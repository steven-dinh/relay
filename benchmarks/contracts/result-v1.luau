--!strict

local Contract = require("./event-v1")
local Identity = require("./internal/AdapterIdentity")

export type RepositoryProvenance = Identity.RepositoryProvenance
export type EngineBuiltInProvenance = Identity.EngineBuiltInProvenance
export type AdapterIdentity = Identity.AdapterIdentity
export type WorkloadCase = {
	kind: "Workload", workloadId: string, senderCount: number, recipientCount: number,
	scheduledRepetitions: number, startedRepetitions: number, completedRepetitions: number,
}
export type SeparateProbeCase = {
	kind: "SeparateProbe", probeId: string, clientCount: number,
	scheduledRepetitions: number, startedRepetitions: number, completedRepetitions: number,
}
export type Counts = {
	finality: "Final" | "Partial" | "NotStarted",
	expectedSubmissions: number, submitted: number, expectedDeliveries: number, received: number,
	correct: number, missing: number, duplicate: number, unexpected: number, outOfOrder: number, mismatch: number,
}
export type ComparatorReason =
	"WrongContainerType" | "ArityMismatch" | "MissingField" | "ExtraField" | "WrongType"
	| "NonFinite" | "NonInteger" | "OutOfRange" | "NotFloat32" | "ValueMismatch"
export type FailureCode =
	"SubmissionShortfall" | "MissingDelivery" | "DuplicateDelivery" | "UnexpectedDelivery"
	| "OutOfOrderDelivery" | "PayloadMismatch" | "UnsupportedCapability"
	| "AddedDeliveryFrameLimitExceeded" | "ControlTrafficDuringMeasuredFrames"
	| "TimingExclusionViolation" | "IsolationFailure" | "StaleCallback"
	| "DeliveryObservationLimitExceeded" | "SetupFailure" | "SubmitFailure" | "Timeout"
	| "Disconnect" | "TeardownFailure" | "RequiredMeasurementUnavailable"
	| "ClockProofFailure" | "InternalError"
export type FailureDiscriminator =
	{ mismatchReason: ComparatorReason }
	| { capability: "Direction" | "DeliverySemantics" | "Payload" | "BroadcastMode", required: string }
	| { exclusion: "setup" | "warmup" | "quiescence" | "resultExtraction" }
	| { measurementId: string }
	| { stage: "Preflight" | "Setup" | "Execution" | "Finalize" }
export type PayloadComparatorMismatch = {
	path: string, reason: ComparatorReason, expectedPresent: boolean, actualPresent: boolean,
	expected: (boolean | number)?, actual: (boolean | number)?,
}
export type FirstOccurrence = {
	repetitionIndex: number,
	participant: { role: "Coordinator" } | { role: "Sender" | "Recipient" | "ProbeClient", index: number },
	mismatch: PayloadComparatorMismatch?,
}
export type Failure = {
	category: "Correctness" | "Capability" | "Contract" | "Lifecycle" | "Measurement" | "Harness",
	code: FailureCode,
	occurrences: number,
	discriminator: FailureDiscriminator?,
	firstOccurrence: FirstOccurrence?,
}
export type RawSampleGroup = { repetitionIndex: number, participantIndex: number?, values: { number } }
export type UnavailableReason = {
	code: "NotSupportedByAdapter" | "UnavailableInEnvironment" | "CaptureFailed" | "CaseUnsupported" | "CaseNotCompleted" | "ResultUntrusted",
}
export type MeasurementDraft =
	{ id: string, state: "Available" | "Diagnostic", rawSamples: { RawSampleGroup } }
	| { id: string, state: "Unavailable", unavailableReason: UnavailableReason }
export type ExactSummary = { kind: "Exact", sampleCount: number, total: number }
export type MedianAndP95Summary = { kind: "MedianAndP95", sampleCount: number, median: number, p95: number }
export type Measurement =
	{ metadata: typeof(Contract.measurements[1]), state: "Available", rawSamples: { RawSampleGroup }, summary: ExactSummary | MedianAndP95Summary }
	| { metadata: typeof(Contract.measurements[1]), state: "Diagnostic", rawSamples: { RawSampleGroup } }
	| { metadata: typeof(Contract.measurements[1]), state: "Unavailable", unavailableReason: UnavailableReason }
export type Conformance = {
	timingExclusionsConfirmed: { setup: boolean, warmup: boolean, quiescence: boolean, resultExtraction: boolean },
	localClock: { source: "os.clock", unit: "seconds", scope: "SingleParticipant", quality: "Direct" },
	sharedClock: { source: "Workspace:GetServerTimeNow", unit: "seconds", scope: "CrossParticipant", quality: "EngineApproximation" },
	clockProof: { version: number, passed: boolean },
}
export type Environment = {
	studio: { version: string, channel: string? },
	host: {
		osFamily: "Windows" | "macOS", architecture: "x86_64" | "arm64", osVersion: string?,
		cpuModel: string?, logicalProcessorCount: number?, memoryMiB: number?, gpuModel: string?,
	},
	execution: { mode: "StudioMultiplayer", targetFrameRate: number, serverCount: number, clientCount: number },
}
export type ResultDraft = {
	runId: string,
	benchmarkSource: { revision: string, dirty: boolean },
	contractFingerprint: string,
	adapter: AdapterIdentity,
	case: WorkloadCase | SeparateProbeCase,
	failures: { Failure },
	counts: Counts?,
	conformance: Conformance,
	measurements: { MeasurementDraft },
	environment: Environment,
}
export type Result = {
	schema: { id: "result-v1", version: number },
	runId: string,
	benchmark: { id: "relay-event", version: number, source: { revision: string, dirty: boolean } },
	contract: { id: "event-v1", version: number, fingerprint: string },
	adapter: AdapterIdentity,
	case: WorkloadCase | SeparateProbeCase,
	status: "Valid" | "Invalid" | "Unsupported" | "Error",
	failures: { Failure },
	counts: Counts?,
	conformance: Conformance,
	measurements: { Measurement },
	environment: Environment,
}

local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local MAX_DEPTH = 6
local MAX_TABLE_NODES = 4_096
local MAX_TABLE_ENTRIES = 131_072
local MAX_ARRAY_ENTRIES = 1_000
local MAX_RAW_WORKLOAD = 60_870
local MAX_RAW_PROBE = 3_600
local MAX_FAILURES = 38
local FLOAT32_BUFFER = buffer.create(4)

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
	UnsupportedCapability = "Capability",
	AddedDeliveryFrameLimitExceeded = "Contract",
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

local COMPARATOR_REASONS = {
	WrongContainerType = true,
	ArityMismatch = true,
	MissingField = true,
	ExtraField = true,
	WrongType = true,
	NonFinite = true,
	NonInteger = true,
	OutOfRange = true,
	NotFloat32 = true,
	ValueMismatch = true,
}

local COMPARATOR_REASON_ORDER = {
	WrongContainerType = 1, ArityMismatch = 2, MissingField = 3, ExtraField = 4, WrongType = 5,
	NonFinite = 6, NonInteger = 7, OutOfRange = 8, NotFloat32 = 9, ValueMismatch = 10,
}
local CAPABILITY_ORDER = { Direction = 1, DeliverySemantics = 2, Payload = 3, BroadcastMode = 4 }
local EXCLUSION_ORDER = { setup = 1, warmup = 2, quiescence = 3, resultExtraction = 4 }
local STAGE_ORDER = { Preflight = 1, Setup = 2, Execution = 3, Finalize = 4 }
local ROLE_ORDER = { Coordinator = 1, Sender = 2, Recipient = 3, ProbeClient = 4 }

local UNAVAILABLE_CODES = {
	NotSupportedByAdapter = true,
	UnavailableInEnvironment = true,
	CaptureFailed = true,
	CaseUnsupported = true,
	CaseNotCompleted = true,
	ResultUntrusted = true,
}

local function reject(code: string, path: string): never
	error(code .. ":" .. path, 0)
end

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: number): boolean
	return value == 0 and 1 / value == -math.huge
end

local function safeInteger(value: any, path: string, positive: boolean?): number
	if type(value) ~= "number" then
		reject("RESULT_E_TYPE", path)
	end
	if not isFinite(value) or isNegativeZero(value) or value % 1 ~= 0 or value < (if positive then 1 else 0) or value > MAX_SAFE_INTEGER then
		reject("RESULT_E_RANGE", path)
	end
	return value
end

local function checkedAdd(left: number, right: number, path: string): number
	if left > MAX_SAFE_INTEGER - right then
		reject("RESULT_E_ARITHMETIC", path)
	end
	return left + right
end

local function checkedMultiply(left: number, right: number, path: string): number
	if left ~= 0 and right > MAX_SAFE_INTEGER / left then
		reject("RESULT_E_ARITHMETIC", path)
	end
	return left * right
end

local function expectType(value: any, expected: string, path: string): any
	if type(value) ~= expected then
		reject("RESULT_E_TYPE", path)
	end
	return value
end

local function expectEnum(value: any, values: { [string]: boolean }, path: string): string
	if type(value) ~= "string" then
		reject("RESULT_E_TYPE", path)
	end
	if values[value] == nil then
		reject("RESULT_E_ENUM", path)
	end
	return value
end

local function exactKeys(value: any, keys: { [string]: boolean }, path: string): { [any]: any }
	if type(value) ~= "table" then
		reject("RESULT_E_TYPE", path)
	end
	local found = 0
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or keys[key] ~= true then
			reject("RESULT_E_KEYSET", path)
		end
		found += 1
		key = next(value, key)
	end
	local required = 0
	for _ in keys do
		required += 1
	end
	if found ~= required then
		reject("RESULT_E_KEYSET", path)
	end
	return value
end

local function exactConditionalKeys(
	value: any,
	required: { [string]: boolean },
	optional: { [string]: boolean },
	path: string
): { [any]: any }
	if type(value) ~= "table" then
		reject("RESULT_E_TYPE", path)
	end
	for key in required do
		if rawget(value, key) == nil then
			reject("RESULT_E_KEYSET", path)
		end
	end
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or (required[key] ~= true and optional[key] ~= true) then
			reject("RESULT_E_KEYSET", path)
		end
		key = next(value, key)
	end
	return value
end

local function denseArray(value: any, maximum: number, path: string): ({ any }, number)
	if type(value) ~= "table" then
		reject("RESULT_E_TYPE", path)
	end
	local count = 0
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			reject("RESULT_E_KEYSET", path)
		end
		if key > maximum then
			reject("RESULT_E_LIMIT", path)
		end
		count += 1
		key = next(value, key)
	end
	if count > maximum then
		reject("RESULT_E_LIMIT", path)
	end
	for index = 1, count do
		if rawget(value, index) == nil then
			reject("RESULT_E_KEYSET", path)
		end
	end
	return value, count
end

local function preflight(root: any)
	local seen: { [table]: string } = {}
	local nodeCount = 0
	local entryCount = 0

	local function visit(value: any, depth: number, path: string)
		if type(value) ~= "table" then
			return
		end
		if getmetatable(value) ~= nil then
			reject("RESULT_E_METATABLE", path)
		end
		local state = seen[value]
		if state == "active" then
			reject("RESULT_E_CYCLE", path)
		elseif state ~= nil then
			reject("RESULT_E_ALIAS", path)
		end
		if depth > MAX_DEPTH then
			reject("RESULT_E_LIMIT", path)
		end
		nodeCount += 1
		if nodeCount > MAX_TABLE_NODES then
			reject("RESULT_E_LIMIT", path)
		end
		seen[value] = "active"
		local key = next(value)
		while key ~= nil do
			entryCount += 1
			if entryCount > MAX_TABLE_ENTRIES then
				reject("RESULT_E_LIMIT", path)
			end
			visit(key, depth + 1, path)
			visit(rawget(value, key), depth + 1, path)
			key = next(value, key)
		end
		seen[value] = "done"
	end

	visit(root, 1, "$")
end

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for _, nested in value do
		deepFreeze(nested)
	end
	table.freeze(value)
end

local function printableAscii(value: any, minimum: number, maximum: number, path: string): string
	if type(value) ~= "string" then
		reject("RESULT_E_TYPE", path)
	end
	if #value < minimum or #value > maximum then
		reject("RESULT_E_RANGE", path)
	end
	for index = 1, #value do
		local byte = string.byte(value, index)
		if byte < 32 or byte > 126 then
			reject("RESULT_E_RANGE", path)
		end
	end
	return value
end

local function normalizedLabel(value: any, maximum: number, path: string, normalize: boolean): string
	local label = printableAscii(value, 1, maximum, path)
	local canonical = string.gsub(string.gsub(label, "^ +", ""), " +$", "")
	canonical = string.gsub(canonical, " +", " ")
	if #canonical == 0 then
		reject("RESULT_E_RANGE", path)
	end
	if not normalize and label ~= canonical then
		reject("RESULT_E_NONCANONICAL", path)
	end
	return canonical
end

local function token(value: any, maximum: number, path: string): string
	if type(value) ~= "string" or #value < 1 or #value > maximum or string.match(value, "^[A-Za-z0-9._-]+$") == nil then
		reject(if type(value) == "string" then "RESULT_E_RANGE" else "RESULT_E_TYPE", path)
	end
	return value
end

local function machineId(value: any, path: string): string
	if type(value) ~= "string" or #value < 1 or #value > 64 or string.match(value, "^[a-z0-9][a-z0-9._-]*$") == nil then
		reject(if type(value) == "string" then "RESULT_E_RANGE" else "RESULT_E_TYPE", path)
	end
	return value
end

local function lowercaseHex(value: any, lengths: { number }, path: string): string
	if type(value) ~= "string" then
		reject("RESULT_E_TYPE", path)
	end
	local allowed = false
	for _, length in lengths do
		if #value == length then
			allowed = true
		end
	end
	if not allowed or string.match(value, "^[0-9a-f]+$") == nil then
		reject("RESULT_E_RANGE", path)
	end
	return value
end

local function sha256(value: any, path: string): string
	if type(value) ~= "string" or #value ~= 71 or string.sub(value, 1, 7) ~= "sha256:" or string.match(string.sub(value, 8), "^[0-9a-f]+$") == nil then
		reject(if type(value) == "string" then "RESULT_E_RANGE" else "RESULT_E_TYPE", path)
	end
	return value
end

local function uuid(value: any, path: string): string
	if type(value) ~= "string" or string.match(value, "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") == nil then
		reject(if type(value) == "string" then "RESULT_E_RANGE" else "RESULT_E_TYPE", path)
	end
	return value
end

local function copyCase(value: any, path: string): (any, any)
	if type(value) ~= "table" then
		reject("RESULT_E_TYPE", path)
	end
	local kind = rawget(value, "kind")
	if kind == "Workload" then
		exactKeys(value, { kind = true, workloadId = true, senderCount = true, recipientCount = true, scheduledRepetitions = true, startedRepetitions = true, completedRepetitions = true }, path)
		local workloadId = machineId(rawget(value, "workloadId"), path .. ".workloadId")
		local workload = nil
		for _, candidate in Contract.workloads do
			if candidate.id == workloadId then workload = candidate break end
		end
		if workload == nil then reject("RESULT_E_ENUM", path .. ".workloadId") end
		local senderCount = safeInteger(rawget(value, "senderCount"), path .. ".senderCount", true)
		local recipientCount = safeInteger(rawget(value, "recipientCount"), path .. ".recipientCount", true)
		local scheduled = safeInteger(rawget(value, "scheduledRepetitions"), path .. ".scheduledRepetitions", true)
		local started = safeInteger(rawget(value, "startedRepetitions"), path .. ".startedRepetitions")
		local completed = safeInteger(rawget(value, "completedRepetitions"), path .. ".completedRepetitions")
		local recipientAllowed = false
		for _, allowed in workload.recipientCounts do if allowed == recipientCount then recipientAllowed = true end end
		if senderCount ~= workload.senderCount or not recipientAllowed or scheduled ~= workload.repetitions or completed > started or started > scheduled then
			reject("RESULT_E_RELATION", path)
		end
		return { kind = kind, workloadId = workloadId, senderCount = senderCount, recipientCount = recipientCount, scheduledRepetitions = scheduled, startedRepetitions = started, completedRepetitions = completed }, workload
	elseif kind == "SeparateProbe" then
		exactKeys(value, { kind = true, probeId = true, clientCount = true, scheduledRepetitions = true, startedRepetitions = true, completedRepetitions = true }, path)
		local probeId = machineId(rawget(value, "probeId"), path .. ".probeId")
		local probe = nil
		for _, candidate in Contract.probes do if candidate.id == probeId then probe = candidate break end end
		if probe == nil then reject("RESULT_E_ENUM", path .. ".probeId") end
		local clientCount = safeInteger(rawget(value, "clientCount"), path .. ".clientCount", true)
		local scheduled = safeInteger(rawget(value, "scheduledRepetitions"), path .. ".scheduledRepetitions", true)
		local started = safeInteger(rawget(value, "startedRepetitions"), path .. ".startedRepetitions")
		local completed = safeInteger(rawget(value, "completedRepetitions"), path .. ".completedRepetitions")
		if clientCount ~= probe.clientCount or scheduled ~= probe.repetitions or completed > started or started > scheduled then reject("RESULT_E_RELATION", path) end
		return { kind = kind, probeId = probeId, clientCount = clientCount, scheduledRepetitions = scheduled, startedRepetitions = started, completedRepetitions = completed }, probe
	end
	reject("RESULT_E_ENUM", path .. ".kind")
end

local function copyAdapter(value: any, environment: any, path: string, normalize: boolean): any
	local checked = Identity.check(
		value,
		if normalize then "Normalize" else "Canonical",
		environment.studio.version,
		path
	)
	if checked.kind == "Invalid" then
		reject("RESULT_E_" .. checked.issue.code, checked.issue.path)
	end
	return checked.value
end

local function copyEnvironment(value: any, caseValue: any, path: string, normalize: boolean): any
	exactKeys(value, { studio = true, host = true, execution = true }, path)
	local studio = exactConditionalKeys(rawget(value, "studio"), { version = true }, { channel = true }, path .. ".studio")
	local host = exactConditionalKeys(rawget(value, "host"), { osFamily = true, architecture = true }, { osVersion = true, cpuModel = true, logicalProcessorCount = true, memoryMiB = true, gpuModel = true }, path .. ".host")
	local execution = exactKeys(rawget(value, "execution"), { mode = true, targetFrameRate = true, serverCount = true, clientCount = true }, path .. ".execution")
	local copiedStudio: any = { version = token(rawget(studio, "version"), 64, path .. ".studio.version") }
	if rawget(studio, "channel") ~= nil then copiedStudio.channel = token(rawget(studio, "channel"), 32, path .. ".studio.channel") end
	local copiedHost: any = {
		osFamily = expectEnum(rawget(host, "osFamily"), { Windows = true, macOS = true }, path .. ".host.osFamily"),
		architecture = expectEnum(rawget(host, "architecture"), { x86_64 = true, arm64 = true }, path .. ".host.architecture"),
	}
	if rawget(host, "osVersion") ~= nil then copiedHost.osVersion = token(rawget(host, "osVersion"), 64, path .. ".host.osVersion") end
	if rawget(host, "cpuModel") ~= nil then copiedHost.cpuModel = normalizedLabel(rawget(host, "cpuModel"), 128, path .. ".host.cpuModel", normalize) end
	if rawget(host, "gpuModel") ~= nil then copiedHost.gpuModel = normalizedLabel(rawget(host, "gpuModel"), 128, path .. ".host.gpuModel", normalize) end
	if rawget(host, "logicalProcessorCount") ~= nil then
		local count = safeInteger(rawget(host, "logicalProcessorCount"), path .. ".host.logicalProcessorCount", true)
		if count > 1_024 then reject("RESULT_E_RANGE", path .. ".host.logicalProcessorCount") end
		copiedHost.logicalProcessorCount = count
	end
	if rawget(host, "memoryMiB") ~= nil then
		local memory = safeInteger(rawget(host, "memoryMiB"), path .. ".host.memoryMiB", true)
		if memory < 128 or memory > 16_777_216 then reject("RESULT_E_RANGE", path .. ".host.memoryMiB") end
		copiedHost.memoryMiB = memory
	end
	local clientCount = safeInteger(rawget(execution, "clientCount"), path .. ".execution.clientCount", true)
	local selection = if caseValue.kind == "SeparateProbe"
		then { kind = "SeparateProbe", probeId = caseValue.probeId }
		else {
			kind = "Workload",
			workloadId = caseValue.workloadId,
			recipientCount = caseValue.recipientCount,
		}
	local resolved = Identity.resolveSelection(selection)
	assert(resolved.kind == "Valid", "validated Result V1 case must resolve")
	local expectedClients = resolved.value.clientProcessCount
	if rawget(execution, "mode") ~= Contract.execution.mode or rawget(execution, "targetFrameRate") ~= Contract.execution.targetFrameRate or rawget(execution, "serverCount") ~= 1 or clientCount ~= expectedClients then reject("RESULT_E_RELATION", path .. ".execution") end
	return {
		studio = copiedStudio,
		host = copiedHost,
		execution = { mode = "StudioMultiplayer", targetFrameRate = Contract.execution.targetFrameRate, serverCount = 1, clientCount = clientCount },
	}
end

local function copyConformance(value: any, path: string): any
	exactKeys(value, { timingExclusionsConfirmed = true, localClock = true, sharedClock = true, clockProof = true }, path)
	local exclusions = exactKeys(rawget(value, "timingExclusionsConfirmed"), { setup = true, warmup = true, quiescence = true, resultExtraction = true }, path .. ".timingExclusionsConfirmed")
	for key in exclusions do if type(rawget(exclusions, key)) ~= "boolean" then reject("RESULT_E_TYPE", path .. ".timingExclusionsConfirmed." .. key) end end
	local localClock = exactKeys(rawget(value, "localClock"), { source = true, unit = true, scope = true, quality = true }, path .. ".localClock")
	local sharedClock = exactKeys(rawget(value, "sharedClock"), { source = true, unit = true, scope = true, quality = true }, path .. ".sharedClock")
	for key, expected in Contract.clocks.localDuration do if rawget(localClock, key) ~= expected then reject("RESULT_E_RELATION", path .. ".localClock." .. key) end end
	for key, expected in Contract.clocks.shared do if rawget(sharedClock, key) ~= expected then reject("RESULT_E_RELATION", path .. ".sharedClock." .. key) end end
	local clockProof = exactKeys(rawget(value, "clockProof"), { version = true, passed = true }, path .. ".clockProof")
	if rawget(clockProof, "version") ~= 1 then reject("RESULT_E_RELATION", path .. ".clockProof.version") end
	if type(rawget(clockProof, "passed")) ~= "boolean" then reject("RESULT_E_TYPE", path .. ".clockProof.passed") end
	return {
		timingExclusionsConfirmed = { setup = exclusions.setup, warmup = exclusions.warmup, quiescence = exclusions.quiescence, resultExtraction = exclusions.resultExtraction },
		localClock = { source = localClock.source, unit = localClock.unit, scope = localClock.scope, quality = localClock.quality },
		sharedClock = { source = sharedClock.source, unit = sharedClock.unit, scope = sharedClock.scope, quality = sharedClock.quality },
		clockProof = { version = 1, passed = clockProof.passed },
	}
end

local function copyCounts(value: any, caseValue: any, workload: any, path: string): any
	if caseValue.kind ~= "Workload" then
		if value ~= nil then reject("RESULT_E_KEYSET", path) end
		return nil
	end
	exactKeys(value, { finality = true, expectedSubmissions = true, submitted = true, expectedDeliveries = true, received = true, correct = true, missing = true, duplicate = true, unexpected = true, outOfOrder = true, mismatch = true }, path)
	local counts: any = { finality = expectEnum(rawget(value, "finality"), { Final = true, Partial = true, NotStarted = true }, path .. ".finality") }
	for _, key in { "expectedSubmissions", "submitted", "expectedDeliveries", "received", "correct", "missing", "duplicate", "unexpected", "outOfOrder", "mismatch" } do
		counts[key] = safeInteger(rawget(value, key), path .. "." .. key)
	end
	local submissionsPerRepetition = checkedMultiply(caseValue.senderCount, workload.measuredFrames, path .. ".expectedSubmissions")
	submissionsPerRepetition = checkedMultiply(submissionsPerRepetition, workload.messagesPerFrame, path .. ".expectedSubmissions")
	local expectedSubmissions = checkedMultiply(caseValue.scheduledRepetitions, submissionsPerRepetition, path .. ".expectedSubmissions")
	local expectedDeliveries = checkedMultiply(expectedSubmissions, caseValue.recipientCount, path .. ".expectedDeliveries")
	if counts.expectedSubmissions ~= expectedSubmissions or counts.expectedDeliveries ~= expectedDeliveries then reject("RESULT_E_RELATION", path) end
	local startedSubmissionCapacity = checkedMultiply(caseValue.startedRepetitions, submissionsPerRepetition, path .. ".submitted")
	if counts.submitted > startedSubmissionCapacity then reject("RESULT_E_RELATION", path .. ".submitted") end
	local classifiedExpected = checkedAdd(counts.correct, counts.mismatch, path .. ".correct")
	if checkedAdd(classifiedExpected, checkedAdd(counts.duplicate, counts.unexpected, path), path) ~= counts.received then reject("RESULT_E_RELATION", path .. ".received") end
	local submittedDeliveryCapacity = checkedMultiply(counts.submitted, caseValue.recipientCount, path .. ".correct")
	if classifiedExpected > submittedDeliveryCapacity then reject("RESULT_E_RELATION", path .. ".correct") end
	if counts.duplicate > 0 and classifiedExpected == 0 then reject("RESULT_E_RELATION", path .. ".duplicate") end
	if counts.outOfOrder > classifiedExpected then reject("RESULT_E_RELATION", path .. ".outOfOrder") end
	if counts.finality == "Final" then
		if caseValue.completedRepetitions ~= caseValue.scheduledRepetitions or checkedAdd(checkedAdd(counts.correct, counts.mismatch, path), counts.missing, path) ~= expectedDeliveries then reject("RESULT_E_RELATION", path) end
	elseif counts.finality == "Partial" then
		if caseValue.startedRepetitions == 0 or caseValue.completedRepetitions >= caseValue.scheduledRepetitions or counts.missing ~= 0 then reject("RESULT_E_RELATION", path) end
	else
		if caseValue.startedRepetitions ~= 0 or caseValue.completedRepetitions ~= 0 then reject("RESULT_E_RELATION", path) end
		for _, key in { "submitted", "received", "correct", "missing", "duplicate", "unexpected", "outOfOrder", "mismatch" } do if counts[key] ~= 0 then reject("RESULT_E_RELATION", path .. "." .. key) end end
	end
	if counts.finality ~= "Final" and counts.missing ~= 0 then reject("RESULT_E_RELATION", path .. ".missing") end
	return counts
end

local function float32Bits(value: number): number
	buffer.writef32(FLOAT32_BUFFER, 0, value)
	return buffer.readu32(FLOAT32_BUFFER, 0)
end

local function isFloat32(value: number): boolean
	buffer.writef32(FLOAT32_BUFFER, 0, value)
	return buffer.readf32(FLOAT32_BUFFER, 0) == value
end

local function descriptorAcceptsValue(field: any, component: boolean, value: any): boolean
	local valueType = if component then "f32" else field.valueType
	if valueType == "boolean" then return type(value) == "boolean" end
	if type(value) ~= "number" or not isFinite(value) then return false end
	if valueType == "u8" or valueType == "u16" or valueType == "u32" then
		return value % 1 == 0 and value >= field.minimum and value <= field.maximum
	end
	if valueType == "f32" then
		return value >= field.minimum and value <= field.maximum and isFloat32(value)
	end
	return false
end

local function copyMismatch(value: any, caseDefinition: any, path: string): any
	local mismatch = exactConditionalKeys(value, { path = true, reason = true, expectedPresent = true, actualPresent = true }, { expected = true, actual = true }, path)
	local mismatchPath = printableAscii(rawget(mismatch, "path"), 1, 128, path .. ".path")
	local allowedPaths: { [string]: boolean } = { ["$"] = true }
	local payload = Contract.payloads[caseDefinition.payloadId]
	local fieldByPath: { [string]: any } = {}
	local componentPaths: { [string]: boolean } = {}
	for _, field in payload.fields do
		allowedPaths[field.name] = true
		fieldByPath[field.name] = field
		if field.valueType == "Vector3F32" then
			for _, component in { "X", "Y", "Z" } do
				local componentPath = field.name .. "." .. component
				allowedPaths[componentPath] = true
				fieldByPath[componentPath] = field
				componentPaths[componentPath] = true
			end
		end
	end
	if allowedPaths[mismatchPath] ~= true then reject("RESULT_E_ENUM", path .. ".path") end
	local reason = expectEnum(rawget(mismatch, "reason"), COMPARATOR_REASONS, path .. ".reason")
	local expectedPresent = rawget(mismatch, "expectedPresent")
	local actualPresent = rawget(mismatch, "actualPresent")
	if type(expectedPresent) ~= "boolean" or type(actualPresent) ~= "boolean" then reject("RESULT_E_TYPE", path) end
	local copied: any = { path = mismatchPath, reason = reason, expectedPresent = expectedPresent, actualPresent = actualPresent }
	for _, key in { "expected", "actual" } do
		local item = rawget(mismatch, key)
		if item ~= nil then
			if type(item) == "number" then if not isFinite(item) then reject("RESULT_E_RANGE", path .. "." .. key) end elseif type(item) ~= "boolean" then reject("RESULT_E_TYPE", path .. "." .. key) end
			copied[key] = item
		end
	end

	local hasExpected = rawget(mismatch, "expected") ~= nil
	local hasActual = rawget(mismatch, "actual") ~= nil
	local expectedValue = rawget(mismatch, "expected")
	local actualValue = rawget(mismatch, "actual")
	local field = fieldByPath[mismatchPath]
	local component = componentPaths[mismatchPath] == true
	local function requireShape(condition: boolean)
		if not condition then reject("RESULT_E_RELATION", path) end
	end

	if reason == "WrongContainerType" then
		requireShape(mismatchPath == "$" and expectedPresent and actualPresent and not hasExpected and not hasActual)
	elseif reason == "ArityMismatch" then
		requireShape(mismatchPath == "$" and expectedPresent and actualPresent and hasExpected and hasActual)
		local expectedArity = safeInteger(expectedValue, path .. ".expected")
		local actualArity = safeInteger(actualValue, path .. ".actual")
		requireShape(expectedArity == #payload.fields and actualArity ~= expectedArity)
	elseif reason == "ExtraField" then
		requireShape(mismatchPath == "$" and not expectedPresent and actualPresent and not hasExpected and not hasActual)
	elseif reason == "MissingField" then
		requireShape(field ~= nil and not component and expectedPresent and not actualPresent and not hasActual)
		if field.valueType == "Vector3F32" then requireShape(not hasExpected)
		else requireShape(hasExpected and descriptorAcceptsValue(field, false, expectedValue)) end
	elseif reason == "WrongType" then
		requireShape(field ~= nil and not component and expectedPresent and actualPresent)
		if field.valueType == "Vector3F32" then requireShape(not hasExpected)
		else requireShape(hasExpected and descriptorAcceptsValue(field, false, expectedValue)) end
		if hasActual then
			if field.valueType == "boolean" then requireShape(type(actualValue) == "number")
			elseif field.valueType == "Vector3F32" then requireShape(type(actualValue) == "boolean" or type(actualValue) == "number")
			else requireShape(type(actualValue) == "boolean") end
		end
	elseif reason == "NonFinite" then
		requireShape(field ~= nil and field.valueType ~= "boolean" and expectedPresent and actualPresent and hasExpected and not hasActual)
		requireShape(descriptorAcceptsValue(field, component, expectedValue))
	elseif reason == "NonInteger" then
		requireShape(field ~= nil and not component and (field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32"))
		requireShape(expectedPresent and actualPresent and hasExpected and hasActual and descriptorAcceptsValue(field, false, expectedValue))
		requireShape(type(actualValue) == "number" and isFinite(actualValue) and actualValue % 1 ~= 0)
	elseif reason == "OutOfRange" then
		requireShape(field ~= nil and field.valueType ~= "boolean" and expectedPresent and actualPresent and hasExpected and hasActual)
		requireShape(descriptorAcceptsValue(field, component, expectedValue) and type(actualValue) == "number" and isFinite(actualValue))
		local valueType = if component then "f32" else field.valueType
		if valueType == "u8" or valueType == "u16" or valueType == "u32" then requireShape(actualValue % 1 == 0) end
		requireShape(actualValue < field.minimum or actualValue > field.maximum)
	elseif reason == "NotFloat32" then
		requireShape(field ~= nil and (component or field.valueType == "f32") and expectedPresent and actualPresent and hasExpected and hasActual)
		requireShape(descriptorAcceptsValue(field, component, expectedValue) and type(actualValue) == "number" and isFinite(actualValue))
		requireShape(actualValue >= field.minimum and actualValue <= field.maximum and not isFloat32(actualValue))
	else
		requireShape(reason == "ValueMismatch" and field ~= nil and expectedPresent and actualPresent and hasExpected and hasActual)
		requireShape(descriptorAcceptsValue(field, component, expectedValue) and descriptorAcceptsValue(field, component, actualValue))
		if (if component then "f32" else field.valueType) == "f32" then
			requireShape(float32Bits(expectedValue) ~= float32Bits(actualValue))
		else
			requireShape(expectedValue ~= actualValue)
		end
	end
	return copied
end

local function copyFirstOccurrence(value: any, code: string, caseValue: any, caseDefinition: any, path: string): any
	local wantsMismatch = code == "PayloadMismatch"
	local occurrence = exactConditionalKeys(value, { repetitionIndex = true, participant = true }, if wantsMismatch then { mismatch = true } else {}, path)
	if wantsMismatch and rawget(occurrence, "mismatch") == nil then reject("RESULT_E_KEYSET", path) end
	local repetitionIndex = safeInteger(rawget(occurrence, "repetitionIndex"), path .. ".repetitionIndex", true)
	if repetitionIndex > caseValue.startedRepetitions then reject("RESULT_E_RELATION", path .. ".repetitionIndex") end
	local participant = expectType(rawget(occurrence, "participant"), "table", path .. ".participant")
	local role = rawget(participant, "role")
	local copiedParticipant
	if role == "Coordinator" then
		exactKeys(participant, { role = true }, path .. ".participant")
		copiedParticipant = { role = role }
	elseif role == "Sender" or role == "Recipient" or role == "ProbeClient" then
		exactKeys(participant, { role = true, index = true }, path .. ".participant")
		local index = safeInteger(rawget(participant, "index"), path .. ".participant.index", true)
		if caseValue.kind == "Workload" then
			if role == "ProbeClient" or (role == "Sender" and index > caseValue.senderCount) or (role == "Recipient" and index > caseValue.recipientCount) then reject("RESULT_E_RELATION", path .. ".participant") end
		else
			if role ~= "ProbeClient" or index > caseValue.clientCount then reject("RESULT_E_RELATION", path .. ".participant") end
		end
		copiedParticipant = { role = role, index = index }
	else
		reject("RESULT_E_ENUM", path .. ".participant.role")
	end
	local copied: any = { repetitionIndex = repetitionIndex, participant = copiedParticipant }
	if wantsMismatch then copied.mismatch = copyMismatch(rawget(occurrence, "mismatch"), caseDefinition, path .. ".mismatch") end
	return copied
end

local function failureDiscriminator(value: any, code: string, selectedRequired: { [string]: boolean }, requiredMeasurementIds: { [string]: boolean }, path: string): (any, string)
	if code == "PayloadMismatch" then
		local discriminator = exactKeys(value, { mismatchReason = true }, path)
		local reason = expectEnum(rawget(discriminator, "mismatchReason"), COMPARATOR_REASONS, path .. ".mismatchReason")
		return { mismatchReason = reason }, reason
	elseif code == "UnsupportedCapability" then
		local discriminator = exactKeys(value, { capability = true, required = true }, path)
		local capability = expectEnum(rawget(discriminator, "capability"), { Direction = true, DeliverySemantics = true, Payload = true, BroadcastMode = true }, path .. ".capability")
		local required = printableAscii(rawget(discriminator, "required"), 1, 64, path .. ".required")
		local key = capability .. "\0" .. required
		if selectedRequired[key] ~= true then reject("RESULT_E_RELATION", path) end
		return { capability = capability, required = required }, capability .. "\0" .. required
	elseif code == "TimingExclusionViolation" then
		local discriminator = exactKeys(value, { exclusion = true }, path)
		local exclusion = expectEnum(rawget(discriminator, "exclusion"), { setup = true, warmup = true, quiescence = true, resultExtraction = true }, path .. ".exclusion")
		return { exclusion = exclusion }, exclusion
	elseif code == "RequiredMeasurementUnavailable" then
		local discriminator = exactKeys(value, { measurementId = true }, path)
		local measurementId = rawget(discriminator, "measurementId")
		if type(measurementId) ~= "string" then reject("RESULT_E_TYPE", path .. ".measurementId") end
		if requiredMeasurementIds[measurementId] ~= true then reject("RESULT_E_RELATION", path .. ".measurementId") end
		return { measurementId = measurementId }, measurementId
	elseif code == "InternalError" then
		local discriminator = exactKeys(value, { stage = true }, path)
		local stage = expectEnum(rawget(discriminator, "stage"), { Preflight = true, Setup = true, Execution = true, Finalize = true }, path .. ".stage")
		return { stage = stage }, stage
	end
	reject("RESULT_E_KEYSET", path)
end

local function requirementKey(requirement: Identity.Requirement): string
	return requirement.capability .. "\0" .. requirement.required
end

local function selectedRequirements(
	caseValue: any
): ({ Identity.Requirement }, { [string]: boolean }, { [string]: boolean })
	local selection: Identity.CaseSelection
	if caseValue.kind == "Workload" then
		selection = {
			kind = "Workload",
			workloadId = caseValue.workloadId,
			recipientCount = caseValue.recipientCount,
		}
	else
		selection = { kind = "SeparateProbe", probeId = caseValue.probeId }
	end
	local resolved = Identity.resolveSelection(selection)
	if resolved.kind == "Invalid" then
		reject("RESULT_E_RELATION", "$.case")
	end
	local requirementSet: { [string]: boolean } = {}
	for _, requirement in resolved.value.requirements do
		requirementSet[requirementKey(requirement)] = true
	end
	local requiredMeasurements: { [string]: boolean } = {}
	for _, measurement in Contract.measurements do
		if measurement.scope == caseValue.kind and (measurement.probeId == nil or measurement.probeId == caseValue.probeId) and measurement.availability == "Required" then requiredMeasurements[measurement.id] = true end
	end
	return resolved.value.requirements, requirementSet, requiredMeasurements
end

local function copyFailures(value: any, caseValue: any, caseDefinition: any, adapter: any, counts: any, path: string, normalize: boolean): (any, any)
	local array, count = denseArray(value, MAX_FAILURES, path)
	local orderedRequirements, requirements, requiredMeasurementIds = selectedRequirements(caseValue)
	local missingRequired: { [string]: boolean } = {}
	for _, requirement in Identity.missingRequirements(adapter, orderedRequirements) do
		missingRequired[requirementKey(requirement)] = true
	end
	local copied = table.create(count)
	local categories: { [string]: boolean } = {}
	local groups: { [string]: boolean } = {}
	local sums: { [string]: number } = {}
	local exclusionSeen: { [string]: boolean } = {}
	local capabilitySeen: { [string]: boolean } = {}
	local measurementFailureSeen: { [string]: boolean } = {}
	local clockFailure = false
	for index = 1, count do
		local failure = exactConditionalKeys(rawget(array, index), { category = true, code = true, occurrences = true }, { discriminator = true, firstOccurrence = true }, path .. "[]")
		local code = expectEnum(rawget(failure, "code"), CODE_ORDER :: any, path .. "[].code")
		local category = expectEnum(rawget(failure, "category"), CATEGORY_ORDER :: any, path .. "[].category")
		if CODE_CATEGORY[code] ~= category then reject("RESULT_E_RELATION", path .. "[]") end
		local occurrences = safeInteger(rawget(failure, "occurrences"), path .. "[].occurrences", true)
		if (code == "UnsupportedCapability" or code == "TimingExclusionViolation" or code == "RequiredMeasurementUnavailable" or code == "InternalError") and occurrences ~= 1 then reject("RESULT_E_RELATION", path .. "[].occurrences") end
		local discriminatorRequired = code == "PayloadMismatch" or code == "UnsupportedCapability" or code == "TimingExclusionViolation" or code == "RequiredMeasurementUnavailable" or code == "InternalError"
		local discriminator = nil
		local discriminatorKey = ""
		if discriminatorRequired then
			if rawget(failure, "discriminator") == nil then reject("RESULT_E_KEYSET", path .. "[]") end
			discriminator, discriminatorKey = failureDiscriminator(rawget(failure, "discriminator"), code, requirements, requiredMeasurementIds, path .. "[].discriminator")
		elseif rawget(failure, "discriminator") ~= nil then reject("RESULT_E_KEYSET", path .. "[]") end
		local firstRequired = code == "PayloadMismatch" or code == "DeliveryObservationLimitExceeded"
		local firstForbidden = code == "UnsupportedCapability" or code == "TimingExclusionViolation" or code == "SetupFailure" or code == "RequiredMeasurementUnavailable" or code == "ClockProofFailure" or code == "InternalError"
		local firstOccurrence = nil
		if rawget(failure, "firstOccurrence") ~= nil then
			if firstForbidden then reject("RESULT_E_KEYSET", path .. "[].firstOccurrence") end
			firstOccurrence = copyFirstOccurrence(rawget(failure, "firstOccurrence"), code, caseValue, caseDefinition, path .. "[].firstOccurrence")
		elseif firstRequired then reject("RESULT_E_KEYSET", path .. "[].firstOccurrence") end
		if code == "PayloadMismatch" and firstOccurrence.mismatch.reason ~= discriminator.mismatchReason then reject("RESULT_E_RELATION", path .. "[]") end
		if caseValue.kind == "SeparateProbe" and (code == "SubmissionShortfall" or code == "MissingDelivery" or code == "DuplicateDelivery" or code == "UnexpectedDelivery" or code == "OutOfOrderDelivery") then reject("RESULT_E_RELATION", path .. "[]") end
		local groupKey = category .. "\0" .. code .. "\0" .. discriminatorKey
		if groups[groupKey] then reject("RESULT_E_RELATION", path) end
		groups[groupKey] = true
		categories[category] = true
		sums[code] = checkedAdd(sums[code] or 0, occurrences, path .. "[].occurrences")
		if code == "TimingExclusionViolation" then exclusionSeen[discriminator.exclusion] = true end
		if code == "UnsupportedCapability" then capabilitySeen[discriminatorKey] = true end
		if code == "RequiredMeasurementUnavailable" then measurementFailureSeen[discriminator.measurementId] = true end
		if code == "ClockProofFailure" then clockFailure = true end
		local copiedFailure: any = { category = category, code = code, occurrences = occurrences }
		if discriminator ~= nil then copiedFailure.discriminator = discriminator end
		if firstOccurrence ~= nil then copiedFailure.firstOccurrence = firstOccurrence end
		copied[index] = copiedFailure
	end

	local function sortKey(failure: any): string
		local discriminator = failure.discriminator
		local scalar = ""
		if discriminator ~= nil then
			if discriminator.mismatchReason ~= nil then scalar = string.format("%02d", COMPARATOR_REASON_ORDER[discriminator.mismatchReason])
			elseif discriminator.capability ~= nil then scalar = string.format("%02d\0%s", CAPABILITY_ORDER[discriminator.capability], discriminator.required)
			elseif discriminator.exclusion ~= nil then scalar = string.format("%02d", EXCLUSION_ORDER[discriminator.exclusion])
			elseif discriminator.measurementId ~= nil then scalar = discriminator.measurementId
			else scalar = string.format("%02d", STAGE_ORDER[discriminator.stage]) end
		end
		local first = failure.firstOccurrence
		local suffix = ""
		if first ~= nil then suffix = string.format("%015d\0%02d\0%015d", first.repetitionIndex, ROLE_ORDER[first.participant.role], first.participant.index or 0) end
		return string.format("%02d\0%02d\0%s\0%s", CATEGORY_ORDER[failure.category], CODE_ORDER[failure.code], scalar, suffix)
	end
	if normalize then
		table.sort(copied, function(left, right) return sortKey(left) < sortKey(right) end)
	else
		for index = 2, #copied do if sortKey(copied[index - 1]) >= sortKey(copied[index]) then reject("RESULT_E_ORDER", path) end end
	end

	local status
	if categories.Harness then status = "Error"
	elseif categories.Capability then status = "Unsupported"
	elseif categories.Correctness or categories.Contract or categories.Lifecycle or categories.Measurement then status = "Invalid"
	else status = "Valid" end
	if categories.Capability and count ~= (function() local n=0 for _ in capabilitySeen do n+=1 end return n end)() then reject("RESULT_E_RELATION", path) end
	if categories.Capability and (categories.Correctness or categories.Contract or categories.Lifecycle or categories.Measurement or categories.Harness) then reject("RESULT_E_RELATION", path) end
	if categories.Harness and (categories.Capability or categories.Measurement) then reject("RESULT_E_RELATION", path) end
	if status == "Valid" and (caseValue.startedRepetitions ~= caseValue.scheduledRepetitions or caseValue.completedRepetitions ~= caseValue.scheduledRepetitions) then reject("RESULT_E_RELATION", path) end
	if status == "Invalid" and caseValue.startedRepetitions == 0 and (sums.SetupFailure or 0) ~= 1 then reject("RESULT_E_RELATION", path) end
	if status == "Unsupported" and (caseValue.startedRepetitions ~= 0 or caseValue.completedRepetitions ~= 0) then reject("RESULT_E_RELATION", path) end
	if status == "Error" and not categories.Harness then reject("RESULT_E_RELATION", path) end

	for _, requirement in orderedRequirements do
		local key = requirementKey(requirement)
		local missing = missingRequired[key] == true
		if status == "Unsupported" then
			if missing ~= (capabilitySeen[key] == true) then reject("RESULT_E_RELATION", path) end
		elseif status ~= "Error" and missing then reject("RESULT_E_RELATION", path) end
	end
	if status == "Unsupported" and count == 0 then reject("RESULT_E_RELATION", path) end

	local maxExpectedSubmissions
	local observationLimit
	if caseValue.kind == "Workload" then
		maxExpectedSubmissions = counts.expectedSubmissions
		observationLimit = checkedMultiply(4, counts.expectedDeliveries, path)
		if (sums.DuplicateDelivery or 0) ~= counts.duplicate or (sums.UnexpectedDelivery or 0) ~= counts.unexpected or (sums.OutOfOrderDelivery or 0) ~= counts.outOfOrder or (sums.PayloadMismatch or 0) ~= counts.mismatch then reject("RESULT_E_RELATION", path) end
		if counts.finality == "Final" then
			if (sums.MissingDelivery or 0) ~= counts.missing then reject("RESULT_E_RELATION", path) end
			local shortfall = counts.expectedSubmissions - counts.submitted
			if shortfall < 0 or (sums.SubmissionShortfall or 0) ~= shortfall then reject("RESULT_E_RELATION", path) end
		elseif (sums.MissingDelivery or 0) ~= 0 or (sums.SubmissionShortfall or 0) ~= 0 then reject("RESULT_E_RELATION", path) end
	else
		maxExpectedSubmissions = checkedMultiply(2, checkedMultiply(caseValue.scheduledRepetitions, caseDefinition.measuredSamples, path), path)
		observationLimit = checkedMultiply(4, maxExpectedSubmissions, path)
		if (sums.PayloadMismatch or 0) > checkedMultiply(caseValue.scheduledRepetitions, caseDefinition.measuredSamples, path) then reject("RESULT_E_RELATION", path) end
	end
	for code, total in sums do
		if code == "AddedDeliveryFrameLimitExceeded" or code == "SubmitFailure" then if total > maxExpectedSubmissions then reject("RESULT_E_RELATION", path) end
		elseif code == "ControlTrafficDuringMeasuredFrames" or code == "StaleCallback" then if total > observationLimit then reject("RESULT_E_RELATION", path) end
		elseif code == "IsolationFailure" or code == "Timeout" or code == "Disconnect" or code == "TeardownFailure" then if total > caseValue.scheduledRepetitions then reject("RESULT_E_RELATION", path) end
		elseif code == "DeliveryObservationLimitExceeded" or code == "SetupFailure" or code == "ClockProofFailure" then if total ~= 1 then reject("RESULT_E_RELATION", path) end end
	end
	if (sums.DeliveryObservationLimitExceeded or 0) > 0 then
		if caseValue.kind == "Workload" then
			if counts.finality ~= "Partial" or caseValue.completedRepetitions >= caseValue.scheduledRepetitions or counts.received ~= observationLimit then reject("RESULT_E_RELATION", path) end
		elseif caseValue.completedRepetitions >= caseValue.scheduledRepetitions then
			reject("RESULT_E_RELATION", path)
		end
	end
	return copied, { status = status, sums = sums, exclusions = exclusionSeen, measurementFailures = measurementFailureSeen, clockFailure = clockFailure }
end

local function cloneTrusted(value: any): any
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, nested in value do clone[key] = cloneTrusted(nested) end
	return clone
end

local function deepEqual(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	local count = 0
	for key, value in left do
		count += 1
		if not deepEqual(value, rawget(right, key)) then return false end
	end
	local rightCount = 0
	for _ in right do rightCount += 1 end
	return count == rightCount
end

local function copyRawSamples(value: any, measurement: any, caseValue: any, caseDefinition: any, path: string, normalize: boolean): (any, { number })
	local role = measurement.capture.role
	local participantCount = if role == "Sender" then caseValue.senderCount elseif role == "ProbeClient" then caseValue.clientCount else 1
	local needsParticipant = role == "Sender" or role == "ProbeClient"
	local valuesPerGroup
	if measurement.capture.cadence == "PerMeasuredFrame" then valuesPerGroup = caseDefinition.measuredFrames
	elseif measurement.capture.cadence == "PerRepetition" then valuesPerGroup = 1
	elseif measurement.capture.cadence == "PerSubmission" then valuesPerGroup = checkedMultiply(caseDefinition.measuredFrames, caseDefinition.messagesPerFrame, path)
	else valuesPerGroup = caseDefinition.measuredSamples end
	local expectedGroups = checkedMultiply(caseValue.scheduledRepetitions, participantCount, path)
	local groups, count = denseArray(value, 1_000, path)
	if count ~= expectedGroups then reject("RESULT_E_RELATION", path) end
	local copied = table.create(count)
	local flattened = table.create(checkedMultiply(count, valuesPerGroup, path))
	local flattenedCount = 0
	for index = 1, count do
		local group = exactConditionalKeys(rawget(groups, index), { repetitionIndex = true, values = true }, if needsParticipant then { participantIndex = true } else {}, path .. "[]")
		if needsParticipant and rawget(group, "participantIndex") == nil then reject("RESULT_E_KEYSET", path .. "[]") end
		if not needsParticipant and rawget(group, "participantIndex") ~= nil then reject("RESULT_E_KEYSET", path .. "[]") end
		local repetitionIndex = safeInteger(rawget(group, "repetitionIndex"), path .. "[].repetitionIndex", true)
		if repetitionIndex > caseValue.scheduledRepetitions then reject("RESULT_E_RANGE", path .. "[].repetitionIndex") end
		local participantIndex = nil
		if needsParticipant then
			participantIndex = safeInteger(rawget(group, "participantIndex"), path .. "[].participantIndex", true)
			if participantIndex > participantCount then reject("RESULT_E_RANGE", path .. "[].participantIndex") end
		end
		local rawValues, valueCount = denseArray(rawget(group, "values"), MAX_ARRAY_ENTRIES, path .. "[].values")
		if valueCount ~= valuesPerGroup then reject("RESULT_E_RELATION", path .. "[].values") end
		local copiedValues = table.create(valueCount)
		for valueIndex = 1, valueCount do
			local sample = rawget(rawValues, valueIndex)
			if type(sample) ~= "number" then reject("RESULT_E_TYPE", path .. "[].values[]") end
			if not isFinite(sample) or isNegativeZero(sample) or sample < 0 then reject("RESULT_E_RANGE", path .. "[].values[]") end
			if measurement.summary == "Exact" and (sample % 1 ~= 0 or sample > MAX_SAFE_INTEGER) then reject("RESULT_E_RANGE", path .. "[].values[]") end
			copiedValues[valueIndex] = sample
			flattenedCount += 1
			flattened[flattenedCount] = sample
		end
		local copiedGroup: any = { repetitionIndex = repetitionIndex, values = copiedValues }
		if participantIndex ~= nil then copiedGroup.participantIndex = participantIndex end
		copied[index] = copiedGroup
	end
	local function groupLess(left: any, right: any): boolean
		if left.repetitionIndex ~= right.repetitionIndex then return left.repetitionIndex < right.repetitionIndex end
		return (left.participantIndex or 0) < (right.participantIndex or 0)
	end
	if normalize then table.sort(copied, groupLess) else for index = 2, #copied do if not groupLess(copied[index - 1], copied[index]) then reject("RESULT_E_ORDER", path) end end end
	for index, group in copied do
		local expectedRepetition = math.floor((index - 1) / participantCount) + 1
		local expectedParticipant = (index - 1) % participantCount + 1
		if group.repetitionIndex ~= expectedRepetition or (needsParticipant and group.participantIndex ~= expectedParticipant) then reject("RESULT_E_RELATION", path) end
	end
	-- Rebuild the flattened sequence after group normalization.
	flattened = table.create(flattenedCount)
	flattenedCount = 0
	for _, group in copied do for _, sample in group.values do flattenedCount += 1 flattened[flattenedCount] = sample end end
	return copied, flattened
end

local function makeSummary(measurement: any, values: { number }, path: string): any
	if #values == 0 then reject("RESULT_E_RELATION", path) end
	if measurement.summary == "Exact" then
		local total = 0
		for _, value in values do total = checkedAdd(total, value, path .. ".total") end
		return { kind = "Exact", sampleCount = #values, total = total }
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local count = #sorted
	local median
	if count % 2 == 1 then median = sorted[(count + 1) / 2]
	else
		local lower = sorted[count / 2]
		local upper = sorted[count / 2 + 1]
		median = lower + (upper - lower) / 2
	end
	local rank = math.floor((95 * count + 99) / 100)
	return { kind = "MedianAndP95", sampleCount = count, median = median, p95 = sorted[rank] }
end

local function selectedMeasurements(caseValue: any): { any }
	local selected = {}
	for _, measurement in Contract.measurements do
		if measurement.scope == caseValue.kind and (measurement.probeId == nil or measurement.probeId == caseValue.probeId) then table.insert(selected, measurement) end
	end
	return selected
end

local function copyMeasurements(
	value: any,
	caseValue: any,
	caseDefinition: any,
	status: string,
	failureInfo: any,
	counts: any,
	path: string,
	normalize: boolean,
	full: boolean
): any
	local selected = selectedMeasurements(caseValue)
	local array, count = denseArray(value, #Contract.measurements, path)
	if count ~= #selected then reject("RESULT_E_RELATION", path) end
	local byId: { [string]: any } = {}
	local originalIds = table.create(count)
	for index = 1, count do
		local record = rawget(array, index)
		if type(record) ~= "table" then reject("RESULT_E_TYPE", path .. "[]") end
		local id
		if full then
			local metadata = rawget(record, "metadata")
			if type(metadata) ~= "table" or type(rawget(metadata, "id")) ~= "string" then reject("RESULT_E_TYPE", path .. "[].metadata") end
			id = rawget(metadata, "id")
		else
			id = rawget(record, "id")
			if type(id) ~= "string" then reject("RESULT_E_TYPE", path .. "[].id") end
		end
		if byId[id] ~= nil then reject("RESULT_E_RELATION", path) end
		byId[id] = record
		originalIds[index] = id
	end
	local copied = table.create(count)
	local totalRaw = 0
	local caseCompleted = caseValue.completedRepetitions == caseValue.scheduledRepetitions
	for index, measurement in selected do
		local record = byId[measurement.id]
		if record == nil then reject("RESULT_E_RELATION", path) end
		if not normalize and originalIds[index] ~= measurement.id then reject("RESULT_E_ORDER", path) end
		local state = rawget(record, "state")
		local output: any
		if state == "Available" or state == "Diagnostic" then
			if full then exactKeys(record, if state == "Available" then { metadata = true, state = true, rawSamples = true, summary = true } else { metadata = true, state = true, rawSamples = true }, path .. "[]")
			else exactKeys(record, { id = true, state = true, rawSamples = true }, path .. "[]") end
			local rawSamples, flattened = copyRawSamples(rawget(record, "rawSamples"), measurement, caseValue, caseDefinition, path .. "[].rawSamples", normalize)
			totalRaw = checkedAdd(totalRaw, #flattened, path)
			local summary = makeSummary(measurement, flattened, path .. "[].summary")
			if state == "Available" then output = { metadata = cloneTrusted(measurement), state = state, rawSamples = rawSamples, summary = summary }
			else output = { metadata = cloneTrusted(measurement), state = state, rawSamples = rawSamples } end
			if full then
				if not deepEqual(rawget(record, "metadata"), measurement) then reject("RESULT_E_RELATION", path .. "[].metadata") end
				if state == "Available" then
					local suppliedSummary = rawget(record, "summary")
					if type(suppliedSummary) == "table" then
						for _, key in { "sampleCount", "total", "median", "p95" } do
							local suppliedValue = rawget(suppliedSummary, key)
							if type(suppliedValue) == "number" and isNegativeZero(suppliedValue) then reject("RESULT_E_NONCANONICAL", path .. "[].summary") end
						end
					end
					if not deepEqual(suppliedSummary, summary) then reject("RESULT_E_NONCANONICAL", path .. "[].summary") end
				end
			end
		else
			if state ~= "Unavailable" then reject("RESULT_E_ENUM", path .. "[].state") end
			if full then exactKeys(record, { metadata = true, state = true, unavailableReason = true }, path .. "[]") else exactKeys(record, { id = true, state = true, unavailableReason = true }, path .. "[]") end
			local reason = exactKeys(rawget(record, "unavailableReason"), { code = true }, path .. "[].unavailableReason")
			local reasonCode = expectEnum(rawget(reason, "code"), UNAVAILABLE_CODES, path .. "[].unavailableReason.code")
			output = { metadata = cloneTrusted(measurement), state = state, unavailableReason = { code = reasonCode } }
			if full and not deepEqual(rawget(record, "metadata"), measurement) then reject("RESULT_E_RELATION", path .. "[].metadata") end
		end

		local allowed = false
		if status == "Valid" then
			if not caseCompleted then reject("RESULT_E_RELATION", path) end
			if measurement.availability == "Required" then allowed = state == "Available"
			else allowed = state == "Available" or (state == "Unavailable" and (output.unavailableReason.code == "NotSupportedByAdapter" or output.unavailableReason.code == "UnavailableInEnvironment" or output.unavailableReason.code == "CaptureFailed")) end
		elseif status == "Invalid" then
			if not caseCompleted then allowed = state == "Unavailable" and output.unavailableReason.code == "CaseNotCompleted"
			elseif measurement.summary == "Exact" then
				if measurement.availability == "Required" then allowed = state == "Available" or (state == "Unavailable" and output.unavailableReason.code == "CaptureFailed")
				else allowed = state == "Available" or (state == "Unavailable" and (output.unavailableReason.code == "NotSupportedByAdapter" or output.unavailableReason.code == "UnavailableInEnvironment" or output.unavailableReason.code == "CaptureFailed")) end
			else
				if measurement.availability == "Required" then allowed = state == "Diagnostic" or (state == "Unavailable" and output.unavailableReason.code == "CaptureFailed")
				else allowed = state == "Diagnostic" or (state == "Unavailable" and (output.unavailableReason.code == "NotSupportedByAdapter" or output.unavailableReason.code == "UnavailableInEnvironment" or output.unavailableReason.code == "CaptureFailed")) end
			end
		elseif status == "Unsupported" then allowed = state == "Unavailable" and output.unavailableReason.code == "CaseUnsupported"
		elseif status == "Error" then allowed = state == "Unavailable" and output.unavailableReason.code == (if caseCompleted then "ResultUntrusted" else "CaseNotCompleted") end
		if not allowed then reject("RESULT_E_RELATION", path .. "[]") end
		if measurement.summary == "Exact" and state == "Diagnostic" then reject("RESULT_E_RELATION", path .. "[]") end
		if status == "Invalid" and measurement.summary == "MedianAndP95" and state == "Available" then reject("RESULT_E_RELATION", path .. "[]") end
		local needsMeasurementFailure = status == "Invalid" and measurement.availability == "Required" and state == "Unavailable"
		if needsMeasurementFailure ~= (failureInfo.measurementFailures[measurement.id] == true) then reject("RESULT_E_RELATION", path .. "[]") end
		if state == "Available" and measurement.summary == "Exact" and counts ~= nil and (measurement.id == "submitted" or measurement.id == "received" or measurement.id == "correct") and output.summary.total ~= counts[measurement.id] then reject("RESULT_E_RELATION", path .. "[].summary.total") end
		if status == "Valid" and state == "Available" and caseValue.kind == "Workload" and (measurement.id == "submitted" or measurement.id == "received" or measurement.id == "correct") then
			local submissionsPerRepetition = checkedMultiply(caseValue.senderCount, caseDefinition.measuredFrames, path .. "[].rawSamples")
			submissionsPerRepetition = checkedMultiply(submissionsPerRepetition, caseDefinition.messagesPerFrame, path .. "[].rawSamples")
			local expectedPerRepetition = if measurement.id == "submitted" then submissionsPerRepetition else checkedMultiply(submissionsPerRepetition, caseValue.recipientCount, path .. "[].rawSamples")
			for _, group in output.rawSamples do
				if group.values[1] ~= expectedPerRepetition then reject("RESULT_E_RELATION", path .. "[].rawSamples[].values[]") end
			end
		end
		copied[index] = output
	end
	local maximumRaw = if caseValue.kind == "Workload" then MAX_RAW_WORKLOAD else MAX_RAW_PROBE
	if totalRaw > maximumRaw then reject("RESULT_E_LIMIT", path) end
	return copied
end

local function validateCrossFields(caseValue: any, status: string, counts: any, conformance: any, failureInfo: any, path: string)
	for _, exclusion in { "setup", "warmup", "quiescence", "resultExtraction" } do
		local falseConfirmation = conformance.timingExclusionsConfirmed[exclusion] == false
		if falseConfirmation ~= (failureInfo.exclusions[exclusion] == true) then reject("RESULT_E_RELATION", path .. ".conformance.timingExclusionsConfirmed." .. exclusion) end
	end
	if (conformance.clockProof.passed == false) ~= failureInfo.clockFailure then reject("RESULT_E_RELATION", path .. ".conformance.clockProof") end
	if status == "Valid" then
		if not conformance.clockProof.passed then reject("RESULT_E_RELATION", path .. ".conformance.clockProof") end
		for _, value in conformance.timingExclusionsConfirmed do if not value then reject("RESULT_E_RELATION", path .. ".conformance.timingExclusionsConfirmed") end end
		if caseValue.kind == "Workload" then
			if counts.finality ~= "Final" or counts.submitted ~= counts.expectedSubmissions or counts.received ~= counts.expectedDeliveries or counts.correct ~= counts.expectedDeliveries then reject("RESULT_E_RELATION", path .. ".counts") end
			for _, key in { "missing", "duplicate", "unexpected", "outOfOrder", "mismatch" } do if counts[key] ~= 0 then reject("RESULT_E_RELATION", path .. ".counts." .. key) end end
		end
	elseif status == "Unsupported" and caseValue.kind == "Workload" and counts.finality ~= "NotStarted" then
		reject("RESULT_E_RELATION", path .. ".counts.finality")
	end
	if caseValue.kind == "Workload" then
		if counts.submitted > counts.expectedSubmissions then reject("RESULT_E_RELATION", path .. ".counts.submitted") end
		local observationLimit = checkedMultiply(4, counts.expectedDeliveries, path .. ".counts.received")
		if counts.received > observationLimit then reject("RESULT_E_RELATION", path .. ".counts.received") end
	end
end

local function parseDraft(draft: any): any
	preflight(draft)
	if type(draft) ~= "table" then reject("RESULT_E_TYPE", "$") end
	local draftKind = if type(rawget(draft, "case")) == "table" then rawget(rawget(draft, "case"), "kind") else nil
	local draftKeys = { runId = true, benchmarkSource = true, contractFingerprint = true, adapter = true, case = true, failures = true, conformance = true, measurements = true, environment = true }
	if draftKind == "Workload" then draftKeys.counts = true end
	local source = exactKeys(draft, draftKeys, "$")
	local caseValue, caseDefinition = copyCase(rawget(source, "case"), "$.case")
	local environment = copyEnvironment(rawget(source, "environment"), caseValue, "$.environment", true)
	local adapter = copyAdapter(rawget(source, "adapter"), environment, "$.adapter", true)
	local counts = copyCounts(rawget(source, "counts"), caseValue, caseDefinition, "$.counts")
	local conformance = copyConformance(rawget(source, "conformance"), "$.conformance")
	local failures, failureInfo = copyFailures(rawget(source, "failures"), caseValue, caseDefinition, adapter, counts, "$.failures", true)
	validateCrossFields(caseValue, failureInfo.status, counts, conformance, failureInfo, "$")
	local measurements = copyMeasurements(rawget(source, "measurements"), caseValue, caseDefinition, failureInfo.status, failureInfo, counts, "$.measurements", true, false)
	local benchmarkSource = exactKeys(rawget(source, "benchmarkSource"), { revision = true, dirty = true }, "$.benchmarkSource")
	if type(rawget(benchmarkSource, "dirty")) ~= "boolean" then reject("RESULT_E_TYPE", "$.benchmarkSource.dirty") end
	local result: any = {
		schema = { id = "result-v1", version = 1 },
		runId = uuid(rawget(source, "runId"), "$.runId"),
		benchmark = { id = "relay-event", version = 1, source = { revision = lowercaseHex(rawget(benchmarkSource, "revision"), { 40, 64 }, "$.benchmarkSource.revision"), dirty = benchmarkSource.dirty } },
		contract = { id = "event-v1", version = Contract.version, fingerprint = sha256(rawget(source, "contractFingerprint"), "$.contractFingerprint") },
		adapter = adapter,
		case = caseValue,
		status = failureInfo.status,
		failures = failures,
		conformance = conformance,
		measurements = measurements,
		environment = environment,
	}
	if counts ~= nil then result.counts = counts end
	deepFreeze(result)
	return result
end

local function parseResult(candidate: any): any
	preflight(candidate)
	if type(candidate) ~= "table" then reject("RESULT_E_TYPE", "$") end
	local kind = if type(rawget(candidate, "case")) == "table" then rawget(rawget(candidate, "case"), "kind") else nil
	local rootKeys = { schema = true, runId = true, benchmark = true, contract = true, adapter = true, case = true, status = true, failures = true, conformance = true, measurements = true, environment = true }
	if kind == "Workload" then rootKeys.counts = true end
	local source = exactKeys(candidate, rootKeys, "$")
	local schema = exactKeys(rawget(source, "schema"), { id = true, version = true }, "$.schema")
	if rawget(schema, "id") ~= "result-v1" or rawget(schema, "version") ~= 1 then reject("RESULT_E_RELATION", "$.schema") end
	local benchmark = exactKeys(rawget(source, "benchmark"), { id = true, version = true, source = true }, "$.benchmark")
	if rawget(benchmark, "id") ~= "relay-event" or rawget(benchmark, "version") ~= 1 then reject("RESULT_E_RELATION", "$.benchmark") end
	local benchmarkSource = exactKeys(rawget(benchmark, "source"), { revision = true, dirty = true }, "$.benchmark.source")
	if type(rawget(benchmarkSource, "dirty")) ~= "boolean" then reject("RESULT_E_TYPE", "$.benchmark.source.dirty") end
	local contract = exactKeys(rawget(source, "contract"), { id = true, version = true, fingerprint = true }, "$.contract")
	if rawget(contract, "id") ~= "event-v1" or rawget(contract, "version") ~= Contract.version then reject("RESULT_E_RELATION", "$.contract") end
	local caseValue, caseDefinition = copyCase(rawget(source, "case"), "$.case")
	local environment = copyEnvironment(rawget(source, "environment"), caseValue, "$.environment", false)
	local adapter = copyAdapter(rawget(source, "adapter"), environment, "$.adapter", false)
	local counts = copyCounts(rawget(source, "counts"), caseValue, caseDefinition, "$.counts")
	local conformance = copyConformance(rawget(source, "conformance"), "$.conformance")
	local failures, failureInfo = copyFailures(rawget(source, "failures"), caseValue, caseDefinition, adapter, counts, "$.failures", false)
	local suppliedStatus = expectEnum(rawget(source, "status"), { Valid = true, Invalid = true, Unsupported = true, Error = true }, "$.status")
	if suppliedStatus ~= failureInfo.status then reject("RESULT_E_NONCANONICAL", "$.status") end
	validateCrossFields(caseValue, suppliedStatus, counts, conformance, failureInfo, "$")
	local measurements = copyMeasurements(rawget(source, "measurements"), caseValue, caseDefinition, suppliedStatus, failureInfo, counts, "$.measurements", false, true)
	local result: any = {
		schema = { id = "result-v1", version = 1 },
		runId = uuid(rawget(source, "runId"), "$.runId"),
		benchmark = { id = "relay-event", version = 1, source = { revision = lowercaseHex(rawget(benchmarkSource, "revision"), { 40, 64 }, "$.benchmark.source.revision"), dirty = benchmarkSource.dirty } },
		contract = { id = "event-v1", version = Contract.version, fingerprint = sha256(rawget(contract, "fingerprint"), "$.contract.fingerprint") },
		adapter = adapter,
		case = caseValue,
		status = suppliedStatus,
		failures = failures,
		conformance = conformance,
		measurements = measurements,
		environment = environment,
	}
	if counts ~= nil then result.counts = counts end
	deepFreeze(result)
	return result
end

local function finalize(draft: ResultDraft): Result
	return parseDraft(draft)
end

local function validate(candidate: unknown): Result
	return parseResult(candidate)
end

local ResultV1 = {
	ID = "result-v1",
	VERSION = 1,
	BENCHMARK_ID = "relay-event",
	BENCHMARK_VERSION = 1,
	MAX_JSON_BYTES = 8_388_608,
	finalize = finalize,
	validate = validate,
}

table.freeze(ResultV1)

return ResultV1
