local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")

local ROBLOX_TYPES_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.d.luau"
local ROBLOX_TYPES_SHA256 = "2857EFA8245485F8C25C19C018EE1EF9B46AFAB4EFD2EA70FC3257CD3FAF7080"
local output = Verification.workspace("public-types")
local TEMP_ROOT = output.artifacts
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
    -- The legacy cache is read-only; every generated analyzer input is run-owned.
    local legacyCache = ".tmp/public-types/globalTypes.d.luau"
    if fs.isFile(legacyCache) then
        local cached = fs.readFile(legacyCache)
        local cachedHash = string.upper(serde.hash("sha256", cached))
        if cachedHash == ROBLOX_TYPES_SHA256 then
            fs.writeFile(DEFINITIONS_PATH, cached)
            return
        end
        assert(cachedHash == "7DB9CD4FE55A4D26F3F7D5A39B6279A376F95A6C055C71D5591C26A1D525AAF2",
            `cached Roblox definitions SHA256 mismatch: {legacyCache}`)
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

    return found
end

local function analyze(fixture)
    -- luau-lsp 1.70.1's optional definition refinement regresses composable-positive.
    -- Remove when that fixture passes without this override.
    return exec("luau-lsp", {
        "analyze",
        "--platform=roblox",
        "--flag:LuauSolverV2=true",
        "--flag:LuauDontBlockRefinementUnconditionally=false",
        "--definitions",
        `@roblox={DEFINITIONS_PATH}`,
        "--sourcemap",
        SOURCEMAP_PATH,
        "src/init.luau",
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

local function verify()
assertVersion("luau-lsp", "1.70.1")
assertVersion("rojo", "7.7.1")
ensureRobloxDefinitions()

local sourcemap = exec("rojo", { "sourcemap", "default.project.json", "--output", SOURCEMAP_PATH })
assert(sourcemap.ok, `Rojo sourcemap generation failed\n{sourcemap.stdout}\n{sourcemap.stderr}`)
assert(fs.isFile(SOURCEMAP_PATH), "Rojo did not create the public type sourcemap")

print("RUN public type consumer (LuauSolverV2)")
checkPositive("tests/types/positive.luau")
checkPositive("tests/types/composable-positive.luau")
checkPositive("tests/types/map-positive.luau")
checkPositive("tests/types/native-values-positive.luau")
checkPositive("tests/types/instance-positive.luau")
checkPositive("tests/types/quantized-positive.luau")
checkPositive("tests/types/compact-values-positive.luau")
checkPositive("tests/types/outbound-packing-positive.luau")
checkPositive("tests/types/buffers-positive.luau")
checkPositive("tests/types/state-deferral-positive.luau")
checkPositive("tests/types/rpc-bounded-positive.luau")
checkPositive("tests/types/competitive-positive.luau")
checkPositive("tests/types/transport-namespaces-positive.luau")
checkDiagnostics("tests/types/transport-namespaces-invalid.luau", {
    { row = 6, column = 17, reason = "string?" },
    { row = 12, column = 46, reason = "string?" },
})
checkDiagnostics("tests/types/competitive-invalid.luau", {
    { row = 50, column = 1, reason = "Key 'CreatePacedBatcher' not found" },
    { row = 53, column = 1, reason = "Key 'ServerBatch' not found" },
    { row = 54, column = 1, reason = "Key 'Immediate' not found" },
    { row = 55, column = 1, reason = "Key 'Ordered' not found" },
    { row = 56, column = 1, reason = "Key 'Method' not found" },
    { row = 57, column = 1, reason = "Function expects 2 arguments, but 3 are specified" },
    { row = 58, column = 31, reason = "Expected this to be 'number', but got 'string'" },
    { row = 59, column = 31, reason = "Expected this to be 'boolean', but got 'number'" },
    { row = 59, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but 3 are specified" },
    { row = 60, column = 44, reason = "Expected this to be 'boolean?', but got 'string'" },
    { row = 61, column = 87, reason = "Expected this to be 'boolean?', but got 'string'" },
    { row = 65, column = 30, reason = "Expected this to be 'boolean?', but got 'number'" },
    { row = 68, column = 33, reason = "Expected this to be '\"High\" | \"Low\" | \"Normal\"', but got '\"Other\"'" },
    { row = 72, column = 16, reason = "Expected this to be '\"Independent\"?', but got '\"Shared\"'" },
    { row = 75, column = 30, reason = "Expected this to be '\"Jump\" | \"Move\"', but got 'number'" },
    { row = 75, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but 3 are specified" },
    { row = 77, column = 26, reason = "event 'Event': timestampWindow must be number" },
    { row = 85, column = 31, reason = "event 'Event': timestampWindow requires ClientToServer direction" },
    { row = 93, column = 27, reason = "event 'Event': timestampWindow requires first field serverTime:f64" },
    { row = 103, column = 1, reason = "event 'Event': timestampWindow must be number" },
    { row = 115, column = 1, reason = "None of the overloads for function that accept 3 arguments are compatible." },
    { row = 115, column = 1, reason = "Available overloads:" },
})
checkDiagnostics("tests/types/instance-invalid.luau", {
    { row = 11, column = 28, reason = "Expected this to be" },
    { row = 12, column = 33, reason = "Expected this to be" },
    { row = 23, column = 26, reason = "Expected this to be 'BasePart', but got 'Folder'" },
    { row = 26, column = 27, reason = "Instance className must be a supported class literal" },
    { row = 29, column = 32, reason = "unsupported Instance class 'NoSuchClass'" },
    { row = 47, column = 16, reason = "map key must be string or integer" },
    { row = 50, column = 16, reason = "set element must be boolean, string, integer, or enum" },
})
checkDiagnostics("tests/types/rpc-bounded-invalid.luau", {
    { row = 5, column = 28, reason = "Expected this to be 'number', but got 'string'" },
    { row = 6, column = 38, reason = "Expected this to be 'number', but got 'string'" },
    { row = 7, column = 61, reason = "Expected this to be" },
    { row = 8, column = 63, reason = "Expected this to be" },
    { row = 9, column = 60, reason = "Expected this to be" },
    { row = 11, column = 24, reason = "request shape contains an unknown key" },
    { row = 14, column = 26, reason = "invalid request direction" },
    { row = 24, column = 1, reason = "Key 'Request' not found" },
})
checkDiagnostics("tests/types/native-values-invalid.luau", {
    { row = 41, column = 28, reason = "Expected this to be 'UDim', but got 'string'" },
    { row = 42, column = 28, reason = "Expected this to be 'UDim2', but got 'string'" },
    { row = 43, column = 28, reason = "Expected this to be 'NumberRange', but got 'string'" },
    { row = 44, column = 28, reason = "Expected this to be 'Rect', but got 'string'" },
    { row = 45, column = 28, reason = "Expected this to be 'BrickColor', but got 'string'" },
    { row = 46, column = 28, reason = "Expected this to be 'Vector2int16', but got 'string'" },
    { row = 47, column = 28, reason = "Expected this to be 'Vector3int16', but got 'string'" },
    { row = 48, column = 28, reason = "Expected this to be 'NumberSequence', but got 'string'" },
    { row = 49, column = 28, reason = "Expected this to be 'ColorSequence', but got 'string'" },
    { row = 50, column = 29, reason = "Expected this to be 'NumberSequenceKeypoint', but got 'string'" },
    { row = 51, column = 29, reason = "Expected this to be 'ColorSequenceKeypoint', but got 'string'" },
    { row = 52, column = 29, reason = "Expected this to be 'TweenInfo', but got 'string'" },
    { row = 53, column = 29, reason = "Expected this to be 'DateTime', but got 'string'" },
    { row = 54, column = 29, reason = "Expected this to be 'Ray', but got 'string'" },
    { row = 55, column = 29, reason = "Expected this to be 'Axes', but got 'string'" },
    { row = 56, column = 29, reason = "Expected this to be 'Faces', but got 'string'" },
    { row = 57, column = 29, reason = "Expected this to be 'Region3', but got 'string'" },
    { row = 58, column = 29, reason = "Expected this to be 'Region3int16', but got 'string'" },
    { row = 59, column = 29, reason = "Expected this to be 'PhysicalProperties', but got 'string'" },
    { row = 60, column = 29, reason = "Expected this to be 'Font', but got 'string'" },
    { row = 61, column = 29, reason = "Expected this to be 'PathWaypoint', but got 'string'" },
    { row = 62, column = 29, reason = "Expected this to be 'Enum.Material', but got 'string'" },
    { row = 63, column = 29, reason = "'Enum.Material'" },
    { row = 66, column = 32, reason = "Expected the indexer key type to be exactly `Enum.Material`, but got `Enum.KeyCode`" },
    { row = 67, column = 36, reason = "Expected the indexer key type to be exactly `Enum.Material`, but got `Enum.KeyCode`" },
    { row = 68, column = 35, reason = "'Enum.Material'" },
    { row = 69, column = 50, reason = "'Enum.Material'" },
    { row = 71, column = 33, reason = "'Enum.KeyCode'" },
    { row = 76, column = 25, reason = "Expected the indexer key type to be exactly `Enum.Material`, but got `Enum.KeyCode`" },
    { row = 79, column = 41, reason = "Expected the indexer key type to be exactly `Enum.Material`, but got `Enum.KeyCode`" },
    { row = 80, column = 15, reason = "robloxEnum values must use one enum family" },
    { row = 84, column = 19, reason = "robloxEnum requires a precise enum family" },
    { row = 87, column = 17, reason = "UDim maximumScale must be number" },
    { row = 90, column = 17, reason = "unknown Axes shape key" },
    { row = 93, column = 23, reason = "Font families has an incompatible value" },
})
checkPositive("tests/types/schema-helpers-positive.luau")
checkPositive("tests/types/schema-authoring-positive.luau")
checkDiagnostics("tests/types/schema-authoring-negative.luau", {
    { row = 22, column = 30, reason = "None of the overloads" },
    { row = 22, column = 30, reason = "Available overloads" },
    { row = 26, column = 30, reason = "None of the overloads" },
    { row = 26, column = 30, reason = "Available overloads" },
    { row = 30, column = 22, reason = "None of the overloads" },
    { row = 30, column = 22, reason = "Available overloads" },
    { row = 31, column = 23, reason = "Key 'Put' not found" },
    { row = 32, column = 25, reason = "Key 'InputBatch' not found" },
    { row = 33, column = 31, reason = "missing field 'value'" },
    { row = 34, column = 31, reason = "'{ kind: \"Other\" | \"Success\", value: number }'" },
    { row = 37, column = 25, reason = "Expected this to be 'string', but got 'number'" },
    { row = 42, column = 1, reason = "None of the overloads" },
    { row = 42, column = 1, reason = "Available overloads" },
})
checkPositive("tests/types/schema-compose-positive.luau")
checkPositive("tests/types/rpc-positive.luau")
checkPositive("tests/types/queued-positive.luau")
checkPositive("tests/types/readiness-positive.luau")
checkPositive("tests/types/ordered-unreliable-positive.luau")
checkPositive("tests/types/streams-positive.luau")
checkDiagnostics("tests/types/map-invalid.luau", {
    { row = 23, column = 26, reason = "Expected the indexer result to be exactly `number`, but got `string`" },
    { row = 24, column = 29, reason = "Expected this to be 'string', but got 'number'" },
    { row = 25, column = 30, reason = "Expected the indexer key type to be exactly `number`, but got `string`" },
    { row = 26, column = 49, reason = "Expected this to be 'number', but got 'string'" },
    { row = 28, column = 29, reason = "Expected this to be 'string', but got 'number'" },
    { row = 29, column = 29, reason = "Expected this to be 'string', but got 'number'" },
    { row = 32, column = 54, reason = "Expected this to be 'number', but got 'string'" },
    { row = 33, column = 50, reason = "Expected the indexer result to be exactly `number`, but got `string`" },
    { row = 36, column = 44, reason = "Expected this to be 'number', but got 'string'" },
    { row = 39, column = 37, reason = "Expected the indexer key type to be exactly `number`, but got `string`" },
    { row = 41, column = 16, reason = "map key must be string or integer" },
    { row = 44, column = 23, reason = "map value cannot be optional" },
    { row = 47, column = 18, reason = "child shape must not have a name" },
    { row = 50, column = 43, reason = "Expected this to be 'number', but got 'string'" },
})
checkDiagnostics("tests/types/ordered-unreliable-invalid.luau", {
    { row = 5, column = 15, reason = "OrderedUnreliable events cannot be queued" },
    { row = 12, column = 15, reason = "OrderedUnreliable events cannot be queued" },
    { row = 35, column = 26, reason = "Expected this to be 'number', but got 'string'" },
    { row = 36, column = 32, reason = "Expected this to be 'boolean', but got 'number'" },
})
checkDiagnostics("tests/types/streams-invalid.luau", {
    { row = 62, column = 12, reason = "Expected this to be 'number', but got 'string'" },
    { row = 63, column = 12, reason = "Expected this to be 'number', but got 'nil'" },
    { row = 64, column = 35, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 65, column = 53, reason = "Expected this to be 'number', but got 'string'" },
    { row = 67, column = 1, reason = "Key 'CreateStream' not found" },
    { row = 68, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 69, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 70, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 71, column = 1, reason = "Key 'CreateStream' not found" },
    { row = 72, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 73, column = 1, reason = "Key 'CreateStream' not found" },
    { row = 74, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 89, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 108, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 109, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 110, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
    { row = 111, column = 1, reason = "Key 'CreateBroadcastStream' not found" },
})
checkPositive("tests/types/endpoint-rate-positive.luau")
checkDiagnostics("tests/types/endpoint-rate-invalid.luau", {
    { row = 11, column = 10, reason = "Expected this to be 'number', but got '\"1\"'" },
    { row = 12, column = 28, reason = "Expected this to be 'number', but got 'string'" },
})
checkPositive("tests/types/admission-fairness-positive.luau")
checkDiagnostics("tests/types/admission-fairness-invalid.luau", {
    { row = 6, column = 21, reason = "Expected this to be 'number', but got 'string'" },
    { row = 7, column = 29, reason = "Expected this to be 'number', but got 'string'" },
    { row = 8, column = 36, reason = "Expected this to be 'number', but got 'string'" },
})
checkPositive("tests/types/inbound-bytes-positive.luau")
checkDiagnostics("tests/types/inbound-bytes-invalid.luau", {
    { row = 11, column = 29, reason = "Expected this to be 'number', but got 'string'" },
    { row = 12, column = 36, reason = "Expected this to be 'number', but got 'string'" },
})
checkPositive("tests/types/tagged-union-positive.luau")
checkDiagnostics("tests/types/tagged-union-invalid.luau", {
	{ row = 19, column = 26, reason = "'{ kind: \"Other\" | \"Success\", value: number }'" },
	{ row = 22, column = 31, reason = "Key 'reason' not found" },
	{ row = 25, column = 31, reason = "Key 'value' not found" },
})
checkPositive("tests/types/color3-positive.luau")
checkDiagnostics("tests/types/color3-invalid.luau", {
    { row = 11, column = 26, reason = "Expected this to be 'Color3', but got 'string'" },
    { row = 13, column = 17, reason = "Color3 does not accept minimum or maximum" },
    { row = 18, column = 15, reason = "unknown Color3 shape key 'extra'" },
    { row = 23, column = 13, reason = "set element must be boolean, string, integer, or enum" },
})
checkPositive("tests/types/rgb8-positive.luau")
checkDiagnostics("tests/types/rgb8-invalid.luau", {
    { row = 12, column = 15, reason = "unknown Color3RGB8 shape key" },
    { row = 20, column = 26, reason = "Expected this to be 'Color3', but got 'string'" },
    { row = 21, column = 1, reason = "Key 'Send' not found" },
})
checkDiagnostics("tests/types/quantized-invalid.luau", {
    { row = 11, column = 26, reason = "Expected this to be 'number', but got 'string'" },
    { row = 13, column = 44, reason = "Expected this to be 'number', but got 'string'" },
    { row = 14, column = 25, reason = "quantized step must be number" },
    { row = 18, column = 21, reason = "quantized step is required" },
    { row = 22, column = 20, reason = "unknown quantized shape key 'extra'" },
    { row = 26, column = 20, reason = "set element must be boolean, string, integer, or enum" },
    { row = 29, column = 16, reason = "map key must be string or integer" },
})
checkDiagnostics("tests/types/compact-values-invalid.luau", {
    { row = 5, column = 51, reason = "Expected this to be 'number', but got 'string'" },
    { row = 6, column = 25, reason = "quantizedVector3 step must be number" },
    { row = 10, column = 27, reason = "quantizedVector2 step is required" },
    { row = 14, column = 26, reason = "unknown quantizedVector3 shape key 'extra'" },
    { row = 18, column = 25, reason = "compactCFrame positionStep must be number" },
    { row = 30, column = 33, reason = "Expected this to be 'Vector3', but got 'string'" },
    { row = 31, column = 33, reason = "Expected this to be 'Vector2', but got 'string'" },
    { row = 32, column = 32, reason = "Expected this to be 'CFrame', but got 'Vector3'" },
    { row = 34, column = 20, reason = "set element must be boolean, string, integer, or enum" },
    { row = 37, column = 16, reason = "map key must be string or integer" },
})
checkDiagnostics("tests/types/outbound-packing-invalid.luau", {
    { row = 5, column = 23, reason = "definition bitPacking must be boolean" },
    { row = 6, column = 25, reason = "definition outboundBytes capacity must be number" },
    { row = 8, column = 28, reason = "definition outboundBytes refillPerSecond must be number" },
    { row = 10, column = 28, reason = "definition outboundBytes contains an unknown key" },
    { row = 19, column = 26, reason = "Expected this to be 'boolean', but got 'string'" },
    { row = 19, column = 34, reason = "Expected this to be '\"Idle\" | \"Run\"', but got '\"Unknown\"'" },
    { row = 29, column = 1, reason = "Function expects 1 argument, but 2 are specified" },
})
checkDiagnostics("tests/types/buffers-invalid.luau", {
    { row = 23, column = 29, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 24, column = 26, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 25, column = 26, reason = "Expected this to be 'buffer', but got '{number}'" },
    { row = 26, column = 29, reason = "Expected this to be" },
    { row = 29, column = 35, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 32, column = 9, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 34, column = 38, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 37, column = 25, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 40, column = 37, reason = "Expected this to be 'buffer', but got 'string'" },
    { row = 42, column = 31, reason = "Expected this to be 'number', but got 'string'" },
    { row = 46, column = 22, reason = "buffer maximumBytes must be number" },
    { row = 49, column = 27, reason = "buffer maximumBytes must be number" },
    { row = 52, column = 21, reason = "unknown buffer shape key" },
    { row = 55, column = 19, reason = "map key must be string or integer" },
    { row = 58, column = 23, reason = "set element must be boolean, string, integer, or enum" },
})
checkDiagnostics("tests/types/state-deferral-invalid.luau", {
    { row = 18, column = 63, reason = "Expected this to be 'boolean?', but got 'string'" },
    { row = 19, column = 59, reason = "Expected this to be '{ deferOutbound: boolean?, progress: \"Independent\"? }?', but got 'string'" },
    { row = 20, column = 77, reason = "Expected this to be 'boolean?', but got 'number'" },
    { row = 21, column = 22, reason = "Argument count mismatch. Function expects 2 arguments, but 3 are specified" },
})
checkDiagnostics("tests/types/queued-invalid.luau", {
    { row = 40, column = 1, reason = "Key 'InBatch' not found" },
    { row = 41, column = 1, reason = "Key 'Immediate' not found" },
    { row = 42, column = 34, reason = "Expected this to be 'number', but got 'string'" },
    { row = 43, column = 1, reason = "Function expects 2 arguments, but only 1 is specified" },
    { row = 44, column = 1, reason = "Key 'Put' not found" },
    { row = 45, column = 1, reason = "Key 'OutBatch' not found" },
    { row = 46, column = 1, reason = "Key 'Send' not found" },
    { row = 47, column = 1, reason = "Key 'OutBatch' not found" },
    { row = 48, column = 33, reason = "Expected this to be 'number', but got 'string'" },
    { row = 49, column = 35, reason = "Expected this to be '\"High\" | \"Low\" | \"Normal\"', but got '\"Other\"'" },
    { row = 50, column = 1, reason = "Key 'OutState' not found" },
    { row = 52, column = 22, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 53, column = 1, reason = "Function expects 3 arguments, but only 2 are specified" },
    { row = 54, column = 32, reason = "Expected this to be 'number', but got 'string'" },
    { row = 55, column = 38, reason = "Expected this to be '{ deferOutbound: boolean?, progress: \"Independent\"? }?', but got 'boolean'" },
    { row = 56, column = 20, reason = "Expected this to be 'number', but got '{Player}'" },
    { row = 56, column = 1, reason = "Function expects 2 arguments, but 3 are specified" },
    { row = 57, column = 20, reason = "Expected this to be 'number', but got 'string'" },
    { row = 59, column = 22, reason = "invalid queue capability; expected 'Batch' or 'State'" },
    { row = 67, column = 29, reason = "Expected this to be 'string', but got 'number'" },
    { row = 73, column = 1, reason = "Key 'InBatch' not found" },
    { row = 74, column = 36, reason = "Expected this to be 'number', but got 'string'" },
    { row = 75, column = 24, reason = "Expected this to be 'Player', but got 'number'" },
    { row = 76, column = 22, reason = "Expected this to be 'number', but got 'string'" },
    { row = 79, column = 45, reason = "Expected this to be 'number', but got 'string'" },
    { row = 80, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but only 1 is specified" },
    { row = 81, column = 1, reason = "Key 'InBatch' not found" },
    { row = 82, column = 1, reason = "Key 'Immediate' not found" },
    { row = 83, column = 1, reason = "Key 'Ordered' not found" },
    { row = 84, column = 1, reason = "Key 'Method' not found" },
    { row = 85, column = 31, reason = "Expected this to be 'number', but got 'string'" },
    { row = 86, column = 31, reason = "Expected this to be 'number', but got '{Player}'" },
    { row = 86, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but 3 are specified" },
    { row = 87, column = 1, reason = "Key 'CreateBroadcastBatcher' not found" },
    { row = 91, column = 53, reason = "Expected this to be 'boolean', but got 'string'" },
    { row = 92, column = 1, reason = "Key 'Send' not found" },
    { row = 93, column = 1, reason = "Key 'InBatch' not found" },
    { row = 94, column = 1, reason = "Key 'InState' not found" },
    { row = 95, column = 1, reason = "Key 'OutBatch' not found" },
    { row = 96, column = 1, reason = "Key 'Immediate' not found" },
    { row = 97, column = 1, reason = "Key 'Ordered' not found" },
    { row = 98, column = 1, reason = "Key 'Method' not found" },
    { row = 99, column = 29, reason = "Expected this to be 'number', but got 'string'" },
    { row = 100, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but only 1 is specified" },
    { row = 101, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but 3 are specified" },
    { row = 102, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but 3 are specified" },
    { row = 103, column = 1, reason = "Key 'CreateBroadcastState' not found" },
    { row = 105, column = 1, reason = "Key 'CreatePacedBatcher' not found" },
    { row = 107, column = 1, reason = "Key 'OutBatch' not found" },
    { row = 108, column = 1, reason = "Key 'Immediate' not found" },
    { row = 109, column = 1, reason = "Key 'Ordered' not found" },
    { row = 110, column = 1, reason = "Key 'Method' not found" },
    { row = 111, column = 27, reason = "Expected this to be 'number', but got 'string'" },
    { row = 112, column = 1, reason = "Argument count mismatch. Function expects 2 arguments, but only 1 is specified" },
    { row = 113, column = 27, reason = "Expected this to be 'number', but got 'string'" },
    { row = 114, column = 44, reason = "Expected this to be 'boolean?', but got 'string'" },
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
    { row = 23, column = 34, reason = "Expected this to be 'string', but got 'number'" },
    { row = 24, column = 31, reason = "Expected this to be '\"Done\"'" },
    { row = 27, column = 1, reason = "Key 'ConnectWithContext' not found" },
    { row = 29, column = 1, reason = "Function expects 1 argument, but 2 are specified" },
    { row = 32, column = 27, reason = "Expected this to be 'string', but got 'number'" },
    { row = 35, column = 11, reason = "Key 'value' not found" },
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
checkDiagnostics("tests/types/schema-compose-invalid.luau", {
    { row = 42, column = 32, reason = "Expected this to be 'boolean', but got 'string'" },
    { row = 43, column = 1, reason = "Key 'Send' not found" },
    { row = 44, column = 42, reason = "Expected this to be 'number', but got 'string'" },
    { row = 45, column = 69, reason = "Expected this to be 'boolean', but got 'number'" },
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
    { row = 47, column = 1, reason = "None of the overloads" },
    { row = 47, column = 1, reason = "Available overloads" },
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
    { row = 53, column = 25, reason = "event 'Input': invalid event delivery; expected 'Reliable', 'Unreliable', or 'OrderedUnreliable'" },
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

local exampleProjectPath = "examples/reliable-events/default.project.json"
local exampleProject = serde.decode("json", fs.readFile(exampleProjectPath))
assert(exampleProject.tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "example project must enable the new type solver")
local exampleSourcemapPath = TEMP_ROOT .. "/example-sourcemap.json"
local exampleSourcemap = exec("rojo", { "sourcemap", exampleProjectPath, "--output", exampleSourcemapPath })
assert(exampleSourcemap.ok, `example sourcemap generation failed\n{exampleSourcemap.stdout}\n{exampleSourcemap.stderr}`)
-- Rojo's relative sourcemap paths are rooted at the example project directory.
local exampleResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. exampleSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau", "Definition.luau", "ordered.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/reliable-events")
local exampleOutput = exampleResult.stdout .. "\n" .. exampleResult.stderr
assert(exampleResult.ok, `Studio examples failed\n{exampleOutput}`)
assertNoCrash(exampleOutput, exampleProjectPath)
assert(#diagnostics(exampleOutput) == 0, `Studio examples produced diagnostics\n{exampleOutput}`)

-- The site reuses these strict, solver-checked scripts rather than maintaining
-- independent API snippets. Check its local navigation and reference anchors.
local site = fs.readFile("docs/index.html")
local readme = fs.readFile("README.md")
local reference = fs.readFile("docs/reference.md")
local publishedReference = "https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md"
for path, document in pairs({
    ["README.md"] = readme,
    ["docs/reference.md"] = reference,
    ["docs/index.html"] = site,
}) do
    assert(string.find(document, publishedReference, 1, true),
        `missing published v0.2.0 reference in {path}`)
end
assert(string.find(readme, "[Development API and protocol reference](docs/reference.md)", 1, true),
    "README must retain its development reference link")
assert(string.find(reference, "https://github.com/steven-dinh/relay/blob/main/docs/reference.md", 1, true),
    "reference must retain its mutable main link")
assert(string.find(site, 'href="https://github.com/steven-dinh/relay/blob/main/docs/reference.md#events"', 1, true),
    "site must retain its mutable main anchor link")
for _, name in { "Definition.luau", "Server.server.luau", "Client.client.luau" } do
    local opener = `<code data-file="{name}">`
    local startAt, endAt = string.find(site, opener, 1, true)
    assert(startAt and endAt and not string.find(site, opener, endAt + 1, true), `site snippet {name} missing or duplicated`)
    local closing = string.find(site, "</code>", endAt + 1, true)
    assert(closing, `site snippet {name} is unterminated`)
    local rendered = string.sub(site, endAt + 1, closing - 1):gsub("\r\n", "\n")
    local source = fs.readFile(`examples/reliable-events/{name}`):gsub("\r\n", "\n")
    assert(string.sub(source, -1) == "\n", `example {name} lacks final newline`)
    local escaped = string.sub(source, 1, -2):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    assert(rendered == escaped,
        `site snippet {name} differs from typed example`)
end
local ids = {}
for id in string.gmatch(site, ' id="([^"]+)"') do
    assert(not ids[id], `duplicate site anchor {id}`)
    ids[id] = true
end
local referenceAnchors = {}
for heading in string.gmatch(reference, "\n#+ ([^\n]+)") do
    local anchor = string.lower(heading):gsub("`", ""):gsub("[^%w%s-]", ""):gsub("%s+", "-")
    referenceAnchors[anchor] = true
end
for href in string.gmatch(site, ' href="([^"]+)"') do
    if string.sub(href, 1, 1) == "#" then
        assert(ids[string.sub(href, 2)], `broken site anchor {href}`)
    end
    local referenceAnchor = string.match(href,
        "^https://github%.com/steven%-dinh/relay/blob/main/docs/reference%.md#([%w%-]+)$")
    if referenceAnchor then
        assert(referenceAnchors[referenceAnchor], `broken API reference anchor {href}`)
    end
end

local adoptionSourcemapPath = TEMP_ROOT .. "/combat-inventory-sourcemap.json"
local adoptionSourcemap = exec("rojo", {
    "sourcemap", "examples/combat-inventory/default.project.json", "--output", adoptionSourcemapPath,
})
assert(adoptionSourcemap.ok, `combat/inventory sourcemap generation failed\n{adoptionSourcemap.stderr}`)
local adoptionResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. adoptionSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau", "Combat.luau", "Inventory.luau",
    "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/combat-inventory")
local adoptionOutput = adoptionResult.stdout .. "\n" .. adoptionResult.stderr
assert(adoptionResult.ok, `combat/inventory examples failed\n{adoptionOutput}`)
assertNoCrash(adoptionOutput, "combat/inventory examples")
assert(#diagnostics(adoptionOutput) == 0, `combat/inventory examples produced diagnostics\n{adoptionOutput}`)

local stateExampleProject = "examples/state-snapshots/default.project.json"
assert(serde.decode("json", fs.readFile(stateExampleProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "state example must enable the new type solver")
local stateExampleSourcemapPath = TEMP_ROOT .. "/state-snapshots-sourcemap.json"
local stateExampleSourcemap = exec("rojo", {
    "sourcemap", stateExampleProject, "--output", stateExampleSourcemapPath,
})
assert(stateExampleSourcemap.ok, `state example sourcemap generation failed\n{stateExampleSourcemap.stderr}`)
local stateExampleResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. stateExampleSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau",
    "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/state-snapshots")
local stateExampleOutput = stateExampleResult.stdout .. "\n" .. stateExampleResult.stderr
assert(stateExampleResult.ok, `state examples failed\n{stateExampleOutput}`)
assertNoCrash(stateExampleOutput, stateExampleProject)
assert(#diagnostics(stateExampleOutput) == 0, `state examples produced diagnostics\n{stateExampleOutput}`)

local testingProject = "examples/testing/default.project.json"
assert(serde.decode("json", fs.readFile(testingProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "consumer testing example must enable the new type solver")
local testingSourcemapPath = TEMP_ROOT .. "/consumer-testing-sourcemap.json"
local testingSourcemap = exec("rojo", {
    "sourcemap", testingProject, "--output", testingSourcemapPath,
})
assert(testingSourcemap.ok, `consumer testing sourcemap generation failed\n{testingSourcemap.stderr}`)
local testingResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. testingSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau",
    "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/testing")
local testingOutput = testingResult.stdout .. "\n" .. testingResult.stderr
assert(testingResult.ok, `consumer testing examples failed\n{testingOutput}`)
assertNoCrash(testingOutput, testingProject)
assert(#diagnostics(testingOutput) == 0, `consumer testing examples produced diagnostics\n{testingOutput}`)

local interestProject = "examples/interest-management/default.project.json"
assert(serde.decode("json", fs.readFile(interestProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "interest management example must enable the new type solver")
local interestSourcemapPath = TEMP_ROOT .. "/interest-management-sourcemap.json"
local interestSourcemap = exec("rojo", {
    "sourcemap", interestProject, "--output", interestSourcemapPath,
})
assert(interestSourcemap.ok, `interest management sourcemap generation failed\n{interestSourcemap.stderr}`)
local interestResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. interestSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau",
    "Groups.luau", "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/interest-management")
local interestOutput = interestResult.stdout .. "\n" .. interestResult.stderr
assert(interestResult.ok, `interest management example failed\n{interestOutput}`)
assertNoCrash(interestOutput, interestProject)
assert(#diagnostics(interestOutput) == 0, `interest management example produced diagnostics\n{interestOutput}`)
local broadcastExampleProject = "examples/shared-broadcast/default.project.json"
assert(serde.decode("json", fs.readFile(broadcastExampleProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "shared broadcast example must enable the new type solver")
local broadcastSourcemapPath = TEMP_ROOT .. "/shared-broadcast-sourcemap.json"
local broadcastSourcemap = exec("rojo", {
    "sourcemap", broadcastExampleProject, "--output", broadcastSourcemapPath,
})
assert(broadcastSourcemap.ok, `shared broadcast sourcemap generation failed\n{broadcastSourcemap.stderr}`)
local broadcastExampleResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. broadcastSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau",
    "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/shared-broadcast")
local broadcastExampleOutput = broadcastExampleResult.stdout .. "\n" .. broadcastExampleResult.stderr
assert(broadcastExampleResult.ok, `shared broadcast examples failed\n{broadcastExampleOutput}`)
assertNoCrash(broadcastExampleOutput, broadcastExampleProject)
assert(#diagnostics(broadcastExampleOutput) == 0, `shared broadcast examples produced diagnostics\n{broadcastExampleOutput}`)

local drainProject = "examples/session-drain/default.project.json"
assert(serde.decode("json", fs.readFile(drainProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
	"session drain example must enable the new type solver")
local drainSourcemapPath = TEMP_ROOT .. "/session-drain-sourcemap.json"
local drainSourcemap = exec("rojo", { "sourcemap", drainProject, "--output", drainSourcemapPath })
assert(drainSourcemap.ok, `session drain sourcemap generation failed\n{drainSourcemap.stderr}`)
local drainResult = exec("luau-lsp", {
	"analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
	"--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
	"--sourcemap", "../../" .. drainSourcemapPath,
	"../../src/init.luau", "../../src/Schema.luau", "Definition.luau", "Drain.luau", "Server.server.luau",
}, process.cwd .. "/examples/session-drain")
local drainOutput = drainResult.stdout .. "\n" .. drainResult.stderr
assert(drainResult.ok, `session drain example failed\n{drainOutput}`)
assertNoCrash(drainOutput, drainProject)
assert(#diagnostics(drainOutput) == 0, `session drain example produced diagnostics\n{drainOutput}`)

local operationProject = "examples/operation-id-rpc/default.project.json"
assert(serde.decode("json", fs.readFile(operationProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "operation-ID example must enable the new type solver")
local operationSourcemapPath = TEMP_ROOT .. "/operation-id-rpc-sourcemap.json"
local operationSourcemap = exec("rojo", {
    "sourcemap", operationProject, "--output", operationSourcemapPath,
})
assert(operationSourcemap.ok, `operation-ID sourcemap generation failed\n{operationSourcemap.stderr}`)
local operationResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. operationSourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau",
    "Rewards.luau", "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/operation-id-rpc")
local operationOutput = operationResult.stdout .. "\n" .. operationResult.stderr
assert(operationResult.ok, `operation-ID example failed\n{operationOutput}`)
assertNoCrash(operationOutput, operationProject)
assert(#diagnostics(operationOutput) == 0, `operation-ID example produced diagnostics\n{operationOutput}`)

local entityProject = "examples/entity-state/default.project.json"
assert(serde.decode("json", fs.readFile(entityProject)).tree.Workspace["$properties"].UseNewLuauTypeSolver == "Enabled",
    "entity state example must enable the new type solver")
local entitySourcemapPath = TEMP_ROOT .. "/entity-state-sourcemap.json"
local entitySourcemap = exec("rojo", {
    "sourcemap", entityProject, "--output", entitySourcemapPath,
})
assert(entitySourcemap.ok, `entity state sourcemap generation failed\n{entitySourcemap.stderr}`)
local entityResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../" .. entitySourcemapPath,
    "../../src/init.luau", "../../src/Schema.luau",
    "Types.luau", "Server.luau", "Client.luau", "Definition.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/examples/entity-state")
local entityOutput = entityResult.stdout .. "\n" .. entityResult.stderr
assert(entityResult.ok, `entity state example failed\n{entityOutput}`)
assertNoCrash(entityOutput, entityProject)
assert(#diagnostics(entityOutput) == 0, `entity state example produced diagnostics\n{entityOutput}`)

local entityProofSourcemapPath = TEMP_ROOT .. "/entity-state-proof-sourcemap.json"
local entityProofSourcemap = exec("rojo", {
    "sourcemap", "tests/studio/entity-state/default.project.json", "--output", entityProofSourcemapPath,
})
assert(entityProofSourcemap.ok, `entity state fixture sourcemap generation failed\n{entityProofSourcemap.stderr}`)
local entityProofResult = exec("luau-lsp", {
    "analyze", "--platform=roblox", "--flag:LuauSolverV2=true", "--flag:LuauDontBlockRefinementUnconditionally=false",
    "--definitions", "@roblox=../../../" .. DEFINITIONS_PATH,
    "--sourcemap", "../../../" .. entityProofSourcemapPath,
    "../../../src/init.luau", "../../../src/Schema.luau", "Server.server.luau", "Client.client.luau",
}, process.cwd .. "/tests/studio/entity-state")
local entityProofOutput = entityProofResult.stdout .. "\n" .. entityProofResult.stderr
assert(entityProofResult.ok, `entity state native fixture failed analysis\n{entityProofOutput}`)
assertNoCrash(entityProofOutput, "entity state native fixture")
assert(#diagnostics(entityProofOutput) == 0, `entity state native fixture produced diagnostics\n{entityProofOutput}`)

print("PASS public type consumer, Studio examples and site snippets/anchors")
end

local ok, failure = pcall(verify)
if ok then
    local cleaned, cleanupFailure = pcall(output.cleanup)
    if not cleaned then ok = false; failure = cleanupFailure end
end
fs.writeFile(output.root .. "/report.json", serde.encode("json", {
    status = if ok then "passed" else "failed",
    failure = if ok then nil else string.sub(tostring(failure), 1, 8192),
    artifacts = if ok then "cleaned" else output.artifacts,
}, true) .. "\n")
if not ok then error(`public types failed; retained evidence: {output.root}\n{tostring(failure)}`, 0) end
