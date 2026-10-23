--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))
local created, problem = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(created, problem and problem.message)
local notices = 0
local listener = assert((client.events.Notice:Connect(function(value)
	assert(value == 7)
	notices += 1
	print("TEST listener: Notice received")
end)))
local cancelBatch: (() -> ())? = nil
local function stop()
	if cancelBatch ~= nil then cancelBatch() end
	listener:Disconnect()
	client:Destroy()
end
script.Destroying:Connect(stop)

local ok, failure = pcall(function()
	assert((client:Start()))
	assert((client.events.Ready:Send()))
	local success = assert((client.requests.Slow:Request(10, 1))):Await()
	if success.ok then
		assert(success.value == 1)
		print("TEST RPC: success")
	else
		print("TEST long RPC:", success.error.code)
	end
	local timeout = assert((client.requests.Slow:Request(0.1, 2))):Await()
	assert(not timeout.ok and timeout.error.code == "RequestTimeout")
	print("TEST timeout: RequestTimeout")
	local cancelled = assert((client.requests.Slow:Request(10, 3)))
	cancelled:Cancel()
	local cancellation = cancelled:Await()
	assert(not cancellation.ok and cancellation.error.code == "Cancelled")
	print("TEST cancel: Cancelled; server work may still execute")

	local queued = assert((client:CreateBatch(0.1)))
	cancelBatch = function() queued:Cancel() end
	for value = 1, 32 do assert((queued.events.Input:Send(value))) end
	local accepted, overflow = queued.events.Input:Send(33)
	assert(not accepted and overflow ~= nil and overflow.code == "QueueFull")
	assert(queued:GetStatus().pendingRecords == 32)
	assert((queued:Flush()))
	print("TEST queue: QueueFull preserved 32 records; flushed")

	local disconnected = assert((client.requests.Slow:Request(10, 4)))
	assert((client.events.Close:Send()))
	local result = disconnected:Await()
	if result.ok then
		print("TEST teardown: reply won race", result.value)
	else
		print("TEST teardown:", result.error.code, "(baseline expects Disconnected)")
	end
	print("TEST listener count", notices, "(baseline expects 1)")
end)
stop()
if not ok then error(failure, 0) end
print("TEST client cleanup complete")
