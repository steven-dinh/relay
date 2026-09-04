--!strict

local EventV1 = require("../event-v1")
local HostManifestV1 = require("./HostManifestV1")
local Identity = require("./AdapterIdentity")

export type RepetitionFragment = {
	schema: "RelayRepetitionFragmentV1",
	batchId: string,
	repetitionIndex: number,
	manifest: HostManifestV1.HostManifest,
	coordinator: {
		started: boolean,
		completed: boolean,
		finalOnlyEvidence: boolean,
		failureFacts: { any },
	},
	participants: { any },
}

export type IssueCode =
	"TYPE"
	| "KEYSET"
	| "ENUM"
	| "RANGE"
	| "RELATION"
	| "LIMIT"
	| "ALIAS"
	| "CYCLE"
	| "METATABLE"
	| "NONCANONICAL"

export type ValidationResult =
	{ kind: "Valid", value: RepetitionFragment }
	| { kind: "Invalid", issue: { code: IssueCode, path: string } }

local SCHEMA = "RelayRepetitionFragmentV1"
local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local MAX_REPETITIONS = 30
local MAX_PARTICIPANTS = 9
local MAX_FAILURES = 39
local MAX_MEASUREMENTS = 7
local MAX_VALUES = 1_000
local MAX_DEPTH = 10
local MAX_TABLE_NODES = 2_048
local MAX_TABLE_ENTRIES = 32_768
local MAX_SCALAR_BYTES = 1_048_576
local ISSUE_MARKER = {}

local function reject(code: IssueCode, path: string): never
	error({ marker = ISSUE_MARKER, code = code, path = path }, 0)
end

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for key, nested in next, value do
		deepFreeze(key)
		deepFreeze(nested)
	end
	table.freeze(value)
end

local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copied = {}
	for key, nested in next, value do
		copied[key] = deepClone(nested)
	end
	return copied
end

local function preflight(root: any)
	local seen: { [table]: string } = {}
	local nodes = 0
	local entries = 0
	local scalarBytes = 0

	local function visit(value: any, depth: number, path: string)
		local valueType = type(value)
		if valueType == "string" then
			scalarBytes += #value
			if scalarBytes > MAX_SCALAR_BYTES then reject("LIMIT", path) end
			return
		elseif valueType == "number" or valueType == "boolean" or valueType == "nil" then
			return
		elseif valueType ~= "table" then
			reject("TYPE", path)
		end
		if getmetatable(value) ~= nil then reject("METATABLE", path) end
		if seen[value] == "active" then reject("CYCLE", path) end
		if seen[value] ~= nil then reject("ALIAS", path) end
		if depth > MAX_DEPTH then reject("LIMIT", path) end
		nodes += 1
		if nodes > MAX_TABLE_NODES then reject("LIMIT", path) end
		seen[value] = "active"
		for key, nested in next, value do
			entries += 1
			if entries > MAX_TABLE_ENTRIES then reject("LIMIT", path) end
			local keyType = type(key)
			if keyType ~= "string" and keyType ~= "number" then reject("TYPE", path) end
			visit(key, depth + 1, path)
			visit(nested, depth + 1, path)
		end
		seen[value] = "done"
	end

	visit(root, 1, "$")
end

local function exactKeys(value: any, expected: { [string]: boolean }, path: string): any
	if type(value) ~= "table" then reject("TYPE", path) end
	local found = 0
	for key in next, value do
		if type(key) ~= "string" or expected[key] ~= true then reject("KEYSET", path) end
		found += 1
	end
	local required = 0
	for _ in expected do required += 1 end
	if found ~= required then reject("KEYSET", path) end
	return value
end

local function conditionalKeys(
	value: any,
	required: { [string]: boolean },
	optional: { [string]: boolean },
	path: string
): any
	if type(value) ~= "table" then reject("TYPE", path) end
	for key in required do
		if rawget(value, key) == nil then reject("KEYSET", path) end
	end
	for key in next, value do
		if type(key) ~= "string" or (required[key] ~= true and optional[key] ~= true) then
			reject("KEYSET", path)
		end
	end
	return value
end

local function denseArray(value: any, maximum: number, path: string): (any, number)
	if type(value) ~= "table" then reject("TYPE", path) end
	local count = 0
	for key in next, value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximum then
			reject("KEYSET", path)
		end
		count += 1
	end
	for index = 1, count do
		if rawget(value, index) == nil then reject("KEYSET", path) end
	end
	return value, count
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: any): boolean
	return value == 0 and 1 / value == -math.huge
end

local function boundedInteger(value: any, minimum: number, maximum: number, path: string): number
	if not isFinite(value)
		or isNegativeZero(value)
		or value % 1 ~= 0
		or value < minimum
		or value > maximum
		or value > MAX_SAFE_INTEGER
	then
		reject(if type(value) == "number" then "RANGE" else "TYPE", path)
	end
	return value
end

local function nonnegativeNumber(value: any, path: string): number
	if not isFinite(value) or isNegativeZero(value) or value < 0 then
		reject(if type(value) == "number" then "RANGE" else "TYPE", path)
	end
	return value
end

local function finiteNumber(value: any, path: string): number
	if not isFinite(value) or isNegativeZero(value) then
		reject(if type(value) == "number" then "RANGE" else "TYPE", path)
	end
	return value
end

local function expectBoolean(value: any, path: string): boolean
	if type(value) ~= "boolean" then reject("TYPE", path) end
	return value
end

local function uuid(value: any, path: string): string
	if type(value) ~= "string" then reject("TYPE", path) end
	if #value ~= 36 or string.match(
		value,
		"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
	) == nil then
		reject("RANGE", path)
	end
	return value
end

local function copyDiscriminator(value: any, kind: string, allowed: { [string]: boolean }, path: string): any
	local source = exactKeys(value, { kind = true, value = true }, path)
	if rawget(source, "kind") ~= kind or allowed[rawget(source, "value")] ~= true then
		reject("ENUM", path)
	end
	return { kind = kind, value = rawget(source, "value") }
end

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

local ONCE_PARTICIPANT_CODES = {
	ControlTrafficDuringMeasuredFrames = true,
	TimingExclusionViolation = true,
	DeliveryObservationLimitExceeded = true,
	InputMutation = true,
	SetupFailure = true,
	InternalError = true,
}

local function copyMismatch(value: any, reason: string, path: string): any
	if type(value) ~= "table" then reject("TYPE", path) end
	local pathKind = rawget(value, "pathKind")
	local actual = rawget(value, "actual")
	if pathKind == "Root" then
		if reason == "ArityMismatch" then
			exactKeys(value, { pathKind = true, actual = true }, path)
			return { pathKind = "Root", actual = boundedInteger(actual, 0, MAX_SAFE_INTEGER, path .. ".actual") }
		elseif reason == "WrongContainerType" or reason == "ExtraField" then
			exactKeys(value, { pathKind = true }, path)
			return { pathKind = "Root" }
		end
	elseif pathKind == "Field" or pathKind == "VectorComponent" then
		local required = { pathKind = true, fieldIndex = true }
		if pathKind == "VectorComponent" then required.component = true end
		local optional = { actual = true }
		conditionalKeys(value, required, optional, path)
		local copied: any = {
			pathKind = pathKind,
			fieldIndex = boundedInteger(rawget(value, "fieldIndex"), 1, 64, path .. ".fieldIndex"),
		}
		if pathKind == "VectorComponent" then
			local component = rawget(value, "component")
			if component ~= "X" and component ~= "Y" and component ~= "Z" then reject("ENUM", path .. ".component") end
			copied.component = component
		end
		if actual ~= nil then
			if type(actual) == "boolean" then
				copied.actual = actual
			else
				copied.actual = finiteNumber(actual, path .. ".actual")
			end
		end
		if reason == "MissingField" or reason == "NonFinite" then
			if actual ~= nil then reject("RELATION", path .. ".actual") end
		elseif reason == "NonInteger" or reason == "OutOfRange" or reason == "NotFloat32" or reason == "ValueMismatch" then
			if actual == nil then reject("RELATION", path .. ".actual") end
		end
		return copied
	end
	reject("RELATION", path)
end

local function factKey(fact: any): string
	local discriminator = rawget(fact, "discriminator")
	return tostring(rawget(fact, "code")) .. "\0" .. tostring(
		if type(discriminator) == "table" then rawget(discriminator, "value") else ""
	)
end

local function copyCoordinatorFact(value: any, repetitionIndex: number, path: string): any
	if type(value) ~= "table" then reject("TYPE", path) end
	local code = rawget(value, "code")
	local occurrences = rawget(value, "occurrences")
	if code == "SetupFailure" or code == "ClockProofFailure" then
		exactKeys(value, { code = true, occurrences = true }, path)
		if occurrences ~= 1 then reject("RANGE", path .. ".occurrences") end
		return { code = code, occurrences = 1 }
	elseif code == "Timeout" or code == "Disconnect" then
		exactKeys(value, { code = true, occurrences = true, firstRepetition = true }, path)
		boundedInteger(occurrences, 1, MAX_SAFE_INTEGER, path .. ".occurrences")
		if rawget(value, "firstRepetition") ~= repetitionIndex then reject("RELATION", path .. ".firstRepetition") end
		return { code = code, occurrences = occurrences, firstRepetition = repetitionIndex }
	elseif code == "InternalError" then
		exactKeys(value, { code = true, occurrences = true, discriminator = true }, path)
		if occurrences ~= 1 then reject("RANGE", path .. ".occurrences") end
		return {
			code = code,
			occurrences = 1,
			discriminator = copyDiscriminator(rawget(value, "discriminator"), "Stage", {
				Setup = true, Execution = true, Finalize = true,
			}, path .. ".discriminator"),
		}
	end
	reject("ENUM", path .. ".code")
end

local function copyParticipantFact(value: any, repetitionIndex: number, path: string): any
	if type(value) ~= "table" then reject("TYPE", path) end
	local code = rawget(value, "code")
	if type(code) ~= "string" or PARTICIPANT_CODES[code] ~= true then reject("ENUM", path .. ".code") end
	local occurrences = boundedInteger(rawget(value, "occurrences"), 1, MAX_SAFE_INTEGER, path .. ".occurrences")
	local first = rawget(value, "firstRepetition")
	if first ~= nil and first ~= repetitionIndex then reject("RELATION", path .. ".firstRepetition") end
	if ONCE_PARTICIPANT_CODES[code] and occurrences ~= 1 then reject("RANGE", path .. ".occurrences") end

	if code == "PayloadMismatch" then
		exactKeys(value, {
			code = true, occurrences = true, discriminator = true, firstRepetition = true,
			fixtureIndex = true, mismatch = true,
		}, path)
		if first ~= repetitionIndex then reject("RELATION", path .. ".firstRepetition") end
		local discriminator = copyDiscriminator(rawget(value, "discriminator"), "MismatchReason", {
			WrongContainerType = true, ArityMismatch = true, MissingField = true, ExtraField = true,
			WrongType = true, NonFinite = true, NonInteger = true, OutOfRange = true,
			NotFloat32 = true, ValueMismatch = true,
		}, path .. ".discriminator")
		return {
			code = code,
			occurrences = occurrences,
			discriminator = discriminator,
			firstRepetition = repetitionIndex,
			fixtureIndex = boundedInteger(rawget(value, "fixtureIndex"), 1, MAX_VALUES, path .. ".fixtureIndex"),
			mismatch = copyMismatch(rawget(value, "mismatch"), discriminator.value, path .. ".mismatch"),
		}
	elseif code == "TimingExclusionViolation" then
		exactKeys(value, { code = true, occurrences = true, discriminator = true }, path)
		return {
			code = code,
			occurrences = 1,
			discriminator = copyDiscriminator(rawget(value, "discriminator"), "TimingExclusion", {
				setup = true, warmup = true, quiescence = true,
			}, path .. ".discriminator"),
		}
	elseif code == "InternalError" then
		exactKeys(value, { code = true, occurrences = true, discriminator = true }, path)
		return {
			code = code,
			occurrences = 1,
			discriminator = copyDiscriminator(rawget(value, "discriminator"), "Stage", {
				Setup = true, Execution = true, Finalize = true,
			}, path .. ".discriminator"),
		}
	elseif code == "SetupFailure" or code == "InputMutation" then
		exactKeys(value, { code = true, occurrences = true }, path)
		return { code = code, occurrences = 1 }
	elseif code == "TeardownFailure" and first == nil then
		exactKeys(value, { code = true, occurrences = true }, path)
		if occurrences ~= 1 then reject("RANGE", path .. ".occurrences") end
		return { code = code, occurrences = 1 }
	end

	exactKeys(value, { code = true, occurrences = true, firstRepetition = true }, path)
	if first ~= repetitionIndex then reject("RELATION", path .. ".firstRepetition") end
	return { code = code, occurrences = occurrences, firstRepetition = repetitionIndex }
end

local function copyFacts(value: any, coordinator: boolean, repetitionIndex: number, path: string): { any }
	local source, count = denseArray(value, MAX_FAILURES, path)
	local copied = table.create(count)
	local seen: { [string]: boolean } = {}
	for index = 1, count do
		local fact = if coordinator
			then copyCoordinatorFact(source[index], repetitionIndex, path .. "[]")
			else copyParticipantFact(source[index], repetitionIndex, path .. "[]")
		local key = factKey(fact)
		if seen[key] then reject("RELATION", path) end
		seen[key] = true
		copied[index] = fact
	end
	return copied
end

local function findDefinition(selection: any): any
	if selection.kind == "Workload" then
		for _, workload in EventV1.workloads do
			if workload.id == selection.workloadId then return workload end
		end
	else
		for _, probe in EventV1.probes do
			if probe.id == selection.probeId then return probe end
		end
	end
	reject("RELATION", "$.manifest.selection")
end

local COMMON_REPETITION = {
	repetitionIndex = true, started = true, completed = true, submitted = true,
	received = true, correct = true, mismatch = true, duplicate = true,
	unexpected = true, outOfOrder = true, staleCallbacks = true, observationOverflow = true,
}

local function copyRepetition(value: any, server: boolean, repetitionIndex: number, path: string): any
	local required = deepClone(COMMON_REPETITION)
	local optional = {}
	if server then
		for _, key in { "probeRequestsReceived", "probeRequestsCorrect", "probeRequestsMismatch", "probeResponsesSubmitted" } do
			required[key] = true
		end
		exactKeys(value, required, path)
	else
		for _, key in { "probeStarted", "probeSubmitted", "probeReceived", "probeCorrect", "probeMismatch" } do
			required[key] = true
		end
		for _, key in {
			"firstSubmissionStartedSharedSeconds", "finalSubmissionReturnedSharedSeconds",
			"finalExpectedDeliveryReceivedSharedSeconds", "finalExpectedDeliveryVerifiedSharedSeconds",
		} do optional[key] = true end
		conditionalKeys(value, required, optional, path)
	end
	if rawget(value, "repetitionIndex") ~= repetitionIndex then reject("RELATION", path .. ".repetitionIndex") end
	expectBoolean(rawget(value, "started"), path .. ".started")
	expectBoolean(rawget(value, "completed"), path .. ".completed")
	expectBoolean(rawget(value, "observationOverflow"), path .. ".observationOverflow")
	for key in required do
		if key ~= "repetitionIndex" and key ~= "started" and key ~= "completed" and key ~= "observationOverflow" then
			boundedInteger(rawget(value, key), 0, MAX_SAFE_INTEGER, path .. "." .. key)
		end
	end
	for key in optional do
		local endpoint = rawget(value, key)
		if endpoint ~= nil then nonnegativeNumber(endpoint, path .. "." .. key) end
	end
	return deepClone(value)
end

local function measurementRules(selection: any, definition: any, participant: any): ({ [number]: number }, { [number]: boolean })
	local allowed: { [number]: number } = {}
	local required: { [number]: boolean } = {}
	if selection.kind == "SeparateProbe" then
		if participant.role == "ProbeClient" then
			allowed[9] = definition.measuredSamples
			required[9] = true
		end
	elseif (participant.role == "Server" and selection.direction == "ServerToClient")
		or (participant.role == "Client" and selection.direction == "ClientToServer")
	then
		allowed[4] = definition.measuredFrames
		allowed[5] = 1
		allowed[10] = definition.measuredFrames * definition.messagesPerFrame
		allowed[11] = definition.measuredFrames
		allowed[12] = definition.measuredFrames * definition.messagesPerFrame
		allowed[13] = 1
		allowed[14] = 1
		required[4] = true
		required[5] = true
		required[10] = true
	end
	return allowed, required
end

local function copyMeasurements(
	value: any,
	selection: any,
	definition: any,
	participant: any,
	repetitionIndex: number,
	started: boolean,
	completed: boolean,
	path: string
): { any }
	local source, count = denseArray(value, MAX_MEASUREMENTS, path)
	if not started and count ~= 0 then reject("RELATION", path) end
	local allowed, required = measurementRules(selection, definition, participant)
	local copied = table.create(count)
	local seen: { [number]: boolean } = {}
	for index = 1, count do
		local record = exactKeys(source[index], {
			measurementIndex = true, repetitionIndex = true, values = true,
		}, path .. "[]")
		local measurementIndex = boundedInteger(rawget(record, "measurementIndex"), 1, 14, path .. "[].measurementIndex")
		local expected = allowed[measurementIndex]
		if expected == nil or seen[measurementIndex] then reject("RELATION", path .. "[].measurementIndex") end
		seen[measurementIndex] = true
		if rawget(record, "repetitionIndex") ~= repetitionIndex then reject("RELATION", path .. "[].repetitionIndex") end
		local valuesSource, valueCount = denseArray(rawget(record, "values"), math.min(MAX_VALUES, expected), path .. "[].values")
		if completed and valueCount ~= expected then reject("RELATION", path .. "[].values") end
		local values = table.create(valueCount)
		for valueIndex = 1, valueCount do
			values[valueIndex] = nonnegativeNumber(valuesSource[valueIndex], path .. "[].values[]")
		end
		copied[index] = {
			measurementIndex = measurementIndex,
			repetitionIndex = repetitionIndex,
			values = values,
		}
	end
	if completed then
		for measurementIndex in required do
			if not seen[measurementIndex] then reject("RELATION", path) end
		end
	end
	return copied
end

local function copyEndpoint(value: any, repetitionIndex: number, started: boolean, path: string): any
	local endpoint = conditionalKeys(value, { repetitionIndex = true }, {
		firstSubmissionStartedSharedSeconds = true,
		finalSubmissionReturnedSharedSeconds = true,
		finalExpectedDeliveryReceivedSharedSeconds = true,
		finalExpectedDeliveryVerifiedSharedSeconds = true,
	}, path)
	if rawget(endpoint, "repetitionIndex") ~= repetitionIndex then reject("RELATION", path .. ".repetitionIndex") end
	local copied: any = { repetitionIndex = repetitionIndex }
	for _, key in {
		"firstSubmissionStartedSharedSeconds", "finalSubmissionReturnedSharedSeconds",
		"finalExpectedDeliveryReceivedSharedSeconds", "finalExpectedDeliveryVerifiedSharedSeconds",
	} do
		local scalar = rawget(endpoint, key)
		if scalar ~= nil then
			if not started then reject("RELATION", path .. "." .. key) end
			copied[key] = nonnegativeNumber(scalar, path .. "." .. key)
		end
	end
	return copied
end

local function copyConformance(value: any, path: string): any
	local source = exactKeys(value, {
		setupExcluded = true, warmupExcluded = true, quiescenceExcluded = true,
		resultExtractionExcluded = true, clockProofPassed = true,
	}, path)
	local copied = {}
	for key in source do copied[key] = expectBoolean(rawget(source, key), path .. "." .. key) end
	return copied
end

local function copyParticipant(
	value: any,
	position: number,
	selection: any,
	definition: any,
	repetitionIndex: number,
	coordinatorStarted: boolean,
	coordinatorCompleted: boolean,
	path: string
): any
	local source = exactKeys(value, { participant = true, evidence = true }, path)
	local participantSource = rawget(source, "participant")
	local participant: any
	if position == 1 then
		exactKeys(participantSource, { role = true }, path .. ".participant")
		if rawget(participantSource, "role") ~= "Server" then reject("RELATION", path .. ".participant.role") end
		participant = { role = "Server" }
	else
		exactKeys(participantSource, { role = true, index = true }, path .. ".participant")
		local expectedRole = if selection.kind == "SeparateProbe" then "ProbeClient" else "Client"
		if rawget(participantSource, "role") ~= expectedRole or rawget(participantSource, "index") ~= position - 1 then
			reject("RELATION", path .. ".participant")
		end
		participant = { role = expectedRole, index = position - 1 }
	end

	local server = position == 1
	local evidence = exactKeys(rawget(source, "evidence"), if server
		then { version = true, repetitions = true, measurements = true, timingEndpoints = true, failureFacts = true, conformance = true }
		else { version = true, repetitions = true, measurements = true, failureFacts = true, conformance = true }, path .. ".evidence")
	if rawget(evidence, "version") ~= 1 then reject("ENUM", path .. ".evidence.version") end
	local repetitions, repetitionCount = denseArray(rawget(evidence, "repetitions"), 1, path .. ".evidence.repetitions")
	if repetitionCount ~= 1 then reject("RELATION", path .. ".evidence.repetitions") end
	local repetition = copyRepetition(repetitions[1], server, repetitionIndex, path .. ".evidence.repetitions[]")
	if repetition.started ~= coordinatorStarted then reject("RELATION", path .. ".evidence.repetitions[].started") end
	if coordinatorCompleted and not repetition.completed then reject("RELATION", path .. ".evidence.repetitions[].completed") end

	local copiedEvidence: any = {
		version = 1,
		repetitions = { repetition },
		measurements = copyMeasurements(
			rawget(evidence, "measurements"), selection, definition, participant,
			repetitionIndex, coordinatorStarted, coordinatorCompleted, path .. ".evidence.measurements"
		),
		failureFacts = copyFacts(rawget(evidence, "failureFacts"), false, repetitionIndex, path .. ".evidence.failureFacts"),
		conformance = copyConformance(rawget(evidence, "conformance"), path .. ".evidence.conformance"),
	}
	if server then
		local endpoints, endpointCount = denseArray(rawget(evidence, "timingEndpoints"), 1, path .. ".evidence.timingEndpoints")
		local expectedEndpoints = if coordinatorStarted then 1 else 0
		if endpointCount ~= expectedEndpoints then reject("RELATION", path .. ".evidence.timingEndpoints") end
		copiedEvidence.timingEndpoints = if coordinatorStarted
			then { copyEndpoint(endpoints[1], repetitionIndex, true, path .. ".evidence.timingEndpoints[]") }
			else {}
	end
	return { participant = participant, evidence = copiedEvidence }
end

local function isSender(selection: any, participant: any): boolean
	if selection.kind == "SeparateProbe" then
		return participant.role == "Server" or participant.role == "ProbeClient"
	end
	return (selection.direction == "ClientToServer" and participant.role == "Client")
		or (selection.direction == "ServerToClient" and participant.role == "Server")
end

local function isReceiver(selection: any, participant: any): boolean
	if selection.kind == "SeparateProbe" then return true end
	return (selection.direction == "ClientToServer" and participant.role == "Server")
		or (selection.direction == "ServerToClient" and participant.role == "Client")
end

local function factsByCode(facts: { any }): { [string]: number }
	local totals: { [string]: number } = {}
	for _, fact in facts do
		local previous = totals[fact.code] or 0
		if fact.occurrences > MAX_SAFE_INTEGER - previous then reject("RANGE", "$.participants[].evidence.failureFacts") end
		totals[fact.code] = previous + fact.occurrences
	end
	return totals
end

local function validateEndpointRelations(repetition: any, selection: any, participant: any, path: string)
	local first = rawget(repetition, "firstSubmissionStartedSharedSeconds")
	local final = rawget(repetition, "finalSubmissionReturnedSharedSeconds")
	local received = rawget(repetition, "finalExpectedDeliveryReceivedSharedSeconds")
	local verified = rawget(repetition, "finalExpectedDeliveryVerifiedSharedSeconds")
	if final ~= nil and first == nil then reject("RELATION", path) end
	if first ~= nil and final ~= nil and final < first then reject("RELATION", path) end
	if (received == nil) ~= (verified == nil) then reject("RELATION", path) end
	if received ~= nil and verified < received then reject("RELATION", path) end
	if selection.kind == "SeparateProbe" then
		if first ~= nil or final ~= nil or received ~= nil or verified ~= nil then reject("RELATION", path) end
	elseif isSender(selection, participant) then
		if received ~= nil or verified ~= nil then reject("RELATION", path) end
	elseif first ~= nil or final ~= nil then
		reject("RELATION", path)
	end
end

local function validateFragmentSemantics(
	selection: any,
	definition: any,
	coordinator: any,
	participants: { any }
)
	local expected = if selection.kind == "Workload"
		then definition.senderCount * definition.measuredFrames * definition.messagesPerFrame
		else definition.measuredSamples
	local anyClockFailure = false
	local inputMutationSenders = 0
	local extraCompletedReceivers = 0

	for _, participantSnapshot in participants do
		local participant = participantSnapshot.participant
		local evidence = participantSnapshot.evidence
		local repetition = evidence.repetitions[1]
		local path = "$.participants[].evidence.repetitions[]"
		if repetition.received ~= repetition.correct + repetition.mismatch + repetition.duplicate + repetition.unexpected
			or repetition.outOfOrder > repetition.correct + repetition.mismatch
		then
			reject("RELATION", path)
		end
		if not repetition.started then
			for _, key in {
				"submitted", "received", "correct", "mismatch", "duplicate", "unexpected",
				"outOfOrder", "staleCallbacks",
			} do
				if repetition[key] ~= 0 then reject("RELATION", path .. "." .. key) end
			end
			if repetition.observationOverflow then reject("RELATION", path .. ".observationOverflow") end
		end

		local server = participant.role == "Server"
		if server then
			if coordinator.started then
				local endpoint = evidence.timingEndpoints[1]
				validateEndpointRelations(endpoint, selection, participant, "$.participants[].evidence.timingEndpoints[]")
			end
			if selection.kind == "SeparateProbe" then
				if repetition.submitted ~= 0 or repetition.received ~= 0
					or repetition.probeRequestsReceived ~= repetition.probeRequestsCorrect + repetition.probeRequestsMismatch
					or repetition.probeResponsesSubmitted > repetition.probeRequestsCorrect
					or repetition.probeRequestsReceived > 4 * expected
					or repetition.probeResponsesSubmitted > expected
				then reject("RELATION", path) end
				if repetition.completed
					and (repetition.probeRequestsReceived ~= expected
						or repetition.probeResponsesSubmitted ~= repetition.probeRequestsCorrect)
				then reject("RELATION", path) end
			elseif selection.direction == "ClientToServer" then
				if repetition.submitted ~= 0
					or repetition.probeRequestsReceived ~= 0
					or repetition.probeRequestsCorrect ~= 0
					or repetition.probeRequestsMismatch ~= 0
					or repetition.probeResponsesSubmitted ~= 0
					or repetition.correct + repetition.mismatch > expected
				then reject("RELATION", path) end
				if repetition.completed and not coordinator.finalOnlyEvidence
					and repetition.correct + repetition.mismatch ~= expected
				then reject("RELATION", path) end
			else
				if repetition.received ~= 0 or repetition.correct ~= 0 or repetition.mismatch ~= 0
					or repetition.duplicate ~= 0 or repetition.unexpected ~= 0 or repetition.outOfOrder ~= 0
					or repetition.staleCallbacks ~= 0 or repetition.observationOverflow
					or repetition.probeRequestsReceived ~= 0 or repetition.probeRequestsCorrect ~= 0
					or repetition.probeRequestsMismatch ~= 0 or repetition.probeResponsesSubmitted ~= 0
					or repetition.submitted > expected
				then reject("RELATION", path) end
				if repetition.completed and repetition.submitted ~= expected then reject("RELATION", path) end
			end
		else
			validateEndpointRelations(repetition, selection, participant, path)
			if selection.kind == "SeparateProbe" then
				if repetition.submitted ~= 0 or repetition.received ~= 0
					or repetition.probeReceived ~= repetition.probeCorrect + repetition.probeMismatch
					or repetition.probeReceived > repetition.probeSubmitted
					or repetition.probeSubmitted > repetition.probeStarted
					or repetition.probeStarted > expected
				then reject("RELATION", path) end
				if repetition.completed and (repetition.probeStarted ~= expected
					or repetition.probeSubmitted ~= expected or repetition.probeReceived ~= expected)
				then reject("RELATION", path) end
			elseif selection.direction == "ClientToServer" then
				if repetition.received ~= 0 or repetition.correct ~= 0 or repetition.mismatch ~= 0
					or repetition.duplicate ~= 0 or repetition.unexpected ~= 0 or repetition.outOfOrder ~= 0
					or repetition.staleCallbacks ~= 0 or repetition.observationOverflow
					or repetition.probeStarted ~= 0 or repetition.probeSubmitted ~= 0
					or repetition.probeReceived ~= 0 or repetition.probeCorrect ~= 0 or repetition.probeMismatch ~= 0
					or repetition.submitted > expected
				then reject("RELATION", path) end
				if repetition.submitted > 0 and repetition.firstSubmissionStartedSharedSeconds == nil then
					reject("RELATION", path)
				end
				if repetition.completed and (repetition.submitted ~= expected
					or repetition.finalSubmissionReturnedSharedSeconds == nil)
				then reject("RELATION", path) end
			else
				if repetition.submitted ~= 0
					or repetition.probeStarted ~= 0 or repetition.probeSubmitted ~= 0
					or repetition.probeReceived ~= 0 or repetition.probeCorrect ~= 0 or repetition.probeMismatch ~= 0
					or repetition.correct + repetition.mismatch > expected
				then reject("RELATION", path) end
				if repetition.completed and not coordinator.finalOnlyEvidence
					and repetition.correct + repetition.mismatch ~= expected
				then reject("RELATION", path) end
				if repetition.completed and repetition.correct + repetition.mismatch == expected
					and repetition.finalExpectedDeliveryReceivedSharedSeconds == nil
				then reject("RELATION", path) end
			end
		end

		local totals = factsByCode(evidence.failureFacts)
		local mismatch = if selection.kind == "SeparateProbe"
			then (if server then repetition.probeRequestsMismatch else repetition.probeMismatch)
			else repetition.mismatch
		if (totals.DuplicateDelivery or 0) ~= repetition.duplicate
			or (totals.UnexpectedDelivery or 0) ~= repetition.unexpected
			or (totals.OutOfOrderDelivery or 0) ~= repetition.outOfOrder
			or (totals.PayloadMismatch or 0) ~= mismatch
			or (totals.StaleCallback or 0) ~= repetition.staleCallbacks
		then reject("RELATION", "$.participants[].evidence.failureFacts") end
		if repetition.observationOverflow ~= ((totals.DeliveryObservationLimitExceeded or 0) == 1) then
			reject("RELATION", "$.participants[].evidence.failureFacts")
		end
		for _, fact in evidence.failureFacts do
			local code = fact.code
			if (code == "DuplicateDelivery" or code == "UnexpectedDelivery" or code == "OutOfOrderDelivery"
				or code == "PayloadMismatch" or code == "StaleCallback" or code == "DeliveryObservationLimitExceeded")
				and not isReceiver(selection, participant)
			then reject("RELATION", "$.participants[].evidence.failureFacts") end
			if code == "SubmitFailure" or code == "InputMutation" then
				if not isSender(selection, participant) then reject("RELATION", "$.participants[].evidence.failureFacts") end
				if code == "InputMutation" then
					inputMutationSenders += 1
					local accepted = if selection.kind == "SeparateProbe"
						then (if server then repetition.probeResponsesSubmitted > 0 else repetition.probeSubmitted > 0)
						else repetition.submitted > 0
					if coordinator.started and (coordinator.completed or not accepted) then
						reject("RELATION", "$.participants[].evidence.failureFacts")
					end
				end
			end
		end
		for _, exclusion in { "setup", "warmup", "quiescence" } do
			local confirmed = evidence.conformance[exclusion .. "Excluded"]
			local present = false
			for _, fact in evidence.failureFacts do
				present = present or (fact.code == "TimingExclusionViolation" and fact.discriminator.value == exclusion)
			end
			if confirmed == present then reject("RELATION", "$.participants[].evidence.conformance") end
		end
		if not evidence.conformance.resultExtractionExcluded then
			reject("RELATION", "$.participants[].evidence.conformance.resultExtractionExcluded")
		end
		anyClockFailure = anyClockFailure or not evidence.conformance.clockProofPassed
		if repetition.completed ~= coordinator.completed then
			if not isReceiver(selection, participant) or not coordinator.started or coordinator.completed then
				reject("RELATION", path .. ".completed")
			end
			extraCompletedReceivers += 1
		end
	end

	if extraCompletedReceivers > 0 and inputMutationSenders == 0 then reject("RELATION", "$.participants") end
	local coordinatorTotals = factsByCode(coordinator.failureFacts)
	if anyClockFailure ~= ((coordinatorTotals.ClockProofFailure or 0) == 1) then
		reject("RELATION", "$.coordinator.failureFacts")
	end
	if not coordinator.started and coordinator.completed then reject("RELATION", "$.coordinator") end
end

local function copyFragment(candidate: any): RepetitionFragment
	local root = exactKeys(candidate, {
		schema = true, batchId = true, repetitionIndex = true, manifest = true,
		coordinator = true, participants = true,
	}, "$")
	if rawget(root, "schema") ~= SCHEMA then reject("ENUM", "$.schema") end
	local batchId = uuid(rawget(root, "batchId"), "$.batchId")
	local repetitionIndex = boundedInteger(rawget(root, "repetitionIndex"), 1, MAX_REPETITIONS, "$.repetitionIndex")
	local checkedManifest = HostManifestV1.validate(rawget(root, "manifest"))
	if checkedManifest.kind ~= "Valid" then
		reject(checkedManifest.issue.code :: IssueCode, "$.manifest" .. string.sub(checkedManifest.issue.path, 2))
	end
	local manifest = checkedManifest.value
	if manifest.launchId == batchId then reject("RELATION", "$.manifest.launchId") end
	if manifest.adapter.identity.semantics.repetitionIsolation ~= "ProcessRestart" then
		reject("RELATION", "$.manifest.adapter.identity.semantics.repetitionIsolation")
	end
	local resolved = Identity.resolveSelection(manifest.selection)
	if resolved.kind ~= "Valid" then reject("RELATION", "$.manifest.selection") end
	local selection = resolved.value
	local definition = findDefinition(selection)
	if definition.repetitions ~= MAX_REPETITIONS then reject("RELATION", "$.manifest.selection") end

	local coordinatorSource = exactKeys(rawget(root, "coordinator"), {
		started = true, completed = true, finalOnlyEvidence = true, failureFacts = true,
	}, "$.coordinator")
	local started = expectBoolean(rawget(coordinatorSource, "started"), "$.coordinator.started")
	local completed = expectBoolean(rawget(coordinatorSource, "completed"), "$.coordinator.completed")
	if completed and not started then reject("RELATION", "$.coordinator.completed") end
	local coordinator = {
		started = started,
		completed = completed,
		finalOnlyEvidence = expectBoolean(rawget(coordinatorSource, "finalOnlyEvidence"), "$.coordinator.finalOnlyEvidence"),
		failureFacts = copyFacts(rawget(coordinatorSource, "failureFacts"), true, repetitionIndex, "$.coordinator.failureFacts"),
	}

	local participantsSource, participantCount = denseArray(rawget(root, "participants"), MAX_PARTICIPANTS, "$.participants")
	local expectedParticipants = selection.clientProcessCount + 1
	if participantCount ~= expectedParticipants then reject("RELATION", "$.participants") end
	local participants = table.create(participantCount)
	for position = 1, participantCount do
		participants[position] = copyParticipant(
			participantsSource[position], position, selection, definition, repetitionIndex,
			started, completed, "$.participants[]"
		)
	end
	validateFragmentSemantics(selection, definition, coordinator, participants)

	return {
		schema = SCHEMA,
		batchId = batchId,
		repetitionIndex = repetitionIndex,
		manifest = manifest,
		coordinator = coordinator,
		participants = participants,
	}
end

local function validate(candidate: unknown): ValidationResult
	local ok, output = pcall(function(): RepetitionFragment
		preflight(candidate)
		local fragment = copyFragment(candidate)
		deepFreeze(fragment)
		return fragment
	end)
	if not ok then
		if type(output) ~= "table" or rawget(output, "marker") ~= ISSUE_MARKER then
			error(output, 0)
		end
		local invalid: ValidationResult = {
			kind = "Invalid",
			issue = { code = rawget(output, "code"), path = rawget(output, "path") },
		}
		deepFreeze(invalid)
		return invalid
	end
	local valid: ValidationResult = { kind = "Valid", value = output }
	deepFreeze(valid)
	return valid
end

local RepetitionFragmentV1 = {
	MAX_JSON_BYTES = MAX_SCALAR_BYTES,
	validate = validate,
}

table.freeze(RepetitionFragmentV1)

return RepetitionFragmentV1
