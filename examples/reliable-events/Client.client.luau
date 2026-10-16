--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Events = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createClientError = Relay.createClient(Events, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createClientError and createClientError.message)
local connectionResult, connectError = client.events.State:Connect(function(sequence, health)
	-- Apply server-authored state to your client presentation here.
end)
local connection = assert(connectionResult, connectError and connectError.message)

script.Destroying:Connect(function()
	connection:Disconnect()
	client:Destroy()
end)

local started, startError = client:Start()
if not started then
	connection:Disconnect()
	client:Destroy()
	if startError and startError.code == "DefinitionMismatch" then
		warn("Relay definitions differ; reconnect with matching server and client game builds")
		return
	end
	error(startError and startError.message or "Relay client startup failed", 0)
end
local sent, sendError = client.events.Input:Send(1, true)
assert(sent, sendError and sendError.message)
