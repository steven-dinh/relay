local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local ClientRuntime = require("./support/ClientRuntime")
local NativeRuntime = require("./support/NativeCodec")
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		require = function(path) assert(path == "./CompositeCodec"); return CompositeCodec end,
	},
	injectGlobals = true,
})()

local definition = assert(Definition.define({
	name = "PacedBatcherProof",
	version = 1,
	events = {
		Alpha = { id = 1, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		Beta = { id = 2, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		Unreliable = { id = 3, direction = "ClientToServer", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		StateInput = { id = 4, direction = "ClientToServer", queue = "State",
			fields = { { name = "value", type = "u8" } } },
		Large = { id = 5, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "buffer", maximumBytes = 1_024 } } },
		Immediate = { id = 6, direction = "ClientToServer",
			fields = { { name = "value", type = "u8" } } },
		Push = { id = 7, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		LargeReliable = { id = 8, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "buffer", maximumBytes = 8_182 } } },
		LargeUnreliable = { id = 9, direction = "ClientToServer", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "buffer", maximumBytes = 890 } } },
		Reference = { id = 10, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "Instance", className = "BasePart" } } },
		ManyReferences = { id = 11, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "array", maximumLength = 16,
				element = { type = "Instance", className = "BasePart" } } } },
		Empty = { id = 12, direction = "ClientToServer", queue = "Batch", fields = {} },
	},
}))
local compiled = assert(Definition.get(definition))

local function assertCode(expected, ok, problem)
	assert((ok == nil or ok == false) and problem ~= nil and problem.code == expected,
		`expected {expected}, got {if problem then problem.code else "success"}`)
end

local function setup()
	local runtime = ClientRuntime.create()
	local root, _, reliable, unreliable = runtime:transport(compiled.descriptor, true)
	local client = assert(runtime.module.create(definition, { startupTimeoutSeconds = 3 }))
	assert(client:Start())
	return runtime, client, root, reliable, unreliable
end

local function timerCount(runtime)
	local count = 0
	for _ in runtime.timers do count += 1 end
	return count
end

local function packetRows(fire, delivery)
	local limit = if delivery == "Unreliable" then 900 else 8_192
	local references = if fire.n > 2 then { n = fire.n - 2 } else nil
	if references ~= nil then
		for index = 1, references.n do references[index] = fire[index + 2] end
	end
	local packet = fire[2]
	local header = assert(BatchFrame.header(packet, limit, references))
	assert(header.kind == 1)
	local rows = assert(BatchFrame.scan(packet, header, function(id)
		return compiled.queuedById[id]
	end, references))
	local values = table.create(#rows)
	for index, row in rows do
		local body, rowReferences = BatchFrame.readBody(packet, row, references)
		assert(body ~= nil)
		local decode = Frame.compile(row.event, "decode")
		local decoded = if rowReferences == nil then table.pack(decode(body))
			else table.pack(decode(body, table.unpack(rowReferences, 1, rowReferences.n)))
		assert(decoded[1] == true)
		values[index] = { id = row.event.id, value = decoded[2] }
	end
	return values
end

local function frameParts(fire, delivery)
	local limit = if delivery == "Unreliable" then 900 else 8_192
	local references = if fire.n > 2 then { n = fire.n - 2 } else nil
	if references ~= nil then
		for index = 1, references.n do references[index] = fire[index + 2] end
	end
	local header = assert(BatchFrame.header(fire[2], limit, references))
	local rows = assert(BatchFrame.scan(fire[2], header, function(id)
		return compiled.queuedById[id]
	end, references))
	return header, rows, references, limit
end

-- Constructor validation, eligible event surface, pacing and one packet per populated channel.
do
	local runtime, client, _, reliable, unreliable = setup()
	assertCode("InvalidOptions", client:CreatePacedBatcher(0.01))
	assertCode("InvalidOptions", client:CreatePacedBatcher(math.huge))
	assertCode("InvalidOptions", client:CreatePacedBatcher(0 / 0))
	assertCode("InvalidOptions", client:CreatePacedBatcher(0.02, { manual = 1 }))
	assertCode("InvalidOptions", client:CreatePacedBatcher(0.02, { manual = false, extra = true }))
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	assertCode("QueueLimit", client:CreatePacedBatcher(0.02))
	local ordinary = assert(client:CreateBatch(0.02))
	ordinary:Cancel()
	assert(pacer.events.Alpha ~= nil and pacer.events.StateInput ~= nil
		and pacer.events.Unreliable ~= nil and pacer.events.Immediate == nil and pacer.events.Push == nil)
	assert(pacer.events.Alpha:Send(11))
	assert(pacer.events.Beta:Send(12))
	assert(pacer.events.StateInput:Send(13))
	assert(pacer.events.Unreliable:Send(14))
	assert(timerCount(runtime) == 0 and #runtime.fires == 0, "manual pacers do not schedule timers or send early")
	local early, _, earlyReport = pacer:Step()
	assert(early and earlyReport.selected == 0 and earlyReport.remaining == 4 and #runtime.fires == 0)
	runtime:advance(0.02)
	local ok, _, finalReport = pacer:Step()
	assert(ok and finalReport.selected == 4 and finalReport.reliableHandoffs == 1
		and finalReport.unreliableHandoffs == 1 and #runtime.fires == 2)
	assert(runtime.fires[1].remote == reliable and runtime.fires[2].remote == unreliable)
	local reliableRows = packetRows(runtime.fires[1], "Reliable")
	local unreliableRows = packetRows(runtime.fires[2], "Unreliable")
	assert(#reliableRows == 3 and reliableRows[1].id == 1 and reliableRows[1].value == 11
		and reliableRows[2].id == 2 and reliableRows[2].value == 12
		and reliableRows[3].id == 4 and reliableRows[3].value == 13)
	assert(#unreliableRows == 1 and unreliableRows[1].value == 14)
	local status = pacer:GetStatus()
	assert(status.pendingRecords == 0 and status.pendingUnits == 0 and status.manual
		and status.lastStep.report.selected == 4)
	client:Destroy()
end

-- Automatic mode waits a full interval; a delayed callback makes one bounded round without catch-up.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.03))
	for value = 1, 33 do assert(pacer.events.Alpha:Send(value % 256)) end
	assert(#runtime.fires == 0 and timerCount(runtime) == 1)
	local earlyTimer = runtime:collectTimers()
	runtime:resumeTimers(earlyTimer)
	assert(#runtime.fires == 0 and timerCount(runtime) == 1,
		"an unexpectedly early scheduler callback preserves the original due time")
	runtime:advance(0.029)
	assert(#runtime.fires == 0)
	runtime.pausedTimers = true
	runtime:advance(0.2)
	runtime.pausedTimers = false
	runtime:runTimers()
	local firstRound = if #runtime.fires > 0 then packetRows(runtime.fires[1], "Reliable") else {}
	assert(#runtime.fires == 1 and #firstRound == 32
		and firstRound[1].value == 1 and firstRound[32].value == 32)
	assert(pacer:GetStatus().pendingRecords == 1 and timerCount(runtime) == 1,
		"a late timer sends at most one 32-row packet and schedules from the current time")
	runtime:runTimers()
	assert(#runtime.fires == 1, "late execution does not cause catch-up sends")
	runtime:advance(0.03)
	assert(#runtime.fires == 2 and pacer:GetStatus().pendingRecords == 0)
	client:Destroy()
end

-- The combined retained-body cap is enforced atomically before appending a buffer event.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	local payload = buffer.create(1_024)
	for _ = 1, 31 do assert(pacer.events.Large:Send(payload)) end
	assertCode("QueueFull", pacer.events.Large:Send(payload))
	local status = pacer:GetStatus()
	assert(status.pendingRecords == 31 and status.pendingUnits == 31 * (3 + 2 + 1_024),
		"a QueueFull refusal retains no partial body or record")
	client:Destroy()
end

-- Packet selection honors exact modeled byte limits and upgrades the header when references join.
do
	local runtime, client, _, reliable, unreliable = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	local scope = roblox.Instance.new("Folder")
	scope.Parent = NativeRuntime.World
	local part = roblox.Instance.new("Part")
	part.Parent = scope
	local exactPrimitiveBody = buffer.create(8_162)
	assert(pacer.events.LargeReliable:Send(exactPrimitiveBody))
	assert(pacer.events.Reference:Send(part))
	assert(pacer.events.Empty:Send())
	runtime:advance(0.02)
	local ok, _, firstReport = pacer:Step()
	local reliableFire = runtime.fires[1]
	local reliableHeader, reliableRows, reliableReferences = frameParts(reliableFire, "Reliable")
	assert(ok and firstReport.selected == 2 and reliableFire.remote == reliable
		and reliableHeader.format == 5 and reliableHeader.count == 2
		and reliableHeader.referenceCount == 1 and reliableReferences[1] == part
		and reliableRows[1].event.id == compiled.events.LargeReliable.id
		and reliableRows[1].length == 8_167 and reliableRows[2].event.id == compiled.events.Reference.id
		and reliableRows[2].length == 5 and buffer.len(reliableFire[2]) + 8 == 8_188
		and pacer:GetStatus().pendingRecords == 1,
		"the reference row upgrades the fresh header from three to four bytes, so a 5-unit next row stays pending")
	runtime:advance(0.02)
	local nextOk, _, nextReport = pacer:Step()
	local nextHeader, nextRows = frameParts(runtime.fires[2], "Reliable")
	assert(nextOk and nextReport.selected == 1 and nextHeader.count == 1
		and nextRows[1].event.id == compiled.events.Empty.id and runtime.fires[2].remote == reliable
		and pacer:GetStatus().pendingRecords == 0,
		"the first row that cannot fit remains FIFO-pending for the next interval")
	pacer:Destroy()

	local exactPacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	assert(exactPacer.events.LargeReliable:Send(buffer.create(8_182)))
	assert(exactPacer.events.Alpha:Send(1))
	runtime:advance(0.02)
	local exactOk, _, exactReport = exactPacer:Step()
	local exactHeader = assert(BatchFrame.header(runtime.fires[3][2], 8_192))
	assert(exactOk and exactReport.selected == 1 and exactHeader.count == 1
		and buffer.len(runtime.fires[3][2]) == 8_192 and exactPacer:GetStatus().pendingRecords == 1,
		"a reliable maximum-sized row fills the exact 8192-byte modeled packet")
	runtime:advance(0.02)
	assert(exactPacer:Step() and exactPacer:GetStatus().pendingRecords == 0)
	exactPacer:Destroy()

	local unreliablePacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	assert(unreliablePacer.events.LargeUnreliable:Send(buffer.create(890)))
	assert(unreliablePacer.events.LargeUnreliable:Send(buffer.create(1)))
	runtime:advance(0.02)
	local unreliableOk, _, unreliableReport = unreliablePacer:Step()
	local unreliableFire = runtime.fires[5]
	local unreliableHeader, unreliableRows = frameParts(unreliableFire, "Unreliable")
	assert(unreliableOk and unreliableReport.selected == 1 and unreliableFire.remote == unreliable
		and unreliableHeader.count == 1 and unreliableRows[1].length == 895
		and buffer.len(unreliableFire[2]) == 900 and unreliablePacer:GetStatus().pendingRecords == 1,
		"an unreliable packet stops exactly at the 900-byte modeled limit")
	runtime:advance(0.02)
	assert(unreliablePacer:Step() and #runtime.fires == 6
		and unreliablePacer:GetStatus().pendingRecords == 0)
	client:Destroy()
	scope:Destroy()
end

-- A 16-reference packet cap splits before the seventeenth sidecar and preserves FIFO.
do
	local runtime, client, _, reliable = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	local scope = roblox.Instance.new("Folder")
	scope.Parent = NativeRuntime.World
	local part = roblox.Instance.new("Part")
	part.Parent = scope
	assert(pacer.events.ManyReferences:Send(table.create(16, part)))
	assert(pacer.events.Reference:Send(part))
	runtime:advance(0.02)
	local ok, _, report = pacer:Step()
	local fire = runtime.fires[1]
	local header, rows, references = frameParts(fire, "Reliable")
	assert(ok and report.selected == 1 and fire.remote == reliable and fire.n == 18
		and header.format == 5 and header.count == 1 and header.referenceCount == 16
		and rows[1].event.id == compiled.events.ManyReferences.id
		and buffer.len(fire[2]) + header.referenceCount * 8 <= 8_192
		and #references == 16 and pacer:GetStatus().pendingRecords == 1,
		"the first packet contains exactly sixteen references and leaves the seventeenth reference row pending")
	runtime:advance(0.02)
	local nextOk, _, nextReport = pacer:Step()
	local nextHeader = assert(BatchFrame.header(runtime.fires[2][2], 8_192,
		{ n = 1, runtime.fires[2][3] }))
	assert(nextOk and nextReport.selected == 1 and nextHeader.referenceCount == 1
		and #runtime.fires == 2 and pacer:GetStatus().pendingRecords == 0)
	client:Destroy()
	scope:Destroy()
end

-- A reference that leaves the client's live Instance scope after enqueue is consumed without handoff or replay.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	local scope = roblox.Instance.new("Folder")
	scope.Parent = NativeRuntime.World
	local moving = roblox.Instance.new("Part")
	moving.Parent = scope
	assert(pacer.events.Reference:Send(moving))
	moving.Parent = nil
	runtime:advance(0.02)
	local ok, problem, report = pacer:Step()
	assert(not ok and problem.code == "InvalidPayload" and report.selected == 1
		and report.reliableHandoffs == 0 and #runtime.fires == 0
		and pacer:GetStatus().state == "Terminal" and pacer:GetStatus().pendingRecords == 0,
		"the send-time Instance scope recheck consumes the stale reference and refuses native handoff")
	local retry, retryProblem = pacer:Step()
	assert(not retry and retryProblem.code == "InvalidPayload" and #runtime.fires == 0,
		"a stale reference frame is never replayed")
	client:Destroy()
	scope:Destroy()
end

-- The hard record cap is session-wide, and a shared flush lock returns QueueBusy without consuming.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	for _ = 1, 128 do assert(pacer.events.Alpha:Send(1)) end
	assertCode("QueueFull", pacer.events.Alpha:Send(2))
	assert(pacer:GetStatus().pendingRecords == 128)
	local full = pacer:GetStatus()
	assert(full.pendingUnits == 128 * 4)
	pacer:Destroy()
	local queued = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	assert(queued.events.Alpha:Send(7))
	runtime:advance(0.02)
	local ordinary = assert(client:CreateBatch(0.02))
	assert(ordinary.events.Alpha:Send(9))
	local nested
	runtime.onFire = function()
		if nested == nil then nested = table.pack(queued:Step()) end
	end
	assert(ordinary:Flush())
	assertCode("QueueBusy", nested[1], nested[2])
	assert(nested[3].selected == 0 and nested[3].remaining == 1
		and queued:GetStatus().pendingRecords == 1)
	runtime.onFire = nil
	runtime:advance(0.02)
	local ok, _, sent = queued:Step()
	assert(ok and sent.selected == 1 and #runtime.fires == 2)
	client:Destroy()
end

-- Uncertain transport failure consumes selected work and terminally prevents replay.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	assert(pacer.events.Alpha:Send(33))
	runtime:advance(0.02)
	runtime.failFire = true
	local ok, problem = pacer:Step()
	assert(not ok and problem.code == "TransportFailure" and pacer:GetStatus().state == "Terminal"
		and pacer:GetStatus().pendingRecords == 0)
	runtime.failFire = false
	local retry, retryProblem = pacer:Step()
	assert(not retry and retryProblem.code == "TransportFailure" and #runtime.fires == 0,
		"a failed FireServer call is never replayed")
	client:Destroy()
end

-- Reentrant Destroy after one channel handoff prevents the queued second channel from sending.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02, { manual = true }))
	assert(pacer.events.Alpha:Send(1) and pacer.events.Unreliable:Send(2))
	runtime:advance(0.02)
	runtime.onFire = function()
		runtime.onFire = nil
		pacer:Destroy()
	end
	local ok, problem, finalReport = pacer:Step()
	assert(not ok and problem.code == "Cancelled" and finalReport.selected == 2
		and finalReport.reliableHandoffs == 1 and finalReport.unreliableHandoffs == 0
		and #runtime.fires == 1 and pacer:GetStatus().pendingRecords == 0,
		"Destroy during a handoff prevents any later channel send")
	client:Destroy()
end

-- Destroy and session loss invalidate pending timers and release retained payloads.
do
	local runtime, client = setup()
	local pacer = assert(client:CreatePacedBatcher(0.02))
	assert(pacer.events.Alpha:Send(1) and timerCount(runtime) == 1)
	local staleTimers = runtime:collectTimers()
	runtime.ignoreTimerCancel = true
	pacer:Destroy()
	assert(pacer:GetStatus().pendingRecords == 0 and timerCount(runtime) == 0)
	runtime:resumeTimers(staleTimers)
	assert(#runtime.fires == 0, "a stale timer cannot flush a destroyed pacer")
	client:Destroy()

	local disconnectedRuntime, disconnectedClient, root = setup()
	local disconnected = assert(disconnectedClient:CreatePacedBatcher(0.02))
	assert(disconnected.events.Alpha:Send(2))
	root.Name = "damaged"
	disconnectedRuntime:advance(0.02)
	assert(disconnected:GetStatus().state == "Terminal" and disconnected:GetStatus().pendingRecords == 0
		and #disconnectedRuntime.fires == 0 and disconnectedClient:GetDiagnostics().state == "Disconnected",
		"transport loss destroys the pacer before its queued frame can send")
	disconnectedClient:Destroy()
end

print("PASS Relay.PacedBatcher limits, channel FIFO, pacing, backpressure and cleanup")
