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
The callback always tears down both sessions, including when an assertion fails.
Relay catches exceptions inside its event/RPC handlers; assert observed results
after Pump or Await in the `withFixture` callback, or check session diagnostics
for `counters.handlerErrors`.
It does not stop arbitrary application coroutines or undo application effects.

## Controls and limits

- `Kit.new(definition)` creates one fake current Player and two unstarted
  sessions. Connect listeners before `test:Start()`. Supply creation options with
  `Kit.new(definition, { server = serverOptions, client = clientOptions })` or
  `Kit.withFixture(definition, callback, options)`.
- `test:Start()` starts the server, then the client. Call `test:Pump()` to complete
  readiness traffic before inspecting ready audiences. A message already
  delivered by Pump before a listener is connected is not replayed. A held
  message can reach a listener connected before Pump delivers it.
- `test:Pump()` delivers reliable messages in order within each direction until
  quiescent, with a 1024-message budget per call. Messages wait until Pump; there
  is no loss, duplication, reordering, retry, or automatic clock progression.
  A feedback loop that exceeds the budget fails and tears down the fixture.
  The budget covers transport handoffs, not arbitrary loops in application
  callbacks or deferred work.
- `test:Advance(seconds)` advances both portable schedulers. Time must be finite
  and nonnegative, and total logical time cannot exceed 60 seconds per fixture.
  Advance does not deliver transport messages. Pump afterwards to observe late
  requests/replies. Timer callbacks use the existing mocks' scheduler behavior;
  this is not a full simulation of the engine task loop or timer tie ordering.
- `test:Disconnect()` removes the Player and client transport. Pending calls
  settle as `Disconnected`; remaining messages are discarded only at terminal
  teardown. `test:Destroy()` is idempotent. Create a fresh fixture to reconnect.
- `test:GetStatus()` returns lifecycle, time, queued-message, connection and
  active-timer counts for cleanup assertions. It does not expose mock services.

The reliable-only fixture rejects definitions containing unreliable events,
ordered client startup, or Instance references.
Native Instances, streaming/replication, multiple clients, engine scheduling,
bandwidth, and network performance require Studio. Do not yield arbitrary
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
