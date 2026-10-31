-- Host-neutral project configuration. Hosts own actual path resolution and loading.
local OPERATIONS = { schema = true, policy = true, compat = true, budget = true, tests = true, typescript = true }
local KEYS = { schemaVersion = true, id = true, schema = true, policy = true, workload = true,
	baseline = true, maxBytesPerSecond = true, tests = true, typescript = true, required = true }

local function problem(path, message)
	return { code = "InvalidProject", severity = "error", path = path, message = message }
end

local function relativePath(value, extension)
	if type(value) ~= "string" or #value == 0 or #value > 1024 or string.find(value, "%c")
		or string.find(value, ":", 1, true) then return nil end
	value = string.gsub(value, "\\", "/")
	if string.sub(value, 1, 1) == "/" then return nil end
	local parts = {}
	for part in string.gmatch(value, "[^/]+") do
		if part == ".." then
			if #parts == 0 then return nil end
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	local normalized = table.concat(parts, "/")
	if normalized == "" or (extension and string.sub(normalized, -#extension) ~= extension) then return nil end
	return normalized
end

local function array(value, maximum)
	if type(value) ~= "table" or getmetatable(value) ~= nil or #value > maximum then return false end
	local count = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
		count += 1
	end
	return count == #value
end

local function validate(value)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil, problem("project", "must be a plain object") end
	for key in value do
		if not KEYS[key] then return nil, problem("project", "unknown configuration field: " .. tostring(key)) end
	end
	if value.schemaVersion ~= 1 then return nil, problem("schemaVersion", "expected project schemaVersion 1") end
	if type(value.id) ~= "string" or #value.id > 64 or not string.match(value.id, "^[A-Za-z][A-Za-z0-9_.%-]*$") then
		return nil, problem("id", "must be a 1..64-byte ASCII identifier beginning with a letter")
	end
	local project = { schemaVersion = 1, id = value.id }
	for _, key in { "schema", "policy", "workload", "baseline", "typescript" } do
		if key == "schema" or value[key] ~= nil then
			local normalized = relativePath(value[key], if key == "typescript" then ".d.ts" else ".luau")
			if normalized == nil then return nil, problem(key, "must name a relative project file without escaping its root") end
			project[key] = normalized
		end
	end
	if value.maxBytesPerSecond ~= nil then
		local maximum = value.maxBytesPerSecond
		if type(maximum) ~= "number" or maximum ~= maximum or maximum < 0 or maximum == math.huge or project.workload == nil then
			return nil, problem("maxBytesPerSecond", "requires workload and a finite non-negative number")
		end
		project.maxBytesPerSecond = maximum
	end
	if value.tests ~= nil then
		if not array(value.tests, 32) then return nil, problem("tests", "must be an array of at most 32 scenario paths") end
		project.tests = {}
		local seen = {}
		for index, path in value.tests do
			local normalized = relativePath(path, ".luau")
			if normalized == nil or seen[normalized] then return nil, problem("tests[" .. index .. "]", "must name a unique relative .luau file") end
			seen[normalized] = true
			table.insert(project.tests, normalized)
		end
	end
	local required = value.required
	if required == nil then
		required = { "schema" }
		for _, pair in { { "policy", project.policy }, { "compat", project.baseline }, { "budget", project.workload } } do
			if pair[2] ~= nil then table.insert(required, pair[1]) end
		end
	elseif not array(required, 6) or #required == 0 then
		return nil, problem("required", "must be a nonempty array of at most six check names")
	end
	project.required = {}
	local seen = {}
	for index, operation in required do
		if not OPERATIONS[operation] or seen[operation] then
			return nil, problem("required[" .. index .. "]", "unknown or repeated check name")
		end
		local input = if operation == "compat" then project.baseline elseif operation == "budget" then project.workload
			elseif operation == "policy" then project.policy elseif operation == "typescript" then project.typescript
			elseif operation == "tests" then project.tests and #project.tests > 0 else true
		if not input then return nil, problem("required[" .. index .. "]", operation .. " requires its configured input") end
		seen[operation] = true
		table.insert(project.required, operation)
	end
	if not seen.schema then return nil, problem("required", "schema is always a required check") end
	return project, nil
end

return table.freeze({ validate = validate, relativePath = relativePath })
