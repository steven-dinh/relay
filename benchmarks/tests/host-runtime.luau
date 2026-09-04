local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Host = require("../host/HostRuntime")
local ExternalAdapterCatalog = require("../host/ExternalAdapterCatalog")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local ResultV1 = require("../contracts/result-v1")
local HostRuntimeFixtures = require("./support/HostRuntimeFixtures")
local RepetitionFragmentV1 = require("../contracts/internal/RepetitionFragmentV1")

local function expectError(code, callback)
	local ok, message = pcall(callback)
	assert(not ok and message == code, `expected {code}, got {tostring(message)}`)
end

do
	local studioCheckCall
	Host.assertStudioIdle("windows", function(program, arguments)
		studioCheckCall = { program = program, arguments = arguments }
		return { ok = true, stdout = "Idle\r\n" }
	end)
	assert(studioCheckCall.program == "powershell.exe" and studioCheckCall.arguments[1] == "-NoProfile"
		and studioCheckCall.arguments[2] == "-NonInteractive" and studioCheckCall.arguments[3] == "-Command",
		"Studio preflight must use structured PowerShell arguments")
	assert(string.find(studioCheckCall.arguments[4], "Get-Process -ErrorAction Stop", 1, true) ~= nil
		and string.find(studioCheckCall.arguments[4], "'RobloxStudioBeta'", 1, true) ~= nil
		and string.find(studioCheckCall.arguments[4], "'RobloxStudio'", 1, true) ~= nil,
		"Studio preflight must query fixed Studio process names and surface query errors")
	expectError("HOST_E_STUDIO_BUSY", function()
		Host.assertStudioIdle("windows", function() return { ok = true, stdout = "Busy\r\n" } end)
	end)
	for _, result in {
		{ ok = false, stdout = "Idle" },
		{ ok = true, stdout = "" },
		{ ok = true, stdout = "Busy\nIdle" },
		{ ok = true, stdout = string.rep(" ", 17) .. "Idle" },
	} do
		expectError("HOST_E_STUDIO_CHECK", function()
			Host.assertStudioIdle("windows", function() return result end)
		end)
	end
	expectError("HOST_E_STUDIO_CHECK", function()
		Host.assertStudioIdle("windows", function() error("process query failed") end)
	end)
	Host.assertStudioIdle("macos", function() error("Windows-only preflight ran on macOS") end)
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
assert(table.isfrozen(options) and table.isfrozen(options.selection), "parsed arguments must be deeply frozen")
assert(options.adapterId == "native-reliable", "default adapter changed")
for _, adapterId in { "native-reliable", "relay-reliable" } do
	local args = table.clone(windowsArgs)
	table.insert(args, "--adapter"); table.insert(args, adapterId)
	assert(Host.parseArgs(args, "windows").adapterId == adapterId, "explicit adapter selection rejected")
end
for _, suffix in { { "--adapter", "unknown" }, { "--unknown", "relay-reliable" }, { "--adapter" } } do
	local args = table.clone(windowsArgs)
	for _, value in suffix do table.insert(args, value) end
	expectError("HOST_E_ARGS", function() Host.parseArgs(args, "windows") end)
end
for _, recipientCount in { 1, 8 } do
	local topologyArgs = table.clone(windowsArgs)
	topologyArgs[8] = tostring(recipientCount)
	assert(Host.parseArgs(topologyArgs, "windows").recipientCount == recipientCount, `topology {recipientCount} rejected`)
end

for _, case in {
	{ "tiny-steady-c2s", 1, "Workload" },
	{ "state-steady-c2s", 1, "Workload" },
	{ "state-burst-c2s", 1, "Workload" },
	{ "state-broadcast-s2c", 1, "Workload" },
	{ "state-broadcast-s2c", 4, "Workload" },
	{ "state-broadcast-s2c", 8, "Workload" },
	{ "tiny-round-trip", 1, "SeparateProbe" },
} do
	local args = table.clone(windowsArgs)
	args[4] = "Benchmark"
	args[6] = case[1]
	args[8] = tostring(case[2])
	local parsed = Host.parseArgs(args, "windows")
	assert(parsed.mode == "Benchmark" and parsed.selection.kind == case[3], `Benchmark case {case[1]}/{case[2]} rejected`)
end

for _, adapterId in { "quicknet", "bytenet", "satset", "warp", "blink", "zap", "netray-compile" } do
	local args = table.clone(windowsArgs)
	args[4] = "Benchmark"
	table.insert(args, "--adapter"); table.insert(args, adapterId)
	local parsed = Host.parseArgs(args, "windows")
	assert(parsed.external and parsed.adapterId == adapterId, `external adapter {adapterId} rejected`)
end
do
	local args = table.clone(windowsArgs)
	table.insert(args, "--adapter"); table.insert(args, "quicknet")
	expectError("HOST_E_ARGS", function() Host.parseArgs(args, "windows") end)
	args[4] = "Benchmark"
	args[2] = "/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio"
	expectError("HOST_E_EXTERNAL_OS", function() Host.parseArgs(args, "macos") end)
	args[2] = windowsArgs[2]
	args[10] = "suphi-packet"
	expectError("HOST_E_EXTERNAL_UNSUPPORTED_SUPHI_FRAME_BOUND", function()
		Host.parseArgs(args, "windows")
	end)
end

local macArgs = table.clone(windowsArgs)
macArgs[2] = "/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio"
assert(Host.parseArgs(macArgs, "macos").recipientCount == 4, "macOS absolute Studio path rejected")

for _, mutation in {
	function(args) table.remove(args) end,
	function(args) args[1] = "--unknown" end,
	function(args) args[2] = "relative.exe" end,
	function(args) args[4] = "Unknown" end,
	function(args) args[6] = "missing" end,
	function(args) args[4] = "Benchmark"; args[6] = "state-burst-c2s"; args[8] = "4" end,
	function(args) args[8] = "01" end,
	function(args) args[8] = "8"; args[6] = "tiny-steady-c2s" end,
	function(args) args[4] = "Benchmark"; args[6] = "tiny-round-trip"; args[8] = "4" end,
} do
	local candidate = table.clone(windowsArgs)
	mutation(candidate)
	expectError("HOST_E_ARGS", function() Host.parseArgs(candidate, "windows") end)
end

for _, arguments in {
	{},
	{ "--mode", "Benchmark", "--case", "tiny-steady-c2s", "--recipients", "1" },
	{ "--mode", "ControlProof", "--studio", windowsArgs[2], "--case", "state-broadcast-s2c", "--recipients", "4" },
} do
	local command = { "run", "benchmarks/host/run-event-v1.luau" }
	for _, argument in arguments do table.insert(command, argument) end
	local rejected = process.exec("lune", command)
	assert(not rejected.ok and string.find(rejected.stderr, "HOST_E_ARGS", 1, true) ~= nil,
		"host CLI silently accepted missing or reordered arguments")
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
local hashedValues = {}
local placeBytes = "exact\0pre-carrier\255place"
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
		table.insert(hashedValues, value)
		return if #hashedValues == 1 then string.rep("b", 64) else string.rep("e", 64)
	end,
	placeBytes
)
assert(sourceFacts.benchmarkSource.revision == string.rep("a", 40) and sourceFacts.benchmarkSource.dirty, "git source facts changed")
assert(sourceFacts.contractFingerprint == "sha256:" .. string.rep("b", 64), "contract fingerprint shape changed")
assert(sourceFacts.benchmarkSource.placeFingerprint == "sha256:" .. string.rep("e", 64), "place fingerprint shape changed")
assert(sourceFacts.host.osFamily == "Windows" and sourceFacts.host.architecture == "x86_64", "host source facts changed")
assert(hashedValues[1] == "first\nsecond\nthird\n", "contract fingerprint input was not LF-normalized")
assert(hashedValues[2] == placeBytes, "place fingerprint did not hash exact pre-carrier bytes")
assert(#sourceCommands == 2 and sourceCommands[1].program == "git" and sourceCommands[1].arguments[1] == "rev-parse"
	and sourceCommands[1].arguments[2] == "HEAD", "revision command changed")
local dirtyArguments = sourceCommands[2].arguments
assert(dirtyArguments[1] == "status" and dirtyArguments[2] == "--porcelain=v1"
	and dirtyArguments[3] == "--untracked-files=normal" and dirtyArguments[4] == "--ignore-submodules=none",
	"dirty command changed")
assert(sourceCommands[1].options.cwd == "E:/relay" and sourceCommands[2].options.cwd == "E:/relay", "git command cwd changed")
Host.assertCleanSource("E:/relay", string.rep("a", 40), function(_, arguments)
	return { ok = true, stdout = if arguments[1] == "rev-parse" then string.rep("a", 40) .. "\n" else "" }
end)
expectError("HOST_E_SOURCE_DIRTY", function()
	Host.assertCleanSource("E:/relay", string.rep("a", 40), function(_, arguments)
		return { ok = true, stdout = if arguments[1] == "rev-parse" then string.rep("a", 40) .. "\n" else " M file\n" }
	end)
end)
expectError("HOST_E_SOURCE_CHANGED", function()
	Host.assertCleanSource("E:/relay", string.rep("a", 40), function()
		return { ok = true, stdout = string.rep("c", 40) .. "\n" }
	end)
end)
local macFacts = Host.collectSourceFacts("/relay", "macos", "aarch64", function(_, arguments)
	return { ok = true, stdout = if arguments[1] == "rev-parse" then string.rep("c", 64) .. "\n" else "" }
end, function() return "x" end, function() return string.rep("d", 64) end, "place")
assert(not macFacts.benchmarkSource.dirty and macFacts.host.osFamily == "macOS" and macFacts.host.architecture == "arm64",
	"macOS source facts changed")

local trustedManifest = Host.nativeManifest("00000000-0000-4000-8000-000000000000", "0.650.0.6500000", options.selection, sourceFacts)
assert(trustedManifest.benchmarkSource.placeFingerprint == sourceFacts.benchmarkSource.placeFingerprint,
	"trusted native manifest lost the exact place fingerprint")
assert(trustedManifest.selection.workloadId == "state-broadcast-s2c"
	and trustedManifest.adapter.identity.library.version == "0.650.0.6500000", "trusted native manifest changed")

do
	local selected = ExternalAdapterCatalog.selected(
		serde.decode("json", fs.readFile("benchmarks/libraries.lock.json")),
		"quicknet"
	)
	local adapter = ExternalAdapterCatalog.adapter(selected, "sha256:" .. string.rep("b", 64), "0.650.0.6500000")
	local fragmentManifest = Host.nativeManifest(
		"00000000-0000-4000-8000-000000000000",
		"0.650.0.6500000",
		options.selection,
		sourceFacts,
		adapter
	)
	local fragmentCollector = Host.prepareFragmentCollector(
		fragmentManifest,
		"11111111-1111-4111-8111-111111111111",
		7
	)
	local fragment = {
		batchId = fragmentCollector.batchId,
		repetitionIndex = fragmentCollector.repetitionIndex,
		manifest = fragmentManifest,
	}
	assert(Host.validateFragmentProvenance(fragment, fragmentManifest.launchId, fragmentCollector),
		"exact fragment provenance rejected")
	for _, mutation in {
		function(value) value.batchId = "22222222-2222-4222-8222-222222222222" end,
		function(value) value.repetitionIndex = 8 end,
		function(value) value.manifest = trustedManifest end,
	} do
		local candidate = table.clone(fragment)
		mutation(candidate)
		expectError("HOST_E_PROVENANCE", function()
			Host.validateFragmentProvenance(candidate, fragmentManifest.launchId, fragmentCollector)
		end)
	end
	expectError("HOST_E_PROVENANCE", function()
		Host.validateFragmentProvenance(fragment, "33333333-3333-4333-8333-333333333333", fragmentCollector)
	end)
end

local uuid = Host.uuidV4(function(count)
	assert(count == 16, "UUID must request exactly 16 random bytes")
	return string.rep("00", count)
end)
assert(uuid == "00000000-0000-4000-8000-000000000000", "canonical UUID v4 bits changed")
local capability = string.rep("ab", 32)
assert(Host.constantWorkCapability(capability, capability), "exact capability rejected")
assert(not Host.constantWorkCapability(string.upper(capability), capability), "uppercase capability accepted")
assert(not Host.constantWorkCapability(string.sub(capability, 2), capability), "short capability accepted")
assert(not Host.constantWorkCapability({}, capability), "non-string capability accepted")

local launchId = "00000000-0000-4000-8000-000000000000"
local studioVersion = "0.650.0.6500000"
local body = Host.envelope(launchId)
assert(body == '{"kind":"RelayStudioControlProofV1","launchId":"' .. launchId .. '"}', "control envelope bytes changed")
assert(Host.jsonPreflight(body), "control envelope JSON preflight rejected")
assert(Host.decodeRoot(body, launchId).kind == "ControlProof", "control root classification changed")

local depthTen = string.rep("[", 10) .. "0" .. string.rep("]", 10)
assert(Host.jsonPreflight(depthTen), "depth-ten JSON rejected")
expectError("HOST_E_JSON", function() Host.jsonPreflight("[" .. depthTen .. "]") end)
local maximumTokenArray = "[" .. string.rep("0,", 131_070) .. "0]"
assert(Host.jsonPreflight(maximumTokenArray), "maximum structural-token JSON rejected")
expectError("HOST_E_JSON", function() Host.jsonPreflight("[" .. string.rep("0,", 131_071) .. "0]") end)
local rawKeyAtLimit = string.rep("k", 128)
local escapedKeyAtLimit = string.rep("\\u006b", 128)
assert(Host.jsonPreflight('{"' .. rawKeyAtLimit .. '":0}'), "128-byte raw object key rejected")
assert(Host.jsonPreflight('{"' .. escapedKeyAtLimit .. '":0}'), "128-byte escaped object key rejected")
expectError("HOST_E_JSON", function()
	Host.jsonPreflight('{"' .. rawKeyAtLimit .. 'k":0}')
end)
expectError("HOST_E_JSON", function()
	Host.jsonPreflight('{"' .. escapedKeyAtLimit .. '\\u006b":0}')
end)
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

local FRAME_PREFIX = "RELAY_TERMINAL_V1"
local FRAME_CHUNK_BYTES = 1_024

local function encodeHex(source)
	local encoded = table.create(#source)
	for index = 1, #source do
		encoded[index] = string.format("%02x", string.byte(source, index))
	end
	return table.concat(encoded)
end

local function terminalLines(payload, framedCapability, framedLaunchId, framedStudioVersion)
	framedCapability = framedCapability or capability
	framedLaunchId = framedLaunchId or launchId
	framedStudioVersion = framedStudioVersion or studioVersion
	local count = math.ceil(#payload / FRAME_CHUNK_BYTES)
	local lines = {
		`{FRAME_PREFIX} {framedCapability} BEGIN {framedLaunchId} {encodeHex(framedStudioVersion)} {#payload} {count}`,
	}
	for index = 1, count do
		local first = (index - 1) * FRAME_CHUNK_BYTES + 1
		lines[#lines + 1] = `{FRAME_PREFIX} {framedCapability} CHUNK {framedLaunchId} {index} {encodeHex(string.sub(payload, first, first + FRAME_CHUNK_BYTES - 1))}`
	end
	lines[#lines + 1] = `{FRAME_PREFIX} {framedCapability} END {framedLaunchId} {#payload} {count}`
	return lines
end

local function terminalLog(payload, framedCapability, framedLaunchId, framedStudioVersion)
	local lines = terminalLines(payload, framedCapability, framedLaunchId, framedStudioVersion)
	table.insert(lines, 1, "> RunScript source and unrelated Studio output")
	lines[#lines + 1] = "unrelated trailing output"
	return table.concat(lines, "\r\n") .. "\r\n"
end

local controlFactoryCalls = 0
local function collectControl(output)
	return Host.collectTerminalLog(output, capability, launchId, "ControlProof", function(attestedVersion)
		controlFactoryCalls += 1
		assert(attestedVersion == studioVersion, "trusted Studio-version frame changed")
		return nil
	end)
end

assert(collectControl("unrelated output") == nil, "missing authenticated frame was accepted")
assert(collectControl(terminalLog(body, string.rep("cd", 32))) == nil, "wrong capability frame was accepted")
local controlTerminal = collectControl(terminalLog(body))
assert(controlTerminal.kind == "ControlProof" and controlFactoryCalls == 1, "valid framed ControlProof rejected")

local malformedFrameLogs = {}
do
	local missing = terminalLines(body)
	table.remove(missing, 2)
	malformedFrameLogs[#malformedFrameLogs + 1] = table.concat(missing, "\n")
	local duplicate = terminalLines(body)
	duplicate[#duplicate + 1] = duplicate[#duplicate]
	malformedFrameLogs[#malformedFrameLogs + 1] = table.concat(duplicate, "\n")
	local wrongLaunch = terminalLines(body, capability, "11111111-1111-4111-8111-111111111111")
	malformedFrameLogs[#malformedFrameLogs + 1] = table.concat(wrongLaunch, "\n")
	local invalidHex = terminalLines(body)
	invalidHex[2] = string.gsub(invalidHex[2], " [0-9a-f]+$", " gg")
	malformedFrameLogs[#malformedFrameLogs + 1] = table.concat(invalidHex, "\n")
	malformedFrameLogs[#malformedFrameLogs + 1] = `{FRAME_PREFIX} {capability} BEGIN {launchId} {encodeHex(studioVersion)} {ResultV1.MAX_JSON_BYTES + 1} 8193`
end
for _, output in malformedFrameLogs do
	expectError("HOST_E_FRAME", function() collectControl(output) end)
end
do
	local length = RepetitionFragmentV1.MAX_JSON_BYTES + 1
	local count = math.ceil(length / FRAME_CHUNK_BYTES)
	local oversizedFragmentBegin = `{FRAME_PREFIX} {capability} BEGIN {launchId} {encodeHex(studioVersion)} {length} {count}`
	expectError("HOST_E_FRAME", function()
		Host.collectTerminalLog(oversizedFragmentBegin, capability, launchId, "ProcessRepetition", function()
			error("oversized fragment reached collector")
		end)
	end)
end
expectError("HOST_E_SCHEMA", function() collectControl(terminalLog(body .. " ")) end)

local expectedManifest, maximumResult = HostRuntimeFixtures.maximum()
local maximumResultBody = serde.encode("json", maximumResult)
assert(#maximumResultBody < ResultV1.MAX_JSON_BYTES, "maximum valid Result exceeds transport body bound")
assert(Host.jsonPreflight(maximumResultBody), "maximum valid Result failed raw JSON preflight")
local decodedResult = Host.decodeRoot(maximumResultBody, expectedManifest.launchId)
assert(decodedResult.kind == "Result" and decodedResult.value.runId == expectedManifest.launchId, "Result root rejected")
assert(Host.matchesManifest(decodedResult.value, expectedManifest), "matching Result provenance rejected")

local function collectBenchmarkTerminal(payload, collector, framedStudioVersion)
	local output = terminalLog(payload, capability, expectedManifest.launchId, framedStudioVersion or expectedManifest.environment.studio.version)
	return Host.collectTerminalLog(output, capability, expectedManifest.launchId, "Benchmark", function(attestedVersion)
		assert(attestedVersion == expectedManifest.environment.studio.version, "Result trusted Studio attestation changed")
		return collector
	end)
end

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

local collidedTempFiles, collidedTempIo = memoryFiles()
local collidedRandom = string.rep("45", 16)
local collidedTempPath = "benchmarks/results/local/." .. expectedManifest.launchId .. "." .. collidedRandom .. ".tmp"
collidedTempFiles[collidedTempPath] = "other-launch"
local collidedTempCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
	return collidedRandom
end, collidedTempIo)
expectError("HOST_E_PUBLICATION", function()
	Host.collectBody(maximumResultBody, expectedManifest.launchId, collidedTempCollector)
end)
assert(collidedTempFiles[collidedTempPath] == "other-launch", "failed exclusive temp creation deleted an unowned file")

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
	{ name = "place fingerprint", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.benchmark.source.placeFingerprint = "sha256:" .. string.rep("8", 64)
	end },
	{ name = "fingerprint", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.contract.fingerprint = "sha256:" .. string.rep("d", 64)
	end },
	{ name = "adapter", code = "HOST_E_PROVENANCE", mutate = function(result)
		result.adapter.displayName = "Different Engine Adapter"
	end },
	{ name = "case", code = "HOST_E_SCHEMA", mutate = function(result)
		result.case.workloadId = "state-burst-c2s"
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
local unauthorizedTerminal = Host.collectTerminalLog(
	terminalLog(maximumResultBody, string.rep("00", 32), expectedManifest.launchId, expectedManifest.environment.studio.version),
	capability,
	expectedManifest.launchId,
	"Benchmark",
	function() return unauthorizedCollector end
)
assert(unauthorizedTerminal == nil, "unauthorized Result frame accepted")
assert(next(unauthorizedFiles) == nil, "authentication failure wrote output")

local authorizedFiles, authorizedIo = memoryFiles()
local authorizedCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function() return string.rep("56", 16) end, authorizedIo)
local authorizedTerminal = collectBenchmarkTerminal(maximumResultBody, authorizedCollector)
assert(authorizedTerminal.kind == "Result", "authorized Result frames rejected")
assert(next(authorizedFiles) == nil, "frame collection published a Result before Studio exited")
local cleanExit = Host.awaitOutcome(function() return { ok = true } end, function() return authorizedTerminal end,
	function() end, os.clock, function() end, 1)
local authorizedPublication = Host.completeBenchmark(cleanExit.terminal)
assert(authorizedPublication.path == expectedPath and authorizedFiles[expectedPath] == maximumResultBody,
	"clean Studio exit did not publish the retained Result")

for _, status in { "Invalid", "Error" } do
	local failedResult = deepClone(maximumResult)
	failedResult.status = status
	failedResult.failures = if status == "Invalid"
		then { { category = "Lifecycle", code = "TeardownFailure", occurrences = 1 } }
		else { { category = "Harness", code = "InternalError", occurrences = 1, discriminator = { stage = "Finalize" } } }
	for _, measurement in failedResult.measurements do
		if status == "Error" then
			measurement.state = "Unavailable"
			measurement.unavailableReason = { code = "ResultUntrusted" }
			measurement.rawSamples = nil
			measurement.summary = nil
		elseif measurement.metadata.summary ~= "Exact" then
			measurement.state = "Diagnostic"
			measurement.summary = nil
		end
	end
	assert(ResultV1.validate(failedResult).status == status, `{status} host fixture must validate`)
	local failedBody = serde.encode("json", failedResult)
	local failedFiles, failedIo = memoryFiles()
	local failedCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
		return string.rep("62", 16)
	end, failedIo)
	local failedTerminal = collectBenchmarkTerminal(failedBody, failedCollector)
	assert(failedTerminal.kind == "Result", `{status} benchmark diagnostic was rejected`)
	expectError(`HOST_E_RESULT_{string.upper(status)}`, function()
		Host.completeBenchmark(failedTerminal)
	end)
	assert(failedFiles[expectedPath] == failedBody,
		`{status} benchmark failed without retaining its diagnostic Result`)
end

for _, terminalFailure in {
	{ name = "nonzero", outcome = function(accessor)
		return Host.awaitOutcome(function() return { ok = false } end, accessor, function() end, os.clock, function() end, 1)
	end },
	{ name = "timeout", outcome = function(accessor)
		local clock = 0
		local exited = false
		return Host.awaitOutcome(function() return if exited then { ok = false } else nil end, accessor, function()
			exited = true
		end, function() return clock end, function(duration) clock += duration end, 0.1, 0.1)
	end },
} do
	local failureFiles, failureIo = memoryFiles()
	local failureCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
		return string.rep("60", 16)
	end, failureIo)
	local failureTerminal = collectBenchmarkTerminal(maximumResultBody, failureCollector)
	local failedOutcome = terminalFailure.outcome(function() return failureTerminal end)
	assert(failedOutcome.kind ~= "Complete" and next(failureFiles) == nil,
		`{terminalFailure.name} Studio outcome published a final Result`)
end

local attestationFiles, attestationIo = memoryFiles()
local attestationCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
	return string.rep("57", 16)
end, attestationIo)
local attestationOk = pcall(function()
	collectBenchmarkTerminal(maximumResultBody, attestationCollector, "0.999.0.9999999")
end)
assert(not attestationOk, "Result-provided Studio version bypassed independent bootstrap attestation")
assert(next(attestationFiles) == nil, "failed Studio attestation wrote output")

local wrongModeFactoryCalls = 0
expectError("HOST_E_SCHEMA", function()
	Host.collectTerminalLog(
		terminalLog(maximumResultBody, capability, expectedManifest.launchId, expectedManifest.environment.studio.version),
		capability,
		expectedManifest.launchId,
		"ControlProof",
		function()
			wrongModeFactoryCalls += 1
			return authorizedCollector
		end
	)
end)
assert(wrongModeFactoryCalls == 0, "wrong-mode Result reached collector construction before mode validation")
local wrongModeFiles, wrongModeIo = memoryFiles()
local wrongModeCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
	return string.rep("58", 16)
end, wrongModeIo)
expectError("HOST_E_SCHEMA", function()
	Host.collectTerminalLog(
		terminalLog(body, capability, expectedManifest.launchId, expectedManifest.environment.studio.version),
		capability,
		expectedManifest.launchId,
		"Benchmark",
		function() return wrongModeCollector end
	)
end)
assert(next(wrongModeFiles) == nil, "wrong-mode ControlProof wrote output")

local retryCollectionFiles, retryCollectionIo = memoryFiles()
local retryWriteExclusive = retryCollectionIo.writeExclusive
local rejectFirstPublication = true
retryCollectionIo.writeExclusive = function(path, contents)
	if rejectFirstPublication then
		rejectFirstPublication = false
		error("transient publication failure")
	end
	retryWriteExclusive(path, contents)
end
local retryCollectionCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
	return string.rep("78", 16)
end, retryCollectionIo)
local retryCollectionTerminal = collectBenchmarkTerminal(maximumResultBody, retryCollectionCollector)
assert(retryCollectionTerminal.kind == "Result", "valid terminal body was rejected before publication")
assert(next(retryCollectionFiles) == nil, "frame collection attempted publication")
expectError("HOST_E_PUBLICATION", function() Host.commitTerminal(retryCollectionTerminal) end)
assert(next(retryCollectionFiles) == nil, "failed post-exit publication retained output")

assert(collectControl(terminalLog(harnessBody)).kind == "HarnessTermination", "authorized Harness termination rejected")
local benchmarkHarnessFiles, benchmarkHarnessIo = memoryFiles()
local benchmarkHarnessCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
	return string.rep("59", 16)
end, benchmarkHarnessIo)
local benchmarkHarnessTerminal = collectBenchmarkTerminal(harnessBody, benchmarkHarnessCollector)
assert(benchmarkHarnessTerminal.kind == "HarnessTermination", "Benchmark mode rejected Harness termination")
assert(next(benchmarkHarnessFiles) == nil, "Harness termination persisted a Result")

local sizePath = "E:/relay/.tmp/output.log"
local windowsSizeCall
assert(Host.outputFileSize(sizePath, "windows", function(program, arguments)
	windowsSizeCall = { program = program, arguments = arguments }
	return { ok = true, stdout = "123\r\n" }
end) == 123, "Windows output size changed")
assert(windowsSizeCall.program == "powershell.exe" and windowsSizeCall.arguments[1] == "-NoProfile"
	and windowsSizeCall.arguments[2] == "-NonInteractive" and windowsSizeCall.arguments[3] == "-Command"
	and string.find(windowsSizeCall.arguments[4], "$args[0]", 1, true) ~= nil
	and windowsSizeCall.arguments[5] == sizePath, "Windows output size must use structured path arguments")
local macSizeCall
assert(Host.outputFileSize(sizePath, "macos", function(program, arguments)
	macSizeCall = { program = program, arguments = arguments }
	return { ok = true, stdout = "456\n" }
end) == 456, "macOS output size changed")
assert(macSizeCall.program == "/usr/bin/stat" and table.concat(macSizeCall.arguments, "\0") == "-f\0%z\0" .. sizePath,
	"macOS output size command changed")
for _, result in { { ok = false, stdout = "1" }, { ok = true, stdout = "" }, { ok = true, stdout = "-1" }, { ok = true, stdout = "1e3" } } do
	expectError("HOST_E_OUTPUT", function() Host.outputFileSize(sizePath, "windows", function() return result end) end)
end

local oversizedRead = false
expectError("HOST_E_OUTPUT_LIMIT", function()
	Host.readTerminalFile(sizePath, "windows", function()
		return { ok = true, stdout = tostring(Host.MAX_OUTPUT_LOG_BYTES + 1) }
	end, function()
		oversizedRead = true
		return ""
	end, capability, launchId, "ControlProof", function() return nil end)
end)
assert(not oversizedRead, "oversized Studio output was materialized before rejection")
local controlLog = terminalLog(body)
local fileTerminal = Host.readTerminalFile(sizePath, "windows", function()
	return { ok = true, stdout = tostring(#controlLog) }
end, function(path)
	assert(path == sizePath, "terminal reader path changed")
	return controlLog
end, capability, launchId, "ControlProof", function(version)
	assert(version == studioVersion, "file terminal Studio attestation changed")
	return nil
end)
assert(fileTerminal.kind == "ControlProof", "bounded Studio output file rejected")
expectError("HOST_E_OUTPUT", function()
	Host.readTerminalFile(sizePath, "windows", function()
		return { ok = true, stdout = tostring(#controlLog - 1) }
	end, function() return controlLog end, capability, launchId, "ControlProof", function() return nil end)
end)

local launchCarrier = Host.carrierData(launchId, capability, options, sourceFacts)
assert(launchCarrier.launchId == launchId and launchCarrier.capability == capability and launchCarrier.port == nil,
	"launch carrier tuple changed")
assert(launchCarrier.benchmarkSource == sourceFacts.benchmarkSource and launchCarrier.host == sourceFacts.host,
	"launch carrier source facts changed")
assert(launchCarrier.mode == "ControlProof" and launchCarrier.selection.workloadId == "state-broadcast-s2c",
	"launch carrier mode or selection changed")
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

local batchId = "11111111-1111-4111-8111-111111111111"
local externalAdapter = {
	moduleId = "quicknet",
	artifact = { kind = "RepositoryModule", digest = "sha256:" .. string.rep("a", 64) },
	identity = { semantics = { repetitionIsolation = "ProcessRestart" } },
}
local processCarrier = Host.processCarrierData(
	launchId,
	capability,
	batchId,
	7,
	{ recipientCount = 4, selection = options.selection },
	sourceFacts,
	externalAdapter
)
assert(processCarrier.mode == "ProcessRepetition" and processCarrier.batchId == batchId
	and processCarrier.repetitionIndex == 7 and processCarrier.adapter == externalAdapter,
	"process repetition carrier changed")
local processModel = roblox.Instance.new("DataModel")
local processServerStorage = roblox.Instance.new("ServerStorage")
processServerStorage.Parent = processModel
local processServerRoot = roblox.Instance.new("Folder")
processServerRoot.Name = "RelayBenchmarkServer"
processServerRoot.Parent = processServerStorage
local processReplicatedStorage = roblox.Instance.new("ReplicatedStorage")
processReplicatedStorage.Parent = processModel
local processBenchmark = roblox.Instance.new("Folder")
processBenchmark.Name = "RelayBenchmark"
processBenchmark.Parent = processReplicatedStorage
local processAdapters = roblox.Instance.new("Folder")
processAdapters.Name = "adapters"
processAdapters.Parent = processBenchmark
local processPlace = Host.launchPlaceBytes(roblox.serializePlace(processModel, true), processCarrier, roblox)
local processGenerated = roblox.deserializePlace(processPlace)
local externalPin = processGenerated:FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark")
	:FindFirstChild("adapters"):FindFirstChild("ExternalAdapterPin")
assert(externalPin ~= nil and externalPin.ClassName == "ModuleScript"
	and processGenerated:FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark")
		:FindFirstChild("adapters"):FindFirstChild("RelayAdapterPin") == nil,
	"process-isolated adapter pin changed")

do
	local digestModel = roblox.Instance.new("DataModel")
	local digestReplicated = roblox.Instance.new("ReplicatedStorage")
	digestReplicated.Parent = digestModel
	local digestBenchmark = roblox.Instance.new("Folder")
	digestBenchmark.Name = "RelayBenchmark"
	digestBenchmark.Parent = digestReplicated
	local digestAdapters = roblox.Instance.new("Folder")
	digestAdapters.Name = "adapters"
	digestAdapters.Parent = digestBenchmark
	local selectedModule = roblox.Instance.new("ModuleScript")
	selectedModule.Name = "ExternalSelected"
	selectedModule.Source = "selected\nbinding"
	selectedModule.Parent = digestAdapters
	local commonModule = roblox.Instance.new("ModuleScript")
	commonModule.Name = "ExternalAdapter"
	commonModule.Source = "shared-binding"
	commonModule.Parent = digestAdapters
	local ignoredContract = roblox.Instance.new("ModuleScript")
	ignoredContract.Name = "AdapterContract"
	ignoredContract.Source = "must-not-enter-digest"
	ignoredContract.Parent = digestAdapters
	local digestServerStorage = roblox.Instance.new("ServerStorage")
	digestServerStorage.Parent = digestModel
	local digestServerRoot = roblox.Instance.new("Folder")
	digestServerRoot.Name = "RelayBenchmarkServer"
	digestServerRoot.Parent = digestServerStorage
	local template = roblox.Instance.new("Folder")
	template.Name = "ExternalTemplate"
	template.Parent = digestServerRoot
	local library = roblox.Instance.new("ModuleScript")
	library.Name = "Library"
	library.Source = "library\nsource"
	library.Parent = template
	local lock = serde.decode("json", fs.readFile("benchmarks/libraries.lock.json"))
	local selected = ExternalAdapterCatalog.selected(lock, "quicknet")
	local hashed = nil
	local adapter = Host.collectExternalAdapter(selected, roblox.serializePlace(digestModel, true), roblox, function(algorithm, value)
		assert(algorithm == "sha256", "external adapter digest algorithm changed")
		hashed = value
		return string.rep("a", 64)
	end)
	local function frame(path, source)
		return `{#path}:{path}{#source}:{source}`
	end
	assert(hashed == frame("ExternalSelected", selectedModule.Source)
		.. frame("ExternalAdapter", commonModule.Source)
		.. frame("ExternalTemplate/Library", library.Source),
		"external adapter digest did not length-frame exact selected binding/template bytes")
	assert(string.find(hashed, ignoredContract.Source, 1, true) == nil
		and adapter.artifact.digest == "sha256:" .. string.rep("a", 64),
		"unselected source entered external adapter provenance")
end

local bootstrap = Host.bootstrapSource()
luau.compile(bootstrap)
assert(string.find(bootstrap, capability, 1, true) == nil, "capability leaked into logged RunScript source")
assert(string.find(bootstrap, launchId, 1, true) == nil, "launch tuple leaked into logged RunScript source")
assert(string.find(bootstrap, [[body = '{"kind":"RelayStudioControlProofV1","launchId":"' .. carrier.launchId .. '"}]], 1, true) ~= nil,
	"bootstrap must construct exact envelope bytes")
assert(string.find(bootstrap, "ExecuteMultiplayerTestAsync(carrier.recipientCount", 1, true) ~= nil, "bootstrap recipient count changed")
assert(string.find(bootstrap, "mode = carrier.mode", 1, true) ~= nil, "bootstrap mode changed")
assert(string.find(bootstrap, "recipientCount = carrier.recipientCount", 1, true) ~= nil, "bootstrap host topology argument changed")
assert(string.find(bootstrap, "testArguments.batchId = carrier.batchId", 1, true) ~= nil
	and string.find(bootstrap, "testArguments.repetitionIndex = carrier.repetitionIndex", 1, true) ~= nil,
	"bootstrap process repetition arguments changed")
assert(string.find(bootstrap, "caseId", 1, true) == nil, "case identity leaked into scalar-only test args")
assert(string.find(bootstrap, "selection = carrier.selection", 1, true) ~= nil, "manifest selection changed")
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
assert(string.find(bootstrap, 'local FRAME_PREFIX = "RELAY_TERMINAL_V1"', 1, true) ~= nil
	and string.find(bootstrap, "local FRAME_CHUNK_BYTES = 1024", 1, true) ~= nil
	and string.find(bootstrap, "local MAX_JSON_BYTES = 8388608", 1, true) ~= nil,
	"bootstrap frame bounds drifted")
assert(string.find(bootstrap, ' .. carrier.capability .. " BEGIN " .. carrier.launchId', 1, true) ~= nil
	and string.find(bootstrap, ' .. carrier.capability .. " CHUNK " .. carrier.launchId', 1, true) ~= nil
	and string.find(bootstrap, ' .. carrier.capability .. " END " .. carrier.launchId', 1, true) ~= nil,
	"authenticated begin/chunk/end framing changed")
assert(string.find(bootstrap, "HttpService:RequestAsync", 1, true) == nil,
	"bootstrap retained the unbounded HTTP terminal transport")
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

local buildFiles = {}
local buildCall = nil
local builtPlace = Host.buildPlace("E:/relay", "E:/relay/.tmp/unique.base.rbxlx", function(program, arguments, executeOptions)
	buildCall = { program = program, arguments = arguments, options = executeOptions }
	buildFiles[arguments[4]] = "exact-built-place"
	return { ok = true, stdout = "" }
end, function(path)
	return buildFiles[path] ~= nil
end, function(path)
	return buildFiles[path]
end)
assert(builtPlace == "exact-built-place" and buildCall.program == "rojo" and buildCall.arguments[1] == "build"
	and buildCall.arguments[2] == "benchmarks/event-v1.project.json" and buildCall.arguments[3] == "--output"
	and buildCall.arguments[4] == "E:/relay/.tmp/unique.base.rbxlx" and buildCall.options.cwd == "E:/relay",
	"per-launch Rojo build command changed")

do
	local verifiedLibrary = nil
	local verifiedGenerated = nil
	local lockValidated = false
	local prepared = Host.prepareExternalProject(
		string.gsub(process.cwd, "\\", "/"),
		"blink",
		"./selected.luau",
		fs.readFile,
		function(value) return serde.decode("json", value) end,
		function(value) return serde.encode("json", value) end,
		{
			validateLock = function(candidate) lockValidated = true; return candidate end,
			verifyInstalled = function(library) verifiedLibrary = library.id end,
		},
		{ verifyGenerated = function(id) verifiedGenerated = id end }
	)
	local project = serde.decode("json", prepared.body)
	assert(lockValidated and verifiedLibrary == "blink" and verifiedGenerated == "blink",
		"external project skipped pinned acquisition or generated-output verification")
	assert(prepared.selected.id == "blink" and project.tree.HttpService["$properties"].HttpEnabled == false,
		"prepared external project changed")
end
expectError("HOST_E_BUILD", function()
	Host.buildPlace("E:/relay", "missing", function() return { ok = true, stdout = "" } end, function() return false end, function() return "" end)
end)
local reservedRojoPath = ".tmp/host-runtime-rojo-" .. string.sub(serde.hash("sha256", tostring(os.clock())), 1, 16) .. ".rbxlx"
fs.writeFile(reservedRojoPath, "", { overwrite = false })
local reservedRojoOk, reservedRojoResult = pcall(function()
	return Host.buildPlace(string.gsub(process.cwd, "\\", "/"), reservedRojoPath, process.exec, fs.isFile, fs.readFile)
end)
local reservedRojoCleanup = pcall(fs.removeFile, reservedRojoPath)
assert(reservedRojoOk and #reservedRojoResult > 0 and reservedRojoCleanup,
	"Rojo did not overwrite the exclusively owned base-place placeholder")
local hostSource = fs.readFile("benchmarks/host/HostRuntime.luau")
do
	local externalStart = assert(string.find(hostSource, "local function runExternal(", 1, true))
	local externalEnd = assert(string.find(hostSource, "local function main(", externalStart, true))
	local childExit = assert(string.find(hostSource, "local childExited = child == nil", externalStart, true))
	local census = assert(string.find(hostSource,
		"local censusOk, censusError = pcall(assertStudioIdle, process.os, process.exec)", childExit, true))
	local retain = assert(string.find(hostSource, "batchCleanupAuthorized = false", census, true))
	local childCleanup = assert(string.find(hostSource, "cleanupNamedPaths(childPaths", census, true))
	assert(childExit < census and census < retain and retain < childCleanup and childCleanup < externalEnd,
		"external child artifacts must be retained until the full Studio census proves idle")
	local build = assert(string.find(hostSource, "local basePlace = buildProject(", externalStart, true))
	local postBuildVerify = assert(string.find(hostSource,
		"verifyExternalArtifacts(preparedProject.selected)", build, true))
	local digest = assert(string.find(hostSource, "local adapter = collectExternalAdapter", postBuildVerify, true))
	local batchCleanup = assert(string.find(hostSource,
		"cleanupNamedPaths(batchPaths, batchNames", digest, true))
	local finalVerify = assert(string.find(hostSource, "verifyExternalArtifacts(result.selected)", batchCleanup, true))
	local publication = assert(string.find(hostSource, "local publication = completeBenchmark", finalVerify, true))
	assert(build < postBuildVerify and postBuildVerify < digest and digest < batchCleanup
		and batchCleanup < finalVerify and finalVerify < publication and publication < externalEnd,
		"ignored external artifacts must be verified around build and again before final publication")
end
do
	local mainStart = assert(string.find(hostSource, "local function main(", 1, true))
	local initialStudioCheck = assert(string.find(hostSource, "assertStudioIdle(process.os, process.exec)", mainStart, true))
	local reservation = assert(string.find(hostSource, "local owned = reserveLaunchPaths", mainStart, true))
	local build = assert(string.find(hostSource, "local basePlace = buildPlace", mainStart, true))
	local finalStudioCheck = assert(string.find(hostSource, "assertStudioIdle(process.os, process.exec)", initialStudioCheck + 1, true))
	local childLaunch = assert(string.find(hostSource, "child = process.create", mainStart, true))
	assert(initialStudioCheck < reservation and reservation < build and build < finalStudioCheck and finalStudioCheck < childLaunch,
		"Studio concurrency checks must precede private reservation/build and immediately precede launch")
end
assert(string.find(hostSource, "/.tmp/event-v1.rbxlx", 1, true) == nil, "host consumed a shared prebuilt place")
assert(string.find(hostSource, 'require("@lune/net")', 1, true) == nil
	and string.find(hostSource, "net.serve", 1, true) == nil,
	"host retained the full-body HTTP ingress")
assert(string.find(hostSource, "local CONTROL_TIMEOUT_SECONDS = 240", 1, true)
	and string.find(hostSource, "local BENCHMARK_TIMEOUT_SECONDS = 7_440", 1, true), "outer timeout margins changed")

local cleanupPaths = { bootstrap = "bootstrap", launchPlace = "launch-place", basePlace = "base-place", output = "output", lock = "lock" }
local cleanupOwned = { bootstrap = true, launchPlace = true, basePlace = true, output = true, lock = true }
local reservedFiles = {}
local reservedOwned = Host.reserveLaunchPaths(cleanupPaths, launchId, function(path)
	return reservedFiles[path] ~= nil
end, function(path, value)
	if reservedFiles[path] ~= nil then error("occupied") end
	reservedFiles[path] = value
end, function(path)
	reservedFiles[path] = nil
end)
assert(reservedOwned.lock and reservedOwned.basePlace and reservedOwned.launchPlace and reservedOwned.bootstrap and reservedOwned.output
	and reservedFiles.lock == launchId and reservedFiles["base-place"] == "" and reservedFiles.output == "",
	"launch paths were not reserved exclusively before tool writes")
local collisionFiles = { ["base-place"] = "other-launch" }
expectError("HOST_E_COLLISION", function()
	Host.reserveLaunchPaths(cleanupPaths, launchId, function(path) return collisionFiles[path] ~= nil end, function(path, value)
		if collisionFiles[path] ~= nil then error("occupied") end
		collisionFiles[path] = value
	end, function(path)
		collisionFiles[path] = nil
	end)
end)
assert(collisionFiles["base-place"] == "other-launch", "launch collision removed an unowned artifact")
local uncertainFiles = {}
expectError("HOST_E_COLLISION", function()
	Host.reserveLaunchPaths(cleanupPaths, launchId, function(path) return uncertainFiles[path] ~= nil end, function(path, value)
		if path == "base-place" then
			uncertainFiles[path] = "uncertain-owner"
			error("ambiguous exclusive creation")
		end
		if uncertainFiles[path] ~= nil then error("occupied") end
		uncertainFiles[path] = value
	end, function(path)
		uncertainFiles[path] = nil
	end)
end)
assert(uncertainFiles["base-place"] == "uncertain-owner" and uncertainFiles.lock == nil,
	"failed exclusive creation deleted an uncertain path or retained an owned lock")
local launchFiles = { bootstrap = true, ["launch-place"] = true, ["base-place"] = true, output = true, lock = true }
assert(Host.cleanupLaunchFiles(cleanupPaths, cleanupOwned, function(path) return launchFiles[path] == true end, function(path)
	launchFiles[path] = nil
end), "owned launch cleanup failed")
assert(next(launchFiles) == nil, "owned launch cleanup changed")

local protectedFiles = { bootstrap = true, ["launch-place"] = true, ["base-place"] = true, output = true, lock = true }
assert(not Host.cleanupProtectedLaunch(false, cleanupPaths, cleanupOwned, function(path)
	return protectedFiles[path] == true
end, function(path)
	protectedFiles[path] = nil
end), "live-child cleanup must be rejected")
assert(protectedFiles.bootstrap and protectedFiles.lock, "live-child cleanup removed owned artifacts")

local partiallyOwned = { bootstrap = true, launchPlace = false, basePlace = false, output = false, lock = true }
assert(Host.cleanupProtectedLaunch(true, cleanupPaths, partiallyOwned, function(path)
	return protectedFiles[path] == true
end, function(path)
	protectedFiles[path] = nil
end), "confirmed-exit cleanup failed")
assert(not protectedFiles.bootstrap and not protectedFiles.lock and protectedFiles["launch-place"],
	"cleanup removed unowned launch artifacts")

local cleanupFailureFiles, cleanupFailureIo = memoryFiles()
local cleanupFailureCollector = Host.prepareCollector(expectedManifest, "benchmarks/results/local", function()
	return string.rep("61", 16)
end, cleanupFailureIo)
local cleanupFailureTerminal = collectBenchmarkTerminal(maximumResultBody, cleanupFailureCollector)
local cleanupFailureOutcome = Host.awaitOutcome(function() return { ok = true } end,
	function() return cleanupFailureTerminal end,
	function() end, os.clock, function() end, 1)
local failedCleanup = Host.cleanupProtectedLaunch(true, cleanupPaths, cleanupOwned, function() return true end, function()
	error("cleanup failed")
end)
assert(cleanupFailureOutcome.kind == "Complete" and not failedCleanup and next(cleanupFailureFiles) == nil,
	"cleanup failure published a final Result")

local killed = false
local exited = false
local now = 0
local timeout = Host.awaitOutcome(
	function() return if exited then { ok = false, code = 9 } else nil end,
	function() return nil end,
	function() killed = true; exited = true end,
	function() return now end,
	function(duration) now += duration end,
	0.1
)
assert(timeout.kind == "Timeout" and killed and not timeout.childExited,
	"forced-kill acknowledgement must not prove Studio exit")

do
	local launched = 0
	local fragments = Host.collectProcessFragments(batchId, function(index)
		return string.format("00000000-0000-4000-8000-%012d", index)
	end, function(childLaunchId, index)
		launched += 1
		return {
			batchId = batchId,
			repetitionIndex = index,
			manifest = { launchId = childLaunchId },
		}
	end)
	assert(launched == 30 and #fragments == 30 and table.isfrozen(fragments),
		"process restart lifecycle did not require exactly 30 sequential launches")
	local stopped = 0
	expectError("fragment failure", function()
		Host.collectProcessFragments(batchId, function(index)
			return string.format("00000000-0000-4000-9000-%012d", index)
		end, function(childLaunchId, index)
			stopped += 1
			if index == 7 then error("fragment failure", 0) end
			return { batchId = batchId, repetitionIndex = index, manifest = { launchId = childLaunchId } }
		end)
	end)
	assert(stopped == 7, "fragment failure did not stop the batch atomically")
	expectError("HOST_E_LAUNCH_ID", function()
		Host.collectProcessFragments(batchId, function() return batchId end, function()
			error("colliding launch must not execute")
		end)
	end)
	expectError("HOST_E_FRAGMENT", function()
		Host.collectProcessFragments(batchId, function(index)
			return string.format("00000000-0000-4000-a000-%012d", index)
		end, function(childLaunchId, index)
			return { batchId = batchId, repetitionIndex = index + 1, manifest = { launchId = childLaunchId } }
		end)
	end)
end

-- Exercise main's actual error cleanup even when awaitOutcome throws after the
-- kill callback has already received Lune's synthetic status.
local mainSource = assert(string.match(hostSource, "local function main%(arguments: { string }%).*"),
	"host main missing")
local mainCleanup = assert(string.match(mainSource,
	"(local childExited = child == nil.-)\n\tif not cleaned then"),
	"main cleanup branch missing")
for _, alreadyKilled in { false, true } do
	local exceptionFiles = { bootstrap = true, ["launch-place"] = true, ["base-place"] = true, output = true, lock = true }
	local environment = {
		child = {},
		status = if alreadyKilled then { ok = false, code = 9 } else nil,
		killRequested = alreadyKilled,
		ok = false,
		paths = cleanupPaths,
		owned = cleanupOwned,
		fs = {
			isFile = function(path) return exceptionFiles[path] == true end,
			removeFile = function(path) exceptionFiles[path] = nil end,
		},
		os = os,
		task = { wait = function() end },
		KILL_CONFIRM_SECONDS = 10,
		cleanupProtectedLaunch = Host.cleanupProtectedLaunch,
		fail = function(code) error(code, 0) end,
	}
	environment.killChild = function()
		environment.status = { ok = false, code = 9 }
	end
	environment.requestChildKill = function()
		environment.killRequested = true
		environment.killChild()
	end
	environment.confirmExit = function(readStatus)
		return readStatus() ~= nil
	end
	local runCleanup = luau.load(mainCleanup, { debugName = "host-main-forced-cleanup", environment = environment })
	expectError("HOST_E_CHILD_LIVE", runCleanup)
	assert(exceptionFiles.bootstrap and exceptionFiles["launch-place"] and exceptionFiles["base-place"]
		and exceptionFiles.output and exceptionFiles.lock, "unproven forced exit deleted launch artifacts")
end
local retainedNow = 0
local retained = Host.awaitOutcome(function() return nil end, function() return nil end, function() end,
	function() return retainedNow end, function(duration) retainedNow += duration end, 0.1, 0.1)
assert(retained.kind == "Timeout" and not retained.childExited, "unconfirmed child exit must retain launch artifacts")
local failed = Host.awaitOutcome(function() return { ok = false } end, function() return nil end, function() end, os.clock, function() end, 1)
assert(failed.kind == "ProcessFailure" and failed.childExited, "failed Studio process accepted")
local naturalCodeNine = Host.awaitOutcome(function() return { ok = false, code = 9 } end, function() return nil end,
	function() error("natural exit must not be killed") end, os.clock, function() end, 1)
assert(naturalCodeNine.kind == "ProcessFailure" and naturalCodeNine.childExited,
	"natural exit code 9 was confused with a forced-kill acknowledgement")
local acceptedTerminal = table.freeze({ kind = "ControlProof" })
local complete = Host.awaitOutcome(function() return { ok = true } end, function() return acceptedTerminal end, function() end, os.clock, function() end, 1)
assert(complete.kind == "Complete" and complete.terminal == acceptedTerminal and table.isfrozen(complete),
	"accepted clean Studio process rejected")

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
