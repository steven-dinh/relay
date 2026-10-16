# Relay API reference

This file on mutable `main` describes development source version `0.2.0`; its
API and protocol details may change. Starting with v0.2.0, each published
release tag preserves its API reference. See the [published v0.2.0 reference](https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md).
Development source may differ even while `Relay.VERSION` remains `0.2.0`; the
[current development reference](https://github.com/steven-dinh/relay/blob/main/docs/reference.md)
tracks changes on `main`.

## Environment, support, and reporting

For a published install, download the [v0.2.0 model](https://github.com/steven-dinh/relay/releases/download/v0.2.0/Relay-v0.2.0.rbxmx)
and import it into `ReplicatedStorage`; use its [matching API reference](https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md)
and [reliable-events example](https://github.com/steven-dinh/relay/tree/v0.2.0/examples/reliable-events).
The matching [source ZIP](https://github.com/steven-dinh/relay/releases/download/v0.2.0/Relay-v0.2.0-source.zip)
is also available.

Relay runs in Roblox. Import the built model into `ReplicatedStorage` and make
the shared definition ModuleScript available to both sides. Create server
sessions from server code (normally a `Script`) and client sessions from a
`LocalScript`; the constructors enforce `RunService:IsServer()` and
`RunService:IsClient()` and otherwise return `WrongRuntimeSide`. See the
[development setup](../README.md#development-setup) and
[examples](../examples/README.md). Lune runs portable verification; it does not
provide live Roblox transport.

Runtime requires Roblox's `buffer` and `task` libraries and `RemoteEvent`.
Unreliable events also require `UnreliableRemoteEvent`; requests and listener
readiness use `HttpService:GenerateGUID()`. These APIs are requirements, not an
inferred minimum engine build.

Use the development tools and versions pinned in [`rokit.toml`](../rokit.toml):
Lune, Rojo, Wally, and luau-lsp. Strict consumer type analysis
requires the new Luau solver; enable `Workspace.UseNewLuauTypeSolver` in Studio
or use `luau-lsp` with `--flag:LuauSolverV2=true`.

Recorded native installation/compatibility checks include the exact published
v0.2.0 and one isolated offline candidate on Windows Studio 0.742.0.7421053,
with one server and two clients.
Those exact runs set no minimum Studio build or device matrix and do not prove
every current source tree. No minimum supported Studio version is established.

Report ordinary bugs in the [GitHub issue tracker](https://github.com/steven-dinh/relay/issues).
Include a minimal reproduction, exact Relay tag or commit and whether the source
was dirty, Studio build, execution context, expected and actual behavior, and any
Relay error code. Omit secrets and real-player payloads. Report vulnerabilities
through the [private GitHub reporting route](https://github.com/steven-dinh/relay/security/advisories/new).
Relay maintains the latest patch of the newest released minor series; older
versions should upgrade. See the [security and maintenance policy](../SECURITY.md)
for response, disclosure, compatibility, and deprecation details.

### Common recovery

| Situation | Next step |
| --- | --- |
| `InvalidDefinition` | Fix any reported path and reason in the shared definition. For `inspect` or session creation, use a definition returned by `Relay.define` from the same loaded Relay copy. See [event and schema rules](#events). |
| `DefinitionMismatch` | Recreate the client with the server's definition; follow the [coordinated upgrade recipe](../examples/README.md#coordinated-definition-upgrades). |
| FIFO `QueueFull` | Treat as pressure. The record was not added; reduce burst/payload size and retry only under an application backpressure policy. See [FIFO batches](#explicit-fifo-batches). |
| A readiness claim may have been dropped | Call `RefreshReadiness()` once. It reports handoff, not delivery; see [listener readiness](#optional-listener-readiness). |
| Request `RequestTimeout` or `Cancelled` | Check server-side effects before retry. Use an operation ID and server-owned idempotency when retries must avoid duplicates; see [requests](#requests). |
| State after a join/restart or audience change | Supply current snapshots from game state and create a lane for the intended audience; Relay does not replay handed-off snapshots. See [State queues](#latest-unsent-state). |

## Protocol and abuse limits

The protocol contract and ingress limits are:

- **Version compatibility:** startup requires identical compiled definition
  descriptors and matching remote topology. The schema's `version` is included
  in that descriptor; matching `Relay.VERSION` or schema version alone is
  insufficient. Reliable-only primitive definitions use `RR1`. Definitions using
  structs, arrays, enums, optionals or sets use `RR3`, request-bearing definitions
  use `RR5`, and optional readiness or queued-event metadata selects `RR6`.
  `RR7` takes precedence when any unreliable event has only primitive fields,
  including zero fields: those events now use checked buffers instead of the
  legacy native-tuple representation. Both sides must use updated Relay copies;
  old descriptors, including `RR2`, fail startup equality without a fallback.
  Definitions without this representation change retain their descriptor bytes.
  Empty request maps and disabled feature metadata retain the earlier descriptor
  bytes. Descriptor equality covers every selected feature.
  There is no version negotiation, downgrade, or cross-version fallback.
  The 64-endpoint limit preserves existing descriptor bytes and payload formats;
  definitions above the earlier 16-endpoint limit require updated Relay copies on
  both sides. The 4,096-byte descriptor cap still applies independently.
  The [coordinated upgrade recipe](../examples/README.md#coordinated-definition-upgrades)
  shows a concrete changed event, mismatched startup, fresh matching session,
  and rollback to a complete matched definition.
- **Maximum encoded size:** the definition descriptor is capped at 4,096 bytes.
  Reliable native tuples have at most eight fields, with each string capped by its declared
  `maximumBytes` (0..1024), at most 8192 string-content bytes per event. Relay
  has no encoded-size cap for reliable native tuples. Every unreliable event and
  every reliable event containing a composable shape encodes its entire tuple into one buffer:
  at most **8192 raw bytes for Reliable or 900 for Unreliable**, including a
  three-byte version/endpoint header and all length prefixes. Definition rejects
  schemas whose worst case exceeds that cap with `InvalidDefinition`; sends reject
  invalid or oversized values with `InvalidPayload` before a transport call. The
  encoder checks actual normalized size before allocating the output buffer.
  `Color3` contributes 12 bytes per value (R/G/B Float32), with finite components
  in `0..1`; it uses the same total-byte, container, depth and node limits. A
  primitive Color3 buffer frame is 15 bytes including the three-byte header.
  Tagged unions add one ordinal byte to the selected struct body. Their worst
  case includes the largest variant; a smaller alternative does not relax any
  byte cap. An unreliable union variant with one string can declare at most
  894 content bytes (three-byte header, one tag byte and two-byte string length).
  A lone unreliable string can declare at most 895 content bytes: its two-byte
  length and the three-byte header fill the 900-byte cap. These exact Relay buffer limits
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
  Tagged unions have 1..32 named struct variants. Their implicit discriminator
  counts toward the eight-field struct cap, leaving at most seven fields per
  variant. A union adds one depth level and one expanded node to its worst
  variant, including that variant's struct level/node. Every alternative counts
  toward the shared authored-node limit, including alternatives not selected by
  a payload. Tag fields and variant labels use Relay's 1..32-byte name grammar.
- **Admission budgets:** an active, intact server admits only current rostered
  players. Each attempt costs one per-player token, then one shared aggregate
  token, before endpoint/channel or payload validation. Both delivery channels
  share those buckets. Per-player exhaustion leaves the aggregate untouched;
  aggregate exhaustion does not refund the player's token. Malformed and
  wrong-channel attempts receive no refund. These base charges are per call;
  the optional content-byte budget below charges separately. The byte, depth
  and expanded-node caps bound composite decode work
  under these same charges.
  Optional server-local `inboundRate.endpoints` adds per-player rate/burst buckets
  for known client-to-server event and request IDs, after these shared charges.
  Correctly routed immediate events and known RPC methods spend their endpoint
  token before payload body decoding, listener or handler checks. Rejected
  attempts retain every earlier charge. These limits leave descriptor bytes,
  payload formats and startup compatibility unchanged.
  Optional server-local `inboundRate.bytes` adds per-player and aggregate content-
  byte budgets after the first shared call-token pair, before endpoint lookup or
  header parsing. Both channels and all inbound routes share these budgets.
  A byte refusal retains that first pair and stops before any later queued-record
  or endpoint charges. Admitted malformed traffic retains its byte charges.
  [Lifecycle and admission](#lifecycle-and-admission) defines buffer/native-tuple
  accounting, configuration bounds and first-rejection order.
  A counted format-2 client batch or state frame pays one pair for its first logical
  record, passes optional byte admission, then attempts another `N - 1` pairs for
  the remaining declared records, using the original timestamp. A count that cannot
  be trusted costs only the first pair. Exhaustion aborts before record scanning
  or body copies; if all N pairs are admitted, a later malformed record keeps
  the full N charges. Exhausted or malformed attempts are never refunded.
  After complete batch/state framing and endpoint/channel checks, each row spends
  its endpoint token in order, before any body copies or payload decoding.
  Immediate, FIFO and State paths share those buckets. Endpoint exhaustion drops
  the whole frame, retaining all N shared charges and earlier endpoint charges;
  later endpoint buckets are untouched. A later malformed body retains all N
  applicable endpoint charges. Invalid framing pays the existing shared charges
  without spending endpoint tokens.
  Handler concurrency caps apply; see [Lifecycle and admission](#lifecycle-and-admission).
- **Optional readiness controls:** `readiness = true` selects RR6 (or RR7 above) and requires at
  least one ServerToClient event. The reliable endpoint-zero controls use format
  2: Hello is 2 bytes, Challenge 42, Ack `82 + W`, and Close 78, where
  `W = ceil(ServerToClient event count / 8)`. Events are ordered by ID for the
  listener-bit map. With the current 64-entry definition cap, `W` is at most 8
  and a control buffer at most 90 bytes. The exact control lengths, direction,
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

Definitions are immutable opaque tokens. Define 1–64 events and requests combined,
with unique IDs across both maps and at most 8 request/event fields each.
The encoded descriptor is limited to 4,096 bytes, so a schema
within those counts can still be rejected. Primitive types are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`,
`i32`, `f32`, `Vector2F32`, `Vector3F32`, `CFrame`, and `Color3`. Integer fields may narrow their bounds; floats and vectors require
finite Float32-exact `minimum` and `maximum`. Values must be finite and within
bounds before and after Float32 rounding; scalar/vector negative zero becomes positive zero.
The additional composable shapes below allow bounded plain tables. User-supplied
buffers, Instances, arbitrary maps and recursive shapes remain unsupported.
The shared definition determines event names, direction-specific methods, and
ordered argument types for both sessions. Integer and float fields have Luau type
`number`; numeric bounds, integer checks, string byte limits, and game permissions
still require runtime validation. Listener callbacks may ignore trailing arguments.

The constructors are `ordered`, `field`, the thirteen primitive kind names,
`struct`, `taggedUnion`, `array`, `enum`, `optional`, `set`, `clientToServer`, `serverToClient`,
`request`, and `compose`.
Their arguments match the raw grammar: for example `s.string(128)`,
`s.i16(-100, 100)`, `s.Color3()`, `s.array(element, 16)`, and
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
Raw records and the original [ordered helper](../examples/reliable-events/ordered.luau)
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
the current 64-entry and 4096-byte descriptor limits and copies the complete
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
Each vector occupies one tuple field. Reliable primitive-only events send native
Roblox values; unreliable and composite events encode the components as described below.

On reliable primitive-only events, integer values travel as native numbers without a
packed wire-width promise. Unreliable and composite events use the declared integer width.
There is no integer rounding.

`Color3` accepts actual Roblox `Color3` values and has a fixed inclusive RGB
domain of `0..1`. Use `s.field("tint", s.Color3())` or the raw field
`{ name = "tint", type = "Color3" }`; custom `minimum`/`maximum` and other keys
are rejected. Each original component must be finite and in range before and
after Float32 normalization. Relay canonicalizes negative zero to positive zero
and rejects invalid values rather than clamping them. Typed sends, listeners,
requests/responses and batch/state handles use Roblox `Color3`, including inside
structs, arrays and optionals. Color3 is one primitive node at depth zero and
is excluded from set keys.

Reliable primitive Color3 events retain native tuples; forced-codec contexts use
three Float32 components in R/G/B order. The decoder checks all 12 bytes and raw
component bounds before construction, then verifies the reconstructed components.
The descriptor adds the distinct `c3f32` type code using existing protocol and
shape grammar. Definitions using Color3 need updated copies on both sides;
definitions without Color3 retain their descriptors and payload representations.
Buffer lengths describe Relay content, with Roblox transport encoding unmeasured.

`CFrame` requires finite Float32-exact translation bounds for X, Y, and Z.
Its rotation must be approximately orthonormal and right-handed: every entry
lies in [-1.0001, 1.0001], each column's squared length differs from 1 by at most
0.0001, pairwise column dot products have magnitude at most 0.0001, and the
determinant differs from +1 by at most 0.0001. All components must be finite.
Slight scale/shear within those fixed tests is accepted; Relay does not repair
or normalize matrices. Accepted local CFrames retain all components and zero
signs unchanged. Roblox controls native remote precision. Unreliable and composite events
encode twelve f64 components and require exact reconstruction, including zero signs.

String fields require integer `maximumBytes` from 0 through 1024. Zero allows
only the empty string. Length counts bytes, including NUL, non-UTF8 bytes, and
each byte of multibyte text; accepted strings are unchanged. Text policy belongs
to the caller. A reliable primitive-only event's string-content bound is the sum of its
declared limits, at most 8192 bytes across eight string fields. Unreliable and composite events
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

### Tagged unions

`s.taggedUnion(tag, variants)` describes a plain table whose literal tag selects
one struct. Each branch has its own required fields and exact runtime key set:

```lua
local resultShape = s.taggedUnion("kind" :: "kind", {
    Success = s.struct((s.field("itemId" :: "itemId", s.u32()))),
    Rejected = s.struct((s.field("reason" :: "reason", s.string(64)))),
})
-- Use s.field("result", resultShape) in an event or request.
-- Payload type:
-- { kind: "Success", itemId: number } | { kind: "Rejected", reason: string }
```

Checking `result.kind == "Success"` narrows the payload to the branch containing
`itemId`. Event/listener/audience, request/response and batch/state types retain
that union, including inside structs, arrays and optionals. Union tag names need
singleton annotations under the pinned solver, as do struct field names.

The raw shape is `{ type = "taggedUnion", tag = "kind", variants = { ... } }`,
with the same anonymous struct shapes as map values; add `name` only when naming
the outer field. The union accepts only these keys. The variants map must be a
plain table with 1..32 literal labels; both the tag name and labels must be valid
Relay names. Each variant has at most seven fields, with no field named after
the tag, so its payload has at most eight keys including the discriminator.
An empty struct variant produces a tag-only table. Tagged unions are not set keys.
Missing/unknown/non-string tags, missing required fields, fields from another
branch, extra keys and metatables reject with `InvalidPayload`; no branch is
chosen by trial validation. Existing child bounds still apply.

The helper freezes its outer record and a shallow copy of the variants map;
`define` independently validates, copies and freezes every branch. Each accepted
payload gets fresh normalized/decoded tables. The wire stores a zero-based
one-byte ordinal in sorted label order, followed by the selected struct's body.
The tag name and label are restored from the definition. The decoder checks
the tag byte and selected branch's minimum size before branch allocation and
rejects unknown ordinals, truncated bodies and trailing bytes before dispatch.
Queued frames still decode every record before any callback.

Tagged unions force the existing whole-tuple buffer codec. Minimum bytes are one
plus the smallest branch minimum; maximum bytes, depth and expanded nodes use
the largest respective branch bound plus the union's byte/level/node. All
alternatives count toward the 256 authored-node budget. The descriptor adds a
distinct `U` shape token containing the tag and sorted named branch schemas;
definitions using unions require updated peers. Non-union descriptors and
payload representations remain unchanged. Full buffer/envelope byte admission
includes the tag once, with existing call, endpoint and handler charging intact.

Composite and unreliable events encode every field in declaration order. The buffer begins
with format version 1 and a little-endian u16 endpoint ID, which must match the
outer endpoint. Booleans and optional presence use one byte (0/1); enum ordinals
use one byte; tagged unions use one ordinal byte plus the selected struct body;
integer widths follow their type; f32 and vector components use
four bytes each. Color3 uses three f32 RGB components (12 bytes); CFrame uses
twelve f64 components. Strings have a u16 byte
length, arrays and sets have a u16 count, and structs omit their known field
names. The decoder checks remaining bytes before each read and count limits
before container allocation. Invalid tags/values, trailing data, and duplicate
set members are rejected before dispatch.
Reliable primitive-only events continue using native tuples inside any definition.

## Sessions

On the server, explicitly choose finite ingress limits and connect before startup:

```lua
local serverResult, createServerError = Relay.createServer(Events, {
    inboundRate = {
        perPlayer = { capacity = 120, refillPerSecond = 60 },
        aggregate = { capacity = 960, refillPerSecond = 480 },
        -- Optional: the client-to-server endpoint with ID 1 gets its own ceiling.
        endpoints = { [1] = { capacity = 8, refillPerSecond = 4 } },
        -- Optional: content-byte burst and refill per second across inbound calls.
        bytes = {
            perPlayer = { capacity = 65536, refillPerSecond = 32768 },
            aggregate = { capacity = 524288, refillPerSecond = 262144 },
        },
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
See [the complete examples](../examples/reliable-events).

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
recipients are not promised. Historical two-client Studio proof from October 7,
2026 passed 23 correctness checkpoints, including FIFO and readiness, and four
admission checkpoints for frozen Relay source
`8a4ccd243eb0e47dbac866fdf490de666fdc8b39` on Studio `0.742.0.7421053`.
That proof qualifies the covered scenarios on that source and engine; native
verification of a changed checkout requires a separate run.

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
slot; a later accepted Put replaces only its pending body and priority. The key
and priority are sender-local metadata; receivers get only the declared payload
fields. Include an entity ID in those fields when the receiver needs it.
Priorities are exactly High, Normal, or Low. Invalid payloads or overflow leave
the previous snapshot intact. Across all lanes, a sending session owns at most
four lanes, 64 active keys, and 16384 pending body bytes. Active keys persist
after handoff until Remove or Destroy; Remove sends no deletion message.

Flush expires pending values at one second from their first dirty submit;
replacements do not extend that age. A Put after handoff, expiry, or Remove starts
a new pending age. Queue service and accepted Put calls remove expired bodies;
platform scheduling can delay service beyond that cutoff. Within each channel it
selects High before Normal before Low, then older first-dirty time, event ID, and
key, fitting at most 32 records and 8192 Reliable/900 Unreliable raw bytes.
Reliable is handed off first. Unselected work remains bounded for later service.
Automatic service uses one timer per lane; platform scheduling can delay its target.

The six-number report uses the same local handoff units as FIFO. `selected`,
`remaining`, and `expired` describe local snapshots. Selected bodies leave the
queue before handoff, including a failed handoff; Relay does not retry. State
Flush keeps the lane open, and GetStatus returns a frozen snapshot of its state,
active/pending keys, pending body bytes, and one last flush result. Destroy is
idempotent and clears timers, bodies, keys, and audience references. FIFO and
state share one flush guard; reentrant mutation returns QueueBusy.

Game code owns authoritative state and the receiver's stored state. Relay's queue
retains unsent encoded snapshots and local queue keys; it does not keep handed-off
snapshots for replay or automatically replay state for late joiners. Joining
Players are not added to a captured audience. Supply their initial current
snapshot from game state and create a lane with the intended audience when that
audience changes.

Replacement concerns unsent values. Unreliable updates can still drop or arrive
out of order after handoff. Include an application tick/sequence and filter stale
values in the receiving handler when needed. Readiness is a listener claim;
the game still owns audience selection and authorization.

For an application recipe covering shared queue pressure, failed handoffs,
key release and current-state submission after an audience rebuild, see the
[State example](../examples/README.md#queue-pressure-and-failed-handoffs).

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

The [State example's readiness recipe](../examples/README.md#readiness-and-audience-changes)
intersects listener claims with a game-authorized audience, handles an empty
snapshot, rebuilds the fixed lane explicitly and exposes a one-shot client
refresh hook. Its scripts are checked by the pinned public type gate.

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
It does not stop the server handler or release its server-side reservation.
Timeout and cancellation leave the outcome of server side effects uncertain.
If game code submits the operation again, the new `Request` has a new identity and
may execute again. Use an application operation ID and server-owned idempotency
policy when such retries must avoid duplicate effects.

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
batch makes its cached `Flush` result `Cancelled`. State operations also use
`InvalidStateKey` and `InvalidPriority`.
Path diagnostics from `Relay.define` identify
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
If `Start` returns `DefinitionMismatch`, that client session is terminal. Create
a fresh client from the definition that matches the server's descriptor; do not
retry the same handle or edit the server-owned descriptor value. On transport
loss, settle application work and create new matched sessions. The
[upgrade example](../examples/README.md#coordinated-definition-upgrades)
explains rollout and rollback boundaries.

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

`inboundRate.endpoints` is optional. Each numeric key must identify a defined
client-to-server event or request; unknown IDs and server-to-client events return
`InvalidOptions` from `createServer`. Each row uses `capacity` for the burst
(integer `1..4096`) and `refillPerSecond` for the sustained rate (finite,
`0 < rate <= 2048`). Maps and rows must be plain tables with only their declared
keys. Limits are copied at creation; changing caller tables later has no effect.
Omitted IDs have no additional endpoint ceiling, and an absent or empty map keeps
the existing admission behavior. Shared player and aggregate budgets still apply
first. At most 64 endpoint buckets are owned per rostered player; removing the
player or ending the session clears them. Replacing a listener does not reset them.

Endpoint admission follows endpoint/direction/channel checks for immediate events.
For RPC it follows the bounded envelope peek and known method lookup, before
replay/listener/busy checks, body copy or decoding. Unknown endpoints, wrong
channels and malformed RPC envelopes spend only the existing shared charges.
Known correctly routed malformed payloads, absent listeners and busy handlers
spend the endpoint token too. Readiness controls use only the shared budgets.
An endpoint-limited RPC is silently dropped, as with other inbound rate limits;
the client's existing pending request deadline determines its timeout. Endpoint
limits add ceilings; they do not provide byte/work accounting or fairness.

`inboundRate.bytes` optionally adds a shared content-byte budget per player and
one for the whole server. Both `perPlayer` and `aggregate` rows are required and
use `capacity` for the integer byte burst (at least one) and `refillPerSecond` for
the finite positive byte rate. Per-player maxima are capacity `33554432` and refill
`16777216` per second; aggregate maxima are capacity `268435456` and refill
`134217728` per second. Each aggregate value must be at least its per-player
counterpart. Maps and rows are plain tables with only their declared keys;
invalid configuration returns `InvalidOptions`. The copied, frozen policy is
server-local and changes no descriptor or payload format. Omitting it preserves
existing admission behavior.

The byte gate runs after the initial per-player then aggregate call-token pair,
before endpoint lookup, header reads, payload body copies or decoding. It takes
the player byte budget first, then the aggregate byte budget, using the same
incoming timestamp. Player byte refusal leaves aggregate bytes untouched;
aggregate byte refusal retains successful player byte charges. An insufficient
take leaves that bucket's remaining bytes intact. Earlier successful charges
are never refunded, including for malformed, oversized, unknown-endpoint,
wrong-channel, listener-less or busy traffic. A byte-refused FIFO/State frame
retains the initial call-token pair and stops before its additional logical-
record or endpoint charges, with no partial callbacks. Once byte admission passes,
all existing logical-record and endpoint charging continues unchanged. RPC
refusal is silent and retains the client's existing deadline. Readiness controls
also consume bytes. Player removal and terminal cleanup release byte buckets;
listener replacement does not reset them.

These are deterministic Relay content units; Roblox envelope/compression bytes
and engine work before the callback remain unmeasured. A single buffer argument
costs its full raw length, including its Relay header/envelope once, with a
minimum charge of one. Other calls cost a three-byte logical header allowance
plus each actual argument's content charge:

| Argument | Admission bytes |
| --- | --- |
| `boolean` | 1 |
| `number` | 8, regardless of schema integer width |
| `Vector2` / `Vector3` | 8 / 12 |
| `Color3` | 12 |
| `CFrame` | 96 |
| `string` | 2 + byte length |
| `buffer` in a mixed tuple | raw byte length |

The estimator examines at most eight arguments without packing or traversing
tables. An invalid outer endpoint selector (anything other than an integer
`0..65535`), more than eight arguments, or an unsupported argument type is byte-
refused. This includes tables, Instances and explicit nil; valid optional payloads
use Relay buffers. Native charges are conservative content accounting rather
than measured native transport encoding. Existing size, schema, queue, replay,
pending-request and handler caps still apply after byte admission.

Relay silently drops malformed, rate-limited, listener-less, and handler-capacity
exceeding traffic. A yielding handler retains its slot: one per player/endpoint,
at most 8 per player and 64 server-wide; client handlers allow one per endpoint.
Immediate events and requests have no waiting queue. Explicit FIFO batches are
opt-in through queue-capable events; replacing a listener does not reset an
occupied handler slot. Handler errors are contained. Removal and destruction
prevent late completions from recreating Relay's internal state.

Handlers must return normally or raise an error. For cooperative cancellation,
set an application-owned flag and have the handler check it after yielding,
then return before applying unwanted effects. Externally terminating the thread
running a Relay event, queued-event or RPC handler with `task.cancel` or
`coroutine.close` is unsupported: it can skip Relay's post-handler cleanup and
leave its reservation occupied. Disconnecting or replacing the listener does not
repair that reservation. Server player removal or session teardown clears the
corresponding accounting; client transport loss also tears down its session.

Disconnect, player removal and session teardown do not stop an already-running
application callback. Guard its late side effects in application code. A terminal
`inFlight = 0` snapshot means Relay released its bookkeeping, not that all
application work has stopped.

## Diagnostics and budget inspection

`Relay.inspect(definition)` returns a deeply frozen report or `InvalidDefinition`
for a token from another loaded copy or a forged token. It lists protocol,
descriptor bytes, current limits, and each event's direction, delivery, depth,
expanded nodes, and byte representation. `RelayBuffer` rows expose exact minimum
and maximum raw buffer bytes. `NativeTuple` rows expose declared string-content
bounds and `robloxEncodedBytes = "Unknown"`; packed numeric widths are not native
wire-size promises. Every unreliable row is `RelayBuffer` with a 900-byte limit.
Raw buffers exclude Roblox's envelope and compression; `robloxEncodedBytes` remains
`"Unknown"` for both representations.
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
eligibility/shared call rate, optional player/aggregate bytes, endpoint/channel,
endpoint rate, listener, busy, then payload
(RPC envelope and replay checks retain their order described above). `endpointRate`
counts refusals by the optional endpoint bucket, in the session and the known
event's row; RPC refusals remain session-only. Frozen `inboundRate` snapshots also
include the configured endpoint policies. Format-2 FIFO/State ingress first charges
the initial call-token pair and passes optional byte admission before charging
its remaining declared logical-record count, then scans metadata, applies endpoint
admission and decodes every body before listener and busy checks. Structural failures are
session-level `invalidPayload`; a known wrong endpoint or channel uses
`invalidEndpoint` or `wrongChannel`; a body decode failure after resolving its
event is attributed to that event. `received` counts receive callbacks (one
envelope), while `dispatched` counts admitted logical callbacks;
`handlerErrors` counts contained errors while the session remains started.
`sendHandoffs` counts successful targeted fire calls, `broadcastHandoffs` counts
native broadcast calls, and neither proves receipt. `transportFailures` counts
throwing fire calls; `transportLosses` counts observed terminal transport loss.

`perPlayerBytes` and `aggregateBytes` count the first byte-budget refusal at
session level, before endpoint resolution; unmeasurable input counts as
`perPlayerBytes`. Frozen `inboundRate` snapshots include the byte policy when
configured. Snapshots never sample a clock, refill buckets or expose live balances.

Counters saturate at 4,294,967,295 and retain no player identities, payloads,
stacks, or logging history. There are 18 session counters and nine per event,
at most 594 counters under the current event limit. Cleanup makes active leases
zero in terminal snapshots; user callbacks may still be suspended. Late callbacks
do not update terminal counters. Caller-retained snapshots are caller-owned memory.

Reliable transport can still lose application callbacks to these admission and
handler guards. Diagnostics do not establish fairness, bandwidth, receipt,
engine-drop reasons, or exact Roblox encoded sizes.

These are remote-abuse and resource-exhaustion limits on Relay-owned work.
Roblox supplies transport and Player identity; Relay buffers add no authentication
or encryption and provide no infrastructure DDoS protection. Roblox incurs engine
ingress and argument materialization costs before Relay's Luau guards run. These
limits do not bound Roblox traffic, scheduling, or a developer handler's own work.
A shared aggregate limit does not guarantee fairness. Game code owns authorization,
ownership, cooldowns, costs, persistence, and replay policy. Roblox's
[client-server boundary guidance](https://create.roblox.com/docs/scripting/security/client-server-boundary)
describes those application responsibilities.

The isolated real Studio correctness proof is `lune run
tests/studio-reliable-events.luau`; it is separate from the portable aggregate
verifier and from timing benchmarks. Relay makes no performance ranking claim.
Append `--correctness-only` to run the two-client correctness scenario during
development; omit it for the full correctness and admission matrix.
