--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createError and createError.message)

local roundResult, roundError = client.events.Round:Connect(function(round)
	print("Public round", round)
end)
local roundConnection = assert(roundResult, roundError and roundError.message)
local announcementResult, announcementError = client.events.Announcement:Connect(function(message)
	print("Public announcement", message)
end)
local announcementConnection = assert(announcementResult, announcementError and announcementError.message)

script.Destroying:Connect(function()
	roundConnection:Disconnect()
	announcementConnection:Disconnect()
	client:Destroy()
end)

local started, startError = client:Start()
if not started then
	roundConnection:Disconnect()
	announcementConnection:Disconnect()
	client:Destroy()
	error(startError and startError.message or "Relay client startup failed", 0)
end
