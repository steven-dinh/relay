local Definition = require("../src/Definition")
local Runtime = require("./support/ServerRuntime")

local spec = { name = "ServerTest", version = 1, events = {} }
for id = 1, 9 do
    spec.events[`Input{id}`] = { id = id, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } }
end
spec.events.State = { id = 10, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } }
local definition = assert(Definition.define(spec))
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
remote.OnServerEvent:Fire(player, 1, 4)
remote.OnServerEvent:Fire(player, 1, {})
remote.OnServerEvent:Fire(player, 1, 4, nil)
remote.OnServerEvent:Fire(player, 10, 4)
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
remote.OnServerEvent:Fire(honest, 1, 1)
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
for _ = 1, 20 do remote.OnServerEvent:Fire(hostile, 1, 1) end
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
server:Destroy()
assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)

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
    assert(server.events[`Input{id}`]:Connect(function()
        table.insert(playerThreads, coroutine.running())
        coroutine.yield()
    end))
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

-- Synchronous identity checks close the deferred-signal window; contaminated leaves survive.
for _, mutate in {
    function(rt, root) root.Name = "Changed" end,
    function(rt, root) root.Parent = nil end,
    function(rt, root) root:GetChildren()[1].Value = "Changed" end,
    function(rt, root) rt:remote().Name = "Changed" end,
    function(rt, root) local child = rt.newInstance("Folder"); child.Parent = root end,
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
runtime = Runtime.new()
server = assert(runtime.server.create(definition, options()))
assert(server:Start())
local root = runtime.storage:GetChildren()[1]
remote = runtime:remote()
local foreign = runtime.newInstance("Folder")
foreign.Parent = remote
server:Destroy()
assert(not foreign.destroyed and not remote.destroyed and not root.destroyed)
local nextServer = assert(runtime.server.create(definition, options()))
expectError("RemoteOwnershipConflict", nextServer:Start())
assert(not foreign.destroyed)

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
print("PASS Relay.ServerSession")
