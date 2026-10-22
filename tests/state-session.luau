local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local ServerRuntime = require("./support/ServerRuntime")
local ClientRuntime = require("./support/ClientRuntime")
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		require = function(path) assert(path == "./CompositeCodec"); return CompositeCodec end,
	},
	injectGlobals = true,
})()

local definition = assert(Definition.define({
	name = "StateSessionProof", version = 1,
	events = {
		StateInput = { id = 1, direction = "ClientToServer", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		StateToggle = { id = 2, direction = "ClientToServer", queue = "State",
			fields = { { name = "value", type = "boolean" } } },
		StateArray = { id = 3, direction = "ClientToServer", queue = "State",
			fields = { { name = "values", type = "array", maximumLength = 2,
				element = { type = "u8" } } } },
		BatchInput = { id = 4, direction = "ClientToServer", queue = "Batch", fields = {} },
		StateBlob = { id = 5, direction = "ClientToServer", queue = "State",
			fields = { { name = "value", type = "string", maximumBytes = 1_024 } } },
		StatePush = { id = 6, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		ImmediateInput = { id = 7, direction = "ClientToServer",
			fields = { { name = "value", type = "u8" } } },
		BatchPush = { id = 8, direction = "ServerToClient", queue = "Batch", fields = {} },
		StateBlobPush = { id = 9, direction = "ServerToClient", queue = "State",
			fields = { { name = "value", type = "string", maximumBytes = 1_024 } } },
		StateTogglePush = { id = 10, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
			fields = { { name = "value", type = "boolean" } } },
		StateArrayPush = { id = 11, direction = "ServerToClient", queue = "State",
			fields = { { name = "values", type = "array", maximumLength = 2,
				element = { type = "u8" } } } },
	},
}))
local compiled = assert(Definition.get(definition))
local options = {
	inboundRate = {
		perPlayer = { capacity = 4_096, refillPerSecond = 1 },
		aggregate = { capacity = 32_768, refillPerSecond = 1 },
	},
}

local function assertCode(expected, value, problem)
	assert((value == nil or value == false) and problem ~= nil and problem.code == expected,
		`expected {expected}, got {if problem then problem.code else "success"}`)
end

local function body(name, ...)
	local event = compiled.events[name]
	local queued = compiled.queuedById[event.id]
	local encoded = table.pack(Frame.compile(queued, "encode")(...))
	assert(encoded[1] == true)
	return encoded[2]
end

local function envelope(kind, bodies, delivery)
	return assert(BatchFrame.wrap(kind, bodies, if delivery == "Unreliable" then 900 else 8_192))
end

local function assertFreshArrayDeliveries(connect, deliveries)
	local received, previous, calls = nil, nil, 0
	local connection = assert(connect(function(values)
		calls += 1
		received = values
	end))
	for _, deliver in deliveries do
		local before = calls
		received = nil
		deliver()
		assert(calls == before + 1 and received ~= nil, "each composite delivery reaches its handler")
		assert(received[1] == 7 and received[2] == 8)
		if previous ~= nil then assert(received ~= previous) end
		previous = received
		received[1] = 99
	end
	connection:Disconnect()
end

local function assertArrayPayload(name, encoded)
	local valid, values = Frame.compile(compiled.events[name], "decode")(encoded)
	assert(valid == true and values[1] == 7 and values[2] == 8)
end

local function serverSetup(serverOptions)
	local runtime = ServerRuntime.new()
	local first, second, third = runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
	local server = assert(runtime.server.create(definition, serverOptions or options))
	local started, problem = server:Start()
	assert(started, problem and problem.code)
	return runtime, server, first, second, third, runtime:remote(), runtime:unreliableRemote()
end

local function clientSetup()
	local runtime = ClientRuntime.create()
	local _, _, remote, unreliable = runtime:transport(compiled.descriptor, true)
	local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
	assert(client:Start())
	return runtime, client, remote, unreliable
end

-- State creation has the same bounded lifecycle, deadline and owned audience contract as batches.
do
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local unstarted = assert(runtime.server.create(definition, options))
	assertCode("NotStarted", unstarted:CreateState({ player }, 0.02))
	assertCode("NotStarted", unstarted:CreateBroadcastState(0.02))
	unstarted:Destroy()

	local runtime2, server, first, second, third = serverSetup()
	assertCode("InvalidOptions", server:CreateState({ first }, 0))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.101))
	assertCode("InvalidAudience", server:CreateState({ [1] = first, [3] = second }, 0.02))
	assertCode("InvalidOptions", server:CreateBroadcastState(0))
	local batch = assert(server:CreateBatch({ first }, 0.02))
	local lanes = {}
	for index = 1, 4 do
		lanes[index] = assert(server:CreateState({ first }, 0.02))
		assert(lanes[index].events.StatePush ~= nil and lanes[index].events.BatchPush == nil
			and lanes[index].events.StateInput == nil)
	end
	assertCode("QueueLimit", server:CreateState({ first }, 0.02))
	assertCode("QueueLimit", server:CreateBroadcastState(0.02))
	assert(batch.events.StatePush ~= nil and batch.events.BatchPush ~= nil
		and batch.events.StateInput == nil)
	assert(batch.events.BatchPush:Send())
	for index, lane in lanes do assert(lane.events.StatePush:Put(index, "Normal", index)) end
	assert(runtime2:activeTimers() == 5, "one FIFO timer and one timer per state lane")
	lanes[4]:Destroy()
	local audience = { first, second, second, third }
	local state = assert(server:CreateState(audience, 0.02))
	audience[1] = {}
	runtime2:removePlayer(second)
	assert(state.events.StatePush:Put(0, "High", 7))
	local ok, problem, report = state:Flush()
	assert(ok and problem == nil and report.unreliableHandoffs == 2
		and report.logicalHandoffs == 2 and #runtime2.fires == 2)
	for _, fire in runtime2.fires do assert(fire.player == first or fire.player == third) end
	server:Destroy()
end

-- Shared State resolves a fresh roster for each nonempty flush and uses one native call per channel.
do
	local runtime, server, first, second, third = serverSetup()
	local state = assert(server:CreateBroadcastState(0.02))
	assert(state.events.StatePush ~= nil and state.events.StateBlobPush ~= nil
		and state.events.StateInput == nil and state.events.BatchPush == nil)
	assert(state.events.StateBlobPush:Put(1, "High", "reliable"))
	assert(state.events.StatePush:Put(2, "Normal", 9))
	runtime:removePlayer(first)
	local joined = runtime:addPlayer()
	local actualRoster
	runtime.snapshotHook = function(snapshot) actualRoster = table.clone(snapshot) end
	local ok, problem, report = state:Flush()
	runtime.snapshotHook = nil
	assert(ok and problem == nil and report.selected == 2 and report.reliableHandoffs == 1
		and report.unreliableHandoffs == 1 and report.logicalHandoffs == 2 and #runtime.fires == 2)
	assert(actualRoster ~= nil and #actualRoster == 3 and not table.find(actualRoster, first)
		and table.find(actualRoster, second) and table.find(actualRoster, third) and table.find(actualRoster, joined),
		"shared State includes current joins and excludes departed players")
	for index, delivery in { "Reliable", "Unreliable" } do
		local fire = runtime.fires[index]
		local packet = fire.values[2]
		local header = assert(BatchFrame.header(packet, if delivery == "Unreliable" then 900 else 8_192))
		assert(fire.kind == "broadcast" and fire.remote.Name == delivery and fire.values[1] == 0
			and header.kind == 2 and header.count == 1,
			"one endpoint-zero kind-2 broadcast is sent per populated channel in reliable-first order")
	end
	local counters = server:GetDiagnostics().counters
	assert(counters.broadcastHandoffs == 2 and counters.sendHandoffs == 0)
	local snapshotCalls = 0
	runtime.snapshotHook = function() snapshotCalls += 1 end
	local emptyOk, _, emptyReport = state:Flush()
	runtime.snapshotHook = nil
	assert(emptyOk and emptyReport.selected == 0 and snapshotCalls == 0 and #runtime.fires == 2,
		"empty shared State flush skips roster lookup and native handoff")
	for _, player in { second, third, joined } do runtime:removePlayer(player) end
	assert(state.events.StatePush:Put(3, "Normal", 10))
	local noPlayersOk, _, noPlayersReport = state:Flush()
	assert(noPlayersOk and noPlayersReport.selected == 1 and noPlayersReport.unreliableHandoffs == 1
		and noPlayersReport.logicalHandoffs == 1 and #runtime.fires == 3
		and runtime.fires[3].kind == "broadcast",
		"a nonempty shared State flush keeps FireAllClients semantics when the roster is empty")
	server:Destroy()
end

-- Invalid current rosters and GetPlayers errors retain pending snapshots for explicit retry.
do
	for _, invalid in { "sparse", "stale", "duplicate", "throw" } do
		local runtime, server, first, second = serverSetup()
		local state = assert(server:CreateBroadcastState(0.02))
		assert(state.events.StatePush:Put(1, "Normal", 7))
		runtime.snapshotHook = function(snapshot)
			if invalid == "sparse" then
				snapshot[1] = nil
			elseif invalid == "stale" then
				runtime:removePlayer(second)
				snapshot[2] = second
			elseif invalid == "duplicate" then
				snapshot[2] = snapshot[1]
			else
				error("GetPlayers failure")
			end
		end
		local before = #runtime.fires
		local ok, problem, report = state:Flush()
		local pending = state:GetStatus()
		assert(not ok and problem.code == "InvalidAudience" and report.selected == 0
			and report.remaining == 1 and pending.pendingKeys == 1 and runtime:activeTimers() == 1
			and #runtime.fires == before, `invalid {invalid} roster is refused without consuming State`)
		runtime.snapshotHook = nil
		runtime:advance(0.1)
		assert(state:GetStatus().pendingKeys == 1 and #runtime.fires == before,
			"audience refusal schedules expiry cleanup, not an automatic retry")
		assert(state:Flush() and #runtime.fires == before + 1, "explicit retry sends the retained value")
		server:Destroy()
	end

	local runtime, server = serverSetup()
	local unowned = runtime.newInstance("Player")
	unowned.Parent = runtime.players
	local state = assert(server:CreateBroadcastState(0.02))
	assert(state.events.StatePush:Put(1, "Normal", 7))
	local refused, problem, report = state:Flush()
	assert(not refused and problem.code == "InvalidAudience" and report.selected == 0
		and report.remaining == 1 and state:GetStatus().pendingKeys == 1,
		"a current Player without an active session roster owner is refused")
	unowned.Parent = nil
	assert(state:Flush(), "removing an unowned Player allows an explicit retry")
	server:Destroy()
end

-- Teardown during GetPlayers keeps lifecycle errors and clears pending references and the shared guard.
do
	local runtime, server = serverSetup()
	local state = assert(server:CreateBroadcastState(0.02))
	assert(state.events.StatePush:Put(1, "High", 7))
	runtime.snapshotHook = function() server:Destroy() end
	local called, ok, problem, report = pcall(function() return state:Flush() end)
	local status = state:GetStatus()
	assert(called and not ok and problem.code == "Destroyed" and report.selected == 0
		and status.state == "Destroyed" and status.pendingKeys == 0 and runtime:activeTimers() == 0
		and #runtime.fires == 0, "session teardown during roster resolution wins over admission and cleanup")

	local runtime2, server2 = serverSetup()
	local state2 = assert(server2:CreateBroadcastState(0.02))
	assert(state2.events.StatePush:Put(1, "High", 8))
	runtime2.snapshotHook = function() state2:Destroy() end
	local laneCalled, laneOk, laneProblem, laneReport = pcall(function() return state2:Flush() end)
	assert(laneCalled and not laneOk and laneProblem.code == "QueueClosed" and laneReport.selected == 0
		and state2:GetStatus().state == "Destroyed" and state2:GetStatus().pendingKeys == 0
		and runtime2:activeTimers() == 0 and #runtime2.fires == 0,
		"lane teardown during roster resolution cannot be overwritten by a later result")
	server2:Destroy()
end

-- Both selected channels are consumed before transport; a later channel failure does not replay either.
do
	local runtime, server = serverSetup()
	local state = assert(server:CreateBroadcastState(0.02))
	assert(state.events.StateBlobPush:Put(1, "High", "reliable"))
	assert(state.events.StatePush:Put(2, "High", 9))
	runtime.beforeBroadcast = function(remote)
		if remote.Name == "Unreliable" then runtime.throwFire = true end
	end
	local ok, problem, report = state:Flush()
	assert(not ok and problem.code == "TransportFailure" and report.selected == 2
		and report.reliableHandoffs == 1 and report.unreliableHandoffs == 0
		and report.logicalHandoffs == 1 and state:GetStatus().pendingKeys == 0 and #runtime.fires == 1,
		"partial broadcast failure reports the confirmed native call and consumes selected records")
	local _, _, noReplay = state:Flush()
	assert(noReplay.selected == 0 and #runtime.fires == 1
		and server:GetDiagnostics().counters.broadcastHandoffs == 1,
		"uncertain selected State is never replayed")
	server:Destroy()
end

-- Client state lanes target only the server and emit kind 2 while retaining owned codec snapshots.
do
	local runtime = ClientRuntime.create()
	local _, _, remote = runtime:transport(compiled.descriptor, true)
	local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
	assertCode("NotStarted", client:CreateState(0.02))
	assert(client:Start())
	assertCode("InvalidOptions", client:CreateState(0))
	local state = assert(client:CreateState(0.02))
	assert(state.events.StateArray ~= nil and state.events.BatchInput == nil and state.events.StatePush == nil)
	local source = { 7 }
	assert(state.events.StateArray:Put(3, "Normal", source))
	source[1] = 99
	local newest = { 8 }
	assert(state.events.StateArray:Put(3, "High", newest))
	newest[1] = 100
	local untouched = { 6 }
	assert(state.events.StateArray:Put(4, "Low", untouched))
	untouched[1] = 77
	local ok, problem, report = state:Flush()
	assert(ok and problem == nil and report.unreliableHandoffs == 0 and report.reliableHandoffs == 1
		and report.selected == 2)
	local sent = runtime.fires[1]
	assert(sent[1] == 0 and sent.n == 2)
	local packet = sent[2]
	local header = assert(BatchFrame.header(packet, 8_192))
	assert(header.kind == 2 and header.count == 2)
	local rows = assert(BatchFrame.scan(packet, header, function(id) return compiled.queuedById[id] end))
	local values = {}
	for _, row in rows do
		local decoded = table.pack(Frame.compile(row.event, "decode")(assert(BatchFrame.readBody(packet, row))))
		assert(decoded[1] == true)
		values[decoded[2][1]] = true
	end
	assert(values[8] and values[6], "replacement is latest-unsent and each Put owns its encoding immediately")
	client:Destroy()
end

-- Replacement is latest-unsent, while four lanes share both active-key and pending-byte limits.
do
	local runtime, server, player = serverSetup()
	local batch = assert(server:CreateBatch({ player }, 0.02))
	local lanes = {}
	for index = 1, 4 do lanes[index] = assert(server:CreateState({ player }, 0.02)) end
	assert(batch.events.BatchPush:Send() and batch.events.StatePush:Send(99))
	for laneIndex, lane in lanes do
		for key = 1, 16 do
			assert(lane.events.StatePush:Put((laneIndex - 1) * 16 + key, "Low", key))
		end
	end
	assertCode("QueueLimit", lanes[4].events.StatePush:Put(65, "High", 1))
	assert(lanes[1]:GetStatus().activeKeys == 16 and lanes[4]:GetStatus().activeKeys == 16)
	assert(runtime:activeTimers() == 5)
	local batchOk, _, batchReport = batch:Flush()
	assert(batchOk and batchReport.selected == 2 and batchReport.logicalHandoffs == 2)
	local foundStateFifo = false
	for _, fire in runtime.fires do
		local packet = fire.values[2]
		local header = assert(BatchFrame.header(packet, if fire.remote.Name == "Unreliable" then 900 else 8_192))
		assert(header.kind == 1 and header.count == 1)
		local rows = assert(BatchFrame.scan(packet, header, function(id) return compiled.queuedById[id] end))
		if rows[1].event.id == compiled.events.StatePush.id then foundStateFifo = true end
	end
	assert(foundStateFifo, "State capability also permits ordinary FIFO batching")
	server:Destroy()
	assert(runtime:activeTimers() == 0)

	local runtime2, server2, player2 = serverSetup()
	local first = assert(server2:CreateState({ player2 }, 0.02))
	local second = assert(server2:CreateState({ player2 }, 0.02))
	for key = 1, 15 do assert(first.events.StateBlobPush:Put(key, "Normal", string.rep("A", 1_024))) end
	local before = first:GetStatus().pendingBodyBytes
	assertCode("QueueFull", first.events.StateBlobPush:Put(16, "Normal", string.rep("B", 1_024)))
	assertCode("QueueFull", second.events.StateBlobPush:Put(16, "Low", string.rep("D", 1_024)))
	local firstStatus = first:GetStatus()
	assert(firstStatus.pendingBodyBytes == before and firstStatus.pendingKeys == 15)
	assert(first.events.StateBlobPush:Put(1, "High", string.rep("C", 900)))
	assert(second.events.StateBlobPush:Put(16, "Low", string.rep("D", 1_024)))
	assert(first:GetStatus().pendingBodyBytes + second:GetStatus().pendingBodyBytes <= 16_384)
	local oldBytes = first:GetStatus().pendingBodyBytes
	assert(first.events.StateBlobPush:Put(1, "Normal", "new"))
	assert(first:GetStatus().pendingBodyBytes < oldBytes)
	server2:Destroy()
end

-- FIFO and state lanes share the same session flush guard; reentrant work remains pending.
do
	local runtime, server, first = serverSetup()
	local batch = assert(server:CreateBatch({ first }, 0.02))
	local state = assert(server:CreateState({ first }, 0.02))
	assert(batch.events.BatchPush:Send() and state.events.StatePush:Put(1, "High", 2))
	local reentered = false
	runtime.beforeFire = function()
		if reentered then return end
		reentered = true
		local ok, problem = state:Flush()
		assert(not ok and problem.code == "QueueBusy")
		assert(state:GetStatus().pendingKeys == 1)
	end
	local ok = batch:Flush()
	assert(ok and state:GetStatus().pendingKeys == 1)
	local stateOk = state:Flush()
	assert(stateOk)
	local batch2 = assert(server:CreateBatch({ first }, 0.02))
	local state2 = assert(server:CreateState({ first }, 0.02))
	assert(batch2.events.BatchPush:Send() and state2.events.StatePush:Put(2, "High", 3))
	runtime.beforeFire = function()
		local flushed, problem = batch2:Flush()
		assert(not flushed and problem.code == "QueueBusy")
	end
	local state2Ok = state2:Flush()
	assert(state2Ok)
	local batchOk = batch2:Flush()
	assert(batchOk)
	server:Destroy()
end

-- State handoff reports partial success once, and departure pruning affects only the owned snapshot.
do
	local runtime, server, first, second = serverSetup()
	local state = assert(server:CreateState({ first, second }, 0.02))
	assert(state.events.StatePush:Put(1, "Normal", 8))
	runtime.beforeFire = function(player)
		if player == second then runtime.throwFire = true end
	end
	local ok, problem, report = state:Flush()
	assert(not ok and problem.code == "TransportFailure" and report.unreliableHandoffs == 1
		and report.logicalHandoffs == 1 and #runtime.fires == 1)
	assert(state:GetStatus().lastFlush.report == report)
	local _, _, emptyReport = state:Flush()
	assert(emptyReport.selected == 0 and emptyReport.unreliableHandoffs == 0 and #runtime.fires == 1)
	server:Destroy()

	local runtime2, server2, first2, second2 = serverSetup()
	local lane = assert(server2:CreateState({ first2, second2 }, 0.02))
	assert(lane.events.StatePush:Put(1, "Normal", 9))
	runtime2:removePlayer(second2)
	local departedOk, _, departedReport = lane:Flush()
	assert(departedOk and departedReport.logicalHandoffs == 1 and #runtime2.fires == 1)
	server2:Destroy()
end

-- Format-2 state ingress validates all records before dispatch and charges each logical record.
do
	local _, metadataServer, metadataPlayer, _, _, metadataRemote = serverSetup()
	local metadataCalls = 0
	assert(metadataServer.events.StateInput:Connect(function() metadataCalls += 1 end))
	local unauthorized = envelope(2, { body("StateInput", 1), body("BatchInput") })
	metadataRemote.OnServerEvent:Fire(metadataPlayer, 0, unauthorized)
	assert(metadataCalls == 0 and metadataServer:GetDiagnostics().counters.invalidEndpoint == 1)
	metadataServer:Destroy()

	local constrained = {
		inboundRate = {
			perPlayer = { capacity = 2, refillPerSecond = 0.001 },
			aggregate = { capacity = 2, refillPerSecond = 0.001 },
		},
	}
	local runtime, server, hostile, other, _, reliable = serverSetup(constrained)
	local calls = 0
	assert(server.events.StateInput:Connect(function() calls += 1 end))
	assert(server.events.StateToggle:Connect(function() calls += 1 end))
	local packet = envelope(2, { body("StateInput", 1), body("StateToggle", false) })
	buffer.writeu8(packet, buffer.len(packet) - 1, 2)
	local validations = runtime.validationCalls
	reliable.OnServerEvent:Fire(hostile, 0, packet)
	assert(calls == 0 and runtime.validationCalls - validations == 2)
	reliable.OnServerEvent:Fire(other, 7, 1)
	reliable.OnServerEvent:Fire(hostile, 7, 1)
	local diagnostics = server:GetDiagnostics()
	assert(diagnostics.counters.invalidPayload == 1 and diagnostics.counters.aggregateRate == 1
		and diagnostics.counters.perPlayerRate == 1 and calls == 0)
	server:Destroy()
end

-- Session cleanup invalidates the owner before clearing queues; late cancelled timers cannot revive them.
do
	local runtime, server, player = serverSetup()
	local batch = assert(server:CreateBatch({ player }, 0.02))
	local state = assert(server:CreateState({ player }, 0.02))
	assert(batch.events.BatchPush:Send() and state.events.StatePush:Put(1, "Normal", 2))
	server:Destroy()
	assert(state:GetStatus().state == "Destroyed" and runtime:activeTimers() == 0)
	assertCode("Destroyed", state:Flush())
	runtime:advance(1)
	assert(#runtime.fires == 0)

	local runtime3, server3, player3 = serverSetup()
	local inFlight = assert(server3:CreateState({ player3 }, 0.02))
	assert(inFlight.events.StateBlobPush:Put(1, "High", "reliable"))
	assert(inFlight.events.StatePush:Put(2, "High", 3))
	runtime3.beforeFire = function() server3:Destroy() end
	local flushOk, flushProblem, partial = inFlight:Flush()
	assert(not flushOk and flushProblem.code == "Destroyed" and partial.reliableHandoffs == 1
		and partial.unreliableHandoffs == 0 and #runtime3.fires == 1)
	assert(inFlight:GetStatus().state == "Destroyed" and runtime3:activeTimers() == 0)
	runtime3:advance(1)
	assert(#runtime3.fires == 1)

	local runtime2, client, remote = clientSetup()
	local lane = assert(client:CreateState(0.02))
	assert(lane.events.StateArray:Put(4, "High", { 1 }))
	local batch = assert(client:CreateBatch(0.02))
	assert(batch.events.StateArray:Send({ 2 }))
	runtime2.ignoreTimerCancel = true
	remote:Destroy()
	assert(lane:GetStatus().state == "Destroyed")
	runtime2:advance(0.02)
	assert(#runtime2.fires == 0 and lane:GetStatus().pendingKeys == 0)
	assertCode("Disconnected", lane:Flush())
	assertCode("Disconnected", batch:Flush())
end

-- Client receives state-only format-2 records through its existing decoder and listener path.
do
	local _, client, _, unreliable = clientSetup()
	local received, toggled = nil, nil
	assert(client.events.StatePush:Connect(function(value) received = value end))
	assert(client.events.StateTogglePush:Connect(function(value) toggled = value end))
	unreliable.OnClientEvent:fire(0, envelope(2, { body("StatePush", 42) }, "Unreliable"))
	assert(received == 42)
	local malformed = envelope(2, { body("StatePush", 43), body("StateTogglePush", false) }, "Unreliable")
	buffer.writeu8(malformed, buffer.len(malformed) - 1, 2)
	unreliable.OnClientEvent:fire(0, malformed)
	assert(received == 42 and toggled == nil and client:GetDiagnostics().counters.invalidPayload == 1)
	client:Destroy()
end

-- Queued composite codecs keep the same immediate and format-2 values on both session sides.
do
	local runtime, server, player, _, _, remote = serverSetup()
	local inputBody = body("StateArray", { 7, 8 })
	local inputBatch = envelope(2, { inputBody })
	assertFreshArrayDeliveries(function(handler)
		return server.events.StateArray:Connect(function(_, values) handler(values) end)
	end, {
		function() remote.OnServerEvent:Fire(player, compiled.events.StateArray.id, inputBody) end,
		function() remote.OnServerEvent:Fire(player, compiled.events.StateArray.id, inputBody) end,
		function() remote.OnServerEvent:Fire(player, 0, inputBatch) end,
		function() remote.OnServerEvent:Fire(player, 0, inputBatch) end,
	})
	assert(server.events.StateArrayPush:Send(player, { 7, 8 }))
	local immediate = runtime.fires[#runtime.fires]
	assert(immediate.kind == "target" and immediate.player == player
		and immediate.values.n == 2 and immediate.values[1] == compiled.events.StateArrayPush.id)
	assertArrayPayload("StateArrayPush", immediate.values[2])
	local batch = assert(server:CreateBatch({ player }, 0.02))
	assert(batch.events.StateArrayPush:Send({ 7, 8 }))
	assert(batch:Flush())
	local queued = runtime.fires[#runtime.fires].values[2]
	local queuedHeader = assert(BatchFrame.header(queued, 8_192))
	local queuedRows = assert(BatchFrame.scan(queued, queuedHeader,
		function(id) return compiled.queuedById[id] end))
	assert(queuedHeader.kind == 1 and queuedRows[1].event.id == compiled.events.StateArrayPush.id)
	assertArrayPayload("StateArrayPush", assert(BatchFrame.readBody(queued, queuedRows[1])))
	server:Destroy()

	local clientRuntime, client, clientRemote = clientSetup()
	local pushBody = body("StateArrayPush", { 7, 8 })
	local pushBatch = envelope(2, { pushBody })
	assertFreshArrayDeliveries(function(handler)
		return client.events.StateArrayPush:Connect(handler)
	end, {
		function() clientRemote.OnClientEvent:fire(compiled.events.StateArrayPush.id, pushBody) end,
		function() clientRemote.OnClientEvent:fire(compiled.events.StateArrayPush.id, pushBody) end,
		function() clientRemote.OnClientEvent:fire(0, pushBatch) end,
		function() clientRemote.OnClientEvent:fire(0, pushBatch) end,
	})
	assert(client.events.StateArray:Send({ 7, 8 }))
	local immediateClient = clientRuntime.fires[#clientRuntime.fires]
	assert(immediateClient.n == 2 and immediateClient[1] == compiled.events.StateArray.id)
	assertArrayPayload("StateArray", immediateClient[2])
	local clientBatch = assert(client:CreateBatch(0.02))
	assert(clientBatch.events.StateArray:Send({ 7, 8 }))
	assert(clientBatch:Flush())
	local queuedClient = clientRuntime.fires[#clientRuntime.fires][2]
	local clientHeader = assert(BatchFrame.header(queuedClient, 8_192))
	local clientRows = assert(BatchFrame.scan(queuedClient, clientHeader,
		function(id) return compiled.queuedById[id] end))
	assert(clientHeader.kind == 1 and clientRows[1].event.id == compiled.events.StateArray.id)
	assertArrayPayload("StateArray", assert(BatchFrame.readBody(queuedClient, clientRows[1])))
	client:Destroy()
end

print("state session checks passed")
