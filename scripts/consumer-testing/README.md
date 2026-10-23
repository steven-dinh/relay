# Consumer integration tests

This development kit runs real Relay sessions under Lune with the repository's
existing portable service mocks. It stays outside `src` and the Wally package.
Use a repository checkout with the pinned tools in `rokit.toml`; run commands
from the repository root.

```sh
rokit install
lune run scripts/consumer-testing/run.luau
lune run tests/consumer-testing.luau
```

`run.luau` is an executable integration test you can copy and adapt. It attaches
application handlers to ordinary Relay sessions, delivers actual request/reply
and event frames, and asserts startup ordering, RPC deadlines and cancellation,
FIFO pressure, disconnect, and cleanup. No internal codec is exposed.

## Minimal application test

```luau
local Relay = require("../../src")
local Kit = require("./Kit")
local s = Relay.schema
local definition = assert(Relay.define({
    name = "MyIntegration", version = 1,
    events = { Input = s.clientToServer(1, s.fields({ value = s.u8() })) },
}))

Kit.withFixture(definition, function(test)
    local received = nil
    assert(test.server.events.Input:Connect(function(player, value)
        assert(player == test.player)
        received = value
    end))
    test:Start()
    assert(test.client.events.Input:Send(7))
    test:Pump()
    assert(received == 7)
end)
```

Save this next to `Kit.luau`, or adjust its two relative requires for your file's
location. The kit wraps the existing portable session loaders; it is not a
standalone installed package. Keep your application handlers in modules that can
accept a session and game-owned dependencies, then connect them in this callback.
The callback always tears down every session, including when an assertion fails.
Relay catches exceptions inside its event/RPC handlers; assert observed results
after Pump or Await in the `withFixture` callback, or check session diagnostics
for `counters.handlerErrors`.
It does not stop arbitrary application coroutines or undo application effects.

## Controls and limits

- `Kit.new(definition)` creates one fake current Player and two unstarted
  sessions. Set `clients = 2` (an integer from 1 through 4) for one shared server
  and separate client sessions. `test.clients[index]` exposes that client's
  `client` session and `player`; `test.client` and `test.player` alias entry 1.
  Connect listeners before `test:Start()`. Supply creation options with
  `Kit.new(definition, { server = serverOptions, client = clientOptions })` or
  `Kit.withFixture(definition, callback, options)`. Named namespaces must match
  in both options; the kit rejects mismatches because its portable transports
  bridge separate fake DataModels. Client options apply to every client.
- `test:Start()` starts the server, then each client. Call `test:Pump()` to complete
  readiness traffic before inspecting ready audiences. A message already
  delivered by Pump before a listener is connected is not replayed. A held
  message can reach a listener connected before Pump delivers it.
- `test:Pump()` delivers due messages until quiescent, with a 1024-recipient
  delivery budget per call. Reliable messages retain FIFO order for each client
  in each direction. Unreliable messages use the same order unless controlled
  explicitly below. A feedback loop that exceeds the budget fails and tears down
  the fixture. Pump never advances time and adds no retries.
  The budget covers transport handoffs, not arbitrary loops in application
  callbacks or deferred work.
- At most 1024 recipient messages may be held, including captured sends and
  duplicates. Broadcasts snapshot the current clients at send time and count one
  message per recipient. A send that would exceed the limit destroys the fixture
  before capture; Relay reports the failed local handoff. An explicit Duplicate
  at the limit rejects without changing the queue.
- `test:Advance(seconds)` advances both portable schedulers. Time must be finite
  and nonnegative, and total logical time cannot exceed 60 seconds per fixture.
  Advance does not deliver transport messages. Pump afterwards to observe late
  requests/replies. Timer callbacks use the existing mocks' scheduler behavior;
  this is not a full simulation of the engine task loop or timer tie ordering.
- `test:Disconnect(index)` removes that Player, client transport and held
  messages. The default index is 1. Pending calls settle as `Disconnected`;
  timers and listeners owned by that client are released while other clients
  continue. After the last disconnect the fixture is `Disconnected`.
  `test:Destroy()` is idempotent. Create a fresh fixture to reconnect.
- `test:GetStatus()` returns lifecycle, time, queued-message, connection and
  active-timer counts for cleanup assertions, with per-client rows in `clients`.
  It does not expose mock services.

## Deterministic unreliable faults

`test:GetPending()` collects held sends and returns a frozen list of frozen
metadata rows: `id`, `direction` (`ClientToServer` or `ServerToClient`), `client`
(the recipient/sender index), `delivery` (`Reliable` or `Unreliable`) and
`dueTime`. IDs remain valid until the message is delivered, dropped or removed
on disconnect. Payloads and mock services are private.

All four controls below accept only an existing **unreliable** message ID.
They return a failure and a reason for reliable, invalid or stale IDs without
changing the queue.

| Control | Result |
| --- | --- |
| `test:Drop(id)` | Removes one recipient message, deterministically modeling loss. |
| `test:Duplicate(id)` | Adds one copy with its own ID and the same due time; returns the new ID. |
| `test:Delay(id, seconds)` | Sets its due time to current logical time plus a finite, nonnegative delay, within the fixture's 60-second limit. |
| `test:Deliver(id)` | Delivers that one message immediately, even before its due time. Select IDs out of order to model reordering. |

This example drops one broadcast recipient's packet and delivers the other
recipient's copy twice. Use a definition with an unreliable S2C `Snapshot` event:

```luau
Kit.withFixture(definition, function(test)
    local received = { 0, 0 }
    for index, entry in test.clients do
        assert(entry.client.events.Snapshot:Connect(function()
            received[index] += 1
        end))
    end
    assert(test:Start())
    test:Pump() -- finish reliable startup/readiness controls
    assert(test.server.events.Snapshot:Broadcast(7))
    local pending = test:GetPending()
    assert(#pending == 2)
    assert(test:Drop(pending[1].id))
    local copy = assert(test:Duplicate(pending[2].id))
    assert(test:Delay(pending[2].id, 0.2))
    assert(test:Deliver(copy))
    assert(test:Advance(0.2)) -- no transport delivery
    assert(received[1] == 0 and received[2] == 1)
    test:Pump()
    assert(received[1] == 0 and received[2] == 2)
end, { clients = 2 })
```

The executable `run.luau` includes a complete fault scenario; the consumer test
also covers two-way routing, reliable order, per-client cleanup, bounded queues
and actual Relay ordered-S2C stale rejection after reordering/duplication.
Duplicate delivery of an ordinary unreliable event may invoke its handler twice;
ordered-unreliable events reject stale sequence numbers through Relay itself.

The fixture still rejects ordered client-to-server startup and Instance
references. It changes no wire format, schema limits or admission charges;
messages pass through the real Relay send/receive validation paths.
Native Instances, streaming/replication, engine scheduling, bandwidth and network
performance require Studio. Portable multi-client routing represents independent
sessions, not engine replication or scheduling. Do not yield arbitrary
application handlers in portable scenarios expecting the kit to resume them.
The kit does not grant production dependency injection or bypass server
validation. A successful send is still a local handoff, not a delivery receipt.

Timeout and Cancel settle the caller locally. They do not cancel server work,
reverse side effects, or prove whether an action happened. The executable test
delivers the held request after local settlement and verifies that distinction.

## Studio scenarios

Build the public-API fixture, then open it in Studio:

```sh
rojo build examples/testing/default.project.json --output .tmp/relay-testing.rbxlx
```

Use a fresh **Server & Clients** playtest with one client for each run. The
fixture prints labeled observations in server/client Output. Both sides attach
listeners before Start. A client Ready event triggers a server Notice; a slow
RPC demonstrates success, timeout and cancellation; the client fills and flushes
a reliable FIFO; finally a Close event destroys the server session while an RPC
is pending. Cleanup deliberately ends the fixture; restart for each profile.

Use Roblox's built-in [Network Simulator](https://create.roblox.com/docs/studio/network-simulator)
for latency, jitter and loss. If needed, enable **New Device Simulator** under
**File > Beta Features**, restart Studio, enable **Device Simulator** in Test,
and select the **Network** pill above the viewport. Stage a profile and select
**Apply**. Record all six directional values and the Studio version with Output.
These UI instructions were checked on 23 October 2026; follow the linked Roblox
documentation if the beta UI changes.

| Run | Added conditions | Observe |
| --- | --- | --- |
| Baseline | All six controls zero | Notice arrives; long-deadline RPC succeeds; short deadline times out; cancelled call stays cancelled; queue rejects overflow, then flushes in order. |
| Delay | 200 ms inbound and outbound latency, zero jitter/loss | Replies arrive later; timeout remains local and the server may still log the request. |
| Variation | 100 ms latency and 50 ms jitter each direction, zero loss | Arrival times vary; reliable FIFO values retain order. |
| Loss | The same variation plus 0.50% loss each direction | Reliable traffic can incur retransmission delay; observe eventual delivery or terminal failure, not silent normal loss. |

The Studio fixture's long RPC deadline is generous but finite. Record a timeout
under severe conditions as a result; do not retry a side-effecting request merely
because its outcome is uncertain. Packet loss is probabilistic, so a short run
may observe no loss. These scenarios establish observations, not latency bounds.

For disconnect cleanup, the final Close ends the server session. The pending
call should settle as `Disconnected` in the controlled baseline; impaired runs
record whether a reply or timeout wins the race. The script destroys the client and
cancels its queue. Stop/restart the playtest and confirm no old fixture logs or
requests reappear. Also stop the client early during a slow request and check
server cleanup when the Player leaves. Application handlers may finish after
Relay teardown; their side effects remain application-owned.

On a shared development host, acquire its existing Studio ownership lease and
confirm a quiet window before starting, controlling, or stopping Studio. Building
the place and running the portable kit do not provide native execution proof.
