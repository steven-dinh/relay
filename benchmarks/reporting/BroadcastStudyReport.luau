--!strict

-- Offline diagnostics only. Reuse canonical validators and archived bytes;
-- collection summaries and a caller-selected threshold are not performance proof.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Study = require("../host/BroadcastStudy")
local StudyInputManifest = require("../host/StudyInputManifest")
local Fingerprint = require("../host/MeasurementFingerprint")
local ResultV2 = require("../contracts/result-v2")
local Contract = require("../contracts/event-v1")

local DRIFT_METRICS = { "submitCallDuration", "frameTime", "drainDuration", "completionDuration" }
local MAX_LEDGER_BYTES = 1_048_576

local function check(condition: any, code: string)
	assert(condition, "BCAST_REPORT_E_" .. code)
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function path(value: string): string
	check(type(value) == "string" and #value > 0, "PATH")
	local normalized = string.gsub(value, "\\", "/")
	check(not string.find(normalized, "[\0\r\n]"), "PATH")
	local prefix = string.match(normalized, "^%a:/")
		or (if string.sub(normalized, 1, 2) == "//" then "//"
			elseif string.sub(normalized, 1, 1) == "/" then "/" else "")
	local parts = {}
	for part in string.gmatch(string.sub(normalized, #prefix + 1), "[^/]+") do
		if part == ".." then check(#parts > 0, "PATH"); table.remove(parts)
		elseif part ~= "." then table.insert(parts, part) end
	end
	return prefix .. table.concat(parts, "/")
end

local function absolute(value: string): string
	local normalized = path(value)
	if string.match(normalized, "^%a:/") or string.sub(normalized, 1, 1) == "/" then return normalized end
	return path(process.cwd .. "/" .. normalized)
end

local function samePath(left: string, right: string): boolean
	local a, b = path(left), path(right)
	return if process.os == "windows" then string.lower(a) == string.lower(b) else a == b
end

local function digest(body: string): string
	return "sha256:" .. serde.hash("sha256", body)
end

local function fingerprint(value: any): boolean
	return type(value) == "string" and #value == 71 and string.match(value, "^sha256:[0-9a-f]+$") ~= nil
end

local function revision(value: any): boolean
	return type(value) == "string" and (#value == 40 or #value == 64) and string.match(value, "^[0-9a-f]+$") ~= nil
end

local function array(value: any, count: number)
	check(type(value) == "table" and #value == count, "SCHEDULE")
	local actual = 0
	for key in value do check(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= count, "SCHEDULE"); actual += 1 end
	check(actual == count, "SCHEDULE")
end

local function summaryAgreement(left: any, right: any): any
	local ok, differences = pcall(Study.summaryAgreement, left, right)
	check(ok, "SUMMARY")
	return differences
end

local function readJson(reader: any, filename: string, limit: number): (any, string)
	local ok, body = pcall(reader, filename)
	check(ok and type(body) == "string" and #body > 0 and #body <= limit, "READ")
	local decoded, value = pcall(serde.decode, "json", body)
	check(decoded and type(value) == "table", "JSON")
	return value, body
end

local function delta(left: any, right: any, statistic: string): any
	local baseline = if left ~= nil and left.state == "Available" and left.summary ~= nil then left.summary[statistic] else nil
	local observation = if right ~= nil and right.state == "Available" and right.summary ~= nil then right.summary[statistic] else nil
	if not finite(baseline) or not finite(observation) then return { state = "Unknown", reason = "metric-unavailable" } end
	if baseline == 0 then
		return { state = "Unknown", reason = "zero-baseline-denominator", baseline = baseline, observation = observation,
			absoluteDifference = observation - baseline }
	end
	local difference = observation - baseline
	local relative = difference / baseline
	if not finite(difference) or not finite(relative) then return { state = "Unknown", reason = "nonfinite-difference" } end
	return { state = "Available", baseline = baseline, observation = observation,
		absoluteDifference = difference, relativeDifference = relative }
end

local function sampleUnit(id: string, cadence: string): string
	if id == "frameTime" then return "one sender frame interval" end
	if id == "engineDataSendRate" then return "engine-wide rate at one sender frame boundary" end
	if id == "positiveGc" then return "one measured-window estimate per event" end
	if cadence == "PerSubmission" then return "one public submit/broadcast call" end
	return "one logical measured window"
end

local function hasHostBoundaries(stages: any?): boolean
	if stages == nil then return false end
	local found = {}
	for _, interval in stages.intervals do
		if interval.status == "Complete" and type(interval.durationSeconds) == "number" then
			found[interval.id] = true
		end
	end
	return found.total == true and found.build == true and found.launch == true
		and found.studioProcess == true and found.hostTeardown == true
end

local function report(ledgerPath: string, maximumControlDrift: number, reader: any?): any
	check(finite(maximumControlDrift) and maximumControlDrift >= 0, "THRESHOLD")
	local read = reader or fs.readFile
	local filename = absolute(ledgerPath)
	local directory = string.match(filename, "^(.*)/[^/]+$")
	check(directory ~= nil, "PATH")
	local ledger, ledgerBytes = readJson(read, filename, MAX_LEDGER_BYTES)
	check(ledger.schema == "Relay.BroadcastStudyLedger"
		and (ledger.version == 1 or ledger.version == 2 or ledger.version == 3), "LEDGER")
	check(type(ledger.startedUtc) == "string" and #ledger.startedUtc > 0
		and type(ledger.finishedUtc) == "string" and #ledger.finishedUtc > 0, "INCOMPLETE")
	check(type(ledger.topology) == "table" and ledger.topology.mode == "PersistentBenchmark"
		and ledger.topology.caseId == "state-broadcast-s2c"
		and (ledger.topology.recipients == 1 or ledger.topology.recipients == 4 or ledger.topology.recipients == 8), "TOPOLOGY")
	check(type(ledger.studio) == "table" and fingerprint(ledger.studio.sha256)
		and finite(ledger.studio.size) and ledger.studio.size > 0 and type(ledger.studio.path) == "string", "STUDIO")
	check(type(ledger.sources) == "table" and type(ledger.sources.baseline) == "table", "SOURCE")
	for key, source in ledger.sources do
		check(key == "baseline" or key == "candidate", "SOURCE")
		check(type(source) == "table" and revision(source.revision) and type(source.root) == "string"
			and absolute(source.root) == source.root, "SOURCE")
	end
	local baseline = ledger.sources.baseline
	local candidate = ledger.sources.candidate
	check(candidate == nil or not samePath(candidate.root, baseline.root), "SOURCE")
	if ledger.version >= 2 then
		local manifest = ledger.inputManifest
		local manifestOk, validManifest = pcall(StudyInputManifest.verify, manifest, serde.hash)
		check(manifestOk and validManifest == true
			and manifest.studioSha256 == ledger.studio.sha256
			and (manifest.candidate ~= nil) == (candidate ~= nil), "INPUT")
		local expectedPlan = Study.plan({ baseline = baseline.root, candidate = if candidate == nil then nil else candidate.root,
			studio = ledger.studio.path, recipients = ledger.topology.recipients })
		local expectedPlanHash = Fingerprint.digest({ bytes = serde.encode("json", expectedPlan) },
			serde.hash, "RelayStudyPlan:1")
		check(manifest.planSha256 == expectedPlanHash, "INPUT")
	end
	local previous = nil
	if ledger.version == 3 then
		local restart = ledger.restartOf
		check(type(ledger.collectionId) == "string" and ledger.collectionId == string.match(directory, "([^/]+)$")
			and type(restart) == "table" and type(restart.path) == "string"
			and fingerprint(restart.sha256) and restart.inputManifestSha256 == ledger.inputManifest.sha256,
			"RESTART")
		local priorPath = Study.restartLedgerPath(restart.path, baseline.root, process.os)
		check(not samePath(priorPath, filename), "RESTART")
		local dependencies: any = { verifyCurrent = false }
		if reader ~= nil then
			dependencies.readFile = read
			dependencies.fileSize = function(priorFile: string): number return #read(priorFile) end
		end
		local RecoveryAudit = require("../host/BroadcastRecoveryAudit")
		previous = RecoveryAudit.audit(priorPath, dependencies, restart.sha256)
		check(previous.status == "FreshFullStudyRequired" and previous.selection == "none"
			and previous.lineageLength + 1 <= RecoveryAudit.MAX_LINEAGE_LENGTH
			and previous.ledgerSha256 == restart.sha256
			and previous.inputManifestSha256 == ledger.inputManifest.sha256
			and samePath(previous.sources.baseline.root, baseline.root)
			and previous.sources.baseline.revision == baseline.revision
			and (candidate == nil and previous.sources.candidate == nil
				or candidate ~= nil and previous.sources.candidate ~= nil
				and samePath(previous.sources.candidate.root, candidate.root)
				and previous.sources.candidate.revision == candidate.revision), "RESTART")
		for _, prior in previous.previousAttempts do
			check(prior.state ~= "Interrupted", "RESTART_OWNERSHIP")
		end
	else
		check(ledger.collectionId == nil and ledger.restartOf == nil, "RESTART")
	end
	local schedule = Study.schedule({ baseline = baseline.root, candidate = if candidate == nil then nil else candidate.root })
	array(ledger.schedule, #schedule)
	array(ledger.attempts, #schedule)
	local attempts, passes, seenIds, fingerprints = {}, { [1] = {}, [2] = {} }, {}, {}
	if previous ~= nil then
		for _, prior in previous.previousAttempts do
			for _, archive in prior.archives do seenIds[string.lower(archive.runId)] = true end
		end
	end
	local commonKey = nil
	for index, expected in schedule do
		local scheduled, attempt = ledger.schedule[index], ledger.attempts[index]
		check(type(scheduled) == "table" and type(attempt) == "table", "SCHEDULE")
		for key, value in expected do check(scheduled[key] == value and attempt[key] == value, "SCHEDULE") end
		check(scheduled.index == index and attempt.index == index, "SCHEDULE")
		if ledger.version >= 2 then
			check(attempt.inputManifestSha256 == ledger.inputManifest.sha256, "INPUT")
		end
		check(attempt.valid == true and attempt.failure == nil and attempt.exitCode == 0
			and attempt.stdoutTruncated == false and attempt.stderrTruncated == false
			and type(attempt.finishedUtc) == "string" and attempt.addedResults == 1, "INCOMPLETE")
		array(attempt.rawResult, 1)
		local raw = attempt.rawResult[1]
		check(type(raw) == "table" and fingerprint(raw.sha256) and finite(raw.size)
			and raw.size > 0 and raw.size <= ResultV2.MAX_JSON_BYTES, "ARCHIVE")
		check(type(attempt.runId) == "string" and type(attempt.resultPath) == "string" and type(raw.path) == "string", "ARCHIVE")
		local rawPath = string.gsub(raw.path, "\\", "/")
		local archivePath = path(if string.match(rawPath, "^%a:/") or string.sub(rawPath, 1, 1) == "/"
			then rawPath else directory .. "/" .. rawPath)
		local archiveName = string.format("attempt-%03d-1-%s.result-v2.json", index, string.lower(attempt.runId))
		local originalPath = expected.root .. "/" .. Study.RESULT_DIRECTORY .. "/" .. string.lower(attempt.runId) .. ".result-v2.json"
		check(type(raw.sourcePath) == "string" and samePath(attempt.resultPath, originalPath)
			and samePath(archivePath, directory .. "/raw/" .. archiveName) and samePath(raw.sourcePath, attempt.resultPath)
			and raw.size == attempt.resultSize and raw.sha256 == attempt.resultSha256, "ARCHIVE")
		local decoded, bytes = readJson(read, archivePath, ResultV2.MAX_JSON_BYTES)
		check(#bytes == raw.size, "HASH")
		local archiveSha256 = digest(bytes)
		check(archiveSha256 == raw.sha256, "HASH")
		local source = if expected.root == baseline.root then baseline else candidate
		local checked = Study.validateResult(decoded, { recipients = ledger.topology.recipients, revision = source.revision },
			attempt.resultPath, expected, seenIds, commonKey)
		if commonKey == nil then commonKey = checked.compatibilityKey end
		check(attempt.runId == checked.result.runId and attempt.sourceRevision == checked.source.revision
			and attempt.measurementFingerprint == checked.source.measurementFingerprint
			and attempt.contractFingerprint == checked.result.contract.fingerprint, "PROVENANCE")
		local role = if expected.label == "control" then "baseline" else expected.label
		local prior = fingerprints[role]
		check(prior == nil or prior == checked.source.adapterFingerprint, "ADAPTER")
		fingerprints[role] = checked.source.adapterFingerprint
		check(type(attempt.summaries) == "table", "SUMMARY")
		local rounding = {}
		for id, summary in checked.summaries do
			for _, difference in summaryAgreement(attempt.summaries[id], summary) do
				difference.metricId = id
				table.insert(rounding, difference)
			end
		end
		for id in attempt.summaries do check(checked.summaries[id] ~= nil, "SUMMARY") end
		local hostStages = nil
		if attempt.hostStages ~= nil then
			check(type(attempt.stdoutPath) == "string", "HOST_STAGES")
			local stdoutPath = path(attempt.stdoutPath)
			check(samePath(stdoutPath, directory .. string.format("/attempt-%03d.stdout.log", index)), "HOST_STAGES")
			local stdout = read(stdoutPath)
			check(type(stdout) == "string" and #stdout <= Study.PROCESS_OUTPUT_MAX_BYTES, "HOST_STAGES")
			hostStages = Study.parseHostStages(stdout)
			check(hostStages ~= nil and hostStages.launchId == attempt.runId, "HOST_STAGES")
		end
		local metrics = {}
		for _, measurement in checked.result.measurements do
			local metadata = measurement.metadata
			metrics[metadata.id] = { state = measurement.state, summary = measurement.summary,
				missingness = if measurement.state == "Unavailable" then measurement.unavailableReason.code else nil,
				unit = metadata.unit, sampleUnit = sampleUnit(metadata.id, metadata.capture.cadence),
				sampleCadence = metadata.capture.cadence, clockOrSource = metadata.capture.source,
				scope = metadata.scope, participantScope = metadata.capture.role, quality = metadata.capture.quality,
				timing = metadata.timing, estimator = if metadata.summary == "Exact" then "sum of retained samples"
					else "empirical median; nearest-rank p95 (ceil(0.95 * sample count))",
				denominator = if metadata.unit == "microsecondsPerEvent" or metadata.unit == "bytesPerEvent" then "per event"
					elseif metadata.unit == "kilobytesPerSecond" then "per second (engine-wide)" else "per sample",
				independentLaunches = 1 }
		end
		local row = { index = index, pass = expected.pass, order = expected.order, label = expected.label,
			runId = checked.result.runId, archive = { path = archivePath, size = #bytes, sha256 = archiveSha256 },
			source = checked.source, environment = checked.result.environment, contractFingerprint = checked.result.contract.fingerprint,
			verifiedSubmissions = checked.result.counts.submitted, verifiedDeliveries = checked.result.counts.correct,
			windows = checked.result.case.completedRepetitions, metrics = metrics, ledgerSummaryRounding = rounding,
			coarseHostStages = attempt.coarseHostStages, hostStages = hostStages,
			detailedHostPhases = if hasHostBoundaries(hostStages) then
				{ state = "Partial", reason = "host build/launch/process/teardown observed; Studio readiness, collection and drain unavailable" }
				else { state = "Unknown", reason = "one or more host boundaries missing or unavailable" } }
		table.insert(attempts, row)
		passes[expected.pass][expected.label] = row
	end
	local comparisons, exceeded, unknown = {}, false, false
	for pass = 1, 2 do
		local rows = passes[pass]
		for _, metadata in Contract.measurements do
			if metadata.scope ~= "Workload" or metadata.summary ~= "MedianAndP95" then continue end
			local required = table.find(DRIFT_METRICS, metadata.id) ~= nil
			for _, statistic in { "median", "p95" } do
				local control = delta(rows.baseline.metrics[metadata.id], rows.control.metrics[metadata.id], statistic)
				if required then
					if control.state == "Unknown" then unknown = true
					else control.withinThreshold = math.abs(control.relativeDifference) <= maximumControlDrift
						if not control.withinThreshold then exceeded = true end
					end
				end
				table.insert(comparisons, { pass = pass, order = if pass == 1 then "forward" else "reverse",
					metricId = metadata.id, statistic = statistic, unit = metadata.unit, driftChecked = required,
					control = control, candidate = if rows.candidate == nil then { state = "Unknown", reason = "no-candidate" }
						else delta(rows.baseline.metrics[metadata.id], rows.candidate.metrics[metadata.id], statistic),
					candidateVsControl = if rows.candidate == nil then { state = "Unknown", reason = "no-candidate" }
						else delta(rows.control.metrics[metadata.id], rows.candidate.metrics[metadata.id], statistic) })
			end
		end
	end
	local completeHostDiagnostics = true
	for _, attempt in attempts do
		if attempt.detailedHostPhases.state ~= "Partial" then completeHostDiagnostics = false; break end
	end
	return { schema = "Relay.BroadcastStudyReport", version = 1, rankingEligible = false,
		ledger = { path = filename, sha256 = digest(ledgerBytes), size = #ledgerBytes }, topology = ledger.topology,
		collection = if previous == nil then nil else { id = ledger.collectionId,
			restartOf = ledger.restartOf, previousAttempts = previous.previousAttempts,
			selection = "FreshCollectionOnly" },
		studioExecutable = ledger.studio, attempts = attempts, comparisons = comparisons,
		hostPhaseCoverage = if completeHostDiagnostics then { state = "Partial", reason = "host boundaries do not isolate Studio workload phases" }
			else { state = "Unknown", reason = "one or more attempts lack validated host-stage diagnostics" },
		controlAssessment = if exceeded then "DriftExceeded" elseif unknown then "Unknown" else "WithinThreshold",
		driftPolicy = { maximumAbsoluteRelativeDifference = maximumControlDrift, denominator = "baseline statistic (candidateVsControl uses control statistic)",
			metrics = DRIFT_METRICS, statistics = { "median", "p95" }, declaration = "SuppliedAtReporting; predeclaration is not established by this ledger" },
		independentLaunches = { total = #attempts, forward = #attempts / 2, reverse = #attempts / 2,
			perRolePerOrder = 1, perRoleAcrossOrders = 2 },
		limitations = { "Diagnostic evidence only; no speed winner or confidence interval.",
			"Within-session windows and samples are correlated; they are not independent launches.",
			"Two ordered launches per role do not establish repeatable performance gains.",
			"Engine-wide rates and pre-transport sizes do not establish attributable physical wire bytes.",
			"CPU/profile/packet capture qualification is not established by Result V2 or this ledger." } }
end

local function cell(value: any): string
	return (string.gsub(tostring(value), "[|\r\n]", " "))
end

local function difference(value: any): string
	return if value.state == "Unknown" then "Unknown: " .. value.reason else string.format("%+.3f%%", value.relativeDifference * 100)
end

local function hostSeconds(stages: any?, id: string): string
	if stages == nil then return "Unknown" end
	for _, interval in stages.intervals do
		if interval.id == id then
			return if type(interval.durationSeconds) == "number" then string.format("%.3f", interval.durationSeconds)
				else "Unknown"
		end
	end
	return "Unknown"
end

local function render(value: any): string
	local lines = { "Relay broadcast study diagnostics", "", "Control assessment: " .. value.controlAssessment
		.. string.format(" (explicit threshold %.3f%%).", value.driftPolicy.maximumAbsoluteRelativeDifference * 100),
		value.driftPolicy.declaration .. ".", "", string.format("Independent launches: %d total; %d forward, %d reverse; one per role per order.",
			value.independentLaunches.total, value.independentLaunches.forward, value.independentLaunches.reverse), "" }
	if value.controlAssessment ~= "WithinThreshold" then table.insert(lines, "Performance inference is inconclusive: controls exceeded the configured threshold or a comparison is unknown.") end
	for _, limitation in value.limitations do table.insert(lines, limitation) end
	table.insert(lines, "\n| Order | Metric | Statistic | Unit | Control vs baseline | Candidate vs baseline | Candidate vs control | Drift checked |")
	table.insert(lines, "| --- | --- | --- | --- | --- | --- | --- | --- |")
	for _, comparison in value.comparisons do
		table.insert(lines, string.format("| %s | %s | %s | %s | %s | %s | %s | %s |", comparison.order, comparison.metricId,
			comparison.statistic, comparison.unit, difference(comparison.control), difference(comparison.candidate),
			difference(comparison.candidateVsControl), tostring(comparison.driftChecked)))
	end
	table.insert(lines, "\n| Order | Role | Run ID | Revision | Harness | Studio | Host | Verified deliveries | Windows |")
	table.insert(lines, "| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for _, attempt in value.attempts do
		table.insert(lines, string.format("| %s | %s | %s | %s | %s | %s | %s | %d | %d |", attempt.order, attempt.label,
			attempt.runId, attempt.source.revision, attempt.source.measurementFingerprint, cell(attempt.environment.studio.version),
			cell(attempt.environment.host.cpuModel or "Unknown"), attempt.verifiedDeliveries, attempt.windows))
	end
	table.insert(lines, "\nHost diagnostic seconds. Total is an overlapping envelope, not the sum of stages; Studio readiness, collection, warmup and engine drain remain unavailable.")
	table.insert(lines, "| Run ID | Total | Build helper | Launch call | Studio process | Host teardown |")
	table.insert(lines, "| --- | ---: | ---: | ---: | ---: | ---: |")
	for _, attempt in value.attempts do
		table.insert(lines, string.format("| %s | %s | %s | %s | %s | %s |", attempt.runId,
			hostSeconds(attempt.hostStages, "total"), hostSeconds(attempt.hostStages, "build"),
			hostSeconds(attempt.hostStages, "launch"), hostSeconds(attempt.hostStages, "studioProcess"),
			hostSeconds(attempt.hostStages, "hostTeardown")))
	end
	table.insert(lines, "\n| Metric | Unit | Sample unit | Clock/source | Participant scope | Estimator | Denominator |")
	table.insert(lines, "| --- | --- | --- | --- | --- | --- | --- |")
	for _, metadata in Contract.measurements do
		local metric = value.attempts[1].metrics[metadata.id]
		if metric ~= nil then
			table.insert(lines, string.format("| %s | %s | %s | %s | %s | %s | %s |", metadata.id, metric.unit,
				metric.sampleUnit, metric.clockOrSource, metric.participantScope, metric.estimator, metric.denominator))
		end
	end
	table.insert(lines, "\nComplete provenance, missingness and timing boundaries are retained in the JSON report.")
	return table.concat(lines, "\n")
end

local function parseArgs(arguments: { string }): any
	check(#arguments == 4 or #arguments == 6, "ARGS")
	local options = {}
	for index = 1, #arguments, 2 do
		local key, value = arguments[index], arguments[index + 1]
		check((key == "--ledger" or key == "--maximum-control-drift" or key == "--output")
			and options[key] == nil and type(value) == "string" and #value > 0, "ARGS")
		options[key] = value
	end
	local threshold = tonumber(options["--maximum-control-drift"])
	check(options["--ledger"] ~= nil and finite(threshold) and threshold >= 0, "ARGS")
	return { ledgerPath = options["--ledger"], maximumControlDrift = threshold,
		outputPath = if options["--output"] == nil then nil else absolute(options["--output"]) }
end

return table.freeze({ report = report, render = render, parseArgs = parseArgs })
