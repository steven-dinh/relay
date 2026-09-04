# Process-Restart Adapter Design and Security Review

Review date: 2026-09-04 UTC

## Decision

Event V1 may measure QuickNet, ByteNet, Satset, Warp, Blink, Zap, and
NetRay-Compile only through the process-restart route described here. The
existing whole-case `SessionRestart` route remains unchanged. An allowlist-only
change, reuse of one Studio process for multiple repetitions, or merging sliced
whole-case snapshots is not approved.

Suphi-Packet is not eligible for this route. Its client networking path flushes
through a private accumulated-time Heartbeat scheduler and exports no supported
flush. That behavior does not guarantee Event V1's maximum of one intentional
added sender frame. Its original author grant is recorded separately as
`LicenseRef-Suphi-Packet-Grant`; licensing is no longer the technical blocker.

## Execution boundary

Each logical repetition runs in a fresh Studio multiplayer process group and
emits one exact `RepetitionFragmentV1`. A fragment is hostile input until it has
passed bounded JSON parsing, contract validation, and all host-derived binding
checks. Every repetition receives a fresh child launch UUID and 256-bit
capability. A stable batch UUID becomes the final Result V1 run ID.

The host accepts a fragment only when all of these values match its private run
plan:

- authenticated frame capability and child launch UUID;
- batch UUID and logical repetition index;
- the complete host-derived child `HostManifestV1`;
- the selected case, topology, adapter identity, source, contract, place,
  Studio, and host environment;
- one exact participant roster and one repetition's bounded evidence.

Indexes must arrive once each in order from 1 through 30. The next launch cannot
start until the previous parent process has exited and the Windows process
census proves that no Studio process remains. Missing, duplicate, malformed,
invalid, provenance-mismatched, timed-out, or lifecycle-uncertain evidence
aborts the batch; the host never synthesizes a repetition.

Only the trusted Lune host aggregates fragments. It validates the complete set,
constructs one full draft, finalizes Result V1 once, validates it again against
a final host-derived manifest whose launch ID is the batch UUID, and publishes
by the existing same-directory no-overwrite transaction. Fragment files and
partial batches are not comparison inputs.

## Source and composition provenance

The external route is Windows-only. A committed closed catalog selects the
adapter; Studio cannot supply module paths, commands, identity fields, or source
locations. Before building, the host requires a clean Git worktree, verifies
the exact acquired artifact lock, and verifies deterministic generated outputs
where applicable.

The host creates an ignored Rojo project from the tracked Event V1 composition,
disables HTTP, and adds only the selected external binding, library, optional
Warp endpoint, and generated runtime. It builds those bytes once per selection
and reuses the exact base place for all 30 child launches. The place fingerprint
binds the complete measured composition; the adapter artifact digest also
length-frames and hashes the exact embedded selected binding and resource tree.
The clean-source check and composition verification run again before final
publication.

## Readiness and correctness

Potentially yielding module initialization and adapter-specific replication
predicates run outside every timed region. Server prewarm happens first. Each
client then proves the expected local remotes, attributes, namespace values, or
generated endpoints before its non-yielding adapter setup. Warp's endpoint is
required and cached before setup. Callback attachment alone is not readiness
for generated libraries that can replay queued traffic.

The route retains the existing receiver-before-sender warmup, deterministic
fixtures, payload/order/cardinality/input-preservation checks, 60-frame quiet
windows, clock proof, measured boundaries, teardown observation, and final
evidence validation. Process exit is the cleanup boundary for singleton queues,
schedulers, registries, and libraries without public listener removal.

## Trust boundary and non-claims

The capability excludes benchmark scripts that cannot read the destroyed
server-only carrier. It does not defend against a same-user local process that
can read launch files or against an operator-selected malicious Studio
executable; the local OS account and selected executable remain trusted.

Third-party decoders and all network bytes remain attacker-controlled for
production security purposes. A measured correctness-valid result is not a
malicious-input decoder audit, redistribution certification, or general product
security approval. It supports comparison only inside the exact matching Result
V1 case, topology, lane, broadcast mode, source, contract, and environment
cohort.
