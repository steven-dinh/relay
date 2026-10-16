--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition = assert((Relay.define({ name = "OrderedTypes", version = 1, events = {
    Input = {
        id = 1, direction = "ClientToServer" :: "ClientToServer",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        fields = s.ordered(s.field("sequence", s.u32())),
    },
    Output = {
        id = 2, direction = "ServerToClient" :: "ServerToClient",
        delivery = "OrderedUnreliable" :: "OrderedUnreliable",
        fields = s.ordered(s.field("enabled", s.boolean())),
    },
    HelperInput = s.clientToServer(3, s.ordered(s.field("value", s.u16())), "OrderedUnreliable"),
    HelperOutput = s.serverToClient(4, s.ordered(s.field("enabled", s.boolean())), "OrderedUnreliable"),
} })))
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 10, refillPerSecond = 1 },
    aggregate = { capacity = 20, refillPerSecond = 2 },
} })))
local client = assert((Relay.createClient(definition, { startupTimeoutSeconds = 10 })))
local player: Player = error("type-only fixture")

local input = assert((server.events.Input:Once(function(sender, sequence)
    local userId: number = sender.UserId
    local value: number = sequence
    print(userId, value)
end)))
local output = assert((client.events.Output:Once(function(enabled)
    local value: boolean = enabled
    print(value)
end)))
local sent: boolean, sendError: Relay.RelayError? = client.events.Input:Send(7)
local targeted: boolean, targetError: Relay.RelayError? = server.events.Output:Send(player, true)
local broadcast: boolean, broadcastError: Relay.RelayError? = server.events.Output:Broadcast(false)
local audience: boolean, audienceError: Relay.RelayError?, count: number = server.events.Output:SendTo({ player }, true)
local inspection = assert((Relay.inspect(definition)))
local delivery: "Reliable" | "Unreliable" | "OrderedUnreliable" = inspection.events.Output.delivery
local helperSend: boolean, helperSendError: Relay.RelayError? = client.events.HelperInput:Send(8)
local helperBroadcast: boolean, helperBroadcastError: Relay.RelayError? = server.events.HelperOutput:Broadcast(true)
print(input, output, sent, sendError, targeted, targetError, broadcast, broadcastError,
    audience, audienceError, count, delivery, helperSend, helperSendError, helperBroadcast, helperBroadcastError)
