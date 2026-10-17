local Schema = require("../src/Schema")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local NativeRuntime = require("./support/NativeCodec")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local Frame = NativeRuntime.loadFrame()
local small = Schema.quantized(-1, 1, 0.01)
local wide = Schema.quantized(0, 256, 1)

local function field(name, shape)
	local result = table.clone(shape)
	result.name = name
	return result
end

local token, issue = Definition.define({
	name = "QuantizedRuntime",
	version = 1,
	events = {
		Input = { id = 1, direction = "ClientToServer", fields = {
			field("first", small), field("second", small),
		} },
		UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
			fields = { field("value", small) } },
		OrderedInput = { id = 3, direction = "ClientToServer", delivery = "OrderedUnreliable",
			fields = { field("value", small) } },
		BatchInput = { id = 4, direction = "ClientToServer", queue = "Batch",
			fields = { field("value", small) } },
		StateInput = { id = 5, direction = "ClientToServer", queue = "State",
			fields = { field("value", small) } },
		Output = { id = 6, direction = "ServerToClient", fields = { field("value", small) } },
		UnreliableOutput = { id = 7, direction = "ServerToClient", delivery = "Unreliable",
			fields = { field("value", small) } },
		OrderedOutput = { id = 8, direction = "ServerToClient", delivery = "OrderedUnreliable",
			fields = { field("value", small) } },
		BatchOutput = { id = 9, direction = "ServerToClient", queue = "Batch",
			fields = { field("value", small) } },
		StateOutput = { id = 10, direction = "ServerToClient", queue = "State",
			fields = { field("value", small) } },
	},
	requests = { Lookup = { id = 11,
		request = { field("first", small), field("second", small) }, response = wide,
	} },
})
assert(token, issue and issue.message)
local compiled = assert(Definition.get(token))

local serverRuntime = ServerRuntime.new()
local player = serverRuntime:addPlayer()
local server = assert(serverRuntime.server.create(token, { inboundRate = {
	perPlayer = { capacity = 64, refillPerSecond = 64 },
	aggregate = { capacity = 128, refillPerSecond = 128 },
} }))
assert(server:Start())

local clientRuntime = ClientRuntime.create()
local _, _, clientRemote, clientUnreliable = clientRuntime:transport(compiled.descriptor, compiled.hasUnreliable)
local serverRemote, serverUnreliable = serverRuntime:remote(), serverRuntime:unreliableRemote()
local function dispatchClient(endpointId, ...)
	local remote = if endpointId == 2 or endpointId == 3 or endpointId == 7 or endpointId == 8
		then clientUnreliable else clientRemote
	remote.OnClientEvent:fire(endpointId, ...)
end
serverRuntime.afterFire = function(_, endpointId, ...)
	dispatchClient(endpointId, ...)
end
clientRuntime.onFire = function(remote, endpointId, ...)
	local transport = if remote.ClassName == "UnreliableRemoteEvent" then serverUnreliable else serverRemote
	transport.OnServerEvent:Fire(player, endpointId, ...)
end

local client = assert(clientRuntime.module.create(token, { startupTimeoutSeconds = 3 }))
local received = {}
for name, expected in {
	Input = { 0.34, 0.67 }, UnreliableInput = { -0.33 }, OrderedInput = { 0.45 },
	BatchInput = { 0.78 }, StateInput = { -0.56 },
} do
	assert(server.events[name]:Connect(function(_, ...)
		local values = table.pack(...)
		assert(values.n == #expected)
		for index, value in expected do assert(math.abs(values[index] - value) < 1e-12) end
		received[name] = (received[name] or 0) + 1
	end))
end
for name, expected in {
	Output = 0.34, UnreliableOutput = -0.33, OrderedOutput = 0.45,
	BatchOutput = 0.78, StateOutput = -0.56,
} do
	assert(client.events[name]:Connect(function(value)
		assert(math.abs(value - expected) < 1e-12)
		received[name] = (received[name] or 0) + 1
	end))
end
local requestCalls = 0
assert(server.requests.Lookup:Connect(function(_, first, second)
	assert(math.abs(first - 0.34) < 1e-12 and math.abs(second - 0.67) < 1e-12)
	requestCalls += 1
	return 255.7
end))

assert(client:Start())
local handoffs = #clientRuntime.fires
local outsideAccepted, outsideError = client.events.Input:Send(1.01, 0.5)
local wrongTypeAccepted, wrongTypeError = client.events.Input:Send("0.5", 0.5)
assert(not outsideAccepted and outsideError.code == "InvalidPayload"
	and not wrongTypeAccepted and wrongTypeError.code == "InvalidPayload"
	and #clientRuntime.fires == handoffs, "out-of-range values reject without clamping or transport handoff")
assert(client.events.Input:Send(0.336, 0.666))
assert(client.events.UnreliableInput:Send(-0.334))
assert(client.events.OrderedInput:Send(0.446))
local batch = assert(client:CreateBatch(0.05))
assert(batch.events.BatchInput:Send(0.776))
assert(batch:Flush())
local state = assert(client:CreateState(0.05))
assert(state.events.StateInput:Put(1, "High", -0.556))
assert(state:Flush())

assert(server.events.Output:Send(player, 0.336))
assert(server.events.UnreliableOutput:Send(player, -0.334))
assert(server.events.OrderedOutput:Send(player, 0.446))
local serverBatch = assert(server:CreateBatch({ player }, 0.05))
assert(serverBatch.events.BatchOutput:Send(0.776))
assert(serverBatch:Flush())
local serverState = assert(server:CreateState({ player }, 0.05))
assert(serverState.events.StateOutput:Put(1, "High", -0.556))
assert(serverState:Flush())

local pending, requestError = client.requests.Lookup:Request(3, 0.336, 0.666)
assert(pending, requestError and requestError.message)
local response = pending:Await()
assert(response.ok and response.value == 256 and requestCalls == 1,
	"RPC request and response quantize using their independently declared grids")
for _, name in { "Input", "UnreliableInput", "OrderedInput", "BatchInput", "StateInput",
	"Output", "UnreliableOutput", "OrderedOutput", "BatchOutput", "StateOutput" } do
	assert(received[name] == 1, `{name} route delivered one rounded value`)
end

local function copy(value, length)
	local result = buffer.create(length or buffer.len(value))
	buffer.copy(result, 0, value, 0, math.min(buffer.len(value), buffer.len(result)))
	return result
end
local function encode(event, ...)
	local valid, body = Frame.compile(event, "encode")(...)
	assert(valid and typeof(body) == "buffer")
	return body
end
local goodInput = encode(compiled.events.Input, 0.336, 0.666)
local unusedCode = copy(goodInput)
buffer.writeu8(unusedCode, 4, 201)
local truncated = copy(goodInput, buffer.len(goodInput) - 1)
local badCalls = 0
local rejectionRuntime = ServerRuntime.new()
local rejectionPlayer = rejectionRuntime:addPlayer()
local rejectionServer = assert(rejectionRuntime.server.create(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 },
	aggregate = { capacity = 32, refillPerSecond = 32 },
} }))
assert(rejectionServer:Start())
assert(rejectionServer.events.Input:Connect(function() badCalls += 1 end))
local rejectionRemote = rejectionRuntime:remote()
rejectionRemote.OnServerEvent:Fire(rejectionPlayer, 1, unusedCode)
rejectionRemote.OnServerEvent:Fire(rejectionPlayer, 1, truncated)
rejectionRemote.OnServerEvent:Fire(rejectionPlayer, 1, goodInput)
assert(badCalls == 1 and rejectionServer:GetDiagnostics().events.Input.invalidPayload == 2,
	"unused scalar codes and truncated later scalars reject atomically, then valid input recovers")
rejectionServer:Destroy()

local function budgetedServer(rate, byteLimit, endpointLimit)
	local runtime = ServerRuntime.new()
	local sender = runtime:addPlayer()
	local config = {
		perPlayer = { capacity = rate, refillPerSecond = 0.01 },
		aggregate = { capacity = rate, refillPerSecond = 0.01 },
	}
	if byteLimit ~= nil then
		config.bytes = {
			perPlayer = { capacity = if type(byteLimit) == "table" then byteLimit[1] else byteLimit,
				refillPerSecond = 0.01 },
			aggregate = { capacity = if type(byteLimit) == "table" then byteLimit[2] else byteLimit,
				refillPerSecond = 0.01 },
		}
	end
	if endpointLimit ~= nil then config.endpoints = { [1] = { capacity = endpointLimit, refillPerSecond = 0.01 } } end
	local subject = assert(runtime.server.create(token, { inboundRate = config }))
	assert(subject:Start())
	local calls = 0
	assert(subject.events.Input:Connect(function() calls += 1 end))
	return runtime, sender, subject, function() return calls end
end

do
	local runtime, sender, subject, calls = budgetedServer(4,
		{ buffer.len(goodInput), buffer.len(goodInput) * 2 })
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(sender, 1, unusedCode)
	remote.OnServerEvent:Fire(sender, 1, goodInput)
	local counters = subject:GetDiagnostics().counters
	assert(calls() == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
		and counters.aggregateBytes == 0, "malformed scalar bodies retain the per-player byte debit")
	subject:Destroy()
end

do
	local runtime, sender, subject, calls = budgetedServer(4,
	buffer.len(goodInput))
	local secondSender = runtime:addPlayer()
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(sender, 1, unusedCode)
	remote.OnServerEvent:Fire(secondSender, 1, goodInput)
	local counters = subject:GetDiagnostics().counters
	assert(calls() == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 0
		and counters.aggregateBytes == 1, "malformed scalar bodies retain the aggregate byte debit")
	subject:Destroy()
end

do
	local runtime, sender, subject, calls = budgetedServer(1, nil)
	local secondSender = runtime:addPlayer()
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(sender, 1, unusedCode)
	remote.OnServerEvent:Fire(sender, 1, goodInput)
	remote.OnServerEvent:Fire(secondSender, 1, goodInput)
	local counters = subject:GetDiagnostics().counters
	assert(calls() == 0 and counters.invalidPayload == 1 and counters.perPlayerRate == 1
		and counters.aggregateRate == 1, "malformed scalar bodies retain shared per-player and aggregate call debits")
	subject:Destroy()
end

do
	local runtime, sender, subject, calls = budgetedServer(4, nil, 1)
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(sender, 1, unusedCode)
	remote.OnServerEvent:Fire(sender, 1, goodInput)
	local counters = subject:GetDiagnostics().counters
	assert(calls() == 0 and counters.invalidPayload == 1 and counters.endpointRate == 1,
		"malformed scalar bodies retain the endpoint rate debit")
	subject:Destroy()
end

do
	local method = compiled.requests.Lookup
	local guid = "01234567-89ab-cdef-0123-456789abcdef"
	local goodBody = encode(method.request, 0.336, 0.666)
	local badBody = copy(goodBody)
	buffer.writeu8(badBody, 4, 201)
	local badPacket = assert(RpcFrame.wrap(1, method.id, 1, guid, badBody))
	local goodPacket = assert(RpcFrame.wrap(1, method.id, 2, guid, goodBody))
	local runtime = ServerRuntime.new()
	local sender = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 4, refillPerSecond = 0.01 },
		aggregate = { capacity = 8, refillPerSecond = 0.01 },
		bytes = { perPlayer = { capacity = buffer.len(badPacket), refillPerSecond = 0.01 },
			aggregate = { capacity = buffer.len(badPacket) * 2, refillPerSecond = 0.01 } },
	} }))
	local calls = 0
	assert(server.requests.Lookup:Connect(function() calls += 1; return 1 end))
	assert(server:Start())
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(sender, 0, badPacket)
	remote.OnServerEvent:Fire(sender, 0, goodPacket)
	local counters = server:GetDiagnostics().counters
	assert(calls == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
		and counters.aggregateBytes == 0, "a malformed later RPC scalar is rejected and retains its full envelope charge")
	server:Destroy()
end

do
	local body = encode(compiled.queuedById[4], 0.776)
	local badLaterBody = copy(body)
	buffer.writeu8(badLaterBody, buffer.len(badLaterBody) - 1, 201)
	local packet = assert(BatchFrame.wrap(1, { body, badLaterBody }, 8_192))
	local runtime, sender, subject, calls = budgetedServer(4, { buffer.len(packet), buffer.len(packet) * 2 })
	local batchCalls = 0
	assert(subject.events.BatchInput:Connect(function() batchCalls += 1 end))
	runtime:remote().OnServerEvent:Fire(sender, 0, packet)
	runtime:remote().OnServerEvent:Fire(sender, 1, goodInput)
	local counters = subject:GetDiagnostics().counters
	assert(calls() == 0 and batchCalls == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
		and counters.aggregateBytes == 0,
		"a malformed later FIFO record blocks every callback and retains the per-player envelope debit")
	subject:Destroy()
end

local clientTimers = 0
for _ in clientRuntime.timers do clientTimers += 1 end
assert(clientTimers == 0 and serverRuntime:activeTimers() == 0
	and server:GetDiagnostics().inFlight == 0, "quantized routes leave no RPC, queue, or session work pending")
client:Destroy()
server:Destroy()

print("PASS Relay.Quantized.Runtime bounded scalar routes and admission")
