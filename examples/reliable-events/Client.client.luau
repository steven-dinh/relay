local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Events = require(ReplicatedStorage:WaitForChild("Definition"))

local client = assert(Relay.createClient(Events, { startupTimeoutSeconds = 10 }))
local connection = assert(client.events.State:Connect(function(sequence, health)
	-- Apply server-authored state to your client presentation here.
end))
assert(client:Start())
assert(client.events.Input:Send(1, true))

script.Destroying:Connect(function()
	connection:Disconnect()
	client:Destroy()
end)
