--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Definition = require(ReplicatedStorage.Definition)

local serverResult, createServerError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 120, refillPerSecond = 60 },
		aggregate = { capacity = 960, refillPerSecond = 480 },
	},
})
local server = assert(serverResult, createServerError and createServerError.message)

local connectionResult, connectError = server.events.Ping:Connect(function(player, sequence)
	print(string.format("Received Ping %d from %s", sequence, player.Name))
end)
assert(connectionResult, connectError and connectError.message)
local started, startError = server:Start()
assert(started, startError and startError.message)
