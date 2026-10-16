local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Relay = require("../src")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		require = function(path)
			assert(path == "./CompositeCodec")
			return require("../src/internal/CompositeCodec")
		end,
	},
	injectGlobals = true,
})()

local function rawUnion(tag)
	return {
		type = "taggedUnion",
		tag = tag or "kind",
		variants = {
			Success = { type = "struct", fields = {
				{ name = "value", type = "u8" },
				{ name = "note", type = "optional", value = { type = "string", maximumBytes = 8 } },
				{ name = "colors", type = "array", maximumLength = 2, element = { type = "Color3" } },
			} },
			Failure = { type = "struct", fields = {
				{ name = "reason", type = "string", maximumBytes = 8 },
			} },
		},
	}
end

local function definitionFor(union, name, delivery)
	local field = table.clone(union)
	field.name = "result"
	local event = { id = 1, direction = "ClientToServer", fields = { field }, delivery = delivery }
	return Definition.define({ name = name or "TaggedUnionTest", version = 1, events = {
		Input = event,
	} })
end

local function assertInvalid(union, fragment, label, delivery)
	local token, problem = definitionFor(union, "BadTaggedUnion", delivery)
	assert(token == nil and problem and problem.code == "InvalidDefinition", label)
	if fragment then assert(string.find(problem.message, fragment, 1, true), problem.message) end
end

local function encode(event, ...)
	local result = table.pack(Frame.compile(event, "encode")(...))
	assert(result.n == 2 and result[1] == true, "expected tagged union frame to encode")
	return result[2]
end

local function copied(value, length)
	local result = buffer.create(length)
	buffer.copy(result, 0, value, 0, math.min(length, buffer.len(value)))
	return result
end

-- The helper owns only its outer map and record; define snapshots every selected branch.
do
	local schema = Relay.schema
	local branch = { type = "struct", fields = { { name = "value", type = "u8" } } }
	local supplied = { Ready = branch }
	local helper = schema.taggedUnion("kind", supplied)
	assert(table.isfrozen(helper) and table.isfrozen(helper.variants)
		and helper.variants ~= supplied and helper.variants.Ready == branch and not table.isfrozen(branch))
	supplied.Added = branch
	assert(helper.variants.Added == nil, "tagged union helper copies its literal variant map")
	local helperToken, helperError = definitionFor(helper, "TaggedUnionHelper")
	assert(helperToken and helperError == nil)
	local rawToken, rawError = definitionFor({ type = "taggedUnion", tag = "kind", variants = {
		Ready = { type = "struct", fields = { { name = "value", type = "u8" } } },
	} }, "TaggedUnionHelper")
	assert(rawToken and rawError == nil
		and Definition.get(helperToken).descriptor == Definition.get(rawToken).descriptor,
		"schema helper and raw tagged union shapes compile to the same descriptor")
	branch.fields[1].type = "boolean"
	assert(Definition.get(helperToken).descriptor == Definition.get(rawToken).descriptor,
		"define snapshots nested helper branch shapes")
end

local union = rawUnion()
local function unionField(shape)
	return { name = "result", type = shape.type, tag = shape.tag, variants = shape.variants }
end

local function defineWithUnion(shape)
	return Definition.define({ name = "TaggedUnionCodec", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", fields = { unionField(shape) } },
		Output = { id = 2, direction = "ServerToClient", fields = { unionField(shape) } },
		BatchInput = { id = 3, direction = "ClientToServer", queue = "Batch", fields = { unionField(shape) } },
		StateInput = { id = 4, direction = "ClientToServer", queue = "State", fields = { unionField(shape) } },
		BatchOutput = { id = 5, direction = "ServerToClient", queue = "Batch", fields = { unionField(shape) } },
		StateOutput = { id = 6, direction = "ServerToClient", queue = "State", fields = { unionField(shape) } },
		NestedInput = { id = 8, direction = "ClientToServer", fields = {
			{ name = "items", type = "array", maximumLength = 2, element = {
				type = shape.type, tag = shape.tag, variants = shape.variants,
			} },
			{ name = "maybe", type = "optional", value = {
				type = shape.type, tag = shape.tag, variants = shape.variants,
			} },
		} },
	}, requests = {
		Inspect = { id = 7, request = { unionField(shape) }, response = shape },
	} })
end

local token, problem = defineWithUnion(union)
assert(token and problem == nil, problem and problem.message)
local compiled = assert(Definition.get(token))
local report = assert(Definition.inspect(token))
local event = compiled.events.Input
assert(event.usesCodec and event.minimumEncodedBytes == 6 and event.maximumEncodedBytes == 42)
assert(report.events.Input.bytes.representation == "RelayBuffer"
	and report.events.Input.bytes.minimum == 6 and report.events.Input.bytes.maximum == 42)
assert(string.find(compiled.descriptor, "U4:kind2[7:Failure=", 1, true)
	and string.find(compiled.descriptor, "7:Success=", 1, true),
	"descriptor sorts discriminator labels before encoding")

local success = { kind = "Success", value = 9, note = nil,
	colors = { roblox.Color3.new(0.1, 0.2, 0.3) } }
local failure = { kind = "Failure", reason = "missing" }
local successFrame = encode(event, success)
assert(buffer.readu8(successFrame, 3) == 1, "sorted Success branch uses ordinal one")
local decodedSuccess = table.pack(Frame.compile(event, "decode")(successFrame))
assert(decodedSuccess.n == 2 and decodedSuccess[1] and decodedSuccess[2].kind == "Success"
	and decodedSuccess[2].value == 9 and decodedSuccess[2].note == nil
	and #decodedSuccess[2].colors == 1 and decodedSuccess[2].colors[1] == success.colors[1])
local failureFrame = encode(event, failure)
assert(buffer.readu8(failureFrame, 3) == 0, "sorted Failure branch uses ordinal zero")
local decodedFailure = table.pack(Frame.compile(event, "decode")(failureFrame))
assert(decodedFailure.n == 2 and decodedFailure[1]
	and decodedFailure[2].kind == "Failure" and decodedFailure[2].reason == "missing")
local nestedEvent = compiled.events.NestedInput
local nestedResult = table.pack(Frame.compile(nestedEvent, "encode")({ success, failure }, success))
assert(nestedResult[1] == true, `nested union encode failed: {tostring(nestedResult[2])}`)
local nestedFrame = nestedResult[2]
local nestedOk, nestedItems, nestedMaybe = Frame.compile(nestedEvent, "decode")(nestedFrame)
assert(nestedOk and nestedItems[1].kind == "Success" and nestedItems[1].value == success.value
	and nestedItems[2].kind == "Failure" and nestedItems[2].reason == failure.reason
	and nestedMaybe.kind == "Success" and nestedMaybe.value == success.value,
	"tagged unions round-trip when nested as array elements and optional values")

local normalized = table.pack(Frame.compile(event, "validate")(success))
assert(normalized[1] and normalized[2] ~= success and normalized[2].colors ~= success.colors
	and normalized[2].kind == "Success", "validation returns invocation-owned tagged union copies")
normalized[2].colors[1] = roblox.Color3.new(1, 1, 1)
assert(success.colors[1] ~= normalized[2].colors[1], "normalized nested arrays do not alias input")

local hostileReads = 0
local hostile = setmetatable({ kind = "Success", value = 9, colors = {} }, {
	__index = function() hostileReads += 1; return nil end,
	__iter = function() hostileReads += 1; return next end,
	__metatable = false,
})
for _, bad in {
	{}, { value = 9, colors = {} }, { kind = 5, value = 9, colors = {} },
	{ kind = "Other", value = 9, colors = {} },
	{ kind = "Success", reason = "inactive" },
	{ kind = "Success", value = 9, colors = {}, extra = true },
	hostile,
} do
	assert(Frame.compile(event, "encode")(bad) == nil, "invalid tag and selected-branch fields reject")
end
assert(hostileReads == 0, "tagged union rejects protected metatables before iteration or indexing")

local invalidOrdinal = copied(successFrame, buffer.len(successFrame))
buffer.writeu8(invalidOrdinal, 3, 32)
assert(Frame.compile(event, "decode")(invalidOrdinal) == nil, "decoder rejects an ordinal outside the bounded variant list")
assert(Frame.compile(event, "decode")(copied(successFrame, buffer.len(successFrame) - 1)) == nil,
	"decoder rejects truncated selected-variant bodies")
assert(Frame.compile(event, "decode")(copied(successFrame, buffer.len(successFrame) + 1)) == nil,
	"decoder rejects trailing bytes after a selected variant")

-- The discriminator exception belongs only to each compiled union branch.
do
	local shared = { type = "struct", fields = { { name = "value", type = "u8" } } }
	local standaloneShape = table.clone(shared)
	standaloneShape.name = "record"
	local isolation = assert(Definition.define({ name = "TaggedUnionIsolation", version = 1, events = {
		Standalone = { id = 1, direction = "ClientToServer", fields = { standaloneShape } },
		Kind = { id = 2, direction = "ClientToServer", fields = { { name = "record", type = "taggedUnion",
			tag = "kind", variants = { Ready = shared } } } },
		Status = { id = 3, direction = "ClientToServer", fields = { { name = "record", type = "taggedUnion",
			tag = "status", variants = { Ready = shared } } } },
	} }))
	local isolationCompiled = assert(Definition.get(isolation))
	local standalone = Frame.compile(isolationCompiled.events.Standalone, "encode")
	local kind = Frame.compile(isolationCompiled.events.Kind, "encode")
	local status = Frame.compile(isolationCompiled.events.Status, "encode")
	assert(standalone({ value = 1, kind = "Ready" }) == nil,
		"standalone struct continues to reject an added discriminator")
	assert(kind({ value = 1, kind = "Ready" }) ~= nil and kind({ value = 1, kind = "Ready", status = "Ready" }) == nil,
		"kind discriminator allowance stays private to its own compiled branch")
	assert(status({ value = 1, status = "Ready" }) ~= nil and status({ value = 1, status = "Ready", kind = "Ready" }) == nil,
		"different union tag keys do not leak between compiled branch structs")
end

-- Ordered and nested branch shapes keep their existing budgets and closed schema.
assertInvalid({ type = "taggedUnion", tag = "bad-tag", variants = { Ready = { type = "struct", fields = {} } } },
	"tag", "invalid discriminator name rejects")
assertInvalid({ type = "taggedUnion", tag = "kind", variants = {} }, "at least one variant", "empty union rejects")
assertInvalid({ type = "taggedUnion", tag = "kind", variants = { [1] = { type = "struct", fields = {} } } },
	"variant keys", "non-string variant keys reject")
assertInvalid({ type = "taggedUnion", tag = "kind", variants = { Ready = { type = "u8" } } },
	"anonymous struct", "non-struct alternatives reject")
assertInvalid({ type = "taggedUnion", tag = "kind", extra = true,
	variants = { Ready = { type = "struct", fields = {} } } }, "unknown key", "union metadata stays closed")
assertInvalid({ type = "taggedUnion", tag = "kind", variants = { Ready = { type = "struct", name = "named",
	fields = {} } } }, "unknown key", "variant structs must be anonymous")
assertInvalid({ type = "taggedUnion", tag = "kind", variants = { Ready = { type = "struct", fields = {
	{ name = "kind", type = "optional", value = { type = "u8" } },
} } } }, "conflicts with discriminator", "optional discriminator collision rejects")
local eightFields = {}
for index = 1, 8 do eightFields[index] = { name = `value{index}`, type = "u8" } end
assertInvalid({ type = "taggedUnion", tag = "kind", variants = { Ready = { type = "struct", fields = eightFields } } },
	"at most 7 fields", "implicit discriminator counts toward the eight-field cap")
local manyVariants = {}
for index = 1, 33 do manyVariants[`V{index}`] = { type = "struct", fields = {} } end
assertInvalid({ type = "taggedUnion", tag = "kind", variants = manyVariants }, "at most 32 variants",
	"variant count stays bounded")

local tooManyAuthored = {}
for variantIndex = 1, 32 do
	local fields = {}
	for fieldIndex = 1, 7 do fields[fieldIndex] = { name = `f{fieldIndex}`, type = "u8" } end
	tooManyAuthored[`V{variantIndex}`] = { type = "struct", fields = fields }
end
assertInvalid({ type = "taggedUnion", tag = "kind", variants = tooManyAuthored }, "authored node count exceeds 256",
	"all alternative subtrees share the authored-node budget")

local expandedVariants = { Wide = { type = "struct", fields = {
	{ name = "a", type = "array", maximumLength = 64, element = { type = "struct", fields = {} } },
	{ name = "b", type = "array", maximumLength = 64, element = { type = "struct", fields = {} } },
	{ name = "c", type = "array", maximumLength = 64, element = { type = "struct", fields = {} } },
	{ name = "d", type = "array", maximumLength = 64, element = { type = "struct", fields = {} } },
} } }
assertInvalid({ type = "taggedUnion", tag = "kind", variants = expandedVariants }, "expanded node count exceeds 256",
	"expanded node bound includes the selected variant structure")
local tooDeep = { Deep = { type = "struct", fields = {
	{ name = "values", type = "array", maximumLength = 1, element = { type = "struct", fields = {
		{ name = "value", type = "optional", value = { type = "u8" } },
	} } },
} } }
assertInvalid({ type = "taggedUnion", tag = "kind", variants = tooDeep }, "composite depth exceeds 4",
	"union and every branch share the existing depth limit")

-- Variant order is canonical, and the union's minimum does not reduce its maximum byte cost.
do
	local orderedA = { Alpha = { type = "struct", fields = { { name = "value", type = "u8" } } },
		Zulu = { type = "struct", fields = { { name = "text", type = "string", maximumBytes = 4 } } } }
	local orderedB = { Zulu = orderedA.Zulu, Alpha = orderedA.Alpha }
	local function descriptor(variants)
		local value = assert(Definition.define({ name = "TaggedUnionOrder", version = 1, events = {
			Input = { id = 1, direction = "ClientToServer", fields = { { name = "result", type = "taggedUnion",
				tag = "kind", variants = variants } } },
		} }))
		return Definition.get(value).descriptor
	end
	assert(descriptor(orderedA) == descriptor(orderedB), "variant map insertion order cannot change compatibility bytes")
end

local boundaryDefinition = assert(Definition.define({ name = "TaggedUnionBoundary", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = { {
		name = "result", type = "taggedUnion", tag = "kind", variants = {
			Empty = { type = "struct", fields = {} },
			Text = { type = "struct", fields = { { name = "text", type = "string", maximumBytes = 894 } } },
		} } } },
} }))
local boundaryEvent = Definition.get(boundaryDefinition).events.Input
assert(boundaryEvent.minimumEncodedBytes == 4 and boundaryEvent.maximumEncodedBytes == 900)
local boundaryValue = { kind = "Text", text = string.rep("x", 894) }
local boundaryFrame = encode(boundaryEvent, boundaryValue)
assert(buffer.len(boundaryFrame) == 900 and Frame.compile(boundaryEvent, "decode")(boundaryFrame) ~= nil,
	"the 894-byte branch reaches the exact unreliable frame limit despite a cheaper alternative")
local overBoundary = { type = "taggedUnion", tag = "kind", variants = {
	Empty = { type = "struct", fields = {} },
	Text = { type = "struct", fields = { { name = "text", type = "string", maximumBytes = 895 } } },
} }
assertInvalid(overBoundary, "900 bytes for Unreliable", "the 895-byte branch exceeds the unreliable maximum", "Unreliable")

-- Public event, RPC, FIFO and State paths all preserve one selected branch end to end.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 64, refillPerSecond = 64 },
		aggregate = { capacity = 128, refillPerSecond = 128 },
	} }))
	assert(server:Start())
	local inputCalls, batchCalls, stateCalls, requestCalls = 0, 0, 0, 0
	assert(server.events.Input:Connect(function(sender, result)
		assert(sender == player and result.kind == "Success" and result.value == success.value)
		inputCalls += 1
	end))
	assert(server.events.BatchInput:Connect(function(sender, result)
		assert(sender == player and result.kind == "Failure" and result.reason == failure.reason)
		batchCalls += 1
	end))
	assert(server.events.StateInput:Connect(function(sender, result)
		assert(sender == player and result.kind == "Success" and result.value == success.value)
		stateCalls += 1
	end))
	assert(server.requests.Inspect:Connect(function(sender, result)
		assert(sender == player and result.kind == "Success" and result.value == success.value)
		requestCalls += 1
		return failure
	end))
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(player, compiled.events.Input.id, successFrame)
	local batchBody = encode(compiled.queuedById[3], failure)
	local batchPacket = assert(BatchFrame.wrap(1, { batchBody }, 8_192))
	remote.OnServerEvent:Fire(player, 0, batchPacket)
	local stateBody = encode(compiled.queuedById[4], success)
	local statePacket = assert(BatchFrame.wrap(2, { stateBody }, 8_192))
	remote.OnServerEvent:Fire(player, 0, statePacket)
	local guid = "01234567-89ab-cdef-0123-456789abcdef"
	local method = compiled.requests.Inspect
	local requestBody = encode(method.request, success)
	remote.OnServerEvent:Fire(player, 0, assert(RpcFrame.wrap(1, method.id, 1, guid, requestBody)))
	local ingressCounters = server:GetDiagnostics().counters
	assert(inputCalls == 1 and batchCalls == 1 and stateCalls == 1 and requestCalls == 1,
		`immediate, FIFO, State and RPC ingress decode tagged unions: {inputCalls}/{batchCalls}/{stateCalls}/{requestCalls}, invalid={ingressCounters.invalidPayload}, unknown={ingressCounters.invalidEndpoint}`)
	local rpcReply = runtime.fires[#runtime.fires].values[2]
	local rpcHeader = assert(RpcFrame.peek(rpcReply, false))
	local rpcResponseBody = assert(RpcFrame.readBody(rpcReply, rpcHeader,
		method.response.minimumEncodedBytes, method.response.maximumEncodedBytes))
	local responseOk, response = Frame.compile(method.response, "decode")(rpcResponseBody)
	assert(rpcHeader.kind == 2 and responseOk and response.kind == "Failure"
		and response.reason == failure.reason, "RPC response keeps its selected variant")

	local sent, sendProblem = server.events.Output:Send(player, success)
	assert(sent, sendProblem and sendProblem.message)
	local directPacket = runtime.fires[#runtime.fires].values[2]
	local directOk, directValue = Frame.compile(compiled.events.Output, "decode")(directPacket)
	assert(directOk and directValue.kind == "Success", "server event sends a tagged union frame")
	local batch = assert(server:CreateBatch({ player }, 0.02))
	assert(batch.events.BatchOutput:Send(failure))
	local batchOk, batchProblem = batch:Flush()
	assert(batchOk, batchProblem and batchProblem.message)
	local outBatch = runtime.fires[#runtime.fires].values[2]
	local outBatchHeader = assert(BatchFrame.header(outBatch, 8_192))
	local outBatchRows = assert(BatchFrame.scan(outBatch, outBatchHeader,
		function(id) return compiled.queuedById[id] end))
	local outBatchBody = assert(BatchFrame.readBody(outBatch, outBatchRows[1]))
	local outBatchOk, outBatchValue = Frame.compile(outBatchRows[1].event, "decode")(outBatchBody)
	assert(outBatchHeader.kind == 1 and outBatchOk and outBatchValue.kind == "Failure")
	local state = assert(server:CreateState({ player }, 0.02))
	assert(state.events.StateOutput:Put(1, "High", success))
	local stateOk, stateProblem = state:Flush()
	assert(stateOk, stateProblem and stateProblem.message)
	local outState = runtime.fires[#runtime.fires].values[2]
	local outStateHeader = assert(BatchFrame.header(outState, 8_192))
	local outStateRows = assert(BatchFrame.scan(outState, outStateHeader,
		function(id) return compiled.queuedById[id] end))
	local outStateBody = assert(BatchFrame.readBody(outState, outStateRows[1]))
	local outStateOk, outStateValue = Frame.compile(outStateRows[1].event, "decode")(outStateBody)
	assert(outStateHeader.kind == 2 and outStateOk and outStateValue.kind == "Success")
	server:Destroy()

	local clientRuntime = ClientRuntime.create()
	local _, _, clientRemote = clientRuntime:transport(compiled.descriptor, compiled.hasUnreliable)
	local client = assert(clientRuntime.module.create(token, { startupTimeoutSeconds = 3 }))
	local clientStarted, clientStartProblem = client:Start()
	assert(clientStarted, clientStartProblem and clientStartProblem.message)
	assert(client.events.Input:Send(success))
	local clientPacket = clientRuntime.fires[#clientRuntime.fires][2]
	local clientOk, clientValue = Frame.compile(event, "decode")(clientPacket)
	assert(clientOk and clientValue.kind == "Success", "client immediate sends preserve a tagged union")
	local outputCalls = 0
	assert(client.events.Output:Connect(function(result)
		assert(result.kind == "Failure" and result.reason == failure.reason)
		outputCalls += 1
	end))
	local outputFrame = encode(compiled.events.Output, failure)
	clientRemote.OnClientEvent:fire(compiled.events.Output.id, outputFrame)
	assert(outputCalls == 1, "client event listener decodes tagged union frames")
	local clientBatch = assert(client:CreateBatch(0.02))
	assert(clientBatch.events.BatchInput:Send(failure))
	local clientBatchOk, clientBatchProblem = clientBatch:Flush()
	assert(clientBatchOk, clientBatchProblem and clientBatchProblem.message)
	local clientBatchPacket = clientRuntime.fires[#clientRuntime.fires][2]
	local clientBatchHeader = assert(BatchFrame.header(clientBatchPacket, 8_192))
	local clientBatchRows = assert(BatchFrame.scan(clientBatchPacket, clientBatchHeader,
		function(id) return compiled.queuedById[id] end))
	local clientBatchBody = assert(BatchFrame.readBody(clientBatchPacket, clientBatchRows[1]))
	local clientBatchDecoded, clientBatchValue = Frame.compile(clientBatchRows[1].event, "decode")(clientBatchBody)
	assert(clientBatchHeader.kind == 1 and clientBatchDecoded and clientBatchValue.kind == "Failure")
	local clientState = assert(client:CreateState(0.02))
	assert(clientState.events.StateInput:Put(2, "Normal", success))
	local clientStateOk, clientStateProblem = clientState:Flush()
	assert(clientStateOk, clientStateProblem and clientStateProblem.message)
	local clientStatePacket = clientRuntime.fires[#clientRuntime.fires][2]
	local clientStateHeader = assert(BatchFrame.header(clientStatePacket, 8_192))
	local clientStateRows = assert(BatchFrame.scan(clientStatePacket, clientStateHeader,
		function(id) return compiled.queuedById[id] end))
	local clientStateBody = assert(BatchFrame.readBody(clientStatePacket, clientStateRows[1]))
	local clientStateDecoded, clientStateValue = Frame.compile(clientStateRows[1].event, "decode")(clientStateBody)
	assert(clientStateHeader.kind == 2 and clientStateDecoded and clientStateValue.kind == "Success")
	local clientPending = assert(client.requests.Inspect:Request(3, success))
	local clientRequestPacket = clientRuntime.fires[#clientRuntime.fires][2]
	local clientRequestHeader = assert(RpcFrame.peek(clientRequestPacket, true))
	local clientRequestBody = assert(RpcFrame.readBody(clientRequestPacket, clientRequestHeader,
		method.request.minimumEncodedBytes, method.request.maximumEncodedBytes))
	local clientRequestOk, clientRequestValue = Frame.compile(method.request, "decode")(clientRequestBody)
	assert(clientRequestOk and clientRequestValue.kind == "Success", "client RPC request carries the selected union branch")
	clientPending:Cancel()
	client:Destroy()
end

-- A changed discriminator changes the descriptor and blocks client startup before application sends.
do
	local mismatchToken, mismatchProblem = defineWithUnion(rawUnion("state"))
	assert(mismatchToken and mismatchProblem == nil)
	local mismatchCompiled = assert(Definition.get(mismatchToken))
	assert(mismatchCompiled.descriptor ~= compiled.descriptor)
	local runtime = ClientRuntime.create()
	runtime:transport(mismatchCompiled.descriptor, mismatchCompiled.hasUnreliable)
	local client = assert(runtime.module.create(token, { startupTimeoutSeconds = 3 }))
	local started, startProblem = client:Start()
	assert(not started and startProblem.code == "DefinitionMismatch" and #runtime.fires == 0,
		"changing only the tagged-union discriminator fails startup before application sends")
	client:Destroy()
end

-- A malformed union on the last FIFO/State row reaches no handler and retains the envelope byte charge.
do
	for _, entry in { { name = "BatchInput", id = 3, kind = 1 }, { name = "StateInput", id = 4, kind = 2 } } do
		local queued = compiled.queuedById[entry.id]
		local firstBody = encode(queued, success)
		local malformedBody = copied(firstBody, buffer.len(firstBody))
		buffer.writeu8(malformedBody, 3, 32)
		local packet = assert(BatchFrame.wrap(entry.kind, { firstBody, malformedBody }, 8_192))
		local runtime = ServerRuntime.new()
		local player = runtime:addPlayer()
		local server = assert(runtime.server.create(token, { inboundRate = {
			perPlayer = { capacity = 8, refillPerSecond = 1 },
			aggregate = { capacity = 16, refillPerSecond = 1 },
			bytes = {
				perPlayer = { capacity = buffer.len(packet), refillPerSecond = 1 },
				aggregate = { capacity = buffer.len(packet) * 2, refillPerSecond = 1 },
			},
		} }))
		assert(server:Start())
		local calls = 0
		assert(server.events[entry.name]:Connect(function() calls += 1 end))
		assert(server.events.Input:Connect(function() calls += 1 end))
		runtime:remote().OnServerEvent:Fire(player, 0, packet)
		local immediate = encode(compiled.events.Input, success)
		runtime:remote().OnServerEvent:Fire(player, compiled.events.Input.id, immediate)
		local counters = server:GetDiagnostics().counters
		assert(calls == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1,
			"bad final union row prevents all FIFO/State callbacks and keeps its admitted bytes")
		server:Destroy()
	end
end

-- Malformed immediate and RPC union payloads keep their byte charge; a same-player retry is silent.
do
	local guid = "01234567-89ab-cdef-0123-456789abcdef"
	local function makeServer(byteCapacity)
		local runtime = ServerRuntime.new()
		local player = runtime:addPlayer()
		local server = assert(runtime.server.create(token, { inboundRate = {
			perPlayer = { capacity = 8, refillPerSecond = 1 },
			aggregate = { capacity = 16, refillPerSecond = 1 },
			bytes = {
				perPlayer = { capacity = byteCapacity, refillPerSecond = 1 },
				aggregate = { capacity = byteCapacity * 2, refillPerSecond = 1 },
			},
		} }))
		assert(server:Start())
		return runtime, player, server, runtime:remote()
	end

	local eventFrame = copied(successFrame, buffer.len(successFrame))
	buffer.writeu8(eventFrame, 3, 32)
	local runtime, player, server, remote = makeServer(buffer.len(eventFrame))
	local eventCalls = 0
	assert(server.events.Input:Connect(function() eventCalls += 1 end))
	remote.OnServerEvent:Fire(player, compiled.events.Input.id, eventFrame)
	remote.OnServerEvent:Fire(player, compiled.events.Input.id, successFrame)
	assert(eventCalls == 0 and server:GetDiagnostics().counters.perPlayerBytes == 1,
		"malformed immediate union decode does not refund the admitted buffer")
	server:Destroy()

	local method = compiled.requests.Inspect
	local requestBody = encode(method.request, success)
	local malformedRequestBody = copied(requestBody, buffer.len(requestBody))
	buffer.writeu8(malformedRequestBody, 3, 32)
	local malformedRequest = assert(RpcFrame.wrap(1, method.id, 1, guid, malformedRequestBody))
	runtime, player, server, remote = makeServer(buffer.len(malformedRequest))
	local requestCalls = 0
	assert(server.requests.Inspect:Connect(function()
		requestCalls += 1
		return failure
	end))
	remote.OnServerEvent:Fire(player, 0, malformedRequest)
	remote.OnServerEvent:Fire(player, 0, assert(RpcFrame.wrap(1, method.id, 2, guid, requestBody)))
	assert(requestCalls == 0 and #runtime.fires == 0 and server:GetDiagnostics().counters.perPlayerBytes == 1,
		"malformed RPC union body keeps its charge and the refused retry sends no reply")
	server:Destroy()
end

-- Endpoint and global charges remain spent after malformed decode and endpoint refusal.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 2, refillPerSecond = 1 },
		aggregate = { capacity = 4, refillPerSecond = 1 },
		endpoints = { [compiled.events.Input.id] = { capacity = 1, refillPerSecond = 1 } },
	} }))
	assert(server:Start())
	local calls = 0
	assert(server.events.Input:Connect(function() calls += 1 end))
	local malformed = copied(successFrame, buffer.len(successFrame))
	buffer.writeu8(malformed, 3, 32)
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(player, compiled.events.Input.id, malformed)
	remote.OnServerEvent:Fire(player, compiled.events.Input.id, successFrame)
	remote.OnServerEvent:Fire(player, compiled.events.Input.id, successFrame)
	local snapshot = server:GetDiagnostics()
	assert(calls == 0 and snapshot.counters.invalidPayload == 1
		and snapshot.counters.endpointRate == 1 and snapshot.events.Input.endpointRate == 1
		and snapshot.counters.perPlayerRate == 1,
		"malformed decode retains endpoint and global charges, and endpoint refusal retains global charge")
	server:Destroy()
end

print("PASS Relay.TaggedUnion bounded variants, compatibility, validation, codec, and budgets")
