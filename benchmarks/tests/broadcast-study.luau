--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Study = require("../host/BroadcastStudy")
local RecoveryAudit = require("../host/BroadcastRecoveryAudit")
local C00 = { sourceCopy = require("../host/StudySourceCopy"),
	receipt = require("../host/StudyExecutionReceipt"),
	lune = "C:/Rokit/tool-storage/rokit/lune/0.10.5/lune.exe" }
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
do
	local rehearsalOptions = Study.parseArgs({
		"--rehearse", "--studio", "C:/Studio.exe", "--recipients", "4",
	}, "windows", "E:/relay")
	assert(rehearsalOptions.mode == "rehearse" and Study.plan(rehearsalOptions).topology.mode == "ControlProof",
		"rehearsal mode was not bound into the plan")
end
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
reject("BCAST_E_ARGS", function()
	Study.parseArgs({ "--rehearse", "--studio", "C:/Studio.exe", "--recipients", "1",
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
do
	local rehearsalOptions = Study.parseArgs({
		"--rehearse", "--studio", "C:/Studio.exe", "--recipients", "4",
	}, "windows", "E:/relay")
	local rehearsalSchedule = Study.schedule(rehearsalOptions)
	assert(#rehearsalSchedule == 1 and rehearsalSchedule[1].label == "baseline"
		and rehearsalSchedule[1].pass == 1 and rehearsalSchedule[1].order == "forward"
		and rehearsalSchedule[1].adapterId == "relay-reliable", "baseline rehearsal must use one Relay control attempt")
	local candidateRehearsal = table.clone(rehearsalOptions)
	candidateRehearsal.candidate = "E:/candidate"
	local candidateRehearsalSchedule = Study.schedule(candidateRehearsal)
	assert(#candidateRehearsalSchedule == 2 and candidateRehearsalSchedule[1].label == "baseline"
		and candidateRehearsalSchedule[2].label == "candidate"
		and candidateRehearsalSchedule[2].root == "E:/candidate"
		and candidateRehearsalSchedule[2].pass == 1 and candidateRehearsalSchedule[2].order == "forward",
		"candidate rehearsal must use exactly one copied control attempt per role")
end

local pass = Study.parsePassOutput("diagnostic\nPASS Relay.EventV1.Benchmark 00112233-4455-4677-8899-aabbccddeeff E:/relay/benchmarks/results/local/00112233-4455-4677-8899-aabbccddeeff.result-v2.json\n")
assert(pass.launchId == "00112233-4455-4677-8899-aabbccddeeff", "PASS launch identity changed")
reject("BCAST_E_PASS", function() Study.parsePassOutput('{"runId":"fake"}\n') end)
reject("BCAST_E_PASS", function()
    Study.parsePassOutput("PASS Relay.EventV1.Benchmark 00112233-4455-4677-8899-aabbccddeeff a.json\nPASS Relay.EventV1.Benchmark 00112233-4455-4677-8899-aabbccddeeff b.json")
end)
do
	local controlPass = Study.parseControlProofOutput("diagnostic\nPASS Relay.EventV1.ControlProof 00112233-4455-4677-8899-aabbccddeeff\n")
	assert(controlPass.launchId == "00112233-4455-4677-8899-aabbccddeeff", "control PASS launch identity changed")
	for _, output in {
		"PASS Relay.EventV1.ControlProof 00112233-4455-4677-8899-aabbccddeeff extra\n",
		"PASS Relay.EventV1.ControlProof 00112233-4455-4677-8899-aabbccddeeff \n",
		"PASS Relay.EventV1.ControlProof bad-id\n",
		"PASS Relay.EventV1.ControlProof 00112233-4455-4677-8899-aabbccddeeff\n"
			.. "PASS Relay.EventV1.ControlProof 00112233-4455-4677-8899-aabbccddeeff\n",
	} do
		reject("BCAST_E_CONTROL_PASS", function() Study.parseControlProofOutput(output) end)
	end
end

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
	local files: { [string]: string } = {
		[studioPath] = "studio-bytes",
		["E:/relay/benchmarks/host/run-event-v1.luau"] = "baseline runner snapshot",
		["E:/relay/benchmarks/results/local/.gitignore"] = "*\n",
	}
    local directories: { [string]: boolean } = {
		["E:/"] = true,
        ["E:/relay"] = true,
        ["E:/relay/.tmp"] = true,
        ["E:/relay/benchmarks"] = true,
		["E:/relay/benchmarks/host"] = true,
        ["E:/relay/benchmarks/results"] = true,
        ["E:/relay/benchmarks/results/local"] = true,
    }
    if candidateRoot ~= nil then
        directories[candidateRoot] = true
        directories[candidateRoot .. "/benchmarks"] = true
		directories[candidateRoot .. "/benchmarks/host"] = true
        directories[candidateRoot .. "/benchmarks/results"] = true
        directories[candidateRoot .. "/benchmarks/results/local"] = true
		files[candidateRoot .. "/benchmarks/host/run-event-v1.luau"] = "candidate runner snapshot"
		files[candidateRoot .. "/benchmarks/results/local/.gitignore"] = "*\n"
    end
    local surface = {}
	surface.copySources = {}
	surface.inputInventories = {}
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
	function surface.copyAttributes(paths: { string }): any
		local output = {}
		for _, path in paths do
			if directories[path] then output[path] = { attributes = 0x10 }
			elseif files[path] ~= nil then output[path] = { attributes = 0 }
			else output[path] = { errorCode = 2 } end
		end
		return output
	end
	function surface.copySource(root: string, destination: string, dependencies: any): any
		local inventory = surface.inputInventories[root]
		assert(inventory ~= nil and not surface.isDir(destination) and not surface.isFile(destination),
			"missing fake copy inventory or occupied destination")
		surface.writeDir(destination)
		surface.copySources[destination] = root
		for _, entry in inventory.entries do
			local current = destination
			local parts = string.split(entry.path, "/")
			for index = 1, #parts - 1 do
				current ..= "/" .. parts[index]
				if not surface.isDir(current) then surface.writeDir(current) end
			end
			surface.writeFile(destination .. "/" .. entry.path,
				surface.readFile(root .. "/" .. entry.path), { overwrite = false })
		end
		local entries = {}
		for index, entry in inventory.entries do entries[index] = clone(entry) end
		return { directory = destination, files = inventory.files, sha256 = inventory.sha256, entries = entries }
	end
    return surface, files, directories
end

local function studyOptions(candidateRoot: string?): any
    return {
        mode = "run", studio = "C:/Studio.exe", recipients = 1,
        baseline = "E:/relay", candidate = candidateRoot, os = "windows", cwd = "E:/relay",
    }
end

local function fakeManifest(options: any, studyPlan: any, dependencies: any, tag: string): (any, any)
    local pinned = "sha256:" .. string.rep(tag, 64)
    local chain = { lune = pinned, rojo = pinned,
        sha256 = Fingerprint.digest({ lune = pinned, rojo = pinned }, serde.hash, "RelayStudyTools:1") }
    local tools = { baseline = chain, candidate = if options.candidate == nil then nil else chain,
        sha256 = Fingerprint.digest({ baseline = chain.sha256,
            candidate = if options.candidate == nil then "none" else chain.sha256 }, serde.hash, "RelayStudyAllTools:1") }
    local planSha256 = Fingerprint.digest({ bytes = serde.encode("json", studyPlan) }, serde.hash, "RelayStudyPlan:1")
    local studioSha256 = "sha256:" .. serde.hash("sha256", dependencies.fs.readFile(options.studio))
	local function inventory(root: string): any
		local entries = {}
		local identities = {}
		for _, path in { "benchmarks/host/run-event-v1.luau", "benchmarks/results/local/.gitignore" } do
			local body = dependencies.fs.readFile(root .. "/" .. path)
			local fileHash = Fingerprint.digest({ bytes = body }, serde.hash, "RelayStudyFile:1")
			identities[path] = fileHash
			table.insert(entries, { path = path, bytes = #body, sha256 = fileHash })
		end
		local result = { files = #entries, sha256 = Fingerprint.digest(identities, serde.hash, "RelayStudySource:1"),
			entries = entries }
		dependencies.fs.inputInventories[root] = result
		return result
	end
	local baselineInventory = inventory(options.baseline)
	local candidateInventory = if options.candidate == nil then nil else inventory(options.candidate)
	local function pins(): any
		return { lune = { path = "C:/Rokit/tool-storage/rokit/lune/0.10.5/lune.exe", sha256 = pinned, version = "0.10.5" },
			rojo = { path = "C:/Rokit/tool-storage/rokit/rojo/7.5.1/rojo.exe", sha256 = pinned, version = "7.5.1" } }
	end
	local details = { baseline = baselineInventory, candidate = candidateInventory,
		tools = { baseline = pins(), candidate = if candidateInventory == nil then nil else pins() } }
	local manifest = { version = 1, baseline = { files = baselineInventory.files, sha256 = baselineInventory.sha256 },
		candidate = if candidateInventory == nil then nil else { files = candidateInventory.files, sha256 = candidateInventory.sha256 },
        tools = tools, planSha256 = planSha256, studioSha256 = studioSha256,
		sha256 = Fingerprint.digest({ baseline = baselineInventory.sha256, baselineFiles = tostring(baselineInventory.files),
			candidate = if candidateInventory == nil then "none" else candidateInventory.sha256,
			candidateFiles = if candidateInventory == nil then "none" else tostring(candidateInventory.files),
            tools = tools.sha256, plan = planSha256, studio = studioSha256 },
			serde.hash, "RelayStudyInputManifest:1") }
	return manifest, details
end

local function runStudy(options: any, dependencies: any): any
    dependencies.collectInputManifest = dependencies.collectInputManifest or function(o, p, d)
        return fakeManifest(o, p, d, "a")
    end
	dependencies.copySource = dependencies.copySource or dependencies.fs.copySource
	dependencies.copyAttributes = dependencies.copyAttributes or dependencies.fs.copyAttributes
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
		assert(program == C00.lune and surface.copySources[options.cwd] ~= nil,
			`unexpected fake process {program} cwd {options.cwd}`)
		local sourceRoot = surface.copySources[options.cwd]
		local receiptPath, receiptSha, attemptIndex
		local actualMode
		for index = 1, #arguments, 2 do
			if arguments[index] == "--execution-receipt" then receiptPath = arguments[index + 1]
			elseif arguments[index] == "--execution-receipt-sha256" then receiptSha = arguments[index + 1]
			elseif arguments[index] == "--execution-attempt" then attemptIndex = tonumber(arguments[index + 1])
			elseif arguments[index] == "--mode" then actualMode = arguments[index + 1] end
		end
		assert(receiptPath ~= nil and receiptSha ~= nil and attemptIndex ~= nil and actualMode ~= nil,
			"fake host command omitted its execution receipt")
		local receipt = C00.receipt.read(receiptPath, receiptSha, options.cwd, {
			fs = surface,
			fileSize = function(path: string): number return #surface.readFile(path) end,
			hash = serde.hash,
		})
		assert(C00.receipt.validateChild(receipt, options.cwd, arguments[#arguments], attemptIndex,
			"C:/Studio.exe", surface.readFile("C:/Studio.exe"), serde.hash, actualMode), "child rejected its receipt context")
		assert(C00.receipt.executionMode(receipt) == actualMode
			and (actualMode == "ControlProof") == (receipt.executionMode == "ControlProof"),
			"receipt did not bind the effective execution mode")
		local mismatchedReceipt = clone(receipt)
		mismatchedReceipt.executionMode = if actualMode == "ControlProof" then "PersistentBenchmark" else "ControlProof"
		mismatchedReceipt.sha256 = nil
		mismatchedReceipt = C00.receipt.seal(mismatchedReceipt, serde.hash)
		assert(not C00.receipt.validateChild(mismatchedReceipt, options.cwd, arguments[#arguments], attemptIndex,
			"C:/Studio.exe", surface.readFile("C:/Studio.exe"), serde.hash, actualMode),
			"host accepted a receipt from the opposite execution mode")
		C00.sourceCopy.verify(receipt.runner.root, receipt.runner, { fs = surface,
			attributes = surface.copyAttributes, allowedOutputs = receipt.runner.allowedResults,
			allowedDirectories = { ".tmp" } })
		if not C00.receipt.samePath(receipt.runner.root, receipt.source.root) then
			C00.sourceCopy.verify(receipt.source.root, receipt.source, { fs = surface,
				attributes = surface.copyAttributes, allowedOutputs = receipt.source.allowedResults,
				allowedDirectories = { ".tmp" } })
		end
		assert(arguments[2] == receipt.runner.root .. "/" .. Study.HOST_SCRIPT,
			"host script did not come from the baseline execution copy")
        hostCalls += 1
        local adapterId = arguments[#arguments]
        local runId = idFor((firstId or 0) + hostCalls)
		local revision = revisions[sourceRoot]
		local temporaryDirectory = options.cwd .. "/.tmp"
		if not surface.isDir(temporaryDirectory) then surface.writeDir(temporaryDirectory) end
        local path = `{options.cwd}/benchmarks/results/local/{runId}.result-v2.json`
        local succeeded, mutation, oversized
        if behavior == nil then
            succeeded = true
            mutation = nil
            oversized = nil
        else
            succeeded, mutation, oversized = behavior(hostCalls, adapterId)
        end
		if actualMode ~= "ControlProof" or mutation == "result" then
			files[path] = serde.encode("json", makeResult(runId, adapterId, revision))
		end
		if mutation == "retained-log" then
			files[temporaryDirectory .. "/relay-launch-" .. runId .. ".log"] = "retained host diagnostic"
		end
		if mutation == "source" then revisions[sourceRoot] = string.rep("c", 40) end
        if mutation == "studio" then files["C:/Studio.exe"] = "changed-studio" end
        local line = if actualMode == "ControlProof" then `PASS Relay.EventV1.ControlProof {runId}`
			else `PASS Relay.EventV1.Benchmark {runId} {path}`
        local stages = if withStages and actualMode ~= "ControlProof" then "HOST_STAGES_V1 " .. serde.encode("json", {
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
do
local normalReport = Report.report(normal.ledgerPath, 0.05, function(path: string): string
	return normalSurface.readFile(path)
end)
assert(normalReport ~= nil, "canonical report rejected the legacy-mode receipt")
local normalRecoveryDependencies = {
	os = "windows", cwd = "E:/relay", hash = serde.hash, verifyCurrent = false,
	readFile = function(path: string): string return normalSurface.readFile(path) end,
	fileSize = function(path: string): number return #normalSurface.readFile(path) end,
}
local interruptedLedger = clone(normalLedger)
interruptedLedger.finishedUtc = nil
normalSurface.writeFile(normal.ledgerPath, serde.encode("json", interruptedLedger), { overwrite = true })
assert(RecoveryAudit.audit(normal.ledgerPath, normalRecoveryDependencies).status == "FreshFullStudyRequired",
	"canonical recovery rejected legacy-mode receipts")
local normalReceiptPath = normalLedger.attempts[1].executionReceiptPath
local normalReceipt = serde.decode("json", normalSurface.readFile(normalReceiptPath))
local controlReceipt = clone(normalReceipt)
controlReceipt.executionMode = "ControlProof"
controlReceipt.sha256 = nil
controlReceipt = C00.receipt.seal(controlReceipt, serde.hash)
normalSurface.writeFile(normalReceiptPath, serde.encode("json", controlReceipt), { overwrite = true })
local controlReceiptLedger = clone(normalLedger)
controlReceiptLedger.attempts[1].executionReceiptSha256 = controlReceipt.sha256
normalSurface.writeFile(normal.ledgerPath, serde.encode("json", controlReceiptLedger), { overwrite = true })
reject("BCAST_REPORT_E_EXECUTION_RECEIPT", function()
	Report.report(normal.ledgerPath, 0.05, function(path: string): string return normalSurface.readFile(path) end)
end)
controlReceiptLedger.finishedUtc = nil
normalSurface.writeFile(normal.ledgerPath, serde.encode("json", controlReceiptLedger), { overwrite = true })
reject("BCAST_RECOVERY_E_RECEIPT", function()
	RecoveryAudit.audit(normal.ledgerPath, normalRecoveryDependencies)
end)
normalSurface.writeFile(normalReceiptPath, serde.encode("json", normalReceipt), { overwrite = true })
normalSurface.writeFile(normal.ledgerPath, serde.encode("json", normalLedger), { overwrite = true })
end

local expectedAdapters = { "native-reliable", "relay-reliable", "relay-reliable", "relay-reliable", "relay-reliable", "native-reliable" }
 C00.normalToken = string.match(normal.ledgerPath, "/broadcast%-study%-(%x+)/ledger%.json$")
assert(C00.normalToken ~= nil, "study output path did not retain its copy token")
C00.baselineCopyRoot = Study.copyDestination("E:/relay", C00.normalToken, "baseline")
local hostIndex = 0
for _, call in normalCalls do
	if call.program == C00.lune then
        hostIndex += 1
		local attempt = normalLedger.attempts[hostIndex]
		assert(call.arguments[1] == "run" and call.arguments[2] == C00.baselineCopyRoot .. "/" .. Study.HOST_SCRIPT
            and call.arguments[4] == "C:/Studio.exe" and call.arguments[6] == "PersistentBenchmark"
            and call.arguments[8] == "state-broadcast-s2c" and call.arguments[10] == "1"
			and call.arguments[#call.arguments] == expectedAdapters[hostIndex]
			and call.options.cwd == C00.baselineCopyRoot
			and call.arguments[12] == attempt.executionReceiptPath
			and call.arguments[14] == attempt.executionReceiptSha256,
			`host invocation {hostIndex} changed`)
    end
end

do
local oneRoleSurface, oneRoleFiles = memorySurface("C:/Studio.exe")
local oneRoleOptions = studyOptions()
oneRoleOptions.mode = "rehearse"
local oneRoleExecutor, oneRoleCalls, oneRoleHostCalls = fakeExecutor(oneRoleSurface, oneRoleFiles, nil, 200)
local rehearsalClockReads = 0
local oneRole = runStudy(oneRoleOptions, {
	fs = oneRoleSurface, execute = oneRoleExecutor, hash = serde.hash,
	clock = function() rehearsalClockReads += 1; error("rehearsal sampled the benchmark clock") end,
})
local oneRoleLedger = serde.decode("json", oneRoleSurface.readFile(oneRole.ledgerPath))
assert(oneRoleLedger.schema == "Relay.BroadcastRehearsalLedger" and oneRoleLedger.version == 1
	and oneRoleLedger.status == "Passed" and oneRoleLedger.topology.mode == "ControlProof"
	and #oneRoleLedger.schedule == 1 and #oneRoleLedger.attempts == 1
	and oneRoleLedger.variation == nil and rehearsalClockReads == 0 and oneRoleHostCalls() == 1,
	"single-role rehearsal produced canonical study evidence or sampled timing")
local oneRoleAttempt = oneRoleLedger.attempts[1]
local oneRoleToken = string.match(oneRole.ledgerPath, "/broadcast%-study%-(%x+)/ledger%.json$")
assert(oneRoleToken ~= nil, "single-role rehearsal output did not retain its copy token")
local oneRoleCopy = Study.copyDestination("E:/relay", oneRoleToken, "baseline")
assert(oneRoleAttempt.valid and oneRoleAttempt.launchId == idFor(201)
	and oneRoleAttempt.executionRoot == oneRoleCopy
	and oneRoleAttempt.coarseHostStages == nil and oneRoleAttempt.hostStages == nil
	and oneRoleAttempt.addedResults == nil and oneRoleAttempt.rawResult == nil
	and oneRoleAttempt.summaries == nil and oneRoleAttempt.resultPath == nil
	and oneRoleSurface.isFile(oneRoleAttempt.stdoutPath) and oneRoleSurface.isFile(oneRoleAttempt.stderrPath),
	"rehearsal attempt contained timing/result metrics or lost logs")
local oneRoleRaw = string.gsub(oneRole.ledgerPath, "/ledger%.json$", "/raw")
assert(#oneRoleSurface.readDir(oneRoleRaw) == 0, "rehearsal archived a raw result")
for _, call in oneRoleCalls do
	if call.program == C00.lune then
		assert(call.arguments[2] == oneRoleCopy .. "/" .. Study.HOST_SCRIPT
			and call.arguments[6] == "ControlProof" and call.options.cwd == oneRoleCopy,
			"baseline rehearsal did not launch the copied runner with the selected role cwd")
	end
end

local twoRoleSurface, twoRoleFiles = memorySurface("C:/Studio.exe", "E:/candidate")
local twoRoleOptions = studyOptions("E:/candidate")
twoRoleOptions.mode = "rehearse"
local twoRoleExecutor, twoRoleCalls, twoRoleHostCalls = fakeExecutor(twoRoleSurface, twoRoleFiles, nil, 300)
local twoRole = runStudy(twoRoleOptions, { fs = twoRoleSurface, execute = twoRoleExecutor, hash = serde.hash })
local twoRoleLedger = serde.decode("json", twoRoleSurface.readFile(twoRole.ledgerPath))
local twoRoleToken = string.match(twoRole.ledgerPath, "/broadcast%-study%-(%x+)/ledger%.json$")
assert(twoRoleToken ~= nil, "two-role rehearsal output did not retain its copy token")
local twoRoleBaselineCopy = Study.copyDestination("E:/relay", twoRoleToken, "baseline")
local twoRoleCandidateCopy = Study.copyDestination("E:/candidate", twoRoleToken, "candidate")
assert(twoRoleLedger.status == "Passed" and #twoRoleLedger.attempts == 2
	and twoRoleHostCalls() == 2 and twoRoleLedger.attempts[1].launchId ~= twoRoleLedger.attempts[2].launchId,
	"two-role rehearsal did not record unique control launches")
local twoRoleHostIndex = 0
for _, call in twoRoleCalls do
	if call.program == C00.lune then
		twoRoleHostIndex += 1
		local attempt = twoRoleLedger.attempts[twoRoleHostIndex]
		assert(call.arguments[2] == twoRoleBaselineCopy .. "/" .. Study.HOST_SCRIPT
			and call.arguments[6] == "ControlProof"
			and call.options.cwd == (if twoRoleHostIndex == 1 then twoRoleBaselineCopy else twoRoleCandidateCopy)
			and attempt.executionRoot == call.options.cwd,
			`rehearsal host invocation {twoRoleHostIndex} did not preserve runner/role copy ownership`)
	end
end
assert(twoRoleHostIndex == 2, "candidate rehearsal invoked an unexpected number of copied hosts")

local rehearsalCopySurface, rehearsalCopyFiles = memorySurface("C:/Studio.exe")
local rehearsalCopyOptions = studyOptions()
rehearsalCopyOptions.mode = "rehearse"
local rehearsalCopyExecute, _, rehearsalCopyHostCalls = fakeExecutor(rehearsalCopySurface, rehearsalCopyFiles, nil, 350)
reject("BCAST_E_COPY_INJECTED", function()
	runStudy(rehearsalCopyOptions, {
		fs = rehearsalCopySurface, execute = rehearsalCopyExecute, hash = serde.hash,
		copySource = function() error("BCAST_E_COPY_INJECTED", 0) end,
	})
end)
local rehearsalCopyLedgerPath = nil
for _, name in rehearsalCopySurface.readDir("E:/relay/.tmp") do
	if string.sub(name, 1, #"broadcast-study-") == "broadcast-study-" then
		rehearsalCopyLedgerPath = `E:/relay/.tmp/{name}/ledger.json`
	end
end
assert(rehearsalCopyLedgerPath ~= nil, "copy-failed rehearsal did not retain a ledger")
local rehearsalCopyLedger = serde.decode("json", rehearsalCopySurface.readFile(rehearsalCopyLedgerPath))
assert(rehearsalCopyLedger.status == "Failed" and rehearsalCopyLedger.execution.status == "Failed"
	and #rehearsalCopyLedger.attempts == 0 and rehearsalCopyHostCalls() == 0,
	"copy-failed rehearsal did not persist failure status before any host launch")

local rehearsalOutputSurface, rehearsalOutputFiles = memorySurface("C:/Studio.exe")
local rehearsalOutputOptions = studyOptions()
rehearsalOutputOptions.mode = "rehearse"
local rehearsalOutputExecute = fakeExecutor(rehearsalOutputSurface, rehearsalOutputFiles,
	function() return true, "result", nil end, 400)
reject("BCAST_E_REHEARSAL_RESULTS", function()
	runStudy(rehearsalOutputOptions, { fs = rehearsalOutputSurface, execute = rehearsalOutputExecute, hash = serde.hash })
end)
local rehearsalFailurePath = nil
for _, name in rehearsalOutputSurface.readDir("E:/relay/.tmp") do
	if string.sub(name, 1, #"broadcast-study-") == "broadcast-study-" then
		rehearsalFailurePath = `E:/relay/.tmp/{name}/ledger.json`
	end
end
assert(rehearsalFailurePath ~= nil, "unexpected-result rehearsal did not retain a ledger")
local rehearsalFailure = serde.decode("json", rehearsalOutputSurface.readFile(rehearsalFailurePath))
local rehearsalFailureAttempt = rehearsalFailure.attempts[1]
assert(rehearsalFailure.schema == "Relay.BroadcastRehearsalLedger" and rehearsalFailure.status == "Failed"
	and rehearsalFailureAttempt.failure == "BCAST_E_REHEARSAL_RESULTS"
	and #rehearsalFailureAttempt.unexpectedResults == 1
	and rehearsalFailureAttempt.rawResult == nil and rehearsalFailureAttempt.addedResults == nil
	and rehearsalOutputSurface.isFile(rehearsalFailureAttempt.stdoutPath)
	and rehearsalOutputSurface.isFile(rehearsalFailureAttempt.stderrPath),
	"unexpected control result was not rejected with auditable output evidence")
reject("BCAST_REPORT_E_LEDGER", function()
	Report.report(rehearsalFailurePath, 0.05, function(path: string): string
		return rehearsalOutputSurface.readFile(path)
	end)
end)
reject("BCAST_RECOVERY_E_LEDGER", function()
	RecoveryAudit.audit(rehearsalFailurePath, {
		os = "windows", cwd = "E:/relay", hash = serde.hash,
		readFile = function(path: string): string return rehearsalOutputSurface.readFile(path) end,
		fileSize = function(path: string): number return #rehearsalOutputSurface.readFile(path) end,
	})
end)

local rehearsalDriftSurface, rehearsalDriftFiles = memorySurface("C:/Studio.exe")
local rehearsalDriftOptions = studyOptions()
rehearsalDriftOptions.mode = "rehearse"
local rehearsalDriftExecute, _, rehearsalDriftHostCalls = fakeExecutor(rehearsalDriftSurface, rehearsalDriftFiles,
	function() return true, "source", nil end, 500)
reject("BCAST_E_SOURCE_CHANGED", function()
	runStudy(rehearsalDriftOptions, { fs = rehearsalDriftSurface, execute = rehearsalDriftExecute, hash = serde.hash })
end)
assert(rehearsalDriftHostCalls() == 1, "source drift did not stop rehearsal after its first host")
end

-- The raw copy is the immutable validation input. Mutate the result source
-- immediately after its archive read and prove the ledger still agrees with
-- the archived bytes rather than a later source reread.
local archiveSurface, archiveFiles = memorySurface("C:/Studio.exe")
local archiveReadFile = archiveSurface.readFile
C00.archiveResultSuffix = `/benchmarks/results/local/{idFor(1)}.result-v2.json`
C00.archiveResultPath = nil
C00.archiveResultReads = 0
C00.archiveOriginalBody = nil
function archiveSurface.readFile(path: string): string
    local body = archiveReadFile(path)
	if string.sub(path, -#C00.archiveResultSuffix) == C00.archiveResultSuffix then
		C00.archiveResultPath = path
        C00.archiveResultReads += 1
        if C00.archiveResultReads == 2 then
            C00.archiveOriginalBody = body
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
assert(C00.archiveResultPath ~= nil, "source result path was not observed")
local function resultMeasurement(resultBody: any, id: string): any
    for _, measurement in resultBody.measurements do
        if measurement.metadata.id == id then return measurement end
    end
    error(`missing measurement {id}`, 0)
end
local archiveRawSubmit = resultMeasurement(archiveRawResult, "submitCallDuration")
local archiveSourceSubmit = resultMeasurement(serde.decode("json", archiveFiles[C00.archiveResultPath]), "submitCallDuration")
assert(C00.archiveOriginalBody ~= nil and C00.archiveResultReads > 2
	and archiveFiles[C00.archiveResultPath] ~= C00.archiveOriginalBody
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
C00.candidateToken = string.match(candidateStudy.ledgerPath, "/broadcast%-study%-(%x+)/ledger%.json$")
assert(C00.candidateToken ~= nil, "candidate study output path did not retain its copy token")
C00.candidateBaselineCopy = Study.copyDestination("E:/relay", C00.candidateToken, "baseline")
C00.candidateExecutionCopy = Study.copyDestination("E:/candidate", C00.candidateToken, "candidate")
local candidateCwdCount = 0
local baselineCwdCount = 0
local candidateHostCount = 0
for _, call in candidateCalls do
	if call.program == C00.lune then
        candidateHostCount += 1
		local attempt = candidateLedger.attempts[candidateHostCount]
		assert(call.arguments[2] == C00.candidateBaselineCopy .. "/" .. Study.HOST_SCRIPT,
            "candidate launch did not use the pinned baseline host script")
		if call.options.cwd == C00.candidateExecutionCopy then
            candidateCwdCount += 1
		elseif call.options.cwd == C00.candidateBaselineCopy then
            baselineCwdCount += 1
        else
            error(`unexpected candidate study cwd {call.options.cwd}`, 0)
        end
		assert(call.options.cwd == (if attempt.label == "candidate" then C00.candidateExecutionCopy else C00.candidateBaselineCopy),
			"selected role did not execute from its verified copy")
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

do
	local retainedLogSurface, retainedLogFiles = memorySurface("C:/Studio.exe")
	local retainedLogExecute, _, retainedLogHostCalls = fakeExecutor(retainedLogSurface, retainedLogFiles, function()
		return false, "retained-log"
	end)
	local retainedLogOk, retainedLogFailure = pcall(function()
		runStudy(studyOptions(), {
			fs = retainedLogSurface, execute = retainedLogExecute, hash = serde.hash,
		})
	end)
	assert(not retainedLogOk and string.find(tostring(retainedLogFailure), "BCAST_E_HOST", 1, true) ~= nil
		and string.find(tostring(retainedLogFailure), "BCAST_E_COPY_CHANGED", 1, true) == nil
		and retainedLogHostCalls() == 1, "retained host diagnostics changed the failed-host classification")
	local retainedLogLedgerPath
	for _, path in retainedLogSurface.readDir("E:/relay/.tmp") do
		if string.sub(path, 1, #"broadcast-study-") == "broadcast-study-" then
			retainedLogLedgerPath = `E:/relay/.tmp/{path}/ledger.json`
		end
	end
	assert(retainedLogLedgerPath ~= nil, "retained-log failure ledger was not saved")
	local retainedLogLedger = serde.decode("json", retainedLogSurface.readFile(retainedLogLedgerPath))
	local retainedLogAttempt = retainedLogLedger.attempts[1]
	assert(retainedLogAttempt.failure == "BCAST_E_HOST" and retainedLogAttempt.rawResult ~= nil
		and retainedLogSurface.isFile(retainedLogAttempt.rawResult[1].path)
		and retainedLogSurface.isFile(retainedLogAttempt.stdoutPath)
		and retainedLogSurface.isFile(retainedLogAttempt.stderrPath),
		"retained host diagnostic failure did not preserve archived evidence")
end

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
    collectInputManifest = function(o: any, p: any, d: any): (any, any) return fakeManifest(o, p, d, "a") end,
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
assert(freshHostCalls() == 6 and fresh.ledger.version == 4 and #fresh.ledger.attempts == 6
    and fresh.ledger.collectionId ~= nil and fresh.ledger.restartOf.path == failureLedgerPath
    and fresh.ledger.restartOf.sha256 == "sha256:" .. serde.hash("sha256", originalLedgerBytes)
    and fresh.ledger.attempts[1].runId == idFor(101)
    and failureSurface.readFile(failureLedgerPath) == originalLedgerBytes
    and failureSurface.readFile(failureLedger.attempts[4].rawResult[1].path) == originalRawBytes,
    "fresh restart did not preserve prior evidence and replace the whole comparison")
local freshReport = Report.report(fresh.ledgerPath, 0.1, failureSurface.readFile)
local originalFreshLedgerBytes = failureSurface.readFile(fresh.ledgerPath)
assert(freshReport.collection.id == fresh.ledger.collectionId
	and freshReport.executionProvenance.kind == "VerifiedCopy"
	and freshReport.executionProvenance.originalSources.baseline.root == "E:/relay"
	and freshReport.executionProvenance.copies.baseline.root == fresh.ledger.execution.copies.baseline.root
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
assert(failedV3.version == 4 and failedV3.finishedUtc == nil and #failedV3.attempts == 2
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
assert(nestedHostCalls() == 6 and nested.ledger.version == 4
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

for _, mutation in { "corrupt", "extra" } do
	local copySurface, copyFiles = memorySurface("C:/Studio.exe")
	local copyExecutor, _, copyHostCalls = fakeExecutor(copySurface, copyFiles)
	local originalCopySource = copySurface.copySource
	local function mutateCopy(root: string, destination: string, dependencies: any): any
		local copied = originalCopySource(root, destination, dependencies)
		if mutation == "corrupt" then
			copySurface.writeFile(destination .. "/benchmarks/host/run-event-v1.luau", "changed runner bytes")
		else
			copySurface.writeFile(destination .. "/unexpected.txt", "unlisted copy addition")
		end
		return copied
	end
	reject("BCAST_E_COPY_CHANGED", function()
		runStudy(studyOptions(), { fs = copySurface, execute = copyExecutor, hash = serde.hash,
			copySource = mutateCopy })
	end)
	assert(copyHostCalls() == 0, `a {mutation} copied input reached the child`)
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
				if sourceChecks == 4 then return { ok = true, stdout = " M src/init.luau\n" } end
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
			return fakeManifest(o, p, d, if inputReads == 5 then "b" else "a")
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
