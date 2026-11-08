local Definition = require("../src/Definition")
local Result = require("../scripts/tooling/Result")
local Project = require("../scripts/tooling/Project")
local Schema = require("../src/Schema")
local Diagnosis = require("../scripts/studio-inspector/Diagnosis")
local Structured = require("../scripts/studio-inspector/Structured")

local identity = {
	projectId = "diagnosis-test", compilerId = "compiler:test", toolingId = "tooling:test",
	sourceId = "source:test", host = "cli", runId = "run:one",
}
local spec = {
	name = "DiagnosisTest", version = 1,
	events = { Input = Schema.clientToServer(1, Schema.fields({ value = Schema.u8() })) },
	requests = { Lookup = Schema.request(3, Schema.fields({ key = Schema.u8() }), Schema.boolean()) },
}
local definition = assert(Definition.define(spec))
local inspection = assert(Definition.inspect(definition))
local structuredInspection = assert(Structured.inspection(inspection))
local schemaResult = Result.new("schema", identity, "passed", inspection)
local common = Result.aggregate("check", identity, { schemaResult }, { "schema" })
common.data = {
	project = assert(Project.validate({
		schemaVersion = 1, id = identity.projectId, schema = "src/Spec.luau", policy = "Policy.luau",
		baseline = "Baseline.luau", workload = "Workload.luau", tests = { "tests/Scenario.luau" },
		typescript = "Relay.d.ts",
	})),
}
common.diagnostics = {
	{ severity = "warning", code = "SourceChanged", path = "src/Spec.luau",
		message = "The source declaration changed during the check", action = "Rerun the project check" },
	{ severity = "warning", code = "GeneratedOutputStale", path = "Relay.d.ts",
		message = "declaration output does not match the current schema",
		action = "Preview with generate, then use generate --write after reviewing the intended output." },
}
assert(Result.validate(common), "common captured check is valid")

local record = {
	format = 2,
	sessionId = "00000000-0000-4000-8000-000000000001",
	association = "constructed",
	identityStatus = "application-supplied",
	label = "Diagnosis session",
	projectId = identity.projectId,
	compilerId = identity.compilerId,
	toolingId = identity.toolingId,
	sourceId = identity.sourceId,
	inspection = structuredInspection,
	liveText = "Relay Studio Inspector v1\n  Last start failure: DescriptorVerification [DefinitionMismatch]\n  #1 / Reliable QueueFull x2",
	history = { "Sample t=1.000s | side=Server | state=Started" },
	scalars = {
		side = "Server", state = "Started", inFlight = 2,
		["failure.DefinitionMismatch"] = 1,
		["session.perPlayerRate"] = 1,
		["session.aggregateRate"] = 0,
		["session.perPlayerBytes"] = 0,
		["session.aggregateBytes"] = 0,
		["session.endpointRate"] = 1,
		["session.invalidEndpoint"] = 0,
		["session.outboundByteRejected"] = 0,
		["session.outboundBytesCharged"] = 650,
		["traffic.Reliable.sentBytes"] = 180,
		["traffic.Reliable.receivedBytes"] = 70,
		["traffic.Unreliable.sentBytes"] = 0,
		["traffic.Unreliable.receivedBytes"] = 0,
	},
	elapsed = 3,
}
assert(Structured.validate(record), "live registration record is valid")
local missingRequiredScalars = table.clone(record)
missingRequiredScalars.scalars = {}
local missingScalarsText = Diagnosis.render(missingRequiredScalars, common)
assert(not Structured.validate(missingRequiredScalars)
    and string.find(missingScalarsText, "Live diagnosis unavailable: structured record is absent or invalid.", 1, true),
    "malformed v2 scalars stay out of diagnosis formatting")

local previous = table.clone(record)
previous.scalars = table.clone(record.scalars)
previous.elapsed = 2
previous.scalars["traffic.Reliable.sentBytes"] = 100
previous.scalars["traffic.Reliable.receivedBytes"] = 40
previous.scalars["session.outboundBytesCharged"] = 500

local text = Diagnosis.render(record, common, previous)
for _, hint in {
	"captured inspection summary and endpoint roster match (advisory only)",
	"schema: src/Spec.luau", "policy: Policy.luau", "baseline: Baseline.luau",
	"workload: Workload.luau", "typescript: Relay.d.ts", "test scenario: tests/Scenario.luau",
	"Startup mismatch observed: DefinitionMismatch", "Per-player call rate refusals: 1",
	"Queue pressure observed: QueueFull", "Source freshness diagnostic (SourceChanged):",
	"Stale declaration diagnostic (GeneratedOutputStale): declaration output does not match the current schema",
	"Preview with generate, then use generate --write after reviewing the intended output.", "Rerun the project check",
	"Reliable sentBytes: 80 modeled content units/sec",
	"Reliable receivedBytes: 30 modeled content units/sec",
	"outboundBytesCharged: 150 reservation units/sec", "In-flight handlers: 2 (gauge",
} do
	assert(string.find(text, hint, 1, true), "diagnosis includes " .. hint)
end
assert(#text < Diagnosis.MAX_TEXT_BYTES, "diagnosis stays below its display limit")
assert(not string.find(text, "Last start failure:", 1, true)
	and not string.find(text, "#1 / Reliable", 1, true), "diagnosis does not render raw live log text")

local textOnlyMismatch = table.clone(record)
textOnlyMismatch.scalars = table.clone(record.scalars)
textOnlyMismatch.scalars["failure.DefinitionMismatch"] = 0
assert(string.find(Diagnosis.render(textOnlyMismatch, common), "Startup mismatch observed: DefinitionMismatch", 1, true),
	"the allowlisted formatted startup failure line is recognized")
local nameOnlyMismatch = table.clone(textOnlyMismatch)
nameOnlyMismatch.label = "DefinitionMismatch example"
nameOnlyMismatch.liveText = "Relay Studio Inspector v1\nAttachment: DefinitionMismatch example"
assert(not string.find(Diagnosis.render(nameOnlyMismatch, common), "Startup mismatch observed", 1, true),
	"names containing the error code do not create a startup mismatch signal")

local mismatchedIdentity = table.clone(record)
mismatchedIdentity.compilerId = "compiler:other"
local identityText = Diagnosis.render(mismatchedIdentity, common)
assert(string.find(identityText, "declared compilerId differs", 1, true)
	and not string.find(identityText, "captured inspection summary and endpoint roster match", 1, true)
	and not string.find(identityText, "Policy path:", 1, true)
	and not string.find(identityText, "Scenario path:", 1, true),
	"all declared identity fields must match before association")

local mismatchedEndpoint = table.clone(record)
mismatchedEndpoint.inspection = table.clone(record.inspection)
mismatchedEndpoint.inspection.events = table.clone(record.inspection.events)
mismatchedEndpoint.inspection.events[1] = table.clone(record.inspection.events[1])
mismatchedEndpoint.inspection.events[1].direction = "ServerToClient"
local endpointText = Diagnosis.render(mismatchedEndpoint, common)
assert(string.find(endpointText, "captured inspection summary or endpoint roster differs", 1, true),
	"endpoint direction mismatch prevents a declared association")

local resetPrevious = table.clone(previous)
resetPrevious.scalars = table.clone(previous.scalars)
resetPrevious.scalars["traffic.Reliable.sentBytes"] = 190
assert(string.find(Diagnosis.render(record, common, resetPrevious), "Reliable sentBytes: unavailable (counter reset)", 1, true),
	"counter reset invalidates an exact rate")

local saturated = table.clone(record)
saturated.scalars = table.clone(record.scalars)
saturated.scalars["traffic.Reliable.sentBytes"] = 4_294_967_295
local saturatedPrevious = table.clone(previous)
saturatedPrevious.scalars = table.clone(previous.scalars)
saturatedPrevious.scalars["traffic.Reliable.sentBytes"] = 4_294_967_295
assert(string.find(Diagnosis.render(saturated, common, saturatedPrevious),
	"Reliable sentBytes: unavailable (counter saturated)", 1, true), "saturated counters have no exact rate")

local replacedPrevious = table.clone(previous)
replacedPrevious.sessionId = "00000000-0000-4000-8000-000000000002"
assert(string.find(Diagnosis.render(record, common, replacedPrevious), "attachment/session was replaced", 1, true),
	"different attachment sessions cannot be compared")

print("PASS Relay Studio connected diagnosis")
