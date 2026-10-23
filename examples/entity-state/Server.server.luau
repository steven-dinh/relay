--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))
local EntityServer = require(ReplicatedStorage:WaitForChild("EntityServer"))

local snapshotRate: Relay.EndpointRate = { capacity = 1, refillPerSecond = 0.5 }
local snapshotEndpoints: { [number]: Relay.EndpointRate } = { [2] = snapshotRate }
local serverResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 64, refillPerSecond = 32 },
		endpoints = snapshotEndpoints,
	},
})
local server = assert(serverResult, createError and createError.message)

local function isCurrentPlayer(player: Player): boolean
	if player.Parent ~= Players then return false end
	for _, current in Players:GetPlayers() do
		if current == player then return true end
	end
	return false
end

local entityState = EntityServer.new(isCurrentPlayer, function(player: Player, update)
	server.events.Update:Send(player, update)
end)

local targetIds: { number } = {}
for index = 1, 8 do
	local id, problem = entityState:CreateEntity(1_000 - index * 25)
	if id == nil then
		entityState:Destroy()
		error(problem or "Target creation failed", 0)
	end
	table.insert(targetIds, id)
end

local snapshotResult, snapshotError = server.requests.Snapshot:Connect(function(player)
	local snapshot = entityState:Snapshot(player, os.clock())
	return {
		status = snapshot.status,
		epoch = snapshot.epoch,
		revision = snapshot.revision,
		entities = snapshot.entities,
	}
end)
local snapshotConnection = assert(snapshotResult, snapshotError and snapshotError.message)

local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local stopped = false
local elapsed = 0
local updateCount = 0
local reentryPlayer: Player? = nil

local function stop(problem: string?)
	if stopped then return end
	stopped = true
	if problem ~= nil then warn("Entity state example stopped", problem) end
	if playerAddedConnection ~= nil then playerAddedConnection:Disconnect(); playerAddedConnection = nil end
	if playerRemovingConnection ~= nil then playerRemovingConnection:Disconnect(); playerRemovingConnection = nil end
	if heartbeatConnection ~= nil then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
	snapshotConnection:Disconnect()
	entityState:Destroy()
	server:Destroy()
end

local function reconcileAudience(excluded: Player?)
	if stopped then return end
	local activeIndex = 0
	for _, player in Players:GetPlayers() do
		if player ~= excluded then
			activeIndex += 1
			local allowed, problem = entityState:SetViewer(player, activeIndex == 1)
			if not allowed then stop(problem); return end
		end
	end
end

playerAddedConnection = Players.PlayerAdded:Connect(function()
	reconcileAudience(nil)
end)
playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
	entityState:RemovePlayer(player)
	if reentryPlayer == player then reentryPlayer = nil end
	reconcileAudience(player)
end)

local started, startError = server:Start()
if not started then stop(startError and startError.code); error(startError and startError.message or "Relay server startup failed", 0) end
reconcileAudience()

heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
	if stopped then return end
	elapsed += deltaTime
	if elapsed < 1 then return end
	elapsed = 0
	updateCount += 1

	if updateCount == 8 then
		for index, player in Players:GetPlayers() do
			if index == 1 then
				local revoked, problem = entityState:SetViewer(player, false)
				if not revoked then stop(problem); return end
				reentryPlayer = player
				break
			end
		end
	elseif updateCount == 10 then
		local player = reentryPlayer
		reentryPlayer = nil
		if player ~= nil and isCurrentPlayer(player) then
			local reentered, problem = entityState:SetViewer(player, true)
			if not reentered then stop(problem); return end
		end
	end

	if updateCount == 12 then
		local deleted, problem = entityState:DeleteEntity(targetIds[3])
		if not deleted then stop(problem); return end
		table.remove(targetIds, 3)
		return
	end

	local id = targetIds[(updateCount - 1) % #targetIds + 1]
	local health = 1_000 - (updateCount * 37) % 701
	local updated, problem = entityState:SetHealth(id, health)
	if not updated then stop(problem); return end
end)

script.Destroying:Connect(function()
	stop(nil)
end)
