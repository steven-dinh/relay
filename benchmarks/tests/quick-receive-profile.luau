local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Instrumentation = require("../quick/ReceiveInstrumentation")
local Model = require("../quick/Model")

for _, id in { "tiny-steady-c2s", "state-steady-c2s", "state-burst-c2s", "state-broadcast-s2c", "state-broadcast-burst-s2c", "schema-composite-c2s" } do
	assert(Model.receiveProfileCases[id] == true, "approved receive profile workload")
end
for _, id in { "tiny-round-trip", "schema-signed-c2s", "schema-vector2-c2s", "schema-string-c2s", "schema-cframe-c2s", "future-workload-c2s" } do
	assert(Model.receiveProfileCases[id] == nil, "unsupported receive profile workload")
end

-- Reject invalid composite adapter selections before creating a source snapshot.
for _, adapters in { "relay-reliable", "native-reliable", "native-reliable,relay-reliable" } do
	local config = table.clone(require("../quick/Config"))
	config.caseId = "schema-composite-c2s"
	local snapshots, writes = 0, 0
	local inputs = {
		["@lune/fs"] = { isFile = function(path) return path == "benchmarks/quick/quick.project.json" end, isDir = function() return false end,
			writeDir = function() writes += 1 end },
		["@lune/process"] = { args = { "--profile-receive", "--adapters", adapters }, cwd = "." },
		["@lune/serde"] = serde,
		["../host/ExternalAdapterCatalog"] = {},
		["./ReceiveInstrumentation"] = { copyProfileSources = function()
			snapshots += 1; error("profile snapshot reached", 0)
		end },
		["./Config"] = config, ["./Model"] = Model,
	}
	local ok, reason = pcall(luau.load(fs.readFile("benchmarks/quick/build.luau"), { environment = {
		require = function(path) return assert(inputs[path], "unexpected build dependency") end,
	} }))
	assert(not ok)
	if adapters == "relay-reliable" then
		assert(snapshots == 1 and writes == 1 and string.find(tostring(reason), "profile snapshot reached", 1, true),
			"the bounded RR3 profile must reach the existing snapshot builder")
	else
		assert(snapshots == 0 and writes == 0 and string.find(tostring(reason), "exactly one relay-reliable", 1, true),
			"unsupported RR3 profile adapters must reject before snapshot creation")
	end
end

local pinnedSdkMock = "pinned LibMP SDK fixture"
local function libmpBuild(arguments, caseId, sdkSource, stopAtSnapshot)
	local config = table.clone(require("../quick/Config"))
	config.caseId = caseId
	local writes, snapshots, emittedFiles = 0, 0, {}
	local inputs = {
		["@lune/fs"] = {
			isFile = function(path) return path == "benchmarks/quick/quick.project.json" end,
			isDir = function() return false end,
			writeDir = function() writes += 1 end,
			writeFile = function(path, body)
				writes += 1
				emittedFiles[path] = body
			end,
			readFile = function(path)
				if path == "benchmarks/quick/quick.project.json" then return fs.readFile(path) end
				if path == "pinned-sdk-mock.luau" then return sdkSource end
				error("unexpected LibMP build input: " .. path, 0)
			end,
		},
		["@lune/process"] = { args = arguments, cwd = ".", exec = function()
			return { ok = true, code = 0, stdout = "", stderr = "" }
		end },
		["@lune/serde"] = serde,
		["../host/ExternalAdapterCatalog"] = {},
		["./ReceiveInstrumentation"] = {
			copyProfileSources = function()
				snapshots += 1
				if stopAtSnapshot ~= false then error("profile snapshot reached", 0) end
				return {}
			end,
			configureProfileProject = function(project) return project end,
			assertProfileMappings = function() end,
			artifact = function() return { sha256 = "mock", size = 0 } end,
			exactBindings = function() return {} end,
		},
		["./Config"] = config,
		["./Model"] = Model,
		["./CpuProfile"] = {
			FORMAT = 65_537,
			SDK_REVISION = "mock-revision",
			SDK_SHA256 = serde.hash("sha256", pinnedSdkMock),
		},
	}
	local ok, reason = pcall(luau.load(fs.readFile("benchmarks/quick/build.luau"), { environment = {
		require = function(path) return assert(inputs[path], "unexpected build dependency: " .. path) end,
	} }))
	return ok, reason, writes, snapshots, emittedFiles
end

local noProfileOk, noProfileReason, noProfileWrites, noProfileSnapshots = libmpBuild(
	{ "--libmp", "pinned-sdk-mock.luau" }, "state-burst-c2s", pinnedSdkMock)
assert(not noProfileOk and noProfileWrites == 0 and noProfileSnapshots == 0
	and string.find(tostring(noProfileReason), "--libmp requires --profile-receive", 1, true),
	"--libmp must require explicit receive profiling")

local s2cOk, s2cReason, s2cWrites, s2cSnapshots = libmpBuild(
	{ "--profile-receive", "--libmp", "pinned-sdk-mock.luau", "--adapters", "relay-reliable" },
	"state-broadcast-s2c", pinnedSdkMock)
assert(not s2cOk and s2cWrites == 0 and s2cSnapshots == 0
	and string.find(tostring(s2cReason), "client-to-server workloads only", 1, true),
	"LibMP profiling must reject S2C before creating a snapshot")

local hashOk, hashReason, hashWrites, hashSnapshots = libmpBuild(
	{ "--profile-receive", "--libmp", "pinned-sdk-mock.luau", "--adapters", "relay-reliable" },
	"state-burst-c2s", "wrong LibMP SDK fixture")
assert(not hashOk and hashWrites == 0 and hashSnapshots == 0
	and string.find(tostring(hashReason), "SDK does not match the pinned revision", 1, true),
	"a wrong LibMP SDK hash must reject before snapshot writes")

local acceptedOk, acceptedReason, acceptedWrites, acceptedSnapshots = libmpBuild(
	{ "--profile-receive", "--libmp", "pinned-sdk-mock.luau", "--adapters", "relay-reliable" },
	"state-burst-c2s", pinnedSdkMock)
assert(not acceptedOk and acceptedWrites == 1 and acceptedSnapshots == 1
	and string.find(tostring(acceptedReason), "profile snapshot reached", 1, true),
	"the pinned SDK must pass validation and reach the existing snapshot builder")

local emittedOk, emittedReason, emittedWrites, emittedSnapshots, emittedFiles = libmpBuild(
	{ "--profile-receive", "--libmp", "pinned-sdk-mock.luau", "--adapters", "relay-reliable" },
	"state-burst-c2s", pinnedSdkMock, false)
local emittedProject
for path, body in emittedFiles do
	if string.find(path, "quick.project.json", 1, true) then emittedProject = serde.decode("json", body) end
end
assert(emittedOk and emittedWrites >= 3 and emittedSnapshots == 1 and emittedProject ~= nil
	and emittedProject.tree.ReplicatedStorage.RelayBenchmark.Quick.ProfileCpu["$properties"].Value == true,
	"the emitted LibMP project must opt in to CPU capture: " .. tostring(emittedReason))

local function recorder(profileValue: boolean, clockStep: number)
	local now, reads, profileEvents = 0, 0, {}
	local profile = {
		Value = profileValue,
		IsA = function(_, name) return name == "BoolValue" end,
	}
	local parent = {
		FindFirstChild = function(_, name) return if name == "ProfileReceive" then profile else nil end,
	}
	local module = luau.load(fs.readFile("benchmarks/quick/CallbackTiming.luau"), { environment = {
		os = { clock = function() reads += 1; now += clockStep; return now end },
		debug = {
			profilebegin = function(marker) table.insert(profileEvents, "begin:" .. marker) end,
			profileend = function() table.insert(profileEvents, "end") end,
		},
		script = { Parent = parent },
	} })()
	return module, function() return reads end, profileEvents
end

local delayedProfileWaits, delayedProfileAvailable = 0, false
local delayedProfile = { Value = true, IsA = function(_, name) return name == "BoolValue" end }
local delayedProfileParent = {
	FindFirstChild = function() return if delayedProfileAvailable then delayedProfile else nil end,
	WaitForChild = function(_, name, timeout)
		assert(name == "ProfileReceive" and timeout == 15,
			"the callback recorder must use its bounded replicated flag wait")
		delayedProfileWaits += 1
		delayedProfileAvailable = true
		return delayedProfile
	end,
}
local delayedProfileTiming = luau.load(fs.readFile("benchmarks/quick/CallbackTiming.luau"), { environment = {
	script = { Parent = delayedProfileParent },
	os = { clock = function() return 0 end },
} })()
assert(delayedProfileWaits == 1 and delayedProfileTiming.enabled,
	"a delayed ProfileReceive BoolValue must enable callback timing after WaitForChild")

local timing, reads, markerEvents = recorder(true, 0.0005)
local callback = function(first, second, third)
	assert(first == "first" and second == nil and third == "third", "callback arguments must be unchanged")
	return first, second, nil
end
local wrapped = timing.wrap("native-reliable", callback)
timing.setCpuMarker("RelayQuickCPU/test/1")
timing.begin("native-reliable", 1)
local returned = table.pack(wrapped("first", nil, "third"))
assert(returned.n == 3 and returned[1] == "first" and returned[2] == nil and returned[3] == nil,
	"timed callbacks must preserve trailing nil returns")
local samples = timing.finish("native-reliable")
assert(#samples == 1 and samples[1] > 0 and reads() == 2, "timing must read around the real callback")
assert(table.concat(markerEvents, ",") == table.concat({
	"begin:RelayQuickCPU/test/1/rt", "end",
}, ","), "CPU callback timing must wrap the full receive callback")

local errorTiming = recorder(true, 0.001)
errorTiming.setCpuMarker("RelayQuickCPU/error/1")
local errorWrapped = errorTiming.wrap("relay-reliable", function() error("callback failure", 0) end)
errorTiming.begin("relay-reliable", 1)
local raised, reason = pcall(errorWrapped)
assert(not raised and string.find(tostring(reason), "callback failure", 1, true) ~= nil,
	"callback errors must propagate")
assert(not pcall(errorTiming.finish, "relay-reliable"), "callback errors must leave the phase in flight")

local scopeTiming, _, recordedScopeEvents = recorder(true, 0.001)
scopeTiming.setCpuMarker("RelayQuickCPU/stages/2")
assert(not pcall(scopeTiming.setCpuMarker, string.rep("x", 61)),
	"CPU marker roots beyond the MicroProfiler name limit must reject")
assert(not pcall(scopeTiming.scope, "receive.unknown", function() return true end),
	"unknown CPU stages must reject instead of generating ambiguous labels")
local scoped = table.pack(scopeTiming.scope("send.validate-encode", function(...)
	assert(select("#", ...) == 3, "scoped callback arguments must retain nil positions")
	return ...
end, "first", nil, "third"))
assert(scoped.n == 3 and scoped[1] == "first" and scoped[2] == nil and scoped[3] == "third",
	"CPU scopes must preserve return tuples including trailing values")
scopeTiming.scope("send.handoff", function() return true end)
assert(table.concat(recordedScopeEvents, ",") == table.concat({
	"begin:RelayQuickCPU/stages/2/sv", "end",
	"begin:RelayQuickCPU/stages/2/sh", "end",
}, ","), "stage markers must open and close in call order")
local beforeScopeError = #recordedScopeEvents
local scopeRaised, scopeReason = pcall(scopeTiming.scope, "receive.dispatch", function()
	error("dispatch failure", 0)
end)
assert(not scopeRaised and string.find(tostring(scopeReason), "dispatch failure", 1, true) ~= nil
	and recordedScopeEvents[beforeScopeError + 1] == "begin:RelayQuickCPU/stages/2/rd"
	and recordedScopeEvents[beforeScopeError + 2] == "end",
	"CPU scope errors must propagate after balancing the profiler marker")
local maxMarker = string.rep("x", 60)
scopeTiming.setCpuMarker(maxMarker)
scopeTiming.scope("send.handoff", function() return true end)
local maxEmittedMarker = string.sub(recordedScopeEvents[#recordedScopeEvents - 1], #"begin:" + 1)
assert(maxEmittedMarker == maxMarker .. "/sh" and #maxEmittedMarker == 63,
	"the maximum accepted root must keep the emitted label within 63 bytes")
scopeTiming.setCpuMarker(nil)
local withoutMarker = #recordedScopeEvents
scopeTiming.scope("receive.dispatch", function() return true end)
assert(#recordedScopeEvents == withoutMarker, "unset CPU marker must emit no stage scopes")

local lateTiming = recorder(true, 0.001)
local lateFailure
lateTiming.setFailureHandler(function(reason) lateFailure = reason end)
local lateWrapped = lateTiming.wrap("native-reliable", function() return true end)
lateTiming.begin("native-reliable", 1)
lateWrapped()
assert(#lateTiming.finish("native-reliable") == 1, "complete phase must finish")
assert(pcall(lateWrapped), "late callbacks must preserve callback behavior")
assert(type(lateFailure) == "string", "late callbacks must notify the terminal failure handler")
assert(not pcall(lateTiming.begin, "native-reliable", 1), "late callbacks must latch the recorder")

local limitTiming, limitReads = recorder(true, 0.001)
assert(not pcall(limitTiming.begin, "native-reliable", 2401), "per-phase cap must reject before allocation")
limitTiming.begin("native-reliable", 2400)
assert(not pcall(limitTiming.begin, "native-reliable", 1), "a second active phase must reject")
local callbackCount = 0
local capped = limitTiming.wrap("native-reliable", function() callbackCount += 1 end)
for _ = 1, 2401 do capped() end
assert(callbackCount == 2401 and limitReads() == 4800,
	"overflow must preserve callbacks without recording beyond the cap")
assert(not pcall(limitTiming.finish, "native-reliable"), "an extra callback must invalidate the phase")

local yieldingTiming = recorder(true, 0.001)
local yieldingWrapped = yieldingTiming.wrap("native-reliable", function()
	coroutine.yield("paused")
	return "resumed"
end)
yieldingTiming.begin("native-reliable", 1)
local thread = coroutine.create(yieldingWrapped)
local paused, marker = coroutine.resume(thread)
assert(paused and marker == "paused", "callback should yield while remaining in flight")
assert(not pcall(yieldingTiming.finish, "native-reliable"), "finish must reject in-flight callbacks")
assert(not pcall(yieldingTiming.begin, "relay-reliable", 1), "yielding callbacks cannot advance phases")
local resumed, value = coroutine.resume(thread)
assert(resumed and value == "resumed", "callback should resume with its original return")
assert(#yieldingTiming.finish("native-reliable") == 1, "completed yielded callback must finish")

local disabled, disabledReads = recorder(false, 1)
local disabledCallback = function(...) return ... end
assert(disabled.wrap("native-reliable", disabledCallback) == disabledCallback,
	"disabled wrapping must return the original callback")
disabled.begin("native-reliable", 2401)
local disabledReturned = table.pack(disabled.wrap("native-reliable", disabledCallback)("value", nil))
assert(disabledReturned.n == 2 and disabledReturned[1] == "value" and disabledReturned[2] == nil,
	"disabled wrapping must preserve callback returns")
assert(#disabled.finish("native-reliable") == 0 and disabledReads() == 0,
	"disabled wrapping must not read the clock or allocate samples")

local relaySource = fs.readFile("src/ClientSession.luau")
local relayServerSource = fs.readFile("src/ServerSession.luau")
local nativeSource = fs.readFile("benchmarks/adapters/native-reliable/init.luau")
local relayGenerated = Instrumentation.instrumentRelaySource(relaySource)
local relayServerGenerated = Instrumentation.instrumentRelayServerSource(relayServerSource)
local nativeGenerated = Instrumentation.instrumentNativeSource(nativeSource)
assert(select(2, string.gsub(relayGenerated, "CallbackTiming%.wrap", "")) == 1
	and string.find(relayGenerated, [[observe(remote.OnClientEvent, CallbackTiming.wrap("relay-reliable", function(endpointId, ...)
                receive("Reliable", endpointId, ...)
            end))]], 1, true) ~= nil,
	"Relay instrumentation must replace exactly one client binding")
assert(select(2, string.gsub(relayServerGenerated, "CallbackTiming%.wrap", "")) == 1
	and string.find(relayServerGenerated, [[remote.OnServerEvent:Connect(CallbackTiming.wrap("relay-reliable", function(player, endpointId, ...)
                receive("Reliable", player, endpointId, ...)
            end))]], 1, true) ~= nil,
	"Relay instrumentation must wrap the complete reliable server callback")
assert(select(2, string.gsub(nativeGenerated, "CallbackTiming%.wrap", "")) == 2
	and string.find(nativeGenerated, Instrumentation.exactBindings().native, 1, true) == nil,
	"native instrumentation must replace exactly one binding on each side")
assert(string.find(nativeGenerated, 'remote.OnServerEvent:Connect(CallbackTiming.wrap("native-reliable", deliverServer))', 1, true),
	"native server instrumentation must wrap the actual delivery callback")
assert(string.find(relayGenerated, 'CallbackTiming.scope("send.validate-encode"', 1, true) == nil
	and string.find(relayServerGenerated, 'CallbackTiming.scope("receive.validate-decode"', 1, true) == nil,
	"ordinary receive-profile copies must not add stage scopes")
assert(not pcall(Instrumentation.instrumentRelaySource, relaySource .. Instrumentation.exactBindings().relay),
	"changed Relay binding structure must fail closed")
assert(not pcall(Instrumentation.instrumentNativeSource, nativeSource .. Instrumentation.exactBindings().native),
	"changed native binding structure must fail closed")
assert(not pcall(Instrumentation.instrumentRelayServerSource, relayServerSource .. Instrumentation.exactBindings().relayServer),
	"ambiguous Relay server binding must fail closed")
assert(not pcall(Instrumentation.instrumentRelayServerSource, relaySource), "missing server binding must fail closed")
assert(not pcall(Instrumentation.instrumentNativeSource, nativeSource .. Instrumentation.exactBindings().nativeServer),
	"ambiguous native server binding must fail closed")
luau.compile(relayGenerated)
luau.compile(relayServerGenerated)
luau.compile(nativeGenerated)

local token = string.sub(serde.hash("sha256", `{os.clock()}:{tostring({})}`), 1, 16)
local destination = ".tmp/quick-receive-profile-test-" .. token
assert(not fs.isDir(destination) and not fs.isFile(destination), "profile fixture path collided")
local beforeRelay = serde.hash("sha256", relaySource)
local beforeRelayServer = serde.hash("sha256", relayServerSource)
local records = Instrumentation.copyProfileSources(process.cwd, destination)
assert(fs.isFile(destination .. "/source/Relay/ClientSession.luau")
	and fs.isFile(destination .. "/source/NativeReliable/init.luau")
	and fs.isFile(destination .. "/source/Quick/CpuProfile.luau"), "profile source copies missing")
assert(records["source/Relay/ClientSession.luau"].sourceSha256 == beforeRelay,
	"profile manifest records the original Relay source hash")
assert(records["source/Relay/ServerSession.luau"].sourceSha256 == beforeRelayServer
	and records["source/Relay/ServerSession.luau"].generatedSha256 == serde.hash("sha256", relayServerGenerated)
	and fs.readFile(destination .. "/source/Relay/ServerSession.luau") == relayServerGenerated,
	"profile snapshot must include the instrumented server and both source hashes")
assert(records["source/NativeReliable/init.luau"].sourceSha256 == serde.hash("sha256", nativeSource)
	and records["source/NativeReliable/init.luau"].generatedSha256 == serde.hash("sha256", nativeGenerated)
	and fs.readFile(destination .. "/source/NativeReliable/init.luau") == nativeGenerated,
	"profile snapshot must preserve both native callback wrappers and their source/generated hashes")
assert(records["source/Relay/ClientSession.luau"].generatedSha256
		== serde.hash("sha256", fs.readFile(destination .. "/source/Relay/ClientSession.luau")),
	"profile manifest records the generated Relay source hash")
assert(string.find(fs.readFile(destination .. "/source/Relay/ClientSession.luau"),
		"CallbackTiming.wrap(\"relay-reliable\", function(endpointId, ...)", 1, true) ~= nil,
	"copied Relay source must contain the instrumented binding")
assert(string.find(fs.readFile(destination .. "/source/NativeReliable/init.luau"),
		"CallbackTiming.wrap(\"native-reliable\", deliverClient)", 1, true) ~= nil,
	"copied native source must contain the instrumented binding")
assert(serde.hash("sha256", fs.readFile("src/ClientSession.luau")) == beforeRelay,
	"profile generation must not write production source")
assert(serde.hash("sha256", fs.readFile("src/ServerSession.luau")) == beforeRelayServer,
	"profile generation must not write production server source")
luau.compile(fs.readFile(destination .. "/source/Relay/ClientSession.luau"))
luau.compile(fs.readFile(destination .. "/source/Relay/ServerSession.luau"))
luau.compile(fs.readFile(destination .. "/source/NativeReliable/init.luau"))

local profileProject = serde.decode("json", fs.readFile("benchmarks/quick/quick.project.json"))
Instrumentation.configureProfileProject(profileProject, { "native-reliable", "relay-reliable" })
Instrumentation.assertProfileMappings(profileProject)
local mappedPaths = {}
local function collectPaths(node)
	if type(node) ~= "table" then return end
	for key, value in node do
		if key == "$path" then table.insert(mappedPaths, value) else collectPaths(value) end
	end
end
collectPaths(profileProject)
assert(table.find(mappedPaths, "source/Quick/CpuProfile.luau") ~= nil,
	"profile project must map the copied CPU reader module")
for _, path in mappedPaths do
	local absolute = destination .. "/" .. path
	assert(fs.isFile(absolute) or fs.isDir(absolute), "profile mapping has no snapshotted input: " .. path)
end
for _, path in {
	"source/contracts/event-v1.luau",
	"source/correctness/PayloadComparator.luau",
	"source/fixtures/event-v1.luau",
	"source/adapters/AdapterContract.luau",
	"source/adapters/ExternalAdapter.luau",
	"source/runner/ExternalReadiness.luau",
	"source/Quick/CoreAdapters.luau",
	"source/Quick/SchemaFixtures.luau",
	"source/Quick/SchemaRelay.luau",
	"source/Quick/CpuProfile.luau",
} do
	assert(records[path] ~= nil and fs.isFile(destination .. "/" .. path), "missing profile snapshot: " .. path)
end

local artifactPath = destination .. "/quick.project.json"
Instrumentation.configureProfileProject(profileProject, { "relay-reliable" })
assert(profileProject.tree.ReplicatedStorage.RelayBenchmark.QuickAdapters["$properties"].Value == "relay-reliable"
	and profileProject.tree.ReplicatedStorage.RelayBenchmark.Quick.ProfileReceive["$properties"].Value == true,
	"Relay-only composite profiles must retain the existing receive callback recorder")
local artifactBody = serde.encode("json", profileProject, true) .. "\n"
fs.writeFile(artifactPath, artifactBody, { overwrite = false })
local built = process.exec("rojo", { "build", artifactPath, "--output", destination .. "/quick.rbxlx" })
assert(built.ok, `self-contained profile project build failed: {built.stdout}\n{built.stderr}`)
local projectArtifact = Instrumentation.artifact(artifactPath)
local placeArtifact = Instrumentation.artifact(destination .. "/quick.rbxlx")
assert(projectArtifact.sha256 == serde.hash("sha256", artifactBody) and projectArtifact.size == #artifactBody
	and placeArtifact.size > 0 and #placeArtifact.sha256 == 64,
	"artifact provenance must include final project/place bytes and sizes")

local function makeInputRoot(root)
	fs.writeDir(root)
	fs.writeDir(root .. "/benchmarks")
	fs.writeDir(root .. "/benchmarks/adapters")
	fs.writeDir(root .. "/benchmarks/quick")
	fs.writeDir(root .. "/benchmarks/runner")
	Instrumentation.copyTree("src", root .. "/src", nil, {}, "src")
	Instrumentation.copyTree("benchmarks/adapters/native-reliable", root .. "/benchmarks/adapters/native-reliable", nil, {}, "benchmarks/adapters/native-reliable")
	Instrumentation.copyTree("benchmarks/adapters/relay-reliable", root .. "/benchmarks/adapters/relay-reliable", nil, {}, "benchmarks/adapters/relay-reliable")
	Instrumentation.copyTree("benchmarks/contracts", root .. "/benchmarks/contracts", nil, {}, "benchmarks/contracts")
	Instrumentation.copyTree("benchmarks/correctness", root .. "/benchmarks/correctness", nil, {}, "benchmarks/correctness")
	Instrumentation.copyTree("benchmarks/fixtures", root .. "/benchmarks/fixtures", nil, {}, "benchmarks/fixtures")
	for _, name in { "Client.client.luau", "Config.luau", "Model.luau", "CoreAdapters.luau", "SchemaFixtures.luau", "SchemaRelay.luau", "Server.server.luau", "Session.luau", "CallbackTiming.luau", "CpuProfile.luau" } do
		fs.writeFile(root .. "/benchmarks/quick/" .. name, fs.readFile("benchmarks/quick/" .. name), { overwrite = false })
	end
	fs.writeFile(root .. "/benchmarks/adapters/AdapterContract.luau", fs.readFile("benchmarks/adapters/AdapterContract.luau"), { overwrite = false })
	fs.writeFile(root .. "/benchmarks/adapters/ExternalAdapter.luau", fs.readFile("benchmarks/adapters/ExternalAdapter.luau"), { overwrite = false })
	fs.writeFile(root .. "/benchmarks/runner/ExternalReadiness.luau", fs.readFile("benchmarks/runner/ExternalReadiness.luau"), { overwrite = false })
end

local inputToken = string.sub(serde.hash("sha256", `{os.clock()}:{tostring({})}:inputs`), 1, 16)
local inputRoot = ".tmp/quick-receive-input-" .. inputToken
local snapshotA = ".tmp/quick-receive-snapshot-a-" .. inputToken
local snapshotB = ".tmp/quick-receive-snapshot-b-" .. inputToken
local cpuSnapshot = ".tmp/quick-receive-cpu-snapshot-" .. inputToken
makeInputRoot(inputRoot)
local recordsA = Instrumentation.copyProfileSources(inputRoot, snapshotA)
local cpuRecords = Instrumentation.copyProfileSources(inputRoot, cpuSnapshot, true)
local snapshotClient = fs.readFile(snapshotA .. "/source/Relay/ClientSession.luau")
local snapshotServer = fs.readFile(snapshotA .. "/source/Relay/ServerSession.luau")
local cpuClient = fs.readFile(cpuSnapshot .. "/source/Relay/ClientSession.luau")
local cpuServer = fs.readFile(cpuSnapshot .. "/source/Relay/ServerSession.luau")
assert(string.find(snapshotClient, 'CallbackTiming.scope("send.validate-encode"', 1, true) == nil
	and string.find(snapshotServer, 'CallbackTiming.scope("receive.validate-decode"', 1, true) == nil,
	"the default snapshot must remain free of stage markers")
assert(string.find(cpuClient, 'CallbackTiming.scope("send.validate-encode"', 1, true) ~= nil
	and string.find(cpuClient, 'CallbackTiming.scope("send.handoff"', 1, true) ~= nil
	and string.find(cpuServer, 'CallbackTiming.scope("receive.validate-decode"', 1, true) ~= nil
	and string.find(cpuServer, 'CallbackTiming.scope("receive.dispatch"', 1, true) ~= nil,
	"only a CPU stage snapshot must include send and receive stage markers")
assert(cpuRecords["source/Relay/ClientSession.luau"].sourceSha256 == serde.hash("sha256", fs.readFile("src/ClientSession.luau"))
	and cpuRecords["source/Relay/ServerSession.luau"].sourceSha256 == serde.hash("sha256", fs.readFile("src/ServerSession.luau")),
	"CPU stage instrumentation must record the unchanged production inputs")
luau.compile(cpuClient)
luau.compile(cpuServer)
local existingSnapshotHash = serde.hash("sha256", fs.readFile(snapshotA .. "/source/fixtures/event-v1.luau"))
local existingSchemaSnapshotHash = serde.hash("sha256", fs.readFile(snapshotA .. "/source/Quick/SchemaFixtures.luau"))
local fixture = inputRoot .. "/benchmarks/fixtures/event-v1.luau"
fs.writeFile(fixture, fs.readFile(fixture) .. "\n-- isolated fresh snapshot change\n", { overwrite = true })
local schemaFixture = inputRoot .. "/benchmarks/quick/SchemaFixtures.luau"
fs.writeFile(schemaFixture, fs.readFile(schemaFixture) .. "\n-- isolated fresh schema snapshot change\n", { overwrite = true })
local recordsB = Instrumentation.copyProfileSources(inputRoot, snapshotB)
assert(recordsA["source/fixtures/event-v1.luau"].sourceSha256
	~= recordsB["source/fixtures/event-v1.luau"].sourceSha256,
	"a changed fixture must affect a fresh profile manifest")
assert(recordsA["source/Quick/SchemaFixtures.luau"].sourceSha256
	~= recordsB["source/Quick/SchemaFixtures.luau"].sourceSha256,
	"a changed schema fixture must affect a fresh profile manifest")
assert(serde.hash("sha256", fs.readFile(snapshotA .. "/source/fixtures/event-v1.luau")) == existingSnapshotHash,
	"a fresh snapshot must not mutate an existing profile snapshot")
assert(serde.hash("sha256", fs.readFile(snapshotA .. "/source/Quick/SchemaFixtures.luau")) == existingSchemaSnapshotHash,
	"a fresh snapshot must not mutate an existing schema fixture snapshot")
for _, path in { destination, inputRoot, snapshotA, snapshotB, cpuSnapshot } do
	assert(pcall(fs.removeDir, path), "profile fixture cleanup failed: " .. path)
end

print("PASS receive callback recorder, bounded phases, vararg/error behavior, exact instrumentation, isolated copies, hashes, mapping coverage, artifact provenance, and snapshot independence")
