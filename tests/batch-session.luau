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
		ImmediatePush = { id = 14, direction = "ServerToClient",
			fields = { { name = "value", type = "u8" } } },
		BooleanPush = { id = 15, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "boolean" } } },
		Spare16 = { id = 16, direction = "ClientToServer", queue = "Batch", fields = {} },
		Spare17 = { id = 17, direction = "ClientToServer", queue = "Batch", fields = {} },
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

-- Public batch creation snapshots actual recipients and hands one bounded format-2 envelope to each.
do
	local _, unstarted, player = serverWithoutStart()
	assertCode("NotStarted", unstarted:CreateBatch({ player }, 0.02))
	unstarted:Destroy()

	local runtime, server, first, second, third = serverSetup()
	assertCode("InvalidOptions", server:CreateBatch({}, 0))
	assertCode("InvalidAudience", server:CreateBatch({ [1] = first, [3] = second }, 0.02))
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
	assert(server:GetDiagnostics().counters.aggregateRate == 3 and calls == 0
		and server:GetDiagnostics().counters.perPlayerRate == 0,
		"player debits preceding aggregate exhaustion are retained")
	reliable.OnServerEvent:Fire(hostile, 6, 3)
	assert(server:GetDiagnostics().counters.perPlayerRate == 1 and calls == 0)
	server:Destroy()
end

-- Dispatch starts each admitted record before reserving the next endpoint lease.
do
	local runtime, server, player, _, _, reliable = serverSetup()
	local names = { "First", "Second", "Toggle", "Spare7", "Spare8", "Spare9", "Spare10", "Spare16", "Spare17" }
	local bodies = table.create(#names)
	for index, name in names do
		assert(server.events[name]:Connect(function() coroutine.yield() end))
		if name == "First" or name == "Second" then
			bodies[index] = body(name, 1)
		elseif name == "Toggle" then
			bodies[index] = body(name, true)
		else
			bodies[index] = body(name)
		end
	end
	reliable.OnServerEvent:Fire(player, 0, envelope(1, bodies))
	assert(#runtime.spawnedThreads == 8 and server:GetDiagnostics().inFlight == 8)
	assert(server:GetDiagnostics().events.Spare17.busy == 1,
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
	assert(values[1] == 1 and values[2] == 2 and server:GetDiagnostics().events.First.busy == 0
		and server:GetDiagnostics().inFlight == 0)
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

-- Client sends batches through endpoint zero and validates whole incoming envelopes before callbacks.
do
	local runtime, client, reliable, unreliable = clientSetup()
	assertCode("InvalidOptions", client:CreateBatch(math.huge))
	local batch = assert(client:CreateBatch(0.02))
	assert(batch.events.First:Send(12))
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
    local firstCalls = 0	assert(client.events.Push:Connect(function(value)
		firstCalls += 1
		if value == 31 then coroutine.yield() end
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
	assert(firstCalls == 1,
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
	client:Destroy()
end

-- Client batch scan failures retain resolver-known endpoint and channel reasons.
do
	local runtime, client, reliable, unreliable = clientSetup()
	local calls = 0
	assert(client.events.Push:Connect(function() calls += 1 end))
	local unsupportedKind = envelope(1, { body("Push", 1) })
	buffer.writeu8(unsupportedKind, 1, 2)
	reliable.OnClientEvent:fire(0, unsupportedKind)
	unreliable.OnClientEvent:fire(0, envelope(1, { body("Push", 2) }, "Unreliable"))
	local snapshot = client:GetDiagnostics()
	assert(calls == 0 and snapshot.counters.invalidPayload == 1
		and snapshot.counters.invalidEndpoint == 0 and snapshot.counters.wrongChannel == 1,
		"unsupported State kind rejects before endpoint resolution; channel mismatch remains distinct")
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

print("PASS Relay.BatchSession routing, admission, leases, audiences, and cleanup")
