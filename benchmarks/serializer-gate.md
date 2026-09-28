# Serializer measurement gate

Use this offline gate before proposing a custom serializer. It extracts delivery,
throughput, API-call and latency measurements from canonical Result V2 files,
decodes captured packet lengths with TShark, and evaluates reviewed sender and
receiver profile accounting. It does not create a serializer, launch Studio,
capture packets, or automate MicroProfiler accounting. Missing evidence returns
`Inconclusive`; a complete failing comparison returns `Reject`. A complete pass
is only `EligibleForReview`, never permission to change Relay's transport.

The previous buffer prototype remains unpromoted. Its 8/26-byte buffer lengths
were not wire measurements, and its RTT p95 regression exceeded its +10% gate.

## Prepare the exact implementations

Run from the repository root, using an unused ignored output directory:

```powershell
lune run benchmarks/host/run-serializer-gate.luau --init .tmp/serializer-gate
```

This creates a **draft** baseline plan, a snapshot place, and an empty ordered
evidence schedule. It accepts the current dirty source for planning, recording
that fact. It cannot qualify dirty canonical results or a missing candidate.
Once the baseline and isolated candidate are ready, create a new study:

```powershell
lune run benchmarks/host/run-serializer-gate.luau --init E:/relay/.tmp/serializer-study E:/relay-baseline E:/relay-candidate
```

The existing host fingerprints the exact Relay module tree and adapter binding;
the shared measurement fingerprint pins the harness, canonical host entrypoint,
host source dependencies, and library lock. The saved place also has a SHA-256
and size. Measurements must match these pins, including all candidate changes.
Commit/revision changes require a new plan. Regenerate plans made before host
dependencies were included in the fingerprint. Do not substitute the old
buffer prototype, a toy encode/decode loop, or a differently instrumented build.
Any necessary instrumentation must be present and identical in both planned
harnesses before collection. No production source is patched by this tool.

Predeclare thresholds before collecting. Defaults are deliberately conservative:

| Requirement | Default |
| --- | --- |
| Captured connection bytes per verified delivered message | At least 15% lower, in each workload and pass |
| Sender/receiver window cost median and p95 | At most 5% regression |
| Workload drain and separate RTT p95/p99 | At most 10% regression |
| Delivered messages per completion second | At most 5% regression |
| Unchanged baseline/control variation, every metric | At most 5% |

If you edit a draft plan, replace `evidence.json.planSha256` with its new hash
**before any collection**. Each session and supplement binds that same hash.
The hashes detect later mismatches; they do not independently prove when an
operator made a declaration. Preserve the dated declaration with the study.

## Collect the scheduled observations

Each of the following has six fresh, serial Studio sessions: baseline, unchanged
control, candidate; then candidate, unchanged control, baseline. Retain every
attempt, including failures. Stop on failure; do not retry for favorable numbers.
Thirty windows in a session are not thirty independent process trials.

| Case | Clients | Latency measurement |
| --- | ---: | --- |
| `state-burst-c2s` | 1 | Per-window final-submission-to-final-delivery drain |
| `state-broadcast-s2c` | 8 | Per-window broadcast drain, all recipients |
| `tiny-round-trip` | 1 | Individual Tiny request/echo RTT, separate probe |

Reuse the canonical host in the pinned checkout for each scheduled session:

```powershell
lune run benchmarks/host/run-event-v1.luau --studio $studio --mode PersistentBenchmark --case state-burst-c2s --recipients 1 --adapter relay-reliable
lune run benchmarks/host/run-event-v1.luau --studio $studio --mode PersistentBenchmark --case state-broadcast-s2c --recipients 8 --adapter relay-reliable
lune run benchmarks/host/run-event-v1.luau --studio $studio --mode PersistentBenchmark --case tiny-round-trip --recipients 1 --adapter relay-reliable
```

Run those commands in the declared per-case order, not as three concurrent jobs.
Keep the engine version, host, frame cap, topology, semantics, profile, and
measurement code fixed. Record machine load throughout measurement, engine and
network simulation settings, process identities, and competing work. The
`environmentReview` below retains that audit; these facts are not all present in
Result V2. An unchanged control outside tolerance makes the study inconclusive.

For workload sessions, also retain a complete packet capture and sender/receiver
MicroProfiler traces from **those same sessions**. The existing canonical host
does not collect these supplemental artifacts. A callback-only quick profile is
insufficient: the gate requires native serialization/deserialization plus Lua
encoding/decoding and dispatch. Qualify capture and profiler boundaries before
launching a full matrix; inability to establish them is an inconclusive result.

## Attach evidence

`--hash <file>` prints `{path, sha256, size}`. Use that object for every artifact
reference. Paths may be absolute or relative to the study directory. Retain raw
files; changing one causes evaluation to fail. JSON inputs use the canonical
result size bound; other individual artifacts are limited to 128 MiB.

Fill each existing `evidence.json.entries` slot without reordering it:

```json
{
  "caseId": "state-burst-c2s", "pass": 1, "role": "baseline",
  "result": {"path": "run.result-v2.json", "sha256": "sha256:...", "size": 123},
  "session": {
    "planSha256": "sha256:...", "startedUnix": 1000, "finishedUnix": 1100,
    "hostLog": {"path": "host.log", "sha256": "sha256:...", "size": 123},
    "environmentReview": {"path": "environment.md", "sha256": "sha256:...", "size": 123}
  },
  "supplement": {"path": "run.supplement.json", "sha256": "sha256:...", "size": 123}
}
```

Examples here are shape illustrations, not usable measurements. RTT entries need
the result and session receipt but no workload supplement. A workload supplement
has this structure (expand each `windows` array to all 30 measured windows):

```json
{
  "schema": "Relay.SerializerSupplement", "version": 1, "planSha256": "sha256:...",
  "sender": {
    "runId": "...", "adapterFingerprint": "sha256:...", "measurementFingerprint": "sha256:...",
    "scope": "send-through-engine-serialization", "unit": "microsecondsPerSubmissionWindowMean",
    "rawProfile": {"path": "server-profile.html", "sha256": "sha256:...", "size": 123},
    "accountingReview": {"path": "sender-accounting.md", "sha256": "sha256:...", "size": 123},
    "participants": [{"index": 1, "windows": [{"messages": 120, "totalMicroseconds": 2400}]}]
  },
  "receiver": {
    "runId": "...", "adapterFingerprint": "sha256:...", "measurementFingerprint": "sha256:...",
    "scope": "engine-deserialization-through-dispatch", "unit": "microsecondsPerDeliveryWindowMean",
    "rawProfile": {"path": "receiver-profiles.zip", "sha256": "sha256:...", "size": 123},
    "accountingReview": {"path": "receiver-accounting.md", "sha256": "sha256:...", "size": 123},
    "participants": [{"index": 1, "windows": [{"messages": 120, "totalMicroseconds": 1200}]}]
  },
  "network": {
    "runId": "...", "adapterFingerprint": "sha256:...", "measurementFingerprint": "sha256:...",
    "scope": "isolated-connection-bidirectional", "layer": "captured-frame",
    "captureComplete": true, "droppedPackets": 0,
    "decoderSha256": "sha256:...", "connections": [{"participantIndex": 1, "udpStream": 0}],
    "capture": {"path": "traffic.pcapng", "sha256": "sha256:...", "size": 123},
    "boundaryEvidence": {"path": "capture-boundaries.json", "sha256": "sha256:...", "size": 123},
    "accountingReview": {"path": "network-accounting.md", "sha256": "sha256:...", "size": 123},
    "windows": [{"startUnix": 1020, "finishUnix": 1022, "delivered": 120}]
  }
}
```

Profile accounting must identify actual trace scopes and measured windows,
exclude setup/warmup/control work, include deferred codec work, avoid adding
nested inclusive durations twice, and document instrumentation overhead and
any yields. Include every receiver separately (all eight for broadcast); package
their raw traces in one retained archive if needed. Use the same accounting
method on both implementations. `messages` must match verified submissions for
the sender and verified deliveries per receiver for the receiver. Callback-only
or script-only costs cannot satisfy the stated scopes. Review artifacts are
human evidence: this tool hashes them but cannot interpret or certify their
claims. `EligibleForReview` still requires that audit.

Network accounting must identify the actual UDP connection(s), capture point,
loss/drop counters, complete measured send-through-drain intervals, and how
local measurement clocks map to capture Unix timestamps. List the capture-local
TShark `udp.stream` ID for each participant (all eight for broadcast); the tool
constructs the union filter and requires every listed stream in every window.
The boundary review must map these IDs to actual participant endpoints. Capture
both directions at **one endpoint/interface** and all broadcast connections.
Include ACKs and retransmissions once. Prove separation from control, unrelated
replication and other processes; inseparable traffic cannot pass as attributable
serializer savings. Denominators cover precisely the retained windows, never
the whole run divided into a short profiler dump. The CLI re-decodes the pinned
capture with the pinned TShark executable rather than trusting entered byte totals.

`frame.len` is actual captured-frame accounting, including the headers exposed
by that link type. It is not compressed payload size, Ethernet preamble/FCS
accounting, or proof of physical WAN traffic for a loopback capture. Preserve
that distinction in decisions; compare matching encapsulations. No idle-rate
subtraction, `buffer.len`, integrated `DataSendKbps`, or profiler HTML file size
can replace these bytes. Duplicate frames, mixed interfaces, truncated packets,
overlapping windows, missing recipient traffic, and mismatched delivery
denominators fail. Participant, connection, and window arrays must be complete;
JSON `null` entries are rejected. All result files must have exactly 30 completed
windows.

Roblox documents [network capture in MicroProfiler](https://create.roblox.com/docs/performance-optimization/microprofiler/network);
its engine packet/item views are useful for attribution but do not by themselves
establish this gate's captured-frame byte totals.

## Evaluate

Supply a locally installed TShark executable whose hash is recorded in each
network receipt. The gate does not install dependencies or start a capture.

```powershell
lune run benchmarks/host/run-serializer-gate.luau --evaluate .tmp/serializer-study .tmp/serializer-study/report.json --tshark 'C:/Program Files/Wireshark/tshark.exe'
```

Reports are written without overwriting existing files. Exit 0 means
`EligibleForReview`; exit 2 means `Reject` or `Inconclusive`. Input/command errors
exit nonzero. Reports retain each observation and comparison separately. The
unit for sender/receiver medians and p95s is the distribution of **window mean
microseconds per message**, not individual-call tails. API-call samples remain
separate diagnostic evidence. Delivered throughput uses verified message count
over summed completion windows, including delivery drain; offered rate is not
substituted. Drain p99 from 30 windows is their maximum, whereas RTT tails use
the individual probe samples. Neither is a synchronized one-way latency claim.

No result here qualifies unreliable events, larger strings, CFrames, other
schemas, or production network conditions. Add a separately predeclared study
when a concrete serializer proposal targets those semantics. Even a complete
pass needs Relay's dedicated design/security review before implementation or
promotion.
