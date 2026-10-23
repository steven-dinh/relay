local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Host = require("../../benchmarks/host/HostRuntime")
local MAXIMUM_PROOF_RESULT_BYTES = 262144

local args = process.args
local modeFlag = args[5]
local correctnessOnly = modeFlag == "--correctness-only"
local competitiveOnly = modeFlag == "--competitive-only"
assert((#args == 4 or (#args == 5 and (correctnessOnly or competitiveOnly)))
    and args[1] == "--studio" and args[3] == "--place",
    "expected --studio <absolute path> --place <path> followed by one optional proof mode flag")
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
if competitiveOnly then expected = { { mode = "competitive", clients = 2 } } end
local correctness = {
    "c2s-values-order", "target-isolation", "broadcast-values", "unreliable-routing-audience", "schema-native-values",
    "composable-native-values", "cframe-native-boundaries", "malformed-ingress", "malformed-composite-buffer",
    "listener-disconnect", "client-listener-error-yield", "recipient-list-exclusion", "once-diagnostics",
    "rpc-results-deadline-cancel", "bounded-batch-handler-starts", "listener-readiness-claims", "reusable-opt-in-batching", "native-state-put-expiry", "server-listener-error-yield",
    "mismatch-loss-timeout", "transport-mutation-contamination", "cleanup-100-cycles",
    "string-overlong-per-player-charged", "string-overlong-aggregate-charged",
    "malformed-composite-charged",
    "per-endpoint-rate-burst",
    "color3-native-values",
    "rgb8-color3-native",
    "tagged-union-native-values",
    "full-width-readiness-64", "content-byte-admission",
    "handler-cancellation-contract",
    "ordered-unreliable-native",
    "native-roblox-values",
    "native-instance-references",
    "bounded-scalar-quantization",
    "compact-native-values",
    "outbound-byte-backpressure",
    "packed-flags-enums",
    "bounded-native-buffers",
    "single-player-state-deferral",
    "rpc-bounded-routes", "shared-broadcast-batching",
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

local function checkReusableValues(values)
    assert(type(values) == "table" and #values == 2 and values[1] == false and values[2] == true,
        "reusable native windows preserve false and later values")
end

local function checkReusableWindow(status)
    assert(type(status) == "table" and status.state == "Open" and status.pendingRecords == 0
        and type(status.lastFlush) == "table" and status.lastFlush.ok == true and status.lastFlush.error == nil,
        "reusable native window status reopened empty")
    checkReport(status.lastFlush.report, 1, 1, 0, 1)
end

local function checkReusableCleanup(cleanup, sendAfterCancel, slotReleased)
    assert(type(cleanup) == "table" and cleanup.state == "Terminal" and cleanup.pendingRecords == 0
        and sendAfterCancel == false and slotReleased == true,
        "reusable Cancel is terminal, rejects sends, and releases the queue slot")
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

    local reusable = queued.reusable
    assert(type(reusable) == "table" and type(reusable.clientInputs) == "table"
        and #reusable.clientInputs == clientCount and type(reusable.clientReports) == "table"
        and #reusable.clientReports == clientCount and type(reusable.outbound) == "table",
        "missing reusable native batcher observations")
    local reusableClients = {}
    local reusableClientCount = 0
    for index, entry in reusable.clientInputs do
        local expectedClient = queued.normalReports[index].client
        local reportEntry = reusable.clientReports[index]
        assert(type(entry) == "table" and entry.client == expectedClient and not reusableClients[entry.client],
            "reusable client-to-server actual Player identity")
        reusableClients[entry.client] = true
        reusableClientCount += 1
        checkReusableValues(entry.values)
        assert(type(reportEntry) == "table" and reportEntry.client == entry.client
            and type(reportEntry.report) == "table" and reportEntry.report.client == entry.client
            and reportEntry.report.sameEventHandle == true,
            "reusable client sender report identity and event handle")
        local report = reportEntry.report
        checkReport(report.manualReport, 1, 1, 0, 1)
        checkReusableWindow(report.manualStatus)
        checkReusableWindow(report.automaticStatus)
        checkReusableCleanup(report.cleanup, report.sendAfterCancel, report.slotReleased)
    end
    assert(reusableClientCount == clientCount, "reusable client Player IDs are distinct")

    local reusableOutbound = reusable.outbound
    assert(validPlayerId(reusableOutbound.recipient) and reusableOutbound.recipient == clientIds[1]
        and reusableOutbound.sameEventHandle == true,
        "reusable server recipient and saved event handle")
    checkReusableValues(reusableOutbound.targetValues)
    if clientCount > 1 then
        assert(validPlayerId(reusableOutbound.excluded) and reusableOutbound.excluded == clientIds[2],
            "reusable fixed audience excludes the other actual Player")
    else
        assert(reusableOutbound.excluded == nil, "single-client reusable audience has no excluded Player")
    end
    assert(type(reusableOutbound.excludedValues) == "table" and #reusableOutbound.excludedValues == 0,
        "reusable fixed audience does not reach an excluded Player")
    checkReport(reusableOutbound.manualReport, 1, 1, 0, 1)
    checkReusableWindow(reusableOutbound.manualStatus)
    checkReusableWindow(reusableOutbound.automaticStatus)
    checkReusableCleanup(reusableOutbound.cleanup, reusableOutbound.sendAfterCancel, reusableOutbound.slotReleased)

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

local function validateReadiness64(proof, clientCount)
    assert(type(proof) == "table" and proof.listenerCount == 64 and proof.highestId == 65535
        and type(proof.clients) == "table" and #proof.clients == clientCount,
        "missing 64-endpoint readiness proof")
    local clientIds = {}
    for index, client in proof.clients do
        assert(validPlayerId(client.userId) and (index == 1 or client.userId > clientIds[index - 1]),
            "64-endpoint client identity/order")
        clientIds[index] = client.userId
        assert(type(client.prepared) == "table" and client.prepared.listenerCount == 64
            and client.prepared.highestId == 65535 and client.failure == nil,
            "64 listeners connected before Start and callbacks remained clean")
        assert(type(client.deliveries) == "table" and #client.deliveries == 1
            and client.deliveries[1].id == 65535 and client.deliveries[1].value == 239,
            "native reliable delivery on highest event ID")
    end

    local function sameFullMask(mask, finalByte)
        assert(type(mask) == "table" and #mask == 8, "native Ack mask width")
        for index = 1, 7 do assert(mask[index] == 255, "native Ack lower readiness bits") end
        assert(mask[8] == finalByte, "native Ack highest readiness bit")
    end
    assert(type(proof.ackRecords) == "table", "missing raw readiness Ack observations")
    local function hasAck(userId, phase, finalByte)
        for _, frame in proof.ackRecords do
            if frame.userId == userId and frame.phase == phase and frame.kind == 18 and frame.length == 90 then
                sameFullMask(frame.maskBytes, finalByte)
                return true
            end
        end
        return false
    end
    for _, userId in clientIds do
        assert(hasAck(userId, "initial", 255), "actual 90-byte initial Ack has all 64 listener bits")
    end
    assert(hasAck(clientIds[1], "reconnect", 255), "actual 90-byte reconnect Ack restores the highest bit")
    assert(hasAck(clientIds[1], "disconnect", 127)
        and hasAck(clientIds[1], "refresh", 127), "highest-bit disconnect and explicit refresh masks")
    local malformedLengths = {}
    for _, frame in proof.ackRecords do
        if frame.userId == clientIds[1] and frame.phase == "malformed" and frame.kind == 18 then
            malformedLengths[frame.length] = true
            if frame.length == 91 then sameFullMask(frame.maskBytes, 255) end
        end
    end
    assert(malformedLengths[89] and malformedLengths[91], "observed 89/91-byte copies of a full Ack")

    local readiness = proof.readiness
    assert(type(readiness) == "table", "missing readiness audience snapshots")
    local expectedDisconnected = if clientCount > 1 then { clientIds[2] } else {}
    for _, phase in { "initial", "malformed", "disconnected", "refreshed", "reconnected" } do
        local snapshot = readiness[phase]
        assert(type(snapshot) == "table", "missing 64-endpoint readiness phase " .. phase)
        sameNumbers(snapshot.highest, if phase == "disconnected" or phase == "refreshed"
            then expectedDisconnected else clientIds)
        assert(type(snapshot.others) == "table" and #snapshot.others == 63,
            "all other native readiness bits were observed")
        for eventId, endpoint in snapshot.others do
            assert(endpoint.id == eventId, "readiness endpoint identity/order")
            sameNumbers(endpoint.clients, clientIds)
        end
    end

    local malformed = proof.malformed
    assert(type(malformed) == "table" and type(malformed.before) == "table"
        and type(malformed.after) == "table"
        and malformed.before.received == clientCount * 2 and malformed.before.invalidPayload == 0
        and malformed.after.received == malformed.before.received + 2
        and malformed.after.invalidPayload == malformed.before.invalidPayload + 2
        and malformed.after.perPlayerBytes == malformed.before.perPlayerBytes,
        "malformed readiness lengths are charged, rejected, and do not alter readiness admission")
end

local function validateContentBytes(proof, clientCount, readinessClients)
    assert(type(proof) == "table" and proof.exact == (clientCount == 2),
        "content-byte cross-player proof cardinality")
    if clientCount ~= 2 then return end
    assert(type(proof.perPlayer) == "table" and #proof.perPlayer == 2
        and type(proof.endpoint) == "table" and #proof.endpoint == 2,
        "missing FIFO and State byte-admission cases")
    local clientIds = { readinessClients[1].userId, readinessClients[2].userId }

    local function counters(actual, expected)
        assert(type(actual) == "table", "missing native admission counters")
        local count = 0
        for name, value in actual do
            count += 1
            assert(expected[name] == value, "native admission counter " .. name)
        end
        local expectedCount = 0
        for _ in expected do expectedCount += 1 end
        assert(count == expectedCount, "native admission counter schema")
    end
    local initial = { received = 4, perPlayerRate = 0, aggregateRate = 0, perPlayerBytes = 0,
        aggregateBytes = 0, endpointRate = 0, invalidPayload = 0 }
    local refused = { received = 5, perPlayerRate = 0, aggregateRate = 0, perPlayerBytes = 1,
        aggregateBytes = 0, endpointRate = 0, invalidPayload = 0 }
    local recovered = { received = 8, perPlayerRate = 1, aggregateRate = 0, perPlayerBytes = 1,
        aggregateBytes = 0, endpointRate = 0, invalidPayload = 0 }
    local endpointRejected = { received = 5, perPlayerRate = 0, aggregateRate = 0, perPlayerBytes = 0,
        aggregateBytes = 0, endpointRate = 1, invalidPayload = 0 }
    local immediateRefused = { received = 6, perPlayerRate = 0, aggregateRate = 0, perPlayerBytes = 1,
        aggregateBytes = 0, endpointRate = 1, invalidPayload = 0 }

    local function checkFrame(frame, userId, kind, count, bytes, ids, values)
        assert(type(frame) == "table" and frame.client == userId and frame.endpoint == 0
            and frame.channel == "Reliable" and frame.kind == kind and frame.count == count and frame.bytes == bytes,
            "native exact content-byte frame")
        sameNumbers(frame.ids, ids)
        sameNumbers(frame.values, values)
    end
    for index, entry in proof.perPlayer do
        local kind = index
        local eventId = if kind == 1 then 1 else 5
        assert(entry.kind == kind and entry.eventId == eventId
            and entry.hostile == clientIds[1] and entry.healthy == clientIds[2],
            "per-player byte case identity")
        counters(entry.before, initial)
        counters(entry.refused, refused)
        counters(entry.final, recovered)
        checkFrame(entry.frame, clientIds[1], kind, 2, 15, { eventId, eventId }, { 81, 82 })
        assert(type(entry.handlers) == "table" and entry.handlers.fifo == 0 and entry.handlers.state == 0
            and entry.handlers.hostileImmediate == 1 and entry.handlers.healthyImmediate == 1,
            "byte refusal has no partial FIFO/State callback and preserves the other Player")
    end
    for index, entry in proof.endpoint do
        local kind = index
        local eventId = if kind == 1 then 1 else 5
        assert(entry.kind == kind and entry.eventId == eventId and entry.client == clientIds[1],
            "endpoint-rate byte case identity")
        counters(entry.before, initial)
        counters(entry.rateRejected, endpointRejected)
        counters(entry.final, immediateRefused)
        checkFrame(entry.frame, clientIds[1], kind, 2, 15, { eventId, eventId }, { 81, 82 })
        local nativeImmediate = entry.nativeImmediate
        assert(type(nativeImmediate) == "table" and nativeImmediate.client == clientIds[1]
            and nativeImmediate.endpoint == eventId and nativeImmediate.arity == 1
            and nativeImmediate.value == 83 and nativeImmediate.contentBytes == 11,
            "native immediate endpoint/value/arity was observed before byte rejection")
        assert(type(entry.handlers) == "table" and entry.handlers.fifo == 0 and entry.handlers.state == 0,
            "endpoint and following byte rejection dispatch no partial FIFO/State callbacks")
    end
end

local function validateTaggedUnion(proof, installation, clientCount, readinessClients)
    local function exactKeys(value, names, label)
        assert(type(value) == "table", label .. " record")
        local count = 0
        for name in value do
            assert(names[name] ~= nil, label .. " unexpected field")
            count += 1
        end
        local expected = 0
        for _ in names do expected += 1 end
        assert(count == expected, label .. " field count")
    end
    local function taggedValue(actual, expected, label)
        assert(type(actual) == "table" and actual.kind == expected.kind, label .. " branch label")
        if expected.kind == "Failure" then
            exactKeys(actual, { kind = true, reason = true }, label)
            assert(actual.reason == "denied", label .. " bounded Failure value")
            return
        end
        exactKeys(actual, { kind = true, enabled = true, count = true, notePresent = true, note = true, tint = true }, label)
        assert(actual.enabled == false and actual.count == expected.count
            and actual.notePresent == expected.notePresent and actual.note == expected.note,
            label .. " Success branch fields and optional value")
        exactKeys(actual.tint, { r = true, g = true, b = true }, label .. " Color3")
        assert(type(actual.tint.r) == "number" and actual.tint.r == 0
            and type(actual.tint.g) == "number" and actual.tint.g == 0.5
            and type(actual.tint.b) == "number" and math.abs(actual.tint.b - 0.1) <= 1e-7,
            label .. " numeric native Color3 components")
    end
    local function taggedValues(actual, expected, label)
        assert(type(actual) == "table" and #actual == #expected, label .. " observation count")
        for index, value in expected do taggedValue(actual[index], value, label .. " observation " .. tostring(index)) end
    end
    local function clientEntries(entries, label)
        assert(type(entries) == "table" and #entries == clientCount, label .. " client count")
        for index, entry in entries do
            assert(type(entry) == "table" and entry.client == readinessClients[index].userId,
                label .. " actual Player identity/order")
        end
    end

    assert(type(installation) == "table" and installation.version == "0.3.0"
        and type(installation.firstInputs) == "table" and #installation.firstInputs == clientCount,
        "model-loaded Relay version and initial event evidence")
    for index, entry in installation.firstInputs do
        assert(type(entry) == "table" and entry.client == readinessClients[index].userId,
            "initial reliable event actual Player identity/order")
        sameNumbers(entry.values, { 1, 2, 3 })
    end

    assert(type(proof) == "table" and type(proof.labelOrder) == "table" and #proof.labelOrder == 2
        and proof.labelOrder[1] == "Failure" and proof.labelOrder[2] == "Success",
        "native tagged-union sorted labels")
    local expectedSuccessNil = { kind = "Success", count = 257, notePresent = false, note = false }
    local expectedSuccessString = { kind = "Success", count = 258, notePresent = true, note = "ready" }
    local expectedFailure = { kind = "Failure" }
    local correctness = proof.correctness
    assert(type(correctness) == "table", "missing native tagged-union event/RPC observations")
    clientEntries(correctness.clients, "native tagged-union correctness")
    for _, entry in correctness.clients do
        taggedValues(entry.c2s, { expectedSuccessNil, expectedSuccessString, expectedFailure }, "tagged-union C2S")
        taggedValues(entry.rpcRequests, { expectedSuccessString, expectedFailure }, "tagged-union RPC request")
        taggedValues(entry.rpcResponses, { expectedSuccessString, expectedFailure }, "tagged-union RPC response")
        taggedValues(entry.s2c, { expectedSuccessString, expectedFailure }, "tagged-union S2C")
    end

    local admission = proof.admission
    assert(type(admission) == "table" and type(admission.counters) == "table",
        "missing native tagged-union admission evidence")
    local expectedCounters = {
        received = 5 * clientCount, invalidPayload = 2 * clientCount, perPlayerRate = clientCount,
        aggregateRate = 0, dispatched = 2 * clientCount, handlerErrors = 0,
        eventDispatched = 2 * clientCount, eventInvalidPayload = 2 * clientCount,
    }
    exactKeys(admission.counters, expectedCounters, "tagged-union admission counters")
    for name, expected in expectedCounters do
        assert(admission.counters[name] == expected, "tagged-union admission counter " .. name)
    end
    clientEntries(admission.clients, "tagged-union admission")
    local expectedFrames = {
        { length = 20, ordinal = 1, byte1 = 0, byte2 = 1 },
        { length = 12, ordinal = 0, byte1 = 6, byte2 = 0 },
        { length = 6, ordinal = 2, byte1 = 0, byte2 = 0 },
        { length = 6, ordinal = 0, byte1 = 4, byte2 = 0 },
        { length = 27, ordinal = 1, byte1 = 0, byte2 = 2 },
    }
    for _, entry in admission.clients do
        taggedValues(entry.handlers, { expectedSuccessNil, expectedFailure }, "tagged-union admitted handlers")
        assert(type(entry.raw) == "table" and #entry.raw == #expectedFrames,
            "tagged-union actual reliable ingress count")
        for index, expected in expectedFrames do
            local frame = entry.raw[index]
            exactKeys(frame, { endpoint = true, format = true, eventId = true, length = true,
                ordinal = true, byte1 = true, byte2 = true },
                "tagged-union raw ingress")
            assert(frame.endpoint == 1 and frame.format == 1 and frame.eventId == 1
                and frame.length == expected.length and frame.ordinal == expected.ordinal
                and frame.byte1 == expected.byte1 and frame.byte2 == expected.byte2,
                "tagged-union raw endpoint/ordinal/branch length bytes")
        end
    end
end

local function validateNativeValues(proof, clientCount, readinessClients)
    local expectedRawProbes = {
        "datetime-fraction", "datetime-below-minimum", "datetime-above-maximum",
        "tween-infinite-repeat-default", "tween-negative-time", "tween-delay-above-maximum",
        "tween-invalid-easing-style", "tween-invalid-easing-direction",
        "tween-unsupported-easing-style-Bezier", "tween-unsupported-easing-style-Spring",
        "tween-invalid-reverses",
        "tween-infinite-repeat-opt-in", "path-label-maximum-boundary", "path-label-over-maximum",
        "path-invalid-action", "number-sequence-count-below-minimum", "number-sequence-count-above-maximum",
        "number-sequence-truncated-before-allocation", "number-sequence-duplicate-time",
        "number-sequence-first-time-not-zero", "number-sequence-last-time-not-one",
        "number-sequence-constructor-coercion", "color-sequence-count-below-minimum",
        "color-sequence-count-above-maximum", "color-sequence-truncated-before-allocation",
        "color-sequence-duplicate-time", "color-sequence-first-time-not-zero",
        "color-sequence-last-time-not-one", "color-sequence-constructor-coercion",
        "physical-density-minimum-six-fields", "physical-density-below-minimum", "physical-density-above-maximum",
        "physical-friction-below-minimum", "physical-friction-above-maximum",
        "physical-elasticity-below-minimum", "physical-elasticity-above-maximum",
        "physical-friction-weight-below-minimum", "physical-friction-weight-above-maximum",
        "physical-elasticity-weight-below-minimum", "physical-elasticity-weight-above-maximum",
        "physical-acoustic-absorption-below-minimum", "physical-acoustic-absorption-above-maximum",
    }
    local expectedGroups = {
        { name = "basic", cases = { "robloxEnum", "UDim", "UDim2", "NumberRange", "Rect", "BrickColor" } },
        { name = "vectors-sequences", cases = { "Vector2int16", "Vector3int16", "NumberSequence",
            "ColorSequence", "NumberSequenceKeypoint", "ColorSequenceKeypoint" } },
        { name = "geometry-time-font", cases = { "TweenInfo", "DateTime", "Ray", "Axes", "Faces", "Region3" } },
        { name = "region-physical-font-path", cases = { "Region3int16", "PhysicalProperties", "Font", "PathWaypoint" } },
    }
    local expectedPolicies = {
        EasingStyle = { { "Linear", 0 }, { "Sine", 1 }, { "Back", 2 }, { "Quad", 3 }, { "Quart", 4 },
            { "Quint", 5 }, { "Bounce", 6 }, { "Elastic", 7 }, { "Exponential", 8 }, { "Circular", 9 }, { "Cubic", 10 } },
        EasingDirection = { { "In", 0 }, { "Out", 1 }, { "InOut", 2 } },
        FontWeight = { { "Thin", 100 }, { "ExtraLight", 200 }, { "Light", 300 }, { "Regular", 400 },
            { "Medium", 500 }, { "SemiBold", 600 }, { "Bold", 700 }, { "ExtraBold", 800 }, { "Heavy", 900 } },
        FontStyle = { { "Normal", 0 }, { "Italic", 1 } },
        PathWaypointAction = { { "Walk", 0 }, { "Jump", 1 }, { "Custom", 2 } },
    }
    assert(type(proof) == "table" and type(proof.groups) == "table" and #proof.groups == #expectedGroups,
        "missing native value group receipts")
    local peerIds = {}
    for _, peer in readinessClients do peerIds[peer.userId] = true end
    local function sameNames(actual, expected)
        assert(type(actual) == "table" and #actual == #expected, "native value case receipt count")
        for index, name in expected do assert(actual[index] == name, "native value case receipt/order") end
    end
    local repeats = { robloxEnum = 2, BrickColor = 2, DateTime = 3, Font = 2 }
    for groupIndex, expected in expectedGroups do
        local group = proof.groups[groupIndex]
        assert(type(group) == "table" and group.name == expected.name, "native value group identity")
        sameNames(group.cases, expected.cases)
        local receiptCases = {}
        for _, name in expected.cases do
            for _ = 1, repeats[name] or 1 do table.insert(receiptCases, name) end
        end
        for _, direction in { "c2s", "s2c" } do
            local entries = group[direction]
            assert(type(entries) == "table" and #entries == clientCount, "native value peer receipt count")
            local seen = {}
            for _, entry in entries do
                assert(type(entry) == "table" and peerIds[entry.client] and not seen[entry.client],
                    "native value actual peer identity")
                seen[entry.client] = true
                sameNames(entry.cases, receiptCases)
            end
        end
    end
    assert(type(proof.intrinsicEnums) == "table", "missing intrinsic enum policy evidence")
    for familyName, expected in expectedPolicies do
        local actual = proof.intrinsicEnums[familyName]
        assert(type(actual) == "table" and #actual == #expected, "intrinsic enum policy count: " .. familyName)
        for index, pair in expected do
            assert(type(actual[index]) == "table" and actual[index].name == pair[1]
                and actual[index].value == pair[2], "intrinsic enum policy: " .. familyName)
        end
    end
    local rawProbes = proof.nativeRejections
    assert(type(rawProbes) == "table" and rawProbes.engineVerified == true
        and rawProbes.count == #expectedRawProbes, "missing Studio native malformed/coercion probe evidence")
    sameNames(rawProbes.probes, expectedRawProbes)
end

local function validateRpcBoundedRoutes(proof, clientCount, readinessClients)
    assert(type(proof) == "table" and type(proof.main) == "table" and type(proof.missing) == "table",
        "missing native RPC/bounded route evidence")
    local main, missing = proof.main, proof.missing
    local target = if type(main.rpc) == "table" then main.rpc.rpcClient else nil
    local peers = {}
    for _, peer in readinessClients do peers[peer.userId] = true end
    local insidePart = "ReplicatedStorage.RelayProofInstanceScope.InsidePart"
    local insideFolder = "ReplicatedStorage.RelayProofInstanceScope.InsideFolder"
    local outsidePart = "ReplicatedStorage.RelayProofInstances.PartReference"
    local expectedReferences = { { "Part", insidePart }, { "Part", insidePart }, { "Folder", insideFolder } }

    local function validatePeerRows(rows, label, visit)
        assert(type(rows) == "table" and #rows == clientCount, label .. " peer count")
        local seen = {}
        for _, row in rows do
            assert(type(row) == "table" and validPlayerId(row.client) and peers[row.client]
                and not seen[row.client], label .. " actual Player identity")
            seen[row.client] = true
            visit(row)
        end
        for id in peers do assert(seen[id], label .. " missing Player") end
    end

    local function matches(rows, predicate)
        local result = {}
        for _, row in rows do if predicate(row) then table.insert(result, row) end end
        return result
    end

    local function validateSidecars(row, expectedPaths, limit, label)
        assert(type(row) == "table" and type(row.length) == "number"
            and row.referenceCount == #expectedPaths and row.argumentCount == #expectedPaths + 1
            and row.instanceArguments == #expectedPaths and row.nilArguments == 0
            and type(row.references) == "table" and #row.references == #expectedPaths
            and row.length + 8 * #expectedPaths <= limit, label .. " complete packet and native sidecars")
        assert(#expectedPaths <= 16, label .. " bounded sidecar arity")
        for index, expected in expectedPaths do
            local reference = row.references[index]
            assert(type(reference) == "table" and reference.kind == "Instance"
                and reference.className == expected[1] and reference.path == expected[2],
                label .. " native Instance identity " .. tostring(index))
        end
    end

    local function validateNilSidecars(row, count, limit, label)
        assert(type(row) == "table" and type(row.length) == "number"
            and row.referenceCount == count and row.argumentCount == count + 1
            and row.instanceArguments == 0 and row.nilArguments == count
            and type(row.references) == "table" and #row.references == count
            and row.length + 8 * count <= limit, label .. " unavailable native sidecars")
        for _, reference in row.references do
            assert(type(reference) == "table" and reference.kind == "nil", label .. " nil sidecar")
        end
    end

    local function validateRpc(row, tag, kind, methodId, bodyFormat, references, label)
        assert(type(row) == "table" and row.endpoint == 0 and row.rpcTag == tag
            and row.rpcKind == kind and row.methodId == methodId and row.bodyFormat == bodyFormat,
            label .. " RPC wire envelope")
        if references > 0 then
            assert(row.localReferenceCount == references, label .. " local RPC reference count")
            validateSidecars(row, { { "Part", insidePart } }, 8_192, label)
        else
            assert(row.referenceCount == 0 and row.argumentCount == 1 and row.instanceArguments == 0
                and row.nilArguments == 0, label .. " reference-free RPC")
        end
        assert(row.length + 8 * references <= 8_192, label .. " complete RPC byte admission")
    end

    local function validateReferenceReceipt(value, label)
        assert(type(value) == "table" and value.part == insidePart and value.partClass == "Part"
            and value.folder == insideFolder and value.folderClass == "Folder", label .. " callback identity")
    end

    local function validateNumeric(value, label)
        assert(type(value) == "table" and value.unsigned == 16_777_215 and value.signed == -8_388_608
            and value.half == 1.5 and value.compactFloat == -2.25 and value.double == math.pi
            and value.wideGrid == 4_294_967_295, label .. " numeric native roundtrip")
    end

    local function validateBounded(value, label)
        assert(type(value) == "table" and value.text == "abcd" and value.binaryBytes == 3
            and type(value.binaryValues) == "table" and value.binaryValues[1] == 201
            and value.binaryValues[2] == 202 and value.binaryValues[3] == 203
            and value.exactCount == 2 and value.itemCount == 3 and value.memberCount == 3
            and value.scoreCount == 3, label .. " bounded collection roundtrip")
    end

    local function validateRpcFrames(rows, label)
        local expectedNumeric = { 255, 255, 255, 0, 0, 128, 0, 62, 0, 64, 192,
            24, 45, 68, 84, 251, 33, 9, 64, 255, 255, 255, 255 }
        local numeric = matches(rows, function(row)
            return row.format == 1 and (row.eventId == 13 or row.eventId == 14)
        end)
        assert(#numeric == 1, label .. " numeric native frame count")
        assert(numeric[1].length == 26, label .. " numeric compact frame size")
        sameNumbers(numeric[1].numericBytes, expectedNumeric)
        local bounded = matches(rows, function(row)
            return row.format == 1 and (row.eventId == 15 or row.eventId == 16)
        end)
        assert(#bounded == 1 and bounded[1].length == 35, label .. " bounded compact frame size")
        local prefixes = bounded[1].compactPrefixes
        assert(type(prefixes) == "table" and prefixes.text == 1 and prefixes.binary == 1
            and prefixes.items == 1 and prefixes.members == 1 and prefixes.scores == 1,
            label .. " minimum-relative count prefixes")
        sameNumbers(bounded[1].exactArrayBytes, { 10, 11 })
    end

    local function validateQueueRecords(rows, kind, eventId, label, minimum, byteLimit)
        local found = 0
        for _, row in rows do
            if row.format == 5 and row.queueKind == kind then
                assert(row.localReferenceCount == row.referenceCount and row.referenceCount <= 16
                    and row.length + 8 * row.referenceCount <= byteLimit,
                    label .. " complete queued frame accounting")
                for _, record in row.records do
                    if record.eventId == eventId then
                        assert(record.format == 4 and record.localReferenceCount == 3,
                            label .. " queued reference record")
                        found += 1
                    end
                end
            end
        end
        assert(found >= minimum, label .. " actual native queued arrival count")
    end

    local function validateQueueSidecars(rows, kind, eventId, label, minimum, byteLimit)
        local found = 0
        local expectedInside = expectedReferences
        local expectedOutside = { { "Part", outsidePart }, { "Part", outsidePart },
            { "Folder", insideFolder } }
        for _, row in rows do
            if row.format == 5 and row.queueKind == kind then
                for _, record in row.records do
                    if record.eventId == eventId and record.format == 4 then
                        assert(record.localReferenceCount == 3, label .. " queued record sidecar count")
                        local expected = if row.references[1] ~= nil and row.references[1].path == outsidePart
                            then expectedOutside else expectedInside
                        if row.referenceCount == 6 then
                            local doubled = table.create(6)
                            for _, reference in expected do table.insert(doubled, reference) end
                            for _, reference in expected do table.insert(doubled, reference) end
                            validateSidecars(row, doubled, byteLimit, label .. " combined queued frame")
                        else
                            validateSidecars(row, expected, byteLimit, label .. " queued frame")
                        end
                        found += 1
                    end
                end
            end
        end
        assert(found >= minimum, label .. " native queued sidecar arrivals")
    end

    assert(type(main.rpc) == "table" and type(main.rawIngress) == "table"
        and type(main.eventCounters) == "table" and type(main.legacyQueue) == "table"
        and type(main.scopeRejectedRoutes) == "table", "missing RPC/bounded main receipts")
    validatePeerRows(main.server, "RPC/bounded server", function(row)
        local values = row.values
        assert(type(values) == "table" and row.failure == nil and row.echoCalls == 1,
            "RPC/bounded server callback completion")
        for _, name in { "Input", "UnreliableInput", "OrderedInput", "QueueInput", "UnreliableQueueInput" } do
            local receipts = values[name]
            local expectedCount = if name == "UnreliableQueueInput" then 1 else 2
            assert(type(receipts) == "table" and #receipts == expectedCount,
                "native C2S Instance route callback count: " .. name)
            for _, receipt in receipts do validateReferenceReceipt(receipt, name) end
        end
        assert(type(values.StateInput) == "table" and #values.StateInput == 1,
            "native State C2S callback count")
        validateReferenceReceipt(values.StateInput[1], "State C2S")
        validateNumeric(values.numeric, "C2S")
        validateBounded(values.bounded, "C2S")
        assert(type(values.minimum) == "table" and #values.minimum == 2
            and values.minimum[1] == "abc" and values.minimum[2] == "abc",
            "minimum-relative string receive and recovery")
        assert(values.legacy == 41 and type(values.legacyQueued) == "table"
            and #values.legacyQueued == 2 and values.legacyQueued[1] == 42 and values.legacyQueued[2] == 43,
            "legacy event and reference-free queued frame compatibility")
    end)
    validatePeerRows(main.clients, "RPC/bounded client", function(row)
        assert(type(row.failure) == "nil" and type(row.references) == "table"
            and type(row.scalars) == "table" and type(row.clientCalls) == "table"
            and type(row.raw) == "table" and type(row.raw.Reliable) == "table"
            and type(row.raw.Unreliable) == "table", "RPC/bounded client receipts")
        for _, name in { "Output", "UnreliableOutput", "OrderedOutput", "QueueOutput",
            "UnreliableQueueOutput", "StateOutput" } do
            assert(type(row.references[name]) == "table" and #row.references[name] == 1,
                "native S2C Instance route callback count: " .. name)
            validateReferenceReceipt(row.references[name][1], name)
        end
        validateNumeric(row.scalars.NumericOutput, "S2C")
        validateBounded(row.scalars.BoundedOutput, "S2C")
        assert(row.scalars.LegacyOutput == 43 and row.scalars.LegacyQueueOutput == 45,
            "legacy immediate and queued S2C receive")
        validateRpcFrames(row.raw.Reliable, "S2C reliable")
        local function validateImmediate(channelRows, eventId, format, limit, label)
            local frames = matches(channelRows, function(frame)
                return frame.endpoint == eventId and frame.eventId == eventId and frame.format == format
            end)
            assert(#frames == 1, label .. " exact native frame count")
            validateSidecars(frames[1], expectedReferences, limit, label)
            if format == 6 then assert(frames[1].orderedTag == 6, label .. " ordered wire tag") end
        end
        validateImmediate(row.raw.Reliable, 2, 4, 8_192, "S2C reliable immediate")
        validateImmediate(row.raw.Unreliable, 4, 4, 900, "S2C immediate unreliable")
        validateImmediate(row.raw.Unreliable, 6, 6, 900, "S2C ordered unreliable")
        validateQueueRecords(row.raw.Reliable, 1, 8, "reliable queued S2C", 1, 8_192)
        validateQueueSidecars(row.raw.Reliable, 1, 8, "reliable queued S2C", 1, 8_192)
        validateQueueRecords(row.raw.Reliable, 2, 12, "State S2C", 1, 8_192)
        validateQueueSidecars(row.raw.Reliable, 2, 12, "State S2C", 1, 8_192)
        validateQueueRecords(row.raw.Unreliable, 1, 10, "unreliable queued S2C", 1, 900)
        validateQueueSidecars(row.raw.Unreliable, 1, 10, "unreliable queued S2C", 1, 900)
        local mixedLegacy = matches(row.raw.Reliable, function(frame)
            return frame.format == 5 and frame.queueKind == 1 and frame.recordCount == 2
                and #matches(frame.records, function(record) return record.eventId == 8 end) == 1
                and #matches(frame.records, function(record) return record.eventId == 21 end) == 1
        end)
        assert(#mixedLegacy == 1, "S2C reference and legacy records share one reliable queue frame")
        local plainLegacy = matches(row.raw.Reliable, function(frame)
            return frame.format == 2 and frame.queueKind == 1 and frame.recordCount == 1
                and frame.referenceCount == 0
                and #matches(frame.records, function(record)
                    return record.eventId == 21 and record.format == 1 and record.localReferenceCount == 0
                end) == 1
        end)
        assert(#plainLegacy == 1, "S2C legacy reference-free queue keeps format 2")
    end)

    local rpc = main.rpc
    assert(rpc.c2sEchoCalls == 1 and rpc.c2sConcurrentCalls == 3
        and rpc.c2sRequestLimit == "RequestLimit"
        and type(rpc.c2sHandoffsBeforeLimit) == "number"
        and rpc.c2sHandoffsAfterLimit == rpc.c2sHandoffsBeforeLimit
        and rpc.c2sCancelled == "Cancelled" and rpc.c2sBusy == "Busy"
        and type(rpc.c2sResults) == "table" and rpc.c2sResults.cancelled == "Cancelled"
        and rpc.c2sResults.nilValue == true
        and rpc.s2cRequestLimit == "RequestLimit"
        and type(rpc.s2cHandoffsBeforeLimit) == "number"
        and rpc.s2cHandoffsAfterLimit == rpc.s2cHandoffsBeforeLimit
        and rpc.c2sResults.falseValue == true and rpc.s2cCancelled == "Cancelled"
        and rpc.s2cHeldAfterCancel == true and rpc.s2cBusy == "Busy"
        and rpc.s2cSecondFalse == true and rpc.s2cFinalNil == true
        and rpc.noListener == "NoListener" and rpc.legacy == 43,
        "bidirectional RPC concurrency, cancellation, typed nil/false, refusal, and legacy result")
    assert(main.invalidSends == 9 and main.scopeRejected == true,
        "bounded schema local rejection and scope guard proof")
    sameNumbers(main.scopeRejectedRoutes, { "Output", "UnreliableOutput", "OrderedOutput",
        "QueueOutput", "UnreliableQueueOutput", "StateOutput" })
    assert(type(main.legacyQueue.inbound) == "table" and #main.legacyQueue.inbound == 2
        and main.legacyQueue.inbound[1] == 42 and main.legacyQueue.inbound[2] == 43
        and main.legacyQueue.outbound == 45, "legacy no-reference queue receipts")
    local eventCounters = main.eventCounters
    assert(eventCounters.Input.dispatched == 2 * clientCount and eventCounters.Input.invalidPayload >= 3 * clientCount
        and eventCounters.UnreliableInput.dispatched == 2 * clientCount
        and eventCounters.UnreliableInput.invalidPayload >= clientCount
        and eventCounters.OrderedInput.dispatched == 2 * clientCount
        and eventCounters.OrderedInput.invalidPayload >= clientCount
        and eventCounters.QueueInput.dispatched == 2 * clientCount
        and eventCounters.QueueInput.invalidPayload >= 2 * clientCount
        and eventCounters.UnreliableQueueInput.dispatched == clientCount
        and eventCounters.UnreliableQueueInput.invalidPayload >= 2 * clientCount
        and eventCounters.StateInput.dispatched == clientCount
        and eventCounters.MinimumInput.dispatched == 2 * clientCount
        and eventCounters.MinimumInput.invalidPayload >= clientCount,
        "native malformed payload rejection and valid recovery counters")

    local ingressByClient = {}
    for _, row in main.rawIngress do
        assert(peers[row.client] and type(row.channel) == "string", "RPC/bounded raw ingress Player")
        local rows = ingressByClient[row.client]
        if rows == nil then rows = {} ingressByClient[row.client] = rows end
        table.insert(rows, row)
    end
    for id in peers do
        local rows = ingressByClient[id]
        assert(type(rows) == "table", "RPC/bounded raw ingress peer")
        local reliable = matches(rows, function(row) return row.channel == "Reliable" end)
        local unreliable = matches(rows, function(row) return row.channel == "Unreliable" end)
        local inputRows = matches(reliable, function(row) return row.endpoint == 1 and row.format == 4 end)
        assert(#inputRows == 5, "native reliable immediate Instance ingress cardinality")
        local malformedSlot, missingSlot, insideCount, outsideCount = false, false, 0, 0
        for _, frame in inputRows do
            if frame.ordinals ~= nil and frame.ordinals[3] == 4 then
                malformedSlot = true
            elseif frame.nilArguments == 1 then
                assert(frame.referenceCount == 3 and frame.argumentCount == 4
                    and frame.instanceArguments == 2 and frame.nilArguments == 1
                    and #frame.references == 3 and frame.references[1].kind == "nil"
                    and frame.references[2].className == "Part" and frame.references[2].path == insidePart
                    and frame.references[3].className == "Folder" and frame.references[3].path == insideFolder
                    and frame.length + 24 <= 8_192, "C2S partial nil native sidecars")
                missingSlot = true
            elseif frame.references[1].path == insidePart then
                validateSidecars(frame, expectedReferences, 8_192, "C2S reliable Instance")
                insideCount += 1
            elseif frame.references[1].path == outsidePart then
                validateSidecars(frame, { { "Part", outsidePart }, { "Part", outsidePart },
                    { "Folder", insideFolder } }, 8_192, "C2S reliable out-of-scope")
                outsideCount += 1
            end
        end
        assert(malformedSlot and missingSlot and insideCount == 2 and outsideCount == 1,
            "reliable immediate malformed, missing, scoped, and recovered evidence")

        for _, route in { { 3, "Unreliable" }, { 5, "OrderedUnreliable" } } do
            local endpointId, label = route[1], route[2]
            local frames = matches(unreliable, function(row)
                return row.endpoint == endpointId and row.eventId == endpointId
                    and row.format == (if endpointId == 5 then 6 else 4)
            end)
            assert(#frames == 3, label .. " native raw arrival count")
            local validCount, outsideCount = 0, 0
            for _, frame in frames do
                assert(frame.referenceCount == 3 and frame.localReferenceCount == 3,
                    label .. " local and native sidecar arity")
                if endpointId == 5 then assert(frame.orderedTag == 6, "ordered reference wire tag") end
                if frame.references[1].path == insidePart then
                    validateSidecars(frame, expectedReferences, 900, label)
                    validCount += 1
                else
                    validateSidecars(frame, { { "Part", outsidePart }, { "Part", outsidePart },
                        { "Folder", insideFolder } }, 900, label .. " scope rejection")
                    outsideCount += 1
                end
            end
            assert(validCount == 2 and outsideCount == 1, label .. " identity, scope, and recovery")
        end

        validateQueueRecords(reliable, 1, 7, "reliable queued C2S", 3, 8_192)
        validateQueueSidecars(reliable, 1, 7, "reliable queued C2S", 3, 8_192)
        validateQueueRecords(unreliable, 1, 9, "unreliable queued C2S", 1, 900)
        validateQueueSidecars(unreliable, 1, 9, "unreliable queued C2S", 1, 900)
        validateQueueRecords(reliable, 2, 11, "State C2S", 1, 8_192)
        validateQueueSidecars(reliable, 2, 11, "State C2S", 1, 8_192)
        local outOfScopeReliableQueue = matches(reliable, function(row)
            return row.format == 5 and row.queueKind == 1 and row.referenceCount == 3
                and type(row.references) == "table" and row.references[1].path == outsidePart
                and #matches(row.records, function(record) return record.eventId == 7 end) == 1
        end)
        local outOfScopeUnreliableQueue = matches(unreliable, function(row)
            return row.format == 5 and row.queueKind == 1 and row.referenceCount == 3
                and type(row.references) == "table" and row.references[1].path == outsidePart
                and #matches(row.records, function(record) return record.eventId == 9 end) == 1
        end)
        assert(#outOfScopeReliableQueue == 1 and #outOfScopeUnreliableQueue == 1,
            "reliable and unreliable queued Instance scope rejection receipts")
        local malformedQueue = matches(reliable, function(row)
            return row.format == 5 and row.queueKind == 1 and row.recordCount == 2
                and row.referenceCount == 6
        end)
        assert(#malformedQueue >= 1 and malformedQueue[1].length + 8 * 6 <= 8_192,
            "late malformed reliable queued frame is whole-frame bounded")
        local malformedUnreliableQueue = matches(unreliable, function(row)
            return row.format == 5 and row.queueKind == 1 and row.recordCount == 2
                and row.referenceCount == 6 and row.localReferenceCount == 6
        end)
        assert(#malformedUnreliableQueue >= 1
            and malformedUnreliableQueue[1].length + 8 * 6 <= 900,
            "late malformed unreliable queued frame is whole-frame bounded")
        local legacyQueues = matches(reliable, function(row)
            return (row.format == 2 or row.format == 5) and type(row.records) == "table"
                and #matches(row.records, function(record) return record.eventId == 20 end) > 0
        end)
        assert(#legacyQueues >= 2, "legacy records survive reference and no-reference queue frames")
        local mixedLegacy = matches(reliable, function(row)
            return row.format == 5 and row.queueKind == 1 and row.recordCount == 2
                and row.referenceCount == 3
                and #matches(row.records, function(record) return record.eventId == 7 end) == 1
                and #matches(row.records, function(record) return record.eventId == 20 end) == 1
        end)
        local plainLegacy = matches(reliable, function(row)
            return row.format == 2 and row.queueKind == 1 and row.recordCount == 1
                and row.referenceCount == 0
                and #matches(row.records, function(record)
                    return record.eventId == 20 and record.format == 1 and record.localReferenceCount == 0
                end) == 1
        end)
        assert(#mixedLegacy == 1 and #plainLegacy == 1,
            "C2S reference and legacy queue compatibility frames")
        local minimumMalformed = matches(reliable, function(row)
            return row.endpoint == 17 and row.eventId == 17 and row.format == 1 and row.minimumOffset == 3
                and row.length == 4
        end)
        assert(#minimumMalformed == 1, "minimum-relative hostile prefix rejects before body traversal")

        local rpcRequests = matches(reliable, function(row)
            return row.rpcTag == 7 and row.rpcKind == 1 and row.methodId == 100
        end)
        assert(#rpcRequests == 1, "C2S Instance RPC request count")
        validateRpc(rpcRequests[1], 7, 1, 100, 4, 1, "C2S Instance RPC request")
        local legacyRequests = matches(reliable, function(row)
            return row.rpcTag == 1 and row.rpcKind == 1 and row.methodId == 104
        end)
        assert(#legacyRequests == 1, "legacy RPC request count")
        validateRpc(legacyRequests[1], 1, 1, 104, 1, 0, "legacy RPC request")
        local concurrentRequests = matches(reliable, function(row)
            return row.rpcTag == 7 and row.rpcKind == 1 and row.methodId == 101
        end)
        assert(#concurrentRequests == (if id == target then 4 else 0),
            "bounded C2S RPC native request count")
        for _, frame in concurrentRequests do
            validateRpc(frame, 7, 1, 101, 1, 0, "bounded C2S RPC request")
        end
        validateRpcFrames(reliable, "C2S reliable ingress")
    end

    validatePeerRows(main.clients, "RPC/bounded raw client", function(row)
        local reliable, unreliable = row.raw.Reliable, row.raw.Unreliable
        local id = row.client
        local expectedCalls = if id == target then 3 else 0
        assert(#row.clientCalls == expectedCalls
            and row.clientCallMaximumActive == (if id == target then 2 else 0),
            "S2C held handler concurrency receipt")
        if id == target then
            local nilCalls, falseCalls, heldCalls = 0, 0, 0
            for _, call in row.clientCalls do
                assert(call.part == insidePart and call.returnMissing == false
                    and (call.concurrentActive == 1 or call.concurrentActive == 2),
                    "S2C RPC native request handler receipt")
                if call.returnNil then nilCalls += 1 else falseCalls += 1 end
                if call.hold then heldCalls += 1 end
            end
            assert(nilCalls == 2 and falseCalls == 1 and heldCalls == 2,
                "S2C RPC native nil/false and held request calls")
        end
        local echoReplies = matches(reliable, function(frame)
            return frame.rpcTag == 7 and frame.rpcKind == 2 and frame.methodId == 100
        end)
        assert(#echoReplies == 1, "C2S Instance RPC response count")
        validateRpc(echoReplies[1], 7, 2, 100, 4, 1, "C2S Instance RPC response")
        local legacyReplies = matches(reliable, function(frame)
            return frame.rpcTag == 1 and frame.rpcKind == 2 and frame.methodId == 104
        end)
        assert(#legacyReplies == 1, "legacy RPC response count")
        validateRpc(legacyReplies[1], 1, 2, 104, 1, 0, "legacy RPC response")
        local concurrentReplies = matches(reliable, function(frame)
            return frame.rpcTag == 7 and frame.rpcKind == 2 and frame.methodId == 101
        end)
        local concurrentRefusals = matches(reliable, function(frame)
            return frame.rpcTag == 7 and frame.rpcKind == 6 and frame.methodId == 101
        end)
        assert(#concurrentReplies == (if id == target then 3 else 0)
            and #concurrentRefusals == (if id == target then 1 else 0),
            "C2S RPC typed responses and prompt Busy refusal")
        for _, frame in concurrentReplies do validateRpc(frame, 7, 2, 101, 1, 0, "C2S scalar RPC response") end
        for _, frame in concurrentRefusals do validateRpc(frame, 7, 6, 101, nil, 0, "C2S RPC Busy response") end
        local clientCalls = matches(reliable, function(frame)
            return frame.rpcTag == 7 and frame.rpcKind == 1 and frame.methodId == 102
        end)
        assert(#clientCalls == (if id == target then 4 else 0),
            "S2C RPC request and prompt Busy request arrivals")
        for _, frame in clientCalls do validateRpc(frame, 7, 1, 102, 4, 1, "S2C Instance RPC request") end
        local noListener = matches(reliable, function(frame)
            return frame.rpcTag == 7 and frame.rpcKind == 1 and frame.methodId == 103
        end)
        assert(#noListener == (if id == target then 1 else 0), "S2C NoListener request arrival")
        for _, frame in noListener do validateRpc(frame, 7, 1, 103, 1, 0, "S2C NoListener request") end
        validateRpcFrames(reliable, "S2C reliable egress")
    end)

    assert(validPlayerId(target) and peers[target], "RPC/bounded target identity")
    local incomingBusy = matches(main.rawIngress, function(row)
        return row.client == target and row.rpcTag == 7 and row.rpcKind == 6 and row.methodId == 102
    end)
    local incomingNoListener = matches(main.rawIngress, function(row)
        return row.client == target and row.rpcTag == 7 and row.rpcKind == 7 and row.methodId == 103
    end)
    assert(#incomingBusy == 1 and #incomingNoListener == 1,
        "S2C RPC Busy and NoListener replies use explicit v2 refusal kinds")
    validateRpc(incomingBusy[1], 7, 6, 102, nil, 0, "S2C RPC Busy response")
    validateRpc(incomingNoListener[1], 7, 7, 103, nil, 0, "S2C RPC NoListener response")

    assert(missing.c2sRequest == "RequestTimeout" and missing.s2cRequest == "RequestTimeout"
        and missing.s2cResponse == "InvalidResponse" and missing.serverHandlerCalls == 0,
        "missing Instance RPC request timeout and malformed response settlement")
    assert(type(missing.output) == "table" and missing.output.invalidPayload == 1
        and missing.output.dispatched == 0 and missing.output.callbacks == 0
        and type(missing.recovered) == "table" and missing.recovered.part == insidePart
        and missing.recovered.folder == insideFolder,
        "missing native S2C references reject before callback and valid output recovers")
    local missingEcho = matches(missing.rawIngress, function(row)
        return row.endpoint == 0 and row.rpcTag == 7 and row.rpcKind == 1 and row.methodId == 100
    end)
    assert(#missingEcho == 1, "missing C2S Instance RPC raw request count")
    validateNilSidecars(missingEcho[1], 1, 8_192, "missing C2S RPC reference")
    local missingResponse = matches(missing.rawIngress, function(row)
        return row.endpoint == 0 and row.rpcTag == 7 and row.rpcKind == 2 and row.methodId == 102
    end)
    assert(#missingResponse == 1, "missing S2C RPC response raw count")
    assert(missingResponse[1].localReferenceCount == 1, "missing S2C RPC response local reference count")
    validateNilSidecars(missingResponse[1], 1, 8_192, "missing S2C RPC response reference")
    assert(type(missing.output.raw) == "table" and type(missing.output.raw.Reliable) == "table",
        "missing native RPC/event raw output receipt")
    local missingOutput = matches(missing.output.raw.Reliable, function(row)
        return row.endpoint == 2 and row.eventId == 2 and row.format == 4
    end)
    assert(#missingOutput == 1, "missing S2C native Instance event raw count")
    validateNilSidecars(missingOutput[1], 3, 8_192, "missing S2C event references")
    local missingRequest = matches(missing.output.raw.Reliable, function(row)
        return row.endpoint == 0 and row.rpcTag == 7 and row.rpcKind == 1 and row.methodId == 102
            and row.nilArguments == 1
    end)
    assert(#missingRequest == 1 and missingRequest[1].referenceCount == 1
        and missingRequest[1].localReferenceCount == 1,
        "missing S2C RPC request reference reaches native transport as nil")
end

local function validateBroadcastBatching(proof, clientCount, readinessClients)
    assert(type(proof) == "table" and type(proof.refusal) == "table"
        and type(proof.counters) == "table" and type(proof.cleanup) == "table"
        and type(proof.byteBreakdown) == "table" and type(proof.malformed) == "table"
        and type(proof.recovery) == "table",
        "missing shared broadcast batching evidence")
    local refusal, retry, reuse = proof.refusal, proof.retry, proof.reuse
    assert(refusal.code == "OutboundRateLimited" and refusal.selected == 0 and refusal.remaining == 4
        and refusal.pending == 4 and type(refusal.pulseAdmissions) == "number" and refusal.pulseAdmissions > 0,
        "shared broadcast outbound refusal retains the complete bounded window")
    local peerIds = {}
    for _, row in readinessClients do peerIds[row.userId] = true end

    local function validatePeers(rows, label, validate)
        assert(type(rows) == "table" and #rows == clientCount, label .. " peer count")
        local seen = {}
        for _, row in rows do
            assert(type(row) == "table" and validPlayerId(row.client) and peerIds[row.client]
                and not seen[row.client], label .. " actual peer identity")
            seen[row.client] = true
            validate(row)
        end
        for id in peerIds do assert(seen[id], label .. " missing peer") end
    end

    local function validateRawBytes(frame, expectedFormat, expectedKind, expectedCount, expectedReferences, label)
        assert(type(frame) == "table" and type(frame.bytes) == "table"
            and #frame.bytes == frame.length and frame.length <= (if expectedFormat == 5 then 8_192 else 900),
            label .. " actual byte count and complete limit")
        for _, byte in frame.bytes do
            assert(type(byte) == "number" and byte % 1 == 0 and byte >= 0 and byte <= 255,
                label .. " raw byte range")
        end
        assert(frame.bytes[1] == expectedFormat and frame.bytes[2] == expectedKind
            and frame.bytes[3] == expectedCount,
            label .. " raw frame header bytes")
        local headerBytes = if expectedFormat == 5 then 4 else 3
        if expectedFormat == 5 then
            assert(frame.bytes[4] == expectedReferences, label .. " raw frame reference header byte")
        end
        local offset = headerBytes + 1
        for index, record in frame.records do
            local bodyLength = frame.bytes[offset] + frame.bytes[offset + 1] * 256
            local bodyOffset = offset + 2
            local eventId = frame.bytes[bodyOffset + 1] + frame.bytes[bodyOffset + 2] * 256
            assert(bodyLength == record.bodyLength and frame.bytes[bodyOffset] == record.codec
                and eventId == record.eventId,
                label .. " raw row prefix, codec, and endpoint bytes")
            if record.codec == 4 then
                local localReferences = frame.bytes[bodyOffset + 3]
                assert(localReferences == record.referenceCount and type(record.ordinals) == "table",
                    label .. " raw reference count")
                local ordinalOffset = bodyOffset + 5
                if record.eventId == 4 then
                    assert(bodyLength >= 7 and localReferences == 2, label .. " State reference string prefix")
                    local messageLength = frame.bytes[bodyOffset + 5] + frame.bytes[bodyOffset + 6] * 256
                    assert(messageLength <= 93 and bodyLength == 7 + messageLength + localReferences,
                        label .. " State string and reference bounds")
                    ordinalOffset = bodyOffset + 7 + messageLength
                else
                    assert(bodyLength >= 5 + localReferences, label .. " FIFO boolean and reference bounds")
                end
                for ordinal = 1, localReferences do
                    assert(frame.bytes[ordinalOffset + ordinal - 1] == record.ordinals[ordinal],
                        label .. " raw reference ordinal byte")
                end
            else
                assert(record.codec == 1 and record.referenceCount == 0 and bodyLength == 5,
                    label .. " raw primitive record bounds")
            end
            offset += 2 + bodyLength
        end
        assert(offset == #frame.bytes + 1, label .. " raw frame has no trailing bytes")
    end

    local function validateExactBytes(frame, expected, label)
        assert(type(frame.bytes) == "table" and frame.length == #expected and #frame.bytes == #expected,
            label .. " exact raw byte length")
        for index, byte in expected do
            assert(frame.bytes[index] == byte, label .. " exact raw byte " .. tostring(index))
        end
    end

    validatePeers(refusal.peers, "refused shared broadcast", function(row)
        assert(type(row.reliable) == "table" and #row.reliable == 0
            and type(row.unreliable) == "table" and #row.unreliable == 0
            and type(row.raw) == "table" and type(row.raw.Reliable) == "table"
            and #row.raw.Reliable == 0 and type(row.raw.Unreliable) == "table"
            and #row.raw.Unreliable == 0,
            "refused shared window delivers no partial packet or callback")
    end)

    assert(type(retry) == "table" and retry.selected == 4 and retry.reliableHandoffs == 1
        and retry.unreliableHandoffs == 1 and retry.logicalHandoffs == 4,
        "shared flush reports one native handoff per channel and four logical records")
    assert(type(reuse) == "table" and reuse.selected == 1 and reuse.reliableHandoffs == 1
        and reuse.unreliableHandoffs == 0 and reuse.logicalHandoffs == 1,
        "shared batcher opens the next FIFO window")
    assert(proof.counters.broadcastHandoffs == 3 and proof.counters.sendHandoffs == 0
        and proof.counters.outboundBytesCharged == clientCount * 100
        and proof.counters.perRecipientBytes == 100,
        "shared native-call diagnostics and exact 100-byte debit per current recipient")
    assert(proof.cleanup.state == "Terminal" and proof.cleanup.pending == 0
        and proof.cleanup.noLateHandoff == true,
        "shared batcher cancellation releases its window and invalidates the timer")

    local partPath = "ReplicatedStorage.RelayProofInstanceScope.InsidePart"
    local folderPath = "ReplicatedStorage.RelayProofInstanceScope.InsideFolder"
    validatePeers(proof.peers, "shared broadcast delivery", function(row)
        assert(row.failure == nil and type(row.reliable) == "table" and #row.reliable == 3,
            "shared reliable callbacks arrive for every current peer")
        local values = { false, true, false }
        for index, enabled in values do
            local value = row.reliable[index]
            assert(type(value) == "table" and value.enabled == enabled
                and value.part == partPath and value.folder == folderPath,
                "shared reliable FIFO values preserve false and Instance identity")
        end

        local raw = row.raw
        assert(type(raw) == "table" and type(raw.Reliable) == "table" and #raw.Reliable == 2
            and type(raw.Unreliable) == "table" and #raw.Unreliable <= 1,
            "shared native packet receipt counts")
        for index, expectedCount in { 2, 1 } do
            local frame = raw.Reliable[index]
            assert(type(frame) == "table" and frame.endpoint == 0 and frame.format == 5 and frame.kind == 1
                and frame.count == expectedCount and frame.referenceCount == expectedCount * 2
                and frame.length == (if index == 1 then 22 else 13)
                and frame.length + frame.referenceCount * 8 <= 8_192
                and type(frame.records) == "table" and #frame.records == expectedCount
                and type(frame.references) == "table" and #frame.references == expectedCount * 2,
                "actual shared reliable format, count, sidecars, and complete byte limit")
            validateRawBytes(frame, 5, 1, expectedCount, expectedCount * 2,
                "actual shared reliable frame " .. tostring(index))
            for _, record in frame.records do
                assert(record.codec == 4 and record.eventId == 1 and record.referenceCount == 2
                    and record.bodyLength == 7
                    and type(record.ordinals) == "table" and record.ordinals[1] == 1
                    and record.ordinals[2] == 2,
                    "actual shared reliable local reference ordinals")
            end
            for sidecarIndex, sidecar in frame.references do
                local expectedClass = if sidecarIndex % 2 == 1 then "Part" else "Folder"
                local expectedPath = if sidecarIndex % 2 == 1 then partPath else folderPath
                assert(type(sidecar) == "table" and sidecar.className == expectedClass
                    and sidecar.path == expectedPath,
                    "actual shared reliable native sidecar identity")
            end
        end

        if #raw.Unreliable == 0 then
            assert(type(row.unreliable) == "table" and #row.unreliable == 0,
                "unreliable callbacks require an observed native packet")
        else
            local frame = raw.Unreliable[1]
            assert(frame.endpoint == 0 and frame.format == 2 and frame.kind == 1 and frame.count == 2
                and frame.referenceCount == 0 and frame.length == 17
                and type(frame.records) == "table" and #frame.records == 2
                and type(frame.references) == "table" and #frame.references == 0,
                "actual shared unreliable frame stays within its complete byte limit")
            validateRawBytes(frame, 2, 1, 2, 0, "actual shared unreliable frame")
            for _, record in frame.records do
                assert(record.codec == 1 and record.eventId == 2 and record.referenceCount == 0
                    and record.bodyLength == 5,
                    "actual shared unreliable record identity")
            end
            assert(type(row.unreliable) == "table" and #row.unreliable == 2
                and row.unreliable[1].sequence == 7 and row.unreliable[1].enabled == false
                and row.unreliable[2].sequence == 255 and row.unreliable[2].enabled == true,
                "observed unreliable values are bounded and remain ordered")
        end
    end)

    local firstPeer = proof.peers[1]
    local firstReliable, reusedReliable = firstPeer.raw.Reliable[1], firstPeer.raw.Reliable[2]
    local breakdown = proof.byteBreakdown
    assert(type(breakdown.retry) == "table" and type(breakdown.retry.reliable) == "table"
        and type(breakdown.retry.unreliable) == "table" and type(breakdown.reuse) == "table",
        "shared outbound byte breakdown")
    local reliable = breakdown.retry.reliable
    local unreliable = breakdown.retry.unreliable
    local reuseBytes = breakdown.reuse
    assert(reliable.frameBytes == firstReliable.length and reliable.headerBytes == 4
        and reliable.recordCount == 2 and reliable.recordBodyBytes[1] == 7 and reliable.recordBodyBytes[2] == 7
        and reliable.lengthPrefixBytes == 4 and reliable.referenceCount == 4 and reliable.referenceUnitBytes == 8
        and reliable.referenceBytes == 32 and reliable.charge == 54,
        "retry reliable frame/header/row/reference debit")
    assert(unreliable.frameBytes == 17 and unreliable.headerBytes == 3 and unreliable.recordCount == 2
        and unreliable.recordBodyBytes[1] == 5 and unreliable.recordBodyBytes[2] == 5
        and unreliable.lengthPrefixBytes == 4 and unreliable.referenceCount == 0
        and unreliable.referenceBytes == 0 and unreliable.charge == 17
        and breakdown.retry.totalCharge == 71,
        "retry unreliable frame/header/row debit")
    assert(reuseBytes.frameBytes == reusedReliable.length and reuseBytes.headerBytes == 4
        and reuseBytes.recordCount == 1 and reuseBytes.recordBodyBytes[1] == 7
        and reuseBytes.lengthPrefixBytes == 2 and reuseBytes.referenceCount == 2
        and reuseBytes.referenceUnitBytes == 8 and reuseBytes.referenceBytes == 16
        and reuseBytes.charge == 29 and breakdown.perRecipientBytes == 100,
        "reusable reliable frame/header/row/reference debit")

    local malformed = proof.malformed
    local malformedBytes = malformed.bytes
    local normalBytes = firstReliable.bytes
    assert(malformed.injected == true and malformed.excludedFromLibraryDiagnosticsAndBudget == true
        and malformed.endpoint == 0 and malformed.format == 5 and malformed.kind == 1
        and malformed.count == 2 and malformed.referenceCount == 4 and malformed.length == 22
        and malformed.finalLengthOffset == 13 and malformed.originalFinalLength == 7
        and malformed.malformedFinalLength == 0 and #malformedBytes == #normalBytes
        and type(malformed.libraryCountersBefore) == "table"
        and type(malformed.libraryCountersAfter) == "table"
        and malformed.libraryCountersAfter.broadcastHandoffs == malformed.libraryCountersBefore.broadcastHandoffs
        and malformed.libraryCountersAfter.sendHandoffs == malformed.libraryCountersBefore.sendHandoffs
        and malformed.libraryCountersAfter.outboundBytesCharged == malformed.libraryCountersBefore.outboundBytesCharged,
        "bounded malformed-last-row test injection is outside Relay handoff accounting")
    for index, byte in normalBytes do
        local expectedByte = if index == malformed.finalLengthOffset + 1
            or index == malformed.finalLengthOffset + 2 then 0 else byte
        assert(malformedBytes[index] == expectedByte,
            "malformed packet changes only the final row length prefix")
    end
    assert(malformedBytes[1] == 5 and malformedBytes[2] == 1 and malformedBytes[3] == 2
        and malformedBytes[4] == 4 and malformedBytes[5] == 7 and malformedBytes[6] == 0
        and malformedBytes[14] == 0 and malformedBytes[15] == 0,
        "malformed packet retains a valid first row and rejects the final zero-length row")
    validatePeers(malformed.peers, "malformed shared broadcast", function(row)
        assert(row.invalidPayloadAfter > row.invalidPayloadBefore
            and row.reliableCallbacksBefore == 3 and row.reliableCallbacksAfter == 3
            and type(row.frames) == "table" and #row.frames == 1,
            "causal invalidPayload barrier proves whole-frame rejection without partial callback")
        local frame = row.frames[1]
        assert(frame.endpoint == 0 and frame.format == 5 and frame.kind == 1 and frame.count == 2
            and frame.referenceCount == 4 and frame.length == malformed.length
            and type(frame.bytes) == "table" and #frame.bytes == #malformedBytes
            and type(frame.references) == "table" and #frame.references == 4,
            "separate actual malformed raw receipt")
        for index, byte in malformedBytes do
            assert(frame.bytes[index] == byte, "peer raw receipt matches injected malformed packet")
        end
        for index, sidecar in frame.references do
            local expectedClass = if index % 2 == 1 then "Part" else "Folder"
            local expectedPath = if index % 2 == 1 then partPath else folderPath
            assert(sidecar.className == expectedClass and sidecar.path == expectedPath,
                "malformed frame retains exact Instance sidecar identity")
        end
    end)

    local recovery = proof.recovery
    assert(type(recovery.report) == "table" and recovery.report.selected == 1
        and recovery.report.reliableHandoffs == 1 and recovery.report.unreliableHandoffs == 0
        and recovery.report.logicalHandoffs == 1
        and type(recovery.counters) == "table" and recovery.counters.broadcastHandoffs == 1
        and recovery.counters.sendHandoffs == 0 and recovery.counters.outboundBytesCharged == clientCount * 29
        and recovery.counters.perRecipientBytes == 29,
        "valid recovery independently hands off and charges 29 bytes per recipient")
    validatePeers(recovery.peers, "valid recovery after malformed shared broadcast", function(row)
        assert(row.failure == nil and type(row.reliable) == "table" and #row.reliable == 4,
            "valid shared recovery callback reaches each peer")
        local values = { false, true, false, true }
        for index, enabled in values do
            local value = row.reliable[index]
            assert(value.enabled == enabled and value.part == partPath and value.folder == folderPath,
                "valid shared recovery retains reliable order and references")
        end
        assert(type(row.raw) == "table" and #row.raw.Reliable == 3,
            "normal raw receipts remain separate from malformed packet receipt")
        local frame = row.raw.Reliable[3]
        assert(frame.endpoint == 0 and frame.format == 5 and frame.kind == 1 and frame.count == 1
            and frame.referenceCount == 2 and frame.length == 13 and #frame.references == 2,
            "valid recovery native frame metadata")
        validateRawBytes(frame, 5, 1, 1, 2, "valid recovery reliable frame")
        assert(frame.records[1].codec == 4 and frame.records[1].eventId == 1
            and frame.records[1].referenceCount == 2 and frame.records[1].ordinals[1] == 1
            and frame.records[1].ordinals[2] == 2,
            "valid recovery reference ordinals")
    end)

    local state = proof.state
    assert(type(state) == "table" and type(state.refusal) == "table"
        and type(state.noAutoDeferral) == "table" and type(state.counters) == "table"
        and type(state.byteBreakdown) == "table" and type(state.malformed) == "table"
        and type(state.recovery) == "table" and type(state.cleanup) == "table"
        and type(state.pulse) == "table" and type(state.pulse.countersBefore) == "table"
        and type(state.pulse.countersAfter) == "table" and type(state.refusal.countersBefore) == "table"
        and type(state.refusal.countersAfter) == "table"
        and type(state.pulseAdmissions) == "number" and state.pulseAdmissions == 1,
        "missing shared State broadcast proof")
    local stateRefusal, noAuto = state.refusal, state.noAutoDeferral
    assert(state.pulse.charge == 10
        and state.pulse.countersAfter.broadcastHandoffs == state.pulse.countersBefore.broadcastHandoffs
        and state.pulse.countersAfter.sendHandoffs == state.pulse.countersBefore.sendHandoffs + 1
        and state.pulse.countersAfter.outboundBytesCharged == state.pulse.countersBefore.outboundBytesCharged + 10
        and stateRefusal.countersBefore.broadcastHandoffs == state.pulse.countersAfter.broadcastHandoffs
        and stateRefusal.countersBefore.sendHandoffs == state.pulse.countersAfter.sendHandoffs
        and stateRefusal.countersBefore.outboundBytesCharged == state.pulse.countersAfter.outboundBytesCharged,
        "short targeted pulse alone consumes ten budget units before State admission")
    assert(stateRefusal.code == "OutboundRateLimited" and stateRefusal.selected == 0
        and stateRefusal.remaining == 3 and stateRefusal.pending == 3
        and stateRefusal.fullRefillWaitSeconds == 2.1
        and stateRefusal.availableAfterPulse == 246 and stateRefusal.pulseCharge == 10
        and stateRefusal.reliableCharge == 244 and stateRefusal.unreliableCharge == 10
        and stateRefusal.combinedCharge == 254
        and stateRefusal.reliableCharge <= stateRefusal.availableAfterPulse
        and stateRefusal.unreliableCharge <= stateRefusal.availableAfterPulse
        and stateRefusal.combinedCharge > stateRefusal.availableAfterPulse
        and type(stateRefusal.pulseToFlushSeconds) == "number" and stateRefusal.pulseToFlushSeconds < 0.05
        and type(stateRefusal.pulseToRefusalSeconds) == "number" and stateRefusal.pulseToRefusalSeconds < 0.05
        and type(stateRefusal.countersBefore) == "table" and type(stateRefusal.countersAfter) == "table"
        and stateRefusal.countersAfter.broadcastHandoffs == stateRefusal.countersBefore.broadcastHandoffs
        and stateRefusal.countersAfter.sendHandoffs == stateRefusal.countersBefore.sendHandoffs
        and stateRefusal.countersAfter.outboundBytesCharged == stateRefusal.countersBefore.outboundBytesCharged,
        "shared State refusal retains all keys and performs no partial debit or handoff")
    assert(noAuto.pending == 3 and type(noAuto.counters) == "table"
        and type(noAuto.elapsedBeforeExpiry) == "number"
        and noAuto.elapsedBeforeExpiry > 0 and noAuto.elapsedBeforeExpiry < 0.9
        and noAuto.counters.broadcastHandoffs == stateRefusal.countersAfter.broadcastHandoffs
        and noAuto.counters.sendHandoffs == stateRefusal.countersAfter.sendHandoffs
        and noAuto.counters.outboundBytesCharged == stateRefusal.countersAfter.outboundBytesCharged,
        "refused shared State waits for explicit retry without automatic deferral")
    assert(type(state.retry) == "table" and state.retry.selected == 3 and state.retry.remaining == 0
        and state.retry.reliableHandoffs == 1 and state.retry.unreliableHandoffs == 1
        and state.retry.logicalHandoffs == 3
        and state.counters.broadcastHandoffs == 2 and state.counters.sendHandoffs == 0
        and state.counters.outboundBytesCharged == clientCount * 254
        and state.counters.perRecipientBytes == 254,
        "shared State retry uses broadcast calls and charges each current recipient exactly")

    local stateReliableMessage = string.rep("1", 93)
    local stateReliableMessage2 = string.rep("2", 93)
    local expectedStateBytes = { 5, 2, 2, 4 }
    local function appendStateRow(marker, message)
        local bodyLength = 9 + #message
        table.insert(expectedStateBytes, bodyLength % 256)
        table.insert(expectedStateBytes, math.floor(bodyLength / 256))
        for _, byte in { 4, 4, 0, 2, marker, #message % 256, math.floor(#message / 256) } do
            table.insert(expectedStateBytes, byte)
        end
        for index = 1, #message do
            table.insert(expectedStateBytes, string.byte(message, index))
        end
        table.insert(expectedStateBytes, 1)
        table.insert(expectedStateBytes, 2)
    end
    appendStateRow(11, stateReliableMessage)
    appendStateRow(12, stateReliableMessage2)
    assert(#expectedStateBytes == 212, "shared reliable State expected wire length")
    validatePeers(state.peers, "shared State broadcast", function(row)
        assert(row.failure == nil and type(row.reliable) == "table" and #row.reliable == 2,
            "coalesced shared State reaches each current peer")
        assert(row.reliable[1].marker == 11 and row.reliable[1].message == stateReliableMessage
            and row.reliable[2].marker == 12 and row.reliable[2].message == stateReliableMessage2
            and row.reliable[1].part == partPath and row.reliable[2].part == partPath
            and row.reliable[1].folder == folderPath and row.reliable[2].folder == folderPath,
            "two State keys deliver only their latest values and exact Instances")
        assert(type(row.raw) == "table" and type(row.raw.Reliable) == "table"
            and #row.raw.Reliable == 1 and type(row.raw.Unreliable) == "table"
            and #row.raw.Unreliable <= 1,
            "shared State raw packet receipts")
        local frame = row.raw.Reliable[1]
        assert(frame.endpoint == 0 and frame.format == 5 and frame.kind == 2 and frame.count == 2
            and frame.referenceCount == 4 and frame.length == 212 and #frame.references == 4
            and #frame.records == 2,
            "actual shared reliable State format-5 kind-2 frame and sidecars")
        validateRawBytes(frame, 5, 2, 2, 4, "actual shared reliable State frame")
        assert(frame.length + frame.referenceCount * 8 == 244
            and frame.length + frame.referenceCount * 8 <= 8_192,
            "shared reliable State exact complete-frame budget")
        validateExactBytes(frame, expectedStateBytes, "shared reliable State")
        for index, record in frame.records do
            assert(record.codec == 4 and record.eventId == 4 and record.bodyLength == 102
                and record.referenceCount == 2 and record.ordinals[1] == 1 and record.ordinals[2] == 2,
                "shared State references use local ordered ordinals")
            local partReference, folderReference = frame.references[(index - 1) * 2 + 1], frame.references[(index - 1) * 2 + 2]
            assert(partReference.className == "Part" and partReference.path == partPath
                and folderReference.className == "Folder" and folderReference.path == folderPath,
                "shared State sidecars retain exact Instance identity")
        end
        if #row.raw.Unreliable == 0 then
            assert(type(row.unreliable) == "table" and #row.unreliable == 0,
                "unreliable State callback requires an observed packet")
        else
            local unreliable = row.raw.Unreliable[1]
            assert(unreliable.endpoint == 0 and unreliable.format == 2 and unreliable.kind == 2
                and unreliable.count == 1 and unreliable.referenceCount == 0 and unreliable.length == 10
                and type(unreliable.references) == "table" and #unreliable.references == 0
                and #unreliable.records == 1 and #row.unreliable == 1
                and row.unreliable[1].sequence == 7 and row.unreliable[1].enabled == false,
                "observed unreliable State packet passes its callback barrier")
            validateRawBytes(unreliable, 2, 2, 1, 0, "actual shared unreliable State frame")
            assert(unreliable.length + unreliable.referenceCount * 8 <= 900,
                "shared unreliable State exact complete-frame budget")
            validateExactBytes(unreliable, { 2, 2, 1, 5, 0, 1, 5, 0, 7, 0 },
                "shared unreliable State")
            assert(unreliable.records[1].codec == 1 and unreliable.records[1].eventId == 5
                and unreliable.records[1].bodyLength == 5,
                "actual shared unreliable State kind-2 row")
        end
    end)

    local stateBytes = state.byteBreakdown
    assert(type(stateBytes) == "table" and stateBytes.capacity == 256 and type(stateBytes.refusal) == "table"
        and stateBytes.refusal.fullRefillWaitSeconds == 2.1
        and stateBytes.refusal.availableAfterPulse == 246 and stateBytes.refusal.pulseCharge == 10
        and stateBytes.refusal.reliableCharge == 244 and stateBytes.refusal.unreliableCharge == 10
        and stateBytes.refusal.combinedCharge == 254
        and stateBytes.refusal.pulseToFlushSeconds == stateRefusal.pulseToFlushSeconds
        and stateBytes.refusal.pulseToRefusalSeconds == stateRefusal.pulseToRefusalSeconds
        and stateBytes.refusal.combinedCharge < stateBytes.capacity
        and type(stateBytes.reliable) == "table" and type(stateBytes.unreliable) == "table"
        and stateBytes.reliable.frameBytes == 212 and stateBytes.reliable.referenceCount == 4
        and stateBytes.reliable.referenceBytes == 32 and stateBytes.reliable.charge == 244
        and stateBytes.unreliable.frameBytes == 10 and stateBytes.unreliable.referenceCount == 0
        and stateBytes.unreliable.referenceBytes == 0 and stateBytes.unreliable.charge == 10
        and stateBytes.perRecipientBytes == 254 and stateBytes.perRecipientBytes < stateBytes.capacity,
        "shared State budget is exact frame length plus eight units per Instance sidecar")

    local malformedState = state.malformed
    local stateNormalBytes = state.peers[1].raw.Reliable[1].bytes
    assert(malformedState.injected == true and malformedState.excludedFromLibraryDiagnosticsAndBudget == true
        and malformedState.endpoint == 0 and malformedState.format == 5 and malformedState.kind == 2
        and malformedState.count == 2 and malformedState.referenceCount == 4 and malformedState.length == 212
        and malformedState.finalLengthOffset == 108 and malformedState.originalFinalLength == 102
        and malformedState.malformedFinalLength == 0 and #malformedState.bytes == #stateNormalBytes
        and malformedState.libraryCountersAfter.broadcastHandoffs == malformedState.libraryCountersBefore.broadcastHandoffs
        and malformedState.libraryCountersAfter.sendHandoffs == malformedState.libraryCountersBefore.sendHandoffs
        and malformedState.libraryCountersAfter.outboundBytesCharged == malformedState.libraryCountersBefore.outboundBytesCharged,
        "malformed State injection bypasses Relay accounting and targets the final row")
    for index, byte in stateNormalBytes do
        local expectedByte = if index == malformedState.finalLengthOffset + 1
            or index == malformedState.finalLengthOffset + 2 then 0 else byte
        assert(malformedState.bytes[index] == expectedByte,
            "malformed State packet changes only its final row length prefix")
    end
    assert(malformedState.bytes[1] == 5 and malformedState.bytes[2] == 2
        and malformedState.bytes[3] == 2 and malformedState.bytes[4] == 4
        and malformedState.bytes[5] == 102 and malformedState.bytes[6] == 0
        and malformedState.bytes[109] == 0 and malformedState.bytes[110] == 0,
        "malformed State packet retains its valid first row and zero-length final row")
    validatePeers(malformedState.peers, "malformed shared State broadcast", function(row)
        assert(row.invalidPayloadAfter > row.invalidPayloadBefore
            and row.reliableCallbacksBefore == 2 and row.reliableCallbacksAfter == 2
            and type(row.frames) == "table" and #row.frames == 1,
            "causal invalidPayload barrier proves whole State frame rejection without partial callback")
        local frame = row.frames[1]
        assert(frame.endpoint == 0 and frame.format == 5 and frame.kind == 2 and frame.count == 2
            and frame.referenceCount == 4 and frame.length == malformedState.length
            and type(frame.bytes) == "table" and #frame.bytes == #malformedState.bytes
            and type(frame.references) == "table" and #frame.references == 4,
            "actual malformed State raw bytes and Instance sidecars are captured")
        for index, byte in malformedState.bytes do
            assert(frame.bytes[index] == byte, "client observed the exact malformed State packet")
        end
        for index, sidecar in frame.references do
            local expectedClass = if index % 2 == 1 then "Part" else "Folder"
            local expectedPath = if index % 2 == 1 then partPath else folderPath
            assert(sidecar.className == expectedClass and sidecar.path == expectedPath,
                "malformed State sidecar preserves Instance identity")
        end
    end)

    local stateRecovery = state.recovery
    local recoveryFrame = stateRecovery.frame
    local expectedRecoveryBytes = { 5, 2, 1, 2, 18, 0, 4, 4, 0, 2, 33, 9, 0 }
    for index = 1, #"recovered" do
        table.insert(expectedRecoveryBytes, string.byte("recovered", index))
    end
    table.insert(expectedRecoveryBytes, 1)
    table.insert(expectedRecoveryBytes, 2)
    assert(stateRecovery.report.selected == 1 and stateRecovery.report.remaining == 0
        and stateRecovery.report.reliableHandoffs == 1 and stateRecovery.report.unreliableHandoffs == 0
        and stateRecovery.report.logicalHandoffs == 1
        and stateRecovery.counters.broadcastHandoffs == 1 and stateRecovery.counters.sendHandoffs == 0
        and stateRecovery.counters.outboundBytesCharged == clientCount * stateRecovery.charge
        and stateRecovery.counters.perRecipientBytes == stateRecovery.charge
        and recoveryFrame.endpoint == 0 and recoveryFrame.format == 5 and recoveryFrame.kind == 2
        and recoveryFrame.count == 1 and recoveryFrame.referenceCount == 2 and recoveryFrame.length == 24
        and #recoveryFrame.references == 2 and #recoveryFrame.records == 1,
        "valid shared State recovery is charged from its native frame")
    validateRawBytes(recoveryFrame, 5, 2, 1, 2, "valid shared State recovery frame")
    validateExactBytes(recoveryFrame, expectedRecoveryBytes, "valid shared State recovery")
    assert(recoveryFrame.records[1].codec == 4 and recoveryFrame.records[1].eventId == 4
        and recoveryFrame.records[1].referenceCount == 2 and recoveryFrame.records[1].ordinals[1] == 1
        and recoveryFrame.records[1].ordinals[2] == 2
        and stateRecovery.charge == recoveryFrame.length + recoveryFrame.referenceCount * 8
        and stateRecovery.charge == 40,
        "State recovery raw reference ordinals and exact modeled charge")
    validatePeers(stateRecovery.peers, "valid State recovery after malformed packet", function(row)
        assert(row.failure == nil and type(row.reliable) == "table"
            and #row.reliable == 3 and row.reliable[3].marker == 33
            and row.reliable[3].message == "recovered" and row.reliable[3].part == partPath
            and row.reliable[3].folder == folderPath and type(row.raw) == "table"
            and type(row.raw.Reliable) == "table" and #row.raw.Reliable == 2,
            "valid State recovery reaches each peer after rejection")
        local peerFrame = row.raw.Reliable[2]
        assert(peerFrame.endpoint == 0 and peerFrame.format == 5 and peerFrame.kind == 2
            and peerFrame.count == 1 and peerFrame.referenceCount == 2 and peerFrame.length == 24
            and #peerFrame.references == 2,
            "valid State recovery frame is observed by each current recipient")
        validateRawBytes(peerFrame, 5, 2, 1, 2, "per-peer valid State recovery frame")
        validateExactBytes(peerFrame, expectedRecoveryBytes, "per-peer valid State recovery")
        assert(peerFrame.references[1].className == "Part" and peerFrame.references[1].path == partPath
            and peerFrame.references[2].className == "Folder" and peerFrame.references[2].path == folderPath,
            "valid State recovery Instance sidecars retain exact identity")
    end)
    assert(state.cleanup.state == "Destroyed" and state.cleanup.pending == 0
        and state.cleanup.noLateHandoff == true,
        "Destroy clears pending shared State and cancels its timer")
    validatePeers(state.cleanup.peers, "destroyed shared State lane", function(row)
        assert(row.failure == nil and type(row.reliable) == "table" and #row.reliable == 3
            and type(row.raw) == "table" and type(row.raw.Reliable) == "table" and #row.raw.Reliable == 2,
            "Destroy produces no late State callback or raw packet")
    end)
end

local function validateInstanceReferences(proof, clientCount, readinessClients)
    local expectedClasses = { "Instance", "BasePart", "Part", "MeshPart", "Model", "Humanoid", "Tool",
        "Attachment", "Player", "Folder", "GuiObject", "Sound", "Animation", "Animator" }
    sameNumbers(proof.classes, expectedClasses)

    local instancePrefix = "ReplicatedStorage.RelayProofInstances."
    local common = {
        { "Instance", "Folder", "RootFolder", instancePrefix .. "RootFolder" },
        { "Part", "Part", "PartReference", instancePrefix .. "PartReference" },
        { "MeshPart", "MeshPart", "MeshPartReference", instancePrefix .. "MeshPartReference" },
        { "Humanoid", "Humanoid", "HumanoidReference", instancePrefix .. "ModelReference.HumanoidReference" },
        { "Attachment", "Attachment", "AttachmentReference", instancePrefix .. "PartReference.AttachmentReference" },
        { "Player", "Player", nil, nil },
        { "GuiObject", "Frame", "FrameReference", instancePrefix .. "ScreenReference.FrameReference" },
        { "Sound", "Sound", "SoundReference", instancePrefix .. "SoundReference" },
        { "BasePart", "Part", "PartReference", instancePrefix .. "PartReference" },
        { "BasePart", "MeshPart", "MeshPartReference", instancePrefix .. "MeshPartReference" },
        { "Folder", "Folder", "MapFolder", instancePrefix .. "MapFolder" },
        { "Animation", "Animation", "AnimationReference", instancePrefix .. "AnimationReference" },
    }
    local function caseReferences(branch, animatorPresent)
        local expected = table.clone(common)
        if animatorPresent then
            table.insert(expected, { "Animator", "Animator", "AnimatorReference",
                instancePrefix .. "ModelReference.HumanoidReference.AnimatorReference" })
        end
        if branch == "Model" then
            table.insert(expected, { "Model", "Model", "ModelReference", instancePrefix .. "ModelReference" })
        else
            table.insert(expected, { "Tool", "Tool", "ToolReference", instancePrefix .. "ToolReference" })
        end
        return expected
    end

    local function validateReference(actual, expected, label, expectedPlayerId)
        assert(type(actual) == "table" and actual.schemaClass == expected[1]
            and actual.className == expected[2], label .. " reference schema/actual class")
        if expected[3] == nil then
            assert(type(actual.name) == "string" and #actual.name > 0
                and actual.path == "Players." .. actual.name and actual.userId == expectedPlayerId,
                label .. " actual Player identity")
        else
            assert(actual.name == expected[3] and actual.path == expected[4] and actual.userId == nil,
                label .. " actual Instance identity/path")
        end
    end

    local function validateCase(actual, branch, animatorPresent, label, expectedPlayerId)
        assert(type(actual) == "table" and actual.branch == branch
            and actual.animatorPresent == animatorPresent, label .. " branch/optional value")
        local expected = caseReferences(branch, animatorPresent)
        assert(type(actual.references) == "table" and #actual.references == #expected,
            label .. " native Instance reference count")
        for index, item in expected do
            validateReference(actual.references[index], item, label .. " reference " .. tostring(index), expectedPlayerId)
        end
    end

    local peers = {}
    for _, peer in readinessClients do peers[peer.userId] = true end
    local function validateEntries(entries, label, visit)
        assert(type(entries) == "table" and #entries == clientCount, label .. " peer count")
        local seen = {}
        for _, entry in entries do
            assert(type(entry) == "table" and peers[entry.client] and not seen[entry.client],
                label .. " actual Player identity")
            seen[entry.client] = true
            visit(entry)
        end
        for id in peers do assert(seen[id], label .. " missing Player") end
    end

    local function rawFor(rows, client, endpoint)
        local result = {}
        for _, row in rows do
            if row.client == client and row.endpoint == endpoint then table.insert(result, row) end
        end
        return result
    end

    local function validateRawInstances(row, endpoint, eventId, expected, label, expectedPlayerId)
        assert(type(row) == "table" and row.endpoint == endpoint and row.format == 4
            and row.eventId == eventId and type(row.length) == "number" and row.length >= 4
            and row.referenceCount == #expected and row.argumentCount == #expected + 1
            and row.instanceArguments == #expected and row.nilArguments == 0,
            label .. " actual format-4 native sidecar arity")
        assert(type(row.references) == "table" and #row.references == #expected,
            label .. " raw reference slot count")
        for index, item in expected do
            local raw = row.references[index]
            assert(type(raw) == "table" and raw.kind == "Instance", label .. " raw Instance sidecar")
            validateReference({ schemaClass = item[1], className = raw.className, name = raw.name,
                path = raw.path, userId = raw.userId },
                item, label .. " raw reference " .. tostring(index), expectedPlayerId)
        end
    end

    local function validateRawNil(row, endpoint, eventId, label)
        assert(type(row) == "table" and row.endpoint == endpoint and row.format == 4
            and row.eventId == eventId and row.referenceCount == 1 and row.argumentCount == 2
            and row.instanceArguments == 0 and row.nilArguments == 1
            and type(row.references) == "table" and #row.references == 1
            and row.references[1].kind == "nil", label .. " actual nil sidecar arrival")
    end

    assert(type(proof) == "table" and type(proof.c2s) == "table" and type(proof.s2c) == "table"
        and type(proof.raw) == "table" and type(proof.raw.ingress) == "table"
        and type(proof.raw.egress) == "table" and peers[proof.s2cPlayer],
        "missing native Instance receipt/raw evidence")
    for _, direction in { "c2s", "s2c" } do
        validateEntries(proof[direction], "Instance " .. direction, function(entry)
            assert(type(entry.cases) == "table" and #entry.cases == 2,
                "Instance " .. direction .. " two case receipts")
            local expectedPlayerId = if direction == "c2s" then entry.client else proof.s2cPlayer
            validateCase(entry.cases[1], "Model", false, "Instance " .. direction .. " Model", expectedPlayerId)
            validateCase(entry.cases[2], "Tool", true, "Instance " .. direction .. " Tool", expectedPlayerId)
        end)
    end

    validateEntries(proof.raw.egress, "Instance raw S2C", function(entry)
        assert(type(entry.frames) == "table" and #entry.frames == 5,
            "Instance raw S2C exact native arrival count")
        local output = rawFor(entry.frames, entry.client, 2)
        assert(#output == 2, "Instance actual S2C format-4 event count")
        validateRawInstances(output[1], 2, 2, caseReferences("Model", false), "Instance S2C Model", proof.s2cPlayer)
        validateRawInstances(output[2], 2, 2, caseReferences("Tool", true), "Instance S2C Tool", proof.s2cPlayer)
    end)
    for _, output in proof.raw.egress do
        assert(peers[output.client], "Instance raw S2C peer")
        local missing, streaming = rawFor(output.frames, output.client, 4), rawFor(output.frames, output.client, 7)
        assert(#missing == 2 and #streaming == 1, "Instance missing/streaming raw frame counts")
        validateRawNil(missing[1], 4, 4, "ServerStorage reference")
        validateRawInstances(missing[2], 4, 4,
            { { "Folder", "Folder", "RootFolder", instancePrefix .. "RootFolder" } }, "valid S2C after ServerStorage")
        validateRawNil(streaming[1], 7, 7, "unstreamed Workspace reference")
    end

    local missing = proof.missing
    assert(type(missing) == "table" and type(missing.clientToServer) == "table"
        and type(missing.serverToClient) == "table", "missing native reference negative-path evidence")
    local c2sMissing = missing.clientToServer
    assert(c2sMissing.invalidPayload == clientCount and c2sMissing.callbacks == 0
        and c2sMissing.validAfter == clientCount and c2sMissing.source.name == "RelayProofClientOnlyFolder"
        and c2sMissing.source.className == "Folder" and c2sMissing.source.parent == "Workspace",
        "client-only Instance rejects before callback and a valid reference recovers")
    local ingressByClient = {}
    for _, row in proof.raw.ingress do
        assert(peers[row.client], "Instance raw C2S actual Player")
        local rows = ingressByClient[row.client]
        if rows == nil then
            rows = {}
            ingressByClient[row.client] = rows
        end
        table.insert(rows, row)
    end
    for id in peers do
        local input = rawFor(ingressByClient[id], id, 1)
        assert(#ingressByClient[id] == 4, "Instance raw C2S exact native arrival count")
        assert(#input == 2, "Instance actual C2S format-4 event count")
        validateRawInstances(input[1], 1, 1, caseReferences("Model", false), "Instance C2S Model", id)
        validateRawInstances(input[2], 1, 1, caseReferences("Tool", true), "Instance C2S Tool", id)
        local absent = rawFor(ingressByClient[id], id, 3)
        assert(#absent == 2, "client-only and recovered C2S raw frame count")
        validateRawNil(absent[1], 3, 3, "client-only reference")
        validateRawInstances(absent[2], 3, 3,
            { { "Folder", "Folder", "RootFolder", instancePrefix .. "RootFolder" } }, "valid C2S after client-only")
    end

    local s2cMissing = missing.serverToClient
    assert(s2cMissing.callbacksBeforeValid == 0 and type(s2cMissing.source) == "table"
        and s2cMissing.source.name == "RelayProofServerOnlyFolder"
        and s2cMissing.source.className == "Folder" and s2cMissing.source.parent == "ServerStorage"
        and type(s2cMissing.source.path) == "string"
        and string.sub(s2cMissing.source.path, 1, 14) == "ServerStorage.",
        "ServerStorage source is outside replication")
    validateEntries(s2cMissing.clients, "ServerStorage S2C rejection", function(entry)
        assert(entry.result.invalidPayload == 1 and entry.result.dispatched == 0
            and entry.result.callbacks == 0 and entry.result.failure == nil
            and entry.validAfter.dispatched == 1 and entry.validAfter.callbacks == 1
            and entry.validAfter.failure == nil,
            "ServerStorage reference arrives nil, does not dispatch, and does not poison later delivery")
    end)

    local streaming = proof.streaming
    assert(type(streaming) == "table" and streaming.enabled == true
        and streaming.modelName == "RelayProofUnstreamedModel"
        and type(streaming.farPath) == "string"
        and string.find(streaming.farPath, "^Workspace%.RelayProofUnstreamedModel%.") ~= nil,
        "far Workspace streaming fixture")
    validateEntries(streaming.absences, "streaming pre-send absence", function(entry)
        assert(entry.result.streamingEnabled == true and entry.result.containerPresent == true
            and entry.result.partAbsent == true
            and entry.result.stableSeconds >= 1, "far model is observably absent before sending")
    end)
    validateEntries(streaming.clients, "streaming rejection", function(entry)
        assert(entry.result.streamingEnabled == true and entry.result.containerPresent == true
            and entry.result.partAbsent == true
            and entry.result.invalidPayload == 1 and entry.result.dispatched == 0
            and entry.result.callbacks == 0 and entry.result.failure == nil,
            "unstreamed Part rejects despite its replicated model container, without callback")
    end)

    local scope = proof.scope
    assert(type(scope) == "table" and type(scope.budget) == "table"
        and type(scope.malformed) == "table" and type(scope.outputs) == "table",
        "missing scoped Instance reference evidence")
    local budget = scope.budget
    assert(budget.configuredBytes == 22 and budget.invalidPayload == 1
        and budget.aggregateBytes == clientCount - 1 and budget.perPlayerBytes == clientCount
        and budget.handlerCalls == 0 and type(scope.budgetIngress) == "table",
        "out-of-root later reference suppresses dispatch and retains per-player/aggregate byte admission")
    local budgetByClient = {}
    for _, row in scope.budgetIngress do
        assert(peers[row.client], "scoped budget raw peer")
        local rows = budgetByClient[row.client]
        if rows == nil then
            rows = {}
            budgetByClient[row.client] = rows
        end
        table.insert(rows, row)
    end
    for id in peers do
        local frames = rawFor(budgetByClient[id], id, 5)
        assert(#frames == 2, "scoped budget actual arrival count")
        local inside = { { "Folder", "Folder", "InsideFolder", "ReplicatedStorage.RelayProofInstanceScope.InsideFolder" } }
        local outside = { { "Part", "Part", "PartReference", instancePrefix .. "PartReference" } }
        local scopedPart = { { "Part", "Part", "InsidePart", "ReplicatedStorage.RelayProofInstanceScope.InsidePart" } }
        local firstExpected = { inside[1], outside[1] }
        local secondExpected = { inside[1], scopedPart[1] }
        validateRawInstances(frames[1], 5, 5, firstExpected, "out-of-root scoped frame")
        validateRawInstances(frames[2], 5, 5, secondExpected, "valid-shaped frame charged after scope rejection")
        sameNumbers(frames[1].ordinals, { 1, 2 })
        sameNumbers(frames[2].ordinals, { 1, 2 })
    end

    local malformed = scope.malformed
    assert(malformed.invalidPayload == clientCount and malformed.handlerCallsBeforeValid == 0
        and malformed.validAfter == clientCount and malformed.clients == clientCount,
        "duplicate later sidecar ordinal rejects atomically and valid event recovers")
    local malformedByClient = {}
    for _, row in malformed.rawIngress do
        assert(peers[row.client], "malformed scoped raw peer")
        local rows = malformedByClient[row.client]
        if rows == nil then
            rows = {}
            malformedByClient[row.client] = rows
        end
        table.insert(rows, row)
    end
    for id in peers do
        local frames = rawFor(malformedByClient[id], id, 5)
        assert(#frames == 2, "malformed scoped raw frame count")
        local refs = {
            { "Folder", "Folder", "InsideFolder", "ReplicatedStorage.RelayProofInstanceScope.InsideFolder" },
            { "Part", "Part", "InsidePart", "ReplicatedStorage.RelayProofInstanceScope.InsidePart" },
        }
        validateRawInstances(frames[1], 5, 5, refs, "duplicate sidecar ordinal")
        validateRawInstances(frames[2], 5, 5, refs, "recovered scoped event")
        sameNumbers(frames[1].ordinals, { 1, 1 })
        sameNumbers(frames[2].ordinals, { 1, 2 })
    end

    assert(scope.outputs.rejectedDestroyed == true and scope.outputs.rejectedReparent == true
        and scope.outputs.handoffsBefore == 0
        and scope.outputs.handoffsAfter == 1, "destroyed/reparented outbound Instances reject before handoff")
    validateEntries(scope.outputs.delivered, "scoped S2C delivery", function(entry)
        assert(entry.result.calls == 1 and entry.result.failure == nil
            and entry.result.references.first.className == "Folder"
            and entry.result.references.first.path == "ReplicatedStorage.RelayProofInstanceScope.InsideFolder"
            and entry.result.references.second.className == "Part"
            and entry.result.references.second.path == "ReplicatedStorage.RelayProofInstanceScope.InsidePart",
            "valid scoped S2C references preserve identities after reparent rejection")
        local output = rawFor(entry.raw, entry.client, 6)
        assert(#output == 1, "scoped S2C actual native frame count")
        validateRawInstances(output[1], 6, 6, {
            { "Folder", "Folder", "InsideFolder", "ReplicatedStorage.RelayProofInstanceScope.InsideFolder" },
            { "Part", "Part", "InsidePart", "ReplicatedStorage.RelayProofInstanceScope.InsidePart" },
        }, "scoped S2C raw sidecars")
    end)
end

local function validateQuantized(proof, clientCount, readinessClients)
    assert(type(proof) == "table" and type(proof.immediate) == "table"
        and type(proof.routes) == "table", "missing native scalar quantization evidence")
    local peers = {}
    for _, peer in readinessClients do peers[peer.userId] = true end

    local function validateEntries(entries, label, visit)
        assert(type(entries) == "table" and #entries == clientCount, label .. " peer count")
        local seen = {}
        for _, entry in entries do
            assert(type(entry) == "table" and peers[entry.client] and not seen[entry.client],
                label .. " actual client identity")
            seen[entry.client] = true
            visit(entry)
        end
        for id in peers do assert(seen[id], label .. " missing client") end
    end

    local expectedGrid = { -1, -0.5, -0.5, 0, -1, 1, 35 * 0.01, 0.1001 }
    local function validateGrid(observation, label)
        assert(type(observation) == "table" and observation.zeroPositive == true
            and type(observation.values) == "table", label .. " callback observation")
        assert(#observation.values == #expectedGrid, label .. " callback arity")
        for index, value in expectedGrid do
            if index == 7 then
                -- The native fixture asserts exact equality before JSON egress;
                -- its raw code 35 is checked below. The host report can differ by one ULP.
                assert(type(observation.values[index]) == "number"
                    and math.abs(observation.values[index] - value) <= 2 ^ -54,
                    label .. " decimal report representation")
            else
                assert(observation.values[index] == value, label .. " callback value/order")
            end
        end
    end

    local immediate = proof.immediate
    local function validateNumericProbes(probes, label)
        assert(type(probes) == "table" and type(probes.minimumStep) == "table"
            and type(probes.largeOffset) == "table", label .. " native numeric probe count")
        local minimum = probes.minimumStep
        local minimumStep = 2 ^ -974
        assert(minimum.name == "minimum-step" and minimum.minimum == 0 and minimum.maximum == minimumStep
            and minimum.step == minimumStep and minimum.input == minimumStep / 2
            and minimum.value == minimumStep and minimum.code == 1 and minimum.width == 1
            and minimum.error == minimumStep / 2 and minimum.error <= minimum.maximumError
            and minimum.stable == true and minimum.rewriteCode == minimum.code,
            label .. " exact minimum-step normalize/write/read bound and stable code")
        local offset = probes.largeOffset
        assert(offset.name == "large-offset-residual" and offset.minimum == 1e13
            and offset.maximum == 1e13 + 1.03125 and offset.step == 1 and offset.input == 1e13 + 0.5
            and offset.value == 1e13 + 1.03125 and offset.code == 1 and offset.width == 1
            and offset.error == math.abs(offset.value - offset.input)
            and offset.error <= offset.maximumError and offset.stable == true
            and offset.rewriteCode == offset.code,
            label .. " permitted large-offset residual error bound and stable code")
    end

    assert(type(immediate.numeric) == "table", "missing native quantized numeric probes")
    validateNumericProbes(immediate.numeric.server, "Studio server")
    validateEntries(immediate.numeric.clients, "Studio client quantized numeric probes", function(entry)
        validateNumericProbes(entry.probes, "Studio client")
    end)
    validateEntries(immediate.c2s, "quantized immediate C2S", function(entry)
        validateGrid(entry.value, "quantized immediate C2S")
    end)
    validateEntries(immediate.s2c, "quantized immediate S2C", function(entry)
        validateGrid(entry.value, "quantized immediate S2C")
    end)
    for _, name in { "wideC2S", "wideS2C" } do
        validateEntries(immediate[name], "quantized u16 " .. name, function(entry)
            assert(entry.value == 256, "quantized u16 actual callback value")
        end)
    end

    local expectedCodes = { 0, 1, 1, 2, 0, 4, 35, 1 }
    local function rawFor(rows, client, eventId)
        local found = {}
        for _, row in rows do
            if row.client == client and row.eventId == eventId then table.insert(found, row) end
        end
        return found
    end
    local raw = immediate.raw
    assert(type(raw) == "table" and type(raw.ingress) == "table" and type(raw.egress) == "table",
        "missing actual quantized remote receipts")
    for id in peers do
        local inputGrid, inputWide = rawFor(raw.ingress, id, 1), rawFor(raw.ingress, id, 3)
        local outputGrid, outputWide = rawFor(raw.egress, id, 2), rawFor(raw.egress, id, 4)
        assert(#inputGrid == 1 and #inputWide == 4 and #outputGrid == 1 and #outputWide == 1,
            "quantized immediate raw event counts")
        local function validateGridFrame(frame, eventId, label)
            assert(frame.endpoint == eventId and frame.eventId == eventId and frame.format == 1 and frame.length == 11,
                label .. " actual reliable buffer header/length")
            sameNumbers(frame.codes, expectedCodes)
        end
        validateGridFrame(inputGrid[1], 1, "quantized C2S")
        validateGridFrame(outputGrid[1], 2, "quantized S2C")
        local unused, truncated, valid, overBudget = inputWide[1], inputWide[2], inputWide[3], inputWide[4]
        assert(unused.endpoint == 3 and unused.format == 1 and unused.length == 5
            and unused.bytes[1] == 1 and unused.bytes[2] == 1,
            "native unused-u16-code rejection probe")
        assert(truncated.endpoint == 3 and truncated.format == 1 and truncated.length == 4 and truncated.bytes[1] == 1
            and truncated.bytes[2] == nil, "native truncated-u16-code rejection probe")
        assert(valid.endpoint == 3 and valid.format == 1 and valid.length == 5
            and valid.bytes[1] == 0 and valid.bytes[2] == 1,
            "native u16 256 little-endian code")
        assert(overBudget.endpoint == 3 and overBudget.format == 1 and overBudget.length == 5 and overBudget.bytes[1] == 0
            and overBudget.bytes[2] == 0, "native exact-byte over-budget frame")
        assert(outputWide[1].endpoint == 4 and outputWide[1].format == 1 and outputWide[1].length == 5
            and outputWide[1].bytes[1] == 0 and outputWide[1].bytes[2] == 1,
            "native S2C u16 256 little-endian code")
    end

    local counters = immediate.counters
    assert(type(counters) == "table" and counters.perPlayerBytes == clientCount
        and counters.aggregateBytes == 0 and counters.invalidPayload == 2 * clientCount
        and counters.inputDispatched == clientCount and counters.wideDispatched == clientCount
        and counters.wideInvalidPayload == 2 * clientCount,
        "quantized malformed-frame charging and atomic dispatch counters")

    local routes = proof.routes
    validateEntries(routes.rpc, "quantized RPC", function(entry)
        assert(entry.request == 0.5 and entry.response == 0.5, "quantized RPC actual normalized values")
    end)
    for _, name in { "queueC2S", "queueS2C" } do
        validateEntries(routes[name], "quantized FIFO " .. name, function(entry)
            assert(entry.value == 0.5, "quantized FIFO actual normalized value")
        end)
    end
    for _, name in { "queueReports" } do
        validateEntries(routes[name], "quantized FIFO " .. name, function(entry)
            local report = entry.report
            assert(type(report) == "table" and report.selected == 1 and report.reliableHandoffs == 1
                and report.unreliableHandoffs == 0 and report.logicalHandoffs == 1,
                "quantized FIFO native handoff report")
        end)
    end
    for _, entry in routes.rpc do
        assert(type(entry) == "table" and type(entry.queueReport) == "table"
            and entry.queueReport.selected == 1 and entry.queueReport.reliableHandoffs == 1
            and entry.queueReport.unreliableHandoffs == 0 and entry.queueReport.logicalHandoffs == 1,
            "quantized FIFO client handoff report")
    end
end

local function validateCompactTransport(proof, clientCount, readinessClients)
    assert(type(proof) == "table" and type(proof.compact) == "table"
        and type(proof.packed) == "table", "missing compact transport native evidence")
    local peers = {}
    local orderedPeers = {}
    for _, peer in readinessClients do
        peers[peer.userId] = true
        table.insert(orderedPeers, peer.userId)
    end
    table.sort(orderedPeers)

    local function validateEntries(entries, label, visit)
        assert(type(entries) == "table" and #entries == clientCount, label .. " peer count")
        local seen = {}
        for _, entry in entries do
            assert(type(entry) == "table" and peers[entry.client] and not seen[entry.client],
                label .. " actual client identity")
            seen[entry.client] = true
            visit(entry)
        end
        for id in peers do assert(seen[id], label .. " missing client") end
    end

    local function bytesEqual(actual, expected, label)
        assert(type(actual) == "table" and #actual == #expected, label .. " byte count")
        for index, value in expected do assert(actual[index] == value, label .. " byte value") end
    end

    local compact = proof.compact
    for _, name in { "c2sVector3", "s2cVector3" } do
        validateEntries(compact[name], "compact Vector3 " .. name, function(entry)
            bytesEqual(entry.value, { 2, 256, 0 }, "actual Vector3 component values")
            if name == "c2sVector3" then
                bytesEqual(entry.recovery, { 2, 256, 0 }, "post-malformed Vector3 recovery value")
            end
        end)
    end
    for _, name in { "c2sVector2", "s2cVector2" } do
        validateEntries(compact[name], "compact Vector2 " .. name, function(entry)
            bytesEqual(entry.value, { 2, 256 }, "actual Vector2 component values")
        end)
    end
    local expectedPositions = { { 1, 2, 3 }, { 1, 2, 3 }, { 2, 3, 4 }, { 2, 3, 4 }, { 2, 3, 4 } }
    for _, name in { "c2sFrames", "s2cFrames" } do
        validateEntries(compact[name], "compact CFrame " .. name, function(entry)
            assert(type(entry.values) == "table" and #entry.values == #expectedPositions,
                "compact CFrame native field count")
            for index, observation in entry.values do
                bytesEqual(observation.position, expectedPositions[index], "compact CFrame actual position")
                assert(type(observation.positionError) == "number" and observation.positionError >= 0
                    and observation.positionError <= 0.5001,
                    "compact CFrame post-construction translation error")
                assert(type(observation.rotationError) == "number" and observation.rotationError >= 0
                    and observation.rotationError <= 0.002,
                    "compact CFrame independently bounded rotation error")
            end
        end)
    end

    local function rawFor(rows, client, eventId)
        local found = {}
        for _, row in rows do
            if row.client == client and row.eventId == eventId then table.insert(found, row) end
        end
        return found
    end
    assert(type(compact.raw) == "table" and type(compact.raw.ingress) == "table"
        and type(compact.raw.egress) == "table", "compact native raw receipt tables")
    local function validateVector3Frame(frame, length, expected, label)
        assert(frame.endpoint == 1 or frame.endpoint == 2, label .. " actual outer endpoint")
        assert(frame.format == 1 and frame.length == length, label .. " reliable frame header/length")
        bytesEqual(frame.bytes, expected, label .. " little-endian Vector3 words")
    end
    local function validateVector2Frame(frame, label)
        assert(frame.endpoint == 3 or frame.endpoint == 4, label .. " actual outer endpoint")
        assert(frame.format == 1 and frame.length == 7, label .. " reliable frame header/length")
        bytesEqual(frame.bytes, { 2, 0, 0, 1 }, label .. " little-endian Vector2 words")
    end
    local function validateFrameFrame(frame, endpoint, label)
        assert(frame.endpoint == endpoint and frame.eventId == endpoint and frame.format == 1
            and frame.length == 63 and type(frame.bytes) == "table" and #frame.bytes == 60,
            label .. " actual compact CFrame header and 12-byte leaf widths")
        for index = 1, 5 do
            local base = (index - 1) * 12
            local expected = if index <= 2 then { 1, 2, 3 } else { 2, 3, 4 }
            for axis, code in expected do
                local offset = base + (axis - 1) * 2 + 1
                assert(frame.bytes[offset] == code % 256 and frame.bytes[offset + 1] == math.floor(code / 256),
                    label .. " actual compact position code")
            end
            local function word(offset)
                return frame.bytes[base + offset] + frame.bytes[base + offset + 1] * 256
            end
            for offset = 7, 12, 2 do
                local code = word(offset)
                assert(type(code) == "number" and code >= 0 and code <= 65_535,
                    label .. " actual XYZ rotation word")
            end
            if index == 1 then
                assert(word(7) == 0 and word(9) == 0 and word(11) == 0,
                    label .. " identity XYZ words")
            elseif index == 2 then
                assert(word(7) == 32_768 and word(9) == 0 and word(11) == 0,
                    label .. " pi XYZ word")
            end
        end
    end
    for _, client in orderedPeers do
        local ingress3, ingress2, ingressFrame = rawFor(compact.raw.ingress, client, 1),
            rawFor(compact.raw.ingress, client, 3), rawFor(compact.raw.ingress, client, 5)
        local egress3, egress2, egressFrame = rawFor(compact.raw.egress, client, 2),
            rawFor(compact.raw.egress, client, 4), rawFor(compact.raw.egress, client, 6)
        assert(#ingress3 == 4 and #ingress2 == 1 and #ingressFrame == 3
            and #egress3 == 1 and #egress2 == 1 and #egressFrame == 1,
            "compact native raw ingress/egress counts")
        validateVector3Frame(ingress3[1], 9, { 2, 0, 0, 1, 0, 0 }, "Vector3 C2S")
        validateVector3Frame(ingress3[2], 9, { 1, 1, 0, 0, 0, 0 }, "unused Vector3 code")
        validateVector3Frame(ingress3[3], 8, { 0, 0, 0, 0, 0 }, "truncated Vector3")
        validateVector3Frame(ingress3[4], 9, { 2, 0, 0, 1, 0, 0 }, "post-malformed Vector3 recovery")
        validateVector2Frame(ingress2[1], "Vector2 C2S")
        validateFrameFrame(ingressFrame[1], 5, "CFrame C2S")
        assert(ingressFrame[2].endpoint == 5 and ingressFrame[2].length == 63
            and ingressFrame[2].bytes[1] == 1 and ingressFrame[2].bytes[2] == 1,
            "unused CFrame position code raw receipt")
        assert(ingressFrame[3].endpoint == 5 and ingressFrame[3].length == 62
            and #ingressFrame[3].bytes == 59, "truncated CFrame raw receipt")
        validateVector3Frame(egress3[1], 9, { 2, 0, 0, 1, 0, 0 }, "Vector3 S2C")
        validateVector2Frame(egress2[1], "Vector2 S2C")
        validateFrameFrame(egressFrame[1], 6, "CFrame S2C")
    end
    local compactCounters = compact.counters
    assert(type(compactCounters) == "table" and compactCounters.invalidPayload == 4 * clientCount
        and compactCounters.vector3Invalid == 2 * clientCount and compactCounters.frameInvalid == 2 * clientCount
        and compactCounters.vector2Dispatched == clientCount
        and compactCounters.vector3Dispatched == 2 * clientCount
        and compactCounters.frameDispatched == clientCount
        and compactCounters.perPlayerByteRejected == clientCount
        and compactCounters.aggregateByteRejected == 0,
        "compact native malformed frames reject before handlers and permit recovery")

    local fanout = proof.outboundFanout
    assert(type(fanout) == "table" and fanout.attempts.first == true and fanout.attempts.second == true
        and fanout.attempts.targeted == false and fanout.attempts.broadcast == false
        and fanout.failures.targeted == "OutboundRateLimited"
        and fanout.failures.broadcast == "OutboundRateLimited",
        "outbound direct sends, recipient lists and atomic Broadcast refusal")
    if clientCount == 1 then
        assert(fanout.attempts.healthy == nil and fanout.attempts.sendTo == nil
            and fanout.attempts.sendExcept == nil and fanout.failures.except == nil,
            "single-client run skips calls requiring a distinct healthy peer")
    else
        assert(fanout.attempts.healthy == true and fanout.attempts.sendTo == true
            and fanout.attempts.sendExcept == false and fanout.failures.except == "OutboundRateLimited",
            "two-client run proves healthy-peer independence and SendExcept refusal")
    end
    local exhaustedId = orderedPeers[1]
    validateEntries(fanout.clients, "outbound fanout native recipients", function(entry)
        local expectedValues = if entry.client == exhaustedId then { true, true } else { true, false }
        assert(type(entry.values) == "table" and #entry.values == 2,
            "outbound recipient actual callback count")
        for index, expected in expectedValues do assert(entry.values[index] == expected,
            "atomic Broadcast did not partially hand off") end
        assert(type(entry.raw) == "table" and #entry.raw == 2,
            "outbound recipient actual RemoteEvent receipt count")
        for index, expected in expectedValues do
            local frame = entry.raw[index]
            assert(frame.endpoint == 1 and frame.argumentCount == 1 and frame.value == expected,
                "outbound callback values match the native RemoteEvent boolean tuple")
        end
    end)
    assert(type(fanout.counters) == "table"
        and fanout.counters.rejected == (if clientCount == 1 then 2 else 3)
        and fanout.counters.charged == 8 * clientCount and fanout.counters.handoffs == 2 * clientCount
        and fanout.counters.controlHandoffs >= clientCount
        and fanout.counters.broadcasts == 0,
        "outbound fanout exact application-byte debits and zero refused handoffs")

    local rpc = proof.outboundRpc
    assert(type(rpc) == "table", "missing native outbound RPC refusal proof")
    validateEntries(rpc.clients, "outbound RPC refusal", function(entry)
        assert(type(entry.result) == "table" and entry.result.ok == false
            and entry.result.error == "OutboundRateLimited" and entry.handlerCalls == 1
            and entry.otherFrames == 0
            and type(entry.raw) == "table" and #entry.raw == 1
            and entry.raw[1].kind == 5 and entry.raw[1].length == 44,
            "kind-5 RPC response settles the client without retry or timeout")
    end)
    assert(rpc.counters.rejected == clientCount and rpc.counters.charged == 0
        and rpc.counters.dispatched == clientCount and rpc.counters.handlerErrors == 0,
        "outbound RPC refusals are exempt control and never charged as application bytes")

    local queues = proof.outboundQueues
    assert(type(queues) == "table", "missing native outbound queue refusal proof")
    validateEntries(queues.clients, "outbound queue refusal", function(entry)
        for _, name in { "batch", "state" } do
            local row = entry[name]
            assert(type(row) == "table" and row.state == "Open" and row.pending == 1
                and row.lastError == "OutboundRateLimited" and row.selected == 0 and row.remaining == 1
                and row.cleanupPending == 0,
                "outbound queue refusal is visible, retains data, and cleans up explicitly")
            assert(row.cleanupState == (if name == "batch" then "Terminal" else "Destroyed"),
                "outbound queue lifecycle cleanup state")
        end
        for _, field in { "pulses", "queues", "states", "raw", "rpcRaw", "other" } do
            assert(entry.received[field] == 0,
                "outbound queued refusal has no client callback or native RemoteEvent handoff")
        end
    end)
    assert(queues.counters.rejected == 2 * clientCount and queues.counters.charged == 0
        and queues.counters.handoffs == 0 and queues.counters.controlHandoffs >= clientCount,
        "outbound queued refusal makes no partial handoff or debit")

    local packed = proof.packed
    local expectedTuple = { enabled = true, mode = "Duck", optionalFlag = false, optionalMode = "Run", tail = 513 }
    local expectedFlags, expectedModes = { true, false, true, false, true }, { "Idle", "Duck", "Jump" }
    local expectedRecord = { enabled = true, mode = "Jump", count = 201 }
    for _, direction in { "input", "output" } do
        local rows = packed[direction]
        local repetitions = if direction == "input" then 2 else 1
        for _, kind in { "tuple", "arrays", "records" } do
            validateEntries(rows[kind], "packed " .. direction .. " " .. kind, function(entry)
                local values = if direction == "input" then entry.values else { entry.value }
                assert(type(values) == "table" and #values == repetitions,
                    "packed actual handler repetition count")
                for _, value in values do
                    if kind == "tuple" then
                        for key, expected in expectedTuple do assert(value[key] == expected,
                            "packed tuple decoded callback value") end
                    elseif kind == "arrays" then
                        assert(type(value.flags) == "table" and type(value.modes) == "table",
                            "packed array callback types")
                        sameNumbers(value.flags, expectedFlags)
                        assert(#value.modes == #expectedModes, "packed enum array cardinality")
                        for index, expected in expectedModes do assert(value.modes[index] == expected,
                            "packed enum array value") end
                    else
                        for key, expected in expectedRecord do assert(value[key] == expected,
                            "packed struct callback value") end
                    end
                end
            end)
        end
    end

    assert(type(packed.raw) == "table" and type(packed.raw.ingress) == "table"
        and type(packed.raw.egress) == "table", "packed native raw frame observations")
    local function packedRawFor(rows, client, eventId)
        local found = {}
        for _, row in rows do if row.client == client and row.eventId == eventId then table.insert(found, row) end end
        return found
    end
    for _, client in orderedPeers do
        local ingressTuple = packedRawFor(packed.raw.ingress, client, 1)
        local ingressArray = packedRawFor(packed.raw.ingress, client, 3)
        local ingressStruct = packedRawFor(packed.raw.ingress, client, 5)
        local egressTuple = packedRawFor(packed.raw.egress, client, 2)
        local egressArray = packedRawFor(packed.raw.egress, client, 4)
        local egressStruct = packedRawFor(packed.raw.egress, client, 6)
        assert(#ingressTuple == 6 and #ingressArray == 4 and #ingressStruct == 2
            and #egressTuple == 1 and #egressArray == 1 and #egressStruct == 1,
            "packed native raw ingress/egress cardinality")
        local function checkTuple(bytes, length, expected, label)
            assert(length == #expected + 3, label .. " actual frame length")
            bytesEqual(bytes, expected, label .. " actual mask and ordered body bytes")
        end
        checkTuple(ingressTuple[1].bytes, ingressTuple[1].length, { 0xD9, 0, 1, 2 }, "packed tuple C2S")
        checkTuple(ingressTuple[2].bytes, ingressTuple[2].length, { 0xD9, 4, 1, 2 }, "nonzero padding probe")
        checkTuple(ingressTuple[3].bytes, ingressTuple[3].length, { 0x0B, 0, 1, 2 }, "unused enum probe")
        checkTuple(ingressTuple[4].bytes, ingressTuple[4].length, { 0x80, 0, 1, 2 }, "absent optional value probe")
        checkTuple(ingressTuple[5].bytes, ingressTuple[5].length, { 0xD9, 0, 0 }, "truncated tuple probe")
        checkTuple(ingressTuple[6].bytes, ingressTuple[6].length, { 0xD9, 0, 1, 2 }, "packed tuple C2S recovery")
        checkTuple(ingressArray[1].bytes, ingressArray[1].length, { 5, 0, 0x15, 3, 0, 0xA0, 0 }, "packed arrays C2S")
        checkTuple(ingressArray[2].bytes, ingressArray[2].length, { 5, 0, 0x80, 0, 0 }, "array padding probe")
        checkTuple(ingressArray[3].bytes, ingressArray[3].length, { 0, 0, 3, 0, 0xA5, 0 }, "array unused enum probe")
        checkTuple(ingressArray[4].bytes, ingressArray[4].length, { 5, 0, 0x15, 3, 0, 0xA0, 0 }, "packed arrays C2S recovery")
        checkTuple(ingressStruct[1].bytes, ingressStruct[1].length, { 5, 201 }, "packed struct C2S")
        checkTuple(ingressStruct[2].bytes, ingressStruct[2].length, { 5, 201 }, "packed struct C2S recovery")
        local admittedBytes = 0
        for _, rows in { ingressTuple, ingressArray, ingressStruct } do
            for _, frame in rows do admittedBytes += frame.length end
        end
        assert(admittedBytes == 88, "exact 88-byte packed ingress admission before the one-byte probe")
        checkTuple(egressTuple[1].bytes, egressTuple[1].length, { 0xD9, 0, 1, 2 }, "packed tuple S2C")
        checkTuple(egressArray[1].bytes, egressArray[1].length, { 5, 0, 0x15, 3, 0, 0xA0, 0 }, "packed arrays S2C")
        checkTuple(egressStruct[1].bytes, egressStruct[1].length, { 5, 201 }, "packed struct S2C")
    end
    local counters = packed.counters
    assert(counters.invalidPayload == 6 * clientCount and counters.tupleInvalid == 4 * clientCount
        and counters.arrayInvalid == 2 * clientCount and counters.tupleDispatched == 2 * clientCount
        and counters.arrayDispatched == 2 * clientCount and counters.structDispatched == 2 * clientCount
        and counters.perPlayerByteRejected == clientCount and counters.aggregateByteRejected == 0
        and counters.handlerErrors == 0,
        "packed malformed frames are byte charged and reject atomically before callbacks, with recovery and exact byte refusal")
end

local function validateBufferDeferral(proof, clientCount, readinessClients)
    assert(type(proof) == "table" and type(proof.clients) == "table"
        and type(proof.raw) == "table", "missing native bounded-buffer observations")
    local peers = {}
    for _, peer in readinessClients do peers[peer.userId] = true end

    local function sameBytes(actual, expected, label)
        assert(type(actual) == "table" and #actual == #expected, label .. " byte count")
        for index, value in expected do
            assert(type(actual[index]) == "number" and actual[index] % 1 == 0
                and actual[index] == value, label .. " byte value/order")
        end
    end
    local function validatePeers(rows, label, visit)
        assert(type(rows) == "table" and #rows == clientCount, label .. " peer count")
        local seen = {}
        for _, row in rows do
            assert(type(row) == "table" and peers[row.client] and not seen[row.client],
                label .. " actual peer identity")
            seen[row.client] = true
            visit(row)
        end
    end
    local function rowsFor(rows, client)
        local found = {}
        for _, row in rows do if row.client == client then table.insert(found, row) end end
        return found
    end

    validatePeers(proof.clients, "bounded native buffers", function(entry)
        sameNumbers(entry.input[1], { 0, 128, 255, 3 })
        sameNumbers(entry.input[2], { 9, 8, 7, 6 })
        sameNumbers(entry.output, { 5, 0, 255, 128 })
        sameNumbers(entry.queued, { 12, 34, 56, 78 })
        assert(type(entry.send) == "table" and entry.send.oversizedSent == false
            and entry.send.oversizedError == "InvalidPayload" and entry.send.handoffDelta == 0,
            "oversized native buffer rejected locally before handoff")
    end)
    validatePeers(proof.queueReports, "buffer snapshot Batch report", function(entry)
        assert(entry.selected == 1 and entry.reliableHandoffs == 1 and entry.logicalHandoffs == 1,
            "buffer snapshot is delivered through one native Batch frame")
    end)

    local ingress, egress, queuedEgress = proof.raw.ingress, proof.raw.egress, proof.raw.queuedEgress
    assert(type(ingress) == "table" and type(egress) == "table" and type(queuedEgress) == "table",
        "missing raw native buffer frames")
    assert(#ingress == 7 * clientCount and #egress == clientCount and #queuedEgress == clientCount,
        "exact native buffer raw receipt cardinality")
    local expectedIngress = {
        { 1, 1, 0, 4, 0, 0, 128, 255, 3 },
        { 1, 1, 0, 5, 0, 10, 20, 30, 40, 50 },
        { 1, 1, 0, 4 },
        { 1, 1, 0, 4, 0, 11, 22 },
        { 1, 1, 0, 4, 0, 1, 2, 3, 4, 5 },
        { 1, 1, 0, 4, 0, 9, 8, 7, 6 },
        { 1 },
    }
    local expectedEgress = { 1, 2, 0, 4, 0, 5, 0, 255, 128 }
    local expectedQueued = { 2, 1, 1, 9, 0, 1, 3, 0, 4, 0, 12, 34, 56, 78 }
    local admittedTotal = 0
    for client in peers do
        local inbound = rowsFor(ingress, client)
        assert(#inbound == #expectedIngress, "native immediate input and one-byte probe raw count")
        for index, expected in expectedIngress do
            local row = inbound[index]
            assert(row.endpoint == 1 and row.length == #expected,
                "native immediate input raw endpoint and frame length")
            sameBytes(row.frameBytes, expected, "native immediate buffer frame " .. index)
            if index < #expectedIngress then
                assert(row.headerComplete == true and row.format == 1 and row.eventId == 1,
                    "well-formed immediate header identity, including malformed body probes")
                admittedTotal += row.length
            else
                assert(row.headerComplete == false and row.eventId == nil,
                    "one-byte raw probe is refused before decoding a complete header")
            end
        end
        local outputRows, queuedRows = rowsFor(egress, client), rowsFor(queuedEgress, client)
        assert(#outputRows == 1 and outputRows[1].endpoint == 2 and outputRows[1].eventId == 2
            and outputRows[1].format == 1 and outputRows[1].length == #expectedEgress,
            "native buffer immediate S2C raw receipt")
        sameBytes(outputRows[1].frameBytes, expectedEgress, "native buffer immediate S2C bytes")
        assert(#queuedRows == 1 and queuedRows[1].kind == 1 and queuedRows[1].eventId == 3
            and queuedRows[1].bodyBytes == 9 and queuedRows[1].length == #expectedQueued,
            "native queued S2C frame contains the expected endpoint body")
        sameBytes(queuedRows[1].bytes, expectedQueued, "native queued buffer frame")
    end
    assert(admittedTotal == 49 * clientCount, "exact admitted raw bytes before per-player refusal")

    local counters = proof.counters
    assert(type(counters) == "table" and counters.invalidPayload == 4 * clientCount
        and counters.inputInvalid == 4 * clientCount and counters.inputDispatched == 2 * clientCount
        and counters.perPlayerByteRejected == clientCount and counters.aggregateByteRejected == 0
        and counters.handlerErrors == 0,
        "bounded buffer malformed frames charge exact byte budgets and recover")
end

local function validateStateDeferral(proof, readinessClients)
    assert(type(proof) == "table", "missing single-player deferred State observations")
    local peers = {}
    for _, peer in readinessClients do peers[peer.userId] = true end

    local function sameBytes(actual, expected, label)
        assert(type(actual) == "table" and #actual == #expected, label .. " byte count")
        for index, value in expected do
            assert(type(actual[index]) == "number" and actual[index] % 1 == 0
                and actual[index] == value, label .. " byte value/order")
        end
    end
    local function checkFirst(snapshot, pending, label)
        local flush = snapshot and snapshot.lastFlush
        assert(type(snapshot) == "table" and snapshot.state == "Open" and snapshot.pendingKeys == pending
            and type(flush) == "table" and flush.ok == false and flush.error == "OutboundRateLimited"
            and type(flush.report) == "table" and flush.report.selected == 0
            and flush.report.remaining == pending,
            label .. " records the refusal and retains all selected State keys")
    end
    local function checkFinal(snapshot, selected, expired, label)
        local flush = snapshot and snapshot.lastFlush
        assert(type(snapshot) == "table" and snapshot.state == "Open" and snapshot.pendingKeys == 0
            and type(flush) == "table" and flush.ok == true and flush.error == nil
            and type(flush.report) == "table" and flush.report.selected == selected
            and flush.report.remaining == 0 and flush.report.expired == expired,
            label .. " final automatic service/expiry status")
    end
    local function checkCase(name, expectedStateValue, selected, expired, charged)
        local row = proof[name]
        assert(type(row) == "table" and peers[row.client] and row.client ~= 0,
            name .. " actual targeted Player identity")
        checkFirst(row.first, if name == "survivor" then 2 else 1, name)
        if name == "replacementAge" then
            assert(type(row.replaced) == "table" and row.replaced.pendingKeys == 1
                and row.replaced.pendingBodyBytes == 25,
                "20-byte replacement owns its serialized State body while retaining one key")
        end
        if name == "destroy" then
            assert(type(row.final) == "table" and row.final.state == "Destroyed"
                and row.final.pendingKeys == 0 and row.final.lastFlush.error == "OutboundRateLimited"
                and row.final.lastFlush.report.selected == 0,
                "Destroy clears refused State data and leaves the lane terminal")
        else
            checkFinal(row.final, selected, expired, name)
        end

        local result = row.result
        local stateCount = if expectedStateValue == nil then 0 else 1
        assert(type(result) == "table" and result.failure == nil and type(result.pulses) == "table"
            and #result.pulses == 3 and type(result.pulseRaw) == "table" and #result.pulseRaw == 3
            and type(result.states) == "table" and #result.states == stateCount
            and type(result.stateRaw) == "table" and #result.stateRaw == stateCount,
            name .. " independent callback and raw receipt barriers")
        for index = 1, 3 do
            sameNumbers(result.pulses[index], { 1, 2, 3, 4 })
            local raw = result.pulseRaw[index]
            assert(raw.endpoint == 1 and raw.eventId == 1 and raw.format == 1 and raw.length == 9,
                name .. " actual precharge Pulse frame")
            sameBytes(raw.frameBytes, { 1, 1, 0, 4, 0, 1, 2, 3, 4 }, name .. " Pulse bytes")
        end
        if expectedStateValue ~= nil then
            sameNumbers(result.states[1], { expectedStateValue })
            local raw = result.stateRaw[1]
            assert(raw.length == 11, name .. " actual State frame length")
            sameBytes(raw.bytes, { 2, 2, 1, 6, 0, 1, 2, 0, 1, 0, expectedStateValue },
                name .. " actual State BatchFrame bytes")
        end
        local counters = row.counters
        assert(type(counters) == "table" and counters.charged == charged
            and counters.rejected >= 1
            and counters.handoffs == (if expectedStateValue == nil then 3 else 4),
            name .. " exact outbound byte debit/refusal and handoff counters")
    end

    checkCase("automatic", 46, 1, 0, 38)
    checkCase("replacement", 31, 1, 0, 38)
    checkCase("replacementAge", nil, 0, 1, 27)
    checkCase("impossible", nil, 0, 1, 27)
    checkCase("survivor", 77, 1, 1, 38)
    checkCase("destroy", nil, 0, 0, 27)
end

local function validateRgb8Color3(proof, clientCount, expectedClients)
    local sampleIndices = { 0, 1, 127, 128, 255, 256, 257 }
    assert(type(proof) == "table" and proof.probeCount == 258
        and type(proof.sampleIndices) == "table" and #proof.sampleIndices == #sampleIndices,
        "missing bounded RGB8 Color3 summaries")
    for position, index in sampleIndices do
        assert(proof.sampleIndices[position] == index, "RGB8 Color3 sample index order")
    end
    local rawC2S, rawS2C = proof.rawC2S, proof.rawS2C
    assert(type(rawC2S) == "table" and rawC2S.format == 1 and rawC2S.endpoint == 1
        and rawC2S.eventId == 1 and rawC2S.length == 8
        and type(rawS2C) == "table" and rawS2C.format == 1 and rawS2C.endpoint == 2
        and rawS2C.eventId == 2 and rawS2C.length == 8,
        "RGB8 Color3 raw frame formats and endpoints")

    local function validateDirection(summary, label)
        assert(type(summary) == "table" and summary.count == 258
            and summary.stableCodes == 774 and type(summary.coverage) == "table"
            and #summary.coverage == 3 and summary.coverage[1] == 256
            and summary.coverage[2] == 256 and summary.coverage[3] == 256
            and type(summary.maxQuantizationError) == "number"
            and summary.maxQuantizationError == summary.maxQuantizationError
            and summary.maxQuantizationError >= 0 and summary.maxQuantizationError <= 1 / 510 + 2 ^ -24
            and type(summary.maxConstructionError) == "number"
            and summary.maxConstructionError == summary.maxConstructionError
            and summary.maxConstructionError >= 0 and summary.maxConstructionError <= 2 ^ -24
            and type(summary.samples) == "table" and #summary.samples == #sampleIndices,
            label .. " all-code coverage and bounded full-grid summary")
        local sampledSources, maxSampleQuantizationError, maxSampleConstructionError = {}, 0, 0
        for position, index in sampleIndices do
            local row = summary.samples[position]
            local source, observed, sourceNegativeZeroR, observedNegativeZeroR, byteStart
            if index == 256 then
                assert(type(row) == "table" and #row == 13
                    and type(row[7]) == "boolean" and type(row[8]) == "boolean",
                    label .. " half-up actual source sample cardinality")
                source = { row[1], row[2], row[3] }
                observed = { row[4], row[5], row[6] }
                sourceNegativeZeroR, observedNegativeZeroR, byteStart = row[7], row[8], 9
            else
                assert(type(row) == "table" and #row == 10
                    and type(row[4]) == "boolean" and type(row[5]) == "boolean",
                    label .. " compact actual sample cardinality")
                source = if index < 256
                    then { index / 255, (255 - index) / 255, ((index + 1) % 256) / 255 }
                    else { 0, 0.5, 1 }
                observed = { row[1], row[2], row[3] }
                sourceNegativeZeroR, observedNegativeZeroR, byteStart = row[4], row[5], 6
            end
            local codes = table.create(3)
            for channel = 1, 3 do
                local sourceValue, observedValue = source[channel], observed[channel]
                assert(type(sourceValue) == "number" and sourceValue == sourceValue
                    and sourceValue ~= math.huge and sourceValue ~= -math.huge
                    and sourceValue >= 0 and sourceValue <= 1,
                    label .. " finite native source component")
                assert(type(observedValue) == "number" and observedValue == observedValue
                    and observedValue ~= math.huge and observedValue ~= -math.huge
                    and observedValue >= 0 and observedValue <= 1,
                    label .. " finite decoded component")
                local code = math.floor(sourceValue * 255 + 0.5)
                codes[channel] = code
                local canonical = code / 255
                local quantizationError = math.abs(sourceValue - canonical)
                local constructionError = math.abs(observedValue - canonical)
                assert(quantizationError <= 1 / 510 + 2 ^ -24,
                    label .. " source quantization allowance")
                assert(constructionError <= 2 ^ -24
                    and math.floor(observedValue * 255 + 0.5) == code,
                    label .. " decoded construction allowance and code stability")
                if code == 0 then
                    assert(observedValue == 0 and 1 / observedValue == math.huge,
                        label .. " decoded positive zero")
                end
                maxSampleQuantizationError = math.max(maxSampleQuantizationError, quantizationError)
                maxSampleConstructionError = math.max(maxSampleConstructionError, constructionError)
            end
            assert(observedNegativeZeroR == false and sourceNegativeZeroR == (index == 257),
                label .. " source negative-zero and decoded positive-zero observations")
            if index < 256 then
                assert(codes[1] == index and codes[2] == 255 - index
                    and codes[3] == (index + 1) % 256,
                    label .. " distinct RGB channel order")
            elseif index == 256 then
                local midpoints = { 12.5, 127.5, 254.5 }
                for channel, midpoint in midpoints do
                    local scaled = source[channel] * 255
                    assert(scaled >= midpoint + 1 / 8192 and scaled <= midpoint + 1 / 2048,
                        label .. " half-up source immediately above midpoint")
                end
                assert(codes[1] == 13 and codes[2] == 128 and codes[3] == 255,
                    label .. " half-up midpoint codes")
            else
                assert(source[1] == 0 and source[2] == 0.5 and source[3] == 1
                    and codes[1] == 0 and codes[2] == 128 and codes[3] == 255,
                    label .. " signed-zero source and companion endpoint codes")
            end
            assert(row[byteStart] == index % 256 and row[byteStart + 1] == math.floor(index / 256)
                and row[byteStart + 2] == codes[1] and row[byteStart + 3] == codes[2]
                and row[byteStart + 4] == codes[3],
                label .. " actual handoff index and RGB bytes")
            sampledSources[position] = { source = source, negativeZeroR = sourceNegativeZeroR }
        end
        assert(summary.maxQuantizationError + 2 ^ -24 >= maxSampleQuantizationError
            and summary.maxConstructionError + 2 ^ -24 >= maxSampleConstructionError,
            label .. " full-grid error summaries include actual samples")
        return sampledSources
    end

    assert(type(proof.clients) == "table" and #proof.clients == clientCount,
        "RGB8 Color3 client report count")
    local seen = {}
    for _, entry in proof.clients do
        assert(type(entry) == "table" and validPlayerId(entry.client) and expectedClients[entry.client]
            and not seen[entry.client], "RGB8 Color3 actual Player identity")
        seen[entry.client] = true
        local inputSources = validateDirection(entry.c2s, "RGB8 Color3 C2S")
        local outputSources = validateDirection(entry.s2c, "RGB8 Color3 S2C")
        for position = 6, 7 do
            for channel = 1, 3 do
                assert(math.abs(inputSources[position].source[channel] - outputSources[position].source[channel])
                    <= 2 ^ -24, "RGB8 Color3 native source agreement in both directions")
            end
            assert(inputSources[position].negativeZeroR == outputSources[position].negativeZeroR,
                "RGB8 Color3 signed-zero source agreement in both directions")
        end
    end
    for id in expectedClients do assert(seen[id], "RGB8 Color3 missing actual Player") end
    assert(proof.inputHandlers == 258 * clientCount, "RGB8 Color3 C2S callback cardinality")

    local malformed = proof.malformed
    assert(type(malformed) == "table" and malformed.handlers == 0
        and malformed.perPlayerByteCapacity == 8 and malformed.aggregateByteCapacity == 8 * clientCount
        and malformed.received == 2 * clientCount and malformed.invalidPayload == clientCount
        and malformed.perPlayerBytes == clientCount and malformed.aggregateBytes == 0
        and malformed.inputInvalidPayload == clientCount and malformed.inputDispatched == 0
        and type(malformed.frame) == "table" and malformed.frame.endpoint == 1
        and malformed.frame.eventId == 1 and malformed.frame.format == 1
        and malformed.frame.truncatedLength == 7 and malformed.frame.overBudgetLength == 8
        and type(malformed.clients) == "table" and #malformed.clients == clientCount,
        "RGB8 Color3 malformed byte charge and no callback")
    local malformedSeen = {}
    for _, client in malformed.clients do
        assert(validPlayerId(client.client) and seen[client.client] and not malformedSeen[client.client]
            and type(client.truncated) == "table" and #client.truncated == 4
            and type(client.overBudget) == "table" and #client.overBudget == 5,
            "RGB8 Color3 malformed actual Player/raw cardinality")
        malformedSeen[client.client] = true
        local truncated, overBudget = client.truncated, client.overBudget
        assert(truncated[1] == 0 and truncated[2] == 1 and truncated[3] == 0 and truncated[4] == 127,
            "RGB8 Color3 truncated ingress body")
        assert(overBudget[1] == 0 and overBudget[2] == 0 and overBudget[3] == 0
            and overBudget[4] == 255 and overBudget[5] == 0,
            "RGB8 Color3 post-malformed admission probe")
    end
end

local function validateCompetitive(proof)
    local function exactKeys(value, keys, label)
        assert(type(value) == "table", label .. " table")
        local seen, count, expectedCount = {}, 0, 0
        for key in value do
            assert(keys[key] == true, label .. " unexpected field " .. tostring(key))
            seen[key] = true
            count += 1
        end
        for key in keys do
            expectedCount += 1
            assert(seen[key], label .. " missing field " .. tostring(key))
        end
        assert(count == expectedCount, label .. " exact field count")
    end
    local function count(value, minimum, label)
        assert(type(value) == "number" and value % 1 == 0 and value >= minimum,
            label .. " bounded count")
    end

    exactKeys(proof, { c03 = true, c04 = true, c05 = true, c06 = true }, "competitive result")
    local c03 = proof.c03
    exactKeys(c03, { steps = true, clients = true, reliableFrames = true, unreliableFrames = true,
        reliableCallbacks = true, unreliableCallbacks = true, destroyedLateCalls = true }, "C03 receipt")
    assert(type(c03.steps) == "table" and #c03.steps == 6 and type(c03.clients) == "table"
        and #c03.clients == 2 and c03.reliableFrames == 6 and c03.reliableCallbacks == 80
        and c03.unreliableFrames <= 6 and c03.unreliableCallbacks <= 80 and c03.destroyedLateCalls == 0,
        "C03 bounded paced batch receipt")
    for round, selected in { 32, 32, 16 } do
        for client = 1, 2 do
            local step = c03.steps[(round - 1) * 2 + client]
            exactKeys(step, { client = true, selected = true, reliableHandoffs = true,
                unreliableHandoffs = true, logicalHandoffs = true, pendingRecords = true }, "C03 step")
            local expectedPending = 80 - (if round == 1 then 32 elseif round == 2 then 64 else 80)
            assert(step.client == client and step.selected == selected and step.reliableHandoffs == 1
                and step.unreliableHandoffs == 1 and step.logicalHandoffs == selected
                and step.pendingRecords == expectedPending,
                "C03 one bounded paced round per due step")
        end
    end
    local expectedRows = { 16, 16, 8 }
    for client, entry in c03.clients do
        exactKeys(entry, { client = true, reliableCallbacks = true, reliableFirst = true, reliableLast = true,
            reliableFrames = true, unreliableCallbacks = true, unreliableFrames = true, destroy = true }, "C03 client")
        assert(entry.client == client and entry.reliableCallbacks == 40 and entry.reliableFirst == 1
            and entry.reliableLast == 40 and type(entry.reliableFrames) == "table"
            and #entry.reliableFrames == 3 and entry.unreliableCallbacks <= 40
            and type(entry.unreliableFrames) == "table" and #entry.unreliableFrames <= 3,
            "C03 client native FIFO receipt")
        for frameIndex, expected in expectedRows do
            local frame = entry.reliableFrames[frameIndex]
            exactKeys(frame, { format = true, kind = true, count = true, referenceCount = true, length = true },
                "C03 actual reliable frame")
            assert(frame.format == 5 and frame.kind == 1 and frame.count == expected
                and frame.referenceCount == expected and frame.length + frame.referenceCount * 8 <= 8_192,
                "C03 actual reliable frame cap")
        end
        exactKeys(entry.destroy, { pendingBefore = true, pendingAfter = true, state = true }, "C03 cleanup")
        assert(entry.destroy.pendingBefore == 2 and entry.destroy.pendingAfter == 0
            and entry.destroy.state == "Terminal", "C03 destroy clears late queue work")
    end

    local c04 = proof.c04
    exactKeys(c04, { atomic = true, independent = true, expiry = true, destroy = true }, "C04 receipt")
    exactKeys(c04.atomic, { ok = true, error = true, selected = true, remaining = true,
        noDebit = true, noHandoffs = true }, "C04 atomic receipt")
    assert(c04.atomic.ok == false and c04.atomic.error == "OutboundRateLimited"
        and c04.atomic.selected == 0 and c04.atomic.remaining == 2
        and c04.atomic.noDebit == true and c04.atomic.noHandoffs == true,
        "C04 atomic refusal has no partial progress")
    exactKeys(c04.independent, { firstRecipients = true, retryCleared = true, initialBudgetCharge = true,
        initialNativeHandoffs = true, retryBudgetCharge = true, retryNativeHandoffs = true, clients = true },
        "C04 independent receipt")
    assert(c04.independent.retryCleared == true and #c04.independent.firstRecipients == 2
        and c04.independent.initialBudgetCharge == 18 and c04.independent.initialNativeHandoffs == 2
        and c04.independent.retryBudgetCharge == 18 and c04.independent.retryNativeHandoffs == 2
        and #c04.independent.clients == 2, "C04 recipient retry and exact per-player charges")
    for index, recipient in c04.independent.firstRecipients do
        exactKeys(recipient, { recipient = true, selected = true, remaining = true, reliableHandoffs = true,
            unreliableHandoffs = true, logicalHandoffs = true, error = true }, "C04 recipient row")
        assert(recipient.recipient == index and recipient.selected == (if index == 1 then 0 else 2)
            and recipient.remaining == (if index == 1 then 2 else 0)
            and recipient.reliableHandoffs == (if index == 1 then 0 else 1)
            and recipient.unreliableHandoffs == (if index == 1 then 0 else 1)
            and recipient.logicalHandoffs == (if index == 1 then 0 else 2)
            and recipient.error == (if index == 1 then "OutboundRateLimited" else "none"),
            "C04 independent recipient progress")
    end
    for client, entry in c04.independent.clients do
        exactKeys(entry, { client = true, reliable = true, reliableRaw = true,
            unreliable = true, unreliableRaw = true }, "C04 client")
        assert(entry.client == client and #entry.reliable == 1 and entry.reliable[1] == 9
            and #entry.reliableRaw == 1 and entry.reliableRaw[1].kind == 2
            and entry.reliableRaw[1].eventId == 2 and #entry.unreliableRaw <= 1
            and #entry.unreliable <= 1, "C04 latest State and optional unreliable receipt")
        for _, frame in entry.unreliableRaw do
            assert(frame.kind == 2 and frame.eventId == 3 and #entry.unreliable == 1
                and entry.unreliable[1] == 7, "C04 observed unreliable State callback")
        end
    end
    exactKeys(c04.expiry, { pendingAfterExpiry = true, lateHandoffs = true }, "C04 expiry")
    exactKeys(c04.destroy, { pendingAfterDestroy = true, lateHandoffs = true }, "C04 destroy")
    assert(c04.expiry.pendingAfterExpiry == 0 and c04.expiry.lateHandoffs == 0
        and c04.destroy.pendingAfterDestroy == 0 and c04.destroy.lateHandoffs == 0,
        "C04 expiry and destroy prevent late handoffs")

    local c05 = proof.c05
    exactKeys(c05, { clients = true, invalid = true, actualOrderedFrames = true, actualQueuedFrames = true,
        unreliableObserved = true, orderedRawObservations = true }, "C05 receipt")
    exactKeys(c05.invalid, { batchFrames = true, ordered = true, reliable = true, state = true,
        oversizedByteRefused = true, wholeFrameRejected = true, orderedRecovery = true }, "C05 invalid receipt")
    assert(c05.invalid.batchFrames == 3 and c05.invalid.ordered >= 1 and c05.invalid.ordered <= 3
        and c05.invalid.reliable == 1
        and c05.invalid.state == 1 and c05.invalid.oversizedByteRefused == true
        and c05.invalid.wholeFrameRejected == true and c05.invalid.orderedRecovery == true
        and #c05.clients == 2 and type(c05.orderedRawObservations) == "table"
        and c05.actualOrderedFrames == #c05.orderedRawObservations
        and c05.actualQueuedFrames == 9
        and c05.unreliableObserved <= 3, "C05 timestamp rejection and recovery receipts")
    local orderedInvalid, orderedRecovery = 0, false
    local orderedSequences, validOrderedCallbacks = { [1] = 0, [2] = 0 }, { [1] = 0, [2] = 0 }
    for _, frame in c05.orderedRawObservations do
        exactKeys(frame, { client = true, sequence = true, generation = true, value = true, length = true },
            "C05 observed ordered raw frame")
        assert((frame.client == 1 or frame.client == 2) and frame.generation > 0 and frame.length == 20,
            "C05 ordered raw frame keeps its client epoch and fixed shape")
        if frame.value == 3 then
            assert(frame.sequence == 1, "C05 initial ordered sequence")
            if frame.sequence > orderedSequences[frame.client] then
                orderedSequences[frame.client] = frame.sequence
                validOrderedCallbacks[frame.client] += 1
            end
        elseif frame.value == 5 then
            assert(frame.client == 1 and frame.sequence == 2 and orderedInvalid >= 1,
                "C05 recovery follows an observed hostile high sequence")
            orderedRecovery = true
            if frame.sequence > orderedSequences[frame.client] then
                orderedSequences[frame.client] = frame.sequence
                validOrderedCallbacks[frame.client] += 1
            end
        elseif frame.value == 49 then
            assert(frame.client == 1 and frame.sequence == 100, "C05 observed stale ordered probe")
            orderedInvalid += 1
        elseif frame.value == 50 then
            assert(frame.client == 1 and frame.sequence == 101, "C05 observed future ordered probe")
            orderedInvalid += 1
        else
            assert(frame.value == 51 and frame.client == 1 and frame.sequence == 102,
                "C05 observed nonfinite ordered probe")
            orderedInvalid += 1
        end
    end
    assert(orderedInvalid == c05.invalid.ordered and orderedRecovery,
        "C05 reports only observed ordered invalid probes and recovery")
    for client, entry in c05.clients do
        exactKeys(entry, { client = true, reliable = true, unreliable = true, ordered = true,
            batch = true, state = true }, "C05 client")
        assert(entry.client == client and entry.reliable == 1
            and entry.ordered == validOrderedCallbacks[client]
            and entry.batch == (if client == 1 then 2 else 1)
            and entry.state == (if client == 1 then 2 else 1),
            "C05 old/future/malformed timestamps do not call handlers")
    end

    local c06 = proof.c06
    exactKeys(c06, { control = true, server = true, clients = true, disabled = true, native = true }, "C06 receipt")
    exactKeys(c06.control, { channelReceives = true, noEndpointAttribution = true }, "C06 control")
    assert(c06.control.channelReceives >= 2 and c06.control.noEndpointAttribution == true,
        "C06 readiness/control is channel-only")
    exactKeys(c06.server, { inputValidated = true, batchPackets = true, unreliableInputPackets = true,
        unreliableInputValidated = true, rpcRequests = true, rpcReplies = true, outputHandoffs = true,
        outputRecipientBytes = true, batch = true, state = true, reports = true, postmortem = true }, "C06 server")
    assert(c06.server.inputValidated == 3 and c06.server.batchPackets == 2
        and c06.server.rpcRequests == 2 and c06.server.rpcReplies == 2
        and c06.server.outputHandoffs == 2 and c06.server.outputRecipientBytes == 33,
        "C06 exact event, RPC and recipient handoffs")
    exactKeys(c06.server.postmortem, { readable = true, stable = true, refused = true, started = true },
        "C06 server postmortem")
    assert(c06.server.postmortem.readable and c06.server.postmortem.stable
        and c06.server.postmortem.refused and c06.server.postmortem.started,
        "C06 enabled server diagnostics survive Destroy and remain stable")
    exactKeys(c06.server.batch, { packets = true, kind = true }, "C06 Batch")
    exactKeys(c06.server.state, { packets = true, kind = true }, "C06 State")
    assert(c06.server.batch.packets == 1 and c06.server.batch.kind == 1
        and c06.server.state.packets == 1 and c06.server.state.kind == 2,
        "C06 actual native Batch and State kinds")
    assert(type(c06.server.reports) == "table" and c06.server.reports.HandlerError >= 1
        and c06.server.reports.InvalidPayload >= 1, "C06 bounded refusal reports")
    assert(type(c06.clients) == "table" and #c06.clients == 2, "C06 client receipt count")
    local trafficCounterKeys = { submittedRecords = true, submittedBytes = true, sentPackets = true,
        sentRecords = true, sentBytes = true, sentRecipientBytes = true, receivedPackets = true,
        receivedBytes = true, validatedRecords = true, validatedBytes = true, unmeasuredPackets = true }
    for client, entry in c06.clients do
        exactKeys(entry, { client = true, reliable = true, batch = true, state = true, reports = true,
            unreliable = true, output = true, rpc = true, postmortem = true, invalidOutputReport = true,
            reliableChannelPacketDelta = true, reliableChannelByteDelta = true,
            localRefusalsUnreported = true }, "C06 client")
        exactKeys(entry.postmortem, { readable = true, stable = true, refused = true, started = true },
            "C06 client postmortem")
        assert(entry.postmortem.readable and entry.postmortem.stable
            and entry.postmortem.refused and entry.postmortem.started,
            "C06 enabled client diagnostics survive Destroy and remain stable")
        assert(entry.client == client and entry.reliable == (if client == 1 then 2 else 1)
            and entry.batch == 1 and entry.state == 1
            and entry.reports.InvalidPayload == 1 and entry.localRefusalsUnreported == true,
            "C06 client native callbacks and local refusal reports")
        exactKeys(entry.invalidOutputReport, { endpointId = true, channel = true, count = true },
            "C06 malformed Output report")
        assert(entry.invalidOutputReport.endpointId == 4 and entry.invalidOutputReport.channel == "Reliable"
            and entry.invalidOutputReport.count == 1 and entry.reliableChannelPacketDelta == 1
            and entry.reliableChannelByteDelta == 11,
            "C06 observed malformed Output report and exact channel receive delta")
        exactKeys(entry.output, trafficCounterKeys, "C06 output traffic row")
        exactKeys(entry.unreliable, trafficCounterKeys, "C06 unreliable input traffic row")
        exactKeys(entry.rpc, trafficCounterKeys, "C06 RPC traffic row")
        assert(entry.output.receivedPackets == (if client == 1 then 3 else 2)
            and entry.output.receivedBytes == (if client == 1 then 33 else 22)
            and entry.output.validatedRecords == (if client == 1 then 2 else 1)
            and entry.output.validatedBytes == (if client == 1 then 22 else 11)
            and entry.unreliable.submittedRecords == 1 and entry.unreliable.submittedBytes == 4
            and entry.unreliable.sentPackets == 1 and entry.unreliable.sentBytes == 4
            and entry.unreliable.sentRecipientBytes == 4
            and entry.rpc.sentPackets == 1 and entry.rpc.receivedPackets == 1,
            "C06 per-endpoint client counters")
    end
    assert(c06.server.unreliableInputPackets <= 2
        and c06.server.unreliableInputValidated == c06.server.unreliableInputPackets,
        "C06 unreliable receive counters reflect only observed native packets")
    exactKeys(c06.disabled, { trafficOmitted = true, reportsOmitted = true }, "C06 disabled options")
    assert(c06.disabled.trafficOmitted == true and c06.disabled.reportsOmitted == true,
        "C06 diagnostics stay absent by default")
    exactKeys(c06.native, { reliableC2sPackets = true, unreliableC2sPackets = true,
        rpcRequestBytes = true, rpcReplyBytes = true }, "C06 native receipt")
    assert(c06.native.reliableC2sPackets == 8 and c06.native.unreliableC2sPackets <= 2
        and #c06.native.rpcRequestBytes == 2 and #c06.native.rpcReplyBytes == 2,
        "C06 actual raw C2S and RPC native packet bounds")
    for index = 1, 2 do
        count(c06.native.rpcRequestBytes[index], 47, "C06 request frame bytes")
        count(c06.native.rpcReplyBytes[index], 47, "C06 reply frame bytes")
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
        assert(result.mode == selection.mode and result.clients == selection.clients, "wrong scenario cardinality")
        if selection.mode == "competitive" then
            validateCompetitive(result.competitive)
        elseif selection.mode == "correctness" then
            local endpointRate = result.endpointRate
            assert(type(endpointRate) == "table" and endpointRate.immediateRefusals == selection.clients
                and endpointRate.rpcRefusals == 1 and endpointRate.rpcHandlers == math.min(selection.clients, 2)
                and endpointRate.independent == 2 and endpointRate.recovered == selection.clients
                and type(endpointRate.queued) == "table" and #endpointRate.queued == 2,
                "native endpoint rate/burst/refill and RPC deadline proof")
            for kind, queuedRate in endpointRate.queued do
                assert(queuedRate.kind == kind and queuedRate.endpointRate == 2 and queuedRate.perPlayerRate == 1
                    and queuedRate.limitedHandlers == 0 and queuedRate.healthy == (if selection.clients > 1 then 1 else 0),
                    "native queued endpoint whole-frame rejection and retained charges")
            end
            local color3 = result.color3
            assert(type(color3) == "table" and color3.constructorCases == 8
                and color3.runtimes == selection.clients + 1
                and color3.nativeHandlers == selection.clients and color3.compositeHandlers == selection.clients
                and color3.rpcHandlers == selection.clients and color3.nativeOutputs == selection.clients
                and color3.compositeOutputs == selection.clients and color3.byteHandlers == selection.clients
                and color3.byteRefusals == 2 * selection.clients, "native Color3 proof summary")
            validateQueued(result, selection.clients)
            local expectedClientIds = {}
            for _, entry in result.queued.normalReports do expectedClientIds[entry.client] = true end
            validateRgb8Color3(result.rgb8Color3, selection.clients, expectedClientIds)
            assert(type(result.statePut) == "table" and result.statePut.cases == 19
                and result.statePut.nativeBuffers == true and result.statePut.rejectedExpiryPreserved == true,
                "native affected-path State Put proof")
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
            validateReadiness64(result.readiness64, selection.clients)
            validateTaggedUnion(result.taggedUnion, result.installation, selection.clients, result.readiness64.clients)
            validateNativeValues(result.nativeValues, selection.clients, result.readiness64.clients)
            validateInstanceReferences(result.instanceReferences, selection.clients, result.readiness64.clients)
            validateRpcBoundedRoutes(result.rpcBoundedRoutes, selection.clients, result.readiness64.clients)
            validateBroadcastBatching(result.broadcastBatching, selection.clients, result.readiness64.clients)
            validateQuantized(result.quantized, selection.clients, result.readiness64.clients)
            validateCompactTransport(result.compactTransport, selection.clients, result.readiness64.clients)
            validateBufferDeferral(result.bufferDeferral, selection.clients, result.readiness64.clients)
            validateStateDeferral(result.stateDeferral, result.readiness64.clients)
            validateContentBytes(result.contentBytes, selection.clients, result.readiness64.clients)
            local ordered = result.orderedUnreliable
            assert(type(ordered) == "table" and ordered.maximumFrameBytes == 900
                and ordered.stale == selection.clients * 2 + 1 and ordered.invalidPayload == selection.clients,
                "native ordered byte boundary and refusal counts")
            assert(type(ordered.restart) == "table" and validPlayerId(ordered.restart.client)
                and ordered.restart.before == 1 and ordered.restart.after == 2,
                "native ordered client restart generation")
            for _, direction in { "c2s", "s2c" } do
                local entries, seen = ordered[direction], {}
                assert(type(entries) == "table" and #entries == selection.clients,
                    "native ordered peer observations")
                for _, entry in entries do
                    assert(validPlayerId(entry.client) and not seen[entry.client], "native ordered actual peer")
                    seen[entry.client] = true
                    local target = entry.client == ordered.restart.client
                    local expectedValues = if direction == "s2c" then { "maximum", "maximum", "ten", "eleven" }
                        elseif target then { "maximum", "ten", "eleven", "maximum", "after-restart" }
                        else { "maximum", "ten", "eleven" }
                    assert(type(entry.values) == "table" and #entry.values == #expectedValues,
                        "native ordered exact handler count")
                    for index, value in expectedValues do
                        assert(entry.values[index] == value, "native ordered snapshot sequence")
                    end
                    assert(entry.raw == (if direction == "s2c" then 7 elseif target then 9 else 6),
                        "native ordered raw arrival proof")
                    if direction == "s2c" then
                        assert(entry.stale == 2 and entry.invalidPayload == 1 and entry.maximumFrameBytes == 900,
                            "native ordered client refusal counts")
                    end
                end
                assert(seen[ordered.restart.client], "native ordered restarted peer appears in both directions")
            end
            local streams = ordered.streams
            assert(type(streams) == "table" and type(streams.peers) == "table"
                and #streams.peers == selection.clients, "missing bounded native ordered stream receipt")
            assert(type(streams.coalesce) == "table" and streams.coalesce.sets == 3
                and streams.coalesce.latestValue == 0.75 and streams.coalesce.immediateCountersUnchanged == true,
                "stream Sets coalesce to the latest value after unchanged immediate counters")
            local function checkSharedPhase(phase, packetLength, label)
                assert(type(phase) == "table" and phase.broadcastHandoffs == 1 and phase.sendHandoffs == 0
                    and phase.outboundBytesCharged == packetLength * selection.clients
                    and phase.outboundByteRejected == 0, label .. " phase call and byte deltas")
            end
            local function validServerTime(value)
                return type(value) == "number" and value == value and value ~= math.huge
                    and value ~= -math.huge and value >= 0 and value <= 1e12
            end
            checkSharedPhase(streams.initialData, 24, "initial stream data")
            checkSharedPhase(streams.stopConfirmation, 24, "stream stop confirmation")
            checkSharedPhase(streams.keepalive, 24, "stream keepalive")
            assert(validServerTime(streams.stopConfirmation.lastSentTime)
                and type(streams.suppression) == "table" and streams.suppression.broadcastHandoffs == 0
                and streams.suppression.sendHandoffs == 0 and streams.suppression.outboundBytesCharged == 0
                and streams.suppression.outboundByteRejected == 0
                and type(streams.suppression.seconds) == "number" and streams.suppression.seconds >= 0.5
                and streams.suppression.seconds < 1.5 and type(streams.suppression.windowSeconds) == "number"
                and streams.suppression.windowSeconds >= 0.5
                and streams.suppression.lastSentTimeBefore == streams.stopConfirmation.lastSentTime
                and streams.suppression.lastSentTimeAfter == streams.stopConfirmation.lastSentTime
                and validServerTime(streams.keepalive.lastSentTime)
                and streams.keepalive.lastSentTime > streams.stopConfirmation.lastSentTime
                and type(streams.keepalive.sinceStopSeconds) == "number"
                and math.abs(streams.keepalive.lastSentTime - streams.stopConfirmation.lastSentTime
                    - streams.keepalive.sinceStopSeconds) <= 0.05
                and streams.keepalive.minimumIntervalSeconds == 1.25
                and streams.keepalive.sinceStopSeconds >= streams.keepalive.minimumIntervalSeconds,
                "stream suppression spans normal-rate intervals before the configured keepalive")
            assert(type(streams.clear) == "table" and streams.clear.broadcastHandoffs == 1
                and streams.clear.sendHandoffs == 0 and streams.clear.outboundBytesCharged == 20 * selection.clients
                and streams.clear.outboundByteRejected == 0
                and streams.clear.packetLength == 20 and streams.clear.idle == true
                and streams.clear.pending == false and type(streams.clear.observedClients) == "number"
                and streams.clear.observedClients >= 0 and streams.clear.observedClients <= selection.clients,
                "explicit 20-byte clear hands off and returns the stream to Idle")
            assert(type(streams.targeted) == "table" and validPlayerId(streams.targeted.client)
                and streams.targeted.client == ordered.restart.client and streams.targeted.value == -12.5
                and streams.targeted.packetLength == 24 and streams.targeted.sendHandoffs == 1
                and streams.targeted.broadcastHandoffs == 0 and streams.targeted.outboundBytesCharged == 24
                and streams.targeted.destroyed == true and streams.targeted.noLateHandoffOrCharge == true
                and type(streams.sharedCleanup) == "table" and streams.sharedCleanup.destroyed == true
                and streams.sharedCleanup.noLateHandoffOrCharge == true,
                "targeted stream calls FireClient for the selected peer and Destroy prevents late work")
            local streamCounters = streams.counters
            assert(type(streamCounters) == "table" and streamCounters.broadcastHandoffs == 4
                and streamCounters.sendHandoffs == 1 and streamCounters.outboundByteRejected == 0
                and streamCounters.sharedDataPacketLength == 24 and streamCounters.clearPacketLength == 20
                and streamCounters.targetedPacketLength == 24
                and streamCounters.sharedBytesPerRecipient == 24 * 3 + 20
                and streamCounters.targetedBytesPerRecipient == 24
                and streamCounters.outboundBytesCharged == (24 * 3 + 20) * selection.clients + 24,
                "stream handoff counts and exact byte debits match native packet lengths")
            local streamClientIds, streamTargetFound, observedClearCount = {}, false, 0
            for _, client in result.readiness64.clients do streamClientIds[client.userId] = true end
            local streamPeers = {}
            local function finite(value)
                return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
            end
            local function checkClock(serverTime, clientTime, label)
                assert(finite(serverTime) and serverTime >= 0 and serverTime <= 1e12
                    and finite(clientTime) and math.abs(serverTime - clientTime) <= 5,
                    label .. " synchronized finite server time")
            end
            for _, peer in streams.peers do
                assert(type(peer) == "table" and validPlayerId(peer.client) and streamClientIds[peer.client]
                    and not streamPeers[peer.client] and validPlayerId(peer.generation)
                    and type(peer.shared) == "table" and #peer.shared <= 16
                    and type(peer.targeted) == "table" and #peer.targeted <= 16
                    and type(peer.raw) == "table" and #peer.raw <= 16
                    and type(peer.rawCounts) == "table" and type(peer.clearObserved) == "boolean"
                    and type(peer.probe) == "table" and peer.invalidPayload == peer.probe.invalidBefore + 2,
                    "bounded stream peer identity and receipt shape")
                streamPeers[peer.client] = true
                if peer.client == streams.targeted.client then streamTargetFound = true end
                local sawSharedValue, sawClear = false, false
                for _, sample in peer.shared do
                    assert(type(sample) == "table" and type(sample.statePresent) == "boolean",
                        "stream callback sample shape")
                    checkClock(sample.serverTime, sample.clientTime, "stream callback")
                    if sample.statePresent then
                        assert(finite(sample.state) and sample.state >= -1000 and sample.state <= 1000
                            and sample.state == 0.75, "coalesced shared callback value and bounds")
                        sawSharedValue = true
                    else
                        sawClear = true
                    end
                end
                assert(sawSharedValue and peer.clearObserved == sawClear,
                    "shared latest value and best-effort Clear observation agree")
                if sawClear then observedClearCount += 1 end
                local targetSampleFound = false
                for _, sample in peer.targeted do
                    assert(type(sample) == "table" and type(sample.statePresent) == "boolean",
                        "targeted stream callback sample shape")
                    checkClock(sample.serverTime, sample.clientTime, "targeted stream callback")
                    if peer.client == streams.targeted.client then
                        assert(sample.statePresent and sample.state == -12.5,
                            "selected peer receives the targeted stream value")
                        targetSampleFound = true
                    else
                        assert(false, "non-target peer received a targeted stream callback")
                    end
                end
                if peer.client == streams.targeted.client then assert(targetSampleFound, "targeted stream positive receiver evidence") end

                local probe = peer.probe
                assert(probe.generation == 0 and type(probe.sequence) == "number"
                    and probe.sequence >= 0 and probe.sequence <= 0xffffffff and math.floor(probe.sequence) == probe.sequence
                    and probe.invalidBefore == 0 and probe.afterTimestamp == 1 and probe.afterFinalState == 2
                    and type(probe.callbacksBefore) == "number" and probe.callbacksAfterTimestamp == probe.callbacksBefore
                    and probe.callbacksAfterFinalState == probe.callbacksBefore
                    and probe.callbacksAfterRecovery == probe.callbacksBefore + 1
                    and probe.recoveryState == 0.625,
                    "malformed timestamp/final-data rejection preserves the sequence for valid recovery")
                checkClock(probe.recoveryTime, probe.recoveryClientTime, "valid stream recovery")
                local sawSharedRaw, sawTargetRaw, sawBadTimestamp, sawBadFinalState, sawRecovery = false, false, false, false, false
                for _, sample in peer.raw do
                    assert(type(sample) == "table" and sample.format == 3 and sample.eventId == sample.endpoint
                        and (sample.endpoint == 3 or sample.endpoint == 4)
                        and sample.generation == 0 and type(sample.length) == "number"
                        and type(sample.sequence) == "number" and sample.sequence >= 0
                        and sample.sequence <= 0xffffffff and math.floor(sample.sequence) == sample.sequence
                        and type(sample.statePresent) == "boolean" and finite(sample.serverTime),
                        "actual ordered stream frame header sample")
                    if sample.endpoint == 3 then
                        if sample.sequence == probe.sequence and sample.serverTime == 1_000_000_000_001 then
                            assert(sample.length == 24 and sample.statePresent and sample.state == 0.625,
                                "raw invalid timestamp probe packet")
                            sawBadTimestamp = true
                        elseif sample.sequence == probe.sequence and sample.statePresent and sample.state == 1001 then
                            assert(sample.length == 24 and sample.serverTime >= 0 and sample.serverTime <= 1e12,
                                "raw invalid final data probe packet")
                            sawBadFinalState = true
                        elseif sample.sequence == probe.sequence and sample.statePresent and sample.state == 0.625 then
                            assert(sample.length == 24 and sample.serverTime >= 0 and sample.serverTime <= 1e12,
                                "raw valid recovery packet")
                            sawRecovery = true
                        else
                            assert(sample.serverTime >= 0 and sample.serverTime <= 1e12
                                and sample.length == (if sample.statePresent then 24 else 20)
                                and (not sample.statePresent or (finite(sample.state) and sample.state >= -1000
                                    and sample.state <= 1000)), "raw shared stream value or explicit clear")
                            if sample.statePresent and sample.state == 0.75 then sawSharedRaw = true end
                        end
                    else
                        assert(peer.client == streams.targeted.client and sample.length == 24
                            and sample.statePresent and sample.state == -12.5
                            and sample.serverTime >= 0 and sample.serverTime <= 1e12,
                            "raw targeted packet is bounded and appears only for its selected peer")
                        sawTargetRaw = true
                    end
                end
                assert(sawSharedRaw and sawBadTimestamp and sawBadFinalState and sawRecovery,
                    "raw shared headers include data, malformed probes, and same-sequence recovery")
                if peer.client == streams.targeted.client then assert(sawTargetRaw, "raw targeted receiver evidence") end
            end
            assert(streamTargetFound and observedClearCount == streams.clear.observedClients,
                "stream receipt covers the selected target and reports optional clear observations honestly")
            for clientId in streamClientIds do assert(streamPeers[clientId], "missing native ordered stream peer identity") end
            local cancellation = result.handlerCancellation
            local observations = result.handlerCancellationObservations
            local owners = { "server-immediate", "server-rpc", "server-queued", "client-immediate", "client-queued" }
            local methods = { "coroutine.close", "task.cancel" }
            assert(type(cancellation) == "table" and #cancellation == #owners * #methods,
                "missing native handler cancellation matrix")
            assert(type(observations) == "table" and #observations == #owners * #methods,
                "missing raw native handler cancellation observations")
            for ownerIndex, owner in owners do
                for methodIndex, method in methods do
                    local row = (ownerIndex - 1) * #methods + methodIndex
                    local entry = cancellation[row]
                    local observation = observations[row]
                    local serverOwned = string.sub(owner, 1, 6) == "server"
                    local isRpc = owner == "server-rpc"
                    local targetFound = false
                    if type(entry) == "table" then
                        for _, client in result.readiness64.clients do
                            if client.userId == entry.targetUserId then targetFound = true break end
                        end
                    end
                    assert(type(entry) == "table" and entry.owner == owner and entry.method == method
                        and type(observation) == "table" and observation.owner == owner and observation.method == method
                        and validPlayerId(entry.targetUserId) and targetFound
                        and observation.targetUserId == entry.targetUserId and observation.threadObserved == true
                        and observation.statusBefore == "suspended" and observation.outcome == entry.outcome
                        and observation.callOk == entry.callOk and observation.returnValue == entry.returnValue
                        and observation.callError == entry.callError and observation.statusAfter == entry.statusAfter
                        and entry.threadObserved == true and entry.statusBefore == "suspended"
                        and (entry.outcome == "accepted" or entry.outcome == "refused")
                        and entry.entered == 1 and entry.continued == 0
                        and entry.inFlightAtYield == 1 and entry.inFlightAfterTermination == 1
                        and entry.inFlightAfterReplacement == 1 and entry.inFlightAfterDestroy == 0
                        and entry.busyDelta == (if serverOwned then 1 else 2)
                        and entry.receivedDelta == 2
                        and entry.endpointRateDelta == (if serverOwned then 1 else 0)
                        and entry.replacementCalls == 0 and entry.freshDispatches == 1
                        and entry.requestTimeout == (if isRpc then "RequestTimeout" else false)
                        and entry.duplicateCancelled == isRpc,
                        "native cancellation owner/method/lease/busy/cleanup proof")
                    if entry.outcome == "accepted" then
                        assert(entry.callOk and entry.statusAfter == "dead" and entry.callError == nil,
                            "accepted native termination closes the callback thread")
                        if method == "coroutine.close" then
                            assert(entry.returnValue == "true", "coroutine.close accepted the suspended callback thread")
                        else
                            assert(entry.returnValue == "nil" or entry.returnValue == "true",
                                "task.cancel returned without error for the suspended callback thread")
                        end
                    else
                        assert(not entry.callOk and entry.statusAfter == "suspended"
                            and type(entry.callError) == "string" and #entry.callError > 0
                            and entry.returnValue == entry.callError,
                            "refused native termination retains its error and suspended thread status")
                    end
                end
            end
        end
        local required = if selection.mode == "competitive" then {
            "competitive-c03-paced-batch", "competitive-c04-independent-state",
            "competitive-c05-server-time", "competitive-c06-traffic-diagnostics",
        } elseif selection.mode == "correctness" then table.clone(correctness) else {
            "hostile-per-player", "hostile-aggregate", "malformed-charged",
        }
        if selection.mode == "correctness" and selection.clients > 1 then
            table.insert(required, "transport-namespaces")
        end
        if selection.mode == "admission" and selection.clients > 1 then
            table.insert(required, "mixed-honest-budget")
        end
        assert(type(result.completed) == "table" and #result.completed == #required, "incomplete scenario")
        for nameIndex, name in required do assert(result.completed[nameIndex] == name, "missing proof: " .. name) end
        if selection.mode == "correctness" and selection.clients > 1 then
            local proof = result.transportNamespaces
            assert(type(proof) == "table" and type(proof.c2s) == "table" and type(proof.s2c) == "table",
                "missing native transport namespace proof")
            sameNumbers(proof.c2s.initial.default, { 11 })
            sameNumbers(proof.c2s.initial.game, { 21 })
            sameNumbers(proof.c2s.initial.package, { 31 })
            sameNumbers(proof.c2s.restartedGame, { 23 })
            local initial = proof.s2c.initial
            sameNumbers(initial.target.default, { 111 })
            sameNumbers(initial.target.game, { 121 })
            sameNumbers(initial.target.package, {})
            sameNumbers(initial.peer.default, {})
            sameNumbers(initial.peer.game, {})
            sameNumbers(initial.peer.package, {})
            sameNumbers(proof.s2c.survived.target.default, { 111, 112 })
            sameNumbers(proof.s2c.survived.target.package, {})
            sameNumbers(proof.s2c.survived.peer.default, {})
            sameNumbers(proof.s2c.survived.peer.package, {})
            sameNumbers(proof.s2c.restartedGame.target, { 123 })
            sameNumbers(proof.s2c.restartedGame.peer, {})
            assert(proof.readiness.default == 2 and proof.readiness.game == 2
                and proof.readiness.package == 0 and proof.readiness.restartedGame == 2,
                "namespace readiness leaked across transports")
            assert(proof.collisions.serverSameCopy == "AlreadyStarted"
                and proof.collisions.serverLoadedCopy == "RemoteOwnershipConflict"
                and proof.collisions.clientSameCopy == "AlreadyStarted"
                and proof.collisions.clientLoadedCopy == "AlreadyStarted",
                "namespace duplicate/copy collision was accepted")
            assert(proof.admission.gameInvalidPayload == 1 and proof.admission.gamePerPlayerRate == 1
                and proof.admission.gameDispatched == 1 and proof.admission.defaultPerPlayerRate == 0
                and proof.admission.packagePerPlayerRate == 0 and proof.admission.defaultDispatched == 2
                and proof.admission.packageDispatched == 2,
                "malformed ingress escaped its namespace admission budget")
            assert(proof.destroy.gameRootRemoved and proof.destroy.defaultRetained
                and proof.destroy.packageRetained and proof.destroy.liveDuplicateOwnerDestroyed
                and proof.destroy.foreignDuplicatePreserved and proof.destroy.foreignDuplicateRemoved
                and #proof.destroy.clientMarkers == 2
                and proof.destroy.clientMarkers[1] and proof.destroy.clientMarkers[2]
                and #proof.destroy.clientDisconnects == 2,
                "isolated namespace destroy affected another session or foreign root")
            for _, client in proof.destroy.clientDisconnects do
                assert(type(client) == "table" and client.state == "Disconnected"
                    and client.markerPresent == false,
                    "duplicate namespace did not autonomously disconnect its client")
            end
            assert(proof.teardown.rootsRemoved and proof.teardown.clientMarkersPrivate
                and #proof.teardown.clientMarkers == 2,
                "namespace teardown proof incomplete")
            for _, markers in proof.teardown.clientMarkers do
                assert(markers.default and markers.game and markers.package, "client namespace marker leaked")
            end
        end
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
                or type(request.body) ~= "string" or #request.body > MAXIMUM_PROOF_RESULT_BYTES
            then
                if request.method == "POST" and request.path == "/" .. launch
                    and type(request.body) == "string" and #request.body > MAXIMUM_PROOF_RESULT_BYTES then
                    print(`Rejected Studio proof result: {#request.body} bytes (limit {MAXIMUM_PROOF_RESULT_BYTES})`)
                end
                return { status = 404, body = "" }
            end
            print(`Received Studio proof result: {#request.body} bytes`)
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

Host.assertStudioIdle(process.os, process.exec)
local lease = Host.openStudioLease()
local child
local status
local launchPending = false
local ok, failure = pcall(function()
    local collected = { launch = launch, results = {} }
    for index, selection in expected do
        child, status = nil, nil
        terminal = nil
        local scenarioOutput = prefix .. "-" .. tostring(index) .. ".log"
        fs.writeFile(scriptPath, bootstrap(selection), { overwrite = index > 1 })
        Host.assertStudioIdle(process.os, process.exec)
        lease.beginLaunch()
        launchPending = true
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
        Host.assertStudioIdle(process.os, process.exec)
        lease.confirmTeardown(true, true, true)
        launchPending = false
        child, status = nil, nil
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
local idleConfirmed = pcall(Host.assertStudioIdle, process.os, process.exec)
-- A failed process.create after beginLaunch has no handle to identify the
-- child. An idle census alone cannot prove that launch never started.
local childExitConfirmed = not killRequested and idleConfirmed
    and (if launchPending then child ~= nil and status ~= nil else child == nil or status ~= nil)
assert(childExitConfirmed, "Studio exit unconfirmed; launch files retained")
if fs.isFile(scriptPath) then fs.removeFile(scriptPath) end
if launchPending then lease.confirmTeardown(true, idleConfirmed, true) end
lease.release()
assert(ok, tostring(failure))
print((if correctnessOnly then "PASS Relay reliable events Studio correctness (2 clients): "
    elseif competitiveOnly then "PASS Relay competitive Studio checks (2 clients): "
    else "PASS Relay reliable events Studio matrix (1/2 correctness; 1/4/8 admission): ") .. resultPath)
