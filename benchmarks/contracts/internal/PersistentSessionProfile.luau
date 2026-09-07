--!strict

-- One fresh Studio selection session owns one fixed physical transport per
-- participant. Event V1 workloads, timing definitions and 30 repetitions remain
-- unchanged; repetitions are logical windows with generation markers, not
-- independent process samples. Per-window isolation proves logical closure
-- (drained traffic and disabled old observation), not physical transport teardown.
-- Final physical cleanup must pass before authoritative result finalization.
-- The fixed 3 ms startup allowance accommodates the engine's shared-clock
-- estimate; it is not calibration or a bound on timing error. Shared durations
-- remain EngineApproximation/DiagnosticOnly. Contract and measurement fingerprints
-- identify this cohort; schema/profile identity stays readable for historical V2.
return table.freeze({
	ID = "event-session-v1",
	VERSION = 1,
	isolation = "PersistentSession",
	startupClockAdmissionToleranceMilliseconds = 3,
})
