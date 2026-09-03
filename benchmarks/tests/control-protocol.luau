local ControlProtocol = require("../runner/ControlProtocol")
local Fixtures = require("../fixtures/event-v1")

local function exact(value, keys, label)
	assert(type(value) == "table", label .. " must be a table")
	local allowed = {}
	for _, key in keys do allowed[key] = true end
	local count = 0
	for key in next, value do
		count += 1
		assert(allowed[key], label .. " extra key " .. tostring(key))
	end
	assert(count == #keys, label .. " key count")
end

local function deepFrozen(value, seen)
	if type(value) ~= "table" then return end
	seen = seen or {}
	if seen[value] then return end
	seen[value] = true
	assert(table.isfrozen(value), "value must be deeply frozen")
	for key, nested in next, value do deepFrozen(key, seen); deepFrozen(nested, seen) end
end

local function raises(expected, callback)
	local ok, problem = pcall(callback)
	assert(not ok and tostring(problem) == expected, "expected " .. expected .. ", got " .. tostring(problem))
end

local function binding(caseId, count, index)
	local value = {
		protocolVersion = 1,
		runId = "00000000-0000-4000-8000-000000000001",
		adapterId = "fake-event-v1",
		caseId = caseId,
		recipientCount = count,
	}
	if index then value.participantIndex = index end
	return value
end

local function emptySnapshot()
	return {
		version = 1,
		repetitions = {},
		measurements = {},
		failureFacts = {},
		conformance = {
			setupExcluded = true,
			warmupExcluded = true,
			quiescenceExcluded = true,
			resultExtractionExcluded = true,
			clockProofPassed = true,
		},
	}
end

local function senderSnapshot()
	local values120 = table.create(120, 0.25)
	return {
		version = 1,
		repetitions = {
			{
				repetitionIndex = 1,
				started = true,
				completed = true,
				submitted = 120,
				received = 0,
				correct = 0,
				mismatch = 0,
				duplicate = 0,
				unexpected = 0,
				outOfOrder = 0,
				staleCallbacks = 0,
				observationOverflow = false,
				probeStarted = 0,
				probeSubmitted = 0,
				probeReceived = 0,
				probeCorrect = 0,
				probeMismatch = 0,
				firstSubmissionStartedSharedSeconds = 10,
				finalSubmissionReturnedSharedSeconds = 11,
			},
		},
		measurements = {
			{ measurementIndex = 4, repetitionIndex = 1, values = values120 },
			{ measurementIndex = 5, repetitionIndex = 1, values = { 1 } },
			{ measurementIndex = 10, repetitionIndex = 1, values = table.create(120, 2) },
		},
		failureFacts = {},
		conformance = {
			setupExcluded = true,
			warmupExcluded = true,
			quiescenceExcluded = true,
			resultExtractionExcluded = true,
			clockProofPassed = true,
		},
	}
end

exact(ControlProtocol, { "newCoordinator", "newParticipant" }, "module")
assert(table.isfrozen(ControlProtocol), "module frozen")

do
	local calls = 0
	local collision = ControlProtocol.newCoordinator(binding("tiny-steady-c2s", 1), { {} }, function() return 0 end, function(runId)
		calls += 1
		assert(runId == "00000000-0000-4000-8000-000000000001")
		return false
	end)
	assert(calls == 1 and collision.kind == "Terminated" and collision.termination.code == "RunIdCollision")
	deepFrozen(collision)
end

for _, invalid in {
	{},
	{ protocolVersion = 2, runId = "00000000-0000-4000-8000-000000000001", adapterId = "a", caseId = "tiny-steady-c2s", recipientCount = 1 },
	{ protocolVersion = 1, runId = "BAD", adapterId = "a", caseId = "tiny-steady-c2s", recipientCount = 1 },
	{ protocolVersion = 1, runId = "00000000-0000-4000-8000-000000000001", adapterId = "A", caseId = "tiny-steady-c2s", recipientCount = 1 },
	{ protocolVersion = 1, runId = "00000000-0000-4000-8000-000000000001", adapterId = "a", caseId = "state-broadcast-s2c", recipientCount = 2 },
} do
	raises("CONTROL_PROTOCOL_E_CONFIG", function()
		ControlProtocol.newCoordinator(invalid, { {} }, function() return 0 end, function() return true end)
	end)
end

-- Reversed Bind barriers prove engine-owned 1/4/8 attribution and no early phase advance.
for _, count in { 1, 4, 8 } do
	local tokens, participants = {}, {}
	for index = 1, count do
		tokens[index] = {}
		participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", count, index))
		exact(participants[index], { "receive", "report", "postSimulation", "beginPostTeardownObservation", "disable" }, "participant")
	end
	local created = ControlProtocol.newCoordinator(binding("state-broadcast-s2c", count), tokens, function() return 1 end, function() return true end)
	assert(created.kind == "Ready")
	exact(created.coordinator, { "command", "receive", "postSimulation", "beginPostTeardownObservation", "beginFinalReports", "expireResponse", "disconnect", "disable" }, "coordinator")
	for index = count, 1, -1 do
		local command = created.coordinator.command(index, { kind = "BindCase" })
		assert(command.kind == "Ready" and command.body.participantIndex == index)
		deepFrozen(command)
		assert(participants[index].receive(command.body).kind == "Accepted")
	end
	local reports = {}
	for index = 1, count do reports[index] = participants[index].report({ kind = "BoundReport" }).body end
	for index = count, 1, -1 do
		assert(created.coordinator.receive(tokens[index], reports[index]).kind == "Accepted")
	end
	assert(created.coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	for index = count, 1, -1 do
		local finish = created.coordinator.command(index, { kind = "FinishCase", repetitionIndex = 0, outcome = "Abort" })
		assert(participants[index].receive(finish.body).command.outcome == "Abort")
		local final = participants[index].report({ kind = "FinalReport", snapshot = emptySnapshot() })
		assert(created.coordinator.receive(tokens[index], final.body).event.kind == "FinalReport")
	end
end

-- One complete measured repetition exercises clock bracketing, quiet 59/60, measured fast paths,
-- teardown observation, positive Abort, and canonical evidence copying.
do
	local token = {}
	local clock = 0
	local created = ControlProtocol.newCoordinator(binding("tiny-steady-c2s", 1), { token }, function()
		clock += 1
		return clock
	end, function() return true end)
	local coordinator = created.coordinator
	local participant = ControlProtocol.newParticipant(binding("tiny-steady-c2s", 1, 1))
	local function roundTrip(commandIntent, reportIntent)
		local command = coordinator.command(1, commandIntent)
		assert(participant.receive(command.body).kind == "Accepted")
		local report = participant.report(reportIntent)
		local received = coordinator.receive(token, report.body)
		assert(received.kind == "Accepted")
		return report.body
	end
	roundTrip({ kind = "BindCase" }, { kind = "BoundReport" })
	roundTrip({ kind = "PrepareRepetition", repetitionIndex = 1 }, { kind = "ReadyReport", outcome = "Ready" })
	roundTrip({ kind = "ClockChallenge" }, {
		kind = "ClockReply", participantSharedSeconds = 1.5, localBeforeSeconds = 5, localAfterSeconds = 6,
	})
	roundTrip({ kind = "BeginWarmup", repetitionIndex = 1 }, { kind = "WarmupReport", outcome = "Clean" })
	for frame = 1, 59 do
		assert(not coordinator.postSimulation() and not participant.postSimulation(), "quiet before frame 60")
	end
	assert(coordinator.postSimulation() and participant.postSimulation(), "quiet frame 60")
	local arm = coordinator.command(1, { kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 10 })
	local armResult = participant.receive(arm.body)
	assert(armResult.kind == "Accepted", "arm result " .. tostring(armResult.kind))
	assert(coordinator.command(nil, setmetatable({}, { __index = function() error("read") end })).kind == "MeasuredControlTraffic")
	assert(participant.report(setmetatable({}, { __index = function() error("read") end })).kind == "MeasuredControlTraffic")
	assert(coordinator.receive(token, setmetatable({}, { __index = function() error("read") end }), "extra").kind == "MeasuredControlTraffic")
	assert(coordinator.beginPostTeardownObservation(1, true, true).kind == "Ready")
	participant.beginPostTeardownObservation(1)
	local rep = participant.report({ kind = "RepetitionReport", outcome = "Clean", isolationPassed = true })
	assert(coordinator.receive(token, rep.body).kind == "Accepted")
	assert(coordinator.beginFinalReports("Abort", 1).kind == "Ready")
	local finish = coordinator.command(1, { kind = "FinishCase", repetitionIndex = 1, outcome = "Abort" })
	assert(participant.receive(finish.body).kind == "Accepted")
	local staleCounts = senderSnapshot()
	staleCounts.repetitions[1].staleCallbacks = 1
	staleCounts.failureFacts = {{ code = "StaleCallback", occurrences = 1, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = staleCounts })
	end)
	local staleClaim = senderSnapshot()
	staleClaim.failureFacts = {{ code = "StaleCallback", occurrences = 1, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = staleClaim })
	end)
	local shortCompletedSender = senderSnapshot()
	shortCompletedSender.repetitions[1].submitted = 119
	shortCompletedSender.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = shortCompletedSender })
	end)
	local missingCompletedEndpoint = senderSnapshot()
	missingCompletedEndpoint.repetitions[1].finalSubmissionReturnedSharedSeconds = nil
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = missingCompletedEndpoint })
	end)
	local falseWithoutFact = senderSnapshot()
	falseWithoutFact.conformance.setupExcluded = false
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = falseWithoutFact })
	end)
	local resultExtractionFalse = senderSnapshot()
	resultExtractionFalse.conformance.resultExtractionExcluded = false
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = resultExtractionFalse })
	end)
	local clockFalse = senderSnapshot()
	clockFalse.conformance.clockProofPassed = false
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = clockFalse })
	end)
	local factWithoutFalse = senderSnapshot()
	factWithoutFalse.failureFacts = {{
		code = "TimingExclusionViolation", occurrences = 1,
		discriminator = { kind = "TimingExclusion", value = "setup" },
	}}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = factWithoutFalse })
	end)
	local twoFalseMissingFact = senderSnapshot()
	twoFalseMissingFact.conformance.setupExcluded = false
	twoFalseMissingFact.conformance.warmupExcluded = false
	twoFalseMissingFact.failureFacts = {{
		code = "TimingExclusionViolation", occurrences = 1,
		discriminator = { kind = "TimingExclusion", value = "setup" },
	}}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = twoFalseMissingFact })
	end)
	local threeFalseMissingFact = senderSnapshot()
	threeFalseMissingFact.conformance.setupExcluded = false
	threeFalseMissingFact.conformance.warmupExcluded = false
	threeFalseMissingFact.conformance.quiescenceExcluded = false
	threeFalseMissingFact.failureFacts = {
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "setup" },
		},
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "warmup" },
		},
	}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = threeFalseMissingFact })
	end)
	local duplicateTiming = senderSnapshot()
	duplicateTiming.conformance.setupExcluded = false
	duplicateTiming.failureFacts = {
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "setup" },
		},
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "setup" },
		},
	}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = duplicateTiming })
	end)
	local reverseTiming = senderSnapshot()
	reverseTiming.conformance.setupExcluded = false
	reverseTiming.conformance.warmupExcluded = false
	reverseTiming.failureFacts = {
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "warmup" },
		},
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "setup" },
		},
	}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = reverseTiming })
	end)
	local shortOptionalMeasurement = senderSnapshot()
	table.insert(shortOptionalMeasurement.measurements, {
		measurementIndex = 11, repetitionIndex = 1, values = table.create(119, 1),
	})
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = shortOptionalMeasurement })
	end)
	local source = senderSnapshot()
	table.insert(source.measurements, {
		measurementIndex = 11, repetitionIndex = 1, values = table.create(120, 1),
	})
	source.conformance.setupExcluded = false
	source.conformance.warmupExcluded = false
	source.failureFacts = {
		{
			code = "ControlTrafficDuringMeasuredFrames", occurrences = 1, firstRepetition = 1,
		},
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "setup" },
		},
		{
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = "warmup" },
		},
	}
	local final = participant.report({ kind = "FinalReport", snapshot = source })
	source.repetitions[1].submitted = 0
	local accepted = coordinator.receive(token, final.body)
	assert(accepted.kind == "Accepted" and accepted.event.snapshot.repetitions[1].submitted == 120)
	assert(#accepted.event.snapshot.measurements[4].values == 120, "present optional cadence must be exact")
	deepFrozen(accepted)
	coordinator.disable()
	participant.disable()
	assert(coordinator.receive(setmetatable({}, { __eq = function() error("read") end }), setmetatable({}, { __index = function() error("read") end })) .kind == "Ignored")
	assert(participant.receive(setmetatable({}, { __index = function() error("read") end })).kind == "Muted")
end

-- Post-Bind expiry consumes only the expected header, allows one exact late replay, and drains to Abort 0.
do
	local token = {}
	local coordinator = ControlProtocol.newCoordinator(binding("tiny-steady-c2s", 1), { token }, function() return 1 end, function() return true end).coordinator
	local participant = ControlProtocol.newParticipant(binding("tiny-steady-c2s", 1, 1))
	local bind = coordinator.command(1, { kind = "BindCase" })
	participant.receive(bind.body)
	coordinator.receive(token, participant.report({ kind = "BoundReport" }).body)
	local prepare = coordinator.command(1, { kind = "PrepareRepetition", repetitionIndex = 1 })
	participant.receive(prepare.body)
	coordinator.receive(token, participant.report({ kind = "ReadyReport", outcome = "Ready" }).body)
	local challenge = coordinator.command(1, { kind = "ClockChallenge" })
	participant.receive(challenge.body)
	local late = participant.report({ kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1 }).body
	assert(coordinator.expireResponse(1).kind == "Ready")
	assert(coordinator.receive(token, late).kind == "Ignored")
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	local finish = coordinator.command(1, { kind = "FinishCase", repetitionIndex = 0, outcome = "Abort" })
	assert(participant.receive(finish.body).kind == "Accepted")
	local final = participant.report({ kind = "FinalReport", snapshot = emptySnapshot() })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
	raises("CONTROL_PROTOCOL_E_INPUT", function() coordinator.expireResponse(0) end)
end

local function pair(caseId, clockFunction)
	local token = {}
	local coordinator = ControlProtocol.newCoordinator(binding(caseId, 1), { token }, clockFunction or function() return 1 end, function() return true end).coordinator
	local participant = ControlProtocol.newParticipant(binding(caseId, 1, 1))
	return coordinator, participant, token
end

local function bindPair(coordinator, participant, token)
	local command = coordinator.command(1, { kind = "BindCase" })
	participant.receive(command.body)
	local report = participant.report({ kind = "BoundReport" })
	assert(coordinator.receive(token, report.body).kind == "Accepted")
	return report.body
end

-- Clock proof conformance is mandatory even when an Abort snapshot precedes a challenge.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	bindPair(coordinator, participant, token)
	raises("CONTROL_PROTOCOL_E_STATE", function()
		coordinator.beginFinalReports("Abort", 0, "InputMutation")
	end)
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
	}).body)
	local clockFalse = emptySnapshot()
	clockFalse.conformance.clockProofPassed = false
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = clockFalse })
	end)
	local final = participant.report({ kind = "FinalReport", snapshot = emptySnapshot() })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

local function preparePair(coordinator, participant, token)
	local command = coordinator.command(1, { kind = "PrepareRepetition", repetitionIndex = 1 })
	participant.receive(command.body)
	assert(coordinator.receive(token, participant.report({ kind = "ReadyReport", outcome = "Ready" }).body).kind == "Accepted")
end

local function clockPair(coordinator, participant, token)
	local command = coordinator.command(1, { kind = "ClockChallenge" })
	assert(command.kind == "Ready")
	participant.receive(command.body)
	local report = participant.report({ kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1 })
	return coordinator.receive(token, report.body)
end

local function enterWarmup(coordinator, participant, token)
	bindPair(coordinator, participant, token)
	preparePair(coordinator, participant, token)
	assert(clockPair(coordinator, participant, token).kind == "Accepted")
	local command = coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = 1 })
	participant.receive(command.body)
end

local function driveToFinal(caseId, outcomes, onMeasured)
	local coordinator, participant, token = pair(caseId)
	bindPair(coordinator, participant, token)
	for repetition, outcome in outcomes do
		local prepare = coordinator.command(1, { kind = "PrepareRepetition", repetitionIndex = repetition })
		participant.receive(prepare.body)
		coordinator.receive(token, participant.report({ kind = "ReadyReport", outcome = "Ready" }).body)
		if repetition == 1 then assert(clockPair(coordinator, participant, token).kind == "Accepted") end
		local warmup = coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = repetition })
		participant.receive(warmup.body)
		coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
		for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
		participant.receive(coordinator.command(1, {
			kind = "ArmMeasured", repetitionIndex = repetition, startSharedSeconds = repetition,
		}).body)
		if onMeasured ~= nil then onMeasured(repetition, coordinator, participant) end
		local completed = outcome ~= "Abort"
		assert(coordinator.beginPostTeardownObservation(repetition, true, completed).kind == "Ready")
		participant.beginPostTeardownObservation(repetition)
		assert(coordinator.receive(token, participant.report({
			kind = "RepetitionReport", outcome = outcome, isolationPassed = true,
		}).body).kind == "Accepted")
	end
	assert(coordinator.beginFinalReports("Abort", #outcomes).kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = #outcomes, outcome = "Abort",
	}).body)
	return coordinator, participant, token
end

local function driveLocallyCompleteToFinal(caseId)
	local coordinator, participant, token = pair(caseId)
	bindPair(coordinator, participant, token)
	local prepare = coordinator.command(1, { kind = "PrepareRepetition", repetitionIndex = 1 })
	participant.receive(prepare.body)
	coordinator.receive(token, participant.report({ kind = "ReadyReport", outcome = "Ready" }).body)
	assert(clockPair(coordinator, participant, token).kind == "Accepted")
	participant.receive(coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = 1 }).body)
	coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
	for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
	participant.receive(coordinator.command(1, {
		kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1,
	}).body)
	assert(coordinator.beginPostTeardownObservation(1, true, false).kind == "Ready")
	participant.beginPostTeardownObservation(1)
	assert(coordinator.receive(token, participant.report({
		kind = "RepetitionReport", outcome = "Clean", isolationPassed = true,
	}).body).kind == "Accepted")
	assert(coordinator.beginFinalReports("Abort", 1).kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 1, outcome = "Abort",
	}).body)
	return coordinator, participant, token
end

local function repetitionEvidence(index, completed)
	return {
		repetitionIndex = index, started = true, completed = completed,
		submitted = 0, received = 0, correct = 0, mismatch = 0, duplicate = 0,
		unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = false,
		probeStarted = 0, probeSubmitted = 0, probeReceived = 0, probeCorrect = 0, probeMismatch = 0,
	}
end

do
	local coordinator, participant, token = driveToFinal("tiny-steady-c2s", { "Abort" })
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, false)
	repetition.firstSubmissionStartedSharedSeconds = 1
	snapshot.repetitions = { repetition }
	snapshot.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "zero-submission first-submit failure must remain reportable")
end

-- A returned operation that mutated its input is accounted as accepted work and
-- represented by one exact, case-latched fact without a repetition field.
do
	local coordinator, participant, token = driveToFinal("tiny-steady-c2s", { "Abort" })
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, false)
	repetition.submitted = 1
	repetition.firstSubmissionStartedSharedSeconds = 1
	repetition.finalSubmissionReturnedSharedSeconds = 2
	snapshot.repetitions = { repetition }
	snapshot.failureFacts = {{ code = "InputMutation", occurrences = 2 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts[1].occurrences = 1
	snapshot.failureFacts[1].firstRepetition = 1
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts[1].firstRepetition = nil
	repetition.submitted = 0
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	repetition.submitted = 1
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "sender mutation evidence must remain reportable")
end

-- Separate-probe clients can report the same atomic mutation outcome using
-- probe-operation accounting; receiver-only roles cannot inject the fact.
do
	local coordinator, participant, token = driveToFinal("tiny-round-trip", { "Abort" })
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, false)
	repetition.probeStarted = 1
	repetition.probeSubmitted = 1
	snapshot.repetitions = { repetition }
	snapshot.failureFacts = {{ code = "InputMutation", occurrences = 1 }}
	repetition.probeSubmitted = 0
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	repetition.probeSubmitted = 1
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "probe mutation evidence must remain reportable")
end

do
	local _, participant = driveToFinal("state-broadcast-s2c", { "Abort" })
	local snapshot = emptySnapshot()
	snapshot.repetitions = { repetitionEvidence(1, false) }
	snapshot.failureFacts = {{ code = "InputMutation", occurrences = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
end

-- Only receiving roles may be locally complete for the coordinator's current
-- globally incomplete repetition. Global mutation backing is reconciled with
-- the local server snapshot after this per-slot protocol boundary.
do
	local coordinator, participant, token = driveLocallyCompleteToFinal("state-broadcast-s2c")
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, true)
	repetition.received = 120
	repetition.correct = 120
	repetition.finalExpectedDeliveryReceivedSharedSeconds = 1
	repetition.finalExpectedDeliveryVerifiedSharedSeconds = 2
	snapshot.repetitions = { repetition }
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted",
		"current broadcast receiver completion must cross the protocol boundary")
end

do
	local coordinator, participant, token = driveLocallyCompleteToFinal("tiny-round-trip")
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, true)
	repetition.probeStarted = 120
	repetition.probeSubmitted = 120
	repetition.probeReceived = 120
	repetition.probeCorrect = 120
	snapshot.repetitions = { repetition }
	snapshot.measurements = {{ measurementIndex = 9, repetitionIndex = 1, values = table.create(120, 1) }}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted",
		"current probe receiver completion must cross the protocol boundary")
end

do
	local _, participant = driveToFinal("tiny-steady-c2s", { "Abort" })
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = senderSnapshot() })
	end)
end

-- Pre-start mutation evidence is accepted only from the fixed slot that
-- previously reported the exact warmup outcome.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	bindPair(coordinator, participant, token)
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
	}).body)
	local snapshot = emptySnapshot()
	snapshot.failureFacts = {{ code = "InputMutation", occurrences = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts = {{ code = "TeardownFailure", occurrences = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts = {}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "uncaused pre-start evidence must stay rejected")
end

do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	enterWarmup(coordinator, participant, token)
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "WarmupReport", outcome = "InputMutation", extra = true } :: any)
	end)
	local warmup = participant.report({ kind = "WarmupReport", outcome = "InputMutation" })
	local accepted = coordinator.receive(token, warmup.body)
	assert(accepted.kind == "Accepted" and accepted.participantIndex == 1)
	exact(accepted.event, { "kind", "outcome" }, "warmup mutation event")
	assert(accepted.event.kind == "WarmupReport" and accepted.event.outcome == "InputMutation")
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
	}).body)
	local snapshot = emptySnapshot()
	snapshot.failureFacts = {
		{ code = "SetupFailure", occurrences = 1 },
		{ code = "InputMutation", occurrences = 1 },
	}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts = {
		{ code = "TeardownFailure", occurrences = 1 },
		{ code = "InputMutation", occurrences = 1 },
	}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "pre-start mutation must remain reportable")
end

do
	local coordinator, participant, token = pair("state-broadcast-s2c")
	enterWarmup(coordinator, participant, token)
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "WarmupReport", outcome = "InputMutation" })
	end)
	local clean = participant.report({ kind = "WarmupReport", outcome = "Clean" })
	assert(coordinator.receive(token, clean.body).kind == "Accepted",
		"receiver warmup mutation rejection must leave Clean reportable")
end

-- A trusted local-server warmup mutation uses the one bounded third-argument
-- cause; remote clean slots finalize without falsely claiming the server fact.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	enterWarmup(coordinator, participant, token)
	local clean = participant.report({ kind = "WarmupReport", outcome = "Clean" })
	assert(coordinator.receive(token, clean.body).kind == "Accepted")
	raises("CONTROL_PROTOCOL_E_STATE", function()
		coordinator.beginFinalReports("Abort", 0, "InputMutation")
	end)
end

do
	local coordinator, participant, token = pair("state-broadcast-s2c")
	enterWarmup(coordinator, participant, token)
	local clean = participant.report({ kind = "WarmupReport", outcome = "Clean" })
	assert(coordinator.receive(token, clean.body).kind == "Accepted")
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		coordinator.beginFinalReports("Abort", 0, "Other")
	end)
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		coordinator.beginFinalReports("Complete", 0, "InputMutation")
	end)
	assert(coordinator.beginFinalReports("Abort", 0, "InputMutation").kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
	}).body)
	local final = participant.report({ kind = "FinalReport", snapshot = emptySnapshot() })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "local warmup mutation cause must finalize")
end

-- A receiver may fail ordinary teardown after the server's warmup mutation.
-- FinishCase permits its local projection; the coordinator owns causal proof.
for _, caseId in { "state-broadcast-s2c", "tiny-round-trip" } do
	local coordinator, participant, token = pair(caseId)
	enterWarmup(coordinator, participant, token)
	assert(coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body).kind == "Accepted")
	assert(coordinator.beginFinalReports("Abort", 0, "InputMutation").kind == "Ready")
	assert(participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
	}).body).kind == "Accepted")
	local snapshot = emptySnapshot()
	snapshot.failureFacts = {{ code = "TeardownFailure", occurrences = 1 }}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	local accepted = coordinator.receive(token, final.body)
	assert(accepted.kind == "Accepted", "receiver teardown failure must retain the server mutation cause")
	assert(#accepted.event.snapshot.failureFacts == 1
		and accepted.event.snapshot.failureFacts[1].code == "TeardownFailure",
		"receiver must not manufacture its own InputMutation fact")
end

do
	local coordinator, participant, token = pair("state-broadcast-s2c")
	bindPair(coordinator, participant, token)
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
	}).body)
	local final = table.clone(participant.report({ kind = "FinalReport", snapshot = emptySnapshot() }).body)
	final.snapshot = emptySnapshot()
	final.snapshot.failureFacts = {{ code = "TeardownFailure", occurrences = 1 }}
	local rejected = coordinator.receive(token, final)
	assert(rejected.kind == "Terminated" and rejected.termination.code == "ControlProtocolRejected",
		"coordinator must reject uncaused pre-start teardown even when it bypasses the participant guard")
end

do
	local _, participant = driveToFinal("state-broadcast-s2c", { "Abort" })
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, false)
	repetition.received = 1
	repetition.correct = 1
	repetition.finalExpectedDeliveryReceivedSharedSeconds = 1
	repetition.finalExpectedDeliveryVerifiedSharedSeconds = 2
	snapshot.repetitions = { repetition }
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
end

-- Bind-terminal cancellation and persistent terminal receive fast path.
do
	local tokens, participants = {}, {}
	for index = 1, 4 do tokens[index] = {}; participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", 4, index)) end
	local coordinator = ControlProtocol.newCoordinator(binding("state-broadcast-s2c", 4), tokens, function() return 1 end, function() return true end).coordinator
	for index = 4, 1, -1 do participants[index].receive(coordinator.command(index, { kind = "BindCase" }).body) end
	local terminal = coordinator.expireResponse(2)
	assert(terminal.kind == "Terminated" and terminal.termination.code == "ControlProtocolRejected" and terminal.termination.stage == "Setup")
	local hostile = setmetatable({}, { __index = function() error("must not read") end, __iter = function() error("must not iterate") end })
	assert(coordinator.receive(tokens[1], hostile, hostile) == terminal, "terminal result must be persistent identity")
	raises("CONTROL_PROTOCOL_E_STATE", function() coordinator.command(1, { kind = "BindCase" }) end)
end

-- Warmup has one persistent no-result disposition for Dirty, expiry, disconnect, and outer deadline.
for _, mode in { "Dirty", "Expire", "Disconnect", "Deadline" } do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	enterWarmup(coordinator, participant, token)
	local result
	if mode == "Dirty" then
		result = coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Dirty" }).body)
	elseif mode == "Expire" then
		result = coordinator.expireResponse(1)
	elseif mode == "Disconnect" then
		result = coordinator.disconnect(token)
	else
		result = coordinator.beginFinalReports("Abort", 0)
	end
	assert(result.kind == "Terminated" and result.termination.code == "WarmupEvidenceRejected" and result.termination.stage == "Execution", mode)
	assert(coordinator.receive(token, setmetatable({}, { __index = function() error("read") end })) == result)
end

-- Shared-clock failures before emission and after consumption are redacted and retain Abort 0 reachability.
do
	local coordinator, participant, token = pair("tiny-steady-c2s", function() error("secret clock detail") end)
	bindPair(coordinator, participant, token)
	preparePair(coordinator, participant, token)
	local failed = coordinator.command(1, { kind = "ClockChallenge" })
	assert(failed.kind == "ClockProofFailed" and failed.participantIndex == 1)
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
end
do
	local reads = 0
	local coordinator, participant, token = pair("tiny-steady-c2s", function()
		reads += 1
		if reads == 2 then error("secret clock detail") end
		return 1
	end)
	bindPair(coordinator, participant, token)
	preparePair(coordinator, participant, token)
	assert(clockPair(coordinator, participant, token).kind == "ClockProofFailed")
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
end

-- Quiet reset occurs for both an exact replay and a body-free non-roster fire.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	enterWarmup(coordinator, participant, token)
	local warmup = participant.report({ kind = "WarmupReport", outcome = "Clean" }).body
	assert(coordinator.receive(token, warmup).kind == "Accepted")
	for _ = 1, 59 do assert(not coordinator.postSimulation()) end
	assert(coordinator.receive(token, warmup).kind == "Ignored")
	for _ = 1, 59 do assert(not coordinator.postSimulation()) end
	assert(coordinator.postSimulation())
	for _ = 1, 59 do coordinator.postSimulation() end
	assert(coordinator.receive({}, setmetatable({}, { __index = function() error("must not traverse") end })).kind == "Ignored")
	for _ = 1, 59 do assert(not coordinator.postSimulation()) end
	assert(coordinator.postSimulation())
end

-- Exact replay 128/129 and non-roster 64/65 ceilings.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	local bound = bindPair(coordinator, participant, token)
	for _ = 1, 128 do assert(coordinator.receive(token, bound).kind == "Ignored") end
	local overflow = coordinator.receive(token, bound)
	assert(overflow.kind == "Terminated" and overflow.termination.code == "IngressLimitExceeded")
end
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	bindPair(coordinator, participant, token)
	local hostile = setmetatable({}, { __index = function() error("must not traverse") end })
	for _ = 1, 64 do assert(coordinator.receive({}, hostile).kind == "Ignored") end
	local overflow = coordinator.receive({}, hostile)
	assert(overflow.kind == "Terminated" and overflow.termination.code == "IngressLimitExceeded")
end

-- A false start after Arm is a protocol termination and never opens evidence reporting.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	enterWarmup(coordinator, participant, token)
	coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
	for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
	participant.receive(coordinator.command(1, { kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1 }).body)
	local result = coordinator.beginPostTeardownObservation(1, false, false)
	assert(result.kind == "Terminated" and result.termination.code == "ControlProtocolRejected" and result.termination.stage == "Execution")
end

local function receiverSnapshot(fixtureIndex, signedZero)
	local reason = if signedZero then "ValueMismatch" else "WrongContainerType"
	local mismatch = if signedZero
		then { pathKind = "Field", fieldIndex = 4, actual = -0.0 }
		else { pathKind = "Root" }
	return {
		version = 1,
		repetitions = {{
			repetitionIndex = 1, started = true, completed = true,
			submitted = 0, received = 1, correct = 0, mismatch = 1, duplicate = 0,
			unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = false,
			probeStarted = 0, probeSubmitted = 0, probeReceived = 0, probeCorrect = 0, probeMismatch = 0,
		}},
		measurements = {},
		failureFacts = {
			{
				code = "PayloadMismatch", occurrences = 1,
				discriminator = { kind = "MismatchReason", value = reason },
				firstRepetition = 1, fixtureIndex = fixtureIndex, mismatch = mismatch,
			},
			{
				code = "TimingExclusionViolation", occurrences = 1,
				discriminator = { kind = "TimingExclusion", value = "setup" },
			},
			{
				code = "TimingExclusionViolation", occurrences = 1,
				discriminator = { kind = "TimingExclusion", value = "warmup" },
			},
			{
				code = "TimingExclusionViolation", occurrences = 1,
				discriminator = { kind = "TimingExclusion", value = "quiescence" },
			},
		},
		conformance = {
			setupExcluded = false, warmupExcluded = false, quiescenceExcluded = false,
			resultExtractionExcluded = true, clockProofPassed = true,
		},
	}
end

-- PayloadMismatch references use only the trusted measured fixture ordinal (min/max/max+1).
for _, validFixtureIndex in { 1, 120 } do
	local signedZero = validFixtureIndex == 1
	local originalGenerate = Fixtures.generate
	if signedZero then
		Fixtures.generate = function()
			return { measured = {{ expected = { yaw = 0 } }} }
		end
	end
	local coordinator, participant, token = pair("state-broadcast-s2c")
	enterWarmup(coordinator, participant, token)
	coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
	for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
	participant.receive(coordinator.command(1, { kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1 }).body)
	coordinator.beginPostTeardownObservation(1, true, true)
	participant.beginPostTeardownObservation(1)
	coordinator.receive(token, participant.report({ kind = "RepetitionReport", outcome = "Invalid", isolationPassed = true }).body)
	coordinator.beginFinalReports("Abort", 1)
	participant.receive(coordinator.command(1, { kind = "FinishCase", repetitionIndex = 1, outcome = "Abort" }).body)
	for _, invalidIndex in { 0, 121 } do
		raises("CONTROL_PROTOCOL_E_INPUT", function()
			participant.report({ kind = "FinalReport", snapshot = receiverSnapshot(invalidIndex, signedZero) })
		end)
	end
	local final = participant.report({ kind = "FinalReport", snapshot = receiverSnapshot(validFixtureIndex, signedZero) })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
	Fixtures.generate = originalGenerate
end

-- Per-entry sample cardinality accepts the burst sender maximum 40 and rejects 41.
do
	local coordinator, participant, token = pair("state-burst-c2s")
	enterWarmup(coordinator, participant, token)
	coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
	for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
	participant.receive(coordinator.command(1, { kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1 }).body)
	coordinator.beginPostTeardownObservation(1, true, true)
	participant.beginPostTeardownObservation(1)
	coordinator.receive(token, participant.report({ kind = "RepetitionReport", outcome = "Clean", isolationPassed = true }).body)
	coordinator.beginFinalReports("Abort", 1)
	participant.receive(coordinator.command(1, { kind = "FinishCase", repetitionIndex = 1, outcome = "Abort" }).body)
	local function burstSnapshot(valueCount)
		local snapshot = emptySnapshot()
		snapshot.repetitions = {{
			repetitionIndex = 1, started = true, completed = true,
			submitted = 40, received = 0, correct = 0, mismatch = 0, duplicate = 0,
			unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = false,
			probeStarted = 0, probeSubmitted = 0, probeReceived = 0, probeCorrect = 0, probeMismatch = 0,
			firstSubmissionStartedSharedSeconds = 1, finalSubmissionReturnedSharedSeconds = 2,
		}}
		snapshot.measurements = {
			{ measurementIndex = 4, repetitionIndex = 1, values = table.create(10, 1) },
			{ measurementIndex = 5, repetitionIndex = 1, values = { 1 } },
			{ measurementIndex = 10, repetitionIndex = 1, values = table.create(valueCount, 1) },
		}
		return snapshot
	end
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = burstSnapshot(41) })
	end)
	local final = participant.report({ kind = "FinalReport", snapshot = burstSnapshot(40) })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

-- Probe evidence owns only probe counters and measurement index 9; derived measurement failures cannot be injected.
do
	local coordinator, participant, token = pair("tiny-round-trip")
	enterWarmup(coordinator, participant, token)
	coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
	for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
	participant.receive(coordinator.command(1, { kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1 }).body)
	coordinator.beginPostTeardownObservation(1, true, true)
	participant.beginPostTeardownObservation(1)
	coordinator.receive(token, participant.report({ kind = "RepetitionReport", outcome = "Clean", isolationPassed = true }).body)
	coordinator.beginFinalReports("Abort", 1)
	participant.receive(coordinator.command(1, { kind = "FinishCase", repetitionIndex = 1, outcome = "Abort" }).body)
	local snapshot = emptySnapshot()
	snapshot.repetitions = {{
		repetitionIndex = 1, started = true, completed = true,
		submitted = 0, received = 0, correct = 0, mismatch = 0, duplicate = 0,
		unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = false,
		probeStarted = 120, probeSubmitted = 120, probeReceived = 120, probeCorrect = 120, probeMismatch = 0,
	}}
	snapshot.measurements = {{ measurementIndex = 9, repetitionIndex = 1, values = table.create(120, 1) }}
	local shortCompletedProbe = emptySnapshot()
	shortCompletedProbe.repetitions = { repetitionEvidence(1, true) }
	shortCompletedProbe.repetitions[1].probeStarted = 120
	shortCompletedProbe.repetitions[1].probeSubmitted = 120
	shortCompletedProbe.repetitions[1].probeReceived = 119
	shortCompletedProbe.repetitions[1].probeCorrect = 119
	shortCompletedProbe.measurements = {{ measurementIndex = 9, repetitionIndex = 1, values = table.create(120, 1) }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = shortCompletedProbe })
	end)
	local injected = emptySnapshot()
	injected.repetitions = snapshot.repetitions
	injected.measurements = snapshot.measurements
	injected.failureFacts = {{ code = "RequiredMeasurementUnavailable", occurrences = 1, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = injected })
	end)
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

-- SubmitFailure is bounded by genuinely short, started, noncompleted submission repetitions.
do
	local coordinator, participant, token = driveToFinal("tiny-steady-c2s", { "Clean", "Abort" })
	local snapshot = emptySnapshot()
	local first = repetitionEvidence(1, true)
	first.submitted = 120
	first.firstSubmissionStartedSharedSeconds = 1
	first.finalSubmissionReturnedSharedSeconds = 2
	local second = repetitionEvidence(2, false)
	second.submitted = 119
	second.firstSubmissionStartedSharedSeconds = 3
	snapshot.repetitions = { first, second }
	snapshot.measurements = {
		{ measurementIndex = 4, repetitionIndex = 1, values = table.create(120, 1) },
		{ measurementIndex = 5, repetitionIndex = 1, values = { 1 } },
		{ measurementIndex = 10, repetitionIndex = 1, values = table.create(120, 1) },
	}
	snapshot.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts[1].firstRepetition = 2
	snapshot.failureFacts[1].occurrences = 2
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts[1].occurrences = 1
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

-- Missing probe responses alone cannot support SubmitFailure; a short submission count can.
do
	local coordinator, participant, token = driveToFinal("tiny-round-trip", { "Abort" })
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, false)
	repetition.probeStarted = 120
	repetition.probeSubmitted = 120
	repetition.probeReceived = 119
	repetition.probeCorrect = 119
	snapshot.repetitions = { repetition }
	snapshot.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	repetition.probeSubmitted = 119
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

-- Receiver-local stale evidence observes both the per-repetition and case-total R1 cap;
-- post-start TeardownFailure occurrences fit only in the started range from first onward.
do
	local coordinator, participant, token = driveToFinal("state-broadcast-s2c", { "Clean", "Clean" })
	local function receiverEvidence()
		local snapshot = emptySnapshot()
		snapshot.repetitions = { repetitionEvidence(1, true), repetitionEvidence(2, true) }
		return snapshot
	end
	local overPer = receiverEvidence()
	overPer.repetitions[1].staleCallbacks = 14_401
	overPer.failureFacts = {{ code = "StaleCallback", occurrences = 14_401, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = overPer })
	end)
	local overTotal = receiverEvidence()
	overTotal.repetitions[1].staleCallbacks = 7_200
	overTotal.repetitions[2].staleCallbacks = 7_201
	overTotal.failureFacts = {{ code = "StaleCallback", occurrences = 14_401, firstRepetition = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = overTotal })
	end)
	local overTeardownRange = receiverEvidence()
	overTeardownRange.failureFacts = {{ code = "TeardownFailure", occurrences = 2, firstRepetition = 2 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = overTeardownRange })
	end)
	local exactCaps = receiverEvidence()
	exactCaps.repetitions[1].staleCallbacks = 7_200
	exactCaps.repetitions[2].staleCallbacks = 7_200
	exactCaps.failureFacts = {
		{ code = "StaleCallback", occurrences = 14_400, firstRepetition = 1 },
		{ code = "TeardownFailure", occurrences = 2, firstRepetition = 1 },
	}
	local final = participant.report({ kind = "FinalReport", snapshot = exactCaps })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

-- ControlTraffic firstRepetition is the exact first locally observed measured repetition.
do
	local coordinator, participant, token = driveToFinal("tiny-steady-c2s", { "Clean", "Abort" }, function(repetition, localCoordinator, localParticipant)
		if repetition == 2 then
			assert(localCoordinator.command("hostile", "hostile").kind == "MeasuredControlTraffic")
			assert(localParticipant.report("hostile").kind == "MeasuredControlTraffic")
		end
	end)
	local snapshot = emptySnapshot()
	local first = repetitionEvidence(1, true)
	first.submitted = 120
	first.firstSubmissionStartedSharedSeconds = 1
	first.finalSubmissionReturnedSharedSeconds = 2
	local second = repetitionEvidence(2, false)
	second.firstSubmissionStartedSharedSeconds = 3
	snapshot.repetitions = { first, second }
	snapshot.measurements = {
		{ measurementIndex = 4, repetitionIndex = 1, values = table.create(120, 1) },
		{ measurementIndex = 5, repetitionIndex = 1, values = { 1 } },
		{ measurementIndex = 10, repetitionIndex = 1, values = table.create(120, 1) },
	}
	snapshot.failureFacts = {{
		code = "ControlTrafficDuringMeasuredFrames", occurrences = 1, firstRepetition = 1,
	}}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts[1].firstRepetition = 2
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

-- PayloadMismatch firstRepetition must name a repetition with local mismatch evidence.
do
	local coordinator, participant, token = driveToFinal("state-broadcast-s2c", { "Clean", "Invalid" })
	local snapshot = emptySnapshot()
	local first = repetitionEvidence(1, true)
	local second = repetitionEvidence(2, true)
	second.received = 1
	second.mismatch = 1
	snapshot.repetitions = { first, second }
	snapshot.failureFacts = {{
		code = "PayloadMismatch", occurrences = 1,
		discriminator = { kind = "MismatchReason", value = "WrongContainerType" },
		firstRepetition = 1, fixtureIndex = 1, mismatch = { pathKind = "Root" },
	}}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts[1].firstRepetition = 2
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
end

raises("CONTROL_PROTOCOL_E_CONFIG", function() ControlProtocol.newParticipant(binding("tiny-steady-c2s", 1, 1), {}) end)
raises("CONTROL_PROTOCOL_E_CONFIG", function() ControlProtocol.newCoordinator() end)

-- Four-slot post-Bind barriers remain closed until the last reversed arrival and Arm emission.
do
	local tokens, participants = {}, {}
	for index = 1, 4 do
		tokens[index] = {}
		participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", 4, index))
	end
	local coordinator = ControlProtocol.newCoordinator(binding("state-broadcast-s2c", 4), tokens, function() return 1 end, function() return true end).coordinator
	local function barrier(commandIntent, reportIntent)
		local reports = {}
		for index = 4, 1, -1 do
			local command = coordinator.command(index, commandIntent)
			participants[index].receive(command.body)
			reports[index] = participants[index].report(reportIntent).body
		end
		for index = 4, 1, -1 do assert(coordinator.receive(tokens[index], reports[index]).kind == "Accepted") end
	end
	barrier({ kind = "BindCase" }, { kind = "BoundReport" })
	barrier({ kind = "PrepareRepetition", repetitionIndex = 1 }, { kind = "ReadyReport", outcome = "Ready" })
	barrier({ kind = "ClockChallenge" }, { kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1 })
	barrier({ kind = "BeginWarmup", repetitionIndex = 1 }, { kind = "WarmupReport", outcome = "Clean" })
	for _ = 1, 60 do
		coordinator.postSimulation()
		for index = 1, 4 do participants[index].postSimulation() end
	end
	for index = 4, 1, -1 do
		assert(participants[index].receive(coordinator.command(index, { kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1 }).body).kind == "Accepted")
	end
	assert(coordinator.command("hostile", "hostile").kind == "MeasuredControlTraffic")
	local terminated = coordinator.beginPostTeardownObservation(1, false, false)
	assert(terminated.kind == "Terminated" and terminated.termination.code == "ControlProtocolRejected")
end

-- The full 30-repetition catalog reaches exactly 93 accepted reports. Combined with 128
-- exact-header replays it reaches universal entry 221; entry 222 terminates before traversal.
do
	local coordinator, participant, token = pair("tiny-steady-c2s")
	local bound = bindPair(coordinator, participant, token)
	for _ = 1, 128 do assert(coordinator.receive(token, bound).kind == "Ignored") end
	local repetitions, measurements = {}, {}
	for repetition = 1, 30 do
		local prepare = coordinator.command(1, { kind = "PrepareRepetition", repetitionIndex = repetition })
		participant.receive(prepare.body)
		coordinator.receive(token, participant.report({ kind = "ReadyReport", outcome = "Ready" }).body)
		if repetition == 1 then
			local challenge = coordinator.command(1, { kind = "ClockChallenge" })
			participant.receive(challenge.body)
			coordinator.receive(token, participant.report({
				kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1,
			}).body)
		end
		local warmup = coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = repetition })
		participant.receive(warmup.body)
		coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
		for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
		local arm = coordinator.command(1, { kind = "ArmMeasured", repetitionIndex = repetition, startSharedSeconds = repetition })
		participant.receive(arm.body)
		coordinator.beginPostTeardownObservation(repetition, true, true)
		participant.beginPostTeardownObservation(repetition)
		coordinator.receive(token, participant.report({ kind = "RepetitionReport", outcome = "Clean", isolationPassed = true }).body)
		repetitions[repetition] = {
			repetitionIndex = repetition, started = true, completed = true,
			submitted = 120, received = 0, correct = 0, mismatch = 0, duplicate = 0,
			unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = false,
			probeStarted = 0, probeSubmitted = 0, probeReceived = 0, probeCorrect = 0, probeMismatch = 0,
			firstSubmissionStartedSharedSeconds = repetition,
			finalSubmissionReturnedSharedSeconds = repetition + 0.5,
		}
		table.insert(measurements, { measurementIndex = 4, repetitionIndex = repetition, values = table.create(120, 1) })
		table.insert(measurements, { measurementIndex = 5, repetitionIndex = repetition, values = { 1 } })
		table.insert(measurements, { measurementIndex = 10, repetitionIndex = repetition, values = table.create(120, 1) })
	end
	assert(coordinator.beginFinalReports("Complete", 30).kind == "Ready")
	participant.receive(coordinator.command(1, { kind = "FinishCase", repetitionIndex = 30, outcome = "Complete" }).body)
	local snapshot = emptySnapshot()
	snapshot.repetitions = repetitions
	snapshot.measurements = measurements
	snapshot.failureFacts = {{ code = "InputMutation", occurrences = 1 }}
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
	snapshot.failureFacts = {}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted")
	local overflow = coordinator.receive(token, final.body)
	assert(overflow.kind == "Terminated" and overflow.termination.code == "IngressLimitExceeded")
end

local function runDistributedOverflowCase(belowCap)
	local tokens, participants = {}, {}
	for index = 1, 4 do
		tokens[index] = {}
		participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", 4, index))
	end
	local coordinator = ControlProtocol.newCoordinator(
		binding("state-broadcast-s2c", 4),
		tokens,
		function() return 1 end,
		function() return true end
	).coordinator
	local function commandBarrier(intent, reportIntent)
		local reports = {}
		for index = 4, 1, -1 do
			participants[index].receive(coordinator.command(index, intent).body)
			reports[index] = participants[index].report(reportIntent).body
		end
		for index = 4, 1, -1 do assert(coordinator.receive(tokens[index], reports[index]).kind == "Accepted") end
	end
	commandBarrier({ kind = "BindCase" }, { kind = "BoundReport" })
	local snapshots = table.create(4)
	for index = 1, 4 do
		snapshots[index] = emptySnapshot()
		snapshots[index].repetitions = {}
		snapshots[index].failureFacts = {}
	end
	for repetition = 1, 30 do
		commandBarrier(
			{ kind = "PrepareRepetition", repetitionIndex = repetition },
			{ kind = "ReadyReport", outcome = "Ready" }
		)
		if repetition == 1 then
			commandBarrier(
				{ kind = "ClockChallenge" },
				{ kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1 }
			)
		end
		commandBarrier(
			{ kind = "BeginWarmup", repetitionIndex = repetition },
			{ kind = "WarmupReport", outcome = "Clean" }
		)
		for _ = 1, 60 do
			coordinator.postSimulation()
			for index = 1, 4 do participants[index].postSimulation() end
		end
		for index = 4, 1, -1 do
			participants[index].receive(coordinator.command(index, {
				kind = "ArmMeasured", repetitionIndex = repetition, startSharedSeconds = repetition,
			}).body)
		end
		local completed = repetition < 30
		coordinator.beginPostTeardownObservation(repetition, true, completed)
		local reports = {}
		for index = 1, 4 do
			participants[index].beginPostTeardownObservation(repetition)
			reports[index] = participants[index].report({
				kind = "RepetitionReport",
				outcome = if completed then "Clean" else "Abort",
				isolationPassed = true,
			}).body
		end
		for index = 4, 1, -1 do assert(coordinator.receive(tokens[index], reports[index]).kind == "Accepted") end
		for index = 1, 4 do
			local overflow = not belowCap or index == 1
			local received = if overflow then 480 else 120
			snapshots[index].repetitions[repetition] = {
				repetitionIndex = repetition, started = true, completed = completed,
				submitted = 0, received = received, correct = received, mismatch = 0, duplicate = 0,
				unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = overflow,
				probeStarted = 0, probeSubmitted = 0, probeReceived = 0, probeCorrect = 0, probeMismatch = 0,
			}
		end
	end
	for index = 1, 4 do
		if not belowCap or index == 1 then
			snapshots[index].failureFacts = {{
				code = "DeliveryObservationLimitExceeded", occurrences = 1, firstRepetition = 1,
			}}
		end
	end
	assert(coordinator.beginFinalReports("Abort", 30).kind == "Ready")
	local finalBodies = {}
	for index = 4, 1, -1 do
		participants[index].receive(coordinator.command(index, {
			kind = "FinishCase", repetitionIndex = 30, outcome = "Abort",
		}).body)
		finalBodies[index] = participants[index].report({ kind = "FinalReport", snapshot = snapshots[index] }).body
	end
	local closing
	for index = 4, 1, -1 do
		closing = coordinator.receive(tokens[index], finalBodies[index])
		if index > 1 then assert(closing.kind == "Accepted") end
	end
	return coordinator, tokens, closing
end

-- The two approved final-barrier scalars accept the exact global cap and terminate below it.
do
	local _, _, closing = runDistributedOverflowCase(false)
	assert(closing.kind == "Accepted" and closing.event.kind == "FinalReport")
end
do
	local coordinator, tokens, closing = runDistributedOverflowCase(true)
	assert(closing.kind == "Terminated" and closing.termination.code == "DistributedOverflowUnrepresentable"
		and closing.termination.stage == "Execution")
	local hostile = setmetatable({}, { __index = function() error("must not read") end, __iter = function() error("must not iterate") end })
	assert(coordinator.receive(tokens[4], hostile, hostile) == closing, "overflow termination must be persistent before arity/body")
end
local function completeReceiverSnapshot()
	local snapshot = emptySnapshot()
	snapshot.repetitions = table.create(30)
	for repetition = 1, 30 do
		snapshot.repetitions[repetition] = {
			repetitionIndex = repetition, started = true, completed = true,
			submitted = 0, received = 120, correct = 120, mismatch = 0, duplicate = 0,
			unexpected = 0, outOfOrder = 0, staleCallbacks = 0, observationOverflow = false,
			probeStarted = 0, probeSubmitted = 0, probeReceived = 0, probeCorrect = 0, probeMismatch = 0,
		}
	end
	return snapshot
end

local function runCompleteFinalRace(count, raceKind)
	local tokens, participants = {}, {}
	for index = 1, count do
		tokens[index] = {}
		participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", count, index))
	end
	local coordinator = ControlProtocol.newCoordinator(
		binding("state-broadcast-s2c", count),
		tokens,
		function() return 1 end,
		function() return true end
	).coordinator
	local function commandBarrier(intent, reportIntent)
		local reports = {}
		for index = count, 1, -1 do
			participants[index].receive(coordinator.command(index, intent).body)
			reports[index] = participants[index].report(reportIntent).body
		end
		for index = count, 1, -1 do
			assert(coordinator.receive(tokens[index], reports[index]).kind == "Accepted")
		end
	end
	commandBarrier({ kind = "BindCase" }, { kind = "BoundReport" })
	for repetition = 1, 30 do
		commandBarrier(
			{ kind = "PrepareRepetition", repetitionIndex = repetition },
			{ kind = "ReadyReport", outcome = "Ready" }
		)
		if repetition == 1 then
			commandBarrier(
				{ kind = "ClockChallenge" },
				{ kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1 }
			)
		end
		commandBarrier(
			{ kind = "BeginWarmup", repetitionIndex = repetition },
			{ kind = "WarmupReport", outcome = "Clean" }
		)
		for _ = 1, 60 do
			coordinator.postSimulation()
			for index = 1, count do participants[index].postSimulation() end
		end
		for index = count, 1, -1 do
			participants[index].receive(coordinator.command(index, {
				kind = "ArmMeasured", repetitionIndex = repetition, startSharedSeconds = repetition,
			}).body)
		end
		coordinator.beginPostTeardownObservation(repetition, true, true)
		local reports = {}
		for index = count, 1, -1 do
			participants[index].beginPostTeardownObservation(repetition)
			reports[index] = participants[index].report({
				kind = "RepetitionReport", outcome = "Clean", isolationPassed = true,
			}).body
		end
		for index = count, 1, -1 do
			assert(coordinator.receive(tokens[index], reports[index]).kind == "Accepted")
		end
	end
	if raceKind == "Settled" then
		local disconnected = coordinator.disconnect(tokens[count])
		assert(disconnected.kind == "Disconnected" and disconnected.participantIndex == count)
		raises("CONTROL_PROTOCOL_E_STATE", function()
			coordinator.beginFinalReports("Complete", 30)
		end)
		assert(coordinator.beginFinalReports("Abort", 30).kind == "Ready")
		return
	end
	assert(coordinator.beginFinalReports("Complete", 30).kind == "Ready")
	local firstRemaining = count
	if raceKind == "Disconnect" then
		local disconnected = coordinator.disconnect(tokens[count])
		assert(disconnected.kind == "Disconnected" and disconnected.participantIndex == count)
		firstRemaining = count - 1
	else
		participants[count].receive(coordinator.command(count, {
			kind = "FinishCase", repetitionIndex = 30, outcome = "Complete",
		}).body)
		local late = participants[count].report({
			kind = "FinalReport", snapshot = completeReceiverSnapshot(),
		}).body
		assert(coordinator.expireResponse(count).kind == "Ready")
		assert(coordinator.receive(tokens[count], late).kind == "Ignored")
		firstRemaining = count - 1
	end
	for index = firstRemaining, 1, -1 do
		participants[index].receive(coordinator.command(index, {
			kind = "FinishCase", repetitionIndex = 30, outcome = "Complete",
		}).body)
		local closing = coordinator.receive(tokens[index], participants[index].report({
			kind = "FinalReport", snapshot = completeReceiverSnapshot(),
		}).body)
		assert(closing.kind == "Accepted")
	end
	if raceKind == "Disconnect" then
		assert(coordinator.disconnect(tokens[count]).kind == "Ignored")
	end
	coordinator.disable()
	for index = 1, count do participants[index].disable() end
end

-- Once Complete is selected at the final boundary, later loss latches Abort but cannot
-- prevent the remaining reversed FinishCase commands from draining the 1/4/8 barriers.
for _, count in { 1, 4, 8 } do
	runCompleteFinalRace(count, "Settled")
	runCompleteFinalRace(count, "Disconnect")
	runCompleteFinalRace(count, "Expire")
end

-- A disconnect before its FinishCase command settles the final NotSent slot for every topology
-- and every position in reversed final-barrier progress.
for _, count in { 1, 4, 8 } do
	for disconnectIndex = 1, count do
		local tokens, participants = {}, {}
		for index = 1, count do
			tokens[index] = {}
			participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", count, index))
		end
		local coordinator = ControlProtocol.newCoordinator(
			binding("state-broadcast-s2c", count), tokens, function() return 1 end, function() return true end
		).coordinator
		local boundReports = {}
		for index = count, 1, -1 do
			participants[index].receive(coordinator.command(index, { kind = "BindCase" }).body)
			boundReports[index] = participants[index].report({ kind = "BoundReport" }).body
		end
		for index = count, 1, -1 do coordinator.receive(tokens[index], boundReports[index]) end
		assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
		local closing = nil
		for index = count, 1, -1 do
			if index == disconnectIndex then
				local disconnected = coordinator.disconnect(tokens[index])
				assert(disconnected.kind == "Disconnected" and disconnected.participantIndex == index)
			else
				participants[index].receive(coordinator.command(index, {
					kind = "FinishCase", repetitionIndex = 0, outcome = "Abort",
				}).body)
				closing = coordinator.receive(tokens[index], participants[index].report({
					kind = "FinalReport", snapshot = emptySnapshot(),
				}).body)
				assert(closing.kind == "Accepted")
			end
		end
		assert(coordinator.disconnect(tokens[disconnectIndex]).kind == "Ignored")
		coordinator.disable()
	end
end

local function driveThirtyToPostTeardown(abortSource)
	local coordinator, participant, token = pair("tiny-steady-c2s")
	bindPair(coordinator, participant, token)
	for repetition = 1, 30 do
		local prepare = coordinator.command(1, { kind = "PrepareRepetition", repetitionIndex = repetition })
		participant.receive(prepare.body)
		coordinator.receive(token, participant.report({ kind = "ReadyReport", outcome = "Ready" }).body)
		if repetition == 1 then
			local challenge = coordinator.command(1, { kind = "ClockChallenge" })
			participant.receive(challenge.body)
			coordinator.receive(token, participant.report({
				kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1,
			}).body)
		end
		local warmup = coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = repetition })
		participant.receive(warmup.body)
		coordinator.receive(token, participant.report({ kind = "WarmupReport", outcome = "Clean" }).body)
		for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
		participant.receive(coordinator.command(1, {
			kind = "ArmMeasured", repetitionIndex = repetition, startSharedSeconds = repetition,
		}).body)
		if repetition == 30 and abortSource == "MeasuredTraffic" then
			assert(coordinator.command("hostile", "hostile").kind == "MeasuredControlTraffic")
			assert(participant.report("hostile").kind == "MeasuredControlTraffic")
		end
		local completed = not (repetition == 30 and abortSource == "AbortReport")
		coordinator.beginPostTeardownObservation(repetition, true, completed)
		participant.beginPostTeardownObservation(repetition)
		local outcome = if completed then "Clean" else "Abort"
		coordinator.receive(token, participant.report({
			kind = "RepetitionReport", outcome = outcome, isolationPassed = true,
		}).body)
	end
	return coordinator, participant
end

-- Complete is unreachable after either measured control traffic or an Abort report, on both mirrors.
for _, abortSource in { "MeasuredTraffic", "AbortReport" } do
	local coordinator, participant = driveThirtyToPostTeardown(abortSource)
	raises("CONTROL_PROTOCOL_E_STATE", function()
		coordinator.beginFinalReports("Complete", 30)
	end)
	local completeBody = {
		protocolVersion = 1,
		messageType = "FinishCase",
		runId = "00000000-0000-4000-8000-000000000001",
		sequence = 93,
		adapterId = "fake-event-v1",
		caseId = "tiny-steady-c2s",
		recipientCount = 1,
		repetitionIndex = 30,
		phase = "ParticipantEvidenceFreezeAndFinalReports",
		outcome = "Complete",
	}
	assert(participant.receive(completeBody).kind == "Muted", abortSource)
end

-- Arming and entering measured execution without attempting the first call
-- remains representable without synthetic timing or submit-failure evidence.
do
	local coordinator, participant, token = driveToFinal("tiny-steady-c2s", { "Abort" })
	local snapshot = emptySnapshot()
	snapshot.repetitions = { repetitionEvidence(1, false) }
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "armed no-attempt evidence must be accepted")
end

-- Participant-only measured-control evidence is valid at the coordinator,
-- while the participant that retained the local observation cannot omit it.
do
	local coordinator, participant, token = driveToFinal("tiny-steady-c2s", { "Abort" }, function(_, _, localParticipant)
		assert(localParticipant.report("hostile").kind == "MeasuredControlTraffic")
	end)
	local snapshot = emptySnapshot()
	snapshot.repetitions = { repetitionEvidence(1, false) }
	snapshot.failureFacts = {{
		code = "ControlTrafficDuringMeasuredFrames", occurrences = 1, firstRepetition = 1,
	}}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted",
		"participant-only measured-control evidence must be accepted")
end

do
	local _, participant = driveToFinal("tiny-steady-c2s", { "Abort" }, function(_, _, localParticipant)
		assert(localParticipant.report("hostile").kind == "MeasuredControlTraffic")
	end)
	local snapshot = emptySnapshot()
	snapshot.repetitions = { repetitionEvidence(1, false) }
	raises("CONTROL_PROTOCOL_E_INPUT", function()
		participant.report({ kind = "FinalReport", snapshot = snapshot })
	end)
end

-- NonFinite is valid for every numeric descriptor. Scalar integer fields keep
-- Field topology, while vectors retain their component topology.
for _, mismatch in {
	{ pathKind = "Field", fieldIndex = 2 },
	{ pathKind = "VectorComponent", fieldIndex = 3, component = "X" },
} do
	local coordinator, participant, token = driveToFinal("state-broadcast-s2c", { "Abort" })
	local snapshot = emptySnapshot()
	local repetition = repetitionEvidence(1, false)
	repetition.received = 1
	repetition.mismatch = 1
	snapshot.repetitions = { repetition }
	snapshot.failureFacts = {{
		code = "PayloadMismatch",
		occurrences = 1,
		discriminator = { kind = "MismatchReason", value = "NonFinite" },
		firstRepetition = 1,
		fixtureIndex = 1,
		mismatch = mismatch,
	}}
	local final = participant.report({ kind = "FinalReport", snapshot = snapshot })
	assert(coordinator.receive(token, final.body).kind == "Accepted", "numeric NonFinite topology must be accepted")
end

local function settledDisconnectPoisonsBarrier(count, barrierKind)
	local tokens, participants = {}, {}
	for index = 1, count do
		tokens[index] = {}
		participants[index] = ControlProtocol.newParticipant(binding("state-broadcast-s2c", count, index))
	end
	local coordinator = ControlProtocol.newCoordinator(
		binding("state-broadcast-s2c", count),
		tokens,
		function() return 1 end,
		function() return true end
	).coordinator
	local function reportsFor(commandIntent, reportIntent)
		local reports = {}
		for index = count, 1, -1 do
			participants[index].receive(coordinator.command(index, commandIntent).body)
			reports[index] = participants[index].report(reportIntent).body
		end
		return reports
	end
	local bound = reportsFor({ kind = "BindCase" }, { kind = "BoundReport" })
	for index = count, 1, -1 do assert(coordinator.receive(tokens[index], bound[index]).kind == "Accepted") end

	local ready = reportsFor(
		{ kind = "PrepareRepetition", repetitionIndex = 1 },
		{ kind = "ReadyReport", outcome = "Ready" }
	)
	if barrierKind == "ClockChallenge" then
		for index = count, 1, -1 do assert(coordinator.receive(tokens[index], ready[index]).kind == "Accepted") end
		ready = reportsFor(
			{ kind = "ClockChallenge" },
			{ kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1 }
		)
	end
	assert(coordinator.receive(tokens[count], ready[count]).kind == "Accepted")
	local disconnected = coordinator.disconnect(tokens[count])
	assert(disconnected.kind == "Disconnected" and disconnected.participantIndex == count)
	for index = count - 1, 1, -1 do
		assert(coordinator.receive(tokens[index], ready[index]).kind == "Accepted")
	end
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready",
		`settled disconnect must poison {barrierKind}/{count}`)
end

-- Reversed 4/8 barriers cannot return to Ready after a settled participant disconnects.
for _, count in { 4, 8 } do
	settledDisconnectPoisonsBarrier(count, "PrepareRepetition")
	settledDisconnectPoisonsBarrier(count, "ClockChallenge")
end

print("PASS Relay.Benchmarks.ControlProtocol")
