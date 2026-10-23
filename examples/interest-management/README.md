# Interest management example

Build the standalone Studio place from the repository root:

```sh
rojo build examples/interest-management/default.project.json --output .tmp/relay-interest-management-example.rbxlx
```

Open the place in Studio. It maps Relay to the current checkout's `../../src`,
places the trusted `Groups` companion and shared definition in
`ReplicatedStorage`, and enables `Workspace.UseNewLuauTypeSolver`.

`Groups.new(players)` is an optional server-side helper for replacing and
snapshotting named audiences:

```lua
local groups = Groups.new(game:GetService("Players"))
local ok, problem = groups:Set("room:arena", authorizedPlayers)
local members, missing = groups:Members("room:arena")
```

`Set` atomically replaces the full membership, accepts an empty dense array, and
deduplicates repeated Players. It rejects names that are empty or over 64 bytes,
more than 16 groups, arrays with over 64 raw entries, metatables, keyed or sparse
arrays, non-Player entries, and Players unless both `Parent == players` and
`players:GetPlayers()` contains them. Duplicate entries count toward the 64
raw-entry limit. Invalid audience input leaves the existing group unchanged.
Failures return `InvalidGroup`, `InvalidAudience`, `GroupLimit`, or
`NotCurrentPlayer`; `Members` returns a fresh array filtered against the current
Players roster, or `MissingGroup`. `Delete` is idempotent and succeeds for an
absent group. Calls after idempotent `Destroy` fail with `Destroyed`; destroy
disconnects its `PlayerRemoving` listener and clears all memberships. The helper
removes a departing Player from every group.

The server chooses all membership from the trusted current player roster; clients
cannot claim a room, team, or spectator role. In roster order, every fourth
player is a spectator. Other players enter `room:arena` when their roster index
is 1 modulo 3, and `room:lobby` otherwise; every other active player enters
`team:red`. A roster over 64 stops the demo with one `PlayerLimit` warning.
Roster compaction can change roles, including promoting a former spectator.

`Notice` uses `SendTo` for room and red-team messages. Its only `SendExcept`
message is the public active-player announcement, excluding the spectator group.
A group membership change does not change recipients already captured by a
State lane. Before each rebuild, the server destroys the spectator score lane,
explicitly excludes the departing Player, replaces all groups, then creates a new
bounded lane and seeds the latest absolute score with a strictly increasing tick
when spectators remain.

The `Score` event uses one key on the `State` queue. Newer unsent snapshots
replace older ones; destroying a lane discards its pending snapshot. A new lane
gets current state from an explicit seed, not automatic replay. The one-second
producer publishes a fresh score after a delayed step without catch-up. State
handoffs and successful Notice sends are not delivery receipts. The example has
no readiness dependency and clients send no membership claims.
