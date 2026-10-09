--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createError and createError.message)

local latestTick = 0
local hasPose = false
local poseConnectionResult, poseError = client.events.Pose:Connect(function(tick, position)
	if hasPose and tick <= latestTick then return end
	latestTick = tick
	hasPose = true
	print("Latest absolute pose", position, "tick", tick)
end)
local poseConnection = assert(poseConnectionResult, poseError and poseError.message)

script.Destroying:Connect(function()
	poseConnection:Disconnect()
	client:Destroy()
end)

local started, startError = client:Start()
assert(started, startError and startError.message)
