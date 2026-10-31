local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")
local Bundle = require("../scripts/tooling/Bundle")
local Paths = require("../scripts/tooling/Paths")

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
fs.writeFile(consumer .. "/relay-tools.json", serde.encode("json", {
	schemaVersion = 1, id = "consumer", schema = "Spec.luau",
	policy = "Policy.luau", baseline = "Spec.luau", workload = "Workload.luau", maxBytesPerSecond = 16,
}))
local result = process.exec("lune", { "run", destination .. "/" .. manifest.entrypoint, "check",
	"--project", consumer .. "/relay-tools.json", "--json" }, { cwd = root })
assert(result.ok, result.stdout .. result.stderr)
local report = serde.decode("json", result.stdout)
assert(report.status == "passed" and report.projectId == "consumer")
assert(report.compilerId == manifest.compilerId and report.toolingId == manifest.toolingId,
	"installed host must identify the bundled source, not the Relay checkout")
assert(#report.children == 4, "schema, policy, compatibility and budget must all run")
for _, child in report.children do assert(child.status == "passed") end

-- This invocation owns the reserved root; verify containment before recursive cleanup.
local externalCleanup = Paths.resolve(root, process.cwd, true)
assert(Paths.within(externalCleanup, temporary) and externalCleanup ~= temporary)
fs.removeDir(externalCleanup)
local cleanup = Paths.resolve(workspace.root, process.cwd, true)
assert(Paths.within(cleanup, Paths.resolve(".tmp/verification", process.cwd, true)))
fs.removeDir(cleanup)
print("PASS pinned Relay Tools bundle checks an independent consumer project")
