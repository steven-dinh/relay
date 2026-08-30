# Relay Context

## Purpose

Relay is a standalone Roblox networking library. The current foundation establishes a minimal loadable package and reproducible development, packaging, testing, example, and benchmark boundaries. The benchmark workspace includes a versioned contract for equivalent reliable-event workloads, execution topology, timing ownership, and measurement quality, a pure R1 whole-case runner, a pure R2 control-protocol validator, and the Plan 4 Studio control/host collection path.

## Ownership

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
Measured submit clock reads sit immediately beside the adapter operation inside
non-yielding containment, excluding runner transition, containment, and clock-
call machinery while retaining `AdapterContract` and final-in-frame
`FlushBeforeReturn` work.

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
the frozen schema cannot support.

Relay owns the benchmark-only Plan 4 Studio control path. The coordinator owns
the server-only validated HostManifest, engine roster, topology latch, one
control RemoteEvent, measured-quiet release, cleanup, and the sole `EndTest`;
each participant owns only its engine-bound control slot. The Plan 4
`AdapterAllowlist` is empty and rejects before any adapter load. The Rojo place,
engine clock adapter, and focused Studio-static proof remain outside `src/` and
do not change the Wally package.

Relay owns the benchmark-only Plan 4 host launcher and IPv4-loopback collector.
A Lune launcher inserts a server-only `LaunchCarrier` into an ignored
per-launch place, while the generic RunScript contains no capability and
destroys the carrier before multiplayer execution. The collector authenticates
one bounded request, validates a closed ControlProof/termination/Result root,
performs complete provenance checks, and publishes only a valid Result V1 by
same-directory no-overwrite move. Plan 4 has one fixed 120-second ControlProof
deadline and writes no ControlProof result.

Relay owns this repository, its package metadata, public source under `src/`, correctness tooling, examples boundary, benchmark contracts, Event V1 fixtures, payload comparison, receiver-local delivery verification, and benchmark workspace.

## Non-ownership

Relay does not own game-specific Core behavior, gameplay policy, persistence, purchases, economy, progression, UI, or third-party benchmark libraries. Future game adapters may depend on Relay; Relay must not depend on them.

## Public API

`src/init.luau` returns a frozen table with one field:

- `VERSION: string` — equal to the Wally package version.

No networking API exists in the foundation slice.

## Configuration and dependencies

- Package identity: `steven-dinh/relay`.
- Version: `0.1.0`.
- Realm: `shared`.
- Runtime, server, and development dependencies: none.
- Tool versions are pinned in `rokit.toml`.
- Wally publication remains disabled with `private = true`.
- `.gitattributes`, `AGENTS.md`, `context.md`, and `docs/plans/**` are tracked
  governance inputs; `.gitattributes` pins repository text to LF.
- The aggregate verifier compares the exact cached Git index to the release
  allowlist and requires CI on pushes only to `main` plus every unfiltered pull
  request, with no additional trigger.
- Local Forge specs/reports, generated outputs, downloaded dependencies,
  benchmark vendors, and local benchmark results remain ignored.
- The four literal Roblox ignore probes are `artifacts/probe.rbxl`,
  `artifacts/probe.rbxlx`, `artifacts/probe.rbxm`, and
  `artifacts/probe.rbxmx`.

## Security and persistence

The published Relay package has no remotes, inbound decoding, replication,
persistence, purchases, currency, inventory, or progression. The benchmark-only
Plan 4 control RemoteEvent and loopback JSON collector are isolated outside
`src/`, treat every remote value and byte stream as hostile, and enforce their
reviewed bounds. No native benchmark data transport exists yet. Any future
inbound surface requires its own attacker-controlled input limits and abuse
tests.

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

- `tests/runner.luau` proves the exact public module shape, frozen state, and manifest version parity.
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
  reclassification.
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
  reconciliation, and recursively immutable evidence snapshots. It also
  exercises the engine-independent `RunnerKernel` lifecycle and deadline paths.
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
  partial aborts, setup/submit/teardown/cleanup precedence, immutable evidence,
  and finalized Result or bounded harness termination.
- `benchmarks/tests/control-protocol.luau` proves the exact frozen two-key
  module, eight-method coordinator, five-method participant, 1/4/8 barriers,
  roster and sequence binding, ingress/replay limits, response expiry, quiet and
  clock paths, exact completed optional cardinality, bounded counter-reconciled
  hostile facts, final overflow, and persistent rejection dispositions without
  an engine or `RemoteEvent` dependency.
- `benchmarks/tests/studio-runner.luau` proves the Plan 4 Rojo topology,
  server-only empty allowlist, real coordinator/participant sources, engine
  clocks, scalar quiet handshake, immediate fail-closed disconnect for invalid
  special scalar ingress, cleanup, and exact one-`EndTest` structure.
- `benchmarks/tests/host-runtime.luau` proves the server-only carrier and
  secret-free RunScript bootstrap launch,
  exact ControlProof CLI, capability and parser bounds, closed-root and
  provenance validation, no-write failures, cleanup, and atomic no-overwrite
  publication.

## Current status

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

The focused R1 and R2 tests are registered in
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

Plan 4's pure R1/R2 proofs, scalar Studio ControlProof path, and authenticated
host collection are implemented. The benchmark place contains the scalar
control `RemoteEvent` topology, empty server-only allowlist, Studio
coordinator/participant control scripts, and engine clocks; the host owns the
authenticated loopback collector and ignored publication path. The live
1/4/8-client scalar ControlProof matrix passed on 2026-08-30 UTC, completing the
approved Plan 4 exit gate. Plan 5 still owns the Studio mapping and composition
of the R1 modules, adapter-generation roots, `openServerPrepared`/`openClient`,
fixed-slot `FinalReport` merge, and the first complete
`RunState -> ResultDraftAssembler -> ResultV1` chain. There is still no native
adapter, positive executable binding, complete Studio benchmark Result path,
codec, schema compiler, generated production code, batching, RPC, middleware,
rate limiting, Core adapter, competitor download, or committed local
benchmark-result artifact. The closed `event-v1` contract continues to target
reproducible 1/4/8-client Studio runs; no 20-client execution profile exists.
