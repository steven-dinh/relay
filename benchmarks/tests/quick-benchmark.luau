local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Model = require("../quick/Model")
local Config = table.clone(require("../quick/Config"))
local SchemaFixtures = require("../quick/SchemaFixtures")
local roblox = require("@lune/roblox")
local DisabledCallbackTiming = {
	enabled = false,
	begin = function() end,
	wrap = function(_, callback) return callback end,
	finish = function() return {} end,
}
-- Exercise fixed test sizes independently of the developer's iteration settings.
Config.warmupFrames, Config.measuredFrames = 30, 120
Config.caseId = "state-burst-c2s"

local selected = Model.selection(Config)
local first, second = Model.batches(Config, selected, 1), Model.batches(Config, selected, 2)
assert(#first[1] == 120 and #first[2] == 480)
assert(first[2][1].expected.sequence > first[1][#first[1]].expected.sequence)
assert(second[1][1].expected.sequence > first[2][#first[2]].expected.sequence)
assert(first[1][1].input ~= first[1][1].expected)

local burstConfig = table.clone(Config)
burstConfig.caseId = "state-broadcast-burst-s2c"
local burstSelection = Model.selection(burstConfig)
assert(burstSelection.payloadId == "state" and burstSelection.direction == "ServerToClient"
	and burstSelection.messagesPerFrame == 4, "quick burst must be a private four-message State S2C workload")
local burstBatches = Model.batches(burstConfig, burstSelection, 1)
assert(#burstBatches[1] == 120 and #burstBatches[2] == 480)

for _, caseId in { "tiny-steady-c2s", "state-steady-c2s", "state-burst-c2s", "state-broadcast-s2c", "tiny-round-trip",
	"schema-signed-c2s", "schema-vector2-c2s", "schema-string-c2s", "schema-cframe-c2s" } do
	local config = table.clone(Config)
	config.caseId = caseId
	local selection = Model.selection(config)
	for _, batch in Model.batches(config, selection, 1) do
		local capture = Model.capture(selection.payloadId, batch)
		assert(not pcall(capture.verify), "missing deliveries must fail")
		for index, fixture in batch do
			assert(capture.push({ kind = "Record", value = fixture.input }, index))
		end
		capture.verify()
		Model.verifyInputs(selection.payloadId, batch)
		assert(not capture.push({ kind = "Record", value = batch[1].input }, 0), "extra delivery must fail")
		assert(not pcall(capture.verify), "extra delivery must latch")
	end
end

-- Schema fixtures remain deterministic, native, bounded and independent across reruns.
for payloadId, fields in SchemaFixtures.fields do
	local config = table.clone(Config)
	config.caseId = payloadId .. "-c2s"
	local selection = Model.selection(config)
	assert(selection.schema and selection.fieldCount == #fields and selection.messagesPerFrame == 1
		and selection.direction == "ClientToServer")
	local previous = -1
	for run = 1, 2 do
		for _, phases in Model.runBatches(config, selection, run, 1) do
			for _, batch in phases do
				assert(batch[1].expected.sequence > previous, "schema run/round sequences disjoint")
				previous = batch[#batch].expected.sequence
				for _, fixture in batch do
					assert(SchemaFixtures.compare(payloadId, fixture.expected,
						SchemaFixtures.generate(payloadId, fixture.expected.sequence), true), "schema deterministic generation")
				end
			end
		end
	end
	local batch = Model.batches(config, selection, 1)[1]
	local positional = Model.capture(payloadId, batch)
	for index, fixture in batch do
		local values = {}
		for position, field in fields do values[position] = fixture.input[field.name] end
		assert(positional.push({ kind = "Positional", values = values, count = #fields }, index))
	end
	positional.verify()
	local wrongType = table.clone(batch[1].input)
	wrongType[fields[2].name] = {}
	local malformed = Model.capture(payloadId, batch)
	assert(not malformed.push({ kind = "Record", value = wrongType }, 0) and malformed.count() == 0)
	local arity = Model.capture(payloadId, batch)
	assert(not arity.push({ kind = "Positional", values = {}, count = #fields + 1 }, 0))
	local duplicate = Model.capture(payloadId, { batch[1], batch[2] })
	assert(duplicate.push({ kind = "Record", value = batch[1].input }, 0))
	assert(duplicate.push({ kind = "Record", value = batch[1].input }, 1))
	assert(not pcall(duplicate.verify), "schema duplicate/stale sequence")
end
local stringBatch = { { expected = SchemaFixtures.generate("schema-string", 0) } }
assert(#stringBatch[1].expected.text == 64 and stringBatch[1].expected.text ~= SchemaFixtures.generate("schema-string", 1).text)
local overlong = Model.capture("schema-string", stringBatch)
assert(not overlong.push({ kind = "Record", value = { sequence = 0, text = string.rep("x", 65) } }, 0)
	and overlong.count() == 0, "overlong string rejected before retention")
local poseExpected = SchemaFixtures.generate("schema-cframe", 17)
local changedComponents = { poseExpected.pose:GetComponents() }
changedComponents[4] += 0.000001
local changed = { sequence = 17, pose = roblox.CFrame.new(table.unpack(changedComponents)) }
assert(SchemaFixtures.compare("schema-cframe", poseExpected, changed, false), "tiny rotation change remains inside native comparator")
assert(not pcall(Model.verifyInputs, "schema-cframe", { { expected = poseExpected, input = changed } }),
	"local CFrame mutation must fail even within receive tolerance")
for _, index in { 1, 4, 8, 12 } do
	for _, nonfinite in { 0 / 0, math.huge, -math.huge } do
		local components = { poseExpected.pose:GetComponents() }
		components[index] = nonfinite
		local invalid = { sequence = 17, pose = roblox.CFrame.new(table.unpack(components)) }
		assert(not SchemaFixtures.compare("schema-cframe", poseExpected, invalid, false), "nonfinite remote CFrame component")
	end
end
local zeroExpected = { sequence = 0, pose = roblox.CFrame.new(-1 / math.huge, 0, 0) }
local zeroChanged = { sequence = 0, pose = roblox.CFrame.new(0, 0, 0) }
assert(not SchemaFixtures.compare("schema-cframe", zeroExpected, zeroChanged, true), "local CFrame zero signs preserved")

-- Exercise the private adapter through a small public-Relay fake; no transport harness.
local Definition = require("../../src/Definition")
local CompositeCodec = require("../../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		Vector2 = roblox.Vector2, Vector3 = roblox.Vector3,
		require = function(path)
			assert(path == "./CompositeCodec")
			return CompositeCodec
		end,
	}, injectGlobals = true,
})()
for payloadId in SchemaFixtures.fields do
	local config = table.clone(Config)
	config.caseId = payloadId .. "-c2s"
	local selection = Model.selection(config)
	local currentRoot, receiver, received, starts, destroys = nil, nil, {}, 0, 0
	local player = {}
	local relay = { define = Definition.define }
	local function makeSession(definition, server)
		local validate = Frame.compile(Definition.get(definition).events.Submit)
		local event = {}
		function event:Connect(callback) assert(server) receiver = callback return {} end
		function event:Send(...)
			local result = table.pack(validate(...))
			if not result[1] then return false end
			receiver(player, table.unpack(result, 2, result.n))
			return true
		end
		return { events = { Submit = event }, Start = function()
			if server then assert(receiver ~= nil, "schema receive binding precedes server startup") end
			starts += 1 return true
		end, Destroy = function() destroys += 1 end }
	end
	function relay.createServer(definition, options)
		assert(options.inboundRate.perPlayer.capacity == 4096 and options.inboundRate.perPlayer.refillPerSecond == 2048
			and options.inboundRate.aggregate.capacity == 32768 and options.inboundRate.aggregate.refillPerSecond == 16384)
		return makeSession(definition, true)
	end
	function relay.createClient(definition, options)
		assert(options.startupTimeoutSeconds == 1)
		return makeSession(definition, false)
	end
	local storage = { Relay = relay, FindFirstChild = function() return currentRoot end }
	local factory = luau.load(fs.readFile("benchmarks/quick/SchemaRelay.luau"), { environment = {
		game = { GetService = function() return storage end }, script = { Parent = { SchemaFixtures = SchemaFixtures } },
		require = function(value) return value end,
	} })()
	local context = { selection = selection, resourceRoot = {}, envelopes = { positional = function(...)
		return { kind = "Positional", values = { ... }, count = select("#", ...) }
	end }, sink = function(envelope, metadata)
		assert(metadata.sender == player and metadata.kind == "ClientToServer")
		table.insert(received, envelope)
	end }
	local serverSide, clientSide = factory.constructServer(context), factory.constructClient(context)
	assert(not pcall(clientSide.ready))
	serverSide.setup() assert(serverSide.ready()) clientSide.setup()
	local fixture = SchemaFixtures.generate(payloadId, 19)
	assert(not pcall(clientSide.submit, fixture, "FlushBeforeReturn"))
	assert(not clientSide.ready(), "schema waits for production root")
	currentRoot = { FindFirstChild = function() return nil end }
	assert(not clientSide.ready(), "schema waits for both production leaves")
	currentRoot = { FindFirstChild = function() return {} end }
	assert(clientSide.ready() and starts == 2)
	clientSide.submit(fixture, "FlushBeforeReturn")
	local capture = Model.capture(payloadId, { { expected = fixture } })
	assert(capture.push(received[1], 0)) capture.verify()
	clientSide.teardown() clientSide.teardown()
	assert(not pcall(clientSide.submit, fixture, "FlushBeforeReturn"))
	local replacement = factory.constructClient(context)
	replacement.setup()
	assert(not replacement.ready(), "schema must not rebind preceding global transport")
	currentRoot = { FindFirstChild = function() return {} end }
	assert(replacement.ready()) replacement.teardown()
	serverSide.teardown() serverSide.teardown()
	assert(destroys == 3, "one teardown per schema session")
	local before = #received
	receiver(player, 0, nil)
	assert(#received == before + 1, "queued late schema callbacks reach Session failure accounting")
end

-- Closed schema combinations must reject before factory, control, or listeners.
for _, invalid in { { adapters = "native-reliable" }, { adapters = "relay-reliable,native-reliable" },
	{ adapters = "relay-reliable,relay-reliable" }, { adapters = "relay-reliable", profile = true } } do
	local config = table.clone(Config)
	config.caseId = "schema-signed-c2s"
	local resources = 0
	local function touched() resources += 1 error("resource touched") end
	local benchmark = { QuickAdapters = { Value = invalid.adapters }, Runner = { ExternalReadiness = {} },
		GetAttributeChangedSignal = touched, FindFirstChild = function() return nil end,
		GetAttribute = function() return nil end, SetAttribute = function() end }
	local services = { Players = {}, ReplicatedStorage = {}, Stats = {}, RunService = { IsServer = function() return false end, IsStudio = function() return true end } }
	local callbackTiming = { enabled = invalid.profile == true, setFailureHandler = function() end }
	local ok, reason = pcall(function()
		local loaded = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
			game = { GetService = function(_, name) return services[name] end },
			script = { Parent = { Parent = benchmark, Config = config, Model = Model, CallbackTiming = callbackTiming, SchemaRelay = touched } },
			require = function(value) if value == touched then return touched() end return value end,
			Instance = { new = touched }, warn = function() end,
		} })()
		loaded.run()
	end)
	assert(not ok and resources == 0 and string.find(tostring(reason), "schema diagnostics", 1, true), "unsupported schema selection rejects before resources")
end
for _, invalid in { { caseId = "tiny-round-trip", adapters = "native-reliable" },
	{ caseId = "tiny-steady-c2s", adapters = "external-library" } } do
	local config = table.clone(Config)
	config.caseId = invalid.caseId
	local resources = 0
	local function touched() resources += 1 error("resource touched") end
	local benchmark = { QuickAdapters = { Value = invalid.adapters }, Runner = { ExternalReadiness = {} },
		GetAttributeChangedSignal = touched, FindFirstChild = function() return nil end,
		GetAttribute = function() return nil end, SetAttribute = function() end }
	local callbackTiming = { enabled = true, setFailureHandler = function() end }
	local services = { Players = {}, ReplicatedStorage = {}, Stats = {},
		RunService = { IsServer = function() return false end, IsStudio = function() return true end } }
	local ok = pcall(function()
		local loaded = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
			game = { GetService = function(_, name) return services[name] end },
			script = { Parent = { Parent = benchmark, Config = config, Model = Model, CallbackTiming = callbackTiming } },
			require = function(value) return value end, warn = function() end,
		} })()
		loaded.run()
	end)
	assert(not ok and resources == 0, "RTT/external profiling must reject before resources")
end

local tinyConfig = table.clone(Config)
tinyConfig.caseId = "tiny-steady-c2s"
local tiny = Model.batches(tinyConfig, Model.selection(tinyConfig), 1)[1]
local capture = Model.capture("tiny", tiny)
for index, fixture in tiny do
	assert(capture.push({ kind = "Positional", values = { fixture.input.sequence, fixture.input.enabled }, count = 2 }, index))
end
capture.verify()

for _, envelope in {
	{ kind = "Record", value = { sequence = 0, enabled = true, extra = true } },
	{ kind = "Record", value = { sequence = {}, enabled = true } },
	{ kind = "Record", value = { sequence = buffer.create(100), enabled = true } },
	{ kind = "Record", value = { sequence = 0 } },
	{ kind = "Positional", values = { 0, true, 123 }, count = 3 },
	{ kind = "Positional", values = { 0, true }, count = 1000000 },
} do
	local rejected = Model.capture("tiny", tiny)
	assert(not rejected.push(envelope, 0))
	assert(rejected.count() == 0, "malformed data must not be retained")
	assert(not pcall(rejected.check))
end

local swapped = Model.capture("tiny", { tiny[1], tiny[2] })
assert(swapped.push({ kind = "Record", value = tiny[2].input }, 0))
assert(swapped.push({ kind = "Record", value = tiny[1].input }, 1))
assert(not pcall(swapped.verify), "order/content comparison belongs outside capture")
tiny[1].input.enabled = not tiny[1].input.enabled
assert(not pcall(Model.verifyInputs, "tiny", tiny), "mutated inputs must fail")

for key, value in { caseId = "unknown", warmupFrames = 0, measuredFrames = 601,
	quietSeconds = 0 / 0, timeoutSeconds = math.huge, autoRun = "yes" } do
	local invalid = table.clone(Config)
	invalid[key] = value
	assert(not pcall(Model.selection, invalid), "invalid quick configuration: " .. key)
end
local stats = Model.summary({ 4, 1, 3, 2 })
assert(stats.mean == 2.5 and stats.p95 == 4 and stats.median == 2.5 and stats.min == 1 and stats.max == 4)
assert(Model.summary({ 1, 100, 3 }).median == 3)
for _, count in { 1, 2, 3, 4, 5, 6, 7, 8, 9 } do
	local rounds = count * math.ceil(3 / count)
	assert(Model.roundCount(count) == rounds and rounds % count == 0, "round count must balance adapter positions")
	local previousRunFirst
	for run = 1, 2 do
		local positionCounts = table.create(count)
		for adapter = 1, count do positionCounts[adapter] = table.create(count, 0) end
		for round = 1, rounds do
			local seen = {}
			for position = 1, count do
				local index = Model.adapterIndex(count, run, round, position)
				assert(index >= 1 and index <= count and not seen[index], "rotation must visit every adapter once")
				seen[index] = true
				positionCounts[index][position] += 1
			end
		end
		for adapter = 1, count do
			for position = 1, count do
				assert(positionCounts[adapter][position] == rounds / count,
					"every adapter must occupy every ordinal position equally")
			end
		end
		local firstAdapter = Model.adapterIndex(count, run, 1, 1)
		if previousRunFirst then
			assert(firstAdapter == previousRunFirst % count + 1, "each rerun rotates the first adapter by one")
		end
		previousRunFirst = firstAdapter
	end
	for _, invalidCount in { 0, 1.5, 10 } do
		assert(not pcall(Model.roundCount, invalidCount), "adapter count must be an integer from one through nine")
	end
	local scheduleConfig = table.clone(Config)
	scheduleConfig.warmupFrames, scheduleConfig.measuredFrames = 1, 1
	local scheduleSelection = Model.selection(scheduleConfig)
	local lastSequence = -1
	for run = 1, 2 do
		local batches = Model.runBatches(scheduleConfig, scheduleSelection, run, count)
		assert(#batches == rounds, "all scheduled rounds must be present")
		local sequences, total = {}, 0
		for _, phases in batches do
			for _, batch in phases do
				for _, fixture in batch do
					local sequence = fixture.expected.sequence
					assert(sequence > lastSequence and not sequences[sequence], "rerun/round fixtures must be disjoint")
					sequences[sequence] = true
					lastSequence = sequence
					total += 1
				end
			end
		end
		assert(total == rounds * scheduleSelection.messagesPerFrame * 2, "round fixture totals must match both phases")
	end
end
local lastSequence = -1
for run = 1, 2 do
	for _, phases in Model.runBatches(Config, selected, run, 2) do
		assert(phases[1][1].expected.sequence > lastSequence, "round/run fixtures must not overlap")
		lastSequence = phases[2][#phases[2]].expected.sequence
	end
end
assert(not pcall(Model.runBatches, Config, selected,
	math.floor(math.floor(0xFFFFFFFF / 600) / Model.roundCount(2)) + 1, 2),
	"all balanced rounds must fit within u32 sequences")
local aggregate = Model.aggregate({
	{ sent = 10, elapsed = 1, calls = { mean = 1, median = 2, p95 = 3 }, floor = { mean = 0.1 },
		rtt = { mean = 2, p95 = 20 }, acknowledgementTail = 0.1,
		receiveCallbacks = { mean = 0.01, median = 0.02, p95 = 0.03 } },
	{ sent = 10, elapsed = 2, calls = { mean = 3, median = 4, p95 = 5 }, floor = { mean = 0.2 },
		rtt = { mean = 4, p95 = 40 }, acknowledgementTail = 0.2,
		receiveCallbacks = { mean = 0.04, median = 0.05, p95 = 0.06 } },
	{ sent = 10, elapsed = 4, calls = { mean = 100, median = 101, p95 = 102 }, floor = { mean = 0.3 },
		rtt = { mean = 6, p95 = 60 }, acknowledgementTail = 0.3,
		receiveCallbacks = { mean = 0.07, median = 0.08, p95 = 0.09 } },
})
assert(aggregate.calls.median == 3 and aggregate.calls.min == 1 and aggregate.calls.max == 100)
assert(aggregate.callMean.mean == aggregate.calls.mean and aggregate.callMean.median == aggregate.calls.median
	and aggregate.callMean.p95 == aggregate.calls.p95 and aggregate.callMean.min == aggregate.calls.min
	and aggregate.callMean.max == aggregate.calls.max and aggregate.callMean ~= aggregate.calls,
	"callMean must preserve values in an independent compatibility summary")
aggregate.callMean.mean = -1
assert(aggregate.calls.mean == 104 / 3, "mutating callMean must not change calls")
assert(aggregate.callMedian.median == 4 and aggregate.callP95.median == 5
	and aggregate.acknowledgementTail.median == 0.2,
	"aggregate must preserve public-call median/p95 and acknowledgement tail separately")
assert(aggregate.receiveCallbacks.mean == aggregate.receiveCallbackMean.mean
	and aggregate.receiveCallbacks.median == aggregate.receiveCallbackMean.median
	and aggregate.receiveCallbacks.p95 == aggregate.receiveCallbackMean.p95
	and aggregate.receiveCallbacks.min == aggregate.receiveCallbackMean.min
	and aggregate.receiveCallbacks.max == aggregate.receiveCallbackMean.max
	and aggregate.receiveCallbacks ~= aggregate.receiveCallbackMean,
	"receiveCallbackMean must preserve values in an independent compatibility summary")
aggregate.receiveCallbackMean.mean = -1
assert(aggregate.receiveCallbacks.mean == 0.04, "mutating receiveCallbackMean must not change receiveCallbacks")
assert(aggregate.offeredRate.median == 5 and aggregate.rttP95.median == 40,
	"aggregate round metrics, not pooled samples or a ratio of averages")
local unprofiledAggregate = Model.aggregate({
	{ sent = 1, elapsed = 1, calls = { mean = 1 }, floor = { mean = 0.1 } },
})
assert(unprofiledAggregate.receiveCallbacks == nil and unprofiledAggregate.receiveCallbackMean == nil
	and unprofiledAggregate.receiveCallbackMedian == nil and unprofiledAggregate.receiveCallbackP95 == nil,
	"optional receive callback metrics must stay absent when unprofiled")

-- Drive the real probe loop with a deterministic clock and delayed echoes.
local function probePhase(delays, waitStep)
	local config = table.clone(Config)
	config.caseId, config.warmupFrames, config.measuredFrames = "tiny-round-trip", 1, #delays
	config.timeoutSeconds = 5
	local now, received, due, sent = 0, 0, nil, 0
	local times = {}
	local benchmark = { QuickAdapters = { Value = "native-reliable" },
		Runner = { ExternalReadiness = {} }, GetAttribute = function() end }
	local services = {
		RunService = { IsServer = function() return false end,
			PostSimulation = { Wait = function()
				now += if due == nil then 0.25 else (waitStep or 0.25)
				if due and now >= due then
					received += 1
					times[received], due = due, nil
				end
			end } },
		Players = {}, ReplicatedStorage = {}, Stats = {},
	}
	local source, replacements = string.gsub(fs.readFile("benchmarks/quick/Session.luau"),
		"return table.freeze%({ serve = serve, run = run }%)", "return { pace = pace }")
	assert(replacements == 1)
	local session = luau.load(source, { environment = {
		game = { GetService = function(_, name) return services[name] end },
		script = { Parent = { Parent = benchmark, Config = config, Model = Model,
			CallbackTiming = DisabledCallbackTiming } },
		require = function(value) return value end, os = { clock = function() return now end },
	} })()
	local ok, result = pcall(session.pace, {
		side = { submit = function()
			sent += 1
			due = now + delays[sent]
			now += 0.000010
		end },
		capture = { count = function() return received end, time = function(index) return times[index] end },
	}, Model.batches(config, Model.selection(config), 1)[2])
	return ok, result, now
end
local timely, probe = probePhase({ 2, 2 })
assert(timely and probe.sent == 2 and #probe.rtt == 2)
for index, rtt in probe.rtt do
	assert(math.abs(rtt - 2) < 1e-9 and math.abs(probe.calls[index] - 0.000010) < 1e-9,
		"deadline checks must preserve receive-timestamp RTT and public-call timing")
end
local overdue, overdueReason, stoppedAt = probePhase({ 4, 4 })
assert(not overdue and string.find(tostring(overdueReason), "timed out", 1, true) and stoppedAt < 5.3,
	"echoes must share the five-second phase budget, including the final echo")
local late, lateReason = probePhase({ 6 }, 6)
assert(not late and string.find(tostring(lateReason), "timed out", 1, true),
	"a final echo received after the deadline cannot pass when polling resumes")

-- The private S2C burst must send four messages in one frame, with only the
-- fourth call carrying the existing flush boundary. Frame timing remains the
-- actual frame interval; public-call samples divide batch duration by four.
local function burstPhase()
	local config = table.clone(Config)
	config.caseId, config.warmupFrames, config.measuredFrames = "state-broadcast-burst-s2c", 1, 2
	local now, calls = 0, {}
	local benchmark = { QuickAdapters = { Value = "native-reliable" },
		Runner = { ExternalReadiness = {} }, GetAttribute = function() end }
	local services = {
		RunService = { IsServer = function() return true end,
			PostSimulation = { Wait = function() now += 0.05 end } },
		Players = {}, ReplicatedStorage = {}, Stats = { DataSendKbps = 12.5 },
	}
	local source, replacements = string.gsub(fs.readFile("benchmarks/quick/Session.luau"),
		"return table.freeze%({ serve = serve, run = run }%)", "return { pace = pace }")
	assert(replacements == 1)
	local session = luau.load(source, { environment = {
		game = { GetService = function(_, name) return services[name] end },
		script = { Parent = { Parent = benchmark, Config = config, Model = Model,
			CallbackTiming = DisabledCallbackTiming } },
		require = function(value) return value end, os = { clock = function() now += 0.000001; return now end },
	} })()
	local batch = Model.batches(config, Model.selection(config), 1)[2]
	local ok, result = pcall(session.pace, {
		side = { broadcast = function(payload, boundary)
			table.insert(calls, { sequence = payload.sequence, boundary = boundary })
			now += 0.000010
		end },
	}, batch)
	assert(ok and result.sent == 8 and #result.frames == 2 and #calls == 8)
	for index, call in calls do
		assert(call.sequence == batch[index].input.sequence,
			"burst messages must retain deterministic fixture order")
		assert(call.boundary == (if index % 4 == 0 then "FlushBeforeReturn" else "ContinueFrame"),
			"burst flush must remain on the final message of each frame")
	end
	assert(math.abs(result.frames[1] - 0.050041) < 0.00001,
		"burst frame timing must preserve the actual frame interval")
end
burstPhase()

-- Exercise the actual client runner with a local control/clock port, then inject
-- failures after it has returned. No subsequent run/check may be needed to
-- invalidate those rows or notify the other side.
local function quickClient(drainDelay, caseId, profileMode)
	local now, runIndex, aborts, teardowns, submissions = 0, 0, 0, 0, 0
	local stage, phaseNumber, phaseSent, expectedBatches, expectedOrder = "Start", 0, 0, nil, nil
	local warnings, output, attributes, observers = {}, {}, {}, {}
	local profileBegins, profileFinishes = 0, 0
	local config = table.clone(Config)
	config.caseId, config.warmupFrames, config.measuredFrames = caseId or "tiny-steady-c2s", 1, 2
	local adapterCount = if Model.selection(config).schema then 1 else 2
	local callbackTiming = {
		enabled = profileMode ~= nil,
		begin = function() profileBegins += 1 end,
		finish = function() profileFinishes += 1; return {} end,
		wrap = function(_, callback) return callback end,
		setFailureHandler = function() end,
	}
	local context
	local factory = {
		constructClient = function(value)
			context = value
			return {
				setup = function() end, ready = function() return true end,
				submit = function(payload, boundary)
					assert(stage == "Drain" and value.resourceRoot.id == expectedOrder[math.ceil(phaseNumber / 2)],
						"client must follow rotated order in both runs")
					phaseSent += 1
					local round = math.floor((phaseNumber - 1) / (adapterCount * 2)) + 1
					local phase = (phaseNumber - 1) % 2 + 1
					local batch = expectedBatches[round][phase]
					assert(payload.sequence == batch[phaseSent].input.sequence and boundary == "FlushBeforeReturn")
					submissions += 1
					now += 0.000010
				end,
				teardown = function() teardowns += 1 end,
			}
		end,
	}
	local transports = { ["native-reliable"] = { id = "native-reliable" }, ["relay-reliable"] = { id = "relay-reliable" } }
	function transports:FindFirstChild(id) return self[id] end
	local benchmark = {
		QuickAdapters = { Value = if adapterCount == 1 then "relay-reliable" else "native-reliable,relay-reliable" }, QuickTransports = transports,
		adapters = { NativeReliable = factory, RelayReliable = factory }, Runner = { ExternalReadiness = {} },
	}
	function benchmark:GetAttribute(key) return attributes[key] end
	function benchmark:SetAttribute(key, value)
		attributes[key] = value
		if observers[key] then observers[key]() end
	end
	function benchmark:GetAttributeChangedSignal(key)
		return { Connect = function(_, callback) observers[key] = callback; return {} end }
	end
	function benchmark:FindFirstChild(key) return self[key] end
	benchmark.QuickControl = { InvokeServer = function(_, command)
		if command == "Abort" then
			aborts += 1
			benchmark:SetAttribute("QuickFailure", "quick benchmark aborted")
			return false
		end
		assert(command == stage, "client command order")
		if command == "Start" then
			runIndex += 1
			local a, b = "native-reliable", "relay-reliable"
			expectedBatches = Model.runBatches(config, Model.selection(config), runIndex, adapterCount)
			expectedOrder = {}
			for round = 1, #expectedBatches do
				for position = 1, adapterCount do
					local index = Model.adapterIndex(adapterCount, runIndex, round, position)
					table.insert(expectedOrder, if adapterCount == 1 then b else if index == 1 then a else b)
				end
			end
			phaseNumber, stage = 0, "Begin"
			return runIndex
		elseif command == "Begin" then
			phaseNumber += 1
			phaseSent, stage = 0, "Drain"
		elseif command == "Drain" then
			assert(phaseSent == (if phaseNumber % 2 == 1 then 1 else 2), "no-op calibration must not send")
			now += drainDelay
			stage = "Finish"
		elseif command == "Finish" then
			-- Deliberately expensive quiet/verification work must not enter timing.
			now += 7
			stage = if phaseNumber == Model.roundCount(adapterCount) * adapterCount * 2 then "Complete" else "Begin"
			if profileMode ~= nil then
				local round = math.floor((phaseNumber - 1) / (adapterCount * 2)) + 1
				local phase = (phaseNumber - 1) % 2 + 1
				local samples = table.create(#expectedBatches[round][phase], 0.000006)
				if phase == 1 then
					if profileMode == "not-table" then return true end
					if profileMode == "short" then samples[#samples] = nil end
					if profileMode == "extra" then samples[#samples + 1] = 0.000006 end
					if profileMode == "keyed" then samples.extra = 0.000006 end
					if profileMode == "nonfinite" then samples[1] = math.huge end
				end
				return { receiveCallbackSamples = samples }
			end
		elseif command == "Complete" then
			stage = "Start"
		end
		return true
	end }
	local quick = { Parent = benchmark, Config = config, Model = Model, SchemaRelay = factory,
		CallbackTiming = callbackTiming }
	local services = {
		RunService = { IsServer = function() return false end, IsStudio = function() return true end,
			PostSimulation = { Wait = function() now += 0.05 end } },
		Players = {}, ReplicatedStorage = {}, Stats = { DataSendKbps = 12.5 },
	}
	local session = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
		game = { GetService = function(_, name) return services[name] end }, script = { Parent = quick },
		require = function(value) return value end,
		os = { clock = function() now += 0.000001; return now end },
		task = { spawn = function(callback) callback(); return coroutine.create(function() end) end },
		warn = function(message) table.insert(warnings, message) end,
		print = function(message) table.insert(output, message) end,
	} })()
	local ok, firstRun = pcall(session.run)
	if profileMode ~= nil and profileMode ~= "valid" then
		assert(not ok and attributes.QuickStatus == "Failed" and aborts == 1 and teardowns == adapterCount,
			"malformed server profile must invalidate the client run")
		assert(profileBegins == 0 and profileFinishes == 0,
			"C2S sender must not open a local receive profile phase")
		return
	end
	assert(ok, firstRun)
	local secondRun = session.run()
	assert(firstRun[1].validity.valid and secondRun[1].validity.valid)
	assert(profileBegins == 0 and profileFinishes == 0,
		"C2S sender must not open a local receive profile phase")
	assert(submissions == 2 * Model.roundCount(adapterCount) * adapterCount
		* (config.warmupFrames + config.measuredFrames), "only warmup and measured calls may reach the adapter")
	for _, rows in { firstRun, secondRun } do
		for _, row in rows do
			assert(#row.rounds == Model.roundCount(adapterCount)
				and row.sent == Model.roundCount(adapterCount) * config.measuredFrames
				and row.summary.kbps.median == 12.5)
			for _, round in row.rounds do
				if profileMode == nil then
					assert(round.receiveCallbacks == nil and round.receiveCallbackSamples == nil,
						"unprofiled runs must not report receive samples")
				else
					assert(#round.receiveCallbackSamples == config.measuredFrames
						and round.receiveCallbacks.median == 0.000006,
						"C2S profile samples must accompany unchanged sender measurements")
				end
				for sampleKey, summaryKey in { callSamples = "calls", frameSamples = "frames", floorSamples = "floor" } do
					assert(#round[sampleKey] == config.measuredFrames, "retained schema/legacy raw sample count")
					local recomputed = Model.summary(round[sampleKey])
					for key, value in recomputed do assert(round[summaryKey][key] == value, "sample-derived summary") end
				end
				assert(math.abs(round.calls.mean - 0.000011) < 1e-9 and math.abs(round.floor.mean - 0.000001) < 1e-9,
					"call time must remain raw, with an independent unsubtracted floor")
				assert(math.abs(round.deliveryConfirmation - round.elapsed - drainDelay) < 0.0001,
					"confirmation includes delivery delay, excluding quiet and validation")
				assert(math.abs(round.acknowledgementTail - drainDelay - 0.05) < 0.0001,
					"acknowledgement tail starts at the final submission return and includes final frame wait")
			end
		end
	end
	local printed = table.concat(output, "\n")
	for _, label in { "engine send 12.50 [12.50..12.50] KB/s", "offered ", "public call mean ",
		"public call median ", "public call p95 ", "no-op floor ", "delivery confirmation ",
		"acknowledgement tail ", "median [min..max]",
		if profileMode == nil then "profile=unprofiled" else "profile=receive-callback" } do
		assert(string.find(printed, label, 1, true), "output label/value: " .. label)
	end
	return {
		rows = firstRun,
		close = function()
			benchmark:SetAttribute("QuickStatus", "Closed")
			assert(not pcall(session.run) and runIndex == 2 and aborts == 0 and #warnings == 0,
				"a client cannot rerun a closed session or invalidate completed rows by trying")
			assert(firstRun[1].validity.valid and secondRun[1].validity.valid)
		end,
		failServer = function() benchmark:SetAttribute("QuickFailure", "late server failure") end,
		failClient = function() context.sink({}, {}) end,
		verify = function(reason)
			assert(attributes.QuickStatus == "Failed", "idle failure must publish Failed")
			for _, rows in { firstRun, secondRun } do
				for _, row in rows do
					assert(row.validity.valid == false and row.validity.failure == reason,
						"already-returned rows must be invalidated")
				end
			end
			assert(#warnings == 1 and string.find(warnings[1], "invalid", 1, true), "visible invalidation required")
			assert(teardowns == adapterCount and aborts == 1, "failure cleanup/Abort must happen once")
			assert(not pcall(session.run) and runIndex == 2, "terminal failure must reject reruns")
			assert(#warnings == 1 and teardowns == adapterCount and aborts == 1, "terminal failure must remain idempotent")
		end,
	}
end
local idleServer = quickClient(0)
idleServer.close()
idleServer.failServer()
idleServer.verify("late server failure")
local idleClient = quickClient(0.3)
assert(math.abs(idleClient.rows[1].summary.deliveryConfirmation.median
	- idleServer.rows[1].summary.deliveryConfirmation.median - 0.3) < 1e-9,
	"delayed completion must increase confirmation time without inflating call time")
idleClient.failClient()
idleClient.verify("unexpected quick benchmark delivery")
quickClient(0, "tiny-steady-c2s", "valid")
for _, malformed in { "not-table", "short", "extra", "keyed", "nonfinite" } do
	quickClient(0, "tiny-steady-c2s", malformed)
end

-- The optional recorder is exercised through the real Session lifecycle. The
-- stub deliberately adds a deterministic interval around the capture sink so
-- the measured sample proves wrap, begin/finish phase isolation, and raw
-- measured samples are retained. Disabled recorders must remain untouched.
local function callbackProfile(enabled, caseId)
	local now, runIndex, phaseNumber, stage = 0, 0, 0, "Start"
	local expectedBatches, context
	local begins, wraps, finishes, active = 0, 0, 0, nil
	local recorder = { enabled = enabled }
	local profileFailure
	function recorder.setFailureHandler(callback) profileFailure = callback end
	function recorder.begin(id, expectedCount)
		assert(enabled and active == nil)
		begins += 1
		active = { id = id, expectedCount = expectedCount, values = {} }
	end
	function recorder.wrap(id, callback)
		wraps += 1
		return function(...)
			assert(active ~= nil and active.id == id)
			local before = now
			now += 0.000003
			local first, second, third = callback(...)
			now += 0.000002
			table.insert(active.values, now - before)
			return first, second, third
		end
	end
	function recorder.finish(id)
		assert(enabled and active ~= nil and active.id == id and #active.values == active.expectedCount)
		finishes += 1
		local values = active.values
		active = nil
		return values
	end
	local profileWarnings = {}
	local config = table.clone(Config)
	config.caseId, config.warmupFrames, config.measuredFrames = caseId or "state-broadcast-s2c", 1, 1
	local messages = Model.selection(config).messagesPerFrame
	local transports = { ["native-reliable"] = { id = "native-reliable" } }
	function transports:FindFirstChild(id) return self[id] end
	local factory = {
		constructClient = function(value)
			context = value
			-- Generated adapter instrumentation wraps its callback binding before
			-- invoking the Session sink; the sink itself stays unwrapped.
			if enabled then value.sink = recorder.wrap("native-reliable", value.sink) end
			return { setup = function() end, ready = function() return true end, teardown = function() end }
		end,
	}
	local attributes, observers, output = {}, {}, {}
	local benchmark = {
		QuickAdapters = { Value = "native-reliable" }, QuickTransports = transports,
		adapters = { NativeReliable = factory }, Runner = { ExternalReadiness = {} }, CallbackTiming = recorder,
	}
	function benchmark:GetAttribute(key) return attributes[key] end
	function benchmark:SetAttribute(key, value)
		attributes[key] = value
		if observers[key] then observers[key]() end
	end
	function benchmark:GetAttributeChangedSignal(key)
		return { Connect = function(_, callback) observers[key] = callback; return {} end }
	end
	function benchmark:FindFirstChild(key) return self[key] end
	benchmark.QuickControl = { InvokeServer = function(_, command)
		if command == "Start" then
			runIndex += 1
			expectedBatches = Model.runBatches(config, Model.selection(config), runIndex, 1)
			phaseNumber, stage = 0, "Begin"
			return runIndex
		end
		assert(command == stage)
		if command == "Begin" then
			phaseNumber += 1
			local batch = expectedBatches[math.ceil(phaseNumber / 2)][(phaseNumber - 1) % 2 + 1]
			for _, fixture in batch do context.sink({ kind = "Record", value = fixture.input }, {}) end
			stage = "Drain"
		elseif command == "Drain" then
			stage = "Finish"
		elseif command == "Finish" then
			stage = if phaseNumber == Model.roundCount(1) * 2 then "Complete" else "Begin"
			return {
				sent = messages, elapsed = 1, calls = { mean = 1, median = 1, p95 = 1 },
				floor = { mean = 0.1 }, frames = { mean = 1, p95 = 1 }, rtt = nil,
				kbps = 1, messagesPerFrame = 1, deliveryConfirmation = 1, acknowledgementTail = 0,
			}
		elseif command == "Complete" then
			stage = "Start"
			return true
		end
		return true
	end }
	local quick = { Parent = benchmark, Config = config, Model = Model, CallbackTiming = recorder }
	local services = {
		RunService = { IsServer = function() return false end, IsStudio = function() return true end,
			PostSimulation = { Wait = function() now += 0.05 end } },
		Players = {}, ReplicatedStorage = {}, Stats = { DataSendKbps = 1 },
	}
	local session = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
		game = { GetService = function(_, name) return services[name] end }, script = { Parent = quick },
		require = function(value) return value end,
		os = { clock = function() now += 0.000001; return now end },
		task = { spawn = function(callback) callback(); return coroutine.create(function() end) end },
		print = function(message) table.insert(output, message) end,
		warn = function(message) table.insert(profileWarnings, message) end,
	} })()
	local rows = session.run()
	assert(rows[1].profile == (if enabled then "receive-callback" else "unprofiled"))
	assert(rows[1].sent == Model.roundCount(1) * messages and #rows[1].rounds == Model.roundCount(1) and stage == "Start",
		"steady and burst runs must complete every phase before returning")
	if enabled then
		assert(begins == 6 and finishes == 6 and wraps == 1)
		for _, round in rows[1].rounds do
			assert(#round.receiveCallbackSamples == messages and round.sent == messages,
				"profile callback counts must match every measured burst")
		end
		assert(math.abs(rows[1].rounds[1].receiveCallbacks.median - 0.000006) < 1e-12)
		assert(string.find(table.concat(output, "\n"), "receive callback mean", 1, true))
		profileFailure("late raw callback outside profile phase")
		assert(not rows[1].validity.valid and attributes.QuickStatus == "Failed" and #profileWarnings == 1,
			"idle profiling failures must invalidate already-returned rows")
	else
		assert(begins == 0 and finishes == 0 and wraps == 0 and rows[1].rounds[1].receiveCallbacks == nil)
	end
	return rows
end
callbackProfile(false)
callbackProfile(true)
callbackProfile(false, "state-broadcast-burst-s2c")
callbackProfile(true, "state-broadcast-burst-s2c")

-- Load the real server state machine as well: client-side mocks alone cannot
-- prove that Drain, round rotation, and yielding aborts are accepted correctly.
local function quickServer(caseId, profiled)
	local now, remote, waitHook = 0, nil, nil
	local function clock() now += 0.000001; return now end
	local removing, teardowns = nil, 0
	local attributes, contexts, warnings = {}, {}, {}
	local profileBegins, profileFinishes = 0, 0
	local config = table.clone(Config)
	config.caseId, config.warmupFrames, config.measuredFrames = caseId, 1, 2
	local adapterCount = if Model.selection(config).schema then 1 else 2
	local callbackTiming = DisabledCallbackTiming
	if profiled then
		local recorder = luau.load(fs.readFile("benchmarks/quick/CallbackTiming.luau"), { environment = {
			script = { Parent = { ProfileReceive = { Value = true } } },
			os = { clock = clock },
		} })()
		local expectedCount
		callbackTiming = {
			enabled = recorder.enabled,
			setFailureHandler = recorder.setFailureHandler,
			wrap = recorder.wrap,
			begin = function(id, count)
				recorder.begin(id, count)
				profileBegins += 1
				expectedCount = count
			end,
			finish = function(id)
				local samples = recorder.finish(id)
				profileFinishes += 1
				expectedCount = nil
				return samples
			end,
			isActive = function() return profileBegins > profileFinishes end,
			expectedCount = function() return expectedCount end,
			finishCount = function() return profileFinishes end,
		}
	end
	local player = {}
	local factory = { constructServer = function(context)
		if profiled then context.sink = callbackTiming.wrap(context.resourceRoot.Name, context.sink) end
		contexts[context.resourceRoot.Name] = context
		return { setup = function() end, ready = function() return true end, teardown = function() teardowns += 1 end,
			broadcast = function() now += 0.000010 end }
	end }
	local benchmark = {
		QuickAdapters = { Value = if adapterCount == 1 then "relay-reliable" else "native-reliable,relay-reliable" }, QuickTransports = {},
		adapters = { NativeReliable = factory, RelayReliable = factory }, Runner = { ExternalReadiness = {} },
	}
	function benchmark:GetAttribute(key) return attributes[key] end
	function benchmark:SetAttribute(key, value) attributes[key] = value end
	local event = { Connect = function() return {} end }
	local services = {
		RunService = { IsServer = function() return true end, IsStudio = function() return true end,
			PostSimulation = { Wait = function()
				now += 0.05
				if waitHook then local callback = waitHook; waitHook = nil; callback() end
			end } },
		Players = { GetPlayers = function() return { player } end, PlayerAdded = event,
			PlayerRemoving = { Connect = function(_, callback) removing = callback; return {} end } },
		ReplicatedStorage = {}, Stats = { DataSendKbps = 12.5 },
	}
	local session = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
		game = { GetService = function(_, name) return services[name] end },
		script = { Parent = { Parent = benchmark, Config = config, Model = Model, SchemaRelay = factory,
			CallbackTiming = callbackTiming } },
		require = function(value) return value end, os = { clock = clock },
		Instance = { new = function(class)
			local instance = {}
			if class == "RemoteFunction" then remote = instance end
			return instance
		end },
		warn = function(message) table.insert(warnings, message) end,
	} })()
	session.serve()
	assert(attributes.QuickStatus == "Ready")
	return {
		invoke = function(command, ...) return remote.OnServerInvoke(player, command, ...) end,
		deliver = function(id, batch)
			if profiled then assert(callbackTiming.isActive(), "profile phase must start before server delivery") end
			for _, fixture in batch do contexts[id].sink({ kind = "Record", value = fixture.input }, { sender = player }) end
		end,
		deliverRawNoop = function(id)
			callbackTiming.wrap(id, function() end)()
		end,
		batches = function(run) return Model.runBatches(config, Model.selection(config), run, adapterCount) end,
		onWait = function(callback) waitHook = callback end,
		advance = function(seconds) now += seconds end,
		leave = function() removing(player) end,
		teardowns = function() return teardowns end,
		attributes = attributes, warnings = warnings, adapterCount = adapterCount,
		profile = if profiled then callbackTiming else nil,
		deliverExtra = function(id, fixture)
			contexts[id].sink({ kind = "Record", value = fixture.input }, { sender = player })
		end,
		rawCallback = function(id)
			-- A transport callback can return before dispatching to the capture sink.
			callbackTiming.wrap(id, function() end)()
		end,
	}
end

local function finishServerRounds(server, run)
	assert(server.invoke("Start") == run)
	local a, b = "native-reliable", "relay-reliable"
	local lastId, lastBatch
	for round, phases in server.batches(run) do
		for position = 1, server.adapterCount do
			local index = Model.adapterIndex(server.adapterCount, run, round, position)
			local id = if server.adapterCount == 1 then b else if index == 1 then a else b
			for _, batch in phases do
				assert(server.invoke("Begin") == true)
				if server.profile then
					assert(server.profile.isActive() and server.profile.expectedCount() == #batch,
						"server receive profiling must begin before deliveries")
				end
				-- Drain must actually wait for the final delivery.
				server.onWait(function() server.deliver(id, batch) end)
				assert(server.invoke("Drain") == true)
				local result = server.invoke("Finish")
				if server.profile then
					assert(type(result) == "table")
					local samples = result.receiveCallbackSamples
					assert(#samples == #batch and result.sent == nil,
						"profile Finish must return only its raw receive samples")
					for _, sample in samples do
						assert(math.abs(sample - 0.000002) < 1e-12, "server must return callback durations after Finish")
					end
				else
					assert(result == true)
				end
				lastId, lastBatch = id, batch
			end
		end
	end
	assert(server.attributes.QuickStatus == "Running" and #server.warnings == 0,
		"completion must await final client validation acknowledgement")
	if server.profile then assert(server.profile.finishCount() == Model.roundCount(server.adapterCount) * server.adapterCount * 2) end
	return lastId, lastBatch
end
for payloadId in SchemaFixtures.fields do
	local client = quickClient(0, payloadId .. "-c2s")
	assert(#client.rows == 1 and client.rows[1].rankingEligible == false)
	client.close()
	local schemaServer = quickServer(payloadId .. "-c2s")
	for run = 1, 2 do
		finishServerRounds(schemaServer, run)
		assert(schemaServer.invoke("Complete") == true)
	end
	schemaServer.leave()
	assert(schemaServer.teardowns() == 1 and schemaServer.attributes.QuickStatus == "Closed")
end

local server = quickServer("tiny-steady-c2s")
for run = 1, 2 do
	finishServerRounds(server, run)
	assert(server.invoke("Complete") == true and server.attributes.QuickStatus == "Complete")
end
server.leave()
assert(server.attributes.QuickStatus == "Closed" and server.attributes.QuickFailure == nil and #server.warnings == 0,
	"normal shutdown after completed runs must preserve successful results")
assert(server.teardowns() == 2, "normal close must release each adapter once")
assert(server.invoke("Start") == false and server.attributes.QuickStatus == "Closed",
	"a closed session cannot start again or invalidate completed results")
server.leave()
assert(server.teardowns() == 2 and #server.warnings == 0)
server.deliver("relay-reliable", { server.batches(2)[3][2][1] })
assert(server.attributes.QuickStatus == "Failed" and #server.warnings == 1 and server.teardowns() == 2,
	"a queued late delivery fault must still invalidate a closed session without repeated cleanup")

local profiledServer = quickServer("tiny-steady-c2s", true)
local lastProfiledId, lastProfiledBatch = finishServerRounds(profiledServer, 1)
profiledServer.deliverExtra(lastProfiledId, lastProfiledBatch[1])
assert(profiledServer.attributes.QuickStatus == "Failed" and #profiledServer.warnings == 1,
	"a callback after the final profile Finish must invalidate the run")

local burstProfile = quickServer("state-burst-c2s", true)
finishServerRounds(burstProfile, 1)
assert(burstProfile.invoke("Complete") == true, "default C2S burst profile must complete every sample")

local missingProfile = quickServer("tiny-steady-c2s", true)
assert(missingProfile.invoke("Start") == 1 and missingProfile.invoke("Begin") == true)
assert(missingProfile.profile.isActive() and missingProfile.profile.expectedCount() == 1)
missingProfile.onWait(function() missingProfile.advance(20) end)
assert(missingProfile.invoke("Drain") == false and missingProfile.attributes.QuickStatus == "Failed"
	and missingProfile.profile.finishCount() == 0, "missing C2S delivery must not produce profile samples")

local rawRejected = quickServer("tiny-steady-c2s", true)
assert(rawRejected.invoke("Start") == 1 and rawRejected.invoke("Begin") == true)
rawRejected.rawCallback("native-reliable")
rawRejected.onWait(function() rawRejected.advance(20) end)
assert(rawRejected.invoke("Drain") == false and rawRejected.attributes.QuickStatus == "Failed"
	and rawRejected.profile.finishCount() == 0, "a recorded raw callback cannot substitute for a verified delivery")

local rawExtra = quickServer("tiny-steady-c2s", true)
assert(rawExtra.invoke("Start") == 1 and rawExtra.invoke("Begin") == true)
rawExtra.deliver("native-reliable", rawExtra.batches(1)[1][1])
rawExtra.rawCallback("native-reliable")
assert(rawExtra.attributes.QuickStatus == "Failed" and rawExtra.invoke("Drain") == false
	and rawExtra.profile.finishCount() == 0, "extra raw callbacks must fail even when the capture count is exact")

local rejectedProfile = quickServer("tiny-steady-c2s", true)
assert(rejectedProfile.invoke("Start") == 1 and rejectedProfile.invoke("Begin") == true)
local rejectedBatch = rejectedProfile.batches(1)[1][1]
rejectedProfile.deliver("relay-reliable", rejectedBatch)
assert(rejectedProfile.invoke("Drain") == false and rejectedProfile.attributes.QuickStatus == "Failed"
	and rejectedProfile.profile.finishCount() == 0, "wrong-adapter callback must not pass C2S profiling")

local completedProfile = quickServer("tiny-steady-c2s", true)
local completedId, completedBatch = finishServerRounds(completedProfile, 1)
assert(completedProfile.invoke("Complete") == true)
completedProfile.leave()
assert(completedProfile.attributes.QuickStatus == "Closed")
completedProfile.deliverExtra(completedId, completedBatch[1])
assert(completedProfile.attributes.QuickStatus == "Failed" and #completedProfile.warnings == 1,
	"a callback after Complete must invalidate profiled results")

local pending = quickServer("tiny-steady-c2s")
finishServerRounds(pending, 1)
pending.leave()
assert(pending.attributes.QuickStatus == "Failed" and pending.invoke("Complete") == false,
	"departure before final client validation must remain a failure")
local rerunDeparture = quickServer("tiny-steady-c2s")
finishServerRounds(rerunDeparture, 1)
assert(rerunDeparture.invoke("Complete") == true and rerunDeparture.invoke("Start") == 2)
rerunDeparture.leave()
assert(rerunDeparture.attributes.QuickStatus == "Failed", "departure during a rerun must invalidate earlier results")
local lateAbort = quickServer("tiny-steady-c2s")
finishServerRounds(lateAbort, 1)
assert(lateAbort.invoke("Complete") == true)
lateAbort.leave()
assert(lateAbort.invoke("Abort", nil) == false and #lateAbort.warnings == 0)
assert(lateAbort.invoke("Abort") == false and lateAbort.attributes.QuickStatus == "Failed"
	and lateAbort.teardowns() == 2, "a valid late client failure must survive normal closure")

local early = quickServer("tiny-steady-c2s")
assert(early.invoke("Drain") == false and early.attributes.QuickStatus == "Failed")
assert(early.invoke("Start") == false and #early.warnings == 1)
local earlyComplete = quickServer("tiny-steady-c2s")
assert(earlyComplete.invoke("Start") == 1 and earlyComplete.invoke("Complete") == false,
	"Complete cannot skip required phases")
local extra = quickServer("tiny-steady-c2s")
assert(extra.invoke("Start") == 1 and extra.invoke("Begin") == true)
assert(extra.invoke("Drain", nil) == false and extra.attributes.QuickStatus == "Failed")
local aborted = quickServer("tiny-steady-c2s")
assert(aborted.invoke("Start") == 1 and aborted.invoke("Begin") == true)
aborted.onWait(function() assert(aborted.invoke("Abort") == false) end)
assert(aborted.invoke("Drain") == false and aborted.attributes.QuickStatus == "Failed")
assert(aborted.invoke("Start") == false and #aborted.warnings == 1, "a yielding Drain cannot revive an aborted run")

local corrupt = quickServer("tiny-steady-c2s")
assert(corrupt.invoke("Start") == 1 and corrupt.invoke("Begin") == true)
local corruptBatch = corrupt.batches(1)[1][1]
corruptBatch[1].input.enabled = not corruptBatch[1].input.enabled
corrupt.deliver("native-reliable", corruptBatch)
assert(corrupt.invoke("Drain") == true, "receipt acknowledgement is not a payload-validity claim")
assert(corrupt.invoke("Finish") == false and corrupt.attributes.QuickStatus == "Failed")

local broadcast = quickServer("state-broadcast-s2c")
assert(broadcast.invoke("Start") == 1 and broadcast.invoke("Begin") == true)
broadcast.advance(0.3)
assert(broadcast.invoke("Drain") == true)
local measured = broadcast.invoke("Finish")
assert(math.abs(measured.deliveryConfirmation - measured.elapsed - 0.3) < 0.0001,
	"S2C confirmation uses the server clock and excludes Finish quiet/validation")
assert(math.abs(measured.calls.mean - 0.000011) < 1e-9 and math.abs(measured.floor.mean - 0.000001) < 1e-9)

for _, name in { "Config.luau", "Model.luau", "SchemaFixtures.luau", "SchemaRelay.luau", "Session.luau", "Server.server.luau", "Client.client.luau" } do
	luau.compile(fs.readFile("benchmarks/quick/" .. name))
end
print("PASS quick benchmark fixtures, rotation, timing, probe deadlines, calibration, Drain/Abort/Complete, closure, idle invalidation, and compilation")
