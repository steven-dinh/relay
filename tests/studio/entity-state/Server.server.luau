--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage.EntityState.Definition)
local EntityStateServer = require(ReplicatedStorage.EntityState.Server)
local controls = ReplicatedStorage:WaitForChild("EntityStateFixture")

local command = controls:WaitForChild("Command") :: RemoteEvent
local report = controls:WaitForChild("Report") :: RemoteEvent
local snapshotLimit: Relay.EndpointRate = { capacity = 1, refillPerSecond = 0.5 }
local endpointLimits: { [number]: Relay.EndpointRate } = { [2] = snapshotLimit }
local created, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 64, refillPerSecond = 32 },
		endpoints = endpointLimits,
	},
})
local session = assert(created, createError and createError.message)

local function isCurrentPlayer(player: Player): boolean
	return player.Parent == Players and table.find(Players:GetPlayers(), player) ~= nil
end

local state = EntityStateServer.new(isCurrentPlayer, function(player, update)
	local sent, sendError = session.events.Update:Send(player, update)
	assert(sent, sendError and sendError.message)
end)

local deadline = os.clock() + 60
local joinOrder: { Player } = {}
local participants: { Player } = {}
local authorized: Player? = nil
local firstEntityId: number? = nil
local raceSent = false
local activePhase = "ready"
local reports: { [Player]: boolean } = {}
local failures: { [Player]: boolean } = {}
local destroyed = false

local function rememberPlayer(player: Player)
	if not table.find(joinOrder, player) then table.insert(joinOrder, player) end
end

local added = Players.PlayerAdded:Connect(rememberPlayer)
for _, player in Players:GetPlayers() do rememberPlayer(player) end

local reportConnection = report.OnServerEvent:Connect(function(player, phase)
	if not isCurrentPlayer(player) or type(phase) ~= "string" or #phase > 16 then return end
	local selected = table.find(participants, player) ~= nil
	if not selected then
		local joinIndex = table.find(joinOrder, player)
		selected = joinIndex ~= nil and joinIndex <= 2
	end
	if not selected then return end
	if phase == "failure" then
		failures[player] = true
	elseif phase == activePhase then
		reports[player] = true
	end
end)

local snapshotConnection = assert((session.requests.Snapshot:Connect(function(player)
	local response = state:Snapshot(player, os.clock())
	if player == authorized and response.status == "Ready" and not raceSent then
		raceSent = true
		local id = assert(firstEntityId, "missing first entity")
		assert(response.revision == 8, "baseline did not capture all eight targets")
		local changed, changeError = state:SetHealth(id, 777)
		assert(changed, changeError)
	end
	return {
		status = response.status,
		epoch = response.epoch,
		revision = response.revision,
		entities = response.entities,
	}
end)))

local removing = Players.PlayerRemoving:Connect(function(player)
	state:RemovePlayer(player)
	local index = table.find(joinOrder, player)
	if index ~= nil then table.remove(joinOrder, index) end
end)

local function currentPlayersInJoinOrder(): { Player }
	local current = Players:GetPlayers()
	local ordered: { Player } = {}
	for _, player in joinOrder do
		if player.Parent == Players and table.find(current, player) ~= nil then
			table.insert(ordered, player)
		end
	end
	return ordered
end

local function waitForReports(expected: { Player }, phase: string)
	while os.clock() < deadline do
		local complete = true
		for _, player in expected do
			if failures[player] then error("client failed during " .. phase) end
			if not isCurrentPlayer(player) or not reports[player] then complete = false end
		end
		if complete then return end
		task.wait(0.05)
	end
	error("TEST entity-state TIMEOUT: " .. phase)
end

local function commandPhase(phase: string)
	activePhase = phase
	reports = {}
	for _, player in participants do command:FireClient(player, phase) end
	waitForReports(participants, phase)
end

local function cleanup()
	if destroyed then return end
	destroyed = true
	added:Disconnect()
	reportConnection:Disconnect()
	snapshotConnection:Disconnect()
	removing:Disconnect()
	state:Destroy()
	session:Destroy()
	table.clear(participants)
	table.clear(joinOrder)
	table.clear(reports)
	table.clear(failures)
end

script.Destroying:Connect(cleanup)

local function run()
	assert((session:Start()))
	while os.clock() < deadline do
		participants = currentPlayersInJoinOrder()
		if #participants >= 2 then break end
		task.wait(0.05)
	end
	assert(#participants == 2, "start a local server with exactly two players")
	authorized = participants[1]
	waitForReports(participants, "ready")

	for index = 1, 8 do
		local id, failure = state:CreateEntity(index * 10)
		assert(id ~= nil, failure)
		if index == 1 then firstEntityId = id end
	end

	activePhase = "reset"
	reports = {}
	assert(state:SetViewer(authorized, true))
	waitForReports({ authorized }, "reset")

	commandPhase("initial")
	assert(raceSent, "authorized baseline did not trigger the controlled update")

	local id = assert(firstEntityId)
	assert(state:DeleteEntity(id))
	commandPhase("delete")

	assert(state:SetViewer(authorized, false))
	commandPhase("revoke")

	assert(state:SetViewer(authorized, true))
	commandPhase("reentry")

	commandPhase("cleanup")
end

local ok, failure = pcall(run)
cleanup()
if not ok then error(failure, 0) end
print("TEST entity-state PASS (baseline race, outsider denial, delete, revoke, re-entry, cleanup)")
