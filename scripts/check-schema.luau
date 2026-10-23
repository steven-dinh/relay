local process = require("@lune/process")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")

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

local function bucketIsValid(value)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for key in value do
		if key ~= "capacity" and key ~= "refillPerSecond" then return false end
	end
	local capacity, refill = value.capacity, value.refillPerSecond
	return type(capacity) == "number" and capacity % 1 == 0 and capacity >= 1 and capacity <= 4096
		and type(refill) == "number" and refill == refill and math.abs(refill) ~= math.huge
		and refill > 0 and refill <= 2048
end

local function checkEndpointRates(report, inboundRate, diagnostics)
	local expected = {}
	for name, endpoint in report.events do
		if endpoint.direction == "ClientToServer" then
			expected[endpoint.id] = "events." .. name
		end
	end
	for name, endpoint in report.requests do
		if endpoint.direction == "ClientToServer" then
			expected[endpoint.id] = "requests." .. name
		end
	end

	local configured = inboundRate.endpoints
	if configured ~= nil and (type(configured) ~= "table" or getmetatable(configured) ~= nil) then
		table.insert(diagnostics, diagnostic("InvalidEndpointRates", "inboundRate.endpoints",
			"must be a plain table keyed by client-to-server endpoint ID"))
		return
	end
	configured = configured or {}

	for id, endpointPath in expected do
		if not bucketIsValid(configured[id]) then
			local present = configured[id] ~= nil
			table.insert(diagnostics, diagnostic(if present then "InvalidEndpointRate" else "MissingEndpointRate",
				"inboundRate.endpoints[" .. id .. "]",
				(if present then endpointPath .. " requires " else endpointPath .. " has no ")
					.. "valid bucket (integer capacity 1..4096 and positive refillPerSecond at most 2048)"))
		end
	end

	local ids = {}
	for id in configured do
		if type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 65_535 then
			table.insert(diagnostics, diagnostic("InvalidEndpointRateId", "inboundRate.endpoints",
				"endpoint keys must be integer IDs from 1 to 65535"))
			return
		end
		table.insert(ids, id)
	end
	for _, id in ids do
		if expected[id] == nil then
			table.insert(diagnostics, diagnostic("UnexpectedEndpointRate", "inboundRate.endpoints[" .. id .. "]",
				"ID does not identify a client-to-server event or request in this schema"))
		end
	end
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
		local defined, definition, definitionError = pcall(Definition.define, spec)
		if not defined then
			table.insert(diagnostics, diagnostic("DefinitionFailed", "spec", tostring(definition)))
		elseif definition == nil then
			local message = tostring(definitionError and definitionError.message or "invalid Relay definition")
			local separator = string.find(message, ": ", 1, true)
			table.insert(diagnostics, diagnostic(definitionError and definitionError.code or "InvalidDefinition",
				if separator then string.sub(message, 1, separator - 1) else "spec",
				if separator then string.sub(message, separator + 2) else message))
		else
			local inspected, inspectionError = Definition.inspect(definition)
			if inspected == nil then
				table.insert(diagnostics, diagnostic(inspectionError and inspectionError.code or "InvalidDefinition",
					"spec", inspectionError and inspectionError.message or "could not inspect Relay definition"))
			else
				report = inspected
				if requireRates then
					local inboundRate, policyError = loadTable(ratesPath, "inboundRate")
					if policyError ~= nil then table.insert(diagnostics, policyError)
					else checkEndpointRates(report, inboundRate, diagnostics) end
				end
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
