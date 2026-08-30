--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")

local root = ReplicatedStorage:WaitForChild("RelayBenchmark")
local runner = root:WaitForChild("Runner")
local StudioProofReports = require(runner:WaitForChild("StudioProofReports"))

local CASE_ID = "state-broadcast-s2c"
local MAX_WAIT_SECONDS = 120

local terminal = false
local caseFolder: Folder? = nil
local coordinator: any = nil
local connections: { RBXScriptConnection } = {}
local postQuiet = false
local measuredQuiet = false

local function cleanup(): boolean
	local clean = true
	for _, connection in connections do
		if not pcall(function() connection:Disconnect() end) then clean = false end
	end
	table.clear(connections)
	if coordinator ~= nil and not pcall(function() coordinator.disable() end) then clean = false end
	if caseFolder ~= nil and not pcall(function() caseFolder:Destroy() end) then clean = false end
	caseFolder = nil
	return clean
end

local function finish(value: any)
	if terminal then return end
	terminal = true
	local finalValue = if cleanup() then value else StudioProofReports.FAILURE_SENTINEL
	pcall(function()
		StudioTestService:EndTest(finalValue)
	end)
end

local function exactArgs(candidate: any): (string, number)
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		error("STUDIO_CONTROL_E_ARGS", 0)
	end
	local count = 0
	for key in candidate do
		if key ~= "version" and key ~= "launchId" and key ~= "mode" and key ~= "recipientCount" then
			error("STUDIO_CONTROL_E_ARGS", 0)
		end
		count += 1
	end
	local launchId = rawget(candidate, "launchId")
	local recipientCount = rawget(candidate, "recipientCount")
	if count ~= 4 or rawget(candidate, "version") ~= 1 or rawget(candidate, "mode") ~= "ControlProof"
		or type(launchId) ~= "string"
		or (recipientCount ~= 1 and recipientCount ~= 4 and recipientCount ~= 8)
		or string.match(launchId, "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") == nil
	then
		error("STUDIO_CONTROL_E_ARGS", 0)
	end
	return launchId, recipientCount
end

local function run()
	local launchId, expected = exactArgs(StudioTestService:GetTestArgs())
	local runtime = root:WaitForChild("Runtime")
	local ControlProtocol = require(runner:WaitForChild("ControlProtocol"))
	local StudioBenchmarkClock = require(runner:WaitForChild("StudioBenchmarkClock"))
	local HostManifestV1 = require(root:WaitForChild("contracts"):WaitForChild("internal"):WaitForChild("HostManifestV1"))
	local serverRoot = ServerStorage:WaitForChild("RelayBenchmarkServer")
	local AdapterAllowlist = require(serverRoot:WaitForChild("AdapterAllowlist"))
	local hostManifestModule = serverRoot:FindFirstChild("HostManifest")
	if hostManifestModule == nil or not hostManifestModule:IsA("ModuleScript") then
		error("STUDIO_CONTROL_E_MANIFEST", 0)
	end
	local required, candidate = pcall(require, hostManifestModule)
	hostManifestModule:Destroy()
	if not required then error("STUDIO_CONTROL_E_MANIFEST", 0) end
	local validation = HostManifestV1.validate(candidate)
	if validation.kind ~= "Valid" then error("STUDIO_CONTROL_E_MANIFEST", 0) end
	local manifest = validation.value
	if manifest.launchId ~= launchId
		or manifest.selection.kind ~= "Workload"
		or manifest.selection.workloadId ~= CASE_ID
		or manifest.selection.recipientCount ~= expected
	then
		error("STUDIO_CONTROL_E_MANIFEST", 0)
	end
	if AdapterAllowlist.resolve(manifest.adapter.moduleId).kind ~= "Rejected" then
		error("STUDIO_CONTROL_E_ALLOWLIST", 0)
	end
	local adapterId = manifest.adapter.identity.id
	local clock = StudioBenchmarkClock.newPort()
	local topologyInvalid = false
	local rosterLocked = false
	local rosterSet: { [Player]: boolean } = {}
	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		if rosterLocked and not rosterSet[player] then topologyInvalid = true end
		if #Players:GetPlayers() > expected then topologyInvalid = true end
	end))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		if rosterLocked and rosterSet[player] then
			topologyInvalid = true
			if coordinator ~= nil then coordinator.disconnect(player) end
		end
	end))

	local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
	while #Players:GetPlayers() ~= expected do
		if topologyInvalid or #Players:GetPlayers() > expected or clock.timeoutNowSeconds() >= deadline then
			error("STUDIO_CONTROL_E_TOPOLOGY", 0)
		end
		RunService.PostSimulation:Wait()
	end
	for _ = 1, 2 do
		RunService.PostSimulation:Wait()
		if topologyInvalid or #Players:GetPlayers() ~= expected then
			error("STUDIO_CONTROL_E_TOPOLOGY", 0)
		end
	end

	local roster = Players:GetPlayers()
	table.sort(roster, function(left, right)
		if left.UserId ~= right.UserId then return left.UserId < right.UserId end
		return left.Name < right.Name
	end)
	for _, player in roster do rosterSet[player] = true end
	rosterLocked = true

	local controlCases = runtime:WaitForChild("ControlCases")
	if controlCases:FindFirstChild(launchId) ~= nil then
		error("STUDIO_CONTROL_E_COLLISION", 0)
	end
	local created = Instance.new("Folder")
	created.Name = launchId
	created:SetAttribute("RecipientCount", expected)
	created:SetAttribute("AdapterId", adapterId)
	created:SetAttribute("CaseId", CASE_ID)
	local control = Instance.new("RemoteEvent")
	control.Name = "Control"
	control.Parent = created
	local rosterFolder = Instance.new("Folder")
	rosterFolder.Name = "Roster"
	rosterFolder.Parent = created
	for index, player in roster do
		local value = Instance.new("ObjectValue")
		value.Name = string.format("P%02d", index)
		value.Value = player
		value.Parent = rosterFolder
	end
	caseFolder = created

	local claimed = false
	local result = ControlProtocol.newCoordinator({
		protocolVersion = 1,
		runId = launchId,
		adapterId = adapterId,
		caseId = CASE_ID,
		recipientCount = expected,
	}, roster, clock.sharedNowSeconds, function(candidate)
		if claimed or candidate ~= launchId then return false end
		claimed = true
		return true
	end)
	if result.kind ~= "Ready" then error("STUDIO_CONTROL_E_PROTOCOL", 0) end
	coordinator = result.coordinator

	local waitingKind: string? = nil
	local accepted: { [number]: boolean } = {}
	local listenerBarrier = true
	local listenerReady: { [number]: boolean } = {}
	local controlQuietOpen = false
	local warmupReported: { [number]: boolean } = {}
	local controlQuietComplete: { [number]: boolean } = {}
	local measuredQuietComplete: { [number]: boolean } = {}
	local rosterIndex: { [Player]: number } = {}
	for index, player in roster do rosterIndex[player] = index end
	table.insert(connections, control.OnServerEvent:Connect(function(player, ...)
		if terminal or coordinator == nil then return end
		if listenerBarrier then
			local index = rosterIndex[player]
			if select("#", ...) ~= 1 or select(1, ...) ~= StudioProofReports.listenerReady
				or index == nil or listenerReady[index]
			then
				topologyInvalid = true
			else
				listenerReady[index] = true
			end
			return
		end
		if controlQuietOpen then
			local index = rosterIndex[player]
			if index == nil then
				topologyInvalid = true
				return
			end
			if warmupReported[index] then
				if select("#", ...) == 1 and select(1, ...) == StudioProofReports.controlQuietComplete
					and not controlQuietComplete[index]
				then
					controlQuietComplete[index] = true
				else
					topologyInvalid = true
				end
				return
			elseif select("#", ...) ~= 1 or type(select(1, ...)) ~= "table" then
				topologyInvalid = true
				return
			end
		end
		if measuredQuiet then
			local index = rosterIndex[player]
			if select("#", ...) == 1 and select(1, ...) == StudioProofReports.measuredQuietComplete
				and index ~= nil and not measuredQuietComplete[index]
			then
				measuredQuietComplete[index] = true
				return
			end
			topologyInvalid = true
		end
		if postQuiet then topologyInvalid = true end
		local received = coordinator.receive(player, ...)
		if received.kind == "Accepted" and waitingKind ~= nil and received.event.kind == waitingKind then
			accepted[received.participantIndex] = true
			if waitingKind == "WarmupReport" then warmupReported[received.participantIndex] = true end
		elseif received.kind ~= "Ignored" then
			topologyInvalid = true
		end
	end))
	created.Parent = controlCases
	local listenerDeadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
	while true do
		local readyCount = 0
		for index = 1, expected do
			if listenerReady[index] then readyCount += 1 end
		end
		if readyCount == expected then break end
		if topologyInvalid or clock.timeoutNowSeconds() >= listenerDeadline then
			error("STUDIO_CONTROL_E_LISTENER", 0)
		end
		RunService.PostSimulation:Wait()
	end
	listenerBarrier = false

	local function startBarrier(kind: string, intent: any)
		waitingKind = kind
		table.clear(accepted)
		for index, player in roster do
			local command = coordinator.command(index, intent)
			if command.kind ~= "Ready" then error("STUDIO_CONTROL_E_PROTOCOL", 0) end
			local ok = pcall(function()
				control:FireClient(player, command.body)
			end)
			if not ok then error("STUDIO_CONTROL_E_PROTOCOL", 0) end
		end
	end
	local function waitBarrier()
		local barrierDeadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
		while true do
			local count = 0
			for index = 1, expected do
				if accepted[index] then count += 1 end
			end
			if count == expected then return end
			if topologyInvalid or clock.timeoutNowSeconds() >= barrierDeadline then
				error("STUDIO_CONTROL_E_TIMEOUT", 0)
			end
			RunService.PostSimulation:Wait()
		end
	end

	startBarrier("BoundReport", { kind = "BindCase" })
	waitBarrier()
	startBarrier("ReadyReport", { kind = "PrepareRepetition", repetitionIndex = 1 })
	waitBarrier()
	startBarrier("ClockReply", { kind = "ClockChallenge" })
	waitBarrier()
	controlQuietOpen = true
	startBarrier("WarmupReport", { kind = "BeginWarmup", repetitionIndex = 1 })
	waitBarrier()
	local controlQuietDeadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
	while true do
		local completeCount = 0
		for index = 1, expected do
			if controlQuietComplete[index] then completeCount += 1 end
		end
		if completeCount == expected then break end
		if topologyInvalid or clock.timeoutNowSeconds() >= controlQuietDeadline then
			error("STUDIO_CONTROL_E_QUIET", 0)
		end
		RunService.PostSimulation:Wait()
	end
	for _ = 1, 59 do
		RunService.PostSimulation:Wait()
		if topologyInvalid or coordinator.postSimulation() then error("STUDIO_CONTROL_E_QUIET", 0) end
	end
	RunService.PostSimulation:Wait()
	if topologyInvalid or not coordinator.postSimulation() then error("STUDIO_CONTROL_E_QUIET", 0) end
	controlQuietOpen = false

	startBarrier("RepetitionReport", {
		kind = "ArmMeasured",
		repetitionIndex = 1,
		startSharedSeconds = clock.sharedNowSeconds(),
	})
	measuredQuiet = true
	for _ = 1, 59 do
		RunService.PostSimulation:Wait()
		if topologyInvalid then error("STUDIO_CONTROL_E_QUIET", 0) end
	end
	RunService.PostSimulation:Wait()
	if topologyInvalid then error("STUDIO_CONTROL_E_QUIET", 0) end
	local quietDeadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
	while true do
		local completeCount = 0
		for index = 1, expected do
			if measuredQuietComplete[index] then completeCount += 1 end
		end
		if completeCount == expected then break end
		if topologyInvalid or clock.timeoutNowSeconds() >= quietDeadline then
			error("STUDIO_CONTROL_E_QUIET", 0)
		end
		RunService.PostSimulation:Wait()
	end
	measuredQuiet = false
	local postTeardown = coordinator.beginPostTeardownObservation(1, true, true)
	if postTeardown.kind ~= "Ready" then error("STUDIO_CONTROL_E_PROTOCOL", 0) end
	for _, player in roster do
		local released = pcall(function()
			control:FireClient(player, StudioProofReports.measuredQuietRelease)
		end)
		if not released then error("STUDIO_CONTROL_E_PROTOCOL", 0) end
	end
	waitBarrier()
	waitingKind = nil
	postQuiet = true
	for _ = 1, 60 do
		RunService.PostSimulation:Wait()
		if topologyInvalid then error("STUDIO_CONTROL_E_QUIET", 0) end
	end
	postQuiet = false
	if topologyInvalid then error("STUDIO_CONTROL_E_TOPOLOGY", 0) end
	finish(StudioProofReports.SENTINEL)
end

task.spawn(function()
	local ok = pcall(run)
	if not ok then finish(StudioProofReports.FAILURE_SENTINEL) end
end)
