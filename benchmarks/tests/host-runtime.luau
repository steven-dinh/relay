local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Host = require("../host/run-event-v1")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local ResultV1 = require("../contracts/result-v1")
local HostRuntimeFixtures = require("./support/HostRuntimeFixtures")

local function expectError(code, callback)
	local ok, message = pcall(callback)
	assert(not ok and message == code, `expected {code}, got {tostring(message)}`)
end

local windowsArgs = {
	"--studio", "C:\\Roblox\\RobloxStudioBeta.exe",
	"--mode", "ControlProof",
	"--case", "state-broadcast-s2c",
	"--recipients", "4",
}
local options = Host.parseArgs(windowsArgs, "windows")
assert(options.studio == windowsArgs[2] and options.mode == "ControlProof", "valid host arguments changed")
assert(options.caseId == "state-broadcast-s2c" and options.recipientCount == 4, "case selection changed")
assert(table.isfrozen(options), "parsed arguments must be frozen")
for _, recipientCount in { 1, 8 } do
	local topologyArgs = table.clone(windowsArgs)
	topologyArgs[8] = tostring(recipientCount)
	assert(Host.parseArgs(topologyArgs, "windows").recipientCount == recipientCount, `topology {recipientCount} rejected`)
end

local macArgs = table.clone(windowsArgs)
macArgs[2] = "/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio"
assert(Host.parseArgs(macArgs, "macos").recipientCount == 4, "macOS absolute Studio path rejected")

for _, mutation in {
	function(args) table.remove(args) end,
	function(args) args[1] = "--unknown" end,
	function(args) args[2] = "relative.exe" end,
	function(args) args[4] = "Benchmark" end,
	function(args) args[6] = "missing" end,
	function(args) args[6] = "state-burst-c2s"; args[8] = "1" end,
	function(args) args[8] = "01" end,
	function(args) args[8] = "8"; args[6] = "tiny-steady-c2s" end,
} do
	local candidate = table.clone(windowsArgs)
	mutation(candidate)
	expectError("HOST_E_ARGS", function() Host.parseArgs(candidate, "windows") end)
end

local calls = {}
local function fakeExecute(program, arguments)
	table.insert(calls, { program = program, arguments = arguments })
	return { ok = true, stdout = "00 11\n22\t33" }
end
assert(Host.randomHex(4, "windows", fakeExecute) == "00112233", "Windows CSPRNG output normalization changed")
assert(calls[1].program == "powershell.exe", "Windows CSPRNG executable changed")
assert(calls[1].arguments[1] == "-NoProfile" and calls[1].arguments[2] == "-NonInteractive", "Windows CSPRNG hardening flags changed")
calls = {}
assert(Host.randomHex(4, "macos", fakeExecute) == "00112233", "macOS CSPRNG output normalization changed")
assert(calls[1].program == "/usr/bin/od" and calls[1].arguments[2] == "-N4", "macOS CSPRNG command changed")
expectError("HOST_E_OS", function() Host.randomHex(4, "linux", fakeExecute) end)
expectError("HOST_E_RANDOM", function()
	Host.randomHex(4, "windows", function() return { ok = true, stdout = "0011" } end)
end)

local sourceCommands = {}
local normalizedContract = nil
local sourceFacts = Host.collectSourceFacts(
	"E:/relay",
	"windows",
	"x86_64",
	function(program, arguments, options)
		table.insert(sourceCommands, { program = program, arguments = arguments, options = options })
		if arguments[1] == "rev-parse" then return { ok = true, stdout = string.rep("a", 40) .. "\n" } end
		return { ok = true, stdout = "?? local-file\n" }
	end,
	function(path)
		assert(path == "E:/relay/benchmarks/contracts/event-v1.luau", "contract fingerprint path changed")
		return "first\r\nsecond\rthird\n"
	end,
	function(algorithm, value)
		assert(algorithm == "sha256", "contract fingerprint algorithm changed")
		normalizedContract = value
		return string.rep("b", 64)
	end
)
assert(sourceFacts.benchmarkSource.revision == string.rep("a", 40) and sourceFacts.benchmarkSource.dirty, "git source facts changed")
assert(sourceFacts.contractFingerprint == "sha256:" .. string.rep("b", 64), "contract fingerprint shape changed")
assert(sourceFacts.host.osFamily == "Windows" and sourceFacts.host.architecture == "x86_64", "host source facts changed")
assert(normalizedContract == "first\nsecond\nthird\n", "contract fingerprint input was not LF-normalized")
assert(#sourceCommands == 2 and sourceCommands[1].program == "git" and sourceCommands[1].arguments[1] == "rev-parse"
	and sourceCommands[1].arguments[2] == "HEAD", "revision command changed")
local dirtyArguments = sourceCommands[2].arguments
assert(dirtyArguments[1] == "status" and dirtyArguments[2] == "--porcelain=v1"
	and dirtyArguments[3] == "--untracked-files=normal" and dirtyArguments[4] == "--ignore-submodules=none",
	"dirty command changed")
assert(sourceCommands[1].options.cwd == "E:/relay" and sourceCommands[2].options.cwd == "E:/relay", "git command cwd changed")
local macFacts = Host.collectSourceFacts("/relay", "macos", "aarch64", function(_, arguments)
	return { ok = true, stdout = if arguments[1] == "rev-parse" then string.rep("c", 64) .. "\n" else "" }
end, function() return "x" end, function() return string.rep("d", 64) end)
assert(not macFacts.benchmarkSource.dirty and macFacts.host.osFamily == "macOS" and macFacts.host.architecture == "arm64",
	"macOS source facts changed")

local uuid = Host.uuidV4(function(count)
	assert(count == 16, "UUID must request exactly 16 random bytes")
	return string.rep("00", count)
end)
assert(uuid == "00000000-0000-4000-8000-000000000000", "canonical UUID v4 bits changed")
assert(Host.randomPort(function() return "0000" end) == 49_152, "minimum random port changed")
assert(Host.randomPort(function() return "ffff" end) == 65_535, "maximum random port changed")

local capability = string.rep("ab", 32)
assert(Host.constantWorkCapability(capability, capability), "exact capability rejected")
assert(not Host.constantWorkCapability(string.upper(capability), capability), "uppercase capability accepted")
assert(not Host.constantWorkCapability(string.sub(capability, 2), capability), "short capability accepted")
assert(not Host.constantWorkCapability({}, capability), "non-string capability accepted")

local launchId = "00000000-0000-4000-8000-000000000000"
local body = Host.envelope(launchId)
assert(body == '{"kind":"RelayStudioControlProofV1","launchId":"' .. launchId .. '"}', "control envelope bytes changed")
assert(Host.jsonPreflight(body), "control envelope JSON preflight rejected")
assert(Host.decodeRoot(body, launchId).kind == "ControlProof", "control root classification changed")

local depthSix = string.rep("[", 6) .. "0" .. string.rep("]", 6)
assert(Host.jsonPreflight(depthSix), "depth-six JSON rejected")
expectError("HOST_E_JSON", function() Host.jsonPreflight("[" .. depthSix .. "]") end)
local maximumTokenArray = "[" .. string.rep("0,", 131_070) .. "0]"
assert(Host.jsonPreflight(maximumTokenArray), "maximum structural-token JSON rejected")
expectError("HOST_E_JSON", function() Host.jsonPreflight("[" .. string.rep("0,", 131_071) .. "0]") end)
for _, invalidJson in {
	'{"a":1,"a":2}',
	'{"a":1,"\\u0061":2}',
	'{"value":null}',
	"-0",
	"-0.0",
	"-0e1",
	"01",
	"1.",
	"1e",
	"1e9999",
	"NaN",
	"Infinity",
} do
	expectError("HOST_E_JSON", function() Host.jsonPreflight(invalidJson) end)
end
for _, validJson in { '"null"', "0", "1", "-1", "1.0", "1.25", "1e+2", "1E-2", '{"a":true,"b":false}' } do
	assert(Host.jsonPreflight(validJson), `valid JSON preflight rejected: {validJson}`)
end
local harnessBody = serde.encode("json", HarnessTerminationV1.new("RunIdCollision", "Preflight"))
local decodedHarness = Host.decodeRoot(harnessBody, launchId)
assert(decodedHarness.kind == "HarnessTermination" and decodedHarness.value.code == "RunIdCollision", "Harness termination root rejected")
expectError("HOST_E_SCHEMA", function() Host.decodeRoot('{"kind":"unknown"}', launchId) end)
expectError("HOST_E_SCHEMA", function()
	Host.decodeRoot('{"kind":"RelayStudioControlProofV1","launchId":"' .. launchId .. '","extra":true}', launchId)
end)

local function request(overrides)
	local candidate = {
		method = "POST",
		path = "/relay-event-v1/v1",
		query = {},
		headers = {
			["content-type"] = "application/json",
			["x-relay-capability"] = capability,
		},
		body = body,
	}
	for key, value in overrides or {} do candidate[key] = value end
	return candidate
end

local invalidShapeHandler, invalidShapeAccepted = Host.newHandler(capability, launchId)
assert(invalidShapeHandler(nil).status == 404, "nil request accepted")
assert(invalidShapeHandler("request").status == 404, "scalar request accepted")
local inheritedRequest = setmetatable({}, { __index = request() })
assert(invalidShapeHandler(inheritedRequest).status == 404, "inherited request fields accepted")
assert(not invalidShapeAccepted(), "invalid request shape consumed one-shot acceptance")

local rejectionCases = {
	{ method = "GET" },
	{ path = "/relay-event-v1/v1/" },
	{ query = { x = "1" } },
	{ headers = { ["content-type"] = "text/plain", ["x-relay-capability"] = capability } },
	{ headers = { ["content-type"] = "application/json", ["content-encoding"] = "gzip", ["x-relay-capability"] = capability } },
	{ headers = { ["content-type"] = "application/json", ["x-relay-capability"] = string.rep("cd", 32) } },
	{ body = body .. " " },
	{ body = string.rep("x", ResultV1.MAX_JSON_BYTES + 1) },
}
for _, overrides in rejectionCases do
	local handler, accepted = Host.newHandler(capability, launchId)
	assert(handler(request(overrides)).status == 404 and not accepted(), "invalid request reached one-shot acceptance")
end

local tooManyHeaders = {}
for index = 1, 33 do tooManyHeaders[`x-{index}`] = "v" end
local oversizedNameHeaders = { [string.rep("n", 65)] = "v" }
local oversizedValueHeaders = { x = string.rep("v", 1_025) }
local aggregateHeaders = {}
for index = 1, 9 do aggregateHeaders[`x-{index}`] = string.rep("v", 1_024) end
for _, headers in { tooManyHeaders, oversizedNameHeaders, oversizedValueHeaders, aggregateHeaders } do
	local handler, accepted = Host.newHandler(capability, launchId)
	assert(handler(request({ headers = headers })).status == 404 and not accepted(), "header bound accepted")
end

local atLimitHeaders = {
	["content-type"] = "application/json",
	["x-relay-capability"] = capability,
}
for index = 1, 30 do atLimitHeaders[`x-count-{index}`] = "v" end
local countHandler = Host.newHandler(capability, launchId)
assert(countHandler(request({ headers = atLimitHeaders })).status == 204, "32-header limit rejected")
local nameHandler = Host.newHandler(capability, launchId)
local nameHeaders = table.clone(request().headers)
nameHeaders[string.rep("n", 64)] = "v"
assert(nameHandler(request({ headers = nameHeaders })).status == 204, "64-byte header name rejected")
local valueHandler = Host.newHandler(capability, launchId)
local valueHeaders = table.clone(request().headers)
valueHeaders["x-limit"] = string.rep("v", 1_024)
assert(valueHandler(request({ headers = valueHeaders })).status == 204, "1024-byte header value rejected")
local exactAggregate = table.clone(request().headers)
local aggregateBytes = 0
for name, value in exactAggregate do aggregateBytes += #name + #value end
local aggregateIndex = 1
while aggregateBytes < 8_192 do
	local name = `x-a{aggregateIndex}`
	local valueLength = math.min(1_024, 8_192 - aggregateBytes - #name)
	assert(valueLength >= 0, "aggregate header fixture cannot close exact bound")
	exactAggregate[name] = string.rep("v", valueLength)
	aggregateBytes += #name + valueLength
	aggregateIndex += 1
end
assert(aggregateBytes == 8_192, "aggregate header fixture missed exact bound")
local aggregateHandler = Host.newHandler(capability, launchId)
assert(aggregateHandler(request({ headers = exactAggregate })).status == 204, "8192-byte header aggregate rejected")

local paddedHarnessBody = harnessBody .. string.rep(" ", ResultV1.MAX_JSON_BYTES - #harnessBody)
assert(#paddedHarnessBody == ResultV1.MAX_JSON_BYTES, "body limit fixture changed")
local bodyLimitHandler = Host.newHandler(capability, launchId)
assert(bodyLimitHandler(request({ body = paddedHarnessBody })).status == 204, "exact body limit rejected")

local retryHandler, retryAccepted = Host.newHandler(capability, launchId)
assert(retryHandler(request({ headers = { ["content-type"] = "application/json" } })).status == 404 and not retryAccepted(),
	"missing capability consumed request")
assert(retryHandler(request({ headers = {
	["content-type"] = "application/json",
	["x-relay-capability"] = string.rep("00", 32),
} })).status == 404 and not retryAccepted(), "wrong capability consumed request")
assert(retryHandler(request()).status == 204 and retryAccepted(), "valid request after authentication failures rejected")

local handler, accepted = Host.newHandler(capability, launchId)
assert(handler(request()).status == 204 and accepted(), "valid request rejected")
assert(handler(request()).status == 404 and accepted(), "one-shot request accepted twice")

local expectedManifest, maximumResult = HostRuntimeFixtures.maximum()
local maximumResultBody = serde.encode("json", maximumResult)
assert(#maximumResultBody < ResultV1.MAX_JSON_BYTES, "maximum valid Result exceeds transport body bound")
assert(Host.jsonPreflight(maximumResultBody), "maximum valid Result failed raw JSON preflight")
local decodedResult = Host.decodeRoot(maximumResultBody, expectedManifest.launchId)
assert(decodedResult.kind == "Result" and decodedResult.value.runId == expectedManifest.launchId, "Result root rejected")
assert(Host.matchesManifest(decodedResult.value, expectedManifest), "matching Result provenance rejected")

local function memoryFiles()
	local files = {}
	local reads = 0
	local io = {
		writeExclusive = function(path, contents)
			if files[path] ~= nil then error("exists") end
			files[path] = contents
		end,
		readFile = function(path)
			reads += 1
			if files[path] == nil then error("missing") end
			return files[path]
		end,
		move = function(from, to)
			if files[from] == nil or files[to] ~= nil then error("move rejected") end
			files[to] = files[from]
			files[from] = nil
		end,
		removeFile = function(path) files[path] = nil end,
	}
	return files, io, function() return reads end
end

local files, fileIo, readCount = memoryFiles()
local collector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function(count)
	assert(count == 16, "publication temp name must use 16 random bytes")
	return string.rep("cd", count)
end, fileIo)
assert(Host.collectBody(body, launchId, collector).kind == "ControlProof", "collector control proof changed")
assert(Host.collectBody(harnessBody, launchId, collector).kind == "HarnessTermination", "collector Harness termination changed")
assert(next(files) == nil, "control or Harness root persisted output")
local publication = Host.collectBody(maximumResultBody, expectedManifest.launchId, collector)
local expectedPath = "benchmarks/results/local/" .. expectedManifest.launchId .. ".result-v1.json"
assert(publication.kind == "Result" and publication.path == expectedPath, "Result output path derivation changed")
assert(files[expectedPath] == maximumResultBody and readCount() == 1, "atomic temp readback/publication changed")
assert(ResultV1.validate(serde.decode("json", files[expectedPath])).runId == expectedManifest.launchId, "published Result readback rejected")
for path in files do assert(string.sub(path, -4) ~= ".tmp", "publication retained temp file") end

local occupiedFiles, occupiedIo = memoryFiles()
occupiedFiles[expectedPath] = "existing"
local occupiedCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function() return string.rep("ef", 16) end, occupiedIo)
expectError("HOST_E_PUBLICATION", function()
	Host.collectBody(maximumResultBody, expectedManifest.launchId, occupiedCollector)
end)
assert(occupiedFiles[expectedPath] == "existing", "publication overwrote existing Result")
for path in occupiedFiles do assert(string.sub(path, -4) ~= ".tmp", "failed move retained temp file") end

local integrationDirectory = ".tmp/host-runtime-" .. string.sub(serde.hash("sha256", tostring(os.clock())), 1, 16)
assert(not fs.isDir(integrationDirectory) and not fs.isFile(integrationDirectory), "default-fs integration path collision")
fs.writeDir(integrationDirectory)
local integrationOk, integrationError = pcall(function()
	local firstCollector = Host.prepareCollector(expectedManifest, integrationDirectory, function() return string.rep("67", 16) end)
	local firstPublication = Host.collectBody(maximumResultBody, expectedManifest.launchId, firstCollector)
	assert(fs.readFile(firstPublication.path) == maximumResultBody, "default-fs publication readback changed")
	fs.writeFile(firstPublication.path, "existing")
	local secondCollector = Host.prepareCollector(expectedManifest, integrationDirectory, function() return string.rep("89", 16) end)
	expectError("HOST_E_PUBLICATION", function()
		Host.collectBody(maximumResultBody, expectedManifest.launchId, secondCollector)
	end)
	assert(fs.readFile(firstPublication.path) == "existing", "default-fs publication overwrote an existing Result")
	local temporaryPath = integrationDirectory .. "/." .. expectedManifest.launchId .. "." .. string.rep("89", 16) .. ".tmp"
	assert(not fs.isFile(temporaryPath), "default-fs failed publication retained temp file")
end)
local integrationCleanupOk = pcall(fs.removeDir, integrationDirectory)
assert(integrationCleanupOk and not fs.isDir(integrationDirectory), "default-fs integration cleanup failed")
assert(integrationOk, integrationError)

local function deepClone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, nested in value do copied[key] = deepClone(nested) end
	return copied
end
local provenanceMutations = {
	{ name = "benchmark source", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.benchmark.source.revision = string.rep("c", 40)
	end },
	{ name = "fingerprint", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.contract.fingerprint = "sha256:" .. string.rep("d", 64)
	end },
	{ name = "adapter", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.adapter.displayName = "Different Engine Adapter"
	end },
	{ name = "case", code = "HOST_E_SCHEMA", mutate = function(result)
		result.case.workloadId = "state-steady-c2s"
	end },
	{ name = "Studio", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.environment.studio.channel = "beta"
	end },
	{ name = "host", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.environment.host.osVersion = "12"
	end },
	{ name = "execution", code = "HOST_E_SCHEMA", mutate = function(result)
		result.environment.execution.targetFrameRate = 61
	end },
}
for _, test in provenanceMutations do
	local mismatched = deepClone(maximumResult)
	test.mutate(mismatched)
	assert(not Host.matchesManifest(mismatched, expectedManifest), `{test.name} provenance mismatch escaped comparison`)
	local mismatchFiles, mismatchIo = memoryFiles()
	local mismatchCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
		return string.rep("ab", 16)
	end, mismatchIo)
	expectError(test.code, function()
		Host.collectBody(serde.encode("json", mismatched), expectedManifest.launchId, mismatchCollector)
	end)
	assert(next(mismatchFiles) == nil, `{test.name} provenance mismatch wrote output`)
end
local mismatchFiles, mismatchIo = memoryFiles()
local mismatchCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function() return string.rep("ab", 16) end, mismatchIo)
expectError("HOST_E_JSON", function()
	Host.collectBody('{"schema":', expectedManifest.launchId, mismatchCollector)
end)
expectError("HOST_E_SCHEMA", function()
	Host.collectBody('{"kind":"unknown"}', expectedManifest.launchId, mismatchCollector)
end)
assert(next(mismatchFiles) == nil, "decode, schema, or provenance failure wrote output")

local corruptFiles, corruptIo = memoryFiles()
local originalRead = corruptIo.readFile
corruptIo.readFile = function(path)
	originalRead(path)
	return "{}"
end
local corruptCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function() return string.rep("12", 16) end, corruptIo)
expectError("HOST_E_PUBLICATION", function()
	Host.collectBody(maximumResultBody, expectedManifest.launchId, corruptCollector)
end)
assert(next(corruptFiles) == nil, "failed readback wrote output")

local unauthorizedFiles, unauthorizedIo = memoryFiles()
local unauthorizedCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function() return string.rep("34", 16) end, unauthorizedIo)
local unauthorizedHandler, unauthorizedAccepted = Host.newHandler(capability, expectedManifest.launchId, unauthorizedCollector)
local unauthorizedRequest = request({
	body = maximumResultBody,
	headers = { ["content-type"] = "application/json", ["x-relay-capability"] = string.rep("00", 32) },
})
assert(unauthorizedHandler(unauthorizedRequest).status == 404 and not unauthorizedAccepted(), "unauthorized Result accepted")
assert(next(unauthorizedFiles) == nil, "authentication failure wrote output")

local authorizedFiles, authorizedIo = memoryFiles()
local authorizedCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function() return string.rep("56", 16) end, authorizedIo)
local authorizedHandler, authorizedAccepted = Host.newHandler(capability, expectedManifest.launchId, authorizedCollector)
assert(authorizedHandler(request({ body = maximumResultBody })).status == 204 and authorizedAccepted(), "authorized Result request rejected")
assert(authorizedFiles[expectedPath] == maximumResultBody, "authorized Result request did not publish")
local harnessHandler, harnessAccepted = Host.newHandler(capability, launchId)
assert(harnessHandler(request({ body = harnessBody })).status == 204 and harnessAccepted(), "authorized Harness termination rejected")

local bindCalls = 0
local listener, port = Host.bindListener(function(candidatePort, config)
	bindCalls += 1
	assert(candidatePort == 49_152, "bound port left CSPRNG range")
	assert(config.address == "http://127.0.0.1", "listener must bind exact IPv4 loopback")
	assert(type(config.handleRequest) == "function", "listener handler missing")
	if bindCalls < 3 then error("occupied") end
	return { stop = function() end }
end, function() return "0000" end, handler)
assert(type(listener.stop) == "function" and port == 49_152 and bindCalls == 3, "listener retry changed")

bindCalls = 0
expectError("HOST_E_BIND", function()
	Host.bindListener(function()
		bindCalls += 1
		error("occupied")
	end, function() return "0000" end, handler)
end)
assert(bindCalls == 64, "listener must stop after 64 CSPRNG-derived attempts")

local stopped = false
local fakeListener = {}
function fakeListener:stop()
	assert(self == fakeListener, "listener stop receiver missing")
	stopped = true
end
Host.closeListener(fakeListener)
assert(stopped, "listener cleanup did not close listener")

local launchCarrier = Host.carrierData(launchId, capability, 49_152, 4, sourceFacts)
assert(launchCarrier.launchId == launchId and launchCarrier.capability == capability and launchCarrier.port == 49_152,
	"launch carrier tuple changed")
assert(launchCarrier.benchmarkSource == sourceFacts.benchmarkSource and launchCarrier.host == sourceFacts.host,
	"launch carrier source facts changed")
assert(launchCarrier.path == nil and launchCarrier.studio == nil, "path or Studio facts entered launch carrier")
local carrierDataModel = roblox.Instance.new("DataModel")
local carrierServerStorage = roblox.Instance.new("ServerStorage")
carrierServerStorage.Parent = carrierDataModel
local carrierServerRoot = roblox.Instance.new("Folder")
carrierServerRoot.Name = "RelayBenchmarkServer"
carrierServerRoot.Parent = carrierServerStorage
local generatedPlace, carrierSource = Host.launchPlaceBytes(roblox.serializePlace(carrierDataModel, true), launchCarrier, roblox)
luau.compile(carrierSource)
assert(string.sub(generatedPlace, 1, 7) == "<roblox", "generated .rbxlx place was not XML")
local generatedDataModel = roblox.deserializePlace(generatedPlace)
local insertedModule = generatedDataModel:FindFirstChild("ServerStorage"):FindFirstChild("RelayBenchmarkServer"):FindFirstChild("LaunchCarrier")
assert(insertedModule ~= nil and insertedModule.ClassName == "ModuleScript" and insertedModule.Parent.Name == "RelayBenchmarkServer",
	"LaunchCarrier escaped server-only root")
assert(insertedModule.Source == carrierSource and string.find(carrierSource, capability, 1, true) ~= nil,
	"LaunchCarrier did not retain private capability")
assert(string.find(carrierSource, "E:/relay", 1, true) == nil, "path entered LaunchCarrier")

local bootstrap = Host.bootstrapSource()
luau.compile(bootstrap)
assert(string.find(bootstrap, capability, 1, true) == nil, "capability leaked into logged RunScript source")
assert(string.find(bootstrap, launchId, 1, true) == nil, "launch tuple leaked into logged RunScript source")
assert(string.find(bootstrap, [[local body = '{"kind":"RelayStudioControlProofV1","launchId":"' .. carrier.launchId .. '"}]], 1, true) ~= nil,
	"bootstrap must construct exact envelope bytes")
assert(string.find(bootstrap, "ExecuteMultiplayerTestAsync(carrier.recipientCount", 1, true) ~= nil, "bootstrap recipient count changed")
assert(string.find(bootstrap, 'mode = "ControlProof"', 1, true) ~= nil, "bootstrap mode changed")
assert(string.find(bootstrap, "recipientCount = carrier.recipientCount", 1, true) ~= nil, "bootstrap host topology argument changed")
assert(string.find(bootstrap, "caseId", 1, true) == nil, "case identity leaked into scalar-only test args")
assert(string.find(bootstrap, 'workloadId = "state-broadcast-s2c"', 1, true) ~= nil, "manifest selection changed")
assert(string.find(bootstrap, 'moduleId = "native-reliable"', 1, true) ~= nil
	and string.find(bootstrap, 'displayName = "Roblox RemoteEvent"', 1, true) ~= nil
	and string.find(bootstrap, 'kind = "EngineBuiltIn"', 1, true) ~= nil, "native-reliable identity changed")
assert(string.find(bootstrap, "local studioVersion = version()", 1, true) ~= nil, "Studio identity version source changed")
assert(string.find(bootstrap, "HostManifestV1.validate(manifestCandidate)", 1, true) ~= nil
	and string.find(bootstrap, 'manifestModule.Source = "return " .. literal(checked.value)', 1, true) ~= nil,
	"bootstrap did not serialize only a validated HostManifest")
local carrierDestroy = assert(string.find(bootstrap, "carrierModule:Destroy()", 1, true))
local executePosition = assert(string.find(bootstrap, "ExecuteMultiplayerTestAsync", 1, true))
assert(carrierDestroy < executePosition, "LaunchCarrier remained in test clone path")
assert(string.find(bootstrap, "pcall(function() manifestModule:Destroy() end)", 1, true) ~= nil,
	"HostManifest best-effort cleanup changed")
assert(string.find(bootstrap, 'Url = "http://127.0.0.1:" .. tostring(carrier.port)', 1, true) ~= nil,
	"bootstrap loopback URL changed")
assert(string.find(body, capability, 1, true) == nil, "capability leaked into body")

local studioArgs = Host.studioArguments("E:/relay/.tmp/relay-launch.rbxlx", "E:/relay/.tmp/bootstrap.luau", "E:/relay/.tmp/output.log")
local expectedStudioArgs = {
	"--task", "RunScript",
	"--localPlaceFile", "E:/relay/.tmp/relay-launch.rbxlx",
	"--runScriptFile", "E:/relay/.tmp/bootstrap.luau",
	"--outputFile", "E:/relay/.tmp/output.log",
	"--quitAfterExecution",
}
assert(#studioArgs == #expectedStudioArgs, "Studio command arity changed")
for index, expected in expectedStudioArgs do assert(studioArgs[index] == expected, `Studio argument {index} changed`) end
assert(string.find(table.concat(studioArgs, "\n"), capability, 1, true) == nil, "capability leaked into Studio command")
assert(string.find(bootstrap .. table.concat(studioArgs, "\n"), capability, 1, true) == nil,
	"capability leaked into logged source or Studio arguments")

local launchFiles = { bootstrap = true, place = true }
Host.cleanupLaunchFiles("bootstrap", "place", function(path) return launchFiles[path] == true end, function(path)
	launchFiles[path] = nil
end)
assert(next(launchFiles) == nil, "bootstrap or generated place cleanup changed")

local killed = false
local now = 0
local timeout = Host.awaitOutcome(
	function() return nil end,
	function() return false end,
	function() killed = true end,
	function() return now end,
	function(duration) now += duration end,
	0.1
)
assert(timeout.kind == "Timeout" and killed, "timeout must kill Studio process")
local failed = Host.awaitOutcome(function() return { ok = false } end, function() return false end, function() end, os.clock, function() end, 1)
assert(failed.kind == "ProcessFailure", "failed Studio process accepted")
local complete = Host.awaitOutcome(function() return { ok = true } end, function() return true end, function() end, os.clock, function() end, 1)
assert(complete.kind == "Complete" and table.isfrozen(complete), "accepted clean Studio process rejected")

local fakeChild = { killed = false }
function fakeChild:status()
	assert(self == fakeChild, "child status receiver missing")
	return { ok = true }
end
function fakeChild:kill()
	assert(self == fakeChild, "child kill receiver missing")
	self.killed = true
end
assert(Host.childStatus(fakeChild).ok, "child status method failed")
Host.killChild(fakeChild)
assert(fakeChild.killed, "child kill method failed")

print("PASS Relay.EventV1.HostRuntime")
