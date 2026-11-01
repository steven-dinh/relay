local serde = require("@lune/serde")
local Budget = require("../scripts/analyze-schema-budget-core")
local Compatibility = require("../scripts/schema-compatibility-core")
local Definition = require("../src/Definition")
local Result = require("../scripts/tooling/Result")
local Schema = require("../src/Schema")
local Workspace = require("../scripts/studio-inspector/Workspace")

local identity = {
    projectId = "workspace-test", compilerId = "compiler:test", toolingId = "tooling:test",
    sourceId = "source:test", host = "cli", runId = "run:one",
}
local spec = {
    name = "WorkspaceTest", version = 1,
    events = {
        Input = Schema.clientToServer(1, Schema.fields({ value = Schema.u16() })),
        Output = Schema.serverToClient(2, Schema.fields({ enabled = Schema.boolean() })),
    },
    requests = {
        Lookup = Schema.request(3, Schema.fields({ key = Schema.u16() }), Schema.boolean()),
    },
}
local definition = assert(Definition.define(spec))
local inspection = assert(Definition.inspect(definition))
local schemaResult = Result.new("schema", identity, "passed", inspection)
local encoded = serde.encode("json", schemaResult)
local decoded = assert(Workspace.decode(encoded, function(bytes) return serde.decode("json", bytes) end))
local schemaText = Workspace.render(decoded, "Schema")
for _, field in { "Captured CLI report; Studio source freshness is unverified", "Project: workspace-test",
    "Compiler: compiler:test", "Tooling: tooling:test", "Source: source:test", "Host: cli", "Run: run:one",
    "Status: passed", "Event #1 Input", "Event #2 Output", "Request #3 Lookup", "NativeTuple",
    "Roblox-encoded and physical wire byte sizes are Unknown" } do
    assert(string.find(schemaText, field, 1, true), "schema view includes " .. field)
end
assert(#schemaText <= Workspace.MAX_TEXT_BYTES)

local called = false
local tooLarge, tooLargeError = Workspace.decode(string.rep("x", Result.MAX_BYTES + 1), function()
    called = true
    error("decoder should not run")
end)
assert(tooLarge == nil and tooLargeError ~= nil and not called, "serialized byte limit is enforced before decode")
local malformed = Workspace.decode("{", function(bytes) return serde.decode("json", bytes) end)
assert(malformed == nil, "malformed JSON is rejected")

local changedSpec = table.clone(spec)
changedSpec.name = "WorkspaceTestNext"
local before = assert(Compatibility.inspect(Definition, spec, "Spec.luau", "before"))
local after = assert(Compatibility.inspect(Definition, changedSpec, "Spec.luau", "after"))
local changes = Compatibility.compare(before, after)
local compatible = Result.new("compat", identity, "failed", {
    status = "changed", before = before, after = after, descriptorEqual = false,
    requiresMatchedDeployment = true, changes = changes,
})
local compatText = Workspace.render(compatible, "Schema")
assert(string.find(compatText, "Raw-schema compatibility: changed", 1, true)
    and string.find(compatText, "Advisory only: raw-schema comparison does not establish deployed-peer compatibility.", 1, true)
    and not string.find(compatText, before.descriptor, 1, true),
    "compatibility view is advisory and never prints descriptor text")

local budget, budgetDiagnostics = Budget.analyze(inspection, {
    events = {
        Input = { sendsPerSecond = 5, recipients = 1, path = "Immediate" },
        Output = { sendsPerSecond = 2, recipients = 1, path = "Immediate" },
    },
    requests = { Lookup = { callsPerSecond = 1, recipients = 1 } },
}, nil)
assert(budget and #budgetDiagnostics == 0)
local budgetText = Workspace.render(Result.new("budget", identity, "passed", budget), "Checks")
assert(string.find(budgetText, "Aggregate payload bytes/sec", 1, true)
    and string.find(budgetText, "NativeTuple sizes", 1, true)
    and string.find(budgetText, "physical wire bytes are Unknown", 1, true),
    "budget view retains modeled bounds and explicit exclusions")

local failed = Result.new("policy", identity, "failed", nil, {
    { severity = "error", code = "MissingEndpointRate", path = "inboundRate.endpoints[1]",
        message = "Declare an endpoint rate", action = "Add a bucket for endpoint 1" },
})
local problems = Workspace.render(failed, "Problems")
assert(string.find(problems, "Next action: Add a bucket for endpoint 1", 1, true),
    "problem view includes the actionable diagnostic")
local aggregate = Result.aggregate("check", identity,
    { schemaResult, failed, Result.new("budget", identity, "passed", budget) }, { "schema", "policy", "budget" })
aggregate.data = { project = { schemaVersion = 1, id = identity.projectId, schema = "Spec.luau" } }
assert(string.find(Workspace.render(aggregate, "Problems"), "Add a bucket for endpoint 1", 1, true)
    and string.find(Workspace.render(aggregate, "Checks"), "Aggregate payload bytes/sec", 1, true)
    and string.find(Workspace.render(aggregate, "Overview"), "Schema path: Spec.luau", 1, true),
    "aggregate views expose child diagnostics, budget details and the selected project projection")
local manyDiagnostics = {}
for _ = 1, 256 do
    table.insert(manyDiagnostics, { severity = "error", code = "LargeProblem", path = "schema",
        message = string.rep("m", 1024), action = string.rep("a", 1024) })
end
local boundedProblems = Workspace.render(Result.new("schema", identity, "failed", nil, manyDiagnostics), "Problems")
assert(#boundedProblems <= Workspace.MAX_TEXT_BYTES and string.find(boundedProblems, "view truncated", 1, true),
    "problem view stays within its 64 KiB display limit")

local unsupported = Result.new("budget", identity, "unsupported", nil, {
    { severity = "info", code = "Unavailable", path = "budget", message = "No workload configured",
        action = "Configure a workload" },
})
local requiredUnsupported = Result.aggregate("check", identity, { schemaResult, unsupported }, { "schema", "budget" })
local unsupportedText = Workspace.render(requiredUnsupported, "Checks")
assert(string.find(unsupportedText, "Status: unsupported", 1, true)
    and string.find(unsupportedText, "budget: unsupported (required)", 1, true),
    "required unsupported checks remain visible")

local newerIdentity = table.clone(identity)
newerIdentity.runId = "run:two"
local stale = Result.aggregate("check", newerIdentity, { schemaResult }, { "schema" })
local staleText = Workspace.render(stale, "Checks")
assert(string.find(staleText, "Status: stale", 1, true)
    and string.find(staleText, "schema: stale (required)", 1, true),
    "required child identity mismatch is rendered as stale")

print("PASS Relay Studio captured workspace reports")
