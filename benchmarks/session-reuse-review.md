# Persistent-session benchmark optimization

Date: 2026-09-05
Status: QuickNet and Zap passed bounded persistent-session Studio pilots.
The explicit measured integration passes the full portable repository gate and
bounded real measured Studio checks for C2S, multi-client broadcast, and probe.

## Decision

The first optimization should run one fresh Studio multiplayer test session per
**exact adapter, case, and client topology**, with 30 measurement windows inside
that session. Initialize each side's library and receive callback once. Reset
the runner's window evidence, not the library, between windows.

This reduces external Studio launches from 30 to 1 per selection, or 210 to 7
per adapter's seven-selection matrix. It retains 30 measurement-window groups,
but reduces process-level samples from 30 to one. This is not a promise of a
30-fold wall-time speedup: warmup, measured work, and quiet windows still take
time. Do not run another full matrix to develop this path.

Do not initially combine different cases in one session. QuickNet, ByteNet,
Satset, Warp, and Suphi bindings capture a case's packet/schema under fixed
names. Reusing those registrations across different payload schemas needs more
changes than eliminating repeated launches within one selection.

The existing Event V1 process-restart path and its validated result files stay
unchanged. Persistent windows are correlated observations from one warm process,
not 30 independent process restarts. They must not be labeled `ProcessRestart`
or silently compared with old restart-isolated timings. This document does not
approve widening the frozen V1 contracts.

## Why simply looping setup is unsafe

- QuickNet rejects duplicate event registration.
- ByteNet and Satset append packet registrations/listeners without a complete
  removal API.
- Blink and Zap can queue traffic while no callback is installed and replay it
  when a callback is attached.
- Warp and NetRay have useful callback disconnection, but process-lifetime
  queues/schedulers still exist. Warp's known broken Destroy path stays unused.

Therefore keep one physical transport and one continuously installed receiver.
Do not accumulate one vendor callback per measurement window, clone another
library per window, or patch a vendor's private registry/scheduler.

## Ownership and correctness boundary

The physical transport root belongs to the whole selection session. The current
repetition-owned root destruction cannot be reused for that root unchanged.
Each logical measurement window owns its counters, expected fixture range,
timing state, and admission state.

1. Start one fresh Studio test session with its exact participant roster.
2. Prewarm and prove replication/readiness outside timing. Set up one raw
   adapter side and receive callback per participant.
3. Complete the shared-clock readiness and physical proof once for the session,
   as the existing native/Relay whole-case route does. Continue guarding clock
   reads; any clock failure invalidates the session. Do not fabricate a proof
   for each window or loosen the shared-clock bracket.
4. For every window, retain deterministic fixtures, receiver-before-sender
   ordering, warmup, correctness validation, and the required quiet/drain
   boundaries. Keep control traffic out of measured windows.
5. Observe the transport continuously. Global fixture sequence ranges are
   disjoint across repetitions. Any extra, old, future, malformed, duplicate,
   out-of-order, or wrong-sender delivery fails the session; do not drop a late
   callback merely because its window ended or retarget it to the next window.
6. Disconnect once where supported after the final drain. Confirm Studio exit
   as the final cleanup boundary for non-removable library state.

No window identifier is added to adapter payload bytes. A persistent runner
must retain the existing fixture payloads and compare decoded input against its
own expected range. A failed session contributes no successful benchmark result.

## First proof and stop condition

The first executable proof is `tests/external-session-reuse.luau`. It uses
the existing simulated engine world, pinned unmodified libraries, public adapter
bindings, fixtures, and payload comparator. For each of the seven selections,
it creates one world and one adapter side per participant, executes all 30 fixture
windows without reinitialization, then tears down once.

The proof must check payloads, exact order/cardinality, sender attribution,
immediate and deferred input preservation, quiet-window deliveries, and final
teardown. It is untimed simulated-engine evidence only: it does not establish
Studio replication, shared-clock reliability, performance, or Result V1 validity.
Suphi may pass this lifecycle proof while remaining timing-ineligible.

On 2026-09-05, QuickNet, ByteNet, Satset, Warp, Blink, Zap, NetRay-Compile, and
Suphi-Packet all passed: seven selections, 210 windows, and 94,200 checked
deliveries per adapter. No Studio process was launched for this proof.

Run one adapter's proof from the repository root:

```text
lune run benchmarks/tests/external-session-reuse.luau quicknet
```

The warmup-boundary review correction now separates warmup and measured sending
in that simulated proof. Each phase requires completion, 60 quiet frames, and
cumulative cardinality checks. QuickNet and Zap passed the corrected proof;
the earlier eight-adapter result is not a claim that all eight were rerun after
this correction.

## Bounded Studio pilot

`pilot/run-session-reuse.luau` now provides a runnable development path for
QuickNet or Zap, fixed to `state-burst-c2s`, one client, and 30 windows. It reuses
the existing pinned build/launch helpers, adapter operations, exact replication
readiness, deterministic fixtures, payload comparator, and guarded local clock.
No V1 admission or lifecycle identity is widened to make the pilot selectable.

```text
lune run benchmarks/pilot/run-session-reuse.luau --studio <absolute RobloxStudioBeta.exe> --adapter quicknet
```

The pilot owns one physical root and raw adapter side per participant for the
entire selection. A continuously installed server receiver checks the next
expected fixture and exact sender. Malformed, duplicate, old, future, misordered,
or between-phase deliveries latch a permanent bounded failure. Receiver errors
cannot disappear as asynchronous callback exceptions. The client checks fresh
inputs immediately after timed calls, after each sending phase, and after its
final teardown. This send-only C2S pilot does not prove absence of unrelated
inbound client traffic.

Every warmup and measured phase drains and then observes 60 quiet server frames.
Control calls occur outside the sending windows. Side teardown occurs once,
after all 30 windows; confirmed Studio exit is the final physical cleanup proof.
The receiver regression and host collector regression are runnable without Studio:

```text
lune run benchmarks/tests/session-reuse-observer.luau
lune run benchmarks/tests/session-reuse-host.luau
```

On 2026-09-06 UTC, both pilots passed in Studio `0.737.0.7371584`:

| Adapter | Studio launches | Checked windows | Checked deliveries | End-to-end host time |
| --- | ---: | ---: | ---: | ---: |
| QuickNet | 1 | 30 | 2,400 | 70.62 s |
| Zap | 1 | 30 | 2,400 | 60.84 s |

Each window delivered 40 warmup and 40 measured messages. Both participants
initialized once, and the host confirmed no Studio process remained afterward.
These are observed execution times, not library-performance rankings or a paired
speedup measurement against the old restart path.

Pilot evidence is separate ignored `session-reuse-pilot-<launchId>.json`, not
Result V1. It honestly records the dirty development revision, exact composed
place fingerprint, pinned library/artifact, and editor-attested Studio version.
Authenticated output is bounded and validated before publication. Failed
sessions cannot publish a passed artifact. Existing validated results are untouched.

The timing scope is deliberately smaller than a promoted benchmark: local
adapter-call totals and whole sending-phase elapsed time only. Payload checking
is outside adapter-call timing; whole-phase elapsed time also includes frame
waits and input checks and is diagnostic. No cross-participant timestamps are
subtracted, and `sharedClockProof = "NotRun"` and `rankingEligible = false` are
required output fields. Host time outside the server session includes startup
and shutdown, not a separately measured startup duration.

This proves real Studio reuse for the two bounded pilots, not all seven
selections, multi-client reuse, or cross-process statistical independence.
The next integration must preserve a separately reviewed persistent lifecycle
and the applicable readiness/clock/correctness requirements. It must not relabel
these pilots as V1 or restart the full matrix as an iteration test.

## Measured integration and compatibility

`HostRuntime` now accepts explicit `PersistentBenchmark` execution through the
existing Studio coordinator/participant, R1 state/ledger, and R2 control path.
`PersistentTransport` owns one raw side and continuously installed sink per
participant. Each ordinary generation gets a facade and disposable marker;
facade teardown releases only the window sink. Raw calls retain exact arity and
non-yielding checks. Active deliveries reach the existing receipt/ledger edge
unchanged; deliveries between windows permanently fail the session.

Clients close/check the physical owner before their final reports. The server
keeps observing until all client reports arrive, then closes/checks its owner
before freezing evidence. Cleanup destroys the physical root before `EndTest`;
the host also requires confirmed Studio exit before publication. Failure cannot
be converted to a successful session proof.

The separately versioned `HostManifestV2` and `ResultV2` own this closed
`event-session-v1` profile and its required passed session proof. Private schema
implementations are shared with strict V1 wrappers; V1 data and acceptance remain
unchanged. V2 does not accept process-repetition fragments or invent per-window
launch IDs. The optional profile is explicit at adapter preflight and allowlist
admission; legacy defaults do not silently change. Native and Relay use the
same persistent facade, so their new timings must be measured under this profile
before comparison with persistent external results.

Focused contract, transport, runner, host/build, and reporter checks cover the
new path and legacy rejection boundaries. The runtime design/security review
found no static blocker. On 2026-09-06 UTC the integrated path passed bounded
real measured checks: QuickNet `state-burst-c2s` with one client,
QuickNet `state-broadcast-s2c` with four clients, and Zap `tiny-round-trip` with
one client. Each completed 30 windows with clean source at `bb6515f`, valid V2
readback, passed clock/session proof, and confirmed Studio exit. These are three
selection results, not full matrix coverage. Do not use the full matrix for debugging.
Suphi's existing timing rejection is unchanged. The updated goal excludes it
and the optional native baseline: Relay plus seven eligible external adapters,
seven selections each, or 56 selection sessions before failures/retries.

Following that bounded verification, all seven QuickNet and all seven Zap
selections completed with 30 valid windows each and confirmed Studio
exit. Every selection used one fresh session and none needed a retry. Strict
reporter readback validated all 14 V2 artifacts; earlier mixed-version readback
also validated two historical V1 artifacts.
Matching persistent burst/probe rows compare while old restart rows remain
separate. The first V2 runs at `bb6515f` and later runs at documentation-only
`edffc07` share the same measurement fingerprint, so that documentation update
did not invalidate existing measurements. Other persistent matrices are pending.

## Remaining time and machine-condition checks

The 30 windows still repeat their own warmup and two 60-frame quiet periods.
At the contract's target 60 frames/second, those quiet periods alone represent
60 seconds per selection, excluding startup and measured work. This is a frame
budget calculation, not an observed wall-time breakdown. The host only reads
terminal output after child exit; it does not repeatedly launch file-size helpers
during measurement.

An offline first-10-versus-all-30 check reused all 14 saved runs without launching
Studio. The largest absolute median shift was about 23.7%; the largest p95 shift
was about 58.9%. Some early/late groups also differ substantially. This does not
prove thermal drift or establish an independent repeatability bound, and does
not justify silently shortening the measured contract.

The smallest environment correction disables `Players.CharacterAutoLoads` in
the base Rojo place, before any player joins. The benchmark and admitted adapters
do not use characters. Actual base/external place builds now require that setting.
It removes automatic avatar work without changing fixtures or sample counts.
The shared composition fingerprint changes, so old and new environmental cohorts
remain separate. No full-matrix rerun is authorized as the development check.

The bounded live check passed at clean `993a745`: QuickNet's one-client
`state-burst-c2s` completed all 30 windows, with 1,200 correct measured deliveries,
zero missing deliveries, passed clock/session proof, and confirmed Studio exit.
Host elapsed time was 50.2 seconds, versus an earlier 105.6-second avatar-enabled
observation. Within the new run, the first-10-window median differed from the
all-30 median by about -0.5%, and the last-10 median differed from the first 10
by about +2.7%. These are one run's observations, not an independent
repeatability test, proof of CPU/GPU stability, or evidence of a causal speedup.
They do not yet justify reducing the sample count. Strict reporter readback
accepted the new result and kept it separate from the old environment. The new
avatar-free cohort initially contained this one selection; the previous 14 valid
results remain historical evidence, not completed rows in the new cohort.

## Frozen collection, 2026-09-07

The requested burst repeat and four-client QuickNet broadcast checks passed at
clean `fd494d1`. The repeat took 53.8 seconds and had a 4.19125 ms median, versus
the earlier avatar-free run's 50.2 seconds and 4.16650 ms median (about 0.6%
apart). Its p95 differed more; these two observations do not establish stable
CPU/GPU conditions. The four-client check took 97.8 seconds. No setup changes
were made before continuing collection, and matching saved cells were reused.

The frozen cohort now has 34 valid V2 files covering 33 of 56 combinations:
all eight libraries passed the four one-client workloads, and QuickNet also
passed four-client broadcast. One additional file is the deliberate burst repeat.
All 34 have 30 completed windows, clean source, passed clock/session proof, and
111,600 correct expected deliveries in total with none missing. Strict reporter
readback validated these 34 files plus 14 historical V2 and two historical V1
files, with incompatible setups and execution methods kept separate.

This collection turn used 39 session attempts (33 new valid files and six
no-result terminations), totaling 43 minutes 24 seconds of summed host-command
time, excluding analysis/reporting and the earlier saved run. Collection stopped
at Relay's four-client broadcast after its first attempt and sole retry both
failed the formal clock check before measured traffic, about 39 seconds each.
Both server logs report `RelayBenchmark.ClockFailure ClockReply`; the rejecting
branch in `ControlProtocol.luau` accepts neither a rejected server clock sample
nor a client timestamp outside the server challenge/reply bracket. The logs do
not contain the values needed to distinguish those possibilities or attribute a
CPU/GPU cause. This is not evidence of a Relay payload-correctness failure.

Twenty-three combinations remain. Studio fully exited and no further selection,
harness change, or vendor repair was attempted after the repeated failure. The
33 completed combinations remain reusable under the unchanged setup. Establish
the cause and compatibility impact before changing the shared clock gate; a
future shared-harness change must not silently relabel these results.

A subsequent single [untimed clock diagnostic](diagnostics/clock/README.md)
completed in 44.94 seconds at clean `a9ffd9a` and stopped before warmup. All four
formal replies passed, so the earlier formal failure was not reproduced. Two
readiness replies had client timestamps 2.133 ms and 2.180 ms beyond the server
receipt-time sample; the existing readiness loop recovered. This is observed
transient clock disagreement, not proof of the earlier numerical cause or
CPU/GPU causation. The measured harness, frozen fingerprint, and all saved
results are unchanged. No measured result or additional selection was collected.

## Avoid unrelated reruns

V2 keeps Git revision and dirty status as provenance and additionally carries
a common measurement-harness fingerprint. Comparison compatibility uses that
fingerprint, contract, lifecycle, selection, and
environment rather than whole-repository revision equality.

The common fingerprint must cover measurement-reachable shared code and
configuration with a versioned, sorted, length-framed content manifest. Adapter,
vendor, and generated-library bytes remain separately fingerprinted. The full
place fingerprint is not a common comparison key because its adapter bytes
intentionally differ between libraries. Unclassified measurement dependencies
must not silently disappear from the common fingerprint.

Consequences: documentation/report presentation changes need no measurement
rerun; an adapter-only change affects that adapter's evidence; a shared timing
or workload change affects every result that depends on it. Preserve old results
as historical evidence. Do not rewrite old metadata to claim fingerprints or
isolation evidence that were never recorded.

## Persistent clock admission, 2026-09-07

Decision: zero-margin distributed startup admission is unnecessarily strict for
Roblox's smoothed approximate shared clock. The diagnostic reproduced a formal
rejection 0.279 ms beyond the receipt-time sample. Three separate fixed-3-ms
candidate sessions then accepted all 12 formal replies, including zero-margin
misses of 0.914 and 2.704 ms. This supports a provisional allowance, not an
optimum, a 3 ms clock-error bound, or a paired speedup claim.

The measured persistent profile now uses a fixed 3 ms allowance for the two
startup bracket comparisons: readiness and the formal challenge. The trusted
coordinator accepts only an exact `PersistentSession` execution descriptor; no
client field or arbitrary tolerance config selects it. Legacy Benchmark and
ProcessRepetition retain zero allowance. Packet shape, sender attribution,
sequence/replay checks, deadlines, finite/nonnegative/nondecreasing server reads,
participant-local proof, correctness, and all 30 windows are unchanged. There is
no fixed settling sleep. The dedicated read-only design/security review found
no blocker to this narrow change; same-participant TimingRecorder bracketing
remains strict. Shared durations remain EngineApproximation/DiagnosticOnly;
ranking durations still subtract same-participant `os.clock()` timestamps.

Profile/schema IDs and versions stay unchanged so historical V2 files remain
readable. Changed profile bytes and measured runner bytes produce new contract
and common measurement fingerprints, separating the new cohort from all old
results. All 56 selections are affected and must be recollected under frozen,
clean source. The old 33-selection cohort and its deliberate repeat remain
historical, without rewriting or deletion. First validate the formerly failing
multi-client and round-trip paths; then collect only missing compatible cells,
one selection session at a time. The existing reporter must read exactly one
validated file per cell, with no overall winner score. Review reproducibility
and claim limits before any external publication.

## Completed clock-admission cohort, 2026-09-07

All 56 selections passed at clean `4ce556e7ddc5473673b6a8225144bade9e2c2967`:
seven each for Relay, QuickNet, ByteNet, Satset, Warp, Blink, Zap and
NetRay-Compile. Each valid Result V2 contains 30 completed windows and passed
clock/session proof. The 48 workload results have 441,600 correct expected
deliveries with no delivery errors; eight separate round-trip results also
validate. The common measurement fingerprint is
`sha256:b105d421679317555c954f1417f44e3ca41b5f9d283d0c4e5ccb451243615237`,
and the contract fingerprint is
`sha256:9a297149156601043b8999b5ca048421f023e802c6269ecb3dde5b9e1989c78f`.
The existing reporter read exactly those 56 validated files into 14 separate
case/topology/broadcast-mode groups, without pooled samples or an overall score.
The final audit confirmed unique complete coverage, provenance, result hashes,
all 77 pre-existing JSON artifacts unchanged (including 69 older results), and
Studio shutdown. Dependency/generated pins and the required foundation gate pass.

There were 57 measured attempts and no clock rejection. One Zap four-client
broadcast candidate failed host summary validation: its diagnostic-only drain
median differed from recomputation by two binary64 steps, beyond the reader's
one-step allowance. Its first unchanged-source retry passed; the rejected log
remains separate and no result was repaired or schema rule relaxed. The precise
arithmetic/serialization cause remains unresolved. Raw authenticated logs stay
private. All other selections completed on their first attempt.

Host commands totaled 85 minutes 43 seconds, not end-to-end elapsed time or a
paired speedup. Two collection blocks span 16 hours 55 minutes 43 seconds, with
a 15-hour-28-minute pause before that Zap retry. Recorded machine/tool identities
match before/after; continuous load/thermal stability remains unproven. These
are descriptive local Studio comparisons, not independent 30-process samples,
a clock-accuracy guarantee, production/internet latency, or general superiority
claims. No further measured runs are needed for the approved matrix, and nothing
has been published externally. The ignored completed report, audit and claims
review are in `benchmarks/results/local/` with prefix
`comparison-clock-admission-2026-09-07` / `audit-clock-admission-2026-09-07`.

## Research and review

Launches and measured iterations are distinct controls in
[BenchmarkDotNet](https://benchmarkdotnet.org/articles/guides/choosing-run-strategy.html)
and [pyperf](https://pyperf.readthedocs.io/en/stable/runner.html). These sources
support separating startup cost from repeated measurements, not a claim that
one launch always characterizes cross-process variance. Roblox's
[StudioTestService](https://create.roblox.com/docs/reference/engine/classes/StudioTestService)
provides a multiplayer test-session boundary with explicit completion.

The local lifecycle and runner reviews agree on per-selection persistent
transport as the smallest useful direction. The security/design review rejects
an allowlist-only relabeling of Event V1 and requires continuously observed,
sequence-checked windows and separate persistent-session evidence before
measured promotion. No production transport, decoder, or downloaded source is
changed by this feasibility stage.
