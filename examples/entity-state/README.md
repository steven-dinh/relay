# Entity state companion

An encounter HUD is a collection: an authorized player needs all current targets,
then absolute health changes and explicit removals. A scheduled stream can keep
an individual value fresh for late listeners, but does not establish a coherent
collection baseline or remove targets that disappeared during an absence.

This optional helper lives outside `src/` and the Wally package. It uses Relay's
existing reliable events and zero-argument RPC. The Relay exports, runtime,
descriptor grammar and wire protocols are unchanged. Both peers must use this
same application definition; changing its shapes requires a coordinated rollout.

Build the runnable example from the repository root:

```sh
rojo build examples/entity-state/default.project.json --output .tmp/relay-entity-state.rbxlx
lune run tests/entity-state.luau
lune run tests/public-types.luau
```

Open the place in Studio with the new type solver enabled by the project. The
server owns the targets, assigns stable numeric IDs, chooses viewers from the
current roster, and demonstrates updates, deletion and audience re-entry. The
client connects before Start and renders its current HUD collection. Neither
membership nor entity lookup is supplied by the client. Delivery does not depend
on a streamed Instance.

`Server.new(isCurrentPlayer, sendUpdate)` owns the authoritative collection.
Both callbacks are trusted, synchronous application code: check the live roster
in the first and call `server.events.Update:Send(player, update)` in the second.
Use `CreateEntity(health)`, `SetHealth(id, health)` and `DeleteEntity(id)` after
game authorization. Only trusted server code calls `SetViewer(player, allowed)`.
Connect Snapshot to `manager:Snapshot(player, os.clock())`, call `RemovePlayer`
from `PlayerRemoving`, and call `Destroy` with the owning session.

`Client.new()` owns a local view. Pass incoming structs to `Receive`, call `Tick`
with the same monotonic clock, and use `GetSnapshot()` for a copied ID-to-health
map. Check `CanBegin(now)` before `Begin(now, cancelPending)` and one 5-second
Snapshot request. Its token goes to `Complete` or `Fail`; the supplied callback
cancels that exact pending request if the attempt becomes obsolete. Keep polling
at the bounded interval even after denial, so a missed re-entry notice can still
recover through a newer baseline. The runnable scripts show complete ownership
and cleanup.

## Recovery contract

The Snapshot request has no arguments. The server looks up the actual calling
Player and returns one complete baseline only when that Player is authorized.
Denied and busy responses contain no entity IDs, counts, collection revision or
membership epoch. The server never returns other players' membership.

Each membership transition receives a strictly increasing epoch. Each target
mutation receives a strictly increasing collection revision. Updates contain
absolute health or an explicit deletion. IDs are never reused during a helper's
lifetime. Counters fail closed before wrapping; create a new Relay session and
client helper together to start another lifetime.

A client installs a baseline atomically, then applies only contiguous buffered
updates newer than its watermark. A live client never installs a baseline older
than its already applied revision. New epochs clear the old view and invalidate
pending baseline work; old epochs cannot reopen a closed or replaced audience.
A same-epoch reset is idempotent. Gaps, invalid data and overflow clear the view
and wait for the next admitted full baseline. No update or uncertain handoff is
automatically replayed.

## Bounds and ownership

| Resource | Limit |
| --- | --- |
| Live targets | 32, each health integer 0..1000 |
| Stable IDs | 1..65535, monotonically assigned, never reused |
| Revision and epoch | u32, no wrap |
| Tracked viewers | 64 current Players, set by trusted server code |
| Baseline | One response, at most 32 unique rows, no chunks |
| Encoded response / update | At most 256 / 32 Relay buffer bytes, checked by the focused test; excludes Roblox transport overhead |
| Shape depth | Baseline struct, array, row struct, scalar leaves; no recursive values |
| Client retention | At most 32 installed rows and 64 pending absolute updates |
| Pending recovery | One generation-owned RPC with a 5-second deadline |
| Resync admission | One attempt per 2 seconds, burst one; server endpoint and application gates run before baseline copying |
| Freshness | Clear an unrefreshed view after 5 seconds |
| Server pending work | No retained response queue, chunk jobs or retry queue |

The caller drives the client helper and periodically requests a fresh baseline.
The runnable adapter owns the one pending RPC handle, cancels it when its attempt
is invalidated, and disconnects its listener at teardown. Cancellation settles
the local request; it does not cancel server application work. Server handlers
do not yield. Departures release server viewer/admission references, and Destroy
clears helper state. A revoked client may already possess earlier data; revocation
stops future authorized sends and clears cooperative clients on notice or expiry.

The client cannot create a baseline queue by choosing IDs, a chunk index, a room,
or a membership claim: none of those inputs exists. Invalid RPC framing and
extra arguments are rejected by Relay before the handler; endpoint/per-player/
aggregate admission remains charged under Relay's existing contract.

The dedicated pre-implementation Sol design/security review accepted this
bounded contract, requiring fail-closed revision exhaustion and epoch-owned
pending requests. Focused tests establish portable race, authorization, invalid
input and lifecycle behavior. The [two-client native fixture](../../tests/studio/entity-state/README.md)
checks the real RPC/event paths, denial, deletion, revocation and re-entry.
The portable test also enforces Roblox's exactly-one-value ModuleScript return
contract. Strict type checks and Rojo builds are separate from native execution;
native qualification remains pending on this source. The inherited full-gate
profiling blocker and separate partial verification are recorded in
[context.md](../../context.md#entity-state-companion).

Platform references checked on 23 October 2026: [task](https://create.roblox.com/docs/reference/engine/libraries/task),
[Players](https://create.roblox.com/docs/reference/engine/classes/Players), and
[remote events](https://create.roblox.com/docs/scripting/events/remote). The example
uses their existing scheduler, roster and actual-caller behavior; documentation
checks do not prove native execution.
