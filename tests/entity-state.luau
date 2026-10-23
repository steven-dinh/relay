local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Relay = require("../src")
local Kit = require("../scripts/consumer-testing/Kit")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local function helpers()
	local typesMarker = {}
	local environment = {
		script = { Parent = { Types = typesMarker } },
		require = function(module)
			assert(module == typesMarker)
			return {}
		end,
	}
	local server = luau.load(fs.readFile("examples/entity-state/Server.luau"), {
		debugName = "EntityStateServer", injectGlobals = true, environment = environment,
	})()
	local client = luau.load(fs.readFile("examples/entity-state/Client.luau"), {
		debugName = "EntityStateClient", injectGlobals = true, environment = environment,
	})()
	return server, client
end

local Server, Client = helpers()

-- Server ownership, bounds, denial privacy, revisions, deletion, and re-entry.
do
	local members: { [Player]: boolean } = {}
	local updates: { any } = {}
	local manager = Server.new(function(player) return members[player] == true end, function(player, update)
		table.insert(updates, { player, update })
	end)
	local permitted, outsider = {}, {}
	members[permitted] = true

	local denied = manager:Snapshot(outsider, 0)
	assert(denied.status == "Denied" and denied.epoch == 0 and denied.revision == 0 and #denied.entities == 0)
	assert(not manager:SetViewer(outsider, true), "a client cannot select its own membership")
	assert(manager:Snapshot(outsider, 0).entities == denied.entities, "unknown callers use the constant empty denial")

	for _, health in { -1, 1_001, 1.5, math.huge, "100" } do
		local id, problem = manager:CreateEntity(health :: any)
		assert(id == nil and problem == "InvalidHealth", "invalid health is rejected before state changes")
	end
	local nilId, nilProblem = manager:CreateEntity(nil :: any)
	assert(nilId == nil and nilProblem == "InvalidHealth")

	local ids = {}
	for index = 1, 32 do
		local id = assert(manager:CreateEntity(index))
		ids[index] = id
	end
	local overflow, overflowProblem = manager:CreateEntity(10)
	assert(overflow == nil and overflowProblem == "EntityLimit")
	assert(not manager:SetHealth("1" :: any, 20) and not manager:SetHealth(1, "20" :: any))
	assert(not manager:SetHealth(1, 1_001) and not manager:SetHealth(65_536, 20))

	assert(manager:SetViewer(permitted, true))
	local reset = updates[#updates][2]
	assert(reset.kind == "Reset" and reset.id == 0 and reset.health == 0 and reset.epoch > 0)
	local baseline = manager:Snapshot(permitted, 1)
	assert(baseline.status == "Ready" and #baseline.entities == 32 and baseline.revision == 32)
	assert(baseline.entities[1].id == 1 and baseline.entities[32].id == 32)
	local busy = manager:Snapshot(permitted, 1.5)
	assert(busy.status == "Busy" and busy.epoch == 0 and busy.revision == 0 and #busy.entities == 0,
		"the application gate refuses before cloning and discloses no collection metadata")
	assert(manager:Snapshot(outsider, 1.5).status == "Denied")

	local eventCount = #updates
	assert(manager:SetHealth(1, 1), "an unchanged absolute value is accepted")
	assert(#updates == eventCount, "unchanged state does not create a revision or send")
	assert(manager:DeleteEntity(1))
	local deletion = updates[#updates][2]
	assert(deletion.kind == "Delete" and deletion.revision == baseline.revision + 1 and deletion.health == 0)
	local replacement = assert(manager:CreateEntity(50))
	assert(replacement == 33, "deleted entity IDs are never reused")
	assert(not manager:DeleteEntity(1), "deletion is explicit and idempotence is reported")

	assert(manager:SetViewer(permitted, false))
	local closed = updates[#updates][2]
	assert(closed.kind == "Closed" and closed.epoch > reset.epoch)
	assert(manager:Snapshot(permitted, 4).status == "Denied")
	assert(manager:SetViewer(permitted, true))
	local reentry = updates[#updates][2]
	assert(reentry.kind == "Reset" and reentry.epoch > closed.epoch)
	assert(manager:Snapshot(permitted, 4).status == "Ready", "membership re-entry gets a new bounded baseline")

	local departing = permitted
	manager:RemovePlayer(departing)
	members[departing] = nil
	assert(manager:Snapshot(departing, 7).status == "Denied", "PlayerRemoving releases viewer access")
	manager:Destroy()
	manager:Destroy()
	assert(not manager:SetViewer(departing, true) and manager:Snapshot(departing, 9).status == "Busy")
end

-- Client epoch ownership, race-safe recovery, absolute deletes, deadlines, and cleanup.
do
	local client = Client.new()
	local cancelled = 0
	local oldToken = assert(client:Begin(0, function() cancelled += 1 end))
	assert(client:Receive({ epoch = 1, revision = 1, kind = "Reset", id = 0, health = 0 }, 0),
		"entry reset requests a baseline")
	assert(cancelled == 1 and not client:Complete(oldToken,
		{ status = "Ready", epoch = 1, revision = 1, entities = { { id = 1, health = 100 } } }, 0.1),
		"a new epoch cancels and invalidates the baseline already in flight")

	local baselineToken = assert(client:Begin(2, function() end))
	assert(client:Receive({ epoch = 1, revision = 2, kind = "Put", id = 1, health = 90 }, 2.1))
	assert(client:Complete(baselineToken,
		{ status = "Ready", epoch = 1, revision = 1, entities = { { id = 1, health = 100 } } }, 2.2))
	local snapshot = client:GetSnapshot()
	assert(snapshot.ready and snapshot.revision == 2 and snapshot.entities[1] == 90,
		"an update received during bootstrap wins over the older baseline")

	local refresh = assert(client:Begin(4.1, function() end))
	assert(not client:Receive({ epoch = 1, revision = 3, kind = "Put", id = 1, health = 70 }, 4.2))
	assert(client:Complete(refresh,
		{ status = "Ready", epoch = 1, revision = 2, entities = { { id = 1, health = 90 } } }, 4.3))
	assert(client:GetSnapshot().entities[1] == 70 and client:GetSnapshot().revision == 3,
		"a response behind live state preserves the newer state")

	local oldEpochRequest = assert(client:Begin(6.2, function() end))
	assert(client:Receive({ epoch = 2, revision = 3, kind = "Reset", id = 0, health = 0 }, 6.3))
	assert(not client:Complete(oldEpochRequest,
		{ status = "Ready", epoch = 1, revision = 3, entities = { { id = 1, health = 70 } } }, 6.4))
	assert(not client:GetSnapshot().ready and client:GetSnapshot().epoch == 2,
		"an old epoch cannot revive state after re-entry")
	assert(not client:Receive({ epoch = 1, revision = 4, kind = "Put", id = 1, health = 1 }, 6.5),
		"updates from a removed epoch are ignored")

	local deleteBaseline = assert(client:Begin(8.3, function() end))
	assert(client:Receive({ epoch = 2, revision = 4, kind = "Delete", id = 1, health = 0 }, 8.4))
	assert(client:Complete(deleteBaseline,
		{ status = "Ready", epoch = 2, revision = 3, entities = { { id = 1, health = 70 } } }, 8.5))
	assert(client:GetSnapshot().ready and client:GetSnapshot().revision == 4
		and client:GetSnapshot().entities[1] == nil, "a buffered absolute delete applies after its baseline")

	local gap = Client.new()
	local gapToken = assert(gap:Begin(0, function() end))
	gap:Receive({ epoch = 4, revision = 0, kind = "Reset", id = 0, health = 0 }, 0)
	local recoveryToken = assert(gap:Begin(2, function() end))
	gap:Receive({ epoch = 4, revision = 2, kind = "Put", id = 2, health = 2 }, 2.1)
	assert(not gap:Complete(recoveryToken,
		{ status = "Ready", epoch = 4, revision = 0, entities = {} }, 2.2),
		"a baseline cannot install through a missing revision")
	assert(not gap:GetSnapshot().ready and gap:NeedsSnapshot())
	assert(not gap:Complete(gapToken, { status = "Ready", epoch = 4, revision = 0, entities = {} }, 2.3))

	local overflow = Client.new()
	local token = assert(overflow:Begin(0, function() end))
	overflow:Receive({ epoch = 5, revision = 0, kind = "Reset", id = 0, health = 0 }, 0)
	local bufferedToken = assert(overflow:Begin(2, function() cancelled += 1 end))
	for revision = 1, 65 do
		overflow:Receive({ epoch = 5, revision = revision, kind = "Put", id = revision, health = 5 }, 2.1)
	end
	assert(not overflow:Complete(bufferedToken,
		{ status = "Ready", epoch = 5, revision = 0, entities = {} }, 2.2)
		and not overflow:GetSnapshot().ready and overflow:NeedsSnapshot(),
		"buffer overflow invalidates the old baseline and remains bounded")
	assert(not overflow:Complete(token, { status = "Ready", epoch = 5, revision = 0, entities = {} }, 2.3))

	local freshness = Client.new()
	local freshToken = assert(freshness:Begin(0, function() end))
	assert(freshness:Complete(freshToken,
		{ status = "Ready", epoch = 6, revision = 1, entities = { { id = 1, health = 1 } } }, 0.1))
	freshness:Tick(5.1)
	assert(not freshness:GetSnapshot().ready and freshness:GetSnapshot().entities[1] == nil
		and freshness:NeedsSnapshot(), "state expires five seconds after a complete baseline")

	local denied = Client.new()
	local deniedToken = assert(denied:Begin(0, function() end))
	assert(denied:Complete(deniedToken, { status = "Denied", epoch = 0, revision = 0, entities = {} }, 0.1))
	assert(not denied:NeedsSnapshot() and not denied:GetSnapshot().ready)
	assert(denied:CanBegin(2), "denied clients keep a bounded poll path for lost re-entry events")
	local reentryToken = assert(denied:Begin(2, function() end))
	assert(denied:Complete(reentryToken,
		{ status = "Ready", epoch = 7, revision = 2, entities = { { id = 2, health = 20 } } }, 2.1))
	assert(denied:GetSnapshot().ready and denied:GetSnapshot().epoch == 7,
		"a newer baseline can recover re-entry when its Reset event was lost")
	assert(denied:Receive({ epoch = 7, revision = 2, kind = "Reset", id = 0, health = 0 }, 1)
		== false and denied:GetSnapshot().ready, "same-epoch reset is idempotent after recovery")
	assert(not denied:Receive({ epoch = 7, revision = 2, kind = "Reset", id = 0, health = 0 }, 2.2),
		"same-epoch reset is idempotent")
	local closed = Client.new()
	local closedRequest = assert(closed:Begin(0, function() end))
	assert(not closed:Receive({ epoch = 8, revision = 4, kind = "Closed", id = 0, health = 0 }, 0))
	assert(not closed:Complete(closedRequest,
		{ status = "Ready", epoch = 8, revision = 4, entities = {} }, 0.1))
	assert(closed:CanBegin(2), "closed clients continue polling for a lost Reset")
	local missedResetToken = assert(closed:Begin(2, function() end))
	assert(closed:Complete(missedResetToken,
		{ status = "Ready", epoch = 9, revision = 4, entities = {} }, 2.1)
		and closed:GetSnapshot().ready, "a newer baseline reopens after a lost audience Reset")
	closed:Destroy()

	local full = Client.new()
	local fullRows = {}
	for id = 1, 32 do fullRows[id] = { id = id, health = id } end
	local fullToken = assert(full:Begin(0, function() end))
	assert(full:Complete(fullToken, { status = "Ready", epoch = 10, revision = 32, entities = fullRows }, 0.1))
	assert(full:Receive({ epoch = 10, revision = 33, kind = "Put", id = 33, health = 33 }, 1)
		and not full:GetSnapshot().ready and next(full:GetSnapshot().entities) == nil,
		"a live update cannot exceed the 32-row install bound")
	local capRecovery = assert(full:Begin(2, function() end))
	assert(not full:Complete(capRecovery,
		{ status = "Ready", epoch = 10, revision = 32, entities = fullRows }, 2.1)
		and not full:GetSnapshot().ready, "buffer replay cannot install a 33-row candidate")
	full:Destroy()

	local malformedLive = Client.new()
	local malformedBaseline = assert(malformedLive:Begin(0, function() end))
	assert(malformedLive:Complete(malformedBaseline,
		{ status = "Ready", epoch = 11, revision = 1, entities = { { id = 1, health = 100 } } }, 0.1))
	assert(malformedLive:Receive({ epoch = 11, revision = 2, kind = "Unexpected", id = 1, health = 1 } :: any, 1)
		and not malformedLive:GetSnapshot().ready and next(malformedLive:GetSnapshot().entities) == nil,
		"invalid event data clears a previously ready view")
	local malformedRefresh = assert(malformedLive:Begin(2, function() end))
	assert(not malformedLive:Complete(malformedRefresh,
		{ status = "Ready", epoch = 11, revision = 2, entities = { { id = 1, health = 1_001 } } } :: any, 2.1)
		and not malformedLive:GetSnapshot().ready,
		"invalid baseline data clears a previously ready view")
	malformedLive:Destroy()

	for _, invalid in {
		{ status = "Ready", epoch = 1, revision = 1, entities = { { id = 1, health = 1 }, [3] = { id = 2, health = 2 } } },
		{ status = "Ready", epoch = 1, revision = 1, entities = { { id = 1, health = 1 }, { id = 1, health = 2 } } },
		{ status = "Ready", epoch = 1, revision = 1, entities = { { id = 1, health = 1_001 } } },
		{ status = "Denied", epoch = 1, revision = 0, entities = {} },
		{ status = "Busy", epoch = 0, revision = 0, entities = { { id = 1, health = 1 } } },
	} do
		local guarded = Client.new()
		local invalidToken = assert(guarded:Begin(0, function() end))
		assert(not guarded:Complete(invalidToken, invalid :: any, 0.1) and not guarded:GetSnapshot().ready,
			"malformed or privacy-leaking snapshots are rejected")
		guarded:Destroy()
	end

	local timeout = Client.new()
	local timeoutCancelled = 0
	local timeoutToken = assert(timeout:Begin(0, function() timeoutCancelled += 1 end))
	timeout:Tick(5)
	assert(timeoutCancelled == 1 and not timeout:Complete(timeoutToken,
		{ status = "Ready", epoch = 1, revision = 1, entities = {} }, 5.1), "pending snapshots expire")
	timeout:Destroy()

	local cleanup = Client.new()
	local cleanupCancelled = 0
	cleanup:Begin(0, function() cleanupCancelled += 1 end)
	cleanup:Destroy()
	cleanup:Destroy()
	assert(cleanupCancelled == 1 and not cleanup:CanBegin(10) and not cleanup:GetSnapshot().ready,
		"Destroy cancels pending work and clears client references")
end

local relayMarker = {}
local storage = {}
function storage:WaitForChild(_name) return relayMarker end
local definition = luau.load(fs.readFile("examples/entity-state/Definition.luau"), {
	debugName = "EntityStateDefinition",
	injectGlobals = true,
	environment = {
		game = { GetService = function(_, _name) return storage end },
		require = function(module) assert(module == relayMarker); return Relay end,
	},
})()
local inspected = assert(Relay.inspect(definition))
assert(inspected.events.Update.bytes.maximum == 16
	and inspected.requests.Snapshot.response.bytes.maximum == 142
	and inspected.requests.Snapshot.response.bytes.maximum + 44 == 186,
	"the 16-byte event and 186-byte RPC response including its 44-byte envelope remain within reviewed bounds")

-- A real public RPC from a departed sender is rejected before the helper handler.
do
	local serverRuntime = ServerRuntime.new()
	local player = serverRuntime:addPlayer()
	local departed = serverRuntime:addPlayer()
	serverRuntime:removePlayer(departed)
	local server = assert(serverRuntime.server.create(definition, { inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 64, refillPerSecond = 32 },
		endpoints = { [2] = { capacity = 1, refillPerSecond = 0.5 } },
	} }))
	local handlerCalls = 0
	local helper = Server.new(function(candidate) return candidate.Parent == serverRuntime.players end, function() end)
	assert(server.requests.Snapshot:Connect(function(sender)
		handlerCalls += 1
		return helper:Snapshot(sender, serverRuntime.now)
	end))
	assert(server:Start())
	local descriptor: string? = nil
	for _, root in serverRuntime.storage:GetChildren() do
		for _, child in root:GetChildren() do
			if child.Name == "Definition" then descriptor = child.Value end
		end
	end
	assert(descriptor ~= nil)
	local clientRuntime = ClientRuntime.create()
	local clientRoot, _, clientRemote = clientRuntime:transport(descriptor, false)
	local client = assert(clientRuntime.module.create(definition, { startupTimeoutSeconds = 3 }))
	assert(client:Start())
	local serverRemote = assert(serverRuntime:remote())
	local function pump(caller: Player?)
		local delivered = 0
		repeat
			local clientFires = table.clone(clientRuntime.fires)
			table.clear(clientRuntime.fires)
			for _, fire in clientFires do
				serverRemote.OnServerEvent:Fire(caller or player, table.unpack(fire, 1, fire.n))
				delivered += 1
			end
			local serverFires = table.clone(serverRuntime.fires)
			table.clear(serverRuntime.fires)
			for _, fire in serverFires do
				if fire.kind == "broadcast" or fire.player == player then
					clientRemote.OnClientEvent:fire(table.unpack(fire.values, 1, fire.values.n))
				end
				delivered += 1
			end
		until #clientRuntime.fires + #serverRuntime.fires == 0
		return delivered
	end
	assert(pump(nil) >= 0)

	local untracked = assert(client.requests.Snapshot:Request(5))
	local requestFires = table.clone(clientRuntime.fires)
	table.clear(clientRuntime.fires)
	assert(#requestFires == 1)
	for _, fire in requestFires do
		serverRemote.OnServerEvent:Fire(departed, table.unpack(fire, 1, fire.n))
	end
	assert(handlerCalls == 0 and server:GetDiagnostics().counters.ineligible == 1,
		"Relay rejects a departed sender before allocating helper membership or calling the handler")
	untracked:Cancel()
	local denied = assert(client.requests.Snapshot:Request(5))
	assert(pump(nil) > 0)
	local deniedResult = denied:Await()
	assert(deniedResult.ok and deniedResult.value.status == "Denied" and deniedResult.value.epoch == 0
		and deniedResult.value.revision == 0 and #deniedResult.value.entities == 0 and handlerCalls == 1,
		"the current but unauthorized caller receives the privacy-preserving empty denial")
	client:Destroy()
	helper:Destroy()
	server:Destroy()
	clientRemote:Destroy()
	clientRoot:Destroy()
end

-- The public Relay RPC and event paths exercise the baseline/update handoff race.
do
	local clientState = Client.new()
	local appNow = 0
	local mutateAfterSnapshot = true
	local snapshotCalls = 0
	local manager
	Kit.withFixture(definition, function(test)
		manager = Server.new(function(player) return player == test.player and player.Parent ~= nil end,
			function(player, update)
				assert(test.server.events.Update:Send(player, update))
			end)
		for index = 1, 8 do assert(manager:CreateEntity(1_000 - index * 25)) end
		assert(test.client.events.Update:Connect(function(update)
			clientState:Receive(update, appNow)
		end))
		assert(test.server.requests.Snapshot:Connect(function(player)
			snapshotCalls += 1
			local snapshot = manager:Snapshot(player, appNow)
			if mutateAfterSnapshot and snapshot.status == "Ready" then
				mutateAfterSnapshot = false
				assert(manager:SetHealth(1, 333))
			end
			return snapshot
		end))
		assert(test:Start())
		test:Pump()
		local extra, extraError = test.client.requests.Snapshot:Request(5, "extra" :: any)
		assert(extra == nil and extraError ~= nil and extraError.code == "InvalidPayload",
			"the public RPC rejects extra request arguments before handler dispatch")
		local deniedPending = assert(test.client.requests.Snapshot:Request(5))
		assert(test:Pump() > 0)
		local deniedResult = deniedPending:Await()
		assert(deniedResult.ok and deniedResult.value.status == "Denied"
			and deniedResult.value.epoch == 0 and deniedResult.value.revision == 0
			and #deniedResult.value.entities == 0,
			"an unauthorized public RPC caller receives only the constant empty denial")
		assert(snapshotCalls == 1)
		local endpointRefusal = assert(test.client.requests.Snapshot:Request(5))
		assert(test:Pump() > 0 and snapshotCalls == 1
			and test.server:GetDiagnostics().counters.endpointRate == 1,
			"the endpoint burst-one token remains charged until its two-second refill")
		endpointRefusal:Cancel()
		test:Advance(2.1)
		appNow = 2.1
		assert(manager:SetViewer(test.player, true) and test:Pump() > 0)

		local function requestSnapshot()
			if not clientState:CanBegin(appNow) then return nil, nil end
			local cancelPending: (() -> ())? = nil
			local token = assert(clientState:Begin(appNow, function()
				local cancel = cancelPending
				cancelPending = nil
				if cancel ~= nil then cancel() end
			end))
			local pending = assert(test.client.requests.Snapshot:Request(5))
			cancelPending = function() pending:Cancel() end
			return token, pending
		end

		local token, pending = requestSnapshot()
		assert(token ~= nil and pending ~= nil and test:Pump() > 0)
		local result = pending:Await()
		assert(result.ok and clientState:Complete(token, result.value, appNow + 0.1))
		local state = clientState:GetSnapshot()
		assert(state.ready and state.revision == 9 and state.entities[1] == 333,
			"an event delivered before the older RPC baseline is applied after its watermark")
		assert(snapshotCalls == 2)

		test:Advance(2.1)
		appNow = 4.2
		local revokeToken, revokePending = requestSnapshot()
		assert(revokeToken ~= nil and revokePending ~= nil)
		assert(manager:SetViewer(test.player, false))
		assert(test:Pump() > 0)
		local cancelled = revokePending:Await()
		assert(not cancelled.ok and cancelled.error.code == "Cancelled" and not clientState:GetSnapshot().ready,
			"revocation cancels a pending response before it can restore the old audience")
		assert(not clientState:Complete(revokeToken, result.value, appNow + 0.1))

		test:Advance(2.1)
		appNow = 6.3
		assert(manager:SetViewer(test.player, true) and test:Pump() > 0)
		local reentryToken, reentryPending = requestSnapshot()
		assert(reentryToken ~= nil and reentryPending ~= nil and test:Pump() > 0)
		local reentryResult = reentryPending:Await()
		assert(reentryResult.ok and clientState:Complete(reentryToken, reentryResult.value, appNow + 0.1))
		assert(clientState:GetSnapshot().ready and clientState:GetSnapshot().entities[1] == 333,
			"re-entry receives the current authoritative collection")
		assert(snapshotCalls == 4,
			"denied snapshot calls reach the application gate; the cancelled handoff cannot restore access")
		manager:Destroy()
	end, { server = { inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 64, refillPerSecond = 32 },
		endpoints = { [2] = { capacity = 1, refillPerSecond = 0.5 } },
	} } })
	clientState:Destroy()
end

print("Entity state companion: bounds, authorization, epochs, races, recovery, expiry, and cleanup passed")
