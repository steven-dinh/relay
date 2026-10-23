--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Relay = require(ReplicatedStorage.Relay)
local Definition = require(ReplicatedStorage.Definition)
local Rewards = require(script.Parent.Rewards)

local created, problem = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 128, refillPerSecond = 64 },
	},
})
local server = assert(created, problem and problem.message)
local rewards = Rewards.new(os.clock, function()
	-- Deliberate preparation delay makes concurrent calls and a caller timeout visible.
	task.wait(1)
end)
local function addPlayer(player: Player)
	if not rewards:AddPlayer(player) then warn("Reward shop account capacity", player.Name) end
end
local added = Players.PlayerAdded:Connect(addPlayer)
local removing = Players.PlayerRemoving:Connect(function(player)
	rewards:RemovePlayer(player)
end)
for _, player in Players:GetPlayers() do addPlayer(player) end

assert((server.events.Ready:Connect(function(player)
	assert((server.events.Welcome:Send(player)))
end)))
assert((server.requests.Claim:Connect(function(player, operationId, rewardId)
	return rewards:Claim(player, operationId, rewardId)
end)))
assert((server.requests.Lookup:Connect(function(player, operationId, rewardId)
	return rewards:Lookup(player, operationId, rewardId)
end)))
local function stop()
	added:Disconnect()
	removing:Disconnect()
	rewards:Destroy()
	server:Destroy()
end
script.Destroying:Connect(stop)
local started, startProblem = server:Start()
if not started then
	stop()
	error(startProblem and startProblem.message or "Reward shop startup failed", 0)
end
