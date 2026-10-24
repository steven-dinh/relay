--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local serverResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 128, refillPerSecond = 64 },
	},
})
local server = assert(serverResult, createError and createError.message)
local started, startError = server:Start()
assert(started, startError and startError.message)

local batcherResult, batcherError = server:CreateBroadcastBatcher(1 / 60)
local batcher = assert(batcherResult, batcherError and batcherError.message)
local elapsed = 0
local round = 0
local observedFlush: { ok: boolean, error: Relay.RelayError?, report: Relay.QueueReport }? = nil
local stopped = false
local heartbeatConnection: RBXScriptConnection? = nil

local function stop(code: string?)
	if stopped then return end
	stopped = true
	if code ~= nil then warn("Shared broadcast stopped", code) end
	if heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	batcher:Cancel()
	server:Destroy()
end

heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
	if stopped then return end
	elapsed += deltaTime
	if elapsed < 1 then return end
	elapsed = 0 -- Publish one fresh sample after a delayed step; never catch up in a loop.

	local lastFlush = batcher:GetStatus().lastFlush
	if lastFlush ~= nil and lastFlush ~= observedFlush then
		observedFlush = lastFlush
		if not lastFlush.ok then
			stop(lastFlush.error and lastFlush.error.code or "TransportFailure")
			return
		end
		print("Previous broadcast local handoffs", lastFlush.report.logicalHandoffs,
			"(handoffs are not delivery receipts)")
	end

	round = round % 100 + 1
	local roundQueued, roundError = batcher.events.Round:Send(round)
	if not roundQueued then
		stop(roundError and roundError.code or "QueueFailure")
		return
	end
	local announcementQueued, announcementError = batcher.events.Announcement:Send(`Round {round} is live`)
	if not announcementQueued then
		stop(announcementError and announcementError.code or "QueueFailure")
	end
end)

script.Destroying:Connect(function()
	stop(nil)
end)
