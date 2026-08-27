--!strict

export type Direction = "ClientToServer" | "ServerToClient"
export type Audience = "Server" | "Broadcast"
export type Delivery = "ReliableOrdered"
export type Schedule = "Steady" | "Burst"
export type ValueType = "boolean" | "u8" | "u16" | "u32" | "f32" | "Vector3F32"
export type Availability = "Required" | "Optional"
export type MeasurementScope = "Workload" | "SeparateProbe"
export type Summary = "Exact" | "MedianAndP95"
export type SampleCadence = "PerMeasuredFrame" | "PerRepetition" | "PerSubmission" | "PerProbe"
export type MeasurementRole = "Coordinator" | "Sender" | "CrossParticipant" | "ProbeClient"
export type MeasurementQuality = "Direct" | "EngineApproximation" | "RuntimeApproximation"
export type RankingUse = "ValidityOnly" | "Eligible" | "DiagnosticOnly"
export type MeasurementSource =
	"RunnerLedger"
	| "os.clock"
	| "Workspace:GetServerTimeNow"
	| "Stats.DataSendKbps"
	| "AdapterInstrumentation"
	| "gcinfo"
export type TimingBoundary =
	"MeasuredFrameStarted"
	| "FollowingFrameStarted"
	| "FirstMeasuredSubmissionStarted"
	| "FinalMeasuredSubmissionReturned"
	| "MeasuredSubmissionStarted"
	| "MeasuredSubmissionReturned"
	| "FinalExpectedDeliveryReceived"
	| "FinalExpectedDeliveryVerified"
	| "RoundTripSubmissionStarted"
	| "RoundTripEchoReceived"

export type Field = {
	name: string,
	valueType: ValueType,
	minimum: number?,
	maximum: number?,
}

export type Payload = {
	id: string,
	fields: { Field },
}

export type Workload = {
	id: string,
	payloadId: string,
	direction: Direction,
	audience: Audience,
	delivery: Delivery,
	schedule: Schedule,
	senderCount: number,
	recipientCounts: { number },
	messagesPerFrame: number,
	warmupFrames: number,
	measuredFrames: number,
	repetitions: number,
}

export type Probe = {
	id: string,
	payloadId: string,
	delivery: Delivery,
	requestAudience: "Server",
	responseAudience: "Broadcast",
	clientCount: number,
	maximumInFlight: number,
	warmupSamples: number,
	measuredSamples: number,
	repetitions: number,
}

export type Measurement = {
	id: string,
	unit: string,
	scope: MeasurementScope,
	summary: Summary,
	availability: Availability,
	capture: {
		source: MeasurementSource,
		role: MeasurementRole,
		cadence: SampleCadence,
		quality: MeasurementQuality,
		ranking: RankingUse,
		point: TimingBoundary?,
	},
	timing: {
		start: TimingBoundary,
		finish: TimingBoundary,
	}?,
	probeId: string?,
}

export type Contract = {
	version: number,
	framePhase: "PostSimulation",
	maximumAddedDeliveryFrames: number,
	maximumAddedDeliveryFramesScope: "IntentionalSenderSchedulingBeforeTransport",
	maximumAddedDeliveryFramesCounting: {
		boundary: "SenderPostSimulation",
		start: "LogicalSubmitInvoked",
		finish: "TransportSendInvoked",
		zero: "SamePostSimulationCallback",
		one: "NoLaterThanNextPostSimulationCallback",
	},
	clocks: {
		localDuration: {
			source: "os.clock",
			unit: "seconds",
			scope: "SingleParticipant",
			quality: "Direct",
		},
		shared: {
			source: "Workspace:GetServerTimeNow",
			unit: "seconds",
			scope: "CrossParticipant",
			quality: "EngineApproximation",
		},
	},
	execution: {
		targetFrameRate: number,
		mode: "StudioMultiplayer",
		launchMethod: "StudioTestService:ExecuteMultiplayerTestAsync",
		maximumClients: number,
		resultMethod: "StudioTestService:EndTest",
		resultReceiver: "ExecuteMultiplayerTestAsyncReturn",
		resultSerialization: "JSON",
		resultEgress: "LoopbackHttp",
		quiescenceFrames: number,
		quiescenceRule: "ConsecutivePostSimulationFramesWithoutDelivery",
		quiescencePlacements: { "AfterWarmupDrain" | "AfterMeasuredVerification" },
		includeSetupInTiming: boolean,
		includeWarmupInTiming: boolean,
		includeQuiescenceInTiming: boolean,
		includeResultExtractionInTiming: boolean,
	},
	fixture: {
		seed: number,
		variation: "PerMessage",
		floatPrecision: "Float32",
	},
	validity: {
		requireEverySubmission: boolean,
		requireEveryDelivery: boolean,
		requireEveryPayload: boolean,
		allowControlTrafficDuringMeasuredFrames: boolean,
		allowEstimatedMeasurementsInRankings: boolean,
	},
	payloads: { [string]: Payload },
	workloads: { Workload },
	probes: { Probe },
	measurements: { Measurement },
}

local contract: Contract = {
	version = 1,
	framePhase = "PostSimulation",
	maximumAddedDeliveryFrames = 1,
	maximumAddedDeliveryFramesScope = "IntentionalSenderSchedulingBeforeTransport",
	maximumAddedDeliveryFramesCounting = {
		boundary = "SenderPostSimulation",
		start = "LogicalSubmitInvoked",
		finish = "TransportSendInvoked",
		zero = "SamePostSimulationCallback",
		one = "NoLaterThanNextPostSimulationCallback",
	},
	clocks = {
		localDuration = {
			source = "os.clock",
			unit = "seconds",
			scope = "SingleParticipant",
			quality = "Direct",
		},
		shared = {
			source = "Workspace:GetServerTimeNow",
			unit = "seconds",
			scope = "CrossParticipant",
			quality = "EngineApproximation",
		},
	},
	execution = {
		targetFrameRate = 60,
		mode = "StudioMultiplayer",
		launchMethod = "StudioTestService:ExecuteMultiplayerTestAsync",
		maximumClients = 8,
		resultMethod = "StudioTestService:EndTest",
		resultReceiver = "ExecuteMultiplayerTestAsyncReturn",
		resultSerialization = "JSON",
		resultEgress = "LoopbackHttp",
		quiescenceFrames = 60,
		quiescenceRule = "ConsecutivePostSimulationFramesWithoutDelivery",
		quiescencePlacements = { "AfterWarmupDrain", "AfterMeasuredVerification" },
		includeSetupInTiming = false,
		includeWarmupInTiming = false,
		includeQuiescenceInTiming = false,
		includeResultExtractionInTiming = false,
	},
	fixture = {
		seed = 0,
		variation = "PerMessage",
		floatPrecision = "Float32",
	},
	validity = {
		requireEverySubmission = true,
		requireEveryDelivery = true,
		requireEveryPayload = true,
		allowControlTrafficDuringMeasuredFrames = false,
		allowEstimatedMeasurementsInRankings = false,
	},
	payloads = {
		tiny = {
			id = "tiny",
			fields = {
				{ name = "sequence", valueType = "u32", minimum = 0, maximum = 4_294_967_295 },
				{ name = "enabled", valueType = "boolean" },
			},
		},
		state = {
			id = "state",
			fields = {
				{ name = "sequence", valueType = "u32", minimum = 0, maximum = 4_294_967_295 },
				{ name = "entityId", valueType = "u16", minimum = 0, maximum = 65_535 },
				{ name = "position", valueType = "Vector3F32", minimum = -1_024, maximum = 1_024 },
				{ name = "yaw", valueType = "f32", minimum = -180, maximum = 180 },
				{ name = "health", valueType = "u8", minimum = 0, maximum = 100 },
			},
		},
	},
	workloads = {
		{
			id = "tiny-steady-c2s",
			payloadId = "tiny",
			direction = "ClientToServer",
			audience = "Server",
			delivery = "ReliableOrdered",
			schedule = "Steady",
			senderCount = 1,
			recipientCounts = { 1 },
			messagesPerFrame = 1,
			warmupFrames = 60,
			measuredFrames = 120,
			repetitions = 30,
		},
		{
			id = "state-steady-c2s",
			payloadId = "state",
			direction = "ClientToServer",
			audience = "Server",
			delivery = "ReliableOrdered",
			schedule = "Steady",
			senderCount = 1,
			recipientCounts = { 1 },
			messagesPerFrame = 1,
			warmupFrames = 60,
			measuredFrames = 120,
			repetitions = 30,
		},
		{
			id = "state-burst-c2s",
			payloadId = "state",
			direction = "ClientToServer",
			audience = "Server",
			delivery = "ReliableOrdered",
			schedule = "Burst",
			senderCount = 1,
			recipientCounts = { 1 },
			messagesPerFrame = 100,
			warmupFrames = 10,
			measuredFrames = 10,
			repetitions = 30,
		},
		{
			id = "state-broadcast-s2c",
			payloadId = "state",
			direction = "ServerToClient",
			audience = "Broadcast",
			delivery = "ReliableOrdered",
			schedule = "Steady",
			senderCount = 1,
			recipientCounts = { 1, 4, 8 },
			messagesPerFrame = 1,
			warmupFrames = 60,
			measuredFrames = 120,
			repetitions = 30,
		},
	},
	probes = {
		{
			id = "tiny-round-trip",
			payloadId = "tiny",
			delivery = "ReliableOrdered",
			requestAudience = "Server",
			responseAudience = "Broadcast",
			clientCount = 1,
			maximumInFlight = 1,
			warmupSamples = 60,
			measuredSamples = 120,
			repetitions = 30,
		},
	},
	measurements = {
		{
			id = "submitted",
			unit = "count",
			scope = "Workload",
			summary = "Exact",
			availability = "Required",
			capture = {
				source = "RunnerLedger",
				role = "Coordinator",
				cadence = "PerRepetition",
				quality = "Direct",
				ranking = "ValidityOnly",
			},
		},
		{
			id = "received",
			unit = "count",
			scope = "Workload",
			summary = "Exact",
			availability = "Required",
			capture = {
				source = "RunnerLedger",
				role = "Coordinator",
				cadence = "PerRepetition",
				quality = "Direct",
				ranking = "ValidityOnly",
			},
		},
		{
			id = "correct",
			unit = "count",
			scope = "Workload",
			summary = "Exact",
			availability = "Required",
			capture = {
				source = "RunnerLedger",
				role = "Coordinator",
				cadence = "PerRepetition",
				quality = "Direct",
				ranking = "ValidityOnly",
			},
		},
		{
			id = "frameTime",
			unit = "milliseconds",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "os.clock",
				role = "Sender",
				cadence = "PerMeasuredFrame",
				quality = "Direct",
				ranking = "Eligible",
			},
			timing = {
				start = "MeasuredFrameStarted",
				finish = "FollowingFrameStarted",
			},
		},
		{
			id = "submissionDuration",
			unit = "milliseconds",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "os.clock",
				role = "Sender",
				cadence = "PerRepetition",
				quality = "Direct",
				ranking = "Eligible",
			},
			timing = {
				start = "FirstMeasuredSubmissionStarted",
				finish = "FinalMeasuredSubmissionReturned",
			},
		},
		{
			id = "completionDuration",
			unit = "milliseconds",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "Workspace:GetServerTimeNow",
				role = "CrossParticipant",
				cadence = "PerRepetition",
				quality = "EngineApproximation",
				ranking = "DiagnosticOnly",
			},
			timing = {
				start = "FirstMeasuredSubmissionStarted",
				finish = "FinalExpectedDeliveryReceived",
			},
		},
		{
			id = "drainDuration",
			unit = "milliseconds",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "Workspace:GetServerTimeNow",
				role = "CrossParticipant",
				cadence = "PerRepetition",
				quality = "EngineApproximation",
				ranking = "DiagnosticOnly",
			},
			timing = {
				start = "FinalMeasuredSubmissionReturned",
				finish = "FinalExpectedDeliveryReceived",
			},
		},
		{
			id = "wallDuration",
			unit = "milliseconds",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "Workspace:GetServerTimeNow",
				role = "CrossParticipant",
				cadence = "PerRepetition",
				quality = "EngineApproximation",
				ranking = "DiagnosticOnly",
			},
			timing = {
				start = "FirstMeasuredSubmissionStarted",
				finish = "FinalExpectedDeliveryVerified",
			},
		},
		{
			id = "roundTripLatency",
			unit = "milliseconds",
			scope = "SeparateProbe",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "os.clock",
				role = "ProbeClient",
				cadence = "PerProbe",
				quality = "Direct",
				ranking = "Eligible",
			},
			timing = {
				start = "RoundTripSubmissionStarted",
				finish = "RoundTripEchoReceived",
			},
			probeId = "tiny-round-trip",
		},
		{
			id = "submitCallDuration",
			unit = "microsecondsPerEvent",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Required",
			capture = {
				source = "os.clock",
				role = "Sender",
				cadence = "PerSubmission",
				quality = "Direct",
				ranking = "Eligible",
			},
			timing = {
				start = "MeasuredSubmissionStarted",
				finish = "MeasuredSubmissionReturned",
			},
		},
		{
			id = "engineDataSendRate",
			unit = "kilobytesPerSecond",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Optional",
			capture = {
				source = "Stats.DataSendKbps",
				role = "Sender",
				cadence = "PerMeasuredFrame",
				quality = "EngineApproximation",
				ranking = "DiagnosticOnly",
				point = "FollowingFrameStarted",
			},
		},
		{
			id = "preTransportSize",
			unit = "bytesPerEvent",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Optional",
			capture = {
				source = "AdapterInstrumentation",
				role = "Sender",
				cadence = "PerSubmission",
				quality = "Direct",
				ranking = "DiagnosticOnly",
			},
		},
		{
			id = "remoteCalls",
			unit = "count",
			scope = "Workload",
			summary = "Exact",
			availability = "Optional",
			capture = {
				source = "AdapterInstrumentation",
				role = "Sender",
				cadence = "PerRepetition",
				quality = "Direct",
				ranking = "DiagnosticOnly",
			},
		},
		{
			id = "positiveGc",
			unit = "bytesPerEvent",
			scope = "Workload",
			summary = "MedianAndP95",
			availability = "Optional",
			capture = {
				source = "gcinfo",
				role = "Sender",
				cadence = "PerRepetition",
				quality = "RuntimeApproximation",
				ranking = "DiagnosticOnly",
			},
		},
	},
}

local function deepFreeze(value: any)
	for _, nested in value do
		if type(nested) == "table" then
			deepFreeze(nested)
		end
	end

	table.freeze(value)
end

deepFreeze(contract)

return contract
