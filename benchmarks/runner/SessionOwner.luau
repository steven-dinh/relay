--!strict

local AdapterContract = require("../adapters/AdapterContract")
local EventV1 = require("../contracts/event-v1")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local DeliveryRouter = require("./DeliveryRouter")

export type BenchmarkClockPort = {
	localNowSeconds: () -> number,
	sharedNowSeconds: () -> number,
	timeoutNowSeconds: () -> number,
}

export type Disconnect = () -> ()

export type PostSimulationSource = {
	connectPostSimulation: (callback: () -> ()) -> Disconnect,
}

export type GenerationRootLease<TResource> = {
	resourceRoot: TResource,
	destroy: () -> (),
}

export type GenerationRootFactory<TResource> = () -> GenerationRootLease<TResource>

export type ProcessRuntimeInput = {
	clocks: BenchmarkClockPort,
	postSimulation: PostSimulationSource,
}

export type ServerRuntimeInput<TSender> = ProcessRuntimeInput & {
	clientTokens: { TSender },
}

export type RuntimeInputs<TSender> = {
	server: ServerRuntimeInput<TSender>,
	clients: { ProcessRuntimeInput },
}

export type PreparedRuntimeInputs<TSender> = {
	server: ServerRuntimeInput<TSender>,
	clients: { ProcessRuntimeInput },
}

export type ParticipantRef =
	{ role: "Server" }
	| { role: "Client" | "ProbeClient", index: number }

export type CommonRuntimePort = {
	selection: AdapterContract.ResolvedSelection,
	caseDefinition: EventV1.Workload | EventV1.Probe,
	clocks: BenchmarkClockPort,
	postSimulation: PostSimulationSource,
	delivery: DeliveryRouter.SinkGate,
}

export type ServerRuntimePort<TSender> = CommonRuntimePort & {
	participant: { role: "Server" },
	side: AdapterContract.ServerSide,
	senderTokens: { TSender },
}

export type ClientRuntimePort = CommonRuntimePort & {
	participant: { role: "Client" | "ProbeClient", index: number },
	side: AdapterContract.ClientSide,
}

export type RuntimePort<TSender> = ServerRuntimePort<TSender> | ClientRuntimePort

export type PreparedSession<TSender> = {
	manifest: HostManifestV1.HostManifest,
	selection: AdapterContract.ResolvedSelection,
	caseDefinition: EventV1.Workload | EventV1.Probe,
	runtimeInputs: PreparedRuntimeInputs<TSender>,
}

export type PreparedCoordinator<TSender> = {
	manifest: HostManifestV1.HostManifest,
	selection: AdapterContract.ResolvedSelection,
	caseDefinition: EventV1.Workload | EventV1.Probe,
	serverRuntimeInput: ServerRuntimeInput<TSender>,
}

export type PreparedCase<TSender> = PreparedSession<TSender> | PreparedCoordinator<TSender>

export type ReadyResult<TSender> = {
	kind: "Ready",
	manifest: HostManifestV1.HostManifest,
	ports: { RuntimePort<TSender> },
	closeGenerationRoot: () -> HarnessTerminationV1.HarnessTerminationV1?,
}

export type ServerReadyResult<TSender> = {
	kind: "Ready",
	manifest: HostManifestV1.HostManifest,
	port: ServerRuntimePort<TSender>,
	closeGenerationRoot: () -> HarnessTerminationV1.HarnessTerminationV1?,
}

export type ClientReadyResult = {
	kind: "Ready",
	port: ClientRuntimePort,
}

export type TerminatedResult = {
	kind: "Terminated",
	termination: HarnessTerminationV1.HarnessTerminationV1,
}

export type PrepareResult<TSender> =
	{ kind: "Prepared", value: PreparedSession<TSender> }
	| TerminatedResult

export type PrepareCoordinatorResult<TSender> =
	{ kind: "Prepared", value: PreparedCoordinator<TSender> }
	| TerminatedResult

export type SetupFailedResult = {
	kind: "SetupFailed",
	manifest: HostManifestV1.HostManifest,
}

export type InternalFailedResult = {
	kind: "InternalFailed",
	manifest: HostManifestV1.HostManifest,
}

export type OpenResult<TSender> =
	ReadyResult<TSender>
	| TerminatedResult
	| SetupFailedResult
	| InternalFailedResult

export type ServerOpenResult<TSender> =
	ServerReadyResult<TSender>
	| TerminatedResult
	| SetupFailedResult
	| InternalFailedResult

export type ClientOpenResult =
	ClientReadyResult
	| TerminatedResult
	| { kind: "SetupFailed" }
	| { kind: "InternalFailed" }

local CLOCK_KEYS = {
	localNowSeconds = true,
	sharedNowSeconds = true,
	timeoutNowSeconds = true,
}

local POST_SIMULATION_KEYS = {
	connectPostSimulation = true,
}

local PROCESS_KEYS = {
	clocks = true,
	postSimulation = true,
}

local SERVER_PROCESS_KEYS = {
	clocks = true,
	postSimulation = true,
	clientTokens = true,
}

local RUNTIME_INPUT_KEYS = {
	server = true,
	clients = true,
}

local LEASE_KEYS = {
	resourceRoot = true,
	destroy = true,
}

local ADAPTER_FACTORY_KEYS = {
	constructServer = true,
	constructClient = true,
}

local preparedValues: { [table]: boolean } = setmetatable({}, {
	__mode = "k",
}) :: any

local preparedCases: { [table]: boolean } = setmetatable({}, {
	__mode = "k",
}) :: any

local function isExactPlainTable(
	value: unknown,
	expected: { [string]: boolean },
	expectedCount: number
): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end

	local count = 0
	local key = next(value :: any)
	while key ~= nil do
		count += 1
		if type(key) ~= "string" or rawget(expected, key) ~= true then
			return false
		end
		key = next(value :: any, key)
	end

	return count == expectedCount
end

local function invokeFresh(callout: () -> ...any): (any, boolean)
	local thread = coroutine.create(function()
		return table.pack(pcall(callout))
	end)
	local resumeResults = table.pack(coroutine.resume(thread))
	local dead = coroutine.status(thread) == "dead"
	if not dead then
		pcall(coroutine.close, thread)
		return resumeResults, false
	end
	if resumeResults[1] ~= true or resumeResults.n ~= 2 then
		return resumeResults, true
	end
	return resumeResults[2], true
end

local function denseArrayLength(value: unknown, expectedCount: number): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end

	local count = 0
	local key = next(value :: any)
	while key ~= nil do
		if type(key) ~= "number"
			or key % 1 ~= 0
			or key < 1
			or key > expectedCount
			or rawget(value :: any, key) == nil
		then
			return nil
		end
		count += 1
		key = next(value :: any, key)
	end

	if count ~= expectedCount then
		return nil
	end
	return count
end

local function copyClocks(candidate: unknown): BenchmarkClockPort?
	if not isExactPlainTable(candidate, CLOCK_KEYS, 3) then
		return nil
	end

	local source: any = candidate
	if type(rawget(source, "localNowSeconds")) ~= "function"
		or type(rawget(source, "sharedNowSeconds")) ~= "function"
		or type(rawget(source, "timeoutNowSeconds")) ~= "function"
	then
		return nil
	end

	local copied: BenchmarkClockPort = {
		localNowSeconds = rawget(source, "localNowSeconds"),
		sharedNowSeconds = rawget(source, "sharedNowSeconds"),
		timeoutNowSeconds = rawget(source, "timeoutNowSeconds"),
	}
	table.freeze(copied)
	return copied
end

local function copyPostSimulation(candidate: unknown): PostSimulationSource?
	if not isExactPlainTable(candidate, POST_SIMULATION_KEYS, 1) then
		return nil
	end

	local connect = rawget(candidate :: any, "connectPostSimulation")
	if type(connect) ~= "function" then
		return nil
	end

	local copied: PostSimulationSource = {
		connectPostSimulation = connect,
	}
	table.freeze(copied)
	return copied
end

local function copyProcessInput(candidate: unknown, server: boolean): ProcessRuntimeInput?
	local expected = if server then SERVER_PROCESS_KEYS else PROCESS_KEYS
	local expectedCount = if server then 3 else 2
	if not isExactPlainTable(candidate, expected, expectedCount) then
		return nil
	end

	local source: any = candidate
	local clocks = copyClocks(rawget(source, "clocks"))
	local postSimulation = copyPostSimulation(rawget(source, "postSimulation"))
	if clocks == nil or postSimulation == nil then
		return nil
	end

	return {
		clocks = clocks,
		postSimulation = postSimulation,
	}
end

local function distinctTokens(candidate: unknown, expectedCount: number): { any }?
	if denseArrayLength(candidate, expectedCount) == nil then
		return nil
	end

	local source: any = candidate
	local copied = table.create(expectedCount)
	for index = 1, expectedCount do
		local token = rawget(source, index)
		if token == nil or not rawequal(token, token) then
			return nil
		end
		for earlier = 1, index - 1 do
			if rawequal(rawget(copied, earlier), token) then
				return nil
			end
		end
		copied[index] = token
	end
	table.freeze(copied)
	return copied
end

local function deepEqual(left: any, right: any, seen: { [table]: table }?): boolean
	if rawequal(left, right) then
		return true
	end
	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end

	local visited = seen or {}
	if visited[left] ~= nil then
		return visited[left] == right
	end
	visited[left] = right

	local count = 0
	for key, value in next, left do
		count += 1
		if rawget(right, key) == nil or not deepEqual(value, rawget(right, key), visited) then
			return false
		end
	end

	local rightCount = 0
	for _ in next, right do
		rightCount += 1
	end
	return count == rightCount
end

local function selectedClientCount(selection: AdapterContract.ResolvedSelection): number
	return selection.clientProcessCount
end

local function resolveCaseDefinition(
	selection: AdapterContract.ResolvedSelection
): (EventV1.Workload | EventV1.Probe)?
	if selection.kind == "Workload" then
		for _, workload in EventV1.workloads do
			if workload.id == selection.workloadId then
				return workload
			end
		end
	else
		for _, probe in EventV1.probes do
			if probe.id == selection.probeId then
				return probe
			end
		end
	end
	return nil
end

local function terminated(
	code: HarnessTerminationV1.Code,
	stage: HarnessTerminationV1.Stage
): TerminatedResult
	local result: TerminatedResult = {
		kind = "Terminated",
		termination = HarnessTerminationV1.new(code, stage),
	}
	table.freeze(result)
	return result
end

local function setupFailed(manifest: HostManifestV1.HostManifest): SetupFailedResult
	local result: SetupFailedResult = {
		kind = "SetupFailed",
		manifest = manifest,
	}
	table.freeze(result)
	return result
end

local function internalFailed(manifest: HostManifestV1.HostManifest): InternalFailedResult
	local result: InternalFailedResult = {
		kind = "InternalFailed",
		manifest = manifest,
	}
	table.freeze(result)
	return result
end

type ValidatedCase = {
	kind: "Validated",
	manifest: HostManifestV1.HostManifest,
	selection: AdapterContract.ResolvedSelection,
	caseDefinition: EventV1.Workload | EventV1.Probe,
}

local function validateCase(
	manifestCandidate: unknown,
	adapterIdentityCandidate: unknown
): ValidatedCase | TerminatedResult
	local manifestResult = HostManifestV1.validate(manifestCandidate)
	if manifestResult.kind ~= "Valid" then
		return terminated("HostManifestRejected", "Preflight")
	end
	local manifest = manifestResult.value

	if manifest.adapter.identity.semantics.repetitionIsolation ~= "SessionRestart" then
		return terminated("HostManifestRejected", "Preflight")
	end

	local preflightCall = table.pack(pcall(
		AdapterContract.preflight,
		adapterIdentityCandidate,
		manifest.selection,
		manifest.environment.studio.version
	))
	if preflightCall[1] ~= true then
		return terminated("HostManifestRejected", "Preflight")
	end
	local supported: any = preflightCall[2]
	if supported.kind ~= "Supported"
		or not deepEqual(supported.identity, manifest.adapter.identity)
	then
		return terminated("HostManifestRejected", "Preflight")
	end

	local selection: AdapterContract.ResolvedSelection = supported.selection
	local caseDefinition = resolveCaseDefinition(selection)
	if caseDefinition == nil then
		return terminated("HostManifestRejected", "Preflight")
	end

	local validated: ValidatedCase = {
		kind = "Validated",
		manifest = manifest,
		selection = selection,
		caseDefinition = caseDefinition,
	}
	table.freeze(validated)
	return validated
end

local function prepare<TSender>(
	manifestCandidate: unknown,
	adapterIdentityCandidate: unknown,
	runtimeInputsCandidate: RuntimeInputs<TSender>
): PrepareResult<TSender>
	local validated = validateCase(manifestCandidate, adapterIdentityCandidate)
	if validated.kind == "Terminated" then
		return validated
	end
	local manifest = validated.manifest
	local selection = validated.selection
	local caseDefinition = validated.caseDefinition

	if not isExactPlainTable(runtimeInputsCandidate, RUNTIME_INPUT_KEYS, 2) then
		return terminated("HostManifestRejected", "Preflight")
	end
	local runtimeInputs: any = runtimeInputsCandidate
	local clientCount = selectedClientCount(selection)
	if denseArrayLength(rawget(runtimeInputs, "clients"), clientCount) == nil then
		return terminated("HostManifestRejected", "Preflight")
	end

	local serverCandidate = rawget(runtimeInputs, "server")
	local serverProcess = copyProcessInput(serverCandidate, true)
	if serverProcess == nil then
		return terminated("HostManifestRejected", "Preflight")
	end
	local clientTokens = distinctTokens(rawget(serverCandidate, "clientTokens"), clientCount)
	if clientTokens == nil then
		return terminated("HostManifestRejected", "Preflight")
	end

	local clients = table.create(clientCount)
	for index = 1, clientCount do
		local copied = copyProcessInput(rawget(runtimeInputs.clients, index), false)
		if copied == nil then
			return terminated("HostManifestRejected", "Preflight")
		end
		table.freeze(copied)
		clients[index] = copied
	end
	table.freeze(clients)

	local preparedServer: ServerRuntimeInput<TSender> = {
		clocks = serverProcess.clocks,
		postSimulation = serverProcess.postSimulation,
		clientTokens = clientTokens,
	}
	table.freeze(preparedServer)
	local preparedRuntimeInputs: PreparedRuntimeInputs<TSender> = {
		server = preparedServer,
		clients = clients,
	}
	table.freeze(preparedRuntimeInputs)

	local prepared: PreparedSession<TSender> = {
		manifest = manifest,
		selection = selection,
		caseDefinition = caseDefinition,
		runtimeInputs = preparedRuntimeInputs,
	}
	table.freeze(prepared)
	preparedValues[prepared :: any] = true
	preparedCases[prepared :: any] = true

	local result = {
		kind = "Prepared" :: "Prepared",
		value = prepared,
	}
	table.freeze(result)
	return result
end

local function prepareCoordinator<TSender>(
	manifestCandidate: unknown,
	adapterIdentityCandidate: unknown,
	serverRuntimeInputCandidate: unknown
): PrepareCoordinatorResult<TSender>
	local validated = validateCase(manifestCandidate, adapterIdentityCandidate)
	if validated.kind == "Terminated" then
		return validated
	end

	local serverProcess = copyProcessInput(serverRuntimeInputCandidate, true)
	local clientTokens = if type(serverRuntimeInputCandidate) == "table"
		then distinctTokens(
			rawget(serverRuntimeInputCandidate :: any, "clientTokens"),
			selectedClientCount(validated.selection)
		)
		else nil
	if serverProcess == nil or clientTokens == nil then
		return terminated("HostManifestRejected", "Preflight")
	end

	local serverRuntimeInput: ServerRuntimeInput<TSender> = {
		clocks = serverProcess.clocks,
		postSimulation = serverProcess.postSimulation,
		clientTokens = clientTokens,
	}
	table.freeze(serverRuntimeInput)

	local prepared: PreparedCoordinator<TSender> = {
		manifest = validated.manifest,
		selection = validated.selection,
		caseDefinition = validated.caseDefinition,
		serverRuntimeInput = serverRuntimeInput,
	}
	table.freeze(prepared)
	preparedCases[prepared :: any] = true

	local result = {
		kind = "Prepared" :: "Prepared",
		value = prepared,
	}
	table.freeze(result)
	return result
end

local function requirePreparedCase<TSender>(candidate: unknown): PreparedCase<TSender>
	if type(candidate) ~= "table"
		or rawget(preparedCases, candidate :: any) ~= true
	then
		error("SESSION_OWNER_E_PREPARED_CASE", 0)
	end
	return candidate :: any
end

local function requirePrepared<TSender>(candidate: unknown): PreparedSession<TSender>
	if type(candidate) ~= "table"
		or rawget(preparedValues, candidate :: any) ~= true
	then
		error("SESSION_OWNER_E_PREPARED", 0)
	end
	return candidate :: any
end

type AdapterProof = {
	sideCleanupUnprovable: boolean,
	constructionCleanupUnprovable: boolean,
}

local CLEANUP_UNPROVABLE = "SESSION_OWNER_E_CLEANUP_UNPROVABLE"

local function proveAdapterFactory(adapterFactory: unknown): (any, AdapterProof)
	local proof: AdapterProof = {
		sideCleanupUnprovable = false,
		constructionCleanupUnprovable = false,
	}
	local effectiveAdapterFactory: any = adapterFactory
	if not isExactPlainTable(adapterFactory, ADAPTER_FACTORY_KEYS, 2)
		or type(rawget(adapterFactory :: any, "constructServer")) ~= "function"
		or type(rawget(adapterFactory :: any, "constructClient")) ~= "function"
	then
		return effectiveAdapterFactory, proof
	end

	local rawConstructServer = rawget(adapterFactory :: any, "constructServer")
	local rawConstructClient = rawget(adapterFactory :: any, "constructClient")

	local function wrapConstructedSide(candidate: any): any
		if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
			return candidate
		end

		local copied = {}
		for key, value in next, candidate do
			if type(key) ~= "string" or type(value) ~= "function" then
				return candidate
			end
			copied[key] = value
		end

		local rawTeardown = rawget(copied, "teardown")
		if type(rawTeardown) == "function" then
			copied.teardown = function()
				local teardownCall, teardownDead = invokeFresh(rawTeardown)
				if teardownCall[1] ~= true then
					error(teardownCall[2], 0)
				end
				if not teardownDead or teardownCall.n ~= 1 then
					proof.sideCleanupUnprovable = true
					error(CLEANUP_UNPROVABLE, 0)
				end
			end
		end
		return copied
	end

	local function invokeAdapterConstructor(constructor: any, context: any): ...any
		local constructorCall, constructorDead = invokeFresh(function()
			return constructor(context)
		end)
		if constructorCall[1] ~= true then
			error(constructorCall[2], 0)
		end
		if not constructorDead or constructorCall.n > 2 then
			proof.constructionCleanupUnprovable = true
			error("SESSION_OWNER_E_CONSTRUCTION_UNPROVABLE", 0)
		end
		if constructorCall.n < 2 then
			return
		end
		return wrapConstructedSide(constructorCall[2])
	end

	effectiveAdapterFactory = {
		constructServer = function(context: any): ...any
			return invokeAdapterConstructor(rawConstructServer, context)
		end,
		constructClient = function(context: any): ...any
			return invokeAdapterConstructor(rawConstructClient, context)
		end,
	}
	return effectiveAdapterFactory, proof
end

local function signalCleanupProof(side: any, proof: AdapterProof): any
	local wrapped = {}
	for key, value in next, side do
		wrapped[key] = value
	end
	local teardown = side.teardown
	wrapped.teardown = function()
		local call = table.pack(pcall(teardown))
		if proof.sideCleanupUnprovable then
			error(CLEANUP_UNPROVABLE, 0)
		end
		if call[1] ~= true then
			error(call[2], 0)
		end
	end
	table.freeze(wrapped)
	return wrapped
end

local function openPrepared<TResource, TSender>(
	prepared: PreparedSession<TSender>,
	adapterFactory: AdapterContract.AdapterFactory<TResource, TSender>,
	generationRootFactory: GenerationRootFactory<TResource>
): OpenResult<TSender>
	local session: PreparedSession<TSender> = requirePrepared(prepared)
	local manifest = session.manifest
	local selection = session.selection
	local caseDefinition = session.caseDefinition
	local runtimeInputs = session.runtimeInputs

	local preflightCall = table.pack(pcall(
		AdapterContract.preflight,
		manifest.adapter.identity,
		manifest.selection,
		manifest.environment.studio.version
	))
	if preflightCall[1] ~= true then
		return internalFailed(manifest)
	end
	local supported: any = preflightCall[2]
	if type(supported) ~= "table"
		or rawget(supported, "kind") ~= "Supported"
		or not deepEqual(rawget(supported, "identity"), manifest.adapter.identity)
		or not deepEqual(rawget(supported, "selection"), selection)
	then
		return internalFailed(manifest)
	end

	local serverProcess = runtimeInputs.server
	local clientTokens = serverProcess.clientTokens
	local clients = runtimeInputs.clients
	local clientCount = selectedClientCount(selection)

	if type(generationRootFactory) ~= "function" then
		return internalFailed(manifest)
	end

	local rootCall, rootDead = invokeFresh(generationRootFactory)
	if rootCall[1] ~= true then
		return setupFailed(manifest)
	end
	if not rootDead then
		return terminated("CleanupFailure", "Finalize")
	end
	if rootCall.n < 2 then
		return internalFailed(manifest)
	end
	local rootHasExtraResults = rootCall.n > 2
	local leaseCandidate = rootCall[2]
	local leaseIsExact = isExactPlainTable(leaseCandidate, LEASE_KEYS, 2)
	local destroy = if type(leaseCandidate) == "table"
		then rawget(leaseCandidate :: any, "destroy")
		else nil
	local resourceRoot = if type(leaseCandidate) == "table"
		then rawget(leaseCandidate :: any, "resourceRoot")
		else nil

	local effectiveAdapterFactory, adapterProof = proveAdapterFactory(adapterFactory)
	local destroyAttempted = false
	local destroyTermination: HarnessTerminationV1.HarnessTerminationV1? = nil
	local function closeGenerationRoot(): HarnessTerminationV1.HarnessTerminationV1?
		if destroyAttempted then
			return destroyTermination
		end
		destroyAttempted = true
		if type(destroy) == "function" then
			local results, dead = invokeFresh(destroy)
			if results[1] ~= true or not dead or results.n ~= 1 then
				destroyTermination = HarnessTerminationV1.new("CleanupFailure", "Finalize")
			end
		end
		if adapterProof.sideCleanupUnprovable and destroyTermination == nil then
			destroyTermination = HarnessTerminationV1.new("CleanupFailure", "Finalize")
		end
		return destroyTermination
	end

	if rootHasExtraResults then
		closeGenerationRoot()
		return terminated("CleanupFailure", "Finalize")
	end

	if not leaseIsExact or resourceRoot == nil or type(destroy) ~= "function" then
		if resourceRoot ~= nil and type(destroy) ~= "function" then
			return terminated("CleanupFailure", "Finalize")
		end
		local cleanup = closeGenerationRoot()
		if cleanup ~= nil then
			local result: TerminatedResult = {
				kind = "Terminated",
				termination = cleanup,
			}
			table.freeze(result)
			return result
		end
		return internalFailed(manifest)
	end

	local gates: { DeliveryRouter.SinkGate } = {}
	local sides: { AdapterContract.ServerSide | AdapterContract.ClientSide } = {}

	local function rollback(
		fallback: "SetupFailed" | "InternalFailed",
		cleanupUnprovable: boolean?
	): OpenResult<TSender>
		local preReadyViolation = false
		local cleanupFailed = cleanupUnprovable == true
		for _, gate in gates do
			local disableCall = table.pack(pcall(gate.disable))
			if disableCall[1] ~= true then
				cleanupFailed = true
			elseif disableCall[2] == "PreReadyViolation" then
				preReadyViolation = true
			end
		end

		for index = #sides, 1, -1 do
			local teardownCall, teardownDead = invokeFresh(sides[index].teardown)
			if teardownCall[1] ~= true or not teardownDead or teardownCall.n ~= 1 then
				cleanupFailed = true
			end
		end
		if adapterProof.sideCleanupUnprovable then
			cleanupFailed = true
		end
		if closeGenerationRoot() ~= nil then
			cleanupFailed = true
		end

		if cleanupFailed then
			return terminated("CleanupFailure", "Finalize")
		elseif preReadyViolation then
			return terminated("ControlProtocolRejected", "Setup")
		end
		if fallback == "InternalFailed" then
			return internalFailed(manifest)
		end
		return setupFailed(manifest)
	end

	local adapterRecipients = {}
	local senderTokens = {}
	if selection.kind == "SeparateProbe"
		or (selection.kind == "Workload" and selection.audience == "Broadcast")
	then
		for index = 1, clientCount do
			adapterRecipients[index] = clientTokens[index]
		end
	end
	if selection.kind == "SeparateProbe" then
		for index = 1, clientCount do
			senderTokens[index] = clientTokens[index]
		end
	elseif selection.direction == "ClientToServer" then
		local workload = caseDefinition :: EventV1.Workload
		for index = 1, workload.senderCount do
			if clientTokens[index] == nil then
				return rollback("InternalFailed")
			end
			senderTokens[index] = clientTokens[index]
		end
	end
	table.freeze(adapterRecipients)
	table.freeze(senderTokens)

	local serverRoute = DeliveryRouter.newServer()
	table.insert(gates, serverRoute.gate)
	local serverConstruct, serverConstructDead = invokeFresh(function()
		return AdapterContract.constructServer(
			supported,
			effectiveAdapterFactory,
			resourceRoot,
			adapterRecipients,
			serverRoute.sink
		)
	end)
	if serverConstruct[1] ~= true then
		return rollback(
			if serverConstruct[2] == "ADAPTER_E_CONSTRUCT" then "SetupFailed" else "InternalFailed",
			adapterProof.constructionCleanupUnprovable
		)
	elseif not serverConstructDead or serverConstruct.n > 2 then
		return rollback("InternalFailed", true)
	elseif serverConstruct.n < 2 then
		return rollback("InternalFailed")
	end
	local serverSide: AdapterContract.ServerSide = serverConstruct[2]
	table.insert(sides, serverSide)

	local serverParticipant = { role = "Server" }
	table.freeze(serverParticipant)
	local serverPort: any = {
		participant = serverParticipant,
		selection = selection,
		caseDefinition = caseDefinition,
		clocks = serverProcess.clocks,
		postSimulation = serverProcess.postSimulation,
		delivery = serverRoute.gate,
		side = serverSide,
		senderTokens = senderTokens,
	}
	table.freeze(serverPort)

	local ports: { RuntimePort<TSender> } = table.create(clientCount + 1)
	ports[1] = serverPort
	for index = 1, clientCount do
		local route = DeliveryRouter.newClient()
		table.insert(gates, route.gate)
		local clientConstruct, clientConstructDead = invokeFresh(function()
			return AdapterContract.constructClient(
				supported,
				effectiveAdapterFactory,
				resourceRoot,
				index,
				route.sink
			)
		end)
		if clientConstruct[1] ~= true then
			return rollback(
				if clientConstruct[2] == "ADAPTER_E_CONSTRUCT" then "SetupFailed" else "InternalFailed",
				adapterProof.constructionCleanupUnprovable
			)
		elseif not clientConstructDead or clientConstruct.n > 2 then
			return rollback("InternalFailed", true)
		elseif clientConstruct.n < 2 then
			return rollback("InternalFailed")
		end
		local side: AdapterContract.ClientSide = clientConstruct[2]
		table.insert(sides, side)

		local participant = {
			role = if selection.kind == "SeparateProbe" then "ProbeClient" else "Client",
			index = index,
		}
		table.freeze(participant)
		local port: any = {
			participant = participant,
			selection = selection,
			caseDefinition = caseDefinition,
			clocks = clients[index].clocks,
			postSimulation = clients[index].postSimulation,
			delivery = route.gate,
			side = side,
		}
		table.freeze(port)
		ports[index + 1] = port
	end
	table.freeze(ports)

	local ready: ReadyResult<TSender> = {
		kind = "Ready",
		manifest = manifest,
		ports = ports,
		closeGenerationRoot = closeGenerationRoot,
	}
	table.freeze(ready)
	return ready
end

local function openServerPrepared<TResource, TSender>(
	preparedCandidate: PreparedCase<TSender>,
	adapterFactory: AdapterContract.AdapterFactory<TResource, TSender>,
	generationRootFactory: GenerationRootFactory<TResource>
): ServerOpenResult<TSender>
	local prepared = requirePreparedCase(preparedCandidate)
	local manifest = prepared.manifest
	local selection = prepared.selection
	local caseDefinition = prepared.caseDefinition
	local runtimeInputs = rawget(prepared :: any, "runtimeInputs")
	local serverProcess: ServerRuntimeInput<TSender> = if runtimeInputs ~= nil
		then rawget(runtimeInputs, "server")
		else rawget(prepared :: any, "serverRuntimeInput")

	local preflightCall = table.pack(pcall(
		AdapterContract.preflight,
		manifest.adapter.identity,
		manifest.selection,
		manifest.environment.studio.version
	))
	if preflightCall[1] ~= true then
		return internalFailed(manifest)
	end
	local supported: any = preflightCall[2]
	if type(supported) ~= "table"
		or rawget(supported, "kind") ~= "Supported"
		or not deepEqual(rawget(supported, "identity"), manifest.adapter.identity)
		or not deepEqual(rawget(supported, "selection"), selection)
	then
		return internalFailed(manifest)
	end

	if type(generationRootFactory) ~= "function" then
		return internalFailed(manifest)
	end

	local rootCall, rootDead = invokeFresh(generationRootFactory)
	if rootCall[1] ~= true then
		return setupFailed(manifest)
	end
	if not rootDead then
		return terminated("CleanupFailure", "Finalize")
	end
	if rootCall.n < 2 then
		return internalFailed(manifest)
	end

	local rootHasExtraResults = rootCall.n > 2
	local leaseCandidate = rootCall[2]
	local leaseIsExact = isExactPlainTable(leaseCandidate, LEASE_KEYS, 2)
	local destroy = if type(leaseCandidate) == "table"
		then rawget(leaseCandidate :: any, "destroy")
		else nil
	local resourceRoot = if type(leaseCandidate) == "table"
		then rawget(leaseCandidate :: any, "resourceRoot")
		else nil

	local effectiveAdapterFactory, adapterProof = proveAdapterFactory(adapterFactory)
	local destroyAttempted = false
	local destroyTermination: HarnessTerminationV1.HarnessTerminationV1? = nil
	local function closeGenerationRoot(): HarnessTerminationV1.HarnessTerminationV1?
		if destroyAttempted then
			return destroyTermination
		end
		destroyAttempted = true
		if type(destroy) == "function" then
			local results, dead = invokeFresh(destroy)
			if results[1] ~= true or not dead or results.n ~= 1 then
				destroyTermination = HarnessTerminationV1.new("CleanupFailure", "Finalize")
			end
		end
		if adapterProof.sideCleanupUnprovable and destroyTermination == nil then
			destroyTermination = HarnessTerminationV1.new("CleanupFailure", "Finalize")
		end
		return destroyTermination
	end

	if rootHasExtraResults then
		closeGenerationRoot()
		return terminated("CleanupFailure", "Finalize")
	end
	if not leaseIsExact or resourceRoot == nil or type(destroy) ~= "function" then
		if resourceRoot ~= nil and type(destroy) ~= "function" then
			return terminated("CleanupFailure", "Finalize")
		end
		local cleanup = closeGenerationRoot()
		if cleanup ~= nil then
			local result: TerminatedResult = {
				kind = "Terminated",
				termination = cleanup,
			}
			table.freeze(result)
			return result
		end
		return internalFailed(manifest)
	end

	local clientTokens = serverProcess.clientTokens
	local adapterRecipients = {}
	local senderTokens = {}
	local clientCount = selectedClientCount(selection)
	if selection.kind == "SeparateProbe"
		or (selection.kind == "Workload" and selection.audience == "Broadcast")
	then
		for index = 1, clientCount do
			adapterRecipients[index] = clientTokens[index]
		end
	end
	if selection.kind == "SeparateProbe" then
		for index = 1, clientCount do
			senderTokens[index] = clientTokens[index]
		end
	elseif selection.direction == "ClientToServer" then
		local workload = caseDefinition :: EventV1.Workload
		for index = 1, workload.senderCount do
			if clientTokens[index] == nil then
				closeGenerationRoot()
				return internalFailed(manifest)
			end
			senderTokens[index] = clientTokens[index]
		end
	end
	table.freeze(adapterRecipients)
	table.freeze(senderTokens)

	local route = DeliveryRouter.newServer()
	local function rollback(fallback: "SetupFailed" | "InternalFailed", cleanupUnprovable: boolean?): ServerOpenResult<TSender>
		local disableCall = table.pack(pcall(route.gate.disable))
		local cleanupFailed = cleanupUnprovable == true or disableCall[1] ~= true
		local preReadyViolation = disableCall[1] == true and disableCall[2] == "PreReadyViolation"
		if closeGenerationRoot() ~= nil then
			cleanupFailed = true
		end
		if cleanupFailed then
			return terminated("CleanupFailure", "Finalize")
		elseif preReadyViolation then
			return terminated("ControlProtocolRejected", "Setup")
		elseif fallback == "SetupFailed" then
			return setupFailed(manifest)
		end
		return internalFailed(manifest)
	end

	local serverConstruct, serverConstructDead = invokeFresh(function()
		return AdapterContract.constructServer(
			supported,
			effectiveAdapterFactory,
			resourceRoot,
			adapterRecipients,
			route.sink
		)
	end)
	if serverConstruct[1] ~= true then
		return rollback(
			if serverConstruct[2] == "ADAPTER_E_CONSTRUCT" then "SetupFailed" else "InternalFailed",
			adapterProof.constructionCleanupUnprovable
		)
	elseif not serverConstructDead or serverConstruct.n > 2 then
		return rollback("InternalFailed", true)
	elseif serverConstruct.n < 2 then
		return rollback("InternalFailed")
	end
	local serverSide: AdapterContract.ServerSide = serverConstruct[2]

	local participant = { role = "Server" }
	table.freeze(participant)
	local port: ServerRuntimePort<TSender> = {
		participant = participant,
		selection = selection,
		caseDefinition = caseDefinition,
		clocks = serverProcess.clocks,
		postSimulation = serverProcess.postSimulation,
		delivery = route.gate,
		side = serverSide,
		senderTokens = senderTokens,
	}
	table.freeze(port)

	local ready: ServerReadyResult<TSender> = {
		kind = "Ready",
		manifest = manifest,
		port = port,
		closeGenerationRoot = closeGenerationRoot,
	}
	table.freeze(ready)
	return ready
end

local function localOpenFailure(kind: "SetupFailed" | "InternalFailed"): any
	local result = { kind = kind }
	table.freeze(result)
	return result
end

local function openClient<TResource>(
	supportedCandidate: AdapterContract.SupportedPreflight,
	adapterFactory: AdapterContract.AdapterFactory<TResource, any>,
	localResourceRoot: TResource,
	participantIndex: number,
	processRuntimeInputCandidate: ProcessRuntimeInput
): ClientOpenResult
	local processRuntimeInput = copyProcessInput(processRuntimeInputCandidate, false)
	if processRuntimeInput == nil then
		return localOpenFailure("InternalFailed")
	end
	table.freeze(processRuntimeInput)

	local route = DeliveryRouter.newClient()
	local effectiveAdapterFactory, adapterProof = proveAdapterFactory(adapterFactory)
	local function rollback(fallback: "SetupFailed" | "InternalFailed", cleanupUnprovable: boolean?): ClientOpenResult
		local disableCall = table.pack(pcall(route.gate.disable))
		if cleanupUnprovable == true or disableCall[1] ~= true then
			return terminated("CleanupFailure", "Finalize")
		elseif disableCall[2] == "PreReadyViolation" then
			return terminated("ControlProtocolRejected", "Setup")
		end
		return localOpenFailure(fallback)
	end

	local clientConstruct, clientConstructDead = invokeFresh(function()
		return AdapterContract.constructClient(
			supportedCandidate,
			effectiveAdapterFactory,
			localResourceRoot,
			participantIndex,
			route.sink
		)
	end)
	if clientConstruct[1] ~= true then
		return rollback(
			if clientConstruct[2] == "ADAPTER_E_CONSTRUCT" then "SetupFailed" else "InternalFailed",
			adapterProof.constructionCleanupUnprovable
		)
	elseif not clientConstructDead or clientConstruct.n > 2 then
		return rollback("InternalFailed", true)
	elseif clientConstruct.n < 2 then
		return rollback("InternalFailed")
	end

	local selection = supportedCandidate.selection
	local caseDefinition = resolveCaseDefinition(selection)
	if caseDefinition == nil then
		return rollback("InternalFailed")
	end
	local participant = {
		role = if selection.kind == "SeparateProbe" then "ProbeClient" else "Client",
		index = participantIndex,
	}
	table.freeze(participant)
	local port: ClientRuntimePort = {
		participant = participant,
		selection = selection,
		caseDefinition = caseDefinition,
		clocks = processRuntimeInput.clocks,
		postSimulation = processRuntimeInput.postSimulation,
		delivery = route.gate,
		side = signalCleanupProof(clientConstruct[2], adapterProof),
	}
	table.freeze(port)

	local ready: ClientReadyResult = {
		kind = "Ready",
		port = port,
	}
	table.freeze(ready)
	return ready
end

local SessionOwner = {
	prepare = prepare,
	prepareCoordinator = prepareCoordinator,
	requirePrepared = requirePrepared,
	requirePreparedCase = requirePreparedCase,
	openPrepared = openPrepared,
	openServerPrepared = openServerPrepared,
	openClient = openClient,
}

table.freeze(SessionOwner)

return SessionOwner
