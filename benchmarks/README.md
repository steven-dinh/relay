# Relay benchmarks

## Measured library results

The latest library comparison was collected on **September 11, 2026**, using
Relay revision `3030944`. It covers four selections, with eight fresh Relay and
native sessions plus earlier peer results. These tables predate the cleanup
patch `3c450db`; its separate diagnostic is below.

Every cell is **median / p95 in milliseconds**, from one valid session with
30 persistent windows. The first three columns measure sender frame intervals;
the last measures request/echo round-trip latency. Tiny C2S and round trips use
one client; State burst sends four messages per frame; broadcast uses eight
recipients. Burst cells contain 300 measured frames, other cells 3,600 samples.

Compare within the same column and Studio/broadcast group. Windows within one
session are correlated; these local observations do not establish a repeatable
overall winner or production internet performance. A dash means this comparison
has no matching measurement in that group.

Relay and native rows below were collected September 11. ByteNet and Satset
rows in the same Studio group were collected September 10, at benchmark revision
`89b4d2f`; matching metadata does not prove matching machine load.

### Studio 0.738.0.7381393 / NativeBroadcast

| Library | Tiny C2S frame | Burst C2S frame | Broadcast / 8 frame | Tiny round trip |
| --- | ---: | ---: | ---: | ---: |
| Roblox RemoteEvent | 4.543 / 7.690 | 4.554 / 7.626 | 4.639 / 10.266 | 7.935 / 11.095 |
| Relay `3030944` | 4.534 / 7.765 | 4.542 / 7.892 | 5.092 / 16.380 | 7.976 / 9.174 |
| ByteNet v0.4.3 | — | — | 4.750 / 11.249 | 11.079 / 12.697 |
| Satset v0.4.2 | — | — | 4.986 / 13.356 | 10.973 / 15.925 |

### Studio 0.737.0.7371584 / NativeBroadcast

| Library | Tiny C2S frame | Burst C2S frame | Broadcast / 8 frame | Tiny round trip |
| --- | ---: | ---: | ---: | ---: |
| ByteNet v0.4.3 | 4.581 / 9.934 | 4.459 / 7.617 | — | — |
| Satset v0.4.2 | 4.577 / 10.038 | 4.543 / 8.072 | — | — |
| NetRay-Compile v0.1.1-cli.1 | 4.527 / 7.900 | 4.478 / 7.239 | 4.475 / 9.352 | 11.562 / 13.255 |

### Studio 0.737.0.7371584 / AdapterFanOut

| Library | Tiny C2S frame | Burst C2S frame | Broadcast / 8 frame | Tiny round trip |
| --- | ---: | ---: | ---: | ---: |
| Blink v0.18.8 | 4.530 / 7.860 | 4.556 / 8.242 | 4.687 / 9.848 | 11.491 / 12.925 |
| QuickNet v0.3.4-beta | 4.564 / 9.498 | 4.495 / 5.283 | 4.737 / 12.457 | 11.302 / 12.926 |
| Warp 1.0.14 | 4.497 / 7.884 | 4.608 / 8.286 | 4.646 / 10.004 | 7.955 / 12.344 |
| Zap v0.6.29 | 4.468 / 7.761 | 4.420 / 7.757 | 4.877 / 14.211 | 11.849 / 12.876 |

The older Studio groups retain earlier peer measurements from benchmark revision
`4ce556e`, except NetRay-Compile's eight-recipient broadcast at `96e8156`.
They are separate reference results. `NativeBroadcast` and `AdapterFanOut`
describe different broadcast implementations and stay separate even for C2S
and round-trip comparisons.

All displayed results passed correctness, clock admission, final session cleanup,
and result validation. Tables show the latest per-library/selection rows in the
September 11 comparison; older duplicate Relay/native baselines are not pooled
into them. The fresh collection's initial dirty-checkout attempt was rejected
before measurement, then restarted in a clean checkout. There were no
timing-based retries. Raw artifacts remain private and ignored; local provenance
is indexed by
`benchmarks/results/local/relay-3030944-vs-libraries-2026-09-11.audit.json`.
The reporter revalidates those artifacts and recomputes their summaries.

## Cleanup patch diagnostic — September 16

Before `56be92a` versus after `3c450db`, in three completed one-client Studio
sessions. Values below are ranges of session medians.

| Check | Before | After |
| --- | ---: | ---: |
| Cancellation response | 452.86–454.25 ms | 0.17–0.22 ms |
| Exact-zero Float32 validation | 0.132–0.166 µs/call | 0.105–0.113 µs/call |

Cancellation used a **500 ms startup timeout**, with `Destroy()` called after
about 50 ms. The old implementation waited out the remaining timeout; the new
one resumed promptly. Float32 values include common batch-loop overhead.
Receive-time reductions ranged from 0–14%, while controls varied; nonzero
Float32 validation ranged from 2.5% quicker to 18.1% slower. These diagnostics
do not establish general packet speed, CPU, or memory savings. One premeasurement
readiness failure was retained and retried with the unchanged harness.
One included session lacks its final host audit because the following readiness
attempt failed; its recorded input hashes matched the successful recovery run.
Evidence stays under `.tmp/optimization-speed-3c450db-20260916/`.

## Run the current benchmarks

Use `PersistentBenchmark`: one fresh Studio multiplayer session per
adapter/case/topology, with 30 windows and Result V2 (`event-session-v1`).
Run from the repository root on Windows with the tools in
[`rokit.toml`](../rokit.toml), a clean Git checkout, and no existing Studio
processes. Keep the argument order shown and run selections serially.

```powershell
$studio = 'C:/path/to/RobloxStudioBeta.exe'
lune run benchmarks/host/run-event-v1.luau --studio $studio --mode PersistentBenchmark --case state-burst-c2s --recipients 1 --adapter relay-reliable
```

| Case | `--recipients` | Load |
| --- | --- | --- |
| `tiny-steady-c2s` | 1 | 1 Tiny message/frame |
| `state-steady-c2s` | 1 | 1 State message/frame |
| `state-burst-c2s` | 1 | 4 State messages/frame |
| `state-broadcast-s2c` | 1, 4, or 8 | 1 State broadcast/frame |
| `tiny-round-trip` | 1 | Sequential Tiny request/echo |

Tiny contains `sequence: u32` and `enabled: boolean`. State contains
`sequence: u32`, `entityId: u16`, `position: Vector3F32`, `yaw: f32`, and
`health: u8`. Workloads advance on `PostSimulation`; 60 FPS is a target,
so offered messages per second vary with actual frame rate. Avatars are disabled.

Adapter IDs: `native-reliable` (default), `relay-reliable`, `quicknet`,
`bytenet`, `satset`, `warp`, `blink`, `zap`, and `netray-compile`.
Suphi-Packet is excluded because its intentional sender buffering cannot be
proven to satisfy the one-added-frame limit. For external adapters, first run:

```powershell
lune run scripts/acquire-benchmark-libraries.luau --all
lune run scripts/generate-benchmark-adapters.luau --all
```

Both commands support `--verify`. See the [adapter guide](adapters/README.md)
for qualification and [the lock file](libraries.lock.json) for versions and
licenses. Never edit or commit downloaded libraries, generated code, or raw
local result artifacts.

Results are written to `benchmarks/results/local/<launch-id>.result-v2.json`
after source/artifact checks and confirmed Studio exit. Only `Valid` results
make the host command succeed. If it reports `HOST_E_CHILD_LIVE`, confirm the
Studio processes have exited before another run. Keep authenticated logs private.

```powershell
lune run benchmarks/reporting/compare-results.luau --result "<first.result-v2.json>" --result "<second.result-v2.json>"
```

## Measurement rules

- Prove correctness separately from timing. Fresh deterministic inputs must
  survive unchanged; missing, duplicate, stale, misordered, or corrupted delivery
  invalidates a run. Preserve receiver-before-sender ordering, continuous
  observation, and verified cleanup.
- Keep setup, dependency loading, readiness, warmup, both 60-frame quiet windows,
  and result extraction outside timing. No runner control traffic is allowed
  during measured frames.
- Workloads rank only by `frameTime`; the separate probe ranks by
  `roundTripLatency`. Call duration, shared-clock completion/drain/wall duration,
  and engine-wide send rate are diagnostics. Local durations use `os.clock()`;
  approximate shared-clock durations cannot decide rankings. The 3 ms startup
  clock allowance is not an accuracy guarantee.
- Compare matching case/topology, lane, broadcast mode, profile/isolation,
  contract, measurement fingerprint, Studio, and host metadata. Keep every run
  separate; never pool incompatible samples, repair invalid evidence, or relabel
  old results. Record collection order, failures, retries, and machine conditions.
- Documentation changes need evidence validation, not fresh Studio timing runs.
  Use focused checks during development and a full matrix only after the measured
  setup is frozen. Shared measurement changes require a new cohort; adapter
  changes require new evidence for that adapter. Correctness is not a decoder
  security audit.

The [workload contract](contracts/event-v1.luau),
[session profile](contracts/internal/PersistentSessionProfile.luau), and
[host](host/HostRuntime.luau) define the detailed boundaries. Relay's
[binding](adapters/relay-reliable/init.luau) uses the public API with production
validation and admission limits enabled. Portable correctness checks run with
`lune run scripts/verify-foundation.luau` without launching Studio.
