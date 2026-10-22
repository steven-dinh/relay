local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local OrderedFrame = require("../src/internal/OrderedFrame")
local BatchFrame = require("../src/internal/BatchFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local ServerRuntime = require("./support/ServerRuntime")

local token = assert(Definition.define({ name = "BufferRuntime", version = 1, events = {
	Immediate = { id = 1, direction = "ClientToServer", fields = {
		{ name = "enabled", type = "boolean" },
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	Unreliable = { id = 2, direction = "ClientToServer", delivery = "Unreliable", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	Ordered = { id = 3, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	FifoInput = { id = 4, direction = "ClientToServer", queue = "Batch", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	StateInput = { id = 5, direction = "ClientToServer", queue = "State", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	Output = { id = 6, direction = "ServerToClient", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	FifoOutput = { id = 7, direction = "ServerToClient", queue = "Batch", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	StateOutput = { id = 8, direction = "ServerToClient", delivery = "Unreliable", queue = "State", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	OrderedOutput = { id = 9, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
		{ name = "bytes", type = "buffer", maximumBytes = 4 },
	} },
	Charged = { id = 10, direction = "ClientToServer", fields = {
		{ name = "enabled", type = "boolean" },
		{ name = "bytes", type = "buffer", maximumBytes = 2 },
		{ name = "tail", type = "boolean" },
	} },
}, requests = {
	Echo = { id = 11, request = { { name = "bytes", type = "buffer", maximumBytes = 4 } },
		response = { type = "buffer", maximumBytes = 4 } },
} }))
local compiled = assert(Definition.get(token))
local guid = "01234567-89ab-cdef-0123-456789abcdef"

local function bytes(values)
	local result = buffer.create(#values)
	for index, value in values do buffer.writeu8(result, index - 1, value) end
	return result
end

local function copy(value)
	local result = buffer.create(buffer.len(value))
	buffer.copy(result, 0, value, 0, buffer.len(value))
	return result
end

local function equals(left, values)
	if typeof(left) ~= "buffer" or buffer.len(left) ~= #values then return false end
	for index, value in values do
		if buffer.readu8(left, index - 1) ~= value then return false end
	end
	return true
end

local function encode(event, ...)
	local result = table.pack(Frame.compile(event, "encode")(...))
	assert(result[1] == true, "runtime test body must encode")
	return result[2]
end

local function queuedBody(name, ...)
	return encode(compiled.queuedById[compiled.events[name].id], ...)
end

local runtime = ServerRuntime.new()
local player = runtime:addPlayer()
local server = assert(runtime.server.create(token, {
	inboundRate = {
		perPlayer = { capacity = 128, refillPerSecond = 1 },
		aggregate = { capacity = 256, refillPerSecond = 1 },
	},
}))
assert(server:Start())
local reliable, unreliable = runtime:remote(), runtime:unreliableRemote()
local received = {}
for _, name in { "Immediate", "Unreliable", "Ordered", "FifoInput", "StateInput" } do
	assert(server.events[name]:Connect(function(sender, value, maybeBytes)
		assert(sender == player)
		local payload = if name == "Immediate" then maybeBytes else value
		received[name] = copy(payload)
	end))
end

local immediate = bytes({ 0, 127, 255 })
reliable.OnServerEvent:Fire(player, 1, encode(compiled.events.Immediate, true, immediate))
assert(equals(received.Immediate, { 0, 127, 255 }), "reliable immediate events decode buffer tuples")

local unreliableBytes = bytes({ 3, 2, 1 })
unreliable.OnServerEvent:Fire(player, 2, encode(compiled.events.Unreliable, unreliableBytes))
assert(equals(received.Unreliable, { 3, 2, 1 }), "unreliable events decode bounded buffers")

local orderedGuid = "abcdefab-cdef-4000-8000-000000000010"
reliable.OnServerEvent:Fire(player, 0, assert(OrderedFrame.hello(orderedGuid)))
local initialization = assert(OrderedFrame.readInitialization(runtime.fires[#runtime.fires].values[2]))
local orderedEvent = compiled.events.Ordered
local orderedBody = encode(OrderedFrame.codecEvent(orderedEvent), bytes({ 9, 8 }))
local orderedPacket = assert(OrderedFrame.wrap(orderedEvent, orderedBody, initialization.generation, 1))
unreliable.OnServerEvent:Fire(player, orderedEvent.id, orderedPacket)
assert(equals(received.Ordered, { 9, 8 }), "ordered unreliable ingress decodes bounded buffers")

local fifoBody = queuedBody("FifoInput", bytes({ 21, 22 }))
reliable.OnServerEvent:Fire(player, 0, assert(BatchFrame.wrap(1, { fifoBody }, 8_192)))
assert(equals(received.FifoInput, { 21, 22 }), "FIFO ingress decodes bounded buffers")
local stateBody = queuedBody("StateInput", bytes({ 31, 32 }))
reliable.OnServerEvent:Fire(player, 0, assert(BatchFrame.wrap(2, { stateBody }, 8_192)))
assert(equals(received.StateInput, { 31, 32 }), "State ingress decodes bounded buffers")

local requestBody = encode(compiled.requests.Echo.request, bytes({ 41, 42 }))
assert(server.requests.Echo:Connect(function(sender, value)
	assert(sender == player and equals(value, { 41, 42 }))
	return bytes({ 43, 44 })
end))
reliable.OnServerEvent:Fire(player, 0, assert(RpcFrame.wrap(1, 11, 1, guid, requestBody)))
local rpcFire = runtime.fires[#runtime.fires]
local rpcHeader = assert(RpcFrame.peek(rpcFire.values[2], false))
local rpcBody = assert(RpcFrame.readBody(rpcFire.values[2], rpcHeader,
	compiled.requests.Echo.response.minimumEncodedBytes,
	compiled.requests.Echo.response.maximumEncodedBytes))
local rpcResponse = table.pack(Frame.compile(compiled.requests.Echo.response, "decode")(rpcBody))
assert(rpcFire.values[1] == 0 and rpcHeader.kind == 2 and rpcResponse[1]
	and equals(rpcResponse[2], { 43, 44 }), "RPC request and response bodies carry native buffers")

local outputSource = bytes({ 51, 52 })
local outputOk = server.events.Output:Send(player, outputSource)
assert(outputOk)
local immediateFire = runtime.fires[#runtime.fires]
assert(immediateFire.values[1] == 6)
local immediateResponse = table.pack(Frame.compile(compiled.events.Output, "decode")(immediateFire.values[2]))
assert(immediateResponse[1] and equals(immediateResponse[2], { 51, 52 }),
	"reliable server-to-client event sends buffer contents")

local batch = assert(server:CreateBatch({ player }, 0.02))
local fifoSource = bytes({ 61, 62 })
assert(batch.events.FifoOutput:Send(fifoSource))
buffer.writeu8(fifoSource, 0, 99)
local batchOk = batch:Flush()
assert(batchOk)
local fifoFire = runtime.fires[#runtime.fires]
local fifoPacket = fifoFire.values[2]
local fifoHeader = assert(BatchFrame.header(fifoPacket, 8_192))
local fifoRows = assert(BatchFrame.scan(fifoPacket, fifoHeader, function(id) return compiled.queuedById[id] end))
local fifoDecoded = table.pack(Frame.compile(fifoRows[1].event, "decode")(
	assert(BatchFrame.readBody(fifoPacket, fifoRows[1]))))
assert(fifoHeader.kind == 1 and fifoRows[1].event.id == 7 and fifoDecoded[1]
	and equals(fifoDecoded[2], { 61, 62 }), "FIFO queued frames own buffer snapshots")

local state = assert(server:CreateState({ player }, 0.02))
local stateSource = bytes({ 71, 72 })
assert(state.events.StateOutput:Put(1, "Normal", stateSource))
buffer.writeu8(stateSource, 0, 99)
local stateOk = state:Flush()
assert(stateOk)
local stateFire = runtime.fires[#runtime.fires]
local statePacket = stateFire.values[2]
local stateHeader = assert(BatchFrame.header(statePacket, 900))
local stateRows = assert(BatchFrame.scan(statePacket, stateHeader, function(id) return compiled.queuedById[id] end))
local stateDecoded = table.pack(Frame.compile(stateRows[1].event, "decode")(
	assert(BatchFrame.readBody(statePacket, stateRows[1]))))
assert(stateFire.remote == unreliable and stateHeader.kind == 2 and stateRows[1].event.id == 8
	and stateDecoded[1] and equals(stateDecoded[2], { 71, 72 }),
	"unreliable State queues retain owned buffer snapshots")

local orderedOutputEvent = compiled.events.OrderedOutput
local orderedOutSource = bytes({ 81, 82 })
local orderedOutOk = server.events.OrderedOutput:Send(player, orderedOutSource)
assert(orderedOutOk)
local orderedOutFire = runtime.fires[#runtime.fires]
local orderedOutPacket = orderedOutFire.values[2]
local orderedOutHeader = assert(OrderedFrame.peek(orderedOutputEvent, orderedOutputEvent.id, orderedOutPacket))
local orderedOutDecoded = table.pack(OrderedFrame.decode(orderedOutputEvent, orderedOutPacket, orderedOutHeader,
	Frame.compile(OrderedFrame.codecEvent(orderedOutputEvent), "decode")))
assert(orderedOutFire.remote == unreliable and orderedOutDecoded[1]
	and equals(orderedOutDecoded[2], { 81, 82 }), "ordered server-to-client events send buffer contents")
server:Destroy()

local chargedToken = assert(Definition.define({ name = "BufferCharged", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = {
		{ name = "enabled", type = "boolean" },
		{ name = "bytes", type = "buffer", maximumBytes = 2 },
		{ name = "tail", type = "boolean" },
	} },
} }))
local chargeRuntime = ServerRuntime.new()
local chargedPlayer = chargeRuntime:addPlayer()
local chargedServer = assert(chargeRuntime.server.create(chargedToken, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 1 },
		aggregate = { capacity = 16, refillPerSecond = 1 },
		bytes = {
			perPlayer = { capacity = 15, refillPerSecond = 1 },
			aggregate = { capacity = 15, refillPerSecond = 1 },
		},
	},
}))
assert(chargedServer:Start())
local chargeCalls = 0
assert(chargedServer.events.Input:Connect(function(_, enabled, value, tail)
	assert(enabled and equals(value, { 1 }) and tail)
	chargeCalls += 1
end))
local malformed = buffer.create(7)
buffer.writeu8(malformed, 0, 1)
buffer.writeu16(malformed, 1, 1)
buffer.writeu8(malformed, 3, 1)
buffer.writeu16(malformed, 4, 3)
buffer.writeu8(malformed, 6, 1)
local chargedRemote = chargeRuntime:remote()
chargedRemote.OnServerEvent:Fire(chargedPlayer, 1, malformed)
local valid = encode(Definition.get(chargedToken).events.Input, true, bytes({ 1 }), true)
chargedRemote.OnServerEvent:Fire(chargedPlayer, 1, valid)
chargedRemote.OnServerEvent:Fire(chargedPlayer, 1, valid)
local counters = chargedServer:GetDiagnostics().counters
assert(chargeCalls == 1 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
	and counters.aggregateBytes == 0,
	"malformed client buffers retain byte charges, reject before handlers, allow remaining capacity, then refuse excess")
chargedServer:Destroy()

print("PASS Relay.BufferRuntime immediate, RPC, ordered, FIFO, State, snapshot, and charged malformed routes")
