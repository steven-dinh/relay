--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = Relay.define({
    name = "RGB8Color3InvalidTypes", version = 1,
    events = {
        Input = s.clientToServer(1, s.ordered(s.field("tint", s.Color3RGB8()))),
        Output = s.serverToClient(2, s.ordered(s.field("tint", s.Color3RGB8()))),
    },
})
local token = assert(definition, "RGB8 Color3 definition")
local extra = Relay.define({
    name = "RGB8Color3InvalidExtra", version = 1,
    events = {
        Extra = s.clientToServer(3, s.ordered(s.field("tint", { type = "Color3RGB8" :: "Color3RGB8", extra = true }))),
    },
})
local clientResult, _problem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, "RGB8 Color3 client")
client.events.Input:Send("not a Color3")
client.events.Output:Send(Color3.new(0.2, 0.4, 0.6))
print(extra)
