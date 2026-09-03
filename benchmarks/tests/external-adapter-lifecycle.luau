--!strict

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local AdapterContract = require("../adapters/AdapterContract")
local Comparator = require("../correctness/PayloadComparator")

local player, impostor = {}, {}
local Common = luau.load(fs.readFile("benchmarks/adapters/ExternalAdapter.luau"), {
	environment = { game = { GetService = function(_, name)
		assert(name == "Players")
		return { GetPlayers = function() return { player } end }
	end } }, injectGlobals = true,
})()

local function rig(options: any?): any
	options = options or {}
	local observed = { calls = {}, reads = 0, disconnects = 0, sends = 0, flushes = 0 }
	local callbacks: any = {}
	local ready = false
	local factory = Common.new({ setup = function(session, _root, _selection, _server, _receives, record, positional)
		callbacks.record, callbacks.positional = record, positional
		session.disconnect = function()
			observed.disconnects += 1
			-- A library is allowed to dispatch an already-scheduled callback here.
			record(player, options.hostile)
			positional(player, options.hostile)
			if options.disconnectFailure then error("library disconnect failed") end
		end
		session.ready = function() return ready end
		session.send = function(payload) observed.sends += 1; observed.lastInput = payload end
		session.flush = function() observed.flushes += 1 end
		if options.setupFailure then error("library setup failed") end
	end })
	local context = {
		resourceRoot = {}, recipients = { player },
		selection = { kind = "SeparateProbe", payloadId = "tiny" },
		envelopes = {
			record = function(value)
				observed.reads += 1
				return AdapterContract.recordDelivery(value)
			end,
			positional = function(...)
				observed.reads += 1
				return { kind = "Positional", values = table.pack(...), count = select("#", ...) }
			end,
		},
		sink = function(envelope, metadata) table.insert(observed.calls, { envelope, metadata }) end,
	}
	local side = factory.constructServer(context)
	return { side = side, callbacks = callbacks, observed = observed, makeReady = function() ready = true end }
end

local hostile = setmetatable({}, { __index = function() error("payload inspected") end,
	__iter = function() error("payload traversed") end })
local test = rig({ hostile = hostile })
test.side.setup()
test.callbacks.record(player, hostile)
test.callbacks.positional(player, hostile, nil, false)
assert(test.observed.reads == 0 and #test.observed.calls == 0, "pre-ready callback escaped")
assert(test.side.ready() == false)
test.callbacks.record(player, hostile)
assert(test.observed.reads == 0, "false readiness admitted payload")
test.makeReady()
assert(test.side.ready())

local expected = { sequence = 0, enabled = false }
test.callbacks.record(player, expected)
local delivered = test.observed.calls[1]
assert(delivered[1].value == expected, "record was copied/projected")
assert(delivered[2].sender == player and delivered[2].kind == "ClientToServer")
assert(Comparator.compareRecord("tiny", expected, delivered[1].value))
for _, malformed in { {}, { sequence = 0 }, { sequence = 0, enabled = false, extra = true },
	{ sequence = 0, enabled = 1 } } do
	test.callbacks.record(impostor, malformed)
	local call = test.observed.calls[#test.observed.calls]
	assert(call[1].value == malformed and call[2].sender == impostor, "adapter hid malformed data/sender")
	assert(not Comparator.compareRecord("tiny", expected, call[1].value), "malformed record passed")
end
test.callbacks.positional(player, 0, false, nil)
local last = test.observed.calls[#test.observed.calls][1]
assert(last.count == 3 and last.values[1] == 0 and last.values[2] == false, "positional arity changed")

test.side.broadcast(expected, "ContinueFrame")
assert(test.observed.sends == 1 and test.observed.flushes == 0)
test.side.broadcast(expected, "FlushBeforeReturn")
assert(test.observed.sends == 2 and test.observed.flushes == 1)
assert(test.observed.lastInput == expected and Comparator.compareRecord("tiny", expected, expected))
local beforeReads, beforeCalls = test.observed.reads, #test.observed.calls
test.side.teardown()
test.side.teardown()
test.callbacks.record(player, hostile)
test.callbacks.positional(player, hostile, nil, false)
assert(test.observed.reads == beforeReads and #test.observed.calls == beforeCalls, "stale callback escaped")
assert(test.observed.disconnects == 1, "teardown was not idempotent")
assert(not pcall(test.side.broadcast, expected, "FlushBeforeReturn"), "send after teardown")

for _, options in { { setupFailure = true, hostile = hostile }, { disconnectFailure = true, hostile = hostile } } do
	local failed = rig(options)
	local setupOK = pcall(failed.side.setup)
	assert(setupOK == not options.setupFailure)
	if setupOK then failed.makeReady(); assert(failed.side.ready()) end
	local teardownOK = pcall(failed.side.teardown)
	assert(teardownOK == not options.disconnectFailure)
	failed.side.teardown()
	failed.callbacks.record(player, hostile)
	assert(#failed.observed.calls == 0 and failed.observed.disconnects == 1, "failed cleanup leaked callback")
end

-- Invalid CLI requests must fail even when optional vendor files are absent.
for _, arguments in { {}, { "--bogus" } } do
	local command = { "run", "scripts/generate-benchmark-adapters.luau" }
	for _, argument in arguments do table.insert(command, argument) end
	assert(not process.exec("lune", command).ok, "generator CLI silently accepted invalid arguments")
end

print("PASS external adapter callback admission, raw delivery, flush, and partial cleanup")
