--!strict

-- Offline copy of the bounded source inventory. It does not authorize execution.
-- Roots must share an ordinary drive; stable filesystem ancestors are trusted.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Manifest = require("./StudyInputManifest")
local Fingerprint = require("./MeasurementFingerprint")
local Study = require("./BroadcastStudy")

local MAX_ENV_CHARS = 12_000
local DIRECTORY = 0x10
local REPARSE = 0x400

local function fail(code: string): never
	error("BCAST_E_COPY_" .. code, 0)
end

local NATIVE_SCRIPT = [[
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Globalization;
using System.Runtime.InteropServices;
public static class RelayStudyCopyNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectoryW(string path, IntPtr securityAttributes);
    public static string Attributes(string path) {
        uint value = GetFileAttributesW(path);
        return value == 0xffffffff ? "E:" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture)
            : "A:" + value.ToString(CultureInfo.InvariantCulture);
    }
    public static string CreateDirectory(string path) {
        return CreateDirectoryW(path, IntPtr.Zero) ? "D"
            : "E:" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture);
    }
}
"@
$items = [Environment]::GetEnvironmentVariable('RELAY_D06_ITEMS').Split([char]10, [StringSplitOptions]::RemoveEmptyEntries)
try {
    foreach ($item in $items) {
        if ($env:RELAY_D06_OPERATION -eq 'attributes') {
            [Console]::Out.WriteLine([RelayStudyCopyNative]::Attributes($item))
        } else {
            $value = [RelayStudyCopyNative]::CreateDirectory($item)
            [Console]::Out.WriteLine($value)
            if ($value -ne 'D') { break }
        }
    }
} catch { exit 27 }
]]

local function native(operation: string, paths: { string }): { string }
	local result, batch, size = {}, {}, 0
	local function flush(): boolean
		if #batch == 0 then return false end
		local systemRoot = process.env.SystemRoot
		if process.os ~= "windows" or type(systemRoot) ~= "string" or #systemRoot == 0 then fail("PLATFORM") end
		local executable = string.gsub(systemRoot, "\\", "/"):gsub("/+$", "")
			.. "/System32/WindowsPowerShell/v1.0/powershell.exe"
		local child = process.exec(executable, { "-NoProfile", "-NonInteractive", "-Command", NATIVE_SCRIPT }, {
			env = { RELAY_D06_OPERATION = operation, RELAY_D06_ITEMS = table.concat(batch, "\n") },
		})
		if type(child) ~= "table" or child.ok ~= true or type(child.stdout) ~= "string" then fail("NATIVE") end
		local lines = string.split(string.gsub(child.stdout, "\r\n", "\n"), "\n")
		if lines[#lines] == "" then table.remove(lines) end
		if #lines > #batch or (#lines < #batch and operation ~= "directories") then fail("NATIVE") end
		for _, line in lines do table.insert(result, line) end
		local stopped = operation == "directories" and #lines > 0 and lines[#lines] ~= "D"
		batch, size = {}, 0
		return stopped
	end
	local stopped = false
	for _, path in paths do
		if stopped then break end
		if #path + 1 > MAX_ENV_CHARS then fail("PATH") end
		if size + #path + 1 > MAX_ENV_CHARS then stopped = flush() end
		if not stopped then table.insert(batch, path); size += #path + 1 end
	end
	if not stopped then flush() end
	return result
end

local function attributes(paths: { string }): { [string]: any }
	local found, lines = {}, native("attributes", paths)
	if #lines ~= #paths then fail("NATIVE") end
	for index, path in paths do
		local kind, value = string.match(lines[index], "^([AE]):(%d+)$")
		if kind == "A" then found[path] = { attributes = tonumber(value) }
		elseif kind == "E" then found[path] = { errorCode = tonumber(value) }
		else fail("NATIVE") end
	end
	return found
end

local function createDirectories(paths: { string }): boolean
	local lines = native("directories", paths)
	for _, line in lines do if line ~= "D" and string.match(line, "^E:%d+$") == nil then fail("NATIVE") end end
	if #lines ~= #paths then return false end
	for _, line in lines do if line ~= "D" then return false end end
	return true
end

local function component(value: string): boolean
	if #value == 0 or #value > 255 or value == "." or value == ".."
		or string.match(value, "^[A-Za-z0-9 _%.%-]+$") == nil
		or string.sub(value, -1) == "." or string.sub(value, -1) == " " then return false end
	local stem = string.upper(string.match(value, "^([^%.]+)") or value)
	return stem ~= "CON" and stem ~= "PRN" and stem ~= "AUX" and stem ~= "NUL"
		and stem ~= "CONIN$" and stem ~= "CONOUT$"
		and string.match(stem, "^COM[1-9]$") == nil and string.match(stem, "^LPT[1-9]$") == nil
end

local function parts(value: string): { string }
	local result = string.split(value, "/")
	for _, part in result do if not component(part) then fail("PATH") end end
	return result
end

local function absolute(value: any): (string, string, { string })
	if type(value) ~= "string" or #value == 0 or string.find(value, "[%z\1-\31\127-\255]") then fail("PATH") end
	local path = string.gsub(value, "\\", "/")
	local drive, tail = string.match(path, "^([A-Za-z]):/(.*)$")
	if drive == nil or tail == nil or #tail == 0 or string.sub(tail, -1) == "/"
		or string.find(tail, "//", 1, true) ~= nil then fail("PATH") end
	local pathParts = parts(tail)
	if #path >= 248 then fail("PATH") end
	return string.lower(drive) .. ":/" .. table.concat(pathParts, "/"),
		drive .. ":/" .. table.concat(pathParts, "/"), pathParts
end

local function relative(value: string): ({ string }, string, string)
	if #value == 0 or string.find(value, "[%z\\:]") ~= nil or string.sub(value, 1, 1) == "/"
		or string.find(value, "//", 1, true) ~= nil or string.sub(value, -1) == "/" then fail("PATH") end
	local pathParts = parts(value)
	local path = table.concat(pathParts, "/")
	return pathParts, path, string.lower(path)
end

local function prefix(left: { string }, right: { string }): boolean
	if #left > #right then return false end
	for index, part in left do if string.lower(part) ~= string.lower(right[index]) then return false end end
	return true
end

local function ancestors(drive: string, pathParts: { string }, includeSelf: boolean): { string }
	local result = { drive .. ":/" }
	local current = drive .. ":"
	local count = if includeSelf then #pathParts else #pathParts - 1
	for index = 1, count do
		current ..= "/" .. pathParts[index]
		table.insert(result, current)
	end
	return result
end

local function join(root: string, child: string): string
	return root .. "/" .. child
end

local function unique(paths: { string }): { string }
	local seen, result = {}, {}
	for _, path in paths do
		local key = string.lower(path)
		if not seen[key] then seen[key] = true; table.insert(result, path) end
	end
	return result
end

local function checkDirectories(paths: { string }, found: any)
	for _, path in paths do
		local item = found[path]
		if type(item) ~= "table" or type(item.attributes) ~= "number"
			or bit32.band(item.attributes, REPARSE) ~= 0 or bit32.band(item.attributes, DIRECTORY) == 0 then fail("REPARSE") end
	end
end

local function checkFiles(paths: { string }, found: any)
	for _, path in paths do
		local item = found[path]
		if type(item) ~= "table" or type(item.attributes) ~= "number"
			or bit32.band(item.attributes, REPARSE) ~= 0 or bit32.band(item.attributes, DIRECTORY) ~= 0 then fail("REPARSE") end
	end
end

local function guardedSourceFs(root: string, drive: string, rootParts: { string }, surface: any,
	getAttributes: any): any
	-- Cache attributes only for this inventory walk; copy reads and the final walk refresh them.
	local cache = {}
	local rootLower, rootPrefix = string.lower(root), string.lower(root) .. "/"
	local function checked(path: string): any
		local normalized = string.gsub(path, "\\", "/")
		local lowered = string.lower(normalized)
		local suffix = if lowered == rootLower then ""
			elseif string.sub(lowered, 1, #rootPrefix) == rootPrefix then string.sub(normalized, #root + 2)
			else fail("PATH")
		local pathParts = if suffix == "" then {} else parts(suffix)
		local check = ancestors(drive, rootParts, true)
		local combined = table.clone(rootParts)
		for _, part in pathParts do
			table.insert(combined, part)
			table.insert(check, drive .. ":/" .. table.concat(combined, "/"))
		end
		local pending, missing = {}, false
		for _, itemPath in check do
			local cached = cache[string.lower(itemPath)]
			if cached == nil and not missing then table.insert(pending, itemPath) end
			if cached == false then missing = true end
		end
		local found = getAttributes(pending)
		for _, itemPath in pending do cache[string.lower(itemPath)] = found[itemPath] end
		for index, itemPath in check do
			local item = cache[string.lower(itemPath)]
			if type(item) ~= "table" or type(item.attributes) ~= "number" then
				if type(item) == "table" and (item.errorCode == 2 or item.errorCode == 3) then
					cache[string.lower(itemPath)] = false
					return nil
				end
				if item == false then return nil end
				fail("REPARSE")
			end
			if bit32.band(item.attributes, REPARSE) ~= 0 then fail("REPARSE") end
			if index < #check and bit32.band(item.attributes, DIRECTORY) == 0 then fail("PATH") end
		end
		return cache[string.lower(check[#check])]
	end
	return {
		isFile = function(path: string)
			local item = checked(path)
			return item ~= nil and bit32.band(item.attributes, DIRECTORY) == 0
		end,
		isDir = function(path: string)
			local item = checked(path)
			return item ~= nil and bit32.band(item.attributes, DIRECTORY) ~= 0
		end,
		readFile = function(path: string)
			local item = checked(path)
			if item == nil or bit32.band(item.attributes, DIRECTORY) ~= 0 then fail("INPUT") end
			return surface.readFile(path)
		end,
		readDir = function(path: string)
			local item = checked(path)
			if item == nil or bit32.band(item.attributes, DIRECTORY) == 0 then fail("INPUT") end
			return surface.readDir(path)
		end,
	}
end

local function collectInventory(root: string, drive: string, rootParts: { string }, deps: any,
	getAttributes: any, hash: any): any
	local guarded = guardedSourceFs(root, drive, rootParts, deps.fs or fs, getAttributes)
	return Manifest.sourceInventory(root, {
		fs = guarded, execute = deps.execute or process.exec, hash = hash,
	})
end

local function checkedEntries(inventory: any): ({ any }, any, any)
	local entries, files, directories = {}, {}, {}
	for _, raw in inventory.entries do
		local pathParts, path, key = relative(raw.path)
		if files[key] ~= nil then fail("PATH") end
		local entry = { path = path, bytes = raw.bytes, sha256 = raw.sha256 }
		files[key] = entry
		table.insert(entries, entry)
		local parent = {}
		for index = 1, #pathParts - 1 do
			table.insert(parent, pathParts[index])
			local directory = table.concat(parent, "/")
			local directoryKey = string.lower(directory)
			if directories[directoryKey] ~= nil and directories[directoryKey] ~= directory then fail("PATH") end
			directories[directoryKey] = directory
		end
	end
	for key in directories do if files[key] ~= nil then fail("PATH") end end
	table.sort(entries, function(left, right) return left.path < right.path end)
	return entries, files, directories
end

local function sourcePaths(root: string, drive: string, rootParts: { string }, entries: { any }): ({ string }, { string })
	local directories, files = ancestors(drive, rootParts, true), {}
	for _, entry in entries do
		local path = join(root, entry.path)
		table.insert(files, path)
		local parent = table.clone(rootParts)
		for part in string.gmatch(entry.path, "[^/]+") do table.insert(parent, part) end
		for _, path in ancestors(drive, parent, false) do table.insert(directories, path) end
	end
	return unique(directories), unique(files)
end

local function outputDirectories(root: string, dirs: any, entries: { any }): { string }
	local result, nested = { root }, {}
	for _, path in dirs do table.insert(nested, join(root, path)) end
	table.sort(nested, function(left, right)
		local leftDepth = select(2, string.gsub(left, "/", ""))
		local rightDepth = select(2, string.gsub(right, "/", ""))
		if leftDepth ~= rightDepth then return leftDepth < rightDepth end
		return string.lower(left) < string.lower(right)
	end)
	for _, path in nested do table.insert(result, path) end
	for _, entry in entries do if #join(root, entry.path) >= 260 then fail("PATH") end end
	for _, path in result do if #path >= 248 then fail("PATH") end end
	return result
end

local function fileDigest(body: string, hash: any): string
	return Fingerprint.digest({ bytes = body }, hash, "RelayStudyFile:1")
end

local function checkSourceFile(root: string, drive: string, rootParts: { string }, entry: any, getAttributes: any)
	local fullParts = table.clone(rootParts)
	for part in string.gmatch(entry.path, "[^/]+") do table.insert(fullParts, part) end
	local all = ancestors(drive, fullParts, true)
	local file = all[#all]
	table.remove(all)
	checkDirectories(all, getAttributes(all))
	checkFiles({ file }, getAttributes({ file }))
end

local function verifyTree(root: string, entries: { any }, files: any, dirs: any,
	getAttributes: any, surface: any, hash: any): (number, string)
	local seenFiles, seenDirs, identities = {}, {}, {}
	local function walk(path: string, relativeDir: string)
		checkDirectories({ path }, getAttributes({ path }))
		local ok, names = pcall(surface.readDir, path)
		if not ok or type(names) ~= "table" then fail("OUTPUT") end
		local children, localSeen = {}, {}
		for _, name in names do
			if type(name) ~= "string" or not component(name) then fail("OUTPUT") end
			local childRel = if relativeDir == "" then name else relativeDir .. "/" .. name
			local key = string.lower(childRel)
			if localSeen[key] or (files[key] == nil and dirs[key] == nil) then fail("OUTPUT") end
			localSeen[key] = true
			table.insert(children, { path = join(path, name), relative = childRel, key = key,
				file = files[key], directory = dirs[key] })
		end
		local childPaths = {}
		for _, child in children do table.insert(childPaths, child.path) end
		local found = getAttributes(childPaths)
		for _, child in children do
			local item = found[child.path]
			if type(item) ~= "table" or type(item.attributes) ~= "number"
				or bit32.band(item.attributes, REPARSE) ~= 0 then fail("OUTPUT") end
			local isDir = bit32.band(item.attributes, DIRECTORY) ~= 0
			if child.directory ~= nil then
				if not isDir or child.relative ~= child.directory then fail("OUTPUT") end
				seenDirs[child.key] = true
				walk(child.path, child.relative)
			else
				if isDir or child.file == nil or child.relative ~= child.file.path then fail("OUTPUT") end
				local readOk, body = pcall(surface.readFile, child.path)
				if not readOk or type(body) ~= "string" or #body ~= child.file.bytes then fail("OUTPUT") end
				local sha256 = fileDigest(body, hash)
				if sha256 ~= child.file.sha256 then fail("OUTPUT") end
				seenFiles[child.key] = true
				identities[child.file.path] = sha256
			end
		end
	end
	walk(root, "")
	local fileCount, dirCount, expectedDirCount = 0, 0, 0
	for _ in seenFiles do fileCount += 1 end
	for _ in seenDirs do dirCount += 1 end
	for _ in dirs do expectedDirCount += 1 end
	if fileCount ~= #entries or dirCount ~= expectedDirCount then fail("OUTPUT") end
	return fileCount, Fingerprint.digest(identities, hash, "RelayStudySource:1")
end

local function copy(rootValue: string, destinationValue: string, dependencies: any?): any
	local deps = dependencies or {}
	local surface, hash = deps.fs or fs, deps.hash or serde.hash
	local getAttributes, mkdir = deps.attributes or attributes, deps.createDirectories or createDirectories
	local sourceKey, root, rootParts = absolute(rootValue)
	local destinationKey, destination, destinationParts = absolute(destinationValue)
	local drive, destinationDrive = string.sub(root, 1, 1), string.sub(destination, 1, 1)
	if string.lower(drive) ~= string.lower(destinationDrive) then fail("PATH") end
	local sourceParts, outputParts = { string.sub(sourceKey, 1, 2) }, { string.sub(destinationKey, 1, 2) }
	for _, part in rootParts do table.insert(sourceParts, part) end
	for _, part in destinationParts do table.insert(outputParts, part) end
	if prefix(sourceParts, outputParts) or prefix(outputParts, sourceParts) then fail("PATH") end

	local sourceDirs = ancestors(drive, rootParts, true)
	checkDirectories(sourceDirs, getAttributes(sourceDirs))
	local parentParts = table.clone(destinationParts)
	table.remove(parentParts)
	local outputParents = ancestors(destinationDrive, parentParts, true)
	checkDirectories(outputParents, getAttributes(outputParents))
	local inventory = collectInventory(root, drive, rootParts, deps, getAttributes, hash)
	local entries, files, dirs = checkedEntries(inventory)
	local plannedDirs = outputDirectories(destination, dirs, entries)
	local sourceDirectoryPaths, sourceFilePaths = sourcePaths(root, drive, rootParts, entries)
	checkDirectories(sourceDirectoryPaths, getAttributes(sourceDirectoryPaths))
	checkFiles(sourceFilePaths, getAttributes(sourceFilePaths))
	local outputState = getAttributes({ destination })[destination]
	if type(outputState) ~= "table" then fail("NATIVE") end
	if outputState.attributes ~= nil or outputState.errorCode ~= 2 then fail("OCCUPIED") end

	checkDirectories(outputParents, getAttributes(outputParents))
	outputState = getAttributes({ destination })[destination]
	if type(outputState) ~= "table" then fail("NATIVE") end
	if outputState.attributes ~= nil or outputState.errorCode ~= 2 then fail("OCCUPIED") end
	if mkdir({ destination }) ~= true then fail("OCCUPIED") end
	if #plannedDirs > 1 then
		local nested = {}
		for index = 2, #plannedDirs do table.insert(nested, plannedDirs[index]) end
		if mkdir(nested) ~= true then fail("DIRECTORY") end
	end

	for _, entry in entries do
		checkSourceFile(root, drive, rootParts, entry, getAttributes)
		local source = join(root, entry.path)
		local readOk, body = pcall(surface.readFile, source)
		if not readOk or type(body) ~= "string" or #body ~= entry.bytes or fileDigest(body, hash) ~= entry.sha256 then
			fail("SOURCE_CHANGED")
		end
		local output = join(destination, entry.path)
		local wrote = pcall((deps.createExclusive or Study.atomicCreateFile), output, body)
		if not wrote then fail("WRITE") end
		local verifyOk, readback = pcall(surface.readFile, output)
		if not verifyOk or readback ~= body then fail("WRITE") end
	end

	local outputFiles, outputHash = verifyTree(destination, entries, files, dirs, getAttributes, surface, hash)
	if outputFiles ~= inventory.files or outputHash ~= inventory.sha256 then fail("OUTPUT") end
	checkDirectories(sourceDirectoryPaths, getAttributes(sourceDirectoryPaths))
	checkFiles(sourceFilePaths, getAttributes(sourceFilePaths))
	local final = collectInventory(root, drive, rootParts, deps, getAttributes, hash)
	if final.files ~= inventory.files or final.sha256 ~= inventory.sha256 then fail("SOURCE_CHANGED") end
	for _, entry in entries do table.freeze(entry) end
	return table.freeze({ directory = destination, files = inventory.files, sha256 = inventory.sha256,
		entries = table.freeze(entries) })
end

return table.freeze({ copy = copy })
