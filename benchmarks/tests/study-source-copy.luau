--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Fingerprint = require("../host/MeasurementFingerprint")
local Manifest = require("../host/StudyInputManifest")
local Copy = require("../host/StudySourceCopy")

assert(Copy.samePath("C:/Relay/Source", "c:/relay/source"),
	"Windows path equality should ignore component case")

local function fixture(name: string, rootOverride: string?, destinationOverride: string?): any
	local root = rootOverride or "C:/relay-" .. name
	local destination = destinationOverride or root .. "-copy"
	local files, directories, reparse = {}, { ["C:/"] = true }, {}
	local tracked = { "benchmarks/event-v1.project.json", "tracked.txt" }
	local reads, metrics = {}, { writes = 0, directoryCalls = 0 }
	local function addDirectory(path: string)
		directories[path] = true
	end
	local function addFile(path: string, body: string)
		files[path] = body
	end
	local function parentPath(path: string): string?
		local parent = string.match(path, "^(.*)/[^/]+$")
		return if parent == string.sub(path, 1, 2) then parent .. "/" else parent
	end
	addDirectory(root)
	local rootParent = parentPath(root)
	if rootParent ~= nil then addDirectory(rootParent) end
	addDirectory(root .. "/benchmarks")
	addDirectory(root .. "/src")
	addFile(root .. "/benchmarks/event-v1.project.json",
		serde.encode("json", { tree = { Relay = { ["$path"] = "../src" } } }))
	addFile(root .. "/tracked.txt", "tracked input")
	addFile(root .. "/src/Relay.luau", "return 'relay'")
	addFile(root .. "/src/Relay.meta.json", "{}")
	local surface = {}
	function surface.isFile(path: string) return files[path] ~= nil end
	function surface.isDir(path: string) return directories[path] == true end
	function surface.readFile(path: string): string
		reads[path] = (reads[path] or 0) + 1
		assert(files[path] ~= nil, `missing fake file {path}`)
		return files[path]
	end
	function surface.readDir(path: string): { string }
		local names, seen, prefix = {}, {}, path .. "/"
		for candidate in files do
			if string.sub(candidate, 1, #prefix) == prefix then
				local suffix = string.sub(candidate, #prefix + 1)
				local name = string.match(suffix, "^[^/]+")
				if name ~= nil and not seen[name] then seen[name] = true; table.insert(names, name) end
			end
		end
		for candidate in directories do
			if string.sub(candidate, 1, #prefix) == prefix then
				local suffix = string.sub(candidate, #prefix + 1)
				local name = string.match(suffix, "^[^/]+")
				if name ~= nil and not seen[name] then seen[name] = true; table.insert(names, name) end
			end
		end
		return names
	end
	local function attributes(paths: { string }): any
		local result = {}
		for _, path in paths do
			if reparse[path] then result[path] = { attributes = 0x410 }
			elseif directories[path] then result[path] = { attributes = 0x10 }
			elseif files[path] ~= nil then result[path] = { attributes = 0 }
			else result[path] = { errorCode = 2 } end
		end
		return result
	end
	local function createDirectories(paths: { string }): boolean
		metrics.directoryCalls += 1
		for _, path in paths do
			if directories[path] or files[path] ~= nil then return false end
			local parent = parentPath(path)
			if parent == nil or not directories[parent] then return false end
			directories[path] = true
		end
		return true
	end
	local function createExclusive(path: string, body: string)
		metrics.writes += 1
		assert(files[path] == nil and not directories[path], `occupied fake output {path}`)
		local parent = parentPath(path)
		assert(parent ~= nil and directories[parent], `missing fake output parent {path}`)
		files[path] = body
	end
	local function execute(program: string, args: { string }): any
		assert(program == "git" and args[1] == "ls-files" and args[2] == "--cached" and args[3] == "-z")
		local paths = table.clone(tracked)
		table.sort(paths)
		return { ok = true, stdout = table.concat(paths, "\0") .. "\0" }
	end
	local deps = { fs = surface, execute = execute, hash = serde.hash,
		attributes = attributes, createDirectories = createDirectories, createExclusive = createExclusive }
	return { root = root, destination = destination, files = files, directories = directories,
		reparse = reparse, tracked = tracked, reads = reads, metrics = metrics,
		surface = surface, deps = deps,
		attributes = attributes, createDirectories = createDirectories, createExclusive = createExclusive }
end

local function rejects(code: string, callback: () -> ())
	local ok, message = pcall(callback)
	assert(not ok and string.find(tostring(message), "BCAST_E_COPY_" .. code, 1, true) ~= nil,
		`expected BCAST_E_COPY_{code}, got {tostring(message)}`)
end

local copied = fixture("source-copy")
local expected = Manifest.sourceInventory(copied.root,
	{ fs = copied.surface, execute = copied.deps.execute, hash = serde.hash })
local result = Copy.copy(copied.root, copied.destination, copied.deps)
assert(table.isfrozen(result) and table.isfrozen(result.entries)
	and result.directory == copied.destination and result.files == expected.files
	and result.sha256 == expected.sha256, "copy result did not preserve the frozen source inventory")
assert(#result.entries == expected.files, "copy omitted inventory entries")
for index, entry in result.entries do
	local source = expected.entries[index]
	assert(table.isfrozen(entry) and entry.path == source.path and entry.bytes == source.bytes
		and entry.sha256 == source.sha256, `copy entry differs at {index}`)
	assert(copied.files[copied.destination .. "/" .. entry.path] == copied.files[copied.root .. "/" .. entry.path],
		`copied bytes differ for {entry.path}`)
end
assert(copied.files[copied.root .. "/src/Relay.meta.json"] == "{}"
	and copied.files[copied.destination .. "/src/Relay.meta.json"] == "{}",
	"ignored $path sibling was not copied")
local temporaryDirectory = copied.destination .. "/.tmp"
assert(copied.createDirectories({ temporaryDirectory }), "could not create the host-owned temporary directory")
local verifiedWithEmptyTemporary = Copy.verify(copied.destination, expected,
	{ fs = copied.surface, attributes = copied.attributes, allowedDirectories = { ".tmp" } })
assert(verifiedWithEmptyTemporary.sha256 == expected.sha256,
	"an owned empty temporary directory changed the verified source copy")
copied.files[temporaryDirectory .. "/rogue.txt"] = "unexpected source-like output"
rejects("OUTPUT", function()
	Copy.verify(copied.destination, expected,
		{ fs = copied.surface, attributes = copied.attributes, allowedDirectories = { ".tmp" } })
end)
copied.files[temporaryDirectory .. "/rogue.txt"] = nil
copied.directories[temporaryDirectory] = nil
copied.files[copied.root .. "/tracked.txt"] = "later source edit"
assert(copied.files[copied.destination .. "/tracked.txt"] == "tracked input",
	"later source edits changed the copied snapshot")

local changed = fixture("source-changed-before-write")
local changedPath = changed.root .. "/src/Relay.luau"
local baseRead = changed.surface.readFile
changed.surface.readFile = function(path: string): string
	local body = baseRead(path)
	if path == changedPath and changed.reads[path] == 2 then
		changed.files[path] = "return 'changed'"
		return changed.files[path]
	end
	return body
end
rejects("SOURCE_CHANGED", function() Copy.copy(changed.root, changed.destination, changed.deps) end)
assert(changed.files[changed.destination .. "/src/Relay.luau"] == nil,
	"changed source bytes were written to the destination")

local changedClosure = fixture("source-closure-changed")
local originalCreate = changedClosure.createExclusive
changedClosure.deps.createExclusive = function(path: string, body: string)
	originalCreate(path, body)
	if string.sub(path, -#"/tracked.txt") == "/tracked.txt" then
		changedClosure.files[changedClosure.root .. "/tracked.txt"] = "changed after copy"
	end
end
rejects("SOURCE_CHANGED", function()
	Copy.copy(changedClosure.root, changedClosure.destination, changedClosure.deps)
end)
assert(changedClosure.files[changedClosure.destination .. "/tracked.txt"] == "tracked input",
	"failed final source check removed or rewrote the retained copy")

local occupiedRoot = fixture("source-copy-occupied-root")
occupiedRoot.directories[occupiedRoot.destination] = true
occupiedRoot.files[occupiedRoot.destination .. "/sentinel.txt"] = "keep root sentinel"
rejects("OCCUPIED", function() Copy.copy(occupiedRoot.root, occupiedRoot.destination, occupiedRoot.deps) end)
assert(occupiedRoot.files[occupiedRoot.destination .. "/sentinel.txt"] == "keep root sentinel"
	and occupiedRoot.metrics.directoryCalls == 0 and occupiedRoot.metrics.writes == 0,
	"occupied destination root was changed")

local rootRace = fixture("source-copy-root-race")
local rootRaceCalls = 0
rootRace.deps.createDirectories = function(paths: { string }): boolean
	rootRaceCalls += 1
	assert(#paths == 1 and paths[1] == rootRace.destination, "root reservation was not its own first call")
	rootRace.directories[rootRace.destination] = true
	rootRace.files[rootRace.destination .. "/sentinel.txt"] = "keep raced sentinel"
	return false
end
rejects("OCCUPIED", function() Copy.copy(rootRace.root, rootRace.destination, rootRace.deps) end)
assert(rootRaceCalls == 1 and rootRace.metrics.writes == 0
	and rootRace.files[rootRace.destination .. "/sentinel.txt"] == "keep raced sentinel",
	"losing the root reservation performed later writes")

local nestedRace = fixture("source-copy-nested-race")
local nestedBase = nestedRace.createDirectories
local nestedCalls = 0
nestedRace.deps.createDirectories = function(paths: { string }): boolean
	nestedCalls += 1
	if nestedCalls == 1 then return nestedBase(paths) end
	assert(paths[1] == nestedRace.destination .. "/benchmarks", "nested directory order changed")
	nestedRace.directories[paths[1]] = true
	nestedRace.files[paths[1] .. "/sentinel.txt"] = "keep nested sentinel"
	return false
end
rejects("DIRECTORY", function() Copy.copy(nestedRace.root, nestedRace.destination, nestedRace.deps) end)
assert(nestedCalls == 2 and nestedRace.metrics.writes == 0
	and nestedRace.files[nestedRace.destination .. "/benchmarks/sentinel.txt"] == "keep nested sentinel"
	and not nestedRace.directories[nestedRace.destination .. "/src"],
	"nested creation failure overwrote data or continued creating directories")

local fileRace = fixture("source-copy-file-race")
local fileBase = fileRace.createDirectories
local fileRaceCalls = 0
fileRace.deps.createDirectories = function(paths: { string }): boolean
	fileRaceCalls += 1
	local ok = fileBase(paths)
	if fileRaceCalls == 2 then
		fileRace.files[fileRace.destination .. "/benchmarks/event-v1.project.json"] = "keep nested file sentinel"
	end
	return ok
end
rejects("WRITE", function() Copy.copy(fileRace.root, fileRace.destination, fileRace.deps) end)
assert(fileRace.files[fileRace.destination .. "/benchmarks/event-v1.project.json"] == "keep nested file sentinel",
	"exclusive file creation overwrote a raced nested sentinel")

local writeFailure = fixture("source-copy-write-failure")
writeFailure.deps.createExclusive = function(path: string, body: string)
	if string.sub(path, -#"/tracked.txt") == "/tracked.txt" then
		writeFailure.files[path] = "keep failed write sentinel"
		error("occupied during exclusive create")
	end
	writeFailure.createExclusive(path, body)
end
rejects("WRITE", function() Copy.copy(writeFailure.root, writeFailure.destination, writeFailure.deps) end)
assert(writeFailure.files[writeFailure.destination .. "/tracked.txt"] == "keep failed write sentinel",
	"failed exclusive write damaged its sentinel")

local function noOutput(state: any, destination: string)
	local before = state.metrics.directoryCalls
	local ok = pcall(Copy.copy, state.root, destination, state.deps)
	assert(not ok and state.metrics.directoryCalls == before and state.metrics.writes == 0,
		`unsafe path created output: {destination}`)
end
local unsafe = fixture("source-copy-unsafe-paths")
for _, destination in { unsafe.root, unsafe.root .. "/child", "C:/", "D:/outside",
	unsafe.destination .. "/bad:name", unsafe.destination .. "/~alias", unsafe.destination .. "/CON",
	unsafe.destination .. "/trailing.", "\\\\server\\share\\copy", "C:relative" } do
	noOutput(unsafe, destination)
end
local contained = fixture("source-copy-containment", "C:/relay-containment/source", "C:/relay-containment")
noOutput(contained, contained.destination)

local aliases = fixture("source-copy-case-alias")
aliases.directories[aliases.root .. "/src/Foo"] = true
aliases.directories[aliases.root .. "/src/foo"] = true
aliases.files[aliases.root .. "/src/Foo/a.luau"] = "return 1"
aliases.files[aliases.root .. "/src/foo/b.luau"] = "return 2"
noOutput(aliases, aliases.destination)

local prefixCollision = fixture("source-copy-prefix-collision")
table.insert(prefixCollision.tracked, "src/File")
table.insert(prefixCollision.tracked, "src/file/child.txt")
prefixCollision.files[prefixCollision.root .. "/src/File"] = "file"
prefixCollision.directories[prefixCollision.root .. "/src/file"] = true
prefixCollision.files[prefixCollision.root .. "/src/file/child.txt"] = "child"
noOutput(prefixCollision, prefixCollision.destination)

local sourceReparse = fixture("source-copy-source-reparse")
sourceReparse.reparse[sourceReparse.root .. "/src"] = true
rejects("REPARSE", function() Copy.copy(sourceReparse.root, sourceReparse.destination, sourceReparse.deps) end)
assert(sourceReparse.reads[sourceReparse.root .. "/src/Relay.luau"] == nil
	and sourceReparse.metrics.directoryCalls == 0, "source reparse point was read or output was created")

local parentReparse = fixture("source-copy-parent-reparse")
parentReparse.destination = "C:/destination-parent/copy"
parentReparse.directories["C:/destination-parent"] = true
parentReparse.reparse["C:/destination-parent"] = true
rejects("REPARSE", function() Copy.copy(parentReparse.root, parentReparse.destination, parentReparse.deps) end)
assert(parentReparse.metrics.directoryCalls == 0, "destination reparse parent was accepted")

local unexpectedFile = fixture("source-copy-extra-file")
local extraFileCreate = unexpectedFile.createExclusive
unexpectedFile.deps.createExclusive = function(path: string, body: string)
	extraFileCreate(path, body)
	if string.sub(path, -#"/tracked.txt") == "/tracked.txt" then
		unexpectedFile.files[unexpectedFile.destination .. "/unexpected.txt"] = "extra"
	end
end
rejects("OUTPUT", function()
	Copy.copy(unexpectedFile.root, unexpectedFile.destination, unexpectedFile.deps)
end)

local unexpectedDir = fixture("source-copy-extra-dir")
local extraDirCreate = unexpectedDir.createExclusive
unexpectedDir.deps.createExclusive = function(path: string, body: string)
	extraDirCreate(path, body)
	if string.sub(path, -#"/tracked.txt") == "/tracked.txt" then
		unexpectedDir.directories[unexpectedDir.destination .. "/unexpected"] = true
	end
end
rejects("OUTPUT", function()
	Copy.copy(unexpectedDir.root, unexpectedDir.destination, unexpectedDir.deps)
end)

-- Exercise the real Win32 directory reservation and BroadcastStudy CreateNew path.
if process.os == "windows" then
	local workspace = string.gsub(process.cwd, "\\", "/"):gsub("/+$", "")
	local tempParent = workspace .. "/.tmp"
	if not fs.isDir(tempParent) then fs.writeDir(tempParent) end
	local token = string.sub(serde.hash("sha256", tostring(os.clock()) .. tostring({})), 1, 16)
	local smoke = tempParent .. "/study-source-copy-" .. token
	assert(string.sub(smoke, 1, #tempParent + 1) == tempParent .. "/"
		and not fs.isDir(smoke) and not fs.isFile(smoke), "smoke fixture path is not owned and new")
	local smokeSource, smokeDestination = smoke .. "/source", smoke .. "/destination"
	fs.writeDir(smokeSource .. "/benchmarks")
	fs.writeDir(smokeSource .. "/src")
	fs.writeFile(smokeSource .. "/benchmarks/event-v1.project.json",
		serde.encode("json", { tree = { Relay = { ["$path"] = "../src" } } }))
	fs.writeFile(smokeSource .. "/src/init.luau", "return 'real smoke'")
	fs.writeFile(smokeSource .. "/tracked.txt", "real CreateNew smoke")
	local smokeDeps = { fs = fs, hash = serde.hash, execute = function(program: string, args: { string })
		assert(program == "git" and args[1] == "ls-files")
		return { ok = true, stdout = "benchmarks/event-v1.project.json\0tracked.txt\0" }
	end }
	local smokeResult = Copy.copy(smokeSource, smokeDestination, smokeDeps)
	assert(smokeResult.files == 3 and fs.readFile(smokeDestination .. "/tracked.txt") == "real CreateNew smoke"
		and fs.readFile(smokeDestination .. "/src/init.luau") == "return 'real smoke'",
		"real Windows copy did not preserve fixture bytes")
	local removeFiles = { smokeSource .. "/benchmarks/event-v1.project.json", smokeSource .. "/src/init.luau",
		smokeSource .. "/tracked.txt", smokeDestination .. "/benchmarks/event-v1.project.json",
		smokeDestination .. "/src/init.luau", smokeDestination .. "/tracked.txt" }
	for _, path in removeFiles do
		local normalized = string.gsub(path, "\\", "/")
		assert(string.sub(normalized, 1, #smoke + 1) == smoke .. "/", "cleanup escaped its owned fixture")
		if fs.isFile(path) then fs.removeFile(path) end
	end
	for _, path in { smokeDestination .. "/benchmarks", smokeDestination .. "/src", smokeDestination,
		smokeSource .. "/benchmarks", smokeSource .. "/src", smokeSource, smoke } do
		local normalized = string.gsub(path, "\\", "/")
		assert(string.sub(normalized, 1, #smoke + 1) == smoke .. "/" or normalized == smoke,
			"cleanup escaped its owned fixture")
		if fs.isDir(path) then fs.removeDir(path) end
	end
end

print("PASS Relay.Benchmarks.StudySourceCopy")
