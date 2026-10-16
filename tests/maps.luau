local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local CompositeCodec = require("../src/internal/CompositeCodec")
local BatchFrame = require("../src/internal/BatchFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local OrderedFrame = require("../src/internal/OrderedFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local schema = require("../src/Schema")

local function defineMap(map, name)
	local shape = table.clone(map)
	shape.type = "map"
	shape.name = "values"
	return Definition.define({ name = name or "MapTest", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", fields = { shape } },
	} })
end

local function encode(event, ...)
	local result = table.pack(Frame.compile(event, "encode")(...))
	assert(result.n == 2 and result[1] == true, "expected map frame to encode")
	return result[2]
end

local function copied(value, length)
	local result = buffer.create(length)
	buffer.copy(result, 0, value, 0, math.min(length, buffer.len(value)))
	return result
end

local key = { type = "u8" }
local value = { type = "boolean" }
local helper = schema.map(key, value, 4)
local helperDefinition = assert(defineMap(helper, "MapShape"))
local rawDefinition = assert(defineMap({ key = key, value = value, maximumSize = 4 }, "MapShape"))
local helperCompiled = assert(Definition.get(helperDefinition))
assert(helperCompiled.descriptor == Definition.get(rawDefinition).descriptor
	and string.find(helperCompiled.descriptor, "M4[", 1, true),
	"map helpers and raw schemas share one compatibility descriptor")
assert(helperCompiled.events.Input.usesCodec and helperCompiled.events.Input.maximumElements == 9)
local report = assert(Definition.inspect(helperDefinition))
assert(report.limits.mapCapacity == 64 and report.limits.arraySetCapacity == 64)
assert(Definition.get(assert(Definition.define({ name = "LegacyMapTest", version = 1, events = {
	Ping = { id = 1, direction = "ClientToServer", fields = {} },
} }))).descriptor == "RR1|D13:LegacyMapTest|V1|N1|E1,C,4:Ping,0",
	"legacy scalar descriptors retain their original bytes")

local integerKinds = { "u8", "i8", "u16", "i16", "u32", "i32" }
for index, kind in integerKinds do
	local definition = assert(defineMap({ key = { type = kind }, value = { type = "string", maximumBytes = 8 },
		maximumSize = 1 }, `MapKey{index}`))
	local event = Definition.get(definition).events.Input
	local keyValue = if kind == "u8" then 0 elseif kind == "i8" then -1 elseif kind == "u16" then 0
		elseif kind == "i16" then -1 elseif kind == "u32" then 0 else -1
	local packet = encode(event, { [keyValue] = "value" })
	local ok, decoded = Frame.compile(event, "decode")(packet)
	assert(ok and decoded[keyValue] == "value", `integer map key {kind} round trips`)
end

local function invalidMap(map, message)
	local definition, problem = defineMap(map, "InvalidMap")
	assert(definition == nil and problem and problem.code == "InvalidDefinition", message)
end
for _, maximumSize in { -1, 1.5, 65 } do
	invalidMap({ key = { type = "u8" }, value = { type = "boolean" }, maximumSize = maximumSize },
		"map size must be an integer from zero through 64")
end
for _, keyType in { "boolean", "enum", "f32", "Vector2F32" } do
	local shape = if keyType == "enum" then { type = "enum", values = { "A", "B" } }
		elseif keyType == "f32" or keyType == "Vector2F32" then { type = keyType, minimum = -1, maximum = 1 }
		else { type = keyType }
	invalidMap({ key = shape, value = { type = "u8" }, maximumSize = 1 },
		"only string and integer map keys are supported")
end
invalidMap({ key = { type = "u8" }, value = { type = "optional", value = { type = "u8" } }, maximumSize = 1 },
	"root optional map values are rejected")
invalidMap({ key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 64, extra = true },
	"map descriptor metadata stays closed")
local cyclicMap = { type = "map", key = { type = "u8" }, maximumSize = 1 }
cyclicMap.value = cyclicMap
invalidMap(cyclicMap, "cyclic map shapes are rejected")
local deepValue = { type = "u8" }
for _ = 1, 5 do
	deepValue = { type = "map", key = { type = "u8" }, value = deepValue, maximumSize = 1 }
end
invalidMap({ key = { type = "u8" }, value = deepValue, maximumSize = 1 },
	"map nesting counts against the composite depth bound")
invalidMap({ key = { type = "u8" }, value = { type = "struct", fields = {
	{ name = "first", type = "boolean" }, { name = "second", type = "boolean" },
	{ name = "third", type = "boolean" },
} }, maximumSize = 64 }, "map expansion counts against the event node bound")

local fullMap = assert(Definition.define({ name = "MapCapacity", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
		key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 64 } } },
} }))
local fullEvent = Definition.get(fullMap).events.Input
local fullValues = {}
for index = 0, 63 do fullValues[index] = index % 2 == 0 end
local fullPacket = encode(fullEvent, fullValues)
local fullOk, fullDecoded = Frame.compile(fullEvent, "decode")(fullPacket)
assert(fullOk and buffer.len(fullPacket) == 133 and fullDecoded[0] == true and fullDecoded[1] == false
	and fullDecoded[63] == false, "map capacity 64 reaches its bound and preserves false values")
local tooManyValues = table.clone(fullValues)
tooManyValues[64] = true
assert(Frame.compile(fullEvent, "encode")(tooManyValues) == nil, "map entry 65 is rejected")

local emptyMap = assert(Definition.define({ name = "EmptyMap", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
		key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 0 } } },
} }))
local emptyEvent = Definition.get(emptyMap).events.Input
local emptyPacket = encode(emptyEvent, {})
local emptyOk, emptyDecoded = Frame.compile(emptyEvent, "decode")(emptyPacket)
assert(emptyOk and next(emptyDecoded) == nil and Frame.compile(emptyEvent, "encode")({ [1] = true }) == nil,
	"zero-capacity maps accept only empty dictionaries")

local mapEvent = helperCompiled.events.Input
local inputMap = { [1] = false, [2] = true }
local encodedMap = encode(mapEvent, inputMap)
local decodedResult = table.pack(Frame.compile(mapEvent, "decode")(encodedMap))
assert(decodedResult.n == 2 and decodedResult[1] and decodedResult[2][1] == false
	and decodedResult[2][2] == true, "false map values survive codec encode/decode")
local normalizedResult = table.pack(Frame.compile(mapEvent, "validate")(inputMap))
assert(normalizedResult[1] and normalizedResult[2] ~= inputMap,
	"map validation returns an owned dictionary")
normalizedResult[2][1] = true
assert(inputMap[1] == false, "normalized map mutation cannot reach the caller table")

local nestedDefinition = assert(Definition.define({ name = "NestedMap", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
		key = { type = "string", maximumBytes = 8 }, value = { type = "struct", fields = {
			{ name = "mode", type = "taggedUnion", tag = "kind", variants = {
				Ready = { type = "struct", fields = { { name = "enabled", type = "boolean" } } },
				Failed = { type = "struct", fields = { { name = "reason", type = "string", maximumBytes = 8 } } },
			} },
			{ name = "note", type = "optional", value = { type = "string", maximumBytes = 8 } },
		} }, maximumSize = 2 } } },
} }))
local nestedEvent = Definition.get(nestedDefinition).events.Input
local nestedPayload = { first = { mode = { kind = "Ready", enabled = false }, note = nil },
	second = { mode = { kind = "Failed", reason = "missing" }, note = "ok" } }
local nestedPacket = encode(nestedEvent, nestedPayload)
local nestedOk, nestedDecoded = Frame.compile(nestedEvent, "decode")(nestedPacket)
assert(nestedOk and nestedDecoded.first.mode.kind == "Ready" and nestedDecoded.first.mode.enabled == false
	and nestedDecoded.second.mode.reason == "missing" and nestedDecoded.second.note == "ok",
	"maps compose with structs, unions, and optional struct fields")
local nestedNormalized = table.pack(Frame.compile(nestedEvent, "validate")(nestedPayload))
assert(nestedNormalized[1] and nestedNormalized[2].first ~= nestedPayload.first,
	"nested map values are copied during normalization")

local hostileReads = 0
local hostile = setmetatable({ [1] = false }, {
	__index = function() hostileReads += 1; error("unexpected map indexing") end,
	__iter = function() hostileReads += 1; error("unexpected map iteration") end,
	__metatable = false,
})
assert(Frame.compile(mapEvent, "encode")(hostile) == nil and hostileReads == 0,
	"maps reject metatables before invoking __iter or __index")

local decodeMap = Frame.compile(mapEvent, "decode")
local malformed = copied(encodedMap, buffer.len(encodedMap))
buffer.writeu16(malformed, 3, 5)
assert(decodeMap(malformed) == nil, "map count above declared maximum is rejected")
local shortCount = buffer.create(5)
buffer.writeu8(shortCount, 0, 1)
buffer.writeu16(shortCount, 1, 1)
buffer.writeu16(shortCount, 3, 2)
assert(decodeMap(shortCount) == nil, "minimum key/value bytes are checked before traversal")
local duplicate = copied(encodedMap, buffer.len(encodedMap))
duplicate = buffer.create(9)
buffer.writeu8(duplicate, 0, 1)
buffer.writeu16(duplicate, 1, 1)
buffer.writeu16(duplicate, 3, 2)
buffer.writeu8(duplicate, 5, 1)
buffer.writeu8(duplicate, 6, 0)
buffer.writeu8(duplicate, 7, 1)
buffer.writeu8(duplicate, 8, 1)
assert(decodeMap(duplicate) == nil, "duplicate decoded keys reject even when the first value is false")
local keyNormalizations, valueNormalizations = 0, 0
local duplicateProbe = CompositeCodec.compile({ id = 9, delivery = "Reliable",
	minimumEncodedBytes = 5, maximumEncodedBytes = 9,
	fields = { { type = "map", maximumSize = 2, minimumEncodedBytes = 2,
		key = { type = "u8", minimum = 0, maximum = 255, minimumEncodedBytes = 1, marker = "key" },
		value = { type = "u8", minimum = 0, maximum = 255, minimumEncodedBytes = 1, marker = "value" },
	} },
}, "decode", function(shape)
	return function(decoded)
		if shape.marker == "key" then keyNormalizations += 1 else valueNormalizations += 1 end
		return decoded
	end, function() return true end, function() return nil end
end)
local duplicateProbePacket = copied(duplicate, buffer.len(duplicate))
buffer.writeu16(duplicateProbePacket, 1, 9)
assert(duplicateProbe(duplicateProbePacket) == nil and keyNormalizations == 2 and valueNormalizations == 1,
	"duplicate keys are rejected before decoding the second associated value")
local invalidBoolean = copied(encodedMap, buffer.len(encodedMap))
buffer.writeu8(invalidBoolean, 6, 2)
assert(decodeMap(invalidBoolean) == nil, "invalid map values reject")
local trailing = copied(encodedMap, buffer.len(encodedMap) + 1)
buffer.writeu8(trailing, buffer.len(trailing) - 1, 0)
assert(decodeMap(trailing) == nil, "map codec rejects trailing bytes")
local invalidSource = { [1] = false, [2] = 1 }
assert(Frame.compile(mapEvent, "encode")(invalidSource) == nil,
	"invalid map values reject during normalization")

local narrowKeyDefinition = assert(Definition.define({ name = "NarrowMapKey", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
		key = { type = "u8", minimum = 5, maximum = 7 }, value = { type = "boolean" }, maximumSize = 1 } } },
} }))
local narrowKeyEvent = Definition.get(narrowKeyDefinition).events.Input
local narrowedPacket = encode(narrowKeyEvent, { [5] = false })
local narrowedInvalid = copied(narrowedPacket, buffer.len(narrowedPacket))
buffer.writeu8(narrowedInvalid, 5, 4)
assert(Frame.compile(narrowKeyEvent, "decode")(narrowedInvalid) == nil
	and Frame.compile(narrowKeyEvent, "encode")({ [4] = false }) == nil,
	"integer map keys enforce their narrowed wire and source bounds")

local invalidStringDefinition = assert(Definition.define({ name = "StringMapKey", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
		key = { type = "string", maximumBytes = 2 }, value = { type = "u8" }, maximumSize = 1 } } },
} }))
local invalidStringEvent = Definition.get(invalidStringDefinition).events.Input
local missingStringKey = buffer.create(5)
buffer.writeu8(missingStringKey, 0, 1)
buffer.writeu16(missingStringKey, 1, 1)
buffer.writeu16(missingStringKey, 3, 1)
assert(Frame.compile(invalidStringEvent, "decode")(missingStringKey) == nil,
	"truncated map keys reject before traversal")
local truncatedStringValue = buffer.create(8)
buffer.writeu8(truncatedStringValue, 0, 1)
buffer.writeu16(truncatedStringValue, 1, 1)
buffer.writeu16(truncatedStringValue, 3, 1)
buffer.writeu16(truncatedStringValue, 5, 1)
buffer.writeu8(truncatedStringValue, 7, 65)
assert(Frame.compile(invalidStringEvent, "decode")(truncatedStringValue) == nil,
	"truncated map values reject after a complete key")
local invalidString = buffer.create(11)
buffer.writeu8(invalidString, 0, 1)
buffer.writeu16(invalidString, 1, 1)
buffer.writeu16(invalidString, 3, 1)
buffer.writeu16(invalidString, 5, 3)
buffer.writestring(invalidString, 7, "abc")
buffer.writeu8(invalidString, 10, 7)
assert(Frame.compile(invalidStringEvent, "decode")(invalidString) == nil,
	"map string keys enforce their declared byte bound")

-- Maps keep the existing event, ordered, queued, and RPC byte limits.
local boundary = assert(Definition.define({ name = "MapByteBoundary", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = { {
		name = "values", type = "map", key = { type = "string", maximumBytes = 892 },
		value = { type = "u8" }, maximumSize = 1,
	} } },
	Ordered = { id = 2, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = { {
		name = "values", type = "map", key = { type = "string", maximumBytes = 884 },
		value = { type = "u8" }, maximumSize = 1,
	} } },
	Batch = { id = 3, direction = "ClientToServer", queue = "Batch", fields = {
		{ name = "values", type = "map", key = { type = "string", maximumBytes = 1_024 },
			value = { type = "string", maximumBytes = 1_017 }, maximumSize = 4 },
		{ name = "tail", type = "u16" },
	} },
} }))
local boundaryCompiled = Definition.get(boundary)
assert(boundaryCompiled.events.Input.maximumEncodedBytes == 900
	and boundaryCompiled.events.Ordered.maximumEncodedBytes == 900
	and boundaryCompiled.events.Batch.maximumEncodedBytes == 8_187,
	"unreliable, ordered, and queued maps retain their exact frame budgets")
local unreliableLimit = encode(boundaryCompiled.events.Input, { [string.rep("x", 892)] = 1 })
local unreliableLimitOk = Frame.compile(boundaryCompiled.events.Input, "decode")(unreliableLimit)
assert(buffer.len(unreliableLimit) == 900 and unreliableLimitOk,
	"map key prefixes and bytes reach the exact unreliable frame limit")
local orderedEvent = boundaryCompiled.events.Ordered
local orderedCodecEvent = OrderedFrame.codecEvent(orderedEvent)
local orderedBody = encode(orderedCodecEvent, { [string.rep("x", 884)] = 1 })
local orderedLimit = assert(OrderedFrame.wrap(orderedEvent, orderedBody, 1, 1))
local orderedHeader = assert(OrderedFrame.peek(orderedEvent, orderedEvent.id, orderedLimit))
local orderedDecodeOk = OrderedFrame.decode(orderedEvent, orderedLimit, orderedHeader,
	Frame.compile(orderedCodecEvent, "decode"))
assert(buffer.len(orderedLimit) == 900 and orderedDecodeOk,
	"ordered maps reach the exact 900-byte outer-frame limit")
local overUnreliableToken, overUnreliableProblem = Definition.define({ name = "OverMapUnreliable", version = 1,
	events = { Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {
		{ name = "values", type = "map", key = { type = "string", maximumBytes = 893 },
			value = { type = "u8" }, maximumSize = 1 },
	} } },
})
assert(overUnreliableToken == nil and overUnreliableProblem.code == "InvalidDefinition",
	"the next unreliable byte over the map boundary rejects")
local overOrderedToken, overOrderedProblem = Definition.define({ name = "OverMapOrdered", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = { {
		name = "values", type = "map", key = { type = "string", maximumBytes = 885 },
		value = { type = "u8" }, maximumSize = 1,
	} } },
} })
assert(overOrderedToken == nil and overOrderedProblem.code == "InvalidDefinition",
	"ordered map frame rejects above its existing 900-byte envelope")
local overBatchToken, overBatchProblem = Definition.define({ name = "OverMapBatch", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", queue = "Batch", fields = {
		{ name = "values", type = "map", key = { type = "string", maximumBytes = 1_024 },
			value = { type = "string", maximumBytes = 1_018 }, maximumSize = 4 },
		{ name = "tail", type = "u16" },
	} },
} })
assert(overBatchToken == nil and overBatchProblem.code == "InvalidDefinition",
	"queued map frame rejects above its retained body budget")

local rpcBoundary, rpcBoundaryProblem = Definition.define({ name = "MapRpcBoundary", version = 1, events = {}, requests = {
	Request = { id = 1, request = {
		{ name = "values", type = "map", key = { type = "string", maximumBytes = 1_024 },
			value = { type = "string", maximumBytes = 1_007 }, maximumSize = 4 },
		{ name = "tail", type = "string", maximumBytes = 1 },
	}, response = { type = "map", key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4 } },
} })
assert(rpcBoundary, rpcBoundaryProblem and rpcBoundaryProblem.message)
assert(Definition.get(rpcBoundary).requests.Request.request.maximumEncodedBytes == 8_148,
	"RPC request map retains the exact body ceiling")
local overRpc, overRpcProblem = Definition.define({ name = "OverMapRpc", version = 1, events = {}, requests = {
	Request = { id = 1, request = {
		{ name = "values", type = "map", key = { type = "string", maximumBytes = 1_024 },
			value = { type = "string", maximumBytes = 1_007 }, maximumSize = 4 },
		{ name = "tail", type = "string", maximumBytes = 2 },
	}, response = { type = "boolean" } },
} })
assert(overRpc == nil and overRpcProblem.code == "InvalidDefinition",
	"RPC map body rejects above its existing ceiling")

local sessionToken = assert(Definition.define({ name = "MapSession", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
		key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4 } } },
	Output = { id = 2, direction = "ServerToClient", fields = { { name = "values", type = "map",
		key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4 } } },
	BatchInput = { id = 3, direction = "ClientToServer", queue = "Batch", fields = { { name = "values", type = "map",
		key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4 } } },
	StateInput = { id = 4, direction = "ClientToServer", queue = "State", fields = { { name = "values", type = "map",
		key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4 } } },
	OrderedInput = { id = 5, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = { {
		name = "values", type = "map", key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4,
	} } },
}, requests = {
	Lookup = { id = 6, request = { { name = "query", type = "map", key = { type = "string", maximumBytes = 8 },
		value = { type = "u8" }, maximumSize = 4 } },
		response = { type = "map", key = { type = "u8" }, value = { type = "boolean" }, maximumSize = 4 } },
} }))
local sessionCompiled = assert(Definition.get(sessionToken))
local sessionMap = { [1] = false, [2] = true }

-- Map descriptor changes fail compatibility before a client can send application data.
do
	local function startupDefinition(keyType, valueType, maximumSize)
		return Definition.define({ name = "MapStartup", version = 1, events = {
			Input = { id = 1, direction = "ClientToServer", fields = { { name = "values", type = "map",
				key = { type = keyType }, value = { type = valueType }, maximumSize = maximumSize } } },
		} })
	end
	local base = assert(startupDefinition("u8", "boolean", 4))
	for _, changed in { { "u16", "boolean", 4 }, { "u8", "u16", 4 }, { "u8", "boolean", 3 } } do
		local changedToken = assert(startupDefinition(changed[1], changed[2], changed[3]))
		local runtime = ClientRuntime.create()
		runtime:transport(Definition.get(changedToken).descriptor, false)
		local client = assert(runtime.module.create(base, { startupTimeoutSeconds = 3 }))
		local started, problem = client:Start()
		assert(not started and problem.code == "DefinitionMismatch" and #runtime.fires == 0,
			"map key, value, or size mismatch rejects during startup")
		client:Destroy()
	end
end

local serverRuntime = ServerRuntime.new()
local firstPlayer, secondPlayer = serverRuntime:addPlayer(), serverRuntime:addPlayer()
local server = assert(serverRuntime.server.create(sessionToken, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 1 }, aggregate = { capacity = 32, refillPerSecond = 1 },
} }))
assert(server:Start())
local calls = { Input = 0, Batch = 0, State = 0, Ordered = 0, Lookup = 0 }
assert(server.events.Input:Connect(function(sender, values)
	assert(sender == firstPlayer and values[1] == false and values[2] == true)
	calls.Input += 1
end))
assert(server.events.BatchInput:Connect(function(sender, values)
	assert(sender == firstPlayer and values[1] == false)
	calls.Batch += 1
end))
assert(server.events.StateInput:Connect(function(sender, values)
	assert(sender == firstPlayer and values[2] == true)
	calls.State += 1
end))
assert(server.events.OrderedInput:Connect(function(sender, values)
	assert(sender == firstPlayer and values[1] == false)
	calls.Ordered += 1
end))
assert(server.requests.Lookup:Connect(function(sender, query)
	assert(sender == firstPlayer and query.alpha == 7)
	calls.Lookup += 1
	return sessionMap
end))
local remote = serverRuntime:remote()
local inputFrame = encode(sessionCompiled.events.Input, sessionMap)
remote.OnServerEvent:Fire(firstPlayer, 1, inputFrame)
local queuedBody = encode(sessionCompiled.queuedById[3], sessionMap)
remote.OnServerEvent:Fire(firstPlayer, 0, assert(BatchFrame.wrap(1, { queuedBody }, 8_192)))
local stateBody = encode(sessionCompiled.queuedById[4], sessionMap)
remote.OnServerEvent:Fire(firstPlayer, 0, assert(BatchFrame.wrap(2, { stateBody }, 8_192)))
local guid = "01234567-89ab-cdef-0123-456789abcdef"
local method = sessionCompiled.requests.Lookup
local requestBody = encode(method.request, { alpha = 7 })
remote.OnServerEvent:Fire(firstPlayer, 0, assert(RpcFrame.wrap(1, method.id, 1, guid, requestBody)))
local rpcPacket = serverRuntime.fires[#serverRuntime.fires].values[2]
local rpcHeader = assert(RpcFrame.peek(rpcPacket, false))
local rpcResponseBody = assert(RpcFrame.readBody(rpcPacket, rpcHeader,
	method.response.minimumEncodedBytes, method.response.maximumEncodedBytes))
local rpcResponseOk, rpcResponse = Frame.compile(method.response, "decode")(rpcResponseBody)
assert(calls.Input == 1 and calls.Batch == 1 and calls.State == 1 and calls.Lookup == 1
	and rpcHeader.kind == 2 and rpcResponseOk and rpcResponse[1] == false,
	"server immediate, FIFO, State, and RPC ingress decode and return maps")

assert(server.events.Output:Send(firstPlayer, sessionMap))
local serverOutputOk, serverOutput = Frame.compile(sessionCompiled.events.Output, "decode")(
	serverRuntime.fires[#serverRuntime.fires].values[2])
assert(serverOutputOk and serverOutput[1] == false, "server-to-client event encodes maps")

local malformedOrderedBody = encode(OrderedFrame.codecEvent(sessionCompiled.events.OrderedInput), sessionMap)
local duplicateOrderedBody = buffer.create(9)
buffer.writeu8(duplicateOrderedBody, 0, 1)
buffer.writeu16(duplicateOrderedBody, 1, sessionCompiled.events.OrderedInput.id)
buffer.writeu16(duplicateOrderedBody, 3, 2)
buffer.writeu8(duplicateOrderedBody, 5, 1)
buffer.writeu8(duplicateOrderedBody, 6, 0)
buffer.writeu8(duplicateOrderedBody, 7, 1)
buffer.writeu8(duplicateOrderedBody, 8, 1)
local orderedRemote = serverRuntime:unreliableRemote()
remote.OnServerEvent:Fire(firstPlayer, 0, assert(OrderedFrame.hello("abcdefab-cdef-4000-8000-000000000010")))
orderedRemote.OnServerEvent:Fire(firstPlayer, 5,
	assert(OrderedFrame.wrap(sessionCompiled.events.OrderedInput, duplicateOrderedBody, 1, 1)))
orderedRemote.OnServerEvent:Fire(firstPlayer, 5,
	assert(OrderedFrame.wrap(sessionCompiled.events.OrderedInput, malformedOrderedBody, 1, 1)))
assert(calls.Ordered == 1 and server:GetDiagnostics().events.OrderedInput.invalidPayload == 1,
	"malformed ordered map payload does not consume the valid sequence number")
server:Destroy()

local clientRuntime = ClientRuntime.create()
local _, _, clientRemote = clientRuntime:transport(sessionCompiled.descriptor, sessionCompiled.hasUnreliable)
clientRuntime.onFire = function(_, endpointId, control)
	if endpointId == 0 then
		local clientGuid = OrderedFrame.readHello(control)
		if clientGuid ~= nil then
			clientRemote.OnClientEvent:fire(0, assert(OrderedFrame.initialization(clientGuid, 1)))
		end
	end
end
local client = assert(clientRuntime.module.create(sessionToken, { startupTimeoutSeconds = 3 }))
assert(client:Start())
assert(client.events.Input:Send(sessionMap))
local clientOutputOk, clientOutput = Frame.compile(sessionCompiled.events.Input, "decode")(
	clientRuntime.fires[#clientRuntime.fires][2])
assert(clientOutputOk and clientOutput[1] == false, "client-to-server event encodes maps")
local receivedOutput = 0
assert(client.events.Output:Connect(function(values)
	assert(values[1] == false and values[2] == true)
	receivedOutput += 1
end))
clientRemote.OnClientEvent:fire(2, encode(sessionCompiled.events.Output, sessionMap))
assert(receivedOutput == 1, "client event listener decodes maps")
local pending = assert(client.requests.Lookup:Request(3, { alpha = 7 }))
local clientRequest = clientRuntime.fires[#clientRuntime.fires][2]
local clientRequestHeader = assert(RpcFrame.peek(clientRequest, true))
local clientRequestBody = assert(RpcFrame.readBody(clientRequest, clientRequestHeader,
	method.request.minimumEncodedBytes, method.request.maximumEncodedBytes))
local clientRequestOk, clientRequestMap = Frame.compile(method.request, "decode")(clientRequestBody)
assert(clientRequestOk and clientRequestMap.alpha == 7, "client RPC request carries a map")
pending:Cancel()
client:Destroy()

-- Malformed map payloads retain call and byte admission charges before decode rejects.
do
	local runtime = ServerRuntime.new()
	local first, second = runtime:addPlayer(), runtime:addPlayer()
	local mapServer = assert(runtime.server.create(sessionToken, { inboundRate = {
		perPlayer = { capacity = 8, refillPerSecond = 1 }, aggregate = { capacity = 16, refillPerSecond = 1 },
		bytes = {
			perPlayer = { capacity = buffer.len(inputFrame), refillPerSecond = 1 },
			aggregate = { capacity = buffer.len(inputFrame), refillPerSecond = 1 },
		},
	} }))
	assert(mapServer:Start())
	local received = 0
	assert(mapServer.events.Input:Connect(function() received += 1 end))
	local bad = copied(inputFrame, buffer.len(inputFrame))
	buffer.writeu8(bad, buffer.len(bad) - 1, 2)
	local mapRemote = runtime:remote()
	mapRemote.OnServerEvent:Fire(first, 1, bad)
	mapRemote.OnServerEvent:Fire(first, 1, inputFrame)
	mapRemote.OnServerEvent:Fire(second, 1, inputFrame)
	local counters = mapServer:GetDiagnostics().counters
	assert(received == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
		and counters.aggregateBytes == 1,
		"malformed map decode keeps per-player and aggregate byte charges")
	mapServer:Destroy()
end

-- A malformed map still spends the same-player base call allowance before decode rejects.
do
	local runtime = ServerRuntime.new()
	local first, second = runtime:addPlayer(), runtime:addPlayer()
	local mapServer = assert(runtime.server.create(sessionToken, { inboundRate = {
		perPlayer = { capacity = 1, refillPerSecond = 1 }, aggregate = { capacity = 1, refillPerSecond = 1 },
	} }))
	assert(mapServer:Start())
	local received = 0
	assert(mapServer.events.Input:Connect(function() received += 1 end))
	local bad = copied(inputFrame, buffer.len(inputFrame))
	buffer.writeu8(bad, buffer.len(bad) - 1, 2)
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(first, 1, bad)
	remote.OnServerEvent:Fire(first, 1, inputFrame)
	remote.OnServerEvent:Fire(second, 1, inputFrame)
	local counters = mapServer:GetDiagnostics().counters
	assert(received == 0 and counters.invalidPayload == 1 and counters.perPlayerRate == 1
		and counters.aggregateRate == 1,
		"malformed map frames retain per-player and aggregate base-call debits")
	mapServer:Destroy()
end

-- Endpoint admission also remains spent after the decoder rejects a map.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local mapServer = assert(runtime.server.create(sessionToken, { inboundRate = {
		perPlayer = { capacity = 8, refillPerSecond = 1 }, aggregate = { capacity = 16, refillPerSecond = 1 },
		endpoints = { [1] = { capacity = 1, refillPerSecond = 1 } },
	} }))
	assert(mapServer:Start())
	local received = 0
	assert(mapServer.events.Input:Connect(function() received += 1 end))
	local bad = copied(inputFrame, buffer.len(inputFrame))
	buffer.writeu8(bad, buffer.len(bad) - 1, 2)
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(player, 1, bad)
	remote.OnServerEvent:Fire(player, 1, inputFrame)
	local snapshot = mapServer:GetDiagnostics()
	assert(received == 0 and snapshot.events.Input.invalidPayload == 1
		and snapshot.counters.endpointRate == 1 and snapshot.events.Input.endpointRate == 1,
		"malformed map frames retain their endpoint admission debit")
	mapServer:Destroy()
end

-- A malformed final map row prevents every FIFO/State callback and keeps the envelope debit.
do
	for _, queued in { { id = 3, kind = 1 }, { id = 4, kind = 2 } } do
		local validBody = encode(sessionCompiled.queuedById[queued.id], sessionMap)
		local badBody = copied(validBody, buffer.len(validBody))
		buffer.writeu8(badBody, buffer.len(badBody) - 1, 2)
		local packet = assert(BatchFrame.wrap(queued.kind, { validBody, badBody }, 8_192))
		local runtime = ServerRuntime.new()
		local player = runtime:addPlayer()
		local mapServer = assert(runtime.server.create(sessionToken, { inboundRate = {
			perPlayer = { capacity = 8, refillPerSecond = 1 }, aggregate = { capacity = 16, refillPerSecond = 1 },
			bytes = {
				perPlayer = { capacity = buffer.len(packet), refillPerSecond = 1 },
				aggregate = { capacity = buffer.len(packet), refillPerSecond = 1 },
			},
		} }))
		assert(mapServer:Start())
		local calls = 0
		local name = if queued.kind == 1 then "BatchInput" else "StateInput"
		assert(mapServer.events[name]:Connect(function() calls += 1 end))
		runtime:remote().OnServerEvent:Fire(player, 0, packet)
		runtime:remote().OnServerEvent:Fire(player, 1, inputFrame)
		local counters = mapServer:GetDiagnostics().counters
		assert(calls == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1,
			`invalid final map row prevents queued callbacks and retains bytes (calls={calls}, invalid={counters.invalidPayload}, playerBytes={counters.perPlayerBytes})`)
		mapServer:Destroy()
	end
end

print("PASS Relay.Maps")
