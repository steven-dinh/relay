--!strict
local Relay = require("../../src/init")
local definition = assert((Relay.define({
    name = "FairnessTypes", version = 1,
    events = { Input = Relay.schema.clientToServer(1, Relay.schema.ordered()) },
})))
local fairness: Relay.InboundFairness = {
    maxPeers = 2, reserve = { capacity = 1, refillPerSecond = 1 },
}
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 4, refillPerSecond = 4 },
    aggregate = { capacity = 4, refillPerSecond = 4 },
    fairness = fairness,
} })))
local configured: Relay.InboundFairness? = server:GetDiagnostics().inboundRate.fairness
print(configured)
