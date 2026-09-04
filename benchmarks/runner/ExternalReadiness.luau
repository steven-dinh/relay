--!strict

-- Process-isolated external adapters may initialize module singletons and yield
-- while their replicated transport is discovered. Prewarm owns that work before
-- AdapterContract enters its deliberately non-yielding setup boundary. The
-- wrapped ready method only inspects exact, already-local replicated state.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MAX_WAIT_SECONDS = 120

local READY = table.freeze({ kind = "Ready" })
local FAILED = table.freeze({ kind = "Failed" })
local UNSUPPORTED = table.freeze({ kind = "Unsupported", reason = "FrameBoundUnproven" })

local RUNTIME_IDS = table.freeze({
	quicknet = true,
	bytenet = true,
	satset = true,
	warp = true,
	["suphi-packet"] = true,
})
local GENERATED_IDS = table.freeze({
	blink = true,
	zap = true,
	["netray-compile"] = true,
})

local function knownAdapter(adapterId: any): boolean
	return type(adapterId) == "string"
		and (rawget(RUNTIME_IDS, adapterId) == true or rawget(GENERATED_IDS, adapterId) == true)
end

local function oneChild(parent: Instance, name: string, className: string): Instance?
	local found: Instance? = nil
	for _, child in parent:GetChildren() do
		if child.Name == name then
			if found ~= nil or not child:IsA(className) then return nil end
			found = child
		end
	end
	return found
end

local function resourceLibrary(adapterId: string, resourceRoot: Instance): Instance?
	local className = if rawget(GENERATED_IDS, adapterId) then "Folder" else "ModuleScript"
	return oneChild(resourceRoot, "Library", className)
end

local function exactResourceRoot(adapterId: string, resourceRoot: any): boolean
	if typeof(resourceRoot) ~= "Instance" or not resourceRoot:IsA("Folder") then return false end
	local library = resourceLibrary(adapterId, resourceRoot)
	if library == nil then return false end
	local expectedChildren = if adapterId == "warp" then 2 else 1
	if #resourceRoot:GetChildren() ~= expectedChildren then return false end
	if adapterId == "warp" and oneChild(resourceRoot, "Endpoint", "ModuleScript") == nil then return false end
	return true
end

local function quickNetRemotes(resourceRoot: Instance): (Instance?, Instance?)
	local library = resourceLibrary("quicknet", resourceRoot)
	if library == nil then return nil, nil end
	return oneChild(library, "QuickNetRemote", "RemoteEvent"),
		oneChild(library, "QuickNetUnreliable", "UnreliableRemoteEvent")
end

local function exactQuickNet(resourceRoot: Instance): boolean
	local reliable, unreliable = quickNetRemotes(resourceRoot)
	if reliable == nil or unreliable == nil then return false end
	local eventId = reliable:GetAttribute("RelayEventV1")
	return type(eventId) == "number" and eventId % 1 == 0 and eventId >= 1 and eventId <= 255
end

local function exactByteNet(): boolean
	local storage = oneChild(ReplicatedStorage, "BytenetStorage", "Folder")
	local reliable = oneChild(ReplicatedStorage, "ByteNetReliable", "RemoteEvent")
	local unreliable = oneChild(ReplicatedStorage, "ByteNetUnreliable", "UnreliableRemoteEvent")
	if storage == nil or reliable == nil or unreliable == nil then return false end
	local namespace = oneChild(storage, "RelayEventV1", "StringValue")
	return namespace ~= nil and (namespace :: StringValue).Value ~= ""
end

local function exactSatset(): boolean
	local bridge = oneChild(ReplicatedStorage, "__SatsetBridge", "Folder")
	return bridge ~= nil
		and oneChild(bridge, "__SatsetReliable", "RemoteEvent") ~= nil
		and oneChild(bridge, "__SatsetUnreliable", "UnreliableRemoteEvent") ~= nil
		and oneChild(bridge, "__SatsetChannelReliable", "RemoteEvent") ~= nil
		and oneChild(bridge, "__SatsetChannelUnreliable", "UnreliableRemoteEvent") ~= nil
end

local function exactWarp(resourceRoot: Instance): boolean
	local library = resourceLibrary("warp", resourceRoot)
	if library == nil then return false end
	local index = oneChild(library, "Index", "ModuleScript")
	local event = if index == nil then nil else oneChild(index, "Event", "ModuleScript")
	if event == nil then return false end
	local reliable = oneChild(event, "Reliable", "RemoteEvent")
	return reliable ~= nil
		and oneChild(event, "Unreliable", "UnreliableRemoteEvent") ~= nil
		and oneChild(event, "Request", "RemoteEvent") ~= nil
		and reliable:GetAttribute("RelayEventV1") == 1
		and reliable:GetAttribute("1") == "RelayEventV1"
end

local function exactBlink(): boolean
	return oneChild(ReplicatedStorage, "RELAY_EVENT_V1_BLINK_RELIABLE_REMOTE", "RemoteEvent") ~= nil
		and oneChild(
			ReplicatedStorage,
			"RELAY_EVENT_V1_BLINK_UNRELIABLE_REMOTE",
			"UnreliableRemoteEvent"
		) ~= nil
end

local function exactZap(): boolean
	local folder = oneChild(ReplicatedStorage, "RELAY_EVENT_V1_ZAP", "Folder")
	return folder ~= nil and oneChild(folder, "RELAY_EVENT_V1_RELIABLE", "RemoteEvent") ~= nil
end

local function exactNetRay(): boolean
	return oneChild(ReplicatedStorage, "RELAY_EVENT_V1_NETRAY_RELIABLE", "RemoteEvent") ~= nil
		and oneChild(ReplicatedStorage, "RELAY_EVENT_V1_NETRAY_UNRELIABLE", "UnreliableRemoteEvent") ~= nil
		and oneChild(ReplicatedStorage, "RELAY_EVENT_V1_NETRAY_FUNCTION", "RemoteFunction") ~= nil
end

local function exactSuphi(resourceRoot: Instance): boolean
	local library = resourceLibrary("suphi-packet", resourceRoot)
	local remote = if library == nil then nil else oneChild(library, "RemoteEvent", "RemoteEvent")
	if remote == nil then return false end
	local eventId = remote:GetAttribute("RelayEventV1")
	return type(eventId) == "number" and eventId % 1 == 0 and eventId >= 1 and eventId <= 255
end

local function locallyReady(adapterId: string, resourceRoot: Instance): boolean
	if not exactResourceRoot(adapterId, resourceRoot) then return false end
	if adapterId == "quicknet" then return exactQuickNet(resourceRoot) end
	if adapterId == "bytenet" then return exactByteNet() end
	if adapterId == "satset" then return exactSatset() end
	if adapterId == "warp" then return exactWarp(resourceRoot) end
	if adapterId == "blink" then return exactBlink() end
	if adapterId == "zap" then return exactZap() end
	if adapterId == "netray-compile" then return exactNetRay() end
	if adapterId == "suphi-packet" then return exactSuphi(resourceRoot) end
	return false
end

local function readNow(timeoutNowSeconds: () -> number): number?
	local ok, value = pcall(timeoutNowSeconds)
	if not ok or type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		return nil
	end
	return value
end

local function waitUntil(predicate: () -> boolean, deadline: number, timeoutNowSeconds: () -> number): boolean
	while true do
		local ok, value = pcall(predicate)
		if not ok then return false end
		if value == true then return true end
		local now = readNow(timeoutNowSeconds)
		if now == nil or now >= deadline then return false end
		RunService.PostSimulation:Wait()
	end
end

local function requireTarget(adapterId: string, resourceRoot: Instance, side: "Server" | "Client"): Instance?
	local library = resourceLibrary(adapterId, resourceRoot)
	if library == nil then return nil end
	if adapterId == "warp" then
		return oneChild(resourceRoot, "Endpoint", "ModuleScript")
	elseif rawget(GENERATED_IDS, adapterId) then
		return oneChild(library, side, "ModuleScript")
	end
	return library
end

local function boundedRequire(target: Instance, deadline: number, timeoutNowSeconds: () -> number): boolean
	local complete = false
	local accepted = false
	local worker = task.spawn(function()
		local call = table.pack(pcall(require, target))
		accepted = call[1] == true and call.n == 2 and call[2] ~= nil
		complete = true
	end)
	while not complete do
		local now = readNow(timeoutNowSeconds)
		if now == nil or now >= deadline then
			pcall(task.cancel, worker)
			return false
		end
		RunService.PostSimulation:Wait()
	end
	return accepted
end

local function serverBootstrapReady(adapterId: string, resourceRoot: Instance): boolean
	if adapterId == "quicknet" then
		local reliable, unreliable = quickNetRemotes(resourceRoot)
		return reliable ~= nil and unreliable ~= nil
	elseif adapterId == "bytenet" then
		return oneChild(ReplicatedStorage, "BytenetStorage", "Folder") ~= nil
			and oneChild(ReplicatedStorage, "ByteNetReliable", "RemoteEvent") ~= nil
			and oneChild(ReplicatedStorage, "ByteNetUnreliable", "UnreliableRemoteEvent") ~= nil
	elseif adapterId == "satset" then
		-- Satset creates its bridge during adapter setup; requiring the cached
		-- module is the complete yielding portion of server prewarm.
		return true
	end
	return locallyReady(adapterId, resourceRoot)
end

local function prewarm(
	adapterId: string,
	resourceRoot: Instance,
	side: "Server" | "Client",
	timeoutNowSeconds: () -> number
): any
	if not knownAdapter(adapterId) or (side ~= "Server" and side ~= "Client")
		or type(timeoutNowSeconds) ~= "function"
		or typeof(resourceRoot) ~= "Instance"
		or not resourceRoot:IsA("Folder")
	then
		return FAILED
	end
	if adapterId == "suphi-packet" then
		-- Its client scheduler only flushes after accumulated time is strictly
		-- greater than 1/60 and exposes no public flush. Event V1's one-added-
		-- frame bound therefore cannot be established.
		return UNSUPPORTED
	end
	local now = readNow(timeoutNowSeconds)
	if now == nil then return FAILED end
	local deadline = now + MAX_WAIT_SECONDS
	if side == "Client" then
		if not waitUntil(function()
			return locallyReady(adapterId, resourceRoot)
				and requireTarget(adapterId, resourceRoot, side) ~= nil
		end, deadline, timeoutNowSeconds) then
			return FAILED
		end
	elseif not exactResourceRoot(adapterId, resourceRoot) then
		return FAILED
	end
	local target = requireTarget(adapterId, resourceRoot, side)
	if target == nil or not boundedRequire(target, deadline, timeoutNowSeconds) then return FAILED end
	local predicate = if side == "Server" then serverBootstrapReady else locallyReady
	if not waitUntil(function()
		return predicate(adapterId, resourceRoot)
	end, deadline, timeoutNowSeconds) then
		return FAILED
	end
	return READY
end

local function wrapSide(adapterId: string, resourceRoot: Instance, candidate: any): any
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil or type(rawget(candidate, "ready")) ~= "function" then
		error("EXTERNAL_READINESS_E_SIDE", 0)
	end
	local wrapped = {}
	for key, value in next, candidate do
		if type(key) ~= "string" or type(value) ~= "function" then error("EXTERNAL_READINESS_E_SIDE", 0) end
		wrapped[key] = value
	end
	local ready = candidate.ready
	wrapped.ready = function(): boolean
		if not locallyReady(adapterId, resourceRoot) then return false end
		return ready()
	end
	table.freeze(wrapped)
	return wrapped
end

local function wrapFactory(adapterId: string, candidate: any): any
	if not knownAdapter(adapterId) or type(candidate) ~= "table" or getmetatable(candidate) ~= nil
		or type(rawget(candidate, "constructServer")) ~= "function"
		or type(rawget(candidate, "constructClient")) ~= "function"
	then
		error("EXTERNAL_READINESS_E_FACTORY", 0)
	end
	local constructServer = candidate.constructServer
	local constructClient = candidate.constructClient
	local factory = {
		constructServer = function(context: any): any
			return wrapSide(adapterId, context.resourceRoot, constructServer(context))
		end,
		constructClient = function(context: any): any
			return wrapSide(adapterId, context.resourceRoot, constructClient(context))
		end,
	}
	table.freeze(factory)
	return factory
end

return table.freeze({
	MAX_WAIT_SECONDS = MAX_WAIT_SECONDS,
	prewarm = prewarm,
	wrapFactory = wrapFactory,
})
