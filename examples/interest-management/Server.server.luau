--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))
local GroupsModule = require(ReplicatedStorage:WaitForChild("Groups"))

type GroupManager = GroupsModule.GroupManager

type ScoreEvent = {
	Put: (self: ScoreEvent, key: number, priority: "High" | "Normal" | "Low", tick: number, score: number) -> (boolean, Relay.RelayError?),
}
type ScoreState = Relay.StateHandle<{ Score: ScoreEvent }>

local serverResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 128, refillPerSecond = 64 },
	},
})
local server = assert(serverResult, createError and createError.message)
local started, startError = server:Start()
if not started then
	server:Destroy()
	error(startError and startError.message or "Relay server startup failed", 0)
end

local groupManager: GroupManager? = nil
local scoreState: ScoreState? = nil
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local stopped = false
local elapsed = 0
local tick = 0
local score = 0

local function destroyScoreState()
	local state = scoreState
	scoreState = nil
	if state ~= nil then state:Destroy() end
end

local function stop(code: string?)
	if stopped then return end
	stopped = true
	if code ~= nil then warn("Interest management stopped", code) end
	if heartbeatConnection ~= nil then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
	if playerAddedConnection ~= nil then playerAddedConnection:Disconnect(); playerAddedConnection = nil end
	if playerRemovingConnection ~= nil then playerRemovingConnection:Disconnect(); playerRemovingConnection = nil end
	destroyScoreState()
	if groupManager ~= nil then groupManager:Destroy(); groupManager = nil end
	server:Destroy()
end

local function nextTick(): boolean
	if tick >= 4_294_967_295 then return false end
	tick += 1
	return true
end

local function rebuildAudiences(leaving: Player?)
	-- State lanes capture recipients, so discard the old lane before changing groups.
	destroyScoreState()
	local manager = groupManager
	if manager == nil then stop("Destroyed"); return end

	local roster: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player ~= leaving then table.insert(roster, player) end
	end
	if #roster > 64 then stop("PlayerLimit"); return end

	local arena: { Player } = {}
	local lobby: { Player } = {}
	local red: { Player } = {}
	local spectators: { Player } = {}
	local activeIndex = 0
	for index, player in roster do
		if index % 4 == 0 then
			table.insert(spectators, player)
		else
			activeIndex += 1
			if index % 3 == 1 then table.insert(arena, player) else table.insert(lobby, player) end
			if activeIndex % 2 == 1 then table.insert(red, player) end
		end
	end

	local function setGroup(name: string, audience: { Player }): boolean
		local ok, problem = manager:Set(name, audience)
		if not ok then stop(problem or "InvalidAudience"); return false end
		return true
	end
	if not setGroup("room:arena", arena)
		or not setGroup("room:lobby", lobby)
		or not setGroup("team:red", red)
		or not setGroup("spectators", spectators) then return end

	local currentSpectators, problem = manager:Members("spectators")
	if currentSpectators == nil then stop(problem or "MissingGroup"); return end
	if #currentSpectators > 0 then
		local stateResult, stateError = server:CreateState(currentSpectators, 0.02)
		if stateResult == nil then stop(stateError and stateError.code or "StateCreateFailure"); return end
		scoreState = stateResult
		if not nextTick() then stop("TickLimit"); return end
		local queued, queueError = stateResult.events.Score:Put(1, "Normal", tick, score)
		if not queued then stop(queueError and queueError.code or "QueueFailure"); return end
	end

	print("Audience rebuilt", "room:arena", #arena, "room:lobby", #lobby,
		"team:red", #red, "spectators", #spectators)
end

local function sendToGroup(name: string, label: string, message: string): boolean
	local manager = groupManager
	if manager == nil then stop("Destroyed"); return false end
	local audience, problem = manager:Members(name)
	if audience == nil then stop(problem or "MissingGroup"); return false end
	if #audience == 0 then return true end
	local sent, sendError = server.events.Notice:SendTo(audience, message)
	if not sent then stop(sendError and sendError.code or "SendFailure"); return false end
	print(label, name, message)
	return true
end

local function publish()
	local state = scoreState
	if state ~= nil then
		local lastFlush = state:GetStatus().lastFlush
		if lastFlush ~= nil and not lastFlush.ok then
			stop(lastFlush.error and lastFlush.error.code or "StateFlushFailure")
			return
		end
		if not nextTick() then stop("TickLimit"); return end
		score = (score + 1) % 65_536
		local queued, queueError = state.events.Score:Put(1, "Normal", tick, score)
		if not queued then stop(queueError and queueError.code or "QueueFailure"); return end
	end

	if not sendToGroup("room:arena", "Private room notice", `Arena score {score}`) then return end
	if not sendToGroup("room:lobby", "Private room notice", `Lobby score {score}`) then return end
	if not sendToGroup("team:red", "Private team notice", `Red team score {score}`) then return end

	local manager = groupManager
	if manager == nil then stop("Destroyed"); return end
	local spectators, problem = manager:Members("spectators")
	if spectators == nil then stop(problem or "MissingGroup"); return end
	local sent, sendError = server.events.Notice:SendExcept(spectators, `Active players score {score}`)
	if not sent then stop(sendError and sendError.code or "SendFailure"); return end
	print("Public active-player notice", `Active players score {score}`)
end

groupManager = GroupsModule.new(Players)
playerAddedConnection = Players.PlayerAdded:Connect(function()
	if stopped then return end
	local ok = pcall(rebuildAudiences, nil)
	if not ok then stop("RebuildFailure") end
end)
playerRemovingConnection = Players.PlayerRemoving:Connect(function(leaving)
	if stopped then return end
	local ok = pcall(rebuildAudiences, leaving)
	if not ok then stop("RebuildFailure") end
end)

local initialOk = pcall(rebuildAudiences, nil)
if not initialOk then stop("RebuildFailure") end
if not stopped then
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if stopped then return end
		elapsed += deltaTime
		if elapsed < 1 then return end
		elapsed = 0 -- One fresh sample after a delayed step; never catch up in a loop.
		local ok = pcall(publish)
		if not ok then stop("PublishFailure") end
	end)
end

script.Destroying:Connect(function()
	stop(nil)
end)
