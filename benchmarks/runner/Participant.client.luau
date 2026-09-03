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
local BENCHMARK_CONTROL_QUIET = "RelayStudioBenchmarkControlQuietV1"
local BENCHMARK_WARMUP_ARMED = "RelayStudioBenchmarkWarmupArmedV1"
local BENCHMARK_MEASURED_ARMED = "RelayStudioBenchmarkMeasuredArmedV1"
local BENCHMARK_MEASURED_QUIET = "RelayStudioBenchmarkMeasuredQuietV1"
local BENCHMARK_MEASURED_ABORT = "RelayStudioBenchmarkMeasuredAbortV1"
local BENCHMARK_TEARDOWN_COMPLETE = "RelayStudioBenchmarkTeardownCompleteV1"
local BENCHMARK_PRESTART_OBSERVED = "RelayStudioBenchmarkPrestartObservedV1"
local BENCHMARK_PRESTART_ISOLATION_FAILED = "RelayStudioBenchmarkPrestartIsolationFailedV1"
local BENCHMARK_ABORT_SETUP = "RelayStudioBenchmarkAbortSetupV1"
local BENCHMARK_BEGIN_TEARDOWN = "RelayStudioBenchmarkBeginTeardownV1"
local BENCHMARK_BEGIN_PRESTART_TEARDOWN = "RelayStudioBenchmarkBeginPrestartTeardownV1"
local BENCHMARK_ROOT_REMOVED = "RelayStudioBenchmarkRootRemovedV1"
local runBenchmarkCase: ((Folder, RemoteEvent, { Instance }, number, number, string) -> ())? = nil

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
	local mode = caseFolder:GetAttribute("Mode")
	if recipientCount ~= 1 and recipientCount ~= 4 and recipientCount ~= 8 then
		error("STUDIO_CONTROL_E_ROSTER", 0)
	end
	if type(adapterId) ~= "string" or #adapterId < 1 or #adapterId > 64
		or string.match(adapterId, "^[a-z0-9][a-z0-9._-]*$") == nil
		or type(caseId) ~= "string" or #caseId < 1 or #caseId > 64
		or string.match(caseId, "^[a-z0-9][a-z0-9._-]*$") == nil
		or (mode ~= nil and mode ~= "Benchmark")
		or (mode == nil and caseId ~= CASE_ID)
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
	if mode == "Benchmark" then
		(runBenchmarkCase :: any)(caseFolder, control, rosterValues, participantIndex, recipientCount, adapterId)
		return
	elseif mode ~= nil then
		error("STUDIO_CONTROL_E_CASE", 0)
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

runBenchmarkCase = function(
	caseFolder: Folder,
	control: RemoteEvent,
	rosterValues: { Instance },
	participantIndex: number,
	recipientCount: number,
	adapterId: string
)
	local adapters = root:WaitForChild("adapters")
	local contracts = root:WaitForChild("contracts")
	local fixtures = root:WaitForChild("fixtures")
	local AdapterContract = require(adapters:WaitForChild("AdapterContract"))
	local BenchmarkClock = require(runner:WaitForChild("BenchmarkClock"))
	local Fixtures = require(fixtures:WaitForChild("event-v1"))
	local GenerationActivation = require(runner:WaitForChild("GenerationActivation"))
	local RunState = require(runner:WaitForChild("RunState"))
	local SessionOwner = require(runner:WaitForChild("SessionOwner"))
	local TimingRecorder = require(runner:WaitForChild("TimingRecorder"))
	local generationParent = runtime:WaitForChild("AdapterGenerations")
	local caseId = caseFolder:GetAttribute("CaseId")
	if type(caseId) ~= "string" or (adapterId ~= "native-reliable" and adapterId ~= "relay-reliable") then
		error("STUDIO_BENCHMARK_E_CASE", 0)
	end

	local participant = ControlProtocol.newParticipant({
		protocolVersion = 1,
		runId = caseFolder.Name,
		adapterId = adapterId,
		caseId = caseId,
		recipientCount = recipientCount,
		participantIndex = participantIndex,
	})
	local clockPort = StudioBenchmarkClock.newPort()
	local clock = BenchmarkClock.new(clockPort)
	local stopped = false
	local commandBusy = false
	local activeActivation: any = nil
	local activeKernel: any = nil
	local activeRoot: Folder? = nil
	local activeState: any = nil
	local activeTiming: any = nil
	local supported: any = nil
	local nativeFactory: any = nil
	local selection: any = nil
	local caseDefinition: any = nil
	local measuredFrames = 0
	local measuredFinishIssued = false
	local currentRepetition = 0
	local pendingClockProof: any = nil
	local controlQuietSent = false
	local measurementArmed = false
	local measuredArmedSent = false
	local measuredQuietSent = false
	local teardownCompleteSent = false
	local awaitingRootRemoval = false
	local prestartTeardown = false
	local repetitionOutcome: "Clean" | "Invalid" | "Abort" = "Clean"
	local connections: { RBXScriptConnection } = {}

	local function stop()
		if stopped then return end
		stopped = true
		pcall(participant.disable)
		for _, connection in connections do pcall(function() connection:Disconnect() end) end
		table.clear(connections)
		if activeActivation ~= nil and activeKernel == nil then pcall(activeActivation.rollback) end
		if activeKernel ~= nil then
			pcall(function()
				local status = activeKernel.status()
				if status.kind == "Terminated" or (status.kind == "State" and status.phase ~= "Closed") then
					if status.kind == "State" then
						if status.phase == "Measured" then
							activeKernel.command({ kind = "FinishMeasured", outcome = "Abort" })
						elseif status.phase ~= "Verified" and status.phase ~= "Draining" and status.phase ~= "Aborting" then
							activeKernel.command({ kind = "AbortBeforeMeasured" })
						end
					end
					activeKernel.beginTeardownObservation()
					activeKernel.teardown()
				end
			end)
		end
	end
	local function send(intent: any): boolean
		if stopped then return false end
		local result = participant.report(intent)
		if result.kind ~= "Ready" then
			stop()
			return false
		end
		local fired = pcall(function() control:FireServer(result.body) end)
		if not fired then stop() end
		return fired
	end
	local function sendScalar(kind: string, repetitionIndex: number): boolean
		if stopped then return false end
		local fired = pcall(function()
			control:FireServer(kind, repetitionIndex)
		end)
		if not fired then stop() end
		return fired
	end
	local function deepFreeze(value: any)
		if type(value) ~= "table" or table.isfrozen(value) then return end
		for key, child in value do
			deepFreeze(key)
			deepFreeze(child)
		end
		table.freeze(value)
	end
	local function canonicalIdentity(studioVersion: string): any
		if adapterId == "relay-reliable" then
			local pin = require(adapters:WaitForChild("RelayAdapterPin"))
			local admitted = require(runner:WaitForChild("AdapterAllowlist")).resolve(pin)
			if admitted.kind ~= "Resolved" or admitted.moduleId ~= adapterId then
				error("STUDIO_BENCHMARK_E_ADAPTER", 0)
			end
			deepFreeze(pin)
			return pin.identity
		end
		local value = {
			id = "native-reliable",
			displayName = "Roblox RemoteEvent",
			lane = "EquivalentSemantics",
			integrationKind = "EngineBuiltIn",
			library = {
				id = "roblox-remote-event",
				displayName = "Roblox RemoteEvent",
				version = studioVersion,
				provenance = { kind = "EngineBuiltIn", studioVersion = studioVersion },
			},
			semantics = {
				broadcastMode = "NativeBroadcast",
				intentionalAddedDeliveryFrames = 0,
				repetitionIsolation = "SessionRestart",
			},
			capabilities = {
				directions = { "ClientToServer", "ServerToClient" },
				deliverySemantics = { "ReliableOrdered" },
				payloadIds = { "state", "tiny" },
			},
		}
		deepFreeze(value)
		return value
	end
	local function selectionForCase(): any
		if caseId == "tiny-round-trip" then
			return { kind = "SeparateProbe", probeId = caseId }
		end
		return { kind = "Workload", workloadId = caseId, recipientCount = recipientCount }
	end
	local function fixtureFor(repetitionIndex: number): any
		if selection.kind == "SeparateProbe" then
			return Fixtures.generateProbe(selection.probeId, repetitionIndex)
		end
		return Fixtures.generate(selection.workloadId, repetitionIndex)
	end
	local function postSimulationSource()
		local value = {
			connectPostSimulation = function(callback: () -> ())
				local connection = RunService.PostSimulation:Connect(callback)
				return function() connection:Disconnect() end
			end,
		}
		table.freeze(value)
		return value
	end
	local function resolveGenerationRoot(repetitionIndex: number): Folder?
		local expectedName = string.format("%s-r%02d", caseFolder.Name, repetitionIndex)
		local found: Folder? = nil
		local conflict = false
		local function observe(child: Instance)
			if child.Name ~= expectedName then return end
			if not child:IsA("Folder") or found ~= nil and found ~= child then
				conflict = true
			elseif child:GetAttribute("RepetitionIndex") ~= repetitionIndex then
				conflict = true
			else
				found = child
			end
		end
		local watcher = generationParent.ChildAdded:Connect(observe)
		for _, child in generationParent:GetChildren() do observe(child) end
		local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
		while found == nil and not conflict and not stopped and clock.timeoutNowSeconds() < deadline do
			RunService.PostSimulation:Wait()
		end
		watcher:Disconnect()
		if conflict then return nil end
		return found
	end
	local function status(): any
		if activeKernel == nil then return nil end
		local value = activeKernel.status()
		if value.kind == "Terminated" then
			stop()
			return nil
		end
		return value
	end
	local function beginClientTeardown(repetitionIndex: number, prestart: boolean)
		if repetitionIndex ~= currentRepetition or activeKernel == nil or awaitingRootRemoval
			or teardownCompleteSent
		then
			stop()
			return
		end
		local current = status()
		if current == nil then return end
		if prestart then
			if current.phase ~= "Aborting" then
				if current.phase ~= "WarmupDrained" and current.phase ~= "ControlQuiet" then
					stop()
					return
				end
				local aborted = activeKernel.command({ kind = "AbortBeforeMeasured" })
				if aborted.kind == "Terminated" then
					stop()
					return
				end
			end
			repetitionOutcome = "Abort"
		elseif current.phase == "Verified" and current.quietFrames == 60 then
			repetitionOutcome = "Clean"
		elseif current.phase == "Aborting" then
			repetitionOutcome = "Abort"
		else
			stop()
			return
		end
		local begun = prestart or pcall(participant.beginPostTeardownObservation, repetitionIndex)
		local observing = pcall(activeKernel.beginTeardownObservation)
		if not begun or not observing then
			stop()
			return
		end
		local teardown = activeKernel.teardown()
		if teardown.kind == "Terminated" then
			stop()
			return
		elseif teardown.kind ~= "Clean" and repetitionOutcome == "Clean" then
			repetitionOutcome = "Invalid"
		end
		awaitingRootRemoval = true
		prestartTeardown = prestart
		teardownCompleteSent = true
		sendScalar(BENCHMARK_TEARDOWN_COMPLETE, repetitionIndex)
	end

	local function finishRootObservation(repetitionIndex: number)
		if repetitionIndex ~= currentRepetition or not awaitingRootRemoval or activeKernel == nil
			or activeRoot == nil
		then
			stop()
			return
		end
		local observedRoot = activeRoot
		task.spawn(function()
			local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
			while not stopped and observedRoot.Parent ~= nil and clock.timeoutNowSeconds() < deadline do
				RunService.PostSimulation:Wait()
			end
			if stopped then return end
			local isolationPassed = observedRoot.Parent == nil
			RunService.PostSimulation:Wait()
			if stopped then return end
			local finished, closed = pcall(activeKernel.finishTeardownObservation)
			if not finished or type(closed) ~= "table" or closed.kind == "Terminated" then
				stop()
				return
			end
			if not isolationPassed and not prestartTeardown then
				local recorded = activeState.recordFailure({
					code = "IsolationFailure",
					occurrences = 1,
					firstRepetition = repetitionIndex,
				})
				if recorded.kind ~= "Recorded" then
					stop()
					return
				end
				if repetitionOutcome == "Clean" then repetitionOutcome = "Invalid" end
			end
			local wasPrestart = prestartTeardown
			activeActivation = nil
			activeKernel = nil
			activeRoot = nil
			awaitingRootRemoval = false
			prestartTeardown = false
			if wasPrestart then
				sendScalar(
					if isolationPassed then BENCHMARK_PRESTART_OBSERVED else BENCHMARK_PRESTART_ISOLATION_FAILED,
					repetitionIndex
				)
			else
				send({
					kind = "RepetitionReport",
					outcome = repetitionOutcome,
					isolationPassed = isolationPassed,
				})
			end
		end)
	end

	local function reportSetupFailure(internal: boolean)
		if activeActivation ~= nil then
			local rolledBack = activeActivation.rollback()
			if rolledBack.kind ~= "Clean" then
				stop()
				return
			end
			activeActivation = nil
		end
		local setup = activeState.recordFailure({ code = "SetupFailure", occurrences = 1 })
		if setup.kind ~= "Recorded" then
			stop()
			return
		end
		if internal then
			local recorded = activeState.recordFailure({
				code = "InternalError",
				occurrences = 1,
				discriminator = { kind = "Stage", value = "Setup" },
			})
			if recorded.kind ~= "Recorded" then
				stop()
				return
			end
		end
		send({ kind = "ReadyReport", outcome = "SetupFailure" })
	end

	local function abortSetup(repetitionIndex: number)
		if repetitionIndex ~= currentRepetition or activeKernel ~= nil or teardownCompleteSent then
			stop()
			return
		end
		if activeActivation ~= nil then
			local rolledBack = activeActivation.rollback()
			if rolledBack.kind ~= "Clean" then
				stop()
				return
			end
			activeActivation = nil
		end
		teardownCompleteSent = true
		sendScalar(BENCHMARK_TEARDOWN_COMPLETE, repetitionIndex)
	end

	local function handleCommand(command: any)
		if command.kind == "BindCase" then
			local candidateSelection = selectionForCase()
			local preflight = AdapterContract.preflight(canonicalIdentity(version()), candidateSelection, version())
			if preflight.kind ~= "Supported" then stop() return end
			supported = preflight
			selection = preflight.selection
			caseDefinition = nil
			if selection.kind == "SeparateProbe" then
				for _, probe in require(contracts:WaitForChild("event-v1")).probes do
					if probe.id == selection.probeId then caseDefinition = probe end
				end
			else
				for _, workload in require(contracts:WaitForChild("event-v1")).workloads do
					if workload.id == selection.workloadId then caseDefinition = workload end
				end
			end
			if caseDefinition == nil then stop() return end
			if adapterId == "relay-reliable" then
				nativeFactory = require(adapters:WaitForChild("RelayReliable"))
			else
				nativeFactory = require(adapters:WaitForChild("NativeReliable"))
			end
			activeState = RunState.newParticipant(selection, {
				role = if selection.kind == "SeparateProbe" then "ProbeClient" else "Client",
				index = participantIndex,
			})
			activeTiming = TimingRecorder.new(caseDefinition, activeState.participant, clock)
			send({ kind = "BoundReport" })
		elseif command.kind == "PrepareRepetition" then
			currentRepetition += 1
			controlQuietSent = false
			measurementArmed = false
			measuredArmedSent = false
			measuredQuietSent = false
			teardownCompleteSent = false
			awaitingRootRemoval = false
			prestartTeardown = false
			repetitionOutcome = "Clean"
			local resourceRoot = resolveGenerationRoot(currentRepetition)
			if resourceRoot == nil then
				reportSetupFailure(false)
				return
			end
			activeRoot = resourceRoot
			local opened = SessionOwner.openClient(
				supported,
				nativeFactory,
				resourceRoot,
				participantIndex,
				{ clocks = clockPort, postSimulation = postSimulationSource() }
			)
			if opened.kind ~= "Ready" then
				if opened.kind == "Terminated" then
					stop()
					return
				end
				reportSetupFailure(opened.kind == "InternalFailed")
				return
			end
			activeActivation = GenerationActivation.beginLocal(
				opened,
				activeState,
				fixtureFor(currentRepetition),
				activeTiming,
				nil
			)
			local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
			while not stopped do
				local ready = activeActivation.pollReady()
				if ready.kind == "ReadyToArm" then break end
				if ready.kind ~= "Pending" or clock.timeoutNowSeconds() >= deadline then
					if ready.kind == "Terminated" then
						stop()
						return
					end
					reportSetupFailure(ready.kind == "InternalFailed")
					return
				end
				RunService.PostSimulation:Wait()
			end
			send({ kind = "ReadyReport", outcome = "Ready" })
		elseif command.kind == "ClockChallenge" then
			local coordinatorBefore = clock.sharedNowSeconds()
			local localBefore = clock.localNowSeconds()
			local participantShared = clock.sharedNowSeconds()
			local localAfter = clock.localNowSeconds()
			local coordinatorAfter = clock.sharedNowSeconds()
			pendingClockProof = {
				coordinatorBeforeSharedSeconds = coordinatorBefore,
				participantSharedSeconds = participantShared,
				coordinatorAfterSharedSeconds = coordinatorAfter,
				localBeforeSeconds = localBefore,
				localAfterSeconds = localAfter,
			}
			send({
				kind = "ClockReply",
				participantSharedSeconds = participantShared,
				localBeforeSeconds = localBefore,
				localAfterSeconds = localAfter,
			})
		elseif command.kind == "BeginWarmup" then
			local armed = activeActivation.arm()
			if armed.kind ~= "Ready" then stop() return end
			activeKernel = armed.kernel
			activeActivation = nil
			if pendingClockProof ~= nil then
				if not activeTiming.recordClockProof(pendingClockProof) then stop() return end
				pendingClockProof = nil
			end
			local started = activeKernel.command({ kind = "BeginWarmup" })
			if started.kind ~= "State" or started.phase ~= "Warmup" then stop() return end
			if selection.kind == "Workload" and caseDefinition.direction == "ServerToClient" then
				if not sendScalar(BENCHMARK_WARMUP_ARMED, currentRepetition) then return end
			end
			local deadline = clock.timeoutNowSeconds() + MAX_WAIT_SECONDS
			while not stopped do
				local current = status()
				if current == nil then return end
				if current.phase == "WarmupDrained" or current.phase == "ControlQuiet"
					or current.phase == "Aborting"
				then break end
				if clock.timeoutNowSeconds() >= deadline then stop() return end
				RunService.PostSimulation:Wait()
			end
			local current = status()
			if current == nil then return end
			local canReportInputMutation = selection.kind == "SeparateProbe"
				or caseDefinition.direction == "ClientToServer"
			send({
				kind = "WarmupReport",
				outcome = if current.phase ~= "Aborting" then "Clean"
					elseif canReportInputMutation then "InputMutation"
					else "Dirty",
			})
		elseif command.kind == "ArmMeasured" then
			activeKernel.command({ kind = "ArmMeasured", startSharedSeconds = command.startSharedSeconds })
			measurementArmed = true
			measuredFrames = 0
			measuredFinishIssued = false
		elseif command.kind == "FinishCase" then
			local frozen = activeState.freeze()
			if frozen.kind ~= "Evidence" then stop() return end
			send({ kind = "FinalReport", snapshot = frozen.value })
			stop()
		end
	end

	table.insert(connections, RunService.PostSimulation:Connect(function()
		if stopped then return end
		local protocolOk, protocolQuiet = pcall(participant.postSimulation)
		if not protocolOk then
			stop()
			return
		end
		local current = status()
		if current ~= nil and currentRepetition > 0 and not controlQuietSent
			and protocolQuiet and current.phase == "ControlQuiet" and current.quietFrames == 60
		then
			controlQuietSent = true
			sendScalar(BENCHMARK_CONTROL_QUIET, currentRepetition)
		end
		if current ~= nil and currentRepetition > 0 and not measuredArmedSent
			and selection.kind == "Workload" and caseDefinition.direction == "ServerToClient"
			and current.phase == "Measured"
		then
			measuredArmedSent = true
			sendScalar(BENCHMARK_MEASURED_ARMED, currentRepetition)
		end
		if current ~= nil and current.phase == "Measured" and selection.kind ~= "SeparateProbe" then
			measuredFrames += 1
			if not measuredFinishIssued and measuredFrames >= caseDefinition.measuredFrames + 1 then
				measuredFinishIssued = true
				local ok = pcall(activeKernel.command, { kind = "FinishMeasured", outcome = "Complete" })
				if not ok then stop() return end
			end
		end
		if current ~= nil and currentRepetition > 0 and measurementArmed and not measuredQuietSent
			and ((current.phase == "Verified" and current.quietFrames == 60) or current.phase == "Aborting")
		then
			measuredQuietSent = true
			sendScalar(
				if current.phase == "Aborting" then BENCHMARK_MEASURED_ABORT else BENCHMARK_MEASURED_QUIET,
				currentRepetition
			)
		end
	end))
	table.insert(connections, control.OnClientEvent:Connect(function(...)
		if stopped then return end
		local count = select("#", ...)
		local scalar = if count >= 1 then select(1, ...) else nil
		local scalarRepetition = if count >= 2 then select(2, ...) else nil
		if scalar == BENCHMARK_BEGIN_TEARDOWN or scalar == BENCHMARK_BEGIN_PRESTART_TEARDOWN
			or scalar == BENCHMARK_ROOT_REMOVED
			or scalar == BENCHMARK_ABORT_SETUP
		then
			if count ~= 2 or scalarRepetition ~= currentRepetition then
				stop()
				return
			end
			if scalar == BENCHMARK_BEGIN_TEARDOWN then
				beginClientTeardown(scalarRepetition, false)
			elseif scalar == BENCHMARK_BEGIN_PRESTART_TEARDOWN then
				beginClientTeardown(scalarRepetition, true)
			elseif scalar == BENCHMARK_ABORT_SETUP then
				abortSetup(scalarRepetition)
			else
				finishRootObservation(scalarRepetition)
			end
			return
		end
		local received = participant.receive(...)
		if received.kind == "MeasuredControlTraffic" then
			if activeState ~= nil and currentRepetition > 0 then
				pcall(activeState.recordFailure, {
					code = "ControlTrafficDuringMeasuredFrames",
					occurrences = 1,
					firstRepetition = currentRepetition,
				})
			end
			if activeKernel ~= nil then
				pcall(activeKernel.command, { kind = "FinishMeasured", outcome = "Abort" })
			end
			return
		end
		if received.kind ~= "Accepted" or commandBusy then
			stop()
			return
		end
		commandBusy = true
		task.spawn(function()
			local ok = pcall(handleCommand, received.command)
			commandBusy = false
			if not ok then stop() end
		end)
	end))
	table.insert(connections, caseFolder.AncestryChanged:Connect(function(_, parent)
		if parent == nil then stop() end
	end))
	local readySent = pcall(function() control:FireServer(StudioProofReports.listenerReady) end)
	if not readySent then stop() end
end

task.spawn(function()
	pcall(run)
end)
