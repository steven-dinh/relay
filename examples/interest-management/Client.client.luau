--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createError and createError.message)
local latestTick = 0
local hasScore = false

local noticeResult, noticeError = client.events.Notice:Connect(function(message)
	print("Notice received", message)
end)
local noticeConnection = assert(noticeResult, noticeError and noticeError.message)
local scoreResult, scoreError = client.events.Score:Connect(function(tick, score)
	if hasScore and tick <= latestTick then return end
	hasScore = true
	latestTick = tick
	print("Score snapshot", score, "tick", tick)
end)
local scoreConnection = assert(scoreResult, scoreError and scoreError.message)

local started, startError = client:Start()
if not started then
	noticeConnection:Disconnect()
	scoreConnection:Disconnect()
	client:Destroy()
	error(startError and startError.message or "Relay client startup failed", 0)
end

script.Destroying:Connect(function()
	noticeConnection:Disconnect()
	scoreConnection:Disconnect()
	client:Destroy()
end)
