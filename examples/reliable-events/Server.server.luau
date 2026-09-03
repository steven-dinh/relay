local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Events = require(ReplicatedStorage.Definition)

local server = assert(Relay.createServer(Events, {
	inboundRate = {
		perPlayer = { capacity = 120, refillPerSecond = 60 },
		aggregate = { capacity = 960, refillPerSecond = 480 },
	},
}))

local connection = assert(server.events.Input:Connect(function(player, sequence, enabled)
	-- Validate permissions, cooldowns and authoritative game state here.
	-- A structurally valid input does not authorize a gameplay effect.
end))
assert(server:Start())

-- Once your application has established client startup:
-- assert(server.events.State:Send(player, sequence, health))
-- assert(server.events.State:Broadcast(sequence, health))

script.Destroying:Connect(function()
	connection:Disconnect()
	server:Destroy()
end)
