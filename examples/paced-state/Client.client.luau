--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local clientResult, createError = Relay.createClient(Definition, {
	startupTimeoutSeconds = 10,
	diagnostics = { traffic = true, reports = true },
})
local client = assert(clientResult, createError and createError.message)

type InputPacedEvent = {
	Send: (self: InputPacedEvent, value: number) -> (boolean, Relay.RelayError?),
}
type InputPacer = Relay.PacedBatcherHandle<{ Input: InputPacedEvent }>

local stopped = false
local value = 0
local sampleElapsed = 0
local reportElapsed = 0
local snapshotConnection: Relay.Connection? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local destroyingConnection: RBXScriptConnection? = nil
local pacer: InputPacer? = nil

local function disconnect(connection: RBXScriptConnection?)
	if connection ~= nil then connection:Disconnect() end
end

local function stop(code: string?)
	if stopped then return end
	stopped = true
	if code ~= nil then warn("Paced client stopped", code) end
	disconnect(heartbeatConnection)
	disconnect(destroyingConnection)
	if snapshotConnection ~= nil then snapshotConnection:Disconnect() end
	local activePacer = pacer
	if activePacer ~= nil then activePacer:Destroy(); pacer = nil end
	client:Destroy()
end

local snapshotResult, snapshotError = client.events.Snapshot:Connect(function(snapshotValue, observedAt)
	print("Public snapshot", snapshotValue, "observed at", observedAt)
end)
snapshotConnection = assert(snapshotResult, snapshotError and snapshotError.message)

local started, startError = client:Start()
if not started then
	stop(startError and startError.code or "StartFailed")
	return
end

local pacerResult, pacerError = client:CreatePacedBatcher(1 / 30, { manual = true })
if pacerResult == nil then
	stop(pacerError and pacerError.code or "PacerCreationFailed")
	return
end
pacer = pacerResult

heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
	if stopped then return end
	local activePacer = pacer
	if activePacer == nil then
		stop("PacerUnavailable")
		return
	end
	sampleElapsed += deltaTime
	if sampleElapsed >= 1 then
		sampleElapsed = 0 -- One current sample after a delayed step; no catch-up burst.
		value = (value + 1) % 101
		local queued, queueError = activePacer.events.Input:Send(value)
		if not queued and (queueError == nil or queueError.code ~= "QueueFull") then
			stop(queueError and queueError.code or "InputQueueFailed")
			return
		end
	end

	local stepped, stepError = activePacer:Step()
	if not stepped and activePacer:GetStatus().state == "Terminal" then
		stop(stepError and stepError.code or "PacerFailed")
		return
	end

	reportElapsed += deltaTime
	if reportElapsed < 10 then return end
	reportElapsed = 0
	local diagnostics = client:GetDiagnostics()
	local traffic = diagnostics.traffic
	local reports = diagnostics.reports
	if traffic ~= nil and reports ~= nil then
		local reliable = traffic.channels.Reliable
		local firstReport = reports.entries[1]
		print("Relay content units", reliable.sentBytes, "bounded reports", reports.total,
			reports.capacity, firstReport and firstReport.reason or "none",
			firstReport and firstReport.count or 0,
			"(not Roblox wire bytes or delivery receipts)")
	end
end)

destroyingConnection = script.Destroying:Connect(function()
	stop(nil)
end)
