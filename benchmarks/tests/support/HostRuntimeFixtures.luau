local Contract = require("../../contracts/event-v1")
local HostManifestV1 = require("../../contracts/internal/HostManifestV1")
local ResultV1 = require("../../contracts/result-v1")

local STUDIO_VERSION = "0.650.0.6500000"
local LAUNCH_ID = "00112233-4455-4677-8899-aabbccddeeff"
local MAXIMUM_WIDTH_FINITE_SAMPLE = 2.2250738585072014e-308

local function identity()
	return {
		id = "engine-adapter",
		displayName = "Engine Adapter",
		lane = "NativeBest",
		integrationKind = "EngineBuiltIn",
		library = {
			id = "engine-library",
			displayName = "Engine Library",
			version = STUDIO_VERSION,
			provenance = { kind = "EngineBuiltIn", studioVersion = STUDIO_VERSION },
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

local function manifest()
	local candidate = {
		version = 1,
		launchId = LAUNCH_ID,
		benchmarkSource = { revision = string.rep("a", 40), dirty = false },
		contractFingerprint = "sha256:" .. string.rep("b", 64),
		adapter = {
			moduleId = "engine-adapter-module",
			artifact = { kind = "EngineBuiltIn" },
			identity = identity(),
		},
		selection = { kind = "Workload", workloadId = "state-burst-c2s", recipientCount = 1 },
		environment = {
			studio = { version = STUDIO_VERSION, channel = "production" },
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
	assert(checked.kind == "Valid", "host fixture manifest must validate")
	return checked.value
end

local function selectedMeasurements()
	local selected = {}
	for _, measurement in Contract.measurements do
		if measurement.scope == "Workload" then table.insert(selected, measurement) end
	end
	return selected
end

local function valuesPerRepetition(measurement, workload)
	local cadence = measurement.capture.cadence
	if cadence == "PerMeasuredFrame" then return workload.measuredFrames end
	if cadence == "PerRepetition" then return 1 end
	if cadence == "PerSubmission" then return workload.measuredFrames * workload.messagesPerFrame end
	error(`unexpected workload cadence {tostring(cadence)}`, 0)
end

local function measurements(workload)
	local output = {}
	for _, measurement in selectedMeasurements() do
		local rawSamples = table.create(workload.repetitions)
		local valueCount = valuesPerRepetition(measurement, workload)
		for repetitionIndex = 1, workload.repetitions do
			local value = if measurement.id == "submitted" or measurement.id == "received" or measurement.id == "correct"
				then workload.measuredFrames * workload.messagesPerFrame
				elseif measurement.summary == "Exact" then 1
				else MAXIMUM_WIDTH_FINITE_SAMPLE
			local values = table.create(valueCount, value)
			local group = { repetitionIndex = repetitionIndex, values = values }
			if measurement.capture.role == "Sender" then group.participantIndex = 1 end
			rawSamples[repetitionIndex] = group
		end
		table.insert(output, { id = measurement.id, state = "Available", rawSamples = rawSamples })
	end
	return output
end

local function maximum()
	local expectedManifest = manifest()
	local workload = Contract.workloads[3]
	assert(workload.id == "state-burst-c2s", "maximum host fixture workload drifted")
	local expected = workload.repetitions * workload.senderCount * workload.measuredFrames * workload.messagesPerFrame
	local draft = {
		runId = expectedManifest.launchId,
		benchmarkSource = expectedManifest.benchmarkSource,
		contractFingerprint = expectedManifest.contractFingerprint,
		adapter = expectedManifest.adapter.identity,
		case = {
			kind = "Workload",
			workloadId = workload.id,
			senderCount = workload.senderCount,
			recipientCount = 1,
			scheduledRepetitions = workload.repetitions,
			startedRepetitions = workload.repetitions,
			completedRepetitions = workload.repetitions,
		},
		failures = {},
		counts = {
			finality = "Final",
			expectedSubmissions = expected,
			submitted = expected,
			expectedDeliveries = expected,
			received = expected,
			correct = expected,
			missing = 0,
			duplicate = 0,
			unexpected = 0,
			outOfOrder = 0,
			mismatch = 0,
		},
		conformance = {
			timingExclusionsConfirmed = {
				setup = true,
				warmup = true,
				quiescence = true,
				resultExtraction = true,
			},
			localClock = Contract.clocks.localDuration,
			sharedClock = Contract.clocks.shared,
			clockProof = { version = 1, passed = true },
		},
		measurements = measurements(workload),
		environment = {
			studio = expectedManifest.environment.studio,
			host = expectedManifest.environment.host,
			execution = {
				mode = "StudioMultiplayer",
				targetFrameRate = Contract.execution.targetFrameRate,
				serverCount = 1,
				clientCount = 1,
			},
		},
	}
	local result = ResultV1.finalize(draft)
	local rawValues = 0
	for _, measurement in result.measurements do
		if measurement.rawSamples ~= nil then
			for _, group in measurement.rawSamples do rawValues += #group.values end
		end
	end
	assert(rawValues == 60_870, "host fixture must retain maximum Result V1 raw workload")
	return expectedManifest, result
end

return table.freeze({ maximum = maximum })
