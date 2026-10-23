local process = require("@lune/process")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")
local Budget = require("./analyze-schema-budget-core")

local USAGE = "Usage: lune run scripts/analyze-schema-budget.luau <spec.luau> <workload.luau> [--json] [--max-bytes-per-second <number>]"

local function diagnostic(code, path, message)
	return { severity = "error", code = code, path = path, message = message }
end

local function absolutePath(path)
	return string.sub(path, 1, 1) == "/"
		or string.sub(path, 1, 2) == "\\\\"
		or string.match(path, "^%a:[/\\]") ~= nil
end

local function loadModule(path)
	local modulePath = string.gsub(path, "\\", "/")
	while string.sub(modulePath, 1, 2) == "./" do modulePath = string.sub(modulePath, 3) end
	modulePath = string.gsub(modulePath, "%.luau$", "")
	return require("../" .. modulePath)
end

local function loadTable(path, label)
	if absolutePath(path) then
		return nil, diagnostic("AbsolutePathUnsupported", label, "input paths must be relative to the repository root")
	end
	local ok, value = pcall(loadModule, path)
	if not ok then
		local message = string.match(tostring(value), "^([^\r\n]+)") or "module could not be loaded"
		return nil, diagnostic("ModuleLoadFailed", label, message)
	end
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil, diagnostic("InvalidModuleResult", label, "module must return a plain table")
	end
	return value
end

local function sortedDiagnostics(diagnostics)
	table.sort(diagnostics, function(left, right)
		if left.path == right.path then
			if left.code == right.code then return left.message < right.message end
			return left.code < right.code
		end
		return left.path < right.path
	end)
end

local function rangeText(value)
	return tostring(value.minimum) .. ".." .. tostring(value.maximum)
end

local function printReadable(report, result)
	print(string.format("%s v%d: bounded Relay buffer estimate in bytes per second",
		report.name, report.version))
	for key, endpoint in result.endpoints do
		local trafficLabel = if endpoint.kind == "request"
			then string.format("%g successful calls/s", endpoint.callsPerSecond)
			else string.format("%g sends/s x %g recipients", endpoint.sendsPerSecond, endpoint.recipients)
		print(string.format("%s (%s, %s): %s",
			key, endpoint.kind, endpoint.path or "RPC success", trafficLabel))
		print("  payload bytes/operation: " .. rangeText(endpoint.payloadBytes)
			.. "; Relay buffer bytes/operation: " .. rangeText(endpoint.relayBufferBytes))
		print("  recipient-weighted payload bytes/s: " .. rangeText(endpoint.payloadBytesPerSecond)
			.. "; Relay buffer bytes/s: " .. rangeText(endpoint.relayBufferBytesPerSecond)
			.. "; Roblox-encoded bytes: Unknown")
	end
	print("Aggregate payload bytes/s: " .. rangeText(result.aggregate.payloadBytesPerSecond))
	print("Aggregate modeled Relay buffer bytes/s: " .. rangeText(result.aggregate.relayBufferBytesPerSecond)
		.. "; Roblox-encoded/physical wire bytes: Unknown")
	if result.budget ~= nil then
		print(string.format("Relay buffer budget <= %g bytes/s: %s",
			result.budget.maximumRelayBufferBytesPerSecond, result.budget.status))
	end
	print(result.limitations)
end

local arguments = process.args
if #arguments == 1 and (arguments[1] == "--help" or arguments[1] == "-h") then
	print(USAGE)
	return
end

local specPath, workloadPath, json, maximumBytesPerSecond, budgetSeen, usageError
local index = 1
while index <= #arguments do
	local argument = arguments[index]
	if argument == "--json" then
		json = true
	elseif argument == "--max-bytes-per-second" then
		local candidate = arguments[index + 1]
		if budgetSeen then
			usageError = "duplicate --max-bytes-per-second option"
		elseif candidate == nil or string.sub(candidate, 1, 2) == "--" then
			usageError = "--max-bytes-per-second requires a number"
		else
			maximumBytesPerSecond = tonumber(candidate)
			if maximumBytesPerSecond == nil then usageError = "budget must be a number" end
			budgetSeen = true
			index += 1
		end
	elseif string.sub(argument, 1, 2) == "--" then
		usageError = "unknown option: " .. argument
	elseif specPath == nil then
		specPath = argument
	elseif workloadPath == nil then
		workloadPath = argument
	else
		usageError = "unexpected argument: " .. argument
	end
	index += 1
end
if specPath == nil and usageError == nil then usageError = "a spec module path is required" end
if workloadPath == nil and usageError == nil then usageError = "a workload module path is required" end

local diagnostics = {}
local definition, result
if usageError ~= nil then
	table.insert(diagnostics, diagnostic("InvalidArguments", "arguments", usageError))
else
	local spec, specError = loadTable(specPath, "spec")
	local workload, workloadError = loadTable(workloadPath, "workload")
	if specError ~= nil then table.insert(diagnostics, specError) end
	if workloadError ~= nil then table.insert(diagnostics, workloadError) end
	if #diagnostics == 0 then
		local defined, token, definitionError = pcall(Definition.define, spec)
		if not defined then
			table.insert(diagnostics, diagnostic("DefinitionFailed", "spec", tostring(token)))
		elseif token == nil then
			local message = tostring(definitionError and definitionError.message or "invalid Relay definition")
			local separator = string.find(message, ": ", 1, true)
			table.insert(diagnostics, diagnostic(definitionError and definitionError.code or "InvalidDefinition",
				if separator then string.sub(message, 1, separator - 1) else "spec",
				if separator then string.sub(message, separator + 2) else message))
		else
			local inspectOk, inspected, inspectError = pcall(Definition.inspect, token)
			if not inspectOk then
				table.insert(diagnostics, diagnostic("InspectionFailed", "spec", tostring(inspected)))
			elseif inspected == nil then
				table.insert(diagnostics, diagnostic(inspectError and inspectError.code or "InvalidDefinition",
					"spec", inspectError and inspectError.message or "could not inspect Relay definition"))
			else
				definition = inspected
				result, diagnostics = Budget.analyze(definition, workload, maximumBytesPerSecond)
			end
		end
	end
end

sortedDiagnostics(diagnostics)
local success = #diagnostics == 0
if json then
	local encoded = serde.encode("json", {
		schemaVersion = 1,
		success = success,
		source = specPath,
		workload = workloadPath,
		definition = definition,
		results = result,
	})
	local encodedDiagnostics = if #diagnostics == 0 then "[]" else serde.encode("json", diagnostics)
	print(string.sub(encoded, 1, -2) .. ",\"diagnostics\":" .. encodedDiagnostics .. "}")
else
	if definition ~= nil and result ~= nil then
		printReadable(definition, result)
	end
	for _, message in diagnostics do
		print(string.upper(message.severity) .. " " .. message.path .. " [" .. message.code .. "]: " .. message.message)
	end
end
if not success then process.exit(1) end
