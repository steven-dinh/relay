--!strict

local Schema = require("./internal/ResultSchema")

export type RepositoryProvenance = Schema.RepositoryProvenance
export type EngineBuiltInProvenance = Schema.EngineBuiltInProvenance
export type AdapterIdentity = Schema.AdapterIdentity
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
export type Conformance = Schema.Conformance
export type Environment = Schema.Environment
export type ResultDraft = Schema.ResultDraft
export type Result = Schema.Result

return Schema.create(1)
