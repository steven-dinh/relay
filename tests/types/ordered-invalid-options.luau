--!strict
local Relay = require("../../src/init")
local definition = require("./ordered-schema")

Relay.createServer(definition, {
    inboundRate = {
        perPlayer = { capacity = "bad", refillPerSecond = 1 },
        aggregate = { capacity = 100, refillPerSecond = 10 },
    },
})
Relay.createClient(definition, { startupTimeoutSeconds = "bad" })
