--!strict

local EventV1 = require("../contracts/event-v1")
local AdapterIdentity = require("../contracts/internal/AdapterIdentity")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local Fixtures = require("../fixtures/event-v1")

export type CaseBinding = {
	protocolVersion: number,
	runId: string,
	adapterId: string,
	caseId: string,
	recipientCount: number,
}
export type ParticipantBinding = CaseBinding & { participantIndex: number }
export type WireCommon = {
	protocolVersion: number,
	messageType: string,
	runId: string,
	sequence: number,
	adapterId: string,
	caseId: string,
	recipientCount: number,
	repetitionIndex: number,
	phase: string,
}
export type CanonicalCommandBody =
	(WireCommon & { messageType: "BindCase", participantIndex: number })
	| (WireCommon & { messageType: "PrepareRepetition" })
	| (WireCommon & { messageType: "ClockChallenge" })
	| (WireCommon & { messageType: "BeginWarmup" })
	| (WireCommon & { messageType: "ArmMeasured", startSharedSeconds: number })
	| (WireCommon & { messageType: "FinishCase", outcome: "Complete" | "Abort" })
export type MismatchFactV1 =
	{ pathKind: "Root", actual: number? }
	| { pathKind: "Field", fieldIndex: number, actual: (boolean | number)? }
	| { pathKind: "VectorComponent", fieldIndex: number, component: "X" | "Y" | "Z", actual: number? }
export type ReducedFailureFactV1 =
	{ code: "DuplicateDelivery" | "UnexpectedDelivery" | "OutOfOrderDelivery", occurrences: number, firstRepetition: number }
	| { code: "PayloadMismatch", occurrences: number, discriminator: { kind: "MismatchReason", value: string }, firstRepetition: number, fixtureIndex: number, mismatch: MismatchFactV1 }
	| { code: "ControlTrafficDuringMeasuredFrames", occurrences: number, firstRepetition: number }
	| { code: "TimingExclusionViolation", occurrences: number, discriminator: { kind: "TimingExclusion", value: "setup" | "warmup" | "quiescence" } }
	| { code: "IsolationFailure" | "StaleCallback" | "DeliveryObservationLimitExceeded" | "SubmitFailure" | "TeardownFailure", occurrences: number, firstRepetition: number }
	| { code: "InputMutation", occurrences: number }
	| { code: "SetupFailure", occurrences: number }
	| { code: "TeardownFailure", occurrences: number }
	| { code: "InternalError", occurrences: number, discriminator: { kind: "Stage", value: "Setup" | "Execution" | "Finalize" } }
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
export type ParticipantEvidenceV1 = {
	version: number,
	repetitions: { ParticipantRepetitionEvidenceV1 },
	measurements: { { measurementIndex: number, repetitionIndex: number, values: { number } } },
	failureFacts: { ReducedFailureFactV1 },
	conformance: {
		setupExcluded: boolean,
		warmupExcluded: boolean,
		quiescenceExcluded: boolean,
		resultExtractionExcluded: boolean,
		clockProofPassed: boolean,
	},
}
export type CanonicalReportBody =
	(WireCommon & { messageType: "BoundReport", replyToSequence: number })
	| (WireCommon & { messageType: "ReadyReport", replyToSequence: number, outcome: "Ready" | "SetupFailure" })
	| (WireCommon & { messageType: "ClockReply", replyToSequence: number, participantSharedSeconds: number, localBeforeSeconds: number, localAfterSeconds: number })
	| (WireCommon & { messageType: "WarmupReport", replyToSequence: number, outcome: "Clean" | "Dirty" | "InputMutation" })
	| (WireCommon & { messageType: "RepetitionReport", replyToSequence: number, outcome: "Clean" | "Invalid" | "Abort", isolationPassed: boolean })
	| (WireCommon & { messageType: "FinalReport", replyToSequence: number, snapshot: ParticipantEvidenceV1 })
export type CommandIntent =
	{ kind: "BindCase" }
	| { kind: "PrepareRepetition", repetitionIndex: number }
	| { kind: "ClockChallenge" }
	| { kind: "BeginWarmup", repetitionIndex: number }
	| { kind: "ArmMeasured", repetitionIndex: number, startSharedSeconds: number }
	| { kind: "FinishCase", repetitionIndex: number, outcome: "Complete" | "Abort" }
export type ReportIntent =
	{ kind: "BoundReport" }
	| { kind: "ReadyReport", outcome: "Ready" | "SetupFailure" }
	| { kind: "ClockReply", participantSharedSeconds: number, localBeforeSeconds: number, localAfterSeconds: number }
	| { kind: "WarmupReport", outcome: "Clean" | "Dirty" | "InputMutation" }
	| { kind: "RepetitionReport", outcome: "Clean" | "Invalid" | "Abort", isolationPassed: boolean }
	| { kind: "FinalReport", snapshot: ParticipantEvidenceV1 }
export type CommandAction =
	{ kind: "BindCase", participantIndex: number }
	| { kind: "PrepareRepetition" }
	| { kind: "ClockChallenge" }
	| { kind: "BeginWarmup" }
	| { kind: "ArmMeasured", startSharedSeconds: number }
	| { kind: "FinishCase", outcome: "Complete" | "Abort" }
export type ReportEvent =
	{ kind: "BoundReport" }
	| { kind: "ReadyReport", outcome: "Ready" | "SetupFailure" }
	| { kind: "ClockReply", participantSharedSeconds: number, localBeforeSeconds: number, localAfterSeconds: number }
	| { kind: "WarmupReport", outcome: "Clean" | "InputMutation" }
	| { kind: "RepetitionReport", outcome: "Clean" | "Invalid" | "Abort", isolationPassed: boolean }
	| { kind: "FinalReport", snapshot: ParticipantEvidenceV1 }
export type CoordinatorCommandResult =
	{ kind: "Ready", body: CanonicalCommandBody }
	| { kind: "MeasuredControlTraffic" }
	| { kind: "ClockProofFailed", participantIndex: number }
export type CoordinatorBoundaryResult =
	{ kind: "Ready" }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
export type CoordinatorReceiveResult =
	{ kind: "Accepted", participantIndex: number, event: ReportEvent }
	| { kind: "Ignored" }
	| { kind: "MeasuredControlTraffic", participantIndex: number }
	| { kind: "MeasuredControlTraffic" }
	| { kind: "ClockProofFailed", participantIndex: number }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
export type DisconnectResult =
	{ kind: "Ignored" }
	| { kind: "Disconnected", participantIndex: number }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
export type ParticipantReceiveResult =
	{ kind: "Accepted", command: CommandAction }
	| { kind: "MeasuredControlTraffic" }
	| { kind: "Muted" }
export type ParticipantReportResult =
	{ kind: "Ready", body: CanonicalReportBody }
	| { kind: "MeasuredControlTraffic" }
	| { kind: "Muted" }
export type Coordinator<TPlayer> = {
	command: (participantIndex: number, intent: CommandIntent) -> CoordinatorCommandResult,
	receive: (playerToken: TPlayer, ...unknown) -> CoordinatorReceiveResult,
	postSimulation: () -> boolean,
	beginPostTeardownObservation: (repetitionIndex: number, started: boolean, completed: boolean) -> CoordinatorBoundaryResult,
	beginFinalReports: (outcome: "Complete" | "Abort", reachedRepetition: number, cause: "InputMutation"?) -> CoordinatorBoundaryResult,
	expireResponse: (participantIndex: number) -> CoordinatorBoundaryResult,
	disconnect: (playerToken: TPlayer) -> DisconnectResult,
	disable: () -> (),
}
export type Participant = {
	receive: (...unknown) -> ParticipantReceiveResult,
	report: (intent: ReportIntent) -> ParticipantReportResult,
	postSimulation: () -> boolean,
	beginPostTeardownObservation: (repetitionIndex: number) -> (),
	disable: () -> (),
}

local CONFIG_ERROR = "CONTROL_PROTOCOL_E_CONFIG"
local INPUT_ERROR = "CONTROL_PROTOCOL_E_INPUT"
local STATE_ERROR = "CONTROL_PROTOCOL_E_STATE"

local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local MAX_CLIENTS = 8
local MAX_REPETITIONS = 30
local MAX_DEPTH = 6
local MAX_NODES = 570
local MAX_ENTRIES = 65_536
local MAX_VALUES = 1_000
local MAX_ACCEPTED = 93
local MAX_REPLAYS = 128
local MAX_UNIVERSAL = 221
local MAX_NON_ROSTER = 64
local QUIET_FRAMES = 60

local function maximumWorkloadSamples(): number
	local maximum = 0
	for _, workload in EventV1.workloads do
		local perRepetition = 0
		for _, measurement in EventV1.measurements do
			if measurement.scope == "Workload" then
				local cadence = measurement.capture.cadence
				local values = if cadence == "PerMeasuredFrame"
					then workload.measuredFrames
					elseif cadence == "PerRepetition"
					then 1
					elseif cadence == "PerSubmission"
					then workload.measuredFrames * workload.messagesPerFrame
					else error(CONFIG_ERROR, 0)
				local participants = if measurement.capture.role == "Sender" then workload.senderCount else 1
				perRepetition += values * participants
			end
		end
		maximum = math.max(maximum, perRepetition * workload.repetitions)
	end
	return maximum
end

local MAX_TOTAL_SAMPLES = maximumWorkloadSamples()

local COMMON_KEYS = {
	protocolVersion = true,
	messageType = true,
	runId = true,
	sequence = true,
	adapterId = true,
	caseId = true,
	recipientCount = true,
	repetitionIndex = true,
	phase = true,
}

local COMMAND_SPECS = {
	BindCase = { phase = "WaitingForParticipants", keys = { participantIndex = true } },
	PrepareRepetition = { phase = "Preparing", keys = {} },
	ClockChallenge = { phase = "Ready", keys = {} },
	BeginWarmup = { phase = "Warmup", keys = {} },
	ArmMeasured = { phase = "ArmedMeasured", keys = { startSharedSeconds = true } },
	FinishCase = {
		phase = "ParticipantEvidenceFreezeAndFinalReports",
		keys = { outcome = true },
	},
}

local REPORT_SPECS = {
	BoundReport = { phase = "WaitingForParticipants", keys = { replyToSequence = true } },
	ReadyReport = { phase = "Ready", keys = { replyToSequence = true, outcome = true } },
	ClockReply = {
		phase = "Ready",
		keys = {
			replyToSequence = true,
			participantSharedSeconds = true,
			localBeforeSeconds = true,
			localAfterSeconds = true,
		},
	},
	WarmupReport = { phase = "WarmupDrained", keys = { replyToSequence = true, outcome = true } },
	RepetitionReport = {
		phase = "PostTeardownObservation",
		keys = { replyToSequence = true, outcome = true, isolationPassed = true },
	},
	FinalReport = {
		phase = "ParticipantEvidenceFreezeAndFinalReports",
		keys = { replyToSequence = true, snapshot = true },
	},
}

local FROZEN_READY = table.freeze({ kind = "Ready" })
local FROZEN_IGNORED = table.freeze({ kind = "Ignored" })
local FROZEN_MUTED = table.freeze({ kind = "Muted" })
local FROZEN_MEASURED = table.freeze({ kind = "MeasuredControlTraffic" })

local function configError(): never
	error(CONFIG_ERROR, 0)
end

local function inputError(): never
	error(INPUT_ERROR, 0)
end

local function stateError(): never
	error(STATE_ERROR, 0)
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: number): boolean
	return value == 0 and 1 / value == -math.huge
end

local function isSafeInteger(value: any, minimum: number?, maximum: number?): boolean
	return isFinite(value)
		and not isNegativeZero(value)
		and value % 1 == 0
		and value >= (minimum or 0)
		and value <= (maximum or MAX_SAFE_INTEGER)
end

local function isNonnegativeFinite(value: any): boolean
	return isFinite(value) and value >= 0 and not isNegativeZero(value)
end

local function checkedAdd(left: number, right: number): number?
	if not isSafeInteger(left, 0) or not isSafeInteger(right, 0) or left > MAX_SAFE_INTEGER - right then return nil end
	return left + right
end

local function checkedMultiply(left: number, right: number): number?
	if not isSafeInteger(left, 0) or not isSafeInteger(right, 0) then return nil end
	if left ~= 0 and right > MAX_SAFE_INTEGER / left then return nil end
	return left * right
end

local function isUuid(value: any): boolean
	return type(value) == "string"
		and string.match(value, "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") ~= nil
end

local function isMachineId(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[a-z0-9][a-z0-9._-]*$") ~= nil
end

local function deepFreeze(value: any, seen: { [table]: boolean }?)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	local visited = seen or {}
	if visited[value] then
		return
	end
	visited[value] = true
	local key = next(value)
	while key ~= nil do
		deepFreeze(key, visited)
		deepFreeze(rawget(value, key), visited)
		key = next(value, key)
	end
	table.freeze(value)
end

local function frozen(value: any): any
	deepFreeze(value)
	return value
end

local function exactKeys(value: any, keys: { [string]: boolean }): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local found = 0
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or rawget(keys, key) ~= true then
			return false
		end
		found += 1
		key = next(value, key)
	end
	local required = 0
	for _ in keys do
		required += 1
	end
	return found == required
end

local function exactRequiredWithOptional(value: any, required: { [string]: boolean }, optional: { [string]: boolean }): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local foundRequired: { [string]: boolean } = {}
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or (rawget(required, key) ~= true and rawget(optional, key) ~= true) then return false end
		if rawget(required, key) then foundRequired[key] = true end
		key = next(value, key)
	end
	for requiredKey in required do
		if not foundRequired[requiredKey] then return false end
	end
	return true
end

local function mergedKeys(base: { [string]: boolean }, extra: { [string]: boolean }): { [string]: boolean }
	local result = {}
	for key in base do
		result[key] = true
	end
	for key in extra do
		result[key] = true
	end
	return result
end

local function denseArray(value: any, maximum: number): (boolean, number)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false, 0
	end
	local count = 0
	local key = next(value)
	while key ~= nil do
		if not isSafeInteger(key, 1, maximum) then
			return false, 0
		end
		count += 1
		if count > maximum then
			return false, 0
		end
		key = next(value, key)
	end
	for index = 1, count do
		if rawget(value, index) == nil then
			return false, 0
		end
	end
	return true, count
end

local function preflight(value: any): boolean
	local seen: { [table]: string } = {}
	local nodes = 0
	local entries = 0
	local function visit(current: any, depth: number): boolean
		if type(current) ~= "table" then
			return true
		end
		if getmetatable(current) ~= nil or depth > MAX_DEPTH then
			return false
		end
		local state = seen[current]
		if state ~= nil then
			return false
		end
		seen[current] = "active"
		nodes += 1
		if nodes > MAX_NODES then
			return false
		end
		local key = next(current)
		while key ~= nil do
			entries += 1
			if entries > MAX_ENTRIES or not visit(key, depth + 1) or not visit(rawget(current, key), depth + 1) then
				return false
			end
			key = next(current, key)
		end
		seen[current] = "done"
		return true
	end
	return visit(value, 1)
end

local function copyArrayScalars(value: any, maximum: number, validator: (any) -> boolean): ({ any }?, number)
	local ok, count = denseArray(value, maximum)
	if not ok then
		return nil, 0
	end
	local result = table.create(count)
	for index = 1, count do
		local item = rawget(value, index)
		if not validator(item) then
			return nil, 0
		end
		result[index] = item
	end
	return result, count
end

local function resolveCase(caseId: string, recipientCount: number): (any?, any?)
	for _, workload in EventV1.workloads do
		if workload.id == caseId then
			local result = AdapterIdentity.resolveSelection({
				kind = "Workload",
				workloadId = caseId,
				recipientCount = recipientCount,
			})
			if result.kind ~= "Valid" or result.value.clientProcessCount ~= recipientCount then
				return nil, nil
			end
			return workload, result.value
		end
	end
	for _, probe in EventV1.probes do
		if probe.id == caseId then
			local result = AdapterIdentity.resolveSelection({ kind = "SeparateProbe", probeId = caseId })
			if result.kind ~= "Valid" or result.value.clientProcessCount ~= recipientCount then
				return nil, nil
			end
			return probe, result.value
		end
	end
	return nil, nil
end

local function copyBinding(candidate: any, participant: boolean): (any, any, any)
	local keys = {
		protocolVersion = true,
		runId = true,
		adapterId = true,
		caseId = true,
		recipientCount = true,
	}
	if participant then
		keys.participantIndex = true
	end
	if not exactKeys(candidate, keys)
		or rawget(candidate, "protocolVersion") ~= 1
		or not isUuid(rawget(candidate, "runId"))
		or not isMachineId(rawget(candidate, "adapterId"))
		or type(rawget(candidate, "caseId")) ~= "string"
		or not isSafeInteger(rawget(candidate, "recipientCount"), 1, MAX_CLIENTS)
	then
		configError()
	end
	local caseDefinition, selection = resolveCase(rawget(candidate, "caseId"), rawget(candidate, "recipientCount"))
	if caseDefinition == nil then
		configError()
	end
	if participant and not isSafeInteger(rawget(candidate, "participantIndex"), 1, rawget(candidate, "recipientCount")) then
		configError()
	end
	local result = {
		protocolVersion = 1,
		runId = rawget(candidate, "runId"),
		adapterId = rawget(candidate, "adapterId"),
		caseId = rawget(candidate, "caseId"),
		recipientCount = rawget(candidate, "recipientCount"),
	}
	if participant then
		result.participantIndex = rawget(candidate, "participantIndex")
	end
	table.freeze(result)
	return result, caseDefinition, selection
end

local function termination(code: string, stage: string): any
	return frozen({ kind = "Terminated", termination = HarnessTerminationV1.new(code, stage) })
end

local function callNonYielding(callback: (...any) -> any, ...: any): (boolean, any)
	local arguments = table.pack(...)
	local thread = coroutine.create(function()
		return callback(table.unpack(arguments, 1, arguments.n))
	end)
	local ok, value = coroutine.resume(thread)
	local dead = coroutine.status(thread) == "dead"
	if not dead then pcall(coroutine.close, thread) end
	return ok and dead, value
end

local function readTrustedClock(clock: () -> number, previous: number?): number?
	local ok, value = callNonYielding(clock)
	if not ok or not isNonnegativeFinite(value) or (previous ~= nil and value < previous) then
		return nil
	end
	return value
end

local function commonBody(binding: any, messageType: string, sequence: number, repetitionIndex: number, phase: string): any
	return {
		protocolVersion = 1,
		messageType = messageType,
		runId = binding.runId,
		sequence = sequence,
		adapterId = binding.adapterId,
		caseId = binding.caseId,
		recipientCount = binding.recipientCount,
		repetitionIndex = repetitionIndex,
		phase = phase,
	}
end

local function copyHeader(body: any): any
	local result = {
		protocolVersion = rawget(body, "protocolVersion"),
		messageType = rawget(body, "messageType"),
		runId = rawget(body, "runId"),
		sequence = rawget(body, "sequence"),
		adapterId = rawget(body, "adapterId"),
		caseId = rawget(body, "caseId"),
		recipientCount = rawget(body, "recipientCount"),
		repetitionIndex = rawget(body, "repetitionIndex"),
		phase = rawget(body, "phase"),
	}
	if rawget(body, "replyToSequence") ~= nil then
		result.replyToSequence = rawget(body, "replyToSequence")
	end
	table.freeze(result)
	return result
end

local function headerMatches(a: any, b: any): boolean
	return a.protocolVersion == b.protocolVersion
		and a.messageType == b.messageType
		and a.runId == b.runId
		and a.sequence == b.sequence
		and a.adapterId == b.adapterId
		and a.caseId == b.caseId
		and a.recipientCount == b.recipientCount
		and a.repetitionIndex == b.repetitionIndex
		and a.phase == b.phase
		and a.replyToSequence == b.replyToSequence
end

local function tupleMatches(body: any, binding: any, participantIndex: number?): boolean
	return rawget(body, "protocolVersion") == 1
		and rawget(body, "runId") == binding.runId
		and rawget(body, "adapterId") == binding.adapterId
		and rawget(body, "caseId") == binding.caseId
		and rawget(body, "recipientCount") == binding.recipientCount
		and (participantIndex == nil or rawget(body, "participantIndex") == participantIndex)
end

local REPETITION_KEYS = {
	repetitionIndex = true,
	started = true,
	completed = true,
	submitted = true,
	received = true,
	correct = true,
	mismatch = true,
	duplicate = true,
	unexpected = true,
	outOfOrder = true,
	staleCallbacks = true,
	observationOverflow = true,
	probeStarted = true,
	probeSubmitted = true,
	probeReceived = true,
	probeCorrect = true,
	probeMismatch = true,
}

local ENDPOINT_KEYS = {
	firstSubmissionStartedSharedSeconds = true,
	finalSubmissionReturnedSharedSeconds = true,
	finalExpectedDeliveryReceivedSharedSeconds = true,
	finalExpectedDeliveryVerifiedSharedSeconds = true,
}

local function participantStaleCallbackLimit(role: string, caseDefinition: any): number?
	local expected
	if role == "Receiver" then
		expected = checkedMultiply(caseDefinition.senderCount, caseDefinition.measuredFrames)
		expected = if expected == nil then nil else checkedMultiply(expected, caseDefinition.messagesPerFrame)
	elseif role == "ProbeClient" then
		expected = caseDefinition.measuredSamples
	else
		return 0
	end
	expected = if expected == nil then nil else checkedMultiply(expected, caseDefinition.repetitions)
	return if expected == nil then nil else checkedMultiply(4, expected)
end

local function copyRepetition(candidate: any, index: number, role: string, caseDefinition: any, known: any): any?
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then return nil end
	local allowed = {}
	for key in REPETITION_KEYS do allowed[key] = true end
	if role == "Sender" then
		allowed.firstSubmissionStartedSharedSeconds = true
		allowed.finalSubmissionReturnedSharedSeconds = true
	elseif role == "Receiver" then
		allowed.finalExpectedDeliveryReceivedSharedSeconds = true
		allowed.finalExpectedDeliveryVerifiedSharedSeconds = true
	end
	local optional = {}
	for key in ENDPOINT_KEYS do optional[key] = allowed[key] == true end
	local completed = rawget(candidate, "completed")
	local extraCompletion = completed == true
		and known.completed == false
		and known.allowExtraCompletion == true
		and (role == "Receiver" or role == "ProbeClient")
	if not exactRequiredWithOptional(candidate, REPETITION_KEYS, optional)
		or rawget(candidate, "repetitionIndex") ~= index
		or type(rawget(candidate, "started")) ~= "boolean"
		or type(rawget(candidate, "completed")) ~= "boolean"
		or rawget(candidate, "started") ~= known.started
		or (completed ~= known.completed and not extraCompletion)
		or type(rawget(candidate, "observationOverflow")) ~= "boolean"
	then
		return nil
	end
	for key in REPETITION_KEYS do
		if key ~= "repetitionIndex" and key ~= "started" and key ~= "completed" and key ~= "observationOverflow"
			and not isSafeInteger(rawget(candidate, key), 0)
		then
			return nil
		end
	end
	local submitted = rawget(candidate, "submitted")
	local received = rawget(candidate, "received")
	local correct = rawget(candidate, "correct")
	local mismatch = rawget(candidate, "mismatch")
	local duplicate = rawget(candidate, "duplicate")
	local unexpected = rawget(candidate, "unexpected")
	local outOfOrder = rawget(candidate, "outOfOrder")
	local stale = rawget(candidate, "staleCallbacks")
	local probeStarted = rawget(candidate, "probeStarted")
	local probeSubmitted = rawget(candidate, "probeSubmitted")
	local probeReceived = rawget(candidate, "probeReceived")
	local probeCorrect = rawget(candidate, "probeCorrect")
	local probeMismatch = rawget(candidate, "probeMismatch")
	local staleLimit = participantStaleCallbackLimit(role, caseDefinition)
	if staleLimit == nil or stale > staleLimit then return nil end
	if role == "Sender" then
		local planned = caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
		if received ~= 0 or correct ~= 0 or mismatch ~= 0 or duplicate ~= 0 or unexpected ~= 0 or outOfOrder ~= 0
			or stale ~= 0 or rawget(candidate, "observationOverflow") or probeStarted ~= 0 or probeSubmitted ~= 0
			or probeReceived ~= 0 or probeCorrect ~= 0 or probeMismatch ~= 0 or submitted > planned
		then return nil end
		local first = rawget(candidate, "firstSubmissionStartedSharedSeconds")
		local final = rawget(candidate, "finalSubmissionReturnedSharedSeconds")
		if (first ~= nil and not isNonnegativeFinite(first)) or (final ~= nil and not isNonnegativeFinite(final))
			or (final ~= nil and first == nil) or (first ~= nil and final ~= nil and final < first)
		then return nil end
		if submitted > 0 and first == nil then return nil end
		if known.completed and (submitted ~= planned or final == nil) then return nil end
	elseif role == "Receiver" then
		local expected = caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
		local observationLimit = 4 * expected * caseDefinition.repetitions
		if submitted ~= 0 or probeStarted ~= 0 or probeSubmitted ~= 0 or probeReceived ~= 0 or probeCorrect ~= 0
			or probeMismatch ~= 0 or received ~= correct + mismatch + duplicate + unexpected
			or correct + mismatch > expected or outOfOrder > correct + mismatch
			or (duplicate > 0 and correct + mismatch == 0) or received > observationLimit
		then return nil end
		local receipt = rawget(candidate, "finalExpectedDeliveryReceivedSharedSeconds")
		local verified = rawget(candidate, "finalExpectedDeliveryVerifiedSharedSeconds")
		if (receipt == nil) ~= (verified == nil)
			or (receipt ~= nil and (not isNonnegativeFinite(receipt) or not isNonnegativeFinite(verified) or verified < receipt))
			or (receipt ~= nil and correct + mismatch ~= expected)
		then return nil end
	else
		if submitted ~= 0 or received ~= 0 or correct ~= 0 or mismatch ~= 0 or duplicate ~= 0 or unexpected ~= 0
			or outOfOrder ~= 0 or probeReceived ~= probeCorrect + probeMismatch
			or probeReceived > probeSubmitted or probeSubmitted > probeStarted or probeStarted > caseDefinition.measuredSamples
		then return nil end
		if known.completed and (probeStarted ~= caseDefinition.measuredSamples
			or probeSubmitted ~= caseDefinition.measuredSamples or probeReceived ~= caseDefinition.measuredSamples)
		then return nil end
	end
	local result = {}
	for key in allowed do result[key] = rawget(candidate, key) end
	return result
end

local function validateMismatch(candidate: any, reason: string, payload: any, expected: any): any?
	local kind = if type(candidate) == "table" then rawget(candidate, "pathKind") else nil
	local fieldIndex = if type(candidate) == "table" then rawget(candidate, "fieldIndex") else nil
	local component = if type(candidate) == "table" then rawget(candidate, "component") else nil
	local actual = if type(candidate) == "table" then rawget(candidate, "actual") else nil
	local keys
	if kind == "Root" then
		keys = if reason == "ArityMismatch" then { pathKind = true, actual = true } else { pathKind = true }
		if not exactKeys(candidate, keys) then return nil end
		if reason == "ArityMismatch" then
			if not isSafeInteger(actual, 0) or actual == #payload.fields then return nil end
		elseif reason ~= "WrongContainerType" and reason ~= "ExtraField" then return nil end
		return if actual == nil then { pathKind = "Root" } else { pathKind = "Root", actual = actual }
	end
	if kind ~= "Field" and kind ~= "VectorComponent" then return nil end
	local field = if isSafeInteger(fieldIndex, 1, #payload.fields) then payload.fields[fieldIndex] else nil
	if field == nil then return nil end
	keys = { pathKind = true, fieldIndex = true }
	if kind == "VectorComponent" then
		keys.component = true
		if field.valueType ~= "Vector3F32" or (component ~= "X" and component ~= "Y" and component ~= "Z") then return nil end
	end
	local needsActual = reason == "NonInteger" or reason == "OutOfRange" or reason == "NotFloat32" or reason == "ValueMismatch"
	local optionalActual = reason == "WrongType"
	if needsActual or (optionalActual and actual ~= nil) then keys.actual = true end
	if not exactKeys(candidate, keys) then return nil end
	if reason == "MissingField" then
		if kind ~= "Field" then return nil end
	elseif reason == "WrongType" then
		if kind ~= "Field" or (actual ~= nil and type(actual) ~= "boolean" and not isFinite(actual)) then return nil end
		local expectedType = field.valueType
		if (expectedType == "boolean" and type(actual) == "boolean")
			or (expectedType ~= "boolean" and expectedType ~= "Vector3F32" and type(actual) == "number")
		then return nil end
	elseif reason == "NonFinite" then
		if field.valueType == "boolean" then return nil end
		if (field.valueType == "Vector3F32") ~= (kind == "VectorComponent") then return nil end
	elseif reason == "NonInteger" then
		if kind ~= "Field" or (field.valueType ~= "u8" and field.valueType ~= "u16" and field.valueType ~= "u32")
			or not isFinite(actual) or actual % 1 == 0 then return nil end
	elseif reason == "OutOfRange" then
		if field.valueType == "boolean" or not isFinite(actual)
			or (field.valueType == "Vector3F32") ~= (kind == "VectorComponent")
			or (field.minimum ~= nil and actual >= field.minimum and field.maximum ~= nil and actual <= field.maximum) then return nil end
		if (field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32") and actual % 1 ~= 0 then return nil end
	elseif reason == "NotFloat32" then
		if (field.valueType ~= "f32" and field.valueType ~= "Vector3F32") or not isFinite(actual)
			or (field.valueType == "Vector3F32") ~= (kind == "VectorComponent")
			or (field.minimum ~= nil and actual < field.minimum) or (field.maximum ~= nil and actual > field.maximum) then return nil end
		local b = buffer.create(4); buffer.writef32(b, 0, actual)
		if buffer.readf32(b, 0) == actual then return nil end
	elseif reason == "ValueMismatch" then
		if type(actual) ~= "boolean" and not isFinite(actual) then return nil end
		local expectedValue = rawget(expected, field.name)
		if kind == "VectorComponent" then expectedValue = expectedValue[component] end
		local equal = actual == expectedValue
		if field.valueType == "boolean" then
			if kind ~= "Field" or type(actual) ~= "boolean" then return nil end
		elseif field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32" then
			if kind ~= "Field" or type(actual) ~= "number" or actual % 1 ~= 0
				or actual < field.minimum or actual > field.maximum then return nil end
		else
			if (field.valueType == "Vector3F32") ~= (kind == "VectorComponent")
				or type(actual) ~= "number" or actual < field.minimum or actual > field.maximum then return nil end
			local b = buffer.create(4)
			buffer.writef32(b, 0, actual)
			local actualBits = buffer.readu32(b, 0)
			if buffer.readf32(b, 0) ~= actual then return nil end
			buffer.writef32(b, 0, expectedValue)
			equal = actualBits == buffer.readu32(b, 0)
		end
		if equal then return nil end
	else
		return nil
	end
	local result = { pathKind = kind, fieldIndex = fieldIndex }
	if component ~= nil then result.component = component end
	if actual ~= nil then result.actual = actual end
	return result
end

local FAILURE_ORDER = {
	DuplicateDelivery = 1,
	UnexpectedDelivery = 2,
	OutOfOrderDelivery = 3,
	PayloadMismatch = 4,
	ControlTrafficDuringMeasuredFrames = 5,
	TimingExclusionViolation = 6,
	IsolationFailure = 7,
	StaleCallback = 8,
	DeliveryObservationLimitExceeded = 9,
	SetupFailure = 10,
	SubmitFailure = 11,
	TeardownFailure = 12,
	InternalError = 13,
	InputMutation = 14,
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

local function copyFailureFact(candidate: any, role: string, caseDefinition: any, startedCount: number, coordinator: any): (any?, number)
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then return nil, 0 end
	local code = rawget(candidate, "code")
	local order = if type(code) == "string" then rawget(FAILURE_ORDER, code) else nil
	if order == nil then return nil, 0 end
	local occurrences = rawget(candidate, "occurrences")
	if not isSafeInteger(occurrences, 1) then return nil, 0 end
	local first = rawget(candidate, "firstRepetition")
	local result: any = { code = code, occurrences = occurrences }
	if code == "DuplicateDelivery" or code == "UnexpectedDelivery" or code == "OutOfOrderDelivery" then
		if role ~= "Receiver" or not exactKeys(candidate, { code = true, occurrences = true, firstRepetition = true })
			or not isSafeInteger(first, 1, startedCount) then return nil, 0 end
		result.firstRepetition = first
	elseif code == "PayloadMismatch" then
		if (role ~= "Receiver" and role ~= "ProbeClient")
			or not exactKeys(candidate, {
				code = true, occurrences = true, discriminator = true, firstRepetition = true,
				fixtureIndex = true, mismatch = true,
			}) or not isSafeInteger(first, 1, startedCount) then return nil, 0 end
		local discriminator = rawget(candidate, "discriminator")
		if not exactKeys(discriminator, { kind = true, value = true }) or rawget(discriminator, "kind") ~= "MismatchReason" then return nil, 0 end
		local reason = rawget(discriminator, "value")
		local reasonOrder = if type(reason) == "string" then rawget(REASON_ORDER, reason) else nil
		if reasonOrder == nil then return nil, 0 end
		local fixtureIndex = rawget(candidate, "fixtureIndex")
		local fixtures
		if role == "ProbeClient" then
			fixtures = Fixtures.generateProbe(caseDefinition.id, first)
		else
			fixtures = Fixtures.generate(caseDefinition.id, first)
		end
		if not isSafeInteger(fixtureIndex, 1, #fixtures.measured) then return nil, 0 end
		local sample = rawget(fixtures.measured, fixtureIndex)
		local payload = EventV1.payloads[caseDefinition.payloadId]
		local mismatch = validateMismatch(rawget(candidate, "mismatch"), reason, payload, sample.expected)
		if mismatch == nil then return nil, 0 end
		result.discriminator = { kind = "MismatchReason", value = reason }
		result.firstRepetition = first
		result.fixtureIndex = fixtureIndex
		result.mismatch = mismatch
		return result, order * 100 + reasonOrder
	elseif code == "ControlTrafficDuringMeasuredFrames" then
		if not exactKeys(candidate, { code = true, occurrences = true, firstRepetition = true })
			or occurrences ~= 1 or not isSafeInteger(first, 1, startedCount)
			or (coordinator.firstMeasuredTrafficRepetition ~= nil
				and first ~= coordinator.firstMeasuredTrafficRepetition)
		then return nil, 0 end
		result.firstRepetition = first
	elseif code == "TimingExclusionViolation" then
		if occurrences ~= 1 or not exactKeys(candidate, { code = true, occurrences = true, discriminator = true }) then return nil, 0 end
		local discriminator = rawget(candidate, "discriminator")
		local value = if type(discriminator) == "table" then rawget(discriminator, "value") else nil
		if not exactKeys(discriminator, { kind = true, value = true }) or rawget(discriminator, "kind") ~= "TimingExclusion"
			or (value ~= "setup" and value ~= "warmup" and value ~= "quiescence") then return nil, 0 end
		result.discriminator = { kind = "TimingExclusion", value = value }
		return result, order * 100 + (if value == "setup" then 1 elseif value == "warmup" then 2 else 3)
	elseif code == "IsolationFailure" or code == "StaleCallback" or code == "DeliveryObservationLimitExceeded"
		or code == "SubmitFailure" or code == "TeardownFailure"
	then
		local preStartTeardown = code == "TeardownFailure" and startedCount == 0 and first == nil
		if preStartTeardown then
			if occurrences ~= 1 or not exactKeys(candidate, { code = true, occurrences = true }) then return nil, 0 end
		else
			if not exactKeys(candidate, { code = true, occurrences = true, firstRepetition = true })
				or not isSafeInteger(first, 1, startedCount) then return nil, 0 end
			result.firstRepetition = first
		end
		if code == "TeardownFailure" and not preStartTeardown and occurrences > startedCount - first + 1 then
			return nil, 0
		end
		if (code == "StaleCallback" and role == "Sender")
			or ((code == "DuplicateDelivery" or code == "UnexpectedDelivery" or code == "OutOfOrderDelivery") and role ~= "Receiver")
			or (code == "DeliveryObservationLimitExceeded" and role == "Sender")
			or (code == "SubmitFailure" and role == "Receiver")
		then return nil, 0 end
		if code == "DeliveryObservationLimitExceeded" and occurrences ~= 1 then return nil, 0 end
	elseif code == "InputMutation" then
		if occurrences ~= 1
			or (role ~= "Sender" and role ~= "ProbeClient")
			or not exactKeys(candidate, { code = true, occurrences = true })
		then return nil, 0 end
	elseif code == "SetupFailure" then
		if occurrences ~= 1 or not exactKeys(candidate, { code = true, occurrences = true }) then return nil, 0 end
	elseif code == "InternalError" then
		if occurrences ~= 1 or not exactKeys(candidate, { code = true, occurrences = true, discriminator = true }) then return nil, 0 end
		local discriminator = rawget(candidate, "discriminator")
		local value = if type(discriminator) == "table" then rawget(discriminator, "value") else nil
		if not exactKeys(discriminator, { kind = true, value = true }) or rawget(discriminator, "kind") ~= "Stage"
			or (value ~= "Setup" and value ~= "Execution" and value ~= "Finalize") then return nil, 0 end
		result.discriminator = { kind = "Stage", value = value }
		return result, order * 100 + (if value == "Setup" then 1 elseif value == "Execution" then 2 else 3)
	else
		return nil, 0
	end
	return result, order * 100
end

local function expectedMeasurementCount(index: number, caseDefinition: any): number?
	if index == 4 or index == 11 then return caseDefinition.measuredFrames end
	if index == 5 or index == 13 or index == 14 then return 1 end
	if index == 10 or index == 12 then return caseDefinition.measuredFrames * caseDefinition.messagesPerFrame end
	if index == 9 then return caseDefinition.measuredSamples end
	return nil
end

local function copyMeasurements(candidate: any, role: string, caseDefinition: any, repetitions: { any }): { any }?
	local ok, count = denseArray(candidate, 210)
	if not ok then return nil end
	local result = table.create(count)
	local totalSamples = 0
	local previousKey = 0
	local seen: { [number]: boolean } = {}
	for position = 1, count do
		local entry = rawget(candidate, position)
		if not exactKeys(entry, { measurementIndex = true, repetitionIndex = true, values = true }) then return nil end
		local index = rawget(entry, "measurementIndex")
		local repetition = rawget(entry, "repetitionIndex")
		if not isSafeInteger(index, 1, #EventV1.measurements) or not isSafeInteger(repetition, 1, #repetitions) then return nil end
		local roleAllowed = (role == "ProbeClient" and index == 9)
			or (role == "Sender" and (index == 4 or index == 5 or index == 10 or (index >= 11 and index <= 14)))
		if not roleAllowed then return nil end
		local expected = expectedMeasurementCount(index, caseDefinition)
		if expected == nil then return nil end
		local values, valueCount = copyArrayScalars(rawget(entry, "values"), MAX_VALUES, isNonnegativeFinite)
		if values == nil or valueCount > expected then return nil end
		if repetitions[repetition].completed and valueCount ~= expected then return nil end
		totalSamples += valueCount
		if totalSamples > MAX_TOTAL_SAMPLES then return nil end
		local key = repetition * 100 + index
		if key <= previousKey then return nil end
		previousKey = key
		seen[key] = true
		result[position] = { measurementIndex = index, repetitionIndex = repetition, values = values }
	end
	for repetition = 1, #repetitions do
		if repetitions[repetition].completed then
			if role == "Sender" then
				for _, index in { 4, 5, 10 } do if not seen[repetition * 100 + index] then return nil end end
			elseif role == "ProbeClient" and not seen[repetition * 100 + 9] then
				return nil
			end
		end
	end
	return result
end

local function copySnapshot(candidate: any, role: string, caseDefinition: any, coordinator: any): any?
	if not preflight(candidate) or not exactKeys(candidate, {
		version = true, repetitions = true, measurements = true, failureFacts = true, conformance = true,
	}) or rawget(candidate, "version") ~= 1 then return nil end
	local repsCandidate = rawget(candidate, "repetitions")
	local ok, count = denseArray(repsCandidate, MAX_REPETITIONS)
	local expectedRepetitionCount = if coordinator.finalRepetition ~= nil then coordinator.finalRepetition else coordinator.currentRepetition
	if not ok or count ~= expectedRepetitionCount then return nil end
	local repetitions = table.create(count)
	for index = 1, count do
		local known = coordinator.repetitions[index]
		if known == nil then return nil end
		local copied = copyRepetition(rawget(repsCandidate, index), index, role, caseDefinition, known)
		if copied == nil then return nil end
		repetitions[index] = copied
	end
	local measurements = copyMeasurements(rawget(candidate, "measurements"), role, caseDefinition, repetitions)
	if measurements == nil then return nil end
	local factsCandidate = rawget(candidate, "failureFacts")
	local factsOk, factsCount = denseArray(factsCandidate, 39)
	if not factsOk then return nil end
	local facts = table.create(factsCount)
	local priorSort = 0
	local seenCode: { [string]: boolean } = {}
	local seenPayloadReason: { [string]: boolean } = {}
	local seenTimingExclusion: { [string]: boolean } = {}
	local seenInternalStage: { [string]: boolean } = {}
	local hasSetup = false
	local hasInputMutation = false
	local hasPreStartTeardown = false
	local factsByCode: { [string]: any } = {}
	local payloadOccurrences = 0
	for index = 1, factsCount do
		local fact, sortKey = copyFailureFact(rawget(factsCandidate, index), role, caseDefinition, count, coordinator)
		if fact == nil or sortKey < priorSort then return nil end
		priorSort = sortKey
		if fact.code == "PayloadMismatch" then
			local reason = fact.discriminator.value
			if seenPayloadReason[reason] then return nil end
			local repetition = repetitions[fact.firstRepetition]
			local mismatch = if role == "ProbeClient" then repetition.probeMismatch else repetition.mismatch
			if mismatch == 0 then return nil end
			seenPayloadReason[reason] = true
			payloadOccurrences += fact.occurrences
		elseif fact.code == "TimingExclusionViolation" then
			local exclusion = fact.discriminator.value
			if seenTimingExclusion[exclusion] then return nil end
			seenTimingExclusion[exclusion] = true
		elseif fact.code == "InternalError" then
			local internalStage = fact.discriminator.value
			if seenInternalStage[internalStage] then return nil end
			seenInternalStage[internalStage] = true
		elseif seenCode[fact.code] then
			return nil
		else
			seenCode[fact.code] = true
		end
		factsByCode[fact.code] = fact
		if fact.code == "SetupFailure" then hasSetup = true end
		if fact.code == "InputMutation" then hasInputMutation = true end
		if fact.code == "TeardownFailure" and fact.firstRepetition == nil then hasPreStartTeardown = true end
		facts[index] = fact
	end
	if hasPreStartTeardown and not hasSetup and not hasInputMutation
		and not (count == 0 and coordinator.allowPrestartTeardown == true)
	then return nil end
	if count == 0 and hasSetup and hasInputMutation then return nil end
	if count == 0 then
		if hasInputMutation ~= (coordinator.warmupInputMutation == true) then return nil end
	elseif hasInputMutation then
		local current = repetitions[count]
		local known = coordinator.repetitions[count]
		local acceptedOperation = if role == "ProbeClient" then current.probeSubmitted > 0 else current.submitted > 0
		if known == nil or known.completed or current.completed or not acceptedOperation then return nil end
	end
	local sums = {
		received = 0, duplicate = 0, unexpected = 0, outOfOrder = 0, mismatch = 0, staleCallbacks = 0,
		observationOverflow = false, isolationFailures = 0,
		firstDuplicate = nil, firstUnexpected = nil, firstOutOfOrder = nil, firstStale = nil,
		firstOverflow = nil, firstIsolation = nil,
	}
	local staleLimit = participantStaleCallbackLimit(role, caseDefinition)
	if staleLimit == nil then return nil end
	local observationLimit = if role == "Receiver"
		then 4 * caseDefinition.measuredFrames * caseDefinition.messagesPerFrame * caseDefinition.repetitions
		else 0
	local submissionCandidates: { [number]: boolean } = {}
	for index = 1, count do
		local repetition = repetitions[index]
		sums.received += repetition.received
		if sums.received > observationLimit then return nil end
		if repetition.observationOverflow and role == "Receiver" and index ~= count then return nil end
		sums.duplicate += repetition.duplicate
		sums.unexpected += repetition.unexpected
		sums.outOfOrder += repetition.outOfOrder
		sums.mismatch += if role == "ProbeClient" then repetition.probeMismatch else repetition.mismatch
		local staleTotal = checkedAdd(sums.staleCallbacks, repetition.staleCallbacks)
		if staleTotal == nil or staleTotal > staleLimit then return nil end
		sums.staleCallbacks = staleTotal
		sums.observationOverflow = sums.observationOverflow or repetition.observationOverflow
		if repetition.duplicate > 0 and sums.firstDuplicate == nil then sums.firstDuplicate = index end
		if repetition.unexpected > 0 and sums.firstUnexpected == nil then sums.firstUnexpected = index end
		if repetition.outOfOrder > 0 and sums.firstOutOfOrder == nil then sums.firstOutOfOrder = index end
		if repetition.staleCallbacks > 0 and sums.firstStale == nil then sums.firstStale = index end
		if repetition.observationOverflow and sums.firstOverflow == nil then sums.firstOverflow = index end
		local known = coordinator.repetitions[index]
		if known.isolationPassed == false then
			sums.isolationFailures += 1
			if sums.firstIsolation == nil then sums.firstIsolation = index end
		end
		if repetition.started and not repetition.completed then
			if role == "Sender" then
				submissionCandidates[index] = repetition.firstSubmissionStartedSharedSeconds ~= nil
					and repetition.submitted < caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
			elseif role == "ProbeClient" then
				submissionCandidates[index] = repetition.probeStarted > repetition.probeSubmitted
			end
		end
	end
	if role == "Receiver" and sums.observationOverflow and sums.received ~= observationLimit then return nil end
	local function occurrences(code: string): number
		local fact = factsByCode[code]
		return if fact == nil then 0 else fact.occurrences
	end
	if occurrences("DuplicateDelivery") ~= sums.duplicate
		or occurrences("UnexpectedDelivery") ~= sums.unexpected
		or occurrences("OutOfOrderDelivery") ~= sums.outOfOrder
		or payloadOccurrences ~= sums.mismatch
		or occurrences("StaleCallback") ~= sums.staleCallbacks
		or (factsByCode.DeliveryObservationLimitExceeded ~= nil) ~= sums.observationOverflow
		or occurrences("IsolationFailure") ~= sums.isolationFailures
	then return nil end
	local submitFailure = factsByCode.SubmitFailure
	if submitFailure ~= nil then
		local first = submitFailure.firstRepetition
		if submissionCandidates[first] ~= true then return nil end
		local capacity = 0
		for repetition = first, count do
			if submissionCandidates[repetition] then capacity += 1 end
		end
		if submitFailure.occurrences > capacity then return nil end
	end
	if coordinator.firstMeasuredTrafficRepetition ~= nil
		and factsByCode.ControlTrafficDuringMeasuredFrames == nil
	then return nil end
	for code, first in {
		DuplicateDelivery = sums.firstDuplicate,
		UnexpectedDelivery = sums.firstUnexpected,
		OutOfOrderDelivery = sums.firstOutOfOrder,
		StaleCallback = sums.firstStale,
		DeliveryObservationLimitExceeded = sums.firstOverflow,
		IsolationFailure = sums.firstIsolation,
	} do
		local fact = factsByCode[code]
		if fact ~= nil and fact.firstRepetition ~= first then return nil end
	end
	local conformance = rawget(candidate, "conformance")
	if not exactKeys(conformance, {
		setupExcluded = true, warmupExcluded = true, quiescenceExcluded = true,
		resultExtractionExcluded = true, clockProofPassed = true,
	}) then return nil end
	for _, key in { "setupExcluded", "warmupExcluded", "quiescenceExcluded", "resultExtractionExcluded", "clockProofPassed" } do
		if type(rawget(conformance, key)) ~= "boolean" then return nil end
	end
	if not rawget(conformance, "resultExtractionExcluded")
		or not rawget(conformance, "clockProofPassed")
	then return nil end
	for field, value in {
		setupExcluded = "setup",
		warmupExcluded = "warmup",
		quiescenceExcluded = "quiescence",
	} do
		if (not rawget(conformance, field)) ~= (seenTimingExclusion[value] == true) then return nil end
	end
	local result = {
		version = 1,
		repetitions = repetitions,
		measurements = measurements,
		failureFacts = facts,
		conformance = {
			setupExcluded = rawget(conformance, "setupExcluded"),
			warmupExcluded = rawget(conformance, "warmupExcluded"),
			quiescenceExcluded = rawget(conformance, "quiescenceExcluded"),
			resultExtractionExcluded = rawget(conformance, "resultExtractionExcluded"),
			clockProofPassed = rawget(conformance, "clockProofPassed"),
		},
	}
	deepFreeze(result)
	return result
end

local function newCoordinator(...: any): any
	if select("#", ...) ~= 4 then configError() end
	local bindingCandidate, rosterCandidate, sharedNowSeconds, claimRunId = ...
	local binding, caseDefinition, selection = copyBinding(bindingCandidate, false)
	if type(sharedNowSeconds) ~= "function" or type(claimRunId) ~= "function" then configError() end
	local rosterOk, rosterCount = denseArray(rosterCandidate, MAX_CLIENTS)
	if not rosterOk or rosterCount ~= binding.recipientCount then configError() end
	local roster = table.create(rosterCount)
	for index = 1, rosterCount do
		local token = rawget(rosterCandidate, index)
		if token == nil or not rawequal(token, token) then configError() end
		for prior = 1, index - 1 do
			if rawequal(token, roster[prior]) then configError() end
		end
		roster[index] = token
	end
	local claimOk, claimed = callNonYielding(claimRunId, binding.runId)
	if not claimOk or type(claimed) ~= "boolean" then configError() end
	if not claimed then
		return termination("RunIdCollision", "Preflight")
	end

	local slots = table.create(rosterCount)
	for index = 1, rosterCount do
		slots[index] = {
			token = roster[index],
			participantIndex = index,
			nextOutgoing = 1,
			nextIncoming = 1,
			accepted = 0,
			replays = 0,
			universal = 0,
			muted = false,
			disconnected = false,
			barrier = "NotSent",
			outstanding = nil,
			consumed = {},
			clockBefore = nil,
			armSequence = nil,
			isolationPassed = {},
			warmupInputMutation = false,
		}
	end

	local context: any = {
		phase = "WaitingForParticipants",
		currentRepetition = 0,
		quiet = 0,
		firstMeasuredTrafficRepetition = nil,
		nonRoster = 0,
		terminal = nil,
		disabled = false,
		barrierKind = "BindCase",
		barrierFailure = false,
		barrierClosed = false,
		clockProven = false,
		lastSharedSeconds = nil,
		armEmitted = false,
		finalOutcome = nil,
		finalRepetition = nil,
		repetitions = {},
		executionStage = false,
		caseAbort = false,
		localWarmupInputMutation = false,
		finalReceivedAggregate = 0,
		finalOverflowSeen = false,
	}

	local function stage(): string
		return if context.executionStage then "Execution" else "Setup"
	end

	local function latch(code: string, forcedStage: string?): any
		if context.terminal == nil then
			context.terminal = termination(code, forcedStage or stage())
			context.finalReceivedAggregate = 0
			context.finalOverflowSeen = false
			for index = 1, rosterCount do
				slots[index].outstanding = nil
				slots[index].token = nil
			end
		end
		return context.terminal
	end

	local function findSlot(token: any): any?
		for index = 1, rosterCount do
			if rawequal(token, slots[index].token) then return slots[index] end
		end
		return nil
	end

	local function initBarrier(kind: string)
		context.barrierKind = kind
		context.barrierFailure = false
		context.barrierClosed = false
		for index = 1, rosterCount do
			local slot = slots[index]
			slot.barrier = if slot.disconnected then "Disconnected" else "NotSent"
			slot.outstanding = nil
		end
	end

	local function barrierTerminal(): boolean
		for index = 1, rosterCount do
			local status = slots[index].barrier
			if status == "NotSent" or status == "AwaitingReply" then return false end
		end
		return true
	end

	local function barrierAllAccepted(): boolean
		for index = 1, rosterCount do
			if slots[index].barrier ~= "Settled" then return false end
		end
		return true
	end

	local function cancelUnsent()
		for index = 1, rosterCount do
			local slot = slots[index]
			if slot.barrier == "NotSent" then slot.barrier = "Cancelled" end
		end
	end

	local function closeBarrierIfReady()
		if not barrierTerminal() then return end
		context.barrierClosed = true
		local kind = context.barrierKind
		if kind == "BindCase" then
			context.phase = "Preflight"
		elseif kind == "PrepareRepetition" then
			context.phase = if context.barrierFailure then "AbortPending" else "Ready"
		elseif kind == "ClockChallenge" then
			if context.barrierFailure then
				context.phase = "AbortPending"
			else
				context.clockProven = true
				context.phase = "Ready"
			end
		elseif kind == "BeginWarmup" then
			if context.barrierFailure then
				context.phase = "AbortPending"
			else
				context.phase = "WarmupDrained"
				context.quiet = 0
			end
		elseif kind == "RepetitionReport" then
			-- The trusted boundary method owns the following transition.
		elseif kind == "FinishCase" then
			if context.finalOverflowSeen then
				local started = 0
				local completed = 0
				for repetition = 1, context.currentRepetition do
					local known = context.repetitions[repetition]
					if known.started then started += 1 end
					if known.completed then completed += 1 end
				end
				local cap = checkedMultiply(4, caseDefinition.repetitions)
				cap = if cap == nil then nil else checkedMultiply(cap, caseDefinition.senderCount)
				cap = if cap == nil then nil else checkedMultiply(cap, caseDefinition.measuredFrames)
				cap = if cap == nil then nil else checkedMultiply(cap, caseDefinition.messagesPerFrame)
				cap = if cap == nil then nil else checkedMultiply(cap, binding.recipientCount)
				if not barrierAllAccepted() or context.finalOutcome ~= "Abort" or started <= 0
					or completed >= caseDefinition.repetitions or cap == nil or context.finalReceivedAggregate ~= cap then
					latch("DistributedOverflowUnrepresentable", "Execution")
				end
			end
			context.finalReceivedAggregate = 0
			context.finalOverflowSeen = false
		end
	end

	local function expectedReport(messageType: string, incomingSequence: number, replySequence: number, repetition: number, phaseName: string): any
		local body = commonBody(binding, messageType, incomingSequence, repetition, phaseName)
		body.replyToSequence = replySequence
		return body
	end

	local function consume(slot: any, body: any)
		local sequence = rawget(body, "sequence")
		slot.consumed[sequence] = copyHeader(body)
		slot.nextIncoming += 1
		slot.accepted += 1
		slot.outstanding = nil
		slot.barrier = "Settled"
	end

	local function roleForSlot(_slot: any): string
		if selection.kind == "SeparateProbe" then return "ProbeClient" end
		return if selection.direction == "ClientToServer" then "Sender" else "Receiver"
	end

	local function validateReportBody(body: any, expected: any, slot: any): (any?, boolean)
		local messageType = rawget(body, "messageType")
		if messageType == "BoundReport" then
			return { kind = "BoundReport" }, true
		elseif messageType == "ReadyReport" then
			local outcome = rawget(body, "outcome")
			if outcome ~= "Ready" and outcome ~= "SetupFailure" then return nil, false end
			return { kind = "ReadyReport", outcome = outcome }, true
		elseif messageType == "ClockReply" then
			local shared = rawget(body, "participantSharedSeconds")
			local before = rawget(body, "localBeforeSeconds")
			local after = rawget(body, "localAfterSeconds")
			if not isNonnegativeFinite(shared) or not isNonnegativeFinite(before) or not isNonnegativeFinite(after) or after < before then return nil, false end
			return {
				kind = "ClockReply", participantSharedSeconds = shared,
				localBeforeSeconds = before, localAfterSeconds = after,
			}, true
		elseif messageType == "WarmupReport" then
			local outcome = rawget(body, "outcome")
			if outcome ~= "Clean" and outcome ~= "Dirty" and outcome ~= "InputMutation" then return nil, false end
			if outcome == "InputMutation" and roleForSlot(slot) == "Receiver" then return nil, false end
			return { kind = "WarmupReport", outcome = outcome }, true
		elseif messageType == "RepetitionReport" then
			local outcome = rawget(body, "outcome")
			local isolation = rawget(body, "isolationPassed")
			if (outcome ~= "Clean" and outcome ~= "Invalid" and outcome ~= "Abort") or type(isolation) ~= "boolean" then return nil, false end
			return { kind = "RepetitionReport", outcome = outcome, isolationPassed = isolation }, true
		elseif messageType == "FinalReport" then
			local repetitions = {}
			for index = 1, context.currentRepetition do
				local known = context.repetitions[index]
				repetitions[index] = {
					started = known.started,
					completed = known.completed,
					isolationPassed = slot.isolationPassed[index],
					allowExtraCompletion = index == context.currentRepetition and known.started and not known.completed,
				}
			end
			local warmupMutation = context.localWarmupInputMutation
			for _, participantSlot in slots do
				warmupMutation = warmupMutation or participantSlot.warmupInputMutation
			end
			local snapshotContext = {
				currentRepetition = context.currentRepetition,
				finalRepetition = context.finalRepetition,
				repetitions = repetitions,
				firstMeasuredTrafficRepetition = context.firstMeasuredTrafficRepetition,
				clockProofPassed = context.clockProven,
				warmupInputMutation = slot.warmupInputMutation,
				allowPrestartTeardown = context.finalOutcome == "Abort"
					and context.finalRepetition == 0 and warmupMutation,
			}
			local snapshot = copySnapshot(rawget(body, "snapshot"), roleForSlot(slot), caseDefinition, snapshotContext)
			if snapshot == nil then return nil, false end
			return { kind = "FinalReport", snapshot = snapshot }, true
		end
		return nil, false
	end

	local function command(...: any): any
		if context.terminal ~= nil or context.disabled then stateError() end
		if context.phase == "Measured" then
			if context.firstMeasuredTrafficRepetition == nil then
				context.firstMeasuredTrafficRepetition = context.currentRepetition
			end
			context.caseAbort = true
			return FROZEN_MEASURED
		end
		if select("#", ...) ~= 2 then inputError() end
		local participantIndex = select(1, ...)
		local intent = select(2, ...)
		if not isSafeInteger(participantIndex, 1, rosterCount) or type(intent) ~= "table" or getmetatable(intent) ~= nil then inputError() end
		local kind = rawget(intent, "kind")
		local intentKeys
		if kind == "BindCase" or kind == "ClockChallenge" then intentKeys = { kind = true }
		elseif kind == "PrepareRepetition" or kind == "BeginWarmup" then intentKeys = { kind = true, repetitionIndex = true }
		elseif kind == "ArmMeasured" then intentKeys = { kind = true, repetitionIndex = true, startSharedSeconds = true }
		elseif kind == "FinishCase" then intentKeys = { kind = true, repetitionIndex = true, outcome = true }
		else inputError() end
		if not exactKeys(intent, intentKeys) then inputError() end
		local slot = slots[participantIndex]
		if slot.disconnected or slot.muted then stateError() end
		local repetition = if kind == "BindCase" then 0 elseif kind == "ClockChallenge" then context.currentRepetition else rawget(intent, "repetitionIndex")
		if kind ~= "BindCase" and not isSafeInteger(repetition, if kind == "FinishCase" then 0 else 1, MAX_REPETITIONS) then inputError() end
		local phaseName
		local reportType
		local reportPhase
		if kind == "BindCase" then
			if context.phase ~= "WaitingForParticipants" or context.barrierKind ~= "BindCase" then stateError() end
			phaseName, reportType, reportPhase = "WaitingForParticipants", "BoundReport", "WaitingForParticipants"
		elseif kind == "PrepareRepetition" then
			if context.phase == "Preflight" or (context.phase == "PostTeardownObservation" and context.barrierClosed and not context.caseAbort and barrierAllAccepted()) then
				if repetition ~= context.currentRepetition + 1 or repetition > caseDefinition.repetitions then stateError() end
				context.currentRepetition = repetition
				context.repetitions[repetition] = { started = false, completed = false }
				context.phase = "Preparing"
				initBarrier(kind)
			elseif context.phase ~= "Preparing" or repetition ~= context.currentRepetition then stateError() end
			phaseName, reportType, reportPhase = "Preparing", "ReadyReport", "Ready"
		elseif kind == "ClockChallenge" then
			if repetition ~= 1 or context.currentRepetition ~= 1 then stateError() end
			if context.phase == "Ready" and not context.clockProven and context.barrierKind ~= "ClockChallenge" then
				initBarrier(kind)
			elseif context.phase ~= "Ready" or context.clockProven then stateError() end
			phaseName, reportType, reportPhase = "Ready", "ClockReply", "Ready"
		elseif kind == "BeginWarmup" then
			if repetition ~= context.currentRepetition or (repetition == 1 and not context.clockProven) then stateError() end
			if context.phase == "Ready" and context.barrierKind ~= "BeginWarmup" then
				context.executionStage = true
				context.phase = "Warmup"
				initBarrier(kind)
			elseif context.phase ~= "Warmup" or context.barrierKind ~= "BeginWarmup" then stateError() end
			phaseName, reportType, reportPhase = "Warmup", "WarmupReport", "WarmupDrained"
		elseif kind == "ArmMeasured" then
			if not isNonnegativeFinite(rawget(intent, "startSharedSeconds")) then inputError() end
			if repetition ~= context.currentRepetition or (context.phase ~= "ControlQuiet" and context.phase ~= "ArmedMeasured")
				or context.quiet < QUIET_FRAMES then stateError() end
			if context.barrierKind ~= "ArmMeasured" then initBarrier(kind) end
			phaseName, reportType, reportPhase = "ArmedMeasured", "RepetitionReport", "PostTeardownObservation"
		elseif kind == "FinishCase" then
			local outcome = rawget(intent, "outcome")
			if outcome ~= "Complete" and outcome ~= "Abort" then inputError() end
			if context.phase ~= "ParticipantEvidenceFreezeAndFinalReports" or outcome ~= context.finalOutcome or repetition ~= context.finalRepetition then stateError() end
			phaseName, reportType, reportPhase = "ParticipantEvidenceFreezeAndFinalReports", "FinalReport", "ParticipantEvidenceFreezeAndFinalReports"
		else
			stateError()
		end
		if slot.barrier ~= "NotSent" then stateError() end
		if slot.nextOutgoing > MAX_ACCEPTED then stateError() end
		if kind == "ClockChallenge" then
			local before = readTrustedClock(sharedNowSeconds, context.lastSharedSeconds)
			if before == nil then
				slot.barrier = "Cancelled"
				context.barrierFailure = true
				cancelUnsent()
				closeBarrierIfReady()
				return frozen({ kind = "ClockProofFailed", participantIndex = participantIndex })
			end
			slot.clockBefore = before
			context.lastSharedSeconds = before
		end
		local body = commonBody(binding, kind, slot.nextOutgoing, repetition, phaseName)
		if kind == "BindCase" then body.participantIndex = participantIndex
		elseif kind == "ArmMeasured" then body.startSharedSeconds = rawget(intent, "startSharedSeconds")
		elseif kind == "FinishCase" then body.outcome = rawget(intent, "outcome") end
		deepFreeze(body)
		slot.barrier = if kind == "ArmMeasured" then "Settled" else "AwaitingReply"
		slot.outstanding = if kind == "ArmMeasured" then nil else expectedReport(reportType, slot.nextIncoming, slot.nextOutgoing, repetition, reportPhase)
		if kind == "ArmMeasured" then
			slot.armSequence = slot.nextOutgoing
			context.armEmitted = true
			context.phase = "ArmedMeasured"
		end
		slot.nextOutgoing += 1
		if kind == "ArmMeasured" and barrierTerminal() then context.phase = "Measured" end
		return frozen({ kind = "Ready", body = body })
	end

	local function receive(playerToken: any, ...: any): any
		if context.terminal ~= nil then return context.terminal end
		if context.disabled then return FROZEN_IGNORED end
		local argumentCount = select("#", ...)
		local slot = findSlot(playerToken)
		if context.phase == "Measured" then
			if context.firstMeasuredTrafficRepetition == nil then
				context.firstMeasuredTrafficRepetition = context.currentRepetition
			end
			context.caseAbort = true
			if slot == nil then return FROZEN_MEASURED end
			return frozen({ kind = "MeasuredControlTraffic", participantIndex = slot.participantIndex })
		end
		if context.phase == "WarmupDrained" or context.phase == "ControlQuiet" then context.quiet = 0 end
		if slot == nil then
			context.nonRoster = math.min(context.nonRoster + 1, MAX_NON_ROSTER + 1)
			if context.nonRoster <= MAX_NON_ROSTER then return FROZEN_IGNORED end
			return latch("IngressLimitExceeded")
		end
		if slot.muted then return context.terminal or FROZEN_IGNORED end
		slot.universal = math.min(slot.universal + 1, MAX_UNIVERSAL + 1)
		if slot.universal > MAX_UNIVERSAL then
			slot.muted = true
			return latch("IngressLimitExceeded")
		end
		if argumentCount ~= 1 then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		local body = select(1, ...)
		if type(body) ~= "table" or getmetatable(body) ~= nil then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		if slot.disconnected then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		local messageType = rawget(body, "messageType")
		local spec = if type(messageType) == "string" then rawget(REPORT_SPECS, messageType) else nil
		if spec == nil or not exactKeys(body, mergedKeys(COMMON_KEYS, spec.keys)) or not tupleMatches(body, binding, nil) then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		local sequence = rawget(body, "sequence")
		if not isSafeInteger(sequence, 1) or not isSafeInteger(rawget(body, "repetitionIndex"), 0, MAX_REPETITIONS)
			or not isSafeInteger(rawget(body, "replyToSequence"), 1) or type(rawget(body, "phase")) ~= "string"
		then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		if sequence < slot.nextIncoming then
			local old = slot.consumed[sequence]
			if old == nil or not headerMatches(copyHeader(body), old) then
				slot.muted = true
				return latch("ControlProtocolRejected")
			end
			slot.replays = math.min(slot.replays + 1, MAX_REPLAYS + 1)
			if slot.replays <= MAX_REPLAYS then return FROZEN_IGNORED end
			slot.muted = true
			return latch("IngressLimitExceeded")
		end
		if sequence ~= slot.nextIncoming or slot.outstanding == nil or not headerMatches(copyHeader(body), slot.outstanding) then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		if not preflight(body) then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		local event, valid = validateReportBody(body, slot.outstanding, slot)
		if not valid or event == nil then
			slot.muted = true
			return latch("ControlProtocolRejected")
		end
		if messageType == "WarmupReport" and event.outcome == "Dirty" then
			return latch("WarmupEvidenceRejected", "Execution")
		end
		consume(slot, body)
		if messageType == "FinalReport" and selection.kind == "Workload" and selection.direction == "ServerToClient" then
			local received = 0
			local overflow = false
			for repetition = 1, #event.snapshot.repetitions do
				local evidence = event.snapshot.repetitions[repetition]
				local nextReceived = checkedAdd(received, evidence.received)
				if nextReceived == nil then return latch("DistributedOverflowUnrepresentable", "Execution") end
				received = nextReceived
				overflow = overflow or evidence.observationOverflow
			end
			local aggregate = checkedAdd(context.finalReceivedAggregate, received)
			if aggregate == nil then return latch("DistributedOverflowUnrepresentable", "Execution") end
			context.finalReceivedAggregate = aggregate
			context.finalOverflowSeen = context.finalOverflowSeen or overflow
		end
		if messageType == "ReadyReport" and event.outcome == "SetupFailure" then
			context.barrierFailure = true
			cancelUnsent()
		elseif messageType == "WarmupReport" and event.outcome == "InputMutation" then
			slot.warmupInputMutation = true
			context.barrierFailure = true
			context.caseAbort = true
			cancelUnsent()
		elseif messageType == "ClockReply" then
			local after = readTrustedClock(sharedNowSeconds, context.lastSharedSeconds)
			if after ~= nil then context.lastSharedSeconds = after end
			if after == nil or event.participantSharedSeconds < slot.clockBefore or event.participantSharedSeconds > after then
				context.barrierFailure = true
				cancelUnsent()
				closeBarrierIfReady()
				return frozen({ kind = "ClockProofFailed", participantIndex = slot.participantIndex })
			end
		elseif messageType == "RepetitionReport" and event.outcome == "Abort" then
			context.barrierFailure = true
			context.caseAbort = true
		end
		if messageType == "RepetitionReport" then slot.isolationPassed[context.currentRepetition] = event.isolationPassed end
		closeBarrierIfReady()
		if context.terminal ~= nil then return context.terminal end
		return frozen({ kind = "Accepted", participantIndex = slot.participantIndex, event = event })
	end

	local function disconnect(...: any): any
		if context.terminal ~= nil or context.disabled then return FROZEN_IGNORED end
		if select("#", ...) ~= 1 then inputError() end
		local slot = findSlot(select(1, ...))
		if slot == nil or slot.disconnected then return FROZEN_IGNORED end
		slot.disconnected = true
		if context.phase == "WaitingForParticipants" then
			slot.barrier = "Disconnected"
			for index = 1, rosterCount do
				local other = slots[index]
				if other ~= slot and (other.barrier == "NotSent" or other.barrier == "AwaitingReply") then
					other.barrier = "Cancelled"
					other.outstanding = nil
				end
			end
			return latch("ControlProtocolRejected", "Setup")
		end
		if context.phase == "Warmup" or context.phase == "WarmupDrained" or context.phase == "ControlQuiet" then
			return latch("WarmupEvidenceRejected", "Execution")
		end
		local current = context.repetitions[context.currentRepetition]
		if context.armEmitted or (current ~= nil and current.started) then
			context.caseAbort = true
		end
		if (context.barrierKind == "PrepareRepetition" or context.barrierKind == "ClockChallenge")
			and not context.barrierClosed
			and (slot.barrier == "AwaitingReply" or slot.barrier == "Settled")
		then
			slot.barrier = "Disconnected"
			slot.outstanding = nil
			context.barrierFailure = true
			cancelUnsent()
			closeBarrierIfReady()
			if context.terminal ~= nil then return context.terminal end
		elseif slot.barrier == "AwaitingReply" then
			slot.barrier = "Disconnected"
			slot.outstanding = nil
			context.barrierFailure = true
			closeBarrierIfReady()
			if context.terminal ~= nil then return context.terminal end
		elseif context.barrierKind == "ArmMeasured" and (context.phase == "ArmedMeasured" or context.phase == "Measured") then
			slot.barrier = "Disconnected"
			context.caseAbort = true
			if barrierTerminal() then context.phase = "Measured" end
		elseif context.phase == "ParticipantEvidenceFreezeAndFinalReports" and context.barrierKind == "FinishCase" and slot.barrier == "NotSent" then
			slot.barrier = "Disconnected"
			context.caseAbort = true
			closeBarrierIfReady()
			if context.terminal ~= nil then return context.terminal end
		elseif context.phase == "Preflight" or context.phase == "Preparing" or context.phase == "Ready" then
			context.phase = "AbortPending"
		end
		return frozen({ kind = "Disconnected", participantIndex = slot.participantIndex })
	end

	local function expireResponse(...: any): any
		if context.terminal ~= nil or context.disabled then stateError() end
		if select("#", ...) ~= 1 or not isSafeInteger(select(1, ...), 1, rosterCount) then inputError() end
		local slot = slots[select(1, ...)]
		if slot.outstanding == nil or slot.barrier ~= "AwaitingReply" then stateError() end
		local expiredHeader = copyHeader(slot.outstanding)
		slot.consumed[slot.nextIncoming] = expiredHeader
		slot.nextIncoming += 1
		slot.outstanding = nil
		slot.barrier = "Expired"
		context.barrierFailure = true
		if context.barrierKind == "BindCase" then
			for index = 1, rosterCount do
				local other = slots[index]
				if other ~= slot and (other.barrier == "NotSent" or other.barrier == "AwaitingReply") then
					other.barrier = "Cancelled"
					other.outstanding = nil
				end
			end
			return latch("ControlProtocolRejected", "Setup")
		elseif context.barrierKind == "BeginWarmup" then
			return latch("WarmupEvidenceRejected", "Execution")
		elseif context.barrierKind == "PrepareRepetition" or context.barrierKind == "ClockChallenge" then
			cancelUnsent()
		end
		if context.barrierKind == "RepetitionReport" or context.barrierKind == "FinishCase" then context.caseAbort = true end
		closeBarrierIfReady()
		if context.terminal ~= nil then return context.terminal end
		return FROZEN_READY
	end

	local function postSimulation(...: any): boolean
		if context.terminal ~= nil or context.disabled or context.phase == "Measured" then return false end
		if select("#", ...) ~= 0 then inputError() end
		if context.phase ~= "WarmupDrained" and context.phase ~= "ControlQuiet" then return false end
		context.phase = "ControlQuiet"
		context.quiet = math.min(context.quiet + 1, QUIET_FRAMES)
		return context.quiet >= QUIET_FRAMES
	end

	local function beginPostTeardownObservation(...: any): any
		if context.terminal ~= nil or context.disabled then stateError() end
		if select("#", ...) ~= 3 then inputError() end
		local repetition = select(1, ...)
		local started = select(2, ...)
		local completed = select(3, ...)
		if not isSafeInteger(repetition, 1, MAX_REPETITIONS) or type(started) ~= "boolean" or type(completed) ~= "boolean" then inputError() end
		if repetition ~= context.currentRepetition or not context.armEmitted
			or (context.phase ~= "ArmedMeasured" and context.phase ~= "Measured") then stateError() end
		if not started then return latch("ControlProtocolRejected", "Execution") end
		if context.phase ~= "Measured" then stateError() end
		context.repetitions[repetition].started = true
		context.repetitions[repetition].completed = completed
		if not completed then context.caseAbort = true end
		context.phase = "PostTeardownObservation"
		initBarrier("RepetitionReport")
		for index = 1, rosterCount do
			local slot = slots[index]
			if not slot.disconnected then
				if slot.armSequence == nil then stateError() end
				slot.barrier = "AwaitingReply"
				slot.outstanding = expectedReport("RepetitionReport", slot.nextIncoming, slot.armSequence, repetition, "PostTeardownObservation")
			end
		end
		context.armEmitted = false
		closeBarrierIfReady()
		return FROZEN_READY
	end

	local function beginFinalReports(...: any): any
		if context.terminal ~= nil or context.disabled then stateError() end
		local argumentCount = select("#", ...)
		if argumentCount ~= 2 and argumentCount ~= 3 then inputError() end
		local outcome = select(1, ...)
		local reached = select(2, ...)
		local cause = if argumentCount == 3 then select(3, ...) else nil
		if (outcome ~= "Complete" and outcome ~= "Abort") or not isSafeInteger(reached, 0, MAX_REPETITIONS) then inputError() end
		if argumentCount == 3 and (cause ~= "InputMutation" or outcome ~= "Abort" or reached ~= 0) then inputError() end
		if cause == "InputMutation" then
			if selection.kind == "Workload" and selection.direction ~= "ServerToClient" then stateError() end
			if context.phase ~= "Warmup" and context.phase ~= "WarmupDrained" and context.phase ~= "ControlQuiet" then stateError() end
			for index = 1, rosterCount do
				if slots[index].outstanding ~= nil then stateError() end
			end
			context.localWarmupInputMutation = true
			context.caseAbort = true
			context.phase = "AbortPending"
		elseif context.phase == "Warmup" or context.phase == "WarmupDrained" or context.phase == "ControlQuiet" then
			return latch("WarmupEvidenceRejected", "Execution")
		end
		if outcome == "Abort" and reached == 0 then
			if context.currentRepetition ~= 0 and context.repetitions[context.currentRepetition] ~= nil
				and context.repetitions[context.currentRepetition].started then stateError() end
			if context.phase ~= "Preflight" and context.phase ~= "Preparing" and context.phase ~= "Ready" and context.phase ~= "AbortPending" then stateError() end
			for index = 1, rosterCount do
				if slots[index].outstanding ~= nil then stateError() end
			end
		elseif reached > 0 then
			if context.phase ~= "PostTeardownObservation" or not context.barrierClosed or reached ~= context.currentRepetition then stateError() end
			if outcome == "Complete" then
				if reached ~= caseDefinition.repetitions or not barrierAllAccepted()
					or not context.repetitions[reached].completed or context.caseAbort then stateError() end
			end
		else
			stateError()
		end
		context.phase = "ParticipantEvidenceFreezeAndFinalReports"
		context.finalOutcome = outcome
		context.finalRepetition = reached
		initBarrier("FinishCase")
		return FROZEN_READY
	end

	local function disable(...: any)
		if select("#", ...) ~= 0 then inputError() end
		if context.disabled then return end
		context.disabled = true
		context.finalReceivedAggregate = 0
		context.finalOverflowSeen = false
		for index = 1, rosterCount do
			slots[index].outstanding = nil
			slots[index].consumed = {}
			slots[index].token = nil
		end
	end

	local coordinator = {
		command = command,
		receive = receive,
		postSimulation = postSimulation,
		beginPostTeardownObservation = beginPostTeardownObservation,
		beginFinalReports = beginFinalReports,
		expireResponse = expireResponse,
		disconnect = disconnect,
		disable = disable,
	}
	table.freeze(coordinator)
	return frozen({ kind = "Ready", coordinator = coordinator })
end

local function newParticipant(...: any): any
	if select("#", ...) ~= 1 then configError() end
	local bindingCandidate = select(1, ...)
	local binding, caseDefinition, selection = copyBinding(bindingCandidate, true)
	local role = if selection.kind == "SeparateProbe" then "ProbeClient"
		elseif selection.direction == "ClientToServer" then "Sender" else "Receiver"
	local state: any = {
		phase = "WaitingForParticipants",
		currentRepetition = 0,
		nextIncoming = 1,
		nextOutgoing = 1,
		lastCommand = nil,
		expectedReport = nil,
		quiet = 0,
		clockProven = false,
		firstMeasuredTrafficRepetition = nil,
		muted = false,
		disabled = false,
		repetitionReportSent = false,
		finalOutcome = nil,
		finalRepetition = nil,
		repetitions = {},
		caseAbort = false,
		warmupInputMutation = false,
		allowPrestartTeardown = false,
	}

	local function mute(): any
		state.muted = true
		state.expectedReport = nil
		return FROZEN_MUTED
	end

	local function receive(...: any): any
		if state.muted or state.disabled then return FROZEN_MUTED end
		if state.phase == "Measured" then
			if state.firstMeasuredTrafficRepetition == nil then
				state.firstMeasuredTrafficRepetition = state.currentRepetition
			end
			state.caseAbort = true
			return FROZEN_MEASURED
		end
		if select("#", ...) ~= 1 then return mute() end
		local body = select(1, ...)
		if type(body) ~= "table" or getmetatable(body) ~= nil then return mute() end
		local messageType = rawget(body, "messageType")
		local spec = if type(messageType) == "string" then rawget(COMMAND_SPECS, messageType) else nil
		if spec == nil or not exactKeys(body, mergedKeys(COMMON_KEYS, spec.keys)) or not tupleMatches(body, binding, if messageType == "BindCase" then binding.participantIndex else nil)
			or not isSafeInteger(rawget(body, "sequence"), 1) or rawget(body, "sequence") ~= state.nextIncoming
			or not isSafeInteger(rawget(body, "repetitionIndex"), 0, MAX_REPETITIONS)
			or rawget(body, "phase") ~= spec.phase or not preflight(body)
		then return mute() end
		local repetition = rawget(body, "repetitionIndex")
		local action
		if messageType == "BindCase" then
			if state.phase ~= "WaitingForParticipants" or repetition ~= 0 then return mute() end
			state.phase = "Preflight"
			state.expectedReport = "BoundReport"
			action = { kind = "BindCase", participantIndex = binding.participantIndex }
		elseif messageType == "PrepareRepetition" then
			if (state.phase ~= "Preflight" and state.phase ~= "PostTeardownObservation")
				or (state.phase == "PostTeardownObservation" and not state.repetitionReportSent)
				or (state.phase == "PostTeardownObservation" and state.caseAbort)
				or repetition ~= state.currentRepetition + 1 or repetition > caseDefinition.repetitions then return mute() end
			state.currentRepetition = repetition
			state.repetitions[repetition] = { started = false, completed = false }
			state.phase = "Preparing"
			state.expectedReport = "ReadyReport"
			state.repetitionReportSent = false
			action = { kind = "PrepareRepetition" }
		elseif messageType == "ClockChallenge" then
			if state.phase ~= "Ready" or repetition ~= 1 or state.currentRepetition ~= 1 or state.clockProven then return mute() end
			state.expectedReport = "ClockReply"
			action = { kind = "ClockChallenge" }
		elseif messageType == "BeginWarmup" then
			if state.phase ~= "Ready" or repetition ~= state.currentRepetition or (repetition == 1 and not state.clockProven) then return mute() end
			state.phase = "Warmup"
			state.expectedReport = "WarmupReport"
			action = { kind = "BeginWarmup" }
		elseif messageType == "ArmMeasured" then
			local start = rawget(body, "startSharedSeconds")
			if state.phase ~= "ControlQuiet" or state.quiet < QUIET_FRAMES or repetition ~= state.currentRepetition or not isNonnegativeFinite(start) then return mute() end
			state.phase = "Measured"
			state.expectedReport = nil
			state.repetitions[repetition].started = true
			action = { kind = "ArmMeasured", startSharedSeconds = start }
		elseif messageType == "FinishCase" then
			local outcome = rawget(body, "outcome")
			if outcome ~= "Complete" and outcome ~= "Abort" then return mute() end
			local valid = false
			if outcome == "Abort" and repetition == 0 then
				local current = state.repetitions[state.currentRepetition]
				valid = (current == nil or not current.started)
					and (state.phase == "Preflight" or state.phase == "Preparing" or state.phase == "Ready" or state.phase == "AbortPending")
				if not valid and (state.phase == "WarmupDrained" or state.phase == "ControlQuiet") then
					valid = current ~= nil and not current.started
				end
			elseif repetition > 0 and state.phase == "PostTeardownObservation" and state.repetitionReportSent and repetition == state.currentRepetition then
				valid = outcome == "Abort" or (outcome == "Complete" and repetition == caseDefinition.repetitions and not state.caseAbort)
			end
			if not valid then return mute() end
			state.allowPrestartTeardown = outcome == "Abort" and repetition == 0
				and (state.phase == "WarmupDrained" or state.phase == "ControlQuiet")
			state.phase = "ParticipantEvidenceFreezeAndFinalReports"
			state.finalOutcome = outcome
			state.finalRepetition = repetition
			state.expectedReport = "FinalReport"
			action = { kind = "FinishCase", outcome = outcome }
		else
			return mute()
		end
		state.lastCommand = rawget(body, "sequence")
		state.nextIncoming += 1
		return frozen({ kind = "Accepted", command = action })
	end

	local function report(...: any): any
		if state.muted or state.disabled then return FROZEN_MUTED end
		if state.phase == "Measured" then
			if state.firstMeasuredTrafficRepetition == nil then
				state.firstMeasuredTrafficRepetition = state.currentRepetition
			end
			state.caseAbort = true
			return FROZEN_MEASURED
		end
		if select("#", ...) ~= 1 then inputError() end
		local intent = select(1, ...)
		if type(intent) ~= "table" or getmetatable(intent) ~= nil then inputError() end
		local kind = rawget(intent, "kind")
		local keys
		if kind == "BoundReport" then keys = { kind = true }
		elseif kind == "ReadyReport" or kind == "WarmupReport" then keys = { kind = true, outcome = true }
		elseif kind == "ClockReply" then keys = {
			kind = true, participantSharedSeconds = true, localBeforeSeconds = true, localAfterSeconds = true,
		}
		elseif kind == "RepetitionReport" then keys = { kind = true, outcome = true, isolationPassed = true }
		elseif kind == "FinalReport" then keys = { kind = true, snapshot = true }
		else inputError() end
		if not exactKeys(intent, keys) then inputError() end
		if kind ~= state.expectedReport or state.lastCommand == nil or state.nextOutgoing > MAX_ACCEPTED then stateError() end
		local phaseName = REPORT_SPECS[kind].phase
		local repetition = if kind == "BoundReport" then 0 elseif kind == "FinalReport" then state.finalRepetition else state.currentRepetition
		local body = commonBody(binding, kind, state.nextOutgoing, repetition, phaseName)
		body.replyToSequence = state.lastCommand
		if kind == "ReadyReport" then
			local outcome = rawget(intent, "outcome")
			if outcome ~= "Ready" and outcome ~= "SetupFailure" then inputError() end
			body.outcome = outcome
			state.phase = if outcome == "SetupFailure" then "AbortPending" else "Ready"
		elseif kind == "ClockReply" then
			local shared = rawget(intent, "participantSharedSeconds")
			local before = rawget(intent, "localBeforeSeconds")
			local after = rawget(intent, "localAfterSeconds")
			if not isNonnegativeFinite(shared) or not isNonnegativeFinite(before) or not isNonnegativeFinite(after) or after < before then inputError() end
			body.participantSharedSeconds, body.localBeforeSeconds, body.localAfterSeconds = shared, before, after
			state.clockProven = true
			state.phase = "Ready"
		elseif kind == "WarmupReport" then
			local outcome = rawget(intent, "outcome")
			if outcome ~= "Clean" and outcome ~= "Dirty" and outcome ~= "InputMutation" then inputError() end
			if outcome == "InputMutation" and role == "Receiver" then inputError() end
			body.outcome = outcome
			if outcome == "InputMutation" then
				state.warmupInputMutation = true
				state.caseAbort = true
				state.phase = "AbortPending"
			else
				state.phase = "WarmupDrained"
				state.quiet = 0
			end
		elseif kind == "RepetitionReport" then
			local outcome = rawget(intent, "outcome")
			local isolation = rawget(intent, "isolationPassed")
			if (outcome ~= "Clean" and outcome ~= "Invalid" and outcome ~= "Abort") or type(isolation) ~= "boolean" then inputError() end
			body.outcome, body.isolationPassed = outcome, isolation
			state.repetitionReportSent = true
			state.repetitions[state.currentRepetition].completed = outcome == "Clean" or outcome == "Invalid"
			state.repetitions[state.currentRepetition].isolationPassed = isolation
			if outcome == "Abort" then state.caseAbort = true end
		elseif kind == "FinalReport" then
			local mirror = {
				currentRepetition = state.finalRepetition,
				repetitions = state.repetitions,
				firstMeasuredTrafficRepetition = state.firstMeasuredTrafficRepetition,
				clockProofPassed = state.clockProven,
				warmupInputMutation = state.warmupInputMutation,
				allowPrestartTeardown = state.allowPrestartTeardown,
			}
			local snapshot = copySnapshot(rawget(intent, "snapshot"), role, caseDefinition, mirror)
			if snapshot == nil then inputError() end
			body.snapshot = snapshot
		end
		deepFreeze(body)
		state.expectedReport = nil
		state.nextOutgoing += 1
		return frozen({ kind = "Ready", body = body })
	end

	local function postSimulation(...: any): boolean
		if state.muted or state.disabled or state.phase == "Measured" then return false end
		if select("#", ...) ~= 0 then inputError() end
		if state.phase ~= "WarmupDrained" and state.phase ~= "ControlQuiet" then return false end
		state.phase = "ControlQuiet"
		state.quiet = math.min(state.quiet + 1, QUIET_FRAMES)
		return state.quiet >= QUIET_FRAMES
	end

	local function beginPostTeardownObservation(...: any)
		if state.muted or state.disabled then stateError() end
		if select("#", ...) ~= 1 or not isSafeInteger(select(1, ...), 1, MAX_REPETITIONS) then inputError() end
		local repetition = select(1, ...)
		if state.phase ~= "Measured" or repetition ~= state.currentRepetition then stateError() end
		state.phase = "PostTeardownObservation"
		state.expectedReport = "RepetitionReport"
	end

	local function disable(...: any)
		if select("#", ...) ~= 0 then inputError() end
		state.disabled = true
		state.expectedReport = nil
		state.lastCommand = nil
	end

	local participant = {
		receive = receive,
		report = report,
		postSimulation = postSimulation,
		beginPostTeardownObservation = beginPostTeardownObservation,
		disable = disable,
	}
	table.freeze(participant)
	return participant
end

local ControlProtocol = {
	newCoordinator = newCoordinator,
	newParticipant = newParticipant,
}

table.freeze(ControlProtocol)

return ControlProtocol
