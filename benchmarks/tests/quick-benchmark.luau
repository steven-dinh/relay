local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
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
	"schema-signed-c2s", "schema-vector2-c2s", "schema-string-c2s", "schema-cframe-c2s", "schema-composite-c2s" } do
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
	if payloadId == "schema-composite" then
		wrongType.items = table.clone(wrongType.items)
		wrongType.items[1] = table.clone(wrongType.items[1])
		wrongType.items[1].score = "bad"
	else
		wrongType[fields[2].name] = {}
	end
	local malformed = Model.capture(payloadId, batch)
	assert(not malformed.push({ kind = "Record", value = wrongType }, 0) and malformed.count() == 0)
	local arity = Model.capture(payloadId, batch)
	assert(not arity.push({ kind = "Positional", values = {}, count = #fields + 1 }, 0))
	local duplicate = Model.capture(payloadId, { batch[1], batch[2] })
	assert(duplicate.push({ kind = "Record", value = batch[1].input }, 0))
	assert(duplicate.push({ kind = "Record", value = batch[1].input }, 1))
	assert(not pcall(duplicate.verify), "schema duplicate/stale sequence")
end

local compositeConfig = table.clone(Config)
compositeConfig.caseId = "schema-composite-c2s"
local compositeBatch = Model.batches(compositeConfig, Model.selection(compositeConfig), 1)[1]
local compositeFixture = compositeBatch[1]
assert(#compositeFixture.expected.items == 16 and compositeFixture.input.items ~= compositeFixture.expected.items)
for index, item in compositeFixture.expected.items do
	assert(compositeFixture.input.items[index] ~= item, "composite fixture records must be independent")
end
compositeFixture.input.items[1].score += 1
assert(not pcall(Model.verifyInputs, "schema-composite", { compositeFixture }),
	"nested adapter input mutation must be detected")

local isolatedFixture = compositeBatch[2]
local isolatedCapture = Model.capture("schema-composite", { isolatedFixture })
assert(isolatedCapture.push({ kind = "Record", value = isolatedFixture.input }, 0))
isolatedFixture.input.items[1].score += 1
isolatedCapture.verify()

local function cloneComposite(value)
	local items = table.create(#value.items)
	for index, item in value.items do items[index] = table.clone(item) end
	return { sequence = value.sequence, items = items }
end
local compositeExpected = SchemaFixtures.generate("schema-composite", 19)
local function rejectsComposite(value, label)
	local capture = Model.capture("schema-composite", { { expected = compositeExpected } })
	assert(not capture.push({ kind = "Record", value = value }, 0) and capture.count() == 0, label)
end
local malformedComposite = cloneComposite(compositeExpected)
malformedComposite.items[1].score = "bad"
rejectsComposite(malformedComposite, "malformed composite item rejected")
local nonplainComposite = cloneComposite(compositeExpected)
setmetatable(nonplainComposite.items[1], {})
rejectsComposite(nonplainComposite, "nonplain composite item rejected")
local oversizedComposite = cloneComposite(compositeExpected)
oversizedComposite.items[17] = table.clone(oversizedComposite.items[16])
rejectsComposite(oversizedComposite, "oversized composite array rejected")
local sparseComposite = cloneComposite(compositeExpected)
sparseComposite.items[3] = nil
rejectsComposite(sparseComposite, "sparse composite array rejected")

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
		local compiled = Definition.get(definition)
		local eventDefinition = compiled.events.Submit
		if payloadId == "schema-composite" then
			assert(string.sub(compiled.descriptor, 1, 3) == "RR3" and eventDefinition.usesCodec
				and eventDefinition.maximumEncodedBytes == 121, "composite schema must select RR3 and its 121-byte limit")
			local goldenHex = "01010000000000100000000080ffff0101000180ffff0002"
				.. "000280ffff0103000380ffff0004000480ffff0105000580"
				.. "ffff0006000680ffff0107000780ffff0008000880ffff01"
				.. "09000980ffff000a000a80ffff010b000b80ffff000c000c"
				.. "80ffff010d000d80ffff000e000e80ffff010f000f80ffff"
				.. "00"
			local goldenFixture = SchemaFixtures.generate(payloadId, 0)
			local encodedOk, encoded = Frame.compile(eventDefinition, "encode")(
				goldenFixture.sequence, goldenFixture.items)
			assert(encodedOk and buffer.len(encoded) == 121 and #goldenHex == 242,
				"composite frame must encode its full bounded array")
			for offset = 0, buffer.len(encoded) - 1 do
				assert(buffer.readu8(encoded, offset) == tonumber(string.sub(goldenHex, offset * 2 + 1, offset * 2 + 2), 16),
					"composite encoded bytes must match the RR3 golden")
			end
			local decoded = table.pack(Frame.compile(eventDefinition, "decode")(encoded))
			assert(decoded.n == 3 and decoded[1] == true
				and SchemaFixtures.compare(payloadId, goldenFixture, { sequence = decoded[2], items = decoded[3] }, false),
				"composite frame must round-trip through the existing Relay fixture fake")
		end
		local validate = Frame.compile(eventDefinition)
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
	{ adapters = "relay-reliable,relay-reliable" }, { adapters = "relay-reliable", profile = true },
	{ caseId = "schema-vector2-c2s", adapters = "relay-reliable", profile = true },
	{ caseId = "schema-string-c2s", adapters = "relay-reliable", profile = true },
	{ caseId = "schema-cframe-c2s", adapters = "relay-reliable", profile = true },
	{ caseId = "schema-composite-c2s", adapters = "native-reliable", profile = true },
	{ caseId = "schema-composite-c2s", adapters = "relay-reliable,native-reliable", profile = true } } do
	local config = table.clone(Config)
	config.caseId = invalid.caseId or "schema-signed-c2s"
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

local summaryRows = {
	{ adapterId = "relay-reliable", caseId = "state-burst-c2s", profile = "unprofiled",
		summary = { fps = { median = 90 }, kbps = { median = 3 } }, sent = 120, rankingEligible = false },
	{ adapterId = "native-reliable", caseId = "state-burst-c2s", profile = "unprofiled",
		summary = { fps = { median = 60 }, kbps = { median = 4 } }, sent = 120, rankingEligible = false },
	{ adapterId = "quicknet", caseId = "state-burst-c2s", profile = "unprofiled",
		summary = { fps = { median = 90 }, kbps = { median = 2 } }, sent = 120, rankingEligible = false },
}
for caseId, expectedCategory in {
	["tiny-steady-c2s"] = "Booleans", ["tiny-round-trip"] = "Booleans",
	["state-steady-c2s"] = "Mixed state", ["state-burst-c2s"] = "Mixed state",
	["state-broadcast-s2c"] = "Mixed state", ["state-broadcast-burst-s2c"] = "Mixed state",
	["schema-signed-c2s"] = "Numbers", ["schema-string-c2s"] = "Strings",
	["schema-vector2-c2s"] = "Vectors", ["schema-vector3-c2s"] = "Vectors",
	["schema-cframe-c2s"] = "CFrames", ["schema-composite-c2s"] = "Entity arrays",
} do
	assert(Model.category(caseId) == expectedCategory, caseId .. " payload category changed")
end
local coreCaseIds = Model.coreCategoryCases("all")
assert(table.concat(coreCaseIds, ",") == "tiny-steady-c2s,schema-string-c2s,schema-signed-c2s,schema-vector3-c2s,state-steady-c2s")
assert(table.concat(Model.coreCategoryCases("booleans"), ",") == "tiny-steady-c2s"
	and table.concat(Model.coreCategoryCases("mixed"), ",") == "state-steady-c2s")
assert(#Model.coreCases("") == 0 and table.concat(Model.coreCases(table.concat(coreCaseIds, ",")), ",") == table.concat(coreCaseIds, ","))
for _, invalid in { "unknown", "tiny-steady-c2s,tiny-steady-c2s", "state-steady-c2s,tiny-steady-c2s", "," } do
	assert(not pcall(Model.coreCases, invalid), "invalid core category lists must reject")
end
assert(not pcall(Model.coreCategoryCases, "unknown"), "unknown CLI categories must reject")

-- Invalid category CLI input must stop before build output or acquisition.
local function rejectCoreBuild(arguments, expected)
	local writes = 0
	local dependencies = {
		["@lune/fs"] = { isFile = function() return true end, isDir = function() return false end,
			writeDir = function() writes += 1 end, writeFile = function() writes += 1 end },
		["@lune/process"] = { args = arguments, cwd = ".", exec = function() writes += 1 end },
		["@lune/serde"] = serde,
		["../host/ExternalAdapterCatalog"] = { ids = {}, isSupported = function() return false end },
		["./ReceiveInstrumentation"] = {}, ["./Model"] = Model,
	}
	local ok, reason = pcall(function()
		luau.load(fs.readFile("benchmarks/quick/build.luau"), { environment = {
			require = function(path) return assert(dependencies[path], "unexpected build dependency: " .. path) end,
		} })()
	end)
	assert(not ok and string.find(tostring(reason), expected, 1, true) and writes == 0,
		"invalid category build must reject before writing artifacts: " .. tostring(reason) .. " writes=" .. writes)
end
rejectCoreBuild({ "--category", "unknown" }, "unknown quick benchmark category")
rejectCoreBuild({ "--category", "all", "--profile-receive" }, "do not support receive profiling")
local summaryTable = Model.renderSummary(summaryRows)
assert(string.find(summaryTable, "sender FPS descending; order is not a benchmark ranking", 1, true)
	and string.find(summaryTable, "| 1 | quicknet | 90.00 | 1.500x | 2.00 | 120/120 |", 1, true)
	and string.find(summaryTable, "| 2 | relay-reliable | 90.00 | 1.500x | 3.00 | 120/120 |", 1, true)
	and string.find(summaryTable, "| 3 | native-reliable | 60.00 | 1.000x | 4.00 | 120/120 |", 1, true),
	"frame summary must sort FPS descending, break ties by adapterId, and scale to native")
assert(summaryRows[1].adapterId == "relay-reliable" and summaryRows[2].adapterId == "native-reliable"
	and summaryRows[3].adapterId == "quicknet" and summaryRows[1].rankingEligible == false,
	"rendering the summary must preserve returned order and diagnostic eligibility")

local noNativeSummary = Model.renderSummary({
	{ adapterId = "relay-reliable", summary = { fps = { median = 30 }, kbps = { median = 1 } }, sent = 10 },
})
assert(string.find(noNativeSummary, "| 1 | relay-reliable | 30.00 | N/A | 1.00 | 10/10 |", 1, true),
	"frame summary without native must show N/A scale")
local zeroNativeSummary = Model.renderSummary({
	{ adapterId = "native-reliable", summary = { fps = { median = 0 }, kbps = { median = 1 } }, sent = 10 },
	{ adapterId = "relay-reliable", summary = { fps = { median = 30 }, kbps = { median = 1 } }, sent = 10 },
})
assert(string.find(zeroNativeSummary, "| 1 | relay-reliable | 30.00 | N/A |", 1, true)
	and string.find(zeroNativeSummary, "| 2 | native-reliable | 0.00 | N/A |", 1, true),
	"zero native FPS must not produce a scale")
local multipleNativeSummary = Model.renderSummary({
	{ adapterId = "native-reliable", summary = { fps = { median = 60 }, kbps = { median = 1 } }, sent = 10 },
	{ adapterId = "native-reliable", summary = { fps = { median = 50 }, kbps = { median = 1 } }, sent = 10 },
	{ adapterId = "relay-reliable", summary = { fps = { median = 30 }, kbps = { median = 1 } }, sent = 10 },
})
assert(string.find(multipleNativeSummary, "| 3 | relay-reliable | 30.00 | N/A |", 1, true),
	"multiple native rows must not choose an arbitrary FPS baseline")

local s2cRows = {
	{ adapterId = "native-reliable", caseId = "state-broadcast-s2c", profile = "unprofiled",
		summary = { fps = { median = 60 }, kbps = { median = 4 } }, sent = 10, rankingEligible = false },
	{ adapterId = "relay-reliable", caseId = "state-broadcast-s2c", profile = "unprofiled",
		summary = { fps = { median = 65 }, kbps = { median = 5 } }, sent = 10, rankingEligible = false },
	{ adapterId = "quicknet", caseId = "state-broadcast-s2c", profile = "unprofiled",
		summary = { fps = { median = 90 }, kbps = { median = 2 } }, sent = 10, rankingEligible = false },
	{ adapterId = "blink", caseId = "state-broadcast-s2c", profile = "unprofiled",
		summary = { fps = { median = 70 }, kbps = { median = 3 } }, sent = 10, rankingEligible = false },
}
local s2cSummary = Model.renderSummary(s2cRows, {
	["native-reliable"] = "NativeBroadcast", ["relay-reliable"] = "NativeBroadcast",
	quicknet = "AdapterFanOut", blink = "AdapterFanOut",
})
local fanoutGroup = string.find(s2cSummary, "Broadcast mode: AdapterFanOut", 1, true)
local nativeGroup = string.find(s2cSummary, "Broadcast mode: NativeBroadcast", 1, true)
assert(fanoutGroup and nativeGroup and fanoutGroup < nativeGroup
	and string.find(s2cSummary, "| 1 | quicknet | 90.00 | N/A | 2.00 | 10/10 |", 1, true)
	and string.find(s2cSummary, "| 2 | blink | 70.00 | N/A | 3.00 | 10/10 |", 1, true)
	and string.find(s2cSummary, "| 1 | relay-reliable | 65.00 | 1.083x | 5.00 | 10/10 |", 1, true)
	and string.find(s2cSummary, "| 2 | native-reliable | 60.00 | 1.000x | 4.00 | 10/10 |", 1, true),
	"S2C summaries must separate broadcast modes, reset order, and use only same-mode baselines")
assert(s2cRows[1].adapterId == "native-reliable" and s2cRows[2].adapterId == "relay-reliable"
	and s2cRows[3].adapterId == "quicknet" and s2cRows[4].adapterId == "blink"
	and s2cRows[1].rankingEligible == false,
	"S2C summary grouping must preserve returned rows and diagnostic eligibility")

local rttSummary = Model.renderSummary({
	{ adapterId = "relay-reliable", caseId = "tiny-round-trip", profile = "unprofiled",
		summary = { rttMean = { median = 0.03 }, rttP95 = { median = 0.05 } }, sent = 3 },
	{ adapterId = "native-reliable", caseId = "tiny-round-trip", profile = "unprofiled",
		summary = { rttMean = { median = 0.01 }, rttP95 = { median = 0.04 } }, sent = 3 },
})
assert(string.find(rttSummary, "RTT avg ascending; order is not a benchmark ranking", 1, true)
	and string.find(rttSummary, "| 1 | native-reliable | 10.00 | 40.00 | 3/3 |", 1, true)
	and string.find(rttSummary, "| 2 | relay-reliable | 30.00 | 50.00 | 3/3 |", 1, true)
	and string.find(rttSummary, "| Order | Adapter | RTT avg (ms) | RTT p95 (ms) | Sent / verified |", 1, true)
	and string.find(rttSummary, "Sender FPS", 1, true) == nil,
	"RTT summary must sort latency ascending without an FPS conversion")

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
		"return table.freeze%({ serve = serve, run = run,.-}%)", "return { pace = pace }")
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
		"return table.freeze%({ serve = serve, run = run,.-}%)", "return { pace = pace }")
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
		CallbackTiming = callbackTiming, ProfileCpu = { Value = false } }
	function quick:FindFirstChild(name)
		if name == "ProfileCpu" then return self.ProfileCpu end
		return nil
	end
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
	local firstAdapter = if adapterCount == 1 then "relay-reliable" else "native-reliable"
	local adapterDiagnostic = string.find(printed, "[Relay quick] " .. firstAdapter .. " |", 1, true)
	local categoryHeading = "[Relay quick] Payload category: " .. Model.category(config.caseId) .. " (" .. config.caseId .. ")"
	local summaryPosition = string.find(printed, "[Relay quick] Sorted local diagnostics", 1, true)
	local completePosition = string.find(printed, "[Relay quick] Complete.", 1, true)
	assert(adapterDiagnostic and summaryPosition and completePosition
		and adapterDiagnostic < summaryPosition and summaryPosition < completePosition
		and string.find(printed, categoryHeading, 1, true)
		and string.find(printed, "| Order | Adapter | Sender FPS | FPS scale vs Native | Send KB/s | Sent / verified |", 1, true),
		"sorted summary must print after adapter diagnostics and before Complete")
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
local function quickCoreClient(adapterId)
	adapterId = adapterId or "warp"
	local now, runIndex, phaseNumber, phaseSent, caseIndex = 0, 0, 0, 0, 1
	local starts, transitions, constructions, setups, submissions = 0, 0, 0, 0, 0
	local stage, expectedBatches = "Start", nil
	local config = table.clone(Config)
	config.caseId = "legacy-selection-must-not-win"
	config.warmupFrames, config.measuredFrames = 1, 2
	local cases = Model.coreCategoryCases("all")
	local coreValue, coreWaits, coreFinds, profileCpuWaits = nil, 0, 0, 0
	local profileCpu = { Value = false }
	local rootReady, coreRequires, prewarms = false, 0, 0
	local context
	local factory = {
		constructClient = function(value)
			constructions += 1
			context = value
			return {
				setup = function() setups += 1 end,
				ready = function() return true end,
				submit = function(payload, boundary)
					assert(stage == "Drain" and value.selection.payloadId == value.activePayloadId(),
						"the initialized core adapter must follow the active category")
					local selectionConfig = table.clone(config)
					selectionConfig.caseId = cases[caseIndex]
					local selected = Model.selection(selectionConfig)
					assert(value.activePayloadId() == selected.payloadId,
						"category order must match the declaration: " .. cases[caseIndex] .. " expected " .. selected.payloadId
							.. " got " .. tostring(value.activePayloadId()))
					local round = math.ceil(phaseNumber / 2)
					local phase = (phaseNumber - 1) % 2 + 1
					local batch = expectedBatches[round][phase]
					local index = phaseSent + 1
					assert(payload.sequence == batch[index].input.sequence and boundary == "FlushBeforeReturn",
						"core category fixtures must keep their declared values and flush boundary")
					phaseSent += 1
					submissions += 1
					now += 0.000010
				end,
				teardown = function() end,
			}
		end,
	}
	local root = {
		id = adapterId, Name = adapterId,
		GetAttribute = function(_, name)
			return if rootReady and name == "QuickCore" then true else nil
		end,
	}
	local transports = { [adapterId] = root }
	function transports:FindFirstChild(id) return self[id] end
	local readiness = {
		prewarm = function(id, resourceRoot, side)
			assert(id == adapterId and resourceRoot == root and side == "Client"
				and root:GetAttribute("QuickCore") == true,
				"external core prewarm must wait for the replicated QuickCore attribute")
			prewarms += 1
			return { kind = "Ready" }
		end,
		wrapFactory = function(_, value) return value end,
	}
	local benchmark = {
		QuickAdapters = { Value = adapterId }, QuickTransports = transports,
		adapters = { [adapterId] = factory }, Runner = { ExternalReadiness = readiness },
	}
	local attributes, output = {}, {}
	function benchmark:GetAttribute(key) return attributes[key] end
	function benchmark:SetAttribute(key, value) attributes[key] = value end
	function benchmark:GetAttributeChangedSignal()
		return { Connect = function() return {} end }
	end
	function benchmark:FindFirstChild(key) return self[key] end
	local quick = { Parent = benchmark, Config = config, Model = Model, CoreAdapters = factory,
		CallbackTiming = DisabledCallbackTiming, ProfileCpu = profileCpu,
		WaitForChild = function(_, name, timeout)
			assert(timeout == config.timeoutSeconds, "replicated quick metadata uses the bounded wait")
			if name == "ProfileCpu" then
				profileCpuWaits += 1
				return profileCpu
			end
			assert(name == "QuickCoreCases" and coreValue == nil,
				"the suite selector must wait while it has not replicated")
			coreWaits += 1
			coreValue = { Value = table.concat(cases, ",") }
			return coreValue
		end,
		FindFirstChild = function(_, name)
			if name == "ProfileCpu" then return profileCpu end
			if name == "QuickCoreCases" then
				coreFinds += 1
				return coreValue
			end
			return nil
		end,
	}
	local function refreshBatches()
		local selectedConfig = table.clone(config)
		selectedConfig.caseId = cases[caseIndex]
		expectedBatches = Model.runBatches(config, Model.selection(selectedConfig), runIndex, 1)
	end
	benchmark.QuickControl = { InvokeServer = function(_, command)
		if command == "Start" then
			starts += 1
			runIndex += 1
			caseIndex, phaseNumber, phaseSent, stage = 1, 0, 0, "Begin"
			refreshBatches()
			return runIndex
		end
		assert(command == stage, "core client control order")
		if command == "Begin" then
			phaseNumber += 1
			phaseSent = 0
			stage = "Drain"
		elseif command == "Drain" then
			local batch = expectedBatches[math.ceil(phaseNumber / 2)][(phaseNumber - 1) % 2 + 1]
			assert(phaseSent == #batch and #batch == (if phaseNumber % 2 == 1 then 1 else 2),
				"core phase must send its complete bounded batch")
			now += 0.1
			stage = "Finish"
		elseif command == "Finish" then
			stage = if phaseNumber == Model.roundCount(1) * 2
				then if caseIndex < #cases then "NextCase" else "Complete"
				else "Begin"
		elseif command == "NextCase" then
			caseIndex += 1
			transitions += 1
			phaseNumber, stage = 0, "Begin"
			refreshBatches()
			return cases[caseIndex]
		elseif command == "Complete" then
			stage = "Start"
		end
		return true
	end }
	local services = {
		RunService = { IsServer = function() return false end, IsStudio = function() return true end,
			PostSimulation = { Wait = function() now += 0.05; rootReady = true end } },
		Players = {}, ReplicatedStorage = {}, Stats = { DataSendKbps = 12.5 },
	}
	local session
	session = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
		game = { GetService = function(_, name) return services[name] end }, script = { Parent = quick },
		require = function(value)
			if value == quick.CoreAdapters then
				assert(root:GetAttribute("QuickCore") == true,
					"core factory must not be required before QuickCore replicates")
				coreRequires += 1
			end
			return value
		end,
		Instance = { new = function()
			return { SetAttribute = function() end }
		end },
		os = { clock = function() now += 0.000001; return now end },
		task = { spawn = function(callback) callback(); return coroutine.create(function() end) end },
		print = function(message) table.insert(output, message) end,
		warn = function(message) error(message) end,
	} })()
	assert(coreWaits == 1 and coreFinds == 0 and profileCpuWaits == 1 and coreValue ~= nil,
		"Session must wait for the selector instead of choosing the legacy Config.caseId")
	local missingFinds, missingTimeout = 0, nil
	local missingQuick = table.clone(quick)
	missingQuick.WaitForChild = function(_, name, timeout)
		if name == "ProfileCpu" then return profileCpu end
		assert(name == "QuickCoreCases")
		missingTimeout = timeout
		return nil
	end
	missingQuick.FindFirstChild = function(_, name)
		if name == "ProfileCpu" then return profileCpu end
		if name == "QuickCoreCases" then missingFinds += 1 end
		return nil
	end
	local missingOk, missingReason = pcall(function()
		return luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
			game = { GetService = function(_, name) return services[name] end },
			script = { Parent = missingQuick }, require = function(value) return value end,
		} })()
	end)
	assert(not missingOk and missingTimeout == config.timeoutSeconds and missingFinds == 0
		and string.find(tostring(missingReason), "QuickCoreCases did not replicate before timeout", 1, true),
		"a missing replicated selector must fail after the bounded wait, never fall back to legacy mode")
	local firstRun = session.run()
	local secondRun = session.run()
	assert(#firstRun == #cases and #secondRun == #cases
		and starts == 2 and transitions == 2 * (#cases - 1)
		and constructions == 1 and setups == 1 and coreWaits == 1 and coreFinds == 0 and profileCpuWaits == 1
		and coreRequires == 1 and prewarms == (if adapterId == "warp" then 1 else 0),
		"one adapter initializes once and Start/NextCase reruns the fixed suite")
	for run, rows in { firstRun, secondRun } do
		for index, row in rows do
			assert(row.caseId == cases[index] and row.sent == Model.roundCount(1) * config.measuredFrames
				and #row.rounds == Model.roundCount(1) and row.validity.valid,
				"each suite row belongs to its category and retains verified round results")
		end
	end
	assert(submissions == 2 * #cases * Model.roundCount(1) * (config.warmupFrames + config.measuredFrames),
		"each core category reruns without adapter reconstruction")
	local printed = table.concat(output, "\n")
	for _, caseId in cases do
		assert(string.find(printed, "Payload category: " .. Model.category(caseId) .. " (" .. caseId .. ")", 1, true),
			"all selected consumer categories must receive their own summary")
	end
end
local function delayedExternalBroadcastMode()
	local now, attributesReady = 0, false
	local modeReadsBeforeReady, prewarms, factoryRequires, constructions = 0, 0, 0, 0
	local root = { Name = "warp" }
	function root:GetAttribute(name)
		if not attributesReady then
			modeReadsBeforeReady += 1
			return nil
		end
		return if name == "QuickBroadcastMode" then "AdapterFanOut" else nil
	end
	local factory = {
		constructClient = function(context)
			assert(context.resourceRoot == root)
			constructions += 1
			return { setup = function() end, ready = function() return true end, teardown = function() end }
		end,
	}
	local readiness = {
		prewarm = function(id, resourceRoot, side)
			assert(id == "warp" and resourceRoot == root and side == "Client"
				and root:GetAttribute("QuickBroadcastMode") == "AdapterFanOut",
				"external S2C prewarm must wait for the broadcast mode attribute")
			prewarms += 1
			return { kind = "Ready" }
		end,
		wrapFactory = function(_, value) return value end,
	}
	local transports = { warp = root }
	function transports:FindFirstChild(id) return self[id] end
	local config = table.clone(Config)
	config.caseId = "state-broadcast-s2c"
	local benchmark = {
		QuickAdapters = { Value = "warp" }, QuickTransports = transports,
		adapters = { warp = factory }, Runner = { ExternalReadiness = readiness },
	}
	function benchmark:GetAttribute() return nil end
	function benchmark:GetAttributeChangedSignal()
		return { Connect = function() return {} end }
	end
	local quick = {
		Parent = benchmark, Config = config, Model = Model, CoreAdapters = factory,
		CallbackTiming = DisabledCallbackTiming, QuickCoreCases = { Value = "" },
		ProfileCpu = { Value = false },
	}
	function quick:WaitForChild(name, timeout)
		if name == "ProfileCpu" then
			assert(timeout == config.timeoutSeconds)
			return self.ProfileCpu
		end
		assert(name == "QuickCoreCases" and timeout == config.timeoutSeconds)
		return self.QuickCoreCases
	end
	local services = {
		RunService = { IsServer = function() return false end, IsStudio = function() return true end,
			PostSimulation = { Wait = function() now += 0.05; attributesReady = true end } },
		Players = {}, ReplicatedStorage = {}, Stats = { DataSendKbps = 12.5 },
	}
	local initializeSource, replacements = string.gsub(fs.readFile("benchmarks/quick/Session.luau"),
		"return table.freeze%({ serve = serve, run = run,.-}%)", "return { initialize = initialize }")
	assert(replacements == 1)
	local session = luau.load(initializeSource, { environment = {
		game = { GetService = function(_, name) return services[name] end }, script = { Parent = quick },
		require = function(value)
			if value == factory then
				assert(root:GetAttribute("QuickBroadcastMode") == "AdapterFanOut",
					"external S2C factory must not be required before its broadcast mode replicates")
				factoryRequires += 1
			end
			return value
		end,
		os = { clock = function() now += 0.001; return now end },
	} })()
	session.initialize()
	assert(modeReadsBeforeReady > 0 and prewarms == 1 and factoryRequires == 1 and constructions == 1,
		"external S2C initialization must wait for delayed broadcast metadata")
end
quickCoreClient("warp")
quickCoreClient("relay-reliable")
delayedExternalBroadcastMode()
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
local compositeProfileClient = quickClient(0, "schema-composite-c2s", "valid")
assert(#compositeProfileClient.rows == 1 and compositeProfileClient.rows[1].rankingEligible == false)
compositeProfileClient.close()
for _, malformed in { "not-table", "short", "extra", "keyed", "nonfinite" } do
	quickClient(0, "tiny-steady-c2s", malformed)
	quickClient(0, "schema-composite-c2s", malformed)
end

-- The optional recorder is exercised through the real Session lifecycle. The
-- stub deliberately adds a deterministic interval around the capture sink so
-- the measured sample proves wrap, begin/finish phase isolation, and raw
-- measured samples are retained. Disabled recorders must remain untouched.
local function callbackProfile(enabled, caseId, sdkAvailable, cpuEnabled, delayedSdk)
	local now, runIndex, phaseNumber, stage = 0, 0, 0, "Start"
	local expectedBatches, context
	local begins, wraps, finishes, active = 0, 0, 0, nil
	local cpuBegins, cpuFinishes, cpuNewCalls, cpuScopedSubmits, submits = 0, 0, 0, 0, 0
	local guidCalls = 0
	local sdkFinds, sdkWaits, profileCpuWaits = 0, 0, 0
	local sdkResolvedAfterWait = false
	local preSimulationConnects, preSimulationDisconnects = 0, 0
	local cpuCaptureActive, preSimulationCallback, inPreSimulation = false, nil, false
	local profileDepth, profileMarker, profileEvents = 0, nil, {}
	local latestCpuReport, latestCpuSnapshot
	sdkAvailable = sdkAvailable == true
	cpuEnabled, delayedSdk = cpuEnabled == true, delayedSdk == true
	local recorder = { enabled = enabled }
	function recorder.setCpuMarker(_marker) end
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
	local selected = Model.selection(config)
	local messages = selected.messagesPerFrame
	local fixedCpuToken = "quick-cpu-fixture-token"
	local function expectedCpuMarker(ordinal)
		return `RelayQuickCPU/{fixedCpuToken}/{ordinal}`
	end
	local sdkLibrary, sdkModule = {}, {}
	local cpuProfile = { new = function(value)
		cpuNewCalls += 1
		assert(sdkAvailable and value == sdkLibrary, "CPU capture must load the attached pinned SDK")
		local capture = {}
		function capture:begin()
			assert(not cpuCaptureActive)
			cpuCaptureActive = true
			cpuBegins += 1
		end
		function capture:finish(marker, _stagePrefix, pauseCapture)
			local ordinal = cpuFinishes + 1
			assert(cpuCaptureActive and marker == expectedCpuMarker(ordinal),
				"CPU capture must finish its unique measured marker")
			assert(pauseCapture == false, "sender snapshots must leave the shared receiver capture active")
			cpuCaptureActive = false
			cpuFinishes += 1
			latestCpuReport = { index = cpuFinishes, marker = marker }
			latestCpuSnapshot = `snapshot-{cpuFinishes}`
			return latestCpuReport
		end
		function capture:latestSnapshot() return latestCpuSnapshot end
		function capture:close() cpuCaptureActive = false end
		return capture
	end, render = function(report) return "CPU report " .. (report.side or "unknown") end }
	local transports = { ["native-reliable"] = { id = "native-reliable" } }
	function transports:FindFirstChild(id) return self[id] end
	local factory = {
		constructClient = function(value)
			context = value
			-- Generated adapter instrumentation wraps its callback binding before
			-- invoking the Session sink; the sink itself stays unwrapped.
			if enabled then value.sink = recorder.wrap("native-reliable", value.sink) end
			local side = { setup = function() end, ready = function() return true end, teardown = function() end }
			if selected.direction == "ClientToServer" then
				side.submit = function(input)
					assert(type(input) == "table")
					submits += 1
					if cpuCaptureActive then
						assert(inPreSimulation and profileDepth == 1
							and profileMarker == expectedCpuMarker(cpuBegins),
							"measured factory submits must run inside their CPU profile scope")
						cpuScopedSubmits += 1
					else
						assert(profileDepth == 0, "warmup submits must remain outside CPU capture scopes")
					end
					return true
				end
			end
			return side
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
			if selected.direction == "ServerToClient" then
				for _, fixture in batch do context.sink({ kind = "Record", value = fixture.input }, {}) end
			end
			stage = "Drain"
		elseif command == "Drain" then
			stage = "Finish"
		elseif command == "Finish" then
			stage = if phaseNumber == Model.roundCount(1) * 2 then "Complete" else "Begin"
			return {
				sent = messages, elapsed = 1, calls = { mean = 1, median = 1, p95 = 1 },
				floor = { mean = 0.1 }, frames = { mean = 1, p95 = 1 }, rtt = nil,
				kbps = 1, messagesPerFrame = 1, deliveryConfirmation = 1, acknowledgementTail = 0,
				receiveCallbackSamples = table.create(messages, 0.000004),
				receiverCpuCapture = if cpuEnabled then { side = "server", captureOrdinal = phaseNumber / 2 } else nil,
			}
		elseif command == "Complete" then
			stage = "Start"
			return true
		end
		return true
	end }
	local coreCases = { Value = "" }
	local profileCpu = { Value = cpuEnabled }
	local sdkReady = sdkAvailable and not delayedSdk
	local quick = { Parent = benchmark, Config = config, Model = Model, CallbackTiming = recorder,
		CpuProfile = cpuProfile, QuickCoreCases = coreCases, ProfileCpu = profileCpu }
	function quick:WaitForChild(name, timeout)
		assert(timeout == config.timeoutSeconds, "optional LibMP modules use the bounded replication wait")
		if name == "QuickCoreCases" then return coreCases end
		if name == "ProfileCpu" then
			profileCpuWaits += 1
			return profileCpu
		end
		assert(name == "LibMPSdk" and cpuEnabled, "only an opted-in capture may wait for LibMPSdk")
		sdkWaits += 1
		if not sdkAvailable then return nil end
		if delayedSdk then sdkResolvedAfterWait = true end
		sdkReady = true
		return sdkModule
	end
	function quick:FindFirstChild(name)
		if name == "QuickCoreCases" then return coreCases end
		if name == "ProfileCpu" then return profileCpu end
		assert(name == "LibMPSdk")
		sdkFinds += 1
		return if sdkReady then sdkModule else nil
	end
	local runService = {
		IsServer = function() return false end, IsStudio = function() return true end,
		PostSimulation = { Wait = function() now += 0.05 end },
		PreSimulation = { Connect = function(_, callback)
			assert(preSimulationCallback == nil)
			preSimulationConnects += 1
			preSimulationCallback = callback
			return { Disconnect = function()
				assert(preSimulationCallback == callback)
				preSimulationCallback = nil
				preSimulationDisconnects += 1
			end }
		end },
		Heartbeat = { Wait = function()
			now += 0.01
			if preSimulationCallback then
				inPreSimulation = true
				local ok, reason = pcall(preSimulationCallback)
				inPreSimulation = false
				assert(ok, reason)
			end
		end },
	}
	local debugApi = {
		profilebegin = function(marker)
			assert(profileDepth == 0 and type(marker) == "string"
				and marker == expectedCpuMarker(cpuBegins),
				"profile scope must use the current capture's unique marker")
			profileDepth, profileMarker = 1, marker
			table.insert(profileEvents, "begin:" .. marker)
		end,
		profileend = function()
			assert(profileDepth == 1 and cpuCaptureActive)
			table.insert(profileEvents, "end:" .. profileMarker)
			profileDepth, profileMarker = 0, nil
		end,
	}
	local services = {
		RunService = runService,
		HttpService = { GenerateGUID = function(_, wrapInBraces)
			assert(wrapInBraces == false)
			guidCalls += 1
			return fixedCpuToken
		end },
		Players = {}, ReplicatedStorage = {}, Stats = { DataSendKbps = 1 },
	}
	local loadOk, loaded = pcall(function()
		return luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
		game = { GetService = function(_, name) return services[name] end }, script = { Parent = quick },
		require = function(value)
			if value == sdkModule then return sdkLibrary end
			return value
		end,
		os = { clock = function() now += 0.000001; return now end },
		debug = debugApi,
		task = { spawn = function(callback) callback(); return coroutine.create(function() end) end },
		print = function(message) table.insert(output, message) end,
		warn = function(message) table.insert(profileWarnings, message) end,
		} })()
	end)
	if cpuEnabled and not sdkAvailable then
		assert(not loadOk and sdkWaits == 1 and profileCpuWaits == 1
			and guidCalls == 0 and string.find(tostring(loaded), "LibMP SDK did not replicate", 1, true),
			"explicit CPU profiling must fail when the pinned SDK is missing")
		return
	end
	assert(loadOk, loaded)
	local session = loaded
	local rows = session.run()
	local expectedProfile = if cpuNewCalls > 0 then "receive-callback+libmp-cpu"
		else if enabled then "receive-callback" else "unprofiled"
	assert(rows[1].profile == expectedProfile)
	assert(rows[1].sent == Model.roundCount(1) * messages and #rows[1].rounds == Model.roundCount(1) and stage == "Start",
		"steady and burst runs must complete every phase before returning")
	assert(session.getCpuReport() == latestCpuReport and session.getCpuSnapshot() == latestCpuSnapshot,
		"Session CPU getters must expose the most recent capture")
	if cpuNewCalls > 0 then
		local rounds = Model.roundCount(1)
		assert(cpuNewCalls == 1 and cpuBegins == rounds and cpuFinishes == rounds and guidCalls == 1,
			"an opted-in session must create exactly one CPU marker token")
		assert(submits == rounds * messages * 2 and cpuScopedSubmits == rounds * messages,
			"only measured factory submits run while LibMP capture is active")
		assert(preSimulationConnects == rounds and preSimulationDisconnects == rounds
			and preSimulationCallback == nil and profileDepth == 0)
		assert(#profileEvents == rounds * 2, "each measured phase must contain one balanced profile scope")
		for index = 1, rounds do
			local report = rows[1].rounds[index].cpuCapture
			assert(report.index == index and report.marker == expectedCpuMarker(index)
				and report.caseId == selected.id and report.adapterId == "native-reliable"
				and report.captureOrdinal == index and report.side == "client"
				and rows[1].rounds[index].receiverCpuCapture.captureOrdinal == index,
				"each measured round must retain its exact CPU capture report")
			assert(rows[1].rounds[index].deliveryConfirmation == nil
				and rows[1].rounds[index].acknowledgementTail == nil,
				"CPU capture rounds must omit confirmation timing that includes the diagnostic drain delay")
			assert(profileEvents[index * 2 - 1] == "begin:" .. expectedCpuMarker(index)
				and profileEvents[index * 2] == "end:" .. expectedCpuMarker(index)
				and (index == 1 or rows[1].rounds[index - 1].cpuCapture.marker ~= report.marker),
				"every measured capture must use a distinct, balanced marker")
		end
		assert(latestCpuReport == rows[1].rounds[rounds].cpuCapture
			and latestCpuSnapshot == `snapshot-{rounds}`)
	elseif enabled and selected.direction == "ServerToClient" then
		assert(begins == 6 and finishes == 6 and wraps == 1)
		for _, round in rows[1].rounds do
			assert(#round.receiveCallbackSamples == messages and round.sent == messages,
				"profile callback counts must match every measured burst")
		end
		assert(math.abs(rows[1].rounds[1].receiveCallbacks.median - 0.000006) < 1e-12)
		assert(string.find(table.concat(output, "\n"), "receive callback mean", 1, true))
	elseif enabled then
		assert(begins == 0 and finishes == 0 and wraps == 1,
			"client-to-server callback profiles use server samples")
		assert(sdkWaits == 0 and sdkFinds == 0 and cpuNewCalls == 0 and session.getCpuReport() == nil
			and session.getCpuSnapshot() == nil, "missing SDK must skip CPU initialization")
	else
		assert(cpuNewCalls == 0 and sdkFinds == 0 and sdkWaits == 0,
			"disabled receive profiling must skip CPU initialization")
	end
	if cpuEnabled and sdkAvailable then
		assert(profileCpuWaits == 1 and sdkWaits == 1 and sdkFinds == 0
			and (not delayedSdk or sdkResolvedAfterWait),
			"an opted-in capture must resolve the pinned SDK through bounded WaitForChild")
	elseif not cpuEnabled then
		assert(sdkWaits == 0 and guidCalls == 0, "a disabled CPU flag must ignore a sibling SDK")
	end
	if enabled then
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
callbackProfile(false, "state-burst-c2s", true)
callbackProfile(true, "state-burst-c2s", false)
callbackProfile(true, "state-burst-c2s", true, false)
callbackProfile(true, "state-burst-c2s", false, true)
callbackProfile(true, "state-burst-c2s", true, true, true)

-- Load the real server state machine as well: client-side mocks alone cannot
-- prove that Drain, round rotation, and yielding aborts are accepted correctly.
local function quickServer(caseId, profiled, coreCategories, cpuEnabled, cpuCloseOutcome)
	local now, remote, waitHook = 0, nil, nil
	local function clock() now += 0.000001; return now end
	local removing, teardowns = nil, 0
	local attributes, contexts, warnings = {}, {}, {}
	local profileBegins, profileFinishes = 0, 0
	local deferred = {}
	local cpuBegins, cpuFinishes, cpuCloses, cpuActive = 0, 0, 0, false
	local config = table.clone(Config)
	config.caseId, config.warmupFrames, config.measuredFrames = caseId, 1, 2
	local coreValue = if coreCategories then { Value = table.concat(coreCategories, ",") } else nil
	local adapterCount = if coreCategories then 1 else if Model.selection(config).schema then 1 else 2
	local callbackTiming = DisabledCallbackTiming
	if profiled then
		local profileParent = { ProfileReceive = { Value = true } }
		function profileParent:FindFirstChild(name) return self[name] end
		local recorder = luau.load(fs.readFile("benchmarks/quick/CallbackTiming.luau"), { environment = {
			script = { Parent = profileParent },
			os = { clock = clock },
			debug = { profilebegin = function() end, profileend = function() end },
		} })()
		local expectedCount
		callbackTiming = {
			enabled = recorder.enabled,
			setCpuMarker = recorder.setCpuMarker,
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
	local quick = { Parent = benchmark, Config = config, Model = Model, SchemaRelay = factory,
		CoreAdapters = factory, CallbackTiming = callbackTiming,
		ProfileCpu = { Value = cpuEnabled == true },
		LibMPSdk = {},
		CpuProfile = { new = function()
			return {
				begin = function() assert(not cpuActive); cpuActive = true; cpuBegins += 1 end,
				finish = function(_, marker, prefix)
					assert(cpuActive and string.sub(marker, -3) == "/rt")
					cpuActive = false; cpuFinishes += 1
					return { exactMarker = marker, prefix = prefix or string.sub(marker, 1, -4), index = cpuFinishes }
				end,
				latestSnapshot = function() return cpuFinishes end,
				close = function()
					cpuCloses += 1
					if cpuCloseOutcome == "throw" then error("cpu-close-threw") end
					if cpuCloseOutcome == "false" then return false, "cpu-close-failed" end
					cpuActive = false
					return true, nil
				end,
			}
		end },
		FindFirstChild = function(self, name)
			if name == "QuickCoreCases" then return coreValue end
			if name == "ProfileCpu" then return self.ProfileCpu end
			if name == "LibMPSdk" then return self.LibMPSdk end
			return nil
		end }
	local event = { Connect = function() return {} end }
	local services = {
		RunService = { IsServer = function() return true end, IsStudio = function() return true end,
			Heartbeat = { Wait = function() now += 0.01 end },
			PostSimulation = { Wait = function()
				now += 0.05
				if waitHook then local callback = waitHook; waitHook = nil; callback() end
			end } },
		Players = { GetPlayers = function() return { player } end, PlayerAdded = event,
			PlayerRemoving = { Connect = function(_, callback) removing = callback; return {} end } },
		ReplicatedStorage = {}, Stats = { DataSendKbps = 12.5 },
		HttpService = { GenerateGUID = function() return "server-fixture-token" end },
	}
	local session = luau.load(fs.readFile("benchmarks/quick/Session.luau"), { environment = {
		game = { GetService = function(_, name) return services[name] end },
		script = { Parent = quick },
		require = function(value) return value end, os = { clock = clock },
		Instance = { new = function(class)
			local instance = { SetAttribute = function() end }
			if class == "RemoteFunction" then remote = instance end
			return instance
		end },
		warn = function(message) table.insert(warnings, message) end,
		task = { defer = function(callback) deferred[#deferred + 1] = callback end },
	} })()
	session.serve()
	assert(attributes.QuickStatus == "Ready")
	return {
		invoke = function(command, ...) return remote.OnServerInvoke(player, command, ...) end,
		deliver = function(id, batch, payloadId, sender)
			if profiled then assert(callbackTiming.isActive(), "profile phase must start before server delivery") end
			for _, fixture in batch do contexts[id].sink({ kind = "Record", value = fixture.input },
				{ sender = sender or player, payloadId = payloadId }) end
			for _, callback in deferred do callback() end
			table.clear(deferred)
		end,
		deliverRawNoop = function(id)
			callbackTiming.wrap(id, function() end)()
		end,
		batches = function(run) return Model.runBatches(config, Model.selection(config), run, adapterCount) end,
		caseBatches = function(caseId, run)
			local selectedConfig = table.clone(config)
			selectedConfig.caseId = caseId
			return Model.runBatches(config, Model.selection(selectedConfig), run, adapterCount)
		end,
		onWait = function(callback) waitHook = callback end,
		advance = function(seconds) now += seconds end,
		leave = function() removing(player) end,
		teardowns = function() return teardowns end,
		attributes = attributes, warnings = warnings, adapterCount = adapterCount,
		profile = if profiled then callbackTiming else nil,
		cpuCounts = function() return cpuBegins, cpuFinishes end,
		cpuCloseCount = function() return cpuCloses end,
		cpuReport = session.getCpuReport,
		deliverExtra = function(id, fixture, payloadId, sender)
			contexts[id].sink({ kind = "Record", value = fixture.input },
				{ sender = sender or player, payloadId = payloadId })
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
	if server.profile then assert(server.profile.finishCount() == run * Model.roundCount(server.adapterCount) * server.adapterCount * 2) end
	return lastId, lastBatch
end
local function finishCoreCategory(server, run, caseId)
	local selectedConfig = table.clone(Config)
	selectedConfig.caseId = caseId
	local selected = Model.selection(selectedConfig)
	local batches = server.caseBatches(caseId, run)
	local lastBatch
	for _, phases in batches do
		for _, batch in phases do
			assert(server.invoke("Begin") == true)
			server.onWait(function() server.deliver("relay-reliable", batch, selected.payloadId) end)
			assert(server.invoke("Drain") == true)
			assert(server.invoke("Finish") == true)
			lastBatch = batch
		end
	end
	return lastBatch, selected.payloadId
end

local cpuServer = quickServer("state-burst-c2s", true, nil, true)
finishServerRounds(cpuServer, 1)
local cpuStarted, cpuFinished = cpuServer.cpuCounts()
assert(cpuStarted == Model.roundCount(cpuServer.adapterCount) * cpuServer.adapterCount
	and cpuFinished == cpuStarted and cpuServer.invoke("Complete") == true,
	"server CPU capture must run once per measured phase, never during warmup")
local receiverReport = cpuServer.cpuReport()
assert(receiverReport.side == "server" and receiverReport.caseId == "state-burst-c2s"
	and receiverReport.captureOrdinal == cpuFinished
	and receiverReport.exactMarker == receiverReport.prefix .. "/rt",
	"the receiver retains its own exact phase marker and workload metadata")
assert(cpuServer.cpuCloseCount() == 0, "Complete must leave the server CPU profiler open")
cpuServer.leave()
assert(cpuServer.attributes.QuickStatus == "Closed" and cpuServer.cpuCloseCount() == 1
	and cpuServer.teardowns() == cpuServer.adapterCount,
	"normal completed server departure must close the CPU profiler before teardown")

for _, closeOutcome in { "false", "throw" } do
	local failedCpuServer = quickServer("state-burst-c2s", true, nil, true, closeOutcome)
	finishServerRounds(failedCpuServer, 1)
	assert(failedCpuServer.invoke("Complete") == true)
	failedCpuServer.leave()
	local expectedFailure = if closeOutcome == "false" then "cpu-close-failed" else "cpu-close-threw"
	assert(failedCpuServer.attributes.QuickStatus == "Failed"
		and string.find(failedCpuServer.attributes.QuickFailure, expectedFailure, 1, true) ~= nil
		and failedCpuServer.teardowns() == failedCpuServer.adapterCount,
		"CPU profiler close failures must fail and tear down the completed server session")
end

local function finishCoreSuite(server, run, cases)
	assert(server.invoke("Start") == run)
	local lastBatch, lastPayloadId
	for index, caseId in cases do
		lastBatch, lastPayloadId = finishCoreCategory(server, run, caseId)
		if index < #cases then
			assert(server.invoke("NextCase") == cases[index + 1], "NextCase must select only the next declared category")
		end
	end
	return lastBatch, lastPayloadId
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

local earlyCore = quickServer("state-burst-c2s", false, coreCaseIds)
assert(earlyCore.invoke("Start") == 1 and earlyCore.invoke("NextCase") == false
	and earlyCore.attributes.QuickStatus == "Failed", "NextCase before a verified category must fail")
local extraCore = quickServer("state-burst-c2s", false, coreCaseIds)
assert(extraCore.invoke("Start") == 1 and extraCore.invoke("NextCase", nil) == false
	and extraCore.attributes.QuickStatus == "Failed", "NextCase rejects extra control arguments")
local coreServer = quickServer("state-burst-c2s", false, coreCaseIds)
local finalCoreBatch = finishCoreSuite(coreServer, 1, coreCaseIds)
assert(coreServer.invoke("Complete") == true and coreServer.attributes.QuickStatus == "Complete",
	"Complete is accepted only after the final declared category")
coreServer.leave()
assert(coreServer.attributes.QuickStatus == "Closed" and coreServer.teardowns() == 1)
local finalNext = quickServer("state-burst-c2s", false, coreCaseIds)
finishCoreSuite(finalNext, 1, coreCaseIds)
assert(finalNext.invoke("NextCase") == false and finalNext.attributes.QuickStatus == "Failed",
	"NextCase after the final category must fail")

local lateCore = quickServer("state-burst-c2s", false, coreCaseIds)
assert(lateCore.invoke("Start") == 1)
local priorBatch, priorPayloadId = finishCoreCategory(lateCore, 1, coreCaseIds[1])
assert(lateCore.invoke("NextCase") == coreCaseIds[2])
lateCore.deliver("relay-reliable", { priorBatch[1] }, priorPayloadId)
assert(lateCore.attributes.QuickStatus == "Failed" and #lateCore.warnings == 1,
	"a prior category callback after NextCase must invalidate the full suite before capture")

local wrongSenderCore = quickServer("state-burst-c2s", false, coreCaseIds)
assert(wrongSenderCore.invoke("Start") == 1 and wrongSenderCore.invoke("Begin") == true)
local firstCoreBatch = wrongSenderCore.caseBatches(coreCaseIds[1], 1)[1][1]
wrongSenderCore.deliver("relay-reliable", firstCoreBatch, "tiny", {})
assert(wrongSenderCore.attributes.QuickStatus == "Failed" and #wrongSenderCore.warnings == 1,
	"core categories must retain authenticated sender checks")

local profiledServer = quickServer("tiny-steady-c2s", true)
local lastProfiledId, lastProfiledBatch = finishServerRounds(profiledServer, 1)
profiledServer.deliverExtra(lastProfiledId, lastProfiledBatch[1])
assert(profiledServer.attributes.QuickStatus == "Failed" and #profiledServer.warnings == 1,
	"a callback after the final profile Finish must invalidate the run")

local burstProfile = quickServer("state-burst-c2s", true)
finishServerRounds(burstProfile, 1)
assert(burstProfile.invoke("Complete") == true, "default C2S burst profile must complete every sample")

local compositeProfileServer = quickServer("schema-composite-c2s", true)
local compositeProfileId, compositeProfileBatch
for run = 1, 2 do
	compositeProfileId, compositeProfileBatch = finishServerRounds(compositeProfileServer, run)
	assert(compositeProfileServer.invoke("Complete") == true, "RR3 C2S profile must complete every sample")
end
compositeProfileServer.leave()
assert(compositeProfileServer.teardowns() == 1 and compositeProfileServer.attributes.QuickStatus == "Closed")
compositeProfileServer.deliverExtra(compositeProfileId, compositeProfileBatch[1])
assert(compositeProfileServer.attributes.QuickStatus == "Failed" and #compositeProfileServer.warnings == 1,
	"a callback after completed RR3 profile runs must invalidate their results")

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
