local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local NativeRuntime = require("./support/NativeCodec")
local ServerRuntime = require("./support/ServerRuntime")
local ClientRuntime = require("./support/ClientRuntime")

local world = NativeRuntime.World
local scope = roblox.Instance.new("Folder")
scope.Parent = world
local outside = roblox.Instance.new("Folder")
outside.Parent = world
local part = roblox.Instance.new("Part")
part.Parent = scope
local other = roblox.Instance.new("Part")
other.Parent = scope
local outsidePart = roblox.Instance.new("Part")
outsidePart.Parent = outside
local wrongClass = roblox.Instance.new("Folder")
wrongClass.Parent = scope

local function event(id, direction, delivery, queue, many)
    local shape = { type = "Instance", className = "BasePart" }
    if many then shape = { type = "array", element = shape, maximumLength = 16 } end
    shape.name = "target"
    return { id = id, direction = direction, delivery = delivery, queue = queue, fields = { shape } }
end
local definition = assert(Definition.define({ name = "InstanceRoutes", version = 1, events = {
    UnreliableIn = event(1, "ClientToServer", "Unreliable"),
    UnreliableOut = event(2, "ServerToClient", "Unreliable"),
    OrderedIn = event(3, "ClientToServer", "OrderedUnreliable"),
    OrderedOut = event(4, "ServerToClient", "OrderedUnreliable"),
    BatchIn = event(5, "ClientToServer", "Reliable", "Batch"),
    BatchOut = event(6, "ServerToClient", "Unreliable", "Batch"),
    StateIn = event(7, "ClientToServer", "Unreliable", "State"),
    StateOut = event(8, "ServerToClient", "Reliable", "State"),
    ManyIn = event(9, "ClientToServer", "Unreliable", nil, true),
    PlainIn = { id = 10, direction = "ClientToServer", queue = "State",
        fields = { { name = "value", type = "u8" } } },
    MixedRefIn = event(11, "ClientToServer", "Reliable", "State"),
} }))
local compiled = assert(Definition.get(definition))
local function options(capacity)
    return { instanceRoot = scope, inboundRate = {
        perPlayer = { capacity = 1024, refillPerSecond = 1 },
        aggregate = { capacity = 4096, refillPerSecond = 1 },
        bytes = {
            perPlayer = { capacity = capacity or 32768, refillPerSecond = 1 },
            aggregate = { capacity = capacity or 32768, refillPerSecond = 1 },
        },
    } }
end
local runtime = ServerRuntime.new()
local player, secondPlayer = runtime:addPlayer(), runtime:addPlayer()
local server = assert(runtime.server.create(definition, options()))
assert(server:Start())
local reliable, unreliable = runtime:remote(), runtime:unreliableRemote()
local clientRuntime = ClientRuntime.create()
local _, _, clientReliable, clientUnreliable = clientRuntime:transport(compiled.descriptor, true)
local client = assert(clientRuntime.module.create(definition, { startupTimeoutSeconds = 3 }))
local function forwardClient(transport, id, ...)
    local target = if transport.Name == "Unreliable" then unreliable else reliable
    target.OnServerEvent:Fire(player, id, ...)
end
clientRuntime.onFire = forwardClient
runtime.afterFire = function(target, id, ...)
    if target ~= player then return end
    local fired = runtime.fires[#runtime.fires]
    local remote = if fired.remote.ClassName == "UnreliableRemoteEvent" then clientUnreliable else clientReliable
    remote.OnClientEvent:fire(id, ...)
end
assert(client:Start(), "native reference stream initialization")
local received = {}
for _, name in { "UnreliableIn", "OrderedIn", "BatchIn", "StateIn", "ManyIn" } do
    assert(server.events[name]:Connect(function(sender, value)
        assert(sender == player)
        if name == "ManyIn" then
            assert(#value == 16)
            for _, reference in value do assert(reference == part) end
        else
            assert(value == part or value == other)
        end
        received[name] = (received[name] or 0) + 1
    end))
end
for _, name in { "UnreliableOut", "OrderedOut", "BatchOut", "StateOut" } do
    assert(client.events[name]:Connect(function(value)
        assert(value == part or value == other)
        received[name] = (received[name] or 0) + 1
    end))
end
assert(server.events.PlainIn:Connect(function(sender, value)
    assert(sender == player and value == 7)
    received.PlainIn = (received.PlainIn or 0) + 1
end))
assert(server.events.MixedRefIn:Connect(function(sender, value)
    assert(sender == player and value == part)
    received.MixedRefIn = (received.MixedRefIn or 0) + 1
end))

assert(client.events.UnreliableIn:Send(part))
assert(server.events.UnreliableOut:Send(player, part))
assert(received.UnreliableIn == 1 and received.UnreliableOut == 1)
assert(client.events.ManyIn:Send(table.create(16, part)) and received.ManyIn == 1,
    "checked reference envelopes admit sixteen sidecars beyond the ordinary argument cap")
assert(client.events.OrderedIn:Send(part))
local ordered = clientRuntime.fires[#clientRuntime.fires]
assert(buffer.readu8(ordered[2], 0) == 6 and ordered.n == 3)
local newer = buffer.create(buffer.len(ordered[2]))
buffer.copy(newer, 0, ordered[2])
buffer.writeu32(newer, 7, 2)
unreliable.OnServerEvent:Fire(player, 3, newer, wrongClass)
assert(received.OrderedIn == 1)
unreliable.OnServerEvent:Fire(player, 3, newer, part)
unreliable.OnServerEvent:Fire(player, 3, newer, part)
assert(received.OrderedIn == 2 and server:GetDiagnostics().events.OrderedIn.stale == 1,
    "a malformed ordered reference does not advance the stream high-water")
assert(server.events.OrderedOut:Send(player, part) and received.OrderedOut == 1)

local inputBatch = assert(client:CreateBatch(0.02))
assert(inputBatch.events.BatchIn:Send(part) and inputBatch.events.BatchIn:Send(other))
assert(inputBatch:Flush() and received.BatchIn == 2)
local batch = clientRuntime.fires[#clientRuntime.fires]
assert(batch[1] == 0 and batch.n == 4 and buffer.readu8(batch[2], 0) == 5
    and buffer.readu8(batch[2], 3) == 2, "queued local slots carry concatenated native sidecars")
local beforeInvalid = server:GetDiagnostics().counters.invalidPayload
reliable.OnServerEvent:Fire(player, 0, batch[2], part, outsidePart)
reliable.OnServerEvent:Fire(player, 0, batch[2], part, nil)
assert(received.BatchIn == 2 and server:GetDiagnostics().counters.invalidPayload == beforeInvalid + 2,
    "a bad late record or missing sidecar rejects the entire frame")
local outputBatch = assert(server:CreateBatch({ player }, 0.02))
assert(outputBatch.events.BatchOut:Send(part) and outputBatch:Flush() and received.BatchOut == 1)
local mixedBatch = assert(client:CreateBatch(0.02))
assert(mixedBatch.events.PlainIn:Send(7) and mixedBatch.events.MixedRefIn:Send(part))
assert(mixedBatch:Flush() and received.PlainIn == 1 and received.MixedRefIn == 1,
    "format5 FIFO frames decode ordinary and reference rows together")
local mixed = clientRuntime.fires[#clientRuntime.fires]
reliable.OnServerEvent:Fire(player, 0, mixed[2], outsidePart)
assert(received.PlainIn == 1 and received.MixedRefIn == 1,
    "a malformed late reference row cannot partially dispatch an earlier ordinary row")

local inputState = assert(client:CreateState(0.02))
assert(inputState.events.StateIn:Put(1, "Normal", part))
assert(inputState:GetStatus().pendingBodyBytes == 13, "retention charges eight units per sidecar")
assert(inputState.events.StateIn:Put(1, "High", other))
assert(inputState:Flush() and received.StateIn == 1 and inputState:GetStatus().pendingBodyBytes == 0)
assert(inputState.events.PlainIn:Put(2, "Normal", 7)
    and inputState.events.MixedRefIn:Put(3, "Normal", part))
assert(inputState:Flush() and received.PlainIn == 2 and received.MixedRefIn == 2,
    "format5 State frames decode mixed ordinary and reference rows atomically")
local outputState = assert(server:CreateState({ player }, 0.02))
assert(outputState.events.StateOut:Put(1, "Normal", part))
assert(outputState:Flush() and received.StateOut == 1)
local outputBroadcastState = assert(server:CreateBroadcastState(0.02))
assert(outputBroadcastState.events.StateOut:Put(2, "Normal", part))
local sharedStateOk, _, sharedStateReport = outputBroadcastState:Flush()
local sharedStateFire = runtime.fires[#runtime.fires]
local sharedStateReferences = { n = 1, sharedStateFire.values[3] }
local sharedStateHeader = assert(BatchFrame.header(sharedStateFire.values[2], 8_192, sharedStateReferences))
assert(sharedStateOk and sharedStateReport.selected == 1 and sharedStateReport.reliableHandoffs == 1
	and sharedStateReport.logicalHandoffs == 1 and sharedStateFire.kind == "broadcast"
	and sharedStateFire.remote == reliable and sharedStateFire.values.n == 3 and sharedStateFire.values[1] == 0
	and sharedStateFire.values[3] == part and sharedStateHeader.format == 5 and sharedStateHeader.kind == 2
	and sharedStateHeader.count == 1 and sharedStateHeader.referenceCount == 1,
	"shared State broadcasts preserve native Instance sidecars in the existing kind-2 format")

local moving = roblox.Instance.new("Part")
moving.Parent = scope
local outputBroadcast = assert(server:CreateBroadcastBatcher(0.02))
assert(outputBroadcast.events.BatchOut:Send(moving) and outputBroadcast:Flush()
	and received.BatchOut == 1, "shared queue broadcasts preserve native Instance sidecars")
local broadcastFire = runtime.fires[#runtime.fires]
local broadcastHeader = assert(BatchFrame.header(broadcastFire.values[2], 900,
	{ n = 1, broadcastFire.values[3] }))
assert(broadcastFire.kind == "broadcast" and broadcastFire.remote == unreliable
	and broadcastFire.values.n == 3 and broadcastFire.values[1] == 0
	and broadcastHeader.format == 5 and broadcastHeader.kind == 1
	and broadcastHeader.count == 1 and broadcastHeader.referenceCount == 1
	and broadcastFire.values[3] == moving,
	"one FireAllClients call carries the exact Instance reference sidecar")
assert(outputBroadcast.events.BatchOut:Send(moving))
moving.Parent = outside
local beforeInvalidBroadcast = #runtime.fires
local broadcastOk, broadcastProblem = outputBroadcast:Flush()
assert(not broadcastOk and broadcastProblem.code == "InvalidPayload"
	and #runtime.fires == beforeInvalidBroadcast and outputBroadcast:GetStatus().state == "Terminal",
	"broadcast flush rechecks Instance scope before native handoff and never replays")
moving.Parent = scope
local invalidState = assert(server:CreateState({ player }, 0.02))
assert(invalidState.events.StateOut:Put(1, "Normal", moving))
moving.Parent = outside
local handoffs = #runtime.fires
local ok, problem = invalidState:Flush()
assert(not ok and problem.code == "InvalidPayload" and #runtime.fires == handoffs
    and invalidState:GetStatus().pendingKeys == 0,
    "queued scope is rechecked and selected invalid work releases references without handoff")
moving.Parent = scope
local invalidBroadcastState = assert(server:CreateBroadcastState(0.02))
assert(invalidBroadcastState.events.StateOut:Put(1, "High", moving))
moving.Parent = outside
local beforeInvalidBroadcastState = #runtime.fires
local invalidBroadcastOk, invalidBroadcastProblem, invalidBroadcastReport = invalidBroadcastState:Flush()
assert(not invalidBroadcastOk and invalidBroadcastProblem.code == "InvalidPayload"
	and invalidBroadcastReport.selected == 1 and invalidBroadcastReport.reliableHandoffs == 0
	and #runtime.fires == beforeInvalidBroadcastState and invalidBroadcastState:GetStatus().pendingKeys == 0,
	"shared State consumes the selected record and rechecks Instance scope before FireAllClients")
moving.Parent = scope
runtime.afterFire = function(target)
    if target == player then moving.Parent = outside end
end
local accepted, failure, sentCount = server.events.OrderedOut:SendTo({ player, secondPlayer }, moving)
assert(not accepted and failure.code == "InvalidPayload" and sentCount == 1,
    "ordered audience sends recheck native scope before every handoff")

local bytes = buffer.len(batch[2]) + 16
local chargedRuntime = ServerRuntime.new()
local chargedPlayer = chargedRuntime:addPlayer()
local charged = assert(chargedRuntime.server.create(definition, options(bytes)))
assert(charged:Start())
local called = 0
assert(charged.events.BatchIn:Connect(function() called += 1 end))
chargedRuntime:remote().OnServerEvent:Fire(chargedPlayer, 0, batch[2], part, outsidePart)
chargedRuntime:remote().OnServerEvent:Fire(chargedPlayer, 0, batch[2], part, other)
local counters = charged:GetDiagnostics().counters
assert(called == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
    and counters.aggregateBytes == 0,
    "malformed format5 retains complete byte charges and player-first refusal")
charged:Destroy()
invalidState:Destroy()
outputState:Destroy()
inputState:Destroy()
client:Destroy()
server:Destroy()
scope:Destroy()
outside:Destroy()
print("PASS all Instance event and queue routes, atomicity, scope and admission")
