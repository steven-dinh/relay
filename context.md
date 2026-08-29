# Relay Context

## Purpose

Relay is a standalone Roblox networking library. The current foundation establishes a minimal loadable package and reproducible development, packaging, testing, example, and benchmark boundaries. The first benchmark artifact is a versioned, runner-independent contract for equivalent reliable-event workloads, execution topology, timing ownership, and measurement quality.

## Ownership

Relay owns strict Result V1 benchmark-envelope finalization and validation outside the published Wally package.

Relay owns a benchmark-only `AdapterContract` that shares canonical adapter
identity, Event V1 case resolution, and capability-requirement validation with
Result V1. It preflights adapter factories, creates frozen side contexts and
bounded raw-delivery envelopes, and enforces side-local lifecycle transitions.
It owns no real transport, runner clock, participant authentication, ledger,
reporter, or mutable result.

Relay owns two pure benchmark-internal R0 contracts. `HostManifestV1` validates,
copies, and freezes the exact trusted host evidence R1 may consume;
`HarnessTerminationV1` owns the exact bounded no-Result envelope. Neither
contract acquires host data, loads a module, creates an engine object, or moves
data across a process boundary.

Relay owns the first pure R1 construction boundary. `DeliveryRouter` creates a
stable adapter sink with a one-time bind/arm gate, a stale-only teardown
observer, a persistent pre-ready latch, and a permanent disabled no-op.
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
`CleanupFailure/Finalize` termination. These modules create no engine object,
remote, clock, frame driver, adapter payload oracle, or result.

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
- Local Forge specs/reports, generated outputs, downloaded dependencies,
  benchmark vendors, and local benchmark results remain ignored.

## Security and persistence

No remotes, inbound decoding, replication, persistence, purchases, currency, inventory, or progression exist. Planned networking properties are not implemented guarantees. Any future inbound surface requires attacker-controlled input limits and abuse tests.

The benchmark adapter boundary treats identity, selections, factory/side
shapes, delivery envelopes, and metadata as hostile where they enter their
owning layer. Resource roots and participant tokens remain opaque. The pure R1
construction boundary exposes no sink, root, fake driver, or scheduler through
runtime ports. A future execution kernel must timestamp sink entry first,
authenticate metadata in a non-throwing terminal latch, and keep malformed or
spoofed deliveries out of comparator and ledger processing.

## Tests

- `tests/runner.luau` proves the exact public module shape, frozen state, and manifest version parity.
- `benchmarks/tests/event-v1.luau` proves the immutable event workload, its
  single-sender invariant, audience, payload, probe, Studio execution, clock,
  measurement-source, quiescence, and validity contract.
- `benchmarks/tests/fixtures-event-v1.luau` proves exact fixture counts and ordering, identity and sequence stability, payload types and bounds, Float32 normalization, deterministic random isolation, recipient-independent broadcast fixtures, recursive immutability, fresh adapter inputs, and independent golden cases.
- `benchmarks/tests/payload-comparator.luau` proves exact record, vararg positional, and captured-positional payload verification, raw shape checks, Event V1 scalar and vector rules, exact Float32 bits, bounded first-mismatch diagnostics, and no expansion of attacker-selected arity.
- `benchmarks/tests/delivery-ledger.luau` proves receiver-local exact-once and fixture-order observation, comparator composition, bounded fault counters, one-time receipt/clean edges, non-sealing verification, and idempotent frozen close behavior.
- `scripts/verify-foundation.luau` aggregates the registered test set, module,
  tracked-governance/file-set, LF, ignore, Wally packaging, Rojo build, and
  semantic CI workflow checks. It also proves the actual generated Wally and
  Rojo outputs remain ignored after creation.

- `benchmarks/tests/result-v1.luau` proves the frozen Result V1 API, canonicalization and validation, terminal statuses, causal count and ledger reconciliation, structured failures, provenance, measurement summaries and cardinalities, canonical numeric and environment-token forms, hostile-input bounds, sanitized environment, immutability, and semantic JSON round trips.
- `benchmarks/tests/adapter-contract.luau` proves shared identity/capability
  parity, the exact frozen five-key adapter surface, hostile preflight/context
  rejection including non-reflexive participant tokens, bounded
  record/positional envelopes, per-case operations, lifecycle/redaction
  behavior, and timestamp-first non-throwing sink handling.
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

## Current status

The approved pure R1 construction boundary is implemented. `SessionOwner`
creates each stable sink before adapter construction and exposes only a one-time
bind/arm/observe/disable gate through a frozen runtime port. Pre-ready calls
latch the fixed no-Result disposition. Before teardown, the gate can atomically
replace its active handler with a zero-argument stale-only observer; disable
makes later calls permanent no-ops.

The remaining pure execution kernel is not implemented. The independently
re-approved runner plan now freezes branded zero-construction
`SessionOwner.prepare/requirePrepared`, construction-only `openPrepared`, one
case-owned server clock and deadline capability, exact `RunState`,
`TimingRecorder`, `RunnerKernel`, `GenerationActivation`, stepped `CaseRunner`,
and `ResultDraftAssembler` APIs. The control security plan likewise freezes the
pure R2 `ControlProtocol` module and state API while approving no RemoteEvent.
Both amended designs passed independent design, security, and reachability
review on 2026-08-29; implementation and their focused exit proofs remain.

R0 closes the prerequisites for the pure R1 runner: independent probe fixtures,
captured-positional comparison, same-frame post-return fake delivery, trusted
host input, the bounded no-Result return, SessionRestart-only isolation,
out-of-band warmup rejection, and honest distributed-overflow disposition. The
exact control catalog and security ceilings are persisted for a later pure R2
validator. No `RemoteEvent`, launcher transport, module loader, JSON collector,
native adapter, execution kernel, or result assembler is added by this slice.

The benchmark workspace includes the Result V1 finalizer/validator, the
benchmark-only AdapterContract, and one deterministic test-only fake. A shared
internal identity owner preserves Result V1's exact serialized and seven-key
runtime surface while serving adapter and manifest preflight. The fake is never
selectable for a benchmark and never enters a result. Result V1 validates and
freezes a runner-assembled envelope but does not launch benchmarks, attest
observations, encode or decode raw JSON, collect, egress, persist, publish, or
create a benchmark result.

Foundation plus the closed `event-v1` benchmark contract, deterministic workload/probe fixture generator, payload comparator, receiver-local delivery ledger, and pure runner construction boundary. The comparator verifies exact named-record, descriptor-ordered vararg, or bounded captured-positional payloads and returns one bounded mismatch. The ledger records exact first deliveries, duplicates, unexpected or out-of-order identities, mismatches, and missing expectations without retaining attacker-controlled input; verification remains open until an idempotent frozen close. The contract targets reproducible 1/4/8-client Studio runs; no 20-client execution profile exists. No execution kernel, real adapter, result extractor, codec, schema compiler, generated code, production transport, batching, RPC, RemoteEvent ownership, middleware, rate limiting, Core adapter, competitor download, or benchmark result exists.
