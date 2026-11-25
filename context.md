# Relay Context

Relay is a standalone Roblox networking library. Games define typed events and requests, then create a client or server session. The package defaults to reliable delivery. Queues, latest-state updates and ordered unreliable streams have distinct delivery contracts.

## Runtime ownership

Start with the public operation. The session owns admission, handoff and cleanup even when a helper owns the encoding or queue.

| If you are changing… | Start here | First check |
| --- | --- | --- |
| Server sends and transport integrity | [ServerSession](src/ServerSession.luau). For `Send` or `Broadcast`, follow `send` to `sendValidated`. For `SendTo` or `SendExcept`, follow `sendAudience` to `sendAudienceValidated`. Both paths call `checkIntegrity`. On reliable-only servers, the child list must contain exactly the owned Definition and Reliable instances. | [Server session](tests/server-session.luau) |
| Client startup, discovery, send or transport loss | [ClientSession](src/ClientSession.luau). Check descriptor matching, deadlines and namespace ownership. | [Client session](tests/client-session.luau), [namespace isolation](tests/transport-namespaces.luau) |
| Root exports and inferred event, request or session types | [Public module](src/init.luau), [schema helpers](src/Schema.luau), [definition compiler](src/Definition.luau) | [Public type consumers](tests/public-types.luau) |
| Tuple validation, composite encoding or native Roblox values | [Frame](src/internal/Frame.luau), [CompositeCodec](src/internal/CompositeCodec.luau), [NativeSchema](src/internal/NativeSchema.luau), [NativeCodec](src/internal/NativeCodec.luau) | [Event frames](tests/frame.luau), [composites, fixed-width record parity and charged rejection](tests/composable-codec.luau), [native codec](tests/native-codec.luau) |
| Numeric formats, count widths, quantization or packed fields | [NumericFormats](src/internal/NumericFormats.luau), [LengthBounds](src/internal/LengthBounds.luau), [Quantized](src/internal/Quantized.luau), [CompactValues](src/internal/CompactValues.luau), [BitPacking](src/internal/BitPacking.luau) | [Bounded formats](tests/bounded-formats.luau), [compact values and single-preparation CFrame encoding](tests/compact-values.luau), [bit packing](tests/bit-packing.luau) |
| Instance reference classes, ancestry or sidecars | [InstanceRefs](src/internal/InstanceRefs.luau) and the receiving session | [Instance routes](tests/instance-routes.luau) |
| Per-player admission, byte budgets or diagnostics | [TokenBucket](src/internal/TokenBucket.luau), [ByteUnits](src/internal/ByteUnits.luau), [Diagnostics](src/internal/Diagnostics.luau). Client traffic diagnostics cache the byte cost of fixed-size native tuples. | [Admission fairness](tests/admission-fairness.luau), [outbound bytes](tests/outbound-bytes.luau), [traffic diagnostics](tests/traffic-diagnostics.luau) |
| FIFO submission, splitting or flush | [Batch](src/internal/Batch.luau), [BatchFrame](src/internal/BatchFrame.luau) and [PacedBatcher](src/internal/PacedBatcher.luau). BatchFrame writes full plain reliable FIFO sends to fixed server recipients in a single pass. | [Batch sessions](tests/batch-session.luau), [batch frames](tests/batch-frame.luau) and [paced batching](tests/paced-batcher.luau) |
| Replacing unsent state, expiry or budget-aware service | [StateQueue](src/internal/StateQueue.luau) and the session that owns the lane | [State queue](tests/state-queue.luau), [state sessions](tests/state-session.luau), [deferred service and per-recipient status after departure](tests/state-deferral.luau) |
| Ordered delivery, stream scheduling or timestamps | [OrderedFrame](src/internal/OrderedFrame.luau), [Streams](src/internal/Streams.luau), [Timestamps](src/internal/Timestamps.luau) | [Ordered unreliable](tests/ordered-unreliable.luau), [streams](tests/streams.luau), [timestamps](tests/timestamps.luau) |
| RPC correlation, cancellation, timeouts or listener readiness | [PendingRequests](src/internal/PendingRequests.luau), [RpcFrame](src/internal/RpcFrame.luau), [ReadinessFrame](src/internal/ReadinessFrame.luau) and the session | [RPC sessions](tests/rpc-session.luau), [readiness sessions](tests/readiness-session.luau) |

## Runtime invariants

- A valid send checks the live transport before handoff. If an owned networking object is still renamed, moved or replaced, the next send must detect it even while Roblox change notifications are deferred. A replacement can have the same class and name, and leave the root with the same child count. [Session lifecycle](docs/reference.md#lifecycle-and-admission)
- Client validation matches the cached root and marker by direct-child lookup, with live name and parent checks when the lookup misses the cached Instance. The root child list proves exact leaf membership. [Client session regression](tests/client-session.luau)
- Client input is untrusted. Preserve the order of admission, validation and dispatch, including charges on rejected inputs. Validate bounds before traversal or allocation. Where a frame is atomic, a bad later row must prevent earlier callbacks. [Protocol and abuse limits](docs/reference.md#protocol-and-abuse-limits)
- A FIFO preserves submitted records. A State lane replaces the latest **unsent** value for a key. The game owns authoritative state, recipient authorization and late-join recovery. A successful handoff does not confirm receipt. [FIFO batches](docs/reference.md#explicit-fifo-batches) · [Latest unsent state](docs/reference.md#latest-unsent-state)
- Session teardown releases owned connections, timers and pending work. Keep callbacks and retries from reviving a destroyed session or replaying a handoff whose outcome is unknown. [Requests](docs/reference.md#requests) · [Lifecycle and admission](docs/reference.md#lifecycle-and-admission)
- The public exports and types live in [src/init.luau](src/init.luau). Consult the [API reference](docs/reference.md) for signatures, descriptor compatibility, limits and recovery semantics. [AGENTS.md](AGENTS.md) owns the review and package rules.

## Examples and contributor tools

| Task | Owner and verification |
| --- | --- |
| Start a game or choose an example | [Example index](examples/README.md) and [quickstart scripts](examples/quickstart/). The [release guide](docs/guide.html) describes installation and cleanup. |
| Send private group notices or public scores | [Interest management](examples/interest-management/README.md) uses server-owned membership. On its one-second step the example seeds ready active viewers and sends again when their server-assigned role or the score changes. Membership changes rebuild and seed the spectator State lane. [Companion test](tests/interest-management.luau) |
| Retry RPC operations, pace State, or drain a session | [Operation-ID RPC](examples/operation-id-rpc/README.md), [paced State](examples/paced-state/) and [session drain](examples/session-drain/README.md). These are application patterns built on public Relay APIs. |
| Check a game schema or generate declarations | [Relay Tools CLI](scripts/tooling/README.md), [schema check](scripts/check-schema.md), [compatibility](scripts/schema-compatibility.md), [budget analysis](scripts/analyze-schema-budget.md) and [optional roblox-ts integration](scripts/roblox-ts/README.md). [CLI tests](tests/tooling-cli.luau) |
| Exercise a consumer integration or inspect a running session | [Consumer testing kit](scripts/consumer-testing/README.md) provides controlled delivery and fault injection. The [Studio inspector](scripts/studio-inspector/README.md) observes registered sessions. Both live outside the runtime package. |

### Entity state companion

The [entity-state example](examples/entity-state/README.md) combines a server-authorized snapshot with reliable absolute updates and deletion. Revisions and membership epochs protect recovery from stale responses. The [portable tests](tests/entity-state.luau) cover authorization and races. The [two-client Studio fixture](tests/studio/entity-state/) covers baseline/update ordering, denial, revocation, re-entry and cleanup.

The native fixture passed on source `f22bb2fd14d7170e74c0eb79ca5db863c76a851e`, Studio `0.744.0.7441077`. Local receipts are under `.tmp/entity-state-native/b4bad193359f2cc55aa13d1706aaf31f/`. The earlier pre-fix launch `07af138cd20b3c05ace16b7e64312803` failed. Separately, foundation on frozen base `7c569f6` passed 96 stages before the quick receive instrumenter failed to match the changed dispatch call. The remaining 20 stages passed in a partial run. Only the native companion correctness result is qualified by that Studio launch.

## Benchmark ownership

| Question | Owner |
| --- | --- |
| What does this workload measure? | [Benchmarks and measurement rules](benchmarks/README.md), [adapter contracts](benchmarks/contracts/), [implementations](benchmarks/adapters/), [libraries and pins](benchmarks/libraries.lock.json) |
| Where do timing, execution and publication happen? | [Runner](benchmarks/runner/) owns phases and measured windows. [Host](benchmarks/host/) owns verified inputs, the Studio lease, teardown and publication of evidence. [Broadcast study workflow](benchmarks/README.md#collect-a-paired-broadcast-study) |
| How are comparisons interpreted? | [Reporting](benchmarks/reporting/) validates V1/V2 results and compatible groups, reports observed median order and burst frame call totals, and separates non-valid evidence. C2S groups ignore broadcast mode. [Measurement rules](benchmarks/README.md#measurement-rules) |
| Where do I run a local diagnostic? | [Quick Studio runner](benchmarks/quick/README.md) supports persistent adapters, FPS-sorted Output tables and in-session reruns. [Saved profiler captures](benchmarks/profiling/html/README.md) and the [serializer gate](benchmarks/serializer-gate.md) have separate evidence requirements. |

**Qualification.** A State-burst client-to-server smoke on Studio `0.742.0.7421053` verified 1,440 deliveries and six sender/receiver captures. The profiler scan was partial. That run validates collection only. Canonical timing and rankings require matched workloads, raw samples, pinned source/builds and comparable controls. Host turnaround, sender elapsed time, frame rate, engine-wide bandwidth and Relay-modeled bytes measure different things.

Ledger updates use a flushed, byte-count-checked sibling file and a same-volume rename. A failed write leaves the last published checkpoint readable. Paired timing preflight requires the verified-copy baseline host and matching tool pins. It builds both verified copies and compares the canonical measurement fingerprints before any Studio attempt. The [broadcast study test](benchmarks/tests/broadcast-study.luau) covers early rejection and checkpoint preservation. The [quick builder test](benchmarks/tests/quick-benchmark.luau) checks that `--all` forwards a copyable Rojo command.

## Competitive roadmap

The local queue at `.tmp/roadmap-20261011/ROADMAP.md` and its `BLINKBLOX.md` acceptance criteria own sequencing. Its receipts qualify only their captured source, Studio build and workload.

- **C00, measurement.** The one-recipient State broadcast at `7a59b80` passed all six verified-copy runs, with 21,600 correct deliveries across 180 windows. The local ledger is `.tmp/broadcast-study-7720babea0405e64/ledger.json`. Matched performance comparison remains open.
- **C01–C06, runtime.** Shared broadcast State and scheduled streams are implemented. Pacing, outbound deferral, client timestamps and traffic reports have source-specific proof. Consult the queue before applying an older result to a combined checkout.
- **C07, release.** Relay v0.3.0 was published at `7a59b80`. The release passed foundation, packaged migration and paced-State checks, and the full and focused Studio runs. The separate Studio tooling heap measurement remains inconclusive. Local evidence is in `.tmp/release-v0.3.0-20261123-final/release-proof.json`.
- **C08–C10, formats and tooling.** Further packing and RPC convenience work depend on a concrete use case. C10 tooling includes offline schema checks, the Studio inspector, the consumer kit and schema-derived roblox-ts declarations.

## Verification and repository hygiene

Start with the focused check in the ownership map. For foundation changes, run the full [foundation verifier](scripts/verify-foundation.luau). On a clean checkout, the [CI workflow](.github/workflows/ci.yml) gives the pinned setup and generation steps. Use [native Studio fixtures](tests/studio/) to verify behavior that depends on Roblox scheduling or transport. Record the source, build, workload and observed result when citing a native run.

[Wally configuration](wally.toml) owns the package manifest. The package is private and its runtime lives in [src/](src/). [SECURITY.md](SECURITY.md) owns disclosure and support policy. For an older qualification, the [previous contributor record](https://github.com/steven-dinh/relay/blob/1f4c90e31408f7df7b1da817d43111fc60a9b1b7/context.md#verification-and-repository-hygiene) indexes the source-specific receipts, failed attempts and scope limits. The same record is available offline with `git show 1f4c90e:context.md`.
