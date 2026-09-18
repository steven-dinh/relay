--!strict

-- A small orchestration layer for paired, fresh-session State-broadcast runs.
-- HostRuntime remains the authority for Studio lifecycle, delivery proof, and
-- Result V2 publication. This module only schedules those invocations and
-- checks their immutable attribution.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local ResultV2 = require("../contracts/result-v2")

local RESULT_DIRECTORY = "benchmarks/results/local"
local HOST_SCRIPT = "benchmarks/host/run-event-v1.luau"
local STUDY_SCHEMA = "Relay.BroadcastStudyLedger"
local STUDY_VERSION = 1
local MAX_RESULT_BYTES = ResultV2.MAX_JSON_BYTES
local PROCESS_OUTPUT_MAX_BYTES = 131_072
local PROCESS_OUTPUT_CHUNK_BYTES = 1_024
local UUID_PATTERN = "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$"

local function fail(code: string): never
    error(code, 0)
end

local function clone(value: any): any
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, child in value do copy[clone(key)] = clone(child) end
    return copy
end

local function slash(value: string): string
    return string.gsub(value, "\\", "/")
end

local function trim(value: string): string
    return string.gsub(value, "^%s+", ""):gsub("%s+$", "")
end

local function isAbsolute(path: string, osName: string): boolean
    local candidate = slash(path)
    if osName == "windows" then
        return string.match(candidate, "^%a:[/]") ~= nil or string.sub(candidate, 1, 2) == "//"
    end
    return string.sub(candidate, 1, 1) == "/"
end

local function join(root: string, child: string): string
    local left = slash(root)
    if string.sub(left, -1) == "/" then left = string.sub(left, 1, -2) end
    return left .. "/" .. string.gsub(child, "^[/]+", "")
end

local function canonicalPath(path: string): string
    local result = slash(path)
    local prefix = ""
    local rest = result
    local drive = string.match(result, "^(%a:)/")
    if drive ~= nil then
        prefix = drive .. "/"
        rest = string.sub(result, 4)
    elseif string.sub(result, 1, 2) == "//" then
        prefix = "//"
        rest = string.sub(result, 3)
    elseif string.sub(result, 1, 1) == "/" then
        prefix = "/"
        rest = string.sub(result, 2)
    end
    local parts = {}
    for part in string.gmatch(rest, "[^/]+") do
        if part == "." then
            continue
        elseif part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            elseif prefix == "" then
                table.insert(parts, part)
            end
        else
            table.insert(parts, part)
        end
    end
    local joined = table.concat(parts, "/")
    if #joined == 0 then return if #prefix > 0 then prefix else "." end
    return prefix .. joined
end

local function pathsEqual(left: string, right: string, osName: string): boolean
    if osName == "windows" then
        return string.lower(canonicalPath(left)) == string.lower(canonicalPath(right))
    end
    return canonicalPath(left) == canonicalPath(right)
end

local function baseName(path: string): string
    return string.match(slash(path), "([^/]+)$") or path
end

local function isUuid(value: any): boolean
    return type(value) == "string" and string.match(value, UUID_PATTERN) ~= nil
end

local function digest(hash: any, body: string): string
    local value = hash("sha256", body)
    if type(value) ~= "string" or #value ~= 64 or string.match(value, "^[0-9a-fA-F]+$") == nil then
        fail("BCAST_E_HASH")
    end
    return "sha256:" .. string.lower(value)
end

local function execute(executeFn: any, program: string, arguments: { string }, cwd: string): any
    local ok, result = pcall(executeFn, program, arguments, { cwd = cwd })
    if not ok or type(result) ~= "table" then fail("BCAST_E_EXEC") end
    return result
end

local function readBounded(reader: any): (string, boolean)
    local chunks = {}
    local retained = 0
    local truncated = false
    while true do
        local chunk = reader:read(PROCESS_OUTPUT_CHUNK_BYTES)
        if chunk == nil then break end
        if type(chunk) ~= "string" then fail("BCAST_E_OUTPUT_READ") end
        if retained < PROCESS_OUTPUT_MAX_BYTES then
            local room = PROCESS_OUTPUT_MAX_BYTES - retained
            local kept = string.sub(chunk, 1, room)
            table.insert(chunks, kept)
            retained += #kept
            if #kept < #chunk then truncated = true end
        else
            truncated = true
        end
    end
    return table.concat(chunks), truncated
end

local function runProcessBounded(program: string, arguments: { string }, options: any): any
    local ok, child = pcall(process.create, program, arguments, options)
    if not ok or child == nil then fail("BCAST_E_EXEC") end
    local output: any = {
        stdout = "", stderr = "", stdoutTruncated = false, stderrTruncated = false,
        stdoutDone = false, stderrDone = false,
    }
    task.spawn(function()
        local readOk, body, truncated = pcall(readBounded, child.stdout)
        if readOk then
            output.stdout = body
            output.stdoutTruncated = truncated
        else
            output.stdoutError = true
        end
        output.stdoutDone = true
    end)
    task.spawn(function()
        local readOk, body, truncated = pcall(readBounded, child.stderr)
        if readOk then
            output.stderr = body
            output.stderrTruncated = truncated
        else
            output.stderrError = true
        end
        output.stderrDone = true
    end)
    local status = nil
    while status == nil do
        status = child:status()
        if status == nil then task.wait(0.01) end
    end
    while not output.stdoutDone or not output.stderrDone do task.wait(0.01) end
    if output.stdoutError or output.stderrError then fail("BCAST_E_OUTPUT_READ") end
    return {
        ok = status.ok == true,
        code = status.code,
        stdout = output.stdout,
        stderr = output.stderr,
        stdoutTruncated = output.stdoutTruncated,
        stderrTruncated = output.stderrTruncated,
    }
end

local function parseArgs(arguments: { string }, osName: string?, cwd: string?): any
    if type(arguments) ~= "table" then fail("BCAST_E_ARGS") end
    local actualOs = osName or process.os
    local actualCwd = canonicalPath(cwd or process.cwd)
    local mode: string? = nil
    local studio: string? = nil
    local recipients: number? = nil
    local baseline: string? = nil
    local candidate: string? = nil
    local index = 1
    while index <= #arguments do
        local argument = arguments[index]
        if argument == "--plan" or argument == "--run" then
            if mode ~= nil then fail("BCAST_E_ARGS") end
            mode = string.sub(argument, 3)
            index += 1
        elseif argument == "--studio" or argument == "--recipients"
            or argument == "--baseline" or argument == "--candidate"
        then
            local value = arguments[index + 1]
            if type(value) ~= "string" or #value == 0 then fail("BCAST_E_ARGS") end
            if argument == "--studio" then
                if studio ~= nil or not isAbsolute(value, actualOs) then fail("BCAST_E_ARGS") end
                studio = canonicalPath(value)
            elseif argument == "--recipients" then
                if recipients ~= nil or (value ~= "1" and value ~= "4" and value ~= "8") then
                    fail("BCAST_E_ARGS")
                end
                recipients = tonumber(value)
            elseif argument == "--baseline" then
                if baseline ~= nil then fail("BCAST_E_ARGS") end
                baseline = if isAbsolute(value, actualOs) then canonicalPath(value) else join(actualCwd, value)
            else
                if candidate ~= nil then fail("BCAST_E_ARGS") end
                candidate = if isAbsolute(value, actualOs) then canonicalPath(value) else join(actualCwd, value)
            end
            index += 2
        else
            fail("BCAST_E_ARGS")
        end
    end
    if mode == nil or studio == nil or recipients == nil then fail("BCAST_E_ARGS") end
    local selectedBaseline = baseline or actualCwd
    if candidate ~= nil and pathsEqual(candidate, selectedBaseline, actualOs) then fail("BCAST_E_ARGS") end
    return table.freeze({
        mode = mode,
        studio = studio,
        recipients = recipients,
        baseline = canonicalPath(selectedBaseline),
        candidate = if candidate == nil then nil else canonicalPath(candidate),
        os = actualOs,
        cwd = actualCwd,
    })
end

local function schedule(options: any): { any }
    local forward = {
        { pass = 1, order = "forward", label = "native", adapterId = "native-reliable", root = options.baseline },
        { pass = 1, order = "forward", label = "baseline", adapterId = "relay-reliable", root = options.baseline },
        { pass = 1, order = "forward", label = "control", adapterId = "relay-reliable", root = options.baseline },
    }
    if options.candidate ~= nil then
        table.insert(forward, {
            pass = 1, order = "forward", label = "candidate", adapterId = "relay-reliable", root = options.candidate,
        })
    end
    local result = {}
    for _, item in forward do table.insert(result, clone(item)) end
    for index = #forward, 1, -1 do
        local item = clone(forward[index])
        item.pass = 2
        item.order = "reverse"
        table.insert(result, item)
    end
    return result
end

local function plan(options: any): any
    local entries = schedule(options)
    local selected = table.create(#entries)
    for index, item in entries do
        selected[index] = {
            index = index,
            pass = item.pass,
            order = item.order,
            label = item.label,
            adapterId = item.adapterId,
            root = item.root,
        }
    end
    return {
        schema = "Relay.BroadcastStudyPlan",
        version = STUDY_VERSION,
        topology = {
            mode = "PersistentBenchmark",
            caseId = "state-broadcast-s2c",
            recipients = options.recipients,
        },
        studio = options.studio,
        baseline = options.baseline,
        candidate = options.candidate,
        schedule = selected,
    }
end

local function parsePassOutput(stdout: string): any
    if type(stdout) ~= "string" then fail("BCAST_E_PASS") end
    local normalized = string.gsub(stdout, "\r\n", "\n")
    normalized = string.gsub(normalized, "\r", "\n")
    local found = nil
    local count = 0
    for line in string.gmatch(normalized, "[^\n]+") do
        local launchId, path = string.match(line, "^PASS Relay%.EventV1%.Benchmark ([^%s]+) (.+)$")
        if launchId ~= nil then
            count += 1
            if not isUuid(launchId) or #path == 0 or string.sub(path, -1) == " " or string.sub(path, 1, 1) == " " then
                fail("BCAST_E_PASS")
            end
            found = { launchId = string.lower(launchId), path = canonicalPath(path) }
        end
    end
    if count ~= 1 or found == nil then fail("BCAST_E_PASS") end
    return found
end

local function snapshotResults(root: string, surface: any, hash: any): any
    local directory = join(root, RESULT_DIRECTORY)
    local snapshot = {}
    if not surface.isDir(directory) then return snapshot end
    local names = surface.readDir(directory)
    if type(names) ~= "table" then fail("BCAST_E_RESULTS") end
    table.sort(names)
    for _, name in names do
        if type(name) == "string" and string.match(name, "^[0-9a-fA-F%-]+%.result%-v2%.json$") ~= nil then
            local path = join(directory, name)
            if not surface.isFile(path) then fail("BCAST_E_RESULTS") end
            local ok, body = pcall(surface.readFile, path)
            if not ok or type(body) ~= "string" or #body == 0 or #body > MAX_RESULT_BYTES then
                fail("BCAST_E_RESULT_SIZE")
            end
            snapshot[name] = {
                path = path,
                size = #body,
                sha256 = digest(hash, body),
            }
        end
    end
    return snapshot
end

local function diffSnapshots(before: any, after: any): { any }
    local added = {}
    for name, old in before do
        local current = after[name]
        if current == nil or current.size ~= old.size or current.sha256 ~= old.sha256 then
            fail("BCAST_E_RESULT_MUTATED")
        end
    end
    for name, current in after do
        if before[name] == nil then table.insert(added, current) end
    end
    table.sort(added, function(left, right) return left.path < right.path end)
    return added
end

local function resultSource(result: any): any
    local source = result.benchmark.source
    if type(source) ~= "table"
        or source.dirty ~= false
        or type(source.revision) ~= "string"
        or (string.match(source.revision, "^[0-9a-f]+$") == nil)
        or (#source.revision ~= 40 and #source.revision ~= 64)
        or type(source.measurementFingerprint) ~= "string"
        or type(source.adapterFingerprint) ~= "string"
    then fail("BCAST_E_RESULT_PROVENANCE") end
    return source
end

local function scalarKey(value: any): string
    local kind = type(value)
    if value == nil then return "N0:" end
    if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then fail("BCAST_E_RESULT_PROVENANCE") end
    local text = tostring(value)
    local tag = if kind == "string" then "S" elseif kind == "number" then "D" else "B"
    return tag .. tostring(#text) .. ":" .. text
end

local function compatibilityKey(result: any): string
    local source = resultSource(result)
    local environment = result.environment
    local host = environment.host
    local studio = environment.studio
    local execution = environment.execution
    local values = {
        result.contract.fingerprint,
        source.measurementFingerprint,
        studio.version, studio.channel,
        host.osFamily, host.architecture, host.osVersion, host.cpuModel,
        host.logicalProcessorCount, host.memoryMiB, host.gpuModel,
        execution.mode, execution.targetFrameRate, execution.serverCount, execution.clientCount,
        result.case.kind, result.case.workloadId, result.case.recipientCount,
        result.adapter.lane, result.adapter.semantics.broadcastMode,
        result.adapter.semantics.repetitionIsolation,
    }
    local encoded = table.create(#values)
    for index, value in values do encoded[index] = scalarKey(value) end
    return table.concat(encoded, "|")
end

local function copySummaries(result: any): any
    local summaries = {}
    for _, measurement in result.measurements do
        if type(measurement) == "table" and type(measurement.metadata) == "table"
            and type(measurement.metadata.id) == "string" and type(measurement.summary) == "table"
        then
            summaries[measurement.metadata.id] = clone(measurement.summary)
        end
    end
    local required = { "submitCallDuration", "frameTime", "drainDuration", "completionDuration" }
    for _, id in required do
        if summaries[id] == nil then fail("BCAST_E_RESULT_METRICS") end
    end
    return summaries
end

local function validateResult(result: any, expected: any, path: string, pass: any, seenRunIds: any, commonKey: string?): any
    local ok, checked = pcall(ResultV2.validate, result)
    if not ok or type(checked) ~= "table" then fail("BCAST_E_RESULT_SCHEMA") end
    result = checked
    if result.status ~= "Valid"
        or result.schema.id ~= "result-v2"
        or result.benchmark.id ~= "relay-event"
        or result.benchmark.version ~= 2
        or result.contract.id ~= "event-session-v1"
        or result.case.kind ~= "Workload"
        or result.case.workloadId ~= "state-broadcast-s2c"
        or result.case.recipientCount ~= expected.recipients
        or result.environment.execution.mode ~= "StudioMultiplayer"
        or result.environment.execution.clientCount ~= expected.recipients
        or result.adapter.id ~= pass.adapterId
        or result.adapter.lane ~= "EquivalentSemantics"
        or result.adapter.semantics.broadcastMode ~= "NativeBroadcast"
        or result.adapter.semantics.repetitionIsolation ~= "PersistentSession"
        or result.conformance.sessionProof.passed ~= true
        or result.conformance.clockProof.passed ~= true
        or result.counts.correct ~= result.counts.expectedDeliveries
        or result.counts.missing ~= 0
        or result.counts.duplicate ~= 0
        or result.counts.unexpected ~= 0
    then fail("BCAST_E_RESULT_PROOF") end
    if not isUuid(result.runId) then fail("BCAST_E_RESULT_ID") end
    local expectedName = string.lower(result.runId) .. ".result-v2.json"
    if string.lower(baseName(path)) ~= expectedName then fail("BCAST_E_RESULT_ID") end
    if seenRunIds[result.runId] then fail("BCAST_E_DUPLICATE_RUN_ID") end
    seenRunIds[result.runId] = true
    local source = resultSource(result)
    if source.revision ~= expected.revision then fail("BCAST_E_SOURCE_CHANGED") end
    local key = compatibilityKey(result)
    if commonKey ~= nil and key ~= commonKey then fail("BCAST_E_INCOMPATIBLE") end
    local summaries = copySummaries(result)
    return {
        result = result,
        source = clone(source),
        compatibilityKey = key,
        summaries = summaries,
    }
end

local function sourceIdentity(root: string, executeFn: any): any
    local revisionResult = execute(executeFn, "git", { "rev-parse", "HEAD" }, root)
    if revisionResult.ok ~= true or type(revisionResult.stdout) ~= "string" then fail("BCAST_E_SOURCE") end
    local revision = trim(revisionResult.stdout)
    if (#revision ~= 40 and #revision ~= 64) or string.match(revision, "^[0-9a-f]+$") == nil then
        fail("BCAST_E_SOURCE")
    end
    local statusResult = execute(executeFn, "git", {
        "status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none",
    }, root)
    if statusResult.ok ~= true or type(statusResult.stdout) ~= "string" then fail("BCAST_E_SOURCE") end
    if #trim(statusResult.stdout) ~= 0 then fail("BCAST_E_SOURCE_DIRTY") end
    return { root = root, revision = revision }
end

local function assertSource(identity: any, executeFn: any)
    local current = sourceIdentity(identity.root, executeFn)
    if current.revision ~= identity.revision then fail("BCAST_E_SOURCE_CHANGED") end
end

local function studioIdentity(path: string, surface: any, hash: any): any
    if not surface.isFile(path) then fail("BCAST_E_STUDIO") end
    local ok, body = pcall(surface.readFile, path)
    if not ok or type(body) ~= "string" or #body == 0 then fail("BCAST_E_STUDIO") end
    return { path = path, size = #body, sha256 = digest(hash, body) }
end

local function assertStudio(identity: any, surface: any, hash: any)
    local current = studioIdentity(identity.path, surface, hash)
    if current.size ~= identity.size or current.sha256 ~= identity.sha256 then fail("BCAST_E_STUDIO_CHANGED") end
end

local function writeExclusive(surface: any, path: string, body: string)
    local ok = pcall(surface.writeFile, path, body, { overwrite = false })
    if not ok then fail("BCAST_E_LEDGER") end
    local readOk, readback = pcall(surface.readFile, path)
    if not readOk or readback ~= body then fail("BCAST_E_LEDGER") end
end

local function writeLedger(surface: any, path: string, ledger: any)
    local body = serde.encode("json", ledger)
    local ok = pcall(surface.writeFile, path, body, { overwrite = true })
    if not ok then fail("BCAST_E_LEDGER") end
end

local function createStudyDirectory(root: string, surface: any, hash: any): string
    local temporary = join(root, ".tmp")
    if not surface.isDir(temporary) then
        local ok = pcall(surface.writeDir, temporary)
        if not ok or not surface.isDir(temporary) then fail("BCAST_E_LEDGER") end
    end
    local seed = string.format("broadcast:%s:%s:%s", root, tostring(os.clock()), tostring({}))
    for attempt = 1, 32 do
        local token = string.sub(digest(hash, seed .. ":" .. tostring(attempt)), 8, 23)
        local directory = join(temporary, "broadcast-study-" .. token)
        if not surface.isDir(directory) and not surface.isFile(directory) then
            local made = pcall(surface.writeDir, directory)
            if made and surface.isDir(directory) then
                local raw = join(directory, "raw")
                local rawMade = pcall(surface.writeDir, raw)
                if rawMade and surface.isDir(raw) then return directory end
                pcall(surface.removeDir, directory)
            end
        end
    end
    fail("BCAST_E_LEDGER")
end

local function summaryVariation(attempts: { any }): any
    local result = {}
    local ids = { "submitCallDuration", "frameTime", "drainDuration", "completionDuration" }
    for pass = 1, 2 do
        local baseline, control
        for _, attempt in attempts do
            if attempt.valid == true and attempt.pass == pass then
                if attempt.label == "baseline" then baseline = attempt
                elseif attempt.label == "control" then control = attempt end
            end
        end
        if baseline ~= nil and control ~= nil then
            local row = {}
            for _, id in ids do
                local left = baseline.summaries[id]
                local right = control.summaries[id]
                if left ~= nil and right ~= nil and type(left.median) == "number" and type(right.median) == "number" then
                    row[id] = {
                        baselineMedian = left.median,
                        controlMedian = right.median,
                        absoluteDifference = right.median - left.median,
                        relativeDifference = if left.median == 0 then nil else (right.median - left.median) / left.median,
                    }
                end
            end
            result[tostring(pass)] = row
        end
    end
    return result
end

local function run(options: any, dependencies: any?): any
    local deps = dependencies or {}
    local surface = deps.fs or fs
    local executeFn = deps.execute or process.exec
    local hostExecute = deps.execute or runProcessBounded
    local hash = deps.hash or serde.hash
    local osName = options.os or process.os
    local baseline = sourceIdentity(options.baseline, executeFn)
    local candidate = if options.candidate == nil then nil else sourceIdentity(options.candidate, executeFn)
    if candidate ~= nil and candidate.root == baseline.root then fail("BCAST_E_ARGS") end
    local studio = studioIdentity(options.studio, surface, hash)
    local studyDirectory = createStudyDirectory(options.baseline, surface, hash)
    local ledgerPath = join(studyDirectory, "ledger.json")
    local ledger: any = {
        schema = STUDY_SCHEMA,
        version = STUDY_VERSION,
        startedUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        topology = {
            mode = "PersistentBenchmark", caseId = "state-broadcast-s2c", recipients = options.recipients,
        },
        studio = clone(studio),
        sources = { baseline = clone(baseline), candidate = if candidate == nil then nil else clone(candidate) },
        schedule = plan(options).schedule,
        attempts = {},
        variation = {},
    }
    writeLedger(surface, ledgerPath, ledger)

    local seenRunIds = {}
    local commonKey: string? = nil
    local baselineAdapterFingerprint: string? = nil
    local executionOptions = {
        "run", join(baseline.root, HOST_SCRIPT),
        "--studio", options.studio,
        "--mode", "PersistentBenchmark",
        "--case", "state-broadcast-s2c",
        "--recipients", tostring(options.recipients),
    }
    local ordered = schedule(options)
    for index, item in ordered do
        local attempt: any = {
            index = index,
            pass = item.pass,
            order = item.order,
            label = item.label,
            adapterId = item.adapterId,
            root = item.root,
            startedUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            valid = false,
        }
        local stdoutPath = join(studyDirectory, string.format("attempt-%03d.stdout.log", index))
        local stderrPath = join(studyDirectory, string.format("attempt-%03d.stderr.log", index))
        attempt.stdoutPath = stdoutPath
        attempt.stderrPath = stderrPath
        table.insert(ledger.attempts, attempt)
        -- Persist the checkpoint before launching the child. A host or shell
        -- interruption must leave an in-flight attempt visible in the ledger.
        writeLedger(surface, ledgerPath, ledger)
        local ok, failure = pcall(function()
            local expectedSource = if item.root == baseline.root then baseline else candidate
            if expectedSource == nil then fail("BCAST_E_SOURCE") end
            assertSource(expectedSource, executeFn)
            if item.root ~= baseline.root then assertSource(baseline, executeFn) end
            assertStudio(studio, surface, hash)
            local before = snapshotResults(item.root, surface, hash)
            local command = table.clone(executionOptions)
            table.insert(command, "--adapter")
            table.insert(command, item.adapterId)
            local launch = execute(hostExecute, "lune", command, item.root)
            local rawStdout = if type(launch.stdout) == "string" then launch.stdout else ""
            local rawStderr = if type(launch.stderr) == "string" then launch.stderr else ""
            local stdoutTruncated = launch.stdoutTruncated == true or #rawStdout > PROCESS_OUTPUT_MAX_BYTES
            local stderrTruncated = launch.stderrTruncated == true or #rawStderr > PROCESS_OUTPUT_MAX_BYTES
            local stdout = string.sub(rawStdout, 1, PROCESS_OUTPUT_MAX_BYTES)
            local stderr = string.sub(rawStderr, 1, PROCESS_OUTPUT_MAX_BYTES)
            writeExclusive(surface, stdoutPath, stdout)
            writeExclusive(surface, stderrPath, stderr)
            attempt.exitCode = launch.code
            attempt.stdoutBytes = #stdout
            attempt.stderrBytes = #stderr
            attempt.stdoutTruncated = stdoutTruncated
            attempt.stderrTruncated = stderrTruncated
            local after = snapshotResults(item.root, surface, hash)
            local added = diffSnapshots(before, after)
            attempt.addedResults = #added
            local archivedBodies = {}
            for addedIndex, entry in added do
                local rawPath = join(studyDirectory .. "/raw", string.format("attempt-%03d-%d-%s", index, addedIndex, baseName(entry.path)))
                local body = surface.readFile(entry.path)
                writeExclusive(surface, rawPath, body)
                if #body ~= entry.size or digest(hash, body) ~= entry.sha256 then fail("BCAST_E_RAW_RESULT") end
                archivedBodies[entry.path] = body
                if attempt.rawResult == nil then attempt.rawResult = {} end
                table.insert(attempt.rawResult, {
                    sourcePath = entry.path,
                    path = rawPath,
                    size = entry.size,
                    sha256 = entry.sha256,
                })
            end
            -- Capture the result evidence before the provenance checks below
            -- can stop the attempt. A changing checkout or executable must
            -- leave an auditable raw artifact and log.
            assertSource(expectedSource, executeFn)
            if item.root ~= baseline.root then assertSource(baseline, executeFn) end
            assertStudio(studio, surface, hash)
            if attempt.stdoutTruncated or attempt.stderrTruncated then fail("BCAST_E_OUTPUT_LIMIT") end
            if launch.ok ~= true then fail("BCAST_E_HOST") end
            if #added ~= 1 then fail("BCAST_E_RESULT_FRESHNESS") end
            local pass = parsePassOutput(stdout)
            local entry = added[1]
            if not pathsEqual(pass.path, entry.path, osName) then fail("BCAST_E_RESULT_PATH") end
            local body = archivedBodies[entry.path]
            local decodedOk, decoded = pcall(serde.decode, "json", body)
            if not decodedOk or type(decoded) ~= "table" then fail("BCAST_E_RESULT_JSON") end
            local checked = validateResult(decoded, {
                recipients = options.recipients,
                revision = expectedSource.revision,
            }, entry.path, item, seenRunIds, commonKey)
            if pass.launchId ~= string.lower(checked.result.runId) then fail("BCAST_E_RESULT_ID") end
            if commonKey == nil then commonKey = checked.compatibilityKey end
            if item.label == "baseline" then
                baselineAdapterFingerprint = checked.source.adapterFingerprint
            elseif item.label == "control"
                and (baselineAdapterFingerprint == nil or checked.source.adapterFingerprint ~= baselineAdapterFingerprint)
            then
                fail("BCAST_E_ADAPTER_SOURCE")
            end
            attempt.runId = checked.result.runId
            attempt.resultPath = entry.path
            attempt.resultSize = entry.size
            attempt.resultSha256 = entry.sha256
            attempt.sourceRevision = checked.source.revision
            attempt.measurementFingerprint = checked.source.measurementFingerprint
            attempt.contractFingerprint = checked.result.contract.fingerprint
            attempt.summaries = checked.summaries
            attempt.valid = true
        end)
        attempt.finishedUtc = os.date("!%Y-%m-%dT%H:%M:%SZ")
        if not ok then
            attempt.failure = tostring(failure)
            ledger.variation = summaryVariation(ledger.attempts)
            writeLedger(surface, ledgerPath, ledger)
            error(failure, 0)
        end
        ledger.variation = summaryVariation(ledger.attempts)
        writeLedger(surface, ledgerPath, ledger)
    end
    ledger.finishedUtc = os.date("!%Y-%m-%dT%H:%M:%SZ")
    ledger.variation = summaryVariation(ledger.attempts)
    writeLedger(surface, ledgerPath, ledger)
    return { ledgerPath = ledgerPath, ledger = ledger }
end

local function main(arguments: { string })
    local options = parseArgs(arguments, process.os, process.cwd)
    if options.mode == "plan" then
        print(serde.encode("json", plan(options)))
        return
    end
    local completed = run(options)
    print(`PASS Relay.BroadcastStudy {completed.ledgerPath}`)
end

return table.freeze({
    RESULT_DIRECTORY = RESULT_DIRECTORY,
    HOST_SCRIPT = HOST_SCRIPT,
    parseArgs = parseArgs,
    schedule = schedule,
    plan = plan,
    parsePassOutput = parsePassOutput,
    snapshotResults = snapshotResults,
    diffSnapshots = diffSnapshots,
    compatibilityKey = compatibilityKey,
    copySummaries = copySummaries,
    validateResult = validateResult,
    sourceIdentity = sourceIdentity,
    summaryVariation = summaryVariation,
    PROCESS_OUTPUT_MAX_BYTES = PROCESS_OUTPUT_MAX_BYTES,
    runProcessBounded = runProcessBounded,
    run = run,
    main = main,
})
