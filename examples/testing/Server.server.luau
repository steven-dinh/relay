--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Relay = require(ReplicatedStorage.Relay)
local Definition = require(ReplicatedStorage.Definition)

local created, problem = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 256, refillPerSecond = 128 },
		aggregate = { capacity = 1024, refillPerSecond = 512 },
	},
})
local server = assert(created, problem and problem.message)
local counts: { [Player]: number } = {}
local removing = Players.PlayerRemoving:Connect(function(player)
	counts[player] = nil
end)

local function stop()
	server:Destroy()
	removing:Disconnect()
	table.clear(counts)
end
script.Destroying:Connect(stop)

assert((server.events.Ready:Connect(function(player)
	assert((server.events.Notice:Send(player, 7)))
end)))
assert((server.events.Input:Connect(function(player, value)
	local count = (counts[player] or 0) + 1
	assert(value == count, "reliable FIFO order changed")
	counts[player] = count
	if count == 32 then print("TEST queue: received 32 values in order") end
end)))
assert((server.requests.Slow:Connect(function(player, value)
	print("TEST request observed", player.Name, value)
	task.wait(1)
	-- Caller timeout/cancellation does not stop this application work.
	print("TEST request completed", value)
	return value
end)))
assert((server.events.Close:Connect(function()
	print("TEST server teardown")
	stop()
end)))

assert((server:Start()))
