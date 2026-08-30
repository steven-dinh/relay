--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local root = ReplicatedStorage:WaitForChild("RelayBenchmark")
local runner = root:WaitForChild("Runner")
local runtime = root:WaitForChild("Runtime")
local ControlProtocol = require(runner:WaitForChild("ControlProtocol"))
local StudioBenchmarkClock = require(runner:WaitForChild("StudioBenchmarkClock"))
local StudioProofReports = require(runner:WaitForChild("StudioProofReports"))

local CASE_ID = "state-broadcast-s2c"
local MAX_WAIT_SECONDS = 120

local function isRunId(value: string): boolean
	return string.match(value, "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") ~= nil
end

local function run()
	local clock = StudioBenchmarkClock.newPort()
	local controlCases = runtime:WaitForChild("ControlCases")
	local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
	local caseFolder: Folder? = nil
	while caseFolder == nil do
		local children = controlCases:GetChildren()
		if #children > 1 then
			error("STUDIO_CONTROL_E_CASE", 0)
		elseif #children == 1 and children[1]:IsA("Folder") then
			caseFolder = children[1]
		elseif clock.timeoutNowSeconds() >= deadline then
			error("STUDIO_CONTROL_E_TIMEOUT", 0)
		else
			RunService.PostSimulation:Wait()
		end
	end

	if not isRunId(caseFolder.Name) then
		error("STUDIO_CONTROL_E_CASE", 0)
	end
	local recipientCount = caseFolder:GetAttribute("RecipientCount")
	local adapterId = caseFolder:GetAttribute("AdapterId")
	local caseId = caseFolder:GetAttribute("CaseId")
	if recipientCount ~= 1 and recipientCount ~= 4 and recipientCount ~= 8 then
		error("STUDIO_CONTROL_E_ROSTER", 0)
	end
	if type(adapterId) ~= "string" or #adapterId < 1 or #adapterId > 64
		or string.match(adapterId, "^[a-z0-9][a-z0-9._-]*$") == nil
		or caseId ~= CASE_ID
	then
		error("STUDIO_CONTROL_E_CASE", 0)
	end
	local control: RemoteEvent? = nil
	local rosterValues: { Instance }? = nil
	while control == nil or rosterValues == nil do
		local controlCandidate = caseFolder:FindFirstChild("Control")
		local roster = caseFolder:FindFirstChild("Roster")
		if controlCandidate ~= nil and not controlCandidate:IsA("RemoteEvent") then
			error("STUDIO_CONTROL_E_CASE", 0)
		end
		if roster ~= nil and not roster:IsA("Folder") then
			error("STUDIO_CONTROL_E_CASE", 0)
		end
		if roster ~= nil then
			local values = roster:GetChildren()
			if #values > recipientCount then error("STUDIO_CONTROL_E_ROSTER", 0) end
			if #values == recipientCount then
				table.sort(values, function(left, right)
					return left.Name < right.Name
				end)
				local complete = true
				local seen: { [Player]: boolean } = {}
				for index, value in values do
					if not value:IsA("ObjectValue") or value.Name ~= string.format("P%02d", index) then
						error("STUDIO_CONTROL_E_ROSTER", 0)
					end
					local player = value.Value
					if player == nil then
						complete = false
					elseif not player:IsA("Player") or seen[player] then
						error("STUDIO_CONTROL_E_ROSTER", 0)
					else
						seen[player] = true
					end
				end
				if complete then rosterValues = values end
			end
		end
		if controlCandidate ~= nil then control = controlCandidate end
		if control == nil or rosterValues == nil then
			if clock.timeoutNowSeconds() >= deadline then error("STUDIO_CONTROL_E_TIMEOUT", 0) end
			RunService.PostSimulation:Wait()
		end
	end

	local participantIndex: number? = nil
	for index, value in rosterValues do
		if value.Value == Players.LocalPlayer then
			if participantIndex ~= nil then
				error("STUDIO_CONTROL_E_ROSTER", 0)
			end
			participantIndex = index
		end
	end
	if participantIndex == nil then
		error("STUDIO_CONTROL_E_ROSTER", 0)
	end

	local participant = ControlProtocol.newParticipant({
		protocolVersion = 1,
		runId = caseFolder.Name,
		adapterId = adapterId,
		caseId = caseId,
		recipientCount = recipientCount,
		participantIndex = participantIndex,
	})
	local stopped = false
	local controlQuietCompleteSent = false
	local measuredQuietComplete = false
	local measuredQuietReleased = false
	local connections: { RBXScriptConnection } = {}
	local function stop()
		if stopped then return end
		stopped = true
		participant.disable()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	local function send(intent: any)
		if stopped then return end
		local report = participant.report(intent)
		if report.kind ~= "Ready" then
			stop()
			return
		end
		local ok = pcall(function()
			control:FireServer(report.body)
		end)
		if not ok then stop() end
	end

	table.insert(connections, RunService.PostSimulation:Connect(function()
		if stopped then return end
		if participant.postSimulation() and not controlQuietCompleteSent then
			controlQuietCompleteSent = true
			local completed = pcall(function()
				control:FireServer(StudioProofReports.controlQuietComplete)
			end)
			if not completed then stop() end
		end
	end))
	table.insert(connections, control.OnClientEvent:Connect(function(...)
		if stopped then return end
		if measuredQuietComplete and not measuredQuietReleased
			and select("#", ...) == 1 and select(1, ...) == StudioProofReports.measuredQuietRelease
		then
			measuredQuietReleased = true
			participant.beginPostTeardownObservation(1)
			send(StudioProofReports.repetition)
			return
		end
		local received = participant.receive(...)
		if received.kind ~= "Accepted" then
			stop()
			return
		end
		local kind = received.command.kind
		if kind == "BindCase" then
			send(StudioProofReports.bound)
		elseif kind == "PrepareRepetition" then
			send(StudioProofReports.ready)
		elseif kind == "ClockChallenge" then
			send(StudioProofReports.clockReply(clock))
		elseif kind == "BeginWarmup" then
			send(StudioProofReports.warmup)
		elseif kind == "ArmMeasured" then
			task.spawn(function()
				for _ = 1, 59 do
					RunService.PostSimulation:Wait()
					if stopped then return end
				end
				RunService.PostSimulation:Wait()
				if stopped then return end
				measuredQuietComplete = true
				local completed = pcall(function()
					control:FireServer(StudioProofReports.measuredQuietComplete)
				end)
				if not completed then stop() end
			end)
		else
			stop()
		end
	end))
	table.insert(connections, caseFolder.AncestryChanged:Connect(function(_, parent)
		if parent == nil then stop() end
	end))
	local readySent = pcall(function()
		control:FireServer(StudioProofReports.listenerReady)
	end)
	if not readySent then stop() end
end

task.spawn(function()
	pcall(run)
end)
