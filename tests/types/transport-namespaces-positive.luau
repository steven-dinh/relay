--!strict
local Relay = require("../../src/init")
local definition = require("./ordered-schema")

local serverOptions: Relay.ServerOptions = {
    namespace = "library_v1",
    inboundRate = {
        perPlayer = { capacity = 10, refillPerSecond = 1 },
        aggregate = { capacity = 20, refillPerSecond = 2 },
    },
}
local clientOptions: Relay.ClientOptions = { namespace = "library_v1", startupTimeoutSeconds = 3 }
Relay.createServer(definition, serverOptions)
Relay.createClient(definition, clientOptions)
