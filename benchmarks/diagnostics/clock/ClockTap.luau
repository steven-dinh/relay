-- Diagnostic-only 3 ms candidate. The measured protocol remains unchanged.
local Original = require("./ClockDiagnosticCandidate")
local observed = table.clone(Original)

local function finite(value)
	return type(value) == "number" and value == value and value >= 0
		and value < math.huge and not (value == 0 and 1 / value == -math.huge)
end

function observed.newCoordinator(...)
	local arguments = table.pack(...)
	local binding, roster, sharedNow = arguments[1], arguments[2], arguments[3]
	assert(binding.adapterId == "relay-reliable" and binding.caseId == "state-broadcast-s2c"
		and binding.recipientCount == 4, "CLOCK_DIAGNOSTIC_E_SELECTION")
	local report = {
		kind = "RelayClockDiagnostic", version = 2, launchId = binding.runId, toleranceMilliseconds = 3,
		adapterId = binding.adapterId, caseId = binding.caseId, recipientCount = 4,
		rankingEligible = false, measuredWorkStarted = false, warmupStarted = false,
		readinessReplyCount = 0, readinessTail = {}, formalReplies = {},
		readinessStrictOutsideCount = 0, readinessToleranceOutsideCount = 0,
		readinessMaxViolationMilliseconds = 0, readinessPhaseMilliseconds = 0,
	}
	local finished = false
	local readinessStarted, formalSentCount = nil, 0
	local previous, lastRead
	local before = {}
	local indices = {}
	for index, player in roster do indices[player] = index end
	arguments[3] = function()
		local ok, value = pcall(sharedNow)
		local status = if not ok then "Threw" elseif not finite(value) then "Invalid"
			elseif previous ~= nil and value < previous then "Regressed" else "Accepted"
		lastRead = { status = status, previousSeconds = previous }
		if finite(value) then lastRead.seconds = value end
		if status == "Accepted" then previous = value end
		if not ok then error(value, 0) end
		return value
	end
	local ready = Original.newCoordinator(table.unpack(arguments, 1, arguments.n))
	if ready.kind ~= "Ready" then return ready end
	local original = ready.coordinator
	local coordinator = table.clone(original)
	local function finish(status, rejection)
		if not finished then
			finished = true
			report.status, report.rejection = status, rejection
			local http = game:GetService("HttpService")
			game:GetService("StudioTestService"):EndTest(http:JSONEncode(report))
		end
		-- Never return a final reply/begin-warmup command to the measured runner.
		-- The host owns a 180-second process deadline if EndTest cannot complete.
		coroutine.yield()
		error("CLOCK_DIAGNOSTIC_E_RESUMED", 0)
	end
	coordinator.command = function(...)
		local index, intent = ...
		if finished or intent.kind == "BeginWarmup" or intent.kind == "ArmMeasured" then
			finish("BoundaryStopped")
		end
		if intent.kind == "ClockReadinessChallenge" and readinessStarted == nil then readinessStarted = os.clock() end
		if intent.kind == "ClockChallenge" and formalSentCount == 0 then
			report.readinessPhaseMilliseconds = (os.clock() - readinessStarted) * 1000
		end
		lastRead = nil
		local result = original.command(...)
		if intent.kind == "ClockReadinessChallenge" or intent.kind == "ClockChallenge" then
			before[index] = lastRead or { status = "NotRead" }
			if result.kind == "ClockProofFailed" then
				finish("ClockRejected", { stage = "Command", participantIndex = index,
					reason = "ServerReadRejected", serverRead = before[index] })
			end
			if intent.kind == "ClockChallenge" and result.kind == "Ready" then formalSentCount += 1 end
		end
		return result
	end
	coordinator.receive = function(player, ...)
		if finished then finish(report.status) end
		lastRead = nil
		local result = original.receive(player, ...)
		local body = if select("#", ...) == 1 then select(1, ...) else nil
		if type(body) == "table" and (result.kind == "Accepted" or result.kind == "ClockProofFailed")
			and (body.messageType == "ClockReadinessReply" or body.messageType == "ClockReply")
		then
			local index = indices[player]
			local sent, received = before[index], lastRead or { status = "NotRead" }
			local sample = {
				participantIndex = index, sequence = body.sequence, phase = body.messageType,
				serverBefore = sent, serverAfter = received, clientSeconds = body.participantSharedSeconds,
				localBeforeSeconds = body.localBeforeSeconds, localAfterSeconds = body.localAfterSeconds,
				protocolAccepted = result.kind == "Accepted",
			}
			if sent ~= nil and sent.status == "Accepted" and received.status == "Accepted" then
				sample.bracketMilliseconds = (received.seconds - sent.seconds) * 1000
				sample.clientMinusBeforeMilliseconds = (sample.clientSeconds - sent.seconds) * 1000
				sample.clientMinusAfterMilliseconds = (sample.clientSeconds - received.seconds) * 1000
				sample.inBracket = sample.clientSeconds >= sent.seconds and sample.clientSeconds <= received.seconds
				sample.violationMilliseconds = math.max(0, -sample.clientMinusBeforeMilliseconds, sample.clientMinusAfterMilliseconds)
				sample.withinTolerance = sample.violationMilliseconds <= 3
			end
			if body.messageType == "ClockReadinessReply" then
				report.readinessReplyCount += 1
				report.readinessPhaseMilliseconds = (os.clock() - readinessStarted) * 1000
				if sample.violationMilliseconds ~= nil then
					if not sample.inBracket then report.readinessStrictOutsideCount += 1 end
					if not sample.withinTolerance then report.readinessToleranceOutsideCount += 1 end
					report.readinessMaxViolationMilliseconds = math.max(report.readinessMaxViolationMilliseconds, sample.violationMilliseconds)
				end
				if #report.readinessTail == 32 then table.remove(report.readinessTail, 1) end
				table.insert(report.readinessTail, sample)
			else
				assert(formalSentCount == 4, "CLOCK_DIAGNOSTIC_E_INCOMPLETE_CHALLENGE")
				assert(#report.formalReplies < 4, "CLOCK_DIAGNOSTIC_E_REPLY_COUNT")
				table.insert(report.formalReplies, sample)
			end
			if result.kind == "ClockProofFailed" then
				local reason = if received.status ~= "Accepted" then "ServerReadRejected"
					elseif sent == nil or sent.status ~= "Accepted" then "MissingSendRead"
					elseif sample.clientSeconds < sent.seconds then "ClientBeforeServerSend"
					elseif sample.clientSeconds > received.seconds then "ClientAfterServerReceive"
					else "Unclassified"
				report.rejection = report.rejection or { stage = "Reply", participantIndex = index, reason = reason }
				if body.messageType == "ClockReadinessReply" then finish("ClockRejected", report.rejection) end
			end
			if #report.formalReplies == 4 then
				finish(if report.rejection == nil then "ClockAccepted" else "ClockRejected", report.rejection)
			end
			if result.kind == "ClockProofFailed" then
				-- Preserve the candidate's failure; keep only the outer wait alive
				-- until the other already-issued formal replies can be captured.
				return table.freeze({ kind = "Ignored" })
			end
		end
		return result
	end
	local wrapped = table.clone(ready)
	wrapped.coordinator = table.freeze(coordinator)
	return table.freeze(wrapped)
end

return table.freeze(observed)
