--!strict

-- Untimed proof for the fixed, reliable quick-core channels. Vendor source is
-- pinned and loaded by ExternalLibraryWorld; it is not modified for testing.
local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local Acquisition = require("../../scripts/acquire-benchmark-libraries")
local GeneratedAdapters = require("../host/GeneratedAdapters")
local Fixtures = require("../fixtures/event-v1")
local SchemaFixtures = require("../quick/SchemaFixtures")
local Comparator = require("../correctness/PayloadComparator")
local World = require("./support/ExternalLibraryWorld")

local LIBRARIES = {
	"native-reliable", "relay-reliable", "quicknet", "bytenet", "satset", "warp", "blink", "zap", "netray-compile",
}
local CHANNELS = { "tiny", "schema-string", "schema-signed", "schema-vector3", "state" }
local NAMES = {
	tiny = { "sequence", "enabled" },
	["schema-string"] = { "sequence", "text" },
	["schema-signed"] = { "sequence", "small", "medium", "large" },
	["schema-vector3"] = { "sequence", "position" },
	state = { "sequence", "entityId", "position", "yaw", "health" },
}
local function expectedPayload(payloadId: string, sequence: number): any
	if payloadId == "tiny" then
		local row = Fixtures.generate("tiny-steady-c2s", 1).warmup[sequence + 1]
		return table.clone(row.expected)
	elseif payloadId == "state" then
		local row = Fixtures.generate("state-steady-c2s", 1).warmup[sequence + 1]
		return table.clone(row.expected)
	end
	return SchemaFixtures.generate(payloadId, sequence)
end

local function matches(payloadId: string, expected: any, actual: any): boolean
	if payloadId == "tiny" or payloadId == "state" then
		local ok = Comparator.compareRecord(payloadId, expected, actual)
		return ok
	end
	return SchemaFixtures.compare(payloadId, expected, actual, true)
end

local function fieldNames(payloadId: string): { string }
	if payloadId == "tiny" or payloadId == "state" then return NAMES[payloadId] end
	local names = {}
	for _, field in SchemaFixtures.fields[payloadId] do table.insert(names, field.name) end
	return names
end

local function normalize(payloadId: string, delivery: any): any
	if delivery.kind == "Record" then return delivery.value end
	assert(delivery.kind == "Positional", "core adapter returned an unknown envelope")
	local names = fieldNames(payloadId)
	assert(delivery.count == #names, "core adapter positional arity mismatch")
	local value = {}
	for index, name in names do value[name] = delivery.values[index] end
	return value
end

local function contextFor(world: any, root: any, selection: any, received: { any }): any
	return {
		resourceRoot = root,
		selection = selection,
		recipients = world.players,
		activePayloadId = function() return selection.payloadId end,
		envelopes = {
			record = function(value) return { kind = "Record", value = value } end,
			positional = function(...)
				local count = select("#", ...)
				local values = {}
				for index = 1, count do values[index] = select(index, ...) end
				return { kind = "Positional", values = values, count = count }
			end,
		},
		sink = function(delivery, metadata)
			table.insert(received, { delivery = delivery, metadata = metadata })
		end,
	}
end

local function verifyGeneratedIds()
	local blinkServer = fs.readFile("benchmarks/generated/blink/Server.luau")
	local blinkClient = fs.readFile("benchmarks/generated/blink/Client.luau")
	local function assertBlinkAssociation(source: string, index: number, event: string)
		local marker = "Index == " .. index .. " then"
		local start = string.find(source, marker, 1, true)
		assert(start ~= nil, "Blink event ID missing: " .. marker)
		local nextBranch = string.find(source, "elseif Index == ", start + #marker, true)
		local branch = string.sub(source, start, if nextBranch then nextBranch - 1 else #source)
		assert(string.find(branch, "ReadEVENT_" .. event, 1, true) ~= nil,
			"Blink event ID maps to the wrong event: " .. tostring(index) .. " / " .. event)
	end
	for _, pair in { { 0, "TinyC2S" }, { 2, "StateC2S" }, { 4, "StringsC2S" },
		{ 5, "NumbersC2S" }, { 6, "VectorsC2S" } } do assertBlinkAssociation(blinkServer, pair[1], pair[2]) end
	for _, pair in { { 1, "TinyS2C" }, { 3, "StateS2C" } } do assertBlinkAssociation(blinkClient, pair[1], pair[2]) end

	local zapServer = fs.readFile("benchmarks/generated/zap/Server.luau")
	local zapClient = fs.readFile("benchmarks/generated/zap/Client.luau")
	for _, marker in {
		"id == 0 then -- TinyC2S", "id == 1 then -- StateC2S", "id == 2 then -- StringsC2S",
		"id == 3 then -- NumbersC2S", "id == 4 then -- VectorsC2S",
		"id == 0 then -- TinyS2C", "id == 1 then -- StateS2C",
	} do
		local source = if string.find(marker, "C2S", 1, true) then zapServer else zapClient
		assert(string.find(source, marker, 1, true) ~= nil, "Zap generated event ID regression: " .. marker)
	end

	for _, side in { "Server", "Client" } do
		local netray = fs.readFile("benchmarks/generated/netray-compile/" .. side .. ".luau")
		for _, marker in {
			"MESSAGE_ID_Net_Tiny_reliable_1 = 1", "MESSAGE_ID_Net_State_reliable_2 = 2",
			"MESSAGE_ID_Net_Strings_reliable_3 = 3", "MESSAGE_ID_Net_Numbers_reliable_4 = 4",
			"MESSAGE_ID_Net_Vectors_reliable_5 = 5",
		} do assert(string.find(netray, marker, 1, true) ~= nil, "NetRay generated event ID regression: " .. marker) end
	end
end

local function verifyLibrary(id: string, libraryById: any, verified: { [string]: boolean })
	local runtimeId = if id == "native-reliable" or id == "relay-reliable" then "quicknet" else id
	if verified[runtimeId] then return end
	local library = libraryById[runtimeId]
	assert(library ~= nil, "missing pinned library metadata: " .. runtimeId)
	Acquisition.verifyInstalled(library)
	if library.kind == "CodegenTool" then GeneratedAdapters.verifyGenerated(runtimeId) end
	verified[runtimeId] = true
end

local function runLibrary(id: string, libraryById: any, verified: { [string]: boolean })
	verifyLibrary(id, libraryById, verified)
	local runtimeId = if id == "native-reliable" or id == "relay-reliable" then "quicknet" else id
	local world = World.new(1, runtimeId)
	local root = world.quickAdapterRoot(id, "Server")
	root:SetAttribute("QuickCore", true)
	local selection = { kind = "Workload", payloadId = "tiny", schema = false, direction = "ClientToServer" }
	local received = {}
	local serverFactory = world.loadAdapter("benchmarks/quick/CoreAdapters.luau", "Server")
	local server = serverFactory.constructServer(contextFor(world, root, selection, received))
	server.setup()

	if id == "warp" then
		world.prepare("Server")
		world.prepare("Client", 1)
	end
	local clientRoot = world.quickAdapterRoot(id, "Client", 1)
	local clientFactory = world.loadAdapter("benchmarks/quick/CoreAdapters.luau", "Client", 1)
	local client = clientFactory.constructClient(contextFor(world, clientRoot, selection, received))
	client.setup()
	assert(server.ready(), id .. " server endpoints not ready")
	assert(client.ready(), id .. " client endpoints not ready")

	for index, payloadId in CHANNELS do
		selection.payloadId = payloadId
		selection.schema = payloadId ~= "tiny" and payloadId ~= "state"
		local input = expectedPayload(payloadId, index + 10)
		local before = table.clone(input)
		client.submit(input, "FlushBeforeReturn")
		for _ = 1, 120 do
			if #received >= index then break end
			world.step()
		end
		assert(#received == index, id .. " delivery count/order mismatch for " .. payloadId)
		local row = received[index]
		assert(row.metadata.kind == "ClientToServer" and row.metadata.sender == world.players[1],
			id .. " did not preserve the authenticated sender")
		assert(row.metadata.payloadId == payloadId, id .. " reported the wrong immutable channel identity")
		assert(matches(payloadId, input, normalize(payloadId, row.delivery)), id .. " changed " .. payloadId .. " payload")
		assert(matches(payloadId, before, input), id .. " mutated the submitted " .. payloadId .. " input")
	end
	for _ = 1, 3 do world.step() end
	assert(#received == #CHANNELS, id .. " delivered an extra core payload")
	client.teardown()
	server.teardown()
	local beforeTeardown = #received
	for _ = 1, 3 do world.step() end
	assert(#received == beforeTeardown, id .. " delivered after teardown")
	print("PASS " .. id .. " quick core channels")
end

local function verifyRelayGuardrails()
	local Definition = require("../../src/Definition")
	local Runtime = require("../../tests/support/ServerRuntime")
	local world = World.new(1, "quicknet")
	local root = world.quickAdapterRoot("relay-reliable", "Server")
	root:SetAttribute("QuickCore", true)
	local factory = world.loadAdapter("benchmarks/quick/CoreAdapters.luau", "Server")
	local definition = assert(Definition.define(factory.relayDefinitionSpecForTests()))
	local function run(perPlayerCapacity: number, aggregateCapacity: number, expectedRate: string)
		local runtime = Runtime.new()
		local players = {}
		local playerCount = if expectedRate == "aggregateRate" then 3 else 1
		for _ = 1, playerCount do table.insert(players, runtime:addPlayer()) end
		local acceptedPlayer = if expectedRate == "aggregateRate" then players[3] else players[1]
		local session, issue = runtime.server.create(definition, { inboundRate = {
			perPlayer = { capacity = perPlayerCapacity, refillPerSecond = 1 },
			aggregate = { capacity = aggregateCapacity, refillPerSecond = 1 },
		} })
		assert(session ~= nil, "guard runtime session create failed: " .. tostring(issue and issue.code))
		local handled = 0
		assert(session.events.Strings:Connect(function(sender, sequence, text)
			assert(sender == acceptedPlayer and sequence == 7 and #text == 64)
			handled += 1
		end))
		assert(session:Start())
		local remote = runtime:remote()
		local invalidCount = 0
		local function rejectMalformed(player)
			remote.OnServerEvent:Fire(player, 2, 7, 123)
			remote.OnServerEvent:Fire(player, 2, 7, string.rep("x", 65))
			invalidCount += 2
		end
		if expectedRate == "aggregateRate" then
			rejectMalformed(players[1])
			rejectMalformed(players[2])
		else
			rejectMalformed(players[1])
		end
		local counters = session:GetDiagnostics().counters
		assert(counters.invalidPayload == invalidCount and handled == 0 and counters.dispatched == 0,
			"Relay accepted malformed or over-limit string data")
		remote.OnServerEvent:Fire(acceptedPlayer, 2, 7, string.rep("y", 64))
		counters = session:GetDiagnostics().counters
		if expectedRate == "perPlayerRate" then
			assert(counters.invalidPayload == invalidCount and counters.perPlayerRate == 1 and counters.aggregateRate == 0
				and handled == 0 and counters.dispatched == 0,
				"malformed Relay payloads did not charge the per-player bucket")
		elseif expectedRate == "aggregateRate" then
			assert(counters.invalidPayload == invalidCount and counters.perPlayerRate == 0 and counters.aggregateRate == 1
				and handled == 0 and counters.dispatched == 0,
				"malformed Relay payloads did not charge the aggregate bucket")
		else
			assert(counters.invalidPayload == invalidCount and counters.perPlayerRate == 0 and counters.aggregateRate == 0
				and handled == 1 and counters.dispatched == 1,
				"Relay rejected an exact 64-byte string boundary payload")
		end
		session:Destroy()
	end
	run(2, 8, "perPlayerRate")
	run(2, 4, "aggregateRate")
	run(8, 8, "boundary")
	print("PASS Relay quick-core string validation and admission charging")
end

local requested = process.args[1] or "all"
assert(#process.args <= 1, "usage: quick-core-adapters [all|library-id]")
local selected = {}
if requested == "all" then
	selected = table.clone(LIBRARIES)
else
	assert(table.find(LIBRARIES, requested) ~= nil, "unknown quick core adapter: " .. requested)
	selected = { requested }
end

luau.compile(fs.readFile("benchmarks/quick/CoreAdapters.luau"))
local lock = Acquisition.validateLock(serde.decode("json", fs.readFile("benchmarks/libraries.lock.json")))
local libraryById = {}
for _, library in lock.libraries do libraryById[library.id] = library end
if requested == "all" or requested == "blink" or requested == "zap" or requested == "netray-compile" then
	verifyGeneratedIds()
end
local verified = {}
for _, id in selected do runLibrary(id, libraryById, verified) end
verifyRelayGuardrails()
print("PASS focused quick-core adapter proof")
