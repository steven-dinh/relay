--!strict
local Relay = require("../../src/init")
local definition = assert((Relay.define({
    name = "BadEndpointRateTypes", version = 1,
    events = { Input = Relay.schema.clientToServer(1, Relay.schema.ordered()) },
})))
local server = Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 },
    aggregate = { capacity = 32, refillPerSecond = 32 },
    endpoints = {
        ["1"] = { capacity = 4, refillPerSecond = 2 },
        [1] = { capacity = "four", refillPerSecond = 2 },
    },
} })
print(server)
