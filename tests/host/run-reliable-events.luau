local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local args = process.args
local correctnessOnly = #args == 5 and args[5] == "--correctness-only"
assert((#args == 4 or correctnessOnly) and args[1] == "--studio" and args[3] == "--place",
    "expected --studio <absolute path> --place <path> followed by optional --correctness-only")
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
if correctnessOnly then expected = { { mode = "correctness", clients = 2 } } end
local correctness = {
    "c2s-values-order", "target-isolation", "broadcast-values", "unreliable-routing-audience", "schema-native-values",
    "composable-native-values", "cframe-native-boundaries", "malformed-ingress", "malformed-composite-buffer",
    "listener-disconnect", "client-listener-error-yield", "server-listener-error-yield",
    "mismatch-loss-timeout", "transport-mutation-contamination", "cleanup-100-cycles",
    "string-overlong-per-player-charged", "string-overlong-aggregate-charged",
    "malformed-composite-charged",
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
        if selection.mode == "correctness" then
            local unreliable = result.unreliable
            assert(type(unreliable) == "table" and unreliable.sampleCount == 8, "missing unreliable sample diagnostics")
            local function checkSamples(samples, minimum, maximum, requireDelivery)
                assert(type(samples) == "table" and #samples <= unreliable.sampleCount, "unbounded unreliable sample set")
                local seen = {}
                for _, sample in samples do
                    assert(type(sample) == "table" and type(sample.sampleId) == "number"
                        and sample.sampleId % 1 == 0 and sample.sampleId >= minimum and sample.sampleId <= maximum,
                        "unreliable sample identity/range")
                    assert(not seen[sample.sampleId], "duplicate unreliable sample identity")
                    seen[sample.sampleId] = true
                    assert(sample.value == sample.sampleId * 257 and sample.enabled == (sample.sampleId % 2 == 0),
                        "unreliable native tuple")
                end
                if requireDelivery then assert(#samples > 0, "unreliable path had no observed delivery") end
            end
            local c2sClients = {}
            assert(type(unreliable.c2s) == "table" and #unreliable.c2s == selection.clients, "unreliable C2S audience count")
            for _, entry in unreliable.c2s do
                assert(type(entry.client) == "number" and not c2sClients[entry.client], "unreliable C2S client identity")
                c2sClients[entry.client] = true
                checkSamples(entry.samples, 1, unreliable.sampleCount, true)
            end
            local function checkClientEntries(entries, minimum, maximum, direction)
                assert(type(entries) == "table" and #entries == selection.clients, "unreliable S2C audience count")
                local seen, targetedCount = {}, 0
                for _, entry in entries do
                    assert(type(entry.client) == "number" and c2sClients[entry.client] and not seen[entry.client],
                        "unreliable S2C client identity")
                    seen[entry.client] = true
                    checkSamples(entry.samples, minimum, maximum,
                        direction == "broadcast" or (direction == "targeted" and entry.targeted == true))
                    if direction == "targeted" then
                        assert(type(entry.targeted) == "boolean", "unreliable targeted recipient marker")
                        if entry.targeted then targetedCount += 1
                        else assert(#entry.samples == 0, "unreliable targeted isolation") end
                    end
                end
                if direction == "targeted" then assert(targetedCount == 1, "unreliable targeted recipient count") end
            end
            checkClientEntries(unreliable.targeted, unreliable.sampleCount + 1, unreliable.sampleCount * 2, "targeted")
            checkClientEntries(unreliable.broadcast, unreliable.sampleCount * 2 + 1, unreliable.sampleCount * 3, "broadcast")

            local diagnostics = result.cframe
            assert(type(diagnostics) == "table" and #diagnostics.serverSources == 11, "missing CFrame sources")
            local sourceNames = { "identity-zero", "general", "translation-boundary", "norm-inside", "norm-outside",
                "shear-inside", "shear-outside", "inverse-scale", "determinant-inside", "determinant-outside", "translation-outside" }
            local expectedAcceptance = { true, true, true, true, false, true, false, false, true, false, false }
            local function checkSources(sources)
                assert(type(sources) == "table" and #sources == 11, "CFrame source count")
                for index, source in sources do
                    assert(source.name == sourceNames[index] and #source.components == 12 and #source.zeroSigns == 12 and #source.residuals == 7,
                        "CFrame source identity/components")
                    assert(type(source.valid) == "boolean" and source.valid == expectedAcceptance[index] and source.expected == expectedAcceptance[index] and source.localPreserved == true,
                        "CFrame source acceptance")
                end
            end
            checkSources(diagnostics.serverSources)
            local clients = {}
            for _, direction in { "c2s", "targeted", "broadcast" } do
                local entries = diagnostics[direction]
                assert(type(entries) == "table" and #entries == (if direction == "targeted" then 1 else selection.clients),
                    "CFrame direction audience")
                local seen = {}
                for _, entry in entries do
                    assert(type(entry.client) == "number" and not seen[entry.client], "CFrame unique client identity")
                    seen[entry.client] = true
                    if direction == "c2s" then clients[entry.client] = true checkSources(entry.sources)
                    else assert(clients[entry.client], "CFrame audience identity") end
                    assert(#entry.raw == 11 and #entry.delivered == 11 and #entry.deliveryValues == 11, "CFrame observation count")
                    assert(entry.rawState.count == 11 and entry.rawState.last == 11 and not entry.rawState.failure
                        and not entry.deliveryState.failure, "CFrame callback identity/order evidence")
                    local deliveredCount, lastDelivered = 0, 0
                    for index, observation in entry.raw do
                        assert(observation.caseId == index and #observation.components == 12 and #observation.zeroSigns == 12 and #observation.residuals == 7,
                            "CFrame raw case identity/components")
                        assert(type(observation.valid) == "boolean" and type(entry.delivered[index]) == "boolean"
                            and type(observation.translationDelta) == "number" and type(observation.rotationDelta) == "number",
                            "CFrame raw validity/delta evidence")
                        assert(observation.valid == entry.delivered[index], "CFrame received predicate/delivery")
                        if expectedAcceptance[index] then
                            assert(observation.valid and observation.translationDelta == 0
                                and observation.rotationDelta >= 0 and observation.rotationDelta <= 0.0001,
                                "CFrame stable native precision")
                        end
                        if index == 11 then assert(not observation.valid, "CFrame raw translation overflow") end
                        if entry.delivered[index] then
                            deliveredCount += 1
                            lastDelivered = index
                            local actual = entry.deliveryValues[index]
                            assert(type(actual) == "table" and actual.caseId == index and actual.valid, "CFrame delivered pose evidence")
                            for component = 1, 12 do
                                assert(actual.components[component] == observation.components[component]
                                    and actual.zeroSigns[component] == observation.zeroSigns[component], "CFrame Relay tuple preservation")
                            end
                        else assert(entry.deliveryValues[index] == false, "CFrame absent delivery evidence") end
                    end
                    assert(entry.deliveryState.count == deliveredCount and entry.deliveryState.last == lastDelivered,
                        "CFrame exact delivery count")
                end
            end
        end
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
                or type(request.body) ~= "string" or #request.body > 131072
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
print((if correctnessOnly then "PASS Relay reliable events Studio correctness (2 clients): "
    else "PASS Relay reliable events Studio matrix (1/2 correctness; 1/4/8 admission): ") .. resultPath)
