local AdapterContract = require("../adapters/AdapterContract")

local STUDIO_VERSION = "0.650.0.6500000"
local SECRET = "must-not-appear-in-errors"

local function assertExactKeys(value, expectedKeys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local allowed = {}
	for _, key in expectedKeys do
		allowed[key] = true
	end

	local count = 0
	for key in next, value do
		count += 1
		assert(rawget(allowed, key) == true, `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #expectedKeys, `{label} must have exactly {#expectedKeys} keys`)
end

local function assertDeepFrozen(value, label, seen)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	assert(table.isfrozen(value), `{label} must be frozen`)
	for key, nested in next, value do
		assertDeepFrozen(key, `{label}.key`, seen)
		assertDeepFrozen(nested, `{label}.{tostring(key)}`, seen)
	end
end

local function assertError(operation, expected, label)
	local ok, problem = pcall(operation)
	assert(not ok, `{label} must fail`)
	local message = tostring(problem)
	assert(message == expected, `{label} expected {expected}, got {message}`)
	assert(not string.find(message, SECRET, 1, true), `{label} reflected a hostile value`)
	return message
end

local function assertErrorPrefix(operation, expectedPrefix, label)
	local ok, problem = pcall(operation)
	assert(not ok, `{label} must fail`)
	local message = tostring(problem)
	assert(
		string.sub(message, 1, #expectedPrefix) == expectedPrefix,
		`{label} expected prefix {expectedPrefix}, got {message}`
	)
	assert(not string.find(message, SECRET, 1, true), `{label} reflected a hostile value`)
	return message
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

local function supported(selection, identity)
	local result = AdapterContract.preflight(identity or repositoryIdentity(), selection, STUDIO_VERSION)
	assert(result.kind == "Supported", "test preflight must be Supported")
	return result
end

local function noop()
	return nil
end

local function operationFor(selection, side)
	if side == "Server" then
		if selection.kind == "SeparateProbe" or selection.direction == "ServerToClient" then
			return "broadcast"
		end
	else
		if selection.kind == "SeparateProbe" or selection.direction == "ClientToServer" then
			return "submit"
		end
	end
	return nil
end

local function sideFor(selection, side, hooks)
	hooks = hooks or {}
	local result = {
		setup = hooks.setup or noop,
		ready = hooks.ready or function()
			return true
		end,
		teardown = hooks.teardown or noop,
	}
	local operation = operationFor(selection, side)
	if operation ~= nil then
		result[operation] = hooks.operation or noop
	end
	return result
end

local function basicFactory(hooks)
	hooks = hooks or {}
	local observed = {
		serverContexts = {},
		clientContexts = {},
	}
	local factory = {
		constructServer = function(context)
			table.insert(observed.serverContexts, context)
			if hooks.constructServer ~= nil then
				return hooks.constructServer(context)
			end
			return sideFor(context.selection, "Server", hooks.server)
		end,
		constructClient = function(context)
			table.insert(observed.clientContexts, context)
			if hooks.constructClient ~= nil then
				return hooks.constructClient(context)
			end
			return sideFor(context.selection, "Client", hooks.client)
		end,
	}
	return factory, observed
end

local function readySide(side)
	side.setup()
	assert(side.ready() == true, "side must become ready")
end

-- The runtime surface is frozen and has exactly the five approved keys.
assertExactKeys(
	AdapterContract,
	{ "preflight", "constructServer", "constructClient", "recordDelivery", "positionalDelivery" },
	"AdapterContract"
)
assert(table.isfrozen(AdapterContract), "AdapterContract must be frozen")
for key, value in next, AdapterContract do
	assert(type(value) == "function", `AdapterContract.{key} must be a function`)
end

-- Studio-version validation is constant and non-reflecting.
for _, case in {
	{ label = "wrong type", value = {} },
	{ label = "empty", value = "" },
	{ label = "too long", value = string.rep("a", 65) },
	{ label = "whitespace", value = "0.650 " .. SECRET },
	{ label = "slash", value = "0.650/" .. SECRET },
	{ label = "unicode", value = "0.650-☃" },
} do
	assertError(function()
		AdapterContract.preflight(repositoryIdentity(), workloadSelection("tiny-steady-c2s", 1), case.value)
	end, "ADAPTER_E_CONTEXT", `studio version {case.label}`)
end

-- Identity and hostile selection failures preserve only schema-owned paths.
do
	local identity = repositoryIdentity()
	identity[SECRET] = true
	assertError(
		function()
			AdapterContract.preflight(identity, workloadSelection("tiny-steady-c2s", 1), STUDIO_VERSION)
		end,
		"ADAPTER_E_IDENTITY_KEYSET:$.adapter",
		"identity extra key"
	)

	for _, case in {
		{
			label = "unknown workload",
			value = workloadSelection(SECRET, 1),
		},
		{
			label = "invalid recipient count",
			value = workloadSelection("state-broadcast-s2c", 2),
		},
		{
			label = "extra key",
			value = {
				kind = "Workload",
				workloadId = "tiny-steady-c2s",
				recipientCount = 1,
				[SECRET] = true,
			},
		},
		{
			label = "metatable",
			value = setmetatable(workloadSelection("tiny-steady-c2s", 1), { __index = function()
				error(SECRET)
			end }),
		},
	} do
		assertErrorPrefix(function()
			AdapterContract.preflight(repositoryIdentity(), case.value, STUDIO_VERSION)
		end, "ADAPTER_E_CASE:$.selection", `selection {case.label}`)
	end
end

-- Supported and Unsupported arms are detached, deeply frozen, and ordered by shared requirements.
local c2s = supported(workloadSelection("tiny-steady-c2s", 1))
assertExactKeys(c2s, { "kind", "identity", "selection" }, "Supported")
assertDeepFrozen(c2s, "Supported")
assert(c2s.selection.payloadId == "tiny", "preflight must resolve the selected payload")
assert(#c2s.selection.requirements == 3, "client-to-server workload must have three requirements")
assert(c2s.selection.requirements[1].capability == "Direction", "direction must be the first requirement")
assert(c2s.selection.requirements[2].capability == "DeliverySemantics", "delivery must be second")
assert(c2s.selection.requirements[3].capability == "Payload", "payload must be third")

do
	local identity = repositoryIdentity()
	identity.semantics.broadcastMode = "Unsupported"
	identity.capabilities.directions = { "ClientToServer" }
	identity.capabilities.payloadIds = { "tiny" }
	local result = AdapterContract.preflight(
		identity,
		workloadSelection("state-broadcast-s2c", 4),
		STUDIO_VERSION
	)
	assert(result.kind == "Unsupported", "missing capabilities must return Unsupported")
	assertExactKeys(result, { "kind", "identity", "selection", "missing" }, "Unsupported")
	assertDeepFrozen(result, "Unsupported")
	assert(#result.missing == 3, "broadcast case must expose each missing requirement once")
	assert(result.missing[1].capability == "Direction", "missing direction must remain first")
	assert(result.missing[1].required == "ServerToClient", "missing direction value differs")
	assert(result.missing[2].capability == "Payload", "missing payload must remain second")
	assert(result.missing[2].required == "state", "missing payload value differs")
	assert(result.missing[3].capability == "BroadcastMode", "missing broadcast mode must remain third")

	local factoryCalls = 0
	local factory = {
		constructServer = function()
			factoryCalls += 1
			return {}
		end,
		constructClient = function()
			factoryCalls += 1
			return {}
		end,
	}
	assertError(function()
		AdapterContract.constructServer(result, factory, {}, {}, noop)
	end, "ADAPTER_E_PREFLIGHT", "Unsupported construction")
	assert(factoryCalls == 0, "Unsupported construction must not invoke a factory")
end

-- Every Event V1 case resolves with the exact ordered requirements, including
-- all broadcast recipient variants and SeparateProbe.
for _, case in {
	{
		selection = workloadSelection("tiny-steady-c2s", 1),
		expected = { "Direction:ClientToServer", "DeliverySemantics:ReliableOrdered", "Payload:tiny" },
	},
	{
		selection = workloadSelection("state-steady-c2s", 1),
		expected = { "Direction:ClientToServer", "DeliverySemantics:ReliableOrdered", "Payload:state" },
	},
	{
		selection = workloadSelection("state-burst-c2s", 1),
		expected = { "Direction:ClientToServer", "DeliverySemantics:ReliableOrdered", "Payload:state" },
	},
	{
		selection = workloadSelection("state-broadcast-s2c", 1),
		expected = { "Direction:ServerToClient", "DeliverySemantics:ReliableOrdered", "Payload:state", "BroadcastMode:Broadcast" },
	},
	{
		selection = workloadSelection("state-broadcast-s2c", 4),
		expected = { "Direction:ServerToClient", "DeliverySemantics:ReliableOrdered", "Payload:state", "BroadcastMode:Broadcast" },
	},
	{
		selection = workloadSelection("state-broadcast-s2c", 8),
		expected = { "Direction:ServerToClient", "DeliverySemantics:ReliableOrdered", "Payload:state", "BroadcastMode:Broadcast" },
	},
	{
		selection = probeSelection(),
		expected = {
			"Direction:ClientToServer",
			"Direction:ServerToClient",
			"DeliverySemantics:ReliableOrdered",
			"Payload:tiny",
			"BroadcastMode:Broadcast",
		},
	},
} do
	local result = supported(case.selection)
	assert(#result.selection.requirements == #case.expected, "resolved requirement count differs")
	for index, requirement in result.selection.requirements do
		assert(
			`{requirement.capability}:{requirement.required}` == case.expected[index],
			`resolved requirement {index} differs`
		)
	end
end

-- Only values returned as Supported by this module carry construction/envelope authority.
do
	local forged = {
		kind = c2s.kind,
		identity = c2s.identity,
		selection = c2s.selection,
	}
	local factory = basicFactory()
	assertError(function()
		AdapterContract.constructClient(forged, factory, {}, 1, noop)
	end, "ADAPTER_E_PREFLIGHT", "copied preflight")
	assertError(function()
		AdapterContract.positionalDelivery(forged, 1, true)
	end, "ADAPTER_E_PREFLIGHT", "forged positional preflight")
	assert(not pcall(function()
		c2s.kind = "Unsupported"
	end), "Supported preflight must reject mutation")
end

-- Factory and returned-side records are raw, no-metatable, exact function records.
do
	local validFactory = basicFactory()
	local invalidFactories = {
		{
			label = "missing constructor",
			value = { constructServer = noop },
		},
		{
			label = "non-function constructor",
			value = { constructServer = noop, constructClient = SECRET },
		},
		{
			label = "extra key",
			value = { constructServer = noop, constructClient = noop, [SECRET] = true },
		},
		{
			label = "metatable",
			value = setmetatable(validFactory, { __index = function()
				error(SECRET)
			end }),
		},
	}
	for _, case in invalidFactories do
		assertError(function()
			AdapterContract.constructClient(c2s, case.value, {}, 1, noop)
		end, "ADAPTER_E_FACTORY", `factory {case.label}`)
	end

	for _, case in {
		{
			label = "extra side key",
			side = { setup = noop, ready = function()
				return true
			end, teardown = noop, submit = noop, [SECRET] = true },
		},
		{
			label = "missing selected operation",
			side = { setup = noop, ready = function()
				return true
			end, teardown = noop },
		},
		{
			label = "side metatable",
			side = setmetatable({ setup = noop, ready = function()
				return true
			end, teardown = noop, submit = noop }, { __index = noop }),
		},
	} do
		local factory = basicFactory({
			constructClient = function()
				return case.side
			end,
		})
		assertError(function()
			AdapterContract.constructClient(c2s, factory, {}, 1, noop)
		end, "ADAPTER_E_FACTORY", case.label)
	end

	local factory = basicFactory({
		constructClient = function()
			error(SECRET)
		end,
	})
	assertError(function()
		AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	end, "ADAPTER_E_CONSTRUCT", "constructor exception")
end

-- Context construction copies only its own records while preserving opaque roots and participant tokens.
do
	local broadcast = supported(workloadSelection("state-broadcast-s2c", 4))
	local tokenMetatable = { __eq = function()
		return true
	end }
	local tokens = {
		setmetatable({}, tokenMetatable),
		setmetatable({}, tokenMetatable),
		setmetatable({}, tokenMetatable),
		setmetatable({}, tokenMetatable),
	}
	local resourceRoot = setmetatable({}, {
		__index = function()
			error(SECRET)
		end,
		__iter = function()
			error(SECRET)
		end,
	})
	local serverSink = noop
	local clientSink = noop
	local factory, observed = basicFactory()
	local server = AdapterContract.constructServer(broadcast, factory, resourceRoot, tokens, serverSink)
	local client = AdapterContract.constructClient(broadcast, factory, resourceRoot, 4, clientSink)
	local serverContext = observed.serverContexts[1]
	local clientContext = observed.clientContexts[1]

	assertExactKeys(serverContext, { "resourceRoot", "selection", "recipients", "envelopes", "sink" }, "server context")
	assertExactKeys(clientContext, { "resourceRoot", "selection", "participantIndex", "envelopes", "sink" }, "client context")
	assert(table.isfrozen(serverContext) and table.isfrozen(clientContext), "context records must be frozen")
	assert(serverContext.resourceRoot == resourceRoot and clientContext.resourceRoot == resourceRoot, "resource root must remain opaque")
	assert(serverContext.selection == broadcast.selection and clientContext.selection == broadcast.selection, "selection must be shared")
	assert(serverContext.recipients ~= tokens and table.isfrozen(serverContext.recipients), "recipient array must be a frozen copy")
	for index = 1, 4 do
		assert(serverContext.recipients[index] == tokens[index], `recipient token {index} identity must be preserved`)
	end
	assert(serverContext.sink == serverSink and clientContext.sink == clientSink, "sink must pass through directly")
	assert(clientContext.participantIndex == 4, "participant index differs")
	assertExactKeys(serverContext.envelopes, { "record", "positional" }, "server envelope factory")
	assert(table.isfrozen(serverContext.envelopes), "envelope factory must be frozen")
	local contextRecord = serverContext.envelopes.record(nil)
	local contextPositional = serverContext.envelopes.positional(1, 2, 3, 4, 5, 6, 7)
	assertExactKeys(contextRecord, { "kind" }, "context record delivery")
	assert(contextPositional.count == 7, "selection-bound positional factory must retain actual arity")
	assert(rawget(contextPositional.values, 6) == 6, "state payload factory must retain field-count plus one")
	assert(rawget(contextPositional.values, 7) == nil, "state payload factory exceeded its retention bound")

	tokens[1] = {}
	assert(serverContext.recipients[1] ~= tokens[1], "recipient input mutation must not affect the context copy")
	assertExactKeys(server, { "setup", "ready", "teardown", "broadcast" }, "broadcast server side")
	assertExactKeys(client, { "setup", "ready", "teardown" }, "broadcast client side")
	assert(table.isfrozen(server) and table.isfrozen(client), "wrapped sides must be frozen")

	local invalidRecipients = {
		{ label = "too few", value = { {}, {}, {} } },
		{ label = "too many", value = { {}, {}, {}, {}, {} } },
		{ label = "sparse", value = { [1] = {}, [2] = {}, [4] = {} } },
		{ label = "extra key", value = { {}, {}, {}, {}, [SECRET] = true } },
	}
	local duplicate = {}
	table.insert(invalidRecipients, { label = "duplicate", value = { duplicate, {}, duplicate, {} } })
	table.insert(invalidRecipients, {
		label = "metatable",
		value = setmetatable({ {}, {}, {}, {} }, { __index = noop }),
	})
	for _, case in invalidRecipients do
		assertError(function()
			AdapterContract.constructServer(broadcast, factory, {}, case.value, noop)
		end, "ADAPTER_E_CONTEXT", `recipients {case.label}`)
	end

	for _, case in {
		{ label = "zero", value = 0 },
		{ label = "fraction", value = 1.5 },
		{ label = "too high", value = 5 },
		{ label = "infinity", value = math.huge },
	} do
		assertError(function()
			AdapterContract.constructClient(broadcast, factory, {}, case.value, noop)
		end, "ADAPTER_E_CONTEXT", `participant index {case.label}`)
	end

	assertError(function()
		AdapterContract.constructServer(broadcast, factory, nil, { {}, {}, {}, {} }, noop)
	end, "ADAPTER_E_CONTEXT", "nil resource root")
	assertError(function()
		AdapterContract.constructClient(broadcast, factory, {}, 1, SECRET)
	end, "ADAPTER_E_CONTEXT", "non-function sink")
end

-- Each selection exposes only its approved case-specific operation.
for _, case in {
	{
		label = "client-to-server",
		preflight = c2s,
		recipients = {},
		serverKeys = { "setup", "ready", "teardown" },
		clientKeys = { "setup", "ready", "teardown", "submit" },
	},
	{
		label = "server-to-client",
		preflight = supported(workloadSelection("state-broadcast-s2c", 1)),
		recipients = { {} },
		serverKeys = { "setup", "ready", "teardown", "broadcast" },
		clientKeys = { "setup", "ready", "teardown" },
	},
	{
		label = "separate probe",
		preflight = supported(probeSelection()),
		recipients = { {} },
		serverKeys = { "setup", "ready", "teardown", "broadcast" },
		clientKeys = { "setup", "ready", "teardown", "submit" },
	},
} do
	local factory = basicFactory()
	local server = AdapterContract.constructServer(case.preflight, factory, {}, case.recipients, noop)
	local client = AdapterContract.constructClient(case.preflight, factory, {}, 1, noop)
	assertExactKeys(server, case.serverKeys, `{case.label} server`)
	assertExactKeys(client, case.clientKeys, `{case.label} client`)
	assert(rawget(server, "start") == nil and rawget(client, "start") == nil, "start must remain absent")
	assert(rawget(server, "receive") == nil and rawget(client, "receive") == nil, "receive must remain absent")
end

-- Record delivery is conditional-key, opaque, reference-preserving, and frozen.
do
	local nilDelivery = AdapterContract.recordDelivery(nil)
	assertExactKeys(nilDelivery, { "kind" }, "nil record delivery")
	assert(nilDelivery.kind == "Record" and rawget(nilDelivery, "value") == nil, "nil record arm differs")

	local value = setmetatable({ original = true }, {
		__index = function()
			error(SECRET)
		end,
		__iter = function()
			error(SECRET)
		end,
	})
	local delivery = AdapterContract.recordDelivery(value)
	assertExactKeys(delivery, { "kind", "value" }, "non-nil record delivery")
	assert(delivery.value == value, "record delivery must retain the original value")
	assert(table.isfrozen(delivery) and not table.isfrozen(value), "only the envelope must be frozen")
	value.after = true
	assert(delivery.value.after == true, "record delivery must not copy or project its value")
end

-- Positional delivery preserves actual arity and nil holes while retaining at most field-count plus one.
do
	local zero = AdapterContract.positionalDelivery(c2s)
	assertExactKeys(zero, { "kind", "values", "count" }, "zero positional delivery")
	assert(zero.kind == "Positional" and zero.count == 0, "zero positional arity differs")
	assert(next(zero.values) == nil, "zero positional values must be empty")
	assert(table.isfrozen(zero) and table.isfrozen(zero.values), "positional output must be deeply frozen")

	local holes = AdapterContract.positionalDelivery(c2s, 1, nil, true)
	assert(holes.count == 3, "middle nil count differs")
	assert(holes.values[1] == 1 and rawget(holes.values, 2) == nil and holes.values[3] == true, "middle nil was not preserved")

	local trailing = AdapterContract.positionalDelivery(c2s, 1, nil)
	assert(trailing.count == 2 and rawget(trailing.values, 2) == nil, "trailing nil count differs")

	local state = supported(workloadSelection("state-steady-c2s", 1))
	local extra = AdapterContract.positionalDelivery(state, 1, 2, 3, 4, 5, 6, 7, 8)
	assert(extra.count == 8, "extra positional arity must remain observable")
	for index = 1, 6 do
		assert(extra.values[index] == index, `retained positional value {index} differs`)
	end
	assert(rawget(extra.values, 7) == nil and rawget(extra.values, 8) == nil, "positional retention exceeded six values")
	assert(not pcall(function()
		extra.values[1] = 0
	end), "positional values must reject mutation")
end

-- Lifecycle wrappers enforce every legal edge, exact argument forwarding, and latching.
do
	local setupCalls = 0
	local readyCalls = 0
	local operationCalls = 0
	local teardownCalls = 0
	local seenPayload = nil
	local seenBoundary = nil
	local factory = basicFactory({
		client = {
			setup = function(...)
				assert(select("#", ...) == 0, "setup must receive no arguments")
				setupCalls += 1
			end,
			ready = function(...)
				assert(select("#", ...) == 0, "ready must receive no arguments")
				readyCalls += 1
				return readyCalls >= 3
			end,
			operation = function(...)
				assert(select("#", ...) == 2, "submit must receive exactly payload and boundary")
				operationCalls += 1
				seenPayload, seenBoundary = ...
			end,
			teardown = function(...)
				assert(select("#", ...) == 0, "teardown must receive no arguments")
				teardownCalls += 1
			end,
		},
	})
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	assertError(function()
		side.ready()
	end, "ADAPTER_E_STATE", "ready before setup")
	assertError(function()
		side.submit({}, "ContinueFrame")
	end, "ADAPTER_E_STATE", "submit before setup")
	side.setup()
	assert(setupCalls == 1, "setup must run exactly once")
	assertError(function()
		side.setup()
	end, "ADAPTER_E_STATE", "duplicate setup")
	assert(side.ready() == false and side.ready() == false and side.ready() == true, "ready polling sequence differs")
	assert(side.ready() == true and readyCalls == 3, "Ready must latch without another adapter poll")
	assertError(function()
		side.submit({}, SECRET)
	end, "ADAPTER_E_OPERATION", "invalid submission boundary")

	local payload = { sequence = 1, enabled = true }
	side.submit(payload, "FlushBeforeReturn")
	assert(operationCalls == 1 and seenPayload == payload, "submit must forward the original payload once")
	assert(seenBoundary == "FlushBeforeReturn", "submit boundary differs")
	assert(payload.sequence == 1 and payload.enabled == true, "contract must not mutate outgoing payload")
	side.teardown()
	side.teardown()
	assert(teardownCalls == 1, "teardown must be idempotent")
	for _, call in {
		function()
			side.setup()
		end,
		function()
			side.ready()
		end,
		function()
			side.submit(payload, "ContinueFrame")
		end,
	} do
		assertError(call, "ADAPTER_E_STATE", "post-teardown operation")
	end
end

-- Setup, readiness, operation, and teardown failures are redacted and remain teardown-safe.
do
	local teardownCalls = 0
	local factory = basicFactory({
		client = {
			setup = function()
				error(SECRET)
			end,
			teardown = function()
				teardownCalls += 1
			end,
		},
	})
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	assertError(function()
		side.setup()
	end, "ADAPTER_E_SETUP", "setup failure")
	assertError(function()
		side.ready()
	end, "ADAPTER_E_STATE", "ready after setup failure")
	side.teardown()
	assert(teardownCalls == 1, "setup failure must remain teardown-safe")
end

for _, case in {
	{
		label = "errored",
		ready = function()
			error(SECRET)
		end,
	},
	{
		label = "non-boolean",
		ready = function()
			return SECRET
		end,
	},
	{
		label = "multi-return",
		ready = function()
			return true, SECRET
		end,
	},
} do
	local factory = basicFactory({ client = { ready = case.ready } })
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	side.setup()
	assertError(function()
		side.ready()
	end, "ADAPTER_E_READY", `{case.label} ready`)
	side.teardown()
end

do
	local reachedBeforeYield = 0
	local reachedAfterYield = 0
	local factory = basicFactory({
		client = {
			ready = function()
				reachedBeforeYield += 1
				coroutine.yield(true)
				reachedAfterYield += 1
				return true
			end,
		},
	})
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	side.setup()
	assertError(function()
		side.ready()
	end, "ADAPTER_E_READY", "yielded ready")
	assert(reachedBeforeYield == 1 and reachedAfterYield == 0, "yielded readiness coroutine must never resume")
	side.teardown()
	assert(reachedAfterYield == 0, "teardown must not resume yielded readiness")
end

do
	local teardownCalls = 0
	local factory = basicFactory({
		client = {
			operation = function()
				error(SECRET)
			end,
			teardown = function()
				teardownCalls += 1
			end,
		},
	})
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	readySide(side)
	assertError(function()
		side.submit({}, "ContinueFrame")
	end, "ADAPTER_E_SUBMIT", "submit failure")
	assertError(function()
		side.submit({}, "ContinueFrame")
	end, "ADAPTER_E_STATE", "submit after execution failure")
	side.teardown()
	assert(teardownCalls == 1, "execution failure must remain teardown-safe")
end

do
	local broadcast = supported(workloadSelection("state-broadcast-s2c", 1))
	local factory = basicFactory({
		server = {
			operation = function()
				error(SECRET)
			end,
		},
	})
	local side = AdapterContract.constructServer(broadcast, factory, {}, { {} }, noop)
	readySide(side)
	assertError(function()
		side.broadcast({}, "ContinueFrame")
	end, "ADAPTER_E_BROADCAST", "broadcast failure")
	side.teardown()
end

do
	local teardownCalls = 0
	local factory = basicFactory({
		client = {
			teardown = function()
				teardownCalls += 1
				error(SECRET)
			end,
		},
	})
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	assertError(function()
		side.teardown()
	end, "ADAPTER_E_TEARDOWN", "teardown failure")
	side.teardown()
	assert(teardownCalls == 1, "failed teardown must still latch TornDown")
	assertError(function()
		side.setup()
	end, "ADAPTER_E_STATE", "setup after failed teardown")
end

-- Flush remains inside the adapter operation and callbacks remain synchronous.
do
	local trace = {}
	local factory = basicFactory({
		client = {
			operation = function(_, boundary)
				table.insert(trace, "send")
				if boundary == "FlushBeforeReturn" then
					table.insert(trace, "flush")
				end
			end,
		},
	})
	local side = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	readySide(side)
	side.submit({}, "FlushBeforeReturn")
	table.insert(trace, "returned")
	assert(table.concat(trace, ",") == "send,flush,returned", "manual flush must finish inside the final operation")
	side.teardown()
end

local function rawExactKeys(value, expected)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local count = 0
	for key in next, value do
		count += 1
		if rawget(expected, key) ~= true then
			return false
		end
	end
	local expectedCount = 0
	for _ in next, expected do
		expectedCount += 1
	end
	return count == expectedCount
end

local function validateEnvelope(delivery)
	if type(delivery) ~= "table" or getmetatable(delivery) ~= nil then
		error("malformed")
	end
	local kind = rawget(delivery, "kind")
	if kind == "Record" then
		local hasValue = rawget(delivery, "value") ~= nil
		if not rawExactKeys(delivery, if hasValue then { kind = true, value = true } else { kind = true }) then
			error("malformed")
		end
	elseif kind == "Positional" then
		if not rawExactKeys(delivery, { kind = true, values = true, count = true }) then
			error("malformed")
		end
		local values = rawget(delivery, "values")
		local count = rawget(delivery, "count")
		if type(values) ~= "table" or getmetatable(values) ~= nil or type(count) ~= "number" or count % 1 ~= 0 or count < 0 then
			error("malformed")
		end
	else
		error("malformed")
	end
end

local function newRunnerSink(direction, authenticatedSender, failAccounting)
	local state = {
		timestampCount = 0,
		trace = {},
		latched = nil,
		accountingCalls = 0,
	}

	local function sink(delivery, metadata)
		state.timestampCount += 1
		table.insert(state.trace, "timestamp")
		if state.latched ~= nil then
			return
		end

		local ok = pcall(function()
			table.insert(state.trace, "envelope")
			validateEnvelope(delivery)
			table.insert(state.trace, "metadata")
			if direction == "ClientToServer" then
				if not rawExactKeys(metadata, { kind = true, sender = true }) or rawget(metadata, "kind") ~= "ClientToServer" then
					error("malformed")
				end
				table.insert(state.trace, "authenticate")
				if rawget(metadata, "sender") == nil or not rawequal(rawget(metadata, "sender"), authenticatedSender) then
					error("spoof")
				end
			else
				if not rawExactKeys(metadata, { kind = true }) or rawget(metadata, "kind") ~= "ServerToClient" then
					error("malformed")
				end
			end
			if failAccounting then
				error("internal")
			end
			state.accountingCalls += 1
			table.insert(state.trace, "account")
		end)

		if not ok then
			state.latched = {
				category = "Harness",
				code = "InternalError",
				stage = "Execution",
			}
		end
	end

	return sink, state
end

local function assertInternalLatch(state, label)
	assert(state.timestampCount >= 1, `{label} must timestamp every sink entry first`)
	assert(state.trace[1] == "timestamp", `{label} first sink action must be timestamp capture`)
	assert(state.latched ~= nil, `{label} must latch a terminal failure`)
	assertExactKeys(state.latched, { "category", "code", "stage" }, `{label} latch`)
	assert(state.latched.category == "Harness" and state.latched.code == "InternalError", `{label} latch differs`)
	assert(state.latched.stage == "Execution", `{label} stage differs`)
	assert(state.accountingCalls == 0, `{label} must not reach accounting`)
end

-- A test-owned timestamp-first non-throwing sink keeps synchronous bad deliveries out of submit failures.
for _, case in {
	{
		label = "malformed envelope",
		delivery = function()
			return { kind = "Record", value = {}, extra = SECRET }
		end,
		metadata = function(sender)
			return { kind = "ClientToServer", sender = sender }
		end,
	},
	{
		label = "malformed metadata",
		delivery = function()
			return AdapterContract.recordDelivery({ sequence = 1 })
		end,
		metadata = function(sender)
			return { kind = "ClientToServer", sender = sender, extra = SECRET }
		end,
	},
	{
		label = "spoofed sender",
		delivery = function()
			return AdapterContract.recordDelivery({ sequence = 1 })
		end,
		metadata = function()
			return { kind = "ClientToServer", sender = {} }
		end,
	},
	{
		label = "internal sink exception",
		delivery = function()
			return AdapterContract.recordDelivery({ sequence = 1 })
		end,
		metadata = function(sender)
			return { kind = "ClientToServer", sender = sender }
		end,
		failAccounting = true,
	},
} do
	local sender = {}
	local serverSink, latch = newRunnerSink("ClientToServer", sender, case.failAccounting)
	local capturedServerSink = nil
	local factory = basicFactory({
		constructServer = function(context)
			capturedServerSink = context.sink
			return sideFor(context.selection, "Server")
		end,
		client = {
			operation = function()
				capturedServerSink(case.delivery(), case.metadata(sender))
			end,
		},
	})
	local server = AdapterContract.constructServer(c2s, factory, {}, {}, serverSink)
	local client = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	readySide(server)
	readySide(client)
	local ok, problem = pcall(function()
		client.submit({ sequence = 1, enabled = true }, "FlushBeforeReturn")
	end)
	assert(ok and problem == nil, `{case.label} must return normally from submit`)
	assertInternalLatch(latch, case.label)
	local firstLatch = latch.latched
	client.submit({ sequence = 2, enabled = false }, "ContinueFrame")
	assert(latch.latched == firstLatch and latch.accountingCalls == 0, `{case.label} latch must be terminal`)
	client.teardown()
	server.teardown()
end

-- Authenticated client-to-server metadata is accepted and never enters the payload envelope.
do
	local sender = {}
	local serverSink, state = newRunnerSink("ClientToServer", sender, false)
	local capturedServerSink = nil
	local observedEnvelope = nil
	local factory = basicFactory({
		constructServer = function(context)
			capturedServerSink = context.sink
			return sideFor(context.selection, "Server")
		end,
		client = {
			operation = function(payload)
				observedEnvelope = AdapterContract.recordDelivery(payload)
				capturedServerSink(observedEnvelope, { kind = "ClientToServer", sender = sender })
			end,
		},
	})
	local server = AdapterContract.constructServer(c2s, factory, {}, {}, serverSink)
	local client = AdapterContract.constructClient(c2s, factory, {}, 1, noop)
	readySide(server)
	readySide(client)
	client.submit({ sequence = 1, enabled = true }, "FlushBeforeReturn")
	assert(state.latched == nil and state.accountingCalls == 1, "authenticated sender must reach accounting")
	assert(rawget(observedEnvelope, "sender") == nil, "sender metadata must never enter the payload envelope")
	client.teardown()
	server.teardown()
end

-- The same non-throwing boundary keeps malformed client metadata out of broadcast failures.
do
	local broadcast = supported(workloadSelection("state-broadcast-s2c", 1))
	local clientSink, state = newRunnerSink("ServerToClient", nil, false)
	local capturedClientSink = nil
	local factory = basicFactory({
		constructClient = function(context)
			capturedClientSink = context.sink
			return sideFor(context.selection, "Client")
		end,
		server = {
			operation = function(payload)
				capturedClientSink(
					AdapterContract.recordDelivery(payload),
					{ kind = "ServerToClient", extra = SECRET }
				)
			end,
		},
	})
	local client = AdapterContract.constructClient(broadcast, factory, {}, 1, clientSink)
	local server = AdapterContract.constructServer(broadcast, factory, {}, { {} }, noop)
	readySide(client)
	readySide(server)
	local ok, problem = pcall(function()
		server.broadcast({ sequence = 1 }, "FlushBeforeReturn")
	end)
	assert(ok and problem == nil, "malformed client metadata must return normally from broadcast")
	assertInternalLatch(state, "malformed broadcast metadata")
	server.teardown()
	client.teardown()
end

-- Exact server-to-client metadata reaches accounting synchronously before the operation returns.
do
	local broadcast = supported(workloadSelection("state-broadcast-s2c", 1))
	local clientSink, state = newRunnerSink("ServerToClient", nil, false)
	local capturedClientSink = nil
	local trace = {}
	local factory = basicFactory({
		constructClient = function(context)
			capturedClientSink = context.sink
			return sideFor(context.selection, "Client")
		end,
		server = {
			operation = function(payload)
				table.insert(trace, "send")
				capturedClientSink(AdapterContract.recordDelivery(payload), { kind = "ServerToClient" })
				table.insert(trace, "sink-returned")
			end,
		},
	})
	local client = AdapterContract.constructClient(broadcast, factory, {}, 1, clientSink)
	local server = AdapterContract.constructServer(broadcast, factory, {}, { {} }, noop)
	readySide(client)
	readySide(server)
	server.broadcast({ sequence = 1 }, "FlushBeforeReturn")
	table.insert(trace, "operation-returned")
	assert(state.latched == nil and state.accountingCalls == 1, "exact client metadata must reach accounting")
	assert(table.concat(trace, ",") == "send,sink-returned,operation-returned", "delivery callback must remain synchronous")
	server.teardown()
	client.teardown()
end

print("PASS Relay.Benchmarks.AdapterContract")
