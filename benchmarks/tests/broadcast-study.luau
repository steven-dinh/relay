--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Study = require("../host/BroadcastStudy")
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

local function idFor(index: number): string
    return string.format("00112233-4455-4677-8899-%012d", index)
end

local function fakeExecutor(surface: any, files: any, behavior: ((number, string) -> (boolean, string?, string?))?)
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
        local runId = idFor(hostCalls)
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
        local stdout = if oversized == "stdout" then string.rep("x", 131_072) else line .. "\r\n"
        local stderr = if oversized == "stderr" then string.rep("x", 131_072) else if succeeded then "" else "failed"
        return {
            ok = succeeded, code = if succeeded then 0 else 17, stdout = stdout, stderr = stderr,
            stdoutTruncated = oversized == "stdout", stderrTruncated = oversized == "stderr",
        }
    end
    return execute, calls, function() return hostCalls end
end

local normalSurface, normalFiles = memorySurface("C:/Studio.exe")
local normalExecute, normalCalls, normalHostCalls = fakeExecutor(normalSurface, normalFiles)
local normal = Study.run(studyOptions(), { fs = normalSurface, execute = normalExecute, hash = serde.hash })
local normalLedger = serde.decode("json", normalSurface.readFile(normal.ledgerPath))
assert(#normalLedger.attempts == 6 and #normalLedger.schedule == 6 and normalLedger.finishedUtc ~= nil,
    "successful study did not retain all six attempts")
assert(normalHostCalls() == 6, "successful study launched an unexpected number of hosts")
assert(normalLedger.variation["1"].submitCallDuration ~= nil
    and normalLedger.variation["2"].frameTime ~= nil, "baseline/control variation was pooled or omitted")
for index, attempt in normalLedger.attempts do
    assert(attempt.valid == true and #attempt.rawResult == 1
        and normalSurface.isFile(attempt.stdoutPath) and normalSurface.isFile(attempt.stderrPath)
        and normalSurface.isFile(attempt.rawResult[1].path), `attempt {index} evidence missing`)
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
local archiveStudy = Study.run(studyOptions(), { fs = archiveSurface, execute = archiveExecute, hash = serde.hash })
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
local candidateStudy = Study.run(studyOptions("E:/candidate"), {
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
end)
-- Make the fourth host fail after writing its valid result. It must retain
-- evidence and stop before the reverse half of the schedule.
local failureOk, failureMessage = pcall(function()
    Study.run(studyOptions(), { fs = failureSurface, execute = failureExecute, hash = serde.hash })
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
    and failureSurface.isFile(failureLedger.attempts[4].stdoutPath)
    and failureSurface.isFile(failureLedger.attempts[4].stderrPath), "failed attempt evidence was lost")

local outputSurface, outputFiles = memorySurface("C:/Studio.exe")
local outputExecute = fakeExecutor(outputSurface, outputFiles, function()
    return true, nil, "stdout"
end)
reject("BCAST_E_OUTPUT_LIMIT", function()
    Study.run(studyOptions(), { fs = outputSurface, execute = outputExecute, hash = serde.hash })
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
    Study.run(studyOptions(), { fs = staleSurface, execute = staleExecute, hash = serde.hash })
end)
assert(staleFiles[stalePath] ~= nil, "stale result was removed or overwritten")

local sourceSurface, sourceFiles = memorySurface("C:/Studio.exe")
local sourceExecute, _, sourceHostCalls = fakeExecutor(sourceSurface, sourceFiles, function(index)
    return true, if index == 1 then "source" else nil
end)
reject("BCAST_E_SOURCE_CHANGED", function()
    Study.run(studyOptions(), { fs = sourceSurface, execute = sourceExecute, hash = serde.hash })
end)
assert(sourceHostCalls() == 1, "source change did not stop after the first host")

local engineSurface, engineFiles = memorySurface("C:/Studio.exe")
local engineExecute, _, engineHostCalls = fakeExecutor(engineSurface, engineFiles, function(index)
    return true, if index == 1 then "studio" else nil
end)
reject("BCAST_E_STUDIO_CHANGED", function()
    Study.run(studyOptions(), { fs = engineSurface, execute = engineExecute, hash = serde.hash })
end)
assert(engineHostCalls() == 1, "Studio change did not stop after the first host")

-- Plan mode is pure: serializing the plan must not create a ledger directory.
local planBody = serde.encode("json", Study.plan(parsed))
assert(string.find(planBody, "state%-broadcast%-s2c") ~= nil and not fs.isDir(".tmp/broadcast-study-plan-test"),
    "plan unexpectedly mutated study artifacts")

print("PASS Relay.Benchmarks.BroadcastStudy")
