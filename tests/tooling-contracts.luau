local Project = require("../scripts/tooling/Project")
local Result = require("../scripts/tooling/Result")
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
