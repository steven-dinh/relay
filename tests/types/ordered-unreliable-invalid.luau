--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local batch = Relay.define({ name = "OrderedBatchInvalid", version = 1, events = {
    Input = {
        id = 1, direction = "ClientToServer" :: "ClientToServer",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        queue = "Batch" :: "Batch", fields = s.ordered(s.field("value", s.u8())),
    },
} })
local state = Relay.define({ name = "OrderedStateInvalid", version = 1, events = {
    Output = {
        id = 1, direction = "ServerToClient" :: "ServerToClient",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        queue = "State" :: "State", fields = s.ordered(s.field("value", s.u8())),
    },
} })
local definition = assert((Relay.define({ name = "OrderedPayloadInvalid", version = 1, events = {
    Input = {
        id = 1, direction = "ClientToServer" :: "ClientToServer",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        fields = s.ordered(s.field("value", s.u32())),
    },
    Output = {
        id = 2, direction = "ServerToClient" :: "ServerToClient",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        fields = s.ordered(s.field("enabled", s.boolean())),
    },
} })))
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 4, refillPerSecond = 1 }, aggregate = { capacity = 8, refillPerSecond = 2 },
} })))
local client = assert((Relay.createClient(definition, { startupTimeoutSeconds = 3 })))
client.events.Input:Send("wrong")
server.events.Output:Broadcast(7)
print(batch, state, server, client)
