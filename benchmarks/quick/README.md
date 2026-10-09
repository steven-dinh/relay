# Quick Studio benchmark

Run every selected adapter sequentially in one Studio Play session. This is a
short diagnostic for local iteration; use the [canonical benchmark](../README.md#run-the-current-benchmarks)
for repeatable comparisons. Quick runs do not produce Result V1/V2 artifacts or
pooled rankings.

From the repository root, using the tools pinned in `rokit.toml`:

```powershell
lune run benchmarks/quick/build.luau
```

Open `.tmp/relay-quick.rbxlx` in Studio and press **F5 / Play**. Use one client.
The benchmark starts automatically and prints results to the client Output.
The default compares Native RemoteEvent and the current local Relay source,
including uncommitted changes. No external library installation is needed.

To repeat the same workload without restarting Play, run this in Studio's
**client** Command Bar after the previous run finishes:

```luau
require(game.ReplicatedStorage.RelayBenchmark.Quick.Session).run()
```

## Iterate

Edit [Config.luau](Config.luau) to choose the workload and duration. Defaults are
`state-burst-c2s`, 30 warmup frames, 120 measured frames, 0.25 seconds of quiet,
a 15-second timeout, and `autoRun = true`. Set `autoRun = false` for manual runs.
Round-trip requests share one `timeoutSeconds` budget per warmup or measured
phase, including echo waits.
Each `.run()` performs complete rotations with at least three rounds, using those
frame counts per round and warmup before each adapter's measurement. The default
two-adapter selection runs four rounds; all nine adapters run nine rounds. Every
adapter occupies each position equally often within a run. The first adapter
rotates one position each round and one position across reruns; results print
only after every round passes. The same Play session and initialized libraries
are reused, so balanced positions do not remove shared-session or time-varying
load effects.

| `caseId` | Work per frame |
| --- | --- |
| `tiny-steady-c2s` | 1 Tiny message |
| `state-steady-c2s` | 1 State message |
| `state-burst-c2s` | 4 State messages |
| `state-broadcast-s2c` | 1 State broadcast to the single client |
| `state-broadcast-burst-s2c` | 4 State broadcasts to the single client; quick diagnostic only |
| `tiny-round-trip` | Sequential Tiny request/echo; frame settings become request counts |
| `schema-signed-c2s` | 1 sequence + i8/i16/i32 tuple; Relay only |
| `schema-vector2-c2s` | 1 sequence + native Vector2 tuple; Relay only |
| `schema-string-c2s` | 1 sequence + varied 64-byte string tuple; Relay only |
| `schema-cframe-c2s` | 1 sequence + native CFrame tuple; Relay only |
| `schema-composite-c2s` | 1 sequence + 16 `{entityId:u16, score:i32, enabled:boolean}` records; Relay only (121-byte frame) |

The five `schema-*` cases are Relay-only diagnostics for its added scalar and
composite field types. The composite case sends a fixed 16-record array for a
121-byte reliable frame. Select one in Config, then build with
`--adapters relay-reliable`. Other adapters are rejected for these cases before
transport setup. Only `schema-composite-c2s` supports receive profiling; the other
four schema cases reject it. They do not extend Event V1 or imply
equivalent representations in other libraries. Fixture construction stays
outside timing. CFrame input preservation checks all local components and zero
signs exactly; delivery comparison requires exact fixture translation and finite
rotation-component differences at most 0.0001.

To sync edits into the open place with the Rojo Studio plugin:

```powershell
rojo serve .tmp/relay-quick.project.json
```

Stop Play, sync changes, and press F5 again after editing source or Config;
already-required modules retain their cached values during a running session.
Rerunning `.run()` is for additional measurements of the loaded code. The
generated project references source files directly, so rebuilding or syncing
uses your latest edits. Rebuild and reopen the place when changing adapter
selection. The default project can also be built directly:

```powershell
rojo build benchmarks/quick/quick.project.json --output .tmp/relay-quick.rbxlx
```

## Include installed external libraries

Use the existing pinned dependencies and generated adapters:

```powershell
lune run benchmarks/quick/build.luau --all
lune run benchmarks/quick/build.luau --adapters native-reliable,relay-reliable,quicknet,zap
```

Available external IDs are `quicknet`, `bytenet`, `satset`, `warp`, `blink`,
`zap`, and `netray-compile`. Suphi-Packet remains excluded. Missing or changed
pinned artifacts fail the build; the quick builder does not download or regenerate
anything. For first-time preparation,
follow the [adapter guide](../adapters/README.md). Generated-adapter verification
also checks the complete installed dependency set through the existing verifier.

## Profile receive callbacks

The default `state-burst-c2s` case supports profiling. You can also select
`tiny-steady-c2s`, `state-steady-c2s`, `state-broadcast-s2c`, or
`state-broadcast-burst-s2c`, then build the native/Relay profile:

```powershell
lune run benchmarks/quick/build.luau --profile-receive
```

For the existing RR3 composite fixture, select `schema-composite-c2s` in Config
and build its Relay-only profile:

```powershell
lune run benchmarks/quick/build.luau --profile-receive --adapters relay-reliable
```

This profile retains the same fixed 16 records and 121-byte reliable frame;
it adds no new schema or workload. Other adapter selections reject before the
profile snapshot is created.

The builder prints a unique place and project under
`.tmp/relay-quick-profile-<token>/`. Open that place and press Play. It contains
isolated copies of every project input, including fixtures, contracts and shared
support code. Its manifest records the source and snapshot hashes plus the
finished project and place hashes. Rebuild to capture later edits; the ordinary
quick project continues to use live source. Profiling accepts only
`native-reliable` and `relay-reliable` and never changes production source files.

Rows labeled `profile=receive-callback` include callback elapsed mean, median and
p95 alongside the existing sender public-call timings. The timer wraps the actual
server callback for C2S or client callback for S2C, including Relay's validation,
admission on the server, RR3 buffer decoding for the composite fixture, and
dispatch plus the shared capture sink. It excludes
network transit, engine decoding and scheduling before callback entry. Elapsed time can include
callback yields and adds instrumentation overhead; these rows must remain
separate from `profile=unprofiled` diagnostics. Neither elapsed metric is isolated
CPU time, and sender and receiver samples must not be added into a latency figure.
Composite samples include the bounded nested capture copy and do not isolate
codec cost.
Round-trip and the other four `schema-*` cases remain unsupported by this profile.
Changed source or fixture hashes require a separate diagnostic cohort; never
relabel an earlier snapshot as measuring the new inputs.

Each round retains `receiveCallbackSamples` and its `receiveCallbacks` summary.
Recording is bounded to 2,400 callbacks per warmup or measured phase; incorrect
counts, incomplete callbacks or deliveries outside their phase invalidate the
profile. Round summaries remain separate rather than pooling their samples.
For C2S, server samples are returned only after delivery/input verification and
the quiet interval, outside sender timing. Late profile faults still invalidate
earlier rows from the same Play session.

## Read the output

Every metric prints the median and `[min..max]` of the round values. For
example, `frame p95` is the median of the per-round p95s, not a pooled p95.
The range describes observed spread; it is not a confidence interval. Returned
rows retain each round in `row.rounds` and the aggregate statistics in
`row.summary`. Verified counts total the measured deliveries across all rounds.
Each round also retains `callSamples`, `frameSamples`, and `floorSamples` in
seconds, using the bounded arrays collected by the existing timing loop. Frame
samples are empty for the sequential round-trip probe. Summaries are computed
after timing, and rounds and reruns remain separate observations.

`offered msg/s` uses the paced sender interval, so it describes the offered load,
not the adapter's maximum throughput. `delivery confirmation` measures from the
start of the measured send window until delivery is acknowledged, using only
the sender's local clock. C2S ends when the receiver's acknowledgement returns;
S2C ends when the receiver's acknowledgement reaches the sender. This includes
the paced window and control-message/scheduling overhead, but excludes deliberate
quiet waits and full payload verification. It is not pure network latency or
an exact last-delivery timestamp. The round-trip case reports request/echo RTT
instead of this extra confirmation metric.

Public-call average, median and p95 measure raw microseconds per message,
including loop overhead and explicit flushes before return; deferred transport
and receive work are outside those metrics. For burst cases, each sample is the
four-call frame duration divided by four, so its p95 is a p95 of frame-batch means,
not a distribution of individually timed messages. `no-op floor avg` runs the identical timed loop with an
empty operation before each paced phase. It makes the harness timing floor
visible without subtracting it or changing the real measurements. Differences
near that floor need more evidence before attributing them to a library.

The acknowledgement tail measures from final submission return until the same
delivery acknowledgement, using the sender's local clock. It excludes the paced
send window but includes acknowledgement/control/scheduling overhead. It is not
the canonical shared-clock drain or an exact last-receipt timestamp. Both timing
definitions stay separate, and RTT remains the request/echo metric.

The burst broadcast workload reuses the State payload and existing flush boundary
without changing the canonical Event V1 workload. Its results cannot be compared
as if they were canonical `state-broadcast-s2c` results.

Frame average/p95 and sender FPS measure sender frame intervals. Raw engine send
KB/s (kilobytes per second) is an engine-wide diagnostic, not per-library wire size.

Deterministic payloads and exact delivery are checked outside timing; failures
invalidate the session's results. Setup, warmup, and quiet intervals are outside
measurement. All adapters share one local Studio session, so order, frame caps,
background load, and retained library state can affect these short samples.
Do not mix them with the canonical benchmark results.
For fresh-session baseline/identical-control comparisons, use the existing
[paired broadcast study](../README.md#collect-a-paired-broadcast-study).
Repeating `.run()` retains the same loaded source; it does not create an
independent process sample or reload an edited candidate.

Receivers keep observing between runs. A late delivery failure sets `QuickStatus`
to `Failed` and prints an invalidation warning, including while the client is
idle. All rows returned by `.run()` share `row.validity`; a terminal failure sets
`row.validity.valid` to `false` and records `row.validity.failure`, invalidating
earlier runs from the same Play session too. Stop/Play after a failure.

After both sides finish validation, stopping Play closes the session without
invalidating successful results or printing a failure warning. Departure during
an unfinished run remains a failure. A closed session requires a new Play session;
normal closure tears down adapters, so deliveries suppressed by teardown are no
longer checked.
