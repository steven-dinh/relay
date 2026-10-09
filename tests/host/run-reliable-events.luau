local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Host = require("../../benchmarks/host/HostRuntime")

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
    "listener-disconnect", "client-listener-error-yield", "recipient-list-exclusion", "once-diagnostics",
    "rpc-results-deadline-cancel", "bounded-batch-handler-starts", "listener-readiness-claims", "server-listener-error-yield",
    "mismatch-loss-timeout", "transport-mutation-contamination", "cleanup-100-cycles",
    "string-overlong-per-player-charged", "string-overlong-aggregate-charged",
    "malformed-composite-charged",
}

local function sameNumbers(actual, expected)
    assert(type(actual) == "table" and #actual == #expected, "native proof cardinality")
    for index, value in expected do assert(actual[index] == value, "native proof value/order") end
end

local function validPlayerId(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
        and value ~= 0 and math.floor(value) == value
end

local function checkReport(report, selected, reliable, unreliable, logical)
    assert(type(report) == "table" and report.selected == selected
        and report.reliableHandoffs == reliable and report.unreliableHandoffs == unreliable
        and report.logicalHandoffs == logical, "native FIFO handoff report")
end

local function validateQueued(result, clientCount)
    local queued = result.queued
    assert(type(queued) == "table" and type(queued.frames) == "table"
        and type(queued.frames.Reliable) == "table" and type(queued.frames.Unreliable) == "table",
        "missing native FIFO endpoint observations")
    assert(type(queued.normalReports) == "table" and #queued.normalReports == clientCount,
        "missing native FIFO client reports")
    local clientIds = {}
    local seenClients = {}
    for index, entry in queued.normalReports do
        assert(validPlayerId(entry.client) and not seenClients[entry.client], "native client identity")
        seenClients[entry.client] = true
        clientIds[index] = entry.client
        checkReport(entry.report, 3, 1, 1, 3)
    end
    table.sort(clientIds)

    local function findFrame(frames, client, channel, kind, ids, values)
        for _, frame in frames do
            if frame.client == client and frame.endpoint == 0 and frame.channel == channel
                and frame.kind == kind and frame.count == #ids
                and type(frame.bytes) == "number" and frame.bytes <= (if channel == "Reliable" then 8_192 else 900)
            then
                local matches = #frame.ids == #ids and #frame.values == #values
                if matches then
                    for index, id in ids do
                        if frame.ids[index] ~= id or frame.values[index] ~= values[index] then
                            matches = false
                            break
                        end
                    end
                end
                if matches then return frame end
            end
        end
        return nil
    end

    assert(type(queued.inputObservations) == "table" and #queued.inputObservations == clientCount,
        "native FIFO handler observations")
    for index, entry in queued.inputObservations do
        assert(entry.client == queued.normalReports[index].client, "native input/client mapping")
        sameNumbers(entry.values, if index == 1 then { 1, 2, 3 } else { 1, 2 })
        sameNumbers(entry.independentValues, if index == 1 then { 5 } else {})
        assert(type(entry.unreliableValues) == "table" and #entry.unreliableValues <= 1
            and (entry.unreliableValues[1] == nil or entry.unreliableValues[1] == 1),
            "bounded native unreliable input sample")
        assert(findFrame(queued.frames.Reliable, entry.client, "Reliable", 1, { 1, 1 }, { 1, 2 }) ~= nil,
            "actual format-2 reliable buffer at endpoint 0")
    end
    local yield = queued.yield
    assert(type(yield) == "table" and yield.client == queued.normalReports[1].client
        and yield.blockedValue == 4 and yield.completed == true and yield.busy >= 1
        and type(yield.order) == "table" and #yield.order == 2
        and yield.order[1].event == "QueueInput" and yield.order[1].value == 3
        and yield.order[2].event == "IndependentInput" and yield.order[2].value == 5,
        "yielding FIFO ordering and same-endpoint admission")
    assert(findFrame(queued.frames.Reliable, yield.client, "Reliable", 1, { 1, 1, 3 }, { 3, 4, 5 }) ~= nil,
        "yielding payload preserved in one native FIFO buffer")

    local unreliableClients = {}
    for _, frame in queued.frames.Unreliable do
        assert(frame.endpoint == 0 and frame.channel == "Unreliable" and frame.kind == 1
            and frame.count == 1 and frame.ids[1] == 2 and frame.values[1] == 1 and not unreliableClients[frame.client],
            "actual format-2 unreliable buffer observation")
        unreliableClients[frame.client] = true
    end
    for _, entry in queued.inputObservations do
        assert((#entry.unreliableValues == 1) == (unreliableClients[entry.client] == true),
            "native unreliable wire receipt matches handler observation")
    end
    if clientCount == 2 then assert(#queued.frames.Unreliable > 0, "no native unreliable FIFO receipt") end

    local hostile = queued.hostile
    assert(type(hostile) == "table" and hostile.invalidPayload == 0 and hostile.invalidEndpoint == 4
        and hostile.wrongChannel == 1 and type(hostile.stateValues) == "table"
        and hostile.stateValues[1] == 71 and hostile.stateValues[2] == 72,
        "bounded hostile kind, endpoint, direction, channel, and State controls")

    local outbound = queued.outbound
    checkReport(outbound.manual, 1, 1, 0, 1)
    checkReport(outbound.automatic, 2, clientCount, clientCount, clientCount * 2)
    checkReport(outbound.once, 1, clientCount, 0, clientCount)
    assert(type(outbound.receipts) == "table" and #outbound.receipts == clientCount,
        "native S2C targeted and fanout receipts")
    for index, receipt in outbound.receipts do
        assert(receipt.client == queued.normalReports[index].client, "native S2C client identity")
        sameNumbers(receipt.reliable, if index == 1 then { 50, 51 } else { 51 })
        sameNumbers(receipt.once, { 44 })
        assert(type(receipt.unreliable) == "table" and #receipt.unreliable <= 1
            and (receipt.unreliable[1] == nil or receipt.unreliable[1] == 52),
            "bounded native unreliable S2C sample")
    end
    assert(type(outbound.refresh) == "table" and #outbound.refresh == clientCount,
        "manual readiness refresh results")
    for _, entry in outbound.refresh do
        local refresh = entry.result
        assert(type(refresh) == "table" and refresh.nilOk == true and refresh.nilError == nil
            and refresh.falseOk == true and refresh.falseError == nil
            and refresh.trueOk == true and refresh.trueError == nil, "nil/false/true readiness refresh")
    end

    local readiness = queued.readiness
    assert(type(readiness) == "table", "native readiness claim observations")
    for _, name in { "initial", "reconnected" } do
        local snapshot = readiness[name]
        sameNumbers(snapshot.queue, clientIds)
        sameNumbers(snapshot.once, clientIds)
    end
    sameNumbers(readiness.initial.unreliable, clientIds)
    sameNumbers(readiness.initial.state, {})
    local remaining = {}
    for index, client in clientIds do if index ~= 1 then table.insert(remaining, client) end end
    sameNumbers(readiness.disconnected.queue, remaining)
    sameNumbers(readiness.disconnected.once, clientIds)
    sameNumbers(readiness.reconnected.once, clientIds)
    sameNumbers(readiness.afterOnce.once, {})
    sameNumbers(readiness.afterOnce.queue, clientIds)
    sameNumbers(readiness.afterRefresh.queue, clientIds)
    sameNumbers(readiness.afterRefresh.unreliable, clientIds)
    sameNumbers(readiness.afterRefresh.once, {})
    sameNumbers(readiness.replacement, { clientIds[1] })

    local admission = queued.admission
    assert(type(admission) == "table" and admission.invalidPayload == 1,
        "malformed final body rejected after bounded framing")
    local malformed = admission.malformedFrame
    assert(type(malformed) == "table" and malformed.endpoint == 0 and malformed.channel == "Reliable"
        and malformed.kind == 1 and malformed.count == 7 and malformed.bytes == 45,
        "malformed final body arrived in a bounded native FIFO buffer")
    sameNumbers(malformed.ids, { 1, 1, 1, 1, 1, 1, 4 })
    sameNumbers(malformed.values, { 31, 32, 33, 34, 35, 36, 2 })
    if clientCount == 2 then
        assert(admission.exact == true and admission.initialReceived == 4
            and admission.initialPerPlayerRate == 0 and admission.initialAggregateRate == 0
            and admission.hostilePlayerRate == 1
            and admission.aggregateBeforeHealthy == 0 and admission.aggregateRate == 1,
            "two-client Hello/Ack baseline, malformed batch charges its logical prefix, and capacity isolates players")
        checkReport(admission.healthyBatch, 2, 1, 0, 2)
        sameNumbers(admission.hostileDelivered, {})
        sameNumbers(admission.healthyDelivered, { 41, 42 })
        sameNumbers(admission.hostileImmediate, {})
        sameNumbers(admission.healthyImmediate, { 78 })
    else
        assert(admission.exact == false, "single-client run cannot prove cross-player capacity isolation")
        sameNumbers(admission.delivered, {})
    end
end
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
            validateQueued(result, selection.clients)
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
-- Let Studio's initial PlaceIdle task finish before creating the test executor.
-- This setup barrier is outside all correctness scenarios and measured regions.
task.wait(5)
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
local killRequested = false
if child and status == nil then
    killRequested = true
    pcall(function() child:kill() end)
    local deadline = os.clock() + 10
    while status == nil and os.clock() < deadline do task.wait(0.1) end
end
listener:stop()
local childExitConfirmed = child == nil or status ~= nil
if killRequested then
    childExitConfirmed = pcall(Host.assertStudioIdle, process.os, process.exec)
end
assert(childExitConfirmed, "Studio exit unconfirmed; launch files retained")
if fs.isFile(scriptPath) then fs.removeFile(scriptPath) end
assert(ok, tostring(failure))
print((if correctnessOnly then "PASS Relay reliable events Studio correctness (2 clients): "
    else "PASS Relay reliable events Studio matrix (1/2 correctness; 1/4/8 admission): ") .. resultPath)
