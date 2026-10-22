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
    Ordered = {
        id = 6, direction = "ServerToClient" :: "ServerToClient",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        fields = s.ordered(s.field("value", s.u16())),
    },
}, requests = {
    Method = s.request(7, s.ordered(s.field("value", s.u16())), s.boolean()),
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

local serverBatcher = assert((server:CreateBatcher({ player }, 0.02)))
local clientBatcher = assert((client:CreateBatcher(0.02)))
clientBatcher.events.InBatch:Send(1)
serverBatcher.events.InBatch:Send(1)
serverBatcher.events.OutBatch:Send("bad")
server:CreateBatcher({ 12 }, 0.02)
client:CreateBatcher("soon")

local serverBroadcastBatcher = assert((server:CreateBroadcastBatcher(0.05)))
serverBroadcastBatcher.events.OutBatch:Send("bad")
serverBroadcastBatcher.events.OutBatch:Send()
serverBroadcastBatcher.events.InBatch:Send(1)
serverBroadcastBatcher.events.Immediate:Send(1)
serverBroadcastBatcher.events.Ordered:Send(1)
serverBroadcastBatcher.events.Method:Send(1)
server:CreateBroadcastBatcher("soon")
server:CreateBroadcastBatcher({ player }, 0.05)
client:CreateBroadcastBatcher(0.05)

local serverBroadcastState = assert((server:CreateBroadcastState(0.05)))
serverBroadcastState.events.OutState:Put(1, "High", true)
serverBroadcastState.events.OutState:Put(1, "High", "bad")
serverBroadcastState.events.OutState:Send(true)
serverBroadcastState.events.InBatch:Put(1, "High", 1)
serverBroadcastState.events.InState:Put(1, "Normal", "Idle")
serverBroadcastState.events.OutBatch:Put(1, "High", 1)
serverBroadcastState.events.Immediate:Put(1, "High", 1)
serverBroadcastState.events.Ordered:Put(1, "High", 1)
serverBroadcastState.events.Method:Put(1, "High", 1)
server:CreateBroadcastState("soon")
server:CreateBroadcastState()
server:CreateBroadcastState(0.05, { deferOutbound = true })
server:CreateBroadcastState(0.05, { player })
client:CreateBroadcastState(0.05)

server:CreatePacedBatcher(0.02)
local paced = assert((client:CreatePacedBatcher(0.02)))
paced.events.OutBatch:Send(1)
paced.events.Immediate:Send(1)
paced.events.Ordered:Send(1)
paced.events.Method:Send(1)
paced.events.InBatch:Send("bad")
paced.events.InBatch:Send()
client:CreatePacedBatcher("soon")
client:CreatePacedBatcher(0.02, { manual = "yes" })
