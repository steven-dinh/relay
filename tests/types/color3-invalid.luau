--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = Relay.define({
    name = "Color3InvalidTypes", version = 1,
    events = { Input = s.clientToServer(1, s.ordered(s.field("tint", s.Color3()))) },
})
local token = assert(definition, "Color3 definition")
local clientResult, _problem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, "Color3 client")
client.events.Input:Send("not a Color3")

local bounded = Relay.define({
    name = "Color3InvalidTypes", version = 1,
    events = { Input = s.clientToServer(2,
        s.ordered({ name = "tint", type = "Color3" :: "Color3", minimum = 0, maximum = 1 })) },
})
local extra = Relay.define({
    name = "Color3InvalidTypes", version = 1,
    events = { Input = s.clientToServer(3,
        s.ordered({ name = "tint", type = "Color3" :: "Color3", extra = true })) },
})
local set = Relay.define({
    name = "Color3InvalidTypes", version = 1,
    events = { Input = s.clientToServer(4, s.ordered(s.field("tints", s.set(s.Color3(), 4)))) },
})
print(bounded, extra, set)
