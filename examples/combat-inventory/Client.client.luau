--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createError and createError.message)

local updateConnectionResult, updateError = client.events.InventoryUpdate:Connect(function(itemId, count)
	print("Inventory update", itemId, count)
end)
local updateConnection = assert(updateConnectionResult, updateError and updateError.message)

script.Destroying:Connect(function()
	updateConnection:Disconnect()
	client:Destroy()
end)

local started, startError = client:Start()
assert(started, startError and startError.message)

local attackSent, attackError = client.events.Attack:Send(1, 42)
assert(attackSent, attackError and attackError.message)

local pendingResult, requestError = client.requests.Inspect:Request(5, 42)
local pending = assert(pendingResult, requestError and requestError.message)
local result = pending:Await()
if result.ok then
	local owned: boolean = result.value.owned
	local count: number = result.value.count
	print("Inspection", owned, count)
else
	print("Inspection failed", result.error.code)
end
