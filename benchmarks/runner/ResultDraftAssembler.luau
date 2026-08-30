--!strict

local EventV1 = require("../contracts/event-v1")
local ResultV1 = require("../contracts/result-v1")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local Identity = require("../contracts/internal/AdapterIdentity")
local Fixtures = require("../fixtures/event-v1")
local BenchmarkClock = require("./BenchmarkClock")
local RunState = require("./RunState")

export type AssembleInput = {
	runId: string,
	manifest: HostManifestV1.HostManifest,
	snapshot: RunState.CaseSnapshot,
}

export type AssembleResult =
	{ kind: "Draft", value: ResultV1.ResultDraft }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

local CONFIG_ERROR = "RESULT_DRAFT_ASSEMBLER_E_CONFIG"
local MAX_SAFE_INTEGER = 9_007_199_254_740_991

local CATEGORY_ORDER = {
	Correctness = 1,
	Capability = 2,
	Contract = 3,
	Lifecycle = 4,
	Measurement = 5,
	Harness = 6,
}

local CODE_ORDER = {
	SubmissionShortfall = 1,
	MissingDelivery = 2,
	DuplicateDelivery = 3,
	UnexpectedDelivery = 4,
	OutOfOrderDelivery = 5,
	PayloadMismatch = 6,
	UnsupportedCapability = 7,
	AddedDeliveryFrameLimitExceeded = 8,
	ControlTrafficDuringMeasuredFrames = 9,
	TimingExclusionViolation = 10,
	IsolationFailure = 11,
	StaleCallback = 12,
	DeliveryObservationLimitExceeded = 13,
	SetupFailure = 14,
	SubmitFailure = 15,
	Timeout = 16,
	Disconnect = 17,
	TeardownFailure = 18,
	RequiredMeasurementUnavailable = 19,
	ClockProofFailure = 20,
	InternalError = 21,
}

local CODE_CATEGORY = {
	SubmissionShortfall = "Correctness",
	MissingDelivery = "Correctness",
	DuplicateDelivery = "Correctness",
	UnexpectedDelivery = "Correctness",
	OutOfOrderDelivery = "Correctness",
	PayloadMismatch = "Correctness",
	ControlTrafficDuringMeasuredFrames = "Contract",
	TimingExclusionViolation = "Contract",
	IsolationFailure = "Contract",
	StaleCallback = "Contract",
	DeliveryObservationLimitExceeded = "Contract",
	SetupFailure = "Lifecycle",
	SubmitFailure = "Lifecycle",
	Timeout = "Lifecycle",
	Disconnect = "Lifecycle",
	TeardownFailure = "Lifecycle",
	RequiredMeasurementUnavailable = "Measurement",
	ClockProofFailure = "Harness",
	InternalError = "Harness",
}

local ONCE_CODES = {
	TimingExclusionViolation = true,
	DeliveryObservationLimitExceeded = true,
	SetupFailure = true,
	RequiredMeasurementUnavailable = true,
	ClockProofFailure = true,
	InternalError = true,
}

local function failConfig(): never
	error(CONFIG_ERROR, 0)
end

local function failProjection(): never
	error("RESULT_DRAFT_ASSEMBLER_E_PROJECTION", 0)
end

local function exactKeys(value: any, expected: { [string]: boolean, }, count: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end

	local found = 0
	local key = next(value)
	while key ~= nil do
		found += 1
		if type(key) ~= "string" or rawget(expected, key) ~= true then
			return false
		end
		key = next(value, key)
	end
	return found == count
end

local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copied = {}
	local key = next(value)
	while key ~= nil do
		copied[deepClone(key)] = deepClone(rawget(value, key))
		key = next(value, key)
	end
	return copied
end

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	local key = next(value)
	while key ~= nil do
		deepFreeze(key)
		deepFreeze(rawget(value, key))
		key = next(value, key)
	end
	table.freeze(value)
end

local function isDeepFrozen(value: any, seen: { [table]: boolean }?): boolean
	if type(value) ~= "table" then
		return true
	elseif not table.isfrozen(value) then
		return false
	end
	seen = seen or {}
	if seen[value] then
		return true
	end
	seen[value] = true
	local key = next(value)
	while key ~= nil do
		if not isDeepFrozen(key, seen) or not isDeepFrozen(rawget(value, key), seen) then
			return false
		end
		key = next(value, key)
	end
	return true
end

local function deepEqual(left: any, right: any): boolean
	if type(left) ~= type(right) then
		return false
	elseif type(left) ~= "table" then
		return left == right
	end

	local count = 0
	local key = next(left)
	while key ~= nil do
		count += 1
		if not deepEqual(rawget(left, key), rawget(right, key)) then
			return false
		end
		key = next(left, key)
	end
	local rightCount = 0
	for _ in next, right do
		rightCount += 1
	end
	return count == rightCount
end

local function safeInteger(value: any): number
	if
		type(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge
		or (value == 0 and 1 / value == -math.huge)
		or value % 1 ~= 0
		or value < 0
		or value > MAX_SAFE_INTEGER
	then
		failProjection()
	end
	return value
end

local function checkedAdd(left: number, right: number): number
	left = safeInteger(left)
	right = safeInteger(right)
	if left > MAX_SAFE_INTEGER - right then
		failProjection()
	end
	return left + right
end

local function checkedMultiply(left: number, right: number): number
	left = safeInteger(left)
	right = safeInteger(right)
	if left ~= 0 and right > MAX_SAFE_INTEGER / left then
		failProjection()
	end
	return left * right
end

local function isUuid(value: any): boolean
	return type(value) == "string"
		and string.match(
			value,
			"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
		) ~= nil
end

local function findCaseDefinition(selection: any): any
	if selection.kind == "Workload" then
		for _, workload in EventV1.workloads do
			if workload.id == selection.workloadId then
				return workload
			end
		end
	else
		for _, probe in EventV1.probes do
			if probe.id == selection.probeId then
				return probe
			end
		end
	end
	failProjection()
end

local function participantFor(selection: any, participant: any): any
	if participant.role == "Server" then
		if selection.kind == "SeparateProbe" then
			return { role = "Coordinator" }
		elseif selection.direction == "ClientToServer" then
			return { role = "Recipient", index = 1 }
		end
		return { role = "Sender", index = 1 }
	end

	local index = safeInteger(participant.index)
	if index < 1 then
		failProjection()
	end
	if selection.kind == "SeparateProbe" then
		return { role = "ProbeClient", index = index }
	elseif selection.direction == "ClientToServer" then
		return { role = "Sender", index = index }
	end
	return { role = "Recipient", index = index }
end

local function participantLess(left: any, right: any): boolean
	local order = { Coordinator = 1, Sender = 2, Recipient = 3, ProbeClient = 4 }
	if order[left.role] ~= order[right.role] then
		return order[left.role] < order[right.role]
	end
	return (left.index or 0) < (right.index or 0)
end

local function firstLess(left: any, right: any): boolean
	return left.repetitionIndex < right.repetitionIndex
		or (left.repetitionIndex == right.repetitionIndex
			and participantLess(left.participant, right.participant))
end

local function mismatchValue(expectedPayload: any, payload: any, fact: any, reason: string): any
	local localFact = fact.mismatch
	if type(localFact) ~= "table" then
		failProjection()
	end

	if localFact.pathKind == "Root" then
		if reason == "WrongContainerType" then
			return {
				path = "$",
				reason = reason,
				expectedPresent = true,
				actualPresent = true,
			}
		elseif reason == "ArityMismatch" then
			return {
				path = "$",
				reason = reason,
				expectedPresent = true,
				actualPresent = true,
				expected = #payload.fields,
				actual = safeInteger(localFact.actual),
			}
		elseif reason == "ExtraField" then
			return {
				path = "$",
				reason = reason,
				expectedPresent = false,
				actualPresent = true,
			}
		end
		failProjection()
	end

	local fieldIndex = safeInteger(localFact.fieldIndex)
	local field = rawget(payload.fields, fieldIndex)
	if fieldIndex < 1 or field == nil then
		failProjection()
	end

	local component = nil
	local expected = rawget(expectedPayload, field.name)
	local path = field.name
	if localFact.pathKind == "VectorComponent" then
		component = localFact.component
		if field.valueType ~= "Vector3F32"
			or (component ~= "X" and component ~= "Y" and component ~= "Z")
		then
			failProjection()
		end
		expected = expected[component]
		path ..= "." .. component
	elseif localFact.pathKind ~= "Field" then
		failProjection()
	end

	local output: any = {
		path = path,
		reason = reason,
		expectedPresent = true,
		actualPresent = reason ~= "MissingField",
	}
	local includeExpected = component ~= nil or field.valueType ~= "Vector3F32"
	if includeExpected then
		output.expected = expected
	end
	if rawget(localFact, "actual") ~= nil then
		output.actual = localFact.actual
	end
	return output
end

local function reconstructMismatch(selection: any, fact: any): any
	local repetitionIndex = safeInteger(fact.firstRepetition)
	local fixtureIndex = safeInteger(fact.fixtureIndex)
	if repetitionIndex < 1 or fixtureIndex < 1 then
		failProjection()
	end

	local fixture
	if selection.kind == "Workload" then
		fixture = Fixtures.generate(selection.workloadId, repetitionIndex)
	else
		fixture = Fixtures.generateProbe(selection.probeId, repetitionIndex)
	end
	local submission = rawget(fixture.measured, fixtureIndex)
	if submission == nil then
		failProjection()
	end
	local payload = rawget(EventV1.payloads, selection.payloadId)
	local reason = fact.discriminator.value
	return mismatchValue(submission.expected, payload, fact, reason)
end

type FailureGroup = {
	value: any,
	firstFact: any?,
}

local function failureKey(code: string, fact: any): string
	if code == "PayloadMismatch" then
		return code .. "\0" .. fact.discriminator.value
	elseif code == "TimingExclusionViolation" then
		return code .. "\0" .. fact.discriminator.value
	elseif code == "InternalError" then
		return code .. "\0" .. fact.discriminator.value
	elseif code == "RequiredMeasurementUnavailable" then
		return code .. "\0" .. fact.discriminator.value
	end
	return code
end

local function factFirstOccurrence(selection: any, participant: any, fact: any): any?
	if rawget(fact, "firstRepetition") == nil then
		return nil
	end
	local occurrence: any = {
		repetitionIndex = safeInteger(fact.firstRepetition),
		participant = participantFor(selection, participant),
	}
	if fact.code == "PayloadMismatch" then
		occurrence.mismatch = reconstructMismatch(selection, fact)
	end
	return occurrence
end

local function addFact(
	groups: { [string]: FailureGroup },
	selection: any,
	participant: any,
	fact: any
)
	local code = fact.code
	local category = CODE_CATEGORY[code]
	if category == nil then
		failProjection()
	end
	local occurrences = safeInteger(fact.occurrences)
	if occurrences < 1 then
		failProjection()
	end
	if ONCE_CODES[code] and occurrences ~= 1 then
		failProjection()
	end
	local key = failureKey(code, fact)
	local first = factFirstOccurrence(selection, participant, fact)
	local group = groups[key]
	if group == nil then
		local value: any = {
			category = category,
			code = code,
			occurrences = occurrences,
		}
		if code == "PayloadMismatch" then
			value.discriminator = { mismatchReason = fact.discriminator.value }
		elseif code == "TimingExclusionViolation" then
			value.discriminator = { exclusion = fact.discriminator.value }
		elseif code == "InternalError" then
			value.discriminator = { stage = fact.discriminator.value }
		elseif code == "RequiredMeasurementUnavailable" then
			value.discriminator = { measurementId = fact.discriminator.value }
		end
		if first ~= nil then
			value.firstOccurrence = first
		end
		groups[key] = { value = value, firstFact = first }
		return
	end

	if not ONCE_CODES[code] then
		group.value.occurrences = checkedAdd(group.value.occurrences, occurrences)
	end
	if first ~= nil and (group.firstFact == nil or firstLess(first, group.firstFact)) then
		group.firstFact = first
		group.value.firstOccurrence = first
	end
end

local function addGeneratedFailure(groups: { [string]: FailureGroup }, code: string, occurrences: number, discriminator: any?)
	if occurrences == 0 then
		return
	end
	local fact: any = { code = code, occurrences = occurrences }
	if discriminator ~= nil then
		fact.discriminator = discriminator
	end
	addFact(groups, {} :: any, { role = "Server" }, fact)
end

local function failureSortKey(failure: any): string
	local discriminator = failure.discriminator
	local scalar = ""
	if discriminator ~= nil then
		scalar = discriminator.mismatchReason
			or discriminator.exclusion
			or discriminator.measurementId
			or discriminator.stage
			or ""
	end
	return string.format("%02d\0%02d\0%s", CATEGORY_ORDER[failure.category], CODE_ORDER[failure.code], scalar)
end

local function frozenFailures(groups: { [string]: FailureGroup }): { any }
	local failures = {}
	for _, group in next, groups do
		table.insert(failures, group.value)
	end
	table.sort(failures, function(left, right)
		return failureSortKey(left) < failureSortKey(right)
	end)
	if #failures > 38 then
		failProjection()
	end
	return failures
end

local function statusFromFailures(groups: { [string]: FailureGroup }): string
	local hasHarness = false
	local hasInvalid = false
	for _, group in next, groups do
		local category = group.value.category
		if category == "Harness" then
			hasHarness = true
		elseif category == "Correctness" or category == "Contract" or category == "Lifecycle" or category == "Measurement" then
			hasInvalid = true
		elseif category == "Capability" then
			failProjection()
		end
	end
	return if hasHarness then "Error" elseif hasInvalid then "Invalid" else "Valid"
end

local function validateFailureReconciliation(
	groups: { [string]: FailureGroup },
	counts: any?,
	snapshot: any,
	definition: any
)
	local sums: { [string]: number } = {}
	local categories: { [string]: boolean } = {}
	for _, group in next, groups do
		local code = group.value.code
		sums[code] = checkedAdd(sums[code] or 0, group.value.occurrences)
		categories[group.value.category] = true
	end
	if categories.Harness and categories.Measurement then
		failProjection()
	end
	if counts == nil then
		local maximumSamples = checkedMultiply(snapshot.coordinator.scheduledRepetitions, definition.measuredSamples)
		local maximumOperations = checkedMultiply(2, maximumSamples)
		local observationLimit = checkedMultiply(4, maximumOperations)
		if (sums.PayloadMismatch or 0) > maximumSamples
			or (sums.SubmitFailure or 0) > maximumOperations
			or (sums.ControlTrafficDuringMeasuredFrames or 0) > observationLimit
			or (sums.StaleCallback or 0) > observationLimit
			or ((sums.DeliveryObservationLimitExceeded or 0) > 0
				and snapshot.coordinator.completedRepetitions >= snapshot.coordinator.scheduledRepetitions)
		then
			failProjection()
		end
	else
		local observationLimit = checkedMultiply(4, counts.expectedDeliveries)
		if (sums.SubmitFailure or 0) > counts.expectedSubmissions
			or (sums.ControlTrafficDuringMeasuredFrames or 0) > observationLimit
			or (sums.StaleCallback or 0) > observationLimit
			or ((sums.DeliveryObservationLimitExceeded or 0) > 0
				and (counts.finality ~= "Partial" or counts.received ~= observationLimit))
		then
			failProjection()
		end
	end
	for _, code in { "IsolationFailure", "Timeout", "Disconnect", "TeardownFailure" } do
		if (sums[code] or 0) > snapshot.coordinator.scheduledRepetitions then
			failProjection()
		end
	end
	if snapshot.coordinator.startedRepetitions == 0
		and statusFromFailures(groups) == "Invalid"
		and (sums.SetupFailure or 0) ~= 1
	then
		failProjection()
	end
	if counts == nil then
		return
	end
	for code, key in {
		DuplicateDelivery = "duplicate",
		UnexpectedDelivery = "unexpected",
		OutOfOrderDelivery = "outOfOrder",
		PayloadMismatch = "mismatch",
	} do
		if (sums[code] or 0) ~= counts[key] then
			failProjection()
		end
	end
	if counts.finality == "Final" then
		if (sums.MissingDelivery or 0) ~= counts.missing
			or (sums.SubmissionShortfall or 0) ~= counts.expectedSubmissions - counts.submitted
		then
			failProjection()
		end
	elseif (sums.MissingDelivery or 0) ~= 0 or (sums.SubmissionShortfall or 0) ~= 0 then
		failProjection()
	end
end

local function emptyRepetitionCounts(): any
	return {
		submitted = 0,
		received = 0,
		correct = 0,
		mismatch = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
	}
end

local function aggregateCounts(snapshot: any, definition: any): (any?, { any })
	local scheduled = safeInteger(snapshot.coordinator.scheduledRepetitions)
	local started = safeInteger(snapshot.coordinator.startedRepetitions)
	local completed = safeInteger(snapshot.coordinator.completedRepetitions)
	if scheduled < 1 or completed > started or started > scheduled then
		failProjection()
	end
	local perRepetition = table.create(scheduled)
	for repetitionIndex = 1, scheduled do
		perRepetition[repetitionIndex] = emptyRepetitionCounts()
	end

	for _, participantSnapshot in snapshot.participants do
		for _, repetition in participantSnapshot.evidence.repetitions do
			local repetitionIndex = safeInteger(repetition.repetitionIndex)
			local aggregate = rawget(perRepetition, repetitionIndex)
			if aggregate == nil then
				failProjection()
			end
			for _, key in { "submitted", "received", "correct", "mismatch", "duplicate", "unexpected", "outOfOrder" } do
				aggregate[key] = checkedAdd(aggregate[key], safeInteger(repetition[key]))
			end
		end
	end

	if snapshot.selection.kind ~= "Workload" then
		return nil, perRepetition
	end

	local totals = emptyRepetitionCounts()
	for _, repetition in perRepetition do
		for key, value in next, repetition do
			totals[key] = checkedAdd(totals[key], value)
		end
	end
	local perRepetitionSubmissions = checkedMultiply(
		checkedMultiply(snapshot.selection.kind == "Workload" and definition.senderCount or 0, definition.measuredFrames),
		definition.messagesPerFrame
	)
	local expectedSubmissions = checkedMultiply(scheduled, perRepetitionSubmissions)
	local expectedDeliveries = checkedMultiply(expectedSubmissions, snapshot.selection.recipientCount)
	local finality = if started == 0 then "NotStarted" elseif completed == scheduled then "Final" else "Partial"
	local missing = 0
	if finality == "Final" then
		local accounted = checkedAdd(totals.correct, totals.mismatch)
		if accounted > expectedDeliveries then
			failProjection()
		end
		missing = expectedDeliveries - accounted
	end
	return {
		finality = finality,
		expectedSubmissions = expectedSubmissions,
		submitted = totals.submitted,
		expectedDeliveries = expectedDeliveries,
		received = totals.received,
		correct = totals.correct,
		missing = missing,
		duplicate = totals.duplicate,
		unexpected = totals.unexpected,
		outOfOrder = totals.outOfOrder,
		mismatch = totals.mismatch,
	}, perRepetition
end

local function validateCounts(snapshot: any, definition: any, counts: any?)
	if counts == nil then
		return
	end
	local expectedPerStarted = checkedMultiply(
		checkedMultiply(definition.senderCount, definition.measuredFrames),
		definition.messagesPerFrame
	)
	if counts.submitted > checkedMultiply(snapshot.coordinator.startedRepetitions, expectedPerStarted) then
		failProjection()
	end
	if counts.received ~= checkedAdd(
		checkedAdd(counts.correct, counts.mismatch),
		checkedAdd(counts.duplicate, counts.unexpected)
	) then
		failProjection()
	end
	local verified = checkedAdd(counts.correct, counts.mismatch)
	if verified > checkedMultiply(counts.submitted, snapshot.selection.recipientCount)
		or counts.outOfOrder > verified
		or (counts.duplicate > 0 and verified == 0)
		or counts.received > checkedMultiply(4, counts.expectedDeliveries)
	then
		failProjection()
	end
	if counts.finality == "NotStarted" then
		for _, key in { "submitted", "received", "correct", "missing", "duplicate", "unexpected", "outOfOrder", "mismatch" } do
			if counts[key] ~= 0 then
				failProjection()
			end
		end
	elseif counts.finality == "Partial" then
		if snapshot.coordinator.finalOnlyEvidence or counts.missing ~= 0 then
			failProjection()
		end
	elseif checkedAdd(verified, counts.missing) ~= counts.expectedDeliveries then
		failProjection()
	end
end

local function copyCase(snapshot: any, definition: any): any
	local coordinator = snapshot.coordinator
	if snapshot.selection.kind == "Workload" then
		return {
			kind = "Workload",
			workloadId = snapshot.selection.workloadId,
			senderCount = definition.senderCount,
			recipientCount = snapshot.selection.recipientCount,
			scheduledRepetitions = safeInteger(coordinator.scheduledRepetitions),
			startedRepetitions = safeInteger(coordinator.startedRepetitions),
			completedRepetitions = safeInteger(coordinator.completedRepetitions),
		}
	end
	return {
		kind = "SeparateProbe",
		probeId = snapshot.selection.probeId,
		clientCount = snapshot.selection.clientCount,
		scheduledRepetitions = safeInteger(coordinator.scheduledRepetitions),
		startedRepetitions = safeInteger(coordinator.startedRepetitions),
		completedRepetitions = safeInteger(coordinator.completedRepetitions),
	}
end

local function selectedMeasurementIndices(selection: any): { [number]: boolean }
	local selected = {}
	for index, measurement in EventV1.measurements do
		if measurement.scope == selection.kind
			and (measurement.probeId == nil or measurement.probeId == selection.probeId)
		then
			selected[index] = true
		end
	end
	return selected
end

local function measurementParticipantIndex(selection: any, participant: any, measurement: any): number?
	local logical = participantFor(selection, participant)
	if measurement.capture.role == "Sender" then
		if logical.role ~= "Sender" then
			failProjection()
		end
		return logical.index
	elseif measurement.capture.role == "ProbeClient" then
		if logical.role ~= "ProbeClient" then
			failProjection()
		end
		return logical.index
	end
	if measurement.capture.role ~= "Coordinator" and measurement.capture.role ~= "CrossParticipant" then
		failProjection()
	end
	return nil
end

local function copyValues(values: any): { number }
	if type(values) ~= "table" then
		failProjection()
	end
	local count = 0
	for key in next, values do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			failProjection()
		end
		count += 1
	end
	local copied = table.create(count)
	for index = 1, count do
		local value = rawget(values, index)
		if type(value) ~= "number"
			or value ~= value
			or value == math.huge
			or value == -math.huge
			or value < 0
			or (value == 0 and 1 / value == -math.huge)
		then
			failProjection()
		end
		copied[index] = value
	end
	return copied
end

local function collectRecordedMeasurements(snapshot: any): { [number]: { any } }
	local selected = selectedMeasurementIndices(snapshot.selection)
	local groups: { [number]: { any } } = {}
	for _, participantSnapshot in snapshot.participants do
		for _, record in participantSnapshot.evidence.measurements do
			local measurementIndex = safeInteger(record.measurementIndex)
			local measurement = rawget(EventV1.measurements, measurementIndex)
			if measurement == nil or selected[measurementIndex] ~= true or measurementIndex == 1 or measurementIndex == 2 or measurementIndex == 3 then
				failProjection()
			end
			local output: any = {
				repetitionIndex = safeInteger(record.repetitionIndex),
				values = copyValues(record.values),
			}
			local participantIndex = measurementParticipantIndex(
				snapshot.selection,
				participantSnapshot.participant,
				measurement
			)
			if participantIndex ~= nil then
				output.participantIndex = participantIndex
			end
			groups[measurementIndex] = groups[measurementIndex] or {}
			table.insert(groups[measurementIndex], output)
		end
	end
	return groups
end

local function collectTimingEndpoints(snapshot: any): { [number]: any }
	local endpoints = {}
	for repetitionIndex = 1, snapshot.coordinator.scheduledRepetitions do
		endpoints[repetitionIndex] = {}
	end

	local function add(participant: any, record: any)
		local repetitionIndex = safeInteger(record.repetitionIndex)
		local target = rawget(endpoints, repetitionIndex)
		if target == nil then
			failProjection()
		end
		local logical = participantFor(snapshot.selection, participant)
		if logical.role == "Sender" then
			if rawget(record, "firstSubmissionStartedSharedSeconds") ~= nil then
				if target.senderStart ~= nil then failProjection() end
				target.senderStart = record.firstSubmissionStartedSharedSeconds
			end
			if rawget(record, "finalSubmissionReturnedSharedSeconds") ~= nil then
				if target.senderFinish ~= nil then failProjection() end
				target.senderFinish = record.finalSubmissionReturnedSharedSeconds
			end
		elseif logical.role == "Recipient" then
			local received = rawget(record, "finalExpectedDeliveryReceivedSharedSeconds")
			local verified = rawget(record, "finalExpectedDeliveryVerifiedSharedSeconds")
			if received ~= nil then
				target.receiverCount = (target.receiverCount or 0) + 1
				target.received = if target.received == nil then received else math.max(target.received, received)
			end
			if verified ~= nil then
				target.verified = if target.verified == nil then verified else math.max(target.verified, verified)
			end
		end
	end

	for _, participantSnapshot in snapshot.participants do
		local evidence = participantSnapshot.evidence
		if participantSnapshot.participant.role == "Server" then
			for _, record in evidence.timingEndpoints do
				add(participantSnapshot.participant, record)
			end
		else
			for _, record in evidence.repetitions do
				add(participantSnapshot.participant, record)
			end
		end
	end
	return endpoints
end

local function valuesPerGroup(measurement: any, definition: any): number
	if measurement.capture.cadence == "PerMeasuredFrame" then
		return definition.measuredFrames
	elseif measurement.capture.cadence == "PerRepetition" then
		return 1
	elseif measurement.capture.cadence == "PerSubmission" then
		return checkedMultiply(definition.measuredFrames, definition.messagesPerFrame)
	elseif measurement.capture.cadence == "PerProbe" then
		return definition.measuredSamples
	end
	failProjection()
end

local function participantCount(measurement: any, definition: any): number
	if measurement.capture.role == "Sender" then
		return definition.senderCount
	elseif measurement.capture.role == "ProbeClient" then
		return definition.clientCount
	end
	return 1
end

local function groupsAreIndividuallyComplete(
	groups: { any }?,
	measurement: any,
	definition: any,
	scheduled: number
): boolean
	if groups == nil then
		return false
	end
	local participants = participantCount(measurement, definition)
	local seen: { [string]: boolean } = {}
	for _, group in groups do
		if group.repetitionIndex < 1
			or group.repetitionIndex > scheduled
			or #group.values ~= valuesPerGroup(measurement, definition)
		then
			return false
		end
		local participantIndex = group.participantIndex
		if measurement.capture.role == "Sender" or measurement.capture.role == "ProbeClient" then
			if participantIndex == nil or participantIndex < 1 or participantIndex > participants then
				return false
			end
		elseif participantIndex ~= nil then
			return false
		end
		local key = tostring(group.repetitionIndex) .. "\0" .. tostring(participantIndex or 0)
		if seen[key] then
			return false
		end
		seen[key] = true
	end
	return true
end

local function groupsAreComplete(groups: { any }?, measurement: any, definition: any, scheduled: number): boolean
	if not groupsAreIndividuallyComplete(groups, measurement, definition, scheduled) then
		return false
	end
	local completeGroups = groups :: { any }
	local participants = participantCount(measurement, definition)
	local expectedCount = scheduled * participants
	local count = 0
	for key in next, completeGroups do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > expectedCount then
			return false
		end
		count += 1
	end
	if count ~= expectedCount then
		return false
	end
	for index = 1, expectedCount do
		if rawget(groups, index) == nil then
			return false
		end
	end
	table.sort(completeGroups, function(left, right)
		if left.repetitionIndex ~= right.repetitionIndex then
			return left.repetitionIndex < right.repetitionIndex
		end
		return (left.participantIndex or 0) < (right.participantIndex or 0)
	end)
	for index, group in completeGroups do
		local expectedRepetition = math.floor((index - 1) / participants) + 1
		local expectedParticipant = (index - 1) % participants + 1
		if group.repetitionIndex ~= expectedRepetition or #group.values ~= valuesPerGroup(measurement, definition) then
			return false
		end
		if measurement.capture.role == "Sender" or measurement.capture.role == "ProbeClient" then
			if group.participantIndex ~= expectedParticipant then
				return false
			end
		elseif group.participantIndex ~= nil then
			return false
		end
	end
	return true
end

local function buildCompleteGroups(snapshot: any, definition: any, perRepetition: { any }): { [number]: { any } }
	local groups = collectRecordedMeasurements(snapshot)
	if snapshot.selection.kind == "Workload" then
		for measurementIndex, countKey in { [1] = "submitted", [2] = "received", [3] = "correct" } do
			local records = table.create(snapshot.coordinator.scheduledRepetitions)
			for repetitionIndex = 1, snapshot.coordinator.scheduledRepetitions do
				records[repetitionIndex] = {
					repetitionIndex = repetitionIndex,
					values = { perRepetition[repetitionIndex][countKey] },
				}
			end
			groups[measurementIndex] = records
		end

		local endpoints = collectTimingEndpoints(snapshot)
		local cross = { [6] = {}, [7] = {}, [8] = {} }
		for repetitionIndex = 1, snapshot.coordinator.scheduledRepetitions do
			local endpoint = endpoints[repetitionIndex]
			if endpoint.senderStart ~= nil
				and endpoint.senderFinish ~= nil
				and endpoint.received ~= nil
				and endpoint.verified ~= nil
				and endpoint.receiverCount == snapshot.selection.recipientCount
			then
				table.insert(cross[6], {
					repetitionIndex = repetitionIndex,
					values = { BenchmarkClock.millisecondsBetween(endpoint.senderStart, endpoint.received) },
				})
				table.insert(cross[7], {
					repetitionIndex = repetitionIndex,
					values = { BenchmarkClock.millisecondsBetween(endpoint.senderFinish, endpoint.received) },
				})
				table.insert(cross[8], {
					repetitionIndex = repetitionIndex,
					values = {
						BenchmarkClock.millisecondsBetween(
							endpoint.senderStart,
							math.max(endpoint.senderFinish, endpoint.verified)
						),
					},
				})
			end
		end
		groups[6] = cross[6]
		groups[7] = cross[7]
		groups[8] = cross[8]
	end
	return groups
end

local function optionalReason(measurementIndex: number): string
	if measurementIndex == 11 or measurementIndex == 14 then
		return "UnavailableInEnvironment"
	elseif measurementIndex == 12 or measurementIndex == 13 then
		return "NotSupportedByAdapter"
	end
	failProjection()
end

local function buildMeasurements(
	snapshot: any,
	definition: any,
	status: string,
	perRepetition: { any },
	groups: { [string]: FailureGroup }
): { any }
	local complete = snapshot.coordinator.completedRepetitions == snapshot.coordinator.scheduledRepetitions
	local completeGroups = if complete and status ~= "Error"
		then buildCompleteGroups(snapshot, definition, perRepetition)
		else {}
	local measurements = {}
	for measurementIndex, measurement in EventV1.measurements do
		if measurement.scope ~= snapshot.selection.kind
			or (measurement.probeId ~= nil and measurement.probeId ~= snapshot.selection.probeId)
		then
			continue
		end

		local output: any
		if status == "Error" then
			output = {
				id = measurement.id,
				state = "Unavailable",
				unavailableReason = { code = if complete then "ResultUntrusted" else "CaseNotCompleted" },
			}
		elseif not complete then
			output = {
				id = measurement.id,
				state = "Unavailable",
				unavailableReason = { code = "CaseNotCompleted" },
			}
		else
			local rawSamples = completeGroups[measurementIndex]
			if groupsAreComplete(rawSamples, measurement, definition, snapshot.coordinator.scheduledRepetitions) then
				output = {
					id = measurement.id,
					state = if status == "Invalid" and measurement.summary == "MedianAndP95" then "Diagnostic" else "Available",
					rawSamples = rawSamples,
				}
			elseif measurement.availability == "Optional" then
				if rawSamples ~= nil
					and not groupsAreIndividuallyComplete(rawSamples, measurement, definition, snapshot.coordinator.scheduledRepetitions)
				then
					failProjection()
				end
				output = {
					id = measurement.id,
					state = "Unavailable",
					unavailableReason = { code = if rawSamples == nil then optionalReason(measurementIndex) else "CaptureFailed" },
				}
			elseif status == "Invalid" then
				output = {
					id = measurement.id,
					state = "Unavailable",
					unavailableReason = { code = "CaptureFailed" },
				}
			else
				failProjection()
			end
		end

		if status == "Invalid" and measurement.availability == "Required" and output.state == "Unavailable" then
			addGeneratedFailure(groups, "RequiredMeasurementUnavailable", 1, {
				kind = "MeasurementId",
				value = measurement.id,
			})
		end
		table.insert(measurements, output)
	end
	return measurements
end

local function copyEnvironment(manifest: any, selection: any): any
	return {
		studio = deepClone(manifest.environment.studio),
		host = deepClone(manifest.environment.host),
		execution = {
			mode = EventV1.execution.mode,
			targetFrameRate = EventV1.execution.targetFrameRate,
			serverCount = 1,
			clientCount = selection.clientProcessCount,
		},
	}
end

local function buildConformance(snapshot: any, groups: { [string]: FailureGroup }): any
	local exclusions = {
		setup = true,
		warmup = true,
		quiescence = true,
		resultExtraction = true,
	}
	local clockPassed = true
	for _, participantSnapshot in snapshot.participants do
		local conformance = participantSnapshot.evidence.conformance
		exclusions.setup = exclusions.setup and conformance.setupExcluded
		exclusions.warmup = exclusions.warmup and conformance.warmupExcluded
		exclusions.quiescence = exclusions.quiescence and conformance.quiescenceExcluded
		exclusions.resultExtraction = exclusions.resultExtraction and conformance.resultExtractionExcluded
		clockPassed = clockPassed and conformance.clockProofPassed
	end

	if not exclusions.resultExtraction then
		local key = "TimingExclusionViolation\0resultExtraction"
		groups[key] = {
			value = {
				category = "Contract",
				code = "TimingExclusionViolation",
				occurrences = 1,
				discriminator = { exclusion = "resultExtraction" },
			},
		}
	end
	for exclusion, confirmed in next, exclusions do
		local hasFailure = groups["TimingExclusionViolation\0" .. exclusion] ~= nil
		if hasFailure == confirmed then
			failProjection()
		end
	end
	if (groups.ClockProofFailure ~= nil) == clockPassed then
		failProjection()
	end
	return {
		timingExclusionsConfirmed = exclusions,
		localClock = deepClone(EventV1.clocks.localDuration),
		sharedClock = deepClone(EventV1.clocks.shared),
		clockProof = { version = 1, passed = clockPassed },
	}
end

local function projection(input: AssembleInput): ResultV1.ResultDraft
	if not isUuid(input.runId) then
		failProjection()
	end
	local manifestResult = HostManifestV1.validate(input.manifest)
	if manifestResult.kind ~= "Valid" then
		failProjection()
	end
	local manifest = manifestResult.value
	local snapshot = input.snapshot
	if not exactKeys(snapshot, {
		version = true,
		selection = true,
		coordinator = true,
		participants = true,
	}, 4) or snapshot.version ~= 1 then
		failProjection()
	end
	local resolved = Identity.resolveSelection(manifest.selection)
	if resolved.kind ~= "Valid" or not deepEqual(resolved.value, snapshot.selection) then
		failProjection()
	end
	if manifest.adapter.identity.semantics.repetitionIsolation ~= "SessionRestart" then
		failProjection()
	end

	local definition = findCaseDefinition(snapshot.selection)
	if snapshot.coordinator.scheduledRepetitions ~= definition.repetitions then
		failProjection()
	end
	if not exactKeys(snapshot.coordinator, {
		scheduledRepetitions = true,
		startedRepetitions = true,
		completedRepetitions = true,
		finalOnlyEvidence = true,
		failureFacts = true,
	}, 5)
		or type(snapshot.coordinator.finalOnlyEvidence) ~= "boolean"
		or type(snapshot.coordinator.failureFacts) ~= "table"
		or type(snapshot.participants) ~= "table"
		or #snapshot.participants ~= snapshot.selection.clientProcessCount + 1
	then
		failProjection()
	end
	for position, participantSnapshot in snapshot.participants do
		if not exactKeys(participantSnapshot, { participant = true, evidence = true }, 2)
			or type(participantSnapshot.participant) ~= "table"
			or type(participantSnapshot.evidence) ~= "table"
		then
			failProjection()
		end
		if position == 1 then
			if not exactKeys(participantSnapshot.participant, { role = true }, 1)
				or participantSnapshot.participant.role ~= "Server"
			then
				failProjection()
			end
		else
			local expectedRole = if snapshot.selection.kind == "SeparateProbe" then "ProbeClient" else "Client"
			if not exactKeys(participantSnapshot.participant, { role = true, index = true }, 2)
				or participantSnapshot.participant.role ~= expectedRole
				or participantSnapshot.participant.index ~= position - 1
			then
				failProjection()
			end
		end
	end

	local groups: { [string]: FailureGroup } = {}
	for _, fact in snapshot.coordinator.failureFacts do
		addFact(groups, snapshot.selection, { role = "Server" }, fact)
		local group = groups[failureKey(fact.code, fact)]
		if rawget(fact, "firstRepetition") ~= nil then
			local first: any = {
				repetitionIndex = safeInteger(fact.firstRepetition),
				participant = { role = "Coordinator" },
			}
			group.firstFact = first
			group.value.firstOccurrence = first
		end
	end
	local repetitionFailureParticipants = {
		IsolationFailure = 0,
		SubmitFailure = 0,
		TeardownFailure = 0,
	}
	for _, participantSnapshot in snapshot.participants do
		local participantRepetitionFailures: { [string]: boolean } = {}
		for _, fact in participantSnapshot.evidence.failureFacts do
			addFact(groups, snapshot.selection, participantSnapshot.participant, fact)
			if repetitionFailureParticipants[fact.code] ~= nil then
				participantRepetitionFailures[fact.code] = true
			end
		end
		for code in participantRepetitionFailures do
			repetitionFailureParticipants[code] += 1
		end
	end
	for _, participantCount in repetitionFailureParticipants do
		if participantCount > 1 then failProjection() end
	end

	local counts, perRepetition = aggregateCounts(snapshot, definition)
	validateCounts(snapshot, definition, counts)
	if counts ~= nil and counts.finality == "Final" then
		addGeneratedFailure(groups, "SubmissionShortfall", counts.expectedSubmissions - counts.submitted)
		addGeneratedFailure(groups, "MissingDelivery", counts.missing)
	end
	local preliminaryStatus = statusFromFailures(groups)
	local conformance = buildConformance(snapshot, groups)
	preliminaryStatus = statusFromFailures(groups)
	if preliminaryStatus == "Valid"
		and snapshot.coordinator.completedRepetitions ~= snapshot.coordinator.scheduledRepetitions
	then
		failProjection()
	end
	local measurements = buildMeasurements(snapshot, definition, preliminaryStatus, perRepetition, groups)
	validateFailureReconciliation(groups, counts, snapshot, definition)

	local caseValue = copyCase(snapshot, definition)
	local draft: any = {
		runId = input.runId,
		benchmarkSource = deepClone(manifest.benchmarkSource),
		contractFingerprint = manifest.contractFingerprint,
		adapter = deepClone(manifest.adapter.identity),
		case = caseValue,
		failures = frozenFailures(groups),
		conformance = conformance,
		measurements = measurements,
		environment = copyEnvironment(manifest, snapshot.selection),
	}
	if counts ~= nil then
		draft.counts = counts
	end
	deepFreeze(draft)
	return draft
end

local function assemble(input: AssembleInput): AssembleResult
	if not exactKeys(input, { runId = true, manifest = true, snapshot = true }, 3)
		or not isDeepFrozen(input)
		or type(rawget(input, "runId")) ~= "string"
		or type(rawget(input, "manifest")) ~= "table"
		or type(rawget(input, "snapshot")) ~= "table"
	then
		failConfig()
	end

	local ok, output = pcall(projection, input)
	if not ok then
		local terminated: AssembleResult = {
			kind = "Terminated",
			termination = HarnessTerminationV1.new("FinalizationFailure", "Finalize"),
		}
		deepFreeze(terminated)
		return terminated
	end
	local result: AssembleResult = { kind = "Draft", value = output }
	deepFreeze(result)
	return result
end

local ResultDraftAssembler = {
	assemble = assemble,
}

table.freeze(ResultDraftAssembler)

return ResultDraftAssembler
