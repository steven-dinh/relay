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
  Request-bearing definitions use `RR5`; optional readiness or queued-event
  metadata selects `RR6`. Empty request maps and disabled feature metadata retain
  the earlier descriptor bytes. Descriptor equality covers every selected feature.
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
  RPC uses Reliable endpoint zero with one buffer of at most **8192 raw bytes**:
  a 44-byte identity header and a forced-codec body of at most **8148 bytes**.
  Requests and responses independently use the same depth, node and shape caps.
  Queue-capable events also use a forced-codec body for their queued route, even
  when immediate sends use native tuples. FIFO and state envelopes are endpoint-zero
  format 2, kinds 1 and 2, with 1..32 records. Kind 1 admits Batch/State-capable
  events; kind 2 admits only State-capable events. Its three-byte format/kind/count header
  and each two-byte body length count toward the **8192 Reliable / 900 Unreliable
  raw-byte** envelope cap. Each record body is at most **8187 / 895 bytes**,
  including its existing three-byte codec header. These are Relay buffer-content
  limits, not Roblox wire-size estimates.
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
  A counted format-2 client batch or state frame pays one pair for its first logical
  record, then attempts another `N - 1` pairs for the remaining declared records,
  using the original timestamp. A count that cannot
  be trusted costs only the first pair. Exhaustion aborts before record scanning
  or body copies; if all N pairs are admitted, a later malformed record keeps
  the full N charges. Exhausted or malformed attempts are never refunded.
  Handler concurrency caps apply; see [Lifecycle and admission](#lifecycle-and-admission).
- **Optional readiness controls:** `readiness = true` selects RR6 and requires at
  least one ServerToClient event. The reliable endpoint-zero controls use format
  2: Hello is 2 bytes, Challenge 42, Ack `82 + W`, and Close 78, where
  `W = ceil(ServerToClient event count / 8)`. Events are ordered by ID for the
  listener-bit map. With the current 16-entry definition cap, `W` is at most 2
  and a control buffer at most 84 bytes. The exact control lengths, direction,
  canonical GUIDs, positive counters, and zero unused mask bits are checked
  before copying fields. Client control attempts use the same actual-player,
  player-first then aggregate admission as other ingress; malformed or stale
  attempts are charged without refund. Controls do not invoke event handlers or
  consume handler leases. These bounds are separate from application payloads.
- **Reject before dispatch:** client data is attacker-controlled. Current frame
  validators require exact arity, native types, and declared bounds before any
  handler call. Composite decoders also reject unsupported versions/tags,
  invalid lengths, truncation, trailing bytes, and size/array/depth violations.
  Decoders check limits before reads, allocation, or recursive descent and validate
  the whole frame before dispatch, with no partial handler calls. FIFO/state frames first
  scan all record boundaries, then decode every body before checking individual
  listeners and handler leases; a malformed last body rejects the entire frame
  without calling earlier handlers.
  Focused checks must prove malformed-input rejection and applicable admission charging.

## Events

The public module exposes `VERSION`, `schema`, `define`, `inspect`,
`createServer`, and `createClient`. `Relay.schema` provides supported constructors for the existing
schema grammar. The example puts its shared definition in `ReplicatedStorage`.
A shared definition assigns stable IDs and directions to events:

```lua
local s = Relay.schema

local definition, definitionError = Relay.define({
    name = "Gameplay",
    version = 1,
    events = {
        Input = s.clientToServer(1, s.ordered(
            s.field("sequence", s.u32()),
            (s.field("enabled", s.boolean()))
        )),
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

Definitions are immutable opaque tokens. Define 1–16 events and requests combined,
with unique IDs across both maps and at most 8 request/event fields each.
The encoded descriptor is limited to 4,096 bytes, so a schema
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

The constructors are `ordered`, `field`, the twelve primitive kind names,
`struct`, `array`, `enum`, `optional`, `set`, `clientToServer`, `serverToClient`,
`request`, and `compose`.
Their arguments match the raw grammar: for example `s.string(128)`,
`s.i16(-100, 100)`, `s.array(element, 16)`, and
`s.serverToClient(id, fields, "Unreliable")`. `field(name, shape)` copies an
anonymous shape before naming it; an already named shape is rejected.
Constructors freeze their owned records and ordered lists. `define` validates
and independently copies the complete tree. Invalid helper arguments can throw
before `define`, so use plain records when constructing dynamically checked input.

Reusable shapes are ordinary locals or returned ModuleScript values. For example:

```lua
local Item = s.struct(
    s.field("id" :: "id", s.u32()),
    (s.field("count" :: "count", s.u16()))
)
local fields = s.ordered(s.field("items", s.array(Item, 16)))
```

Luau's pinned new solver still needs singleton annotations for struct field names
and enum values, such as `s.enum("Idle" :: "Idle", "Run" :: "Run")`.
Parenthesize the final builder call in multi-entry `ordered` or `struct` arguments
as shown above: this keeps its result singular in the solver's ordered type pack.
Primitive kind and event direction casts are supplied by the constructors.
Raw records and the original [ordered helper](examples/reliable-events/ordered.luau)
remain compatible; raw kind/direction literals require singleton annotations.

Split event maps into ordinary inferred modules and combine them with
`s.compose(combatEvents, inventoryEvents)`. It returns a frozen merged event map
or an `InvalidDefinition` error. Duplicate event names or IDs reject the merge;
they never overwrite an earlier event. Literal keys preserve exact payload and
direction types. Broad string-indexed maps cannot provide those types.

```lua
local events, composeProblem = s.compose(Combat, Inventory)
local merged = assert(events, composeProblem and composeProblem.message)
local definition, problem = Relay.define({ name = "Gameplay", version = 1, events = merged })
```

Composition accepts at most 64 fragments and 64 total entries. `define` applies
the current 16-entry and 4096-byte descriptor limits and copies the complete
schema; composition retains the input event records until then.

Use `s.ordered()` for events with no fields. Plain arrays are valid runtime schema
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
`:Send(player, ...fields)`, `:Broadcast(...fields)`, `:SendTo(players, ...fields)`,
and `:SendExcept(excludedPlayers, ...fields)`, and the client handle
exposes `:Connect(handler)` and `:Once(handler)`. Broadcast makes one `FireAllClients` call. Each
receiving endpoint permits one listener; `connection:Disconnect()` permits a
replacement. `session:Destroy()` releases the session and is idempotent.
See [the complete examples](examples/reliable-events).

Receiving events on either side support `Once` with Connect's return/error
contract. It detaches before the first validated, admitted callback. Rejected
traffic does not consume it. On the server it means once across all players.
A yielding one-shot handler keeps its lease; connecting a replacement does not
free that lease. Errors are contained as with Connect.

`SendTo` and `SendExcept` validate and normalize/encode the payload once, then
reuse it for each recipient. They return `ok, error, sentCount`; the count records
successful Roblox `FireClient` calls, not receipts. Audiences must be plain dense
Player arrays with at most 1024 entries. Duplicate Player objects count once;
departed players are skipped. `SendExcept` snapshots the current roster and
rejects more than 1024 remaining recipients. Empty audiences still validate the
payload and return `true, nil, 0`. Caller arrays are unchanged. A transport failure
or observed session destruction stops the loop and returns the completed count;
earlier sends cannot be rolled back and are never retried. Full broadcast keeps
the native `FireAllClients` path.

### Explicit FIFO batches

Mark an event with `queue = "Batch"` to make its sending-side payload available
through an explicit one-shot batch. Queue metadata selects RR6 and is part of
the startup descriptor. Immediate `Send`, `Broadcast`, `SendTo`, and `SendExcept`
keep their existing behavior. For example, these event entries can be placed in
the shared definition:

```lua
local s = Relay.schema
local Queued = assert(Relay.define({
    name = "QueuedGameplay", version = 1,
    events = {
        Input = {
            id = 1, direction = "ClientToServer" :: "ClientToServer",
            queue = "Batch" :: "Batch",
            fields = s.ordered(s.field("sequence", s.u32())),
        },
        Snapshot = {
            id = 2, direction = "ServerToClient" :: "ServerToClient",
            queue = "Batch" :: "Batch",
            fields = s.ordered(s.field("sequence", s.u32())),
        },
    },
}))
```

Create and start both sessions from `Queued`, connecting their listeners as
shown in [Sessions](#sessions).

After the sessions start, the server captures a copy of its bounded recipient
snapshot when creating a batch. The client always targets its connected server:

```lua
local batch, problem = server:CreateBatch({ alice, bob }, 0.02)
assert(batch, problem and problem.message)
assert(batch.events.Snapshot:Send(25))
local ok, flushProblem, report = batch:Flush()

local inputBatch = assert(client:CreateBatch(0.02))
assert(inputBatch.events.Input:Send(26))
local inputOk, inputProblem, inputReport = inputBatch:Flush()
```

`CreateBatch` requires a started, intact session and a finite
`flushAfterSeconds` greater than zero and at most 0.1 seconds. On the server,
the audience must be a plain dense Player array with at most 1024 input entries;
duplicate identities collapse, departed Players are skipped, and an empty
audience is valid. The caller's array is not retained. A batch exposes only
marked events sent by that session. Only one batch may be active per sending
session; another can be created after the current batch is terminal.

Each accepted `Send` validates and encodes immediately, then owns that exact
payload for the batch. The batch holds at most 32 records across both delivery
channels. It preflights each channel's complete raw frame against 8192 Reliable
or 900 Unreliable bytes, including the three-byte outer header, two-byte length
per record, and codec body. A count or byte overflow returns `QueueFull` without
adding or evicting a record. The first accepted send fixes one automatic flush
deadline; later sends do not extend it. Manual `Flush` sends any queued Reliable
frame before the Unreliable frame. Records retain their submission order within
each channel, with no order promise between channels.

`Flush()` returns `ok, error, report`. Its frozen report counts successful
`FireClient`/`FireServer` calls in `reliableHandoffs` and `unreliableHandoffs`;
`logicalHandoffs` multiplies each successful envelope handoff by its record
count. For this FIFO handle, `selected` is the record count and `remaining` and
`expired` are zero. These are local handoff counts, not receipts or callbacks.
An empty flush succeeds with zero handoffs. Flush is terminal and repeated calls
return the same cached result, including after an automatic flush. A transport
failure stops later handoffs and preserves earlier successful counts; Relay does
not retry. `Cancel()` discards an open batch, and a later `Flush()` returns the
cached `Cancelled` error. Cancel after flush begins has no effect.

The receiver scans all record lengths and event metadata, then decodes every
body before attempting any callback. A malformed body rejects the whole frame
with no partial handler calls. Valid records then go through the ordinary
listener and handler-lease checks in envelope order, and admitted handlers start
in that order within the envelope. A yielding handler keeps its lease, so another
record for that endpoint can be dropped as busy; a batch does not serialize
command completion. Callback completion and order across frames, channels, and
recipients are not promised. Portable runtime checks and review pass; actual
Studio scheduler and transport proof is still pending.

### Latest unsent state

Use `queue = "State"` for absolute snapshots that may replace an earlier unsent
value. This also permits ordinary FIFO batching. Keep purchases, damage, and
other discrete commands on immediate sends or FIFO batches.

`server:CreateState(audience, flushAfterSeconds)` captures the same fixed,
bounded Player snapshot as CreateBatch; `client:CreateState(flushAfterSeconds)`
targets its connected server. Both require a started, intact session and
`0 < flushAfterSeconds <= 0.1`. A lane exposes only sending-direction State events.

```lua
local lane, problem = server:CreateState({ alice, bob }, 0.02)
assert(lane, problem and problem.message)
assert(lane.events.Pose:Put(entityId, "High", tick, position))
assert(lane.events.Pose:Put(entityId, "Normal", newerTick, newerPosition))
local ok, flushProblem, report = lane:Flush()
local status = lane:GetStatus()
lane.events.Pose:Remove(entityId)
lane:Destroy()
```

Declare Pose's tick and position fields in the shared definition. `Put` validates
and owns an encoded snapshot immediately. The lane/event/u32 key identifies a
slot; a later accepted Put replaces only its pending body and priority.
Priorities are exactly High, Normal, or Low. Invalid payloads or overflow leave
the previous snapshot intact. Across all lanes, a sending session owns at most
four lanes, 64 active keys, and 16384 pending body bytes. Active keys persist
after handoff until Remove or Destroy; Remove sends no deletion message.

Flush expires pending values at one second from their first dirty submit;
replacements do not extend that age. Within each channel it selects High before
Normal before Low, then older first-dirty time, event ID, and key, fitting at most
32 records and 8192 Reliable/900 Unreliable raw bytes. Reliable is handed off
first. Unselected work remains bounded for later service. Automatic service uses
one timer per lane; platform scheduling can delay its target.

The six-number report uses the same local handoff units as FIFO. `selected`,
`remaining`, and `expired` describe local snapshots. Selected bodies leave the
queue before handoff, including a failed handoff; Relay does not retry. State
Flush keeps the lane open, and GetStatus returns a frozen snapshot of its state,
active/pending keys, pending body bytes, and one last flush result. Destroy is
idempotent and clears timers, bodies, keys, and audience references. FIFO and
state share one flush guard; reentrant mutation returns QueueBusy.

Replacement concerns unsent values. Unreliable updates can still drop or arrive
out of order after handoff. Include an application tick/sequence and filter stale
values in the receiving handler when needed. Readiness is a listener claim;
the game still owns audience selection and authorization.

### Optional listener readiness

Set `readiness = true` in the shared definition to track client listeners for
ServerToClient events. Omit it or set it to `false` to keep the legacy descriptor
and startup behavior. Readiness requires at least one ServerToClient event and
adds no remote. For example:

```lua
local s = Relay.schema
local definition, problem = Relay.define({
    name = "Gameplay", version = 1, readiness = true,
    events = {
        Snapshot = s.serverToClient(1, s.ordered(s.field("sequence", s.u32()))),
    },
})
local Gameplay = assert(definition, problem and problem.message)
```

On the client, connect the listeners before `Start` when practical. Start installs
the reliable receiver, snapshots the current listener set, and sends one Hello.
It does not wait for the server to accept the claim. A valid Challenge triggers
one Ack; later Connect, Disconnect, and admitted `Once` depletion update the
listener mask with best-effort Acks. Listener changes before startup are included
in the initial mask.

```lua
local connection, connectProblem = client.events.Snapshot:Connect(function(sequence)
    -- Apply the snapshot under the game's own authorization and ordering rules.
end)
assert(connection, connectProblem and connectProblem.message)
assert(client:Start())

-- If recovery is needed after an admission-dropped Ack or Hello:
local refreshed, refreshProblem = client:RefreshReadiness()
-- If a newer Challenge may have been missed while an older one is held, use this instead:
-- local restarted, restartProblem = client:RefreshReadiness(true)
```

`RefreshReadiness()` (also nil or false) sends one Ack for the currently held
Challenge, or one Hello if there is no held Challenge. `RefreshReadiness(true)`
clears only the held generation and sends one Hello to request a fresh Challenge;
it preserves the session identity and listener revision. It is useful if a newer
Challenge handoff failed while the client still holds an older generation. Both
forms report only local transport handoff, do not wait for server acceptance,
and never retry automatically. A non-boolean argument returns `InvalidOptions`.

On the server, `GetReadyPlayers()` is available on each ServerToClient event
handle. It returns a fresh dense Player array containing current roster members
whose latest accepted listener claim includes that event. Pass the snapshot to
the existing `SendTo` method:

```lua
local ready, readyProblem = server.events.Snapshot:GetReadyPlayers()
assert(ready, readyProblem and readyProblem.message)
local sent, sendProblem, sentCount = server.events.Snapshot:SendTo(ready, 25)
```

The query returns no partial array if more than 1024 eligible players would be
returned (`InvalidAudience`). It follows the session's lifecycle and transport
integrity checks. The audience can change between query and send; `SendTo`
rechecks each recipient and keeps its normal validation and partial-handoff
behavior. `Send`, `SendTo`, `SendExcept`, and `Broadcast` remain unconditional.
`GetReadyPlayers` returns `Destroyed`, `NotStarted`, `ReadinessDisabled`, or
`InvalidAudience` errors as applicable. `RefreshReadiness` can return `Destroyed`,
`NotStarted`, `ReadinessDisabled`, `ReadinessExhausted`, `InvalidOptions`, or
`TransportFailure`.

Readiness means only that the latest accepted client control claims a listener
is installed. It is not authorization, delivery receipt, handler completion,
liveness, or lease availability. Clients can make false claims; admission limits,
missing listeners, and busy handlers can still drop traffic. Unreliable events
can still be lost or reordered. The game owns authorization, initialization
timeouts, and any recovery policy. `ReadinessExhausted` reports exhausted local
identity counters.

## Requests

Declare reliable client-to-server requests beside the event map. Each request
has an ID, ordered request fields, and one anonymous response shape:

```lua
local definition, problem = Relay.define({
    name = "Inventory", version = 1, events = {},
    requests = {
        Inspect = s.request(1, s.ordered(s.field("itemId", s.u32())),
            s.struct(
                s.field("owned" :: "owned", s.boolean()),
                (s.field("count" :: "count", s.u16()))
            )),
    },
})
local Inventory = assert(definition, problem and problem.message)

local connection, connectProblem = server.requests.Inspect:Connect(function(player, itemId)
    -- Check this actual Player's permissions against authoritative game state.
    return { owned = true, count = 3 }
end)
assert(connection, connectProblem and connectProblem.message)

local pending, requestProblem = client.requests.Inspect:Request(5, 123)
assert(pending, requestProblem and requestProblem.message)
local result = pending:Await()
if result.ok then
    print(result.value.count)
else
    warn(result.error.message)
end
```

`Request(timeoutSeconds, ...fields)` validates and hands off without yielding;
the timeout must be finite and greater than zero, at most 60 seconds. A client
owns at most eight pending requests and one per method. IDs never repeat within
its session. `Await` yields while pending, permits one waiter, and returns a
frozen `{ ok = true, value = response }` or `{ ok = false, error = RelayError }`.
Repeated Await reads the same settled result and decoded value.
`Cancel()` settles locally with `Cancelled`; it does not undo server work.

The server handler receives the actual firing Player and must return exactly
one value. False is valid; an optional response permits explicit nil. A thrown
handler returns `HandlerFailure`, and an invalid result returns `InvalidResponse`,
without sending exception text. Game denial belongs in the declared response.
Requests share event admission budgets and the one/eight/64 server handler
limits. Missing listeners, busy or rate-limited requests are dropped and can
therefore time out. A bounded 64-identity recent ring plus active identities
rejects replays; this is no durable exactly-once guarantee. Departures, destroy,
transport loss, deadlines and cancellation release owned pending state. Late
responses are ignored. Relay never retries a request automatically.

Object-producing operations return `object, nil` or `nil, error`; other boolean
operations return `true, nil` or `false, error`. Errors are frozen `{ code,
message }` records. For `assert`, pass `err and err.message` because Relay errors
are records, not strings. The stable codes are `InvalidDefinition`, `InvalidOptions`,
`WrongRuntimeSide`, `AlreadyStarted`, `NotStarted`, `Destroyed`,
`AlreadyConnected`, `InvalidHandler`, `InvalidPayload`, `InvalidPlayer`, `InvalidAudience`,
`StartupTimeout`, `RemoteOwnershipConflict`, `DefinitionMismatch`,
`Disconnected`, and `TransportFailure`. Requests also use `RequestLimit`,
`RequestIdExhausted`, `RequestTimeout`, `Cancelled`, `AlreadyAwaiting`,
`NotYieldable`, `HandlerFailure`, and `InvalidResponse`. Readiness also uses
`ReadinessDisabled` and `ReadinessExhausted`. FIFO batches also use
`QueueLimit`, `QueueFull`, `QueueClosed`, and `QueueBusy`; cancelling an open
batch makes its cached `Flush` result `Cancelled`.
Setup `InvalidDefinition` messages identify
the first rejected field path and reason, bounded to 256 bytes. Long paths elide
their middle. Packet errors keep fixed messages and retain no rejected payload.

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
client readiness, receipt, or handler completion. Requests use explicit pending
handles and local deadlines. Relay adds no automatic retry or reconnect. Transport loss
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
Immediate events and requests have no waiting queue. Explicit FIFO batches are
opt-in through queue-capable events; replacing a listener does not reset an
occupied handler slot. Handler errors are contained. Removal and destruction
prevent late callbacks from recreating state.

## Diagnostics and budget inspection

`Relay.inspect(definition)` returns a deeply frozen report or `InvalidDefinition`
for a token from another loaded copy or a forged token. It lists protocol,
descriptor bytes, current limits, and each event's direction, delivery, depth,
expanded nodes, and byte representation. `RelayBuffer` rows expose exact minimum
and maximum raw buffer bytes. `NativeTuple` rows expose declared string-content
bounds and `robloxEncodedBytes = "Unknown"`; packed numeric widths are not native
wire-size promises. Native unreliable rows also report `unreliableSizeStatus =
"Unknown"`. Raw buffers exclude Roblox's envelope and compression.
Request rows expose separate forced-codec request/response bounds, with the
8148-byte body and 8192-byte envelope limits. Queue-capable events preserve
`bytes` for immediate sends and add `queuedBytes` for their forced-codec body,
single-record envelope bounds, and Reliable/Unreliable raw limit. Its
`robloxEncodedBytes` remains `"Unknown"`; no exact engine or wire size is inferred.

`session:GetDiagnostics()` returns an independent deeply frozen snapshot in
every lifecycle state, including after destruction. It includes side, state,
active Relay leases, handler limits, server inbound-rate settings, and cumulative
session/per-event counters. It never samples a clock or refills a budget.

```lua
local report, issue = Relay.inspect(Events)
assert(report, issue and issue.message)
local diagnostics = server:GetDiagnostics()
print(report.descriptorBytes, diagnostics.counters.busy,
    diagnostics.counters.invalidPayload, diagnostics.inFlight)
```

Immediate and RPC receive counters report the first observed rejection:
eligibility/rate, endpoint, channel, listener, busy, then payload. Format-2 FIFO
ingress first charges its declared logical-record count, then scans metadata and
decodes every body before listener and busy checks. Structural failures are
session-level `invalidPayload`; a known wrong endpoint or channel uses
`invalidEndpoint` or `wrongChannel`; a body decode failure after resolving its
event is attributed to that event. `received` counts receive callbacks (one
envelope), while `dispatched` counts admitted logical callbacks;
`handlerErrors` counts contained errors while the session remains started.
`sendHandoffs` counts successful targeted fire calls, `broadcastHandoffs` counts
native broadcast calls, and neither proves receipt. `transportFailures` counts
throwing fire calls; `transportLosses` counts observed terminal transport loss.

Counters saturate at 4,294,967,295 and retain no player identities, payloads,
stacks, or logging history. There are 15 session counters and eight per event,
at most 143 counters under the current event limit. Cleanup makes active leases
zero in terminal snapshots; user callbacks may still be suspended. Late callbacks
do not update terminal counters. Caller-retained snapshots are caller-owned memory.

Reliable transport can still lose application callbacks to these admission and
handler guards. Diagnostics do not establish fairness, bandwidth, receipt,
engine-drop reasons, or a native unreliable size guarantee.

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
