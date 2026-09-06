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
Suphi's existing timing rejection is unchanged and remains an unresolved part
of the original all-eight measured goal, not a successful measurement.

Following that bounded verification, all seven QuickNet selections and Zap's
burst/probe selections completed with 30 valid windows each and confirmed Studio
exit. Every selection used one fresh session and none needed a retry. Strict
reporter readback validated all nine V2 artifacts and two historical V1 artifacts;
matching persistent burst/probe rows compare while old restart rows remain
separate. The first V2 runs at `bb6515f` and later runs at documentation-only
`edffc07` share the same measurement fingerprint, so that documentation update
did not invalidate existing measurements. Other persistent matrices are pending.

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
