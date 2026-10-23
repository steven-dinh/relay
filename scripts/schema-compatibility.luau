local process = require("@lune/process")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")

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

local function loadModule(path)
	local modulePath = string.gsub(path, "%.luau$", "")
	return require("../" .. modulePath)
end

local function display(value)
	local valueType = type(value)
	if valueType == "table" then
		local result = {}
		for key, child in value do
			result[key] = display(child)
		end
		return result
	elseif valueType == "string" or valueType == "number" or valueType == "boolean" or value == nil then
		return value
	end
	return tostring(value)
end

local function inspectSide(path, label)
	local normalizedPath, pathError = normalizePath(path, label)
	if pathError ~= nil then return { source = path }, pathError end

	local ok, spec = pcall(loadModule, normalizedPath)
	if not ok then
		local message = string.match(tostring(spec), "^([^\r\n]+)") or "module could not be loaded"
		return { source = normalizedPath }, diagnostic("ModuleLoadFailed", label, message)
	end
	if type(spec) ~= "table" or getmetatable(spec) ~= nil then
		return { source = normalizedPath }, diagnostic("InvalidModuleResult", label, "module must return a plain table")
	end

	local defined, token, definitionError = pcall(Definition.define, spec)
	if not defined then
		return { source = normalizedPath }, diagnostic("DefinitionFailed", label, tostring(token))
	elseif token == nil then
		local message = tostring(definitionError and definitionError.message or "invalid Relay definition")
		local separator = string.find(message, ": ", 1, true)
		return { source = normalizedPath }, diagnostic(definitionError and definitionError.code or "InvalidDefinition",
			if separator then label .. "." .. string.sub(message, 1, separator - 1) else label,
			if separator then string.sub(message, separator + 2) else message)
	end

	local compiled = Definition.get(token)
	local inspection, inspectionError = Definition.inspect(token)
	if compiled == nil or inspection == nil then
		return { source = normalizedPath }, diagnostic("InspectionFailed", label,
			inspectionError and inspectionError.message or "could not inspect Relay definition")
	end

	local endpoints = {}
	for name, event in compiled.events do
		local inspected = inspection.events[name]
		endpoints[tostring(event.id)] = {
			id = event.id,
			kind = "event",
			name = name,
			direction = event.direction,
			delivery = if event.ordered == true then "OrderedUnreliable" else event.delivery,
			queue = event.queue,
			timestampWindow = event.timestampWindow,
			fields = display(event.fields),
			inspection = display(inspected),
		}
	end
	for name, method in compiled.requests do
		local inspected = inspection.requests[name]
		endpoints[tostring(method.id)] = {
			id = method.id,
			kind = "request",
			name = name,
			direction = inspected.direction,
			concurrency = inspected.concurrency,
			refusals = inspected.refusals,
			envelopeVersion = inspected.envelopeVersion,
			request = { fields = display(method.request.fields), inspection = display(inspected.request) },
			response = { shape = display(method.response.fields[1]), inspection = display(inspected.response) },
		}
	end

	return {
		source = normalizedPath,
		inspection = display(inspection),
		descriptor = compiled.descriptor,
		metadata = {
			name = compiled.name,
			version = compiled.version,
			protocol = inspection.protocol,
			readiness = inspection.readiness,
			bitPacking = inspection.bitPacking,
			outboundBytes = display(compiled.outboundBytes),
		},
		endpoints = endpoints,
	}, nil
end

local function keyPath(path, key)
	if type(key) == "number" then return path .. "[" .. tostring(key) .. "]" end
	if path == "" then return tostring(key) end
	return path .. "." .. tostring(key)
end

local function sortedKeys(left, right)
	local keys, seen = {}, {}
	for key in left do seen[key] = true; table.insert(keys, key) end
	for key in right do if not seen[key] then table.insert(keys, key) end end
	table.sort(keys, function(a, b)
		if type(a) == "number" and type(b) == "number" then return a < b end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function appendChange(changes, path, before, after)
	local change = { path = path, kind = if before == nil then "added" elseif after == nil then "removed" else "changed" }
	if before ~= nil then change.before = before end
	if after ~= nil then change.after = after end
	table.insert(changes, change)
end

local function diffValue(changes, path, before, after)
	if type(before) == "table" and type(after) == "table" then
		for _, key in sortedKeys(before, after) do
			diffValue(changes, keyPath(path, key), before[key], after[key])
		end
	elseif before ~= after then
		appendChange(changes, path, before, after)
	end
end

local function compare(before, after)
	local changes = {}
	if before.descriptor ~= after.descriptor then
		diffValue(changes, "metadata", before.metadata, after.metadata)
		for _, id in sortedKeys(before.endpoints, after.endpoints) do
			local left, right = before.endpoints[id], after.endpoints[id]
			local path = "endpoints[" .. id .. "]"
			if left == nil or right == nil then appendChange(changes, path, left, right)
			else diffValue(changes, path, left, right) end
		end
		if #changes == 0 then appendChange(changes, "descriptor", before.descriptor, after.descriptor) end
	end
	table.sort(changes, function(left, right) return left.path < right.path end)
	return changes
end

local function sortedDiagnostics(diagnostics)
	table.sort(diagnostics, function(left, right)
		if left.path == right.path then return left.code < right.code end
		return left.path < right.path
	end)
end

local function endpointSummary(endpoint)
	return endpoint.kind .. " " .. endpoint.name .. " (#" .. tostring(endpoint.id) .. ")"
end

local function readableValue(value)
	if value == nil then return "null" end
	return serde.encode("json", value)
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
sortedDiagnostics(diagnostics)

local valid = #diagnostics == 0
local descriptorEqual = if valid then before.descriptor == after.descriptor else nil
local changes = if valid then compare(before, after) else {}
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
	local encoded = serde.encode("json", report)
	encoded = string.gsub(encoded, '"changes":{}', '"changes":[]')
	encoded = string.gsub(encoded, '"diagnostics":{}', '"diagnostics":[]')
	print(encoded)
else
	printReadable(report)
end
process.exit(if valid then (if descriptorEqual then 0 else 1) else 2)
