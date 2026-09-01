--!strict

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")

local root = ReplicatedStorage:WaitForChild("RelayBenchmark")
local runner = root:WaitForChild("Runner")
local StudioProofReports = require(runner:WaitForChild("StudioProofReports"))

local CASE_ID = "state-broadcast-s2c"
local MAX_WAIT_SECONDS = 120
local BENCHMARK_WAIT_SECONDS = 150
local BENCHMARK_CONTROL_QUIET = "RelayStudioBenchmarkControlQuietV1"
local BENCHMARK_MEASURED_QUIET = "RelayStudioBenchmarkMeasuredQuietV1"
local BENCHMARK_MEASURED_ABORT = "RelayStudioBenchmarkMeasuredAbortV1"
local BENCHMARK_TEARDOWN_COMPLETE = "RelayStudioBenchmarkTeardownCompleteV1"
local BENCHMARK_PRESTART_OBSERVED = "RelayStudioBenchmarkPrestartObservedV1"
local BENCHMARK_PRESTART_ISOLATION_FAILED = "RelayStudioBenchmarkPrestartIsolationFailedV1"
local BENCHMARK_ABORT_SETUP = "RelayStudioBenchmarkAbortSetupV1"
local BENCHMARK_BEGIN_TEARDOWN = "RelayStudioBenchmarkBeginTeardownV1"
local BENCHMARK_BEGIN_PRESTART_TEARDOWN = "RelayStudioBenchmarkBeginPrestartTeardownV1"
local BENCHMARK_ROOT_REMOVED = "RelayStudioBenchmarkRootRemovedV1"
local FIXED_FINALIZATION_FAILURE_JSON = "{\"kind\":\"RelayHarnessTerminationV1\",\"code\":\"FinalizationFailure\",\"stage\":\"Finalize\"}"

local terminal = false
local caseFolder: Folder? = nil
local coordinator: any = nil
local connections: { RBXScriptConnection } = {}
local postQuiet = false
local measuredQuiet = false
local benchmarkCleanup: (() -> boolean)? = nil

local function cleanup(): boolean
	local clean = true
	for _, connection in connections do
		if not pcall(function() connection:Disconnect() end) then clean = false end
	end
	table.clear(connections)
	if coordinator ~= nil and not pcall(function() coordinator.disable() end) then clean = false end
	if benchmarkCleanup ~= nil then
		local cleanupOk, cleanupResult = pcall(benchmarkCleanup)
		if not cleanupOk or cleanupResult ~= true then clean = false end
	end
	benchmarkCleanup = nil
	if caseFolder ~= nil and not pcall(function() caseFolder:Destroy() end) then clean = false end
	caseFolder = nil
	return clean
end

local function finish(value: any, cleanupFailureValue: any?)
	if terminal then return end
	terminal = true
	local finalValue = if cleanup() then value else (cleanupFailureValue or StudioProofReports.FAILURE_SENTINEL)
	pcall(function()
		StudioTestService:EndTest(finalValue)
	end)
end

local function encodeBenchmarkTerminal(candidate: any): string
	local encoded = table.pack(pcall(function()
		return HttpService:JSONEncode(candidate)
	end))
	if encoded[1] == true and encoded.n == 2 and type(encoded[2]) == "string" then
		return encoded[2]
	end
	return FIXED_FINALIZATION_FAILURE_JSON
end

local function exactArgs(candidate: any): (string, number, "ControlProof" | "Benchmark")
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
	local mode = rawget(candidate, "mode")
	if count ~= 4 or rawget(candidate, "version") ~= 1
		or (mode ~= "ControlProof" and mode ~= "Benchmark")
		or type(launchId) ~= "string"
		or (recipientCount ~= 1 and recipientCount ~= 4 and recipientCount ~= 8)
		or string.match(launchId, "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") == nil
	then
		error("STUDIO_CONTROL_E_ARGS", 0)
	end
	return launchId, recipientCount, mode
end

local function runControlProof(launchId: string, expected: number)
	local runtime = root:WaitForChild("Runtime")
	local ControlProtocol = require(runner:WaitForChild("ControlProtocol"))
	local StudioBenchmarkClock = require(runner:WaitForChild("StudioBenchmarkClock"))
	local HostManifestV1 = require(root:WaitForChild("contracts"):WaitForChild("internal"):WaitForChild("HostManifestV1"))
	local serverRoot = ServerStorage:WaitForChild("RelayBenchmarkServer")
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
	local adapterId = manifest.adapter.identity.id
	local clock = StudioBenchmarkClock.newPort()
	local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
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
	local controlConnection: RBXScriptConnection? = nil
	local function invalidateControlIngress()
		topologyInvalid = true
		local connection = controlConnection
		controlConnection = nil
		if connection ~= nil then connection:Disconnect() end
	end
	local installedControlConnection = control.OnServerEvent:Connect(function(player, ...)
		if terminal or coordinator == nil then return end
		if listenerBarrier then
			local index = rosterIndex[player]
			if select("#", ...) ~= 1 or select(1, ...) ~= StudioProofReports.listenerReady
				or index == nil or listenerReady[index]
			then
				invalidateControlIngress()
			else
				listenerReady[index] = true
			end
			return
		end
		if controlQuietOpen then
			local index = rosterIndex[player]
			if index == nil then
				invalidateControlIngress()
				return
			end
			if warmupReported[index] then
				if select("#", ...) == 1 and select(1, ...) == StudioProofReports.controlQuietComplete
					and not controlQuietComplete[index]
				then
					controlQuietComplete[index] = true
				else
					invalidateControlIngress()
				end
				return
			elseif select("#", ...) ~= 1 or type(select(1, ...)) ~= "table" then
				invalidateControlIngress()
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
			invalidateControlIngress()
			return
		end
		if postQuiet then
			invalidateControlIngress()
			return
		end
		local received = coordinator.receive(player, ...)
		if received.kind == "Accepted" and waitingKind ~= nil and received.event.kind == waitingKind then
			accepted[received.participantIndex] = true
			if waitingKind == "WarmupReport" then warmupReported[received.participantIndex] = true end
		elseif received.kind ~= "Ignored" then
			invalidateControlIngress()
			return
		end
	end)
	controlConnection = installedControlConnection
	table.insert(connections, installedControlConnection)
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

local function runBenchmark(launchId: string, expected: number): any
	local contracts = root:WaitForChild("contracts")
	local internalContracts = contracts:WaitForChild("internal")
	local runtime = root:WaitForChild("Runtime")
	local BenchmarkClock = require(runner:WaitForChild("BenchmarkClock"))
	local ControlProtocol = require(runner:WaitForChild("ControlProtocol"))
	local Fixtures = require(root:WaitForChild("fixtures"):WaitForChild("event-v1"))
	local GenerationActivation = require(runner:WaitForChild("GenerationActivation"))
	local AdapterIdentity = require(internalContracts:WaitForChild("AdapterIdentity"))
	local HarnessTerminationV1 = require(internalContracts:WaitForChild("HarnessTerminationV1"))
	local HostManifestV1 = require(internalContracts:WaitForChild("HostManifestV1"))
	local ResultDraftAssembler = require(runner:WaitForChild("ResultDraftAssembler"))
	local ResultV1 = require(contracts:WaitForChild("result-v1"))
	local RunState = require(runner:WaitForChild("RunState"))
	local SessionOwner = require(runner:WaitForChild("SessionOwner"))
	local StudioBenchmarkClock = require(runner:WaitForChild("StudioBenchmarkClock"))
	local TimingRecorder = require(runner:WaitForChild("TimingRecorder"))

	local function stopWith(value: any): never
		error(value, 0)
	end
	local function termination(code: string, stage: string): any
		return HarnessTerminationV1.new(code, stage)
	end
	local function requireReady(value: any, code: string): any
		if type(value) ~= "table" or rawget(value, "kind") ~= "Ready" then
			if type(value) == "table" and rawget(value, "kind") == "Terminated" then
				stopWith(rawget(value, "termination"))
			end
			error(code, 0)
		end
		return value
	end
	local function postSimulationSource()
		local source = {
			connectPostSimulation = function(callback: () -> ())
				local connection = RunService.PostSimulation:Connect(callback)
				return function()
					connection:Disconnect()
				end
			end,
		}
		table.freeze(source)
		return source
	end

	local serverRoot = ServerStorage:WaitForChild("RelayBenchmarkServer")
	local AdapterAllowlist = require(serverRoot:WaitForChild("AdapterAllowlist"))
	local hostManifestModule = serverRoot:FindFirstChild("HostManifest")
	if hostManifestModule == nil or not hostManifestModule:IsA("ModuleScript") then
		stopWith(termination("HostManifestRejected", "Preflight"))
	end
	local required, candidate = pcall(require, hostManifestModule)
	hostManifestModule:Destroy()
	if not required then stopWith(termination("HostManifestRejected", "Preflight")) end
	local validation = HostManifestV1.validate(candidate)
	if validation.kind ~= "Valid" then stopWith(termination("HostManifestRejected", "Preflight")) end
	local manifest = validation.value
	local selection = manifest.selection
	local resolvedSelectionResult = AdapterIdentity.resolveSelection(selection)
	if resolvedSelectionResult.kind ~= "Valid" then
		stopWith(termination("HostManifestRejected", "Preflight"))
	end
	local resolvedSelection = resolvedSelectionResult.value
	local caseId = if selection.kind == "Workload" then selection.workloadId else selection.probeId
	if manifest.launchId ~= launchId
		or resolvedSelection.clientProcessCount ~= expected
		or (resolvedSelection.kind == "Workload" and resolvedSelection.recipientCount ~= expected)
	then
		stopWith(termination("HostManifestRejected", "Preflight"))
	end
	local resolved = AdapterAllowlist.resolve(manifest.adapter)
	if resolved.kind ~= "Resolved" then stopWith(termination("HostManifestRejected", "Preflight")) end

	local clockPort = StudioBenchmarkClock.newPort()
	local clock = BenchmarkClock.new(clockPort)
	local topologyInvalid = false
	local topologyTermination: any = nil
	local rosterLocked = false
	local rosterSet: { [Player]: boolean } = {}
	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		if rosterLocked and not rosterSet[player] then topologyInvalid = true end
		if #Players:GetPlayers() > expected then topologyInvalid = true end
	end))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		if rosterLocked and rosterSet[player] then
			topologyInvalid = true
			if coordinator ~= nil then
				local call = table.pack(pcall(coordinator.disconnect, player))
				if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
					topologyTermination = topologyTermination
						or termination("ControlProtocolRejected", "Execution")
				elseif call[2].kind == "Terminated" then
					topologyTermination = topologyTermination or call[2].termination
				elseif call[2].kind == "Disconnected" then
					topologyTermination = topologyTermination
						or termination("FinalEvidenceUnrepresentable", "Execution")
				elseif call[2].kind ~= "Ignored" then
					topologyTermination = topologyTermination
						or termination("ControlProtocolRejected", "Execution")
				end
			end
		end
	end))
	local rosterDeadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
	while #Players:GetPlayers() ~= expected do
		if topologyInvalid or #Players:GetPlayers() > expected or clock.timeoutNowSeconds() >= rosterDeadline then
			stopWith(termination("ControlProtocolRejected", "Setup"))
		end
		RunService.PostSimulation:Wait()
	end
	for _ = 1, 2 do
		RunService.PostSimulation:Wait()
		if topologyInvalid or #Players:GetPlayers() ~= expected then
			stopWith(termination("ControlProtocolRejected", "Setup"))
		end
	end
	local roster = Players:GetPlayers()
	table.sort(roster, function(left, right)
		if left.UserId ~= right.UserId then return left.UserId < right.UserId end
		return left.Name < right.Name
	end)
	for _, player in roster do rosterSet[player] = true end
	rosterLocked = true

	local preparedResult = SessionOwner.prepareCoordinator(manifest, manifest.adapter.identity, {
		clocks = clockPort,
		postSimulation = postSimulationSource(),
		clientTokens = roster,
	})
	if preparedResult.kind ~= "Prepared" then stopWith(preparedResult.termination) end
	local prepared = preparedResult.value
	local caseState = RunState.newCase(prepared, clock)
	local serverState = RunState.newParticipant(prepared.selection, { role = "Server" })
	local serverTiming = TimingRecorder.new(prepared.caseDefinition, serverState.participant, clock)

	local controlCases = runtime:WaitForChild("ControlCases")
	local generationParent = runtime:WaitForChild("AdapterGenerations")
	if controlCases:FindFirstChild(launchId) ~= nil then
		stopWith(termination("ControlProtocolRejected", "Setup"))
	end
	local created = Instance.new("Folder")
	created.Name = launchId
	created:SetAttribute("RecipientCount", expected)
	created:SetAttribute("AdapterId", manifest.adapter.identity.id)
	created:SetAttribute("CaseId", caseId)
	created:SetAttribute("Mode", "Benchmark")
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
	local protocolResult = ControlProtocol.newCoordinator({
		protocolVersion = 1,
		runId = launchId,
		adapterId = manifest.adapter.identity.id,
		caseId = caseId,
		recipientCount = expected,
	}, roster, clock.sharedNowSeconds, function(value)
		if claimed or value ~= launchId then return false end
		claimed = true
		return true
	end)
	coordinator = requireReady(protocolResult, "STUDIO_BENCHMARK_E_PROTOCOL").coordinator

	local listenerBarrier = true
	local listenerReady: { [number]: boolean } = {}
	local rosterIndex: { [Player]: number } = {}
	for index, player in roster do rosterIndex[player] = index end
	local waitingKind: string? = nil
	local accepted: { [number]: boolean } = {}
	local acceptedEvents: { [number]: any } = {}
	local protocolTermination: any = nil
	local currentRepetition = 0
	local protocolAbort = false
	local controlQuietOpen = false
	local controlQuietComplete: { [number]: boolean } = {}
	local warmupReported: { [number]: boolean } = {}
	local measuredCompletionOpen = false
	local measuredComplete: { [number]: "Clean" | "Abort" } = {}
	local teardownReadyOpen = false
	local teardownReady: { [number]: boolean } = {}
	local prestartObservationOpen = false
	local prestartObserved: { [number]: "Clean" | "Invalid" } = {}
	local function rejectProtocol()
		protocolTermination = protocolTermination or termination("ControlProtocolRejected", "Execution")
	end
	local function recordClockFailure()
		local recorded = caseState.recordFailure({ code = "ClockProofFailure", occurrences = 1 })
		if recorded.kind == "Terminated" then
			protocolTermination = recorded.termination
		else
			protocolTermination = termination("FinalEvidenceUnrepresentable", "Execution")
		end
	end
	table.insert(connections, control.OnServerEvent:Connect(function(player, ...)
		if terminal or protocolTermination ~= nil then return end
		local index = rosterIndex[player]
		if listenerBarrier then
			if select("#", ...) ~= 1 or select(1, ...) ~= StudioProofReports.listenerReady
				or index == nil or listenerReady[index]
			then
				topologyInvalid = true
			else
				listenerReady[index] = true
			end
			return
		end
		local count = select("#", ...)
		local scalar = if count >= 1 then select(1, ...) else nil
		local scalarRepetition = if count >= 2 then select(2, ...) else nil
		if scalar == BENCHMARK_CONTROL_QUIET or scalar == BENCHMARK_MEASURED_QUIET
			or scalar == BENCHMARK_MEASURED_ABORT
			or scalar == BENCHMARK_TEARDOWN_COMPLETE
			or scalar == BENCHMARK_PRESTART_OBSERVED
			or scalar == BENCHMARK_PRESTART_ISOLATION_FAILED
		then
			local target = if scalar == BENCHMARK_CONTROL_QUIET then controlQuietComplete
				elseif scalar == BENCHMARK_MEASURED_QUIET or scalar == BENCHMARK_MEASURED_ABORT then measuredComplete
				elseif scalar == BENCHMARK_PRESTART_OBSERVED
					or scalar == BENCHMARK_PRESTART_ISOLATION_FAILED then prestartObserved
				else teardownReady
			local open = if scalar == BENCHMARK_CONTROL_QUIET then controlQuietOpen
				elseif scalar == BENCHMARK_MEASURED_QUIET or scalar == BENCHMARK_MEASURED_ABORT then measuredCompletionOpen
				elseif scalar == BENCHMARK_PRESTART_OBSERVED
					or scalar == BENCHMARK_PRESTART_ISOLATION_FAILED then prestartObservationOpen
				else teardownReadyOpen
			if count ~= 2 or scalarRepetition ~= currentRepetition or not open
				or (scalar == BENCHMARK_CONTROL_QUIET and (index == nil or not warmupReported[index]))
				or index == nil or target[index]
			then
				rejectProtocol()
			else
				target[index] = if scalar == BENCHMARK_MEASURED_ABORT then "Abort"
					elseif scalar == BENCHMARK_MEASURED_QUIET then "Clean"
					elseif scalar == BENCHMARK_PRESTART_ISOLATION_FAILED then "Invalid"
					elseif scalar == BENCHMARK_PRESTART_OBSERVED then "Clean"
					else true
			end
			return
		end
		local received = coordinator.receive(player, ...)
		if received.kind == "Terminated" then
			protocolTermination = received.termination
		elseif received.kind == "ClockProofFailed" then
			recordClockFailure()
		elseif received.kind == "MeasuredControlTraffic" then
			protocolAbort = true
		elseif received.kind == "Accepted" and waitingKind ~= nil and received.event.kind == waitingKind then
			accepted[received.participantIndex] = true
			acceptedEvents[received.participantIndex] = received.event
			if received.event.kind == "WarmupReport" then
				warmupReported[received.participantIndex] = true
			end
		elseif received.kind ~= "Ignored" then
			rejectProtocol()
		end
	end))
	created.Parent = controlCases

	local function waitFor(predicate: () -> boolean, timeoutTermination: any)
		local deadline = clock.timeoutNowSeconds() + BENCHMARK_WAIT_SECONDS
		while not predicate() do
			if protocolTermination ~= nil then stopWith(protocolTermination) end
			if topologyTermination ~= nil then stopWith(topologyTermination) end
			if topologyInvalid then stopWith(termination("ControlProtocolRejected", "Execution")) end
			if clock.timeoutNowSeconds() >= deadline then stopWith(timeoutTermination) end
			RunService.PostSimulation:Wait()
		end
	end
	waitFor(function()
		local count = 0
		for index = 1, expected do if listenerReady[index] then count += 1 end end
		return count == expected
	end, termination("ControlProtocolRejected", "Setup"))
	listenerBarrier = false

	local function startBarrier(kind: string, intent: any)
		waitingKind = kind
		table.clear(accepted)
		table.clear(acceptedEvents)
		for index, player in roster do
			local commandResult = coordinator.command(index, intent)
			if commandResult.kind == "ClockProofFailed" then
				recordClockFailure()
				return
			elseif commandResult.kind == "MeasuredControlTraffic" then
				protocolAbort = true
				return
			elseif commandResult.kind ~= "Ready" then
				rejectProtocol()
				return
			end
			local fired = pcall(function() control:FireClient(player, commandResult.body) end)
			if not fired then
				if intent.kind == "BindCase" then
					stopWith(termination("ControlProtocolRejected", "Setup"))
				elseif intent.kind == "BeginWarmup" then
					stopWith(termination("WarmupEvidenceRejected", "Execution"))
				else
					stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
				end
			end
		end
	end
	local function waitBarrier(): boolean
		local deadline = clock.timeoutNowSeconds() + BENCHMARK_WAIT_SECONDS
		while true do
			local count = 0
			for index = 1, expected do if accepted[index] then count += 1 end end
			if count == expected then return true end
			if protocolTermination ~= nil then stopWith(protocolTermination) end
			if topologyTermination ~= nil then stopWith(topologyTermination) end
			if topologyInvalid then stopWith(termination("ControlProtocolRejected", "Execution")) end
			if clock.timeoutNowSeconds() >= deadline then
				for index = 1, expected do
					if not accepted[index] then
						local call = table.pack(pcall(coordinator.expireResponse, index))
						if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
							stopWith(termination("ControlProtocolRejected", "Execution"))
						elseif call[2].kind == "Terminated" then
							stopWith(call[2].termination)
						elseif call[2].kind ~= "Ready" then
							stopWith(termination("ControlProtocolRejected", "Execution"))
						end
					end
				end
				return false
			end
			RunService.PostSimulation:Wait()
		end
	end
	local function allReported(reports: { [number]: any }): boolean
		for index = 1, expected do
			if not reports[index] then return false end
		end
		return true
	end
	startBarrier("BoundReport", { kind = "BindCase" })
	if not waitBarrier() then stopWith(termination("ControlProtocolRejected", "Setup")) end

	local activeKernel: any = nil
	local activeOpen: any = nil
	local activeActivation: any = nil
	local activeRoot: Folder? = nil
	local measuredFrames = 0
	local measuredFinishIssued = false
	local finalLocalCause: "InputMutation"? = nil
	local frozenServerEvidence: any = nil
	benchmarkCleanup = function(): boolean
		local clean = true
		if activeActivation ~= nil and activeKernel == nil then
			local call = table.pack(pcall(activeActivation.rollback))
			if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table"
				or call[2].kind ~= "Clean"
			then
				clean = false
			end
		elseif activeKernel ~= nil then
			local cleaned = pcall(function()
				local status = activeKernel.status()
				if status.kind == "Terminated" then error("cleanup terminated", 0) end
				if status.phase == "Measured" then
					activeKernel.command({ kind = "FinishMeasured", outcome = "Abort" })
				elseif status.phase ~= "Closed" and status.phase ~= "PostTeardownObservation"
					and status.phase ~= "Verified" and status.phase ~= "Aborting"
				then
					activeKernel.command({ kind = "AbortBeforeMeasured" })
				end
				status = activeKernel.status()
				if status.phase ~= "Closed" and status.phase ~= "PostTeardownObservation" then
					activeKernel.beginTeardownObservation()
				end
				if activeKernel.status().phase ~= "Closed" then
					local teardown = activeKernel.teardown()
					if teardown.kind == "Terminated" then error("cleanup terminated", 0) end
				end
			end)
			if not cleaned then clean = false end
		end
		if activeOpen ~= nil then
			local call = table.pack(pcall(activeOpen.closeGenerationRoot))
			if call[1] ~= true or call.n ~= 2 or call[2] ~= nil then clean = false end
		end
		activeRoot = nil
		return clean
	end

	local function fixtureFor(repetitionIndex: number): any
		if prepared.selection.kind == "SeparateProbe" then
			return Fixtures.generateProbe(prepared.selection.probeId, repetitionIndex)
		end
		return Fixtures.generate(prepared.selection.workloadId, repetitionIndex)
	end
	local function phaseOf(): (string, number?)
		local status = activeKernel.status()
		if status.kind == "Terminated" then stopWith(status.termination) end
		return status.phase, status.quietFrames
	end
	local function pollActivation(): boolean
		local deadline = clock.timeoutNowSeconds() + BENCHMARK_WAIT_SECONDS
		local setupKind: string? = nil
		while setupKind == nil do
			if protocolTermination ~= nil then stopWith(protocolTermination) end
			if topologyTermination ~= nil then stopWith(topologyTermination) end
			if topologyInvalid then stopWith(termination("ControlProtocolRejected", "Setup")) end
			local value = activeActivation.pollReady()
			if value.kind == "ReadyToArm" then return true end
			if value.kind == "Terminated" then stopWith(value.termination) end
			if value.kind == "SetupFailed" or value.kind == "InternalFailed" then
				setupKind = value.kind
			elseif value.kind ~= "Pending" then
				setupKind = "InternalFailed"
			elseif clock.timeoutNowSeconds() >= deadline then
				setupKind = "SetupFailed"
			else
				RunService.PostSimulation:Wait()
			end
		end
		local fact = if setupKind == "InternalFailed"
			then {
				code = "InternalError",
				occurrences = 1,
				discriminator = { kind = "Stage", value = "Setup" },
			}
			else { code = "SetupFailure", occurrences = 1 }
		local recorded = caseState.recordFailure(fact)
		if recorded.kind == "Terminated" then stopWith(recorded.termination) end
		local aborted = caseState.transition({ kind = "AbortRemaining" })
		if aborted.kind == "Terminated" then stopWith(aborted.termination) end
		local rolledBack = activeActivation.rollback()
		if rolledBack.kind == "Terminated" then stopWith(rolledBack.termination) end
		activeActivation = nil
		local rootTermination = activeOpen.closeGenerationRoot()
		if rootTermination ~= nil then stopWith(rootTermination) end
		activeOpen = nil
		return false
	end
	local function finishMeasuredIfNeeded()
		if prepared.selection.kind == "SeparateProbe" or measuredFinishIssued then return end
		measuredFrames += 1
		local needed = prepared.caseDefinition.measuredFrames + 1
		if measuredFrames >= needed then
			measuredFinishIssued = true
			activeKernel.command({ kind = "FinishMeasured", outcome = "Complete" })
		end
	end
	local function hasCanonicalInputMutation(evidence: any): boolean
		if type(evidence) ~= "table" or type(evidence.failureFacts) ~= "table" then return false end
		local found = false
		for _, fact in evidence.failureFacts do
			if type(fact) == "table" and rawget(fact, "code") == "InputMutation" then
				local keyCount = 0
				for key in fact do
					if key ~= "code" and key ~= "occurrences" then return false end
					keyCount += 1
				end
				if found or keyCount ~= 2 or rawget(fact, "occurrences") ~= 1 then return false end
				found = true
			end
		end
		return found
	end
	local function finishPrestartMutation(repetitionIndex: number, localWarmupAbort: boolean)
		local currentPhase = phaseOf()
		if currentPhase ~= "Aborting" then
			activeKernel.command({ kind = "AbortBeforeMeasured" })
		end
		activeKernel.beginTeardownObservation()
		table.clear(teardownReady)
		teardownReadyOpen = true
		for _, player in roster do
			local fired = pcall(function()
				control:FireClient(player, BENCHMARK_BEGIN_PRESTART_TEARDOWN, repetitionIndex)
			end)
			if not fired then stopWith(termination("CleanupFailure", "Finalize")) end
		end
		waitFor(
			function() return allReported(teardownReady) end,
			termination("CleanupFailure", "Finalize")
		)
		local teardown = activeKernel.teardown()
		if teardown.kind == "Terminated" then stopWith(teardown.termination) end
		if teardown.kind ~= "Clean" then
			stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
		end
		local closedRoot = activeRoot
		local rootTermination = activeOpen.closeGenerationRoot()
		if rootTermination ~= nil then stopWith(rootTermination) end
		activeOpen = nil
		table.clear(prestartObserved)
		prestartObservationOpen = true
		for _, player in roster do
			local fired = pcall(function()
				control:FireClient(player, BENCHMARK_ROOT_REMOVED, repetitionIndex)
			end)
			if not fired then stopWith(termination("CleanupFailure", "Finalize")) end
		end
		RunService.PostSimulation:Wait()
		if closedRoot == nil or closedRoot.Parent ~= nil then
			stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
		end
		local closed = activeKernel.finishTeardownObservation()
		if closed.kind == "Terminated" then stopWith(closed.termination) end
		activeKernel = nil
		teardownReadyOpen = false
		waitFor(
			function() return allReported(prestartObserved) end,
			termination("FinalEvidenceUnrepresentable", "Execution")
		)
		prestartObservationOpen = false
		for index = 1, expected do
			if prestartObserved[index] ~= "Clean" then
				stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
			end
		end
		local frozenServer = serverState.freeze()
		if frozenServer.kind == "Terminated" then stopWith(frozenServer.termination) end
		frozenServerEvidence = frozenServer.value
		local hasLocalInputMutation = hasCanonicalInputMutation(frozenServerEvidence)
		local serverCanOwnInputMutation = prepared.selection.kind == "SeparateProbe"
			or prepared.selection.direction == "ServerToClient"
		if hasLocalInputMutation then
			if not serverCanOwnInputMutation then
				stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
			end
			finalLocalCause = "InputMutation"
		elseif localWarmupAbort then
			stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
		end
		local aborted = caseState.transition({ kind = "AbortRemaining" })
		if aborted.kind == "Terminated" then stopWith(aborted.termination) end
	end

	for repetitionIndex = 1, prepared.caseDefinition.repetitions do
		currentRepetition = repetitionIndex
		protocolAbort = false
		local generationName = string.format("%s-r%02d", launchId, repetitionIndex)
		if generationParent:FindFirstChild(generationName) ~= nil then
			stopWith(termination("ControlProtocolRejected", "Setup"))
		end
		local rootFactory = function()
			local generation = Instance.new("Folder")
			generation.Name = generationName
			generation:SetAttribute("RepetitionIndex", repetitionIndex)
			generation.Parent = generationParent
			activeRoot = generation
			local lease = {
				resourceRoot = generation,
				destroy = function()
					generation:Destroy()
					if activeRoot == generation then activeRoot = nil end
				end,
			}
			table.freeze(lease)
			return lease
		end
		activeOpen = SessionOwner.openServerPrepared(prepared, resolved.factory, rootFactory)
		local acceptedSession = caseState.acceptSession(repetitionIndex, activeOpen)
		if acceptedSession.kind == "Terminated" then stopWith(acceptedSession.termination) end
		if activeOpen.kind ~= "Ready" then
			activeOpen = nil
			break
		end
		activeActivation = GenerationActivation.beginLocal(
			activeOpen,
			serverState,
			fixtureFor(repetitionIndex),
			serverTiming,
			caseState
		)
		local readiness = caseState.startDeadline("Readiness")
		if readiness.kind ~= "Active" then
			stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
		end
		if not pollActivation() then break end
		startBarrier("ReadyReport", { kind = "PrepareRepetition", repetitionIndex = repetitionIndex })
		local readyBarrierComplete = waitBarrier()
		local clientSetupFailed = not readyBarrierComplete
		for index = 1, expected do
			local event = acceptedEvents[index]
			if event == nil or event.outcome ~= "Ready" then clientSetupFailed = true end
		end
		if clientSetupFailed then
			local recorded = caseState.recordFailure({ code = "SetupFailure", occurrences = 1 })
			if recorded.kind == "Terminated" then stopWith(recorded.termination) end
			local aborted = caseState.transition({ kind = "AbortRemaining" })
			if aborted.kind == "Terminated" then stopWith(aborted.termination) end
			table.clear(teardownReady)
			teardownReadyOpen = true
			for _, player in roster do
				local fired = pcall(function()
					control:FireClient(player, BENCHMARK_ABORT_SETUP, repetitionIndex)
				end)
				if not fired then stopWith(termination("CleanupFailure", "Finalize")) end
			end
			waitFor(
				function() return allReported(teardownReady) end,
				termination("CleanupFailure", "Finalize")
			)
			local rolledBack = activeActivation.rollback()
			if rolledBack.kind == "Terminated" then stopWith(rolledBack.termination) end
			if rolledBack.kind ~= "Clean" then stopWith(termination("CleanupFailure", "Finalize")) end
			activeActivation = nil
			local rootTermination = activeOpen.closeGenerationRoot()
			if rootTermination ~= nil then stopWith(rootTermination) end
			activeOpen = nil
			teardownReadyOpen = false
			break
		end
		caseState.clearDeadline("Readiness")
		if repetitionIndex == 1 then
			startBarrier("ClockReply", { kind = "ClockChallenge" })
			if not waitBarrier() then
				recordClockFailure()
				stopWith(protocolTermination)
			end
		end

		local armed = activeActivation.arm()
		if armed.kind ~= "Ready" then
			if armed.kind == "Terminated" then stopWith(armed.termination) end
			stopWith(termination("FinalizationFailure", "Finalize"))
		end
		activeKernel = armed.kernel
		activeActivation = nil
		if repetitionIndex == 1 then
			local beforeShared = clock.sharedNowSeconds()
			local localBefore = clock.localNowSeconds()
			local participantShared = clock.sharedNowSeconds()
			local localAfter = clock.localNowSeconds()
			local afterShared = clock.sharedNowSeconds()
			if not serverTiming.recordClockProof({
				coordinatorBeforeSharedSeconds = beforeShared,
				participantSharedSeconds = participantShared,
				coordinatorAfterSharedSeconds = afterShared,
				localBeforeSeconds = localBefore,
				localAfterSeconds = localAfter,
			}) then
				recordClockFailure()
				stopWith(protocolTermination)
			end
		end
		table.clear(controlQuietComplete)
		table.clear(warmupReported)
		controlQuietOpen = true
		activeKernel.command({ kind = "BeginWarmup" })
		startBarrier("WarmupReport", { kind = "BeginWarmup", repetitionIndex = repetitionIndex })
		waitFor(function()
			local phase = phaseOf()
			return phase == "WarmupDrained" or phase == "ControlQuiet" or phase == "Aborting"
		end, termination("WarmupEvidenceRejected", "Execution"))
		if not waitBarrier() then stopWith(termination("WarmupEvidenceRejected", "Execution")) end
		local serverWarmupInputMutation = phaseOf() == "Aborting"
		local remoteWarmupInputMutation = false
		for index = 1, expected do
			local event = acceptedEvents[index]
			if event == nil or event.kind ~= "WarmupReport" then
				stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
			elseif event.outcome == "InputMutation" then
				remoteWarmupInputMutation = true
			elseif event.outcome ~= "Clean" then
				stopWith(termination("WarmupEvidenceRejected", "Execution"))
			end
		end
		if serverWarmupInputMutation or remoteWarmupInputMutation then
			controlQuietOpen = false
			finishPrestartMutation(repetitionIndex, serverWarmupInputMutation)
			break
		end

		waitFor(function()
			local protocolQuiet = coordinator.postSimulation()
			local phase, quietFrames = phaseOf()
			return protocolQuiet and phase == "ControlQuiet" and quietFrames == 60
				and allReported(controlQuietComplete)
		end, termination("WarmupEvidenceRejected", "Execution"))
		controlQuietOpen = false
		local startSharedSeconds = clock.sharedNowSeconds()
		activeKernel.command({ kind = "ArmMeasured", startSharedSeconds = startSharedSeconds })
		table.clear(measuredComplete)
		measuredCompletionOpen = true
		startBarrier("RepetitionReport", {
			kind = "ArmMeasured",
			repetitionIndex = repetitionIndex,
			startSharedSeconds = startSharedSeconds,
		})
		measuredFrames = 0
		measuredFinishIssued = false
		waitFor(function()
			if protocolAbort then
				local phase = phaseOf()
				if phase == "Measured" then
					activeKernel.command({ kind = "FinishMeasured", outcome = "Abort" })
				end
			end
			finishMeasuredIfNeeded()
			local phase, quietFrames = phaseOf()
			local serverReady = (phase == "Verified" and quietFrames == 60)
				or phase == "Aborting"
			return serverReady and allReported(measuredComplete)
		end, termination("FinalEvidenceUnrepresentable", "Execution"))
		measuredCompletionOpen = false
		local serverPhase = phaseOf()
		local serverOutcome = if serverPhase == "Verified" then "Clean" else "Abort"
		for index = 1, expected do
			if measuredComplete[index] == "Abort" then serverOutcome = "Abort" end
		end

		local postBoundary = coordinator.beginPostTeardownObservation(
			repetitionIndex,
			true,
			serverOutcome ~= "Abort"
		)
		if postBoundary.kind == "Terminated" then stopWith(postBoundary.termination) end
		activeKernel.beginTeardownObservation()
		table.clear(teardownReady)
		teardownReadyOpen = true
		for _, player in roster do
			local fired = pcall(function()
				control:FireClient(player, BENCHMARK_BEGIN_TEARDOWN, repetitionIndex)
			end)
			if not fired then stopWith(termination("CleanupFailure", "Finalize")) end
		end
		waitFor(function()
			return allReported(teardownReady)
		end, termination("CleanupFailure", "Finalize"))
		local teardown = activeKernel.teardown()
		if teardown.kind == "Terminated" then stopWith(teardown.termination) end
		if teardown.kind ~= "Clean" and serverOutcome == "Clean" then
			serverOutcome = "Invalid"
		end
		local closedRoot = activeRoot
		local rootTermination = activeOpen.closeGenerationRoot()
		if rootTermination ~= nil then stopWith(rootTermination) end
		activeOpen = nil
		for _, player in roster do
			local fired = pcall(function()
				control:FireClient(player, BENCHMARK_ROOT_REMOVED, repetitionIndex)
			end)
			if not fired then stopWith(termination("CleanupFailure", "Finalize")) end
		end
		RunService.PostSimulation:Wait()
		local serverIsolationPassed = closedRoot ~= nil and closedRoot.Parent == nil
		if not serverIsolationPassed then
			local recorded = serverState.recordFailure({
				code = "IsolationFailure",
				occurrences = 1,
				firstRepetition = repetitionIndex,
			})
			if recorded.kind == "Terminated" then stopWith(recorded.termination) end
			if serverOutcome == "Clean" then serverOutcome = "Invalid" end
		end
		local closed = activeKernel.finishTeardownObservation()
		if closed.kind == "Terminated" then stopWith(closed.termination) end
		activeKernel = nil
		teardownReadyOpen = false
		if not waitBarrier() then
			stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
		end
		local repetitionOutcome = serverOutcome
		for index = 1, expected do
			local event = acceptedEvents[index]
			if event.outcome == "Abort" then
				repetitionOutcome = "Abort"
			elseif (event.outcome == "Invalid" or not event.isolationPassed)
				and repetitionOutcome == "Clean"
			then
				repetitionOutcome = "Invalid"
			end
		end
		local progressed
		if repetitionOutcome == "Abort" then
			progressed = caseState.transition({
				kind = "RepetitionAborted",
				repetitionIndex = repetitionIndex,
			})
		else
			progressed = caseState.transition({
				kind = "RepetitionCompleted",
				repetitionIndex = repetitionIndex,
				finalOnlyEvidence = false,
			})
			if repetitionOutcome == "Invalid" and repetitionIndex < prepared.caseDefinition.repetitions then
				progressed = caseState.transition({ kind = "AbortRemaining" })
			end
		end
		if progressed.kind == "Terminated" then stopWith(progressed.termination) end
		if repetitionOutcome ~= "Clean" then break end
	end

	local caseStatus = caseState.status()
	if caseStatus.kind == "Terminated" then stopWith(caseStatus.termination) end
	local finalOutcome = if caseStatus.phase == "Complete" then "Complete" else "Abort"
	local reachedRepetition = caseStatus.startedRepetitions
	local finalBoundary = if finalLocalCause == nil
		then coordinator.beginFinalReports(finalOutcome, reachedRepetition)
		else coordinator.beginFinalReports(finalOutcome, reachedRepetition, finalLocalCause)
	if finalBoundary.kind == "Terminated" then stopWith(finalBoundary.termination) end
	startBarrier("FinalReport", {
		kind = "FinishCase",
		repetitionIndex = reachedRepetition,
		outcome = finalOutcome,
	})
	if not waitBarrier() then
		stopWith(termination("FinalEvidenceUnrepresentable", "Execution"))
	end
	if frozenServerEvidence == nil then
		local frozenServer = serverState.freeze()
		if frozenServer.kind == "Terminated" then stopWith(frozenServer.termination) end
		frozenServerEvidence = frozenServer.value
	end
	local participantSnapshots = table.create(expected + 1)
	local serverSnapshot = {
		participant = serverState.participant,
		evidence = frozenServerEvidence,
	}
	table.freeze(serverSnapshot)
	participantSnapshots[1] = serverSnapshot
	for index = 1, expected do
		local clientSnapshot = {
			participant = {
				role = if prepared.selection.kind == "SeparateProbe" then "ProbeClient" else "Client",
				index = index,
			},
			evidence = acceptedEvents[index].snapshot,
		}
		table.freeze(clientSnapshot.participant)
		table.freeze(clientSnapshot)
		participantSnapshots[index + 1] = clientSnapshot
	end
	table.freeze(participantSnapshots)
	local snapshot = caseState.snapshot(participantSnapshots)
	if snapshot.kind == "Terminated" then stopWith(snapshot.termination) end
	local assemblyInput = {
		runId = launchId,
		manifest = manifest,
		snapshot = snapshot.value,
	}
	table.freeze(assemblyInput)
	local assembled = ResultDraftAssembler.assemble(assemblyInput)
	if assembled.kind == "Terminated" then stopWith(assembled.termination) end
	local finalized = ResultV1.finalize(assembled.value)
	return ResultV1.validate(finalized)
end

task.spawn(function()
	local arguments = table.pack(pcall(exactArgs, StudioTestService:GetTestArgs()))
	if arguments[1] ~= true or arguments.n ~= 4 then
		finish(StudioProofReports.FAILURE_SENTINEL)
		return
	end
	local launchId = arguments[2]
	local expected = arguments[3]
	local mode = arguments[4]
	if mode == "ControlProof" then
		local ok = pcall(runControlProof, launchId, expected)
		if not ok then finish(StudioProofReports.FAILURE_SENTINEL) end
		return
	end
	local HarnessTerminationV1 = require(
		root:WaitForChild("contracts"):WaitForChild("internal"):WaitForChild("HarnessTerminationV1")
	)
	local ok, value = pcall(runBenchmark, launchId, expected)
	local finalizationFailure = HarnessTerminationV1.new("FinalizationFailure", "Finalize")
	local cleanupFailure = HarnessTerminationV1.new("CleanupFailure", "Finalize")
	local cleanupFailureJson = encodeBenchmarkTerminal(cleanupFailure)
	local terminalValue: any
	if ok then
		terminalValue = value
	else
		local validated = table.pack(pcall(HarnessTerminationV1.validate, value))
		terminalValue = if validated[1] == true and validated.n == 2
			then validated[2]
			else finalizationFailure
	end
	local encodedValue = encodeBenchmarkTerminal(terminalValue)
	finish(encodedValue, cleanupFailureJson)
end)
