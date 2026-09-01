local AdapterIdentity = require("../contracts/internal/AdapterIdentity")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")

local function deepClone(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end
	local copied = {}
	seen[value] = copied
	for key, nested in next, value do
		copied[deepClone(key, seen)] = deepClone(nested, seen)
	end
	return copied
end

local function assertExactKeys(value, keys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local expected = {}
	for _, key in keys do
		expected[key] = true
	end
	local count = 0
	for key in next, value do
		count += 1
		assert(expected[key] == true, `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #keys, `{label} key count differs`)
end

local function assertDeepEqual(actual, expected, path, seen)
	path = path or "$"
	if type(actual) ~= type(expected) then
		error(`{path}: type differs`, 0)
	end
	if type(actual) ~= "table" then
		assert(actual == expected, `{path}: value differs`)
		return
	end
	seen = seen or {}
	if seen[actual] ~= nil then
		assert(seen[actual] == expected, `{path}: alias differs`)
		return
	end
	seen[actual] = expected
	local count = 0
	for key, nested in next, actual do
		count += 1
		assert(rawget(expected, key) ~= nil, `{path}: unexpected key {tostring(key)}`)
		assertDeepEqual(nested, rawget(expected, key), `{path}.{tostring(key)}`, seen)
	end
	local expectedCount = 0
	for _ in next, expected do
		expectedCount += 1
	end
	assert(count == expectedCount, `{path}: key count differs`)
end

local function assertDeepFrozen(value, seen, path)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	path = path or "$"
	if seen[value] then
		return
	end
	seen[value] = true
	assert(table.isfrozen(value), `{path} must be frozen`)
	for key, nested in next, value do
		assertDeepFrozen(key, seen, `{path}.<key>`)
		assertDeepFrozen(nested, seen, `{path}.{tostring(key)}`)
	end
end

local function collectTables(value, found)
	if type(value) ~= "table" or found[value] then
		return
	end
	found[value] = true
	for key, nested in next, value do
		collectTables(key, found)
		collectTables(nested, found)
	end
end

local function assertDetached(input, output)
	local inputTables = {}
	local outputTables = {}
	collectTables(input, inputTables)
	collectTables(output, outputTables)
	for outputTable in outputTables do
		assert(not inputTables[outputTable], "validated manifest must not share input tables")
	end
end

local function repositoryIdentity()
	return {
		id = "repo-adapter",
		displayName = "Repository Adapter",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "repo-library",
			displayName = "Repository Library",
			version = "1.2.3",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/relay-adapter",
				revision = string.rep("d", 40),
				checksum = "sha256:" .. string.rep("e", 64),
				license = "MIT",
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
	}
end

local function engineIdentity(studioVersion)
	studioVersion = studioVersion or "0.650.0.6500000"
	return {
		id = "engine-adapter",
		displayName = "Engine Adapter",
		lane = "NativeBest",
		integrationKind = "EngineBuiltIn",
		library = {
			id = "engine-library",
			displayName = "Engine Library",
			version = studioVersion,
			provenance = {
				kind = "EngineBuiltIn",
				studioVersion = studioVersion,
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "ProcessRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function repositoryManifest()
	local identity = repositoryIdentity()
	return {
		version = 1,
		launchId = "00112233-4455-6677-8899-aabbccddeeff",
		benchmarkSource = {
			revision = string.rep("a", 40),
			dirty = false,
			placeFingerprint = "sha256:" .. string.rep("c", 64),
		},
		contractFingerprint = "sha256:" .. string.rep("b", 64),
		adapter = {
			moduleId = "repo-adapter-module",
			artifact = {
				kind = "RepositoryModule",
				digest = identity.library.provenance.checksum,
			},
			identity = identity,
		},
		selection = {
			kind = "Workload",
			workloadId = "state-broadcast-s2c",
			recipientCount = 4,
		},
		environment = {
			studio = {
				version = "0.650.0.6500000",
				channel = "production",
			},
			host = {
				osFamily = "Windows",
				architecture = "x86_64",
				osVersion = "11",
				cpuModel = "Test CPU",
				logicalProcessorCount = 8,
				memoryMiB = 16_384,
				gpuModel = "Test GPU",
			},
		},
	}
end

local function engineManifest()
	local studioVersion = "0.650.0.6500000"
	local manifest = repositoryManifest()
	manifest.adapter = {
		moduleId = "engine-adapter-module",
		artifact = { kind = "EngineBuiltIn" },
		identity = engineIdentity(studioVersion),
	}
	manifest.environment.studio.version = studioVersion
	manifest.selection = {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
	}
	return manifest
end

local function assertValid(candidate, label)
	local result = HostManifestV1.validate(candidate)
	assert(result.kind == "Valid", `{label} must be valid`)
	assertDeepFrozen(result)
	return result.value
end

local function assertInvalid(candidate, code, path, label)
	local result = HostManifestV1.validate(candidate)
	assert(result.kind == "Invalid", `{label} must be invalid`)
	assert(result.issue.code == code, `{label} expected {code}, got {result.issue.code}`)
	assert(result.issue.path == path, `{label} expected {path}, got {result.issue.path}`)
	assertExactKeys(result, { "kind", "issue" }, `{label} result`)
	assertExactKeys(result.issue, { "code", "path" }, `{label} issue`)
	assertDeepFrozen(result)
	return result
end

assertExactKeys(HostManifestV1, { "validate" }, "HostManifestV1")
assert(table.isfrozen(HostManifestV1), "HostManifestV1 module must be frozen")

-- Both approved artifact forms validate and project to exact canonical shapes.
for _, case in {
	{ label = "repository module", value = repositoryManifest(), artifactKeys = { "kind", "digest" } },
	{ label = "engine built-in", value = engineManifest(), artifactKeys = { "kind" } },
} do
	local output = assertValid(case.value, case.label)
	assertExactKeys(output, {
		"version",
		"launchId",
		"benchmarkSource",
		"contractFingerprint",
		"adapter",
		"selection",
		"environment",
	}, `{case.label} manifest`)
	assertExactKeys(output.benchmarkSource, { "revision", "dirty", "placeFingerprint" }, `{case.label} benchmarkSource`)
	assert(output.benchmarkSource.placeFingerprint == case.value.benchmarkSource.placeFingerprint,
		`{case.label} place fingerprint changed`)
	assertExactKeys(output.adapter, { "moduleId", "artifact", "identity" }, `{case.label} adapter`)
	assertExactKeys(output.adapter.artifact, case.artifactKeys, `{case.label} artifact`)
	assertExactKeys(output.environment, { "studio", "host" }, `{case.label} environment`)
	assertExactKeys(output.environment.studio, { "version", "channel" }, `{case.label} studio`)
	assertExactKeys(output.environment.host, {
		"osFamily",
		"architecture",
		"osVersion",
		"cpuModel",
		"logicalProcessorCount",
		"memoryMiB",
		"gpuModel",
	}, `{case.label} host`)
end

-- Every scalar boundary accepts its minimum and maximum canonical value.
do
	local minimum = repositoryManifest()
	minimum.adapter.moduleId = "a"
	minimum.benchmarkSource.revision = string.rep("a", 40)
	minimum.environment.studio.version = "v"
	minimum.environment.studio.channel = "c"
	minimum.environment.host.osVersion = "1"
	minimum.environment.host.cpuModel = "C"
	minimum.environment.host.logicalProcessorCount = 1
	minimum.environment.host.memoryMiB = 128
	minimum.environment.host.gpuModel = "G"
	assertValid(minimum, "minimum scalar bounds")

	local maximum = repositoryManifest()
	maximum.adapter.moduleId = string.rep("a", 64)
	maximum.benchmarkSource.revision = string.rep("a", 64)
	maximum.environment.studio.version = string.rep("v", 64)
	maximum.environment.studio.channel = string.rep("c", 32)
	maximum.environment.host.osVersion = string.rep("1", 64)
	maximum.environment.host.cpuModel = string.rep("C", 128)
	maximum.environment.host.logicalProcessorCount = 1_024
	maximum.environment.host.memoryMiB = 16_777_216
	maximum.environment.host.gpuModel = string.rep("G", 128)
	assertValid(maximum, "maximum scalar bounds")
end

-- Maximum-plus-one, below-minimum, malformed canonical forms, and wrong scalar types reject.
for _, case in {
	{
		label = "module id empty",
		path = "$.adapter.moduleId",
		mutate = function(value)
			value.adapter.moduleId = ""
		end,
	},
	{
		label = "module id max plus one",
		path = "$.adapter.moduleId",
		mutate = function(value)
			value.adapter.moduleId = string.rep("a", 65)
		end,
	},
	{
		label = "studio version empty",
		path = "$.environment.studio.version",
		mutate = function(value)
			value.environment.studio.version = ""
		end,
	},
	{
		label = "studio version max plus one",
		path = "$.environment.studio.version",
		mutate = function(value)
			value.environment.studio.version = string.rep("v", 65)
		end,
	},
	{
		label = "channel empty",
		path = "$.environment.studio.channel",
		mutate = function(value)
			value.environment.studio.channel = ""
		end,
	},
	{
		label = "channel max plus one",
		path = "$.environment.studio.channel",
		mutate = function(value)
			value.environment.studio.channel = string.rep("c", 33)
		end,
	},
	{
		label = "os version empty",
		path = "$.environment.host.osVersion",
		mutate = function(value)
			value.environment.host.osVersion = ""
		end,
	},
	{
		label = "os version max plus one",
		path = "$.environment.host.osVersion",
		mutate = function(value)
			value.environment.host.osVersion = string.rep("1", 65)
		end,
	},
	{
		label = "cpu model empty",
		path = "$.environment.host.cpuModel",
		mutate = function(value)
			value.environment.host.cpuModel = ""
		end,
	},
	{
		label = "cpu model max plus one",
		path = "$.environment.host.cpuModel",
		mutate = function(value)
			value.environment.host.cpuModel = string.rep("C", 129)
		end,
	},
	{
		label = "gpu model empty",
		path = "$.environment.host.gpuModel",
		mutate = function(value)
			value.environment.host.gpuModel = ""
		end,
	},
	{
		label = "gpu model max plus one",
		path = "$.environment.host.gpuModel",
		mutate = function(value)
			value.environment.host.gpuModel = string.rep("G", 129)
		end,
	},
	{
		label = "logical processor below minimum",
		path = "$.environment.host.logicalProcessorCount",
		mutate = function(value)
			value.environment.host.logicalProcessorCount = 0
		end,
	},
	{
		label = "logical processor max plus one",
		path = "$.environment.host.logicalProcessorCount",
		mutate = function(value)
			value.environment.host.logicalProcessorCount = 1_025
		end,
	},
	{
		label = "memory below minimum",
		path = "$.environment.host.memoryMiB",
		mutate = function(value)
			value.environment.host.memoryMiB = 127
		end,
	},
	{
		label = "memory max plus one",
		path = "$.environment.host.memoryMiB",
		mutate = function(value)
			value.environment.host.memoryMiB = 16_777_217
		end,
	},
	{
		label = "revision below minimum",
		path = "$.benchmarkSource.revision",
		mutate = function(value)
			value.benchmarkSource.revision = string.rep("a", 39)
		end,
	},
	{
		label = "revision max plus one",
		path = "$.benchmarkSource.revision",
		mutate = function(value)
			value.benchmarkSource.revision = string.rep("a", 65)
		end,
	},
	{
		label = "uppercase revision",
		path = "$.benchmarkSource.revision",
		mutate = function(value)
			value.benchmarkSource.revision = string.rep("A", 40)
		end,
	},
	{
		label = "invalid contract fingerprint",
		path = "$.contractFingerprint",
		mutate = function(value)
			value.contractFingerprint = "sha256:" .. string.rep("B", 64)
		end,
	},
	{
		label = "invalid place fingerprint",
		path = "$.benchmarkSource.placeFingerprint",
		mutate = function(value)
			value.benchmarkSource.placeFingerprint = "sha256:" .. string.rep("C", 64)
		end,
	},
	{
		label = "place fingerprint without algorithm prefix",
		path = "$.benchmarkSource.placeFingerprint",
		mutate = function(value)
			value.benchmarkSource.placeFingerprint = string.rep("c", 64)
		end,
	},
	{
		label = "uppercase uuid",
		path = "$.launchId",
		mutate = function(value)
			value.launchId = "00112233-4455-6677-8899-AABBCCDDEEFF"
		end,
	},
	{
		label = "noncanonical cpu label",
		path = "$.environment.host.cpuModel",
		code = "NONCANONICAL",
		mutate = function(value)
			value.environment.host.cpuModel = "Test  CPU"
		end,
	},
	{
		label = "noncanonical gpu label",
		path = "$.environment.host.gpuModel",
		code = "NONCANONICAL",
		mutate = function(value)
			value.environment.host.gpuModel = " Test GPU"
		end,
	},
} do
	local candidate = repositoryManifest()
	case.mutate(candidate)
	assertInvalid(candidate, case.code or "RANGE", case.path, case.label)
end

do
	local candidate = repositoryManifest()
	candidate.environment.host.logicalProcessorCount = 1.5
	assertInvalid(candidate, "RANGE", "$.environment.host.logicalProcessorCount", "fractional processor count")
	candidate = repositoryManifest()
	candidate.environment.host.memoryMiB = math.huge
	assertInvalid(candidate, "RANGE", "$.environment.host.memoryMiB", "infinite memory")
	candidate = repositoryManifest()
	candidate.benchmarkSource.dirty = 0
	assertInvalid(candidate, "TYPE", "$.benchmarkSource.dirty", "non-boolean dirty")
	candidate = repositoryManifest()
	candidate.benchmarkSource.placeFingerprint = 1
	assertInvalid(candidate, "TYPE", "$.benchmarkSource.placeFingerprint", "non-string place fingerprint")
	candidate = repositoryManifest()
	candidate.version = "1"
	assertInvalid(candidate, "TYPE", "$.version", "non-number version")
	candidate = repositoryManifest()
	candidate.version = 2
	assertInvalid(candidate, "ENUM", "$.version", "wrong manifest version")
end

-- Optional fields may be absent, but required and extra keys are rejected at every envelope boundary.
do
	local sparse = repositoryManifest()
	sparse.environment.studio.channel = nil
	sparse.environment.host.osVersion = nil
	sparse.environment.host.cpuModel = nil
	sparse.environment.host.logicalProcessorCount = nil
	sparse.environment.host.memoryMiB = nil
	sparse.environment.host.gpuModel = nil
	local output = assertValid(sparse, "absent optional environment fields")
	assertExactKeys(output.environment.studio, { "version" }, "sparse studio")
	assertExactKeys(output.environment.host, { "osFamily", "architecture" }, "sparse host")
end

for _, case in {
	{
		label = "extra root key",
		path = "$",
		mutate = function(value)
			value.extra = true
		end,
	},
	{
		label = "missing root key",
		path = "$",
		mutate = function(value)
			value.contractFingerprint = nil
		end,
	},
	{
		label = "extra benchmark source key",
		path = "$.benchmarkSource",
		mutate = function(value)
			value.benchmarkSource.branch = "main"
		end,
	},
	{
		label = "missing place fingerprint",
		path = "$.benchmarkSource",
		mutate = function(value)
			value.benchmarkSource.placeFingerprint = nil
		end,
	},
	{
		label = "missing studio version",
		path = "$.environment.studio",
		mutate = function(value)
			value.environment.studio.version = nil
		end,
	},
	{
		label = "extra host key",
		path = "$.environment.host",
		mutate = function(value)
			value.environment.host.path = "secret"
		end,
	},
	{
		label = "extra adapter key",
		path = "$.adapter",
		mutate = function(value)
			value.adapter.loader = {}
		end,
	},
	{
		label = "extra artifact key",
		path = "$.adapter.artifact",
		mutate = function(value)
			value.adapter.artifact.path = "secret"
		end,
	},
} do
	local candidate = repositoryManifest()
	case.mutate(candidate)
	assertInvalid(candidate, "KEYSET", case.path, case.label)
end

-- Artifact identity, digest, Studio version, and selected case capability relations are enforced.
do
	local candidate = repositoryManifest()
	candidate.adapter.artifact.digest = "sha256:" .. string.rep("f", 64)
	assertInvalid(candidate, "RELATION", "$.adapter.artifact", "artifact checksum mismatch")

	candidate = repositoryManifest()
	candidate.adapter.artifact = { kind = "EngineBuiltIn" }
	assertInvalid(candidate, "RELATION", "$.adapter.artifact", "repository identity as engine artifact")

	candidate = engineManifest()
	candidate.adapter.artifact = {
		kind = "RepositoryModule",
		digest = "sha256:" .. string.rep("e", 64),
	}
	assertInvalid(candidate, "RELATION", "$.adapter.artifact", "engine identity as repository artifact")

	candidate = engineManifest()
	candidate.environment.studio.version = "0.651.0.6510000"
	assertInvalid(candidate, "RELATION", "$.adapter.identity.library.provenance", "engine Studio version mismatch")

	candidate = repositoryManifest()
	candidate.adapter.identity.capabilities.payloadIds = { "tiny" }
	assertInvalid(candidate, "RELATION", "$.selection", "selection missing payload capability")

	candidate = repositoryManifest()
	candidate.adapter.identity.semantics.broadcastMode = "Unsupported"
	assertInvalid(candidate, "RELATION", "$.selection", "selection missing broadcast capability")

	candidate = repositoryManifest()
	candidate.selection.recipientCount = 2
	assertInvalid(candidate, "RELATION", "$.selection.recipientCount", "invalid selected recipient count")

	candidate = repositoryManifest()
	candidate.selection.extra = true
	assertInvalid(candidate, "RELATION", "$.selection", "selection extra key")
end

-- Manifests require canonical AdapterIdentity output rather than silently normalizing identity fields.
do
	local candidate = repositoryManifest()
	candidate.adapter.identity.displayName = " Repository  Adapter "
	assertInvalid(
		candidate,
		"NONCANONICAL",
		"$.adapter.identity.displayName",
		"noncanonical adapter identity"
	)

	local normalized = AdapterIdentity.check(
		candidate.adapter.identity,
		"Normalize",
		candidate.environment.studio.version,
		"$.adapter.identity"
	)
	assert(normalized.kind == "Valid", "shared AdapterIdentity normalization must succeed")
	candidate.adapter.identity = deepClone(normalized.value)
	candidate.adapter.artifact.digest = candidate.adapter.identity.library.provenance.checksum
	local output = assertValid(candidate, "AdapterIdentity-normalized manifest")
	assert(output.adapter.identity.displayName == "Repository Adapter", "canonical identity label differs")

	candidate = repositoryManifest()
	candidate.adapter.identity.capabilities.directions = { "ServerToClient", "ClientToServer" }
	assertInvalid(
		candidate,
		"ORDER",
		"$.adapter.identity.capabilities.directions",
		"out-of-order adapter capability"
	)
end

-- Preflight uses raw bounded traversal and rejects metatables, cycles, and aliases before projection.
do
	local candidate = repositoryManifest()
	setmetatable(candidate.environment.host, { __index = function()
		error("must not run")
	end })
	assertInvalid(candidate, "METATABLE", "$", "metatable")

	candidate = repositoryManifest()
	candidate.environment.host.loop = candidate.environment.host
	assertInvalid(candidate, "CYCLE", "$", "cycle")

	candidate = repositoryManifest()
	local shared = {}
	candidate.environment.studio = shared
	candidate.environment.host = shared
	assertInvalid(candidate, "ALIAS", "$", "alias")

	candidate = repositoryManifest()
	local current = candidate.environment.host
	for _ = 1, 9 do
		local nested = {}
		current.nested = nested
		current = nested
	end
	assertInvalid(candidate, "LIMIT", "$", "depth limit")

	candidate = repositoryManifest()
	candidate.overflow = {}
	for index = 1, 1_025 do
		candidate.overflow[index] = index
	end
	assertInvalid(candidate, "LIMIT", "$", "entry limit")

	candidate = repositoryManifest()
	candidate.overflow = {}
	for index = 1, 129 do
		candidate.overflow[index] = {}
	end
	assertInvalid(candidate, "LIMIT", "$", "table-node limit")
end

-- Validation copies without mutating or retaining any caller-owned table, then deeply freezes the result.
do
	local candidate = repositoryManifest()
	local before = deepClone(candidate)
	local output = assertValid(candidate, "copy and freeze")
	assertDeepEqual(candidate, before)
	assertDetached(candidate, output)
	candidate.adapter.identity.displayName = "Changed"
	candidate.environment.host.cpuModel = "Changed CPU"
	candidate.selection.recipientCount = 8
	assert(output.adapter.identity.displayName == "Repository Adapter", "identity retained input mutation")
	assert(output.environment.host.cpuModel == "Test CPU", "environment retained input mutation")
	assert(output.selection.recipientCount == 4, "selection retained input mutation")
	assert(not pcall(function()
		output.environment.host.cpuModel = "Changed"
	end), "canonical manifest must reject mutation")
end

print("PASS Relay.Benchmarks.HostManifestV1")
