local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local RpcFrame = require("../src/internal/RpcFrame")
local ReadinessFrame = require("../src/internal/ReadinessFrame")
local BatchFrame = require("../src/internal/BatchFrame")
local ServerRuntime = require("./support/ServerRuntime")
local roblox = require("@lune/roblox")

local definition = assert(Definition.define({
    name = "InboundBytesProof", version = 1, readiness = true,
    events = {
        Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "boolean" } } },
        UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
            fields = { { name = "value", type = "boolean" } } },
        BatchInput = { id = 3, direction = "ClientToServer", queue = "Batch",
            fields = { { name = "value", type = "boolean" } } },
        StateInput = { id = 4, direction = "ClientToServer", queue = "State",
            fields = { { name = "value", type = "boolean" } } },
        Output = { id = 5, direction = "ServerToClient", fields = {} },
        EmptyInput = { id = 7, direction = "ClientToServer", fields = {} },
    },
    requests = {
        Inspect = { id = 6, request = { { name = "enabled", type = "boolean" } }, response = { type = "boolean" } },
    },
}))
local compiled = assert(Definition.get(definition))
local guid = "01234567-89ab-cdef-0123-456789abcdef"

local function options(byteRate, playerCalls, aggregateCalls)
    local inboundRate = {
        perPlayer = { capacity = playerCalls or 64, refillPerSecond = 64 },
        aggregate = { capacity = aggregateCalls or 128, refillPerSecond = 128 },
    }
    if byteRate ~= nil then
        inboundRate.bytes = byteRate
    end
    return { inboundRate = inboundRate }
end

local function bytes(playerCapacity, aggregateCapacity, playerRefill, aggregateRefill)
    return {
        perPlayer = { capacity = playerCapacity, refillPerSecond = playerRefill or 64 },
        aggregate = { capacity = aggregateCapacity or playerCapacity,
            refillPerSecond = aggregateRefill or playerRefill or 64 },
    }
end

local function setup(serverOptions, playerCount)
    local runtime = ServerRuntime.new()
    local players = table.create(playerCount or 1)
    for index = 1, playerCount or 1 do
        players[index] = runtime:addPlayer()
    end
    local server = assert(runtime.server.create(definition, serverOptions or options()))
    assert(server:Start())
    return runtime, players, server, runtime:remote(), runtime:unreliableRemote()
end

local function eventBody(name, ...)
    local encoded = table.pack(Frame.compile(compiled.events[name], "encode")(...))
    assert(encoded[1] == true)
    return encoded[2]
end

local function queuedBody(id, value)
    local encoded = table.pack(Frame.compile(compiled.queuedById[id], "encode")(value))
    assert(encoded[1] == true)
    return encoded[2]
end

local function requestPacket(callId, value)
    local encoded = table.pack(Frame.compile(compiled.requests.Inspect.request, "encode")(value))
    assert(encoded[1] == true)
    return assert(RpcFrame.wrap(1, 6, callId, guid, encoded[2]))
end

local function expectInvalid(byteRate)
    local runtime = ServerRuntime.new()
    local server, problem = runtime.server.create(definition, options(byteRate))
    assert(server == nil and problem.code == "InvalidOptions", "invalid byte policy rejects at creation")
end

-- Byte rows are closed, finite, bounded and checked even when no endpoint map exists.
for _, policy in {
    {},
    { perPlayer = { capacity = 1, refillPerSecond = 1 } },
    { aggregate = { capacity = 1, refillPerSecond = 1 } },
    { perPlayer = setmetatable({ capacity = 1, refillPerSecond = 1 }, {}) ,
        aggregate = { capacity = 1, refillPerSecond = 1 } },
    { perPlayer = { capacity = 1, refillPerSecond = 1, extra = true },
        aggregate = { capacity = 1, refillPerSecond = 1 } },
    { perPlayer = { capacity = 33_554_433, refillPerSecond = 1 },
        aggregate = { capacity = 33_554_433, refillPerSecond = 1 } },
    { perPlayer = { capacity = 1, refillPerSecond = 16_777_217 },
        aggregate = { capacity = 1, refillPerSecond = 16_777_217 } },
    { perPlayer = { capacity = 2, refillPerSecond = 2 },
        aggregate = { capacity = 1, refillPerSecond = 2 } },
    { perPlayer = { capacity = 1, refillPerSecond = 2 },
        aggregate = { capacity = 1, refillPerSecond = 1 } },
} do
    expectInvalid(policy)
end
expectInvalid(setmetatable(bytes(1), {}))
expectInvalid(bytes(0))
expectInvalid(bytes(1, 1, 0))
expectInvalid(bytes(1, 1, math.huge))
expectInvalid(bytes(1, 268_435_457))
expectInvalid(bytes(1, 1, 1, 134_217_729))

do
    local runtime = ServerRuntime.new()
    local maximum = bytes(33_554_432, 268_435_456, 16_777_216, 134_217_728)
    local server = assert(runtime.server.create(definition, options(maximum)))
    assert(server:GetDiagnostics().inboundRate.bytes.aggregate.capacity == 268_435_456)
    server:Destroy()

    local rate = bytes(4, 8, 1, 2)
    local player = runtime:addPlayer()
    server = assert(runtime.server.create(definition, options(rate)))
    rate.perPlayer.capacity = 99
    rate.aggregate.capacity = 99
    local policy = server:GetDiagnostics().inboundRate.bytes
    assert(policy.perPlayer.capacity == 4 and policy.aggregate.capacity == 8)
    assert(table.isfrozen(policy) and table.isfrozen(policy.perPlayer) and table.isfrozen(policy.aggregate))
    assert(server:Start())
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    runtime:remote().OnServerEvent:Fire(player, 1, true)
    runtime:remote().OnServerEvent:Fire(player, 1, true)
    assert(calls == 1 and server:GetDiagnostics().counters.perPlayerBytes == 1,
        "the copied bucket policy remains in force after caller mutation")
    server:Destroy()
end

-- Omitted bytes keep existing admission; an empty byte row is invalid rather than an opt-out.
do
    expectInvalid({})
    local runtime, players, server, remote = setup(options(nil))
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[1], 1, true)
    local snapshot = server:GetDiagnostics()
    assert(calls == 2 and snapshot.inboundRate.bytes == nil
        and snapshot.counters.perPlayerBytes == 0 and snapshot.counters.aggregateBytes == 0)
    server:Destroy()
end

-- Native tuple widths are charged exactly; one raw buffer costs its full envelope once on either channel.
do
    local nativeCost = 3 + 1 + 8 + 8 + 12 + 96 + 2 + #"abc"
    local runtime, players, server, remote = setup(options(bytes(nativeCost)))
    assert(server.events.EmptyInput:Connect(function() end))
    remote.OnServerEvent:Fire(players[1], 7, true, 12, roblox.Vector2.new(1, 2),
        roblox.Vector3.new(1, 2, 3), roblox.CFrame.new(), "abc")
    remote.OnServerEvent:Fire(players[1], 7)
    local counters = server:GetDiagnostics().counters
    assert(counters.invalidPayload == 1 and counters.perPlayerBytes == 1,
        "native bool/number/vector/CFrame/string widths use one fixed header and exact content costs")
    server:Destroy()

    local body = eventBody("UnreliableInput", true)
    local length = buffer.len(body)
    local unreliable
    runtime, players, server, remote, unreliable = setup(options(bytes(length)))
    local calls = 0
    assert(server.events.UnreliableInput:Connect(function(_, value)
        assert(value == true)
        calls += 1
    end))
    local reads = runtime.clockReads
    unreliable.OnServerEvent:Fire(players[1], 2, body)
    assert(runtime.clockReads == reads + 1 and calls == 1)
    remote.OnServerEvent:Fire(players[1], 2, body)
    counters = server:GetDiagnostics().counters
    assert(counters.perPlayerBytes == 1 and counters.wrongChannel == 0,
        "the exact buffer length is charged once and shared across reliable/unreliable ingress")
    server:Destroy()
end

-- Unmeasurable values, invalid selectors and more than eight native arguments fail before validation.
do
    local runtime, players, server, remote = setup(options(bytes(64)))
    local hostile = setmetatable({}, {
        __index = function() error("byte estimator traversed hostile input") end,
        __iter = function() error("byte estimator iterated hostile input") end,
    })
    remote.OnServerEvent:Fire(players[1], 1, hostile)
    remote.OnServerEvent:Fire(players[1], -1, hostile)
    remote.OnServerEvent:Fire(players[1], 1, 1, 2, 3, 4, 5, 6, 7, 8, 9)
    local snapshot = server:GetDiagnostics()
    assert(snapshot.counters.perPlayerBytes == 3 and snapshot.counters.invalidPayload == 0
        and snapshot.counters.invalidEndpoint == 0 and runtime.validationCalls == 0,
        "unmeasurable calls refuse without table traversal, route parsing or payload validation")
    server:Destroy()
end

-- Weighted byte refill keeps fractional balances, high-water time and one ingress sample.
do
    local runtime, players, server, remote = setup(options(bytes(3, 6, 4, 8)))
    local calls = 0
    assert(server.events.EmptyInput:Connect(function() calls += 1 end))
    local reads = runtime.clockReads
    remote.OnServerEvent:Fire(players[1], 7)
    assert(runtime.clockReads == reads + 1 and calls == 1)
    runtime.now = 0.5
    remote.OnServerEvent:Fire(players[1], 7)
    runtime.now = 0.25
    remote.OnServerEvent:Fire(players[1], 7)
    runtime.now = 0.75
    remote.OnServerEvent:Fire(players[1], 7)
    local counters = server:GetDiagnostics().counters
    assert(calls == 2 and counters.perPlayerBytes == 2 and counters.aggregateBytes == 0,
        "insufficient weighted takes keep fractional tokens and backward time cannot refill twice")
    assert(runtime.clockReads == reads + 4, "all byte buckets reuse one clock sample per eligible ingress")
    server:Destroy()
end

-- Player rejection skips aggregate bytes; aggregate rejection retains the player's earlier byte debit.
do
    local runtime, players, server, remote = setup(options(bytes(4, 8)))
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[2] or runtime:addPlayer(), 1, true)
    local counters = server:GetDiagnostics().counters
    assert(calls == 2 and counters.perPlayerBytes == 1 and counters.aggregateBytes == 0,
        "per-player exhaustion leaves aggregate bytes available to another player")
    server:Destroy()

    runtime, players, server, remote = setup(options(bytes(4, 4, 0.5, 1)), 3)
    calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[2], 1, true)
    runtime.now = 4
    remote.OnServerEvent:Fire(players[2], 1, true)
    remote.OnServerEvent:Fire(players[3], 1, true)
    counters = server:GetDiagnostics().counters
    assert(calls == 2 and counters.aggregateBytes == 1 and counters.perPlayerBytes == 1,
        "aggregate refusal retains the player debit; later player refusal leaves aggregate tokens untouched")
    server:Destroy()
end

-- RPC buffers share the same byte pool as immediate events, with no response on byte refusal.
do
    local packet = requestPacket(1, true)
    local runtime, players, server, remote = setup(options(bytes(buffer.len(packet))))
    local requests = 0
    assert(server.requests.Inspect:Connect(function(_, enabled)
        assert(enabled == true)
        requests += 1
        return true
    end))
    remote.OnServerEvent:Fire(players[1], 0, packet)
    local responses = #runtime.fires
    local validations = runtime.validationCalls
    remote.OnServerEvent:Fire(players[1], 0, requestPacket(2, true))
    remote.OnServerEvent:Fire(players[1], 1, true)
    local counters = server:GetDiagnostics().counters
    assert(requests == 1 and #runtime.fires == responses and counters.perPlayerBytes == 2
        and runtime.validationCalls == validations,
        "RPC body decoding happens only after byte admission and refused retries stay silent")
    server:Destroy()
end

-- Readiness controls and ordinary events share one envelope byte budget.
do
    local hello = ReadinessFrame.hello()
    local runtime, players, server, remote = setup(options(bytes(buffer.len(hello))))
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 0, hello)
    remote.OnServerEvent:Fire(players[1], 1, true)
    assert(calls == 0 and #runtime.fires == 1 and server:GetDiagnostics().counters.perPlayerBytes == 1,
        "readiness consumes bytes before control parsing and shares the event bucket")
    server:Destroy()
end

-- A byte-refused queue frame stops before count/logical/endpoint parsing; admitted frames keep later ordering.
do
    for _, item in { { id = 3, name = "BatchInput", kind = 1 }, { id = 4, name = "StateInput", kind = 2 } } do
        local body = queuedBody(item.id, true)
        local twoRows = assert(BatchFrame.wrap(item.kind, { body, body }, 8_192))
        local runtime, players, server, remote = setup(options(bytes(buffer.len(twoRows) - 1), 2, 2))
        local calls = 0
        assert(server.events[item.name]:Connect(function() calls += 1 end))
        assert(server.events.Input:Connect(function() calls += 1 end))
        local before = runtime.validationCalls
        remote.OnServerEvent:Fire(players[1], 0, twoRows)
        remote.OnServerEvent:Fire(players[1], 1, true)
        local counters = server:GetDiagnostics().counters
        assert(calls == 1 and counters.perPlayerBytes == 1 and counters.invalidPayload == 0
            and counters.perPlayerRate == 0 and counters.aggregateRate == 0
            and counters.endpointRate == 0 and runtime.validationCalls == before + 1,
            "byte refusal keeps only the first coarse pair and does no FIFO/State scan or body validation")
        server:Destroy()

        local endpointRates = options(bytes(buffer.len(twoRows)), 2, 2)
        endpointRates.inboundRate.endpoints = { [item.id] = { capacity = 1, refillPerSecond = 1 } }
        runtime, players, server, remote = setup(endpointRates)
        calls = 0
        assert(server.events[item.name]:Connect(function() calls += 1 end))
        assert(server.events.Input:Connect(function() calls += 1 end))
        remote.OnServerEvent:Fire(players[1], 0, twoRows)
        remote.OnServerEvent:Fire(players[1], 1, true)
        counters = server:GetDiagnostics().counters
        assert(calls == 0 and counters.perPlayerBytes == 0 and counters.endpointRate == 1
            and counters.perPlayerRate == 1 and counters.aggregateRate == 0,
            "admitted FIFO/State pays its byte cost once, then retains N coarse and row-ordered endpoint debits")
        server:Destroy()
    end

    local stateBody = queuedBody(4, true)
    local statePacket = assert(BatchFrame.wrap(2, { stateBody }, 8_192))
    local runtime, players, server, remote = setup(options(bytes(buffer.len(statePacket))))
    local stateCalls = 0
    assert(server.events.StateInput:Connect(function(_, value)
        assert(value == true)
        stateCalls += 1
    end))
    remote.OnServerEvent:Fire(players[1], 0, statePacket)
    assert(stateCalls == 1 and server:GetDiagnostics().counters.perPlayerBytes == 0,
        "a byte-admitted kind-2 State frame decodes and dispatches as one envelope")
    server:Destroy()
end

-- Malformed and no-listener ingress retain admitted byte costs; listener replacement does not refill them.
do
    local malformed = buffer.create(4)
    buffer.writeu8(malformed, 0, 1)
    local runtime, players, server, remote = setup(options(bytes(4)))
    remote.OnServerEvent:Fire(players[1], 0, malformed)
    local calls = 0
    assert(server.events.EmptyInput:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 7)
    local counters = server:GetDiagnostics().counters
    assert(calls == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1,
        "malformed admitted frames spend bytes before their normal parser rejection")
    server:Destroy()

    runtime, players, server, remote = setup(options(bytes(8_193)))
    local oversized = buffer.create(8_193)
    remote.OnServerEvent:Fire(players[1], 0, oversized)
    remote.OnServerEvent:Fire(players[1], 1, true)
    counters = server:GetDiagnostics().counters
    assert(counters.invalidPayload == 1 and counters.perPlayerBytes == 1
        and runtime.validationCalls == 0,
        "an over-limit raw frame spends its full byte cost before the existing size rejection")
    server:Destroy()

    runtime, players, server, remote = setup(options(bytes(4)))
    remote.OnServerEvent:Fire(players[1], 1, true)
    assert(server:GetDiagnostics().events.Input.noListener == 1)
    local first = assert(server.events.Input:Connect(function() calls += 1 end))
    first:Disconnect()
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 1, true)
    assert(server:GetDiagnostics().events.Input.noListener == 1
        and server:GetDiagnostics().counters.perPlayerBytes == 1,
        "no-listener ingress retains bytes and reconnecting does not reset them")
    server:Destroy()
end

-- Unknown endpoints and wrong-channel events also spend admitted bytes before classification.
do
    local runtime, players, server, remote, unreliable = setup(options(bytes(4, 8)), 2)
    unreliable.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[2], 99, true)
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[2], 1, true)
    local counters = server:GetDiagnostics().counters
    assert(counters.wrongChannel == 1 and counters.invalidEndpoint == 1
        and counters.perPlayerBytes == 2,
        "wrong-channel and unknown-endpoint ingress retain their byte charges")
    server:Destroy()
end

-- Busy rejections also retain bytes; player removal constructs a fresh bucket.
do
    local runtime, players, server, remote = setup(options(bytes(8)))
    runtime.captureThreads = true
    local calls = 0
    assert(server.events.Input:Connect(function()
        calls += 1
        coroutine.yield()
    end))
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[1], 1, true)
    remote.OnServerEvent:Fire(players[1], 1, true)
    local counters = server:GetDiagnostics().counters
    assert(calls == 1 and counters.busy == 1 and counters.perPlayerBytes == 1,
        "busy ingress retains its admitted byte cost")
    assert(coroutine.resume(runtime.threads[1]))
    server:Destroy()

    runtime, players, server, remote = setup(options(bytes(4, 8)))
    calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(players[1], 1, true)
    runtime:removePlayer(players[1])
    players[1].Parent = runtime.players
    runtime.players.PlayerAdded:Fire(players[1])
    remote.OnServerEvent:Fire(players[1], 1, true)
    assert(calls == 2 and server:GetDiagnostics().counters.perPlayerBytes == 0,
        "player removal clears the prior byte bucket before re-admission")
    server:Destroy()
end

print("PASS Relay.InboundBytes")
