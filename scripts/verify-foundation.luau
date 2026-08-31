local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = process.cwd

local TESTS = {
	{ label = "module contract", path = "tests/runner.luau" },
	{ label = "benchmark event contract", path = "benchmarks/tests/event-v1.luau" },
	{ label = "benchmark event fixtures", path = "benchmarks/tests/fixtures-event-v1.luau" },
	{ label = "benchmark payload comparator", path = "benchmarks/tests/payload-comparator.luau" },
	{ label = "benchmark delivery ledger", path = "benchmarks/tests/delivery-ledger.luau" },
	{ label = "benchmark result contract", path = "benchmarks/tests/result-v1.luau" },
	{ label = "benchmark adapter contract", path = "benchmarks/tests/adapter-contract.luau" },
	{ label = "benchmark delivery router", path = "benchmarks/tests/delivery-router.luau" },
	{ label = "benchmark session owner", path = "benchmarks/tests/session-owner.luau" },
	{ label = "benchmark timing recorder", path = "benchmarks/tests/timing-recorder.luau" },
	{ label = "benchmark runner state", path = "benchmarks/tests/runner-state.luau" },
	{ label = "benchmark runner activation", path = "benchmarks/tests/generation-activation.luau" },
	{ label = "benchmark result draft assembler", path = "benchmarks/tests/result-draft-assembler.luau" },
	{ label = "benchmark case runner", path = "benchmarks/tests/case-runner.luau" },
	{ label = "benchmark control protocol", path = "benchmarks/tests/control-protocol.luau" },
	{ label = "benchmark Studio runner", path = "benchmarks/tests/studio-runner.luau" },
	{ label = "benchmark host runtime", path = "benchmarks/tests/host-runtime.luau" },
	{ label = "benchmark host manifest contract", path = "benchmarks/tests/host-manifest-v1.luau" },
	{ label = "benchmark harness termination contract", path = "benchmarks/tests/harness-termination-v1.luau" },
	{ label = "benchmark fake adapter", path = "benchmarks/tests/fake-adapter.luau" },
}

local EXPECTED_FILES = {
	".gitattributes",
    ".github/workflows/ci.yml",
    ".gitignore",
	"AGENTS.md",
    "LICENSE",
    "README.md",
	"benchmarks/README.md",
	"benchmarks/adapters/AdapterContract.luau",
	"benchmarks/event-v1.project.json",
	"benchmarks/contracts/event-v1.luau",
	"benchmarks/contracts/internal/AdapterIdentity.luau",
	"benchmarks/contracts/internal/HarnessTerminationV1.luau",
	"benchmarks/contracts/internal/HostManifestV1.luau",
	"benchmarks/contracts/result-v1.luau",
	"benchmarks/correctness/DeliveryLedger.luau",
    "benchmarks/correctness/PayloadComparator.luau",
    "benchmarks/fixtures/event-v1.luau",
	"benchmarks/generated/.gitignore",
	"benchmarks/host/run-event-v1.luau",
	"benchmarks/results/local/.gitignore",
	"benchmarks/runner/AdapterAllowlist.luau",
	"benchmarks/runner/DeliveryRouter.luau",
	"benchmarks/runner/BenchmarkClock.luau",
	"benchmarks/runner/TimingRecorder.luau",
	"benchmarks/runner/RunState.luau",
	"benchmarks/runner/RunnerKernel.luau",
	"benchmarks/runner/GenerationActivation.luau",
	"benchmarks/runner/ResultDraftAssembler.luau",
	"benchmarks/runner/CaseRunner.luau",
	"benchmarks/runner/KernelFanout.luau",
	"benchmarks/runner/ControlProtocol.luau",
	"benchmarks/runner/Coordinator.server.luau",
	"benchmarks/runner/Participant.client.luau",
	"benchmarks/runner/SessionOwner.luau",
	"benchmarks/runner/StudioBenchmarkClock.luau",
	"benchmarks/tests/support/HostRuntimeFixtures.luau",
	"benchmarks/tests/support/StudioProofReports.luau",
	"benchmarks/tests/support/FakeAdapter.luau",
	"benchmarks/vendor/.gitignore",
	"default.project.json",
	"examples/README.md",
	"context.md",
    "rokit.toml",
    "scripts/verify-foundation.luau",
    "src/init.luau",
    "wally.toml",
}

for _, test in ipairs(TESTS) do
	table.insert(EXPECTED_FILES, test.path)
end

local EXPECTED_PACKAGE_FILES = {
    "default.project.json",
    "LICENSE",
    "README.md",
    "src",
    "src/init.luau",
    "wally.toml",
}

local IGNORE_PROBES = {
    ".tmp/probe",
    "Packages/probe",
    "ServerPackages/probe",
    "DevPackages/probe",
	"docs/specs/probe.md",
	"docs/plans/probe.md",
	"docs/forge/probe.md",
    "docs/reports/probe.md",
    ".idea/workspace.xml",
    ".vscode/settings.json",
    ".DS_Store",
    "Thumbs.db",
    "Desktop.ini",
    "benchmarks/vendor/probe",
    "benchmarks/generated/probe",
    "benchmarks/results/local/probe",
    "sourcemap.json",
	"artifacts/probe.rbxl",
	"artifacts/probe.rbxlx",
	"artifacts/probe.rbxm",
	"artifacts/probe.rbxmx",
}

local EXPECTED_EXCLUDES = {
    ".github",
    ".github/**",
    "AGENTS.md",
    "context.md",
    "docs",
    "docs/**",
    "tests",
    "tests/**",
    "scripts",
    "scripts/**",
    "examples",
    "examples/**",
    "benchmarks",
    "benchmarks/**",
    "sourcemap.json",
    "rokit.toml",
}

local function run(program, arguments)
    local result = process.exec(program, arguments, {
        cwd = ROOT,
        stdio = "default",
    })

    assert(
        result.ok,
        `{program} failed with exit code {result.code}\n{result.stdout}\n{result.stderr}`
    )

    return result
end

local function normalizedLines(value)
    local lines = {}

    for line in string.gmatch(value, "[^\r\n]+") do
        local normalized = string.gsub(line, "^%.[/\\]", "")
        normalized = string.gsub(normalized, "\\", "/")
        table.insert(lines, normalized)
    end

    table.sort(lines)
    return lines
end

local function normalizedNewlines(value)
	local normalized = string.gsub(value, "\r\n", "\n")
	return string.gsub(normalized, "\r", "\n")
end

local function keyCount(value)
	local count = 0

	for _ in pairs(value) do
		count += 1
	end

	return count
end

local function assertExactList(actual, expected, label)
    table.sort(actual)
    table.sort(expected)
    assert(#actual == #expected, `{label} count mismatch: expected {#expected}, got {#actual}`)

    for index, expectedValue in ipairs(expected) do
        assert(actual[index] == expectedValue, `{label} mismatch at {index}: expected {expectedValue}, got {tostring(actual[index])}`)
    end
end

for _, test in ipairs(TESTS) do
	print(`RUN {test.label}`)
	run("lune", { "run", test.path })
	print(`PASS {test.label}`)
end

print("RUN repository structure")
local publicFiles = normalizedLines(run("git", {
    "ls-files",
    "--cached",
}).stdout)
assertExactList(publicFiles, table.clone(EXPECTED_FILES), "tracked release file set")
assert(
	fs.readFile(".gitattributes") == "* text=auto eol=lf\n",
	"repository LF policy changed"
)

for _, path in ipairs(EXPECTED_FILES) do
    assert(fs.isFile(path), `missing scaffold file: {path}`)

    local contents = fs.readFile(path)
	assert(string.sub(contents, -1) == "\n", `missing final newline: {path}`)
	assert(string.find(contents, "[ \t]+\r?\n") == nil, `trailing whitespace: {path}`)
end

for _, path in ipairs({
    ".github/workflows",
    "benchmarks/adapters",
    "benchmarks/contracts",
    "benchmarks/contracts/internal",
    "benchmarks/correctness",
    "benchmarks/fixtures",
    "benchmarks/generated",
    "benchmarks/results/local",
	"benchmarks/runner",
    "benchmarks/tests",
    "benchmarks/tests/support",
    "benchmarks/vendor",
	"examples",
    "scripts",
    "src",
    "tests",
}) do
    assert(fs.isDir(path), `missing scaffold directory: {path}`)
end

local keepFileContract = "*\n!.gitignore\n"
assert(normalizedNewlines(fs.readFile("benchmarks/vendor/.gitignore")) == keepFileContract, "benchmark vendor ignore contract changed")
assert(normalizedNewlines(fs.readFile("benchmarks/generated/.gitignore")) == keepFileContract, "benchmark generated ignore contract changed")
assert(normalizedNewlines(fs.readFile("benchmarks/results/local/.gitignore")) == keepFileContract, "benchmark results ignore contract changed")
print("PASS repository structure")

print("RUN ignore boundary")
local function assertIgnored(path)
	run("git", { "check-ignore", "--no-index", "--quiet", path })
end

for _, probe in ipairs(IGNORE_PROBES) do
	assertIgnored(probe)
end

local gitStatus = run("git", { "status", "--short" }).stdout
for _, forbidden in ipairs({ ".tmp/", "Packages/", "ServerPackages/", "DevPackages/", "benchmarks/vendor/probe", "benchmarks/generated/probe", "benchmarks/results/local/probe", "sourcemap.json" }) do
    assert(not string.find(gitStatus, forbidden, 1, true), `ignored output entered Git status: {forbidden}`)
end
print("PASS ignore boundary")

print("RUN Wally contract")
local manifestResult = run("wally", { "manifest-to-json", "--project-path", "." })
local manifest = serde.decode("json", manifestResult.stdout)
local package = manifest.package

assert(package.name == "steven-dinh/relay", "unexpected Wally package name")
assert(package.description == "Pre-alpha foundation for Relay, a standalone Roblox networking library.", "unexpected Wally description")
assert(package.version == "0.1.0", "unexpected Wally version")
assert(package.license == "MIT", "unexpected Wally license")
assert(package.realm == "shared", "unexpected Wally realm")
assert(package.registry == "https://github.com/UpliftGames/wally-index", "unexpected Wally registry")
assert(package.private == true, "Wally publication guard must remain enabled")
assert(#package.authors == 1 and package.authors[1] == "Steven Dinh", "unexpected Wally authors")
assert(#package.include == 0, "Wally include must remain empty")
assertExactList(table.clone(package.exclude), table.clone(EXPECTED_EXCLUDES), "Wally excludes")
assert(next(manifest.dependencies) == nil, "runtime dependencies must remain empty")
assert(next(manifest["server-dependencies"]) == nil, "server dependencies must remain empty")
assert(next(manifest["dev-dependencies"]) == nil, "development dependencies must remain empty")

local packageFiles = normalizedLines(run("wally", { "package", "--list", "--project-path", "." }).stdout)
assertExactList(packageFiles, table.clone(EXPECTED_PACKAGE_FILES), "Wally package file set")

if not fs.isDir(".tmp") then
    fs.writeDir(".tmp")
end

run("wally", { "package", "--project-path", ".", "--output", ".tmp/relay-package.zip" })
assert(fs.isFile(".tmp/relay-package.zip"), "Wally package archive was not created")
assert(#fs.readFile(".tmp/relay-package.zip") > 0, "Wally package archive is empty")
assertIgnored(".tmp/relay-package.zip")
print("PASS Wally contract")

print("RUN Rojo package build")
run("rojo", { "build", "default.project.json", "--output", ".tmp/Relay.rbxm" })
assert(fs.isFile(".tmp/Relay.rbxm"), "Rojo package build was not created")
assert(#fs.readFile(".tmp/Relay.rbxm") > 0, "Rojo package build is empty")
assertIgnored(".tmp/Relay.rbxm")
print("PASS Rojo package build")

print("RUN Rojo benchmark place build")
run("rojo", { "build", "benchmarks/event-v1.project.json", "--output", ".tmp/event-v1.rbxlx" })
assert(fs.isFile(".tmp/event-v1.rbxlx"), "Rojo benchmark place build was not created")
assert(#fs.readFile(".tmp/event-v1.rbxlx") > 0, "Rojo benchmark place build is empty")
assertIgnored(".tmp/event-v1.rbxlx")
print("PASS Rojo benchmark place build")

print("RUN CI workflow contract")
local workflowSource = normalizedNewlines(fs.readFile(".github/workflows/ci.yml"))
local workflow = serde.decode("yaml", workflowSource)
assert(keyCount(workflow) == 4, "CI workflow root shape changed")
assert(workflow.name == "CI", "CI workflow name changed")

local triggers = workflow["on"]
assert(type(triggers) == "table", "CI trigger shape changed")
assert(
	type(triggers.push) == "table"
		and keyCount(triggers.push) == 1
		and type(triggers.push.branches) == "table"
		and #triggers.push.branches == 1
		and triggers.push.branches[1] == "main",
	"CI push trigger must target only main"
)
local barePullRequest = string.find(workflowSource, "\n  pull_request:\n", 1, true) ~= nil
local emptyPullRequest = string.find(workflowSource, "\n  pull_request: {}\n", 1, true) ~= nil
assert(barePullRequest ~= emptyPullRequest, "CI pull request trigger must remain unfiltered")
if barePullRequest then
	assert(keyCount(triggers) == 1 and triggers.pull_request == nil, "CI trigger shape changed")
else
	assert(
		keyCount(triggers) == 2
			and type(triggers.pull_request) == "table"
			and keyCount(triggers.pull_request) == 0,
		"CI trigger shape changed"
	)
end

assert(keyCount(workflow.permissions) == 1 and workflow.permissions.contents == "read", "CI permissions must remain read-only")

assert(
	type(workflow.jobs) == "table"
		and keyCount(workflow.jobs) == 1
		and type(workflow.jobs.verify) == "table",
	"CI must contain exactly the verify job"
)
local verifyJob = workflow.jobs.verify
assert(keyCount(verifyJob) == 3, "CI verify job shape changed")
assert(verifyJob["runs-on"] == "ubuntu-24.04", "CI runner must remain pinned")
assert(verifyJob["timeout-minutes"] == 10, "CI timeout must remain bounded")
assert(#verifyJob.steps == 3, "CI verify job must contain exactly three steps")

local checkoutStep = verifyJob.steps[1]
assert(keyCount(checkoutStep) == 3, "CI checkout step shape changed")
assert(checkoutStep.name == "Check out repository", "CI checkout step changed")
assert(checkoutStep.uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "CI checkout action must remain pinned")
assert(keyCount(checkoutStep["with"]) == 1 and checkoutStep["with"]["persist-credentials"] == false, "checkout credentials must not persist")

local rokitStep = verifyJob.steps[2]
assert(keyCount(rokitStep) == 3, "CI Rokit step shape changed")
assert(rokitStep.name == "Install Rokit tools", "CI Rokit step changed")
assert(rokitStep.uses == "CompeyDev/setup-rokit@1d9390883f7ebce19d48f5b8d006e11d387c92ab", "CI Rokit action must remain pinned")
assert(keyCount(rokitStep["with"]) == 2, "CI Rokit inputs changed")
assert(rokitStep["with"].version == "v1.2.0", "CI Rokit version must remain pinned")
assert(rokitStep["with"].cache == false, "setup-rokit cache must remain disabled")

local verificationStep = verifyJob.steps[3]
assert(keyCount(verificationStep) == 2, "CI verification step shape changed")
assert(verificationStep.name == "Verify foundation", "CI verification step changed")
assert(verificationStep.run == "lune run scripts/verify-foundation.luau", "CI must run aggregate foundation proof")
print("PASS CI workflow contract")

print("PASS Relay.Foundation.Proof")
