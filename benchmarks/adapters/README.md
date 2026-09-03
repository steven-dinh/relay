# External benchmark adapters

Each binding connects a pinned library to `AdapterContract` and forwards the
library's decoded payloads to the existing correctness checks. Source acquisition,
payload qualification, and benchmark eligibility are separate steps.

The authoritative revisions, versions, licenses, and artifact checksums are in
[`../libraries.lock.json`](../libraries.lock.json). Downloaded source, compiler
executables, and generated runtimes remain ignored. The existing acquisition
verifier checks their bytes against the lock; the installation marker alone is
not integrity evidence. Artifact checksums frame sorted relative paths, byte
lengths, and file contents with NUL separators; they are not individual executable
hashes.

## Bindings and library interfaces

Paths below are relative to `benchmarks/`. Every adapter uses
`adapters/<id>/init.luau`. Runtime bindings receive their library through
`context.resourceRoot.Library`.

| ID | Pinned source or tool | Decoded callback | Reliable send and broadcast |
| --- | --- | --- | --- |
| `quicknet` | `vendor/quicknet/src/QuickNet.luau` and its child modules | One record; server receives `(Player, record)` | `FireServer(record)` / `FireAllClients(record)` |
| `bytenet` | `vendor/bytenet/src` | One record; server receives `(record, Player)` | `send(record)` / `sendToAll(record)` |
| `satset` | `vendor/satset/src` | One record; server `listen` receives `(record, Player)` | `fireServer(record)` / `fireAllClients(record)` |
| `suphi-packet` | `vendor/suphi-packet/Packet` | Positional values; server receives `Player` first | `Fire(...)` on either side; server Fire broadcasts |
| `warp` | `vendor/warp/src` | Positional values; server receives `Player` first | Client `Fire(true, ...)` / server `Fires(true, ...)` |
| `blink` | `vendor/blink/blink.exe` and generated runtime | Positional values via `On`; server receives `Player` first | `Fire(...)` / `FireAll(...)`; `StepReplication()` flush |
| `zap` | `vendor/zap/zap.exe` and generated runtime | Positional values via `SetCallback` for `SingleSync`; server receives `Player` first | `Fire(...)` / `FireAll(...)`; `SendEvents()` flush |
| `netray-compile` | `vendor/netray-compile/NetRay-Compile.exe` and generated runtime | Positional values via `On`; server receives `Player` first | `Fire(...)` / `FireAll(...)`; `StepReplication()` flush |

Tiny carries `sequence: u32` and `enabled: boolean`. State carries
`sequence: u32`, `entityId: u16`, `position: Vector3F32`, `yaw: f32`, and
`health: u8`. Schemas preserve those logical values; Warp chooses numeric storage
widths dynamically. C2S sender metadata comes from the library's engine-supplied
`Player`, never a payload field. Adapters preserve original decoded records or
captured positional values so malformed, missing, or extra fields remain visible
to the comparator.

QuickNet uses a single record schema because the pinned positional unpacker pads
two arguments to four and five arguments to eight. Its public server rate limit
is set to `1_000_000` calls per second for qualification; the default 120 per
second would reject the four-message-per-frame workload. Warp also needs an
explicit public rate-limit configuration above the offered workload; its default
is 200 calls per two seconds. QuickNet's `FireAllClients` and Warp's `Fires` loop
over recipients internally, unlike a native broadcast remote call.

## Qualification and isolation

Run the integrity check from the repository root before loading external inputs:

```powershell
lune run scripts/acquire-benchmark-libraries.luau --verify
lune run scripts/generate-benchmark-adapters.luau --all
lune run benchmarks/tests/external-library-payloads.luau quicknet 30
```

The payload command accepts a library ID from the table. Generated libraries also
require runtime generation from their tracked schemas with the verified compiler
before this command can qualify them. Use `--library blink`, `--library zap`, or
`--library netray-compile` to generate one adapter, and `--verify` to check existing
outputs. Each generation runs the pinned compiler twice and requires identical
output bytes. The payload command independently verifies the selected library's
downloaded bytes and the generated schema/compiler/output manifest before loading.
Installing a compiler is not payload proof.

For generated bindings, `resourceRoot.Library` is a folder containing the
generated `Server`, `Client`, and `Types` ModuleScripts. Blink and Zap use manual
replication; their public flush runs inside the final operation of each frame.
NetRay also exposes a public flush but retains its upstream Heartbeat connection.

Qualification executes the unmodified library serializer and decoder through a
simulated engine transport. It compares actual delivered Tiny and State values,
sender metadata, order, cardinality, input preservation, and multi-recipient
broadcast against the deterministic fixtures. Each repetition receives a fresh
simulated module world. Its output is an untimed correctness report, not Result V1,
a Studio transport measurement, or a performance ranking. Passing it does not
make an adapter selectable by the existing Benchmark host.

On 2026-09-03, all eight adapters passed the seven selections across 30 fixture
repetitions: 94,200 verified deliveries per library, 753,600 in total. QuickNet's
runtime pilot passed before the remaining runtime bindings; Blink's generated
pilot passed before Zap and NetRay. These counts describe codec qualification
under the simulated engine, not measured Studio results.

All eight require `ProcessRestart` isolation for a future Studio integration.
Their global remotes, scheduler connections, registries, or queues outlive an
adapter callback disconnect. Teardown closes callback admission and releases
runner references before disconnecting any supported subscription. ByteNet and
Satset lack public listener removal; bindings do not mutate their internal
listener arrays. Warp's pinned `Destroy` calls `remove` on a buffer already
cleared by its constructor and throws; the adapter uses the supported
`Disconnect(key)` operation and leaves the endpoint to process teardown.

Potentially yielding library initialization must finish before entering the
non-yielding adapter lifecycle; readiness only inspects cached state. Generated
callbacks may replay queued traffic when attached, so attachment alone cannot
establish a clean repetition.

Warp additionally requires `adapters/warp/Endpoint.luau` mapped as
`resourceRoot.Endpoint`, beside the vendor `Library`. Require that module during
bounded untimed startup, server first and then each client, before constructing
adapter sides. Its client constructor always yields. The adapter only requires
the cached endpoint during setup. A future Studio host must also await replicated
library remotes, registration attributes, and ByteNet namespace values before
entering non-yielding setup; the simulated world has immediate replication.

Suphi-Packet's license remains `UNVERIFIED` in the lock. Its client flush is gated
by accumulated time above 1/60 second, which does not establish Event V1's maximum
one added sender frame. Qualification therefore makes no scheduling-bound or
benchmark-eligibility claim for it. No adapter here has a published vendor Result
identity or a certified malicious-byte-stream decoder review.
