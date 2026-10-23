--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))
local created, problem = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(created, problem and problem.message)
local listener = assert((client.events.Welcome:Connect(function()
	print("OPERATION listener connected before Start")
end)))
local function stop()
	listener:Disconnect()
	client:Destroy()
end
script.Destroying:Connect(stop)

local ok, failure = pcall(function()
	assert((client:Start()))
	assert((client.events.Ready:Send()))
	-- Keep the original ID and input even when the transport outcome is unknown.
	local operationId, rewardId = 1, 1
	local original = assert((client.requests.Claim:Request(0.1, operationId, rewardId)))
	local concurrent = assert((client.requests.Claim:Request(5, operationId, rewardId))):Await()
	if concurrent.ok then
		assert(concurrent.value.status == "Pending" or concurrent.value.status == "Applied")
		print("OPERATION concurrent duplicate", concurrent.value.status)
	else
		print("OPERATION concurrent outcome unresolved", concurrent.error.code)
	end
	local initial = original:Await()
	if not initial.ok then
		print("OPERATION unknown outcome", initial.error.code, "(no automatic retry)")
	else
		print("OPERATION initial receipt", initial.value.status)
	end

	-- This is one explicit read-only reconciliation, never a replacement Claim.
	task.wait(1.1)
	local reconciled = assert((client.requests.Lookup:Request(5, operationId, rewardId))):Await()
	if not reconciled.ok then
		print("OPERATION reconciliation unresolved", reconciled.error.code)
		return
	end
	local receipt = reconciled.value
	print("OPERATION reconciliation", receipt.status, receipt.coins, receipt.potions)
	if receipt.status == "Denied" then
		print("OPERATION explicitly denied")
		return
	end
	if receipt.status ~= "Applied" then
		print("OPERATION remains unresolved; retain original input for deliberate lookup")
		return
	end
	assert(receipt.coins == 8 and receipt.potions == 1)
	local completed = assert((client.requests.Claim:Request(5, operationId, rewardId))):Await()
	assert(completed.ok and completed.value.status == "Applied"
		and completed.value.coins == 8 and completed.value.potions == 1)
	print("OPERATION completed duplicate: original receipt; potion granted once")
	local conflict = assert((client.requests.Claim:Request(5, operationId, 2))):Await()
	assert(conflict.ok and conflict.value.status == "Conflict")
	local denied = assert((client.requests.Claim:Request(5, 2, 2))):Await()
	assert(denied.ok and denied.value.status == "Denied"
		and denied.value.coins == 8 and denied.value.potions == 1)
	print("OPERATION explicit permission denial; conflicting input rejected")
	print("PASS operation-ID reward shop")
end)
stop()
if not ok then error(failure, 0) end
