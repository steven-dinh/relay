--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Study = require("../host/BroadcastStudy")
local Report = require("../reporting/BroadcastStudyReport")
local Fingerprint = require("../host/MeasurementFingerprint")
local ResultV2 = require("../contracts/result-v2")
local Fixtures = require("./support/HostRuntimeFixtures")

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in value do copy[key] = clone(child) end
	return copy
end

local function reject(code: string, callback: any)
	local ok, message = pcall(callback)
	assert(not ok and string.find(tostring(message), code, 1, true) ~= nil, `expected {code}, got {tostring(message)}`)
end

local function near(actual: number, expected: number)
	assert(math.abs(actual - expected) < 1e-10, `expected {expected}, got {actual}`)
end

local function hash(bytes: string): string return "sha256:" .. serde.hash("sha256", bytes) end
local _, fixture = Fixtures.maximum()
local ROOT = string.gsub(process.cwd, "\\", "/"):gsub("/+$", "")
local DIRECTORY = ROOT .. "/.tmp/broadcast-study-report-fixture"
local LEDGER_PATH = DIRECTORY .. "/ledger.json"

-- Independently calculate fixture summaries before canonical validation. The
-- report never receives these values except inside the immutable raw results.
local function fixtureSummary(measurement: any): any
	local samples = {}
	for _, group in measurement.rawSamples do
		for _, sample in group.values do table.insert(samples, sample) end
	end
	table.sort(samples)
	if measurement.metadata.summary == "Exact" then
		local total = 0
		for _, sample in samples do total += sample end
		return { kind = "Exact", sampleCount = #samples, total = total }
	end
	local lower = math.floor((#samples + 1) / 2)
	local upper = math.ceil((#samples + 1) / 2)
	return { kind = "MedianAndP95", sampleCount = #samples,
		median = (samples[lower] + samples[upper]) / 2, p95 = samples[math.ceil(#samples * 0.95)] }
end

local function makeResult(index: number, item: any, scale: number, distribution: boolean?): any
	local result = clone(fixture)
	local sourceRevision = if item.root == "E:/baseline" then string.rep("a", 40) else string.rep("b", 40)
	result.schema = { id = "result-v2", version = 2 }
	result.benchmark.version = 2
	result.contract.id = "event-session-v1"
	result.benchmark.source.revision = sourceRevision
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
			kind = "Repository", sourceRepository = "https://github.com/steven-dinh/relay", revision = sourceRevision,
			checksum = "sha256:" .. string.rep("9", 64), license = "MIT" } }
	end
	result.environment.execution.mode = "StudioMultiplayer"
	result.environment.execution.clientCount = 1
	result.conformance.sessionProof = { version = 1, passed = true }
	for _, measurement in result.measurements do
		if measurement.metadata.availability == "Optional" then
			measurement.state = "Unavailable"
			measurement.rawSamples = nil
			measurement.summary = nil
			measurement.unavailableReason = { code = "UnavailableInEnvironment" }
		elseif measurement.metadata.summary == "MedianAndP95" then
			for _, group in measurement.rawSamples do
				for sampleIndex in group.values do
					group.values[sampleIndex] = (if distribution and measurement.metadata.id == "frameTime" then sampleIndex else 100) * scale
				end
			end
			measurement.summary = fixtureSummary(measurement)
		end
	end
	return ResultV2.validate(result)
end

local function evidence(candidate: boolean?, controlScale: number?, distribution: boolean?): (any, any)
	local sources = { baseline = { root = "E:/baseline", revision = string.rep("a", 40) } }
	if candidate then sources.candidate = { root = "E:/candidate", revision = string.rep("b", 40) } end
	local schedule = Study.schedule({ baseline = sources.baseline.root, candidate = if candidate then sources.candidate.root else nil })
	local ledger = { schema = "Relay.BroadcastStudyLedger", version = 1, startedUtc = "2026-10-11T00:00:00Z",
		finishedUtc = "2026-10-11T01:00:00Z", sources = sources,
		topology = { mode = "PersistentBenchmark", caseId = "state-broadcast-s2c", recipients = 1 },
		studio = { path = "C:/Studio.exe", size = 123, sha256 = hash("studio bytes") }, schedule = {}, attempts = {} }
	local files = {}
	for index, item in schedule do
		local result = makeResult(index, item, if item.label == "control" then controlScale or 1
			elseif item.label == "candidate" then 0.8 else 1, distribution)
		local bytes = serde.encode("json", result)
		local originalPath = item.root .. "/benchmarks/results/local/" .. result.runId .. ".result-v2.json"
		local archivePath = DIRECTORY .. string.format("/raw/attempt-%03d-1-%s.result-v2.json", index, result.runId)
		local scheduled = clone(item)
		scheduled.index = index
		ledger.schedule[index] = scheduled
		local attempt = clone(scheduled)
		attempt.valid = true
		attempt.exitCode = 0
		attempt.stdoutTruncated = false
		attempt.stderrTruncated = false
		attempt.finishedUtc = ledger.finishedUtc
		attempt.addedResults = 1
		attempt.runId = result.runId
		attempt.resultPath = originalPath
		attempt.resultSize = #bytes
		attempt.resultSha256 = hash(bytes)
		attempt.sourceRevision = result.benchmark.source.revision
		attempt.measurementFingerprint = result.benchmark.source.measurementFingerprint
		attempt.contractFingerprint = result.contract.fingerprint
		attempt.summaries = Study.copySummaries(result)
		attempt.rawResult = { { path = archivePath, sourcePath = originalPath, size = #bytes, sha256 = hash(bytes) } }
		ledger.attempts[index] = attempt
		files[archivePath] = bytes
	end
	return ledger, files
end

local function uncEvidence(candidate: boolean?): (any, any)
	local ledger, files = evidence(candidate)
	local uncFiles = {}
	local roots = { baseline = "//server/share/baseline", candidate = "//server/share/candidate" }
	ledger.sources.baseline.root = roots.baseline
	if candidate then ledger.sources.candidate.root = roots.candidate end
	for index, attempt in ledger.attempts do
		local root = if attempt.label == "candidate" then roots.candidate else roots.baseline
		ledger.schedule[index].root = root
		attempt.root = root
		attempt.resultPath = root .. "/benchmarks/results/local/" .. attempt.runId .. ".result-v2.json"
		local raw = attempt.rawResult[1]
		local originalPath = raw.path
		local archiveName = string.match(originalPath, "([^/]+)$")
		assert(archiveName ~= nil)
		local archivePath = "//server/share/broadcast/raw/" .. archiveName
		raw.sourcePath = attempt.resultPath
		raw.path = string.gsub(archivePath, "/", "\\")
		uncFiles[archivePath] = files[originalPath]
	end
	return ledger, uncFiles
end

local function evaluate(ledger: any, files: any, threshold: number?, ledgerBytes: string?): any
	files[LEDGER_PATH] = ledgerBytes or serde.encode("json", ledger)
	return Report.report(LEDGER_PATH, threshold or 0.05, function(filename: string)
		assert(files[filename] ~= nil, "missing fixture file")
		return files[filename]
	end)
end

local function alterResult(ledger: any, files: any, index: number, change: any)
	local attempt = ledger.attempts[index]
	local raw = attempt.rawResult[1]
	local value = serde.decode("json", files[raw.path])
	change(value)
	local bytes = serde.encode("json", value)
	files[raw.path] = bytes
	raw.size, raw.sha256 = #bytes, hash(bytes)
	attempt.resultSize, attempt.resultSha256 = raw.size, raw.sha256
end

local UNC_LEDGER_PATH = "\\\\server\\share\\broadcast\\ledger.json"
local function evaluateUnc(ledger: any, files: any): any
	files["//server/share/broadcast/ledger.json"] = serde.encode("json", ledger)
	return Report.report(UNC_LEDGER_PATH, 0.05, function(filename: string)
		assert(files[filename] ~= nil, "missing UNC fixture file")
		return files[filename]
	end)
end

local parsed = Report.parseArgs({ "--ledger", "ledger.json", "--maximum-control-drift", "0.0125", "--output", "new.json" })
assert(parsed.maximumControlDrift == 0.0125 and parsed.outputPath == ROOT .. "/new.json")
for _, arguments in { { "--ledger", "ledger.json" }, { "--ledger", "ledger.json", "--maximum-control-drift", "-1" },
	{ "--ledger", "ledger.json", "--maximum-control-drift", "nan" }, { "--ledger", "a", "--ledger", "b" } } do
	reject("BCAST_REPORT_E_ARGS", function() Report.parseArgs(arguments) end)
end

local ledger, files = evidence(true, 0.9056)
ledger.attempts[1].coarseHostStages = { version = 1, unit = "Seconds", intervals = {
	{ id = "hostExecution", status = "Complete", startedSeconds = 2, finishedSeconds = 10, durationSeconds = 8 } } }
local report = evaluate(ledger, files)
assert(report.controlAssessment == "DriftExceeded" and report.rankingEligible == false)
assert(report.independentLaunches.total == 8 and report.independentLaunches.forward == 4
	and report.independentLaunches.perRolePerOrder == 1 and report.independentLaunches.perRoleAcrossOrders == 2)
assert(report.hostPhaseCoverage.state == "Unknown")
assert(report.attempts[1].coarseHostStages.intervals[1].durationSeconds == 8 and report.attempts[1].detailedHostPhases.state == "Unknown")
local stageLedger, stageFiles = evidence(true, 0.9056)
for index, attempt in stageLedger.attempts do
	local diagnostic = "HOST_STAGES_V1 " .. serde.encode("json", { version = 1, unit = "Seconds",
		clock = "os.clock", launchId = attempt.runId, intervals = {
			{ id = "total", status = "Complete", startedSeconds = 0, finishedSeconds = 8 },
			{ id = "build", status = "Complete", startedSeconds = 1, finishedSeconds = 3 },
			{ id = "launch", status = "Complete", startedSeconds = 3, finishedSeconds = 4 },
			{ id = "studioProcess", status = "Complete", startedSeconds = 4, finishedSeconds = 6 },
			{ id = "hostTeardown", status = "Complete", startedSeconds = 6, finishedSeconds = 8 },
		} }) .. "\n"
	attempt.hostStages = Study.parseHostStages(diagnostic)
	attempt.stdoutPath = DIRECTORY .. string.format("/attempt-%03d.stdout.log", index)
	stageFiles[attempt.stdoutPath] = diagnostic
end
local stageReport = evaluate(stageLedger, stageFiles)
assert(stageReport.hostPhaseCoverage.state == "Partial" and stageReport.attempts[1].detailedHostPhases.state == "Partial"
	and stageReport.attempts[1].hostStages.intervals[2].durationSeconds == 2
	and string.find(Report.render(stageReport), "Host diagnostic seconds", 1, true) ~= nil,
	"validated host stages were not reported without inventing missing phases")
local wrongStageLog = stageFiles[stageLedger.attempts[1].stdoutPath]
stageFiles[stageLedger.attempts[1].stdoutPath] = string.gsub(wrongStageLog, '"launchId":"[^"]+"',
	'"launchId":"00112233-4455-4677-8899-000000009999"')
reject("BCAST_REPORT_E_HOST_STAGES", function() evaluate(stageLedger, stageFiles) end)
stageFiles[stageLedger.attempts[1].stdoutPath] = wrongStageLog
local partialDiagnostic = "HOST_STAGES_V1 " .. serde.encode("json", { version = 1, unit = "Seconds",
	clock = "os.clock", launchId = stageLedger.attempts[1].runId,
	intervals = { { id = "total", status = "Complete", startedSeconds = 0, finishedSeconds = 8 } } }) .. "\n"
stageLedger.attempts[1].hostStages = Study.parseHostStages(partialDiagnostic)
stageFiles[stageLedger.attempts[1].stdoutPath] = partialDiagnostic
local partialReport = evaluate(stageLedger, stageFiles)
assert(partialReport.hostPhaseCoverage.state == "Unknown"
	and partialReport.attempts[1].detailedHostPhases.state == "Unknown"
	and partialReport.attempts[1].hostStages.intervals[1].durationSeconds == 8,
	"total-only diagnostic fabricated missing build/launch/process/teardown phases")
for _, comparison in report.comparisons do
	if comparison.driftChecked then
		near(comparison.control.relativeDifference, -0.0944)
		near(comparison.control.absoluteDifference, -9.44)
		near(comparison.candidate.relativeDifference, -0.2)
		near(comparison.candidateVsControl.relativeDifference, 80 / 90.56 - 1)
		assert(comparison.control.withinThreshold == false)
	elseif comparison.metricId == "engineDataSendRate" or comparison.metricId == "preTransportSize" or comparison.metricId == "positiveGc" then
		assert(comparison.control.state == "Unknown")
	else near(comparison.control.relativeDifference, -0.0944) end
end
assert(report.attempts[1].metrics.engineDataSendRate.state == "Unavailable"
	and report.attempts[1].metrics.engineDataSendRate.missingness == "UnavailableInEnvironment")
assert(report.attempts[1].metrics.submitCallDuration.unit == "microsecondsPerEvent"
	and report.attempts[1].metrics.submitCallDuration.denominator == "per event"
	and report.attempts[1].metrics.drainDuration.clockOrSource == "Workspace:GetServerTimeNow"
	and report.attempts[1].metrics.frameTime.sampleUnit == "one sender frame interval")
local rendered = Report.render(report)
assert(string.find(rendered, "-9.440%", 1, true) and string.find(rendered, "SuppliedAtReporting", 1, true)
	and string.find(rendered, "no speed winner or confidence interval", 1, true)
	and string.find(rendered, "Performance inference is inconclusive", 1, true))

local plainLedger, plainFiles = evidence(false, 1, true)
local plain = evaluate(plainLedger, plainFiles, 0)
assert(plain.controlAssessment == "WithinThreshold" and plain.independentLaunches.total == 6)

-- Version 1 remains readable; version 2 binds every completed attempt to the
-- prelaunch source/tool/plan identity before any comparison is reported.
local manifestLedger, manifestFiles = evidence(false, 1, true)
manifestLedger.version = 2
local pinned = "sha256:" .. string.rep("a", 64)
local chain = { lune = pinned, rojo = pinned,
	sha256 = Fingerprint.digest({ lune = pinned, rojo = pinned }, serde.hash, "RelayStudyTools:1") }
local tools = { baseline = chain,
	sha256 = Fingerprint.digest({ baseline = chain.sha256, candidate = "none" }, serde.hash, "RelayStudyAllTools:1") }
local studyPlan = Study.plan({ baseline = manifestLedger.sources.baseline.root,
	candidate = nil, studio = manifestLedger.studio.path, recipients = 1 })
local planSha256 = Fingerprint.digest({ bytes = serde.encode("json", studyPlan) }, serde.hash, "RelayStudyPlan:1")
manifestLedger.inputManifest = { version = 1, baseline = { files = 1, sha256 = pinned },
	tools = tools, planSha256 = planSha256, studioSha256 = manifestLedger.studio.sha256,
	sha256 = Fingerprint.digest({ baseline = pinned, baselineFiles = "1", candidate = "none", candidateFiles = "none",
		tools = tools.sha256,
		plan = planSha256, studio = manifestLedger.studio.sha256 }, serde.hash, "RelayStudyInputManifest:1") }
for _, attempt in manifestLedger.attempts do
	attempt.inputManifestSha256 = manifestLedger.inputManifest.sha256
end
assert(evaluate(manifestLedger, manifestFiles, 0).independentLaunches.total == 6,
	"version 2 manifest-bearing ledger was rejected")

local capacityFiles = clone(manifestFiles)
local capacityRoot = clone(manifestLedger)
capacityRoot.finishedUtc = nil
capacityRoot.attempts = {}
local parentPath = "E:/baseline/.tmp/broadcast-study-0000000000000001/ledger.json"
local parentBytes = serde.encode("json", capacityRoot)
capacityFiles[parentPath] = parentBytes
for level = 2, 8 do
	local collectionId = "broadcast-study-" .. string.format("%016x", level)
	local nextPath = "E:/baseline/.tmp/" .. collectionId .. "/ledger.json"
	local parent = clone(manifestLedger)
	parent.version = 3
	parent.finishedUtc = nil
	parent.attempts = {}
	parent.collectionId = collectionId
	parent.restartOf = { path = parentPath, sha256 = hash(parentBytes),
		inputManifestSha256 = parent.inputManifest.sha256 }
	parentBytes = serde.encode("json", parent)
	capacityFiles[nextPath] = parentBytes
	parentPath = nextPath
end
local capacityLedger = clone(manifestLedger)
capacityLedger.version = 3
capacityLedger.collectionId = "broadcast-study-report-fixture"
capacityLedger.restartOf = { path = parentPath, sha256 = hash(parentBytes),
	inputManifestSha256 = capacityLedger.inputManifest.sha256 }
reject("BCAST_REPORT_E_RESTART", function()
	evaluate(capacityLedger, capacityFiles, 0)
end)

local alteredManifest = clone(manifestLedger)
alteredManifest.attempts[2].inputManifestSha256 = pinned
reject("BCAST_REPORT_E_INPUT", function() evaluate(alteredManifest, manifestFiles, 0) end)
local alteredPlan = clone(manifestLedger)
alteredPlan.inputManifest.planSha256 = pinned
reject("BCAST_REPORT_E_INPUT", function() evaluate(alteredPlan, manifestFiles, 0) end)
near(plain.attempts[1].metrics.frameTime.summary.median, 60.5)
near(plain.attempts[1].metrics.frameTime.summary.p95, 114)
for _, comparison in plain.comparisons do assert(comparison.candidate.state == "Unknown" and comparison.candidate.reason == "no-candidate") end

local uncLedger, uncFiles = uncEvidence(true)
local uncReport = evaluateUnc(uncLedger, uncFiles)
assert(uncReport.ledger.path == "//server/share/broadcast/ledger.json"
	and uncReport.attempts[1].archive.path == "//server/share/broadcast/raw/attempt-001-1-00112233-4455-4677-8899-000000000001.result-v2.json",
	"UNC ledger and archive paths must normalize backslashes and retain their share roots")
local outsideUncLedger, outsideUncFiles = uncEvidence(true)
outsideUncLedger.attempts[1].rawResult[1].path = "\\\\server\\share\\broadcast\\raw\\..\\outside.json"
reject("BCAST_REPORT_E_ARCHIVE", function() evaluateUnc(outsideUncLedger, outsideUncFiles) end)

local permissive = evaluate(ledger, files, 0.1)
assert(permissive.controlAssessment == "WithinThreshold" and permissive.rankingEligible == false)
local roundedLedger, roundedFiles = evidence(false)
roundedLedger.attempts[3].summaries.drainDuration.p95 = 100 + math.ldexp(1, -46)
-- The pinned JSON decoder rounds decimal 100.00000000000001 to 100.
-- Decimal ...002 produces the exact adjacent binary64 value for this oracle.
local roundedText = serde.encode("json", roundedLedger):gsub("100%.00000000000001", "100.00000000000002")
local rounded = evaluate(roundedLedger, roundedFiles, nil, roundedText)
assert(#rounded.attempts[3].ledgerSummaryRounding == 1 and rounded.attempts[3].metrics.drainDuration.summary.p95 == 100,
	"adjacent ledger rounding supplied authoritative metric values")
assert(rounded.attempts[3].ledgerSummaryRounding[1].reason == "adjacent-binary64-rounding")

local function drainReference(reference: number): (any, any)
	local value, rawFiles = evidence(false)
	alterResult(value, rawFiles, 3, function(result)
		for _, measurement in result.measurements do
			if measurement.metadata.id ~= "drainDuration" then continue end
			for _, group in measurement.rawSamples do for index in group.values do group.values[index] = reference end end
			measurement.summary = fixtureSummary(measurement)
		end
	end)
	value.attempts[3].summaries.drainDuration = { kind = "MedianAndP95", sampleCount = 30, median = reference, p95 = reference }
	return value, rawFiles
end
local zeroLedger, zeroFiles = drainReference(0)
zeroLedger.attempts[3].summaries.drainDuration.p95 = 1e-17
reject("BCAST_REPORT_E_SUMMARY", function() evaluate(zeroLedger, zeroFiles) end)
zeroLedger.attempts[3].summaries.drainDuration.p95 = math.ldexp(1, -1074)
assert(#evaluate(zeroLedger, zeroFiles).attempts[3].ledgerSummaryRounding == 1, "minimum subnormal was not adjacent to zero")
zeroLedger.attempts[3].summaries.drainDuration.p95 = math.ldexp(1, -1073)
reject("BCAST_REPORT_E_SUMMARY", function() evaluate(zeroLedger, zeroFiles) end)
local powerLedger, powerFiles = drainReference(128)
powerLedger.attempts[3].summaries.drainDuration.p95 = 128 - math.ldexp(1, -46)
local powerText = serde.encode("json", powerLedger):gsub("127%.99999999999999", "127.99999999999998")
assert(#evaluate(powerLedger, powerFiles, nil, powerText).attempts[3].ledgerSummaryRounding == 1, "power-of-two downward spacing was wrong")
powerLedger.attempts[3].summaries.drainDuration.p95 = 128 - 2 * math.ldexp(1, -46)
reject("BCAST_REPORT_E_SUMMARY", function() evaluate(powerLedger, powerFiles) end)

local function invalid(code: string, change: any)
	local changed, changedFiles = evidence(true)
	change(changed, changedFiles)
	reject(code, function() evaluate(changed, changedFiles) end)
end
invalid("BCAST_REPORT_E_INCOMPLETE", function(value) value.finishedUtc = nil end)
invalid("BCAST_REPORT_E_SCHEDULE", function(value) table.remove(value.attempts) end)
invalid("BCAST_REPORT_E_SCHEDULE", function(value) value.schedule[1], value.schedule[2] = value.schedule[2], value.schedule[1] end)
invalid("BCAST_REPORT_E_INCOMPLETE", function(value) value.attempts[3].valid = false end)
invalid("BCAST_REPORT_E_INCOMPLETE", function(value) value.attempts[3].stdoutTruncated = true end)
invalid("BCAST_REPORT_E_HASH", function(value, rawFiles)
	local raw = value.attempts[2].rawResult[1]
	rawFiles[raw.path] = string.gsub(rawFiles[raw.path], '"Test CPU"', '"Fake CPU"')
end)
invalid("BCAST_REPORT_E_ARCHIVE", function(value) value.attempts[2].rawResult[1].size += 1 end)
invalid("BCAST_REPORT_E_ARCHIVE", function(value) value.attempts[2].rawResult[1].path = DIRECTORY .. "/../outside.json" end)
invalid("BCAST_REPORT_E_ARCHIVE", function(value)
	value.attempts[2].resultPath = "E:/outside/benchmarks/results/local/" .. value.attempts[2].runId .. ".result-v2.json"
	value.attempts[2].rawResult[1].sourcePath = value.attempts[2].resultPath
end)
invalid("BCAST_REPORT_E_SUMMARY", function(value) value.attempts[2].summaries.frameTime.median = 1 end)
invalid("BCAST_REPORT_E_SUMMARY", function(value) value.attempts[3].summaries.drainDuration.p95 = 100 + 2 * math.ldexp(1, -46) end)
invalid("BCAST_REPORT_E_SUMMARY", function(value) value.attempts[3].summaries.drainDuration.sampleCount += 1 end)
invalid("BCAST_E_INCOMPATIBLE", function(value, rawFiles)
	alterResult(value, rawFiles, 3, function(result) result.environment.host.architecture = "arm64" end)
end)
invalid("BCAST_E_INCOMPATIBLE", function(value, rawFiles)
	alterResult(value, rawFiles, 3, function(result) result.benchmark.source.measurementFingerprint = "sha256:" .. string.rep("8", 64) end)
end)
invalid("BCAST_REPORT_E_ADAPTER", function(value, rawFiles)
	alterResult(value, rawFiles, 3, function(result) result.benchmark.source.adapterFingerprint = "sha256:" .. string.rep("8", 64) end)
end)
invalid("BCAST_REPORT_E_ADAPTER", function(value, rawFiles)
	alterResult(value, rawFiles, 5, function(result) result.benchmark.source.adapterFingerprint = "sha256:" .. string.rep("8", 64) end)
end)
invalid("BCAST_E_SOURCE_CHANGED", function(value, rawFiles)
	alterResult(value, rawFiles, 2, function(result)
		result.benchmark.source.revision = string.rep("8", 40)
		result.adapter.library.provenance.revision = result.benchmark.source.revision
	end)
end)
invalid("BCAST_E_DUPLICATE_RUN_ID", function(value, rawFiles)
	local attempt = value.attempts[3]
	alterResult(value, rawFiles, 3, function(result) result.runId = value.attempts[2].runId end)
	local oldPath = attempt.rawResult[1].path
	attempt.runId = value.attempts[2].runId
	attempt.resultPath = "E:/baseline/benchmarks/results/local/" .. attempt.runId .. ".result-v2.json"
	attempt.rawResult[1].sourcePath = attempt.resultPath
	attempt.rawResult[1].path = DIRECTORY .. "/raw/attempt-003-1-" .. attempt.runId .. ".result-v2.json"
	rawFiles[attempt.rawResult[1].path] = rawFiles[oldPath]
end)

-- Real CLI integration proves that report output is new-only and the inputs
-- stay byte-identical. It invokes no Studio or performance harness.
local cliRoot = ".tmp/broadcast-report-cli-" .. string.sub(serde.hash("sha256", tostring({}) .. tostring(os.clock())), 1, 16)
assert(not fs.metadata(cliRoot).exists, "CLI test output root already exists")
fs.writeDir(cliRoot .. "/raw")
local cliLedger = clone(plainLedger)
local actualRoot = ROOT .. "/" .. cliRoot
for _, attempt in cliLedger.attempts do
	local previous = attempt.rawResult[1].path
	local name = string.match(previous, "([^/]+)$")
	attempt.rawResult[1].path = actualRoot .. "/raw/" .. name
	fs.writeFile(attempt.rawResult[1].path, plainFiles[previous])
end
local input = actualRoot .. "/ledger.json"
local output = actualRoot .. "/report.json"
local inputBytes = serde.encode("json", cliLedger)
fs.writeFile(input, inputBytes)
local command = { "run", "benchmarks/reporting/report-broadcast-study.luau", "--ledger", input,
	"--maximum-control-drift", "0", "--output", output }
local first = process.exec("lune", command)
assert(first.ok, first.stderr)
local outputBytes = fs.readFile(output)
local second = process.exec("lune", command)
assert(not second.ok and fs.readFile(output) == outputBytes and fs.readFile(input) == inputBytes,
	"CLI overwrote evidence or its prior report")
assert(string.find(second.stderr, "BCAST_REPORT_E_OUTPUT_EXISTS_OR_MOVE_FAILED", 1, true),
	"existing output did not reach the native no-replacement move")
local directoryOutput = actualRoot .. "/directory-output"
fs.writeDir(directoryOutput)
command[#command] = directoryOutput
assert(not process.exec("lune", command).ok and #fs.readDir(directoryOutput) == 0,
	"CLI published into an existing directory")
local raceOutput = actualRoot .. "/race.json"
command[#command] = raceOutput
local raced = {}
for index = 1, 2 do task.spawn(function() raced[index] = process.exec("lune", command) end) end
while raced[1] == nil or raced[2] == nil do task.wait(0.01) end
assert(raced[1].ok ~= raced[2].ok and fs.isFile(raceOutput), "concurrent publishers did not retain exactly one output")
local retained = serde.decode("json", fs.readFile(raceOutput))
assert(retained.ledger.sha256 == hash(inputBytes) and retained.rankingEligible == false and fs.readFile(input) == inputBytes,
	"concurrent output publication altered evidence or retained a partial report")
fs.removeDir(cliRoot)
print("PASS Relay.Benchmarks.BroadcastStudyReport")
