local process = require("@lune/process")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")
local SchemaCheck = require("./schema-check-core")

local USAGE = "Usage: lune run scripts/check-schema.luau <spec.luau> [--json] [--require-endpoint-rates <inbound-rate.luau>]"

local function diagnostic(code, path, message)
	return { severity = "error", code = code, path = path, message = message }
end

local function loadModule(path)
	local modulePath = string.gsub(path, "\\", "/")
	while string.sub(modulePath, 1, 2) == "./" do modulePath = string.sub(modulePath, 3) end
	modulePath = string.gsub(modulePath, "%.luau$", "")
	return require("../" .. modulePath)
end

local function loadTable(path, label)
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

local arguments = process.args
if #arguments == 1 and (arguments[1] == "--help" or arguments[1] == "-h") then
	print(USAGE)
	return
end

local specPath, ratesPath, json, usageError
local requireRates = false
local index = 1
while index <= #arguments do
	local argument = arguments[index]
	if argument == "--json" then
		json = true
	elseif argument == "--require-endpoint-rates" then
		requireRates = true
		local candidate = arguments[index + 1]
		if candidate == nil or string.sub(candidate, 1, 2) == "--" then
			usageError = "--require-endpoint-rates requires an inbound-rate module path"
		else
			ratesPath = candidate
			index += 1
		end
	elseif string.sub(argument, 1, 2) == "--" then
		usageError = "unknown option: " .. argument
	elseif specPath == nil then
		specPath = argument
	else
		usageError = "unexpected argument: " .. argument
	end
	index += 1
end
if specPath == nil and usageError == nil then usageError = "a spec module path is required" end

local diagnostics = {}
local report
if usageError ~= nil then
	table.insert(diagnostics, diagnostic("InvalidArguments", "arguments", usageError))
elseif specPath ~= nil then
	local spec, loadError = loadTable(specPath, "spec")
	if loadError ~= nil then
		table.insert(diagnostics, loadError)
	else
		report, loadError = SchemaCheck.inspect(Definition, spec)
		if loadError ~= nil then
			table.insert(diagnostics, loadError)
		elseif requireRates then
			local inboundRate, policyError = loadTable(ratesPath, "inboundRate")
			if policyError ~= nil then table.insert(diagnostics, policyError)
			else SchemaCheck.checkEndpointRates(report, inboundRate, diagnostics) end
		end
	end
end

SchemaCheck.sortDiagnostics(diagnostics)
local success = #diagnostics == 0
if json then
	local encoded = serde.encode("json", {
		schemaVersion = 1,
		success = success,
		source = specPath,
		definition = report,
	})
	-- Lune encodes empty tables as objects; diagnostics must remain an array.
	local encodedDiagnostics = if #diagnostics == 0 then "[]" else serde.encode("json", diagnostics)
	print(string.sub(encoded, 1, -2) .. ",\"diagnostics\":" .. encodedDiagnostics .. "}")
else
	if success then
		print(string.format("%s v%d (%s), %d descriptor bytes", report.name, report.version,
			report.protocol, report.descriptorBytes))
	else
		for _, message in diagnostics do
			print(string.upper(message.severity) .. " " .. message.path .. " [" .. message.code .. "]: " .. message.message)
		end
	end
end
if not success then process.exit(1) end
