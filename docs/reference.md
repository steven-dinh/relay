# Relay API reference

This file on mutable `main` describes private, unreleased development
source version `0.3.0`; its API and protocol details may change.
Starting with v0.2.0,
each published release tag preserves its API reference. See the [published v0.2.0
reference](https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md).
Development source may differ even while `Relay.VERSION` remains `0.3.0`; the
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
Unreliable events also require `UnreliableRemoteEvent`; requests, listener
readiness, and ordered client-to-server events use `HttpService:GenerateGUID()`.
These APIs are requirements, not an inferred minimum engine build.

Use the development tools and versions pinned in [`rokit.toml`](../rokit.toml):
Lune, Rojo, Wally, and luau-lsp. Strict consumer type analysis
requires the new Luau solver; enable `Workspace.UseNewLuauTypeSolver` in Studio
or use `luau-lsp` with `--flag:LuauSolverV2=true`.

With luau-lsp `1.70.1`, also pass
`--flag:LuauDontBlockRefinementUnconditionally=false`. Its default enabled flag
can lose schema inference when `assert` narrows an optional definition. In editor
settings, put `"LuauDontBlockRefinementUnconditionally": "false"` in
`luau-lsp.fflags.override`. The verifier uses this override with Solver V2 enabled;
remove it only when the same consumer checks pass without it.

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
| `OutboundRateLimited` | A selected player's outbound byte budget refused this send or RPC response. FIFO retries require explicit `Flush()`; State lanes can opt into bounded automatic deferral. Inspect `GetStatus()` before deciding what to retain or replace. |
| FIFO `QueueFull` | Treat as pressure. The record was not added; reduce burst/payload size and retry only under an application backpressure policy. See [FIFO batches](#explicit-fifo-batches). |
| A readiness claim may have been dropped | Call `RefreshReadiness()` once. It reports handoff, not delivery; see [listener readiness](#optional-listener-readiness). |
| Request `RequestTimeout` or `Cancelled` | Check server-side effects before retry. Use an operation ID and server-owned idempotency when retries must avoid duplicates; see [requests](#requests). |
| State after a join/restart or audience change | Supply current snapshots from game state and create a lane for the intended audience; Relay does not replay handed-off snapshots. See [State queues](#latest-unsent-state). |

## Upgrade compatibility

The `0.3.0` source is a private, unreleased development candidate. Startup
compares the complete compiled definition descriptor and remote topology;
neither `Relay.VERSION` nor the schema's numeric `version` proves compatibility.

| Definition or change | Peer requirement and effect |
| --- | --- |
| Unchanged compatibility fixtures for `RR1`, `RR3`, `RR5`, or `RR6` | These fixtures pin selected descriptors and wire bytes to established goldens. A `Relay.VERSION`-only change does not alter them. This portable regression evidence does not qualify mixed-version startup; support remains limited to separately verified old/new peer pairs with identical descriptors and remote topology. |
| Primitive unreliable events that were `RR2` and now select `RR7` | Use updated Relay copies with the same definition on both sides. An old `RR2` peer fails startup with `DefinitionMismatch`; there is no fallback. |
| More than 16 endpoints or readiness listeners, up to the `64`-item limit | Both peers need updated copies and the same definition. The expanded readiness mask supports 64 listeners in a 90-byte Ack. |
| Opting into `OrderedUnreliable` (`RR8`) | Both peers need RR8-capable copies and the same opt-in definition. Definitions without ordered events retain their existing descriptor. |
| `Color3`, `Color3RGB8`, or tagged-union shapes | Both peers need copies that support the shape and the same updated definition. |
| Native Roblox shapes or native enum allowlists | Both peers need copies that support the shape and the same updated definition; existing definitions without them retain their descriptors and payload representations. |
| Quantized scalar shapes (`RR10`) | Both peers need quantization-capable copies and the same bounds and step; definitions without quantized scalars retain their descriptors and payload representations. |
| Quantized `Vector2` / `Vector3` shapes (`RR11`) | Both peers need vector-capable copies and matching bounds and step; existing definitions retain their descriptors and payload representations. |
| Compact CFrames (`RR12`) | Both peers need compact-CFrame-capable copies and matching position bounds and step. Legacy `CFrame` representation is unchanged. |
| Definition `bitPacking = true` (`RR13`) | Both peers need packed-codec-capable copies and the same definition. Definitions without the option retain their descriptors and payload representations. |
| Definition `outboundBytes` policy (`RR14`) | Both peers need copies that understand the matching policy and RPC refusal response. Definitions without the policy retain their descriptors and behavior. |
| Bounded buffer shapes (`RR15`) | Both peers need buffer-capable copies and matching byte caps. Definitions without buffers retain their descriptors and payload representations. |
| Extended RPC, bounded formats, or extended Instance routes (`RR16`) | Both peers need matching RR16 copies and settings. Default RPC options and omitted minimum lengths retain earlier descriptors and bytes. |

Deploy the server, client, and shared Definition as one application revision.
Start fresh matching sessions and keep the previous complete revision for
rollback. Reconcile an uncertain RPC with an application operation ID and
server-owned idempotency before retrying. Seed State from authoritative game
state after a new session starts; Relay does not replay it. The [coordinated
upgrade recipe](../examples/README.md#coordinated-definition-upgrades) shows
the session replacement and full-revision rollback sequence.

## Protocol and abuse limits

The protocol, size, and admission contract is:

- **Transport namespaces:** constructor options may select one explicit namespace,
  with at most eight named sessions plus the default per runtime side in one
  serial Luau VM. Each retains its own existing admission, packet, endpoint,
  readiness, queue and handler limits; total authored resources can therefore
  reach nine session limits. Namespace selection changes discovery only, with no
  descriptor or payload bytes added. Payloads cannot create a namespace or reset
  its budgets. Namespaces provide independent ownership, not caller permissions;
  firing any visible remote still enters that session's validation and admission.
  See [Lifecycle and admission](#lifecycle-and-admission).
- **Version compatibility:** startup requires identical compiled definition
  descriptors and matching remote topology. The schema's `version` is included
  in that descriptor; matching `Relay.VERSION` or schema version alone is
  insufficient. Without newer opt-in capabilities, reliable-only primitive
  definitions use `RR1`. Definitions using structs, tagged unions, arrays, maps,
  enums, optionals or sets use `RR3`; request-bearing definitions use `RR5`, and
  optional readiness or queued-event metadata selects `RR6`.
  `RR7` takes precedence when any unreliable event has only primitive fields,
  including zero fields: those events now use checked buffers instead of the
  legacy native-tuple representation. Both sides must use updated Relay copies;
  old descriptors, including `RR2`, fail startup equality without a fallback.
  Definitions without this representation change retain their descriptor bytes.
  Empty request maps and disabled feature metadata retain the earlier descriptor
  bytes. Descriptor equality covers every selected feature.
  Opt-in ordered unreliable events select `RR8` with a distinct `O` delivery
  marker. Definitions without ordered events retain their existing descriptors;
  definitions using them require updated copies on both sides.
  Definitions with Instance references add `|I4,16,8`; each class name is
  length-prefixed in the shape descriptor. If no higher capability applies,
  they select `RR9`. The marker remains when references are combined with newer
  capabilities. Definitions without references keep their current descriptor
  and payload bytes.
  Scalar quantization adds the `|Q1,65536` marker, including when the scalar is
  in an RPC or a zero-capacity shape. A definition whose highest selected
  capability is scalar quantization uses `RR10`. The marker pins the quantization
  revision and level limit; each quantized leaf
  records its exact binary64 bounds and step, derived level count, and encoded
  width. Quantized definitions require matching updated peers; definitions
  without quantization keep their existing descriptors and payload
  representations.
  Quantized Vector2/Vector3 shapes add `|VQ1`; when no higher capability
  applies, they select `RR11`. Each leaf pins its vector kind, exact binary64
  bounds and step, scalar level count, and per-axis code width. Compact CFrame
  shapes add `|CF1`; when no higher capability applies, they select `RR12`.
  Each leaf pins its exact bounds and position step, scalar level count and
  width, and the XYZ-u16 rotation representation. Vector and compact-CFrame definitions need
  matching updated peers; old numeric and native CFrame definitions retain
  their existing descriptors and payload representations.
  A definition with `bitPacking = true` adds `|BP1` and selects `RR13` unless
  outbound bytes or buffers select a higher capability, even when its event tuples have no packable
  fields. The marker pins the packed
  block grammar; native Roblox enum values and tagged-union discriminators keep
  their existing representation. Definitions without bit packing preserve
  their descriptors and payload bytes.
  A definition with `outboundBytes` selects `RR14` unless buffers select `RR15`, and adds `|OB1` with the
  exact binary64 refill rate and byte capacity. The marker also enables the
  explicit RPC `OutboundRateLimited` response. Its policy is a shared definition
  capability, so both peers must use matching settings. Definitions without it
  retain their descriptors and RPC behavior. When several capabilities are
  enabled, the highest RR number wins and all applicable markers and per-shape
  tokens remain in the descriptor.
  Any authored buffer shape, including under a zero-capacity collection, selects
  `RR15` and adds `|BUF1,2,8187`. Each buffer leaf adds `B<maximumBytes>;`.
  Matching peers must agree on the exact cap and checked u16-length grammar;
  there is no decoder fallback. Existing feature markers remain present.
  New numeric formats, wide quantization or explicit minimum counts select
  `RR16` and add `|BND1`. Extended RPC adds `|RPC2,7`, and Instance references on
  unreliable or queued routes add `|IR2,5,6`. RPC direction, per-method concurrency,
  refusals, and every length range enter the descriptor. Explicit default RPC
  options canonicalize to the legacy descriptor. Omitted minimum counts keep
  their legacy absolute u16 prefixes; explicit minima use the bounded offset
  grammar described below. No capability falls back to an older wire format.
  Client-to-server `timestampWindow` selects `RR17` and includes its exact window
  in a `|TW` descriptor token. The declared f64 timestamp stays inside existing
  payload/frame bounds; see [Client send timestamps](#client-send-timestamps).
  Maps add an `M` shape token containing their capacity and key/value schemas.
  Map definitions require updated peers; definitions without maps retain their
  existing descriptor bytes and payload representations.
  Each new native value shape adds its bounded `N` descriptor token, including
  declared value allowlists and bounds. Native-shape definitions require updated
  peers; definitions without these shapes retain their existing descriptor
  bytes and payload representations. All new native shapes use the checked
  whole-tuple codec, including in reliable events.
  `Color3RGB8` uses the fixed shape token `N10:Color3RGB8[1]`; existing prefix
  selection still applies, so a lone codec shape remains `RR3`. It adds no
  global prefix revision.
  There is no version negotiation, downgrade, or cross-version fallback.
  The 64-endpoint limit preserves existing descriptor bytes and payload formats;
  definitions above the earlier 16-endpoint limit require updated Relay copies on
  both sides. The 4,096-byte descriptor cap still applies independently.
  The [coordinated upgrade recipe](../examples/README.md#coordinated-definition-upgrades)
  shows a concrete changed event, mismatched startup, fresh matching session,
  and rollback to a complete matched definition.
  See [upgrade compatibility](#upgrade-compatibility) for the peer matrix.
- **Maximum encoded size:** the definition descriptor is capped at 4,096 bytes.
  Reliable native tuples have at most eight fields, with each string capped by its declared
  `maximumBytes` (0..1024), at most 8192 string-content bytes per event. Relay
  has no encoded-size cap for reliable native tuples. Every unreliable event and
  every reliable event containing a composable shape encodes its entire tuple into one buffer:
  at most **8192 raw bytes for Reliable or 900 for either unreliable mode**,
  including all headers and length prefixes. This includes every reliable
  event when the definition enables `bitPacking`. Ordinary codec frames have a
  three-byte version/endpoint header. Ordered unreliable frames have an eleven-
  byte header, leaving at most 887 content bytes for a lone string. Definition rejects
  schemas whose worst case exceeds that cap with `InvalidDefinition`; sends reject
  invalid or oversized values with `InvalidPayload` before a transport call. The
  encoder checks actual normalized size before allocating the output buffer.
  `Color3` contributes 12 bytes per value (R/G/B Float32), with finite components
  in `0..1`; it uses the same total-byte, container, depth and node limits. A
  primitive Color3 buffer frame is 15 bytes including the three-byte header.
  `Color3RGB8` contributes three R/G/B u8 bytes per value and uses the same
  limits. Its ordinary primitive frame is 6 raw bytes, and its ordered
  unreliable frame is 14 raw bytes. Both routes use the existing headers.
  A quantized scalar contributes one body byte when it has at most 256 levels,
  otherwise two little-endian bytes. Its code, including unused codes that the
  decoder rejects, is covered by the existing frame-size and admission limits.
  Quantized scalars use the checked whole-tuple codec and fit under the existing
  Reliable, unreliable, RPC, FIFO, State, and envelope caps; no new byte budget
  or admission charge is added.
  Quantized Vector2 and Vector3 use two or three independent scalar codes,
  respectively: each axis is one byte for at most 256 levels and two bytes
  otherwise, so a value occupies 2/4 or 3/6 bytes. The native Vector2/Vector3
  constructor precision is included in the component error allowance and must
  satisfy the stable-code check. Compact CFrame stores three quantized position
  coordinates followed by three u16 rotation codes, for 9/12 bytes total. Its
  position error follows the scalar grid; its rotation error is at most 0.002
  radians. These leaves use the existing frame and envelope caps.
  With definition-level bit packing, Boolean, literal enum and optional flag
  bits occupy a low-bit-first mask at the start of each tuple or struct block.
  Mask padding and absent optional value bits are zero. Computed mask bytes are
  included in exact bounded shape sizes; other field bodies retain their
  existing encodings.
  Native Roblox shapes use the fixed checked body sizes listed in
  [Native Roblox values](#native-roblox-values); sequences reserve their declared
  maximum keypoints, and PathWaypoint reserves its maximum label bytes. A
  maximum ColorSequence body is 641 bytes. A PathWaypoint label can be at most
  867 bytes in a normal unreliable frame, 859 in an ordered frame, or 862 in a
  queued-unreliable body; the schema is still limited to 1,024 label bytes and
  must fit the route's total frame cap.
  Immediate events containing Instance references use format 4 and
  carry a bounded reference tuple beside the buffer. Their admission maximum is
  `buffer.len + 8 * referenceCount`, including the four-byte header, and must
  fit 8,192 reliable or 900 unreliable units. Definitions check worst-case buffer bytes plus eight bytes
  per maximum reference; union branches use conservative independent maxima.
  This format is limited to 16 references per event, regardless of nesting.
  Tagged unions add one ordinal byte to the selected struct body. Their worst
  case includes the largest variant; a smaller alternative does not relax any
  byte cap. An unreliable union variant with one string can declare at most
  894 content bytes (three-byte header, one tag byte and two-byte string length).
  Legacy maps contribute a two-byte count plus each encoded key and value. Their
  declared maximum includes every entry at its key/value maximum size, even
  when the actual map is empty. All existing frame and envelope caps apply.
  A lone unreliable string can declare at most 895 content bytes: its two-byte
  length and the three-byte header fill the 900-byte cap. These exact Relay buffer limits
  exclude Roblox's outer endpoint/envelope and compression; the unreliable
  ceiling still does not guarantee delivery.
  Ordered unreliable framing is format 3: version:u8, endpoint:u16,
  generation:u32, sequence:u32, then the same encoded fields. Integers are little-
  endian. The complete frame is 11..900 raw bytes; its bounded ordinary codec
  body would be at most 892 bytes including the three-byte codec header.
  RPC uses Reliable endpoint zero with a buffer and optional native references,
  totaling at most **8192 units** (`buffer.len + 8 * referenceCount`):
  a 44-byte identity header and a forced-codec body of at most **8148 bytes**.
  Requests and responses independently use the same depth, node and shape caps.
  Legacy RPC uses outer format 1; upgraded RPC uses format 7 with the same
  44-byte identity header. Its body is codec format 1 or reference format 4;
  header, body, and all reference charges fit the complete limit. Bodyless
  failures carry no sidecars. Ordered reference events use format 6, with
  a 12-byte ID/generation/sequence/reference-count header, and fit the complete
  900-unit ceiling. Ordering advances only after full typed and scope validation.
  Scheduled streams use this same envelope with explicit f64 time and optional
  state fields; all timestamp/presence bytes and reference charges are inside
  the same bound. At most 64 owners retain two <=900-modeled-unit snapshots
  each (115200 units, at most 2048 references), with at most 64 timers; Idle
  owners have none. Shape limits and admission charges are unchanged. See
  [Scheduled ordered streams](#scheduled-ordered-streams).
  Queue-capable events also use a forced-codec body for their queued route, even
  when immediate sends use native tuples. FIFO and state envelopes are endpoint-zero
  format 2, kinds 1 and 2, with 1..32 records. Kind 1 admits Batch/State-capable
  events; kind 2 admits only State-capable events. Its three-byte format/kind/count header
  and each two-byte body length count toward the **8192 Reliable / 900 Unreliable
  raw-byte** envelope cap. Each record body is at most **8187 / 895 bytes**,
  including its existing three-byte codec header. Reusable batchers use the same
  format, limits, and payload schema bounds; they add no wire or descriptor
  version and introduce no new charge policy. All existing logical-record, byte,
  endpoint, and outbound charges still apply. These are Relay buffer-content
  limits, not Roblox wire-size estimates.
  Opt-in client pacing retains at most 128 records / 32768 body-plus-reference
  units and emits at most one legal packet per channel per interval; see
  [Paced client batches](#paced-client-batches). Independent server State
  progress retains at most 64 captured recipients per lane, with at most
  64*64 pending recipient flags across the existing session key cap; see
  [Latest unsent state](#latest-unsent-state).
  The server-only `CreateBroadcastBatcher` and `CreateBroadcastState` use these
  same envelopes and limits (kind 1 FIFO and kind 2 State respectively).
  Each nonempty flush validates the complete current Player roster, at most
  1024 recipients, and reserves both channels' combined bytes for every recipient
  before calling `FireAllClients` once per populated channel. A refusal sends
  neither channel and retains unexpired pending work for explicit retry. No client decoder,
  descriptor or protocol version changes.
  Reference-bearing queues use format 5: a four-byte format/kind/count/totalRefs
  header, followed by u16 lengths and format-1 or format-4 bodies. Native
  sidecars concatenate each record's local references in record order, with
  at most 16 per complete frame. The receiver scans all metadata, validates
  exact sidecar arity and each typed body before dispatching any record.
  Queue retention, selection, admission and outbound budgets include eight
  units per reference and the extra header byte. State replacement, expiry,
  removal and teardown release retained references. Scope is checked again
  before handoff; selected work is never replayed after an uncertain send.
  See the [UnreliableRemoteEvent reference](https://create.roblox.com/docs/reference/engine/classes/UnreliableRemoteEvent).
- **Elements and nesting depth:** array length, set size and map size have required
  declared limits in 0..64; structs have at most eight fields, string enums at
  most 32 distinct strings of 1..32 bytes, and native enum, BrickColor, and Font
  allowlists at most 32 values. Native sequences allow 2..20 keypoints. Each compiled shape has explicit minimum/
  maximum encoded bytes, maximum depth and expanded node count. A primitive,
  string enum or fixed native value is one node at depth zero. Native sequences
  add one intrinsic depth level and reserve `1 + maximumKeypoints` expanded nodes.
  Each struct, array, set, map or optional adds one
  depth level and one node; arrays/sets reserve their declared capacity times
  the child's node count, structs sum children, and optionals reserve the child
  even when absent. An event is limited to **depth 4 and 256 expanded nodes**
  across all roots. Empty structs still count. Compilation also permits at most
  256 authored nodes per event, including children of zero-capacity containers.
  Instance references are one node at depth zero. Their schema-wide maximum
  count is 16: structs sum child counts, arrays and map values multiply by the
  declared capacity, optionals reserve their child, and unions reserve the
  largest alternative. Instance references are supported as map values, but
  never as map or set keys.
  Quantized scalars are one node at depth zero, with a one- to four-byte body;
  their configured grid has at most 4,294,967,296 levels. They can be map values but
  cannot be map or set keys. Existing array, authored-node, expanded-node, depth,
  frame, envelope, and admission limits continue to apply.
  Quantized Vector2/Vector3 and compact CFrame are strict native Roblox leaves at
  depth zero and one node. They can be nested as values in supported shapes and
  routes, but cannot be map or set keys. They retain the existing container,
  depth, node, frame, and envelope limits.
  A map reserves `1 + maximumSize * (keyNodes + valueNodes)` expanded nodes;
  its depth is one plus the greater child depth. Both child schemas consume
  authored nodes even at zero capacity. Map keys are bounded strings or integer
  shapes or allowlisted native EnumItems; direct optional values are forbidden
  because nil removes an entry.
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
  Optional server-local `inboundRate.fairness` partitions aggregate call
  allowance into at most 64 reusable peer reserves and a shared pool, charged
  between per-player and aggregate admission. It changes no wire bounds or
  compatibility and retains all later gates; see
  [Lifecycle and admission](#lifecycle-and-admission) for its conditions.
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
  Ordered frames, including their generation/sequence bytes, pay these same
  call, byte and endpoint charges. Stale, duplicate and old-generation attempts
  retain applicable charges. Header checks and stale rejection precede body
  copying; only a completely valid, admitted payload advances its high-water.
  Ordered initialization uses Reliable endpoint zero, format 2 kinds 32/33:
  a 38-byte Hello (canonical client GUID) and a 42-byte Init (echoed GUID and
  nonzero server generation). Hello pays shared call/byte admission; these
  controls do not spend an application endpoint token. A byte policy must admit
  the 38-byte Hello for client startup to complete. No automatic retry is made.
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
- **Optional readiness controls:** `readiness = true` selects RR6 (or RR7/RR8 above) and requires at
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
        Input = s.clientToServer(1, s.fields(
            { sequence = s.u32() },
            { enabled = s.boolean() }
        )),
    },
})
local Events = assert(definition, definitionError and definitionError.message)
```

The shared definition may also set `bitPacking = true` or an
`outboundBytes` policy. These are definition-wide, opt-in wire capabilities;
their formats and compatibility effects are described below.

For transient updates such as aim snapshots or visual effects, pass
`{ delivery = "Unreliable" }` as the third argument to either direction helper.
Send, Broadcast and Connect keep the same signatures. Omitted delivery and
`{ delivery = "Reliable" }` use reliable delivery. Add `queue = "Batch"` or
`queue = "State"` to the same options table for queued capabilities; queued
events support Reliable or Unreliable delivery. OrderedUnreliable cannot be queued.

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
Native Roblox values and the composable shapes below add closed, bounded shape
grammars. Bounded Instance references are supported across immediate, queued,
ordered and RPC routes as described below. Unbounded buffers,
unbounded maps and recursive shapes remain unsupported.
The shared definition determines event names, direction-specific methods, and
ordered argument types for both sessions. Integer and float fields have Luau type
`number`; numeric bounds, integer checks, string byte limits, and game permissions
still require runtime validation. Listener callbacks may ignore trailing arguments.

The constructors include `fields`, `ordered`, `field`, the primitive and
Roblox-value helpers including `Instance`, `buffer`, `quantized`, `quantizedVector2`,
`quantizedVector3`, and `compactCFrame`, `struct`, `taggedUnion`, `array`, `map`,
`enum`, `optional`, `set`, `clientToServer`, `serverToClient`, `request`, and
`compose`.
Their arguments match the raw grammar: for example `s.string(128)`,
`s.i16(-100, 100)`, `s.Color3()`, `s.array(element, 16)`, `s.map(s.string(32), s.u16(), 16)`, and
`s.serverToClient(id, fields, { delivery = "Unreliable" })`.
`fields({ name = shape }, ...)` preserves the argument order and names each
anonymous shape. Each keyed entry must contain exactly one name; `s.fields()`
declares zero fields. `fields` and `struct` also accept legacy named field
records. The preferred keyed forms need no
singleton casts or special parentheses on the final argument.
Constructors freeze their owned records and ordered lists. `define` validates
and independently copies the complete tree. Invalid helper arguments can throw
before `define`, so use plain records when constructing dynamically checked input.

Reusable shapes are ordinary locals or returned ModuleScript values. For example:

```lua
local Item = s.struct(
    { id = s.u32() },
    { count = s.u16() }
)
local fields = s.fields({ items = s.array(Item, 16) })
local Mode = s.enum({ Idle = 1, Run = 2 })
```

Enum maps assign explicit one-based ordinals. Values must be unique integers
forming the dense range 1 through the label count, independent of map traversal
order. When migrating a string-list enum, retain each label's original list
position as its ordinal. Bracketed keys support labels such as `["not moving"]`.

Legacy `ordered`, `field`, named struct records, vararg string enums,
two-argument tagged unions and third-string delivery remain supported.
`field(name, shape)` copies an anonymous shape before naming it; an already
named shape is rejected. Legacy nested field names and enum values still need
singleton annotations, such as `s.enum("Idle" :: "Idle", "Run" :: "Run")`.
Legacy multi-entry ordered/struct calls may need parentheses around the final
builder call to preserve a singular result in the pinned solver.
Raw records and the original [ordered helper](../examples/reliable-events/ordered.luau)
remain compatible. Equivalent declarations preserve field and enum order,
compiled descriptors and payload bytes; this authoring change adds no protocol.

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

Use `s.fields()` for events with no fields. Plain arrays are valid runtime schema
input; static type derivation requires `fields` or legacy ordered metadata and
Luau's new solver.
Keep schema, definition, and session variables inferred: a broad `DefinitionSpec`
annotation loses the information needed for derivation. The `Definition<S>`,
`ServerSession<S>`, and `ClientSession<S>` type aliases take the schema type.

### Ordered unreliable events

Set `delivery = "OrderedUnreliable" :: "OrderedUnreliable"`, or pass
`"OrderedUnreliable"` to `s.clientToServer` / `s.serverToClient`, to discard
duplicate and stale snapshots before the listener runs. Payload types and handle
methods stay the same. This is an immediate-event capability; combining it with
`queue = "Batch"` or `"State"` rejects. Each endpoint describes one stream:
independent entity updates sharing it do not receive separate ordering state.

```lua
Aim = s.clientToServer(1, s.fields(
    { direction = s.Vector3F32(-1, 1) }
), { delivery = "OrderedUnreliable" })
```

The sender advances a u32 sequence per endpoint. After accepting its first valid
frame, a receiver accepts a candidate only when its forward distance modulo
2^32 is 1..2^31-1. Equal, backward and exactly half-range values are discarded.
This permits wraparound within that window; it does not promise ordering across
2^31 or more unseen sends. Loss is still possible. Sequence order does not wait
for a yielding callback to finish, and Relay's existing handler caps still apply.

The server uses one outbound counter per endpoint across `Send`, `Broadcast`,
`SendTo` and `SendExcept`. Excluded recipients see gaps. Audiences still encode
one immutable payload per invocation, and `Broadcast` uses one `FireAllClients`.
Failed/partial native handoffs consume their sequence without retry. Listener
replacement and `Once` do not reset receive high-waters. No-listener, busy,
rate-refused or malformed frames do not advance them.

When a definition has ordered client-to-server events, client `Start` also waits
for a server-issued generation within its existing startup deadline. Recreating
the client for the same Player gets a new generation, preventing old-session
frames from advancing the new stream. Generations never wrap; exhaustion fails
closed until that actual Player leaves or the server session ends. Server-to-
client frames reserve generation zero; a recreated client starts with no high-
water and may accept an already in-flight packet first. Ordering applies after
that first acceptance, rather than providing restart freshness. Player removal
and session teardown release owned sequence state and initialization waits.

These checks do not establish gameplay authority. A modified client controls the
snapshots it sends and may disrupt its own stream; the game still validates their
meaning and permissions. Protocol and byte limits are specified above.

### Client send timestamps

Client-to-server events may set `timestampWindow` to a finite number greater than
zero and at most two seconds. Their first field must be `serverTime:f64`, with
minimum zero and maximum at least `2^40`. Client sending methods omit this first
argument and sample synchronized server time when submitting the payload,
including Batch and State submissions.

After decoding, the server rejects claims older than the configured window or
more than 0.1 seconds ahead. The oldest boundary is inclusive; accepted future
claims clamp to the sampled server time. Immediate and ordered events validate
before callbacks and ordered sequence advancement. FIFO/State frames share one
server-time sample, and an invalid timestamp rejects the entire frame before any
callback. Clock failure also rejects. Rejection counts as `invalidPayload` and
retains applicable call, byte, and endpoint admission charges.

The f64 field adds eight bytes inside existing payload/frame limits and selects
RR17 with the exact window in the descriptor. There is no local-clock fallback.
Queued records are stamped on submission, so a long queue delay can make them
too old at receipt. Timestamps remain untrusted client claims: the game still
owns authorization, history, interpolation and any rewind decisions.

For a game-owned lag compensation path, declare the timestamp before the shot
payload in the shared event map:

```lua
Shot = s.clientToServer(1, s.fields(
    { serverTime = s.f64(0, 2^42) },
    { origin = s.Vector3F32(-32768, 32768) },
    { direction = s.Vector3F32(-1, 1) }
), { timestampWindow = 0.25 }),
```

The client submits only `client.events.Shot:Send(origin, direction)`. On the
server, connect a handler using the game's bounded history and authority checks:

```lua
server.events.Shot:Connect(function(player, shotTime, origin, direction)
    if not gameRules:CanShoot(player) then return end
    local pastWorld = history:SampleAt(shotTime)
    if pastWorld == nil then return end
    gameRules:CheckShot(player, origin, direction, pastWorld)
end)
```

Here `history` and `gameRules` are application services, not Relay APIs. Retain
only the game's chosen history window; a missing sample refuses the shot.
`CheckShot` must verify origin, direction, ownership and damage against server
state before applying effects. Relay bounds the claimed time; it does not move
live parts, keep historical snapshots or decide whether a hit is valid.

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

`s.quantized(minimum, maximum, step)` opts one scalar into a bounded numeric
grid and gives it Luau payload type `number`:

```lua
local Speed = s.quantized(-1, 1, 0.01)
local fields = s.fields({ speed = Speed })
```

The raw form is `{ type = "quantized", minimum = -1, maximum = 1, step = 0.01 }`;
it accepts those three numeric keys and an outer `name` only when used as a named
field.

The three arguments must be finite, `minimum < maximum`, and `step` must be at
least `2^-974`, which keeps the error allowance normal in Roblox's floating-point
runtime. The finite span divided by
the step is rounded to the nearest positive integer step count `N`; ties advance to the higher
count. It must produce `1..4294967295`, or at most 4,294,967,296 representable levels
including both endpoints. To allow ordinary binary64 cancellation such as
`0.1..0.1001` with step `0.0001`, the endpoint may differ from the nominal grid
by at most `allowance = 16 * 2^-52 * max(abs(minimum), abs(maximum), step)`.
That allowance must be finite, positive, and no greater than `step / 16`.
`maximumError` is `step / 2 + allowance`; the final grid interval can differ by
up to the endpoint allowance. Calculations follow Roblox's floating-point
behavior, including subnormal flushing.

Every sent number must be finite and inside the original inclusive bounds before
rounding. Relay never clamps it. It rounds the computed nominal position
`(value - minimum) / step` to the nearest grid index, with exact `.5` ties going
toward the higher index, including for negative ranges;
the declared minimum and maximum map to their exact endpoint values. Zero is
canonicalized to positive zero. Relay rejects values whose normalized result
does not map back to the same index or whose actual error exceeds
`maximumError`. The decoder rejects unused codes and verifies the same bounds
and stable-index rule before returning a number. A grid with at most 256 levels
uses one unsigned byte; grids with at most 65,536, 16,777,216 or
4,294,967,296 levels use two, three or four little-endian bytes. Existing
one/two-byte grids preserve Q1 descriptors; wider grids use a distinct Q2
shape token and select RR16. `inspect`
includes these widths in its exact encoded-size bounds and reports the fixed
`limits.quantizedLevels = 4294967296` cap.

Quantized scalars are supported in ordinary immediate events in both directions,
unreliable and ordered events, RPC arguments and results, queued events, and
nested structs, arrays, map values, optionals, and tagged unions. They cannot be
map or set keys. If an event contains any quantized scalar, including one in a
zero-capacity shape, its entire tuple uses the checked buffer codec. Any existing
Instance reference count, class and scope rules apply when the shapes are combined.
The descriptor pins the algorithm revision, grid parameters, level count, and
width, so both peers must use the same definition and updated Relay copies.
Definitions without quantized fields retain their existing encoding and descriptors.

### Compact numeric formats and bounded lengths

`s.u24(minimum?, maximum?)` and `s.i24(minimum?, maximum?)` encode exact
three-byte little-endian integers in 0..16,777,215 and -8,388,608..8,388,607.
`s.f16(minimum, maximum)`, `s.f24(minimum, maximum)` and
`s.f64(minimum, maximum)` retain Luau type `number`. All these formats force
the whole-tuple codec, including reliable immediate events.

The compact floats round to nearest, ties to even, including subnormals, and
canonicalize zero. Binary16 uses sign/exponent/fraction widths 1/5/10, bias15,
maximum finite65504 and smallest subnormal `2^-24`. Relay f24 uses 1/6/17,
bias31, maximum finite4294950912 and smallest subnormal `2^-47`; it is an
explicit Relay format. Its byte layout is little-endian. Roundoff is at most
half the spacing at the rounded magnitude, or half the smallest subnormal
spacing near zero. These are absolute rounding guarantees, not gameplay
tolerances. Use `quantized` when an authored step/error bound is needed.
F64 uses native finite binary64 without precision reduction. Every format
requires finite inclusive bounds; source and rounded values must both fit
them. Decoders reject nonfinite encodings and noncanonical compact-float
negative zero. No format clamps an out-of-range value.

Strings, buffers, arrays, sets and maps accept an optional final minimum:
`s.string(maximumBytes, minimumBytes?)`, `s.buffer(maximumBytes, minimumBytes?)`,
`s.array(element, maximumLength, minimumLength?)`,
`s.set(element, maximumSize, minimumSize?)`, and
`s.map(key, value, maximumSize, minimumSize?)`. Minima are integers between
zero and the maximum. Existing maximum caps remain unchanged. For example,
`s.array(s.u8(), 12, 12)` requires exactly twelve values;
`s.string(32, 4)` permits 4..32 bytes.

Omitting the minimum preserves the old two-byte absolute count and descriptor.
Providing it, including zero, opts into a compact offset `count - minimum`:
no prefix when minimum equals maximum, one byte for a range span1..255,
otherwise two bytes. Counts outside the declared range reject before allocation
or collection traversal. Exact zero-length fields remain strictly typed.
Packed fields and Instance-bearing collections use the same count grammar.

### Bounded buffers

`s.buffer(maximumBytes)` accepts a native Luau `buffer` with an integer byte cap
from `0..8187`. For example, `s.field("data", s.buffer(256))` retains the strict
`buffer` payload type. Its closed raw shape has `type = "buffer"` and
`maximumBytes`, with `name` only on a named field. Strings and tables reject.

The checked body is a little-endian u16 length followed by exactly that many
bytes, including arbitrary binary content. Empty buffers are valid. Relay checks
the prefix, declared cap and remaining frame bytes before allocating or copying
decoded content; malformed lengths, truncation and trailing bytes reject the
whole frame before callbacks. Normalized and decoded buffers are fresh owned
copies. Queued sends own their encoded snapshot, so caller mutation after an
accepted send cannot change it.

Buffers are leaf nodes at depth zero and always force the whole-tuple codec.
They may be nested as composite values and used in supported events, RPCs,
FIFO and State queues, including packed definitions. They cannot be map or set
keys. A legacy buffer body takes `2 + length` bytes; an explicit minimum uses
the compact count grammar above. All existing complete-frame caps
still apply. A single reliable immediate buffer may hold 8187 bytes after its
three-byte frame header and two-byte length; unreliable, ordered, RPC, queued
and mixed-field definitions must fit their narrower remaining budgets. Admission
charges the actual complete Relay frame and envelopes, including rejected
eligible ingress. The buffer capability requires matching RR15 peers.

### Quantized native vectors and compact CFrames

`s.quantizedVector3(minimum, maximum, step)` and
`s.quantizedVector2(minimum, maximum, step)` apply the same scalar grid to each
component and retain native `Vector3` / `Vector2` payload types. For example:

```lua
local Position = s.quantizedVector3(-256, 256, 0.25)
local AimOffset = s.quantizedVector2(-32, 32, 0.125)
```

Their raw shapes use the exact keys `type`, `minimum`, `maximum`, and `step`,
plus `name` only when used as a named field. Bounds must be finite, ordered,
and exactly representable as finite Float32 values. `step` follows the scalar
grid limits and rules. Native component precision must also be representable:
Relay computes `nativeAllowance = max(2^-126, 2^-23 *
max(abs(minimum), abs(maximum), step))` and requires it to be finite and at most
`step / 16`. The maximum component error is the scalar `maximumError` plus this
allowance. Wider scalar index codes do not relax native Float32 precision:
vector grids that exceed this precision condition still reject, even when
their index count would fit four bytes. Compact CFrames retain their distinct
post-construction position stability and error checks.

Each source component is checked for finiteness and original inclusive bounds
before rounding. Relay selects scalar grid codes, constructs the native vector,
then checks the actual components for bounds, native precision, stable codes,
and the declared error. It never clamps. On receive it checks all scalar codes
before constructing the native value and verifies the constructed components
against those codes. Vector2 occupies `2 * scalarWidth` bytes and Vector3 `3 * scalarWidth`,
with the narrowest supported scalar width chosen for the grid. These shapes are supported in the
same events, requests, queues and composites as other native leaves; they
cannot be map or set keys.

`s.compactCFrame(minimum, maximum, positionStep)` opts a CFrame into bounded
position and rotation quantization:

```lua
local Pose = s.compactCFrame(-4096, 4096, 0.25)
```

The raw shape uses `minimum`, `maximum`, and `positionStep`, plus `type` and
outer `name`. Bounds have the same Float32-exact requirement as quantized
vectors, and `positionStep` follows the scalar grid rules. Relay reads position
from `CFrame:GetComponents()`, quantizes its three coordinates, and encodes
three periodic u16 XYZ Euler angles. Each code rounds by the `2*pi/65536`
increment, ties forward, and wraps modulo 65,536; decoding interprets it in
`[-pi, pi)`. Relay reconstructs rotation with the matching `ToEulerAnglesXYZ` /
`fromEulerAnglesXYZ` pair and accepts a source frame only when the reconstructed
orientation is within `0.002` radians by `AngleBetween`.

The source and reconstructed rotation matrices must be finite, right-handed and
rigid within a fixed `1e-6` component, norm, dot-product, and determinant
tolerance. Relay rejects scaled, sheared, reflected, out-of-bounds, unstable, or
over-error frames instead of repairing them. Position keeps the scalar grid's
per-coordinate error bound. The checked body is 9 or 12 bytes: three one- or
two-byte position codes followed by six rotation bytes. There is no exact
rotation roundtrip promise. This helper is separate from `s.CFrame(...)`; legacy
CFrame bounds, representation, and zero-sign behavior remain unchanged.
Compact CFrames can be nested in supported events, requests, queues, and
composites, but cannot be map or set keys.

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

### RGB8 Color3

`s.Color3RGB8()` and raw `{ type = "Color3RGB8" }` opt into a fixed three-byte
R/G/B encoding while preserving native `Color3` payloads. The raw shape accepts
only `type` and, for a named outer field, `name`; bounds and other keys are
rejected. Each actual native component must be finite and in inclusive `0..1`
before encoding, and invalid inputs are rejected without clamping. Relay encodes
each channel as `floor(component * 255 + 0.5)`, so exact halves round upward;
the actual Roblox component after engine storage rounding is quantized. All 256
u8 codes are valid. Decoding constructs `Color3.new(r / 255, g / 255, b / 255)`
and canonicalizes zero to positive zero. Each reconstructed component must remain
in range, stay within `2^-24` of its selected code divided by 255, and re-encode
to that same code. The maximum per-channel error is `1/510 + 2^-24`.

RGB8 is a value leaf with one node at depth zero and is excluded from set keys.
Its `N10:Color3RGB8[1]` shape token participates in existing descriptor-prefix
selection; no global RR revision is added. Matching definitions are required on
both peers, while definitions without RGB8 retain their descriptors and bytes.
Every route uses the checked whole-tuple codec, including reliable immediate
events, nested shapes, requests/responses, ordered unreliable events, FIFO
batches, State queues, and definition-level bit packing. The existing total
frame/envelope, container, depth, node, endpoint, and admission limits and
charges continue to apply. Legacy `Color3` keeps its existing Float32 semantics,
descriptor, and 12-byte codec representation. Buffer lengths describe Relay
content, with Roblox transport encoding unmeasured.

### Native Roblox values

The 23 native-value helpers in the table below accept and return the matching
Roblox datatypes.
They can be used as event fields, request arguments or results, and inside
supported composable shapes. Every raw shape has a closed set of keys shown
below, plus `name` only when it is the outer named field. Floating bounds must
be finite and ordered. The helpers take one inclusive component bound where a
single `minimum`/`maximum` pair is shown; values are checked before and after
Float64 encoding, and Relay rejects values that Roblox construction would round
or clamp. New floating zero values normalize to positive zero. Where native-value
rows use floats, they use Float64 independently of existing Float32 `Color3`
behavior; the `Color3RGB8` row instead uses its fixed-width u8 channel encoding.

| Helper | Raw metadata keys | Bounds and body size |
| --- | --- | --- |
| `s.Color3RGB8()` | None | Native `Color3` with finite RGB components in `0..1`; three R/G/B u8 codes (3 bytes). |
| `s.robloxEnum(...items)` | `values` | `1..32` nonempty `EnumItem`s from one family; unique names and signed 32-bit values; 4 bytes. Its precise Enum family is retained in the payload type. |
| `s.UDim(minScale, maxScale, minOffset, maxOffset)` | `minimumScale`, `maximumScale`, `minimumOffset`, `maximumOffset` | Finite scale bounds and signed 32-bit integer offset bounds; 12 bytes. |
| `s.UDim2(minScale, maxScale, minOffset, maxOffset)` | Same as `UDim` | Same bounds independently apply to both axes; 24 bytes. |
| `s.NumberRange(minimum, maximum)` | `minimum`, `maximum` | Ordered range endpoints; 16 bytes. |
| `s.Rect(minimum, maximum)` | `minimum`, `maximum` | Bounds every coordinate, with Min ordered componentwise before Max; 32 bytes. |
| `s.BrickColor(...colors)` | `values` | `1..32` distinct declared BrickColors; 16-bit palette numbers; 2 bytes. |
| `s.Vector2int16(minimum?, maximum?)`, `s.Vector3int16(...)` | Optional `minimum`, `maximum` | Integer component bounds default to `-32768..32767` and may narrow; 4 / 6 bytes. |
| `s.NumberSequence(maximumKeypoints, minimum, maximum, maximumEnvelope)` | `maximumKeypoints`, `minimum`, `maximum`, `maximumEnvelope` | `2..20` points; values within the declared bounds, envelopes from zero through `maximumEnvelope`; 1-byte count plus 24 bytes per point. |
| `s.ColorSequence(maximumKeypoints)` | `maximumKeypoints` | `2..20` points, RGB components in `0..1`; 1-byte count plus 32 bytes per point. |
| `s.NumberSequenceKeypoint(minimum, maximum, maximumEnvelope)` | `minimum`, `maximum`, `maximumEnvelope` | Time `0..1`, bounded value and envelope `0..maximumEnvelope`; 24 bytes. |
| `s.ColorSequenceKeypoint()` | None | Time and RGB components in `0..1`; 32 bytes. |
| `s.TweenInfo(maximumTime, maximumDelayTime, maximumRepeatCount, allowInfiniteRepeat?)` | `maximumTime`, `maximumDelayTime`, `maximumRepeatCount`, optional `allowInfiniteRepeat` | Nonnegative time/delay and repeat bound `0..2147483647`; 29 bytes. Repeat `-1` requires `allowInfiniteRepeat = true`. |
| `s.DateTime(minimum, maximum)` | `minimum`, `maximum` | Integer `UnixTimestampMillis` from `-17987443200000` through `253402300799999`; 8 bytes. |
| `s.Ray(minimum, maximum, maximumDirectionMagnitude)` | `minimum`, `maximum`, `maximumDirectionMagnitude` | Origin components within the bounds and a finite direction within the nonnegative magnitude limit; 48 bytes. |
| `s.Axes()`, `s.Faces()` | None | Masks `0..7` / `0..63`; 1 byte. |
| `s.Region3(minimum, maximum)` | `minimum`, `maximum` | Bounds both corners and the finite derived corners. Corner order, including negative sizes, is preserved only when center/size reconstruction is exact; 48 bytes. |
| `s.Region3int16(minimum?, maximum?)` | Optional `minimum`, `maximum` | Both corners use signed 16-bit component bounds, defaulting to the full range and preserving native order; 12 bytes. |
| `s.PhysicalProperties()` | None | Density, friction, elasticity, both weights, and acoustic absorption use fixed native ranges; 48 bytes. |
| `s.Font(...families)` | `families` | `1..32` unique family strings, each `1..256` bytes; 9 bytes. A fresh Font is constructed for each normalized or decoded value. |
| `s.PathWaypoint(minimum, maximum, maximumLabelBytes)` | `minimum`, `maximum`, `maximumLabelBytes` | Position components use the bounds; action is allowlisted and label is limited to `0..1024` bytes; 30 bytes plus label bytes. |

Fixed numeric components use little-endian Float64 unless a row specifies an
integer width. UDim stores scale then signed-32 offset per axis; NumberRange
stores its two endpoints; Rect stores Min/Max X and Y; integer vectors and
Region3int16 use signed-16 components. Native enum values use their declared
signed-32 `Value`; BrickColor uses its declared 16-bit palette number. Sequences
store a one-byte point count, then each point's time and value fields. TweenInfo
stores time and delay, repeat count, reverse flag, easing style, and easing
direction. DateTime stores the integer Unix milliseconds exactly as a Float64.
Ray stores Origin then Direction. Region3 stores center and size; its observable
corners must reconstruct exactly. PhysicalProperties stores density, friction,
elasticity, friction weight, elasticity weight, and acoustic absorption. Font
stores family ordinal, weight, and style; PathWaypoint stores position, action,
then a u16 label length and its bytes.

For example, `s.robloxEnum(Enum.Material.Plastic, Enum.Material.Wood)` accepts
only those two materials and infers the `Enum.Material` family. Native enum
allowlists can also be set members or map keys; their declared family is kept
inferred. The raw form is `{ type = "robloxEnum", values = { ... } }`. Enum
values are matched by their native signed 32-bit `Value`, not by an ordinal.
BrickColor uses only its declared palette; undeclared values are rejected rather
than passed to Roblox's fallback palette constructor. Font family names are
restored from the definition. The bounded intrinsic enum policies are:
TweenInfo uses EasingStyle (`Linear`, `Sine`, `Back`, `Quad`, `Quart`, `Quint`,
`Bounce`, `Elastic`, `Exponential`, `Circular`, `Cubic`) and EasingDirection
(`In`, `Out`, `InOut`); Font uses FontWeight (`Thin`, `ExtraLight`, `Light`,
`Regular`, `Medium`, `SemiBold`, `Bold`, `ExtraBold`, `Heavy`) and FontStyle
(`Normal`, `Italic`); PathWaypoint uses PathWaypointAction (`Walk`, `Jump`,
`Custom`). These named policies are included in the descriptor.

NumberSequence and ColorSequence times must be strictly increasing, start at
zero, and end at one; duplicate times are rejected. Their declared maximum
reserves `1 + maximumKeypoints` expanded nodes and one level of composite depth.
Other native values are leaves at depth zero and one expanded node. Axes and
Faces accept only masks `0..7` and `0..63`. PhysicalProperties bounds are
density `Float32(0.0001)..100`, friction `0..2`, elasticity and acoustic
absorption `0..1`, and both weights `0..100`.

Every native value is fully validated before construction from a received
buffer: fixed bytes must remain available, variable counts and label lengths
must fit before allocation, and all components and enum values must match the
definition. Constructor output is checked exactly, so clamping or rounding
cannot turn invalid bytes into an accepted value. The descriptor records all
bounds and allowlist entries; peers must use the same definition and updated
Relay copies. These shapes use the existing event, request, FIFO and State
admission limits. `inspect` reports their byte bounds and the native allowlist,
font-family, and sequence limits alongside existing limits; it does not measure
Roblox's outer transport encoding.

### Instance references

`s.Instance(className)` adds one bounded native Instance reference. The closed
class list is `Instance`, `BasePart`, `Part`, `MeshPart`, `Model`, `Humanoid`,
`Tool`, `Attachment`, `Player`, `Folder`, `GuiObject`, `Sound`, `Animation`,
and `Animator`. `Instance` is the explicitly broad base type; other entries
retain their precise Luau class type, and runtime `IsA` checks accept subclasses.
Unknown, widened, or nonliteral class names and extra raw-shape keys are rejected.
The raw form is `{ type = "Instance", className = "BasePart" }`.

References may appear in structs, dense arrays, map values, optionals, and tagged
unions. Map and set keys cannot be Instances. They are supported in reliable,
unreliable and ordered immediate events, RPC arguments/results, and Batch/State
queues on either channel. A reference-bearing immediate event
uses a checked format-4 buffer even when its other fields are primitive.

```lua
local events = {
    InspectTarget = s.clientToServer(1, s.fields({
        target = s.optional(s.Instance("BasePart")),
    })),
}
```

The server must pass `instanceRoot` to `createServer` exactly when its definition
uses references. The root must be the live `game` DataModel or a live descendant
of it; a root is rejected when the definition has no references. Relay checks
client-to-server references against this server-owned root and checks the same
scope again immediately before each server-to-client audience handoff. Audience
payloads encode once; if a reference leaves scope before a later handoff, the
call returns `InvalidPayload` with the successful handoff count retained. A
reference must be a live native Instance of the declared class, parented under
the actual `game` DataModel and equal to or descended from `instanceRoot` on the
server. The DataModel itself is never a payload reference. A detached object or
one outside the root is rejected. Clients check class and live game ancestry;
they do not choose or authorize the server root. Destroying the server session
clears its owned root context. These checks do not replace game ownership or
permission checks.

Each occurrence gets one sequential u8 slot in the format-4 body. The outer
remote call carries the endpoint ID, buffer, then its native Instance arguments; Relay
does not send an attacker-controlled sidecar table. The header is
version:u8=4, endpoint:u16, referenceCount:u8. Slot ordinals must be exactly
1..N in traversal order, where `N` is at most 16; repeated and out-of-order
slots reject. Optional absence uses its
existing zero tag and consumes no slot. Missing or nil references, wrong class,
wrong scope, destroyed or detached references, malformed slots, and unused or
extra arguments reject the whole event before any listener runs. Relay does not
wait or retry for streaming. A reference that has not replicated or streamed to
the receiver arrives missing and rejects that event; later valid events remain
independent.

`inspect` reports header-inclusive minimum/maximum encoded bytes and an event
`references` table with `maximumCount`, `perReferenceAdmissionBytes`, and
`maximumAdmissionBytes` for affected events.
Its fixed limits include `instanceReferences = 16` and
`instanceReferenceAdmissionBytes = 8`. The descriptor pins format 4, the
reference count cap, charge, and declared classes. Extended routes select RR16;
RPC format7, queued format5 and ordered format6 retain local sequential slots.
Their complete limits include wrappers and eight units per reference, with at
most sixteen references per complete frame. Old definitions without
references retain their current prefix and representation.

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
`element`, map `key`, and `value`. For example:

```lua
local Snapshot = s.struct(
    { mode = s.enum({ Idle = 1, Run = 2 }) },
    { scores = s.array(s.u16(), 16) },
    { tags = s.set(s.string(24), 8) },
    { target = s.optional(s.u32()) }
)
local fields = s.fields({ snapshot = Snapshot })
-- Send({ mode = "Idle", scores = { 10, 20 }, tags = { blue = true } })
```

Structs reject undeclared keys and require every non-optional field. Arrays are
dense, start at index 1, and reject holes or extra keys. Sets use
`{ [member] = true }`; members may be booleans, strings, integers, enum strings,
or declared native EnumItems.
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

Literal field keys and enum labels preserve exact inferred types.
The example derives a record with `mode: "Idle" | "Run"`,
`scores: { number }`, `tags: { [string]: true }`, and `target: number?`.
Value bounds remain runtime checks; typed schemas also enforce the four-level
composite depth limit. Definitions copy and freeze the complete schema;
decoded tables belong to that invocation, without sharing mutable payload state.

### Maps / dictionaries

`s.map(keyShape, valueShape, maximumSize)` describes a plain dictionary with a
required maximum of 0..64 entries:

```lua
local counts = s.map(s.string(32), s.u16(), 32)
-- s.field("counts", counts) accepts { potion = 3, arrow = 20 }.
-- Inferred payload type: { [string]: number }
```

The raw shape is `{ type = "map", key = keyShape, value = valueShape,
maximumSize = 32 }`; add `name` only for the outer named field. Keys must be
anonymous `string`, `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, or an allowlisted
`robloxEnum` shape, with their existing byte/range checks. String enums,
BrickColor, floats, booleans and composite keys are unsupported. Values may use any supported anonymous shape except a direct
`optional`; put optional fields inside a struct when needed. Missing keys mean
absent entries. `false` is a valid boolean value. Integer keys infer `number`,
and nested struct/union values retain their exact payload types. Luau types do
not enforce the entry count, string length or numeric bounds; runtime checks do.
The pinned solver can also accept incompatible fields in unannotated dictionary
literals passed directly to functions, including native Luau dictionary
parameters. Explicit dictionary annotations and listener values retain the
declared indexer types; Relay validates every key and value at runtime.

Maps reject metatables and invalid keys/values. Normalization first counts at
most the declared capacity plus one entry, then creates invocation-owned copies;
caller input is unchanged. Iteration and wire entry order are unspecified.
The wire stores a count followed by alternating key and value bodies. Omitted
minimumSize uses the legacy u16 count; an explicit minimum uses its compact offset.
Minimum body size is two bytes; maximum is
`2 + maximumSize * (keyMaximumBytes + valueMaximumBytes)`.
The decoder checks the count and minimum remaining entry bytes before allocating
the map or traversing entries. It validates each key and rejects duplicates
before decoding that entry's value. Truncated keys/values, invalid bounds,
oversized counts and trailing bytes reject before any handler. FIFO/State frames
still decode all records before any callback, and malformed admitted maps retain
the existing call, byte and endpoint charges. `inspect` reports the same byte,
depth and expanded-node bounds and exposes `limits.mapCapacity = 64`.

### Tagged unions

`s.taggedUnion({ tagName = variants })` describes a plain table whose literal tag selects
one struct. Each branch has its own required fields and exact runtime key set:

```lua
local resultShape = s.taggedUnion({
    kind = {
        Success = s.struct({ itemId = s.u32() }),
        Rejected = s.struct({ reason = s.string(64) }),
    },
})
-- Use s.fields({ result = resultShape }) for event or request arguments.
-- Payload type:
-- { kind: "Success", itemId: number } | { kind: "Rejected", reason: string }
```

Checking `result.kind == "Success"` narrows the payload to the branch containing
`itemId`. Event/listener/audience, request/response and batch/state types retain
that union, including inside structs, arrays and optionals. The wrapper requires
exactly one discriminator key. The legacy `s.taggedUnion(tag, variants)` form
remains supported and requires a singleton tag annotation for exact inference.

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

### Bit packing

Set `bitPacking = true` on `Relay.define` to pack booleans, string-enum ordinals,
and optional flags. `false` or an omitted option keeps the existing representation.
It does not change payload types. It opts the whole definition into the checked
tuple codec, including reliable boolean-only tuples, empty tuples, and tuples
without packable fields.

Each tuple and struct starts with a low-bit-first mask for its directly packable
fields. Booleans use one bit. A literal enum with 1..32 values uses
`max(1, ceil(log2(valueCount)))` bits. Optional presence uses one bit; optional
booleans and literal enums keep their value bits in the same mask. Other optional
payloads follow the mask in the byte body when present. Nonflag field bodies
follow the mask in their existing declaration order and retain their existing
encodings. Masks never span independent tuple, struct, array, map, set, or union
records.

Arrays of directly packable values use their declared count prefix followed by one
count-sized mask; arrays of other values encode each element as its own block.
Map entries remain in their encoded key/value correspondence and each entry is
its own block after the count. Sets may share an element mask when their
members are directly packable. A tagged union keeps its existing one-byte
variant ordinal, followed by the selected packed struct. Native Roblox EnumItems
and tagged-union discriminators retain their existing byte representations.

Absent optional value bits and unused mask padding must be zero. The decoder
rejects nonzero absent values or padding, unused literal-enum ordinals, malformed
or truncated nested blocks, and trailing data before dispatch. It checks each
count, complete count-derived mask, and minimum present body bytes before
allocation or traversal. Definition size bounds include each mask's exact
`ceil(bitCount / 8)` bytes and bounded child bodies. Existing count, byte, depth,
node, admission and envelope caps continue to apply. The descriptor pins the
block format; matching peers must enable the same option.

Without definition-level bit packing, composite and unreliable events encode
every field in declaration order. The buffer begins
with format version 1 and a little-endian u16 endpoint ID, which must match the
outer endpoint. Booleans and optional presence use one byte (0/1); enum ordinals
use one byte; tagged unions use one ordinal byte plus the selected struct body;
integer widths follow their type; f32 and vector components use
four bytes each. Color3 uses three f32 RGB components (12 bytes); Color3RGB8 uses
three R/G/B u8 components. Legacy CFrame uses twelve f64 components. Strings have a u16 byte
length, arrays, sets and maps have their declared count prefix, and structs omit their known field
names. The decoder checks remaining bytes before each read and count limits
before container allocation. Invalid tags/values, trailing data, and duplicate
set members or map keys are rejected before dispatch.
Reliable primitive-only events use native tuples when `bitPacking` is disabled.

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
        Input = s.clientToServer(1, s.fields({ sequence = s.u32() }), { queue = "Batch" }),
        Snapshot = s.serverToClient(2, s.fields({ sequence = s.u32() }), { queue = "Batch" }),
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

### Reusable batchers

Use `CreateBatcher` when one sender should keep the same FIFO handle across
multiple windows. The server takes the same fixed, bounded audience snapshot as
`CreateBatch`; the client targets its connected server. Both accept the same
sending-direction `Batch` and `State` events and use the same payload types:

```lua
local batcher, problem = server:CreateBatcher({ alice, bob }, 0.02)
assert(batcher, problem and problem.message)
assert(batcher.events.Snapshot:Send(27))
local ok, flushProblem, report = batcher:Flush()
local status = batcher:GetStatus()
assert(status.state == "Open" and status.pendingRecords == 0)

assert(batcher.events.Snapshot:Send(28))
batcher:Cancel()

local inputBatcher = assert(client:CreateBatcher(0.02))
assert(inputBatcher.events.Input:Send(29))
inputBatcher:Cancel()
```

Creation reserves the sender's single FIFO queue slot while the batcher is open,
including while it is empty. Another FIFO constructor on that sender, including
the server's `CreateBroadcastBatcher`, returns `QueueLimit` until cancellation,
terminal failure, or session cleanup releases the slot.
Creation requires a started, intact session and the same finite
`0 < flushAfterSeconds <= 0.1` delay as `CreateBatch`. It starts with no timer.
The first accepted `Send` sets a deadline using `flushAfterSeconds`; later sends
do not extend it. A successful `Flush`, including an empty one, freezes the
latest result, clears that window's records and counters, and returns the same
handle to Open. The next accepted send starts a fresh window. `GetStatus()`
reports Open, Sealed, or Terminal, the current pending record count, and only
the latest flush result.
The server's audience remains fixed: duplicate Players collapse, departures are
skipped and pruned, and later joins are not added.

An `OutboundRateLimited` result before handoff keeps the complete window Open
and stops its timer. Further sends do not restart that timer; retry with an
explicit `Flush()` or cancel the handle. A successful retry clears the window
and reopens it. Hard or partial transport failures are terminal and are never
retried. `Cancel()` is terminal and drops pending payload. Cancel has no effect
while the batcher is Sealed or while any queue handle owns the shared flush
guard; call it again after the guard is released. Session teardown also ends
the batcher.

### Paced client batches

Use client-only `CreatePacedBatcher(interval, options?)` to collect queue-capable
client-to-server events and split them into bounded packets over successive
flushes. Immediate sends keep their existing behavior. The interval is finite
and between `1/60` and `0.1` seconds; the closed options table accepts only
`manual = boolean?`.

```lua
local pacer, problem = client:CreatePacedBatcher(1 / 30, { manual = true })
assert(pacer, problem and problem.message)
assert(pacer.events.Input:Send(30))
-- Call from the application's update loop; early steps do no work.
local ok, stepProblem, report = pacer:Step()
local status = pacer:GetStatus()
pacer:Destroy()
```

Only outgoing events marked `queue = "Batch"` or `queue = "State"` appear on
this handle. The pacer owns one separate client slot, so an explicit FIFO handle
may coexist with it; both use the same flush guard. It retains at most 128
encoded records and 32768 body-plus-reference units across both channels.
Accepted submissions own their encoded payload immediately. A record must fit
a legal fresh packet; overflow returns `QueueFull` without changing the queue.

The first handoff waits a full interval after the first submission. Each due
`Step()` selects at most 32 FIFO records per channel and sends at most one packet
per populated channel. Complete packets include the three- or four-byte frame
header, two-byte row prefixes, bodies, and eight units per reference, within
8192 Reliable / 900 Unreliable units and 16 references. A record is never split;
later records stay pending for a future interval. There is no order promise
between channels. Late steps send one round and schedule from the current time,
without catch-up bursts. Automatic mode owns one timer only while work is pending;
manual mode owns no timer.

`Step()` returns `ok, error, QueueReport`; an early or empty step succeeds with
zero handoffs. `GetStatus()` returns `state` (`Open` or `Terminal`),
`pendingRecords`, `pendingUnits`, `manual`, and optional `lastStep` containing
`ok`, `error`, and `report`. `QueueBusy` retains pending work for the next
interval. Selected records leave the queue before native handoff. Scope,
transport, or other hard failures terminate the pacer and clear all remaining
work; an uncertain handoff is never replayed. `Destroy`, session teardown and
transport loss release retained bodies, slot and timer ownership.

### Shared broadcast batchers

Use the server-only `CreateBroadcastBatcher(flushAfterSeconds)` to collect
queue-capable server-to-client events into shared packets for all current
Players. It returns the same strictly typed `BatchHandle` as `CreateBatcher`:

```lua
local broadcasts, problem = server:CreateBroadcastBatcher(1 / 60)
assert(broadcasts, problem and problem.message)
assert(broadcasts.events.Snapshot:Send(30))
assert(broadcasts.events.Snapshot:Send(31))
local ok, flushProblem, report = broadcasts:Flush()
-- One Reliable envelope handoff containing both records.
assert(ok and report.reliableHandoffs == 1 and report.logicalHandoffs == 2)
broadcasts:Cancel()
```

Only `Batch`- or `State`-marked sending events appear on the handle. Its `Send`
queues one owned payload; immediate event sends and ordinary `Broadcast` keep
their existing behavior. It shares the single FIFO slot, shared FIFO/State flush
guard, lazy first-send deadline, `0 < flushAfterSeconds <= 0.1`, 32-record cap,
8192/900 complete byte caps, and 16-reference-per-frame cap. The timer is a
bounded delay, not a promise to run at an exact engine frame boundary.

For a nonempty window, `Flush` resolves a fresh dense, unique, live Player roster
of at most 1024 Players. Players who joined after submission are included;
departed Players from earlier windows are not retained. This is an all-player
broadcast and does not filter listener readiness or game permissions. The caller
must choose payloads appropriate for every current Player. `CreateBatcher` with
an explicit audience remains the choice for restricted recipients.

With `outboundBytes`, both channels' complete modeled bytes are preflighted and
reserved atomically against every current recipient before either send. A single
recipient's refusal or missing budget owner returns `OutboundRateLimited`
without a handoff or debit to other recipients. A failed or malformed roster
returns `InvalidAudience`; without an outbound policy, a missing active roster
owner also returns `InvalidAudience`. These preflight failures keep the complete
window Open, stop its timer, and record zero selected records with all records
remaining. Retry explicitly with `Flush` or cancel; later sends do not restart
the stopped window timer. An empty flush succeeds without consulting the roster.

Each populated channel uses one `FireAllClients` call at endpoint zero, Reliable
before Unreliable, including when the current roster is empty. Frame formats,
record order, exact sidecars, Instance scope checks and whole-frame decoder
rejection remain the same as ordinary FIFO batches. Reports count native calls:
one handoff per populated channel, and `logicalHandoffs` counts that channel's
records once. It does not multiply by player count or imply delivery. Diagnostics
increment `broadcastHandoffs`; byte charges still multiply by actual recipients.
No ordering is added across channels, immediate sends or other handles.

Success clears the window and reopens the handle. Hard or partial handoff
failure is terminal, retains earlier successful channel counts, and never
replays selected work. `Cancel`, session destruction and transport loss release
the existing slot, retained payloads and timer ownership.

### Latest unsent state

Use `queue = "State"` for absolute snapshots that may replace an earlier unsent
value. This also permits ordinary FIFO batching. Keep purchases, damage, and
other discrete commands on immediate sends or FIFO batches.

`server:CreateState(audience, flushAfterSeconds, options?)` captures the same fixed,
bounded Player snapshot as CreateBatch; `client:CreateState(flushAfterSeconds)`
targets its connected server. Both require a started, intact session and
`0 < flushAfterSeconds <= 0.1`. A lane exposes only sending-direction State events.

Server options are a closed plain table
`{ deferOutbound = boolean?, progress = "Independent"? }`.
`deferOutbound = true` requires a definition-level `outboundBytes` policy and a
nonempty captured audience, within the existing 1024-player cap. It opts that
lane into automatic service after a byte-budget refusal. With no `progress`,
both selected channels reserve bytes atomically for every surviving captured
recipient, and retries wait for the slowest recipient. Omit the options or use
false to retain explicit retry behavior. Client lanes keep their existing
signature; these options do not change frames or descriptors.

An opted-in lane keeps its unexpired snapshots and one timer, then rechecks
admission when its bucket can afford the selected packet or an older snapshot
expires. Expiry removes old snapshots and reevaluates surviving work. Budget
retries wait at least `1/60` second and the lane's flush interval; platform
scheduling can delay service. Replacement may bring service forward without
postponing the current deadline or resetting first-dirty age. A combined packet
larger than bucket capacity waits for expiry to change the selection; it does
not spin or split the atomic reservation. Player removal prunes that recipient;
the deferred lane closes when its audience becomes empty. `Remove` and
`Destroy` release their retained work and timers. Selected data still leaves the
queue before uncertain handoff, so it is never replayed automatically.

Set `progress = "Independent"` together with `deferOutbound = true` when each
recipient may progress separately. This mode accepts 1–64 captured Players.
Each key still owns one encoded body; bounded pending flags record which
recipients have yet to be attempted. Both selected channels reserve together
for one recipient. A blocked recipient stays pending while affordable peers
receive individual `FireClient` calls. Replacing a key resets its pending
recipients to the surviving captured audience, retaining its first-dirty age.
No later joins are added. All four-lane, 64-key, 16384-unit and one-second expiry
limits continue to apply.

Independent flush reports and status add a frozen `recipients` array containing
`player`, `selected`, `remaining`, `reliableHandoffs`, `unreliableHandoffs`,
`logicalHandoffs`, and optional `error`. `selected` counts distinct keys consumed
before an attempt; refused preflight selects zero. Top-level `remaining` counts
distinct pending keys, while logical handoffs sum successful per-recipient
records. An attempted recipient's selected work is consumed before uncertain
handoff and is never replayed; unattempted peers remain pending. These reports
describe local progress, without an acknowledgement or receipt guarantee.
Automatic independent service waits at least `max(flushAfterSeconds, 1/60)`
between rounds; expiry may wake earlier to discard old work.

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
Players are not added to a fixed `CreateState` audience. Supply their initial current
snapshot from game state and create a lane with the intended audience when that
audience changes.

Replacement concerns unsent values. Unreliable updates can still drop or arrive
out of order after handoff. Include an application tick/sequence and filter stale
values in the receiving handler when needed. Readiness is a listener claim;
the game still owns audience selection and authorization.

For an application recipe covering shared queue pressure, failed handoffs,
key release and current-state submission after an audience rebuild, see the
[State example](../examples/README.md#queue-pressure-and-failed-handoffs).

### Shared broadcast State

Use the server-only `CreateBroadcastState(flushAfterSeconds)` when the latest
unsent snapshot for each event/key should reach every current Player through
shared packets. It returns the same strictly typed `StateHandle` as `CreateState`,
with `Put`, `Remove`, `Flush`, `GetStatus`, and `Destroy`:

```lua
local lane, problem = server:CreateBroadcastState(1 / 60)
assert(lane, problem and problem.message)
assert(lane.events.Pose:Put(entityId, "Normal", entityId, tick, position))
assert(lane.events.Pose:Put(entityId, "High", entityId, newerTick, newerPosition))
local ok, flushProblem, report = lane:Flush()
-- Only the latest unsent Pose for this key was selected.
lane:Destroy()
```

Here Pose declares entity ID, tick and position as payload fields; the queue key
itself is sender-local and is not transmitted. Only outgoing State events appear
on the handle. Creation requires a started,
intact server and `0 < flushAfterSeconds <= 0.1`; this constructor has no options
argument. It shares the existing four lanes, 64 active keys, 16384 retained body
units, one-second first-dirty expiry, priority ordering and FIFO/State flush guard.
Each channel selects at most 32 records within its complete 8192 Reliable / 900
Unreliable unit cap and 16-reference cap, including wrappers and eight units per
reference. No decoder, descriptor or wire version changes.

Each nonempty selected flush validates a fresh complete, dense, unique roster
of at most 1024 current Players using the shared broadcast audience checks.
Players who join before the flush are included; departed Players are not retained
by the lane. The payload must be appropriate for all current Players: listener
readiness and game permissions do not filter this audience. Empty or fully
expired flushes perform no roster lookup, debit or native handoff.

With `outboundBytes`, Reliable and Unreliable selected bytes are reserved together
for every current recipient before either handoff. Audience refusal returns
`InvalidAudience`; insufficient budgets or a missing budget owner return
`OutboundRateLimited`. As with shared FIFO, a missing active roster owner without
an outbound policy returns `InvalidAudience`. Refusal reports zero selected and
handoffs, retains unexpired pending snapshots, and schedules only expiry cleanup.
Retry explicitly with `Flush`; a later accepted `Put` keeps ordinary State
scheduling and replacement behavior. This handle does not opt into automatic
multi-player budget deferral.

Each populated channel uses one protected `FireAllClients` call at endpoint zero,
Reliable first, with live Instance scope and transport integrity checks. A
nonempty packet can still use that call when the roster is empty. Reports count
native handoffs and logical records once, while outbound byte charges multiply
by recipient count. Successful calls do not prove receipt.

Selected snapshots leave the queue before uncertain handoff, including selected
work in a later channel that is not reached after an earlier failure. They are
never replayed automatically. The lane retains ordinary State behavior: it stays
open after a handoff failure for new or unselected pending work, unless session
teardown closes it. `Remove` and `Destroy` release keys, retained references and
timers as usual. Receivers still reject an entire malformed State frame before
calling any handler.

This lane stores unsent values only. It does not retain handed-off state for late
joins, periodically resend snapshots, add unreliable ordering, or interpolate.
Include an application tick when the receiver needs stale-state filtering and
submit current authoritative state for newly joined Players.

### Scheduled ordered streams

An eligible server event handle provides `CreateBroadcastStream(options)` for
all current Players, or `CreateStream(player, options)` for one current Player.
Declare an `OrderedUnreliable` event with exactly two fields: an `f64` server
time, then an optional state. The state may be a bounded struct for several
values, but cannot itself be optional. Definition-level `bitPacking` must be
false or absent. Other event handles and clients have no stream constructor.

```lua
local s = Relay.schema
local definition = assert(Relay.define({
    name = "PoseStream", version = 1,
    events = {
        Pose = s.serverToClient(1, s.fields(
            s.field("serverTime", s.f64(0, 1e12)),
            s.field("position", s.optional(s.Vector3F32(-10000, 10000)))
        ), { delivery = "OrderedUnreliable" }),
    },
}))
-- After server:Start():
local stream, problem = server.events.Pose:CreateBroadcastStream({
    rate = 10, fastRate = 20, keepalive = 1, epsilon = 0.05,
})
assert(stream, problem and problem.message)
assert(stream:Set(position)) -- owns a validated snapshot; latest Set wins
assert(stream:SetFast(true))
assert(stream:Urgent()) -- send at the next Heartbeat step
-- assert(stream:Clear()) -- one explicit nil notification, then Idle
-- stream:Destroy() -- local cleanup; cancels pending sends, including Clear
```

Clients use the existing `Connect(function(serverTime, state) ... end)` or
`Once`; a callback with `state == nil` is a delivered clear. Packet loss invokes
no callback. `false` is a valid state. `Set(nil)` rejects: use `Clear`.
The existing schema descriptor and ordered formats 3/6 are unchanged. Timestamp,
optional presence, state and any native Instance sidecars all fit the complete
900-unit bound; each sidecar costs eight units and the existing limit is 16.
The first f64 bounds must admit zero and the current server clock at creation,
and every sampled time at handoff. An out-of-range later clock pauses with
`InvalidPayload` before charging or advancing the ordered sequence.

`rate` is required and finite in `[0.1,60]` sends/second. Optional `fastRate` is
higher than `rate` and at most 60. `keepalive` is in `[1/rate,60]` seconds,
defaulting to `max(1,1/rate)`. `SetFast(true)` requires a configured fast rate;
`SetFast(false)` restores the normal rate. The native Heartbeat limits effective
cadence. A delayed step sends at most once and never catches up missed packets.

The first `Set` sends on the next step. Changed state follows the selected rate.
One unchanged resend follows a changed handoff to signal that motion stopped;
then unchanged values suppress sends until keepalive. Keepalive also makes
active shared state eligible for Players who joined since the last handoff.
Delivery still depends on admission and unreliable transport. No history is
replayed. `Urgent` brings an active send to the next step without accumulating
requests; it does nothing in Idle and does not resume a paused stream.

Comparison uses owned, canonical encoded values and Instance identity, excluding
the timestamp. `epsilon`, default zero, is finite in `[0,1000000]`; positive
values are supported only for direct f32/f64 or Vector2F32/Vector3F32 states,
comparing each component with the last handed-off normalized value. Other shapes
use exact encoded equality. Tables and buffers passed to `Set` may be mutated
afterward without changing the owned snapshot. A rejected `Set` preserves the
previous snapshot and deadline.

`Clear` schedules one best-effort nil notification at the next step, including
for an Idle handle, then releases snapshots and timers after a successful native
handoff. A lost clear has no delivery guarantee; use an application stale-time
policy when disappearance matters. `Destroy` only releases locally and cancels
a pending `Clear`; wait for Idle first if that clear handoff is wanted. Departure
also destroys a targeted stream, and session teardown destroys all streams.
At most 64 stream handles exist per session, one per event/Player. A shared owner
excludes targeted owners for that event and vice versa. Each owner has one timer
and at most two snapshots; conservative session retention is at most 115200
modeled snapshot units and 2048 native references. Idle handles have no timer.

`Set`, `Clear`, `Urgent` and `SetFast` return `(boolean, RelayError?)`.
`GetStatus()` returns `state` (`Idle`, `Active`, `Paused`, `Destroyed`), `fast`,
`pending`, optional `lastError` and optional `lastSentTime`, with no payload.
Outbound budget refusal retains unsent state and retries at the chosen cadence;
`Urgent` preserves that retry deadline. Refusal never updates the last-sent value
or timestamp. Scope/payload or uncertain
transport failure pauses automatic work. A fresh `Set` or `Clear` revalidates and resumes;
`Urgent` cannot replay a paused submission. Successful calls prove native handoff,
not delivery. Ordinary event methods remain explicit manual sends and share the
same endpoint sequence; applications mixing them own their state/time choices.

A client can retain just two received samples for interpolation. This example
returns a position for application rendering, clears on nil, and drops stale
state. Rendering and extrapolation policy remain with the game:

```lua
local olderTime, newerTime = nil, nil
local olderPosition, newerPosition = nil, nil
assert(client.events.Pose:Connect(function(serverTime, position)
    if position == nil then
        olderTime, newerTime, olderPosition, newerPosition = nil, nil, nil, nil
        return
    end
    olderTime, olderPosition = newerTime, newerPosition
    newerTime, newerPosition = serverTime, position
end))
local function samplePosition()
    local now = workspace:GetServerTimeNow()
    if newerTime == nil or newerPosition == nil or now - newerTime > 2 then
        return nil
    end
    if olderTime == nil or olderPosition == nil or newerTime <= olderTime then
        return newerPosition
    end
    local targetTime = now - 0.1 -- one normal-rate interval behind
    local alpha = math.clamp((targetTime - olderTime) / (newerTime - olderTime), 0, 1)
    return olderPosition:Lerp(newerPosition, alpha)
end
```

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

Declare reliable requests beside the event map. Each request
has an ID, ordered request fields, and one anonymous response shape:

```lua
local definition, problem = Relay.define({
    name = "Inventory", version = 1, events = {},
    requests = {
        Inspect = s.request(1, s.fields({ itemId = s.u32() }),
            s.struct(
                { owned = s.boolean() },
                { count = s.u16() }
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
owns at most eight pending requests, with one per method by default. IDs never repeat within
its session. `Await` yields while pending, permits one waiter, and returns a
frozen `{ ok = true, value = response }` or `{ ok = false, error = RelayError }`.
Repeated Await reads the same settled result and decoded value.
`Cancel()` settles locally with `Cancelled`; it does not undo server work.
It does not stop the server handler or release its server-side reservation.
Timeout and cancellation leave the outcome of server side effects uncertain.
If game code submits the operation again, the new `Request` has a new identity and
may execute again. Use an application operation ID and server-owned idempotency
policy when such retries must avoid duplicate effects.

The [operation-ID reward shop example](../examples/operation-id-rpc/README.md)
uses bounded server-owned reservations/receipts and an explicit read-only lookup
after timeout. Its idempotency lasts only while that account's reservation or
unexpired receipt remains in this server; persistent effects need an
application-owned atomic transaction/ledger.

The server handler receives the actual firing Player and must return exactly
one value. False is valid; an optional response permits explicit nil. A thrown
handler returns `HandlerFailure`, and an invalid result returns `InvalidResponse`,
without sending exception text. Game denial belongs in the declared response.
Client-to-server requests share event admission budgets and the eight/player,
64/session server handler limits. A method defaults to one active handler per
player. Missing listeners, busy or rate-limited requests are dropped by default
and can therefore time out. A bounded 64-identity recent ring plus active identities
rejects replays; this is no durable exactly-once guarantee. Departures, destroy,
transport loss, deadlines and cancellation release owned pending state. Late
responses are ignored. Relay never retries a request automatically.

An optional fourth constructor argument configures the direction, per-method
concurrency and prompt refusals:

```lua
Confirm = s.request(2, s.fields({ prompt = s.string(64) }), s.boolean(), {
    direction = "ServerToClient", concurrency = 2, refusals = true,
})
```

Direction defaults to `ClientToServer`, concurrency to1 (integer1..8), and
refusals tofalse. With `ServerToClient`, the client connects
`client.requests.Confirm:Connect(function(prompt) return false end)` and the
server calls `server.requests.Confirm:Request(player, 5, "Ready?")`.
The exact same typed single response and pending-handle semantics apply.
Server callers own at most eight pending calls per player and64 per session;
client RPC listeners have eight total handler slots. Each method is also
bounded by its declared concurrency. Cancelling or timing out a caller leaves
the callee's handler lease held until its work ends. Direction-specific APIs
and identities prevent response packets from becoming requests or settling a
call in the other direction.

Server handlers for client-to-server methods can opt into a server-local
deadline and lifetime signal with `ConnectWithContext(timeoutSeconds, handler)`:

```lua
server.requests.Inspect:ConnectWithContext(5, function(player, context, itemId)
    if context:GetState() ~= "Open" then return { owned = false, count = 0 } end
    return inspectFor(player, itemId)
end)
```

The finite timeout must be greater than zero and at most 60 seconds. The frozen
context exposes an absolute `deadline` in `os.clock()` seconds and
`GetState()`, which returns `Open`, `DeadlineExceeded`, or `Closed`. The deadline
is local to the server handler and is not sent to the client; caller-side
`Request` timeouts and `Cancel()` do not reach it. State is cooperative: Relay
does not stop the handler or undo game effects. A deadline alone keeps the
handler lease until the callback returns. Player departure, session `Destroy`,
or callback return closes the context. `GetState()` also detects a Player that
has left `Players` before `PlayerRemoving` runs. A retained context cannot reopen
for a later roster entry, and Relay clears its Player references when it closes.
Ignoring the state leaves the handler and its normal response path unchanged.

With `refusals = true`, valid requests can settle with `Busy`, `NoListener` or
`EndpointRateLimited`. The receiver reserves a refusal-work token before
copying/decoding a rejected request: eight burst/eight per second per player
(or client), plus64 burst/64 per second across the server. Malformed bodies
retain this debit and get no reply. Shared inbound call/byte refusals, replay,
unknown endpoints, malformed traffic and exhausted refusal budgets still drop
silently. Valid refusal replies also obey the outbound byte budget. These
bounded replies improve feedback without guaranteeing that every request gets
a refusal. Server-owned pending calls settle `InvalidResponse` on the first
matching malformed client reply; unrelated identities cannot settle them.

Object-producing operations return `object, nil` or `nil, error`; other boolean
operations return `true, nil` or `false, error`. Errors are frozen `{ code,
message }` records. For `assert`, pass `err and err.message` because Relay errors
are records, not strings. The stable codes are `InvalidDefinition`, `InvalidOptions`,
`WrongRuntimeSide`, `AlreadyStarted`, `NotStarted`, `Destroyed`,
`AlreadyConnected`, `InvalidHandler`, `InvalidPayload`, `InvalidPlayer`, `InvalidAudience`,
`StartupTimeout`, `RemoteOwnershipConflict`, `DefinitionMismatch`,
`Disconnected`, and `TransportFailure`. Requests also use `RequestLimit`,
`RequestIdExhausted`, `RequestTimeout`, `Cancelled`, `AlreadyAwaiting`,
`NotYieldable`, `HandlerFailure`, and `InvalidResponse`. Budgeted RPCs can also
settle with `OutboundRateLimited`; opted-in prompt refusals also use `Busy`,
`NoListener` and `EndpointRateLimited`. Readiness also uses
`ReadinessDisabled` and `ReadinessExhausted`. FIFO batches also use
`QueueLimit`, `QueueFull`, `QueueClosed`, and `QueueBusy`; cancelling an open
batch makes its cached `Flush` result `Cancelled`. State operations also use
`InvalidStateKey` and `InvalidPriority`.
Path diagnostics from `Relay.define` identify
the first rejected field path and reason, bounded to 256 bytes. Long paths elide
their middle. Packet errors keep fixed messages and retain no rejected payload.

## Lifecycle and admission

Both constructors accept optional `namespace = "library_v1"`. Omit it to keep
the default `ReplicatedStorage.RelayRemotes`; an explicit name selects the sibling
folder `ReplicatedStorage.RelayRemotes_<namespace>`. Names are 1..32 ASCII bytes,
start with a lowercase letter, and contain only lowercase letters, digits,
underscores and hyphens (`[a-z][a-z0-9_-]*`). Invalid names return `InvalidOptions`.
The explicit name `"default"` is distinct from omission. Names are captured at
construction and must match on both peers. There is no path or parent option.

One session may start per namespace and runtime side, including across current
loaded copies in a single serial Luau VM. The server creates and owns each root,
containing `Definition` and `Reliable`, plus `Unreliable` when needed. An existing
same-copy session returns `AlreadyStarted`; an occupied server root returns
`RemoteOwnershipConflict` and is never adopted. At most eight named roots plus
the default are allowed. Every direct child with the reserved `RelayRemotes_`
prefix counts toward the named limit, including foreign or corrupt occupants;
reaching the limit returns `RemoteOwnershipConflict`.

Before discovery, clients claim a local empty Folder named
`RelayClientSession_<rootName>` under ReplicatedStorage. These ownership markers
do not replicate to the server or create transports. A duplicate marker returns
`AlreadyStarted`; eight named markers return `RemoteOwnershipConflict`. Waiting
startup attempts count, and foreign occupants with the reserved
`RelayClientSession_RelayRemotes_` prefix count too. Marker
loss or contamination ends its owner and releases discovery resources. Cleanup
removes only the owned empty marker, preserving foreign descendants. Older copies
do not use these client markers, so cross-version client exclusivity is not
guaranteed. Actor and cross-VM ownership are unsupported.

Readiness, admission budgets, pending requests, queues and Destroy are independent
for each namespace. Destroying or losing one transport leaves the others active.
The unnamed default retains its folder, descriptor and wire contract. Legacy
clients discover only the default; named clients never fall back to it. A missing
namespace times out, a matching root with a different descriptor returns
`DefinitionMismatch`, and wrong classes or extra leaves are ownership conflicts.
An incompletely replicated root may wait for its leaves until the startup deadline.
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

`inboundRate.fairness` optionally reserves aggregate **call** allowance for a
bounded number of peers. For example:

```lua
inboundRate = {
    perPlayer = { capacity = 4, refillPerSecond = 4 },
    aggregate = { capacity = 4, refillPerSecond = 4 },
    fairness = { maxPeers = 2, reserve = { capacity = 1, refillPerSecond = 1 } },
}
```

This partitions the existing aggregate allowance into two reserved `1/1` buckets
and a shared `2/2` bucket. After the per-player charge, an attempt takes its own
reserve token if available, otherwise a shared token, then pays the original
aggregate charge. `aggregateRate` includes reserve/shared-pool refusal. Charges
are never refunded after later rejection. Every channel and route, including
readiness, RPC and each FIFO/State logical record, uses this gate; a refused queued
frame keeps earlier charges and dispatches no records. Malformed attempts spend
their sender's allowance too. Omission retains the existing admission behavior.

The first `maxPeers` roster entries receive slots; initial roster order is not a
priority or trust rule. Extra peers use only the shared pool, with no automatic
promotion. A departing peer frees its slot while the bucket retains its tokens
and refill state for its next owner, preventing churn from creating reserve
credit. At Start, all slots and the shared pool start full with one clock origin.
Refill is continuous and saturating using the admission timestamp, with backwards
time clamped independently in each bucket. Destroy releases all slot ownership
and bucket state. No payload, handler, retry or admission queue is retained.

`maxPeers` is an integer `1..64`; `reserve` uses the existing finite per-player
capacity/rate bounds and must not exceed the corresponding `perPlayer` values.
`maxPeers * reserve.capacity` and `maxPeers * reserve.refillPerSecond` must each
be strictly below the aggregate value, leaving at least one shared burst token
and positive shared refill. Tables have only the shown keys and no metatables;
invalid policies return `InvalidOptions`. The policy is copied at construction
and appears frozen in diagnostics. State is bounded to 64 reserved buckets plus
one shared bucket per server session, with slot lookup only on roster changes.
Wire descriptors, packet/count/depth bounds and handler ceilings are unchanged.

In this example, a hostile slotted peer may spend its own token and both shared
tokens first; the other slotted peer can still submit one command initially and
after each full second of refill. Service also requires enough per-player,
byte and endpoint allowance, available handlers, a valid payload and live
transport. Byte budgets and handler capacity are not reserved. Peers can spend
their own reserve on malformed attempts; identity assignment remains external.
This policy makes no transport QoS, delivery, CPU or general scheduling guarantee,
and does not change State's existing High/Normal/Low selection order.

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
An endpoint-limited RPC is silently dropped by default; opt-in prompt refusals
may return `EndpointRateLimited` under their separate work and byte budgets.
Shared call/byte refusals remain silent. The pending deadline bounds waiting. Endpoint
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
| Instance reference slot in format 4 | 8 per occurrence |
| `CFrame` | 96 |
| `string` | 2 + byte length |
| `buffer` in a mixed tuple | raw byte length |

The estimator examines at most eight arguments without packing or traversing
tables for existing call shapes. Before that path, a reference frame is accepted
for byte estimation only when its buffer has a bounded format-4 header, its
count is at most 16, its actual arity is exactly one buffer plus that many
slots, and every slot is an Instance or nil. Its charge is `buffer.len + 8*N`;
nil still pays for its slot before the decoder rejects it. A malformed header,
count, arity, or slot kind is refused before endpoint lookup. This bounded scan
does not traverse or pack a table.

An invalid outer endpoint selector (anything other than an integer
`0..65535`), more than eight arguments, or an unsupported argument type is byte-
refused on the existing call shapes. This includes tables, direct native-tuple
Instances and explicit nil; valid optional payloads use Relay buffers. Format-4
reference calls, format5 queues, format6 ordered frames and format7 RPCs are
bounded exceptions with exact sidecar arity. Native charges are conservative content accounting rather
than measured native transport encoding. Existing size, schema, queue, replay,
pending-request and handler caps still apply after byte admission.

### Outbound byte budgets

Add `outboundBytes` to the shared `Relay.define` record to cap server-originated
application data per current player:

```lua
local s = Relay.schema
local definition, problem = Relay.define({
    name = "Gameplay",
    version = 1,
    outboundBytes = { capacity = 65536, refillPerSecond = 32768 },
    events = {
        Snapshot = s.serverToClient(1, s.fields({ ready = s.boolean() })),
    },
})
local Events = assert(definition, problem and problem.message)
```

The closed policy accepts an integer `capacity` from `1..33554432` and a finite
positive `refillPerSecond` no greater than `16777216`. Relay copies and freezes
it. Each current player gets one bucket, created and removed with that player's
session state; there is no aggregate outbound bucket. The exact capacity and
binary64 refill rate are part of the RR14 definition descriptor, so server,
client and shared definition must be upgraded together.

The policy covers server `Send`, `Broadcast`, `SendTo`, and `SendExcept`, RPC
responses, and FIFO/State envelopes. It uses the existing deterministic Relay
content units: bounded native-tuple estimates, exact buffer lengths, and
`buffer.len + 8 * referenceCount` for Instance frames. Ordered and RPC envelope
bytes count; queued sends charge the final selected channel packet for each
recipient. These units do not measure Roblox's outer encoding or engine bytes.

Before a send, Relay checks every selected current recipient at one timestamp,
then reserves all their charges synchronously before handing off. A local
`OutboundRateLimited` refusal performs no handoff and debits none of the
selected players. A budgeted `Broadcast` checks the actual current `Players`
snapshot because `FireAllClients` reaches that full set; it fails closed if
the snapshot exceeds the audience cap or any current player has no active
budget owner. It never sends to an uncharged player. Charges remain after a
transport error or partial handoff because delivery may be uncertain.

When a legacy v1 RPC response cannot fit the caller's remaining budget, Relay sends an
empty 44-byte kind-5 control response and the client settles the request with
`OutboundRateLimited`. This bounded library response is exempt from the budget;
normal success and application-error responses pay their full content charge.
Upgraded v2 failure replies, including kind5 and opted-in kinds6..8, must fit
the normal byte budget. If the control reply cannot fit, it is dropped; no
second uncharged refusal is sent. Outbound server requests also reserve their
complete packet and sidecar charge before handoff.
The request handler may already have performed side effects before its response
is refused, so Relay never retries it automatically. Readiness and ordered setup
controls are also exempt; ordered application frames are charged normally.

A FIFO budget refusal retains all records, returns `false, OutboundRateLimited`
with zero handoffs, leaves the batch open, and stops its timer. Call `Flush()`
again explicitly to retry. `GetStatus()` reports `state`, `pendingRecords`, and
`lastFlush` (including its error and report); `Cancel()` or session teardown
ends retained ownership. By default, a State refusal keeps selected snapshots pending and
continues only expiry cleanup. A new `Put()` or explicit `Flush()` may retry;
expiry itself never resends data. No refusal silently drops pending records.
The server-only `deferOutbound` option described in
[Latest unsent state](#latest-unsent-state) additionally permits bounded automatic
service for captured audiences, with atomic or opt-in independent recipient
progress. Existing byte/key/age caps still apply.

Relay silently drops malformed traffic and early admission refusals. Events
keep silent listener/rate/capacity drops; RPC can opt into bounded prompt
refusals. A yielding handler retains its slot: one per player/event endpoint,
the declared1..8 concurrency per RPC method, at most8 per player and64
server-wide; client events allow one per endpoint and client RPC eight total.
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
active Relay leases, handler limits, server inbound-rate and outbound-byte
settings, and cumulative session/per-event counters. Server snapshots expose the
copied outbound policy when configured; client snapshots report `outboundBytes =
nil`. It never samples a clock or refills a budget.

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

`outboundByteRejected` counts server-side per-player budget refusals, and
`outboundBytesCharged` sums reserved Relay content units across recipients.
Charged handoff attempts remain counted after transport errors; these counters
do not measure Roblox wire bytes or successful receipt. `inspect` reports the
definition's `bitPacking` flag and copied `outboundBytes` policy. Its fixed
`limits.compactRotationErrorRadians` value is `0.002`; vector and compact-CFrame
body widths and packed masks are included in the existing event, request, and
queued byte bounds.

Counters saturate at 4,294,967,295 and retain no player identities, payloads,
stacks, or logging history. The `stale` counter records ordered duplicate,
backward and wrong-generation drops; malformed frames use `invalidPayload`.
The default diagnostics have 21 session counters and ten per event, at most 661 counters under the
current event limit. Cleanup makes active leases
zero in terminal snapshots; user callbacks may still be suspended. Late callbacks
do not update terminal counters. Caller-retained snapshots are caller-owned memory.

### Opt-in traffic and refusal reports

Both session constructors accept the closed option
`diagnostics = { traffic = boolean?, reports = boolean? }`. When disabled,
`GetDiagnostics().traffic` and `.reports` are nil. These local options do not
change descriptors or send diagnostic network traffic.

```lua
local server = assert(Relay.createServer(Events, {
    inboundRate = {
        perPlayer = { capacity = 32, refillPerSecond = 16 },
        aggregate = { capacity = 128, refillPerSecond = 64 },
    },
    diagnostics = { traffic = true, reports = true },
}))
local snapshot = server:GetDiagnostics()
local reliable = snapshot.traffic.channels.Reliable
local input = snapshot.traffic.endpoints[1] -- stable event/request ID
print(reliable.sentPackets, input.channels.Reliable.validatedRecords)
```

Traffic has `channels.Reliable` and `channels.Unreliable`, plus an ID-keyed
`endpoints` table for every declared event and request (at most 64 combined).
Each endpoint row includes `id`, `name`, `kind` (`Event` or `Request`) and the
same channel rows. Event and request names may coincide; their IDs remain unique.
Each channel row exposes saturating counters:

| Counters | Meaning |
| --- | --- |
| `submittedRecords`, `submittedBytes` | Accepted API submissions, including each accepted replacement before coalescing. |
| `sentPackets`, `sentRecords`, `sentBytes` | Successful local native handoffs and their logical records/content units. |
| `sentRecipientBytes` | Successful handoff content units multiplied by recipient count. |
| `receivedPackets`, `receivedBytes` | Observed incoming packets and exact known modeled content units, before admission. |
| `validatedRecords`, `validatedBytes` | Fully validated incoming logical records/content units. |
| `unmeasuredPackets` | Incoming packets whose arbitrary native arguments have no known bounded content model. |

`submittedBytes` and `validatedBytes` count logical encoded body and reference
units in both channel and endpoint rows. Sent/received channel bytes include the
complete packet envelope and eight units per reference. Sent/received endpoint
bytes include body and reference units, excluding queued row/wrapper, ordered
sequence and RPC identity headers. Direct native tuples retain their three-unit
content prefix. Bodyless RPC controls have zero endpoint body units while the
channel counts their full packet. Direct ordered sends and streams use the same
units. A batch counts one packet per channel and once for each distinct
represented endpoint; repeated rows still count individually as records. RPC
request, reply, failure and refusal traffic is attributed to its method;
readiness and ordered setup controls are channel-only. Unknown endpoint IDs do
not allocate new rows. Known over-cap buffers use their actual observed size;
the capped admission sentinel is never presented as an observed byte total.
A queued frame contributes no validated records until every row, including its
timestamp if present, passes validation.
Pending-request `Cancel()` settles locally and creates no network frame or
traffic counter increment.

These are Relay content units, not physical Roblox wire bytes, acknowledgements
or successful callbacks. `outboundBytesCharged` remains the reservation ledger,
including uncertain/failed attempts; `sentRecipientBytes` counts only successful
native handoffs. The two counters need not match.

Reports retain a fixed 16-slot ring of scalar rows: bounded `reason`, optional
known `endpointId`/`channel`, saturating `count` and `sequence`. Matching keys
aggregate. The snapshot includes `capacity`, `total` and frozen `entries`.
Reasons cover rate/byte admission, endpoint/channel/payload rejection, missing
listeners, busy handlers, stale data, queue pressure/lifecycle, transport and
handler errors. Reports retain no Player, payload, exception text, stack or
timestamp. Snapshots are copied/frozen only on explicit inspection; destruction
stops updates while retaining the bounded postmortem snapshot.

Reliable transport can still lose application callbacks to these admission and
handler guards. Diagnostics do not establish fairness, bandwidth, receipt,
engine-drop reasons, or exact Roblox encoded sizes.

These are remote-abuse and resource-exhaustion limits on Relay-owned work.
Roblox supplies transport and Player identity; Relay buffers add no authentication
or encryption and provide no infrastructure DDoS protection. Roblox incurs engine
ingress and argument materialization costs before Relay's Luau guards run. These
limits do not bound Roblox traffic, scheduling, or a developer handler's own work.
A shared aggregate limit alone does not guarantee fairness. The optional peer
call reservation above protects only its stated allowance and conditions.
Game code owns authorization,
ownership, cooldowns, costs, persistence, and replay policy. Roblox's
[client-server boundary guidance](https://create.roblox.com/docs/scripting/security/client-server-boundary)
describes those application responsibilities.

The isolated real Studio correctness proof is `lune run
tests/studio-reliable-events.luau`; it is separate from the portable aggregate
verifier and from timing benchmarks. Relay makes no performance ranking claim.
Append `--correctness-only` to run the two-client correctness scenario during
development, or `--competitive-only` for the focused two-client pacing, State
progress, timestamp and traffic/report checks. Omit both flags for the full
correctness and admission matrix.
