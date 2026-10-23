require("../scripts/consumer-testing/run")

local Relay = require("../src")
local Kit = require("../scripts/consumer-testing/Kit")
local s = Relay.schema
local namespacedDefinition = assert(Relay.define({
	name = "ConsumerTestingNamespace",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
		Notice = s.serverToClient(2, s.fields(s.field("value", s.u8()))),
	},
}))

local receivedInput, receivedNotice
Kit.withFixture(namespacedDefinition, function(test)
	assert(test.server.events.Input:Connect(function(_, value) receivedInput = value end))
	assert(test.client.events.Notice:Connect(function(value) receivedNotice = value end))
	assert(test:Start(), "namespaced sessions start")
	assert(test.client.events.Input:Send(23) and test:Pump() > 0 and receivedInput == 23,
		"namespaced client events reach the server")
	assert(test.server.events.Notice:Broadcast(24) and test:Pump() > 0 and receivedNotice == 24,
		"namespaced server events reach the client")
end, {
	server = {
		namespace = "typescript",
		inboundRate = {
			perPlayer = { capacity = 4_096, refillPerSecond = 1 },
			aggregate = { capacity = 32_768, refillPerSecond = 1 },
		},
	},
	client = { namespace = "typescript", startupTimeoutSeconds = 3 },
})

local mismatchOk, mismatchFailure = pcall(Kit.new, namespacedDefinition, {
	server = { namespace = "server" },
	client = { namespace = "typescript", startupTimeoutSeconds = 3 },
})
assert(not mismatchOk and tostring(mismatchFailure):find("namespaces must match", 1, true),
	"mismatched fixture namespaces must be rejected")
local definition = assert(Relay.define({
	name = "ConsumerFaultTesting",
	version = 1,
	readiness = true,
	events = {
		Input = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
		Queue = s.clientToServer(2, s.fields(s.field("value", s.u8())), { queue = "Batch" }),
		Notice = s.serverToClient(3, s.fields(s.field("value", s.u8()))),
		UnreliableInput = s.clientToServer(4, s.fields(s.field("value", s.u8())), { delivery = "Unreliable" }),
		Snapshot = s.serverToClient(5, s.fields(s.field("value", s.u8())), { delivery = "Unreliable" }),
		OrderedSnapshot = s.serverToClient(6, s.fields(s.field("value", s.u8())), { delivery = "OrderedUnreliable" }),
	},
	requests = { Echo = s.request(7, s.fields(s.field("value", s.u8())), s.u8()) },
}))

local function matching(test, direction, client, delivery)
	local matches = {}
	for _, message in test:GetPending() do
		if message.direction == direction and message.client == client and message.delivery == delivery then
			table.insert(matches, message)
		end
	end
	return matches
end

local function rejectedControl(control, message)
	local ok, accepted, problem = pcall(control)
	assert(ok and accepted == false and problem ~= nil, message)
end

assert(not pcall(Kit.new, definition, { clients = 0 }) and not pcall(Kit.new, definition, { clients = 5 }),
	"client count is bounded from one through four")

local routedPlayers, routedInputs, routedNotices = {}, {}, { {}, {} }
local routedReplies = {}
local isolatedFixture, isolatedPending, isolatedBatch
Kit.withFixture(definition, function(test)
	assert(#test.clients == 2, "multi-client fixtures expose independent sessions")
	for index, entry in test.clients do
		routedPlayers[entry.player] = index
		assert(entry.client.events.Notice:Connect(function(value)
			table.insert(routedNotices[index], value)
		end))
	end
	assert(test.server.events.Input:Connect(function(player, value)
		table.insert(routedInputs, { client = routedPlayers[player], value = value })
	end))
	assert(test.server.requests.Echo:Connect(function(player, value)
		return value + routedPlayers[player]
	end))
	assert(test:Start())
	assert(test:Pump() > 0)

	for index, entry in test.clients do
		assert(entry.client.events.Input:Send(index * 10))
		routedReplies[index] = assert(entry.client.requests.Echo:Request(5, index * 10))
	end
	assert(test:Pump() > 0)
	assert(#routedInputs == 2 and routedInputs[1].client == 1 and routedInputs[1].value == 10
		and routedInputs[2].client == 2 and routedInputs[2].value == 20,
		"client events route to the matching Player")
	assert(routedReplies[1]:Await().value == 11 and routedReplies[2]:Await().value == 22,
		"RPC replies return only to the requesting client")

	local targeted, targetProblem = test.server.events.Notice:SendTo({ test.clients[2].player }, 30)
	assert(targeted, targetProblem and targetProblem.message or "SendTo failed")
	assert(test.server.events.Notice:Broadcast(40))
	assert(test:Pump() > 0)
	assert(#routedNotices[1] == 1 and routedNotices[1][1] == 40
		and #routedNotices[2] == 2 and routedNotices[2][1] == 30 and routedNotices[2][2] == 40,
		"SendTo selects one client while Broadcast reaches both")

	isolatedFixture = test
	isolatedBatch = assert(test.clients[1].client:CreateBatch(0.1))
	assert(isolatedBatch.events.Queue:Send(51))
	isolatedPending = assert(test.clients[1].client.requests.Echo:Request(30, 51))
	local secondBatch = assert(test.clients[2].client:CreateBatch(0.1))
	assert(secondBatch.events.Queue:Send(52))
	local secondPending = assert(test.clients[2].client.requests.Echo:Request(30, 52))
	local before = test:GetStatus()
	assert(before.clients[1].activeTimers > 0 and before.clients[1].connections > 0
		and before.clients[1].queuedMessages > 0 and before.clients[2].activeTimers > 0,
		"status reports per-client timers, listeners and queued requests")

	test:Disconnect(1)
	local disconnected = isolatedPending:Await()
	assert(not disconnected.ok and disconnected.error.code == "Disconnected")
	assert(isolatedBatch:GetStatus().state == "Terminal" and test.clients[1].player.Parent == nil)
	local after = test:GetStatus()
	assert(after.state == "Started" and after.clients[1].activeTimers == 0
		and after.clients[1].connections == 0 and after.clients[1].queuedMessages == 0,
		"disconnect releases one client's timers, listeners and transport queue")
	assert(after.clients[2].activeTimers > 0 and after.clients[2].connections > 0
		and test.clients[2].player.Parent ~= nil,
		"disconnect leaves other clients active")

	assert(test.clients[2].client.events.Input:Send(23))
	assert(test:Pump() > 0)
	local secondResult = secondPending:Await()
	assert(secondResult.ok and secondResult.value == 54
		and routedInputs[#routedInputs].client == 2 and routedInputs[#routedInputs].value == 23,
		"the remaining client can still use events and RPC")
	test:Disconnect(2)
	assert(test:GetStatus().state == "Disconnected" and secondBatch:GetStatus().state == "Terminal")
end, { clients = 2 })
assert(isolatedFixture:GetStatus().state == "Destroyed")

Kit.withFixture(definition, function(test)
	assert(not pcall(Kit.new, definition, { extra = true }), "unknown fixture options are rejected")
	assert(test:Start())
	assert(test:Pump() > 0)

	local uplink, downlink, orderedSeen = {}, { {}, {} }, { {}, {} }
	local playerIndices, reliableUp, reliableDown = {}, {}, {}
	for index, entry in test.clients do
		playerIndices[entry.player] = index
		assert(entry.client.events.Snapshot:Connect(function(value)
			table.insert(downlink[index], value)
		end))
		assert(entry.client.events.OrderedSnapshot:Connect(function(value)
			table.insert(orderedSeen[index], value)
		end))
		assert(entry.client.events.Notice:Connect(function(value)
			table.insert(reliableDown, value)
		end))
	end
	assert(test.server.events.UnreliableInput:Connect(function(player, value)
		uplink[playerIndices[player]] = uplink[playerIndices[player]] or {}
		table.insert(uplink[playerIndices[player]], value)
	end))
	assert(test.server.events.Input:Connect(function(_, value) table.insert(reliableUp, value) end))

	assert(test.clients[1].client.events.UnreliableInput:Send(10))
	assert(test.clients[1].client.events.UnreliableInput:Send(11))
	assert(test.clients[1].client.events.UnreliableInput:Send(12))
	local up = matching(test, "ClientToServer", 1, "Unreliable")
	assert(#up == 3)
	local dueTime = up[1].dueTime
	rejectedControl(function() return test:Delay(up[1].id, -1) end, "negative delays are rejected")
	rejectedControl(function() return test:Delay(up[1].id, math.huge) end, "non-finite delays are rejected")
	rejectedControl(function() return test:Delay(up[1].id, 61) end, "delays cannot exceed fixture time")
	assert(matching(test, "ClientToServer", 1, "Unreliable")[1].dueTime == dueTime,
		"invalid Delay controls leave the queue unchanged")
	assert(test:Delay(up[1].id, 0.3))
	local upCopy = assert(test:Duplicate(up[2].id))
	assert(test:Deliver(up[2].id) and test:Deliver(upCopy))
	rejectedControl(function() return test:Drop(up[2].id) end, "delivered IDs are stale")
	rejectedControl(function() return test:Duplicate(upCopy) end, "delivered duplicate IDs are stale")
	assert(test:Drop(up[3].id))
	rejectedControl(function() return test:Drop(up[3].id) end, "dropped IDs are stale")
	assert(#uplink[1] == 2 and uplink[1][1] == 11 and uplink[1][2] == 11,
		"unreliable client-to-server duplication is delivered explicitly")
	assert(test:Advance(0.3) and #uplink[1] == 2,
		"Advance changes logical time without delivering delayed transport")
	local delayedUplink = test:Pump()
	assert(delayedUplink > 0 and #uplink[1] == 3 and uplink[1][3] == 10,
		"Pump delivers delayed client-to-server traffic after time advances")

	assert(test.server.events.Snapshot:SendTo({ test.clients[2].player }, 20))
	assert(test.server.events.Snapshot:SendTo({ test.clients[2].player }, 21))
	local down = matching(test, "ServerToClient", 2, "Unreliable")
	assert(#down == 2)
	assert(test:Delay(down[1].id, 0.4) and test:Delay(down[1].id, 0.2))
	assert(matching(test, "ServerToClient", 2, "Unreliable")[1].dueTime == test:GetStatus().time + 0.2,
		"Delay sets the due time relative to the current logical clock")
	local downCopy = assert(test:Duplicate(down[2].id))
	assert(test:Deliver(down[2].id) and test:Deliver(downCopy))
	assert(#downlink[2] == 2 and downlink[2][1] == 21 and downlink[2][2] == 21)
	assert(test:Advance(0.2) and #downlink[2] == 2)
	assert(test:Pump() == 1 and downlink[2][3] == 20,
		"server-to-client delay and reordering use explicit controls")
	assert(#downlink[1] == 0, "targeted unreliable messages stay isolated")

	assert(test.server.events.OrderedSnapshot:SendTo({ test.clients[1].player }, 30))
	assert(test.server.events.OrderedSnapshot:SendTo({ test.clients[1].player }, 31))
	local ordered = matching(test, "ServerToClient", 1, "Unreliable")
	assert(#ordered == 2)
	local staleBefore = test.clients[1].client:GetDiagnostics().events.OrderedSnapshot.stale
	local orderedCopy = assert(test:Duplicate(ordered[2].id))
	assert(test:Deliver(orderedCopy) and test:Deliver(ordered[2].id) and test:Deliver(ordered[1].id))
	local staleAfter = test.clients[1].client:GetDiagnostics().events.OrderedSnapshot.stale
	assert(#orderedSeen[1] == 1 and orderedSeen[1][1] == 31 and staleAfter == staleBefore + 2,
		"Relay rejects older and duplicate ordered-unreliable frames as stale")
	assert(#orderedSeen[2] == 0, "ordered targeted traffic does not reach another client")

	assert(test.clients[1].client.events.Input:Send(40))
	assert(test.clients[1].client.events.Input:Send(41))
	assert(test.server.events.Notice:SendTo({ test.clients[1].player }, 50))
	assert(test.server.events.Notice:SendTo({ test.clients[1].player }, 51))
	assert(test.clients[1].client.events.UnreliableInput:Send(60))
	assert(test.clients[1].client.events.UnreliableInput:Send(61))
	local concurrentUp = matching(test, "ClientToServer", 1, "Unreliable")
	assert(#concurrentUp == 2 and test:Delay(concurrentUp[1].id, 0.4))
	local concurrentUpCopy = assert(test:Duplicate(concurrentUp[2].id))
	assert(test:Deliver(concurrentUp[2].id) and test:Deliver(concurrentUpCopy))
	assert(test.server.events.Snapshot:SendTo({ test.clients[1].player }, 62))
	assert(test.server.events.Snapshot:SendTo({ test.clients[1].player }, 63))
	local concurrentDown = matching(test, "ServerToClient", 1, "Unreliable")
	assert(#concurrentDown == 2 and test:Delay(concurrentDown[1].id, 0.4))
	local concurrentDownCopy = assert(test:Duplicate(concurrentDown[2].id))
	assert(test:Deliver(concurrentDown[2].id) and test:Deliver(concurrentDownCopy))
	local reliableClientMessages = matching(test, "ClientToServer", 1, "Reliable")
	assert(#reliableClientMessages == 2 and #matching(test, "ServerToClient", 1, "Reliable") == 2)
	local reliableId = reliableClientMessages[1].id
	rejectedControl(function() return test:Drop(reliableId) end, "Drop rejects reliable messages")
	rejectedControl(function() return test:Duplicate(reliableId) end, "Duplicate rejects reliable messages")
	rejectedControl(function() return test:Delay(reliableId, 1) end, "Delay rejects reliable messages")
	rejectedControl(function() return test:Deliver(reliableId) end, "Deliver rejects reliable messages")
	for _, control in {
		function() return test:Drop(-1) end,
		function() return test:Duplicate(0) end,
		function() return test:Delay("bad", 0) end,
		function() return test:Deliver(nil) end,
	} do
		rejectedControl(control, "invalid message IDs are rejected")
	end
	local pending = test:GetPending()
	assert(table.isfrozen(pending) and table.isfrozen(pending[1]), "pending metadata is immutable")
	assert(test:Advance(0.4) and #uplink[1] == 5 and #downlink[1] == 2,
		"clock advancement still leaves concurrent delayed faults queued")
	assert(test:Pump() >= 6 and reliableUp[1] == 40 and reliableUp[2] == 41
		and reliableDown[1] == 50 and reliableDown[2] == 51,
		"reliable FIFO order survives unreliable faults in both directions")
	assert(#uplink[1] == 6 and uplink[1][6] == 60 and #downlink[1] == 3 and downlink[1][3] == 62,
		"the same Pump releases each delayed unreliable direction after reliable traffic")
end, { clients = 2 })

local queueFixture = Kit.new(definition, { clients = 4 })
assert(queueFixture:Start())
assert(queueFixture:Pump() > 0)
assert(queueFixture.clients[1].client.events.Notice:Connect(function() end))
assert(queueFixture:Pump() > 0)
local capBatch = assert(queueFixture.clients[1].client:CreateBatch(0.1))
assert(capBatch.events.Queue:Send(1))
local capPending = assert(queueFixture.clients[1].client.requests.Echo:Request(30, 1))
for value = 1, 254 do assert(queueFixture.server.events.Snapshot:Broadcast(value)) end
assert(queueFixture:GetStatus().queuedMessages == 1_017,
	"queue before targeted cap fill: " .. queueFixture:GetStatus().queuedMessages)
for value = 1, 7 do
	local accepted, problem = queueFixture.server.events.Snapshot:SendTo({ queueFixture.clients[1].player }, value)
	assert(accepted, (problem and problem.message or "targeted cap fill failed")
		.. ": send=" .. value .. ", queued=" .. queueFixture:GetStatus().queuedMessages)
end
local atCapacity = queueFixture:GetPending()
assert(#atCapacity == 1_024)
local capUnreliable = matching(queueFixture, "ServerToClient", 1, "Unreliable")
assert(#capUnreliable > 0)
rejectedControl(function() return queueFixture:Duplicate(capUnreliable[1].id) end,
	"Duplicate rejects a full queue without adding a copy")
assert(#queueFixture:GetPending() == 1_024, "duplicate-at-cap leaves queue unchanged")
local overflowAccepted = queueFixture.server.events.Snapshot:Broadcast(1)
local overflowStatus = queueFixture:GetStatus()
assert(not overflowAccepted and overflowStatus.state == "Destroyed" and overflowStatus.connections == 0
	and overflowStatus.activeTimers == 0 and capBatch:GetStatus().state == "Terminal",
	"a broadcast that exceeds the recipient-message cap fails before delivery and tears down")
local capResult = capPending:Await()
assert(not capResult.ok and capResult.error.code == "Destroyed",
	"queue overflow releases request timers and settles pending calls")

local fanoutFixture = Kit.new(definition, { clients = 4 })
assert(fanoutFixture:Start())
assert(fanoutFixture:Pump() > 0)
for value = 1, 255 do assert(fanoutFixture.server.events.Snapshot:Broadcast(value)) end
assert(fanoutFixture.server.events.Snapshot:SendTo({ fanoutFixture.clients[1].player }, 1))
assert(fanoutFixture.server.events.Snapshot:SendTo({ fanoutFixture.clients[1].player }, 2))
assert(#fanoutFixture:GetPending() == 1_022)
assert(not fanoutFixture.server.events.Snapshot:Broadcast(3)
	and fanoutFixture:GetStatus().state == "Destroyed",
	"recipient fanout is checked against the queue cap before capture")

local timeFixture = Kit.new(definition)
assert(timeFixture:Start())
assert(timeFixture:Advance(60))
assert(not timeFixture:Advance(0.01) and timeFixture:GetStatus().time == 60,
	"logical time cannot advance past 60 seconds")
timeFixture:Destroy()

print("consumer fault controls: PASS")
