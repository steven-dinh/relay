local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local RpcFrame = require("../src/internal/RpcFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local schema = {
	name = "OutboundBytesTest",
	version = 1,
	outboundBytes = { capacity = 16, refillPerSecond = 20 },
	events = {
		Native = { id = 1, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
		Unreliable = { id = 2, direction = "ServerToClient", delivery = "Unreliable",
			fields = { { name = "value", type = "u8" } } },
		Ordered = { id = 3, direction = "ServerToClient", delivery = "OrderedUnreliable",
			fields = { { name = "value", type = "u8" } } },
		FIFO = { id = 4, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		Snapshot = { id = 5, direction = "ServerToClient", queue = "State",
			fields = { { name = "value", type = "u8" } } },
	},
}
local token, issue = Definition.define(schema)
assert(token, issue and issue.message)
local compiled = Definition.get(token)

local function serverOptions()
	return { inboundRate = {
		perPlayer = { capacity = 4_096, refillPerSecond = 1 },
		aggregate = { capacity = 32_768, refillPerSecond = 1 },
	} }
end

local runtime = ServerRuntime.new()
local first = runtime:addPlayer()
local second = runtime:addPlayer()
local server = assert(runtime.server.create(token, serverOptions()))
assert(server:Start())
local native = server.events.Native

assert(native:Send(first, 7))
local fires = #runtime.fires
local fanoutOk, fanoutError, sent = native:SendTo({ first, second }, 7)
assert(not fanoutOk and fanoutError.code == "OutboundRateLimited" and sent == 0
	and #runtime.fires == fires, "fanout refusal is atomic and reports zero handoffs")
assert(native:Send(second, 7), "failed audience preflight must not debit later peers")
runtime:advance(0.55)
local sendToOk, _, sendToCount = native:SendTo({ first, second }, 7)
assert(sendToOk and sendToCount == 2)
runtime:advance(0.55)
local exceptOk, _, exceptCount = native:SendExcept({ first }, 7)
assert(exceptOk and exceptCount == 1)
runtime:advance(0.55)
assert(native:Broadcast(7))
local lastFire = runtime.fires[#runtime.fires]
assert(lastFire.kind == "broadcast" and lastFire.values.n == 2 and lastFire.values[1] == 1,
	"budgeted Broadcast retains one FireAllClients handoff")
local unownedPlayer = runtime.newInstance("Player")
unownedPlayer.Parent = runtime.players
local beforeUnownedBroadcast = #runtime.fires
local unownedOk, unownedError = native:Broadcast(7)
assert(not unownedOk and unownedError.code == "OutboundRateLimited"
	and #runtime.fires == beforeUnownedBroadcast,
	"Broadcast fails closed if an actual recipient has no current budget owner")
unownedPlayer.Parent = nil

runtime:advance(0.55)
assert(server.events.Unreliable:Send(first, 9))
local unreliableFire = runtime.fires[#runtime.fires]
assert(unreliableFire.remote.ClassName == "UnreliableRemoteEvent"
	and buffer.len(unreliableFire.values[2]) == 4, "unreliable content is charged by its exact buffer length")
runtime:advance(0.35)
assert(server.events.Ordered:Send(first, 10))
local orderedPacket = runtime.fires[#runtime.fires].values[2]
assert(buffer.len(orderedPacket) == 12, "ordered content includes its outer header in the charge")

local batch = assert(server:CreateBatch({ first }, 0.05))
assert(batch.events.FIFO:Send(1))
runtime:advance(0.05)
local batchStatus = batch:GetStatus()
assert(batchStatus.state == "Open" and batchStatus.pendingRecords == 1
	and batchStatus.lastFlush.error.code == "OutboundRateLimited"
	and batchStatus.lastFlush.report.selected == 0 and batchStatus.lastFlush.report.remaining == 1
	and runtime:activeTimers() == 0, "timer refusal keeps FIFO records and stops automatic retry")
runtime:advance(0.2)
assert(batch:Flush() and batch:GetStatus().state == "Terminal"
	and batch:GetStatus().lastFlush.ok, "explicit FIFO retry spends the retained frame once")

assert(server.events.Native:Send(second, 2))
assert(server.events.Unreliable:Send(second, 3))
local state = assert(server:CreateState({ second }, 0.05))
assert(state.events.Snapshot:Put(1, "Normal", 4))
runtime:advance(0.05)
local stateStatus = state:GetStatus()
assert(stateStatus.pendingKeys == 1 and stateStatus.lastFlush.error.code == "OutboundRateLimited"
	and stateStatus.lastFlush.report.selected == 0 and runtime:activeTimers() == 1,
	"State refusal retains the value and schedules expiry cleanup only")
runtime:advance(0.4)
assert(state:Flush() and state:GetStatus().pendingKeys == 0,
	"explicit State retry can send retained values before expiry")

local expiringState = assert(server:CreateState({ second }, 0.05))
assert(expiringState.events.Snapshot:Put(2, "Normal", 5))
runtime:advance(0.05)
assert(expiringState:GetStatus().pendingKeys == 1
	and expiringState:GetStatus().lastFlush.error.code == "OutboundRateLimited")
local beforeExpiry = #runtime.fires
runtime:advance(0.95)
assert(expiringState:GetStatus().pendingKeys == 0 and #runtime.fires == beforeExpiry
	and runtime:activeTimers() == 0, "expiry cleanup clears refused State without auto-retrying")

local deadlineRuntime = ServerRuntime.new()
local deadlinePlayer = deadlineRuntime:addPlayer()
local deadlineServer = assert(deadlineRuntime.server.create(token, serverOptions()))
assert(deadlineServer:Start())
assert(deadlineServer.events.Native:Send(deadlinePlayer, 1))
local expiringLane = assert(deadlineServer:CreateState({ deadlinePlayer }, 0.05))
assert(expiringLane.events.Snapshot:Put(1, "Normal", 1))
deadlineRuntime:advance(0.05)
assert(expiringLane:GetStatus().lastFlush.error.code == "OutboundRateLimited"
	and expiringLane:GetStatus().pendingKeys == 1 and deadlineRuntime:activeTimers() == 1,
	"refused lane retains its value with expiry-only cleanup pending")
deadlineRuntime:advance(0.9)
local flushLane = assert(deadlineServer:CreateState({ deadlinePlayer }, 0.1))
assert(flushLane.events.Snapshot:Put(2, "Normal", 2))
local beforeLaneDeadline = #deadlineRuntime.fires
deadlineRuntime:advance(0.05)
assert(expiringLane:GetStatus().pendingKeys == 0 and flushLane:GetStatus().pendingKeys == 1
	and #deadlineRuntime.fires == beforeLaneDeadline and deadlineRuntime:activeTimers() == 1,
	"another lane's expiry cleans up without flushing this lane before its deadline")
deadlineRuntime:advance(0.05)
assert(flushLane:GetStatus().pendingKeys == 0 and #deadlineRuntime.fires == beforeLaneDeadline + 1,
	"state lane flushes at its own first-pending deadline")
deadlineServer:Destroy()

local serverDiagnostics = server:GetDiagnostics()
assert(serverDiagnostics.outboundBytes.capacity == 16 and table.isfrozen(serverDiagnostics.outboundBytes)
	and serverDiagnostics.counters.outboundByteRejected == 5
	and serverDiagnostics.counters.outboundBytesCharged == 126,
	"diagnostics expose the copied policy, refused attempts and weighted content charges")
server:Destroy()
assert(server:GetDiagnostics().inFlight == 0, "destroy releases session-owned state")

local queueBudgetToken, queueDefinitionIssue = Definition.define({
	name = "OutboundQueueBytesTest",
	version = 1,
	outboundBytes = { capacity = 32, refillPerSecond = 18 },
	events = {
		Precharge = { id = 1, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
		ReliableBatch = { id = 2, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		UnreliableBatch = { id = 3, direction = "ServerToClient", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		ReliableState = { id = 4, direction = "ServerToClient", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		UnreliableState = { id = 5, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
			fields = { { name = "value", type = "u8" } } },
	},
})
assert(queueBudgetToken, queueDefinitionIssue and queueDefinitionIssue.message)

local function verifyCombinedQueueBudget(queueKind)
	local queueRuntime = ServerRuntime.new()
	local queuePlayer = queueRuntime:addPlayer()
	local queueServer = assert(queueRuntime.server.create(queueBudgetToken, serverOptions()))
	assert(queueServer:Start())
	assert(queueServer.events.Precharge:Send(queuePlayer, 1))
	assert(queueServer.events.Precharge:Send(queuePlayer, 2))
	local firesBeforeQueue = #queueRuntime.fires
	local queue
	if queueKind == "Batch" then
		local created, problem = queueServer:CreateBatch({ queuePlayer }, 0.05)
		assert(created, problem and problem.code or "Batch creation failed")
		queue = created
		assert(queue.events.ReliableBatch:Send(1) and queue.events.UnreliableBatch:Send(2))
	else
		local created, problem = queueServer:CreateState({ queuePlayer }, 0.05)
		assert(created, problem and problem.code or "State creation failed")
		queue = created
		assert(queue.events.ReliableState:Put(1, "Normal", 1)
			and queue.events.UnreliableState:Put(2, "Normal", 2))
	end
	queueRuntime:advance(0.05)
	local diagnostic = queueServer:GetDiagnostics().counters
	assert(#queueRuntime.fires == firesBeforeQueue and diagnostic.outboundBytesCharged == 22
		and diagnostic.outboundByteRejected == 1,
		queueKind .. " must reject the 18-byte combined packet without debiting the 10-byte available balance")
	local refused = queue:GetStatus()
	if queueKind == "Batch" then
		assert(refused.state == "Open" and refused.pendingRecords == 2
			and refused.lastFlush.error.code == "OutboundRateLimited"
			and refused.lastFlush.report.selected == 0 and refused.lastFlush.report.remaining == 2,
			"combined FIFO refusal retains both channel records")
	else
		assert(refused.pendingKeys == 2 and refused.lastFlush.error.code == "OutboundRateLimited"
			and refused.lastFlush.report.selected == 0 and refused.lastFlush.report.remaining == 2,
			"combined State refusal retains both channel records")
	end

	-- Each final channel packet costs 9 bytes; the remaining 10 bytes fit either one, not both.
	queueRuntime:advance(0.5)
	local ok, _, report = queue:Flush()
	assert(ok and report.selected == 2 and #queueRuntime.fires == firesBeforeQueue + 2,
		queueKind .. " explicit retry sends both retained channels once after refill")
	local reliableFire, unreliableFire = queueRuntime.fires[firesBeforeQueue + 1], queueRuntime.fires[firesBeforeQueue + 2]
	assert(reliableFire.remote.ClassName == "RemoteEvent" and unreliableFire.remote.ClassName == "UnreliableRemoteEvent"
		and buffer.len(reliableFire.values[2]) == 9 and buffer.len(unreliableFire.values[2]) == 9,
		queueKind .. " retry includes each final packet envelope in the byte charge")
	local charged = queueServer:GetDiagnostics().counters
	assert(charged.outboundBytesCharged == 40 and charged.outboundByteRejected == 1,
		queueKind .. " charges the combined packet bytes once after successful reservation")
	queueServer:Destroy()
end

verifyCombinedQueueBudget("Batch")
verifyCombinedQueueBudget("State")

local rpcToken = assert(Definition.define({
	name = "OutboundRpcBytesTest",
	version = 1,
	outboundBytes = { capacity = 48, refillPerSecond = 1 },
	events = {},
	requests = {
		Echo = { id = 7, request = { { name = "value", type = "u8" } }, response = { type = "u8" } },
	},
}))
local rpcCompiled = Definition.get(rpcToken)
local rpcRuntime = ServerRuntime.new()
local rpcPlayer = rpcRuntime:addPlayer()
local rpcServer = assert(rpcRuntime.server.create(rpcToken, serverOptions()))
assert(rpcServer:Start())
local handlerCalls = 0
rpcServer.requests.Echo:Connect(function(_, value)
	handlerCalls += 1
	return value
end)
local encodeRequest = Frame.compile(rpcCompiled.requests.Echo.request, "encode")
for callId = 1, 2 do
	local valid, body = encodeRequest(callId)
	assert(valid)
	local request = assert(RpcFrame.wrap(1, 7, callId, "01234567-89ab-cdef-0123-456789abcdef", body))
	rpcRuntime:remote().OnServerEvent:Fire(rpcPlayer, 0, request)
end
local normalResponse = rpcRuntime.fires[#rpcRuntime.fires - 1].values[2]
local refusedResponse = rpcRuntime.fires[#rpcRuntime.fires].values[2]
assert(RpcFrame.peek(normalResponse, false, true).kind == 2 and buffer.len(normalResponse) == 48
	and RpcFrame.peek(refusedResponse, false, true).kind == 5 and buffer.len(refusedResponse) == 44
	and handlerCalls == 2, "RPC application reply is charged; exhausted replies use one exempt kind-5 control")
local rpcDiagnostics = rpcServer:GetDiagnostics().counters
assert(rpcDiagnostics.outboundBytesCharged == 48 and rpcDiagnostics.outboundByteRejected == 1)

local clientRuntime = ClientRuntime.create()
local _, _, clientRemote = clientRuntime:transport(rpcCompiled.descriptor, false)
local client = assert(clientRuntime.module.create(rpcToken, { startupTimeoutSeconds = 3 }))
assert(client:Start())
local pending = assert(client.requests.Echo:Request(3, 9))
local clientGuid = "abcdefab-cdef-4000-8000-000000000001"
clientRemote.OnClientEvent:fire(0, assert(RpcFrame.wrap(5, 7, 1, clientGuid, nil, true)))
local result = pending:Await()
assert(not result.ok and result.error.code == "OutboundRateLimited",
	"capability-matched client settles a budget refusal without waiting for timeout")
assert(client:GetDiagnostics().outboundBytes == nil, "client diagnostics do not claim a server byte policy")
client:Destroy()
rpcServer:Destroy()

local failureToken = assert(Definition.define({
	name = "OutboundFailureBytesTest",
	version = 1,
	outboundBytes = { capacity = 11, refillPerSecond = 1 },
	events = {
		Native = { id = 1, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
	},
}))
local failureRuntime = ServerRuntime.new()
local departedPlayer = failureRuntime:addPlayer()
local failureServer = assert(failureRuntime.server.create(failureToken, serverOptions()))
assert(failureServer:Start())
failureRuntime.throwFire = true
local handoffOk, handoffError = failureServer.events.Native:Send(departedPlayer, 1)
assert(not handoffOk and handoffError.code == "TransportFailure")
failureRuntime.throwFire = false
local retryOk, retryError = failureServer.events.Native:Send(departedPlayer, 1)
assert(not retryOk and retryError.code == "OutboundRateLimited",
	"uncertain transport failure does not refund reserved bytes")
failureRuntime:removePlayer(departedPlayer)
local arrivedPlayer = failureRuntime:addPlayer()
assert(failureServer.events.Native:Send(arrivedPlayer, 1), "departed player budget state is released")
local failureCounters = failureServer:GetDiagnostics().counters
assert(failureCounters.outboundBytesCharged == 22 and failureCounters.outboundByteRejected == 1)
failureServer:Destroy()

print("PASS Relay.OutboundBytes atomic admission, content charging, queues and RPC settlement")
