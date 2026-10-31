local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local function absolute(path)
	return string.sub(path, 1, 1) == "/" or string.sub(path, 1, 2) == "\\\\"
		or string.match(path, "^%a:[/\\\\]") ~= nil
end

local function clean(path)
	local value = string.gsub(path, "\\", "/")
	while #value > 1 and string.sub(value, -1) == "/" do value = string.sub(value, 1, -2) end
	return value
end

local function sourceDirectory()
	local source = clean(debug.info(1, "s"))
	if not absolute(source) then source = clean(process.cwd .. "/" .. source) end
	return string.match(source, "^(.*)/[^/]+$") or source
end

local GUARD = sourceDirectory() .. "/PathGuard.ps1"

local function windowsResolve(base, requests)
	local result = process.exec("powershell.exe", {
		"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", GUARD,
		"-InputJson", serde.encode("json", { base = base, paths = requests }),
	})
	if not result.ok then error("PathGuardFailed: " .. string.gsub(result.stderr, "[\r\n]+$", ""), 2) end
	local decoded = serde.decode("json", result.stdout)
	if type(decoded) ~= "table" or type(decoded.paths) ~= "table" or #decoded.paths ~= #requests then
		error("PathGuardFailed: invalid guard response", 2)
	end
	return decoded.paths
end

local function unixResolve(base, requests)
	local output = {}
	for index, request in requests do
		local candidate = if absolute(request.path) then request.path else base .. "/" .. request.path
		local prefix = if string.sub(candidate, 1, 1) == "/" then "/" else ""
		local segments = {}
		for segment in string.gmatch(candidate, "[^/\\\\]+") do
			if segment == ".." then
				if #segments > 0 then table.remove(segments) end
			elseif segment ~= "." then
				table.insert(segments, segment)
			end
		end
		local resolved = prefix .. table.concat(segments, "/")
		local current = prefix
		for segmentIndex, segment in segments do
			current = if current == "" or current == "/" then current .. segment else current .. "/" .. segment
			local ok, metadata = pcall(fs.metadata, current)
			if ok and metadata.kind == "symlink" then error("UnsupportedReparsePath: " .. current, 2) end
			if request.mustExist and (not ok or not metadata.exists) then error("MissingPath: " .. current, 2) end
			if segmentIndex < #segments and ok and metadata.kind == "file" then error("InvalidPath: parent is a file", 2) end
		end
		if resolved == "" then resolved = "." end
		table.insert(output, resolved)
	end
	return output
end

local function resolveMany(base, requests)
	assert(type(base) == "string" and absolute(base), "base must be an absolute path")
	assert(type(requests) == "table", "requests must be an array")
	for _, request in requests do
		assert(type(request) == "table" and type(request.path) == "string" and request.path ~= ""
			and not string.find(request.path, "%c"), "invalid path request")
	end
	if process.os == "windows" then return windowsResolve(base, requests) end
	return unixResolve(base, requests)
end

local function resolve(path, base, mustExist)
	local found = resolveMany(base or process.cwd, { { path = path, mustExist = mustExist == true } })
	return found[1]
end

local function within(path, root)
	local child, parent = clean(path), clean(root)
	if process.os == "windows" then child, parent = string.lower(child), string.lower(parent) end
	return child == parent or string.sub(child, 1, #parent + 1) == parent .. "/"
end

local function directory(path)
	local value = clean(path)
	return string.match(value, "^(.*)/[^/]+$") or value
end

return table.freeze({ resolve = resolve, resolveMany = resolveMany, within = within, directory = directory })
