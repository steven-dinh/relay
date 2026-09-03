local AdapterContract = require("../adapters/AdapterContract")
local EventV1 = require("../contracts/event-v1")
local ResultV1 = require("../contracts/result-v1")
local Fixtures = require("../fixtures/event-v1")
local BenchmarkClock = require("../runner/BenchmarkClock")
local ControlProtocol = require("../runner/ControlProtocol")
local DeliveryRouter = require("../runner/DeliveryRouter")
local ResultDraftAssembler = require("../runner/ResultDraftAssembler")
local RunState = require("../runner/RunState")
local RunnerKernel = require("../runner/RunnerKernel")
local SessionOwner = require("../runner/SessionOwner")
local TimingRecorder = require("../runner/TimingRecorder")

local STUDIO_VERSION = "0.650.0.6500000"

local function assertExactKeys(value, keys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local expected = {}
	for _, key in keys do expected[key] = true end
	local count = 0
	for key in next, value do
		count += 1
		assert(expected[key] == true, `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #keys, `{label} must have exactly {#keys} keys`)
end

local function assertError(operation, expected, label)
	local ok, problem = pcall(operation)
	assert(not ok, `{label} must fail`)
	assert(tostring(problem) == expected, `{label} expected {expected}, got {tostring(problem)}`)
end

local function deepClone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, nested in next, value do copied[key] = deepClone(nested) end
	return copied
end

local function deepFreeze(value)
	if type(value) ~= "table" or table.isfrozen(value) then return end
	for _, nested in next, value do deepFreeze(nested) end
	table.freeze(value)
end

local function identity()
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

local function manifest(adapterIdentity, requestedSelection)
	return {
		version = 1,
		launchId = "00112233-4455-6677-8899-aabbccddeeff",
		benchmarkSource = {
			revision = string.rep("a", 40),
			dirty = false,
			placeFingerprint = "sha256:" .. string.rep("c", 64),
		},
		contractFingerprint = "sha256:" .. string.rep("b", 64),
		adapter = {
			moduleId = "repo-adapter-module",
			artifact = {
				kind = "RepositoryModule",
				digest = adapterIdentity.library.provenance.checksum,
			},
			identity = adapterIdentity,
		},
		selection = requestedSelection or {
			kind = "Workload",
			workloadId = "tiny-steady-c2s",
			recipientCount = 1,
		},
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

local function constantProcess(value)
	return {
		clocks = {
			localNowSeconds = function() return value end,
			sharedNowSeconds = function() return value end,
			timeoutNowSeconds = function() return value end,
		},
		postSimulation = {
			connectPostSimulation = function()
				return function() end
			end,
		},
	}
end

local function prepared(requestedSelection)
	local adapterIdentity = identity()
	local server = constantProcess(0)
	local clientCount = if requestedSelection ~= nil and requestedSelection.kind == "Workload"
		then requestedSelection.recipientCount
		else 1
	local clientTokens = table.create(clientCount)
	local clients = table.create(clientCount)
	for index = 1, clientCount do
		clientTokens[index] = `client-{index}`
		clients[index] = constantProcess(0)
	end
	server.clientTokens = clientTokens
	local result = SessionOwner.prepare(manifest(adapterIdentity, requestedSelection), adapterIdentity, {
		server = server,
		clients = clients,
	})
	assert(result.kind == "Prepared", `test session must prepare: {result.kind}/{if result.kind == "Terminated" then result.termination.code else "none"}`)
	return result.value
end

local function timeoutClock(values)
	local index = 0
	return BenchmarkClock.new({
		localNowSeconds = function() return 0 end,
		sharedNowSeconds = function() return 0 end,
		timeoutNowSeconds = function()
			index += 1
			local value = values[index]
			if type(value) == "function" then return value() end
			return value
		end,
	})
end

local function participantSnapshots(serverEvidence, clientEvidence)
	return {
		{ participant = { role = "Server" }, evidence = serverEvidence },
		{ participant = { role = "Client", index = 1 }, evidence = clientEvidence },
	}
end

local function markFirstRepetitionStarted(evidence, server)
	local copied = deepClone(evidence)
	if copied.repetitions[1] == nil then
		copied.repetitions[1] = {
			repetitionIndex = 1,
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
	copied.repetitions[1].started = true
	if server then
		copied.timingEndpoints = { { repetitionIndex = 1 } }
	end
	deepFreeze(copied)
	return copied
end

assertExactKeys(RunState, { "newCase", "newParticipant" }, "RunState")
assert(table.isfrozen(RunState), "RunState must be frozen")

-- BenchmarkClock remains the only constructor/monotonicity guard used by
-- RunState, so this composition test keeps the boundary proof local.
assertError(function()
	BenchmarkClock.new({
		localNowSeconds = function() return 0 end,
		sharedNowSeconds = function() return 0 end,
	})
end, "BENCHMARK_CLOCK_E_CONFIG", "clock missing timeout reader")

do
	local clock = timeoutClock({ 2, 1 })
	local deadline = clock.startDeadline(1)
	assertError(deadline.check, "BENCHMARK_CLOCK_E_VALUE", "decreasing timeout clock")
end

local session = prepared()
assertError(function()
	RunState.newCase({
		manifest = session.manifest,
		selection = session.selection,
		caseDefinition = session.caseDefinition,
		runtimeInputs = session.runtimeInputs,
	}, timeoutClock({ 0 }))
end, "RUN_STATE_E_CONFIG", "unbranded prepared lookalike")

do
	local adapterIdentity = identity()
	local server = constantProcess(0)
	server.clientTokens = { "client-1" }
	local preparedCoordinator = SessionOwner.prepareCoordinator(manifest(adapterIdentity), adapterIdentity, server)
	assert(preparedCoordinator.kind == "Prepared", "coordinator case must prepare")
	local case = RunState.newCase(preparedCoordinator.value, timeoutClock({ 0 }))
	assert(case.selection == preparedCoordinator.value.selection, "coordinator must own the branded CaseState selection")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0, 10, 130, 140 }))
	assertExactKeys(case, {
		"selection", "caseDefinition", "acceptSession", "transition", "startDeadline",
		"checkDeadline", "clearDeadline", "recordFailure", "terminate", "status", "snapshot",
	}, "CaseState")
	assert(table.isfrozen(case), "CaseState must be frozen")
	local initial = case.status()
	assertExactKeys(initial, {
		"kind", "phase", "scheduledRepetitions", "startedRepetitions", "completedRepetitions",
	}, "initial CaseStatus")
	assert(initial.phase == "NotStarted" and initial.scheduledRepetitions == 30, "initial case progress differs")
	assert(case.startDeadline("Readiness").kind == "Active", "deadline start must be active")
	assert(case.checkDeadline("Readiness").kind == "Expired", "deadline equality must expire")
	assertError(function() case.clearDeadline("Readiness") end, "RUN_STATE_E_STATE", "clear expired deadline")
	assert(case.startDeadline("Readiness").kind == "Active", "expired generation deadline must be replaceable")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0, 10, 20 }))
	assert(case.startDeadline("Delivery").kind == "Active", "delivery deadline must start")
	assert(case.checkDeadline("Delivery").kind == "Active", "delivery deadline must remain active")
	case.clearDeadline("Delivery")
	assertError(function() case.checkDeadline("Delivery") end, "RUN_STATE_E_STATE", "check cleared deadline")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0, function() error("secret") end }))
	assert(case.startDeadline("Warmup").kind == "ClockFailed", "deadline reader failure must be sanitized")
end

do
	local case = RunState.newCase(session, timeoutClock({ function() error("secret") end }))
	assert(case.checkDeadline("Case").kind == "ClockFailed", "case deadline construction failure must persist")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local serverState = RunState.newParticipant(session.selection, { role = "Server" })
	local clientState = RunState.newParticipant(session.selection, { role = "Client", index = 1 })
	local serverEvidence = serverState.freeze()
	local clientEvidence = clientState.freeze()
	assert(serverEvidence.kind == "Evidence" and clientEvidence.kind == "Evidence", "empty participant evidence must freeze")
	local result = case.snapshot({
		{ participant = { role = "Server" }, evidence = serverEvidence.value },
		{ participant = { role = "Client", index = 1 }, evidence = clientEvidence.value },
	})
	assertExactKeys(result, { "kind", "value" }, "case snapshot result")
	assert(result.kind == "Snapshot", "not-started case must snapshot")
	assertExactKeys(result.value, { "version", "selection", "coordinator", "participants" }, "CaseSnapshot")
	assert(result.value.version == 1 and table.isfrozen(result.value), "CaseSnapshot must be frozen V1")
	assert(result.value.coordinator.startedRepetitions == 0 and result.value.coordinator.completedRepetitions == 0, "not-started progress differs")
	assert(#result.value.participants == 2, "snapshot topology differs")
	assert(result.value.participants[1].evidence ~= serverEvidence, "snapshot must detach participant evidence")
	assert(result.value.participants[2].evidence ~= clientEvidence, "snapshot must detach client evidence")
end

-- Aborted snapshots are representable only when at least one retained fact
-- explains the abort. Both coordinator- and participant-owned facts qualify.
do
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	assertError(function()
		case.transition({ kind = "AbortRemaining", extra = true } :: any)
	end, "RUN_STATE_E_STATE", "AbortRemaining exact keyset")
	assert(case.transition({ kind = "AbortRemaining" }).phase == "Aborted", "AbortRemaining must abort an idle case")
	local result = case.snapshot(participantSnapshots(serverEvidence, clientEvidence))
	assert(result.kind == "Terminated" and result.termination.code == "FinalEvidenceUnrepresentable", "fact-free abort must terminate")
end

do
	local server = RunState.newParticipant(session.selection, { role = "Server" })
	assert(server.recordFailure({ code = "SetupFailure", occurrences = 1 }).kind == "Recorded", "participant abort fact must record")
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	case.transition({ kind = "AbortRemaining" })
	local result = case.snapshot(participantSnapshots(
		server.freeze().value,
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value
	))
	assert(result.kind == "Snapshot", "participant-fact abort must snapshot")
end

do
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value
	local ready = { kind = "Ready", manifest = session.manifest }
	table.freeze(ready)
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	case.acceptSession(1, ready :: any)
	case.transition({ kind = "MeasuredStarted", repetitionIndex = 1 })
	case.recordFailure({ code = "Timeout", occurrences = 1, firstRepetition = 1 })
	assert(case.transition({ kind = "RepetitionAborted", repetitionIndex = 1 }).phase == "Aborted", "open repetition must abort")
	local result = case.snapshot(participantSnapshots(
		markFirstRepetitionStarted(serverEvidence, true),
		markFirstRepetitionStarted(clientEvidence, false)
	))
	assert(result.kind == "Snapshot", "coordinator-fact repetition abort must snapshot")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = deepClone(RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value)
	clientEvidence.measurements = {
		{ measurementIndex = 4, repetitionIndex = 1, values = { -0 } },
	}
	deepFreeze(clientEvidence)
	assertError(function()
		case.snapshot({
			{ participant = { role = "Server" }, evidence = serverEvidence },
			{ participant = { role = "Client", index = 1 }, evidence = clientEvidence },
		})
	end, "RUN_STATE_E_CONFIG", "negative-zero remote measurement")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = deepClone(RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value)
	table.freeze(clientEvidence)
	assertError(function()
		case.snapshot(participantSnapshots(serverEvidence, clientEvidence))
	end, "RUN_STATE_E_CONFIG", "shallow-frozen participant evidence")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = deepClone(RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value)
	clientEvidence.measurements = clientEvidence.failureFacts
	deepFreeze(clientEvidence)
	assertError(function()
		case.snapshot(participantSnapshots(serverEvidence, clientEvidence))
	end, "RUN_STATE_E_CONFIG", "aliased participant evidence")
end

do
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.repetitions[1].started = false
	clientEvidence.repetitions[1].probeStarted = 1
	deepFreeze(clientEvidence)
	assertError(function()
		case.snapshot(participantSnapshots(serverEvidence, clientEvidence))
	end, "RUN_STATE_E_CONFIG", "unstarted repetition must be empty")
end

do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	assertExactKeys(participant, { "selection", "participant", "beginGeneration", "recordFailure", "freeze" }, "ParticipantState")
	assert(table.isfrozen(participant), "ParticipantState must be frozen")
	local recorded = participant.recordFailure({ code = "SetupFailure", occurrences = 1 })
	assertExactKeys(recorded, { "kind" }, "recorded failure result")
	assert(recorded.kind == "Recorded" and table.isfrozen(recorded), "failure record result differs")

	local fixture = Fixtures.generate(session.selection.workloadId, 1)
	local clock = BenchmarkClock.new(session.runtimeInputs.server.clocks)
	local timing = TimingRecorder.new(session.caseDefinition, { role = "Server" }, clock)
	local route = DeliveryRouter.newServer()
	local tokens = table.freeze({ "client-1" })
	local generation = participant.beginGeneration(1, fixture, route.gate, timing, tokens)
	assertExactKeys(generation, { "observeDelivery", "staleHandler", "transition", "status" }, "GenerationStatePort")
	assert(table.isfrozen(generation), "GenerationStatePort must be frozen")
	local status = generation.status()
	assertExactKeys(status, { "kind", "phase" }, "prepared generation status")
	assert(status.phase == "Prepared", "generation must start prepared")
	assertError(function()
		generation.transition({ kind = "BeginMeasured" })
	end, "RUN_STATE_E_STATE", "BeginMeasured before arm")
end

do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local firstTiming = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Server" },
		BenchmarkClock.new(session.runtimeInputs.server.clocks)
	)
	participant.beginGeneration(
		1,
		Fixtures.generate(session.selection.workloadId, 1),
		DeliveryRouter.newServer().gate,
		firstTiming,
		table.freeze({ "client-1" })
	)
	assertError(function()
		participant.beginGeneration(
			2,
			Fixtures.generate(session.selection.workloadId, 2),
			DeliveryRouter.newServer().gate,
			TimingRecorder.new(
				session.caseDefinition,
				{ role = "Server" },
				BenchmarkClock.new(session.runtimeInputs.server.clocks)
			),
			table.freeze({ "client-1" })
		)
	end, "RUN_STATE_E_CONFIG", "participant recorder identity must be case-lifetime")
end

-- AbortBeforeMeasured does not manufacture participant progress or a fact,
-- and dirty prestart teardown cannot be represented as TeardownFailure.
do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local generation = participant.beginGeneration(
		1,
		Fixtures.generate(session.selection.workloadId, 1),
		DeliveryRouter.newServer().gate,
		TimingRecorder.new(session.caseDefinition, { role = "Server" }, BenchmarkClock.new(session.runtimeInputs.server.clocks)),
		table.freeze({ "client-1" })
	)
	assertError(function()
		generation.transition({ kind = "AbortBeforeMeasured", extra = true } :: any)
	end, "RUN_STATE_E_STATE", "AbortBeforeMeasured exact keyset")
	assert(generation.transition({ kind = "AbortBeforeMeasured" }).phase == "Aborting", "pre-measured abort must enter Aborting")
	generation.transition({ kind = "BeginTeardown" })
	local result = generation.transition({ kind = "FinishTeardown", clean = false })
	assert(result.kind == "Terminated" and result.termination.code == "FinalEvidenceUnrepresentable", "dirty prestart teardown must terminate")
end

-- A non-clock invariant in an active callback is contained, records the
-- sanitized execution fact, and immediately moves the generation to Aborting.
do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local generation = participant.beginGeneration(
		1,
		Fixtures.generate(session.selection.workloadId, 1),
		DeliveryRouter.newServer().gate,
		TimingRecorder.new(session.caseDefinition, { role = "Server" }, BenchmarkClock.new(session.runtimeInputs.server.clocks)),
		table.freeze({ "client-1" })
	)
	generation.transition({ kind = "BeginWarmup" })
	assert(generation.observeDelivery(1, {}, {}).kind == "None", "malformed active callback must be contained")
	assert(generation.status().phase == "Aborting", "malformed active callback must abort immediately")
	generation.transition({ kind = "BeginTeardown" })
	generation.transition({ kind = "FinishTeardown", clean = true })
	generation.transition({ kind = "FinishTeardownObservation" })
	local frozen = participant.freeze()
	assert(frozen.kind == "Evidence", "contained callback must preserve evidence")
	local foundInternal = false
	for _, fact in frozen.value.failureFacts do
		if fact.code == "InternalError" then
			foundInternal = fact.discriminator.kind == "Stage" and fact.discriminator.value == "Execution" and fact.occurrences == 1
		end
	end
	assert(foundInternal, "malformed active callback must retain one InternalError/Execution")
end

do
	local supported = AdapterContract.preflight(identity(), {
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 4,
	}, STUDIO_VERSION)
	assert(supported.kind == "Supported", "broadcast preflight must be supported")
	local workload
	for _, candidate in EventV1.workloads do
		if candidate.id == supported.selection.workloadId then workload = candidate end
	end
	local participant = RunState.newParticipant(supported.selection, { role = "Server" })
	local timing = TimingRecorder.new(workload, { role = "Server" }, timeoutClock({ 0, 0, 0 }))
	local generation = participant.beginGeneration(
		1,
		Fixtures.generate(supported.selection.workloadId, 1),
		DeliveryRouter.newServer().gate,
		timing,
		nil
	)
	assert(generation.status().phase == "Prepared", "broadcast server generation must prepare")
end

-- Armed receiver callbacks are execution traffic both before BeginWarmup and
-- after BeginMeasured. A trusted GenerationState invariant failure must abort
-- immediately, latch once, halt later callbacks/producers, and still close.
local function proveKernelObserveFailure(measured: boolean)
	local label = if measured then "measured" else "prepared"
	local route = DeliveryRouter.newServer()
	local producer
	local port = {
		selection = session.selection,
		caseDefinition = session.caseDefinition,
		participant = table.freeze({ role = "Server" }),
		side = table.freeze({
			setup = function() end,
			ready = function() return true end,
			teardown = function() end,
		}),
		postSimulation = table.freeze({
			connectPostSimulation = function(callback)
				producer = callback
				return function() end
			end,
		}),
		delivery = route.gate,
	}
	table.freeze(port)
	local phase = "Prepared"
	local quietFrames = 0
	local observeCalls = 0
	local throwOnObserve = not measured
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Server" },
		BenchmarkClock.new(session.runtimeInputs.server.clocks)
	)
	local function status()
		local value = if phase == "ControlQuiet"
			then { kind = "State", phase = phase, quietFrames = quietFrames }
			else { kind = "State", phase = phase }
		table.freeze(value)
		return value
	end
	local none = table.freeze({ kind = "None" })
	local generationState = {
		observeDelivery = function()
			observeCalls += 1
			if throwOnObserve then error("injected trusted observe failure") end
			assert(phase == "Warmup", `{label} setup callback must occur during Warmup`)
			phase = "WarmupDrained"
			return none
		end,
		staleHandler = function() end,
		transition = function(event)
			if event.kind == "AbortBeforeMeasured" then
				assert(phase == "Prepared", "prepared callback abort must start from Prepared")
				phase = "Aborting"
			elseif event.kind == "BeginWarmup" then
				phase = "Warmup"
			elseif event.kind == "PostSimulation" and phase == "WarmupDrained" then
				phase = "ControlQuiet"
				quietFrames = 1
			elseif event.kind == "PostSimulation" and phase == "ControlQuiet" then
				quietFrames = math.min(EventV1.execution.quiescenceFrames, quietFrames + 1)
			elseif event.kind == "ArmMeasured" then
				phase = "ArmedMeasured"
			elseif event.kind == "BeginMeasured" then
				timing.beginRepetition(1)
				phase = "Measured"
			elseif event.kind == "FinishMeasured" then
				assert(event.outcome == "Abort" and phase == "Measured", "measured callback must abort open measurement")
				timing.finishRepetition(false)
				phase = "Aborting"
			elseif event.kind == "BeginTeardown" then
				assert(phase == "Aborting", "callback teardown must start from Aborting")
			elseif event.kind == "FinishTeardown" then
				phase = "PostTeardownObservation"
			elseif event.kind == "FinishTeardownObservation" then
				phase = "Closed"
			else
				error("unexpected generation transition")
			end
			return status()
		end,
		status = status,
	}
	table.freeze(generationState)
	local internalFacts = 0
	local caseProgress = 0
	local recorded = table.freeze({ kind = "Recorded" })
	local active = table.freeze({ kind = "Active" })
	local caseState = {
		recordFailure = function(fact)
			assert(fact.code == "InternalError" and fact.discriminator.value == "Execution", `{label} callback failure fact differs`)
			internalFacts += 1
			return recorded
		end,
		terminate = function() error("callback invariant must remain representable") end,
		startDeadline = function() return active end,
		checkDeadline = function() return active end,
		clearDeadline = function() end,
		transition = function(event)
			assert(event.kind == "MeasuredStarted" and event.repetitionIndex == 1, "measured case progress differs")
			caseProgress += 1
			return recorded
		end,
	}
	table.freeze(caseState)
	local participantState = table.freeze({ recordFailure = caseState.recordFailure })
	local kernel = RunnerKernel.new(
		port :: any,
		generationState :: any,
		Fixtures.generate(session.selection.workloadId, 1),
		timing,
		caseState :: any,
		participantState :: any
	)
	assert(kernel.attach().kind == "Clean", `{label} callback kernel attach must succeed`)
	assert(kernel.setup().kind == "Clean", `{label} callback kernel setup must succeed`)
	assert(kernel.pollReady().kind == "Ready", `{label} callback kernel readiness must succeed`)
	assert(kernel.arm().kind == "Ready", `{label} callback kernel arm must succeed`)
	local runProducer = producer :: any
	if measured then
		assert(kernel.command({ kind = "BeginWarmup" }).phase == "Warmup", "measured callback warmup must begin")
		route.sink({}, { kind = "ClientToServer", sender = "client-1" })
		runProducer()
		while quietFrames < EventV1.execution.quiescenceFrames do runProducer() end
		assert(kernel.command({ kind = "ArmMeasured", startSharedSeconds = 0 }).phase == "ArmedMeasured", "measured callback must arm")
		runProducer()
		assert(kernel.status().phase == "Measured" and caseProgress == 1, "measured callback must start measured progress")
		throwOnObserve = true
	end
	local callsBeforeFailure = observeCalls
	route.sink({}, { kind = "ClientToServer", sender = "client-1" })
	assert(kernel.status().kind == "State" and kernel.status().phase == "Aborting", `{label} callback invariant must abort immediately`)
	assert(observeCalls == callsBeforeFailure + 1 and internalFacts == 1, `{label} callback invariant must record exactly once`)
	route.sink({}, { kind = "ClientToServer", sender = "client-1" })
	runProducer()
	assert(observeCalls == callsBeforeFailure + 1 and internalFacts == 1, `{label} halted callback/producer must remain inert`)
	kernel.beginTeardownObservation()
	assert(kernel.teardown().kind == "Clean", `{label} callback invariant teardown must remain clean`)
	local closed = kernel.finishTeardownObservation()
	assert(closed.kind == "State" and closed.phase == "Closed", `{label} callback invariant observation must close`)
	assert(internalFacts == 1, `{label} callback invariant teardown must not add a fact`)
end

proveKernelObserveFailure(false)
proveKernelObserveFailure(true)

local function proveKernelPublicAbort(targetPhase: "Warmup" | "ArmedMeasured")
	local route = DeliveryRouter.newServer()
	local producer
	local phase = "Prepared"
	local quietFrames = 0
	local function status()
		local value = if phase == "ControlQuiet"
			then { kind = "State", phase = phase, quietFrames = quietFrames }
			else { kind = "State", phase = phase }
		table.freeze(value)
		return value
	end
	local none = table.freeze({ kind = "None" })
	local generationState = {
		observeDelivery = function()
			assert(phase == "Warmup", "abort warmup classifier must be active")
			phase = "WarmupDrained"
			return none
		end,
		staleHandler = function() end,
		transition = function(event)
			if event.kind == "BeginWarmup" then
				phase = "Warmup"
			elseif event.kind == "PostSimulation" and phase == "WarmupDrained" then
				phase = "ControlQuiet"
				quietFrames = 1
			elseif event.kind == "PostSimulation" and phase == "ControlQuiet" then
				quietFrames = math.min(EventV1.execution.quiescenceFrames, quietFrames + 1)
			elseif event.kind == "ArmMeasured" then
				phase = "ArmedMeasured"
			elseif event.kind == "AbortBeforeMeasured" then
				assert(phase == targetPhase, `public abort must start from {targetPhase}`)
				phase = "Aborting"
			elseif event.kind == "BeginTeardown" then
				assert(phase == "Aborting", "public abort teardown must start from Aborting")
			elseif event.kind == "FinishTeardown" then
				phase = "PostTeardownObservation"
			elseif event.kind == "FinishTeardownObservation" then
				phase = "Closed"
			else
				error("unexpected public-abort generation transition")
			end
			return status()
		end,
		status = status,
	}
	table.freeze(generationState)
	local port = {
		selection = session.selection,
		caseDefinition = session.caseDefinition,
		participant = table.freeze({ role = "Server" }),
		side = table.freeze({
			setup = function() end,
			ready = function() return true end,
			teardown = function() end,
		}),
		postSimulation = table.freeze({
			connectPostSimulation = function(callback)
				producer = callback
				return function() end
			end,
		}),
		delivery = route.gate,
	}
	table.freeze(port)
	local active = table.freeze({ kind = "Active" })
	local caseState = {
		recordFailure = function() error("public pre-measured abort must not add a fact") end,
		terminate = function() error("public pre-measured abort must remain representable") end,
		startDeadline = function() return active end,
		checkDeadline = function() return active end,
		clearDeadline = function() end,
		transition = function() error("public pre-measured abort must not start case progress") end,
	}
	table.freeze(caseState)
	local participantState = table.freeze({ recordFailure = caseState.recordFailure })
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Server" },
		BenchmarkClock.new(session.runtimeInputs.server.clocks)
	)
	local kernel = RunnerKernel.new(
		port :: any,
		generationState :: any,
		Fixtures.generate(session.selection.workloadId, 1),
		timing,
		caseState :: any,
		participantState :: any
	)
	assert(kernel.attach().kind == "Clean", `{targetPhase} abort attach must succeed`)
	assert(kernel.setup().kind == "Clean", `{targetPhase} abort setup must succeed`)
	assert(kernel.pollReady().kind == "Ready", `{targetPhase} abort readiness must succeed`)
	assert(kernel.arm().kind == "Ready", `{targetPhase} abort arm must succeed`)
	assert(kernel.command({ kind = "BeginWarmup" }).phase == "Warmup", `{targetPhase} abort warmup must begin`)
	local runProducer = producer :: any
	if targetPhase == "ArmedMeasured" then
		route.sink({}, { kind = "ClientToServer", sender = "client-1" })
		runProducer()
		while quietFrames < EventV1.execution.quiescenceFrames do runProducer() end
		assert(kernel.command({ kind = "ArmMeasured", startSharedSeconds = 0 }).phase == "ArmedMeasured", "public abort must reach ArmedMeasured")
	end
	local aborted = kernel.command({ kind = "AbortBeforeMeasured" })
	assert(aborted.kind == "State" and aborted.phase == "Aborting", `{targetPhase} public abort must reach Aborting`)
	kernel.beginTeardownObservation()
	assert(kernel.teardown().kind == "Clean", `{targetPhase} public abort teardown must be clean`)
	local closed = kernel.finishTeardownObservation()
	assert(closed.kind == "State" and closed.phase == "Closed", `{targetPhase} public abort observation must close`)
end

proveKernelPublicAbort("Warmup")
proveKernelPublicAbort("ArmedMeasured")

-- RunnerKernel must not return the stale ArmedMeasured status when clearing
-- the server warmup deadline fails after the state transition succeeded.
do
	local supported = AdapterContract.preflight(identity(), {
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 4,
	}, STUDIO_VERSION)
	assert(supported.kind == "Supported", "kernel deadline-clear selection must be supported")
	local workload
	for _, candidate in EventV1.workloads do
		if candidate.id == supported.selection.workloadId then workload = candidate end
	end
	local route = DeliveryRouter.newServer()
	local timing = TimingRecorder.new(workload, { role = "Server" }, timeoutClock({ 0, 0, 0 }))
	local participantState = RunState.newParticipant(supported.selection, { role = "Server" })
	local generation = participantState.beginGeneration(
		1,
		Fixtures.generate(supported.selection.workloadId, 1),
		route.gate,
		timing,
		nil
	)
	local producer
	local port = {
		selection = supported.selection,
		caseDefinition = workload,
		participant = table.freeze({ role = "Server" }),
		side = table.freeze({
			setup = function() end,
			ready = function() return true end,
			teardown = function() end,
			broadcast = function() end,
		}),
		postSimulation = table.freeze({
			connectPostSimulation = function(callback)
				producer = callback
				return function() end
			end,
		}),
		delivery = route.gate,
	}
	table.freeze(port)
	local internalFacts = 0
	local active = table.freeze({ kind = "Active" })
	local recorded = table.freeze({ kind = "Recorded" })
	local caseState = {
		startDeadline = function() return active end,
		checkDeadline = function() return active end,
		clearDeadline = function() error("injected deadline clear failure") end,
		recordFailure = function(fact)
			assert(fact.code == "InternalError" and fact.discriminator.value == "Execution", "deadline clear fact differs")
			internalFacts += 1
			return recorded
		end,
		transition = function() error("case progress must not start") end,
		terminate = function() error("case must not terminate") end,
	}
	table.freeze(caseState)
	local kernel = RunnerKernel.new(
		port :: any,
		generation,
		Fixtures.generate(supported.selection.workloadId, 1),
		timing,
		caseState :: any,
		participantState
	)
	assert(kernel.attach().kind == "Clean", "kernel attach must succeed")
	assert(kernel.setup().kind == "Clean", "kernel setup must succeed")
	assert(kernel.pollReady().kind == "Ready", "kernel readiness must succeed")
	assert(kernel.arm().kind == "Ready", "kernel arm must succeed")
	assert(kernel.command({ kind = "BeginWarmup" }).phase == "Warmup", "kernel warmup must begin")
	while generation.status().phase ~= "ControlQuiet" do
		(producer :: any)()
	end
	while (generation.status() :: any).quietFrames < EventV1.execution.quiescenceFrames do
		(producer :: any)()
	end
	local result = kernel.command({ kind = "ArmMeasured", startSharedSeconds = 0 })
	assert(result.kind == "State" and result.phase == "Aborting", "deadline clear failure must return Aborting")
	assert(kernel.status().kind == "State" and kernel.status().phase == "Aborting", "deadline clear failure status must be Aborting")
	assert(internalFacts == 1, "deadline clear failure must record exactly one InternalError")
end

-- A distributed C2S receiver owns its delivery deadline through RunnerKernel.
-- The deadline starts only if FinishMeasured still needs deliveries and is
-- cleared as soon as the final delivery verifies the repetition.
do
	local route = DeliveryRouter.newServer()
	local producer
	local phase = "Prepared"
	local quietFrames = 0
	local function status()
		local value = if phase == "ControlQuiet" or phase == "Verified"
			then { kind = "State", phase = phase, quietFrames = quietFrames }
			else { kind = "State", phase = phase }
		table.freeze(value)
		return value
	end
	local none = table.freeze({ kind = "None" })
	local generationState = {
		observeDelivery = function()
			assert(phase == "Draining", "C2S final delivery must arrive while draining")
			phase = "Verified"
			quietFrames = 0
			return none
		end,
		staleHandler = function() end,
		transition = function(event)
			if event.kind == "BeginWarmup" then
				phase = "WarmupDrained"
			elseif event.kind == "PostSimulation" and phase == "WarmupDrained" then
				phase = "ControlQuiet"
				quietFrames = 1
			elseif event.kind == "PostSimulation" and phase == "ControlQuiet" then
				quietFrames = math.min(EventV1.execution.quiescenceFrames, quietFrames + 1)
			elseif event.kind == "ArmMeasured" then
				phase = "ArmedMeasured"
			elseif event.kind == "BeginMeasured" then
				phase = "Measured"
			elseif event.kind == "FinishMeasured" then
				assert(event.outcome == "Complete" and phase == "Measured", "C2S receiver must finish measured from Measured")
				phase = "Draining"
			elseif event.kind == "PostSimulation" and phase == "Verified" then
				quietFrames = math.min(EventV1.execution.quiescenceFrames, quietFrames + 1)
			elseif event.kind == "BeginTeardown" then
				assert(phase == "Verified", "C2S receiver teardown must start after verification")
				phase = "Teardown"
			elseif event.kind == "FinishTeardown" then
				phase = "PostTeardownObservation"
			elseif event.kind == "FinishTeardownObservation" then
				phase = "Closed"
			else
				error("unexpected C2S receiver transition")
			end
			return status()
		end,
		status = status,
	}
	table.freeze(generationState)
	local port = {
		selection = session.selection,
		caseDefinition = session.caseDefinition,
		participant = table.freeze({ role = "Server" }),
		side = table.freeze({
			setup = function() end,
			ready = function() return true end,
			teardown = function() end,
		}),
		postSimulation = table.freeze({
			connectPostSimulation = function(callback)
				producer = callback
				return function() end
			end,
		}),
		delivery = route.gate,
	}
	table.freeze(port)
	local active = table.freeze({ kind = "Active" })
	local recorded = table.freeze({ kind = "Recorded" })
	local activeScope = nil
	local starts = {}
	local clears = {}
	local caseState = {
		startDeadline = function(scope)
			assert(activeScope == nil, `deadline {tostring(activeScope)} leaked before {scope}`)
			activeScope = scope
			table.insert(starts, scope)
			return active
		end,
		checkDeadline = function(scope)
			assert(activeScope == scope, "C2S receiver must check its active deadline")
			return active
		end,
		clearDeadline = function(scope)
			assert(activeScope == scope, "C2S receiver must clear its owned deadline")
			activeScope = nil
			table.insert(clears, scope)
		end,
		recordFailure = function() error("C2S receiver deadline path must not add a failure") end,
		transition = function(event)
			assert(event.kind == "MeasuredStarted" and event.repetitionIndex == 1, "C2S receiver progress differs")
			return recorded
		end,
		terminate = function() error("C2S receiver deadline path must remain representable") end,
	}
	table.freeze(caseState)
	local participantState = table.freeze({ recordFailure = caseState.recordFailure })
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Server" },
		BenchmarkClock.new(session.runtimeInputs.server.clocks)
	)
	local kernel = RunnerKernel.new(
		port :: any,
		generationState :: any,
		Fixtures.generate(session.selection.workloadId, 1),
		timing,
		caseState :: any,
		participantState :: any,
		true
	)
	assert(kernel.attach().kind == "Clean" and kernel.setup().kind == "Clean", "C2S receiver setup must succeed")
	assert(kernel.pollReady().kind == "Ready" and kernel.arm().kind == "Ready", "C2S receiver readiness must succeed")
	assert(kernel.command({ kind = "BeginWarmup" }).phase == "WarmupDrained", "C2S receiver warmup must begin")
	local runProducer = producer :: any
	while phase ~= "ControlQuiet" or quietFrames < EventV1.execution.quiescenceFrames do runProducer() end
	assert(kernel.command({ kind = "ArmMeasured", startSharedSeconds = 0 }).phase == "ArmedMeasured", "C2S receiver must arm measured")
	runProducer()
	assert(kernel.command({ kind = "FinishMeasured", outcome = "Complete" }).phase == "Draining", "C2S receiver must drain")
	assert(activeScope == "Delivery", "C2S receiver must own the delivery deadline while draining")
	route.sink({}, { kind = "ClientToServer", sender = "client-1" })
	assert(kernel.status().phase == "Verified" and activeScope == nil, "final C2S delivery must clear the deadline")
	assert(#starts == 2 and starts[1] == "Warmup" and starts[2] == "Delivery", "C2S deadline starts differ")
	assert(#clears == 2 and clears[1] == "Warmup" and clears[2] == "Delivery", "C2S deadline clears differ")
	while quietFrames < EventV1.execution.quiescenceFrames do runProducer() end
	kernel.beginTeardownObservation()
	assert(kernel.teardown().kind == "Clean", "C2S receiver teardown must stay clean")
	assert(kernel.finishTeardownObservation().phase == "Closed", "C2S receiver observation must close")
end

do
	local participant = RunState.newParticipant(session.selection, { role = "Client", index = 1 })
	local fixture = Fixtures.generate(session.selection.workloadId, 1)
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Client", index = 1 },
		BenchmarkClock.new(session.runtimeInputs.clients[1].clocks)
	)
	local generation = participant.beginGeneration(1, fixture, DeliveryRouter.newClient().gate, timing, nil)
	timing.enterExcluded("setup")
	assert(timing.leaveExcluded("setup"), "timeout setup exclusion must remain clean")
	timing.enterExcluded("warmup")
	generation.transition({ kind = "BeginWarmup" })
	for index in fixture.warmup do
		generation.transition({ kind = "OperationStarted", phase = "Warmup", fixtureIndex = index })
		generation.transition({ kind = "OperationReturned", phase = "Warmup", fixtureIndex = index })
	end
	assert(timing.leaveExcluded("warmup"), "timeout warmup exclusion must remain clean")
	timing.enterExcluded("quiescence")
	generation.transition({ kind = "PostSimulation" })
	for _ = 2, EventV1.execution.quiescenceFrames do generation.transition({ kind = "PostSimulation" }) end
	assert(timing.leaveExcluded("quiescence"), "timeout quiescence exclusion must remain clean")
	generation.transition({ kind = "ArmMeasured", startSharedSeconds = 0 })
	generation.transition({ kind = "BeginMeasured" })
	assert(timing.recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "timeout clock proof must pass")
	assert(generation.transition({ kind = "Timeout", scope = "Delivery" }).phase == "Aborting", "delivery timeout must abort")
	generation.transition({ kind = "BeginTeardown" })
	generation.transition({ kind = "FinishTeardown", clean = true })
	generation.transition({ kind = "FinishTeardownObservation" })
	assert(participant.freeze().kind == "Evidence", "timeout must freeze without an incomplete timing group")
end

-- A zero-return adapter call is accepted before its caller-owned input is
-- checked. Mutation therefore increments submitted exactly once and aborts
-- atomically instead of passing through a completed state.
do
	local participant = RunState.newParticipant(session.selection, { role = "Client", index = 1 })
	assertError(function()
		participant.recordFailure({ code = "InputMutation", occurrences = 1 })
	end, "RUN_STATE_E_CONFIG", "input mutation must require the atomic return event")
	local fixture = Fixtures.generate(session.selection.workloadId, 1)
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Client", index = 1 },
		BenchmarkClock.new(session.runtimeInputs.clients[1].clocks)
	)
	local generation = participant.beginGeneration(1, fixture, DeliveryRouter.newClient().gate, timing, nil)
	timing.enterExcluded("setup")
	assert(timing.leaveExcluded("setup"), "mutation setup exclusion must remain clean")
	timing.enterExcluded("warmup")
	generation.transition({ kind = "BeginWarmup" })
	for index in fixture.warmup do
		generation.transition({ kind = "OperationStarted", phase = "Warmup", fixtureIndex = index })
		generation.transition({ kind = "OperationReturned", phase = "Warmup", fixtureIndex = index })
	end
	assert(timing.leaveExcluded("warmup"), "mutation warmup exclusion must remain clean")
	timing.enterExcluded("quiescence")
	for _ = 1, EventV1.execution.quiescenceFrames do
		generation.transition({ kind = "PostSimulation" })
	end
	assert(timing.leaveExcluded("quiescence"), "mutation quiescence exclusion must remain clean")
	generation.transition({ kind = "ArmMeasured", startSharedSeconds = 0 })
	generation.transition({ kind = "BeginMeasured" })
	assert(timing.recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "mutation clock proof must pass")
	generation.transition({ kind = "OperationStarted", phase = "Measured", fixtureIndex = 1 })
	local mutated = generation.transition({
		kind = "OperationReturnedWithInputMutation",
		phase = "Measured",
		fixtureIndex = 1,
	})
	assert(mutated.kind == "State" and mutated.phase == "Aborting",
		"input mutation must abort in the accepted-return transition")
	generation.transition({ kind = "BeginTeardown" })
	generation.transition({ kind = "FinishTeardown", clean = true })
	generation.transition({ kind = "FinishTeardownObservation" })
	local frozen = participant.freeze()
	assert(frozen.kind == "Evidence", "input mutation must freeze as participant evidence")
	assert(frozen.value.repetitions[1].submitted == 1,
		"accepted mutated operation must increment submitted")
	assert(#frozen.value.failureFacts == 1
		and frozen.value.failureFacts[1].code == "InputMutation"
		and frozen.value.failureFacts[1].occurrences == 1,
		"input mutation evidence must be a single bounded latch")
end

-- Probe response acceptance is a bounded identity-only action. RunState owns
-- the receipt clock read; stale/malformed entries never make that read.
do
	local supported = AdapterContract.preflight(identity(), {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
	}, STUDIO_VERSION)
	assert(supported.kind == "Supported", "probe preflight must be supported")
	local probe = EventV1.probes[1]
	local localReads = 0
	local clock = BenchmarkClock.new({
		localNowSeconds = function()
			localReads += 1
			return localReads
		end,
		sharedNowSeconds = function() return 0 end,
		timeoutNowSeconds = function() return 0 end,
	})
	local timing = TimingRecorder.new(probe, { role = "ProbeClient", index = 1 }, clock)
	local participant = RunState.newParticipant(supported.selection, { role = "ProbeClient", index = 1 })
	local fixture = Fixtures.generateProbe(probe.id, 1)
	local route = DeliveryRouter.newClient()
	local generation = participant.beginGeneration(1, fixture, route.gate, timing, nil)
	local metadata = { kind = "ServerToClient" }

	local readsBeforeRejected = localReads
	assert(generation.observeDelivery(1, {}, metadata).kind == "None", "wrong-phase callback must be rejected")
	assert(localReads == readsBeforeRejected, "rejected callback must not read measurement clock")

	timing.enterExcluded("setup")
	assert(timing.leaveExcluded("setup"), "setup exclusion must remain clean")
	timing.enterExcluded("warmup")
	generation.transition({ kind = "BeginWarmup" })
	for index, sample in fixture.warmup do
		generation.transition({ kind = "OperationStarted", phase = "Warmup", fixtureIndex = index })
		generation.transition({ kind = "OperationReturned", phase = "Warmup", fixtureIndex = index })
		local action = generation.observeDelivery(
			2,
			AdapterContract.recordDelivery(Fixtures.newInput(sample)),
			metadata
		)
		assert(action.kind == "ProbeResponseAccepted" and action.fixtureIndex == index, "warmup response action differs")
	end
	assert(timing.leaveExcluded("warmup"), "warmup exclusion must remain clean")
	timing.enterExcluded("quiescence")
	generation.transition({ kind = "PostSimulation" })
	for _ = 2, EventV1.execution.quiescenceFrames do
		generation.transition({ kind = "PostSimulation" })
	end
	assert(timing.leaveExcluded("quiescence"), "quiescence exclusion must remain clean")
	generation.transition({ kind = "ArmMeasured", startSharedSeconds = 0 })
	generation.transition({ kind = "BeginMeasured" })
	assert(timing.recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "probe clock proof must pass")
	for index, sample in fixture.measured do
		timing.markLocal("RoundTripSubmissionStarted")
		generation.transition({ kind = "OperationStarted", phase = "Measured", fixtureIndex = index })
		generation.transition({ kind = "OperationReturned", phase = "Measured", fixtureIndex = index })
		local action = generation.observeDelivery(
			2,
			AdapterContract.recordDelivery(Fixtures.newInput(sample)),
			metadata
		)
		assert(action.kind == "ProbeResponseAccepted" and action.fixtureIndex == index, "measured response action differs")
	end
	assert(generation.status().phase == "Verified", "probe must verify on its final terminal response")
	timing.enterExcluded("quiescence")
	for _ = 1, EventV1.execution.quiescenceFrames - 1 do
		generation.transition({ kind = "PostSimulation" })
	end
	assert((generation.status() :: any).quietFrames == 59, "post-measured frame 59 must remain quiet-pending")
	assertError(function()
		generation.transition({ kind = "BeginTeardown" })
	end, "RUN_STATE_E_STATE", "post-measured teardown before frame 60")
	assertError(function()
		generation.transition({ kind = "FinishTeardown", clean = true })
	end, "RUN_STATE_E_STATE", "post-measured teardown completion before frame 60")
	generation.transition({ kind = "PostSimulation" })
	assert((generation.status() :: any).quietFrames == 60, "post-measured frame 60 must permit teardown")
	assert(timing.leaveExcluded("quiescence"), "post-measured quiescence exclusion must remain clean")
	generation.transition({ kind = "BeginTeardown" })
	generation.transition({ kind = "FinishTeardown", clean = true })
	assert(generation.transition({ kind = "FinishTeardownObservation" }).phase == "Closed", "probe must close")
	local frozen = participant.freeze()
	assertExactKeys(frozen, { "kind", "value" }, "participant freeze result")
	assert(frozen.kind == "Evidence", "participant must freeze evidence")
	assertExactKeys(frozen.value, { "version", "repetitions", "measurements", "failureFacts", "conformance" }, "participant evidence")
	assert(frozen.value.version == 1 and #frozen.value.repetitions == 1, "participant evidence prefix differs")
	assert(frozen.value.repetitions[1].probeReceived == probe.measuredSamples, "probe received count differs")
	assert(frozen.value.repetitions[1].probeCorrect == probe.measuredSamples, "probe correct count differs")
	assert(frozen.value.repetitions[1].completed, "probe repetition must be complete")
end

-- Verified workload callbacks stay on the measured ledger. Any entry resets
-- post-measured quiet before bounded classification, without reopening timing.
do
	local supported = AdapterContract.preflight(identity(), {
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 1,
	}, STUDIO_VERSION)
	assert(supported.kind == "Supported", "verified callback selection must be supported")
	local workload
	for _, candidate in EventV1.workloads do
		if candidate.id == supported.selection.workloadId then workload = candidate end
	end
	local participant = RunState.newParticipant(supported.selection, { role = "Client", index = 1 })
	local timing = TimingRecorder.new(workload, { role = "Client", index = 1 }, BenchmarkClock.new(constantProcess(0).clocks))
	local fixture = Fixtures.generate(supported.selection.workloadId, 1)
	local generation = participant.beginGeneration(1, fixture, DeliveryRouter.newClient().gate, timing, nil)
	local metadata = { kind = "ServerToClient" }

	timing.enterExcluded("setup")
	assert(timing.leaveExcluded("setup"), "verified callback setup exclusion must remain clean")
	timing.enterExcluded("warmup")
	generation.transition({ kind = "BeginWarmup" })
	for _, sample in fixture.warmup do
		generation.observeDelivery(2, AdapterContract.recordDelivery(Fixtures.newInput(sample)), metadata)
	end
	assert(generation.status().phase == "WarmupDrained", "verified callback warmup must drain")
	assert(timing.leaveExcluded("warmup"), "verified callback warmup exclusion must remain clean")
	timing.enterExcluded("quiescence")
	for _ = 1, EventV1.execution.quiescenceFrames do
		generation.transition({ kind = "PostSimulation" })
	end
	assert(timing.leaveExcluded("quiescence"), "verified callback pre-measured quiet must remain clean")
	generation.transition({ kind = "ArmMeasured", startSharedSeconds = 0 })
	generation.transition({ kind = "BeginMeasured" })
	assert(timing.recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "verified callback clock proof must pass")
	for _, sample in fixture.measured do
		generation.observeDelivery(2, AdapterContract.recordDelivery(Fixtures.newInput(sample)), metadata)
	end
	assert(generation.status().phase == "Measured", "verified callback workload must remain measured until FinishMeasured")
	assert(generation.transition({ kind = "FinishMeasured", outcome = "Complete" }).phase == "Verified",
		"verified callback workload must verify")

	timing.enterExcluded("quiescence")
	for _ = 1, EventV1.execution.quiescenceFrames - 1 do
		generation.transition({ kind = "PostSimulation" })
	end
	assert((generation.status() :: any).quietFrames == 59, "verified callback frame 59 must remain pending")
	local late = generation.observeDelivery(
		2,
		AdapterContract.recordDelivery(Fixtures.newInput(fixture.measured[#fixture.measured])),
		metadata
	)
	assert(late.kind == "None" and generation.status().phase == "Verified", "late duplicate must remain Verified")
	assert((generation.status() :: any).quietFrames == 0, "late duplicate must reset quiet progress")
	for _ = 1, EventV1.execution.quiescenceFrames - 1 do
		generation.transition({ kind = "PostSimulation" })
	end
	assert((generation.status() :: any).quietFrames == 59, "reset frame 59 must remain pending")
	generation.transition({ kind = "PostSimulation" })
	assert((generation.status() :: any).quietFrames == 60, "reset frame 60 must permit teardown")
	assert(timing.leaveExcluded("quiescence"), "verified callback post-measured quiet must remain clean")
	generation.transition({ kind = "BeginTeardown" })
	generation.transition({ kind = "FinishTeardown", clean = true })
	generation.transition({ kind = "FinishTeardownObservation" })
	local frozen = participant.freeze()
	assert(frozen.kind == "Evidence", "verified callback evidence must freeze")
	local duplicateOccurrences = 0
	for _, fact in frozen.value.failureFacts do
		if fact.code == "DuplicateDelivery" then duplicateOccurrences = fact.occurrences end
		assert(fact.code ~= "StaleCallback", "verified duplicate must not become StaleCallback")
	end
	assert(duplicateOccurrences == 1, "verified duplicate must remain measured-ledger evidence")
	assert(frozen.value.repetitions[1].duplicate == 1, "verified duplicate repetition count differs")
end

local function beginReceiverGeneration(participant, timing, repetitionIndex, route)
	local fixture = Fixtures.generate(session.selection.workloadId, repetitionIndex)
	local generation = participant.beginGeneration(
		repetitionIndex,
		fixture,
		route.gate,
		timing,
		table.freeze({ "client-1" })
	)
	assert(route.gate.bind(function(argumentCount, delivery, metadata)
		generation.observeDelivery(argumentCount, delivery, metadata)
	end), "receiver route must bind")
	assert(route.gate.arm(), "receiver route must arm")
	timing.enterExcluded("setup")
	assert(timing.leaveExcluded("setup"), "receiver setup exclusion must remain clean")
	timing.enterExcluded("warmup")
	generation.transition({ kind = "BeginWarmup" })
	for _, sample in fixture.warmup do
		generation.observeDelivery(
			2,
			AdapterContract.recordDelivery(Fixtures.newInput(sample)),
			{ kind = "ClientToServer", sender = "client-1" }
		)
	end
	assert(generation.status().phase == "WarmupDrained", "receiver warmup must drain")
	assert(timing.leaveExcluded("warmup"), "receiver warmup exclusion must remain clean")
	timing.enterExcluded("quiescence")
	for _ = 1, EventV1.execution.quiescenceFrames do
		generation.transition({ kind = "PostSimulation" })
	end
	assert(timing.leaveExcluded("quiescence"), "receiver quiescence exclusion must remain clean")
	generation.transition({ kind = "ArmMeasured", startSharedSeconds = 0 })
	generation.transition({ kind = "BeginMeasured" })
	return generation, fixture
end

-- The measured callback cap accepts exactly 4x the case-wide expected
-- receipts. The next entry is not counted, closes timing, and aborts once.
do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Server" },
		BenchmarkClock.new(session.runtimeInputs.server.clocks)
	)
	local route = DeliveryRouter.newServer()
	local generation, fixture = beginReceiverGeneration(participant, timing, 1, route)
	assert(timing.recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "active-cap clock proof must pass")
	local limit = 4 * session.caseDefinition.repetitions * session.caseDefinition.measuredFrames
	local delivery = AdapterContract.recordDelivery(Fixtures.newInput(fixture.measured[1]))
	local metadata = { kind = "ClientToServer", sender = "client-1" }
	for _ = 1, limit do
		generation.observeDelivery(2, delivery, metadata)
	end
	assert(generation.status().phase == "Measured", "active cap must be inclusive")
	assert(generation.observeDelivery(2, delivery, metadata).kind == "None", "active cap +1 must be contained")
	assert(generation.status().phase == "Aborting", "active cap +1 must abort")
	generation.transition({ kind = "BeginTeardown" })
	generation.transition({ kind = "FinishTeardown", clean = true })
	generation.transition({ kind = "FinishTeardownObservation" })
	local evidence = participant.freeze().value
	assert(evidence.repetitions[1].received == limit, "overflow callback must not enter receipt counts")
	assert(evidence.repetitions[1].observationOverflow, "active cap +1 must retain overflow evidence")
	local overflow = 0
	for _, fact in evidence.failureFacts do
		if fact.code == "DeliveryObservationLimitExceeded" then overflow = fact.occurrences end
	end
	assert(overflow == 1, "active cap +1 must record one overflow")

	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.repetitions[1].submitted = 1
	clientEvidence.repetitions[1].firstSubmissionStartedSharedSeconds = 0
	clientEvidence.repetitions[1].finalSubmissionReturnedSharedSeconds = 0
	deepFreeze(clientEvidence)
	local function snapshotOverflow(serverEvidence)
		local case = RunState.newCase(session, timeoutClock({ 0 }))
		case.acceptSession(1, table.freeze({ kind = "Ready", manifest = session.manifest }))
		case.transition({ kind = "MeasuredStarted", repetitionIndex = 1 })
		case.transition({ kind = "RepetitionAborted", repetitionIndex = 1 })
		return case.snapshot(participantSnapshots(serverEvidence, clientEvidence))
	end
	local snapshot = snapshotOverflow(evidence)
	assert(snapshot.kind == "Snapshot",
		"a case-wide callback budget exhausted in one repetition must survive snapshot validation")
	local assembled = ResultDraftAssembler.assemble(table.freeze({
		runId = "10213243-5465-7687-98a9-bacbdcedfe0f",
		manifest = session.manifest,
		snapshot = snapshot.value,
	}))
	assert(assembled.kind == "Draft", "case-wide callback overflow must remain projectable")
	local finalized = ResultV1.finalize(assembled.value)
	assert(finalized.status == "Invalid" and ResultV1.validate(finalized).status == "Invalid",
		"case-wide callback overflow must produce an invalid diagnostic Result")
	for _, malformed in { "TooManyFirstReceipts", "OverCaseBudget", "PrematureOverflow" } do
		local changed = deepClone(evidence)
		local repetition = changed.repetitions[1]
		if malformed == "TooManyFirstReceipts" then
			repetition.correct = #fixture.measured + 1
		elseif malformed == "OverCaseBudget" then
			repetition.received += 1
		else
			repetition.received -= 1
		end
		repetition.duplicate = repetition.received - repetition.correct
		for _, fact in changed.failureFacts do
			if fact.code == "DuplicateDelivery" then fact.occurrences = repetition.duplicate end
		end
		deepFreeze(changed)
		assertError(function() snapshotOverflow(changed) end, "RUN_STATE_E_CONFIG", malformed)
	end
end

-- Rejected callbacks have an independent case-wide cap. Prepared callbacks
-- are inert through the limit and the next entry terminates without evidence.
do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local generation = participant.beginGeneration(
		1,
		Fixtures.generate(session.selection.workloadId, 1),
		DeliveryRouter.newServer().gate,
		TimingRecorder.new(session.caseDefinition, { role = "Server" }, BenchmarkClock.new(session.runtimeInputs.server.clocks)),
		table.freeze({ "client-1" })
	)
	local limit = 4 * session.caseDefinition.repetitions * session.caseDefinition.measuredFrames
	for _ = 1, limit do generation.observeDelivery(0, nil, nil) end
	assert(generation.status().phase == "Prepared", "rejected callback cap must be inclusive")
	local overflow = generation.observeDelivery(0, nil, nil)
	assert(overflow.kind == "None", "rejected cap +1 must be contained")
	local status = generation.status()
	assert(status.kind == "Terminated" and status.termination.code == "FinalEvidenceUnrepresentable",
		"rejected cap +1 termination differs")
end

-- The per-generation warmup phase cap is likewise inclusive and wins before
-- any case-wide universal budget could be exceeded.
do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local fixture = Fixtures.generate(session.selection.workloadId, 1)
	local generation = participant.beginGeneration(
		1,
		fixture,
		DeliveryRouter.newServer().gate,
		TimingRecorder.new(session.caseDefinition, { role = "Server" }, BenchmarkClock.new(session.runtimeInputs.server.clocks)),
		table.freeze({ "client-1" })
	)
	generation.transition({ kind = "BeginWarmup" })
	local limit = 4 * session.caseDefinition.warmupFrames
	local delivery = AdapterContract.recordDelivery(Fixtures.newInput(fixture.warmup[1]))
	local metadata = { kind = "ClientToServer", sender = "client-1" }
	for _ = 1, limit do generation.observeDelivery(2, delivery, metadata) end
	assert(generation.status().phase == "Warmup", "warmup phase cap must be inclusive")
	generation.observeDelivery(2, delivery, metadata)
	local status = generation.status()
	assert(status.kind == "Terminated" and status.termination.code == "WarmupEvidenceRejected",
		"warmup phase cap +1 termination differs")
end

local function broadcastParticipantEvidence(preparedBroadcast, participantRef, overflow)
	local participant = RunState.newParticipant(preparedBroadcast.selection, participantRef)
	local timing = TimingRecorder.new(
		preparedBroadcast.caseDefinition,
		participantRef,
		BenchmarkClock.new(if participantRef.role == "Server"
			then preparedBroadcast.runtimeInputs.server.clocks
			else preparedBroadcast.runtimeInputs.clients[participantRef.index].clocks)
	)
	for repetitionIndex = 1, preparedBroadcast.caseDefinition.repetitions do
		local fixture = Fixtures.generate(preparedBroadcast.selection.workloadId, repetitionIndex)
		local route = if participantRef.role == "Server" then DeliveryRouter.newServer() else DeliveryRouter.newClient()
		local generation = participant.beginGeneration(repetitionIndex, fixture, route.gate, timing, nil)
		timing.enterExcluded("setup")
		assert(timing.leaveExcluded("setup"), "B8 setup exclusion must remain clean")
		timing.enterExcluded("warmup")
		generation.transition({ kind = "BeginWarmup" })
		if participantRef.role == "Server" then
			for index = 1, #fixture.warmup do
				generation.transition({ kind = "OperationStarted", phase = "Warmup", fixtureIndex = index })
				generation.transition({ kind = "OperationReturned", phase = "Warmup", fixtureIndex = index })
			end
		else
			for _, sample in fixture.warmup do
				generation.observeDelivery(2, AdapterContract.recordDelivery(Fixtures.newInput(sample)), { kind = "ServerToClient" })
			end
		end
		assert(generation.status().phase == "WarmupDrained", "B8 warmup must drain")
		assert(timing.leaveExcluded("warmup"), "B8 warmup exclusion must remain clean")
		timing.enterExcluded("quiescence")
		for _ = 1, EventV1.execution.quiescenceFrames do generation.transition({ kind = "PostSimulation" }) end
		assert(timing.leaveExcluded("quiescence"), "B8 quiescence exclusion must remain clean")
		generation.transition({ kind = "ArmMeasured", startSharedSeconds = 0 })
		generation.transition({ kind = "BeginMeasured" })
		if repetitionIndex == 1 then
			assert(timing.recordClockProof({
				coordinatorBeforeSharedSeconds = 0,
				participantSharedSeconds = 0,
				coordinatorAfterSharedSeconds = 0,
				localBeforeSeconds = 0,
				localAfterSeconds = 0,
			}), "B8 clock proof must pass")
		end
		if participantRef.role == "Server" then
			if repetitionIndex < preparedBroadcast.caseDefinition.repetitions then
				for index = 1, #fixture.measured do
					timing.markLocal("MeasuredFrameStarted")
					if index == 1 then
						timing.markLocal("FirstMeasuredSubmissionStarted")
						timing.markShared("FirstMeasuredSubmissionStarted")
					end
					generation.transition({ kind = "OperationStarted", phase = "Measured", fixtureIndex = index })
					timing.markLocal("MeasuredSubmissionStarted")
					timing.markLocal("MeasuredSubmissionReturned")
					generation.transition({ kind = "OperationReturned", phase = "Measured", fixtureIndex = index })
					if index == #fixture.measured then
						timing.markLocal("FinalMeasuredSubmissionReturned")
						timing.markShared("FinalMeasuredSubmissionReturned")
					end
					timing.markLocal("FollowingFrameStarted")
				end
				generation.transition({ kind = "FinishMeasured", outcome = "Complete" })
			else
				generation.transition({ kind = "FinishMeasured", outcome = "Abort" })
			end
		else
			for _, sample in fixture.measured do
				generation.observeDelivery(2, AdapterContract.recordDelivery(Fixtures.newInput(sample)), { kind = "ServerToClient" })
			end
			local duplicate = AdapterContract.recordDelivery(Fixtures.newInput(fixture.measured[1]))
			for _ = 1, 3 * #fixture.measured do
				generation.observeDelivery(2, duplicate, { kind = "ServerToClient" })
			end
			if repetitionIndex < preparedBroadcast.caseDefinition.repetitions then
				generation.transition({ kind = "FinishMeasured", outcome = "Complete" })
			elseif overflow then
				generation.observeDelivery(2, duplicate, { kind = "ServerToClient" })
				assert(generation.status().phase == "Aborting", "B8 overflow client must abort")
			else
				generation.transition({ kind = "FinishMeasured", outcome = "Abort" })
			end
		end
		if generation.status().phase == "Verified" then
			timing.enterExcluded("quiescence")
			for _ = 1, EventV1.execution.quiescenceFrames do generation.transition({ kind = "PostSimulation" }) end
			assert(timing.leaveExcluded("quiescence"), "B8 post-measured quiescence must remain clean")
		end
		generation.transition({ kind = "BeginTeardown" })
		generation.transition({ kind = "FinishTeardown", clean = true })
		generation.transition({ kind = "FinishTeardownObservation" })
	end
	local result = participant.freeze()
	assert(result.kind == "Evidence", "B8 participant evidence must freeze")
	return result.value
end

local function abortedBroadcastCase(preparedBroadcast, participantEvidence)
	local case = RunState.newCase(preparedBroadcast, timeoutClock({ 0 }))
	local ready = { kind = "Ready", manifest = preparedBroadcast.manifest }
	table.freeze(ready)
	for repetitionIndex = 1, preparedBroadcast.caseDefinition.repetitions do
		case.acceptSession(repetitionIndex, ready :: any)
		case.transition({ kind = "MeasuredStarted", repetitionIndex = repetitionIndex })
		if repetitionIndex < preparedBroadcast.caseDefinition.repetitions then
			case.transition({
				kind = "RepetitionCompleted",
				repetitionIndex = repetitionIndex,
				finalOnlyEvidence = false,
			})
		else
			case.transition({ kind = "RepetitionAborted", repetitionIndex = repetitionIndex })
		end
	end
	local snapshots = {
		{ participant = { role = "Server" }, evidence = participantEvidence[1] },
	}
	for index = 1, 4 do
		table.insert(snapshots, {
			participant = { role = "Client", index = index },
			evidence = participantEvidence[index + 1],
		})
	end
	return case.snapshot(snapshots)
end

-- B8 accepts a broadcast overflow only when the independently frozen local
-- counts make the full 4x aggregate representable; the asymmetric arm stops.
do
	local preparedBroadcast = prepared({
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 4,
	})
	local evidence = {
		broadcastParticipantEvidence(preparedBroadcast, { role = "Server" }, false),
	}
	for index = 1, 4 do
		evidence[index + 1] = broadcastParticipantEvidence(
			preparedBroadcast,
			{ role = "Client", index = index },
			index == 1
		)
	end
	local representable = abortedBroadcastCase(preparedBroadcast, evidence)
	assert(representable.kind == "Snapshot", "B8 full 4x overflow aggregate must remain representable")
	local earlyOverflow = table.clone(evidence)
	earlyOverflow[2] = deepClone(evidence[2])
	earlyOverflow[2].repetitions[1].observationOverflow = true
	earlyOverflow[2].repetitions[preparedBroadcast.caseDefinition.repetitions].observationOverflow = false
	for _, fact in earlyOverflow[2].failureFacts do
		if fact.code == "DeliveryObservationLimitExceeded" then fact.firstRepetition = 1 end
	end
	deepFreeze(earlyOverflow[2])
	assertError(function() abortedBroadcastCase(preparedBroadcast, earlyOverflow) end,
		"RUN_STATE_E_CONFIG", "repetitions after callback overflow")

	local optionalEvidence = { deepClone(evidence[1]) }
	for index = 2, #evidence do optionalEvidence[index] = evidence[index] end
	for repetitionIndex = 1, preparedBroadcast.caseDefinition.repetitions - 1 do
		for measurementIndex, valueCount in {
			[11] = preparedBroadcast.caseDefinition.measuredFrames,
			[12] = preparedBroadcast.caseDefinition.measuredFrames * preparedBroadcast.caseDefinition.messagesPerFrame,
			[13] = 1,
			[14] = 1,
		} do
			table.insert(optionalEvidence[1].measurements, {
				measurementIndex = measurementIndex,
				repetitionIndex = repetitionIndex,
				values = table.create(valueCount, 1),
			})
		end
	end
	deepFreeze(optionalEvidence[1])
	local withOptional = abortedBroadcastCase(preparedBroadcast, optionalEvidence)
	assert(withOptional.kind == "Snapshot", "complete optional sender groups must remain representable")

	local partialCurrentEvidence = { deepClone(evidence[1]) }
	for index = 2, #evidence do partialCurrentEvidence[index] = evidence[index] end
	for _, measurementIndex in { 4, 11 } do
		table.insert(partialCurrentEvidence[1].measurements, {
			measurementIndex = measurementIndex,
			repetitionIndex = preparedBroadcast.caseDefinition.repetitions,
			values = { 1 },
		})
	end
	deepFreeze(partialCurrentEvidence[1])
	local withPartialCurrent = abortedBroadcastCase(preparedBroadcast, partialCurrentEvidence)
	assert(withPartialCurrent.kind == "Snapshot", "partial current-repetition measurements must remain representable")

	local noSenderAttempt = { deepClone(evidence[1]) }
	for index = 2, #evidence do noSenderAttempt[index] = evidence[index] end
	local finalEndpoint = noSenderAttempt[1].timingEndpoints[preparedBroadcast.caseDefinition.repetitions]
	finalEndpoint.firstSubmissionStartedSharedSeconds = nil
	finalEndpoint.finalSubmissionReturnedSharedSeconds = nil
	deepFreeze(noSenderAttempt[1])
	assert(abortedBroadcastCase(preparedBroadcast, noSenderAttempt).kind == "Snapshot",
		"armed sender without a measured attempt must remain reportable")

	local earlyReceiverEndpoint = {}
	for index = 1, #evidence do earlyReceiverEndpoint[index] = if index == 3 then deepClone(evidence[index]) else evidence[index] end
	local finalReceiver = earlyReceiverEndpoint[3].repetitions[preparedBroadcast.caseDefinition.repetitions]
	assert(finalReceiver.finalExpectedDeliveryReceivedSharedSeconds ~= nil, "receiver endpoint regression requires evidence")
	local removedCorrect = finalReceiver.correct - 1
	finalReceiver.correct = 1
	finalReceiver.received -= removedCorrect
	deepFreeze(earlyReceiverEndpoint[3])
	assertError(function()
		abortedBroadcastCase(preparedBroadcast, earlyReceiverEndpoint)
	end, "RUN_STATE_E_CONFIG", "receiver endpoint before full expected delivery")

	for _, code in { "IsolationFailure", "TeardownFailure" } do
		local ambiguousEvidence = {}
		for index = 1, #evidence do
			ambiguousEvidence[index] = if index == 1 or index == 3 then deepClone(evidence[index]) else evidence[index]
		end
		for _, participantIndex in { 1, 3 } do
			table.insert(ambiguousEvidence[participantIndex].failureFacts, {
				code = code,
				occurrences = 1,
				firstRepetition = 1,
			})
			deepFreeze(ambiguousEvidence[participantIndex])
		end
		local ambiguous = abortedBroadcastCase(preparedBroadcast, ambiguousEvidence)
		assert(ambiguous.kind == "Terminated"
			and ambiguous.termination.code == "FinalEvidenceUnrepresentable",
			`multi-participant {code} overlap must terminate`)
	end

	local asymmetric = { evidence[1], evidence[2] }
	for index = 3, 5 do
		local copied = deepClone(evidence[index])
		for repetitionIndex, repetition in copied.repetitions do
			if repetitionIndex < preparedBroadcast.caseDefinition.repetitions then
				repetition.received = preparedBroadcast.caseDefinition.measuredFrames
				repetition.correct = preparedBroadcast.caseDefinition.measuredFrames
			else
				repetition.received = 0
				repetition.correct = 0
				repetition.finalExpectedDeliveryReceivedSharedSeconds = nil
				repetition.finalExpectedDeliveryVerifiedSharedSeconds = nil
			end
			repetition.duplicate = 0
		end
		copied.failureFacts = {}
		deepFreeze(copied)
		asymmetric[index] = copied
	end
	local unrepresentable = abortedBroadcastCase(preparedBroadcast, asymmetric)
	assert(unrepresentable.kind == "Terminated"
		and unrepresentable.termination.code == "DistributedOverflowUnrepresentable",
		"B8 asymmetric overflow aggregate must terminate")
end

-- An old route retained across generation N+1 can mutate only generation N's
-- stale accumulator. Once participant evidence freezes, it is a permanent no-op.
do
	local participant = RunState.newParticipant(session.selection, { role = "Server" })
	local timing = TimingRecorder.new(
		session.caseDefinition,
		{ role = "Server" },
		BenchmarkClock.new(session.runtimeInputs.server.clocks)
	)
	local firstRoute = DeliveryRouter.newServer()
	local first = beginReceiverGeneration(participant, timing, 1, firstRoute)
	assert(timing.recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "retained-route clock proof must pass")
	first.transition({ kind = "FinishMeasured", outcome = "Abort" })
	first.transition({ kind = "BeginTeardown" })
	firstRoute.gate.beginTeardownObservation(first.staleHandler)
	first.transition({ kind = "FinishTeardown", clean = true })
	first.transition({ kind = "FinishTeardownObservation" })

	local secondRoute = DeliveryRouter.newServer()
	local second = beginReceiverGeneration(participant, timing, 2, secondRoute)
	local reads = 0
	local hostile = setmetatable({}, {
		__index = function()
			reads += 1
			error("retained stale callback traversed hostile input", 0)
		end,
	})
	firstRoute.sink(hostile, hostile)
	assert(reads == 0, "retained stale callback must ignore N+1 arguments")
	assert(second.status().phase == "Measured", "retained stale callback must not alter N+1 phase")
	second.transition({ kind = "FinishMeasured", outcome = "Abort" })
	second.transition({ kind = "BeginTeardown" })
	secondRoute.gate.beginTeardownObservation(second.staleHandler)
	second.transition({ kind = "FinishTeardown", clean = true })
	second.transition({ kind = "FinishTeardownObservation" })
	local frozen = participant.freeze()
	assert(frozen.kind == "Evidence", "two-generation stale evidence must freeze")
	assert(frozen.value.repetitions[1].staleCallbacks == 1, "retained route must charge generation N")
	assert(frozen.value.repetitions[2].staleCallbacks == 0, "retained route must not charge generation N+1")
	firstRoute.sink(hostile, hostile)
	assert(reads == 0 and participant.freeze() == frozen, "frozen retained route must remain an inert constant-space no-op")
end

local function abortFirstRepetition(preparedCase, snapshots)
	local case = RunState.newCase(preparedCase, timeoutClock({ 0 }))
	local ready = { kind = "Ready", manifest = preparedCase.manifest }
	table.freeze(ready)
	case.acceptSession(1, ready :: any)
	case.transition({ kind = "MeasuredStarted", repetitionIndex = 1 })
	case.transition({ kind = "RepetitionAborted", repetitionIndex = 1 })
	return case.snapshot(snapshots)
end

local function controlBinding(preparedCase, participantIndex)
	local value = {
		protocolVersion = 1,
		runId = "00000000-0000-4000-8000-000000000001",
		adapterId = "fake-event-v1",
		caseId = if preparedCase.selection.kind == "Workload"
			then preparedCase.selection.workloadId else preparedCase.selection.probeId,
		recipientCount = preparedCase.selection.clientProcessCount,
	}
	if participantIndex ~= nil then value.participantIndex = participantIndex end
	return value
end

-- A real RunState remote prefix survives FinalReport validation and can be
-- consumed by RunState again. Reverse-recorded discriminator groups prove the
-- schema order used at both boundaries, including distinct InternalError stages.
do
	local token = {}
	local created = ControlProtocol.newCoordinator(controlBinding(session), { token }, function() return 0 end, function() return true end)
	local coordinator = created.coordinator
	local participant = ControlProtocol.newParticipant(controlBinding(session, 1))
	local bind = coordinator.command(1, { kind = "BindCase" })
	participant.receive(bind.body)
	coordinator.receive(token, participant.report({ kind = "BoundReport" }).body)
	assert(coordinator.beginFinalReports("Abort", 0).kind == "Ready")
	participant.receive(coordinator.command(1, { kind = "FinishCase", repetitionIndex = 0, outcome = "Abort" }).body)

	local remote = RunState.newParticipant(session.selection, { role = "Client", index = 1 })
	for _, stage in { "Finalize", "Execution", "Setup" } do
		remote.recordFailure({
			code = "InternalError", occurrences = 1,
			discriminator = { kind = "Stage", value = stage },
		})
	end
	for _, exclusion in { "quiescence", "warmup", "setup" } do
		remote.recordFailure({
			code = "TimingExclusionViolation", occurrences = 1,
			discriminator = { kind = "TimingExclusion", value = exclusion },
		})
	end
	local evidence = deepClone(remote.freeze().value)
	evidence.conformance.setupExcluded = false
	evidence.conformance.warmupExcluded = false
	evidence.conformance.quiescenceExcluded = false
	deepFreeze(evidence)
	local final = participant.report({ kind = "FinalReport", snapshot = evidence })
	local accepted = coordinator.receive(token, final.body)
	assert(accepted.kind == "Accepted" and #accepted.event.snapshot.repetitions == 0,
		"pre-start FinalReport prefix must survive ControlProtocol")
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local result = case.snapshot(participantSnapshots(
		RunState.newParticipant(session.selection, { role = "Server" }).freeze().value,
		accepted.event.snapshot
	))
	assert(result.kind == "Snapshot", "pre-start FinalReport prefix must survive RunState")
end

do
	local token = {}
	local coordinator = ControlProtocol.newCoordinator(controlBinding(session), { token }, function() return 1 end, function() return true end).coordinator
	local participant = ControlProtocol.newParticipant(controlBinding(session, 1))
	local function exchange(commandIntent, reportIntent)
		local command = coordinator.command(1, commandIntent)
		participant.receive(command.body)
		return coordinator.receive(token, participant.report(reportIntent).body)
	end
	exchange({ kind = "BindCase" }, { kind = "BoundReport" })
	exchange({ kind = "PrepareRepetition", repetitionIndex = 1 }, { kind = "ReadyReport", outcome = "Ready" })
	exchange({ kind = "ClockChallenge" }, {
		kind = "ClockReply", participantSharedSeconds = 1, localBeforeSeconds = 1, localAfterSeconds = 1,
	})
	exchange({ kind = "BeginWarmup", repetitionIndex = 1 }, { kind = "WarmupReport", outcome = "Clean" })
	for _ = 1, 60 do coordinator.postSimulation(); participant.postSimulation() end
	participant.receive(coordinator.command(1, {
		kind = "ArmMeasured", repetitionIndex = 1, startSharedSeconds = 1,
	}).body)
	coordinator.beginPostTeardownObservation(1, true, false)
	participant.beginPostTeardownObservation(1)
	coordinator.receive(token, participant.report({
		kind = "RepetitionReport", outcome = "Abort", isolationPassed = true,
	}).body)
	coordinator.beginFinalReports("Abort", 1)
	participant.receive(coordinator.command(1, {
		kind = "FinishCase", repetitionIndex = 1, outcome = "Abort",
	}).body)
	local remote = markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	)
	local accepted = coordinator.receive(token, participant.report({ kind = "FinalReport", snapshot = remote }).body)
	assert(accepted.kind == "Accepted" and #accepted.event.snapshot.repetitions == 1,
		"mid-case FinalReport prefix must survive ControlProtocol")
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	local ready = { kind = "Ready", manifest = session.manifest }
	table.freeze(ready)
	case.acceptSession(1, ready :: any)
	case.transition({ kind = "MeasuredStarted", repetitionIndex = 1 })
	case.recordFailure({ code = "Timeout", occurrences = 1, firstRepetition = 1 })
	case.transition({ kind = "RepetitionAborted", repetitionIndex = 1 })
	local result = case.snapshot(participantSnapshots(
		markFirstRepetitionStarted(RunState.newParticipant(session.selection, { role = "Server" }).freeze().value, true),
		accepted.event.snapshot
	))
	assert(result.kind == "Snapshot", "mid-case FinalReport prefix must survive RunState")
end

-- A workload sender's first adapter call may throw before any submission
-- returns; the shared first endpoint is the attempt proof that keeps the
-- resulting SubmitFailure reportable.
do
	local serverEvidence = RunState.newParticipant(session.selection, { role = "Server" }).freeze().value
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.repetitions[1].firstSubmissionStartedSharedSeconds = 1
	clientEvidence.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	deepFreeze(clientEvidence)
	local result = abortFirstRepetition(session, participantSnapshots(
		markFirstRepetitionStarted(serverEvidence, true),
		clientEvidence
	))
	assert(result.kind == "Snapshot", "first-call workload throw must remain reportable")
end

-- InputMutation is causal only when the mutating sender accepted an operation
-- in the current globally incomplete repetition.
do
	local serverEvidence = markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Server" }).freeze().value,
		true
	)
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.failureFacts = {{ code = "InputMutation", occurrences = 1 }}
	deepFreeze(clientEvidence)
	assertError(function()
		abortFirstRepetition(session, participantSnapshots(serverEvidence, clientEvidence))
	end, "RUN_STATE_E_CONFIG", "input mutation without a current accepted workload operation")

	clientEvidence = deepClone(clientEvidence)
	clientEvidence.repetitions[1].submitted = 1
	clientEvidence.repetitions[1].firstSubmissionStartedSharedSeconds = 1
	clientEvidence.repetitions[1].finalSubmissionReturnedSharedSeconds = 2
	deepFreeze(clientEvidence)
	local result = abortFirstRepetition(session, participantSnapshots(serverEvidence, clientEvidence))
	assert(result.kind == "Snapshot", "current accepted workload mutation must remain reportable")
end

-- A locally completed receiver is valid only for the current repetition and
-- only when at least one sender snapshot carries causal mutation evidence.
do
	local serverEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Server" }).freeze().value,
		true
	))
	serverEvidence.repetitions[1].completed = true
	serverEvidence.repetitions[1].received = 120
	serverEvidence.repetitions[1].correct = 120
	serverEvidence.timingEndpoints[1].finalExpectedDeliveryReceivedSharedSeconds = 1
	serverEvidence.timingEndpoints[1].finalExpectedDeliveryVerifiedSharedSeconds = 2
	deepFreeze(serverEvidence)
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.repetitions[1].submitted = 1
	clientEvidence.repetitions[1].firstSubmissionStartedSharedSeconds = 1
	clientEvidence.repetitions[1].finalSubmissionReturnedSharedSeconds = 2
	clientEvidence.failureFacts = {{ code = "InputMutation", occurrences = 1 }}
	deepFreeze(clientEvidence)
	local result = abortFirstRepetition(session, participantSnapshots(serverEvidence, clientEvidence))
	assert(result.kind == "Snapshot", "caused current receiver completion must remain reportable")

	local noCause = deepClone(clientEvidence)
	noCause.failureFacts = {}
	deepFreeze(noCause)
	local rejected = abortFirstRepetition(session, participantSnapshots(serverEvidence, noCause))
	assert(rejected.kind == "Terminated" and rejected.termination.code == "FinalEvidenceUnrepresentable",
		"extra receiver completion without sender mutation must terminate")
end

-- A remote probe timeout can abort without inventing a coordinator-owned
-- timeout cause. Its pending-sample evidence yields the bounded no-Result arm.
do
	local probeCase = prepared({ kind = "SeparateProbe", probeId = "tiny-round-trip" })
	local serverEvidence = markFirstRepetitionStarted(
		RunState.newParticipant(probeCase.selection, { role = "Server" }).freeze().value, true
	)
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(probeCase.selection, { role = "ProbeClient", index = 1 }).freeze().value, false
	))
	clientEvidence.repetitions[1].probeStarted = 1
	clientEvidence.repetitions[1].probeSubmitted = 1
	deepFreeze(clientEvidence)
	local result = abortFirstRepetition(probeCase, {
		{ participant = { role = "Server" }, evidence = serverEvidence },
		{ participant = { role = "ProbeClient", index = 1 }, evidence = clientEvidence },
	})
	assert(result.kind == "Terminated" and result.termination.code == "FinalEvidenceUnrepresentable"
		and result.termination.stage == "Execution", "unproven client timeout must retain bounded no-Result disposition")
end

-- Probe client and server SubmitFailure facts likewise require the role's
-- own attempt-minus-return evidence, rather than the generic started bit.
do
	local probeCase = prepared({ kind = "SeparateProbe", probeId = "tiny-round-trip" })
	local serverEvidence = RunState.newParticipant(probeCase.selection, { role = "Server" }).freeze().value
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(probeCase.selection, { role = "ProbeClient", index = 1 }).freeze().value,
		false
	))
	clientEvidence.repetitions[1].probeStarted = 1
	clientEvidence.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	deepFreeze(clientEvidence)
	local result = abortFirstRepetition(probeCase, {
		{ participant = { role = "Server" }, evidence = markFirstRepetitionStarted(serverEvidence, true) },
		{ participant = { role = "ProbeClient", index = 1 }, evidence = clientEvidence },
	})
	assert(result.kind == "Snapshot", "probe-client first-call throw must remain reportable")
end

do
	local probeCase = prepared({ kind = "SeparateProbe", probeId = "tiny-round-trip" })
	local serverEvidence = deepClone(RunState.newParticipant(probeCase.selection, { role = "Server" }).freeze().value)
	serverEvidence.repetitions[1].started = true
	serverEvidence.repetitions[1].probeRequestsReceived = 1
	serverEvidence.repetitions[1].probeRequestsCorrect = 1
	serverEvidence.timingEndpoints = {{ repetitionIndex = 1 }}
	serverEvidence.failureFacts = {{ code = "SubmitFailure", occurrences = 1, firstRepetition = 1 }}
	local returnedEvidence = deepClone(serverEvidence)
	returnedEvidence.repetitions[1].probeResponsesSubmitted = 1
	deepFreeze(returnedEvidence)
	local clientEvidence = RunState.newParticipant(probeCase.selection, { role = "ProbeClient", index = 1 }).freeze().value
	assertError(function()
		abortFirstRepetition(probeCase, {
			{ participant = { role = "Server" }, evidence = returnedEvidence },
			{ participant = { role = "ProbeClient", index = 1 }, evidence = markFirstRepetitionStarted(clientEvidence, false) },
		})
	end, "RUN_STATE_E_CONFIG", "probe-server SubmitFailure without an unreturned response")
	deepFreeze(serverEvidence)
	local result = abortFirstRepetition(probeCase, {
		{ participant = { role = "Server" }, evidence = serverEvidence },
		{ participant = { role = "ProbeClient", index = 1 }, evidence = markFirstRepetitionStarted(clientEvidence, false) },
	})
	assert(result.kind == "Snapshot", "probe-server first-response throw must remain reportable")
end

-- Signed zero is meaningful mismatch diagnostic data and must survive the
-- participant fact sanitizer bit-for-bit.
do
	local broadcast = prepared({
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 1,
	})
	local participant = RunState.newParticipant(broadcast.selection, { role = "Client", index = 1 })
	assert(participant.recordFailure({
		code = "PayloadMismatch",
		occurrences = 1,
		discriminator = { kind = "MismatchReason", value = "ValueMismatch" },
		firstRepetition = 1,
		fixtureIndex = 1,
		mismatch = { pathKind = "Field", fieldIndex = 4, actual = -0.0 },
	}).kind == "Recorded")
	local evidence = participant.freeze()
	assert(evidence.kind == "Evidence")
	local actual = evidence.value.failureFacts[1].mismatch.actual
	assert(actual == 0 and 1 / actual == -math.huge, "signed-zero mismatch actual must be preserved")
end

-- Descriptor-impossible mismatch facts are rejected at the RunState trust
-- boundary even when their aggregate counters are otherwise self-consistent.
do
	local broadcast = prepared({
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 1,
	})
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(broadcast.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.repetitions[1].received = 1
	clientEvidence.repetitions[1].mismatch = 1
	clientEvidence.failureFacts = {{
		code = "PayloadMismatch",
		occurrences = 1,
		discriminator = { kind = "MismatchReason", value = "ValueMismatch" },
		firstRepetition = 1,
		fixtureIndex = 1,
		mismatch = {
			pathKind = "Field",
			fieldIndex = 4,
			actual = Fixtures.generate("state-broadcast-s2c", 1).measured[1].expected.yaw,
		},
	}}
	deepFreeze(clientEvidence)
	assertError(function()
		abortFirstRepetition(broadcast, {
			{ participant = { role = "Server" }, evidence = markFirstRepetitionStarted(
				RunState.newParticipant(broadcast.selection, { role = "Server" }).freeze().value,
				true
			) },
			{ participant = { role = "Client", index = 1 }, evidence = clientEvidence },
		})
	end, "RUN_STATE_E_CONFIG", "equal ValueMismatch fact")
end

-- Repetition-owned facts cannot claim more occurrences than the retained tail.
for _, code in { "TeardownFailure", "IsolationFailure" } do
	local clientEvidence = deepClone(markFirstRepetitionStarted(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value,
		false
	))
	clientEvidence.failureFacts = {{ code = code, occurrences = 2, firstRepetition = 1 }}
	deepFreeze(clientEvidence)
	assertError(function()
		abortFirstRepetition(session, participantSnapshots(
			markFirstRepetitionStarted(RunState.newParticipant(session.selection, { role = "Server" }).freeze().value, true),
			clientEvidence
		))
	end, "RUN_STATE_E_CONFIG", `{code} occurrence tail`)
end

-- Imported pre-start teardown evidence is representable only as fallout from
-- a matching setup failure; a teardown-only remote snapshot is hostile.
do
	local clientEvidence = deepClone(
		RunState.newParticipant(session.selection, { role = "Client", index = 1 }).freeze().value
	)
	clientEvidence.failureFacts = {{ code = "TeardownFailure", occurrences = 1 }}
	deepFreeze(clientEvidence)
	local case = RunState.newCase(session, timeoutClock({ 0 }))
	case.transition({ kind = "AbortRemaining" })
	assertError(function()
		case.snapshot(participantSnapshots(
			RunState.newParticipant(session.selection, { role = "Server" }).freeze().value,
			clientEvidence
		))
	end, "RUN_STATE_E_CONFIG", "pre-start teardown without setup failure")
end

print("PASS Relay.Benchmarks.RunState")
