--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = assert((Relay.define({
    name = "InboundByteTypes", version = 1,
    events = { Input = s.clientToServer(1, s.ordered()) },
    requests = { Inspect = s.request(2, s.ordered(), s.boolean()) },
})))
local byteRate: Relay.InboundByteRate = {
    perPlayer = { capacity = 4_096, refillPerSecond = 2_048 },
    aggregate = { capacity = 32_768, refillPerSecond = 16_384 },
}
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 },
    aggregate = { capacity = 32, refillPerSecond = 32 },
    bytes = byteRate,
} })))
local configured: Relay.InboundByteRate? = server:GetDiagnostics().inboundRate.bytes
print(configured)
