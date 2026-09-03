local AdapterContract = require("../adapters/AdapterContract")
local BenchmarkClock = require("../runner/BenchmarkClock")
local Fixtures = require("../fixtures/event-v1")
local GenerationActivation = require("../runner/GenerationActivation")
local RunState = require("../runner/RunState")
local SessionOwner = require("../runner/SessionOwner")
local TimingRecorder = require("../runner/TimingRecorder")

local STUDIO_VERSION = "0.650.0.6500000"

local function assertExactKeys(value, keys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local expected = {}
	for _, key in keys do
		expected[key] = true
	end
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

local function assertTermination(result, code, stage, label)
	assertExactKeys(result, { "kind", "termination" }, label)
	assert(result.kind == "Terminated", `{label} must terminate`)
	assertExactKeys(result.termination, { "kind", "code", "stage" }, `{label} termination`)
	assert(result.termination.kind == "RelayHarnessTerminationV1", `{label} termination kind differs`)
	assert(result.termination.code == code, `{label} code differs`)
	assert(result.termination.stage == stage, `{label} stage differs`)
	assert(table.isfrozen(result), `{label} must be frozen`)
	assert(table.isfrozen(result.termination), `{label} termination must be frozen`)
end

local function repositoryIdentity()
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

local function manifest(identity, selection)
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
				digest = identity.library.provenance.checksum,
			},
			identity = identity,
		},
		selection = selection,
		environment = {
			studio = {
				version = STUDIO_VERSION,
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
end

local function newFactory(control)
	local contexts = { server = nil, client = nil }

	local function makeSide(context, label)
		local side = {
			setup = function()
				table.insert(control.log, `setup:{label}`)
				if control.sinkDuringSetup == label then
					context.sink()
				end
				if control.setupFault == label then
					error("hostile setup detail", 0)
				end
				if control.setupYield == label then
					control.setupThread = coroutine.running()
					coroutine.yield()
					control.setupResumed = true
				end
			end,
			ready = function()
				control.readyCalls[label] += 1
				table.insert(control.log, `ready:{label}`)
				if control.sinkDuringReady == label then
					context.sink()
				end
				if control.readyFault == label then
					error("hostile ready detail", 0)
				end
				local sequence = control.readySequence[label]
				local value = sequence[control.readyCalls[label]]
				if value == nil then
					return sequence[#sequence]
				end
				return value
			end,
			teardown = function()
				table.insert(control.log, `teardown:{label}`)
				if control.teardownFault == label then
					error("hostile teardown detail", 0)
				end
			end,
		}
		if context.selection.kind == "SeparateProbe" then
			if label == "server" then
				side.broadcast = function() end
			else
				side.submit = function() end
			end
		elseif context.selection.direction == "ClientToServer" and label == "client" then
			side.submit = function() end
		elseif context.selection.direction == "ServerToClient" and label == "server" then
			side.broadcast = function() end
		end
		return side
	end

	return {
		constructServer = function(context)
			contexts.server = context
			table.insert(control.log, "construct:server")
			return makeSide(context, "server")
		end,
		constructClient = function(context)
			contexts.client = context
			table.insert(control.log, "construct:client")
			return makeSide(context, "client")
		end,
	}, contexts
end

local function newControl(options)
	options = options or {}
	return {
		log = {},
		readyCalls = { server = 0, client = 0 },
		readySequence = options.readySequence or { server = { true }, client = { true } },
		setupFault = options.setupFault,
		setupYield = options.setupYield,
		setupResumed = false,
		readyFault = options.readyFault,
		teardownFault = options.teardownFault,
		sinkDuringSetup = options.sinkDuringSetup,
		sinkDuringReady = options.sinkDuringReady,
		connectorFault = options.connectorFault,
		connectorExtra = options.connectorExtra,
		connectorNonfunction = options.connectorNonfunction,
		rootFault = options.rootFault,
		serverTimeout = 0,
		clientTimeout = 0,
		serverTimeoutReads = 0,
		clientTimeoutReads = 0,
		localClockFault = { server = false, client = false },
		producers = {},
		rootCalls = 0,
		destroyCalls = 0,
	}
end

local function newProcess(control, label)
	local timeoutReadsKey = if label == "server" then "serverTimeoutReads" else "clientTimeoutReads"
	return {
		clocks = {
			localNowSeconds = function()
				if control.localClockFault[label] then
					error("local clock fault", 0)
				end
				return 0
			end,
			sharedNowSeconds = function()
				return 0
			end,
			timeoutNowSeconds = function()
				control[timeoutReadsKey] += 1
				table.insert(control.log, `clock:{label}:timeout`)
				return if label == "server" then control.serverTimeout else control.clientTimeout
			end,
		},
		postSimulation = {
			connectPostSimulation = function(callback)
				table.insert(control.log, `connect:{label}`)
				if control.connectorFault == label then
					error("hostile connector detail", 0)
				end
				if control.connectorNonfunction == label then
					return nil
				end
				control.producers[label] = callback
				local disconnect = function()
					control.producers[label] = nil
					table.insert(control.log, `disconnect:{label}`)
				end
				if control.connectorExtra == label then
					return disconnect, "extra"
				end
				return disconnect
			end,
		},
	}
end

local function buildRig(options)
	options = options or {}
	local control = newControl(options)
	local identity = repositoryIdentity()
	local selection = options.selection or {
		kind = "Workload",
		workloadId = "tiny-steady-c2s",
		recipientCount = 1,
	}
	local server = newProcess(control, "server")
	server.clientTokens = { "client-1" }
	local preparedResult = SessionOwner.prepare(manifest(identity, selection), identity, {
		server = server,
		clients = { newProcess(control, "client") },
	})
	assert(preparedResult.kind == "Prepared", "valid activation rig must prepare")
	local prepared = preparedResult.value
	local caseClock = BenchmarkClock.new(prepared.runtimeInputs.server.clocks)
	local caseState = RunState.newCase(prepared, caseClock)
	local factory, contexts = newFactory(control)
	local rootFactory = function()
		control.rootCalls += 1
		table.insert(control.log, "construct:root")
		return {
			resourceRoot = { id = "generation-root" },
			destroy = function()
				control.destroyCalls += 1
				table.insert(control.log, "destroy:root")
				if control.rootFault then
					error("hostile root detail", 0)
				end
			end,
		}
	end
	local session = SessionOwner.openPrepared(prepared, factory, rootFactory)
	assert(session.kind == "Ready", `valid activation rig must open: {session.kind}`)
	caseState.acceptSession(1, session)

	local participantStates = {}
	local timingRecorders = {}
	for index, port in session.ports do
		participantStates[index] = RunState.newParticipant(prepared.selection, port.participant)
		timingRecorders[index] = TimingRecorder.new(
			prepared.caseDefinition,
			port.participant,
			BenchmarkClock.new(port.clocks)
		)
	end
	table.freeze(participantStates)
	table.freeze(timingRecorders)
	local fixture = if prepared.selection.kind == "SeparateProbe"
		then Fixtures.generateProbe(prepared.selection.probeId, 1)
		else Fixtures.generate(prepared.selection.workloadId, 1)
	return {
		adapterFactory = factory,
		control = control,
		prepared = prepared,
		rootFactory = rootFactory,
		caseState = caseState,
		session = session,
		participantStates = participantStates,
		timingRecorders = timingRecorders,
		fixture = fixture,
		identity = identity,
		selectionInput = selection,
		contexts = contexts,
	}
end

local function beginRig(rig)
	return GenerationActivation.begin(
		rig.session,
		rig.caseState,
		rig.participantStates,
		rig.fixture,
		rig.timingRecorders
	)
end

local function serverReady(rig)
	local result = {
		kind = "Ready",
		manifest = rig.session.manifest,
		port = rig.session.ports[1],
		closeGenerationRoot = rig.session.closeGenerationRoot,
	}
	table.freeze(result)
	return result
end

local function clientReady(rig)
	local result = {
		kind = "Ready",
		port = rig.session.ports[2],
	}
	table.freeze(result)
	return result
end

local function indexOf(values, expected)
	for index, value in values do
		if value == expected then
			return index
		end
	end
	return nil
end

assertExactKeys(GenerationActivation, { "READY_TIMEOUT_SECONDS", "begin", "beginLocal" }, "GenerationActivation")
assert(GenerationActivation.READY_TIMEOUT_SECONDS == 120, "readiness timeout constant differs")
assert(type(GenerationActivation.begin) == "function", "begin must be a function")
assert(type(GenerationActivation.beginLocal) == "function", "beginLocal must be a function")
assert(table.isfrozen(GenerationActivation), "GenerationActivation must be frozen")

-- All producers attach before server-then-client setup. Readiness polling is
-- at-most-once per pending side per poll and only the server CaseState clock is
-- used for the shared readiness deadline.
do
	local rig = buildRig({
		readySequence = { server = { false, true }, client = { true } },
	})
	rig.control.log = {}
	local activation = beginRig(rig)
	assertExactKeys(activation, { "poll" }, "Activation")
	assert(table.isfrozen(activation), "Activation must be frozen")
	local first = activation.poll()
	assertExactKeys(first, { "kind" }, "pending activation")
	assert(first.kind == "Pending" and table.isfrozen(first), "first poll must be frozen Pending")
	assert(rig.control.readyCalls.server == 1 and rig.control.readyCalls.client == 1, "first poll must call every pending side once")

	local connectServer = indexOf(rig.control.log, "connect:server")
	local connectClient = indexOf(rig.control.log, "connect:client")
	local setupServer = indexOf(rig.control.log, "setup:server")
	local setupClient = indexOf(rig.control.log, "setup:client")
	local readyServer = indexOf(rig.control.log, "ready:server")
	assert(connectServer ~= nil and connectClient ~= nil and setupServer ~= nil and setupClient ~= nil, "activation ordering log is incomplete")
	assert(connectServer < connectClient and connectClient < setupServer and setupServer < setupClient, "attach/setup ordering differs")
	assert(indexOf(rig.control.log, "clock:server:timeout") < readyServer, "readiness deadline must start before polling")
	assert(rig.control.clientTimeoutReads == 0, "client clocks must not decide readiness")

	local second = activation.poll()
	assertExactKeys(second, { "kind", "kernels" }, "ready activation")
	assert(second.kind == "Ready", "second poll must become Ready")
	assert(table.isfrozen(second) and table.isfrozen(second.kernels), "Ready result and kernel array must be frozen")
	assert(#second.kernels == 2, "Ready must return server-then-client kernels")
	assert(rig.control.readyCalls.server == 2 and rig.control.readyCalls.client == 1, "already-ready side must not be polled again")
	assert(rig.control.clientTimeoutReads == 0, "later polls must still use only CaseState's server clock")
	assertError(activation.poll, "GENERATION_ACTIVATION_E_STATE", "poll after Ready")
end

-- Sender-token ownership differs across the broadcast and probe topologies.
-- Both must activate through the same server-then-client composition without
-- exposing a caller-built state port or recorder bundle.
for label, selection in {
	broadcast = {
		kind = "Workload",
		workloadId = "state-broadcast-s2c",
		recipientCount = 1,
	},
	probe = {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
	},
} do
	local rig = buildRig({ selection = selection })
	local result = beginRig(rig).poll()
	assert(result.kind == "Ready", `{label} topology must activate`)
	assert(#result.kernels == 2, `{label} topology kernel count differs`)
end

-- Setup/attach failures collapse to the fixed setup arm after complete reverse
-- rollback and exactly one root close.
do
	local rig = buildRig({ setupFault = "server" })
	rig.control.log = {}
	local activation = beginRig(rig)
	local result = activation.poll()
	assertExactKeys(result, { "kind", "manifest" }, "setup failure")
	assert(result.kind == "SetupFailed" and result.manifest == rig.session.manifest, "setup failure projection differs")
	assert(table.isfrozen(result), "setup failure must be frozen")
	local teardownClient = indexOf(rig.control.log, "teardown:client")
	local teardownServer = indexOf(rig.control.log, "teardown:server")
	local destroyRoot = indexOf(rig.control.log, "destroy:root")
	assert(teardownClient < teardownServer and teardownServer < destroyRoot, "rollback must clean in reverse order before root close")
	assert(rig.control.destroyCalls == 1, "rollback must close the root once")
	assertError(activation.poll, "GENERATION_ACTIVATION_E_STATE", "poll after setup failure")
end

-- The kernel rejects yielding setup, but the adapter must leave its setup
-- transition before rollback so partially created resources can be released.
for _, label in { "server", "client" } do
	local rig = buildRig({ setupYield = label })
	local result = beginRig(rig).poll()
	assert(indexOf(rig.control.log, `teardown:{label}`) ~= nil,
		`yielding {label} setup must still invoke raw teardown`)
	assert(result.kind == "SetupFailed", "yielding setup with proven cleanup must remain SetupFailed")
	assert(rig.control.producers.server == nil and rig.control.producers.client == nil,
		"yielding setup rollback must disconnect every producer")
	assert(rig.control.destroyCalls == 1, "yielding setup rollback must close the root exactly once")
	assert(coroutine.status(rig.control.setupThread) == "dead", "yielding setup coroutine must be closed")
	assert(coroutine.resume(rig.control.setupThread) == false and not rig.control.setupResumed,
		"setup must not resume after rollback")
end

do
	local rig = buildRig({ connectorFault = "server" })
	rig.control.log = {}
	local result = beginRig(rig).poll()
	assert(result.kind == "SetupFailed", "throwing frame connector must collapse to SetupFailed")
	assert(indexOf(rig.control.log, "setup:server") == nil, "setup must not begin after attach failure")
	assert(rig.control.destroyCalls == 1, "attach rollback must close root once")
end

-- A malformed trusted connector is the InternalInvariant fallback, while an
-- unclosable connector takes cleanup precedence.
do
	local rig = buildRig({ connectorExtra = "server" })
	rig.control.log = {}
	local result = beginRig(rig).poll()
	assertExactKeys(result, { "kind", "manifest" }, "internal activation failure")
	assert(result.kind == "InternalFailed" and result.manifest == rig.session.manifest, "internal fallback differs")
	assert(rig.control.destroyCalls == 1, "internal rollback must close root")
end

do
	local rig = buildRig()
	-- The CaseState already established the whole-case deadline at zero. A
	-- non-monotonic readiness sample is sanitized by the private server clock
	-- and projected only as InternalFailed after rollback.
	rig.control.serverTimeout = -1
	local result = beginRig(rig).poll()
	assert(result.kind == "InternalFailed", "readiness clock failure must be InternalFailed")
	assert(rig.control.clientTimeoutReads == 0, "clock failure must not consult client clocks")
	assert(rig.control.destroyCalls == 1, "clock failure rollback must close root")
end

do
	local rig = buildRig({ connectorNonfunction = "server" })
	rig.control.log = {}
	assertTermination(beginRig(rig).poll(), "CleanupFailure", "Finalize", "unclosable connector")
	assert(rig.control.destroyCalls == 1, "unclosable connector rollback must still close root")
end

-- Ready exceptions are SetupFailed. A pre-arm callback always outranks that
-- fallback, and cleanup failure outranks both.
do
	local rig = buildRig({ readyFault = "server" })
	local result = beginRig(rig).poll()
	assert(result.kind == "SetupFailed", "ready failure must collapse to SetupFailed")
	assert(rig.control.readyCalls.server == 1 and rig.control.readyCalls.client == 0, "ready failure must stop later ready calls")
end

do
	local rig = buildRig({ readyFault = "server", sinkDuringReady = "server" })
	assertTermination(beginRig(rig).poll(), "ControlProtocolRejected", "Setup", "pre-ready precedence")
	assert(rig.control.destroyCalls == 1, "pre-ready rollback must close root")
end

do
	local rig = buildRig({
		readyFault = "server",
		sinkDuringReady = "server",
		teardownFault = "client",
	})
	assertTermination(beginRig(rig).poll(), "CleanupFailure", "Finalize", "cleanup precedence")
	assert(rig.control.destroyCalls == 1, "cleanup failure must not skip root close")
	assert(indexOf(rig.control.log, "teardown:client") < indexOf(rig.control.log, "teardown:server"), "rollback must continue after teardown failure")
end

do
	local rig = buildRig({ sinkDuringSetup = "server" })
	assertTermination(beginRig(rig).poll(), "ControlProtocolRejected", "Setup", "arm pre-ready violation")
end

do
	local rig = buildRig({ setupFault = "server", rootFault = true })
	assertTermination(beginRig(rig).poll(), "CleanupFailure", "Finalize", "root cleanup precedence")
	assert(rig.control.destroyCalls == 1, "throwing root destroy must not be retried")
end

-- Readiness expiry is checked before another ready call, uses deadline
-- equality, and collapses to the one pre-start setup failure.
do
	local rig = buildRig({
		readySequence = { server = { false, true }, client = { true } },
	})
	local activation = beginRig(rig)
	assert(activation.poll().kind == "Pending", "timeout rig must first pend")
	rig.control.serverTimeout = 120
	local result = activation.poll()
	assert(result.kind == "SetupFailed", "readiness equality must expire as SetupFailed")
	assert(rig.control.readyCalls.server == 1 and rig.control.readyCalls.client == 1, "expired poll must not call ready again")
	assert(rig.control.clientTimeoutReads == 0, "readiness timeout must not read a client clock")
end

-- Trusted configuration is rejected before activation side effects.
do
	local rig = buildRig()
	local shortStates = { rig.participantStates[1] }
	table.freeze(shortStates)
	assertError(function()
		GenerationActivation.begin(
			rig.session,
			rig.caseState,
			shortStates,
			rig.fixture,
			rig.timingRecorders
		)
	end, "GENERATION_ACTIVATION_E_CONFIG", "short participant state array")
	assert(indexOf(rig.control.log, "connect:server") == nil, "config rejection must not attach a producer")
end

do
	local rig = buildRig()
	local reversed = { rig.participantStates[2], rig.participantStates[1] }
	table.freeze(reversed)
	assertError(function()
		GenerationActivation.begin(
			rig.session,
			rig.caseState,
			reversed,
			rig.fixture,
			rig.timingRecorders
		)
	end, "GENERATION_ACTIVATION_E_CONFIG", "participant ordering mismatch")
end

-- A distributed server activation owns exactly one kernel and its generation
-- root. Readiness does not arm the gate, and rollback is cached.
do
	local rig = buildRig({
		readySequence = { server = { false, true }, client = { true } },
	})
	local activation = GenerationActivation.beginLocal(
		serverReady(rig),
		rig.participantStates[1],
		rig.fixture,
		rig.timingRecorders[1],
		rig.caseState
	)
	assertExactKeys(activation, { "pollReady", "arm", "rollback" }, "server local activation")
	assert(table.isfrozen(activation), "server local activation must be frozen")
	assert(activation.pollReady().kind == "Pending", "server local readiness must preserve Pending")
	assert(activation.pollReady().kind == "ReadyToArm", "server local readiness must stop before arm")
	assert(rig.control.destroyCalls == 0, "server root must remain open before rollback")
	local armed = activation.arm()
	assertExactKeys(armed, { "kind", "kernel" }, "server local arm")
	assert(armed.kind == "Ready" and table.isfrozen(armed), "server local arm must return its frozen kernel")
	local rolledBack = activation.rollback()
	assertExactKeys(rolledBack, { "kind" }, "server local rollback")
	assert(rolledBack.kind == "Clean" and table.isfrozen(rolledBack), "server local rollback must be clean")
	assert(rig.control.destroyCalls == 1, "server local rollback must close its root once")
	assert(rawequal(activation.rollback(), rolledBack), "server local rollback must return its cached result")
	assert(rig.control.destroyCalls == 1, "cached server rollback must not close its root again")
end

-- A distributed client has no CaseState or root authority. A callback between
-- ReadyToArm and arm is the fixed pre-ready violation and still cleans locally.
do
	local rig = buildRig()
	local activation = GenerationActivation.beginLocal(
		clientReady(rig),
		rig.participantStates[2],
		rig.fixture,
		rig.timingRecorders[2],
		nil
	)
	assert(activation.pollReady().kind == "ReadyToArm", "client local readiness must stop before arm")
	rig.contexts.client.sink()
	local armResult = activation.arm()
	assertExactKeys(armResult, { "kind" }, "client pre-ready arm")
	assert(armResult.kind == "PreReadyViolation" and table.isfrozen(armResult), "client pre-ready arm differs")
	assertTermination(activation.rollback(), "ControlProtocolRejected", "Setup", "client pre-ready rollback")
	assert(rig.control.destroyCalls == 0, "client rollback must not close the server root")
	assert(rig.session.closeGenerationRoot() == nil, "test root close must remain clean")
end

-- A distributed client has no generation-root cleanup fallback. Teardown
-- completion that the adapter proof cannot establish must terminate directly
-- at the local kernel cleanup boundary.
for _, behavior in { "Yield", "Extra" } do
	local rig = buildRig()
	local supported = AdapterContract.preflight(rig.identity, rig.selectionInput, STUDIO_VERSION)
	assert(supported.kind == "Supported", `{behavior} client teardown preflight must be supported`)
	local baseFactory = rig.adapterFactory
	local teardownResumed = false
	local factory = {
		constructServer = baseFactory.constructServer,
		constructClient = function(context)
			local side = baseFactory.constructClient(context)
			local wrapped = {}
			for key, value in next, side do
				wrapped[key] = value
			end
			local rawTeardown = side.teardown
			wrapped.teardown = function()
				if behavior == "Yield" then
					coroutine.yield()
					teardownResumed = true
					return
				end
				rawTeardown()
				return "extra"
			end
			table.freeze(wrapped)
			return wrapped
		end,
	}
	local opened = SessionOwner.openClient(
		supported,
		factory,
		table.freeze({ id = `{behavior}-client-root` }),
		1,
		rig.prepared.runtimeInputs.clients[1]
	)
	assert(opened.kind == "Ready", `{behavior} distributed client must open`)
	local participantState = RunState.newParticipant(opened.port.selection, opened.port.participant)
	local timing = TimingRecorder.new(
		rig.prepared.caseDefinition,
		opened.port.participant,
		BenchmarkClock.new(opened.port.clocks)
	)
	local activation = GenerationActivation.beginLocal(opened, participantState, rig.fixture, timing, nil)
	assert(activation.pollReady().kind == "ReadyToArm", `{behavior} distributed client must become ready`)
	local armed = activation.arm()
	assert(armed.kind == "Ready", `{behavior} distributed client must arm`)
	armed.kernel.command({ kind = "AbortBeforeMeasured" })
	armed.kernel.beginTeardownObservation()
	local teardownResult = armed.kernel.teardown()
	assertTermination(teardownResult, "CleanupFailure", "Finalize",
		`{behavior} distributed client teardown ({tostring(teardownResult.termination.code)}/{tostring(teardownResult.termination.stage)})`)
	assert(not teardownResumed, "yielding distributed client teardown must never resume")
	assert(rig.session.closeGenerationRoot() == nil, `{behavior} test root must remain independently clean`)
end

-- Role ownership is checked before participant-generation side effects.
do
	local serverRig = buildRig()
	assertError(function()
		GenerationActivation.beginLocal(
			serverReady(serverRig),
			serverRig.participantStates[1],
			serverRig.fixture,
			serverRig.timingRecorders[1],
			nil
		)
	end, "GENERATION_ACTIVATION_E_CONFIG", "local server without CaseState")
	assert(serverRig.session.closeGenerationRoot() == nil, "rejected server local config must retain caller root ownership")

	local clientRig = buildRig()
	assertError(function()
		GenerationActivation.beginLocal(
			clientReady(clientRig),
			clientRig.participantStates[2],
			clientRig.fixture,
			clientRig.timingRecorders[2],
			clientRig.caseState
		)
	end, "GENERATION_ACTIVATION_E_CONFIG", "local client with CaseState")
	assert(clientRig.session.closeGenerationRoot() == nil, "rejected client local config must retain caller root ownership")
end

-- Malformed trusted selection data must reach the fixed configuration error,
-- never a raw mixed-type comparison while checking the participant index.
do
	local rig = buildRig()
	local badSelection = {}
	for key, value in rig.session.ports[2].selection do
		badSelection[key] = value
	end
	badSelection.clientProcessCount = "1"
	table.freeze(badSelection)
	local badPort = {}
	for key, value in rig.session.ports[2] do
		badPort[key] = if key == "selection" then badSelection else value
	end
	table.freeze(badPort)
	local badReady = {
		kind = "Ready",
		port = badPort,
	}
	table.freeze(badReady)
	assertError(function()
		GenerationActivation.beginLocal(
			badReady,
			rig.participantStates[2],
			rig.fixture,
			rig.timingRecorders[2],
			nil
		)
	end, "GENERATION_ACTIVATION_E_CONFIG", "non-numeric local client count")
	assert(indexOf(rig.control.log, "connect:client") == nil, "malformed local client count must fail before attach")
	assert(rig.session.closeGenerationRoot() == nil, "malformed local client count test root close must remain clean")
end

-- The local activation boundary accepts the genuine single-process Ready arms
-- emitted by SessionOwner for both distributed roles.
do
	local rig = buildRig()
	local supported = AdapterContract.preflight(rig.identity, rig.selectionInput, STUDIO_VERSION)
	assert(supported.kind == "Supported", "distributed activation preflight must be supported")
	local serverOpen = SessionOwner.openServerPrepared(rig.prepared, rig.adapterFactory, rig.rootFactory)
	assert(serverOpen.kind == "Ready", "distributed server open must be Ready")
	local clientRoot = table.freeze({ id = "client-local-root" })
	local clientOpen = SessionOwner.openClient(
		supported,
		rig.adapterFactory,
		clientRoot,
		1,
		rig.prepared.runtimeInputs.clients[1]
	)
	assert(clientOpen.kind == "Ready", "distributed client open must be Ready")

	local serverActivation = GenerationActivation.beginLocal(
		serverOpen,
		rig.participantStates[1],
		rig.fixture,
		rig.timingRecorders[1],
		rig.caseState
	)
	local clientActivation = GenerationActivation.beginLocal(
		clientOpen,
		rig.participantStates[2],
		rig.fixture,
		rig.timingRecorders[2],
		nil
	)
	assert(serverActivation.pollReady().kind == "ReadyToArm", "genuine server Ready must activate")
	assert(clientActivation.pollReady().kind == "ReadyToArm", "genuine client Ready must activate")
	assert(serverActivation.arm().kind == "Ready", "genuine server Ready must arm")
	assert(clientActivation.arm().kind == "Ready", "genuine client Ready must arm")
	assert(serverActivation.rollback().kind == "Clean", "genuine server rollback must be clean")
	assert(clientActivation.rollback().kind == "Clean", "genuine client rollback must be clean")
	assert(rig.control.destroyCalls == 1, "only the genuine server activation may close its root")
	assert(rig.session.closeGenerationRoot() == nil, "original same-process test root close must remain clean")
	assert(rig.control.destroyCalls == 2, "original and distributed server roots must each close once")
end

-- Distributed probes have a response deadline even though they have no local
-- CaseState. Each accepted response clears its deadline; a whole repetition
-- may take longer than the Studio control-message wait.
for _, missingSample in { 1, 120, false, "ClockFailure" } do
	local rig = buildRig({ selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" } })
	local activation = GenerationActivation.beginLocal(
		clientReady(rig), rig.participantStates[2], rig.fixture, rig.timingRecorders[2], nil
	)
	assert(activation.pollReady().kind == "ReadyToArm", "distributed probe must become ready")
	local kernel = activation.arm().kernel
	assert(rig.timingRecorders[2].recordClockProof({
		coordinatorBeforeSharedSeconds = 0, participantSharedSeconds = 0, coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0, localAfterSeconds = 0,
	}), "distributed probe clock proof must pass")
	kernel.command({ kind = "BeginWarmup" })
	local function reply(sample)
		rig.contexts.client.sink(AdapterContract.recordDelivery(Fixtures.newInput(sample)), { kind = "ServerToClient" })
	end
	for _, sample in rig.fixture.warmup do
		rig.control.producers.client()
		reply(sample)
	end
	while kernel.status().phase ~= "ControlQuiet" or kernel.status().quietFrames < 60 do
		rig.control.producers.client()
	end
	kernel.command({ kind = "ArmMeasured", startSharedSeconds = 0 })
	for index, sample in rig.fixture.measured do
		rig.control.producers.client()
		if missingSample == "ClockFailure" then
			rig.control.clientTimeout = 0 / 0
			rig.control.producers.client()
			assert(kernel.status().phase == "Aborting", "failed local timeout clock must abort the probe")
			break
		end
		if index == missingSample then
			local submittedAt = rig.control.clientTimeout
			rig.control.clientTimeout = submittedAt + 119.999
			rig.control.producers.client()
			assert(kernel.status().phase == "Measured", "probe deadline must remain active before 120 seconds")
			rig.control.clientTimeout = submittedAt + 120
			rig.control.producers.client()
			assert(kernel.status().phase == "Aborting", "distributed lost reply must abort at its 120-second deadline")
			break
		end
		rig.control.clientTimeout += 2
		reply(sample)
	end
	if missingSample == false then
		assert(rig.control.clientTimeout == 240 and kernel.status().phase == "Verified",
			"healthy sequential probes must allow total duration beyond 150 seconds")
		for _ = 1, 60 do rig.control.producers.client() end
	end
	kernel.beginTeardownObservation()
	assert(kernel.teardown().kind == "Clean", "distributed probe teardown must remain clean")
	assert(kernel.finishTeardownObservation().phase == "Closed", "distributed probe must close")
	local evidence = rig.participantStates[2].freeze()
	assert(evidence.kind == "Evidence" and #evidence.value.failureFacts == (if missingSample == "ClockFailure" then 1 else 0),
		"client-only probe timeout must not invent a coordinator-owned Timeout fact")
	if missingSample == "ClockFailure" then
		assert(evidence.value.failureFacts[1].code == "InternalError", "timeout-clock failure must remain an internal failure")
	end
	assert(rig.control.producers.client == nil, "distributed probe cleanup must disconnect its producer")
	assert(rig.session.closeGenerationRoot() == nil, "distributed probe test root must close")
end

-- Without a CaseState, a kernel-owned internal failure is recorded by the
-- local ParticipantState and aborts only that generation.
do
	local rig = buildRig()
	local base = rig.participantStates[2]
	local facts = {}
	local localParticipant = {
		selection = base.selection,
		participant = base.participant,
		beginGeneration = function(...)
			local generation = base.beginGeneration(...)
			local wrapped = {
				observeDelivery = generation.observeDelivery,
				staleHandler = generation.staleHandler,
				transition = function(event)
					if event.kind == "PostSimulation" then
						error("trusted local transition fault", 0)
					end
					return generation.transition(event)
				end,
				status = generation.status,
			}
			table.freeze(wrapped)
			return wrapped
		end,
		recordFailure = function(fact)
			table.insert(facts, fact)
			return base.recordFailure(fact)
		end,
		freeze = base.freeze,
	}
	table.freeze(localParticipant)
	local activation = GenerationActivation.beginLocal(
		clientReady(rig),
		localParticipant,
		rig.fixture,
		rig.timingRecorders[2],
		nil
	)
	assert(activation.pollReady().kind == "ReadyToArm", "local internal rig must become ready")
	local armed = activation.arm()
	assert(armed.kind == "Ready", "local internal rig must arm")
	armed.kernel.command({ kind = "BeginWarmup" })
	rig.control.producers.client()
	assert(#facts == 1, "local internal failure must record exactly one participant fact")
	assert(facts[1].code == "InternalError", "local internal failure code differs")
	assert(facts[1].discriminator.kind == "Stage" and facts[1].discriminator.value == "Execution", "local internal stage differs")
	assert(armed.kernel.status().kind == "State" and armed.kernel.status().phase == "Aborting", "local internal failure must abort locally")
	assert(activation.rollback().kind == "Clean", "local internal rollback must remain clean")
	assert(rig.control.destroyCalls == 0, "local internal client must not close the server root")
	assert(rig.session.closeGenerationRoot() == nil, "local internal test root close must remain clean")
end

-- A local timing-clock failure latches only the participant conformance proof;
-- the distributed coordinator is responsible for projecting the one case fact.
do
	local rig = buildRig()
	local base = rig.participantStates[2]
	local facts = {}
	local localParticipant = {
		selection = base.selection,
		participant = base.participant,
		beginGeneration = base.beginGeneration,
		recordFailure = function(fact)
			table.insert(facts, fact)
			return base.recordFailure(fact)
		end,
		freeze = base.freeze,
	}
	table.freeze(localParticipant)
	local activation = GenerationActivation.beginLocal(
		clientReady(rig),
		localParticipant,
		rig.fixture,
		rig.timingRecorders[2],
		nil
	)
	assert(activation.pollReady().kind == "ReadyToArm", "local clock rig must become ready")
	local armed = activation.arm()
	assert(armed.kind == "Ready", "local clock rig must arm")
	assert(rig.timingRecorders[2].recordClockProof({
		coordinatorBeforeSharedSeconds = 0,
		participantSharedSeconds = 0,
		coordinatorAfterSharedSeconds = 0,
		localBeforeSeconds = 0,
		localAfterSeconds = 0,
	}), "local clock rig proof must start valid")
	armed.kernel.command({ kind = "BeginWarmup" })
	for _ = 1, 200 do
		local status = armed.kernel.status()
		if status.kind == "State" and status.phase == "ControlQuiet" and status.quietFrames == 60 then
			break
		end
		rig.control.producers.client()
	end
	local quiet = armed.kernel.status()
	assert(quiet.kind == "State" and quiet.phase == "ControlQuiet" and quiet.quietFrames == 60, "local clock rig must reach pre-measured quiet")
	assert(rig.control.clientTimeoutReads == 0, "local client kernel must not read coordinator deadlines")
	armed.kernel.command({ kind = "ArmMeasured", startSharedSeconds = 0 })
	rig.control.localClockFault.client = true
	rig.control.producers.client()
	local failed = armed.kernel.status()
	assert(failed.kind == "State" and failed.phase == "Aborting", "local clock failure must abort only the local generation")
	assert(#facts == 0, "local clock failure must not synthesize a participant InternalError")
	armed.kernel.beginTeardownObservation()
	assert(armed.kernel.teardown().kind == "Clean", "local clock failure teardown must stay clean")
	assert(armed.kernel.finishTeardownObservation().phase == "Closed", "local clock failure observation must close")
	local frozen = localParticipant.freeze()
	assert(frozen.kind == "Evidence", "local clock failure must retain bounded participant evidence")
	assert(not frozen.value.conformance.clockProofPassed, "local clock failure conformance must remain failed")
	assert(#facts == 0, "local clock evidence must not duplicate the coordinator clock fact")
	assert(rig.control.destroyCalls == 0, "local clock client must not close the server root")
	assert(rig.session.closeGenerationRoot() == nil, "local clock test root close must remain clean")
end

print("PASS Relay.Benchmarks.GenerationActivation")
