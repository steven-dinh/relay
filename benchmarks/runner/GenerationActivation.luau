--!strict

local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local Fixtures = require("../fixtures/event-v1")
local RunState = require("./RunState")
local RunnerKernel = require("./RunnerKernel")
local SessionOwner = require("./SessionOwner")
local TimingRecorder = require("./TimingRecorder")

export type Activation<TSender> = {
	poll: () ->
		{ kind: "Pending" }
		| { kind: "Ready", kernels: { RunnerKernel.Kernel<TSender> } }
		| { kind: "SetupFailed", manifest: HostManifestV1.HostManifest }
		| { kind: "InternalFailed", manifest: HostManifestV1.HostManifest }
		| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
}

export type LocalActivation<TSender> = {
	pollReady: () ->
		{ kind: "Pending" }
		| { kind: "ReadyToArm" }
		| { kind: "SetupFailed" }
		| { kind: "InternalFailed" }
		| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
	arm: () ->
		{ kind: "Ready", kernel: RunnerKernel.Kernel<TSender> }
		| { kind: "PreReadyViolation" }
		| { kind: "InternalFailed" }
		| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
	rollback: () ->
		{ kind: "Clean" }
		| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 },
}

local READY_TIMEOUT_SECONDS = 120

local CONFIG_ERROR = "GENERATION_ACTIVATION_E_CONFIG"
local STATE_ERROR = "GENERATION_ACTIVATION_E_STATE"

local SESSION_KEYS = {
	kind = true,
	manifest = true,
	ports = true,
	closeGenerationRoot = true,
}

local SERVER_READY_KEYS = {
	kind = true,
	manifest = true,
	port = true,
	closeGenerationRoot = true,
}

local CLIENT_READY_KEYS = {
	kind = true,
	port = true,
}

local CASE_STATE_KEYS = {
	selection = true,
	caseDefinition = true,
	acceptSession = true,
	transition = true,
	startDeadline = true,
	checkDeadline = true,
	clearDeadline = true,
	recordFailure = true,
	terminate = true,
	status = true,
	snapshot = true,
}

local PARTICIPANT_STATE_KEYS = {
	selection = true,
	participant = true,
	beginGeneration = true,
	recordFailure = true,
	freeze = true,
}

local RECORDER_KEYS = {
	participant = true,
	caseId = true,
	beginRepetition = true,
	enterExcluded = true,
	leaveExcluded = true,
	markLocal = true,
	markShared = true,
	captureShared = true,
	resolveShared = true,
	recordClockProof = true,
	finishRepetition = true,
	freeze = true,
}

local SERVER_PORT_KEYS = {
	participant = true,
	selection = true,
	caseDefinition = true,
	clocks = true,
	postSimulation = true,
	delivery = true,
	side = true,
	senderTokens = true,
}

local CLIENT_PORT_KEYS = {
	participant = true,
	selection = true,
	caseDefinition = true,
	clocks = true,
	postSimulation = true,
	delivery = true,
	side = true,
}

type Fallback = "SetupFailure" | "ReadyFailure" | "ReadyTimeout" | "InternalInvariant" | "ActivationInvariant" | "Terminated"
type ActivationLifecycle = "Created" | "Polling" | "Finished"
type LocalActivationLifecycle = "Polling" | "ReadyToArm" | "Armed" | "Failed"

local function fail(code: string): never
	error(code, 0)
end

local function isPositiveInteger(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and value > 0
		and value < math.huge
		and value % 1 == 0
end

local function isExactPlainTable(candidate: unknown, keys: { [string]: boolean }, expectedCount: number): boolean
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		return false
	end
	local count = 0
	for key in next, candidate :: any do
		count += 1
		if type(key) ~= "string" or rawget(keys, key) ~= true then
			return false
		end
	end
	return count == expectedCount
end

local function frozenExact(candidate: unknown, keys: { [string]: boolean }, expectedCount: number): boolean
	return type(candidate) == "table"
		and table.isfrozen(candidate :: any)
		and isExactPlainTable(candidate, keys, expectedCount)
end

local function denseFrozenLength(candidate: unknown): number?
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil or not table.isfrozen(candidate :: any) then
		return nil
	end
	local count = 0
	local maximum = 0
	for key in next, candidate :: any do
		if not isPositiveInteger(key) then
			return nil
		end
		count += 1
		maximum = math.max(maximum, key :: number)
	end
	if count ~= maximum then
		return nil
	end
	return count
end

local function deepEqual(left: unknown, right: unknown, seen: { [any]: any }?): boolean
	if type(left) ~= "table" or type(right) ~= "table" then
		return left == right
	end
	if getmetatable(left :: any) ~= nil or getmetatable(right :: any) ~= nil then
		return false
	end
	seen = seen or {}
	local previous = seen[left :: any]
	if previous ~= nil then
		return previous == right
	end
	seen[left :: any] = right
	local count = 0
	for key, value in next, left :: any do
		count += 1
		if rawget(right :: any, key) == nil and value ~= nil then
			return false
		end
		if not deepEqual(value, rawget(right :: any, key), seen) then
			return false
		end
	end
	local rightCount = 0
	for _ in next, right :: any do
		rightCount += 1
	end
	return count == rightCount
end

local function participantMatches(candidate: unknown, role: "Server" | "Client" | "ProbeClient", index: number?): boolean
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil or not table.isfrozen(candidate :: any) then
		return false
	end
	local value: any = candidate
	if role == "Server" then
		return isExactPlainTable(value, { role = true }, 1) and rawget(value, "role") == "Server"
	end
	return isExactPlainTable(value, { role = true, index = true }, 2)
		and rawget(value, "role") == role
		and rawget(value, "index") == index
end

local function frozenResult<T>(value: T): T
	table.freeze(value :: any)
	return value
end

local PENDING = frozenResult({ kind = "Pending" :: "Pending" })
local READY_TO_ARM = frozenResult({ kind = "ReadyToArm" :: "ReadyToArm" })
local LOCAL_SETUP_FAILED = frozenResult({ kind = "SetupFailed" :: "SetupFailed" })
local LOCAL_INTERNAL_FAILED = frozenResult({ kind = "InternalFailed" :: "InternalFailed" })
local PRE_READY_VIOLATION = frozenResult({ kind = "PreReadyViolation" :: "PreReadyViolation" })
local CLEAN = frozenResult({ kind = "Clean" :: "Clean" })

local function setupFailed(manifest: HostManifestV1.HostManifest)
	return frozenResult({
		kind = "SetupFailed" :: "SetupFailed",
		manifest = manifest,
	})
end

local function internalFailed(manifest: HostManifestV1.HostManifest)
	return frozenResult({
		kind = "InternalFailed" :: "InternalFailed",
		manifest = manifest,
	})
end

local function terminated(termination: HarnessTerminationV1.HarnessTerminationV1)
	return frozenResult({
		kind = "Terminated" :: "Terminated",
		termination = termination,
	})
end

local function validateCallableObject(candidate: unknown, keys: { [string]: boolean }, expectedCount: number): boolean
	if not frozenExact(candidate, keys, expectedCount) then
		return false
	end
	for key in next, keys do
		if key ~= "selection" and key ~= "participant" and key ~= "caseDefinition" and key ~= "caseId" then
			if type(rawget(candidate :: any, key)) ~= "function" then
				return false
			end
		end
	end
	return true
end

local function callKernel(kernel: any, methodName: string): any?
	local method = rawget(kernel, methodName)
	if type(method) ~= "function" then
		return nil
	end
	local call = table.pack(pcall(method))
	if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
		return nil
	end
	return call[2]
end

local function disableAndCleanup(kernels: { any }, closeRoot: (() -> HarnessTerminationV1.HarnessTerminationV1?)?): (boolean, boolean, boolean)
	local preReady = false
	local internalDuringDisable = false
	for _, kernel in kernels do
		local result = callKernel(kernel, "disableForRollback")
		local kind = if result == nil then nil else rawget(result, "kind")
		if kind == "PreReadyViolation" then
			preReady = true
		elseif kind ~= "Clean" then
			internalDuringDisable = true
		end
	end

	local cleanupFailed = false
	for index = #kernels, 1, -1 do
		local result = callKernel(kernels[index], "cleanupRollback")
		if result == nil or rawget(result, "kind") ~= "Clean" then
			cleanupFailed = true
		end
	end
	if closeRoot ~= nil then
		local closeCall = table.pack(pcall(closeRoot))
		if closeCall[1] ~= true or closeCall.n ~= 2 or closeCall[2] ~= nil then
			cleanupFailed = true
		end
	end
	return preReady, internalDuringDisable, cleanupFailed
end

local function begin<TSender>(
	sessionCandidate: SessionOwner.ReadyResult<TSender>,
	caseStateCandidate: RunState.CaseState,
	participantStatesCandidate: { RunState.ParticipantState<TSender> },
	fixture: Fixtures.FixtureSet | Fixtures.ProbeFixtureSet,
	timingRecordersCandidate: { TimingRecorder.Recorder }
): Activation<TSender>
	local session: any = sessionCandidate
	local caseState: any = caseStateCandidate
	local participantStates: any = participantStatesCandidate
	local timingRecorders: any = timingRecordersCandidate
	if not frozenExact(session, SESSION_KEYS, 4)
		or rawget(session, "kind") ~= "Ready"
		or type(rawget(session, "manifest")) ~= "table"
		or not table.isfrozen(rawget(session, "manifest"))
		or type(rawget(session, "closeGenerationRoot")) ~= "function"
		or not validateCallableObject(caseState, CASE_STATE_KEYS, 11)
		or type(fixture) ~= "table"
		or not table.isfrozen(fixture)
	then
		fail(CONFIG_ERROR)
	end

	local ports: any = rawget(session, "ports")
	local portCount = denseFrozenLength(ports)
	local stateCount = denseFrozenLength(participantStates)
	local recorderCount = denseFrozenLength(timingRecorders)
	if portCount == nil or portCount < 2 or stateCount ~= portCount or recorderCount ~= portCount then
		fail(CONFIG_ERROR)
	end

	local firstPort: any = rawget(ports, 1)
	if not frozenExact(firstPort, SERVER_PORT_KEYS, 8) then
		fail(CONFIG_ERROR)
	end
	local selection: any = rawget(firstPort, "selection")
	local caseDefinition: any = rawget(firstPort, "caseDefinition")
	if type(selection) ~= "table"
		or not table.isfrozen(selection)
		or not isPositiveInteger(rawget(selection, "clientProcessCount"))
		or type(caseDefinition) ~= "table"
		or not table.isfrozen(caseDefinition)
		or not isPositiveInteger(rawget(selection, "clientProcessCount"))
		or rawget(selection, "clientProcessCount") + 1 ~= portCount
		or type(rawget(caseDefinition, "id")) ~= "string"
		or not deepEqual(rawget(caseState, "selection"), selection)
		or not deepEqual(rawget(caseState, "caseDefinition"), caseDefinition)
	then
		fail(CONFIG_ERROR)
	end

	local caseId = rawget(caseDefinition, "id")
	local clientRole: "Client" | "ProbeClient" = if rawget(selection, "kind") == "SeparateProbe" then "ProbeClient" else "Client"
	local generationStates: { RunState.GenerationStatePort<TSender> } = table.create(portCount)
	local kernels: { RunnerKernel.Kernel<TSender> } = table.create(portCount)
	local readySides: { boolean } = table.create(portCount, false)
	local repetitionIndex = rawget(fixture :: any, "repetitionIndex")
	if not isPositiveInteger(repetitionIndex) then
		fail(CONFIG_ERROR)
	end

	for arrayIndex = 1, portCount do
		local port: any = rawget(ports, arrayIndex)
		local participantState: any = rawget(participantStates, arrayIndex)
		local timing: any = rawget(timingRecorders, arrayIndex)
		local role: "Server" | "Client" | "ProbeClient" = if arrayIndex == 1 then "Server" else clientRole
		local participantIndex = if arrayIndex == 1 then nil else arrayIndex - 1
		local expectedPortKeys = if arrayIndex == 1 then SERVER_PORT_KEYS else CLIENT_PORT_KEYS
		local expectedPortKeyCount = if arrayIndex == 1 then 8 else 7
		if not frozenExact(port, expectedPortKeys, expectedPortKeyCount)
			or not validateCallableObject(participantState, PARTICIPANT_STATE_KEYS, 5)
			or not validateCallableObject(timing, RECORDER_KEYS, 12)
			or not participantMatches(rawget(port, "participant"), role, participantIndex)
			or not participantMatches(rawget(participantState, "participant"), role, participantIndex)
			or not participantMatches(rawget(timing, "participant"), role, participantIndex)
			or not deepEqual(rawget(port, "selection"), selection)
			or not deepEqual(rawget(participantState, "selection"), selection)
			or not deepEqual(rawget(port, "caseDefinition"), caseDefinition)
			or rawget(timing, "caseId") ~= caseId
		then
			fail(CONFIG_ERROR)
		end

		local senderTokens = nil
		if arrayIndex == 1
			and (rawget(selection, "kind") == "SeparateProbe" or rawget(selection, "direction") == "ClientToServer")
		then
			senderTokens = rawget(port, "senderTokens")
		end
		local generationCall = table.pack(pcall(
			rawget(participantState, "beginGeneration"),
			repetitionIndex,
			fixture,
			rawget(port, "delivery"),
			timing,
			senderTokens
		))
		if generationCall[1] ~= true or generationCall.n ~= 2 or type(generationCall[2]) ~= "table" or not table.isfrozen(generationCall[2]) then
			fail(CONFIG_ERROR)
		end
		generationStates[arrayIndex] = generationCall[2]
		local kernelCall = table.pack(pcall(
			RunnerKernel.new,
			port,
			generationCall[2],
			fixture,
			timing,
			caseState,
			participantState,
			false
		))
		if kernelCall[1] ~= true or kernelCall.n ~= 2 or type(kernelCall[2]) ~= "table" or not table.isfrozen(kernelCall[2]) then
			fail(CONFIG_ERROR)
		end
		kernels[arrayIndex] = kernelCall[2]
	end
	table.freeze(generationStates)
	table.freeze(kernels)

	local lifecycle: ActivationLifecycle = "Created"
	local firstPoll = true
	local terminalTermination: HarnessTerminationV1.HarnessTerminationV1? = nil

	local function rollback(fallback: Fallback, initialPreReady: boolean): any
		local preReady, internalDuringDisable, cleanupFailed = disableAndCleanup(
			kernels :: { any },
			rawget(session, "closeGenerationRoot")
		)
		preReady = preReady or initialPreReady

		lifecycle = "Finished"
		if cleanupFailed then
			return terminated(HarnessTerminationV1.new("CleanupFailure", "Finalize"))
		elseif preReady or fallback == "ActivationInvariant" then
			return terminated(HarnessTerminationV1.new("ControlProtocolRejected", "Setup"))
		elseif internalDuringDisable or fallback == "InternalInvariant" then
			return internalFailed(rawget(session, "manifest"))
		elseif fallback == "Terminated" then
			return terminated(terminalTermination :: HarnessTerminationV1.HarnessTerminationV1)
		end
		return setupFailed(rawget(session, "manifest"))
	end

	local function deadlineStatus(scope: "Case" | "Readiness", start: boolean): ("Active" | "Expired" | "ClockFailed" | "Invalid")
		local method = if start then rawget(caseState, "startDeadline") else rawget(caseState, "checkDeadline")
		local call = table.pack(pcall(method, scope))
		if call[1] ~= true or call.n ~= 2 or type(call[2]) ~= "table" then
			return "Invalid"
		end
		local kind = rawget(call[2], "kind")
		if kind == "Active" or kind == "Expired" or kind == "ClockFailed" then
			return kind
		end
		return "Invalid"
	end

	local function failForDeadline(status: "Active" | "Expired" | "ClockFailed" | "Invalid", timeoutFallback: Fallback): any?
		if status == "Active" then
			return nil
		elseif status == "Expired" then
			return rollback(timeoutFallback, false)
		end
		return rollback("InternalInvariant", false)
	end

	local function poll(): any
		if lifecycle == "Finished" then
			fail(STATE_ERROR)
		end
		lifecycle = "Polling"

		if firstPoll then
			firstPoll = false
			for _, kernel in kernels do
				local result = callKernel(kernel, "attach")
				local kind = if result == nil then nil else rawget(result, "kind")
				if kind == "PreReadyViolation" then
					return rollback("ActivationInvariant", true)
				elseif kind == "SetupFailed" then
					return rollback("SetupFailure", false)
				elseif kind == "InternalFailed" or kind == nil then
					return rollback("InternalInvariant", false)
				elseif kind == "Terminated" then
					local validation = table.pack(pcall(HarnessTerminationV1.validate, rawget(result, "termination")))
					if validation[1] ~= true or validation.n ~= 2 then
						return rollback("InternalInvariant", false)
					end
					terminalTermination = validation[2]
					return rollback("Terminated", false)
				elseif kind ~= "Clean" then
					return rollback("InternalInvariant", false)
				end
			end

			for _, kernel in kernels do
				local result = callKernel(kernel, "setup")
				local kind = if result == nil then nil else rawget(result, "kind")
				if kind == "SetupFailed" then
					return rollback("SetupFailure", false)
				elseif kind ~= "Clean" then
					return rollback("InternalInvariant", false)
				end
			end

			local readinessFailure = failForDeadline(deadlineStatus("Readiness", true), "ReadyTimeout")
			if readinessFailure ~= nil then
				return readinessFailure
			end
		else
			local readinessFailure = failForDeadline(deadlineStatus("Readiness", false), "ReadyTimeout")
			if readinessFailure ~= nil then
				return readinessFailure
			end
		end

		local caseFailure = failForDeadline(deadlineStatus("Case", false), "ReadyTimeout")
		if caseFailure ~= nil then
			return caseFailure
		end

		local allReady = true
		for index, kernel in kernels do
			if not readySides[index] then
				local result = callKernel(kernel, "pollReady")
				local kind = if result == nil then nil else rawget(result, "kind")
				if kind == "Ready" then
					readySides[index] = true
				elseif kind == "Pending" then
					allReady = false
				elseif kind == "SetupFailed" then
					return rollback("ReadyFailure", false)
				else
					return rollback("InternalInvariant", false)
				end
			end
		end

		if not allReady then
			return PENDING
		end

		local clearCall = table.pack(pcall(rawget(caseState, "clearDeadline"), "Readiness"))
		if clearCall[1] ~= true or clearCall.n ~= 1 then
			return rollback("InternalInvariant", false)
		end
		for _, kernel in kernels do
			local result = callKernel(kernel, "arm")
			local kind = if result == nil then nil else rawget(result, "kind")
			if kind == "PreReadyViolation" then
				return rollback("ActivationInvariant", true)
			elseif kind == "InternalFailed" then
				return rollback("InternalInvariant", false)
			elseif kind ~= "Ready" then
				return rollback("ActivationInvariant", false)
			end
		end

		lifecycle = "Finished"
		local result = {
			kind = "Ready" :: "Ready",
			kernels = kernels,
		}
		table.freeze(result)
		return result
	end

	local activation: Activation<TSender> = {
		poll = poll,
	}
	table.freeze(activation)
	return activation
end

local function beginLocal<TSender>(
	openReadyCandidate: SessionOwner.ServerReadyResult<TSender> | SessionOwner.ClientReadyResult,
	participantStateCandidate: RunState.ParticipantState<TSender>,
	fixture: Fixtures.FixtureSet | Fixtures.ProbeFixtureSet,
	timingCandidate: TimingRecorder.Recorder,
	caseStateCandidate: RunState.CaseState?
): LocalActivation<TSender>
	local openReady: any = openReadyCandidate
	local participantState: any = participantStateCandidate
	local timing: any = timingCandidate
	local caseState: any = caseStateCandidate
	local port: any = if type(openReady) == "table" then rawget(openReady, "port") else nil
	local participant: any = if type(port) == "table" then rawget(port, "participant") else nil
	local role = if type(participant) == "table" then rawget(participant, "role") else nil
	local isServer = role == "Server"
	local expectedPortKeys = if isServer then SERVER_PORT_KEYS else CLIENT_PORT_KEYS
	local expectedPortKeyCount = if isServer then 8 else 7

	if not frozenExact(openReady, if isServer then SERVER_READY_KEYS else CLIENT_READY_KEYS, if isServer then 4 else 2)
		or rawget(openReady, "kind") ~= "Ready"
		or not frozenExact(port, expectedPortKeys, expectedPortKeyCount)
		or not validateCallableObject(participantState, PARTICIPANT_STATE_KEYS, 5)
		or not validateCallableObject(timing, RECORDER_KEYS, 12)
		or type(fixture) ~= "table"
		or not table.isfrozen(fixture)
	then
		fail(CONFIG_ERROR)
	end

	local selection: any = rawget(port, "selection")
	local caseDefinition: any = rawget(port, "caseDefinition")
	local participantIndex = if isServer then nil else rawget(participant, "index")
	local expectedRole: "Server" | "Client" | "ProbeClient" = if isServer
		then "Server"
		elseif type(selection) == "table" and rawget(selection, "kind") == "SeparateProbe"
		then "ProbeClient"
		else "Client"
	if type(selection) ~= "table"
		or not table.isfrozen(selection)
		or not isPositiveInteger(rawget(selection, "clientProcessCount"))
		or type(caseDefinition) ~= "table"
		or not table.isfrozen(caseDefinition)
		or type(rawget(caseDefinition, "id")) ~= "string"
		or not participantMatches(participant, expectedRole, participantIndex)
		or (not isServer and (not isPositiveInteger(participantIndex) or participantIndex > rawget(selection, "clientProcessCount")))
		or not participantMatches(rawget(participantState, "participant"), expectedRole, participantIndex)
		or not participantMatches(rawget(timing, "participant"), expectedRole, participantIndex)
		or not deepEqual(rawget(participantState, "selection"), selection)
		or rawget(timing, "caseId") ~= rawget(caseDefinition, "id")
		or not isPositiveInteger(rawget(fixture :: any, "repetitionIndex"))
	then
		fail(CONFIG_ERROR)
	end

	local closeRoot: (() -> HarnessTerminationV1.HarnessTerminationV1?)? = nil
	if isServer then
		if type(rawget(openReady, "manifest")) ~= "table"
			or not table.isfrozen(rawget(openReady, "manifest"))
			or type(rawget(openReady, "closeGenerationRoot")) ~= "function"
			or not validateCallableObject(caseState, CASE_STATE_KEYS, 11)
			or not deepEqual(rawget(caseState, "selection"), selection)
			or not deepEqual(rawget(caseState, "caseDefinition"), caseDefinition)
		then
			fail(CONFIG_ERROR)
		end
		closeRoot = rawget(openReady, "closeGenerationRoot")
	elseif caseState ~= nil then
		fail(CONFIG_ERROR)
	end

	local senderTokens = nil
	if isServer and (rawget(selection, "kind") == "SeparateProbe" or rawget(selection, "direction") == "ClientToServer") then
		senderTokens = rawget(port, "senderTokens")
	end
	local generationCall = table.pack(pcall(
		rawget(participantState, "beginGeneration"),
		rawget(fixture :: any, "repetitionIndex"),
		fixture,
		rawget(port, "delivery"),
		timing,
		senderTokens
	))
	if generationCall[1] ~= true
		or generationCall.n ~= 2
		or type(generationCall[2]) ~= "table"
		or not table.isfrozen(generationCall[2])
	then
		fail(CONFIG_ERROR)
	end
	local kernelCall = table.pack(pcall(
		RunnerKernel.new,
		port,
		generationCall[2],
		fixture,
		timing,
		caseState,
		participantState,
		isServer
	))
	if kernelCall[1] ~= true or kernelCall.n ~= 2 or type(kernelCall[2]) ~= "table" or not table.isfrozen(kernelCall[2]) then
		fail(CONFIG_ERROR)
	end
	local kernel: RunnerKernel.Kernel<TSender> = kernelCall[2]
	local kernels = { kernel }
	table.freeze(kernels)

	local lifecycle: LocalActivationLifecycle = "Polling"
	local firstPoll = true
	local preReadyViolation = false
	local terminalTermination: HarnessTerminationV1.HarnessTerminationV1? = nil
	local rollbackResult: ({ kind: "Clean" } | { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 })? = nil

	local function failLocal(result: any): any
		lifecycle = "Failed"
		return result
	end

	local function terminateLocal(candidate: unknown): any
		local validation = table.pack(pcall(HarnessTerminationV1.validate, candidate))
		if validation[1] ~= true or validation.n ~= 2 then
			return failLocal(LOCAL_INTERNAL_FAILED)
		end
		terminalTermination = validation[2]
		return failLocal(terminated(terminalTermination :: HarnessTerminationV1.HarnessTerminationV1))
	end

	local function pollReady(): any
		if lifecycle ~= "Polling" then
			fail(STATE_ERROR)
		end
		if firstPoll then
			firstPoll = false
			local attachResult = callKernel(kernel, "attach")
			local attachKind = if attachResult == nil then nil else rawget(attachResult, "kind")
			if attachKind == "PreReadyViolation" then
				preReadyViolation = true
				terminalTermination = HarnessTerminationV1.new("ControlProtocolRejected", "Setup")
				return failLocal(terminated(terminalTermination))
			elseif attachKind == "SetupFailed" then
				return failLocal(LOCAL_SETUP_FAILED)
			elseif attachKind == "InternalFailed" or attachKind == nil then
				return failLocal(LOCAL_INTERNAL_FAILED)
			elseif attachKind == "Terminated" then
				return terminateLocal(rawget(attachResult, "termination"))
			elseif attachKind ~= "Clean" then
				return failLocal(LOCAL_INTERNAL_FAILED)
			end

			local setupResult = callKernel(kernel, "setup")
			local setupKind = if setupResult == nil then nil else rawget(setupResult, "kind")
			if setupKind == "SetupFailed" then
				return failLocal(LOCAL_SETUP_FAILED)
			elseif setupKind ~= "Clean" then
				return failLocal(LOCAL_INTERNAL_FAILED)
			end
		end

		local readyResult = callKernel(kernel, "pollReady")
		local readyKind = if readyResult == nil then nil else rawget(readyResult, "kind")
		if readyKind == "Pending" then
			return PENDING
		elseif readyKind == "Ready" then
			lifecycle = "ReadyToArm"
			return READY_TO_ARM
		elseif readyKind == "SetupFailed" then
			return failLocal(LOCAL_SETUP_FAILED)
		elseif readyKind == "Terminated" then
			return terminateLocal(rawget(readyResult, "termination"))
		end
		return failLocal(LOCAL_INTERNAL_FAILED)
	end

	local function arm(): any
		if lifecycle ~= "ReadyToArm" then
			fail(STATE_ERROR)
		end
		local armResult = callKernel(kernel, "arm")
		local kind = if armResult == nil then nil else rawget(armResult, "kind")
		if kind == "Ready" then
			lifecycle = "Armed"
			return frozenResult({
				kind = "Ready" :: "Ready",
				kernel = kernel,
			})
		elseif kind == "PreReadyViolation" then
			preReadyViolation = true
			return failLocal(PRE_READY_VIOLATION)
		elseif kind == "Terminated" then
			return terminateLocal(rawget(armResult, "termination"))
		end
		return failLocal(LOCAL_INTERNAL_FAILED)
	end

	local function rollback(): any
		if rollbackResult ~= nil then
			return rollbackResult
		end
		local disabledPreReady, internalDuringDisable, cleanupFailed = disableAndCleanup(kernels :: { any }, closeRoot)
		preReadyViolation = preReadyViolation or disabledPreReady
		if cleanupFailed or internalDuringDisable then
			rollbackResult = terminated(HarnessTerminationV1.new("CleanupFailure", "Finalize"))
		elseif preReadyViolation then
			rollbackResult = terminated(HarnessTerminationV1.new("ControlProtocolRejected", "Setup"))
		elseif terminalTermination ~= nil then
			rollbackResult = terminated(terminalTermination)
		else
			rollbackResult = CLEAN
		end
		lifecycle = "Failed"
		return rollbackResult
	end

	local activation: LocalActivation<TSender> = {
		pollReady = pollReady,
		arm = arm,
		rollback = rollback,
	}
	table.freeze(activation)
	return activation
end

local GenerationActivation = {
	READY_TIMEOUT_SECONDS = READY_TIMEOUT_SECONDS,
	begin = begin,
	beginLocal = beginLocal,
}
table.freeze(GenerationActivation)

return GenerationActivation
