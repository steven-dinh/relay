--!strict

local Contract = require("../event-v1")

export type RepositoryProvenance = {
	kind: "Repository",
	sourceRepository: string,
	revision: string,
	checksum: string,
	license: string,
}
export type EngineBuiltInProvenance = { kind: "EngineBuiltIn", studioVersion: string }
export type AdapterIdentity = {
	id: string,
	displayName: string,
	lane: "EquivalentSemantics" | "NativeBest",
	integrationKind: "Runtime" | "Generated" | "EngineBuiltIn",
	library: {
		id: string,
		displayName: string,
		version: string,
		provenance: RepositoryProvenance | EngineBuiltInProvenance,
	},
	semantics: {
		broadcastMode: "Unsupported" | "NativeBroadcast" | "AdapterFanOut",
		intentionalAddedDeliveryFrames: number,
		repetitionIsolation: "SessionRestart" | "ProcessRestart",
	},
	capabilities: {
		directions: { "ClientToServer" | "ServerToClient" },
		deliverySemantics: { "ReliableOrdered" },
		payloadIds: { string },
	},
}

export type IdentityMode = "Normalize" | "Canonical"
export type IdentityIssueCode =
	"TYPE"
	| "KEYSET"
	| "ENUM"
	| "RANGE"
	| "ORDER"
	| "RELATION"
	| "LIMIT"
	| "ALIAS"
	| "CYCLE"
	| "METATABLE"
	| "NONCANONICAL"
export type IdentityIssue = {
	code: IdentityIssueCode,
	path: string,
}
export type IdentityCheckResult =
	{ kind: "Valid", value: AdapterIdentity }
	| { kind: "Invalid", issue: IdentityIssue }

export type CaseSelection =
	{ kind: "Workload", workloadId: string, recipientCount: number }
	| { kind: "SeparateProbe", probeId: string }

export type Requirement =
	{ capability: "Direction", required: "ClientToServer" | "ServerToClient" }
	| { capability: "DeliverySemantics", required: "ReliableOrdered" }
	| { capability: "Payload", required: string }
	| { capability: "BroadcastMode", required: "Broadcast" }

export type ResolvedSelection =
	{
		kind: "Workload",
		workloadId: string,
		recipientCount: number,
		clientProcessCount: number,
		payloadId: string,
		direction: "ClientToServer" | "ServerToClient",
		audience: "Server" | "Broadcast",
		requirements: { Requirement },
	}
	| {
		kind: "SeparateProbe",
		probeId: string,
		clientCount: number,
		clientProcessCount: number,
		payloadId: string,
		requestDirection: "ClientToServer",
		responseDirection: "ServerToClient",
		responseAudience: "Broadcast",
		requirements: { Requirement },
	}

export type SelectionResult =
	{ kind: "Valid", value: ResolvedSelection }
	| { kind: "Invalid", path: string }

local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local MAX_DEPTH = 6
local MAX_TABLE_NODES = 4_096
local MAX_TABLE_ENTRIES = 131_072
local ISSUE_MARKER = {}

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for key, nested in value do
		deepFreeze(key)
		deepFreeze(nested)
	end
	table.freeze(value)
end

local function reject(code: IdentityIssueCode, path: string): never
	error({ marker = ISSUE_MARKER, code = code, path = path }, 0)
end

local function preflight(root: any, rootPath: string)
	local seen: { [table]: string } = {}
	local nodeCount = 0
	local entryCount = 0

	local function visit(value: any, depth: number, path: string)
		if type(value) ~= "table" then
			return
		end
		if getmetatable(value) ~= nil then
			reject("METATABLE", path)
		end
		local state = seen[value]
		if state == "active" then
			reject("CYCLE", path)
		elseif state ~= nil then
			reject("ALIAS", path)
		end
		if depth > MAX_DEPTH then
			reject("LIMIT", path)
		end
		nodeCount += 1
		if nodeCount > MAX_TABLE_NODES then
			reject("LIMIT", path)
		end
		seen[value] = "active"
		local key = next(value)
		while key ~= nil do
			entryCount += 1
			if entryCount > MAX_TABLE_ENTRIES then
				reject("LIMIT", path)
			end
			visit(key, depth + 1, path)
			visit(rawget(value, key), depth + 1, path)
			key = next(value, key)
		end
		seen[value] = "done"
	end

	visit(root, 1, rootPath)
end

local function exactKeys(value: any, keys: { [string]: boolean }, path: string): { [any]: any }
	if type(value) ~= "table" then
		reject("TYPE", path)
	end
	local found = 0
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or keys[key] ~= true then
			reject("KEYSET", path)
		end
		found += 1
		key = next(value, key)
	end
	local required = 0
	for _ in keys do
		required += 1
	end
	if found ~= required then
		reject("KEYSET", path)
	end
	return value
end

local function denseArray(value: any, maximum: number, path: string): ({ any }, number)
	if type(value) ~= "table" then
		reject("TYPE", path)
	end
	local count = 0
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			reject("KEYSET", path)
		end
		if key > maximum then
			reject("LIMIT", path)
		end
		count += 1
		key = next(value, key)
	end
	if count > maximum then
		reject("LIMIT", path)
	end
	for index = 1, count do
		if rawget(value, index) == nil then
			reject("KEYSET", path)
		end
	end
	return value, count
end

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: number): boolean
	return value == 0 and 1 / value == -math.huge
end

local function safeInteger(value: any, path: string): number
	if type(value) ~= "number" then
		reject("TYPE", path)
	end
	if not isFinite(value) or isNegativeZero(value) or value % 1 ~= 0 or value < 0 or value > MAX_SAFE_INTEGER then
		reject("RANGE", path)
	end
	return value
end

local function expectEnum(value: any, values: { [string]: boolean }, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if values[value] == nil then
		reject("ENUM", path)
	end
	return value
end

local function printableAscii(value: any, minimum: number, maximum: number, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value < minimum or #value > maximum then
		reject("RANGE", path)
	end
	for index = 1, #value do
		local byte = string.byte(value, index)
		if byte < 32 or byte > 126 then
			reject("RANGE", path)
		end
	end
	return value
end

local function normalizedLabel(value: any, maximum: number, path: string, normalize: boolean): string
	local label = printableAscii(value, 1, maximum, path)
	local canonical = string.gsub(string.gsub(label, "^ +", ""), " +$", "")
	canonical = string.gsub(canonical, " +", " ")
	if #canonical == 0 then
		reject("RANGE", path)
	end
	if not normalize and label ~= canonical then
		reject("NONCANONICAL", path)
	end
	return canonical
end

local function machineId(value: any, path: string): string
	if type(value) ~= "string" or #value < 1 or #value > 64 or string.match(value, "^[a-z0-9][a-z0-9._-]*$") == nil then
		reject(if type(value) == "string" then "RANGE" else "TYPE", path)
	end
	return value
end

local function lowercaseHex(value: any, lengths: { number }, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	local allowed = false
	for _, length in lengths do
		if #value == length then
			allowed = true
		end
	end
	if not allowed or string.match(value, "^[0-9a-f]+$") == nil then
		reject("RANGE", path)
	end
	return value
end

local function sha256(value: any, path: string): string
	if type(value) ~= "string" or #value ~= 71 or string.sub(value, 1, 7) ~= "sha256:" or string.match(string.sub(value, 8), "^[0-9a-f]+$") == nil then
		reject(if type(value) == "string" then "RANGE" else "TYPE", path)
	end
	return value
end

local function repositoryUrl(value: any, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value < 9 or #value > 2_048 or string.sub(value, 1, 8) ~= "https://" or string.sub(value, -1) == "/" then
		reject("RANGE", path)
	end
	local remainder = string.sub(value, 9)
	local slash = string.find(remainder, "/", 1, true)
	local host = if slash then string.sub(remainder, 1, slash - 1) else remainder
	local pathPart = if slash then string.sub(remainder, slash + 1) else nil
	if #host == 0 or string.find(host, ".", 1, true) == nil or string.match(host, "^[a-z0-9.-]+$") == nil then
		reject("RANGE", path)
	end
	for label in string.gmatch(host .. ".", "(.-)%.") do
		if #label == 0 or (#label == 1 and string.match(label, "^[a-z0-9]$") == nil) or (#label > 1 and string.match(label, "^[a-z0-9][a-z0-9-]*[a-z0-9]$") == nil) then
			reject("RANGE", path)
		end
	end
	if pathPart ~= nil then
		if #pathPart == 0 or string.match(pathPart, "^[A-Za-z0-9._~/-]+$") == nil then
			reject("RANGE", path)
		end
		for segment in string.gmatch(pathPart .. "/", "(.-)/") do
			if segment == "" or segment == "." or segment == ".." then
				reject("RANGE", path)
			end
		end
	end
	return value
end

local function copyOrderedSubset(
	arrayValue: any,
	allowed: { [string]: boolean },
	arrayPath: string,
	normalize: boolean
): { string }
	local array, count = denseArray(arrayValue, 8, arrayPath)
	local copied = table.create(count)
	local previous = nil
	for index = 1, count do
		local item = expectEnum(rawget(array, index), allowed, arrayPath .. "[]")
		if previous ~= nil and item <= previous and not normalize then
			reject("ORDER", arrayPath)
		end
		for prior = 1, index - 1 do
			if copied[prior] == item then
				reject("RELATION", arrayPath)
			end
		end
		copied[index] = item
		previous = item
	end
	if normalize then
		table.sort(copied)
	end
	return copied
end

local function copyIdentity(
	value: any,
	studioVersion: string,
	path: string,
	normalize: boolean
): AdapterIdentity
	exactKeys(value, {
		id = true,
		displayName = true,
		lane = true,
		integrationKind = true,
		library = true,
		semantics = true,
		capabilities = true,
	}, path)
	local integrationKind = expectEnum(rawget(value, "integrationKind"), {
		Runtime = true,
		Generated = true,
		EngineBuiltIn = true,
	}, path .. ".integrationKind")
	local library = exactKeys(rawget(value, "library"), {
		id = true,
		displayName = true,
		version = true,
		provenance = true,
	}, path .. ".library")
	local provenance = rawget(library, "provenance")
	if type(provenance) ~= "table" then
		reject("TYPE", path .. ".library.provenance")
	end
	local copiedProvenance: RepositoryProvenance | EngineBuiltInProvenance
	if rawget(provenance, "kind") == "Repository" then
		exactKeys(provenance, {
			kind = true,
			sourceRepository = true,
			revision = true,
			checksum = true,
			license = true,
		}, path .. ".library.provenance")
		if integrationKind == "EngineBuiltIn" then
			reject("RELATION", path .. ".library.provenance")
		end
		local license = rawget(provenance, "license")
		if type(license) ~= "string" or #license < 1 or #license > 64 or string.match(license, "^[A-Za-z0-9][A-Za-z0-9.+-]*$") == nil then
			reject(if type(license) == "string" then "RANGE" else "TYPE", path .. ".library.provenance.license")
		end
		copiedProvenance = {
			kind = "Repository",
			sourceRepository = repositoryUrl(rawget(provenance, "sourceRepository"), path .. ".library.provenance.sourceRepository"),
			revision = lowercaseHex(rawget(provenance, "revision"), { 40, 64 }, path .. ".library.provenance.revision"),
			checksum = sha256(rawget(provenance, "checksum"), path .. ".library.provenance.checksum"),
			license = license,
		}
	elseif rawget(provenance, "kind") == "EngineBuiltIn" then
		exactKeys(provenance, { kind = true, studioVersion = true }, path .. ".library.provenance")
		if integrationKind ~= "EngineBuiltIn" then
			reject("RELATION", path .. ".library.provenance")
		end
		copiedProvenance = {
			kind = "EngineBuiltIn",
			studioVersion = normalizedLabel(
				rawget(provenance, "studioVersion"),
				64,
				path .. ".library.provenance.studioVersion",
				normalize
			),
		}
	else
		reject("ENUM", path .. ".library.provenance.kind")
	end

	local semantics = exactKeys(rawget(value, "semantics"), {
		broadcastMode = true,
		intentionalAddedDeliveryFrames = true,
		repetitionIsolation = true,
	}, path .. ".semantics")
	local broadcastMode = expectEnum(rawget(semantics, "broadcastMode"), {
		Unsupported = true,
		NativeBroadcast = true,
		AdapterFanOut = true,
	}, path .. ".semantics.broadcastMode")
	local addedFrames = safeInteger(
		rawget(semantics, "intentionalAddedDeliveryFrames"),
		path .. ".semantics.intentionalAddedDeliveryFrames"
	)
	if addedFrames > Contract.maximumAddedDeliveryFrames or (broadcastMode == "Unsupported" and addedFrames ~= 0) then
		reject("RELATION", path .. ".semantics")
	end

	local capabilities = exactKeys(rawget(value, "capabilities"), {
		directions = true,
		deliverySemantics = true,
		payloadIds = true,
	}, path .. ".capabilities")
	local copiedCapabilities = {
		directions = copyOrderedSubset(rawget(capabilities, "directions"), {
			ClientToServer = true,
			ServerToClient = true,
		}, path .. ".capabilities.directions", normalize),
		deliverySemantics = copyOrderedSubset(rawget(capabilities, "deliverySemantics"), {
			ReliableOrdered = true,
		}, path .. ".capabilities.deliverySemantics", normalize),
		payloadIds = copyOrderedSubset(rawget(capabilities, "payloadIds"), {
			state = true,
			tiny = true,
		}, path .. ".capabilities.payloadIds", normalize),
	}
	local copiedLibrary = {
		id = machineId(rawget(library, "id"), path .. ".library.id"),
		displayName = normalizedLabel(rawget(library, "displayName"), 128, path .. ".library.displayName", normalize),
		version = normalizedLabel(rawget(library, "version"), 64, path .. ".library.version", normalize),
		provenance = copiedProvenance,
	}
	if integrationKind == "EngineBuiltIn"
		and (
			(copiedProvenance :: EngineBuiltInProvenance).studioVersion ~= copiedLibrary.version
			or copiedLibrary.version ~= studioVersion
		)
	then
		reject("RELATION", path .. ".library.provenance")
	end
	return {
		id = machineId(rawget(value, "id"), path .. ".id"),
		displayName = normalizedLabel(rawget(value, "displayName"), 128, path .. ".displayName", normalize),
		lane = expectEnum(rawget(value, "lane"), { EquivalentSemantics = true, NativeBest = true }, path .. ".lane") :: any,
		integrationKind = integrationKind :: any,
		library = copiedLibrary :: any,
		semantics = {
			broadcastMode = broadcastMode :: any,
			intentionalAddedDeliveryFrames = addedFrames,
			repetitionIsolation = expectEnum(rawget(semantics, "repetitionIsolation"), {
				SessionRestart = true,
				ProcessRestart = true,
			}, path .. ".semantics.repetitionIsolation") :: any,
		},
		capabilities = copiedCapabilities :: any,
	}
end

local function check(
	candidate: unknown,
	mode: IdentityMode,
	studioVersion: string,
	rootPath: string
): IdentityCheckResult
	local ok, output = pcall(function(): AdapterIdentity
		preflight(candidate, rootPath)
		if mode ~= "Normalize" and mode ~= "Canonical" then
			reject("ENUM", rootPath)
		end
		return copyIdentity(candidate, studioVersion, rootPath, mode == "Normalize")
	end)
	if not ok then
		if type(output) ~= "table" or rawget(output, "marker") ~= ISSUE_MARKER then
			error(output, 0)
		end
		local invalid: IdentityCheckResult = {
			kind = "Invalid",
			issue = {
				code = rawget(output, "code"),
				path = rawget(output, "path"),
			},
		}
		deepFreeze(invalid)
		return invalid
	end
	local valid: IdentityCheckResult = { kind = "Valid", value = output }
	deepFreeze(valid)
	return valid
end

local function selectionInvalid(path: string): SelectionResult
	local result: SelectionResult = { kind = "Invalid", path = path }
	deepFreeze(result)
	return result
end

local function selectionHasExactKeys(selection: { [any]: any }, expected: { [string]: boolean }): boolean
	local found = 0
	local key = next(selection)
	while key ~= nil do
		if type(key) ~= "string" or expected[key] ~= true then
			return false
		end
		found += 1
		key = next(selection, key)
	end
	local required = 0
	for _ in expected do
		required += 1
	end
	return found == required
end

local function resolveSelection(selection: CaseSelection): SelectionResult
	if type(selection) ~= "table" or getmetatable(selection) ~= nil then
		return selectionInvalid("$.selection")
	end
	local kind = rawget(selection, "kind")
	if kind == "Workload" then
		if not selectionHasExactKeys(selection, { kind = true, workloadId = true, recipientCount = true }) then
			return selectionInvalid("$.selection")
		end
		local workloadId = rawget(selection, "workloadId")
		if type(workloadId) ~= "string" then
			return selectionInvalid("$.selection.workloadId")
		end
		local workload = nil
		for _, candidate in Contract.workloads do
			if candidate.id == workloadId then
				workload = candidate
				break
			end
		end
		if workload == nil then
			return selectionInvalid("$.selection.workloadId")
		end
		local recipientCount = rawget(selection, "recipientCount")
		if type(recipientCount) ~= "number"
			or not isFinite(recipientCount)
			or isNegativeZero(recipientCount)
			or recipientCount % 1 ~= 0
			or recipientCount < 1
			or recipientCount > MAX_SAFE_INTEGER
		then
			return selectionInvalid("$.selection.recipientCount")
		end
		local recipientAllowed = false
		for _, allowed in workload.recipientCounts do
			if allowed == recipientCount then
				recipientAllowed = true
				break
			end
		end
		if not recipientAllowed then
			return selectionInvalid("$.selection.recipientCount")
		end
		assert(workload.senderCount == 1, "Event V1 workloads must remain single-sender")
		local clientProcessCount = if workload.audience == "Broadcast"
			then recipientCount
			else workload.senderCount
		local requirements: { Requirement } = {
			{ capability = "Direction", required = workload.direction },
			{ capability = "DeliverySemantics", required = "ReliableOrdered" },
			{ capability = "Payload", required = workload.payloadId },
		}
		if workload.audience == "Broadcast" then
			table.insert(requirements, { capability = "BroadcastMode", required = "Broadcast" })
		end
		local result: SelectionResult = {
			kind = "Valid",
			value = {
				kind = "Workload",
				workloadId = workload.id,
				recipientCount = recipientCount,
				clientProcessCount = clientProcessCount,
				payloadId = workload.payloadId,
				direction = workload.direction,
				audience = workload.audience,
				requirements = requirements,
			},
		}
		deepFreeze(result)
		return result
	elseif kind == "SeparateProbe" then
		if not selectionHasExactKeys(selection, { kind = true, probeId = true }) then
			return selectionInvalid("$.selection")
		end
		local probeId = rawget(selection, "probeId")
		if type(probeId) ~= "string" then
			return selectionInvalid("$.selection.probeId")
		end
		local probe = nil
		for _, candidate in Contract.probes do
			if candidate.id == probeId then
				probe = candidate
				break
			end
		end
		if probe == nil then
			return selectionInvalid("$.selection.probeId")
		end
		local result: SelectionResult = {
			kind = "Valid",
			value = {
				kind = "SeparateProbe",
				probeId = probe.id,
				clientCount = probe.clientCount,
				clientProcessCount = probe.clientCount,
				payloadId = probe.payloadId,
				requestDirection = "ClientToServer",
				responseDirection = "ServerToClient",
				responseAudience = "Broadcast",
				requirements = {
					{ capability = "Direction", required = "ClientToServer" },
					{ capability = "Direction", required = "ServerToClient" },
					{ capability = "DeliverySemantics", required = "ReliableOrdered" },
					{ capability = "Payload", required = probe.payloadId },
					{ capability = "BroadcastMode", required = "Broadcast" },
				},
			},
		}
		deepFreeze(result)
		return result
	end
	return selectionInvalid("$.selection.kind")
end

local function arrayContains(values: { string }, target: string): boolean
	for index = 1, #values do
		if rawget(values, index) == target then
			return true
		end
	end
	return false
end

local function missingRequirements(identity: AdapterIdentity, requirements: { Requirement }): { Requirement }
	local missing: { Requirement } = {}
	local seen: { [string]: boolean } = {}
	for index = 1, #requirements do
		local requirement = rawget(requirements, index)
		local capability = rawget(requirement, "capability")
		local required = rawget(requirement, "required")
		local key = capability .. "\0" .. required
		if not seen[key] then
			seen[key] = true
			local satisfied
			if capability == "Direction" then
				satisfied = arrayContains(identity.capabilities.directions :: { string }, required)
			elseif capability == "DeliverySemantics" then
				satisfied = arrayContains(identity.capabilities.deliverySemantics :: { string }, required)
			elseif capability == "Payload" then
				satisfied = arrayContains(identity.capabilities.payloadIds, required)
			else
				satisfied = identity.semantics.broadcastMode == "NativeBroadcast"
					or identity.semantics.broadcastMode == "AdapterFanOut"
			end
			if not satisfied then
				table.insert(missing, { capability = capability, required = required } :: any)
			end
		end
	end
	deepFreeze(missing)
	return missing
end

local AdapterIdentity = {
	check = check,
	resolveSelection = resolveSelection,
	missingRequirements = missingRequirements,
}

table.freeze(AdapterIdentity)

return AdapterIdentity
