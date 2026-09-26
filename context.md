# Relay Context

## Purpose and boundaries

Relay is a standalone Roblox fixed-schema reliable-event library. Publishable
source lives under `src/`; it has no game repository or Core dependency.
The package is `steven-dinh/relay` version `0.1.0`, realm `shared`, with no
runtime, server, or development dependencies. Wally publication is disabled
with `private = true`. Tool versions are pinned in `rokit.toml`.

The public surface is frozen to `VERSION`, `define`, `createServer`, and
`createClient`. Sessions expose `events`, `Start`, and idempotent `Destroy`.
`src/init.luau` types the public calls, required options, and field variants;
event names and payload tuples are not inferred from a definition. Runtime
validation remains authoritative.
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
| `src/internal/TokenBucket.luau` | Bounded token buckets, saturating refill, a monotonic clock clamp, and optional caller-supplied time. |
| `src/ServerSession.luau` | Server transport ownership, current-player admission, handler leases, dispatch, sends/broadcasts, and cleanup. |
| `src/ClientSession.luau` | Single-deadline discovery, descriptor matching, module-slot ownership, dispatch, cancellation, terminal transport loss, and cleanup. |

Definitions allow at most 16 events and eight fields per event. The twelve field
types are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`, `Vector2F32`, `Vector3F32`, and `CFrame`.
Signed integer base ranges are -128..127, -32768..32767, and
-2147483648..2147483647. Both integer families share exact-integer validation,
optional inclusive narrowing bounds, and canonical positive zero. Definition
encodes signed bounds as decimal tokens under the existing `RR1` descriptor;
legacy descriptors remain unchanged. Numbers remain native tuple values, with
no integer codec or byte-width promise and unchanged one-token admission costs.
Definition/frame tests cover signed descriptors, bounds, rejection, and exact
returns. The Studio fixture uses `schema-native-values` for C2S, targeted S2C,
and broadcast delivery of both signed extrema, Vector2 components, exact
string bytes, and CFrame values; existing
scenario checks remain. Vector2F32 requires finite Float32-exact scalar bounds
for both components, uses `v2f32` descriptor tokens, and retains native Vector2
values as one field. Definition/frame checks cover its grammar, normalization,
rejection, and tuple arity; native fixture checks scalar parity, precision,
subnormals, and zero signs in both runtimes.
String fields have exactly name/type/maximumBytes keys; the required limit is
an integer in 0..1024, encoded as `str,-,<limit>`. Frame binds the byte limit once,
checks native type and length, and returns the immutable string unchanged.
Empty strings, NUL, and non-UTF8 bytes are valid within bounds; no text parsing
or coercion occurs. Eight fields imply at most 8192 accepted string-content bytes
without packet summation metadata. Native wire overhead and engine allocation
before Relay ingress are not covered. The existing one-token admission remains.
Portable tests cover the grammar, descriptors, byte boundaries and exact tuples;
correctness-mode Studio checks require overlong-drop and observable per-player
and aggregate consumption through valid follow-up calls.
CFrame uses required Float32-exact translation bounds and descriptor code `cf1`.
Frame reads twelve native components into locals, checks finite bounded position
and rotation entries in [-1.0001,1.0001], then column squared-norm residuals,
pairwise dot products, and determinant-minus-one residual, each <=1e-4 absolute.
Accepted approximately orthonormal right-handed native values are returned
unchanged, including local zero signs; there is no reconstruction or repair.
Eight fields imply at most 96 fixed CFrame components; no wire-width promise.
The Studio correctness fixture adds eleven predetermined source cases and
independent raw observations on the existing Reliable remote in all three send
paths. JSON retains components, zero signs, invariant residuals, validity,
translation/rotation maximum deltas, and separate handler delivery. Stable
accepted cases require exact chosen translation and <=1e-4 rotation-component
error; source-invalid rotation may change in native serialization, so received
validity controls expected dispatch. Raw translation overflow must still drop.
The native tolerance is empirical qualification for these cases, not a universal
remote precision guarantee. The host requires bounded case/client/direction
identities and keeps result bodies up to 131072 bytes for this finite evidence.
Definition scans stop at the structural ceiling plus one. Session construction
compiles one validator per event, binding field types/bounds and one of the
zero-to-eight argument bodies. Packet validation checks exact arity before
normalization and rejects at the first invalid field. Verified finite bounds
select positive inclusive interval checks at construction, rejecting NaN and
infinities without separate per-value finite checks. Internal records with
nonfinite bounds retain explicit finite checks. Validators return a success flag
followed by the exact normalized tuple; sessions forward those per-invocation
values without creating or unpacking a payload array. It does not
traverse attacker-provided tables, strings, buffers, or Instances.
Exact zero-field tuples return only the success flag. Vector2F32/Vector3F32
validation checks native Float32 components directly for finiteness and bounds,
then canonicalizes zero signs. Scalar f32 values return canonical zero after
input checks for exact zero; nonzero values still round through a buffer.
The server binds the endpoint ID separately and forwards only payload arguments.

The server owns one `ReplicatedStorage.RelayRemotes` Folder with exactly
`Definition` StringValue and `Reliable` RemoteEvent leaves. Integrity observers
attach after initial parenting and before activation. Once active, observed
owned-instance mutations are terminal, even if restored before deferred
callbacks run. Packet paths use cached references; storage-wide uniqueness
checks belong to startup and storage-change observers.
Transport classes are established at server construction or client discovery;
packet checks inspect mutable names, parents, descriptor value, and child count.
Both distinct cached leaves must still be parented to the root, so a count of two
proves exact membership without repeating class or child-order comparisons.
Startup's preexisting-root check uses a direct name lookup. Cleanup checks for
any direct child with `FindFirstChildWhichIsA("Instance")`, preserving foreign
descendants without allocating a child array. Production never calls `GetDescendants`.

Inbound tuples are attacker-controlled. The private roster establishes immutable
Player type/class once; receive checks live parentage before rate admission.
Current-player admission and finite per-player/aggregate rate limits precede
payload validation. Compiled validators own exact payload arity. Per-player
exhaustion cannot debit the aggregate bucket. Eligible ingress samples the server
clock once for both buckets; each retains its own refill and monotonic clamp.
Aggregate refill is evaluated at the player-admission instant. Internal supplied
timestamps share the constructor clock's domain; omitted timestamps read that
clock. There is one handler per
player/endpoint, at most eight per player and 64 server-wide; clients allow one
handler per endpoint. Reservations are transactional and survive listener
replacement. Removal/destruction invalidates old leases without reinserting state.
Server handler-cap checks follow rate admission and precede payload normalization;
reservations are written only after validation and released when the protected
handler returns, without a separate per-dispatch lease table. Both session sides
reuse a protected transport helper instead of creating a closure for each send.
Rejections retain no payload diagnostic, response, log, or queue. Cleanup does
not recursively delete foreign descendants.

Client discovery and final activation share one startup deadline, including
late child arrivals and deferred continuations. A pending child lookup holds one
ChildAdded listener and one timeout task. Arrival, timeout, or Destroy settles
the wait once and releases both resources; cancellation resumes Start with
Destroyed on a deferred continuation. The attempt token prevents a queued
arrival from activating a destroyed client or affecting a replacement session.

Game code owns authorization, semantic validation, and trusted-handler work.
Send success means local transport handoff, not receipt. Relay provides no
persistence, game policy, readiness handshake, automatic reconnect, retry,
batching, RPC, or middleware. Admission limits are not network-availability or
DDoS protection and do not promise fairness.

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
| `benchmarks/quick/` | One-client Studio Play diagnostics over one selected workload, with persistent adapter instances, short warmup/measurement, Output summaries, and in-session reruns. |

Unqualified runner filenames in the table are under `benchmarks/runner/`.
External adapter prewarm shares one 120-second deadline across replication and
module initialization. Readiness and module completion are accepted only before
that deadline, and unfinished module workers are cancelled on failure. Portable
runner tests cover timely, expired, and unhealthy-clock completion paths.
The quick benchmark has its own Rojo project and optional pinned-library builder.
It accepts dirty local source and never emits Result V1/V2 or ranking evidence.
Each adapter initializes once per Play session; changing workload/schema or
source requires Stop/Play. Client-driven control has exact server-owned phase
ordering, a single-player roster, bounded waits, and terminal aborts. Receivers
copy only the fixed primitive field shapes into bounded buffers; full delivery,
order, and input-preservation checks run after timing. Quick runs use local
clocks and raw engine-wide send-rate diagnostics, with all selected libraries
resident in the same process. Their setup and retained background work differ
from canonical isolation. No production transport or shared measurement code
changes are involved. `benchmarks/tests/quick-benchmark.luau` covers the private
fixtures, shape bounds, invalid configuration, comparisons, and compilation;
the foundation gate also builds the quick place without launching Studio.
`SchemaFixtures.luau` owns four separate Relay-only C2S payloads: signed integer
tuples, Vector2, fixed 64-byte strings, and native CFrame. `SchemaRelay.luau`
binds these fixtures through the existing public Relay API and admission profile.
Model selects their fixed arities and bounded capture/comparison rules; Session
rejects other adapters and receive profiling before creating resources. Existing
Event V1 contracts, fixtures, adapters and default quick Config remain unchanged.
CFrame local input checks preserve all components and zero signs exactly;
receive comparisons require exact fixture translation and finite rotation
differences within 0.0001. Ordinary and profiled source mappings both include
these modules so legacy profile snapshots remain self-contained.
Dedicated design and implementation review covered the private control remote.
Studio smoke checks passed two in-session runs for all nine adapters on State
burst, State broadcast, and Tiny round trip; broadcast/probe checks used shortened
fixtures. Abort during a yielding broadcast request remained terminal and
rejected a subsequent Start. These checks establish execution and rerun behavior,
not comparative performance evidence.
Terminal quick failures also publish `Failed` and an invalidation warning while
idle. Clients observe the server failure attribute and forward local failures
through the existing Abort command. Returned rows share session validity so a
later failure invalidates earlier reruns without retaining their result arrays.
Send rate is labeled KB/s, matching the engine's kilobytes-per-second value.
Focused runner checks cover idle failure propagation, prior-row invalidation,
one-time teardown/Abort, rejected reruns, and the output unit.
Studio checks also passed late-delivery injection on each side after two completed
runs, confirming replicated failure status and invalidation of both returned runs.
Each quick run now measures three rounds, rotates adapter order across rounds
and reruns, and reports the median and min/max of per-round metrics. Each round
has distinct fixture sequences and retains the configured warmup/measured counts.
Public-call timing and a separate unsubtracted no-op floor use the same timed
loop. Offered rate remains sender-paced. A server-owned Drain phase acknowledges
receipt before Finish's quiet interval and full verification; delivery-confirmation
duration uses only sender-local timestamps and includes control/scheduling overhead.
Raw rounds and aggregate statistics are returned alongside shared session validity.
Rounds also retain bounded `callSamples`, `frameSamples`, and `floorSamples`
arrays in seconds after timing; no timing loop or canonical result format changes.
Duplicate mean summaries are computed once while preserving existing metric names
and independent result tables. Focused checks also preserve absent receive metrics
for unprofiled runs.
Focused checks cover rotation on both sides, disjoint sequences, delayed delivery,
exclusion of quiet/verification from confirmation, the unsubtracted calibration,
and invalid/aborted Drain requests. Dedicated design/security and implementation
review covered the new phase and timing boundaries.
Studio smoke checks passed two consecutive three-round runs for all nine adapters
on each of State burst C2S, State broadcast S2C, and Tiny round trip: 54 adapter-round
results per case. Shortened fixtures verified execution, metric shape, and reruns;
they do not establish comparative performance. The foundation gate also passed.
Normal departure after a completed quick run now closes the session without
invalidating successful results. A final zero-argument Complete acknowledgement
establishes that both sides finished validation before allowing normal closure.
Incomplete runs, interrupted reruns, and genuine late faults remain terminal
failures. Closed sessions reject new work and release each adapter once.
Focused lifecycle checks cover closure, final acknowledgement ordering, departure
during reruns, queued faults after closure, and idempotent cleanup.
Dedicated design/security and implementation review passed. A real solo Studio
Play check completed two full default runs and normal shutdown without a failure
warning; the foundation gate passed as well.
Round-trip echo waits use the remaining phase deadline and reject a final reply
after expiry. Focused regressions cover cumulative waits and late polling while
preserving receive-timestamp RTT and public-call timing.

The quick broadcast upgrade adds `state-broadcast-burst-s2c` with four State
broadcasts per frame, public-call mean/median/p95, and a sender-local
acknowledgement tail from the exact final submission return. Existing frame
intervals, confirmation and RTT keep their separate meanings. Burst call samples
are frame-batch duration divided by four, not individually timed messages.
`CallbackTiming.luau` owns opt-in bounded receive recordings;
`ReceiveInstrumentation.luau` and the quick builder generate unique isolated
native/Relay source copies with hashes. Every project input, including fixtures,
contracts and shared support code, is snapshotted under the profile directory;
the manifest also hashes the finished project and place. Only State S2C quick
cases support this profile. Timers wrap the original receive bindings, preserve
callback behavior, and retain raw samples per round. Profile labels distinguish these diagnostics
from ordinary quick results; production source and canonical contracts are
unchanged. `benchmarks/tests/quick-receive-profile.luau` covers the recorder,
source generation and complete snapshot provenance; the existing quick test
covers workload/metric integration.

`benchmarks/host/BroadcastStudy.luau` and `run-broadcast-study.luau` schedule
fresh canonical State-broadcast sessions for one 1/4/8-recipient topology.
Native, baseline, identical control and an optional candidate run in forward
and reverse order. The driver reuses HostRuntime publication and Result V2
validation, pins clean source and Studio identities, and retains attempts,
logs, hashes and separate timing summaries in ignored local ledgers. Result
validation and summaries consume the same verified bytes that were archived,
so later source-result changes cannot alter their recorded meaning. Plan mode
does not launch Studio. `benchmarks/tests/broadcast-study.luau` covers ordering,
provenance, freshness, failure retention and compatibility without native timing.
The upgrade passed the foundation gate, focused burst/profile lifecycle checks,
and a real profiled Rojo build with inspection of the generated callback bindings.
Independent implementation review resolved the host-pinning, bounded-log and
profile-invalidation findings. Follow-up review fixed result-archive consistency
and complete profile dependency provenance. Their regressions, the foundation
gate, and an isolated CLI profile build with project/place hash checks passed.
Follow-up native checks passed four Studio smoke sessions: steady and burst
broadcast, each unprofiled and receive-profiled, with two complete three-round
native/Relay runs per session and confirmed process exit. These shortened
fixtures establish execution, delivery and rerun validity, not performance.
Fresh canonical collection exposed omitted optional environment metadata in the
study compatibility key. The key now preserves missing field positions, and a
focused regression accepts schema-valid omissions while distinguishing them
from present metadata. The failed collection attempt remains retained separately.

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
Host ingestion and file reporting reject negative zero and nonzero JSON numbers
that underflow to zero before decoding, preserving publication/reader parity.

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
and repeated-validator tuple isolation across yields. Frame tests also check
nonfinite internal bounds and exact success/rejection return counts; both session
suites check all arities, false boundary fields, normalized scalar forwarding,
reentrant dispatch, and invalid-payload precedence during deferred corruption.
Client tests also cover all discovery cancellation stages, competing completion
paths, stale callbacks, expired arrivals/resumptions at each discovery stage,
shared deadlines, and replacement-session isolation.
Server tests reject departed roster members before debiting rate buckets.
Token-bucket tests cover supplied-time refill boundaries, backward-time clamps,
saturation, and fallback clock reads. Server tests verify one clock read for each
eligible attempt, including malformed and rate-rejected ingress, and no reads
for unrostered or departed senders.
Scalar Float32 tests preserve signed-zero and zero-excluding bound behavior.
Session tests also reject same-count
transport-leaf replacements before deferred observers run. Server tests cover
direct versus nested reserved names and preserve foreign children under each
owned instance during cleanup. The gate does not launch Studio. Real Studio
verification is explicit through `tests/studio-reliable-events.luau` or the
benchmark host; the correctness fixture verifies native Vector3 storage and
numeric parity with scalar Float32 normalization on both runtime sides. It also
checks prompt startup cancellation in Roblox's scheduler.
The proof fixture allows 60 seconds for participant startup and reports expected,
present, and ready counts on failure; operational waits remain 30 seconds.
Its optional `--correctness-only` launcher flag selects two-client correctness;
the default still runs the complete correctness/admission matrix.
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
