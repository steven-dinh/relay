local AdapterContract = require("../adapters/AdapterContract")
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
				if options.yieldTeardownAt == label then
					coroutine.yield("hostile teardown suspension")
					table.insert(log, `resumed:teardown:{label}`)
				end
				if options.multiReturnTeardownAt == label then
					return "unexpected teardown result"
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
			if options.yieldConstructAt == "server" then
				coroutine.yield("hostile construct suspension")
				table.insert(log, "resumed:construct:server")
			end
			local side = makeSide(context, "server")
			if options.multiReturnConstructAt == "server" then
				return side, "unexpected construct result"
			end
			return side
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
			if options.yieldConstructAt == label then
				coroutine.yield("hostile construct suspension")
				table.insert(log, `resumed:construct:{label}`)
			end
			local side = makeSide(context, label)
			if options.multiReturnConstructAt == label then
				return side, "unexpected construct result"
			end
			return side
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
		if options.yieldFactory then
			coroutine.yield("hostile root factory suspension")
			if options.log ~= nil then
				table.insert(options.log, "resumed:factory")
			end
		end
		local lease = {
			resourceRoot = root,
			destroy = function()
				destroys += 1
				if options.log ~= nil then
					table.insert(options.log, "destroy:root")
				end
			if options.failDestroy then
				error("hostile destroy detail", 0)
			end
				if options.yieldDestroy then
					coroutine.yield("hostile destroy suspension")
					if options.log ~= nil then
						table.insert(options.log, "resumed:destroy")
					end
				end
				if options.multiReturnDestroy then
					return "unexpected destroy result"
				end
			end,
		}
		if options.multiReturnFactory then
			return lease, "unexpected factory result"
		end
		return lease
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

local function assertSetupFailed(result, manifestCandidate, label)
	assertExactKeys(result, { "kind", "manifest" }, label)
	assert(result.kind == "SetupFailed", `{label} must be SetupFailed`)
	assert(table.isfrozen(result), `{label} must be frozen`)
	assert(table.isfrozen(result.manifest), `{label} manifest must be frozen`)
	assert(not rawequal(result.manifest, manifestCandidate), `{label} manifest must be copied`)
end

local function assertInternalFailed(result, manifestCandidate, label)
	assertExactKeys(result, { "kind", "manifest" }, label)
	assert(result.kind == "InternalFailed", `{label} must be InternalFailed`)
	assert(table.isfrozen(result), `{label} must be frozen`)
	assert(table.isfrozen(result.manifest), `{label} manifest must be frozen`)
	assert(not rawequal(result.manifest, manifestCandidate), `{label} manifest must be copied`)
end

local function openCase(selection, clientCount, tokens, factoryOptions, rootOptions, identity)
	identity = identity or repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local factory, contexts, constructCount, log = newFactory(factoryOptions)
	rootOptions = rootOptions or {}
	rootOptions.log = rootOptions.log or log
	local rootFactory, root, rootCalls, destroyCalls = newRootFactory(rootOptions)
	local runtimeInputs = newRuntimeInputs(clientCount, tokens)
	local preparedResult = SessionOwner.prepare(
		manifest,
		identity,
		runtimeInputs
	)
	assert(preparedResult.kind == "Prepared", "valid case must prepare")
	local prepared = preparedResult.value
	local result = SessionOwner.openPrepared(prepared, factory, rootFactory)
	assert(type(result) == "table" and table.isfrozen(result), "open result wrapper must be frozen")
	if result.kind ~= "Terminated" then
		assert(rawequal(result.manifest, prepared.manifest), "open result must carry prepared manifest")
	end
	return result, {
		manifest = manifest,
		preparedResult = preparedResult,
		prepared = prepared,
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

assertExactKeys(SessionOwner, {
	"prepare",
	"prepareCoordinator",
	"requirePrepared",
	"requirePreparedCase",
	"openPrepared",
	"openServerPrepared",
	"openClient",
}, "SessionOwner")
assert(table.isfrozen(SessionOwner), "SessionOwner must be frozen")

-- Preparation is allocation-free, deeply detaches the trusted roster, and remains reusable.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local token = { id = "reusable-sender" }
	local runtimeInputs = newRuntimeInputs(1, { token })
	local factory, _, constructCount = newFactory()
	local rootFactory, _, rootCalls, destroyCalls = newRootFactory()

	local preparedResult = SessionOwner.prepare(manifest, identity, runtimeInputs)
	assert(preparedResult.kind == "Prepared", "valid preparation must succeed")
	assertExactKeys(preparedResult, { "kind", "value" }, "prepared result")
	assert(table.isfrozen(preparedResult), "prepared result must be frozen")
	assert(rootCalls() == 0 and constructCount() == 0, "prepare must perform zero construction")
	assert(destroyCalls() == 0, "prepare must not attempt cleanup")

	local prepared = preparedResult.value
	assertExactKeys(
		prepared,
		{ "manifest", "selection", "caseDefinition", "runtimeInputs" },
		"prepared session"
	)
	assert(table.isfrozen(prepared), "prepared session must be frozen")
	assert(table.isfrozen(prepared.manifest), "prepared manifest must be frozen")
	assert(table.isfrozen(prepared.selection), "prepared selection must be frozen")
	assert(table.isfrozen(prepared.caseDefinition), "prepared case definition must be frozen")
	assert(rawequal(SessionOwner.requirePrepared(prepared), prepared), "prepared guard must preserve identity")
	assert(not rawequal(prepared.manifest, manifest), "prepared manifest must be canonical copy")
	assertExactKeys(prepared.runtimeInputs, { "server", "clients" }, "prepared runtime inputs")
	assertExactKeys(
		prepared.runtimeInputs.server,
		{ "clocks", "postSimulation", "clientTokens" },
		"prepared server runtime"
	)
	assert(table.isfrozen(prepared.runtimeInputs), "prepared runtime inputs must be frozen")
	assert(table.isfrozen(prepared.runtimeInputs.server), "prepared server runtime must be frozen")
	assert(table.isfrozen(prepared.runtimeInputs.server.clocks), "prepared server clocks must be frozen")
	assert(
		table.isfrozen(prepared.runtimeInputs.server.postSimulation),
		"prepared server frame source must be frozen"
	)
	assert(table.isfrozen(prepared.runtimeInputs.server.clientTokens), "prepared token roster must be frozen")
	assert(table.isfrozen(prepared.runtimeInputs.clients), "prepared client roster must be frozen")
	assert(table.isfrozen(prepared.runtimeInputs.clients[1]), "prepared client runtime must be frozen")
	assert(table.isfrozen(prepared.runtimeInputs.clients[1].clocks), "prepared client clocks must be frozen")
	assert(
		table.isfrozen(prepared.runtimeInputs.clients[1].postSimulation),
		"prepared client frame source must be frozen"
	)
	assert(not rawequal(prepared.runtimeInputs, runtimeInputs), "prepared runtime root must be copied")
	assert(not rawequal(prepared.runtimeInputs.server, runtimeInputs.server), "prepared server must be copied")
	assert(not rawequal(prepared.runtimeInputs.clients, runtimeInputs.clients), "prepared clients must be copied")
	assert(
		not rawequal(prepared.runtimeInputs.clients[1], runtimeInputs.clients[1]),
		"prepared client runtime must be copied"
	)
	assert(rawequal(prepared.runtimeInputs.server.clientTokens[1], token), "opaque token identity must persist")
	assert(not table.isfrozen(token), "opaque token must not be frozen")
	assertNoPrivateSurface(prepared, "prepared session")

	local function assertPreparedError(callback, label)
		local ok, detail = pcall(callback)
		assert(ok == false and detail == "SESSION_OWNER_E_PREPARED", `{label} must raise prepared sentinel`)
	end

	assertPreparedError(function()
		SessionOwner.requirePrepared(deepClone(prepared))
	end, "prepared clone")
	assertPreparedError(function()
		SessionOwner.requirePrepared(nil)
	end, "nil prepared candidate")

	local candidateReads = 0
	local lookalike = setmetatable({}, {
		__index = function()
			candidateReads += 1
			error("prepared lookalike was read", 0)
		end,
	})
	assertPreparedError(function()
		SessionOwner.requirePrepared(lookalike)
	end, "prepared lookalike")
	local rejectedRootCalls = 0
	assertPreparedError(function()
		SessionOwner.openPrepared(lookalike :: any, {} :: any, function()
			rejectedRootCalls += 1
			return { resourceRoot = {}, destroy = function() end }
		end)
	end, "openPrepared lookalike")
	assert(candidateReads == 0, "prepared guard must reject before candidate field reads")
	assert(rejectedRootCalls == 0, "prepared guard must reject before root construction")

	manifest.benchmarkSource.dirty = true
	runtimeInputs.server.clientTokens[1] = { id = "replacement" }
	runtimeInputs.server.clocks.localNowSeconds = function()
		error("mutated source clock must not enter prepared value", 0)
	end
	assert(prepared.manifest.benchmarkSource.dirty == false, "prepared manifest must be detached")
	assert(rawequal(prepared.runtimeInputs.server.clientTokens[1], token), "prepared roster must be detached")

	for repetitionIndex = 1, 30 do
		local result = SessionOwner.openPrepared(prepared, factory, rootFactory)
		assert(result.kind == "Ready", `prepared reuse {repetitionIndex} must open`)
		assert(rawequal(result.manifest, prepared.manifest), "open must reuse prepared canonical manifest")
		assert(closeReady(result) == nil, `prepared reuse {repetitionIndex} must close cleanly`)
		assert(
			rawequal(SessionOwner.requirePrepared(prepared), prepared),
			`prepared reuse {repetitionIndex} must preserve brand`
		)
	end
	assert(rootCalls() == 30, "reusable prepared session must create thirty generation roots")
	assert(constructCount() == 60, "reusable prepared session must construct thirty two-side generations")
	assert(destroyCalls() == 30, "reusable prepared session must destroy thirty generation roots")
end

-- Coordinator preparation is server-only, locally branded, and opens one server side.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local clientInputReads = 0
	local token = setmetatable({}, {
		__index = function()
			clientInputReads += 1
			error("coordinator preparation touched client runtime input", 0)
		end,
	})
	local serverRuntimeInput = newRuntimeInputs(1, { token }).server
	local factory, contexts, constructCount = newFactory()
	local rootFactory, _, rootCalls, destroyCalls = newRootFactory()

	local preparedResult = SessionOwner.prepareCoordinator(manifest, identity, serverRuntimeInput)
	assert(preparedResult.kind == "Prepared", "coordinator preparation must succeed")
	assertExactKeys(preparedResult, { "kind", "value" }, "coordinator prepared result")
	assert(table.isfrozen(preparedResult), "coordinator prepared result must be frozen")
	local prepared = preparedResult.value
	assertExactKeys(
		prepared,
		{ "manifest", "selection", "caseDefinition", "serverRuntimeInput" },
		"prepared coordinator"
	)
	assert(table.isfrozen(prepared), "prepared coordinator must be frozen")
	assert(table.isfrozen(prepared.serverRuntimeInput), "prepared server runtime must be frozen")
	assertExactKeys(
		prepared.serverRuntimeInput,
		{ "clocks", "postSimulation", "clientTokens" },
		"prepared coordinator server runtime"
	)
	assert(rootCalls() == 0 and constructCount() == 0, "coordinator prepare must not allocate")
	assert(destroyCalls() == 0, "coordinator prepare must not clean up an absent root")
	assert(clientInputReads == 0, "coordinator prepare must treat client tokens as opaque")
	assert(
		rawequal(SessionOwner.requirePreparedCase(prepared), prepared),
		"coordinator case guard must preserve identity"
	)

	local fullPrepared = SessionOwner.prepare(manifest, identity, newRuntimeInputs(1, { {} }))
	assert(fullPrepared.kind == "Prepared", "full case must prepare for shared guard")
	assert(
		rawequal(SessionOwner.requirePreparedCase(fullPrepared.value), fullPrepared.value),
		"shared case guard must accept a full preparation"
	)
	local fullFactory, _, fullConstructCount = newFactory()
	local fullRootFactory, _, fullRootCalls, fullDestroyCalls = newRootFactory()
	local fullOpened = SessionOwner.openServerPrepared(
		fullPrepared.value,
		fullFactory,
		fullRootFactory
	)
	assert(fullOpened.kind == "Ready", "full preparation must open through the server seam")
	fullOpened.port.side.teardown()
	assert(fullOpened.closeGenerationRoot() == nil, "full preparation server root must close cleanly")
	assert(fullRootCalls() == 1 and fullConstructCount() == 1, "full server seam counts differ")
	assert(fullDestroyCalls() == 1, "full server seam must destroy its root once")

	local okFull, fullDetail = pcall(SessionOwner.requirePrepared, prepared)
	assert(okFull == false and fullDetail == "SESSION_OWNER_E_PREPARED", "coordinator must not gain full brand")
	local clone = deepClone(prepared)
	local okClone, cloneDetail = pcall(SessionOwner.requirePreparedCase, clone)
	assert(
		okClone == false and cloneDetail == "SESSION_OWNER_E_PREPARED_CASE",
		"prepared coordinator clone must lose its brand"
	)
	local rejectedRootCalls = 0
	local okOpen, openDetail = pcall(
		SessionOwner.openServerPrepared,
		clone,
		factory,
		function()
			rejectedRootCalls += 1
			return { resourceRoot = {}, destroy = function() end }
		end
	)
	assert(
		okOpen == false and openDetail == "SESSION_OWNER_E_PREPARED_CASE",
		"server open must guard before reading a clone"
	)
	assert(rejectedRootCalls == 0 and constructCount() == 0, "rejected server open must not allocate")

	serverRuntimeInput.clientTokens[1] = { replacement = true }
	assert(rawequal(prepared.serverRuntimeInput.clientTokens[1], token), "coordinator roster must detach")
	local opened = SessionOwner.openServerPrepared(prepared, factory, rootFactory)
	assert(opened.kind == "Ready", "prepared coordinator must open its server")
	assertExactKeys(
		opened,
		{ "kind", "manifest", "port", "closeGenerationRoot" },
		"server ready result"
	)
	assert(table.isfrozen(opened), "server ready result must be frozen")
	assertExactKeys(opened.port, {
		"participant",
		"selection",
		"caseDefinition",
		"clocks",
		"postSimulation",
		"delivery",
		"side",
		"senderTokens",
	}, "distributed server port")
	assert(opened.port.participant.role == "Server", "distributed server role differs")
	assert(rawequal(opened.port.senderTokens[1], token), "distributed sender identity differs")
	assert(contexts.server ~= nil and contexts.clients[1] == nil, "server open must construct no client")
	assert(rootCalls() == 1 and constructCount() == 1, "server open constructor counts differ")
	opened.port.side.teardown()
	assert(opened.closeGenerationRoot() == nil, "distributed server root must close cleanly")
	assert(opened.closeGenerationRoot() == nil, "distributed server root close must be idempotent")
	assert(destroyCalls() == 1, "distributed server root must destroy once")
	assert(clientInputReads == 0, "server-only path must not inspect client runtime input")
end

-- Server construction rollback owns and destroys its generation root exactly once.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local prepared = SessionOwner.prepareCoordinator(
		manifest,
		identity,
		newRuntimeInputs(1, { {} }).server
	)
	assert(prepared.kind == "Prepared", "server rollback case must prepare")
	local factory, _, constructCount = newFactory({ failConstructAt = "server" })
	local rootFactory, _, rootCalls, destroyCalls = newRootFactory()
	local result = SessionOwner.openServerPrepared(prepared.value, factory, rootFactory)
	assertSetupFailed(result, manifest, "distributed server construction")
	assert(rootCalls() == 1 and constructCount() == 1, "server rollback constructor counts differ")
	assert(destroyCalls() == 1, "server rollback must destroy its root once")
end

-- Client opening accepts only a locally minted preflight and owns no generation root.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local supported = AdapterContract.preflight(identity, selection, STUDIO_VERSION)
	assert(supported.kind == "Supported", "client case must be supported locally")
	local factory, contexts, constructCount = newFactory()
	local localRoot = { id = "client-local-root" }
	local processInput = newProcessInput(90)
	local result = SessionOwner.openClient(supported, factory, localRoot, 1, processInput)
	assert(result.kind == "Ready", "locally supported client must open")
	assertExactKeys(result, { "kind", "port" }, "client ready result")
	assert(table.isfrozen(result), "client ready result must be frozen")
	assertExactKeys(result.port, {
		"participant",
		"selection",
		"caseDefinition",
		"clocks",
		"postSimulation",
		"delivery",
		"side",
	}, "distributed client port")
	assert(result.port.participant.role == "Client" and result.port.participant.index == 1, "client role differs")
	assert(rawequal(contexts.clients[1].resourceRoot, localRoot), "client local root differs")
	assert(contexts.server == nil and constructCount() == 1, "client open must construct one local side")
	assert(not rawequal(result.port.clocks, processInput.clocks), "client clocks must be copied locally")
	result.port.side.teardown()

	local cloneFactory, _, cloneConstructCount = newFactory()
	local cloneResult = SessionOwner.openClient(
		deepClone(supported),
		cloneFactory,
		localRoot,
		1,
		newProcessInput(91)
	)
	assertExactKeys(cloneResult, { "kind" }, "cloned client preflight rejection")
	assert(cloneResult.kind == "InternalFailed", "cloned client preflight must be rejected")
	assert(cloneConstructCount() == 0, "cloned client preflight must not invoke adapter constructor")

	local badInput = newProcessInput(92)
	badInput.extra = true
	local malformedResult = SessionOwner.openClient(supported, cloneFactory, localRoot, 1, badInput)
	assertExactKeys(malformedResult, { "kind" }, "malformed client runtime rejection")
	assert(malformedResult.kind == "InternalFailed", "malformed local runtime must be rejected")
	assert(cloneConstructCount() == 0, "malformed local runtime must reject before construction")

	local failingFactory, _, failingConstructCount = newFactory({ failConstructAt = "client1" })
	local failed = SessionOwner.openClient(supported, failingFactory, localRoot, 1, newProcessInput(93))
	assertExactKeys(failed, { "kind" }, "client setup failure")
	assert(failed.kind == "SetupFailed", "client constructor throw must be setup failure")
	assert(failingConstructCount() == 1, "client setup failure must enter constructor once")
end

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
	assert(not rawequal(result.manifest, state.manifest), "canonical manifest must be copied")
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
		assert(
			not rawequal(client.clocks, state.runtimeInputs.clients[index].clocks),
			`client clock record {index} must be copied`
		)
		assert(
			not rawequal(client.postSimulation, state.runtimeInputs.clients[index].postSimulation),
			`client frame source {index} must be copied`
		)
		assert(
			table.isfrozen(client.clocks) and table.isfrozen(client.postSimulation),
			`client runtime seams {index} must be frozen`
		)
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
	local result = SessionOwner.prepare(manifest, identity, runtimeInputs)
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
	assertPreflightRejected(
		newManifest(selection, identity),
		identity,
		newRuntimeInputs(4, { 0 / 0, {}, {}, {} }),
		"non-reflexive token"
	)

	local shortClients = newRuntimeInputs(4, { {}, {}, {}, {} })
	shortClients.clients[4] = nil
	assertPreflightRejected(newManifest(selection, identity), identity, shortClients, "short client roster")

	local exactNodeCases = {
		{
			label = "runtime root extra key",
			mutate = function(inputs)
				inputs.extra = true
			end,
		},
		{
			label = "server runtime extra key",
			mutate = function(inputs)
				inputs.server.extra = true
			end,
		},
		{
			label = "client roster extra key",
			mutate = function(inputs)
				inputs.clients.extra = true
			end,
		},
		{
			label = "server clocks extra key",
			mutate = function(inputs)
				inputs.server.clocks.extra = function() end
			end,
		},
		{
			label = "server frame source extra key",
			mutate = function(inputs)
				inputs.server.postSimulation.extra = true
			end,
		},
		{
			label = "client token roster extra key",
			mutate = function(inputs)
				inputs.server.clientTokens.extra = true
			end,
		},
		{
			label = "client runtime extra key",
			mutate = function(inputs)
				inputs.clients[1].extra = true
			end,
		},
		{
			label = "client clocks extra key",
			mutate = function(inputs)
				inputs.clients[1].clocks.extra = function() end
			end,
		},
		{
			label = "client frame source extra key",
			mutate = function(inputs)
				inputs.clients[1].postSimulation.extra = true
			end,
		},
	}
	for _, exactNodeCase in exactNodeCases do
		local malformedRuntime = newRuntimeInputs(4, { {}, {}, {}, {} })
		exactNodeCase.mutate(malformedRuntime)
		assertPreflightRejected(
			newManifest(selection, identity),
			identity,
			malformedRuntime,
			exactNodeCase.label
		)
	end

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

-- A yielding destroy is rejected, never resumed, and latches one cleanup termination.
do
	local result, state = openCase(
		workloadSelection("tiny-steady-c2s", 1),
		1,
		{ {} },
		nil,
		{ yieldDestroy = true }
	)
	assert(result.kind == "Ready", "yielding destroy case must open before cleanup")
	for index = #result.ports, 1, -1 do
		result.ports[index].side.teardown()
	end
	local first = result.closeGenerationRoot()
	local second = result.closeGenerationRoot()
	assert(first ~= nil, "yielding destroy must report cleanup failure")
	assert(first.code == "CleanupFailure" and first.stage == "Finalize", "yielding destroy code differs")
	assert(rawequal(first, second), "yielding destroy must return the identical cached termination")
	assert(table.isfrozen(first), "yielding destroy termination must be frozen")
	assert(state.destroyCalls() == 1, "yielding destroy must be entered once and never resumed")
end

-- A throwing root factory is allocation-atomic and remains a fixed SetupFailed value.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local runtimeInputs = newRuntimeInputs(1, { {} })
	local factory, _, constructCount = newFactory()
	local rootFactory, _, rootCalls, destroyCalls = newRootFactory({ failFactory = true })
	local prepared = SessionOwner.prepare(manifest, identity, runtimeInputs)
	assert(prepared.kind == "Prepared", "root factory failure case must prepare")
	local malformedResult = SessionOwner.openPrepared(prepared.value, factory, {} :: any)
	assertInternalFailed(malformedResult, manifest, "malformed root factory")
	local result = SessionOwner.openPrepared(prepared.value, factory, rootFactory)
	assertSetupFailed(result, manifest, "root factory failure")
	assert(rawequal(result.manifest, prepared.value.manifest), "root failure must carry prepared manifest")
	assert(rootCalls() == 1 and constructCount() == 0, "root factory failure counts differ")
	assert(destroyCalls() == 0, "throwing allocation-atomic factory must expose no root to destroy")
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
		local prepared = SessionOwner.prepare(manifest, identity, runtimeInputs)
		assert(prepared.kind == "Prepared", `{label} must prepare`)
		local result = SessionOwner.openPrepared(prepared.value, factory, rootFactory)
		if expectedCode == "InternalFailed" then
			assertInternalFailed(result, manifest, label)
			assert(rawequal(result.manifest, prepared.value.manifest), `{label} must carry prepared manifest`)
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
	end, "InternalFailed", 1, "extra lease key")

	assertLeaseFailure(function(destroy)
		return setmetatable({ resourceRoot = {}, destroy = function()
			destroy(false)
		end }, {})
	end, "InternalFailed", 1, "lease metatable")

	assertLeaseFailure(function(destroy)
		return { resourceRoot = nil, destroy = function()
			destroy(false)
		end }
	end, "InternalFailed", 1, "nil lease root")

	assertLeaseFailure(function(_destroy)
		return { resourceRoot = {}, destroy = true }
	end, "CleanupFailure", 0, "nonfunction lease destroy")

	assertLeaseFailure(function(_destroy)
		return { resourceRoot = {} }
	end, "CleanupFailure", 0, "missing lease destroy")

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
	assertSetupFailed(result, state.manifest, "partial construction")
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


-- A malformed trusted adapter factory is a harness invariant, not an adapter setup failure.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local identity = repositoryIdentity()
	local manifest = newManifest(selection, identity)
	local runtimeInputs = newRuntimeInputs(1, { {} })
	local rootFactory, _, rootCalls, destroyCalls = newRootFactory()
	local prepared = SessionOwner.prepare(manifest, identity, runtimeInputs)
	assert(prepared.kind == "Prepared", "malformed adapter factory case must prepare")
	local result = SessionOwner.openPrepared(prepared.value, {} :: any, rootFactory)
	assertInternalFailed(result, manifest, "malformed adapter factory")
	assert(rawequal(result.manifest, prepared.value.manifest), "internal failure must carry prepared manifest")
	assert(rootCalls() == 1, "malformed adapter factory must create one root")
	assert(destroyCalls() == 1, "malformed adapter factory must clean up its root")
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

-- Creation callouts that suspend or return extra values make cleanup ownership unprovable.
do
	local factoryCases = {
		{ label = "yielding root factory", rootOptions = { yieldFactory = true }, destroyCount = 0 },
		{ label = "multi-return root factory", rootOptions = { multiReturnFactory = true }, destroyCount = 1 },
	}
	for _, factoryCase in factoryCases do
		local result, state = openCase(
			workloadSelection("tiny-steady-c2s", 1),
			1,
			{ {} },
			nil,
			factoryCase.rootOptions
		)
		assertTermination(result, "CleanupFailure", "Finalize", factoryCase.label)
		assert(state.rootCalls() == 1, `{factoryCase.label} must enter once`)
		assert(state.constructCount() == 0, `{factoryCase.label} must not construct`)
		assert(state.destroyCalls() == factoryCase.destroyCount, `{factoryCase.label} destroy count differs`)
		for _, entry in state.log do
			assert(entry ~= "resumed:factory", `{factoryCase.label} must never resume`)
		end
	end

	local constructCases = {
		{ label = "yielding adapter construction", option = "yieldConstructAt" },
		{ label = "multi-return adapter construction", option = "multiReturnConstructAt" },
	}
	for _, constructCase in constructCases do
		local options = { failConstructAt = false }
		options[constructCase.option] = "client1"
		local result, state = openCase(
			workloadSelection("state-broadcast-s2c", 4),
			4,
			{ {}, {}, {}, {} },
			options
		)
		assertTermination(result, "CleanupFailure", "Finalize", constructCase.label)
		assert(state.constructCount() == 2, `{constructCase.label} call count differs`)
		assert(state.destroyCalls() == 1, `{constructCase.label} must destroy root`)
		assert(state.log[#state.log - 1] == "teardown:server", `{constructCase.label} must roll back known side`)
		assert(state.log[#state.log] == "destroy:root", `{constructCase.label} must finish root cleanup`)
		for _, entry in state.log do
			assert(entry ~= "resumed:construct:client1", `{constructCase.label} must never resume`)
		end
	end
end

-- Rollback cleanup callouts always continue in reverse order after yield or extra results.
do
	local teardownCases = {
		{ label = "yielding teardown", option = "yieldTeardownAt" },
		{ label = "multi-return teardown", option = "multiReturnTeardownAt" },
	}
	for _, teardownCase in teardownCases do
		local options = { failConstructAt = "client2" }
		options[teardownCase.option] = "client1"
		local result, state = openCase(
			workloadSelection("state-broadcast-s2c", 4),
			4,
			{ {}, {}, {}, {} },
			options
		)
		assertTermination(result, "CleanupFailure", "Finalize", teardownCase.label)
		assert(state.destroyCalls() == 1, `{teardownCase.label} must destroy root`)
		assert(state.log[#state.log - 1] == "teardown:server", `{teardownCase.label} must continue reverse teardown`)
		assert(state.log[#state.log] == "destroy:root", `{teardownCase.label} must finish root cleanup`)
		for _, entry in state.log do
			assert(entry ~= "resumed:teardown:client1", `{teardownCase.label} must never resume`)
		end
	end

	local result, state = openCase(
		workloadSelection("tiny-steady-c2s", 1),
		1,
		{ {} },
		nil,
		{ multiReturnDestroy = true }
	)
	assert(result.kind == "Ready", "multi-return destroy case must construct")
	for index = #result.ports, 1, -1 do
		result.ports[index].side.teardown()
	end
	local first = result.closeGenerationRoot()
	local second = result.closeGenerationRoot()
	assert(first ~= nil and rawequal(first, second), "multi-return destroy failure must be cached")
	assert(first.code == "CleanupFailure" and first.stage == "Finalize", "multi-return destroy code differs")
	assert(state.destroyCalls() == 1, "multi-return destroy must enter exactly once")
end

-- Normal cleanup folds only unprovable teardown completion into root cleanup.
do
	local teardownCases = {
		{ label = "normal yielding teardown", option = "yieldTeardownAt" },
		{ label = "normal multi-return teardown", option = "multiReturnTeardownAt" },
	}
	for _, teardownCase in teardownCases do
		local options = {}
		options[teardownCase.option] = "client1"
		local result, state = openCase(
			workloadSelection("tiny-steady-c2s", 1),
			1,
			{ {} },
			options
		)
		assert(result.kind == "Ready", `{teardownCase.label} must construct`)
		for index = #result.ports, 1, -1 do
			pcall(result.ports[index].side.teardown)
		end
		local cleanup = result.closeGenerationRoot()
		assert(cleanup ~= nil, `{teardownCase.label} must escalate cleanup`)
		assert(cleanup.code == "CleanupFailure" and cleanup.stage == "Finalize", `{teardownCase.label} code differs`)
		assert(state.destroyCalls() == 1, `{teardownCase.label} must destroy root once`)
		for _, entry in state.log do
			assert(entry ~= "resumed:teardown:client1", `{teardownCase.label} must never resume`)
		end
	end

	local result, state = openCase(
		workloadSelection("tiny-steady-c2s", 1),
		1,
		{ {} },
		{ failTeardownAt = "client1" }
	)
	assert(result.kind == "Ready", "normal throwing teardown must construct")
	for index = #result.ports, 1, -1 do
		pcall(result.ports[index].side.teardown)
	end
	assert(result.closeGenerationRoot() == nil, "ordinary teardown throw must not become root cleanup failure")
	assert(state.destroyCalls() == 1, "ordinary teardown throw must still destroy root once")
end

print("PASS Relay.Benchmarks.SessionOwner")
