local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local ROOT = string.gsub(process.cwd, "\\", "/")
local MANIFEST_NAME = ".relay-generated.json"
local OUTPUTS = { "Server.luau", "Client.luau", "Types.luau" }
local GENERATORS = {
	blink = { schema = "benchmarks/adapters/blink/event-v1.blink" },
	zap = { schema = "benchmarks/adapters/zap/event-v1.zap" },
	["netray-compile"] = { schema = "benchmarks/adapters/netray-compile/event-v1.idl" },
}
local verifiedLock = nil

local function run(executable, arguments)
	local result = process.exec(executable, arguments, { cwd = ROOT })
	assert(result.ok, `generation command failed ({result.code})\n{result.stdout}\n{result.stderr}`)
end

local function getLibrary(id)
	assert(GENERATORS[id] ~= nil, `unknown generated adapter {tostring(id)}`)
	if verifiedLock == nil then
		-- A subprocess avoids the acquisition CLI interpreting this module's flags.
		run("lune", { "run", "scripts/acquire-benchmark-libraries.luau", "--verify" })
		verifiedLock = serde.decode("json", fs.readFile("benchmarks/libraries.lock.json"))
	end
	for _, library in ipairs(verifiedLock.libraries) do
		if library.id == id then return library end
	end
	error(`missing compiler pin for {id}`)
end

local function outputHashes(id, directory, includeManifest)
	local expected = {}
	for _, filename in ipairs(OUTPUTS) do expected[filename] = true end
	if includeManifest then expected[MANIFEST_NAME] = true end
	assert(fs.isDir(directory), `missing generated output directory for {id}`)
	for _, filename in ipairs(fs.readDir(directory)) do
		assert(expected[filename] == true and fs.isFile(`{directory}/{filename}`),
			`unexpected generated output for {id}: {filename}`)
		expected[filename] = nil
	end
	for filename in pairs(expected) do
		error(`{id} did not produce {filename}`)
	end

	local hashes = {}
	for _, filename in ipairs(OUTPUTS) do
		local path = `{directory}/{filename}`
		local bytes = fs.readFile(path)
		assert(#bytes > 0, `{id} produced an empty {filename}`)
		hashes[filename] = serde.hash("sha256", bytes)
	end
	return hashes
end

local function assertSameOutputs(id, first, second)
	for _, filename in ipairs(OUTPUTS) do
		assert(second[filename] == first[filename], `{id} generation is not deterministic: {filename}`)
	end
end

local DEFAULT_FILE_IO = table.freeze({
	isDir = fs.isDir,
	isFile = fs.isFile,
	move = fs.move,
	removeDir = fs.removeDir,
})

local function publishOutput(staged, output, previous, verify, fileIo)
	local io = fileIo or DEFAULT_FILE_IO
	assert(not io.isFile(output), "generated output path is not a directory")
	assert(not io.isDir(previous) and not io.isFile(previous), "generation backup path already exists")
	local previousMoved = false
	local published = false
	local ok, result = pcall(function()
		if io.isDir(output) then
			io.move(output, previous)
			previousMoved = true
		end
		io.move(staged, output)
		published = true
		verify()
	end)
	if ok then
		if previousMoved then
			local cleaned, cleanupError = pcall(io.removeDir, previous)
			if not cleaned then
				return `verified output published; previous output retained at {previous}: {tostring(cleanupError)}`
			end
		end
		return nil
	end

	local rollbackErrors = {}
	if published and io.isDir(output) then
		local removed, removeError = pcall(io.removeDir, output)
		if not removed then table.insert(rollbackErrors, `new output removal failed: {tostring(removeError)}`) end
	end
	if previousMoved then
		if io.isDir(output) or io.isFile(output) then
			table.insert(rollbackErrors, "output path remained occupied")
		else
			local restored, restoreError = pcall(io.move, previous, output)
			if not restored then table.insert(rollbackErrors, `previous output restore failed: {tostring(restoreError)}`) end
		end
	end
	if #rollbackErrors > 0 then
		local retained = if previousMoved then `previous output retained at {previous}` else "no previous output existed"
		error(`{tostring(result)}\nrollback failed; {retained}: {table.concat(rollbackErrors, "; ")}`, 0)
	end
	error(result, 0)
end

local function reserveTransaction(id)
	for attempt = 1, 8 do
		local token = string.sub(serde.hash("sha256", `{os.clock()}:{tostring({})}:{attempt}`), 1, 16)
		local staging = `benchmarks/generated/.staging-{id}-{token}`
		local previous = `benchmarks/generated/.previous-{id}-{token}`
		if not fs.isDir(staging) and not fs.isFile(staging)
			and not fs.isDir(previous) and not fs.isFile(previous)
			and pcall(fs.writeDir, staging)
		then
			return staging, previous
		end
	end
	error(`could not reserve generation transaction for {id}`)
end

local function verifyGenerated(id)
	local library = getLibrary(id)
	local manifestPath = `benchmarks/generated/{id}/{MANIFEST_NAME}`
	assert(fs.isFile(manifestPath), `missing generation proof for {id}; regenerate the adapter`)
	local manifest = serde.decode("json", fs.readFile(manifestPath))
	assert(manifest.version == 1 and manifest.id == id, `invalid generation proof for {id}`)
	assert(manifest.compilerArtifactSha256 == library.artifactSha256 and manifest.compilerRevision == library.revision,
		`compiler pin changed for {id}; regenerate the adapter`)
	assert(manifest.schemaSha256 == serde.hash("sha256", fs.readFile(GENERATORS[id].schema)),
		`schema changed for {id}; regenerate the adapter`)
	local hashes = outputHashes(id, `benchmarks/generated/{id}`, true)
	for _, filename in ipairs(OUTPUTS) do
		assert(manifest.outputSha256[filename] == hashes[filename], `generated output changed for {id}/{filename}`)
	end
	return manifest
end

local function generate(id)
	local library = getLibrary(id)
	local generator = GENERATORS[id]
	local outputDirectory = `benchmarks/generated/{id}`
	local staging, previous = reserveTransaction(id)
	local executable = `{ROOT}/benchmarks/vendor/{id}/{library.executablePath}`
	local ok, result = pcall(function()
		local hashes = {}
		local outputs = {}
		local schemaName = string.match(generator.schema, "[^/]+$")
		local schemaBytes = fs.readFile(generator.schema)
		for pass = 1, 2 do
			local workspace = `{staging}/pass-{pass}`
			local schemaDirectory = `{workspace}/benchmarks/adapters/{id}`
			local stagedSchema = `{schemaDirectory}/{schemaName}`
			local passOutput = `{workspace}/benchmarks/generated/{id}`
			fs.writeDir(workspace)
			fs.writeDir(schemaDirectory)
			fs.writeDir(passOutput)
			fs.writeFile(stagedSchema, schemaBytes)
			-- Blink 0.18.8 resolves TypesOutput incorrectly with an absolute schema path.
			local arguments = if id == "blink" then { stagedSchema, "--yes" }
				elseif id == "netray-compile" then { "compile", stagedSchema, "--out-dir", passOutput }
				else { stagedSchema }
			run(executable, arguments)
			outputs[pass] = passOutput
			hashes[pass] = outputHashes(id, passOutput, false)
			-- Cross the timestamp precision boundary before checking reproducibility.
			if pass == 1 then task.wait(1.1) end
		end
		assertSameOutputs(id, hashes[1], hashes[2])
		fs.writeFile(`{outputs[2]}/{MANIFEST_NAME}`, serde.encode("json", {
			version = 1,
			id = id,
			compilerRevision = library.revision,
			compilerArtifactSha256 = library.artifactSha256,
			schemaSha256 = serde.hash("sha256", schemaBytes),
			outputSha256 = hashes[2],
		}) .. "\n")
		outputHashes(id, outputs[2], true)
		return publishOutput(outputs[2], outputDirectory, previous, function()
			verifyGenerated(id)
		end)
	end)
	if not ok then
		local cleaned, cleanupError = pcall(fs.removeDir, staging)
		if not cleaned then
			error(`{tostring(result)}\ngeneration transaction retained at {staging}: {tostring(cleanupError)}`, 0)
		end
		error(result, 0)
	end
	local cleaned, cleanupError = pcall(fs.removeDir, staging)
	if result ~= nil then print(`WARNING {result}`) end
	if not cleaned then print(`WARNING verified generation staging retained at {staging}: {tostring(cleanupError)}`) end
	print(`GENERATED {id}: pinned compiler verified; two identical generations`)
end

local function main(arguments)
	local flag = arguments[1]
	assert((#arguments == 1 and (flag == "--all" or flag == "--verify"))
		or (#arguments == 2 and flag == "--library" and GENERATORS[arguments[2]] ~= nil),
		"usage: lune run scripts/generate-benchmark-adapters.luau --all|--verify|--library <id>")
	if flag == "--library" then generate(arguments[2]) return end
	for _, id in ipairs({ "blink", "zap", "netray-compile" }) do
		if flag == "--verify" then
			verifyGenerated(id)
			print(`VERIFIED generated {id}`)
		else generate(id) end
	end
end

return table.freeze({
	verifyGenerated = verifyGenerated,
	main = main,
	_testing = table.freeze({
		outputHashes = outputHashes,
		assertSameOutputs = assertSameOutputs,
		publishOutput = publishOutput,
	}),
})
