local Contract = require("../contracts/event-v1")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local Identity = require("../contracts/internal/AdapterIdentity")
local ResultV1 = require("../contracts/result-v1")
local Fixtures = require("../fixtures/event-v1")
local ResultDraftAssembler = require("../runner/ResultDraftAssembler")

local RUN_ID = "10213243-5465-7687-98a9-bacbdcedfe0f"

local function deepClone(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end
	local copied = {}
	seen[value] = copied
	for key, nested in value do
		copied[deepClone(key, seen)] = deepClone(nested, seen)
	end
	return copied
end

local function deepFreeze(value, seen)
	if type(value) ~= "table" or table.isfrozen(value) then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return value
	end
	seen[value] = true
	for key, nested in value do
		deepFreeze(key, seen)
		deepFreeze(nested, seen)
	end
	return table.freeze(value)
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

local function assertExactKeys(value, keys, label)
	local allowed = {}
	for _, key in keys do
		allowed[key] = true
	end
	local count = 0
	for key in value do
		count += 1
		assert(allowed[key], `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #keys, `{label} has the wrong key count`)
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
		assert(not inputTables[outputTable], `{label} retained an input table`)
	end
end

local function identity()
	return {
		id = "assembler-adapter",
		displayName = "Assembler Adapter",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "assembler-library",
			displayName = "Assembler Library",
			version = "1.0.0",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/assembler",
				revision = string.rep("a", 40),
				checksum = "sha256:" .. string.rep("b", 64),
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

local function manifest(selection)
	selection = selection or {
		kind = "Workload",
		workloadId = "tiny-steady-c2s",
		recipientCount = 1,
	}
	local candidate = {
		version = 1,
		launchId = "00112233-4455-6677-8899-aabbccddeeff",
		benchmarkSource = {
			revision = string.rep("c", 40),
			dirty = false,
		},
		contractFingerprint = "sha256:" .. string.rep("d", 64),
		adapter = {
			moduleId = "assembler-adapter",
			artifact = {
				kind = "RepositoryModule",
				digest = "sha256:" .. string.rep("b", 64),
			},
			identity = identity(),
		},
		selection = selection,
		environment = {
			studio = {
				version = "0.650.0.6500000",
				channel = "production",
			},
			host = {
				osFamily = "Windows",
				architecture = "x86_64",
				osVersion = "11",
				cpuModel = "Test CPU",
				logicalProcessorCount = 8,
				memoryMiB = 16_384,
				gpuModel = "Test GPU",
			},
		},
	}
	local checked = HostManifestV1.validate(candidate)
	assert(checked.kind == "Valid", "test manifest must validate")
	return checked.value
end

local function conformance()
	return {
		setupExcluded = true,
		warmupExcluded = true,
		quiescenceExcluded = true,
		resultExtractionExcluded = true,
		clockProofPassed = true,
	}
end

local function values(count, value)
	local output = table.create(count)
	for index = 1, count do
		output[index] = value
	end
	return output
end

local function resolvedSelection(selection)
	local resolved = Identity.resolveSelection(selection)
	assert(resolved.kind == "Valid", "test selection must resolve")
	return deepClone(resolved.value)
end

local function serverRepetition(repetitionIndex, started, completed)
	return {
		repetitionIndex = repetitionIndex,
		started = started,
		completed = completed,
		submitted = 0,
		received = if completed then 120 else 0,
		correct = if completed then 120 else 0,
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

local function clientRepetition(repetitionIndex, started, completed)
	local output = {
		repetitionIndex = repetitionIndex,
		started = started,
		completed = completed,
		submitted = if completed then 120 else 0,
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
	if completed then
		output.firstSubmissionStartedSharedSeconds = repetitionIndex * 10
		output.finalSubmissionReturnedSharedSeconds = repetitionIndex * 10 + 1
	end
	return output
end

local function completeSnapshot()
	local repetitions = Contract.workloads[1].repetitions
	local serverRepetitions = table.create(repetitions)
	local clientRepetitions = table.create(repetitions)
	local serverEndpoints = table.create(repetitions)
	local clientMeasurements = {}
	for repetitionIndex = 1, repetitions do
		serverRepetitions[repetitionIndex] = serverRepetition(repetitionIndex, true, true)
		clientRepetitions[repetitionIndex] = clientRepetition(repetitionIndex, true, true)
		serverEndpoints[repetitionIndex] = {
			repetitionIndex = repetitionIndex,
			finalExpectedDeliveryReceivedSharedSeconds = repetitionIndex * 10 + 1.5,
			finalExpectedDeliveryVerifiedSharedSeconds = repetitionIndex * 10 + 2,
		}
		for measurementIndex, measurementValues in {
			[4] = values(120, 16),
			[5] = { 1 },
			[10] = values(120, 10),
		} do
			table.insert(clientMeasurements, {
				measurementIndex = measurementIndex,
				repetitionIndex = repetitionIndex,
				values = measurementValues,
			})
		end
	end
	return deepFreeze({
		version = 1,
		selection = {
			kind = "Workload",
			workloadId = "tiny-steady-c2s",
			recipientCount = 1,
			clientProcessCount = 1,
			payloadId = "tiny",
			direction = "ClientToServer",
			audience = "Server",
			requirements = {
				{ capability = "Direction", required = "ClientToServer" },
				{ capability = "DeliverySemantics", required = "ReliableOrdered" },
				{ capability = "Payload", required = "tiny" },
			},
		},
		coordinator = {
			scheduledRepetitions = repetitions,
			startedRepetitions = repetitions,
			completedRepetitions = repetitions,
			finalOnlyEvidence = false,
			failureFacts = {},
		},
		participants = {
			{
				participant = { role = "Server" },
				evidence = {
					version = 1,
					repetitions = serverRepetitions,
					measurements = {},
					timingEndpoints = serverEndpoints,
					failureFacts = {},
					conformance = conformance(),
				},
			},
			{
				participant = { role = "Client", index = 1 },
				evidence = {
					version = 1,
					repetitions = clientRepetitions,
					measurements = clientMeasurements,
					failureFacts = {},
					conformance = conformance(),
				},
			},
		},
	})
end

local function completeBroadcastSnapshot(recipientCount)
	local selectionInput = {
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = recipientCount,
	}
	local selection = resolvedSelection(selectionInput)
	local repetitions = Contract.workloads[4].repetitions
	local serverRepetitions = table.create(repetitions)
	local serverEndpoints = table.create(repetitions)
	local serverMeasurements = {}
	for repetitionIndex = 1, repetitions do
		local repetition = serverRepetition(repetitionIndex, true, true)
		repetition.submitted = 120
		repetition.received = 0
		repetition.correct = 0
		serverRepetitions[repetitionIndex] = repetition
		serverEndpoints[repetitionIndex] = {
			repetitionIndex = repetitionIndex,
			firstSubmissionStartedSharedSeconds = repetitionIndex * 10,
			finalSubmissionReturnedSharedSeconds = repetitionIndex * 10 + 1,
		}
		for measurementIndex, measurementValues in {
			[4] = values(120, 16),
			[5] = { 1 },
			[10] = values(120, 10),
		} do
			table.insert(serverMeasurements, {
				measurementIndex = measurementIndex,
				repetitionIndex = repetitionIndex,
				values = measurementValues,
			})
		end
	end

	local participants = {
		{
			participant = { role = "Server" },
			evidence = {
				version = 1,
				repetitions = serverRepetitions,
				measurements = serverMeasurements,
				timingEndpoints = serverEndpoints,
				failureFacts = {},
				conformance = conformance(),
			},
		},
	}
	for clientIndex = 1, recipientCount do
		local clientRepetitions = table.create(repetitions)
		for repetitionIndex = 1, repetitions do
			local repetition = clientRepetition(repetitionIndex, true, true)
			repetition.submitted = 0
			repetition.received = 120
			repetition.correct = 120
			repetition.firstSubmissionStartedSharedSeconds = nil
			repetition.finalSubmissionReturnedSharedSeconds = nil
			repetition.finalExpectedDeliveryReceivedSharedSeconds = repetitionIndex * 10 + 1.5 + clientIndex / 100
			repetition.finalExpectedDeliveryVerifiedSharedSeconds = repetitionIndex * 10 + 2 + clientIndex / 100
			clientRepetitions[repetitionIndex] = repetition
		end
		table.insert(participants, {
			participant = { role = "Client", index = clientIndex },
			evidence = {
				version = 1,
				repetitions = clientRepetitions,
				measurements = {},
				failureFacts = {},
				conformance = conformance(),
			},
		})
	end
	return deepFreeze({
		version = 1,
		selection = selection,
		coordinator = {
			scheduledRepetitions = repetitions,
			startedRepetitions = repetitions,
			completedRepetitions = repetitions,
			finalOnlyEvidence = false,
			failureFacts = {},
		},
		participants = participants,
	}), selectionInput
end

local function completeProbeSnapshot()
	local selectionInput = { kind = "SeparateProbe", probeId = "tiny-round-trip" }
	local selection = resolvedSelection(selectionInput)
	local repetitions = Contract.probes[1].repetitions
	local serverRepetitions = table.create(repetitions)
	local clientRepetitions = table.create(repetitions)
	local measurements = table.create(repetitions)
	for repetitionIndex = 1, repetitions do
		local server = serverRepetition(repetitionIndex, true, true)
		server.probeRequestsReceived = 120
		server.probeRequestsCorrect = 120
		server.probeResponsesSubmitted = 120
		serverRepetitions[repetitionIndex] = server
		local client = clientRepetition(repetitionIndex, true, true)
		client.submitted = 0
		client.firstSubmissionStartedSharedSeconds = nil
		client.finalSubmissionReturnedSharedSeconds = nil
		client.probeStarted = 120
		client.probeSubmitted = 120
		client.probeReceived = 120
		client.probeCorrect = 120
		clientRepetitions[repetitionIndex] = client
		measurements[repetitionIndex] = {
			measurementIndex = 9,
			repetitionIndex = repetitionIndex,
			values = values(120, 2),
		}
	end
	return deepFreeze({
		version = 1,
		selection = selection,
		coordinator = {
			scheduledRepetitions = repetitions,
			startedRepetitions = repetitions,
			completedRepetitions = repetitions,
			finalOnlyEvidence = false,
			failureFacts = {},
		},
		participants = {
			{
				participant = { role = "Server" },
				evidence = {
					version = 1,
					repetitions = serverRepetitions,
					measurements = {},
					timingEndpoints = {},
					failureFacts = {},
					conformance = conformance(),
				},
			},
			{
				participant = { role = "ProbeClient", index = 1 },
				evidence = {
					version = 1,
					repetitions = clientRepetitions,
					measurements = measurements,
					failureFacts = {},
					conformance = conformance(),
				},
			},
		},
	}), selectionInput
end

local function assemble(snapshot, selection)
	local input = {
		runId = RUN_ID,
		manifest = manifest(selection),
		snapshot = snapshot,
	}
	table.freeze(input)
	local result = ResultDraftAssembler.assemble(input)
	return result, input
end

assertExactKeys(ResultDraftAssembler, { "assemble" }, "ResultDraftAssembler")
assert(table.isfrozen(ResultDraftAssembler), "ResultDraftAssembler must be frozen")

do
	local assembled, input = assemble(completeSnapshot())
	assert(assembled.kind == "Draft", "complete clean evidence must assemble")
	assertExactKeys(assembled, { "kind", "value" }, "Draft result")
	assertDeepFrozen(assembled)
	assertDetached(input, assembled, "Draft result")
	local draft = assembled.value
	assert(draft.counts.finality == "Final", "complete evidence must be Final")
	assert(draft.counts.expectedSubmissions == 3_600, "expected submissions differ")
	assert(draft.counts.correct == 3_600 and draft.counts.missing == 0, "clean delivery totals differ")
	assert(draft.environment.execution.clientCount == 1, "execution topology must use clientProcessCount")
	assert(#draft.measurements == 13, "workload must emit all 13 selected measurements")
	assert(draft.measurements[6].rawSamples[1].values[1] == 1_500, "completion duration differs")
	assert(draft.measurements[7].rawSamples[1].values[1] == 500, "drain duration differs")
	assert(draft.measurements[8].rawSamples[1].values[1] == 2_000, "wall duration differs")
	assert(draft.measurements[10].unavailableReason.code == "UnavailableInEnvironment", "engine rate reason differs")
	assert(draft.measurements[11].unavailableReason.code == "NotSupportedByAdapter", "adapter size reason differs")
	assert(draft.measurements[12].unavailableReason.code == "NotSupportedByAdapter", "remote call reason differs")
	assert(draft.measurements[13].unavailableReason.code == "UnavailableInEnvironment", "GC reason differs")
	local finalized = ResultV1.finalize(draft)
	assert(finalized.status == "Valid", "clean draft must finalize Valid")
	assert(ResultV1.validate(finalized).status == "Valid", "clean result must validate")
end

do
	local snapshot = deepClone(completeSnapshot())
	for repetitionIndex = 1, snapshot.coordinator.scheduledRepetitions do
		for measurementIndex, measurementValues in {
			[11] = values(120, 1),
			[12] = values(120, 2),
			[13] = { 3 },
			[14] = { 4 },
		} do
			table.insert(snapshot.participants[2].evidence.measurements, {
				measurementIndex = measurementIndex,
				repetitionIndex = repetitionIndex,
				values = measurementValues,
			})
		end
	end
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "completed optional measurements must assemble")
	for measurementIndex = 10, 13 do
		assert(assembled.value.measurements[measurementIndex].state == "Available", "completed optional measurement must be available")
	end
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Valid", "completed optional measurements must finalize Valid")
	assert(ResultV1.validate(result).status == "Valid", "completed optional measurement result must validate")
end

do
	local snapshot = deepClone(completeSnapshot())
	table.insert(snapshot.participants[2].evidence.measurements, {
		measurementIndex = 11,
		repetitionIndex = 1,
		values = values(120, 1),
	})
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "partially present optional capture must assemble")
	local engineRate = assembled.value.measurements[10]
	assert(engineRate.state == "Unavailable", "partial optional capture must be unavailable")
	assert(engineRate.unavailableReason.code == "CaptureFailed", "partial optional capture reason differs")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Valid", "partial optional capture must preserve Valid status")
end

do
	local snapshot = deepClone(completeSnapshot())
	table.insert(snapshot.participants[2].evidence.measurements, {
		measurementIndex = 11,
		repetitionIndex = 1,
		values = values(119, 1),
	})
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Terminated", "partial optional measurement must terminate")
	assert(assembled.termination.code == "FinalizationFailure", "partial optional measurement code differs")
	assert(assembled.termination.stage == "Finalize", "partial optional measurement stage differs")
end

do
	for _, code in { "IsolationFailure", "TeardownFailure" } do
		local snapshot = deepClone(completeSnapshot())
		for participantIndex = 1, 2 do
			table.insert(snapshot.participants[participantIndex].evidence.failureFacts, {
				code = code,
				occurrences = 1,
				firstRepetition = 1,
			})
		end
		deepFreeze(snapshot)
		local assembled = assemble(snapshot)
		assert(assembled.kind == "Terminated", `ambiguous {code} overlap must terminate`)
		assert(assembled.termination.code == "FinalizationFailure", `ambiguous {code} overlap code differs`)
		assert(assembled.termination.stage == "Finalize", `ambiguous {code} overlap stage differs`)
	end
end

do
	local snapshot, selection = completeProbeSnapshot()
	snapshot = deepClone(snapshot)
	for participantIndex = 1, 2 do
		table.insert(snapshot.participants[participantIndex].evidence.failureFacts, {
			code = "SubmitFailure",
			occurrences = 1,
			firstRepetition = 1,
		})
	end
	deepFreeze(snapshot)
	local assembled = assemble(snapshot, selection)
	assert(assembled.kind == "Terminated", "ambiguous probe submit overlap must terminate")
	assert(assembled.termination.code == "FinalizationFailure", "ambiguous probe submit overlap code differs")
end

do
	local snapshot, selection = completeBroadcastSnapshot(4)
	local assembled = assemble(snapshot, selection)
	assert(assembled.kind == "Draft", "four-client broadcast evidence must assemble")
	assert(assembled.value.environment.execution.clientCount == 4, "broadcast topology differs")
	assert(assembled.value.counts.expectedDeliveries == 14_400, "broadcast expected delivery total differs")
	assert(assembled.value.counts.correct == 14_400, "broadcast correct total differs")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Valid", "four-client broadcast must finalize Valid")
	assert(result.measurements[6].summary.median > 1_500, "broadcast completion must use latest receiver")
end

do
	local snapshot, selection = completeProbeSnapshot()
	local assembled = assemble(snapshot, selection)
	assert(assembled.kind == "Draft", "separate probe evidence must assemble")
	assert(assembled.value.counts == nil, "probe draft must not carry workload counts")
	assert(#assembled.value.measurements == 1, "probe must emit one measurement")
	assert(assembled.value.measurements[1].id == "roundTripLatency", "probe measurement differs")
	assert(assembled.value.measurements[1].rawSamples[1].participantIndex == 1, "probe participant index differs")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Valid", "separate probe must finalize Valid")
	assert(ResultV1.validate(result).status == "Valid", "separate probe result must validate")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.participants[1].evidence.repetitions[1].correct = 119
	snapshot.participants[1].evidence.repetitions[1].mismatch = 1
	local expected = Fixtures.generate("tiny-steady-c2s", 1).measured[1].expected.enabled
	snapshot.participants[1].evidence.failureFacts = {
		{
			code = "PayloadMismatch",
			occurrences = 1,
			discriminator = { kind = "MismatchReason", value = "ValueMismatch" },
			firstRepetition = 1,
			fixtureIndex = 1,
			mismatch = { pathKind = "Field", fieldIndex = 2, actual = not expected },
		},
	}
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "mismatch evidence must assemble")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Invalid", "payload mismatch must finalize Invalid")
	local failure = result.failures[1]
	assert(failure.code == "PayloadMismatch", "payload mismatch failure missing")
	assert(failure.firstOccurrence.participant.role == "Recipient", "server C2S mismatch role differs")
	assert(failure.firstOccurrence.participant.index == 1, "server C2S mismatch index differs")
	local mismatch = failure.firstOccurrence.mismatch
	assert(mismatch.path == "enabled" and mismatch.reason == "ValueMismatch", "mismatch identity differs")
	assert(mismatch.expected == expected and mismatch.actual == not expected, "trusted mismatch values differ")
	assert(assembled.value.measurements[4].state == "Diagnostic", "invalid timing measurements must be Diagnostic")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.participants[1].evidence.repetitions[1].received = 119
	snapshot.participants[1].evidence.repetitions[1].correct = 119
	snapshot.participants[2].evidence.repetitions[1].submitted = 119
	table.remove(snapshot.participants[1].evidence.timingEndpoints, 1)
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "final shortfall evidence must assemble")
	assert(assembled.value.counts.finality == "Final", "closed dirty repetitions must remain Final")
	assert(assembled.value.counts.missing == 1, "Final missing total differs")
	local shortfall = 0
	local missing = 0
	for _, failure in assembled.value.failures do
		if failure.code == "SubmissionShortfall" then
			shortfall = failure.occurrences
		elseif failure.code == "MissingDelivery" then
			missing = failure.occurrences
		end
	end
	assert(shortfall == 1 and missing == 1, "Final-only count failures differ")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Invalid", "final shortfall must finalize Invalid")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.coordinator.startedRepetitions = 0
	snapshot.coordinator.completedRepetitions = 0
	snapshot.coordinator.failureFacts = { { code = "SetupFailure", occurrences = 1 } }
	for _, participant in snapshot.participants do
		participant.evidence.measurements = {}
		participant.evidence.failureFacts = {}
		if participant.participant.role == "Server" then
			participant.evidence.timingEndpoints = {}
		end
		for repetitionIndex = 1, #participant.evidence.repetitions do
			participant.evidence.repetitions[repetitionIndex] = if participant.participant.role == "Server"
				then serverRepetition(repetitionIndex, false, false)
				else clientRepetition(repetitionIndex, false, false)
		end
	end
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "pre-start setup failure must assemble")
	assert(assembled.value.counts.finality == "NotStarted", "pre-start failure must be NotStarted")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Invalid", "pre-start setup failure must finalize Invalid")
	local requiredUnavailable = 0
	for _, failure in result.failures do
		if failure.code == "RequiredMeasurementUnavailable" then
			requiredUnavailable += 1
		end
	end
	assert(requiredUnavailable == 9, "NotStarted Invalid must derive nine required-measurement failures")
	for _, measurement in result.measurements do
		assert(measurement.state == "Unavailable", "NotStarted measurements must be unavailable")
		assert(measurement.unavailableReason.code == "CaseNotCompleted", "NotStarted reason differs")
	end
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.coordinator.startedRepetitions = 1
	snapshot.coordinator.completedRepetitions = 0
	snapshot.coordinator.failureFacts = {
		{ code = "Timeout", occurrences = 1, firstRepetition = 1 },
	}
	for _, participant in snapshot.participants do
		participant.evidence.measurements = {}
		participant.evidence.failureFacts = {}
		if participant.participant.role == "Server" then
			participant.evidence.timingEndpoints = {}
		end
		for repetitionIndex = 1, #participant.evidence.repetitions do
			participant.evidence.repetitions[repetitionIndex] = if participant.participant.role == "Server"
				then serverRepetition(repetitionIndex, repetitionIndex == 1, false)
				else clientRepetition(repetitionIndex, repetitionIndex == 1, false)
		end
	end
	snapshot.participants[1].evidence.repetitions[1].received = 9
	snapshot.participants[1].evidence.repetitions[1].correct = 9
	snapshot.participants[2].evidence.repetitions[1].submitted = 10
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "partial timeout evidence must assemble")
	assert(assembled.value.counts.finality == "Partial", "open repetition must project Partial")
	assert(assembled.value.counts.submitted == 10, "partial submitted total differs")
	assert(assembled.value.counts.received == 9, "partial received total differs")
	assert(assembled.value.counts.missing == 0, "Partial must never relabel absence as missing")
	for _, failure in assembled.value.failures do
		assert(failure.code ~= "SubmissionShortfall", "Partial must omit SubmissionShortfall")
		assert(failure.code ~= "MissingDelivery", "Partial must omit MissingDelivery")
	end
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Invalid", "partial timeout must finalize Invalid")
	local timeout = nil
	for _, failure in result.failures do
		if failure.code == "Timeout" then
			timeout = failure
		end
	end
	assert(timeout.firstOccurrence.participant.role == "Coordinator", "timeout participant must be Coordinator")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.coordinator.failureFacts = { { code = "ClockProofFailure", occurrences = 1 } }
	snapshot.participants[1].evidence.conformance.clockProofPassed = false
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "clock proof failure must assemble")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Error", "clock proof failure must finalize Error")
	for _, failure in result.failures do
		assert(failure.code ~= "RequiredMeasurementUnavailable", "Error must suppress measurement failures")
	end
	for _, measurement in result.measurements do
		assert(measurement.state == "Unavailable", "Error measurements must be unavailable")
		assert(measurement.unavailableReason.code == "ResultUntrusted", "complete Error reason differs")
	end
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.participants[2].evidence.failureFacts = {
		{ code = "IsolationFailure", occurrences = 1, firstRepetition = 1 },
	}
	local retained = {}
	for _, record in snapshot.participants[2].evidence.measurements do
		if record.measurementIndex ~= 4 then
			table.insert(retained, record)
		end
	end
	snapshot.participants[2].evidence.measurements = retained
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Draft", "Invalid missing capture must assemble")
	local frameTime = assembled.value.measurements[4]
	assert(frameTime.state == "Unavailable", "missing frame time must be unavailable")
	assert(frameTime.unavailableReason.code == "CaptureFailed", "missing frame time reason differs")
	local result = ResultV1.finalize(assembled.value)
	assert(result.status == "Invalid", "missing Invalid capture must remain Invalid")
	local found = false
	for _, failure in result.failures do
		if failure.code == "RequiredMeasurementUnavailable"
			and failure.discriminator.measurementId == "frameTime"
		then
			found = true
		end
	end
	assert(found, "Invalid missing capture must derive its measurement failure")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.coordinator.failureFacts = { { code = "ClockProofFailure", occurrences = 2 } }
	snapshot.participants[1].evidence.conformance.clockProofPassed = false
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Terminated", "singleton failure occurrences above one must terminate")
	assert(assembled.termination.code == "FinalizationFailure", "singleton failure termination differs")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.participants[2].evidence.measurements[1].values[1] = -0
	assert(1 / snapshot.participants[2].evidence.measurements[1].values[1] == -math.huge, "test must retain negative zero")
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Terminated", "negative-zero raw sample must terminate")
	assert(assembled.termination.code == "FinalizationFailure", "negative-zero termination differs")
end

do
	local snapshot = deepClone(completeSnapshot())
	snapshot.selection.clientProcessCount = 8
	deepFreeze(snapshot)
	local assembled = assemble(snapshot)
	assert(assembled.kind == "Terminated", "manifest/snapshot conflict must terminate")
	assertExactKeys(assembled, { "kind", "termination" }, "Terminated result")
	assertDeepFrozen(assembled)
	assert(assembled.termination.code == "FinalizationFailure", "conflict termination code differs")
	assert(assembled.termination.stage == "Finalize", "conflict termination stage differs")
end

do
	local ok, problem = pcall(function()
		ResultDraftAssembler.assemble({
			runId = RUN_ID,
			manifest = manifest(),
			snapshot = completeSnapshot(),
		})
	end)
	assert(not ok and tostring(problem) == "RESULT_DRAFT_ASSEMBLER_E_CONFIG", "mutable input must use config sentinel")
end

do
	local ok, problem = pcall(function()
		ResultDraftAssembler.assemble(deepFreeze({
			runId = RUN_ID,
			manifest = manifest(),
			snapshot = completeSnapshot(),
			extra = "TOP-SECRET",
		}))
	end)
	assert(not ok and tostring(problem) == "RESULT_DRAFT_ASSEMBLER_E_CONFIG", "bad call shape must use config sentinel")
end

print("PASS Relay.Benchmarks.ResultDraftAssembler")
