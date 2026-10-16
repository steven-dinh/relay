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
caller-selected audience. Its shared definition enables listener readiness;
the client connects before startup. The server intersects the game's authorized
audience with Pose's latest listener claims before creating a lane. Its hooks
show repeated Put, queue pressure, status, manual Flush, Remove and cleanup;
connect them to the game's authoritative pose updates.
The single-entity client rejects stale ticks. Ticks must continue increasing
across lane recreation; choose a new application epoch before u32 exhaustion.
New Players are not added to a captured audience automatically. Build it with:

```sh
rojo build examples/state-snapshots/default.project.json --output .tmp/relay-state-snapshots-example.rbxlx
```

### Readiness and audience changes

Call `_beginPoseStream(authorizedAudience)` after server startup and when the
game chooses to replace the stream's audience. It snapshots `GetReadyPlayers`,
intersects that claim with the supplied authorized Players, destroys the old
lane, and creates a new lane only for a nonempty result. Destroy discards old
unsent poses. Submit the current authoritative pose after rebuilding; Relay
does not seed or replay state for new recipients. Rebuilding also releases the
old key and timer. Keep ticks increasing across rebuilds.

An empty readiness snapshot is valid, including immediately after client Start;
it leaves no active stream. The game owns a bounded initialization deadline and
decides when to query again. Readiness claims can change after lane creation;
the lane does not track them automatically. Clients can make false claims, so
readiness grants no game permission or receipt. The client hook
`_refreshPoseReadiness()` sends one best-effort Ack or Hello; pass `true` only
when requesting a fresh Challenge is appropriate. It does not wait for server
acceptance. Choose a bounded recovery policy instead of polling or retry loops.
See the [readiness contract](../docs/reference.md#optional-listener-readiness).

### Queue pressure and failed handoffs

`_publishPose` returns `queued, problem, status`; `status` is absent when no
stream is active. A `QueueFull` result skips that sample and leaves the previous
pending pose intact. Submit a fresh absolute pose on a later authoritative
update; retaining rejected samples defeats latest-unsent state. Observe
`status.activeKeys`, `pendingKeys`, `pendingBodyBytes`, and `lastFlush` outside
hot update loops. These counts cover this lane; the four-lane, 64-key and
16384-body-byte caps are shared by the session. A single small demo pose rarely
reaches them, but other lanes can consume the shared budget. `QueueLimit` from
CreateState means the session already owns four lanes. Flush does not release
active keys; Remove or Destroy does. Remove sends no deletion to clients.

Normal service continues after a rejected Put. Avoid immediate flush/retry loops
and growing retry queues. `_flushPose` reports successful local handoffs even
when a later handoff fails; selected bodies have already left the queue.
`lastFlush` also exposes automatic flush results. Neither result proves receipt.
Keep authoritative state in the game and use subsequent absolute updates or an
explicit game recovery exchange. See the
[State contract](../docs/reference.md#latest-unsent-state).

The public type gate checks all three example projects with the pinned new solver.

### Coordinated definition upgrades

The `reliable-events` example gives a small upgrade exercise. Make a separate
copy of that project as a proposed version 2. In its shared `Definition.luau`,
change `version = 1` to `version = 2` and append a `maximumHealth` field to the
`State` event, keeping its existing ID and earlier field order:

```lua
State = s.serverToClient(2, s.ordered(
	s.field("sequence", s.u32()),
	s.field("health", s.u8(nil, 100)),
	(s.field("maximumHealth", s.u8(nil, 100)))
)),
```

In that same proposed project, update the server's `State:Send` and `Broadcast`
calls to supply `maximumHealth` after `health`, and the client's `State:Connect`
handler to accept the third field. Keep `Input` unchanged. Build and type-check
the complete proposed project before using it. The actual example in this
repository remains a working version 1 baseline.

| Server definition | Client definition | Startup result |
| --- | --- | --- |
| Version 1, original two-field `State` | Same version 1 definition | May start after the usual transport checks. |
| Version 2, three-field `State` | Version 1 | `DefinitionMismatch`; the old client cannot reuse its failed session. |
| Version 2, three-field `State` | Same version 2 definition | A newly created client session may start. |
| Restored version 1 server and handlers | Matching version 1 client | A newly created client session may start after rollback. |

Deploy the server, client and shared Definition as one matched application
revision. Keep the previous complete revision available for rollback. Do not
edit `RelayRemotes.Definition.Value` or hot-swap a live Relay session: the server
owns the transport, and a changed descriptor or remote identity ends an active
session. Pause application sends and settle or explicitly abandon pending game
work according to its own rules before replacing a session. Destroy old session
handles, start new ones with the matching definition, reconnect listeners before
client `Start`, and resend current authoritative state when the new client is
ready. Relay has no replay or automatic migration of queued State, batches, or
pending requests. An uncertain request outcome needs application reconciliation
before a replacement command; a transport handoff alone is not a receipt.

The example client handles `DefinitionMismatch` by releasing its listener and
session, warning once and stopping further sends. If a rollout or rollback
leaves a client with the other definition, use a fresh matching client build and
session. Do not retry the destroyed handle or fall back to the old schema within
one running session. `Relay.VERSION` and the schema's numeric `version` do not
prove compatibility by themselves: startup compares the entire compiled
descriptor and remote topology. Check the [protocol contract](../docs/reference.md#protocol-and-abuse-limits)
and [lifecycle rules](../docs/reference.md#lifecycle-and-admission).

The portable client-session test covers real version/shape mismatch, terminal
cleanup, and a fresh matching startup. The pinned public-type gate checks the
shipped example scripts; the full foundation gate also builds the example place.
Those checks do not prove a live mixed-version deployment or an install/rollback
of a packaged place. Test those separately before an application rollout.
