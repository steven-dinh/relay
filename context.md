# Relay Context

Handler cancellation characterization uses the existing portable event/client/RPC/
batch suites and Studio fixture. External `task.cancel`/`coroutine.close` of a
Relay callback thread is unsupported because it can skip post-handler reservation
release; cooperative cancellation returns through the callback instead. Listener
replacement preserves occupied capacity. Removal/teardown (including client
transport loss) clears Relay accounting without stopping arbitrary application
work; late side effects remain application-owned. Client pending-RPC cancellation
does not stop server handlers or release server capacity. This slice changes no
runtime, protocol, public API or version, and records no timing claim. Exact
portable/native proof is retained under `.tmp/handler-cancellation-20261015/`.

## Purpose and boundaries

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. Publishable source lives
under `src/`; it has no game repository, Core, or runtime dependency.

The Wally package is `steven-dinh/relay` version `0.3.0`, realm `shared`.
The private, unreleased candidate is the next minor because it changes
primitive unreliable definitions from `RR2` to `RR7`; `RR8` and new shapes require
matched peers. Publication remains disabled with `private = true`.
Tool versions are pinned in
`rokit.toml`, including Lune `0.11.0` and luau-lsp `1.70.1` (both Luau `0.740`).

GitHub releases attach only the Relay `.rbxmx` model and source ZIP. Example
places, Wally ZIPs, installation files, manifests, and checksums are not release
attachments.

The public GitHub Pages site is plain dark, static documentation in
`docs/index.html` and `docs/styles.css`, with `docs/.nojekyll` bypassing Jekyll.
It has home/version notes and general, types, events, functions, cleanup, and
benchmark sections, linking to `docs/reference.md` for the detailed API contract.
README.md is the short repository overview and quick start.
The site and main API reference describe development source, which may differ
from a published release with the same version constant. README and the site lead
with the exact published v0.2.0 model, matching tag reference/example, and source ZIP;
the development build remains explicit. The reference links the published install and
routes common recovery actions to existing contract sections. Starting with v0.2.0,
published release tags preserve their API reference; README, reference, and site
link to the published v0.2.0 reference. The public-type gate checks these documentation links.
The cached `InvalidDefinition` fallback is generic and unversioned; its code and
validation behavior are unchanged.
The API reference's Environment, support, and reporting section separates tested
native source/build evidence from runtime and new-solver requirements, and routes
ordinary minimal bug reports to GitHub issues. A private security-reporting route
is enabled through GitHub. `SECURITY.md` owns private reporting, coordinated
disclosure and best-effort maintenance: the newest released minor series' latest
patch, a seven-calendar-day acknowledgement target, compatible patch releases,
documented pre-1.0 breaking minor releases and one-release deprecation notice
except for urgent security corrections. Releases follow verification rather
than a calendar. The root policy is included in the checked package inventory;
these policies do not expand native qualification or promise a fix deadline.
Benchmark tables mirror `benchmarks/README.md`, keeping the September 26
Native/Relay snapshot separate from the historical multi-library comparisons,
with workloads, Studio/broadcast groups, measured versions, revisions, and timing
units intact. Canonical workload tables lead with inverse-median sender FPS,
Native-relative scales, and sorted ranks; uncaptured bandwidth stays Unmeasured.
The audited October 7 quick cohort has separate FPS-sorted local diagnostic
tables with measured engine-wide KB/s and exact verified counts, keeping broadcast
modes separate. Tooling links cover quick runs and receive profiling.
The Studio correctness harness also exercises the current StateQueue.Put with
native buffers and controlled logical expiry across 0/1/16/64 keys, one/four
lanes, cross-lane rejection preservation, admitted expiry, and decoded flush
bytes. This fixture records no performance samples.
It has no logo, scripts, runtime dependencies, or build step. GitHub Pages serves
https://steven-dinh.github.io/relay/ from `main`'s `/docs` folder; other `docs/`
contents stay ignored.

The approved public surface is `VERSION`, `schema`, `define`, `inspect`,
`createServer`, and `createClient`. Sessions expose `events`, `requests`,
`Start`, `GetDiagnostics`, `CreateBatch`, `CreateBatcher`, `CreateState`, and
idempotent `Destroy`; clients also
expose `RefreshReadiness`.
Event handles expose direction-specific `Connect`, `Once`, `Send`, `Broadcast`, `SendTo`, and `SendExcept`;
ServerToClient server handles also expose `GetReadyPlayers`.
connections expose idempotent `Disconnect`. Expected failures return frozen
`{ code, message }` errors. Definitions, compiled records, handles, and exports
are frozen; internal modules are not public exports.

Static payload derivation requires Luau's new solver and ordered type metadata.
`Relay.schema` supplies frozen constructors, field naming, reusable shapes, and
bounded whole-map composition with exact inferred event keys. Its native-value
helpers cover 22 bounded Roblox shape kinds, including family-precise EnumItems;
`schema.Instance(className)` adds closed-class, precise Instance references for
reliable immediate events, with server scope supplied through `createServer`'s
`instanceRoot` option. `schema.quantized(minimum, maximum, step)` adds opt-in
strictly typed numeric grids with a fixed maximum level count and explicit
rounding-error bound. `quantizedVector2`/`quantizedVector3` retain native vector
types with per-axis error checks; `compactCFrame` bounds both positional and
angular error. Definitions may opt into block bit packing and per-player
outbound byte budgets. Raw records and the original ordered example helper remain
compatible. Preferred
authoring uses `fields` and struct arguments with ordered single-key entries,
explicit ordinal enum maps, a keyed union discriminator and typed delivery/queue
options. These forms preserve exact names without caller singleton casts or
special final-call parentheses; legacy forms retain their pinned-solver rules.
Construction normalizes to the shared grammar. Definitions without new wire
features retain their existing descriptors and payload bytes. The new features
select RR10 scalar quantization, RR11 quantized vectors, RR12 compact CFrames,
RR13 optional bit packing, and RR14 outbound byte budgets, retaining all
applicable feature markers and exact shape/policy metadata. Existing caps and
admission remain in force. Keep schema and
session variables inferred. The composable type fixture captures `assert`'s
return before generic session construction to preserve inference with the pinned
solver. Type-level event, request, and nested-shape checks share one
ordered-metadata reader. Runtime validation
remains authoritative. [The API reference](docs/reference.md) owns usage, schema
grammar, options, error codes, and the
[protocol contract](docs/reference.md#protocol-and-abuse-limits).

## Runtime ownership

| Module | Responsibility |
| --- | --- |
| `src/init.luau` | Public exports, version, and schema-derived event names, methods, payload types, and typed CreateBatch/CreateBatcher/State constructors, including the `Color3RGB8` to `Color3` payload mapping. |
| `src/Schema.luau` | Frozen authoring constructors, bounded keyed-field/struct/ordinal-enum/union/options normalization, native Roblox values including opt-in RGB8 Color3, quantized scalar/vector grids, compact CFrames, typed dictionaries, ordered type metadata, and bounded literal-map composition with collision rejection; definitions independently copy reused shapes. |
| `src/Definition.luau` | Closed schema grammar, including NativeSchema, Quantized and CompactValues metadata, definition-wide bit-packing/outbound-byte options, opaque definition identity, immutable bounded shape compilation, deterministic descriptors, Float32 canonicalization, and bounded setup path errors. |
| `src/internal/Frame.luau` | Endpoint/direction lookup, compiled fixed-arity primitive validators, decode-specific scalar normalizers, and forwarding server/client reference context for affected composite codecs. |
| `src/internal/OrderedFrame.luau` | Fixed bounded ordered-unreliable envelope, private reliable initialization controls and checked body copying through the existing codec. |
| `src/internal/CompositeCodec.luau` | Bounded composite validation, buffer encoding, and checked decoding using Frame's scalar normalizers and raw checks; delegates native values to NativeCodec, scalar grids to Quantized, quantized vectors/compact CFrames to CompactValues, packed blocks to BitPacking, and Instance framing and validation to InstanceRefs. |
| `src/internal/InstanceRefs.luau` | Format-4 reference limits, closed class names, live game ancestry and server-root checks, and bounded scope revalidation before send handoffs. |
| `src/internal/Quantized.luau` | Finite bounded-grid metadata, binary64 alignment/error allowance, stable index selection and reconstruction, exact descriptor tokens, and scalar width selection shared by schema compilation and the checked codec. |
| `src/internal/CompactValues.luau` | Bounded native Vector2/Vector3 quantization and compact CFrame position/XYZ rotation coding, with post-construction component, stable-index, rigid-matrix, and angular-error checks. |
| `src/internal/BitPacking.luau` | Definition-opt-in low-bit-first masks for bounded boolean, literal-enum, and optional flags; exact packed sizing and checked decoding with canonical zero padding. |
| `src/internal/NativeSchema.luau` | Closed native shape keys, bounds, immutable enum/palette/family allowlists, byte/node/depth budgets, and deterministic native descriptor tokens. |
| `src/internal/NativeCodec.luau` | Checked normalization, encoding, and decoding for bounded Roblox values, with raw validation before construction and exact result checks. |
| `src/internal/TokenBucket.luau` | Bounded token buckets, nonconsuming preflight and optional weighted takes, saturating refill, and monotonic clock clamping. |
| `src/internal/Diagnostics.luau` | Fixed saturating counters, immutable snapshots with copied/frozen inbound and outbound policies, and exact local handoff units; no traffic-keyed state or payload retention. |
| `src/internal/RpcFrame.luau` | Fixed RPC envelope, checked correlation identity and body bounds before owned copying. |
| `src/internal/ReadinessFrame.luau` | Fixed format-2 Hello/Challenge/Ack/Close framing with exact direction, counter, GUID, and mask validation. |
| `src/internal/BatchFrame.luau` | Fixed format-2 counted envelope, complete bounded record metadata scan and checked owned body copies for batch ingress. |
| `src/internal/Batch.luau` | One-shot and reusable FIFO windows, channel byte/count caps, lazy deadline timers, sealed handoff state and shared flush guard, immutable partial-handoff reports, and lifecycle cleanup. |
| `src/internal/StateQueue.luau` | Latest unsent encoded snapshots, four lanes sharing 64 keys/16384 pending bytes, deterministic priority/age selection, first-dirty expiry, one timer per lane, and shared queue cleanup. |
| `src/ServerSession.luau` | Transport ownership, current-player, optional inbound and per-player outbound byte admission, server Instance-root ownership and scope checks, shared event/RPC handler leases, dispatch, bounded RPC replay identities and replies, atomic budget preflight for audiences, ordered sequence/generation admission, optional readiness challenges and ready-player snapshots, explicit FIFO batches/state lanes, and cleanup. |
| `src/ClientSession.luau` | Deadline-bound discovery, ordered initialization and requests, descriptor matching, module-slot ownership, live Instance validation, ordered sequence admission, budgeted RPC-refusal parsing, dispatch, request correlation/cancellation, optional listener-readiness handshakes and refresh, explicit FIFO batches/state lanes, transport loss, and cleanup. |

## Runtime invariants

- Definitions allow at most 64 events/requests combined, unique IDs across both
  maps, and eight fields per event/request. Primitive kinds
  are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`,
  `Vector2F32`, `Vector3F32`, `CFrame`, and `Color3`; opt-in `Color3RGB8` is a
  native value leaf. Composable shapes are bounded structs,
  tagged unions, dense arrays, maps, enums, optionals, and primitive-key sets; unbounded maps and
  recursive shapes are unsupported.
- `schema.quantized(minimum, maximum, step)` opts a numeric field into a bounded
  scalar grid. Inputs and bounds are finite, minimum is less than maximum, and
  step is at least `2^-974` so its error allowance remains normal in Roblox.
  The derived step count is rounded to the nearest
  integer (ties advance), with 1..65,535 intervals and an explicit binary64
  endpoint-roundoff allowance; maximum error is `step / 2 + allowance`. Payload
  values are checked against the original bounds before rounding, never clamped,
  and must retain a stable index and remain within the error bound. Exact endpoint
  values are preserved and zero is canonicalized. Ties select the higher index;
  unused wire codes and unstable decoded values reject before dispatch.
  Quantized leaves occupy one or two bytes, one node and depth zero. They may be
  nested in supported event, request, queued and composite routes, but not used as
  map or set keys. Authored quantization, including under zero-capacity shapes or
  in RPC fields, adds the `Q1,65536` marker; it selects RR10 when no higher
  capability applies. `I4,16,8` remains when a definition also uses Instance
  references. Existing frame/envelope, array,
  depth, node, endpoint and admission limits are unchanged.
- `schema.quantizedVector3(minimum, maximum, step)` and
  `schema.quantizedVector2(...)` retain native vector payload types and reuse the
  scalar grid per component. Bounds must be Float32-exact. A native allowance
  `max(2^-126, 2^-23 * max(abs(minimum), abs(maximum), step))` is capped at
  `step / 16`; component error is scalar error plus this allowance. Sender and
  decoder verify the actual native-constructed components, bounds, and stable
  scalar codes. Bodies are 3/6 bytes for Vector3 and 2/4 for Vector2; each is a
  leaf node at depth zero. Authored shapes add VQ1 metadata and select RR11 when
  no higher capability applies.
- `schema.compactCFrame(minimum, maximum, positionStep)` bounds all translation
  axes using the scalar grid and stores XYZ Euler rotation as three periodic u16
  codes. Input and reconstructed matrices must be finite, right-handed and rigid
  within `1e-6`; the actual reconstructed orientation must be within `0.002`
  radians by `AngleBetween`. Position and orientation are checked independently.
  The leaf is 9/12 bytes, one node at depth zero, and adds CF1 metadata; it
  selects RR12 when no higher capability applies. Legacy CFrame encoding remains
  unchanged.
- Definition `bitPacking = true` adds BP1 and selects RR13 unless outbound bytes
  select RR14. It opts the whole definition into block
  masks for booleans, literal enum ordinals and optional flags. Tuple, struct and
  bounded collection blocks carry canonical low-bit-first masks; padding and
  absent optional value bits must be zero. Native Roblox enum ordinals and
  tagged-union discriminators keep their existing encoding. Definitions without
  the option retain their wire representation.
- Definition `outboundBytes = {capacity, refillPerSecond}` opts into RR14 / OB1
  and one token bucket per current player. The server preflights all selected
  recipients at one timestamp and reserves Relay content units before handoff;
  budget refusal makes no handoff or debit. RPC refusal uses the explicit bounded
  kind-5 response; FIFO/State retain pending data for explicit retry. Existing
  inbound order and charges remain unchanged. Diagnostics expose fixed outbound
  refusal/charge counters and the frozen server policy.
- The 22 additional native shape kinds are `robloxEnum`, `UDim`, `UDim2`,
  `NumberRange`, `Rect`, `BrickColor`, `Vector2int16`, `Vector3int16`,
  `NumberSequence`, `ColorSequence`, `NumberSequenceKeypoint`,
  `ColorSequenceKeypoint`, `TweenInfo`,
  `DateTime`, `Ray`, `Axes`, `Faces`, `Region3`, `Region3int16`,
  `PhysicalProperties`, `Font`, and `PathWaypoint`. They require the checked
  whole-tuple codec. EnumItems are bounded allowlists from one family and may be
  set members/map keys; no other new native type is a key. Fixed native leaves
  use one node at depth zero; sequences reserve one depth level and
  `1 + maximumKeypoints` nodes. Sequences are limited to 2..20 points. Finite
  component bounds, exact constructor roundtrip checks, the descriptor and
  frame/envelope caps, and existing admission order/charges remain enforced.
- Bounded `Instance(className)` references support only reliable immediate
  events. The closed classes are `Instance`, `BasePart`, `Part`, `MeshPart`,
  `Model`, `Humanoid`, `Tool`, `Attachment`, `Player`, `Folder`, `GuiObject`,
  `Sound`, `Animation`, and `Animator`; static payload types retain the selected
  Roblox class and runtime checks accept subclasses. References may nest in
  structs, arrays, map values, optionals and tagged unions, never in map/set keys,
  requests, queued routes or unreliable events. `createServer` requires a live
  `instanceRoot` (game or descendant) exactly when the definition has references.
  The server checks reference class, game ancestry and root scope on ingress and
  rechecks scope at each outbound audience handoff; the game DataModel itself is
  not a payload reference. Destroy clears the session-owned root context.
  These checks do not grant gameplay ownership or permission.
- Reference-bearing events use RR9 and format 4, with a four-byte header and
  sequential u8 slots passed as native varargs beside the buffer. At most 16
  references are allowed; each costs 8 deterministic admission bytes, so
  `buffer.len + 8 * referenceCount` must fit 8192. Existing depth, node, array,
  endpoint and frame limits remain in force. Missing, nil, detached, out-of-scope,
  wrong-class or malformed references reject the whole event before callbacks;
  Relay never waits for a streamed object. Definitions without references keep
  existing descriptors and payload bytes.
- The endpoint-count expansion retains the 4096-byte descriptor cap and existing
  descriptor/payload formats; definitions above the former 16-endpoint cap require
  updated Relay copies on both sides. Payload, shape, queue, admission, RPC-pending,
  and handler-concurrency limits remain unchanged. Session diagnostics include
  fixed outbound-byte refusal and charge counters.
- Invalid definitions return fresh frozen setup errors with validated paths/reasons
  capped at 256 bytes; packet errors retain the cached generic records. Diagnostic
  construction never stringifies attacker values or retains rejected schemas.
- Definition inspection exposes exact Relay-buffer bounds or native string-content
  bounds with unknown Roblox encoded size. Session diagnostics preserve first-reason
  guard/admission order and saturate 21 totals plus 10/event at u32 maximum; no player,
  payload, stack or callback retention. Terminal snapshots report zero active leases.
  Once consumes only an admitted dispatch, detaches before callback, and preserves
  yielding leases and the client validator for replacements until terminal cleanup.
  `inspect` exposes `quantizedLevels = 65536`,
  `compactRotationErrorRadians = 0.002`, the definition bitPacking flag and
  copied outbound policy; vector/CFrame widths and packed masks are included in
  existing exact encoded-size bounds, without an unbounded per-leaf report.
  Session diagnostics have 21 fixed counters and ten per event, at most 661
  total; outbound snapshots contain the frozen policy on the server and nil on
  clients. The new counters are `outboundByteRejected` and
  `outboundBytesCharged`.
- Server send audiences are invocation-owned plain arrays bounded to 1024 entries
  and recipients. SendTo/SendExcept deduplicate Player identity, skip departures,
  validate/encode once, and report successful handoffs before partial failure.
  Audience sends bind their stable diagnostic counter row before recipient handoffs.
  Empty audiences still validate; full Broadcast uses FireAllClients unchanged.
  Private roster membership proves immutable Player type/class; send and readiness
  paths still check current parentage before handoff or inclusion.
- Reliable primitive-only definitions use `RR1`; composable shapes select `RR3`.
  `RR7` takes precedence over the existing prefixes when any unreliable event has
  only primitive fields (including zero fields), because that event now uses the
  existing checked buffer codec. Its original shape flag still selects descriptor
  field grammar; request/readiness/queue metadata remains explicit. Definitions
  without a changed event representation preserve their descriptor bytes.
  Startup requires identical descriptors and topology, so affected legacy RR2/RR3/
  RR5/RR6 definitions require updated copies on both sides with no native-tuple
  fallback. Reliable primitive events retain native tuples; all unreliable and
  composite events encode their entire tuple into one buffer.
  RR11 adds quantized Vector2/Vector3 leaves and VQ1 shape tokens; RR12 adds
  compact CFrames with CF1 tokens and fixed XYZ-u16 rotation; RR13 adds the
  opt-in BP1 block codec; RR14 adds OB1 with exact capacity/refill and the bounded
  RPC kind-5 refusal response. The highest used RR prefix wins, while all enabled
  markers and exact shape/policy descriptors remain present. Without any of
  these new capabilities, legacy descriptor and payload bytes are unchanged.
  Every unreliable schema must fit 900 raw bytes including the three-byte header
  and all prefixes; a lone string can declare at most 895 content bytes. Oversized
  schemas return InvalidDefinition and invalid sends return InvalidPayload before
  handoff. The codec checks actual normalized size before output-buffer allocation.
  Inspector bounds describe Relay buffers, not Roblox's encoded size or delivery.
- Bounded `schema.map(key, value, maximumSize)` and raw `type = "map"` shapes
  accept 0..64 entries, bounded string or six integer key kinds, and any supported
  non-optional direct value shape. Missing entries represent absence; false
  survives. Exact `{ [string]: V }` / `{ [number]: V }` types flow through events,
  requests and queue handles, retaining nested struct/union precision without
  `any` widening. The pinned solver can miss incompatible named fields in
  unannotated dictionary literal arguments even for native Luau indexers;
  explicit indexer variables are checked and runtime validates every entry.
  Maps add one depth level and `1 + capacity * (keyNodes + valueNodes)` expanded nodes;
  both children count toward authored nodes even at capacity zero. Existing
  depth 4, nodes 256, string 1024 and all frame/envelope caps remain unchanged.
  A u16 count precedes alternating encoded keys/values; body bounds are 2 through
  `2 + capacity * (keyMaximumBytes + valueMaximumBytes)`. The descriptor's new
  `M<capacity>[key][value]` token reuses existing prefix precedence; peers using
  maps must update together, while non-map descriptor/frame bytes stay unchanged.
  Inspector limits add mapCapacity=64, retaining arraySetCapacity. Normalization
  rejects metatables, counts at most capacity+1 before walking entries, and owns
  fresh nested copies. Decode checks count and minimum remaining bytes before
  allocation/traversal and rejects duplicate validated keys before value decode.
  Existing admission order/retained charges, whole-queue rejection and ordered
  high-water commit rules apply without new session state. Dedicated Sol design
  review approved this bounded slice before implementation. Portable proof does
  not imply a fresh native Studio qualification.
- Ordered immediate events use `delivery = "OrderedUnreliable"` in raw/helper
  schemas with unchanged inferred payload types, RR8 descriptors and an `O`
  delivery marker. Internal compiled events use the Unreliable channel plus an
  ordered flag. Without this capability, all existing descriptors/frames remain
  unchanged. Ordered+Batch/State rejects because local queue keys do not define
  receiver streams. Format 3 uses an 11-byte version/id/generation/sequence header
  and the existing field encoding; the full cap remains 900, base codec cap 892,
  and a lone string can declare 887 content bytes. Existing container/node/depth,
  descriptor, reliable, RPC and queue caps remain unchanged.
  Each sender owns one u32 counter per endpoint. The server shares its outbound
  counter across audiences, retaining encode-once invocation ownership and one
  native FireAllClients Broadcast; exclusions have sequence gaps. Receive high-
  waters belong to actual-Player roster entries or the client session, survive
  listener replacement and commit only after complete admitted payload decoding,
  before callback start. Forward modulo 2^32 distance 1..2^31-1 is accepted after
  the first valid frame; equal/backward/half-range values drop as stale. Ordering
  across 2^31 unseen advances is unsupported. Existing call/byte/endpoint/handler
  admission order and retained-charge rules apply; malformed/denied/busy/no-
  listener traffic cannot poison high-waters. One saturating stale counter is
  added per session/event, without traffic-keyed retention.
  C2S ordered definitions initialize through reliable endpoint-zero format 2
  kinds 32/33: 38-byte GUID Hello and 42-byte echoed GUID+generation Init. Client
  Start installs its receiver before Hello and waits only for the exact active
  attempt under the original deadline; timeout/Destroy releases its wait/timer.
  Server generation increments per actual Player without reuse/wrap and clears
  only inbound ordered high-waters. Old-generation data cannot reset a recreated
  client stream. Both control transitions are nonyielding before state mutation.
  S2C generation is 0; recreated clients accept their first valid in-flight frame
  before enforcing ordering, without a stronger restart-freshness promise.
  Teardown/player removal clear owned sequence state. No retransmission or
  gameplay-authorization claim is added. Dedicated Sol design/security review
  approved this bounded scope before implementation; native proof is recorded
  separately from portable checks.
- Requests select RR5 (or RR7/RR8 above) and force Reliable codec bodies, including primitive-only
  shapes. The format-1 RPC envelope has a 44-byte identity header, at most 8148
  body bytes and 8192 complete raw bytes. Request/response shapes independently
  retain existing depth/node/container limits. Client sessions own at most eight
  pending requests and one per method, with nonreused u32 call IDs, actual-session
  GUID correlation, finite deadlines at most 60 seconds and one waiter per handle.
  Cancellation is local; late responses cannot settle a replacement request.
  Server RPC shares event buckets/leases and keeps at most 64 recent identities
  plus eight active identities per actual Player; no durable exactly-once claim.
  Replay scans cover the populated private ring, including all 64 slots after wrap.
  Event-only servers omit RPC replay state; fixed RPC codec results use scalar
  locals while protected handler results retain exact return-count checks.
  Validated request values forward directly to protected handlers; pending client
  records share the session settlement function without a per-request closure.
  Fixed failure replies carry no exception text. False and explicit optional nil
  are valid single responses. Terminal cleanup releases timers and pending closures.
  The corrected frozen RPC/audience/Once snapshot passed 21 checkpoints with two
  actual Studio clients (`.tmp/relay-proof-f18e3b170254476fa6440d3ab93179a4.json`),
  including deadlines, cancellation and late replies. This proof excludes the
  later readiness and batch runtime integration; its initial failed attempt is retained.
- Readiness/queue metadata selects RR6 (or RR7/RR8 above), with exact legacy descriptor preservation
  when disabled/absent. Queued capable events have a separate forced-codec record
  bounded to 8187 Reliable/895 Unreliable body bytes and separate inspector bounds.
  Optional readiness requires one ServerToClient event, maps those IDs in ascending
  order into a 1–8-byte mask at the current 64-entry cap, and admits reliable
  format-2 controls through player-first then aggregate charging before parsing.
  One readiness record stays on each actual roster Player; RefreshReadiness is a
  local handoff with no automatic retry, and GetReadyPlayers returns a fresh,
  bounded claim snapshot. Portable tests and Sol review pass; the integrated
  0.2.0 two-client Studio fixture passed readiness checkpoints.
  Readiness uses precomputed mask positions and a shared frozen Hello header;
  Ack validation reuses its bounded width while retaining exact length and unused-bit checks.
  Session ingress accepts controls up to 90 bytes so the full eight-byte listener
  mask reaches that parser; shorter definitions still require their exact mask width.
- Explicit FIFO `CreateBatch` is available on started sessions for their sending-
  direction queue-capable events. A sender owns one open batch and up to 32
  records across both channels, with each complete raw channel frame capped at
  8192 Reliable/900 Unreliable bytes. Server batches capture a fixed recipient
  snapshot of at most 1024 Players; client batches target their server. Accepted
  values are encoded immediately. The first submit fixes one deadline timer of
  at most 100 ms; Flush sends Reliable before Unreliable, caches its frozen
  six-number handoff report, and does not retry failures. C2S format-2 kind-1
  ingress pays one player-first/aggregate token pair per declared logical record
  before record scanning, body copying, or decode. The whole frame is scanned and
  decoded before callbacks; malformed frames produce no partial dispatch.
  Dispatch holds decoded tuples beside checked row metadata without allocating
  another wrapper table per record.
  Private queued receiver maps contain only incoming-direction events; lookup misses
  reject other directions while channel and State-kind checks stay explicit.
  Portable frame, queue, session, type checks and Sol review pass. The integrated
  0.2.0 two-client Studio fixture passed scheduler, callback-start order and
  transport checks as part of its 23 checkpoints.
- Explicit FIFO `CreateBatcher` reuses the same typed queue-capable event map,
  fixed server audience, queue slot, 32-record/8192-Reliable/900-Unreliable
  bounds, format-2 kind-1 framing, and admission. It starts Open without a timer;
  the first accepted Send starts each window's deadline, and successful Flush
  records only the latest result and reopens the handle. An outbound rate refusal
  retains the window for manual retry with its timer stopped; hard or partial
  handoff failure is terminal. Cancel is terminal and retains the shared flush
  guard's no-effect behavior until retried. No wire, descriptor, schema, or
  admission contract changes.
- Explicit CreateState uses the same private queue owner, current-player
  handoff, monotonic clock and flush guard. State-capable events also permit
  FIFO batching; kind-2 ingress admits only State-capable events under the same
  complete-frame rejection and logical charges. Four lanes share 64 active keys
  and 16384 pending body bytes. Put owns and atomically replaces one unsent
  lane/event/u32 key. Priority, first-dirty age, event ID and key determine bounded
  selection; replacements do not extend one-second expiry. Selected bodies are
  consumed before uncertain handoff, without retry; active scalar keys remain
  until Remove/Destroy. Receiving games use payload sequences for stale filtering.
  Put stores each validated priority rank once and applies expiry cleanup only
  when its admitted plan contains expired bodies. Its admission and replacement
  accounting share the live old-body size from that plan. Flush expires and partitions keys
  in one pass before independent channel selection, which stops at its 32-record cap and
  retains unselected snapshots for later flushes.
  State event handles are frozen directly in the public handle; lane records retain
  pending state and lifecycle ownership without another reference to that event map.
  Helper/session checks and Sol reviews pass. The separate two-client Studio
  fixture passed nine State checkpoints and six submission-to-ACK age gates;
  ACK age includes reverse transport, scheduling and the harness.
- Composite frames use format version 1 and a u16 endpoint matching the outer
  endpoint. Limits are 8192 raw bytes for Reliable, 900 for Unreliable, depth four,
  256 expanded nodes per event, and array/set capacities at most 64. Definition
  rejects schemas exceeding the worst-case bounds. Decoders check bounds before
  reads, allocation, and traversal, and reject the complete malformed frame
  before any handler call. Normalized/decoded tables belong to each invocation.
  Single- and two-field validation, encoding, and decoding keep values in locals
  instead of allocating temporary payload tuples.
  Composite codecs bind frozen endpoint IDs and effective byte bounds at setup;
  decode-only nodes omit encode/validation lookup maps. RPC and batch readers
  retain wire bounds while checking only the narrowed unsigned ID/kind ranges.
- Primitive validators check exact arity and return normalized tuples without
  payload arrays. Sessions compile and bind each validator while constructing its
  event handle, without an intermediate validator lookup table. Integers are exact
  and bounded; Float32 scalars/vectors check
  bounds and canonicalize negative zero. Vector validation reuses immutable values
  whose zero components are already canonical and reconstructs only to canonicalize
  negative zero. Strings retain exact bytes. CFrame validation checks finite bounded
  translation and approximately orthonormal,
  right-handed rotation without repair. Composite CFrames preserve twelve f64
  components and require exact reconstruction, including zero signs.
  Composite integer decoding selects zero-only normalization at construction for
  full native ranges after checked buffer reads; narrower ranges retain their
  scalar validators. Encoding and native tuple validation keep full checks.
  Queued receiver codecs compile only for the session's incoming direction.
  Immediate composite and unreliable events reuse their queued codec; reliable
  primitive immediate events retain their separate native tuple validators.
- `schema.Color3()` and raw `{ type = "Color3" }` add an actual Roblox Color3
  primitive with fixed finite RGB0..1, one node/depth0 and no custom bounds/keys.
  Every original component is validated before/after existing Float32 rounding;
  negative zero becomes positive zero. Unchanged normalized values are reused;
  reconstructed components must match. Reliable primitive events keep native
  tuples; composite, unreliable, RPC and queued bodies use12-byte R/G/B f32.
  Checked reads and raw bounds precede construction, with reconstructed-value
  checks before dispatch. The new c3f32 descriptor code uses existing prefixes;
  Color3 requires updated peers, while non-Color3 definitions preserve their
  descriptors/representations. Strict types carry actual Color3 through all
  capabilities and struct/array/optional children; set keys remain restricted.
  Native content admission charges12 per Color3 plus the existing tuple header;
  forced buffers retain exact whole-envelope charging. All existing byte, shape,
  queue, request, handler and admission-order limits remain unchanged.
- `schema.Color3RGB8()` and raw `{ type = "Color3RGB8" }` add a closed native
  `Color3` leaf with finite actual RGB components in `0..1`. The codec writes
  R/G/B as three u8 codes using `floor(component * 255 + 0.5)`, then reconstructs
  each selected code as `code / 255`; zero is positive and each result must be
  within `2^-24` of its selected code / 255 and re-encode stably. Maximum
  component error is `1/510 + 2^-24`. This shape adds exact token
  `N10:Color3RGB8[1]` and uses
  existing descriptor-prefix selection and whole-tuple codec routes, including
  reliable immediate sends. It retains the current frame, queue, depth, node,
  endpoint, and admission limits/charges. Existing `Color3` Float32 behavior,
  descriptors, and bytes remain unchanged.
- `schema.taggedUnion(tag, variants)` and the raw `taggedUnion` shape select one
  anonymous struct from a plain 1..32-entry literal map. Tag/labels use valid
  Relay names. The tag counts toward eight struct fields, so branches have at
  most seven authored fields and cannot redeclare the tag. Closed keys and
  metatable rejection remain authoritative at runtime; missing/unknown tags,
  branch-inappropriate fields and child validation failures reject the payload.
  Helpers own a shallow frozen variants map; define owns all compiled branches.
  Strict types form an actual discriminated table union through all public
  capabilities and supported nested shapes; existing set-key restrictions hold.
  Sorted labels define zero-based u8 ordinals, followed by the selected struct
  body. The union forces the existing buffer codec and adds one byte, depth
  level and expanded node to the respective branch bound; minimum bytes use
  the smallest branch, other maxima use the largest branch. Every alternative
  consumes the existing shared authored-node budget. Depth4, nodes256,
  authored256, arrays64, descriptor4096 and all message/queue limits remain.
  Private compiled variant structs permit exactly the checked discriminator
  key without changing standalone structs. Unknown ordinals reject before
  branch allocation; selected minimum checks precede allocation/reads and
  complete-frame validation precedes every callback. Tables remain owned by
  each invocation. New recursive U descriptor tokens use existing prefixes;
  non-union definitions keep their descriptors/bytes and mismatches fail startup.
  Existing single-buffer byte admission includes the tag once with all call,
  endpoint, logical-record and handler order/limits unchanged. This pure
  table/buffer slice introduces no engine API, scheduler or transport behavior;
  its focused portable/type proof is separate from recorded native snapshots.
- The server owns `ReplicatedStorage.RelayRemotes`, with `Definition` and
  `Reliable` leaves, plus `Unreliable` when selected by any event. The Reliable
  leaf is present even for unreliable-only schemas. Active mutations
  are terminal, including same-count leaf replacements or mutations restored
  before deferred observers run. Cleanup preserves foreign descendants.
  Sibling name observers detect persistent root-name conflicts without scanning
  storage on packet paths.
- Eligible ingress requires a current rostered player and charges one per-player
  token, then one aggregate token, before endpoint/channel/payload validation.
  Both channels share buckets and handler caps. Per-player exhaustion leaves
  aggregate tokens untouched; aggregate or validation rejection gives no refund.
  Each eligible attempt samples the server clock once for both buckets. Each bucket
  refills only when that sample advances its independent clock high-water mark.
- Optional server-local `inboundRate.endpoints` maps known client-to-server event
  and request IDs to per-player `{ capacity, refillPerSecond }` buckets. Maps/rows
  must be plain, IDs known and inbound, capacity integer 1..4096 and refill finite
  >0..2048; invalid configuration returns InvalidOptions at create. Missing/empty
  maps preserve existing admission. Policy is copied/frozen, leaves all descriptors
  and payloads unchanged, and owns at most 64 existing TokenBuckets per rostered
  player. Buckets are constructed at roster setup and cleared on removal/teardown,
  including entries retained by suspended handlers; listener replacement does not
  reset them. All takes reuse the incoming packet's existing timestamp.
  Immediate events debit after endpoint/channel checks and before listener/busy/
  payload checks. RPC debits after bounded envelope peek and method resolution,
  before replay/listener/busy/body copy/decode; rate drops keep normal client
  deadlines and send no refusal response. FIFO/State preserve existing coarse
  prefix charges up to N, then fully scan framing/IDs/channels, then debit endpoints
  in row order before body copies/decode. First endpoint exhaustion drops the whole
  frame, retaining all N shared charges and earlier endpoint charges. Malformed
  bodies retain all applicable endpoint charges; malformed framing debits none.
  Immediate/FIFO/State share buckets. Readiness controls have no endpoint-token charge.
  Saturating endpointRate counts session/event refusals (RPC session-only), and
  diagnostics expose frozen configured policies. These are ceilings, not fairness
  or byte/work accounting; all earlier shape, byte, queue and handler caps remain.
- Optional server-local `inboundRate.bytes` adds plain, closed `perPlayer` and
  `aggregate` `{ capacity, refillPerSecond }` rows, copied/frozen once and reused
  by runtime. Capacity is integer >=1 and refill finite >0; per-player maxima
  are 33554432/16777216, aggregate 268435456/134217728, with each aggregate value
  at least its per-player counterpart. Missing policy preserves existing behavior.
  The shared receive boundary first takes the existing player/aggregate call pair,
  then the player/aggregate byte pair with the same clock sample, before header
  parsing, body copies or decode. Player byte exhaustion leaves aggregate bytes
  untouched; aggregate byte exhaustion retains player bytes. No earlier charge is
  refunded. A single buffer costs its whole raw length once (minimum1), including
  malformed/oversized frames. Native tuples cost3 plus boolean1, number8, Vector2/3
  8/12, Color3 12, CFrame96, string2+length and mixed-buffer length per actual argument.
  Invalid outer selectors, >8 arguments or unsupported value types are byte-
  refused without table traversal/tuple allocation. These are Relay content units,
  not Roblox wire/engine ingress measurements. Byte refusal precedes queued N-1
  logical charges and endpoint charges; once admitted, all prior charge/guard
  ordering remains. Budgets span events/RPC/FIFO/State/readiness and both channels;
  whole-frame rejection has no partial callbacks and RPC keeps normal deadlines.
  One aggregate bucket and one per rostered Player exist only when configured;
  removal/teardown clears even retained entries and listener replacement cannot
  reset them. Existing TokenBucket weighted takes validate finite positive integer
  costs before mutation and retain independent monotonic high-water/refill rules.
  Session-only `perPlayerBytes`/`aggregateBytes` saturate; snapshots expose policy
  without clocks or balances. Protocols, payload/shape/queue/replay/handler caps,
  and client APIs are unchanged; content bytes do not provide work accounting or fairness.
- Yielding handlers retain their leases: one per player/endpoint, eight per
  player, and 64 server-wide; clients allow one handler per endpoint. Listener
  replacement cannot reset occupied slots. Removal/destruction invalidates leases
  without allowing late callbacks to recreate state. Inbound drops do not retain
  payload diagnostics or enqueue per-drop work. Client terminal cleanup and server
  listener cleanup release decoder references held by connection handles.
- Client discovery and activation share one startup deadline. Each pending child
  wait owns one listener and timeout, released on arrival, timeout, or Destroy.
  Destroy cancels startup with `Destroyed`; attempt identity prevents stale
  continuations from activating a destroyed or replacement session.
- Session option checks reject unknown keys and missing required values without
  temporary key tables. Protected connection cleanup reuses module-local helpers.
- Send success means local Roblox transport handoff. Game code owns authorization,
  semantic validation, sequencing, persistence, and handler work.
  Unreliable delivery may drop or reorder messages. Relay has no automatic retry
  or reconnect. Admission bounds Relay-owned
  work, not engine ingress allocation, network availability, or fairness.

Networking, decoder, serializer, transport, batching, RPC, and middleware changes
require a dedicated design and security review under [AGENTS.md](AGENTS.md).
Before extending unreliable delivery or composite shapes, that review must
specify version compatibility, maximum total encoded size, array length, nesting
depth, and admission charges. Keep the contract in docs/reference.md current and prove
malformed-input rejection and applicable charging with focused checks.

## Benchmark ownership

Benchmark code stays outside the Wally package.
[benchmarks/README.md](benchmarks/README.md) owns execution, timing, lifecycle,
reporting, and trust-boundary rules; [the adapter guide](benchmarks/adapters/README.md)
owns external binding details.

| Area | Responsibility |
| --- | --- |
| `benchmarks/contracts/` | Event V1 workloads, Result/HostManifest profiles, shared private schemas, repetition fragments, and bounded terminations. |
| `benchmarks/fixtures/`, `benchmarks/correctness/` | Deterministic inputs, payload comparison, order/cardinality checks, and delivery ledgers. |
| `benchmarks/adapters/` | Closed adapter contract, native/Relay bindings, and pinned external bindings. |
| `benchmarks/runner/` | Clock/timing boundaries, bounded phases, readiness, distributed execution, persistent transport observation, evidence assembly, and cleanup. |
| `benchmarks/host/` | Source/artifact verification, canonical study prelaunch input manifests and between-attempt rechecks, interrupted-study recovery audits and fresh whole-study restart collection, selected-only builds, authenticated bounded collection, confirmed Studio exit, shared fail-closed Studio launch ownership, and no-overwrite publication. |
| `benchmarks/reporting/` | Bounded reads, strict V1/V2 validation, compatible comparison groups, median-sorted ranks and inverse-median FPS/Native scales, and separation of non-valid evidence. |
| `benchmarks/pilot/` | Opt-in QuickNet/Zap lifecycle checks outside measured Result evidence. |
| `benchmarks/quick/` | One-client Studio Play diagnostics, persistent adapter instances, bounded capture, FPS-sorted Output tables with Native scales and engine-wide KB/s, and in-session reruns. |
| `benchmarks/profiling/html/` | Pinned saved-HTML extraction, viewer-compatible normalization, isolated decoder worker, Windows process bounds and focused offline checks. |

The library lock is `benchmarks/libraries.lock.json`. Acquisition and deterministic
generation use `scripts/acquire-benchmark-libraries.luau` and
`scripts/generate-benchmark-adapters.luau`. Downloaded/generated code is not
edited or committed. Suphi-Packet has an author grant but remains timing-ineligible
because its sender-frame bound cannot be proven.
QuickNet's lock separates its `v0.3.5-beta` tag target from the runtime-source
commit because the tag is docs-only; the pinned source matches the published
RBXM scripts used for the benchmark. The focused benchmark-library test covers
that source/tag split and Blink's current release asset size. QuickNet's newer
`Config` ModuleScript is mapped in both the runtime project and catalog.

Canonical `PersistentBenchmark` uses Result V2's `event-session-v1` profile:
one fresh Studio session per adapter/case/topology, 30 logical windows, a passed
session proof, and confirmed process exit before publication. Physical receivers
observe across windows; late, stale, malformed, or between-window deliveries
latch failures. Setup, readiness, warmup, correctness, and quiet windows stay
outside timing. Result V1 is a separate lifecycle/profile and cannot be pooled
with V2. Readers recompute summaries and reject dirty provenance, duplicate run
IDs, and incompatible comparison groups. A warm process is not 30 independent
process samples; shared-clock durations are diagnostics, not ranking inputs.

The canonical host, external repetition runner, session-reuse pilot and native
proof runner acquire the same Windows host lease under the OS-resolved
CommonApplicationData folder (normally ProgramData), independent of the caller's
environment, before Studio preflight. Its file is created with Windows CreateNew
rather than Lune 0.10.5 `fs.writeFile`, whose overwrite option does not make creation
exclusive. A launch marks ownership uncertain until child exit, Studio-idle
census and owned-file cleanup succeed. Crash, kill acknowledgement, cleanup
failure, missing owner content or an existing lease retain/fail closed; there
is no time- or PID-based automatic reclamation. Manual recovery requires
confirming the old host and Studio descendants are gone. This coordination
covers Relay CLI launches across Windows accounts and checkout directories;
unrelated Studio tools do not participate, and macOS fails closed.
The pilot latches forced-kill requests and unconfirmed outcome exit across
cleanup; the multi-scenario proof clears each confirmed prior child before
the next prelaunch check.

The timing recorder retains completed private sample arrays and makes one final
defensive copy when producing deeply frozen evidence.
Runner operation callbacks and fixed delivery/control key allowlists are selected
before execution; per-message validation and timing boundaries remain unchanged.
Submission arity uses scalar counts; protected delivery results use scalar locals.
Authenticated preflight tokens and generations retain immutable payload bounds.
Control comparisons borrow validated plain headers; replay storage keeps owned copies.
Coroutine guards avoid nested result packing while retaining protected error text
where failure classification needs it. Receipt completion follows the unique
seen-count edge; finalization omits arrays used only for canonical input ordering.
Single-result protected setup, cleanup and duration calls use scalar results;
coroutine/adapter guards keep packs wherever exact return counts matter.
Role key maps are built once with their original membership and construction order.
Fixed evidence ordering maps and counter lists are reused across comparisons;
single-sender workload checks share the frozen contract's expected delivery count.
Canonical fixture arrays reserve their exact counts from frozen contract definitions.
CaseRunner aggregates phase flags while polling immutable kernel statuses. Result
validation flattens samples once after checking and ordering their owned groups.

`MeasurementFingerprint.luau` covers measured runner/contract/fixture/correctness
inputs, composition and adapter contracts, canonical host dependencies, and the
library lock. Documentation/reporting edits do not change the fingerprint.
Changed measured inputs require a compatible new cohort.

[Quick benchmark guidance](benchmarks/quick/README.md) owns workload selection,
balanced adapter rotations, timing units, and receive profiling. Quick runs
accept dirty local source and do not emit Result V1/V2 or ranking evidence.
Their summary tables sort local observations by sender FPS, or by RTT for the
sequential probe, without changing returned adapter order or ranking eligibility.
Sender FPS uses per-round mean frame intervals; engine send KB/s remains an
engine-wide diagnostic. Canonical FPS is separately derived from median frame
intervals, and RTT is never converted to FPS.
The Relay-only `schema-composite-c2s` diagnostic exercises RR3 with 16 bounded
records and independent nested fixture/capture copies. It supports the isolated
Relay receive profile; the other schema cases remain unprofiled. The profile
includes admission, RR3 decode, dispatch, and nested capture, excluding engine
decode, scheduling, and transit.
`CoreAdapters.luau` owns quick-only matched reliable C2S channels for Booleans,
Strings, Numbers, Vector3, and Mixed state across all nine timing-eligible
libraries. `--category` selects one category or the fixed five-case suite;
`--adapters`/`--all` independently select libraries. Each physical library loads
once and declares all five channels before timing, including Warp's cached
endpoints. Category-tagged callbacks and bounded `NextCase` transitions preserve
the suite-wide failure latch. The dedicated Relay definition uses existing
pre-handler validation and admission; third-party codec checks prove fixture
delivery, not hostile-byte security. Suphi-Packet remains timing-ineligible.
Core runs and receive profiling are separate. Generated schema extensions
require pinned regeneration and a separate measurement cohort.
Fixed quick payloads forward exact scalar tuples directly to native, Relay, Warp,
and generated send calls without an intermediate packed table.
Relay quick senders bind their fixed event handle at setup.
Sender closures and native replication discovery belong to clients; admission
options belong to servers. Probe and workload phases reserve only arrays they fill.
Schema captures bind frozen field metadata and release cached event handles at teardown.
`benchmarks/tests/quick-core-adapters.luau` checks all five fixture payloads
through the nine adapters, including the real pinned vendor codecs, sender and
channel identity, input preservation, and legacy generated event IDs. The
owned five-event Relay specification has focused pre-handler string-boundary
rejection and per-player/aggregate admission checks. Suite tests cover category
transitions, cached reruns, late deliveries, and delayed replication metadata.
Each adapter initializes once per Play session; the selected core cases run
sequentially without reopening Studio. Changing source or the built selection
requires Stop/Play. Observed terminal faults invalidate prior reruns, while
acknowledged normal closure tears down adapters and preserves completed results.
Receive profiles use isolated source snapshots and include capture/instrumentation
overhead; they are callback elapsed diagnostics, not isolated CPU time or
end-to-end latency.
Snapshot manifests reuse the source hash for identical generated bytes. CPU stage
names are expanded when the phase marker is set, before profiled callbacks.

[Saved MicroProfiler HTML analysis](benchmarks/profiling/html/README.md) uses a
pinned external decoder anchor and runtime. Input HTML remains inert; an
isolated worker and Windows Job bound execution and verify cleanup. Supported
saved dumps use this CLI for structured extraction; Studio capture/export
controls may still require computer use. Reports retain provenance and explicit
qualification flags, with absent network records, workload attribution and
physical wire bytes kept distinct. This path does not load LibMP or qualify a
native capture, and its output is separate from Result V1/V2 rankings.
The zero-record hold parity exception requires zero viewer totals and category
counters; nonzero category data cannot pass as an explicit-zero addition.
The normalizer collects included record IDs and network-detail presence in one
ordered walk without an intermediate filtered array.
Marker prefixes and packet-bucket string identities are reused within normalization.
Host and reporter JSON scans share private escape lookups within each module and
construct decoded characters only for retained object keys; all rejection checks remain.
Native manifest fallback identities are built only when no adapter is supplied.
Bounded offline reads use initialized private buffers and return only the written prefix.
Reporter evidence rows stream in their existing sorted order.
Receiver cost and network evidence checks share one private correct-sample vector
from the owned validated result, retaining independent receipt and artifact checks.

Canonical LibMP benchmark collection remains disabled pending qualification.
The quick runner now supports opt-in `--profile-receive --libmp <SDK>` for the
existing client-to-server workloads. `CpuProfile.luau` owns pinned-SDK/backend
checks, capture control, bounded exact CPU scope-pair analysis, and cleanup.
Completed server departure closes the profiler before publishing Closed; cleanup
failure latches Failed. Complete stays open for in-session reruns.
The isolated builder verifies SDK revision/hash and records it in the manifest;
ordinary builds exclude the SDK. The measured client send loop runs directly
inside PreSimulation, closes its scope before yielding, and copies the live data
to a private buffer after a diagnostic delay without pausing the shared capture.
Snapshots use the SDK's compressed container, keeping the 4 MiB retained-buffer
bound without imposing that bound on native allocation or decoding.
The server owns the final pause and also captures each measured receive
phase, snapshotting after the final expected delivery and four Heartbeats so
sender analysis cannot evict the receive window. SDK-only isolated copies add
send validation/encoding and handoff markers, plus receive validation/decoding
and dispatch markers; `CallbackTiming` adds the receive-total marker. Scopes
preserve tuple/error behavior and require synchronous benchmark handlers.
Per-round `cpuCapture`/`receiverCpuCapture` reports and each side's latest
buffer/report are available to code sharing the running Session module. MCP
command contexts returned nil from those module-local getters in the native
smoke; the printed reports remain available there. Capture retains 16 frames,
the reader accepts up to 32, and only the latest eight are scanned. Compact
Output reports show inclusive stage observations, partial-scan status, and the
three slowest frame intervals in the scanned window without adding parent and
child durations. They retain scan limits and explicit false timing/ranking
qualification. Iterator and state
read errors retain partial pair diagnostics and report failure rather than an
observed result. A native State-burst C2S smoke on Studio 0.742.0.7421053
verified 1440/1440 measured deliveries over three rounds; all six sender/receiver
captures and all five stages per round had exact CPU pairs. Scans stopped at
Step=false and remain partial, with timing/ranking qualification disabled.
Native validation exposed 63-byte timer-name truncation, zero-timestamp
labels/events, and a terminal boundary retaining the final absolute frame ID.
Compact stage suffixes and scope-only timestamp checks handle those records;
scope pairing still requires exact timer/thread/frame identities. Ordinary Play
uses a process-wide profiler source, so side markers distinguish work while
the sender and receiver buffers can cover different frame windows. A shared-Control
regression covers sender snapshot before delayed receive scopes and final receiver
pause while preserving the sender buffer. A follow-up native smoke with 1000 ms
outbound delay verified 1440/1440 deliveries and all six sender/receiver captures;
all stages were observed, with receive windows over 200 frames after send windows.
Raw 16-frame buffers exceeded 4 MiB in that run; the existing reader decoded
the SDK's compressed buffers within the retained-byte bound. The focused reader, session, and snapshot/build
checks cover this tooling without changing Relay production source or remotes.
The quick guide applies the earlier investigation lesson to real-workload
probes, retained-data analysis before recapture/GUI, and focused verification.

Pinned Studio 0.742.0.7421053 and matching SDK 1.1
(65537:65537) expose ordinary CPU enter/exit records and counters. Before-work
active ranges precede paused ranges by four absolute frames; buffered and
paused-live scalar views agree. Those command-driven probes found work timer
descriptors, but their exact enter/exit pair remains unqualified. The typed
recent-frame census separates boundaries, scopes, labels and events and retains
only its committed prefix. Failed and capped scans prove no full-window absence;
Step=false can
mean exhaustion or reader error. Heartbeats establish neither the work's
Profiler frame placement nor a capture-drain fence. Heap samples are process-
wide; scope timing and benchmark attribution remain unqualified.

LibMP name masks match whole descriptor names. Related-name inventory is
diagnostic-only and does not expand the exact-base qualifier's accepted IDs.
Timer filters do not exclude labels, so diagnostics retain record-class counts,
step caps and stopping state. The private diagnostic reader now accepts the
documented terminal frame boundary at end+1 while keeping work matches inside
the selected frames. Both prior corrected recent-eight-frame scans reported complete
with zero work matches; that stopping state still does not establish clean EOF.

A separate ordinary client Play probe now reads an exact custom CPU work
enter/exit pair from a paused LibMP slot. It wraps non-yielding work directly in
a PreSimulation callback, repeats eight times, and retains 32 frames. The
bounded latest-eight-frame scan found a pair in its committed prefix before
reaching its step limit. This establishes marker presence in that context;
the earlier missing marker's cause remains unexplained. Native UI work-bar and
exact-frame corroboration remain incomplete. A native binary dump is retained
but has not been decoded or verified against the slot bytes. Scope timing,
benchmark-workload attribution and collector promotion remain unqualified.

`BroadcastStudy.luau` and `run-broadcast-study.luau` schedule forward/reverse
canonical State-broadcast sessions with pinned source and Studio identities.
Verified result bytes, logs, hashes, and failed attempts stay in ignored local
ledgers. Initial ledgers, logs and raw archives use a Windows CreateNew write
because pinned Lune's `writeFile(overwrite=false)` is not exclusive.
`BroadcastRecoveryAudit.luau` checks interrupted v2/v3 ledgers and current inputs
without launching Studio or selecting old slots. Restart history is bounded to
eight ledgers including the original v2 and newest v3 collection. Each parent
hash, manifest and source identity is revalidated; canonical repeated paths and
run IDs across generations are rejected. Historical reporting validates archived
inputs; a new restart also requires current checkout inputs to match. A terminal
failed attempt may start a linked v3 collection with a fresh full schedule.
An in-flight attempt in any ancestor remains blocked on uncertain ownership.
Full histories fail before a new
collection or launch. The v3 reporter revalidates all ancestors and archived
evidence before using only the newest collection's attempts.
D05 owns actual Studio launch exclusion and uncertain child teardown.
`StudyInputManifest.sourceInventory` exposes the same source closure as sorted
relative paths, byte counts and domain-separated file hashes for verified copies.
Ledger manifest v1 summaries and identities stay unchanged. Inventory still
reads live files; immutable execution remains a separate gate.
`StudySourceCopy.copy` creates an offline copy in a fresh Windows directory,
checks each source read and destination readback against the frozen inventory,
and rejects missing or extra files/directories before returning its identity.
Ordinary ASCII paths on the same drive, case/prefix and reparse-point checks
and exclusive directory/file creation constrain writes; failed output is retained.
Checks assume stable local filesystem ancestors and cannot prevent a hostile
reparse-point swap after inspection. The copy contains no Git metadata and is
not wired to benchmark execution; tool closure and immutable execution stay open.
[The serializer gate](benchmarks/serializer-gate.md) owns predeclared
units, attribution limits, and evidence collection. `SerializerGate.luau`,
`SerializerEvidence.luau`, and `run-serializer-gate.luau` evaluate pinned source,
exact planned base-place identities, Result V2, profiler, and packet-capture
artifacts. They do not collect those traces or certify human reviews; missing
evidence is inconclusive, and passing evidence is eligible for design/security
review.
Packet evidence matches ordered packets to validated nonoverlapping windows with
one advancing cursor, preserving half-open boundaries and packets in gaps.

The local OS account and selected Studio executable are trusted. Harness
framing, source checks, and correctness qualification do not certify third-party
decoders against malicious bytes or establish production security.

## Broadcast study diagnostics

Offline `BroadcastStudyReport.luau` and its CLI reuse canonical Result V2
validation and exact archived bytes. Metric scopes,
sample/launch units, median/p95 drift, source/engine pins and unknown coverage
remain explicit; two ordered passes cannot select a winner or establish an
independent uncertainty interval. Report thresholds do not prove historical
predeclaration. `benchmarks/tests/broadcast-study-report.luau` verifies evidence
tampering, incompatibility and drift arithmetic.
Old duplicated ledger summaries may differ by one binary64 step; these differences
are recorded while canonical raw-sample summaries remain authoritative. CLI output
creation rejects collisions without replacing prior evidence.
Reporter paths preserve Windows UNC roots accepted by the collector.
Each archived result's checked digest is reused in its report row.

`BroadcastStudy` additionally records coarse monotonic preflight, whole child
host command, and archive/validation intervals, including failures. These are
campaign turnaround timings, not measured runtime phases.
`HostRuntime` now emits optional monotonic host-side build-helper, Studio launch-call,
child-process, teardown and overlapping total intervals outside workload loops.
`BroadcastStudy` retains the bounded line on failed attempts; the offline
report re-reads successful raw stdout before exposing it. Readiness, warmup,
workload collection and engine drain remain unavailable within the child
process. Clock faults mark timing unavailable without obstructing raw evidence
or the primary failure. Legacy reports keep Unknown coverage. The canonical
host remains `HostRuntime`; its changed source changes the measurement
fingerprint value, while the fingerprint algorithm is unchanged.
These intervals do not isolate child lifecycle phases or establish performance.
The current API reference distinguishes historical native proof from a
fresh current-checkout run and explains State residence/late join, uncertain RPC
outcomes and engine-ingress security boundaries.

## Verification and repository hygiene

Code reviews use a Sol (`gpt-6-sol`) subagent. Use the nearest focused test during
development. After foundation changes, run:

```sh
lune run scripts/verify-foundation.luau
```

The gate runs registered runtime/type/benchmark checks and verifies the Git-index
file allowlist, LF/trailing-whitespace policy, ignore boundaries, Wally package
contents, Rojo builds, and CI pins. Stage intended file additions/deletions before
running it because the inventory reads the index. The gate does not launch Studio.

The RPC retention witness ends its creator frame before collection to exclude
dead VM stack slots. Adapter checksum fixtures preserve binary source bytes and
compare XML hashes with the parsed artifact's source.

`scripts/Verification.luau` owns the private advisory first-check mappings, Git
NUL-path parsing, source identity and atomically reserved per-run output roots.
`verify-foundation.luau --first --dry-run` explains the staged/unstaged/untracked
selection against HEAD without executing checks or creating artifacts; omit
`--dry-run` to execute it. Registered tests select themselves; type fixtures select
the pinned public-type check. A small exact source mapping selects nearby checks.
Unknown paths, deletions/renames, unsupported statuses, missing mapped checks and
empty changes conservatively run the full gate. This is no dependency graph;
the default full command and independent Sol review remain required.

The verifier reuses `MeasurementFingerprint.digest` with a separate verification
domain over tracked/untracked non-ignored file bytes, revision and dirty status.
It rejects source drift between entry and exit. This identity is separate from
benchmark measurement eligibility; `HostRuntime` and `BroadcastStudy` still own
their source/artifact pins, raw bytes, failed attempts and native coordination.
Ignored `.tmp/verification/<owner>-<run>/report.json` handoffs identify the source,
actual commands by registered test path, stage outcomes and bounded failure text.
Full runs retain every package/build/CI check. Advisory reports explicitly mark
unselected checks and final gates skipped. Success removes only that invocation's
artifacts; failures or interruptions retain them. Public-type runs isolate every
generated input and pin hash-verified Roblox definitions from the analyzer's tag.
The legacy definitions cache stays read-only: matching current bytes are reused,
the known prior snapshot triggers a fresh download, and unknown bytes reject.
All analyzer paths keep Solver V2 enabled and explicitly disable
`LuauDontBlockRefinementUnconditionally`: luau-lsp `1.70.1` otherwise loses schema
inference after `assert` narrows an optional composed definition. Consumer fixtures
and exact negative diagnostics stay unchanged. Remove the override only after the
same checks pass without it; the API reference records the CLI/editor setting.
Never delete another invocation's output; inspect only completed run roots.
`tests/verification-workflow.luau` uses literal expected commands and controlled
runner failures to check selection/fallback, dry runs, source drift, reports and
cleanup ownership.

`.agents/skills/relay-benchmark-review/` owns repository-scoped offline benchmark
claim review. Its concise entrypoint routes to study and capture/attribution
references, with normal automatic discovery. `benchmarks/reporting/BenchmarkReview.luau`
reuses `BroadcastStudyReport` and `BroadcastStudy.sourceIdentity`; the skill's
`scripts/assess-study.luau` emits a diagnostic assessment and bounded failure
codes. Optional before/after clean Git checks establish only a revision match,
not ignored-artifact/build/engine qualification or current performance. The
assessor never grants a winner, CPU attribution or packet attribution, and an
explicit caller-selected drift tolerance proves neither predeclaration nor
significance. `benchmarks/tests/benchmark-review.luau` exercises raw failures,
clean/dirty/changed source, tolerance choice and unqualified LibMP claims with
synthetic fixtures and real offline CLI calls. Skills remain outside Wally via
the `.agents` exclusions. No benchmark collection or runtime change is added.

| Check | Coverage |
| --- | --- |
| `tests/runner.luau` | Frozen public module contract, supported schema helpers, and legacy ordered-helper compatibility. |
| `tests/public-types.luau` | Actual API and mapped example consumers under the new solver, including RGB8 Color3 helper/raw payload inference across nested and routed shapes, plus invalid RGB8 payload/direction/keys. Uses hash-verified Roblox definitions in ignored `.tmp/`. Also checks that the site's quick-start code is exactly the escaped, typed reliable-events example and that its local/reference anchors resolve. |
| `examples/reliable-events/` | Shared v1 definition, typed server/client consumer and cleanup; the client stops on descriptor mismatch. The example guide owns a separate proposed v2 field-addition and coordinated upgrade/rollback recipe; portable client-session coverage checks mismatched and fresh matching startup. |
| `examples/combat-inventory/` | Two composed event modules, authoritative Player-based inventory inspection, typed request results and explicit lifecycle cleanup; all mapped scripts pass the pinned solver and Rojo build. |
| `examples/state-snapshots/` | One absolute replaceable pose/key, listener-ready intersection with a game-authorized fixed audience, one-shot readiness refresh, queue-pressure/Put/status/Flush/Remove hooks and scalar stale-tick filtering; mapped scripts are covered by the pinned solver and Rojo build. |
| `tests/definition.luau`, `tests/frame.luau`, `tests/composable-codec.luau` | Schema/descriptor rejection, primitive normalization, bounded encoding/decoding, malformed buffers, exact tuples, per-invocation ownership, single-/two-field tuple-allocation checks, canonical vector reuse, all six composite integer widths, decoder/input-validation separation, guarded composite table iteration, and a legal 256-node/11-byte queued body with 32-record ownership and malformed-count checks. |
| `tests/unreliable-size.luau` | Primitive unreliable 900-byte schema/runtime bounds, pre-handoff rejection across public send/audience methods, charged rejection of legacy native tuples, and legacy descriptor mismatch before sends. |
| `tests/ordered-unreliable.luau`, `tests/types/ordered-unreliable-*.luau` | Opt-in ordered schema/types, bounded envelope/control parsing, 900/901-byte send limits, serial window/wrap, duplicate/stale/old-generation rejection, retained admission charges, nonpoisoning decode, audience/Broadcast preservation, initialization/restart/timeout/teardown and unchanged legacy compatibility. Native proof is separate and does not require observing natural network reordering. |
| `tests/compatibility.luau` | Literal legacy and current descriptor/frame compatibility fixtures, unchanged reliable/composite/RPC/queued representations, RR7 primitive-unreliable and zero-field buffers, legacy descriptor rejection before handoff, 64-endpoint descriptor limits, and full-width 90-byte readiness controls. Portable regression proof only; native mixed-package and release qualification remain source-specific. |
| `tests/endpoint-rate.luau`, `tests/types/endpoint-rate-*.luau` | Optional endpoint policy validation/copying, per-player rate/burst/refill, shared immediate/RPC/FIFO/State admission and retained charges, no partial callbacks, cleanup, diagnostics and strict options consumers. |
| `tests/inbound-bytes.luau`, `tests/types/inbound-bytes-*.luau`, `tests/token-bucket.luau` | Optional byte policy validation/copying, bounded native-tuple/raw-buffer accounting, shared event/RPC/FIFO/State/control admission, weighted refill/debits, retained charges, no payload copies or partial callbacks on byte rejection, cleanup, diagnostics and strict options consumers. |
| `tests/color3.luau`, `tests/types/color3-*.luau` | Fixed-domain Color3 schema/typing, checked Float32 codec/normalization, nested payloads, 900/901-byte boundaries, malformed rejection/retained admission, event/RPC/queued routing and native content charging. Native proof is recorded separately below. |
| `tests/rgb8-color3.luau` | Portable RGB8 Color3 schema, codec, rounding, admission, and compatibility proof. |
| `tests/types/rgb8-*.luau` | RGB8 Color3 helper/raw parity, nested and optional shapes, actual `Color3` types across reliable, unreliable, ordered, RPC, FIFO, State, and bit-packed routes, with wrong-payload, wrong-direction, and closed-key diagnostics. |
| `tests/tagged-union.luau`, `tests/types/tagged-union-*.luau` | Bounded literal variants, exact branch fields and type narrowing, deterministic ordinals/descriptors, schema byte/depth/node limits, malformed and metatable rejection, fresh ownership, nested/RPC/queued payloads, charged whole-frame rejection and compatibility before handoff. Portable correctness/type proof; source-specific Studio proof is recorded separately. |
| `tests/maps.luau`, `tests/types/map-*.luau` | Bounded string/integer/native-enum dictionaries, precise value types, schema byte/depth/node bounds, malformed/duplicate-key rejection, fresh ownership, RPC/queued/ordered payloads, retained admission charges and descriptor mismatch. |
| `tests/instance-codec.luau`, `tests/instance-runtime.luau`, `tests/types/instance-values-*.luau` | Format-4 slot bounds and ownership, class/liveness/root checks, admission and whole-event rejection, reliable-immediate route restrictions, descriptor compatibility, and precise class payload types. |
| `tests/quantized-schema.luau`, `tests/quantized-codec.luau`, `tests/quantized-runtime.luau`, `tests/types/quantized-*.luau` | Finite grid/configuration bounds, binary64 alignment and error guarantees, stable nearest-index rounding, exact one/two-byte codes, malformed/unused-code rejection, route and zero-capacity restrictions, descriptor compatibility, retained admission, and strict number payload types. |
| `tests/compact-values.luau`, `tests/compact-definition.luau`, `tests/compact-runtime.luau`, `tests/types/compact-values-*.luau` | Float32-exact vector/CFrame bounds, native precision allowance, scalar-code stability after construction, per-component and angular error checks, exact 2/4/3/6/9/12-byte bodies, malformed codes, routes, compatibility, and strict native payload types. Native reliable immediate-event qualification is recorded below; portable checks cover the other routes. |
| `tests/bit-packing.luau`, `tests/outbound-bytes.luau`, `tests/types/outbound-packing-*.luau` | Canonical low-bit-first tuple/struct/collection masks and malformed padding/unused values; definition-level descriptor and strict typing; outbound per-player preflight, no-debit refusal, exact content charging, RPC control refusal, queue retention/retry, refill, and cleanup. Native packed immediate-event and outbound fanout/RPC/queue refusal qualification is recorded below. The State regression also checks that one lane's expiry cannot advance another lane's flush deadline. |
| `tests/native-schema.luau`, `tests/native-codec.luau`, `tests/native-runtime.luau`, `tests/types/native-values-*.luau` | Native schema closure and limits, exact body sizing and descriptor bounds, checked constructor/decoder behavior, malformed-input admission, value ownership, and precise payload types for all new native shapes. |
| `tests/studio/NativeValues.luau` | Shared native Studio fixture for two-direction value, enum-policy, Font ownership, sequence, range, and size checks; run in bounded sequential definition groups through the existing two-client harness. Source-specific two-client Studio qualification is recorded below. |
| `tests/studio/InstanceValues.luau` | Qualified two-client Instance-reference fixture for both directions, scope and liveness rejection, optional absence, streaming/missing references, retained admission, and recovery on later valid events. Native evidence is recorded below. |
| `tests/studio/QuantizedValues.luau` | Qualified two-client scalar quantization fixture for exact grid codes, rounded values, rejection/recovery and byte charging on reliable immediate events, RPC and FIFO routes; native minimum-step and large-offset error/stability probes run on the server and both clients. Native evidence is recorded below; portable tests separately cover unreliable, ordered and State routes. |
| `tests/studio/CompactTransport.luau` | Two-client native fixture for quantized Vector2/Vector3 and compact CFrame values and raw codes, separate position/angular error checks, outbound fanout/RPC/queue backpressure, packed tuple/array/struct masks, and charged malformed-frame rejection with recovery. Source-specific qualification is recorded separately below. |
| `tests/schema-compose.luau`, `tests/types/schema-compose-*.luau` | Bounded modular event merging, duplicate rejection, descriptor parity, ownership, 64-event definition composition, and exact positive/negative solver consumers at 64 events or mixed event/request endpoints. |
| `tests/schema-authoring.luau`, `tests/types/schema-authoring-*.luau` | Cast-free keyed fields/structs, explicit enum ordinals, union discriminator wrappers and typed delivery/queue options; legacy descriptor/byte parity, bounded wrapper rejection, ownership and exact payload/capability typing. |
| `tests/diagnostics.luau`, `tests/rpc-frame.luau`, `tests/rpc-definition.luau`, `tests/rpc-session.luau` | Fixed snapshots, inspection bounds, checked RPC envelope/schema, request lifecycle, correlation, replay admission and shared leases. Definition checks accept 17/64 event-only, request-only and mixed endpoints and reject 65; mixed session routing covers the highest request ID, malformed payloads, and retained player/aggregate charges. |
| `tests/queued-definition.luau`, `tests/readiness-frame.luau`, `tests/readiness-session.luau`, `tests/batch-frame.luau`, `tests/batch-session.luau` | RR6 metadata, readiness lifecycle, FIFO framing, logical admission, complete decode, handler leases, diagnostics, and audiences pass portable checks and Sol review. The batch-frame fixture counts copied queued-body bytes at 1/2/8/32 records and checks adjacent malformed strings plus zero-byte struct arrays. Batch-session also checks a legal 32-record, 256-node-per-record ingress, full admission charging, and no dispatch when the final record's count is malformed. These untimed checks do not qualify native CPU or allocation. An earlier source snapshot's two-client Studio fixture passed 24 checkpoints, including readiness, FIFO callback-start order and the native affected State Put cases; separate historical State producer/timer evidence is described below. |
| `tests/batch-queue.luau`, `tests/types/queued-*.luau`, `tests/types/readiness-*.luau` | FIFO helper ownership/timer/partial-failure checks, reusable batcher lifecycle checks, and strict directional capability/report/inspection types. The queued type fixtures cover positive and negative CreateBatcher constructor and handle use. Public typing, helper and session portable review is complete; actual Studio proof is separate. |
| `tests/state-queue.luau`, `tests/state-session.luau` | Latest-unsent ownership, deterministic selection/expiry, shared key/byte/flush limits, audience pruning, partial handoffs and terminal timer cleanup pass focused tests and Sol reviews. Reference Put replays compare accounting, owned buffers, first-dirty expiry, rejection behavior, timers and exact handoff bytes; key-read probes measure work separately from timing. Separate two-client Studio launch `78f12ce7e1724b8f9e7324da292edd73` passed nine State checkpoints and six paired submission-to-ACK age gates. Its collector failed on an echoed marker; exact saved-log recovery passed unchanged assertions and independent Sol review without another run. That proof used frozen 0.1.0 source and does not qualify later working-tree runtime edits. ACK age includes reverse transport, scheduling and the harness; it is not one-way latency. |
| `tests/token-bucket.luau`, `tests/server-session.luau`, `tests/client-session.luau` | Refill/clocks, admission charging, handler leases, routing, discovery cancellation, transport integrity, and cleanup. |
| `benchmarks/tests/` | Contract rejection, adapters, timing/lifecycle boundaries, stale probe rejection, host provenance/framing/cleanup, reporter compatibility, quick diagnostics, and study/gate orchestration with exact place pins. Synthetic/build checks are not native timing evidence. |

Portable RPC session checks cover false and explicit trailing-nil request
arguments. State session checks cover fresh composite payload ownership across
immediate and queued paths on both session sides.

Real Studio correctness is explicit:

```sh
lune run tests/studio-reliable-events.luau
```

Append `--correctness-only` for the two-client correctness scenario; omit it for
the complete correctness/admission matrix. This fixture covers native,
composed, and tagged-union payloads, both delivery channels, malformed
rejection/charging, startup cancellation, and transport mutation. Its first
three C2S observations also record the loaded Relay version and actual player
IDs for private-artifact verification. Unreliable checks require valid
observations and audiences without requiring full or ordered delivery.
After a timeout kill, cleanup requires an independent Studio-exit check before
removing the bootstrap script.
The native-value cases share this two-client harness and run in bounded
sequential definition groups. Their Studio qualification must pin source, fixture,
place, and Studio inputs; cover every new shape in both directions; and verify
engine enum and constructor behavior. Portable Lune checks do not establish this
qualification. The October 16 source-frozen native-value run passed on Studio
`0.743.0.7431133` (executable SHA256
`CC70176D50D5F2C1EDC26D40F1FCDC530748FC83DEDC63C2FDBB251F766972D2`),
launch `cef37375d14347ba8cfc176aadb113d3`. The two-client fixture passed all 32 harness
checkpoints, including all 22 new native shape kinds in both directions (54
C2S and 54 S2C checked value receipts), exact intrinsic enum domains, fresh Font
ownership, DateTime boundary samples, negative-size regions, and 40 named raw
constructor/decoder probes. DateTime, TweenInfo and PathWaypoint were checked in
Roblox rather than emulated in Lune. The 294 input hashes were identical before
and after the run, fingerprint
`a3aa779b4e398fa88d8992dae87dbf3d8113bbf4dabe8cf3091eb85fa217fc69`.
The manifest, executable/place hashes, result, and receipt summary remain under
`.tmp/native-values-4adb6b38ffc0447e8a0288e2a3ed4660/`; source, fixture, and host
must match those inputs when citing that evidence. This is untimed correctness
proof for that build and source, with no performance claim.
Instance-reference Studio qualification passed on October 16, 2026 with the same
Studio build and executable hash, launch `6b4ca238b5c942738232f869c79549ea`.
All 33 two-client checkpoints passed, including all 14 supported class types,
subclasses, arrays, map values, optionals and tagged unions. Four payload receipts
per direction covered 54 checked reference occurrences per direction. Raw native
sidecars proved nil arrival for client-only, ServerStorage and unstreamed Part
references, with no callback; later valid events recovered after missing or
malformed references. Both clients observed the far model container while its
referenced Part stayed absent for at least one second before sending and remained
absent after rejection. This follows Roblox's
[nonatomic streaming behavior](https://create.roblox.com/docs/workspace/streaming#nonatomic).
The 22-byte scoped frame retained byte debits after rejection: one invalid payload,
one aggregate refusal, two per-player refusals, and zero callbacks. Destroyed or
reparented outbound references made no handoff before a valid scoped broadcast.
All 305 source input hashes and the place/executable hashes matched before and
after capture; source manifest fingerprint
`f2e78df25ceff02a84f649b9ac9123dd0b320017d3d28399c79ba99fbcf8c0a8`.
Manifests, frozen place, raw result, logs and summary remain under
`.tmp/instance-refs-4f6636c3f74c42aab7e833059eaf2632/`. The qualification note was
added after capture; runtime, fixture and host must match those inputs when citing
the evidence. This is untimed correctness proof, with no performance claim.
Scalar quantization passed all 34 two-client Studio checkpoints on October 16,
2026 with build `0.743.0.7431133`, launch
`e37ae7f3b79946d8badf73130e340a43`. Native callbacks and raw buffers checked
one-byte grid codes and two-byte little-endian code 256 in both directions,
midpoint neighbors, negative ties, positive zero, decimal steps and exact
endpoints. Server and both clients checked the accepted `2^-974` step floor and
the permitted large-offset endpoint residual against the error bound and stable
rewrite code. Each player's 25-byte budget retained charges for unused-code and
truncated frames, admitted a later valid frame, then refused a further frame;
there were four invalid-payload rejections, two per-player byte refusals and no
aggregate refusal. RPC request/response and FIFO in both directions delivered
the rounded value with exact handoff reports. All 312 source hashes and the
place/executable hashes matched before and after capture. The collector's decimal
report differed from the host calculation by one binary64 ULP; its corrected
validator replayed the complete saved capture with a one-ULP allowance only for
that report field. Native exact-value assertions and raw code 35 remained exact;
mutating the report beyond one ULP or changing a raw code failed validation.
Frozen inputs, raw result, logs, replay and receipt remain under
`.tmp/quantized-551501469a974e69870b1610f087b6bb/`. Runtime and Studio fixtures
still match the capture; the host-only reporting correction and this qualification
note followed it. The first attempt is retained there: Studio flushed the former
subnormal allowance to zero, prompting the reviewed step-floor correction. This
is untimed correctness evidence for the tested source/build and routes.

Compact values, bit packing and outbound byte budgets passed all 37 two-client
Studio checkpoints on October 16, 2026 with build `0.743.0.7431133`, launch
`049f9124e9cc4be4b1786f3dc073ee0e`. Native reliable events checked quantized
Vector2/Vector3 values and raw codes, compact CFrame position and angular bounds,
malformed-code/truncation rejection, and later valid recovery. Packed tuple,
array and struct receipts checked exact masks, canonical padding and unused enum
rejection; each player's 88-byte admitted sequence exhausted its budget before
the trailing one-byte probe. Outbound checks proved atomic two-player fanout
refusal without debiting the healthy player, a bounded kind-5 RPC refusal, and
FIFO/State retention and explicit cleanup without application handoffs. The raw
observer checked actual native boolean tuples, excluded only validated readiness
challenges, and recorded all other unexpected traffic.
All 324 source input hashes and the place/executable hashes matched before and
after capture; source manifest fingerprint
`72779cf23e4c961692798ddaa7fb7d911deedabc4c0edf725df13acd24a908b3`.
Frozen inputs, raw results, logs and receipt remain under
`.tmp/compact-review-20261016/native-pass/`. This qualification note followed
capture; runtime, Studio fixtures and host still match those inputs. Portable
checks separately cover compact shapes in bit-packing-enabled RPC, FIFO, State
and unreliable routes, plus packed sets, malformed sidecars, and the cross-lane
State timer regression.
This is untimed correctness evidence for the tested source/build and routes.
An earlier source-specific capture of these slices, launch
`60f79e7118434f7fa8292c0e4865776e`, also passed 37 two-client checkpoints; its
separate inputs and receipt remain under
`.tmp/four-slices-0f3deb5d7479406c8f875112ebe80572/`. The current qualification
above uses the later compact-review manifest.
The primitive-unreliable buffer extension passed the two-client correctness fixture
on October 15 with Studio `0.743.0.7431133`, launch
`07ba398749f6410faaaf29c6ef2f5cc9`, using a frozen source/place snapshot. All 24
checkpoints passed. The 900-byte raw frames (891 padding bytes plus nine bytes of
fields/header/prefix) delivered eight C2S samples from each client, eight targeted
S2C samples only to the selected client, and eight broadcast samples to each client.
Oversized 901-byte attempts returned `InvalidPayload` before handoff on client
Send and server Send/Broadcast, with unchanged handoff counters. Source, place,
Studio and result hashes are retained in the ignored
`.tmp/unreliable-native-974b3033009542c39bf526ef8b22cefa/` evidence directory, with
the result at `.tmp/relay-proof-07ba398749f6410faaaf29c6ef2f5cc9.json`. This qualifies
the tested source/build and scenarios, not Roblox's exact encoded size or guaranteed
unreliable delivery. The earlier updater-interrupted attempt remains unqualified.
The optional endpoint-rate policy passed a frozen two-client correctness run on
October 15 with Studio `0.743.0.7431133`, launch
`60a800ec9e2747bdae282f63691d544c`. All 25 ordered checkpoints passed, including
per-player burst rejection and refill, independent endpoint/peer admission, RPC
refusal with the existing client deadline, and whole-frame FIFO/State rejection
with shared and earlier endpoint charges retained and no partial callbacks.
The 20 frozen inputs, built place, Studio, collector, result and log hashes are
retained under `.tmp/endpoint-rate-4bcea81105894134bc268438840324bd/native-2/`;
the result is `.tmp/relay-proof-60a800ec9e2747bdae282f63691d544c.json`.
Independent Sol review matched those pins and the place's script sources. This
qualifies the tested source/build and fixture cases; it is not a performance or
full admission-matrix result. The first attempt
`b4915ad4f8254988844fe8e3d9d8ca0d` remains retained and unqualified after a queued
fixture cleanup failure; the correction changed only the fixture's post-destroy
event selection.
Bounded Color3 passed the frozen two-client correctness run on October 15 with
Studio `0.743.0.7431133`, launch `10917385bb6e4a509412944da99cb70d`. All 26 ordered
checkpoints passed. Eight constructor cases ran in the server and both clients;
native and composite events, RPC request/response and both output forms preserved
the checked Float32 components and positive zero. Each player admitted one native
Color3 at a 15-byte capacity (three-byte header plus twelve content bytes), then
refused a minimum-charge raw frame and a second Color3 before parsing, with no
invalid-payload or aggregate-byte refusal. The 20 frozen inputs, 19 place script
sources, place, Studio, collector, result and log pins are retained under
`.tmp/color3-816a2b5cdf1644dcbf01bcd3ddb01d03/native-1/`; the result is
`.tmp/relay-proof-10917385bb6e4a509412944da99cb70d.json`. Independent Sol review
matched the pins, place script sources and ordered result. This qualifies the tested
source/build and fixture cases, not engine wire-byte accounting, performance or
the full admission matrix.
The frozen compatibility source passed 78/78 stable foundation stages and 28
ordered two-client Studio checkpoints on October 15, launch
`f8acf23ebf134b4e9cddc08744e35d74`, Studio `0.743.0.7431133`. The existing fixture
now includes 64 S2C listeners, actual 90-byte all-bit Acks, ID65535 delivery,
89/91-byte rejection, highest-bit disconnect/refresh/reconnect, and FIFO/State
byte/endpoint admission ordering without partial callbacks. A local artifact
overlay additionally checks RR2/RR7 mismatches before handoff, fresh matched
package/definition/listener restarts and the bounded unchanged RR1 mixed pairs.
Both model builds and source ZIP builds reproduced; all 14 runtime sources match
the model and proof place. `tests/studio/StatePut.luau` is now in the required
source inventory. Exact inputs, final/failed evidence and scope are retained in
`.tmp/native-compatibility-20261015/receipt.md`. This proof uses the earlier frozen
compatibility runtime and excludes concurrent Color3/later benchmark-tool changes;
the shared fixture merge preserves Color3 but is not that native source selection.
It does not qualify editor import UI, pending work continuity, performance or a
final release version. Shared runtime and index bytes were preserved by this task.
Opt-in ordered unreliable events passed the two-client Studio correctness fixture
on October 16, 2026, build `0.743.0.7431133`, launch
`a1f240d003b741c897417bf92f02e7dc`: all 30 checkpoints passed. The added checkpoint
observed 900-byte frames and exact payloads in both directions, rejected 901-byte
sends before handoff, rejected controlled duplicate/stale and malformed frames,
and recreated a client with generation 2 while refusing prior-generation data.
Per-phase raw-arrival and handler/diagnostic barriers distinguish this from a
claim that natural network reordering was observed. Pinned runtime, native
fixture/runner and host inputs, Studio executable and built-place hashes remained
unchanged through execution; the receipt is
`.tmp/ordered-unreliable-e4022695580a4f4aaf2f5499d4a9a971/native-receipt.json`.
This qualifies that source/build correctness snapshot, with no performance claim
or guarantee that unreliable messages arrive. Portable serial-window, admission,
typing and compatibility checks remain separately required.

External payload/reuse qualifications are opt-in and require pinned local inputs.
Use focused checks before collecting the full measured matrix.

[examples/README.md](examples/README.md) owns the public-API example place. The
public-type check analyzes its mapped scripts, and the foundation gate builds it.

Private plans/reports under `docs/`, `.tmp/`, Forge artifacts, dependencies,
benchmark vendors/generated runtimes, and local results stay ignored. CI runs on
pinned Windows 2022 for pushes to `main` and all pull requests; after installing
pinned Rokit tools it acquires the locked benchmark libraries and regenerates
their adapters before the full foundation proof. Keep changes surgical and update
this map when purpose, ownership, API, modules, tests, or guardrails change.
