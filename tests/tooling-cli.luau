local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")
local Paths = require("../scripts/tooling/Paths")
local WorkerProcess = require("../scripts/tooling/Process")

local workspace = Verification.workspace("regression")
local ok, failure = pcall(function()
	local artifactRoot = Paths.resolve(workspace.artifacts, process.cwd, true)
	local consumer = artifactRoot .. "/consumer project with spaces"
	fs.writeDir(consumer)
	fs.writeDir(consumer .. "/shapes")
	local function write(path, value) fs.writeFile(consumer .. "/" .. path, value .. "\n") end
	local shape = [[
local Schema = require("@relay/schema")
return Schema.field("value", Schema.array(Schema.u8(), 1, 1))
]]
	local schema = [[
local Schema = require("@relay/schema")
local Shape = require("./shapes/input")
print("consumer log must not enter JSON")
return { name = "ToolingCli", version = 1,
    events = { Input = Schema.clientToServer(1, Schema.ordered(Shape)) } }
]]
	local baseline = [[
local Schema = require("@relay/schema")
local Shape = require("./shapes/input")
return { name = "ToolingCli", version = 1,
    events = { Input = Schema.clientToServer(1, Schema.ordered(Shape)) } }
]]
	write("shapes/input.luau", shape)
	write("schema.luau", schema)
	write("baseline.luau", baseline)
	write("policy.luau", 'return { endpoints = { [1] = { capacity = 4, refillPerSecond = 2 } } }')
	write("workload.luau", 'return { events = { Input = { sendsPerSecond = 2, recipients = 1, path = "Immediate" } }, requests = {} }')
	write("scenario.luau", "return function() return true end")

	local manifest = {
		schemaVersion = 1, id = "cliFixture", schema = "schema.luau", policy = "policy.luau",
		baseline = "baseline.luau", workload = "workload.luau", maxBytesPerSecond = 1000,
	}
	local manifestPath = consumer .. "/relay-tools.json"
	local function saveManifest() fs.writeFile(manifestPath, serde.encode("json", manifest) .. "\n") end
	local lune = WorkerProcess.executable()
	local cli = Paths.resolve("scripts/relay-tools.luau", process.cwd, true)
	local function invoke(operation, extra)
		local arguments = { "run", cli, operation }
		for _, argument in extra do table.insert(arguments, argument) end
		return process.exec(lune, arguments, { cwd = artifactRoot })
	end
	local function decoded(result, exitCode)
		assert(result.code == exitCode, `expected exit {exitCode}, got {result.code}: {result.stderr}\n{result.stdout}`)
		local valid, value = pcall(serde.decode, "json", result.stdout)
		assert(valid, `expected one clean JSON result: {result.stdout}\n{result.stderr}`)
		return value
	end

	saveManifest()
	local clean = decoded(invoke("check", { "--project", manifestPath, "--json" }), 0)
	assert(clean.status == "passed" and #clean.children == 4, "schema, policy, compat, and budget should pass")
	local sourceId = clean.sourceId
	for _, child in clean.children do
		assert(child.status == "passed" and child.projectId == clean.projectId
			and child.compilerId == clean.compilerId and child.toolingId == clean.toolingId
			and child.sourceId == sourceId and child.runId == clean.runId,
			"aggregate children must share the complete run identity")
	end
	assert(clean.children[3].data.descriptorEqual and clean.children[3].data.changes[1] == nil,
		"same baseline should produce equal descriptors")
	assert(clean.children[4].data.budget.status == "passed", "configured budget should pass")
	local doctor = decoded(invoke("doctor", { "--project", manifestPath, "--json" }), 0)
	assert(doctor.status == "passed" and doctor.projectId == "cliFixture", "doctor should validate the registered project")
	local compat = decoded(invoke("compat", { "--project", manifestPath, "--json" }), 0)
	assert(compat.status == "passed" and compat.data.descriptorEqual, "compat command should compare the configured baseline")
	local budget = decoded(invoke("budget", { "--project", manifestPath, "--json" }), 0)
	assert(budget.status == "passed" and budget.data.budget.status == "passed", "budget command should reuse the configured workload")

	local badSchema = [[
print("x" .. string.rep("🙂", 5000))
local Schema = require("@relay/schema")
local fields = Schema.fields({ value = Schema.array(Schema.u8(), 1, 1) })
return { name = "DuplicateIds", version = 1, events = {
    First = Schema.clientToServer(1, fields),
    Second = Schema.clientToServer(1, fields),
} }
]]
	write("schema.luau", badSchema)
	write("policy.luau", 'error("PolicyMustNotRunWithoutValidSchema")')
	local bad = decoded(invoke("check", { "--project", manifestPath, "--json" }), 1)
	assert(bad.status == "failed" and bad.sourceId ~= sourceId and bad.children[1].status == "failed"
		and bad.children[1].diagnostics[1].action ~= "", "invalid schema should fail with a new source identity and an action")
	assert(not string.find(serde.encode("json", bad), "PolicyMustNotRunWithoutValidSchema", 1, true),
		"policy evaluation must wait for a valid schema")
	local readable = invoke("check", { "--project", manifestPath })
	assert(readable.code == 1 and string.find(readable.stdout, "InvalidDefinition", 1, true)
		and string.find(readable.stdout, "Action:", 1, true), "default output must explain child failures")
	write("policy.luau", 'return { endpoints = { [1] = { capacity = 4, refillPerSecond = 2 } } }')
	write("schema.luau", string.rep(" ", 4_194_305))
	local oversized = decoded(invoke("check", { "--project", manifestPath, "--json" }), 2)
	assert(oversized.status == "failed" and oversized.diagnostics[1].code == "InvalidConfiguration",
		"oversized configured input must fail before worker evaluation")

	write("schema.luau", schema)
	manifest.tests = { "scenario.luau" }
	manifest.typescript = "types/Relay.d.ts"
	manifest.required = { "schema", "tests", "typescript" }
	saveManifest()
	local missingOutput = decoded(invoke("check", { "--project", manifestPath, "--json" }), 1)
	assert(missingOutput.status == "failed", "missing required generated output must not pass")
	local preview = decoded(invoke("generate", { "--project", manifestPath, "--json" }), 0)
	assert(preview.data.mode == "preview" and type(preview.data.declaration) == "string"
		and not fs.isFile(consumer .. "/types/Relay.d.ts"), "generation previews without writing")
	fs.writeDir(consumer .. "/types")
	write("types/Relay.d.ts", "previous output")
	write("schema.luau", 'require("@lune/fs").writeFile("types/Relay.d.ts", "newer edit")\n' .. schema)
	local stale = decoded(invoke("generate", { "--project", manifestPath, "--write", "--json" }), 1)
	assert(stale.status == "stale" and fs.readFile(consumer .. "/types/Relay.d.ts") == "newer edit",
		"generation must preserve an output edited during the worker job")

	manifest.tests, manifest.typescript, manifest.required = nil, nil, nil
	write("schema.luau", "while true do end")
	saveManifest()
	local cancelled = decoded(invoke("check", { "--project", manifestPath, "--json" }), 2)
	assert(cancelled.status == "cancelled" and cancelled.diagnostics[1].code == "WorkerTimeout",
		"a nonterminating schema must cancel its owned native worker")
end)
workspace.cleanup()
assert(ok, failure)
print("PASS Relay.Tooling.Cli")
