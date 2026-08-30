--!strict

local AdapterContract = require("../adapters/AdapterContract")
local ResultV1 = require("../contracts/result-v1")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local Fixtures = require("../fixtures/event-v1")
local BenchmarkClock = require("./BenchmarkClock")
local GenerationActivation = require("./GenerationActivation")
local KernelFanout = require("./KernelFanout")
local ResultDraftAssembler = require("./ResultDraftAssembler")
local RunState = require("./RunState")
local RunnerKernel = require("./RunnerKernel")
local SessionOwner = require("./SessionOwner")
local TimingRecorder = require("./TimingRecorder")

export type StepResult =
	{ kind: "Continue" }
	| { kind: "NeedsFrame" }
	| { kind: "GenerationClosed", repetitionIndex: number }
	| { kind: "Result", value: ResultV1.Result }
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }

export type Runner = {
	step: () -> StepResult,
	resumeAfterFrame: () -> StepResult,
	confirmGenerationReset: () -> StepResult,
	rejectGenerationReset: () -> StepResult,
}

local CONFIG_ERROR = "CASE_RUNNER_E_CONFIG"
local STATE_ERROR = "CASE_RUNNER_E_STATE"

local CONTINUE: StepResult = table.freeze({ kind = "Continue" }) :: any
local NEEDS_FRAME: StepResult = table.freeze({ kind = "NeedsFrame" }) :: any

type Lifecycle =
	"New"
	| "OpenGeneration"
	| "Activating"
	| "ClockProof"
	| "BeginWarmup"
	| "Running"
	| "Observation"
	| "ResetBarrier"
	| "Finalize"
	| "Terminal"

type FramePurpose = "Generation" | "Observation"

type CallOutcome = "Returned" | "Threw" | "Yielded"

local function fail(code: string): never
	error(code, 0)
end

local function invokeNonYielding(callback: any, ...: any): (CallOutcome, any?, number, any?)
	local thread = coroutine.create(callback)
	local results = table.pack(coroutine.resume(thread, ...))
	if results[1] ~= true then
		return "Threw", nil, 0, results[2]
	end
	if coroutine.status(thread) ~= "dead" then
		pcall(coroutine.close, thread)
		return "Yielded", nil, 0, nil
	end
	return "Returned", results[2], results.n - 1, nil
end

local function isExactFactory(candidate: unknown): boolean
	if type(candidate) ~= "table" or getmetatable(candidate :: any) ~= nil then
		return false
	end
	local count = 0
	for key in next, candidate :: any do
		count += 1
		if key ~= "constructServer" and key ~= "constructClient" then
			return false
		end
	end
	return count == 2
		and type(rawget(candidate :: any, "constructServer")) == "function"
		and type(rawget(candidate :: any, "constructClient")) == "function"
end

local function isUuid(value: unknown): boolean
	return type(value) == "string"
		and string.match(
			value,
			"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
		) ~= nil
end

local function frozenResult(value: any): StepResult
	table.freeze(value)
	return value
end

local function new<TResource, TSender>(
	preparedCandidate: SessionOwner.PreparedSession<TSender>,
	adapterFactory: AdapterContract.AdapterFactory<TResource, TSender>,
	generationRootFactory: SessionOwner.GenerationRootFactory<TResource>,
	runId: string
): Runner
	-- The private preparation brand is deliberately checked before any public
	-- field or caller-supplied function is inspected.
	local prepared = SessionOwner.requirePrepared(preparedCandidate)
	if not isExactFactory(adapterFactory) or type(generationRootFactory) ~= "function" or not isUuid(runId) then
		fail(CONFIG_ERROR)
	end

	local lifecycle: Lifecycle = "New"
	local waitingForFrame: FramePurpose? = nil
	local repetitionIndex = 1
	local pendingResetRepetition: number? = nil
	local abortProgressPending = false
	local measuredFramesObserved = 0
	local measuredFinishIssued = false
	local deliveryDeadlineCleared = false
	local repetitionWasStarted = false
	local repetitionWasCompleted = false

	local serverClock: BenchmarkClock.Clock? = nil
	local participantClocks: { BenchmarkClock.Clock }? = nil
	local participantStates: { RunState.ParticipantState<TSender> }? = nil
	local timingRecorders: { TimingRecorder.Recorder }? = nil
	local caseState: RunState.CaseState? = nil
	local session: SessionOwner.ReadyResult<TSender>? = nil
	local activation: GenerationActivation.Activation<TSender>? = nil
	local kernels: { RunnerKernel.Kernel<TSender> }? = nil
	local terminalTermination: HarnessTerminationV1.HarnessTerminationV1? = nil
	local terminalResult: ResultV1.Result? = nil
	local armSharedSeconds: number? = nil
	local clockProofRecorded = false
	local executionInvariantRecorded = false

	local function setTermination(termination: HarnessTerminationV1.HarnessTerminationV1)
		local current = terminalTermination
		local cleanupOverrides = termination.code == "CleanupFailure"
			and (current == nil or current.code ~= "CleanupFailure")
		if current == nil or cleanupOverrides then
			terminalTermination = termination
			if current == nil and caseState ~= nil then
				pcall((caseState :: RunState.CaseState).terminate, termination)
			end
		end
	end

	local function fixedTermination(
		code: HarnessTerminationV1.Code,
		stage: HarnessTerminationV1.Stage
	): HarnessTerminationV1.HarnessTerminationV1
		return HarnessTerminationV1.new(code, stage)
	end

	local function terminalStep(): StepResult
		lifecycle = "Terminal"
		if terminalTermination ~= nil then
			return frozenResult({ kind = "Terminated", termination = terminalTermination })
		end
		if terminalResult ~= nil then
			return frozenResult({ kind = "Result", value = terminalResult })
		end
		fail(STATE_ERROR)
	end

	local function recordCoordinatorFailure(fact: RunState.CoordinatorFailureFactV1): boolean
		local state = caseState
		if state == nil then
			return false
		end
		local outcome, value, count = invokeNonYielding(state.recordFailure, fact)
		if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
			return false
		end
		if rawget(value :: any, "kind") == "Terminated" then
			setTermination(rawget(value :: any, "termination"))
			return false
		end
		return rawget(value :: any, "kind") == "Recorded"
	end

	local function recordExecutionInvariant(fact: RunState.CoordinatorFailureFactV1)
		if terminalTermination == nil and not executionInvariantRecorded then
			executionInvariantRecorded = true
			recordCoordinatorFailure(fact)
		end
	end

	local function transitionCase(event: RunState.CaseEvent): boolean
		local state = caseState
		if state == nil then
			return false
		end
		local outcome, value, count = invokeNonYielding(state.transition, event)
		if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return false
		end
		if rawget(value :: any, "kind") == "Terminated" then
			setTermination(rawget(value :: any, "termination"))
			return false
		end
		return true
	end

	local function buildCaseOwners()
		local clocks = table.create(prepared.selection.clientProcessCount + 1)
		clocks[1] = serverClock :: BenchmarkClock.Clock
		for index, runtimeInput in prepared.runtimeInputs.clients do
			clocks[index + 1] = BenchmarkClock.new(runtimeInput.clocks)
		end
		table.freeze(clocks)
		participantClocks = clocks

		local states = table.create(#clocks)
		states[1] = RunState.newParticipant(prepared.selection, { role = "Server" })
		local clientRole = if prepared.selection.kind == "SeparateProbe" then "ProbeClient" else "Client"
		for index = 1, prepared.selection.clientProcessCount do
			states[index + 1] = RunState.newParticipant(prepared.selection, {
				role = clientRole,
				index = index,
			})
		end
		table.freeze(states)
		participantStates = states

		local recorders = table.create(#clocks)
		for index, clock in clocks do
			recorders[index] = TimingRecorder.new(prepared.caseDefinition, states[index].participant, clock)
		end
		table.freeze(recorders)
		timingRecorders = recorders
	end

	local function generateFixture(): Fixtures.FixtureSet | Fixtures.ProbeFixtureSet
		if prepared.selection.kind == "SeparateProbe" then
			return Fixtures.generateProbe(prepared.selection.probeId, repetitionIndex)
		end
		return Fixtures.generate(prepared.selection.workloadId, repetitionIndex)
	end

	local function beginActivation(readySession: SessionOwner.ReadyResult<TSender>): boolean
		local states = participantStates :: { RunState.ParticipantState<TSender> }
		local recorders = timingRecorders :: { TimingRecorder.Recorder }

		local fixture = generateFixture()
		activation = GenerationActivation.begin(readySession, caseState :: RunState.CaseState, states, fixture, recorders)
		lifecycle = "Activating"
		return true
	end

	local function cleanupUnadoptedReady(candidate: any)
		if rawget(candidate, "kind") ~= "Ready" then
			return
		end
		local cleanupFailed = false
		local ports = rawget(candidate, "ports")
		if type(ports) ~= "table" then
			cleanupFailed = true
		else
			for _, port in ports do
				local gate = if type(port) == "table" then rawget(port, "delivery") else nil
				local disable = if type(gate) == "table" then rawget(gate, "disable") else nil
				local outcome, value, count = invokeNonYielding(disable)
				if outcome ~= "Returned" or count ~= 1 or value ~= "Clean" then
					cleanupFailed = true
				end
			end
			for index = #ports, 1, -1 do
				local port = ports[index]
				local side = if type(port) == "table" then rawget(port, "side") else nil
				local teardown = if type(side) == "table" then rawget(side, "teardown") else nil
				local outcome, _, count = invokeNonYielding(teardown)
				if outcome ~= "Returned" or count ~= 0 then
					cleanupFailed = true
				end
			end
		end

		local closeRoot = rawget(candidate, "closeGenerationRoot")
		local outcome, value, count = invokeNonYielding(closeRoot)
		if outcome ~= "Returned" or count ~= 1 then
			cleanupFailed = true
		elseif value ~= nil then
			setTermination(value :: HarnessTerminationV1.HarnessTerminationV1)
		end
		if cleanupFailed then
			setTermination(fixedTermination("CleanupFailure", "Finalize"))
		end
	end

	local function openGeneration(): StepResult
		local state = caseState :: RunState.CaseState
		local openOutcome, openValue, openCount = invokeNonYielding(
			SessionOwner.openPrepared,
			prepared,
			adapterFactory,
			generationRootFactory
		)
		if openOutcome ~= "Returned" or openCount ~= 1 or type(openValue) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		local kind = rawget(openValue :: any, "kind")

		local acceptOutcome, acceptValue, acceptCount = invokeNonYielding(state.acceptSession, repetitionIndex, openValue)
		if acceptOutcome ~= "Returned" or acceptCount ~= 1 or type(acceptValue) ~= "table" then
			cleanupUnadoptedReady(openValue)
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		if rawget(acceptValue :: any, "kind") == "Terminated" then
			setTermination(rawget(acceptValue :: any, "termination"))
			cleanupUnadoptedReady(openValue)
			return terminalStep()
		end

		if participantStates == nil then
			local ok = pcall(buildCaseOwners)
			if not ok then
				cleanupUnadoptedReady(openValue)
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
		end

		if kind == "Ready" then
			local readySession = openValue :: SessionOwner.ReadyResult<TSender>
			local ok = pcall(beginActivation, readySession)
			if not ok then
				cleanupUnadoptedReady(openValue)
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
			session = readySession
			return CONTINUE
		elseif kind == "SetupFailed" or kind == "InternalFailed" then
			lifecycle = "Finalize"
			return CONTINUE
		end
		setTermination(fixedTermination("FinalizationFailure", "Finalize"))
		return terminalStep()
	end

	local function freezeAndFinalize(): StepResult
		local states = participantStates
		local state = caseState
		if states == nil or state == nil then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end

		local participantSnapshots = table.create(#states)
		for index, participantState in states do
			local outcome, value, count = invokeNonYielding(participantState.freeze)
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
			if rawget(value :: any, "kind") == "Terminated" then
				setTermination(rawget(value :: any, "termination"))
				return terminalStep()
			end
			local snapshot = {
				participant = participantState.participant,
				evidence = rawget(value :: any, "value"),
			}
			table.freeze(snapshot)
			participantSnapshots[index] = snapshot
		end
		table.freeze(participantSnapshots)
		local snapshotOutcome, snapshotValue, snapshotCount = invokeNonYielding(state.snapshot, participantSnapshots)
		if snapshotOutcome ~= "Returned" or snapshotCount ~= 1 or type(snapshotValue) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		if rawget(snapshotValue :: any, "kind") == "Terminated" then
			setTermination(rawget(snapshotValue :: any, "termination"))
			return terminalStep()
		end

		local assembleInput = {
			runId = runId,
			manifest = prepared.manifest,
			snapshot = rawget(snapshotValue :: any, "value"),
		}
		table.freeze(assembleInput)
		local assembleOutcome, assembleValue, assembleCount = invokeNonYielding(ResultDraftAssembler.assemble, assembleInput)
		if assembleOutcome ~= "Returned" or assembleCount ~= 1 or type(assembleValue) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		if rawget(assembleValue :: any, "kind") == "Terminated" then
			setTermination(rawget(assembleValue :: any, "termination"))
			return terminalStep()
		end

		-- This is the sole production Result V1 finalization call. Validation is
		-- deliberately separate and cannot recursively finalize a rejected value.
		local finalizeOutcome, finalized, finalizeCount = invokeNonYielding(
			ResultV1.finalize,
			rawget(assembleValue :: any, "value")
		)
		if finalizeOutcome ~= "Returned" or finalizeCount ~= 1 or type(finalized) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		local validateOutcome, validated, validateCount = invokeNonYielding(ResultV1.validate, finalized)
		if validateOutcome ~= "Returned" or validateCount ~= 1 or type(validated) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		terminalResult = validated :: ResultV1.Result
		return terminalStep()
	end

	local function statusSnapshot(): ({ RunState.GenerationStatus }, boolean)
		local current = kernels
		if current == nil then
			fail(STATE_ERROR)
		end
		local statuses = table.create(#current)
		local terminated = false
		for index, kernel in current do
			local outcome, value, count = invokeNonYielding(kernel.status)
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				terminated = true
				break
			end
			statuses[index] = value :: RunState.GenerationStatus
			if rawget(value :: any, "kind") == "Terminated" then
				setTermination(rawget(value :: any, "termination"))
				terminated = true
			end
		end
		return statuses, terminated
	end

	local function commandAll(command: RunnerKernel.KernelCommand): boolean
		local current = kernels
		if current == nil then
			return false
		end
		return KernelFanout.commandAll(current, command, recordExecutionInvariant, setTermination)
	end

	local function abortAllKernels(): boolean
		local current = kernels
		if current == nil then
			return false
		end
		return KernelFanout.abortAllKernels(current, recordExecutionInvariant, setTermination)
	end

	local function closeGeneration(): StepResult
		local current = kernels
		local readySession = session
		if current == nil or readySession == nil then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end

		for _, kernel in current do
			local outcome, _, count = invokeNonYielding(kernel.beginTeardownObservation)
			if outcome ~= "Returned" or count ~= 0 then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			end
		end
		for index = #current, 1, -1 do
			local outcome, value, count = invokeNonYielding(current[index].teardown)
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
				setTermination(fixedTermination("CleanupFailure", "Finalize"))
			elseif rawget(value :: any, "kind") == "Terminated" then
				setTermination(rawget(value :: any, "termination"))
			end
		end
		local rootOutcome, rootValue, rootCount = invokeNonYielding(readySession.closeGenerationRoot)
		if rootOutcome ~= "Returned" or rootCount ~= 1 then
			setTermination(fixedTermination("CleanupFailure", "Finalize"))
		elseif rootValue ~= nil then
			setTermination(rootValue :: HarnessTerminationV1.HarnessTerminationV1)
		end

		lifecycle = "Observation"
		waitingForFrame = "Observation"
		return NEEDS_FRAME
	end

	local function abortCurrentGeneration(): StepResult
		if kernels ~= nil then
			abortAllKernels()
		end
		if terminalTermination == nil and caseState ~= nil then
			abortProgressPending = true
		end
		return closeGeneration()
	end

	local function recordClockProofs(): "Passed" | "ClockFailed" | "InternalFailed"
		local clocks = participantClocks :: { BenchmarkClock.Clock }
		local recorders = timingRecorders :: { TimingRecorder.Recorder }
		local coordinator = serverClock :: BenchmarkClock.Clock
		local allPassed = true
		local internalFailed = false
		local latestCoordinatorAfter: number? = nil
		local function readClock(reader: () -> number): (CallOutcome, any?, number, any?)
			local results = table.pack(pcall(reader))
			if results[1] ~= true then
				return "Threw", nil, 0, results[2]
			end
			return "Returned", results[2], results.n - 1, nil
		end
		for index, participantClock in clocks do
			local beforeOutcome, coordinatorBefore, beforeCount, beforeDetail = readClock(coordinator.sharedNowSeconds)
			local localBeforeOutcome, localBefore, localBeforeCount, localBeforeDetail = readClock(participantClock.localNowSeconds)
			local sharedOutcome, participantShared, sharedCount, sharedDetail = readClock(participantClock.sharedNowSeconds)
			local localAfterOutcome, localAfter, localAfterCount, localAfterDetail = readClock(participantClock.localNowSeconds)
			local afterOutcome, coordinatorAfter, afterCount, afterDetail = readClock(coordinator.sharedNowSeconds)
			local proof: any
			if beforeOutcome == "Returned"
				and beforeCount == 1
				and localBeforeOutcome == "Returned"
				and localBeforeCount == 1
				and sharedOutcome == "Returned"
				and sharedCount == 1
				and localAfterOutcome == "Returned"
				and localAfterCount == 1
				and afterOutcome == "Returned"
				and afterCount == 1
			then
				proof = {
					coordinatorBeforeSharedSeconds = coordinatorBefore,
					participantSharedSeconds = participantShared,
					coordinatorAfterSharedSeconds = coordinatorAfter,
					localBeforeSeconds = localBefore,
					localAfterSeconds = localAfter,
				}
				latestCoordinatorAfter = coordinatorAfter :: number
			else
				proof = nil
				for _, read in {
					{ outcome = beforeOutcome, count = beforeCount, detail = beforeDetail },
					{ outcome = localBeforeOutcome, count = localBeforeCount, detail = localBeforeDetail },
					{ outcome = sharedOutcome, count = sharedCount, detail = sharedDetail },
					{ outcome = localAfterOutcome, count = localAfterCount, detail = localAfterDetail },
					{ outcome = afterOutcome, count = afterCount, detail = afterDetail },
				} do
					if (read.outcome ~= "Returned" or read.count ~= 1)
						and not (read.outcome == "Threw" and read.detail == "BENCHMARK_CLOCK_E_VALUE")
					then
						internalFailed = true
					end
				end
			end
			local proofOutcome, passed, proofCount = invokeNonYielding(recorders[index].recordClockProof, proof)
			if proofOutcome ~= "Returned" or proofCount ~= 1 or passed ~= true then
				allPassed = false
				if proofOutcome ~= "Returned" or proofCount ~= 1 then
					internalFailed = true
				end
			end
		end
		armSharedSeconds = latestCoordinatorAfter
		if not allPassed or armSharedSeconds == nil then
			recordCoordinatorFailure({ code = "ClockProofFailure", occurrences = 1 })
		end
		if internalFailed then
			recordCoordinatorFailure({
				code = "InternalError",
				occurrences = 1,
				discriminator = { kind = "Stage", value = "Execution" },
			})
			return "InternalFailed"
		end
		return if allPassed and armSharedSeconds ~= nil then "Passed" else "ClockFailed"
	end

	local function requestGenerationFrame(): StepResult
		waitingForFrame = "Generation"
		return NEEDS_FRAME
	end

	local function checkCaseDeadline(): "Active" | "Expired" | "ClockFailed"
		local state = caseState :: RunState.CaseState
		local outcome, value, count = invokeNonYielding(state.checkDeadline, "Case")
		if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
			return "ClockFailed"
		end
		local kind = rawget(value :: any, "kind")
		if kind == "Active" or kind == "Expired" or kind == "ClockFailed" then
			return kind
		end
		return "ClockFailed"
	end

	local function stepRunning(): StepResult
		local deadline = checkCaseDeadline()
		if deadline ~= "Active" then
			if repetitionWasStarted then
				recordCoordinatorFailure({
					code = if deadline == "Expired" then "Timeout" else "InternalError",
					occurrences = 1,
					firstRepetition = if deadline == "Expired" then repetitionIndex else nil,
					discriminator = if deadline == "ClockFailed" then { kind = "Stage", value = "Execution" } else nil,
				} :: any)
				return abortCurrentGeneration()
			end
			setTermination(fixedTermination("WarmupEvidenceRejected", "Execution"))
			return abortCurrentGeneration()
		end

		local statuses, terminated = statusSnapshot()
		if terminated then
			return abortCurrentGeneration()
		end
		local anyAborting = false
		local anyWarmup = false
		local allWarmupDrained = true
		local allQuiet = true
		local allQuietReady = true
		local anyMeasured = false
		local anyDraining = false
		local allVerified = true
		local allVerifiedQuiet = true
		for _, status in statuses do
			local phase = rawget(status :: any, "phase")
			anyAborting = anyAborting or phase == "Aborting"
			anyWarmup = anyWarmup or phase == "Warmup"
			allWarmupDrained = allWarmupDrained and phase == "WarmupDrained"
			allQuiet = allQuiet and phase == "ControlQuiet"
			allQuietReady = allQuietReady and phase == "ControlQuiet" and rawget(status :: any, "quietFrames") == 60
			anyMeasured = anyMeasured or phase == "Measured"
			anyDraining = anyDraining or phase == "Draining"
			allVerified = allVerified and phase == "Verified"
			allVerifiedQuiet = allVerifiedQuiet
				and phase == "Verified"
				and rawget(status :: any, "quietFrames") == 60
		end

		if anyAborting then
			return abortCurrentGeneration()
		end
		if allVerifiedQuiet then
			if not repetitionWasCompleted then
			local outcome, value, count = invokeNonYielding((caseState :: RunState.CaseState).transition, {
					kind = "RepetitionCompleted",
					repetitionIndex = repetitionIndex,
				finalOnlyEvidence = false,
			})
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
					setTermination(fixedTermination("FinalizationFailure", "Finalize"))
					return abortCurrentGeneration()
				end
				repetitionWasCompleted = true
			end
			return closeGeneration()
		end
		if allVerified then
			if prepared.selection.kind == "Workload" and not deliveryDeadlineCleared then
				local outcome, _, count = invokeNonYielding(
					(caseState :: RunState.CaseState).clearDeadline,
					"Delivery"
				)
				if outcome ~= "Returned" or count ~= 0 then
					setTermination(fixedTermination("FinalizationFailure", "Finalize"))
					return abortCurrentGeneration()
				end
				deliveryDeadlineCleared = true
			end
			return requestGenerationFrame()
		end
		if anyDraining then
			if prepared.selection.kind == "Workload" then
				local deadlineOutcome, deadlineValue, deadlineCount = invokeNonYielding(
					(caseState :: RunState.CaseState).checkDeadline,
					"Delivery"
				)
				if deadlineOutcome ~= "Returned" or deadlineCount ~= 1 or type(deadlineValue) ~= "table" then
					setTermination(fixedTermination("FinalizationFailure", "Finalize"))
					return abortCurrentGeneration()
				end
				local deadlineKind = rawget(deadlineValue :: any, "kind")
				if deadlineKind == "Expired" then
					local outcome, value, count = invokeNonYielding((caseState :: RunState.CaseState).transition, {
						kind = "RepetitionCompleted",
						repetitionIndex = repetitionIndex,
						finalOnlyEvidence = true,
					})
					if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
						setTermination(fixedTermination("FinalizationFailure", "Finalize"))
						return abortCurrentGeneration()
					end
					repetitionWasCompleted = true
					return closeGeneration()
				elseif deadlineKind ~= "Active" then
					setTermination(fixedTermination("FinalizationFailure", "Finalize"))
					return abortCurrentGeneration()
				end
			end
			return requestGenerationFrame()
		end
		if allQuietReady then
			if not commandAll({ kind = "ArmMeasured", startSharedSeconds = armSharedSeconds :: number }) then
				return abortCurrentGeneration()
			end
			measuredFramesObserved = 0
			return requestGenerationFrame()
		end
		if anyWarmup or allWarmupDrained or allQuiet then
			return requestGenerationFrame()
		end
		if anyMeasured then
			if prepared.selection.kind == "SeparateProbe" then
				return requestGenerationFrame()
			end
			local requiredFrames = (prepared.caseDefinition :: any).measuredFrames + 1
			if not measuredFinishIssued and measuredFramesObserved >= requiredFrames then
				measuredFinishIssued = true
				if not commandAll({ kind = "FinishMeasured", outcome = "Complete" }) then
					return abortCurrentGeneration()
				end
				return CONTINUE
			end
			return requestGenerationFrame()
		end

		setTermination(fixedTermination("FinalizationFailure", "Finalize"))
		return abortCurrentGeneration()
	end

	local function step(): StepResult
		if waitingForFrame ~= nil or lifecycle == "ResetBarrier" or lifecycle == "Terminal" then
			fail(STATE_ERROR)
		end
		if lifecycle == "New" then
			local clockOutcome, clockValue, clockCount = invokeNonYielding(
				BenchmarkClock.new,
				prepared.runtimeInputs.server.clocks
			)
			if clockOutcome ~= "Returned" or clockCount ~= 1 or type(clockValue) ~= "table" then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
			serverClock = clockValue :: BenchmarkClock.Clock
			local stateOutcome, stateValue, stateCount = invokeNonYielding(RunState.newCase, prepared, serverClock)
			if stateOutcome ~= "Returned" or stateCount ~= 1 or type(stateValue) ~= "table" then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
			caseState = stateValue :: RunState.CaseState
			return openGeneration()
		elseif lifecycle == "OpenGeneration" then
			return openGeneration()
		elseif lifecycle == "Activating" then
			local outcome, value, count = invokeNonYielding((activation :: GenerationActivation.Activation<TSender>).poll)
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
			local kind = rawget(value :: any, "kind")
			if kind == "Pending" then
				return CONTINUE
			elseif kind == "Ready" then
				kernels = rawget(value :: any, "kernels")
				lifecycle = if clockProofRecorded then "BeginWarmup" else "ClockProof"
				return CONTINUE
			elseif kind == "Terminated" then
				setTermination(rawget(value :: any, "termination"))
				return terminalStep()
			elseif kind == "SetupFailed" then
				recordCoordinatorFailure({ code = "SetupFailure", occurrences = 1 })
			elseif kind == "InternalFailed" then
				recordCoordinatorFailure({
					code = "InternalError",
					occurrences = 1,
					discriminator = { kind = "Stage", value = "Setup" },
				})
			else
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
				return terminalStep()
			end
			transitionCase({ kind = "AbortRemaining" } :: any)
			lifecycle = "Finalize"
			return CONTINUE
		elseif lifecycle == "ClockProof" then
			if recordClockProofs() ~= "Passed" then
				return abortCurrentGeneration()
			end
			clockProofRecorded = true
			lifecycle = "BeginWarmup"
			return CONTINUE
		elseif lifecycle == "BeginWarmup" then
			if not commandAll({ kind = "BeginWarmup" }) then
				return abortCurrentGeneration()
			end
			lifecycle = "Running"
			return CONTINUE
		elseif lifecycle == "Running" then
			return stepRunning()
		elseif lifecycle == "Finalize" then
			return freezeAndFinalize()
		end
		fail(STATE_ERROR)
	end

	local function resumeAfterFrame(): StepResult
		local purpose = waitingForFrame
		if purpose == nil or lifecycle == "Terminal" then
			fail(STATE_ERROR)
		end
		waitingForFrame = nil
		if purpose == "Generation" then
			local status = (caseState :: RunState.CaseState).status()
			if rawget(status :: any, "kind") == "State"
				and rawget(status :: any, "startedRepetitions") >= repetitionIndex
			then
				repetitionWasStarted = true
				measuredFramesObserved += 1
			end
			return CONTINUE
		end

		local current = kernels :: { RunnerKernel.Kernel<TSender> }
		for _, kernel in current do
			local outcome, value, count = invokeNonYielding(kernel.finishTeardownObservation)
			if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
				setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			elseif rawget(value :: any, "kind") == "Terminated" then
				setTermination(rawget(value :: any, "termination"))
			end
		end
		session = nil
		activation = nil
		kernels = nil
		if terminalTermination ~= nil then
			return terminalStep()
		end
		if abortProgressPending then
			abortProgressPending = false
			local status = (caseState :: RunState.CaseState).status()
			local hasOpenRepetition = rawget(status :: any, "kind") == "State"
				and rawget(status :: any, "startedRepetitions") > rawget(status :: any, "completedRepetitions")
			if hasOpenRepetition then
				transitionCase({ kind = "RepetitionAborted", repetitionIndex = repetitionIndex } :: any)
			else
				transitionCase({ kind = "AbortRemaining" } :: any)
			end
			if terminalTermination ~= nil then
				return terminalStep()
			end
		end
		local status = (caseState :: RunState.CaseState).status()
		if repetitionIndex >= prepared.caseDefinition.repetitions or rawget(status :: any, "phase") == "Aborted" then
			lifecycle = "Finalize"
			return CONTINUE
		end
		pendingResetRepetition = repetitionIndex
		lifecycle = "ResetBarrier"
		return frozenResult({ kind = "GenerationClosed", repetitionIndex = repetitionIndex })
	end

	local function confirmGenerationReset(): StepResult
		if lifecycle ~= "ResetBarrier" or waitingForFrame ~= nil or pendingResetRepetition == nil then
			fail(STATE_ERROR)
		end
		pendingResetRepetition = nil
		repetitionIndex += 1
		measuredFramesObserved = 0
		measuredFinishIssued = false
		deliveryDeadlineCleared = false
		repetitionWasStarted = false
		repetitionWasCompleted = false
		-- The case clock/state and participant accumulators are case-lifetime.
		-- A later step, never this reset acknowledgement, opens the generation.
		lifecycle = "OpenGeneration"
		return CONTINUE
	end

	local function rejectGenerationReset(): StepResult
		if lifecycle ~= "ResetBarrier" or waitingForFrame ~= nil or pendingResetRepetition == nil then
			fail(STATE_ERROR)
		end
		local failedRepetition = pendingResetRepetition
		pendingResetRepetition = nil
		local states = participantStates :: { RunState.ParticipantState<TSender> }
		local outcome, value, count = invokeNonYielding(states[1].recordFailure, {
			code = "IsolationFailure",
			occurrences = 1,
			firstRepetition = failedRepetition,
		})
		if outcome ~= "Returned" or count ~= 1 or type(value) ~= "table" then
			setTermination(fixedTermination("FinalizationFailure", "Finalize"))
			return terminalStep()
		end
		if rawget(value :: any, "kind") == "Terminated" then
			setTermination(rawget(value :: any, "termination"))
			return terminalStep()
		end
		transitionCase({ kind = "AbortRemaining" } :: any)
		lifecycle = "Finalize"
		return CONTINUE
	end

	local runner: Runner = {
		step = step,
		resumeAfterFrame = resumeAfterFrame,
		confirmGenerationReset = confirmGenerationReset,
		rejectGenerationReset = rejectGenerationReset,
	}
	table.freeze(runner)
	return runner
end

local CaseRunner = {
	new = new,
}

table.freeze(CaseRunner)
return CaseRunner
