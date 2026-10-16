--!strict
local Relay = require("../../src/init")
local definition = assert((Relay.define({
    name = "BadInboundByteTypes", version = 1,
    events = { Input = Relay.schema.clientToServer(1, Relay.schema.ordered()) },
})))
local policy: Relay.InboundByteRate = {
    perPlayer = { capacity = 4, refillPerSecond = 4 },
    aggregate = { capacity = 8, refillPerSecond = 8 },
}
policy.perPlayer.capacity = "four"
policy.aggregate.refillPerSecond = "fast"
local server = Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 },
    aggregate = { capacity = 32, refillPerSecond = 32 },
    bytes = policy,
} })
print(server)
