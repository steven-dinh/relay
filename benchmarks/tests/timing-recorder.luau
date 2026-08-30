local EventV1 = require("../contracts/event-v1")
local BenchmarkClock = require("../runner/BenchmarkClock")
local TimingRecorder = require("../runner/TimingRecorder")

local CONFIG_ERROR = "TIMING_RECORDER_E_CONFIG"
local STATE_ERROR = "TIMING_RECORDER_E_STATE"
local CLOCK_VALUE_ERROR = "BENCHMARK_CLOCK_E_VALUE"

local function assertError(callback, expected, label)
	local ok, message = pcall(callback)
	assert(not ok, `{label} must fail`)
	assert(tostring(message) == expected, `{label} leaked or returned the wrong sentinel: {tostring(message)}`)
end

local function assertExactKeys(value, expectedKeys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local expected = {}
	for _, key in expectedKeys do
		expected[key] = true
	end

	local count = 0
	for key in next, value do
		assert(type(key) == "string" and expected[key], `{label} has unexpected key {tostring(key)}`)
		count += 1
	end
	assert(count == #expectedKeys, `{label} key count differs`)
end

local function assertDeepFrozen(value, label, seen)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	assert(table.isfrozen(value), `{label} must be deeply frozen`)
	for _, nested in value do
		assertDeepFrozen(nested, label, seen)
	end
end

local function findWorkload(id)
	for _, workload in EventV1.workloads do
		if workload.id == id then
			return workload
		end
	end
	error(`missing workload {id}`)
end

local function findMeasurementIndex(id)
	for index, measurement in EventV1.measurements do
		if measurement.id == id then
			return index
		end
	end
	error(`missing measurement {id}`)
end

local function counter(first, step, onRead)
	local nextValue = first
	return function()
		if onRead ~= nil then
			onRead()
		end
		local value = nextValue
		nextValue += step
		return value
	end
end

local function sequence(values)
	local index = 0
	return function()
		index += 1
		local value = values[index]
		if value == nil then
			error("TOP-SECRET-CLOCK-EXHAUSTED")
		end
		return value
	end
end

local function clock(localReader, sharedReader)
	return BenchmarkClock.new({
		localNowSeconds = localReader or function()
			return 0
		end,
		sharedNowSeconds = sharedReader or function()
			return 0
		end,
		timeoutNowSeconds = function()
			return 0
		end,
	})
end

local function validProof()
	return {
		coordinatorBeforeSharedSeconds = 10,
		participantSharedSeconds = 10,
		coordinatorAfterSharedSeconds = 10,
		localBeforeSeconds = 20,
		localAfterSeconds = 20,
	}
end

local function frozenMutationFails(value, key, replacement, label)
	local ok = pcall(function()
		value[key] = replacement
	end)
	assert(not ok, `{label} must reject mutation`)
end

local tiny = findWorkload("tiny-steady-c2s")
local probe = EventV1.probes[1]
local frameTimeIndex = findMeasurementIndex("frameTime")
local submissionDurationIndex = findMeasurementIndex("submissionDuration")
local roundTripLatencyIndex = findMeasurementIndex("roundTripLatency")
local submitCallDurationIndex = findMeasurementIndex("submitCallDuration")

assertExactKeys(TimingRecorder, { "new" }, "TimingRecorder")
assert(table.isfrozen(TimingRecorder), "TimingRecorder module must be frozen")

-- The recorder calls an already-guarded clock reader directly. BenchmarkClock
-- remains the sole fresh-coroutine and value/monotonicity guard.
do
	local guarded = clock(counter(0, 1))
	local callerThread = coroutine.running()
	local readerThreads = {}
	local observedClock = {
		localNowSeconds = function()
			table.insert(readerThreads, coroutine.running())
			return guarded.localNowSeconds()
		end,
		sharedNowSeconds = guarded.sharedNowSeconds,
		timeoutNowSeconds = guarded.timeoutNowSeconds,
		startDeadline = guarded.startDeadline,
	}
	table.freeze(observedClock)
	local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, observedClock)
	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "direct guarded-reader proof must pass")
	recorder.markLocal("RoundTripSubmissionStarted")
	recorder.markLocal("RoundTripEchoReceived")
	assert(#readerThreads == 2, "guarded reader must be called exactly once per boundary")
	assert(readerThreads[1] == callerThread and readerThreads[2] == callerThread,
		"TimingRecorder must not add a clock-reader coroutine")
	recorder.finishRepetition(false)
	assert(recorder.freeze().clockProofPassed, "direct guarded-reader proof latch changed")
end

-- A workload sender derives its three local groups from Event V1 declaration
-- order and preserves shared sender endpoints separately.
do
	local localReads = 0
	local participant = { role = "Client", index = 1 }
	local recorder = TimingRecorder.new(
		tiny,
		participant,
		clock(counter(0, 1, function()
			localReads += 1
		end), sequence({ 10, 11 }))
	)
	participant.index = 8

	assertExactKeys(recorder, {
		"participant",
		"caseId",
		"beginRepetition",
		"enterExcluded",
		"leaveExcluded",
		"markLocal",
		"markShared",
		"captureShared",
		"resolveShared",
		"recordClockProof",
		"finishRepetition",
		"freeze",
	}, "recorder")
	assert(table.isfrozen(recorder), "recorder must be frozen")
	assertExactKeys(recorder.participant, { "role", "index" }, "recorder participant")
	assert(table.isfrozen(recorder.participant), "recorder participant must be frozen")
	assert(recorder.participant.role == "Client" and recorder.participant.index == 1, "participant must be copied")
	assert(recorder.caseId == tiny.id, "case id differs")

	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "bracket equality must pass")
	for frameIndex = 1, tiny.measuredFrames do
		recorder.markLocal("MeasuredFrameStarted")
		if frameIndex == 1 then
			recorder.markLocal("FirstMeasuredSubmissionStarted")
			recorder.markShared("FirstMeasuredSubmissionStarted")
		end
		recorder.markLocal("MeasuredSubmissionStarted")
		recorder.markLocal("MeasuredSubmissionReturned")
		if frameIndex == tiny.measuredFrames then
			recorder.markLocal("FinalMeasuredSubmissionReturned")
			recorder.markShared("FinalMeasuredSubmissionReturned")
		end
		recorder.markLocal("FollowingFrameStarted")
	end
	recorder.finishRepetition(true)

	local evidence = recorder.freeze()
	assert(recorder.freeze() == evidence, "freeze must be idempotent")
	assertDeepFrozen(evidence, "timing evidence")
	assertExactKeys(evidence, {
		"version",
		"measurements",
		"endpoints",
		"clockProofPassed",
		"timingExclusionsConfirmed",
	}, "timing evidence")
	assert(evidence.version == 1 and evidence.clockProofPassed, "evidence header differs")
	assert(#evidence.measurements == 3, "sender must emit exactly three local groups")
	assert(evidence.measurements[1].measurementIndex == frameTimeIndex, "frame group order differs")
	assert(evidence.measurements[2].measurementIndex == submissionDurationIndex, "submission group order differs")
	assert(evidence.measurements[3].measurementIndex == submitCallDurationIndex, "submit-call group order differs")
	assert(#evidence.measurements[1].values == tiny.measuredFrames, "frame cadence differs")
	assert(#evidence.measurements[2].values == 1, "submission cadence differs")
	assert(
		#evidence.measurements[3].values == tiny.measuredFrames * tiny.messagesPerFrame,
		"submit-call cadence differs"
	)
	assert(evidence.measurements[1].values[1] == 4_000, "millisecond conversion must subtract then scale")
	assert(evidence.measurements[3].values[1] == 1_000_000, "microsecond conversion must subtract then scale")
	assert(localReads == tiny.measuredFrames * 4 + 2, "local timing read cadence differs")
	assert(#evidence.endpoints == 1, "sender endpoint count differs")
	assertExactKeys(evidence.endpoints[1], {
		"repetitionIndex",
		"firstSubmissionStartedSharedSeconds",
		"finalSubmissionReturnedSharedSeconds",
	}, "sender endpoints")
	assert(evidence.endpoints[1].firstSubmissionStartedSharedSeconds == 10, "sender start endpoint differs")
	assert(evidence.endpoints[1].finalSubmissionReturnedSharedSeconds == 11, "sender finish endpoint differs")
	assert(evidence.timingExclusionsConfirmed.setup, "untouched setup exclusion must remain confirmed")
	assert(evidence.timingExclusionsConfirmed.warmup, "untouched warmup exclusion must remain confirmed")
	assert(evidence.timingExclusionsConfirmed.quiescence, "untouched quiescence exclusion must remain confirmed")
	frozenMutationFails(evidence.measurements[1].values, 1, 999, "detached measurement values")
	assertError(function()
		recorder.beginRepetition(2)
	end, STATE_ERROR, "mark after freeze")
end

-- A receiver can speculatively timestamp an expected identity before payload
-- comparison. Only the exact retained candidate contributes an endpoint.
do
	local recorder = TimingRecorder.new(tiny, { role = "Server" }, clock(nil, sequence({ 20, 21, 22, 23, 24 })))
	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "receiver proof must pass")

	local discarded = recorder.captureShared("FinalExpectedDeliveryReceived")
	assertExactKeys(discarded, { "boundary" }, "shared candidate")
	assert(table.isfrozen(discarded), "shared candidate must be frozen")
	assert(discarded.boundary == "FinalExpectedDeliveryReceived", "candidate boundary differs")
	assertError(function()
		recorder.resolveShared({ boundary = "FinalExpectedDeliveryReceived" }, true)
	end, STATE_ERROR, "forged shared candidate")
	assertError(function()
		recorder.markShared("FinalExpectedDeliveryVerified")
	end, STATE_ERROR, "mark while shared candidate pending")
	assertError(recorder.freeze, STATE_ERROR, "freeze while shared candidate pending")
	recorder.resolveShared(discarded, false)

	local retained = recorder.captureShared("FinalExpectedDeliveryReceived")
	recorder.resolveShared(retained, true)
	local duplicate = recorder.captureShared("FinalExpectedDeliveryReceived")
	recorder.resolveShared(duplicate, false)
	local duplicateRetain = recorder.captureShared("FinalExpectedDeliveryReceived")
	assertError(function()
		recorder.resolveShared(duplicateRetain, true)
	end, STATE_ERROR, "duplicate final-boundary retention")
	-- A rejected second retention resolves the pending slot before raising.
	recorder.markShared("FinalExpectedDeliveryVerified")
	recorder.finishRepetition(true)
	local evidence = recorder.freeze()
	assert(#evidence.measurements == 0, "receiver must not invent local groups")
	assert(#evidence.endpoints == 1, "receiver endpoint count differs")
	assertExactKeys(evidence.endpoints[1], {
		"repetitionIndex",
		"finalExpectedDeliveryReceivedSharedSeconds",
		"finalExpectedDeliveryVerifiedSharedSeconds",
	}, "receiver endpoints")
	assert(evidence.endpoints[1].finalExpectedDeliveryReceivedSharedSeconds == 21, "discarded time was retained")
	assert(evidence.endpoints[1].finalExpectedDeliveryVerifiedSharedSeconds == 24, "verified time differs")
end

-- Probe timing remains wholly on the probe client's local clock, including
-- zero-duration samples, and emits an empty endpoint arm.
do
	local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock(counter(5, 0)))
	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "probe proof must pass")
	for _ = 1, probe.measuredSamples do
		recorder.markLocal("RoundTripSubmissionStarted")
		recorder.markLocal("RoundTripEchoReceived")
	end
	recorder.finishRepetition(true)
	local evidence = recorder.freeze()
	assert(#evidence.measurements == 1, "probe must emit one measurement group")
	local measurement = evidence.measurements[1]
	assert(measurement.measurementIndex == roundTripLatencyIndex, "probe measurement index differs")
	assert(#measurement.values == probe.measuredSamples, "probe cadence differs")
	for _, value in measurement.values do
		assert(value == 0, "zero local delta must remain zero")
	end
	assertExactKeys(evidence.endpoints[1], { "repetitionIndex" }, "probe endpoint")
end

-- Failed repetitions retain only legal progressive endpoints and no raw group.
do
	local recorder = TimingRecorder.new(tiny, { role = "Client", index = 1 }, clock(sequence({ 1, 2 }), sequence({ 30 })))
	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "incomplete sender proof must pass")
	recorder.markLocal("FirstMeasuredSubmissionStarted")
	recorder.markShared("FirstMeasuredSubmissionStarted")
	recorder.finishRepetition(false)
	local evidence = recorder.freeze()
	assert(#evidence.measurements == 0, "incomplete repetition must emit no raw group")
	assertExactKeys(evidence.endpoints[1], {
		"repetitionIndex",
		"firstSubmissionStartedSharedSeconds",
	}, "incomplete sender endpoint")
	assert(evidence.endpoints[1].firstSubmissionStartedSharedSeconds == 30, "first-only endpoint differs")
end

-- Exclusion bracketing latches only the affected category. Marks made while
-- excluded do not read a measurement clock.
do
	local reads = 0
	local recorder = TimingRecorder.new(tiny, { role = "Client", index = 1 }, clock(counter(0, 1, function()
		reads += 1
	end), sequence({ 40 })))
	recorder.enterExcluded("setup")
	recorder.markLocal("MeasuredFrameStarted")
	assert(not recorder.leaveExcluded("setup"), "mark during setup must latch setup false")
	assert(reads == 0, "excluded mark must not read local clock")

	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "exclusion proof must pass")
	recorder.markLocal("MeasuredFrameStarted")
	recorder.enterExcluded("warmup")
	assert(not recorder.leaveExcluded("warmup"), "open boundary must latch warmup false")
	recorder.enterExcluded("quiescence")
	recorder.markShared("FirstMeasuredSubmissionStarted")
	assert(not recorder.leaveExcluded("quiescence"), "shared mark during exclusion must latch quiescence false")
	recorder.finishRepetition(false)
	local evidence = recorder.freeze()
	assert(not evidence.timingExclusionsConfirmed.setup, "setup latch recovered")
	assert(not evidence.timingExclusionsConfirmed.warmup, "warmup latch recovered")
	assert(not evidence.timingExclusionsConfirmed.quiescence, "quiescence latch recovered")
end

-- Clock proof accepts equality and rejects malformed, nonfinite, decreasing,
-- negative, and out-of-bracket evidence without reflecting supplied values.
do
	local invalidProofs = {
		{ label = "missing", proof = { coordinatorBeforeSharedSeconds = 0 } },
		{ label = "extra", proof = {
			coordinatorBeforeSharedSeconds = 0,
			participantSharedSeconds = 0,
			coordinatorAfterSharedSeconds = 0,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
			extra = "TOP-SECRET-PROOF",
		} },
		{ label = "coordinator decrease", proof = {
			coordinatorBeforeSharedSeconds = 2,
			participantSharedSeconds = 2,
			coordinatorAfterSharedSeconds = 1,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
		{ label = "participant below", proof = {
			coordinatorBeforeSharedSeconds = 1,
			participantSharedSeconds = 0,
			coordinatorAfterSharedSeconds = 2,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
		{ label = "participant above", proof = {
			coordinatorBeforeSharedSeconds = 1,
			participantSharedSeconds = 3,
			coordinatorAfterSharedSeconds = 2,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
		{ label = "local decrease", proof = {
			coordinatorBeforeSharedSeconds = 1,
			participantSharedSeconds = 1,
			coordinatorAfterSharedSeconds = 1,
			localBeforeSeconds = 2,
			localAfterSeconds = 1,
		} },
		{ label = "NaN", proof = {
			coordinatorBeforeSharedSeconds = 0 / 0,
			participantSharedSeconds = 0,
			coordinatorAfterSharedSeconds = 0,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
		{ label = "infinity", proof = {
			coordinatorBeforeSharedSeconds = 0,
			participantSharedSeconds = math.huge,
			coordinatorAfterSharedSeconds = math.huge,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
		{ label = "negative", proof = {
			coordinatorBeforeSharedSeconds = -1,
			participantSharedSeconds = 0,
			coordinatorAfterSharedSeconds = 0,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
		{ label = "negative zero", proof = {
			coordinatorBeforeSharedSeconds = -0,
			participantSharedSeconds = 0,
			coordinatorAfterSharedSeconds = 0,
			localBeforeSeconds = 0,
			localAfterSeconds = 0,
		} },
	}

	for _, case in invalidProofs do
		local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock())
		assert(not recorder.recordClockProof(case.proof), `{case.label} proof must fail`)
		assert(not recorder.freeze().clockProofPassed, `{case.label} proof latch recovered`)
	end

	local metatableProof = validProof()
	setmetatable(metatableProof, {})
	local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock())
	assert(not recorder.recordClockProof(metatableProof), "metatable proof must fail")
	assertError(function()
		recorder.recordClockProof(validProof())
	end, STATE_ERROR, "clock proof retry")

	local missing = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock())
	missing.beginRepetition(1)
	assert(not missing.recordClockProof(nil), "missing guarded proof must latch false")
	missing.finishRepetition(false)
	assert(not missing.freeze().clockProofPassed, "missing proof latch recovered")
end

-- A bad guarded endpoint emits no sample, permanently fails clock proof, and
-- reports only the fixed clock sentinel. Conversion overflow follows the same
-- path after subtract-before-scale.
do
	for _, case in {
		{ label = "decreasing local endpoint", values = { 2, 1 } },
		{ label = "nonfinite local endpoint", values = { 0, math.huge } },
		{ label = "overflowing conversion", values = { 0, 1e308 } },
	} do
		local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock(sequence(case.values)))
		recorder.beginRepetition(1)
		assert(recorder.recordClockProof(validProof()), `{case.label} proof must pass first`)
		recorder.markLocal("RoundTripSubmissionStarted")
		assertError(function()
			recorder.markLocal("RoundTripEchoReceived")
		end, CLOCK_VALUE_ERROR, case.label)
		recorder.finishRepetition(false)
		local evidence = recorder.freeze()
		assert(not evidence.clockProofPassed, `{case.label} must fail clock proof`)
		assert(#evidence.measurements == 0, `{case.label} must insert no sample`)
	end

	local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock(function()
		error("TOP-SECRET-CLOCK")
	end))
	recorder.beginRepetition(1)
	assert(recorder.recordClockProof(validProof()), "throwing-clock proof must pass before read")
	assertError(function()
		recorder.markLocal("RoundTripSubmissionStarted")
	end, CLOCK_VALUE_ERROR, "throwing local clock")
	recorder.finishRepetition(false)
	assert(not recorder.freeze().clockProofPassed, "throwing clock latch recovered")
end

-- Trusted misuse is rejected before timing reads or partial evidence changes.
do
	local recorder = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock())
	recorder.beginRepetition(1)
	assertError(function()
		recorder.markLocal("RoundTripEchoReceived")
	end, STATE_ERROR, "finish before start")
	assertError(function()
		recorder.finishRepetition(true)
	end, STATE_ERROR, "completed cardinality shortfall")
	recorder.finishRepetition(false)
	assertError(function()
		recorder.beginRepetition(3)
	end, STATE_ERROR, "nonsequential repetition")

	local receiver = TimingRecorder.new(tiny, { role = "Server" }, clock())
	receiver.beginRepetition(1)
	assert(receiver.recordClockProof(validProof()), "receiver state proof must pass")
	assertError(function()
		receiver.markLocal("MeasuredFrameStarted")
	end, STATE_ERROR, "receiver-owned local boundary")
	assertError(function()
		receiver.markShared("FinalExpectedDeliveryReceived")
	end, STATE_ERROR, "receipt must use candidate path")
	assertError(function()
		receiver.captureShared("FinalExpectedDeliveryVerified")
	end, STATE_ERROR, "wrong capture boundary")
	receiver.finishRepetition(false)
end

-- Configuration accepts only canonical contract cases, exact participant
-- roles, and the frozen BenchmarkClock surface.
do
	local canonicalClock = clock()
	local clonedCase = table.clone(tiny)
	for _, case in {
		{ label = "noncanonical case", caseDefinition = clonedCase, participant = { role = "Client", index = 1 }, clock = canonicalClock },
		{ label = "probe client for workload", caseDefinition = tiny, participant = { role = "ProbeClient", index = 1 }, clock = canonicalClock },
		{ label = "client for probe", caseDefinition = probe, participant = { role = "Client", index = 1 }, clock = canonicalClock },
		{ label = "out-of-range participant", caseDefinition = tiny, participant = { role = "Client", index = 9 }, clock = canonicalClock },
		{ label = "extra participant key", caseDefinition = tiny, participant = { role = "Client", index = 1, secret = true }, clock = canonicalClock },
		{ label = "mutable clock", caseDefinition = tiny, participant = { role = "Client", index = 1 }, clock = {
			localNowSeconds = function() return 0 end,
			sharedNowSeconds = function() return 0 end,
			timeoutNowSeconds = function() return 0 end,
			startDeadline = function() return { check = function() return { kind = "Active" } end } end,
		} },
	} do
		assertError(function()
			TimingRecorder.new(case.caseDefinition, case.participant, case.clock)
		end, CONFIG_ERROR, case.label)
	end
end

print("PASS Relay.Benchmarks.TimingRecorder")
