--!strict

local serde = require("@lune/serde")
local fs = require("@lune/fs")
local Recovery = require("../host/BroadcastRecoveryAudit")
local Study = require("../host/BroadcastStudy")
local Fingerprint = require("../host/MeasurementFingerprint")

local directory = "E:/relay/.tmp/study"
local ledgerPath = directory .. "/ledger.json"
local baseline = "E:/relay"
local revision = string.rep("a", 40)
local studioHash = "sha256:" .. string.rep("b", 64)
local pinned = "sha256:" .. string.rep("c", 64)
local chain = { lune = pinned, rojo = pinned,
	sha256 = Fingerprint.digest({ lune = pinned, rojo = pinned }, serde.hash, "RelayStudyTools:1") }
local tools = { baseline = chain,
	sha256 = Fingerprint.digest({ baseline = chain.sha256, candidate = "none" }, serde.hash, "RelayStudyAllTools:1") }
local options = { os = "windows", baseline = baseline, candidate = nil, studio = "C:/Studio.exe", recipients = 1 }
local studyPlan = Study.plan(options)
local planHash = Fingerprint.digest({ bytes = serde.encode("json", studyPlan) }, serde.hash, "RelayStudyPlan:1")
local manifest = { version = 1, baseline = { files = 1, sha256 = pinned }, tools = tools,
	planSha256 = planHash, studioSha256 = studioHash,
	sha256 = Fingerprint.digest({ baseline = pinned, baselineFiles = "1", candidate = "none", candidateFiles = "none",
		tools = tools.sha256, plan = planHash, studio = studioHash }, serde.hash, "RelayStudyInputManifest:1") }
local schedule = Study.schedule(options)
local ledger = { schema = "Relay.BroadcastStudyLedger", version = 2,
	startedUtc = "2026-10-14T00:00:00Z", sources = { baseline = { root = baseline, revision = revision } },
	studio = { path = options.studio, sha256 = studioHash, size = 10 },
	topology = studyPlan.topology, inputManifest = manifest, schedule = {}, attempts = {} }
for index, item in schedule do
	ledger.schedule[index] = table.clone(item)
	ledger.schedule[index].index = index
end
local files: any = {}
local function save() files[ledgerPath] = serde.encode("json", ledger) end
local function attempt(index: number): any
	local entry = table.clone(ledger.schedule[index])
	entry.inputManifestSha256 = manifest.sha256
	entry.startedUtc = "2026-10-14T00:01:00Z"
	entry.finishedUtc = "2026-10-14T00:02:00Z"
	entry.valid = false
	entry.failure = "BCAST_E_HOST"
	entry.stdoutPath = directory .. string.format("/attempt-%03d.stdout.log", index)
	entry.stderrPath = directory .. string.format("/attempt-%03d.stderr.log", index)
	return entry
end
local function archive(entry: any, rawIndex: number, runId: string): string
	local name = runId .. ".result-v2.json"
	local body = serde.encode("json", { runId = runId })
	local source = entry.root .. "/benchmarks/results/local/" .. name
	local destination = directory .. "/raw/" .. string.format("attempt-%03d-%d-%s", entry.index, rawIndex, name)
	files[destination] = body
	entry.rawResult = entry.rawResult or {}
	table.insert(entry.rawResult, { sourcePath = source, path = destination,
		size = #body, sha256 = "sha256:" .. serde.hash("sha256", body) })
	entry.addedResults = #entry.rawResult
	entry.exitCode = 17
	files[entry.stdoutPath] = "failed"
	files[entry.stderrPath] = "failed"
	entry.stdoutBytes = #files[entry.stdoutPath]
	entry.stderrBytes = #files[entry.stderrPath]
	return destination
end
local currentManifest: any = manifest
local currentRevision = revision
local dependencies = { os = "windows", hash = serde.hash,
	fileSize = function(path: string): number
		assert(files[path] ~= nil, "missing " .. path)
		return #files[path]
	end,
	readFile = function(path: string): string
		assert(files[path] ~= nil, "missing " .. path)
		return files[path]
	end,
	sourceIdentity = function(root: string): any
		assert(root == baseline)
		return { root = root, revision = currentRevision }
	end,
	collectInputManifest = function(): any return currentManifest end }
local function inspect(): any save(); return Recovery.audit(ledgerPath, dependencies) end
local function reject(code: string, callback: () -> ())
	local ok, message = pcall(callback)
	assert(not ok and string.find(tostring(message), "BCAST_RECOVERY_E_" .. code, 1, true),
		`expected {code}, got {tostring(message)}`)
end

local rehearsalLedger = table.clone(ledger)
rehearsalLedger.schema = "Relay.BroadcastRehearsalLedger"
files[ledgerPath] = serde.encode("json", rehearsalLedger)
reject("LEDGER", function() Recovery.audit(ledgerPath, dependencies) end)
local controlLedger = table.clone(ledger)
controlLedger.topology = table.clone(ledger.topology)
controlLedger.topology.mode = "ControlProof"
files[ledgerPath] = serde.encode("json", controlLedger)
reject("LEDGER", function() Recovery.audit(ledgerPath, dependencies) end)
save()

local failedCopyPath = baseline .. "/.tmp/broadcast-study-0000000000000001/ledger.json"
local failedCopyLedger = table.clone(ledger)
failedCopyLedger.version = 4
failedCopyLedger.execution = { version = 1, status = "Failed", runner = nil, copies = {},
	copyFailure = "BCAST_E_COPY_CHANGED" }
failedCopyLedger.attempts = {}
files[failedCopyPath] = serde.encode("json", failedCopyLedger)
local failedCopyAudit = Recovery.audit(failedCopyPath, dependencies)
assert(failedCopyAudit.status == "FreshFullStudyRequired" and #failedCopyAudit.previousAttempts == 0,
	"copy-failure recovery required toolchains that were never pinned")
currentManifest = table.clone(manifest)
currentManifest.sha256 = pinned
reject("INPUT_CHANGED", function() Recovery.audit(failedCopyPath, dependencies) end)
currentManifest = manifest
files[failedCopyPath] = nil

ledger.attempts[1] = attempt(1)
local first = inspect()
local bytes = files[ledgerPath]
local second = inspect()
assert(first.status == "FreshFullStudyRequired" and first.selection == "none"
	and #first.previousAttempts == 1 and first.previousAttempts[1].state == "Rejected"
	and second.ledgerSha256 == first.ledgerSha256 and files[ledgerPath] == bytes,
	"repeated read-only audit selected or modified interrupted evidence")
for _, cwd in { baseline, baseline .. "/" } do
	dependencies.cwd = cwd
	local relative = Recovery.audit(".tmp/study/ledger.json", dependencies)
	local absolute = Recovery.audit(ledgerPath, dependencies)
	assert(relative.ledger == absolute.ledger and relative.ledgerSha256 == absolute.ledgerSha256
		and relative.previousAttempts[1].state == absolute.previousAttempts[1].state
		and files[ledgerPath] == bytes,
		"absolute and relative ledger paths selected different evidence")
end
dependencies.cwd = nil
ledger.attempts[1].finishedUtc = nil
ledger.attempts[1].failure = nil
assert(inspect().previousAttempts[1].state == "Interrupted", "in-flight checkpoint was not visible")
ledger.attempts[1].finishedUtc = "2026-10-14T00:02:00Z"
ledger.attempts[1].failure = "BCAST_E_HOST"

currentManifest = table.clone(manifest)
currentManifest.sha256 = pinned
reject("INPUT_CHANGED", inspect)
currentManifest = manifest
currentRevision = string.rep("d", 40)
reject("SOURCE_CHANGED", inspect)
dependencies.verifyCurrent = false
local historical = inspect()
assert(historical.sources.baseline.revision == revision and historical.inputManifestSha256 == manifest.sha256,
	"historical validation lost the frozen source and manifest pins")
dependencies.verifyCurrent = nil
currentRevision = revision

local raw = archive(ledger.attempts[1], 1, "aaa")
assert(#inspect().previousAttempts[1].archives == 1, "rejected raw artifact disappeared")
files[raw] = "corrupt"
reject("ARCHIVE_HASH", inspect)
files[raw] = serde.encode("json", { runId = "aaa" })
archive(ledger.attempts[1], 2, "aaa")
reject("RAW_RESULT", inspect)
table.remove(ledger.attempts[1].rawResult)
archive(ledger.attempts[1], 2, "AAA")
reject("RAW_RESULT", inspect)
table.remove(ledger.attempts[1].rawResult)
ledger.attempts[1].addedResults = #ledger.attempts[1].rawResult

local oversized = string.rep("x", 1_048_577)
files[ledgerPath] = oversized
local fileRead = dependencies.readFile
dependencies.readFile = function(path: string): string
	assert(path ~= ledgerPath, "oversized ledger was read before size rejection")
	return fileRead(path)
end
reject("LEDGER_READ", function() Recovery.audit(ledgerPath, dependencies) end)
dependencies.readFile = fileRead
save()
ledger.attempts[1].valid = true
ledger.attempts[1].failure = nil
files[ledger.attempts[1].stdoutPath] = nil
reject("LOG", inspect)
ledger.attempts[1].valid = false
ledger.attempts[1].failure = "BCAST_E_HOST"
local stdoutPath = ledger.attempts[1].stdoutPath
files[stdoutPath] = string.rep("x", 131_073)
ledger.attempts[1].stdoutBytes = 131_073
dependencies.readFile = function(path: string): string
	assert(path ~= stdoutPath, "oversized log was read before size rejection")
	return fileRead(path)
end
reject("LOG", inspect)
dependencies.readFile = fileRead
files[stdoutPath] = "failed"
ledger.attempts[1].stdoutBytes = #files[stdoutPath]

ledger.attempts[2] = attempt(2)
reject("ATTEMPT", inspect) -- no later slot may complete a failed comparison unit
ledger.attempts[2] = nil
ledger.attempts[1].inputManifestSha256 = pinned
reject("ATTEMPT", inspect)
ledger.attempts[1].inputManifestSha256 = manifest.sha256
ledger.sources.candidate = true
reject("LEDGER", inspect)
ledger.sources.candidate = nil
ledger.attempts[1].rawResult[1].path = directory .. "/outside.json"
reject("ARCHIVE", inspect)
ledger.attempts[1].rawResult[1].path = raw
ledger.finishedUtc = "2026-10-14T01:00:00Z"
reject("LEDGER", inspect)
ledger.finishedUtc = nil
files[ledgerPath] = "{"
reject("LEDGER", function() Recovery.audit(ledgerPath, dependencies) end)

local readerPath = ".tmp/broadcast-recovery-reader-"
	.. string.sub(serde.hash("sha256", tostring({}) .. tostring(os.clock())), 1, 16) .. ".txt"
local readerBody = "a\0b"
fs.writeFile(readerPath, readerBody, { overwrite = false })
assert(Recovery.readCapped(readerPath, #readerBody) == readerBody,
	"capped Windows reader changed retained bytes")
reject("READ", function() Recovery.readCapped(readerPath, #readerBody - 1) end)
for _, value in { "a", "a\0", "a\0bc" } do
	fs.writeFile(readerPath, value, { overwrite = true })
	assert(Recovery.readCapped(readerPath, #value) == value, "capped base64 padding changed bytes")
end
fs.removeFile(readerPath)

local lineageFiles = {}
local lineageDependencies = {}
for key, value in dependencies do lineageDependencies[key] = value end
lineageDependencies.verifyCurrent = false
lineageDependencies.readFile = function(path: string): string
	assert(lineageFiles[path] ~= nil, "missing lineage fixture " .. path)
	return lineageFiles[path]
end
lineageDependencies.fileSize = function(path: string): number
	assert(lineageFiles[path] ~= nil, "missing lineage fixture size " .. path)
	return #lineageFiles[path]
end
local parentPath = baseline .. "/.tmp/broadcast-study-0000000000000000/ledger.json"
local rootLedger = table.clone(ledger)
rootLedger.attempts = {}
rootLedger.finishedUtc = nil
rootLedger.collectionId = nil
rootLedger.restartOf = nil
lineageFiles[parentPath] = serde.encode("json", rootLedger)
for index = 1, 7 do
	local collectionId = string.format("broadcast-study-%016x", index)
	local collectionPath = baseline .. "/.tmp/" .. collectionId .. "/ledger.json"
	local collectionLedger = table.clone(rootLedger)
	collectionLedger.version = 3
	collectionLedger.collectionId = collectionId
	collectionLedger.restartOf = { path = parentPath,
		sha256 = "sha256:" .. serde.hash("sha256", lineageFiles[parentPath]),
		inputManifestSha256 = manifest.sha256 }
	lineageFiles[collectionPath] = serde.encode("json", collectionLedger)
	parentPath = collectionPath
end
local atLimit = Recovery.audit(parentPath, lineageDependencies)
assert(atLimit.lineageLength == Recovery.MAX_LINEAGE_LENGTH,
	"audit depth cap did not include the root ledger")
local overflowId = "broadcast-study-0000000000000008"
local overflowPath = baseline .. "/.tmp/" .. overflowId .. "/ledger.json"
local overflowLedger = table.clone(rootLedger)
overflowLedger.version = 3
overflowLedger.collectionId = overflowId
overflowLedger.restartOf = { path = parentPath,
	sha256 = "sha256:" .. serde.hash("sha256", lineageFiles[parentPath]),
	inputManifestSha256 = manifest.sha256 }
lineageFiles[overflowPath] = serde.encode("json", overflowLedger)
reject("LINEAGE_DEPTH", function() Recovery.audit(overflowPath, lineageDependencies) end)

print("PASS Relay.Benchmarks.BroadcastRecoveryAudit")
