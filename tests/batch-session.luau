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
	name = "BatchSessionProof", version = 1,
	events = {
		First = { id = 1, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		Second = { id = 2, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		Toggle = { id = 3, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "boolean" } } },
		UnreliableInput = { id = 4, direction = "ClientToServer", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		StateInput = { id = 5, direction = "ClientToServer", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		ImmediateInput = { id = 6, direction = "ClientToServer",
			fields = { { name = "value", type = "u8" } } },
		Spare7 = { id = 7, direction = "ClientToServer", queue = "Batch", fields = {} },
		Spare8 = { id = 8, direction = "ClientToServer", queue = "Batch", fields = {} },
		Spare9 = { id = 9, direction = "ClientToServer", queue = "Batch", fields = {} },
		Spare10 = { id = 10, direction = "ClientToServer", queue = "Batch", fields = {} },
		Push = { id = 11, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		UnreliablePush = { id = 12, direction = "ServerToClient", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "boolean" } } },
		StatePush = { id = 13, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		ImmediatePush = { id = 14, direction = "ServerToClient",
			fields = { { name = "value", type = "u8" } } },
		BooleanPush = { id = 15, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "boolean" } } },
		Spare16 = { id = 16, direction = "ClientToServer", queue = "Batch", fields = {} },
	},
}))
local compiled = assert(Definition.get(definition))
local options = {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
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

local function truncatedSecond(kind, firstBody, secondBody)
	local firstBytes, secondBytes = buffer.len(firstBody), buffer.len(secondBody)
	local packet = buffer.create(3 + 2 + firstBytes + 2 + secondBytes - 1)
	buffer.writeu8(packet, 0, 2)
	buffer.writeu8(packet, 1, kind)
	buffer.writeu8(packet, 2, 2)
	buffer.writeu16(packet, 3, firstBytes)
	buffer.copy(packet, 5, firstBody, 0, firstBytes)
	local secondOffset = 5 + firstBytes
	buffer.writeu16(packet, secondOffset, secondBytes)
	buffer.copy(packet, secondOffset + 2, secondBody, 0, secondBytes - 1)
	return packet
end

local function serverSetup(serverOptions)
	local runtime = ServerRuntime.new()
	local first, second, third = runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
	local server = assert(runtime.server.create(definition, serverOptions or options))
	assert(server:Start())
	return runtime, server, first, second, third, runtime:remote(), runtime:unreliableRemote()
end

local function serverWithoutStart(serverOptions)
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local server = assert(runtime.server.create(definition, serverOptions or options))
	return runtime, server, player
end

local function clientSetup()
	local runtime = ClientRuntime.create()
	local _, _, remote, unreliable = runtime:transport(compiled.descriptor, true)
	local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
	assert(client:Start())
	return runtime, client, remote, unreliable
end

-- Shared broadcast batching uses one current-roster frame per populated channel.
do
	local _, unstarted, player = serverWithoutStart()
	assertCode("NotStarted", unstarted:CreateBroadcastBatcher(0.02))
	unstarted:Destroy()

	local runtime, server, first, second, third, reliable, unreliable = serverSetup()
	assertCode("InvalidOptions", server:CreateBroadcastBatcher(0))
	assertCode("InvalidOptions", server:CreateBroadcastBatcher(math.huge))
	assertCode("InvalidOptions", server:CreateBroadcastBatcher("0.02"))
	local batcher = assert(server:CreateBroadcastBatcher(0.02))
	assert(batcher.events.Push ~= nil and batcher.events.UnreliablePush ~= nil
		and batcher.events.ImmediatePush == nil and batcher.events.First == nil,
		"broadcast batcher exposes only queued server-to-client events")
	assert(batcher.events.Push:Send(41) and batcher.events.Push:Send(42)
		and batcher.events.UnreliablePush:Send(true) and batcher.events.UnreliablePush:Send(false))
	local snapshots = 0
	runtime.snapshotHook = function(snapshot)
		snapshots += 1
		assert(#snapshot == 3 and snapshot[1] == first and snapshot[2] == second and snapshot[3] == third)
	end
	local ok, problem, report = batcher:Flush()
	runtime.snapshotHook = nil
	assert(ok and problem == nil and report.selected == 4 and report.remaining == 0
		and report.reliableHandoffs == 1 and report.unreliableHandoffs == 1
		and report.logicalHandoffs == 4 and snapshots == 1 and #runtime.fires == 2,
		"one shared native handoff carries each populated channel")
	local reliableFire, unreliableFire = runtime.fires[1], runtime.fires[2]
	local reliableHeader = assert(BatchFrame.header(reliableFire.values[2], 8_192))
	local unreliableHeader = assert(BatchFrame.header(unreliableFire.values[2], 900))
	assert(reliableFire.kind == "broadcast" and reliableFire.remote == reliable
		and reliableFire.values.n == 2 and reliableFire.values[1] == 0
		and reliableHeader.kind == 1 and reliableHeader.count == 2
		and unreliableFire.kind == "broadcast" and unreliableFire.remote == unreliable
		and unreliableFire.values.n == 2 and unreliableFire.values[1] == 0
		and unreliableHeader.kind == 1 and unreliableHeader.count == 2,
		"broadcast packets retain the existing format-2 FIFO envelope and reliable-first order")
	local diagnostics = server:GetDiagnostics().counters
	assert(diagnostics.broadcastHandoffs == 2 and diagnostics.sendHandoffs == 0,
		"shared batch diagnostics count successful native calls")

	local joined = runtime:addPlayer()
	runtime:removePlayer(first)
	local currentRoster
	runtime.snapshotHook = function(snapshot)
		currentRoster = table.clone(snapshot)
	end
	assert(batcher.events.Push:Send(43))
	local nextOk, _, nextReport = batcher:Flush()
	runtime.snapshotHook = nil
	assert(nextOk and nextReport.reliableHandoffs == 1 and nextReport.logicalHandoffs == 1
		and #runtime.fires == 3 and currentRoster ~= nil and #currentRoster == 3
		and not table.find(currentRoster, first) and table.find(currentRoster, joined),
		"each reusable window resolves a fresh roster including later joins")

	runtime.players.GetPlayers = function() error("empty flush must not enumerate players") end
	local beforeEmpty = #runtime.fires
	local emptyOk, _, emptyReport = batcher:Flush()
	assert(emptyOk and emptyReport.selected == 0 and emptyReport.reliableHandoffs == 0
		and #runtime.fires == beforeEmpty, "empty windows skip roster lookup and handoff")
	batcher:Cancel()
	server:Destroy()
end

-- Invalid current-player snapshots retain the open window and stop its timer for explicit retry.
do
	local function verifyBadSnapshot(replacePlayers, expected)
		local runtime, server, first = serverSetup()
		local batcher = assert(server:CreateBroadcastBatcher(0.02))
		assert(batcher.events.Push:Send(9) and runtime:activeTimers() == 1)
		runtime.players.GetPlayers = replacePlayers(runtime)
		local before = #runtime.fires
		local ok, problem, report = batcher:Flush()
		local status = batcher:GetStatus()
		assert(not ok and problem.code == expected and report.selected == 0 and report.remaining == 1
			and status.state == "Open" and status.pendingRecords == 1 and runtime:activeTimers() == 0
			and #runtime.fires == before, "bad broadcast snapshot is rejected before debit or handoff")
		runtime.players.GetPlayers = function() return runtime.players:GetChildren() end
		assert(batcher:Flush() and #runtime.fires == before + 1,
			"snapshot refusal preserves the frame for a manual retry")
		server:Destroy()
	end

	verifyBadSnapshot(function(runtime)
		return function()
			local snapshot = runtime.players:GetChildren()
			snapshot.hash = true
			return snapshot
		end
	end, "InvalidAudience")
	verifyBadSnapshot(function(runtime)
		return function()
			local snapshot = runtime.players:GetChildren()
			snapshot[2] = nil
			return snapshot
		end
	end, "InvalidAudience")
	verifyBadSnapshot(function(runtime)
		return function()
			return setmetatable(runtime.players:GetChildren(), {})
		end
	end, "InvalidAudience")
	verifyBadSnapshot(function(runtime)
		return function()
			local snapshot = runtime.players:GetChildren()
			snapshot[2] = snapshot[1]
			return snapshot
		end
	end, "InvalidAudience")
	verifyBadSnapshot(function(runtime)
		return function()
			error("GetPlayers failed")
		end
	end, "InvalidAudience")
	verifyBadSnapshot(function(runtime)
		local stale = runtime.players:GetChildren()[1]
		runtime:removePlayer(stale)
		return function() return { stale } end
	end, "InvalidAudience")
end

-- A current Player without an active Relay roster owner fails closed with policy-specific errors.
do
	local runtime, server, first = serverSetup()
	local unowned = runtime.newInstance("Player")
	unowned.Parent = runtime.players
	local batcher = assert(server:CreateBroadcastBatcher(0.02))
	assert(batcher.events.Push:Send(1))
	local ok, problem = batcher:Flush()
	assert(not ok and problem.code == "InvalidAudience"
		and batcher:GetStatus().state == "Open" and batcher:GetStatus().pendingRecords == 1,
		"unbudgeted current players require active Relay roster owners")
	unowned.Parent = nil
	assert(batcher:Flush())
	server:Destroy()
end

-- Teardown during dynamic roster resolution preserves the already-settled terminal result.
do
	local runtime, server = serverSetup()
	local batcher = assert(server:CreateBroadcastBatcher(0.02))
	assert(batcher.events.Push:Send(1))
	runtime.snapshotHook = function() server:Destroy() end
	local called, ok, problem, report = pcall(function() return batcher:Flush() end)
	assert(called and not ok and problem.code == "Destroyed" and report.selected == 0
		and batcher:GetStatus().state == "Terminal" and batcher:GetStatus().pendingRecords == 0
		and runtime:activeTimers() == 0 and #runtime.fires == 0,
		`reentrant teardown during GetPlayers must return the cached terminal result (called={called}, ok={ok}, error={if problem then problem.code else "none"})`)
	assert(batcher:Flush() == false and batcher:GetStatus().lastFlush.error.code == "Destroyed")
end

-- Shared flush exclusion and terminal partial handoff behavior are unchanged.
do
	local runtime, server = serverSetup()
	local batcher = assert(server:CreateBroadcastBatcher(0.02))
	assert(batcher.events.Push:Send(5) and batcher.events.UnreliablePush:Send(true))
	runtime.beforeBroadcast = function()
		local ok, problem = batcher:Flush()
		assert(not ok and problem.code == "QueueBusy")
	end
	local ok, _, report = batcher:Flush()
	runtime.beforeBroadcast = nil
	assert(ok and report.reliableHandoffs == 1 and report.unreliableHandoffs == 1
		and #runtime.fires == 2, "reentrant flush cannot enter the shared broadcast window")
	server:Destroy()

	local failedRuntime, failedServer = serverSetup()
	local failedBatcher = assert(failedServer:CreateBroadcastBatcher(0.02))
	assert(failedBatcher.events.Push:Send(6) and failedBatcher.events.UnreliablePush:Send(false))
	failedRuntime.beforeBroadcast = function(transport)
		if transport.ClassName == "UnreliableRemoteEvent" then error("second channel failed") end
	end
	local failed, problem, partial = failedBatcher:Flush()
	failedRuntime.beforeBroadcast = nil
	assert(not failed and problem.code == "TransportFailure" and partial.selected == 2
		and partial.reliableHandoffs == 1 and partial.unreliableHandoffs == 0
		and partial.logicalHandoffs == 1 and failedBatcher:GetStatus().state == "Terminal"
		and #failedRuntime.fires == 1, "later channel failure reports the completed call without retry")
	local _, _, cached = failedBatcher:Flush()
	assert(cached == partial and #failedRuntime.fires == 1)
	failedServer:Destroy()
end

-- Public batch creation snapshots actual recipients and hands one bounded format-2 envelope to each.
do
	local _, unstarted, player = serverWithoutStart()
	assertCode("NotStarted", unstarted:CreateBatch({ player }, 0.02))
	assertCode("NotStarted", unstarted:CreateBatcher({ player }, 0.02))
	unstarted:Destroy()

	local runtime, server, first, second, third = serverSetup()
	assertCode("InvalidOptions", server:CreateBatch({}, 0))
	assertCode("InvalidOptions", server:CreateBatcher({ first }, 0))
	assertCode("InvalidAudience", server:CreateBatch({ [1] = first, [3] = second }, 0.02))
	assertCode("InvalidAudience", server:CreateBatcher({ [1] = first, [3] = second }, 0.02))
	local recipients = { first, second, second, third }
	local batch = assert(server:CreateBatch(recipients, 0.02))
	recipients[1] = {}
	assert(batch.events.Push:Send(41))
	runtime:removePlayer(second)
	local ok, problem, report = batch:Flush()
	assert(ok and problem == nil and table.isfrozen(report) and report.selected == 1
		and report.reliableHandoffs == 2 and report.logicalHandoffs == 2)
	assert(#runtime.fires == 2)
	for _, fire in runtime.fires do
		assert(fire.kind == "target" and fire.values.n == 2 and fire.values[1] == 0)
		local packet = fire.values[2]
		local header = assert(BatchFrame.header(packet, 8_192))
		assert(header.kind == 1 and header.count == 1)
		assert(fire.player == first or fire.player == third)
	end
	assert(server:GetDiagnostics().counters.sendHandoffs == 2)
	server:Destroy()
end

-- Empty maps stay usable, while malformed deadlines and audiences fail before taking the open slot.
do
	local runtime, server, first = serverSetup()
	assertCode("InvalidOptions", server:CreateBatch({ first }, math.huge))
	assertCode("InvalidAudience", server:CreateBatch({ [1] = first, [3] = first }, 0.02))
	local emptyDefinition = assert(Definition.define({ name = "EmptyBatch", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", fields = {} },
	} }))
	local emptyRuntime = ServerRuntime.new()
	local emptyPlayer = emptyRuntime:addPlayer()
	local emptyServer = assert(emptyRuntime.server.create(emptyDefinition, options))
	assert(emptyServer:Start())
	local emptyBatch = assert(emptyServer:CreateBatch({ emptyPlayer }, 0.02))
	assert(next(emptyBatch.events) == nil)
	local ok, _, report = emptyBatch:Flush()
	assert(ok and report.selected == 0 and report.reliableHandoffs == 0 and #emptyRuntime.fires == 0)
	emptyServer:Destroy()
	server:Destroy()
end

-- The first accepted record sets one automatic service timer; completion is cached.
do
	local runtime, server, first = serverSetup()
	local batch = assert(server:CreateBatch({ first }, 0.02))
	assert(batch.events.Push:Send(9) and runtime:activeTimers() == 1)
	runtime:advance(0.02)
	assert(runtime:activeTimers() == 0 and #runtime.fires == 1)
	local ok, _, report = batch:Flush()
	assert(ok and report.selected == 1 and report.reliableHandoffs == 1 and #runtime.fires == 1)
	server:Destroy()
end

-- One server batcher keeps its fixed audience across manual and automatic windows.
do
	local runtime, server, first, second, third = serverSetup()
	local recipients = { first, second, second, third }
	local batcher = assert(server:CreateBatcher(recipients, 0.02))
	recipients[1] = third
	assertCode("QueueLimit", server:CreateBatch({ first }, 0.02))
	assert(runtime:activeTimers() == 0 and batcher:GetStatus().state == "Open")
	assert(batcher.events.Push:Send(41))
	local firstOk, _, firstReport = batcher:Flush()
	assert(firstOk and firstReport.selected == 1 and firstReport.reliableHandoffs == 3
		and #runtime.fires == 3 and batcher:GetStatus().state == "Open"
		and batcher:GetStatus().pendingRecords == 0 and runtime:activeTimers() == 0,
		"manual server flush reopens the same handle with its deduplicated audience")
	for _, fire in runtime.fires do
		local header = assert(BatchFrame.header(fire.values[2], 8_192))
		assert(fire.kind == "target" and header.kind == 1 and header.count == 1
			and (fire.player == first or fire.player == second or fire.player == third))
	end
	assert(batcher.events.Push:Send(42))
	runtime:advance(0.02)
	assert(batcher:GetStatus().state == "Open" and batcher:GetStatus().pendingRecords == 0
		and batcher:GetStatus().lastFlush.report.selected == 1 and runtime:activeTimers() == 0
		and #runtime.fires == 6,
		"automatic server expiry reopens without an idle timer")

	local removalArmed = true
	runtime.beforeFire = function(player)
		if removalArmed and player == second then
			removalArmed = false
			runtime:removePlayer(first)
		end
	end
	assert(batcher.events.Push:Send(43))
	local removalOk, _, removalReport = batcher:Flush()
	runtime.beforeFire = nil
	assert(removalOk and removalReport.reliableHandoffs == 3 and #runtime.fires == 9,
		"removal during a handoff does not mutate the active recipient iterator")
	assert(batcher.events.Push:Send(44))
	local prunedOk, _, prunedReport = batcher:Flush()
	assert(prunedOk and prunedReport.reliableHandoffs == 2 and #runtime.fires == 11
		and runtime.fires[10].player == second and runtime.fires[11].player == third,
		"the next server window uses the independently pruned fixed audience")
	batcher:Cancel()
	assert(batcher:GetStatus().state == "Terminal")
	server:Destroy()
end

-- Reentrant manual Flush sees QueueBusy without changing the active operation.
do
	local runtime, server, first = serverSetup()
	local batch = assert(server:CreateBatch({ first }, 0.02))
	assert(batch.events.Push:Send(5))
	runtime.beforeFire = function()
		local ok, problem = batch:Flush()
		assert(not ok and problem.code == "QueueBusy")
	end
	local ok, _, report = batch:Flush()
	assert(ok and report.reliableHandoffs == 1 and #runtime.fires == 1)
	server:Destroy()
end

-- Partial targeted handoff reports only completed FireClient calls and never retries.
do
	local runtime, server, first, second = serverSetup()
	local batch = assert(server:CreateBatch({ first, second }, 0.02))
	assert(batch.events.Push:Send(5))
	runtime.beforeFire = function(player)
		if player == second then runtime:removePlayer(second) end
	end
	local ok, problem, report = batch:Flush()
	assert(not ok and problem.code == "TransportFailure" and report.selected == 1
		and report.reliableHandoffs == 1 and report.logicalHandoffs == 1 and #runtime.fires == 1)
	local _, _, cached = batch:Flush()
	assert(cached == report and #runtime.fires == 1)
	server:Destroy()
end

-- Kind 2 accepts only State capabilities; Unreliable FIFO remains kind 1 on either channel.
do
	local runtime, server, player, _, _, reliable, unreliable = serverSetup()
	local firstCalls, stateCalls, unreliableCalls = 0, 0, 0
	assert(server.events.First:Connect(function() firstCalls += 1 end))
	assert(server.events.StateInput:Connect(function(sender, value)
		assert(sender == player and value == 8)
		stateCalls += 1
	end))
	assert(server.events.UnreliableInput:Connect(function() unreliableCalls += 1 end))
	reliable.OnServerEvent:Fire(player, 0, envelope(2, { body("First", 1) }))
	reliable.OnServerEvent:Fire(player, 0, envelope(2, { body("StateInput", 8) }))
	reliable.OnServerEvent:Fire(player, 0, envelope(1, { body("UnreliableInput", 9) }))
	unreliable.OnServerEvent:Fire(player, 0,
		envelope(1, { body("UnreliableInput", 9) }, "Unreliable"))
	assert(firstCalls == 0 and stateCalls == 1 and unreliableCalls == 1)
	local diagnostics = server:GetDiagnostics()
	assert(diagnostics.counters.invalidPayload == 0
		and diagnostics.counters.invalidEndpoint == 1
		and diagnostics.counters.wrongChannel == 1,
		"scan rejections preserve session-level endpoint and channel reasons")
	server:Destroy()
end

-- Declared valid counts are fully charged before malformed framing and do not refund admission.
do
	local limited = {
		inboundRate = {
			perPlayer = { capacity = 2, refillPerSecond = 1 },
			aggregate = { capacity = 2, refillPerSecond = 1 },
		},
	}
	local runtime, server, player, _, _, reliable = serverSetup(limited)
	local calls = 0
	assert(server.events.ImmediateInput:Connect(function() calls += 1 end))
	local malformed = buffer.create(3)
	buffer.writeu8(malformed, 0, 2)
	buffer.writeu8(malformed, 1, 1)
	buffer.writeu8(malformed, 2, 2)
	reliable.OnServerEvent:Fire(player, 0, malformed)
	assert(server:GetDiagnostics().counters.invalidPayload == 1 and calls == 0)
	reliable.OnServerEvent:Fire(player, 6, 9)
	assert(calls == 0 and server:GetDiagnostics().counters.perPlayerRate == 1,
		"a malformed N=2 envelope retains both admission charges")
	server:Destroy()
end

-- A valid declared count spends per-player capacity before the matching aggregate debit fails.
do
	local limited = {
		inboundRate = {
			perPlayer = { capacity = 4, refillPerSecond = 1 },
			aggregate = { capacity = 4, refillPerSecond = 1 },
		},
	}
	local runtime, server, hostile, honest, _, reliable = serverSetup(limited)
	local calls = 0
	assert(server.events.ImmediateInput:Connect(function() calls += 1 end))
	for index = 1, 3 do reliable.OnServerEvent:Fire(honest, 6, index) end
	assert(calls == 3)
	calls = 0
	local declaredTwo = buffer.create(3)
	buffer.writeu8(declaredTwo, 0, 2)
	buffer.writeu8(declaredTwo, 1, 1)
	buffer.writeu8(declaredTwo, 2, 2)
	reliable.OnServerEvent:Fire(hostile, 0, declaredTwo)
	assert(server:GetDiagnostics().counters.aggregateRate == 1 and calls == 0)
	reliable.OnServerEvent:Fire(hostile, 6, 1)
	reliable.OnServerEvent:Fire(hostile, 6, 2)
	local diagnostics = server:GetDiagnostics()
	assert(diagnostics.counters.aggregateRate == 3 and calls == 0
		and diagnostics.counters.perPlayerRate == 0,
		"player debits preceding aggregate exhaustion are retained")
	reliable.OnServerEvent:Fire(hostile, 6, 3)
	assert(server:GetDiagnostics().counters.perPlayerRate == 1 and calls == 0)
	server:Destroy()
end

-- A legal 32-record, 256-node-per-record envelope reaches session admission and staged decoding.
do
	local fields = table.create(4)
	for index, capacity in { 64, 64, 64, 60 } do
		fields[index] = { name = ({ "first", "second", "third", "fourth" })[index],
			type = "array", maximumLength = capacity,
			element = { type = "struct", fields = {} } }
	end
	local denseDefinition = assert(Definition.define({ name = "DenseBatchSessionProof", version = 1,
		events = { Dense = { id = 1, direction = "ClientToServer", queue = "Batch", fields = fields } },
	}))
	local queued = assert(Definition.get(denseDefinition).queuedById[1])
	assert(queued.maximumElements == 256 and queued.minimumEncodedBytes == 11)
	local values = table.create(4)
	for index, capacity in { 64, 64, 64, 60 } do
		values[index] = table.create(capacity)
		for child = 1, capacity do values[index][child] = {} end
	end
	local encoded = table.pack(Frame.compile(queued, "encode")(table.unpack(values)))
	assert(encoded[1] == true and buffer.len(encoded[2]) == 11)
	local bodies = table.create(32)
	for index = 1, 32 do bodies[index] = encoded[2] end
	local packet = assert(BatchFrame.wrap(1, bodies, 8_192))
	assert(buffer.len(packet) == 419)
	local rows = assert(BatchFrame.scan(packet, assert(BatchFrame.header(packet, 8_192)),
		function(id) return if id == 1 then queued else nil end))
	assert(#rows == 32)

	local function receiveDense(incoming)
		local runtime = ServerRuntime.new()
		local sender, other = runtime:addPlayer(), runtime:addPlayer()
		local server = assert(runtime.server.create(denseDefinition, {
			inboundRate = { perPlayer = { capacity = 32, refillPerSecond = 1 },
				aggregate = { capacity = 32, refillPerSecond = 1 } },
		}))
		assert(server:Start())
		local received = {}
		assert(server.events.Dense:Connect(function(player, first, second, third, fourth)
			assert(player == sender and #first == 64 and #second == 64
				and #third == 64 and #fourth == 60)
			received[#received + 1] = first
		end))
		local remote = runtime:remote()
		remote.OnServerEvent:Fire(sender, 0, incoming)
		remote.OnServerEvent:Fire(sender, 65_535)
		remote.OnServerEvent:Fire(other, 65_535)
		local diagnostics = server:GetDiagnostics()
		assert(diagnostics.counters.perPlayerRate == 1 and diagnostics.counters.aggregateRate == 1,
			"all 32 declared records spend both admission budgets")
		server:Destroy()
		return received, diagnostics
	end

	local received, diagnostics = receiveDense(packet)
	assert(#received == 32 and diagnostics.counters.invalidPayload == 0,
		"all 32 legal high-node records reach handlers")
	for index = 2, 32 do assert(received[index] ~= received[1]) end

	local malformed = buffer.create(buffer.len(packet))
	buffer.copy(malformed, 0, packet, 0, buffer.len(packet))
	buffer.writeu16(malformed, rows[32].offset + 3, 65)
	received, diagnostics = receiveDense(malformed)
	assert(#received == 0 and diagnostics.counters.invalidPayload == 1,
		"invalid final count rejects the whole admitted batch before dispatch")
end

-- Dispatch starts each admitted record before reserving the next endpoint lease.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local names = { "First", "Second", "Toggle", "StateInput", "Spare7", "Spare8", "Spare9", "Spare10", "Spare16" }
	local bodies = table.create(#names)
	for index, name in names do
		assert(server.events[name]:Connect(function() coroutine.yield() end))
		if name == "First" or name == "Second" or name == "StateInput" then
			bodies[index] = body(name, 1)
		elseif name == "Toggle" then
			bodies[index] = body(name, true)
		else
			bodies[index] = body(name)
		end
	end
	reliable.OnServerEvent:Fire(player, 0, envelope(1, bodies))
	assert(#runtime.spawnedThreads == 8 and server:GetDiagnostics().inFlight == 8)
	assert(server:GetDiagnostics().events.Spare16.busy == 1,
		"only eight simultaneous handlers are admitted for one player")
	for _, thread in runtime.spawnedThreads do
		local ok, problem = coroutine.resume(thread)
		assert(ok, problem)
	end
	assert(server:GetDiagnostics().inFlight == 0)
	server:Destroy()
end

-- Reentrant topology damage preserves the actual successful handoff and terminally closes the session.
do
	local runtime, server, first = serverSetup()
	local root = runtime.storage:FindFirstChild("RelayRemotes")
	local batch = assert(server:CreateBatch({ first }, 0.02))
	assert(batch.events.Push:Send(5))
	runtime.beforeFire = function() root.Name = "damaged" end
	local ok, problem, report = batch:Flush()
	assert(not ok and problem.code == "Destroyed" and report.reliableHandoffs == 1
		and report.logicalHandoffs == 1 and server:GetDiagnostics().state == "Destroyed")
	server:Destroy()
end

-- Batch decoding completes for every record before task.spawn can call the first handler.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local calls = 0
	assert(server.events.First:Connect(function() calls += 1 end))
	assert(server.events.Toggle:Connect(function() calls += 1 end))
	local malformedBoolean = buffer.create(4)
	buffer.writeu8(malformedBoolean, 0, 1)
	buffer.writeu16(malformedBoolean, 1, 3)
	buffer.writeu8(malformedBoolean, 3, 2)
	local packet = envelope(1, { body("First", 1), malformedBoolean })
	reliable.OnServerEvent:Fire(player, 0, packet)
	assert(calls == 0 and server:GetDiagnostics().counters.invalidPayload == 1)
	server:Destroy()
end

-- A structural failure after one resolved record is session-only; no earlier row owns the error.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local calls = 0
	assert(server.events.First:Connect(function() calls += 1 end))
	local malformed = truncatedSecond(1, body("First", 1), body("Second", 2))
	reliable.OnServerEvent:Fire(player, 0, malformed)
	local snapshot = server:GetDiagnostics()
	assert(calls == 0 and snapshot.counters.invalidPayload == 1
		and snapshot.events.First.invalidPayload == 0,
		"scan failures have no authoritative failing event row")
	server:Destroy()
end

-- A yielding record keeps its lease while the next wire-order record starts independently.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local starts = {}
	assert(server.events.First:Connect(function()
		table.insert(starts, "first")
		coroutine.yield()
	end))
	assert(server.events.Second:Connect(function()
		table.insert(starts, "second")
	end))
	reliable.OnServerEvent:Fire(player, 0, envelope(1, { body("First", 1), body("Second", 2) }))
	assert(starts[1] == "first" and starts[2] == "second" and server:GetDiagnostics().inFlight == 1)
	reliable.OnServerEvent:Fire(player, 1, 3)
	assert(#starts == 2 and server:GetDiagnostics().events.First.busy == 1)
	local suspended = runtime.spawnedThreads[1]
	assert(coroutine.status(suspended) == "suspended")
	local resumed, problem = coroutine.resume(suspended)
	assert(resumed, problem)
	assert(server:GetDiagnostics().inFlight == 0)
	server:Destroy()
end

-- Each record starts before the next is admitted, so quick duplicate endpoints release their lease.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local values = {}
	assert(server.events.First:Connect(function(_, value) values[#values + 1] = value end))
	reliable.OnServerEvent:Fire(player, 0, envelope(1, { body("First", 1), body("First", 2) }))
	local diagnostics = server:GetDiagnostics()
	assert(values[1] == 1 and values[2] == 2 and diagnostics.events.First.busy == 0
		and diagnostics.inFlight == 0)
	server:Destroy()
end

-- A yielded first duplicate keeps its endpoint lease, dropping only the busy second record.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local values = {}
	assert(server.events.First:Connect(function(_, value)
		values[#values + 1] = value
		if value == 1 then coroutine.yield() end
	end))
	reliable.OnServerEvent:Fire(player, 0, envelope(1, { body("First", 1), body("First", 2) }))
	assert(values[1] == 1 and values[2] == nil and server:GetDiagnostics().events.First.busy == 1)
	local ok, problem = coroutine.resume(runtime.spawnedThreads[1])
	assert(ok, problem and tostring(problem))
	assert(values[2] == nil and server:GetDiagnostics().inFlight == 0)
	server:Destroy()
end

-- A Once listener can install its replacement before the next same-endpoint record.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local values = {}
	assert(server.events.First:Once(function(_, value)
		values[#values + 1] = `once:{value}`
		assert(server.events.First:Connect(function(_, replacementValue)
			values[#values + 1] = `replacement:{replacementValue}`
		end))
	end))
	reliable.OnServerEvent:Fire(player, 0, envelope(1, { body("First", 1), body("First", 2) }))
	assert(values[1] == "once:1" and values[2] == "replacement:2")
	server:Destroy()
end

-- Destroy from the first started record prevents later records from starting.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local starts = {}
	assert(server.events.First:Connect(function()
		starts[#starts + 1] = "first"
		server:Destroy()
	end))
	assert(server.events.Second:Connect(function() starts[#starts + 1] = "second" end))
	reliable.OnServerEvent:Fire(player, 0, envelope(1, { body("First", 1), body("Second", 2) }))
	assert(starts[1] == "first" and starts[2] == nil and server:GetDiagnostics().state == "Destroyed")
end

-- A malformed count pays only its outer pair; exact per-player then aggregate prefix charging holds.
do
	local limited = {
		inboundRate = {
			perPlayer = { capacity = 2, refillPerSecond = 1 },
			aggregate = { capacity = 3, refillPerSecond = 1 },
		},
	}
	local runtime, server, hostile, honest, _, reliable = serverSetup(limited)
	local calls = 0
	assert(server.events.ImmediateInput:Connect(function() calls += 1 end))
	local invalidCount = buffer.create(3)
	buffer.writeu8(invalidCount, 0, 2)
	buffer.writeu8(invalidCount, 1, 1)
	buffer.writeu8(invalidCount, 2, 33)
	reliable.OnServerEvent:Fire(hostile, 0, invalidCount)
	reliable.OnServerEvent:Fire(hostile, 6, 4)
	assert(calls == 1 and server:GetDiagnostics().counters.perPlayerRate == 0,
		"invalid count charges only the initial pair")

	local declaredThree = buffer.create(3)
	buffer.writeu8(declaredThree, 0, 2)
	buffer.writeu8(declaredThree, 1, 1)
	buffer.writeu8(declaredThree, 2, 3)
	reliable.OnServerEvent:Fire(hostile, 0, declaredThree)
	assert(server:GetDiagnostics().counters.perPlayerRate == 1 and calls == 1,
		"logical admission stops at the first failed per-player debit")
	reliable.OnServerEvent:Fire(honest, 6, 5)
	assert(calls == 2, "the failed per-player pair did not spend aggregate capacity")
	server:Destroy()
end

-- One FIFO envelope on the Unreliable channel is kind 1 and still uses the normal event leases.
do
	local runtime, server, player, _, _, _, unreliable = serverSetup()
	local calls = 0
	assert(server.events.UnreliableInput:Connect(function(sender, value)
		assert(sender == player and value == 7)
		calls += 1
	end))
	unreliable.OnServerEvent:Fire(player, 0, envelope(1, { body("UnreliableInput", 7) }, "Unreliable"))
	assert(calls == 1 and server:GetDiagnostics().events.UnreliableInput.dispatched == 1)
	server:Destroy()
end

-- One client batcher supports a manual FIFO window followed by an automatic Unreliable window.
do
	local runtime, client, reliable, unreliable = clientSetup()
	assertCode("InvalidOptions", client:CreateBatcher(math.huge))
	local batcher = assert(client:CreateBatcher(0.02))
	assertCode("QueueLimit", client:CreateBatch(0.02))
	assert(batcher.events.StateInput:Send(12))
	local manualOk, _, manualReport = batcher:Flush()
	local manualHeader = assert(BatchFrame.header(runtime.fires[1][2], 8_192))
	assert(manualOk and manualReport.selected == 1 and manualReport.reliableHandoffs == 1
		and runtime.fires[1].remote == reliable and manualHeader.kind == 1 and manualHeader.count == 1
		and batcher:GetStatus().state == "Open" and batcher:GetStatus().pendingRecords == 0,
		"manual client flush reopens the same sender and preserves State FIFO format")
	assert(batcher.events.UnreliableInput:Send(7))
	runtime:advance(0.02)
	local automaticHeader = assert(BatchFrame.header(runtime.fires[2][2], 900))
	assert(runtime.fires[2].remote == unreliable and automaticHeader.kind == 1
		and automaticHeader.count == 1 and batcher:GetStatus().state == "Open"
		and batcher:GetStatus().pendingRecords == 0
		and batcher:GetStatus().lastFlush.report.selected == 1 and #runtime.fires == 2,
		"automatic client expiry reopens after the Unreliable handoff")
	batcher:Cancel()
	assert(batcher:GetStatus().state == "Terminal")
	local ordinary = assert(client:CreateBatch(0.02))
	ordinary:Cancel()
	client:Destroy()
end

-- Client sends batches through endpoint zero and validates whole incoming envelopes before callbacks.
do
	local runtime, client, reliable, unreliable = clientSetup()
	assertCode("InvalidOptions", client:CreateBatch(math.huge))
	local batch = assert(client:CreateBatch(0.02))
	assert(batch.events.StateInput:Send(12))
	local ok, _, report = batch:Flush()
	assert(ok and report.selected == 1 and report.reliableHandoffs == 1)
	assert(#runtime.fires == 1 and runtime.fires[1].n == 2 and runtime.fires[1][1] == 0)
	local sentHeader = assert(BatchFrame.header(runtime.fires[1][2], 8_192))
	assert(sentHeader.kind == 1 and sentHeader.count == 1)
	table.clear(runtime.fires)
	local unreliableBatch = assert(client:CreateBatch(0.02))
	assert(unreliableBatch.events.UnreliableInput:Send(7))
	local unreliableOk, _, unreliableReport = unreliableBatch:Flush()
	assert(unreliableOk and unreliableReport.unreliableHandoffs == 1 and runtime.fires[1].remote == unreliable)
	assert(BatchFrame.header(runtime.fires[1][2], 900).kind == 1)

	local firstCalls, secondCalls = 0, 0
	assert(client.events.Push:Connect(function(value)
		firstCalls += 1
		if value == 31 then coroutine.yield() end
	end))
	assert(client.events.StatePush:Connect(function(value)
		assert(value == 4)
		secondCalls += 1
	end))
	reliable.OnClientEvent:fire(0, envelope(1, { body("Push", 21) }))
	assert(firstCalls == 1)
	runtime:flush()

	local malformedScan = truncatedSecond(1, body("Push", 22), body("BooleanPush", true))
	reliable.OnClientEvent:fire(0, malformedScan)
	local scanSnapshot = client:GetDiagnostics()
	assert(firstCalls == 1 and scanSnapshot.counters.invalidPayload == 1
		and scanSnapshot.events.Push.invalidPayload == 0,
		"scan failures have no authoritative failing event row")

	local malformedBoolean = buffer.create(4)
	buffer.writeu8(malformedBoolean, 0, 1)
	buffer.writeu16(malformedBoolean, 1, 15)
	buffer.writeu8(malformedBoolean, 3, 2)
	reliable.OnClientEvent:fire(0, envelope(1, { body("Push", 22), malformedBoolean }))
	runtime:flush()
	assert(firstCalls == 1 and secondCalls == 0,
		"client also completes all decoding before starting any callback")
	assert(client:GetDiagnostics().counters.invalidPayload == 2)

	reliable.OnClientEvent:fire(0, envelope(1, { body("Push", 23), body("Push", 24) }))
	assert(firstCalls == 3 and client:GetDiagnostics().events.Push.busy == 0,
		"same-endpoint records both start when the preceding handler returns")
	reliable.OnClientEvent:fire(0, envelope(1, { body("Push", 31), body("Push", 32) }))
	assert(firstCalls == 4 and client:GetDiagnostics().events.Push.busy == 1,
		"a yielding same-endpoint handler retains its lease and drops the repeated record")
	local yieldingClientThread = runtime.spawnedThreads[#runtime.spawnedThreads]
	local resumed, resumeProblem = coroutine.resume(yieldingClientThread)
	assert(resumed, resumeProblem and tostring(resumeProblem))
	assert(client:GetDiagnostics().inFlight == 0)

	local statePacket = envelope(2, { body("StatePush", 4) }, "Unreliable")
	unreliable.OnClientEvent:fire(0, statePacket)
	runtime:flush()
	assert(secondCalls == 1)
	client:Destroy()
end

-- Client batch scan failures retain resolver-known endpoint and channel reasons.
do
	local runtime, client, reliable, unreliable = clientSetup()
	local calls = 0
	assert(client.events.Push:Connect(function() calls += 1 end))
	reliable.OnClientEvent:fire(0, envelope(2, { body("Push", 1) }))
	unreliable.OnClientEvent:fire(0, envelope(1, { body("Push", 2) }, "Unreliable"))
	local snapshot = client:GetDiagnostics()
	assert(calls == 0 and snapshot.counters.invalidPayload == 0
		and snapshot.counters.invalidEndpoint == 1 and snapshot.counters.wrongChannel == 1,
		"scan rejections preserve session-level endpoint and channel reasons")
	client:Destroy()
end

-- A client Once handler may install a replacement that receives the next record.
do
	local runtime, client, reliable = clientSetup()
	local values = {}
	assert(client.events.Push:Once(function(value)
		values[#values + 1] = `once:{value}`
		assert(client.events.Push:Connect(function(replacementValue)
			values[#values + 1] = `replacement:{replacementValue}`
		end))
	end))
	reliable.OnClientEvent:fire(0, envelope(1, { body("Push", 1), body("Push", 2) }))
	assert(values[1] == "once:1" and values[2] == "replacement:2")
	client:Destroy()
end

-- Destroy from the first client record prevents the later record from starting.
do
	local runtime, client, reliable = clientSetup()
	local starts = {}
	assert(client.events.Push:Connect(function()
		starts[#starts + 1] = "first"
		client:Destroy()
	end))
	assert(client.events.BooleanPush:Connect(function() starts[#starts + 1] = "second" end))
	reliable.OnClientEvent:fire(0, envelope(1, { body("Push", 1), body("BooleanPush", true) }))
	assert(starts[1] == "first" and starts[2] == nil and client:GetDiagnostics().state == "Destroyed")
end

do
	local limited = { inboundRate = {
		perPlayer = { capacity = 2, refillPerSecond = 1 },
		aggregate = { capacity = 2, refillPerSecond = 1 },
	} }
	local runtime, server, player, _, _, reliable = serverSetup(limited)
	local continuationRan, replacementCalls, handlerThread = false, 0, nil
	local connection = assert(server.events.First:Connect(function()
		handlerThread = coroutine.running()
		coroutine.yield()
		continuationRan = true
	end))
	local packet = envelope(1, { body("First", 7) })
	reliable.OnServerEvent:Fire(player, 0, packet)
	assert(handlerThread and coroutine.status(handlerThread) == "suspended"
		and server:GetDiagnostics().inFlight == 1)
	assert(coroutine.close(handlerThread) and coroutine.status(handlerThread) == "dead")
	assert(not continuationRan and server:GetDiagnostics().inFlight == 1)
	connection:Disconnect()
	assert(server.events.First:Connect(function() replacementCalls += 1 end))
	reliable.OnServerEvent:Fire(player, 0, packet)
	local closedDiagnostics = server:GetDiagnostics()
	assert(replacementCalls == 0 and closedDiagnostics.inFlight == 1
		and closedDiagnostics.events.First.busy == 1 and closedDiagnostics.counters.busy == 1)
	reliable.OnServerEvent:Fire(player, 0, packet)
	assert(server:GetDiagnostics().counters.perPlayerRate == 1,
		"the busy rejection still spends the remaining per-player admission token")
	runtime:removePlayer(player)
	assert(server:GetDiagnostics().inFlight == 0, "player removal clears the closed FIFO reservation")
	runtime.now = 1
	local freshPlayer = runtime:addPlayer()
	reliable.OnServerEvent:Fire(freshPlayer, 0, packet)
	assert(replacementCalls == 1 and server:GetDiagnostics().inFlight == 0,
		"a fresh Player can use the replacement FIFO listener after removal")
	server:Destroy()
end

do
	local runtime, client, _, unreliable = clientSetup()
	local continuationRan, replacementCalls = false, 0
	local connection = assert(client.events.StatePush:Connect(function(value)
		assert(value == 7)
		coroutine.yield()
		continuationRan = true
	end))
	local packet = envelope(2, { body("StatePush", 7) }, "Unreliable")
	unreliable.OnClientEvent:fire(0, packet)
	local handlerThread = runtime.spawnedThreads[#runtime.spawnedThreads]
	assert(handlerThread and coroutine.status(handlerThread) == "suspended"
		and client:GetDiagnostics().inFlight == 1)
	assert(coroutine.close(handlerThread) and coroutine.status(handlerThread) == "dead")
	assert(not continuationRan and client:GetDiagnostics().inFlight == 1)
	connection:Disconnect()
	assert(client.events.StatePush:Connect(function() replacementCalls += 1 end))
	unreliable.OnClientEvent:fire(0, envelope(2, { body("StatePush", 8) }, "Unreliable"))
	local closedDiagnostics = client:GetDiagnostics()
	assert(replacementCalls == 0 and closedDiagnostics.inFlight == 1
		and closedDiagnostics.events.StatePush.busy == 1 and closedDiagnostics.counters.busy == 1)
	client:Destroy()
	assert(client:GetDiagnostics().inFlight == 0, "Destroy clears a closed State reservation")

	local freshClient = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
	assert(freshClient.events.StatePush:Connect(function(value)
		assert(value == 9)
		replacementCalls += 1
	end))
	assert(freshClient:Start())
	unreliable.OnClientEvent:fire(0, envelope(2, { body("StatePush", 9) }, "Unreliable"))
	assert(replacementCalls == 1 and freshClient:GetDiagnostics().inFlight == 0,
		"a fresh client session can receive State after cleanup")
	freshClient:Destroy()
end

print("PASS Relay.BatchSession routing, admission, leases, audiences, and cleanup")
