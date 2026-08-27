local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = process.cwd

local EXPECTED_FILES = {
    ".github/workflows/ci.yml",
    ".gitignore",
    "LICENSE",
    "README.md",
    "benchmarks/README.md",
    "benchmarks/contracts/event-v1.luau",
    "benchmarks/fixtures/event-v1.luau",
    "benchmarks/generated/.gitignore",
    "benchmarks/results/local/.gitignore",
    "benchmarks/tests/event-v1.luau",
    "benchmarks/tests/fixtures-event-v1.luau",
    "benchmarks/vendor/.gitignore",
    "default.project.json",
    "examples/README.md",
    "rokit.toml",
    "scripts/verify-foundation.luau",
    "src/init.luau",
    "tests/runner.luau",
    "wally.toml",
}

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
    "AGENTS.md",
    "context.md",
    ".idea/workspace.xml",
    ".vscode/settings.json",
    ".DS_Store",
    "Thumbs.db",
    "Desktop.ini",
    "benchmarks/vendor/probe",
    "benchmarks/generated/probe",
    "benchmarks/results/local/probe",
    "sourcemap.json",
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

local function assertExactList(actual, expected, label)
    table.sort(actual)
    table.sort(expected)
    assert(#actual == #expected, `{label} count mismatch: expected {#expected}, got {#actual}`)

    for index, expectedValue in ipairs(expected) do
        assert(actual[index] == expectedValue, `{label} mismatch at {index}: expected {expectedValue}, got {tostring(actual[index])}`)
    end
end

print("RUN module contract")
run("lune", { "run", "tests/runner.luau" })
print("PASS module contract")

print("RUN benchmark event contract")
run("lune", { "run", "benchmarks/tests/event-v1.luau" })
print("PASS benchmark event contract")

print("RUN benchmark event fixtures")
run("lune", { "run", "benchmarks/tests/fixtures-event-v1.luau" })
print("PASS benchmark event fixtures")

print("RUN repository structure")
local publicFiles = normalizedLines(run("git", {
    "ls-files",
    "--cached",
    "--others",
    "--exclude-standard",
}).stdout)
assertExactList(publicFiles, table.clone(EXPECTED_FILES), "public repository file set")

for _, path in ipairs(EXPECTED_FILES) do
    assert(fs.isFile(path), `missing scaffold file: {path}`)

    local contents = fs.readFile(path)
    assert(string.sub(contents, -1) == "\n", `missing final newline: {path}`)
    assert(string.find(contents, "[ \t]+\r?\n") == nil, `trailing whitespace: {path}`)
end

for _, path in ipairs({
    ".github/workflows",
    "benchmarks/contracts",
    "benchmarks/fixtures",
    "benchmarks/generated",
    "benchmarks/results/local",
    "benchmarks/tests",
    "benchmarks/vendor",
    "examples",
    "scripts",
    "src",
    "tests",
}) do
    assert(fs.isDir(path), `missing scaffold directory: {path}`)
end

local keepFileContract = "*\n!.gitignore\n"
assert(fs.readFile("benchmarks/vendor/.gitignore") == keepFileContract, "benchmark vendor ignore contract changed")
assert(fs.readFile("benchmarks/generated/.gitignore") == keepFileContract, "benchmark generated ignore contract changed")
assert(fs.readFile("benchmarks/results/local/.gitignore") == keepFileContract, "benchmark results ignore contract changed")
print("PASS repository structure")

print("RUN ignore boundary")
for _, probe in ipairs(IGNORE_PROBES) do
    run("git", { "check-ignore", "--no-index", "--quiet", probe })
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
print("PASS Wally contract")

print("RUN Rojo package build")
run("rojo", { "build", "default.project.json", "--output", ".tmp/Relay.rbxm" })
assert(fs.isFile(".tmp/Relay.rbxm"), "Rojo package build was not created")
assert(#fs.readFile(".tmp/Relay.rbxm") > 0, "Rojo package build is empty")
print("PASS Rojo package build")

print("RUN CI workflow contract")
local workflow = fs.readFile(".github/workflows/ci.yml")
local expectedUses = {
    "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
    "CompeyDev/setup-rokit@1d9390883f7ebce19d48f5b8d006e11d387c92ab",
}
local actualUses = {}

for value in string.gmatch(workflow, "uses:%s*([^%s]+)") do
    table.insert(actualUses, value)
end

table.sort(actualUses)
assertExactList(actualUses, table.clone(expectedUses), "CI action pins")
assert(string.find(workflow, "runs-on: ubuntu-24.04", 1, true), "CI runner must remain pinned")
assert(string.find(workflow, "timeout-minutes: 10", 1, true), "CI timeout must remain bounded")
assert(string.find(workflow, "permissions:\n  contents: read", 1, true), "CI permissions must remain read-only")
assert(string.find(workflow, "persist-credentials: false", 1, true), "checkout credentials must not persist")
assert(string.find(workflow, "version: v1.2.0", 1, true), "CI Rokit version must remain pinned")
assert(string.find(workflow, "cache: false", 1, true), "setup-rokit cache must remain disabled")
assert(string.find(workflow, "run: lune run scripts/verify-foundation.luau", 1, true), "CI must run aggregate foundation proof")
print("PASS CI workflow contract")

print("PASS Relay.Foundation.Proof")
