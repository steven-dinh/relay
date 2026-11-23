local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local Paths = require("./Paths")
local Project = require("./Project")
local Result = require("./Result")
local ResultJson = require("./ResultJson")
local Identity = require("./Identity")
local Fingerprint = require("../../benchmarks/host/MeasurementFingerprint")
local Definition = require("../../src/Definition")
local Schema = require("../../src/Schema")
local SchemaCheck = require("../schema-check-core")
local Compatibility = require("../schema-compatibility-core")
local Budget = require("../analyze-schema-budget-core")

local SOURCE_DOMAIN = "RelayToolsProjectSource:2"
local MAX_SOURCE_FILES, MAX_SOURCE_BYTES = 256, 4_194_304

local function readBounded(path, maximum)
	assert(fs.metadata(path).size <= maximum, "file exceeds its byte limit: " .. path)
	local bytes = fs.readFile(path)
	assert(#bytes <= maximum, "file exceeds its byte limit: " .. path)
	return bytes
end

local function plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function pathKey(path)
	local normalized = string.gsub(path, "\\", "/")
	return if process.os == "windows" then string.lower(normalized) else normalized
end

local function relativeTo(root, path)
	local child = string.gsub(path, "\\", "/")
	local parent = string.gsub(root, "\\", "/")
	if process.os == "windows" then child, parent = string.lower(child), string.lower(parent) end
	if child == parent then return "" end
	assert(string.sub(child, 1, #parent + 1) == parent .. "/", "input escaped project root")
	return string.sub(child, #parent + 2)
end

local function segments(value)
	local result = {}
	for part in string.gmatch(string.gsub(value, "\\", "/"), "[^/]+") do
		if part == ".." then
			if #result == 0 then return nil end
			table.remove(result)
		elseif part ~= "." and part ~= "" then
			table.insert(result, part)
		end
	end
	return result
end

local diagnostic = Result.diagnostic

local function wrapDiagnostics(items, prefix)
	local output = {}
	for _, item in items do
		table.insert(output, diagnostic(item.code or "AnalysisFailed", prefix .. "." .. (item.path or "input"),
			item.message or "analysis failed", nil, item.severity))
	end
	table.sort(output, function(left, right)
		if left.path == right.path then
			if left.code == right.code then return left.message < right.message end
			return left.code < right.code
		end
		return left.path < right.path
	end)
	return Result.limitDiagnostics(output)
end

local function run(request, pathGuard)
	assert(plain(request) and plain(request.project) and plain(request.sourceDigests), "invalid worker request")
	local project, projectError = Project.validate(request.project)
	assert(project, projectError and projectError.message or "invalid project configuration")
	local projectRoot = pathGuard.resolve(request.projectRoot, process.cwd, true)
	local manifestPath = pathGuard.resolve(request.manifest, projectRoot, true)
	assert(Paths.within(manifestPath, projectRoot), "manifest escaped project root")
	local manifestBytes = readBounded(manifestPath, 1_048_576)
	assert(serde.hash("sha256", manifestBytes) == request.manifestDigest, "project manifest changed before worker start")

	local inputPaths = { request.manifest, project.schema }
	for _, key in { "policy", "workload", "baseline" } do
		if project[key] ~= nil then table.insert(inputPaths, project[key]) end
	end
	for _, path in project.tests or {} do table.insert(inputPaths, path) end
	local resolvedInputs = pathGuard.resolveMany(projectRoot, (function()
		local rows = {}
		for _, path in inputPaths do table.insert(rows, { path = path, mustExist = true }) end
		return rows
	end)())

	local tracked, trackedPath, trackedAbsolute, missingPath, totalSourceBytes, trackedCount, missingCount = {}, {}, {}, {}, 0, 0, 0
	local function addTracked(relative, absolutePath, bytes)
		local key = pathKey(relative)
		if tracked[key] == nil then
			if trackedCount >= MAX_SOURCE_FILES or totalSourceBytes + #bytes > MAX_SOURCE_BYTES then
				error("SourceLimitExceeded: project source inputs exceed the CLI identity limit")
			end
			tracked[key] = bytes
			trackedPath[key] = relative
			trackedAbsolute[key] = absolutePath
			totalSourceBytes += #bytes
			trackedCount += 1
		end
	end
	local function addMissing(relative)
		local key = pathKey(relative)
		if missingPath[key] == nil then
			assert(missingCount < MAX_SOURCE_FILES, "SourceLimitExceeded: project import probes exceed the CLI identity limit")
			missingPath[key] = relative
			missingCount += 1
		end
	end
	for index, relative in inputPaths do
		local absolutePath = resolvedInputs[index]
		assert(fs.isFile(absolutePath), "configured input is not a file: " .. relative)
		local remaining = if tracked[pathKey(relative)] then MAX_SOURCE_BYTES else MAX_SOURCE_BYTES - totalSourceBytes
		local bytes = tracked[pathKey(relative)] or readBounded(absolutePath, remaining)
		local expectedDigest = request.sourceDigests[pathKey(relative)]
		assert(type(expectedDigest) == "string" and serde.hash("sha256", bytes) == expectedDigest,
			"SourceChangedBeforeWorker: " .. relative)
		addTracked(relative, absolutePath, bytes)
	end

	local cache, loading = {}, {}
	local function consumerRelative(fromAbsolute, imported)
		assert(type(imported) == "string" and imported ~= "" and not string.find(imported, "%c"), "invalid require path")
		local normalized = string.gsub(imported, "\\", "/")
		assert(not string.find(normalized, ":", 1, true), "colon is unsupported in consumer imports")
		assert(string.sub(normalized, 1, 2) == "./" or string.sub(normalized, 1, 3) == "../",
			"consumer imports must start with ./ or ../")
		local parts = segments(relativeTo(projectRoot, Paths.directory(fromAbsolute)))
		assert(parts, "import base escaped project root")
		for part in string.gmatch(normalized, "[^/]+") do
			if part == ".." then
				assert(#parts > 0, "relative import traverses above the project root")
				table.remove(parts)
			elseif part ~= "." then table.insert(parts, part) end
		end
		assert(#parts > 0, "invalid relative import")
		return table.concat(parts, "/")
	end

	local function loadConsumer(absolutePath, relative)
		local key = pathKey(absolutePath)
		if cache[key] ~= nil then return cache[key] end
		assert(not loading[key], "cyclic consumer import: " .. relative)
		loading[key] = true
		local remaining = if tracked[pathKey(relative)] then MAX_SOURCE_BYTES else MAX_SOURCE_BYTES - totalSourceBytes
		-- Execute the guarded input snapshot captured before any factory runs.
		local bytes = tracked[pathKey(relative)] or readBounded(absolutePath, remaining)
		addTracked(relative, absolutePath, bytes)
		assert(tracked[pathKey(relative)] == bytes, "SourceChangedDuringLoad: " .. relative)
		local moduleRequire = function(imported)
			if string.sub(imported, 1, 6) == "@lune/" then return require(imported) end
			if imported == "@relay/schema" then return Schema end
			if string.sub(imported, 1, 1) == "@" then error("unsupported module alias: " .. imported, 2) end
			local candidate = consumerRelative(absolutePath, imported)
			local choices = if string.sub(candidate, -5) == ".luau" then { candidate }
				else { candidate .. ".luau", candidate .. "/init.luau" }
			for _, choice in choices do
				local resolved = trackedAbsolute[pathKey(choice)] or pathGuard.resolve(choice, projectRoot, false)
				if Paths.within(resolved, projectRoot) then
					local ok, exists = pcall(fs.isFile, resolved)
					if ok and exists then
						local childRelative = relativeTo(projectRoot, resolved)
						local loaded = loadConsumer(resolved, childRelative)
						return loaded
					end
				end
				addMissing(choice)
			end
			error("module not found inside project root: " .. imported, 2)
		end
		local chunk = luau.load(bytes, { debugName = absolutePath,
			environment = { require = moduleRequire } })
		local value = chunk()
		cache[key], loading[key] = value, nil
		return value
	end

	local function module(relative, label)
		local absolutePath = assert(trackedAbsolute[pathKey(relative)], "configured module was not captured")
		local ok, value = pcall(loadConsumer, absolutePath, relative)
		if not ok then
			local message = string.match(tostring(value), "^([^\r\n]+)") or "module could not be loaded"
			return nil, diagnostic("ModuleLoadFailed", label, message,
				"Check the module and its project-relative imports.")
		end
		if not plain(value) then
			return nil, diagnostic("InvalidModuleResult", label, "module must return a plain table",
				"Return a plain Luau table from this module.")
		end
		return value
	end

	local function sourceEntries()
		local entries = {}
		for key, bytes in tracked do entries[trackedPath[key]] = bytes end
		for _, relative in missingPath do entries[string.char(0) .. "candidate:" .. relative] = "missing" end
		return entries
	end
	local function sourceId()
		return Fingerprint.digest(sourceEntries(), serde.hash, SOURCE_DOMAIN)
	end
	local identity = {
		projectId = project.id, compilerId = request.compilerId, toolingId = request.toolingId,
		sourceId = request.sourceId, host = "cli", runId = request.runId,
	}
	local function sourcePaths()
		local paths = {}
		for _, relative in trackedPath do table.insert(paths, relative) end
		table.sort(paths)
		return paths
	end
	local function absentPaths()
		local paths = {}
		for _, relative in missingPath do table.insert(paths, relative) end
		table.sort(paths)
		return paths
	end
	local function sourcesChanged()
		for key, bytes in tracked do
			local ok, current = pcall(readBounded, trackedAbsolute[key], #bytes)
			if not ok or current ~= bytes then return true end
		end
		local paths = absentPaths()
		if #paths > 0 then
			local requests = {}
			for index, path in paths do requests[index] = { path = path, mustExist = false } end
			local resolved = pathGuard.resolveMany(projectRoot, requests)
			for index in paths do
				if fs.isFile(resolved[index]) then return true end
			end
		end
		return false
	end
	local spec, specError = module(project.schema, "schema")
	local schemaReport, schemaIssue
	if spec ~= nil then
		local ok, report, issue = pcall(SchemaCheck.inspect, Definition, spec)
		if ok then schemaReport, schemaIssue = report, issue
		else schemaIssue = { code = "SchemaCheckFailed", path = "spec", message = tostring(report) } end
	end
	if specError ~= nil then schemaIssue = specError end
	local schemaDiagnostics = if schemaIssue then { diagnostic(schemaIssue.code or "SchemaFailed",
		"schema." .. (schemaIssue.path or "input"), schemaIssue.message or "schema analysis failed",
		schemaIssue.action or if schemaIssue.code == "InvalidDefinition" then "Correct the Relay schema definition and rerun check." else nil) } else {}
	local function child(operation, status, data, diagnostics)
		if identity.sourceId == nil then identity.sourceId = sourceId() end
		return Result.new(operation, identity, status, data, diagnostics)
	end
	local function loadPolicy()
		if not schemaReport then
			return nil, { diagnostic(schemaIssue and schemaIssue.code or "SchemaUnavailable", "policy",
				schemaIssue and schemaIssue.message or "policy analysis needs a valid schema",
				"Fix the schema result before using policy coverage.") }
		end
		local policy, issue = module(project.policy, "policy")
		if issue then return nil, { diagnostic(issue.code, "policy." .. issue.path, issue.message, issue.action) } end
		local diagnostics = {}
		local ok, problem = pcall(SchemaCheck.checkEndpointRates, schemaReport, policy, diagnostics)
		if not ok then return nil, { diagnostic("PolicyCheckFailed", "policy", tostring(problem)) } end
		return { input = project.policy }, wrapDiagnostics(diagnostics, "policy")
	end
	local function compatibility()
		if not schemaReport then
			return child("compat", "failed", nil, { diagnostic(schemaIssue and schemaIssue.code or "SchemaUnavailable",
				"compat.after", schemaIssue and schemaIssue.message or "compatibility analysis needs a valid current schema",
				"Fix the schema result before comparing it.") })
		end
		local beforeSpec, issue = module(project.baseline, "baseline")
		if issue then return child("compat", "failed", nil,
			{ diagnostic(issue.code, "baseline." .. issue.path, issue.message, issue.action) }) end
		local before, beforeIssue = Compatibility.inspect(Definition, beforeSpec, project.baseline, "before")
		local after, afterIssue = Compatibility.inspect(Definition, spec, project.schema, "after")
		local diagnostics = {}
		if beforeIssue then table.insert(diagnostics, beforeIssue) end
		if afterIssue then table.insert(diagnostics, afterIssue) end
		if #diagnostics > 0 then return child("compat", "failed", Compatibility.forOutput({ before = before, after = after }),
			wrapDiagnostics(diagnostics, "compat")) end
		local changes = Compatibility.compare(before, after)
		local equal = before.descriptor == after.descriptor
		if not equal then table.insert(diagnostics, diagnostic("CompatibilityChanged", "compat.descriptor",
			"raw schema descriptors differ under the current compiler; this does not establish deployed-peer compatibility",
			"Review the descriptor changes and qualify each supported deployment revision separately.")) end
		return child("compat", if equal then "passed" else "failed",
			Compatibility.forOutput({ status = if equal then "equal" else "changed", before = before, after = after,
				descriptorEqual = equal, requiresMatchedDeployment = not equal, changes = changes }), diagnostics)
	end
	local function budget()
		if not schemaReport then
			return child("budget", "failed", nil, { diagnostic(schemaIssue and schemaIssue.code or "SchemaUnavailable",
				"budget.schema", schemaIssue and schemaIssue.message or "budget analysis needs a valid schema",
				"Fix the schema result before checking its workload.") })
		end
		local workload, issue = module(project.workload, "workload")
		if issue then return child("budget", "failed", nil,
			{ diagnostic(issue.code, "workload." .. issue.path, issue.message, issue.action) }) end
		local outcome, diagnostics = Budget.analyze(schemaReport, workload, project.maxBytesPerSecond)
		local wrapped = wrapDiagnostics(diagnostics, "budget")
		local status = if #wrapped == 0 then "passed" elseif outcome and outcome.budget
			and outcome.budget.status == "unknown" then "inconclusive" else "failed"
		return child("budget", status, outcome, wrapped)
	end
	local function scenarios()
		if not schemaReport then return child("tests", "failed", nil, {
			diagnostic("SchemaUnavailable", "tests", "portable scenarios need a valid schema", "Fix the schema before running scenarios.") }) end
		local definition = assert(Definition.define(spec))
		local data, diagnostics = require("./Scenarios").run(definition, project.tests, function(path)
			return loadConsumer(assert(trackedAbsolute[pathKey(path)], "scenario was not captured"), path)
		end)
		return child("tests", if #diagnostics == 0 then "passed" else "failed", data, diagnostics)
	end
	local function declarations(preview)
		local operation = if preview then "generate" else "typescript"
		if not schemaReport then return child(operation, "failed", nil, {
			diagnostic("SchemaUnavailable", "typescript", "declaration generation needs a valid schema", "Fix the schema before generating declarations.") }) end
		local ok, bytes = pcall(require("../roblox-ts/Generator").generate, spec)
		if not ok then return child(operation, "failed", nil, { diagnostic("GenerationFailed", project.typescript,
			tostring(bytes), "Use the supported declaration subset and fix the schema.") }) end
		local output = pathGuard.resolve(project.typescript, projectRoot, false)
		assert(Paths.within(output, projectRoot), "declaration output escaped the project root")
		local existing = if fs.isFile(output) then readBounded(output, MAX_SOURCE_BYTES) else nil
		local digest = if existing then "sha256:" .. serde.hash("sha256", existing) else "missing"
		local data = { profile = "typescript-declarations", output = project.typescript,
			expectedDigest = "sha256:" .. serde.hash("sha256", bytes), observedDigest = digest,
			compilerCheck = "not-run", mode = if preview then "preview" else "verify" }
		if request.operation == "verify" then data.inspection = schemaReport end
		local diagnostics = {}
		local status = "passed"
		if digest ~= request.outputDigest then
			status = "stale"
			table.insert(diagnostics, diagnostic("GeneratedOutputChanged", project.typescript,
				"declaration output changed during this job", "Review the newer output and rerun generation."))
		elseif not preview and existing ~= bytes then
			status = "failed"
			table.insert(diagnostics, diagnostic(if existing then "GeneratedOutputStale" else "GeneratedOutputMissing", project.typescript,
				"declaration output does not match the current schema",
				"Preview with generate, then use generate --write after reviewing the intended output."))
		end
		if preview then data.declaration = bytes end
		local result = child(operation, status, data, diagnostics)
		if existing then result.artifacts = { { path = project.typescript, kind = "typescript-declaration", digest = digest } } end
		return result
	end

	local operation = request.operation
	local result
	if operation == "compat" then result = compatibility()
	elseif operation == "budget" then result = budget()
	elseif operation == "test" then result = scenarios()
	elseif operation == "generate" then result = declarations(true)
	elseif operation == "verify" then result = declarations(false)
	elseif operation ~= "check" then error("invalid worker operation")
	else
		local children = { child("schema", if schemaReport and schemaIssue == nil then "passed" else "failed",
			schemaReport, schemaDiagnostics) }
		if project.policy then
			local data, diagnostics = loadPolicy()
			table.insert(children, child("policy", if #diagnostics == 0 then "passed" else "failed", data, diagnostics))
		end
		if project.baseline then table.insert(children, compatibility()) end
		if project.workload then table.insert(children, budget()) end
		local required = {}
		for _, name in project.required do required[name] = true end
		for _, profile in { { "tests", project.tests and #project.tests > 0, scenarios }, { "typescript", project.typescript, function() return declarations(false) end } } do
			if profile[2] then
				table.insert(children, if required[profile[1]] then profile[3]() else child(profile[1], "skipped", nil,
					{ diagnostic("OptionalProfile", profile[1], "optional profile was not selected",
						"Run test/verify explicitly or add this profile to required.", "info") }))
			end
		end
		identity.sourceId = sourceId()
		for _, item in children do item.sourceId = identity.sourceId end
		result = Result.aggregate("check", identity, children, project.required)
		result.data = { project = project }
	end
	if operation ~= "check" then identity.sourceId = sourceId() end
	result.sourceId = identity.sourceId
	if sourcesChanged() then Result.markStale(result, diagnostic("SourceChanged", "project", "project source changed during analysis",
		"Rerun the command after the project files stop changing.")) end
	return result, sourcePaths(), absentPaths()
end

local arguments = process.args
if #arguments ~= 3 or arguments[1] ~= "--relay-tools-worker" then
	error("worker usage: --relay-tools-worker <request.json> <result.json>")
end
local requestPath, resultPath = arguments[2], arguments[3]
local request = serde.decode("json", fs.readFile(requestPath))
local identity = Identity.collect(request.toolRoot)
local result
local pathGuard
local sourceList, missingList = {}, {}
local ok, failure = pcall(function()
	assert(identity.compilerId == request.compilerId and identity.toolingId == request.toolingId,
		"tooling source changed before worker start")
	pathGuard = Paths.createGuard()
	result, sourceList, missingList = run(request, pathGuard)
end)
local closed, closeFailure = pcall(function() if pathGuard then pathGuard.close() end end)
if not closed then
	if ok then ok, failure = false, closeFailure
	else failure = tostring(failure) .. "\nPathGuardShutdownFailed: " .. tostring(closeFailure) end
end
if not ok then
	local projectId = if type(request.project) == "table" and type(request.project.id) == "string" then request.project.id else "unknown"
	local fallbackSource = request.sourceId or Fingerprint.digest({}, serde.hash, SOURCE_DOMAIN)
	sourceList = request.sourcePaths or {}
	missingList = {}
	result = Result.new(Result.workerOperation(request.operation or "check"), {
		projectId = projectId, compilerId = identity.compilerId, toolingId = identity.toolingId,
		sourceId = fallbackSource, host = "cli", runId = request.runId,
	}, "failed", nil, { diagnostic("WorkerFailed", "worker", tostring(failure),
		"Review the worker log and project paths, then rerun the command.") })
end

local response = { result = result, sourcePaths = sourceList, missingPaths = missingList }
fs.writeFile(resultPath, ResultJson.worker(response))
