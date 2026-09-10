# Relay Context

## Purpose and boundaries

Relay is a standalone Roblox fixed-schema reliable-event library. Publishable
source lives under `src/`; it has no game repository or Core dependency.
The package is `steven-dinh/relay` version `0.1.0`, realm `shared`, with no
runtime, server, or development dependencies. Wally publication is disabled
with `private = true`. Tool versions are pinned in `rokit.toml`.

The public surface is frozen to `VERSION`, `define`, `createServer`, and
`createClient`. Sessions expose `events`, `Start`, and idempotent `Destroy`.
Direction-specific event handles expose `Connect`, `Send`, or `Broadcast`;
listener connections expose idempotent `Disconnect`. Expected failures return
frozen `{ code, message }` errors. See [README.md](README.md) for usage and options.

Definitions, compiled records, session/event/connection handles, errors, and
module exports are frozen. Internal modules are not additional public API keys.

## Runtime ownership

| Module | Responsibility |
| --- | --- |
| `src/init.luau` | The four-key public surface and version. |
| `src/Definition.luau` | Closed authoring grammar, opaque definition identity, immutable compilation, deterministic `RR1` descriptor, and Float32 canonicalization. |
| `src/internal/Frame.luau` | Constant-time endpoint/direction lookup and construction-time compilation of fixed-arity validators with prebound field normalization. |
| `src/internal/TokenBucket.luau` | Bounded token buckets, saturating refill, and a monotonic clock clamp. |
| `src/ServerSession.luau` | Server transport ownership, current-player admission, handler leases, dispatch, sends/broadcasts, and cleanup. |
| `src/ClientSession.luau` | Single-deadline discovery, descriptor matching, module-slot ownership, dispatch, cancellation, terminal transport loss, and cleanup. |

Definitions allow at most 16 events and eight fields per event. The six field
types are `boolean`, `u8`, `u16`, `u32`, `f32`, and `Vector3F32`.
Definition scans stop at the structural ceiling plus one. Session construction
compiles one validator per event, binding field types/bounds and one of the
zero-to-eight argument bodies. Packet validation checks exact arity before
normalization, rejects at the first invalid field, and allocates a fresh result
only after all fields pass. It does not
traverse attacker-provided tables, strings, buffers, or Instances.
Exact zero-field tuples reuse an internal frozen empty payload. Vector3F32
validation checks native Float32 components directly for finiteness and bounds,
then canonicalizes zero signs; scalar f32 values still round through a buffer.
The server binds the endpoint ID separately and forwards only payload arguments.

The server owns one `ReplicatedStorage.RelayRemotes` Folder with exactly
`Definition` StringValue and `Reliable` RemoteEvent leaves. Integrity observers
attach after initial parenting and before activation. Once active, observed
owned-instance mutations are terminal, even if restored before deferred
callbacks run. Packet paths use cached references; storage-wide uniqueness
checks belong to startup and storage-change observers.

Inbound tuples are attacker-controlled. Current-player admission and finite
per-player/aggregate rate limits precede payload validation. Per-player
exhaustion cannot debit the aggregate bucket. There is one handler per
player/endpoint, at most eight per player and 64 server-wide; clients allow one
handler per endpoint. Reservations are transactional and survive listener
replacement. Removal/destruction invalidates old leases without reinserting state.
Server handler-cap checks follow rate admission and precede payload normalization;
reservations are written only after validation and released when the protected
handler returns, without a separate per-dispatch lease table. Both session sides
reuse a protected transport helper instead of creating a closure for each send.
Rejections retain no payload diagnostic, response, log, or queue. Cleanup does
not recursively delete foreign descendants.

Game code owns authorization, semantic validation, and trusted-handler work.
Send success means local transport handoff, not receipt. Relay provides no
persistence, game policy, readiness handshake, automatic reconnect, retry,
batching, RPC, or middleware. Admission limits are not network-availability or
DDoS protection and do not promise fairness.

## Optimization research and decisions

[Assess Packet networking library](codex://threads/01a008e0-5c6d-7242-9ebc-dcd5dde4a6b8)
and [Research Roblox optimization tools](codex://threads/01a040be-7574-7fe2-8708-fb2968f5842a)
provide the research basis. Startup-compiled field validators and fixed-arity
execution apply the runtime-schema and specialization findings. Compact bounded
buffer codecs were tested as an isolated RR2 prototype on
`codex/buffer-codec-prototype` (38a1595), based on tuple baseline e096d0c.
The prototype passed dedicated design/security and patch reviews, the foundation
gate, and the full Studio correctness/admission matrix. Its initial paired RTT
p95 exceeded the predeclared regression ceiling; different pre-launch CPU loads
also limit attribution. It remains unpromoted pending more comparable evidence.
The active transport remains RR1 tuples. Batching needs a separately
reviewed flush/queue contract that preserves an immediate path. AOT tooling,
XOR/delta state, and lossy vectors remain workload-dependent experiments.
Validation CPU diagnostics do not establish end-to-end networking gains.

## Benchmark ownership

Benchmark code stays outside the Wally package. [benchmarks/README.md](benchmarks/README.md)
owns execution, timing, lifecycle, reporting, and trust-boundary rules;
[the adapter guide](benchmarks/adapters/README.md) owns external binding details.

| Area | Responsibility |
| --- | --- |
| `benchmarks/contracts/` | Event V1 workloads, version-specific Result/HostManifest wrappers, shared private schemas, repetition fragments, and bounded terminations. |
| `benchmarks/fixtures/`, `correctness/` | Deterministic fresh inputs, payload comparison, exact order/cardinality, and delivery ledgers. |
| `benchmarks/adapters/` | Closed adapter contract, native/Relay bindings, and eight pinned external bindings. |
| `benchmarks/runner/BenchmarkClock.luau`, `TimingRecorder.luau` | Guarded clock reads, timing boundaries, raw samples, and immutable evidence. |
| `RunState.luau`, `RunnerKernel.luau`, `CaseRunner.luau`, `KernelFanout.luau` | Bounded phases, workload/probe execution, generation state, and trusted fanout. |
| `SessionOwner.luau`, `DeliveryRouter.luau`, `GenerationActivation.luau` | Construction, stable delivery routing, readiness, activation, rollback, and cleanup. |
| `ControlProtocol.luau` | Exact remote-message shapes, roster/sequence/replay bounds, barriers, deadlines, and clock admission. |
| `Coordinator.server.luau`, `Participant.client.luau` | Distributed execution, receiver-before-sender ordering, participant evidence, and server-only finalization/`EndTest`. |
| `ExternalReadiness.luau`, `AdapterAllowlist.luau` | Closed identities, untimed module prewarm, and exact replication/readiness predicates. |
| `PersistentTransport.luau` | One physical adapter side per participant, continuous observation across logical windows, and final session cleanup. |
| `ResultDraftAssembler.luau` | Projection of validated run evidence and complete legacy fragment sets into result drafts. |
| `benchmarks/host/` | Clean-source and artifact verification, selected-only builds, authenticated bounded collection, exit confirmation, and no-overwrite publication. |
| `benchmarks/reporting/` | Bounded JSON reads, strict V1/V2 validation, compatible comparison groups, and non-valid evidence separation. |
| `benchmarks/pilot/` | Opt-in, non-ranking QuickNet/Zap lifecycle development checks, not measured Result evidence. |

Unqualified runner filenames in the table are under `benchmarks/runner/`.
The adapter lock is `benchmarks/libraries.lock.json`; acquisition and deterministic
generation are owned by `scripts/acquire-benchmark-libraries.luau` and
`scripts/generate-benchmark-adapters.luau`. Downloaded or generated code is not
edited or committed. Suphi-Packet has a recorded author grant but remains
timing-ineligible because its sender-frame bound cannot be proven.

`PersistentBenchmark` uses Result V2's `event-session-v1` profile: one fresh
Studio session per exact adapter/case/topology, with 30 logical windows and a
required passed session proof. Legacy Result V1 retains its distinct lifecycle
identities and shapes. Both readers recompute summaries; only even medians have
the tested one-adjacent-binary64-value serialization allowance. Neither reader
repairs samples or accepts arbitrary numeric tolerances.

Persistent windows retain physical receivers and disjoint expected fixture
ranges. Late, stale, malformed, or between-window deliveries latch failures;
they are not discarded at a window boundary. Clients close/check physical
ownership before final reports; the server observes until those reports arrive,
then closes/checks before freezing evidence. Publication also requires confirmed
Studio exit.

Correctness is separate from timing. Setup, prewarm, replication/readiness,
warmup, and two 60-frame quiet windows per repetition remain outside measured
regions. Clock startup requires two full-roster readiness passes followed by
formal admission. The fixed 3 ms bracket allowance applies only to persistent
shared-clock admission; legacy admission has zero allowance. Local clock
checks remain strict. Shared-clock durations are diagnostic, not ranking inputs
or a claim of 3 ms clock accuracy.

V2 separates common measurement, adapter artifact, whole-place, and Git
provenance. `MeasurementFingerprint.luau` covers all Luau bytes in runner,
contracts, correctness, and fixtures, plus the explicit composition/adapter
contract inputs; unknown executable roots fail closed. Documentation and reporter
edits do not change that fingerprint. Changed measured inputs require a
compatible new cohort, not relabeling old evidence.

Comparisons require matching case, topology, lane, broadcast mode, lifecycle,
contract, source compatibility, and environment. Dirty provenance and duplicate
run IDs are rejected. Runs remain individual rows; samples and incompatible
profiles are not pooled. There is no overall winner score. One warm process is
not 30 independent process samples, and a machine identity snapshot does not
prove stable CPU/GPU load or temperature.

The local OS account and selected Studio executable are trusted. Collector
capabilities, bounded parsing, roster checks, and source checks do not certify
third-party decoders against malicious bytes or establish production security.

## Verification and repository hygiene

Run the portable gate from the repository root:

```text
lune run scripts/verify-foundation.luau
```

It runs the registered runtime and benchmark checks, validates the exact cached
Git file allowlist, LF/trailing-whitespace rules, ignore boundaries, Wally package
contents, real Rojo builds, and CI triggers. Because its file inventory reads
the Git index, stage intended file additions/deletions before this gate.
Offline external build checks use minimal test modules to verify composition;
they do not substitute for qualification with actual pinned library codecs.

Use the nearest existing focused test during development. The gate includes
contract rejection cases, host framing/provenance/cleanup, persistent lifecycle,
and reporter compatibility checks; server tests also cover both rate debits for
busy-endpoint rejection and exact empty tuples. Frame tests cover vector signed
zeros and subnormal components, every compiled arity, position-specific rejection,
and repeated-validator result isolation. The gate does not launch Studio. Real Studio
verification is explicit through `tests/studio-reliable-events.luau` or the
benchmark host; the correctness fixture verifies native Vector3 storage and
numeric parity with scalar Float32 normalization on both runtime sides.
External payload/reuse qualifications are opt-in and need pinned
local inputs. Do not use the full measured matrix as the debugging loop.

`AGENTS.md`, `README.md`, and this map are durable contributor documentation.
Private plans/reports under `docs/`, `.tmp/`, Forge artifacts, dependencies,
benchmark vendors/generated runtimes, and local results stay ignored. CI runs
on pushes to `main` and all pull requests.

Any future remote, decoder, serializer, transport, batching, RPC, or middleware
change requires a dedicated design and security review. Keep changes surgical,
update this map when ownership or guardrails change, and never commit third-party
source or local benchmark results.
