local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")

local workspace = Verification.workspace("regression")
local specs = workspace.artifacts .. "/schema fixture.luau"
local badSpec = workspace.artifacts .. "/invalid.luau"
local rates = workspace.artifacts .. "/inbound rates.luau"
local missing = workspace.artifacts .. "/missing rates.luau"

fs.writeFile(specs, [[
local s = require("../../../../src/Schema")
return {
	name = "OfflineCheck",
	version = 1,
	outboundBytes = { capacity = 128, refillPerSecond = 64 },
	events = {
		Input = s.clientToServer(1, s.fields({ values = s.array(s.u8(), 3) })),
		Output = s.serverToClient(2, s.fields({ value = s.string(16) })),
	},
	requests = {
		Inspect = s.request(3, s.fields({ itemId = s.u16() }), s.struct({ owned = s.boolean() })),
	},
}
]])
fs.writeFile(badSpec, [[
return {
	name = "InvalidOfflineCheck",
	version = 1,
	events = {
		Broken = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "unsupported" } } },
	},
}
]])
fs.writeFile(rates, [[
return {
	perPlayer = { capacity = 64, refillPerSecond = 32 },
	aggregate = { capacity = 256, refillPerSecond = 128 },
	endpoints = {
		[1] = { capacity = 32, refillPerSecond = 16 },
		[3] = { capacity = 8, refillPerSecond = 4 },
	},
}
]])
fs.writeFile(missing, [[
return {
	perPlayer = { capacity = 64, refillPerSecond = 32 },
	aggregate = { capacity = 256, refillPerSecond = 128 },
	endpoints = { [1] = { capacity = 32, refillPerSecond = 16 } },
}
]])

local function run(arguments)
	local command = { "run", "scripts/check-schema.luau" }
	for _, argument in arguments do table.insert(command, argument) end
	return process.exec("lune", command, { cwd = process.cwd, stdio = "default" })
end

local function json(arguments)
	local result = run(arguments)
	return result, serde.decode("json", result.stdout)
end

local good, report = json({ specs, "--json", "--require-endpoint-rates", rates })
assert(good.ok and report.schemaVersion == 1 and report.success, "valid helper-authored schema and rates")
assert(string.find(good.stdout, '"diagnostics":[]', 1, true), "empty JSON diagnostics remain an array")
assert(report.definition.name == "OfflineCheck" and report.definition.events.Input.direction == "ClientToServer")
assert(report.definition.outboundBytes.capacity == 128, "inspection policy fields are retained")
assert(report.definition.events.Input.bytes.representation == "RelayBuffer"
	and report.definition.events.Input.bytes.maximum > 0, "codec bounds are reported")
assert(report.definition.events.Output.bytes.representation == "NativeTuple"
	and report.definition.events.Output.bytes.robloxEncodedBytes == "Unknown", "native size stays unknown")

local example, exampleReport = json({ "examples/reliable-events/Spec.luau", "--json" })
assert(example.ok and exampleReport.success and #exampleReport.diagnostics == 0,
	"shipped reliable-events spec loads in the offline checker")
assert(exampleReport.definition.name == "Gameplay" and exampleReport.definition.version == 1
	and exampleReport.definition.events.Input.id == 1
	and exampleReport.definition.events.State.id == 2, "shipped endpoint IDs remain stable")

local missingResult, missingReport = json({ specs, "--json", "--require-endpoint-rates", missing })
assert(not missingResult.ok and not missingReport.success and #missingReport.diagnostics == 1)
assert(missingReport.diagnostics[1].code == "MissingEndpointRate"
	and missingReport.diagnostics[1].path == "inboundRate.endpoints[3]"
	and string.find(missingReport.diagnostics[1].message, "requests.Inspect", 1, true))

fs.writeFile(missing, [[
return {
	endpoints = {
		[1] = { capacity = 4097, refillPerSecond = 16 },
		[3] = { capacity = 8, refillPerSecond = 4 },
		[2] = { capacity = 8, refillPerSecond = 4 },
	},
}
]])
local invalidRateResult, invalidRateReport = json({ specs, "--json", "--require-endpoint-rates", missing })
assert(not invalidRateResult.ok and #invalidRateReport.diagnostics == 2)
assert(invalidRateReport.diagnostics[1].code == "InvalidEndpointRate"
	and invalidRateReport.diagnostics[1].path == "inboundRate.endpoints[1]")
assert(invalidRateReport.diagnostics[2].code == "UnexpectedEndpointRate"
	and invalidRateReport.diagnostics[2].path == "inboundRate.endpoints[2]", "outbound rates are rejected")

local invalidResult, invalidReport = json({ badSpec, "--json" })
assert(not invalidResult.ok and invalidReport.diagnostics[1].code == "InvalidDefinition")
assert(string.find(invalidReport.diagnostics[1].path, "events.Broken", 1, true)
	and #invalidReport.diagnostics[1].message > 0, "compiler path and reason are preserved")

local loadResult, loadReport = json({ workspace.artifacts .. "/absent.luau", "--json" })
assert(not loadResult.ok and loadReport.diagnostics[1].code == "ModuleLoadFailed")
local usageAfterSpecResult, usageAfterSpec = json({ specs, "--require-endpoint-rates", "--json" })
assert(not usageAfterSpecResult.ok and usageAfterSpec.schemaVersion == 1
	and usageAfterSpec.diagnostics[1].code == "InvalidArguments", "JSON remains enabled after a missing policy path")
local usageBeforeSpecResult, usageBeforeSpec = json({ "--require-endpoint-rates", "--json" })
assert(not usageBeforeSpecResult.ok and usageBeforeSpec.schemaVersion == 1
	and usageBeforeSpec.diagnostics[1].code == "InvalidArguments", "JSON remains enabled before a schema path")
assert(not run({ specs, "--unknown" }).ok, "unknown options exit unsuccessfully")
assert(run({ "--help" }).ok, "help exits successfully")

workspace.cleanup()
fs.removeDir(workspace.root)
print("PASS offline schema diagnostics and endpoint-rate coverage")
