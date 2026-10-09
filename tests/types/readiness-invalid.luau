--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = assert((Relay.define({ name = "ReadinessInvalidTypes", version = 1, readiness = true, events = {
    Out = s.serverToClient(1, s.ordered(s.field("value", s.u16()))),
    In = s.clientToServer(2, s.ordered(s.field("enabled", s.boolean()))),
} })))
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })))
local client = assert((Relay.createClient(definition, { startupTimeoutSeconds = 3 })))
local player: Player = error("type-only fixture")

client:RefreshReadiness("force")
client:RefreshReadiness(1)
client:RefreshReadiness({})
client:RefreshReadiness(false, true)
server.events.In:GetReadyPlayers()
client.events.Out:GetReadyPlayers()
server.events.Out:SendTo({ 1 }, 3)
server.events.Out:SendTo({ player }, "bad")
server.events.In:SendTo({ player }, true)

Relay.define({ name = "BadReadinessOption", version = 1, readiness = "yes", events = {} })
