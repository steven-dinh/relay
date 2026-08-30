--!strict

local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local Fixtures = require("../fixtures/event-v1")
local RunState = require("./RunState")
local SessionOwner = require("./SessionOwner")
local TimingRecorder = require("./TimingRecorder")

export type KernelCommand =
	{ kind: "AbortBeforeMeasured" }
	| { kind: "BeginWarmup" }
	| { kind: "ArmMeasured", startSharedSeconds: number }
	| { kind: "FinishMeasured", outcome: "Complete" | "Abort" }

export type AttachResult =
	{ kind: "Clean" }
	| { kind: "PreReadyViolation" }
	| { kind: "SetupFailed" }
	| { kind: "InternalFailed" }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

export type SetupResult =
	{ kind: "Clean" }
	| { kind: "SetupFailed" }
	| { kind: "InternalFailed" }

export type ReadyPollResult =
	{ kind: "Pending" }
	| { kind: "Ready" }
	| { kind: "SetupFailed" }
	| { kind: "InternalFailed" }

export type ArmResult =
	{ kind: "Ready" }
	| { kind: "PreReadyViolation" }
	| { kind: "InternalFailed" }

export type DisableResult =
	{ kind: "Clean" }
	| { kind: "PreReadyViolation" }
	| { kind: "InternalFailed" }

export type CleanupRollbackResult =
	{ kind: "Clean" }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

export type TeardownResult =
	{ kind: "Clean" }
	| { kind: "TeardownFailed" }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

export type Kernel<TSender> = {
	attach: () -> AttachResult,
	setup: () -> SetupResult,
	pollReady: () -> ReadyPollResult,
	arm: () -> ArmResult,
	command: (command: KernelCommand) -> RunState.GenerationStatus,
	status: () -> RunState.GenerationStatus,
	beginTeardownObservation: () -> (),
	teardown: () -> TeardownResult,
	finishTeardownObservation: () -> RunState.GenerationStatus,
	disableForRollback: () -> DisableResult,
	cleanupRollback: () -> CleanupRollbackResult,
}

local WARMUP_TIMEOUT_SECONDS = 120
local DELIVERY_TIMEOUT_SECONDS = 120
local CASE_TIMEOUT_SECONDS = 7_200

local STATE_ERROR = "RUNNER_KERNEL_E_STATE"
local CLEANUP_UNPROVABLE = "SESSION_OWNER_E_CLEANUP_UNPROVABLE"

local CLEAN = table.freeze({ kind = "Clean" })
local PRE_READY_VIOLATION = table.freeze({ kind = "PreReadyViolation" })
local SETUP_FAILED = table.freeze({ kind = "SetupFailed" })
local INTERNAL_FAILED = table.freeze({ kind = "InternalFailed" })
local PENDING = table.freeze({ kind = "Pending" })
local READY = table.freeze({ kind = "Ready" })
local TEARDOWN_FAILED = table.freeze({ kind = "TeardownFailed" })

type CallOutcome = "Returned" | "Threw" | "Yielded"
type Lifecycle =
	"New"
	| "Attached"
	| "SetUp"
	| "Ready"
	| "Armed"
	| "ActivationFailed"
	| "Observing"
	| "TornDown"
	| "Closed"
	| "RollbackDisabled"
	| "RollbackCleaned"

local function failState(): never
	error(STATE_ERROR, 0)
end

local function invokeNonYielding(callback: any, ...: any): (CallOutcome, any?, number)
	local thread = coroutine.create(function(...: any)
		return table.pack(pcall(callback, ...))
	end)
	local results = table.pack(coroutine.resume(thread, ...))
	if results[1] ~= true then
		return "Threw", results[2], 0
	end
	if coroutine.status(thread) ~= "dead" then
		pcall(coroutine.close, thread)
		return "Yielded", nil, 0
	end
	if results.n ~= 2 or type(results[2]) ~= "table" then
		return "Threw", nil, 0
	end
	local call = results[2]
	if call[1] ~= true then
		return "Threw", call[2], 0
	end
	return "Returned", call[2], call.n - 1
end

local function cleanupTermination(): HarnessTerminationV1.HarnessTerminationV1
	return HarnessTerminationV1.new("CleanupFailure", "Finalize")
end

local function terminatedStatus(
	termination: HarnessTerminationV1.HarnessTerminationV1
): RunState.GenerationStatus
	local result: RunState.GenerationStatus = {
		kind = "Terminated",
		termination = termination,
	}
	table.freeze(result)
	return result
end

local function terminatedResult(
	termination: HarnessTerminationV1.HarnessTerminationV1
): { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
	local result = {
		kind = "Terminated" :: "Terminated",
		termination = termination,
	}
	table.freeze(result)
	return result
end

local function exactCommand(candidate: unknown, expectedKeys: { [string]: boolean }, expectedCount: number): boolean
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		return false
	end
	local count = 0
	for key in next, candidate do
		count += 1
		if type(key) ~= "string" or rawget(expectedKeys, key) ~= true then
			return false
		end
	end
	return count == expectedCount
end

local function new<TSender>(
	port: SessionOwner.RuntimePort<TSender>,
	generationState: RunState.GenerationStatePort<TSender>,
	fixture: Fixtures.FixtureSet | Fixtures.ProbeFixtureSet,
	timing: TimingRecorder.Recorder,
	caseState: RunState.CaseState?,
	participantState: RunState.ParticipantState<TSender>?
): Kernel<TSender>
	local lifecycle: Lifecycle = "New"
	local disconnect: SessionOwner.Disconnect? = nil
	local disconnectUnprovable = false
	local setupExclusionOpen = false
	local executionExclusion: TimingRecorder.TimingExclusion? = nil
	local beganWarmup = false
	local callbackHalted = false
	local producerRunning = false
	local forcedStatus: RunState.GenerationStatus? = nil
	local stickyCleanupTermination: HarnessTerminationV1.HarnessTerminationV1? = nil
	local warmupFrameIndex = 0
	local measuredFrameIndex = 0
	local warmupProbeIndex = 0
	local measuredProbeIndex = 0
	local probeOutstandingPhase: ("Warmup" | "Measured")? = nil
	local probeOutstandingIndex: number? = nil
	local shortDeadlineScope: RunState.CoordinatorDeadlineScope? = nil
	local measuredFrameBoundaryOpen = false
	local measuredWorkloadOperations = 0
	local clockFailureLatched = false
	local senderOnlyStaleFired = false

	local selection = port.selection
	local caseDefinition = port.caseDefinition
	local participant = port.participant
	local side = port.side
	local gate = port.delivery
	local isProbe = selection.kind == "SeparateProbe"
	local isServer = participant.role == "Server"
	local isProbeClient = participant.role == "ProbeClient"
	if caseState == nil and (isServer or participantState == nil) then
		failState()
	end
	local isReceiver: boolean
	local isWorkloadSender: boolean
	if selection.kind == "SeparateProbe" then
		isReceiver = true
		isWorkloadSender = false
	else
		isReceiver = (selection.direction == "ClientToServer" and isServer)
			or (selection.direction == "ServerToClient" and not isServer)
		isWorkloadSender = (selection.direction == "ClientToServer" and not isServer)
			or (selection.direction == "ServerToClient" and isServer)
	end
	local senderIndex = if isServer then 1 else (participant :: any).index

	local function latchTermination(termination: HarnessTerminationV1.HarnessTerminationV1)
		if forcedStatus == nil then
			forcedStatus = terminatedStatus(termination)
			if caseState ~= nil then
				caseState.terminate(termination)
			end
		end
		callbackHalted = true
	end

	local function generationStatus(): RunState.GenerationStatus
		if forcedStatus ~= nil then
			return forcedStatus
		end
		return generationState.status()
	end

	local function transition(event: RunState.GenerationEvent): RunState.GenerationStatus
		if forcedStatus ~= nil then
			return forcedStatus
		end
		return generationState.transition(event)
	end

	local function publicTransition(event: RunState.GenerationEvent): RunState.GenerationStatus
		local call = table.pack(pcall(transition, event))
		if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
			failState()
		end
		return call[2]
	end

	local function abortForCurrentStatus()
		local state = generationStatus()
		if state.kind ~= "State" then
			return
		end
		local phase = state.phase
		if phase == "Prepared"
			or phase == "Warmup"
			or phase == "WarmupDrained"
			or phase == "ControlQuiet"
			or phase == "ArmedMeasured"
		then
			pcall(transition, { kind = "AbortBeforeMeasured" })
		elseif phase == "Measured" or phase == "Draining" then
			pcall(transition, { kind = "FinishMeasured", outcome = "Abort" })
		end
	end

	local function latchInternal(stage: "Setup" | "Execution")
		if callbackHalted then
			return
		end
		callbackHalted = true
		local recordFailure = if caseState ~= nil
			then caseState.recordFailure
			else (participantState :: RunState.ParticipantState<TSender>).recordFailure
		local call = table.pack(pcall(recordFailure, {
			code = "InternalError",
			occurrences = 1,
			discriminator = { kind = "Stage", value = stage },
		}))
		if call[1] == true and call.n == 2 then
			local result = call[2]
			if type(result) == "table" and rawget(result, "kind") == "Terminated" then
				latchTermination(rawget(result, "termination"))
			elseif stage == "Execution" and type(result) == "table" then
				abortForCurrentStatus()
			end
		end
	end

	local function latchClockFailure()
		if clockFailureLatched then
			callbackHalted = true
			return
		end
		clockFailureLatched = true
		callbackHalted = true
		if caseState == nil then
			abortForCurrentStatus()
			return
		end
		local call = table.pack(pcall(caseState.recordFailure, {
			code = "ClockProofFailure",
			occurrences = 1,
		}))
		if call[1] == true and call.n == 2 then
			local result = call[2]
			if type(result) == "table" and rawget(result, "kind") == "Terminated" then
				latchTermination(rawget(result, "termination"))
				return
			end
		end
		abortForCurrentStatus()
	end

	local function markTiming(method: (any) -> (), boundary: any): boolean
		local call = table.pack(pcall(method, boundary))
		if call[1] == true and call.n == 1 then
			return true
		end
		if call[1] == false and call[2] == "BENCHMARK_CLOCK_E_VALUE" then
			latchClockFailure()
		else
			latchInternal("Execution")
		end
		return false
	end

	local function closeSetupExclusion(): boolean
		if not setupExclusionOpen then
			return true
		end
		local call = table.pack(pcall(timing.leaveExcluded, "setup"))
		setupExclusionOpen = false
		return call[1] == true and call.n == 2 and type(call[2]) == "boolean"
	end

	local function enterExecutionExclusion(exclusion: TimingRecorder.TimingExclusion): boolean
		if executionExclusion ~= nil then
			return false
		end
		local call = table.pack(pcall(timing.enterExcluded, exclusion))
		if call[1] ~= true or call.n ~= 1 then
			return false
		end
		executionExclusion = exclusion
		return true
	end

	local function leaveExecutionExclusion(expected: TimingRecorder.TimingExclusion): boolean
		if executionExclusion ~= expected then
			return false
		end
		local call = table.pack(pcall(timing.leaveExcluded, expected))
		executionExclusion = nil
		return call[1] == true and call.n == 2 and type(call[2]) == "boolean"
	end

	local function clearShortDeadline()
		local scope = shortDeadlineScope
		if scope == nil then
			return
		end
		shortDeadlineScope = nil
		if caseState == nil then
			return
		end
		local ok = pcall(caseState.clearDeadline, scope)
		if not ok then
			latchInternal("Execution")
		end
	end

	local function timeout(scope: "Warmup" | "Delivery" | "ProbeResponse")
		shortDeadlineScope = nil
		local ok = pcall(generationState.transition, {
			kind = "Timeout",
			scope = scope,
		})
		if not ok then
			latchInternal("Execution")
		elseif scope ~= "Warmup" then
			local factCall = table.pack(pcall(caseState.recordFailure, {
				code = "Timeout",
				occurrences = 1,
				firstRepetition = (fixture :: any).repetitionIndex,
			}))
			if factCall[1] ~= true or factCall.n ~= 2 then
				latchInternal("Execution")
			elseif type(factCall[2]) == "table" and rawget(factCall[2], "kind") == "Terminated" then
				latchTermination(rawget(factCall[2], "termination"))
			end
		end
		callbackHalted = true
	end

	local function clockFailed()
		latchInternal(if beganWarmup then "Execution" else "Setup")
		abortForCurrentStatus()
	end

	local function startShortDeadline(scope: RunState.CoordinatorDeadlineScope): boolean
		if caseState == nil then
			return true
		end
		if shortDeadlineScope ~= nil then
			latchInternal("Execution")
			return false
		end
		local call = table.pack(pcall(caseState.startDeadline, scope))
		if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
			latchInternal(if beganWarmup then "Execution" else "Setup")
			return false
		end
		local kind = rawget(call[2], "kind")
		if kind == "ClockFailed" then
			clockFailed()
			return false
		elseif kind == "Expired" then
			timeout(scope :: any)
			return false
		elseif kind ~= "Active" then
			latchInternal(if beganWarmup then "Execution" else "Setup")
			return false
		end
		shortDeadlineScope = scope
		return true
	end

	local function checkDeadlines(): boolean
		if caseState == nil then
			return true
		end
		local scope = shortDeadlineScope
		if scope ~= nil then
			local call = table.pack(pcall(caseState.checkDeadline, scope))
			if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
				local current = generationStatus()
				if scope == "Delivery" and current.kind == "State" and current.phase == "Verified" then
					shortDeadlineScope = nil
					return true
				end
				clockFailed()
				return false
			end
			local kind = rawget(call[2], "kind")
			if kind == "ClockFailed" then
				clockFailed()
				return false
			elseif kind == "Expired" then
				timeout(scope :: any)
				return false
			elseif kind ~= "Active" then
				latchInternal("Execution")
				return false
			end
		end
		return true
	end

	local function operationFunction(): any
		if isServer then
			return (side :: any).broadcast
		end
		return (side :: any).submit
	end

	local function invokeOperation(
		phase: "Warmup" | "Measured",
		fixtureIndex: number,
		boundary: any,
		operationKind: "Workload" | "ProbeRequest" | "ProbeResponse",
		firstMeasuredWorkloadOperation: boolean?,
		finalMeasuredWorkloadOperation: boolean?
	): boolean
		local phaseFixtures = if phase == "Warmup" then (fixture :: any).warmup else (fixture :: any).measured
		local submission = rawget(phaseFixtures, fixtureIndex)
		if submission == nil then
			latchInternal("Execution")
			return false
		end
		local inputCall = table.pack(pcall(Fixtures.newInput, submission))
		if inputCall[1] ~= true or inputCall.n ~= 2 or type(inputCall[2]) ~= "table" then
			latchInternal("Execution")
			return false
		end
		local startCall = table.pack(pcall(transition, {
			kind = "OperationStarted",
			phase = phase,
			fixtureIndex = fixtureIndex,
		}))
		if startCall[1] ~= true or startCall.n ~= 2 or type(startCall[2]) ~= "table" then
			latchInternal("Execution")
			return false
		end
		if startCall[2].kind == "Terminated" then
			latchTermination(startCall[2].termination)
			return false
		end

		local operation = operationFunction()
		if type(operation) ~= "function" then
			latchInternal("Execution")
			return false
		end
		local timingOk = true
		local operationResultCount: number? = nil
		local outcome, _, resultCount = invokeNonYielding(function()
			if phase == "Measured" then
				if operationKind == "Workload" and firstMeasuredWorkloadOperation then
					timingOk = markTiming(timing.markLocal, "FirstMeasuredSubmissionStarted")
					if timingOk then
						timingOk = markTiming(timing.markShared, "FirstMeasuredSubmissionStarted")
					end
				elseif operationKind == "ProbeRequest" then
					timingOk = markTiming(timing.markLocal, "RoundTripSubmissionStarted")
				end
				if not timingOk then
					return
				end
			end

			if phase == "Measured" and operationKind == "Workload" then
				timingOk = markTiming(timing.markLocal, "MeasuredSubmissionStarted")
				if not timingOk then
					return
				end
			end

			local operationResults = table.pack(operation(inputCall[2], boundary))
			operationResultCount = operationResults.n
			if operationResultCount ~= 0 then
				return
			end

			if phase == "Measured" and operationKind == "Workload" then
				timingOk = markTiming(timing.markLocal, "MeasuredSubmissionReturned")
				if finalMeasuredWorkloadOperation and timingOk then
					timingOk = markTiming(timing.markLocal, "FinalMeasuredSubmissionReturned")
					if timingOk then
						timingOk = markTiming(timing.markShared, "FinalMeasuredSubmissionReturned")
					end
				end
			end
		end)
		if outcome ~= "Returned"
			or resultCount ~= 0
			or (operationResultCount ~= nil and operationResultCount ~= 0)
		then
			pcall(transition, {
				kind = "OperationFailed",
				phase = phase,
			})
			callbackHalted = true
			return false
		end
		if operationResultCount == nil then
			return false
		end
		local returnCall = table.pack(pcall(transition, {
			kind = "OperationReturned",
			phase = phase,
			fixtureIndex = fixtureIndex,
		}))
		if returnCall[1] ~= true or returnCall.n ~= 2 or type(returnCall[2]) ~= "table" then
			latchInternal("Execution")
			return false
		end
		if returnCall[2].kind == "Terminated" then
			latchTermination(returnCall[2].termination)
			return false
		end
		return timingOk
	end

	local function submitWorkloadFrame(phase: "Warmup" | "Measured"): boolean
		if not isWorkloadSender then
			return true
		end
		local workload: any = caseDefinition
		local frameIndex: number
		if phase == "Warmup" then
			if warmupFrameIndex >= workload.warmupFrames then
				return true
			end
			warmupFrameIndex += 1
			frameIndex = warmupFrameIndex
		else
			if measuredFrameIndex >= workload.measuredFrames then
				return true
			end
			measuredFrameIndex += 1
			frameIndex = measuredFrameIndex
		end

		local submissionsPerFrame = workload.senderCount * workload.messagesPerFrame
		local firstFixtureIndex = (frameIndex - 1) * submissionsPerFrame
			+ (senderIndex - 1) * workload.messagesPerFrame
			+ 1
		for messageIndex = 1, workload.messagesPerFrame do
			local fixtureIndex = firstFixtureIndex + messageIndex - 1
			local boundary = if messageIndex == workload.messagesPerFrame
				then "FlushBeforeReturn"
				else "ContinueFrame"
			local firstMeasured = phase == "Measured" and measuredWorkloadOperations == 0
			local finalMeasured = phase == "Measured"
				and frameIndex == workload.measuredFrames
				and messageIndex == workload.messagesPerFrame
			if not invokeOperation(
				phase,
				fixtureIndex,
				boundary,
				"Workload",
				firstMeasured,
				finalMeasured
			) then
				return false
			end
			if phase == "Measured" then
				measuredWorkloadOperations += 1
			end
		end

		if phase == "Measured" and frameIndex == workload.measuredFrames then
			startShortDeadline("Delivery")
		end
		return true
	end

	local function submitProbe(phase: "Warmup" | "Measured"): boolean
		if not isProbeClient or probeOutstandingIndex ~= nil then
			return true
		end
		local probe: any = caseDefinition
		local fixtureIndex: number
		if phase == "Warmup" then
			if warmupProbeIndex >= probe.warmupSamples then
				return true
			end
			warmupProbeIndex += 1
			fixtureIndex = warmupProbeIndex
		else
			if measuredProbeIndex >= probe.measuredSamples then
				return true
			end
			measuredProbeIndex += 1
			fixtureIndex = measuredProbeIndex
		end

		probeOutstandingPhase = phase
		probeOutstandingIndex = fixtureIndex
		if not invokeOperation(phase, fixtureIndex, "FlushBeforeReturn", "ProbeRequest") then
			probeOutstandingPhase = nil
			probeOutstandingIndex = nil
			return false
		end
		if phase == "Measured" and probeOutstandingIndex ~= nil then
			startShortDeadline("ProbeResponse")
		end
		return true
	end

	local function handleProbeResponse(fixtureIndex: number)
		if not isProbe or not isServer or type(fixtureIndex) ~= "number" then
			latchInternal("Execution")
			return
		end
		local state = generationStatus()
		if state.kind ~= "State" then
			return
		end
		local phase = if state.phase == "Warmup" then "Warmup" else "Measured"
		invokeOperation(phase, fixtureIndex, "FlushBeforeReturn", "ProbeResponse")
	end

	local function handleAcceptedProbeResponse(fixtureIndex: number)
		if not isProbeClient
			or type(fixtureIndex) ~= "number"
			or fixtureIndex ~= probeOutstandingIndex
			or probeOutstandingPhase == nil
		then
			latchInternal("Execution")
			return
		end
		local wasMeasured = probeOutstandingPhase == "Measured"
		probeOutstandingPhase = nil
		probeOutstandingIndex = nil
		if wasMeasured then
			clearShortDeadline()
		end
	end

	local function receivingDelivery(argumentCount: number, delivery: unknown, metadata: unknown)
		if callbackHalted then
			return
		end
		local call = table.pack(pcall(generationState.observeDelivery, argumentCount, delivery, metadata))
		if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
			latchInternal("Execution")
			return
		end
		local action = call[2]
		local kind = rawget(action, "kind")
		if kind == "ProbeResponse" then
			handleProbeResponse(rawget(action, "fixtureIndex"))
		elseif kind == "ProbeResponseAccepted" then
			handleAcceptedProbeResponse(rawget(action, "fixtureIndex"))
		elseif kind == "ClockProofFailed" then
			latchClockFailure()
		elseif kind ~= "None" then
			latchInternal("Execution")
		end
		local current = generationStatus()
		if current.kind == "State" and current.phase == "Verified" and executionExclusion == nil then
			if not enterExecutionExclusion("quiescence") then
				latchInternal("Execution")
			end
		end
	end

	local function senderOnlyDelivery(_argumentCount: number, _delivery: unknown, _metadata: unknown)
		local stage = if beganWarmup then "Execution" else "Setup"
		pcall(gate.disable)
		latchTermination(HarnessTerminationV1.new("IngressLimitExceeded", stage))
	end

	local function receivingDeliveryHandler(argumentCount: number, delivery: unknown, metadata: unknown)
		if callbackHalted then
			return
		end
		local ok = pcall(receivingDelivery, argumentCount, delivery, metadata)
		if not ok then
			pcall(latchInternal, "Execution")
		end
	end

	local function senderOnlyDeliveryHandler(_argumentCount: number, _delivery: unknown, _metadata: unknown)
		local ok = pcall(senderOnlyDelivery)
		if not ok then
			pcall(latchInternal, if beganWarmup then "Execution" else "Setup")
		end
	end

	local function senderOnlyStaleHandler()
		if senderOnlyStaleFired then
			return
		end
		senderOnlyStaleFired = true
		local ok = pcall(function()
			pcall(gate.disable)
			latchTermination(HarnessTerminationV1.new("IngressLimitExceeded", "Execution"))
		end)
		if not ok then
			pcall(latchInternal, "Execution")
		end
	end

	local deliveryHandler = if isReceiver then receivingDeliveryHandler else senderOnlyDeliveryHandler

	local function producerBody()
		if lifecycle ~= "Armed" or callbackHalted then
			return
		end
		if not checkDeadlines() then
			return
		end

		local before = generationStatus()
		if before.kind ~= "State" then
			callbackHalted = true
			return
		end
		local after: RunState.GenerationStatus
		if before.phase == "ArmedMeasured" then
			after = transition({ kind = "BeginMeasured" })
			if after.kind ~= "State" then
				callbackHalted = true
				return
			end
			if isServer then
				local coordinator = caseState :: RunState.CaseState
				local progressCall = table.pack(pcall(coordinator.transition, {
					kind = "MeasuredStarted",
					repetitionIndex = (fixture :: any).repetitionIndex,
				}))
				if progressCall[1] ~= true or progressCall.n ~= 2 or type(progressCall[2]) ~= "table" then
					latchInternal("Execution")
					return
				end
				if progressCall[2].kind == "Terminated" then
					latchTermination(progressCall[2].termination)
					return
				end
			end
		else
			after = transition({ kind = "PostSimulation" })
			if after.kind ~= "State" then
				callbackHalted = true
				return
			end

			if before.phase == "WarmupDrained" and after.phase == "ControlQuiet" then
				if not leaveExecutionExclusion("warmup") or not enterExecutionExclusion("quiescence") then
					latchInternal("Execution")
					return
				end
			end
		end

		if isWorkloadSender and measuredFrameBoundaryOpen then
			if not markTiming(timing.markLocal, "FollowingFrameStarted") then
				return
			end
			measuredFrameBoundaryOpen = false
		end

		if after.phase == "Warmup" then
			if isProbe then
				submitProbe("Warmup")
			else
				submitWorkloadFrame("Warmup")
			end
		elseif after.phase == "Measured" then
			if isProbe then
				submitProbe("Measured")
			else
				local workload: any = caseDefinition
				if isWorkloadSender and measuredFrameIndex < workload.measuredFrames then
					if not markTiming(timing.markLocal, "MeasuredFrameStarted") then
						return
					end
					measuredFrameBoundaryOpen = true
				end
				submitWorkloadFrame("Measured")
			end
		end
	end

	local function producer()
		if producerRunning or callbackHalted then
			return
		end
		producerRunning = true
		local ok = pcall(producerBody)
		producerRunning = false
		if not ok then
			latchInternal(if beganWarmup then "Execution" else "Setup")
		end
	end

	local function attach(): AttachResult
		if lifecycle ~= "New" then
			failState()
		end

		local exclusionCall = table.pack(pcall(timing.enterExcluded, "setup"))
		if exclusionCall[1] ~= true or exclusionCall.n ~= 1 then
			lifecycle = "ActivationFailed"
			return INTERNAL_FAILED :: any
		end
		setupExclusionOpen = true

		local connect = port.postSimulation.connectPostSimulation
		local outcome, candidate, resultCount = invokeNonYielding(connect, producer)
		if outcome == "Threw" then
			lifecycle = "ActivationFailed"
			return SETUP_FAILED :: any
		elseif outcome ~= "Returned" or type(candidate) ~= "function" then
			disconnectUnprovable = true
			stickyCleanupTermination = cleanupTermination()
			lifecycle = "ActivationFailed"
			return terminatedResult(stickyCleanupTermination) :: any
		end
		disconnect = candidate
		if resultCount ~= 1 then
			lifecycle = "ActivationFailed"
			return INTERNAL_FAILED :: any
		end

		local bindCall = table.pack(pcall(gate.bind, deliveryHandler))
		if bindCall[1] ~= true or bindCall.n ~= 2 or type(bindCall[2]) ~= "boolean" then
			lifecycle = "ActivationFailed"
			return INTERNAL_FAILED :: any
		elseif bindCall[2] == false then
			lifecycle = "ActivationFailed"
			return PRE_READY_VIOLATION :: any
		end
		lifecycle = "Attached"
		return CLEAN :: any
	end

	local function setup(): SetupResult
		if lifecycle ~= "Attached" or stickyCleanupTermination ~= nil then
			failState()
		end
		local outcome, _, resultCount = invokeNonYielding(side.setup)
		if outcome ~= "Returned" or resultCount ~= 0 then
			lifecycle = "ActivationFailed"
			return SETUP_FAILED :: any
		end
		lifecycle = "SetUp"
		return CLEAN :: any
	end

	local function pollReady(): ReadyPollResult
		if lifecycle ~= "SetUp" then
			failState()
		end
		local outcome, value, resultCount = invokeNonYielding(side.ready)
		if outcome ~= "Returned" or resultCount ~= 1 or type(value) ~= "boolean" then
			lifecycle = "ActivationFailed"
			return SETUP_FAILED :: any
		elseif value == false then
			return PENDING :: any
		end
		lifecycle = "Ready"
		return READY :: any
	end

	local function arm(): ArmResult
		if lifecycle ~= "Ready" then
			failState()
		end
		local armCall = table.pack(pcall(gate.arm))
		if armCall[1] ~= true or armCall.n ~= 2 or type(armCall[2]) ~= "boolean" then
			lifecycle = "ActivationFailed"
			return INTERNAL_FAILED :: any
		elseif armCall[2] == false then
			lifecycle = "ActivationFailed"
			return PRE_READY_VIOLATION :: any
		end
		if not closeSetupExclusion() then
			lifecycle = "ActivationFailed"
			return INTERNAL_FAILED :: any
		end
		lifecycle = "Armed"
		return READY :: any
	end

	local function command(commandCandidate: KernelCommand): RunState.GenerationStatus
		if lifecycle ~= "Armed" or forcedStatus ~= nil then
			failState()
		end
		local command: any = commandCandidate
		local kind = if type(command) == "table" then rawget(command, "kind") else nil
		if kind == "AbortBeforeMeasured" then
			if not exactCommand(command, { kind = true }, 1) then
				failState()
			end
			local current = generationStatus()
			if current.kind ~= "State"
				or (current.phase ~= "Prepared"
					and current.phase ~= "Warmup"
					and current.phase ~= "WarmupDrained"
					and current.phase ~= "ControlQuiet"
					and current.phase ~= "ArmedMeasured")
			then
				failState()
			end
			callbackHalted = true
			return publicTransition({ kind = "AbortBeforeMeasured" })
		elseif kind == "BeginWarmup" then
			if beganWarmup or not exactCommand(command, { kind = true }, 1) then
				failState()
			end
			if not enterExecutionExclusion("warmup") then
				failState()
			end
			local result = publicTransition({ kind = "BeginWarmup" })
			beganWarmup = true
			if isServer then
				if not startShortDeadline("Warmup") then
					return generationStatus()
				end
			end
			return result
		elseif kind == "ArmMeasured" then
			if not beganWarmup
				or not exactCommand(command, { kind = true, startSharedSeconds = true }, 2)
				or not leaveExecutionExclusion("quiescence")
			then
				failState()
			end
			local result = publicTransition({
				kind = "ArmMeasured",
				startSharedSeconds = rawget(command, "startSharedSeconds"),
			})
			if isServer and result.kind == "State" and result.phase == "ArmedMeasured" then
				clearShortDeadline()
				return generationStatus()
			end
			return result
		elseif kind == "FinishMeasured" then
			if not beganWarmup or not exactCommand(command, { kind = true, outcome = true }, 2) then
				failState()
			end
			local outcome = rawget(command, "outcome")
			if outcome ~= "Complete" and outcome ~= "Abort" then
				failState()
			end
			local result = publicTransition({ kind = "FinishMeasured", outcome = outcome })
			if result.kind == "State" and result.phase == "Verified" then
				if not enterExecutionExclusion("quiescence") then
					latchInternal("Execution")
				end
				return generationStatus()
			end
			return result
		end
		failState()
	end

	local function status(): RunState.GenerationStatus
		return generationStatus()
	end

	local function disconnectProducer(): boolean
		local current = disconnect
		disconnect = nil
		if current == nil then
			return not disconnectUnprovable
		end
		local outcome, _, resultCount = invokeNonYielding(current)
		return outcome == "Returned" and resultCount == 0
	end

	local function beginTeardownObservation()
		if lifecycle ~= "Armed" then
			failState()
		end
		if executionExclusion ~= nil then
			local exclusion = executionExclusion
			if not leaveExecutionExclusion(exclusion) then
				latchInternal("Execution")
			end
		end
		clearShortDeadline()
		local transitionCall = table.pack(pcall(transition, { kind = "BeginTeardown" }))
		if transitionCall[1] ~= true or transitionCall.n ~= 2 then
			latchInternal("Execution")
		end
		local staleHandler = if isReceiver then generationState.staleHandler else senderOnlyStaleHandler
		local observeCall = table.pack(pcall(gate.beginTeardownObservation, staleHandler))
		if observeCall[1] ~= true or observeCall.n ~= 1 then
			latchInternal("Execution")
		end
		lifecycle = "Observing"
		if not disconnectProducer() then
			stickyCleanupTermination = stickyCleanupTermination or cleanupTermination()
		end
	end

	local function teardown(): TeardownResult
		if lifecycle ~= "Observing" then
			failState()
		end
		local outcome, detail, resultCount = invokeNonYielding(side.teardown)
		local clean = outcome == "Returned" and resultCount == 0
		if outcome == "Yielded"
			or (outcome == "Returned" and resultCount ~= 0)
			or (outcome == "Threw" and detail == CLEANUP_UNPROVABLE)
		then
			stickyCleanupTermination = stickyCleanupTermination or cleanupTermination()
		end
		local transitionCall = table.pack(pcall(transition, {
			kind = "FinishTeardown",
			clean = clean,
		}))
		local transitionStatus: RunState.GenerationStatus? = nil
		if transitionCall[1] ~= true or transitionCall.n ~= 2 or type(transitionCall[2]) ~= "table" then
			latchInternal("Execution")
		else
			transitionStatus = transitionCall[2]
		end
		lifecycle = "TornDown"
		if stickyCleanupTermination ~= nil then
			return terminatedResult(stickyCleanupTermination) :: any
		elseif transitionStatus ~= nil and transitionStatus.kind == "Terminated" then
			return terminatedResult(transitionStatus.termination) :: any
		elseif not clean then
			return TEARDOWN_FAILED :: any
		end
		return CLEAN :: any
	end

	local function finishTeardownObservation(): RunState.GenerationStatus
		if lifecycle ~= "TornDown" then
			failState()
		end
		local result = publicTransition({ kind = "FinishTeardownObservation" })
		lifecycle = "Closed"
		return result
	end

	local function disableForRollback(): DisableResult
		if lifecycle == "RollbackDisabled" or lifecycle == "RollbackCleaned"
			or lifecycle == "Observing" or lifecycle == "TornDown" or lifecycle == "Closed"
		then
			failState()
		end
		local call = table.pack(pcall(gate.disable))
		lifecycle = "RollbackDisabled"
		if call[1] ~= true or call.n ~= 2 then
			return INTERNAL_FAILED :: any
		elseif call[2] == "PreReadyViolation" then
			return PRE_READY_VIOLATION :: any
		elseif call[2] ~= "Clean" then
			return INTERNAL_FAILED :: any
		end
		return CLEAN :: any
	end

	local function cleanupRollback(): CleanupRollbackResult
		if lifecycle ~= "RollbackDisabled" then
			failState()
		end
		local clean = disconnectProducer()
		local outcome, _, resultCount = invokeNonYielding(side.teardown)
		if outcome ~= "Returned" or resultCount ~= 0 then
			clean = false
		end
		if not closeSetupExclusion() then
			clean = false
		end
		lifecycle = "RollbackCleaned"
		if not clean or stickyCleanupTermination ~= nil then
			stickyCleanupTermination = stickyCleanupTermination or cleanupTermination()
			return terminatedResult(stickyCleanupTermination) :: any
		end
		return CLEAN :: any
	end

	local kernel: Kernel<TSender> = {
		attach = attach,
		setup = setup,
		pollReady = pollReady,
		arm = arm,
		command = command,
		status = status,
		beginTeardownObservation = beginTeardownObservation,
		teardown = teardown,
		finishTeardownObservation = finishTeardownObservation,
		disableForRollback = disableForRollback,
		cleanupRollback = cleanupRollback,
	}
	table.freeze(kernel)
	return kernel
end

local RunnerKernel = {
	WARMUP_TIMEOUT_SECONDS = WARMUP_TIMEOUT_SECONDS,
	DELIVERY_TIMEOUT_SECONDS = DELIVERY_TIMEOUT_SECONDS,
	CASE_TIMEOUT_SECONDS = CASE_TIMEOUT_SECONDS,
	new = new,
}

table.freeze(RunnerKernel)

return RunnerKernel
