--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = assert((Relay.define({
    name = "EndpointRateTypes", version = 1,
    events = {
        Input = Relay.schema.clientToServer(1, Relay.schema.ordered()),
        State = Relay.schema.serverToClient(2, Relay.schema.ordered()),
    },
    requests = { Inspect = s.request(3, s.ordered(), s.boolean()) },
})))
local eventLimit: Relay.EndpointRate = { capacity = 4, refillPerSecond = 2 }
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 },
    aggregate = { capacity = 32, refillPerSecond = 32 },
    endpoints = {
        [1] = eventLimit,
        [3] = { capacity = 2, refillPerSecond = 1 },
    },
} })))
local endpoints = server:GetDiagnostics().inboundRate.endpoints
if endpoints ~= nil then
    local rate: number = endpoints[3].refillPerSecond
    print(rate)
end
