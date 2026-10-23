local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")
local Schema = require("../src/Schema")
local Budget = require("../scripts/analyze-schema-budget-core")
local Verification = require("../scripts/Verification")

local workspace = Verification.workspace("regression")
local token, definition = Definition.define({
	name = "BudgetAcceptance",
	version = 1,
	events = {
		Client = Schema.clientToServer(1, Schema.fields({ value = Schema.array(Schema.u8(), 1, 1) })),
		Fanout = Schema.serverToClient(2, Schema.fields({ value = Schema.array(Schema.u16(), 1, 1) })),
		Queued = Schema.serverToClient(3, Schema.fields({ values = Schema.array(Schema.u8(), 4, 0) }),
			{ queue = "Batch" }),
		Ordered = Schema.serverToClient(4, Schema.fields({ value = Schema.array(Schema.u8(), 1, 1) }),
			{ delivery = "OrderedUnreliable" }),
		Native = Schema.serverToClient(5, Schema.fields({ value = Schema.string(12) })),
		NativeZeroRate = Schema.serverToClient(6, Schema.fields({ value = Schema.string(12) })),
		NativeZeroFanout = Schema.serverToClient(7, Schema.fields({ value = Schema.string(12) })),
		InstanceQueue = Schema.serverToClient(8, Schema.fields({ target = Schema.Instance("Part") }),
			{ queue = "Batch" }),
	},
	requests = {
		Inspect = Schema.request(9, Schema.fields({ value = Schema.array(Schema.u8(), 1, 1) }), Schema.struct({ owned = Schema.boolean() })),
	},
})
assert(token ~= nil, definition and definition.message or "test schema must compile")
local report = assert(Definition.inspect(token))

local function workload()
	return {
		events = {
			Client = { sendsPerSecond = 2, recipients = 1, path = "Immediate" },
			Fanout = { sendsPerSecond = 3, recipients = 4, path = "Immediate" },
			Queued = { sendsPerSecond = 2, recipients = 1, path = "QueuedSingleRecord" },
			Ordered = { sendsPerSecond = 2, recipients = 1, path = "Immediate" },
			Native = { sendsPerSecond = 1, recipients = 1, path = "Immediate" },
			NativeZeroRate = { sendsPerSecond = 0, recipients = 1, path = "Immediate" },
			NativeZeroFanout = { sendsPerSecond = 1, recipients = 0, path = "Immediate" },
			InstanceQueue = { sendsPerSecond = 1, recipients = 3, path = "QueuedSingleRecord" },
		},
		requests = { Inspect = { callsPerSecond = 4, recipients = 1 } },
	}
end

local input = workload()
input.events.Native.sendsPerSecond = 0
local result, diagnostics = Budget.analyze(report, input)
assert(result ~= nil and #diagnostics == 0, "valid explicit workload")
local rows = result.endpoints
assert(rows["events.Client"].payloadBytes.minimum == 4 and rows["events.Client"].relayBufferBytes.maximum == 4)
assert(rows["events.Client"].relayBufferBytesPerSecond.minimum == 8
	and rows["events.Client"].relayBufferBytesPerSecond.maximum == 8)
assert(rows["events.Fanout"].relayBufferBytes.minimum == 5
	and rows["events.Fanout"].relayBufferBytesPerSecond.maximum == 60,
	"server event fanout multiplies the per-send buffer estimate")
assert(rows["events.Queued"].payloadBytes.minimum == 4 and rows["events.Queued"].payloadBytes.maximum == 8
	and rows["events.Queued"].relayBufferBytes.minimum == 9 and rows["events.Queued"].relayBufferBytes.maximum == 13
	and rows["events.Queued"].relayBufferBytesPerSecond.minimum == 18
	and rows["events.Queued"].relayBufferBytesPerSecond.maximum == 26,
	"queued exact body, record, and traffic ranges")
assert(rows["events.Queued"].payloadBytes.minimum == report.events.Queued.queuedBytes.bodyMinimum
	and rows["events.Queued"].payloadBytes.maximum == report.events.Queued.queuedBytes.bodyMaximum
	and rows["events.Queued"].relayBufferBytes.minimum == report.events.Queued.queuedBytes.singleRecordMinimum
	and rows["events.Queued"].relayBufferBytes.maximum == report.events.Queued.queuedBytes.singleRecordMaximum,
	"queued payload and single-record packet ranges use inspected bounds")
assert(rows["events.Queued"].payloadBytes.minimum < rows["events.Queued"].payloadBytes.maximum,
	"variable array bounds remain a range")
assert(rows["events.Ordered"].relayBufferBytes.minimum == 12
	and rows["events.Ordered"].relayBufferBytes.maximum == 12,
	"ordered inspected range already contains its frame wrapper")
assert(rows["events.Native"].representation == "NativeTuple" and rows["events.Native"].payloadBytes.minimum == "Unknown"
	and rows["events.Native"].relayBufferBytesPerSecond.maximum == 0)
assert(rows["events.NativeZeroRate"].payloadBytes.minimum == "Unknown"
	and rows["events.NativeZeroRate"].relayBufferBytesPerSecond.maximum == 0)
assert(rows["events.NativeZeroFanout"].relayBufferBytesPerSecond.maximum == 0,
	"unknown size multiplied by zero rate or fanout contributes zero")
assert(rows["events.InstanceQueue"].relayBufferBytes.maximum
	== report.events.InstanceQueue.queuedBytes.singleRecordMaximum
	and rows["events.InstanceQueue"].relayBufferBytes.maximum
	< report.events.InstanceQueue.queuedBytes.maximumAdmissionBytes,
	"queued buffer includes the reference index without admission sidecar charges")
assert(string.find(result.limitations, "sidecar admission charges are excluded", 1, true))
assert(rows["requests.Inspect"].direction == "ClientToServer"
	and rows["requests.Inspect"].requestPayloadBytes.minimum == 4
	and rows["requests.Inspect"].responsePayloadBytes.minimum == 4
	and rows["requests.Inspect"].requestRelayBufferBytes.minimum == 48
	and rows["requests.Inspect"].responseRelayBufferBytes.minimum == 48
	and rows["requests.Inspect"].payloadBytes.minimum == 8
	and rows["requests.Inspect"].relayBufferBytes.minimum == 96
	and rows["requests.Inspect"].relayBufferBytesPerSecond.minimum == 384,
	"RPC bodies are summed with one 44-byte envelope on each leg")

local activeUnknown = workload()
local unknownResult, unknownDiagnostics = Budget.analyze(report, activeUnknown, 1e100)
assert(unknownResult ~= nil and unknownResult.aggregate.relayBufferBytesPerSecond.maximum == "Unknown"
	and unknownResult.budget.status == "unknown" and unknownDiagnostics[1].code == "BudgetUnknown",
	"active NativeTuple size keeps a CI budget unknown")
assert(result.aggregate.payloadBytesPerSecond.minimum == 147 and result.aggregate.payloadBytesPerSecond.maximum == 155
	and result.aggregate.relayBufferBytesPerSecond.minimum == 527
	and result.aggregate.relayBufferBytesPerSecond.maximum == 535,
	"literal aggregate bounds include fanout, RPC envelopes, ordered frames, and queue records exactly once")
local exactMaximum = result.aggregate.relayBufferBytesPerSecond.maximum
local equalBudget, equalDiagnostics = Budget.analyze(report, input, exactMaximum)
assert(equalBudget.budget.status == "passed" and #equalDiagnostics == 0, "budget limit is inclusive")
local exceededBudget, exceededDiagnostics = Budget.analyze(report, input, exactMaximum - 1)
assert(exceededBudget.budget.status == "exceeded" and exceededDiagnostics[1].code == "BudgetExceeded")

local function rejects(candidate, code, budgetLimit)
	local _, issues = Budget.analyze(report, candidate, budgetLimit)
	for _, issue in issues do if issue.code == code then return end end
	error("expected workload diagnostic " .. code)
end

local invalid = workload()
invalid.events.Client = nil
rejects(invalid, "MissingEndpointAssumption")
invalid = workload()
invalid.events.Extra = { sendsPerSecond = 0, recipients = 1, path = "Immediate" }
rejects(invalid, "UnexpectedEndpointAssumption")
invalid = workload()
invalid.extra = true
rejects(invalid, "UnexpectedWorkloadField")
invalid = workload()
invalid.events.Client.extra = true
rejects(invalid, "UnexpectedWorkloadField")
invalid = workload()
invalid.events.Client.sendsPerSecond = -1
rejects(invalid, "InvalidRate")
invalid = workload()
invalid.events.Fanout.recipients = 1.5
rejects(invalid, "InvalidRecipients")
invalid = workload()
invalid.events.Client.recipients = 2
rejects(invalid, "InvalidRecipients")
invalid = workload()
invalid.requests.Inspect.recipients = 2
rejects(invalid, "InvalidRecipients")
invalid = workload()
invalid.events.Client.path = "Batch"
rejects(invalid, "InvalidPath")
invalid = workload()
invalid.events.Queued.path = "ImmediateButQueued"
rejects(invalid, "InvalidPath")
invalid = workload()
invalid.events.Client.path = nil
rejects(invalid, "InvalidPath")
invalid = workload()
setmetatable(invalid, {})
rejects(invalid, "InvalidWorkload")
invalid = workload()
setmetatable(invalid.events.Client, {})
rejects(invalid, "InvalidEndpointAssumption")
invalid = workload()
invalid.events.Client.sendsPerSecond = 1e308
rejects(invalid, "NumericOverflow")
rejects(workload(), "InvalidBudget", -1)

fs.writeFile(workspace.artifacts .. "/invalid-schema.luau", [[
return { name = "InvalidBudgetSchema", version = 1, events = {
	Broken = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "not-a-shape" } } },
} }
]])
fs.writeFile(workspace.artifacts .. "/invalid-workload.luau", [[ return { events = {}, requests = {} } ]])

local function run(arguments)
	local command = { "run", "scripts/analyze-schema-budget.luau" }
	for _, argument in arguments do table.insert(command, argument) end
	return process.exec("lune", command, { cwd = process.cwd, stdio = "default" })
end

local function json(arguments)
	local completed = run(arguments)
	return completed, serde.decode("json", completed.stdout)
end

local exampleSpec = "scripts/analyze-schema-budget-example-spec.luau"
local exampleWorkload = "scripts/analyze-schema-budget-example-workload.luau"
local example, exampleReport = json({ exampleSpec, exampleWorkload, "--json", "--max-bytes-per-second", "10000" })
assert(example.ok and exampleReport.schemaVersion == 1 and exampleReport.success
	and exampleReport.results.budget.status == "passed" and #exampleReport.diagnostics == 0,
	"documented workload example passes its CI budget")
assert(exampleReport.results.endpoints["events.NearbyState"].relayBufferBytes.maximum == 14
	and exampleReport.results.endpoints["events.InventoryDelta"].payloadBytes.minimum == 6,
	"documented example exercises ordered and queued inspected models")

local readable = run({ exampleSpec, exampleWorkload })
assert(readable.ok and string.find(readable.stdout, "Aggregate modeled Relay buffer bytes/s", 1, true)
	and string.find(readable.stdout, "Unknown", 1, true), "readable output shows aggregate units and unknown limits")
local usage, usageReport = json({ "--json" })
assert(not usage.ok and not usageReport.success and usageReport.diagnostics[1].code == "InvalidArguments"
	and string.find(usage.stdout, '"diagnostics":[]', 1, true) == nil)
local missingModule, missingReport = json({ "missing-schema-budget.luau", exampleWorkload, "--json" })
assert(not missingModule.ok and missingReport.diagnostics[1].code == "ModuleLoadFailed")
local absolute, absoluteReport = json({ "C:\\schema.luau", exampleWorkload, "--json" })
assert(not absolute.ok and absoluteReport.diagnostics[1].code == "AbsolutePathUnsupported")
local invalidSchema, invalidSchemaReport = json({ workspace.artifacts .. "/invalid-schema.luau", exampleWorkload, "--json" })
assert(not invalidSchema.ok and invalidSchemaReport.diagnostics[1].code == "InvalidDefinition")
local invalidInput, invalidInputReport = json({ exampleSpec,
	workspace.artifacts .. "/invalid-workload.luau", "--json" })
assert(not invalidInput.ok and invalidInputReport.diagnostics[1].code == "MissingEndpointAssumption")
assert(run({ "--help" }).ok)

workspace.cleanup()
fs.removeDir(workspace.root)
print("PASS offline schema budget arithmetic, workload validation, and CLI")
