--!strict
-- Synthetic capture records test accounting, never performance claims.
local Evidence = require("../host/SerializerEvidence")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local ResultV2 = require("../contracts/result-v2")
local EventContract = require("../contracts/event-v1")
local Fixtures = require("./support/HostRuntimeFixtures")
local JSON_NULL_HOLE = "__serializer_evidence_json_null_hole__"
local windows = {
	{ startUnix = 10, finishUnix = 11, delivered = 2 },
	{ startUnix = 12, finishUnix = 13, delivered = 3 },
}
local function packet(frame, time, length, captured, interface)
	return `{frame}\t{time}\t{length}\t{captured or length}\t{interface or 0}\t1\t0\n`
end
local function encodeJson(value: any, nullHole: boolean?): string
	local encoded = serde.encode("json", value)
	if nullHole then
		local substitutions
		encoded, substitutions = string.gsub(encoded, serde.encode("json", JSON_NULL_HOLE), "null", 1)
		assert(substitutions == 1, "serialized test fixture must contain one null-hole marker")
	end
	return encoded
end
local rows = packet(1, 9, 999) .. packet(2, 10, 60) .. packet(3, 10.5, 40)
	.. packet(4, 11, 999) .. packet(5, 12, 150) .. packet(6, 13, 999)
local result = Evidence.wireTotals(rows, windows)
assert(result.bytes == 250 and result.deliveries == 5 and result.bytesPerDelivery == 50 and result.packets == 3,
	"must count captured frames once in half-open measured windows only")
assert(Evidence.wireTotals(rows, windows, { [0] = true }).bytes == 250)
assert(not pcall(Evidence.wireTotals, rows, windows, { [0] = true, [1] = true }),
	"one connection cannot supply an eight-recipient byte denominator")
assert(not pcall(Evidence.wireTotals, rows, windows, { [1] = true }), "unknown stream accepted")
local sparseWireWindows = serde.decode("json", encodeJson({ windows = { windows[1], JSON_NULL_HOLE, windows[2] } }, true)).windows
local sparseWireOk, sparseWireIssue = pcall(Evidence.wireTotals, rows, sparseWireWindows)
assert(not sparseWireOk and string.find(tostring(sparseWireIssue), "invalid wire windows", 1, true),
	"serialized null-hole wire windows must be rejected as sparse")
local function rejects(text, ranges)
	assert(not pcall(Evidence.wireTotals, text, ranges or windows), "invalid capture was accepted")
end
rejects(packet(1, 10, 60) .. packet(1, 12, 60)) -- duplicated frame
rejects(packet(1, 10, 60, 20) .. packet(2, 12, 60)) -- truncated packet
rejects(packet(1, 10, 60) .. packet(2, 12, 60, nil, 1)) -- double-sided capture
rejects(packet(1, 12, 60) .. packet(2, 10, 60)) -- clock went backwards
rejects(packet(1, 10, 60)) -- missing second window
rejects(rows, { { startUnix = 10, finishUnix = 12, delivered = 2 }, { startUnix = 11, finishUnix = 13, delivered = 3 } })
rejects(rows, { { startUnix = 10, finishUnix = 11, delivered = 0 } })
rejects("1\t10\t60\t60\t\t1\n")
local missing = Evidence.load(".", { caseId = "state-burst-c2s", pass = 1, role = "baseline" }, "unset", nil)
assert(#missing.issues == 1 and missing.metrics.wireBytesPerDelivery == nil, "missing evidence must remain unavailable")
print("PASS serializer evidence accounting")

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, nested in value do copied[key] = clone(nested) end
	return copied
end

local _, fixture = Fixtures.maximum()
local candidate = clone(fixture)
local revision = string.rep("a", 40)
local adapterFingerprint = "sha256:" .. string.rep("d", 64)
local measurementFingerprint = "sha256:" .. string.rep("c", 64)
local placeFingerprint = "sha256:" .. string.rep("e", 64)
candidate.schema = { id = "result-v2", version = 2 }
candidate.benchmark.version = 2
candidate.benchmark.source.adapterFingerprint = adapterFingerprint
candidate.benchmark.source.measurementFingerprint = measurementFingerprint
candidate.benchmark.source.revision = revision
candidate.benchmark.source.placeFingerprint = placeFingerprint
candidate.contract.id = "event-session-v1"
candidate.case.workloadId = "state-broadcast-s2c"
candidate.case.recipientCount = 8
candidate.environment.execution.clientCount = 8
for _, field in { "expectedDeliveries", "received", "correct" } do candidate.counts[field] *= 8 end
for _, measurement in candidate.measurements do
	if measurement.metadata.id == "received" or measurement.metadata.id == "correct" then
		measurement.summary.total *= 8
		for _, group in measurement.rawSamples do group.values[1] *= 8 end
	end
end
candidate.runId = "00112233-4455-4677-8899-aabbccddeeff"
candidate.adapter = {
	id = "relay-reliable",
	displayName = "Relay Reliable",
	lane = "EquivalentSemantics",
	integrationKind = "Runtime",
	library = {
		id = "relay",
		displayName = "Relay",
		version = "0.1.0",
		provenance = {
			kind = "Repository",
			sourceRepository = "https://github.com/steven-dinh/relay",
			revision = revision,
			checksum = "sha256:" .. string.rep("e", 64),
			license = "MIT",
		},
	},
	semantics = {
		broadcastMode = "NativeBroadcast",
		intentionalAddedDeliveryFrames = 0,
		repetitionIsolation = "PersistentSession",
	},
	capabilities = clone(candidate.adapter.capabilities),
}
candidate.conformance.sessionProof = { version = 1, passed = true }
local result = ResultV2.validate(candidate)

local function roundTripProbeResult(): any
	local probeCandidate = clone(candidate)
	probeCandidate.case = {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
		clientCount = 1,
		scheduledRepetitions = 30,
		startedRepetitions = 30,
		completedRepetitions = 30,
	}
	probeCandidate.counts = nil
	probeCandidate.environment.execution.clientCount = 1
	local definition = nil
	for _, measurement in EventContract.measurements do
		if measurement.id == "roundTripLatency" then definition = measurement break end
	end
	assert(definition ~= nil, "round-trip probe definition must exist")
	local rawSamples = table.create(30)
	for repetitionIndex = 1, 30 do
		rawSamples[repetitionIndex] = {
			repetitionIndex = repetitionIndex,
			participantIndex = 1,
			values = table.create(120, 4),
		}
	end
	probeCandidate.measurements = {
		{
			metadata = clone(definition),
			state = "Available",
			rawSamples = rawSamples,
			summary = { kind = "MedianAndP95", sampleCount = 3_600, median = 4, p95 = 4 },
		},
	}
	return ResultV2.validate(probeCandidate)
end

local process = require("@lune/process")
local tempRoot = process.cwd .. "/.tmp/serializer-evidence-loader-test"
assert(not fs.isDir(tempRoot) and not fs.isFile(tempRoot), "serializer evidence fixture directory collided")
if not fs.isDir(".tmp") then fs.writeDir(".tmp") end
fs.writeDir(tempRoot)
local ok, failure = pcall(function()
	local function artifact(name: string, bytes: string): any
		local path = tempRoot .. "/" .. name
		fs.writeFile(path, bytes)
		local reference = Evidence.artifact(path)
		reference.path = name
		return reference
	end
	local function jsonArtifact(name: string, value: any, nullHole: boolean?): any
		return artifact(name, encodeJson(value, nullHole))
	end
	local plan = {
		schema = "Relay.SerializerGatePlan",
		version = 1,
		baseline = { revision = revision, adapterFingerprint = adapterFingerprint,
			place = { path = "baseline.rbxlx", sha256 = placeFingerprint, size = 1 } },
		candidate = { revision = string.rep("b", 40), adapterFingerprint = "sha256:" .. string.rep("f", 64),
			place = { path = "candidate.rbxlx", sha256 = "sha256:" .. string.rep("6", 64), size = 1 } },
		cases = { "state-burst-c2s", "state-broadcast-s2c", "tiny-round-trip" },
		limits = {
			minimumWireSaving = 0.15, maximumCostRegression = 0.05, maximumLatencyRegression = 0.10,
			maximumDeliveryRegression = 0.05, maximumControlVariation = 0.05,
		},
	}
	local planHash = jsonArtifact("plan.json", plan).sha256
	local resultReference = jsonArtifact("result.json", result)
	local function values(id: string): { number }
		for _, measurement in result.measurements do
			if measurement.metadata.id == id then
				local output = {}
				for _, group in measurement.rawSamples do
					for _, value in group.values do table.insert(output, value) end
				end
				return output
			end
		end
		error("missing fixture measurement " .. id)
	end
	local submitted, correct = values("submitted"), values("correct")
	assert(#submitted == 30 and #correct == 30, "synthetic workload must retain all 30 windows")
	local function costParticipants(samples: { number }, microsecondsPerMessage: number, recipientCount: number?): any
		local count = recipientCount or 1
		local costWindows = table.create(30)
		for index = 1, 30 do
			costWindows[index] = {
				messages = samples[index] / count,
				totalMicroseconds = samples[index] / count * microsecondsPerMessage,
			}
		end
		local participants = {}
		for index = 1, count do participants[index] = { index = index, windows = clone(costWindows) } end
		return participants
	end
	local function sourceReceipt(runId: string, sourceFingerprint: string, samples: { number }, cost: number): any
		return {
			runId = runId,
			adapterFingerprint = sourceFingerprint,
			measurementFingerprint = measurementFingerprint,
			scope = "send-through-engine-serialization",
			unit = "microsecondsPerSubmissionWindowMean",
			rawProfile = artifact("sender-profile.json", "synthetic sender profile"),
			accountingReview = artifact("sender-review.md", "synthetic sender review"),
			participants = costParticipants(samples, cost),
		}
	end
	local receiver = {
		runId = result.runId,
		adapterFingerprint = adapterFingerprint,
		measurementFingerprint = measurementFingerprint,
		scope = "engine-deserialization-through-dispatch",
		unit = "microsecondsPerDeliveryWindowMean",
		rawProfile = artifact("receiver-profile.json", "synthetic receiver profile"),
		accountingReview = artifact("receiver-review.md", "synthetic receiver review"),
		participants = costParticipants(correct, 3, 8),
	}
	local connections = {}
	for index = 1, 8 do connections[index] = { participantIndex = index, udpStream = index - 1 } end
	local networkWindows = table.create(30)
	for index = 1, 30 do
		local startUnix = 101 + (index - 1) * 2
		networkWindows[index] = { startUnix = startUnix, finishUnix = startUnix + 1, delivered = correct[index] }
	end
	local supplement = {
		schema = "Relay.SerializerSupplement",
		version = 1,
		planSha256 = planHash,
		sender = sourceReceipt(result.runId, adapterFingerprint, submitted, 2),
		receiver = receiver,
		network = {
			runId = result.runId,
			adapterFingerprint = adapterFingerprint,
			measurementFingerprint = measurementFingerprint,
			scope = "isolated-connection-bidirectional",
			layer = "captured-frame",
			droppedPackets = 0,
			captureComplete = true,
			decoderSha256 = "sha256:" .. string.rep("1", 64),
			connections = connections,
			windows = networkWindows,
			boundaryEvidence = artifact("boundary-evidence.md", "synthetic boundary evidence"),
			accountingReview = artifact("network-review.md", "synthetic network review"),
			capture = artifact("capture.pcap", "synthetic packet capture"),
		},
	}
	local supplementReference = jsonArtifact("supplement.json", supplement)
	local session = {
		planSha256 = planHash,
		startedUnix = 100,
		finishedUnix = 200,
		hostLog = artifact("host.log", "synthetic host log"),
		environmentReview = artifact("environment-review.md", "synthetic environment review"),
	}
	local entry = {
		caseId = "state-broadcast-s2c",
		pass = 1,
		role = "baseline",
		result = resultReference,
		supplement = supplementReference,
		session = session,
	}
	local row = Evidence.load(tempRoot, entry, planHash, nil)
	local probeResult = roundTripProbeResult()
	local probeEntry = {
		caseId = "tiny-round-trip",
		pass = 1,
		role = "baseline",
		result = jsonArtifact("probe-result.json", probeResult),
		session = session,
	}
	local probeRow = Evidence.load(tempRoot, probeEntry, planHash, nil)
	assert(probeRow.runId == probeResult.runId and probeRow.metrics.latencyP95Ms == 4
		and probeRow.metrics.latencyP99Ms == 4 and #probeRow.issues == 0,
		"canonical SeparateProbe latency must import without workload counts")
	local function summary(id: string): any
		for _, measurement in result.measurements do
			if measurement.metadata.id == id then return measurement.summary end
		end
		error("missing fixture measurement " .. id)
	end
	local calls = summary("submitCallDuration")
	local latency = summary("drainDuration")
	assert(row.runId == result.runId and row.delivered == result.counts.correct, "canonical V2 delivery count was not imported")
	assert(row.placeFingerprint == placeFingerprint, "canonical V2 place identity was not imported")
	assert(row.publicCall.median == calls.median and row.publicCall.p95 == calls.p95,
		"sender public-call metrics did not come from Result V2 samples")
	assert(row.metrics.latencyP95Ms == latency.p95 and row.metrics.latencyP99Ms == latency.p95,
		"workload latency tails did not come from Result V2 drain samples")
	assert(row.metrics.senderMedianUs == 2 and row.metrics.senderP95Us == 2
		and row.metrics.receiverMedianUs == 3 and row.metrics.receiverP95Us == 3,
		"valid cost windows and full receiver coverage must import")
	assert(#row.issues == 1 and string.find(row.issues[1], "packet capture requires --tshark", 1, true),
		"valid full-window evidence must reach the external decoder requirement")

	local function checkIssue(badEntry: any, expected: string)
		local badRow = Evidence.load(tempRoot, badEntry, planHash, nil)
		assert(#badRow.issues == 1 and string.find(badRow.issues[1], expected, 1, true),
			"expected loader rejection: " .. expected .. "; got " .. tostring(badRow.issues[1]))
	end
	local alteredHash = clone(entry)
	alteredHash.result.sha256 = "sha256:" .. string.rep("0", 64)
	checkIssue(alteredHash, "artifact hash/size mismatch")
	local wrongSourceSupplement = clone(supplement)
	wrongSourceSupplement.sender.runId = "11112233-4455-4677-8899-aabbccddeeff"
	local wrongSource = clone(entry)
	wrongSource.supplement = jsonArtifact("wrong-source.json", wrongSourceSupplement)
	checkIssue(wrongSource, "sender evidence belongs to different code/run")
	local wrongPlanSupplement = clone(supplement)
	wrongPlanSupplement.planSha256 = "sha256:" .. string.rep("0", 64)
	local wrongPlan = clone(entry)
	wrongPlan.supplement = jsonArtifact("wrong-plan.json", wrongPlanSupplement)
	checkIssue(wrongPlan, "supplement does not bind this predeclared plan")
	local wrongSession = clone(entry)
	wrongSession.session.planSha256 = "sha256:" .. string.rep("0", 64)
	checkIssue(wrongSession, "missing predeclared session receipt")
	local alteredSessionArtifact = clone(entry)
	alteredSessionArtifact.session.hostLog.sha256 = "sha256:" .. string.rep("0", 64)
	checkIssue(alteredSessionArtifact, "artifact hash/size mismatch")
	local sparseParticipants = clone(supplement)
	sparseParticipants.receiver.participants[4] = JSON_NULL_HOLE
	local decodedParticipants = serde.decode("json", encodeJson(sparseParticipants, true)).receiver.participants
	assert(#decodedParticipants == 8 and decodedParticipants[4] == nil and decodedParticipants[8] ~= nil,
		"participant fixture must reproduce the old length-check bypass")
	local missingParticipant = clone(entry)
	missingParticipant.supplement = jsonArtifact("sparse-participant.json", sparseParticipants, true)
	checkIssue(missingParticipant, "missing receiver participant")
	local sparseCostWindows = clone(supplement)
	sparseCostWindows.receiver.participants[1].windows[15] = JSON_NULL_HOLE
	local missingCostWindow = clone(entry)
	missingCostWindow.supplement = jsonArtifact("sparse-cost-window.json", sparseCostWindows, true)
	checkIssue(missingCostWindow, "receiver windows/identity mismatch")
	local sparseConnections = clone(supplement)
	sparseConnections.network.connections[4] = JSON_NULL_HOLE
	local decodedConnections = serde.decode("json", encodeJson(sparseConnections, true)).network.connections
	assert(#decodedConnections == 8 and decodedConnections[4] == nil and decodedConnections[8] ~= nil,
		"connection fixture must reproduce the old length-check bypass")
	local missingConnection = clone(entry)
	missingConnection.supplement = jsonArtifact("sparse-connection.json", sparseConnections, true)
	checkIssue(missingConnection, "missing recipient connections")
	local sparseNetworkWindows = clone(supplement)
	sparseNetworkWindows.network.windows[15] = JSON_NULL_HOLE
	local missingNetworkWindow = clone(entry)
	missingNetworkWindow.supplement = jsonArtifact("sparse-network-window.json", sparseNetworkWindows, true)
	checkIssue(missingNetworkWindow, "capture does not cover every measured window")
end)
fs.removeDir(tempRoot)
assert(ok, tostring(failure))

print("PASS serializer evidence Result V2 loader")
