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

Relay owns strict Result V1 benchmark-envelope finalization and validation outside the published Wally package.

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

Relay owns two pure benchmark-internal R0 contracts. `HostManifestV1` validates,
copies, and freezes the exact trusted host evidence R1 may consume;
`HarnessTerminationV1` owns the exact bounded no-Result envelope. Neither
contract acquires host data, loads a module, creates an engine object, or moves
data across a process boundary.

Relay owns the first pure R1 construction boundary. `DeliveryRouter` creates a
stable adapter sink with a one-time bind/arm gate, a stale-only teardown
observer, a persistent defensive pre-arm latch, and a permanent disabled no-op.
`SessionOwner` revalidates trusted host and adapter selection, enforces
SessionRestart and exact runtime rosters before construction, creates one
generation root, constructs server then client ports, and owns bounded partial
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
Result V1 draft that `CaseRunner` finalizes. These modules expose only the exact
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
budgets, multi-slot barriers, response expiry, timing-conformance reconciliation,
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
Studio version or the host-pinned exact Relay identity. `native-reliable`
validates and caches its exact roster and
remote during readiness before any timed submit or broadcast. The Rojo place,
native adapter, engine clocks, and Studio proof remain outside `src/` and do not
change the Wally package.

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

Relay owns the benchmark-only host launcher and IPv4-loopback collector. Each
launch receives a unique ignored Rojo build whose exact pre-carrier bytes supply
the place fingerprint, then a server-only `LaunchCarrier`; the generic RunScript
contains no embedded capability and destroys the carrier before multiplayer
execution. The collector accepts one authenticated terminal POST, uses
independent Studio-version attestation, validates a closed
ControlProof/termination/Result root and complete provenance, and publishes only
a valid Result V1 by same-directory no-overwrite move. ControlProof writes no
result.
`HostRuntime` owns the importable launcher and collector implementation;
`run-event-v1.luau` always validates command-line arguments and invokes it.
Schema-valid non-`Valid` Results remain available as diagnostic artifacts, but
the benchmark command returns a failure with the Result status instead of
printing `PASS`.
Forced-kill acknowledgements from Lune do not prove OS process exit. The host
retains protected launch files and fails with `HOST_E_CHILD_LIVE` after a kill
attempt, including exception paths; descendant-process termination remains
unproven with the current launcher.
Windows launch preflight rejects active Studio processes with
`HOST_E_STUDIO_BUSY` to avoid the observed shared `server.rbxl` quick-save
collision. Process inspection failure is bounded and fails closed. This is a
read-only guard, not atomic serialization against other launchers; Studio test
sessions must still run serially.

Relay owns the benchmark-only external-library lock, acquisition command, and
opt-in runtime-library Rojo mapping. They place exact Git source artifacts and
hash-pinned Windows code-generation tools beneath ignored vendor paths, verify
existing bytes without overwriting them, and leave the ordinary native
benchmark project independent of third-party files. Relay does not own the
downloaded libraries or grant redistribution rights for them.

Relay owns eight external benchmark adapter bindings and their private
`ExternalAdapter` lifecycle helper. They translate the existing Tiny/State
operations to each pinned library's public API and forward original decoded
records or positional values through AdapterContract. Generated adapters have
tracked schema inputs and an ignored, byte-verified deterministic generation
workflow. These adapters require process isolation and remain outside the
measured host. The qualification harness executes actual unmodified library
codecs in fresh simulated engine worlds; it does not prove Studio transport,
replication readiness, process cleanup, decoder security, or timing eligibility.
Warp has an explicit untimed `Endpoint` prewarm because its client constructor
yields. Its broken pinned Destroy path is avoided using public callback
disconnection, with full cleanup deferred to process exit. Suphi's unresolved
license and sender-frame scheduling remain documented eligibility blockers.

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

Benchmark control/data remotes and loopback collection stay outside `src/` and
retain their separately reviewed roster, shape, sequence, replay, cardinality,
size, and lifecycle bounds. New transport or payload features still require
dedicated design/security review.

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

- `benchmarks/tests/result-v1.luau` proves the frozen Result V1 API, canonicalization and validation, terminal statuses, causal count and ledger reconciliation, structured failures, provenance, measurement summaries and cardinalities, canonical numeric and environment-token forms, hostile-input bounds, sanitized environment, immutability, and semantic JSON round trips.
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
  reverse rollback, and cleanup precedence.
- `benchmarks/tests/result-draft-assembler.luau` proves sole projection from a
  frozen run snapshot and trusted host inputs into exact Result V1 drafts,
  including counts, measurements, failure groups, finality, and fixed
  finalization failure.
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
  clock paths, exact completed optional cardinality, bounded counter-reconciled
  hostile facts, cross-participant warmup-mutation teardown evidence and
  rejection without its cause, final overflow, and persistent rejection
  dispositions including scalar repetition rejection without an engine or
  `RemoteEvent` dependency.
- `benchmarks/tests/studio-runner.luau` proves the native module and complete
  Rojo dependency mapping, exact full-identity allowlist, all seven
  manifest-derived selections and topologies, preserved ControlProof, quiet
  signals bound to repetition and generation, direction-aware measured-start
  receiver barriers, latched failure precedence at completed waits and barriers,
  receiver readiness before S2C warmup and cleanup of measured and terminal
  participant failures,
  teardown/root-observation order, final Result-or-termination handling, and
  exact one-`EndTest` structure.
- `benchmarks/tests/host-runtime.luau` proves all seven Benchmark CLI
  selections, the server-only carrier and secret-free RunScript bootstrap,
  unique per-launch Rojo builds, exact pre-carrier place fingerprinting,
  independent Studio attestation, exactly one terminal POST, capability and
  parser bounds, closed-root and provenance validation, no-write failures,
  cleanup, and atomic no-overwrite publication.
  It also proves direct CLI argument failures and non-`Valid` Result exit failures
  after diagnostic publication.
- `benchmarks/tests/benchmark-libraries.luau` proves the exact eight-candidate
  lock, safe artifact paths, raw-byte checksum framing, runtime/tool partition,
  opt-in runtime mappings, and continued native-project independence.

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
The real one-client Relay `state-burst-c2s` case completed 30 valid repetitions
on 2026-09-03 with Studio 0.737.0.7371584. Its collected/reopened Result V1 is an
ignored local artifact with exact dirty source provenance; the remaining Relay
matrix and comparisons are not claimed complete.

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
no-Result return, `SessionRestart`-only isolation, out-of-band warmup rejection,
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
Benchmark matrix passed on 2026-09-02 UTC. External adapter codec qualification
does not create a committed or published competitor benchmark result. The closed Event V1
contract continues to target its three one-client C2S workloads, 1/4/8-client
broadcast workload, and one-client round-trip probe; no 20-client execution
profile exists.
Pinned external source and compiler artifacts can now be acquired into ignored
local vendor paths.
On 2026-09-03 all eight external adapters passed the untimed seven-selection,
30-repetition codec qualification matrix: 94,200 verified deliveries per library.
The QuickNet pilot preceded the remaining runtime bindings and the Blink pilot
preceded the remaining generated bindings. Fresh-process Studio composition and
replication-readiness proof remain necessary before measured integration.
