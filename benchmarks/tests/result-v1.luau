local serde = require("@lune/serde")

local Contract = require("../contracts/event-v1")
local Identity = require("../contracts/internal/AdapterIdentity")
local ResultV1 = require("../contracts/result-v1")
local DeliveryLedger = require("../correctness/DeliveryLedger")
local PayloadComparator = require("../correctness/PayloadComparator")
local Fixtures = require("../fixtures/event-v1")

local MAX_SAFE_INTEGER = 9_007_199_254_740_991

local function deepClone(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end
	local result = {}
	seen[value] = result
	for key, nested in value do
		result[deepClone(key, seen)] = deepClone(nested, seen)
	end
	return result
end

local function assertDeepEqual(actual, expected, path, seen)
	path = path or "$"
	if type(actual) ~= type(expected) then
		error(`{path}: type differs ({type(actual)} ~= {type(expected)})`, 0)
	end
	if type(actual) ~= "table" then
		if type(actual) == "number" and actual ~= actual and expected ~= expected then
			return
		end
		assert(actual == expected, `{path}: {tostring(actual)} ~= {tostring(expected)}`)
		return
	end
	seen = seen or {}
	if seen[actual] ~= nil then
		assert(seen[actual] == expected, `{path}: table alias differs`)
		return
	end
	seen[actual] = expected
	local actualCount = 0
	for key, nested in actual do
		actualCount += 1
		assert(rawget(expected, key) ~= nil, `{path}: unexpected key {tostring(key)}`)
		assertDeepEqual(nested, rawget(expected, key), `{path}.{tostring(key)}`, seen)
	end
	local expectedCount = 0
	for _ in expected do
		expectedCount += 1
	end
	assert(actualCount == expectedCount, `{path}: key count differs`)
end

local function assertExactKeys(value, expectedKeys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local allowed = {}
	for _, key in expectedKeys do
		allowed[key] = true
	end
	local count = 0
	for key in value do
		count += 1
		assert(allowed[key], `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #expectedKeys, `{label} key count differs`)
end

local function assertRejected(operation, expectedCode, label, redacted)
	local ok, failure = pcall(operation)
	assert(not ok, `{label} must reject`)
	local message = tostring(failure)
	assert(string.sub(message, 1, #expectedCode) == expectedCode, `{label} expected {expectedCode}, got {message}`)
	if redacted ~= nil then
		assert(string.find(message, redacted, 1, true) == nil, `{label} leaked rejected input`)
	end
	return message
end

local function assertDeepFrozen(value, seen, path)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	path = path or "$"
	if seen[value] then
		return
	end
	seen[value] = true
	assert(table.isfrozen(value), `{path} must be frozen`)
	for key, nested in value do
		assertDeepFrozen(key, seen, `{path}.<key>`)
		assertDeepFrozen(nested, seen, `{path}.{tostring(key)}`)
	end
end

local function assertIdentityIssue(candidate, mode, studioVersion, expectedCode, expectedPath, label)
	local result = Identity.check(candidate, mode, studioVersion, "$.adapter")
	assert(result.kind == "Invalid", `{label} must reject through shared identity validation`)
	assert(result.issue.code == expectedCode, `{label} expected {expectedCode}, got {result.issue.code}`)
	assert(result.issue.path == expectedPath, `{label} expected {expectedPath}, got {result.issue.path}`)
	assertDeepFrozen(result)
	return result
end

local function collectTables(value, found)
	if type(value) ~= "table" or found[value] then
		return
	end
	found[value] = true
	for key, nested in value do
		collectTables(key, found)
		collectTables(nested, found)
	end
end

local function assertDetached(input, output, label)
	local inputTables = {}
	local outputTables = {}
	collectTables(input, inputTables)
	collectTables(output, outputTables)
	for outputTable in outputTables do
		assert(not inputTables[outputTable], `{label} shares an input table`)
	end
end

local function findWorkload(workloadId)
	for _, workload in Contract.workloads do
		if workload.id == workloadId then
			return workload
		end
	end
	error(`unknown test workload {workloadId}`, 0)
end

local function findProbe(probeId)
	for _, probe in Contract.probes do
		if probe.id == probeId then
			return probe
		end
	end
	error(`unknown test probe {probeId}`, 0)
end

local function repositoryAdapter()
	return {
		id = "repo-adapter",
		displayName = "Repository Adapter",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "repo-library",
			displayName = "Repository Library",
			version = "1.2.3",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/relay-adapter",
				revision = string.rep("d", 40),
				checksum = "sha256:" .. string.rep("e", 64),
				license = "MIT",
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "SessionRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function engineAdapter()
	return {
		id = "engine-adapter",
		displayName = "Engine Adapter",
		lane = "NativeBest",
		integrationKind = "EngineBuiltIn",
		library = {
			id = "engine-library",
			displayName = "Engine Library",
			version = "0.650.0.6500000",
			provenance = {
				kind = "EngineBuiltIn",
				studioVersion = "0.650.0.6500000",
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "ProcessRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function environmentFor(caseValue, studioVersion)
	local clientCount
	if caseValue.kind == "SeparateProbe" then
		clientCount = caseValue.clientCount
	elseif caseValue.workloadId == "state-broadcast-s2c" then
		clientCount = caseValue.recipientCount
	else
		clientCount = caseValue.senderCount
	end
	return {
		studio = {
			version = studioVersion or "0.650.0.6500000",
			channel = "production",
		},
		host = {
			osFamily = "Windows",
			osVersion = "11",
			architecture = "x86_64",
			cpuModel = "Test CPU",
			logicalProcessorCount = 8,
			memoryMiB = 16_384,
			gpuModel = "Test GPU",
		},
		execution = {
			mode = "StudioMultiplayer",
			targetFrameRate = Contract.execution.targetFrameRate,
			serverCount = 1,
			clientCount = clientCount,
		},
	}
end

local function conformingClockProof(passed)
	return {
		timingExclusionsConfirmed = {
			setup = true,
			warmup = true,
			quiescence = true,
			resultExtraction = true,
		},
		localClock = deepClone(Contract.clocks.localDuration),
		sharedClock = deepClone(Contract.clocks.shared),
		clockProof = {
			version = 1,
			passed = if passed == nil then true else passed,
		},
	}
end

local function completeWorkloadCase(workloadId, recipientCount)
	local workload = findWorkload(workloadId)
	return {
		kind = "Workload",
		workloadId = workload.id,
		senderCount = workload.senderCount,
		recipientCount = recipientCount or workload.recipientCounts[1],
		scheduledRepetitions = workload.repetitions,
		startedRepetitions = workload.repetitions,
		completedRepetitions = workload.repetitions,
	}, workload
end

local function completeProbeCase(probeId)
	local probe = findProbe(probeId)
	return {
		kind = "SeparateProbe",
		probeId = probe.id,
		clientCount = probe.clientCount,
		scheduledRepetitions = probe.repetitions,
		startedRepetitions = probe.repetitions,
		completedRepetitions = probe.repetitions,
	}, probe
end

local function plannedCounts(caseValue, workload, overrides)
	local expectedSubmissions = caseValue.scheduledRepetitions
		* caseValue.senderCount
		* workload.measuredFrames
		* workload.messagesPerFrame
	local expectedDeliveries = expectedSubmissions * caseValue.recipientCount
	local result = {
		finality = "Final",
		expectedSubmissions = expectedSubmissions,
		submitted = expectedSubmissions,
		expectedDeliveries = expectedDeliveries,
		received = expectedDeliveries,
		correct = expectedDeliveries,
		missing = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
	}
	if overrides ~= nil then
		for key, value in overrides do
			result[key] = value
		end
	end
	return result
end

local function measurementDefinitions(caseValue)
	local selected = {}
	for _, measurement in Contract.measurements do
		if measurement.scope == caseValue.kind then
			if caseValue.kind ~= "SeparateProbe" or measurement.probeId == caseValue.probeId then
				table.insert(selected, measurement)
			end
		end
	end
	return selected
end

local function valuesPerGroup(measurement, caseDefinition)
	local cadence = measurement.capture.cadence
	if cadence == "PerMeasuredFrame" then
		return caseDefinition.measuredFrames
	elseif cadence == "PerRepetition" then
		return 1
	elseif cadence == "PerSubmission" then
		return caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
	elseif cadence == "PerProbe" then
		return caseDefinition.measuredSamples
	end
	error(`unhandled cadence {tostring(cadence)}`, 0)
end

local function participantCount(measurement, caseDefinition)
	if measurement.capture.role == "Sender" then
		return caseDefinition.senderCount
	elseif measurement.capture.role == "ProbeClient" then
		return caseDefinition.clientCount
	end
	return 1
end

local function buildRawSamples(measurement, caseValue, caseDefinition, options)
	local perGroup = valuesPerGroup(measurement, caseDefinition)
	local participants = participantCount(measurement, caseDefinition)
	local total = caseValue.scheduledRepetitions * participants * perGroup
	local groups = table.create(caseValue.scheduledRepetitions * participants)
	local cursor = 0
	for repetitionIndex = 1, caseValue.scheduledRepetitions do
		for participantIndex = 1, participants do
			local values = table.create(perGroup)
			for valueIndex = 1, perGroup do
				cursor += 1
				local value
				local byRepetition = options.countValuesByRepetition
				if byRepetition ~= nil and byRepetition[measurement.id] ~= nil then
					value = byRepetition[measurement.id][repetitionIndex]
				elseif options.valueProviders ~= nil and options.valueProviders[measurement.id] ~= nil then
					value = options.valueProviders[measurement.id](cursor, total)
				elseif options.descending then
					value = total - cursor + 1
				else
					value = cursor
				end
				values[valueIndex] = value
			end
			local group = {
				repetitionIndex = repetitionIndex,
				values = values,
			}
			if measurement.capture.role == "Sender" or measurement.capture.role == "ProbeClient" then
				group.participantIndex = participantIndex
			end
			table.insert(groups, group)
		end
	end
	if options.reverseGroups then
		local reversed = table.create(#groups)
		for index = 1, #groups do
			reversed[index] = groups[#groups - index + 1]
		end
		return reversed
	end
	return groups
end

local function buildMeasurements(caseValue, caseDefinition, mode, options)
	options = options or {}
	local measurements = {}
	for _, measurement in measurementDefinitions(caseValue) do
		local requestedReason = options.unavailableById and options.unavailableById[measurement.id]
		local state
		local reason
		if requestedReason ~= nil then
			state = "Unavailable"
			reason = requestedReason
		elseif mode == "Unavailable" then
			state = "Unavailable"
			reason = options.unavailableReason
		elseif mode == "InvalidCompleted" and measurement.summary == "MedianAndP95" then
			state = "Diagnostic"
		else
			state = "Available"
		end

		if state == "Unavailable" then
			table.insert(measurements, {
				id = measurement.id,
				state = state,
				unavailableReason = { code = reason },
			})
		else
			local rawSamples = buildRawSamples(measurement, caseValue, caseDefinition, options)
			if measurement.summary == "Exact" and options.exactTotals ~= nil and options.exactTotals[measurement.id] ~= nil then
				local expectedTotal = options.exactTotals[measurement.id]
				local actualTotal = 0
				for _, group in rawSamples do
					for _, value in group.values do
						actualTotal += value
					end
				end
				assert(actualTotal == expectedTotal, `{measurement.id} builder total differs`)
			end
			table.insert(measurements, {
				id = measurement.id,
				state = state,
				rawSamples = rawSamples,
			})
		end
	end
	return measurements
end

local function requiredMeasurementFailures(caseValue)
	local failures = {}
	for _, measurement in measurementDefinitions(caseValue) do
		if measurement.availability == "Required" then
			table.insert(failures, {
				category = "Measurement",
				code = "RequiredMeasurementUnavailable",
				occurrences = 1,
				discriminator = { measurementId = measurement.id },
			})
		end
	end
	return failures
end

local function makeDraft(caseValue, adapter, failures, counts, conformance, measurements, studioVersion)
	local draft = {
		runId = "11111111-2222-4333-8444-555555555555",
		benchmarkSource = {
			revision = string.rep("a", 40),
			dirty = true,
		},
		contractFingerprint = "sha256:" .. string.rep("c", 64),
		adapter = adapter,
		case = caseValue,
		failures = failures,
		conformance = conformance,
		measurements = measurements,
		environment = environmentFor(caseValue, studioVersion),
	}
	if counts ~= nil then
		draft.counts = counts
	end
	return draft
end

local function closeCleanLedger(workloadId)
	local fixture = Fixtures.generate(workloadId, 1)
	local ledger = DeliveryLedger.new(fixture.measured)
	for _, submission in fixture.measured do
		local status = ledger:recordDelivery(submission.payloadId, submission.sequence, true)
		assert(status == "Expected", "clean ledger delivery must be expected")
	end
	local clean, snapshot = ledger:close()
	assert(clean, "clean ledger must close cleanly")
	assert(table.isfrozen(snapshot), "clean ledger snapshot must be frozen")
	return snapshot
end

local function closeFaultLedgerAndMismatch()
	local fixture = Fixtures.generate("state-steady-c2s", 1)
	local submissions = fixture.measured
	local ledger = DeliveryLedger.new(submissions)
	ledger:recordDelivery(submissions[2].payloadId, submissions[2].sequence, true)
	ledger:recordDelivery(submissions[2].payloadId, submissions[2].sequence, true)
	ledger:recordDelivery("tiny", 0, true)
	ledger:recordDelivery(submissions[1].payloadId, submissions[1].sequence, false)
	for index = 3, #submissions - 1 do
		local submission = submissions[index]
		ledger:recordDelivery(submission.payloadId, submission.sequence, true)
	end
	local clean, snapshot = ledger:close()
	assert(not clean, "fault ledger must close dirty")

	local actual = deepClone(submissions[1].expected)
	actual.health = submissions[1].expected.health - 1
	local payloadMatches, mismatch = PayloadComparator.compareRecord("state", submissions[1].expected, actual)
	assert(not payloadMatches and mismatch ~= nil, "real comparator must retain a health mismatch")
	assert(mismatch.path == "health" and mismatch.reason == "ValueMismatch", "real mismatch shape drifted")
	return snapshot, deepClone(mismatch)
end

local function canonicalWorkloadDraft()
	local caseValue, workload = completeWorkloadCase("state-burst-c2s", 1)
	local snapshot = closeCleanLedger(workload.id)
	local counts = plannedCounts(caseValue, workload, {
		received = snapshot.received * caseValue.scheduledRepetitions,
		correct = snapshot.correct * caseValue.scheduledRepetitions,
	})
	local perRepetition = snapshot.expectedDeliveries
	local countValues = {
		submitted = table.create(caseValue.scheduledRepetitions, perRepetition),
		received = table.create(caseValue.scheduledRepetitions, snapshot.received),
		correct = table.create(caseValue.scheduledRepetitions, snapshot.correct),
	}
	local measurements = buildMeasurements(caseValue, workload, "Available", {
		countValuesByRepetition = countValues,
		exactTotals = {
			submitted = counts.submitted,
			received = counts.received,
			correct = counts.correct,
		},
	})
	return makeDraft(caseValue, repositoryAdapter(), {}, counts, conformingClockProof(), measurements), snapshot
end

local function canonicalProbeDraft(options)
	options = options or {}
	local caseValue, probe = completeProbeCase("tiny-round-trip")
	local measurements = buildMeasurements(caseValue, probe, "Available", options)
	local adapter = options.adapter or engineAdapter()
	local studioVersion = if adapter.integrationKind == "EngineBuiltIn" then adapter.library.version else nil
	return makeDraft(caseValue, adapter, {}, nil, conformingClockProof(), measurements, studioVersion)
end

local function unavailableMeasurements(caseValue, caseDefinition, reason)
	return buildMeasurements(caseValue, caseDefinition, "Unavailable", { unavailableReason = reason })
end

local function completedInvalidDraft()
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	local cleanSnapshot = closeCleanLedger(workload.id)
	local faultSnapshot, mismatch = closeFaultLedgerAndMismatch()
	local repetitionsAfterFault = caseValue.scheduledRepetitions - 1
	local counts = plannedCounts(caseValue, workload, {
		received = faultSnapshot.received + cleanSnapshot.received * repetitionsAfterFault,
		correct = faultSnapshot.correct + cleanSnapshot.correct * repetitionsAfterFault,
		missing = faultSnapshot.missing,
		duplicate = faultSnapshot.duplicate,
		unexpected = faultSnapshot.unexpected,
		outOfOrder = faultSnapshot.outOfOrder,
		mismatch = faultSnapshot.mismatch,
	})
	local countValues = {
		submitted = table.create(caseValue.scheduledRepetitions, cleanSnapshot.expectedDeliveries),
		received = table.create(caseValue.scheduledRepetitions, cleanSnapshot.received),
		correct = table.create(caseValue.scheduledRepetitions, cleanSnapshot.correct),
	}
	countValues.received[1] = faultSnapshot.received
	countValues.correct[1] = faultSnapshot.correct
	local measurements = buildMeasurements(caseValue, workload, "InvalidCompleted", {
		countValuesByRepetition = countValues,
		exactTotals = {
			submitted = counts.submitted,
			received = counts.received,
			correct = counts.correct,
		},
	})
	local failures = {
		{ category = "Correctness", code = "PayloadMismatch", occurrences = faultSnapshot.mismatch, discriminator = { mismatchReason = mismatch.reason }, firstOccurrence = { repetitionIndex = 1, participant = { role = "Recipient", index = 1 }, mismatch = mismatch } },
		{ category = "Correctness", code = "OutOfOrderDelivery", occurrences = faultSnapshot.outOfOrder },
		{ category = "Correctness", code = "UnexpectedDelivery", occurrences = faultSnapshot.unexpected },
		{ category = "Correctness", code = "DuplicateDelivery", occurrences = faultSnapshot.duplicate },
		{ category = "Correctness", code = "MissingDelivery", occurrences = faultSnapshot.missing },
	}
	return makeDraft(caseValue, repositoryAdapter(), failures, counts, conformingClockProof(), measurements), faultSnapshot, mismatch
end

local function notStartedCounts(caseValue, workload)
	return plannedCounts(caseValue, workload, {
		finality = "NotStarted",
		submitted = 0,
		received = 0,
		correct = 0,
		missing = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
	})
end

local function setupFailedDraft()
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	caseValue.startedRepetitions = 0
	caseValue.completedRepetitions = 0
	local failures = requiredMeasurementFailures(caseValue)
	table.insert(failures, { category = "Lifecycle", code = "SetupFailure", occurrences = 1 })
	return makeDraft(
		caseValue,
		repositoryAdapter(),
		failures,
		notStartedCounts(caseValue, workload),
		conformingClockProof(),
		unavailableMeasurements(caseValue, workload, "CaseNotCompleted")
	)
end

local function unsupportedDraft(capability, required, configure)
	local workloadId = if capability == "BroadcastMode" then "state-broadcast-s2c" else "state-steady-c2s"
	local caseValue, workload = completeWorkloadCase(workloadId, 1)
	caseValue.startedRepetitions = 0
	caseValue.completedRepetitions = 0
	local adapter = repositoryAdapter()
	configure(adapter)
	return makeDraft(
		caseValue,
		adapter,
		{
			{
				category = "Capability",
				code = "UnsupportedCapability",
				occurrences = 1,
				discriminator = { capability = capability, required = required },
			},
		},
		notStartedCounts(caseValue, workload),
		conformingClockProof(),
		unavailableMeasurements(caseValue, workload, "CaseUnsupported")
	)
end

local function preStartErrorDraft(stage)
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	caseValue.startedRepetitions = 0
	caseValue.completedRepetitions = 0
	return makeDraft(
		caseValue,
		repositoryAdapter(),
		{
			{
				category = "Harness",
				code = "InternalError",
				occurrences = 1,
				discriminator = { stage = stage or "Preflight" },
			},
		},
		notStartedCounts(caseValue, workload),
		conformingClockProof(),
		unavailableMeasurements(caseValue, workload, "CaseNotCompleted")
	)
end

local function completedUntrustedErrorDraft()
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	local counts = plannedCounts(caseValue, workload)
	return makeDraft(
		caseValue,
		repositoryAdapter(),
		{ { category = "Harness", code = "ClockProofFailure", occurrences = 1 } },
		counts,
		conformingClockProof(false),
		unavailableMeasurements(caseValue, workload, "ResultUntrusted")
	)
end

local function completedInvalidWithFailures(extraFailures, configure)
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	local counts = plannedCounts(caseValue, workload)
	local conformance = conformingClockProof()
	if configure ~= nil then
		configure(caseValue, workload, counts, conformance)
	end
	local failures = requiredMeasurementFailures(caseValue)
	for _, failure in extraFailures do
		table.insert(failures, failure)
	end
	return makeDraft(
		caseValue,
		repositoryAdapter(),
		failures,
		counts,
		conformance,
		unavailableMeasurements(caseValue, workload, if caseValue.completedRepetitions == caseValue.scheduledRepetitions then "CaptureFailed" else "CaseNotCompleted")
	)
end

local function countRawValues(result)
	local count = 0
	for _, measurement in result.measurements do
		if measurement.rawSamples ~= nil then
			for _, group in measurement.rawSamples do
				count += #group.values
			end
		end
	end
	return count
end

local function findResultMeasurement(result, measurementId)
	for _, measurement in result.measurements do
		if measurement.metadata.id == measurementId then
			return measurement
		end
	end
	error(`missing result measurement {measurementId}`, 0)
end

local function flattenedSampleCount(measurement)
	local count = 0
	for _, group in measurement.rawSamples do
		count += #group.values
	end
	return count
end

assertExactKeys(
	ResultV1,
	{ "ID", "VERSION", "BENCHMARK_ID", "BENCHMARK_VERSION", "MAX_JSON_BYTES", "finalize", "validate" },
	"ResultV1"
)
assert(table.isfrozen(ResultV1), "ResultV1 module must be frozen")
assert(ResultV1.ID == "result-v1" and ResultV1.VERSION == 1, "result identity drifted")
assert(ResultV1.BENCHMARK_ID == "relay-event" and ResultV1.BENCHMARK_VERSION == 1, "benchmark identity drifted")
assert(ResultV1.MAX_JSON_BYTES == 8_388_608, "JSON body limit drifted")
assert(type(ResultV1.finalize) == "function" and type(ResultV1.validate) == "function", "result operations missing")

assertExactKeys(Identity, { "check", "resolveSelection", "missingRequirements" }, "AdapterIdentity")
assert(table.isfrozen(Identity), "AdapterIdentity module must be frozen")
assert(type(Identity.check) == "function", "shared identity check missing")
assert(type(Identity.resolveSelection) == "function", "shared selection resolver missing")
assert(type(Identity.missingRequirements) == "function", "shared requirement matcher missing")

do
	local candidate = repositoryAdapter()
	candidate.displayName = "  Repository   Adapter  "
	candidate.library.displayName = " Repository   Library "
	candidate.capabilities.directions = { "ServerToClient", "ClientToServer" }
	candidate.capabilities.payloadIds = { "tiny", "state" }
	local before = deepClone(candidate)
	local checked = Identity.check(candidate, "Normalize", "0.650.0.6500000", "$.adapter")
	assert(checked.kind == "Valid", "shared identity normalization rejected a valid identity")
	assertDeepEqual(candidate, before, "shared identity input")
	assertDetached(candidate, checked, "shared normalized identity")
	assertDeepFrozen(checked)
	assert(checked.value.displayName == "Repository Adapter", "shared adapter label normalization differs")
	assert(checked.value.library.displayName == "Repository Library", "shared library label normalization differs")
	assertDeepEqual(checked.value.capabilities.directions, { "ClientToServer", "ServerToClient" }, "shared normalized directions")
	assertDeepEqual(checked.value.capabilities.payloadIds, { "state", "tiny" }, "shared normalized payload IDs")

	local canonical = Identity.check(repositoryAdapter(), "Canonical", "0.650.0.6500000", "$.adapter")
	assert(canonical.kind == "Valid", "shared canonical identity rejected a valid identity")
	assertDeepFrozen(canonical)
	assertDetached(candidate, canonical, "shared canonical identity")
end

do
	local function parity(label, expectedCode, expectedPath, mutate)
		local adapter = repositoryAdapter()
		mutate(adapter)
		assertIdentityIssue(adapter, "Normalize", "0.650.0.6500000", expectedCode, expectedPath, label)
		local draft = canonicalProbeDraft({ adapter = adapter })
		assertRejected(function()
			ResultV1.finalize(draft)
		end, "RESULT_E_" .. expectedCode, `Result V1 parity: {label}`)
	end

	parity("unknown acquisition field", "KEYSET", "$.adapter", function(adapter)
		adapter.modulePath = "TOP-SECRET-MODULE-PATH"
	end)
	parity("invalid adapter ID", "RANGE", "$.adapter.id", function(adapter)
		adapter.id = "Invalid Adapter ID"
	end)
	parity("unknown lane", "ENUM", "$.adapter.lane", function(adapter)
		adapter.lane = "Experimental"
	end)
	parity("unsupported broadcast with an added frame", "RELATION", "$.adapter.semantics", function(adapter)
		adapter.semantics.broadcastMode = "Unsupported"
		adapter.semantics.intentionalAddedDeliveryFrames = 1
	end)
	parity("identity metatable", "METATABLE", "$.adapter", function(adapter)
		setmetatable(adapter.library, {})
	end)
	parity("identity cycle", "CYCLE", "$.adapter", function(adapter)
		adapter.loop = adapter
	end)
	parity("identity alias", "ALIAS", "$.adapter", function(adapter)
		adapter.shared = adapter.library
	end)
end

local workloadDraft, cleanBurstSnapshot = canonicalWorkloadDraft()
local workloadBefore = deepClone(workloadDraft)
local workloadResult = ResultV1.finalize(workloadDraft)
assertDeepEqual(workloadDraft, workloadBefore, "workload draft")
workloadDraft.benchmarkSource.dirty = false
assert(workloadResult.benchmark.source.dirty, "result must detach benchmark source")
workloadDraft.benchmarkSource.dirty = true
assert(workloadResult.status == "Valid", "clean workload must derive Valid")
assert(workloadResult.schema.id == "result-v1" and workloadResult.schema.version == 1, "schema identity differs")
assert(workloadResult.benchmark.id == "relay-event" and workloadResult.benchmark.version == 1, "benchmark identity differs")
assert(workloadResult.contract.id == "event-v1" and workloadResult.contract.version == Contract.version, "contract identity differs")
assert(workloadResult.counts.received == cleanBurstSnapshot.received * workloadResult.case.scheduledRepetitions, "ledger receipt aggregation differs")
assert(countRawValues(workloadResult) == 60_870, "largest workload must retain exactly 60,870 values")

local contractWorkloadMeasurements = measurementDefinitions(workloadResult.case)
assert(#workloadResult.measurements == #contractWorkloadMeasurements, "workload measurement count differs")
for index, resultMeasurement in workloadResult.measurements do
	local contractMeasurement = contractWorkloadMeasurements[index]
	assertDeepEqual(resultMeasurement.metadata, contractMeasurement, `metadata[{index}]`)
	assert(resultMeasurement.state == "Available", `{contractMeasurement.id} must be Available`)
	local sampleCount = flattenedSampleCount(resultMeasurement)
	assert(resultMeasurement.summary.sampleCount == sampleCount, `{contractMeasurement.id} sampleCount differs`)
	if contractMeasurement.summary == "Exact" then
		assert(resultMeasurement.summary.kind == "Exact", `{contractMeasurement.id} exact summary kind differs`)
		if contractMeasurement.id == "submitted" or contractMeasurement.id == "received" or contractMeasurement.id == "correct" then
			assert(resultMeasurement.summary.total == workloadResult.counts[contractMeasurement.id], `{contractMeasurement.id} total differs from counts`)
		else
			assert(resultMeasurement.summary.total == sampleCount * (sampleCount + 1) / 2, `{contractMeasurement.id} exact total differs`)
		end
	else
		assert(resultMeasurement.summary.kind == "MedianAndP95", `{contractMeasurement.id} percentile summary kind differs`)
		assert(resultMeasurement.summary.median == sampleCount / 2 + 0.5, `{contractMeasurement.id} even median differs`)
		assert(resultMeasurement.summary.p95 == math.floor((95 * sampleCount + 99) / 100), `{contractMeasurement.id} p95 differs`)
	end
end

assert(findResultMeasurement(workloadResult, "submissionDuration").summary.sampleCount == 30, "30-value summary missing")
assert(findResultMeasurement(workloadResult, "frameTime").summary.sampleCount == 300, "300-value summary missing")
assert(findResultMeasurement(workloadResult, "submitCallDuration").summary.sampleCount == 30_000, "30,000-value summary missing")
assertDeepFrozen(workloadResult)
assertDetached(workloadDraft, workloadResult, "finalized workload")

local validatedWorkload = ResultV1.validate(workloadResult)
assert(validatedWorkload ~= workloadResult, "validate must return a detached root")
assertDetached(workloadResult, validatedWorkload, "validated workload")
assertDeepFrozen(validatedWorkload)
assertDeepEqual(validatedWorkload, workloadResult, "validated workload")

local encodedWorkload = serde.encode("json", workloadResult)
assert(#encodedWorkload < ResultV1.MAX_JSON_BYTES, "largest workload JSON exceeds Result V1 body limit")
local decodedWorkload = serde.decode("json", encodedWorkload)
local roundTrippedWorkload = ResultV1.validate(decodedWorkload)
assertDeepEqual(roundTrippedWorkload, workloadResult, "JSON round trip")
local decodedNull = serde.decode("json", [[{"optional":null}]])
assert(rawget(decodedNull, "optional") == nil, "pinned Lune object-null behavior changed")

-- A nonnegative IEEE-754 double needs at most 23 bytes in shortest round-trip
-- scientific JSON notation: 17 significant digits plus `.e-308` punctuation.
local MAXIMUM_WIDTH_FINITE_SAMPLE = 2.2250738585072014e-308
local encodedMaximumWidthSample = serde.encode("json", MAXIMUM_WIDTH_FINITE_SAMPLE)
assert(encodedMaximumWidthSample == "2.2250738585072014e-308", "pinned finite-number JSON width changed")
assert(#encodedMaximumWidthSample == 23, "maximum-width finite sample proof drifted")

local maximumEnvelopeDraft = deepClone(workloadDraft)
maximumEnvelopeDraft.benchmarkSource.revision = string.rep("f", 64)
maximumEnvelopeDraft.adapter.id = string.rep("a", 64)
maximumEnvelopeDraft.adapter.displayName = string.rep("A", 128)
maximumEnvelopeDraft.adapter.library.id = string.rep("l", 64)
maximumEnvelopeDraft.adapter.library.displayName = string.rep("L", 128)
maximumEnvelopeDraft.adapter.library.version = string.rep("V", 64)
maximumEnvelopeDraft.adapter.library.provenance.sourceRepository = "https://example.com/"
	.. string.rep("a", 2_048 - #"https://example.com/")
maximumEnvelopeDraft.adapter.library.provenance.revision = string.rep("e", 64)
maximumEnvelopeDraft.adapter.library.provenance.checksum = "sha256:" .. string.rep("f", 64)
maximumEnvelopeDraft.adapter.library.provenance.license = string.rep("M", 64)
maximumEnvelopeDraft.adapter.semantics.intentionalAddedDeliveryFrames = Contract.maximumAddedDeliveryFrames
maximumEnvelopeDraft.environment.studio.version = string.rep("1", 64)
maximumEnvelopeDraft.environment.studio.channel = string.rep("c", 32)
maximumEnvelopeDraft.environment.host.osVersion = string.rep("2", 64)
maximumEnvelopeDraft.environment.host.cpuModel = string.rep("C", 128)
maximumEnvelopeDraft.environment.host.logicalProcessorCount = 1_024
maximumEnvelopeDraft.environment.host.memoryMiB = 16_777_216
maximumEnvelopeDraft.environment.host.gpuModel = string.rep("G", 128)

local maximumExactPerRepetition = math.floor(MAX_SAFE_INTEGER / maximumEnvelopeDraft.case.scheduledRepetitions)
local maximumExactRemainder = MAX_SAFE_INTEGER
	- maximumExactPerRepetition * maximumEnvelopeDraft.case.scheduledRepetitions
local contractSummaryById = {}
for _, measurement in Contract.measurements do
	contractSummaryById[measurement.id] = measurement.summary
end
for _, measurement in maximumEnvelopeDraft.measurements do
	if contractSummaryById[measurement.id] == "MedianAndP95" then
		for _, group in measurement.rawSamples do
			for index = 1, #group.values do
				group.values[index] = MAXIMUM_WIDTH_FINITE_SAMPLE
			end
		end
	elseif measurement.id == "remoteCalls" then
		for _, group in measurement.rawSamples do
			group.values[1] = maximumExactPerRepetition
		end
		measurement.rawSamples[1].values[1] += maximumExactRemainder
	end
end

local maximumEnvelopeResult = ResultV1.finalize(maximumEnvelopeDraft)
assert(countRawValues(maximumEnvelopeResult) == 60_870, "maximum-width envelope lost raw values")
assert(#maximumEnvelopeResult.benchmark.source.revision == 64, "maximum revision width lost")
assert(#maximumEnvelopeResult.adapter.id == 64, "maximum adapter ID width lost")
assert(#maximumEnvelopeResult.adapter.displayName == 128, "maximum adapter label width lost")
assert(#maximumEnvelopeResult.adapter.library.id == 64, "maximum library ID width lost")
assert(#maximumEnvelopeResult.adapter.library.displayName == 128, "maximum library label width lost")
assert(#maximumEnvelopeResult.adapter.library.version == 64, "maximum library version width lost")
assert(#maximumEnvelopeResult.adapter.library.provenance.sourceRepository == 2_048, "maximum repository URL width lost")
assert(#maximumEnvelopeResult.adapter.library.provenance.license == 64, "maximum license width lost")
assert(#maximumEnvelopeResult.environment.studio.version == 64, "maximum Studio version width lost")
assert(#maximumEnvelopeResult.environment.studio.channel == 32, "maximum Studio channel width lost")
assert(#maximumEnvelopeResult.environment.host.osVersion == 64, "maximum OS version width lost")
assert(#maximumEnvelopeResult.environment.host.cpuModel == 128, "maximum CPU label width lost")
assert(#maximumEnvelopeResult.environment.host.gpuModel == 128, "maximum GPU label width lost")
assert(maximumEnvelopeResult.environment.host.logicalProcessorCount == 1_024, "maximum processor count lost")
assert(maximumEnvelopeResult.environment.host.memoryMiB == 16_777_216, "maximum memory value lost")
assert(findResultMeasurement(maximumEnvelopeResult, "remoteCalls").summary.total == MAX_SAFE_INTEGER, "maximum legal Exact total lost")
assert(findResultMeasurement(maximumEnvelopeResult, "frameTime").summary.median == MAXIMUM_WIDTH_FINITE_SAMPLE, "maximum-width finite samples lost")

local encodedMaximumEnvelope = serde.encode("json", maximumEnvelopeResult)
assert(#encodedMaximumEnvelope > #encodedWorkload, "maximum-width envelope proof did not widen encoded output")
assert(#encodedMaximumEnvelope < ResultV1.MAX_JSON_BYTES, "maximum-width valid envelope exceeds Result V1 body limit")
local decodedMaximumEnvelope = serde.decode("json", encodedMaximumEnvelope)
local roundTrippedMaximumEnvelope = ResultV1.validate(decodedMaximumEnvelope)
assertDeepEqual(roundTrippedMaximumEnvelope, maximumEnvelopeResult, "maximum-width JSON round trip")

local probeDraft = canonicalProbeDraft({ descending = true, reverseGroups = true })
local probeResult = ResultV1.finalize(probeDraft)
assert(probeResult.status == "Valid", "clean probe must derive Valid")
assert(probeResult.counts == nil, "probe must not expose workload counts")
assert(probeResult.adapter.integrationKind == "EngineBuiltIn", "engine provenance arm missing")
local latency = findResultMeasurement(probeResult, "roundTripLatency")
assert(latency.summary.sampleCount == 3_600, "probe summary must contain 3,600 samples")
assert(latency.summary.median == 1_800.5 and latency.summary.p95 == 3_420, "probe median/p95 differs")
assert(latency.rawSamples[1].repetitionIndex == 1 and latency.rawSamples[1].participantIndex == 1, "probe groups not canonicalized")
assert(latency.rawSamples[1].values[1] == 3_600 and latency.rawSamples[1].values[120] == 3_481, "raw acquisition order changed")

local invalidDraft, faultSnapshot, retainedMismatch = completedInvalidDraft()
local invalidResult = ResultV1.finalize(invalidDraft)
assert(invalidResult.status == "Invalid", "fault ledger must derive Invalid")
assert(invalidResult.counts.missing == faultSnapshot.missing, "missing count lost")
assert(invalidResult.counts.duplicate == faultSnapshot.duplicate, "duplicate count lost")
assert(invalidResult.counts.unexpected == faultSnapshot.unexpected, "unexpected count lost")
assert(invalidResult.counts.outOfOrder == faultSnapshot.outOfOrder, "out-of-order count lost")
assert(invalidResult.counts.mismatch == faultSnapshot.mismatch, "mismatch count lost")
assert(invalidResult.counts.received == invalidResult.counts.correct + invalidResult.counts.mismatch + invalidResult.counts.duplicate + invalidResult.counts.unexpected, "receipt partition differs")
assert(invalidResult.counts.expectedDeliveries == invalidResult.counts.correct + invalidResult.counts.mismatch + invalidResult.counts.missing, "final delivery balance differs")
local payloadFailure = invalidResult.failures[#invalidResult.failures]
assert(payloadFailure.code == "PayloadMismatch", "failures were not sorted by code")
assertDeepEqual(payloadFailure.firstOccurrence.mismatch, retainedMismatch, "retained mismatch")
assert(payloadFailure.firstOccurrence.mismatch.path == "health", "comparator path was transformed")
for _, measurement in invalidResult.measurements do
	if measurement.metadata.summary == "MedianAndP95" then
		assert(measurement.state == "Diagnostic" and measurement.summary == nil, `{measurement.metadata.id} invalid timing state differs`)
	else
		assert(measurement.state == "Available" and measurement.summary.kind == "Exact", `{measurement.metadata.id} invalid exact state differs`)
	end
end

assert(ResultV1.finalize(setupFailedDraft()).status == "Invalid", "setup failure must derive Invalid")
assert(ResultV1.finalize(preStartErrorDraft()).status == "Error", "pre-start harness fault must derive Error")
assert(ResultV1.finalize(completedUntrustedErrorDraft()).status == "Error", "completed untrusted result must derive Error")

local function expectedWorkloadRequirements(workload)
	local requirements = {
		{ capability = "Direction", required = workload.direction },
		{ capability = "DeliverySemantics", required = "ReliableOrdered" },
		{ capability = "Payload", required = workload.payloadId },
	}
	if workload.audience == "Broadcast" then
		table.insert(requirements, { capability = "BroadcastMode", required = "Broadcast" })
	end
	return requirements
end

for _, workload in Contract.workloads do
	for _, recipientCount in workload.recipientCounts do
		local selection = {
			kind = "Workload",
			workloadId = workload.id,
			recipientCount = recipientCount,
		}
		local resolved = Identity.resolveSelection(selection)
		assert(resolved.kind == "Valid", `{workload.id}/{recipientCount} selection must resolve`)
		assertExactKeys(
			resolved.value,
			{ "kind", "workloadId", "recipientCount", "payloadId", "direction", "audience", "requirements" },
			`{workload.id}/{recipientCount} resolved selection`
		)
		assertDeepEqual(
			resolved.value.requirements,
			expectedWorkloadRequirements(workload),
			`{workload.id}/{recipientCount} requirements`
		)
		assertDeepFrozen(resolved)
		assertDetached(selection, resolved, `{workload.id}/{recipientCount} resolved selection`)
		local capable = Identity.check(repositoryAdapter(), "Canonical", "0.650.0.6500000", "$.adapter")
		assert(capable.kind == "Valid", "capability fixture identity must validate")
		local missing = Identity.missingRequirements(capable.value, resolved.value.requirements)
		assert(#missing == 0, `{workload.id}/{recipientCount} must be supported by the full identity`)
		assertDeepFrozen(missing)
	end
end

do
	local selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" }
	local resolved = Identity.resolveSelection(selection)
	assert(resolved.kind == "Valid", "tiny-round-trip selection must resolve")
	assertExactKeys(
		resolved.value,
		{
			"kind",
			"probeId",
			"clientCount",
			"payloadId",
			"requestDirection",
			"responseDirection",
			"responseAudience",
			"requirements",
		},
		"tiny-round-trip resolved selection"
	)
	local expected = {
		{ capability = "Direction", required = "ClientToServer" },
		{ capability = "Direction", required = "ServerToClient" },
		{ capability = "DeliverySemantics", required = "ReliableOrdered" },
		{ capability = "Payload", required = "tiny" },
		{ capability = "BroadcastMode", required = "Broadcast" },
	}
	assertDeepEqual(resolved.value.requirements, expected, "tiny-round-trip requirements")
	assertDeepFrozen(resolved)
	assertDetached(selection, resolved, "tiny-round-trip resolved selection")

	local unsupported = repositoryAdapter()
	unsupported.semantics.broadcastMode = "Unsupported"
	unsupported.capabilities.directions = {}
	unsupported.capabilities.deliverySemantics = {}
	unsupported.capabilities.payloadIds = {}
	local checked = Identity.check(unsupported, "Canonical", "0.650.0.6500000", "$.adapter")
	assert(checked.kind == "Valid", "empty capability sets must remain a valid identity")
	local missing = Identity.missingRequirements(checked.value, resolved.value.requirements)
	assertDeepEqual(missing, expected, "tiny-round-trip missing requirement order")
	assertDeepFrozen(missing)
	assertDetached(resolved.value.requirements, missing, "tiny-round-trip missing requirements")
end

for _, invalidSelection in {
	{ value = { kind = "Workload", workloadId = "unknown", recipientCount = 1 }, path = "$.selection.workloadId" },
	{ value = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 2 }, path = "$.selection.recipientCount" },
	{ value = { kind = "SeparateProbe", probeId = "unknown" }, path = "$.selection.probeId" },
	{ value = { kind = "Workload", workloadId = "state-steady-c2s", recipientCount = 1, extra = true }, path = "$.selection" },
} do
	local resolved = Identity.resolveSelection(invalidSelection.value :: any)
	assert(resolved.kind == "Invalid" and resolved.path == invalidSelection.path, "invalid selection path differs")
	assertDeepFrozen(resolved)
end

do
	local hostile = { kind = "SeparateProbe", probeId = "tiny-round-trip" }
	setmetatable(hostile, {})
	local resolved = Identity.resolveSelection(hostile :: any)
	assert(resolved.kind == "Invalid" and resolved.path == "$.selection", "selection metatable must reject at the selection root")
	assertDeepFrozen(resolved)
end

local capabilityCases = {
	{
		capability = "Direction",
		required = "ClientToServer",
		configure = function(adapter)
			adapter.capabilities.directions = { "ServerToClient" }
		end,
	},
	{
		capability = "DeliverySemantics",
		required = "ReliableOrdered",
		configure = function(adapter)
			adapter.capabilities.deliverySemantics = {}
		end,
	},
	{
		capability = "Payload",
		required = "state",
		configure = function(adapter)
			adapter.capabilities.payloadIds = { "tiny" }
		end,
	},
	{
		capability = "BroadcastMode",
		required = "Broadcast",
		configure = function(adapter)
			adapter.semantics.broadcastMode = "Unsupported"
		end,
	},
}
for _, capabilityCase in capabilityCases do
	local draft = unsupportedDraft(capabilityCase.capability, capabilityCase.required, capabilityCase.configure)
	local result = ResultV1.finalize(draft)
	assert(result.status == "Unsupported", `{capabilityCase.capability} deficiency must derive Unsupported`)
	assert(#result.failures == 1 and result.failures[1].code == "UnsupportedCapability", "unsupported result must contain only capability evidence")
	local resolved = Identity.resolveSelection({
		kind = "Workload",
		workloadId = draft.case.workloadId,
		recipientCount = draft.case.recipientCount,
	})
	assert(resolved.kind == "Valid", "unsupported Result V1 workload selection must resolve")
	local checked = Identity.check(draft.adapter, "Canonical", draft.environment.studio.version, "$.adapter")
	assert(checked.kind == "Valid", "unsupported Result V1 identity must remain schema-valid")
	local missing = Identity.missingRequirements(checked.value, resolved.value.requirements)
	assert(#missing == #result.failures, "Result V1 unsupported group count differs from the shared owner")
	assert(missing[1].capability == result.failures[1].discriminator.capability, "Result V1 unsupported capability differs from the shared owner")
	assert(missing[1].required == result.failures[1].discriminator.required, "Result V1 unsupported requirement differs from the shared owner")
	for _, measurement in result.measurements do
		assert(measurement.state == "Unavailable" and measurement.unavailableReason.code == "CaseUnsupported", "unsupported measurement state differs")
	end
end

do
	local draft = unsupportedDraft("Payload", "state", function(adapter)
		adapter.capabilities.payloadIds = { "tiny" }
	end)
	draft.adapter.capabilities.payloadIds = { "state", "tiny" }
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "fully capable Unsupported")
end

do
	local draft = unsupportedDraft("Payload", "state", function(adapter)
		adapter.capabilities.payloadIds = { "tiny" }
	end)
	table.insert(draft.failures, { category = "Lifecycle", code = "SetupFailure", occurrences = 1 })
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "Capability category mixing")
end

do
	local draft = canonicalProbeDraft()
	draft.status = "Valid"
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_KEYSET", "caller-supplied status")
end

do
	local draft = canonicalProbeDraft({ adapter = repositoryAdapter() })
	draft.adapter.integrationKind = "Generated"
	local result = ResultV1.finalize(draft)
	assert(result.adapter.integrationKind == "Generated" and result.adapter.library.provenance.kind == "Repository", "Generated repository arm rejected")
end

do
	local draft = canonicalProbeDraft({ adapter = repositoryAdapter() })
	draft.adapter.displayName = "  Repository   Adapter  "
	draft.adapter.library.displayName = " Repository   Library "
	draft.adapter.capabilities.directions = { "ServerToClient", "ClientToServer" }
	draft.adapter.capabilities.payloadIds = { "tiny", "state" }
	local normalized = ResultV1.finalize(draft)
	assert(normalized.adapter.displayName == "Repository Adapter", "adapter label not normalized")
	assert(normalized.adapter.library.displayName == "Repository Library", "library label not normalized")
	assertDeepEqual(normalized.adapter.capabilities.directions, { "ClientToServer", "ServerToClient" }, "normalized directions")
	assertDeepEqual(normalized.adapter.capabilities.payloadIds, { "state", "tiny" }, "normalized payload IDs")

	local noncanonical = deepClone(normalized)
	noncanonical.adapter.displayName = " Repository Adapter"
	assertIdentityIssue(
		noncanonical.adapter,
		"Canonical",
		noncanonical.environment.studio.version,
		"NONCANONICAL",
		"$.adapter.displayName",
		"noncanonical serialized label parity"
	)
	assertRejected(function()
		ResultV1.validate(noncanonical)
	end, "RESULT_E_NONCANONICAL", "noncanonical serialized label")
	noncanonical = deepClone(normalized)
	noncanonical.adapter.capabilities.directions = { "ServerToClient", "ClientToServer" }
	assertIdentityIssue(
		noncanonical.adapter,
		"Canonical",
		noncanonical.environment.studio.version,
		"ORDER",
		"$.adapter.capabilities.directions",
		"noncanonical serialized capability order parity"
	)
	assertRejected(function()
		ResultV1.validate(noncanonical)
	end, "RESULT_E_ORDER", "noncanonical serialized capability order")
end

do
	local draft = canonicalProbeDraft({ adapter = repositoryAdapter() })
	draft.adapter.library.provenance.revision = string.rep("f", 40)
	draft.adapter.library.provenance.checksum = "sha256:" .. string.rep("0", 64)
	local structurallyValid = ResultV1.finalize(draft)
	assert(structurallyValid.adapter.library.provenance.revision == string.rep("f", 40), "schema must not perform host manifest equality")
end

local function rejectProvenanceMutation(label, expectedCode, mutate)
	local draft = canonicalProbeDraft({ adapter = repositoryAdapter() })
	mutate(draft.adapter, draft.environment)
	assertRejected(function()
		ResultV1.finalize(draft)
	end, expectedCode, label)
end

rejectProvenanceMutation("missing repository field", "RESULT_E_KEYSET", function(adapter)
	adapter.library.provenance.revision = nil
end)
rejectProvenanceMutation("extra repository field", "RESULT_E_KEYSET", function(adapter)
	adapter.library.provenance.package = "hidden"
end)
rejectProvenanceMutation("uppercase revision", "RESULT_E_RANGE", function(adapter)
	adapter.library.provenance.revision = string.rep("A", 40)
end)
rejectProvenanceMutation("malformed checksum", "RESULT_E_RANGE", function(adapter)
	adapter.library.provenance.checksum = string.rep("e", 64)
end)
rejectProvenanceMutation("repository query", "RESULT_E_RANGE", function(adapter)
	adapter.library.provenance.sourceRepository = "https://example.com/relay?token=x"
end)
rejectProvenanceMutation("compound license", "RESULT_E_RANGE", function(adapter)
	adapter.library.provenance.license = "MIT OR Apache-2.0"
end)
rejectProvenanceMutation("PackageArtifact deferred", "RESULT_E_ENUM", function(adapter)
	adapter.library.provenance = { kind = "PackageArtifact" }
end)
rejectProvenanceMutation("runtime engine provenance", "RESULT_E_RELATION", function(adapter)
	adapter.library.provenance = { kind = "EngineBuiltIn", studioVersion = "0.650.0.6500000" }
end)

do
	local draft = canonicalProbeDraft()
	draft.adapter.library.version = "0.651.0.6510000"
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "engine Studio version mismatch")
end

local genericFailureCodes = {
	{ category = "Contract", code = "AddedDeliveryFrameLimitExceeded" },
	{ category = "Contract", code = "ControlTrafficDuringMeasuredFrames" },
	{ category = "Contract", code = "IsolationFailure" },
	{ category = "Contract", code = "StaleCallback" },
	{ category = "Lifecycle", code = "SubmitFailure" },
	{ category = "Lifecycle", code = "Timeout" },
	{ category = "Lifecycle", code = "Disconnect" },
	{ category = "Lifecycle", code = "TeardownFailure" },
}
for _, definition in genericFailureCodes do
	local result = ResultV1.finalize(completedInvalidWithFailures({
		{ category = definition.category, code = definition.code, occurrences = 1 },
	}))
	assert(result.status == "Invalid", `{definition.code} must derive Invalid`)
end

for _, exclusion in { "setup", "warmup", "quiescence", "resultExtraction" } do
	local result = ResultV1.finalize(completedInvalidWithFailures({
		{
			category = "Contract",
			code = "TimingExclusionViolation",
			occurrences = 1,
			discriminator = { exclusion = exclusion },
		},
	}, function(_, _, _, conformance)
		conformance.timingExclusionsConfirmed[exclusion] = false
	end))
	assert(result.status == "Invalid", `{exclusion} exclusion failure must derive Invalid`)
end

do
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	caseValue.startedRepetitions = 1
	caseValue.completedRepetitions = 0
	local expectedDeliveries = caseValue.scheduledRepetitions
		* caseValue.senderCount
		* workload.measuredFrames
		* workload.messagesPerFrame
		* caseValue.recipientCount
	local observationLimit = 4 * expectedDeliveries
	local counts = plannedCounts(caseValue, workload, {
		finality = "Partial",
		submitted = workload.measuredFrames,
		received = observationLimit,
		correct = workload.measuredFrames,
		missing = 0,
		unexpected = observationLimit - workload.measuredFrames,
	})
	local failures = requiredMeasurementFailures(caseValue)
	table.insert(failures, {
		category = "Correctness",
		code = "UnexpectedDelivery",
		occurrences = observationLimit - workload.measuredFrames,
	})
	table.insert(failures, {
		category = "Contract",
		code = "DeliveryObservationLimitExceeded",
		occurrences = 1,
		firstOccurrence = { repetitionIndex = 1, participant = { role = "Coordinator" } },
	})
	local partial = makeDraft(
		caseValue,
		repositoryAdapter(),
		failures,
		counts,
		conformingClockProof(),
		unavailableMeasurements(caseValue, workload, "CaseNotCompleted")
	)
	local result = ResultV1.finalize(partial)
	assert(result.status == "Invalid" and result.counts.finality == "Partial", "observation-limit Partial result differs")
	assert(result.counts.received == observationLimit, "observation-limit saturation total differs")
	assert(result.counts.correct == workload.measuredFrames, "observation-limit expected receipt evidence differs")
	assert(result.counts.unexpected == observationLimit - workload.measuredFrames, "observation-limit unexpected evidence differs")
end

do
	local completed = completedInvalidWithFailures({
		{
			category = "Contract",
			code = "DeliveryObservationLimitExceeded",
			occurrences = 1,
			firstOccurrence = { repetitionIndex = 1, participant = { role = "Coordinator" } },
		},
	})
	assert(completed.case.completedRepetitions == completed.case.scheduledRepetitions, "observation-limit regression must exercise completed progress")
	assert(completed.counts.finality == "Final", "observation-limit regression must exercise Final counts")
	assertRejected(function()
		ResultV1.finalize(completed)
	end, "RESULT_E_RELATION", "completed Final delivery observation overflow")
end

do
	local oversized = completedInvalidWithFailures({
		{ category = "Correctness", code = "OutOfOrderDelivery", occurrences = 3_601 },
	}, function(_, _, counts)
		counts.outOfOrder = counts.expectedDeliveries + 1
	end)
	assert(oversized.counts.expectedDeliveries == 3_600, "out-of-order regression workload cardinality drifted")
	assertRejected(function()
		ResultV1.finalize(oversized)
	end, "RESULT_E_RELATION", "out-of-order count exceeds expected deliveries")
end

local correctnessCountCases = {
	{
		code = "SubmissionShortfall",
		configure = function(counts)
			counts.submitted -= 1
			counts.received -= 1
			counts.correct -= 1
			counts.missing = 1
		end,
		additionalFailures = {
			{ category = "Correctness", code = "MissingDelivery", occurrences = 1 },
		},
	},
	{
		code = "MissingDelivery",
		configure = function(counts)
			counts.received -= 1
			counts.correct -= 1
			counts.missing = 1
		end,
	},
	{
		code = "DuplicateDelivery",
		configure = function(counts)
			counts.received += 1
			counts.duplicate = 1
		end,
	},
	{
		code = "UnexpectedDelivery",
		configure = function(counts)
			counts.received += 1
			counts.unexpected = 1
		end,
	},
	{
		code = "OutOfOrderDelivery",
		configure = function(counts)
			counts.outOfOrder = 1
		end,
	},
}
for _, correctnessCase in correctnessCountCases do
	local failures = {
		{ category = "Correctness", code = correctnessCase.code, occurrences = 1 },
	}
	for _, failure in correctnessCase.additionalFailures or {} do
		table.insert(failures, failure)
	end
	local draft = completedInvalidWithFailures(failures, function(_, _, counts)
		correctnessCase.configure(counts)
	end)
	local result = ResultV1.finalize(draft)
	assert(result.status == "Invalid", `{correctnessCase.code} must derive Invalid`)
end

do
	local result = ResultV1.finalize(completedInvalidWithFailures({}))
	assert(result.status == "Invalid", "required measurement failures must derive Invalid")
	for _, measurement in result.measurements do
		assert(measurement.state == "Unavailable" and measurement.unavailableReason.code == "CaptureFailed", "completed invalid unavailable state differs")
	end
end

for _, stage in { "Preflight", "Setup", "Execution", "Finalize" } do
	local result = ResultV1.finalize(preStartErrorDraft(stage))
	assert(result.status == "Error", `{stage} InternalError must derive Error`)
end

do
	local duplicate = completedInvalidWithFailures({
		{ category = "Contract", code = "IsolationFailure", occurrences = 1 },
		{ category = "Contract", code = "IsolationFailure", occurrences = 1 },
	})
	assertRejected(function()
		ResultV1.finalize(duplicate)
	end, "RESULT_E_RELATION", "duplicate failure grouping key")
end

do
	local tooMany = preStartErrorDraft()
	tooMany.failures = {}
	for index = 1, 39 do
		tooMany.failures[index] = {
			category = "Harness",
			code = "InternalError",
			occurrences = 1,
			discriminator = { stage = "Preflight" },
		}
	end
	assertRejected(function()
		ResultV1.finalize(tooMany)
	end, "RESULT_E_LIMIT", "39 grouped failures preflight")
end

do
	local wrongCategory = completedInvalidWithFailures({
		{ category = "Lifecycle", code = "IsolationFailure", occurrences = 1 },
	})
	assertRejected(function()
		ResultV1.finalize(wrongCategory)
	end, "RESULT_E_RELATION", "failure category/code mismatch")
end

do
	local invalidRole = completedInvalidDraft()
	local failure = invalidRole.failures[1]
	failure.firstOccurrence.participant = { role = "ProbeClient", index = 1 }
	assertRejected(function()
		ResultV1.finalize(invalidRole)
	end, "RESULT_E_RELATION", "workload ProbeClient first occurrence")
end

local function comparatorMismatches()
	local submission = Fixtures.generate("state-steady-c2s", 1).measured[1]
	local expected = submission.expected
	local mismatches = {}

	local function retain(label, expectedReason, compare)
		local matches, mismatch = compare()
		assert(not matches and mismatch ~= nil, `{label} must produce a mismatch`)
		assert(mismatch.reason == expectedReason, `{label} expected {expectedReason}, got {tostring(mismatch.reason)}`)
		mismatches[expectedReason] = deepClone(mismatch)
	end

	retain("wrong container", "WrongContainerType", function()
		return PayloadComparator.compareRecord("state", expected, "not-a-record")
	end)
	retain("positional arity", "ArityMismatch", function()
		return PayloadComparator.comparePositional("state", expected, expected.sequence)
	end)
	retain("missing field", "MissingField", function()
		local actual = deepClone(expected)
		actual.health = nil
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("extra field", "ExtraField", function()
		local actual = deepClone(expected)
		actual.extra = true
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("wrong field type", "WrongType", function()
		local actual = deepClone(expected)
		actual.health = "healthy"
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("non-finite field", "NonFinite", function()
		local actual = deepClone(expected)
		actual.yaw = math.huge
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("non-integer field", "NonInteger", function()
		local actual = deepClone(expected)
		actual.health = 0.5
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("out-of-range field", "OutOfRange", function()
		local actual = deepClone(expected)
		actual.health = 101
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("non-float32 field", "NotFloat32", function()
		local floatBytes = buffer.create(4)
		buffer.writef32(floatBytes, 0, expected.yaw)
		local bits = buffer.readu32(floatBytes, 0)
		buffer.writeu32(floatBytes, 0, bits + 1)
		local adjacent = buffer.readf32(floatBytes, 0)
		local actual = deepClone(expected)
		actual.yaw = expected.yaw + (adjacent - expected.yaw) / 2
		return PayloadComparator.compareRecord("state", expected, actual)
	end)
	retain("different value", "ValueMismatch", function()
		local actual = deepClone(expected)
		actual.health = if expected.health == 0 then 1 else expected.health - 1
		return PayloadComparator.compareRecord("state", expected, actual)
	end)

	return mismatches
end

local allComparatorMismatches = comparatorMismatches()

local function completedPayloadMismatchDraft(mismatch)
	return completedInvalidWithFailures({
		{
			category = "Correctness",
			code = "PayloadMismatch",
			occurrences = 1,
			discriminator = { mismatchReason = mismatch.reason },
			firstOccurrence = {
				repetitionIndex = 1,
				participant = { role = "Recipient", index = 1 },
				mismatch = deepClone(mismatch),
			},
		},
	}, function(_, _, counts)
		counts.correct -= 1
		counts.mismatch = 1
	end)
end

for reason, mismatch in allComparatorMismatches do
	local draft = completedPayloadMismatchDraft(mismatch)
	local result = ResultV1.finalize(draft)
	local retained = nil
	for _, failure in result.failures do
		if failure.code == "PayloadMismatch" then
			retained = failure.firstOccurrence.mismatch
		end
	end
	assert(retained ~= nil and retained.reason == reason, `{reason} comparator reason did not round-trip`)
	assertDeepEqual(retained, mismatch, `{reason} comparator mismatch`)
end

local comparatorDiagnosticMutations = {
	{
		label = "mismatch reason",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.reason = "MissingField"
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "mismatch descriptor path",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.path = "notAContractField"
		end,
		expectedCode = "RESULT_E_ENUM",
	},
	{
		label = "expected presence flag",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.expectedPresent = false
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "actual presence flag",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.actualPresent = false
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "missing expected diagnostic",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.expected = nil
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "missing actual diagnostic",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.actual = nil
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "out-of-descriptor expected diagnostic",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.expected = 101
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "equal ValueMismatch diagnostics",
		reason = "ValueMismatch",
		mutate = function(mismatch)
			mismatch.actual = mismatch.expected
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "forbidden container expected diagnostic",
		reason = "WrongContainerType",
		mutate = function(mismatch)
			mismatch.expected = 1
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "forbidden missing-field actual diagnostic",
		reason = "MissingField",
		mutate = function(mismatch)
			mismatch.actual = 1
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "forbidden extra-field actual diagnostic",
		reason = "ExtraField",
		mutate = function(mismatch)
			mismatch.actual = 1
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "forbidden wrong-type actual diagnostic",
		reason = "WrongType",
		mutate = function(mismatch)
			mismatch.actual = 1
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "forbidden non-finite actual diagnostic",
		reason = "NonFinite",
		mutate = function(mismatch)
			mismatch.actual = 1
		end,
		expectedCode = "RESULT_E_RELATION",
	},
	{
		label = "missing arity expected diagnostic",
		reason = "ArityMismatch",
		mutate = function(mismatch)
			mismatch.expected = nil
		end,
		expectedCode = "RESULT_E_RELATION",
	},
}
for _, mutation in comparatorDiagnosticMutations do
	local draft = completedPayloadMismatchDraft(allComparatorMismatches[mutation.reason])
	local mismatch = draft.failures[#draft.failures].firstOccurrence.mismatch
	mutation.mutate(mismatch)
	assertRejected(function()
		ResultV1.finalize(draft)
	end, mutation.expectedCode, `comparator parity: {mutation.label}`)
end

do
	local mismatch = allComparatorMismatches.ValueMismatch
	local caseValue, probe = completeProbeCase("tiny-round-trip")
	local tinySubmission = Fixtures.generate("tiny-steady-c2s", 1).measured[1]
	local actual = deepClone(tinySubmission.expected)
	actual.enabled = not actual.enabled
	local matches, probeMismatch = PayloadComparator.compareRecord("tiny", tinySubmission.expected, actual)
	assert(not matches and probeMismatch.reason == "ValueMismatch", "probe comparator mismatch missing")
	local probeInvalid = makeDraft(
		caseValue,
		repositoryAdapter(),
		{
			{
				category = "Correctness",
				code = "PayloadMismatch",
				occurrences = 1,
				discriminator = { mismatchReason = probeMismatch.reason },
				firstOccurrence = {
					repetitionIndex = 1,
					participant = { role = "ProbeClient", index = 1 },
					mismatch = deepClone(probeMismatch),
				},
			},
		},
		nil,
		conformingClockProof(),
		buildMeasurements(caseValue, probe, "InvalidCompleted")
	)
	local result = ResultV1.finalize(probeInvalid)
	assert(result.status == "Invalid", "ProbeClient payload mismatch must derive Invalid")
	assert(result.failures[1].firstOccurrence.participant.role == "ProbeClient", "ProbeClient first occurrence lost")
	assert(mismatch.reason == result.failures[1].firstOccurrence.mismatch.reason, "probe/workload comparator parity differs")
end

local function smallValidWorkloadDraft(options)
	options = options or {}
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	local counts = plannedCounts(caseValue, workload)
	local perRepetition = workload.measuredFrames * workload.messagesPerFrame
	local countValues = {
		submitted = table.create(caseValue.scheduledRepetitions, perRepetition),
		received = table.create(caseValue.scheduledRepetitions, perRepetition),
		correct = table.create(caseValue.scheduledRepetitions, perRepetition),
	}
	options.countValuesByRepetition = countValues
	options.exactTotals = {
		submitted = counts.submitted,
		received = counts.received,
		correct = counts.correct,
	}
	return makeDraft(
		caseValue,
		repositoryAdapter(),
		{},
		counts,
		conformingClockProof(),
		buildMeasurements(caseValue, workload, "Available", options)
	)
end

for _, reason in { "NotSupportedByAdapter", "UnavailableInEnvironment", "CaptureFailed" } do
	local result = ResultV1.finalize(smallValidWorkloadDraft({
		unavailableById = { engineDataSendRate = reason },
	}))
	assert(result.status == "Valid", `optional {reason} must not invalidate result`)
	local measurement = findResultMeasurement(result, "engineDataSendRate")
	assert(measurement.state == "Unavailable" and measurement.unavailableReason.code == reason, `optional {reason} lost`)
end

do
	local draft = smallValidWorkloadDraft({ unavailableById = { frameTime = "CaptureFailed" } })
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "required measurement unavailable on Valid")
end

do
	local draft = smallValidWorkloadDraft({ unavailableById = { engineDataSendRate = "CaseUnsupported" } })
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "optional CaseUnsupported on Valid")
end

do
	local draft = completedInvalidDraft()
	for _, measurement in draft.measurements do
		if measurement.id == "submitted" then
			measurement.state = "Diagnostic"
		end
	end
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "Exact measurement Diagnostic")
end

do
	local draft = completedInvalidDraft()
	for _, measurement in draft.measurements do
		if measurement.id == "frameTime" then
			measurement.state = "Available"
		end
	end
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "Invalid percentile measurement Available")
end

do
	local draft = smallValidWorkloadDraft()
	draft.measurements[1], draft.measurements[2] = draft.measurements[2], draft.measurements[1]
	local normalized = ResultV1.finalize(draft)
	assert(normalized.measurements[1].metadata.id == "submitted" and normalized.measurements[2].metadata.id == "received", "finalize did not canonicalize measurement order")
	local noncanonical = deepClone(normalized)
	noncanonical.measurements[1], noncanonical.measurements[2] = noncanonical.measurements[2], noncanonical.measurements[1]
	assertRejected(function()
		ResultV1.validate(noncanonical)
	end, "RESULT_E_ORDER", "serialized measurement order")
end

do
	local noncanonical = deepClone(probeResult)
	local samples = noncanonical.measurements[1].rawSamples
	samples[1], samples[2] = samples[2], samples[1]
	assertRejected(function()
		ResultV1.validate(noncanonical)
	end, "RESULT_E_ORDER", "serialized sample group order")
end

do
	local mutated = deepClone(probeResult)
	mutated.measurements[1].metadata.unit = "seconds"
	assertRejected(function()
		ResultV1.validate(mutated)
	end, "RESULT_E_RELATION", "measurement metadata drift")
	mutated = deepClone(probeResult)
	mutated.measurements[1].summary.median += 1
	assertRejected(function()
		ResultV1.validate(mutated)
	end, "RESULT_E_NONCANONICAL", "derived median drift")
	mutated = deepClone(probeResult)
	mutated.measurements[1].summary.p95 += 1
	assertRejected(function()
		ResultV1.validate(mutated)
	end, "RESULT_E_NONCANONICAL", "derived p95 drift")
	mutated = deepClone(probeResult)
	mutated.measurements[1].summary.sampleCount -= 1
	assertRejected(function()
		ResultV1.validate(mutated)
	end, "RESULT_E_NONCANONICAL", "derived sample count drift")
end

do
	local repeated = ResultV1.finalize(canonicalProbeDraft({
		valueProviders = {
			roundTripLatency = function()
				return 7.25
			end,
		},
	}))
	local summary = repeated.measurements[1].summary
	assert(summary.median == 7.25 and summary.p95 == 7.25, "repeated percentile values differ")

	local extremeMedian = ResultV1.finalize(canonicalProbeDraft({
		valueProviders = {
			roundTripLatency = function()
				return 1e308
			end,
		},
	}))
	summary = extremeMedian.measurements[1].summary
	assert(summary.median == 1e308 and summary.p95 == 1e308, "overflow-safe even median differs")

	local extremeP95 = ResultV1.finalize(canonicalProbeDraft({
		valueProviders = {
			roundTripLatency = function(index)
				return if index <= 3_419 then 0 else 1e308
			end,
		},
	}))
	summary = extremeP95.measurements[1].summary
	assert(summary.median == 0 and summary.p95 == 1e308, "nearest-rank p95 or outlier retention differs")
end

do
	local malformed = canonicalProbeDraft()
	malformed.measurements[1].rawSamples[1].values[2] = nil
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "sparse raw values")

	malformed = canonicalProbeDraft()
	malformed.measurements[1].rawSamples[1].values.label = 1
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "non-array raw value key")

	for label, value in {
		NaN = 0 / 0,
		positiveInfinity = math.huge,
		negativeInfinity = -math.huge,
		negative = -1,
	} do
		malformed = canonicalProbeDraft()
		malformed.measurements[1].rawSamples[1].values[1] = value
		assertRejected(function()
			ResultV1.finalize(malformed)
		end, "RESULT_E_RANGE", `raw sample {label}`)
	end

	malformed = canonicalProbeDraft()
	malformed.measurements[1].rawSamples[1].values = table.create(1_001, 1)
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_LIMIT", "1,001 values in one sample group")

	malformed = canonicalProbeDraft()
	table.insert(malformed.measurements[1].rawSamples, deepClone(malformed.measurements[1].rawSamples[#malformed.measurements[1].rawSamples]))
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "probe sample cardinality exceeds 3,600")
end

do
	local malformed = smallValidWorkloadDraft()
	for _, measurement in malformed.measurements do
		if measurement.id == "submitted" then
			measurement.rawSamples[1].values[1] += 0.5
		end
	end
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", "fractional Exact sample")

	malformed = smallValidWorkloadDraft({
		valueProviders = {
			remoteCalls = function()
				return MAX_SAFE_INTEGER
			end,
		},
	})
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_ARITHMETIC", "Exact total overflow")
end

do
	local malformed = canonicalProbeDraft()
	malformed.measurements[1].rawSamples[1].repetitionIndex = 0
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", "sample repetition zero")

	malformed = canonicalProbeDraft()
	malformed.measurements[1].rawSamples[1].participantIndex = 0
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", "sample participant zero")

	malformed = smallValidWorkloadDraft()
	for _, measurement in malformed.measurements do
		if measurement.id == "submitted" then
			measurement.rawSamples[1].participantIndex = 1
		end
	end
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "Coordinator sample participant index")

	malformed = smallValidWorkloadDraft()
	for _, measurement in malformed.measurements do
		if measurement.id == "frameTime" then
			measurement.rawSamples[1].participantIndex = nil
		end
	end
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "Sender sample missing participant index")
end

do
	local malformed = canonicalProbeDraft()
	malformed.measurements[1].id = "unknownMeasurement"
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "unknown measurement ID")

	malformed = canonicalProbeDraft()
	malformed.measurements[1].unavailableReason = { code = "CaptureFailed" }
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "Available measurement unavailable reason")

	malformed = canonicalProbeDraft()
	malformed.measurements[1] = {
		id = "roundTripLatency",
		state = "Unavailable",
		unavailableReason = { code = "CaseUnsupported", detail = "secret" },
	}
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "unavailable reason extension", "secret")
end

do
	local mismatch = allComparatorMismatches.ValueMismatch
	local overflow = completedInvalidWithFailures({
		{
			category = "Correctness",
			code = "PayloadMismatch",
			occurrences = MAX_SAFE_INTEGER,
			discriminator = { mismatchReason = "ValueMismatch" },
			firstOccurrence = { repetitionIndex = 1, participant = { role = "Recipient", index = 1 }, mismatch = deepClone(mismatch) },
		},
		{
			category = "Correctness",
			code = "PayloadMismatch",
			occurrences = 1,
			discriminator = { mismatchReason = "WrongContainerType" },
			firstOccurrence = { repetitionIndex = 1, participant = { role = "Recipient", index = 1 }, mismatch = deepClone(allComparatorMismatches.WrongContainerType) },
		},
	})
	assertRejected(function()
		ResultV1.finalize(overflow)
	end, "RESULT_E_ARITHMETIC", "failure occurrence sum overflow")

	local zero = completedInvalidWithFailures({
		{ category = "Contract", code = "IsolationFailure", occurrences = 0 },
	})
	assertRejected(function()
		ResultV1.finalize(zero)
	end, "RESULT_E_RANGE", "zero failure occurrences")

	local extra = completedInvalidWithFailures({
		{ category = "Contract", code = "IsolationFailure", occurrences = 1, discriminator = { stage = "Setup" } },
	})
	assertRejected(function()
		ResultV1.finalize(extra)
	end, "RESULT_E_KEYSET", "forbidden failure discriminator")
end

do
	local malformed = completedInvalidDraft()
	local payloadFailure = malformed.failures[1]
	payloadFailure.discriminator.mismatchReason = "MissingField"
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "mismatch/discriminator disagreement")

	malformed = completedInvalidDraft()
	payloadFailure = malformed.failures[1]
	payloadFailure.firstOccurrence.repetitionIndex = 0
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", "first occurrence repetition zero")

	malformed = completedInvalidDraft()
	payloadFailure = malformed.failures[1]
	payloadFailure.firstOccurrence.mismatch.path = "$.health"
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_ENUM", "transformed comparator path")
end

do
	local malformed = completedUntrustedErrorDraft()
	malformed.conformance.clockProof.passed = true
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "ClockProofFailure with passing proof")

	malformed = canonicalProbeDraft()
	malformed.conformance.clockProof.passed = false
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "failed clock proof without Harness evidence")

	malformed = completedUntrustedErrorDraft()
	table.insert(malformed.failures, {
		category = "Measurement",
		code = "RequiredMeasurementUnavailable",
		occurrences = 1,
		discriminator = { measurementId = "submitted" },
	})
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "Harness and Measurement category mixing")
end

do
	local ordered = deepClone(invalidResult)
	ordered.failures[1], ordered.failures[2] = ordered.failures[2], ordered.failures[1]
	assertRejected(function()
		ResultV1.validate(ordered)
	end, "RESULT_E_ORDER", "serialized failure order")
end

do
	assertRejected(function()
		ResultV1.finalize("not-a-draft")
	end, "RESULT_E_TYPE", "non-table draft")

	local malformed = canonicalProbeDraft()
	malformed.adapter.capabilities.payloadIds = { "state", "state", "tiny" }
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RELATION", "duplicate capability declaration")

	malformed = canonicalProbeDraft()
	malformed.runId = "AAAAAAAA-2222-4333-8444-555555555555"
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", "uppercase run UUID")

	malformed = canonicalProbeDraft()
	malformed.contractFingerprint = "sha256:" .. string.rep("A", 64)
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", "uppercase contract fingerprint")

	malformed = canonicalProbeDraft()
	malformed.benchmarkSource.dirty = "yes"
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_TYPE", "non-boolean dirty state")
end

local forbiddenEnvironmentFields = { "username", "hostname", "path", "token", "placeId", "jobId", "timestamp" }
do
	local malformed = canonicalProbeDraft()
	for _, field in forbiddenEnvironmentFields do
		local secret = `TOP-SECRET-{field}`
		malformed.environment.host[field] = secret
		assertRejected(function()
			ResultV1.finalize(malformed)
		end, "RESULT_E_KEYSET", `forbidden environment {field}`, secret)
		malformed.environment.host[field] = nil
	end

	malformed.environment.host.cpuModel = "token workstation"
	local allowed = ResultV1.finalize(malformed)
	assert(allowed.environment.host.cpuModel == "token workstation", "allowlisted labels must not use heuristic secret scanning")
end

for label, rejectedValue in {
	control = "CPU\nserial",
	carriageReturn = "CPU\rserial",
	bidi = "CPU" .. utf8.char(0x202E) .. "serial",
} do
	local malformed = canonicalProbeDraft()
	malformed.environment.host.cpuModel = rejectedValue
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_RANGE", `environment label {label}`, rejectedValue)
end

do
	local normalized = canonicalProbeDraft()
	normalized.environment.host.cpuModel = "  Test   CPU  "
	local result = ResultV1.finalize(normalized)
	assert(result.environment.host.cpuModel == "Test CPU", "host label not normalized")

	local wrongExecution = canonicalProbeDraft()
	wrongExecution.environment.execution.targetFrameRate += 1
	assertRejected(function()
		ResultV1.finalize(wrongExecution)
	end, "RESULT_E_RELATION", "environment target frame rate")
end

do
	local secretKey = "TOP-SECRET-UNKNOWN-KEY"
	local malformed = preStartErrorDraft()
	malformed[secretKey] = "TOP-SECRET-UNKNOWN-VALUE"
	local before = deepClone(malformed)
	local message = assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "unknown root key redaction", secretKey)
	assert(string.find(message, "TOP-SECRET-UNKNOWN-VALUE", 1, true) == nil, "unknown value leaked")
	assertDeepEqual(malformed, before, "rejected draft mutation")

	malformed = preStartErrorDraft()
	malformed[1] = true
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_KEYSET", "non-string object key")
end

do
	local metatableTouched = false
	local malformed = preStartErrorDraft()
	setmetatable(malformed.environment.host, {
		__index = function()
			metatableTouched = true
			return nil
		end,
		__pairs = function()
			metatableTouched = true
			error("must not run")
		end,
	})
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_METATABLE", "host metatable")
	assert(not metatableTouched, "validator invoked hostile metatable")

	malformed = preStartErrorDraft()
	malformed.environment.host.loop = malformed.environment.host
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_CYCLE", "input cycle")

	malformed = preStartErrorDraft()
	malformed.environment.host.shared = malformed.adapter.library
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_ALIAS", "input shared alias")
end

do
	local malformed = preStartErrorDraft()
	malformed.extra = {}
	local cursor = malformed.extra
	for _ = 1, 6 do
		cursor.next = {}
		cursor = cursor.next
	end
	assertIdentityIssue(malformed.extra, "Canonical", "0.650.0.6500000", "LIMIT", "$.adapter", "shared identity depth limit")
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_LIMIT", "nested depth limit")

	malformed = preStartErrorDraft()
	malformed.extra = {}
	for index = 1, 4_096 do
		malformed.extra[`node{index}`] = {}
	end
	assertIdentityIssue(malformed.extra, "Canonical", "0.650.0.6500000", "LIMIT", "$.adapter", "shared identity table node limit")
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_LIMIT", "table node limit")

	malformed = preStartErrorDraft()
	malformed.extra = {}
	for index = 1, 131_073 do
		malformed.extra[`entry{index}`] = true
	end
	assertIdentityIssue(malformed.extra, "Canonical", "0.650.0.6500000", "LIMIT", "$.adapter", "shared identity table entry limit")
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_LIMIT", "table entry limit")
end

do
	local malformed = canonicalProbeDraft()
	malformed.measurements[1].rawSamples[2].values = malformed.measurements[1].rawSamples[1].values
	assertRejected(function()
		ResultV1.finalize(malformed)
	end, "RESULT_E_ALIAS", "raw sample shared alias")
end

local mutableCandidate = serde.decode("json", encodedWorkload)
local mutableBefore = deepClone(mutableCandidate)
local validatedMutable = ResultV1.validate(mutableCandidate)
assertDeepEqual(mutableCandidate, mutableBefore, "validate input")
mutableCandidate.benchmark.source.dirty = not mutableCandidate.benchmark.source.dirty
assert(validatedMutable.benchmark.source.dirty ~= mutableCandidate.benchmark.source.dirty, "validate output must detach from input")

local function incompleteInvalidDraft(countOverrides, extraFailures)
	local caseValue, workload = completeWorkloadCase("state-steady-c2s", 1)
	caseValue.startedRepetitions = 1
	caseValue.completedRepetitions = 0
	local overrides = {
		finality = "Partial",
		submitted = 0,
		received = 0,
		correct = 0,
		missing = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
	}
	for key, value in countOverrides do
		overrides[key] = value
	end
	local counts = plannedCounts(caseValue, workload, overrides)
	local failures = requiredMeasurementFailures(caseValue)
	for _, failure in extraFailures or {} do
		table.insert(failures, failure)
	end
	return makeDraft(
		caseValue,
		repositoryAdapter(),
		failures,
		counts,
		conformingClockProof(),
		unavailableMeasurements(caseValue, workload, "CaseNotCompleted")
	), workload
end

local redProofFailures = {}
local function redProof(label, proof)
	local ok, failure = pcall(proof)
	if not ok then
		table.insert(redProofFailures, `{label}: {tostring(failure)}`)
	end
end

redProof("observation-limit evidence below saturation", function()
	local draft, workload = incompleteInvalidDraft({}, {})
	local observationLimit = 4 * draft.counts.expectedDeliveries
	draft.counts.submitted = workload.measuredFrames
	draft.counts.received = observationLimit - 1
	draft.counts.correct = workload.measuredFrames
	draft.counts.unexpected = observationLimit - 1 - workload.measuredFrames
	table.insert(draft.failures, {
		category = "Correctness",
		code = "UnexpectedDelivery",
		occurrences = observationLimit - 1 - workload.measuredFrames,
	})
	table.insert(draft.failures, {
		category = "Contract",
		code = "DeliveryObservationLimitExceeded",
		occurrences = 1,
		firstOccurrence = { repetitionIndex = 1, participant = { role = "Coordinator" } },
	})
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "observation-limit evidence below saturation")
end)

redProof("submitted exceeds started-repetition capacity", function()
	local draft, workload = incompleteInvalidDraft({}, {})
	local startedCapacity = draft.case.startedRepetitions
		* draft.case.senderCount
		* workload.measuredFrames
		* workload.messagesPerFrame
	draft.counts.submitted = startedCapacity + 1
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "submitted exceeds started-repetition capacity")
end)

redProof("verified deliveries exceed submitted fan-out", function()
	local draft = incompleteInvalidDraft({
		submitted = 1,
		received = 2,
		correct = 2,
	}, {})
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "correct plus mismatch exceeds submitted fan-out")
end)

redProof("duplicate lacks an earlier expected delivery", function()
	local draft = incompleteInvalidDraft({
		submitted = 1,
		received = 1,
		duplicate = 1,
	}, {
		{ category = "Correctness", code = "DuplicateDelivery", occurrences = 1 },
	})
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RELATION", "duplicate without correct or mismatched delivery")
end)

redProof("every observed expected identity may be out of order", function()
	local fixture = Fixtures.generate("state-steady-c2s", 1)
	local ledger = DeliveryLedger.new(fixture.measured)
	for index = 2, #fixture.measured do
		local submission = fixture.measured[index]
		local status = ledger:recordDelivery(submission.payloadId, submission.sequence, true)
		assert(status == "Expected", "out-of-order reachability delivery must be expected")
	end
	local clean, reachableSnapshot = ledger:close()
	assert(not clean, "out-of-order reachability ledger must close dirty")
	assert(reachableSnapshot.missing == 1, "out-of-order reachability must leave ordinal one unseen")
	assert(reachableSnapshot.outOfOrder == reachableSnapshot.correct, "every observed expected identity must be out of order")
	assert(reachableSnapshot.correct == #fixture.measured - 1, "out-of-order reachability count differs")

	local draft = completedInvalidWithFailures({
		{ category = "Correctness", code = "MissingDelivery", occurrences = 1 },
		{ category = "Correctness", code = "OutOfOrderDelivery", occurrences = 3_599 },
	}, function(_, _, counts)
		counts.received = counts.expectedDeliveries - 1
		counts.correct = counts.expectedDeliveries - 1
		counts.missing = 1
		counts.outOfOrder = counts.expectedDeliveries - 1
	end)
	local result = ResultV1.finalize(draft)
	assert(result.status == "Invalid" and result.counts.finality == "Final", "reachable out-of-order aggregate must be Final Invalid")
	assert(result.counts.outOfOrder == result.counts.correct + result.counts.mismatch, "reachable out-of-order equality lost")
end)

redProof("Valid per-repetition submission distribution", function()
	local validDraft = smallValidWorkloadDraft()
	local validSubmitted = nil
	for _, measurement in validDraft.measurements do
		if measurement.id == "submitted" then
			validSubmitted = measurement
		end
	end
	assert(validSubmitted ~= nil, "Valid submitted measurement missing")
	validSubmitted.rawSamples[1].values[1] -= 1
	validSubmitted.rawSamples[2].values[1] += 1
	assertRejected(function()
		ResultV1.finalize(validDraft)
	end, "RESULT_E_RELATION", "Valid redistributed per-repetition submissions")

	local invalidDraft = completedInvalidDraft()
	local invalidSubmitted = nil
	for _, measurement in invalidDraft.measurements do
		if measurement.id == "submitted" then
			invalidSubmitted = measurement
		end
	end
	assert(invalidSubmitted ~= nil, "Invalid submitted measurement missing")
	invalidSubmitted.rawSamples[1].values[1] -= 1
	invalidSubmitted.rawSamples[2].values[1] += 1
	local invalidResult = ResultV1.finalize(invalidDraft)
	assert(invalidResult.status == "Invalid", "Invalid completed raw distributions must remain flexible")
end)

redProof("leading punctuation in environment tokens", function()
	local draft = canonicalProbeDraft({ adapter = repositoryAdapter() })
	draft.environment.studio.version = ".650"
	draft.environment.studio.channel = "_production"
	draft.environment.host.osVersion = "-11"
	local result = ResultV1.finalize(draft)
	assert(result.environment.studio.version == ".650", "leading-dot Studio token lost")
	assert(result.environment.studio.channel == "_production", "leading-underscore channel token lost")
	assert(result.environment.host.osVersion == "-11", "leading-hyphen OS token lost")
end)

redProof("negative zero safe integer", function()
	local draft = setupFailedDraft()
	draft.counts.submitted = -0
	assert(1 / draft.counts.submitted == -math.huge, "test must construct signed negative zero")
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RANGE", "negative-zero submitted count")
end)

redProof("negative zero raw nonnegative sample", function()
	local draft = canonicalProbeDraft()
	draft.measurements[1].rawSamples[1].values[1] = -0
	assert(1 / draft.measurements[1].rawSamples[1].values[1] == -math.huge, "test must construct signed negative-zero sample")
	assertRejected(function()
		ResultV1.finalize(draft)
	end, "RESULT_E_RANGE", "negative-zero raw sample")
end)

redProof("negative zero serialized summary", function()
	local zeroResult = ResultV1.finalize(canonicalProbeDraft({
		valueProviders = {
			roundTripLatency = function()
				return 0
			end,
		},
	}))
	assert(1 / zeroResult.measurements[1].summary.median == math.huge, "derived median must be positive zero")
	local candidate = deepClone(zeroResult)
	candidate.measurements[1].summary.median = -0
	assert(1 / candidate.measurements[1].summary.median == -math.huge, "candidate median must be negative zero")
	assertRejected(function()
		ResultV1.validate(candidate)
	end, "RESULT_E_NONCANONICAL", "negative-zero serialized median")
end)

redProof("signed-zero comparator evidence", function()
	local submission = Fixtures.generate("state-steady-c2s", 1).measured[1]
	local expected = deepClone(submission.expected)
	expected.yaw = 0
	local actual = deepClone(expected)
	actual.yaw = -0
	local matches, mismatch = PayloadComparator.compareRecord("state", expected, actual)
	assert(not matches and mismatch ~= nil, "signed-zero comparator must retain a mismatch")
	assert(mismatch.path == "yaw" and mismatch.reason == "ValueMismatch", "signed-zero mismatch identity differs")
	assert(1 / mismatch.expected == math.huge and 1 / mismatch.actual == -math.huge, "signed-zero diagnostics lost before result finalization")

	local result = ResultV1.finalize(completedPayloadMismatchDraft(mismatch))
	local retained = nil
	for _, failure in result.failures do
		if failure.code == "PayloadMismatch" then
			retained = failure.firstOccurrence.mismatch
		end
	end
	assert(retained ~= nil, "signed-zero result mismatch missing")
	assert(1 / retained.expected == math.huge and 1 / retained.actual == -math.huge, "signed-zero diagnostics lost during finalization")
	local validated = ResultV1.validate(result)
	local validatedMismatch = nil
	for _, failure in validated.failures do
		if failure.code == "PayloadMismatch" then
			validatedMismatch = failure.firstOccurrence.mismatch
		end
	end
	assert(validatedMismatch ~= nil, "validated signed-zero mismatch missing")
	assert(1 / validatedMismatch.expected == math.huge and 1 / validatedMismatch.actual == -math.huge, "signed-zero diagnostics lost during validation")
	local jsonValidated = ResultV1.validate(serde.decode("json", serde.encode("json", result)))
	local jsonMismatch = nil
	for _, failure in jsonValidated.failures do
		if failure.code == "PayloadMismatch" then
			jsonMismatch = failure.firstOccurrence.mismatch
		end
	end
	assert(jsonMismatch ~= nil, "JSON signed-zero mismatch missing")
	assert(1 / jsonMismatch.expected == math.huge and 1 / jsonMismatch.actual == -math.huge, "signed-zero diagnostics lost during JSON round trip")
end)

if #redProofFailures > 0 then
	error("RESULT_V1_RED_PROOF\n- " .. table.concat(redProofFailures, "\n- "), 0)
end

print("PASS Relay.Benchmarks.ResultV1")
