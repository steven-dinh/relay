local DeliveryRouter = require("../runner/DeliveryRouter")

local STATE_ERROR = "DELIVERY_ROUTER_E_STATE"
local HANDLER_ERROR = "DELIVERY_ROUTER_E_HANDLER"

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

local function assertError(operation, expected, label)
	local ok, problem = pcall(operation)
	assert(not ok, `{label} must fail`)
	assert(tostring(problem) == expected, `{label} expected {expected}, got {tostring(problem)}`)
end

local function noop()
	return nil
end

local function armRoute(route, handler)
	assert(route.gate.bind(handler) == true, "bind must succeed")
	assert(route.gate.arm() == true, "arm must succeed")
end

-- The public surface and every returned capability are exact and frozen.
assertExactKeys(DeliveryRouter, { "newServer", "newClient" }, "DeliveryRouter")
assert(table.isfrozen(DeliveryRouter), "DeliveryRouter must be frozen")
assert(type(DeliveryRouter.newServer) == "function", "newServer must be a function")
assert(type(DeliveryRouter.newClient) == "function", "newClient must be a function")

local serverRoute = DeliveryRouter.newServer()
local clientRoute = DeliveryRouter.newClient()
for label, route in { server = serverRoute, client = clientRoute } do
	assertExactKeys(route, { "sink", "gate" }, `{label} route`)
	assertExactKeys(route.gate, { "bind", "arm", "beginTeardownObservation", "disable" }, `{label} gate`)
	assert(table.isfrozen(route), `{label} route must be frozen`)
	assert(table.isfrozen(route.gate), `{label} gate must be frozen`)
	assert(type(route.sink) == "function", `{label} sink must be a function`)
	for key, value in next, route.gate do
		assert(type(value) == "function", `{label} gate.{key} must be a function`)
	end
	assert(rawget(route.gate, "sink") == nil, `{label} gate must not expose its sink`)
	assert(rawget(route.gate, "state") == nil, `{label} gate must not expose state`)
	assert(rawget(route.gate, "handler") == nil, `{label} gate must not expose a handler`)
end
assert(serverRoute ~= clientRoute, "routes must be independent")
assert(serverRoute.sink ~= clientRoute.sink, "sinks must be independent")
assert(serverRoute.gate ~= clientRoute.gate, "gates must be independent")
assert(serverRoute.sink == serverRoute.sink, "server sink identity must be stable")
assert(clientRoute.sink == clientRoute.sink, "client sink identity must be stable")
assert(not pcall(function()
	serverRoute.extra = true
end), "route mutation must fail")
assert(not pcall(function()
	serverRoute.gate.extra = true
end), "gate mutation must fail")

-- A callback before bind latches permanently without inspecting or retaining its arguments.
do
	local traversals = 0
	local hostile = setmetatable({}, {
		__index = function()
			traversals += 1
			error("must-not-run")
		end,
		__iter = function()
			traversals += 1
			error("must-not-run")
		end,
		__len = function()
			traversals += 1
			error("must-not-run")
		end,
		__tostring = function()
			traversals += 1
			error("must-not-run")
		end,
	})
	local route = DeliveryRouter.newServer()
	route.sink(hostile, hostile, hostile)
	assert(traversals == 0, "pre-bind callback must not inspect arguments")
	assert(route.gate.bind(noop) == false, "bind must report a pre-bind callback")
	assert(route.gate.arm() == false, "arm must preserve a pre-bind callback")
	route.sink(hostile)
	assert(traversals == 0, "latched route must remain a no-op")
	assert(route.gate.disable() == "PreReadyViolation", "disable must report the pre-bind callback")
	assert(route.gate.disable() == "PreReadyViolation", "disable result must remain persistent")
end

-- A callback between bind and arm clears the bound handler and reports the same fixed latch.
do
	local calls = 0
	local route = DeliveryRouter.newClient()
	assert(route.gate.bind(function()
		calls += 1
	end) == true, "initial bind must succeed")
	route.sink({}, {})
	assert(calls == 0, "pre-arm callback must not enter the bound handler")
	assert(route.gate.arm() == false, "arm must report a pre-arm callback")
	assert(route.gate.bind(noop) == false, "pre-arm latch must not accept a replacement handler")
	route.sink({}, {})
	assert(calls == 0, "pre-arm latch must make later callbacks no-ops")
	assert(route.gate.disable() == "PreReadyViolation", "disable must report the pre-arm callback")
end

-- Armed server and client routes forward exact arity, nil holes, and opaque references once.
for _, constructor in { DeliveryRouter.newServer, DeliveryRouter.newClient } do
	local route = constructor()
	local calls = {}
	armRoute(route, function(...)
		local handlerArgumentCount = select("#", ...)
		local argumentCount, delivery, metadata = ...
		table.insert(calls, {
			handlerArgumentCount = handlerArgumentCount,
			argumentCount = argumentCount,
			delivery = delivery,
			metadata = metadata,
		})
	end)

	local delivery = {}
	local metadata = {}
	route.sink()
	route.sink(delivery)
	route.sink(delivery, nil)
	route.sink(nil, metadata, "ignored", nil)
	route.sink(delivery, metadata)

	assert(#calls == 5, "armed route must invoke its handler once per callback")
	for index, call in calls do
		assert(call.handlerArgumentCount == 3, `handler call {index} must receive exactly three arguments`)
	end
	assert(calls[1].argumentCount == 0 and calls[1].delivery == nil and calls[1].metadata == nil, "zero-arity forwarding differs")
	assert(calls[2].argumentCount == 1 and calls[2].delivery == delivery and calls[2].metadata == nil, "one-argument forwarding differs")
	assert(calls[3].argumentCount == 2 and calls[3].delivery == delivery and calls[3].metadata == nil, "nil metadata forwarding differs")
	assert(calls[4].argumentCount == 4 and calls[4].delivery == nil and calls[4].metadata == metadata, "nil-hole arity forwarding differs")
	assert(calls[5].argumentCount == 2 and calls[5].delivery == delivery and calls[5].metadata == metadata, "two-argument forwarding differs")
	assert(route.gate.disable() == "Clean", "armed route must disable cleanly")
end

-- Observation replaces the active handler and forwards no callback arguments to the stale handler.
do
	local activeCalls = 0
	local staleCalls = 0
	local staleArgumentCount = nil
	local route = DeliveryRouter.newServer()
	armRoute(route, function()
		activeCalls += 1
	end)
	route.sink({}, {})
	assert(activeCalls == 1, "active handler must receive an armed callback")
	route.gate.beginTeardownObservation(function(...)
		staleCalls += 1
		staleArgumentCount = select("#", ...)
	end)

	local hostile = setmetatable({}, {
		__index = function()
			error("must-not-run")
		end,
		__iter = function()
			error("must-not-run")
		end,
		__len = function()
			error("must-not-run")
		end,
	})
	route.sink(hostile, hostile, hostile)
	assert(activeCalls == 1, "observing route must release the active handler")
	assert(staleCalls == 1 and staleArgumentCount == 0, "observing route must invoke only the zero-argument stale handler")
	assert(route.gate.disable() == "Clean", "observing route must disable cleanly")
	route.sink(hostile, hostile)
	assert(staleCalls == 1, "disabled observing route must not invoke its stale handler")
end

-- Invalid stale handlers are rejected before the active handler is replaced.
do
	local activeCalls = 0
	local route = DeliveryRouter.newClient()
	armRoute(route, function()
		activeCalls += 1
	end)
	assertError(function()
		route.gate.beginTeardownObservation(false)
	end, HANDLER_ERROR, "nonfunction stale handler")
	route.sink({}, {})
	assert(activeCalls == 1, "invalid stale handler must leave the active route armed")
	route.gate.beginTeardownObservation(noop)
	assert(route.gate.disable() == "Clean", "route must remain usable after invalid stale handler")
end

-- Nonfunction bind handlers leave an unbound route available for the one valid bind.
do
	local route = DeliveryRouter.newServer()
	for _, value in { false, 0, {}, "handler" } do
		assertError(function()
			route.gate.bind(value)
		end, HANDLER_ERROR, `nonfunction bind handler {tostring(value)}`)
	end
	assert(route.gate.bind(noop) == true, "invalid bind candidates must not consume bind")
	assert(route.gate.arm() == true, "route must arm after a valid bind")
	assert(route.gate.disable() == "Clean", "route must disable cleanly")
end

-- Every trusted lifecycle misuse returns the fixed state error.
do
	local route = DeliveryRouter.newServer()
	assertError(function()
		route.gate.arm()
	end, STATE_ERROR, "arm before bind")
	assertError(function()
		route.gate.beginTeardownObservation(noop)
	end, STATE_ERROR, "observe before bind")
	assert(route.gate.bind(noop) == true, "bind after nonmutating misuse must succeed")
	assertError(function()
		route.gate.bind(noop)
	end, STATE_ERROR, "repeated bind")
	assertError(function()
		route.gate.beginTeardownObservation(noop)
	end, STATE_ERROR, "observe before arm")
	assert(route.gate.arm() == true, "arm after bind must succeed")
	assertError(function()
		route.gate.arm()
	end, STATE_ERROR, "repeated arm")
	route.gate.beginTeardownObservation(noop)
	assertError(function()
		route.gate.beginTeardownObservation(noop)
	end, STATE_ERROR, "repeated observe")
	assertError(function()
		route.gate.bind(noop)
	end, STATE_ERROR, "bind while observing")
	assertError(function()
		route.gate.arm()
	end, STATE_ERROR, "arm while observing")
	assert(route.gate.disable() == "Clean", "observing route must disable cleanly")
	assertError(function()
		route.gate.bind(noop)
	end, STATE_ERROR, "bind after disable")
	assertError(function()
		route.gate.arm()
	end, STATE_ERROR, "arm after disable")
	assertError(function()
		route.gate.beginTeardownObservation(noop)
	end, STATE_ERROR, "observe after disable")
end

-- Disable is legal and idempotent from every reachable nonviolating state.
for _, case in {
	{
		label = "unbound",
		prepare = function(_)
			return nil
		end,
	},
	{
		label = "bound",
		prepare = function(route)
			assert(route.gate.bind(noop) == true)
		end,
	},
	{
		label = "armed",
		prepare = function(route)
			armRoute(route, noop)
		end,
	},
	{
		label = "observing",
		prepare = function(route)
			armRoute(route, noop)
			route.gate.beginTeardownObservation(noop)
		end,
	},
} do
	local route = DeliveryRouter.newClient()
	case.prepare(route)
	assert(route.gate.disable() == "Clean", `{case.label} disable must be clean`)
	assert(route.gate.disable() == "Clean", `{case.label} disable must be idempotent`)
end

-- A disabled route never traverses callback values, invokes evidence, or changes its result.
do
	local activeCalls = 0
	local traversals = 0
	local route = DeliveryRouter.newServer()
	armRoute(route, function()
		activeCalls += 1
	end)
	assert(route.gate.disable() == "Clean", "disable must succeed")
	local hostile = setmetatable({}, {
		__index = function()
			traversals += 1
			error("must-not-run")
		end,
		__iter = function()
			traversals += 1
			error("must-not-run")
		end,
		__len = function()
			traversals += 1
			error("must-not-run")
		end,
		__tostring = function()
			traversals += 1
			error("must-not-run")
		end,
	})
	for _ = 1, 100 do
		route.sink(hostile, nil, hostile, hostile)
	end
	assert(activeCalls == 0, "post-disable callback must not invoke the released handler")
	assert(traversals == 0, "post-disable callback must not traverse arguments")
	assert(route.gate.disable() == "Clean", "post-disable result must remain stable")
end

print("PASS Relay.Benchmarks.DeliveryRouter")
