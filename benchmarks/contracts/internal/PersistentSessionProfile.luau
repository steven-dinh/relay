--!strict

-- One fresh Studio selection session owns one fixed physical transport per
-- participant. Event V1 workloads, timing definitions and 30 repetitions remain
-- unchanged; repetitions are logical windows with generation markers, not
-- independent process samples. Per-window isolation proves logical closure
-- (drained traffic and disabled old observation), not physical transport teardown.
-- Final physical cleanup must pass before authoritative result finalization.
return table.freeze({
	ID = "event-session-v1",
	VERSION = 1,
	isolation = "PersistentSession",
})
