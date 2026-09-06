--!strict

local ResultV1 = require("../contracts/result-v1")
local ResultV2 = require("../contracts/result-v2")

export type Entry = {
	path: string,
	result: any,
}

type PreparedEntry = {
	path: string,
	result: any,
	stratumKey: string,
	compatibilityKey: string,
}

local MAX_DIAGNOSTIC_BYTES = 512

local function diagnosticText(value: string): string
	local limit = math.min(#value, MAX_DIAGNOSTIC_BYTES)
	local sanitized = table.create(limit)
	for index = 1, limit do
		local byte = string.byte(value, index)
		sanitized[index] = if byte <= 31 or byte == 127 then "?" else string.char(byte)
	end
	if #value > MAX_DIAGNOSTIC_BYTES then
		sanitized[MAX_DIAGNOSTIC_BYTES - 2] = "."
		sanitized[MAX_DIAGNOSTIC_BYTES - 1] = "."
		sanitized[MAX_DIAGNOSTIC_BYTES] = "."
	end
	return table.concat(sanitized)
end

local function fail(code: string, path: string?): never
	error(if path == nil then code else code .. ":" .. diagnosticText(path), 0)
end

local MARKDOWN_PUNCTUATION = table.freeze({
	["!"] = "&#33;",
	['"'] = "&#34;",
	["#"] = "&#35;",
	["$"] = "&#36;",
	["%"] = "&#37;",
	["&"] = "&amp;",
	["'"] = "&#39;",
	["("] = "&#40;",
	[")"] = "&#41;",
	["*"] = "&#42;",
	["+"] = "&#43;",
	[","] = "&#44;",
	["-"] = "&#45;",
	["."] = "&#46;",
	["/"] = "&#47;",
	[":"] = "&#58;",
	[";"] = "&#59;",
	["<"] = "&lt;",
	["="] = "&#61;",
	[">"] = "&gt;",
	["?"] = "&#63;",
	["@"] = "&#64;",
	["["] = "&#91;",
	["\\"] = "&#92;",
	["]"] = "&#93;",
	["^"] = "&#94;",
	["_"] = "&#95;",
	["`"] = "&#96;",
	["{"] = "&#123;",
	["|"] = "&#124;",
	["}"] = "&#125;",
	["~"] = "&#126;",
})

local function markdownText(value: any): string
	local rendered = tostring(value)
	local escaped = table.create(#rendered)
	for index = 1, #rendered do
		local byte = string.byte(rendered, index)
		if byte <= 31 or byte == 127 then
			escaped[index] = " "
		else
			local character = string.char(byte)
			escaped[index] = MARKDOWN_PUNCTUATION[character] or character
		end
	end
	return table.concat(escaped)
end

local markdownCell = markdownText

local function joined(...: any): string
	local parts = table.pack(...)
	local rendered = table.create(parts.n)
	for index = 1, parts.n do
		local part = rawget(parts, index)
		if part == nil then
			rendered[index] = "N0:"
		else
			local kind = type(part)
			if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
				fail("RESULT_REPORT_E_SCHEMA")
			end
			local scalar = tostring(part)
			local tag = if kind == "string" then "S" elseif kind == "number" then "D" else "B"
			rendered[index] = tag .. tostring(#scalar) .. ":" .. scalar
		end
	end
	return table.concat(rendered)
end

local function stratumKey(result: any): string
	local caseValue = result.case
	local adapter = result.adapter
	if caseValue.kind == "Workload" then
		return joined(
			result.schema.id, result.schema.version,
			result.contract.id, result.contract.version,
			adapter.semantics.repetitionIsolation,
			"1",
			caseValue.workloadId,
			caseValue.recipientCount,
			adapter.lane,
			adapter.semantics.broadcastMode
		)
	end
	return joined(
		result.schema.id, result.schema.version,
		result.contract.id, result.contract.version,
		adapter.semantics.repetitionIsolation,
		"2",
		caseValue.probeId,
		caseValue.clientCount,
		adapter.lane,
		adapter.semantics.broadcastMode
	)
end

local function compatibilityKey(result: any): string
	local execution = result.environment.execution
	local host = result.environment.host
	local source = result.benchmark.source
	return joined(
		result.schema.id, result.schema.version,
		result.contract.id, result.contract.version,
		result.adapter.semantics.repetitionIsolation,
		result.contract.fingerprint,
		if result.schema.id == ResultV2.ID then source.measurementFingerprint else source.revision,
		result.environment.studio.version,
		result.environment.studio.channel,
		host.osFamily,
		host.architecture,
		host.osVersion,
		host.cpuModel,
		host.logicalProcessorCount,
		host.memoryMiB,
		host.gpuModel,
		execution.mode,
		execution.targetFrameRate,
		execution.serverCount,
		execution.clientCount
	)
end

local function entryLess(left: PreparedEntry, right: PreparedEntry): boolean
	if left.stratumKey ~= right.stratumKey then
		return left.stratumKey < right.stratumKey
	end
	if left.compatibilityKey ~= right.compatibilityKey then
		return left.compatibilityKey < right.compatibilityKey
	end
	if left.result.status ~= right.result.status then
		return left.result.status < right.result.status
	end
	if left.result.adapter.id ~= right.result.adapter.id then
		return left.result.adapter.id < right.result.adapter.id
	end
	if left.result.runId ~= right.result.runId then
		return left.result.runId < right.result.runId
	end
	return left.path < right.path
end

local function prepare(entries: { Entry }): { PreparedEntry }
	if type(entries) ~= "table" or #entries < 2 then
		fail("RESULT_REPORT_E_INPUTS")
	end

	local ordered = table.clone(entries)
	table.sort(ordered, function(left: Entry, right: Entry): boolean
		if type(left) ~= "table" or type(left.path) ~= "string" then
			fail("RESULT_REPORT_E_ENTRY")
		end
		if type(right) ~= "table" or type(right.path) ~= "string" then
			fail("RESULT_REPORT_E_ENTRY")
		end
		return left.path < right.path
	end)

	local paths: { [string]: boolean } = {}
	local runIds: { [string]: string } = {}
	local prepared = table.create(#ordered)
	for _, entry in ordered do
		if type(entry.path) ~= "string" or #entry.path == 0 then
			fail("RESULT_REPORT_E_ENTRY")
		end
		if paths[entry.path] then
			fail("RESULT_REPORT_E_DUPLICATE_PATH", entry.path)
		end
		paths[entry.path] = true

		local schema = if type(entry.result) == "table" then rawget(entry.result, "schema") else nil
		local schemaId = if type(schema) == "table" then rawget(schema, "id") else nil
		local validator = if schemaId == ResultV1.ID then ResultV1.validate
			elseif schemaId == ResultV2.ID then ResultV2.validate else nil
		if validator == nil then fail("RESULT_REPORT_E_SCHEMA", entry.path) end
		local validateOk, result = pcall(validator, entry.result)
		if not validateOk then
			fail("RESULT_REPORT_E_SCHEMA", entry.path)
		end
		local firstPath = runIds[result.runId]
		if firstPath ~= nil then
			fail("RESULT_REPORT_E_DUPLICATE_RUN_ID", result.runId .. ":" .. firstPath .. ":" .. entry.path)
		end
		runIds[result.runId] = entry.path
		if type(result.benchmark) ~= "table"
			or type(result.benchmark.source) ~= "table"
			or result.benchmark.source.dirty ~= false
		then
			fail("RESULT_REPORT_E_DIRTY", entry.path)
		end

		local ok, stratum = pcall(stratumKey, result)
		local compatible, compatibility = pcall(compatibilityKey, result)
		if not ok or not compatible then
			fail("RESULT_REPORT_E_SCHEMA", entry.path)
		end
		table.insert(prepared, {
			path = entry.path,
			result = result,
			stratumKey = stratum,
			compatibilityKey = compatibility,
		})
	end

	table.sort(prepared, entryLess)
	return prepared
end

local function stratumHeading(result: any): string
	local caseValue = result.case
	local identity = result.adapter
	local profile = string.format(" · profile=%s/%s · isolation=%s",
		markdownText(result.contract.id), markdownText(result.contract.version),
		markdownText(identity.semantics.repetitionIsolation))
	if caseValue.kind == "Workload" then
		return string.format(
			"## Workload: %s · recipients=%s · lane=%s · broadcast=%s",
			markdownText(caseValue.workloadId),
			markdownText(caseValue.recipientCount),
			markdownText(identity.lane),
			markdownText(identity.semantics.broadcastMode)
		) .. profile
	end
	return string.format(
		"## Probe: %s · clients=%s · lane=%s · broadcast=%s",
		markdownText(caseValue.probeId),
		markdownText(caseValue.clientCount),
		markdownText(identity.lane),
		markdownText(identity.semantics.broadcastMode)
	) .. profile
end

local function failureSummary(result: any): string
	if #result.failures == 0 then
		return "—"
	end
	local failures = table.create(#result.failures)
	for index, failure in result.failures do
		failures[index] = string.format("%s/%s×%s", failure.category, failure.code, failure.occurrences)
	end
	return table.concat(failures, ", ")
end

local function appendNonValidEvidence(lines: { string }, entries: { PreparedEntry })
	local evidence = {}
	for _, entry in entries do
		if entry.result.status ~= "Valid" then
			table.insert(evidence, entry)
		end
	end
	if #evidence == 0 then
		return
	end

	table.insert(lines, "### Non-Valid evidence")
	table.insert(lines, "")
	table.insert(lines, "| Status | Adapter | Run ID | Result | Failures |")
	table.insert(lines, "| --- | --- | --- | --- | --- |")
	for _, entry in evidence do
		local result = entry.result
		table.insert(lines, string.format(
			"| %s | %s | %s | %s | %s |",
			markdownCell(result.status),
			markdownCell(result.adapter.displayName),
			markdownCell(result.runId),
			markdownCell(entry.path),
			markdownCell(failureSummary(result))
		))
	end
	table.insert(lines, "")
end

local function topology(result: any): string
	local execution = result.environment.execution
	return string.format(
		"%s; %ss/%sc; %sfps",
		execution.mode,
		execution.serverCount,
		execution.clientCount,
		execution.targetFrameRate
	)
end

local function compatibleCohorts(entries: { PreparedEntry }): { { PreparedEntry } }
	local cohorts = {}
	local currentKey = nil
	local current = nil
	for _, entry in entries do
		if entry.result.status == "Valid" then
			if currentKey ~= entry.compatibilityKey then
				currentKey = entry.compatibilityKey
				current = {}
				table.insert(cohorts, current)
			end
			table.insert(current :: { PreparedEntry }, entry)
		end
	end
	return cohorts
end

local function appendIncompatibleEvidence(lines: { string }, cohorts: { { PreparedEntry } })
	if #cohorts < 2 then
		return
	end

	table.insert(lines, "### Incompatible evidence")
	table.insert(lines, "")
	table.insert(lines, "| Cohort | Adapter | Run ID | Result | Contract fingerprint | Measurement fingerprint | Benchmark revision | Studio | Host | OS version | CPU | Logical CPUs | Memory MiB | GPU | Topology |")
	table.insert(lines, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | --- | --- |")
	for cohortIndex, cohort in cohorts do
		for _, entry in cohort do
			local result = entry.result
			local host = result.environment.host
			table.insert(lines, string.format(
				"| C%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |",
				markdownCell(cohortIndex),
				markdownCell(result.adapter.displayName),
				markdownCell(result.runId),
				markdownCell(entry.path),
				markdownCell(result.contract.fingerprint),
				markdownCell(result.benchmark.source.measurementFingerprint or "—"),
				markdownCell(result.benchmark.source.revision),
				markdownCell(result.environment.studio.version),
				markdownCell(host.osFamily .. "/" .. host.architecture),
				markdownCell(host.osVersion or "—"),
				markdownCell(host.cpuModel or "—"),
				markdownCell(host.logicalProcessorCount or "—"),
				markdownCell(host.memoryMiB or "—"),
				markdownCell(host.gpuModel or "—"),
				markdownCell(topology(result))
			))
		end
	end
	table.insert(lines, "")
end

local function eligibleMeasurement(entry: PreparedEntry): any
	local found = nil
	for _, measurement in entry.result.measurements do
		if measurement.metadata.capture.ranking == "Eligible" then
			if found ~= nil or measurement.state ~= "Available" or measurement.summary.kind ~= "MedianAndP95" then
				fail("RESULT_REPORT_E_ELIGIBLE_METRIC", entry.path)
			end
			found = measurement
		end
	end
	if found == nil then
		fail("RESULT_REPORT_E_ELIGIBLE_METRIC", entry.path)
	end
	return found
end

local function appendTimings(lines: { string }, cohorts: { { PreparedEntry } })
	for cohortIndex, cohort in cohorts do
		local timings = table.create(#cohort)
		local metricId = nil
		local unit = nil
		for _, entry in cohort do
			local measurement = eligibleMeasurement(entry)
			if metricId == nil then
				metricId = measurement.metadata.id
				unit = measurement.metadata.unit
			elseif metricId ~= measurement.metadata.id or unit ~= measurement.metadata.unit then
				fail("RESULT_REPORT_E_ELIGIBLE_METRIC", entry.path)
			end
			table.insert(timings, { entry = entry, measurement = measurement })
		end

		table.sort(timings, function(left: any, right: any): boolean
			local leftSummary = left.measurement.summary
			local rightSummary = right.measurement.summary
			if leftSummary.median ~= rightSummary.median then
				return leftSummary.median < rightSummary.median
			end
			if leftSummary.p95 ~= rightSummary.p95 then
				return leftSummary.p95 < rightSummary.p95
			end
			local leftResult = left.entry.result
			local rightResult = right.entry.result
			if leftResult.adapter.id ~= rightResult.adapter.id then
				return leftResult.adapter.id < rightResult.adapter.id
			end
			if leftResult.runId ~= rightResult.runId then
				return leftResult.runId < rightResult.runId
			end
			return left.entry.path < right.entry.path
		end)

		local cohortLabel = if #cohorts == 1 then "" else string.format(" · C%s", markdownText(cohortIndex))
		table.insert(lines, string.format("### %s (%s)%s", markdownText(metricId), markdownText(unit), cohortLabel))
		table.insert(lines, "")
		table.insert(lines, "| Adapter | Library | Run ID | Result | Samples | Median | P95 |")
		table.insert(lines, "| --- | --- | --- | --- | ---: | ---: | ---: |")
		for _, timing in timings do
			local entry = timing.entry
			local result = entry.result
			local summary = timing.measurement.summary
			local library = result.adapter.library
			table.insert(lines, string.format(
				"| %s | %s | %s | %s | %s | %s | %s |",
				markdownCell(result.adapter.displayName),
				markdownCell(library.displayName .. " " .. library.version),
				markdownCell(result.runId),
				markdownCell(entry.path),
				markdownCell(summary.sampleCount),
				markdownCell(summary.median),
				markdownCell(summary.p95)
			))
		end
		table.insert(lines, "")
	end
end

local function render(entries: { Entry }): string
	local prepared = prepare(entries)
	local lines = {
		"# Relay benchmark comparison",
		"",
		string.format(
			"Inputs: %s validated Result V1/V2 files. Each timing row is one run; samples are not combined.",
			markdownText(#prepared)
		),
		"",
	}

	local startIndex = 1
	while startIndex <= #prepared do
		local finishIndex = startIndex
		while finishIndex < #prepared and prepared[finishIndex + 1].stratumKey == prepared[startIndex].stratumKey do
			finishIndex += 1
		end
		local stratumEntries = table.create(finishIndex - startIndex + 1)
		for index = startIndex, finishIndex do
			table.insert(stratumEntries, prepared[index])
		end

		table.insert(lines, stratumHeading(stratumEntries[1].result))
		table.insert(lines, "")
		appendNonValidEvidence(lines, stratumEntries)
		local cohorts = compatibleCohorts(stratumEntries)
		appendIncompatibleEvidence(lines, cohorts)
		appendTimings(lines, cohorts)
		startIndex = finishIndex + 1
	end

	while lines[#lines] == "" do
		table.remove(lines)
	end
	return table.concat(lines, "\n")
end

local ResultReporter = table.freeze({
	render = render,
})

return ResultReporter
