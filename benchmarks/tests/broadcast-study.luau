--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Study = require("../host/BroadcastStudy")
local RecoveryAudit = require("../host/BroadcastRecoveryAudit")
local Report = require("../reporting/BroadcastStudyReport")
local Fingerprint = require("../host/MeasurementFingerprint")
local ResultV2 = require("../contracts/result-v2")
local Fixtures = require("./support/HostRuntimeFixtures")

local function clone(value: any): any
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in value do result[clone(key)] = clone(child) end
    return result
end

local function reject(code: string, callback: () -> ())
    local ok, message = pcall(callback)
    assert(not ok and string.find(tostring(message), code, 1, true) ~= nil,
        `expected {code}, got {tostring(message)}`)
end

local parsed = Study.parseArgs({ "--plan", "--studio", "C:/Studio.exe", "--recipients", "4" }, "windows", "E:/relay")
assert(parsed.mode == "plan" and parsed.recipients == 4 and parsed.baseline == "E:/relay"
    and parsed.candidate == nil, "default baseline parsing changed")
local withCandidate = Study.parseArgs({
    "--run", "--studio", "C:/Studio.exe", "--recipients", "8", "--baseline", "E:/baseline",
    "--candidate", "E:/candidate",
}, "windows", "E:/relay")
assert(withCandidate.baseline == "E:/baseline" and withCandidate.candidate == "E:/candidate",
    "checkout parsing changed")
local relativeCheckouts = Study.parseArgs({
    "--plan", "--studio", "C:/Studio.exe", "--recipients", "1", "--baseline", ".", "--candidate", "../candidate",
}, "windows", "E:/relay")
assert(relativeCheckouts.baseline == "E:/relay" and relativeCheckouts.candidate == "E:/candidate",
    "relative checkout paths were not canonicalized")
reject("BCAST_E_ARGS", function()
    Study.parseArgs({ "--run", "--studio", "studio.exe", "--recipients", "1" }, "windows", "E:/relay")
end)
reject("BCAST_E_ARGS", function()
    Study.parseArgs({ "--run", "--studio", "C:/Studio.exe", "--recipients", "2" }, "windows", "E:/relay")
end)
reject("BCAST_E_ARGS", function()
    Study.parseArgs({ "--plan", "--run", "--studio", "C:/Studio.exe", "--recipients", "1" }, "windows", "E:/relay")
end)
reject("BCAST_E_ARGS", function()
    Study.parseArgs({ "--run", "--studio", "C:/Studio.exe", "--recipients", "1", "--candidate", "E:/relay" }, "windows", "E:/relay")
end)
local restartArgument = "E:/relay/.tmp/broadcast-study-0123456789abcdef/ledger.json"
assert(Study.parseArgs({ "--run", "--studio", "C:/Studio.exe", "--recipients", "1",
    "--restart-ledger", restartArgument }, "windows", "E:/relay").restartLedger == restartArgument,
    "restart ledger argument changed")
reject("BCAST_E_ARGS", function()
    Study.parseArgs({ "--plan", "--studio", "C:/Studio.exe", "--recipients", "1",
        "--restart-ledger", restartArgument }, "windows", "E:/relay")
end)
reject("BCAST_E_RESTART_PATH", function()
    Study.parseArgs({ "--run", "--studio", "C:/Studio.exe", "--recipients", "1",
        "--restart-ledger", "E:/other/.tmp/broadcast-study-0123456789abcdef/ledger.json" },
        "windows", "E:/relay")
end)

local schedule = Study.schedule(withCandidate)
assert(#schedule == 8, "candidate study must have eight fresh sessions")
assert(schedule[1].label == "native" and schedule[2].label == "baseline"
    and schedule[3].label == "control" and schedule[4].label == "candidate", "forward order changed")
assert(schedule[5].pass == 2 and schedule[5].order == "reverse" and schedule[5].label == "candidate"
    and schedule[6].label == "control" and schedule[7].label == "baseline" and schedule[8].label == "native",
    "reverse order changed")
local noCandidate = Study.schedule(parsed)
assert(#noCandidate == 6 and noCandidate[4].label == "control" and noCandidate[6].label == "native",
    "native/baseline/control reverse schedule changed")

local pass = Study.parsePassOutput("diagnostic\nPASS Relay.EventV1.Benchmark 00112233-4455-4677-8899-aabbccddeeff E:/relay/benchmarks/results/local/00112233-4455-4677-8899-aabbccddeeff.result-v2.json\n")
assert(pass.launchId == "00112233-4455-4677-8899-aabbccddeeff", "PASS launch identity changed")
reject("BCAST_E_PASS", function() Study.parsePassOutput('{"runId":"fake"}\n') end)
reject("BCAST_E_PASS", function()
    Study.parsePassOutput("PASS Relay.EventV1.Benchmark 00112233-4455-4677-8899-aabbccddeeff a.json\nPASS Relay.EventV1.Benchmark 00112233-4455-4677-8899-aabbccddeeff b.json")
end)

local before = {
    ["old.result-v2.json"] = { path = "old.result-v2.json", size = 10, sha256 = "sha256:old" },
}
local after = {
    ["old.result-v2.json"] = { path = "old.result-v2.json", size = 10, sha256 = "sha256:old" },
    ["new.result-v2.json"] = { path = "new.result-v2.json", size = 12, sha256 = "sha256:new" },
}
assert(#Study.diffSnapshots(before, after) == 1, "fresh result diff changed")
reject("BCAST_E_RESULT_MUTATED", function()
    Study.diffSnapshots(before, {
        ["old.result-v2.json"] = { path = "old.result-v2.json", size = 11, sha256 = "sha256:changed" },
    })
end)
assert(#Study.diffSnapshots(before, before) == 0, "unchanged result set was not recognized")

local sourceCalls = {}
local source = Study.sourceIdentity("E:/relay", function(program, arguments, options)
    table.insert(sourceCalls, { program = program, arguments = arguments, options = options })
    if arguments[1] == "rev-parse" then return { ok = true, stdout = string.rep("a", 40) .. "\r\n" } end
    return { ok = true, stdout = "\r\n" }
end)
assert(source.revision == string.rep("a", 40) and #sourceCalls == 2
    and sourceCalls[1].options.cwd == "E:/relay" and sourceCalls[1].program == "git",
    "source pinning did not use structured git calls")

-- The study validator accepts only a canonical, authenticated Result V2 shape.
-- Build it from the existing bounded fixture so this test never launches Studio.
local _, fixture = Fixtures.maximum()
local function makeResult(runId: string, adapterId: string, revision: string?): any
    local result = clone(fixture)
    local sourceRevision = revision or string.rep("a", 40)
    result.schema = { id = "result-v2", version = 2 }
    result.benchmark.version = 2
    result.contract.id = "event-session-v1"
    result.benchmark.source.measurementFingerprint = "sha256:" .. string.rep("c", 64)
    result.benchmark.source.adapterFingerprint = "sha256:" .. (if adapterId == "native-reliable" then string.rep("d", 64) else string.rep("e", 64))
    result.benchmark.source.revision = sourceRevision
    result.runId = runId
    result.adapter.id = adapterId
    result.adapter.lane = "EquivalentSemantics"
    result.adapter.semantics.repetitionIsolation = "PersistentSession"
    if adapterId == "native-reliable" then
        result.adapter.displayName = "Roblox RemoteEvent"
        result.adapter.integrationKind = "EngineBuiltIn"
        result.adapter.library = {
            id = "roblox-remote-event", displayName = "Roblox RemoteEvent", version = "0.650.0.6500000",
            provenance = { kind = "EngineBuiltIn", studioVersion = "0.650.0.6500000" },
        }
    else
        result.adapter.displayName = "Relay"
        result.adapter.integrationKind = "Runtime"
        result.adapter.library = {
            id = "relay", displayName = "Relay", version = "0.1.0",
            provenance = {
                kind = "Repository", sourceRepository = "https://github.com/steven-dinh/relay",
                revision = sourceRevision, checksum = "sha256:" .. string.rep("f", 64), license = "MIT",
            },
        }
    end
    result.case.recipientCount = 1
    result.environment.execution.mode = "StudioMultiplayer"
    result.environment.execution.clientCount = 1
    result.conformance.sessionProof = { version = 1, passed = true }
    return ResultV2.validate(result)
end

local result = makeResult("00112233-4455-4677-8899-aabbccddeeff", "native-reliable")
local validated = Study.validateResult(result, { recipients = 1, revision = string.rep("a", 40) },
    "E:/relay/benchmarks/results/local/00112233-4455-4677-8899-aabbccddeeff.result-v2.json",
    { adapterId = "native-reliable" }, {}, nil)
assert(validated.result.schema.id == "result-v2" and validated.summaries.frameTime ~= nil
    and validated.summaries.submitCallDuration ~= nil, "valid Result V2 was not retained")
local optionalEnvironment = clone(result)
optionalEnvironment.environment.studio.channel = nil
optionalEnvironment.environment.host = {
    osFamily = result.environment.host.osFamily,
    architecture = result.environment.host.architecture,
}
optionalEnvironment = ResultV2.validate(optionalEnvironment)
local optionalKey = Study.compatibilityKey(optionalEnvironment)
assert(optionalKey ~= Study.compatibilityKey(result), "missing environment metadata was not distinguished")
local optionalValidated = Study.validateResult(optionalEnvironment,
    { recipients = 1, revision = string.rep("a", 40) },
    "E:/relay/benchmarks/results/local/00112233-4455-4677-8899-aabbccddeeff.result-v2.json",
    { adapterId = "native-reliable" }, {}, optionalKey)
assert(optionalValidated.compatibilityKey == optionalKey, "optional environment metadata rejected a compatible result")
local changed = clone(result)
changed.environment.host.architecture = "arm64"
changed = ResultV2.validate(changed)
assert(Study.compatibilityKey(result) ~= Study.compatibilityKey(changed), "host mismatch was not visible")
local framedLeft = clone(result)
framedLeft.environment.host.osVersion = "ab"
framedLeft.environment.host.cpuModel = "c"
framedLeft = ResultV2.validate(framedLeft)
local framedRight = clone(result)
framedRight.environment.host.osVersion = "a"
framedRight.environment.host.cpuModel = "bc"
framedRight = ResultV2.validate(framedRight)
assert(Study.compatibilityKey(framedLeft) ~= Study.compatibilityKey(framedRight),
    "compatibility scalar framing allowed a delimiter collision")
local duplicate = clone(result)
reject("BCAST_E_DUPLICATE_RUN_ID", function()
    Study.validateResult(duplicate, { recipients = 1, revision = string.rep("a", 40) },
        "E:/relay/benchmarks/results/local/00112233-4455-4677-8899-aabbccddeeff.result-v2.json",
        { adapterId = "native-reliable" }, { [result.runId] = true }, nil)
end)

-- Exercise the actual serial orchestration with bounded in-memory process and
-- filesystem surfaces. The fake creates canonical Result V2 files, so this
-- covers the same freshness, provenance, and raw-copy paths as a real host.
local function memorySurface(studioPath: string, candidateRoot: string?)
    local files: { [string]: string } = { [studioPath] = "studio-bytes" }
    local directories: { [string]: boolean } = {
        ["E:/relay"] = true,
        ["E:/relay/.tmp"] = true,
        ["E:/relay/benchmarks"] = true,
        ["E:/relay/benchmarks/results"] = true,
        ["E:/relay/benchmarks/results/local"] = true,
    }
    if candidateRoot ~= nil then
        directories[candidateRoot] = true
        directories[candidateRoot .. "/benchmarks"] = true
        directories[candidateRoot .. "/benchmarks/results"] = true
        directories[candidateRoot .. "/benchmarks/results/local"] = true
    end
    local surface = {}
    function surface.isDir(path: string): boolean return directories[path] == true end
    function surface.isFile(path: string): boolean return files[path] ~= nil end
    function surface.readFile(path: string): string
        local body = files[path]
        assert(body ~= nil, `missing fake file {path}`)
        return body
    end
    function surface.readDir(path: string): { string }
        local output = {}
        local prefix = path .. "/"
        for directoryPath in directories do
            if string.sub(directoryPath, 1, #prefix) == prefix
                and string.find(string.sub(directoryPath, #prefix + 1), "/", 1, true) == nil
            then
                table.insert(output, string.sub(directoryPath, #prefix + 1))
            end
        end
        for filePath in files do
            if string.sub(filePath, 1, #prefix) == prefix
                and string.find(string.sub(filePath, #prefix + 1), "/", 1, true) == nil
            then
                table.insert(output, string.sub(filePath, #prefix + 1))
            end
        end
        return output
    end
    function surface.writeDir(path: string)
        if directories[path] then error("occupied", 0) end
        directories[path] = true
    end
    function surface.removeDir(path: string) directories[path] = nil end
    function surface.removeFile(path: string) files[path] = nil end
    function surface.writeFile(path: string, body: string, options: any?)
        if options ~= nil and options.overwrite == false and files[path] ~= nil then error("occupied", 0) end
        files[path] = body
    end
    return surface, files, directories
end

local function studyOptions(candidateRoot: string?): any
    return {
        mode = "run", studio = "C:/Studio.exe", recipients = 1,
        baseline = "E:/relay", candidate = candidateRoot, os = "windows", cwd = "E:/relay",
    }
end

local function fakeManifest(options: any, studyPlan: any, dependencies: any, tag: string): any
    local pinned = "sha256:" .. string.rep(tag, 64)
    local chain = { lune = pinned, rojo = pinned,
        sha256 = Fingerprint.digest({ lune = pinned, rojo = pinned }, serde.hash, "RelayStudyTools:1") }
    local tools = { baseline = chain, candidate = if options.candidate == nil then nil else chain,
        sha256 = Fingerprint.digest({ baseline = chain.sha256,
            candidate = if options.candidate == nil then "none" else chain.sha256 }, serde.hash, "RelayStudyAllTools:1") }
    local planSha256 = Fingerprint.digest({ bytes = serde.encode("json", studyPlan) }, serde.hash, "RelayStudyPlan:1")
    local studioSha256 = "sha256:" .. serde.hash("sha256", dependencies.fs.readFile(options.studio))
    return { version = 1, baseline = { files = 1, sha256 = pinned },
        candidate = if options.candidate == nil then nil else { files = 1, sha256 = pinned },
        tools = tools, planSha256 = planSha256, studioSha256 = studioSha256,
        sha256 = Fingerprint.digest({ baseline = pinned, baselineFiles = "1",
            candidate = if options.candidate == nil then "none" else pinned,
            candidateFiles = if options.candidate == nil then "none" else "1",
            tools = tools.sha256, plan = planSha256, studio = studioSha256 },
            serde.hash, "RelayStudyInputManifest:1") }
end

local function runStudy(options: any, dependencies: any): any
    dependencies.collectInputManifest = dependencies.collectInputManifest or function(o, p, d)
        return fakeManifest(o, p, d, "a")
    end
    dependencies.createExclusive = dependencies.createExclusive or function(path: string, body: string)
        if dependencies.fs.isFile(path) then error("occupied", 0) end
        dependencies.fs.writeFile(path, body, { overwrite = true })
    end
    return Study.run(options, dependencies)
end

local function idFor(index: number): string
    return string.format("00112233-4455-4677-8899-%012d", index)
end

local function fakeExecutor(surface: any, files: any, behavior: ((number, string) -> (boolean, string?, string?))?, firstId: number?, withStages: boolean?)
    local revisions = { ["E:/relay"] = string.rep("a", 40), ["E:/candidate"] = string.rep("b", 40) }
    local calls = {}
    local hostCalls = 0
    local function execute(program: string, arguments: { string }, options: any): any
        table.insert(calls, { program = program, arguments = table.clone(arguments), options = options })
        if program == "git" then
            local revision = revisions[options.cwd] or revisions["E:/relay"]
            if arguments[1] == "rev-parse" then return { ok = true, stdout = revision .. "\r\n", stderr = "" } end
            return { ok = true, stdout = "\r\n", stderr = "" }
        end
        assert(program == "lune" and revisions[options.cwd] ~= nil, `unexpected fake process {program}`)
        hostCalls += 1
        local adapterId = arguments[#arguments]
        local runId = idFor((firstId or 0) + hostCalls)
        local revision = revisions[options.cwd]
        local path = `{options.cwd}/benchmarks/results/local/{runId}.result-v2.json`
        files[path] = serde.encode("json", makeResult(runId, adapterId, revision))
        local succeeded, mutation, oversized
        if behavior == nil then
            succeeded = true
            mutation = nil
            oversized = nil
        else
            succeeded, mutation, oversized = behavior(hostCalls, adapterId)
        end
        if mutation == "source" then revisions[options.cwd] = string.rep("c", 40) end
        if mutation == "studio" then files["C:/Studio.exe"] = "changed-studio" end
        local line = `PASS Relay.EventV1.Benchmark {runId} {path}`
        local stages = if withStages then "HOST_STAGES_V1 " .. serde.encode("json", {
            version = 1, unit = "Seconds", clock = "os.clock", launchId = runId,
            intervals = { { id = "total", status = if succeeded then "Complete" else "Failed",
                startedSeconds = 0, finishedSeconds = 8, durationSeconds = 8 },
                { id = "build", status = "Complete", startedSeconds = 1, finishedSeconds = 3, durationSeconds = 2 },
                { id = "launch", status = "Complete", startedSeconds = 4, finishedSeconds = 5, durationSeconds = 1 },
                { id = "studioProcess", status = if succeeded then "Complete" else "Failed",
                    startedSeconds = 5, finishedSeconds = 7, durationSeconds = 2 } },
        }) .. "\r\n" else ""
        local stdout = if oversized == "stdout" then string.rep("x", 131_072) else line .. "\r\n" .. stages
        local stderr = if oversized == "stderr" then string.rep("x", 131_072) else if succeeded then "" else "failed"
        return {
            ok = succeeded, code = if succeeded then 0 else 17, stdout = stdout, stderr = stderr,
            stdoutTruncated = oversized == "stdout", stderrTruncated = oversized == "stderr",
        }
    end
    return execute, calls, function() return hostCalls end
end

local function coarseClock()
    local reads = 0
    local boundaries = { 0, 1, 5, 8 }
    return function()
        reads += 1
        return math.floor((reads - 1) / 4) * 20 + boundaries[(reads - 1) % 4 + 1]
    end, function() return reads end
end

local function checkIntervals(attempt: any, expectedStatuses: { string })
    local stages = attempt.coarseHostStages
    assert(stages.version == 1 and stages.unit == "Seconds", "coarse host stages lost their separate version or unit")
    local ids = { "preflight", "hostExecution", "archiveValidation" }
    local previous = 0
    assert(#stages.intervals == #expectedStatuses, "unexpected coarse interval count")
    for index, interval in stages.intervals do
        local started, finished, duration = interval.startedSeconds, interval.finishedSeconds, interval.durationSeconds
        assert(interval.id == ids[index] and interval.status == expectedStatuses[index]
            and type(started) == "number" and started >= previous and started < math.huge
            and type(finished) == "number" and finished >= started and finished < math.huge
            and type(duration) == "number" and duration == finished - started and duration < math.huge,
            "coarse intervals must be ordered, finite, closed and explicitly classified")
        previous = finished
    end
end

do
    local partial = "HOST_STAGES_V1 " .. serde.encode("json", { version = 1, unit = "Seconds",
        clock = "os.clock", intervals = {
            { id = "total", status = "Failed", startedSeconds = 0, finishedSeconds = 7 },
            { id = "studioProcess", status = "Timeout", startedSeconds = 2, finishedSeconds = 6 },
        } }) .. "\n"
    local parsed = Study.parseHostStages(partial)
    assert(parsed ~= nil and #parsed.intervals == 2 and parsed.intervals[2].durationSeconds == 4
        and parsed.intervals[2].status == "Timeout" and parsed.unavailable.readiness ~= nil,
        "timeout stage or explicitly missing build/readiness was not retained")
    assert(Study.parseHostStages("PASS legacy-host\n") == nil
        and Study.parseHostStages(partial .. partial) == nil
        and Study.parseHostStages("HOST_STAGES_V1 {}\n") == nil,
        "legacy or malformed host stages were treated as measured phases")
end

local normalSurface, normalFiles = memorySurface("C:/Studio.exe")
local normalExecutor, normalCalls, normalHostCalls = fakeExecutor(normalSurface, normalFiles, nil, nil, true)
local readNormalClock, normalClockReads = coarseClock()
local hostInFlight = false
local checkpoint: any = nil
local normalWriteFile = normalSurface.writeFile
function normalSurface.writeFile(path: string, body: string, options: any?)
    assert(not hostInFlight, "study persisted a ledger or artifact during child execution")
    if string.sub(path, -#"/ledger.json") == "/ledger.json" then checkpoint = serde.decode("json", body) end
    normalWriteFile(path, body, options)
end
local function normalExecute(program: string, arguments: { string }, options: any): any
    if program ~= "lune" then return normalExecutor(program, arguments, options) end
    local active = checkpoint.attempts[#checkpoint.attempts]
    assert(active.valid == false and #active.coarseHostStages.intervals == 2
        and active.coarseHostStages.intervals[1].status == "Complete"
        and active.coarseHostStages.intervals[2].status == "Running"
        and active.coarseHostStages.intervals[2].finishedSeconds == nil,
        "pre-launch checkpoint must retain the open host interval if interrupted")
    hostInFlight = true
    local launched = normalExecutor(program, arguments, options)
    hostInFlight = false
    return launched
end
local normal = runStudy(studyOptions(), {
    fs = normalSurface, execute = normalExecute, hash = serde.hash,
    clock = function()
        assert(not hostInFlight, "study sampled its coarse clock during child execution")
        return readNormalClock()
    end,
})
local normalLedger = serde.decode("json", normalSurface.readFile(normal.ledgerPath))
assert(#normalLedger.attempts == 6 and #normalLedger.schedule == 6 and normalLedger.finishedUtc ~= nil,
    "successful study did not retain all six attempts")
assert(normalLedger.inputManifest.version == 1
    and normalLedger.attempts[1].inputManifestSha256 == normalLedger.inputManifest.sha256,
    "prelaunch input manifest was not bound to the ledger and attempt")
assert(normalHostCalls() == 6, "successful study launched an unexpected number of hosts")
assert(normalClockReads() == 24, "coarse diagnostics sampled more than the four outer boundaries per attempt")
assert(normalLedger.variation["1"].submitCallDuration ~= nil
    and normalLedger.variation["2"].frameTime ~= nil, "baseline/control variation was pooled or omitted")
for index, attempt in normalLedger.attempts do
    assert(attempt.valid == true and #attempt.rawResult == 1
        and normalSurface.isFile(attempt.stdoutPath) and normalSurface.isFile(attempt.stderrPath)
        and normalSurface.isFile(attempt.rawResult[1].path), `attempt {index} evidence missing`)
    checkIntervals(attempt, { "Complete", "Complete", "Complete" })
    assert(attempt.hostStages ~= nil and attempt.hostStages.launchId == attempt.runId
        and attempt.hostStages.intervals[1].durationSeconds == 8
        and attempt.hostStages.unavailable.collection ~= nil,
        "host process stages were not retained alongside successful raw evidence")
    local intervals = attempt.coarseHostStages.intervals
    assert(intervals[1].startedSeconds == 0 and intervals[1].durationSeconds == 1
        and intervals[2].startedSeconds == 1 and intervals[2].durationSeconds == 4
        and intervals[3].startedSeconds == 5 and intervals[3].durationSeconds == 3,
        "coarse intervals did not retain the injected outer-boundary elapsed times")
end
local expectedAdapters = { "native-reliable", "relay-reliable", "relay-reliable", "relay-reliable", "relay-reliable", "native-reliable" }
local hostIndex = 0
for _, call in normalCalls do
    if call.program == "lune" then
        hostIndex += 1
        assert(call.arguments[1] == "run" and call.arguments[2] == "E:/relay/benchmarks/host/run-event-v1.luau"
            and call.arguments[4] == "C:/Studio.exe" and call.arguments[6] == "PersistentBenchmark"
            and call.arguments[8] == "state-broadcast-s2c" and call.arguments[10] == "1"
            and call.arguments[12] == expectedAdapters[hostIndex]
            and call.options.cwd == "E:/relay", `host invocation {hostIndex} changed`)
    end
end

-- The raw copy is the immutable validation input. Mutate the result source
-- immediately after its archive read and prove the ledger still agrees with
-- the archived bytes rather than a later source reread.
local archiveSurface, archiveFiles = memorySurface("C:/Studio.exe")
local archiveReadFile = archiveSurface.readFile
local archiveResultPath = `E:/relay/benchmarks/results/local/{idFor(1)}.result-v2.json`
local archiveResultReads = 0
local archiveOriginalBody: string? = nil
function archiveSurface.readFile(path: string): string
    local body = archiveReadFile(path)
    if path == archiveResultPath then
        archiveResultReads += 1
        if archiveResultReads == 2 then
            archiveOriginalBody = body
            local changed = clone(serde.decode("json", body))
            for _, measurement in changed.measurements do
                if measurement.metadata.id == "submitCallDuration" then
                    measurement.summary.median = 3
                    measurement.summary.p95 = 3
                    for _, group in measurement.rawSamples do
                        for sampleIndex, _ in group.values do group.values[sampleIndex] = 3 end
                    end
                    break
                end
            end
            archiveFiles[path] = serde.encode("json", changed)
        end
    end
    return body
end
local archiveExecute = fakeExecutor(archiveSurface, archiveFiles)
local archiveStudy = runStudy(studyOptions(), { fs = archiveSurface, execute = archiveExecute, hash = serde.hash })
local archiveLedger = serde.decode("json", archiveSurface.readFile(archiveStudy.ledgerPath))
local archiveAttempt = archiveLedger.attempts[1]
local archiveRawPath = archiveAttempt.rawResult[1].path
local archiveRawBody = archiveSurface.readFile(archiveRawPath)
local archiveRawResult = serde.decode("json", archiveRawBody)
local function resultMeasurement(resultBody: any, id: string): any
    for _, measurement in resultBody.measurements do
        if measurement.metadata.id == id then return measurement end
    end
    error(`missing measurement {id}`, 0)
end
local archiveRawSubmit = resultMeasurement(archiveRawResult, "submitCallDuration")
local archiveSourceSubmit = resultMeasurement(serde.decode("json", archiveFiles[archiveResultPath]), "submitCallDuration")
assert(archiveOriginalBody ~= nil and archiveResultReads > 2
    and archiveFiles[archiveResultPath] ~= archiveOriginalBody
    and archiveAttempt.resultSha256 == `sha256:{string.lower(serde.hash("sha256", archiveRawBody))}`
    and archiveAttempt.summaries.submitCallDuration.median
        == archiveRawSubmit.summary.median
    and archiveAttempt.summaries.submitCallDuration.median ~= archiveSourceSubmit.summary.median,
    "result validation reread mutable source bytes instead of the archived body")

-- Candidate runs use the pinned baseline host script while their checkout is
-- only the process cwd. This guards the clean-source comparison against a
-- candidate-local copy of the orchestration host.
local candidateSurface, candidateFiles = memorySurface("C:/Studio.exe", "E:/candidate")
local candidateExecute, candidateCalls, candidateHostCalls = fakeExecutor(candidateSurface, candidateFiles)
local candidateStudy = runStudy(studyOptions("E:/candidate"), {
    fs = candidateSurface, execute = candidateExecute, hash = serde.hash,
})
local candidateLedger = serde.decode("json", candidateSurface.readFile(candidateStudy.ledgerPath))
assert(#candidateLedger.attempts == 8 and candidateHostCalls() == 8,
    "candidate study did not launch all eight fresh sessions")
local candidateCwdCount = 0
local baselineCwdCount = 0
local candidateHostCount = 0
for _, call in candidateCalls do
    if call.program == "lune" then
        candidateHostCount += 1
        assert(call.arguments[2] == "E:/relay/benchmarks/host/run-event-v1.luau",
            "candidate launch did not use the pinned baseline host script")
        if call.options.cwd == "E:/candidate" then
            candidateCwdCount += 1
        elseif call.options.cwd == "E:/relay" then
            baselineCwdCount += 1
        else
            error(`unexpected candidate study cwd {call.options.cwd}`, 0)
        end
    end
end
assert(candidateHostCount == 8 and candidateCwdCount == 2 and baselineCwdCount == 6,
    "candidate study cwd schedule changed")

local failureSurface, failureFiles = memorySurface("C:/Studio.exe")
local failureExecute, _, failureHostCalls = fakeExecutor(failureSurface, failureFiles, function(index)
    return index ~= 4
end, nil, true)
local failureClock, failureClockReads = coarseClock()
-- Make the fourth host fail after writing its valid result. It must retain
-- evidence and stop before the reverse half of the schedule.
local failureOk, failureMessage = pcall(function()
    runStudy(studyOptions(), { fs = failureSurface, execute = failureExecute, hash = serde.hash, clock = failureClock })
end)
assert(not failureOk and string.find(tostring(failureMessage), "BCAST_E_HOST", 1, true) ~= nil
    and failureHostCalls() == 4, "failed host did not stop the study")
local failureLedgerPath
for _, path in failureSurface.readDir("E:/relay/.tmp") do
    if string.sub(path, 1, #"broadcast-study-") == "broadcast-study-" then
        failureLedgerPath = `E:/relay/.tmp/{path}/ledger.json`
    end
end
assert(failureLedgerPath ~= nil, "failed study ledger was not retained")
local failureLedger = serde.decode("json", failureSurface.readFile(failureLedgerPath))
assert(#failureLedger.attempts == 4 and failureLedger.attempts[4].valid == false
    and failureLedger.attempts[4].rawResult ~= nil
    and failureLedger.attempts[4].hostStages.intervals[4].status == "Failed"
    and failureSurface.isFile(failureLedger.attempts[4].stdoutPath)
    and failureSurface.isFile(failureLedger.attempts[4].stderrPath), "failed attempt evidence was lost")
checkIntervals(failureLedger.attempts[4], { "Complete", "Failed", "Failed" })
assert(failureClockReads() == 16 and failureLedger.attempts[4].coarseHostStages.intervals[3].durationSeconds == 3
    and failureLedger.attempts[4].failure ~= nil
    and failureSurface.isFile(failureLedger.attempts[4].rawResult[1].path),
    "failed execution did not close its coarse intervals after retaining raw evidence")

-- A recorded failed attempt can start a separate complete collection. The
-- original ledger/raw files remain authoritative and are never reused as
-- successful slots in the new report. An open host interval cannot relaunch.
local originalLedgerBytes = failureSurface.readFile(failureLedgerPath)
local originalRawBytes = failureSurface.readFile(failureLedger.attempts[4].rawResult[1].path)
local recoveryExecute = fakeExecutor(failureSurface, failureFiles)
local recoveryDependencies = {
    os = "windows", fs = failureSurface, hash = serde.hash, execute = recoveryExecute,
    readFile = failureSurface.readFile,
    fileSize = function(path: string): number return #failureSurface.readFile(path) end,
    collectInputManifest = function(o: any, p: any, d: any): any return fakeManifest(o, p, d, "a") end,
}
do
local capacityOptions = studyOptions()
capacityOptions.restartLedger = failureLedgerPath
local capacityManifest = fakeManifest(capacityOptions, Study.plan(capacityOptions), { fs = failureSurface }, "a")
local capacityExecute, _, capacityHostCalls = fakeExecutor(failureSurface, failureFiles)
local capacityAuditCalls = 0
local capacityDirectories = {}
for _, directory in failureSurface.readDir("E:/relay/.tmp") do capacityDirectories[directory] = true end
reject("BCAST_E_RESTART_INPUT", function()
    runStudy(capacityOptions, {
        fs = failureSurface, execute = capacityExecute, hash = serde.hash,
        collectInputManifest = recoveryDependencies.collectInputManifest,
        recoveryAudit = function(): any
            capacityAuditCalls += 1
            return { status = "FreshFullStudyRequired", selection = "none",
                inputManifestSha256 = capacityManifest.sha256, lineageLength = RecoveryAudit.MAX_LINEAGE_LENGTH,
                ledgerSha256 = "sha256:" .. string.rep("a", 64), previousAttempts = {},
                sources = { baseline = { root = "E:/relay", revision = string.rep("a", 40) } } }
        end,
    })
end)
local afterCapacityDirectories = {}
for _, directory in failureSurface.readDir("E:/relay/.tmp") do afterCapacityDirectories[directory] = true end
assert(capacityAuditCalls == 1 and capacityHostCalls() == 0
    and #failureSurface.readDir("E:/relay/.tmp") == (function()
        local count = 0
        for _ in capacityDirectories do count += 1 end
        return count
    end)(), "full lineage created a collection or launched a host")
for directory in capacityDirectories do
    assert(afterCapacityDirectories[directory] == true, "full lineage removed an existing collection")
end
end
local missingOutput = clone(failureLedger)
missingOutput.attempts[4].addedResults = 2
failureSurface.writeFile(failureLedgerPath, serde.encode("json", missingOutput))
reject("BCAST_RECOVERY_E_ARCHIVE_COUNT", function()
    RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
end)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local oldFailedStdout = failureSurface.readFile(failureLedger.attempts[4].stdoutPath)
failureSurface.removeFile(failureLedger.attempts[4].stdoutPath)
local missingFailedLog = clone(failureLedger)
missingFailedLog.attempts[4].stdoutBytes = nil
failureSurface.writeFile(failureLedgerPath, serde.encode("json", missingFailedLog))
reject("BCAST_RECOVERY_E_LOG", function()
    RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
end)
failureSurface.writeFile(failureLedger.attempts[4].stdoutPath, oldFailedStdout)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local badTerminalTime = clone(failureLedger)
badTerminalTime.attempts[4].finishedUtc = 123
failureSurface.writeFile(failureLedgerPath, serde.encode("json", badTerminalTime))
reject("BCAST_RECOVERY_E_ATTEMPT", function()
    RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
end)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local oldValidStdout = failureSurface.readFile(failureLedger.attempts[1].stdoutPath)
local conflictingStdout = `PASS Relay.EventV1.Benchmark {idFor(999)} E:/relay/benchmarks/results/local/{idFor(999)}.result-v2.json\n`
failureSurface.writeFile(failureLedger.attempts[1].stdoutPath, conflictingStdout)
local conflictingPass = clone(failureLedger)
conflictingPass.attempts[1].stdoutBytes = #conflictingStdout
failureSurface.writeFile(failureLedgerPath, serde.encode("json", conflictingPass))
reject("BCAST_RECOVERY_E_PASS", function()
    RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
end)
local conflictingPath = `PASS Relay.EventV1.Benchmark {idFor(1)} E:/relay/benchmarks/results/local/{idFor(999)}.result-v2.json\n`
failureSurface.writeFile(failureLedger.attempts[1].stdoutPath, conflictingPath)
conflictingPass.attempts[1].stdoutBytes = #conflictingPath
failureSurface.writeFile(failureLedgerPath, serde.encode("json", conflictingPass))
reject("BCAST_RECOVERY_E_PASS", function()
    RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
end)
failureSurface.writeFile(failureLedger.attempts[1].stdoutPath, oldValidStdout)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local roundedLedger = clone(failureLedger)
local priorP95 = roundedLedger.attempts[1].summaries.frameTime.p95
local _, priorExponent = math.frexp(priorP95)
roundedLedger.attempts[1].summaries.frameTime.p95 = priorP95 + math.ldexp(1, priorExponent - 53)
failureSurface.writeFile(failureLedgerPath, serde.encode("json", roundedLedger))
assert(RecoveryAudit.audit(failureLedgerPath, recoveryDependencies).previousAttempts[1].state
    == "RetainedValidButNotSelected", "one-ULP historical summary rounding blocked recovery")
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)
local restartOptions = studyOptions()
restartOptions.restartLedger = failureLedgerPath
reject("BCAST_REPORT_E_INCOMPLETE", function()
    Report.report(failureLedgerPath, 0.1, failureSurface.readFile)
end)
local openLedger = clone(failureLedger)
openLedger.attempts[4].finishedUtc = nil
openLedger.attempts[4].failure = nil
failureSurface.writeFile(failureLedgerPath, serde.encode("json", openLedger))
local interrupted = RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
assert(#interrupted.previousAttempts == 4
    and interrupted.previousAttempts[1].state == "RetainedValidButNotSelected"
    and interrupted.previousAttempts[3].state == "RetainedValidButNotSelected"
    and interrupted.previousAttempts[4].state == "Interrupted",
    "valid prefix followed by interruption was not identified")
local openExecute, _, openHostCalls = fakeExecutor(failureSurface, failureFiles, nil, 90)
reject("BCAST_E_RESTART_OWNERSHIP", function()
    runStudy(restartOptions, { fs = failureSurface, execute = openExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(openHostCalls() == 0, "in-flight prior study launched a new host")
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local mismatchedOptions = clone(restartOptions)
mismatchedOptions.recipients = 4
local mismatchExecute, _, mismatchHostCalls = fakeExecutor(failureSurface, failureFiles, nil, 90)
reject("BCAST_E_RESTART_INPUT", function()
    runStudy(mismatchedOptions, { fs = failureSurface, execute = mismatchExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(mismatchHostCalls() == 0, "changed topology launched a restarted host")

failureSurface.writeFile(failureLedger.attempts[4].rawResult[1].path, "tampered")
local corruptExecute, _, corruptHostCalls = fakeExecutor(failureSurface, failureFiles, nil, 90)
reject("BCAST_RECOVERY_E_ARCHIVE_HASH", function()
    runStudy(restartOptions, { fs = failureSurface, execute = corruptExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(corruptHostCalls() == 0, "corrupt prior archive launched a restarted host")
failureSurface.writeFile(failureLedger.attempts[4].rawResult[1].path, originalRawBytes)

local freshExecute, _, freshHostCalls = fakeExecutor(failureSurface, failureFiles, nil, 100)
local fresh = runStudy(restartOptions, { fs = failureSurface, execute = freshExecute, hash = serde.hash,
    recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
assert(freshHostCalls() == 6 and fresh.ledger.version == 3 and #fresh.ledger.attempts == 6
    and fresh.ledger.collectionId ~= nil and fresh.ledger.restartOf.path == failureLedgerPath
    and fresh.ledger.restartOf.sha256 == "sha256:" .. serde.hash("sha256", originalLedgerBytes)
    and fresh.ledger.attempts[1].runId == idFor(101)
    and failureSurface.readFile(failureLedgerPath) == originalLedgerBytes
    and failureSurface.readFile(failureLedger.attempts[4].rawResult[1].path) == originalRawBytes,
    "fresh restart did not preserve prior evidence and replace the whole comparison")
local freshReport = Report.report(fresh.ledgerPath, 0.1, failureSurface.readFile)
local originalFreshLedgerBytes = failureSurface.readFile(fresh.ledgerPath)
assert(freshReport.collection.id == fresh.ledger.collectionId
    and freshReport.collection.selection == "FreshCollectionOnly"
    and #freshReport.collection.previousAttempts == 4
    and #freshReport.attempts == 6 and freshReport.attempts[1].runId == idFor(101),
    "report selected old attempts or lost restart lineage")

do
local existingCollections = {}
for _, directoryName in failureSurface.readDir("E:/relay/.tmp") do existingCollections[directoryName] = true end
local failedV3Execute, _, failedV3HostCalls = fakeExecutor(failureSurface, failureFiles, function(index)
    return index ~= 2
end, 400)
local failedV3Ok = pcall(function()
    runStudy(restartOptions, { fs = failureSurface, execute = failedV3Execute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
local failedV3Path: string? = nil
for _, directoryName in failureSurface.readDir("E:/relay/.tmp") do
    if not existingCollections[directoryName] then
        failedV3Path = `E:/relay/.tmp/{directoryName}/ledger.json`
    end
end
assert(not failedV3Ok and failedV3HostCalls() == 2 and failedV3Path ~= nil,
    "failed v3 parent fixture was not retained")
local failedV3 = serde.decode("json", failureSurface.readFile(failedV3Path))
assert(failedV3.version == 3 and failedV3.finishedUtc == nil and #failedV3.attempts == 2
    and failedV3.attempts[2].valid == false and failedV3.attempts[2].finishedUtc ~= nil,
    "failed v3 parent did not remain an auditable checkpoint")
local originalFailedV3LedgerBytes = failureSurface.readFile(failedV3Path)

local nestedOptions = studyOptions()
nestedOptions.restartLedger = failedV3Path
local nestedExecute, _, nestedHostCalls = fakeExecutor(failureSurface, failureFiles, nil, 300)
local nested = runStudy(nestedOptions, { fs = failureSurface, execute = nestedExecute, hash = serde.hash,
    recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
local nestedReport = Report.report(nested.ledgerPath, 0.1, failureSurface.readFile)
local nestedAudit = RecoveryAudit.audit(failedV3Path, recoveryDependencies)
assert(nestedHostCalls() == 6 and nested.ledger.version == 3
    and nested.ledger.restartOf.path == failedV3Path
    and nested.ledger.restartOf.sha256 == "sha256:" .. serde.hash("sha256", originalFailedV3LedgerBytes)
    and nestedAudit.lineageLength == 2 and #nestedAudit.previousAttempts == 6
    and nestedReport.collection.selection == "FreshCollectionOnly"
    and #nestedReport.collection.previousAttempts == 6
    and nestedReport.collection.previousAttempts[1].ledger == failureLedgerPath
    and nestedReport.collection.previousAttempts[5].ledger == failedV3Path
    and #nestedReport.attempts == 6 and nestedReport.attempts[1].runId == idFor(301),
    "nested restart did not audit full lineage or select only newest collection")

local completedParentOptions = studyOptions()
completedParentOptions.restartLedger = fresh.ledgerPath
local completedParentExecute, _, completedParentCalls = fakeExecutor(failureSurface, failureFiles)
reject("BCAST_RECOVERY_E_LEDGER", function()
    runStudy(completedParentOptions, { fs = failureSurface, execute = completedParentExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(completedParentCalls() == 0, "completed v3 parent was accepted for restart")
reject("BCAST_RECOVERY_E_LEDGER", function()
    RecoveryAudit.audit(nested.ledgerPath, recoveryDependencies)
end)

local originalNestedLedgerBytes = failureSurface.readFile(nested.ledgerPath)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes .. " ")
reject("BCAST_RECOVERY_E_RESTART_HASH", function()
    Report.report(nested.ledgerPath, 0.1, failureSurface.readFile)
end)
local tamperedAncestorExecute, _, tamperedAncestorCalls = fakeExecutor(failureSurface, failureFiles)
reject("BCAST_RECOVERY_E_RESTART_HASH", function()
    runStudy(nestedOptions, { fs = failureSurface, execute = tamperedAncestorExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(tamperedAncestorCalls() == 0, "tampered ancestor digest launched a restarted host")
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local changedManifest = clone(failedV3)
changedManifest.restartOf.inputManifestSha256 = pinned
failureSurface.writeFile(failedV3Path, serde.encode("json", changedManifest))
reject("BCAST_RECOVERY_E_RESTART", function()
    RecoveryAudit.audit(failedV3Path, recoveryDependencies)
end)
local changedSource = clone(failedV3)
changedSource.sources.baseline.revision = string.rep("c", 40)
failureSurface.writeFile(failedV3Path, serde.encode("json", changedSource))
reject("BCAST_RECOVERY_E_RESTART", function()
    RecoveryAudit.audit(failedV3Path, recoveryDependencies)
end)
failureSurface.writeFile(failedV3Path, originalFailedV3LedgerBytes)

failureSurface.removeFile(`E:/relay/benchmarks/results/local/{idFor(1)}.result-v2.json`)
local reusedRunExecute, _, reusedRunCalls = fakeExecutor(failureSurface, failureFiles, nil, 0)
reject("BCAST_E_DUPLICATE_RUN_ID", function()
    runStudy(nestedOptions, { fs = failureSurface, execute = reusedRunExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(reusedRunCalls() == 1, "run ID reused from an ancestor was not rejected")

local interruptedAncestor = clone(failureLedger)
interruptedAncestor.attempts[4].finishedUtc = nil
interruptedAncestor.attempts[4].failure = nil
local interruptedAncestorBytes = serde.encode("json", interruptedAncestor)
failureSurface.writeFile(failureLedgerPath, interruptedAncestorBytes)
local failedV3WithInterruptedAncestor = clone(failedV3)
failedV3WithInterruptedAncestor.restartOf.sha256 = "sha256:" .. serde.hash("sha256", interruptedAncestorBytes)
local failedV3WithInterruptedAncestorBytes = serde.encode("json", failedV3WithInterruptedAncestor)
failureSurface.writeFile(failedV3Path, failedV3WithInterruptedAncestorBytes)
local nestedWithInterruptedAncestor = clone(nested.ledger)
nestedWithInterruptedAncestor.restartOf.sha256 = "sha256:" .. serde.hash("sha256", failedV3WithInterruptedAncestorBytes)
failureSurface.writeFile(nested.ledgerPath, serde.encode("json", nestedWithInterruptedAncestor))
local interruptedAncestorExecute, _, interruptedAncestorCalls = fakeExecutor(failureSurface, failureFiles)
reject("BCAST_E_RESTART_OWNERSHIP", function()
    runStudy(nestedOptions, { fs = failureSurface, execute = interruptedAncestorExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(interruptedAncestorCalls() == 0, "interrupted ancestor launched another collection")
reject("BCAST_REPORT_E_RESTART_OWNERSHIP", function()
    Report.report(nested.ledgerPath, 0.1, failureSurface.readFile)
end)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)
failureSurface.writeFile(failedV3Path, originalFailedV3LedgerBytes)
failureSurface.writeFile(nested.ledgerPath, originalNestedLedgerBytes)

local cyclicParent = clone(failedV3)
cyclicParent.restartOf.path = failedV3Path
failureSurface.writeFile(failedV3Path, serde.encode("json", cyclicParent))
local cycleDependencies = {}
for key, value in recoveryDependencies do cycleDependencies[key] = value end
cycleDependencies.verifyCurrent = false
reject("BCAST_RECOVERY_E_RESTART_CYCLE", function()
    RecoveryAudit.audit(failedV3Path, cycleDependencies)
end)
failureSurface.writeFile(failedV3Path, originalFailedV3LedgerBytes)
end

local changedCollection = clone(fresh.ledger)
changedCollection.collectionId = "broadcast-study-0000000000000000"
failureSurface.writeFile(fresh.ledgerPath, serde.encode("json", changedCollection))
reject("BCAST_REPORT_E_RESTART", function()
    Report.report(fresh.ledgerPath, 0.1, failureSurface.readFile)
end)
failureSurface.writeFile(fresh.ledgerPath, originalFreshLedgerBytes)
local changedPrior = clone(failureLedger)
changedPrior.startedUtc = "2026-10-14T12:00:00Z"
failureSurface.writeFile(failureLedgerPath, serde.encode("json", changedPrior))
reject("BCAST_RECOVERY_E_RESTART_HASH", function()
    Report.report(fresh.ledgerPath, 0.1, failureSurface.readFile)
end)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

local repeatedExecute, _, repeatedHostCalls = fakeExecutor(failureSurface, failureFiles, nil, 200)
local repeated = runStudy(restartOptions, { fs = failureSurface, execute = repeatedExecute, hash = serde.hash,
    recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
assert(repeatedHostCalls() == 6 and repeated.ledger.collectionId ~= fresh.ledger.collectionId
    and repeated.ledgerPath ~= fresh.ledgerPath
    and failureSurface.readFile(failureLedgerPath) == originalLedgerBytes,
    "repeated invocation overwrote a prior collection")

local tamperedPrior = clone(failureLedger)
tamperedPrior.attempts[1].summaries.frameTime.median += 1
failureSurface.writeFile(failureLedgerPath, serde.encode("json", tamperedPrior))
reject("BCAST_RECOVERY_E_SUMMARY", function()
    RecoveryAudit.audit(failureLedgerPath, recoveryDependencies)
end)
failureSurface.writeFile(failureLedgerPath, originalLedgerBytes)

failureSurface.removeFile(`E:/relay/benchmarks/results/local/{idFor(1)}.result-v2.json`)
local duplicateExecute, _, duplicateHostCalls = fakeExecutor(failureSurface, failureFiles)
reject("BCAST_E_DUPLICATE_RUN_ID", function()
    runStudy(restartOptions, { fs = failureSurface, execute = duplicateExecute, hash = serde.hash,
        recoveryAudit = RecoveryAudit.audit, recoveryAuditDependencies = recoveryDependencies })
end)
assert(duplicateHostCalls() == 1 and failureSurface.readFile(failureLedgerPath) == originalLedgerBytes,
    "duplicate run ID was accepted or changed original evidence")

do
local collisionSurface, collisionFiles = memorySurface("C:/Studio.exe")
local collisionLedgerPath: string? = nil
local function collisionCreate(path: string, body: string)
    if string.sub(path, -#"/ledger.json") == "/ledger.json" and collisionLedgerPath == nil then
        collisionLedgerPath = path
        collisionFiles[path] = "other collection"
    end
    if collisionFiles[path] ~= nil then error("occupied", 0) end
    -- This fake write ignores overwrite=false, like pinned Lune. Exclusivity
    -- comes from the creator, independently of the filesystem write option.
    collisionSurface.writeFile(path, body, { overwrite = true })
end
local collisionExecute, _, collisionHostCalls = fakeExecutor(collisionSurface, collisionFiles)
reject("BCAST_E_LEDGER", function()
    runStudy(studyOptions(), { fs = collisionSurface, execute = collisionExecute,
        hash = serde.hash, createExclusive = collisionCreate })
end)
assert(collisionLedgerPath ~= nil and collisionFiles[collisionLedgerPath] == "other collection"
    and collisionHostCalls() == 0, "initial ledger collision overwrote another collection")

-- Exercise the production Windows CreateNew path on real ignored files.
local atomicDirectory = `.tmp/broadcast-create-new-{string.sub(serde.hash("sha256", tostring({}) .. tostring(os.clock())), 1, 16)}`
fs.writeDir(atomicDirectory)
local occupiedPath = atomicDirectory .. "/ledger.json"
Study.atomicCreateFile(occupiedPath, "prior\0bytes")
reject("BCAST_E_LEDGER", function() Study.atomicCreateFile(occupiedPath, "replacement") end)
assert(fs.readFile(occupiedPath) == "prior\0bytes", "CreateNew replaced an occupied real ledger")
local largePath = atomicDirectory .. "/large-archive.json"
local largeBody = string.rep("x", Study.PROCESS_OUTPUT_MAX_BYTES) .. "\0tail"
Study.atomicCreateFile(largePath, largeBody)
assert(fs.readFile(largePath) == largeBody, "CreateNew truncated streamed artifact bytes")
local racingPath = atomicDirectory .. "/contended.json"
local finished, wins = 0, 0
for index = 1, 2 do
    task.spawn(function()
        local ok = pcall(Study.atomicCreateFile, racingPath, `contender-{index}`)
        if ok then wins += 1 end
        finished += 1
    end)
end
while finished < 2 do task.wait(0.01) end
assert(wins == 1 and (fs.readFile(racingPath) == "contender-1"
    or fs.readFile(racingPath) == "contender-2"), "CreateNew contention accepted multiple writers")
fs.removeFile(occupiedPath)
fs.removeFile(largePath)
fs.removeFile(racingPath)
fs.removeDir(atomicDirectory)
end

local preflightSurface, preflightFiles = memorySurface("C:/Studio.exe")
local preflightExecutor, _, preflightHostCalls = fakeExecutor(preflightSurface, preflightFiles)
local sourceChecks = 0
local preflightClock = coarseClock()
reject("BCAST_E_SOURCE", function()
    runStudy(studyOptions(), {
        fs = preflightSurface, hash = serde.hash, clock = preflightClock,
        execute = function(program, arguments, options)
            if program == "git" and arguments[1] == "status" then
                sourceChecks += 1
                if sourceChecks == 2 then return { ok = true, stdout = " M src/init.luau\n" } end
            end
            return preflightExecutor(program, arguments, options)
        end,
    })
end)
local preflightLedger: any = nil
for _, path in preflightSurface.readDir("E:/relay/.tmp") do
    if string.sub(path, 1, #"broadcast-study-") == "broadcast-study-" then
        preflightLedger = serde.decode("json", preflightSurface.readFile(`E:/relay/.tmp/{path}/ledger.json`))
    end
end
assert(preflightLedger ~= nil and preflightHostCalls() == 0 and #preflightLedger.attempts == 1,
    "failed preflight lost its attempt or launched the child")
checkIntervals(preflightLedger.attempts[1], { "Failed" })
assert(preflightLedger.attempts[1].coarseHostStages.intervals[1].durationSeconds == 1,
    "failed preflight interval was not closed at the failure boundary")

-- Diagnostic clock faults must not skip raw archival or replace the host's
-- failure. Unavailable timings carry phase status without invented durations.
local clockFailureSurface, clockFailureFiles = memorySurface("C:/Studio.exe")
local clockFailureExecute = fakeExecutor(clockFailureSurface, clockFailureFiles, function() return false end)
local faultyReads = 0
reject("BCAST_E_HOST", function()
    runStudy(studyOptions(), {
        fs = clockFailureSurface, execute = clockFailureExecute, hash = serde.hash,
        clock = function()
            faultyReads += 1
            if faultyReads >= 3 then error("clock unavailable", 0) end
            return faultyReads - 1
        end,
    })
end)
local clockFailureLedger: any = nil
for _, path in clockFailureSurface.readDir("E:/relay/.tmp") do
    if string.sub(path, 1, #"broadcast-study-") == "broadcast-study-" then
        clockFailureLedger = serde.decode("json", clockFailureSurface.readFile(`E:/relay/.tmp/{path}/ledger.json`))
    end
end
assert(clockFailureLedger ~= nil, "clock fault discarded the ledger")
local clockFailureAttempt = clockFailureLedger.attempts[1]
local clockFailureIntervals = clockFailureAttempt.coarseHostStages.intervals
assert(faultyReads == 3 and clockFailureAttempt.finishedUtc ~= nil and clockFailureAttempt.failure ~= nil
    and clockFailureSurface.isFile(clockFailureAttempt.stdoutPath)
    and clockFailureSurface.isFile(clockFailureAttempt.stderrPath)
    and clockFailureSurface.isFile(clockFailureAttempt.rawResult[1].path)
    and clockFailureIntervals[1].status == "Complete"
    and clockFailureIntervals[2].status == "Failed" and clockFailureIntervals[2].timingUnavailable == true
    and clockFailureIntervals[3].status == "Failed" and clockFailureIntervals[3].timingUnavailable == true
    and clockFailureIntervals[2].durationSeconds == nil and clockFailureIntervals[3].durationSeconds == nil,
    "clock fault prevented evidence archival or the final failed interval checkpoint")

local invalidClockSurface, invalidClockFiles = memorySurface("C:/Studio.exe")
local invalidClockExecute = fakeExecutor(invalidClockSurface, invalidClockFiles)
local invalidClockStudy = runStudy(studyOptions(), {
    fs = invalidClockSurface, execute = invalidClockExecute, hash = serde.hash, clock = function() return 0 / 0 end,
})
for _, attempt in invalidClockStudy.ledger.attempts do
    assert(attempt.valid and #attempt.coarseHostStages.intervals == 3, "invalid diagnostic clock changed result acceptance")
    for _, interval in attempt.coarseHostStages.intervals do
        assert(interval.status == "Complete" and interval.timingUnavailable == true
            and interval.startedSeconds == nil and interval.durationSeconds == nil,
            "invalid clock values appeared as valid coarse timings")
    end
end

local finalClockSurface, finalClockFiles = memorySurface("C:/Studio.exe")
local finalClockExecute = fakeExecutor(finalClockSurface, finalClockFiles)
local readFinalClock = coarseClock()
local finalClockReads = 0
local finalClockStudy = runStudy(studyOptions(), {
    fs = finalClockSurface, execute = finalClockExecute, hash = serde.hash,
    clock = function()
        finalClockReads += 1
        local value = readFinalClock()
        return if finalClockReads == 4 then 0 else value
    end,
})
local finalClockAttempt = finalClockStudy.ledger.attempts[1]
assert(finalClockAttempt.valid and finalClockAttempt.finishedUtc ~= nil
    and finalClockAttempt.coarseHostStages.intervals[3].status == "Complete"
    and finalClockAttempt.coarseHostStages.intervals[3].timingUnavailable == true
    and finalClockAttempt.coarseHostStages.intervals[3].durationSeconds == nil,
    "backward final clock prevented successful evidence and status persistence")

local outputSurface, outputFiles = memorySurface("C:/Studio.exe")
local outputExecute = fakeExecutor(outputSurface, outputFiles, function()
    return true, nil, "stdout"
end)
reject("BCAST_E_OUTPUT_LIMIT", function()
    runStudy(studyOptions(), { fs = outputSurface, execute = outputExecute, hash = serde.hash })
end)
local outputLedgerPath
for _, path in outputSurface.readDir("E:/relay/.tmp") do
    if string.sub(path, 1, #"broadcast-study-") == "broadcast-study-" then
        outputLedgerPath = `E:/relay/.tmp/{path}/ledger.json`
    end
end
assert(outputLedgerPath ~= nil, "output-limit ledger was not retained")
local outputLedger = serde.decode("json", outputSurface.readFile(outputLedgerPath))
assert(outputLedger.attempts[1].stdoutTruncated == true
    and #outputSurface.readFile(outputLedger.attempts[1].stdoutPath) == 131_072,
    "oversized host output was not bounded and retained")

if process.os == "windows" then
    local bounded = Study.runProcessBounded("powershell.exe", {
        "-NoProfile", "-NonInteractive", "-Command",
        "$o=('o'*200000)-join ''; $e=('e'*200000)-join ''; [Console]::Out.Write($o); [Console]::Error.Write($e)",
    }, { cwd = process.cwd })
    assert(bounded.ok and bounded.stdoutTruncated and bounded.stderrTruncated
        and #bounded.stdout == Study.PROCESS_OUTPUT_MAX_BYTES
        and #bounded.stderr == Study.PROCESS_OUTPUT_MAX_BYTES,
        "bounded child reader did not drain and cap both streams")
end

local staleSurface, staleFiles = memorySurface("C:/Studio.exe")
local staleId = idFor(90)
local stalePath = `E:/relay/benchmarks/results/local/{staleId}.result-v2.json`
staleFiles[stalePath] = serde.encode("json", makeResult(staleId, "native-reliable"))
local staleExecute = function(program: string, arguments: { string }, options: any): any
    if program == "git" then
        return if arguments[1] == "rev-parse"
            then { ok = true, stdout = string.rep("a", 40) .. "\r\n" }
            else { ok = true, stdout = "\r\n" }
    end
    return { ok = true, code = 0, stdout = `PASS Relay.EventV1.Benchmark {staleId} {stalePath}\r\n`, stderr = "" }
end
reject("BCAST_E_RESULT_FRESHNESS", function()
    runStudy(studyOptions(), { fs = staleSurface, execute = staleExecute, hash = serde.hash })
end)
assert(staleFiles[stalePath] ~= nil, "stale result was removed or overwritten")

local sourceSurface, sourceFiles = memorySurface("C:/Studio.exe")
local sourceExecute, _, sourceHostCalls = fakeExecutor(sourceSurface, sourceFiles, function(index)
    return true, if index == 1 then "source" else nil
end)
reject("BCAST_E_SOURCE_CHANGED", function()
    runStudy(studyOptions(), { fs = sourceSurface, execute = sourceExecute, hash = serde.hash })
end)
assert(sourceHostCalls() == 1, "source change did not stop after the first host")

local inputSurface, inputFiles = memorySurface("C:/Studio.exe")
local inputExecute, _, inputHostCalls = fakeExecutor(inputSurface, inputFiles)
local inputReads = 0
reject("BCAST_E_INPUT_CHANGED", function()
    runStudy(studyOptions(), {
        fs = inputSurface, execute = inputExecute, hash = serde.hash,
        collectInputManifest = function(o, p, d)
            inputReads += 1
            return fakeManifest(o, p, d, if inputReads == 3 then "b" else "a")
        end,
    })
end)
assert(inputHostCalls() == 1, "post-launch input change did not stop after the first host")
local inputLedgerPath
for _, name in inputSurface.readDir("E:/relay/.tmp") do
    if string.sub(name, 1, #"broadcast-study-") == "broadcast-study-" then
        inputLedgerPath = `E:/relay/.tmp/{name}/ledger.json`
    end
end
local inputLedger = serde.decode("json", inputSurface.readFile(inputLedgerPath))
assert(inputLedger.attempts[1].valid == false and #inputLedger.attempts[1].rawResult == 1
    and inputSurface.isFile(inputLedger.attempts[1].rawResult[1].path),
    "post-launch input mismatch discarded raw evidence or marked the attempt valid")

local engineSurface, engineFiles = memorySurface("C:/Studio.exe")
local engineExecute, _, engineHostCalls = fakeExecutor(engineSurface, engineFiles, function(index)
    return true, if index == 1 then "studio" else nil
end)
reject("BCAST_E_STUDIO_CHANGED", function()
    runStudy(studyOptions(), { fs = engineSurface, execute = engineExecute, hash = serde.hash })
end)
assert(engineHostCalls() == 1, "Studio change did not stop after the first host")

-- Plan mode is pure: serializing the plan must not create a ledger directory.
local planBody = serde.encode("json", Study.plan(parsed))
assert(string.find(planBody, "state%-broadcast%-s2c") ~= nil and not fs.isDir(".tmp/broadcast-study-plan-test"),
    "plan unexpectedly mutated study artifacts")

print("PASS Relay.Benchmarks.BroadcastStudy")
