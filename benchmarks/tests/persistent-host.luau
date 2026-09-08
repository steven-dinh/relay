local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Host = require("../host/HostRuntime")
local Fingerprint = require("../host/MeasurementFingerprint")
local Catalog = require("../host/ExternalAdapterCatalog")
local ResultV2 = require("../contracts/result-v2")
local Fixtures = require("./support/HostRuntimeFixtures")

local function reject(callback)
	assert(not pcall(callback), "invalid persistent host input accepted")
end
local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in value do copy[key] = clone(child) end
	return copy
end
for _, id in { "native-reliable", "relay-reliable", "quicknet", "satset", "zap", "blink", "bytenet", "netray-compile", "warp" } do
	local options = Host.parseArgs({ "--studio", "C:/Studio.exe", "--mode", "PersistentBenchmark",
		"--case", "state-burst-c2s", "--recipients", "1", "--adapter", id }, "windows")
	assert(options.mode == "PersistentBenchmark" and options.adapterId == id)
end
reject(function() Host.parseArgs({ "--studio", "C:/Studio.exe", "--mode", "PersistentBenchmark",
	"--case", "state-burst-c2s", "--recipients", "1", "--adapter", "suphi-packet" }, "windows") end)
luau.compile(Host.bootstrapSource())
local legacyManifest, legacyResult = Fixtures.maximum()
assert(Host.matchesManifest(legacyResult, legacyManifest))
local manifest, result = clone(legacyManifest), clone(legacyResult)
manifest.version = 2
manifest.benchmarkSource.measurementFingerprint = "sha256:" .. string.rep("c", 64)
manifest.benchmarkSource.adapterFingerprint = "sha256:" .. string.rep("d", 64)
manifest.adapter.identity.semantics.repetitionIsolation = "PersistentSession"
result.schema = { id = "result-v2", version = 2 }
result.benchmark.version = 2
result.benchmark.source = clone(manifest.benchmarkSource)
result.contract.id = "event-session-v1"
result.adapter = clone(manifest.adapter.identity)
result.conformance.sessionProof = { version = 1, passed = true }
result = ResultV2.validate(result)
local files = {}
local io = {
	writeExclusive = function(path, body) assert(files[path] == nil); files[path] = body end,
	readFile = function(path) return files[path] end,
	move = function(from, to) assert(files[to] == nil); files[to] = files[from]; files[from] = nil end,
	removeFile = function(path) files[path] = nil end,
}
local collector = Host.prepareCollector(manifest, "results", function() return string.rep("e", 32) end, io, true)
reject(function() Host.prepareCollector(manifest, "results") end)
reject(function() Host.prepareCollector(legacyManifest, "results", nil, nil, true) end)
assert(Host.matchesManifest(result, manifest))
assert(not Host.matchesManifest(result, legacyManifest) and not Host.matchesManifest(legacyResult, manifest))
for _, field in { "measurementFingerprint", "adapterFingerprint", "revision" } do
	local changed = clone(result)
	changed.benchmark.source[field] = if field == "revision" then string.rep("f", 40) else "sha256:" .. string.rep("f", 64)
	assert(not Host.matchesManifest(changed, manifest), "V2 source binding weakened")
end
local body = serde.encode("json", result)
local published = Host.collectBody(body, manifest.launchId, collector)
assert(published.path == "results/" .. manifest.launchId .. ".result-v2.json")
assert(files[published.path] == body)

local function hex(source)
	return (string.gsub(source, ".", function(character) return string.format("%02x", string.byte(character)) end))
end
local capability = string.rep("1", 64)
local chunks = math.ceil(#body / 1024)
local lines = { `RELAY_TERMINAL_V1 {capability} BEGIN {manifest.launchId} {hex(manifest.environment.studio.version)} {#body} {chunks}` }
for index = 1, chunks do
	table.insert(lines, `RELAY_TERMINAL_V1 {capability} CHUNK {manifest.launchId} {index} {hex(string.sub(body, (index - 1) * 1024 + 1, index * 1024))}`)
end
table.insert(lines, `RELAY_TERMINAL_V1 {capability} END {manifest.launchId} {#body} {chunks}`)
local log = table.concat(lines, "\n")
assert(Host.collectTerminalLog(log, capability, manifest.launchId, "PersistentBenchmark", function() return collector end).kind == "Result")
reject(function() Host.collectTerminalLog(log, capability, manifest.launchId, "Benchmark", function() return collector end) end)

-- Fake file/place surfaces exercise dependency coverage without builds or Studio.
local contents = {}
for _, directory in { "runner", "contracts", "correctness", "fixtures" } do
	contents[directory .. "/shared.luau"] = "return '" .. directory .. "'"
end
for _, path in { "event-v1.project.json", "adapters/AdapterContract.luau", "adapters/ExternalAdapter.luau",
	"tests/support/StudioProofReports.luau" } do contents[path] = "return '" .. path .. "'" end
local function node(name, className, source, children)
	local value = { Name = name, ClassName = className, Source = source, children = children or {} }
	function value:GetChildren() return self.children end
	function value:FindFirstChild(wanted)
		for _, child in self.children do if child.Name == wanted then return child end end
		return nil
	end
	return value
end
local nativeBinding = node("NativeReliable", "ModuleScript", "return 'native'")
local runner = node("Runner", "Folder", nil, { node("Shared", "ModuleScript", contents["runner/shared.luau"]) })
local place = node("game", "DataModel", nil, { node("ReplicatedStorage", "Folder", nil, {
	node("RelayBenchmark", "Folder", nil, { runner, node("adapters", "Folder", nil, { nativeBinding }) }),
}) })
local fakeRoblox = { deserializePlace = function() return place end }
local fakeFs = {
	readFile = function(path) return assert(contents[string.sub(path, #"root/benchmarks/" + 1)]) end,
	readDir = function() return { "shared.luau" } end,
	isDir = function() return false end,
}
local common = Fingerprint.collect("root", "place", fakeFs, fakeRoblox, serde.hash)
local native = Host.collectNativeBinding("place", fakeRoblox, serde.hash)
nativeBinding.Source = "return 'changed native'"
assert(Fingerprint.collect("root", "place", fakeFs, fakeRoblox, serde.hash) == common)
assert(Host.collectNativeBinding("place", fakeRoblox, serde.hash) ~= native)
contents["README.md"] = "unrelated reporting documentation"
assert(Fingerprint.collect("root", "place", fakeFs, fakeRoblox, serde.hash) == common)
contents["runner/shared.luau"] = "return 'new measurement logic'"
runner.children[1].Source = contents["runner/shared.luau"]
assert(Fingerprint.collect("root", "place", fakeFs, fakeRoblox, serde.hash) ~= common)
table.insert(place.children, node("Unclassified", "ModuleScript", "return 42"))
reject(function() Fingerprint.collect("root", "place", fakeFs, fakeRoblox, serde.hash) end)
assert(Fingerprint.digest({ a = "bc", ab = "c" }, serde.hash) ~= Fingerprint.digest({ a = "b", ab = "cc" }, serde.hash))

local lock = serde.decode("json", fs.readFile("benchmarks/libraries.lock.json"))
local entry = Catalog.selected(lock, "quicknet")
assert(Catalog.adapter(entry, "sha256:" .. string.rep("a", 64), "test").identity.semantics.repetitionIsolation == "ProcessRestart")
assert(Catalog.adapter(entry, "sha256:" .. string.rep("a", 64), "test", "PersistentSession").identity.semantics.repetitionIsolation == "PersistentSession")

-- One actual build proves Rojo's source representation matches the file manifest.
-- This is not a Studio launch or a measured result.
local root = string.gsub(process.cwd, "\\", "/")
local token = string.sub(serde.hash("sha256", `{os.clock()}:{tostring({})}`), 1, 16)
local placePath = root .. "/.tmp/persistent-host-fingerprint-" .. token .. ".rbxlx"
fs.writeFile(placePath, "", { overwrite = false })
local builtOk, builtError = pcall(function()
	local bytes = Host.buildPlace(root, placePath, process.exec, fs.isFile, fs.readFile)
	local players = roblox.deserializePlace(bytes):FindFirstChild("Players")
	assert(players ~= nil and players.CharacterAutoLoads == false, "benchmark place must not spawn avatars")
	assert(string.sub(Fingerprint.collect(root, bytes, fs, roblox, serde.hash), 1, 7) == "sha256:")
	assert(string.sub(Host.collectNativeBinding(bytes, roblox, serde.hash), 1, 7) == "sha256:")
end)
fs.removeFile(placePath)
assert(builtOk, builtError)
print("PASS persistent-host: V2 mode/collector/source binding, V1 rollback, classified shared/adapter fingerprints")
