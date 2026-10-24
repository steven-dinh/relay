--!strict

local FORMAT = 65_537
local MAXIMUM_U32 = 4_294_967_295
local MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991
local MAXIMUM_SNAPSHOT_BYTES = 4 * 1024 * 1024
local MAXIMUM_FRAMES = 32
local MAXIMUM_SCAN_FRAMES = 8
local MAXIMUM_THREADS = 128
local MAXIMUM_TIMER_IDS = 8
local MAXIMUM_STEPS = 32_768
local MAXIMUM_DEPTH = 128
local MAXIMUM_PAIRS = 128
local SEND_STAGES = { "send.validate-encode", "send.handoff" }
local RECEIVE_STAGES = { "receive.total", "receive.validate-decode", "receive.dispatch" }
local STAGE_SUFFIXES: { [string]: string } = { ["send.validate-encode"] = "sv", ["send.handoff"] = "sh",
	["receive.total"] = "rt", ["receive.validate-decode"] = "rv", ["receive.dispatch"] = "rd" }

type PendingScope = {
	frameId: number,
	absoluteId: number,
	timestamp: number,
	step: number,
}
type PendingScopesByTimer = { [number]: { PendingScope } }
type PendingScopesByThread = { [number]: PendingScopesByTimer }

local CpuProfile = {
	FORMAT = FORMAT,
	SDK_REVISION = "23573b949ed027fdf8820f969bea525b96c357cc",
	SDK_SHA256 = "236fea082f323facd08109f9fd6dab70350bd0cc69617e07cc194778415a0bb8",
}

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: any, maximum: number): boolean
	return type(value) == "number" and value >= 0 and value <= maximum and value % 1 == 0
end

local function isU32(value: any): boolean
	return isInteger(value, MAXIMUM_U32)
end

local function isDenseArray(value: any, maximum: number): number?
	if type(value) ~= "table" then return nil end
	local count, highest = 0, 0
	for key in next, value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > maximum then return nil end
		count += 1
		highest = math.max(highest, key)
	end
	return if count == highest then count else nil
end

local function baseReport(marker: any): any
	return {
		kind = "LibMPCpuProfileV1",
		status = "incomplete",
		reason = "not-started",
		exactMarker = if type(marker) == "string" and #marker <= 128 then marker else "invalid",
		snapshotBytes = 0,
		formatPair = { library = 0, session = 0 },
		frameWindow = { min = 0, max = 0, count = 0 },
		frames = {},
		slowFrames = {},
		stages = {},
		threadCount = 0,
		cpuThreadCount = 0,
		timers = {},
		scan = { state = "not-started", stepCalls = 0, frameBoundaries = 0, pairsCapped = false },
		pairCount = 0,
		pairs = {},
		meanDurationMs = nil,
		maxDurationMs = nil,
		absenceProven = false,
		rankingQualified = false,
		timingQualified = false,
		measurement = "instrumented-scope-observations",
	}
end

local function read(lib: any, snapshot: any, exactMarker: any, stagePrefix: string?): any
	local report = baseReport(exactMarker)
	local session: any = nil
	local iterator: any = nil
	local threadIds: any = nil
	local failureReason = ""
	local failureStatus = "failed"
	local function stop(reason: string, status: string?): never
		failureReason, failureStatus = reason, status or "failed"
		error(reason, 0)
	end
	local runOk, runError = pcall(function()
		if type(lib) ~= "table" or type(lib.Versions) ~= "table" then stop("library-invalid") end
		local libraryFormat = lib.Versions.DataFormat
		report.formatPair.library = if isU32(libraryFormat) then libraryFormat else 0
		if libraryFormat ~= FORMAT then stop("library-format-mismatch") end
		if type(exactMarker) ~= "string" or #exactMarker == 0 or #exactMarker > 128 then
			stop("exact-marker-invalid")
		end
		if stagePrefix ~= nil and (type(stagePrefix) ~= "string" or #stagePrefix == 0 or #stagePrefix > 60
			or (exactMarker ~= stagePrefix and exactMarker ~= stagePrefix .. "/rt")) then
			stop("stage-prefix-invalid")
		end
		if typeof(snapshot) ~= "buffer" then stop("snapshot-invalid") end
		local snapshotBytes = buffer.len(snapshot)
		report.snapshotBytes = snapshotBytes
		if snapshotBytes == 0 then stop("snapshot-empty") end
		if snapshotBytes > MAXIMUM_SNAPSHOT_BYTES then stop("snapshot-over-acceptance-limit") end
		if type(lib.Session) ~= "table" or type(lib.Session.OpenFromBuffer) ~= "function" then
			stop("session-api-missing")
		end
		session = lib.Session.OpenFromBuffer(snapshot)
		if session == nil or session:IsValid() ~= true then stop("session-invalid") end
		local sessionFormat = session:GetDataFormatVersion()
		report.formatPair.session = if isU32(sessionFormat) then sessionFormat else 0
		if sessionFormat ~= FORMAT then stop("session-format-mismatch") end

		local global = session:FetchGlobalDesc()
		local tickToMsCpu = if type(global) == "table" then global.TickToMsCpu else nil
		if not isFinite(tickToMsCpu) or tickToMsCpu <= 0 then stop("cpu-tick-scale-invalid") end

		local frameMin, frameMax = session:GetFrameIdMin(), session:GetFrameIdMax()
		if not isU32(frameMin) or not isU32(frameMax) or frameMax < frameMin then
			stop("frame-window-invalid")
		end
		local frameCount = frameMax - frameMin + 1
		report.frameWindow = { min = frameMin, max = frameMax, count = frameCount }
		if frameCount > MAXIMUM_FRAMES then stop("frame-window-over-limit") end
		local scanMin = math.max(frameMin, frameMax - MAXIMUM_SCAN_FRAMES + 1)
		local framesById = {}
		local previousAbsolute = nil
		for frameId = frameMin, frameMax do
			local desc = session:FetchFrameDesc(frameId)
			if type(desc) ~= "table" or desc.FrameId ~= frameId or not isU32(desc.FrameAbsoluteId)
				or type(desc.IsPaused) ~= "boolean" or type(desc.IsIncomplete) ~= "boolean"
				or not isFinite(desc.TickStartCpu) or not isFinite(desc.TickEndCpu)
				or desc.TickStartCpu < 0 or desc.TickEndCpu < desc.TickStartCpu
			then
				stop("frame-descriptor-invalid")
			end
			if desc.IsPaused or desc.IsIncomplete then stop("frame-paused-or-incomplete") end
			if previousAbsolute ~= nil and desc.FrameAbsoluteId ~= previousAbsolute + 1 then
				stop("frame-mapping-inconsistent")
			end
			previousAbsolute = desc.FrameAbsoluteId
			framesById[frameId] = { frameId = frameId, absoluteId = desc.FrameAbsoluteId,
				durationMs = (desc.TickEndCpu - desc.TickStartCpu) * tickToMsCpu }
			if not isFinite(framesById[frameId].durationMs) then stop("frame-duration-invalid") end
			if frameId >= scanMin then
				report.frames[#report.frames + 1] = framesById[frameId]
			end
		end
		local slowFrames = table.clone(report.frames)
		table.sort(slowFrames, function(left: any, right: any)
			return if left.durationMs == right.durationMs then left.frameId < right.frameId
				else left.durationMs > right.durationMs
		end)
		for index = 1, math.min(3, #slowFrames) do report.slowFrames[index] = slowFrames[index] end

		threadIds = session:GetThreadIds()
		if threadIds == nil then stop("thread-array-missing") end
		local threadCount = threadIds:Size()
		if not isInteger(threadCount, MAXIMUM_THREADS) then stop("thread-count-invalid") end
		report.threadCount = threadCount
		local threadSet, cpuIds = {}, {}
		for index = 0, threadCount - 1 do
			local threadId = threadIds:Get(index)
			if not isU32(threadId) or threadId == 0 or threadSet[threadId] then
				stop("thread-id-invalid")
			end
			threadSet[threadId] = true
			local desc = session:FetchThreadDesc(threadId)
			if type(desc) ~= "table" or desc.ThreadId ~= threadId or type(desc.ThreadName) ~= "string"
				or #desc.ThreadName > 128 or type(desc.IsGpu) ~= "boolean"
			then
				stop("thread-descriptor-invalid")
			end
			if not desc.IsGpu then cpuIds[#cpuIds + 1] = threadId end
		end
		local disposedIds = pcall(function() threadIds:Dispose() end)
		threadIds = nil
		if not disposedIds then stop("thread-array-dispose-failed") end
		report.cpuThreadCount = #cpuIds
		if #cpuIds == 0 then stop("no-cpu-threads", "incomplete") end

		local timerIds = session:FindTimerIds(exactMarker, true)
		local timerCount = isDenseArray(timerIds, MAXIMUM_TIMER_IDS)
		if timerCount == nil then stop("timer-array-invalid") end
		local exactTimerCount = timerCount :: number
		local exactTimers = {}
		for index = 1, exactTimerCount do
			local timerId = timerIds[index]
			if not isU32(timerId) or timerId == 0 or exactTimers[timerId] then stop("timer-id-invalid") end
			local desc = session:FetchTimerDesc(timerId)
			if type(desc) ~= "table" or desc.TimerId ~= timerId or desc.TimerName ~= exactMarker then
				stop("timer-descriptor-invalid")
			end
			exactTimers[timerId] = true
			report.timers[#report.timers + 1] = { id = timerId, name = desc.TimerName }
		end
		if exactTimerCount == 0 then stop("exact-timer-not-found", "incomplete") end
		local stageByTimer: { [number]: { name: string, pairCount: number, totalDurationMs: number, maxDurationMs: number } } = {}
		if stagePrefix ~= nil then
			local names = if exactMarker == stagePrefix then SEND_STAGES else RECEIVE_STAGES
			for _, name in names do
				local stage = { name = name, pairCount = 0, totalDurationMs = 0, maxDurationMs = 0 }
				report.stages[#report.stages + 1] = stage
				local marker = stagePrefix .. "/" .. STAGE_SUFFIXES[name]
				local ids = if marker == exactMarker then table.clone(timerIds) else session:FindTimerIds(marker, true)
				local count = isDenseArray(ids, MAXIMUM_TIMER_IDS)
				if count == nil then stop("stage-timer-array-invalid") end
				for _, id in ids do
					if not isU32(id) or id == 0 or stageByTimer[id] ~= nil then stop("stage-timer-id-invalid") end
					local desc = session:FetchTimerDesc(id)
					if type(desc) ~= "table" or desc.TimerId ~= id or desc.TimerName ~= marker then
						stop("stage-timer-descriptor-invalid")
					end
					stageByTimer[id] = stage
					if not exactTimers[id] then
						timerIds[#timerIds + 1] = id
						if #timerIds > 32 then stop("stage-timer-count-over-limit") end
					end
				end
			end
		end

		iterator = session:CreateLogIterator()
		if iterator == nil then stop("log-iterator-missing") end
		iterator:Configure({
			StartFrameId = scanMin,
			EndFrameId = frameMax,
			SkipGpuThreads = true,
			SkipEvents = false,
			SkipFrameBoundaries = false,
			SkipTimestampNormalization = false,
			EmitThreadFrameEnd = false,
			ThreadIds = cpuIds,
			TimerIds = timerIds,
		})
		local state = iterator:GetState()
		if state == nil then stop("log-state-missing") end
		local pending: PendingScopesByThread = {}
		local pendingCounts: { [number]: number } = {}
		local previousTimestamps: { [number]: number } = {}
		local durationTotal, durationMax = 0, 0
		report.scan.state = "scanning"
		for stepNumber = 1, MAXIMUM_STEPS do
			report.scan.stepCalls = stepNumber
			local stepOk, stepped = pcall(function() return iterator:Step() end)
			if not stepOk then
				report.scan.state = "step-error"
				failureReason = "iterator-step-failed"
				break
			end
			if stepped == false then
				report.scan.state = "step-false-incomplete"
				break
			end
			if stepped ~= true then stop("iterator-step-result-invalid") end
			local readOk, entry = pcall(function()
				return {
					frameId = state:FrameId(), absoluteId = state:FrameAbsoluteId(), threadId = state:ThreadId(),
					timerId = state:TimerId(), timestamp = state:Timestamp(),
					boundary = state:IsFrameBoundary(), gpu = state:IsGpuThread(),
					enter = state:IsEnter(), exit = state:IsExit(), label = state:IsLabel(),
					event = state:IsEvent(), unknown = state:IsUnknown(),
					underflow = state:ThreadStackIsUnderflowed(),
					overflow = state:ThreadStackIsOverflowed(), wasOverflowed = state:ThreadStackWasOverflowed(),
					depth = state:ThreadStackDepth(),
				}
			end)
			if not readOk then
				report.scan.state = "state-read-error"
				failureReason = "iterator-state-read-failed"
				break
			end
			if not isU32(entry.frameId) or not isU32(entry.absoluteId) or not isU32(entry.threadId)
				or not isU32(entry.timerId) or not isInteger(entry.timestamp, MAXIMUM_SAFE_INTEGER)
				or type(entry.boundary) ~= "boolean" or type(entry.gpu) ~= "boolean"
				or type(entry.enter) ~= "boolean" or type(entry.exit) ~= "boolean"
				or type(entry.label) ~= "boolean" or type(entry.event) ~= "boolean"
				or type(entry.unknown) ~= "boolean" or type(entry.underflow) ~= "boolean"
				or type(entry.overflow) ~= "boolean" or type(entry.wasOverflowed) ~= "boolean"
				or not isInteger(entry.depth, MAXIMUM_DEPTH)
			then
				stop("iterator-state-invalid")
			end
			if entry.gpu then stop("gpu-thread-in-cpu-scan") end
			if entry.unknown then stop("unknown-log-state") end
			if entry.underflow then stop("thread-stack-underflow") end
			if entry.overflow or entry.wasOverflowed then
				stop("thread-stack-overflow")
			end
			if entry.boundary then
				local mapped = framesById[entry.frameId]
				if entry.frameId == frameMax + 1 then
					mapped = framesById[frameMax]
					-- The native terminal boundary can retain the final absolute frame.
					if mapped == nil or (entry.absoluteId ~= mapped.absoluteId and entry.absoluteId ~= mapped.absoluteId + 1) then
						stop("terminal-boundary-invalid")
					end
				elseif entry.frameId < scanMin or entry.frameId > frameMax or mapped == nil
					or entry.absoluteId ~= mapped.absoluteId
				then
					stop("frame-boundary-invalid")
				end
				report.scan.frameBoundaries += 1
				continue
			end
			local frame = framesById[entry.frameId]
			local kindCount = (if entry.enter then 1 else 0) + (if entry.exit then 1 else 0)
				+ (if entry.label then 1 else 0) + (if entry.event then 1 else 0)
			if kindCount > 1 or entry.threadId == 0 or not threadSet[entry.threadId]
				or frame == nil or entry.frameId < scanMin or entry.frameId > frameMax
			then
				stop("log-record-outside-window")
			end
			if frame.absoluteId ~= entry.absoluteId then stop("log-frame-mapping-mismatch") end
			if entry.enter or entry.exit then
				-- Labels/events have no scope timestamp (the native SDK returns 0).
				local lastTimestamp = previousTimestamps[entry.threadId]
				if lastTimestamp ~= nil and entry.timestamp < lastTimestamp then stop("timestamp-backwards") end
				previousTimestamps[entry.threadId] = entry.timestamp
				if exactTimers[entry.timerId] or stageByTimer[entry.timerId] ~= nil then
					local byTimer: PendingScopesByTimer
					local existingByTimer = pending[entry.threadId]
					if existingByTimer == nil then
						byTimer = {}
						pending[entry.threadId] = byTimer
					else
						byTimer = existingByTimer
					end
					local stack: { PendingScope }
					local existingStack = byTimer[entry.timerId]
					if existingStack == nil then
						stack = {}
						byTimer[entry.timerId] = stack
					else
						stack = existingStack
					end
					if entry.enter then
						local count = (pendingCounts[entry.threadId] or 0) + 1
						if count > MAXIMUM_DEPTH then stop("pending-scope-depth-over-limit") end
						pendingCounts[entry.threadId] = count
						stack[#stack + 1] = {
							frameId = entry.frameId, absoluteId = entry.absoluteId,
							timestamp = entry.timestamp, step = stepNumber,
						}
					elseif #stack > 0 then
						local entered = table.remove(stack) :: PendingScope
						pendingCounts[entry.threadId] -= 1
						if entered.frameId == entry.frameId and entered.absoluteId == entry.absoluteId
							and entered.step < stepNumber
						then
							local durationMs = (entry.timestamp - entered.timestamp) * tickToMsCpu
						if not isFinite(durationMs) or durationMs < 0 then stop("duration-invalid") end
							local stage = stageByTimer[entry.timerId]
							if stage ~= nil then
								stage.pairCount += 1
								stage.totalDurationMs += durationMs
								stage.maxDurationMs = math.max(stage.maxDurationMs, durationMs)
							end
							if exactTimers[entry.timerId] then
						report.pairCount += 1
						durationTotal += durationMs
						durationMax = math.max(durationMax, durationMs)
						if #report.pairs < MAXIMUM_PAIRS then
							report.pairs[#report.pairs + 1] = {
								frameId = entry.frameId, absoluteFrameId = entry.absoluteId,
								threadId = entry.threadId, timerId = entry.timerId,
								enterStep = entered.step, exitStep = stepNumber,
							durationMs = durationMs,
							}
						else
							report.scan.pairsCapped = true
						end
							end
					end
				end
			end
		end
		end
		if report.scan.state == "scanning" then report.scan.state = "step-cap" end
		if report.pairCount > 0 then
			report.status = "observed"
			report.reason = ""
			report.meanDurationMs = durationTotal / report.pairCount
			report.maxDurationMs = durationMax
		else
			report.status = "incomplete"
			report.reason = if failureReason ~= "" then failureReason else "no-pair-observed"
		end
		if failureReason ~= "" then
			report.status, report.reason = failureStatus, failureReason
		end
	end)
	if not runOk then
		if failureReason == "" then failureReason = string.sub(tostring(runError), 1, 256) end
		report.status = failureStatus
		report.reason = if failureReason ~= "" then failureReason else "analysis-operation-failed"
	end
	if threadIds ~= nil then
		local disposed = pcall(function() threadIds:Dispose() end)
		if not disposed then failureReason = "thread-array-dispose-failed" end
	end
	if iterator ~= nil then
		local disposed = pcall(function() iterator:Dispose() end)
		if not disposed then failureReason = "iterator-dispose-failed" end
	end
	if session ~= nil then
		local disposed = pcall(function() session:Dispose() end)
		if not disposed then failureReason = "session-dispose-failed" end
	end
	if failureReason == "thread-array-dispose-failed" or failureReason == "iterator-dispose-failed"
		or failureReason == "session-dispose-failed"
	then
		report.status, report.reason = "cleanup-failed", failureReason
	end
	return report
end

CpuProfile.read = read

-- Timings are inclusive observations from a bounded window, never a sum of
-- parent/child scopes or an estimate of CPU utilization.
function CpuProfile.render(report: any): string
	local lines = { string.format("[LibMP %s] %s | scan=%s (partial) | pairs=%d | timing/ranking unqualified",
		report.side or "client", report.status, report.scan.state, report.pairCount) }
	if report.reason ~= "" then lines[#lines + 1] = "  reason: " .. report.reason end
	if report.meanDurationMs ~= nil then
		lines[#lines + 1] = string.format("  marked work: mean %.4f ms; max %.4f ms", report.meanDurationMs, report.maxDurationMs)
	end
	for _, stage in report.stages do
		lines[#lines + 1] = if stage.pairCount == 0 then "  " .. stage.name .. ": no pair observed"
			else string.format("  %s: %d pairs; inclusive mean %.4f ms; max %.4f ms", stage.name,
				stage.pairCount, stage.totalDurationMs / stage.pairCount, stage.maxDurationMs)
	end
	local slow = {}
	for _, frame in report.slowFrames do
		slow[#slow + 1] = string.format("#%d %.2f ms", frame.absoluteId, frame.durationMs)
	end
	if #slow > 0 then lines[#lines + 1] = "  slow frames in scanned window: " .. table.concat(slow, ", ") end
	return table.concat(lines, "\n")
end

local Capture: any = {}
Capture.__index = Capture

function Capture.begin(self: any)
	assert(not self.closed and not self.capturing, "LibMP capture is unavailable")
	self.snapshot = nil
	self.capturing = true
	local ok, enabled = pcall(function() return self.control:EnableCapture(true) end)
	if not ok or enabled ~= true then
		self:close()
		error("LibMP capture enable failed", 0)
	end
	return true
end

function Capture.finish(self: any, exactMarker: string, stagePrefix: string?, pauseCapture: boolean?): any
	assert(not self.closed and self.capturing, "LibMP capture is not active")
	self.capturing = false
	if pauseCapture ~= false then
		local pauseOk, paused = pcall(function() return self.control:EnableCapture(false) end)
		if not pauseOk or paused ~= true then
			self:close()
			local report = baseReport(exactMarker)
			report.status, report.reason = "failed", "capture-pause-failed"
			return report
		end
	end
	local captureOk, snapshot = pcall(function()
		return self.control:CaptureToBufferSync({ ContainerFormat = self.lib.Enums.ContainerFormat.Compressed })
	end)
	if not captureOk or typeof(snapshot) ~= "buffer" then
		self:close()
		local report = baseReport(exactMarker)
		report.status, report.reason = "failed", "snapshot-capture-failed"
		return report
	end
	if buffer.len(snapshot) <= MAXIMUM_SNAPSHOT_BYTES then
		self.snapshot = snapshot
	else
		self.snapshot = nil
	end
	return read(self.lib, snapshot, exactMarker, stagePrefix)
end

function Capture.latestSnapshot(self: any): any
	return self.snapshot
end

function Capture.close(self: any): (boolean, string?)
	if self.closed then return true, nil end
	self.closed = true
	local firstFailure = nil
	for _, action in {
		function() return self.control:EnableCapture(false) end,
		function() return self.control:ShowUI(false) end,
		function() return self.control:EnableProfiler(false) end,
	} do
		local ok, result = pcall(action)
		if (not ok or result == false) and firstFailure == nil then firstFailure = "libmp-cleanup-failed" end
	end
	self.capturing = false
	return firstFailure == nil, firstFailure
end

function CpuProfile.new(lib: any): any
	assert(type(lib) == "table" and type(lib.Versions) == "table", "LibMP library is invalid")
	assert(lib.Versions.DataFormat == FORMAT, "LibMP data format mismatch")
	local control = lib.Control
	assert(type(control) == "table" and type(control.IsBackendReady) == "function"
		and type(control.SetFrameLimit) == "function" and type(control.EnableProfiler) == "function"
		and type(control.ShowUI) == "function" and type(control.EnableCapture) == "function"
		and type(control.CaptureToBufferSync) == "function", "LibMP control API is incomplete")
	local readyOk, ready = pcall(function() return control:IsBackendReady() end)
	assert(readyOk and ready == true, "LibMP backend is not ready")
	local capture = setmetatable({
		lib = lib,
		control = control,
		capturing = false,
		closed = false,
		snapshot = nil,
	}, Capture)
	local ok, reason = pcall(function()
		-- Compression limits retained bytes; the reader also accepts older 32-frame buffers.
		assert(control:SetFrameLimit(16) == true, "LibMP frame limit rejected")
		assert(control:EnableProfiler(true) == true, "LibMP profiler enable failed")
		assert(control:ShowUI(true) == true, "LibMP profiler UI failed")
	end)
	if not ok then
		capture:close()
		error(reason, 0)
	end
	return capture
end

return CpuProfile
