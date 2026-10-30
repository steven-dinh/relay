--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local serverResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 128, refillPerSecond = 64 },
	},
	diagnostics = { traffic = true, reports = true },
})
local server = assert(serverResult, createError and createError.message)

type SnapshotStateEvent = {
	Put: (self: SnapshotStateEvent, key: number, priority: "High" | "Normal" | "Low",
		value: number, observedAt: number) -> (boolean, Relay.RelayError?),
}
type SnapshotLane = Relay.StateHandle<{ Snapshot: SnapshotStateEvent }>

local stopped = false
local started = false
local warnedForAudience = false
local transportFailureBaseline = 0
local stateLane: SnapshotLane? = nil
local inputConnection: Relay.Connection? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local destroyingConnection: RBXScriptConnection? = nil
local reportElapsed = 0
local observedFlush: { ok: boolean, error: Relay.RelayError?, report: Relay.QueueReport }? = nil

local function disconnect(connection: RBXScriptConnection?)
	if connection ~= nil then connection:Disconnect() end
end

local function stop(code: string?)
	if stopped then return end
	stopped = true
	if code ~= nil then warn("Paced state stopped", code) end
	disconnect(heartbeatConnection)
	disconnect(playerAddedConnection)
	disconnect(playerRemovingConnection)
	disconnect(destroyingConnection)
	if inputConnection ~= nil then inputConnection:Disconnect() end
	if stateLane ~= nil then stateLane:Destroy(); stateLane = nil end
	observedFlush = nil
	server:Destroy()
end

local function replaceAudience(excluded: Player?)
	if stopped or not started then return end
	if stateLane ~= nil then stateLane:Destroy(); stateLane = nil end
	observedFlush = nil
	local audience: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player ~= excluded then table.insert(audience, player) end
	end
	if #audience > 64 then
		if not warnedForAudience then
			warn("Paced state paused: its fixed audience is limited to 64 players")
			warnedForAudience = true
		end
		return
	end
	warnedForAudience = false
	if #audience == 0 then return end
	local stateResult, stateError = server:CreateState(audience, 0.05, {
		deferOutbound = true,
		progress = "Independent",
	})
	if stateResult == nil then
		stop(stateError and stateError.code or "StateCreationFailed")
		return
	end
	stateLane = stateResult
end

local inputResult, inputError = server.events.Input:Connect(function(_player, serverTime, value)
	if stopped then return end
	local lane = stateLane
	if lane == nil then return end
	-- Any connected Player may submit this bounded public demo sample; it is not
	-- gameplay state. The timestamp is an untrusted freshness hint checked by Relay.
	local queued, queueError = lane.events.Snapshot:Put(1, "Normal", value, serverTime)
	if not queued and (queueError == nil or queueError.code ~= "QueueFull") then
		stop(queueError and queueError.code or "StateQueueFailed")
	end
end)
inputConnection = assert(inputResult, inputError and inputError.message)

playerAddedConnection = Players.PlayerAdded:Connect(function()
	replaceAudience(nil)
end)
playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
	replaceAudience(player)
end)

local startedOk, startError = server:Start()
if not startedOk then
	stop(startError and startError.code or "StartFailed")
	return
end
started = true
transportFailureBaseline = server:GetDiagnostics().counters.transportFailures
replaceAudience(nil)
if stopped then return end

heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
	if stopped then return end
	local diagnostics = server:GetDiagnostics()
	if diagnostics.state == "Destroyed" then
		stop(if diagnostics.counters.transportLosses > 0 then "TransportLoss" else "SessionDestroyed")
		return
	end
	-- Read the monotonic session counter before lane status: an independent
	-- recipient failure can be followed by a successful service before Heartbeat.
	if diagnostics.counters.transportFailures > transportFailureBaseline then
		stop("TransportFailure")
		return
	end
	local lane = stateLane
	if lane ~= nil then
		local lastFlush = lane:GetStatus().lastFlush
		if lastFlush ~= nil and lastFlush ~= observedFlush then
			observedFlush = lastFlush
			if not lastFlush.ok then
				local code = lastFlush.error and lastFlush.error.code
				if code ~= "OutboundRateLimited" and code ~= "QueueBusy" then
					stop(code or "StateHandoffFailed")
					return
				end
			else
				print("State local handoffs", lastFlush.report.logicalHandoffs,
					"(handoffs are not delivery receipts)")
			end
		end
	end

	reportElapsed += deltaTime
	if reportElapsed < 10 then return end
	reportElapsed = 0
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
