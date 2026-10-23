--!strict
local Relay = require("../../src/init")
local definition = require("./ordered-schema")

Relay.createServer(definition, {
    namespace = 1,
    inboundRate = {
        perPlayer = { capacity = 10, refillPerSecond = 1 },
        aggregate = { capacity = 20, refillPerSecond = 2 },
    },
})
Relay.createClient(definition, { namespace = false, startupTimeoutSeconds = 3 })
