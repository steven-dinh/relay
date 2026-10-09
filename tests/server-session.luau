local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local Runtime = require("./support/ServerRuntime")
local ordered = require("../examples/reliable-events/ordered")

local spec = { name = "ServerTest", version = 1, events = {} }
for id = 1, 9 do
    spec.events[`Input{id}`] = { id = id, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } }
end
spec.events.State = { id = 10, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } }
spec.events.EmptyInput = { id = 11, direction = "ClientToServer", fields = {} }
spec.events.EmptyState = { id = 12, direction = "ServerToClient", fields = {} }
local definition = assert(Definition.define(spec))
local mixedDefinition = assert(Definition.define({ name = "MixedTest", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
    UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
        fields = { { name = "value", type = "boolean" } } },
    EmptyUnreliableInput = { id = 3, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
    State = { id = 4, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
    UnreliableState = { id = 5, direction = "ServerToClient", delivery = "Unreliable",
        fields = { { name = "value", type = "boolean" } } },
    EmptyUnreliableState = { id = 6, direction = "ServerToClient", delivery = "Unreliable", fields = {} },
} }))
local unreliableOnlyDefinition = assert(Definition.define({ name = "UnreliableOnlyTest", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
    State = { id = 2, direction = "ServerToClient", delivery = "Unreliable", fields = {} },
} }))
local function options(playerCapacity, aggregateCapacity)
    return { inboundRate = {
        perPlayer = { capacity = playerCapacity or 4096, refillPerSecond = 1 },
        aggregate = { capacity = aggregateCapacity or 32768, refillPerSecond = 1 },
    } }
end
local function errorCode(value, err, expected)
    assert(not value and err.code == expected, `expected {expected}`)
    assert(table.isfrozen(err))
end
local function expectError(expected, value, err)
    errorCode(value, err, expected)
end
local function countKeys(value)
    local count = 0
    for _ in value do
        count += 1
    end
    return count
end
local runtime = Runtime.new()
runtime.isServer = false
expectError("WrongRuntimeSide", runtime.server.create({}, {}))
runtime.isServer = true
expectError("InvalidDefinition", runtime.server.create({}, {}))
for _, badOptions in {
    {}, { inboundRate = {} }, { inboundRate = options().inboundRate, extra = true },
    setmetatable(options(), {}),
} do
    expectError("InvalidOptions", runtime.server.create(definition, badOptions))
end
for _, path in { "perPlayer", "aggregate" } do
    for _, key in { "capacity", "refillPerSecond" } do
        for _, value in { 0, -1, math.huge, -math.huge, 0 / 0, "1", false } do
            local malformed = options()
            malformed.inboundRate[path][key] = value
            expectError("InvalidOptions", runtime.server.create(definition, malformed))
        end
    end
end
for _, edit in {
    function(value) value.inboundRate = nil end,
    function(value) value.inboundRate.perPlayer = nil end,
    function(value) value.inboundRate.aggregate = nil end,
    function(value) value.inboundRate.perPlayer.capacity = nil end,
    function(value) value.inboundRate.perPlayer.refillPerSecond = nil end,
    function(value) value.inboundRate.aggregate.capacity = nil end,
    function(value) value.inboundRate.aggregate.refillPerSecond = nil end,
    function(value) value.inboundRate.perPlayer.capacity = 1.5 end,
    function(value) value.inboundRate.perPlayer.capacity = 4097 end,
    function(value) value.inboundRate.aggregate.capacity = 32769 end,
    function(value) value.inboundRate.perPlayer.refillPerSecond = 2049 end,
    function(value) value.inboundRate.aggregate.refillPerSecond = 16385 end,
    function(value) value.inboundRate.aggregate.capacity = 1 end,
    function(value) value.inboundRate.aggregate.refillPerSecond = 0.5 end,
    function(value) value.inboundRate.perPlayer.extra = true end,
    function(value) setmetatable(value.inboundRate.aggregate, {}) end,
} do
    local malformed = options()
    edit(malformed)
    expectError("InvalidOptions", runtime.server.create(definition, malformed))
end
local player = runtime:addPlayer()
local server = assert(runtime.server.create(definition, options()))
assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0, "create has no runtime artifacts")
assert(table.isfrozen(server) and table.isfrozen(server.events) and table.isfrozen(server.events.Input1))
expectError("NotStarted", server.events.State:Send(nil, "bad"))
expectError("InvalidHandler", server.events.Input1:Connect(false))
local calls = 0
local connection = assert(server.events.Input1:Connect(function(sender, value)
    assert(sender == player and value == 4)
    calls += 1
end))
expectError("AlreadyConnected", server.events.Input1:Connect(function() end))
assert(server:Start())
local remote = runtime:remote()
assert(runtime:unreliableRemote() == nil, "reliable-only sessions keep their legacy topology")
local clockReads = runtime.clockReads
remote.OnServerEvent:Fire({}, 1, 4)
assert(runtime.clockReads == clockReads, "unrostered sender rejects before reading the clock")
remote.OnServerEvent:Fire(player, 1, 4)
assert(runtime.clockReads == clockReads + 1, "accepted ingress shares one clock read across both buckets")
remote.OnServerEvent:Fire(player, 1, {})
remote.OnServerEvent:Fire(player, 1, 4, nil)
remote.OnServerEvent:Fire(player, 10, 4)
assert(runtime.clockReads == clockReads + 4, "malformed and wrong-direction ingress also share one clock read")
assert(calls == 1)
local storageScans = runtime.storageScans
for _ = 1, 20 do remote.OnServerEvent:Fire(player, "unknown") end
assert(runtime.storageScans == storageScans, "incoming calls must not enumerate unrelated storage children")
assert(server.events.State:Send(player, 5))
assert(server.events.State:Broadcast(6))
assert(#runtime.fires == 2 and runtime.fires[1].kind == "target" and runtime.fires[2].kind == "broadcast")
expectError("InvalidPlayer", server.events.State:Send({}, "bad"))
expectError("InvalidPayload", server.events.State:Send(player, "bad"))
runtime.throwFire = true
expectError("TransportFailure", server.events.State:Broadcast(1))
runtime.throwFire = false
runtime.beforeFire = function(target)
    runtime:removePlayer(target)
end
expectError("TransportFailure", server.events.State:Send(player, 1))
runtime.beforeFire = nil
connection:Disconnect()
connection:Disconnect()
server:Destroy()
server:Destroy()
expectError("Destroyed", server.events.Input1:Connect(false))
expectError("Destroyed", server:Start())
assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)

-- Ownership conflicts concern direct children of any class, not nested names.
runtime = Runtime.new()
local container = runtime.newInstance("Folder")
container.Name = "Other"
container.Parent = runtime.storage
local reserved = runtime.newInstance("StringValue")
reserved.Name = "RelayRemotes"
reserved.Parent = container
server = assert(runtime.server.create(definition, options()))
assert(server:Start(), "a nested reserved name must not conflict")
server:Destroy()
assert(reserved.Parent == container and container.Parent == runtime.storage)
reserved.Parent = runtime.storage
server = assert(runtime.server.create(definition, options()))
storageScans = runtime.storageScans
expectError("RemoteOwnershipConflict", server:Start())
assert(runtime.storageScans == storageScans, "existence check must not enumerate storage children")
assert(not reserved.destroyed and not container.destroyed and runtime.connections == 0)

-- Endpoint binding preserves missing/nil arguments and zero-field payloads.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options()))
calls = 0
assert(server.events.EmptyInput:Connect(function(sender, ...)
    assert(sender == player and select("#", ...) == 0)
    calls += 1
end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(player)
remote.OnServerEvent:Fire(player, nil)
remote.OnServerEvent:Fire(player, nil, 11)
remote.OnServerEvent:Fire(player, 11, nil)
remote.OnServerEvent:Fire(player, 11, false)
assert(calls == 0, "missing endpoint and extra arguments must reject")
remote.OnServerEvent:Fire(player, 11)
remote.OnServerEvent:Fire(player, 11)
assert(calls == 2, "zero-field dispatch must release its reservation")
assert(server.events.EmptyState:Send(player))
assert(server.events.EmptyState:Broadcast())
assert(#runtime.fires == 2)
for _, fire in runtime.fires do
    assert(fire.values.n == 1 and fire.values[1] == 12, "empty sends contain only the endpoint")
end
expectError("InvalidPayload", server.events.EmptyState:Broadcast(nil))
server:Destroy()

-- A malformed attempt spends aggregate capacity before payload validation.
runtime = Runtime.new()
local hostile, honest = runtime:addPlayer(), runtime:addPlayer()
server = assert(runtime.server.create(definition, options(2, 2)))
calls = 0
assert(server.events.Input1:Connect(function() calls += 1 end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(hostile, "unknown")
remote.OnServerEvent:Fire(honest, 1, 1)
clockReads = runtime.clockReads
remote.OnServerEvent:Fire(honest, 1, 1)
assert(runtime.clockReads == clockReads + 1, "aggregate exhaustion still uses one clock read")
assert(calls == 1, "malformed frame must charge aggregate independently of per-player exhaustion")
server:Destroy()

-- An exhausted player cannot drain aggregate.
runtime = Runtime.new()
hostile, honest = runtime:addPlayer(), runtime:addPlayer()
server = assert(runtime.server.create(definition, options(2, 4)))
calls = 0
assert(server.events.Input1:Connect(function() calls += 1 end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(hostile, "unknown")
remote.OnServerEvent:Fire(hostile, 1, "bad")
clockReads = runtime.clockReads
for _ = 1, 20 do remote.OnServerEvent:Fire(hostile, 1, 1) end
assert(runtime.clockReads == clockReads + 20, "per-player exhaustion still uses one clock read per attempt")
remote.OnServerEvent:Fire(honest, 1, 1)
remote.OnServerEvent:Fire(honest, 1, 1)
assert(calls == 2)
runtime.players.PlayerAdded:Fire(hostile)
remote.OnServerEvent:Fire(hostile, 1, 1)
assert(calls == 2, "duplicate add cannot refill")
runtime.now = 1
remote.OnServerEvent:Fire(hostile, 1, 1)
assert(calls == 3)
server:Destroy()

-- Repeated admitted malformed tuples neither dispatch nor grow Relay resources.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options(1, 1)))
calls = 0
assert(server.events.Input1:Connect(function() calls += 1 end))
assert(server:Start())
remote = runtime:remote()
local connectionCount, instanceCount = runtime.connections, countKeys(runtime.instances)
local hostileValue = setmetatable({}, {
    __index = function() error("hostile value traversed") end,
    __iter = function() error("hostile value iterated") end,
    __tostring = function() error("hostile value logged") end,
})
for index = 1, 10_000 do
    runtime.now = index
    if index % 3 == 0 then remote.OnServerEvent:Fire(player, hostileValue)
    elseif index % 3 == 1 then remote.OnServerEvent:Fire(player, 1, hostileValue)
    else remote.OnServerEvent:Fire(player, 1, 1, hostileValue) end
end
assert(calls == 0 and #runtime.fires == 0 and #runtime.pending == 0)
assert(runtime.connections == connectionCount and countKeys(runtime.instances) == instanceCount)
local repeatedSnapshot = server:GetDiagnostics()
assert(countKeys(repeatedSnapshot.counters) == 15 and countKeys(repeatedSnapshot.events) == 12
    and countKeys(repeatedSnapshot.events.Input1) == 8,
    "unknown traffic must leave only the fixed diagnostic counter rows")
assert(repeatedSnapshot.counters.invalidEndpoint > 0 and repeatedSnapshot.counters.invalidPayload > 0)
server:Destroy()
assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)

-- Busy-endpoint rejection still charges both budgets before inspecting the payload.
runtime = Runtime.new()
hostile, honest = runtime:addPlayer(), runtime:addPlayer()
server = assert(runtime.server.create(definition, options(2, 3)))
calls = 0
local busyHandler
assert(server.events.Input1:Connect(function()
    calls += 1
    if calls == 1 then
        busyHandler = coroutine.running()
        coroutine.yield()
    end
end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(hostile, 1, 1)
remote.OnServerEvent:Fire(hostile, 1, "bad")
assert(calls == 1)
assert(coroutine.resume(busyHandler))
remote.OnServerEvent:Fire(hostile, 1, 1)
assert(calls == 1, "busy rejection must debit per-player capacity")
remote.OnServerEvent:Fire(honest, 1, 1)
assert(calls == 2, "per-player exhaustion must not debit aggregate capacity")
remote.OnServerEvent:Fire(honest, 1, 1)
assert(calls == 2, "busy rejection must debit aggregate capacity")
server:Destroy()

-- Yielding listeners retain their endpoint reservation across disconnect/replacement.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options()))
local suspended
calls = 0
connection = assert(server.events.Input1:Connect(function()
    calls += 1
    suspended = coroutine.running()
    coroutine.yield()
end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(player, 1, 1)
connection:Disconnect()
assert(server.events.Input1:Connect(function() calls += 1 end))
remote.OnServerEvent:Fire(player, 1, 1)
assert(calls == 1)
assert(coroutine.resume(suspended))
remote.OnServerEvent:Fire(player, 1, 1)
assert(calls == 2)
server:Destroy()

runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options()))
calls = 0
assert(server.events.Input1:Connect(function()
    calls += 1
    error("private handler failure")
end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(player, 1, 1)
remote.OnServerEvent:Fire(player, 1, 1)
assert(calls == 2, "handler error must release its lease")
server:Destroy()

runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options()))
local playerThreads = {}
for id = 1, 9 do
    local handler = function()
        table.insert(playerThreads, coroutine.running())
        coroutine.yield()
    end
    local eventHandle = server.events[`Input{id}`]
    if id == 9 then
        assert(eventHandle:Once(handler))
    else
        assert(eventHandle:Connect(handler))
    end
end
assert(server:Start())
remote = runtime:remote()
for id = 1, 9 do remote.OnServerEvent:Fire(player, id, 1) end
assert(#playerThreads == 8)
assert(coroutine.resume(playerThreads[1]))
remote.OnServerEvent:Fire(player, 9, 1)
assert(#playerThreads == 9, "player cap failure must not reserve endpoint")
server:Destroy()
for _, thread in playerThreads do
    if coroutine.status(thread) == "suspended" then assert(coroutine.resume(thread)) end
end

-- Later-cap failures reserve nothing; removal and late return never recreate player state.
runtime = Runtime.new()
local players = {}
for _ = 1, 9 do table.insert(players, runtime:addPlayer()) end
server = assert(runtime.server.create(definition, options()))
local suspendedHandlers = {}
for id = 1, 9 do
    assert(server.events[`Input{id}`]:Connect(function()
        table.insert(suspendedHandlers, coroutine.running())
        coroutine.yield()
    end))
end
assert(server:Start())
remote = runtime:remote()
for index = 1, 8 do
    for id = 1, 8 do remote.OnServerEvent:Fire(players[index], id, 1) end
end
assert(#suspendedHandlers == 64)
remote.OnServerEvent:Fire(players[9], 1, 1)
remote.OnServerEvent:Fire(players[1], 9, 1)
assert(#suspendedHandlers == 64)
runtime:removePlayer(players[1])
assert(coroutine.resume(suspendedHandlers[1]))
remote.OnServerEvent:Fire(players[9], 1, 1)
assert(#suspendedHandlers == 65, "aggregate failure must not occupy earlier endpoint/player caps")
remote.OnServerEvent:Fire(players[1], 1, 1)
assert(#suspendedHandlers == 65)
server:Destroy()
for _, thread in suspendedHandlers do
    if coroutine.status(thread) == "suspended" then assert(coroutine.resume(thread)) end
end
assert(runtime.connections == 0)

-- Roster startup duplicate-add/snapshot and removal races use exact object identity.
runtime = Runtime.new()
player = runtime:addPlayer()
local removedPlayer = runtime:addPlayer()
runtime.snapshotHook = function()
    runtime.players.PlayerAdded:Fire(player)
    runtime:removePlayer(removedPlayer)
    runtime.players.PlayerAdded:Fire(removedPlayer)
end
server = assert(runtime.server.create(definition, options(1, 2)))
calls = 0
assert(server.events.Input1:Connect(function() calls += 1 end))
assert(server:Start())
remote = runtime:remote()
remote.OnServerEvent:Fire(removedPlayer, 1, 1)
remote.OnServerEvent:Fire(player, 1, 1)
remote.OnServerEvent:Fire(player, 1, 1)
assert(calls == 1)
server:Destroy()

-- A deferred removal leaves a roster entry, but a departed sender cannot spend rate tokens.
runtime = Runtime.new()
local departing = runtime:addPlayer()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options(1, 1)))
calls = 0
assert(server.events.Input1:Connect(function(sender)
    assert(sender == player)
    calls += 1
end))
assert(server:Start())
remote = runtime:remote()
runtime.deferred = true
runtime:removePlayer(departing)
runtime.deferred = false
clockReads = runtime.clockReads
remote.OnServerEvent:Fire(departing, 1, 1)
assert(runtime.clockReads == clockReads, "departed sender rejects before reading the clock")
remote.OnServerEvent:Fire(player, 1, 1)
assert(calls == 1, "departed sender must reject before debiting aggregate capacity")
runtime:flush()
server:Destroy()

-- Synchronous identity checks close the deferred-signal window; contaminated leaves survive.
for _, mutate in {
    function(rt, root) root.Name = "Changed" end,
    function(rt, root) root.Parent = nil end,
    function(rt, root) root:GetChildren()[1].Value = "Changed" end,
    function(rt, root) rt:remote().Name = "Changed" end,
    function(rt, root) local child = rt.newInstance("Folder"); child.Parent = root end,
    function(rt, root)
        rt:remote().Parent = nil
        local replacement = rt.newInstance("RemoteEvent")
        replacement.Name = "Reliable"
        replacement.Parent = root
        assert(#root:GetChildren() == 2, "replacement preserves the child count")
    end,
} do
    runtime = Runtime.new()
    player = runtime:addPlayer()
    server = assert(runtime.server.create(definition, options()))
    calls = 0
    assert(server.events.Input1:Connect(function() calls += 1 end))
    assert(server:Start())
    remote = runtime:remote()
    runtime.deferred = true
    mutate(runtime, runtime.storage:GetChildren()[1])
    expectError("InvalidPayload", server.events.State:Broadcast("bad"))
    assert(#runtime.fires == 0, "invalid payload must precede deferred integrity failure")
    expectError("Destroyed", server.events.State:Broadcast(1))
    remote.OnServerEvent:Fire(player, 1, 1)
    runtime:flush()
    assert(calls == 0 and #runtime.fires == 0 and runtime.connections == 0)
end
runtime = Runtime.new()
server = assert(runtime.server.create(definition, options()))
assert(server:Start())
local duplicate = runtime.newInstance("Folder")
duplicate.Name = "RelayRemotes"
duplicate.Parent = runtime.storage
expectError("Destroyed", server.events.State:Broadcast(1))
assert(not duplicate.destroyed and runtime.connections == 0)

do
    runtime = Runtime.new()
    local existing = runtime.newInstance("Folder")
    existing.Name = "Other"
    existing.Parent = runtime.storage
    server = assert(runtime.server.create(definition, options()))
    assert(server:Start())
    existing.Name = "RelayRemotes"
    expectError("Destroyed", server.events.State:Broadcast(1))
    assert(not existing.destroyed and existing.Parent == runtime.storage and runtime.connections == 0,
        "renamed foreign storage sibling must terminate without deleting it")
end

do
    runtime = Runtime.new()
    server = assert(runtime.server.create(definition, options()))
    assert(server:Start())
    local added = runtime.newInstance("Folder")
    added.Name = "Other"
    added.Parent = runtime.storage
    runtime.deferred = true
    added.Name = "RelayRemotes"
    assert(server.events.State:Broadcast(1), "deferred sibling watcher must wait for its signal")
    runtime:flush()
    runtime.deferred = false
    expectError("Destroyed", server.events.State:Broadcast(1))
    assert(not added.destroyed and added.Parent == runtime.storage and runtime.connections == 0,
        "deferred foreign sibling conflict must preserve the foreign instance")
end

do
    runtime = Runtime.new()
    server = assert(runtime.server.create(definition, options()))
    assert(server:Start())
    local removed = runtime.newInstance("Folder")
    removed.Name = "Other"
    removed.Parent = runtime.storage
    local kept = runtime.newInstance("Folder")
    kept.Name = "Other"
    kept.Parent = runtime.storage
    local withBoth = runtime.connections
    removed.Parent = nil
    assert(runtime.connections == withBoth - 1, "removal must release that sibling watcher")
    removed.Name = "RelayRemotes"
    assert(server.events.State:Broadcast(1), "renaming a removed sibling must not terminate the server")
    server:Destroy()
    assert(not kept.destroyed and kept.Parent == runtime.storage and runtime.connections == 0,
        "destroy must release remaining sibling watchers and preserve foreign siblings")
end

runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(definition, options()))
calls = 0
assert(server.events.Input1:Connect(function() calls += 1 end))
assert(server:Start())
remote = runtime:remote()
runtime.deferred = true
remote.Name = "Changed"
runtime.deferred = false
remote.OnServerEvent:Fire(player, 1, 1)
assert(calls == 0 and runtime.connections == 0, "receive must detect identity loss before queued observers")
expectError("Destroyed", server:Start())
runtime:flush()
for _, mutateAndRestore in {
    function(rt, root)
        root.Name = "Changed"
        root.Name = "RelayRemotes"
    end,
    function(rt, root)
        root.Parent = nil
        root.Parent = rt.storage
    end,
    function(rt, root)
        local descriptor = root:GetChildren()[1]
        local original = descriptor.Value
        descriptor.Value = "Changed"
        descriptor.Value = original
    end,
    function(rt, root)
        local child = rt.newInstance("Folder")
        child.Parent = root
        child.Parent = nil
    end,
} do
    runtime = Runtime.new()
    runtime.deferred = true
    server = assert(runtime.server.create(definition, options()))
    assert(server:Start())
    runtime:flush()
    assert(server.events.State:Broadcast(1), "own deferred startup events must not destroy session")
    mutateAndRestore(runtime, runtime.storage:GetChildren()[1])
    runtime:flush()
    expectError("Destroyed", server.events.State:Broadcast(1))
    assert(runtime.connections == 0)
end
for _, ownerName in { "Definition", "Reliable", "RelayRemotes" } do
    runtime = Runtime.new()
    server = assert(runtime.server.create(definition, options()))
    assert(server:Start())
    local root = runtime.storage:FindFirstChild("RelayRemotes")
    local owner = if ownerName == "RelayRemotes" then root else root:FindFirstChild(ownerName)
    local foreign = runtime.newInstance("Part")
    local nested = runtime.newInstance("Folder")
    nested.Parent = foreign
    foreign.Parent = owner
    server:Destroy()
    assert(not foreign.destroyed and not nested.destroyed and not owner.destroyed and not root.destroyed)
    assert(foreign.Parent == owner and nested.Parent == foreign and runtime.connections == 0)
    local nextServer = assert(runtime.server.create(definition, options()))
    expectError("RemoteOwnershipConflict", nextServer:Start())
    assert(not foreign.destroyed and not nested.destroyed)
end

runtime = Runtime.new()
runtime:addPlayer()
for _ = 1, 100 do
    server = assert(runtime.server.create(definition, options()))
    local contender = assert(runtime.server.create(definition, options()))
    assert(server:Start())
    expectError("AlreadyStarted", contender:Start())
    server:Destroy()
    assert(contender:Start())
    contender:Destroy()
    assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)
end
-- All compiled arities reach both native sends and handlers without nil padding.
for arity = 0, 8 do
    local fields, input, expected = {}, {}, {}
    local bytes = buffer.create(4)
    for index = 1, arity do
        local flag = index == 1 or index == arity
        fields[index] = if flag then { name = `v{index}`, type = "boolean" }
            else { name = `v{index}`, type = "f32", minimum = -1, maximum = 1 }
        input[index] = if flag then false else index / 10
        if flag then
            expected[index] = false
        else
            buffer.writef32(bytes, 0, input[index])
            expected[index] = buffer.readf32(bytes, 0)
        end
    end
    local token = assert(Definition.define({ name = "ArityProof", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", fields = fields },
        State = { id = 2, direction = "ServerToClient", fields = fields },
    } }))
    local rt = Runtime.new()
    local sender = rt:addPlayer()
    local session = assert(rt.server.create(token, options()))
    local received, count = nil, 0
    assert(session.events.Input:Connect(function(from, ...)
        assert(from == sender)
        received = table.pack(...)
        count += 1
    end))
    assert(session:Start())
    rt:remote().OnServerEvent:Fire(sender, 1, table.unpack(input, 1, arity))
    rt:remote().OnServerEvent:Fire(sender, 1, table.unpack(input, 1, arity + 1))
    assert(count == 1 and received.n == arity, "server must dispatch the exact normalized tuple")
    assert(session.events.State:Send(sender, table.unpack(input, 1, arity)))
    assert(session.events.State:Broadcast(table.unpack(input, 1, arity)))
    local ok, err, sent = session.events.State:SendTo({ sender }, table.unpack(input, 1, arity))
    assert(ok and err == nil and sent == 1)
    ok, err, sent = session.events.State:SendExcept({}, table.unpack(input, 1, arity))
    assert(ok and err == nil and sent == 1)
    expectError("InvalidPayload", session.events.State:Broadcast(table.unpack(input, 1, arity + 1)))
    assert(#rt.fires == 4)
    for _, sent in rt.fires do
        assert(sent.values.n == arity + 1 and sent.values[1] == 2, "native wire must contain ID plus exact tuple")
        for index = 1, arity do
            assert(sent.values[index + 1] == expected[index] and received[index] == expected[index])
        end
    end
    session:Destroy()
end

-- A running handler retains its values while another player/endpoint dispatches.
do
    local rt = Runtime.new()
    local firstPlayer, secondPlayer = rt:addPlayer(), rt:addPlayer()
    local session = assert(rt.server.create(definition, options()))
    local packetRemote, held, firstCount, otherCount = nil, nil, 0, 0
    local retained
    assert(session.events.Input1:Connect(function(sender, value, ...)
        firstCount += 1
        if sender == firstPlayer then
            packetRemote.OnServerEvent:Fire(firstPlayer, 1, 99)
            packetRemote.OnServerEvent:Fire(firstPlayer, 2, 7)
            held = coroutine.running()
            coroutine.yield()
            retained = table.pack(sender, value, ...)
        end
    end))
    assert(session.events.Input2:Connect(function(_, value)
        assert(value == 7)
        otherCount += 1
    end))
    assert(session:Start())
    packetRemote = rt:remote()
    packetRemote.OnServerEvent:Fire(firstPlayer, 1, 4)
    packetRemote.OnServerEvent:Fire(secondPlayer, 1, 5)
    assert(firstCount == 2 and otherCount == 1, "reentrant same-player endpoint must stay reserved")
    assert(coroutine.resume(held))
    assert(retained.n == 2 and retained[1] == firstPlayer and retained[2] == 4, "overlap must preserve original tuple")
    session:Destroy()
end
-- Mixed sessions route all send paths through the event's compiled delivery.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(mixedDefinition, options()))
local unreliableCalls, emptyCalls = 0, 0
assert(server.events.UnreliableInput:Connect(function(sender, value)
    assert(sender == player and value == false)
    unreliableCalls += 1
end))
assert(server.events.EmptyUnreliableInput:Connect(function(sender, ...)
    assert(sender == player and select("#", ...) == 0)
    emptyCalls += 1
end))
assert(server:Start())
remote = runtime:remote()
local unreliableRemote = runtime:unreliableRemote()
assert(unreliableRemote and #runtime.storage:FindFirstChild("RelayRemotes"):GetChildren() == 3)
unreliableRemote.OnServerEvent:Fire(player, 2, false)
unreliableRemote.OnServerEvent:Fire(player, 3)
remote.OnServerEvent:Fire(player, 2, false)
unreliableRemote.OnServerEvent:Fire(player, 2, false, nil)
assert(unreliableCalls == 1 and emptyCalls == 1, "wrong-channel and malformed tuples must not dispatch")
assert(server.events.UnreliableState:Send(player, false))
assert(server.events.UnreliableState:Broadcast(false))
assert(server.events.EmptyUnreliableState:Broadcast())
assert(server.events.State:Send(player, 7))
assert(#runtime.fires == 4)
assert(runtime.fires[1].kind == "target" and runtime.fires[1].remote == unreliableRemote
    and runtime.fires[1].values.n == 2 and runtime.fires[1].values[1] == 5
    and runtime.fires[1].values[2] == false)
assert(runtime.fires[2].kind == "broadcast" and runtime.fires[2].remote == unreliableRemote)
assert(runtime.fires[3].remote == unreliableRemote and runtime.fires[3].values.n == 1
    and runtime.fires[3].values[1] == 6, "zero-field unreliable sends keep endpoint-only arity")
assert(runtime.fires[4].remote == remote, "reliable events stay on the reliable leaf")
runtime.throwFire = true
expectError("TransportFailure", server.events.UnreliableState:Broadcast(false))
runtime.throwFire = false
assert(#runtime.fires == 4)
server:Destroy()
assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)

-- An unreliable-only schema still publishes the predictable reliable base leaf.
runtime = Runtime.new()
server = assert(runtime.server.create(unreliableOnlyDefinition, options()))
assert(server:Start())
assert(runtime:remote() ~= nil and runtime:unreliableRemote() ~= nil)
server:Destroy()

-- Wrong-channel and malformed traffic spend the same player's cross-channel budget.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(mixedDefinition, options(3, 10)))
unreliableCalls = 0
assert(server.events.UnreliableInput:Connect(function() unreliableCalls += 1 end))
assert(server:Start())
remote = runtime:remote()
unreliableRemote = runtime:unreliableRemote()
clockReads = runtime.clockReads
remote.OnServerEvent:Fire(player, 2, false)
unreliableRemote.OnServerEvent:Fire(player, 2, false, nil)
unreliableRemote.OnServerEvent:Fire(player, 2, false)
unreliableRemote.OnServerEvent:Fire(player, 2, false)
assert(runtime.clockReads == clockReads + 4 and unreliableCalls == 1,
    "channel mismatch and malformed ingress spend the shared per-player bucket")
server:Destroy()

-- Aggregate admission is shared when separate players use different channels.
runtime = Runtime.new()
local firstPlayer, secondPlayer = runtime:addPlayer(), runtime:addPlayer()
server = assert(runtime.server.create(mixedDefinition, options(2, 3)))
local reliableCalls = 0
unreliableCalls = 0
assert(server.events.Input:Connect(function() reliableCalls += 1 end))
assert(server.events.UnreliableInput:Connect(function() unreliableCalls += 1 end))
assert(server:Start())
remote = runtime:remote()
unreliableRemote = runtime:unreliableRemote()
remote.OnServerEvent:Fire(firstPlayer, 2, false)
unreliableRemote.OnServerEvent:Fire(firstPlayer, 2, false, nil)
remote.OnServerEvent:Fire(secondPlayer, 1, 4)
unreliableRemote.OnServerEvent:Fire(secondPlayer, 2, false)
assert(reliableCalls == 1 and unreliableCalls == 0,
    "mismatch and malformed ingress spend aggregate capacity across channels")
server:Destroy()

-- The per-player dispatch lease cap is shared by reliable and unreliable ingress.
local crossChannelEvents = {}
for id = 1, 9 do
    crossChannelEvents[`Input{id}`] = { id = id, direction = "ClientToServer",
        delivery = if id > 4 then "Unreliable" else "Reliable", fields = {} }
end
local crossChannelDefinition = assert(Definition.define({
    name = "CrossChannelCapacity", version = 1, events = crossChannelEvents,
}))
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(crossChannelDefinition, options()))
local suspended, dispatches = {}, 0
for id = 1, 9 do
    assert(server.events[`Input{id}`]:Connect(function()
        dispatches += 1
        table.insert(suspended, coroutine.running())
        coroutine.yield()
    end))
end
assert(server:Start())
remote = runtime:remote()
unreliableRemote = runtime:unreliableRemote()
for id = 1, 9 do
    local transport = if id > 4 then unreliableRemote else remote
    transport.OnServerEvent:Fire(player, id)
end
assert(dispatches == 8, "mixed channels share the existing eight-handler per-player cap")
assert(coroutine.resume(suspended[1]))
unreliableRemote.OnServerEvent:Fire(player, 9)
assert(dispatches == 9, "a returned handler releases its shared dispatch lease")
server:Destroy()
for _, thread in suspended do
    if coroutine.status(thread) == "suspended" then assert(coroutine.resume(thread)) end
end

-- Optional-leaf corruption fails closed, and foreign descendants survive cleanup.
for _, mutate in {
    function(rt) rt:unreliableRemote().Name = "Changed" end,
    function(rt) rt:unreliableRemote().Parent = nil end,
    function(rt, root) rt.newInstance("Folder").Parent = root end,
    function(rt, root)
        rt:unreliableRemote().Parent = nil
        local replacement = rt.newInstance("UnreliableRemoteEvent")
        replacement.Name = "Unreliable"
        replacement.Parent = root
    end,
} do
    runtime = Runtime.new()
    server = assert(runtime.server.create(mixedDefinition, options()))
    assert(server:Start())
    runtime.deferred = true
    mutate(runtime, runtime.storage:FindFirstChild("RelayRemotes"))
    expectError("InvalidPayload", server.events.State:Broadcast("bad"))
    expectError("Destroyed", server.events.State:Broadcast(1))
    runtime:flush()
    assert(runtime.connections == 0)
end

-- A native optional-leaf construction failure removes all earlier partial instances.
runtime = Runtime.new()
runtime.failInstanceClass = "UnreliableRemoteEvent"
local existingInstances = {}
for instance in runtime.instances do existingInstances[instance] = true end
server = assert(runtime.server.create(mixedDefinition, options()))
expectError("TransportFailure", server:Start())
assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)
for instance in runtime.instances do
    if not existingInstances[instance] then assert(instance.destroyed, "partial session instance must be destroyed") end
end
runtime.failInstanceClass = nil
local nextServer = assert(runtime.server.create(mixedDefinition, options()))
assert(nextServer:Start(), "partial construction failure must release the server slot")
nextServer:Destroy()

-- Queued callbacks from either physical remote cannot dispatch after teardown.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(mixedDefinition, options()))
reliableCalls, unreliableCalls = 0, 0
assert(server.events.Input:Connect(function() reliableCalls += 1 end))
assert(server.events.UnreliableInput:Connect(function() unreliableCalls += 1 end))
assert(server:Start())
runtime.deferred = true
runtime:remote().OnServerEvent:Fire(player, 1, 4)
runtime:unreliableRemote().OnServerEvent:Fire(player, 2, false)
server:Destroy()
runtime.deferred = false
runtime:flush()
assert(reliableCalls == 0 and unreliableCalls == 0 and runtime.connections == 0)

runtime = Runtime.new()
server = assert(runtime.server.create(mixedDefinition, options()))
assert(server:Start())
local root = runtime.storage:FindFirstChild("RelayRemotes")
unreliableRemote = runtime:unreliableRemote()
local foreign = runtime.newInstance("Part")
local nested = runtime.newInstance("Folder")
nested.Parent = foreign
foreign.Parent = unreliableRemote
server:Destroy()
assert(not foreign.destroyed and not nested.destroyed and unreliableRemote.Parent == root
    and foreign.Parent == unreliableRemote and nested.Parent == foreign and root.Parent == runtime.storage
    and runtime.connections == 0, "foreign descendants keep their owning optional leaf alive")
local replacement = assert(runtime.server.create(mixedDefinition, options()))
expectError("RemoteOwnershipConflict", replacement:Start())
assert(not foreign.destroyed)

-- Composite ingress decodes after admission, and malformed frames spend both buckets.
local codecDefinition = assert(Definition.define({ name = "ServerCompositeTest", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", fields = ordered(
        { name = "payload", type = "struct", fields = ordered(
            { name = "mode", type = "enum", values = ordered("Idle", "Run") },
            { name = "values", type = "array", maximumLength = 3,
                element = { type = "u8", minimum = 0, maximum = 10 } },
            { name = "labels", type = "set", maximumSize = 2,
                element = { type = "string", maximumBytes = 8 } },
            { name = "enabled", type = "optional", value = { type = "boolean" } }
        ) },
        { name = "tail", type = "optional", value = { type = "string", maximumBytes = 8 } }
    ) },
    UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", fields = ordered(
        { name = "values", type = "set", maximumSize = 3,
            element = { type = "i16", minimum = -5, maximum = 5 } }
    ) },
    State = { id = 3, direction = "ServerToClient", fields = ordered(
        { name = "value", type = "optional", value = { type = "string", maximumBytes = 8 } }
    ) },
    UnreliableState = { id = 4, direction = "ServerToClient", delivery = "Unreliable", fields = ordered(
        { name = "mode", type = "enum", values = ordered("Ready", "Busy") }
    ) },
} }))
local codecCompiled = Definition.get(codecDefinition)
local function encode(event, ...)
    local result = table.pack(Frame.compile(event, "encode")(...))
    assert(result[1] == true)
    return result[2]
end
local validInput = encode(codecCompiled.byId[1], {
    mode = "Run", values = { 1, 3 }, labels = { alpha = true }, enabled = false,
}, nil)
local wrongInnerEndpoint = buffer.create(buffer.len(validInput))
buffer.copy(wrongInnerEndpoint, 0, validInput, 0, buffer.len(validInput))
buffer.writeu16(wrongInnerEndpoint, 1, 3)
local invalidTailTag = buffer.create(buffer.len(validInput))
buffer.copy(invalidTailTag, 0, validInput, 0, buffer.len(validInput))
buffer.writeu8(invalidTailTag, buffer.len(invalidTailTag) - 1, 2)

runtime = Runtime.new()
local malformedPlayer, admittedPlayer, aggregateBlockedPlayer =
    runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
server = assert(runtime.server.create(codecDefinition, options(2, 3)))
local compositeCalls = {}
assert(server.events.Input:Connect(function(sender, payload, ...)
    local tail = table.pack(...)
    table.insert(compositeCalls, { sender = sender, payload = payload, tail = tail[1], n = tail.n })
end))
assert(server:Start())
local compositeRemote = runtime:remote()
compositeRemote.OnServerEvent:Fire(malformedPlayer, 1, wrongInnerEndpoint)
compositeRemote.OnServerEvent:Fire(malformedPlayer, 1, invalidTailTag)
compositeRemote.OnServerEvent:Fire(malformedPlayer, 1, validInput)
compositeRemote.OnServerEvent:Fire(admittedPlayer, 1, validInput)
compositeRemote.OnServerEvent:Fire(aggregateBlockedPlayer, 1, validInput)
assert(#compositeCalls == 1 and compositeCalls[1].sender == admittedPlayer)
assert(compositeCalls[1].payload.mode == "Run" and compositeCalls[1].payload.enabled == false
    and compositeCalls[1].tail == nil and compositeCalls[1].n == 1,
    "malformed composite input consumes player and aggregate admission before dispatch")
assert(server.events.State:Send(admittedPlayer, "ok"))
assert(server.events.State:Broadcast(nil))
assert(#runtime.fires == 2 and runtime.fires[1].kind == "target" and runtime.fires[2].kind == "broadcast")
for _, sent in runtime.fires do
    assert(sent.values.n == 2 and sent.values[1] == 3 and typeof(sent.values[2]) == "buffer",
        "composite target and broadcast each send endpoint plus one buffer")
end
server:Destroy()

-- Composite unreliable ingress remains bound to its declared physical channel.
runtime = Runtime.new()
player = runtime:addPlayer()
server = assert(runtime.server.create(codecDefinition, options()))
local unreliableCompositeCalls = 0
assert(server.events.UnreliableInput:Connect(function(sender, values)
    assert(sender == player and values[-2] and values[3])
    unreliableCompositeCalls += 1
end))
assert(server:Start())
local unreliableInput = encode(codecCompiled.byId[2], { [-2] = true, [3] = true })
runtime:unreliableRemote().OnServerEvent:Fire(player, 2, unreliableInput)
runtime:remote().OnServerEvent:Fire(player, 2, unreliableInput)
assert(unreliableCompositeCalls == 1, "wrong-channel composite frames do not dispatch")
server:Destroy()

-- Audience methods validate once and leave caller lists untouched.
do
    local rt = Runtime.new()
    local first, second, third = rt:addPlayer(), rt:addPlayer(), rt:addPlayer()
    first.UserId, second.UserId = 1, 1
    local session = assert(rt.server.create(mixedDefinition, options()))
    assert(session.events.Input.SendTo == nil and session.events.Input.SendExcept == nil)
    local ok, err, sent = session.events.State:SendTo(nil, "bad")
    errorCode(ok, err, "NotStarted")
    assert(sent == 0 and rt.validationCalls == 0)
    assert(session:Start())
    local departed = rt:addPlayer()
    rt:removePlayer(departed)
    local recipients = table.freeze({ first, second, first, departed })
    ok, err, sent = session.events.State:SendTo(recipients, 7)
    assert(ok and err == nil and sent == 2 and #rt.fires == 2 and rt.validationCalls == 1)
    assert(recipients[1] == first and recipients[2] == second and recipients[3] == first
        and recipients[4] == departed and #recipients == 4, "audience input remains unchanged")
    local delivered = {}
    for _, handoff in rt.fires do
        delivered[handoff.player] = true
        assert(handoff.kind == "target" and handoff.remote == rt:remote()
            and handoff.values.n == 2 and handoff.values[1] == 4 and handoff.values[2] == 7)
    end
    assert(delivered[first] and delivered[second] and not delivered[third] and not delivered[departed])
    table.clear(rt.fires)
    local excluded = table.freeze({ second, second, departed })
    ok, err, sent = session.events.UnreliableState:SendExcept(excluded, false)
    assert(ok and err == nil and sent == 2 and #rt.fires == 2 and rt.validationCalls == 2)
    delivered = {}
    for _, handoff in rt.fires do
        delivered[handoff.player] = true
        assert(handoff.remote == rt:unreliableRemote() and handoff.values.n == 2
            and handoff.values[1] == 5 and handoff.values[2] == false)
    end
    assert(delivered[first] and delivered[third] and not delivered[second] and #excluded == 3)
    table.clear(rt.fires)
    for _, method in { "SendTo", "SendExcept" } do
        local empty = if method == "SendTo" then {} else { first, second, third }
        ok, err, sent = session.events.State[method](session.events.State, empty, "bad")
        errorCode(ok, err, "InvalidPayload")
        assert(sent == 0 and #rt.fires == 0)
        ok, err, sent = session.events.State[method](session.events.State, empty, 7)
        assert(ok and err == nil and sent == 0 and #rt.fires == 0)
        ok, err, sent = session.events.UnreliableState[method](session.events.UnreliableState, { first }, false, nil)
        errorCode(ok, err, "InvalidPayload")
        assert(sent == 0 and #rt.fires == 0, "explicit trailing nil rejects before any handoff")
        ok, err, sent = session.events.EmptyUnreliableState[method](session.events.EmptyUnreliableState, { first })
        assert(ok and err == nil and sent == (if method == "SendTo" then 1 else 2))
        for _, handoff in rt.fires do
            assert(handoff.remote == rt:unreliableRemote() and handoff.values.n == 1
                and handoff.values[1] == 6, "empty tuples have no nil padding")
        end
        table.clear(rt.fires)
    end
    local validationCalls = rt.validationCalls
    for _, malformed in {
        false, "players", { first, {}, second }, { [2] = first }, { [1] = first, [3] = second },
        { first, extra = second }, { [0] = first }, { [1.5] = first }, { [math.huge] = first },
        { rt.newInstance("Folder") }, setmetatable({ first }, {}),
        setmetatable({}, { __iter = function() error("must reject before iteration") end }),
        table.create(1025, first),
    } do
        for _, method in { "SendTo", "SendExcept" } do
            ok, err, sent = session.events.State[method](session.events.State, malformed, "bad")
            errorCode(ok, err, "InvalidAudience")
            assert(sent == 0 and #rt.fires == 0 and rt.validationCalls == validationCalls,
                "invalid audiences reject before validation and handoff")
        end
    end
    for _, method in { "SendTo", "SendExcept" } do
        ok, err, sent = session.events.State[method](session.events.State, nil, 7)
        errorCode(ok, err, "InvalidAudience")
        assert(sent == 0 and rt.validationCalls == validationCalls)
    end
    ok, err, sent = session.events.State:SendTo(table.create(1024, first), 7)
    assert(ok and err == nil and sent == 1 and #rt.fires == 1, "the input bound counts duplicates")
    table.clear(rt.fires)
    ok, err, sent = session.events.State:SendExcept(table.create(1024, first), 7)
    assert(ok and err == nil and sent == 2 and #rt.fires == 2)
    table.clear(rt.fires)
    assert(session.events.State:Broadcast(9))
    assert(#rt.fires == 1 and rt.fires[1].kind == "broadcast",
        "full Broadcast stays one native FireAllClients call")
    session:Destroy()
    ok, err, sent = session.events.State:SendExcept(nil, "bad")
    errorCode(ok, err, "Destroyed")
    assert(sent == 0)
end

-- Composite audiences reuse one buffer and retain false plus an explicit nil root.
do
    local rt = Runtime.new()
    local first, second, third = rt:addPlayer(), rt:addPlayer(), rt:addPlayer()
    local token = assert(Definition.define({ name = "AudienceCodec", version = 1, events = {
        State = { id = 1, direction = "ServerToClient", fields = ordered(
            { name = "enabled", type = "optional", value = { type = "boolean" } },
            { name = "tail", type = "optional", value = { type = "string", maximumBytes = 8 } }
        ) },
    } }))
    local session = assert(rt.server.create(token, options()))
    local decode = Frame.compile(Definition.get(token).byId[1], "decode")
    assert(session:Start())
    for _, method in { "SendTo", "SendExcept" } do
        local audience = if method == "SendTo" then { first, second, third } else {}
        local previousCalls = rt.validationCalls
        local ok, err, sent = session.events.State[method](session.events.State, audience, false, nil)
        assert(ok and err == nil and sent == 3 and rt.validationCalls == previousCalls + 1)
        local encoded = rt.fires[1].values[2]
        for _, handoff in rt.fires do
            assert(handoff.values.n == 2 and handoff.values[1] == 1 and handoff.values[2] == encoded,
                "each recipient receives the exact same encoded buffer")
        end
        local decoded = table.pack(decode(encoded))
        assert(decoded.n == 3 and decoded[1] and decoded[2] == false and decoded[3] == nil)
        table.clear(rt.fires)
        ok, err, sent = session.events.State[method](session.events.State, audience, false)
        errorCode(ok, err, "InvalidPayload")
        assert(sent == 0 and #rt.fires == 0, "missing optional root still violates exact arity")
    end
    session:Destroy()
end

-- Current identity and live parentage are rechecked before each handoff.
for _, method in { "SendTo", "SendExcept" } do
    local rt = Runtime.new()
    local first, second, third = rt:addPlayer(), rt:addPlayer(), rt:addPlayer()
    first.UserId, second.UserId = 1, 1
    local session = assert(rt.server.create(definition, options()))
    assert(session:Start())
    local targets = { first, second, third }
    local unrostered = rt.newInstance("Player")
    unrostered.Parent = rt.players
    local ok, err, sent = session.events.State:SendTo({ unrostered }, 1)
    assert(ok and err == nil and sent == 0 and #rt.fires == 0)
    rt.beforeFire = function(target)
        if #rt.fires == 0 then
            for _, candidate in targets do
                if candidate ~= target then
                    rt.deferred = true
                    rt:removePlayer(candidate)
                    rt.deferred = false
                end
            end
            table.clear(targets)
        end
    end
    ok, err, sent = session.events.State[method](session.events.State,
        if method == "SendTo" then targets else {}, 1)
    assert(ok and err == nil and sent == 1 and #rt.fires == 1,
        "snapshot ownership survives caller edits while newly departed targets are skipped")
    rt:flush()
    session:Destroy()
end

-- Handoff failure and observed mutation stop fanout with successful-call counts.
for _, method in { "SendTo", "SendExcept" } do
    for position = 1, 3 do
        for _, throwing in { false, true } do
            local rt = Runtime.new()
            local recipients = { rt:addPlayer(), rt:addPlayer(), rt:addPlayer() }
            local session = assert(rt.server.create(definition, options()))
            assert(session:Start())
            local root = rt.storage:FindFirstChild("RelayRemotes")
            rt.beforeFire = function()
                if #rt.fires + 1 == position then
                    root.Name = "Changed"
                    rt.throwFire = throwing
                end
            end
            local ok, err, sent = session.events.State[method](session.events.State,
                if method == "SendTo" then recipients else {}, 1)
            errorCode(ok, err, if throwing then "TransportFailure" else "Destroyed")
            assert(sent == (if throwing then position - 1 else position) and #rt.fires == sent,
                "only returning calls count, including a final call that observes terminal mutation")
            assert(rt.connections == 0)
        end
    end
    local rt = Runtime.new()
    local recipients = { rt:addPlayer(), rt:addPlayer(), rt:addPlayer() }
    local session = assert(rt.server.create(definition, options()))
    assert(session:Start())
    rt.beforeFire = function() rt.throwFire = #rt.fires == 1 end
    local ok, err, sent = session.events.State[method](session.events.State,
        if method == "SendTo" then recipients else {}, 1)
    errorCode(ok, err, "TransportFailure")
    assert(sent == 1 and #rt.fires == 1, "a throwing middle handoff aborts the remaining targets")
    rt.beforeFire, rt.throwFire = nil, false
    table.clear(rt.fires)
    ok, err, sent = session.events.State[method](session.events.State,
        if method == "SendTo" then recipients else {}, 1)
    assert(ok and err == nil and sent == 3, "transport failure alone does not destroy an intact session")
    session:Destroy()
end

-- Empty audiences retain validation precedence and synchronous integrity checks.
for _, method in { "SendTo", "SendExcept" } do
    local rt = Runtime.new()
    local session = assert(rt.server.create(definition, options()))
    assert(session:Start())
    rt.deferred = true
    rt.storage:FindFirstChild("RelayRemotes").Name = "Changed"
    local ok, err, sent = session.events.State[method](session.events.State, {}, "bad")
    errorCode(ok, err, "InvalidPayload")
    assert(sent == 0)
    ok, err, sent = session.events.State[method](session.events.State, {}, 1)
    errorCode(ok, err, "Destroyed")
    assert(sent == 0 and #rt.fires == 0)
    rt:flush()
end

-- Deferred sibling observation preserves the existing success window.
for _, method in { "SendTo", "SendExcept" } do
    local rt = Runtime.new()
    local recipients = { rt:addPlayer(), rt:addPlayer(), rt:addPlayer() }
    local sibling = rt.newInstance("Folder")
    sibling.Name = "Other"
    sibling.Parent = rt.storage
    local session = assert(rt.server.create(definition, options()))
    assert(session:Start())
    rt.deferred = true
    rt.beforeFire = function() sibling.Name = "RelayRemotes" end
    local ok, err, sent = session.events.State[method](session.events.State,
        if method == "SendTo" then recipients else {}, 1)
    assert(ok and err == nil and sent == 3 and #rt.fires == 3)
    rt:flush()
    rt.deferred = false
    ok, err, sent = session.events.State[method](session.events.State, {}, 1)
    errorCode(ok, err, "Destroyed")
    assert(sent == 0 and not sibling.destroyed and rt.connections == 0)
end

-- SendExcept bounds the eligible roster independently of its exclusion list.
do
    local rt = Runtime.new()
    local recipients = {}
    for index = 1, 1025 do recipients[index] = rt:addPlayer() end
    local session = assert(rt.server.create(definition, options()))
    assert(session:Start())
    local ok, err, sent = session.events.State:SendExcept({}, "bad")
    errorCode(ok, err, "InvalidAudience")
    assert(sent == 0 and #rt.fires == 0 and rt.validationCalls == 0)
    ok, err, sent = session.events.State:SendExcept({ recipients[1] }, 1)
    assert(ok and err == nil and sent == 1024 and #rt.fires == 1024 and rt.validationCalls == 1)
    session:Destroy()
end

-- Diagnostics count first rejection, fixed handoff units, and Once lease behavior.
do
    local rt = Runtime.new()
    local first, second = rt:addPlayer(), rt:addPlayer()
    local session = assert(rt.server.create(mixedDefinition, options()))
    assert(session.events.Input.Once ~= nil and session.events.State.Once == nil)

    local onceCalls, onceThread = 0, nil
    local onceConnection = assert(session.events.Input:Once(function()
        onceCalls += 1
        onceThread = coroutine.running()
        coroutine.yield()
        error("once handler failure")
    end))
    assert(session:Start())
    local beforeSnapshot = session:GetDiagnostics()
    assert(beforeSnapshot.side == "Server" and beforeSnapshot.state == "Started"
        and beforeSnapshot.inFlight == 0 and beforeSnapshot.inboundRate.perPlayer.capacity == 4096
        and beforeSnapshot.handlerLimits.perPlayerEndpoint == 1 and beforeSnapshot.handlerLimits.global == 64)
    assert(table.isfrozen(beforeSnapshot) and table.isfrozen(beforeSnapshot.counters)
        and table.isfrozen(beforeSnapshot.events.Input))

    local remote, unreliableRemote = rt:remote(), rt:unreliableRemote()
    remote.OnServerEvent:Fire(first, 999)
    unreliableRemote.OnServerEvent:Fire(first, 1, 1)
    unreliableRemote.OnServerEvent:Fire(first, 2, false)
    local unrostered = rt.newInstance("Player")
    unrostered.Parent = rt.players
    remote.OnServerEvent:Fire(unrostered, 1, 1)
    remote.OnServerEvent:Fire(first, 1, "bad")
    remote.OnServerEvent:Fire(first, 1, 1)
    local replacementCalls = 0
    local replacement = assert(session.events.Input:Connect(function()
        replacementCalls += 1
    end))
    remote.OnServerEvent:Fire(first, 1, 1)
    assert(onceCalls == 1 and replacementCalls == 0, "Once must detach before the yielding callback")
    assert(session:GetDiagnostics().inFlight == 1)
    remote.OnServerEvent:Fire(second, 1, 1)
    assert(replacementCalls == 1, "a different player may reach a replacement listener")
    assert(coroutine.resume(onceThread), "the protected one-shot error must stay contained")
    onceConnection:Disconnect()

    assert(session.events.State:Send(first, 1))
    assert(session.events.State:Broadcast(2))
    local ok, err, sent = session.events.State:SendTo({ first, second }, 3)
    assert(ok and err == nil and sent == 2)
    rt.beforeFire = function(target)
        if target == second then rt.throwFire = true end
    end
    ok, err, sent = session.events.State:SendTo({ first, second }, 4)
    errorCode(ok, err, "TransportFailure")
    assert(sent == 1, "partial audience handoffs retain the successful FireClient count")
    rt.beforeFire, rt.throwFire = nil, false

    local clockReads = rt.clockReads
    local snapshot = session:GetDiagnostics()
    assert(rt.clockReads == clockReads, "snapshotting must not sample the server clock")
    assert(snapshot.counters.received == 8 and snapshot.counters.invalidEndpoint == 1
        and snapshot.counters.wrongChannel == 1 and snapshot.counters.noListener == 1
        and snapshot.counters.ineligible == 1 and snapshot.counters.invalidPayload == 1
        and snapshot.counters.busy == 1 and snapshot.counters.dispatched == 2
        and snapshot.counters.handlerErrors == 1)
    assert(snapshot.events.Input.invalidPayload == 1 and snapshot.events.Input.busy == 1
        and snapshot.events.Input.dispatched == 2
        and snapshot.events.Input.handlerErrors == 1 and snapshot.events.UnreliableInput.noListener == 1)
    assert(snapshot.counters.sendHandoffs == 4 and snapshot.counters.broadcastHandoffs == 1
        and snapshot.counters.transportFailures == 1)
    assert(snapshot.events.State.sendHandoffs == 4 and snapshot.events.State.broadcastHandoffs == 1
        and snapshot.events.State.transportFailures == 1)

    local oldBroadcasts = snapshot.counters.broadcastHandoffs
    assert(session.events.State:Broadcast(5))
    assert(snapshot.counters.broadcastHandoffs == oldBroadcasts
        and session:GetDiagnostics().counters.broadcastHandoffs == oldBroadcasts + 1,
        "snapshots must remain unchanged after later traffic")

    rt.storage:FindFirstChild("RelayRemotes").Name = "Changed"
    local terminal = session:GetDiagnostics()
    assert(terminal.state == "Destroyed" and terminal.inFlight == 0
        and terminal.counters.transportLosses == 1)
    session:Destroy()
    assert(session:GetDiagnostics().counters.transportLosses == 1)
end

-- The two rate counters retain player-before-aggregate charging with one clock sample.
do
    local rt = Runtime.new()
    local first, second = rt:addPlayer(), rt:addPlayer()
    local session = assert(rt.server.create(definition, options(1, 1)))
    assert(session.events.Input1:Connect(function() end))
    assert(session:Start())
    local remote = rt:remote()
    local reads = rt.clockReads
    remote.OnServerEvent:Fire(first, 1, 1)
    assert(rt.clockReads == reads + 1)
    remote.OnServerEvent:Fire(second, 1, 1)
    assert(rt.clockReads == reads + 2)
    remote.OnServerEvent:Fire(first, 1, 1)
    assert(rt.clockReads == reads + 3)
    local snapshot = session:GetDiagnostics()
    assert(snapshot.counters.dispatched == 1 and snapshot.counters.aggregateRate == 1
        and snapshot.counters.perPlayerRate == 1,
        "player exhaustion must be counted separately and leave aggregate charging unchanged")
    session:Destroy()
    assert(session:GetDiagnostics().counters.transportLosses == 0, "explicit Destroy is not transport loss")
end

print("PASS Relay.ServerSession")
