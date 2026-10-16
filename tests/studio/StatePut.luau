-- Native StateQueue.Put correctness on the current runtime module; no timing samples.
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local Definition = require(game:GetService("ReplicatedStorage").Relay.Definition)
local Frame = require(game:GetService("ReplicatedStorage").Relay.internal.Frame)
local BatchFrame = require(game:GetService("ReplicatedStorage").Relay.internal.BatchFrame)
local StateQueue = require(game:GetService("ReplicatedStorage").Relay.internal.StateQueue)

local bigFields = {}
for index = 1, 8 do bigFields[index] = { name = "part" .. index, type = "string",
    maximumBytes = if index == 8 then 1_000 else 1_024 } end
local token, problem = Relay.define({ name = "NativeStatePutProof", version = 1, events = {
    Small = { id = 1, direction = "ServerToClient", queue = "State", fields = { { name = "value", type = "u32" } } },
    Big = { id = 2, direction = "ServerToClient", queue = "State", fields = bigFields },
} })
assert(token, problem and problem.message)
local compiled = assert(Definition.get(token))
local events, decoders, definitions = {}, {}, {}
for name, event in compiled.events do
    local queued = assert(compiled.queuedById[event.id])
    events[name] = { id = queued.id, delivery = queued.delivery, queue = queued.queue,
        encode = Frame.compile(queued, "encode") }
    decoders[queued.id] = Frame.compile(queued, "decode")
    definitions[queued.id] = queued
end

local function bigPayload(bytes)
    local remaining, fields = bytes - 19, {}
    for index = 1, 8 do
        local length = math.min(remaining, if index == 8 then 1_000 else 1_024)
        fields[index], remaining = string.rep("x", length), remaining - length
    end
    assert(remaining == 0, "native Big body size")
    local valid, body = events.Big.encode(table.unpack(fields))
    assert(valid and buffer.len(body) == bytes, "native Big encoding")
    return fields
end

local function fixture()
    local clock = { now = 0, packets = {} }
    local owner = { alive = true, events = events, flushOwner = nil }
    function owner.check() return true, nil end
    function owner.now() return clock.now end
    function owner.handoff(delivery, packet)
        assert(delivery == "Reliable" and typeof(packet) == "buffer", "native State packet")
        clock.packets[#clock.packets + 1] = packet
        return true, nil, 1
    end
    function clock:readValues()
        local values = {}
        for _, packet in self.packets do
            local header = assert(BatchFrame.header(packet, 8_192))
            assert(header.kind == 2, "native State frame kind")
            local rows = assert(BatchFrame.scan(packet, header, function(id) return definitions[id] end))
            for _, row in rows do
                local body = assert(BatchFrame.readBody(packet, row))
                local valid, value = decoders[row.event.id](body)
                assert(valid and row.event.id == 1, "native State value decode")
                values[#values + 1] = value
            end
        end
        table.sort(values)
        return values
    end
    return clock, owner
end

local function runSmall(keyCount, laneCount, pattern)
    local clock, owner = fixture()
    local lanes = {}
    for index = 1, laneCount do lanes[index] = assert(StateQueue.create(owner, nil, 60)) end
    local expiredCount = if pattern == "all" then keyCount elseif pattern == "mixed" then math.floor(keyCount / 2) else 0
    for key = 1, keyCount do
        clock.now = if key <= expiredCount then 0 else 0.5
        local lane = lanes[(key - 1) % laneCount + 1]
        assert(lane.events.Small:Put(key, "Normal", key * 10), "native initial Put")
    end
    clock.now = 1
    local target = 1
    assert(lanes[1].events.Small:Put(target, "High", 999), "native affected-path Put")
    local expected = { 999 }
    for key = 1, keyCount do
        if key ~= target and key > expiredCount then expected[#expected + 1] = key * 10 end
    end
    table.sort(expected)
    assert(owner.stateKeys == math.max(1, keyCount) and owner.stateBytes == #expected * 7,
        "native cross-lane expiry accounting")
    for _, lane in lanes do
        while lane:GetStatus().pendingKeys > 0 do
            local ok, issue, report = lane:Flush()
            assert(ok and issue == nil and report.selected > 0, "native State flush")
        end
    end
    local actual = clock:readValues()
    assert(#actual == #expected, "native State delivery count")
    for index, value in expected do assert(actual[index] == value, "native State expiry/replacement bytes") end
    StateQueue.destroy(owner)
    assert(owner.stateKeys == 0 and owner.stateBytes == 0 and #owner.states == 0, "native State cleanup")
end

local function runRejectedExpiry()
    local clock, owner = fixture()
    local lanes = {}
    for index = 1, 4 do lanes[index] = assert(StateQueue.create(owner, nil, 60)) end
    local initial = bigPayload(1_024)
    for key = 1, 16 do
        clock.now = if key == 4 then 0 else 0.5
        assert(lanes[(key - 1) % 4 + 1].events.Big:Put(key, "Normal", table.unpack(initial)))
    end
    assert(owner.stateBytes == 16_384 and lanes[4]:GetStatus().pendingKeys == 4)
    local expiredTimer = owner.states[4].timer
    clock.now = 1
    local accepted, issue = lanes[1].events.Big:Put(1, "High", table.unpack(bigPayload(8_187)))
    assert(not accepted and issue == Definition.error("QueueFull"), "native over-cap rejection")
    assert(owner.stateBytes == 16_384 and owner.stateKeys == 16
        and lanes[4]:GetStatus().pendingKeys == 4 and owner.states[4].timer == expiredTimer,
        "rejected native Put preserves expired other-lane body and timer")
    assert(lanes[1].events.Big:Put(1, "High", table.unpack(bigPayload(20))), "native admitted shrink")
    assert(owner.stateBytes == 16_384 - 1_024 - 1_024 + 20
        and lanes[4]:GetStatus().pendingKeys == 3, "admitted native Put applies other-lane expiry")
    StateQueue.destroy(owner)
    assert(owner.stateKeys == 0 and owner.stateBytes == 0 and #owner.states == 0, "native cap cleanup")
end

return function()
    local cases = 0
    for _, keys in { 0, 1, 16, 64 } do
        for _, lanes in { 1, 4 } do
            for _, pattern in { "fresh", "mixed", "all" } do
                if (keys == 0 and pattern ~= "fresh") or (keys == 1 and pattern == "mixed") then continue end
                runSmall(keys, lanes, pattern)
                cases += 1
            end
        end
    end
    runRejectedExpiry()
    return { cases = cases + 1, nativeBuffers = true, rejectedExpiryPreserved = true }
end
