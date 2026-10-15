--!strict

-- Prelaunch identity for the canonical broadcast study. This records bytes,
-- not a reusable build or a promise that a live checkout cannot be edited.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Fingerprint = require("./MeasurementFingerprint")

local MAX_FILES = 4_096
local MAX_SOURCE_BYTES = 64 * 1_048_576

local function fail(code: string): never
	error(code, 0)
end

local function digest(entries: any, hash: any, domain: string): string
	return Fingerprint.digest(entries, hash, domain)
end

local function isDigest(value: any): boolean
	return type(value) == "string" and #value == 71 and string.match(value, "^sha256:[0-9a-f]+$") ~= nil
end

local function fileBytes(surface: any, path: string): string
	if not surface.isFile(path) then fail("BCAST_E_INPUT_FILE") end
	local ok, body = pcall(surface.readFile, path)
	if not ok or type(body) ~= "string" then fail("BCAST_E_INPUT_FILE") end
	return body
end

local function relativePath(base: string, child: string): string
	if type(child) ~= "string" or #child == 0 or string.find(child, "\\", 1, true)
		or string.sub(child, 1, 1) == "/" or string.find(child, ":", 1, true)
	then fail("BCAST_E_INPUT_PATH") end
	local parts = {}
	for part in string.gmatch(base .. "/" .. child, "[^/]+") do
		if part == "." then continue end
		if part == ".." then
			if #parts == 0 then fail("BCAST_E_INPUT_PATH") end
			table.remove(parts)
		elseif part == "" then
			fail("BCAST_E_INPUT_PATH")
		else
			table.insert(parts, part)
		end
	end
	if #parts == 0 then fail("BCAST_E_INPUT_PATH") end
	return table.concat(parts, "/")
end

local function trackedPaths(root: string, execute: any): { string }
	local ok, result = pcall(execute, "git", { "ls-files", "--cached", "-z" }, { cwd = root })
	if not ok or type(result) ~= "table" or result.ok ~= true or type(result.stdout) ~= "string" then
		fail("BCAST_E_INPUT_GIT")
	end
	local output = result.stdout
	local paths = {}
	local seen = {}
	local start = 1
	while start <= #output do
		local ending = string.find(output, "\0", start, true)
		if ending == nil then fail("BCAST_E_INPUT_GIT") end
		local path = string.sub(output, start, ending - 1)
		if #path == 0 or seen[path] or relativePath("", path) ~= path then fail("BCAST_E_INPUT_GIT") end
		seen[path] = true
		table.insert(paths, path)
		if #paths > MAX_FILES then fail("BCAST_E_INPUT_LIMIT") end
		start = ending + 1
	end
	if #paths == 0 then fail("BCAST_E_INPUT_GIT") end
	table.sort(paths)
	return paths
end

local function sourceIdentity(root: string, surface: any, execute: any, hash: any): any
	local entries = {}
	local count = 0
	local total = 0
	local function add(path: string)
		if entries[path] ~= nil then return end
		count += 1
		if count > MAX_FILES then fail("BCAST_E_INPUT_LIMIT") end
		local body = fileBytes(surface, root .. "/" .. path)
		total += #body
		if total > MAX_SOURCE_BYTES then fail("BCAST_E_INPUT_LIMIT") end
		entries[path] = digest({ bytes = body }, hash, "RelayStudyFile:1")
	end
	for _, path in trackedPaths(root, execute) do add(path) end
	local projectBody = fileBytes(surface, root .. "/benchmarks/event-v1.project.json")
	local decodedOk, project = pcall(serde.decode, "json", projectBody)
	if not decodedOk or type(project) ~= "table" then fail("BCAST_E_INPUT_PROJECT") end
	local visited = {}
	local scannedFileParents = {}
	local function rejectNestedProject(path: string)
		if string.match(string.lower(path), "%.project%.json$") then fail("BCAST_E_INPUT_PROJECT") end
	end
	local function scanFileSiblings(path: string)
		local parent = string.match(path, "^(.*)/[^/]+$")
		if parent == nil or scannedFileParents[parent] then return end
		scannedFileParents[parent] = true
		local ok, names = pcall(surface.readDir, root .. "/" .. parent)
		if not ok or type(names) ~= "table" then fail("BCAST_E_INPUT_FILE") end
		for _, name in names do
			if type(name) ~= "string" or #name == 0 or name == "." or name == ".."
				or string.find(name, "/", 1, true) or string.find(name, "\\", 1, true)
			then fail("BCAST_E_INPUT_PATH") end
			local sibling = relativePath(parent, name)
			if surface.isFile(root .. "/" .. sibling) then
				rejectNestedProject(sibling)
				add(sibling)
			end
		end
	end
	local function scan(path: string, depth: number)
		if depth > 32 or visited[path] then fail("BCAST_E_INPUT_PROJECT") end
		visited[path] = true
		local absolute = root .. "/" .. path
		if surface.isFile(absolute) then
			rejectNestedProject(path)
			add(path)
			scanFileSiblings(path)
			return
		end
		if not surface.isDir(absolute) then fail("BCAST_E_INPUT_FILE") end
		local ok, names = pcall(surface.readDir, absolute)
		if not ok or type(names) ~= "table" then fail("BCAST_E_INPUT_FILE") end
		table.sort(names)
		for _, name in names do
			if type(name) ~= "string" or #name == 0 or name == "." or name == ".."
				or string.find(name, "/", 1, true) or string.find(name, "\\", 1, true)
			then fail("BCAST_E_INPUT_PATH") end
			scan(relativePath(path, name), depth + 1)
		end
	end
	local function projectPaths(node: any, depth: number)
		if depth > 32 then fail("BCAST_E_INPUT_PROJECT") end
		if type(node) ~= "table" then return end
		for key, child in node do
			if key == "$path" then
				if type(child) ~= "string" then fail("BCAST_E_INPUT_PROJECT") end
				local path = relativePath("benchmarks", child)
				if not visited[path] then scan(path, 0) end
			else
				projectPaths(child, depth + 1)
			end
		end
	end
	projectPaths(project, 0)
	return { files = count, sha256 = digest(entries, hash, "RelayStudySource:1") }
end

local function toolIdentity(root: string, surface: any, execute: any, hash: any, toolRoot: string, resolver: string): any
	local config = fileBytes(surface, root .. "/rokit.toml")
	local tools = {}
	for _, name in { "lune", "rojo" } do
		local pin = string.match("\n" .. config, "\n" .. name .. '%s*=%s*"([^"\n]+)"')
		local owner, repository, version = nil, nil, nil
		if pin ~= nil then
			owner, repository, version = string.match(pin, "^([%w%-]+)/([%w%-]+)@([%w%.%-]+)$")
		end
		if owner == nil or repository ~= name or version == nil then fail("BCAST_E_INPUT_TOOL") end
		local binary = toolRoot .. "/tool-storage/" .. owner .. "/" .. repository .. "/" .. version .. "/" .. name .. ".exe"
		local shim = toolRoot .. "/bin/" .. name .. ".exe"
		local resolvedOk, resolved = pcall(execute, resolver, { name }, { cwd = root })
		local first = if resolvedOk and type(resolved) == "table" and resolved.ok == true
			and type(resolved.stdout) == "string" then string.match(resolved.stdout, "^([^\r\n]+)") else nil
		if first == nil or string.lower(string.gsub(first, "\\", "/")) ~= string.lower(shim) then
			fail("BCAST_E_INPUT_TOOL")
		end
		local ok, result = pcall(execute, name, { "--version" }, { cwd = root })
		if not ok or type(result) ~= "table" or result.ok ~= true or type(result.stdout) ~= "string"
			or string.find(result.stdout, version, 1, true) == nil
		then fail("BCAST_E_INPUT_TOOL") end
		tools[name] = digest({ binary = fileBytes(surface, binary), shim = fileBytes(surface, shim),
			resolver = fileBytes(surface, resolver), resolved = first,
			pin = pin, reportedVersion = result.stdout }, hash, "RelayStudyTool:1")
	end
	return { sha256 = digest(tools, hash, "RelayStudyTools:1"), lune = tools.lune, rojo = tools.rojo }
end

local function collect(options: any, studyPlan: any, dependencies: any?): any
	local deps = dependencies or {}
	local surface = deps.fs or fs
	local execute = deps.execute or process.exec
	local hash = deps.hash or serde.hash
	local toolRoot = deps.toolRoot or process.env.ROKIT_HOME
		or (if process.env.USERPROFILE == nil then nil else process.env.USERPROFILE .. "/.rokit")
	local systemRoot = deps.systemRoot or process.env.SystemRoot
	if options.os ~= "windows" or type(toolRoot) ~= "string" or #toolRoot == 0
		or type(systemRoot) ~= "string" or #systemRoot == 0 then fail("BCAST_E_INPUT_TOOL") end
	local baseline = sourceIdentity(options.baseline, surface, execute, hash)
	local candidate = if options.candidate == nil then nil else sourceIdentity(options.candidate, surface, execute, hash)
	local normalizedToolRoot = string.gsub(toolRoot, "\\", "/")
	local normalizedSystemRoot = string.gsub(systemRoot, "\\", "/")
	local resolver = string.gsub(normalizedSystemRoot, "/+$", "") .. "/System32/where.exe"
	local baselineTools = toolIdentity(options.baseline, surface, execute, hash, normalizedToolRoot, resolver)
	local candidateTools = if options.candidate == nil then nil
		else toolIdentity(options.candidate, surface, execute, hash, normalizedToolRoot, resolver)
	local tools = { baseline = baselineTools, candidate = candidateTools,
		sha256 = digest({ baseline = baselineTools.sha256,
			candidate = if candidateTools == nil then "none" else candidateTools.sha256 }, hash, "RelayStudyAllTools:1") }
	local planSha256 = digest({ bytes = serde.encode("json", studyPlan) }, hash, "RelayStudyPlan:1")
	local studioIdentity = deps.studioIdentity
	local studioSha256 = if studioIdentity == nil
		then "sha256:" .. hash("sha256", fileBytes(surface, options.studio))
		else studioIdentity.sha256
	if not isDigest(studioSha256) then
		fail("BCAST_E_INPUT_STUDIO")
	end
	local entries = { baseline = baseline.sha256, baselineFiles = tostring(baseline.files),
		candidate = if candidate == nil then "none" else candidate.sha256,
		candidateFiles = if candidate == nil then "none" else tostring(candidate.files),
		tools = tools.sha256, plan = planSha256, studio = studioSha256 }
	return { version = 1, baseline = baseline, candidate = candidate, tools = tools,
		planSha256 = planSha256, studioSha256 = studioSha256,
		sha256 = digest(entries, hash, "RelayStudyInputManifest:1") }
end

local function verify(manifest: any, hash: any): boolean
	if type(manifest) ~= "table" or manifest.version ~= 1 or not isDigest(manifest.sha256)
		or type(manifest.baseline) ~= "table" or not isDigest(manifest.baseline.sha256)
		or type(manifest.baseline.files) ~= "number" or manifest.baseline.files < 1
		or manifest.baseline.files > MAX_FILES
		or manifest.baseline.files % 1 ~= 0 or not isDigest(manifest.planSha256)
		or not isDigest(manifest.studioSha256) or type(manifest.tools) ~= "table"
	then return false end
	if manifest.candidate ~= nil and (type(manifest.candidate) ~= "table"
		or not isDigest(manifest.candidate.sha256) or type(manifest.candidate.files) ~= "number"
		or manifest.candidate.files < 1 or manifest.candidate.files > MAX_FILES
		or manifest.candidate.files % 1 ~= 0) then return false end
	local tools = manifest.tools
	local function validToolchain(value: any): boolean
		return type(value) == "table" and isDigest(value.sha256) and isDigest(value.lune) and isDigest(value.rojo)
			and value.sha256 == digest({ lune = value.lune, rojo = value.rojo }, hash, "RelayStudyTools:1")
	end
	if (manifest.candidate ~= nil) ~= (tools.candidate ~= nil)
		or not validToolchain(tools.baseline) or (tools.candidate ~= nil and not validToolchain(tools.candidate))
		or not isDigest(tools.sha256)
	then return false end
	local candidateToolHash = if tools.candidate == nil then "none" else tools.candidate.sha256
	if tools.sha256 ~= digest({ baseline = tools.baseline.sha256, candidate = candidateToolHash },
		hash, "RelayStudyAllTools:1") then return false end
	return manifest.sha256 == digest({ baseline = manifest.baseline.sha256,
		baselineFiles = tostring(manifest.baseline.files),
		candidate = if manifest.candidate == nil then "none" else manifest.candidate.sha256,
		candidateFiles = if manifest.candidate == nil then "none" else tostring(manifest.candidate.files),
		tools = tools.sha256, plan = manifest.planSha256, studio = manifest.studioSha256 },
		hash, "RelayStudyInputManifest:1")
end

return table.freeze({ collect = collect, verify = verify })
