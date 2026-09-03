local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Acquisition = require("../../scripts/acquire-benchmark-libraries")
local GeneratedAdapters = require("../host/GeneratedAdapters")
local GenerationTesting = GeneratedAdapters._testing

local function expectError(callback)
	local ok = pcall(callback)
	assert(not ok, "expected generation verification failure")
end

local lock = serde.decode("json", fs.readFile("benchmarks/libraries.lock.json"))
assert(Acquisition.validateLock(lock) == lock, "lock validation did not preserve the canonical value")

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
