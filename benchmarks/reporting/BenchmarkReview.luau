--!strict

-- Offline claim guard: reuse study validation; never grant a performance winner.
local process = require("@lune/process")
local Report = require("./BroadcastStudyReport")
local Study = require("../host/BroadcastStudy")

local function code(message: any): string
	return string.match(tostring(message), "BCAST_[A-Z_]+") or "BENCH_REVIEW_E_VALIDATION"
end

local function parseArgs(arguments: { string }): any
	assert(#arguments == 4 or #arguments == 8, "BENCH_REVIEW_E_ARGS")
	local options = {}
	for index = 1, #arguments, 2 do
		local key, value = arguments[index], arguments[index + 1]
		assert((key == "--ledger" or key == "--maximum-control-drift" or key == "--current-root" or key == "--source-role")
			and options[key] == nil and type(value) == "string" and #value > 0, "BENCH_REVIEW_E_ARGS")
		options[key] = value
	end
	local threshold = tonumber(options["--maximum-control-drift"])
	assert(options["--ledger"] ~= nil and threshold ~= nil and threshold == threshold
		and threshold >= 0 and threshold < math.huge, "BENCH_REVIEW_E_ARGS")
	assert((options["--current-root"] == nil and options["--source-role"] == nil)
		or (options["--current-root"] ~= nil and (options["--source-role"] == "baseline" or options["--source-role"] == "candidate")),
		"BENCH_REVIEW_E_ARGS")
	return { ledgerPath = options["--ledger"], maximumControlDrift = threshold,
		currentRoot = options["--current-root"], sourceRole = options["--source-role"] }
end

local function assess(options: any, reader: any?, execute: any?): any
	local result = { schema = "Relay.BenchmarkReview", version = 1, state = "Blocked", rankingEligible = false,
		reasons = {}, sourceRelationship = "NotCompared", cpuAttribution = "Unqualified", packetAttribution = "Unqualified",
		limitations = {
			"A revision match does not verify ignored artifacts, built places or the current engine.",
			"Archive replay does not measure current performance or qualify CPU/packet captures.",
			"The supplied tolerance does not prove predeclaration or statistical significance.",
			"Two ordered launches per role are diagnostics, not a rigorous campaign.",
		} }
	local run = execute or process.exec
	local initialOk, initial
	if options.currentRoot ~= nil then
		initialOk, initial = pcall(Study.sourceIdentity, options.currentRoot, run)
	end
	local ok, report = pcall(Report.report, options.ledgerPath, options.maximumControlDrift, reader)
	if not ok then
		table.insert(result.reasons, code(report))
		return result
	end
	result.report = report
	result.state = if report.controlAssessment == "WithinThreshold" then "DiagnosticsOnly" else "Inconclusive"
	if result.state == "Inconclusive" then table.insert(result.reasons, "CONTROL_" .. report.controlAssessment) end
	if options.currentRoot ~= nil then
		local finalOk, final = pcall(Study.sourceIdentity, options.currentRoot, run)
		local recorded = nil
		for _, attempt in report.attempts do
			if attempt.label == options.sourceRole then recorded = attempt.source.revision; break end
		end
		result.currentSource = { root = options.currentRoot, role = options.sourceRole, recordedRevision = recorded,
			initialRevision = if initialOk then initial.revision else nil, finalRevision = if finalOk then final.revision else nil }
		local reason = if not initialOk then code(initial) elseif not finalOk then code(final)
			elseif recorded == nil then "SOURCE_ROLE_MISSING"
			elseif initial.revision ~= final.revision then "SOURCE_CHANGED_DURING_REVIEW"
			elseif final.revision ~= recorded then "SOURCE_REVISION_MISMATCH" else nil
		if reason ~= nil then
			result.sourceRelationship = "Unestablished"
			result.state = "Inconclusive"
			table.insert(result.reasons, reason)
		else
			result.sourceRelationship = "CleanRevisionMatch"
		end
	end
	return result
end

return table.freeze({ parseArgs = parseArgs, assess = assess })
