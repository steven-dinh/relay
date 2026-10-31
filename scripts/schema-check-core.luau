local function diagnostic(code, path, message)
	return { severity = "error", code = code, path = path, message = message }
end

local function inspect(Definition, spec)
	local defined, definition, definitionError = pcall(Definition.define, spec)
	if not defined then
		return nil, diagnostic("DefinitionFailed", "spec", tostring(definition))
	elseif definition == nil then
		local message = tostring(definitionError and definitionError.message or "invalid Relay definition")
		local separator = string.find(message, ": ", 1, true)
		return nil, diagnostic(definitionError and definitionError.code or "InvalidDefinition",
			if separator then string.sub(message, 1, separator - 1) else "spec",
			if separator then string.sub(message, separator + 2) else message)
	end

	local inspection, inspectionError = Definition.inspect(definition)
	if inspection == nil then
		return nil, diagnostic(inspectionError and inspectionError.code or "InvalidDefinition",
			"spec", inspectionError and inspectionError.message or "could not inspect Relay definition")
	end
	return inspection
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

local function checkEndpointRates(report, policy, diagnostics)
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

	local configured = policy.endpoints
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

local function sortDiagnostics(diagnostics)
	table.sort(diagnostics, function(left, right)
		if left.path == right.path then
			if left.code == right.code then return left.message < right.message end
			return left.code < right.code
		end
		return left.path < right.path
	end)
end

return table.freeze({
	inspect = inspect,
	checkEndpointRates = checkEndpointRates,
	sortDiagnostics = sortDiagnostics,
})
