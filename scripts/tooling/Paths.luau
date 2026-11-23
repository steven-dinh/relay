local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local MAX_GUARD_LINE_BYTES, MAX_GUARD_LOG_BYTES = 1_048_576, 16_384

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

local function validateRequests(base, requests)
	assert(type(base) == "string" and absolute(base), "base must be an absolute path")
	assert(type(requests) == "table", "requests must be an array")
	for _, request in requests do
		assert(type(request) == "table" and type(request.path) == "string" and request.path ~= ""
			and not string.find(request.path, "%c"), "invalid path request")
	end
	return true
end

local function createWindowsGuard()
	local child = process.create("powershell.exe", {
		"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", GUARD, "-Persistent",
	})
	local state = { buffer = "", stderr = "", stderrDone = false, status = nil, closed = false }
	task.spawn(function()
		while true do
			local chunk = child.stderr:read(1024)
			if chunk == nil then break end
			local remaining = MAX_GUARD_LOG_BYTES - #state.stderr
			if remaining > 0 then state.stderr ..= string.sub(chunk, 1, remaining) end
		end
		state.stderrDone = true
	end)
	local function exited()
		if state.status == nil then state.status = child:status() end
		while not state.stderrDone do task.wait(0.01) end
		return `guard process exited ({state.status.code}): {state.stderr}`
	end
	local function stop()
		state.closed = true
		pcall(function() child:kill() end)
		pcall(function() state.status = child:status() end)
		while not state.stderrDone do task.wait(0.01) end
	end
	local function readLine()
		while true do
			local ending = string.find(state.buffer, "\n", 1, true)
			if ending then
				if ending - 1 > MAX_GUARD_LINE_BYTES then
					stop()
					error("PathGuardFailed: response line exceeds its byte limit", 2)
				end
				local line = string.sub(state.buffer, 1, ending - 1)
				state.buffer = string.sub(state.buffer, ending + 1)
				if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
				return line
			end
			if #state.buffer > MAX_GUARD_LINE_BYTES then
				stop()
				error("PathGuardFailed: response line exceeds its byte limit", 2)
			end
			local chunk = child.stdout:read(1024)
			if chunk == nil then error("PathGuardFailed: " .. exited(), 2) end
			state.buffer ..= chunk
		end
	end
	local function resolveMany(base, requests)
		assert(not state.closed, "PathGuardFailed: resolver is closed")
		validateRequests(base, requests)
		local encoded = serde.encode("json", { base = base, paths = requests })
		assert(#encoded <= MAX_GUARD_LINE_BYTES, "PathGuardFailed: request line exceeds its byte limit")
		local wrote, writeIssue = pcall(function() child.stdin:write(encoded .. "\n") end)
		if not wrote then error("PathGuardFailed: " .. tostring(writeIssue), 2) end
		local decodedOk, decoded = pcall(serde.decode, "json", readLine())
		if not decodedOk then error("PathGuardFailed: invalid guard response", 2) end
		if type(decoded) == "table" and type(decoded.error) == "string" then
			error("PathGuardFailed: " .. decoded.error, 2)
		end
		if type(decoded) ~= "table" or type(decoded.paths) ~= "table" or #decoded.paths ~= #requests then
			error("PathGuardFailed: invalid guard response", 2)
		end
		return decoded.paths
	end
	local function close()
		if state.closed then return end
		state.closed = true
		local closed, closeIssue = pcall(function() child.stdin:close() end)
		if not closed then pcall(function() child:kill() end) end
		local statusOk, status = pcall(function()
			if state.status == nil then state.status = child:status() end
			return state.status
		end)
		if not closed or not statusOk or not status.ok then
			pcall(function() child:kill() end)
			pcall(function() state.status = child:status() end)
			if statusOk then status = state.status end
			while not state.stderrDone do task.wait(0.01) end
			error("PathGuardFailed: resolver shutdown failed: " .. tostring(closeIssue or (status and status.code) or status), 2)
		end
		while not state.stderrDone do task.wait(0.01) end
	end
	local function resolve(path, base, mustExist)
		local found = resolveMany(base or process.cwd, { { path = path, mustExist = mustExist == true } })
		return found[1]
	end
	return table.freeze({ resolve = resolve, resolveMany = resolveMany, close = close })
end

local function windowsResolve(base, requests)
	local guard = createWindowsGuard()
	local ok, resolved = pcall(guard.resolveMany, base, requests)
	local closed, closeProblem = pcall(guard.close)
	if not ok then
		if not closed then resolved = tostring(resolved) .. "\n" .. tostring(closeProblem) end
		error(resolved, 2)
	end
	if not closed then error(closeProblem, 2) end
	return resolved
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
	validateRequests(base, requests)
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

local function createGuard()
	if process.os == "windows" then return createWindowsGuard() end
	return table.freeze({ resolve = resolve, resolveMany = resolveMany, close = function() end })
end

local function loadRepoModule(path)
	local modulePath = string.gsub(path, "\\", "/")
	while string.sub(modulePath, 1, 2) == "./" do modulePath = string.sub(modulePath, 3) end
	if string.sub(modulePath, -5) == ".luau" then
		assert(fs.isFile(sourceDirectory() .. "/../../" .. modulePath), "module file not found: " .. path)
		modulePath = string.sub(modulePath, 1, -6)
	end
	-- Lune rejects ambiguous siblings and resolves imports relative to the loaded module.
	return require("../../" .. modulePath)
end

return table.freeze({ resolve = resolve, resolveMany = resolveMany, createGuard = createGuard,
	within = within, directory = directory, loadRepoModule = loadRepoModule })
