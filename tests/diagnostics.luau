local Definition = require("../src/Definition")
local Diagnostics = require("../src/internal/Diagnostics")

local definition = assert(Definition.define({
    name = "DiagnosticsTest",
    version = 1,
    events = { State = { id = 1, direction = "ServerToClient", fields = {} } },
}))
local inboundRate = {
    perPlayer = { capacity = 4, refillPerSecond = 1 },
    aggregate = { capacity = 8, refillPerSecond = 2 },
}
local diagnostics = Diagnostics.create(Definition.get(definition).events, "Server", inboundRate, {
    perPlayerEndpoint = 1,
    perPlayer = 8,
    global = 64,
})

inboundRate.perPlayer.capacity = 99
assert(diagnostics.inboundRate.perPlayer.capacity == 4, "diagnostics metadata must copy options")
diagnostics.counters.received = 4_294_967_294
Diagnostics.increment(diagnostics.counters, "received")
Diagnostics.increment(diagnostics.counters, "received")
Diagnostics.increment(diagnostics.events.State, "dispatched")

local snapshot = Diagnostics.snapshot(diagnostics, "Started", 1)
assert(snapshot.counterLimit == 4_294_967_295 and snapshot.counters.received == snapshot.counterLimit)
assert(snapshot.events.State.dispatched == 1 and snapshot.inFlight == 1)
assert(table.isfrozen(snapshot) and table.isfrozen(snapshot.counters)
    and table.isfrozen(snapshot.events) and table.isfrozen(snapshot.events.State)
    and table.isfrozen(snapshot.inboundRate) and table.isfrozen(snapshot.inboundRate.perPlayer))

Diagnostics.increment(diagnostics.events.State, "dispatched")
assert(snapshot.events.State.dispatched == 1, "later increments must not change old snapshots")
assert(not pcall(function() snapshot.events.State.dispatched = 0 end), "snapshot rows must be immutable")

print("PASS Relay.Diagnostics")
