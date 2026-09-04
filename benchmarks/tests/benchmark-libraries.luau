local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Acquisition = require("../../scripts/acquire-benchmark-libraries")
local GeneratedAdapters = require("../host/GeneratedAdapters")
local GenerationTesting = GeneratedAdapters._testing

local function expectError(callback)
	local ok = pcall(callback)
	assert(not ok, "expected generation verification failure")
end

local function captureError(callback)
	local ok, failure = pcall(callback)
	assert(not ok, "expected operation to fail")
	return tostring(failure)
end

local lock = serde.decode("json", fs.readFile("benchmarks/libraries.lock.json"))
assert(Acquisition.validateLock(lock) == lock, "lock validation did not preserve the canonical value")
assert(lock.libraries[5].id == "suphi-packet"
	and lock.libraries[5].license == "LicenseRef-Suphi-Packet-Grant",
	"Suphi-Packet custom license reference changed")
local suphiGrant = fs.readFile("benchmarks/licenses/LicenseRef-Suphi-Packet-Grant.txt")
assert(string.find(suphiGrant, "https://devforum.roblox.com/t/packet-networking-library/3573907", 1, true),
	"Suphi-Packet grant source is missing")
assert(string.find(suphiGrant,
	"Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted.",
	1, true), "Suphi-Packet grant text changed")
local acquisitionSource = fs.readFile("scripts/acquire-benchmark-libraries.luau")
assert(string.find(acquisitionSource, 'require("@lune/net")', 1, true) == nil
	and string.find(acquisitionSource, "net.request", 1, true) == nil,
	"acquisition retained the full-body HTTP client")

local expectedAssetBytes = {
	zap = 1036611,
	blink = 5367339,
	["netray-compile"] = 5342234,
}
for _, library in ipairs(lock.libraries) do
	if library.kind == "CodegenTool" then
		assert(expectedAssetBytes[library.id] == library.assetBytes, `unexpected asset byte pin for {library.id}`)
		expectedAssetBytes[library.id] = nil
	end
end
assert(next(expectedAssetBytes) == nil, "a codegen asset byte pin is missing")

for _, invalidBytes in { 0, 1.5, 8 * 1024 * 1024 + 1 } do
	local invalid = serde.decode("json", serde.encode("json", lock))
	invalid.libraries[6].assetBytes = invalidBytes
	expectError(function()
		Acquisition.validateLock(invalid)
	end)
end

local function fakeReader(chunks)
	local index = 0
	local reads = {}
	return {
		reads = reads,
		read = function(_, maximum)
			table.insert(reads, maximum)
			index += 1
			return chunks[index]
		end,
	}
end

local function fakeChild(stdoutChunks, stderrChunks, status)
	local state = {
		killed = false,
		stdinClosed = false,
		statusCalls = 0,
	}
	local child = {
		stdout = fakeReader(stdoutChunks),
		stderr = fakeReader(stderrChunks),
		stdin = {
			close = function()
				state.stdinClosed = true
			end,
		},
	}
	function child:kill()
		state.killed = true
	end
	function child:status()
		state.statusCalls += 1
		return status
	end
	return child, state
end

local function fakeLibrary(bytes)
	return {
		id = "fixture",
		assetBytes = bytes,
		assetUrl = "https://github.com/example/project/releases/download/v1/fixture.zip",
	}
end

do
	local library = fakeLibrary(6)
	local child, state = fakeChild({ "ab", "cdef" }, {}, { ok = true, code = 0 })
	local invocation = nil
	local body = Acquisition._testing.downloadAsset(library, function(program, arguments, options)
		invocation = { program = program, arguments = arguments, options = options }
		return child
	end)
	assert(body == "abcdef", "exact-length curl output was not preserved")
	assert(not state.killed and state.stdinClosed and state.statusCalls == 1, "successful curl lifecycle changed")
	assert(child.stdout.reads[#child.stdout.reads] == 1, "exact-length download did not probe for an extra byte")
	assert(invocation.program == "curl" and invocation.options.cwd ~= nil, "curl process invocation changed")
	local expectedArguments = {
		"--disable",
		"--silent",
		"--show-error",
		"--fail",
		"--location",
		"--proto",
		"=https",
		"--proto-redir",
		"=https",
		"--max-redirs",
		"3",
		"--globoff",
		"--header",
		"Accept-Encoding: identity",
		"--max-time",
		"600",
		"--max-filesize",
		"6",
		"--output",
		"-",
		library.assetUrl,
	}
	assert(#invocation.arguments == #expectedArguments, "curl argument count changed")
	for index, argument in ipairs(expectedArguments) do
		assert(invocation.arguments[index] == argument, `curl argument {index} changed`)
	end
end

do
	local child, state = fakeChild({ "ab", "cde", "f" }, {}, { ok = true, code = 0 })
	local failure = captureError(function()
		Acquisition._testing.downloadAsset(fakeLibrary(5), function()
			return child
		end)
	end)
	assert(string.find(failure, "exceeded pinned size", 1, true) ~= nil, "limit+1 failure was not diagnosed")
	assert(state.killed and state.statusCalls == 1, "limit+1 download did not request a kill and consume status")
	assert(child.stdout.reads[#child.stdout.reads - 1] == 1, "limit+1 check did not narrow the final retained read")
end

do
	local child, state = fakeChild({ "short" }, {}, { ok = true, code = 0 })
	local failure = captureError(function()
		Acquisition._testing.downloadAsset(fakeLibrary(6), function()
			return child
		end)
	end)
	assert(string.find(failure, "download size mismatch", 1, true) ~= nil, "short download was not rejected")
	assert(not state.killed and state.statusCalls == 1, "short download lifecycle changed")
end

do
	local child, state = fakeChild({ "abc" }, { string.rep("x", 5000), "SECRET_TAIL" }, { ok = false, code = 22 })
	local failure = captureError(function()
		Acquisition._testing.downloadAsset(fakeLibrary(3), function()
			return child
		end)
	end)
	assert(string.find(failure, "curl exit code 22", 1, true) ~= nil, "curl failure status was hidden")
	assert(string.find(failure, "SECRET_TAIL", 1, true) == nil, "stderr retention exceeded its cap")
	assert(#failure < 4600 and #child.stderr.reads == 3, "stderr was not incrementally drained with bounded retention")
	assert(not state.killed and state.statusCalls == 1, "failed curl lifecycle changed")
end

do
	local child, state = fakeChild({ "" }, {}, { ok = true, code = 0 })
	local failure = captureError(function()
		Acquisition._testing.downloadAsset(fakeLibrary(1), function()
			return child
		end)
	end)
	assert(string.find(failure, "invalid chunk", 1, true) ~= nil, "malformed reader output was not rejected")
	assert(state.killed and state.statusCalls == 1, "malformed reader output did not request a kill and consume status")
end

local expected = {
	quicknet = "a2b95ff624acccd935109468b7f84d51089b54e3",
	satset = "4c30f8ae689e8b286b6526a4186d26f896b8d908",
	warp = "0b1304f4c578943e23ed1919e35f0bdc536b3f6a",
	bytenet = "d8262827b573efad10593c7d1dae451a78fe98b5",
	["suphi-packet"] = "ec86397bd6a67a002b868ae8f5a72d62eeb38c4a",
	zap = "8cd17ab78192217600eec6f688ed8f8aab18d707",
	blink = "73695d11a113ba632cef12b6b2c6fe821827855e",
	["netray-compile"] = "20ff4d6a2ca05c3cdbc05f7765182cd8c2df5c89",
}

local runtimeCount = 0
local toolCount = 0
for _, library in ipairs(lock.libraries) do
	assert(expected[library.id] == library.revision, `unexpected pin for {library.id}`)
	expected[library.id] = nil
	if library.kind == "RuntimeSource" then
		runtimeCount += 1
	else
		toolCount += 1
	end
end
assert(next(expected) == nil, "a pinned external candidate is missing")
assert(runtimeCount == 5 and toolCount == 3, "runtime/tool candidate partition changed")

for _, path in ipairs({
	"src/init.luau",
	"Packet/Types/Static1.lua",
	"blink-windows-x86_64.tar.gz",
}) do
	assert(Acquisition.isSafeRelativePath(path), `safe path rejected: {path}`)
end
for _, path in ipairs({
	"",
	"../src/init.luau",
	"src\\init.luau",
	"C:/src/init.luau",
	"/src/init.luau",
	"src//init.luau",
	"src/",
	"src/CON.luau",
	"src/file:stream",
	"src/file?.luau",
	"src/caf\195\169.luau",
	"src/trailing. ",
}) do
	assert(not Acquisition.isSafeRelativePath(path), `unsafe path accepted: {path}`)
end

local entries = {
	{ path = "b.luau", bytes = "two\r\n" },
	{ path = "a.luau", bytes = "one\n" },
}
local framing = "a.luau\0" .. tostring(#entries[2].bytes) .. "\0" .. entries[2].bytes .. "\0"
	.. "b.luau\0" .. tostring(#entries[1].bytes) .. "\0" .. entries[1].bytes .. "\0"
assert(Acquisition.canonicalChecksum(entries) == serde.hash("sha256", framing), "canonical artifact framing changed")
assert(
	Acquisition.canonicalChecksum(entries)
		~= Acquisition.canonicalChecksum({
			{ path = "a.luau", bytes = "one\r\n" },
			{ path = "b.luau", bytes = "two\r\n" },
		}),
	"artifact checksum normalized line endings"
)

local inventoryDirectory = `.tmp/generated-adapter-inventory-{string.sub(serde.hash("sha256", tostring(os.clock())), 1, 16)}`
assert(not fs.isDir(inventoryDirectory) and not fs.isFile(inventoryDirectory), "generation inventory fixture collided")
fs.writeDir(inventoryDirectory)
local inventoryOk, inventoryError = pcall(function()
	local first = {}
	for _, filename in { "Server.luau", "Client.luau", "Types.luau" } do
		local bytes = `exact {filename}`
		fs.writeFile(`{inventoryDirectory}/{filename}`, bytes)
		first[filename] = serde.hash("sha256", bytes)
	end
	local checked = GenerationTesting.outputHashes("fixture", inventoryDirectory, false)
	GenerationTesting.assertSameOutputs("fixture", first, checked)
	local changed = table.clone(checked)
	changed["Client.luau"] = string.rep("0", 64)
	expectError(function() GenerationTesting.assertSameOutputs("fixture", first, changed) end)
	fs.writeFile(`{inventoryDirectory}/unexpected.luau`, "return true")
	expectError(function() GenerationTesting.outputHashes("fixture", inventoryDirectory, false) end)
	fs.removeFile(`{inventoryDirectory}/unexpected.luau`)
	fs.writeDir(`{inventoryDirectory}/Server`)
	expectError(function() GenerationTesting.outputHashes("fixture", inventoryDirectory, false) end)
	fs.removeDir(`{inventoryDirectory}/Server`)
	fs.writeFile(`{inventoryDirectory}/.relay-generated.json`, "{}")
	GenerationTesting.outputHashes("fixture", inventoryDirectory, true)
	expectError(function() GenerationTesting.outputHashes("fixture", inventoryDirectory, false) end)
end)
local inventoryCleaned = pcall(fs.removeDir, inventoryDirectory)
assert(inventoryOk, inventoryError)
assert(inventoryCleaned and not fs.isDir(inventoryDirectory), "generation inventory fixture cleanup failed")

local function memoryDirectories(initial, failures)
	local directories = table.clone(initial)
	local io = {
		isDir = function(path) return directories[path] ~= nil end,
		isFile = function() return false end,
		move = function(from, to)
			if failures.move == `{from}->{to}` then error("move failed") end
			if directories[from] == nil or directories[to] ~= nil then error("move rejected") end
			directories[to] = directories[from]
			directories[from] = nil
		end,
		removeDir = function(path)
			if failures.remove == path then error("remove failed") end
			if directories[path] == nil then error("remove rejected") end
			directories[path] = nil
		end,
	}
	return directories, io
end

do
	local directories, io = memoryDirectories({ staged = "new", output = "old" }, {})
	local warning = GenerationTesting.publishOutput("staged", "output", "previous", function()
		assert(directories.output == "new", "verification did not observe the published output")
	end, io)
	assert(warning == nil and directories.output == "new" and directories.previous == nil,
		"successful publication did not retire the previous output")
end

do
	local directories, io = memoryDirectories({ staged = "new", output = "old" }, {})
	local ok, message = pcall(GenerationTesting.publishOutput, "staged", "output", "previous", function()
		error("verification failed")
	end, io)
	assert(not ok and string.find(message, "verification failed", 1, true) ~= nil,
		"publication verification failure was hidden")
	assert(directories.output == "old" and directories.previous == nil,
		"publication verification failure did not restore the previous output")
end

do
	local directories, io = memoryDirectories({ staged = "new", output = "old" }, { remove = "output" })
	local ok, message = pcall(GenerationTesting.publishOutput, "staged", "output", "previous", function()
		error("verification failed")
	end, io)
	assert(not ok and string.find(message, "rollback failed", 1, true) ~= nil
		and string.find(message, "previous", 1, true) ~= nil, "rollback failure was not surfaced with its backup path")
	assert(directories.output == "new" and directories.previous == "old",
		"failed rollback deleted the only previous output")
end

do
	local directories, io = memoryDirectories({ staged = "new" }, { remove = "output" })
	local ok, message = pcall(GenerationTesting.publishOutput, "staged", "output", "previous", function()
		error("verification failed")
	end, io)
	assert(not ok and string.find(message, "no previous output existed", 1, true) ~= nil,
		"rollback failure invented a previous output")
	assert(directories.output == "new" and directories.previous == nil,
		"failed rollback without a previous output changed ownership")
end

do
	local directories, io = memoryDirectories({ staged = "new", output = "old" }, { move = "previous->output" })
	local ok, message = pcall(GenerationTesting.publishOutput, "staged", "output", "previous", function()
		error("verification failed")
	end, io)
	assert(not ok and string.find(message, "previous output restore failed", 1, true) ~= nil,
		"restore failure was not surfaced")
	assert(directories.output == nil and directories.previous == "old",
		"restore failure did not retain the only previous output")
end

do
	local directories, io = memoryDirectories({ staged = "new", output = "old" }, { remove = "previous" })
	local warning = GenerationTesting.publishOutput("staged", "output", "previous", function() end, io)
	assert(type(warning) == "string" and string.find(warning, "previous", 1, true) ~= nil,
		"successful backup cleanup failure was not diagnosed")
	assert(directories.output == "new" and directories.previous == "old",
		"backup cleanup failure damaged the verified publication")
end

assert(
	Acquisition.resolveTagRevision(
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0\n",
		"v1.0.0"
	) == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	"lightweight tag resolution changed"
)
assert(
	Acquisition.resolveTagRevision(
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0\n"
			.. "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v1.0.0^{}\n",
		"v1.0.0"
	) == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
	"annotated tag resolution did not use the peeled commit"
)

local project = serde.decode("json", fs.readFile("benchmarks/external-runtime-libraries.project.json"))
local libraries = project.tree.ReplicatedStorage.RelayBenchmarkExternal.Libraries
local expectedLibraryKeys = {
	["$className"] = true,
	QuickNet = true,
	Satset = true,
	Warp = true,
	ByteNet = true,
	SuphiPacket = true,
}
for key in pairs(libraries) do
	assert(expectedLibraryKeys[key], `unexpected runtime library mapping: {key}`)
	expectedLibraryKeys[key] = nil
end
assert(next(expectedLibraryKeys) == nil, "a runtime library mapping is missing")
assert(libraries.QuickNet["$path"] == "vendor/quicknet/src/QuickNet.luau", "QuickNet entry mapping changed")
assert(libraries.Satset["$path"] == "vendor/satset/src", "Satset mapping changed")
assert(libraries.Warp["$path"] == "vendor/warp/src", "Warp mapping changed")
assert(libraries.ByteNet["$path"] == "vendor/bytenet/src", "ByteNet mapping changed")
assert(libraries.SuphiPacket["$path"] == "vendor/suphi-packet/Packet", "Suphi-Packet mapping changed")

local nativeProjectSource = fs.readFile("benchmarks/event-v1.project.json")
assert(not string.find(nativeProjectSource, "benchmarks/vendor", 1, true), "native benchmark project depends on vendor acquisition")
assert(not string.find(nativeProjectSource, "vendor/", 1, true), "native benchmark project maps an external vendor")

print("PASS benchmark external library lock and placement")
