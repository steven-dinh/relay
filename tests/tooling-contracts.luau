local Project = require("../scripts/tooling/Project")
local Paths = require("../scripts/tooling/Paths")
local Result = require("../scripts/tooling/Result")
local ResultJson = require("../scripts/tooling/ResultJson")
local process = require("@lune/process")
local Definition = require("../src/Definition")

local config = assert(Project.validate({ schemaVersion = 1, id = "combat", schema = "./schemas/../Spec.luau",
	policy = "Rates.luau", workload = "Workload.luau", tests = { "test.luau" }, typescript = "Network.d.ts" }))
assert(config.schema == "Spec.luau" and table.concat(config.required, ",") == "schema,policy,budget")
assert(config.tests[1] == "test.luau" and config.typescript == "Network.d.ts")
assert(not Project.validate({ schemaVersion = 1, id = "combat", schema = "../Spec.luau" }))
assert(not Project.validate({ schemaVersion = 1, id = "combat", schema = "Spec.luau", required = { "schema", "budget" } }))
assert(not Project.validate({ schemaVersion = 1, id = "combat", schema = "Spec.luau", requiredd = {} }))
assert(not Project.validate({ schemaVersion = 1, id = "combat", schema = "Spec.luau", required = { "policy" } }))
assert(Project.relativePath("C:\\Spec.luau", ".luau") == nil and Project.relativePath("Spec.luau:other", ".luau") == nil)

local longPathRequests = table.create(220)
for index = 1, 220 do
	longPathRequests[index] = { path = string.rep("x", 150) .. index .. ".luau", mustExist = false }
end
local longPathResults = Paths.resolveMany(process.cwd, longPathRequests)
assert(#longPathResults == #longPathRequests, "large path checks must return every result")
for index, path in longPathResults do
	assert(string.find(path, string.rep("x", 150) .. index .. ".luau", 1, true) ~= nil,
		"large path checks must preserve request order and content")
end

local identity = { projectId = "combat", compilerId = "compiler:one", toolingId = "tools:one",
	sourceId = "source:one", host = "cli", runId = "run:one" }
local schema = Result.new("schema", identity, "passed", { name = "combat" })
local unavailable = Result.new("budget", identity, "unsupported", nil,
	{ { code = "Unavailable", path = "budget", message = "No workload configured", severity = "info",
		action = "Configure a workload to use budget analysis" } })
assert(Result.aggregate("check", identity, { schema, unavailable }, { "schema" }).status == "passed")
assert(Result.aggregate("check", identity, { schema, unavailable }, { "schema", "budget" }).status == "unsupported")
local inconsistent = Result.aggregate("check", identity, { schema, unavailable }, { "schema", "budget" })
inconsistent.status = "passed"
assert(not Result.validate(inconsistent), "imported result cannot hide a required unsupported check")
assert(Result.aggregate("check", identity, { schema }, { "schema", "budget" }).status == "inconclusive")
local replacement = table.clone(identity)
replacement.runId = "run:two"
assert(not Result.isCurrent(schema, replacement) and Result.aggregate("check", replacement,
	{ schema }, { "schema" }).status == "stale", "same-input earlier jobs cannot replace a newer run")
local failed = Result.new("policy", identity, "failed", nil, { { code = "MissingEndpointRate", path = "policy",
	message = "Missing rate", severity = "error", action = "Declare the endpoint rate" } })
assert(Result.aggregate("check", identity, { schema, unavailable, failed }, { "schema", "budget", "policy" }).status == "failed"
	and Result.aggregate("check", identity, { schema, unavailable, failed }, { "schema", "policy", "budget" }).status == "failed")
local invalid = table.clone(schema)
invalid.diagnostics = failed.diagnostics
assert(not Result.validate(invalid), "a passed result cannot contain error diagnostics")
invalid = table.clone(schema)
invalid.status = "green"
assert(not Result.validate(invalid))

local rows = table.create(257, failed.diagnostics[1])
assert(not pcall(Result.new, "policy", identity, "failed", nil, rows))
local crowded = Result.new("policy", identity, "failed", nil, Result.limitDiagnostics(rows))
local crowdedCheck = Result.aggregate("check", identity, { crowded }, { "policy" })
local changed = Result.diagnostic("SourceChanged", "project", "Source changed.")
Result.markStale(crowdedCheck, changed)
Result.markStale(crowdedCheck, changed)
assert(Result.validate(crowdedCheck) and #crowded.diagnostics == 256 and crowded.diagnostics[1].code == "SourceChanged"
	and crowded.diagnostics[256].omittedCount == 3, "repeated freshness checks preserve the bounded omission count")
local maps = ResultJson.result(Result.new("schema", identity, "passed", { tests = {}, diagnostics = {} }))
assert(string.find(maps, '"data":{"diagnostics":{},"tests":{}}', 1, true)
	and string.find(maps, '"diagnostics":[]', 1, true), "only schema-defined arrays should encode as arrays")
local emptyBudget = ResultJson.result(Result.new("budget", identity, "passed", { endpoints = {} }))
local emptyCompat = ResultJson.result(Result.new("compat", identity, "passed", { before = { endpoints = {} }, changes = {} }))
assert(string.find(emptyBudget, '"endpoints":{}', 1, true) and string.find(emptyCompat, '"endpoints":{}', 1, true)
	and string.find(emptyCompat, '"changes":[]', 1, true), "budget and compatibility endpoint maps remain objects")
local compatEndpoint = { id = 2, kind = "event", fields = { { type = "struct", fields = {} } } }
local changedCompat = Result.new("compat", identity, "failed", { after = { endpoints = { ["2"] = compatEndpoint } },
	changes = { { path = "endpoints[2]", kind = "added", after = compatEndpoint } } })
local compatJson = ResultJson.result(Result.aggregate("check", identity, { changedCompat }, { "compat" }))
local _, fieldLists = string.gsub(compatJson, '"fields":%[%]', "")
assert(fieldLists == 2 and string.find(compatJson, '"endpoints":{"2":', 1, true),
	"both compatibility snapshots and changes preserve nested empty struct fields")
invalid = table.clone(schema)
invalid.data = {}; invalid.data.self = invalid.data
assert(not Result.validate(invalid))

-- Inspect summarizes shape depth/counts rather than recursively serializing them.
-- Duplicating full event/RPC rows in both maps conservatively exceeds the total 64-endpoint cap.
local s = require("../src/Schema")
local references = s.array(s.Instance("BasePart"), 16)
local definition, problem = Definition.define({ name = "ToolBounds", version = 1,
	outboundBytes = { capacity = 4096, refillPerSecond = 1024 },
	events = { Input = s.clientToServer(1, s.fields({ serverTime = s.f64(0, 2^40) }, { refs = references }),
		{ queue = "State", timestampWindow = 1 }) },
	requests = { Query = s.request(2, s.fields({ refs = references }), references, { concurrency = 8, refusals = true }) },
})
assert(definition, problem and problem.message)
local inspected = assert(Definition.inspect(definition))
local report = table.clone(inspected)
report.events, report.requests = {}, {}
for id = 1, 64 do
	local name = string.rep("E", 29) .. string.format("%03d", id)
	report.events[name], report.requests[name] = inspected.events.Input, inspected.requests.Query
end
local record = Result.new("schema", identity, "passed", report)
assert(Result.validate(record) and #require("@lune/serde").encode("json", record) < Result.MAX_BYTES)
print("PASS Relay Tools project/result contracts and endpoint report bounds")
