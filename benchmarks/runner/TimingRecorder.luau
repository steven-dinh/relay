--!strict

local EventV1 = require("../contracts/event-v1")
local BenchmarkClock = require("./BenchmarkClock")
local SessionOwner = require("./SessionOwner")

export type ClockBracket = {
	coordinatorBeforeSharedSeconds: number,
	participantSharedSeconds: number,
	coordinatorAfterSharedSeconds: number,
	localBeforeSeconds: number,
	localAfterSeconds: number,
}

export type ParticipantMeasurementV1 = {
	measurementIndex: number,
	repetitionIndex: number,
	values: { number },
}

export type ParticipantTimingEndpointsV1 =
	{ repetitionIndex: number }
	| { repetitionIndex: number, firstSubmissionStartedSharedSeconds: number }
	| {
		repetitionIndex: number,
		firstSubmissionStartedSharedSeconds: number,
		finalSubmissionReturnedSharedSeconds: number,
	}
	| {
		repetitionIndex: number,
		finalExpectedDeliveryReceivedSharedSeconds: number,
		finalExpectedDeliveryVerifiedSharedSeconds: number,
	}

export type TimingExclusion = "setup" | "warmup" | "quiescence"

export type SharedBoundaryCandidate = {
	boundary: EventV1.TimingBoundary,
}

export type TimingEvidence = {
	version: number,
	measurements: { ParticipantMeasurementV1 },
	endpoints: { ParticipantTimingEndpointsV1 },
	clockProofPassed: boolean,
	timingExclusionsConfirmed: {
		setup: boolean,
		warmup: boolean,
		quiescence: boolean,
	},
}

export type Recorder = {
	participant: SessionOwner.ParticipantRef,
	caseId: string,
	beginRepetition: (repetitionIndex: number) -> (),
	enterExcluded: (exclusion: TimingExclusion) -> (),
	leaveExcluded: (exclusion: TimingExclusion) -> boolean,
	markLocal: (boundary: EventV1.TimingBoundary) -> (),
	markShared: (boundary: EventV1.TimingBoundary) -> (),
	captureShared: (boundary: EventV1.TimingBoundary) -> SharedBoundaryCandidate,
	resolveShared: (candidate: SharedBoundaryCandidate, retain: boolean) -> (),
	recordClockProof: (proof: ClockBracket?) -> boolean,
	finishRepetition: (completed: boolean) -> (),
	freeze: () -> TimingEvidence,
}

type LocalMeasurementSpec = {
	measurementIndex: number,
	startBoundary: EventV1.TimingBoundary,
	finishBoundary: EventV1.TimingBoundary,
	cadence: EventV1.SampleCadence,
	expectedValues: number,
	unit: string,
}

local CONFIG_ERROR = "TIMING_RECORDER_E_CONFIG"
local STATE_ERROR = "TIMING_RECORDER_E_STATE"
local CLOCK_VALUE_ERROR = "BENCHMARK_CLOCK_E_VALUE"

local PARTICIPANT_SERVER_KEYS = {
	role = true,
}

local PARTICIPANT_INDEXED_KEYS = {
	role = true,
	index = true,
}

local CLOCK_KEYS = {
	localNowSeconds = true,
	sharedNowSeconds = true,
	timeoutNowSeconds = true,
	startDeadline = true,
}

local PROOF_KEYS = {
	coordinatorBeforeSharedSeconds = true,
	participantSharedSeconds = true,
	coordinatorAfterSharedSeconds = true,
	localBeforeSeconds = true,
	localAfterSeconds = true,
}

local EXCLUSIONS = {
	setup = true,
	warmup = true,
	quiescence = true,
}

local function fail(code: string): never
	error(code, 0)
end

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: number): boolean
	return value == 0 and 1 / value == -math.huge
end

local function isPositiveInteger(value: unknown): boolean
	return type(value) == "number"
		and isFinite(value :: number)
		and value :: number > 0
		and value :: number % 1 == 0
end

local function isExactPlainTable(candidate: unknown, keys: { [string]: boolean }, expectedCount: number): boolean
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		return false
	end

	local count = 0
	for key in next, candidate :: any do
		if type(key) ~= "string" or rawget(keys, key) ~= true then
			return false
		end
		count += 1
	end

	return count == expectedCount
end

local function isCanonicalCase(candidate: unknown): boolean
	for _, workload in EventV1.workloads do
		if candidate == workload then
			return true
		end
	end

	for _, probe in EventV1.probes do
		if candidate == probe then
			return true
		end
	end

	return false
end

local function isProbeCase(caseDefinition: EventV1.Workload | EventV1.Probe): boolean
	for _, probe in EventV1.probes do
		if caseDefinition == probe then
			return true
		end
	end

	return false
end

local function copyParticipant(
	candidate: SessionOwner.ParticipantRef,
	caseDefinition: EventV1.Workload | EventV1.Probe,
	probeCase: boolean
): SessionOwner.ParticipantRef
	local source: any = candidate
	local role = if type(source) == "table" then rawget(source, "role") else nil

	if role == "Server" then
		if not isExactPlainTable(candidate, PARTICIPANT_SERVER_KEYS, 1) then
			fail(CONFIG_ERROR)
		end

		local copied: SessionOwner.ParticipantRef = { role = "Server" }
		table.freeze(copied)
		return copied
	end

	if role ~= "Client" and role ~= "ProbeClient" then
		fail(CONFIG_ERROR)
	end
	if not isExactPlainTable(candidate, PARTICIPANT_INDEXED_KEYS, 2) then
		fail(CONFIG_ERROR)
	end

	local index = rawget(source, "index")
	if not isPositiveInteger(index) or index > EventV1.execution.maximumClients then
		fail(CONFIG_ERROR)
	end
	if probeCase then
		local probe = caseDefinition :: EventV1.Probe
		if role ~= "ProbeClient" or index > probe.clientCount then
			fail(CONFIG_ERROR)
		end
	else
		local workload = caseDefinition :: EventV1.Workload
		if role ~= "Client" then
			fail(CONFIG_ERROR)
		end
		if workload.direction == "ClientToServer" and index > workload.senderCount then
			fail(CONFIG_ERROR)
		end
	end

	local copied: SessionOwner.ParticipantRef = {
		role = role,
		index = index,
	}
	table.freeze(copied)
	return copied
end

local function validateClock(clock: BenchmarkClock.Clock)
	if not isExactPlainTable(clock, CLOCK_KEYS, 4) or not table.isfrozen(clock :: any) then
		fail(CONFIG_ERROR)
	end

	local source: any = clock
	if type(rawget(source, "localNowSeconds")) ~= "function"
		or type(rawget(source, "sharedNowSeconds")) ~= "function"
		or type(rawget(source, "timeoutNowSeconds")) ~= "function"
		or type(rawget(source, "startDeadline")) ~= "function"
	then
		fail(CONFIG_ERROR)
	end
end

local function ownsSenderBoundary(
	caseDefinition: EventV1.Workload,
	participant: SessionOwner.ParticipantRef
): boolean
	if caseDefinition.direction == "ServerToClient" then
		return participant.role == "Server"
	end

	return participant.role == "Client" and participant.index <= caseDefinition.senderCount
end

local function ownsReceiverBoundary(
	caseDefinition: EventV1.Workload,
	participant: SessionOwner.ParticipantRef
): boolean
	if caseDefinition.direction == "ClientToServer" then
		return participant.role == "Server"
	end

	return participant.role == "Client"
end

local function expectedCardinality(
	caseDefinition: EventV1.Workload | EventV1.Probe,
	probeCase: boolean,
	cadence: EventV1.SampleCadence
): number
	if probeCase then
		local probe = caseDefinition :: EventV1.Probe
		if cadence ~= "PerProbe" then
			fail(CONFIG_ERROR)
		end
		return probe.measuredSamples
	end

	local workload = caseDefinition :: EventV1.Workload
	if cadence == "PerMeasuredFrame" then
		return workload.measuredFrames
	elseif cadence == "PerRepetition" then
		return 1
	elseif cadence == "PerSubmission" then
		return workload.measuredFrames * workload.messagesPerFrame
	end

	fail(CONFIG_ERROR)
end

local function copyAndDeepFreezeEvidence(
	measurements: { ParticipantMeasurementV1 },
	endpoints: { ParticipantTimingEndpointsV1 },
	clockProofPassed: boolean,
	exclusionConfirmed: { [TimingExclusion]: boolean }
): TimingEvidence
	local copiedMeasurements: { ParticipantMeasurementV1 } = {}
	for _, measurement in measurements do
		local copiedValues: { number } = {}
		for _, value in measurement.values do
			table.insert(copiedValues, value)
		end
		table.freeze(copiedValues)

		local copiedMeasurement: ParticipantMeasurementV1 = {
			measurementIndex = measurement.measurementIndex,
			repetitionIndex = measurement.repetitionIndex,
			values = copiedValues,
		}
		table.freeze(copiedMeasurement)
		table.insert(copiedMeasurements, copiedMeasurement)
	end
	table.freeze(copiedMeasurements)

	local copiedEndpoints: { ParticipantTimingEndpointsV1 } = {}
	for _, endpoint in endpoints do
		local copiedEndpoint: ParticipantTimingEndpointsV1
		if endpoint.firstSubmissionStartedSharedSeconds ~= nil then
			if endpoint.finalSubmissionReturnedSharedSeconds ~= nil then
				copiedEndpoint = {
					repetitionIndex = endpoint.repetitionIndex,
					firstSubmissionStartedSharedSeconds = endpoint.firstSubmissionStartedSharedSeconds,
					finalSubmissionReturnedSharedSeconds = endpoint.finalSubmissionReturnedSharedSeconds,
				}
			else
				copiedEndpoint = {
					repetitionIndex = endpoint.repetitionIndex,
					firstSubmissionStartedSharedSeconds = endpoint.firstSubmissionStartedSharedSeconds,
				}
			end
		elseif endpoint.finalExpectedDeliveryReceivedSharedSeconds ~= nil then
			copiedEndpoint = {
				repetitionIndex = endpoint.repetitionIndex,
				finalExpectedDeliveryReceivedSharedSeconds = endpoint.finalExpectedDeliveryReceivedSharedSeconds,
				finalExpectedDeliveryVerifiedSharedSeconds = endpoint.finalExpectedDeliveryVerifiedSharedSeconds,
			}
		else
			copiedEndpoint = { repetitionIndex = endpoint.repetitionIndex }
		end
		table.freeze(copiedEndpoint)
		table.insert(copiedEndpoints, copiedEndpoint)
	end
	table.freeze(copiedEndpoints)

	local copiedExclusions = {
		setup = exclusionConfirmed.setup,
		warmup = exclusionConfirmed.warmup,
		quiescence = exclusionConfirmed.quiescence,
	}
	table.freeze(copiedExclusions)

	local evidence: TimingEvidence = {
		version = 1,
		measurements = copiedMeasurements,
		endpoints = copiedEndpoints,
		clockProofPassed = clockProofPassed,
		timingExclusionsConfirmed = copiedExclusions,
	}
	table.freeze(evidence)
	return evidence
end

local function new(
	caseDefinition: EventV1.Workload | EventV1.Probe,
	participantCandidate: SessionOwner.ParticipantRef,
	clock: BenchmarkClock.Clock
): Recorder
	if not isCanonicalCase(caseDefinition) then
		fail(CONFIG_ERROR)
	end
	validateClock(clock)

	local probeCase = isProbeCase(caseDefinition)
	local participant = copyParticipant(participantCandidate, caseDefinition, probeCase)
	local caseId = caseDefinition.id
	local workload = if probeCase then nil else caseDefinition :: EventV1.Workload
	local sender = workload ~= nil and ownsSenderBoundary(workload, participant)
	local receiver = workload ~= nil and ownsReceiverBoundary(workload, participant)

	if not probeCase and not sender and not receiver then
		fail(CONFIG_ERROR)
	end

	local localSpecs: { LocalMeasurementSpec } = {}
	local caseScope: EventV1.MeasurementScope = if probeCase then "SeparateProbe" else "Workload"
	for measurementIndex, measurement in EventV1.measurements do
		local ownsRole = (measurement.capture.role == "Sender" and sender)
			or (measurement.capture.role == "ProbeClient" and participant.role == "ProbeClient")
		if measurement.scope == caseScope and measurement.capture.source == "os.clock" and ownsRole then
			if measurement.timing == nil then
				fail(CONFIG_ERROR)
			end
			if probeCase and measurement.probeId ~= caseId then
				continue
			end
			if measurement.unit ~= "milliseconds" and measurement.unit ~= "microsecondsPerEvent" then
				fail(CONFIG_ERROR)
			end

			local spec: LocalMeasurementSpec = {
				measurementIndex = measurementIndex,
				startBoundary = measurement.timing.start,
				finishBoundary = measurement.timing.finish,
				cadence = measurement.capture.cadence,
				expectedValues = expectedCardinality(caseDefinition, probeCase, measurement.capture.cadence),
				unit = measurement.unit,
			}
			table.insert(localSpecs, spec)
		end
	end

	local measurements: { ParticipantMeasurementV1 } = {}
	local endpoints: { ParticipantTimingEndpointsV1 } = {}
	local exclusionConfirmed: { [TimingExclusion]: boolean } = {
		setup = true,
		warmup = true,
		quiescence = true,
	}

	local activeRepetitionIndex: number? = nil
	local nextRepetitionIndex = 1
	local activeExclusion: TimingExclusion? = nil
	local currentValues: { [number]: { number } } = {}
	local localStarts: { [number]: number } = {}
	local firstSubmissionStartedSharedSeconds: number? = nil
	local finalSubmissionReturnedSharedSeconds: number? = nil
	local finalExpectedDeliveryReceivedSharedSeconds: number? = nil
	local finalExpectedDeliveryVerifiedSharedSeconds: number? = nil
	local pendingCandidate: SharedBoundaryCandidate? = nil
	local pendingSharedSeconds: number? = nil
	local clockProofRecorded = false
	local clockProofPassed = true
	local frozenEvidence: TimingEvidence? = nil

	local function requireMutable()
		if frozenEvidence ~= nil then
			fail(STATE_ERROR)
		end
	end

	local function requireNoPending()
		if pendingCandidate ~= nil then
			fail(STATE_ERROR)
		end
	end

	local function hasOpenBoundary(): boolean
		if next(localStarts) ~= nil then
			return true
		end
		if sender and firstSubmissionStartedSharedSeconds ~= nil and finalSubmissionReturnedSharedSeconds == nil then
			return true
		end
		if receiver
			and finalExpectedDeliveryReceivedSharedSeconds ~= nil
			and finalExpectedDeliveryVerifiedSharedSeconds == nil
		then
			return true
		end
		return false
	end

	local function readClock(reader: () -> number): number
		local ok, value = pcall(reader)
		if not ok then
			clockProofPassed = false
			fail(CLOCK_VALUE_ERROR)
		end
		return value
	end

	local function convertDuration(spec: LocalMeasurementSpec, startSeconds: number, finishSeconds: number): number
		local converter = if spec.unit == "milliseconds"
			then BenchmarkClock.millisecondsBetween
			else BenchmarkClock.microsecondsBetween
		local results = table.pack(pcall(converter, startSeconds, finishSeconds))
		if results[1] ~= true or results.n ~= 2 or type(results[2]) ~= "number" then
			clockProofPassed = false
			fail(CLOCK_VALUE_ERROR)
		end
		return results[2]
	end

	local function localBoundaryOwned(boundary: EventV1.TimingBoundary): boolean
		for _, spec in localSpecs do
			if spec.startBoundary == boundary or spec.finishBoundary == boundary then
				return true
			end
		end
		return false
	end

	local function sharedBoundaryOwned(boundary: EventV1.TimingBoundary): boolean
		if sender then
			return boundary == "FirstMeasuredSubmissionStarted" or boundary == "FinalMeasuredSubmissionReturned"
		end
		if receiver then
			return boundary == "FinalExpectedDeliveryReceived" or boundary == "FinalExpectedDeliveryVerified"
		end
		return false
	end

	local function requireTimingReady()
		if not clockProofRecorded or not clockProofPassed then
			fail(STATE_ERROR)
		end
	end

	local function beginRepetition(repetitionIndex: number)
		requireMutable()
		requireNoPending()
		if activeRepetitionIndex ~= nil
			or activeExclusion ~= nil
			or not isPositiveInteger(repetitionIndex)
			or repetitionIndex ~= nextRepetitionIndex
			or repetitionIndex > caseDefinition.repetitions
		then
			fail(STATE_ERROR)
		end

		activeRepetitionIndex = repetitionIndex
		currentValues = {}
		for _, spec in localSpecs do
			currentValues[spec.measurementIndex] = {}
		end
		localStarts = {}
		firstSubmissionStartedSharedSeconds = nil
		finalSubmissionReturnedSharedSeconds = nil
		finalExpectedDeliveryReceivedSharedSeconds = nil
		finalExpectedDeliveryVerifiedSharedSeconds = nil
	end

	local function enterExcluded(exclusion: TimingExclusion)
		requireMutable()
		requireNoPending()
		if rawget(EXCLUSIONS, exclusion :: any) ~= true or activeExclusion ~= nil then
			fail(STATE_ERROR)
		end
		if hasOpenBoundary() then
			exclusionConfirmed[exclusion] = false
		end
		activeExclusion = exclusion
	end

	local function leaveExcluded(exclusion: TimingExclusion): boolean
		requireMutable()
		requireNoPending()
		if rawget(EXCLUSIONS, exclusion :: any) ~= true or activeExclusion ~= exclusion then
			fail(STATE_ERROR)
		end
		if hasOpenBoundary() then
			exclusionConfirmed[exclusion] = false
		end
		activeExclusion = nil
		return exclusionConfirmed[exclusion]
	end

	local function markLocal(boundary: EventV1.TimingBoundary)
		requireMutable()
		requireNoPending()
		if not localBoundaryOwned(boundary) then
			fail(STATE_ERROR)
		end
		if activeExclusion ~= nil then
			exclusionConfirmed[activeExclusion] = false
			return
		end
		if activeRepetitionIndex == nil then
			fail(STATE_ERROR)
		end
		requireTimingReady()

		for _, spec in localSpecs do
			if spec.startBoundary == boundary then
				local values = currentValues[spec.measurementIndex]
				if localStarts[spec.measurementIndex] ~= nil or values == nil or #values >= spec.expectedValues then
					fail(STATE_ERROR)
				end
			elseif spec.finishBoundary == boundary and localStarts[spec.measurementIndex] == nil then
				fail(STATE_ERROR)
			end
		end

		local nowSeconds = readClock(clock.localNowSeconds)
		for _, spec in localSpecs do
			if spec.startBoundary == boundary then
				localStarts[spec.measurementIndex] = nowSeconds
			elseif spec.finishBoundary == boundary then
				local startSeconds = localStarts[spec.measurementIndex]
				local values = currentValues[spec.measurementIndex]
				if startSeconds == nil or values == nil then
					fail(STATE_ERROR)
				end
				local value = convertDuration(spec, startSeconds, nowSeconds)
				table.insert(values, value)
				localStarts[spec.measurementIndex] = nil
			end
		end
	end

	local function markShared(boundary: EventV1.TimingBoundary)
		requireMutable()
		requireNoPending()
		if not sharedBoundaryOwned(boundary) or boundary == "FinalExpectedDeliveryReceived" then
			fail(STATE_ERROR)
		end
		if activeExclusion ~= nil then
			exclusionConfirmed[activeExclusion] = false
			return
		end
		if activeRepetitionIndex == nil then
			fail(STATE_ERROR)
		end
		requireTimingReady()

		if boundary == "FirstMeasuredSubmissionStarted" then
			if firstSubmissionStartedSharedSeconds ~= nil then
				fail(STATE_ERROR)
			end
		elseif boundary == "FinalMeasuredSubmissionReturned" then
			if firstSubmissionStartedSharedSeconds == nil or finalSubmissionReturnedSharedSeconds ~= nil then
				fail(STATE_ERROR)
			end
		elseif boundary == "FinalExpectedDeliveryVerified" then
			if finalExpectedDeliveryReceivedSharedSeconds == nil
				or finalExpectedDeliveryVerifiedSharedSeconds ~= nil
			then
				fail(STATE_ERROR)
			end
		else
			fail(STATE_ERROR)
		end

		local nowSeconds = readClock(clock.sharedNowSeconds)
		if boundary == "FirstMeasuredSubmissionStarted" then
			firstSubmissionStartedSharedSeconds = nowSeconds
		elseif boundary == "FinalMeasuredSubmissionReturned" then
			finalSubmissionReturnedSharedSeconds = nowSeconds
		else
			finalExpectedDeliveryVerifiedSharedSeconds = nowSeconds
		end
	end

	local function captureShared(boundary: EventV1.TimingBoundary): SharedBoundaryCandidate
		requireMutable()
		requireNoPending()
		if boundary ~= "FinalExpectedDeliveryReceived" or not sharedBoundaryOwned(boundary) then
			fail(STATE_ERROR)
		end
		if activeExclusion ~= nil then
			exclusionConfirmed[activeExclusion] = false
			fail(STATE_ERROR)
		end
		if activeRepetitionIndex == nil then
			fail(STATE_ERROR)
		end
		requireTimingReady()

		local sharedSeconds = readClock(clock.sharedNowSeconds)
		local candidate: SharedBoundaryCandidate = { boundary = boundary }
		table.freeze(candidate)
		pendingCandidate = candidate
		pendingSharedSeconds = sharedSeconds
		return candidate
	end

	local function resolveShared(candidate: SharedBoundaryCandidate, retain: boolean)
		requireMutable()
		if pendingCandidate == nil
			or candidate ~= pendingCandidate
			or type(retain) ~= "boolean"
			or pendingSharedSeconds == nil
		then
			fail(STATE_ERROR)
		end

		local alreadyRetained = finalExpectedDeliveryReceivedSharedSeconds ~= nil
		if retain and not alreadyRetained then
			finalExpectedDeliveryReceivedSharedSeconds = pendingSharedSeconds
		end
		pendingCandidate = nil
		pendingSharedSeconds = nil
		if retain and alreadyRetained then
			fail(STATE_ERROR)
		end
	end

	local function recordClockProof(proof: ClockBracket?): boolean
		requireMutable()
		requireNoPending()
		if clockProofRecorded or activeExclusion ~= nil or hasOpenBoundary() then
			fail(STATE_ERROR)
		end
		clockProofRecorded = true
		if proof == nil then
			clockProofPassed = false
			return false
		end

		if not isExactPlainTable(proof, PROOF_KEYS, 5) then
			clockProofPassed = false
			return false
		end

		local source: any = proof
		local coordinatorBefore = rawget(source, "coordinatorBeforeSharedSeconds")
		local participantShared = rawget(source, "participantSharedSeconds")
		local coordinatorAfter = rawget(source, "coordinatorAfterSharedSeconds")
		local localBefore = rawget(source, "localBeforeSeconds")
		local localAfter = rawget(source, "localAfterSeconds")
		for _, value in { coordinatorBefore, participantShared, coordinatorAfter, localBefore, localAfter } do
			if type(value) ~= "number" or not isFinite(value) or value < 0 or isNegativeZero(value) then
				clockProofPassed = false
				return false
			end
		end

		if coordinatorAfter < coordinatorBefore
			or participantShared < coordinatorBefore
			or participantShared > coordinatorAfter
			or localAfter < localBefore
		then
			clockProofPassed = false
		end
		return clockProofPassed
	end

	local function finishRepetition(completed: boolean)
		requireMutable()
		requireNoPending()
		if type(completed) ~= "boolean" or activeRepetitionIndex == nil or activeExclusion ~= nil then
			fail(STATE_ERROR)
		end

		local repetitionIndex = activeRepetitionIndex
		if completed then
			if not clockProofRecorded or not clockProofPassed or next(localStarts) ~= nil then
				fail(STATE_ERROR)
			end
			for _, spec in localSpecs do
				local values = currentValues[spec.measurementIndex]
				if values == nil or #values ~= spec.expectedValues then
					fail(STATE_ERROR)
				end
			end
			if sender
				and (firstSubmissionStartedSharedSeconds == nil or finalSubmissionReturnedSharedSeconds == nil)
			then
				fail(STATE_ERROR)
			end
			if receiver
				and (
					finalExpectedDeliveryReceivedSharedSeconds == nil
					or finalExpectedDeliveryVerifiedSharedSeconds == nil
				)
			then
				fail(STATE_ERROR)
			end

			for _, spec in localSpecs do
				local values = currentValues[spec.measurementIndex]
				local copiedValues: { number } = {}
				for _, value in values do
					table.insert(copiedValues, value)
				end
				local measurement: ParticipantMeasurementV1 = {
					measurementIndex = spec.measurementIndex,
					repetitionIndex = repetitionIndex,
					values = copiedValues,
				}
				table.insert(measurements, measurement)
			end
		end

		local endpoint: ParticipantTimingEndpointsV1
		if sender and firstSubmissionStartedSharedSeconds ~= nil then
			if finalSubmissionReturnedSharedSeconds ~= nil then
				endpoint = {
					repetitionIndex = repetitionIndex,
					firstSubmissionStartedSharedSeconds = firstSubmissionStartedSharedSeconds,
					finalSubmissionReturnedSharedSeconds = finalSubmissionReturnedSharedSeconds,
				}
			else
				endpoint = {
					repetitionIndex = repetitionIndex,
					firstSubmissionStartedSharedSeconds = firstSubmissionStartedSharedSeconds,
				}
			end
		elseif receiver
			and finalExpectedDeliveryReceivedSharedSeconds ~= nil
			and finalExpectedDeliveryVerifiedSharedSeconds ~= nil
		then
			endpoint = {
				repetitionIndex = repetitionIndex,
				finalExpectedDeliveryReceivedSharedSeconds = finalExpectedDeliveryReceivedSharedSeconds,
				finalExpectedDeliveryVerifiedSharedSeconds = finalExpectedDeliveryVerifiedSharedSeconds,
			}
		else
			endpoint = { repetitionIndex = repetitionIndex }
		end
		table.insert(endpoints, endpoint)

		activeRepetitionIndex = nil
		nextRepetitionIndex += 1
		currentValues = {}
		localStarts = {}
		firstSubmissionStartedSharedSeconds = nil
		finalSubmissionReturnedSharedSeconds = nil
		finalExpectedDeliveryReceivedSharedSeconds = nil
		finalExpectedDeliveryVerifiedSharedSeconds = nil
	end

	local function freeze(): TimingEvidence
		if frozenEvidence ~= nil then
			return frozenEvidence
		end
		requireNoPending()
		if activeRepetitionIndex ~= nil or activeExclusion ~= nil or hasOpenBoundary() then
			fail(STATE_ERROR)
		end

		local evidence = copyAndDeepFreezeEvidence(
			measurements,
			endpoints,
			clockProofPassed,
			exclusionConfirmed
		)
		frozenEvidence = evidence
		return evidence
	end

	local recorder: Recorder = {
		participant = participant,
		caseId = caseId,
		beginRepetition = beginRepetition,
		enterExcluded = enterExcluded,
		leaveExcluded = leaveExcluded,
		markLocal = markLocal,
		markShared = markShared,
		captureShared = captureShared,
		resolveShared = resolveShared,
		recordClockProof = recordClockProof,
		finishRepetition = finishRepetition,
		freeze = freeze,
	}
	table.freeze(recorder)
	return recorder
end

local TimingRecorder = {
	new = new,
}

table.freeze(TimingRecorder)
return TimingRecorder
