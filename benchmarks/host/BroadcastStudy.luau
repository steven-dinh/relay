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
local StudyInputManifest = require("./StudyInputManifest")

local RESULT_DIRECTORY = "benchmarks/results/local"
local HOST_SCRIPT = "benchmarks/host/run-event-v1.luau"
local STUDY_SCHEMA = "Relay.BroadcastStudyLedger"
local STUDY_VERSION = 2
local RESTART_VERSION = 3
local SUMMARY_IDS = table.freeze({ "submitCallDuration", "frameTime", "drainDuration", "completionDuration" })
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

local function restartLedgerPath(value: string, baseline: string, osName: string): string
    local selected = canonicalPath(value)
    local directory, token = string.match(selected, "^(.*)/broadcast%-study%-(%x+)/ledger%.json$")
    if directory == nil or #token ~= 16 or not pathsEqual(directory, join(baseline, ".tmp"), osName)
        or not pathsEqual(selected, value, osName) then fail("BCAST_E_RESTART_PATH") end
    return selected
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
    local restartLedger: string? = nil
    local index = 1
    while index <= #arguments do
        local argument = arguments[index]
        if argument == "--plan" or argument == "--run" then
            if mode ~= nil then fail("BCAST_E_ARGS") end
            mode = string.sub(argument, 3)
            index += 1
        elseif argument == "--studio" or argument == "--recipients"
            or argument == "--baseline" or argument == "--candidate" or argument == "--restart-ledger"
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
            elseif argument == "--restart-ledger" then
                if restartLedger ~= nil then fail("BCAST_E_ARGS") end
                restartLedger = if isAbsolute(value, actualOs) then canonicalPath(value) else join(actualCwd, value)
            else
                if candidate ~= nil then fail("BCAST_E_ARGS") end
                candidate = if isAbsolute(value, actualOs) then canonicalPath(value) else join(actualCwd, value)
            end
            index += 2
        else
            fail("BCAST_E_ARGS")
        end
    end
    if mode == nil or studio == nil or recipients == nil or (restartLedger ~= nil and mode ~= "run") then
        fail("BCAST_E_ARGS")
    end
    local selectedBaseline = baseline or actualCwd
    if candidate ~= nil and pathsEqual(candidate, selectedBaseline, actualOs) then fail("BCAST_E_ARGS") end
    if restartLedger ~= nil then restartLedger = restartLedgerPath(restartLedger, selectedBaseline, actualOs) end
    return table.freeze({
        mode = mode,
        studio = studio,
        recipients = recipients,
        baseline = canonicalPath(selectedBaseline),
        candidate = if candidate == nil then nil else canonicalPath(candidate),
        restartLedger = restartLedger,
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
    local result = forward
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

local function parseHostStages(stdout: string): any?
    if type(stdout) ~= "string" then return nil end
    local found = nil
    for line in string.gmatch(string.gsub(stdout, "\r\n", "\n"), "[^\n]+") do
        local body = string.match(line, "^HOST_STAGES_V1 (.+)$")
        if body ~= nil then
            if found ~= nil or #body > 8_192 then return nil end
            local ok, decoded = pcall(serde.decode, "json", body)
            if not ok or type(decoded) ~= "table" then return nil end
            found = decoded
        end
    end
    if found == nil or found.version ~= 1 or found.unit ~= "Seconds" or found.clock ~= "os.clock"
        or type(found.intervals) ~= "table" or #found.intervals < 1 or #found.intervals > 5
        or (found.launchId ~= nil and not isUuid(found.launchId)) then return nil end
    local allowed = { total = true, build = true, launch = true, studioProcess = true, hostTeardown = true }
    local seen = {}
    local intervals = {}
    for _, interval in found.intervals do
        if type(interval) ~= "table" or allowed[interval.id] ~= true or seen[interval.id]
            or (interval.status ~= "Complete" and interval.status ~= "Failed" and interval.status ~= "Timeout")
        then return nil end
        seen[interval.id] = true
        local start, finish = interval.startedSeconds, interval.finishedSeconds
        if start ~= nil and (type(start) ~= "number" or start ~= start or start < 0 or start == math.huge) then return nil end
        if finish ~= nil and (type(finish) ~= "number" or finish ~= finish or finish < 0 or finish == math.huge) then return nil end
        if start ~= nil and finish ~= nil and finish < start then return nil end
        if (start == nil or finish == nil) and interval.timingUnavailable ~= true then return nil end
        table.insert(intervals, { id = interval.id, status = interval.status,
            startedSeconds = start, finishedSeconds = finish,
            durationSeconds = if start == nil or finish == nil then nil else finish - start,
            timingUnavailable = if start == nil or finish == nil then true else nil })
    end
    if not seen.total then return nil end
    return { version = 1, unit = "Seconds", clock = "os.clock", launchId = found.launchId,
        intervals = intervals, unavailable = {
            readiness = "no authenticated readiness boundary",
            collection = "Studio workload collection is inside studioProcess",
            engineDrain = "Studio drain is inside studioProcess" } }
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
    local values = table.pack(
        result.contract.fingerprint,
        source.measurementFingerprint,
        studio.version, studio.channel,
        host.osFamily, host.architecture, host.osVersion, host.cpuModel,
        host.logicalProcessorCount, host.memoryMiB, host.gpuModel,
        execution.mode, execution.targetFrameRate, execution.serverCount, execution.clientCount,
        result.case.kind, result.case.workloadId, result.case.recipientCount,
        result.adapter.lane, result.adapter.semantics.broadcastMode,
        result.adapter.semantics.repetitionIsolation
    )
    local encoded = table.create(values.n)
    for index = 1, values.n do encoded[index] = scalarKey(values[index]) end
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
    for _, id in SUMMARY_IDS do
        if summaries[id] == nil then fail("BCAST_E_RESULT_METRICS") end
    end
    return summaries
end

local function adjacent(left: any, right: any): boolean
    if type(left) ~= "number" or type(right) ~= "number" or left ~= left or right ~= right
        or left < 0 or right < 0 or left == math.huge or right == math.huge then return false end
    local minimum = math.ldexp(1, -1074)
    if right == 0 then return left <= minimum end
    local mantissa, exponent = math.frexp(right)
    local upward = math.max(minimum, math.ldexp(1, exponent - 53))
    local downward = if mantissa == 0.5 then math.max(minimum, math.ldexp(1, exponent - 54)) else upward
    return if left < right then right - left <= downward else left - right <= upward
end

local function summaryAgreement(left: any, right: any): { any }
    if type(left) ~= "table" or type(right) ~= "table" then fail("BCAST_E_SUMMARY") end
    local differences = {}
    for key, value in left do
        if value == right[key] then continue end
        if right.kind ~= "MedianAndP95" or (key ~= "median" and key ~= "p95")
            or not adjacent(value, right[key]) then fail("BCAST_E_SUMMARY") end
        table.insert(differences, { statistic = key, ledgerValue = value,
            rawDerivedValue = right[key], reason = "adjacent-binary64-rounding" })
    end
    for key in right do if left[key] == nil then fail("BCAST_E_SUMMARY") end end
    return differences
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
    local runKey = string.lower(result.runId)
    if seenRunIds[runKey] then fail("BCAST_E_DUPLICATE_RUN_ID") end
    seenRunIds[runKey] = true
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

-- Lune 0.10.5 writeFile(overwrite=false) is not an exclusive create. Stream
-- the bytes into a Windows CreateNew handle so an occupied path survives.
local function atomicCreateFile(path: string, body: string)
    local systemRoot = process.env.SystemRoot
    if process.os ~= "windows" or type(systemRoot) ~= "string" or #systemRoot == 0 then
        fail("BCAST_E_LEDGER")
    end
    local executable = join(systemRoot, "System32/WindowsPowerShell/v1.0/powershell.exe")
    local script = [[
$ErrorActionPreference = 'Stop'
try {
    $stream = [System.IO.File]::Open($env:RELAY_STUDY_EXCLUSIVE_PATH,
        [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        [Console]::OpenStandardInput().CopyTo($stream)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
} catch { exit 17 }
]]
    local started, child = pcall(process.create, executable,
        { "-NoProfile", "-NonInteractive", "-Command", script },
        { env = { RELAY_STUDY_EXCLUSIVE_PATH = path } })
    if not started or child == nil then fail("BCAST_E_LEDGER") end
    local wrote = pcall(function() child.stdin:write(body) end)
    local closed = pcall(function() child.stdin:close() end)
    local status = child:status()
    while status == nil do task.wait(0.01); status = child:status() end
    if not wrote or not closed or status.ok ~= true then fail("BCAST_E_LEDGER") end
end

local function writeExclusive(surface: any, path: string, body: string, createExclusive: any)
    local ok = pcall(createExclusive, path, body)
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
            for _, id in SUMMARY_IDS do
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

local function sampleClock(clock: any, previous: number?): number?
    local ok, value = pcall(clock)
    if not ok or type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
        or (previous ~= nil and value < previous) then
        return nil
    end
    return value
end

local function finishInterval(interval: any, elapsed: number?, status: string)
    if elapsed ~= nil and interval.startedSeconds ~= nil then
        interval.finishedSeconds = elapsed
        interval.durationSeconds = elapsed - interval.startedSeconds
    else
        interval.timingUnavailable = true
    end
    interval.status = status
end

local function run(options: any, dependencies: any?): any
    local deps = dependencies or {}
    local surface = deps.fs or fs
    local createExclusive = deps.createExclusive or atomicCreateFile
    local executeFn = deps.execute or process.exec
    local hostExecute = deps.execute or runProcessBounded
    local hash = deps.hash or serde.hash
    local clock = deps.clock or os.clock
    local osName = options.os or process.os
    local baseline = sourceIdentity(options.baseline, executeFn)
    local candidate = if options.candidate == nil then nil else sourceIdentity(options.candidate, executeFn)
    if candidate ~= nil and candidate.root == baseline.root then fail("BCAST_E_ARGS") end
    local studio = studioIdentity(options.studio, surface, hash)
    local studyPlan = plan(options)
    local collectInputs = deps.collectInputManifest or StudyInputManifest.collect
    local function inputs(): any
        return collectInputs(options, studyPlan, { fs = surface, execute = executeFn, hash = hash,
            toolRoot = deps.toolRoot, studioIdentity = studio })
    end
    local inputManifest = inputs()
    if not StudyInputManifest.verify(inputManifest, hash)
        or inputManifest.studioSha256 ~= studio.sha256
    then fail("BCAST_E_INPUT_MANIFEST") end
    local previous = nil
    if options.restartLedger ~= nil then
        local recoveryModule = require("./BroadcastRecoveryAudit")
        local recoveryAudit = deps.recoveryAudit or recoveryModule.audit
        local audited = recoveryAudit(restartLedgerPath(options.restartLedger, baseline.root, osName),
            deps.recoveryAuditDependencies)
        if type(audited) ~= "table" or audited.status ~= "FreshFullStudyRequired"
            or audited.selection ~= "none" or audited.inputManifestSha256 ~= inputManifest.sha256
            or type(audited.lineageLength) ~= "number" or audited.lineageLength % 1 ~= 0
            or audited.lineageLength < 1 or audited.lineageLength + 1 > recoveryModule.MAX_LINEAGE_LENGTH
            or type(audited.ledgerSha256) ~= "string" or type(audited.previousAttempts) ~= "table"
            or type(audited.sources) ~= "table"
            or type(audited.sources.baseline) ~= "table"
            or not pathsEqual(audited.sources.baseline.root, baseline.root, osName)
            or audited.sources.baseline.revision ~= baseline.revision
            or (candidate ~= nil and (type(audited.sources.candidate) ~= "table"
                or not pathsEqual(audited.sources.candidate.root, candidate.root, osName)
                or audited.sources.candidate.revision ~= candidate.revision))
            or (candidate == nil and audited.sources.candidate ~= nil)
        then fail("BCAST_E_RESTART_INPUT") end
        for _, prior in audited.previousAttempts do
            if prior.state == "Interrupted" then fail("BCAST_E_RESTART_OWNERSHIP") end
        end
        previous = audited
    end
    local function assertInputs()
        local current = inputs()
        if not StudyInputManifest.verify(current, hash) or current.sha256 ~= inputManifest.sha256 then
            fail("BCAST_E_INPUT_CHANGED")
        end
    end
    local studyDirectory = createStudyDirectory(options.baseline, surface, hash)
    local ledgerPath = join(studyDirectory, "ledger.json")
    local ledger: any = {
        schema = STUDY_SCHEMA,
        version = if previous == nil then STUDY_VERSION else RESTART_VERSION,
        collectionId = if previous == nil then nil else baseName(studyDirectory),
        restartOf = if previous == nil then nil else {
            path = previous.ledger, sha256 = previous.ledgerSha256,
            inputManifestSha256 = previous.inputManifestSha256,
        },
        startedUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        topology = {
            mode = "PersistentBenchmark", caseId = "state-broadcast-s2c", recipients = options.recipients,
        },
        studio = clone(studio),
        inputManifest = clone(inputManifest),
        sources = { baseline = clone(baseline), candidate = if candidate == nil then nil else clone(candidate) },
        schedule = studyPlan.schedule,
        attempts = {},
        variation = {},
    }
    writeExclusive(surface, ledgerPath, serde.encode("json", ledger), createExclusive)

    local seenRunIds = {}
    if previous ~= nil then
        for _, prior in previous.previousAttempts do
            for _, archive in prior.archives do
                seenRunIds[string.lower(archive.runId)] = true
            end
        end
    end
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
        local clockOrigin = sampleClock(clock, nil)
        local lastClock = clockOrigin
        local function sampleElapsed(): number?
            if clockOrigin == nil then return nil end
            lastClock = sampleClock(clock, lastClock)
            if lastClock == nil then clockOrigin = nil; return nil end
            return lastClock - clockOrigin
        end
        local interval: any = { id = "preflight", status = "Running",
            startedSeconds = if clockOrigin == nil then nil else 0,
            timingUnavailable = if clockOrigin == nil then true else nil }
        -- D03 coarse host diagnostics only. The child interval includes setup,
        -- readiness, warmup, measurement, drain and exit; none are attributed here.
        -- Detailed phases and observer overhead remain deferred. Historical
        -- ledgers may omit this optional, independently versioned field. Clock
        -- failure marks timings unavailable without obstructing raw evidence.
        local coarseHostStages = { version = 1, unit = "Seconds", intervals = { interval } }
        local attempt: any = {
            index = index,
            pass = item.pass,
            order = item.order,
            label = item.label,
            adapterId = item.adapterId,
            root = item.root,
            startedUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            inputManifestSha256 = inputManifest.sha256,
            coarseHostStages = coarseHostStages,
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
            assertInputs()
            local before = snapshotResults(item.root, surface, hash)
            local command = table.clone(executionOptions)
            table.insert(command, "--adapter")
            table.insert(command, item.adapterId)
            local elapsed = sampleElapsed()
            finishInterval(interval, elapsed, "Complete")
            interval = { id = "hostExecution", status = "Running", startedSeconds = elapsed,
                timingUnavailable = if elapsed == nil then true else nil }
            table.insert(coarseHostStages.intervals, interval)
            writeLedger(surface, ledgerPath, ledger)
            local launch = execute(hostExecute, "lune", command, item.root)
            elapsed = sampleElapsed()
            finishInterval(interval, elapsed, if launch.ok == true then "Complete" else "Failed")
            interval = { id = "archiveValidation", status = "Running", startedSeconds = elapsed,
                timingUnavailable = if elapsed == nil then true else nil }
            table.insert(coarseHostStages.intervals, interval)
            writeLedger(surface, ledgerPath, ledger)
            local rawStdout = if type(launch.stdout) == "string" then launch.stdout else ""
            local rawStderr = if type(launch.stderr) == "string" then launch.stderr else ""
            local stdoutTruncated = launch.stdoutTruncated == true or #rawStdout > PROCESS_OUTPUT_MAX_BYTES
            local stderrTruncated = launch.stderrTruncated == true or #rawStderr > PROCESS_OUTPUT_MAX_BYTES
            local stdout = string.sub(rawStdout, 1, PROCESS_OUTPUT_MAX_BYTES)
            local stderr = string.sub(rawStderr, 1, PROCESS_OUTPUT_MAX_BYTES)
            attempt.hostStages = if stdoutTruncated then nil else parseHostStages(stdout)
            writeExclusive(surface, stdoutPath, stdout, createExclusive)
            writeExclusive(surface, stderrPath, stderr, createExclusive)
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
                writeExclusive(surface, rawPath, body, createExclusive)
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
            assertInputs()
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
            if attempt.hostStages ~= nil and attempt.hostStages.launchId ~= pass.launchId then
                attempt.hostStages = nil
            end
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
        finishInterval(interval, sampleElapsed(), if ok then "Complete" else "Failed")
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
    parseHostStages = parseHostStages,
    snapshotResults = snapshotResults,
    diffSnapshots = diffSnapshots,
    compatibilityKey = compatibilityKey,
    copySummaries = copySummaries,
    summaryAgreement = summaryAgreement,
    validateResult = validateResult,
    sourceIdentity = sourceIdentity,
    restartLedgerPath = restartLedgerPath,
    summaryVariation = summaryVariation,
    PROCESS_OUTPUT_MAX_BYTES = PROCESS_OUTPUT_MAX_BYTES,
    atomicCreateFile = atomicCreateFile,
    runProcessBounded = runProcessBounded,
    run = run,
    main = main,
})
