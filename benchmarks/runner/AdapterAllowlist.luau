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

local function resolve(...: any)
	if select("#", ...) ~= 1 then
		return REJECTED
	end

	local candidate = select(1, ...)
	local identity = if type(candidate) == "table" then rawget(candidate, "identity") else nil
	local library = if type(identity) == "table" then rawget(identity, "library") else nil
	local studioVersion = if type(library) == "table" then rawget(library, "version") else nil
	if type(studioVersion) ~= "string"
		or studioVersion == ""
		or not matchesExact(candidate, NATIVE_ADAPTER, studioVersion)
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
