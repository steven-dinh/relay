--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local clientTime = s.field("serverTime" :: "serverTime", s.f64(0, 2^42))
local clientSequence = s.field("sequence" :: "sequence", s.u8())
local clientEnabled = s.field("enabled" :: "enabled", s.boolean())
local clientAction = s.field("action" :: "action", s.enum("Jump" :: "Jump", "Move" :: "Move"))
local schema = {
    name = "CompetitiveInvalidTypes",
    version = 1,
    events = {
        ClientBatch = s.clientToServer(1, s.ordered(clientTime, clientSequence), {
            queue = "Batch", timestampWindow = 0.5,
        }),
        ClientState = s.clientToServer(2, s.ordered(clientTime, clientEnabled), {
            queue = "State", timestampWindow = 1,
        }),
        ServerBatch = {
            id = 3,
            direction = "ServerToClient" :: "ServerToClient",
            queue = "Batch" :: "Batch",
            fields = s.ordered(s.field("sequence" :: "sequence", s.u8())),
        },
        Immediate = {
            id = 4,
            direction = "ClientToServer" :: "ClientToServer",
            timestampWindow = 0.25,
            fields = s.ordered(clientTime, clientAction),
        },
        Ordered = {
            id = 5,
            direction = "ClientToServer" :: "ClientToServer",
            delivery = "OrderedUnreliable" :: "OrderedUnreliable",
            fields = s.ordered(s.field("sequence" :: "sequence", s.u8())),
        },
    },
    requests = require("./rpc-methods"),
}
local definitionValue, definitionIssue = Relay.define(schema)
local definition = assert(definitionValue, definitionIssue and definitionIssue.message)
local serverValue, serverIssue = Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 32, refillPerSecond = 32 },
    aggregate = { capacity = 64, refillPerSecond = 64 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(definition, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")

server:CreatePacedBatcher(0.02)
local pacedValue, pacedIssue = client:CreatePacedBatcher(0.02, { manual = true })
local paced = assert(pacedValue, pacedIssue and pacedIssue.message)
paced.events.ServerBatch:Send(1)
paced.events.Immediate:Send("Jump")
paced.events.Ordered:Send(1)
paced.events.Method:Send(1)
paced.events.ClientBatch:Send(0.5, 2)
paced.events.ClientBatch:Send("bad")
paced.events.ClientState:Send(0.5, true)
client:CreatePacedBatcher(0.02, { manual = "yes" })
Relay.createClient(definition, { startupTimeoutSeconds = 3, diagnostics = { traffic = "yes" } })
Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 32, refillPerSecond = 32 },
    aggregate = { capacity = 64, refillPerSecond = 64 },
}, diagnostics = { reports = 1 } })

local state = assert((client:CreateState(0.02)))
state.events.ClientState:Put(1, "Other", true)
state:Flush()
local independent = assert((server:CreateState({ player }, 0.02, {
    deferOutbound = true,
    progress = "Shared",
})))

client.events.Immediate:Send(0.5, "Jump")

local badTimestampType = Relay.define({
    name = "BadTimestampType", version = 1, events = {
        Event = {
            id = 1, direction = "ClientToServer" :: "ClientToServer", timestampWindow = "soon",
            fields = s.ordered(s.field("serverTime", s.f64(0, 2^42))),
        },
    },
})
local badTimestampDirection = Relay.define({
    name = "BadTimestampDirection", version = 1, events = {
        Event = {
            id = 1, direction = "ServerToClient" :: "ServerToClient", timestampWindow = 0.5,
            fields = s.ordered(s.field("serverTime", s.f64(0, 2^42))),
        },
    },
})
local badTimestampField = Relay.define({
    name = "BadTimestampField", version = 1, events = {
        Event = {
            id = 1, direction = "ClientToServer" :: "ClientToServer", timestampWindow = 0.5,
            fields = s.ordered(s.field("time", s.f64(0, 2^42))),
        },
    },
})

local maybeTimestampWindow: number? = nil :: number?
Relay.define({
    name = "OptionalTimestampWindow",
    version = 1,
    events = {
        Event = {
            id = 1,
            direction = "ClientToServer" :: "ClientToServer",
            timestampWindow = maybeTimestampWindow,
            fields = s.ordered(s.field("serverTime", s.f64(0, 2^42))),
        },
    },
})
s.serverToClient(1, s.ordered(s.field("serverTime", s.f64(0, 2^42))), { timestampWindow = 0.5 })

print(independent, badTimestampType, badTimestampDirection, badTimestampField)
