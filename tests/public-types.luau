local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROBLOX_TYPES_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.69.0/scripts/globalTypes.d.luau"
local ROBLOX_TYPES_SHA256 = "7DB9CD4FE55A4D26F3F7D5A39B6279A376F95A6C055C71D5591C26A1D525AAF2"
local TEMP_ROOT = ".tmp/public-types"
local DEFINITIONS_PATH = TEMP_ROOT .. "/globalTypes.d.luau"
local SOURCEMAP_PATH = TEMP_ROOT .. "/sourcemap.json"

local function exec(program, arguments, cwd)
    local ok, result = pcall(process.exec, program, arguments, { cwd = cwd or process.cwd, stdio = "default" })
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
            if left.row == right.row then
                return left.column < right.column
            end
            return left.row < right.row
        end
        return left.path < right.path
    end)
    return found
end

local function analyze(fixture)
    return exec("luau-lsp", {
        "analyze",
        "--platform=roblox",
        "--flag:LuauSolverV2=true",
        "--definitions",
        `@roblox={DEFINITIONS_PATH}`,
        "--sourcemap",
        SOURCEMAP_PATH,
        "src/init.luau",
        "src/Schema.luau",
        "src/Schema.luau",
        fixture,
    })
end

local function assertNoCrash(output, fixture)
    local lowered = string.lower(output)
    assert(string.find(lowered, "panic", 1, true) == nil and string.find(lowered, "stack traceback", 1, true) == nil,
        `luau-lsp crashed while checking {fixture}\n{output}`)
end

local function checkPositive(fixture)
    local result = analyze(fixture)
    local output = result.stdout .. "\n" .. result.stderr
    assert(result.ok, `positive consumer failed\n{output}`)
    assertNoCrash(output, fixture)
    local found = diagnostics(output)
    assert(#found == 0, `positive consumer produced diagnostics\n{output}`)
end

local function checkDiagnostics(fixture, expected)
    local result = analyze(fixture)
    assert(not result.ok and result.code == 1,
        `{fixture} must fail with analyzer exit 1; got {tostring(result.code)}\n{result.stdout}\n{result.stderr}`)

    local output = result.stdout .. "\n" .. result.stderr
    assertNoCrash(output, fixture)
    local found = diagnostics(output)
    assert(#found == #expected,
        `{fixture} expected {#expected} diagnostics, got {#found}\n{output}`)

    for _, item in expected do
        local matchingIndex
        for index, diagnostic in found do
            if string.sub(diagnostic.path, -#fixture) == fixture
                and diagnostic.row == item.row and diagnostic.column == item.column
                and diagnostic.kind == "TypeError"
                and string.find(diagnostic.text, item.reason, 1, true) ~= nil then
                matchingIndex = index
                break
            end
        end
        assert(matchingIndex,
            `expected TypeError at {fixture}:{item.row}:{item.column} reporting {item.reason}\n{output}`)
        table.remove(found, matchingIndex)
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

print("RUN public type consumer (LuauSolverV2)")
checkPositive("tests/types/positive.luau")
checkPositive("tests/types/composable-positive.luau")
checkDiagnostics("tests/types/negative.luau", {
    { row = 15, column = 1, reason = "Key 'Unknown' not found" },
    { row = 16, column = 1, reason = "Key 'Send' not found" },
    { row = 17, column = 1, reason = "Key 'Send' not found" },
    { row = 18, column = 1, reason = "Key 'Connect' not found" },
    { row = 19, column = 1, reason = "Key 'Connect' not found" },
    { row = 20, column = 26, reason = "Expected this to be 'number', but got 'string'" },
    { row = 21, column = 26, reason = "Expected this to be 'number', but got 'boolean'" },
    { row = 21, column = 32, reason = "Expected this to be 'boolean', but got 'number'" },
    { row = 22, column = 1, reason = "Function expects 9 arguments, but only 8 are specified" },
    { row = 23, column = 1, reason = "Function expects 9 arguments, but 10 are specified" },
    { row = 24, column = 26, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 25, column = 1, reason = "Function expects 6 arguments, but 7 are specified" },
    { row = 26, column = 1, reason = "Function expects 1 argument, but 2 are specified" },
    { row = 27, column = 29, reason = "Expected this to be" },
    { row = 28, column = 29, reason = "Expected this to be '() -> ()'" },
    { row = 29, column = 1, reason = "Key 'Unknown' not found" },
    { row = 30, column = 1, reason = "Key 'SendTo' not found" },
    { row = 31, column = 1, reason = "Key 'SendExcept' not found" },
    { row = 32, column = 30, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 33, column = 36, reason = "Expected this to be 'number', but got 'string'" },
    { row = 34, column = 1, reason = "Function expects 6 arguments, but only 5 are specified" },
    { row = 35, column = 1, reason = "Function expects 2 arguments, but 3 are specified" },
    { row = 36, column = 1, reason = "Key 'Once' not found" },
    { row = 37, column = 1, reason = "Key 'Once' not found" },
    { row = 38, column = 26, reason = "Expected this to be" },
    { row = 39, column = 15, reason = "Expected this to be 'Definition<S>', but got 'number'" },
})
checkDiagnostics("tests/types/ordered-invalid-options.luau", {
    { row = 7, column = 34, reason = "Expected this to be 'number', but got 'string'" },
    { row = 11, column = 58, reason = "Expected this to be 'number', but got 'string'" },
})
checkDiagnostics("tests/types/ordered-invalid-schemas.luau", {
    { row = 5, column = 21, reason = "definition name must be string" },
    { row = 6, column = 24, reason = "definition version must be number" },
    { row = 7, column = 19, reason = "event 'Input': event id must be number" },
    { row = 8, column = 22, reason = "event 'Input': invalid event direction; expected 'ClientToServer' or 'ServerToClient'" },
    { row = 9, column = 21, reason = "event 'Input': fields must be ordered" },
    { row = 10, column = 28, reason = "event 'Input', field 1: string maximumBytes must be number" },
    { row = 11, column = 27, reason = "event 'Input', field 1: bounded field is missing minimum" },
    { row = 12, column = 27, reason = "event 'Input', field 1: bounded field is missing maximum" },
    { row = 13, column = 31, reason = "event 'Input', field 1: bounded field is missing minimum" },
    { row = 14, column = 31, reason = "event 'Input', field 1: bounded field is missing maximum" },
    { row = 15, column = 31, reason = "event 'Input', field 1: bounded field is missing minimum" },
    { row = 16, column = 31, reason = "event 'Input', field 1: bounded field is missing maximum" },
    { row = 17, column = 30, reason = "event 'Input', field 1: bounded field is missing minimum" },
    { row = 18, column = 30, reason = "event 'Input', field 1: bounded field is missing maximum" },
    { row = 19, column = 26, reason = "event 'Input', field 1: field minimum must be number" },
    { row = 20, column = 25, reason = "event 'Input', field 1: unsupported field type 'i64'" },
    { row = 21, column = 26, reason = "event 'Input', field 1: field name must be string" },
    { row = 22, column = 21, reason = "event 'Input', field 1: field must be a table" },
    { row = 32, column = 36, reason = "event 'Input', field 1: field minimum must be number" },
    { row = 33, column = 28, reason = "event 'Input', field 1: field minimum must be number" },
    { row = 34, column = 28, reason = "event 'Input', field 1: field maximum must be number" },
    { row = 37, column = 24, reason = "event 'Status', field 2: bounded field is missing minimum" },
    { row = 53, column = 25, reason = "event 'Input': invalid event delivery; expected 'Reliable' or 'Unreliable'" },
})
checkDiagnostics("tests/types/composable-invalid.luau", {
    { row = 5, column = 23, reason = "struct field name must be a string literal" },
    { row = 12, column = 23, reason = "array element cannot be optional" },
    { row = 18, column = 19, reason = "set element must be boolean, string, integer, or enum" },
    { row = 24, column = 24, reason = "enum value must be a string literal" },
    { row = 46, column = 43, reason = "Expected this to be '\"Idle\" | \"Run\"', but got '\"Other\"'" },
    { row = 47, column = 62, reason = "Expected this to be 'number', but got 'string'" },
    { row = 48, column = 80, reason = "Expected this to be 'true', but got 'false'" },
    { row = 49, column = 74, reason = "Expected this to be 'string', but got 'number'" },
    { row = 50, column = 84, reason = "Expected this to be 'number?', but got 'string'" },
    { row = 59, column = 29, reason = "schema exceeds maximum composite depth of 4" },
    { row = 71, column = 29, reason = "schema exceeds maximum composite depth of 4" },
    { row = 72, column = 31, reason = "shape exceeds maximum composite depth of 4" },
    { row = 85, column = 50, reason = "Expected this to be 'true?', but got 'false'" },
})

checkPositive("tests/types/schema-helpers-positive.luau")
checkPositive("tests/types/schema-compose-positive.luau")
checkPositive("tests/types/rpc-positive.luau")
checkPositive("tests/types/readiness-positive.luau")
checkPositive("tests/types/queued-positive.luau")
checkDiagnostics("tests/types/schema-helpers-invalid.luau", {
    { row = 6, column = 21, reason = "struct field name must be a string literal" },
    { row = 9, column = 21, reason = "enum value must be a string literal" },
    { row = 12, column = 17, reason = "field name must be string" },
    { row = 15, column = 17, reason = "unsupported field type 'i64'" },
    { row = 18, column = 18, reason = "array element must be a shape table" },
    { row = 21, column = 20, reason = "child shape must not have a name" },
    { row = 24, column = 23, reason = "array element cannot be optional" },
    { row = 27, column = 16, reason = "set element must be boolean, string, integer, or enum" },
    { row = 30, column = 24, reason = "schema exceeds maximum composite depth of 4" },
    { row = 34, column = 29, reason = "field type must be a singleton" },
    { row = 38, column = 29, reason = "field name must be string" },
    { row = 42, column = 29, reason = "field must be a table" },
    { row = 45, column = 10, reason = "Expected this to be 'number', but got 'string'" },
    { row = 46, column = 7, reason = "Expected this to be 'number?', but got 'boolean'" },
    { row = 47, column = 34, reason = "Expected this to be '(\"Reliable\" | \"Unreliable\")?', but got '\"Slow\"'" },
    { row = 62, column = 1, reason = "Key 'Unknown' not found" },
    { row = 63, column = 1, reason = "Key 'Send' not found" },
    { row = 64, column = 1, reason = "Key 'Send' not found" },
    { row = 65, column = 1, reason = "Key 'Connect' not found" },
    { row = 66, column = 35, reason = "Expected this to be '\"Idle\" | \"Run\"', but got '\"Other\"'" },
    { row = 67, column = 83, reason = "Expected this to be 'number', but got 'string'" },
    { row = 68, column = 60, reason = "Expected this to be 'true?', but got 'false'" },
    { row = 69, column = 105, reason = "Expected this to be 'number?', but got 'string'" },
    { row = 70, column = 98, reason = "Expected this to be 'number', but got 'boolean'" },
    { row = 71, column = 1, reason = "Function expects 3 arguments, but 4 are specified" },
    { row = 72, column = 1, reason = "Function expects 1 argument, but 2 are specified" },
    { row = 73, column = 29, reason = "Expected this to be" },
    { row = 75, column = 11, reason = "Key 'unknown' not found" },
    { row = 77, column = 58, reason = "Expected this to be 'number', but got 'string'" },
    { row = 79, column = 30, reason = "Expected this to be 'number', but got 'string'" },
})
checkDiagnostics("tests/types/schema-compose-invalid.luau", {
    { row = 16, column = 1, reason = "Key 'Unknown' not found" },
    { row = 17, column = 1, reason = "Key 'Send' not found" },
    { row = 18, column = 27, reason = "Expected this to be 'number', but got 'string'" },
    { row = 19, column = 40, reason = "Expected this to be '\"Guard\" | \"Slash\"', but got '\"Other\"'" },
    { row = 20, column = 62, reason = "Expected this to be 'number', but got 'string'" },
    { row = 21, column = 1, reason = "Function expects 3 arguments, but 4 are specified" },
    { row = 22, column = 33, reason = "Expected this to be 'number', but got 'boolean'" },
    { row = 28, column = 24, reason = "duplicate event name" },
    { row = 28, column = 24, reason = "Type functions do not currently support types of the form" },
    { row = 28, column = 37, reason = "duplicate event name" },
    { row = 30, column = 14, reason = "duplicate event name" },
    { row = 30, column = 21, reason = "duplicate event name" },
    { row = 35, column = 20, reason = "event fragments require literal event keys" },
    { row = 35, column = 20, reason = "Type functions do not currently support types of the form" },
    { row = 35, column = 33, reason = "event fragments require literal event keys" },
    { row = 37, column = 14, reason = "event fragments require literal event keys" },
    { row = 37, column = 21, reason = "event fragments require literal event keys" },
})
checkDiagnostics("tests/types/rpc-invalid.luau", {
    { row = 9, column = 1, reason = "Key 'Unknown' not found" },
    { row = 10, column = 1, reason = "Key 'Request' not found" },
    { row = 11, column = 1, reason = "Key 'Connect' not found" },
    { row = 12, column = 33, reason = "Expected this to be 'number', but got 'string'" },
    { row = 13, column = 36, reason = "Expected this to be 'number', but got 'string'" },
    { row = 14, column = 1, reason = "Function expects 3 arguments, but only 2 are specified" },
    { row = 15, column = 1, reason = "Function expects 3 arguments, but 4 are specified" },
    { row = 16, column = 1, reason = "Function expects 2 arguments, but 3 are specified" },
    { row = 17, column = 58, reason = "Expected this to be 'boolean', but got 'number'" },
    { row = 18, column = 66, reason = "Expected this to be 'number?', but got 'boolean'" },
    { row = 19, column = 72, reason = "Expected this to be" },
    { row = 20, column = 98, reason = "Expected this to be 'number', but got 'string'" },
    { row = 21, column = 33, reason = "Expected this to be" },
    { row = 23, column = 1, reason = "Function expects 1 argument, but 2 are specified" },
    { row = 26, column = 27, reason = "Expected this to be 'string', but got 'number'" },
    { row = 29, column = 11, reason = "Key 'value' not found" },
})
checkDiagnostics("tests/types/rpc-invalid-schemas.luau", {
    { row = 4, column = 1, reason = "definition requests must be a table" },
    { row = 5, column = 1, reason = "request 'Inspect' must be a table" },
    { row = 6, column = 91, reason = "Expected this to be 'number', but got 'string'" },
    { row = 7, column = 1, reason = "request fields must be ordered" },
    { row = 8, column = 1, reason = "child shape must not have a name" },
    { row = 9, column = 1, reason = "array element cannot be optional" },
    { row = 10, column = 1, reason = "bounded field needs minimum and maximum" },
})
checkDiagnostics("tests/types/readiness-invalid.luau", {
    { row = 14, column = 25, reason = "Expected this to be 'boolean?', but got 'string'" },
    { row = 15, column = 25, reason = "Expected this to be 'boolean?', but got 'number'" },
    { row = 16, column = 25, reason = "Expected this to be 'boolean?', but got '{  }'" },
    { row = 17, column = 1, reason = "Function expects 1 to 2 arguments, but 3 are specified" },
    { row = 18, column = 1, reason = "Key 'GetReadyPlayers' not found" },
    { row = 19, column = 1, reason = "Key 'GetReadyPlayers' not found" },
    { row = 20, column = 28, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 21, column = 38, reason = "Expected this to be 'number', but got 'string'" },
    { row = 22, column = 1, reason = "Key 'SendTo' not found" },
    { row = 24, column = 1, reason = "definition readiness must be boolean" },
})
checkDiagnostics("tests/types/queued-invalid.luau", {
    { row = 33, column = 1, reason = "Key 'InBatch' not found" },
    { row = 34, column = 1, reason = "Key 'Immediate' not found" },
    { row = 35, column = 34, reason = "Expected this to be 'number', but got 'string'" },
    { row = 36, column = 1, reason = "Function expects 2 arguments, but only 1 is specified" },
    { row = 37, column = 1, reason = "Key 'Put' not found" },
    { row = 38, column = 1, reason = "Key 'OutBatch' not found" },
    { row = 39, column = 1, reason = "Key 'Send' not found" },
    { row = 40, column = 1, reason = "Key 'OutBatch' not found" },
    { row = 41, column = 33, reason = "Expected this to be 'number', but got 'string'" },
    { row = 42, column = 35, reason = "Expected this to be '\"High\" | \"Low\" | \"Normal\"', but got '\"Other\"'" },
    { row = 43, column = 1, reason = "Key 'OutState' not found" },
    { row = 45, column = 22, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 46, column = 1, reason = "Function expects 3 arguments, but only 2 are specified" },
    { row = 47, column = 32, reason = "Expected this to be 'number', but got 'string'" },
    { row = 48, column = 1, reason = "Function expects 3 arguments, but 4 are specified" },
    { row = 49, column = 20, reason = "Expected this to be 'number', but got '{Player}'" },
    { row = 49, column = 1, reason = "Function expects 2 arguments, but 3 are specified" },
    { row = 50, column = 20, reason = "Expected this to be 'number', but got 'string'" },
    { row = 52, column = 22, reason = "invalid queue capability; expected 'Batch' or 'State'" },
    { row = 60, column = 29, reason = "Expected this to be 'string', but got 'number'" },
})

local exampleProjectPath = "examples/reliable-events/default.project.json"
local exampleProject = serde.decode("json", fs.readFile(exampleProjectPath))
assert(exampleProject.tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "example project must enable the new type solver")
local exampleSourcemapPath = TEMP_ROOT .. "/example-sourcemap.json"
local exampleSourcemap = exec("rojo", { "sourcemap", exampleProjectPath, "--output", exampleSourcemapPath })
assert(exampleSourcemap.ok, `example sourcemap generation failed\n{exampleSourcemap.stdout}\n{exampleSourcemap.stderr}`)
-- Rojo's relative sourcemap paths are rooted at the example project directory.
local exampleResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. exampleSourcemapPath,
    "../../src/init.luau", "Definition.luau", "ordered.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/reliable-events")
local exampleOutput = exampleResult.stdout .. "\n" .. exampleResult.stderr
assert(exampleResult.ok, `Studio examples failed\n{exampleOutput}`)
assertNoCrash(exampleOutput, exampleProjectPath)
assert(#diagnostics(exampleOutput) == 0, `Studio examples produced diagnostics\n{exampleOutput}`)

print("PASS public type consumer and Studio examples")
