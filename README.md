# Relay

## Requirements

- [Rokit](https://github.com/rojo-rbx/rokit) `v1.2.0`

## Development setup

From the repository root:

```sh
rokit install
lune run scripts/verify-foundation.luau
```

The verifier runs the registered correctness tests and checks the public module
contract, tracked file set and LF policy, Git ignore rules, Wally package
contents and archive creation, the Rojo package build, and CI workflow pins.

## Reliable events

Relay provides fixed-schema reliable events over one server-owned Roblox
`RemoteEvent`. It is standalone and has no runtime dependencies.

The frozen public module exposes `VERSION`, `define`, `createServer`, and
`createClient`. A shared definition assigns stable IDs and directions to events:

```lua
local Events = assert(Relay.define({
    name = "Gameplay",
    version = 1,
    events = {
        Input = {
            id = 1,
            direction = "ClientToServer",
            fields = {
                { name = "sequence", type = "u32" },
                { name = "enabled", type = "boolean" },
            },
        },
    },
}))
```

Definitions are immutable opaque tokens. Define at most 16 events with at most
8 fields each. Supported types are `boolean`, `u8`, `u16`, `u32`, `f32`, and
`Vector3F32`. Unsigned fields may narrow their bounds; floats and vectors require
finite Float32-exact `minimum` and `maximum`. Values must be finite and within
bounds before and after Float32 rounding; negative zero becomes positive zero.
Strings, tables, buffers, Instances, and dynamic or nested payloads are unsupported.

On the server, explicitly choose finite ingress limits and connect before startup:

```lua
local server = assert(Relay.createServer(Events, {
    inboundRate = {
        perPlayer = { capacity = 120, refillPerSecond = 60 },
        aggregate = { capacity = 960, refillPerSecond = 480 },
    },
}))
local connection = assert(server.events.Input:Connect(function(player, sequence, enabled)
    -- Validate game permissions and authoritative state before acting.
end))
assert(server:Start())
```

On the client:

```lua
local client = assert(Relay.createClient(Events, { startupTimeoutSeconds = 10 }))
assert(client:Start())
assert(client.events.Input:Send(1, true))
```

For a `ServerToClient` event, the server handle exposes
`:Send(player, ...fields)` and `:Broadcast(...fields)`, and the client handle
exposes `:Connect(handler)`. Broadcast makes one `FireAllClients` call. Each
receiving endpoint permits one listener; `connection:Disconnect()` permits a
replacement. `session:Destroy()` releases the session and is idempotent.
See [the complete examples](examples/reliable-events).

Object-producing operations return `object, nil` or `nil, error`; boolean
operations return `true, nil` or `false, error`. Errors are frozen `{ code,
message }` records. The stable codes are `InvalidDefinition`, `InvalidOptions`,
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
