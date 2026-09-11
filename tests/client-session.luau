local Definition = require("../src/Definition")
local Runtime = require("./support/ClientRuntime")

local definition = assert(Definition.define({
    name = "ClientProof", version = 1,
    events = {
        Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
        State = { id = 2, direction = "ServerToClient", fields = {
            { name = "sequence", type = "u32" }, { name = "enabled", type = "boolean" },
        } },
    },
}))
local descriptor = Definition.get(definition).descriptor
local options = { startupTimeoutSeconds = 3 }

local function code(expected, _, failure)
    assert(failure and failure.code == expected, `expected {expected}, got {if failure then failure.code else "success"}`)
    assert(table.isfrozen(failure))
end

local function setup()
    local runtime = Runtime.create()
    local root, value, remote = runtime:transport(descriptor)
    local client = assert(runtime.module.create(definition, options))
    return runtime, client, root, value, remote
end

code("WrongRuntimeSide", require("../src/ClientSession").create({}, {}))

do
    local runtime = Runtime.create()
    runtime.client = false
    code("WrongRuntimeSide", runtime.module.create({}, {}))
    runtime.client = true
    code("InvalidDefinition", runtime.module.create({}, {}))
    for _, invalid in { {}, { startupTimeoutSeconds = 0 }, { startupTimeoutSeconds = 61 },
        { startupTimeoutSeconds = math.huge }, { startupTimeoutSeconds = 0 / 0 },
        { startupTimeoutSeconds = 1, extra = true }, setmetatable({ startupTimeoutSeconds = 1 }, {}) } do
        code("InvalidOptions", runtime.module.create(definition, invalid))
    end
    local client = assert(runtime.module.create(definition, options))
    assert(runtime.connections == 0)
    code("NotStarted", client.events.Input:Send(1))
    code("InvalidHandler", client.events.State:Connect(false))
    code("StartupTimeout", client:Start())
    assert(runtime.now == 3 and runtime.connections == 0)
    code("Destroyed", client:Start())
    code("Destroyed", client.events.Input:Send(false))
    code("Destroyed", client.events.State:Connect(false))
end

for _, mutation in {
    function(_, root) root.ClassName = "Model" end,
    function(_, _, value) value.ClassName = "Folder" end,
    function(_, _, _, remote) remote.ClassName = "UnreliableRemoteEvent" end,
    function(runtime, root) runtime:instance("Folder", "Extra", root) end,
    function(runtime, root) runtime:instance("RemoteEvent", "Reliable", root) end,
    function(runtime) runtime:instance("Folder", "RelayRemotes", runtime.storage) end,
} do
    local runtime, client, root, value, remote = setup()
    mutation(runtime, root, value, remote)
    code("RemoteOwnershipConflict", client:Start())
    assert(runtime.connections == 0 and root.Parent == runtime.storage)
end

do
    local runtime, client, _, value = setup()
    value.Value = "different"
    code("DefinitionMismatch", client:Start())
    assert(runtime.connections == 0)
end

do
    local runtime, client, root, value = setup()
    value.Value = "different"
    runtime:instance("Folder", "Extra", root)
    code("RemoteOwnershipConflict", client:Start())
    assert(runtime.connections == 0)
end

do
    local runtime = Runtime.create()
    local client = assert(runtime.module.create(definition, options))
    local steps = 0
    runtime.onWait = function(parent, name, remaining)
        steps += 1
        assert(remaining == 4 - steps)
        runtime.now += 1
        if name == "RelayRemotes" then
            runtime:instance("Folder", name, parent)
        elseif name == "Definition" then
            runtime:instance("StringValue", name, parent).Value = descriptor
        end
    end
    code("StartupTimeout", client:Start())
    assert(runtime.now == 3 and steps == 3)
end

do
    local runtime = Runtime.create()
    local client = assert(runtime.module.create(definition, options))
    runtime.onWait = function() coroutine.yield() end
    local result
    local thread = coroutine.create(function() result = table.pack(client:Start()) end)
    assert(coroutine.resume(thread))
    code("AlreadyStarted", client:Start())
    local loser = assert(runtime.module.create(definition, options))
    code("AlreadyStarted", loser:Start())
    code("Destroyed", loser:Start())
    client:Destroy()
    runtime:transport(descriptor)
    local replacement = assert(runtime.module.create(definition, options))
    assert(replacement:Start())
    local connectionCount = runtime.connections
    assert(coroutine.resume(thread))
    code("Destroyed", table.unpack(result, 1, result.n))
    assert(runtime.connections == connectionCount)
    replacement:Destroy()
    assert(runtime.connections == 0)
end

do
    local runtime, client, root, _, remote = setup()
    assert(table.isfrozen(client) and table.isfrozen(client.events) and table.isfrozen(client.events.Input))
    assert(client.events.Input.Connect == nil and client.events.State.Send == nil)
    local deliveries = {}
    local connection = assert(client.events.State:Connect(function(...) table.insert(deliveries, table.pack(...)) end))
    assert(table.isfrozen(connection))
    code("AlreadyConnected", client.events.State:Connect(function() end))
    code("InvalidHandler", client.events.State:Connect(false))
    assert(client:Start())
    code("AlreadyStarted", client:Start())
    assert(client.events.Input:Send(4))
    assert(#runtime.fires == 1 and runtime.fires[1].n == 2 and runtime.fires[1][1] == 1 and runtime.fires[1][2] == 4)
    code("InvalidPayload", client.events.Input:Send(256))
    code("InvalidPayload", client.events.Input:Send(4, nil))
    assert(#runtime.fires == 1)
    remote.OnClientEvent:fire(1, 4)
    remote.OnClientEvent:fire(2, 1, true, nil)
    remote.OnClientEvent:fire(2, 1, "true")
    remote.OnClientEvent:fire(99)
    remote.OnClientEvent:fire(2, 1, false)
    remote.OnClientEvent:fire(2, 2, true)
    assert(#deliveries == 2 and deliveries[1].n == 2 and deliveries[1][1] == 1 and deliveries[1][2] == false)
    connection:Disconnect()
    connection:Disconnect()
    remote.OnClientEvent:fire(2, 3, true)
    assert(#deliveries == 2)
    local replacement = assert(client.events.State:Connect(function() error("handler error") end))
    remote.OnClientEvent:fire(2, 3, true)
    replacement:Disconnect()
    assert(client.events.State:Connect(function() table.insert(deliveries, {}) end))
    remote.OnClientEvent:fire(2, 4, true)
    assert(#deliveries == 3)
    runtime.failFire = true
    code("TransportFailure", client.events.Input:Send(4))
    runtime.failFire = false
    assert(client.events.Input:Send(4))
    local staleCallbacks = remote.OnClientEvent:snapshot()
    client:Destroy()
    for _, callback in staleCallbacks do callback(2, 5, true) end
    assert(#deliveries == 3 and runtime.connections == 0 and root.Parent == runtime.storage)
    client:Destroy()
end

do
    local _, client, _, _, remote = setup()
    local calls = 0
    local first = assert(client.events.State:Connect(function()
        calls += 1
        coroutine.yield()
    end))
    assert(client:Start())
    local threads = remote.OnClientEvent:fire(2, 1, true)
    remote.OnClientEvent:fire(2, 2, true)
    assert(calls == 1)
    first:Disconnect()
    assert(client.events.State:Connect(function() calls += 1 end))
    remote.OnClientEvent:fire(2, 3, true)
    assert(calls == 1, "disconnect/replacement must not release a running endpoint")
    assert(coroutine.resume(threads[1]))
    remote.OnClientEvent:fire(2, 4, true)
    assert(calls == 2)
    client:Destroy()
end

for _, mutate in {
    function(_, root) root.Name = "Changed" end,
    function(_, root) root.Parent = nil end,
    function(_, _, value) value.Value = "changed" end,
    function(_, _, value) value.Name = "Changed" end,
    function(_, _, _, remote) remote.Parent = nil end,
    function(_, _, _, remote) remote:Destroy() end,
    function(runtime, root) runtime:instance("Folder", "Extra", root) end,
    function(runtime) runtime:instance("Folder", "RelayRemotes", runtime.storage) end,
} do
    local runtime, client, root, value, remote = setup()
    assert(client:Start())
    mutate(runtime, root, value, remote)
    code("Disconnected", client:Start())
    code("Disconnected", client.events.Input:Send(4))
    code("Disconnected", client.events.State:Connect(false))
    assert(runtime.connections == 0)
    local replacement = assert(runtime.module.create(definition, options))
    local _, failure = replacement:Start()
    assert(not failure or failure.code ~= "AlreadyStarted", "disconnect must release module slot")
    replacement:Destroy()
    client:Destroy()
end

do
    local runtime, client, root = setup()
    assert(client:Start())
    runtime.silent = true
    root.Name = "Changed"
    code("Disconnected", client.events.Input:Send(4))
    assert(#runtime.fires == 0 and runtime.connections == 0)
end

do
    local runtime, client, root, _, remote = setup()
    assert(client:Start())
    runtime.deferred = true
    remote.Parent = nil
    runtime:instance("RemoteEvent", "Reliable", root)
    assert(#root:GetChildren() == 2, "replacement preserves the child count")
    code("InvalidPayload", client.events.Input:Send("bad"))
    assert(#runtime.fires == 0, "invalid payload must precede deferred integrity failure")
    code("Disconnected", client.events.Input:Send(4))
    runtime:flush()
    assert(#runtime.fires == 0 and runtime.connections == 0)
end

for _, mutateAndRestore in {
    function(_, root) root.Name = "Temporary"; root.Name = "RelayRemotes" end,
    function(_, _, value) value.Name = "Temporary"; value.Name = "Definition" end,
    function(_, _, _, remote) remote.Name = "Temporary"; remote.Name = "Reliable" end,
    function(_, _, value) value.Value = "temporary"; value.Value = descriptor end,
    function(runtime, root) root.Parent = nil; root.Parent = runtime.storage end,
    function(_, root, value) value.Parent = nil; value.Parent = root end,
    function(_, root, _, remote) remote.Parent = nil; remote.Parent = root end,
    function(runtime, root)
        local extra = runtime:instance("Folder", "Temporary", root)
        extra.Parent = nil
    end,
} do
    local runtime, client, root, value, remote = setup()
    assert(client:Start())
    runtime.deferred = true
    mutateAndRestore(runtime, root, value, remote)
    runtime:flush()
    code("Disconnected", client:Start())
    code("Disconnected", client.events.Input:Send(4))
    assert(runtime.connections == 0)
end

do
    local runtime, client, _, _, remote = setup()
    runtime:instance("Folder", "Unrelated", runtime.storage)
    assert(client.events.State:Connect(function() end))
    assert(client:Start())
    local scans = runtime.storageScans
    for _ = 1, 10 do
        remote.OnClientEvent:fire(2, 1, true)
        assert(client.events.Input:Send(4))
    end
    assert(runtime.storageScans == scans, "packet paths must not enumerate all ReplicatedStorage children")
    client:Destroy()
end

do
    local runtime, client, root, _, remote = setup()
    local calls = 0
    assert(client.events.State:Connect(function() calls += 1 end))
    assert(client:Start())
    local callbacks = remote.OnClientEvent:snapshot()
    runtime.silent = true
    root.Name = "Changed"
    for _, callback in callbacks do callback(2, 1, true) end
    assert(calls == 0 and runtime.connections == 0)
    code("Disconnected", client:Start())
end

do
    local runtime, client, root = setup()
    assert(client:Start())
    runtime.onFire = function() root.Parent = nil end
    runtime.failFire = true
    code("TransportFailure", client.events.Input:Send(4))
    code("Disconnected", client.events.Input:Send(4))
    assert(runtime.connections == 0 and #runtime.fires == 0)
end

do
    local runtime, client, _, _, remote = setup()
    local calls = 0
    assert(client.events.State:Connect(function()
        calls += 1
        coroutine.yield()
    end))
    assert(client:Start())
    local threads = remote.OnClientEvent:fire(2, 1, true)
    client:Destroy()
    local replacement = assert(runtime.module.create(definition, options))
    assert(replacement.events.State:Connect(function() calls += 1 end))
    assert(replacement:Start())
    assert(coroutine.resume(threads[1]))
    remote.OnClientEvent:fire(2, 2, true)
    assert(calls == 2)
    replacement:Destroy()
    assert(runtime.connections == 0)
end

do
    local runtime, client = setup()
    runtime.failConnect = true
    code("TransportFailure", client:Start())
    assert(runtime.connections == 0)
    runtime.failConnect = false
    for _ = 1, 100 do
        local nextClient = assert(runtime.module.create(definition, options))
        assert(nextClient:Start())
        nextClient:Destroy()
        assert(runtime.connections == 0)
    end
end

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
    local rt = Runtime.create()
    local _, _, remote = rt:transport(Definition.get(token).descriptor)
    local client = assert(rt.module.create(token, options))
    local received, count = nil, 0
    assert(client.events.State:Connect(function(...)
        received = table.pack(...)
        count += 1
    end))
    assert(client:Start())
    remote.OnClientEvent:fire(2, table.unpack(input, 1, arity))
    remote.OnClientEvent:fire(2, table.unpack(input, 1, arity + 1))
    assert(count == 1 and received.n == arity, "client must dispatch the exact normalized tuple")
    assert(client.events.Input:Send(table.unpack(input, 1, arity)))
    code("InvalidPayload", client.events.Input:Send(table.unpack(input, 1, arity + 1)))
    assert(#rt.fires == 1 and rt.fires[1].n == arity + 1 and rt.fires[1][1] == 1)
    for index = 1, arity do
        assert(rt.fires[1][index + 1] == expected[index] and received[index] == expected[index])
    end
    client:Destroy()
end

do
    local rt, client, _, _, remote = setup()
    local calls, retained = 0, nil
    assert(client.events.State:Connect(function(sequence, enabled, ...)
        calls += 1
        remote.OnClientEvent:fire(2, 99, true)
        assert(client.events.Input:Send(7))
        coroutine.yield()
        retained = table.pack(sequence, enabled, ...)
    end))
    assert(client:Start())
    local threads = remote.OnClientEvent:fire(2, 1, false)
    remote.OnClientEvent:fire(2, 2, true)
    assert(calls == 1 and #rt.fires == 1, "reentrant receive must keep the endpoint busy while sends remain independent")
    assert(coroutine.resume(threads[1]))
    assert(retained.n == 2 and retained[1] == 1 and retained[2] == false, "yielding client handler must retain its tuple")
    client:Destroy()
end
print("PASS Relay.ClientSession lifecycle, discovery, tuples, dispatch leases, and cleanup")
