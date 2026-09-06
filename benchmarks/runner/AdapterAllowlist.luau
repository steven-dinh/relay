--!strict

local REJECTED = table.freeze({ kind = "Rejected" })
local STUDIO_VERSION = {}
local NATIVE_ADAPTER = {
	moduleId = "native-reliable",
	artifact = { kind = "EngineBuiltIn" },
	identity = {
		id = "native-reliable",
		displayName = "Roblox RemoteEvent",
		lane = "EquivalentSemantics",
		integrationKind = "EngineBuiltIn",
		library = {
			id = "roblox-remote-event",
			displayName = "Roblox RemoteEvent",
			version = STUDIO_VERSION,
			provenance = {
				kind = "EngineBuiltIn",
				studioVersion = STUDIO_VERSION,
			},
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
	},
}

local resolved: any = nil
local resolvedRelay: any = nil
local resolvedExternal: any = nil

local EXTERNAL_IDS = table.freeze({
	quicknet = true,
	bytenet = true,
	satset = true,
	warp = true,
	blink = true,
	zap = true,
	["netray-compile"] = true,
	["suphi-packet"] = true,
})

local function matchesExact(actual: any, expected: any, studioVersion: string): boolean
	if expected == STUDIO_VERSION then
		return actual == studioVersion
	end
	if type(expected) ~= "table" then
		return actual == expected
	end
	if type(actual) ~= "table" then
		return false
	end
	if getmetatable(actual) ~= nil then
		return false
	end

	for key, value in next, actual do
		local expectedValue = rawget(expected, key)
		if expectedValue == nil or not matchesExact(value, expectedValue, studioVersion) then
			return false
		end
	end
	for key in next, expected do
		if rawget(actual, key) == nil then
			return false
		end
	end

	return true
end

local function resolveRelay(candidate: any, persistent: boolean?): any
	local storage = game:GetService("ReplicatedStorage")
	local adapters = storage.RelayBenchmark.adapters
	local pinModule = adapters:FindFirstChild("RelayAdapterPin")
	if pinModule == nil or not pinModule:IsA("ModuleScript") then return REJECTED end
	local ok, pin = pcall(require, pinModule)
	if not ok or type(pin) ~= "table" then return REJECTED end
	local identity = rawget(pin, "identity")
	local library = if type(identity) == "table" then rawget(identity, "library") else nil
	local provenance = if type(library) == "table" then rawget(library, "provenance") else nil
	local revision = if type(provenance) == "table" then rawget(provenance, "revision") else nil
	local checksum = if type(provenance) == "table" then rawget(provenance, "checksum") else nil
	if type(revision) ~= "string" or (#revision ~= 40 and #revision ~= 64)
		or string.match(revision, "^[0-9a-f]+$") == nil
		or type(checksum) ~= "string" or #checksum ~= 71
		or string.sub(checksum, 1, 7) ~= "sha256:" or string.match(string.sub(checksum, 8), "^[0-9a-f]+$") == nil
	then return REJECTED end
	local expected = {
		moduleId = "relay-reliable",
		artifact = { kind = "RepositoryModule", digest = checksum },
		identity = {
			id = "relay-reliable", displayName = "Relay Reliable", lane = "EquivalentSemantics",
			integrationKind = "Runtime",
			library = {
				id = "relay", displayName = "Relay", version = require(storage.Relay).VERSION,
				provenance = {
					kind = "Repository", sourceRepository = "https://github.com/steven-dinh/relay",
					revision = revision, checksum = checksum, license = "MIT",
				},
			},
			semantics = {
				broadcastMode = "NativeBroadcast", intentionalAddedDeliveryFrames = 0,
				repetitionIsolation = if persistent then "PersistentSession" else "SessionRestart",
			},
			capabilities = {
				directions = { "ClientToServer", "ServerToClient" },
				deliverySemantics = { "ReliableOrdered" }, payloadIds = { "state", "tiny" },
			},
		},
	}
	if not matchesExact(pin, expected, "") or not matchesExact(candidate, expected, "") then return REJECTED end
	if resolvedRelay == nil then
		resolvedRelay = table.freeze({
			kind = "Resolved", moduleId = "relay-reliable", factory = require(adapters.RelayReliable),
		})
	end
	return resolvedRelay
end

local function resolveExternal(candidate: any, persistent: boolean?): any
	local storage = game:GetService("ReplicatedStorage")
	local benchmark = storage.RelayBenchmark
	local adapters = benchmark.adapters
	local pinModule = adapters:FindFirstChild("ExternalAdapterPin")
	local selectedModule = adapters:FindFirstChild("ExternalSelected")
	if pinModule == nil or not pinModule:IsA("ModuleScript")
		or selectedModule == nil or not selectedModule:IsA("ModuleScript")
	then
		return REJECTED
	end
	local pinOk, pin = pcall(require, pinModule)
	if not pinOk or type(pin) ~= "table" or getmetatable(pin) ~= nil then return REJECTED end
	local moduleId = rawget(pin, "moduleId")
	local artifact = rawget(pin, "artifact")
	local identity = rawget(pin, "identity")
	local semantics = if type(identity) == "table" then rawget(identity, "semantics") else nil
	local library = if type(identity) == "table" then rawget(identity, "library") else nil
	local provenance = if type(library) == "table" then rawget(library, "provenance") else nil
	if type(moduleId) ~= "string" or rawget(EXTERNAL_IDS, moduleId) ~= true
		or type(identity) ~= "table" or rawget(identity, "id") ~= moduleId
		or type(semantics) ~= "table"
		or rawget(semantics, "repetitionIsolation") ~= (if persistent then "PersistentSession" else "ProcessRestart")
		or type(artifact) ~= "table" or rawget(artifact, "kind") ~= "RepositoryModule"
		or type(provenance) ~= "table" or rawget(provenance, "kind") ~= "Repository"
		or rawget(artifact, "digest") ~= rawget(provenance, "checksum")
		or not matchesExact(candidate, pin, "")
	then
		return REJECTED
	end
	if resolvedExternal ~= nil then
		return if resolvedExternal.moduleId == moduleId then resolvedExternal else REJECTED
	end
	local selectedOk, selectedFactory = pcall(require, selectedModule)
	local readinessOk, ExternalReadiness = pcall(require, benchmark.Runner.ExternalReadiness)
	if not selectedOk or not readinessOk or type(ExternalReadiness) ~= "table"
		or type(rawget(ExternalReadiness, "wrapFactory")) ~= "function"
	then
		return REJECTED
	end
	local wrappedOk, wrappedFactory = pcall(ExternalReadiness.wrapFactory, moduleId, selectedFactory)
	if not wrappedOk then return REJECTED end
	resolvedExternal = table.freeze({
		kind = "Resolved",
		moduleId = moduleId,
		factory = wrappedFactory,
	})
	return resolvedExternal
end

local function resolve(...: any)
	local argumentCount = select("#", ...)
	if argumentCount ~= 1 and argumentCount ~= 2 then
		return REJECTED
	end

	local candidate = select(1, ...)
	local admission = if argumentCount == 2 then select(2, ...) else nil
	local persistent = admission == "PersistentBenchmark"
	local moduleId = if type(candidate) == "table" then rawget(candidate, "moduleId") else nil
	if type(moduleId) == "string" and rawget(EXTERNAL_IDS, moduleId) == true then
		if argumentCount ~= 2 or (admission ~= "ProcessRepetition" and not persistent) then return REJECTED end
		return resolveExternal(candidate, persistent)
	end
	if argumentCount ~= 1 and not persistent then return REJECTED end
	if type(candidate) == "table" and rawget(candidate, "moduleId") == "relay-reliable" then
		return resolveRelay(candidate, persistent)
	end
	local identity = if type(candidate) == "table" then rawget(candidate, "identity") else nil
	local library = if type(identity) == "table" then rawget(identity, "library") else nil
	local studioVersion = if type(library) == "table" then rawget(library, "version") else nil
	local expected = NATIVE_ADAPTER
	if persistent then
		expected = table.clone(NATIVE_ADAPTER)
		expected.identity = table.clone(NATIVE_ADAPTER.identity)
		expected.identity.semantics = table.clone(NATIVE_ADAPTER.identity.semantics)
		expected.identity.semantics.repetitionIsolation = "PersistentSession"
	end
	if type(studioVersion) ~= "string"
		or studioVersion == ""
		or not matchesExact(candidate, expected, studioVersion)
	then
		return REJECTED
	end
	if studioVersion ~= version() then
		return REJECTED
	end

	if resolved == nil then
		local factory = require(game:GetService("ReplicatedStorage").RelayBenchmark.adapters.NativeReliable)
		resolved = table.freeze({
			kind = "Resolved",
			moduleId = "native-reliable",
			factory = factory,
		})
	end

	return resolved
end

return table.freeze({ resolve = resolve })
