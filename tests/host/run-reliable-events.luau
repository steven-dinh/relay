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
    "rpc-results-deadline-cancel", "bounded-batch-handler-starts", "listener-readiness-claims", "native-state-put-expiry", "server-listener-error-yield",
    "mismatch-loss-timeout", "transport-mutation-contamination", "cleanup-100-cycles",
    "string-overlong-per-player-charged", "string-overlong-aggregate-charged",
    "malformed-composite-charged",
    "per-endpoint-rate-burst",
    "color3-native-values",
    "tagged-union-native-values",
    "full-width-readiness-64", "content-byte-admission",
    "handler-cancellation-contract",
    "ordered-unreliable-native",
    "native-roblox-values",
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
        "tween-invalid-easing-style", "tween-invalid-easing-direction", "tween-invalid-reverses",
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
        if selection.mode == "correctness" then
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
    else "PASS Relay reliable events Studio matrix (1/2 correctness; 1/4/8 admission): ") .. resultPath)
