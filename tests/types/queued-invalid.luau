--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = assert((Relay.define({ name = "QueuedInvalidTypes", version = 1, events = {
    OutBatch = {
        id = 1, direction = "ServerToClient" :: "ServerToClient",
        queue = "Batch" :: "Batch", fields = s.ordered(s.field("value", s.u16())),
    },
    InBatch = {
        id = 2, direction = "ClientToServer" :: "ClientToServer",
        queue = "Batch" :: "Batch", fields = s.ordered(s.field("value", s.u16())),
    },
    OutState = {
        id = 3, direction = "ServerToClient" :: "ServerToClient",
        queue = "State" :: "State", fields = s.ordered(s.field("enabled", s.boolean())),
    },
    InState = {
        id = 4, direction = "ClientToServer" :: "ClientToServer",
        queue = "State" :: "State", fields = s.ordered(s.field("mode", s.enum("Idle" :: "Idle", "Run" :: "Run"))),
    },
    Immediate = Relay.schema.serverToClient(5, s.ordered(s.field("value", s.u8()))),
} })))
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })))
local client = assert((Relay.createClient(definition, { startupTimeoutSeconds = 3 })))
local player: Player = error("type-only fixture")
local serverBatch = assert((server:CreateBatch({ player }, 0.02)))
local clientBatch = assert((client:CreateBatch(0.02)))
local serverState = assert((server:CreateState({ player }, 0.02)))
local clientState = assert((client:CreateState(0.02)))

serverBatch.events.InBatch:Send(1)
serverBatch.events.Immediate:Send(1)
serverBatch.events.OutBatch:Send("bad")
serverBatch.events.OutBatch:Send()
serverBatch.events.OutBatch:Put(1, "High", 1)
serverState.events.OutBatch:Put(1, "High", false)
serverState.events.OutState:Send(false)
clientBatch.events.OutBatch:Send(1)
clientBatch.events.InBatch:Send("bad")
clientState.events.InState:Put(1, "Other", "Idle")
clientState.events.OutState:Put(1, "High", "Idle")

server:CreateBatch({ 12 }, 0.02)
server:CreateBatch({ player })
server:CreateBatch({ player }, "soon")
server:CreateState({ player }, 0.02, true)
client:CreateBatch({ player }, 0.02)
client:CreateState("soon")

local invalidQueue = Relay.define({ name = "InvalidQueue", version = 1, events = {
    Bad = {
        id = 1, direction = "ServerToClient" :: "ServerToClient",
        queue = "Latest" :: "Latest", fields = s.ordered(),
    },
} })
print(invalidQueue)
local _, _, report = serverBatch:Flush()
local wrongReport: string = report.logicalHandoffs
print(wrongReport)
