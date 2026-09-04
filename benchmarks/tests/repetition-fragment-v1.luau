local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local RepetitionFragmentV1 = require("../contracts/internal/RepetitionFragmentV1")

local BATCH_ID = "10213243-5465-7687-98a9-bacbdcedfe0f"
local LAUNCH_ID = "00112233-4455-6677-8899-aabbccddeeff"

local function deepClone(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] ~= nil then return seen[value] end
	local copied = {}
	seen[value] = copied
	for key, nested in value do copied[deepClone(key, seen)] = deepClone(nested, seen) end
	return copied
end

local function assertDeepFrozen(value, seen)
	if type(value) ~= "table" then return end
	seen = seen or {}
	if seen[value] then return end
	seen[value] = true
	assert(table.isfrozen(value), "validated fragment output must be deeply frozen")
	for key, nested in value do
		assertDeepFrozen(key, seen)
		assertDeepFrozen(nested, seen)
	end
end

local function identity(isolation)
	return {
		id = "fragment-adapter",
		displayName = "Fragment Adapter",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "fragment-library",
			displayName = "Fragment Library",
			version = "1.0.0",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/fragment",
				revision = string.rep("a", 40),
				checksum = "sha256:" .. string.rep("b", 64),
				license = "MIT",
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = isolation,
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function manifest(isolation)
	local candidate = {
		version = 1,
		launchId = LAUNCH_ID,
		benchmarkSource = {
			revision = string.rep("c", 40),
			dirty = false,
			placeFingerprint = "sha256:" .. string.rep("e", 64),
		},
		contractFingerprint = "sha256:" .. string.rep("d", 64),
		adapter = {
			moduleId = "fragment-adapter",
			artifact = { kind = "RepositoryModule", digest = "sha256:" .. string.rep("b", 64) },
			identity = identity(isolation or "ProcessRestart"),
		},
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		environment = {
			studio = { version = "0.650.0.6500000", channel = "production" },
			host = {
				osFamily = "Windows",
				architecture = "x86_64",
				logicalProcessorCount = 8,
				memoryMiB = 16_384,
			},
		},
	}
	local checked = HostManifestV1.validate(candidate)
	assert(checked.kind == "Valid", "fragment manifest fixture must validate")
	return checked.value
end

local function values(count, value)
	local output = table.create(count)
	for index = 1, count do output[index] = value end
	return output
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

local function candidate()
	return {
		schema = "RelayRepetitionFragmentV1",
		batchId = BATCH_ID,
		repetitionIndex = 7,
		manifest = manifest(),
		coordinator = {
			started = true,
			completed = true,
			finalOnlyEvidence = false,
			failureFacts = {},
		},
		participants = {
			{
				participant = { role = "Server" },
				evidence = {
					version = 1,
					repetitions = { {
						repetitionIndex = 7,
						started = true,
						completed = true,
						submitted = 0,
						received = 120,
						correct = 120,
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
					} },
					measurements = {},
					timingEndpoints = { {
						repetitionIndex = 7,
						finalExpectedDeliveryReceivedSharedSeconds = 71.5,
						finalExpectedDeliveryVerifiedSharedSeconds = 72,
					} },
					failureFacts = {},
					conformance = conformance(),
				},
			},
			{
				participant = { role = "Client", index = 1 },
				evidence = {
					version = 1,
					repetitions = { {
						repetitionIndex = 7,
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
						firstSubmissionStartedSharedSeconds = 70,
						finalSubmissionReturnedSharedSeconds = 71,
					} },
					measurements = {
						{ measurementIndex = 4, repetitionIndex = 7, values = values(120, 16) },
						{ measurementIndex = 5, repetitionIndex = 7, values = { 1 } },
						{ measurementIndex = 10, repetitionIndex = 7, values = values(120, 10) },
					},
					failureFacts = {},
					conformance = conformance(),
				},
			},
		},
	}
end

local function preStartCandidate()
	local input = candidate()
	input.coordinator.started = false
	input.coordinator.completed = false
	input.coordinator.failureFacts = { { code = "SetupFailure", occurrences = 1 } }
	for _, participant in input.participants do
		local repetition = participant.evidence.repetitions[1]
		repetition.started = false
		repetition.completed = false
		for key, value in repetition do
			if type(value) == "number" and key ~= "repetitionIndex" then repetition[key] = 0 end
		end
		repetition.observationOverflow = false
		repetition.firstSubmissionStartedSharedSeconds = nil
		repetition.finalSubmissionReturnedSharedSeconds = nil
		repetition.finalExpectedDeliveryReceivedSharedSeconds = nil
		repetition.finalExpectedDeliveryVerifiedSharedSeconds = nil
		participant.evidence.measurements = {}
		participant.evidence.failureFacts = {}
	end
	input.participants[1].evidence.timingEndpoints = {}
	return input
end

assert(table.isfrozen(RepetitionFragmentV1), "fragment contract module must be frozen")
assert(RepetitionFragmentV1.MAX_JSON_BYTES == 1_048_576, "fragment JSON byte limit differs")

do
	local input = candidate()
	local checked = RepetitionFragmentV1.validate(input)
	assert(checked.kind == "Valid", "complete fragment must validate")
	assertDeepFrozen(checked)
	input.coordinator.started = false
	input.participants[2].evidence.measurements[1].values[1] = 999
	assert(checked.value.coordinator.started, "validated fragment must be detached from input")
	assert(checked.value.participants[2].evidence.measurements[1].values[1] == 16,
		"validated measurement must be detached from input")
end

do
	local checked = RepetitionFragmentV1.validate(preStartCandidate())
	assert(checked.kind == "Valid", "pre-start failure fragment with no server endpoint must validate")
	assert(#checked.value.participants[1].evidence.timingEndpoints == 0,
		"pre-start fragment must retain zero server endpoints")
end

local function assertInvalid(input, label)
	local checked = RepetitionFragmentV1.validate(input)
	assert(checked.kind == "Invalid", label)
	assertDeepFrozen(checked)
end

do
	local input = candidate()
	input.manifest = manifest("SessionRestart")
	assertInvalid(input, "SessionRestart fragment must be rejected")
end

do
	local input = candidate()
	input.batchId = LAUNCH_ID
	assertInvalid(input, "batch identity reused as child launch identity must be rejected")
end

do
	local input = candidate()
	input.participants[1].evidence.repetitions[1].repetitionIndex = 1
	assertInvalid(input, "non-global repetition evidence must be rejected")
end

do
	local input = candidate()
	table.remove(input.participants[2].evidence.measurements, 3)
	assertInvalid(input, "completed fragment missing required measurement must be rejected")
end

do
	local input = candidate()
	input.participants[3] = deepClone(input.participants[2])
	assertInvalid(input, "wrong participant cardinality must be rejected")
end

do
	local input = candidate()
	input.participants[2].evidence.conformance = input.participants[1].evidence.conformance
	assertInvalid(input, "aliased hostile input must be rejected")
end

do
	local input = candidate()
	input.loop = input
	assertInvalid(input, "cyclic hostile input must be rejected")
end

do
	local input = candidate()
	local nested = input
	for _ = 1, 11 do
		local nextValue = {}
		nested.depth = nextValue
		nested = nextValue
	end
	assertInvalid(input, "over-depth hostile input must be rejected")
end

print("PASS Relay.Benchmarks.RepetitionFragmentV1")
