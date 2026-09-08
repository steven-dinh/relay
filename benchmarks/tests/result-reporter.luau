local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Contract = require("../contracts/event-v1")
local Identity = require("../contracts/internal/AdapterIdentity")
local ResultV1 = require("../contracts/result-v1")
local ResultReporter = require("../reporting/ResultReporter")
local HostRuntimeFixtures = require("./support/HostRuntimeFixtures")

local JSON_TOKEN_MAX = 131_072

local function clone(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end
	local copied = {}
	seen[value] = copied
	for key, nested in value do
		copied[clone(key, seen)] = clone(nested, seen)
	end
	return copied
end

local function occurrences(source, needle)
	local count = 0
	local cursor = 1
	while true do
		local found = string.find(source, needle, cursor, true)
		if found == nil then
			return count
		end
		count += 1
		cursor = found + #needle
	end
end

local function expectError(code, operation)
	local ok, failure = pcall(operation)
	assert(not ok, code .. " must reject")
	assert(string.find(tostring(failure), code, 1, true) ~= nil,
		string.format("%s expected, got %s", code, tostring(failure)))
end

local function runId(index)
	return string.format("%08d-0000-4000-8000-%012d", index, index)
end

local function findWorkload(workloadId)
	for _, workload in Contract.workloads do
		if workload.id == workloadId then
			return workload
		end
	end
	error("missing workload fixture", 0)
end

local function findProbe(probeId)
	for _, probe in Contract.probes do
		if probe.id == probeId then
			return probe
		end
	end
	error("missing probe fixture", 0)
end

local function adapter(options)
	local studio = options.studio or "0.650.0.6500000"
	local suffix = tostring(options.index)
	return {
		id = options.adapterId or "adapter-" .. suffix,
		displayName = options.adapterName or "Adapter " .. suffix,
		lane = options.lane or "NativeBest",
		integrationKind = "EngineBuiltIn",
		library = {
			id = "library-" .. suffix,
			displayName = options.libraryName or "Library " .. suffix,
			version = studio,
			provenance = { kind = "EngineBuiltIn", studioVersion = studio },
		},
		semantics = {
			broadcastMode = options.broadcast or "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "ProcessRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function environment(caseValue, options)
	local selection = if caseValue.kind == "SeparateProbe"
		then { kind = "SeparateProbe", probeId = caseValue.probeId }
		else {
			kind = "Workload",
			workloadId = caseValue.workloadId,
			recipientCount = caseValue.recipientCount,
		}
	local resolved = Identity.resolveSelection(selection)
	assert(resolved.kind == "Valid", "report fixture selection must resolve")
	return {
		studio = { version = options.studio or "0.650.0.6500000", channel = "production" },
		host = {
			osFamily = options.osFamily or "Windows",
			architecture = options.architecture or "x86_64",
			osVersion = options.osVersion or "fixture",
			cpuModel = options.cpuModel or "Fixture CPU",
			logicalProcessorCount = options.logicalProcessorCount or 8,
			memoryMiB = options.memoryMiB or 16_384,
			gpuModel = options.gpuModel or "Fixture GPU",
		},
		execution = {
			mode = "StudioMultiplayer",
			targetFrameRate = Contract.execution.targetFrameRate,
			serverCount = 1,
			clientCount = resolved.value.clientProcessCount,
		},
	}
end

local function conformance()
	return {
		timingExclusionsConfirmed = {
			setup = true,
			warmup = true,
			quiescence = true,
			resultExtraction = true,
		},
		localClock = clone(Contract.clocks.localDuration),
		sharedClock = clone(Contract.clocks.shared),
		clockProof = { version = 1, passed = true },
	}
end

local function selectedMeasurements(caseValue)
	local selected = {}
	for _, measurement in Contract.measurements do
		if measurement.scope == caseValue.kind
			and (caseValue.kind ~= "SeparateProbe" or measurement.probeId == caseValue.probeId)
		then
			table.insert(selected, measurement)
		end
	end
	return selected
end

local function valuesPerGroup(measurement, caseDefinition)
	local cadence = measurement.capture.cadence
	if cadence == "PerMeasuredFrame" then
		return caseDefinition.measuredFrames
	elseif cadence == "PerRepetition" then
		return 1
	elseif cadence == "PerSubmission" then
		return caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
	else
		assert(cadence == "PerProbe", "unknown report fixture cadence")
		return caseDefinition.measuredSamples
	end
end

local function measurementValue(measurement, caseValue, caseDefinition, options)
	if caseValue.kind == "Workload" then
		local submissions = caseValue.senderCount * caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
		if measurement.id == "submitted" then
			return submissions
		elseif measurement.id == "received" or measurement.id == "correct" then
			return submissions * caseValue.recipientCount
		end
	end
	if measurement.capture.ranking == "Eligible" then
		return options.median or 10
	elseif measurement.capture.ranking == "DiagnosticOnly" then
		return options.diagnostic or 1
	end
	return 1
end

local function availableMeasurements(caseValue, caseDefinition, options)
	local output = {}
	for _, measurement in selectedMeasurements(caseValue) do
		local participants = if measurement.capture.role == "Sender"
			then caseValue.senderCount
			elseif measurement.capture.role == "ProbeClient"
			then caseValue.clientCount
			else 1
		local groups = {}
		for repetitionIndex = 1, caseValue.scheduledRepetitions do
			for participantIndex = 1, participants do
				local values = table.create(
					valuesPerGroup(measurement, caseDefinition),
					measurementValue(measurement, caseValue, caseDefinition, options)
				)
				local group = { repetitionIndex = repetitionIndex, values = values }
				if measurement.capture.role == "Sender" or measurement.capture.role == "ProbeClient" then
					group.participantIndex = participantIndex
				end
				table.insert(groups, group)
			end
		end
		table.insert(output, { id = measurement.id, state = "Available", rawSamples = groups })
	end
	return output
end

local function resultDraft(caseValue, caseDefinition, options)
	local counts = nil
	if caseValue.kind == "Workload" then
		local expectedSubmissions = caseValue.scheduledRepetitions
			* caseValue.senderCount * caseDefinition.measuredFrames * caseDefinition.messagesPerFrame
		local expectedDeliveries = expectedSubmissions * caseValue.recipientCount
		counts = {
			finality = "Final",
			expectedSubmissions = expectedSubmissions,
			submitted = expectedSubmissions,
			expectedDeliveries = expectedDeliveries,
			received = expectedDeliveries,
			correct = expectedDeliveries,
			missing = 0,
			duplicate = 0,
			unexpected = 0,
			outOfOrder = 0,
			mismatch = 0,
		}
	end

	local draft = {
		runId = options.runId or runId(options.index),
		benchmarkSource = {
			revision = options.revision or string.rep("a", 40),
			dirty = if options.dirty == nil then false else options.dirty,
			placeFingerprint = "sha256:" .. string.rep("9", 64),
		},
		contractFingerprint = options.contract or "sha256:" .. string.rep("b", 64),
		adapter = adapter(options),
		case = caseValue,
		failures = {},
		conformance = conformance(),
		measurements = availableMeasurements(caseValue, caseDefinition, options),
		environment = environment(caseValue, options),
	}
	if counts ~= nil then
		draft.counts = counts
	end
	return draft
end

local function workloadResult(options)
	local workload = findWorkload(options.caseId or "tiny-steady-c2s")
	local caseValue = {
		kind = "Workload",
		workloadId = workload.id,
		senderCount = workload.senderCount,
		recipientCount = options.recipients or 1,
		scheduledRepetitions = workload.repetitions,
		startedRepetitions = workload.repetitions,
		completedRepetitions = workload.repetitions,
	}
	return ResultV1.finalize(resultDraft(caseValue, workload, options))
end

local function probeResult(options)
	local probe = findProbe("tiny-round-trip")
	local caseValue = {
		kind = "SeparateProbe",
		probeId = probe.id,
		clientCount = probe.clientCount,
		scheduledRepetitions = probe.repetitions,
		startedRepetitions = probe.repetitions,
		completedRepetitions = probe.repetitions,
	}
	return ResultV1.finalize(resultDraft(caseValue, probe, options))
end

local function draftFromResult(result)
	local measurements = {}
	for _, measurement in result.measurements do
		local record = { id = measurement.metadata.id, state = measurement.state }
		if measurement.rawSamples ~= nil then
			record.rawSamples = clone(measurement.rawSamples)
		else
			record.unavailableReason = clone(measurement.unavailableReason)
		end
		table.insert(measurements, record)
	end
	local draft = {
		runId = result.runId,
		benchmarkSource = clone(result.benchmark.source),
		contractFingerprint = result.contract.fingerprint,
		adapter = clone(result.adapter),
		case = clone(result.case),
		failures = clone(result.failures),
		conformance = clone(result.conformance),
		measurements = measurements,
		environment = clone(result.environment),
	}
	if result.counts ~= nil then
		draft.counts = clone(result.counts)
	end
	return draft
end

local function unavailableMeasurements(draft, reason)
	for _, measurement in draft.measurements do
		measurement.state = "Unavailable"
		measurement.rawSamples = nil
		measurement.unavailableReason = { code = reason }
	end
end

local function notStarted(draft)
	draft.case.startedRepetitions = 0
	draft.case.completedRepetitions = 0
	draft.counts.finality = "NotStarted"
	for _, key in { "submitted", "received", "correct", "missing", "duplicate", "unexpected", "outOfOrder", "mismatch" } do
		draft.counts[key] = 0
	end
end

local function nonValidResult(kind, index)
	local draft = draftFromResult(workloadResult({ index = index }))
	if kind == "Invalid" then
		draft.failures = { { category = "Contract", code = "StaleCallback", occurrences = 1 } }
		for _, measurement in draft.measurements do
			for _, definition in Contract.measurements do
				if definition.id == measurement.id and definition.summary == "MedianAndP95" then
					measurement.state = "Diagnostic"
					break
				end
			end
		end
	elseif kind == "Unsupported" then
		notStarted(draft)
		draft.adapter.capabilities.payloadIds = { "state" }
		draft.failures = { {
			category = "Capability",
			code = "UnsupportedCapability",
			occurrences = 1,
			discriminator = { capability = "Payload", required = "tiny" },
		} }
		unavailableMeasurements(draft, "CaseUnsupported")
	else
		assert(kind == "Error", "unknown non-Valid fixture")
		notStarted(draft)
		draft.failures = { {
			category = "Harness",
			code = "InternalError",
			occurrences = 1,
			discriminator = { stage = "Preflight" },
		} }
		unavailableMeasurements(draft, "CaseNotCompleted")
	end
	return ResultV1.finalize(draft)
end

assert(table.isfrozen(ResultReporter), "ResultReporter API must be frozen")
assert(type(ResultReporter.render) == "function", "ResultReporter.render missing")

local slow = workloadResult({ index = 1, adapterName = "Slow", median = 20, diagnostic = 1 })
local fast = workloadResult({ index = 2, adapterName = "Fast", median = 10, diagnostic = 9_999 })
local workloadEntries = {
	{ path = "slow.json", result = slow },
	{ path = "fast.json", result = fast },
}
local workloadReport = ResultReporter.render(workloadEntries)
assert(string.find(workloadReport, "## Workload: tiny&#45;steady&#45;c2s", 1, true), "workload stratum missing")
assert(string.find(workloadReport, "### frameTime (milliseconds)", 1, true), "workload eligible metric missing")
assert(string.find(workloadReport, "| Fast |", 1, true) < string.find(workloadReport, "| Slow |", 1, true),
	"workloads must order only by the eligible timing")
assert(ResultReporter.render({ workloadEntries[2], workloadEntries[1] }) == workloadReport,
	"report changed with argument order")

local changedDiagnostics = {
	{ path = "slow.json", result = workloadResult({ index = 1, adapterName = "Slow", median = 20, diagnostic = 100_000 }) },
	{ path = "fast.json", result = workloadResult({ index = 2, adapterName = "Fast", median = 10, diagnostic = 0 }) },
}
assert(ResultReporter.render(changedDiagnostics) == workloadReport, "diagnostics changed report content or timing order")
assert(string.find(workloadReport, "submissionDuration", 1, true) == nil, "diagnostic measurement leaked into output")

local probeA = probeResult({ index = 3, adapterName = "Probe A", median = 3 })
local probeB = probeResult({ index = 4, adapterName = "Probe B", median = 2 })
local probeReport = ResultReporter.render({
	{ path = "probe-a.json", result = probeA },
	{ path = "probe-b.json", result = probeB },
})
assert(string.find(probeReport, "## Probe: tiny&#45;round&#45;trip", 1, true), "probe stratum missing")
assert(string.find(probeReport, "### roundTripLatency (milliseconds)", 1, true), "probe eligible metric missing")
assert(string.find(probeReport, "| Probe B |", 1, true) < string.find(probeReport, "| Probe A |", 1, true),
	"probe eligible timing order differs")

local lane = workloadResult({ index = 5, adapterName = "Other Lane", lane = "EquivalentSemantics" })
local broadcast = workloadResult({ index = 6, adapterName = "Other Broadcast", broadcast = "AdapterFanOut" })
local separated = ResultReporter.render({
	{ path = "base.json", result = fast },
	{ path = "lane.json", result = lane },
	{ path = "broadcast.json", result = broadcast },
})
assert(occurrences(separated, "## Workload:") == 3, "lane and broadcast strata were pooled")
assert(string.find(separated, "lane=EquivalentSemantics", 1, true), "lane separation missing")
assert(string.find(separated, "broadcast=AdapterFanOut", 1, true), "broadcast separation missing")

local incompatibleInputs = {
	{ path = "baseline.json", result = workloadResult({ index = 10, adapterName = "Compat Base" }) },
	{ path = "contract.json", result = workloadResult({
		index = 11,
		adapterName = "Compat Contract",
		contract = "sha256:" .. string.rep("c", 64),
	}) },
	{ path = "revision.json", result = workloadResult({
		index = 12,
		adapterName = "Compat Revision",
		revision = string.rep("d", 40),
	}) },
	{ path = "studio.json", result = workloadResult({
		index = 13,
		adapterName = "Compat Studio",
		studio = "0.651.0.6500001",
	}) },
	{ path = "host.json", result = workloadResult({
		index = 14,
		adapterName = "Compat Host",
		osFamily = "macOS",
		architecture = "arm64",
	}) },
	{ path = "cpu.json", result = workloadResult({
		index = 15,
		adapterName = "Compat CPU",
		cpuModel = "Different CPU",
	}) },
	{ path = "gpu.json", result = workloadResult({
		index = 16,
		adapterName = "Compat GPU",
		gpuModel = "Different GPU",
	}) },
}
local incompatible = ResultReporter.render(incompatibleInputs)
assert(string.find(incompatible, "### Incompatible evidence", 1, true), "compatibility mismatch was pooled")
assert(occurrences(incompatible, "### frameTime (milliseconds) · C") == #incompatibleInputs,
	"incompatible cohorts did not retain separate timing tables")
assert(string.find(incompatible, "Different CPU", 1, true), "CPU mismatch evidence missing")
assert(string.find(incompatible, "Different GPU", 1, true), "GPU mismatch evidence missing")

local invalid = nonValidResult("Invalid", 20)
local unsupported = nonValidResult("Unsupported", 21)
local errored = nonValidResult("Error", 22)
local evidence = ResultReporter.render({
	{ path = "valid.json", result = fast },
	{ path = "invalid.json", result = invalid },
	{ path = "unsupported.json", result = unsupported },
	{ path = "error.json", result = errored },
})
assert(string.find(evidence, "### Non-Valid evidence", 1, true) < string.find(evidence, "### frameTime", 1, true),
	"non-Valid evidence must precede timings")
for _, result in { invalid, unsupported, errored } do
	local escapedRunId = string.gsub(result.runId, "-", "&#45;")
	assert(occurrences(evidence, escapedRunId) == 1, result.status .. " received a timing row")
end
assert(string.find(evidence, "Contract&#47;StaleCallback×1", 1, true), "failure evidence missing")

expectError("RESULT_REPORT_E_DIRTY", function()
	ResultReporter.render({
		{ path = "clean.json", result = fast },
		{ path = "dirty.json", result = workloadResult({ index = 30, dirty = true }) },
	})
end)
expectError("RESULT_REPORT_E_SCHEMA", function()
	local wrongSchema = clone(workloadResult({ index = 31 }))
	wrongSchema.schema.version = 2
	ResultReporter.render({
		{ path = "clean.json", result = fast },
		{ path = "wrong-schema.json", result = wrongSchema },
	})
end)
expectError("RESULT_REPORT_E_SCHEMA", function()
	ResultReporter.render({
		{ path = "clean.json", result = fast },
		{ path = "tag-only.json", result = { schema = { id = ResultV1.ID, version = ResultV1.VERSION } } },
	})
end)
expectError("RESULT_REPORT_E_DUPLICATE_PATH", function()
	ResultReporter.render({
		{ path = "same.json", result = fast },
		{ path = "same.json", result = slow },
	})
end)
expectError("RESULT_REPORT_E_DUPLICATE_RUN_ID", function()
	ResultReporter.render({
		{ path = "first.json", result = fast },
		{ path = "second.json", result = workloadResult({ index = 32, runId = fast.runId }) },
	})
end)

local hostileDiagnosticPath = "bad\27\n\127path-" .. string.rep("x", 2_000)
local diagnosticOk, diagnosticFailure = pcall(function()
	ResultReporter.render({
		{ path = "clean.json", result = fast },
		{ path = hostileDiagnosticPath, result = { schema = { id = ResultV1.ID, version = ResultV1.VERSION } } },
	})
end)
assert(not diagnosticOk, "hostile diagnostic path must reject")
local diagnosticMessage = tostring(diagnosticFailure)
assert(string.find(diagnosticMessage, "RESULT_REPORT_E_SCHEMA:bad???path-", 1, true),
	"diagnostic path controls were not visibly replaced")
assert(string.find(diagnosticMessage, string.char(27), 1, true) == nil
	and string.find(diagnosticMessage, string.char(127), 1, true) == nil
	and string.find(diagnosticMessage, "\n", 1, true) == nil,
	"diagnostic path retained terminal control bytes")
assert(#diagnosticMessage <= #"RESULT_REPORT_E_SCHEMA:" + 512, "diagnostic path was not bounded")

local injected = workloadResult({
	index = 40,
	adapterName = "Adapter ![x](https://evil.test/a)_em_*`code`<script>",
	libraryName = "Library [lib](https://evil.test/b)&<b>",
})
local escapedReport = ResultReporter.render({
	{ path = "!\27[31m![path](https://evil.test/c)\7\127\t\n|`*<img>.json", result = injected },
	{ path = "ordinary.json", result = workloadResult({ index = 41 }) },
})
assert(string.find(escapedReport, "<script>", 1, true) == nil, "adapter HTML was not escaped")
assert(string.find(escapedReport, "<img>", 1, true) == nil, "path HTML was not escaped")
assert(string.find(escapedReport,
	"Adapter &#33;&#91;x&#93;&#40;https&#58;&#47;&#47;evil&#46;test&#47;a&#41;&#95;em&#95;&#42;&#96;code&#96;&lt;script&gt;",
	1, true), "adapter Markdown/HTML escaping differs")
assert(string.find(escapedReport,
	"Library &#91;lib&#93;&#40;https&#58;&#47;&#47;evil&#46;test&#47;b&#41;&amp;&lt;b&gt;",
	1, true), "library Markdown/HTML escaping differs")
assert(string.find(escapedReport,
	"&#33; &#91;31m&#33;&#91;path&#93;&#40;https&#58;&#47;&#47;evil&#46;test&#47;c&#41;    &#124;&#96;&#42;&lt;img&gt;&#46;json",
	1, true), "path Markdown/control escaping differs")
for _, active in { "![x](https://evil.test/a)", "[lib](https://evil.test/b)", "https://evil.test/c", "`code`" } do
	assert(string.find(escapedReport, active, 1, true) == nil, "active Markdown survived escaping: " .. active)
end
for index = 1, #escapedReport do
	local byte = string.byte(escapedReport, index)
	assert(byte == 10 or byte > 31, "rendered report retained an ASCII control byte")
	assert(byte ~= 127, "rendered report retained DEL")
end

local lowercase = string.lower(workloadReport .. "\n" .. probeReport .. "\n" .. separated .. "\n" .. incompatible)
assert(string.find(lowercase, "winner", 1, true) == nil, "report invented a winner")
assert(string.find(lowercase, "score", 1, true) == nil, "report invented a score")
assert(string.find(lowercase, "rank", 1, true) == nil, "report invented a rank")

local _, realResult = HostRuntimeFixtures.maximum()
local secondCandidate = clone(realResult)
secondCandidate.runId = runId(50)
local secondResult = ResultV1.validate(secondCandidate)
local realReport = ResultReporter.render({
	{ path = "real-a.json", result = realResult },
	{ path = "real-b.json", result = secondResult },
})
assert(string.find(realReport, "### frameTime (milliseconds)", 1, true), "validated maximum Result V1 integration missing")

local tempRoot = ".tmp/result-reporter-test"
assert(not fs.isDir(tempRoot) and not fs.isFile(tempRoot), "result reporter temp fixture collided")
if not fs.isDir(".tmp") then
	fs.writeDir(".tmp")
end
fs.writeDir(tempRoot)

local createdFiles = {}
local function writeFixture(name, body)
	local path = tempRoot .. "/" .. name
	fs.writeFile(path, body)
	table.insert(createdFiles, path)
	return path
end

local firstPath = writeFixture("first.json", serde.encode("json", fast))
local secondPath = writeFixture("second.json", serde.encode("json", slow))
local malformedPath = writeFixture("malformed.json", "{}")

local command = {
	"run",
	"benchmarks/reporting/compare-results.luau",
	"--result",
	secondPath,
	"--result",
	firstPath,
}
local cli = process.exec("lune", command)
assert(cli.ok, "comparison CLI rejected valid Result V1 inputs: " .. cli.stderr)
local normalizedStdout = string.gsub(cli.stdout, "\r\n", "\n")
normalizedStdout = string.gsub(normalizedStdout, "\n$", "")
local expectedCliReport = ResultReporter.render({
	{ path = firstPath, result = fast },
	{ path = secondPath, result = slow },
})
assert(normalizedStdout == expectedCliReport, "comparison CLI output differs from pure reporter")

if process.os == "windows" then
	for _, name in {
		"second.json;Write-Output REPORTER_PATH_EXECUTED;#.json",
		"spaces 'quote' $value (literal).json",
	} do
		local literalPath = writeFixture(name, serde.encode("json", slow))
		local literalResult = process.exec("lune", {
			"run", "benchmarks/reporting/compare-results.luau",
			"--result", literalPath, "--result", firstPath,
		})
		assert(literalResult.ok, "Windows result path was interpreted as PowerShell: " .. literalResult.stderr)
		local literalOutput = string.gsub(string.gsub(literalResult.stdout, "\r\n", "\n"), "\n$", "")
		assert(literalOutput == ResultReporter.render({
			{ path = firstPath, result = fast }, { path = literalPath, result = slow },
		}), "Windows literal-path CLI output differs from pure reporter")
	end
end

local function expectCliFailure(path, code)
	local failure = process.exec("lune", {
		"run",
		"benchmarks/reporting/compare-results.luau",
		"--result",
		path,
		"--result",
		firstPath,
	})
	assert(not failure.ok and string.find(failure.stderr, code .. ":" .. path, 1, true),
		code .. " CLI failure lacked its result path: " .. failure.stderr)
	return failure.stderr
end

expectCliFailure(malformedPath, "RESULT_REPORT_E_SCHEMA")

local duplicatePathFailure = process.exec("lune", {
	"run",
	"benchmarks/reporting/compare-results.luau",
	"--result",
	firstPath,
	"--result",
	firstPath,
})
assert(not duplicatePathFailure.ok
	and string.find(duplicatePathFailure.stderr, "RESULT_REPORT_E_DUPLICATE_PATH:" .. firstPath, 1, true),
	"CLI duplicate path was not rejected before loading")

local oversizedPath = writeFixture("oversized.json", string.rep(" ", ResultV1.MAX_JSON_BYTES + 1))
local oversizedFailure = expectCliFailure(oversizedPath, "RESULT_REPORT_E_SIZE")
assert(string.find(oversizedFailure, "RESULT_REPORT_E_JSON", 1, true) == nil,
	"oversized input reached lexical JSON processing")

expectCliFailure(tempRoot, "RESULT_REPORT_E_FILE")

local deepPath = writeFixture("deep.json", string.rep("[", 11) .. "0" .. string.rep("]", 11))
local tokenPath = writeFixture("tokens.json", "[" .. string.rep("0,", JSON_TOKEN_MAX) .. "0]")
local duplicateKeyPath = writeFixture("duplicate-key.json", [=[{"a":1,"\u0061":2}]=])
local negativeZeroPath = writeFixture("negative-zero.json", [[{"value":-0}]])
local nonFinitePath = writeFixture("non-finite.json", [[{"value":1e9999}]])
local underflowPath = writeFixture("underflow.json", [[{"value":1e-9999}]])
local noncanonicalPath = writeFixture("noncanonical-number.json", [[{"value":01}]])
local longKeyPath = writeFixture("long-key.json", "{\"" .. string.rep("k", 129) .. "\":1}")
for _, path in {
	deepPath,
	tokenPath,
	duplicateKeyPath,
	negativeZeroPath,
	nonFinitePath,
	underflowPath,
	noncanonicalPath,
	longKeyPath,
} do
	local stderr = expectCliFailure(path, "RESULT_REPORT_E_JSON")
	assert(string.find(stderr, "RESULT_REPORT_E_SCHEMA", 1, true) == nil,
		"lexically unsafe JSON reached Result V1 validation")
end

local hostileMissingPath = tempRoot .. "/missing-\27-\n-\127.json"
local hostileMissingFailure = process.exec("lune", {
	"run",
	"benchmarks/reporting/compare-results.luau",
	"--result",
	hostileMissingPath,
	"--result",
	firstPath,
})
assert(not hostileMissingFailure.ok
	and string.find(hostileMissingFailure.stderr, "RESULT_REPORT_E_FILE:", 1, true)
	and string.find(hostileMissingFailure.stderr, "missing-?-?-?.json", 1, true),
	"CLI did not visibly sanitize a hostile missing path")
assert(string.find(hostileMissingFailure.stderr, string.char(27), 1, true) == nil
	and string.find(hostileMissingFailure.stderr, string.char(127), 1, true) == nil,
	"CLI diagnostic retained terminal controls from a hostile path")

if process.os ~= "windows" then
	local hostileMalformedPath = tempRoot .. "/malformed-\27-\n-\127.json"
	local writeOk = pcall(fs.writeFile, hostileMalformedPath, "{}")
	if writeOk then
		table.insert(createdFiles, hostileMalformedPath)
		local hostileMalformedFailure = process.exec("lune", {
			"run",
			"benchmarks/reporting/compare-results.luau",
			"--result",
			hostileMalformedPath,
			"--result",
			firstPath,
		})
		assert(not hostileMalformedFailure.ok
			and string.find(hostileMalformedFailure.stderr, "RESULT_REPORT_E_SCHEMA:", 1, true)
			and string.find(hostileMalformedFailure.stderr, "malformed-?-?-?.json", 1, true),
			"CLI did not sanitize a supported hostile filename")
		assert(string.find(hostileMalformedFailure.stderr, string.char(27), 1, true) == nil
			and string.find(hostileMalformedFailure.stderr, string.char(127), 1, true) == nil,
			"malformed filename controls reached CLI stderr")
	end
end

local dirtyPath = writeFixture("dirty.json", serde.encode("json", workloadResult({ index = 60, dirty = true })))
expectCliFailure(dirtyPath, "RESULT_REPORT_E_DIRTY")

for _, path in createdFiles do
	fs.removeFile(path)
end
fs.removeDir(tempRoot)

print("PASS Relay.Benchmarks.ResultReporter")
