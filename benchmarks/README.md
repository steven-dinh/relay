# Relay Benchmarks

This directory contains the deterministic Event V1 contracts, fixtures,
correctness tooling, pure R1 runner, pure R2 control validator, Plan 4 Studio
control path, and authenticated loopback collector for neutral comparisons
between Relay and other Roblox networking libraries. The focused R3/R4 proofs
and live 1/4/8-client ControlProof matrix pass, completing the Plan 4 exit gate.
A real native adapter remains Plan 5 work. No competitors or benchmark results
are included yet.

Benchmark implementations and future execution slices must follow these rules:

- prove correctness before ranking performance;
- use deterministic fixtures;
- keep setup and dependency loading outside timed regions;
- provide equivalent-semantics and native-best lanes when features differ;
- measure real wall time;
- pin exact dependency revisions;
- keep downloaded source, generated code, and local results untracked.

Correctness tests remain separate from timing and never fail because of timing variance.

## Event-v1 execution contract

Each workload names its audience directly. Client-to-server submissions target
`Server`; the server-to-client workload targets `Broadcast`. Targeted
server-to-client delivery is not part of event-v1.

The reproducible event-v1 execution profile requires Studio multiplayer through
`StudioTestService:ExecuteMultiplayerTestAsync`. Roblox supports at most eight
clients through that API, so the broadcast variants are 1, 4, and 8 clients.
A 20-client result must not be presented as event-v1 unless a separate,
reproducible execution profile is specified later.

The Plan 4/5 server path passes the completed serializable value to
`StudioTestService:EndTest`. The secret-free RunScript bootstrap receives that
value from `ExecuteMultiplayerTestAsync`, JSON-encodes it, and sends it to the
authenticated host collector over IPv4 loopback. Result extraction happens
after all timed work; ControlProof validates its fixed wrapper and writes no
result.

Quiescence means 60 consecutive `PostSimulation` frames with no workload
delivery. Any relevant delivery restarts the count. This untimed window runs
after warmup has drained and again after measured deliveries have been verified;
the second window catches late, duplicate, stale, or unexpected callbacks.

`maximumAddedDeliveryFrames = 1` limits only intentional sender-side buffering
or flush scheduling before the library hands work to Roblox transport. It does
not limit Roblox transport latency, internet latency, or receiver scheduling.
An implementation that intentionally buffers for more than one frame cannot
claim the equivalent-semantics lane.

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
- `submissionDuration`: sender-local `os.clock()` from immediately before the
  first measured adapter operation until immediately after the final measured
  adapter operation returns;
- `completionDuration`: shared-clock time from the first measured submission
  start until the final expected delivery is received;
- `drainDuration`: shared-clock time from the final measured submission return
  until the final expected delivery is received;
- `wallDuration`: shared-clock time from the first measured submission start
  until the final expected delivery passes payload, order, and count checks;
- `submitCallDuration`: sender-local `os.clock()` immediately around each
  `AdapterContract` submit or broadcast operation, reported in microseconds per
  event. It measures blocking elapsed time, not CPU utilization;
- `roundTripLatency`: client-local `os.clock()` around one non-pipelined tiny
  client-to-server submission and its matching one-client broadcast echo.

Receipt timestamps are captured before correctness verification. Verification
work is included only in `wallDuration`; setup, warmup, quiescence, and result
extraction stay outside every timing window.

The measured submit and round-trip start marks sit at the raw adapter-operation
edge inside the non-yielding call boundary. Each submit finish mark is
immediately after that operation returns. Runner state transitions,
containment/resume bookkeeping, and clock-call machinery stay outside the
elapsed delta. Selected-field extraction, the adapter/library operation, and
any final-in-frame `FlushBeforeReturn` work remain inside it. The shared first
submission endpoint is attempt-owned: merely arming measured work records no
endpoint, the first attempted operation records the first endpoint even if it
fails, and the final endpoint exists only after the final planned operation
returns.

`engineDataSendRate` samples sender-side `Stats.DataSendKbps` once per measured
frame. Despite the property name, Roblox documents its value as approximate
kilobytes per second for all data sent by the current instance. It is therefore
an optional diagnostic, not remote-only wire bytes, and no background-rate
subtraction is allowed. Runner control traffic is forbidden during measured
frames.
