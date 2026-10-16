# Relay Context

## Purpose and boundaries

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. Publishable source lives
under `src/`; it has no game repository, Core, or runtime dependency.

The Wally package is `steven-dinh/relay` version `0.2.0`, realm `shared`.
Publication is disabled with `private = true`. Tool versions are pinned in
`rokit.toml`, including Lune `0.11.0` (Luau `0.740`).

GitHub releases attach only the Relay `.rbxmx` model and source ZIP. Example
places, Wally ZIPs, installation files, manifests, and checksums are not release
attachments.

The public GitHub Pages site is plain dark, static documentation in
`docs/index.html` and `docs/styles.css`, with `docs/.nojekyll` bypassing Jekyll.
It has home/version notes and general, types, events, functions, cleanup, and
benchmark sections, linking to `docs/reference.md` for the detailed API contract.
README.md is the short repository overview and quick start.
The site and main API reference describe development source, which may differ
from a published release with the same version constant. Starting with v0.2.0,
published release tags preserve their API reference; README, reference, and site
link to the published v0.2.0 reference. The public-type gate checks these documentation links.
The API reference's Environment, support, and reporting section separates tested
native source/build evidence from runtime and new-solver requirements, and routes
ordinary minimal bug reports to GitHub issues. A private security-reporting route
is enabled through GitHub. `SECURITY.md` owns private reporting, coordinated
disclosure and best-effort maintenance: the newest released minor series' latest
patch, a seven-calendar-day acknowledgement target, compatible patch releases,
documented pre-1.0 breaking minor releases and one-release deprecation notice
except for urgent security corrections. Releases follow verification rather
than a calendar. The root policy is included in the checked package inventory;
these policies do not expand native qualification or promise a fix deadline.
Benchmark tables mirror `benchmarks/README.md`, keeping the September 26
Native/Relay snapshot separate from the historical multi-library comparisons,
with workloads, Studio/broadcast groups, measured versions, revisions, and timing
units intact. Canonical workload tables lead with inverse-median sender FPS,
Native-relative scales, and sorted ranks; uncaptured bandwidth stays Unmeasured.
The audited October 7 quick cohort has separate FPS-sorted local diagnostic
tables with measured engine-wide KB/s and exact verified counts, keeping broadcast
modes separate. Tooling links cover quick runs and receive profiling.
It has no logo, scripts, runtime dependencies, or build step. GitHub Pages serves
https://steven-dinh.github.io/relay/ from `main`'s `/docs` folder; other `docs/`
contents stay ignored.

The approved public surface is `VERSION`, `schema`, `define`, `inspect`,
`createServer`, and `createClient`. Sessions expose `events`, `requests`,
`Start`, `GetDiagnostics`, `CreateBatch`, `CreateState`, and idempotent `Destroy`; clients also
expose `RefreshReadiness`.
Event handles expose direction-specific `Connect`, `Once`, `Send`, `Broadcast`, `SendTo`, and `SendExcept`;
ServerToClient server handles also expose `GetReadyPlayers`.
connections expose idempotent `Disconnect`. Expected failures return frozen
`{ code, message }` errors. Definitions, compiled records, handles, and exports
are frozen; internal modules are not public exports.

Static payload derivation requires Luau's new solver and ordered type metadata.
`Relay.schema` supplies frozen constructors, field naming, reusable shapes, and
bounded whole-map composition with exact inferred event keys;
raw records and the original ordered example helper remain compatible. The pinned
solver still needs singleton struct names/enum values and parentheses around a
final builder call in multi-entry ordered/struct arguments. Keep schema and
session variables inferred. Runtime validation
remains authoritative. [The API reference](docs/reference.md) owns usage, schema
grammar, options, error codes, and the
[protocol contract](docs/reference.md#protocol-and-abuse-limits).

## Runtime ownership

| Module | Responsibility |
| --- | --- |
| `src/init.luau` | Public exports, version, and schema-derived event names, methods, and payload types. |
| `src/Schema.luau` | Frozen authoring constructors, ordered type metadata, and bounded literal-map composition with collision rejection; definitions independently copy reused shapes. |
| `src/Definition.luau` | Closed schema grammar, opaque definition identity, immutable bounded shape compilation, deterministic descriptors, Float32 canonicalization, and bounded setup path errors. |
| `src/internal/Frame.luau` | Endpoint/direction lookup, compiled fixed-arity primitive validators, and decode-specific scalar normalizers. |
| `src/internal/CompositeCodec.luau` | Bounded composite validation, buffer encoding, and checked decoding using Frame's scalar normalizers and raw checks. |
| `src/internal/TokenBucket.luau` | Bounded token buckets, saturating refill, and monotonic clock clamping. |
| `src/internal/Diagnostics.luau` | Fixed saturating counters, immutable snapshots, and exact local handoff units; no traffic-keyed state or payload retention. |
| `src/internal/RpcFrame.luau` | Fixed RPC envelope, checked correlation identity and body bounds before owned copying. |
| `src/internal/ReadinessFrame.luau` | Fixed format-2 Hello/Challenge/Ack/Close framing with exact direction, counter, GUID, and mask validation. |
| `src/internal/BatchFrame.luau` | Fixed format-2 counted envelope, complete bounded record metadata scan and checked owned body copies for batch ingress. |
| `src/internal/Batch.luau` | One-shot FIFO body ownership, channel byte/count caps, one deadline timer, shared flush guard, immutable partial-handoff reports and terminal cleanup. |
| `src/internal/StateQueue.luau` | Latest unsent encoded snapshots, four lanes sharing 64 keys/16384 pending bytes, deterministic priority/age selection, first-dirty expiry, one timer per lane, and shared queue cleanup. |
| `src/ServerSession.luau` | Transport ownership, current-player admission, shared event/RPC handler leases, dispatch, bounded RPC replay identities and replies, encode-once audiences, optional readiness challenges and ready-player snapshots, explicit FIFO batches/state lanes, and cleanup. |
| `src/ClientSession.luau` | Deadline-bound discovery and requests, descriptor matching, module-slot ownership, dispatch, request correlation/cancellation, optional listener-readiness handshakes and refresh, explicit FIFO batches/state lanes, transport loss, and cleanup. |

## Runtime invariants

- Definitions allow at most 16 events/requests combined, unique IDs across both
  maps, and eight fields per event/request. Primitive kinds
  are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`,
  `Vector2F32`, `Vector3F32`, and `CFrame`. Composable shapes are bounded structs,
  dense arrays, enums, optionals, and primitive-key sets; arbitrary maps and
  recursive shapes are unsupported.
- Invalid definitions return fresh frozen setup errors with validated paths/reasons
  capped at 256 bytes; packet errors retain the cached generic records. Diagnostic
  construction never stringifies attacker values or retains rejected schemas.
- Definition inspection exposes exact Relay-buffer bounds or native string-content
  bounds with unknown Roblox encoded size. Session diagnostics preserve first-reason
  guard/admission order and saturate 15 totals plus 8/event at u32 maximum; no player,
  payload, stack or callback retention. Terminal snapshots report zero active leases.
  Once consumes only an admitted dispatch, detaches before callback, and preserves
  yielding leases and the client validator for replacements until terminal cleanup.
- Server send audiences are invocation-owned plain arrays bounded to 1024 entries
  and recipients. SendTo/SendExcept deduplicate Player identity, skip departures,
  validate/encode once, and report successful handoffs before partial failure.
  Empty audiences still validate; full Broadcast uses FireAllClients unchanged.
  Private roster membership proves immutable Player type/class; send and readiness
  paths still check current parentage before handoff or inclusion.
- Primitive-only definitions use `RR1` for reliable-only events and `RR2` when
  any event is unreliable. Definitions containing a composable shape use `RR3`.
  Startup requires an identical descriptor and matching transport topology.
  Primitive-only events use native tuples even within an RR3 definition;
  composite events encode their entire tuple into one buffer.
- Requests select RR5 and force Reliable codec bodies, including primitive-only
  shapes. The format-1 RPC envelope has a 44-byte identity header, at most 8148
  body bytes and 8192 complete raw bytes. Request/response shapes independently
  retain existing depth/node/container limits. Client sessions own at most eight
  pending requests and one per method, with nonreused u32 call IDs, actual-session
  GUID correlation, finite deadlines at most 60 seconds and one waiter per handle.
  Cancellation is local; late responses cannot settle a replacement request.
  Server RPC shares event buckets/leases and keeps at most 64 recent identities
  plus eight active identities per actual Player; no durable exactly-once claim.
  Event-only servers omit RPC replay state; fixed RPC codec results use scalar
  locals while protected handler results retain exact return-count checks.
  Validated request values forward directly to protected handlers; pending client
  records share the session settlement function without a per-request closure.
  Fixed failure replies carry no exception text. False and explicit optional nil
  are valid single responses. Terminal cleanup releases timers and pending closures.
  The corrected frozen RPC/audience/Once snapshot passed 21 checkpoints with two
  actual Studio clients (`.tmp/relay-proof-f18e3b170254476fa6440d3ab93179a4.json`),
  including deadlines, cancellation and late replies. This proof excludes the
  later readiness and batch runtime integration; its initial failed attempt is retained.
- Readiness/queue metadata selects RR6, with exact legacy descriptor preservation
  when disabled/absent. Queued capable events have a separate forced-codec record
  bounded to 8187 Reliable/895 Unreliable body bytes and separate inspector bounds.
  Optional readiness requires one ServerToClient event, maps those IDs in ascending
  order into a 1–2-byte mask at the current 16-entry cap, and admits reliable
  format-2 controls through player-first then aggregate charging before parsing.
  One readiness record stays on each actual roster Player; RefreshReadiness is a
  local handoff with no automatic retry, and GetReadyPlayers returns a fresh,
  bounded claim snapshot. Portable tests and Sol review pass; the integrated
  0.2.0 two-client Studio fixture passed readiness checkpoints.
  Readiness uses precomputed mask positions and a shared frozen Hello header.
- Explicit FIFO `CreateBatch` is available on started sessions for their sending-
  direction queue-capable events. A sender owns one open batch and up to 32
  records across both channels, with each complete raw channel frame capped at
  8192 Reliable/900 Unreliable bytes. Server batches capture a fixed recipient
  snapshot of at most 1024 Players; client batches target their server. Accepted
  values are encoded immediately. The first submit fixes one deadline timer of
  at most 100 ms; Flush sends Reliable before Unreliable, caches its frozen
  six-number handoff report, and does not retry failures. C2S format-2 kind-1
  ingress pays one player-first/aggregate token pair per declared logical record
  before record scanning, body copying, or decode. The whole frame is scanned and
  decoded before callbacks; malformed frames produce no partial dispatch.
  Dispatch holds decoded tuples beside checked row metadata without allocating
  another wrapper table per record.
  Portable frame, queue, session, type checks and Sol review pass. The integrated
  0.2.0 two-client Studio fixture passed scheduler, callback-start order and
  transport checks as part of its 23 checkpoints.
- Explicit CreateState uses the same private queue owner, current-player
  handoff, monotonic clock and flush guard. State-capable events also permit
  FIFO batching; kind-2 ingress admits only State-capable events under the same
  complete-frame rejection and logical charges. Four lanes share 64 active keys
  and 16384 pending body bytes. Put owns and atomically replaces one unsent
  lane/event/u32 key. Priority, first-dirty age, event ID and key determine bounded
  selection; replacements do not extend one-second expiry. Selected bodies are
  consumed before uncertain handoff, without retry; active scalar keys remain
  until Remove/Destroy. Receiving games use payload sequences for stale filtering.
  Put stores each validated priority rank once; Flush partitions pending keys once
  before independent channel selection, which stops at its 32-record cap and
  retains unselected snapshots for later flushes.
  Helper/session checks and Sol reviews pass. The separate two-client Studio
  fixture passed nine State checkpoints and six submission-to-ACK age gates;
  ACK age includes reverse transport, scheduling and the harness.
- Composite frames use format version 1 and a u16 endpoint matching the outer
  endpoint. Limits are 8192 raw bytes for Reliable, 900 for Unreliable, depth four,
  256 expanded nodes per event, and array/set capacities at most 64. Definition
  rejects schemas exceeding the worst-case bounds. Decoders check bounds before
  reads, allocation, and traversal, and reject the complete malformed frame
  before any handler call. Normalized/decoded tables belong to each invocation.
  Single- and two-field validation, encoding, and decoding keep values in locals
  instead of allocating temporary payload tuples.
  Composite codecs bind frozen endpoint IDs and effective byte bounds at setup;
  decode-only nodes omit encode/validation lookup maps. RPC and batch readers
  retain wire bounds while checking only the narrowed unsigned ID/kind ranges.
- Primitive validators check exact arity and return normalized tuples without
  payload arrays. Sessions compile and bind each validator while constructing its
  event handle, without an intermediate validator lookup table. Integers are exact
  and bounded; Float32 scalars/vectors check
  bounds and canonicalize negative zero. Vector validation reuses immutable values
  whose zero components are already canonical and reconstructs only to canonicalize
  negative zero. Strings retain exact bytes. CFrame validation checks finite bounded
  translation and approximately orthonormal,
  right-handed rotation without repair. Composite CFrames preserve twelve f64
  components and require exact reconstruction, including zero signs.
  Composite integer decoding selects zero-only normalization at construction for
  full native ranges after checked buffer reads; narrower ranges retain their
  scalar validators. Encoding and native tuple validation keep full checks.
  Queued receiver codecs compile only for the session's incoming direction.
  Immediate composite events reuse their queued codec; primitive immediate events
  retain their separate native tuple validators.
- The server owns `ReplicatedStorage.RelayRemotes`, with `Definition` and
  `Reliable` leaves, plus `Unreliable` when selected by any event. The Reliable
  leaf is present even for unreliable-only schemas. Active mutations
  are terminal, including same-count leaf replacements or mutations restored
  before deferred observers run. Cleanup preserves foreign descendants.
  Sibling name observers detect persistent root-name conflicts without scanning
  storage on packet paths.
- Eligible ingress requires a current rostered player and charges one per-player
  token, then one aggregate token, before endpoint/channel/payload validation.
  Both channels share buckets and handler caps. Per-player exhaustion leaves
  aggregate tokens untouched; aggregate or validation rejection gives no refund.
  Each eligible attempt samples the server clock once for both buckets. Each bucket
  refills only when that sample advances its independent clock high-water mark.
- Yielding handlers retain their leases: one per player/endpoint, eight per
  player, and 64 server-wide; clients allow one handler per endpoint. Listener
  replacement cannot reset occupied slots. Removal/destruction invalidates leases
  without allowing late callbacks to recreate state. Inbound drops do not retain
  payload diagnostics or enqueue per-drop work. Client terminal cleanup and server
  listener cleanup release decoder references held by connection handles.
- Client discovery and activation share one startup deadline. Each pending child
  wait owns one listener and timeout, released on arrival, timeout, or Destroy.
  Destroy cancels startup with `Destroyed`; attempt identity prevents stale
  continuations from activating a destroyed or replacement session.
- Session option checks reject unknown keys and missing required values without
  temporary key tables. Protected connection cleanup reuses module-local helpers.
- Send success means local Roblox transport handoff. Game code owns authorization,
  semantic validation, sequencing, persistence, and handler work.
  Unreliable delivery may drop or reorder messages. Relay has no automatic retry
  or reconnect. Admission bounds Relay-owned
  work, not engine ingress allocation, network availability, or fairness.

Networking, decoder, serializer, transport, batching, RPC, and middleware changes
require a dedicated design and security review under [AGENTS.md](AGENTS.md).
Before extending unreliable delivery or composite shapes, that review must
specify version compatibility, maximum total encoded size, array length, nesting
depth, and admission charges. Keep the contract in docs/reference.md current and prove
malformed-input rejection and applicable charging with focused checks.

## Benchmark ownership

Benchmark code stays outside the Wally package.
[benchmarks/README.md](benchmarks/README.md) owns execution, timing, lifecycle,
reporting, and trust-boundary rules; [the adapter guide](benchmarks/adapters/README.md)
owns external binding details.

| Area | Responsibility |
| --- | --- |
| `benchmarks/contracts/` | Event V1 workloads, Result/HostManifest profiles, shared private schemas, repetition fragments, and bounded terminations. |
| `benchmarks/fixtures/`, `benchmarks/correctness/` | Deterministic inputs, payload comparison, order/cardinality checks, and delivery ledgers. |
| `benchmarks/adapters/` | Closed adapter contract, native/Relay bindings, and pinned external bindings. |
| `benchmarks/runner/` | Clock/timing boundaries, bounded phases, readiness, distributed execution, persistent transport observation, evidence assembly, and cleanup. |
| `benchmarks/host/` | Source/artifact verification, canonical study prelaunch input manifests and between-attempt rechecks, interrupted-study recovery audits and fresh whole-study restart collection, selected-only builds, authenticated bounded collection, confirmed Studio exit, shared fail-closed Studio launch ownership, and no-overwrite publication. |
| `benchmarks/reporting/` | Bounded reads, strict V1/V2 validation, compatible comparison groups, median-sorted ranks and inverse-median FPS/Native scales, and separation of non-valid evidence. |
| `benchmarks/pilot/` | Opt-in QuickNet/Zap lifecycle checks outside measured Result evidence. |
| `benchmarks/quick/` | One-client Studio Play diagnostics, persistent adapter instances, bounded capture, FPS-sorted Output tables with Native scales and engine-wide KB/s, and in-session reruns. |
| `benchmarks/profiling/html/` | Pinned saved-HTML extraction, viewer-compatible normalization, isolated decoder worker, Windows process bounds and focused offline checks. |

The library lock is `benchmarks/libraries.lock.json`. Acquisition and deterministic
generation use `scripts/acquire-benchmark-libraries.luau` and
`scripts/generate-benchmark-adapters.luau`. Downloaded/generated code is not
edited or committed. Suphi-Packet has an author grant but remains timing-ineligible
because its sender-frame bound cannot be proven.
QuickNet's lock separates its `v0.3.5-beta` tag target from the runtime-source
commit because the tag is docs-only; the pinned source matches the published
RBXM scripts used for the benchmark. The focused benchmark-library test covers
that source/tag split and Blink's current release asset size. QuickNet's newer
`Config` ModuleScript is mapped in both the runtime project and catalog.

Canonical `PersistentBenchmark` uses Result V2's `event-session-v1` profile:
one fresh Studio session per adapter/case/topology, 30 logical windows, a passed
session proof, and confirmed process exit before publication. Physical receivers
observe across windows; late, stale, malformed, or between-window deliveries
latch failures. Setup, readiness, warmup, correctness, and quiet windows stay
outside timing. Result V1 is a separate lifecycle/profile and cannot be pooled
with V2. Readers recompute summaries and reject dirty provenance, duplicate run
IDs, and incompatible comparison groups. A warm process is not 30 independent
process samples; shared-clock durations are diagnostics, not ranking inputs.

The canonical host, external repetition runner, session-reuse pilot and native
proof runner acquire the same Windows host lease under the OS-resolved
CommonApplicationData folder (normally ProgramData), independent of the caller's
environment, before Studio preflight. Its file is created with Windows CreateNew
rather than Lune 0.10.5 `fs.writeFile`, whose overwrite option does not make creation
exclusive. A launch marks ownership uncertain until child exit, Studio-idle
census and owned-file cleanup succeed. Crash, kill acknowledgement, cleanup
failure, missing owner content or an existing lease retain/fail closed; there
is no time- or PID-based automatic reclamation. Manual recovery requires
confirming the old host and Studio descendants are gone. This coordination
covers Relay CLI launches across Windows accounts and checkout directories;
unrelated Studio tools do not participate, and macOS fails closed.
The pilot latches forced-kill requests and unconfirmed outcome exit across
cleanup; the multi-scenario proof clears each confirmed prior child before
the next prelaunch check.

The timing recorder retains completed private sample arrays and makes one final
defensive copy when producing deeply frozen evidence.
Runner operation callbacks and fixed delivery/control key allowlists are selected
before execution; per-message validation and timing boundaries remain unchanged.

`MeasurementFingerprint.luau` covers measured runner/contract/fixture/correctness
inputs, composition and adapter contracts, canonical host dependencies, and the
library lock. Documentation/reporting edits do not change the fingerprint.
Changed measured inputs require a compatible new cohort.

[Quick benchmark guidance](benchmarks/quick/README.md) owns workload selection,
balanced adapter rotations, timing units, and receive profiling. Quick runs
accept dirty local source and do not emit Result V1/V2 or ranking evidence.
Their summary tables sort local observations by sender FPS, or by RTT for the
sequential probe, without changing returned adapter order or ranking eligibility.
Sender FPS uses per-round mean frame intervals; engine send KB/s remains an
engine-wide diagnostic. Canonical FPS is separately derived from median frame
intervals, and RTT is never converted to FPS.
The Relay-only `schema-composite-c2s` diagnostic exercises RR3 with 16 bounded
records and independent nested fixture/capture copies. It supports the isolated
Relay receive profile; the other schema cases remain unprofiled. The profile
includes admission, RR3 decode, dispatch, and nested capture, excluding engine
decode, scheduling, and transit.
`CoreAdapters.luau` owns quick-only matched reliable C2S channels for Booleans,
Strings, Numbers, Vector3, and Mixed state across all nine timing-eligible
libraries. `--category` selects one category or the fixed five-case suite;
`--adapters`/`--all` independently select libraries. Each physical library loads
once and declares all five channels before timing, including Warp's cached
endpoints. Category-tagged callbacks and bounded `NextCase` transitions preserve
the suite-wide failure latch. The dedicated Relay definition uses existing
pre-handler validation and admission; third-party codec checks prove fixture
delivery, not hostile-byte security. Suphi-Packet remains timing-ineligible.
Core runs and receive profiling are separate. Generated schema extensions
require pinned regeneration and a separate measurement cohort.
Fixed quick payloads forward exact scalar tuples directly to native, Relay, Warp,
and generated send calls without an intermediate packed table.
`benchmarks/tests/quick-core-adapters.luau` checks all five fixture payloads
through the nine adapters, including the real pinned vendor codecs, sender and
channel identity, input preservation, and legacy generated event IDs. The
owned five-event Relay specification has focused pre-handler string-boundary
rejection and per-player/aggregate admission checks. Suite tests cover category
transitions, cached reruns, late deliveries, and delayed replication metadata.
Each adapter initializes once per Play session; the selected core cases run
sequentially without reopening Studio. Changing source or the built selection
requires Stop/Play. Observed terminal faults invalidate prior reruns, while
acknowledged normal closure tears down adapters and preserves completed results.
Receive profiles use isolated source snapshots and include capture/instrumentation
overhead; they are callback elapsed diagnostics, not isolated CPU time or
end-to-end latency.

[Saved MicroProfiler HTML analysis](benchmarks/profiling/html/README.md) uses a
pinned external decoder anchor and runtime. Input HTML remains inert; an
isolated worker and Windows Job bound execution and verify cleanup. Supported
saved dumps use this CLI for structured extraction; Studio capture/export
controls may still require computer use. Reports retain provenance and explicit
qualification flags, with absent network records, workload attribution and
physical wire bytes kept distinct. This path does not load LibMP or qualify a
native capture, and its output is separate from Result V1/V2 rankings.
The zero-record hold parity exception requires zero viewer totals and category
counters; nonzero category data cannot pass as an explicit-zero addition.

Canonical LibMP benchmark collection remains disabled pending qualification.
The quick runner now supports opt-in `--profile-receive --libmp <SDK>` for the
existing client-to-server workloads. `CpuProfile.luau` owns pinned-SDK/backend
checks, capture control, bounded exact CPU scope-pair analysis, and cleanup.
The isolated builder verifies SDK revision/hash and records it in the manifest;
ordinary builds exclude the SDK. The measured client send loop runs directly
inside PreSimulation, closes its scope before yielding, and captures to a private
buffer after a diagnostic delay. Per-round `cpuCapture` reports and the latest
buffer/report are available through the quick Session diagnostics. They retain
scan limits and explicit false timing/ranking qualification. Iterator and state
read errors retain partial pair diagnostics and report failure rather than an
observed result. Fresh native
benchmark validation remains pending; the registered Studio executable was
unavailable during integration. The focused reader, session, and snapshot/build
checks cover this tooling without changing Relay production source or remotes.
The quick guide applies the earlier investigation lesson to real-workload
probes, retained-data analysis before recapture/GUI, and focused verification.

Pinned Studio 0.742.0.7421053 and matching SDK 1.1
(65537:65537) expose ordinary CPU enter/exit records and counters. Before-work
active ranges precede paused ranges by four absolute frames; buffered and
paused-live scalar views agree. Those command-driven probes found work timer
descriptors, but their exact enter/exit pair remains unqualified. The typed
recent-frame census separates boundaries, scopes, labels and events and retains
only its committed prefix. Failed and capped scans prove no full-window absence;
Step=false can
mean exhaustion or reader error. Heartbeats establish neither the work's
Profiler frame placement nor a capture-drain fence. Heap samples are process-
wide; scope timing and benchmark attribution remain unqualified.

LibMP name masks match whole descriptor names. Related-name inventory is
diagnostic-only and does not expand the exact-base qualifier's accepted IDs.
Timer filters do not exclude labels, so diagnostics retain record-class counts,
step caps and stopping state. The private diagnostic reader now accepts the
documented terminal frame boundary at end+1 while keeping work matches inside
the selected frames. Both prior corrected recent-eight-frame scans reported complete
with zero work matches; that stopping state still does not establish clean EOF.

A separate ordinary client Play probe now reads an exact custom CPU work
enter/exit pair from a paused LibMP slot. It wraps non-yielding work directly in
a PreSimulation callback, repeats eight times, and retains 32 frames. The
bounded latest-eight-frame scan found a pair in its committed prefix before
reaching its step limit. This establishes marker presence in that context;
the earlier missing marker's cause remains unexplained. Native UI work-bar and
exact-frame corroboration remain incomplete. A native binary dump is retained
but has not been decoded or verified against the slot bytes. Scope timing,
benchmark-workload attribution and collector promotion remain unqualified.

`BroadcastStudy.luau` and `run-broadcast-study.luau` schedule forward/reverse
canonical State-broadcast sessions with pinned source and Studio identities.
Verified result bytes, logs, hashes, and failed attempts stay in ignored local
ledgers. Initial ledgers, logs and raw archives use a Windows CreateNew write
because pinned Lune's `writeFile(overwrite=false)` is not exclusive.
`BroadcastRecoveryAudit.luau` checks interrupted v2/v3 ledgers and current inputs
without launching Studio or selecting old slots. Restart history is bounded to
eight ledgers including the original v2 and newest v3 collection. Each parent
hash, manifest and source identity is revalidated; canonical repeated paths and
run IDs across generations are rejected. Historical reporting validates archived
inputs; a new restart also requires current checkout inputs to match. A terminal
failed attempt may start a linked v3 collection with a fresh full schedule.
An in-flight attempt in any ancestor remains blocked on uncertain ownership.
Full histories fail before a new
collection or launch. The v3 reporter revalidates all ancestors and archived
evidence before using only the newest collection's attempts.
D05 owns actual Studio launch exclusion and uncertain child teardown.
`StudyInputManifest.sourceInventory` exposes the same source closure as sorted
relative paths, byte counts and domain-separated file hashes for verified copies.
Ledger manifest v1 summaries and identities stay unchanged. Inventory still
reads live files; immutable execution remains a separate gate.
`StudySourceCopy.copy` creates an offline copy in a fresh Windows directory,
checks each source read and destination readback against the frozen inventory,
and rejects missing or extra files/directories before returning its identity.
Ordinary ASCII paths on the same drive, case/prefix and reparse-point checks
and exclusive directory/file creation constrain writes; failed output is retained.
Checks assume stable local filesystem ancestors and cannot prevent a hostile
reparse-point swap after inspection. The copy contains no Git metadata and is
not wired to benchmark execution; tool closure and immutable execution stay open.
[The serializer gate](benchmarks/serializer-gate.md) owns predeclared
units, attribution limits, and evidence collection. `SerializerGate.luau`,
`SerializerEvidence.luau`, and `run-serializer-gate.luau` evaluate pinned source,
exact planned base-place identities, Result V2, profiler, and packet-capture
artifacts. They do not collect those traces or certify human reviews; missing
evidence is inconclusive, and passing evidence is eligible for design/security
review.
Packet evidence matches ordered packets to validated nonoverlapping windows with
one advancing cursor, preserving half-open boundaries and packets in gaps.

The local OS account and selected Studio executable are trusted. Harness
framing, source checks, and correctness qualification do not certify third-party
decoders against malicious bytes or establish production security.

## Broadcast study diagnostics

Offline `BroadcastStudyReport.luau` and its CLI reuse canonical Result V2
validation and exact archived bytes. Metric scopes,
sample/launch units, median/p95 drift, source/engine pins and unknown coverage
remain explicit; two ordered passes cannot select a winner or establish an
independent uncertainty interval. Report thresholds do not prove historical
predeclaration. `benchmarks/tests/broadcast-study-report.luau` verifies evidence
tampering, incompatibility and drift arithmetic.
Old duplicated ledger summaries may differ by one binary64 step; these differences
are recorded while canonical raw-sample summaries remain authoritative. CLI output
creation rejects collisions without replacing prior evidence.
Reporter paths preserve Windows UNC roots accepted by the collector.
Each archived result's checked digest is reused in its report row.

`BroadcastStudy` additionally records coarse monotonic preflight, whole child
host command, and archive/validation intervals, including failures. These are
campaign turnaround timings, not measured runtime phases.
Clock faults mark timing unavailable without obstructing raw evidence or the
primary failure. These coarse intervals preserve the host measurement method
and fingerprint algorithm. Host ownership changes alter HostRuntime source
bytes and therefore the recorded measurement fingerprint.
These intervals do not isolate child lifecycle phases or establish performance.
The current API reference distinguishes historical native proof from a
fresh current-checkout run and explains State residence/late join, uncertain RPC
outcomes and engine-ingress security boundaries.

## Verification and repository hygiene

Code reviews use a Sol (`gpt-6-sol`) subagent. Use the nearest focused test during
development. After foundation changes, run:

```sh
lune run scripts/verify-foundation.luau
```

The gate runs registered runtime/type/benchmark checks and verifies the Git-index
file allowlist, LF/trailing-whitespace policy, ignore boundaries, Wally package
contents, Rojo builds, and CI pins. Stage intended file additions/deletions before
running it because the inventory reads the index. The gate does not launch Studio.

The RPC retention witness ends its creator frame before collection to exclude
dead VM stack slots. Adapter checksum fixtures preserve binary source bytes and
compare XML hashes with the parsed artifact's source.

`scripts/Verification.luau` owns the private advisory first-check mappings, Git
NUL-path parsing, source identity and atomically reserved per-run output roots.
`verify-foundation.luau --first --dry-run` explains the staged/unstaged/untracked
selection against HEAD without executing checks or creating artifacts; omit
`--dry-run` to execute it. Registered tests select themselves; type fixtures select
the pinned public-type check. A small exact source mapping selects nearby checks.
Unknown paths, deletions/renames, unsupported statuses, missing mapped checks and
empty changes conservatively run the full gate. This is no dependency graph;
the default full command and independent Sol review remain required.

The verifier reuses `MeasurementFingerprint.digest` with a separate verification
domain over tracked/untracked non-ignored file bytes, revision and dirty status.
It rejects source drift between entry and exit. This identity is separate from
benchmark measurement eligibility; `HostRuntime` and `BroadcastStudy` still own
their source/artifact pins, raw bytes, failed attempts and native coordination.
Ignored `.tmp/verification/<owner>-<run>/report.json` handoffs identify the source,
actual commands by registered test path, stage outcomes and bounded failure text.
Full runs retain every package/build/CI check. Advisory reports explicitly mark
unselected checks and final gates skipped. Success removes only that invocation's
artifacts; failures or interruptions retain them. Public-type runs isolate every
generated input and read/hash-check the legacy definitions cache without writing
it. Never delete another invocation's output; inspect only completed run roots.
`tests/verification-workflow.luau` uses literal expected commands and controlled
runner failures to check selection/fallback, dry runs, source drift, reports and
cleanup ownership.

`.agents/skills/relay-benchmark-review/` owns repository-scoped offline benchmark
claim review. Its concise entrypoint routes to study and capture/attribution
references, with normal automatic discovery. `benchmarks/reporting/BenchmarkReview.luau`
reuses `BroadcastStudyReport` and `BroadcastStudy.sourceIdentity`; the skill's
`scripts/assess-study.luau` emits a diagnostic assessment and bounded failure
codes. Optional before/after clean Git checks establish only a revision match,
not ignored-artifact/build/engine qualification or current performance. The
assessor never grants a winner, CPU attribution or packet attribution, and an
explicit caller-selected drift tolerance proves neither predeclaration nor
significance. `benchmarks/tests/benchmark-review.luau` exercises raw failures,
clean/dirty/changed source, tolerance choice and unqualified LibMP claims with
synthetic fixtures and real offline CLI calls. Skills remain outside Wally via
the `.agents` exclusions. No benchmark collection or runtime change is added.

| Check | Coverage |
| --- | --- |
| `tests/runner.luau` | Frozen public module contract, supported schema helpers, and legacy ordered-helper compatibility. |
| `tests/public-types.luau` | Actual API and mapped example consumers under the new solver, including invalid schemas, payloads, options, depth, and recursive types. Uses hash-verified Roblox definitions in ignored `.tmp/`. Also checks that the site's quick-start code is exactly the escaped, typed reliable-events example and that its local/reference anchors resolve. |
| `examples/combat-inventory/` | Two composed event modules, authoritative Player-based inventory inspection, typed request results and explicit lifecycle cleanup; all mapped scripts pass the pinned solver and Rojo build. |
| `examples/state-snapshots/` | One absolute replaceable pose/key, fixed caller audience, latest-unsent Put/status/Flush/Remove hooks and scalar stale-tick filtering; mapped scripts pass the pinned solver and Rojo build. |
| `tests/definition.luau`, `tests/frame.luau`, `tests/composable-codec.luau` | Schema/descriptor rejection, primitive normalization, bounded encoding/decoding, malformed buffers, exact tuples, per-invocation ownership, single-/two-field tuple-allocation checks, canonical vector reuse, all six composite integer widths, decoder/input-validation separation, and guarded composite table iteration. |
| `tests/schema-compose.luau`, `tests/types/schema-compose-*.luau` | Bounded modular event merging, duplicate rejection, descriptor parity, ownership, and exact positive/negative solver consumers. |
| `tests/diagnostics.luau`, `tests/rpc-frame.luau`, `tests/rpc-definition.luau`, `tests/rpc-session.luau` | Fixed snapshots, inspection bounds, checked RPC envelope/schema, request lifecycle, correlation, replay admission and shared leases. |
| `tests/queued-definition.luau`, `tests/readiness-frame.luau`, `tests/readiness-session.luau`, `tests/batch-frame.luau`, `tests/batch-session.luau` | RR6 metadata, readiness lifecycle, FIFO framing, logical admission, complete decode, handler leases, diagnostics, and audiences pass portable checks and Sol review. The integrated 0.2.0 two-client Studio fixture passed 23 checkpoints, including readiness and FIFO callback-start order; separate State producer/timer evidence is described below. |
| `tests/batch-queue.luau`, `tests/types/queued-*.luau`, `tests/types/readiness-*.luau` | FIFO helper ownership/timer/partial-failure checks and strict directional capability/report/inspection types. Public typing, helper and session portable review is complete; actual Studio proof is separate. |
| `tests/state-queue.luau`, `tests/state-session.luau` | Latest-unsent ownership, deterministic selection/expiry, shared key/byte/flush limits, audience pruning, partial handoffs and terminal timer cleanup pass focused tests and Sol reviews. Reference Put replays compare accounting, owned buffers, first-dirty expiry, rejection behavior, timers and exact handoff bytes; key-read probes measure work separately from timing. Separate two-client Studio launch `78f12ce7e1724b8f9e7324da292edd73` passed nine State checkpoints and six paired submission-to-ACK age gates. Its collector failed on an echoed marker; exact saved-log recovery passed unchanged assertions and independent Sol review without another run. That proof used frozen 0.1.0 source and does not qualify later working-tree runtime edits. ACK age includes reverse transport, scheduling and the harness; it is not one-way latency. |
| `tests/token-bucket.luau`, `tests/server-session.luau`, `tests/client-session.luau` | Refill/clocks, admission charging, handler leases, routing, discovery cancellation, transport integrity, and cleanup. |
| `benchmarks/tests/` | Contract rejection, adapters, timing/lifecycle boundaries, stale probe rejection, host provenance/framing/cleanup, reporter compatibility, quick diagnostics, and study/gate orchestration with exact place pins. Synthetic/build checks are not native timing evidence. |

Portable RPC session checks cover false and explicit trailing-nil request
arguments. State session checks cover fresh composite payload ownership across
immediate and queued paths on both session sides.

Real Studio correctness is explicit:

```sh
lune run tests/studio-reliable-events.luau
```

Append `--correctness-only` for the two-client correctness scenario; omit it for
the complete correctness/admission matrix. This fixture covers native and
composed payloads, both delivery channels, malformed rejection/charging,
startup cancellation, and transport mutation. Unreliable checks require valid
observations and audiences without requiring full or ordered delivery.
After a timeout kill, cleanup requires an independent Studio-exit check before
removing the bootstrap script.
External payload/reuse qualifications are opt-in and require pinned local inputs.
Use focused checks before collecting the full measured matrix.

[examples/README.md](examples/README.md) owns the public-API example place. The
public-type check analyzes its mapped scripts, and the foundation gate builds it.

Private plans/reports under `docs/`, `.tmp/`, Forge artifacts, dependencies,
benchmark vendors/generated runtimes, and local results stay ignored. CI runs on
pinned Windows 2022 for pushes to `main` and all pull requests; after installing
pinned Rokit tools it acquires the locked benchmark libraries and regenerates
their adapters before the full foundation proof. Keep changes surgical and update
this map when purpose, ownership, API, modules, tests, or guardrails change.
