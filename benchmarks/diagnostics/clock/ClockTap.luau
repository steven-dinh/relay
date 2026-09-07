-- Diagnostic overlay only. The original protocol remains an unchanged sibling.
local Original = require("./ClockDiagnosticOriginal")
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
		kind = "RelayClockDiagnostic", version = 1, launchId = binding.runId,
		adapterId = binding.adapterId, caseId = binding.caseId, recipientCount = 4,
		rankingEligible = false, measuredWorkStarted = false, warmupStarted = false,
		readinessReplyCount = 0, readinessTail = {}, formalReplies = {},
	}
	local finished = false
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
		lastRead = nil
		local result = original.command(...)
		if intent.kind == "ClockReadinessChallenge" or intent.kind == "ClockChallenge" then
			before[index] = lastRead or { status = "NotRead" }
			if result.kind == "ClockProofFailed" then
				finish("ClockRejected", { stage = "Command", participantIndex = index,
					reason = "ServerReadRejected", serverRead = before[index] })
			end
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
			end
			if body.messageType == "ClockReadinessReply" then
				report.readinessReplyCount += 1
				if #report.readinessTail == 32 then table.remove(report.readinessTail, 1) end
				table.insert(report.readinessTail, sample)
			else
				assert(#report.formalReplies < 4, "CLOCK_DIAGNOSTIC_E_REPLY_COUNT")
				table.insert(report.formalReplies, sample)
			end
			if result.kind == "ClockProofFailed" then
				local reason = if received.status ~= "Accepted" then "ServerReadRejected"
					elseif sent == nil or sent.status ~= "Accepted" then "MissingSendRead"
					elseif sample.clientSeconds < sent.seconds then "ClientBeforeServerSend"
					elseif sample.clientSeconds > received.seconds then "ClientAfterServerReceive"
					else "Unclassified"
				finish("ClockRejected", { stage = "Reply", participantIndex = index, reason = reason })
			elseif #report.formalReplies == 4 then
				finish("ClockAccepted")
			end
		end
		return result
	end
	local wrapped = table.clone(ready)
	wrapped.coordinator = table.freeze(coordinator)
	return table.freeze(wrapped)
end

return table.freeze(observed)
