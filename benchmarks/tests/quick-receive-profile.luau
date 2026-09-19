local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Instrumentation = require("../quick/ReceiveInstrumentation")

local function recorder(profileValue: boolean, clockStep: number)
	local now, reads = 0, 0
	local profile = {
		Value = profileValue,
		IsA = function(_, name) return name == "BoolValue" end,
	}
	local parent = {
		FindFirstChild = function(_, name) return if name == "ProfileReceive" then profile else nil end,
	}
	local module = luau.load(fs.readFile("benchmarks/quick/CallbackTiming.luau"), { environment = {
		os = { clock = function() reads += 1; now += clockStep; return now end },
		script = { Parent = parent },
	} })()
	return module, function() return reads end
end

local timing, reads = recorder(true, 0.0005)
local callback = function(first, second, third)
	assert(first == "first" and second == nil and third == "third", "callback arguments must be unchanged")
	return first, second, nil
end
local wrapped = timing.wrap("native-reliable", callback)
timing.begin("native-reliable", 1)
local returned = table.pack(wrapped("first", nil, "third"))
assert(returned.n == 3 and returned[1] == "first" and returned[2] == nil and returned[3] == nil,
	"timed callbacks must preserve trailing nil returns")
local samples = timing.finish("native-reliable")
assert(#samples == 1 and samples[1] > 0 and reads() == 2, "timing must read around the real callback")

local errorTiming = recorder(true, 0.001)
local errorWrapped = errorTiming.wrap("relay-reliable", function() error("callback failure", 0) end)
errorTiming.begin("relay-reliable", 1)
local raised, reason = pcall(errorWrapped)
assert(not raised and string.find(tostring(reason), "callback failure", 1, true) ~= nil,
	"callback errors must propagate")
assert(not pcall(errorTiming.finish, "relay-reliable"), "callback errors must leave the phase in flight")

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
local nativeSource = fs.readFile("benchmarks/adapters/native-reliable/init.luau")
local relayGenerated = Instrumentation.instrumentRelaySource(relaySource)
local nativeGenerated = Instrumentation.instrumentNativeSource(nativeSource)
assert(select(2, string.gsub(relayGenerated, "CallbackTiming%.wrap", "")) == 1
	and string.find(relayGenerated, "observe(remote.OnClientEvent, CallbackTiming.wrap(\"relay-reliable\", receive))", 1, true) ~= nil,
	"Relay instrumentation must replace exactly one client binding")
assert(select(2, string.gsub(nativeGenerated, "CallbackTiming%.wrap", "")) == 1
	and string.find(nativeGenerated, Instrumentation.exactBindings().native, 1, true) == nil,
	"native instrumentation must replace exactly one client binding")
assert(not pcall(Instrumentation.instrumentRelaySource, relaySource .. Instrumentation.exactBindings().relay),
	"changed Relay binding structure must fail closed")
assert(not pcall(Instrumentation.instrumentNativeSource, nativeSource .. Instrumentation.exactBindings().native),
	"changed native binding structure must fail closed")
luau.compile(relayGenerated)
luau.compile(nativeGenerated)

local token = string.sub(serde.hash("sha256", `{os.clock()}:{tostring({})}`), 1, 16)
local destination = ".tmp/quick-receive-profile-test-" .. token
assert(not fs.isDir(destination) and not fs.isFile(destination), "profile fixture path collided")
local beforeRelay = serde.hash("sha256", relaySource)
local records = Instrumentation.copyProfileSources(process.cwd, destination)
assert(fs.isFile(destination .. "/source/Relay/ClientSession.luau")
	and fs.isFile(destination .. "/source/NativeReliable/init.luau"), "profile source copies missing")
assert(records["source/Relay/ClientSession.luau"].sourceSha256 == beforeRelay,
	"profile manifest records the original Relay source hash")
assert(records["source/Relay/ClientSession.luau"].generatedSha256
		== serde.hash("sha256", fs.readFile(destination .. "/source/Relay/ClientSession.luau")),
	"profile manifest records the generated Relay source hash")
assert(string.find(fs.readFile(destination .. "/source/Relay/ClientSession.luau"),
		"CallbackTiming.wrap(\"relay-reliable\", receive)", 1, true) ~= nil,
	"copied Relay source must contain the instrumented binding")
assert(string.find(fs.readFile(destination .. "/source/NativeReliable/init.luau"),
		"CallbackTiming.wrap(\"native-reliable\", deliverClient)", 1, true) ~= nil,
	"copied native source must contain the instrumented binding")
assert(serde.hash("sha256", fs.readFile("src/ClientSession.luau")) == beforeRelay,
	"profile generation must not write production source")
luau.compile(fs.readFile(destination .. "/source/Relay/ClientSession.luau"))
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
	"source/Quick/SchemaFixtures.luau",
	"source/Quick/SchemaRelay.luau",
} do
	assert(records[path] ~= nil and fs.isFile(destination .. "/" .. path), "missing profile snapshot: " .. path)
end

local artifactPath = destination .. "/quick.project.json"
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
	for _, name in { "Client.client.luau", "Config.luau", "Model.luau", "SchemaFixtures.luau", "SchemaRelay.luau", "Server.server.luau", "Session.luau", "CallbackTiming.luau" } do
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
makeInputRoot(inputRoot)
local recordsA = Instrumentation.copyProfileSources(inputRoot, snapshotA)
local existingSnapshotHash = serde.hash("sha256", fs.readFile(snapshotA .. "/source/fixtures/event-v1.luau"))
local fixture = inputRoot .. "/benchmarks/fixtures/event-v1.luau"
fs.writeFile(fixture, fs.readFile(fixture) .. "\n-- isolated fresh snapshot change\n", { overwrite = true })
local recordsB = Instrumentation.copyProfileSources(inputRoot, snapshotB)
assert(recordsA["source/fixtures/event-v1.luau"].sourceSha256
	~= recordsB["source/fixtures/event-v1.luau"].sourceSha256,
	"a changed fixture must affect a fresh profile manifest")
assert(serde.hash("sha256", fs.readFile(snapshotA .. "/source/fixtures/event-v1.luau")) == existingSnapshotHash,
	"a fresh snapshot must not mutate an existing profile snapshot")
for _, path in { destination, inputRoot, snapshotA, snapshotB } do
	assert(pcall(fs.removeDir, path), "profile fixture cleanup failed: " .. path)
end

print("PASS receive callback recorder, bounded phases, vararg/error behavior, exact instrumentation, isolated copies, hashes, mapping coverage, artifact provenance, and snapshot independence")
