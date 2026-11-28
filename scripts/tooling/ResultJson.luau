local serde = require("@lune/serde")

-- Lune represents both empty JSON objects and arrays as a plain empty table.
local function array(value)
	return if next(value) == nil then "[]" else serde.encode("json", value)
end

local function mapArray(values, encode)
	local parts = {}
	for index, value in values do parts[index] = encode(value) end
	return "[" .. table.concat(parts, ",") .. "]"
end

local function object(value, fields)
	local parts = {}
	for key, child in value do
		local encode = fields[key]
		local bytes = if encode then encode(child) else serde.encode("json", child)
		table.insert(parts, serde.encode("json", key) .. ":" .. bytes)
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

local function project(value)
	return object(value, { tests = array, required = array })
end

local function compiled(value)
	-- Endpoint tuples and nested struct shapes both store ordered lists under fields.
	local bytes = serde.encode("json", value)
	return (string.gsub(bytes, '"fields":{}', '"fields":[]'))
end

local function compatibleSchema(value)
	return object(value, { endpoints = compiled })
end

local function changes(values)
	return mapArray(values, function(change)
		local encode = if string.match(change.path, "%.fields$") then function(fields)
			return if next(fields) == nil then "[]" else compiled(fields)
		end else compiled
		return object(change, { before = encode, after = encode })
	end)
end

local compatibilityFields = { changes = changes, before = compatibleSchema, after = compatibleSchema, diagnostics = array }

local dataFields = {
	check = { project = project },
	["ts-check"] = { project = project },
	compat = compatibilityFields,
	tests = { cases = array },
	typescriptCompiler = { sourceFiles = array, configFiles = array, outputs = array, diagnostics = array, unsupported = array },
}

local function result(value)
	local fields = { diagnostics = array, artifacts = array, required = array,
		children = function(children) return mapArray(children, result) end }
	local data = dataFields[value.operation]
	if data then fields.data = function(item) return object(item, data) end end
	return object(value, fields)
end

local function worker(value)
	return object(value, { result = result, sourcePaths = array, missingPaths = array })
end

return table.freeze({ result = result, worker = worker,
	compatibility = function(value) return object(value, compatibilityFields) end })
