--!strict

local AdapterContract = require("../adapters/AdapterContract")
local EventV1 = require("../contracts/event-v1")
local AdapterIdentity = require("../contracts/internal/AdapterIdentity")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local DeliveryLedger = require("../correctness/DeliveryLedger")
local PayloadComparator = require("../correctness/PayloadComparator")
local Fixtures = require("../fixtures/event-v1")
local BenchmarkClock = require("./BenchmarkClock")
local DeliveryRouter = require("./DeliveryRouter")
local SessionOwner = require("./SessionOwner")
local TimingRecorder = require("./TimingRecorder")

export type ComparatorReason = PayloadComparator.MismatchReason

-- `actual` is present on the root arm only for ArityMismatch. The security
-- review owns that more precise rule; the abbreviated R1 type omitted it.
export type LocalMismatchFactV1 =
	{ pathKind: "Root", actual: number? }
	| { pathKind: "Field", fieldIndex: number, actual: (boolean | number)? }
	| {
		pathKind: "VectorComponent",
		fieldIndex: number,
		component: "X" | "Y" | "Z",
		actual: number?,
	}

export type SanitizedFailureFactV1 =
	{ code: "DuplicateDelivery" | "UnexpectedDelivery" | "OutOfOrderDelivery", occurrences: number, firstRepetition: number }
	| {
		code: "PayloadMismatch",
		occurrences: number,
		discriminator: { kind: "MismatchReason", value: ComparatorReason },
		firstRepetition: number,
		fixtureIndex: number,
		mismatch: LocalMismatchFactV1,
	}
	| { code: "ControlTrafficDuringMeasuredFrames", occurrences: number, firstRepetition: number }
	| {
		code: "TimingExclusionViolation",
		occurrences: number,
		discriminator: { kind: "TimingExclusion", value: "setup" | "warmup" | "quiescence" },
	}
	| { code: "IsolationFailure" | "StaleCallback", occurrences: number, firstRepetition: number }
	| { code: "DeliveryObservationLimitExceeded", occurrences: number, firstRepetition: number }
	| { code: "InputMutation", occurrences: number }
	| { code: "SetupFailure", occurrences: number }
	| { code: "SubmitFailure", occurrences: number, firstRepetition: number }
	| { code: "TeardownFailure", occurrences: number, firstRepetition: number? }
	| {
		code: "InternalError",
		occurrences: number,
		discriminator: { kind: "Stage", value: "Setup" | "Execution" | "Finalize" },
	}

export type CoordinatorFailureFactV1 =
	{ code: "SetupFailure", occurrences: number }
	| { code: "Timeout" | "Disconnect", occurrences: number, firstRepetition: number }
	| { code: "ClockProofFailure", occurrences: number }
	| {
		code: "InternalError",
		occurrences: number,
		discriminator: { kind: "Stage", value: "Setup" | "Execution" | "Finalize" },
	}

export type ParticipantRepetitionEvidenceV1 = {
	repetitionIndex: number,
	started: boolean,
	completed: boolean,
	submitted: number,
	received: number,
	correct: number,
	mismatch: number,
	duplicate: number,
	unexpected: number,
	outOfOrder: number,
	staleCallbacks: number,
	observationOverflow: boolean,
	probeStarted: number,
	probeSubmitted: number,
	probeReceived: number,
	probeCorrect: number,
	probeMismatch: number,
	firstSubmissionStartedSharedSeconds: number?,
	finalSubmissionReturnedSharedSeconds: number?,
	finalExpectedDeliveryReceivedSharedSeconds: number?,
	finalExpectedDeliveryVerifiedSharedSeconds: number?,
}

export type ParticipantConformanceV1 = {
	setupExcluded: boolean,
	warmupExcluded: boolean,
	quiescenceExcluded: boolean,
	resultExtractionExcluded: boolean,
	clockProofPassed: boolean,
}

export type ParticipantEvidenceV1 = {
	version: number,
	repetitions: { ParticipantRepetitionEvidenceV1 },
	measurements: { TimingRecorder.ParticipantMeasurementV1 },
	failureFacts: { SanitizedFailureFactV1 },
	conformance: ParticipantConformanceV1,
}

export type ServerRepetitionEvidenceV1 = {
	repetitionIndex: number,
	started: boolean,
	completed: boolean,
	submitted: number,
	received: number,
	correct: number,
	mismatch: number,
	duplicate: number,
	unexpected: number,
	outOfOrder: number,
	staleCallbacks: number,
	observationOverflow: boolean,
	probeRequestsReceived: number,
	probeRequestsCorrect: number,
	probeRequestsMismatch: number,
	probeResponsesSubmitted: number,
}

export type ServerEvidenceV1 = {
	version: number,
	repetitions: { ServerRepetitionEvidenceV1 },
	measurements: { TimingRecorder.ParticipantMeasurementV1 },
	timingEndpoints: { TimingRecorder.ParticipantTimingEndpointsV1 },
	failureFacts: { SanitizedFailureFactV1 },
	conformance: ParticipantConformanceV1,
}

export type DeliveryAction =
	{ kind: "None" }
	| { kind: "ProbeResponse", fixtureIndex: number }
	| { kind: "ProbeResponseAccepted", fixtureIndex: number }
	| { kind: "ClockProofFailed" }

export type GenerationEvent =
	{ kind: "AbortBeforeMeasured" }
	| { kind: "BeginWarmup" }
	| { kind: "PostSimulation" }
	| { kind: "BeginMeasured" }
	| { kind: "OperationStarted", phase: "Warmup" | "Measured", fixtureIndex: number }
	| { kind: "OperationReturned", phase: "Warmup" | "Measured", fixtureIndex: number }
	| { kind: "OperationReturnedWithInputMutation", phase: "Warmup" | "Measured", fixtureIndex: number }
	| { kind: "OperationFailed", phase: "Warmup" | "Measured" }
	| { kind: "ArmMeasured", startSharedSeconds: number }
	| { kind: "FinishMeasured", outcome: "Complete" | "Abort" }
	| { kind: "Timeout", scope: "Warmup" | "Delivery" | "ProbeResponse" }
	| { kind: "AbortAfterLocalCompletion" }
	| { kind: "BeginTeardown" }
	| { kind: "FinishTeardown", clean: boolean }
	| { kind: "FinishTeardownObservation" }

export type GenerationPhase =
	"Prepared"
	| "Warmup"
	| "WarmupDrained"
	| "ControlQuiet"
	| "ArmedMeasured"
	| "Measured"
	| "Draining"
	| "Verified"
	| "Aborting"
	| "PostTeardownObservation"
	| "Closed"

export type GenerationStatus =
	{ kind: "State", phase: "ControlQuiet" | "Verified", quietFrames: number }
	| {
		kind: "State",
		phase: "Prepared" | "Warmup" | "WarmupDrained" | "ArmedMeasured" | "Measured" | "Draining" | "Aborting" | "PostTeardownObservation" | "Closed",
	}
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

export type GenerationStatePort<TSender> = {
	observeDelivery: (argumentCount: number, delivery: unknown, metadata: unknown) -> DeliveryAction,
	staleHandler: DeliveryRouter.StaleHandler,
	transition: (event: GenerationEvent) -> GenerationStatus,
	status: () -> GenerationStatus,
}

export type ParticipantState<TSender> = {
	selection: AdapterContract.ResolvedSelection,
	participant: SessionOwner.ParticipantRef,
	beginGeneration: (
		repetitionIndex: number,
		fixture: Fixtures.FixtureSet | Fixtures.ProbeFixtureSet,
		gate: DeliveryRouter.SinkGate,
		timing: TimingRecorder.Recorder,
		senderTokens: { TSender }?
	) -> GenerationStatePort<TSender>,
	recordFailure: (fact: SanitizedFailureFactV1) ->
		{ kind: "Recorded" }
		| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
	freeze: () ->
		{ kind: "Evidence", value: ParticipantEvidenceV1 | ServerEvidenceV1 }
		| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
}

export type CaseEvent =
	{ kind: "AbortRemaining" }
	| { kind: "MeasuredStarted", repetitionIndex: number }
	| { kind: "RepetitionAborted", repetitionIndex: number }
	| { kind: "RepetitionCompleted", repetitionIndex: number, finalOnlyEvidence: boolean }
	| { kind: "Disconnect", repetitionIndex: number }

export type CaseStatus =
	{
		kind: "State",
		phase: "NotStarted" | "Running" | "Complete" | "Aborted" | "Frozen",
		scheduledRepetitions: number,
		startedRepetitions: number,
		completedRepetitions: number,
	}
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

export type CoordinatorEvidenceV1 = {
	scheduledRepetitions: number,
	startedRepetitions: number,
	completedRepetitions: number,
	finalOnlyEvidence: boolean,
	failureFacts: { CoordinatorFailureFactV1 },
}

export type ParticipantSnapshot = {
	participant: SessionOwner.ParticipantRef,
	evidence: ParticipantEvidenceV1 | ServerEvidenceV1,
}

export type CaseSnapshot = {
	version: number,
	selection: AdapterContract.ResolvedSelection,
	coordinator: CoordinatorEvidenceV1,
	participants: { ParticipantSnapshot },
}

export type CoordinatorDeadlineScope = "Readiness" | "Warmup" | "Delivery" | "ProbeResponse"
export type CoordinatorDeadlineStatus = { kind: "Active" } | { kind: "Expired" } | { kind: "ClockFailed" }

export type CaseState = {
	selection: AdapterContract.ResolvedSelection,
	caseDefinition: EventV1.Workload | EventV1.Probe,
	acceptSession: (repetitionIndex: number, result: SessionOwner.OpenResult<any>) -> CaseStatus,
	transition: (event: CaseEvent) -> CaseStatus,
	startDeadline: (scope: CoordinatorDeadlineScope) -> CoordinatorDeadlineStatus,
	checkDeadline: (scope: "Case" | CoordinatorDeadlineScope) -> CoordinatorDeadlineStatus,
	clearDeadline: (scope: CoordinatorDeadlineScope) -> (),
	recordFailure: (fact: CoordinatorFailureFactV1) -> { kind: "Recorded" } | { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
	terminate: (termination: HarnessTerminationV1.HarnessTerminationV1) -> CaseStatus,
	status: () -> CaseStatus,
	snapshot: (participantSnapshots: { ParticipantSnapshot }) -> { kind: "Snapshot", value: CaseSnapshot } | { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
}

local CONFIG_ERROR = "RUN_STATE_E_CONFIG"
local STATE_ERROR = "RUN_STATE_E_STATE"
local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local UINT32_MAX = 0xFFFFFFFF
local MAX_FAILURE_GROUPS = 39
local QUIET_FRAMES = 60
local SHORT_DEADLINE_SECONDS = 120
local CASE_DEADLINE_SECONDS = 7_200

local CODE_ORDER = {
	DuplicateDelivery = 3,
	UnexpectedDelivery = 4,
	OutOfOrderDelivery = 5,
	PayloadMismatch = 6,
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
	ClockProofFailure = 20,
	InternalError = 21,
	InputMutation = 22,
}

local REASON_ORDER = {
	WrongContainerType = 1,
	ArityMismatch = 2,
	MissingField = 3,
	ExtraField = 4,
	WrongType = 5,
	NonFinite = 6,
	NonInteger = 7,
	OutOfRange = 8,
	NotFloat32 = 9,
	ValueMismatch = 10,
}

local PARTICIPANT_CODES = {
	DuplicateDelivery = true,
	UnexpectedDelivery = true,
	OutOfOrderDelivery = true,
	PayloadMismatch = true,
	ControlTrafficDuringMeasuredFrames = true,
	TimingExclusionViolation = true,
	IsolationFailure = true,
	StaleCallback = true,
	DeliveryObservationLimitExceeded = true,
	InputMutation = true,
	SetupFailure = true,
	SubmitFailure = true,
	TeardownFailure = true,
	InternalError = true,
}

local NONE: DeliveryAction = { kind = "None" }
table.freeze(NONE)
local CLOCK_PROOF_FAILED: DeliveryAction = { kind = "ClockProofFailed" }
table.freeze(CLOCK_PROOF_FAILED)

local function fail(code: string): never
	error(code, 0)
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: any): boolean
	return type(value) == "number" and value == 0 and 1 / value == -math.huge
end

local function isSafeInteger(value: any, positive: boolean?): boolean
	return isFinite(value)
		and value % 1 == 0
		and value >= (if positive then 1 else 0)
		and value <= MAX_SAFE_INTEGER
		and not (value == 0 and 1 / value == -math.huge)
end

local function checkedMultiply(left: number, right: number): number
	if not isSafeInteger(left) or not isSafeInteger(right) or (left ~= 0 and right > MAX_SAFE_INTEGER / left) then
		fail(CONFIG_ERROR)
	end
	return left * right
end

local function checkedAdd(left: number, right: number): number
	if not isSafeInteger(left) or not isSafeInteger(right) or right > MAX_SAFE_INTEGER - left then
		fail(CONFIG_ERROR)
	end
	return left + right
end

local function exactPlain(value: unknown, keys: { [string]: boolean }, required: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local count = 0
	for key in next, value :: any do
		if type(key) ~= "string" or rawget(keys, key) ~= true then
			return false
		end
		count += 1
	end
	return count == required
end

local function exactConditional(
	value: unknown,
	required: { [string]: boolean },
	optional: { [string]: boolean }
): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for key in required do
		if rawget(value :: any, key) == nil then return false end
	end
	for key in next, value :: any do
		if type(key) ~= "string" or (required[key] ~= true and optional[key] ~= true) then return false end
	end
	return true
end

local function validCaseEvent(event: unknown): boolean
	if type(event) ~= "table" or getmetatable(event) ~= nil then
		return false
	end
	local value: any = event
	local kind = rawget(value, "kind")
	if kind == "AbortRemaining" then
		return exactPlain(value, { kind = true }, 1)
	elseif kind == "MeasuredStarted" or kind == "RepetitionAborted" or kind == "Disconnect" then
		return exactPlain(value, { kind = true, repetitionIndex = true }, 2)
			and isSafeInteger(rawget(value, "repetitionIndex"), true)
	elseif kind == "RepetitionCompleted" then
		return exactPlain(value, { kind = true, repetitionIndex = true, finalOnlyEvidence = true }, 3)
			and isSafeInteger(rawget(value, "repetitionIndex"), true)
			and type(rawget(value, "finalOnlyEvidence")) == "boolean"
	end
	return false
end

local function validGenerationEvent(event: unknown): boolean
	if type(event) ~= "table" or getmetatable(event) ~= nil then
		return false
	end
	local value: any = event
	local kind = rawget(value, "kind")
	if kind == "AbortBeforeMeasured"
		or kind == "BeginWarmup"
		or kind == "PostSimulation"
		or kind == "BeginMeasured"
		or kind == "AbortAfterLocalCompletion"
		or kind == "BeginTeardown"
		or kind == "FinishTeardownObservation"
	then
		return exactPlain(value, { kind = true }, 1)
	elseif kind == "OperationStarted"
		or kind == "OperationReturned"
		or kind == "OperationReturnedWithInputMutation"
	then
		local phase = rawget(value, "phase")
		return exactPlain(value, { kind = true, phase = true, fixtureIndex = true }, 3)
			and (phase == "Warmup" or phase == "Measured")
			and isSafeInteger(rawget(value, "fixtureIndex"), true)
	elseif kind == "OperationFailed" then
		local phase = rawget(value, "phase")
		return exactPlain(value, { kind = true, phase = true }, 2)
			and (phase == "Warmup" or phase == "Measured")
	elseif kind == "ArmMeasured" then
		local seconds = rawget(value, "startSharedSeconds")
		return exactPlain(value, { kind = true, startSharedSeconds = true }, 2)
			and isFinite(seconds)
			and seconds >= 0
			and not isNegativeZero(seconds)
	elseif kind == "FinishMeasured" then
		local outcome = rawget(value, "outcome")
		return exactPlain(value, { kind = true, outcome = true }, 2)
			and (outcome == "Complete" or outcome == "Abort")
	elseif kind == "Timeout" then
		local scope = rawget(value, "scope")
		return exactPlain(value, { kind = true, scope = true }, 2)
			and (scope == "Warmup" or scope == "Delivery" or scope == "ProbeResponse")
	elseif kind == "FinishTeardown" then
		return exactPlain(value, { kind = true, clean = true }, 2)
			and type(rawget(value, "clean")) == "boolean"
	end
	return false
end

local function denseLength(value: unknown, maximum: number?): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end
	local count = 0
	for key in next, value :: any do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or (maximum ~= nil and key > maximum) then
			return nil
		end
		count += 1
	end
	for index = 1, count do
		if rawget(value :: any, index) == nil then
			return nil
		end
	end
	return count
end

local function boundedNumericStorage(value: unknown, maximum: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local count = 0
	for key in next, value :: any do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximum then
			return false
		end
		count += 1
		if count > maximum then return false end
	end
	return true
end

local function deepEqual(left: any, right: any, seen: { [table]: table }?): boolean
	if rawequal(left, right) then
		return true
	end
	local leftType = typeof(left)
	local rightType = typeof(right)
	if leftType == "Vector3" or rightType == "Vector3" then
		return leftType == "Vector3"
			and rightType == "Vector3"
			and left.X == right.X
			and left.Y == right.Y
			and left.Z == right.Z
	end
	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end
	local visited = seen or {}
	if visited[left] ~= nil then
		return visited[left] == right
	end
	visited[left] = right
	local count = 0
	for key, value in next, left do
		count += 1
		if rawget(right, key) == nil or not deepEqual(value, rawget(right, key), visited) then
			return false
		end
	end
	local rightCount = 0
	for _ in next, right do
		rightCount += 1
	end
	return count == rightCount
end

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for _, nested in next, value do
		deepFreeze(nested)
	end
	table.freeze(value)
end

local function copyDeep(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copied = {}
	for key, nested in next, value do
		copied[key] = copyDeep(nested)
	end
	return copied
end

local function isDeepFrozenAliasFree(
	value: any,
	seen: { [table]: boolean }?,
	active: { [table]: boolean }?
): boolean
	if type(value) ~= "table" then
		return true
	end
	if getmetatable(value) ~= nil or not table.isfrozen(value) then
		return false
	end
	local visited = seen or {}
	local visiting = active or {}
	if visiting[value] or visited[value] then
		return false
	end
	visiting[value] = true
	visited[value] = true
	for key, nested in next, value do
		if type(key) == "table" or not isDeepFrozenAliasFree(nested, visited, visiting) then
			return false
		end
	end
	visiting[value] = nil
	return true
end

local function canonicalSelection(candidate: AdapterContract.ResolvedSelection): boolean
	if type(candidate) ~= "table" or not isDeepFrozenAliasFree(candidate) then
		return false
	end
	local source: any = candidate
	local request: any
	if rawget(source, "kind") == "Workload" then
		request = {
			kind = "Workload",
			workloadId = rawget(source, "workloadId"),
			recipientCount = rawget(source, "recipientCount"),
		}
	elseif rawget(source, "kind") == "SeparateProbe" then
		request = {
			kind = "SeparateProbe",
			probeId = rawget(source, "probeId"),
		}
	else
		return false
	end
	local call = table.pack(pcall(AdapterIdentity.resolveSelection, request))
	return call[1] == true
		and type(call[2]) == "table"
		and rawget(call[2], "kind") == "Valid"
		and deepEqual(candidate, rawget(call[2], "value"))
end

local function resolveDefinition(selection: AdapterContract.ResolvedSelection): EventV1.Workload | EventV1.Probe
	if selection.kind == "Workload" then
		for _, workload in EventV1.workloads do
			if workload.id == selection.workloadId then
				if workload.payloadId ~= selection.payloadId
					or workload.direction ~= selection.direction
					or workload.audience ~= selection.audience
				then
					fail(CONFIG_ERROR)
				end
				return workload
			end
		end
	else
		for _, probe in EventV1.probes do
			if probe.id == selection.probeId then
				if probe.payloadId ~= selection.payloadId then
					fail(CONFIG_ERROR)
				end
				return probe
			end
		end
	end
	fail(CONFIG_ERROR)
end

local function participantEqual(left: SessionOwner.ParticipantRef, right: SessionOwner.ParticipantRef): boolean
	return left.role == right.role and (left.role == "Server" or left.index == (right :: any).index)
end

local function copyParticipant(participant: SessionOwner.ParticipantRef): SessionOwner.ParticipantRef
	local copied: any = { role = participant.role }
	if participant.role ~= "Server" then
		copied.index = participant.index
	end
	table.freeze(copied)
	return copied
end

local function termination(code: HarnessTerminationV1.Code, stage: HarnessTerminationV1.Stage): HarnessTerminationV1.HarnessTerminationV1
	return HarnessTerminationV1.new(code, stage)
end

local function stateStatus(phase: GenerationPhase, quietFrames: number, stopped: HarnessTerminationV1.HarnessTerminationV1?): GenerationStatus
	if stopped ~= nil then
		local value: GenerationStatus = { kind = "Terminated", termination = stopped }
		table.freeze(value)
		return value
	end
	local value: any = { kind = "State", phase = phase }
	if phase == "ControlQuiet" or phase == "Verified" then
		value.quietFrames = quietFrames
	end
	table.freeze(value)
	return value
end

local function caseStatus(
	phase: "NotStarted" | "Running" | "Complete" | "Aborted" | "Frozen",
	stopped: HarnessTerminationV1.HarnessTerminationV1?,
	scheduled: number,
	started: number,
	completed: number
): CaseStatus
	if stopped ~= nil then
		local value: CaseStatus = { kind = "Terminated", termination = stopped }
		table.freeze(value)
		return value
	end
	local value: CaseStatus = {
		kind = "State",
		phase = phase,
		scheduledRepetitions = scheduled,
		startedRepetitions = started,
		completedRepetitions = completed,
	}
	table.freeze(value)
	return value
end

local function failureKey(fact: any): string
	local discriminator = rawget(fact, "discriminator")
	if type(discriminator) == "table" then
		return fact.code .. "\0" .. tostring(rawget(discriminator, "value"))
	end
	return fact.code
end

local function sortFailures(facts: { any })
	table.sort(facts, function(left, right)
		local leftOrder = CODE_ORDER[left.code] or 100
		local rightOrder = CODE_ORDER[right.code] or 100
		if leftOrder ~= rightOrder then
			return leftOrder < rightOrder
		end
		local leftDiscriminator = left.discriminator
		local rightDiscriminator = right.discriminator
		if left.code == "PayloadMismatch" then
			return REASON_ORDER[leftDiscriminator.value] < REASON_ORDER[rightDiscriminator.value]
		elseif left.code == "TimingExclusionViolation" then
			local order = { setup = 1, warmup = 2, quiescence = 3 }
			return order[leftDiscriminator.value] < order[rightDiscriminator.value]
		elseif left.code == "InternalError" then
			local order = { Setup = 1, Execution = 2, Finalize = 3 }
			return order[leftDiscriminator.value] < order[rightDiscriminator.value]
		end
		return tostring(if leftDiscriminator == nil then "" else leftDiscriminator.value)
			< tostring(if rightDiscriminator == nil then "" else rightDiscriminator.value)
	end)
end

local function appendFailure(groups: { [string]: any }, order: { any }, fact: any): boolean
	local key = failureKey(fact)
	local existing = groups[key]
	if existing ~= nil then
		if fact.code ~= "SetupFailure"
			and fact.code ~= "ClockProofFailure"
			and fact.code ~= "InternalError"
			and fact.code ~= "TimingExclusionViolation"
			and fact.code ~= "DeliveryObservationLimitExceeded"
			and fact.code ~= "ControlTrafficDuringMeasuredFrames"
			and fact.code ~= "InputMutation"
		then
			existing.occurrences = checkedAdd(existing.occurrences, fact.occurrences)
		end
		if existing.firstRepetition ~= nil and fact.firstRepetition ~= nil then
			existing.firstRepetition = math.min(existing.firstRepetition, fact.firstRepetition)
		end
		return true
	end
	if #order == MAX_FAILURE_GROUPS then
		return false
	end
	local copied = copyDeep(fact)
	groups[key] = copied
	table.insert(order, copied)
	return true
end

local function copyFailureArray(source: { any }): { any }
	local copied = table.create(#source)
	for index, fact in source do
		copied[index] = copyDeep(fact)
	end
	sortFailures(copied)
	deepFreeze(copied)
	return copied
end

local function validateParticipant(selection: AdapterContract.ResolvedSelection, participant: SessionOwner.ParticipantRef)
	if type(participant) ~= "table" or getmetatable(participant) ~= nil then
		fail(CONFIG_ERROR)
	end
	if participant.role == "Server" then
		if not exactPlain(participant, { role = true }, 1) then
			fail(CONFIG_ERROR)
		end
	else
		if not exactPlain(participant, { role = true, index = true }, 2)
			or not isSafeInteger(participant.index, true)
			or participant.index > selection.clientProcessCount
		then
			fail(CONFIG_ERROR)
		end
		local expectedRole = if selection.kind == "SeparateProbe" then "ProbeClient" else "Client"
		if participant.role ~= expectedRole then
			fail(CONFIG_ERROR)
		end
	end
end

local function isReceiver(selection: AdapterContract.ResolvedSelection, participant: SessionOwner.ParticipantRef): boolean
	if selection.kind == "SeparateProbe" then
		return true
	end
	return (selection.direction == "ClientToServer" and participant.role == "Server")
		or (selection.direction == "ServerToClient" and participant.role == "Client")
end

local function isSender(selection: AdapterContract.ResolvedSelection, participant: SessionOwner.ParticipantRef): boolean
	if selection.kind == "SeparateProbe" then
		return participant.role == "ProbeClient" or participant.role == "Server"
	end
	return (selection.direction == "ClientToServer" and participant.role == "Client")
		or (selection.direction == "ServerToClient" and participant.role == "Server")
end

local function validMismatchFact(selection: AdapterContract.ResolvedSelection, fact: any): boolean
	local reason = fact.discriminator.value
	local mismatch = fact.mismatch
	local kind = mismatch.pathKind
	local actual = rawget(mismatch, "actual")
	local fixtures = if selection.kind == "Workload"
		then Fixtures.generate(selection.workloadId, fact.firstRepetition)
		else Fixtures.generateProbe(selection.probeId, fact.firstRepetition)
	local sample = rawget(fixtures.measured, fact.fixtureIndex)
	if sample == nil then return false end
	local payload = EventV1.payloads[selection.payloadId]
	if kind == "Root" then
		if reason == "ArityMismatch" then
			return isSafeInteger(actual) and actual ~= #payload.fields
		end
		return reason == "WrongContainerType" or reason == "ExtraField"
	end
	if kind ~= "Field" and kind ~= "VectorComponent" then return false end
	local field = rawget(payload.fields, mismatch.fieldIndex)
	if field == nil then return false end
	local vector = field.valueType == "Vector3F32"
	if kind == "VectorComponent" and not vector then return false end
	if reason == "MissingField" then
		return kind == "Field"
	elseif reason == "WrongType" then
		if kind ~= "Field" then return false end
		return not ((field.valueType == "boolean" and type(actual) == "boolean")
			or (field.valueType ~= "boolean" and field.valueType ~= "Vector3F32" and type(actual) == "number"))
	elseif reason == "NonFinite" then
		return field.valueType ~= "boolean" and vector == (kind == "VectorComponent")
	elseif reason == "NonInteger" then
		return kind == "Field"
			and (field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32")
			and isFinite(actual) and actual % 1 ~= 0
	elseif reason == "OutOfRange" then
		if field.valueType == "boolean" or vector ~= (kind == "VectorComponent") or not isFinite(actual) then return false end
		if actual >= field.minimum and actual <= field.maximum then return false end
		return (field.valueType ~= "u8" and field.valueType ~= "u16" and field.valueType ~= "u32")
			or actual % 1 == 0
	elseif reason == "NotFloat32" then
		if (field.valueType ~= "f32" and field.valueType ~= "Vector3F32")
			or vector ~= (kind == "VectorComponent")
			or not isFinite(actual) or actual < field.minimum or actual > field.maximum
		then return false end
		local encoded = buffer.create(4)
		buffer.writef32(encoded, 0, actual)
		return buffer.readf32(encoded, 0) ~= actual
	elseif reason ~= "ValueMismatch" then
		return false
	end
	if vector ~= (kind == "VectorComponent") then return false end
	local expected = rawget(sample.expected, field.name)
	if kind == "VectorComponent" then expected = expected[mismatch.component] end
	if field.valueType == "boolean" then
		return kind == "Field" and type(actual) == "boolean" and actual ~= expected
	elseif field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32" then
		return kind == "Field" and isFinite(actual) and actual % 1 == 0
			and actual >= field.minimum and actual <= field.maximum and actual ~= expected
	end
	if not isFinite(actual) or actual < field.minimum or actual > field.maximum then return false end
	local encoded = buffer.create(4)
	buffer.writef32(encoded, 0, actual)
	if buffer.readf32(encoded, 0) ~= actual then return false end
	local actualBits = buffer.readu32(encoded, 0)
	buffer.writef32(encoded, 0, expected)
	return actualBits ~= buffer.readu32(encoded, 0)
end

local copyCoordinatorFact: (CoordinatorFailureFactV1) -> CoordinatorFailureFactV1
local copyParticipantFact: (SanitizedFailureFactV1, number) -> SanitizedFailureFactV1

local function newCase<TSender>(
	preparedCandidate: SessionOwner.PreparedCase<TSender>,
	serverClock: BenchmarkClock.Clock
): CaseState
	-- The public brand guard is deliberately the first operation. In particular,
	-- no candidate field is read before it succeeds.
	local preparedCall = table.pack(pcall(SessionOwner.requirePreparedCase, preparedCandidate))
	if preparedCall[1] ~= true then
		fail(CONFIG_ERROR)
	end
	local prepared: SessionOwner.PreparedCase<TSender> = preparedCall[2]
	if type(serverClock) ~= "table"
		or not table.isfrozen(serverClock)
		or not exactPlain(serverClock, {
			localNowSeconds = true,
			sharedNowSeconds = true,
			timeoutNowSeconds = true,
			startDeadline = true,
		}, 4)
		or type(rawget(serverClock :: any, "localNowSeconds")) ~= "function"
		or type(rawget(serverClock :: any, "sharedNowSeconds")) ~= "function"
		or type(rawget(serverClock :: any, "timeoutNowSeconds")) ~= "function"
		or type(rawget(serverClock :: any, "startDeadline")) ~= "function"
	then
		fail(CONFIG_ERROR)
	end
	local selection = prepared.selection
	local caseDefinition = prepared.caseDefinition
	if not canonicalSelection(selection) or not rawequal(resolveDefinition(selection), caseDefinition) then
		fail(CONFIG_ERROR)
	end
	local scheduled = caseDefinition.repetitions
	local expectedDeliveryPerRepetition = if selection.kind == "Workload"
		then checkedMultiply(caseDefinition.senderCount, checkedMultiply(caseDefinition.measuredFrames, caseDefinition.messagesPerFrame))
		else caseDefinition.measuredSamples
	local caseDeadlineCall = table.pack(pcall(serverClock.startDeadline, CASE_DEADLINE_SECONDS))
	local caseDeadline: BenchmarkClock.Deadline? = if caseDeadlineCall[1] then caseDeadlineCall[2] else nil
	local caseDeadlineFailed = not caseDeadlineCall[1]
	local deadlines: { [CoordinatorDeadlineScope]: BenchmarkClock.Deadline } = {}
	local deadlineExpired: { [CoordinatorDeadlineScope]: boolean } = {}
	local accepted: { [number]: boolean } = {}
	local started = 0
	local completed = 0
	local finalOnlyEvidence = false
	local phase: "NotStarted" | "Running" | "Complete" | "Aborted" | "Frozen" = "NotStarted"
	local stopped: HarnessTerminationV1.HarnessTerminationV1? = nil
	local failureGroups: { [string]: any } = {}
	local failureOrder: { any } = {}
	local frozenSnapshot: CaseSnapshot? = nil

	local function recordFailure(
		factCandidate: CoordinatorFailureFactV1
	): { kind: "Recorded" } | { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
		if phase == "Frozen" then
			fail(STATE_ERROR)
		end
		if stopped ~= nil then
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		local fact = copyCoordinatorFact(factCandidate)
		if fact.firstRepetition ~= nil and fact.firstRepetition > started then
			fail(CONFIG_ERROR)
		end
		if not appendFailure(failureGroups, failureOrder, fact) then
			stopped = termination("FinalEvidenceUnrepresentable", "Execution")
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		local result = { kind = "Recorded" } :: { kind: "Recorded" }
		table.freeze(result)
		return result
	end

	local function terminate(value: HarnessTerminationV1.HarnessTerminationV1): CaseStatus
		if phase == "Frozen" then
			fail(STATE_ERROR)
		end
		if stopped == nil then
			if type(value) ~= "table" or not table.isfrozen(value) then
				fail(CONFIG_ERROR)
			end
			local check = table.pack(pcall(HarnessTerminationV1.validate, value))
			if check[1] ~= true then
				fail(CONFIG_ERROR)
			end
			stopped = value
		end
		return caseStatus(phase, stopped, scheduled, started, completed)
	end

	local function acceptSession(repetitionIndex: number, result: SessionOwner.OpenResult<any>): CaseStatus
		if stopped ~= nil then
			return caseStatus(phase, stopped, scheduled, started, completed)
		end
		if phase == "Frozen"
			or not isSafeInteger(repetitionIndex, true)
			or repetitionIndex > scheduled
			or repetitionIndex ~= completed + 1
			or accepted[repetitionIndex]
			or type(result) ~= "table"
			or not table.isfrozen(result)
		then
			fail(STATE_ERROR)
		end
		local kind = rawget(result :: any, "kind")
		if kind == "Terminated" then
			local value = rawget(result :: any, "termination")
			return terminate(value)
		end
		if kind ~= "Ready" and kind ~= "SetupFailed" and kind ~= "InternalFailed" then
			fail(CONFIG_ERROR)
		end
		if not deepEqual(rawget(result :: any, "manifest"), prepared.manifest) then
			fail(CONFIG_ERROR)
		end
		accepted[repetitionIndex] = true
		if kind == "SetupFailed" then
			recordFailure({ code = "SetupFailure", occurrences = 1 })
			phase = "Aborted"
		elseif kind == "InternalFailed" then
			recordFailure({
				code = "InternalError",
				occurrences = 1,
				discriminator = { kind = "Stage", value = "Setup" },
			})
			phase = "Aborted"
		end
		return caseStatus(phase, stopped, scheduled, started, completed)
	end

	local function transition(event: CaseEvent): CaseStatus
		if stopped ~= nil then
			return caseStatus(phase, stopped, scheduled, started, completed)
		end
		if phase == "Frozen" or not validCaseEvent(event) then
			fail(STATE_ERROR)
		end
		if event.kind == "AbortRemaining" then
			if (phase ~= "NotStarted" and phase ~= "Running") or started ~= completed then
				fail(STATE_ERROR)
			end
			phase = "Aborted"
		elseif event.kind == "MeasuredStarted" then
			if (phase ~= "NotStarted" and phase ~= "Running")
				or event.repetitionIndex ~= started + 1
				or event.repetitionIndex > scheduled
				or accepted[event.repetitionIndex] ~= true
			then
				fail(STATE_ERROR)
			end
			started += 1
			phase = "Running"
		elseif event.kind == "RepetitionCompleted" then
			if phase ~= "Running" or started ~= completed + 1 or event.repetitionIndex ~= started then
				fail(STATE_ERROR)
			end
			completed += 1
			finalOnlyEvidence = finalOnlyEvidence or event.finalOnlyEvidence
			if completed == scheduled then
				phase = "Complete"
			end
		elseif event.kind == "RepetitionAborted" then
			if phase ~= "Running" or started ~= completed + 1 or event.repetitionIndex ~= started then
				fail(STATE_ERROR)
			end
			phase = "Aborted"
		elseif event.kind == "Disconnect" then
			if phase ~= "Running" or started ~= completed + 1 or event.repetitionIndex ~= started then
				fail(STATE_ERROR)
			end
			recordFailure({ code = "Disconnect", occurrences = 1, firstRepetition = event.repetitionIndex })
			phase = "Aborted"
		else
			fail(STATE_ERROR)
		end
		return caseStatus(phase, stopped, scheduled, started, completed)
	end

	local function startDeadline(scope: CoordinatorDeadlineScope): CoordinatorDeadlineStatus
		if phase == "Frozen" or (deadlines[scope] ~= nil and deadlineExpired[scope] ~= true) then
			fail(STATE_ERROR)
		end
		local call = table.pack(pcall(serverClock.startDeadline, SHORT_DEADLINE_SECONDS))
		if call[1] ~= true then
			local result: CoordinatorDeadlineStatus = { kind = "ClockFailed" }
			table.freeze(result)
			return result
		end
		deadlines[scope] = call[2]
		deadlineExpired[scope] = false
		local result: CoordinatorDeadlineStatus = { kind = "Active" }
		table.freeze(result)
		return result
	end

	local function checkDeadline(scope: "Case" | CoordinatorDeadlineScope): CoordinatorDeadlineStatus
		if phase == "Frozen" then
			fail(STATE_ERROR)
		end
		local deadline: BenchmarkClock.Deadline?
		if scope == "Case" then
			if caseDeadlineFailed then
				local failed: CoordinatorDeadlineStatus = { kind = "ClockFailed" }
				table.freeze(failed)
				return failed
			end
			deadline = caseDeadline
		else
			deadline = deadlines[scope]
			if deadline == nil then fail(STATE_ERROR) end
		end
		local call = table.pack(pcall((deadline :: BenchmarkClock.Deadline).check))
		if call[1] ~= true then
			local failed: CoordinatorDeadlineStatus = { kind = "ClockFailed" }
			table.freeze(failed)
			return failed
		end
		local kind = rawget(call[2], "kind")
		if kind ~= "Active" and kind ~= "Expired" then
			local failed: CoordinatorDeadlineStatus = { kind = "ClockFailed" }
			table.freeze(failed)
			return failed
		end
		if scope ~= "Case" and kind == "Expired" then
			deadlineExpired[scope] = true
		end
		local result: CoordinatorDeadlineStatus = { kind = kind }
		table.freeze(result)
		return result
	end

	local function clearDeadline(scope: CoordinatorDeadlineScope)
		if phase == "Frozen" or deadlines[scope] == nil or deadlineExpired[scope] then
			fail(STATE_ERROR)
		end
		deadlines[scope] = nil
		deadlineExpired[scope] = nil
	end

	local function validateEvidence(
		participant: SessionOwner.ParticipantRef,
		evidence: ParticipantEvidenceV1 | ServerEvidenceV1,
		snapshotSeen: { [table]: boolean }
	): boolean
		if type(evidence) ~= "table" or not isDeepFrozenAliasFree(evidence, snapshotSeen) or evidence.version ~= 1 then
			return false
		end
		local server = participant.role == "Server"
		local firstOnlyEndpoint = false
		if not exactPlain(evidence, if server
			then { version = true, repetitions = true, measurements = true, timingEndpoints = true, failureFacts = true, conformance = true }
			else { version = true, repetitions = true, measurements = true, failureFacts = true, conformance = true }, if server then 6 else 5)
		then
			return false
		end
		local expectedRepetitionCount = if server then scheduled else started
		if denseLength(evidence.repetitions, expectedRepetitionCount) ~= expectedRepetitionCount
			or denseLength(evidence.measurements, 210) == nil
			or denseLength(evidence.failureFacts, MAX_FAILURE_GROUPS) == nil
		then
			return false
		end
		if server and denseLength((evidence :: ServerEvidenceV1).timingEndpoints, scheduled) ~= started then
			return false
		end
		local commonRepetitionKeys = {
			repetitionIndex = true, started = true, completed = true, submitted = true,
			received = true, correct = true, mismatch = true, duplicate = true,
			unexpected = true, outOfOrder = true, staleCallbacks = true,
			observationOverflow = true,
		}
		local remoteRequired = copyDeep(commonRepetitionKeys)
		for _, key in { "probeStarted", "probeSubmitted", "probeReceived", "probeCorrect", "probeMismatch" } do
			remoteRequired[key] = true
		end
		local remoteOptional = {
			firstSubmissionStartedSharedSeconds = true,
			finalSubmissionReturnedSharedSeconds = true,
			finalExpectedDeliveryReceivedSharedSeconds = true,
			finalExpectedDeliveryVerifiedSharedSeconds = true,
		}
		local serverRequired = copyDeep(commonRepetitionKeys)
		for _, key in { "probeRequestsReceived", "probeRequestsCorrect", "probeRequestsMismatch", "probeResponsesSubmitted" } do
			serverRequired[key] = true
		end
		local totals = {
			duplicate = 0,
			unexpected = 0,
			outOfOrder = 0,
			mismatch = 0,
			staleCallbacks = 0,
		}
		local submissionCandidates: { [number]: boolean } = {}
		local firstOverflowRepetition: number? = nil
		local function addTotal(key: string, value: number): boolean
			local current = rawget(totals :: any, key)
			if not isSafeInteger(current) or value > MAX_SAFE_INTEGER - current then
				return false
			end
			(totals :: any)[key] = current + value
			return true
		end
		for index, repetition in evidence.repetitions do
			local currentExtraCompletion = type(repetition) == "table"
				and started == completed + 1
				and index == started
				and rawget(repetition, "completed") == true
			if type(repetition) ~= "table"
				or not table.isfrozen(repetition)
				or repetition.repetitionIndex ~= index
				or repetition.started ~= (index <= started)
				or (repetition.completed ~= (index <= completed) and not currentExtraCompletion)
				or (server and not exactPlain(repetition, serverRequired, 16))
				or (not server and not exactConditional(repetition, remoteRequired, remoteOptional))
			then
				return false
			end
			for _, key in { "submitted", "received", "correct", "mismatch", "duplicate", "unexpected", "outOfOrder", "staleCallbacks" } do
				if not isSafeInteger(rawget(repetition, key)) then return false end
			end
			if type(repetition.observationOverflow) ~= "boolean"
				or type(repetition.started) ~= "boolean"
				or type(repetition.completed) ~= "boolean"
				or repetition.received ~= repetition.correct + repetition.mismatch + repetition.duplicate + repetition.unexpected
				or repetition.outOfOrder > repetition.correct + repetition.mismatch
			then
				return false
			end
			if not repetition.started then
				for _, key in { "submitted", "received", "correct", "mismatch", "duplicate", "unexpected", "outOfOrder", "staleCallbacks" } do
					if rawget(repetition, key) ~= 0 then return false end
				end
				if repetition.observationOverflow then return false end
			end
			if not addTotal("duplicate", repetition.duplicate)
				or not addTotal("unexpected", repetition.unexpected)
				or not addTotal("outOfOrder", repetition.outOfOrder)
				or not addTotal("staleCallbacks", repetition.staleCallbacks)
			then return false end
			if repetition.observationOverflow and firstOverflowRepetition == nil then
				firstOverflowRepetition = index
			end
			if server then
				local serverRepetition: any = repetition
				for _, key in { "probeRequestsReceived", "probeRequestsCorrect", "probeRequestsMismatch", "probeResponsesSubmitted" } do
					if not isSafeInteger(serverRepetition[key]) then return false end
				end
				if not repetition.started
					and (serverRepetition.probeRequestsReceived ~= 0
						or serverRepetition.probeRequestsCorrect ~= 0
						or serverRepetition.probeRequestsMismatch ~= 0
						or serverRepetition.probeResponsesSubmitted ~= 0)
				then return false end
				if selection.kind == "SeparateProbe" then
					if serverRepetition.submitted ~= 0 or serverRepetition.received ~= 0
						or serverRepetition.correct ~= 0 or serverRepetition.mismatch ~= 0
						or serverRepetition.duplicate ~= 0 or serverRepetition.unexpected ~= 0
						or serverRepetition.outOfOrder ~= 0
						or serverRepetition.probeRequestsReceived ~= serverRepetition.probeRequestsCorrect + serverRepetition.probeRequestsMismatch
						or serverRepetition.probeResponsesSubmitted > serverRepetition.probeRequestsCorrect
						or serverRepetition.probeRequestsReceived > checkedMultiply(4, (caseDefinition :: EventV1.Probe).measuredSamples)
						or serverRepetition.probeResponsesSubmitted > (caseDefinition :: EventV1.Probe).measuredSamples
					then return false end
					if serverRepetition.completed
						and (serverRepetition.probeRequestsReceived ~= (caseDefinition :: EventV1.Probe).measuredSamples
							or serverRepetition.probeResponsesSubmitted ~= serverRepetition.probeRequestsCorrect)
					then return false end
					if not addTotal("mismatch", serverRepetition.probeRequestsMismatch) then return false end
					submissionCandidates[index] = serverRepetition.probeRequestsCorrect > serverRepetition.probeResponsesSubmitted
				elseif selection.direction == "ClientToServer" then
					if serverRepetition.submitted ~= 0 or serverRepetition.probeRequestsReceived ~= 0
						or serverRepetition.probeRequestsCorrect ~= 0 or serverRepetition.probeRequestsMismatch ~= 0
						or serverRepetition.probeResponsesSubmitted ~= 0
						or serverRepetition.received > checkedMultiply(4, expectedDeliveryPerRepetition)
					then return false end
					if serverRepetition.completed
						and serverRepetition.correct + serverRepetition.mismatch ~= expectedDeliveryPerRepetition
						and not finalOnlyEvidence
					then return false end
					if not addTotal("mismatch", serverRepetition.mismatch) then return false end
				else
					if serverRepetition.received ~= 0 or serverRepetition.correct ~= 0 or serverRepetition.mismatch ~= 0
						or serverRepetition.duplicate ~= 0 or serverRepetition.unexpected ~= 0
						or serverRepetition.outOfOrder ~= 0 or serverRepetition.staleCallbacks ~= 0
						or serverRepetition.observationOverflow
						or serverRepetition.probeRequestsReceived ~= 0 or serverRepetition.probeRequestsCorrect ~= 0
						or serverRepetition.probeRequestsMismatch ~= 0 or serverRepetition.probeResponsesSubmitted ~= 0
						or serverRepetition.submitted > checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, (caseDefinition :: EventV1.Workload).messagesPerFrame)
					then return false end
					if serverRepetition.completed and serverRepetition.submitted ~= checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, (caseDefinition :: EventV1.Workload).messagesPerFrame) then return false end
				end
			else
				local remote: any = repetition
				for _, key in { "probeStarted", "probeSubmitted", "probeReceived", "probeCorrect", "probeMismatch" } do
					if not isSafeInteger(remote[key]) then return false end
				end
				local senderFirst = rawget(remote, "firstSubmissionStartedSharedSeconds")
				local senderFinal = rawget(remote, "finalSubmissionReturnedSharedSeconds")
				local receiverReceived = rawget(remote, "finalExpectedDeliveryReceivedSharedSeconds")
				local receiverVerified = rawget(remote, "finalExpectedDeliveryVerifiedSharedSeconds")
				if not repetition.started
					and (remote.probeStarted ~= 0
						or remote.probeSubmitted ~= 0
						or remote.probeReceived ~= 0
						or remote.probeCorrect ~= 0
						or remote.probeMismatch ~= 0
						or senderFirst ~= nil
						or senderFinal ~= nil
						or receiverReceived ~= nil
						or receiverVerified ~= nil)
				then return false end
				if selection.kind == "SeparateProbe" then
					if remote.submitted ~= 0 or remote.received ~= 0 or remote.correct ~= 0 or remote.mismatch ~= 0
						or remote.duplicate ~= 0 or remote.unexpected ~= 0 or remote.outOfOrder ~= 0
						or remote.probeReceived ~= remote.probeCorrect + remote.probeMismatch
						or remote.probeReceived > remote.probeSubmitted or remote.probeSubmitted > remote.probeStarted
						or senderFirst ~= nil or senderFinal ~= nil or receiverReceived ~= nil or receiverVerified ~= nil
						or remote.probeStarted > (caseDefinition :: EventV1.Probe).measuredSamples
					then return false end
					if remote.completed
						and (remote.probeStarted ~= (caseDefinition :: EventV1.Probe).measuredSamples
							or remote.probeSubmitted ~= remote.probeStarted
							or remote.probeReceived ~= remote.probeSubmitted)
					then return false end
					if not addTotal("mismatch", remote.probeMismatch) then return false end
					submissionCandidates[index] = remote.probeStarted > remote.probeSubmitted
				elseif selection.direction == "ClientToServer" then
					if remote.received ~= 0 or remote.correct ~= 0 or remote.mismatch ~= 0 or remote.duplicate ~= 0
						or remote.unexpected ~= 0 or remote.outOfOrder ~= 0 or remote.staleCallbacks ~= 0
						or remote.observationOverflow or remote.probeStarted ~= 0 or remote.probeSubmitted ~= 0
						or remote.probeReceived ~= 0 or remote.probeCorrect ~= 0 or remote.probeMismatch ~= 0
						or receiverReceived ~= nil or receiverVerified ~= nil or (senderFinal ~= nil and senderFirst == nil)
						or remote.submitted > checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, (caseDefinition :: EventV1.Workload).messagesPerFrame)
					then return false end
				if remote.completed and remote.submitted ~= checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, (caseDefinition :: EventV1.Workload).messagesPerFrame) then return false end
				if remote.submitted > 0 and senderFirst == nil then return false end
				submissionCandidates[index] = senderFirst ~= nil
					and remote.submitted < checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, (caseDefinition :: EventV1.Workload).messagesPerFrame)
				else
					if remote.submitted ~= 0 or remote.probeStarted ~= 0 or remote.probeSubmitted ~= 0
						or remote.probeReceived ~= 0 or remote.probeCorrect ~= 0 or remote.probeMismatch ~= 0
					or senderFirst ~= nil or senderFinal ~= nil or ((receiverReceived == nil) ~= (receiverVerified == nil))
					or (receiverReceived ~= nil and remote.correct + remote.mismatch ~= expectedDeliveryPerRepetition)
						or remote.received > checkedMultiply(4, expectedDeliveryPerRepetition)
					then return false end
					if remote.completed
						and remote.correct + remote.mismatch ~= expectedDeliveryPerRepetition
						and not finalOnlyEvidence
					then return false end
					if not addTotal("mismatch", remote.mismatch) then return false end
				end
				for _, endpoint in { senderFirst, senderFinal, receiverReceived, receiverVerified } do
					if endpoint ~= nil and (not isFinite(endpoint) or endpoint < 0 or isNegativeZero(endpoint)) then return false end
				end
				if senderFirst ~= nil and senderFinal ~= nil and senderFinal < senderFirst then return false end
				if receiverReceived ~= nil and receiverVerified ~= nil and receiverVerified < receiverReceived then return false end
				if senderFirst ~= nil and senderFinal == nil then firstOnlyEndpoint = true end
				if repetition.completed then
					if selection.kind == "Workload" and selection.direction == "ClientToServer"
						and (senderFirst == nil or senderFinal == nil)
					then return false end
					if selection.kind == "Workload" and selection.direction == "ServerToClient"
						and repetition.correct + repetition.mismatch == expectedDeliveryPerRepetition
						and (receiverReceived == nil or receiverVerified == nil)
					then return false end
				end
			end
		end
		if server then
			for endpointIndex, endpoint in (evidence :: ServerEvidenceV1).timingEndpoints do
				if not exactConditional(endpoint, { repetitionIndex = true }, {
					firstSubmissionStartedSharedSeconds = true,
					finalSubmissionReturnedSharedSeconds = true,
					finalExpectedDeliveryReceivedSharedSeconds = true,
					finalExpectedDeliveryVerifiedSharedSeconds = true,
				})
					or not isSafeInteger(endpoint.repetitionIndex, true)
					or endpoint.repetitionIndex ~= endpointIndex
				then return false end
				local first = endpoint.firstSubmissionStartedSharedSeconds
				local final = endpoint.finalSubmissionReturnedSharedSeconds
				local received = endpoint.finalExpectedDeliveryReceivedSharedSeconds
				local verified = endpoint.finalExpectedDeliveryVerifiedSharedSeconds
				if selection.kind == "SeparateProbe" then
					if first ~= nil or final ~= nil or received ~= nil or verified ~= nil then return false end
				elseif selection.direction == "ClientToServer" then
					if first ~= nil or final ~= nil or ((received == nil) ~= (verified == nil)) then return false end
				elseif received ~= nil or verified ~= nil or (final ~= nil and first == nil) then
					return false
				end
				for _, value in { first, final, received, verified } do
					if value ~= nil and (not isFinite(value) or value < 0 or isNegativeZero(value)) then return false end
				end
				if first ~= nil and final ~= nil and final < first then return false end
				if received ~= nil and verified ~= nil and verified < received then return false end
				if first ~= nil and final == nil then firstOnlyEndpoint = true end
			local repetition = evidence.repetitions[endpointIndex]
			if selection.kind == "Workload" and selection.direction == "ServerToClient"
				and repetition.submitted > 0 and first == nil
			then return false end
			if selection.kind == "Workload" and selection.direction == "ServerToClient" then
				submissionCandidates[endpointIndex] = first ~= nil
					and repetition.submitted < checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, (caseDefinition :: EventV1.Workload).messagesPerFrame)
			end
			if received ~= nil and repetition.correct + repetition.mismatch ~= expectedDeliveryPerRepetition then
				return false
			end
			if repetition.completed then
					if selection.kind == "Workload" and selection.direction == "ServerToClient"
						and (first == nil or final == nil)
					then return false end
					if selection.kind == "Workload" and selection.direction == "ClientToServer"
						and repetition.correct + repetition.mismatch == expectedDeliveryPerRepetition
						and (received == nil or verified == nil)
					then return false end
				end
			end
		end
		local allowedMeasurements: { [number]: number } = {}
		local requiredMeasurements: { [number]: boolean } = {}
		if selection.kind == "SeparateProbe" then
			if participant.role == "ProbeClient" then
				allowedMeasurements[9] = (caseDefinition :: EventV1.Probe).measuredSamples
				requiredMeasurements[9] = true
			end
		elseif (participant.role == "Server" and selection.direction == "ServerToClient")
			or (participant.role == "Client" and selection.direction == "ClientToServer")
		then
			local workload = caseDefinition :: EventV1.Workload
			allowedMeasurements[4] = workload.measuredFrames
			allowedMeasurements[5] = 1
			allowedMeasurements[10] = checkedMultiply(workload.measuredFrames, workload.messagesPerFrame)
			allowedMeasurements[11] = workload.measuredFrames
			allowedMeasurements[12] = checkedMultiply(workload.measuredFrames, workload.messagesPerFrame)
			allowedMeasurements[13] = 1
			allowedMeasurements[14] = 1
			requiredMeasurements[4] = true
			requiredMeasurements[5] = true
			requiredMeasurements[10] = true
		end
		local measurementGroups: { [string]: boolean } = {}
		for _, measurement in evidence.measurements do
			if type(measurement) ~= "table"
				or not table.isfrozen(measurement)
				or not isSafeInteger(measurement.measurementIndex, true)
				or allowedMeasurements[measurement.measurementIndex] == nil
				or not isSafeInteger(measurement.repetitionIndex, true)
				or measurement.repetitionIndex > started
				or not exactPlain(measurement, { measurementIndex = true, repetitionIndex = true, values = true }, 3)
			then
				return false
			end
			local expectedValueCount = allowedMeasurements[measurement.measurementIndex]
			local valueCount = denseLength(measurement.values, expectedValueCount)
			if valueCount == nil
				or (measurement.repetitionIndex <= completed and valueCount ~= expectedValueCount)
			then
				return false
			end
			local groupKey = tostring(measurement.measurementIndex) .. "\0" .. tostring(measurement.repetitionIndex)
			if measurementGroups[groupKey] then return false end
			measurementGroups[groupKey] = true
			for _, value in measurement.values do
				if not isFinite(value) or value < 0 or isNegativeZero(value) then return false end
			end
		end
		for measurementIndex in requiredMeasurements do
			for repetitionIndex = 1, completed do
				local groupKey = tostring(measurementIndex) .. "\0" .. tostring(repetitionIndex)
				if not measurementGroups[groupKey] then
					return false
				end
			end
		end
		local conformance = evidence.conformance
		if not exactPlain(conformance, {
			setupExcluded = true,
			warmupExcluded = true,
			quiescenceExcluded = true,
			resultExtractionExcluded = true,
			clockProofPassed = true,
		}, 5)
		then
			return false
		end
		for _, value in conformance do
			if type(value) ~= "boolean" then return false end
		end
		local factTotals: { [string]: number } = {}
		local factKeys: { [string]: boolean } = {}
		local timingExclusionFacts: { [string]: boolean } = {}
		local hasSubmitFailure = false
		local hasInputMutation = false
		local hasSetupFailure = false
		local hasPrestartTeardownFailure = false
		local receiverRole = isReceiver(selection, participant)
		local senderRole = isSender(selection, participant)
		local function firstRepetitionWith(key: string): number?
			for repetitionIndex, repetition in evidence.repetitions do
				if rawget(repetition, key) > 0 then return repetitionIndex end
			end
			return nil
		end
		for _, fact in evidence.failureFacts do
			if type(fact) ~= "table" or not table.isfrozen(fact) then return false end
			local ok = pcall(copyParticipantFact, fact, scheduled)
			if not ok then return false end
			local key = failureKey(fact)
			if factKeys[key] then return false end
			factKeys[key] = true
			if fact.firstRepetition ~= nil and fact.firstRepetition > started then return false end
			local previous = factTotals[fact.code] or 0
			if fact.occurrences > MAX_SAFE_INTEGER - previous then return false end
			factTotals[fact.code] = previous + fact.occurrences
			if (fact.code == "DuplicateDelivery"
				or fact.code == "UnexpectedDelivery"
				or fact.code == "OutOfOrderDelivery"
				or fact.code == "PayloadMismatch"
				or fact.code == "StaleCallback"
				or fact.code == "DeliveryObservationLimitExceeded")
				and not receiverRole
			then return false end
			if fact.code == "SubmitFailure" then
				if not senderRole then return false end
				if submissionCandidates[fact.firstRepetition] ~= true then return false end
				local capacity = 0
				for repetitionIndex = fact.firstRepetition, scheduled do
					if submissionCandidates[repetitionIndex] then capacity += 1 end
				end
				if fact.occurrences > capacity then return false end
				hasSubmitFailure = true
			elseif fact.code == "InputMutation" then
				if not senderRole then return false end
				hasInputMutation = true
			elseif fact.code == "DuplicateDelivery" then
				if fact.firstRepetition ~= firstRepetitionWith("duplicate") then return false end
			elseif fact.code == "UnexpectedDelivery" then
				if fact.firstRepetition ~= firstRepetitionWith("unexpected") then return false end
			elseif fact.code == "OutOfOrderDelivery" then
				if fact.firstRepetition ~= firstRepetitionWith("outOfOrder") then return false end
			elseif fact.code == "StaleCallback" then
				if fact.firstRepetition ~= firstRepetitionWith("staleCallbacks") then return false end
		elseif fact.code == "IsolationFailure" or fact.code == "TeardownFailure" then
			if fact.firstRepetition ~= nil
				and fact.occurrences > started - fact.firstRepetition + 1
			then return false end
			if fact.code == "TeardownFailure" and fact.firstRepetition == nil then
				hasPrestartTeardownFailure = true
			end
		elseif fact.code == "SetupFailure" then
			hasSetupFailure = true
		elseif fact.code == "TimingExclusionViolation" then
				timingExclusionFacts[fact.discriminator.value] = true
			end
			if fact.code == "PayloadMismatch" then
				local maximumFixture = if selection.kind == "Workload"
					then checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, checkedMultiply((caseDefinition :: EventV1.Workload).senderCount, (caseDefinition :: EventV1.Workload).messagesPerFrame))
					else (caseDefinition :: EventV1.Probe).measuredSamples
				if fact.fixtureIndex > maximumFixture or not validMismatchFact(selection, fact) then return false end
				if fact.mismatch.pathKind ~= "Root" and fact.mismatch.fieldIndex > #EventV1.payloads[selection.payloadId].fields then return false end
				local repetition = evidence.repetitions[fact.firstRepetition]
				local localMismatch = if selection.kind == "SeparateProbe"
					then (if server then repetition.probeRequestsMismatch else repetition.probeMismatch)
					else repetition.mismatch
				if localMismatch == 0 then return false end
			end
		end
		if not deepEqual(evidence.failureFacts, copyFailureArray(evidence.failureFacts)) then return false end
		if (factTotals.DuplicateDelivery or 0) ~= totals.duplicate
			or (factTotals.UnexpectedDelivery or 0) ~= totals.unexpected
			or (factTotals.OutOfOrderDelivery or 0) ~= totals.outOfOrder
			or (factTotals.PayloadMismatch or 0) ~= totals.mismatch
			or (factTotals.StaleCallback or 0) ~= totals.staleCallbacks
		then return false end
		if firstOverflowRepetition == nil then
			if (factTotals.DeliveryObservationLimitExceeded or 0) ~= 0 then return false end
		else
			if (factTotals.DeliveryObservationLimitExceeded or 0) ~= 1 then return false end
			for _, fact in evidence.failureFacts do
				if fact.code == "DeliveryObservationLimitExceeded" and fact.firstRepetition ~= firstOverflowRepetition then
					return false
				end
			end
		end
		if hasInputMutation then
			if started > 0 then
				local current: any = evidence.repetitions[started]
				local acceptedOperation = if selection.kind == "SeparateProbe"
					then (if server then current.probeResponsesSubmitted > 0 else current.probeSubmitted > 0)
					else current.submitted > 0
				if started ~= completed + 1 or current.completed or not acceptedOperation then return false end
			end
		end
		if firstOnlyEndpoint and not hasSubmitFailure and not hasInputMutation then return false end
		if hasPrestartTeardownFailure and not hasSetupFailure and not hasInputMutation then return false end
		for _, exclusion in { "setup", "warmup", "quiescence" } do
			local confirmed = (conformance :: any)[exclusion .. "Excluded"]
			if (confirmed == false) ~= (timingExclusionFacts[exclusion] == true) then return false end
		end
		if not conformance.resultExtractionExcluded then return false end
		return true
	end

	local function snapshot(
		participantSnapshots: { ParticipantSnapshot }
	): { kind: "Snapshot", value: CaseSnapshot } | { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
		if stopped ~= nil then
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		if frozenSnapshot ~= nil then
			local result = { kind = "Snapshot", value = frozenSnapshot }
			table.freeze(result)
			return result
		end
		if phase == "Running" or phase == "Frozen" then
			fail(STATE_ERROR)
		end
		if finalOnlyEvidence and completed < scheduled then
			stopped = termination("FinalEvidenceUnrepresentable", "Execution")
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		local expectedParticipants = selection.clientProcessCount + 1
		if denseLength(participantSnapshots, expectedParticipants) ~= expectedParticipants then
			fail(CONFIG_ERROR)
		end
		local copiedParticipants = table.create(expectedParticipants)
		local aggregateReceived = 0
		local overflow = false
		local anyClockFailed = false
		local repetitionFailureParticipants = {
			IsolationFailure = 0,
			SubmitFailure = 0,
			TeardownFailure = 0,
		}
		local groupSet: { [string]: boolean } = {}
		local extraCompletedParticipants = 0
		local inputMutationSenders = 0
		local snapshotSeen: { [table]: boolean } = {}
		for _, fact in failureOrder do groupSet[failureKey(fact)] = true end
		local groupCount = #failureOrder
		for index, participantSnapshot in participantSnapshots do
			if not exactPlain(participantSnapshot, { participant = true, evidence = true }, 2) then
				fail(CONFIG_ERROR)
			end
			local expectedParticipant: SessionOwner.ParticipantRef = if index == 1
				then ({ role = "Server" } :: any)
				else ({ role = if selection.kind == "SeparateProbe" then "ProbeClient" else "Client", index = index - 1 } :: any)
			local participantValid = pcall(validateParticipant, selection, participantSnapshot.participant)
			if not participantValid
				or not participantEqual(participantSnapshot.participant, expectedParticipant)
				or not validateEvidence(expectedParticipant, participantSnapshot.evidence, snapshotSeen)
			then
				fail(CONFIG_ERROR)
			end
			for _, repetition in participantSnapshot.evidence.repetitions do
				aggregateReceived += repetition.received
				overflow = overflow or repetition.observationOverflow
			end
			if started == completed + 1 then
				local current = participantSnapshot.evidence.repetitions[started]
				if current ~= nil and current.completed then
					if not isReceiver(selection, expectedParticipant) then
						stopped = termination("FinalEvidenceUnrepresentable", "Execution")
						local result = { kind = "Terminated", termination = stopped }
						table.freeze(result)
						return result
					end
					extraCompletedParticipants += 1
				end
			end
			anyClockFailed = anyClockFailed or not participantSnapshot.evidence.conformance.clockProofPassed
			local participantRepetitionFailures: { [string]: boolean } = {}
			for _, fact in participantSnapshot.evidence.failureFacts do
				if fact.code == "InputMutation" then inputMutationSenders += 1 end
				if repetitionFailureParticipants[fact.code] ~= nil then
					participantRepetitionFailures[fact.code] = true
				end
				local key = failureKey(fact)
				if not groupSet[key] then
					groupSet[key] = true
					groupCount += 1
					if groupCount > MAX_FAILURE_GROUPS then
						stopped = termination("FinalEvidenceUnrepresentable", "Execution")
						local result = { kind = "Terminated", termination = stopped }
						table.freeze(result)
						return result
					end
				end
			end
			for code in participantRepetitionFailures do
				repetitionFailureParticipants[code] += 1
			end
			local copied: ParticipantSnapshot = {
				participant = copyParticipant(expectedParticipant),
				evidence = copyDeep(participantSnapshot.evidence),
			}
			deepFreeze(copied)
			copiedParticipants[index] = copied
		end
		if extraCompletedParticipants > 0 and inputMutationSenders == 0 then
			stopped = termination("FinalEvidenceUnrepresentable", "Execution")
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		for _, participantCount in repetitionFailureParticipants do
			if participantCount > 1 then
				stopped = termination("FinalEvidenceUnrepresentable", "Execution")
				local result = { kind = "Terminated", termination = stopped }
				table.freeze(result)
				return result
			end
		end
		if phase == "Aborted" and groupCount == 0 then
			stopped = termination("FinalEvidenceUnrepresentable", "Execution")
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		local hasClockFailure = failureGroups.ClockProofFailure ~= nil
		if anyClockFailed and not hasClockFailure then
			if not appendFailure(failureGroups, failureOrder, { code = "ClockProofFailure", occurrences = 1 }) then
				stopped = termination("FinalEvidenceUnrepresentable", "Execution")
				local result = { kind = "Terminated", termination = stopped }
				table.freeze(result)
				return result
			end
		elseif hasClockFailure and not anyClockFailed then
			fail(CONFIG_ERROR)
		end
		if selection.kind == "Workload" and selection.audience == "Broadcast" and overflow then
			local workload = caseDefinition :: EventV1.Workload
			local expected = checkedMultiply(
				checkedMultiply(scheduled, checkedMultiply(workload.senderCount, checkedMultiply(workload.measuredFrames, workload.messagesPerFrame))),
				selection.recipientCount
			)
			if aggregateReceived ~= checkedMultiply(4, expected) then
				stopped = termination("DistributedOverflowUnrepresentable", "Execution")
				local result = { kind = "Terminated", termination = stopped }
				table.freeze(result)
				return result
			end
		end
		deepFreeze(copiedParticipants)
		local coordinator: CoordinatorEvidenceV1 = {
			scheduledRepetitions = scheduled,
			startedRepetitions = started,
			completedRepetitions = completed,
			finalOnlyEvidence = finalOnlyEvidence,
			failureFacts = copyFailureArray(failureOrder),
		}
		deepFreeze(coordinator)
		local value: CaseSnapshot = {
			version = 1,
			selection = selection,
			coordinator = coordinator,
			participants = copiedParticipants,
		}
		deepFreeze(value)
		frozenSnapshot = value
		phase = "Frozen"
		local result = { kind = "Snapshot", value = value }
		table.freeze(result)
		return result
	end

	local state: CaseState = {
		selection = selection,
		caseDefinition = caseDefinition,
		acceptSession = acceptSession,
		transition = transition,
		startDeadline = startDeadline,
		checkDeadline = checkDeadline,
		clearDeadline = clearDeadline,
		recordFailure = recordFailure,
		terminate = terminate,
		status = function()
			return caseStatus(phase, stopped, scheduled, started, completed)
		end,
		snapshot = snapshot,
	}
	table.freeze(state)
	return state
end

local function newRemoteRepetition(index: number): ParticipantRepetitionEvidenceV1
	return {
		repetitionIndex = index,
		started = false,
		completed = false,
		submitted = 0,
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
	}
end

local function newServerRepetition(index: number): ServerRepetitionEvidenceV1
	return {
		repetitionIndex = index,
		started = false,
		completed = false,
		submitted = 0,
		received = 0,
		correct = 0,
		mismatch = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		staleCallbacks = 0,
		observationOverflow = false,
		probeRequestsReceived = 0,
		probeRequestsCorrect = 0,
		probeRequestsMismatch = 0,
		probeResponsesSubmitted = 0,
	}
end

local function fieldIndex(payloadId: string, path: string): (number?, "X" | "Y" | "Z"?)
	local payload = EventV1.payloads[payloadId]
	for index, field in payload.fields do
		if path == field.name then
			return index, nil
		end
		for _, component in { "X", "Y", "Z" } do
			if path == field.name .. "." .. component then
				return index, component :: any
			end
		end
	end
	return nil, nil
end

local function sanitizeMismatch(payloadId: string, mismatch: PayloadComparator.Mismatch): LocalMismatchFactV1
	if mismatch.reason == "WrongContainerType" or mismatch.reason == "ExtraField" then
		return { pathKind = "Root" }
	elseif mismatch.reason == "ArityMismatch" then
		if not isSafeInteger(mismatch.actual) then
			fail(STATE_ERROR)
		end
		return { pathKind = "Root", actual = mismatch.actual :: number }
	end
	local index, component = fieldIndex(payloadId, mismatch.path)
	if index == nil then
		fail(STATE_ERROR)
	end
	local includeActual = mismatch.reason ~= "MissingField"
		and mismatch.reason ~= "NonFinite"
		and (type(mismatch.actual) == "boolean" or isFinite(mismatch.actual))
	if component ~= nil then
		local value: LocalMismatchFactV1 = {
			pathKind = "VectorComponent",
			fieldIndex = index,
			component = component,
		}
		if includeActual and type(mismatch.actual) == "number" then
			(value :: any).actual = mismatch.actual
		end
		return value
	end
	local value: LocalMismatchFactV1 = { pathKind = "Field", fieldIndex = index }
	if includeActual then
		(value :: any).actual = mismatch.actual
	end
	return value
end

local function validateGate(gate: unknown)
	if type(gate) ~= "table"
		or getmetatable(gate) ~= nil
		or not table.isfrozen(gate)
		or not exactPlain(gate, { bind = true, arm = true, beginTeardownObservation = true, disable = true }, 4)
		or type(rawget(gate :: any, "bind")) ~= "function"
		or type(rawget(gate :: any, "arm")) ~= "function"
		or type(rawget(gate :: any, "beginTeardownObservation")) ~= "function"
		or type(rawget(gate :: any, "disable")) ~= "function"
	then
		fail(CONFIG_ERROR)
	end
end

local function validateTiming(
	timing: unknown,
	selection: AdapterContract.ResolvedSelection,
	participant: SessionOwner.ParticipantRef
)
	if type(timing) ~= "table"
		or getmetatable(timing) ~= nil
		or not table.isfrozen(timing)
		or not exactPlain(timing, {
			participant = true, caseId = true, beginRepetition = true,
			enterExcluded = true, leaveExcluded = true, markLocal = true,
			markShared = true, captureShared = true, resolveShared = true,
			recordClockProof = true, finishRepetition = true, freeze = true,
		}, 12)
		or type(rawget(timing :: any, "participant")) ~= "table"
		or not participantEqual(rawget(timing :: any, "participant"), participant)
		or rawget(timing :: any, "caseId") ~= (if selection.kind == "Workload" then selection.workloadId else selection.probeId)
		or type(rawget(timing :: any, "beginRepetition")) ~= "function"
		or type(rawget(timing :: any, "enterExcluded")) ~= "function"
		or type(rawget(timing :: any, "leaveExcluded")) ~= "function"
		or type(rawget(timing :: any, "markLocal")) ~= "function"
		or type(rawget(timing :: any, "markShared")) ~= "function"
		or type(rawget(timing :: any, "captureShared")) ~= "function"
		or type(rawget(timing :: any, "resolveShared")) ~= "function"
		or type(rawget(timing :: any, "recordClockProof")) ~= "function"
		or type(rawget(timing :: any, "finishRepetition")) ~= "function"
		or type(rawget(timing :: any, "freeze")) ~= "function"
	then
		fail(CONFIG_ERROR)
	end
end

local function validateFixture(
	selection: AdapterContract.ResolvedSelection,
	repetitionIndex: number,
	fixture: Fixtures.FixtureSet | Fixtures.ProbeFixtureSet
)
	if type(fixture) ~= "table" or not table.isfrozen(fixture) or fixture.contractVersion ~= EventV1.version then
		fail(CONFIG_ERROR)
	end
	if selection.kind == "Workload" then
		local workloadFixture = fixture :: Fixtures.FixtureSet
		if workloadFixture.workloadId ~= selection.workloadId
			or workloadFixture.repetitionIndex ~= repetitionIndex
			or not deepEqual(workloadFixture, Fixtures.generate(selection.workloadId, repetitionIndex))
		then
			fail(CONFIG_ERROR)
		end
	else
		local probeFixture = fixture :: Fixtures.ProbeFixtureSet
		if probeFixture.probeId ~= selection.probeId
			or probeFixture.repetitionIndex ~= repetitionIndex
			or not deepEqual(probeFixture, Fixtures.generateProbe(selection.probeId, repetitionIndex))
		then
			fail(CONFIG_ERROR)
		end
	end
end

local function validateSenderTokens<TSender>(
	selection: AdapterContract.ResolvedSelection,
	participant: SessionOwner.ParticipantRef,
	senderTokens: { TSender }?
)
	local required = participant.role == "Server"
		and (selection.kind == "SeparateProbe" or selection.direction == "ClientToServer")
	if not required then
		if senderTokens ~= nil then
			fail(CONFIG_ERROR)
		end
		return
	end
	local expectedCount = if selection.kind == "SeparateProbe" then selection.clientCount else 1
	if denseLength(senderTokens, expectedCount) ~= expectedCount or not table.isfrozen(senderTokens :: any) then
		fail(CONFIG_ERROR)
	end
	for index = 1, expectedCount do
		local token = rawget(senderTokens :: any, index)
		if token == nil or not rawequal(token, token) then
			fail(CONFIG_ERROR)
		end
	end
end

copyCoordinatorFact = function(candidate: CoordinatorFailureFactV1): CoordinatorFailureFactV1
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		fail(CONFIG_ERROR)
	end
	local fact: any = candidate
	local code = rawget(fact, "code")
	local occurrences = rawget(fact, "occurrences")
	if code == "SetupFailure" or code == "ClockProofFailure" then
		if not exactPlain(fact, { code = true, occurrences = true }, 2) or occurrences ~= 1 then
			fail(CONFIG_ERROR)
		end
	elseif code == "Timeout" or code == "Disconnect" then
		if not exactPlain(fact, { code = true, occurrences = true, firstRepetition = true }, 3)
			or not isSafeInteger(occurrences, true)
			or not isSafeInteger(rawget(fact, "firstRepetition"), true)
		then
			fail(CONFIG_ERROR)
		end
	elseif code == "InternalError" then
		local discriminator = rawget(fact, "discriminator")
		if not exactPlain(fact, { code = true, occurrences = true, discriminator = true }, 3)
			or occurrences ~= 1
			or not exactPlain(discriminator, { kind = true, value = true }, 2)
			or rawget(discriminator :: any, "kind") ~= "Stage"
			or ({ Setup = true, Execution = true, Finalize = true })[rawget(discriminator :: any, "value")] ~= true
		then
			fail(CONFIG_ERROR)
		end
	else
		fail(CONFIG_ERROR)
	end
	return copyDeep(candidate)
end

copyParticipantFact = function(candidate: SanitizedFailureFactV1, scheduled: number): SanitizedFailureFactV1
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		fail(CONFIG_ERROR)
	end
	local fact: any = candidate
	local code = rawget(fact, "code")
	local occurrences = rawget(fact, "occurrences")
	if type(code) ~= "string" or rawget(PARTICIPANT_CODES, code) ~= true or not isSafeInteger(occurrences, true) then
		fail(CONFIG_ERROR)
	end
	local first = rawget(fact, "firstRepetition")
	if first ~= nil and (not isSafeInteger(first, true) or first > scheduled) then
		fail(CONFIG_ERROR)
	end
	if code == "PayloadMismatch" then
		local discriminator = rawget(fact, "discriminator")
		local mismatch = rawget(fact, "mismatch")
		if not exactPlain(fact, {
			code = true,
			occurrences = true,
			discriminator = true,
			firstRepetition = true,
			fixtureIndex = true,
			mismatch = true,
		}, 6)
			or not exactPlain(discriminator, { kind = true, value = true }, 2)
			or rawget(discriminator :: any, "kind") ~= "MismatchReason"
			or rawget(REASON_ORDER, rawget(discriminator :: any, "value")) == nil
			or not isSafeInteger(first, true)
			or not isSafeInteger(rawget(fact, "fixtureIndex"), true)
			or type(mismatch) ~= "table"
		then
			fail(CONFIG_ERROR)
		end
		local reason = rawget(discriminator :: any, "value")
		local pathKind = rawget(mismatch :: any, "pathKind")
		local actual = rawget(mismatch :: any, "actual")
		if pathKind == "Root" then
			if reason == "ArityMismatch" then
				if not exactPlain(mismatch, { pathKind = true, actual = true }, 2) or not isSafeInteger(actual) then fail(CONFIG_ERROR) end
			elseif reason == "WrongContainerType" or reason == "ExtraField" then
				if not exactPlain(mismatch, { pathKind = true }, 1) then fail(CONFIG_ERROR) end
			else fail(CONFIG_ERROR) end
		elseif pathKind == "Field" then
			local hasActual = actual ~= nil
			if not isSafeInteger(rawget(mismatch :: any, "fieldIndex"), true)
				or not exactPlain(mismatch, if hasActual
					then { pathKind = true, fieldIndex = true, actual = true }
					else { pathKind = true, fieldIndex = true }, if hasActual then 3 else 2)
			then fail(CONFIG_ERROR) end
			if reason == "MissingField" or reason == "NonFinite" then
				if hasActual then fail(CONFIG_ERROR) end
			elseif reason == "WrongType" then
				if hasActual and type(actual) ~= "boolean" and not isFinite(actual) then fail(CONFIG_ERROR) end
			elseif reason == "NonInteger" or reason == "OutOfRange" or reason == "NotFloat32" then
				if not hasActual or not isFinite(actual) then fail(CONFIG_ERROR) end
			elseif reason == "ValueMismatch" then
				if not hasActual
					or (type(actual) ~= "boolean" and not isFinite(actual))
				then fail(CONFIG_ERROR) end
			else fail(CONFIG_ERROR) end
		elseif pathKind == "VectorComponent" then
			local hasActual = actual ~= nil
			if not isSafeInteger(rawget(mismatch :: any, "fieldIndex"), true)
				or ({ X = true, Y = true, Z = true })[rawget(mismatch :: any, "component")] ~= true
				or not exactPlain(mismatch, if hasActual
					then { pathKind = true, fieldIndex = true, component = true, actual = true }
					else { pathKind = true, fieldIndex = true, component = true }, if hasActual then 4 else 3)
			then fail(CONFIG_ERROR) end
			if reason == "NonFinite" then
				if hasActual then fail(CONFIG_ERROR) end
			elseif reason == "OutOfRange" or reason == "NotFloat32" or reason == "ValueMismatch" then
				if not hasActual or not isFinite(actual) then fail(CONFIG_ERROR) end
			else fail(CONFIG_ERROR) end
		else fail(CONFIG_ERROR) end
	elseif code == "TimingExclusionViolation" then
		local discriminator = rawget(fact, "discriminator")
		if occurrences ~= 1
			or not exactPlain(fact, { code = true, occurrences = true, discriminator = true }, 3)
			or not exactPlain(discriminator, { kind = true, value = true }, 2)
			or rawget(discriminator :: any, "kind") ~= "TimingExclusion"
			or ({ setup = true, warmup = true, quiescence = true })[rawget(discriminator :: any, "value")] ~= true
		then fail(CONFIG_ERROR) end
	elseif code == "InternalError" then
		local discriminator = rawget(fact, "discriminator")
		if occurrences ~= 1
			or not exactPlain(fact, { code = true, occurrences = true, discriminator = true }, 3)
			or not exactPlain(discriminator, { kind = true, value = true }, 2)
			or rawget(discriminator :: any, "kind") ~= "Stage"
			or ({ Setup = true, Execution = true, Finalize = true })[rawget(discriminator :: any, "value")] ~= true
		then fail(CONFIG_ERROR) end
	elseif code == "SetupFailure" then
		if occurrences ~= 1 or first ~= nil or not exactPlain(fact, { code = true, occurrences = true }, 2) then
			fail(CONFIG_ERROR)
		end
	elseif code == "InputMutation" then
		if occurrences ~= 1 or first ~= nil or not exactPlain(fact, { code = true, occurrences = true }, 2) then
			fail(CONFIG_ERROR)
		end
	elseif code == "TeardownFailure" then
		if not exactPlain(fact, if first == nil
			then { code = true, occurrences = true }
			else { code = true, occurrences = true, firstRepetition = true }, if first == nil then 2 else 3)
		then fail(CONFIG_ERROR) end
		if first == nil then
			if occurrences ~= 1 then
				fail(CONFIG_ERROR)
			end
		end
	elseif first == nil then
		fail(CONFIG_ERROR)
	elseif not exactPlain(fact, { code = true, occurrences = true, firstRepetition = true }, 3) then
		fail(CONFIG_ERROR)
	elseif (code == "ControlTrafficDuringMeasuredFrames" or code == "DeliveryObservationLimitExceeded") and occurrences ~= 1 then
		fail(CONFIG_ERROR)
	end
	return copyDeep(candidate)
end

local function newParticipant<TSender>(
	selection: AdapterContract.ResolvedSelection,
	participantCandidate: SessionOwner.ParticipantRef
): ParticipantState<TSender>
	if not canonicalSelection(selection) then
		fail(CONFIG_ERROR)
	end
	validateParticipant(selection, participantCandidate)
	local participant = copyParticipant(participantCandidate)
	local caseDefinition = resolveDefinition(selection)
	local scheduled = caseDefinition.repetitions
	local serverRole = participant.role == "Server"
	local repetitions: { any } = table.create(scheduled)
	for index = 1, scheduled do
		repetitions[index] = if serverRole then newServerRepetition(index) else newRemoteRepetition(index)
	end

	local failureGroups: { [string]: any } = {}
	local failureOrder: { any } = {}
	local timingRecorder: TimingRecorder.Recorder? = nil
	local gates: { DeliveryRouter.SinkGate } = {}
	local frozenEvidence: (ParticipantEvidenceV1 | ServerEvidenceV1)? = nil
	local frozenResult: any = nil
	local stopped: HarnessTerminationV1.HarnessTerminationV1? = nil
	local lastGeneration = 0
	local activeObservationCount = 0
	local rejectedCallbackCount = 0
	local receiving = isReceiver(selection, participant)
	local sending = isSender(selection, participant)
	local measuredPerRepetition = if selection.kind == "Workload"
		then checkedMultiply(caseDefinition.measuredFrames, checkedMultiply(caseDefinition.senderCount, caseDefinition.messagesPerFrame))
		else caseDefinition.measuredSamples
	local observationLimit = checkedMultiply(4, checkedMultiply(scheduled, measuredPerRepetition))
	local rejectedCallbackLimit = observationLimit
	local measuredEntryLimit = checkedAdd(observationLimit, rejectedCallbackLimit)
	local warmupPerRepetition = if selection.kind == "Workload"
		then checkedMultiply(caseDefinition.senderCount, checkedMultiply(caseDefinition.warmupFrames, caseDefinition.messagesPerFrame))
		else caseDefinition.warmupSamples
	local warmupObservationLimitPerRepetition = checkedMultiply(4, warmupPerRepetition)
	local warmupEntryLimitPerRepetition = checkedAdd(warmupObservationLimitPerRepetition, warmupObservationLimitPerRepetition)
	local universalEntryLimit = checkedAdd(measuredEntryLimit, checkedMultiply(scheduled, warmupEntryLimitPerRepetition))
	local callbackEntries = 0

	local function latchTermination(value: HarnessTerminationV1.HarnessTerminationV1): HarnessTerminationV1.HarnessTerminationV1
		if stopped == nil then
			stopped = value
		end
		return stopped :: HarnessTerminationV1.HarnessTerminationV1
	end

	local function recordFailureInternal(factCandidate: SanitizedFailureFactV1, allowInputMutation: boolean): any
		if frozenEvidence ~= nil then
			fail(STATE_ERROR)
		end
		if stopped ~= nil then
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		local fact = copyParticipantFact(factCandidate, scheduled)
		if fact.code == "InputMutation" and not allowInputMutation then fail(CONFIG_ERROR) end
		if fact.code == "PayloadMismatch" then
			local maximumFixture = if selection.kind == "Workload"
				then checkedMultiply((caseDefinition :: EventV1.Workload).measuredFrames, checkedMultiply((caseDefinition :: EventV1.Workload).senderCount, (caseDefinition :: EventV1.Workload).messagesPerFrame))
				else (caseDefinition :: EventV1.Probe).measuredSamples
			if fact.fixtureIndex > maximumFixture
				or (fact.mismatch.pathKind ~= "Root" and fact.mismatch.fieldIndex > #EventV1.payloads[selection.payloadId].fields)
			then fail(CONFIG_ERROR) end
		end
		if not appendFailure(failureGroups, failureOrder, fact) then
			local result = { kind = "Terminated", termination = latchTermination(termination("FinalEvidenceUnrepresentable", "Execution")) }
			table.freeze(result)
			return result
		end
		local result = { kind = "Recorded" }
		table.freeze(result)
		return result
	end

	local function recordFailure(factCandidate: SanitizedFailureFactV1): any
		return recordFailureInternal(factCandidate, false)
	end

	local function recordInternal(stage: "Setup" | "Execution" | "Finalize")
		if stopped == nil then
			recordFailure({
				code = "InternalError",
				occurrences = 1,
				discriminator = { kind = "Stage", value = stage },
			})
		end
	end

	local function beginGeneration(
		repetitionIndex: number,
		fixture: Fixtures.FixtureSet | Fixtures.ProbeFixtureSet,
		gate: DeliveryRouter.SinkGate,
		timing: TimingRecorder.Recorder,
		senderTokens: { TSender }?
	): GenerationStatePort<TSender>
		if frozenEvidence ~= nil or stopped ~= nil or repetitionIndex ~= lastGeneration + 1 or repetitionIndex > scheduled then
			fail(STATE_ERROR)
		end
		validateFixture(selection, repetitionIndex, fixture)
		validateGate(gate)
		validateTiming(timing, selection, participant)
		validateSenderTokens(selection, participant, senderTokens)
		if timingRecorder == nil then
			timingRecorder = timing
		elseif not rawequal(timingRecorder, timing) then
			fail(CONFIG_ERROR)
		end
		lastGeneration = repetitionIndex
		gates[repetitionIndex] = gate

		local evidence: any = repetitions[repetitionIndex]
		local phase: GenerationPhase = "Prepared"
		local quietFrames = 0
		local generationStopped: HarnessTerminationV1.HarnessTerminationV1? = nil
		local warmupDirty = false
		local warmupObservationCount = 0
		local warmupRejectedCallbackCount = 0
		local warmupProbeReceived = 0
		local warmupOperations = 0
		local measuredOperations = 0
		local operationStarted: { [number]: boolean } = {}
		local operationReturned: { [number]: boolean } = {}
		local activeLedger: DeliveryLedger.DeliveryLedger? = nil
		local probeSeen: { [number]: boolean } = {}
		local currentFixture: any = fixture
		local pendingWarmupLedger: DeliveryLedger.DeliveryLedger? = nil
		local measuredLedger: DeliveryLedger.DeliveryLedger? = nil
		local timingFinished = false
		local warmupExpected = if selection.kind == "Workload"
			then #((fixture :: Fixtures.FixtureSet).warmup)
			else #((fixture :: Fixtures.ProbeFixtureSet).warmup)
		local warmupObservationLimit = checkedMultiply(4, warmupExpected)

		if selection.kind == "Workload" and receiving then
			local workloadFixture = fixture :: Fixtures.FixtureSet
			pendingWarmupLedger = DeliveryLedger.new(workloadFixture.warmup)
			measuredLedger = DeliveryLedger.new(workloadFixture.measured)
		end

		local function generationTermination(value: HarnessTerminationV1.HarnessTerminationV1): GenerationStatus
			generationStopped = latchTermination(value)
			pcall(gate.disable)
			return stateStatus(phase, quietFrames, generationStopped)
		end

		local function finishTiming(completedValue: boolean)
			if not timingFinished then
				timing.finishRepetition(completedValue)
				timingFinished = true
			end
		end

		local function failGenerationInternal(): DeliveryAction
			recordInternal("Execution")
			phase = "Aborting"
			if evidence.started then pcall(finishTiming, false) end
			pcall(gate.disable)
			return NONE
		end

		local function updateLedgerEvidence(ledger: DeliveryLedger.DeliveryLedger): any
			local _, _, snapshot = ledger:verify()
			evidence.received = snapshot.received
			evidence.correct = snapshot.correct
			evidence.mismatch = snapshot.mismatch
			evidence.duplicate = snapshot.duplicate
			evidence.unexpected = snapshot.unexpected
			evidence.outOfOrder = snapshot.outOfOrder
			return snapshot
		end

		local function markMismatch(mismatch: PayloadComparator.Mismatch, fixtureIndex: number)
			recordFailure({
				code = "PayloadMismatch",
				occurrences = 1,
				discriminator = { kind = "MismatchReason", value = mismatch.reason },
				firstRepetition = repetitionIndex,
				fixtureIndex = fixtureIndex,
				mismatch = sanitizeMismatch(selection.payloadId, mismatch),
			})
		end

		local function compareDelivery(expected: any, delivery: any): (boolean, PayloadComparator.Mismatch?)
			if delivery.kind == "Record" then
				return PayloadComparator.compareRecord(selection.payloadId, expected.expected, rawget(delivery, "value"))
		end
		return PayloadComparator.compareCapturedPositional(
				selection.payloadId,
				expected.expected,
				delivery.values,
				delivery.count
			)
		end

		local function deliverySequence(delivery: any): number?
			local sequenceField = EventV1.payloads[selection.payloadId].fields[1]
			if sequenceField.name ~= "sequence" then
				fail(STATE_ERROR)
			end
			local value
			if delivery.kind == "Record" then
				local record = rawget(delivery, "value")
				if type(record) ~= "table" then
					return nil
				end
				value = rawget(record, "sequence")
			else
				value = rawget(delivery.values, 1)
			end
			return if isFinite(value) and value % 1 == 0 and value >= 0 and value <= UINT32_MAX then value else nil
		end

		local function preflightDelivery(argumentCount: number, delivery: unknown, metadata: unknown): any?
			if argumentCount ~= 2 or type(delivery) ~= "table" or getmetatable(delivery) ~= nil then
				return nil
			end
			local envelope: any = delivery
			if rawget(envelope, "kind") == "Record" then
				local keyCount = if rawget(envelope, "value") == nil then 1 else 2
				if not exactPlain(envelope, { kind = true, value = true }, keyCount) then
					return nil
				end
			elseif rawget(envelope, "kind") == "Positional" then
				if not exactPlain(envelope, { kind = true, values = true, count = true }, 3)
					or not isSafeInteger(rawget(envelope, "count"))
					or not boundedNumericStorage(rawget(envelope, "values"), #EventV1.payloads[selection.payloadId].fields + 1)
				then
					return nil
				end
			else
				return nil
			end
			if type(metadata) ~= "table" or getmetatable(metadata) ~= nil then
				return nil
			end
			local metadataValue: any = metadata
			if participant.role == "Server" then
				if not exactPlain(metadataValue, { kind = true, sender = true }, 2)
					or rawget(metadataValue, "kind") ~= "ClientToServer"
				then
					return nil
				end
			else
				if not exactPlain(metadataValue, { kind = true }, 1)
					or rawget(metadataValue, "kind") ~= "ServerToClient"
				then
					return nil
				end
			end
			return envelope
		end

		local function activeExpected(fixtureItems: { any }, sequence: number): (any?, number?)
			local first = rawget(fixtureItems, 1)
			if first == nil then
				return nil, nil
			end
			-- validateFixture has already proved this is the canonical generated
			-- fixture, whose phase-local sequences are contiguous.
			local fixtureIndex = sequence - first.sequence + 1
			local item = rawget(fixtureItems, fixtureIndex)
			if item ~= nil and item.sequence == sequence then
				return item, fixtureIndex
			end
			return nil, nil
		end

		local function internalObserve(argumentCount: number, delivery: unknown, metadata: unknown): DeliveryAction
			if generationStopped ~= nil or stopped ~= nil then
				return NONE
			end
			if not receiving then
				generationTermination(termination("IngressLimitExceeded", if phase == "Prepared" then "Setup" else "Execution"))
				return NONE
			end
			if phase == "Verified" then
				quietFrames = 0
			end
			callbackEntries = checkedAdd(callbackEntries, 1)
			if callbackEntries > universalEntryLimit then
				generationTermination(termination("FinalEvidenceUnrepresentable", "Execution"))
				return NONE
			end
			local activePhase = phase == "Warmup" or phase == "Measured" or phase == "Draining" or phase == "Verified"
			if not activePhase then
				local warmupWindow = phase == "WarmupDrained" or phase == "ControlQuiet" or phase == "ArmedMeasured"
				if warmupWindow then
					warmupRejectedCallbackCount = checkedAdd(warmupRejectedCallbackCount, 1)
					warmupDirty = true
					if warmupRejectedCallbackCount > warmupObservationLimit then
						generationTermination(termination("WarmupEvidenceRejected", "Execution"))
					end
				else
					rejectedCallbackCount = checkedAdd(rejectedCallbackCount, 1)
					if rejectedCallbackCount > rejectedCallbackLimit then
						generationTermination(termination("FinalEvidenceUnrepresentable", "Execution"))
					elseif evidence.started then
						evidence.staleCallbacks = checkedAdd(evidence.staleCallbacks, 1)
						recordFailure({ code = "StaleCallback", occurrences = 1, firstRepetition = repetitionIndex })
					elseif phase ~= "Prepared" then
						generationTermination(termination("FinalEvidenceUnrepresentable", "Execution"))
					end
				end
				if phase == "ControlQuiet" then
					quietFrames = 0
				end
				return NONE
			end
			if phase == "Warmup" then
				warmupObservationCount = checkedAdd(warmupObservationCount, 1)
				if warmupObservationCount > warmupObservationLimit then
					generationTermination(termination("WarmupEvidenceRejected", "Execution"))
					return NONE
				end
			else
				activeObservationCount = checkedAdd(activeObservationCount, 1)
				if activeObservationCount > observationLimit then
					evidence.observationOverflow = true
					recordFailure({ code = "DeliveryObservationLimitExceeded", occurrences = 1, firstRepetition = repetitionIndex })
					phase = "Aborting"
					if evidence.started then pcall(finishTiming, false) end
					pcall(gate.disable)
					return NONE
				end
			end

			local envelope = preflightDelivery(argumentCount, delivery, metadata)
			if envelope == nil then
				return failGenerationInternal()
			end
			if participant.role == "Server" then
				local sender = rawget(metadata :: any, "sender")
				local senderAllowed = false
				for _, expectedSender in senderTokens :: { TSender } do
					if rawequal(sender, expectedSender) then
						senderAllowed = true
						break
					end
				end
				if not senderAllowed then
					if selection.kind == "SeparateProbe" then
						return failGenerationInternal()
					end
					local ledger = activeLedger
					if ledger ~= nil then
						ledger:recordDelivery(nil, nil, false)
						if phase ~= "Warmup" then
							updateLedgerEvidence(ledger)
							recordFailure({ code = "UnexpectedDelivery", occurrences = 1, firstRepetition = repetitionIndex })
						else
							warmupDirty = true
						end
					end
					return NONE
				end
			end

			local sequence = deliverySequence(envelope)
			if sequence == nil then
				if selection.kind == "Workload" and activeLedger ~= nil then
					activeLedger:recordDelivery(nil, nil, false)
					if phase == "Warmup" then
						warmupDirty = true
					else
						updateLedgerEvidence(activeLedger)
						recordFailure({ code = "UnexpectedDelivery", occurrences = 1, firstRepetition = repetitionIndex })
					end
				else
					return failGenerationInternal()
				end
				return NONE
			end

			local items = if selection.kind == "Workload"
				then (if phase == "Warmup" then (currentFixture :: Fixtures.FixtureSet).warmup else (currentFixture :: Fixtures.FixtureSet).measured)
				else (if phase == "Warmup" then (currentFixture :: Fixtures.ProbeFixtureSet).warmup else (currentFixture :: Fixtures.ProbeFixtureSet).measured)
			local expected, fixtureIndex = activeExpected(items, sequence)
			if expected == nil then
				if selection.kind == "Workload" and activeLedger ~= nil then
					activeLedger:recordDelivery(selection.payloadId, sequence, false)
					if phase == "Warmup" then
						warmupDirty = true
					else
						updateLedgerEvidence(activeLedger)
						recordFailure({ code = "UnexpectedDelivery", occurrences = 1, firstRepetition = repetitionIndex })
					end
				end
				return NONE
			end

			if selection.kind == "SeparateProbe" and probeSeen[sequence] then
				if phase ~= "Warmup" then
					evidence.staleCallbacks = checkedAdd(evidence.staleCallbacks, 1)
					recordFailure({ code = "StaleCallback", occurrences = 1, firstRepetition = repetitionIndex })
				else
					warmupDirty = true
				end
				return NONE
			end

			local candidate = nil
			local timingActive = phase == "Measured" or phase == "Draining"
			if selection.kind == "Workload" and timingActive then
				candidate = timing.captureShared("FinalExpectedDeliveryReceived")
			elseif selection.kind == "SeparateProbe" and participant.role == "ProbeClient" and timingActive then
				timing.markLocal("RoundTripEchoReceived")
			end
			local matches, mismatch = compareDelivery(expected, envelope)

			if selection.kind == "Workload" then
				local ledger = activeLedger :: DeliveryLedger.DeliveryLedger
				local previousOutOfOrder = evidence.outOfOrder
				local deliveryStatus, firstReceiptsCompletedNow = ledger:recordDelivery(selection.payloadId, sequence, matches)
				if candidate ~= nil then
					timing.resolveShared(candidate, firstReceiptsCompletedNow)
				end
				if phase == "Warmup" then
					local clean = ledger:verify()
					if deliveryStatus ~= "Expected" or not matches then
						warmupDirty = true
					end
					if clean and (not sending or warmupOperations == #((currentFixture :: Fixtures.FixtureSet).warmup)) then
						phase = "WarmupDrained"
					end
					return NONE
				end
				local ledgerSnapshot = updateLedgerEvidence(ledger)
				if firstReceiptsCompletedNow and timingActive then
					timing.markShared("FinalExpectedDeliveryVerified")
					if phase == "Draining" then
						phase = "Verified"
						quietFrames = 0
						evidence.completed = true
						finishTiming(true)
					end
				end
				if deliveryStatus == "Duplicate" then
					recordFailure({ code = "DuplicateDelivery", occurrences = 1, firstRepetition = repetitionIndex })
				elseif deliveryStatus == "Unexpected" then
					recordFailure({ code = "UnexpectedDelivery", occurrences = 1, firstRepetition = repetitionIndex })
				elseif deliveryStatus == "Expected" then
					if ledgerSnapshot.outOfOrder > previousOutOfOrder then
						recordFailure({ code = "OutOfOrderDelivery", occurrences = 1, firstRepetition = repetitionIndex })
					end
					if not matches and mismatch ~= nil then
						markMismatch(mismatch, fixtureIndex :: number)
					end
				end
				return NONE
			end

			probeSeen[sequence] = true
			if phase == "Warmup" then
				warmupProbeReceived += 1
				if not matches then
					warmupDirty = true
					generationTermination(termination("WarmupEvidenceRejected", "Execution"))
					return NONE
				end
				if warmupProbeReceived == #items and warmupOperations == #items then
					phase = "WarmupDrained"
				end
				if participant.role == "Server" and matches then
					return table.freeze({ kind = "ProbeResponse", fixtureIndex = fixtureIndex :: number }) :: any
				elseif participant.role == "ProbeClient" then
					return table.freeze({ kind = "ProbeResponseAccepted", fixtureIndex = fixtureIndex :: number }) :: any
				end
				return NONE
			end
			if participant.role == "Server" then
				evidence.probeRequestsReceived += 1
				if matches then
					evidence.probeRequestsCorrect += 1
				else
					evidence.probeRequestsMismatch += 1
				end
			else
				evidence.probeReceived += 1
				if matches then
					evidence.probeCorrect += 1
				else
					evidence.probeMismatch += 1
				end
			end
			if participant.role == "ProbeClient"
				and (phase == "Measured" or phase == "Draining")
				and evidence.probeReceived == #items
				and evidence.probeSubmitted == #items
			then
				phase = "Verified"
				quietFrames = 0
				evidence.completed = true
				finishTiming(true)
			end
			if not matches and mismatch ~= nil then
				markMismatch(mismatch, fixtureIndex :: number)
			end
			if participant.role == "Server" and matches then
				return table.freeze({ kind = "ProbeResponse", fixtureIndex = fixtureIndex :: number }) :: any
			elseif participant.role == "ProbeClient" then
				return table.freeze({ kind = "ProbeResponseAccepted", fixtureIndex = fixtureIndex :: number }) :: any
			end
			return NONE
		end

		local function observeDelivery(argumentCount: number, delivery: unknown, metadata: unknown): DeliveryAction
			local call = table.pack(pcall(internalObserve, argumentCount, delivery, metadata))
			if call[1] ~= true then
				if call[2] == "BENCHMARK_CLOCK_E_VALUE" then
					phase = "Aborting"
					if evidence.started then pcall(finishTiming, false) end
					return CLOCK_PROOF_FAILED
				end
				return failGenerationInternal()
			end
			return call[2]
		end

		local function staleHandler()
			if stopped ~= nil or generationStopped ~= nil then
				return
			end
			callbackEntries = checkedAdd(callbackEntries, 1)
			rejectedCallbackCount = checkedAdd(rejectedCallbackCount, 1)
			if callbackEntries > universalEntryLimit or rejectedCallbackCount > rejectedCallbackLimit then
				generationTermination(termination("FinalEvidenceUnrepresentable", "Execution"))
				return
			end
			if evidence.started then
				evidence.staleCallbacks = checkedAdd(evidence.staleCallbacks, 1)
				recordFailure({ code = "StaleCallback", occurrences = 1, firstRepetition = repetitionIndex })
			else
				generationTermination(termination("FinalEvidenceUnrepresentable", "Execution"))
			end
		end

		local function operationCount(phaseValue: "Warmup" | "Measured"): number
			if selection.kind == "Workload" then
				local workloadFixture = currentFixture :: Fixtures.FixtureSet
				local items = if phaseValue == "Warmup" then workloadFixture.warmup else workloadFixture.measured
				return #items / (caseDefinition :: EventV1.Workload).senderCount
			end
			local probeFixture = currentFixture :: Fixtures.ProbeFixtureSet
			return #(if phaseValue == "Warmup" then probeFixture.warmup else probeFixture.measured)
		end

		local function validOperationFixture(phaseValue: "Warmup" | "Measured", fixtureIndex: number): boolean
			if selection.kind == "SeparateProbe" then
				return fixtureIndex <= operationCount(phaseValue)
			end
			local workloadFixture = currentFixture :: Fixtures.FixtureSet
			local items = if phaseValue == "Warmup" then workloadFixture.warmup else workloadFixture.measured
			local item = items[fixtureIndex]
			if item == nil then
				return false
			end
			local senderIndex = if participant.role == "Server" then 1 else (participant :: any).index
			return item.senderIndex == senderIndex
		end

		local function transition(event: GenerationEvent): GenerationStatus
			if generationStopped ~= nil or stopped ~= nil then
				return stateStatus(phase, quietFrames, generationStopped or stopped)
			end
			if not validGenerationEvent(event) then
				fail(STATE_ERROR)
			end
			if event.kind == "AbortBeforeMeasured" then
				if phase ~= "Prepared"
					and phase ~= "Warmup"
					and phase ~= "WarmupDrained"
					and phase ~= "ControlQuiet"
					and phase ~= "ArmedMeasured"
				then
					fail(STATE_ERROR)
				end
				phase = "Aborting"
			elseif event.kind == "BeginWarmup" then
				if phase ~= "Prepared" then fail(STATE_ERROR) end
				phase = "Warmup"
				activeLedger = pendingWarmupLedger
			elseif event.kind == "PostSimulation" then
				if phase == "WarmupDrained" then
					phase = "ControlQuiet"
					quietFrames = 1
				elseif phase == "ControlQuiet" or phase == "Verified" then
					quietFrames = math.min(QUIET_FRAMES, quietFrames + 1)
				elseif phase ~= "Warmup" and phase ~= "Measured" and phase ~= "Draining" then
					fail(STATE_ERROR)
				end
			elseif event.kind == "ArmMeasured" then
				if phase ~= "ControlQuiet"
					or quietFrames ~= QUIET_FRAMES
					or not isFinite(event.startSharedSeconds)
					or event.startSharedSeconds < 0
					or isNegativeZero(event.startSharedSeconds)
				then
					fail(STATE_ERROR)
				end
				if warmupDirty then
					return generationTermination(termination("WarmupEvidenceRejected", "Execution"))
				end
				phase = "ArmedMeasured"
			elseif event.kind == "BeginMeasured" then
				if phase ~= "ArmedMeasured" then fail(STATE_ERROR) end
				timing.beginRepetition(repetitionIndex)
				operationStarted = {}
				operationReturned = {}
				evidence.started = true
				phase = "Measured"
				activeLedger = measuredLedger
			elseif event.kind == "OperationStarted" then
				if phase ~= event.phase or not sending or not validOperationFixture(event.phase, event.fixtureIndex) or operationStarted[event.fixtureIndex] then
					fail(STATE_ERROR)
				end
				operationStarted[event.fixtureIndex] = true
				if event.phase == "Measured" then
					if selection.kind == "SeparateProbe" and participant.role == "ProbeClient" then
						evidence.probeStarted += 1
					end
				end
			elseif event.kind == "OperationReturned" or event.kind == "OperationReturnedWithInputMutation" then
				if phase ~= event.phase or not operationStarted[event.fixtureIndex] or operationReturned[event.fixtureIndex] then
					fail(STATE_ERROR)
				end
				local inputMutated = event.kind == "OperationReturnedWithInputMutation"
				operationReturned[event.fixtureIndex] = true
				if event.phase == "Warmup" then
					warmupOperations += 1
					if not inputMutated then
						local receiptsComplete = not receiving
						if selection.kind == "Workload" and receiving then
							receiptsComplete = (activeLedger :: DeliveryLedger.DeliveryLedger):verify()
						elseif selection.kind == "SeparateProbe" then
							receiptsComplete = warmupProbeReceived == operationCount("Warmup")
						end
						if warmupOperations == operationCount("Warmup") and receiptsComplete then
							phase = "WarmupDrained"
						end
					end
				else
					measuredOperations += 1
					if selection.kind == "SeparateProbe" then
						if participant.role == "ProbeClient" then
							evidence.probeSubmitted += 1
						else
							evidence.probeResponsesSubmitted += 1
						end
					else
						evidence.submitted += 1
					end
				end
				if inputMutated then
					local recorded = recordFailureInternal({ code = "InputMutation", occurrences = 1 }, true)
					if recorded.kind == "Terminated" then
						return generationTermination(recorded.termination)
					end
					phase = "Aborting"
					if event.phase == "Measured" then finishTiming(false) end
				elseif event.phase == "Measured" and selection.kind == "SeparateProbe" then
					local probeComplete = if participant.role == "Server"
						then evidence.probeRequestsReceived == operationCount("Measured")
							and evidence.probeResponsesSubmitted == operationCount("Measured")
						else evidence.probeSubmitted == operationCount("Measured")
							and evidence.probeReceived == operationCount("Measured")
					if (phase == "Measured" or phase == "Draining") and probeComplete then
						phase = "Verified"
						quietFrames = 0
						evidence.completed = true
						finishTiming(true)
					end
				end
			elseif event.kind == "OperationFailed" then
				if phase ~= event.phase or not sending then fail(STATE_ERROR) end
				if event.phase == "Warmup" then
					return generationTermination(termination("WarmupEvidenceRejected", "Execution"))
				end
				recordFailure({ code = "SubmitFailure", occurrences = 1, firstRepetition = repetitionIndex })
				phase = "Aborting"
				finishTiming(false)
			elseif event.kind == "FinishMeasured" then
				if phase ~= "Measured" and phase ~= "Draining" then fail(STATE_ERROR) end
				if event.outcome == "Abort" then
					phase = "Aborting"
					finishTiming(false)
				else
					local complete = true
					if sending and measuredOperations ~= operationCount("Measured") then complete = false end
					if selection.kind == "Workload" and receiving then
						local _, _, ledgerSnapshot = (measuredLedger :: DeliveryLedger.DeliveryLedger):verify()
						complete = ledgerSnapshot.missing == 0
						phase = if complete then "Verified" else "Draining"
					elseif selection.kind == "SeparateProbe" then
						if participant.role == "ProbeClient" then
							complete = evidence.probeReceived == operationCount("Measured")
						else
							complete = evidence.probeRequestsReceived == operationCount("Measured")
						end
						phase = if complete then "Verified" else "Draining"
					else
						phase = if complete then "Verified" else "Aborting"
					end
					if complete then
						quietFrames = 0
						evidence.completed = true
						finishTiming(true)
					elseif phase == "Aborting" then
						finishTiming(false)
					end
				end
			elseif event.kind == "Timeout" then
				if event.scope == "Warmup" then
					if phase ~= "Warmup" and phase ~= "WarmupDrained" and phase ~= "ControlQuiet" and phase ~= "ArmedMeasured" then
						fail(STATE_ERROR)
					end
					return generationTermination(termination("WarmupEvidenceRejected", "Execution"))
				end
				if phase ~= "Measured" and phase ~= "Draining" and phase ~= "Verified" then
					fail(STATE_ERROR)
				end
				if selection.kind ~= "Workload" or phase ~= "Verified" then
					phase = "Aborting"
					if evidence.started then finishTiming(false) end
				end
			elseif event.kind == "AbortAfterLocalCompletion" then
				if phase ~= "Verified" or quietFrames == QUIET_FRAMES then fail(STATE_ERROR) end
				phase = "Aborting"
			elseif event.kind == "BeginTeardown" then
				if phase ~= "Verified" and phase ~= "Aborting" and phase ~= "Draining" then fail(STATE_ERROR) end
				if phase == "Verified" and quietFrames ~= QUIET_FRAMES then fail(STATE_ERROR) end
			elseif event.kind == "FinishTeardown" then
				if phase ~= "Verified" and phase ~= "Aborting" and phase ~= "Draining" then fail(STATE_ERROR) end
				if phase == "Verified" and quietFrames ~= QUIET_FRAMES then fail(STATE_ERROR) end
				if phase == "Draining" and selection.kind == "Workload" and receiving then
					updateLedgerEvidence(measuredLedger :: DeliveryLedger.DeliveryLedger)
					evidence.completed = true
					finishTiming(false)
				end
				if not event.clean then
					if not evidence.started then
						return generationTermination(termination("FinalEvidenceUnrepresentable", "Execution"))
					end
					recordFailure({ code = "TeardownFailure", occurrences = 1, firstRepetition = repetitionIndex })
				end
				phase = "PostTeardownObservation"
			elseif event.kind == "FinishTeardownObservation" then
				if phase ~= "PostTeardownObservation" then fail(STATE_ERROR) end
				phase = "Closed"
			else
				fail(STATE_ERROR)
			end
			return stateStatus(phase, quietFrames, generationStopped)
		end

		local port: GenerationStatePort<TSender> = {
			observeDelivery = observeDelivery,
			staleHandler = staleHandler,
			transition = transition,
			status = function()
				return stateStatus(phase, quietFrames, generationStopped or stopped)
			end,
		}
		table.freeze(port)
		return port
	end

	local function freeze(): any
		if stopped ~= nil then
			for _, gate in gates do pcall(gate.disable) end
			local result = { kind = "Terminated", termination = stopped }
			table.freeze(result)
			return result
		end
		if frozenResult ~= nil then
			return frozenResult
		end
		for _, gate in gates do
			local ok, result = pcall(gate.disable)
			if not ok or result == "PreReadyViolation" then
				local result = { kind = "Terminated", termination = latchTermination(termination("ControlProtocolRejected", "Setup")) }
				table.freeze(result)
				return result
			end
		end

		local measurements: { TimingRecorder.ParticipantMeasurementV1 } = {}
		local endpoints: { TimingRecorder.ParticipantTimingEndpointsV1 } = {}
		local conformance: ParticipantConformanceV1 = {
			setupExcluded = true,
			warmupExcluded = true,
			quiescenceExcluded = true,
			resultExtractionExcluded = true,
			clockProofPassed = true,
		}
		if timingRecorder ~= nil then
			local timingCall = table.pack(pcall((timingRecorder :: TimingRecorder.Recorder).freeze))
			if timingCall[1] ~= true then
				recordInternal("Finalize")
				local result = { kind = "Terminated", termination = latchTermination(termination("FinalizationFailure", "Finalize")) }
				table.freeze(result)
				return result
			end
			local timingEvidence: TimingRecorder.TimingEvidence = timingCall[2]
			for _, measurement in timingEvidence.measurements do table.insert(measurements, copyDeep(measurement)) end
			for _, endpoint in timingEvidence.endpoints do table.insert(endpoints, copyDeep(endpoint)) end
			conformance.setupExcluded = conformance.setupExcluded and timingEvidence.timingExclusionsConfirmed.setup
			conformance.warmupExcluded = conformance.warmupExcluded and timingEvidence.timingExclusionsConfirmed.warmup
			conformance.quiescenceExcluded = conformance.quiescenceExcluded and timingEvidence.timingExclusionsConfirmed.quiescence
			conformance.clockProofPassed = conformance.clockProofPassed and timingEvidence.clockProofPassed
		end
		for _, exclusion in { "setup", "warmup", "quiescence" } do
			if not (conformance :: any)[exclusion .. "Excluded"] then
				local recorded = recordFailure({
					code = "TimingExclusionViolation",
					occurrences = 1,
					discriminator = { kind = "TimingExclusion", value = exclusion :: any },
				})
				if recorded.kind == "Terminated" then
					return recorded
				end
			end
		end

		if not serverRole then
			for _, endpoint in endpoints do
				local repetition = repetitions[endpoint.repetitionIndex]
				if participant.role == "Client" and selection.kind == "Workload" and selection.direction == "ClientToServer" then
					if endpoint.firstSubmissionStartedSharedSeconds ~= nil then repetition.firstSubmissionStartedSharedSeconds = endpoint.firstSubmissionStartedSharedSeconds end
					if endpoint.finalSubmissionReturnedSharedSeconds ~= nil then repetition.finalSubmissionReturnedSharedSeconds = endpoint.finalSubmissionReturnedSharedSeconds end
				elseif participant.role == "Client" and selection.kind == "Workload" and selection.direction == "ServerToClient" then
					if endpoint.finalExpectedDeliveryReceivedSharedSeconds ~= nil then repetition.finalExpectedDeliveryReceivedSharedSeconds = endpoint.finalExpectedDeliveryReceivedSharedSeconds end
					if endpoint.finalExpectedDeliveryVerifiedSharedSeconds ~= nil then repetition.finalExpectedDeliveryVerifiedSharedSeconds = endpoint.finalExpectedDeliveryVerifiedSharedSeconds end
				end
			end
		end

		local repetitionCount = scheduled
		if not serverRole then
			repetitionCount = 0
			for repetitionIndex = 1, scheduled do
				if not repetitions[repetitionIndex].started then break end
				repetitionCount = repetitionIndex
			end
		end
		local copiedRepetitions = table.create(repetitionCount)
		for repetitionIndex = 1, repetitionCount do
			copiedRepetitions[repetitionIndex] = copyDeep(repetitions[repetitionIndex])
		end
		for _, repetition in copiedRepetitions do deepFreeze(repetition) end
		deepFreeze(copiedRepetitions)
		deepFreeze(measurements)
		deepFreeze(endpoints)
		deepFreeze(conformance)
		local evidenceValue: any = {
			version = 1,
			repetitions = copiedRepetitions,
			measurements = measurements,
			failureFacts = copyFailureArray(failureOrder),
			conformance = conformance,
		}
		if serverRole then
			evidenceValue.timingEndpoints = endpoints
		end
		deepFreeze(evidenceValue)
		frozenEvidence = evidenceValue
		frozenResult = { kind = "Evidence", value = evidenceValue }
		table.freeze(frozenResult)
		return frozenResult
	end

	local state: ParticipantState<TSender> = {
		selection = selection,
		participant = participant,
		beginGeneration = beginGeneration,
		recordFailure = recordFailure,
		freeze = freeze,
	}
	table.freeze(state)
	return state
end

local RunState = {
	newCase = newCase,
	newParticipant = newParticipant,
}

table.freeze(RunState)

return RunState
