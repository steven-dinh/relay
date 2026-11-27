local STATUSES = { passed = true, failed = true, running = true, cancelled = true, stale = true,
	unsupported = true, skipped = true, inconclusive = true }
local MAX_BYTES, MAX_DEPTH, MAX_ENTRIES, MAX_DIAGNOSTICS = 4_194_304, 32, 65_536, 256
local PRIORITY = { passed = 0, running = 1, inconclusive = 2, unsupported = 3, cancelled = 4, failed = 5, stale = 6 }

local function short(value, maximum)
	return type(value) == "string" and #value > 0 and #value <= maximum
end

local function boundedText(value, maximum, fallback)
	local text = string.sub(value, 1, maximum)
	local _, invalidAt = utf8.len(text)
	if invalidAt then text = string.sub(text, 1, invalidAt - 1) end
	return if text == "" then fallback else text
end

local function diagnostic(code, path, message, action, severity)
	return { severity = severity or "error", code = boundedText(code, 64, "AnalysisFailed"),
		path = boundedText(path, 512, "project"), message = boundedText(message, 1024, "Project analysis failed."),
		action = boundedText(action or "", 1024, "Correct the reported project input and rerun this command.") }
end

local function limitDiagnostics(rows)
	if #rows <= MAX_DIAGNOSTICS then return rows end
	local limited = table.create(MAX_DIAGNOSTICS)
	table.move(rows, 1, MAX_DIAGNOSTICS - 1, 1, limited)
	local omitted = #rows - MAX_DIAGNOSTICS + 1
	local last = rows[#rows]
	if last.code == "DiagnosticsOmitted" and type(last.omittedCount) == "number" then
		omitted += last.omittedCount - 1
	end
	local summary = diagnostic("DiagnosticsOmitted", "diagnostics", tostring(omitted) .. " additional diagnostics omitted.",
		"Correct the listed issues and rerun to see the remaining diagnostics.", "info")
	summary.omittedCount = omitted
	limited[MAX_DIAGNOSTICS] = summary
	return limited
end

local function markStale(result, issue)
	result.status = "stale"
	if result.children then
		for _, child in result.children do markStale(child, issue) end
	else
		for _, row in result.diagnostics do
			if row.code == issue.code and row.path == issue.path then return end
		end
		table.insert(result.diagnostics, 1, issue)
		result.diagnostics = limitDiagnostics(result.diagnostics)
	end
end

local function workerOperation(command)
	return if command == "verify" then "typescript" elseif command == "test" then "tests" else command
end

local function plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function array(value, maximum)
	if not plain(value) or #value > maximum then return false end
	local count = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
		count += 1
	end
	return count == #value
end

local function aggregateStatus(identity, children, required)
	local indexed = {}
	for _, child in children do
		if indexed[child.operation] then return nil end
		indexed[child.operation] = child
	end
	local seen = {}
	for _, name in required do
		if not short(name, 32) or seen[name] then return nil end
		seen[name] = true
	end
	local status = "passed"
	for _, name in required do
		local child = indexed[name]
		local nextStatus = if child == nil or child.status == "skipped" then "inconclusive" else child.status
		if child and (child.projectId ~= identity.projectId or child.compilerId ~= identity.compilerId
			or child.toolingId ~= identity.toolingId or child.sourceId ~= identity.sourceId
			or child.host ~= identity.host or child.runId ~= identity.runId) then
			nextStatus = "stale"
		end
		if PRIORITY[nextStatus] > PRIORITY[status] then status = nextStatus end
	end
	return status
end

local function bounded(value, depth, active, budget)
	if depth > MAX_DEPTH then return false end
	budget.entries += 1
	if budget.entries > MAX_ENTRIES then return false end
	local kind = type(value)
	if kind == "string" then
		budget.bytes += #value
	elseif kind == "number" then
		if value ~= value or math.abs(value) == math.huge then return false end
	elseif kind == "table" then
		if not plain(value) or active[value] then return false end
		active[value] = true
		for key, child in value do
			if (type(key) ~= "string" and type(key) ~= "number") or not bounded(key, depth + 1, active, budget)
				or not bounded(child, depth + 1, active, budget) then return false end
		end
		active[value] = nil
	elseif kind ~= "boolean" and kind ~= "nil" then
		return false
	end
	return budget.bytes <= MAX_BYTES
end

local function validate(value)
	if not plain(value) or value.schemaVersion ~= 1 or not short(value.operation, 32)
		or not short(value.projectId, 64) or not short(value.compilerId, 256) or not short(value.sourceId, 256)
		or not short(value.toolingId, 256) or not short(value.runId, 128)
		or (value.host ~= "cli" and value.host ~= "studio")
		or not STATUSES[value.status] then return false, "invalid result header" end
	if not plain(value.diagnostics) or #value.diagnostics > MAX_DIAGNOSTICS then return false, "invalid diagnostics" end
	local count = 0
	for index, item in value.diagnostics do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value.diagnostics or not plain(item)
			or not short(item.code, 64) or not short(item.path, 512) or not short(item.message, 1024)
			or not short(item.action, 1024)
			or (item.severity ~= "error" and item.severity ~= "warning" and item.severity ~= "info") then
			return false, "invalid diagnostic row"
		end
		if value.status == "passed" and item.severity == "error" then return false, "passed result contains an error" end
		count += 1
	end
	if not array(value.artifacts, 32) then return false, "invalid artifacts" end
	for _, artifact in value.artifacts do
		if not plain(artifact) or not short(artifact.path, 4096) or not short(artifact.kind, 32)
			or (artifact.digest ~= nil and not short(artifact.digest, 256)) then return false, "invalid artifact row" end
	end
	if count ~= #value.diagnostics or not bounded(value, 0, {}, { bytes = 0, entries = 0 }) then
		return false, "result exceeds data limits"
	end
	if value.children ~= nil or value.required ~= nil then
		if not array(value.children, 16) or not array(value.required, 16) or #value.required == 0 then
			return false, "invalid aggregate checks"
		end
		for _, child in value.children do
			if not plain(child) or child.children ~= nil or child.required ~= nil then return false, "nested aggregate is unsupported" end
			local valid, reason = validate(child)
			if not valid then return false, reason end
		end
		if aggregateStatus(value, value.children, value.required) ~= value.status then return false, "inconsistent aggregate status" end
	end
	return true, nil
end

local function new(operation, identity, status, data, diagnostics, artifacts)
	local result = { schemaVersion = 1, operation = operation, projectId = identity.projectId,
		compilerId = identity.compilerId, toolingId = identity.toolingId, sourceId = identity.sourceId,
		host = identity.host, runId = identity.runId, status = status,
		data = data, diagnostics = diagnostics or {}, artifacts = artifacts or {} }
	local valid, reason = validate(result)
	assert(valid, reason)
	return result
end

local function aggregate(operation, identity, children, required)
	for _, child in children do
		local valid, reason = validate(child)
		assert(valid, reason)
	end
	local status = aggregateStatus(identity, children, required)
	assert(status, "duplicate operation or required check")
	local result = new(operation, identity, status)
	result.children = children
	result.required = table.clone(required)
	local valid, reason = validate(result)
	assert(valid, reason)
	return result
end

local function isCurrent(result, identity)
	return validate(result) and result.projectId == identity.projectId and result.compilerId == identity.compilerId
		and result.toolingId == identity.toolingId and result.sourceId == identity.sourceId
		and result.host == identity.host and result.runId == identity.runId
end

return table.freeze({ new = new, validate = validate, aggregate = aggregate, isCurrent = isCurrent,
	diagnostic = diagnostic, limitDiagnostics = limitDiagnostics, markStale = markStale, workerOperation = workerOperation,
	MAX_BYTES = MAX_BYTES, MAX_DEPTH = MAX_DEPTH, MAX_ENTRIES = MAX_ENTRIES })
