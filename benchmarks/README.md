# Relay benchmarks

For fast local iterations, use the [quick Studio benchmark](quick/README.md).
It compares selected libraries in one Play session and can rerun without
restarting Studio. The rigorous workflow and audited results remain below.

For saved MicroProfiler HTML exports, use the [structured analysis CLI](profiling/html/README.md).
It extracts supported frame, marker and network records without opening the dump
in a browser window or launching Studio. Keep these diagnostics separate from
benchmark rankings; traffic attribution and physical wire bytes require their
own evidence.

The quick runner can optionally load pinned LibMP through
[`--profile-receive --libmp`](quick/README.md#capture-send-and-receive-cpu-scopes-with-libmp).
It captures exact client send-loop and server receive CPU scopes through ordinary
Play, adds send/receive stage markers to isolated Relay copies, and prints compact
reports with stage observations and slow frame intervals.
Ordinary runs do not load LibMP. These instrumented observations remain separate
from rankings. One real State-burst C2S workload passed native collector validation;
timing/ranking qualification remains pending. See the [qualification status](../context.md).

For CPU marker diagnostics, the working private probe wraps non-yielding work
in a client `PreSimulation` callback, pauses and retains the capture, then
matches ordered enter/exit records by exact timer, thread and regular/absolute
frame IDs. A descriptor alone does not prove execution, and a capped scan does
not prove full-window absence. Native UI corroboration remains incomplete.

## Payload categories

Choose the data type first. Direction and pacing describe how the same payload
is sent: client to server, broadcast to clients, or request/echo; steady sends
one message/frame and burst sends four. Internal case IDs remain available for
running the exact test. A sequence number checks ordering in every payload.

| Category | Actual payload | Library coverage | Results / runnable case |
| --- | --- | --- | --- |
| Booleans | 1 boolean + u32 sequence | All compared libraries | Published below; `tiny-steady-c2s` |
| Mixed state | u16 entity ID, Vector3, f32 yaw, u8 health + u32 sequence | All compared libraries | Published below; steady, burst, and broadcast variants |
| Numbers | i8, i16, i32 + u32 sequence | All ten eligible libraries in core suite | Not published; `schema-signed-c2s` |
| Strings | Varied 64-byte string + u32 sequence | All ten eligible libraries in core suite | Not published; `schema-string-c2s` |
| Vectors | Vector3F32 + u32 sequence | All ten eligible libraries in core suite | Not published; `schema-vector3-c2s` |
| CFrames | Position and rotation + u32 sequence | Relay diagnostic | Not published; `schema-cframe-c2s` |
| Entity arrays | 16 records: entity ID, score, enabled + u32 sequence | Native, Relay, BlinkBlox diagnostic | Not published; `schema-composite-c2s` |
| RPC | boolean + u32 sequence request and reply | Relay, BlinkBlox diagnostic | Not published; `tiny-rpc` |

Run the five matched core categories with one library or all ten eligible
libraries in one Studio Play. Library and category selection are independent:

```powershell
lune run benchmarks/quick/build.luau --adapters relay-reliable --category all
lune run benchmarks/quick/build.luau --adapters relay-reliable,quicknet --category strings
lune run benchmarks/quick/build.luau --all --category all
```

The [quick guide](quick/README.md) explains setup, reruns, and output. Numbers,
Strings, and dedicated Vectors have no published measurements yet. CFrames,
and Vector2 remain additional Relay diagnostics. Entity arrays and actual RPC
have separate matched quick categories described in the guide. Missing
measurements are not filled from a different payload.

## Local FPS and bandwidth diagnostics (October 7, 2026)

Frozen source `37906f0`; Studio `0.741.19.7411056`; Native RemoteEvent,
Relay, QuickNet `v0.3.5-beta`, and Blink `v0.18.9`. This source predates the
integrated Relay 0.2.0 features. One client, one message/frame, four balanced
rounds of 120 measured frames per adapter, with warmup and correctness outside timing.

**Rows sort by sender FPS, highest first.** This is local diagnostic order,
not a qualified competitive ranking. FPS is the median of the four round FPS
values (each is 1 / mean sender frame interval). FPS scale divides by Native
in the same case and broadcast mode; N/A means no matching Native baseline.
Send KB/s is the median of the time-weighted engine-wide send rates, in
kilobytes/second. It includes background/control traffic and is not attributable
wire bandwidth. Broadcast modes stay separate. These samples are not pooled
with the canonical results below; small FPS differences do not prove repeatable wins.

### Booleans: client to server, steady

| Order | Library | Sender FPS | FPS scale vs Native | Send KB/s | Sent / verified |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Native RemoteEvent | 232.16 | 1.000x | 3.92 | 480 / 480 |
| 2 | Blink v0.18.9 | 224.27 | 0.966x | 4.01 | 480 / 480 |
| 3 | Relay | 219.52 | 0.946x | 5.28 | 480 / 480 |
| 4 | QuickNet v0.3.5-beta | 211.74 | 0.912x | 3.77 | 480 / 480 |

### Mixed state: client to server, steady

| Order | Library | Sender FPS | FPS scale vs Native | Send KB/s | Sent / verified |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Native RemoteEvent | 237.71 | 1.000x | 10.06 | 480 / 480 |
| 2 | Relay | 234.23 | 0.985x | 11.73 | 480 / 480 |
| 3 | Blink v0.18.9 | 224.24 | 0.943x | 6.65 | 480 / 480 |
| 4 | QuickNet v0.3.5-beta | 223.68 | 0.941x | 6.75 | 480 / 480 |

### Mixed state: broadcast to clients, 1 recipient / NativeBroadcast

| Order | Library | Sender FPS | FPS scale vs Native | Send KB/s | Sent / verified |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Native RemoteEvent | 228.73 | 1.000x | 10.66 | 480 / 480 |
| 2 | Relay | 222.17 | 0.971x | 11.70 | 480 / 480 |

### Mixed state: broadcast to clients, 1 recipient / AdapterFanOut

| Order | Library | Sender FPS | FPS scale vs Native | Send KB/s | Sent / verified |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | QuickNet v0.3.5-beta | 229.54 | N/A | 7.49 | 480 / 480 |
| 2 | Blink v0.18.9 | 216.06 | N/A | 7.25 | 480 / 480 |

## Native/Relay snapshot (September 26, 2026; source `d507a7a9`)

This dated snapshot does not measure the current working tree. It has one valid
Native RemoteEvent run and one valid Relay run for each of the seven canonical
selections. All 14 Result V2 runs used Studio `0.740.19.7400931`, the
`event-session-v1` contract, one fresh session per row, and 30 persistent
windows. Workload rows lead with sender FPS derived from frame intervals;
the separate round-trip table shows request/echo latency. Original median / p95
milliseconds remain visible, rounded to three decimals for display.

*Sender FPS* is 1000 / displayed median frame interval in ms, not average or
rendered FPS. Scale is Native frame median / library frame median in the same
selection. Send KB/s is unmeasured in this canonical snapshot.

| Payload / scenario | Rank | Library | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Booleans: client to server, steady, 1 client | 1 | Relay 0.1.0 | 240.73 | 1.004x | Unmeasured | 4.154 / 6.090 |
| Booleans: client to server, steady, 1 client | 2 | Native RemoteEvent | 239.69 | 1.000x | Unmeasured | 4.172 / 7.483 |
| Mixed state: client to server, steady, 1 client | 1 | Relay 0.1.0 | 240.38 | 1.003x | Unmeasured | 4.160 / 7.152 |
| Mixed state: client to server, steady, 1 client | 2 | Native RemoteEvent | 239.69 | 1.000x | Unmeasured | 4.172 / 7.609 |
| Mixed state: client to server, burst, 1 client | 1 | Relay 0.1.0 | 241.55 | 1.008x | Unmeasured | 4.140 / 5.419 |
| Mixed state: client to server, burst, 1 client | 2 | Native RemoteEvent | 239.64 | 1.000x | Unmeasured | 4.173 / 8.052 |
| Mixed state: broadcast to clients, 1 recipient | 1 | Native RemoteEvent | 239.92 | 1.000x | Unmeasured | 4.168 / 7.038 |
| Mixed state: broadcast to clients, 1 recipient | 2 | Relay 0.1.0 | 239.18 | 0.997x | Unmeasured | 4.181 / 7.620 |
| Mixed state: broadcast to clients, 4 recipients | 1 | Native RemoteEvent | 238.27 | 1.000x | Unmeasured | 4.197 / 7.913 |
| Mixed state: broadcast to clients, 4 recipients | 2 | Relay 0.1.0 | 238.15 | 1.000x | Unmeasured | 4.199 / 7.638 |
| Mixed state: broadcast to clients, 8 recipients | 1 | Native RemoteEvent | 221.34 | 1.000x | Unmeasured | 4.518 / 12.427 |
| Mixed state: broadcast to clients, 8 recipients | 2 | Relay 0.1.0 | 219.83 | 0.993x | Unmeasured | 4.549 / 12.084 |

Booleans: request and echo, 1 client (request/echo latency):

| Rank | Library | RTT median / p95 ms |
| ---: | --- | ---: |
| 1 | Native RemoteEvent | 11.093 / 12.822 |
| 2 | Relay 0.1.0 | 12.019 / 13.444 |

Every workload row passed its expected submission and delivery counts with no
missing, duplicate, out-of-order, unexpected, or mismatched deliveries. The two
round-trip rows passed their separate probe checks. Each row remains an
independent run; its windows are correlated, and small differences do not
establish repeatable wins. Raw results, hashes, logs, and the audit stay in
ignored local files. The older library comparisons below use different source
and Studio pins and must not be ranked against this cohort.

## Historical library results: fastest to slowest

All **seven case/topology selections** and **nine eligible adapters** are
represented below. Native State-steady C2S is the one unmeasured historical
combination. These are the latest completed valid runs per adapter and compatible
group from the audited September 7–11, 2026 collections: **76 selected runs**.

**Rank 1 has the highest derived sender FPS (lowest frame median); round trips
rank by lowest latency.** Tables sort by the unrounded median; exact
ties share a rank. P95 is shown separately and can favor a different library.
Rank resets for each workload, Studio version, and broadcast mode. There is no
combined ranking across those groups. Small differences in a single local
session do not establish repeatable wins.

Each row is one session with 30 persistent windows. Workload rankings measure
**sender frame intervals**, in milliseconds. Only the round-trip probe measures
request/echo latency. The source beside each library identifies the measured
benchmark revision; for Relay, it also identifies the library implementation.

**† Call duration** is median / p95 in microseconds per public submit or broadcast.
It is diagnostic, excludes deferred transport and receiver work, and does not
determine rank. Expand a workload and its diagnostic tables to see every
available timing metric:

- **Submission:** first submission start to final return, including inter-frame time.
- **Completion:** first submission start to final expected receipt.
- **Drain:** final submission return to final expected receipt.
- **Wall:** first submission start to final receipt passing correctness checks.

*Sender FPS* is 1000 / displayed median frame interval in ms; it is not average
or rendered FPS. FPS scale is Native frame median / library frame median within
the same table. N/A means no compatible Native baseline. Derived values use the
rounded displayed intervals and are approximate; the ordering retains the original
unrounded medians. At least 95% of frame intervals were at or below p95; it
remains a secondary diagnostic.

Bandwidth, packet size, remote-call counts, and memory/GC were unavailable in
these historical runs; Send KB/s is marked Unmeasured. All workload runs passed
their exact submission/delivery counts and correctness checks.

<details open>
<summary><strong>Booleans: client to server, steady</strong></summary>

1 client; 1 message/frame; 3,600 measured frames per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Relay `3030944` | 220.56 | 1.002x | Unmeasured | 4.534 / 7.765 | 39.700 / 60.800 |
| 2 | Native RemoteEvent `3030944` | 220.12 | 1.000x | Unmeasured | 4.543 / 7.690 | 21.300 / 33.400 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 526.014 / 628.524 | 528.719 / 627.651 | 1.841 / 4.987 | 528.734 / 628.521 |
| Native RemoteEvent | 542.929 / 591.481 | 542.923 / 592.729 | 0.000 / 3.103 | 543.038 / 592.736 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | NetRay-Compile `4ce556e` | 220.90 | N/A | Unmeasured | 4.527 / 7.900 | 34.500 / 50.700 |
| 2 | Relay `4ce556e` | 220.85 | N/A | Unmeasured | 4.528 / 8.042 | 51.800 / 80.400 |
| 3 | Satset `4ce556e` | 218.48 | N/A | Unmeasured | 4.577 / 10.038 | 23.900 / 41.100 |
| 4 | ByteNet `4ce556e` | 218.29 | N/A | Unmeasured | 4.581 / 9.934 | 19.900 / 31.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 541.769 / 609.565 | 546.264 / 609.908 | 1.483 / 4.973 | 546.288 / 609.931 |
| Relay | 540.122 / 688.382 | 541.837 / 688.497 | 0.333 / 4.828 | 541.856 / 688.514 |
| Satset | 623.779 / 737.220 | 624.423 / 737.725 | 1.716 / 6.939 | 624.443 / 737.749 |
| ByteNet | 616.820 / 700.064 | 620.827 / 701.937 | 2.509 / 4.831 | 620.846 / 703.066 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Zap `4ce556e` | 223.81 | N/A | Unmeasured | 4.468 / 7.761 | 33.000 / 49.600 |
| 2 | Warp `4ce556e` | 222.37 | N/A | Unmeasured | 4.497 / 7.884 | 14.400 / 21.700 |
| 3 | Blink `4ce556e` | 220.75 | N/A | Unmeasured | 4.530 / 7.860 | 37.800 / 56.200 |
| 4 | QuickNet `4ce556e` | 219.11 | N/A | Unmeasured | 4.564 / 9.498 | 21.100 / 32.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Zap | 531.402 / 645.780 | 531.473 / 645.404 | 0.359 / 2.590 | 531.894 / 645.780 |
| Warp | 539.021 / 623.148 | 542.053 / 621.125 | 1.789 / 5.162 | 542.070 / 623.149 |
| Blink | 546.423 / 630.832 | 547.637 / 627.139 | 2.999 / 4.869 | 547.656 / 630.828 |
| QuickNet | 556.532 / 982.286 | 557.915 / 983.027 | 0.819 / 3.383 | 558.202 / 983.050 |

</details>

</details>

<details>
<summary><strong>Mixed state: client to server, steady</strong></summary>

1 client; 1 message/frame; 3,600 measured frames per run. Native has no compatible measurement.

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Relay `4ce556e` | 223.86 | N/A | Unmeasured | 4.467 / 7.601 | 55.850 / 84.800 |
| 2 | Satset `4ce556e` | 222.27 | N/A | Unmeasured | 4.499 / 7.912 | 23.650 / 36.900 |
| 3 | NetRay-Compile `4ce556e` | 221.88 | N/A | Unmeasured | 4.507 / 7.516 | 29.000 / 45.500 |
| 4 | ByteNet `4ce556e` | 218.96 | N/A | Unmeasured | 4.567 / 8.022 | 19.900 / 29.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 522.640 / 629.700 | 524.827 / 631.713 | 0.874 / 4.249 | 524.851 / 631.734 |
| Satset | 536.619 / 632.671 | 536.858 / 632.454 | 1.053 / 5.384 | 537.163 / 632.668 |
| NetRay-Compile | 531.612 / 613.390 | 536.838 / 614.841 | 0.000 / 2.619 | 537.724 / 614.868 |
| ByteNet | 545.683 / 657.259 | 547.861 / 661.160 | 1.128 / 4.634 | 547.881 / 661.185 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Warp `4ce556e` | 223.91 | N/A | Unmeasured | 4.466 / 7.793 | 14.500 / 21.900 |
| 2 | QuickNet `4ce556e` | 221.83 | N/A | Unmeasured | 4.508 / 7.795 | 21.000 / 31.500 |
| 3 | Zap `4ce556e` | 220.95 | N/A | Unmeasured | 4.526 / 7.886 | 34.200 / 51.500 |
| 4 | Blink `4ce556e` | 219.97 | N/A | Unmeasured | 4.546 / 7.932 | 36.500 / 52.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Warp | 537.377 / 637.440 | 536.289 / 637.147 | 1.256 / 3.027 | 537.379 / 637.438 |
| QuickNet | 537.522 / 629.624 | 538.747 / 632.348 | 1.089 / 4.395 | 538.951 / 632.379 |
| Zap | 549.720 / 633.558 | 550.503 / 633.984 | 0.430 / 3.016 | 550.528 / 634.013 |
| Blink | 542.741 / 624.569 | 544.856 / 624.439 | 0.637 / 5.097 | 546.605 / 624.569 |

</details>

</details>

<details>
<summary><strong>Mixed state: client to server, burst</strong></summary>

1 client; 4 messages/frame; 300 measured frames and 1,200 calls per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Relay `3030944` | 220.17 | 1.003x | Unmeasured | 4.542 / 7.892 | 14.000 / 47.100 |
| 2 | Native RemoteEvent `3030944` | 219.59 | 1.000x | Unmeasured | 4.554 / 7.626 | 8.850 / 26.200 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 41.919 / 50.517 | 42.129 / 66.831 | 0.259 / 3.579 | 43.250 / 66.839 |
| Native RemoteEvent | 38.399 / 47.159 | 40.695 / 48.601 | 1.455 / 5.374 | 41.519 / 49.838 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | ByteNet `4ce556e` | 224.27 | N/A | Unmeasured | 4.459 / 7.617 | 7.600 / 23.600 |
| 2 | NetRay-Compile `4ce556e` | 223.31 | N/A | Unmeasured | 4.478 / 7.239 | 8.650 / 35.600 |
| 3 | Relay `4ce556e` | 221.43 | N/A | Unmeasured | 4.516 / 7.730 | 15.750 / 51.900 |
| 4 | Satset `4ce556e` | 220.12 | N/A | Unmeasured | 4.543 / 8.072 | 7.950 / 22.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| ByteNet | 38.543 / 49.615 | 38.805 / 54.370 | 0.117 / 5.005 | 39.469 / 54.377 |
| NetRay-Compile | 38.493 / 46.129 | 39.127 / 48.172 | 1.002 / 4.052 | 39.305 / 48.179 |
| Relay | 39.765 / 50.734 | 39.160 / 49.353 | 0.000 / 3.325 | 40.475 / 50.734 |
| Satset | 39.698 / 54.969 | 42.390 / 58.515 | 0.823 / 4.093 | 42.397 / 58.523 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Zap `4ce556e` | 226.24 | N/A | Unmeasured | 4.420 / 7.757 | 10.200 / 33.500 |
| 2 | QuickNet `4ce556e` | 222.47 | N/A | Unmeasured | 4.495 / 5.283 | 6.100 / 17.900 |
| 3 | Blink `4ce556e` | 219.49 | N/A | Unmeasured | 4.556 / 8.242 | 9.500 / 34.400 |
| 4 | Warp `4ce556e` | 217.01 | N/A | Unmeasured | 4.608 / 8.286 | 6.000 / 15.400 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Zap | 38.357 / 49.619 | 39.626 / 48.838 | 0.533 / 3.246 | 39.798 / 49.613 |
| QuickNet | 37.578 / 42.045 | 38.762 / 44.557 | 0.753 / 2.921 | 38.913 / 44.567 |
| Blink | 42.291 / 50.691 | 43.784 / 51.870 | 1.249 / 5.295 | 43.871 / 51.881 |
| Warp | 43.855 / 55.256 | 45.670 / 56.209 | 0.396 / 3.793 | 45.760 / 56.218 |

</details>

</details>

<details>
<summary><strong>Mixed state: broadcast to 1 client</strong></summary>

1 broadcast/frame; 3,600 measured frames and 3,600 correct deliveries per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Relay `89b4d2f` | 220.07 | 1.007x | Unmeasured | 4.544 / 7.822 | 37.400 / 57.600 |
| 2 | Native RemoteEvent `89b4d2f` | 218.58 | 1.000x | Unmeasured | 4.575 / 7.824 | 19.600 / 30.300 |
| 3 | Satset `89b4d2f` | 218.48 | 1.000x | Unmeasured | 4.577 / 7.692 | 15.400 / 23.800 |
| 4 | ByteNet `89b4d2f` | 217.77 | 0.996x | Unmeasured | 4.592 / 7.863 | 13.800 / 19.100 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 532.380 / 616.741 | 537.865 / 625.565 | 7.445 / 10.499 | 537.882 / 625.589 |
| Native RemoteEvent | 535.036 / 611.920 | 541.997 / 616.625 | 5.190 / 10.097 | 542.022 / 616.647 |
| Satset | 525.350 / 587.511 | 535.736 / 592.222 | 8.304 / 13.316 | 535.752 / 592.231 |
| ByteNet | 552.125 / 627.779 | 561.210 / 637.748 | 6.745 / 10.828 | 561.229 / 637.756 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | NetRay-Compile `4ce556e` | 219.49 | N/A | Unmeasured | 4.556 / 7.867 | 28.800 / 44.400 |
| 2 | ByteNet `4ce556e` | 219.44 | N/A | Unmeasured | 4.557 / 7.772 | 17.400 / 25.500 |
| 3 | Satset `4ce556e` | 219.25 | N/A | Unmeasured | 4.561 / 7.923 | 22.200 / 33.200 |
| 4 | Relay `4ce556e` | 218.39 | N/A | Unmeasured | 4.579 / 7.805 | 43.400 / 64.500 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 553.121 / 629.099 | 562.449 / 638.246 | 8.448 / 11.626 | 562.479 / 638.275 |
| ByteNet | 521.041 / 599.662 | 529.613 / 607.074 | 8.069 / 10.865 | 529.634 / 607.087 |
| Satset | 537.664 / 613.312 | 546.421 / 618.463 | 8.134 / 11.324 | 546.443 / 618.472 |
| Relay | 535.304 / 683.689 | 540.999 / 690.255 | 8.144 / 12.218 | 541.011 / 690.269 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Blink `4ce556e` | 219.49 | N/A | Unmeasured | 4.556 / 7.842 | 41.800 / 67.400 |
| 2 | Zap `4ce556e` | 219.49 | N/A | Unmeasured | 4.556 / 7.753 | 37.300 / 58.200 |
| 3 | QuickNet `4ce556e` | 218.34 | N/A | Unmeasured | 4.580 / 8.264 | 23.300 / 39.000 |
| 4 | Warp `4ce556e` | 218.29 | N/A | Unmeasured | 4.581 / 7.853 | 19.700 / 28.900 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Blink | 541.193 / 628.693 | 547.518 / 635.955 | 5.661 / 11.378 | 547.543 / 635.979 |
| Zap | 527.271 / 608.130 | 536.355 / 614.230 | 5.838 / 9.519 | 536.378 / 614.257 |
| QuickNet | 553.689 / 649.788 | 564.231 / 653.328 | 9.078 / 13.518 | 564.259 / 653.345 |
| Warp | 541.273 / 637.183 | 547.366 / 644.098 | 5.296 / 8.946 | 547.381 / 644.130 |

</details>

</details>

<details>
<summary><strong>Mixed state: broadcast to 4 clients</strong></summary>

1 broadcast/frame; 3,600 measured frames and 14,400 correct deliveries per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Native RemoteEvent `89b4d2f` | 219.20 | 1.000x | Unmeasured | 4.562 / 8.191 | 27.900 / 45.500 |
| 2 | ByteNet `89b4d2f` | 218.15 | 0.995x | Unmeasured | 4.584 / 8.281 | 22.200 / 36.900 |
| 3 | Relay `89b4d2f` | 217.06 | 0.990x | Unmeasured | 4.607 / 7.789 | 50.300 / 75.800 |
| 4 | Satset `89b4d2f` | 216.12 | 0.986x | Unmeasured | 4.627 / 8.263 | 25.100 / 45.100 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Native RemoteEvent | 566.752 / 616.700 | 577.747 / 627.736 | 11.142 / 16.552 | 577.777 / 627.770 |
| ByteNet | 565.904 / 645.741 | 580.795 / 660.856 | 11.106 / 24.944 | 580.816 / 660.870 |
| Relay | 538.907 / 595.725 | 832.605 / 892.242 | 329.783 / 335.955 | 832.624 / 892.270 |
| Satset | 572.335 / 704.628 | 586.899 / 721.046 | 11.729 / 30.587 | 586.934 / 721.064 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | NetRay-Compile `96e8156` | 221.88 | N/A | Unmeasured | 4.507 / 8.102 | 32.800 / 49.500 |
| 2 | Relay `96e8156` | 217.39 | N/A | Unmeasured | 4.600 / 8.042 | 48.500 / 71.700 |
| 3 | ByteNet `96e8156` | 217.34 | N/A | Unmeasured | 4.601 / 8.000 | 20.500 / 30.800 |
| 4 | Satset `96e8156` | 216.87 | N/A | Unmeasured | 4.611 / 7.941 | 22.400 / 33.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 556.225 / 626.535 | 566.417 / 636.978 | 9.401 / 17.450 | 566.435 / 637.009 |
| Relay | 552.713 / 603.809 | 562.001 / 613.966 | 8.855 / 15.235 | 562.021 / 613.997 |
| ByteNet | 535.751 / 628.958 | 545.445 / 636.430 | 9.954 / 13.873 | 545.461 / 636.455 |
| Satset | 561.835 / 636.550 | 572.318 / 668.878 | 9.791 / 61.814 | 572.341 / 668.884 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Warp `4ce556e` | 238.66 | N/A | Unmeasured | 4.190 / 7.762 | 23.700 / 33.900 |
| 2 | Blink `4ce556e` | 237.47 | N/A | Unmeasured | 4.211 / 7.906 | 67.400 / 104.100 |
| 3 | Zap `4ce556e` | 219.25 | N/A | Unmeasured | 4.561 / 8.093 | 69.700 / 103.800 |
| 4 | QuickNet `4ce556e` | 215.61 | N/A | Unmeasured | 4.638 / 8.240 | 33.200 / 48.800 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Warp | 528.357 / 608.407 | 536.003 / 618.289 | 9.632 / 12.394 | 536.035 / 618.319 |
| Blink | 528.497 / 630.492 | 539.129 / 652.412 | 10.298 / 13.612 | 539.157 / 652.430 |
| Zap | 541.280 / 671.463 | 551.169 / 684.747 | 10.387 / 16.921 | 551.201 / 684.778 |
| QuickNet | 578.216 / 640.736 | 588.498 / 648.612 | 9.913 / 19.036 | 588.527 / 648.642 |

</details>

</details>

<details>
<summary><strong>Mixed state: broadcast to 8 clients</strong></summary>

1 broadcast/frame; 3,600 measured frames and 28,800 correct deliveries per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Native RemoteEvent `3030944` | 215.56 | 1.000x | Unmeasured | 4.639 / 10.266 | 31.200 / 52.000 |
| 2 | ByteNet `89b4d2f` | 210.53 | 0.977x | Unmeasured | 4.750 / 11.249 | 27.100 / 45.300 |
| 3 | Satset `89b4d2f` | 200.56 | 0.930x | Unmeasured | 4.986 / 13.356 | 30.000 / 53.400 |
| 4 | Relay `3030944` | 196.39 | 0.911x | Unmeasured | 5.092 / 16.380 | 57.900 / 112.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Native RemoteEvent | 619.200 / 784.168 | 634.654 / 1115.417 | 15.555 / 427.087 | 634.694 / 1115.449 |
| ByteNet | 655.815 / 785.525 | 670.773 / 800.507 | 14.693 / 29.334 | 670.894 / 800.563 |
| Satset | 715.610 / 910.524 | 731.765 / 993.784 | 17.475 / 52.981 | 731.793 / 993.798 |
| Relay | 790.812 / 968.505 | 811.176 / 998.909 | 19.613 / 31.407 | 811.198 / 998.941 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | NetRay-Compile `96e8156` | 223.46 | N/A | Unmeasured | 4.475 / 9.352 | 42.100 / 78.000 |
| 2 | Relay `96e8156` | 223.36 | N/A | Unmeasured | 4.477 / 12.012 | 68.200 / 130.200 |
| 3 | Satset `96e8156` | 217.34 | N/A | Unmeasured | 4.601 / 13.727 | 29.100 / 61.400 |
| 4 | ByteNet `96e8156` | 216.12 | N/A | Unmeasured | 4.627 / 13.788 | 26.200 / 54.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 596.720 / 673.044 | 610.041 / 686.914 | 13.578 / 21.600 | 610.082 / 686.949 |
| Relay | 670.355 / 808.411 | 698.689 / 818.906 | 16.154 / 31.654 | 698.707 / 818.936 |
| Satset | 686.292 / 929.563 | 705.899 / 947.947 | 17.205 / 49.201 | 705.942 / 947.961 |
| ByteNet | 680.330 / 846.559 | 694.044 / 911.434 | 15.415 / 31.668 | 694.073 / 911.461 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Sender FPS* | FPS scale vs Native | Send KB/s | Frame median / p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Warp `4ce556e` | 215.24 | N/A | Unmeasured | 4.646 / 10.004 | 34.300 / 52.500 |
| 2 | Blink `4ce556e` | 213.36 | N/A | Unmeasured | 4.687 / 9.848 | 106.300 / 161.500 |
| 3 | QuickNet `4ce556e` | 211.10 | N/A | Unmeasured | 4.737 / 12.457 | 46.000 / 73.400 |
| 4 | Zap `4ce556e` | 205.04 | N/A | Unmeasured | 4.877 / 14.211 | 112.600 / 197.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Warp | 627.447 / 738.501 | 641.491 / 754.505 | 14.308 / 25.544 | 641.524 / 754.534 |
| Blink | 627.118 / 737.135 | 639.643 / 754.520 | 13.179 / 31.709 | 639.670 / 754.534 |
| QuickNet | 686.544 / 835.823 | 698.914 / 962.076 | 18.154 / 26.236 | 698.930 / 963.005 |
| Zap | 743.194 / 938.744 | 759.757 / 958.500 | 16.118 / 54.602 | 759.791 / 958.515 |

</details>

</details>

<details>
<summary><strong>Booleans: request and echo</strong></summary>

1 client; one request in flight; 3,600 measured request/echo round trips per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | RTT median ms | RTT p95 ms |
| ---: | --- | ---: | ---: |
| 1 | Native RemoteEvent `3030944` | 7.935 | 11.095 |
| 2 | Relay `3030944` | 7.976 | 9.174 |
| 3 | Satset `89b4d2f` | 10.973 | 15.925 |
| 4 | ByteNet `89b4d2f` | 11.079 | 12.697 |

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | RTT median ms | RTT p95 ms |
| ---: | --- | ---: | ---: |
| 1 | ByteNet `4ce556e` | 7.986 | 9.424 |
| 2 | Satset `4ce556e` | 8.034 | 12.590 |
| 3 | Relay `4ce556e` | 11.202 | 13.023 |
| 4 | NetRay-Compile `4ce556e` | 11.562 | 13.255 |

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | RTT median ms | RTT p95 ms |
| ---: | --- | ---: | ---: |
| 1 | Warp `4ce556e` | 7.955 | 12.344 |
| 2 | QuickNet `4ce556e` | 11.302 | 12.926 |
| 3 | Blink `4ce556e` | 11.491 | 12.925 |
| 4 | Zap `4ce556e` | 11.849 | 12.876 |

</details>

<details>
<summary>Versions, source revisions, and collection record</summary>

| Adapter | Measured library version |
| --- | --- |
| Native RemoteEvent | Studio version in each table |
| Relay | 0.1.0, with the exact revision shown per row |
| ByteNet | v0.4.3 |
| Satset | v0.4.2 |
| NetRay-Compile | v0.1.1-cli.1 |
| Blink | v0.18.8 |
| QuickNet | v0.3.4-beta |
| Warp | 1.0.14 |
| Zap | v0.6.29 |

| Source revision | Collection date (UTC) | Valid runs |
| --- | --- | ---: |
| `4ce556e` | September 7 | 56 |
| `96e8156` | September 9 | 16 |
| `89b4d2f` | September 10 | 16 |
| `3030944` | September 11 | 8 |

All 96 artifacts passed hash checks, Result V2 validation, and the strict
comparison reporter; 20 superseded repeats are omitted from the displayed rankings.
Selection uses each ledger's completion timestamp, never
the fastest repeat. Compatible groups also require matching profile, contract,
measurement fingerprint, host, and topology; all use `EquivalentSemantics`
and `PersistentSession`. Native broadcast and adapter fan-out remain separate,
including for C2S and round-trip cases. The collections used no timing-based
retries.

Machine identity does not prove stable load or temperature; 30 windows in one
process are correlated observations. These results do not establish production
internet performance.

Raw results and logs remain private and ignored under
`benchmarks/results/local/`.

</details>

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
Relay's CLI Studio launchers share `ProgramData/relay-studio-host-v1.lock`
across Windows accounts and checkouts. The path uses Windows' machine-wide
CommonApplicationData folder, independent of the caller's environment. An
existing lease blocks new launches,
including after a crash or uncertain teardown. Before manually removing a
retained lease, verify that its prior host and every Studio child are gone;
the launcher never reclaims it by age or PID alone. An unavailable shared
location fails closed.

```powershell
lune run benchmarks/reporting/compare-results.luau --result "<first.result-v2.json>" --result "<second.result-v2.json>"
```

### Collect a paired broadcast study

The study driver runs canonical State broadcast for one selected topology
(`1`, `4`, or `8` recipients). Preview its schedule without launching Studio:

```powershell
lune run benchmarks/host/run-broadcast-study.luau --plan --studio $studio --recipients 4
```

Before a timing campaign, rehearse the verified-copy child path without collecting
workload timings:

```powershell
lune run benchmarks/host/run-broadcast-study.luau --rehearse --studio $studio --recipients 1 --baseline E:/relay-baseline --candidate E:/relay-candidate
```

The optional candidate adds one candidate-role attempt to the single baseline
attempt. Each uses the copied baseline runner, the selected role's copied source,
the pinned tools and Studio, and the existing authenticated `ControlProof` path.
Both original checkouts must be clean. Success requires stable copied/original
inputs, an exact control marker, no result output, confirmed Studio exit and host
lease cleanup. Rehearsal retains a separate ledger and terminal marker; canonical
study reporters and recovery reject it. It checks startup, control, provenance
and teardown, not application workload delivery or performance. It cannot restart
an interrupted timing study and does not produce Result V1/V2 or comparative data.

Use `--run` to collect fresh sessions serially: native, Relay baseline, an
identical Relay control, then the reverse order. Each session still has the
canonical 30 measurement windows. `--baseline <clean-checkout>` selects another
baseline root; it defaults to the current directory. An optional
`--candidate <clean-checkout>` adds a candidate before the reverse pass:

```powershell
lune run benchmarks/host/run-broadcast-study.luau --run --studio $studio --recipients 4 --baseline E:/relay-baseline --candidate E:/relay-candidate
```

Collection requires clean, stable source and a fixed Studio executable. All
sessions use a verified copy of the baseline checkout's host code, including
candidate sessions. Each source role gets a fresh sibling execution directory;
the child runs with its selected role's copy as cwd. Project, generated/vendor,
build and result paths stay in that copy, which contains no Git metadata.
Every attempt retains host stdout/stderr and new raw results in a unique
`.tmp/broadcast-study-<token>/` directory under the baseline checkout. The ledger
and retained artifacts use exclusive Windows file creation, so a path collision
fails without replacing earlier bytes. The ledger records order, source/result
hashes, separate call/frame/drain/completion
summaries, and baseline/control variation. Validation and summaries use the exact
bytes archived under the recorded result hash. Call durations use microseconds per
event; frame/drain/completion durations use milliseconds. Each log stream is
limited to 128 KiB; exceeding that limit retains the prefix and fails the attempt.
Failures stop the study. Existing
results are never reused as a successful new attempt, and samples are not pooled.
The driver checks canonical result compatibility and does not choose a winner.

New v4 studies record a prelaunch input manifest covering tracked checkout
bytes, recursive canonical Rojo project inputs, pinned Lune/Rojo binaries and
shims, the Studio executable, and the frozen study plan. Inputs are rechecked
around each host attempt; a mismatch fails that attempt after retaining any new
raw evidence. Nested Rojo project files inside the scanned project tree are
rejected until their referenced paths have an explicit closure design.
An attempt receipt binds the copied inventories, execution roots, original
checkout/revision, manifest, attempt and absolute tool/Studio pins. The parent
checks both runner and selected copies before launch; the child rechecks them
around build and Studio work, allowing only exact owned outputs. Copy and
preflight work stay outside measured workloads. Copies and failed output remain
for audit. Copy roots use ordinary ASCII Windows paths on the source's drive;
external tool pins retain support for UNC paths and spaces. Trusted filesystem
ancestors are still required. The checks do not make the filesystem immutable.
An interrupted comparative study requires a new whole-study collection.

For an interrupted ledger, audit its retained prefix and current input identity
without launching Studio:

```powershell
lune run benchmarks/host/audit-broadcast-recovery.luau --ledger "<study-directory>/ledger.json"
```

The audit checks the frozen schedule, source and tool manifest, archived raw
hashes, duplicate result IDs, and any completed attempt's original result
proof. It lists every retained attempt and returns `selection: "none"` with a
full-study restart requirement. Corrupt or partial evidence fails closed. It
does not verify that an interrupted Studio process or D05 lease has ended.
After the retained attempts have finished and host ownership is clear, start a
linked collection with the same inputs:

```powershell
lune run benchmarks/host/run-broadcast-study.luau --run --studio $studio --recipients 4 --baseline E:/relay-baseline --candidate E:/relay-candidate --restart-ledger "<failed-study-directory>/ledger.json"
```

The driver accepts an interrupted v2, v3 or v4 ledger and validates its complete
history. It requires the same input manifest
and source identities at every link, checks parent hashes, and creates a new
v4 ledger and new verified copies in unique directories. Historical v1-v3
reports retain their live-checkout provenance; metadata cannot upgrade them to
verified-copy evidence. Histories contain at most eight ledgers,
including the original and newest collections; a full history is rejected
before creating another collection or launching Studio.

Earlier ledgers and attempts stay unchanged. Each restart runs the complete
forward and reverse schedule with fresh run IDs that cannot repeat any
ancestor's IDs. An in-flight attempt anywhere in the history blocks restart
because ownership is uncertain. The reporter revalidates the entire history,
but comparisons use only the newest collection's attempts. Repeated invocations
create distinct collections within the history limit. The D05 host lease still
guards each Studio launch. These offline checks do not establish native timing
quality or performance attribution.

Inspect a retained study without launching Studio:

```powershell
lune run benchmarks/reporting/report-broadcast-study.luau --ledger "<study-directory>/ledger.json" --maximum-control-drift 0.05 --output ".tmp/broadcast-report.json"
```

The required drift fraction is an explicit reporting policy; `0.05` is an
example, not a universal promotion threshold. Choose and retain the intended
policy before a new campaign. An old ledger cannot prove when that choice was
made. The output path must be unused, so derived reports cannot overwrite raw
evidence. Omit `--output` for console diagnostics alone.

The reporter rechecks archived hashes/sizes, source pins, exact schedule and
canonical Result V2 compatibility. For v4 it also rechecks retained attempt
receipts and copied result roots, and reports both attribution and execution
roots. It then reports each pass separately, including
median/p95 control drift and candidate differences. Excessive drift is
inconclusive. Even stable controls do not establish a winner, equivalence or an
uncertainty interval from two ordered passes. Thirty within-session windows are
correlated observations; they are not thirty independent Studio launches.

Each metric carries its unit, sample unit, clock, boundary, estimator and
denominator. Public-call elapsed excludes deferred work; frame, drain and
completion boundaries remain separate. Receiver CPU, allocations, isolated
codec cost and physical wire bytes stay unknown without qualified evidence.
Historical revision and engine identities are retained exactly.
Adjacent binary64 rounding differences in old duplicated ledger summaries are
recorded explicitly; the archived raw samples supply the reported summaries.
Larger differences, changed counts, and altered raw hashes still reject evidence.

Each new attempt also records coarse monotonic intervals for preflight, the
whole host command, and archive/validation, including failure status. The host
command emits optional host-side `os.clock` boundaries for the build helper,
Studio launch call, child process through terminal outcome, host teardown, and
total. Total overlaps the other intervals and gaps include host preparation;
do not sum them as a partition. Studio readiness, warmup, workload collection,
and engine drain remain unavailable inside the child-process interval. The
collector retains the bounded diagnostic alongside raw logs even for failed
attempts; the offline report validates successful diagnostics against those logs.
Historical ledgers may omit these fields. Clock faults mark timing unavailable
without changing the primary outcome or raw evidence.

Rehearsal and timing evidence have separate scopes. A passing copied-child
rehearsal does not qualify workload correctness, measurement quality, control
drift, CPU attribution or a comparative result. Keep those gates explicit before
using a canonical campaign for a performance claim.

## Serializer decision gate

The [serializer measurement gate](serializer-gate.md) binds an exact baseline
and candidate to delivery proof, captured network frames, complete sender and
receiver profile accounting, and latency tails. It requires forward/reverse
fresh sessions with unchanged controls. Missing bytes or cost evidence remains
inconclusive; a passing report is eligible for review, not automatic promotion.

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
