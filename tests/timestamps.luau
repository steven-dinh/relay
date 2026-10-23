local Definition = require("../src/Definition")
local Schema = require("../src/Schema")
local Frame = require("../src/internal/Frame")
local OrderedFrame = require("../src/internal/OrderedFrame")
local BatchFrame = require("../src/internal/BatchFrame")
local Runtime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")
local Timestamps = require("../src/internal/Timestamps")

local function assertInvalid(spec, label, path)
	local ok, token, problem = pcall(Definition.define, spec)
	assert(ok and token == nil and problem.code == "InvalidDefinition", label .. " must reject as InvalidDefinition")
	assert(problem.message:find(path, 1, true), label .. " error must identify " .. path)
end

local function eventFields(extra)
	local fields = { { name = "serverTime", type = "f64", minimum = 0, maximum = 2 ^ 41 } }
	for _, field in extra or {} do table.insert(fields, field) end
	return fields
end

local function definition(name, timestampWindow, delivery, queue, bitPacking)
	return assert(Definition.define({
		name = name,
		version = 1,
		bitPacking = bitPacking,
		events = {
			Input = {
				id = 1,
				direction = "ClientToServer",
				delivery = delivery,
				queue = queue,
				timestampWindow = timestampWindow,
				fields = eventFields({ { name = "value", type = "u8" } }),
			},
		},
	}))
end

local function beginClient(token, runtime)
	local compiled = Definition.get(token)
	local root, _, remote, unreliable = runtime:transport(compiled.descriptor, compiled.hasUnreliable)
	local client = assert(runtime.module.create(token, { startupTimeoutSeconds = 3 }))
	if compiled.hasOrderedClientToServer then
		runtime.onFire = function(_, endpointId, control)
			if endpointId == 0 then
				local guid = OrderedFrame.readHello(control)
				if guid ~= nil then
					remote.OnClientEvent:fire(0, assert(OrderedFrame.initialization(guid, 7)))
				end
			end
		end
	end
	assert(client:Start())
	return client, root, remote, unreliable
end

local valid = definition("Stamp", 0.5)
local compiled = Definition.get(valid)
local event = compiled.events.Input
assert(compiled.descriptor:sub(1, 4) == "RR17" and compiled.descriptor:find("|TW", 1, true),
	"timestamp opt-in must select RR17 and encode its window")
assert(event.timestampWindow == 0.5 and event.minimumEncodedBytes == 12 and event.maximumEncodedBytes == 12,
	"the timestamp uses the declared eight-byte f64 field and normal event header")
assert(Definition.inspect(valid).events.Input.timestampWindow == 0.5, "inspection must expose the exact timestamp window")

local otherWindow = Definition.get(definition("Stamp", 0.75)).descriptor
assert(otherWindow ~= compiled.descriptor, "different timestamp windows must not share a descriptor")
local bitPacked = Definition.get(definition("PackedStamp", 2, nil, nil, true))
assert(bitPacked.descriptor:sub(1, 4) == "RR17" and bitPacked.descriptor:find("|BP1", 1, true)
	and bitPacked.descriptor:find("|BND1", 1, true), "RR17 must retain bit-packing and bounded-format markers")
local queued = Definition.get(definition("QueuedStamp", 1, "Reliable", "Batch"))
assert(queued.queuedById[1].timestampWindow == 1
	and queued.descriptor:find("|R0", 1, true), "queued timestamp metadata and existing queue markers must be retained")

local legacyToken = assert(Definition.define({ name = "LegacyStamp", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "f64", minimum = 0, maximum = 2 ^ 41 } } },
} }))
local legacy = Definition.get(legacyToken)
assert(legacy.descriptor:sub(1, 4) == "RR16" and not legacy.descriptor:find("|TW", 1, true),
	"events without the opt-in must retain their previous descriptor format")

for _, invalid in {
	{ name = "zero window", window = 0 },
	{ name = "negative window", window = -0.1 },
	{ name = "large window", window = 2.001 },
	{ name = "infinite window", window = math.huge },
	{ name = "nan window", window = 0 / 0 },
} do
	assertInvalid({ name = "BadStamp", version = 1, events = { Input = {
		id = 1, direction = "ClientToServer", timestampWindow = invalid.window,
		fields = eventFields(),
	} } }, invalid.name, "timestampWindow")
end
assertInvalid({ name = "BadStamp", version = 1, events = { Input = {
	id = 1, direction = "ServerToClient", timestampWindow = 0.5, fields = eventFields(),
} } }, "S2C timestamp", "timestampWindow")
for _, invalid in {
	{ name = "missing timestamp", fields = {} },
	{ name = "wrong field name", fields = { { name = "time", type = "f64", minimum = 0, maximum = 2 ^ 41 } } },
	{ name = "wrong field type", fields = { { name = "serverTime", type = "f32", minimum = 0, maximum = 2 ^ 20 } } },
	{ name = "nonzero minimum", fields = { { name = "serverTime", type = "f64", minimum = 1, maximum = 2 ^ 41 } } },
	{ name = "narrow maximum", fields = { { name = "serverTime", type = "f64", minimum = 0, maximum = 2 ^ 39 } } },
} do
	assertInvalid({ name = "BadStamp", version = 1, events = { Input = {
		id = 1, direction = "ClientToServer", timestampWindow = 0.5, fields = invalid.fields,
	} } }, invalid.name, "fields")
end

local helper = Schema.clientToServer(1, Schema.ordered(
	Schema.field("serverTime", Schema.f64(0, 2 ^ 41))), { timestampWindow = 0.5 })
assert(helper.timestampWindow == 0.5 and table.isfrozen(helper), "Schema helper must preserve and freeze timestampWindow")
assert(not pcall(Schema.serverToClient, 1, Schema.ordered(), { timestampWindow = 0.5 }),
	"server-to-client Schema helpers must reject timestampWindow")
for _, window in { 0, -1, 2.1, math.huge, 0 / 0 } do
	assert(not pcall(Schema.clientToServer, 1, Schema.ordered(), { timestampWindow = window }),
		"Schema helper must reject invalid timestamp windows")
end

do
	local normalized = Timestamps.normalize(100.05, 0.2, 100)
	assert(normalized == 100, "accepted small future skew must clamp to server time")
	assert(Timestamps.normalize(99.8, 0.2, 100) == 99.8, "oldest in-window timestamp must pass")
	for _, value in { 97.99, 100.1001, math.huge, -math.huge, 0 / 0 } do
		assert(Timestamps.normalize(value, 2, 100) == nil, "old, future, and nonfinite claims must fail")
	end
	assert(Timestamps.normalize(100, 0, 100) == nil, "invalid windows must fail closed")
end

local runtime = Runtime.create()
local client = beginClient(valid, runtime)
assert(runtime.serverTimeCalls == 0, "client construction must not sample the server clock")
assert(client.events.Input:Send(9), "timestamped immediate event must send")
assert(runtime.serverTimeCalls == 1, "immediate send must sample once")
local immediate = runtime.fires[#runtime.fires]
assert(immediate[1] == 1 and typeof(immediate[2]) == "buffer", "immediate send must prefix an encoded timestamp")
local decoded = table.pack(Frame.compile(event, "decode")(immediate[2]))
assert(decoded[1] == true and decoded[2] == runtime.serverTime and decoded[3] == 9,
	"immediate payload must encode serverTime before authored fields")

runtime.serverClockUnavailable = true
local before = #runtime.fires
local sent, failure = client.events.Input:Send(9)
assert(not sent and failure.code == "InvalidPayload" and #runtime.fires == before,
	"an unavailable Workspace server clock must reject before sending")
runtime.serverClockUnavailable = false
client:Destroy()

do
	local token = assert(Definition.define({ name = "TimestampQueues", version = 1, events = {
		BatchInput = { id = 1, direction = "ClientToServer", queue = "Batch", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
		StateInput = { id = 2, direction = "ClientToServer", queue = "State", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
	} }))
	local queueRuntime = Runtime.create()
	local queueClient = beginClient(token, queueRuntime)
	local queueCompiled = Definition.get(token)
	local function directQueuedSend(name, eventId, value)
		local priorFires = #queueRuntime.fires
		local priorSamples = queueRuntime.serverTimeCalls
		local sent, issue = queueClient.events[name]:Send(value)
		assert(sent, issue and issue.message)
		assert(#queueRuntime.fires == priorFires + 1
			and queueRuntime.serverTimeCalls == priorSamples + 1,
			"direct queued Send must emit once after one timestamp sample")
		local payload = queueRuntime.fires[#queueRuntime.fires][2]
		local decoded = table.pack(Frame.compile(queueCompiled.queuedById[eventId], "decode")(payload))
		assert(decoded[1] == true and decoded[2] == queueRuntime.serverTime and decoded[3] == value,
			"direct queued Send must encode one canonical leading serverTime")
	end
	directQueuedSend("BatchInput", 1, 6)
	directQueuedSend("StateInput", 2, 5)
	queueRuntime.serverClockUnavailable = true
	local beforeFailedClockFires = #queueRuntime.fires
	local beforeFailedClockSamples = queueRuntime.serverTimeCalls
	local directClockFailure, directClockIssue = queueClient.events.BatchInput:Send(9)
	assert(not directClockFailure and directClockIssue.code == "InvalidPayload"
		and #queueRuntime.fires == beforeFailedClockFires
		and queueRuntime.serverTimeCalls == beforeFailedClockSamples + 1,
		"direct queued Send must fail closed after one unavailable clock sample")
	queueRuntime.serverClockUnavailable = false
	local batch = assert(queueClient:CreateBatch(0.1))
	assert(batch.events.BatchInput:Send(8) and queueRuntime.serverTimeCalls == 4,
		"eligible Batch.Send must sample and prefix its timestamp at submission")
	local state = assert(queueClient:CreateState(0.1))
	assert(state.events.StateInput:Put(1, "Normal", 7) and queueRuntime.serverTimeCalls == 5,
		"eligible State.Put must sample and prefix its timestamp at submission")
	queueClient:Destroy()
end

do
	local orderedToken = assert(Definition.define({ name = "OrderedStamp", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
	} }))
	local orderedRuntime = Runtime.create()
	local orderedClient = beginClient(orderedToken, orderedRuntime)
	assert(orderedClient.events.Input:Send(11) and orderedRuntime.serverTimeCalls == 1,
		"ordered immediate send must prefix a server timestamp before ordered framing")
	local packet = orderedRuntime.fires[#orderedRuntime.fires][2]
	local header = assert(OrderedFrame.peek(Definition.get(orderedToken).events.Input, 1, packet))
	local unpacked = table.pack(OrderedFrame.decode(Definition.get(orderedToken).events.Input, packet, header,
		function(body) return Frame.compile(OrderedFrame.codecEvent(Definition.get(orderedToken).events.Input), "decode")(body) end))
	assert(unpacked[1] == true and unpacked[2] == orderedRuntime.serverTime,
		"ordered packet body must contain the full-width timestamp")
	orderedClient:Destroy()
end

do
	local token = assert(Definition.define({ name = "ServerTimestamps", version = 1, events = {
		ReliableInput = { id = 1, direction = "ClientToServer", timestampWindow = 0.5, fields = {
			{ name = "serverTime", type = "f64", minimum = 0, maximum = 2 ^ 41 },
			{ name = "enabled", type = "boolean" },
			{ name = "maybe", type = "optional", value = { type = "u8" } },
		} },
		UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
			timestampWindow = 0.5, fields = eventFields({ { name = "value", type = "u8" } }) },
		OnceInput = { id = 3, direction = "ClientToServer", timestampWindow = 0.5,
			fields = { { name = "serverTime", type = "f64", minimum = 0, maximum = 2 ^ 41 } } },
		PlainInput = { id = 4, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
	} }))
	local compiled = Definition.get(token)
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 2048 },
		aggregate = { capacity = 32768, refillPerSecond = 16384 },
	} }))
	local reliableValues, unreliableValues
	local reliableCalls, unreliableCalls, plainCalls, onceCalls = 0, 0, 0, 0
	assert(server.events.ReliableInput:Connect(function(sender, ...)
		reliableCalls += 1
		reliableValues = table.pack(...)
		assert(sender == player)
	end))
	assert(server.events.UnreliableInput:Connect(function(sender, ...)
		unreliableCalls += 1
		unreliableValues = table.pack(...)
		assert(sender == player)
	end))
	assert(server.events.PlainInput:Connect(function(sender, value)
		plainCalls += 1
		assert(sender == player and value == 4)
	end))
	assert(server.events.OnceInput:Once(function(sender, serverTime)
		onceCalls += 1
		assert(sender == player and serverTime == runtime.serverTime)
	end))
	assert(server:Start())
	local reliable, unreliable = runtime:remote(), runtime:unreliableRemote()
	local function send(name, remote, ...)
		local event = compiled.events[name]
		local encoded = table.pack(Frame.compile(event, "encode")(...))
		assert(encoded[1] == true, "timestamp test payload must encode")
		remote.OnServerEvent:Fire(player, event.id, encoded[2])
	end
	local now = runtime.serverTime
	send("ReliableInput", reliable, now - 0.5001, true, 7)
	send("ReliableInput", reliable, now + 100, true, 7)
	assert(reliableCalls == 0 and server:GetDiagnostics().events.ReliableInput.invalidPayload == 2,
		"stale and far-future timestamps must be rejected before callback")
	send("ReliableInput", reliable, now - 0.5, false, nil)
	assert(reliableCalls == 1 and reliableValues.n == 3
		and reliableValues[1] == now - 0.5 and reliableValues[2] == false and reliableValues[3] == nil,
		"the exact oldest timestamp must pass and the callback must preserve false/trailing-nil arity")
	assert(runtime.serverTimeCalls == 3, "each admitted reliable timestamp samples once")
	send("ReliableInput", reliable, now + 0.05, true, 7)
	assert(reliableCalls == 2 and reliableValues[1] == now,
		"server must clamp an accepted future timestamp to its sampled time")
	runtime.failServerTime = true
	send("ReliableInput", reliable, now, true, 7)
	runtime.failServerTime = false
	assert(reliableCalls == 2, "a failing protected Workspace clock must reject the timestamp")
	send("ReliableInput", reliable, now, true, 7)
	assert(reliableCalls == 3 and reliableValues[1] == now,
		"a later valid reliable timestamp must recover after a clock failure")
	assert(runtime.serverTimeCalls == 6, "each admitted timestamped reliable packet samples once")
	send("UnreliableInput", unreliable, now, 9)
	assert(unreliableCalls == 1 and unreliableValues.n == 2 and unreliableValues[1] == now
		and unreliableValues[2] == 9 and runtime.serverTimeCalls == 7,
		"immediate unreliable events use the same timestamp validation")
	send("PlainInput", reliable, 4)
	assert(plainCalls == 1 and runtime.serverTimeCalls == 7,
		"an immediate event without timestamp metadata must not sample the synchronized clock")
	send("OnceInput", reliable, now - 1)
	assert(onceCalls == 0, "a rejected timestamp must not consume a Once listener")
	send("OnceInput", reliable, now)
	assert(onceCalls == 1 and runtime.serverTimeCalls == 9,
		"a valid timestamp must reach the Once listener after a rejected timestamp")
	server:Destroy()
end

do
	local token = assert(Definition.define({ name = "OrderedStampIngress", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable",
			timestampWindow = 0.5, fields = eventFields({ { name = "value", type = "u8" } }) },
	} }))
	local compiled = Definition.get(token)
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 2048 },
		aggregate = { capacity = 32768, refillPerSecond = 16384 },
	} }))
	local calls, received = 0, nil
	assert(server.events.Input:Connect(function(_, serverTime, value)
		calls += 1
		received = { serverTime, value }
	end))
	assert(server:Start())
	local reliable, unreliable = runtime:remote(), runtime:unreliableRemote()
	reliable.OnServerEvent:Fire(player, 0, assert(OrderedFrame.hello("abcdefab-cdef-4000-8000-000000000015")))
	local response = runtime.fires[#runtime.fires].values[2]
	local generation = assert(OrderedFrame.readInitialization(response)).generation
	local event = compiled.events.Input
	local codec = Frame.compile(OrderedFrame.codecEvent(event), "encode")
	local function send(sequence, serverTime)
		local encoded = table.pack(codec(serverTime, 12))
		assert(encoded[1] == true)
		local packet = assert(OrderedFrame.wrap(event, encoded[2], generation, sequence))
		unreliable.OnServerEvent:Fire(player, event.id, packet)
	end
	send(1, runtime.serverTime - 0.6)
	assert(calls == 0 and runtime.serverTimeCalls == 1,
		"an invalid ordered timestamp must reject without dispatch")
	send(1, runtime.serverTime)
	assert(calls == 1 and received[1] == runtime.serverTime and received[2] == 12,
		"invalid timestamp must not advance ordered high-water")
	server:Destroy()
end

do
	local token = assert(Definition.define({ name = "QueuedStampIngress", version = 1, events = {
		BatchPlain = { id = 1, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		BatchGood = { id = 2, direction = "ClientToServer", queue = "Batch", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
		BatchBad = { id = 3, direction = "ClientToServer", queue = "Batch", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
		StatePlain = { id = 4, direction = "ClientToServer", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		StateGood = { id = 5, direction = "ClientToServer", queue = "State", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
		StateBad = { id = 6, direction = "ClientToServer", queue = "State", timestampWindow = 0.5,
			fields = eventFields({ { name = "value", type = "u8" } }) },
	} }))
	local compiled = Definition.get(token)
	for _, case in {
		{ kind = 1, plain = "BatchPlain", good = "BatchGood", bad = "BatchBad" },
		{ kind = 2, plain = "StatePlain", good = "StateGood", bad = "StateBad" },
	} do
		local runtime = ServerRuntime.new()
		local player = runtime:addPlayer()
		local calls = 0
		local function body(name, ...)
			local event = compiled.events[name]
			local encoded = table.pack(Frame.compile(compiled.queuedById[event.id], "encode")(...))
			assert(encoded[1] == true)
			return encoded[2]
		end
		local bodies = {
			body(case.plain, 7),
			body(case.good, runtime.serverTime, 1),
			body(case.bad, runtime.serverTime - 0.6, 2),
		}
		local packet = assert(BatchFrame.wrap(case.kind, bodies, 8_192))
		local packetBytes = buffer.len(packet)
		local endpoints = {}
		for _, name in { case.plain, case.good, case.bad } do
			endpoints[compiled.events[name].id] = { capacity = 1, refillPerSecond = 1 }
		end
		local server = assert(runtime.server.create(token, { inboundRate = {
			perPlayer = { capacity = 7, refillPerSecond = 1 },
			aggregate = { capacity = 7, refillPerSecond = 1 },
			endpoints = endpoints,
			bytes = {
				perPlayer = { capacity = packetBytes * 2, refillPerSecond = 1 },
				aggregate = { capacity = packetBytes * 2, refillPerSecond = 1 },
			},
		} }))
		assert(server:Start())
		for _, name in { case.plain, case.good, case.bad } do
			assert(server.events[name]:Connect(function() calls += 1 end))
		end
		local remote = runtime:remote()
		remote.OnServerEvent:Fire(player, 0, packet)
		assert(calls == 0 and runtime.serverTimeCalls == 1
			and server:GetDiagnostics().events[case.bad].invalidPayload == 1,
			"a bad final timestamp must reject the full kind-1/kind-2 frame after one shared clock sample")
		remote.OnServerEvent:Fire(player, 0, packet)
		assert(calls == 0 and server:GetDiagnostics().events[case.plain].endpointRate == 1
			and runtime.serverTimeCalls == 1,
			"the rejected frame must retain endpoint charges, with later refusal before timestamp sampling")
		remote.OnServerEvent:Fire(player, 0, packet)
		remote.OnServerEvent:Fire(player, 0, packet)
		local counters = server:GetDiagnostics().counters
		assert(calls == 0 and counters.perPlayerBytes == 1 and counters.perPlayerRate == 1,
			"rejected queued frames retain byte and declared-record admission charges")
		server:Destroy()
	end
end

print("PASS Relay bounded C2S timestamps: descriptor, schema, client submission, and server ingress")
