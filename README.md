# Relay

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

In Studio, import `relay.rbxmx` into `ReplicatedStorage`. The build root is a
ModuleScript named `relay`; rename it to `Relay` so the examples can require
`ReplicatedStorage.Relay`.

For a place with the shared definition and both scripts already mapped, build the
[reliable-events example](examples/README.md).

The verifier runs the registered correctness tests and checks the public module
contract, tracked file set and LF policy, Git ignore rules, Wally package
contents and archive creation, the Rojo package build, and CI workflow pins.
It also checks strict public API consumers with Luau's new type solver, using
hash-verified Roblox definitions cached in ignored `.tmp/`. Run that check alone
with `lune run tests/public-types.luau`; it enables `LuauSolverV2` explicitly.

## Reliable events

Relay provides fixed-schema reliable events over one server-owned Roblox
`RemoteEvent`. It is standalone and has no runtime dependencies.

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

Definitions are immutable opaque tokens. Define at most 16 events with at most
8 fields each. Supported types are `boolean`, `string`, `u8`, `u16`, `u32`, `i8`, `i16`,
`i32`, `f32`, `Vector2F32`, `Vector3F32`, and `CFrame`. Integer fields may narrow their bounds; floats and vectors require
finite Float32-exact `minimum` and `maximum`. Values must be finite and within
bounds before and after Float32 rounding; scalar/vector negative zero becomes positive zero.
Tables, buffers, Instances, and dynamic or nested payloads are unsupported.
The shared definition determines event names, direction-specific methods, and
ordered argument types for both sessions. Integer and float fields have Luau type
`number`; numeric bounds, integer checks, string byte limits, and game permissions
still require runtime validation. Listener callbacks may ignore trailing arguments.

`ordered(...)` preserves field positions for type analysis and copies/freezes the
field array and its plain scalar records once during schema construction. The
`:: "u32"` and direction annotations retain exact string types; they do not convert
or validate values. The helper is consumer-owned, not another Relay export.
Use plain field records: invalid tables with protected metatables can throw in
the helper before `Relay.define` returns its usual error record.

Migrating existing typed schemas requires replacing `fields = { ... }` with
`fields = ordered(...)`, using `ordered()` for no fields, and adding the literal
annotations shown above. Old-solver analysis is no longer supported. Existing
runtime schema data, send calls, wire behavior, and validation are unchanged;
plain arrays remain valid runtime input but no longer provide the typed authoring
path. No unchecked fallback is provided for dynamic schemas.

Keep schema, definition, and session variables inferred: a broad `DefinitionSpec`
annotation loses the information needed for derivation. `Definition`,
`ServerSession`, and `ClientSession` type aliases now take a schema type parameter;
the former broad event-handle type aliases have been removed.

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
Each vector occupies one tuple field. These are native Roblox values, not a
Relay byte encoding.

Integer values travel as native numbers; the type names describe allowed ranges,
not a packed wire width. There is no integer rounding. Each field occupies one
fixed tuple position, and eligible inbound attempts retain the same one-token
per-player and aggregate admission costs.

`CFrame` requires finite Float32-exact translation bounds for X, Y, and Z.
Its rotation must be approximately orthonormal and right-handed: every entry
lies in [-1.0001, 1.0001], each column's squared length differs from 1 by at most
0.0001, pairwise column dot products have magnitude at most 0.0001, and the
determinant differs from +1 by at most 0.0001. All components must be finite.
Slight scale/shear within those fixed tests is accepted; Relay does not repair
or normalize matrices. Accepted local CFrames retain all components and zero
signs unchanged. Roblox controls native remote precision; the tested 0.0001
rotation-component comparison is not a global wire-error guarantee. Each CFrame
is one field with twelve fixed components, not a Relay compressed encoding.

String fields require integer `maximumBytes` from 0 through 1024. Zero allows
only the empty string. Length counts bytes, including NUL, non-UTF8 bytes, and
each byte of multibyte text; accepted strings are unchanged. Text policy belongs
to the caller. An event's string-content bound is the sum of its declared limits,
at most 8192 bytes across eight string fields. This does not bound Roblox wire
overhead or engine allocation before Relay receives the call. Admission charges
calls, not bytes, and overlong calls still consume applicable ingress budgets.

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
The server owns `ReplicatedStorage.RelayRemotes`, containing exactly `Definition`
and `Reliable`. A client checks the exact definition descriptor and attaches its
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
shared aggregate budget, before endpoint or payload validation. Per-player
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
fairness. Game code still owns authorization, ownership, cooldowns, costs,
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
- durable repository guidance is tracked; private plans, downloaded benchmark
  libraries, generated output, local results, builds, dependencies, editor
  state, and local Forge specs/reports remain ignored.

## License

[MIT](LICENSE)
