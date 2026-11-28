local function diagnostic(code, path, message)
	return { code = code, path = path, message = message }
end

local function display(value, encodeBytes)
	local valueType = type(value)
	if valueType == "table" then
		local result = {}
		for key, child in value do
			result[key] = display(child, encodeBytes)
		end
		return result
	elseif encodeBytes and valueType == "string" and utf8.len(value) == nil then
		local bytes = string.gsub(value, ".", function(byte) return string.format("%02x", string.byte(byte)) end)
		return { encoding = "hex", bytes = bytes }
	elseif valueType == "string" or valueType == "number" or valueType == "boolean" or value == nil then
		return value
	end
	return tostring(value)
end

local function inspectDefinition(Definition, token, inspection, source, label)
	local compiled = Definition.get(token)
	if compiled == nil then
		return { source = source }, diagnostic("InspectionFailed", label, "could not inspect Relay definition")
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
		source = source,
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

local function inspect(Definition, spec, source, label)
	local function failed(code, path, message)
		return { source = source }, diagnostic(code, path, message)
	end

	local defined, token, definitionError = pcall(Definition.define, spec)
	if not defined then
		return failed("DefinitionFailed", label, tostring(token))
	elseif token == nil then
		local message = tostring(definitionError and definitionError.message or "invalid Relay definition")
		local separator = string.find(message, ": ", 1, true)
		return failed(definitionError and definitionError.code or "InvalidDefinition",
			if separator then label .. "." .. string.sub(message, 1, separator - 1) else label,
			if separator then string.sub(message, separator + 2) else message)
	end

	local inspection, inspectionError = Definition.inspect(token)
	if inspection == nil then
		return failed("InspectionFailed", label,
			inspectionError and inspectionError.message or "could not inspect Relay definition")
	end
	return inspectDefinition(Definition, token, inspection, source, label)
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

local function sortDiagnostics(diagnostics)
	table.sort(diagnostics, function(left, right)
		if left.path == right.path then return left.code < right.code end
		return left.path < right.path
	end)
end

return table.freeze({
	inspect = inspect,
	inspectDefinition = inspectDefinition,
	compare = compare,
	sortDiagnostics = sortDiagnostics,
	forOutput = function(value) return display(value, true) end,
})
