local roblox = require("@lune/roblox")
local Schema = require("../src/Schema")
local Definition = require("../src/Definition")
local NativeRuntime = require("./support/NativeCodec")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local Frame = NativeRuntime.loadFrame()
local vector3 = Schema.quantizedVector3(-8, 8, 0.5)
local vector2 = Schema.quantizedVector2(-8, 8, 0.5)
local compactFrame = Schema.compactCFrame(-16, 16, 0.5)

local function field(name, shape)
	local result = table.clone(shape)
	result.name = name
	return result
end

local function frameAt(x, y, z, rx, ry, rz)
	return roblox.CFrame.new(x, y, z) * roblox.CFrame.fromEulerAnglesXYZ(rx, ry, rz)
end

local vector3Input = roblox.Vector3.new(0.25, -0.75, 8)
local vector3Output = roblox.Vector3.new(2.75, -2.25, 3.6)
local vector2Input = roblox.Vector2.new(-7.75, 7.75)
local vector2Output = roblox.Vector2.new(1.25, -1.25)
local frameGeneral = frameAt(2.25, -3.25, 1.25, 0.7, -1.1, 2.4)
local framePi = frameAt(-5.25, 6.75, -1.25, math.pi, 0, 0)
local frameGimbal = frameAt(4.25, -2.25, 3.25, 0, math.pi / 2, 0)
local frameIdentity = roblox.CFrame.new(0, 0, 0)
local frameOther = frameAt(1.25, -2.25, 3.25, -2.2, 0.3, -0.9)

local routes = {
	{ name = "Vector3ReliableInput", id = 1, direction = "ClientToServer", shape = vector3, value = vector3Input },
	{ name = "Vector3ReliableOutput", id = 2, direction = "ServerToClient", shape = vector3, value = vector3Output },
	{ name = "FrameReliableInput", id = 3, direction = "ClientToServer", shape = compactFrame, value = frameGeneral },
	{ name = "FrameReliableOutput", id = 4, direction = "ServerToClient", shape = compactFrame, value = framePi },
	{ name = "Vector2UnreliableInput", id = 5, direction = "ClientToServer", delivery = "Unreliable", shape = vector2, value = vector2Input },
	{ name = "Vector2UnreliableOutput", id = 6, direction = "ServerToClient", delivery = "Unreliable", shape = vector2, value = vector2Output },
	{ name = "FrameUnreliableInput", id = 7, direction = "ClientToServer", delivery = "Unreliable", shape = compactFrame, value = frameOther },
	{ name = "FrameUnreliableOutput", id = 8, direction = "ServerToClient", delivery = "Unreliable", shape = compactFrame, value = frameIdentity },
	{ name = "Vector3OrderedInput", id = 9, direction = "ClientToServer", delivery = "OrderedUnreliable", shape = vector3, value = vector3Output },
	{ name = "Vector3OrderedOutput", id = 10, direction = "ServerToClient", delivery = "OrderedUnreliable", shape = vector3, value = vector3Input },
	{ name = "FrameOrderedInput", id = 11, direction = "ClientToServer", delivery = "OrderedUnreliable", shape = compactFrame, value = frameGimbal },
	{ name = "FrameOrderedOutput", id = 12, direction = "ServerToClient", delivery = "OrderedUnreliable", shape = compactFrame, value = framePi },
	{ name = "Vector2BatchInput", id = 13, direction = "ClientToServer", queue = "Batch", shape = vector2, value = vector2Output },
	{ name = "Vector2BatchOutput", id = 14, direction = "ServerToClient", queue = "Batch", shape = vector2, value = vector2Input },
	{ name = "FrameBatchInput", id = 15, direction = "ClientToServer", queue = "Batch", shape = compactFrame, value = frameIdentity },
	{ name = "FrameBatchOutput", id = 16, direction = "ServerToClient", queue = "Batch", shape = compactFrame, value = frameOther },
	{ name = "Vector3StateInput", id = 17, direction = "ClientToServer", queue = "State", shape = vector3, value = vector3Input },
	{ name = "Vector3StateOutput", id = 18, direction = "ServerToClient", queue = "State", shape = vector3, value = vector3Output },
	{ name = "FrameStateInput", id = 19, direction = "ClientToServer", queue = "State", shape = compactFrame, value = frameOther },
	{ name = "FrameStateOutput", id = 20, direction = "ServerToClient", queue = "State", shape = compactFrame, value = frameGimbal },
}

local events, unreliableIds = {}, {}
local byName = {}
for _, route in routes do
	byName[route.name] = route
	events[route.name] = { id = route.id, direction = route.direction, delivery = route.delivery,
		queue = route.queue, fields = { field("value", route.shape) } }
	if route.delivery ~= nil then unreliableIds[route.id] = true end
end
local packedVector = roblox.Vector3.new(0.75, 0.25, 2.25)
events.PackedInput = { id = 21, direction = "ClientToServer", fields = {
	{ name = "flag", type = "optional", value = { type = "boolean" } },
	{ name = "mode", type = "enum", values = { "Idle", "Move", "Jump" } },
	field("vector", vector3),
} }

local token, issue = Definition.define({
	name = "CompactRuntime", version = 1, bitPacking = true, events = events,
	requests = { Lookup = { id = 22,
		request = { field("position3", vector3), field("position2", vector2), field("transform", compactFrame) },
		response = { type = "struct", fields = {
			field("position3", vector3), field("position2", vector2), field("transform", compactFrame),
		} },
	} },
})
assert(token, issue and issue.message)
local compiled = assert(Definition.get(token))
assert(compiled.bitPacking and string.match(compiled.descriptor, "^RR13|D"),
	"compact leaves use the checked bit-packed tuple path when both features are enabled")

local serverRuntime = ServerRuntime.new()
local player = serverRuntime:addPlayer()
local server = assert(serverRuntime.server.create(token, { inboundRate = {
	perPlayer = { capacity = 128, refillPerSecond = 128 },
	aggregate = { capacity = 256, refillPerSecond = 256 },
} }))
assert(server:Start())

local clientRuntime = ClientRuntime.create()
local _, _, clientRemote, clientUnreliable = clientRuntime:transport(compiled.descriptor, compiled.hasUnreliable)
local serverRemote, serverUnreliable = serverRuntime:remote(), serverRuntime:unreliableRemote()
local function dispatchClient(endpointId, ...)
	local remote = if unreliableIds[endpointId] then clientUnreliable else clientRemote
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

local function assertVector(actual, source, bound, name)
	local vectorType = typeof(source)
	assert(typeof(actual) == vectorType, `{name} remains {vectorType}`)
	for _, component in { "X", "Y", if vectorType == "Vector3" then "Z" else nil } do
		if component ~= nil then
			assert(math.abs(actual[component] - source[component]) <= bound,
				`{name}.{component} exceeds the declared component error`)
		end
	end
end

local function assertCFrame(actual, source, name)
	assert(typeof(actual) == "CFrame", `{name} remains CFrame`)
	local sx, sy, sz = source:GetComponents()
	local ax, ay, az = actual:GetComponents()
	assert(math.abs(ax - sx) <= compiled.events.FrameReliableInput.fields[1].maximumPositionError
		and math.abs(ay - sy) <= compiled.events.FrameReliableInput.fields[1].maximumPositionError
		and math.abs(az - sz) <= compiled.events.FrameReliableInput.fields[1].maximumPositionError,
		`{name} translation exceeds the independent position bound`)
	local angle = source:AngleBetween(actual)
	assert(angle <= 0.002, `{name} rotation error {angle} exceeds 0.002 radians`)
end

local function assertValue(actual, route, name)
	if route.shape == compactFrame then
		assertCFrame(actual, route.value, name)
	else
		assertVector(actual, route.value, compiled.events[route.name].fields[1].maximumComponentError, name)
	end
end

local received = {}
for _, route in routes do
	local selected = route
	if route.direction == "ClientToServer" then
		assert(server.events[route.name]:Connect(function(_, value)
			assertValue(value, selected, selected.name)
			received[selected.name] = (received[selected.name] or 0) + 1
		end))
	else
		assert(client.events[route.name]:Connect(function(value)
			assertValue(value, selected, selected.name)
			received[selected.name] = (received[selected.name] or 0) + 1
		end))
	end
end
assert(server.events.PackedInput:Connect(function(_, flag, mode, value)
	assert(flag == false and mode == "Move", "packed optional presence and literal enum survive the compact tuple")
	assertVector(value, packedVector, compiled.events.PackedInput.fields[3].maximumComponentError, "PackedInput.vector")
	received.PackedInput = (received.PackedInput or 0) + 1
end))

local rpcCalls = 0
local rpcArguments
assert(server.requests.Lookup:Connect(function(_, position3, position2, transform)
	rpcArguments = { position3, position2, transform }
	rpcCalls += 1
	return { position3 = vector3Output, position2 = vector2Output, transform = frameOther }
end))

assert(client:Start())
local invalidHandoffs = #clientRuntime.fires
local wrongVector, wrongVectorError = client.events.Vector3ReliableInput:Send(roblox.Vector2.new(0, 0))
local outOfBoundsVector, boundsError = client.events.Vector3ReliableInput:Send(roblox.Vector3.new(9, 0, 0))
local wrongFrame, frameTypeError = client.events.FrameReliableInput:Send(roblox.Vector3.new(0, 0, 0))
local outOfBoundsFrame, frameBoundsError = client.events.FrameReliableInput:Send(roblox.CFrame.new(17, 0, 0))
local nonfiniteVector = roblox.Vector3.new(math.huge, 0, 0)
local nonfiniteAccepted, nonfiniteError = client.events.Vector3ReliableInput:Send(nonfiniteVector)
local nonfiniteFrameConstructed, nonfiniteFrame = pcall(roblox.CFrame.new, math.huge, 0, 0)
local nonfiniteFrameRejected = not nonfiniteFrameConstructed
if nonfiniteFrameConstructed then
	local accepted, problem = client.events.FrameReliableInput:Send(nonfiniteFrame)
	nonfiniteFrameRejected = not accepted and problem.code == "InvalidPayload"
end
assert(not wrongVector and wrongVectorError.code == "InvalidPayload"
	and not outOfBoundsVector and boundsError.code == "InvalidPayload"
	and not wrongFrame and frameTypeError.code == "InvalidPayload"
	and not outOfBoundsFrame and frameBoundsError.code == "InvalidPayload"
	and not nonfiniteAccepted and nonfiniteError.code == "InvalidPayload" and nonfiniteFrameRejected
	and #clientRuntime.fires == invalidHandoffs,
	"wrong native types, nonfinite values, and original out-of-range components reject before handoff")
local serverHandoffs = #serverRuntime.fires
local serverInvalid, serverInvalidError = server.events.Vector3ReliableOutput:Send(player,
	roblox.Vector2.new(0, 0))

local serverBadFrame, serverBadFrameError = server.events.FrameReliableOutput:Send(player,
	roblox.CFrame.new(17, 0, 0))
assert(not serverInvalid and serverInvalidError.code == "InvalidPayload"
	and not serverBadFrame and serverBadFrameError.code == "InvalidPayload"
	and #serverRuntime.fires == serverHandoffs,
	"server-side vector and CFrame validation rejects invalid native values before handoff")

for _, route in routes do
	if route.queue == nil and route.direction == "ClientToServer" then
		assert(client.events[route.name]:Send(route.value))
	elseif route.queue == nil and route.direction == "ServerToClient" then
		assert(server.events[route.name]:Send(player, route.value))
	end
end
assert(client.events.PackedInput:Send(false, "Move", packedVector))

local clientBatch = assert(client:CreateBatch(0.05))
local serverBatch = assert(server:CreateBatch({ player }, 0.05))
for _, route in routes do
	if route.queue == "Batch" and route.direction == "ClientToServer" then
		assert(clientBatch.events[route.name]:Send(route.value))
	elseif route.queue == "Batch" and route.direction == "ServerToClient" then
		assert(serverBatch.events[route.name]:Send(route.value))
	end
end
assert(clientBatch:Flush() and serverBatch:Flush())

local clientState = assert(client:CreateState(0.05))
local serverState = assert(server:CreateState({ player }, 0.05))
for _, route in routes do
	if route.queue == "State" and route.direction == "ClientToServer" then
		assert(clientState.events[route.name]:Put(route.id, "High", route.value))
	elseif route.queue == "State" and route.direction == "ServerToClient" then
		assert(serverState.events[route.name]:Put(route.id, "High", route.value))
	end
end
assert(clientState:Flush() and serverState:Flush())

local pending, requestError = client.requests.Lookup:Request(3, vector3Input, vector2Input, frameGeneral)
assert(pending, requestError and requestError.message)
local response = pending:Await()
assert(response.ok and rpcCalls == 1, "compact native RPC request and response complete once")
assertVector(rpcArguments[1], vector3Input,
	compiled.requests.Lookup.request.fields[1].maximumComponentError, "RPC request Vector3")
assertVector(rpcArguments[2], vector2Input,
	compiled.requests.Lookup.request.fields[2].maximumComponentError, "RPC request Vector2")
assertCFrame(rpcArguments[3], frameGeneral, "RPC request CFrame")
assertVector(response.value.position3, vector3Output,
	compiled.requests.Lookup.response.fields[1].fields[1].maximumComponentError, "RPC response Vector3")
assertVector(response.value.position2, vector2Output,
	compiled.requests.Lookup.response.fields[1].fields[2].maximumComponentError, "RPC response Vector2")
assertCFrame(response.value.transform, frameOther, "RPC response CFrame")
for _, route in routes do
	assert(received[route.name] == 1, `{route.name} delivers one native compact value`)
end
assert(received.PackedInput == 1)

local function copy(value, length)
	local result = buffer.create(length or buffer.len(value))
	buffer.copy(result, 0, value, 0, math.min(buffer.len(value), buffer.len(result)))
	return result
end
local valid, goodVectorFrame = Frame.compile(compiled.events.Vector3ReliableInput, "encode")(vector3Input)
assert(valid and buffer.len(goodVectorFrame) == 6
	and buffer.readu8(goodVectorFrame, 3) == 17 and buffer.readu8(goodVectorFrame, 4) == 15
	and buffer.readu8(goodVectorFrame, 5) == 32,
	"checked vector codec writes the selected component indexes into the bounded frame")

local function proveMalformed(raw, label)
	local runtime = ServerRuntime.new()
	local sender = runtime:addPlayer()
	local serverWithBytes = assert(runtime.server.create(token, { inboundRate = {
		perPlayer = { capacity = 8, refillPerSecond = 8 },
		aggregate = { capacity = 16, refillPerSecond = 16 },
		bytes = {
			perPlayer = { capacity = buffer.len(goodVectorFrame), refillPerSecond = buffer.len(goodVectorFrame) },
			aggregate = { capacity = buffer.len(goodVectorFrame) * 2, refillPerSecond = buffer.len(goodVectorFrame) * 2 },
		},
	} }))
	local calls = 0
	assert(serverWithBytes.events.Vector3ReliableInput:Connect(function() calls += 1 end))
	assert(serverWithBytes:Start())
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(sender, 1, raw)
	remote.OnServerEvent:Fire(sender, 1, goodVectorFrame)
	local diagnostics = serverWithBytes:GetDiagnostics()
	assert(calls == 0 and diagnostics.events.Vector3ReliableInput.invalidPayload == 1
		and diagnostics.counters.perPlayerBytes == 1 and diagnostics.counters.aggregateBytes == 0,
		`{label} rejects atomically after charging the raw frame; player-first refusal makes no aggregate debit`)
	runtime:advance(1)
	remote.OnServerEvent:Fire(sender, 1, goodVectorFrame)
	assert(calls == 1 and serverWithBytes:GetDiagnostics().events.Vector3ReliableInput.invalidPayload == 1,
		`valid compact input recovers after {label}`)
	serverWithBytes:Destroy()
end

local unused = copy(goodVectorFrame)
buffer.writeu8(unused, 3, 33)
proveMalformed(unused, "an unused final vector code")
proveMalformed(copy(goodVectorFrame, buffer.len(goodVectorFrame) - 1), "a truncated vector")

local clientTimers = 0
for _ in clientRuntime.timers do clientTimers += 1 end
assert(clientTimers == 0 and serverRuntime:activeTimers() == 0
	and server:GetDiagnostics().inFlight == 0,
	"compact native routes leave no RPC or queue work pending")
client:Destroy()
server:Destroy()

print("PASS compact native vector/CFrame routes, error bounds, and malformed-frame admission")
