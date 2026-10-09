# Examples

The `reliable-events` example uses only Relay's public API. Build its Studio place
from the repository root:

```sh
rojo build examples/reliable-events/default.project.json --output relay-example.rbxlx
```

Open `relay-example.rbxlx` in Studio. The project places Relay, `Definition.luau`
and `ordered.luau` in `ReplicatedStorage`, the server script in
`ServerScriptService`, and the client script in `StarterPlayerScripts`. It enables
the new type solver through `Workspace.UseNewLuauTypeSolver`. When copying the
scripts into another place, set that property to `Enabled` there too.

The strict schema preserves each field's position with `ordered(...)` and its
exact kind/direction with singleton annotations.
Both sides require the same definition module, so their event names, methods,
and payload types are derived without separate client/server declarations.
The helper is an example of consumer-owned schema setup, not a Relay export.

Run `lune run tests/public-types.luau` to check the mapped example scripts.

The example connects before startup and shows explicit cleanup. Choose rates and
game-side validation for your application. A successful send is a transport
handoff; arrange startup in your application when receiving early events matters.

The `combat-inventory` example composes two event modules with `Relay.schema.compose`
and adds an `Inspect` request with a typed `{ owned, count }` response. The server
reads inventory by the actual Player and logs attack intent; game authorization
must precede any damage or inventory change. The client connects before startup
and handles a request failure explicitly. Build it from the repository root:

```sh
rojo build examples/combat-inventory/default.project.json --output .tmp/relay-combat-inventory-example.rbxlx
```

The `state-snapshots` example sends absolute replaceable state through a fixed
caller-selected audience. Its server hooks show repeated Put, status, manual
Flush, Remove and cleanup; connect them to the game's authoritative pose updates.
The single-entity client rejects stale ticks. Ticks must continue increasing
across lane recreation; choose a new application epoch before u32 exhaustion.
New Players are not added to a captured audience automatically. Build it with:

```sh
rojo build examples/state-snapshots/default.project.json --output .tmp/relay-state-snapshots-example.rbxlx
```

The public type gate checks all three example projects with the pinned new solver.
