local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = string.gsub(process.cwd, "\\", "/")
local LOCK_PATH = "benchmarks/libraries.lock.json"
local VENDOR_ROOT = "benchmarks/vendor"
local MARKER_NAME = ".relay-benchmark-library.json"
local TEMP_ROOT = ".tmp/benchmark-library-acquisition"

local RUNTIME_KEYS = {
	id = true,
	name = true,
	kind = true,
	repository = true,
	tag = true,
	revision = true,
	license = true,
	artifactSha256 = true,
	sourcePaths = true,
	modulePath = true,
}

local TOOL_KEYS = {
	id = true,
	name = true,
	kind = true,
	repository = true,
	tag = true,
	revision = true,
	license = true,
	artifactSha256 = true,
	assetUrl = true,
	assetSha256 = true,
	archiveName = true,
	executablePath = true,
}

local WINDOWS_RESERVED = {
	CON = true,
	PRN = true,
	AUX = true,
	NUL = true,
	COM1 = true,
	COM2 = true,
	COM3 = true,
	COM4 = true,
	COM5 = true,
	COM6 = true,
	COM7 = true,
	COM8 = true,
	COM9 = true,
	LPT1 = true,
	LPT2 = true,
	LPT3 = true,
	LPT4 = true,
	LPT5 = true,
	LPT6 = true,
	LPT7 = true,
	LPT8 = true,
	LPT9 = true,
}

local function pathJoin(...)
	return table.concat({ ... }, "/")
end

local function absolute(path)
	return pathJoin(ROOT, path)
end

local function assertExactKeys(value, expected, label)
	assert(type(value) == "table", `{label} must be a table`)

	local count = 0
	for key in pairs(value) do
		assert(expected[key] == true, `{label} has unknown key {tostring(key)}`)
		count += 1
	end

	local expectedCount = 0
	for key in pairs(expected) do
		expectedCount += 1
		assert(value[key] ~= nil, `{label} is missing {key}`)
	end

	assert(count == expectedCount, `{label} key count changed`)
end

local function isSafeRelativePath(path)
	if type(path) ~= "string" or #path == 0 or #path > 240 then
		return false
	end
	if string.find(path, "\\", 1, true) or string.sub(path, 1, 1) == "/" or string.sub(path, -1) == "/" or string.match(path, "^%a:") then
		return false
	end
	if string.find(path, "//", 1, true) or string.find(path, "[<>:%\"|%?%*]") then
		return false
	end
	for index = 1, #path do
		local byte = string.byte(path, index)
		if byte < 32 or byte > 126 then
			return false
		end
	end

	for segment in string.gmatch(path, "[^/]+") do
		if segment == "." or segment == ".." or string.match(segment, "[%. ]$") then
			return false
		end
		local stem = string.upper(string.match(segment, "^[^%.]+") or segment)
		if WINDOWS_RESERVED[stem] then
			return false
		end
	end

	return true
end

local function assertString(value, label, maximum)
	assert(type(value) == "string" and #value > 0 and #value <= maximum, `{label} must be a bounded string`)
end

local function validateLock(lock)
	assertExactKeys(lock, { version = true, libraries = true }, "library lock")
	assert(lock.version == 1, "library lock version must be 1")
	assert(type(lock.libraries) == "table" and #lock.libraries == 8, "library lock must contain eight candidates")

	local seen = {}
	for index, library in ipairs(lock.libraries) do
		local label = `library {index}`
		local expectedKeys = if library.kind == "RuntimeSource" then RUNTIME_KEYS else TOOL_KEYS
		assertExactKeys(library, expectedKeys, label)
		assertString(library.id, `{label}.id`, 64)
		assert(string.match(library.id, "^[a-z0-9][a-z0-9%-]*$") ~= nil, `{label}.id is not canonical`)
		assert(not seen[library.id], `duplicate library id {library.id}`)
		seen[library.id] = true
		assertString(library.name, `{label}.name`, 64)
		assert(library.kind == "RuntimeSource" or library.kind == "CodegenTool", `{label}.kind is invalid`)
		assertString(library.repository, `{label}.repository`, 200)
		assert(string.match(library.repository, "^https://github%.com/[A-Za-z0-9_.%-]+/[A-Za-z0-9_.%-]+$") ~= nil, `{label}.repository must be a GitHub HTTPS URL`)
		assertString(library.tag, `{label}.tag`, 64)
		assert(string.match(library.tag, "^[A-Za-z0-9][A-Za-z0-9%.%_%-]*$") ~= nil, `{label}.tag is not canonical`)
		assert(type(library.revision) == "string" and string.match(library.revision, "^[0-9a-f]+$") and #library.revision == 40, `{label}.revision must be lowercase SHA-1`)
		assertString(library.license, `{label}.license`, 32)
		assert(type(library.artifactSha256) == "string" and #library.artifactSha256 == 64 and string.match(library.artifactSha256, "^[0-9a-f]+$"), `{label}.artifactSha256 must be lowercase SHA-256`)

		if library.kind == "RuntimeSource" then
			assert(type(library.sourcePaths) == "table" and #library.sourcePaths > 0 and #library.sourcePaths <= 8, `{label}.sourcePaths is invalid`)
			local paths = {}
			for _, path in ipairs(library.sourcePaths) do
				assert(isSafeRelativePath(path), `{label}.sourcePaths contains unsafe path`)
				local folded = string.lower(path)
				assert(not paths[folded], `{label}.sourcePaths has a duplicate`)
				paths[folded] = true
			end
			assert(isSafeRelativePath(library.modulePath), `{label}.modulePath is unsafe`)
		else
			assertString(library.assetUrl, `{label}.assetUrl`, 300)
			assert(string.match(library.assetUrl, "^https://github%.com/") ~= nil, `{label}.assetUrl must be GitHub HTTPS`)
			assert(type(library.assetSha256) == "string" and #library.assetSha256 == 64 and string.match(library.assetSha256, "^[0-9a-f]+$"), `{label}.assetSha256 must be lowercase SHA-256`)
			assert(isSafeRelativePath(library.archiveName) and not string.find(library.archiveName, "/", 1, true), `{label}.archiveName is unsafe`)
			assert(isSafeRelativePath(library.executablePath), `{label}.executablePath is unsafe`)
		end
	end

	return lock
end

local function loadLock()
	return validateLock(serde.decode("json", fs.readFile(LOCK_PATH)))
end

local function canonicalChecksum(entries)
	local ordered = table.clone(entries)
	table.sort(ordered, function(left, right)
		return left.path < right.path
	end)

	local framed = {}
	local seen = {}
	for _, entry in ipairs(ordered) do
		assert(isSafeRelativePath(entry.path), "checksum entry path is unsafe")
		assert(type(entry.bytes) == "string", "checksum entry bytes must be a string")
		local folded = string.lower(entry.path)
		assert(not seen[folded], "checksum entry path is duplicated")
		seen[folded] = true
		table.insert(framed, entry.path)
		table.insert(framed, "\0")
		table.insert(framed, tostring(#entry.bytes))
		table.insert(framed, "\0")
		table.insert(framed, entry.bytes)
		table.insert(framed, "\0")
	end

	assert(#ordered > 0, "artifact set must not be empty")
	return serde.hash("sha256", table.concat(framed))
end

local function collectFiles(root, relative, entries)
	local directory = if relative == "" then root else pathJoin(root, relative)
	for _, name in ipairs(fs.readDir(directory)) do
		local childRelative = if relative == "" then name else pathJoin(relative, name)
		local child = pathJoin(root, childRelative)
		if fs.isDir(child) then
			collectFiles(root, childRelative, entries)
		elseif fs.isFile(child) then
			if childRelative ~= MARKER_NAME then
				assert(isSafeRelativePath(childRelative), `installed artifact has unsafe path {childRelative}`)
				table.insert(entries, { path = childRelative, bytes = fs.readFile(child) })
			end
		else
			error(`installed artifact is not a regular file: {childRelative}`)
		end
	end
end

local function directoryChecksum(root)
	local entries = {}
	collectFiles(root, "", entries)
	return canonicalChecksum(entries)
end

local function run(program, arguments, cwd)
	local result = process.exec(program, arguments, {
		cwd = cwd or ROOT,
		stdio = "default",
	})
	assert(result.ok, `{program} failed with exit code {result.code}\n{result.stdout}\n{result.stderr}`)
	return result.stdout
end

local function ensureDir(path)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

local function markerFor(library, checksum)
	return {
		version = 1,
		id = library.id,
		kind = library.kind,
		repository = library.repository,
		tag = library.tag,
		revision = library.revision,
		artifactSha256 = `sha256:{checksum}`,
	}
end

local function verifyInstalled(library)
	local destination = pathJoin(VENDOR_ROOT, library.id)
	assert(fs.isDir(destination), `missing installed library {library.id}`)
	local markerPath = pathJoin(destination, MARKER_NAME)
	assert(fs.isFile(markerPath), `missing installation marker for {library.id}`)
	local marker = serde.decode("json", fs.readFile(markerPath))
	assertExactKeys(marker, {
		version = true,
		id = true,
		kind = true,
		repository = true,
		tag = true,
		revision = true,
		artifactSha256 = true,
	}, `marker for {library.id}`)
	assert(marker.version == 1, `marker version changed for {library.id}`)
	for _, key in ipairs({ "id", "kind", "repository", "tag", "revision" }) do
		assert(marker[key] == library[key], `marker {key} mismatch for {library.id}`)
	end
	local checksum = directoryChecksum(destination)
	assert(checksum == library.artifactSha256, `tracked artifact checksum mismatch for {library.id}`)
	assert(marker.artifactSha256 == `sha256:{checksum}`, `artifact checksum mismatch for {library.id}`)
	if library.kind == "RuntimeSource" then
		assert(fs.isFile(pathJoin(destination, library.modulePath)), `entry module missing for {library.id}`)
	else
		assert(fs.isFile(pathJoin(destination, library.archiveName)), `release archive missing for {library.id}`)
		assert(serde.hash("sha256", fs.readFile(pathJoin(destination, library.archiveName))) == library.assetSha256, `release archive checksum mismatch for {library.id}`)
		assert(fs.isFile(pathJoin(destination, library.executablePath)), `compiler executable missing for {library.id}`)
	end
	return marker
end

local function validateGitTree(raw, library)
	local count = 0
	local seen = {}
	local entries = {}
	for record in string.gmatch(raw, "([^%z]+)%z") do
		local mode, kind, hash, path = string.match(record, "^(%d+) ([^ ]+) ([0-9a-f]+)\t(.+)$")
		assert(mode == "100644" or mode == "100755", `non-regular Git entry for {library.id}`)
		assert(kind == "blob", `non-blob Git entry for {library.id}`)
		assert(isSafeRelativePath(path), `unsafe Git path for {library.id}: {tostring(path)}`)
		local folded = string.lower(path)
		assert(not seen[folded], `case-fold collision for {library.id}: {path}`)
		seen[folded] = true
		table.insert(entries, { hash = hash, path = path })
		count += 1
	end
	assert(count > 0, `Git artifact set is empty for {library.id}`)
	return entries
end

local function resolveTagRevision(raw, tag)
	local directRef = `refs/tags/{tag}`
	local peeledRef = directRef .. "^{}"
	local direct = nil
	local peeled = nil
	for line in string.gmatch(raw, "[^\r\n]+") do
		local revision, reference = string.match(line, "^([0-9a-f]+)\t(.+)$")
		assert(revision ~= nil and #revision == 40, "remote tag output is malformed")
		if reference == directRef then
			assert(direct == nil, "remote tag output duplicated the direct ref")
			direct = revision
		elseif reference == peeledRef then
			assert(peeled == nil, "remote tag output duplicated the peeled ref")
			peeled = revision
		else
			error("remote tag output contained an unexpected ref")
		end
	end
	assert(direct ~= nil, `remote tag does not exist: {tag}`)
	return peeled or direct
end

local function verifyRemoteTag(library)
	local directRef = `refs/tags/{library.tag}`
	local peeledRef = directRef .. "^{}"
	local resolved = resolveTagRevision(
		run("git", { "ls-remote", library.repository, directRef, peeledRef }),
		library.tag
	)
	assert(resolved == library.revision, `tag revision mismatch for {library.id}`)
end

local function acquireRuntime(library, staging, temp)
	fs.writeDir(temp)
	run("git", { "init", "--quiet" }, absolute(temp))
	run("git", { "remote", "add", "origin", library.repository }, absolute(temp))
	run("git", { "fetch", "--quiet", "--depth=1", "origin", library.revision }, absolute(temp))
	local resolved = string.match(run("git", { "rev-parse", "FETCH_HEAD" }, absolute(temp)), "([0-9a-f]+)")
	assert(resolved == library.revision, `resolved revision mismatch for {library.id}`)

	local treeArguments = { "ls-tree", "-rz", "--full-tree", "FETCH_HEAD", "--" }
	for _, path in ipairs(library.sourcePaths) do
		table.insert(treeArguments, path)
	end
	local entries = validateGitTree(run("git", treeArguments, absolute(temp)), library)
	fs.writeDir(staging)
	for _, entry in ipairs(entries) do
		local parent = string.match(entry.path, "^(.+)/[^/]+$")
		if parent then
			ensureDir(pathJoin(staging, parent))
		end
		fs.writeFile(pathJoin(staging, entry.path), run("git", { "cat-file", "blob", entry.hash }, absolute(temp)))
	end
	assert(fs.isFile(pathJoin(staging, library.modulePath)), `entry module was not acquired for {library.id}`)
end

local function validateArchiveListing(raw, library)
	local count = 0
	for path in string.gmatch(raw, "[^\r\n]+") do
		local normalized = string.gsub(path, "/$", "")
		if #normalized > 0 then
			assert(isSafeRelativePath(normalized), `unsafe release archive path for {library.id}: {normalized}`)
			count += 1
		end
	end
	assert(count > 0, `release archive is empty for {library.id}`)
end

local function acquireTool(library, staging)
	local response = net.request(library.assetUrl)
	assert(response.ok, `download failed for {library.id}: HTTP {response.statusCode}`)
	assert(serde.hash("sha256", response.body) == library.assetSha256, `release asset checksum mismatch for {library.id}`)
	fs.writeDir(staging)
	local archive = pathJoin(staging, library.archiveName)
	fs.writeFile(archive, response.body)
	validateArchiveListing(run("tar", { "-tf", absolute(archive) }), library)
	run("tar", { "-xf", absolute(archive), "-C", absolute(staging) })
	assert(fs.isFile(pathJoin(staging, library.executablePath)), `compiler executable was not extracted for {library.id}`)
end

local function acquireOne(library)
	local destination = pathJoin(VENDOR_ROOT, library.id)
	if fs.isDir(destination) then
		local marker = verifyInstalled(library)
		print(`READY {library.id} {marker.artifactSha256}`)
		return marker
	end

	local staging = pathJoin(VENDOR_ROOT, `.staging-{library.id}`)
	local temp = pathJoin(TEMP_ROOT, library.id)
	assert(not fs.isDir(staging) and not fs.isFile(staging), `staging path already exists for {library.id}: {staging}`)
	assert(not fs.isDir(temp) and not fs.isFile(temp), `temporary path already exists for {library.id}: {temp}`)

	local ok, markerOrError = pcall(function()
		verifyRemoteTag(library)
		if library.kind == "RuntimeSource" then
			acquireRuntime(library, staging, temp)
		else
			acquireTool(library, staging)
		end

		local checksum = directoryChecksum(staging)
		assert(checksum == library.artifactSha256, `acquired artifact checksum mismatch for {library.id}`)
		local marker = markerFor(library, checksum)
		fs.writeFile(pathJoin(staging, MARKER_NAME), serde.encode("json", marker) .. "\n")
		fs.move(staging, destination)
		return marker
	end)
	if not ok then
		if fs.isDir(staging) then
			pcall(fs.removeDir, staging)
		end
		if fs.isDir(temp) then
			pcall(fs.removeDir, temp)
		end
		error(markerOrError, 0)
	end
	if fs.isDir(temp) then
		fs.removeDir(temp)
	end
	local marker = markerOrError
	print(`ACQUIRED {library.id} {marker.artifactSha256}`)
	return marker
end

local function main(arguments)
	assert(#arguments == 1 and (arguments[1] == "--all" or arguments[1] == "--verify"), "usage: lune run scripts/acquire-benchmark-libraries.luau --all|--verify")
	local lock = loadLock()
	ensureDir(".tmp")
	ensureDir(TEMP_ROOT)

	for _, library in ipairs(lock.libraries) do
		if arguments[1] == "--all" then
			acquireOne(library)
		else
			local marker = verifyInstalled(library)
			print(`VERIFIED {library.id} {marker.artifactSha256}`)
		end
	end
end

local Acquisition = table.freeze({
	isSafeRelativePath = isSafeRelativePath,
	validateLock = validateLock,
	canonicalChecksum = canonicalChecksum,
	resolveTagRevision = resolveTagRevision,
	directoryChecksum = directoryChecksum,
	verifyInstalled = verifyInstalled,
	main = main,
})

if process.args[1] == "--all" or process.args[1] == "--verify" then
	main(process.args)
end

return Acquisition
