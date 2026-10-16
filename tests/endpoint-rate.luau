local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local RpcFrame = require("../src/internal/RpcFrame")
local BatchFrame = require("../src/internal/BatchFrame")
local ServerRuntime = require("./support/ServerRuntime")

local definition = assert(Definition.define({
    name = "EndpointRateProof", version = 1,
    events = {
        Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
        UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
            fields = { { name = "value", type = "boolean" } } },
        BatchInput = { id = 3, direction = "ClientToServer", queue = "Batch",
            fields = { { name = "value", type = "boolean" } } },
        StateInput = { id = 4, direction = "ClientToServer", queue = "State",
            fields = { { name = "value", type = "boolean" } } },
        ServerOnly = { id = 5, direction = "ServerToClient", fields = {} },
    },
    requests = {
        Inspect = { id = 6, request = { { name = "enabled", type = "boolean" } }, response = { type = "boolean" } },
    },
}))
local compiled = assert(Definition.get(definition))
local guid = "01234567-89ab-cdef-0123-456789abcdef"

local function options(endpoints, playerCapacity, aggregateCapacity)
    return { inboundRate = {
        perPlayer = { capacity = playerCapacity or 4096, refillPerSecond = 64 },
        aggregate = { capacity = aggregateCapacity or 32768, refillPerSecond = 64 },
        endpoints = endpoints,
    } }
end

local function expectInvalid(endpoints)
    local runtime = ServerRuntime.new()
    local server, problem = runtime.server.create(definition, options(endpoints))
    assert(server == nil and problem.code == "InvalidOptions", "endpoint rate options reject at creation")
end

for _, endpointRates in {
    "bad",
    setmetatable({}, {}),
    { [1.5] = { capacity = 1, refillPerSecond = 1 } },
    { [7] = { capacity = 1, refillPerSecond = 1 } },
    { [5] = { capacity = 1, refillPerSecond = 1 } },
    { [1] = { capacity = 0, refillPerSecond = 1 } },
    { [1] = { capacity = 1, refillPerSecond = math.huge } },
    { [1] = setmetatable({ capacity = 1, refillPerSecond = 1 }, {}) },
    { [1] = { capacity = 1, refillPerSecond = 1, extra = true } },
    { ["1"] = { capacity = 1, refillPerSecond = 1 } },
} do
    expectInvalid(endpointRates)
end
local tooMany = {}
for id = 1, 65 do tooMany[id] = { capacity = 1, refillPerSecond = 1 } end
expectInvalid(tooMany)

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

local function queuedPacket(kind, ...)
    return assert(BatchFrame.wrap(kind, { ... }, 8_192))
end

local function requestPacket(callId, value)
    local body = table.pack(Frame.compile(compiled.requests.Inspect.request, "encode")(value))
    assert(body[1] == true)
    return assert(RpcFrame.wrap(1, 6, callId, guid, body[2]))
end

local function requestBody(value)
    local encoded = table.pack(Frame.compile(compiled.requests.Inspect.request, "encode")(value))
    assert(encoded[1] == true)
    return encoded[2]
end

local function setup(rateOptions)
    local runtime = ServerRuntime.new()
    local player = runtime:addPlayer()
    local server = assert(runtime.server.create(definition, rateOptions or options(nil)))
    assert(server:Start())
    return runtime, player, server, runtime:remote(), runtime:unreliableRemote()
end

-- Missing and empty maps retain the previous behavior, while configured rates are copied.
do
    local runtime = ServerRuntime.new()
    local player = runtime:addPlayer()
    local rates = { [1] = { capacity = 1, refillPerSecond = 1 } }
    local server = assert(runtime.server.create(definition, options(rates)))
    rates[1].capacity = 99
    rates[1] = nil
    rates[2] = { capacity = 99, refillPerSecond = 99 }
    assert(server:GetDiagnostics().inboundRate.endpoints[1].capacity == 1
        and server:GetDiagnostics().inboundRate.endpoints[2] == nil)
    assert(table.isfrozen(server:GetDiagnostics().inboundRate.endpoints))
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    assert(server:Start())
    local remote = runtime:remote()
    remote.OnServerEvent:Fire(player, 1, 1)
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(calls == 1 and server:GetDiagnostics().events.Input.endpointRate == 1)
    server:Destroy()

    runtime, player, server = setup(options({}))
    local before = server:GetDiagnostics()
    assert(next(before.inboundRate.endpoints) == nil and before.counters.endpointRate == 0)
    local connection = assert(server.events.Input:Connect(function() calls += 1 end))
    local eventRemote = runtime:remote()
    eventRemote.OnServerEvent:Fire(player, 1, 1)
    eventRemote.OnServerEvent:Fire(player, 1, 1)
    assert(server:GetDiagnostics().counters.endpointRate == 0)
    connection:Disconnect()
    server:Destroy()
end

-- Reliable, unreliable, malformed, listener-less, and listener replacement attempts share one event bucket.
do
    local runtime, player, server, remote, unreliable = setup(options({
        [1] = { capacity = 1, refillPerSecond = 1 },
        [2] = { capacity = 1, refillPerSecond = 1 },
    }))
    local reliableCalls, unreliableCalls = 0, 0
    assert(server.events.Input:Connect(function() reliableCalls += 1 end))
    local input = remote.OnServerEvent
    input:Fire(player, 1, "bad")
    input:Fire(player, 1, 1)
    assert(reliableCalls == 0 and server:GetDiagnostics().events.Input.invalidPayload == 1
        and server:GetDiagnostics().events.Input.endpointRate == 1)

    assert(server.events.UnreliableInput:Connect(function(_, value)
        assert(value == true)
        unreliableCalls += 1
    end))
    local body = eventBody("UnreliableInput", true)
    unreliable.OnServerEvent:Fire(player, 2, body)
    unreliable.OnServerEvent:Fire(player, 2, body)
    assert(unreliableCalls == 1 and server:GetDiagnostics().events.UnreliableInput.endpointRate == 1)
    server:Destroy()

    runtime, player, server, remote, unreliable = setup(options({ [1] = { capacity = 1, refillPerSecond = 1 } }))
    reliableCalls = 0
    unreliable.OnServerEvent:Fire(player, 1, 1)
    assert(server.events.Input:Connect(function() reliableCalls += 1 end))
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(reliableCalls == 1 and server:GetDiagnostics().counters.wrongChannel == 1,
        "wrong-channel traffic spends coarse admission but leaves the endpoint bucket untouched")
    server:Destroy()

    runtime, player, server, remote = setup(options({ [1] = { capacity = 1, refillPerSecond = 1 } }))
    remote.OnServerEvent:Fire(player, 1, 1)
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(calls == 0 and server:GetDiagnostics().events.Input.noListener == 1
        and server:GetDiagnostics().events.Input.endpointRate == 1)
    server:Destroy()
end

-- Endpoint buckets are independent by player and endpoint, retain a high-water clock, and do not reset with listeners.
do
    local runtime, player, server, remote = setup(options({
        [1] = { capacity = 2, refillPerSecond = 1 },
        [2] = { capacity = 1, refillPerSecond = 1 },
    }))
    local calls = 0
    local connection = assert(server.events.Input:Connect(function() calls += 1 end))
    assert(server.events.UnreliableInput:Connect(function() calls += 1 end))
    local clockReads = runtime.clockReads
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(runtime.clockReads == clockReads + 1, "all buckets use the single ingress timestamp")
    remote.OnServerEvent:Fire(player, 1, 1)
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(calls == 2 and server:GetDiagnostics().events.Input.endpointRate == 1)
    runtime.now = -10
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(server:GetDiagnostics().events.Input.endpointRate == 2, "backward time cannot refill a bucket")
    runtime.now = 1
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(calls == 3, "forward time refills to the configured sustained rate")
    connection:Disconnect()
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(server:GetDiagnostics().events.Input.endpointRate == 3, "replacing a listener does not reset its rate")
    local secondPlayer = runtime:addPlayer()
    remote.OnServerEvent:Fire(secondPlayer, 1, 1)
    assert(calls == 4, "each player receives an independent endpoint bucket")
    local unreliable = runtime:unreliableRemote()
    unreliable.OnServerEvent:Fire(player, 2, eventBody("UnreliableInput", true))
    assert(calls == 5, "separate endpoints have independent buckets")
    server:Destroy()
end

-- Player and aggregate admission still precede endpoint admission, without refunds.
do
    local runtime, player, server, remote = setup(options({
        [1] = { capacity = 1, refillPerSecond = 1 },
    }, 2, 2))
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(player, 1, 1)
    remote.OnServerEvent:Fire(player, 1, 1)
    remote.OnServerEvent:Fire(player, 1, 1)
    local counters = server:GetDiagnostics().counters
    assert(calls == 1 and counters.endpointRate == 1 and counters.perPlayerRate == 1,
        "endpoint refusal retains coarse charges and coarse exhaustion short-circuits endpoint charging")
    server:Destroy()
end

-- RPC peeks and resolves before charging; known replay and malformed bodies spend the request bucket.
do
    local runtime, player, server, remote = setup(options({ [6] = { capacity = 2, refillPerSecond = 1 } }))
    local calls = 0
    assert(server.requests.Inspect:Connect(function(_, enabled)
        assert(enabled == true)
        calls += 1
        return true
    end))
    local clockReads = runtime.clockReads
    local short = buffer.create(1)
    remote.OnServerEvent:Fire(player, 0, short)
    local unknownBody = buffer.create(4)
    buffer.writeu8(unknownBody, 0, 1)
    buffer.writeu16(unknownBody, 1, 7)
    buffer.writeu8(unknownBody, 3, 1)
    remote.OnServerEvent:Fire(player, 0, RpcFrame.wrap(1, 7, 1, guid, unknownBody))
    remote.OnServerEvent:Fire(player, 0, requestPacket(1, true))
    assert(runtime.clockReads == clockReads + 3, "malformed, unknown, and valid RPCs each use one clock sample")
    local responses = #runtime.fires
    remote.OnServerEvent:Fire(player, 0, requestPacket(1, true))
    remote.OnServerEvent:Fire(player, 0, requestPacket(2, true))
    local counters = server:GetDiagnostics().counters
    assert(calls == 1 and #runtime.fires == responses and counters.invalidPayload == 1
        and counters.invalidEndpoint == 1 and counters.busy == 1 and counters.endpointRate == 1,
        "replay is charged, rate-refused RPCs stay silent, and malformed or unknown requests spend only coarse admission")
    server:Destroy()

    runtime, player, server, remote = setup(options({ [6] = { capacity = 1, refillPerSecond = 1 } }))
    calls = 0
    assert(server.requests.Inspect:Connect(function() calls += 1; return true end))
    local malformedBody = requestBody(true)
    buffer.writeu8(malformedBody, 3, 2)
    local malformedRequest = assert(RpcFrame.wrap(1, 6, 1, guid, malformedBody))
    remote.OnServerEvent:Fire(player, 0, malformedRequest)
    remote.OnServerEvent:Fire(player, 0, requestPacket(2, true))
    counters = server:GetDiagnostics().counters
    assert(calls == 0 and counters.invalidPayload == 1 and counters.endpointRate == 1,
        "a well-peeked malformed request body consumes its endpoint bucket before decode")
    server:Destroy()
end

-- FIFO and State charge each scanned row before copies or decode; repeated IDs retain partial charges.
for _, item in { { id = 3, kind = 1 }, { id = 4, kind = 2 } } do
    local runtime, player, server, remote = setup(options({ [item.id] = { capacity = 1, refillPerSecond = 1 } }))
    local calls = 0
    local name = if item.id == 3 then "BatchInput" else "StateInput"
    assert(server.events[name]:Connect(function() calls += 1 end))
    local body = queuedBody(item.id, true)
    local repeated = queuedPacket(item.kind, body, body)
    local clockReads = runtime.clockReads
    remote.OnServerEvent:Fire(player, 0, repeated)
    assert(runtime.clockReads == clockReads + 1, "all queued row debits share one ingress timestamp")
    local snapshot = server:GetDiagnostics()
    assert(calls == 0 and snapshot.counters.endpointRate == 1
        and snapshot.counters.received == 1 and snapshot.events[name].dispatched == 0,
        "repeated queued IDs spend per row and reject the complete frame")
    remote.OnServerEvent:Fire(player, item.id, body)
    assert(calls == 0 and server:GetDiagnostics().counters.endpointRate == 2,
        "immediate and queued ingress share endpoint buckets")
    local single = queuedPacket(item.kind, body)
    remote.OnServerEvent:Fire(player, 0, single)
    assert(calls == 0 and server:GetDiagnostics().counters.endpointRate == 3,
        "a rejected frame retains prior endpoint charges")
    server:Destroy()
end

-- Every logical row keeps its player and aggregate debit even when a later endpoint row refuses the frame.
do
    local runtime, player, server, remote = setup(options({
        [3] = { capacity = 1, refillPerSecond = 1 },
    }, 2, 2))
    local body = queuedBody(3, true)
    remote.OnServerEvent:Fire(player, 0, queuedPacket(1, body, body))
    local samePlayer = remote.OnServerEvent
    samePlayer:Fire(player, 1, 1)
    local otherPlayer = runtime:addPlayer()
    samePlayer:Fire(otherPlayer, 1, 1)
    local counters = server:GetDiagnostics().counters
    assert(counters.endpointRate == 1 and counters.perPlayerRate == 1 and counters.aggregateRate == 1,
        "the full coarse prefix is retained before row-ordered endpoint admission")
    server:Destroy()
end

-- Invalid framing has no endpoint debit; a structurally scanned invalid body does.
do
    local runtime, player, server, remote = setup(options({ [3] = { capacity = 1, refillPerSecond = 1 } }))
    local calls = 0
    assert(server.events.BatchInput:Connect(function() calls += 1 end))
    local malformedFrame = buffer.create(3)
    buffer.writeu8(malformedFrame, 0, 2)
    buffer.writeu8(malformedFrame, 1, 1)
    buffer.writeu8(malformedFrame, 2, 2)
    remote.OnServerEvent:Fire(player, 0, malformedFrame)
    local validBody = queuedBody(3, true)
    remote.OnServerEvent:Fire(player, 0, queuedPacket(1, validBody))
    assert(calls == 1 and server:GetDiagnostics().counters.endpointRate == 0,
        "malformed framing does not charge an endpoint")
    server:Destroy()

    runtime, player, server, remote = setup(options({ [3] = { capacity = 1, refillPerSecond = 1 } }))
    calls = 0
    assert(server.events.BatchInput:Connect(function() calls += 1 end))
    local invalidBody = queuedBody(3, true)
    buffer.writeu8(invalidBody, 3, 2)
    remote.OnServerEvent:Fire(player, 0, queuedPacket(1, invalidBody))
    remote.OnServerEvent:Fire(player, 0, queuedPacket(1, validBody))
    local counters = server:GetDiagnostics().counters
    assert(calls == 0 and counters.invalidPayload == 1 and counters.endpointRate == 1,
        "a scanned row is charged before its malformed body is decoded")
    server:Destroy()
end

-- Removing and re-adding the same rostered player constructs fresh bounded endpoint buckets.
do
    local runtime, player, server, remote = setup(options({ [1] = { capacity = 1, refillPerSecond = 1 } }))
    local calls = 0
    assert(server.events.Input:Connect(function() calls += 1 end))
    remote.OnServerEvent:Fire(player, 1, 1)
    runtime:removePlayer(player)
    player.Parent = runtime.players
    runtime.players.PlayerAdded:Fire(player)
    remote.OnServerEvent:Fire(player, 1, 1)
    assert(calls == 2, "player removal clears the old endpoint buckets before re-admission")
    server:Destroy()
end

print("PASS Relay.EndpointRate")
