# Relay Benchmarks

This directory contains the deterministic Event V1 contracts, fixtures,
correctness tooling, pure R1 runner, pure R2 control validator, Studio
composition, native Roblox `RemoteEvent` adapter, and authenticated loopback
collector used for neutral networking-library comparisons. The focused pure,
static Studio, and host proofs pass, and the live 1/4/8-client ControlProof
matrix passed on 2026-08-30 UTC. A live Benchmark matrix has not yet been
completed or published. No competitor integration or benchmark result is
included.

Benchmark implementations and executions must follow these rules:

- prove correctness before ranking performance;
- use deterministic fixtures and give every adapter a fresh input value;
- treat any adapter mutation of its input as an invalid result;
- keep setup, dependency loading, and readiness checks outside timed regions;
- provide equivalent-semantics and native-best lanes when features differ;
- measure real wall time and preserve the contract's timing boundaries;
- pin every compared dependency to an exact revision;
- report only comparable strata, never an overall library winner;
- keep downloaded source, generated code, and local results untracked.

Correctness tests remain separate from timing and never fail because of timing
variance. A run with missing, duplicate, stale, misordered, corrupted, or
input-mutating behavior is invalid and must not enter a performance ranking.

## Native path and selection matrix

The first executable binding is
`benchmarks/adapters/native-reliable/init.luau`, a benchmark-only adapter over
Roblox `RemoteEvent`. The server-only allowlist accepts only the exact full
native identity for the running Studio version. Native readiness caches its
remote and validates the exact participant roster before measured submission or
broadcast; those checks are not charged to an adapter operation.

The host accepts exactly seven manifest-derived Event V1 selections:

- `tiny-steady-c2s` with one client;
- `state-steady-c2s` with one client;
- `state-burst-c2s` with one client;
- `state-broadcast-s2c` with one recipient;
- `state-broadcast-s2c` with four recipients;
- `state-broadcast-s2c` with eight recipients;
- `tiny-round-trip` with one client.

The native binding is only a baseline path. It is not evidence that another
library is faster or slower, and its presence does not create a published
result.

## Event V1 execution contract

Each workload names its audience directly. Client-to-server submissions target
`Server`; the server-to-client workload targets `Broadcast`. Targeted
server-to-client delivery is not part of Event V1.

The reproducible Event V1 execution profile requires Studio multiplayer through
`StudioTestService:ExecuteMultiplayerTestAsync`. Roblox supports at most eight
clients through that API, so the broadcast variants are 1, 4, and 8 clients. A
20-client result must not be presented as Event V1 unless a separate,
reproducible execution profile is specified later.

The contract's `targetFrameRate = 60` is a target, not a fixed throughput
assumption. Workloads submit their declared `messagesPerFrame` once per
`PostSimulation` frame. They do not promise a fixed messages-per-second rate:
when Studio runs below 60 FPS, the offered real-time message rate falls with it.
Frame-time samples preserve that behavior instead of normalizing it away.
The burst workload sends four messages per frame (240 per second at the target)
so the native `RemoteEvent` baseline retains headroom below
[Roblox's documented approximate client-to-server request limit](https://create.roblox.com/docs/reference/engine/classes/RemoteEvent/OnServerEvent)
instead of measuring transport throttling as library performance.

The server passes one completed serializable Result V1 or bounded termination to
`StudioTestService:EndTest`. The secret-free RunScript bootstrap accepts the
resulting Benchmark JSON, or encodes its own bounded fallback termination, and
makes exactly one authenticated terminal POST to the IPv4-loopback collector.
Result extraction happens after all timed work. ControlProof validates the same
fixed wrapper and writes no benchmark result.

Every launch uses a unique ignored Rojo build. The place fingerprint is the
SHA-256 of the exact Rojo-produced place bytes before `LaunchCarrier` insertion.
The collector uses independent Studio-version attestation from the bootstrap,
rather than trusting a version reported inside Result V1, and publishes only a
fully validated terminal Result.

Quiescence means 60 consecutive `PostSimulation` frames with no workload
delivery. Any relevant delivery restarts the count. This untimed window runs
after warmup has drained and again after measured deliveries have been verified;
the second window catches late, duplicate, stale, or unexpected callbacks.

`maximumAddedDeliveryFrames = 1` limits only intentional sender-side buffering
or flush scheduling before the library hands work to Roblox transport. It does
not limit Roblox transport latency, internet latency, or receiver scheduling. An
implementation that intentionally buffers for more than one frame cannot claim
the equivalent-semantics lane.

Frames are counted by sender `PostSimulation` boundaries crossed between the
runner invoking a logical submit and the library invoking its transport send.
Zero means transport send occurs in that same `PostSimulation` callback; one
means it occurs no later than the next `PostSimulation` callback. The submission
callback itself is not counted as an added frame.

## Clocks and measurements

Local durations use `os.clock()` and never subtract timestamps recorded by
different Roblox participants. Cross-server/client boundaries use
`Workspace:GetServerTimeNow()`. That clock is engine-synchronized but
approximate, so `completionDuration`, `drainDuration`, and `wallDuration` are
diagnostic and cannot affect rankings.

Both clocks return seconds. Runners subtract timestamps first, then multiply the
delta by 1,000 for milliseconds or 1,000,000 for microseconds.

Runners record these timing windows:

- `frameTime`: sender-local `os.clock()` from the start of each measured
  `PostSimulation` frame to the following frame, one sample per measured frame;
  this is the sole ranking-eligible workload metric;
- `submissionDuration`: sender-local `os.clock()` from immediately before the
  first measured adapter operation until immediately after the final measured
  adapter operation returns; it includes the scheduled inter-frame time between
  operations and is `DiagnosticOnly`;
- `completionDuration`: shared-clock time from the first measured submission
  start until the final expected delivery is received, `DiagnosticOnly`;
- `drainDuration`: shared-clock time from the final measured submission return
  until the final expected delivery is received, `DiagnosticOnly`;
- `wallDuration`: shared-clock time from the first measured submission start
  until the final expected delivery passes payload, order, and count checks,
  `DiagnosticOnly`;
- `submitCallDuration`: sender-local `os.clock()` immediately around each
  `AdapterContract` submit or broadcast operation, reported in microseconds per
  event. It captures caller-blocking work such as enqueueing and any
  final-before-return flush, but excludes deferred transport and receiver work;
  it is `DiagnosticOnly` and is not CPU utilization;
- `roundTripLatency`: client-local `os.clock()` around one non-pipelined tiny
  client-to-server submission and its matching one-client broadcast echo. It is
  eligible only within the separate round-trip probe, not as a workload metric.

Cross-participant completion and drain diagnostics floor at zero when the
receiver has already observed the final delivery before the sender operation
returns, or when the approximate shared clock reports that ordering. This does
not affect ranking eligibility.

Receipt timestamps are captured before correctness verification. Verification
work is included only in `wallDuration`; setup, warmup, readiness, quiescence,
and result extraction stay outside every timing window.

The measured submit and round-trip marks sit at the adapter-operation boundary.
Selected-field extraction, the adapter/library operation, and any
final-in-frame `FlushBeforeReturn` work remain inside the call window. Each
sample also necessarily includes the fixed surrounding clock calls and wrapper
edge shared by every adapter; that overhead is controlled and common, not
absent. The first submission endpoint is attempt-owned: merely arming measured
work records no endpoint, the first attempted operation records it even if the
operation fails, and the final endpoint exists only after the final planned
operation returns.

`engineDataSendRate` samples sender-side `Stats.DataSendKbps` once per measured
frame. Despite the property name, Roblox documents its value as approximate
kilobytes per second for all data sent by the current instance. It is therefore
an optional diagnostic, not remote-only wire bytes, and no background-rate
subtraction is allowed. Runner control traffic is forbidden during measured
frames.

## Fair reporting

Rankings may include only correctness-valid results. Every comparison must be
stratified by the exact case and topology, adapter lane, and `broadcastMode`.
Equivalent-semantics and native-best lanes remain separate; broadcast modes are
not silently pooled. Workloads may rank only by `frameTime`, while the separate
probe may rank its own `roundTripLatency`. Diagnostic measurements can explain a
result but cannot decide one. There is no valid aggregate score or overall
winner across different workloads, topologies, lanes, or broadcast modes.
