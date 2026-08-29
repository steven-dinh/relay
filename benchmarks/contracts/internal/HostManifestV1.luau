--!strict

local AdapterIdentity = require("./AdapterIdentity")

export type RepositoryModuleArtifact = {
	kind: "RepositoryModule",
	digest: string,
}

export type EngineBuiltInArtifact = {
	kind: "EngineBuiltIn",
}

export type HostManifest = {
	version: number,
	launchId: string,
	benchmarkSource: {
		revision: string,
		dirty: boolean,
	},
	contractFingerprint: string,
	adapter: {
		moduleId: string,
		artifact: RepositoryModuleArtifact | EngineBuiltInArtifact,
		identity: AdapterIdentity.AdapterIdentity,
	},
	selection: AdapterIdentity.CaseSelection,
	environment: {
		studio: {
			version: string,
			channel: string?,
		},
		host: {
			osFamily: "Windows" | "macOS",
			architecture: "x86_64" | "arm64",
			osVersion: string?,
			cpuModel: string?,
			logicalProcessorCount: number?,
			memoryMiB: number?,
			gpuModel: string?,
		},
	},
}

export type ManifestIssueCode =
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

export type ManifestIssue = {
	code: ManifestIssueCode,
	path: string,
}

export type ValidationResult =
	{ kind: "Valid", value: HostManifest }
	| { kind: "Invalid", issue: ManifestIssue }

local MAX_SAFE_INTEGER = 9_007_199_254_740_991
local MAX_DEPTH = 8
local MAX_TABLE_NODES = 128
local MAX_TABLE_ENTRIES = 1_024
local ISSUE_MARKER = {}

local function deepFreeze(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	local key = next(value)
	while key ~= nil do
		deepFreeze(key)
		deepFreeze(rawget(value, key))
		key = next(value, key)
	end
	table.freeze(value)
end

local function reject(code: ManifestIssueCode, path: string): never
	error({ marker = ISSUE_MARKER, code = code, path = path }, 0)
end

local function preflight(root: any)
	local seen: { [table]: string } = {}
	local nodeCount = 0
	local entryCount = 0

	local function visit(value: any, depth: number)
		if type(value) ~= "table" then
			return
		end
		if getmetatable(value) ~= nil then
			reject("METATABLE", "$")
		end
		local state = seen[value]
		if state == "active" then
			reject("CYCLE", "$")
		elseif state ~= nil then
			reject("ALIAS", "$")
		end
		if depth > MAX_DEPTH then
			reject("LIMIT", "$")
		end
		nodeCount += 1
		if nodeCount > MAX_TABLE_NODES then
			reject("LIMIT", "$")
		end
		seen[value] = "active"
		local key = next(value)
		while key ~= nil do
			entryCount += 1
			if entryCount > MAX_TABLE_ENTRIES then
				reject("LIMIT", "$")
			end
			visit(key, depth + 1)
			visit(rawget(value, key), depth + 1)
			key = next(value, key)
		end
		seen[value] = "done"
	end

	visit(root, 1)
end

local function exactKeys(value: any, expected: { [string]: boolean }, path: string): { [any]: any }
	if type(value) ~= "table" then
		reject("TYPE", path)
	end
	local found = 0
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or expected[key] ~= true then
			reject("KEYSET", path)
		end
		found += 1
		key = next(value, key)
	end
	local required = 0
	for _ in expected do
		required += 1
	end
	if found ~= required then
		reject("KEYSET", path)
	end
	return value
end

local function exactConditionalKeys(
	value: any,
	required: { [string]: boolean },
	optional: { [string]: boolean },
	path: string
): { [any]: any }
	if type(value) ~= "table" then
		reject("TYPE", path)
	end
	local key = next(value)
	while key ~= nil do
		if type(key) ~= "string" or (required[key] ~= true and optional[key] ~= true) then
			reject("KEYSET", path)
		end
		key = next(value, key)
	end
	for requiredKey in required do
		if rawget(value, requiredKey) == nil then
			reject("KEYSET", path)
		end
	end
	return value
end

local function expectBoolean(value: any, path: string): boolean
	if type(value) ~= "boolean" then
		reject("TYPE", path)
	end
	return value
end

local function expectEnum(value: any, allowed: { [string]: boolean }, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if allowed[value] ~= true then
		reject("ENUM", path)
	end
	return value
end

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isNegativeZero(value: number): boolean
	return value == 0 and 1 / value == -math.huge
end

local function boundedInteger(value: any, minimum: number, maximum: number, path: string): number
	if type(value) ~= "number" then
		reject("TYPE", path)
	end
	if not isFinite(value)
		or isNegativeZero(value)
		or value % 1 ~= 0
		or value < minimum
		or value > maximum
		or value > MAX_SAFE_INTEGER
	then
		reject("RANGE", path)
	end
	return value
end

local function token(value: any, maximum: number, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value < 1 or #value > maximum or string.match(value, "^[A-Za-z0-9._-]+$") == nil then
		reject("RANGE", path)
	end
	return value
end

local function normalizedLabel(value: any, maximum: number, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value < 1 or #value > maximum then
		reject("RANGE", path)
	end
	for index = 1, #value do
		local byte = string.byte(value, index)
		if byte < 32 or byte > 126 then
			reject("RANGE", path)
		end
	end
	local canonical = string.gsub(string.gsub(value, "^ +", ""), " +$", "")
	canonical = string.gsub(canonical, " +", " ")
	if #canonical == 0 then
		reject("RANGE", path)
	end
	if canonical ~= value then
		reject("NONCANONICAL", path)
	end
	return canonical
end

local function machineId(value: any, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value < 1 or #value > 64 or string.match(value, "^[a-z0-9][a-z0-9._-]*$") == nil then
		reject("RANGE", path)
	end
	return value
end

local function lowercaseHex(value: any, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if (#value ~= 40 and #value ~= 64) or string.match(value, "^[0-9a-f]+$") == nil then
		reject("RANGE", path)
	end
	return value
end

local function sha256(value: any, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value ~= 71
		or string.sub(value, 1, 7) ~= "sha256:"
		or string.match(string.sub(value, 8), "^[0-9a-f]+$") == nil
	then
		reject("RANGE", path)
	end
	return value
end

local function uuid(value: any, path: string): string
	if type(value) ~= "string" then
		reject("TYPE", path)
	end
	if #value ~= 36 or string.match(
		value,
		"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
	) == nil
	then
		reject("RANGE", path)
	end
	return value
end

local function copySelection(value: any, identity: AdapterIdentity.AdapterIdentity): AdapterIdentity.CaseSelection
	local resolved = AdapterIdentity.resolveSelection(value)
	if resolved.kind == "Invalid" then
		reject("RELATION", resolved.path)
	end
	if #AdapterIdentity.missingRequirements(identity, resolved.value.requirements) ~= 0 then
		reject("RELATION", "$.selection")
	end
	if resolved.value.kind == "Workload" then
		return {
			kind = "Workload",
			workloadId = resolved.value.workloadId,
			recipientCount = resolved.value.recipientCount,
		}
	end
	return {
		kind = "SeparateProbe",
		probeId = resolved.value.probeId,
	}
end

local function copyManifest(candidate: any): HostManifest
	local root = exactKeys(candidate, {
		version = true,
		launchId = true,
		benchmarkSource = true,
		contractFingerprint = true,
		adapter = true,
		selection = true,
		environment = true,
	}, "$")
	if rawget(root, "version") ~= 1 then
		if type(rawget(root, "version")) ~= "number" then
			reject("TYPE", "$.version")
		end
		reject("ENUM", "$.version")
	end

	local benchmarkSource = exactKeys(rawget(root, "benchmarkSource"), {
		revision = true,
		dirty = true,
	}, "$.benchmarkSource")
	local environment = exactKeys(rawget(root, "environment"), {
		studio = true,
		host = true,
	}, "$.environment")
	local studio = exactConditionalKeys(rawget(environment, "studio"), {
		version = true,
	}, {
		channel = true,
	}, "$.environment.studio")
	local studioVersion = token(rawget(studio, "version"), 64, "$.environment.studio.version")
	local copiedStudio: { version: string, channel: string? } = { version = studioVersion }
	if rawget(studio, "channel") ~= nil then
		copiedStudio.channel = token(rawget(studio, "channel"), 32, "$.environment.studio.channel")
	end

	local host = exactConditionalKeys(rawget(environment, "host"), {
		osFamily = true,
		architecture = true,
	}, {
		osVersion = true,
		cpuModel = true,
		logicalProcessorCount = true,
		memoryMiB = true,
		gpuModel = true,
	}, "$.environment.host")
	local copiedHost: any = {
		osFamily = expectEnum(rawget(host, "osFamily"), {
			Windows = true,
			macOS = true,
		}, "$.environment.host.osFamily"),
		architecture = expectEnum(rawget(host, "architecture"), {
			x86_64 = true,
			arm64 = true,
		}, "$.environment.host.architecture"),
	}
	if rawget(host, "osVersion") ~= nil then
		copiedHost.osVersion = token(rawget(host, "osVersion"), 64, "$.environment.host.osVersion")
	end
	if rawget(host, "cpuModel") ~= nil then
		copiedHost.cpuModel = normalizedLabel(rawget(host, "cpuModel"), 128, "$.environment.host.cpuModel")
	end
	if rawget(host, "logicalProcessorCount") ~= nil then
		copiedHost.logicalProcessorCount = boundedInteger(
			rawget(host, "logicalProcessorCount"),
			1,
			1_024,
			"$.environment.host.logicalProcessorCount"
		)
	end
	if rawget(host, "memoryMiB") ~= nil then
		copiedHost.memoryMiB = boundedInteger(
			rawget(host, "memoryMiB"),
			128,
			16_777_216,
			"$.environment.host.memoryMiB"
		)
	end
	if rawget(host, "gpuModel") ~= nil then
		copiedHost.gpuModel = normalizedLabel(rawget(host, "gpuModel"), 128, "$.environment.host.gpuModel")
	end

	local adapter = exactKeys(rawget(root, "adapter"), {
		moduleId = true,
		artifact = true,
		identity = true,
	}, "$.adapter")
	local checkedIdentity = AdapterIdentity.check(
		rawget(adapter, "identity"),
		"Canonical",
		studioVersion,
		"$.adapter.identity"
	)
	if checkedIdentity.kind == "Invalid" then
		reject(checkedIdentity.issue.code :: ManifestIssueCode, checkedIdentity.issue.path)
	end
	local identity = checkedIdentity.value
	local artifact = rawget(adapter, "artifact")
	if type(artifact) ~= "table" then
		reject("TYPE", "$.adapter.artifact")
	end
	local copiedArtifact: RepositoryModuleArtifact | EngineBuiltInArtifact
	if rawget(artifact, "kind") == "RepositoryModule" then
		exactKeys(artifact, { kind = true, digest = true }, "$.adapter.artifact")
		local digest = sha256(rawget(artifact, "digest"), "$.adapter.artifact.digest")
		if identity.library.provenance.kind ~= "Repository"
			or digest ~= identity.library.provenance.checksum
		then
			reject("RELATION", "$.adapter.artifact")
		end
		copiedArtifact = { kind = "RepositoryModule", digest = digest }
	elseif rawget(artifact, "kind") == "EngineBuiltIn" then
		exactKeys(artifact, { kind = true }, "$.adapter.artifact")
		if identity.integrationKind ~= "EngineBuiltIn"
			or identity.library.provenance.kind ~= "EngineBuiltIn"
			or identity.library.provenance.studioVersion ~= studioVersion
		then
			reject("RELATION", "$.adapter.artifact")
		end
		copiedArtifact = { kind = "EngineBuiltIn" }
	else
		reject("ENUM", "$.adapter.artifact.kind")
	end

	return {
		version = 1,
		launchId = uuid(rawget(root, "launchId"), "$.launchId"),
		benchmarkSource = {
			revision = lowercaseHex(rawget(benchmarkSource, "revision"), "$.benchmarkSource.revision"),
			dirty = expectBoolean(rawget(benchmarkSource, "dirty"), "$.benchmarkSource.dirty"),
		},
		contractFingerprint = sha256(rawget(root, "contractFingerprint"), "$.contractFingerprint"),
		adapter = {
			moduleId = machineId(rawget(adapter, "moduleId"), "$.adapter.moduleId"),
			artifact = copiedArtifact,
			identity = identity,
		},
		selection = copySelection(rawget(root, "selection"), identity),
		environment = {
			studio = copiedStudio,
			host = copiedHost,
		},
	}
end

local function validate(candidate: unknown): ValidationResult
	local ok, output = pcall(function(): HostManifest
		preflight(candidate)
		local manifest = copyManifest(candidate)
		deepFreeze(manifest)
		return manifest
	end)
	if not ok then
		if type(output) ~= "table" or rawget(output, "marker") ~= ISSUE_MARKER then
			error(output, 0)
		end
		local invalid: ValidationResult = {
			kind = "Invalid",
			issue = {
				code = rawget(output, "code"),
				path = rawget(output, "path"),
			},
		}
		deepFreeze(invalid)
		return invalid
	end
	local valid: ValidationResult = { kind = "Valid", value = output }
	deepFreeze(valid)
	return valid
end

local HostManifestV1 = {
	validate = validate,
}

table.freeze(HostManifestV1)

return HostManifestV1
