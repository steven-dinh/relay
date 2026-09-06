--!strict

-- Untimed feasibility proof: one simulated engine world and one initialized
-- adapter session per side stay alive across all 30 fixture windows. This is
-- not Studio evidence, a Result V1, or a ProcessRestart measurement.
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
assert(#process.args <= 1, "usage: external-session-reuse <library-id>")
local lock = Acquisition.validateLock(serde.decode("json", fs.readFile("benchmarks/libraries.lock.json")))
local selectedLibrary
for _, library in lock.libraries do
	if library.id == id then selectedLibrary = library; break end
end
assert(selectedLibrary ~= nil, "unknown external library")
Acquisition.verifyInstalled(selectedLibrary)
if selectedLibrary.kind == "CodegenTool" then
	require("../host/GeneratedAdapters").verifyGenerated(id)
end

-- Synthetic capability-preflight fixture only; this identity is never emitted
-- as evidence of the pilot's isolation model or as benchmark provenance.
local identity = {
	id = "external-session-reuse", displayName = "External session reuse proof", lane = "NativeBest",
	integrationKind = "Runtime",
	library = {
		id = "test-harness", displayName = "Test harness", version = "1",
		provenance = { kind = "Repository", sourceRepository = "https://example.com/test-harness",
			revision = string.rep("a", 40), checksum = "sha256:" .. string.rep("b", 64), license = "MIT" },
	},
	semantics = { broadcastMode = "NativeBroadcast", intentionalAddedDeliveryFrames = 1,
		repetitionIsolation = "SessionRestart" },
	capabilities = { directions = { "ClientToServer", "ServerToClient" },
		deliverySemantics = { "ReliableOrdered" }, payloadIds = { "state", "tiny" } },
}

local totalDeliveries = 0
local totalWindows = 0
local selectionCount = 0

local function runSelection(selection: any, clientCount: number, repetitions: number, label: string)
	assert(repetitions == 30, "session reuse proof requires the contract's 30 repetitions")
	local world = World.new(clientCount, id)
	local preflight = AdapterContract.preflight(identity, selection, "test")
	assert(preflight.kind == "Supported")
	if world.prepare ~= nil then
		world.prepare("Server")
		for clientIndex = 1, clientCount do world.prepare("Client", clientIndex) end
	end

	local probe = selection.kind == "SeparateProbe"
	local broadcast = not probe and preflight.selection.direction == "ServerToClient"
	local windows = {}
	local ownerBySequence = {}
	local expectedDeliveries = 0
	for repetition = 1, repetitions do
		local fixture = if probe then Fixtures.generateProbe(selection.probeId, repetition)
			else Fixtures.generate(selection.workloadId, repetition)
		local samples = {}
		for _, sample in fixture.warmup do table.insert(samples, sample) end
		for _, sample in fixture.measured do table.insert(samples, sample) end
		for _, sample in samples do
			assert(ownerBySequence[sample.sequence] == nil, "fixture sequence collision")
			ownerBySequence[sample.sequence] = repetition
		end
		windows[repetition] = { index = repetition, samples = samples,
			phases = { fixture.warmup, fixture.measured }, received = table.create(clientCount + 1, 0) }
		expectedDeliveries += #samples * (if probe then clientCount + 1 elseif broadcast then clientCount else 1)
	end

	local failures = {}
	local seen = {}
	for slot = 1, clientCount + 1 do seen[slot] = {} end
	local active: any = nil
	local observed = 0
	local responseInputs = {}
	local server: any

	local function fail(message: string)
		table.insert(failures, `{label}: {message}`)
	end

	local function sequenceOf(envelope: any): any
		if type(envelope) ~= "table" then return nil end
		if envelope.kind == "Record" and type(envelope.value) == "table" then
			return rawget(envelope.value, "sequence")
		elseif envelope.kind == "Positional" and type(envelope.values) == "table" then
			return rawget(envelope.values, 1)
		end
		return nil
	end

	local function expectedAt(slot: number): boolean
		return if probe then slot >= 1 and slot <= clientCount + 1
			elseif broadcast then slot >= 2 and slot <= clientCount + 1
			else slot == 1
	end

	local function observe(slot: number, envelope: any, metadata: any)
		observed += 1
		totalDeliveries += 1
		local sequence = sequenceOf(envelope)
		local owner = if type(sequence) == "number" then ownerBySequence[sequence] else nil
		if active == nil then
			fail(`delivery outside a fixture window at slot {slot}`)
			return
		end
		if owner ~= active.index then
			fail(`cross-window/unknown delivery sequence={tostring(sequence)} owner={tostring(owner)} active={active.index}`)
			return
		end
		if not expectedAt(slot) then
			fail(`delivery to unexpected slot {slot} in window {active.index}`)
			return
		end
		if seen[slot][sequence] then
			fail(`duplicate delivery sequence={sequence} slot={slot}`)
			return
		end
		seen[slot][sequence] = true

		local index = active.received[slot] + 1
		active.received[slot] = index
		local sample = active.samples[index]
		if sample == nil then
			fail(`extra delivery slot={slot} window={active.index}`)
			return
		end
		local ok, mismatch
		if envelope.kind == "Record" then
			ok, mismatch = Comparator.compareRecord(sample.payloadId, sample.expected, envelope.value)
		else
			ok, mismatch = Comparator.compareCapturedPositional(
				sample.payloadId, sample.expected, envelope.values, envelope.count
			)
		end
		if not ok then fail(`payload slot={slot} index={index}: {mismatch.path}/{mismatch.reason}`) end
		if slot == 1 then
			if type(metadata) ~= "table"
				or metadata.kind ~= "ClientToServer"
				or metadata.sender ~= world.players[1]
			then
				fail(`unauthenticated server delivery sequence={sequence}`)
			end
		elseif type(metadata) ~= "table" or metadata.kind ~= "ServerToClient" then
			fail(`wrong client delivery direction sequence={sequence} slot={slot}`)
		end

		if probe and slot == 1 and ok then
			local response = Fixtures.newInput(sample)
			table.insert(responseInputs, { sample = sample, input = response })
			server.broadcast(response, "FlushBeforeReturn")
			if not Comparator.compareRecord(sample.payloadId, sample.expected, response) then
				fail(`probe response input mutation sequence={sequence}`)
			end
		end
	end

	local path = `benchmarks/adapters/{id}/init.luau`
	server = AdapterContract.constructServer(
		preflight, world.loadAdapter(path, "Server"), world.contextRoot("Server"),
		if probe or broadcast then world.players else {},
		function(envelope, metadata) observe(1, envelope, metadata) end
	)
	server.setup()
	local clients = {}
	for clientIndex = 1, clientCount do
		clients[clientIndex] = AdapterContract.constructClient(
			preflight, world.loadAdapter(path, "Client", clientIndex),
			world.contextRoot("Client", clientIndex), clientIndex,
			function(envelope, metadata) observe(clientIndex + 1, envelope, metadata) end
		)
		clients[clientIndex].setup()
	end
	assert(server.ready(), "server not ready")
	for _, client in clients do assert(client.ready(), "client not ready") end

	for repetition = 1, repetitions do
		active = windows[repetition]
		local inputs = {}
		local responseStart = #responseInputs + 1
		local phaseEnd = 0
		for phaseIndex, samples in active.phases do
			local phaseStart = phaseEnd
			phaseEnd += #samples
			for phaseSampleIndex, sample in samples do
				local index = phaseStart + phaseSampleIndex
				local input = Fixtures.newInput(sample)
				table.insert(inputs, { sample = sample, input = input })
				local nextSample = samples[phaseSampleIndex + 1]
				local endFrame = probe or nextSample == nil or nextSample.frameIndex ~= sample.frameIndex
					or nextSample.phase ~= sample.phase
				local boundary = if endFrame then "FlushBeforeReturn" else "ContinueFrame"
				if broadcast then server.broadcast(input, boundary) else clients[1].submit(input, boundary) end
				if not Comparator.compareRecord(sample.payloadId, sample.expected, input) then
					fail(`submission input mutation sequence={sample.sequence}`)
				end
				if endFrame then world.step() end
				if probe then
					for _ = 1, 120 do
						if active.received[2] == index then break end
						world.step()
					end
					if active.received[2] ~= index then fail(`probe echo missing at index {index}`) end
				end
			end

			for _ = 1, 120 do
				local complete = true
				for slot = 1, clientCount + 1 do
					if expectedAt(slot) and active.received[slot] ~= phaseEnd then complete = false end
				end
				if complete then break end
				world.step()
			end
			local quiet = 0
			for _ = 1, EventV1.execution.quiescenceFrames + 120 do
				local before = observed
				world.step()
				quiet = if observed == before then quiet + 1 else 0
				if quiet == EventV1.execution.quiescenceFrames then break end
			end
			if quiet ~= EventV1.execution.quiescenceFrames then
				fail(`quiet drain failed in window {repetition} phase {phaseIndex}`)
			end

			for slot = 1, clientCount + 1 do
				local expectedCount = if expectedAt(slot) then phaseEnd else 0
				if active.received[slot] ~= expectedCount then
					fail(`cardinality window={repetition} phase={phaseIndex} slot={slot} expected={expectedCount} actual={active.received[slot]}`)
				end
			end
		end
		for _, record in inputs do
			if not Comparator.compareRecord(record.sample.payloadId, record.sample.expected, record.input) then
				fail(`deferred submission input mutation sequence={record.sample.sequence}`)
			end
		end
		for responseIndex = responseStart, #responseInputs do
			local record = responseInputs[responseIndex]
			if not Comparator.compareRecord(record.sample.payloadId, record.sample.expected, record.input) then
				fail(`deferred response input mutation sequence={record.sample.sequence}`)
			end
		end
		totalWindows += 1
	end

	if observed ~= expectedDeliveries then
		fail(`global cardinality expected={expectedDeliveries} actual={observed}`)
	end
	active = nil
	for _, client in clients do client.teardown(); client.teardown() end
	server.teardown(); server.teardown()
	local transmissionCount = #world.transmissions
	for _ = 1, EventV1.execution.quiescenceFrames do world.step() end
	if #world.transmissions ~= transmissionCount then fail("transport emitted after teardown") end
	assert(#failures == 0, table.concat(failures, "; "))
	print(`PASS {id} {label}: {repetitions} windows, one session/side (SIMULATED ENGINE; UNTIMED; NON-RESULT-V1)`)
end

for _, workload in EventV1.workloads do
	for _, clientCount in workload.recipientCounts do
		selectionCount += 1
		runSelection(
			{ kind = "Workload", workloadId = workload.id, recipientCount = clientCount },
			clientCount, workload.repetitions, `{workload.id} recipients={clientCount}`
		)
	end
end
for _, probe in EventV1.probes do
	selectionCount += 1
	runSelection(
		{ kind = "SeparateProbe", probeId = probe.id },
		probe.clientCount, probe.repetitions, probe.id
	)
end

print(`PASS {id} external session reuse: selections={selectionCount} windows={totalWindows} deliveries={totalDeliveries}`)
print("SCOPE simulated engine / untimed / non-Result-V1; no Studio or ProcessRestart proof")
