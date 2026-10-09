# Relay Context

## Purpose and boundaries

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. Publishable source lives
under `src/`; it has no game repository, Core, or runtime dependency.

The Wally package is `steven-dinh/relay` version `0.1.0`, realm `shared`.
Publication is disabled with `private = true`. Tool versions are pinned in
`rokit.toml`.

The approved public surface is `VERSION`, `schema`, `define`, `inspect`, `createServer`, and `createClient`. Sessions expose `events`, `requests`, `Start`, idempotent `Destroy`, `GetDiagnostics`.
Event handles expose direction-specific `Connect`, `Send`, and `Broadcast`;
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
remains authoritative. [README.md](README.md) owns usage, schema grammar,
options, error codes, and the [protocol contract](README.md#protocol-and-abuse-limits).

## Runtime ownership

| Module | Responsibility |
| --- | --- |
| `src/init.luau` | Public exports, version, and schema-derived event names, methods, and payload types. |
| `src/Schema.luau` | Frozen schema authoring constructors and bounded event-map composition. |
| `src/internal/Diagnostics.luau` | Fixed saturating session counters and immutable snapshots. |
| `src/internal/RpcFrame.luau` | Checked RPC identity envelope and owned body copying. |
| `src/Definition.luau` | Closed schema grammar, opaque definition identity, immutable bounded shape compilation, deterministic descriptors, and Float32 canonicalization. |
| `src/internal/Frame.luau` | Endpoint/direction lookup, compiled fixed-arity primitive validators, and decode-specific scalar normalizers. |
| `src/internal/CompositeCodec.luau` | Bounded composite validation, buffer encoding, and checked decoding using Frame's scalar normalizers and raw checks. |
| `src/internal/TokenBucket.luau` | Bounded token buckets, saturating refill, and monotonic clock clamping. |
| `src/ServerSession.luau` | Transport ownership, current-player admission, handler leases, dispatch, sends/broadcasts, and cleanup. |
| `src/ClientSession.luau` | Deadline-bound discovery, descriptor matching, module-slot ownership, dispatch, cancellation, transport loss, and cleanup. |

## Runtime invariants

## Supported schema authoring

`Relay.schema` is a frozen table of ordered field, primitive/composite shape and
directional event constructors. Use `schema.field(name, shape)` to bind a reusable
shape, then `schema.ordered(...)` for fields. `define` remains the authoritative
validator and copies reused shapes independently. Setup errors include bounded
field paths. The original ordered helper remains compatible.

`schema.compose(...)` merges 1..64 literal event maps, with at most 64 input
entries and deterministic key/ID collision rejection. The compiled definition
limits remain 16 endpoints and a 4096-byte descriptor. Keep singleton struct
names/enum values and parenthesize a final builder call in ordered packs.

## Audience sends

ServerToClient server handles expose `SendTo(players, ...)` and
`SendExcept(excludedPlayers, ...)`, returning success, error and successful
handoff count. Lists are plain dense arrays of at most 1024 actual Players.
Identity duplicates are removed and departed Players skipped. Validation and
encoding occur once, including empty audiences. A partial transport failure
stops handoffs and is never retried. Full `Broadcast` still uses FireAllClients.

## Diagnostics and request responses

`Relay.inspect(definition)` returns a frozen schema-budget report; native tuple
wire bytes remain unknown. `session:GetDiagnostics()` returns bounded saturating
totals and per-event counters without retaining attacker payloads or Players.
Receiving event handles support `Once`; a callback's yielding lease survives
listener replacement. Reliable transport can still encounter admission/busy drops.

Define `requests` using `schema.request(id, orderedArguments, responseShape)`.
Clients call `session.requests.Method:Request(timeoutSeconds, ...)` and await the
returned handle with `Await`; `Cancel` settles locally without undoing server
work. Server request handles use `Connect(function(player, ...) return response end)`.
Clients own at most eight pending requests and one per method, with deadlines
of at most 60 seconds. Nonreused u32 call IDs and session GUIDs reject stale
responses. Server replay records are bounded to 64 recent and eight active
identities per actual Player. Requests share ingress budgets and handler leases;
callbacks own application authorization. No automatic retries or durable
exactly-once promise apply. Departure/destroy releases pending work and timers.


- Definitions allow at most 16 total event/request endpoints and eight fields per event. Primitive kinds
  are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`,
  `Vector2F32`, `Vector3F32`, and `CFrame`. Composable shapes are bounded structs,
  dense arrays, enums, optionals, and primitive-key sets; arbitrary maps and
  recursive shapes are unsupported.
- Primitive-only definitions use `RR1` for reliable-only events and `RR2` when
  any event is unreliable. Definitions containing a composable shape use `RR3`.
  Startup requires an identical descriptor and matching transport topology.
  Primitive-only events use native tuples even within an RR3 definition;
  composite events encode their entire tuple into one buffer.
- Composite frames use format version 1 and a u16 endpoint matching the outer
  endpoint. Limits are 8192 raw bytes for Reliable, 900 for Unreliable, depth four,
  256 expanded nodes per event, and array/set capacities at most 64. Definition
  rejects schemas exceeding the worst-case bounds. Decoders check bounds before
  reads, allocation, and traversal, and reject the complete malformed frame
  before any handler call. Normalized/decoded tables belong to each invocation.
  Single- and two-field validation, encoding, and decoding keep values in locals
  instead of allocating temporary payload tuples.
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
  without allowing late callbacks to recreate state. Inbound drops retain no
  payload diagnostic, response, log, or queue. Client terminal cleanup and server
  listener cleanup release decoder references held by connection handles.
- Client discovery and activation share one startup deadline. Each pending child
  wait owns one listener and timeout, released on arrival, timeout, or Destroy.
  Destroy cancels startup with `Destroyed`; attempt identity prevents stale
  continuations from activating a destroyed or replacement session.
- Session option checks reject unknown keys and missing required values without
  temporary key tables. Protected connection cleanup reuses module-local helpers.
- Send success means local Roblox transport handoff. Game code owns authorization,
  semantic validation, readiness, sequencing, persistence, and handler work.
  Unreliable delivery may drop or reorder messages. Relay has no retry,
  automatic reconnect, batching, RPC, or middleware. Admission bounds Relay-owned
  work, not engine ingress allocation, network availability, or fairness.

Networking, decoder, serializer, transport, batching, RPC, and middleware changes
require a dedicated design and security review under [AGENTS.md](AGENTS.md).
Before extending unreliable delivery or composite shapes, that review must
specify version compatibility, maximum total encoded size, array length, nesting
depth, and admission charges. Keep the contract in README.md current and prove
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
| `benchmarks/host/` | Source/artifact verification, selected-only builds, authenticated bounded collection, confirmed Studio exit, and no-overwrite publication. |
| `benchmarks/reporting/` | Bounded reads, strict V1/V2 validation, compatible comparison groups, and separation of non-valid evidence. |
| `benchmarks/pilot/` | Opt-in QuickNet/Zap lifecycle checks outside measured Result evidence. |
| `benchmarks/quick/` | One-client Studio Play diagnostics, persistent adapter instances, bounded capture, Output summaries, and in-session reruns. |

The library lock is `benchmarks/libraries.lock.json`. Acquisition and deterministic
generation use `scripts/acquire-benchmark-libraries.luau` and
`scripts/generate-benchmark-adapters.luau`. Downloaded/generated code is not
edited or committed. Suphi-Packet has an author grant but remains timing-ineligible
because its sender-frame bound cannot be proven.

Canonical `PersistentBenchmark` uses Result V2's `event-session-v1` profile:
one fresh Studio session per adapter/case/topology, 30 logical windows, a passed
session proof, and confirmed process exit before publication. Physical receivers
observe across windows; late, stale, malformed, or between-window deliveries
latch failures. Setup, readiness, warmup, correctness, and quiet windows stay
outside timing. Result V1 is a separate lifecycle/profile and cannot be pooled
with V2. Readers recompute summaries and reject dirty provenance, duplicate run
IDs, and incompatible comparison groups. A warm process is not 30 independent
process samples; shared-clock durations are diagnostics, not ranking inputs.

The timing recorder retains completed private sample arrays and makes one final
defensive copy when producing deeply frozen evidence.

`MeasurementFingerprint.luau` covers measured runner/contract/fixture/correctness
inputs, composition and adapter contracts, canonical host dependencies, and the
library lock. Documentation/reporting edits do not change the fingerprint.
Changed measured inputs require a compatible new cohort.

[Quick benchmark guidance](benchmarks/quick/README.md) owns workload selection,
balanced adapter rotations, timing units, and receive profiling. Quick runs
accept dirty local source and do not emit Result V1/V2 or ranking evidence.
The Relay-only `schema-composite-c2s` diagnostic exercises RR3 with 16 bounded
records and independent nested fixture/capture copies; schema cases are unprofiled.
Each adapter initializes once per Play session; changing workload or source
requires Stop/Play. Observed terminal faults invalidate prior reruns, while
acknowledged normal closure tears down adapters and preserves completed results.
Receive profiles use isolated source snapshots and include capture/instrumentation
overhead; they are callback elapsed diagnostics, not isolated CPU time or
end-to-end latency.

`BroadcastStudy.luau` and `run-broadcast-study.luau` schedule forward/reverse
canonical State-broadcast sessions with pinned source and Studio identities.
Verified result bytes, logs, hashes, and failed attempts stay in ignored local
ledgers.
[The serializer gate](benchmarks/serializer-gate.md) owns predeclared
units, attribution limits, and evidence collection. `SerializerGate.luau`,
`SerializerEvidence.luau`, and `run-serializer-gate.luau` evaluate pinned source,
exact planned base-place identities, Result V2, profiler, and packet-capture
artifacts. They do not collect those traces or certify human reviews; missing
evidence is inconclusive, and passing evidence is eligible for design/security
review.

The local OS account and selected Studio executable are trusted. Harness
framing, source checks, and correctness qualification do not certify third-party
decoders against malicious bytes or establish production security.

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

| Check | Coverage |
| --- | --- |
| `tests/runner.luau` | Frozen public module contract and consumer-owned ordered helper. |
| `tests/public-types.luau` | Actual API and mapped example consumers under the new solver, including invalid schemas, payloads, options, depth, and recursive types. Uses hash-verified Roblox definitions in ignored `.tmp/`. |
| `tests/definition.luau`, `tests/frame.luau`, `tests/composable-codec.luau` | Schema/descriptor rejection, primitive normalization, bounded encoding/decoding, malformed buffers, exact tuples, per-invocation ownership, single-/two-field tuple-allocation checks, canonical vector reuse, all six composite integer widths, decoder/input-validation separation, and guarded composite table iteration. |
| `tests/token-bucket.luau`, `tests/server-session.luau`, `tests/client-session.luau` | Refill/clocks, admission charging, handler leases, routing, discovery cancellation, transport integrity, and cleanup. |
| `benchmarks/tests/` | Contract rejection, adapters, timing/lifecycle boundaries, stale probe rejection, host provenance/framing/cleanup, reporter compatibility, quick diagnostics, and study/gate orchestration with exact place pins. Synthetic/build checks are not native timing evidence. |

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
pushes to `main` and all pull requests. Keep changes surgical and update this map
when purpose, ownership, API, modules, tests, or guardrails change.
