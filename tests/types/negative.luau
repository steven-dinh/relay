--!strict
local Relay = require("../../src/init")
local definition = require("./ordered-schema")
local server, serverError = Relay.createServer(definition, {
    inboundRate = {
        perPlayer = { capacity = 10, refillPerSecond = 1 },
        aggregate = { capacity = 100, refillPerSecond = 10 },
    },
})
local client, clientError = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
if not server then error(if serverError then serverError.message else "server failed") end
if not client then error(if clientError then clientError.message else "client failed") end
local player: Player = error("type-only fixture")

client.events.Unknown:Send(1)
client.events.State:Send(1)
server.events.Input:Send(player, 1, true)
server.events.State:Connect(function() end)
client.events.Input:Connect(function() end)
client.events.Input:Send("wrong", true, "a", -1, 0.5, Vector2.new(), Vector3.new(), CFrame.new())
client.events.Input:Send(true, 1, "a", -1, 0.5, Vector2.new(), Vector3.new(), CFrame.new())
client.events.Input:Send(1, true, "a", -1, 0.5, Vector2.new(), Vector3.new())
client.events.Input:Send(1, true, "a", -1, 0.5, Vector2.new(), Vector3.new(), CFrame.new(), 9)
server.events.State:Send(1, 2, -3, -4, 5)
server.events.State:Send(player, 1, 2, -3, -4, 5)
server.events.Empty:Broadcast(1)
server.events.Input:Connect(function(sender: Player, sequence: string) end)
client.events.Empty:Connect(function(value: number) end)
server.events.Unknown:Send(1)
client.events.State:SendTo({}, 1, 2, -3, -4)
server.events.Input:SendExcept({}, 1, true)
server.events.State:SendTo({ 1 }, 1, 2, -3, -4)
server.events.State:SendExcept({}, "wrong", 2, -3, -4)
server.events.State:SendTo({}, 1, 2, -3)
server.events.Empty:SendExcept({}, 1)
