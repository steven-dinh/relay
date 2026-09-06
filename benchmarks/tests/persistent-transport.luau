local PersistentTransport = require("../runner/PersistentTransport")
local DeliveryRouter = require("../runner/DeliveryRouter")

local function rejects(callback, code)
	local ok, message = pcall(callback)
	assert(not ok and string.find(tostring(message), code, 1, true), tostring(message))
end

local function fixture(isServer)
	local physicalRoot, recipient, envelopes = {}, {}, {}
	local counts = { construct = 0, setup = 0, ready = 0, send = 0, teardown = 0 }
	local rawContext
	local cleanupFails = false
	local function construct(context)
		counts.construct += 1
		rawContext = context
		assert(context.resourceRoot == physicalRoot and context.envelopes == envelopes)
		return {
			setup = function() counts.setup += 1 end,
			ready = function() counts.ready += 1 return true end,
			submit = function(...) counts.send += 1 context.sink(...) end,
			broadcast = function(...) counts.send += 1 context.sink(...) end,
			teardown = function()
				counts.teardown += 1
				if cleanupFails then error("cleanup failed") end
			end,
		}
	end
	local owner = PersistentTransport.new({ constructServer = construct, constructClient = construct }, physicalRoot)
	local function context(sink)
		return {
			resourceRoot = {}, selection = { caseId = "tiny", topology = { clients = 1 } },
			recipients = if isServer then { recipient } else nil,
			participantIndex = if isServer then nil else 1,
			envelopes = envelopes, sink = sink or function() end,
		}
	end
	return owner, counts, context, function(...) rawContext.sink(...) end,
		function() cleanupFails = true end
end

for _, isServer in { false, true } do
	local owner, counts, context = fixture(isServer)
	local construct = owner.factory[if isServer then "constructServer" else "constructClient"]
	local previousMarker
	for window = 1, 30 do
		local received = 0
		local payload, metadata, timestamp = {}, {}, 12.5
		local logicalContext = context(function(...)
			assert(select("#", ...) == 3)
			local actual, meta, receipt = ...
			assert(actual == payload and meta == metadata and receipt == timestamp)
			received += 1
		end)
		assert(logicalContext.resourceRoot ~= previousMarker)
		previousMarker = logicalContext.resourceRoot
		local side = construct(logicalContext)
		side.setup()
		assert(side.ready())
		side[if isServer then "broadcast" else "submit"](payload, metadata, timestamp)
		assert(received == 1)
		side.teardown()
		side.teardown()
		assert(counts.teardown == 0)
		owner.assertHealthy()
	end
	owner.close()
	owner.close()
	assert(counts.construct == 1 and counts.setup == 1 and counts.ready == 30)
	assert(counts.send == 30 and counts.teardown == 1)
	rejects(function() construct(context()) end, "PERSISTENT_TRANSPORT_E_STATE")
end

for _, failureKind in { "gap", "forward", "selection", "roster", "index", "cleanup" } do
	local server = failureKind == "roster"
	local owner, counts, context, emit, failCleanup = fixture(server)
	local construct = owner.factory[if server then "constructServer" else "constructClient"]
	local side = construct(context(if failureKind == "forward" then function() error("sink failed") end else nil))
	side.setup()
	assert(side.ready())
	local expected
	if failureKind == "forward" then
		emit({}, {})
		expected = "PERSISTENT_TRANSPORT_E_DELIVERY"
	elseif failureKind == "gap" then
		side.teardown()
		emit({}, {})
		emit({}, {})
		expected = "PERSISTENT_TRANSPORT_E_GAP_DELIVERY"
	elseif failureKind == "cleanup" then
		failCleanup()
		expected = "PERSISTENT_TRANSPORT_E_CLEANUP"
	else
		side.teardown()
		local changed = context()
		if failureKind == "selection" then changed.selection.topology.clients = 2
		elseif failureKind == "roster" then changed.recipients[1] = {}
		else changed.participantIndex = 2 end
		expected = if failureKind == "roster" then "PERSISTENT_TRANSPORT_E_ROSTER" else "PERSISTENT_TRANSPORT_E_SELECTION"
		rejects(function() construct(changed) end, expected)
	end
	if failureKind ~= "cleanup" then rejects(owner.assertHealthy, expected) end
	side.teardown()
	rejects(owner.close, expected)
	rejects(owner.close, expected)
	rejects(owner.assertHealthy, expected)
	assert(counts.teardown == 1)
end

-- The persistent sink delegates ownership checks to the current real router.
-- A late prior-window delivery is rejected by that window's sequence validator.
do
	local owner, counts, context, emit = fixture(false)
	for window = 1, 2 do
		local route = DeliveryRouter.newClient()
		assert(route.gate.bind(function(argumentCount, delivery, metadata)
			assert(argumentCount == 2 and metadata.kind == "ServerToClient")
			assert(delivery.sequence == window, "stale window")
		end))
		local side = owner.factory.constructClient(context(route.sink))
		side.setup()
		assert(side.ready())
		assert(route.gate.arm())
		emit({ sequence = window }, { kind = "ServerToClient" })
		owner.assertHealthy()
		if window == 2 then
			emit({ sequence = 1 }, { kind = "ServerToClient" })
			rejects(owner.assertHealthy, "PERSISTENT_TRANSPORT_E_DELIVERY")
		end
		side.teardown()
		route.gate.disable()
	end
	rejects(owner.close, "PERSISTENT_TRANSPORT_E_DELIVERY")
	assert(counts.teardown == 1)
end

-- Physical calls cannot hide invalid returns or yield past the owner boundary.
for _, operation in { "construct", "setup", "ready", "submit", "teardown" } do
	for _, violation in { "returns", "yields" } do
		local cleanupCalls, resumed = 0, false
		local function violate()
			if violation == "yields" then
				coroutine.yield()
				resumed = true
			end
			return true, nil
		end
		local rawSide = {
			setup = function() end,
			ready = function() return true end,
			submit = function() end,
			teardown = function() cleanupCalls += 1 end,
		}
		if operation ~= "construct" then
			rawSide[operation] = function()
				if operation == "teardown" then cleanupCalls += 1 end
				return violate()
			end
		end
		local function construct()
			if operation == "construct" then
				if violation == "yields" then violate() end
				return rawSide, nil
			end
			return rawSide
		end
		local owner = PersistentTransport.new({ constructClient = construct }, {})
		local expected = if operation == "teardown" then "PERSISTENT_TRANSPORT_E_CLEANUP" else "PERSISTENT_TRANSPORT_E_ADAPTER"
		rejects(function()
			local side = owner.factory.constructClient({ selection = {}, participantIndex = 1, sink = function() end })
			side.setup()
			assert(side.ready())
			side.submit({}, "ContinueFrame")
			side.teardown()
			owner.close()
		end, expected)
		rejects(owner.close, expected)
		rejects(owner.close, expected)
		assert(not resumed)
		assert(cleanupCalls == (if operation == "construct" and violation == "yields" then 0 else 1))
	end
end

do
	local rawSide = { setup = function() end, ready = function() return "true" end, teardown = function() end }
	local owner = PersistentTransport.new({ constructClient = function() return rawSide end }, {})
	local side = owner.factory.constructClient({ selection = {}, participantIndex = 1, sink = function() end })
	side.setup()
	rejects(side.ready, "PERSISTENT_TRANSPORT_E_ADAPTER")
	rejects(owner.close, "PERSISTENT_TRANSPORT_E_ADAPTER")
end

print("persistent transport passed: 30 windows per role; sticky delivery/identity/cleanup failures; non-yielding exact-return boundaries")
