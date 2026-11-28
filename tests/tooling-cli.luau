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
		baseline = "baseline.luau", workload = "workload.luau", maxBytesPerSecond = 1000, tests = {},
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

	-- Lune's generic encoder emits {} for an empty table. Start with an actual JSON list.
	local manifestBytes = string.gsub(serde.encode("json", manifest), '"tests":{}', '"tests":[]')
	fs.writeFile(manifestPath, manifestBytes)
	local usage = decoded(invoke(manifestPath, { "--json" }), 2)
	assert(usage.operation == "cli" and usage.diagnostics[1].code == "InvalidArguments")
	local output = invoke("check", { "--project", manifestPath, "--json" })
	local clean = decoded(output, 0)
	assert(string.find(output.stdout, '"tests":[]', 1, true) and string.find(output.stdout, '"requests":{}', 1, true),
		"JSON must preserve the manifest tests list and the schema request map")
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
	assert(budget.status == "passed" and budget.data.budget.status == "passed"
		and budget.data.endpoints["events.Input"].name == "Input", "budget command should report the configured workload by endpoint")
	write("policy.luau", [[
local endpoints = {}
for id = 2, 257 do endpoints[id] = {} end
return { endpoints = endpoints }
]])
	local many = decoded(invoke("check", { "--project", manifestPath, "--json" }), 1)
	local rows = many.children[2].diagnostics
	assert(#rows == 256 and rows[1].code ~= "DiagnosticsOmitted" and rows[256].code == "DiagnosticsOmitted"
		and rows[256].omittedCount == 2, "project policy errors must retain bounded rows and the omitted count")
	write("schema.luau", [[error("broken schema " .. string.rep("🙂", 1024), 0)]])
	local long = decoded(invoke("check", { "--project", manifestPath, "--json" }), 1)
	local problem = long.children[1].diagnostics[1]
	assert(problem.code == "ModuleLoadFailed" and string.find(problem.message, "broken schema", 1, true)
		and #problem.message <= 1024 and utf8.len(problem.message), "long project errors must reach the CLI")
	write("schema.luau", schema)

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
	write("shapes/input.luau", 'require("@lune/fs").removeFile("shapes/input.luau")\n' .. shape)
	local removed = decoded(invoke("check", { "--project", manifestPath, "--json" }), 1)
	assert(removed.status == "stale" and removed.children[1].status == "stale",
		"removing a captured import during evaluation makes the check stale")
	write("shapes/input.luau", shape)

	-- Inject the failure only when the parent opens the worker's captured import.
	local captured = Paths.resolve("shapes/input.luau", consumer, true)
	local parentFs, parentProcess = table.clone(fs), table.clone(process)
	local parentWorker = table.clone(WorkerProcess)
	local parentResult, parentExit
	parentProcess.args = { "check", "--project", manifestPath, "--json" }
	parentProcess.exit = function(code) parentExit = code end
	local runParent = require("@lune/luau").load(fs.readFile(cli), {
		debugName = "@" .. cli, injectGlobals = true,
		environment = {
			print = function(json) parentResult = serde.decode("json", json) end,
			require = function(path)
				if path == "@lune/fs" then return parentFs end
				if path == "@lune/process" then return parentProcess end
				if path == "./tooling/Process" then return parentWorker end
				if string.sub(path, 1, 1) == "." then return require("../scripts/" .. path) end
				return require(path)
			end,
		},
	})
	parentFs.readFile = function(path)
		if path == captured then error("fixture read failure") end
		return fs.readFile(path)
	end
	runParent()
	assert(parentExit == 2 and parentResult.diagnostics[1].code == "WorkerResultInvalid"
		and string.find(parentResult.diagnostics[1].message, "fixture read failure", 1, true),
		"a read error for an existing import must retain its diagnostic")
	parentFs.readFile = function(path)
		if path == captured then fs.removeFile(path) end
		return fs.readFile(path)
	end
	runParent()
	assert(not fs.isFile(captured) and parentExit == 1 and parentResult.status == "stale"
		and parentResult.children[1].diagnostics[1].code == "SourceChanged",
		"a captured import removed during the parent's read must be reported as stale: " .. serde.encode("json", parentResult))
	write("shapes/input.luau", shape)
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
	local waitDeadline = os.clock() + 30
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

	write("schema.luau", schema)
	parentProcess.args = { "generate", "--project", manifestPath, "--write", "--json" }
	parentFs.readFile = fs.readFile
	parentFs.writeFile = function(path, ...)
		fs.writeFile(path, ...)
		if string.sub(path, -5) == "/next" then write("shapes/input.luau", shape .. "-- staged edit") end
	end
	runParent()
	assert(parentExit == 1 and parentResult.status == "stale" and parentResult.diagnostics[1].code == "SourceChanged"
		and fs.readFile(consumer .. "/types/Relay.d.ts") == "newer edit" and #fs.readDir(consumer .. "/types") == 1,
		"a source edit during staging must discard only the staged declaration")
	write("shapes/input.luau", shape)
	parentFs.writeFile = fs.writeFile
	parentProcess.exec = function(program, arguments, ...)
		if arguments[7] and string.match(arguments[7], "/PublishDeclaration%.ps1$") then
			fs.writeFile(consumer .. "/types/Relay.d.ts", "save during publication")
		end
		return process.exec(program, arguments, ...)
	end
	runParent()
	assert(parentExit == 1 and parentResult.status == "stale"
		and parentResult.diagnostics[1].code == "GeneratedOutputChanged" and parentResult.data.recoveryPath
		and string.find(parentResult.diagnostics[2].message, parentResult.data.recoveryPath, 1, true)
		and fs.readFile(parentResult.data.recoveryPath) == "save during publication",
		"an existing output displaced at publication must be recoverable at the advertised path")
	fs.removeFile(consumer .. "/types/Relay.d.ts")
	runParent()
	assert(parentExit == 1 and parentResult.status == "stale" and parentResult.data.recoveryPath == nil
		and fs.readFile(consumer .. "/types/Relay.d.ts") == "save during publication",
		"an output created at publication must win exclusive creation")
	parentProcess.exec = function(program, arguments, ...)
		if arguments[7] and string.match(arguments[7], "/PublishDeclaration%.ps1$") then error("fixture publisher unavailable") end
		return process.exec(program, arguments, ...)
	end
	runParent()
	local retained = parentResult.data.stagingPath
	assert(parentExit == 2 and parentResult.diagnostics[1].code == "GenerationWriteFailed" and retained
		and string.find(parentResult.diagnostics[2].message, retained, 1, true)
		and fs.readFile(retained .. "/next") == preview.data.declaration
		and fs.readFile(consumer .. "/types/Relay.d.ts") == "save during publication",
		"publisher launch failure must identify the remaining stage and preserve the output")
	parentProcess.exec = process.exec
	runParent()
	assert(parentExit == 0 and parentResult.data.mode == "written"
		and fs.readFile(consumer .. "/types/Relay.d.ts") == preview.data.declaration,
		"generation should replace an existing unchanged output")

	-- Exercise the parent's crash cleanup with one owned shadow and one unrelated file.
	local ownedShadow, otherShadow
	parentProcess.args = { "ts-check", "--project", manifestPath, "--json" }
	parentProcess.exec = function(program, ...)
		if program == "node" then return { ok = true, stdout = "fixture-node" } end
		return process.exec(program, ...)
	end
	parentWorker.run = function(program, args, cwd, ...)
		if program ~= "fixture-node" then return WorkerProcess.run(program, args, cwd, ...) end
		local job = args[#args]
		local token = assert(string.match(string.gsub(job, "\\", "/"), "([^/]+)$"))
		ownedShadow = cwd .. "/.relay-tools-" .. token .. ".tsconfig.json"
		otherShadow = cwd .. "/.relay-tools-" .. token .. ".project.json"
		fs.writeFile(ownedShadow, "owned")
		fs.writeFile(otherShadow, "keep")
		fs.writeDir(job .. "/roblox-ts")
		fs.writeFile(job .. "/roblox-ts/owned.tsconfig.sha256", serde.hash("sha256", "owned"))
		return { timedOut = true, stdout = "", stderr = "" }
	end
	runParent()
	assert(parentExit == 2 and parentResult.status == "cancelled" and not fs.isFile(ownedShadow)
		and fs.readFile(otherShadow) == "keep", "cleanup must only remove a shadow the compiler created")
	parentProcess.exec = process.exec
	parentWorker.run = WorkerProcess.run

	manifest.tests, manifest.required = nil, nil
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
	local cancelled = decoded(invoke("ts-check", { "--project", manifestPath, "--json" }), 2)
	assert(cancelled.status == "cancelled" and cancelled.children[1].operation == "typescript"
		and cancelled.children[1].diagnostics[1].code == "WorkerTimeout" and cancelled.children[2].status == "skipped",
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

	write("schema.luau", schema)
	manifest.policy, manifest.baseline, manifest.workload = "policy.luau", "baseline.luau", "workload.luau"
	manifest.tests, manifest.required = { "scenario.luau" }, { "schema", "policy", "compat", "budget", "tests", "typescript" }
	write("policy.luau", [[
local s = require("@relay/schema")
require("./schema").events.Input = s.clientToServer(1, s.fields({ value = s.u8() }))
return { endpoints = { [1] = { capacity = 4, refillPerSecond = 2 } } }
]])
	write("scenario.luau", [[
return function(context)
    context.withFixture(function(test)
        local received
        assert(test.server.events.Input:Connect(function(_, values) received = values end))
        assert(test:Start())
        assert(test.client.events.Input:Send({7}))
        test:Pump()
        assert(received and received[1] == 7, "the original array reached the handler")
    end)
end
]])
	saveManifest()
	local snapshot = decoded(invoke("check", { "--project", manifestPath, "--json" }), 0)
	assert(snapshot.children[3].data.descriptorEqual and snapshot.children[5].data.cases[1].status == "passed"
		and snapshot.children[6].data.expectedDigest == "sha256:" .. serde.hash("sha256", preview.data.declaration),
		"compatibility, scenarios, and declarations use the same current schema as inspection")
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
if ok and junctionCleaned then workspace.cleanup() end
assert(ok, failure)
assert(junctionCleaned, junctionFailure)
print("PASS Relay.Tooling.Cli")
