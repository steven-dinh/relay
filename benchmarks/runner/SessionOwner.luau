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

export type OpenResult<TSender> =
	{
		kind: "Ready",
		manifest: HostManifestV1.HostManifest,
		ports: { RuntimePort<TSender> },
		closeGenerationRoot: () -> HarnessTerminationV1.HarnessTerminationV1?,
	}
	| { kind: "Terminated", termination: HarnessTerminationV1.HarnessTerminationV1 }
	| { kind: "SetupFailed" }

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
		if token == nil then
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
	if selection.kind == "Workload" then
		return selection.recipientCount
	end
	return selection.clientCount
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

local function terminated(code: HarnessTerminationV1.Code, stage: HarnessTerminationV1.Stage): any
	local result = {
		kind = "Terminated",
		termination = HarnessTerminationV1.new(code, stage),
	}
	table.freeze(result)
	return result
end

local function setupFailed(): any
	local result = { kind = "SetupFailed" }
	table.freeze(result)
	return result
end

local function open<TResource, TSender>(
	manifestCandidate: unknown,
	adapterIdentityCandidate: unknown,
	adapterFactory: AdapterContract.AdapterFactory<TResource, TSender>,
	generationRootFactory: GenerationRootFactory<TResource>,
	runtimeInputsCandidate: unknown
): OpenResult<TSender>
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

	if type(generationRootFactory) ~= "function" then
		return setupFailed()
	end

	local rootCall = table.pack(pcall(generationRootFactory))
	if rootCall[1] ~= true then
		return setupFailed()
	end
	local leaseCandidate = rootCall[2]
	local leaseIsExact = isExactPlainTable(leaseCandidate, LEASE_KEYS, 2)
	local destroy = if type(leaseCandidate) == "table"
		then rawget(leaseCandidate :: any, "destroy")
		else nil
	local resourceRoot = if type(leaseCandidate) == "table"
		then rawget(leaseCandidate :: any, "resourceRoot")
		else nil

	local destroyAttempted = false
	local destroyTermination: HarnessTerminationV1.HarnessTerminationV1? = nil
	local function closeGenerationRoot(): HarnessTerminationV1.HarnessTerminationV1?
		if destroyAttempted then
			return destroyTermination
		end
		destroyAttempted = true
		if type(destroy) ~= "function" then
			return nil
		end
		local ok = pcall(destroy)
		if not ok then
			destroyTermination = HarnessTerminationV1.new("CleanupFailure", "Finalize")
		end
		return destroyTermination
	end

	if not leaseIsExact or resourceRoot == nil or type(destroy) ~= "function" then
		local cleanup = closeGenerationRoot()
		if cleanup ~= nil then
			local result = { kind = "Terminated", termination = cleanup }
			table.freeze(result)
			return result :: any
		end
		return setupFailed()
	end

	local gates: { DeliveryRouter.SinkGate } = {}
	local sides: { AdapterContract.ServerSide | AdapterContract.ClientSide } = {}

	local function rollback(): OpenResult<TSender>
		local preReadyViolation = false
		local cleanupFailed = false
		for _, gate in gates do
			local disableCall = table.pack(pcall(gate.disable))
			if disableCall[1] ~= true then
				cleanupFailed = true
			elseif disableCall[2] == "PreReadyViolation" then
				preReadyViolation = true
			end
		end

		for index = #sides, 1, -1 do
			if not pcall(sides[index].teardown) then
				cleanupFailed = true
			end
		end
		if closeGenerationRoot() ~= nil then
			cleanupFailed = true
		end

		if cleanupFailed then
			return terminated("CleanupFailure", "Finalize")
		elseif preReadyViolation then
			return terminated("ControlProtocolRejected", "Setup")
		end
		return setupFailed()
	end

	local adapterRecipients = {}
	local senderTokens = {}
	if selection.kind == "SeparateProbe"
		or (selection.kind == "Workload" and selection.direction == "ServerToClient")
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
				return rollback()
			end
			senderTokens[index] = clientTokens[index]
		end
	end
	table.freeze(adapterRecipients)
	table.freeze(senderTokens)

	local serverRoute = DeliveryRouter.newServer()
	table.insert(gates, serverRoute.gate)
	local serverConstruct = table.pack(pcall(
		AdapterContract.constructServer,
		supported,
		adapterFactory,
		resourceRoot,
		adapterRecipients,
		serverRoute.sink
	))
	if serverConstruct[1] ~= true then
		return rollback()
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
		local clientConstruct = table.pack(pcall(
			AdapterContract.constructClient,
			supported,
			adapterFactory,
			resourceRoot,
			index,
			route.sink
		))
		if clientConstruct[1] ~= true then
			return rollback()
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

	local ready: any = {
		kind = "Ready",
		manifest = manifest,
		ports = ports,
		closeGenerationRoot = closeGenerationRoot,
	}
	table.freeze(ready)
	return ready
end

local SessionOwner = {
	open = open,
}

table.freeze(SessionOwner)

return SessionOwner
