--!strict

local AdapterIdentity = require("../contracts/internal/AdapterIdentity")

local COMMON_CAPABILITIES = table.freeze({
	directions = table.freeze({ "ClientToServer", "ServerToClient" }),
	deliverySemantics = table.freeze({ "ReliableOrdered" }),
	payloadIds = table.freeze({ "state", "tiny" }),
})

local DEFINITIONS = table.freeze({
	quicknet = table.freeze({
		integrationKind = "Runtime",
		broadcastMode = "AdapterFanOut",
		intentionalAddedDeliveryFrames = 1,
		adapterPath = "adapters/quicknet/init.luau",
		library = table.freeze({
			["$path"] = "vendor/quicknet/src/QuickNet.luau",
			DataTypes = table.freeze({ ["$path"] = "vendor/quicknet/src/QuickNet/DataTypes.luau" }),
			Enums = table.freeze({ ["$path"] = "vendor/quicknet/src/QuickNet/Enums.luau" }),
			EnumsToNativeTypes = table.freeze({ ["$path"] = "vendor/quicknet/src/QuickNet/EnumsToNativeTypes.luau" }),
			Parser = table.freeze({ ["$path"] = "vendor/quicknet/src/QuickNet/Parser.luau" }),
			Serialize = table.freeze({ ["$path"] = "vendor/quicknet/src/QuickNet/Serialize.luau" }),
			Types = table.freeze({ ["$path"] = "vendor/quicknet/src/QuickNet/Types.luau" }),
		}),
	}),
	bytenet = table.freeze({
		integrationKind = "Runtime",
		broadcastMode = "NativeBroadcast",
		intentionalAddedDeliveryFrames = 1,
		adapterPath = "adapters/bytenet/init.luau",
		library = table.freeze({ ["$path"] = "vendor/bytenet/src" }),
	}),
	satset = table.freeze({
		integrationKind = "Runtime",
		broadcastMode = "NativeBroadcast",
		intentionalAddedDeliveryFrames = 1,
		adapterPath = "adapters/satset/init.luau",
		library = table.freeze({ ["$path"] = "vendor/satset/src" }),
	}),
	warp = table.freeze({
		integrationKind = "Runtime",
		broadcastMode = "AdapterFanOut",
		intentionalAddedDeliveryFrames = 1,
		adapterPath = "adapters/warp/init.luau",
		endpointPath = "adapters/warp/Endpoint.luau",
		library = table.freeze({ ["$path"] = "vendor/warp/src" }),
	}),
	blink = table.freeze({
		integrationKind = "Generated",
		broadcastMode = "AdapterFanOut",
		intentionalAddedDeliveryFrames = 0,
		adapterPath = "adapters/blink/init.luau",
		generatedId = "blink",
	}),
	zap = table.freeze({
		integrationKind = "Generated",
		broadcastMode = "AdapterFanOut",
		intentionalAddedDeliveryFrames = 0,
		adapterPath = "adapters/zap/init.luau",
		generatedId = "zap",
	}),
	["netray-compile"] = table.freeze({
		integrationKind = "Generated",
		broadcastMode = "NativeBroadcast",
		intentionalAddedDeliveryFrames = 0,
		adapterPath = "adapters/netray-compile/init.luau",
		generatedId = "netray-compile",
	}),
	["suphi-packet"] = table.freeze({
		unsupported = "SenderFrameBoundUnprovable",
	}),
})

local ORDERED_IDS = table.freeze({
	"quicknet",
	"bytenet",
	"satset",
	"warp",
	"blink",
	"zap",
	"netray-compile",
	"suphi-packet",
})

local function deepClone(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, nested in value do copy[deepClone(key)] = deepClone(nested) end
	return copy
end

local function definition(id: any): any?
	if type(id) ~= "string" then return nil end
	return rawget(DEFINITIONS, id)
end

local function isExternal(id: any): boolean
	return definition(id) ~= nil
end

local function isSupported(id: any): boolean
	local selected = definition(id)
	return selected ~= nil and selected.unsupported == nil
end

local function findLockedLibrary(lock: any, id: string): any
	if type(lock) ~= "table" or type(lock.libraries) ~= "table" then
		error("HOST_E_EXTERNAL_LOCK", 0)
	end
	for _, library in lock.libraries do
		if type(library) == "table" and library.id == id then return library end
	end
	error("HOST_E_EXTERNAL_LOCK", 0)
end

local function selected(lock: any, id: string): any
	local entry = definition(id)
	if entry == nil then error("HOST_E_EXTERNAL_ADAPTER", 0) end
	if entry.unsupported ~= nil then
		error("HOST_E_EXTERNAL_UNSUPPORTED_SUPHI_FRAME_BOUND", 0)
	end
	local library = findLockedLibrary(lock, id)
	if library.kind ~= (if entry.integrationKind == "Generated" then "CodegenTool" else "RuntimeSource")
		or library.name == nil
		or library.tag == nil
		or library.repository == nil
		or library.revision == nil
		or library.license == nil
	then
		error("HOST_E_EXTERNAL_LOCK", 0)
	end
	return {
		id = id,
		library = library,
		integrationKind = entry.integrationKind,
		broadcastMode = entry.broadcastMode,
		intentionalAddedDeliveryFrames = entry.intentionalAddedDeliveryFrames,
		adapterPath = entry.adapterPath,
		endpointPath = entry.endpointPath,
		generatedId = entry.generatedId,
		libraryProject = if entry.library == nil then nil else deepClone(entry.library),
	}
end

local function adapter(selectedEntry: any, digest: string, studioVersion: string, profile: string?): any
	if profile ~= nil and profile ~= "PersistentSession" then error("HOST_E_EXTERNAL_IDENTITY", 0) end
	if type(selectedEntry) ~= "table" or type(selectedEntry.library) ~= "table"
		or type(digest) ~= "string"
	then
		error("HOST_E_EXTERNAL_IDENTITY", 0)
	end
	local library = selectedEntry.library
	local identity = {
		id = selectedEntry.id,
		displayName = library.name,
		lane = "EquivalentSemantics",
		integrationKind = selectedEntry.integrationKind,
		library = {
			id = library.id,
			displayName = library.name,
			version = library.tag,
			provenance = {
				kind = "Repository",
				sourceRepository = library.repository,
				revision = library.revision,
				checksum = digest,
				license = library.license,
			},
		},
		semantics = {
			broadcastMode = selectedEntry.broadcastMode,
			intentionalAddedDeliveryFrames = selectedEntry.intentionalAddedDeliveryFrames,
			repetitionIsolation = profile or "ProcessRestart",
		},
		capabilities = deepClone(COMMON_CAPABILITIES),
	}
	local checked = AdapterIdentity.check(identity, "Canonical", studioVersion, "$.adapter.identity", profile)
	if checked.kind ~= "Valid" then error("HOST_E_EXTERNAL_IDENTITY", 0) end
	return {
		moduleId = selectedEntry.id,
		artifact = { kind = "RepositoryModule", digest = digest },
		identity = checked.value,
	}
end

local function generatedLibraryProject(id: string): any
	return {
		["$className"] = "Folder",
		Server = { ["$path"] = `generated/{id}/Server.luau` },
		Client = { ["$path"] = `generated/{id}/Client.luau` },
		Types = { ["$path"] = `generated/{id}/Types.luau` },
	}
end

local function rewritePaths(value: any)
	if type(value) ~= "table" then return end
	local path = rawget(value, "$path")
	if type(path) == "string" and string.sub(path, 1, 3) ~= "../" then
		value["$path"] = "../benchmarks/" .. path
	end
	for key, child in value do
		if key ~= "$path" then rewritePaths(child) end
	end
end

local function composeProject(baseProject: any, selectedEntry: any, bindingProjectPath: string): any
	if type(baseProject) ~= "table" or type(baseProject.tree) ~= "table"
		or type(selectedEntry) ~= "table" or type(selectedEntry.id) ~= "string"
		or type(bindingProjectPath) ~= "string" or #bindingProjectPath == 0
	then
		error("HOST_E_EXTERNAL_PROJECT", 0)
	end
	local project = deepClone(baseProject)
	rewritePaths(project)
	project.name = `relay-event-v1-{selectedEntry.id}`
	local tree = project.tree
	if type(tree.HttpService) ~= "table" or type(tree.HttpService["$properties"]) ~= "table"
		or type(tree.ReplicatedStorage) ~= "table"
		or type(tree.ReplicatedStorage.RelayBenchmark) ~= "table"
		or type(tree.ServerStorage) ~= "table"
	then
		error("HOST_E_EXTERNAL_PROJECT", 0)
	end
	tree.HttpService["$properties"].HttpEnabled = false
	tree.ReplicatedStorage.Relay = nil
	local benchmark = tree.ReplicatedStorage.RelayBenchmark
	benchmark.adapters = {
		["$className"] = "Folder",
		AdapterContract = { ["$path"] = "../benchmarks/adapters/AdapterContract.luau" },
		ExternalAdapter = { ["$path"] = "../benchmarks/adapters/ExternalAdapter.luau" },
		ExternalSelected = { ["$path"] = bindingProjectPath },
	}
	if type(benchmark.Runner) ~= "table" then error("HOST_E_EXTERNAL_PROJECT", 0) end
	benchmark.Runner.ExternalReadiness = {
		["$path"] = "../benchmarks/runner/ExternalReadiness.luau",
	}
	local libraryProject = selectedEntry.libraryProject
	if selectedEntry.generatedId ~= nil then
		libraryProject = generatedLibraryProject(selectedEntry.generatedId)
	end
	if type(libraryProject) ~= "table" then error("HOST_E_EXTERNAL_PROJECT", 0) end
	rewritePaths(libraryProject)
	local template = {
		["$className"] = "Folder",
		Library = libraryProject,
	}
	if selectedEntry.endpointPath ~= nil then
		template.Endpoint = { ["$path"] = "../benchmarks/" .. selectedEntry.endpointPath }
	end
	if type(tree.ServerStorage.RelayBenchmarkServer) ~= "table" then
		error("HOST_E_EXTERNAL_PROJECT", 0)
	end
	tree.ServerStorage.RelayBenchmarkServer.ExternalTemplate = template
	return project
end

return table.freeze({
	ids = ORDERED_IDS,
	definition = definition,
	isExternal = isExternal,
	isSupported = isSupported,
	selected = selected,
	adapter = adapter,
	composeProject = composeProject,
})
