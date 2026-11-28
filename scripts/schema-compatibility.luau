local process = require("@lune/process")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")
local Compatibility = require("./schema-compatibility-core")
local Paths = require("./tooling/Paths")
local ResultJson = require("./tooling/ResultJson")

local USAGE = "Usage: lune run scripts/schema-compatibility.luau <before.luau> <after.luau> [--json]"

local function diagnostic(code, path, message)
	return { code = code, path = path, message = message }
end

local function normalizePath(path, label)
	if type(path) ~= "string" or path == "" then return nil, diagnostic("InvalidPath", label, "must be a repository-relative .luau path") end
	local normalized = string.gsub(path, "\\", "/")
	if string.sub(normalized, 1, 1) == "/" or string.match(normalized, "^%a:") then
		return nil, diagnostic("UnsupportedPath", label, "absolute paths are unsupported; use a repository-relative path")
	end
	local parts = {}
	for part in string.gmatch(normalized, "[^/]+") do
		if part == ".." then
			if #parts == 0 then return nil, diagnostic("UnsupportedPath", label, "path must stay inside the repository") end
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	normalized = table.concat(parts, "/")
	if normalized == "" or not string.match(normalized, "%.luau$") then
		return nil, diagnostic("InvalidPath", label, "must name a .luau module")
	end
	return normalized
end

local function inspectSide(path, label)
	local normalizedPath, pathError = normalizePath(path, label)
	if pathError ~= nil then return { source = path }, pathError end

	local ok, spec = pcall(Paths.loadRepoModule, normalizedPath)
	if not ok then
		local message = string.match(tostring(spec), "^([^\r\n]+)") or "module could not be loaded"
		return { source = normalizedPath }, diagnostic("ModuleLoadFailed", label, message)
	end
	if type(spec) ~= "table" or getmetatable(spec) ~= nil then
		return { source = normalizedPath }, diagnostic("InvalidModuleResult", label, "module must return a plain table")
	end
	return Compatibility.inspect(Definition, spec, normalizedPath, label)
end

local function endpointSummary(endpoint)
	return endpoint.kind .. " " .. endpoint.name .. " (#" .. tostring(endpoint.id) .. ")"
end

local function readableValue(value)
	if value == nil then return "null" end
	return serde.encode("json", Compatibility.forOutput(value))
end

local function printReadable(report)
	print("Status: " .. string.upper(report.status))
	print("Before: " .. tostring(report.before.source))
	print("After:  " .. tostring(report.after.source))
	if report.status == "invalid-input" then
		for _, item in report.diagnostics do
			print("ERROR " .. item.path .. " [" .. item.code .. "]: " .. item.message)
		end
	elseif report.status == "equal" then
		print("Compiled descriptors are identical.")
	else
		print("Requires matched deployment: yes")
		for _, change in report.changes do
			if string.match(change.path, "^endpoints%[%d+%]$") and change.kind ~= "changed" then
				local endpoint = change.after or change.before
				print((if change.kind == "added" then "+ " else "- ") .. endpointSummary(endpoint))
			else
				local prefix = if change.kind == "added" then "+ " elseif change.kind == "removed" then "- " else "~ "
				if change.path == "descriptor" then
					print("~ descriptor: " .. #change.before .. " bytes -> " .. #change.after .. " bytes")
				else
					print(prefix .. change.path .. ": " .. readableValue(change.before) .. " -> " .. readableValue(change.after))
				end
			end
		end
	end
end

local arguments = process.args
if #arguments == 1 and (arguments[1] == "--help" or arguments[1] == "-h") then
	print(USAGE)
	return
end

local json, paths, argumentError = false, {}, nil
for _, argument in arguments do
	if argument == "--json" then
		json = true
	elseif string.sub(argument, 1, 1) == "-" then
		argumentError = "unknown option or unexpected argument: " .. argument
	else
		table.insert(paths, argument)
	end
end
if argumentError == nil and #paths ~= 2 then argumentError = "exactly two schema module paths are required" end

local before, after, diagnostics = { source = paths[1] }, { source = paths[2] }, {}
if argumentError ~= nil then
	table.insert(diagnostics, diagnostic("InvalidArguments", "arguments", argumentError))
else
	local beforeError, afterError
	before, beforeError = inspectSide(paths[1], "before")
	after, afterError = inspectSide(paths[2], "after")
	if beforeError ~= nil then table.insert(diagnostics, beforeError) end
	if afterError ~= nil then table.insert(diagnostics, afterError) end
end
Compatibility.sortDiagnostics(diagnostics)

local valid = #diagnostics == 0
local descriptorEqual = if valid then before.descriptor == after.descriptor else nil
local changes = if valid then Compatibility.compare(before, after) else {}
local report = {
	schemaVersion = 1,
	status = if not valid then "invalid-input" elseif descriptorEqual then "equal" else "changed",
	before = before,
	after = after,
	descriptorEqual = descriptorEqual,
	requiresMatchedDeployment = if valid then not descriptorEqual else nil,
	changes = changes,
	diagnostics = diagnostics,
}

if json then
	print(ResultJson.compatibility(Compatibility.forOutput(report)))
else
	printReadable(report)
end
process.exit(if valid then (if descriptorEqual then 0 else 1) else 2)
