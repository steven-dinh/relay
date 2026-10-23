local Relay = require("../../src")
local Kit = require("./Kit")
local s = Relay.schema

local definition = assert(Relay.define({
	name = "ConsumerTestingKit",
	version = 1,
	readiness = true,
	events = {
		Input = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
		Queue = s.clientToServer(2, s.fields(s.field("value", s.u8())), { queue = "Batch" }),
		Notice = s.serverToClient(3, s.fields(s.field("value", s.u8()))),
		Stamp = s.clientToServer(4, s.fields(
			s.field("serverTime", s.f64(0, 2 ^ 41)),
			s.field("value", s.u8())
		), { timestampWindow = 0.5 }),
		Late = s.clientToServer(6, s.fields(s.field("value", s.u8()))),
	},
	requests = {
		Echo = s.request(5, s.fields(s.field("value", s.u8())), s.u8()),
	},
}))

local receivedInput, receivedNotice, receivedStamp = nil, nil, nil
local queueValues, echoCalls = {}, 0
local batch
Kit.withFixture(definition, function(test)
	local accepted, problem = test.client.events.Input:Send(1)
	assert(not accepted and problem.code == "NotStarted", "client sends must fail before Start")
	assert(not pcall(function() test:Pump() end), "Pump must require a started fixture")
	assert(not test:Advance(-1) and not test:Advance(math.huge) and not test:Advance(61),
		"invalid or over-limit time must be rejected without advancing")

	assert(test.client.events.Notice:Connect(function(value) receivedNotice = value end))
	assert(test.server.events.Input:Connect(function(player, value)
		assert(player == test.player)
		receivedInput = value
	end))
	assert(test.server.events.Stamp:Connect(function(_, _, value) receivedStamp = value end))
	assert(test.server.events.Queue:Connect(function(_, value) table.insert(queueValues, value) end))
	assert(test.server.requests.Echo:Connect(function(player, value)
		assert(player == test.player)
		echoCalls += 1
		return value + 1
	end))

	assert(test:Start())
	local ready = assert(test.server.events.Notice:GetReadyPlayers())
	assert(#ready == 0, "readiness traffic must wait for Pump")
	assert(test:Pump() > 0)
	ready = assert(test.server.events.Notice:GetReadyPlayers())
	assert(#ready == 1 and ready[1] == test.player, "listener readiness must complete after Pump")
	assert(test.client.events.Late:Send(17) and test:Pump() > 0)
	local lateValue = nil
	assert(test.server.events.Late:Connect(function(_, value) lateValue = value end))
	assert(lateValue == nil, "a send without a listener must not replay after subscription")
	assert(test.client.events.Late:Send(18) and test:Pump() > 0 and lateValue == 18)

	assert(test.client.events.Input:Send(7))
	assert(receivedInput == nil, "transport must wait for Pump")
	assert(test:Pump() > 0 and receivedInput == 7, "real client event reaches its server listener")
	assert(test.server.events.Notice:Broadcast(8))
	assert(test:Pump() > 0 and receivedNotice == 8, "real server event reaches its client listener")
	assert(test.client.events.Stamp:Send(9))
	assert(test:Pump() > 0 and receivedStamp == 9, "timestamp-window delivery uses the shared fixture clock")

	local success = assert(test.client.requests.Echo:Request(2, 10))
	assert(test:Pump() > 0)
	local result = success:Await()
	assert(result.ok and result.value == 11, "RPC request/reply uses real Relay sessions")

	local timedOut = assert(test.client.requests.Echo:Request(0.2, 12))
	assert(test:Advance(0.3))
	result = timedOut:Await()
	assert(not result.ok and result.error.code == "RequestTimeout", "RPC timeout settles locally")
	local callsBeforeLateRequest = echoCalls
	assert(test:Pump() > 0 and echoCalls == callsBeforeLateRequest + 1,
		"a timed-out request can still run on the server when delivered later")
	result = timedOut:Await()
	assert(not result.ok and result.error.code == "RequestTimeout", "a late reply cannot change timeout")
	assert(test.client.events.Stamp:Send(10))
	assert(test:Pump() > 0 and receivedStamp == 10, "server clocks stay synchronized after Advance")

	local cancelled = assert(test.client.requests.Echo:Request(2, 13))
	cancelled:Cancel()
	result = cancelled:Await()
	assert(not result.ok and result.error.code == "Cancelled", "RPC cancellation settles locally")
	local callsBeforeCancelledRequest = echoCalls
	assert(test:Pump() > 0 and echoCalls == callsBeforeCancelledRequest + 1,
		"local cancellation does not cancel server work")
	result = cancelled:Await()
	assert(not result.ok and result.error.code == "Cancelled", "a late reply cannot change cancellation")

	batch = assert(test.client:CreateBatch(0.1))
	for value = 1, 32 do assert(batch.events.Queue:Send(value)) end
	local queued, queueProblem = batch.events.Queue:Send(33)
	assert(not queued and queueProblem.code == "QueueFull" and batch:GetStatus().pendingRecords == 32,
		"QueueFull preserves accepted records")
	assert(batch:Flush())
	assert(test:Pump() > 0 and #queueValues == 32)
	for index = 1, 32 do assert(queueValues[index] == index, "reliable batch preserves FIFO order") end
end)

local disconnectFixture, disconnectBatch, disconnectPending
Kit.withFixture(definition, function(test)
	disconnectFixture = test
	assert(test.client.events.Notice:Connect(function() end))
	assert(test:Start())
	assert(test:Pump() > 0)
	disconnectBatch = assert(test.client:CreateBatch(0.1))
	assert(disconnectBatch.events.Queue:Send(42))
	disconnectPending = assert(test.client.requests.Echo:Request(10, 14))
	test:Disconnect()
	local result = disconnectPending:Await()
	assert(not result.ok and result.error.code == "Disconnected", "disconnect settles pending calls")
	assert(test.player.Parent == nil and disconnectBatch:GetStatus().state == "Terminal",
		"disconnect removes the fake Player and closes queued work")
	assert(test:Pump() == 0)
end)
assert(disconnectFixture:GetStatus().state == "Destroyed")

local lostServerFixture = Kit.new(definition)
assert(lostServerFixture:Start())
local lostServerPending = assert(lostServerFixture.client.requests.Echo:Request(10, 16))
lostServerFixture.server:Destroy()
assert(lostServerFixture:Pump() == 0)
local lostServerResult = lostServerPending:Await()
assert(not lostServerResult.ok and lostServerResult.error.code == "Disconnected"
	and lostServerFixture:GetStatus().state == "Disconnected"
	and lostServerFixture:GetStatus().queuedMessages == 0,
	"Pump mirrors server teardown and discards held transport records")
lostServerFixture:Destroy()

local cleanupFixture, cleanupPending
local callbackOk = pcall(function()
	Kit.withFixture(definition, function(test)
		cleanupFixture = test
		assert(test:Start())
		cleanupPending = assert(test.client.requests.Echo:Request(20, 15))
		local status = test:GetStatus()
		assert(status.activeTimers > 0 and status.connections > 0, "fixture owns active timers and connections")
		error("intentional callback failure")
	end)
end)
assert(not callbackOk, "withFixture must rethrow callback failures")
local cleanupStatus = cleanupFixture:GetStatus()
assert(cleanupStatus.state == "Destroyed" and cleanupStatus.activeTimers == 0
	and cleanupStatus.connections == 0 and cleanupStatus.queuedMessages == 0,
	"withFixture failure destroys sessions, timers, connections, and held messages")
local cleanupResult = cleanupPending:Await()
assert(not cleanupResult.ok and cleanupResult.error.code == "Destroyed")

local loopDefinition = assert(Relay.define({ name = "ConsumerPumpLimit", version = 1, events = {
	Ping = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
	Pong = s.serverToClient(2, s.fields(s.field("value", s.u8()))),
} }))
local loopFixture = Kit.new(loopDefinition)
assert(loopFixture.client.events.Pong:Connect(function(value) loopFixture.client.events.Ping:Send(value) end))
assert(loopFixture.server.events.Ping:Connect(function(player, value)
	loopFixture.server.events.Pong:Send(player, value)
end))
assert(loopFixture:Start())
assert(loopFixture.client.events.Ping:Send(1))
local pumpOk, pumpFailure = pcall(function() loopFixture:Pump() end)
local loopStatus = loopFixture:GetStatus()
assert(not pumpOk and tostring(pumpFailure):find("1024", 1, true)
	and loopStatus.state == "Destroyed" and loopStatus.connections == 0 and loopStatus.activeTimers == 0,
	"feedback overflow must stop and clean the fixture")

local function rejected(spec, reason)
	local token = assert(Relay.define(spec))
	local ok, problem = pcall(Kit.new, token)
	assert(not ok and tostring(problem):find(reason, 1, true), "unsupported definition must be rejected")
end
rejected({ name = "ConsumerUnreliable", version = 1, events = {
	Input = s.clientToServer(1, s.fields(), { delivery = "Unreliable" }),
} }, "unreliable")
rejected({ name = "ConsumerOrdered", version = 1, events = {
	Input = s.clientToServer(1, s.fields(), { delivery = "OrderedUnreliable" }),
} }, "ordered client-to-server")
rejected({ name = "ConsumerReferences", version = 1, events = {
	Input = s.clientToServer(1, s.fields(s.field("part", s.Instance("Part")))),
} }, "Instance references")
assert(not pcall(Kit.new, {}), "invalid definition token must be rejected")
assert(not pcall(Kit.new, definition, { client = { startupTimeoutSeconds = 0 } }),
	"invalid client options must fail during construction")

print("consumer testing kit: PASS")
