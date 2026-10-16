local CpuProfile = require("../quick/CpuProfile")
local snapshot = buffer.create(1)

local function makeLib(steps: { any }, options: any?)
	options = options or {}
	local counts = {
		opened = 0,
		frameFetches = 0,
		threadFetches = 0,
		timerFetches = 0,
		threadArrayDisposed = false,
		iteratorDisposed = false,
		sessionDisposed = false,
		stepCalls = 0,
	}
	local stepIndex = 0
	local function entry()
		if options.alwaysSteps then
			return { frameId = 3, absoluteId = 103, threadId = 11, timerId = 99, timestamp = stepIndex,
				boundary = false, gpu = false, enter = false, exit = false, label = true, event = false,
				unknown = false, underflow = false, overflow = false, wasOverflowed = false, depth = 0 }
		end
		return steps[stepIndex]
	end
	local state = {}
	for name, field in {
		FrameId = "frameId", FrameAbsoluteId = "absoluteId", ThreadId = "threadId", TimerId = "timerId",
		Timestamp = "timestamp", IsFrameBoundary = "boundary", IsGpuThread = "gpu", IsEnter = "enter",
		IsExit = "exit", IsLabel = "label", IsEvent = "event", IsUnknown = "unknown",
		ThreadStackIsUnderflowed = "underflow", ThreadStackIsOverflowed = "overflow",
		ThreadStackWasOverflowed = "wasOverflowed", ThreadStackDepth = "depth",
	} do
		state[name] = function()
			if options.readErrorAt == stepIndex then error("state read failed", 0) end
			return entry()[field]
		end
	end
	local iterator = {
		Configure = function(_, config)
			assert(config.SkipGpuThreads and config.SkipTimestampNormalization == false)
			assert(config.TimerIds[1] == 7 and #config.ThreadIds == 1 and config.ThreadIds[1] == 11)
		end,
		GetState = function() return state end,
		Step = function()
			stepIndex += 1
			counts.stepCalls += 1
			if options.stepErrorAt == stepIndex then error("iterator step failed", 0) end
			if options.alwaysSteps then return true end
			return stepIndex <= #steps
		end,
		Dispose = function() counts.iteratorDisposed = true end,
	}
	local session = {
		IsValid = function() return true end,
		GetDataFormatVersion = function() return options.sessionFormat or CpuProfile.FORMAT end,
		FetchGlobalDesc = function() return { TickToMsCpu = 0.25 } end,
		GetFrameIdMin = function() return 1 end,
		GetFrameIdMax = function() return 3 end,
		FetchFrameDesc = function(_, frameId)
			counts.frameFetches += 1
			return { FrameId = frameId, FrameAbsoluteId = frameId + 100, TickStartCpu = 1, TickEndCpu = 10,
				IsPaused = false, IsIncomplete = false }
		end,
		GetThreadIds = function()
			return {
				Size = function() return 2 end,
				Get = function(_, index) return ({ 11, 12 })[index + 1] end,
				Dispose = function() counts.threadArrayDisposed = true end,
			}
		end,
		FetchThreadDesc = function(_, threadId)
			counts.threadFetches += 1
			return { ThreadId = threadId, ThreadName = if threadId == 11 then "Main" else "GPU", IsGpu = threadId == 12 }
		end,
		FindTimerIds = function(_, marker, caseSensitive)
			assert(caseSensitive == true)
			if marker == "Work" then return { 7 } end
			assert(options.stages, "unexpected stage query")
			return if marker == "Work/sv" then { 8 } else { 9 }
		end,
		FetchTimerDesc = function(_, timerId)
			counts.timerFetches += 1
			return { TimerId = timerId, TimerName = if timerId == 7 then "Work"
				else if timerId == 8 then "Work/sv" else "Work/sh" }
		end,
		CreateLogIterator = function() return iterator end,
		Dispose = function() counts.sessionDisposed = true end,
	}
	local lib = {
		Versions = { DataFormat = options.libraryFormat or CpuProfile.FORMAT },
		Enums = { ContainerFormat = { Compressed = 1 } },
		Session = { OpenFromBuffer = function(value)
			counts.opened += 1
			assert(value == (options.snapshot or snapshot))
			return session
		end },
	}
	return lib, counts
end

local function event(kind: string, timestamp: number, options: any?)
	options = options or {}
	return {
		frameId = options.frameId or 3, absoluteId = options.absoluteId or 103,
		threadId = options.threadId or 11, timerId = options.timerId or 7, timestamp = timestamp,
		boundary = false, gpu = false, enter = kind == "enter", exit = kind == "exit",
		label = kind == "label", event = kind == "event", unknown = false, underflow = false,
		overflow = false, wasOverflowed = false, depth = 0,
	}
end

local lib, counts = makeLib({ event("enter", 100), event("exit", 120) })
local report = CpuProfile.read(lib, snapshot, "Work")
assert(report.status == "observed" and report.pairCount == 1 and #report.pairs == 1
	and report.scan.state == "step-false-incomplete",
	`pair result: {report.status}/{report.reason}/{report.pairCount}/{report.scan.state}`)
local pair = report.pairs[1]
assert(pair.enterStep == 1 and pair.exitStep == 2 and pair.timerId == 7 and pair.threadId == 11)
assert(pair.frameId == 3 and pair.absoluteFrameId == 103 and pair.durationMs == 5)
assert(report.absenceProven == false and report.rankingQualified == false and report.timingQualified == false)
assert(counts.threadArrayDisposed and counts.iteratorDisposed and counts.sessionDisposed)
assert(counts.frameFetches == 3 and counts.threadFetches == 2 and counts.timerFetches == 1)
assert(#report.slowFrames == 3 and report.slowFrames[1].frameId == 1
	and report.slowFrames[1].durationMs == 2.25, "slow frames use the CPU tick scale and deterministic tie order")
local stagesLib = makeLib({ event("enter", 100), event("enter", 110, { timerId = 8 }),
	event("exit", 120, { timerId = 8 }), event("enter", 130, { timerId = 9 }),
	event("exit", 140, { timerId = 9 }), event("exit", 150) }, { stages = true })
local stages = CpuProfile.read(stagesLib, snapshot, "Work", "Work")
assert(stages.pairCount == 1 and stages.meanDurationMs == 12.5 and #stages.stages == 2)
assert(stages.stages[1].pairCount == 1 and stages.stages[1].totalDurationMs == 2.5
	and stages.stages[2].pairCount == 1 and stages.stages[2].totalDurationMs == 2.5,
	"stage totals must remain separate from inclusive marked-work totals")
local rendered = CpuProfile.render(stages)
assert(string.find(rendered, "scan=step-false-incomplete (partial)", 1, true)
	and string.find(rendered, "send.validate-encode: 1 pairs", 1, true)
	and string.find(rendered, "slow frames in scanned window", 1, true)
	and string.find(rendered, "timing/ranking unqualified", 1, true), "compact reports retain capture limits")
local invalidPrefix = CpuProfile.read(stagesLib, snapshot, "Work", "Other")
assert(invalidPrefix.status == "failed" and invalidPrefix.reason == "stage-prefix-invalid")
local metadataLib = makeLib({ event("enter", 100), event("label", 0), event("event", 0), event("exit", 120) })
local metadataReport = CpuProfile.read(metadataLib, snapshot, "Work")
assert(metadataReport.status == "observed" and metadataReport.pairCount == 1
	and metadataReport.meanDurationMs == 5, "zero-timestamp metadata must not invalidate ordered CPU scopes")
local backwardsLib = makeLib({ event("enter", 100), event("exit", 90) })
local backwards = CpuProfile.read(backwardsLib, snapshot, "Work")
assert(backwards.status == "failed" and backwards.reason == "timestamp-backwards",
	"backward timestamps on actual CPU scopes must still fail")
for _, absoluteId in { 103, 104 } do
	local terminal = event("boundary", 125, { frameId = 4, absoluteId = absoluteId })
	terminal.boundary = true
	local terminalLib = makeLib({ event("enter", 100), event("exit", 120), terminal })
	local terminalReport = CpuProfile.read(terminalLib, snapshot, "Work")
	assert(terminalReport.status == "observed" and terminalReport.pairCount == 1
		and terminalReport.scan.frameBoundaries == 1 and terminalReport.scan.state == "step-false-incomplete",
		"terminal boundaries may retain the final absolute frame or advance once")
end
local invalidTerminal = event("boundary", 125, { frameId = 4, absoluteId = 105 })
invalidTerminal.boundary = true
local invalidTerminalLib = makeLib({ event("enter", 100), event("exit", 120), invalidTerminal })
local invalidTerminalReport = CpuProfile.read(invalidTerminalLib, snapshot, "Work")
assert(invalidTerminalReport.status == "failed" and invalidTerminalReport.reason == "terminal-boundary-invalid"
	and invalidTerminalReport.pairCount == 1, "unrelated terminal frame IDs must fail while preserving observed pairs")

local stepErrorLib, stepErrorCounts = makeLib({ event("enter", 100), event("exit", 120) }, { stepErrorAt = 3 })
local stepError = CpuProfile.read(stepErrorLib, snapshot, "Work")
assert(stepError.status == "failed" and stepError.reason == "iterator-step-failed" and stepError.pairCount == 1,
	"a step failure after a valid pair must fail while preserving the partial pair")
assert(#stepError.pairs == 1 and stepError.absenceProven == false
	and stepError.rankingQualified == false and stepError.timingQualified == false)
assert(stepErrorCounts.threadArrayDisposed and stepErrorCounts.iteratorDisposed and stepErrorCounts.sessionDisposed,
	"all LibMP resources must be disposed after an iterator step exception")

local readErrorLib, readErrorCounts = makeLib({ event("enter", 100), event("exit", 120), event("label", 130) },
	{ readErrorAt = 3 })
local readError = CpuProfile.read(readErrorLib, snapshot, "Work")
assert(readError.status == "failed" and readError.reason == "iterator-state-read-failed" and readError.pairCount == 1,
	"a state read failure after a valid pair must fail while preserving the partial pair")
assert(#readError.pairs == 1 and readError.absenceProven == false
	and readError.rankingQualified == false and readError.timingQualified == false)
assert(readErrorCounts.threadArrayDisposed and readErrorCounts.iteratorDisposed and readErrorCounts.sessionDisposed,
	"all LibMP resources must be disposed after a state read exception")

local wrongFormat, wrongCounts = makeLib({}, { libraryFormat = CpuProfile.FORMAT - 1 })
local wrong = CpuProfile.read(wrongFormat, snapshot, "Work")
assert(wrong.status == "failed" and wrong.reason == "library-format-mismatch")
assert(wrongCounts.opened == 0 and wrongCounts.frameFetches == 0 and wrongCounts.threadFetches == 0,
	"library format must be checked before session traversal")

local wrongSessionFormat, wrongSessionCounts = makeLib({}, { sessionFormat = CpuProfile.FORMAT - 1 })
local wrongSession = CpuProfile.read(wrongSessionFormat, snapshot, "Work")
assert(wrongSession.status == "failed" and wrongSession.reason == "session-format-mismatch")
assert(wrongSessionCounts.opened == 1 and wrongSessionCounts.frameFetches == 0
	and wrongSessionCounts.threadFetches == 0 and wrongSessionCounts.timerFetches == 0,
	"session format must be checked before descriptor traversal")

local emptyLib = makeLib({})
local empty = CpuProfile.read(emptyLib, snapshot, "Work")
assert(empty.status == "incomplete" and empty.scan.state == "step-false-incomplete")
assert(empty.absenceProven == false and empty.reason == "no-pair-observed")

local descriptorOnlyLib = makeLib({ event("label", 100) })
local descriptorOnly = CpuProfile.read(descriptorOnlyLib, snapshot, "Work")
assert(descriptorOnly.status == "incomplete" and descriptorOnly.pairCount == 0)
assert(descriptorOnly.absenceProven == false, "descriptor-only steps do not prove an absent pair")

local cappedLib = makeLib({}, { alwaysSteps = true })
local capped = CpuProfile.read(cappedLib, snapshot, "Work")
assert(capped.status == "incomplete" and capped.scan.state == "step-cap")
assert(capped.scan.stepCalls == 32_768 and capped.absenceProven == false)

local invalid = event("label", 100)
invalid.unknown = true
local invalidLib, invalidCounts = makeLib({ invalid })
local invalidReport = CpuProfile.read(invalidLib, snapshot, "Work")
assert(invalidReport.status == "failed" and invalidReport.reason == "unknown-log-state")
assert(invalidCounts.threadArrayDisposed and invalidCounts.iteratorDisposed and invalidCounts.sessionDisposed,
	"all LibMP resources must be disposed after a reader failure")

local captureLib, captureCounts = makeLib({ event("enter", 100), event("exit", 120) })
local controlCalls = {}
captureLib.Control = {
	IsBackendReady = function() table.insert(controlCalls, "ready"); return true end,
	SetFrameLimit = function(_, frameLimit) table.insert(controlCalls, "limit:" .. frameLimit); return true end,
	EnableProfiler = function(_, enabled) table.insert(controlCalls, "profiler:" .. tostring(enabled)); return true end,
	ShowUI = function(_, visible) table.insert(controlCalls, "ui:" .. tostring(visible)); return true end,
	EnableCapture = function(_, enabled) table.insert(controlCalls, "capture:" .. tostring(enabled)); return true end,
	CaptureToBufferSync = function(_, params)
		assert(params.ContainerFormat == 1)
		table.insert(controlCalls, "snapshot")
		return snapshot
	end,
}
local capture = CpuProfile.new(captureLib)
assert(capture:begin())
local captureReport = capture:finish("Work")
assert(captureReport.status == "observed" and capture:latestSnapshot() == snapshot)
assert(capture:close())
assert(table.concat(controlCalls, ",") == "ready,limit:16,profiler:true,ui:true,capture:true,capture:false,snapshot,capture:false,ui:false,profiler:false")
assert(captureCounts.sessionDisposed and captureCounts.iteratorDisposed)

local senderSnapshot, receiverSnapshot = buffer.create(1), buffer.create(2)
local lateScopes = { event("enter", 100), event("exit", 120) }
local senderLib = makeLib(lateScopes, { snapshot = senderSnapshot })
local receiverLib = makeLib(lateScopes, { snapshot = receiverSnapshot })
local sharedCaptureEnabled, sharedSnapshot = false, senderSnapshot
local sharedControl = {
	IsBackendReady = function() return true end,
	SetFrameLimit = function() return true end,
	EnableProfiler = function() return true end,
	ShowUI = function() return true end,
	EnableCapture = function(_, enabled) sharedCaptureEnabled = enabled; return true end,
	CaptureToBufferSync = function(_, params)
		assert(params.ContainerFormat == 1)
		return sharedSnapshot
	end,
}
senderLib.Control, receiverLib.Control = sharedControl, sharedControl
local senderCapture, receiverCapture = CpuProfile.new(senderLib), CpuProfile.new(receiverLib)
senderCapture:begin()
receiverCapture:begin()
local senderRaceReport = senderCapture:finish("Work", nil, false)
assert(senderRaceReport.status == "observed" and sharedCaptureEnabled,
	"sender snapshot must leave the shared capture running for late receiver scopes")
table.insert(lateScopes, event("enter", 130))
table.insert(lateScopes, event("exit", 150))
sharedSnapshot = receiverSnapshot
local receiverRaceReport = receiverCapture:finish("Work")
assert(receiverRaceReport.status == "observed" and receiverRaceReport.pairCount == 2
	and not sharedCaptureEnabled, "receiver finish must include late scopes and pause the shared capture")
assert(senderCapture:latestSnapshot() == senderSnapshot and receiverCapture:latestSnapshot() == receiverSnapshot,
	"finishing the receiver must not replace the sender's retained snapshot")
senderCapture:close()
receiverCapture:close()

local repeated = CpuProfile.new(captureLib)
repeated:begin()
repeated:finish("Work")
assert(repeated:latestSnapshot() == snapshot)
repeated:begin()
assert(repeated:latestSnapshot() == nil, "a new phase must not expose the previous snapshot")
captureLib.Control.CaptureToBufferSync = function(_, params)
	assert(params.ContainerFormat == 1)
	error("capture failed", 0)
end
local failedCapture = repeated:finish("Work")
assert(failedCapture.status == "failed" and failedCapture.reason == "snapshot-capture-failed"
	and repeated:latestSnapshot() == nil, "failed capture must not expose stale bytes")

print("LibMP CPU profile checks passed")
