--!strict

local Schema = require("./internal/ResultSchema")
local Identity = require("./internal/AdapterIdentity")

export type RepositoryProvenance = Schema.RepositoryProvenance
export type EngineBuiltInProvenance = Schema.EngineBuiltInProvenance
export type AdapterIdentity = Identity.AdapterIdentity<"PersistentSession">
export type WorkloadCase = Schema.WorkloadCase
export type SeparateProbeCase = Schema.SeparateProbeCase
export type Counts = Schema.Counts
export type ComparatorReason = Schema.ComparatorReason
export type FailureCode = Schema.FailureCode
export type FailureDiscriminator = Schema.FailureDiscriminator
export type PayloadComparatorMismatch = Schema.PayloadComparatorMismatch
export type FirstOccurrence = Schema.FirstOccurrence
export type Failure = Schema.Failure
export type RawSampleGroup = Schema.RawSampleGroup
export type UnavailableReason = Schema.UnavailableReason
export type MeasurementDraft = Schema.MeasurementDraft
export type ExactSummary = Schema.ExactSummary
export type MedianAndP95Summary = Schema.MedianAndP95Summary
export type Measurement = Schema.Measurement
export type Environment = Schema.Environment

export type Conformance = Schema.Conformance & { sessionProof: { version: number, passed: boolean } }
export type BenchmarkSource = { revision: string, dirty: boolean, placeFingerprint: string?, measurementFingerprint: string, adapterFingerprint: string }
export type ResultDraft = {
	runId: string,
	benchmarkSource: BenchmarkSource,
	contractFingerprint: string,
	adapter: AdapterIdentity,
	case: WorkloadCase | SeparateProbeCase,
	failures: { Failure },
	counts: Counts?,
	conformance: Conformance,
	measurements: { MeasurementDraft },
	environment: Environment,
}
export type Result = {
	schema: { id: "result-v2", version: number },
	runId: string,
	benchmark: { id: "relay-event", version: number, source: BenchmarkSource },
	contract: { id: "event-session-v1", version: number, fingerprint: string },
	adapter: AdapterIdentity,
	case: WorkloadCase | SeparateProbeCase,
	status: "Valid" | "Invalid" | "Unsupported" | "Error",
	failures: { Failure },
	counts: Counts?,
	conformance: Conformance,
	measurements: { Measurement },
	environment: Environment,
}

return (Schema.create(2) :: any) :: {
	ID: string,
	VERSION: number,
	BENCHMARK_ID: string,
	BENCHMARK_VERSION: number,
	MAX_JSON_BYTES: number,
	finalize: (draft: ResultDraft) -> Result,
	validate: (candidate: unknown) -> Result,
}
