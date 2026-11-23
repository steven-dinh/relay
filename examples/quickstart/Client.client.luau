--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createClientError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createClientError and createClientError.message)

local started, startError = client:Start()
if not started then
	client:Destroy()
	error(startError and startError.message or "Relay client startup failed", 0)
end

local sent, sendError = client.events.Ping:Send(1)
assert(sent, sendError and sendError.message)
