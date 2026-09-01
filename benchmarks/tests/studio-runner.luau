local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local AdapterIdentity = require("../contracts/internal/AdapterIdentity")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local StudioProofReports = require("./support/StudioProofReports")

local STUDIO_VERSION = "0.650.0.6500000"

local function assertExactKeys(value, expectedKeys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local expected = {}
	for _, key in expectedKeys do expected[key] = true end
	local count = 0
	for key in value do
		count += 1
		assert(type(key) == "string" and expected[key] == true, `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #expectedKeys, `{label} key count differs`)
end

local function assertContains(source, needle, label)
	assert(string.find(source, needle, 1, true) ~= nil, `{label} is missing`)
end

local function assertNotContains(source, needle, label)
	assert(string.find(source, needle, 1, true) == nil, `{label} must be absent`)
end

local function countPlain(source, needle)
	local count = 0
	local cursor = 1
	while true do
		local found = string.find(source, needle, cursor, true)
		if found == nil then return count end
		count += 1
		cursor = found + #needle
	end
end

local function normalize(source)
	return string.gsub(source, "\r\n", "\n")
end

local function between(source, firstNeedle, lastNeedle, label)
	local first = assert(string.find(source, firstNeedle, 1, true), `{label} start is missing`)
	local last = assert(string.find(source, lastNeedle, first + #firstNeedle, true), `{label} end is missing`)
	return string.sub(source, first, last - 1)
end

local function assertOrdered(source, needles, label)
	local cursor = 1
	for index, needle in needles do
		local found = assert(string.find(source, needle, cursor, true), `{label} step {index} is missing`)
		cursor = found + #needle
	end
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, child in value do copied[clone(key)] = clone(child) end
	return copied
end

local function nativeBinding(studioVersion)
	return {
		moduleId = "native-reliable",
		artifact = { kind = "EngineBuiltIn" },
		identity = {
			id = "native-reliable",
			displayName = "Roblox RemoteEvent",
			lane = "EquivalentSemantics",
			integrationKind = "EngineBuiltIn",
			library = {
				id = "roblox-remote-event",
				displayName = "Roblox RemoteEvent",
				version = studioVersion,
				provenance = { kind = "EngineBuiltIn", studioVersion = studioVersion },
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
		},
	}
end

assert(StudioProofReports.SENTINEL == "RelayStudioControlProofV1")
assert(StudioProofReports.FAILURE_SENTINEL == "RelayStudioControlProofFailureV1")
assert(StudioProofReports.listenerReady == "RelayStudioControlListenerReadyV1")
assert(StudioProofReports.controlQuietComplete == "RelayStudioControlQuietCompleteV1")
assert(StudioProofReports.measuredQuietComplete == "RelayStudioMeasuredQuietCompleteV1")
assert(StudioProofReports.measuredQuietRelease == "RelayStudioMeasuredQuietReleaseV1")
assert(table.isfrozen(StudioProofReports))
assert(table.isfrozen(StudioProofReports.bound))
assert(table.isfrozen(StudioProofReports.ready))
assert(table.isfrozen(StudioProofReports.warmup))
assert(table.isfrozen(StudioProofReports.repetition))

-- The server allowlist accepts only the exact host-validated native binding and loads lazily once.
local allowlistSource = normalize(fs.readFile("benchmarks/runner/AdapterAllowlist.luau"))
luau.compile(allowlistSource)
do
	local nativeModule = {}
	local nativeFactory = table.freeze({})
	local requireCalls = 0
	local replicatedStorage = {
		RelayBenchmark = {
			adapters = {
				NativeReliable = nativeModule,
			},
		},
	}
	local chunk = luau.load(allowlistSource, {
		debugName = "AdapterAllowlist",
		environment = {
			game = {
				GetService = function(_, serviceName)
					assert(serviceName == "ReplicatedStorage", "allowlist requested an unexpected service")
					return replicatedStorage
				end,
			},
			version = function() return STUDIO_VERSION end,
			require = function(candidate)
				assert(candidate == nativeModule, "allowlist required an unexpected module")
				requireCalls += 1
				return nativeFactory
			end,
		},
	})
	local allowlist = chunk()
	assertExactKeys(allowlist, { "resolve" }, "AdapterAllowlist")
	assert(table.isfrozen(allowlist), "AdapterAllowlist must be frozen")

	for _, rejected in {
		allowlist.resolve(),
		allowlist.resolve("native-reliable"),
		allowlist.resolve({}),
		allowlist.resolve({ identity = { library = { version = STUDIO_VERSION } } }),
		allowlist.resolve(nativeBinding(STUDIO_VERSION), "extra"),
	} do
		assert(rejected.kind == "Rejected" and table.isfrozen(rejected), "malformed binding must be rejected")
	end
	assert(requireCalls == 0, "rejected bindings must not load adapter code")

	local extra = nativeBinding(STUDIO_VERSION)
	extra.identity.extra = true
	assert(allowlist.resolve(extra).kind == "Rejected", "extra identity fields must be rejected")
	local wrongVersion = nativeBinding(STUDIO_VERSION)
	wrongVersion.identity.library.version = "0.650.0.1"
	assert(allowlist.resolve(wrongVersion).kind == "Rejected", "wrong Studio version must be rejected")
	local wrongPayloads = nativeBinding(STUDIO_VERSION)
	wrongPayloads.identity.capabilities.payloadIds = { "state" }
	assert(allowlist.resolve(wrongPayloads).kind == "Rejected", "partial capabilities must be rejected")
	local metatableBinding = nativeBinding(STUDIO_VERSION)
	setmetatable(metatableBinding.identity.library, {})
	assert(allowlist.resolve(metatableBinding).kind == "Rejected", "metatable-bearing bindings must be rejected")

	local resolved = allowlist.resolve(nativeBinding(STUDIO_VERSION))
	assertExactKeys(resolved, { "kind", "moduleId", "factory" }, "resolved native adapter")
	assert(resolved.kind == "Resolved" and resolved.moduleId == "native-reliable")
	assert(resolved.factory == nativeFactory and table.isfrozen(resolved), "resolved factory differs")
	assert(allowlist.resolve(nativeBinding(STUDIO_VERSION)) == resolved, "resolved adapter must be cached")
	assert(requireCalls == 1, "native adapter must load exactly once")
end

-- Every approved Benchmark case is represented by a valid native manifest and exact client topology.
local function manifestFor(selection)
	return {
		version = 1,
		launchId = "00112233-4455-6677-8899-aabbccddeeff",
		benchmarkSource = {
			revision = string.rep("a", 40),
			dirty = false,
			placeFingerprint = "sha256:" .. string.rep("c", 64),
		},
		contractFingerprint = "sha256:" .. string.rep("b", 64),
		adapter = nativeBinding(STUDIO_VERSION),
		selection = selection,
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
end

local benchmarkCases = {
	{ id = "tiny-steady-c2s", selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 }, clients = 1 },
	{ id = "state-steady-c2s", selection = { kind = "Workload", workloadId = "state-steady-c2s", recipientCount = 1 }, clients = 1 },
	{ id = "state-burst-c2s", selection = { kind = "Workload", workloadId = "state-burst-c2s", recipientCount = 1 }, clients = 1 },
	{ id = "state-broadcast-s2c-1", selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 1 }, clients = 1 },
	{ id = "state-broadcast-s2c-4", selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 4 }, clients = 4 },
	{ id = "state-broadcast-s2c-8", selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 8 }, clients = 8 },
	{ id = "tiny-round-trip", selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" }, clients = 1 },
}
assert(#benchmarkCases == 7, "Benchmark case matrix must contain exactly seven entries")
for _, case in benchmarkCases do
	local checked = HostManifestV1.validate(manifestFor(clone(case.selection)))
	assert(checked.kind == "Valid", `{case.id} native manifest must validate`)
	local resolvedSelection = AdapterIdentity.resolveSelection(checked.value.selection)
	assert(resolvedSelection.kind == "Valid", `{case.id} validated selection must resolve`)
	assert(resolvedSelection.value.clientProcessCount == case.clients, `{case.id} client topology differs`)
	assert(checked.value.adapter.moduleId == "native-reliable", `{case.id} adapter binding differs`)
	if case.selection.kind == "Workload" then
		assert(checked.value.selection.workloadId == case.selection.workloadId, `{case.id} workload changed`)
		assert(checked.value.selection.recipientCount == case.selection.recipientCount, `{case.id} recipients changed`)
	else
		assert(checked.value.selection.probeId == case.selection.probeId, `{case.id} probe changed`)
	end
end

-- The place exposes every dependency required by distributed Benchmark execution to both sides.
local project = serde.decode("json", fs.readFile("benchmarks/event-v1.project.json"))
local relay = project.tree.ReplicatedStorage.RelayBenchmark
assert(project.tree.HttpService["$properties"].HttpEnabled == true)
assertExactKeys(relay, { "$className", "contracts", "correctness", "fixtures", "Runner", "adapters", "Runtime" }, "RelayBenchmark mapping")
assert(relay.correctness["$path"] == "correctness" and relay.Correctness == nil, "correctness mapping must match relative requires")
assertExactKeys(relay.Runtime, { "$className", "ControlCases", "AdapterGenerations" }, "Runtime mapping")
assert(relay.Runtime.ControlCases["$className"] == "Folder")
assert(relay.Runtime.AdapterGenerations["$className"] == "Folder")
assertExactKeys(relay.adapters, { "$className", "AdapterContract", "NativeReliable" }, "adapter mapping")
assert(relay.adapters.AdapterContract["$path"] == "adapters/AdapterContract.luau")
assert(relay.adapters.NativeReliable["$path"] == "adapters/native-reliable")

local runnerPaths = {
	BenchmarkClock = "runner/BenchmarkClock.luau",
	CaseRunner = "runner/CaseRunner.luau",
	ControlProtocol = "runner/ControlProtocol.luau",
	DeliveryRouter = "runner/DeliveryRouter.luau",
	GenerationActivation = "runner/GenerationActivation.luau",
	KernelFanout = "runner/KernelFanout.luau",
	ResultDraftAssembler = "runner/ResultDraftAssembler.luau",
	RunState = "runner/RunState.luau",
	RunnerKernel = "runner/RunnerKernel.luau",
	SessionOwner = "runner/SessionOwner.luau",
	StudioBenchmarkClock = "runner/StudioBenchmarkClock.luau",
	StudioProofReports = "tests/support/StudioProofReports.luau",
	TimingRecorder = "runner/TimingRecorder.luau",
}
local runnerKeys = { "$className" }
for name, path in runnerPaths do
	table.insert(runnerKeys, name)
	assert(relay.Runner[name]["$path"] == path, `{name} mapping differs`)
	luau.compile(fs.readFile("benchmarks/" .. path))
end
assertExactKeys(relay.Runner, runnerKeys, "Runner mapping")
assert(project.tree.ServerStorage.RelayBenchmarkServer.AdapterAllowlist["$path"] == "runner/AdapterAllowlist.luau")
assert(project.tree.ServerScriptService.RelayBenchmarkCoordinator["$path"] == "runner/Coordinator.server.luau")
assert(project.tree.StarterPlayer.StarterPlayerScripts.RelayBenchmarkParticipant["$path"] == "runner/Participant.client.luau")

local coordinator = normalize(fs.readFile("benchmarks/runner/Coordinator.server.luau"))
local participant = normalize(fs.readFile("benchmarks/runner/Participant.client.luau"))
local nativeAdapter = normalize(fs.readFile("benchmarks/adapters/native-reliable/init.luau"))
local clock = normalize(fs.readFile("benchmarks/runner/StudioBenchmarkClock.luau"))
luau.compile(coordinator)
luau.compile(participant)
luau.compile(nativeAdapter)
assertContains(clock, "Workspace:GetServerTimeNow()", "shared Studio clock")
assertContains(clock, "localNowSeconds = os.clock", "local Studio clock")
assertContains(clock, "timeoutNowSeconds = os.clock", "timeout Studio clock")

-- Native roster validation and endpoint discovery complete before measured operations begin.
local readyRegion = between(nativeAdapter, "\tlocal function exactRoster()", "\tlocal function operationEndpoint", "native readiness")
local operationRegion = between(nativeAdapter, "\tlocal function operationEndpoint", "\tlocal function teardown", "native operation endpoint")
assert(countPlain(nativeAdapter, "Players:GetPlayers()") == 1, "native roster must be read exactly once in readiness code")
assertContains(readyRegion, "not exactRoster()", "server readiness roster proof")
assertNotContains(operationRegion, "Players:GetPlayers()", "timed operation roster scan")
assertNotContains(operationRegion, ".Parent", "timed operation hierarchy scan")
assertContains(nativeAdapter, "remote:FireAllClients(", "native broadcast")
assertContains(nativeAdapter, "remote:FireServer(", "native submit")

local controlProof = between(coordinator, "local function runControlProof", "local function runBenchmark", "ControlProof")
local benchmark = between(coordinator, "local function runBenchmark", "task.spawn(function()", "Benchmark")
local participantBenchmarkStart = assert(
	(string.find(participant, "runBenchmarkCase = function", 1, true)),
	"Benchmark participant is missing"
)
local benchmarkParticipant = string.sub(participant, participantBenchmarkStart)

-- ControlProof remains a distinct scalar path and never resolves or loads an executable adapter.
assertContains(controlProof, "HostManifestV1.validate(candidate)", "ControlProof manifest validation")
assertNotContains(controlProof, "AdapterAllowlist", "ControlProof adapter admission")
assertContains(controlProof, "ControlProtocol.newCoordinator", "ControlProof coordinator")
assertContains(controlProof, "StudioProofReports.controlQuietComplete", "ControlProof control quiet signal")
assertContains(controlProof, "StudioProofReports.measuredQuietComplete", "ControlProof measured quiet signal")
assertContains(controlProof, "coordinator.beginPostTeardownObservation", "ControlProof teardown observation")
assertContains(controlProof, "finish(StudioProofReports.SENTINEL)", "ControlProof completion")
assertContains(coordinator, "if mode == \"ControlProof\" then", "ControlProof mode branch")

-- Benchmark derives the case and topology solely from the validated manifest.
assertContains(benchmark, "local selection = manifest.selection", "manifest selection")
assertContains(benchmark, "local caseId = if selection.kind == \"Workload\" then selection.workloadId else selection.probeId", "manifest case id")
local hasManifestTopologyResolution = string.find(
	benchmark,
	"AdapterIdentity.resolveSelection(selection)",
	1,
	true
) ~= nil
assertContains(benchmark, "resolvedSelection.clientProcessCount ~= expected", "manifest client topology")
assertContains(benchmark, "resolvedSelection.kind == \"Workload\" and resolvedSelection.recipientCount ~= expected", "manifest recipient topology")
assertContains(benchmark, "AdapterAllowlist.resolve(manifest.adapter)", "full adapter binding")
assertContains(benchmark, "SessionOwner.prepareCoordinator(manifest, manifest.adapter.identity", "prepared manifest ownership")
assertContains(benchmark, "created:SetAttribute(\"CaseId\", caseId)", "distributed case id")
assertNotContains(benchmark, "CASE_ID", "ControlProof case constant in Benchmark")
assertContains(benchmarkParticipant, "if caseId == \"tiny-round-trip\" then", "probe selection")
assertContains(benchmarkParticipant, "return { kind = \"Workload\", workloadId = caseId, recipientCount = recipientCount }", "workload selection")
assertContains(benchmarkParticipant, "AdapterContract.preflight(canonicalIdentity(version()), candidateSelection, version())", "client native preflight")
assertContains(benchmarkParticipant, "nativeFactory = require(adapters:WaitForChild(\"NativeReliable\"))", "client native adapter")
assertContains(benchmarkParticipant, "SessionOwner.openClient(", "client generation opening")
assertNotContains(benchmarkParticipant, "FakeAdapter", "test adapter in Studio Benchmark")
assertContains(benchmarkParticipant, "string.format(\"%s-r%02d\", caseFolder.Name, repetitionIndex)", "deterministic client generation name")
assertContains(benchmarkParticipant, "child:GetAttribute(\"RepetitionIndex\") ~= repetitionIndex", "replicated generation identity")
assertNotContains(benchmark, "created:SetAttribute(\"GenerationName\"", "dynamic generation-name replication gate")
assertNotContains(benchmark, "created:SetAttribute(\"RepetitionIndex\"", "dynamic repetition replication gate")
assertContains(benchmarkParticipant, "caseDefinition.direction == \"ClientToServer\"", "sender-only warmup mutation claim")
assertContains(benchmarkParticipant, "else \"Dirty\"", "receiver warmup abort disposition")

-- Quiet reports are bound to the open repetition and accepted once per participant.
assertContains(benchmark, "scalarRepetition ~= currentRepetition or not open", "server repetition-bound scalar gate")
assertContains(benchmark, "not warmupReported[index]", "control quiet requires the participant warmup report")
assertContains(benchmark, "or index == nil or target[index]", "server one-report gate")
assertContains(benchmark, "table.clear(controlQuietComplete)", "server control quiet reset")
assertContains(benchmark, "table.clear(measuredComplete)", "server measured quiet reset")
assertContains(benchmark, "quietFrames == 60", "server 60-frame quiet proof")
assertContains(benchmark, "and allReported(controlQuietComplete)", "server control quiet roster proof")
assertContains(benchmark, "serverReady and allReported(measuredComplete)", "server measured quiet roster proof")
assertContains(benchmarkParticipant, "control:FireServer(kind, repetitionIndex)", "client repetition-bound scalar report")
assertOrdered(benchmarkParticipant, {
	"currentRepetition += 1",
	"controlQuietSent = false",
	"measuredQuietSent = false",
	"teardownCompleteSent = false",
}, "client repetition reset")
assertContains(benchmarkParticipant, "current.phase == \"ControlQuiet\" and current.quietFrames == 60", "client control quiet proof")
assertContains(benchmarkParticipant, "current.phase == \"Verified\" and current.quietFrames == 60", "client measured quiet proof")
local repetitionStartup = between(
	benchmark,
	"\t\tcaseState.clearDeadline(\"Readiness\")",
	"\t\tlocal serverWarmupInputMutation",
	"server repetition startup"
)
assertOrdered(repetitionStartup, {
	"kind = \"ClockChallenge\"",
	"waitBarrier()",
	"activeActivation.arm()",
	"serverTiming.recordClockProof",
	"table.clear(warmupReported)",
	"controlQuietOpen = true",
	"activeKernel.command({ kind = \"BeginWarmup\" })",
	"startBarrier(\"WarmupReport\"",
}, "clock proof, arm, and warmup ordering")
assertNotContains(benchmark, "kind = \"MeasuredStarted\"", "duplicate coordinator measured-start transition")
assertNotContains(benchmark, "caseState.startDeadline(\"Delivery\")", "coordinator-owned C2S delivery deadline")

-- Teardown closes delivery first, removes the generation root, observes one later frame, then reports.
local serverTeardown = between(benchmark, "\t\tlocal postBoundary = coordinator.beginPostTeardownObservation", "\t\tlocal repetitionOutcome", "server repetition teardown")
assertOrdered(serverTeardown, {
	"coordinator.beginPostTeardownObservation",
	"activeKernel.beginTeardownObservation()",
	"BENCHMARK_BEGIN_TEARDOWN",
	"allReported(teardownReady)",
	"activeKernel.teardown()",
	"activeOpen.closeGenerationRoot()",
	"BENCHMARK_ROOT_REMOVED",
	"closedRoot.Parent == nil",
	"activeKernel.finishTeardownObservation()",
	"waitBarrier()",
}, "server teardown/root observation")
local clientTeardown = between(benchmarkParticipant, "\tlocal function beginClientTeardown", "\tlocal function finishRootObservation", "client teardown")
assertOrdered(clientTeardown, {
	"participant.beginPostTeardownObservation",
	"activeKernel.beginTeardownObservation",
	"activeKernel.teardown()",
	"awaitingRootRemoval = true",
	"sendScalar(BENCHMARK_TEARDOWN_COMPLETE, repetitionIndex)",
}, "client teardown")
local clientRootObservation = between(benchmarkParticipant, "\tlocal function finishRootObservation", "\tlocal function reportSetupFailure", "client root observation")
assertOrdered(clientRootObservation, {
	"observedRoot.Parent ~= nil",
	"local isolationPassed = observedRoot.Parent == nil",
	"RunService.PostSimulation:Wait()",
	"activeKernel.finishTeardownObservation",
	"activeRoot = nil",
	"kind = \"RepetitionReport\"",
}, "client root observation")

-- Final reports merge into one validated Result; failures remain bounded terminations; EndTest is unique.
local finalizationStart = assert(
	(string.find(benchmark, "\tlocal caseStatus = caseState.status()", 1, true)),
	"final Result assembly start is missing"
)
local finalization = string.sub(benchmark, finalizationStart)
assertOrdered(finalization, {
	"coordinator.beginFinalReports",
	"kind = \"FinishCase\"",
	"waitBarrier()",
	"serverState.freeze()",
	"caseState.snapshot(participantSnapshots)",
	"table.freeze(assemblyInput)",
	"ResultDraftAssembler.assemble",
	"ResultV1.finalize",
	"return ResultV1.validate(finalized)",
}, "final Result assembly")
assert(countPlain(coordinator, "StudioTestService:EndTest(") == 1, "Coordinator must own exactly one EndTest call site")
assertContains(coordinator, "local finalValue = if cleanup() then value else", "cleanup result precedence")
assertContains(coordinator, "local ok, value = pcall(runBenchmark, launchId, expected)", "Benchmark result capture")
assertContains(coordinator, "pcall(HarnessTerminationV1.validate, value)", "bounded termination validation")
assertContains(coordinator, "HarnessTerminationV1.new(\"FinalizationFailure\", \"Finalize\")", "unknown failure bounding")
assertContains(coordinator, "HarnessTerminationV1.new(\"CleanupFailure\", \"Finalize\")", "cleanup failure bounding")
assertContains(coordinator, "local HttpService = game:GetService(\"HttpService\")", "Benchmark JSON service")
assertContains(coordinator, "local function encodeBenchmarkTerminal(candidate: any): string", "Benchmark JSON boundary")
assertContains(coordinator, "return HttpService:JSONEncode(candidate)", "Benchmark terminal JSON encoding")
assertContains(coordinator,
	"{\\\"kind\\\":\\\"RelayHarnessTerminationV1\\\",\\\"code\\\":\\\"FinalizationFailure\\\",\\\"stage\\\":\\\"Finalize\\\"}",
	"fixed FinalizationFailure JSON envelope")
assertContains(coordinator, "then validated[2]", "canonical thrown termination")
assertOrdered(coordinator, {
	"local cleanupFailureJson = encodeBenchmarkTerminal(cleanupFailure)",
	"local encodedValue = encodeBenchmarkTerminal(terminalValue)",
	"finish(encodedValue, cleanupFailureJson)",
}, "Benchmark JSON EndTest boundary")
assertContains(coordinator, "return FIXED_FINALIZATION_FAILURE_JSON", "fixed JSON encoding fallback")
assertNotContains(coordinator, "finish(value, cleanupFailure)", "raw Benchmark terminal table")
assert(hasManifestTopologyResolution, "manifest client topology resolution is missing")

print("PASS Relay.Benchmarks.StudioRunner")
