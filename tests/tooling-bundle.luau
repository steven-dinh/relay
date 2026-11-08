local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Verification = require("../scripts/Verification")
local Bundle = require("../scripts/tooling/Bundle")
local Paths = require("../scripts/tooling/Paths")
local WorkerProcess = require("../scripts/tooling/Process")

local workspace = Verification.workspace("regression")
local temporary = Paths.resolve(process.env.TEMP or process.env.TMPDIR or "/tmp", process.cwd, true)
local token = assert(string.match(workspace.root, "([^/]+)$"))
local root = Paths.resolve(temporary .. "/relay-tools-" .. token, process.cwd, false)
assert(not Paths.within(root, Paths.resolve(process.cwd, process.cwd, true)), "consumer smoke must be outside Relay")
assert(not fs.isDir(root) and not fs.isFile(root), "consumer smoke requires a new owned directory")
fs.writeDir(root)
local destination = root .. "/installed tools"
local manifest = Bundle.build(process.cwd, destination)
assert(manifest.status == "complete" and #manifest.files > 28)
local installed = serde.decode("json", fs.readFile(destination .. "/tooling-manifest.json"))
assert(installed.compilerId == manifest.compilerId and installed.toolingId == manifest.toolingId)
assert(not pcall(Bundle.build, process.cwd, destination), "existing installation must not be overwritten")
local repeated = Bundle.build(process.cwd, root .. "/repeated tools")
assert(repeated.compilerId == manifest.compilerId and repeated.toolingId == manifest.toolingId,
	"same-source bundles must reproduce every pinned byte")
assert(fs.readFile(root .. "/repeated tools/tooling-manifest.json") == fs.readFile(destination .. "/tooling-manifest.json"),
	"same-source bundle manifests must reproduce exactly")

local contested = root .. "/concurrent [literal] tools"
local attempts, completed = {}, 0
for index = 1, 2 do
	task.spawn(function()
		local ok, result = pcall(Bundle.build, process.cwd, contested)
		attempts[index] = { ok = ok, result = result }
		completed += 1
	end)
end
while completed < 2 do task.wait(0.01) end
local winners = 0
for _, attempt in attempts do
	if attempt.ok then
		winners += 1
		assert(attempt.result.toolingId == manifest.toolingId)
	end
end
assert(winners == 1, "concurrent bundles must have exactly one destination owner")
assert(fs.readFile(contested .. "/tooling-manifest.json") == fs.readFile(destination .. "/tooling-manifest.json"),
	"a refused concurrent build must leave the winning bundle intact")

local consumer = root .. "/consumer project"
fs.writeDir(consumer)
fs.writeFile(consumer .. "/Spec.luau", [[
local s = require("@relay/schema")
local value = require("./Shape")
return {
	name = "Consumer", version = 1,
	events = { Input = s.clientToServer(1, s.fields({ value = value }), { delivery = "Unreliable" }) },
}
]])
fs.writeFile(consumer .. "/Shape.luau", 'return require("@relay/schema").u8()\n')
fs.writeFile(consumer .. "/Policy.luau", 'return { endpoints = { [1] = { capacity = 16, refillPerSecond = 8 } } }\n')
fs.writeFile(consumer .. "/Workload.luau",
	'return { events = { Input = { sendsPerSecond = 2, recipients = 1, path = "Immediate" } }, requests = {} }\n')
fs.writeFile(consumer .. "/Scenario.luau", [[
return function(context)
    context.withFixture(function(test)
        local received
        assert(test.server.events.Input:Connect(function(_, value) received = value end))
        assert(test:Start())
        assert(test.client.events.Input:Send(7))
        assert(received == nil and test:Pump() > 0 and received == 7)
    end)
end
]])
fs.writeFile(consumer .. "/relay-tools.json", serde.encode("json", {
	schemaVersion = 1, id = "consumer", schema = "Spec.luau",
	policy = "Policy.luau", baseline = "Spec.luau", workload = "Workload.luau", maxBytesPerSecond = 16,
	tests = { "Scenario.luau" }, typescript = "Network.d.ts",
	required = { "schema", "policy", "compat", "budget", "tests", "typescript" },
}))
local executable = WorkerProcess.executable()
local generated = process.exec(executable, { "run", destination .. "/" .. manifest.entrypoint, "generate",
	"--project", consumer .. "/relay-tools.json", "--write", "--json" }, { cwd = root })
assert(generated.ok, generated.stdout .. generated.stderr)
assert(serde.decode("json", generated.stdout).data.mode == "written" and fs.isFile(consumer .. "/Network.d.ts"))
local result = process.exec(executable, { "run", destination .. "/" .. manifest.entrypoint, "check",
	"--project", consumer .. "/relay-tools.json", "--json" }, { cwd = root })
assert(result.ok, result.stdout .. result.stderr)
local report = serde.decode("json", result.stdout)
assert(report.status == "passed" and report.projectId == "consumer")
assert(report.compilerId == manifest.compilerId and report.toolingId == manifest.toolingId,
	"installed host must identify the bundled source, not the Relay checkout")
assert(#report.children == 6, "all six required analyses/profiles must run")
for _, child in report.children do assert(child.status == "passed") end

-- This invocation owns the reserved root; verify containment before recursive cleanup.
local externalCleanup = Paths.resolve(root, process.cwd, true)
assert(Paths.within(externalCleanup, temporary) and externalCleanup ~= temporary)
fs.removeDir(externalCleanup)
local cleanup = Paths.resolve(workspace.root, process.cwd, true)
assert(Paths.within(cleanup, Paths.resolve(".tmp/verification", process.cwd, true)))
fs.removeDir(cleanup)
print("PASS pinned Relay Tools bundle checks an independent consumer project")
