local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local OrderedFrame = require("../src/internal/OrderedFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local NativeRuntime = require("./support/NativeCodec")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")
local Frame = NativeRuntime.loadFrame()

local guid = "01234567-89ab-cdef-0123-456789abcdef"
local fontFamily = "rbxasset://fonts/families/Arial.json"
local nativeEnum = { type = "robloxEnum", values = {
	roblox.Enum.Material.Plastic, roblox.Enum.Material.Wood,
} }
local udim = { type = "UDim", minimumScale = 0, maximumScale = 1, minimumOffset = -16, maximumOffset = 16 }
local axes = { type = "Axes" }
local sequence = { type = "NumberSequence", maximumKeypoints = 4,
	minimum = 0, maximum = 10, maximumEnvelope = 2 }
local font = { type = "Font", families = { fontFamily } }
local udim2 = { type = "UDim2", minimumScale = 0, maximumScale = 1, minimumOffset = -16, maximumOffset = 16 }
local function field(name, shape)
	local result = table.clone(shape)
	result.name = name
	return result
end

local token, problem = Definition.define({
	name = "NativeRuntime",
	version = 1,
	events = {
		Input = { id = 1, direction = "ClientToServer", fields = {
			field("size", udim), field("material", nativeEnum),
		} },
		Output = { id = 2, direction = "ServerToClient", fields = {
			field("font", font),
		} },
		SequenceInput = { id = 3, direction = "ClientToServer", fields = {
			field("curve", sequence),
		} },
		AxesInput = { id = 4, direction = "ClientToServer", fields = {
			field("axes", axes),
		} },
		BatchInput = { id = 5, direction = "ClientToServer", queue = "Batch", fields = {
			field("curve", sequence),
		} },
		StateInput = { id = 6, direction = "ClientToServer", queue = "State", fields = {
			field("curve", sequence),
		} },
		OrderedInput = { id = 7, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
			field("curve", sequence),
		} },
		BatchOutput = { id = 9, direction = "ServerToClient", queue = "Batch", fields = {
			field("font", font),
		} },
		StateOutput = { id = 10, direction = "ServerToClient", queue = "State", fields = {
			field("size", udim2),
		} },
	},
	requests = {
		Lookup = { id = 8, request = { field("size", udim) }, response = font },
	},
})
assert(token and problem == nil, problem and problem.message)
local compiled = assert(Definition.get(token))

local function encode(shape, ...)
	local result = table.pack(Frame.compile(shape, "encode")(...))
	assert(result[1] == true, "native frame encodes")
	return result[2]
end

local function copied(value, length)
	local result = buffer.create(length)
	buffer.copy(result, 0, value, 0, math.min(length, buffer.len(value)))
	return result
end

local function makeSequence(pointCount)
	local points = table.create(pointCount)
	for index = 1, pointCount do
		local time = (index - 1) / (pointCount - 1)
		points[index] = roblox.NumberSequenceKeypoint.new(time, time * 4, 0.25)
	end
	return roblox.NumberSequence.new(points)
end

local sourceSize = roblox.UDim.new(0.5, 7)
local sourceFont = roblox.Font.new(fontFamily, roblox.Enum.FontWeight.Bold, roblox.Enum.FontStyle.Italic)
local sourceAxes = roblox.Axes.new(roblox.Enum.Axis.X, roblox.Enum.Axis.Z)
local sourceSequence = makeSequence(2)
local sourceSize2 = roblox.UDim2.new(0.25, 2, 0.75, 4)

-- Client validation runs before FireServer; native values travel through immediate, queued, RPC, and ordered paths.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 64, refillPerSecond = 64 },
		aggregate = { capacity = 128, refillPerSecond = 128 },
	} }))
	assert(server:Start())
	local clientRuntime = ClientRuntime.create()
	local _, _, clientRemote = clientRuntime:transport(compiled.descriptor, compiled.hasUnreliable)
	clientRuntime.onFire = function(_, endpointId, control)
		if endpointId == 0 then
			local clientGuid = OrderedFrame.readHello(control)
			if clientGuid ~= nil then
				clientRemote.OnClientEvent:fire(0, assert(OrderedFrame.initialization(clientGuid, 1)))
			end
		end
	end
	local client = assert(clientRuntime.module.create(token, { startupTimeoutSeconds = 3 }))
	local started, startProblem = client:Start()
	assert(started, startProblem and startProblem.message)

	local fireCount = #clientRuntime.fires
	assert(not client.events.Input:Send(sourceSize, "Wood") and #clientRuntime.fires == fireCount,
		"a wrong native enum type is rejected before transport handoff")
	assert(not client.events.SequenceInput:Send(makeSequence(5)) and #clientRuntime.fires == fireCount,
		"a sequence above its declared keypoint count is rejected before transport handoff")

	assert(client.events.Input:Send(sourceSize, roblox.Enum.Material.Wood))
	local inputPacket = clientRuntime.fires[#clientRuntime.fires][2]
	local inputCalls = 0
	assert(server.events.Input:Connect(function(sender, size, material)
		assert(sender == player and typeof(size) == "UDim" and size.Scale == sourceSize.Scale
			and size.Offset == sourceSize.Offset and material == roblox.Enum.Material.Wood)
		inputCalls += 1
	end))
	runtime:remote().OnServerEvent:Fire(player, 1, inputPacket)
	assert(inputCalls == 1, "client-to-server event handlers receive reconstructed native values")

	local outputCalls = 0
	assert(client.events.Output:Connect(function(value)
		assert(typeof(value) == "Font" and value.Family == fontFamily
			and value.Weight == roblox.Enum.FontWeight.Bold and value.Style == roblox.Enum.FontStyle.Italic)
		outputCalls += 1
	end))
	assert(server.events.Output:Send(player, sourceFont))
	local outputPacket = runtime.fires[#runtime.fires].values[2]
	clientRemote.OnClientEvent:fire(2, outputPacket)
	assert(outputCalls == 1, "server-to-client event listeners receive reconstructed native values")

	local sequenceCalls, axesCalls, batchCalls, stateCalls = 0, 0, 0, 0
	assert(server.events.SequenceInput:Connect(function(_, value)
		assert(typeof(value) == "NumberSequence" and #value.Keypoints == 2)
		sequenceCalls += 1
	end))
	assert(server.events.AxesInput:Connect(function(_, value)
		assert(typeof(value) == "Axes" and value.X and not value.Y and value.Z)
		axesCalls += 1
	end))
	assert(server.events.BatchInput:Connect(function(_, value)
		assert(typeof(value) == "NumberSequence" and #value.Keypoints == 2)
		batchCalls += 1
	end))
	assert(server.events.StateInput:Connect(function(_, value)
		assert(typeof(value) == "NumberSequence" and #value.Keypoints == 2)
		stateCalls += 1
	end))
	runtime:remote().OnServerEvent:Fire(player, 3, encode(compiled.events.SequenceInput, sourceSequence))
	runtime:remote().OnServerEvent:Fire(player, 4, encode(compiled.events.AxesInput, sourceAxes))
	local batchBody = encode(compiled.queuedById[5], sourceSequence)
	runtime:remote().OnServerEvent:Fire(player, 0, assert(BatchFrame.wrap(1, { batchBody }, 8_192)))
	local stateBody = encode(compiled.queuedById[6], sourceSequence)
	runtime:remote().OnServerEvent:Fire(player, 0, assert(BatchFrame.wrap(2, { stateBody }, 8_192)))
	assert(sequenceCalls == 1 and axesCalls == 1 and batchCalls == 1 and stateCalls == 1,
		"sequence, mask, FIFO, and State routes decode native values")

	local method = compiled.requests.Lookup
	local requestCalls = 0
	assert(server.requests.Lookup:Connect(function(sender, size)
		assert(sender == player and typeof(size) == "UDim" and size.Offset == sourceSize.Offset)
		requestCalls += 1
		return sourceFont
	end))
	local requestBody = encode(method.request, sourceSize)
	runtime:remote().OnServerEvent:Fire(player, 0,
		assert(RpcFrame.wrap(1, method.id, 1, guid, requestBody)))
	local rpcReply = runtime.fires[#runtime.fires].values[2]
	local replyHeader = assert(RpcFrame.peek(rpcReply, false))
	local replyBody = assert(RpcFrame.readBody(rpcReply, replyHeader,
		method.response.minimumEncodedBytes, method.response.maximumEncodedBytes))
	local responseOk, response = Frame.compile(method.response, "decode")(replyBody)
	assert(requestCalls == 1 and replyHeader.kind == 2 and responseOk and response.Family == fontFamily
		and response.Weight == roblox.Enum.FontWeight.Bold,
		"RPC request and response preserve native values")

	local batch = assert(server:CreateBatch({ player }, 0.02))
	assert(batch.events.BatchOutput:Send(sourceFont))
	local batchOk, batchProblem = batch:Flush()
	assert(batchOk, batchProblem and batchProblem.message)
	local batchPacket = runtime.fires[#runtime.fires].values[2]
	local batchHeader = assert(BatchFrame.header(batchPacket, 8_192))
	local batchRows = assert(BatchFrame.scan(batchPacket, batchHeader,
		function(id) return compiled.queuedById[id] end))
	local batchOutputBody = assert(BatchFrame.readBody(batchPacket, batchRows[1]))
	local batchOutputOk, batchOutput = Frame.compile(batchRows[1].event, "decode")(batchOutputBody)
	assert(batchHeader.kind == 1 and batchOutputOk and batchOutput.Family == fontFamily,
		"server FIFO output encodes a native value")

	local state = assert(server:CreateState({ player }, 0.02))
	local statePutOk, statePutProblem = state.events.StateOutput:Put(1, "High", sourceSize2)
	assert(statePutOk, statePutProblem and statePutProblem.message)
	local stateOk, stateProblem = state:Flush()
	assert(stateOk, stateProblem and stateProblem.message)
	local statePacket = runtime.fires[#runtime.fires].values[2]
	local stateHeader = assert(BatchFrame.header(statePacket, 8_192))
	local stateRows = assert(BatchFrame.scan(statePacket, stateHeader,
		function(id) return compiled.queuedById[id] end))
	local stateOutputBody = assert(BatchFrame.readBody(statePacket, stateRows[1]))
	local stateOutputOk, stateOutput = Frame.compile(stateRows[1].event, "decode")(stateOutputBody)
	assert(stateHeader.kind == 2 and stateOutputOk and stateOutput.X.Scale == sourceSize2.X.Scale,
		"server State output encodes a native value")
	client:Destroy()
	server:Destroy()
end

-- Invalid native enum, mask, sequence count, and count-bytes combinations fail before handlers.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server, serverProblem = runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 64, refillPerSecond = 64 },
		aggregate = { capacity = 128, refillPerSecond = 128 },
	} })
	assert(server, serverProblem and serverProblem.message)
	assert(server:Start())
	local calls = { Input = 0, AxesInput = 0, SequenceInput = 0 }
	for name in calls do
		assert(server.events[name]:Connect(function() calls[name] += 1 end))
	end
	local remote = runtime:remote()
	local badEnum = encode(compiled.events.Input, sourceSize, roblox.Enum.Material.Wood)
	buffer.writei32(badEnum, 15, 2_147_483_647)
	remote.OnServerEvent:Fire(player, 1, badEnum)
	local badMask = encode(compiled.events.AxesInput, sourceAxes)
	buffer.writeu8(badMask, 3, 8)
	remote.OnServerEvent:Fire(player, 4, badMask)
	local badCount = encode(compiled.events.SequenceInput, sourceSequence)
	buffer.writeu8(badCount, 3, 1)
	remote.OnServerEvent:Fire(player, 3, badCount)
	local shortValues = copied(encode(compiled.events.SequenceInput, sourceSequence), 3 + 1 + 2 * 24)
	buffer.writeu8(shortValues, 3, 4)
	remote.OnServerEvent:Fire(player, 3, shortValues)
	local snapshot = server:GetDiagnostics()
	assert(calls.Input == 0 and calls.AxesInput == 0 and calls.SequenceInput == 0
		and snapshot.events.Input.invalidPayload == 1 and snapshot.events.AxesInput.invalidPayload == 1
		and snapshot.events.SequenceInput.invalidPayload == 2,
		"malformed native enum, mask, count, or truncated variable body never reaches a handler")
	server:Destroy()
end

-- A malformed ordered sequence does not advance the event high-water mark.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 64, refillPerSecond = 64 },
		aggregate = { capacity = 128, refillPerSecond = 128 },
	} }))
	assert(server:Start())
	local calls = 0
	assert(server.events.OrderedInput:Connect(function(_, value)
		assert(typeof(value) == "NumberSequence")
		calls += 1
	end))
	local remote, unreliable = runtime:remote(), runtime:unreliableRemote()
	remote.OnServerEvent:Fire(player, 0, assert(OrderedFrame.hello(guid)))
	local malformedBody = encode(OrderedFrame.codecEvent(compiled.events.OrderedInput), sourceSequence)
	buffer.writeu8(malformedBody, 3, 4)
	unreliable.OnServerEvent:Fire(player, 7,
		assert(OrderedFrame.wrap(compiled.events.OrderedInput, malformedBody, 1, 1)))
	local validBody = encode(OrderedFrame.codecEvent(compiled.events.OrderedInput), sourceSequence)
	unreliable.OnServerEvent:Fire(player, 7,
		assert(OrderedFrame.wrap(compiled.events.OrderedInput, validBody, 1, 1)))
	assert(calls == 1 and server:GetDiagnostics().events.OrderedInput.invalidPayload == 1,
		"invalid ordered native body retains the same serial for a later valid packet")
	server:Destroy()
end

-- A malformed admitted native body keeps each configured inbound debit.
do
	local goodFrame = encode(compiled.events.Input, sourceSize, roblox.Enum.Material.Wood)
	local badFrame = copied(goodFrame, buffer.len(goodFrame))
	buffer.writei32(badFrame, 15, 2_147_483_647)
	local function makeServer(options)
		local runtime = ServerRuntime.new()
		local first, second = runtime:addPlayer(), runtime:addPlayer()
		local server = assert(runtime.server.create(token, { inboundRate = options }))
		assert(server:Start())
		local calls = 0
		assert(server.events.Input:Connect(function() calls += 1 end))
		return runtime, first, second, server, function() return calls end
	end

	local runtime, first, second, server, calls = makeServer({
		perPlayer = { capacity = 8, refillPerSecond = 1 }, aggregate = { capacity = 16, refillPerSecond = 1 },
		bytes = { perPlayer = { capacity = buffer.len(badFrame), refillPerSecond = 1 },
			aggregate = { capacity = buffer.len(badFrame), refillPerSecond = 1 } },
	})
	runtime:remote().OnServerEvent:Fire(first, 1, badFrame)
	runtime:remote().OnServerEvent:Fire(first, 1, goodFrame)
	runtime:remote().OnServerEvent:Fire(second, 1, goodFrame)
	local counters = server:GetDiagnostics().counters
	assert(calls() == 0 and counters.invalidPayload == 1
		and counters.perPlayerBytes == 1 and counters.aggregateBytes == 1,
		"malformed native body retains per-player and aggregate byte charges")
	server:Destroy()

	runtime, first, second, server, calls = makeServer({
		perPlayer = { capacity = 1, refillPerSecond = 1 }, aggregate = { capacity = 1, refillPerSecond = 1 },
	})
	runtime:remote().OnServerEvent:Fire(first, 1, badFrame)
	runtime:remote().OnServerEvent:Fire(first, 1, goodFrame)
	runtime:remote().OnServerEvent:Fire(second, 1, goodFrame)
	counters = server:GetDiagnostics().counters
	assert(calls() == 0 and counters.invalidPayload == 1
		and counters.perPlayerRate == 1 and counters.aggregateRate == 1,
		"malformed native body retains per-player and aggregate call charges")
	server:Destroy()

	runtime, first, second, server, calls = makeServer({
		perPlayer = { capacity = 8, refillPerSecond = 1 }, aggregate = { capacity = 16, refillPerSecond = 1 },
		endpoints = { [1] = { capacity = 1, refillPerSecond = 1 } },
	})
	runtime:remote().OnServerEvent:Fire(first, 1, badFrame)
	runtime:remote().OnServerEvent:Fire(first, 1, goodFrame)
	local snapshot = server:GetDiagnostics()
	assert(calls() == 0 and snapshot.events.Input.invalidPayload == 1
		and snapshot.counters.endpointRate == 1 and snapshot.events.Input.endpointRate == 1,
		"malformed native body retains its endpoint charge")
	server:Destroy()
end

-- A malformed later Batch or State row prevents every callback and retains the envelope debit.
do
	for _, entry in { { id = 5, kind = 1, name = "BatchInput" }, { id = 6, kind = 2, name = "StateInput" } } do
		local queued = compiled.queuedById[entry.id]
		local validBody = encode(queued, sourceSequence)
		local malformedBody = copied(validBody, buffer.len(validBody))
		buffer.writeu8(malformedBody, 3, 4)
		local packet = assert(BatchFrame.wrap(entry.kind, { validBody, malformedBody }, 8_192))
		local runtime = ServerRuntime.new()
		local player, secondPlayer = runtime:addPlayer(), runtime:addPlayer()
		local server = assert(runtime.server.create(token, { inboundRate = {
			perPlayer = { capacity = 8, refillPerSecond = 1 },
			aggregate = { capacity = 16, refillPerSecond = 1 },
			bytes = { perPlayer = { capacity = buffer.len(packet), refillPerSecond = 1 },
				aggregate = { capacity = buffer.len(packet), refillPerSecond = 1 } },
		} }))
		assert(server:Start())
		local calls = 0
		assert(server.events[entry.name]:Connect(function() calls += 1 end))
		runtime:remote().OnServerEvent:Fire(player, 0, packet)
		local counters = server:GetDiagnostics().counters
		assert(server.events.Input:Connect(function() calls += 1 end))
		runtime:remote().OnServerEvent:Fire(player, 1, encode(compiled.events.Input, sourceSize, roblox.Enum.Material.Wood))
		runtime:remote().OnServerEvent:Fire(secondPlayer, 1,
			encode(compiled.events.Input, sourceSize, roblox.Enum.Material.Wood))
		counters = server:GetDiagnostics().counters
		assert(calls == 0 and counters.invalidPayload == 1 and counters.perPlayerBytes == 1
			and counters.aggregateBytes == 1,
			`invalid later {entry.name} row prevents callbacks after the envelope is admitted`)
		server:Destroy()
	end
end

print("PASS Relay native runtime routes, malformed payloads, and admission charges")
