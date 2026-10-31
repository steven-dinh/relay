local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Paths = require("./tooling/Paths")
local Project = require("./tooling/Project")
local Result = require("./tooling/Result")
local Identity = require("./tooling/Identity")
local Bundle = require("./tooling/Bundle")
local WorkerProcess = require("./tooling/Process")
local Fingerprint = require("../benchmarks/host/MeasurementFingerprint")

local SOURCE_DOMAIN = "RelayToolsProjectSource:1"
local WORKER_DEADLINE = 15
local MAX_SOURCE_BYTES = 4_194_304
local USAGE = "Usage: lune run scripts/relay-tools.luau <doctor|check|compat|budget> --project <manifest.json> [--json]\n       lune run scripts/relay-tools.luau doctor [--json]\n       lune run scripts/relay-tools.luau bundle --output <directory> [--json]"

local function diagnostic(code, path, message, action, severity)
	return { severity = severity or "error", code = string.sub(code, 1, 64), path = string.sub(path, 1, 512),
		message = string.sub(tostring(message), 1, 1024),
		action = string.sub(action or "Correct the project configuration and rerun this command.", 1, 1024) }
end

local function readBounded(path, maximum)
	assert(fs.metadata(path).size <= maximum, "file exceeds its byte limit: " .. path)
	local bytes = fs.readFile(path)
	assert(#bytes <= maximum, "file exceeds its byte limit: " .. path)
	return bytes
end

local function jsonBytes(value)
	local encoded = serde.encode("json", value)
	for _, key in { "diagnostics", "artifacts", "children", "changes", "sourcePaths" } do
		encoded = string.gsub(encoded, '"' .. key .. '":{}', '"' .. key .. '":[]')
	end
	return encoded
end

local function toolRoot()
	local source = string.gsub(debug.info(1, "s"), "\\", "/")
	source = string.gsub(source, "%.luau$", "")
	local root = string.match(source, "^(.*)/scripts/relay%-tools$")
	assert(root, "could not locate Relay Tools source root")
	return Paths.resolve(root, process.cwd, true)
end

local function parseArguments(arguments)
	local operation = arguments[1]
	if operation == "--help" or operation == "-h" then return { help = true } end
	local project, output, json, seenProject, seenOutput, seenJson
	local parseError = if operation ~= "doctor" and operation ~= "check" and operation ~= "compat" and operation ~= "budget" and operation ~= "bundle"
		then "expected doctor, check, compat, budget, or bundle" else nil
	local index = 2
	while index <= #arguments do
		local argument = arguments[index]
		if argument == "--json" then
			if seenJson and parseError == nil then parseError = "duplicate --json option" end
			json, seenJson = true, true
		elseif argument == "--project" then
			if operation == "bundle" and parseError == nil then parseError = "bundle uses --output, not --project" end
			if seenProject and parseError == nil then parseError = "duplicate --project option" end
			local candidate = arguments[index + 1]
			if candidate == nil or string.sub(candidate, 1, 1) == "-" then
				if parseError == nil then parseError = "--project requires a manifest path" end
			else
				project, seenProject = candidate, true
				index += 1
			end
		elseif argument == "--output" then
			if operation ~= "bundle" and parseError == nil then parseError = "--output is only valid for bundle" end
			if seenOutput and parseError == nil then parseError = "duplicate --output option" end
			local candidate = arguments[index + 1]
			if candidate == nil or string.sub(candidate, 1, 1) == "-" then
				if parseError == nil then parseError = "--output requires a destination directory" end
			else
				output, seenOutput = candidate, true
				index += 1
			end
		else
			if parseError == nil then parseError = "unknown option or unexpected argument: " .. argument end
		end
		index += 1
	end
	if operation == "bundle" then
		if output == nil and parseError == nil then parseError = "--output is required for bundle" end
	elseif project == nil and operation ~= "doctor" and parseError == nil then
		parseError = "--project is required"
	end
	return { operation = operation or "cli", project = project, output = output, json = json == true }, parseError
end

local function staticSources(projectRoot, manifestRelative, project, manifestBytes)
	local paths = { manifestRelative, project.schema }
	for _, key in { "policy", "workload", "baseline" } do
		if project[key] then table.insert(paths, project[key]) end
	end
	for _, path in project.tests or {} do table.insert(paths, path) end
	local requests = {}
	for _, path in paths do table.insert(requests, { path = path, mustExist = true }) end
	local resolved = Paths.resolveMany(projectRoot, requests)
	local entries, absolute, total = {}, {}, 0
	for index, path in paths do
		assert(Paths.within(resolved[index], projectRoot), "configured input escapes the project root")
		assert(fs.isFile(resolved[index]), "configured input is not a file: " .. path)
		local key = if process.os == "windows" then string.lower(path) else path
		if entries[key] == nil then
			entries[key] = if path == manifestRelative then manifestBytes
				else readBounded(resolved[index], MAX_SOURCE_BYTES - total)
			total += #entries[key]
			assert(total <= MAX_SOURCE_BYTES, "project source inputs exceed 4 MiB")
			absolute[key] = path
		end
	end
	local sourceEntries, sourceDigests = {}, {}
	local sourcePaths = {}
	for key, bytes in entries do
		sourceEntries[absolute[key]] = bytes
		sourceDigests[key] = serde.hash("sha256", bytes)
		table.insert(sourcePaths, absolute[key])
	end
	table.sort(sourcePaths)
	return sourcePaths, Fingerprint.digest(sourceEntries, serde.hash, SOURCE_DOMAIN), sourceDigests
end

local function readProject(manifestInput)
	local manifestPath = Paths.resolve(manifestInput, process.cwd, true)
	assert(fs.isFile(manifestPath), "project manifest is not a file")
	local projectRoot = Paths.directory(manifestPath)
	projectRoot = Paths.resolve(projectRoot, projectRoot, true)
	assert(Paths.within(manifestPath, projectRoot), "project manifest escaped its root")
	local manifestRelative = string.match(string.gsub(manifestPath, "\\", "/"), "([^/]+)$")
	local manifestBytes = readBounded(manifestPath, 1_048_576)
	local decoded = serde.decode("json", manifestBytes)
	local project, issue = Project.validate(decoded)
	assert(project, issue and (issue.path .. ": " .. issue.message) or "invalid project manifest")
	local sourcePaths, sourceId, sourceDigests = staticSources(projectRoot, manifestRelative, project, manifestBytes)
	if project.typescript then
		local output = Paths.resolve(project.typescript, projectRoot, false)
		assert(Paths.within(output, projectRoot), "TypeScript output escapes the project root")
	end
	return {
		manifestPath = manifestPath, manifestRelative = manifestRelative, projectRoot = projectRoot,
		manifestBytes = manifestBytes, manifestDigest = serde.hash("sha256", manifestBytes),
		project = project, sourcePaths = sourcePaths, sourceDigests = sourceDigests, sourceId = sourceId,
	}
end

local function newResult(operation, projectId, identity, status, data, diagnostics)
	return Result.new(operation, {
		projectId = projectId or "unknown", compilerId = identity.compilerId, toolingId = identity.toolingId,
		sourceId = identity.sourceId, host = "cli", runId = identity.runId,
	}, status, data, diagnostics)
end

local function resultFromError(operation, message, identity, code, projectId)
	local action = if code == "InvalidArguments" then USAGE
		elseif code == "ToolExecutionUnavailable" then "Install or repair the pinned Lune 0.11 toolchain, then rerun doctor."
		else "Check the manifest path and project configuration, then rerun the command."
	return newResult(operation, projectId or (if operation == "bundle" then "tooling" else "unknown"), identity, "failed", nil,
		{ diagnostic(code or "InvalidConfiguration", "project", message, action) })
end

local function runId()
	return "run:" .. string.sub(serde.hash("sha256", `{os.time()}:{os.clock()}:{tostring({})}`), 1, 32)
end

local function reserveWorkspace()
	local base = process.env.TEMP or process.env.TMP or process.env.TMPDIR or process.cwd
	base = Paths.resolve(base, process.cwd, true)
	for attempt = 1, 8 do
		local token = string.sub(serde.hash("sha256", `{os.time()}:{os.clock()}:{tostring({})}:{attempt}`), 1, 24)
		local directory = base .. (if process.os == "windows" then "\\" else "/") .. "relay-tools-" .. token
		if not fs.isDir(directory) and not fs.isFile(directory) then
			local ok = pcall(fs.writeDir, directory)
			if ok then return directory end
		end
	end
	error("JobWorkspaceUnavailable: could not reserve a temporary job directory")
end

local function cleanWorkspace(directory)
	for _, name in { "request.json", "result.json" } do
		local path = directory .. (if process.os == "windows" then "\\" else "/") .. name
		local ok, exists = pcall(fs.isFile, path)
		if ok and exists then pcall(fs.removeFile, path) end
	end
	local ok, exists = pcall(fs.isDir, directory)
	if ok and exists then pcall(fs.removeDir, directory) end
end

local function fallbackFailure(operation, project, identity, code, message)
	local status = if code == "WorkerTimeout" then "cancelled" else "failed"
	local result = newResult(operation, project.project.id, identity, status, nil,
		{ diagnostic(code, "worker", message,
			if code == "WorkerTimeout" then "Reduce schema evaluation work or remove nonterminating factory code." else "Review the bounded worker logs and rerun the command.") })
	return result
end

local function verifySourceIdentity(response, project)
	local paths = response.sourcePaths
	assert(type(paths) == "table" and #paths <= 256, "invalid worker source list")
	local seen, requests = {}, {}
	for index, path in paths do
		local normalized = Project.relativePath(path)
		assert(normalized == path and not seen[path], "invalid or repeated worker source path")
		seen[path] = true
		requests[index] = { path = path, mustExist = true }
	end
	local resolved = Paths.resolveMany(project.projectRoot, requests)
	local entries, total = {}, 0
	for index, path in paths do
		assert(Paths.within(resolved[index], project.projectRoot) and fs.isFile(resolved[index]),
			"worker source path escaped the project root")
		entries[path] = readBounded(resolved[index], MAX_SOURCE_BYTES - total)
		total += #entries[path]
	end
	local current = Fingerprint.digest(entries, serde.hash, SOURCE_DOMAIN)
	if current ~= response.result.sourceId then
		local result = response.result
		local issue = diagnostic("SourceChanged", "project", "project source changed during analysis",
			"Rerun the command after the project files stop changing.")
		if result.children then
			for _, child in result.children do
				child.status = "stale"
				table.insert(child.diagnostics, table.clone(issue))
			end
			result.status = "stale"
		else
			result.status = "stale"
			table.insert(result.diagnostics, issue)
		end
	end
	return response.result
end

local function runWorker(operation, project, identity, toolRoot, executable)
	local workspaceOk, workspace = pcall(reserveWorkspace)
	if not workspaceOk then return fallbackFailure(operation, project, identity, "WorkerFailed", tostring(workspace)) end
	local requestPath = workspace .. (if process.os == "windows" then "\\" else "/") .. "request.json"
	local resultPath = workspace .. (if process.os == "windows" then "\\" else "/") .. "result.json"
	local request = {
		operation = operation, projectRoot = project.projectRoot, manifest = project.manifestRelative,
		manifestDigest = project.manifestDigest, project = project.project, sourceDigests = project.sourceDigests,
		toolRoot = toolRoot, compilerId = identity.compilerId, toolingId = identity.toolingId,
		runId = identity.runId, sourceId = identity.sourceId, sourcePaths = project.sourcePaths,
	}
	local workerScript = toolRoot .. (if process.os == "windows" then "\\" else "/") .. "scripts/tooling/Worker.luau"
	local runOk, output = pcall(function()
		fs.writeFile(requestPath, serde.encode("json", request))
		return WorkerProcess.run(executable, { "run", workerScript, "--relay-tools-worker", requestPath, resultPath },
			project.projectRoot, WORKER_DEADLINE)
	end)
	if not runOk then cleanWorkspace(workspace); return fallbackFailure(operation, project, identity,
		"WorkerFailed", tostring(output)) end
	if output.timedOut then
		local result = fallbackFailure(operation, project, identity, "WorkerTimeout",
			"worker exceeded the fifteen-second deadline and the owned Lune process was terminated")
		result.logs = { stdout = output.stdout, stderr = output.stderr }
		cleanWorkspace(workspace)
		return result
	end
	if not output.status.ok then
		local result = fallbackFailure(operation, project, identity, "WorkerFailed",
			"worker exited unsuccessfully (code " .. tostring(output.status.code) .. ")")
		result.logs = { stdout = output.stdout, stderr = output.stderr }
		cleanWorkspace(workspace)
		return result
	end
	local ok, response = pcall(function()
		local bytes = readBounded(resultPath, Result.MAX_BYTES)
		local decoded = serde.decode("json", bytes)
		assert(type(decoded) == "table" and type(decoded.result) == "table", "worker result file is malformed")
		local valid, issue = Result.validate(decoded.result)
		assert(valid, issue)
		assert(decoded.result.projectId == project.project.id and decoded.result.compilerId == identity.compilerId
			and decoded.result.toolingId == identity.toolingId and decoded.result.host == "cli"
			and decoded.result.runId == identity.runId, "worker result identity mismatch")
		local currentIdentity = { projectId = decoded.result.projectId, compilerId = decoded.result.compilerId,
			toolingId = decoded.result.toolingId, sourceId = decoded.result.sourceId, host = "cli", runId = identity.runId }
		assert(Result.isCurrent(decoded.result, currentIdentity), "worker result is stale or invalid")
		return verifySourceIdentity(decoded, project)
	end)
	cleanWorkspace(workspace)
	if not ok then
		local result = fallbackFailure(operation, project, identity, "WorkerResultInvalid", tostring(response))
		result.logs = { stdout = output.stdout, stderr = output.stderr }
		return result
	end
	if response.status ~= "passed" then response.logs = { stdout = output.stdout, stderr = output.stderr } end
	return response
end

local function doctor(project, identity, lunePath)
	local diagnostics = {}
	local supportedVersion = string.match(_VERSION, "^Lune (%d+%.%d+%.%d+)") == Bundle.LUNE_VERSION
	if not supportedVersion then
		table.insert(diagnostics, diagnostic("UnsupportedLuneVersion", "host.lune",
			"Relay Tools requires Lune " .. Bundle.LUNE_VERSION .. "; this process is " .. _VERSION,
			"Install the pinned Lune toolchain and rerun doctor."))
	end
	local unsupported = {}
	if project then
		local required = {}
		for _, name in project.project.required do required[name] = true end
		for _, name in { "tests", "typescript" } do
			if required[name] then
				table.insert(unsupported, name)
				table.insert(diagnostics, diagnostic("UnsupportedCapability", name,
					name .. " is required but is not implemented by this CLI host",
					"Remove the unsupported profile from required or use its existing standalone tooling."))
			end
		end
	end
	local status = if #unsupported > 0 or not supportedVersion then "unsupported"
		elseif #diagnostics > 0 then "failed" else "passed"
	local data = { luneVersion = _VERSION, executable = lunePath, projectRoot = if project then project.projectRoot else nil,
		capabilities = { doctor = "passed", schema = "available", policy = "available", compat = "available",
			budget = "available", tests = "unsupported", typescript = "unsupported" } }
	return newResult("doctor", if project then project.project.id else "tooling", identity, status, data, diagnostics)
end

local function bundle(toolRootPath, outputPath, identity)
	local destination
	local ok, manifest = pcall(function()
		destination = Paths.resolve(outputPath, process.cwd, false)
		return Bundle.build(toolRootPath, destination)
	end)
	if not ok then
		return newResult("bundle", "tooling", identity, "failed", nil,
			{ diagnostic("BundleBuildFailed", "output", tostring(manifest),
				"Choose a new destination and confirm the source bundle is complete.") })
	end
	local sourceId = Fingerprint.digest({ compilerId = manifest.compilerId, toolingId = manifest.toolingId },
		serde.hash, "RelayToolsBundleSource:1")
	local resultIdentity = {
		projectId = "tooling", compilerId = manifest.compilerId, toolingId = manifest.toolingId,
		sourceId = sourceId, host = "cli", runId = identity.runId,
	}
	local matchesInvocation = manifest.compilerId == identity.compilerId and manifest.toolingId == identity.toolingId
	local diagnostics = if matchesInvocation then {} else {
		diagnostic("BundleSourceChanged", "tooling", "tooling source changed while the bundle was being built",
			"Rerun bundle from a stable tooling checkout.")
	}
	local result = Result.new("bundle", resultIdentity, if matchesInvocation then "passed" else "stale",
		manifest, diagnostics, { { path = destination, kind = "tooling-bundle", digest = manifest.toolingId } })
	return result
end

local function exitCode(result)
	if result.status == "passed" then return 0 end
	if result.status == "failed" then
		for _, item in result.diagnostics or {} do
			if item.code == "InvalidArguments" or item.code == "InvalidConfiguration" or item.code == "WorkerFailed"
				or item.code == "ToolExecutionUnavailable" or item.code == "WorkerTimeout"
				or item.code == "WorkerResultInvalid" or item.code == "BundleBuildFailed" then return 2 end
		end
		return 1
	end
	return if result.status == "stale" then 1 else 2
end

local function readable(result)
	print("Relay Tools " .. result.operation .. ": " .. string.upper(result.status))
	print("Project: " .. result.projectId)
	print("Source: " .. result.sourceId)
	local function issues(items)
		for _, item in items do
			print(string.upper(item.severity) .. " " .. item.path .. " [" .. item.code .. "]: " .. item.message)
			print("  Action: " .. item.action)
		end
	end
	if result.children then
		for _, child in result.children do
			print("  " .. child.operation .. ": " .. string.upper(child.status))
			issues(child.diagnostics)
		end
	end
	issues(result.diagnostics)
	if result.logs then
		if result.logs.stdout ~= "" then print("Worker stdout:\n" .. result.logs.stdout) end
		if result.logs.stderr ~= "" then print("Worker stderr:\n" .. result.logs.stderr) end
	end
end

local arguments, argumentError = parseArguments(process.args)
if arguments.help then print(USAGE); return end
local operation, json = arguments.operation, arguments.json
local root, identity, lunePath, project
local stage = "tooling"
local ok, errorMessage = pcall(function()
	root = toolRoot()
	identity = Identity.collect(root)
	identity.runId = runId()
	identity.sourceId = Fingerprint.digest({}, serde.hash, SOURCE_DOMAIN)
	if argumentError then stage = "usage"; error(argumentError) end
	stage = "host"
	lunePath = WorkerProcess.executable()
	if operation ~= "doctor" and string.match(_VERSION, "^Lune (%d+%.%d+%.%d+)") ~= Bundle.LUNE_VERSION then
		error("Relay Tools requires Lune " .. Bundle.LUNE_VERSION .. "; this process is " .. _VERSION)
	end
	if arguments.project then
		stage = "project"
		project = readProject(arguments.project)
		identity.sourceId = project.sourceId
	end
end)
local result
if not ok then
	identity = identity or { compilerId = _VERSION, toolingId = "unavailable", sourceId = Fingerprint.digest({}, serde.hash, SOURCE_DOMAIN), runId = runId() }
	local code = if stage == "usage" then "InvalidArguments"
		elseif stage == "host" or stage == "tooling" then "ToolExecutionUnavailable" else "InvalidConfiguration"
	result = resultFromError(operation, tostring(errorMessage), identity, code)
elseif operation == "doctor" then
	result = doctor(project, identity, lunePath)
elseif operation == "bundle" then
	result = bundle(root, arguments.output, identity)
elseif (operation == "compat" and project.project.baseline == nil)
	or (operation == "budget" and project.project.workload == nil) then
	result = resultFromError(operation, "command requires a configured " .. (if operation == "compat" then "baseline" else "workload"),
		identity, "InvalidConfiguration", project.project.id)
else
	result = runWorker(operation, project, identity, root, lunePath)
end

if json then print(jsonBytes(result)) else readable(result) end
process.exit(exitCode(result))
