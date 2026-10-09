# Relay

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. It has no runtime dependencies.

## Requirements

- [Rokit](https://github.com/rojo-rbx/rokit) `v1.2.0`
- Luau's new type solver for static analysis; set Workspace's
  `UseNewLuauTypeSolver` to `Enabled` in Studio and use `--!strict` in consumer scripts.

## Development setup

From the repository root:

```sh
rokit install
rojo build default.project.json --output relay.rbxmx
lune run scripts/verify-foundation.luau
```

In Studio, import `relay.rbxmx` into `ReplicatedStorage`. It contains the
`Relay` ModuleScript used by the examples.

For a place with the shared definition and both scripts already mapped, build the
[reliable-events example](examples/README.md).

The verifier runs the registered correctness tests and checks the public module
contract, tracked file set and LF policy, Git ignore rules, Wally package
contents and archive creation, the Rojo package build, and CI workflow pins.
It also checks strict public API consumers with Luau's new type solver, using
hash-verified Roblox definitions cached in ignored `.tmp/`. Run that check alone
with `lune run tests/public-types.luau`; it enables `LuauSolverV2` explicitly.

## Protocol and abuse limits

The protocol contract and ingress limits are:

- **Version compatibility:** startup requires identical compiled definition
  descriptors and matching remote topology. The schema's `version` is included
  in that descriptor; matching `Relay.VERSION` or schema version alone is
  insufficient. Primitive-only definitions use `RR1` when reliable-only or
  `RR2` when any event is unreliable, including every event's delivery choice.
  Definitions using structs, arrays, enums, optionals or sets use `RR3`, with
  nested shapes and delivery choices included. Primitive-only definitions
  retain RR1/RR2 descriptor byte compatibility.
  There is no version negotiation, downgrade, or cross-version fallback.
- **Maximum encoded size:** the definition descriptor is capped at 4,096 bytes.
  Native tuples have at most eight fields, with each string capped by its declared
  `maximumBytes` (0..1024), at most 8192 string-content bytes per event. Relay
  has no encoded-size cap for reliable native tuples. Unreliable
  native payloads have Roblox's 1,000-byte ceiling, including endpoint/native
  encoding overhead; Relay does not preflight that encoded size. Oversized
  unreliable payloads can pass field validation and still be dropped by Roblox.
  Events containing any composable shape encode their entire tuple into one buffer:
  at most **8192 raw bytes for Reliable or 900 for Unreliable**, including a
  three-byte version/endpoint header and all length prefixes. Definition rejects
  schemas whose worst case exceeds that cap. These exact Relay buffer limits
  exclude Roblox's outer endpoint/envelope and compression; the unreliable
  ceiling still does not guarantee delivery.
  See the [UnreliableRemoteEvent reference](https://create.roblox.com/docs/reference/engine/classes/UnreliableRemoteEvent).
- **Elements and nesting depth:** array length and set size have required
  declared limits in 0..64; structs have at most eight fields and enums at most
  32 distinct strings of 1..32 bytes. Each compiled shape has explicit minimum/
  maximum encoded bytes, maximum depth and expanded node count. A primitive or
  enum is one node at depth zero. Each struct, array, set or optional adds one
  depth level and one node; arrays/sets reserve their declared capacity times
  the child's node count, structs sum children, and optionals reserve the child
  even when absent. An event is limited to **depth 4 and 256 expanded nodes**
  across all roots. Empty structs still count. Compilation also permits at most
  256 authored nodes per event, including children of zero-capacity containers.
- **Admission budgets:** an active, intact server admits only current rostered
  players. Each attempt costs one per-player token, then one shared aggregate
  token, before endpoint/channel or payload validation. Both delivery channels
  share those buckets. Per-player exhaustion leaves the aggregate untouched;
  aggregate exhaustion does not refund the player's token. Malformed and
  wrong-channel attempts receive no refund. Charges are per call, not per byte
  or element. The byte, depth and expanded-node caps bound composite decode work
  under these same charges.
  Handler concurrency caps apply; see [Lifecycle and admission](#lifecycle-and-admission).
- **Reject before dispatch:** client data is attacker-controlled. Current frame
  validators require exact arity, native types, and declared bounds before any
  handler call. Composite decoders also reject unsupported versions/tags,
  invalid lengths, truncation, trailing bytes, and size/array/depth violations.
  Decoders check limits before reads, allocation, or recursive descent and validate
  the whole frame before dispatch, with no partial handler calls.
  Focused checks must prove malformed-input rejection and applicable admission charging.

- Requests select RR5 and use Reliable endpoint zero with a checked format-1
  envelope: 44 identity bytes plus at most 8148 body bytes, 8192 total. Request
  and response shapes keep depth four, 256 nodes and containers of at most 64.
  Client attempts pay player-first then aggregate admission before parsing.
- Readiness or queue metadata selects RR6. Disabled/absent metadata preserves
  legacy descriptors. Reliable format-2 readiness controls are at most 84 bytes,
  with canonical GUIDs, positive counters and checked unused listener-mask bits.
  They pay ordinary actual-player admission before parsing and invoke no handlers.
- FIFO format-2 kind-1 frames contain 1..32 records and stay within 8192
  Reliable / 900 Unreliable raw bytes, including all framing; each forced-codec
  body is at most 8187 / 895 bytes. Client frames charge one player/aggregate
  token pair per declared logical record before scanning or copying. Complete
  bounds scan and decode precede any handler; malformed frames dispatch nothing.
- State uses the same queue bounds/admission with format-2 kind 2, accepting
  only State-capable events. Kind 1 accepts Batch/State-capable events. There is
  no receiver latest-arrival, loss recovery or ordered Unreliable promise.

## Events

The frozen public module exposes `VERSION`, `define`, `createServer`, and
`createClient`. Copy the small [ordered field helper](examples/reliable-events/ordered.luau)
beside your shared schema; the example puts both in `ReplicatedStorage`.
A shared definition assigns stable IDs and directions to events:

```lua
local ordered = require(game:GetService("ReplicatedStorage").ordered)

local definition, definitionError = Relay.define({
    name = "Gameplay",
    version = 1,
    events = {
        Input = {
            id = 1,
            direction = "ClientToServer" :: "ClientToServer",
            fields = ordered(
                { name = "sequence", type = "u32" :: "u32" },
                { name = "enabled", type = "boolean" :: "boolean" }
            ),
        },
    },
})
local Events = assert(definition, definitionError and definitionError.message)
```

For transient updates such as aim snapshots or visual effects, add
`delivery = "Unreliable" :: "Unreliable"` to an event, alongside `id`,
`direction`, and `fields`. Both directions support this option; Send, Broadcast,
and Connect keep the same signatures. Omitted delivery and explicit
`delivery = "Reliable" :: "Reliable"` use reliable delivery.

Unreliable events may be lost or arrive out of order. Keep these payloads small
and handle stale updates in game code. See [Protocol and abuse limits](#protocol-and-abuse-limits)
for payload size limits.

Definitions are immutable opaque tokens. Define 1–16 events with at most
8 fields each. The encoded descriptor is limited to 4,096 bytes, so a schema
within those counts can still be rejected. Primitive types are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`,
`i32`, `f32`, `Vector2F32`, `Vector3F32`, and `CFrame`. Integer fields may narrow their bounds; floats and vectors require
finite Float32-exact `minimum` and `maximum`. Values must be finite and within
bounds before and after Float32 rounding; scalar/vector negative zero becomes positive zero.
The additional composable shapes below allow bounded plain tables. User-supplied
buffers, Instances, arbitrary maps and recursive shapes remain unsupported.
The shared definition determines event names, direction-specific methods, and
ordered argument types for both sessions. Integer and float fields have Luau type
`number`; numeric bounds, integer checks, string byte limits, and game permissions
still require runtime validation. Listener callbacks may ignore trailing arguments.

`ordered(...)` preserves field positions for type analysis and copies/freezes the
field array and its immediate plain records once during schema construction. The
`:: "u32"` and direction annotations retain exact string types; they do not convert
or validate values. The helper is consumer-owned, not another Relay export.
Use plain field records: invalid tables with protected metatables can throw in
the helper before `Relay.define` returns its usual error record.

For a kind or direction used repeatedly, annotate a local once and reuse it,
as the [example definition](examples/reliable-events/Definition.luau) does for `u32`:
`local U32: "u32" = "u32"`, then `type = U32`. Unannotated locals widen to
`string`, which the typed schema rejects for field kinds and directions.

Use `ordered()` for events with no fields. Plain arrays are valid runtime schema
input; static type derivation requires the ordered helper and Luau's new solver.
Keep schema, definition, and session variables inferred: a broad `DefinitionSpec`
annotation loses the information needed for derivation. The `Definition<S>`,
`ServerSession<S>`, and `ClientSession<S>` type aliases take the schema type.

### Primitive fields

Signed integers accept exact whole numbers in `i8` (-128..127), `i16`
(-32768..32767), and `i32` (-2147483648..2147483647) ranges. Optional `minimum`
and `maximum` independently narrow that range, for example:

```lua
local fields = ordered(
    { name = "delta", type = "i16" :: "i16", minimum = -100, maximum = 100 },
    { name = "direction", type = "Vector2F32" :: "Vector2F32", minimum = -1, maximum = 1 },
    { name = "label", type = "string" :: "string", maximumBytes = 128 },
    { name = "pose", type = "CFrame" :: "CFrame", minimum = -1024, maximum = 1024 }
)
```

`Vector2F32` accepts native `Vector2` values and applies the same required bounds
to both Float32 components; `Vector3F32` does the same for three components.
Each vector occupies one tuple field. Primitive-only events send native Roblox
values; composite events encode the components as described below.

On primitive-only events, integer values travel as native numbers without a
packed wire-width promise. Composite events use the declared integer width.
There is no integer rounding.

`CFrame` requires finite Float32-exact translation bounds for X, Y, and Z.
Its rotation must be approximately orthonormal and right-handed: every entry
lies in [-1.0001, 1.0001], each column's squared length differs from 1 by at most
0.0001, pairwise column dot products have magnitude at most 0.0001, and the
determinant differs from +1 by at most 0.0001. All components must be finite.
Slight scale/shear within those fixed tests is accepted; Relay does not repair
or normalize matrices. Accepted local CFrames retain all components and zero
signs unchanged. Roblox controls native remote precision. Composite events
encode twelve f64 components and require exact reconstruction, including zero signs.

String fields require integer `maximumBytes` from 0 through 1024. Zero allows
only the empty string. Length counts bytes, including NUL, non-UTF8 bytes, and
each byte of multibyte text; accepted strings are unchanged. Text policy belongs
to the caller. A primitive-only event's string-content bound is the sum of its
declared limits, at most 8192 bytes across eight string fields. Composite events
include length prefixes in their total encoded-byte cap.

### Composable shapes

Use named fields in event tuples and structs, and anonymous shapes for
`element` and `value`. For example:

```lua
local fields = ordered({
    name = "snapshot", type = "struct" :: "struct",
    fields = ordered(
        { name = "mode" :: "mode", type = "enum" :: "enum",
            values = ordered("Idle" :: "Idle", "Run" :: "Run") },
        { name = "scores" :: "scores", type = "array" :: "array",
            maximumLength = 16, element = { type = "u16" :: "u16" } },
        { name = "tags" :: "tags", type = "set" :: "set",
            maximumSize = 8, element = { type = "string" :: "string", maximumBytes = 24 } },
        { name = "target" :: "target", type = "optional" :: "optional",
            value = { type = "u32" :: "u32" } }
    ),
})
-- Send({ mode = "Idle", scores = { 10, 20 }, tags = { blue = true } })
```

Structs reject undeclared keys and require every non-optional field. Arrays are
dense, start at index 1, and reject holes or extra keys. Sets use
`{ [member] = true }`; members may be booleans, strings, integers or enum strings.
Set iteration/wire order is unspecified. Enum strings must match a declared
literal exactly. Enum-set payload types expose the declared members as optional
`true` properties; unknown table keys still require runtime validation.
Optional values are nil or the declared child value; an absent
struct key means nil. An optional tuple argument still occupies its position,
including an explicit trailing nil. Luau may accept omitted trailing nullable
arguments at type-check time; Relay still requires the explicit nil and returns
`InvalidPayload` if it is omitted. Direct optional array elements and nested
optionals are rejected; put an optional field in an array element struct when
each position needs an absent value. Payload tables must have no metatable.

Struct field names and enum values need singleton annotations for exact inferred
types. The example derives a record with `mode: "Idle" | "Run"`,
`scores: { number }`, `tags: { [string]: true }`, and `target: number?`.
Value bounds remain runtime checks; typed schemas also enforce the four-level
composite depth limit. Definitions copy and freeze the complete schema;
decoded tables belong to that invocation, without sharing mutable payload state.

Composite events encode every field in declaration order. The buffer begins
with format version 1 and a little-endian u16 endpoint ID, which must match the
outer endpoint. Booleans and optional presence use one byte (0/1); enum ordinals
use one byte; integer widths follow their type; f32 and vector components use
four bytes each. CFrame uses twelve f64 components. Strings have a u16 byte
length, arrays and sets have a u16 count, and structs omit their known field
names. The decoder checks remaining bytes before each read and count limits
before container allocation. Invalid tags/values, trailing data, and duplicate
set members are rejected before dispatch.
Primitive-only events continue using native tuples even inside an RR3 definition.

## Sessions

On the server, explicitly choose finite ingress limits and connect before startup:

```lua
local serverResult, createServerError = Relay.createServer(Events, {
    inboundRate = {
        perPlayer = { capacity = 120, refillPerSecond = 60 },
        aggregate = { capacity = 960, refillPerSecond = 480 },
    },
})
local server = assert(serverResult, createServerError and createServerError.message)
local connectionResult, connectError = server.events.Input:Connect(function(player, sequence, enabled)
    -- Validate game permissions and authoritative state before acting.
end)
local connection = assert(connectionResult, connectError and connectError.message)
local started, startError = server:Start()
assert(started, startError and startError.message)
```

On the client:

```lua
local clientResult, createClientError = Relay.createClient(Events, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createClientError and createClientError.message)
local started, startError = client:Start()
assert(started, startError and startError.message)
local sent, sendError = client.events.Input:Send(1, true)
assert(sent, sendError and sendError.message)
```

For a `ServerToClient` event, the server handle exposes
`:Send(player, ...fields)` and `:Broadcast(...fields)`, and the client handle
exposes `:Connect(handler)`. Broadcast makes one `FireAllClients` call. Each
receiving endpoint permits one listener; `connection:Disconnect()` permits a
replacement. `session:Destroy()` releases the session and is idempotent.
See [the complete examples](examples/reliable-events).

Object-producing operations return `object, nil` or `nil, error`; boolean
operations return `true, nil` or `false, error`. Errors are frozen `{ code,
message }` records. For `assert`, pass `err and err.message` because Relay errors
are records, not strings. The stable codes are `InvalidDefinition`, `InvalidOptions`,
`WrongRuntimeSide`, `AlreadyStarted`, `NotStarted`, `Destroyed`,
`AlreadyConnected`, `InvalidHandler`, `InvalidPayload`, `InvalidPlayer`,
`StartupTimeout`, `RemoteOwnershipConflict`, `DefinitionMismatch`,
`Disconnected`, and `TransportFailure`. Messages are fixed diagnostics.

## Lifecycle and admission

Only one started session per runtime side and loaded Relay copy is allowed.
The server owns `ReplicatedStorage.RelayRemotes`, containing `Definition` and
`Reliable`, plus `Unreliable` when any event opts into unreliable delivery.
A client checks the exact definition descriptor and attaches its
local callback during `Start`; its timeout must be greater than zero and at
most 60 seconds. Connect listeners before startup when early traffic matters.
Destroying a client during startup cancels discovery and makes the pending
`Start` return `Destroyed` without waiting for the remaining timeout.

A successful send means the Roblox fire call returned. It does not establish
client readiness, receipt, or handler completion. Relay adds no queue, handshake,
retry, replay, automatic reconnect, batching, RPC, or middleware. Transport loss
destroys the server session or disconnects the client; create a new session to
restart. Cleanup preserves foreign descendants in contaminated transport objects.

Every current player's inbound call consumes its per-player budget, then the
shared aggregate budget, before endpoint or payload validation. Both delivery
channels share these budgets and handler limits. An endpoint sent over the wrong
remote is rejected after applicable rate charging. Per-player
capacity is `1..4096` and refill is `0 < rate <= 2048` per second; aggregate
capacity is `1..32768` and refill is `0 < rate <= 16384`, with each aggregate
value at least its per-player counterpart. The example rates are application
choices, not universal defaults.

Relay silently drops malformed, rate-limited, listener-less, and handler-capacity
exceeding traffic. A yielding handler retains its slot: one per player/endpoint,
at most 8 per player and 64 server-wide; client handlers allow one per endpoint.
There is no waiting queue, and replacing a listener does not reset an occupied
slot. Handler errors are contained. Removal and destruction prevent late
callbacks from recreating state.

These are remote-abuse and resource-exhaustion limits on Relay-owned work.
They do not bound Roblox traffic, argument materialization, scheduling, or a
developer handler's own work. A shared aggregate limit does not guarantee
fairness. Game code owns authorization, ownership, cooldowns, costs,
persistence, and replay policy. Roblox's
[client-server boundary guidance](https://create.roblox.com/docs/scripting/security/client-server-boundary)
describes those application responsibilities.

The isolated real Studio correctness proof is `lune run
tests/studio-reliable-events.luau`; it is separate from the portable aggregate
verifier and from timing benchmarks. Relay makes no performance ranking claim.
Append `--correctness-only` to run the two-client correctness scenario during
development; omit it for the full correctness and admission matrix.

## Supported schema authoring

`Relay.schema` is a frozen table of ordered field, primitive/composite shape and
directional event constructors. Use `schema.field(name, shape)` to bind a reusable
shape, then `schema.ordered(...)` for fields. `define` remains the authoritative
validator and copies reused shapes independently. Setup errors include bounded
field paths. The original ordered helper remains compatible.

`schema.compose(...)` merges 1..64 literal event maps, with at most 64 input
entries and deterministic key/ID collision rejection. The compiled definition
limits remain 16 endpoints and a 4096-byte descriptor. Keep singleton struct
names/enum values and parenthesize a final builder call in ordered packs.

## Audience sends

ServerToClient server handles expose `SendTo(players, ...)` and
`SendExcept(excludedPlayers, ...)`, returning success, error and successful
handoff count. Lists are plain dense arrays of at most 1024 actual Players.
Identity duplicates are removed and departed Players skipped. Validation and
encoding occur once, including empty audiences. A partial transport failure
stops handoffs and is never retried. Full `Broadcast` still uses FireAllClients.

## Diagnostics and request responses

`Relay.inspect(definition)` returns a frozen schema-budget report; native tuple
wire bytes remain unknown. `session:GetDiagnostics()` returns bounded saturating
totals and per-event counters without retaining attacker payloads or Players.
Receiving event handles support `Once`; a callback's yielding lease survives
listener replacement. Reliable transport can still encounter admission/busy drops.

Define `requests` using `schema.request(id, orderedArguments, responseShape)`.
Clients call `session.requests.Method:Request(timeoutSeconds, ...)` and await the
returned handle with `Await`; `Cancel` settles locally without undoing server
work. Server request handles use `Connect(function(player, ...) return response end)`.
Clients own at most eight pending requests and one per method, with deadlines
of at most 60 seconds. Nonreused u32 call IDs and session GUIDs reject stale
responses. Server replay records are bounded to 64 recent and eight active
identities per actual Player. Requests share ingress budgets and handler leases;
callbacks own application authorization. No automatic retries or durable
exactly-once promise apply. Departure/destroy releases pending work and timers.

## Readiness and explicit FIFO batches

Set `readiness = true` to acknowledge ServerToClient listeners. Clients expose
`RefreshReadiness`; server event handles expose `GetReadyPlayers`, a fresh bounded
claim snapshot. Readiness is optional and does not replace application authority.

Mark a sending-direction event `queue = "Batch"` and call `CreateBatch` on a
started session. Server batches capture a fixed audience of at most 1024 Players;
client batches target their server. Accepted submissions encode immediately and
own their bytes. One open batch owns at most 32 records across both channels.
The first submission fixes a deadline of at most 100 ms, without extension.
`Flush` consumes records and sends Reliable before Unreliable, returning a frozen
handoff report; partial/uncertain failures never retry. Destroy releases timers.

## Latest unsent state

`queue = "State"` also permits FIFO submission. `CreateState` shares the queue
owner, handoff clock and flush guard. Four lanes share 64 active keys and 16384
pending body bytes. `Put` atomically replaces one unsent lane/event/u32 key;
priority, first-dirty age, event ID and key determine selection. Replacements
never extend the one-second expiry. Handoffs consume selected bodies without
retry; scalar keys remain until Remove/Destroy. Use absolute snapshots and
application sequence checks for stale filtering. Never use replacement for
discrete commands such as purchases or damage.

## Repository boundaries

- `src/` contains publishable package source.
- `tests/` and `scripts/` contain correctness tooling.
- `examples/` contains examples that use only the public API.
- `benchmarks/` is an isolated benchmark workspace.
- Durable repository guidance is tracked; private plans, downloaded benchmark
  libraries, generated output, local results, builds, dependencies, editor
  state, and local Forge specs/reports remain ignored.

## License

[MIT](LICENSE)
