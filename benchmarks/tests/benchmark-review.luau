--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Review = require("../reporting/BenchmarkReview")
local Study = require("../host/BroadcastStudy")
local Result = require("../contracts/result-v2")
local Fixtures = require("./support/HostRuntimeFixtures")

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in value do result[key] = clone(child) end
	return result
end

local function hash(bytes: string): string return "sha256:" .. serde.hash("sha256", bytes) end
local root = string.gsub(process.cwd, "\\", "/"):gsub("/+$", "")
local directory = root .. "/.tmp/benchmark-review-" .. string.sub(serde.hash("sha256", tostring({}) .. tostring(os.clock())), 1, 16)
local ledgerPath = directory .. "/ledger.json"
local baseline, candidate = string.rep("a", 40), string.rep("b", 40)
local _, maximum = Fixtures.maximum()

-- Raw fixtures use the existing canonical schema. Summaries are calculated
-- independently here; validation and assessment receive only archived bytes.
local function evidence(controlScale: number): (any, any)
	local ledger = { schema = "Relay.BroadcastStudyLedger", version = 1,
		startedUtc = "2026-10-11T00:00:00Z", finishedUtc = "2026-10-11T01:00:00Z",
		sources = { baseline = { root = "E:/baseline", revision = baseline }, candidate = { root = "E:/candidate", revision = candidate } },
		topology = { mode = "PersistentBenchmark", caseId = "state-broadcast-s2c", recipients = 1 },
		studio = { path = "C:/Studio.exe", size = 123, sha256 = hash("studio") }, schedule = {}, attempts = {} }
	local files = {}
	for index, scheduled in Study.schedule({ baseline = "E:/baseline", candidate = "E:/candidate" }) do
		local item, result = clone(scheduled), clone(maximum)
		item.index = index
		ledger.schedule[index] = item
		result.schema = { id = "result-v2", version = 2 }
		result.benchmark.version = 2
		result.contract.id = "event-session-v1"
		local revision = if item.label == "candidate" then candidate else baseline
		result.benchmark.source.revision = revision
		result.benchmark.source.measurementFingerprint = "sha256:" .. string.rep("c", 64)
		result.benchmark.source.adapterFingerprint = "sha256:" .. string.rep(if item.label == "native" then "d"
			elseif item.label == "candidate" then "f" else "e", 64)
		result.runId = string.format("00112233-4455-4677-8899-%012d", index)
		result.adapter.id = item.adapterId
		result.adapter.lane = "EquivalentSemantics"
		result.adapter.semantics.repetitionIsolation = "PersistentSession"
		if item.label == "native" then
			result.adapter.displayName = "Roblox RemoteEvent"
			result.adapter.integrationKind = "EngineBuiltIn"
			result.adapter.library = { id = "roblox-remote-event", displayName = "Roblox RemoteEvent", version = "0.650.0.6500000",
				provenance = { kind = "EngineBuiltIn", studioVersion = "0.650.0.6500000" } }
		else
			result.adapter.displayName = "Relay"
			result.adapter.integrationKind = "Runtime"
			result.adapter.library = { id = "relay", displayName = "Relay", version = "0.2.0", provenance = {
				kind = "Repository", sourceRepository = "https://github.com/steven-dinh/relay", revision = revision,
				checksum = "sha256:" .. string.rep("9", 64), license = "MIT" } }
		end
		result.environment.execution.mode = "StudioMultiplayer"
		result.environment.execution.clientCount = 1
		result.conformance.sessionProof = { version = 1, passed = true }
		local scale = if item.label == "control" then controlScale elseif item.label == "candidate" then 0.8 else 1
		for _, measurement in result.measurements do
			if measurement.metadata.availability == "Optional" then
				measurement.state = "Unavailable"
				measurement.rawSamples, measurement.summary = nil, nil
				measurement.unavailableReason = { code = "UnavailableInEnvironment" }
			elseif measurement.metadata.summary == "MedianAndP95" then
				local count = 0
				for _, group in measurement.rawSamples do
					for sampleIndex in group.values do group.values[sampleIndex] = 100 * scale; count += 1 end
				end
				measurement.summary = { kind = "MedianAndP95", sampleCount = count, median = 100 * scale, p95 = 100 * scale }
			end
		end
		result = Result.validate(result)
		local bytes = serde.encode("json", result)
		local original = item.root .. "/benchmarks/results/local/" .. result.runId .. ".result-v2.json"
		local archive = directory .. string.format("/raw/attempt-%03d-1-%s.result-v2.json", index, result.runId)
		local attempt = clone(item)
		attempt.valid, attempt.exitCode, attempt.stdoutTruncated, attempt.stderrTruncated = true, 0, false, false
		attempt.finishedUtc, attempt.addedResults, attempt.runId = ledger.finishedUtc, 1, result.runId
		attempt.resultPath, attempt.resultSize, attempt.resultSha256 = original, #bytes, hash(bytes)
		attempt.sourceRevision = revision
		attempt.measurementFingerprint = result.benchmark.source.measurementFingerprint
		attempt.contractFingerprint = result.contract.fingerprint
		attempt.summaries = Study.copySummaries(result)
		attempt.rawResult = { { path = archive, sourcePath = original, size = #bytes, sha256 = hash(bytes) } }
		ledger.attempts[index], files[archive] = attempt, bytes
	end
	files[ledgerPath] = serde.encode("json", ledger)
	return ledger, files
end

local options = Review.parseArgs({ "--ledger", ledgerPath, "--maximum-control-drift", "0.05" })
local function assess(files: any, selected: any?, execute: any?): any
	return Review.assess(selected or options, function(path: string)
		assert(files[path] ~= nil, "missing fixture")
		return files[path]
	end, execute)
end

local function git(revisions: { string }, statuses: { string }): any
	local reads = 0
	return function(program: string, args: any, config: any): any
		assert(program == "git" and config.cwd == "E:/current", "unexpected source command")
		if args[1] == "rev-parse" then
			assert(#args == 2 and args[2] == "HEAD")
			reads += 1
			return { ok = true, stdout = revisions[reads] .. "\n" }
		end
		assert(table.concat(args, " ") == "status --porcelain=v1 --untracked-files=normal --ignore-submodules=none")
		return { ok = true, stdout = statuses[reads] }
	end
end

local ledger, files = evidence(1)
local clean = assess(files)
assert(clean.state == "DiagnosticsOnly" and clean.sourceRelationship == "NotCompared" and clean.rankingEligible == false)
assert(clean.cpuAttribution == "Unqualified" and clean.packetAttribution == "Unqualified")
local selected = clone(options)
selected.currentRoot, selected.sourceRole = "E:/current", "candidate"
local match = assess(files, selected, git({ candidate, candidate }, { "", "" }))
assert(match.state == "DiagnosticsOnly" and match.sourceRelationship == "CleanRevisionMatch" and not match.rankingEligible)
local dirty = assess(files, selected, git({ candidate, candidate }, { " M src/internal/StateQueue.luau\n", " M src/internal/StateQueue.luau\n" }))
assert(dirty.state == "Inconclusive" and dirty.reasons[1] == "BCAST_E_SOURCE_DIRTY" and dirty.report ~= nil)
local changed = assess(files, selected, git({ candidate, baseline }, { "", "" }))
assert(changed.state == "Inconclusive" and changed.reasons[1] == "SOURCE_CHANGED_DURING_REVIEW")
local historical = assess(files, selected, git({ baseline, baseline }, { "", "" }))
assert(historical.state == "Inconclusive" and historical.reasons[1] == "SOURCE_REVISION_MISMATCH")
local unavailable = assess(files, selected, function() return { ok = false, stdout = "" } end)
assert(unavailable.state == "Inconclusive" and unavailable.reasons[1] == "BCAST_E_SOURCE")

local _, driftFiles = evidence(0.90)
assert(assess(driftFiles).state == "Inconclusive")
local loose = clone(options)
loose.maximumControlDrift = 0.15
assert(assess(driftFiles, loose).state == "DiagnosticsOnly", "tolerance was treated as universal")
local malformed = clone(files)
malformed[ledgerPath] = "{malformed"
assert(assess(malformed).state == "Blocked")
assert(assess({}).state == "Blocked")
local tampered = clone(files)
tampered[ledger.attempts[1].rawResult[1].path] ..= " "
assert(assess(tampered).state == "Blocked")
local missing = clone(files)
missing[ledger.attempts[1].rawResult[1].path] = nil
assert(assess(missing).state == "Blocked")
local function alteredControl(change: any): any
	local alteredLedger, alteredFiles = clone(ledger), clone(files)
	for _, attempt in alteredLedger.attempts do
		if attempt.label ~= "control" then continue end
		local raw = attempt.rawResult[1]
		local value = serde.decode("json", alteredFiles[raw.path])
		change(value)
		local bytes = serde.encode("json", value)
		alteredFiles[raw.path] = bytes
		raw.size, raw.sha256 = #bytes, hash(bytes)
		attempt.resultSize, attempt.resultSha256 = raw.size, raw.sha256
		break
	end
	alteredFiles[ledgerPath] = serde.encode("json", alteredLedger)
	return alteredFiles
end
assert(assess(alteredControl(function(value) value.benchmark.source.dirty = true end)).state == "Blocked",
	"a dirty unchanged control was accepted")
assert(assess(alteredControl(function(value) value.benchmark.source.revision = candidate end)).state == "Blocked",
	"a control's changed source was accepted")
assert(assess(alteredControl(function(value) value.environment.studio.version = "0.651.0.6510000" end)).state == "Blocked",
	"incompatible engine evidence was accepted")

-- A claimed qualification in an extra receipt cannot establish native EOF,
-- capture validity or attribution. Retained raw fixtures still yield no winner.
ledger.libmp = { qualified = true, markerMatches = 1, stepLimitReached = true, stepReturnedFalse = true,
	workloadAttributed = true, cpuMicroseconds = 42, packetBytes = 0 }
files[ledgerPath] = serde.encode("json", ledger)
local unqualified = assess(files)
assert(unqualified.cpuAttribution == "Unqualified" and unqualified.packetAttribution == "Unqualified" and not unqualified.rankingEligible)

for _, args in { {}, { "--ledger", "a", "--maximum-control-drift", "-1" },
	{ "--ledger", "a", "--maximum-control-drift", "nan" },
	{ "--ledger", "a", "--ledger", "b" },
	{ "--ledger", "a", "--maximum-control-drift", "0.05", "--current-root", "E:/current", "--source-role", "control" } } do
	assert(not pcall(Review.parseArgs, args), "invalid arguments accepted")
end

-- Exercise the real CLI and read-only raw paths; each test owns a new root.
fs.writeDir(directory .. "/raw")
for path, bytes in files do fs.writeFile(path, bytes) end
local args = { "run", ".agents/skills/relay-benchmark-review/scripts/assess-study.luau", "--ledger", ledgerPath, "--maximum-control-drift", "0.05" }
local cli = process.exec("lune", args)
assert(cli.ok and serde.decode("json", cli.stdout).state == "DiagnosticsOnly", cli.stderr)
for path, bytes in driftFiles do fs.writeFile(path, bytes) end
local driftCli = process.exec("lune", args)
assert(driftCli.code == 1 and serde.decode("json", driftCli.stdout).state == "Inconclusive")
fs.writeFile(ledgerPath, "{")
local invalid = process.exec("lune", args)
assert(invalid.code == 2 and serde.decode("json", invalid.stdout).state == "Blocked")
local badArgs = process.exec("lune", { "run", ".agents/skills/relay-benchmark-review/scripts/assess-study.luau" })
assert(badArgs.code == 2 and serde.decode("json", badArgs.stdout).reasons[1] == "BENCH_REVIEW_E_ARGS")
fs.removeDir(directory)
print("PASS benchmark review: raw integrity, tolerance, source identity, attribution limits and CLI failure exits")
