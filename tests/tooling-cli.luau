local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Verification = require("../scripts/Verification")
local Paths = require("../scripts/tooling/Paths")
local WorkerProcess = require("../scripts/tooling/Process")

local workspace = Verification.workspace("regression")
local junction
local junctionRoot
local ok, failure = pcall(function()
	local artifactRoot = Paths.resolve(workspace.artifacts, process.cwd, true)
	local consumer = artifactRoot .. "/consumer project with spaces café"
	junctionRoot = consumer
	fs.writeDir(consumer)
	fs.writeDir(consumer .. "/shapes")
	fs.writeDir(consumer .. "/guard-target")
	local function write(path, value) fs.writeFile(consumer .. "/" .. path, value .. "\n") end
	write("guard-target/input.luau", "return {}")
	junction = consumer .. "/guard-link"
	local linked = process.exec("powershell.exe", { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
		"New-Item -ItemType Junction -Path $env:RELAY_TEST_LINK -Target $env:RELAY_TEST_TARGET | Out-Null" },
		{ env = { RELAY_TEST_LINK = junction, RELAY_TEST_TARGET = consumer .. "/guard-target" } })
	assert(linked.ok, "the path guard regression should create its local junction")
	local guarded, guardIssue = pcall(Paths.resolve, "guard-link/input.luau", consumer, true)
	assert(not guarded and string.find(tostring(guardIssue), "UnsupportedReparsePath", 1, true),
		"path resolution should continue rejecting reparse points")
	local resolver = Paths.createGuard()
	local resolved = resolver.resolve("guard-target/input.luau", consumer, true)
	local persistentGuarded, persistentIssue = pcall(resolver.resolve, "guard-link/input.luau", consumer, true)
	assert(string.find(resolved, "café", 1, true) and not persistentGuarded
		and string.find(tostring(persistentIssue), "UnsupportedReparsePath", 1, true),
		"the persistent guard should frame Unicode paths and return resolver errors")
	assert(resolver.resolve("guard-target/input.luau", consumer, true) == resolved,
		"a rejected request should leave the persistent guard usable")
	resolver.close()
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
	local function readAll(reader)
		local chunks = {}
		while true do
			local chunk = reader:read(4096)
			if chunk == nil then break end
			table.insert(chunks, chunk)
		end
		return table.concat(chunks)
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

	manifest = { schemaVersion = 1, id = "cliChain", schema = "chain-schema.luau" }
	saveManifest()
	fs.writeDir(consumer .. "/chain")
	local chainSchema = [[
local Schema = require("@relay/schema")
local Shape = require("./chain/module-01.luau")
return { name = "ToolingChain", version = 1,
    events = { Input = Schema.clientToServer(1, Schema.ordered(Shape)) } }
]]
	write("chain-schema.luau", chainSchema)
	for index = 1, 40 do
		local path = string.format("chain/module-%02d.luau", index)
		local body = if index < 40 then string.format('return require("./module-%02d.luau")', index + 1)
			else [[
local Schema = require("@relay/schema")
return Schema.field("value", Schema.array(Schema.u8(), 1, 1))
]]
		write(path, body)
	end
	local chain = decoded(invoke("check", { "--project", manifestPath, "--json" }), 0)
	assert(chain.status == "passed", "a 40-module consumer import chain should complete inside the owned worker deadline")

	manifest.schema = "schema.luau"
	manifest.id = "cliFixture"
	saveManifest()
	write("shapes/init.luau", [[
local fs = require("@lune/fs")
local task = require("@lune/task")
fs.writeFile("waiting", "ready")
while not fs.isFile("release") do task.wait(0.01) end
local Schema = require("@relay/schema")
return Schema.field("value", Schema.array(Schema.u8(), 1, 1))
]])
	write("schema.luau", [[
local Schema = require("@relay/schema")
local Shape = require("./shapes")
return { name = "ToolingStale", version = 1,
    events = { Input = Schema.clientToServer(1, Schema.ordered(Shape)) } }
]])
	local waiting = process.create(lune, { "run", cli, "check", "--project", manifestPath, "--json" }, { cwd = artifactRoot })
	local state = { stdoutDone = false, stderrDone = false }
	task.spawn(function() state.status = waiting:status() end)
	task.spawn(function() state.stdout = readAll(waiting.stdout); state.stdoutDone = true end)
	task.spawn(function() state.stderr = readAll(waiting.stderr); state.stderrDone = true end)
	local waitDeadline = os.clock() + 10
	while not fs.isFile(consumer .. "/waiting") and state.status == nil and os.clock() < waitDeadline do task.wait(0.01) end
	if not fs.isFile(consumer .. "/waiting") then
		if state.status == nil then waiting:kill() end
		while state.status == nil do task.wait(0.01) end
		error("the init module should enter its controlled wait")
	end
	write("shapes.luau", [[
local Schema = require("@relay/schema")
return Schema.field("other", Schema.array(Schema.u8(), 1, 1))
]])
	write("release", "continue")
	local finishDeadline = os.clock() + 20
	while (state.status == nil or not state.stdoutDone or not state.stderrDone) and os.clock() < finishDeadline do task.wait(0.01) end
	if state.status == nil then waiting:kill() end
	while state.status == nil do task.wait(0.01) end
	assert(state.stdoutDone and state.stderrDone, "controlled worker output should drain")
	local stale = decoded({ code = state.status.code, stdout = state.stdout, stderr = state.stderr }, 1)
	assert(stale.status == "stale", "adding a higher-priority module while the init factory waits should stale the result")
	local current = decoded(invoke("check", { "--project", manifestPath, "--json" }), 0)
	local currentAgain = decoded(invoke("check", { "--project", manifestPath, "--json" }), 0)
	assert(current.sourceId == currentAgain.sourceId and current.sourceId ~= stale.sourceId,
		"the changed candidate should become the stable current source identity")

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
	write("schema.luau", [=[
local process = require("@lune/process")
local fs = require("@lune/fs")
local probe = process.exec("powershell.exe", { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", [[
$self = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)
$helpers = @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $self.ParentProcessId) | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -like '*PathGuard.ps1*' -and $_.CommandLine -like '*-Persistent*'
})
if ($helpers.Count -ne 1) { exit 2 }
$helpers[0].ProcessId
]] })
local helperPid = tonumber(string.match(probe.stdout, "%d+"))
assert(probe.ok and helperPid ~= nil, "the worker should own one persistent path guard")
fs.writeFile("guard-pid", tostring(helperPid))
while true do end
]=])
	saveManifest()
	local cancelled = decoded(invoke("check", { "--project", manifestPath, "--json" }), 2)
	assert(cancelled.status == "cancelled" and cancelled.diagnostics[1].code == "WorkerTimeout",
		"a nonterminating schema must cancel its owned native worker")
	local helperPid = tonumber(fs.readFile(consumer .. "/guard-pid"))
	assert(helperPid ~= nil, "the timed-out worker should record its owned guard PID")
	local helpers = process.exec("powershell.exe", { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", [[
$helperPid = [int]$env:RELAY_TEST_GUARD_PID
$deadline = [DateTime]::UtcNow.AddSeconds(3)
do {
    $helper = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $helperPid) -ErrorAction SilentlyContinue
    if ($null -eq $helper -or $helper.CommandLine -notlike '*PathGuard.ps1*' -or $helper.CommandLine -notlike '*-Persistent*') { exit 0 }
    Start-Sleep -Milliseconds 50
} while ([DateTime]::UtcNow -lt $deadline)
$helper | Select-Object ProcessId, ParentProcessId, CommandLine | ConvertTo-Json -Compress
exit 1
]] }, { env = { RELAY_TEST_GUARD_PID = tostring(helperPid) } })
	assert(helpers.ok, "a timed-out worker must not leave an owned PathGuard process: " .. helpers.stdout .. helpers.stderr)
end)
local junctionCleaned, junctionFailure = pcall(function()
	if junction then
		assert(junctionRoot and junction ~= junctionRoot and Paths.within(junction, junctionRoot),
			"the path guard regression should clean only its owned in-root junction")
		local removed = process.exec("powershell.exe", { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
			[[
$root = [IO.Path]::GetFullPath($env:RELAY_TEST_ROOT)
$path = [IO.Path]::GetFullPath($env:RELAY_TEST_LINK)
$prefix = $root.TrimEnd('\') + '\'
if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'owned junction escaped its root' }
if ([IO.Directory]::Exists($path)) {
    if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'cleanup target is no longer a reparse point' }
    [IO.Directory]::Delete($path)
}
]] }, { env = { RELAY_TEST_LINK = junction, RELAY_TEST_ROOT = junctionRoot } })
		assert(removed.ok, "the path guard regression should remove its owned junction")
	end
end)
workspace.cleanup()
assert(ok, failure)
assert(junctionCleaned, junctionFailure)
print("PASS Relay.Tooling.Cli")
