--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Events = require(ReplicatedStorage.Definition)

local serverResult, createServerError = Relay.createServer(Events, {
	inboundRate = {
		perPlayer = { capacity = 120, refillPerSecond = 60 },
		aggregate = { capacity = 960, refillPerSecond = 480 },
	},
})
local server = assert(serverResult, createServerError and createServerError.message)

local connectionResult, connectError = server.events.Input:Connect(function(player, sequence, enabled)
	-- Validate permissions, cooldowns and authoritative game state here.
	-- A structurally valid input does not authorize a gameplay effect.
end)
local connection = assert(connectionResult, connectError and connectError.message)
local started, startError = server:Start()
assert(started, startError and startError.message)

-- Once your application has established client startup:
-- local sent, sendError = server.events.State:Send(player, sequence, health)
-- assert(sent, sendError and sendError.message)
-- local broadcast, broadcastError = server.events.State:Broadcast(sequence, health)
-- assert(broadcast, broadcastError and broadcastError.message)

script.Destroying:Connect(function()
	connection:Disconnect()
	server:Destroy()
end)
