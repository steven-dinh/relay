local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")

local workspace = Verification.workspace("regression")
local prefix = 'local s = require("../../../../src/Schema")\nreturn '
local paths = {}

local function write(name, body)
	local path = workspace.artifacts .. "/" .. name .. ".luau"
	fs.writeFile(path, prefix .. body)
	paths[name] = path
	return path
end

local base = [[{
	name = "Compared",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ id = s.u16() }, { details = s.struct({ count = s.u8() }) })),
		Output = s.serverToClient(2, s.fields({ enabled = s.boolean() })),
	},
	requests = {
		Lookup = s.request(3, s.fields({ key = s.string(8) }), s.struct({ count = s.u8() })),
	},
}]]
local baseline = write("before schema", base)
write("same", base)
write("normalized", [[{
	name = "Compared",
	version = 1,
	events = {
		Output = s.serverToClient(2, s.fields({ enabled = s.boolean() }), { delivery = "Reliable" }),
		Input = s.clientToServer(1, s.fields({ id = s.u16() }, { details = s.struct({ count = s.u8() }) }),
			{ delivery = "Reliable" }),
	},
	requests = {
		Lookup = s.request(3, s.fields({ key = s.string(8) }), s.struct({ count = s.u8() }),
			{ direction = "ClientToServer", concurrency = 1, refusals = false }),
	},
}]] )
write("widened", string.gsub(base, "count = s.u8%(%)", "count = s.u16()", 1))
write("renamed field", string.gsub(base, "id = s.u16%(%)", "itemId = s.u16()", 1))
write("changed id", string.gsub(base, "clientToServer%(1,", "clientToServer(4,", 1))
write("changed direction", string.gsub(base, "clientToServer%(1,", "serverToClient(1,", 1))
write("renamed endpoint", string.gsub(base, "Input =", "Moved =", 1))
write("extended metadata", [[{
	name = "Compared",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ serverTime = s.f64(0, 2 ^ 41) }, { id = s.u16() }),
			{ timestampWindow = 0.5 }),
		Output = s.serverToClient(2, s.fields({ enabled = s.boolean() })),
	},
	requests = {
		Lookup = s.request(3, s.fields({ key = s.string(8) }), s.struct({ count = s.u8() }),
			{ direction = "ServerToClient", concurrency = 2, refusals = true }),
	},
}]])
write("changed request", [[{
	name = "Compared",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ id = s.u16() }, { details = s.struct({ count = s.u8() }) })),
		Output = s.serverToClient(2, s.fields({ enabled = s.boolean() })),
	},
	requests = {
		Lookup = s.request(3, s.fields({ key = s.string(9) }), s.struct({ count = s.u16() })),
	},
}]])

local policy = [[{
	name = "ComparedNext",
	version = 2,
	readiness = true,
	bitPacking = true,
	outboundBytes = { capacity = 64, refillPerSecond = 32 },
	events = {
		Input = s.clientToServer(1, s.fields({ id = s.u16() }, { details = s.struct({ count = s.u8() }) })),
		Output = s.serverToClient(2, s.fields({ enabled = s.boolean() }), { delivery = "Unreliable", queue = "State" }),
	},
	requests = {
		Lookup = s.request(3, s.fields({ key = s.string(8) }), s.struct({ count = s.u8() })),
	},
}]]
write("policy", policy)
write("added endpoint", [[{
	name = "Compared",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ id = s.u16() }, { details = s.struct({ count = s.u8() }) })),
		Output = s.serverToClient(2, s.fields({ enabled = s.boolean() })),
		Added = s.serverToClient(4, s.fields({ value = s.u8() })),
	},
	requests = { Lookup = s.request(3, s.fields({ key = s.string(8) }), s.struct({ count = s.u8() })) },
}]])
write("invalid schema", [[{
	name = "Bad",
	version = 1,
	events = { Broken = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "unsupported" } } } },
}]])
local invalidModule = workspace.artifacts .. "/invalid return.luau"
fs.writeFile(invalidModule, "return 42")

local function run(arguments)
	local command = { "run", "scripts/schema-compatibility.luau" }
	for _, argument in arguments do table.insert(command, argument) end
	return process.exec("lune", command, { cwd = process.cwd, stdio = "default" })
end

local function compare(left, right)
	local result = run({ left, right, "--json" })
	return result, serde.decode("json", result.stdout)
end

local function hasPath(report, path)
	for _, change in report.changes do if change.path == path then return change end end
	return nil
end

local identical, sameReport = compare(baseline, paths.same)
assert(identical.code == 0 and sameReport.status == "equal" and sameReport.descriptorEqual
	and sameReport.requiresMatchedDeployment == false and #sameReport.changes == 0,
	"identical definitions compare equal with empty arrays")
assert(string.find(identical.stdout, '"changes":[]', 1, true)
	and string.find(identical.stdout, '"diagnostics":[]', 1, true))

local normalizedResult, normalizedReport = compare(baseline:gsub("/", "\\"), paths.normalized)
assert(normalizedResult.code == 0 and normalizedReport.status == "equal",
	"map order and omitted/default Reliable and RPC metadata normalize to the same descriptor")
assert(normalizedReport.before.source == string.gsub(baseline, "\\", "/"), "backslashes normalize in reported paths")
assert(normalizedReport.before.inspection.events.Output.bytes.robloxEncodedBytes == "Unknown",
	"unknown native encoding sizes remain explicit")

local widenedResult, widened = compare(baseline, paths.widened)
assert(widenedResult.code == 1 and widened.status == "changed" and widened.descriptorEqual == false
	and widened.requiresMatchedDeployment == true and hasPath(widened, "endpoints[1].fields[2].fields[1].maximum"),
	"payload widening is changed and requires a matched deployment")
local renamedResult, renamed = compare(baseline, paths["renamed field"])
assert(renamedResult.code == 1 and hasPath(renamed, "endpoints[1].fields[1].name"))

local idResult, idReport = compare(baseline, paths["changed id"])
assert(idResult.code == 1 and hasPath(idReport, "endpoints[1]").kind == "removed"
	and hasPath(idReport, "endpoints[4]").kind == "added", "ID changes show endpoint removal and addition")
local directionResult, direction = compare(baseline, paths["changed direction"])
assert(directionResult.code == 1 and hasPath(direction, "endpoints[1].direction"), "direction changes are reported")
local endpointNameResult, endpointName = compare(baseline, paths["renamed endpoint"])
assert(endpointNameResult.code == 1 and hasPath(endpointName, "endpoints[1].name"),
	"same-ID endpoint renames are reported")
local extendedResult, extended = compare(baseline, paths["extended metadata"])
assert(extendedResult.code == 1 and hasPath(extended, "endpoints[1].timestampWindow")
	and hasPath(extended, "endpoints[3].direction") and hasPath(extended, "endpoints[3].concurrency")
	and hasPath(extended, "endpoints[3].refusals") and hasPath(extended, "endpoints[3].envelopeVersion"),
	"timestamp and extended request policies are reported")
local requestResult, request = compare(baseline, paths["changed request"])
assert(requestResult.code == 1 and hasPath(request, "endpoints[3].request.fields[1].maximumBytes")
	and hasPath(request, "endpoints[3].response.shape.fields[1].maximum"),
	"request input and response shapes are both reported")

local policyResult, policyReport = compare(baseline, paths.policy)
assert(policyResult.code == 1 and hasPath(policyReport, "metadata.name") and hasPath(policyReport, "metadata.version")
	and hasPath(policyReport, "metadata.protocol") and hasPath(policyReport, "metadata.readiness")
	and hasPath(policyReport, "metadata.bitPacking") and hasPath(policyReport, "metadata.outboundBytes")
	and hasPath(policyReport, "endpoints[2].delivery") and hasPath(policyReport, "endpoints[2].queue"),
	"protocol and policy metadata, queue, and delivery changes are visible")
local readablePolicy = run({ baseline, paths.policy })
assert(readablePolicy.code == 1 and string.find(readablePolicy.stdout, "+ endpoints[2].queue:", 1, true),
	"readable output handles newly added endpoint policy metadata")
local addedResult, added = compare(baseline, paths["added endpoint"])
assert(addedResult.code == 1 and added.requiresMatchedDeployment and hasPath(added, "endpoints[4]").kind == "added",
	"additive endpoints still require matched deployment")

local kindBefore = write("event kind", [[{
	name = "Kind", version = 1,
	events = { Input = s.clientToServer(1, s.fields({ value = s.u8() })) },
}]])
local kindAfter = write("request kind", [[{
	name = "Kind", version = 1,
	events = {},
	requests = { Inspect = s.request(1, s.fields({ value = s.u8() }), s.boolean()) },
}]])
local kindResult, kind = compare(kindBefore, kindAfter)
assert(kindResult.code == 1 and hasPath(kind, "endpoints[1].kind"),
	"event-to-request kind changes at the same ID are reported")

local invalidResult, invalid = compare(paths["invalid schema"], paths.same)
assert(invalidResult.code == 2 and invalid.status == "invalid-input" and invalid.descriptorEqual == nil
	and invalid.requiresMatchedDeployment == nil and #invalid.changes == 0 and #invalid.diagnostics == 1,
	"invalid schemas do not claim a compatibility result")
local moduleResult, moduleReport = compare(invalidModule, paths.same)
assert(moduleResult.code == 2 and moduleReport.diagnostics[1].code == "InvalidModuleResult")
local missingResult, missing = compare(workspace.artifacts .. "/missing.luau", paths.same)
assert(missingResult.code == 2 and missing.diagnostics[1].code == "ModuleLoadFailed")
local absoluteResult, absolute = compare("C:\\outside.luau", paths.same)
assert(absoluteResult.code == 2 and absolute.diagnostics[1].code == "UnsupportedPath")
local argsResult = run({ "--json" })
local args = serde.decode("json", argsResult.stdout)
assert(argsResult.code == 2 and args.status == "invalid-input" and args.changes ~= nil,
	"invalid arguments keep the JSON report shape")
assert(run({ "--help" }).ok, "help succeeds")

local nativePrefix = 'local s = require("../../../../src/Schema")\nlocal r = require("@lune/roblox")\nreturn '
local nativeBefore = workspace.artifacts .. "/native before.luau"
local nativeAfter = workspace.artifacts .. "/native after.luau"
local function nativeBody(material, color)
	return nativePrefix .. '{ name = "Native", version = 1, events = { Paint = s.serverToClient(1, s.fields({ material = s.robloxEnum(r.Enum.Material.'
		.. material .. ') }, { color = s.BrickColor(r.BrickColor.new("' .. color .. '")) })) } }'
end
fs.writeFile(nativeBefore, nativeBody("Rock", "Bright red"))
fs.writeFile(nativeAfter, nativeBody("Water", "Bright blue"))
local nativeResult, native = compare(nativeBefore, nativeAfter)
assert(nativeResult.code == 1 and #native.changes > 0 and string.find(nativeResult.stdout, "Enum.Material", 1, true)
	and string.find(nativeResult.stdout, "Bright red", 1, true),
	"native EnumItem and BrickColor values serialize into useful differences")

workspace.cleanup()
fs.removeDir(workspace.root)
print("PASS offline schema compatibility CLI")
