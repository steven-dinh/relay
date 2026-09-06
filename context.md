# Relay Context

## Purpose

Relay is a standalone Roblox networking library with fixed-schema reliable
events, explicit server/client sessions, bounded client admission, targeted
sends, broadcasts, and lifecycle cleanup. The repository keeps reproducible
development, packaging, correctness, examples, and benchmarking boundaries. The
benchmark workspace includes Event V1 equivalent-semantics workloads, a pure R1
whole-case runner, a pure R2 control validator, native/Relay Studio bindings, and
authenticated host collection.

## Ownership

Relay owns a private pure reliable-event definition compiler and frame validator under `src/`. The compiler bounded-validates and copies the fixed six-type schema, creates the exact canonical descriptor, recursively freezes compiled state, and brands an opaque zero-key definition token through a closure-private weak registry. The frame validator resolves only trusted compiled endpoint metadata, checks exact positional arity, and normalizes at most eight fixed fields without transport, services, tasks, diagnostics, or payload-selected traversal.

Relay owns strict Result V1 and V2 benchmark-envelope finalization and validation
outside the published Wally package. Version-specific wrappers share the private
`ResultSchema` and `HostManifestSchema` validators without widening V1 acceptance.
V2 exclusively represents `event-session-v1` / `PersistentSession`, requires a
passed final session proof and separate measurement/adapter fingerprints, and
cannot be pooled with old restart results. Revalidation permits only one adjacent
binary64 value of JSON-transport drift in a derived even-sample median and
returns the recomputed canonical median; odd medians, p95, counts, and all other
fields remain exact.

Relay owns a benchmark-only `AdapterContract` that shares canonical adapter
identity, Event V1 case resolution, and capability-requirement validation with
Result V1. It preflights adapter factories, creates frozen side contexts and
bounded raw-delivery envelopes, and enforces side-local lifecycle transitions.
It owns no real transport, runner clock, participant authentication, ledger,
reporter, or mutable result.

Adapter conformance permits one raw-readiness side effect: immediately before
its first true result, a side atomically opens only its local callback admission.
Before that point and after teardown begins, callbacks inspect no argument and
never invoke the runner sink; readiness creates no resource, generation-wide
activation, queue, or replay. `DeliveryRouter` remains the defensive pre-arm
backstop after local admission opens.
A rejected yielding readiness call has its suspended coroutine closed before
setup failure returns, preventing its continuation from running after teardown.
Raw setup calls are also contained and closed if they yield; the side reaches
`SetupFailed` before returning, so rollback can still invoke adapter teardown.

Relay owns pure benchmark-internal R0 contracts. `HostManifestV1` validates,
copies, and freezes the exact trusted host evidence R1 may consume;
`HarnessTerminationV1` owns the exact bounded no-Result envelope; and
`RepetitionFragmentV1` validates and freezes one provenance-bound, globally
indexed ProcessRestart repetition. `HostManifestV2` validates the persistent
whole-case host input and rejects fragment execution. None acquires host data,
loads a module, creates an engine object, or moves
data across a process boundary.

Relay owns the first pure R1 construction boundary. `DeliveryRouter` creates a
stable adapter sink with a one-time bind/arm gate, a stale-only teardown
observer, a persistent defensive pre-arm latch, and a permanent disabled no-op.
`SessionOwner` revalidates trusted host and adapter selection, enforces
SessionRestart for V1 whole cases, an exact one-index ProcessRestart window, or
explicit V2 PersistentSession whole cases, and
validates exact runtime rosters before construction. It creates one generation
root, constructs server then client ports, and owns bounded partial
construction rollback. Workload fanout is audience-owned; sender authentication
tokens remain direction-owned. The resolved selection's
`clientProcessCount` is the sole benchmark-internal topology count: Broadcast
workloads use the selected recipient count, Server/C2S workloads use Event
V1's single sender count, and the probe uses its declared client count. Opaque
participant tokens must be nonnil, reflexive under `rawequal`, and pairwise
distinct. Post-validation setup/internal failure arms carry the canonical
frozen manifest. Generation-root destruction is attempted exactly once in a
fresh coroutine and must return without yielding; a throw, suspension, or
otherwise unprovable cleanup produces the cached
`CleanupFailure/Finalize` termination. A malformed/non-callable trusted root or
adapter factory is `InternalFailed` with the canonical manifest, while a
callable allocation-atomic root factory that throws before returning a lease is
`SetupFailed`. These modules create no engine object, remote, clock, frame
driver, adapter payload oracle, or result.

Relay owns the pure R1 benchmark runner. `BenchmarkClock` guards injected local,
shared, and timeout clocks; `TimingRecorder` owns contract-driven timing
boundaries and clock proof; `RunState` owns bounded case, participant,
generation, progress, failure, and immutable evidence state; `RunnerKernel`
owns engine-independent producer, callback, and teardown orchestration;
`KernelFanout` is the exact two-key CaseRunner-private test seam for non-yielding
trusted-kernel fanout and one-fact invariant deduplication;
`GenerationActivation` owns same-process attach/setup/readiness/arm rollback;
and `CaseRunner` is the stepped whole-case owner. `ResultDraftAssembler` is the
sole projection from the frozen run snapshot and trusted host inputs into the
Result V1 draft that `CaseRunner` finalizes. The Studio persistent path uses the
same projection with exact V2 host input and frozen passed session proof. These modules expose only the exact
frozen APIs documented in the runner plan and create no engine object.
`RunState` requires its `Verified` phase to complete the second 60-frame quiet
window after measured verification before normal teardown; every relevant
delivery resets that count, and `IsolationFailure` is valid for every role.
`RunnerKernel` snapshots each fresh fixture input across the adapter operation;
any mutation records `InputMutation` and invalidates the run. A warmup mutation
followed by an ordinary teardown failure preserves both failure facts in a
`NotStarted` invalid result. Measured submit clock reads sit immediately beside
the operation inside non-yielding containment. The interval retains
selected-field extraction, `AdapterContract`,
final-in-frame `FlushBeforeReturn`, and the fixed clock/wrapper edge shared by
every adapter, while deferred transport and receiver work remain outside it.
Receiver evidence uses the same case-wide observation budget as the runner,
allowing duplicate traffic to concentrate in one repetition. First receipts
remain bounded by each repetition's fixture count; overflow must exhaust the
case budget in the final started repetition. R1 snapshot and R2 final-report
validation enforce these same relations.

Relay owns the pure R2 `ControlProtocol` validator. Its exact frozen module
surface is `{ newCoordinator, newParticipant }`; successful construction returns
an eight-method coordinator or a five-method participant. It owns bounded
canonical command/report validation, roster attribution, sequence and replay
budgets, multi-slot barriers, response expiry, a 120-attempt untimed shared-clock
readiness barrier requiring two consecutive full-roster bracket passes,
timing-conformance reconciliation,
and distributed final-report overflow disposition. It creates no `RemoteEvent`,
engine object, launcher, module loader, or transport, and has no runtime
dependency on the R1 runner state. Present optional measurement groups on a
completed repetition have exact Event V1 cardinality and are preserved for
projection; an absent pure-R1 optional group receives only its deterministic
unavailability reason. Hostile facts are accepted only to relations R2 can
prove. `IsolationFailure`, `SubmitFailure`, and `TeardownFailure` occurrence
counts are repetition-owned, not participant-owned, but their compressed facts
do not expose a complete repetition set for cross-participant deduplication.
Pure R1 therefore permits each of those codes from at most one participant and
rejects ambiguous multi-participant projection. `IsolationFailure` retains its
exact earliest failed repetition; `SubmitFailure` and `TeardownFailure` retain
bounded representative references without a cause-specific earliest claim that
the frozen schema cannot support. Prestart teardown evidence from another
participant requires a validated warmup mutation in the same case; unrelated
prestart teardown claims remain rejected.
Final-report repetition entries must be plain tables before field access;
malformed scalar entries produce the protocol rejection disposition without
throwing out of the validator.

Relay owns the benchmark-only Studio control and native execution path. The
coordinator owns the server-only validated HostManifest, manifest-derived
selection, exact engine roster, topology latch, generation roots, pure R1/R2
composition, fixed-slot final-report merge, cleanup, and sole `EndTest`; each
participant owns its authenticated control slot and local generation lifecycle.
`AdapterAllowlist` accepts the exact full native identity for the running
Studio version, the host-pinned exact Relay identity, or the selected host-pinned
external identity for a one-index `ProcessRepetition` or explicit whole-case
`PersistentBenchmark`. `ExternalReadiness` owns
the selected external adapter's bounded server/client prewarm and replicated
remote, namespace, attribute, or endpoint proof; QuickNet's transport children
are resolved under the replicated per-generation `Library` module that creates
them, not as global `ReplicatedStorage` children. `native-reliable`
validates and caches its exact roster and
remote during readiness before any timed submit or broadcast. The Rojo place,
native adapter, engine clocks, and Studio proof remain outside `src/` and do not
change the Wally package.

`PersistentTransport` owns one physical raw adapter side and permanent receiver
per Studio participant for an exact selection. Its window facades preserve the
ordinary AdapterContract lifecycle while setup/teardown of the raw side happen
once. Active deliveries forward unchanged to the current R1 sink; deliveries
between windows latch failure. Per-window roots are disposable generation
markers, not physical transport roots. Clients close/check the owner before
FinalReport; the server closes/checks after every client report and before its
evidence freeze. Cleanup destroys the physical root before EndTest. Final
session proof cannot pass after a callback, raw-call, or cleanup failure.

Studio startup preserves receiver-before-sender ordering. S2C warmup waits for
exact-roster, current-repetition acknowledgements after clients have armed
their local callback gates and warmup ledgers. The
server stays unarmed during that wait, then begins warmup after closing the
acknowledgement gate. Participant aborts during `Measured` use the measured
abort transition before disconnecting the producer and tearing down the adapter.
Terminal participant failures also disconnect and tear down their active kernel.
Warmup aborts remain outside the measured-report gate. Coordinator emergency
cleanup releases draining and terminated kernels and skips adapter teardown
when post-teardown observation has already begun.
Emergency cleanup preserves prior non-cleanup terminations; only unprovable
cleanup replaces them with `CleanupFailure`.
For measured startup, S2C clients acknowledge with one bounded two-field,
current-repetition scalar only after their local kernel reaches `Measured`;
the server requires the exact
roster, rejects duplicates, and closes the acknowledgement gate before arming
its sender. C2S workloads and the round-trip probe arm the server receiver and
cross one `PostSimulation` boundary before client senders are armed. The
measured-completion report gate remains closed until that directional arm
sequence has completed. Coordinator waits honor latched protocol and topology
failures before accepting completion, including the final-report barrier.
Distributed probe clients own a guarded local 120-second response deadline.
Expiry uses the existing measured-abort and cleanup path without creating a
coordinator-owned `Timeout` fact. Without other causal evidence, the run ends
with bounded `FinalEvidenceUnrepresentable` rather than a fabricated Result.
Measured probe waits use the original 7,200-second case deadline, allowing a
healthy sequential probe to exceed the general 150-second control wait.

Relay owns the benchmark-only host launcher and bounded Studio-output collector. Each
launch receives a unique ignored Rojo build whose exact pre-carrier bytes supply
the place fingerprint, then a server-only `LaunchCarrier`; the generic RunScript
contains no embedded capability and destroys the carrier before multiplayer
execution. After confirmed Studio exit, the collector rejects an output file over
20 MiB before reading it, accepts one authenticated and exactly ordered sequence
of sub-4-KiB begin/chunk/end lines, and reconstructs no more than the Result V1
8 MiB JSON ceiling. It uses independent Studio-version attestation, validates a
closed ControlProof/termination/Result root and complete provenance, and
publishes only a validated Result V1 or V2 by same-directory no-overwrite move.
ControlProof writes no result. No HTTP listener is opened for terminal results.
`HostRuntime` owns the importable launcher and collector implementation;
`run-event-v1.luau` always validates command-line arguments and invokes it.
Schema-valid non-`Valid` Results remain available as diagnostic artifacts, but
the benchmark command returns a failure with the Result status instead of
printing `PASS`.
The Studio coordinator logs a failure-only call stack when it terminates and
the active control barrier when a clock proof fails. These diagnostics contain
no raw payload or host capability and do not run on successful measured paths;
the original termination envelope and fail-closed publication rules are unchanged.
Forced-kill acknowledgements from Lune do not prove OS process exit. The host
retains protected launch files and fails with `HOST_E_CHILD_LIVE` after a kill
attempt, including exception paths; descendant-process termination remains
unproven with the current launcher.
Windows launch preflight rejects active Studio processes with
`HOST_E_STUDIO_BUSY` to avoid the observed shared `server.rbxl` quick-save
collision. Process inspection failure is bounded and fails closed. This is a
read-only guard, not atomic serialization against other launchers; Studio test
sessions must still run serially.

For admitted external adapters, the host derives an HTTP-disabled Rojo project
from the tracked composition and includes only the selected binding, library,
optional endpoint, and generated runtime. In the legacy Benchmark mode a stable batch UUID owns exactly 30
fresh child launch UUIDs and capabilities. Each child emits one bounded
`RepetitionFragmentV1`; the host validates its exact batch/index/manifest,
requires a clean Studio process census before cleanup and the next child, then
aggregates and publishes only the complete set. Vendor/generated verification
brackets the build and runs again with the clean Git revision check immediately
before publication. Lifecycle uncertainty retains protected files and aborts
the batch. Explicit PersistentBenchmark instead runs one whole selection in one
fresh Studio session, including all 30 windows. Native, Relay, and the seven
eligible external adapters use the same profile. Clean Git, exact artifact
verification, authenticated output, and confirmed Studio exit bracket publication.
`MeasurementFingerprint` hashes versioned, sorted, length-framed shared runner,
contract, correctness, fixture, and composition sources; unknown executable roots
fail closed. Selected adapter/library bytes are fingerprinted separately. Docs
and reporting are not measurement inputs; the full place and revision remain
recorded provenance without being common V2 comparison keys.

Relay owns a benchmark comparison reporter that reads two or more ordinary,
bounded files, performs lexical JSON preflight and complete version-specific validation,
and rejects dirty provenance and duplicate runs. It keeps runs separate within
case/topology/lane/broadcast strata, separates incompatible source and hardware
cohorts, excludes non-valid evidence from timings, and creates no cross-case
score or overall winner. Schema/profile/isolation always separate cohorts. V1
retains revision-based compatibility; V2 uses the shared measurement fingerprint.

Relay owns the benchmark-only external-library lock, acquisition command,
external adapter catalog, and opt-in runtime-library Rojo mapping. They place exact Git source artifacts and
byte-and-hash-pinned Windows code-generation tools beneath ignored vendor paths.
Tool archives stream through `curl` with HTTPS-only redirects; the acquisition
retains at most each exact byte pin as payload plus a one-byte EOF probe, uses a
fixed transfer deadline, and verifies size and SHA-256 before any archive is
written or extracted. Existing bytes are verified without overwriting them, and
the ordinary native benchmark project remains independent of third-party files.
Relay does not own the downloaded libraries or grant redistribution rights for
them.

Relay owns eight external benchmark adapter bindings and their private
`ExternalAdapter` lifecycle helper. They translate the existing Tiny/State
operations to each pinned library's public API and forward original decoded
records or positional values through AdapterContract. Generated adapters have
tracked schema inputs and an ignored, byte-verified deterministic generation
workflow. These adapters require a fresh physical selection session. Seven are
admitted by the measured Windows host through either legacy per-repetition
process fragments or one explicit persistent selection session; Suphi-Packet remains explicitly
unsupported. The qualification harness executes actual unmodified library
codecs in fresh simulated engine worlds; it does not prove Studio transport,
replication readiness, process cleanup, decoder security, or timing eligibility.
Warp has an explicit untimed `Endpoint` prewarm because its client constructor
yields. Its broken pinned Destroy path is avoided using public callback
disconnection, with full cleanup deferred to process exit. Suphi's original
author grant is tracked as a custom LicenseRef; its unbounded sender-frame
scheduling remains an eligibility blocker.

Relay owns this repository, its package metadata, public source under `src/`, correctness tooling, examples boundary, benchmark contracts, Event V1 fixtures, payload comparison, receiver-local delivery verification, and benchmark workspace.

## Non-ownership

Relay does not own game-specific Core behavior, gameplay policy, persistence, purchases, economy, progression, UI, or third-party benchmark libraries. Future game adapters may depend on Relay; Relay must not depend on them.

## Public API

`src/init.luau` returns a frozen table with exactly four fields:

- `VERSION: string` — equal to the Wally package version.
- `define(spec)` — validates and compiles an immutable opaque definition token.
- `createServer(definition, options)` — creates a server session with explicit inbound limits.
- `createClient(definition, options)` — creates a client session with a bounded startup timeout.

Sessions expose `events`, `Start`, and idempotent `Destroy`. Direction-specific
event handles expose only `Connect`, `Send`, or `Broadcast` as applicable;
listener connections expose idempotent `Disconnect`. Expected failures return
frozen `{ code, message }` errors, with the stable precedence documented by the
reliable-events plan. No internal module is a public top-level key.

## Reliable-event runtime ownership

- `src/Definition.luau` owns the closed authoring grammar, structural ceilings, six fixed field types, Float32-bound canonicalization, deterministic `RR1` descriptor, recursively frozen compiled records, and GC-safe definition identity.
- `src/internal/Frame.luau` owns constant-time endpoint/direction resolution and exact-arity positional payload validation/canonicalization for immutable compiled fields.
- `src/internal/TokenBucket.luau` owns full-at-construction token buckets, saturating refill, and a monotonic clock clamp that prevents backward-clock double refill.
- `src/ServerSession.luau` owns the exact server transport hierarchy, current-player state, ordered per-player/aggregate admission, transactional handler leases, C2S dispatch, targeted sends, one-call broadcasts, and cleanup.
- `src/ClientSession.luau` owns bounded single-deadline discovery, descriptor matching, cancellation and module-slot ownership, S2C dispatch, C2S sends, terminal transport loss, and cleanup.
- Definitions, session/event/connection handles, errors, and module exports are frozen. Internal modules are not additional public API keys.
- The server attaches integrity observers after its non-yielding initial parenting and before final validation/activation. This avoids treating its own deferred startup signals as transport loss. Once active, observed owned-instance mutations remain terminal even if restored before deferred callbacks run. Packet paths inspect only cached owned references and the exact two-child root; storage-wide uniqueness checks belong to startup and storage-change observers.

## Configuration and dependencies

- Package identity: `steven-dinh/relay`.
- Version: `0.1.0`.
- Realm: `shared`.
- Runtime, server, and development dependencies: none.
- Tool versions are pinned in `rokit.toml`.
- Wally publication remains disabled with `private = true`.
- `.gitattributes`, `AGENTS.md`, and `context.md` are tracked governance inputs;
  private planning material under `docs/plans/` remains ignored.
- `.gitattributes` pins repository text to LF.
- The aggregate verifier compares the exact cached Git index to the release
  allowlist and requires CI on pushes only to `main` plus every unfiltered pull
  request, with no additional trigger.
- Local Forge specs/reports, generated outputs, downloaded dependencies,
  benchmark vendors, and local benchmark results remain ignored.
- `benchmarks/libraries.lock.json` pins the eight external benchmark candidates;
  local acquisition writes only under ignored `benchmarks/vendor/` paths.
- The four literal Roblox ignore probes are `artifacts/probe.rbxl`,
  `artifacts/probe.rbxlx`, `artifacts/probe.rbxm`, and
  `artifacts/probe.rbxmx`.

## Security and persistence

The runtime uses one server-owned `ReplicatedStorage.RelayRemotes` Folder with
exact `Definition` StringValue and `Reliable` RemoteEvent leaves. Inbound tuples
remain attacker-controlled: current-player admission and required finite rate
limits precede endpoint, arity, and field validation. Per-player rate exhaustion
cannot further debit the aggregate bucket. There is one handler per
player/endpoint, at most eight per player and 64 server-wide; clients allow one
handler per endpoint. Reservation is transactional and an occupied slot survives
listener replacement. Removal/destruction invalidates old leases without
reinserting state. Rejections produce no response, log, queue, or retained
payload diagnostic. Cleanup never recursively deletes foreign descendants.

Relay has no persistence, purchases, currency, inventory, progression, readiness
handshake, automatic reconnect, retry, batching, RPC, middleware, or game/Core
dependency. Send success means local transport handoff, not receipt. Game code
owns authorization, semantic validation, and trusted-handler work. These are
remote-abuse and resource-exhaustion limits, not network availability or DDoS
protection; aggregate admission does not promise fairness.

Benchmark control/data remotes and bounded Studio-output collection stay outside
`src/` and retain their separately reviewed roster, shape, sequence, replay,
cardinality, size, and lifecycle bounds. New transport or payload features still
require dedicated design/security review.

The private reliable-event frame core treats every candidate value as hostile. Endpoint resolution is constant-time; exact arity is checked before allocation; field work follows only the immutable compiled schema; at most eight values are inspected and retained; tables, strings, buffers, and Instances are never traversed. The definition compiler similarly stops author-table scans at each frozen structural ceiling plus one. Neither module claims network-level availability protection.

The benchmark adapter boundary treats identity, selections, factory/side
shapes, delivery envelopes, and metadata as hostile where they enter their
owning layer. Resource roots and participant tokens remain opaque. The pure R1
construction boundary exposes no sink, root, fake driver, or scheduler through
runtime ports. The pure R1 runner charges lifecycle/phase gates and observation
caps, bounded-raw-preflights envelope and metadata, authenticates any sender,
and resolves the active expected identity before an eligible measured receipt
reads the clock immediately before payload comparison. Earlier rejections read
no measurement clock and malformed or spoofed deliveries stay out of comparator
processing. The pure R2 validator treats every remote-shaped table as hostile,
checks exact arity and structure before traversal, enforces fixed ingress and
replay budgets, and retains only canonical bounded evidence. It does not claim
transport authentication or engine-level availability.

## Tests

- `benchmarks/tests/external-adapter-lifecycle.luau` checks callback admission,
  unchanged raw records/varargs and sender tokens, final-before-return flush,
  malformed record visibility, and idempotent partial/failing cleanup without
  downloaded dependencies.
- `benchmarks/tests/external-library-payloads.luau` is an opt-in qualification
  command. It verifies pinned input bytes and generated outputs, then runs the
  seven Event V1 selections through actual library codecs and the existing
  comparator, including all 30 fixture repetitions, 1/4/8 broadcast recipients,
  fresh trusted probe echoes, and immediate/deferred input-mutation checks.
  `ExternalLibraryWorld` owns only the test engine services, transport copies,
  scheduling, and per-side module caches; no library serializer is substituted.

- `tests/runner.luau` proves the exact public module shape, frozen state, and manifest version parity.
- `tests/token-bucket.luau` proves finite constructor validation, full/empty boundaries, saturating refill, and backward-clock no-double-refill behavior.
- `tests/server-session.luau` proves current-player admission, malformed-call charging, targeted/broadcast fire counts, option and operation precedence, transactional handler caps, yielding listener replacement, roster races, deferred mutation loss, 10,000 admitted malformed calls without resource growth, contamination-safe cleanup, and 100 session cycles.
- `tests/client-session.luau` proves single-deadline discovery, runtime/option/startup precedence, module-slot races and cancellation, exact sends/receives, listener leases and errors, deferred mutation loss, cleanup, and 100 session cycles. Its injected engine harness and the server harness live only under `tests/support`.
- `tests/studio-reliable-events.luau` builds the isolated production place and requires real Studio result evidence for every declared correctness/admission topology. The host reopens and validates exact scenario completion; missing Studio/results or failed scenarios fail the command.
- `benchmarks/tests/relay-reliable-adapter.luau` proves public-only Relay composition, exact positional payload forwarding, fixed enabled rates, non-yielding readiness, roster attribution, generation isolation, teardown, and rejection of foreign provenance pins.
- `tests/definition.luau` proves the closed bounded schema grammar, canonical descriptor, Float32 and negative-zero rules, immutable copy isolation, opaque weak branding, and invalid-definition errors.
- `tests/frame.luau` proves constant-time endpoint/direction resolution, exact vararg arity including explicit `nil`, all six value validators and canonicalizers, and bounded no-traversal failure behavior.
- `benchmarks/tests/event-v1.luau` proves the immutable event workload, its
  single-sender invariant, audience, payload, probe, Studio execution, clock,
  measurement-source, quiescence, and validity contract.
- `benchmarks/tests/fixtures-event-v1.luau` proves exact fixture counts and ordering, identity and sequence stability, payload types and bounds, Float32 normalization, deterministic random isolation, recipient-independent broadcast fixtures, recursive immutability, fresh adapter inputs, and independent golden cases.
- `benchmarks/tests/payload-comparator.luau` proves exact record, vararg positional, and captured-positional payload verification, raw shape checks, Event V1 scalar and vector rules, exact Float32 bits, bounded first-mismatch diagnostics, and no expansion of attacker-selected arity.
- `benchmarks/tests/delivery-ledger.luau` proves receiver-local exact-once and fixture-order observation, comparator composition, bounded fault counters, one-time receipt/clean edges, non-sealing verification, and idempotent frozen close behavior.
- `scripts/verify-foundation.luau` aggregates the registered test set, module,
  exact cached release file set, tracked governance, LF, ignore, Wally
  packaging, Rojo build, and semantic CI workflow checks. It proves the exact
  push-`main`/unfiltered-pull-request trigger shape, all four Roblox artifact
  ignore suffixes, and the actual generated Wally and Rojo outputs after
  creation.

- `benchmarks/tests/result-v1.luau` proves the frozen Result V1 API,
  canonicalization and validation, terminal statuses, causal count and ledger
  reconciliation, structured failures, provenance, measurement summaries and
  cardinalities, exact rejection outside the adjacent-value even-median
  transport allowance, canonical numeric and environment-token forms,
  hostile-input bounds, sanitized environment, immutability, and semantic JSON
  round trips.
- `benchmarks/tests/adapter-contract.luau` proves shared identity/capability
  parity, the exact frozen five-key adapter surface, hostile preflight/context
  rejection including non-reflexive participant tokens, bounded
  record/positional envelopes, per-case operations, lifecycle/redaction
  behavior, and synchronous non-throwing sink handling without adapter-error
  reclassification, including closure of rejected yielding readiness calls.
- `benchmarks/tests/native-reliable-adapter.luau` proves the benchmark-only
  native reliable factory and side mappings, exact roster and endpoint
  readiness, pre-ready and stale callback rejection, authenticated C2S
  `Player` routing, broadcast S2C routing, positional payload forwarding without
  fixture mutation, endpoint-conflict latching, server-only endpoint
  destruction, and idempotent teardown.
- `benchmarks/tests/host-manifest-v1.luau` proves exact trusted-manifest shape,
  adapter/artifact/selection relations, bounded hostile-table rejection,
  canonical copied output, and recursive immutability.
- `benchmarks/tests/harness-termination-v1.luau` proves the exact three-key
  no-Result envelope, fixed code/stage enums, redaction, hostile-shape
  rejection, copy isolation, and Result V1 separation.
- `benchmarks/tests/fake-adapter.luau` proves the deterministic test-only
  AdapterContract implementation, bounded scripted faults, lifecycle isolation,
  same-frame tail delivery after adapter calls return, and probe composition
  from `generateProbe` with a fresh non-aliased trusted response record.
- `benchmarks/tests/delivery-router.luau` proves stable sink identity, exact
  active arity forwarding, pre-bind and pre-arm latching, atomic stale-only
  observation, persistent disable results, fixed misuse errors, and hostile
  post-disable no-traversal behavior.
- `benchmarks/tests/session-owner.luau` proves zero-construction rejection,
  exact semantic topology derivation through `clientProcessCount`, rejection of
  non-reflexive tokens, frozen server-then-client runtime ports, shared opaque
  root construction, partial rollback precedence, and one-attempt cached root
  cleanup for successful, throwing, and yielding destroy functions.
- `benchmarks/tests/timing-recorder.luau` proves the exact recorder surface,
  contract-owned timing boundaries and cardinalities, exclusion transitions,
  guarded clock proof, candidate retain/discard identity, immutable freeze, and
  fixed misuse sentinels.
- `benchmarks/tests/runner-state.luau` proves guarded benchmark clocks, bounded
  generation/case state, workload and probe progress, callback budgets,
  both 60-frame quiescence windows, role-independent `IsolationFailure`, pre-
  measured and measured abort edges, clock-failure disposition, failure
  reconciliation, bounded input-mutation invalidation, and recursively immutable
  evidence snapshots. It also exercises the engine-independent `RunnerKernel`
  lifecycle, mutation, and deadline paths.
- `benchmarks/tests/generation-activation.luau` proves same-process
  attach/setup/readiness/arm composition, timeout and pre-ready disposition,
  reverse rollback, and cleanup precedence. Distributed server activation also
  accepts the exact fragment CaseState while rejecting unknown fields and a
  non-callable fragment snapshot method.
- `benchmarks/tests/result-draft-assembler.luau` proves sole projection from a
  frozen run snapshot and trusted host inputs into exact Result V1 drafts,
  including counts, measurements, failure groups, finality, fixed finalization
  failure, and exact 30-fragment ProcessRestart aggregation.
- `benchmarks/tests/repetition-fragment-v1.luau` proves the exact 1 MiB fragment
  contract, participant/measurement cardinality, pre-start and completed timing
  relations, provenance binding, hostile structure rejection, and detached
  recursive freezing.
- `benchmarks/tests/result-reporter.luau` proves strict pre-read file and JSON
  bounds, complete Result V1 validation, matching strata and compatibility
  cohorts, non-valid evidence separation, inert Markdown output, and the absence
  of an overall score or winner.
- `benchmarks/tests/case-runner.luau` proves branded whole-case construction,
  the full selection matrix dynamically derived from every Event V1 workload,
  its audience-owned recipient variants, and every probe, with every scheduled
  repetition completed per selection. It also proves clock behavior, stepped
  frame and reset barriers, trusted fanout fault containment and deduplication,
  partial aborts, setup/submit/teardown/cleanup precedence, warmup mutation with
  ordinary teardown failure, immutable evidence, and finalized Result or bounded
  harness termination.
- `benchmarks/tests/control-protocol.luau` proves the exact frozen two-key
  module, eight-method coordinator, five-method participant, 1/4/8 barriers,
  roster and sequence binding, ingress/replay limits, response expiry, quiet and
  clock paths, bounded two-pass clock readiness without physical evidence,
  exact completed optional cardinality, bounded counter-reconciled
  hostile facts, cross-participant warmup-mutation teardown evidence and
  rejection without its cause, final overflow, and persistent rejection
  dispositions including scalar repetition rejection without an engine or
  `RemoteEvent` dependency.
- `benchmarks/tests/studio-runner.luau` proves the native module and complete
  Rojo dependency mapping, exact full-identity allowlist, the seven-adapter
  ProcessRepetition admission/readiness path, and all seven
  manifest-derived selections and topologies, preserved ControlProof, quiet
  signals bound to repetition and generation, direction-aware measured-start
  receiver barriers, latched failure precedence at completed waits and barriers,
  receiver readiness before S2C warmup and cleanup of measured and terminal
  participant failures, setup-deadline enforcement for clock readiness and the
  readiness-before-physical-proof source order, and QuickNet's cloned-library
  transport ownership,
  teardown/root-observation order, final Result-or-termination handling, and
  exact one-`EndTest` structure.
- `benchmarks/tests/host-runtime.luau` proves all seven Benchmark CLI
  selections, the server-only carrier and secret-free RunScript bootstrap,
  unique per-launch Rojo builds, exact pre-carrier place fingerprinting,
  independent Studio attestation, one authenticated ordered terminal-frame
  sequence, pre-read output and parser bounds, closed-root and provenance
  validation, no-write failures, cleanup, and atomic no-overwrite publication.
  It also proves exact external fragment framing/binding, sequential 30-child
  lifecycle and census-before-cleanup, clean-source publication gates, direct
  CLI argument failures, and non-`Valid` Result exit failures after diagnostic
  publication.
- `benchmarks/tests/external-adapter-catalog.luau` proves the closed adapter
  identities, Suphi fail-closed decision, selected-only HTTP-disabled Rojo
  compositions, exact runtime/generated/Warp mappings, and real project builds.
- `benchmarks/tests/benchmark-libraries.luau` proves the exact eight-candidate
  lock, safe artifact paths, exact streamed tool-archive byte ceilings, bounded
  child output, raw-byte checksum framing, runtime/tool partition, opt-in runtime
  mappings, and continued native-project independence.

- `benchmarks/tests/persistent-contracts.luau` proves strict V1/V2 separation,
  exact persistent identity/host/result shapes, fingerprints, and session proof.
- `benchmarks/tests/persistent-transport.luau` proves one raw lifecycle across
  30 windows, unchanged active routing, stale/gap failures, exact non-yielding
  raw calls, fixed selection/roster, and sticky one-attempt physical cleanup.
- `benchmarks/tests/persistent-runner.luau` proves V2 whole-case admission,
  process-fragment rejection, and frozen passed-proof-only result projection.
- `benchmarks/tests/persistent-host.luau` proves explicit new-mode collection,
  manifest/provenance binding, compatible measurement fingerprints, rejection
  boundaries, and actual Rojo composition without starting Studio.
- `benchmarks/tests/persistent-reporter.luau` proves mixed-version validation,
  lifecycle separation, shared-measurement compatibility, and CLI readback.
- `benchmarks/tests/session-reuse-observer.luau` and `session-reuse-host.luau`
  preserve the earlier non-ranking pilot's receiver and collection checks.

## Current status

The reliable-event vertical slice is implemented and its definition,
frame, token-bucket, server-session, and client-session tests pass. The private
real Studio matrix and dedicated production/adapter review passed before the
atomic public export. The complete matrix then passed through the public API
on Studio 0.737.0.7371584: one/two-client correctness and one/four/eight-client
admission, including mixed honest traffic and 100 cleanup cycles. The wrapper
requires exact topology/scenario completion, and is separate from the portable
aggregate verifier and timing benchmarks. Local proof JSON remains ignored.

`benchmarks/adapters/relay-reliable/init.luau` depends only on the public Relay
API, with setup outside timing, public session destruction, positional delivery,
one-call native broadcast, and zero intentional added delivery frames. Its fixed
rate profile is per-player 4096 capacity/2048 refill per second and aggregate
32768 capacity/16384 refill per second; production validation and handler caps
stay enabled. The adapter rejects reuse of the previous exact client transport
while replication catches up between harness generations. The optional host
`--adapter relay-reliable` selection binds exact built production source bytes
and revision to the host-created server/client allowlist pin; the complete place
fingerprint covers the adapter and harness too. No Relay performance comparison
is claimed without a valid Result V1.
All seven real Relay selections completed 30 valid repetitions each on
2026-09-04 with Studio 0.737.0.7371584 and clean source provenance. Their
collected/reopened Result V1 files remain ignored local artifacts. The Relay
execution matrix is complete; the external matrix and cross-library comparisons
are not claimed complete.

The pure R1 runner is implemented. The exact frozen runtime modules are
`SessionOwner`, `BenchmarkClock`, `TimingRecorder`, `RunState`, `RunnerKernel`,
`GenerationActivation`, `CaseRunner`, and `ResultDraftAssembler` alongside the
existing `DeliveryRouter`; `KernelFanout` is a private CaseRunner-only helper,
not a caller-facing module surface. `CaseRunner` accepts only a branded prepared session,
owns one case clock and state across generation restarts, composes the
deterministic fake through `AdapterContract`, closes every generation through
both required quiet windows plus the observation and cleanup barriers, and
returns either a finalized validated Result V1 value or the bounded no-Result
termination envelope. Its clean proof enumerates the Event V1 selection matrix
from the contract rather than a copied case list.

The pure R2 `ControlProtocol` validator is implemented with its exact two-key
module, eight-method coordinator, and five-method participant surfaces. It
validates only bounded scalar control and canonical participant evidence,
including 1/4/8 participant barriers, response expiry, clock and timing
conformance, replay/ingress ceilings, and representable versus unrepresentable
distributed overflow. It imports no R1 state object and creates no transport or
engine object.

The focused R1, R2, and native adapter tests are registered in
`scripts/verify-foundation.luau`. The amended runner and control contracts were
independently re-reviewed on 2026-08-29 after the five-key `AdapterContract`
implementation, and the runner consumes only that implemented contract rather
than a stale adapter shape.

R0 prerequisites remain the independent probe fixtures, captured-positional
comparison, same-frame post-return fake delivery, trusted host input, bounded
no-Result return, whole-case `SessionRestart` or exact one-index
`ProcessRestart` isolation, out-of-band warmup rejection,
and honest distributed-overflow disposition. The benchmark workspace also
includes the Result V1 finalizer/validator and one deterministic test-only fake.
The fake is never selectable for a real benchmark and never enters a result.

The pure R1/R2 proofs, scalar Studio ControlProof path, authenticated host
collection, native `RemoteEvent` adapter, exact positive executable binding,
complete Rojo runtime mapping, coordinator/participant generation composition,
fixed-slot `FinalReport` merge, and terminal
`RunState -> ResultDraftAssembler -> ResultV1` chain are implemented. The live
1/4/8-client scalar ControlProof matrix passed on 2026-08-30 UTC. Focused pure,
Studio-static, host, and Rojo-build proofs pass, and the live seven-selection
native-baseline Benchmark matrix passed on 2026-09-02 UTC. External adapter
codec qualification does not create a committed or published competitor
benchmark result. The closed Event V1
contract continues to target its three one-client C2S workloads, 1/4/8-client
broadcast workload, and one-client round-trip probe; no 20-client execution
profile exists.
Pinned external source and compiler artifacts can now be acquired into ignored
local vendor paths.
On 2026-09-03 all eight external adapters passed the untimed seven-selection,
30-repetition codec qualification matrix: 94,200 verified deliveries per library.
The QuickNet pilot preceded the remaining runtime bindings and the Blink pilot
preceded the remaining generated bindings. The fresh-process Studio composition,
replication-readiness gates, fragment contract, and host aggregation path are now
implemented and statically verified. QuickNet's three C2S selections and
one-client broadcast selection have collected/reopened valid Result V1 files,
each with 30 fresh-process repetitions, clean source provenance, and no delivery
errors. The remaining measured external selections are not complete. A later
QuickNet burst batch and its diagnostic rerun terminated before publication;
the diagnostic captured a fatal physical shared-clock bracket failure before
warmup. The strict clock proof remains unchanged, and failed batches contribute
no fragments to subsequent runs or comparisons.
The process client consumes ControlProtocol's kind-only preparation action;
the protocol owns wire repetition-index validation, and the client advances its
local index within the selected window. The Studio runner regression executes
that action for global repetitions 1 and 30 and checks wrong-index wire rejection.

Benchmark iteration is being optimized separately from the frozen measured
path. `benchmarks/session-reuse-review.md` specifies one persistent transport
per exact adapter/case/topology, with 30 independently checked fixture windows,
instead of 30 Studio launches. `benchmarks/tests/external-session-reuse.luau`
is an opt-in, untimed simulated-engine feasibility proof using existing pinned
libraries and one initialization per side per selection. It creates no Result
V1, proves no Studio timing or replication, and does not remove Suphi's timing
blocker. Persistent windows must not be mislabeled as restart repetitions.
All eight adapters passed the reuse feasibility proof on 2026-09-05: seven
selections, 210 windows, and 94,200 checked deliveries per adapter.
At the feasibility stage the measured runner and existing validated results
were unchanged; full matrix launches remain paused during integration testing.
The corrected simulated proof now separates warmup and measured sending with
completion, 60 quiet frames, and cardinality checks after each phase; QuickNet
and Zap passed that correction. `benchmarks/pilot/` adds a deliberately fixed
real-Studio development runner for those two libraries, one-client
`state-burst-c2s`, and 30 windows per single test-session launch. It reuses the
existing host/artifact/readiness/fixture/comparator/local-clock leaves and owns
one physical adapter/root per side, with a permanent failure-latching server
receipt observer. The dedicated runtime design/security review found no blocker;
the observer and authenticated host collector regressions pass without Studio.
On 2026-09-06 UTC, QuickNet and Zap both passed all 30 windows and 2,400 deliveries
in real Studio, taking 70.62 and 60.84 seconds end to end respectively. Both
initialized each side once and exited with no Studio process remaining.
Pilot JSON is ignored, explicitly non-ranking/non-Result-V1, and records dirty
development provenance and exact composed-place bytes honestly. Local timing
only is reported; shared-clock proof is explicitly not run. This does not prove
the remaining selections or promote a persistent lifecycle into the frozen V1
contracts. The legacy Benchmark command still uses process restarts. No
production, vendor, or V1 contract source changed for that pilot.

The measured integration now uses explicit PersistentBenchmark, HostManifestV2,
ResultV2, and the ordinary Studio/R1/R2 runner with PersistentTransport ownership.
The dedicated runtime design/security review found no static blocker; the full
portable repository gate including new/legacy local checks passes. On
2026-09-06 UTC, real measured QuickNet one-client burst, QuickNet four-client
broadcast, and Zap one-client round-trip checks passed at clean `bb6515f`.
Each produced a valid V2 with 30 completed windows, clock/session proof, and
confirmed Studio exit. These establish the three execution paths, not a full
comparison matrix. The updated goal excludes Suphi and the optional native
baseline, covering Relay and seven eligible externals (56 selections). Old Relay V1
completion remains valid history but cannot supply persistent comparison rows.

Subsequent persistent collection completed QuickNet's and Zap's seven-selection
matrices: 14 valid V2 artifacts, 30 windows each, no retries, and confirmed Studio
exit. Strict reporter readback validated all 14; earlier readback also validated
two historical V1 files. Matching persistent burst/probe rows compare
across the documentation-only `bb6515f` to `edffc07` revision change because the
shared measurement fingerprint is unchanged; restart results stay separate.
The remaining persistent adapter/Relay comparison matrices are incomplete.
Local results and the generated partial comparison stay ignored.

Time/consistency investigation found repeated warmup/quiet periods remain, and
offline first-10-versus-all-30 analysis can shift reported medians by about 24%.
This is not proof of CPU/GPU causation or justification to reduce sample counts.
The base benchmark place now sets Players.CharacterAutoLoads=false, removing
irrelevant automatic avatar work before players join. Fixtures/adapters use
Player identities but not characters. Existing native and external actual-build
checks enforce the setting; sample counts and protocol checks are unchanged.
A bounded live QuickNet one-client burst check passed at clean `993a745` with
30 valid windows, 1,200 correct measured deliveries, clock/session proof, and
confirmed Studio exit. Host elapsed time was 50.2 seconds versus an earlier
105.6-second observation; this unpaired check does not establish a repeatable
speedup or machine stability. Strict reporter readback keeps the changed
composition separate: the new avatar-free cohort has one valid selection and
the previous 14 results remain historical evidence. Full collection remains
paused pending the time/stability decision; no full-matrix development rerun.
