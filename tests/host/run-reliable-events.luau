local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local args = process.args
assert(#args == 4 and args[1] == "--studio" and args[3] == "--place", "expected --studio <absolute path> --place <path>")
local studio = args[2]
local place = args[4]
assert(process.os == "windows" and string.match(studio, "^%a:[/\\]"), "absolute Windows Studio path required")
assert(fs.isFile(studio), "Studio executable unavailable")
assert(fs.isFile(place), "proof place unavailable")
local root = string.gsub(process.cwd, "\\", "/")
if not string.match(place, "^%a:[/\\]") then place = root .. "/" .. place end
if not fs.isDir(root .. "/.tmp") then fs.writeDir(root .. "/.tmp") end

local random = process.exec("powershell.exe", {
    "-NoProfile", "-NonInteractive", "-Command", "[Guid]::NewGuid().ToString('N')",
})
assert(random.ok, "launch identity unavailable")
local launch = string.gsub(random.stdout, "%s", "")
assert(#launch == 32 and string.match(launch, "^[0-9a-f]+$"), "invalid launch identity")
local prefix = root .. "/.tmp/relay-proof-" .. launch
local scriptPath = prefix .. ".luau"
local resultPath = prefix .. ".json"
local expected = {
    { mode = "correctness", clients = 1 },
    { mode = "correctness", clients = 2 },
    { mode = "admission", clients = 1 },
    { mode = "admission", clients = 4 },
    { mode = "admission", clients = 8 },
}
local correctness = {
    "c2s-values-order", "target-isolation", "broadcast-values", "malformed-ingress",
    "listener-disconnect", "client-listener-error-yield", "server-listener-error-yield",
    "mismatch-loss-timeout", "transport-mutation-contamination", "cleanup-100-cycles",
}
local function validate(candidate)
    assert(type(candidate) == "table" and candidate.launch == launch, "result launch mismatch")
    assert(type(candidate.results) == "table", "missing proof matrix")
    for _, result in candidate.results do
        assert(type(result) == "table" and result.ok == true, "Studio scenario failed: " .. tostring(if type(result) == "table" then result.failure else result))
    end
    assert(#candidate.results == #expected, "incomplete proof matrix")
    for index, selection in expected do
        local result = candidate.results[index]
        assert(type(result) == "table" and result.kind == "RelayReliableEventsProofV1", "invalid result")
        assert(result.ok == true, "Studio scenario failed: " .. tostring(result.failure))
        assert(result.mode == selection.mode and result.clients == selection.clients, "wrong scenario cardinality")
        local required = if selection.mode == "correctness" then correctness else {
            "hostile-per-player", "hostile-aggregate", "malformed-charged",
        }
        if selection.mode == "admission" and selection.clients > 1 then
            table.insert(required, "mixed-honest-budget")
        end
        assert(type(result.completed) == "table" and #result.completed == #required, "incomplete scenario")
        for nameIndex, name in required do assert(result.completed[nameIndex] == name, "missing proof: " .. name) end
    end
end

local terminal
local listener
local port
for candidate = 49152, 49215 do
    local ok, handle = pcall(net.serve, candidate, {
        address = "http://127.0.0.1",
        handleRequest = function(request)
            if terminal ~= nil or request.method ~= "POST" or request.path ~= "/" .. launch
                or type(request.body) ~= "string" or #request.body > 32768
            then return { status = 404, body = "" } end
            terminal = request.body
            return { status = 204, body = "" }
        end,
    })
    if ok then listener = handle port = candidate break end
end
assert(listener, "proof result listener unavailable")
local function bootstrap(selection)
    return string.format([[
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local selection = {mode=%q,clients=%d}
local ok, result = pcall(function()
    return StudioTestService:ExecuteMultiplayerTestAsync(selection.clients, selection)
end)
if not ok then result = {ok=false,failure=tostring(result)} end
local response = HttpService:RequestAsync({
    Url=%q, Method="POST", Headers={["Content-Type"]="application/json"},
    Body=HttpService:JSONEncode({launch=%q,result=result}),
})
assert(response.Success and response.StatusCode == 204, "proof result egress failed")
]], selection.mode, selection.clients, "http://127.0.0.1:" .. tostring(port) .. "/" .. launch, launch)
end

local child
local status
local ok, failure = pcall(function()
    local collected = { launch = launch, results = {} }
    for index, selection in expected do
        status = nil
        terminal = nil
        local scenarioOutput = prefix .. "-" .. tostring(index) .. ".log"
        fs.writeFile(scriptPath, bootstrap(selection), { overwrite = index > 1 })
        child = process.create(studio, {
            "--task", "RunScript", "--localPlaceFile", place,
            "--runScriptFile", scriptPath, "--outputFile", scenarioOutput, "--quitAfterExecution",
        }, { cwd = root })
        task.spawn(function() status = child:status() end)
        for _, reader in { child.stdout, child.stderr } do
            task.spawn(function() while reader:read() ~= nil do end end)
        end
        local deadline = os.clock() + 240
        while status == nil and os.clock() < deadline do task.wait(0.1) end
        assert(status ~= nil, "Studio proof timeout")
        assert(status.ok == true, "Studio process failed")
        assert(terminal ~= nil, "Studio proof result missing; inspect " .. scenarioOutput)
        local candidate = serde.decode("json", terminal)
        assert(type(candidate) == "table" and candidate.launch == launch and type(candidate.result) == "table", "invalid scenario result")
        table.insert(collected.results, candidate.result)
        fs.writeFile(resultPath, serde.encode("json", collected), { overwrite = index > 1 })
        assert(candidate.result.ok == true, "Studio scenario failed: " .. tostring(candidate.result.failure))
        print("Completed Studio " .. selection.mode .. " / " .. tostring(selection.clients) .. " clients")
    end
    validate(serde.decode("json", fs.readFile(resultPath)))
end)
if child and status == nil then
    pcall(function() child:kill() end)
    local deadline = os.clock() + 10
    while status == nil and os.clock() < deadline do task.wait(0.1) end
end
listener:stop()
assert(child == nil or status ~= nil, "Studio did not exit; launch files retained")
if fs.isFile(scriptPath) then fs.removeFile(scriptPath) end
assert(ok, tostring(failure))
print("PASS Relay reliable events Studio matrix (1/2 correctness; 1/4/8 admission): " .. resultPath)
