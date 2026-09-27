local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROBLOX_TYPES_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.69.0/scripts/globalTypes.d.luau"
local ROBLOX_TYPES_SHA256 = "7DB9CD4FE55A4D26F3F7D5A39B6279A376F95A6C055C71D5591C26A1D525AAF2"
local TEMP_ROOT = ".tmp/public-types"
local DEFINITIONS_PATH = TEMP_ROOT .. "/globalTypes.d.luau"
local SOURCEMAP_PATH = TEMP_ROOT .. "/sourcemap.json"

local function exec(program, arguments)
    local ok, result = pcall(process.exec, program, arguments, { cwd = process.cwd, stdio = "default" })
    assert(ok, `could not run {program}: {tostring(result)}`)
    assert(type(result) == "table", `{program} returned no process result`)
    return result
end

local function assertVersion(program, expected)
    local result = exec(program, { "--version" })
    assert(result.ok, `{program} --version failed: {result.stderr}`)
    local actual = string.match(result.stdout .. result.stderr, "%d+%.%d+%.%d+")
    assert(actual == expected, `{program} {expected} required, got {tostring(actual)}`)
end

local function ensureRobloxDefinitions()
    if fs.isFile(DEFINITIONS_PATH) then
        local cached = fs.readFile(DEFINITIONS_PATH)
        assert(string.upper(serde.hash("sha256", cached)) == ROBLOX_TYPES_SHA256,
            `cached Roblox definitions SHA256 mismatch: {DEFINITIONS_PATH}`)
        return
    end

    local ok, response = pcall(net.request, ROBLOX_TYPES_URL)
    assert(ok, `could not download pinned Roblox definitions: {tostring(response)}`)
    assert(response.ok and response.statusCode == 200,
        `Roblox definitions download failed: HTTP {response.statusCode} {response.statusMessage}`)
    assert(string.upper(serde.hash("sha256", response.body)) == ROBLOX_TYPES_SHA256,
        "downloaded Roblox definitions SHA256 mismatch")
    fs.writeFile(DEFINITIONS_PATH, response.body)
end

local function diagnostics(output)
    local found = {}
    local current

    for line in string.gmatch(string.gsub(output, "\\", "/"), "[^\r\n]+") do
        local path, row, column, kind = string.match(line, "^(.-%.luau)%((%d+),(%d+)%)%: ([%w_]+):")
        if path then
            current = { path = path, row = tonumber(row), column = tonumber(column), kind = kind, text = line }
            table.insert(found, current)
        elseif current then
            current.text ..= "\n" .. line
        end
    end

    table.sort(found, function(left, right)
        if left.path == right.path then
            return left.row < right.row
        end
        return left.path < right.path
    end)
    return found
end

local function analyze(solverV2, fixture)
    local arguments = {
        "analyze",
        "--platform=roblox",
        "--definitions",
        `@roblox={DEFINITIONS_PATH}`,
        "--sourcemap",
        SOURCEMAP_PATH,
    }
    if solverV2 then
        table.insert(arguments, "--flag:LuauSolverV2=true")
    end
    table.insert(arguments, "src/init.luau")
    table.insert(arguments, fixture)
    return exec("luau-lsp", arguments)
end

local function checkPositive(solverV2)
    local result = analyze(solverV2, "tests/types/positive.luau")
    assert(result.ok, `positive consumer failed (solver v2: {solverV2})\n{result.stdout}\n{result.stderr}`)
    local output = result.stdout .. "\n" .. result.stderr
    local lowered = string.lower(output)
    assert(string.find(lowered, "panic", 1, true) == nil and string.find(lowered, "stack traceback", 1, true) == nil,
        `luau-lsp crashed during positive consumer (solver v2: {solverV2})\n{output}`)
    local found = diagnostics(output)
    assert(#found == 0, `positive consumer produced diagnostics (solver v2: {solverV2})\n{output}`)
end

local function checkNegative(solverV2)
    local result = analyze(solverV2, "tests/types/negative.luau")
    assert(not result.ok and result.code == 1,
        `negative consumer must fail with analyzer exit 1 (solver v2: {solverV2}); got {tostring(result.code)}\n{result.stdout}\n{result.stderr}`)

    local output = result.stdout .. "\n" .. result.stderr
    local lowered = string.lower(output)
    assert(string.find(lowered, "panic", 1, true) == nil and string.find(lowered, "stack traceback", 1, true) == nil,
        `luau-lsp crashed during negative consumer (solver v2: {solverV2})\n{output}`)
    local found = diagnostics(output)
    local expected = {
        { row = 11, reason = "'number', but got 'string'" },
        { row = 18, reason = "maximumBytes" },
        { row = 26, reason = "missing field 'maximum'" },
        { row = 34, reason = "missing field 'minimum'" },
        { row = 42, reason = "missing field 'maximum'" },
    }
    assert(#found == #expected,
        `negative consumer expected 5 diagnostics, got {#found}\n{output}`)

    for index, item in expected do
        local diagnostic = found[index]
        assert(string.sub(diagnostic.path, -#"tests/types/negative.luau") == "tests/types/negative.luau",
            `unexpected diagnostic file: {diagnostic.path}`)
        assert(diagnostic.row == item.row and diagnostic.kind == "TypeError",
            `expected TypeError at negative.luau:{item.row}, got {diagnostic.path}:{diagnostic.row} {diagnostic.kind}`)
        assert(string.find(diagnostic.text, item.reason, 1, true) ~= nil,
            `negative.luau:{item.row} did not report {item.reason}: {diagnostic.text}`)
    end
end

assertVersion("luau-lsp", "1.69.0")
assertVersion("rojo", "7.7.0")
if not fs.isDir(".tmp") then
    fs.writeDir(".tmp")
end
if not fs.isDir(TEMP_ROOT) then
    fs.writeDir(TEMP_ROOT)
end
ensureRobloxDefinitions()

local sourcemap = exec("rojo", { "sourcemap", "default.project.json", "--output", SOURCEMAP_PATH })
assert(sourcemap.ok, `Rojo sourcemap generation failed\n{sourcemap.stdout}\n{sourcemap.stderr}`)
assert(fs.isFile(SOURCEMAP_PATH), "Rojo did not create the public type sourcemap")

for _, solverV2 in { false, true } do
    print(`RUN public type consumer (solver v2: {solverV2})`)
    checkPositive(solverV2)
    checkNegative(solverV2)
end

print("PASS public type consumer")
