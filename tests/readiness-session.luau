local Definition = require("../src/Definition")
local ReadinessFrame = require("../src/internal/ReadinessFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local definition = assert(Definition.define({
	name = "ReadinessSessionProof", version = 1, readiness = true, events = {
		State = { id = 1, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
		Input = { id = 2, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
		Other = { id = 3, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
		UnreliableInput = { id = 4, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
	},
}))
local compiled = Definition.get(definition)
local listenerCount = compiled.readiness.count
local options = {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
}
local clientOptions = { startupTimeoutSeconds = 3 }
local serverGuid = "abcdefab-cdef-4000-8000-000000000001"
local otherGuid = "01234567-89ab-cdef-0123-456789abcdef"

local function serverSetup(def, serverOptions)
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(def or definition, serverOptions or options))
	assert(server:Start())
	return runtime, player, server, runtime:remote(), runtime:unreliableRemote()
end

local function clientSetup(def)
	local runtime = ClientRuntime.create()
	local token = def or definition
	local tokenCompiled = Definition.get(token)
	local _, _, remote = runtime:transport(tokenCompiled.descriptor, tokenCompiled.hasUnreliable)
	local client = assert(runtime.module.create(token, clientOptions))
	return runtime, client, remote
end

local function sendClientFire(runtime, remote, player, index)
	local fire = assert(runtime.fires[index])
	remote.OnServerEvent:Fire(player, table.unpack(fire, 1, fire.n))
end

local function sendServerFire(runtime, remote, index)
	local fire = assert(runtime.fires[index])
	remote.OnClientEvent:fire(table.unpack(fire.values, 1, fire.values.n))
end

local function clientHeader(runtime, index)
	return ReadinessFrame.peek(assert(runtime.fires[index])[2], true, listenerCount)
end

local function serverHeader(runtime, index)
	local fire = assert(runtime.fires[index])
	assert(fire.kind == "target" and fire.values.n == 2 and fire.values[1] == 0)
	return ReadinessFrame.peek(fire.values[2], false, listenerCount)
end

local function assertReady(server, eventName, player, expected)
	local players, problem = server.events[eventName]:GetReadyPlayers()
	assert(problem == nil and players ~= nil)
	assert((table.find(players, player) ~= nil) == expected, `wrong {eventName} readiness`)
	return players
end

local function assertError(expected, value, problem)
	assert((value == nil or value == false) and problem ~= nil and problem.code == expected,
		`expected {expected}, got {if problem then problem.code else "success"}`)
end

local function makeAck(guid, generation, clientGuid, revision, mask)
	return assert(ReadinessFrame.ack(guid, generation, clientGuid, revision, mask, listenerCount))
end

local function acceptAck(runtime, remote, player, guid, generation, clientGuid, revision, mask)
	remote.OnServerEvent:Fire(player, 0, makeAck(guid, generation, clientGuid, revision, mask))
end

-- The initial snapshot, per-event claims, transition revisions, Once detachment, and ready audiences.
do
	local serverRuntime, player, server, serverRemote = serverSetup()
	local clientRuntime, client, clientRemote = clientSetup()
	assert(client.events.State:Connect(function() end))
	local onceCalls, onceClearedRevision, replacementCalls = 0, nil, 0
	local replacement
	assert(client:Start())
	assert(#clientRuntime.fires == 1 and clientRuntime.fires[1][1] == 0)
	assert(ReadinessFrame.peek(clientRuntime.fires[1][2], true, listenerCount).kind == 16)
	sendClientFire(clientRuntime, serverRemote, player, 1)
	assert(#serverRuntime.fires == 1 and serverHeader(serverRuntime, 1).kind == 17)
	sendServerFire(serverRuntime, clientRemote, 1)
	assert(#clientRuntime.fires == 2 and clientHeader(clientRuntime, 2).kind == 18)
	sendClientFire(clientRuntime, serverRemote, player, 2)
	assertReady(server, "State", player, true)
	assertReady(server, "Other", player, false)

	local stateSnapshot = assert(server.events.State:GetReadyPlayers())
	stateSnapshot[1] = nil
	assertReady(server, "State", player, true)
	local ready = assert(server.events.State:GetReadyPlayers())
	local ok, problem, count = server.events.State:SendTo(ready, 37)
	assert(ok and problem == nil and count == 1)
	local broadcasts = serverRuntime.fires[#serverRuntime.fires].kind == "broadcast"
	assert(server.events.State:Broadcast(38) and broadcasts == false,
		"readiness must not change Broadcast into audience fanout")
	assert(serverRuntime.fires[#serverRuntime.fires].kind == "broadcast")

	local otherConnection = assert(client.events.Other:Connect(function() end))
	assert(clientHeader(clientRuntime, #clientRuntime.fires).revision == 2)
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "Other", player, true)
	otherConnection:Disconnect()
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "Other", player, false)

	local onceConnection = assert(client.events.Other:Once(function()
		onceCalls += 1
		local cleared = clientHeader(clientRuntime, #clientRuntime.fires)
		assert(cleared.revision == 5 and string.byte(cleared.maskString, 1) == 1)
		onceClearedRevision = cleared.revision
		replacement = assert(client.events.Other:Connect(function() replacementCalls += 1 end))
	end))
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "Other", player, true)
	local beforeInvalid = #clientRuntime.fires
	clientRemote.OnClientEvent:fire(3, "malformed")
	assert(onceCalls == 0 and #clientRuntime.fires == beforeInvalid,
		"invalid application payload must leave Once readiness armed")
	clientRemote.OnClientEvent:fire(3, 9)
	assert(onceCalls == 1 and onceClearedRevision == 5 and replacement ~= nil)
	local last = #clientRuntime.fires
	sendClientFire(clientRuntime, serverRemote, player, last - 1)
	sendClientFire(clientRuntime, serverRemote, player, last)
	assertReady(server, "Other", player, true)
	clientRemote.OnClientEvent:fire(3, 10)
	assert(replacementCalls == 1 and onceCalls == 1)
	replacement:Disconnect()
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "Other", player, false)

	client:Destroy()
	server:Destroy()
	assert(serverRuntime.connections == 0 and clientRuntime.connections == 0)
	assert(onceConnection ~= nil)
end

-- Fixed framing, invalid channel/arity/size/kind, and player-first shared admission.
do
	local runtime, player, server, remote, unreliable = serverSetup()
	local hello = ReadinessFrame.hello()
	local large = buffer.create(85)
	buffer.writeu8(large, 0, 2)
	buffer.writeu8(large, 1, 16)
	local wrongKind = buffer.create(2)
	buffer.writeu8(wrongKind, 0, 2)
	buffer.writeu8(wrongKind, 1, 15)
	local wrongFormat = buffer.create(2)
	buffer.writeu8(wrongFormat, 0, 3)
	buffer.writeu8(wrongFormat, 1, 16)
	local beforeClock, beforeFires = runtime.clockReads, #runtime.fires
	remote.OnServerEvent:Fire(player, 0, hello, "extra")
	remote.OnServerEvent:Fire(player, 0, {})
	remote.OnServerEvent:Fire(player, 0, large)
	remote.OnServerEvent:Fire(player, 0, wrongKind)
	remote.OnServerEvent:Fire(player, 0, wrongFormat)
	unreliable.OnServerEvent:Fire(player, 0, hello)
	assert(runtime.clockReads == beforeClock + 6 and #runtime.fires == beforeFires)
	local snapshot = server:GetDiagnostics()
	assert(snapshot.counters.invalidPayload == 4 and snapshot.counters.invalidEndpoint == 1
		and snapshot.counters.wrongChannel == 1,
		"eligible malformed and wrong-channel controls must be charged and classified")

	local invalidMask = makeAck(serverGuid, 1, otherGuid, 1, string.char(0))
	buffer.writeu8(invalidMask, 82, 4)
	remote.OnServerEvent:Fire(player, 0, invalidMask)
	assert(#runtime.fires == beforeFires and server:GetDiagnostics().counters.invalidPayload == 5,
		"unused high bits must reject the whole control before readiness state changes")

	local perPlayer = { inboundRate = {
		perPlayer = { capacity = 1, refillPerSecond = 1 },
		aggregate = { capacity = 2, refillPerSecond = 1 },
	} }
	server:Destroy()
	runtime, player, server, remote = serverSetup(definition, perPlayer)
	local second = runtime:addPlayer()
	remote.OnServerEvent:Fire(player, 0, hello)
	remote.OnServerEvent:Fire(player, 0, hello)
	remote.OnServerEvent:Fire(second, 0, hello)
	snapshot = server:GetDiagnostics()
	assert(snapshot.counters.perPlayerRate == 1 and snapshot.counters.aggregateRate == 0
		and #runtime.fires == 2,
		"per-player exhaustion must not spend aggregate capacity; another Player can still offer")
	local reads = runtime.clockReads
	runtime:removePlayer(player)
	remote.OnServerEvent:Fire(player, 0, hello)
	assert(runtime.clockReads == reads, "departed Player controls reject before sampling admission time")
	server:Destroy()
end

-- RPC format 1 and readiness format 2 share one client GUID without sharing parsers.
do
	local mixed = assert(Definition.define({
		name = "MixedReadinessRpcSession", version = 1, readiness = true, events = {
			State = { id = 1, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
			Input = { id = 2, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
			Other = { id = 3, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
			UnreliableInput = { id = 4, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
		}, requests = {
			Echo = { id = 5, request = { { name = "value", type = "u8" } }, response = { type = "boolean" } },
		},
	}))
	local serverRuntime, player, server, serverRemote = serverSetup(mixed)
	local clientRuntime, client, clientRemote = clientSetup(mixed)
	server.requests.Echo:Connect(function(sender, value)
		assert(sender == player and value == 7)
		return false
	end)
	assert(client.events.State:Connect(function() end))
	assert(client:Start() and clientRuntime.guidCalls == 1)
	sendClientFire(clientRuntime, serverRemote, player, 1)
	sendServerFire(serverRuntime, clientRemote, 1)
	local readinessAck = ReadinessFrame.peek(clientRuntime.fires[2][2], true, listenerCount)
	assert(readinessAck and readinessAck.kind == 18)
	sendClientFire(clientRuntime, serverRemote, player, 2)
	local handle = assert(client.requests.Echo:Request(1, 7))
	local request = RpcFrame.peek(clientRuntime.fires[3][2], true)
	assert(request and request.kind == 1 and request.sessionGuid == readinessAck.clientGuid,
		"RPC and readiness must reuse the started client GUID while keeping separate wire formats")
	sendClientFire(clientRuntime, serverRemote, player, 3)
	local response = RpcFrame.peek(serverRuntime.fires[2].values[2], false)
	assert(response and response.kind == 2 and serverRuntime.fires[2].values[1] == 0)
	sendServerFire(serverRuntime, clientRemote, 2)
	local result = handle:Await()
	assert(result.ok and result.value == false)
	assertReady(server, "State", player, true)
	client:Destroy()
	server:Destroy()
end

-- Ready-player snapshots accept exactly the configured roster cap with no partial overflow result.
do
	local runtime = ServerRuntime.new()
	local players = table.create(1_025)
	for index = 1, 1_025 do
		players[index] = runtime:addPlayer()
	end
	local server = assert(runtime.server.create(definition, options))
	assert(server:Start())
	local remote = runtime:remote()
	local readyMask = makeAck(serverGuid, 1, otherGuid, 1, string.char(1))
	for index = 1, 1_024 do
		remote.OnServerEvent:Fire(players[index], 0, ReadinessFrame.hello())
		remote.OnServerEvent:Fire(players[index], 0, readyMask)
	end
	local ready = assert(server.events.State:GetReadyPlayers())
	assert(#ready == 1_024)
	remote.OnServerEvent:Fire(players[1_025], 0, ReadinessFrame.hello())
	remote.OnServerEvent:Fire(players[1_025], 0, readyMask)
	local overflow, problem = server.events.State:GetReadyPlayers()
	assert(overflow == nil and problem.code == "InvalidAudience",
		"ready snapshots return no partial list when the current eligible roster exceeds its cap")
	server:Destroy()
end

-- Ack identity/revision rules, repeated Hello, Close-before-Ack, and Player-object replacement.
do
	local runtime, player, server, remote = serverSetup()
	remote.OnServerEvent:Fire(player, 0, ReadinessFrame.hello())
	local offered = serverHeader(runtime, 1)
	assert(offered.generation == 1)
	acceptAck(runtime, remote, player, otherGuid, 1, otherGuid, 1, string.char(1))
	assertReady(server, "State", player, false)
	acceptAck(runtime, remote, player, serverGuid, 2, otherGuid, 1, string.char(1))
	assertReady(server, "State", player, false)
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 2, string.char(1))
	assertReady(server, "State", player, true)
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 1, string.char(0))
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 2, string.char(0))
	assertReady(server, "State", player, true,
		"lower revision and changed same-revision mask cannot change a bound claim")
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 2, string.char(1))
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 3, string.char(0))
	assertReady(server, "State", player, false)
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 4, string.char(1))
	remote.OnServerEvent:Fire(player, 0, assert(ReadinessFrame.close(serverGuid, 1,
		"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")))
	assertReady(server, "State", player, true, "a different client GUID cannot close a Bound record")
	remote.OnServerEvent:Fire(player, 0, assert(ReadinessFrame.close(serverGuid, 1, otherGuid)))
	assertReady(server, "State", player, false)
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 5, string.char(1))
	assertReady(server, "State", player, false, "a queued Ack cannot reopen a Closed generation")

	remote.OnServerEvent:Fire(player, 0, ReadinessFrame.hello())
	assert(serverHeader(runtime, #runtime.fires).generation == 2)
	acceptAck(runtime, remote, player, serverGuid, 1, otherGuid, 6, string.char(1))
	assertReady(server, "State", player, false, "a prior generation cannot update a replacement offer")
	remote.OnServerEvent:Fire(player, 0, assert(ReadinessFrame.close(serverGuid, 2, otherGuid)))
	assertReady(server, "State", player, false, "Close is allowed before the first Ack in Offered")

	local userId = 77
	player.UserId = userId
	runtime:removePlayer(player)
	local replacement = runtime:addPlayer()
	replacement.UserId = userId
	remote.OnServerEvent:Fire(replacement, 0, ReadinessFrame.hello())
	assert(serverHeader(runtime, #runtime.fires).generation == 1,
		"a new Player object starts its own generation high-water")
	assertReady(server, "State", replacement, false)
	server:Destroy()
end

-- Capacity-one recovery and forced-Hello recovery after a failed newer Challenge.
do
	local serverOptions = { inboundRate = {
		perPlayer = { capacity = 1, refillPerSecond = 1 },
		aggregate = { capacity = 2, refillPerSecond = 1 },
	} }
	local serverRuntime, player, server, serverRemote = serverSetup(definition, serverOptions)
	local clientRuntime, client, clientRemote = clientSetup()
	assert(client.events.State:Connect(function() end))
	assert(client:Start())
	sendClientFire(clientRuntime, serverRemote, player, 1)
	sendServerFire(serverRuntime, clientRemote, 1)
	sendClientFire(clientRuntime, serverRemote, player, 2)
	assert(server:GetDiagnostics().counters.perPlayerRate == 1)
	assertReady(server, "State", player, false,
		"the immediate Ack after a capacity-one Hello may be dropped")

	serverRuntime.now = 1
	local sent, problem = client:RefreshReadiness()
	assert(sent and problem == nil and clientHeader(clientRuntime, 3).kind == 18
		and clientHeader(clientRuntime, 3).generation == 1,
		"default refresh after refill must send the held Ack")
	sendClientFire(clientRuntime, serverRemote, player, 3)
	assertReady(server, "State", player, true)

	serverRuntime.now = 2
	serverRuntime.throwFire = true
	serverRemote.OnServerEvent:Fire(player, 0, ReadinessFrame.hello())
	serverRuntime.throwFire = false
	assert(serverHeader(serverRuntime, #serverRuntime.fires).generation == 1,
		"a failed challenge is not recorded as a completed handoff")
	assert(server:GetDiagnostics().counters.transportFailures == 1)
	serverRuntime.now = 3
	sent, problem = client:RefreshReadiness(false)
	assert(sent and problem == nil and clientHeader(clientRuntime, #clientRuntime.fires).generation == 1)
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "State", player, false, "the old held-generation Ack is rejected")

	serverRuntime.now = 4
	sent, problem = client:RefreshReadiness(true)
	assert(sent and problem == nil and clientHeader(clientRuntime, #clientRuntime.fires).kind == 16)
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assert(serverHeader(serverRuntime, #serverRuntime.fires).generation == 3)
	sendServerFire(serverRuntime, clientRemote, #serverRuntime.fires)
	assert(clientHeader(clientRuntime, #clientRuntime.fires).generation == 3)
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assert(server:GetDiagnostics().counters.perPlayerRate == 2,
		"the immediate recovery Ack may also be dropped with capacity one")
	serverRuntime.now = 5
	sent, problem = client:RefreshReadiness(false)
	assert(sent and problem == nil and clientHeader(clientRuntime, #clientRuntime.fires).kind == 18
		and clientHeader(clientRuntime, #clientRuntime.fires).generation == 3)
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "State", player, true)

	local invalidTraffic = #clientRuntime.fires
	sent, problem = client:RefreshReadiness("force")
	assert(not sent and problem.code == "InvalidOptions" and #clientRuntime.fires == invalidTraffic)
	assert(client:RefreshReadiness())
	local queuedAck = #clientRuntime.fires
	serverRuntime.now = 6
	client:Destroy()
	local closeFire = clientRuntime.fires[#clientRuntime.fires]
	local closeHeader = ReadinessFrame.peek(closeFire[2], true, listenerCount)
	assert(closeFire[1] == 0 and closeHeader and closeHeader.kind == 19)
	sendClientFire(clientRuntime, serverRemote, player, #clientRuntime.fires)
	assertReady(server, "State", player, false)
	serverRuntime.now = 7
	sendClientFire(clientRuntime, serverRemote, player, queuedAck)
	assertReady(server, "State", player, false, "a Close received first prevents a queued Ack reopening the record")
	server:Destroy()
end

-- Server Challenge fire reentrancy cannot roll back Bound, Closed, or a newer generation.
for _, reentry in { "ack", "close", "hello" } do
	local serverRuntime, player, server, serverRemote = serverSetup()
	local clientRuntime, client, clientRemote = clientSetup()
	assert(client.events.State:Connect(function() end))
	assert(client:Start())
	local hello = clientRuntime.fires[1]
	serverRuntime.beforeFire = function(target, endpointId, packet)
		assert(target == player and endpointId == 0)
		serverRuntime.beforeFire = nil
		if reentry == "ack" then
			clientRemote.OnClientEvent:fire(endpointId, packet)
			local ack = clientRuntime.fires[#clientRuntime.fires]
			serverRemote.OnServerEvent:Fire(player, table.unpack(ack, 1, ack.n))
		elseif reentry == "close" then
			local challenge = ReadinessFrame.peek(packet, false, listenerCount)
			serverRemote.OnServerEvent:Fire(player, 0,
				assert(ReadinessFrame.close(challenge.serverGuid, challenge.generation, otherGuid)))
		else
			serverRemote.OnServerEvent:Fire(player, 0, ReadinessFrame.hello())
		end
		serverRuntime.throwFire = true
	end
	serverRemote.OnServerEvent:Fire(player, table.unpack(hello, 1, hello.n))
	serverRuntime.throwFire = false
	if reentry == "ack" then
		assertReady(server, "State", player, true, "a reentrant accepted Ack survives the throwing Challenge call")
	elseif reentry == "close" then
		assertReady(server, "State", player, false, "a reentrant Close survives the throwing Challenge call")
	else
		assert(serverHeader(serverRuntime, #serverRuntime.fires).generation == 2)
		local nestedChallenge = serverRuntime.fires[#serverRuntime.fires]
		clientRemote.OnClientEvent:fire(table.unpack(nestedChallenge.values, 1, nestedChallenge.values.n))
		local ack = clientRuntime.fires[#clientRuntime.fires]
		serverRemote.OnServerEvent:Fire(player, table.unpack(ack, 1, ack.n))
		assertReady(server, "State", player, true,
			"a nested newer Hello cannot be overwritten by the older fire completion")
	end
	assert(server:GetDiagnostics().counters.transportFailures == 1)
	client:Destroy()
	server:Destroy()
end

for _, reentry in { "remove", "destroy" } do
	local serverRuntime, player, server, serverRemote = serverSetup()
	local clientRuntime, client = clientSetup()
	assert(client:Start())
	local hello = clientRuntime.fires[1]
	serverRuntime.beforeFire = function(target)
		serverRuntime.beforeFire = nil
		if reentry == "remove" then
			serverRuntime:removePlayer(target)
		else
			server:Destroy()
		end
		serverRuntime.throwFire = true
	end
	serverRemote.OnServerEvent:Fire(player, table.unpack(hello, 1, hello.n))
	serverRuntime.throwFire = false
	if reentry == "remove" then
		local ready = assert(server.events.State:GetReadyPlayers())
		assert(#ready == 0)
		local reads = serverRuntime.clockReads
		serverRemote.OnServerEvent:Fire(player, 0, ReadinessFrame.hello())
		assert(serverRuntime.clockReads == reads and server:GetDiagnostics().counters.ineligible == 1,
			"a reentrant departure cannot recreate its roster or readiness record")
	else
		assertError("Destroyed", server.events.State:GetReadyPlayers())
	end
	client:Destroy()
	server:Destroy()
end

-- Client forced-Hello reentrancy preserves a newer Challenge; Destroy closes only a held identity.
do
	local runtime, client, remote = clientSetup()
	assert(client.events.State:Connect(function() end))
	assert(client:Start())
	remote.OnClientEvent:fire(0, assert(ReadinessFrame.challenge(serverGuid, 1)))
	assert(clientHeader(runtime, #runtime.fires).kind == 18)
	local newer = assert(ReadinessFrame.challenge(serverGuid, 2))
	local reenter = true
	runtime.failFire = true
	runtime.onFire = function(signal, endpointId, packet)
		if reenter and endpointId == 0 and buffer.readu8(packet, 1) == 16 then
			reenter = false
			signal.OnClientEvent:fire(0, newer)
		end
	end
	local sent, problem = client:RefreshReadiness(true)
	assert(not sent and problem.code == "TransportFailure")
	runtime.failFire = false
	runtime.onFire = nil
	assert(client:RefreshReadiness(false))
	local refreshed = clientHeader(runtime, #runtime.fires)
	assert(refreshed.kind == 18 and refreshed.generation == 2,
		"a reentrant Challenge must not be cleared when forced Hello throws")
	local beforeOldChallenges = #runtime.fires
	remote.OnClientEvent:fire(0, newer)
	remote.OnClientEvent:fire(0, assert(ReadinessFrame.challenge(otherGuid, 9)))
	assert(#runtime.fires == beforeOldChallenges
		and client:GetDiagnostics().counters.invalidEndpoint >= 2,
		"duplicate generations and a different server identity cannot trigger more ACKs")

	local queuedChallenge = assert(ReadinessFrame.challenge(serverGuid, 3))
	local fireCount = #runtime.fires
	client:Destroy()
	local close = runtime.fires[#runtime.fires]
	assert(close[1] == 0 and buffer.readu8(close[2], 1) == 19)
	assert(#runtime.fires == fireCount + 1)
	remote.OnClientEvent:fire(0, queuedChallenge)
	assert(#runtime.fires == fireCount + 1, "terminal callbacks cannot emit late readiness controls")
	assert(client:GetDiagnostics().state == "Destroyed")
end

-- Disabled readiness keeps legacy startup and reports fixed lifecycle errors.
do
	local legacy = assert(Definition.define({ name = "LegacyReadiness", version = 1, events = {
		State = { id = 1, direction = "ServerToClient", fields = {} },
	} }))
	local runtime, _, server = serverSetup(legacy)
	assertError("ReadinessDisabled", server.events.State:GetReadyPlayers())
	server:Destroy()
	assertError("Destroyed", server.events.State:GetReadyPlayers())

	local clientRuntime, client = clientSetup(legacy)
	assertError("NotStarted", client:RefreshReadiness())
	assert(client:Start())
	assertError("ReadinessDisabled", client:RefreshReadiness())
	client:Destroy()
end

-- Initial Hello failures terminate startup; a reentrant terminal transition cannot report Start success.
do
	local runtime, client = clientSetup()
	assert(client.events.State:Connect(function() end))
	runtime.failFire = true
	local started, problem = client:Start()
	assert(not started and problem.code == "TransportFailure"
		and client:GetDiagnostics().state == "Destroyed" and runtime.connections == 0)

	runtime, client = clientSetup()
	assert(client.events.State:Connect(function() end))
	runtime.onFire = function(_, endpointId, packet)
		if endpointId == 0 and buffer.readu8(packet, 1) == 16 then
			client:Destroy()
		end
	end
	started, problem = client:Start()
	assert(not started and problem.code == "Destroyed"
		and client:GetDiagnostics().state == "Destroyed" and runtime.connections == 0)
end

print("PASS Relay.ReadinessSession")
