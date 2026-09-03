--!strict

-- Untimed qualification: unmodified library serializers and decoders, simulated
-- engine transport. This is not Studio timing, a Result V1, or a vendor identity.
local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Acquisition = require("../../scripts/acquire-benchmark-libraries")
local AdapterContract = require("../adapters/AdapterContract")
local EventV1 = require("../contracts/event-v1")
local Fixtures = require("../fixtures/event-v1")
local Comparator = require("../correctness/PayloadComparator")
local World = require("./support/ExternalLibraryWorld")

local id = process.args[1] or "quicknet"
local repetitions = if process.args[2] == nil then 30 else tonumber(process.args[2])
assert(repetitions == 1 or repetitions == 30, "qualification repetitions must be 1 or 30")
assert(#process.args <= 2, "usage: external-library-payloads <library-id> [1|30]")
local lock = Acquisition.validateLock(serde.decode("json", fs.readFile("benchmarks/libraries.lock.json")))
local selectedLibrary
for _, library in lock.libraries do
	if library.id == id then selectedLibrary = library; break end
end
assert(selectedLibrary ~= nil, "unknown qualification library")
Acquisition.verifyInstalled(selectedLibrary)
if selectedLibrary.kind == "CodegenTool" then
	require("../host/GeneratedAdapters").verifyGenerated(id)
end
local identity = {
	id = "external-payload-test", displayName = "External payload test", lane = "NativeBest",
	integrationKind = "Runtime",
	library = {
		id = "test-harness", displayName = "Test harness", version = "1",
		provenance = { kind = "Repository", sourceRepository = "https://example.com/test-harness",
			revision = string.rep("a", 40), checksum = "sha256:" .. string.rep("b", 64), license = "MIT" },
	},
	semantics = { broadcastMode = "NativeBroadcast", intentionalAddedDeliveryFrames = 1,
		repetitionIsolation = "ProcessRestart" },
	capabilities = { directions = { "ClientToServer", "ServerToClient" },
		deliverySemantics = { "ReliableOrdered" }, payloadIds = { "state", "tiny" } },
}

local total = 0
local function runCase(selection: any, count: number, repetition: number)
	-- Every repetition has fresh per-side module caches, queues, and engine services.
	local world = World.new(count, id)
	local preflight = AdapterContract.preflight(identity, selection, "test")
	assert(preflight.kind == "Supported")
	if world.prepare ~= nil then
		world.prepare("Server")
		for clientIndex = 1, count do world.prepare("Client", clientIndex) end
	end
	local probe = selection.kind == "SeparateProbe"
	local fixture = if probe then Fixtures.generateProbe(selection.probeId, repetition)
		else Fixtures.generate(selection.workloadId, repetition)
	local expected = {}
	for _, sample in fixture.warmup do table.insert(expected, sample) end
	for _, sample in fixture.measured do table.insert(expected, sample) end
	local broadcast = not probe and preflight.selection.direction == "ServerToClient"
	local received = table.create(count + 1, 0)
	local failures = {}
	local inputs = {}
	local responseInputs = {}
	local server: any

	local function observe(slot: number, envelope: any, metadata: any)
		local index = received[slot] + 1
		local sample = expected[index]
		if sample == nil then table.insert(failures, "extra delivery"); return end
		local ok, mismatch
		if envelope.kind == "Record" then
			ok, mismatch = Comparator.compareRecord(sample.payloadId, sample.expected, envelope.value)
		else
			ok, mismatch = Comparator.compareCapturedPositional(sample.payloadId, sample.expected,
				envelope.values, envelope.count)
		end
		if not ok then table.insert(failures, `payload {index}: {mismatch.path}/{mismatch.reason}`) end
		if slot == 1 then
			if metadata.kind ~= "ClientToServer" or metadata.sender ~= world.players[1] then
				table.insert(failures, "unauthenticated sender")
			end
		elseif metadata.kind ~= "ServerToClient" then table.insert(failures, "wrong direction") end
		received[slot] = index
		total += 1
		if probe and slot == 1 and ok then
			local response = Fixtures.newInput(sample)
			responseInputs[index] = response
			server.broadcast(response, "FlushBeforeReturn")
			if not Comparator.compareRecord(sample.payloadId, sample.expected, response) then
				table.insert(failures, "probe response input mutation")
			end
		end
	end
	local path = `benchmarks/adapters/{id}/init.luau`
	server = AdapterContract.constructServer(preflight, world.loadAdapter(path, "Server"),
		world.contextRoot("Server"), if probe or broadcast then world.players else {},
		function(envelope, metadata) observe(1, envelope, metadata) end)
	server.setup()
	local clients = {}
	for clientIndex = 1, count do
		clients[clientIndex] = AdapterContract.constructClient(preflight,
			world.loadAdapter(path, "Client", clientIndex), world.contextRoot("Client", clientIndex),
			clientIndex, function(envelope, metadata) observe(clientIndex + 1, envelope, metadata) end)
		clients[clientIndex].setup()
	end
	assert(server.ready(), "server not ready")
	for _, client in clients do assert(client.ready(), "client not ready") end

	for index, sample in expected do
		local input = Fixtures.newInput(sample)
		inputs[index] = input
		local nextSample = expected[index + 1]
		local endFrame = probe or nextSample == nil or nextSample.frameIndex ~= sample.frameIndex
			or nextSample.phase ~= sample.phase
		local boundary = if endFrame then "FlushBeforeReturn" else "ContinueFrame"
		if broadcast then server.broadcast(input, boundary) else clients[1].submit(input, boundary) end
		assert(Comparator.compareRecord(sample.payloadId, sample.expected, input), "input mutation")
		if endFrame then world.step() end
		if probe then
			for _ = 1, 120 do
				if received[2] == index then break end
				world.step()
			end
			assert(received[2] == index, `probe echo missing at {index}`)
		end
	end
	for _ = 1, 120 do world.step() end
	for index, input in inputs do
		assert(Comparator.compareRecord(expected[index].payloadId, expected[index].expected, input),
			"deferred input mutation")
	end
	for index, response in responseInputs do
		assert(Comparator.compareRecord(expected[index].payloadId, expected[index].expected, response),
			"deferred probe response input mutation")
	end
	assert(#failures == 0, table.concat(failures, "; "))
	if not broadcast then assert(received[1] == #expected, "C2S count/order mismatch") end
	if broadcast or probe then
		for clientIndex = 1, count do
			assert(received[clientIndex + 1] == #expected, `S2C count mismatch at recipient {clientIndex}`)
		end
	end
	for _, client in clients do client.teardown(); client.teardown() end
	server.teardown(); server.teardown()
	local before = total
	for _ = 1, 3 do world.step() end
	assert(total == before, "delivery after teardown")
end

for _, workload in EventV1.workloads do
	for _, count in workload.recipientCounts do
		for repetition = 1, repetitions do
			runCase({ kind = "Workload", workloadId = workload.id, recipientCount = count }, count, repetition)
		end
		print(`PASS {id} {workload.id} recipients={count} repetitions={repetitions}`)
	end
end
for _, probe in EventV1.probes do
	for repetition = 1, repetitions do
		runCase({ kind = "SeparateProbe", probeId = probe.id }, probe.clientCount, repetition)
	end
	print(`PASS {id} {probe.id} repetitions={repetitions}`)
end
print(`PASS {id} real-library payload qualification: {total} deliveries (simulated engine; no timing claim)`)
