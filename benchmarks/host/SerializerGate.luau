--!strict

local CASES = { "state-burst-c2s", "state-broadcast-s2c", "tiny-round-trip" }
local WORKLOAD_METRICS = {
	"wireBytesPerDelivery",
	"senderMedianUs",
	"senderP95Us",
	"receiverMedianUs",
	"receiverP95Us",
	"latencyP95Ms",
	"latencyP99Ms",
	"deliveredPerSecond",
}
local PROBE_METRICS = { "latencyP95Ms", "latencyP99Ms" }
local LIMIT_NAMES = {
	"minimumWireSaving",
	"maximumCostRegression",
	"maximumLatencyRegression",
	"maximumDeliveryRegression",
	"maximumControlVariation",
}
local MAX_SUMMARY_SAMPLES = 100_000

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function positive(value: any): boolean
	return finite(value) and value > 0
end

local function denseLength(value: any, maximum: number): number?
	if type(value) ~= "table" then return nil end
	local count = 0
	for key in next, value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximum then return nil end
		count += 1
	end
	for index = 1, count do
		if rawget(value, index) == nil then return nil end
	end
	return count
end

local function revision(value: any): boolean
	return type(value) == "string" and (#value == 40 or #value == 64) and string.match(value, "^[0-9a-f]+$") ~= nil
end

local function fingerprint(value: any): boolean
	return type(value) == "string" and string.match(value, "^sha256:[0-9a-f]+$") ~= nil and #value == 71
end

local function addReason(reasons: { string }, seen: { [string]: boolean }, value: string)
	if not seen[value] then
		seen[value] = true
		table.insert(reasons, value)
	end
end

local function report(status: string, reasons: { string }, comparisons: { any }): any
	for _, comparison in comparisons do table.freeze(comparison) end
	table.freeze(reasons)
	table.freeze(comparisons)
	return table.freeze({
		schema = "Relay.SerializerGateReport",
		version = 1,
		status = status,
		reasons = reasons,
		comparisons = comparisons,
	})
end

local function inconclusive(reason: string): any
	return report("Inconclusive", { reason }, {})
end

local function validSource(value: any): boolean
	local place = if type(value) == "table" then rawget(value, "place") else nil
	return type(value) == "table"
		and revision(rawget(value, "revision"))
		and fingerprint(rawget(value, "adapterFingerprint"))
		and type(place) == "table"
		and fingerprint(rawget(place, "sha256"))
end

local function validPlan(plan: any): (any?, string?)
	if type(plan) ~= "table" or rawget(plan, "schema") ~= "Relay.SerializerGatePlan" or rawget(plan, "version") ~= 1 then
		return nil, "plan-invalid"
	end
	local baseline = rawget(plan, "baseline")
	if not validSource(baseline) then return nil, "plan-invalid" end
	local cases = rawget(plan, "cases")
	if denseLength(cases, #CASES) ~= #CASES then return nil, "plan-invalid" end
	local expectedCases = {}
	for _, caseId in CASES do expectedCases[caseId] = true end
	local seenCases = {}
	local copiedCases = table.create(#CASES)
	for index = 1, #CASES do
		local caseId = rawget(cases, index)
		if type(caseId) ~= "string" or not expectedCases[caseId] or seenCases[caseId] then return nil, "plan-invalid" end
		seenCases[caseId] = true
		copiedCases[index] = caseId
	end
	local limits = rawget(plan, "limits")
	if type(limits) ~= "table" then return nil, "plan-invalid" end
	local copiedLimits = {}
	for _, name in LIMIT_NAMES do
		local value = rawget(limits, name)
		if not finite(value) or value < 0 or value > 1 then return nil, "plan-invalid" end
		copiedLimits[name] = value
	end
	local candidate = rawget(plan, "candidate")
	if candidate ~= nil and not validSource(candidate) then return nil, "plan-invalid" end
	local copiedBaseline = {
		revision = rawget(baseline, "revision"),
		adapterFingerprint = rawget(baseline, "adapterFingerprint"),
		placeFingerprint = rawget(rawget(baseline, "place"), "sha256"),
	}
	local copiedCandidate = if candidate == nil then nil else {
		revision = rawget(candidate, "revision"),
		adapterFingerprint = rawget(candidate, "adapterFingerprint"),
		placeFingerprint = rawget(rawget(candidate, "place"), "sha256"),
	}
	return { baseline = copiedBaseline, candidate = copiedCandidate, cases = copiedCases, limits = copiedLimits }
end

local function metricsFor(caseId: string): { string }
	return if caseId == "tiny-round-trip" then PROBE_METRICS else WORKLOAD_METRICS
end

local function evaluate(plan: any, rows: any): any
	local normalized, planError = validPlan(plan)
	if normalized == nil then return inconclusive(planError or "plan-invalid") end
	if normalized.candidate == nil then return inconclusive("candidate-not-specified") end
	local baselineSource = normalized.baseline
	local candidateSource = normalized.candidate
	if baselineSource.adapterFingerprint == candidateSource.adapterFingerprint then
		return inconclusive("candidate-unchanged")
	end

	local rowCount = denseLength(rows, #normalized.cases * 6)
	if rowCount ~= #normalized.cases * 6 then return inconclusive("rows-incomplete-or-invalid") end
	local byCase = {}
	local runIds = {}
	local rowIndex = 0
	local schedules = {
		{ pass = 1, role = "baseline" },
		{ pass = 1, role = "control" },
		{ pass = 1, role = "candidate" },
		{ pass = 2, role = "candidate" },
		{ pass = 2, role = "control" },
		{ pass = 2, role = "baseline" },
	}
	for _, caseId in normalized.cases do
		local caseRows = { [1] = {}, [2] = {} }
		byCase[caseId] = caseRows
		for _, slot in schedules do
			rowIndex += 1
			local row = rawget(rows, rowIndex)
			if type(row) ~= "table" or rawget(row, "caseId") ~= caseId
				or rawget(row, "pass") ~= slot.pass or rawget(row, "role") ~= slot.role then
				return inconclusive("row-schedule-mismatch")
			end
			local runId = rawget(row, "runId")
			local rowRevision = rawget(row, "revision")
			local adapterFingerprint = rawget(row, "adapterFingerprint")
			local placeFingerprint = rawget(row, "placeFingerprint")
			local measurementFingerprint = rawget(row, "measurementFingerprint")
			local compatibilityKey = rawget(row, "compatibilityKey")
			local issues = rawget(row, "issues")
			local issueCount = denseLength(issues, 1_000)
			local metricValues = rawget(row, "metrics")
			local requiredMetrics = metricsFor(caseId)
			if type(runId) ~= "string" or runId == "" or runIds[runId]
				or not revision(rowRevision) or not fingerprint(adapterFingerprint)
				or not fingerprint(placeFingerprint)
				or not fingerprint(measurementFingerprint)
				or type(compatibilityKey) ~= "string" or compatibilityKey == ""
				or issueCount == nil or type(metricValues) ~= "table" then
			return inconclusive(if type(runId) == "string" and runIds[runId] then "duplicate-run-id" else "row-evidence-invalid")
			end
			runIds[runId] = true
			for issueIndex = 1, issueCount do
				local issue = rawget(issues, issueIndex)
				if type(issue) ~= "string" then return inconclusive("row-evidence-invalid") end
			end
			if issueCount > 0 then return inconclusive("row-has-issues") end
			local expectedSource = if slot.role == "candidate" then candidateSource else baselineSource
			if rowRevision ~= expectedSource.revision or adapterFingerprint ~= expectedSource.adapterFingerprint
				or placeFingerprint ~= expectedSource.placeFingerprint then
				return inconclusive("source-pin-mismatch")
			end
			local metrics = {}
			for _, metric in requiredMetrics do
				local value = rawget(metricValues, metric)
				if not positive(value) then return inconclusive("metric-missing-or-invalid") end
				metrics[metric] = value
			end
			caseRows[slot.pass][slot.role] = {
				measurementFingerprint = measurementFingerprint,
				compatibilityKey = compatibilityKey,
				metrics = metrics,
			}
		end
	end

	for _, caseId in normalized.cases do
		local caseRows = byCase[caseId]
		local reference = caseRows[1].baseline
		for _, pass in { 1, 2 } do
			for _, role in { "baseline", "control", "candidate" } do
				local row = caseRows[pass][role]
				if row.compatibilityKey ~= reference.compatibilityKey then
					return inconclusive("compatibility-mismatch")
				end
				if row.measurementFingerprint ~= reference.measurementFingerprint then
					return inconclusive("measurement-fingerprint-mismatch")
				end
			end
		end
	end

	local comparisons = {}
	local reasons = {}
	local seenReasons = {}
	local noisyControl = false
	local regression = false
	for _, caseId in normalized.cases do
		local caseRows = byCase[caseId]
		local requiredMetrics = metricsFor(caseId)
		for _, pass in { 1, 2 } do
			local passRows = caseRows[pass]
			for _, metric in requiredMetrics do
				local base = passRows.baseline.metrics[metric]
				local control = passRows.control.metrics[metric]
				local candidate = passRows.candidate.metrics[metric]
				local controlRatio = math.max(base, control) / math.min(base, control)
				local change = candidate / base - 1
				if not finite(controlRatio) or not finite(change) then return inconclusive("ratio-invalid") end
				if math.max(base, control) > math.min(base, control) * (1 + normalized.limits.maximumControlVariation) then
					noisyControl = true
					addReason(reasons, seenReasons, `control-variation:{caseId}:{pass}:{metric}`)
				end
				table.insert(comparisons, {
					caseId = caseId,
					pass = pass,
					metric = metric,
					baseline = base,
					candidate = candidate,
					changeFraction = change,
				})
				if metric == "wireBytesPerDelivery" then
					if candidate > base * (1 - normalized.limits.minimumWireSaving) then
						regression = true
						addReason(reasons, seenReasons, `insufficient-wire-saving:{caseId}:{pass}`)
					end
				elseif metric == "deliveredPerSecond" then
					if candidate < base * (1 - normalized.limits.maximumDeliveryRegression) then
						regression = true
						addReason(reasons, seenReasons, `delivery-regression:{caseId}:{pass}`)
					end
				elseif metric == "latencyP95Ms" or metric == "latencyP99Ms" then
					if candidate > base * (1 + normalized.limits.maximumLatencyRegression) then
						regression = true
						addReason(reasons, seenReasons, `latency-regression:{caseId}:{pass}:{metric}`)
					end
				elseif candidate > base * (1 + normalized.limits.maximumCostRegression) then
					regression = true
					addReason(reasons, seenReasons, `cost-regression:{caseId}:{pass}:{metric}`)
				end
			end
		end
	end
	if noisyControl then return report("Inconclusive", reasons, comparisons) end
	if regression then return report("Reject", reasons, comparisons) end
	return report("EligibleForReview", {}, comparisons)
end

local function summary(samples: any): any?
	local count = denseLength(samples, MAX_SUMMARY_SAMPLES)
	if count == nil or count == 0 then return nil end
	local sorted = table.create(count)
	local mean = 0
	for index = 1, count do
		local value = rawget(samples, index)
		if not finite(value) or value < 0 then return nil end
		sorted[index] = value
		mean += (value - mean) / index
	end
	if not finite(mean) then return nil end
	table.sort(sorted)
	local middle = math.floor(count / 2)
	local median = if count % 2 == 1 then sorted[middle + 1] else sorted[middle] / 2 + sorted[middle + 1] / 2
	return table.freeze({
		count = count,
		mean = mean,
		median = median,
		p95 = sorted[math.ceil(count * 0.95)],
		p99 = sorted[math.ceil(count * 0.99)],
	})
end

return table.freeze({ evaluate = evaluate, summary = summary })
