local SessionOwner = require("../runner/SessionOwner")

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

local PRIVATE_SURFACE_KEYS = {
	sink = true,
	resourceRoot = true,
	root = true,
	step = true,
	advance = true,
	flush = true,
	control = true,
	fake = true,
	scheduler = true,
	queue = true,
}

local function assertNoPrivateSurface(value, label, opaque, seen)
	if type(value) ~= "table" or (opaque ~= nil and opaque[value]) then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	for key, nested in next, value do
		if type(key) == "string" then
			assert(PRIVATE_SURFACE_KEYS[key] ~= true, `{label} exposes private key {key}`)
		end
		assertNoPrivateSurface(key, `{label}.<key>`, opaque, seen)
		assertNoPrivateSurface(nested, `{label}.{tostring(key)}`, opaque, seen)
	end
end

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
	for key, nested in next, value do
		copied[deepClone(key, seen)] = deepClone(nested, seen)
	end
	return copied
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

local function newManifest(selection, identity)
	identity = identity or repositoryIdentity()
	return {
		version = 1,
		launchId = "00112233-4455-6677-8899-aabbccddeeff",
		benchmarkSource = {
			revision = string.rep("a", 40),
			dirty = false,
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

local function workloadSelection(workloadId, recipientCount)
	return {
		kind = "Workload",
		workloadId = workloadId,
		recipientCount = recipientCount,
	}
end

local function probeSelection()
	return {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
	}
end

local function newProcessInput(seed)
	local clocks = {
		localNowSeconds = function()
			return seed
		end,
		sharedNowSeconds = function()
			return seed + 1
		end,
		timeoutNowSeconds = function()
			return seed + 2
		end,
	}
	local postSimulation = {
		connectPostSimulation = function(_callback)
			local disconnected = false
			return function()
				disconnected = true
				return disconnected
			end
		end,
	}
	return {
		clocks = clocks,
		postSimulation = postSimulation,
	}
end

local function newRuntimeInputs(clientCount, tokens)
	local serverProcess = newProcessInput(0)
	local server = {
		clocks = serverProcess.clocks,
		postSimulation = serverProcess.postSimulation,
		clientTokens = tokens,
	}
	local clients = table.create(clientCount)
	for index = 1, clientCount do
		clients[index] = newProcessInput(index * 10)
	end
	return {
		server = server,
		clients = clients,
	}
end

local function newFactory(options)
	options = options or {}
	local log = options.log or {}
	local contexts = {
		server = nil,
		clients = {},
	}
	local constructCount = 0

	local function maybeEnterSink(context, label)
		if options.preReadyAt == label then
			context.sink()
		end
	end

	local function makeSide(context, label)
		local side = {
			setup = function()
				table.insert(log, `setup:{label}`)
			end,
			ready = function()
				return true
			end,
			teardown = function()
				table.insert(log, `teardown:{label}`)
				if options.sinkDuringTeardown then
					context.sink()
				end
				if options.failTeardownAt == label then
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
		elseif context.selection.direction == "ClientToServer" then
			if label ~= "server" then
				side.submit = function() end
			end
		else
			if label == "server" then
				side.broadcast = function() end
			end
		end
		return side
	end

	local factory = {
		constructServer = function(context)
			constructCount += 1
			contexts.server = context
			table.insert(log, "construct:server")
			maybeEnterSink(context, "server")
			if options.failConstructAt == "server" then
				error("hostile construct detail", 0)
			end
			return makeSide(context, "server")
		end,
		constructClient = function(context)
			constructCount += 1
			local label = `client{context.participantIndex}`
			contexts.clients[context.participantIndex] = context
			table.insert(log, `construct:{label}`)
			maybeEnterSink(context, label)
			if options.failConstructAt == label then
				error("hostile construct detail", 0)
			end
			return makeSide(context, label)
		end,
	}
	return factory, contexts, function()
		return constructCount
	end, log
end

local function newRootFactory(options)
	options = options or {}
	local calls = 0
	local destroys = 0
	local root = options.root or { id = "opaque-generation-root" }
	local function factory()
		calls += 1
		if options.failFactory then
			error("hostile root factory detail", 0)
		end
		return {
			resourceRoot = root,
			destroy = function()
				destroys += 1
				if options.log ~= nil then
					table.insert(options.log, "destroy:root")
				end
				if options.failDestroy then
					error("hostile destroy detail", 0)
				end
			end,
		}
	end
	return factory, root, function()
		return calls
	end, function()
		return destroys
	end
end

local function assertTermination(result, code, stage, label)
	assertExactKeys(result, { "kind", "termination" }, label)
	assert(result.kind == "Terminated", `{label} must terminate`)
	assertExactKeys(result.termination, { "kind", "code", "stage" }, `{label} termination`)
	assert(result.termination.kind == "RelayHarnessTerminationV1", `{label} kind differs`)
	assert(result.termination.code == code, `{label} code differs`)
	assert(result.termination.stage == stage, `{label} stage differs`)
	assert(table.isfrozen(result), `{label} result must be frozen`)
	assert(table.isfrozen(result.termination), `{label} termination must be frozen`)
end

local function assertSetupFailed(result, label)
	assertExactKeys(result, { "kind" }, label)
	assert(result.kind == "SetupFailed", `{label} must be SetupFailed`)
	assert(table.isfrozen(result), `{label} must be frozen`)
end

local function openCase(selection, clientCount, tokens, factoryOptions, rootOptions, identity)
	identity = identity or repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local factory, contexts, constructCount, log = newFactory(factoryOptions)
	rootOptions = rootOptions or {}
	rootOptions.log = rootOptions.log or log
	local rootFactory, root, rootCalls, destroyCalls = newRootFactory(rootOptions)
	local runtimeInputs = newRuntimeInputs(clientCount, tokens)
	local result = SessionOwner.open(
		manifest,
		identity,
		factory,
		rootFactory,
		runtimeInputs
	)
	return result, {
		manifest = manifest,
		factory = factory,
		contexts = contexts,
		constructCount = constructCount,
		log = log,
		root = root,
		rootCalls = rootCalls,
		destroyCalls = destroyCalls,
		runtimeInputs = runtimeInputs,
	}
end

local function closeReady(result)
	for index = #result.ports, 1, -1 do
		result.ports[index].side.teardown()
	end
	return result.closeGenerationRoot()
end

assertExactKeys(SessionOwner, { "open" }, "SessionOwner")
assert(table.isfrozen(SessionOwner), "SessionOwner must be frozen")

-- Broadcast derives adapter recipients from the full roster and exposes no sender tokens.
do
	local equalityCalls = 0
	local tokenMetatable = {
		__eq = function()
			equalityCalls += 1
			error("opaque token equality must not run", 0)
		end,
	}
	local tokens = {}
	for index = 1, 4 do
		tokens[index] = setmetatable({ index = index }, tokenMetatable)
	end
	local result, state = openCase(
		workloadSelection("state-broadcast-s2c", 4),
		4,
		tokens
	)
	assert(result.kind == "Ready", "broadcast must open")
	assert(equalityCalls == 0, "opaque token equality must not be invoked")
	assertExactKeys(result, { "kind", "manifest", "ports", "closeGenerationRoot" }, "ready result")
	assert(table.isfrozen(result), "ready result must be frozen")
	assert(table.isfrozen(result.manifest), "canonical manifest must be frozen")
	assert(table.isfrozen(result.ports), "port array must be frozen")
	assert(#result.ports == 5, "broadcast must return server plus four clients")
	assert(state.rootCalls() == 1 and state.constructCount() == 5, "broadcast construction count differs")
	assert(state.log[1] == "construct:server", "server must construct first")
	for index = 1, 4 do
		assert(state.log[index + 1] == `construct:client{index}`, "clients must construct in order")
	end

	local server = result.ports[1]
	assertExactKeys(server, {
		"participant",
		"selection",
		"caseDefinition",
		"clocks",
		"postSimulation",
		"delivery",
		"side",
		"senderTokens",
	}, "server port")
	assert(table.isfrozen(server), "server port must be frozen")
	assert(table.isfrozen(server.participant), "server participant must be frozen")
	assert(table.isfrozen(server.senderTokens), "server sender tokens must be frozen")
	assertExactKeys(server.participant, { "role" }, "server participant")
	assertExactKeys(server.clocks, {
		"localNowSeconds",
		"sharedNowSeconds",
		"timeoutNowSeconds",
	}, "server clocks")
	assertExactKeys(server.postSimulation, { "connectPostSimulation" }, "server frame source")
	assertExactKeys(server.delivery, {
		"bind",
		"arm",
		"beginTeardownObservation",
		"disable",
	}, "server delivery gate")
	assertExactKeys(server.side, { "setup", "ready", "teardown", "broadcast" }, "server side")
	assert(#server.senderTokens == 0, "broadcast sender tokens must be empty")
	assert(server.participant.role == "Server", "server role differs")
	assert(server.caseDefinition.id == "state-broadcast-s2c", "server case differs")
	assert(not rawequal(server.clocks, state.runtimeInputs.server.clocks), "clock record must be copied")
	assert(not rawequal(server.postSimulation, state.runtimeInputs.server.postSimulation), "frame source must be copied")
	assert(table.isfrozen(server.clocks) and table.isfrozen(server.postSimulation), "runtime seams must be frozen")
	assert(state.contexts.server.resourceRoot == state.root, "server must receive shared root")
	assert(#state.contexts.server.recipients == 4, "broadcast recipients differ")
	assert(table.isfrozen(state.contexts.server.recipients), "adapter recipients must be frozen")
	assert(not rawequal(state.contexts.server.recipients, tokens), "adapter recipients must be copied")
	assert(not rawequal(state.contexts.server.recipients, server.senderTokens), "recipient and sender arrays must differ")
	for index = 1, 4 do
		assert(rawequal(state.contexts.server.recipients[index], tokens[index]), "recipient token differs")
		local client = result.ports[index + 1]
		assertExactKeys(client, {
			"participant",
			"selection",
			"caseDefinition",
			"clocks",
			"postSimulation",
			"delivery",
			"side",
		}, `client port {index}`)
		assert(table.isfrozen(client) and table.isfrozen(client.participant), "client port must be frozen")
		assertExactKeys(client.participant, { "role", "index" }, `client participant {index}`)
		assertExactKeys(client.clocks, {
			"localNowSeconds",
			"sharedNowSeconds",
			"timeoutNowSeconds",
		}, `client clocks {index}`)
		assertExactKeys(client.postSimulation, { "connectPostSimulation" }, `client frame source {index}`)
		assertExactKeys(client.delivery, {
			"bind",
			"arm",
			"beginTeardownObservation",
			"disable",
		}, `client delivery gate {index}`)
		assertExactKeys(client.side, { "setup", "ready", "teardown" }, `client side {index}`)
		assert(client.participant.role == "Client" and client.participant.index == index, "client role differs")
		assert(state.contexts.clients[index].resourceRoot == state.root, "client must share root")
		assertNoPrivateSurface(client, `client port {index}`)
	end
	assertNoPrivateSurface(server, "server port")
	state.manifest.benchmarkSource.dirty = true
	assert(result.manifest.benchmarkSource.dirty == false, "manifest output must be detached")
	assert(closeReady(result) == nil, "clean close must return nil")
	assert(result.closeGenerationRoot() == nil, "clean close must be idempotent")
	assert(state.destroyCalls() == 1, "root must be destroyed once")
end

-- C2S keeps adapter fanout empty while the server receives a separate sender oracle.
do
	local token = { id = "sender" }
	local result, state = openCase(
		workloadSelection("tiny-steady-c2s", 1),
		1,
		{ token }
	)
	assert(result.kind == "Ready", "C2S must open")
	assert(#state.contexts.server.recipients == 0, "C2S adapter recipients must be empty")
	assert(#result.ports[1].senderTokens == 1, "C2S sender oracle count differs")
	assert(rawequal(result.ports[1].senderTokens[1], token), "C2S sender oracle token differs")
	assert(not table.isfrozen(token), "opaque sender token must not be frozen")
	assert(result.ports[2].participant.role == "Client", "C2S client role differs")
	closeReady(result)
end

-- Probe uses the full roster for both adapter recipients and server sender identity.
do
	local token = { id = "probe-client" }
	local result, state = openCase(probeSelection(), 1, { token })
	assert(result.kind == "Ready", "probe must open")
	assert(result.ports[2].participant.role == "ProbeClient", "probe client role differs")
	assert(rawequal(state.contexts.server.recipients[1], token), "probe recipient differs")
	assert(rawequal(result.ports[1].senderTokens[1], token), "probe sender token differs")
	assert(
		not rawequal(state.contexts.server.recipients, result.ports[1].senderTokens),
		"probe recipient and sender arrays must be separate copies"
	)
	closeReady(result)
end

-- The largest selected topology remains a dense server-then-client port array.
do
	local tokens = table.create(8)
	for index = 1, 8 do
		tokens[index] = { index = index }
	end
	local result = openCase(workloadSelection("state-broadcast-s2c", 8), 8, tokens)
	assert(result.kind == "Ready" and #result.ports == 9, "eight-client topology differs")
	closeReady(result)
end

local function assertPreflightRejected(manifest, identity, runtimeInputs, label)
	local factory, _, constructCount = newFactory()
	local rootFactory, _, rootCalls, destroyCalls = newRootFactory()
	local result = SessionOwner.open(manifest, identity, factory, rootFactory, runtimeInputs)
	assertTermination(result, "HostManifestRejected", "Preflight", label)
	assert(rootCalls() == 0, `{label} must not create a root`)
	assert(constructCount() == 0, `{label} must not construct a side`)
	assert(destroyCalls() == 0, `{label} must not destroy an absent root`)
end

-- Every host/candidate/selection/roster conflict rejects before root creation.
do
	local selection = workloadSelection("state-broadcast-s2c", 4)
	local identity = repositoryIdentity()
	local runtimeInputs = newRuntimeInputs(4, { {}, {}, {}, {} })

	local malformedManifest = newManifest(selection, identity)
	malformedManifest.extra = true
	assertPreflightRejected(malformedManifest, identity, runtimeInputs, "malformed manifest")

	local processIdentity = repositoryIdentity()
	processIdentity.semantics.repetitionIsolation = "ProcessRestart"
	assertPreflightRejected(
		newManifest(selection, processIdentity),
		processIdentity,
		runtimeInputs,
		"ProcessRestart"
	)

	local mismatchedIdentity = deepClone(identity)
	mismatchedIdentity.displayName = "Different Adapter"
	assertPreflightRejected(
		newManifest(selection, identity),
		mismatchedIdentity,
		runtimeInputs,
		"candidate mismatch"
	)

	local unsupportedIdentity = deepClone(identity)
	unsupportedIdentity.capabilities.directions = { "ClientToServer" }
	assertPreflightRejected(
		newManifest(selection, identity),
		unsupportedIdentity,
		runtimeInputs,
		"unsupported candidate"
	)

	local malformedIdentity = deepClone(identity)
	malformedIdentity.secret = "must-not-escape"
	assertPreflightRejected(
		newManifest(selection, identity),
		malformedIdentity,
		runtimeInputs,
		"malformed candidate"
	)

	local duplicateToken = {}
	assertPreflightRejected(
		newManifest(selection, identity),
		identity,
		newRuntimeInputs(4, { duplicateToken, duplicateToken, {}, {} }),
		"duplicate token"
	)

	local shortClients = newRuntimeInputs(4, { {}, {}, {}, {} })
	shortClients.clients[4] = nil
	assertPreflightRejected(newManifest(selection, identity), identity, shortClients, "short client roster")

	local extraClock = newRuntimeInputs(4, { {}, {}, {}, {} })
	extraClock.clients[1].clocks.extra = function() end
	assertPreflightRejected(newManifest(selection, identity), identity, extraClock, "extra clock key")

	local badFrameSource = newRuntimeInputs(4, { {}, {}, {}, {} })
	badFrameSource.server.postSimulation.connectPostSimulation = true
	assertPreflightRejected(newManifest(selection, identity), identity, badFrameSource, "bad frame source")

	local metatableClient = newRuntimeInputs(4, { {}, {}, {}, {} })
	setmetatable(metatableClient.clients[2], {})
	assertPreflightRejected(newManifest(selection, identity), identity, metatableClient, "metatable client")
end

-- Raw token identity never invokes a hostile equality metamethod.
do
	local equalityCalls = 0
	local tokenMetatable = {
		__eq = function()
			equalityCalls += 1
			return true
		end,
	}
	local tokens = {}
	for index = 1, 4 do
		tokens[index] = setmetatable({ index = index }, tokenMetatable)
	end
	local result = openCase(workloadSelection("state-broadcast-s2c", 4), 4, tokens)
	assert(result.kind == "Ready", "distinct opaque tokens must open")
	assert(equalityCalls == 0, "SessionOwner must not invoke token __eq")
	closeReady(result)
end

-- Root-factory defects are fixed SetupFailed values with no side construction.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local runtimeInputs = newRuntimeInputs(1, { {} })
	local factory, _, constructCount = newFactory()
	local rootFactory, _, rootCalls = newRootFactory({ failFactory = true })
	local result = SessionOwner.open(manifest, identity, factory, rootFactory, runtimeInputs)
	assertSetupFailed(result, "root factory failure")
	assert(rootCalls() == 1 and constructCount() == 0, "root factory failure counts differ")
end

-- Hostile lease shapes are rejected before side construction and clean up when possible.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local runtimeInputs = newRuntimeInputs(1, { {} })

	local function assertLeaseFailure(makeLease, expectedCode, expectedDestroyCalls, label)
		local factory, _, constructCount = newFactory()
		local rootCalls = 0
		local destroyCalls = 0
		local function rootFactory()
			rootCalls += 1
			return makeLease(function(shouldFail)
				destroyCalls += 1
				if shouldFail then
					error("hostile lease destroy detail", 0)
				end
			end)
		end
		local result = SessionOwner.open(manifest, identity, factory, rootFactory, runtimeInputs)
		if expectedCode == nil then
			assertSetupFailed(result, label)
		else
			assertTermination(result, expectedCode, "Finalize", label)
		end
		assert(rootCalls == 1, `{label} must call the root factory once`)
		assert(constructCount() == 0, `{label} must not construct a side`)
		assert(destroyCalls == expectedDestroyCalls, `{label} destroy count differs`)
	end

	assertLeaseFailure(function(destroy)
		return { resourceRoot = {}, destroy = function()
			destroy(false)
		end, extra = true }
	end, nil, 1, "extra lease key")

	assertLeaseFailure(function(destroy)
		return setmetatable({ resourceRoot = {}, destroy = function()
			destroy(false)
		end }, {})
	end, nil, 1, "lease metatable")

	assertLeaseFailure(function(destroy)
		return { resourceRoot = nil, destroy = function()
			destroy(false)
		end }
	end, nil, 1, "nil lease root")

	assertLeaseFailure(function(_destroy)
		return { resourceRoot = {}, destroy = true }
	end, nil, 0, "nonfunction lease destroy")

	assertLeaseFailure(function(destroy)
		return { resourceRoot = {}, destroy = function()
			destroy(true)
		end, extra = true }
	end, "CleanupFailure", 1, "invalid lease cleanup failure")
end

-- Partial construction disables routes before reverse teardown and destroys the root once.
do
	local log = {}
	local options = {
		log = log,
		failConstructAt = "client2",
		sinkDuringTeardown = true,
	}
	local rootOptions = { log = log }
	local result, state = openCase(
		workloadSelection("state-broadcast-s2c", 4),
		4,
		{ {}, {}, {}, {} },
		options,
		rootOptions
	)
	assertSetupFailed(result, "partial construction")
	assert(state.destroyCalls() == 1, "partial construction must destroy root once")
	local expected = {
		"construct:server",
		"construct:client1",
		"construct:client2",
		"teardown:client1",
		"teardown:server",
		"destroy:root",
	}
	assert(#state.log == #expected, "partial rollback log length differs")
	for index, value in expected do
		assert(state.log[index] == value, `partial rollback order differs at {index}`)
	end
	for _, context in state.contexts.clients do
		context.sink(setmetatable({}, { __index = function()
			error("disabled sink traversed", 0)
		end }), nil, "extra")
	end
	state.contexts.server.sink(nil, nil, "extra")
end

-- A constructor-time sink call outranks construction failure after clean rollback.
do
	local result, state = openCase(
		workloadSelection("state-broadcast-s2c", 4),
		4,
		{ {}, {}, {}, {} },
		{
			preReadyAt = "client2",
			failConstructAt = "client2",
		}
	)
	assertTermination(result, "ControlProtocolRejected", "Setup", "pre-ready rollback")
	assert(state.destroyCalls() == 1, "pre-ready rollback must destroy root")
end

-- Cleanup failure has highest precedence over a latched pre-ready violation.
do
	local result, state = openCase(
		workloadSelection("state-broadcast-s2c", 4),
		4,
		{ {}, {}, {}, {} },
		{
			preReadyAt = "client2",
			failConstructAt = "client2",
			failTeardownAt = "client1",
		},
		{ failDestroy = true }
	)
	assertTermination(result, "CleanupFailure", "Finalize", "cleanup precedence")
	assert(state.destroyCalls() == 1, "cleanup precedence must attempt root once")
end

-- A successful constructor-time pre-ready call remains latched for kernel binding.
do
	local result = openCase(
		workloadSelection("tiny-steady-c2s", 1),
		1,
		{ {} },
		{ preReadyAt = "server" }
	)
	assert(result.kind == "Ready", "latched route may finish construction")
	assert(result.ports[1].delivery.bind(function() end) == false, "pre-ready bind must return false")
	assert(result.ports[1].delivery.disable() == "PreReadyViolation", "pre-ready disable result differs")
	closeReady(result)
end

-- Normal root cleanup is idempotent and caches its bounded cleanup failure.
do
	local result, state = openCase(
		workloadSelection("tiny-steady-c2s", 1),
		1,
		{ {} },
		nil,
		{ failDestroy = true }
	)
	assert(result.kind == "Ready", "destroy-failure case must construct")
	for index = #result.ports, 1, -1 do
		result.ports[index].side.teardown()
	end
	local first = result.closeGenerationRoot()
	local second = result.closeGenerationRoot()
	assert(first ~= nil and rawequal(first, second), "cleanup failure must be cached")
	assert(first.code == "CleanupFailure" and first.stage == "Finalize", "cleanup envelope differs")
	assert(state.destroyCalls() == 1, "failing destroy must run once")
end

print("PASS Relay.Benchmarks.SessionOwner")
