local Contract = require("../contracts/event-v1")

local function assertPositiveInteger(value, label)
	assert(type(value) == "number", `{label} must be a number`)
	assert(value > 0 and value % 1 == 0, `{label} must be a positive integer`)
end

local function assertDeepFrozen(value, path)
	if type(value) ~= "table" then
		return
	end

	assert(table.isfrozen(value), `{path} must be frozen`)
	for key, nested in value do
		assertDeepFrozen(nested, `{path}.{tostring(key)}`)
	end
end

assert(Contract.version == 1, "event contract version must be 1")
assert(Contract.framePhase == "PostSimulation", "event submissions must use PostSimulation")
assert(Contract.maximumAddedDeliveryFrames == 1, "intentional sender scheduling budget must be one frame")
assert(
	Contract.maximumAddedDeliveryFramesScope == "IntentionalSenderSchedulingBeforeTransport",
	"added delivery frames must exclude Roblox transport and receiver scheduling"
)
assert(
	Contract.maximumAddedDeliveryFramesCounting.boundary == "SenderPostSimulation",
	"added frames must count sender PostSimulation boundaries"
)
assert(
	Contract.maximumAddedDeliveryFramesCounting.start == "LogicalSubmitInvoked",
	"added-frame counting must start at logical submit"
)
assert(
	Contract.maximumAddedDeliveryFramesCounting.finish == "TransportSendInvoked",
	"added-frame counting must stop at transport submission"
)
assert(
	Contract.maximumAddedDeliveryFramesCounting.zero == "SamePostSimulationCallback",
	"zero added frames must mean same-callback transport submission"
)
assert(
	Contract.maximumAddedDeliveryFramesCounting.one == "NoLaterThanNextPostSimulationCallback",
	"one added frame must mean transport submission no later than the next callback"
)

assert(Contract.clocks.localDuration.source == "os.clock", "local durations must use os.clock")
assert(Contract.clocks.localDuration.unit == "seconds", "os.clock source unit must be explicit")
assert(Contract.clocks.localDuration.scope == "SingleParticipant", "os.clock must stay within one participant")
assert(Contract.clocks.localDuration.quality == "Direct", "local duration clock must be direct")
assert(
	Contract.clocks.shared.source == "Workspace:GetServerTimeNow",
	"cross-participant timestamps must use the shared engine clock"
)
assert(Contract.clocks.shared.unit == "seconds", "shared clock source unit must be explicit")
assert(Contract.clocks.shared.scope == "CrossParticipant", "shared clock must span participants")
assert(
	Contract.clocks.shared.quality == "EngineApproximation",
	"shared engine clock must not be treated as exact"
)

assert(Contract.execution.targetFrameRate == 60, "event contract must target 60 FPS")
assert(Contract.execution.mode == "StudioMultiplayer", "event-v1 must use the reproducible Studio lane")
assert(
	Contract.execution.launchMethod == "StudioTestService:ExecuteMultiplayerTestAsync",
	"Studio multiplayer launch method must be explicit"
)
assert(Contract.execution.maximumClients == 8, "Studio multiplayer supports at most eight clients")
assert(Contract.execution.resultMethod == "StudioTestService:EndTest", "server result method must be explicit")
assert(
	Contract.execution.resultReceiver == "ExecuteMultiplayerTestAsyncReturn",
	"plugin must receive the server result as the launcher return value"
)
assert(Contract.execution.resultSerialization == "JSON", "host result payload must be JSON")
assert(Contract.execution.resultEgress == "LoopbackHttp", "plugin results must leave Studio over loopback HTTP")
assert(Contract.execution.quiescenceFrames == 60, "quiescence must require 60 quiet frames")
assert(
	Contract.execution.quiescenceRule == "ConsecutivePostSimulationFramesWithoutDelivery",
	"any delivery must restart the quiescence count"
)
assert(#Contract.execution.quiescencePlacements == 2, "event-v1 must define both quiescence windows")
assert(Contract.execution.quiescencePlacements[1] == "AfterWarmupDrain", "warmup quiescence must come first")
assert(
	Contract.execution.quiescencePlacements[2] == "AfterMeasuredVerification",
	"post-verification quiescence must come second"
)
assert(not Contract.execution.includeSetupInTiming, "setup must stay outside timed regions")
assert(not Contract.execution.includeWarmupInTiming, "warmup must stay outside timed regions")
assert(not Contract.execution.includeQuiescenceInTiming, "quiescence must stay outside timed regions")
assert(not Contract.execution.includeResultExtractionInTiming, "result extraction must stay outside timed regions")

assert(Contract.fixture.seed == 0, "fixture seed must remain deterministic")
assert(Contract.fixture.variation == "PerMessage", "fixtures must vary per message")
assert(Contract.fixture.floatPrecision == "Float32", "float precision must remain equivalent")

assert(Contract.validity.requireEverySubmission, "every submission must be counted")
assert(Contract.validity.requireEveryDelivery, "every delivery must be counted")
assert(Contract.validity.requireEveryPayload, "every payload must be checked")
assert(
	not Contract.validity.allowControlTrafficDuringMeasuredFrames,
	"runner control traffic must stay outside measured frames"
)
assert(
	not Contract.validity.allowEstimatedMeasurementsInRankings,
	"estimated measurements must never affect rankings"
)

local expectedPayloads = { "state", "tiny" }
local actualPayloads = {}
local allowedValueTypes = {
	boolean = true,
	u8 = true,
	u16 = true,
	u32 = true,
	f32 = true,
	Vector3F32 = true,
}

for id, payload in Contract.payloads do
	table.insert(actualPayloads, id)
	assert(payload.id == id, `payload key {id} must match payload id`)
	assert(#payload.fields > 0, `payload {id} must contain fields`)

	local fieldNames = {}
	for _, field in payload.fields do
		assert(not fieldNames[field.name], `payload {id} repeats field {field.name}`)
		assert(allowedValueTypes[field.valueType], `payload {id} uses unsupported type {field.valueType}`)
		fieldNames[field.name] = true

		if field.minimum ~= nil or field.maximum ~= nil then
			assert(type(field.minimum) == "number", `payload {id}.{field.name} minimum must be numeric`)
			assert(type(field.maximum) == "number", `payload {id}.{field.name} maximum must be numeric`)
			assert(field.minimum <= field.maximum, `payload {id}.{field.name} range must be ordered`)
		end
	end
end

table.sort(actualPayloads)
assert(#actualPayloads == #expectedPayloads, "event-v1 must contain exactly two payloads")
for index, expectedId in expectedPayloads do
	assert(actualPayloads[index] == expectedId, `expected payload {expectedId}`)
end

local expectedWorkloads = {
	["tiny-steady-c2s"] = { audience = "Server", submissions = 120, deliveries = { 120 } },
	["state-steady-c2s"] = { audience = "Server", submissions = 120, deliveries = { 120 } },
	["state-burst-c2s"] = { audience = "Server", submissions = 1_000, deliveries = { 1_000 } },
	["state-broadcast-s2c"] = { audience = "Broadcast", submissions = 120, deliveries = { 120, 480, 960 } },
}

local workloadCount = 0
for _, workload in Contract.workloads do
	workloadCount += 1
	local expected = expectedWorkloads[workload.id]
	assert(expected ~= nil, `unexpected workload {workload.id}`)
	assert(Contract.payloads[workload.payloadId] ~= nil, `unknown payload {workload.payloadId}`)
	assert(workload.delivery == "ReliableOrdered", `workload {workload.id} must be reliable and ordered`)
	assert(
		workload.direction == "ClientToServer" or workload.direction == "ServerToClient",
		`invalid direction for {workload.id}`
	)
	assert(workload.audience == expected.audience, `unexpected audience for {workload.id}`)
	if workload.direction == "ClientToServer" then
		assert(workload.audience == "Server", `client-to-server workload {workload.id} must target the server`)
	else
		assert(workload.audience == "Broadcast", `server-to-client workload {workload.id} must broadcast`)
	end
	assert(workload.schedule == "Steady" or workload.schedule == "Burst", `invalid schedule for {workload.id}`)
	assertPositiveInteger(workload.senderCount, `{workload.id}.senderCount`)
	assert(workload.senderCount == 1, `Event V1 workload {workload.id} must remain single-sender`)
	assertPositiveInteger(workload.messagesPerFrame, `{workload.id}.messagesPerFrame`)
	assertPositiveInteger(workload.warmupFrames, `{workload.id}.warmupFrames`)
	assertPositiveInteger(workload.measuredFrames, `{workload.id}.measuredFrames`)
	assertPositiveInteger(workload.repetitions, `{workload.id}.repetitions`)
	assert(workload.repetitions == 30, `workload {workload.id} must provide 30 samples`)

	local submissions = workload.messagesPerFrame * workload.measuredFrames * workload.senderCount
	assert(submissions == expected.submissions, `unexpected submission count for {workload.id}`)
	assert(#workload.recipientCounts == #expected.deliveries, `unexpected recipient variants for {workload.id}`)

	local previousRecipients = 0
	for index, recipients in workload.recipientCounts do
		assertPositiveInteger(recipients, `{workload.id}.recipientCounts[{index}]`)
		assert(recipients <= Contract.execution.maximumClients, `workload {workload.id} exceeds Studio client limit`)
		assert(recipients > previousRecipients, `recipient counts must be strictly increasing for {workload.id}`)
		assert(
			submissions * recipients == expected.deliveries[index],
			`unexpected expected delivery count for {workload.id}`
		)
		previousRecipients = recipients
	end

	expectedWorkloads[workload.id] = nil
end

assert(workloadCount == 4, "event-v1 must contain exactly four workloads")
assert(next(expectedWorkloads) == nil, "an expected workload is missing")

assert(#Contract.probes == 1, "event-v1 must contain exactly one separate probe")
local roundTripProbe = Contract.probes[1]
assert(roundTripProbe.id == "tiny-round-trip", "round-trip probe id must remain stable")
assert(roundTripProbe.payloadId == "tiny", "round-trip probe must use the tiny payload")
assert(roundTripProbe.delivery == "ReliableOrdered", "round-trip probe must be reliable and ordered")
assert(roundTripProbe.requestAudience == "Server", "round-trip request must target the server")
assert(roundTripProbe.responseAudience == "Broadcast", "one-client round-trip response must broadcast")
assert(roundTripProbe.clientCount == 1, "round-trip probe must use exactly one client")
assert(roundTripProbe.maximumInFlight == 1, "round-trip probe must not pipeline requests")
assert(roundTripProbe.warmupSamples == 60, "round-trip probe warmup must remain fixed")
assert(roundTripProbe.measuredSamples == 120, "round-trip probe sample count must remain fixed")
assert(roundTripProbe.repetitions == 30, "round-trip probe must provide 30 repetitions")

local expectedMeasurements = {
	submitted = { "count", "Workload", "Exact", "Required", "RunnerLedger", "Coordinator", "PerRepetition", "Direct", "ValidityOnly" },
	received = { "count", "Workload", "Exact", "Required", "RunnerLedger", "Coordinator", "PerRepetition", "Direct", "ValidityOnly" },
	correct = { "count", "Workload", "Exact", "Required", "RunnerLedger", "Coordinator", "PerRepetition", "Direct", "ValidityOnly" },
	frameTime = { "milliseconds", "Workload", "MedianAndP95", "Required", "os.clock", "Sender", "PerMeasuredFrame", "Direct", "Eligible", "MeasuredFrameStarted", "FollowingFrameStarted" },
	submissionDuration = { "milliseconds", "Workload", "MedianAndP95", "Required", "os.clock", "Sender", "PerRepetition", "Direct", "Eligible", "FirstMeasuredSubmissionStarted", "FinalMeasuredSubmissionReturned" },
	completionDuration = { "milliseconds", "Workload", "MedianAndP95", "Required", "Workspace:GetServerTimeNow", "CrossParticipant", "PerRepetition", "EngineApproximation", "DiagnosticOnly", "FirstMeasuredSubmissionStarted", "FinalExpectedDeliveryReceived" },
	drainDuration = { "milliseconds", "Workload", "MedianAndP95", "Required", "Workspace:GetServerTimeNow", "CrossParticipant", "PerRepetition", "EngineApproximation", "DiagnosticOnly", "FinalMeasuredSubmissionReturned", "FinalExpectedDeliveryReceived" },
	wallDuration = { "milliseconds", "Workload", "MedianAndP95", "Required", "Workspace:GetServerTimeNow", "CrossParticipant", "PerRepetition", "EngineApproximation", "DiagnosticOnly", "FirstMeasuredSubmissionStarted", "FinalExpectedDeliveryVerified" },
	roundTripLatency = { "milliseconds", "SeparateProbe", "MedianAndP95", "Required", "os.clock", "ProbeClient", "PerProbe", "Direct", "Eligible", "RoundTripSubmissionStarted", "RoundTripEchoReceived", nil, "tiny-round-trip" },
	submitCallDuration = { "microsecondsPerEvent", "Workload", "MedianAndP95", "Required", "os.clock", "Sender", "PerSubmission", "Direct", "Eligible", "MeasuredSubmissionStarted", "MeasuredSubmissionReturned" },
	engineDataSendRate = { "kilobytesPerSecond", "Workload", "MedianAndP95", "Optional", "Stats.DataSendKbps", "Sender", "PerMeasuredFrame", "EngineApproximation", "DiagnosticOnly", nil, nil, "FollowingFrameStarted" },
	preTransportSize = { "bytesPerEvent", "Workload", "MedianAndP95", "Optional", "AdapterInstrumentation", "Sender", "PerSubmission", "Direct", "DiagnosticOnly" },
	remoteCalls = { "count", "Workload", "Exact", "Optional", "AdapterInstrumentation", "Sender", "PerRepetition", "Direct", "DiagnosticOnly" },
	positiveGc = { "bytesPerEvent", "Workload", "MedianAndP95", "Optional", "gcinfo", "Sender", "PerRepetition", "RuntimeApproximation", "DiagnosticOnly" },
}

for _, measurement in Contract.measurements do
	local expected = expectedMeasurements[measurement.id]
	assert(expected ~= nil, `unexpected measurement {measurement.id}`)
	assert(measurement.unit == expected[1], `unexpected unit for {measurement.id}`)
	assert(measurement.scope == expected[2], `unexpected scope for {measurement.id}`)
	assert(measurement.summary == expected[3], `unexpected summary for {measurement.id}`)
	assert(measurement.availability == expected[4], `unexpected availability for {measurement.id}`)
	assert(measurement.capture.source == expected[5], `unexpected source for {measurement.id}`)
	assert(measurement.capture.role == expected[6], `unexpected role for {measurement.id}`)
	assert(measurement.capture.cadence == expected[7], `unexpected cadence for {measurement.id}`)
	assert(measurement.capture.quality == expected[8], `unexpected quality for {measurement.id}`)
	assert(measurement.capture.ranking == expected[9], `unexpected ranking use for {measurement.id}`)

	if expected[10] ~= nil then
		assert(measurement.timing ~= nil, `{measurement.id} must define timing boundaries`)
		assert(measurement.timing.start == expected[10], `unexpected start boundary for {measurement.id}`)
		assert(measurement.timing.finish == expected[11], `unexpected finish boundary for {measurement.id}`)
	else
		assert(measurement.timing == nil, `unexpected timing boundaries for {measurement.id}`)
	end

	assert(measurement.capture.point == expected[12], `unexpected capture point for {measurement.id}`)
	assert(measurement.probeId == expected[13], `unexpected probe ownership for {measurement.id}`)
	if measurement.capture.quality ~= "Direct" then
		assert(measurement.capture.ranking == "DiagnosticOnly", `{measurement.id} estimate must not be ranked`)
	end

	expectedMeasurements[measurement.id] = nil
end

assert(next(expectedMeasurements) == nil, "an expected measurement is missing")
assertDeepFrozen(Contract, "Contract")

local mutationSucceeded = pcall(function()
	Contract.workloads[1].measuredFrames = 1
end)
assert(not mutationSucceeded, "nested contract data must reject mutation")

print("PASS Relay.Benchmarks.EventContractV1")
