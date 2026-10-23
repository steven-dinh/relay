local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local OrderedFrame = require("../src/internal/OrderedFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local definition = assert(Definition.define({
    name = "OrderedProof", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
            { name = "enabled", type = "boolean" },
        } },
        TextInput = { id = 2, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
            { name = "text", type = "string", maximumBytes = 8 },
        } },
        OtherInput = { id = 3, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
            { name = "value", type = "u8" },
        } },
        Output = { id = 4, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
            { name = "value", type = "u8" },
        } },
        OtherOutput = { id = 5, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
            { name = "value", type = "u8" },
        } },
    },
}))
local compiled = Definition.get(definition)

local function encode(event, ...)
    local codecEvent = OrderedFrame.codecEvent(event)
    local values = table.pack(Frame.compile(codecEvent, "encode")(...))
    assert(values[1] == true, "test payload must encode")
    return values[2]
end

local function packet(event, generation, sequence, ...)
    return assert(OrderedFrame.wrap(event, encode(event, ...), generation, sequence))
end

local function serverOptions(perPlayer, aggregate, endpoints, bytes)
    return { inboundRate = {
        perPlayer = { capacity = perPlayer or 4096, refillPerSecond = 2048 },
        aggregate = { capacity = aggregate or 32768, refillPerSecond = 16384 },
        endpoints = endpoints,
        bytes = bytes,
    } }
end

local function makeServer(options)
    local runtime = ServerRuntime.new()
    local first, second = runtime:addPlayer(), runtime:addPlayer()
    local server = assert(runtime.server.create(definition, options or serverOptions()))
    assert(server:Start())
    return runtime, first, second, server, runtime:remote(), runtime:unreliableRemote()
end

local function hello(remote, player, guid)
    remote.OnServerEvent:Fire(player, 0, assert(OrderedFrame.hello(guid)))
end

local function startClient(responseGeneration)
    local runtime = ClientRuntime.create()
    local _, _, remote, unreliable = runtime:transport(compiled.descriptor, true)
    local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
    runtime.onFire = function(_, endpointId, control)
        if endpointId == 0 then
            local guid = OrderedFrame.readHello(control)
            if guid ~= nil then
                remote.OnClientEvent:fire(0, assert(OrderedFrame.initialization(guid, responseGeneration)))
            end
        end
    end
    assert(client:Start())
    return runtime, client, remote, unreliable
end

local function beginStart(client)
    local result = {}
    local thread = coroutine.create(function()
        result.ok, result.failure = client:Start()
    end)
    assert(coroutine.resume(thread))
    return thread, result
end

local function assertFailure(expected, ok, problem)
    assert(not ok and problem ~= nil and problem.code == expected,
        `expected {expected}, got {if problem then problem.code else "success"}`)
end

do
    local event = { id = 62, hasReferences = false, minimumEncodedBytes = 20, maximumEncodedBytes = 20 }
    local codecPacket = buffer.create(12)
    buffer.writeu8(codecPacket, 0, 1)
    buffer.writeu16(codecPacket, 1, event.id)
    buffer.writef64(codecPacket, 3, 0)
    buffer.writeu8(codecPacket, 11, 7)
    local original = buffer.tostring(codecPacket)
    local stamped = assert(OrderedFrame.wrap(event, codecPacket, 9, 4, nil, 12.5))
    local expected = buffer.create(20)
    buffer.writeu8(expected, 0, 3)
    buffer.writeu16(expected, 1, event.id)
    buffer.writeu32(expected, 3, 9)
    buffer.writeu32(expected, 7, 4)
    buffer.writef64(expected, 11, 12.5)
    buffer.writeu8(expected, 19, 7)
    assert(buffer.tostring(stamped) == buffer.tostring(expected)
        and buffer.tostring(codecPacket) == original and buffer.readf64(codecPacket, 3) == 0,
        "format-3 stamping matches the exact envelope and retains the canonical codec body")

    local reference = require("@lune/roblox").Instance.new("Part")
    local referenceEvent = { id = 63, hasReferences = true, maximumReferences = 1,
        minimumEncodedBytes = 21, maximumEncodedBytes = 21 }
    local referenceBody = buffer.create(13)
    buffer.writeu8(referenceBody, 0, 4)
    buffer.writeu16(referenceBody, 1, referenceEvent.id)
    buffer.writeu8(referenceBody, 3, 1)
    buffer.writef64(referenceBody, 4, 0)
    buffer.writeu8(referenceBody, 12, 7)
    local referenceOriginal = buffer.tostring(referenceBody)
    local referenceSidecars = table.pack(reference)
    local referencePacket = assert(OrderedFrame.wrap(referenceEvent, referenceBody, 7, 9,
        referenceSidecars, 25.5))
    local expectedReferencePacket = buffer.create(21)
    buffer.writeu8(expectedReferencePacket, 0, 6)
    buffer.writeu16(expectedReferencePacket, 1, referenceEvent.id)
    buffer.writeu32(expectedReferencePacket, 3, 7)
    buffer.writeu32(expectedReferencePacket, 7, 9)
    buffer.writeu8(expectedReferencePacket, 11, 1)
    buffer.writef64(expectedReferencePacket, 12, 25.5)
    buffer.writeu8(expectedReferencePacket, 20, 7)
    assert(buffer.tostring(referencePacket) == buffer.tostring(expectedReferencePacket)
        and buffer.tostring(referenceBody) == referenceOriginal and buffer.readf64(referenceBody, 4) == 0,
        "format-6 stamping follows its larger header and retains the referenced codec body")

    assert(OrderedFrame.wrap(event, codecPacket, 9, 4, nil, true) == nil
        and OrderedFrame.wrap(event, codecPacket, 9, 4, nil, 0 / 0) == nil
        and OrderedFrame.wrap(event, codecPacket, 9, 4, nil, math.huge) == nil,
        "ordered stamping rejects nonnumeric and nonfinite timestamps")
    local shortEvent = { id = 64, hasReferences = false, minimumEncodedBytes = 11, maximumEncodedBytes = 11 }
    local shortBody = buffer.create(3)
    buffer.writeu8(shortBody, 0, 1)
    buffer.writeu16(shortBody, 1, shortEvent.id)
    assert(OrderedFrame.wrap(shortEvent, shortBody, 1, 1) ~= nil
        and OrderedFrame.wrap(shortEvent, shortBody, 1, 1, nil, 1) == nil,
        "timestamp stamping rejects bodies shorter than the f64 field while unstamped framing stays valid")
end

do
	local reference = require("@lune/roblox").Instance.new("Part")
	local event = { id = 60, hasReferences = true, maximumReferences = 1,
		minimumEncodedBytes = 13, maximumEncodedBytes = 13 }
	local codecPacket = buffer.create(5)
	buffer.writeu8(codecPacket, 0, 4)
	buffer.writeu16(codecPacket, 1, event.id)
	buffer.writeu8(codecPacket, 3, 1)
	buffer.writeu8(codecPacket, 4, 1)
	local sidecars = table.pack(reference)
	local wrapped, outgoingReferences = assert(OrderedFrame.wrap(event, codecPacket, 7, 9, sidecars))
	assert(buffer.readu8(wrapped, 0) == 6 and buffer.readu8(wrapped, 11) == 1
		and buffer.len(wrapped) + 8 == 21 and outgoingReferences[1] == reference,
		"ordered format-6 retains the reference count and includes its sidecar charge")
	local header = assert(OrderedFrame.peek(event, event.id, wrapped, sidecars))
	local decoded = table.pack(OrderedFrame.decode(event, wrapped, header, function(body, value)
		assert(buffer.readu8(body, 0) == 4 and buffer.readu16(body, 1) == event.id
			and buffer.readu8(body, 3) == 1 and buffer.readu8(body, 4) == 1)
		return true, value
	end, sidecars))
	assert(decoded.n == 2 and decoded[1] == true and decoded[2] == reference,
		"ordered format-6 rebuilds the exact local format-4 body and preserves its slot ordinal")
	assert(OrderedFrame.wrap(event, codecPacket, 7, 10) == nil
		and OrderedFrame.peek(event, event.id, wrapped) == nil,
		"ordered format-6 rejects missing sidecars on both send and receive")

	local exactEvent = { id = 61, hasReferences = true, maximumReferences = 16,
		minimumEncodedBytes = 12, maximumEncodedBytes = 900 }
	local exactBody = buffer.create(764)
	buffer.writeu8(exactBody, 0, 4)
	buffer.writeu16(exactBody, 1, exactEvent.id)
	buffer.writeu8(exactBody, 3, 16)
	local sixteenReferences = { n = 16 }
	for index = 1, 16 do sixteenReferences[index] = reference end
	local exactPacket = assert(OrderedFrame.wrap(exactEvent, exactBody, 7, 1, sixteenReferences))
	assert(buffer.len(exactPacket) + 128 == 900,
		"ordered format-6 accepts the exact 900-unit packet and 16-reference budget")
	local oversizedBody = buffer.create(765)
	buffer.writeu8(oversizedBody, 0, 4)
	buffer.writeu16(oversizedBody, 1, exactEvent.id)
	buffer.writeu8(oversizedBody, 3, 16)
	assert(OrderedFrame.wrap(exactEvent, oversizedBody, 7, 2, sixteenReferences) == nil,
		"ordered format-6 rejects one unit over the 900-byte complete limit")
end

-- Legacy descriptors remain byte-identical; ordered events opt into RR8 and
-- inspection reports the entire 11-byte-header frame budget.
do
    local legacy = assert(Definition.define({ name = "OrderedProof", version = 1, events = {
        Ping = { id = 1, direction = "ClientToServer", fields = {} },
    } }))
    assert(Definition.get(legacy).descriptor == "RR1|D12:OrderedProof|V1|N1|E1,C,4:Ping,0")
    assert(compiled.descriptor:sub(1, 3) == "RR8" and string.find(compiled.descriptor, ",O,", 1, true))
    assert(compiled.hasUnreliable and compiled.hasOrderedUnreliable and compiled.hasOrderedClientToServer)
    assert(compiled.events.Input.delivery == "Unreliable" and compiled.events.Input.ordered)
    local report = Definition.inspect(definition)
    assert(report.events.Input.delivery == "OrderedUnreliable"
        and report.events.Input.bytes.minimum == 12 and report.events.Input.bytes.maximum == 12
        and report.events.Input.bytes.limit == 900)
    local full900 = assert(Definition.define({ name = "OrderedLimit", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable",
            fields = { { name = "text", type = "string", maximumBytes = 887 } } },
    } }))
    assert(Definition.inspect(full900).events.Input.bytes.maximum == 900)
    local rejected, problem = Definition.define({ name = "OrderedLimit", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable",
            fields = { { name = "text", type = "string", maximumBytes = 888 } } },
    } })
    assert(rejected == nil and string.find(problem.message, "892 bytes", 1, true)
        and string.find(problem.message, "900-byte", 1, true))
    for _, queue in { "Batch", "State" } do
        rejected = Definition.define({ name = "OrderedQueue", version = 1, events = {
            Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", queue = queue, fields = {} },
        } })
        assert(rejected == nil, "OrderedUnreliable cannot be queued")
    end
end

-- The private frame moves the ordinary format-1 body behind an 11-byte header,
-- rejects invalid fields and trailing bytes, and keeps control records exact.
do
    local event = compiled.events.Input
    local body = encode(event, true)
    local wrapped = packet(event, 7, 9, true)
    assert(buffer.len(wrapped) == 12 and buffer.readu8(wrapped, 0) == 3
        and buffer.readu16(wrapped, 1) == 1 and buffer.readu32(wrapped, 3) == 7
        and buffer.readu32(wrapped, 7) == 9)
    local header = assert(OrderedFrame.peek(event, 1, wrapped))
    local values = table.pack(OrderedFrame.decode(event, wrapped, header,
        Frame.compile(OrderedFrame.codecEvent(event), "decode")))
    assert(values.n == 2 and values[1] and values[2] == true)
    assert(OrderedFrame.peek(event, 2, wrapped) == nil)
    local truncated = buffer.create(buffer.len(wrapped) - 1)
    buffer.copy(truncated, 0, wrapped, 0, buffer.len(truncated))
    assert(OrderedFrame.peek(event, 1, truncated) == nil)

    buffer.writeu8(body, 3, 2)
    local malformed = assert(OrderedFrame.wrap(event, body, 7, 10))
    local malformedHeader = assert(OrderedFrame.peek(event, 1, malformed))
    assert(OrderedFrame.decode(event, malformed, malformedHeader,
        Frame.compile(OrderedFrame.codecEvent(event), "decode")) == nil)

    local textEvent = compiled.events.TextInput
    local textBody = encode(textEvent, "a")
    local trailingBody = buffer.create(buffer.len(textBody) + 1)
    buffer.copy(trailingBody, 0, textBody, 0, buffer.len(textBody))
    buffer.writeu8(trailingBody, buffer.len(trailingBody) - 1, 0)
    local trailing = assert(OrderedFrame.wrap(textEvent, trailingBody, 7, 1))
    local trailingHeader = assert(OrderedFrame.peek(textEvent, 2, trailing))
    assert(OrderedFrame.decode(textEvent, trailing, trailingHeader,
        Frame.compile(OrderedFrame.codecEvent(textEvent), "decode")) == nil)

    local compositeToken = assert(Definition.define({ name = "OrderedComposite", version = 1, events = {
        Empty = { id = 6, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {} },
        Nested = { id = 7, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
            { name = "payload", type = "struct", fields = {
                { name = "result", type = "taggedUnion", tag = "kind", variants = {
                    Ready = { type = "struct", fields = { { name = "value", type = "u8" } } },
                    Failed = { type = "struct", fields = { { name = "reason", type = "string", maximumBytes = 8 } } },
                } },
            } },
        } },
    } }))
    local composite = Definition.get(compositeToken)
    local emptyEvent = composite.events.Empty
    local emptyPacket = assert(OrderedFrame.wrap(emptyEvent, encode(emptyEvent), 1, 1))
    local emptyHeader = assert(OrderedFrame.peek(emptyEvent, 6, emptyPacket))
    assert(buffer.len(emptyPacket) == 11
        and OrderedFrame.decode(emptyEvent, emptyPacket, emptyHeader,
            Frame.compile(OrderedFrame.codecEvent(emptyEvent), "decode")) ~= nil,
        "empty ordered fields retain the 11-byte frame header and round-trip")

    local nestedEvent = composite.events.Nested
    local nestedValue = { result = { kind = "Ready", value = 7 } }
    local nestedBody = encode(nestedEvent, nestedValue)
    local nestedPacket = assert(OrderedFrame.wrap(nestedEvent, nestedBody, 1, 1))
    local nestedHeader = assert(OrderedFrame.peek(nestedEvent, 7, nestedPacket))
    local nestedValues = table.pack(OrderedFrame.decode(nestedEvent, nestedPacket, nestedHeader,
        Frame.compile(OrderedFrame.codecEvent(nestedEvent), "decode")))
    assert(nestedValues.n == 2 and nestedValues[1]
        and nestedValues[2].result.kind == "Ready" and nestedValues[2].result.value == 7)
    local invalidNestedBody = buffer.create(buffer.len(nestedBody))
    buffer.copy(invalidNestedBody, 0, nestedBody, 0, buffer.len(nestedBody))
    buffer.writeu8(invalidNestedBody, 3, 255)
    local invalidNested = assert(OrderedFrame.wrap(nestedEvent, invalidNestedBody, 1, 2))
    local invalidNestedHeader = assert(OrderedFrame.peek(nestedEvent, 7, invalidNested))
    assert(OrderedFrame.decode(nestedEvent, invalidNested, invalidNestedHeader,
        Frame.compile(OrderedFrame.codecEvent(nestedEvent), "decode")) == nil,
        "nested tagged-union ordinals are validated behind the ordered header")

    local guid = "abcdefab-cdef-4000-8000-000000000001"
    local helloPacket = assert(OrderedFrame.hello(guid))
    local initialization = assert(OrderedFrame.initialization(guid, 1))
    assert(buffer.len(helloPacket) == 38 and OrderedFrame.readHello(helloPacket) == guid)
    assert(buffer.len(initialization) == 42 and OrderedFrame.readInitialization(initialization).generation == 1)
    local zeroGeneration = buffer.create(42)
    buffer.copy(zeroGeneration, 0, initialization, 0, 42)
    buffer.writeu32(zeroGeneration, 38, 0)
    assert(OrderedFrame.readInitialization(zeroGeneration) == nil)
    local extraControl = buffer.create(43)
    buffer.copy(extraControl, 0, initialization, 0, 42)
    assert(OrderedFrame.readInitialization(extraControl) == nil)

    local runtime = ServerRuntime.new()
    local player = runtime:addPlayer()
    local server = assert(runtime.server.create(compositeToken, serverOptions()))
    local received = 0
    assert(server.events.Nested:Connect(function(_, payload)
        received += 1
        assert(payload.result.kind == "Ready" and payload.result.value == 7)
    end))
    assert(server:Start())
    hello(runtime:remote(), player, "abcdefab-cdef-4000-8000-000000000010")
    local remote = runtime:unreliableRemote()
    remote.OnServerEvent:Fire(player, 7, nestedPacket)
    remote.OnServerEvent:Fire(player, 7, invalidNested)
    remote.OnServerEvent:Fire(player, 7, assert(OrderedFrame.wrap(nestedEvent, nestedBody, 1, 2)))
    assert(received == 2 and server:GetDiagnostics().events.Nested.invalidPayload == 1
        and server:GetDiagnostics().events.Nested.dispatched == 2,
        "nested ordered decode rejects an invalid union without poisoning the serial")
    server:Destroy()
end

-- An ordered definition cannot start against an otherwise matching ordinary
-- unreliable descriptor, and fails before sending Hello or application data.
do
    local ordered = assert(Definition.define({ name = "OrderedMismatch", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {} },
    } }))
    local unreliable = assert(Definition.define({ name = "OrderedMismatch", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
    } }))
    assert(Definition.get(ordered).descriptor ~= Definition.get(unreliable).descriptor,
        "ordered delivery participates in compatibility identity")
    local runtime = ClientRuntime.create()
    runtime:transport(Definition.get(unreliable).descriptor, true)
    local client = assert(runtime.module.create(ordered, { startupTimeoutSeconds = 3 }))
    local ok, problem = client:Start()
    assert(not ok and problem.code == "DefinitionMismatch" and #runtime.fires == 0,
        "descriptor mismatch must reject before OrderedUnreliable Hello")
    client:Destroy()
end

-- Ordered runtime routes accept exactly 900 bytes and reject 901 before any
-- transport handoff, including empty server audiences.
do
    local boundaryToken = assert(Definition.define({ name = "OrderedBoundary", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
            { name = "text", type = "string", maximumBytes = 887 },
        } },
        Output = { id = 2, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
            { name = "text", type = "string", maximumBytes = 887 },
        } },
    } }))
    local boundaryCompiled = Definition.get(boundaryToken)
    local maximum = string.rep("x", 887)
    local tooLarge = string.rep("x", 888)
    assert(boundaryCompiled.events.Input.maximumEncodedBytes == 900
        and boundaryCompiled.events.Output.maximumEncodedBytes == 900)

    local clientRuntime = ClientRuntime.create()
    local _, _, clientRemote = clientRuntime:transport(boundaryCompiled.descriptor, true)
    local client = assert(clientRuntime.module.create(boundaryToken, { startupTimeoutSeconds = 3 }))
    clientRuntime.onFire = function(_, endpointId, control)
        if endpointId == 0 then
            local guid = OrderedFrame.readHello(control)
            if guid then
                clientRemote.OnClientEvent:fire(0, assert(OrderedFrame.initialization(guid, 19)))
            end
        end
    end
    assert(client:Start() and client.events.Input:Send(maximum))
    local clientPacket = clientRuntime.fires[2][2]
    local clientHeader = assert(OrderedFrame.peek(boundaryCompiled.events.Input, 1, clientPacket))
    local clientValues = table.pack(OrderedFrame.decode(boundaryCompiled.events.Input, clientPacket, clientHeader,
        Frame.compile(OrderedFrame.codecEvent(boundaryCompiled.events.Input), "decode")))
    assert(buffer.len(clientPacket) == 900 and clientHeader.generation == 19 and clientHeader.sequence == 1
        and clientValues.n == 2 and clientValues[1] and clientValues[2] == maximum)
    local clientFireCount = #clientRuntime.fires
    local sent, invalid = client.events.Input:Send(tooLarge)
    assertFailure("InvalidPayload", sent, invalid)
    assert(#clientRuntime.fires == clientFireCount, "901-byte client frames reject before transport")
    client:Destroy()

    local runtime = ServerRuntime.new()
    local first, second = runtime:addPlayer(), runtime:addPlayer()
    local server = assert(runtime.server.create(boundaryToken, serverOptions()))
    assert(server:Start())
    local output = server.events.Output
    local unreliable = runtime:unreliableRemote()
    local decode = Frame.compile(OrderedFrame.codecEvent(boundaryCompiled.events.Output), "decode")
    local function assertFrames(start, count, sequence)
        assert(#runtime.fires - start == count)
        for index = start + 1, #runtime.fires do
            local handoff = runtime.fires[index]
            local packet = handoff.values[2]
            local header = assert(OrderedFrame.peek(boundaryCompiled.events.Output, 2, packet))
            local values = table.pack(OrderedFrame.decode(boundaryCompiled.events.Output, packet, header, decode))
            assert(handoff.remote == unreliable and handoff.values[1] == 2 and buffer.len(packet) == 900
                and header.generation == 0 and header.sequence == sequence
                and values.n == 2 and values[1] and values[2] == maximum)
        end
    end

    local start = #runtime.fires
    assert(output:Send(first, maximum))
    assertFrames(start, 1, 1)
    start = #runtime.fires
    assert(output:Broadcast(maximum))
    assertFrames(start, 1, 2)
    start = #runtime.fires
    local ok, problem, count = output:SendTo({ first, second }, maximum)
    assert(ok and problem == nil and count == 2)
    assertFrames(start, 2, 3)
    start = #runtime.fires
    ok, problem, count = output:SendExcept({ second }, maximum)
    assert(ok and problem == nil and count == 1)
    assertFrames(start, 1, 4)
    start = #runtime.fires
    ok, problem, count = output:SendTo({}, maximum)
    assert(ok and problem == nil and count == 0 and #runtime.fires == start)
    ok, problem, count = output:SendExcept({ first, second }, maximum)
    assert(ok and problem == nil and count == 0 and #runtime.fires == start)
    assert(output:Broadcast(maximum))
    assertFrames(start, 1, 5)

    local invalidRoutes = {
        function() return output:Send(first, tooLarge) end,
        function() return output:Broadcast(tooLarge) end,
        function() return output:SendTo({ first }, tooLarge) end,
        function() return output:SendExcept({ second }, tooLarge) end,
        function() return output:SendTo({}, tooLarge) end,
        function() return output:SendExcept({ first, second }, tooLarge) end,
    }
    for _, route in invalidRoutes do
        local before = #runtime.fires
        local sendOk, sendError, sentCount = route()
        assert(not sendOk and sendError.code == "InvalidPayload"
            and (sentCount == nil or sentCount == 0) and #runtime.fires == before,
            "901-byte ordered payloads reject on every server route before handoff")
    end
    server:Destroy()
    assert(runtime.connections == 0)
end

-- Client installs its receiver before Hello, binds the exact attempt, and only
-- then starts. Per-event serials accept wrap and Once replacement keeps high-water.
do
    local runtime = ClientRuntime.create()
    local _, _, remote, unreliable = runtime:transport(compiled.descriptor, true)
    local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
    local received = {}
    local once = assert(client.events.Output:Once(function(value) table.insert(received, value) end))
    local syncReceiverReady = false
    runtime.onFire = function(_, endpointId, control)
        if endpointId == 0 then
            local guid = OrderedFrame.readHello(control)
            if guid ~= nil then
                syncReceiverReady = runtime.connections > 0
                remote.OnClientEvent:fire(0, assert(OrderedFrame.initialization(guid, 11)))
            end
        end
    end
    assert(client:Start() and syncReceiverReady, "Init may arrive synchronously after receiver installation")
    assert(once ~= nil and #runtime.fires == 1 and OrderedFrame.readHello(runtime.fires[1][2]) ~= nil)

    assert(client.events.Input:Send(true) and client.events.OtherInput:Send(7))
    local firstSend = runtime.fires[2][2]
    local secondSend = runtime.fires[3][2]
    assert(buffer.readu8(firstSend, 0) == 3 and buffer.readu32(firstSend, 3) == 11
        and buffer.readu32(firstSend, 7) == 1 and buffer.readu16(secondSend, 1) == 3
        and buffer.readu32(secondSend, 7) == 1,
        "each endpoint starts at sequence one under the bound generation")

    local event = compiled.events.Output
    local function deliver(sequence, value, generation, channel)
        local data = packet(event, generation or 0, sequence, value)
        local transport = if channel == "Reliable" then remote else unreliable
        transport.OnClientEvent:fire(4, data)
        return data
    end
    deliver(4_294_967_295, 1)
    assert(received[1] == 1)
    local replacementCalls = 0
    local replacement = assert(client.events.Output:Connect(function(value)
        replacementCalls += value
    end))
    deliver(4_294_967_295, 2)
    unreliable.OnClientEvent:fire(4, packet(event, 0, 0, 3), "extra")
    deliver(0, 3)
    deliver(2_147_483_648, 4)
    deliver(1, 5, 1)
    deliver(1, 6, 0, "Reliable")
    assert(received[1] == 1 and replacementCalls == 3,
        "duplicate, half-window, wrong generation and wrong channel never dispatch")
    local diagnostics = client:GetDiagnostics()
    assert(diagnostics.events.Output.stale == 3 and diagnostics.events.Output.invalidPayload == 1
        and diagnostics.events.Output.dispatched == 2
        and diagnostics.counters.wrongChannel == 1)
    client:Destroy()
    assert(runtime.connections == 0)
end

-- Server generation belongs to a Player: it restarts on Hello, clears only
-- serial history, and leaves a yielded handler's busy reservation intact.
do
    local runtime, first, second, server, remote, unreliable = makeServer()
    local guid1 = "abcdefab-cdef-4000-8000-000000000001"
    local guid2 = "abcdefab-cdef-4000-8000-000000000002"
    hello(remote, first, guid1)
    local firstInit = runtime.fires[#runtime.fires].values[2]
    hello(remote, second, guid2)
    local secondInit = runtime.fires[#runtime.fires].values[2]
    assert(OrderedFrame.readInitialization(firstInit).generation == 1
        and OrderedFrame.readInitialization(secondInit).generation == 1)

    local invalid = packet(compiled.events.Input, 1, 1, true)
    buffer.writeu8(invalid, 11, 2)
    unreliable.OnServerEvent:Fire(first, 1, invalid)
    assert(server:GetDiagnostics().events.Input.noListener == 1,
        "no-listener admission precedes frame decoding")
    local inputCalls, otherCalls = 0, 0
    assert(server.events.Input:Connect(function(player, enabled)
        assert(enabled == true)
        inputCalls += 1
    end))
    assert(server.events.OtherInput:Connect(function(player, value)
        otherCalls += value
    end))
    local validFirst = packet(compiled.events.Input, 1, 1, true)
    unreliable.OnServerEvent:Fire(first, 1, validFirst, "extra")
    unreliable.OnServerEvent:Fire(first, 1, validFirst)
    unreliable.OnServerEvent:Fire(first, 1, validFirst)
    unreliable.OnServerEvent:Fire(second, 1, packet(compiled.events.Input, 1, 1, true))
    assert(inputCalls == 2, "wrong arity and duplicate frames cannot advance or dispatch")
    assert(server:GetDiagnostics().events.Input.invalidPayload == 1
        and server:GetDiagnostics().events.Input.stale == 1)

    local malformedField = packet(compiled.events.Input, 1, 2, true)
    buffer.writeu8(malformedField, 11, 2)
    unreliable.OnServerEvent:Fire(first, 1, malformedField)
    unreliable.OnServerEvent:Fire(first, 1, packet(compiled.events.Input, 1, 2, true))
    assert(inputCalls == 3, "a malformed codec payload must not poison its serial")

    unreliable.OnServerEvent:Fire(first, 1, packet(compiled.events.Input, 1, 1, true))
    unreliable.OnServerEvent:Fire(first, 1, packet(compiled.events.Input, 1, 2_147_483_650, true))
    assert(inputCalls == 3, "backward and half-window serials are stale")

    unreliable.OnServerEvent:Fire(first, 3, packet(compiled.events.OtherInput, 1, 4_294_967_295, 2))
    unreliable.OnServerEvent:Fire(first, 3, packet(compiled.events.OtherInput, 1, 0, 3))
    assert(otherCalls == 5, "serial wrap is forward and high-water is isolated per endpoint")

    hello(remote, first, guid2)
    local newGeneration = OrderedFrame.readInitialization(runtime.fires[#runtime.fires].values[2]).generation
    assert(newGeneration == 2)
    unreliable.OnServerEvent:Fire(first, 1, packet(compiled.events.Input, 1, 3, true))
    unreliable.OnServerEvent:Fire(first, 1, packet(compiled.events.Input, newGeneration, 1, true))
    assert(inputCalls == 4, "new generation clears only the old high-water")

    local yielded = false
    assert(server.events.TextInput:Connect(function(_, text)
        yielded = text == "wait"
        coroutine.yield()
    end))
    runtime.captureThreads = true
    local trailingBody = buffer.create(buffer.len(encode(compiled.events.TextInput, "wait")) + 1)
    local textBody = encode(compiled.events.TextInput, "wait")
    buffer.copy(trailingBody, 0, textBody, 0, buffer.len(textBody))
    buffer.writeu8(trailingBody, buffer.len(trailingBody) - 1, 0)
    unreliable.OnServerEvent:Fire(first, 2,
        assert(OrderedFrame.wrap(compiled.events.TextInput, trailingBody, newGeneration, 1)))
    unreliable.OnServerEvent:Fire(first, 2, packet(compiled.events.TextInput, newGeneration, 1, "wait"))
    local handlerThread = runtime.threads[#runtime.threads]
    assert(yielded and coroutine.status(handlerThread) == "suspended")
    hello(remote, first, "abcdefab-cdef-4000-8000-000000000003")
    local thirdGeneration = OrderedFrame.readInitialization(runtime.fires[#runtime.fires].values[2]).generation
    local beforeBusy = server:GetDiagnostics().events.TextInput.busy
    local invalidPayloads = server:GetDiagnostics().events.TextInput.invalidPayload
    unreliable.OnServerEvent:Fire(first, 2, packet(compiled.events.TextInput, thirdGeneration, 1, "next"), "extra")
    assert(server:GetDiagnostics().events.TextInput.busy == beforeBusy + 1,
        "a new initialization preserves the in-flight admission slot")
    assert(server:GetDiagnostics().events.TextInput.invalidPayload == invalidPayloads,
        "busy admission precedes ordered payload validation")
    assert(coroutine.resume(handlerThread))
    unreliable.OnServerEvent:Fire(first, 2, packet(compiled.events.TextInput, thirdGeneration, 1, "next"))
    assert(server:GetDiagnostics().events.TextInput.dispatched == 2)
    server:Destroy()
    assert(runtime.connections == 0 and unreliable ~= nil)
end

-- Endpoint and byte budgets run before stale classification. Fan-out encodes
-- one frame once, shares one endpoint serial, and reports partial handoff count.
do
    local runtime, first, second, server, remote, unreliable = makeServer(serverOptions(20, 40, {
        [1] = { capacity = 1, refillPerSecond = 1 },
    }, { perPlayer = { capacity = 100, refillPerSecond = 1 }, aggregate = { capacity = 200, refillPerSecond = 2 } }))
    hello(remote, first, "abcdefab-cdef-4000-8000-000000000004")
    local input = packet(compiled.events.Input, 1, 1, true)
    unreliable.OnServerEvent:Fire(first, 1, input)
    unreliable.OnServerEvent:Fire(first, 1, input)
    local diagnostics = server:GetDiagnostics()
    assert(diagnostics.counters.endpointRate == 1 and diagnostics.events.Input.stale == 0,
        "endpoint admission precedes stale checks")
    server:Destroy()

    local byteRuntime, bytePlayer, _, byteServer, byteRemote, byteUnreliable = makeServer(serverOptions(20, 40, nil, {
        perPlayer = { capacity = 50, refillPerSecond = 1 },
        aggregate = { capacity = 100, refillPerSecond = 2 },
    }))
    hello(byteRemote, bytePlayer, "abcdefab-cdef-4000-8000-000000000005")
    local small = packet(compiled.events.Input, 1, 1, true)
    byteUnreliable.OnServerEvent:Fire(bytePlayer, 1, small)
    byteUnreliable.OnServerEvent:Fire(bytePlayer, 1, small)
    local byteDiagnostics = byteServer:GetDiagnostics()
    assert(byteDiagnostics.counters.perPlayerBytes == 1 and byteDiagnostics.events.Input.stale == 0,
        "byte charging precedes stale checks")
    byteServer:Destroy()

    local fanRuntime, fanFirst, fanSecond, fanServer, _, fanUnreliable = makeServer()
    local output = fanServer.events.Output
    local validationCalls = fanRuntime.validationCalls
    assert(output:SendTo({ fanFirst, fanSecond }, 7))
    local firstFan, secondFan = fanRuntime.fires[#fanRuntime.fires - 1], fanRuntime.fires[#fanRuntime.fires]
    assert(firstFan.kind == "target" and secondFan.kind == "target"
        and firstFan.values[2] == secondFan.values[2]
        and buffer.readu32(firstFan.values[2], 7) == 1
        and fanRuntime.validationCalls == validationCalls + 1
        and firstFan.remote == fanUnreliable)
    assert(output:Broadcast(8))
    local broadcast = fanRuntime.fires[#fanRuntime.fires]
    assert(broadcast.kind == "broadcast" and buffer.readu32(broadcast.values[2], 7) == 2)
    assert(output:SendTo({}, 9))
    assert(output:Broadcast(10))
    assert(buffer.readu32(fanRuntime.fires[#fanRuntime.fires].values[2], 7) == 3,
        "empty audiences do not consume an endpoint serial")
    fanRuntime.beforeFire = function(player)
        if player == fanSecond then fanRuntime.throwFire = true end
    end
    local ok, problem, sent = output:SendTo({ fanFirst, fanSecond }, 11)
    assertFailure("TransportFailure", ok, problem)
    assert(sent == 1 and buffer.readu32(fanRuntime.fires[#fanRuntime.fires].values[2], 7) == 4)
    fanRuntime.throwFire = false
    fanRuntime.beforeFire = nil
    assert(output:Broadcast(12))
    assert(buffer.readu32(fanRuntime.fires[#fanRuntime.fires].values[2], 7) == 5)
    fanServer:Destroy()
    assert(fanRuntime.connections == 0 and byteRuntime.connections == 0 and runtime.connections == 0)
end

-- Attempt-bound Init rejects malformed, mismatched and late controls. Discovery
-- and Init share the original deadline, while Destroy releases both waiters.
do
    local runtime = ClientRuntime.create()
    local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
    local thread, result = beginStart(client)
    runtime:advance(2)
    local _, _, remote = runtime:transport(compiled.descriptor, true)
    runtime:flush()
    assert(coroutine.status(thread) == "suspended" and #runtime.fires == 1)
    local guid = OrderedFrame.readHello(runtime.fires[1][2])
    local malformed = buffer.create(42)
    buffer.writeu8(malformed, 0, 2)
    buffer.writeu8(malformed, 1, 33)
    remote.OnClientEvent:fire(0, malformed)
    remote.OnClientEvent:fire(0, assert(OrderedFrame.initialization("abcdefab-cdef-4000-8000-000000000099", 1)))
    assert(coroutine.status(thread) == "suspended")
    local initialization = assert(OrderedFrame.initialization(guid, 1))
    remote.OnClientEvent:fire(0, initialization)
    runtime:flush()
    assert(result.ok and result.failure == nil and coroutine.status(thread) == "dead")
    remote.OnClientEvent:fire(0, initialization)
    assert(client:GetDiagnostics().counters.stale == 2
        and client:GetDiagnostics().counters.invalidPayload == 1)
    client:Destroy()
    assert(runtime.connections == 0 and next(runtime.timers) == nil)

    local timeoutRuntime = ClientRuntime.create()
    local timeoutClient = assert(timeoutRuntime.module.create(definition, { startupTimeoutSeconds = 3 }))
    local timeoutThread, timeoutResult = beginStart(timeoutClient)
    timeoutRuntime:advance(2)
    timeoutRuntime:transport(compiled.descriptor, true)
    timeoutRuntime:flush()
    assert(coroutine.status(timeoutThread) == "suspended" and #timeoutRuntime.fires == 1)
    for _, deadline in timeoutRuntime.timers do
        assert(deadline == 3, "Init must use the original Start deadline after discovery")
    end
    timeoutRuntime:advance(1)
    assert(coroutine.status(timeoutThread) == "dead" and not timeoutResult.ok
        and timeoutResult.failure.code == "StartupTimeout" and timeoutRuntime.now == 3
        and timeoutRuntime.connections == 0
        and next(timeoutRuntime.timers) == nil)
    local timeoutFailure = timeoutClient:GetDiagnostics().lastStartFailure
    assert(timeoutFailure ~= nil and timeoutFailure.stage == "OrderedInitialization"
        and timeoutFailure.code == "StartupTimeout")

    local cancelRuntime = ClientRuntime.create()
    cancelRuntime:transport(compiled.descriptor, true)
    local cancelClient = assert(cancelRuntime.module.create(definition, { startupTimeoutSeconds = 3 }))
    local cancelThread, cancelResult = beginStart(cancelClient)
    assert(coroutine.status(cancelThread) == "suspended" and next(cancelRuntime.timers) ~= nil)
    cancelClient:Destroy()
    cancelRuntime:flush()
    assert(coroutine.status(cancelThread) == "dead" and not cancelResult.ok
        and cancelResult.failure.code == "Destroyed" and cancelRuntime.connections == 0
        and next(cancelRuntime.timers) == nil
        and cancelClient:GetDiagnostics().lastStartFailure == nil)
end

print("PASS Relay.OrderedUnreliable framing, serial admission, initialization, and fan-out")
