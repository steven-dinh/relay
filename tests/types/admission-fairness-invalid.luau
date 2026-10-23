--!strict
local Relay = require("../../src/init")
local fairness: Relay.InboundFairness = {
    maxPeers = 2, reserve = { capacity = 1, refillPerSecond = 1 },
}
fairness.maxPeers = "two"
fairness.reserve.capacity = "one"
fairness.reserve.refillPerSecond = "fast"
print(fairness)
