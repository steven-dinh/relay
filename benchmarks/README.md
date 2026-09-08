# Relay Benchmarks

This directory contains Event V1 contracts, deterministic fixtures, correctness
checks, the Studio runner, native/Relay/external adapters, and the local result
reporter. Seven external bindings are eligible for measured runs; Suphi-Packet
remains rejected because its sender-frame bound cannot be proven. See
[the adapter guide](adapters/README.md) for pinned bindings and qualification.
Downloaded source, generated runtimes, and local results are not committed.

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

## External library placement

`benchmarks/libraries.lock.json` pins the five runtime-source candidates and the
three Windows code-generation tools used by external benchmark lanes. Run the
acquisition from the repository root:

```text
lune run scripts/acquire-benchmark-libraries.luau --all
```

Final artifacts are written only beneath ignored `benchmarks/vendor/<id>/`
paths; acquisition scratch stays under ignored `.tmp/benchmark-library-acquisition/`
and `benchmarks/vendor/.staging-<id>`. The command resolves each tag to its
tracked commit, fetches exact Git revisions for QuickNet, Satset, Warp, ByteNet,
and Suphi-Packet, and streams the three Windows tool archives through `curl` with
HTTPS-only redirects, a fixed transfer deadline, and exact byte-count limits
before verifying their hashes and extracting Zap, Blink, and NetRay-Compile.
Existing vendor directories are never overwritten;
they must pass the offline byte verification or acquisition stops. Ordinary
failures clean scratch paths created by that invocation.

Use `--verify` for an offline verification pass. After acquisition,
`benchmarks/external-runtime-libraries.project.json` is the opt-in Rojo project
for checking that all five runtime package roots load. The ordinary
`event-v1.project.json` intentionally remains independent of external files.
Generate the three compiler-backed runtimes from their tracked schemas with
`lune run scripts/generate-benchmark-adapters.luau --all`; the command verifies
the selected compiler and requires deterministic output. Suphi-Packet's source
mirror has no repository license file. Relay records the original
author's published permission grant as the custom
`LicenseRef-Suphi-Packet-Grant`; it is not mislabeled as 0BSD or ISC because the
published text omits their required disclaimer or conditions.

## Persistent-session measured path

Use the existing host with `--mode PersistentBenchmark` to run all 30 windows
of one exact adapter/case/topology in **one fresh Studio multiplayer session**:

```text
lune run benchmarks/host/run-event-v1.luau --studio <absolute RobloxStudioBeta.exe> --mode PersistentBenchmark --case state-burst-c2s --recipients 1 --adapter quicknet
```

This mode admits native, Relay, and the same seven eligible external adapters.
It keeps each participant's physical library, transport root, and receiver alive
across windows; only window-local evidence and generation markers restart.
Continuous observation rejects deliveries between windows, and final physical
cleanup must pass before publication. Replication/readiness, receiver ordering,
shared-clock proof, deterministic fixtures, input checks, and quiet windows
remain required and setup stays outside timing.

The host writes validated `.result-v2.json` with the `event-session-v1` profile
and `PersistentSession` isolation. Thirty windows in one process are not thirty
independent process samples; do not pool them with legacy restart results.
This mode requires clean Git and exact selected artifacts before and after
execution, and confirmed Studio exit. The full place and Git revision remain
provenance; separate measurement and adapter fingerprints avoid rerunning
unaffected measurements after documentation, reporting, or adapter-only changes.

Each session has a fixed case and roster. Different cases are not combined:
several libraries register case-specific packet schemas under fixed names.
The runner does not reinitialize a library, accumulate callbacks, or edit vendor
registries between windows. Disjoint fixture sequence ranges detect old or
future deliveries without adding window IDs to payload bytes.

Clients close/check their physical owners before final reports. The server
continues observing until those reports arrive, then closes/checks its owner
before freezing evidence. Cleanup failure cannot become a passed session proof.
Process exit remains the final boundary for non-removable library state.

The benchmark place disables automatic character loading. These fixtures need
Player identities, not avatars, asset loading, or character physics. Build
checks enforce that setting. Thirty windows and both quiet-window requirements
remain part of the profile; fewer windows are not interchangeable evidence.

Use a focused test or one affected selection for development. Run a complete
matrix only after the measured setup is frozen. Documentation/reporting changes
need validation, not fresh Studio measurements. Shared measured-code changes
create a new measurement cohort; adapter-only changes affect that adapter's
evidence. Never relabel old results to match changed source.

## Development checks

The simulated-engine reuse check exercises one pinned adapter without Studio:

```text
lune run benchmarks/tests/external-session-reuse.luau quicknet
```

The bounded Studio lifecycle pilot accepts only QuickNet or Zap, fixed to
`state-burst-c2s`, one client, and 30 windows in one session:

```text
lune run benchmarks/pilot/run-session-reuse.luau --studio <absolute RobloxStudioBeta.exe> --adapter quicknet
```

It checks selected server receipts, input preservation, and warmup/measured
quiet boundaries, with one initialization per side. Output records development
provenance and is explicitly non-ranking pilot evidence, not Result V1 or V2.
It does not establish shared-clock proof, other selections, or absence of
unrelated inbound client traffic.

## Legacy process-restart external path

This route starts **30 Studio multiplayer sessions per external selection** and
produces Result V1 with `ProcessRestart` isolation. Use the persistent mode above
for the one-session profile; the two profiles are not interchangeable.

On Windows, select QuickNet, ByteNet, Satset, Warp, Blink, Zap, or
NetRay-Compile with the ordinary Benchmark command, for example:

```text
lune run benchmarks/host/run-event-v1.luau --studio <absolute RobloxStudioBeta.exe> --mode Benchmark --case state-burst-c2s --recipients 1 --adapter quicknet
```

The external route first requires clean Git source and exact installed vendor
and generated-output verification. It creates an ignored Rojo project with HTTP
disabled and only the selected binding, library, optional Warp endpoint, and
generated runtime. The exact composed bytes are fingerprinted and reused for
the selection.

Each of the 30 logical repetitions receives its own launch UUID, capability,
Studio multiplayer process group, and exact `RepetitionFragmentV1`. The host
accepts a fragment only after bounded authenticated decoding and exact
launch/batch/index/manifest validation, then proves no Studio process remains
before cleanup or the next launch. It aggregates only a complete ordered set of
30 fragments, validates one final Result V1, re-verifies ignored artifacts and
the clean Git revision, and publishes once by no-overwrite move. Runs must remain
serial because the Studio idle census is deliberately conservative but not an
atomic system-wide lock.

Adapter-specific module prewarm and replicated remote, attribute, namespace, or
generated-endpoint readiness run before non-yielding adapter setup and outside
timing. The existing fixtures, receiver-before-sender warmup, correctness
ledger, quiet windows, clock proof, measurement boundaries, teardown
observation, and final evidence checks remain in force. A fragment or partial
batch is not a comparison input, and the host never synthesizes missing evidence.

If a Studio run terminates without a Result, its server log includes a
`RelayBenchmark.Termination` call stack. Clock failures also log
`RelayBenchmark.ClockFailure` with the active control barrier. These failure-only
diagnostics do not change the termination envelope or admit a failed batch.

`--adapter suphi-packet` fails with
`HOST_E_EXTERNAL_UNSUPPORTED_SUPHI_FRAME_BOUND`. Its networking path exports no
flush and can intentionally cross more than Event V1's one permitted sender
frame; the host does not manufacture an eligible identity or result.

## Native path and selection matrix

The native binding,
`benchmarks/adapters/native-reliable/init.luau`, is a benchmark-only adapter over
Roblox `RemoteEvent`. The allowlist accepts the exact full native identity for
the running Studio version or the host-pinned exact Relay identity. Native readiness caches its
remote and validates the exact participant roster before measured submission or
broadcast; those checks are not charged to an adapter operation.

Warmup and measured startup preserve receiver-before-sender ordering. Before
S2C warmup, each exact-roster client acknowledges that its local delivery gate
and warmup ledger are armed; only then does the server begin sending.
For measured S2C broadcast,
each exact-roster client first reaches its local `Measured` phase and then sends
one bounded two-field acknowledgement for the current repetition; the server
waits for the complete roster and closes that acknowledgement gate before it
arms the S2C sender. For C2S workloads and the round-trip probe, the server
receiver is armed and crosses a `PostSimulation` boundary before client senders
are armed. Measured-completion reports remain closed until that directional arm
sequence has completed.

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

The `relay-reliable` binding uses the public Relay API with definitions,
connections, and session startup outside measured operations. Select it with
`--adapter relay-reliable` on the existing host command; omitting the option
keeps the native baseline. It maps C2S submit to public `Send` and S2C broadcast
to public `Broadcast`, with public `Destroy` at the selected profile's physical
cleanup boundary and zero intentional added frames. All production validation and handler limits remain
enabled. The predeclared rate profile uses per-player capacity 4096/refill 2048
per second and aggregate capacity 32768/refill 16384 per second. This is a
benchmark profile inside Relay's hard ceilings, not a recommended game default.

Relay results bind the Git revision and exact production ModuleScript source
checksum from the built place. The existing place fingerprint also covers the
adapter and harness. The host inserts the same exact binding for server and
client allowlist checks; it does not label dirty source as clean. The adapter
adds no private runtime switch and does not move Relay's production transport
under the benchmark generation root.

The adapter's presence alone establishes no comparative performance result.
Only validated, reproducible Result V1 or V2 artifacts in matching comparison
groups can support a comparison with another eligible adapter.

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

The server passes a completed serializable result, legacy repetition fragment,
or bounded termination to `StudioTestService:EndTest`, according to the launch mode. The secret-free RunScript bootstrap accepts the
resulting Benchmark JSON, or encodes its own bounded fallback termination, then
emits one authenticated begin/chunk/end sequence through Studio's output file.
Payload chunks are hex-encoded from at most 1 KiB of input, keeping every frame
line below 4 KiB. After Studio exits cleanly, the host checks the unique output
file's 20 MiB ceiling before reading it, requires an exact ordered sequence, and
reconstructs at most the Result V1/V2 8 MiB JSON limit. Result extraction happens
after all timed work. ControlProof validates the same fixed wrapper and writes no
benchmark result.
The command reports success only for a `Valid` benchmark Result. Authenticated,
schema-valid `Invalid`, `Error`, or `Unsupported` Results are retained for
diagnosis and make the command fail with their status. Missing or malformed
command-line arguments also fail instead of silently skipping the launch.
If the host has to kill Studio, it returns `HOST_E_CHILD_LIVE` and retains the
private launch files: Lune's kill status does not prove that the OS process or
its descendants have exited. Check those processes before starting another
timed run.

Run Studio tests serially. The launcher rejects an already-running Studio
process with `HOST_E_STUDIO_BUSY`, because multiplayer tests share Studio's
`server.rbxl` quick-save file. The read-only check cannot prevent another
launcher or manual Studio session from starting immediately afterward.

Every launch uses a unique ignored Rojo build. The place fingerprint is the
SHA-256 of the exact Rojo-produced place bytes before `LaunchCarrier` insertion.
The collector uses independent Studio-version attestation from the authenticated
bootstrap frame, rather than trusting a version reported inside the result, and
publishes only a fully validated terminal Result.

The local OS account and operator-selected Studio executable are trusted.
The capability excludes benchmark scripts that cannot read the destroyed
server-only carrier; it does not defend against a same-user process that can
read private launch files. Keep authenticated logs and launch files private.
A correctness-valid result is not a malicious-input decoder audit, a license
certification, or general production-security approval.

Quiescence means 60 consecutive `PostSimulation` frames with no workload
delivery. Any relevant delivery restarts the count. This untimed window runs
after warmup has drained and again after measured deliveries have been verified;
the second window catches late, duplicate, stale, or unexpected callbacks.
The receiver observation budget applies across the entire case, so duplicate
traffic concentrated in one repetition remains reportable. Final evidence
separately bounds first receipts by the repetition's fixture count and requires
overflow claims to exhaust the case budget in the final started repetition.

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

After participant readiness, the Studio runner requires two consecutive
full-roster shared-clock samples inside server-recorded before/after brackets.
`PersistentBenchmark` admits a fixed 3 ms allowance on either side of each
bracket, for both readiness and the following formal challenge. Legacy
`Benchmark`/`ProcessRepetition` retains zero allowance. This is startup admission
for an approximate engine clock, not calibration or a 3 ms accuracy guarantee;
finite, nonnegative, nondecreasing and participant-local clock checks remain
strict. The margin is a provisional startup-admission choice supported by local
diagnostics, not a demonstrated optimal tolerance or clock-error bound.
These untimed convergence probes are bounded to 120 attempts by the active
readiness deadline and create no benchmark evidence. Only the following single
clock challenge supplies the admission proof used by the run; any failure of
that proof remains fatal. Shared-clock diagnostic durations are not rankings.

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

Completion and drain diagnostics clamp negative cross-clock differences to zero.
Drain can be zero when final delivery precedes the final submission return;
completion instead compares final delivery against the first submission start.
These diagnostic adjustments do not affect ranking eligibility.

The distributed round-trip probe applies a local 120-second response deadline
and the original 7,200-second whole-case deadline. The 150-second control wait
does not limit the entire set of sequential probe samples. A local expiry uses
the existing abort path; when the coordinator cannot establish a causal failure
fact, cleanup ends with a bounded no-Result termination.

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

Compare two or more local Result V1 or V2 files with repeated `--result` arguments:

```text
lune run benchmarks/reporting/compare-results.luau --result <first.result-v1.json> --result <second.result-v1.json>
```

The reporter requires ordinary files no larger than the result schema's ceiling,
performs bounded JSON preflight and complete version-specific validation, rejects dirty
source provenance and duplicate run IDs, and keeps every run as its own row.
Matching strata are further separated by result/profile version, isolation,
contract fingerprint, Studio version/channel, host, and execution topology.
V1 uses benchmark revision for source compatibility; V2 uses the common
measurement fingerprint, not the intentionally different adapter or full-place
bytes. Old metadata is never rewritten to infer missing evidence.
Non-`Valid` evidence is shown before timing rows and never receives a timing
comparison.

The reporter recomputes summaries from raw samples. Both versions allow only
one adjacent binary64 value for an even-count median's serialization difference;
other summary values must match exactly. Failed validation is not repaired.

Thirty windows in one session are correlated observations, not independent
process samples. Record collection order, retries, pauses, and machine conditions
with local evidence before publishing comparisons. A hardware/software identity
snapshot does not establish stable CPU/GPU load or temperature. Local Studio
results do not establish production internet performance, and unpaired startup
observations do not establish a repeatable speedup.
