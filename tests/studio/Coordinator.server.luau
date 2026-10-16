local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Relay = require(ReplicatedStorage.Relay)
local Fixture = require(ReplicatedStorage.RelayProofDefinition)
local proveStatePut = require(ReplicatedStorage.RelayProofStatePut)
local control = ReplicatedStorage.RelayProofControl
local readyPlayers = {}
local readyConnection = ReplicatedStorage.RelayProofReady.OnServerEvent:Connect(function(player)
    readyPlayers[player] = true
end)
local session
local inputConnection
local rpcDelayConnection
local queuedInputConnection
local roster
local deliveries = {}
local unreliableDeliveries = {}
local unreliableFailure
local compositeDeliveries = {}
local compositeHandlerCalls = {}
local unreliableCompositeDeliveries = {}
local compositeUnreliableFailure
local completed = {}
local cframeDiagnostics
local unreliableDiagnostics
local rpcDelayEntered = 0
local rpcInspectCalls = 0
local endpointRateDiagnostics
local color3Diagnostics
local queuedInputValues = {}
local queuedUnreliableValues = {}
local queuedIndependentValues = {}
local queuedStateValues = {}
local queuedImmediateValues = {}
local queuedYieldCompleted = {}
local queuedStartOrder = {}
local queuedFrames = { Reliable = {}, Unreliable = {} }
local queuedFrameConnections = {}
local queuedDiagnostics
local statePutDiagnostics
local readiness64Diagnostics
local contentByteDiagnostics
local handlerCancellationDiagnostics
local handlerCancellationObservations = {}
local readiness64Phase = "initial"
local BatchFrame = require(ReplicatedStorage.Relay.internal.BatchFrame)

local function waitFor(predicate, label, timeoutSeconds)
    local deadline = os.clock() + (timeoutSeconds or 30)
    repeat
        if predicate() then return end
        task.wait(0.03)
    until os.clock() >= deadline
    error("timed out: " .. (if type(label) == "function" then label() else label))
end

local function command(player, name, argument)
    local done, result = false, nil
    local isRpc = string.sub(name, 1, 4) == "rpc-"
    if isRpc then print("Relay proof command begin", name, player.Name) end
    task.spawn(function()
        result = table.pack(pcall(control.InvokeClient, control, player, name, argument))
        done = true
    end)
    waitFor(function() return done end, "client command " .. name .. " for " .. player.Name)
    assert(result[1], result[2])
    if isRpc then print("Relay proof command end", name, player.Name) end
    return table.unpack(result, 2, result.n)
end

local function all(name, argument)
    for _, player in roster do assert(command(player, name, argument)) end
end

local function create(capacity, aggregate, refill, endpointRates)
    if session then session:Destroy() end
    assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "owned root leaked")
    -- The test coordinator, not Relay, orders replication between generations.
    -- Old sessions are one-shot and must never adopt a replacement transport.
    all("absent")
    table.clear(deliveries)
    table.clear(unreliableDeliveries)
    table.clear(compositeDeliveries)
    table.clear(compositeHandlerCalls)
    table.clear(unreliableCompositeDeliveries)
    unreliableFailure = nil
    compositeUnreliableFailure = nil
    rpcDelayEntered = 0
    rpcInspectCalls = 0
    local created, failure = Relay.createServer(Fixture.create(), {
        inboundRate = {
            perPlayer = { capacity = capacity or 128, refillPerSecond = refill or 128 },
            aggregate = { capacity = aggregate or 1024, refillPerSecond = refill or 1024 },
            endpoints = endpointRates,
        },
    })
    if not created then
        error("createServer: " .. tostring(failure.code) .. ": " .. tostring(failure.message), 2)
    end
    session = created
    inputConnection = assert(session.events.Input:Connect(function(player, ...)
        assert(player.Parent == Players, "engine supplied current player")
        local sequence = Fixture.check(...)
        deliveries[player] = deliveries[player] or {}
        table.insert(deliveries[player], sequence)
    end))
    assert(session.events.UnreliableInput:Connect(function(player, sampleId, value, enabled, ...)
        local ok, checkedId, checkedValue, checkedEnabled = pcall(Fixture.checkUnreliable, sampleId, value, enabled, ...)
        if not ok then unreliableFailure = tostring(checkedId) return end
        if checkedId > Fixture.unreliableSampleCount then
            unreliableFailure = "C2S unreliable sample ID outside its range"
            return
        end
        local samples = unreliableDeliveries[player]
        if samples == nil then samples = {} unreliableDeliveries[player] = samples end
        samples[checkedId] = { sampleId = checkedId, value = checkedValue, enabled = checkedEnabled }
    end))
    assert(session.events.CompositeInput:Connect(function(player, ...)
        compositeHandlerCalls[player] = (compositeHandlerCalls[player] or 0) + 1
        local sequence, ticket = Fixture.checkComposed(...)
        local samples = compositeDeliveries[player]
        if samples == nil then samples = {} compositeDeliveries[player] = samples end
        table.insert(samples, { sequence = sequence, ticket = ticket })
    end))
    assert(session.events.UnreliableCompositeInput:Connect(function(player, ...)
        local ok, sequence, ticket = pcall(Fixture.checkComposed, ...)
        if not ok then compositeUnreliableFailure = tostring(sequence) return end
        if sequence > Fixture.composedAttemptCount then
            compositeUnreliableFailure = "C2S composed unreliable sample ID outside its range"
            return
        end
        local samples = unreliableCompositeDeliveries[player]
        if samples == nil then samples = {} unreliableCompositeDeliveries[player] = samples end
        table.insert(samples, { sequence = sequence, ticket = ticket })
    end))
    assert(session.requests.Inspect:Connect(function(player, sequence)
        assert(player.Parent == Players, "RPC authoritative Player")
        rpcInspectCalls += 1
        return { sequence = sequence, owner = player.Name }
    end))
    assert(session.requests.Optional:Connect(function(_player, present)
        if present then return false end
        return nil
    end))
    rpcDelayConnection = assert(session.requests.Delay:Connect(function(_player, seconds)
        rpcDelayEntered += 1
        task.wait(seconds)
        return 7
    end))
    assert(session.requests.Failure:Connect(function(_player, invalidReturn)
        if invalidReturn then return "invalid" end
        error("deliberate trusted RPC handler failure")
    end))
    assert(session:Start())
    assert(ReplicatedStorage.RelayRemotes.Unreliable.ClassName == "UnreliableRemoteEvent",
        "native unreliable remote class")
    return session
end

local function count(player)
    return if deliveries[player] then #deliveries[player] else 0
end

local function mark(name)
    table.insert(completed, name)
    print("Relay proof checkpoint", name)
end

local function captureSamples(capture, firstSample, lastSample)
    assert(unreliableFailure == nil, "unreliable C2S validation: " .. tostring(unreliableFailure))
    local samples = {}
    for _, tuple in capture do
        local checkedId, value, enabled = Fixture.checkUnreliable(
            tuple.sampleId, tuple.value, tuple.enabled, Fixture.unreliablePadding)
        if checkedId >= firstSample and checkedId <= lastSample then
            table.insert(samples, { sampleId = checkedId, value = value, enabled = enabled })
        end
    end
    table.sort(samples, function(left, right) return left.sampleId < right.sampleId end)
    return samples
end

local function unreliableCorrectness()
    local count = Fixture.unreliableSampleCount
    local before = session:GetDiagnostics().counters
    local oversized = Fixture.unreliablePadding .. "x"
    local sent, problem = session.events.UnreliableState:Send(roster[1], 1, 257, false, oversized)
    assert(not sent and problem.code == "InvalidPayload", "oversized primitive unreliable target rejects")
    sent, problem = session.events.UnreliableState:Broadcast(1, 257, false, oversized)
    assert(not sent and problem.code == "InvalidPayload"
        and session:GetDiagnostics().counters.sendHandoffs == before.sendHandoffs
        and session:GetDiagnostics().counters.broadcastHandoffs == before.broadcastHandoffs,
        "oversized primitive unreliable sends do not hand off")
    all("unreliable-send")
    waitFor(function()
        for _, player in roster do
            if #captureSamples(unreliableDeliveries[player] or {}, 1, count) == 0 then return false end
        end
        return true
    end, "unreliable C2S bounded samples; zero observations are inconclusive", 8)

    for sampleId = count + 1, count * 2 do
        assert(session.events.UnreliableState:Send(roster[1], Fixture.unreliableValues(sampleId)))
    end
    waitFor(function()
        return #captureSamples(command(roster[1], "unreliable-read"), count + 1, count * 2) > 0
    end, "unreliable targeted S2C bounded samples; zero observations are inconclusive", 8)

    for sampleId = count * 2 + 1, count * 3 do
        assert(session.events.UnreliableState:Broadcast(Fixture.unreliableValues(sampleId)))
    end
    waitFor(function()
        for _, player in roster do
            if #captureSamples(command(player, "unreliable-read"), count * 2 + 1, count * 3) == 0 then return false end
        end
        return true
    end, "unreliable broadcast S2C bounded samples; zero observations are inconclusive", 8)
    task.wait(0.3)

    unreliableDiagnostics = { sampleCount = count, c2s = {}, targeted = {}, broadcast = {} }
    for index, player in roster do
        local c2s = captureSamples(unreliableDeliveries[player] or {}, 1, count)
        local received = command(player, "unreliable-read")
        local targeted = captureSamples(received, count + 1, count * 2)
        local broadcast = captureSamples(received, count * 2 + 1, count * 3)
        assert(#c2s > 0, "unreliable C2S recipient delivery")
        assert((#targeted > 0) == (index == 1), "unreliable targeted audience")
        assert(#broadcast > 0, "unreliable broadcast audience")
        table.insert(unreliableDiagnostics.c2s, { client = player.UserId, samples = c2s })
        table.insert(unreliableDiagnostics.targeted, { client = player.UserId, targeted = index == 1, samples = targeted })
        table.insert(unreliableDiagnostics.broadcast, { client = player.UserId, samples = broadcast })
    end
    mark("unreliable-routing-audience")
end

local function compositeCorrectness()
    all("composed-send")
    waitFor(function()
        for _, player in roster do
            if not compositeDeliveries[player] or #compositeDeliveries[player] ~= 2 then return false end
        end
        return true
    end, "composed C2S delivery")
    for _, player in roster do
        local samples = compositeDeliveries[player]
        assert(compositeHandlerCalls[player] == 2, "composed C2S handler call count")
        assert(samples[1].sequence == 1 and samples[1].ticket == nil
            and samples[2].sequence == 2 and samples[2].ticket == 2, "composed C2S values and trailing optional")
    end

    for sequence = 3, 4 do assert(session.events.CompositeState:Send(roster[1], Fixture.composedValues(sequence))) end
    task.wait(0.3)
    for index, player in roster do
        local samples = command(player, "composed-read")
        assert(#samples == (if index == 1 then 2 else 0), "composed targeted audience")
        if index == 1 then
            assert(samples[1].sequence == 3 and samples[1].ticket == nil
                and samples[2].sequence == 4 and samples[2].ticket == 4, "composed targeted values")
        end
    end

    for sequence = 5, 6 do assert(session.events.CompositeState:Broadcast(Fixture.composedValues(sequence))) end
    task.wait(0.3)
    for index, player in roster do
        local samples = command(player, "composed-read")
        assert(#samples == (if index == 1 then 4 else 2), "composed broadcast audience")
        assert(samples[#samples - 1].sequence == 5 and samples[#samples].sequence == 6,
            "composed broadcast values")
    end

    all("unreliable-composed-send")
    waitFor(function()
        assert(compositeUnreliableFailure == nil, "composed unreliable C2S validation: " .. tostring(compositeUnreliableFailure))
        for _, player in roster do
            local samples = unreliableCompositeDeliveries[player] or {}
            if #samples == 0 then return false end
        end
        return true
    end, "bounded unreliable composed C2S attempts; zero observations are inconclusive", 8)
    for _, player in roster do
        local samples = unreliableCompositeDeliveries[player] or {}
        assert(#samples > 0 and #samples <= Fixture.composedAttemptCount, "bounded composed C2S observations")
    end

    local function countRange(samples, firstSequence, lastSequence)
        local count = 0
        for _, sample in samples do
            if sample.sequence >= firstSequence and sample.sequence <= lastSequence then count += 1 end
        end
        return count
    end

    for sequence = Fixture.composedAttemptCount + 1, Fixture.composedAttemptCount * 2 do
        assert(session.events.UnreliableCompositeState:Send(roster[1], Fixture.composedValues(sequence)))
    end
    waitFor(function()
        return countRange(command(roster[1], "unreliable-composed-read"),
            Fixture.composedAttemptCount + 1, Fixture.composedAttemptCount * 2) > 0
    end, "bounded unreliable composed targeted S2C attempts; zero observations are inconclusive", 8)

    for sequence = Fixture.composedAttemptCount * 2 + 1, Fixture.composedAttemptCount * 3 do
        assert(session.events.UnreliableCompositeState:Broadcast(Fixture.composedValues(sequence)))
    end
    waitFor(function()
        for _, player in roster do
            if countRange(command(player, "unreliable-composed-read"),
                Fixture.composedAttemptCount * 2 + 1, Fixture.composedAttemptCount * 3) == 0 then return false end
        end
        return true
    end, "bounded unreliable composed broadcast S2C attempts; zero observations are inconclusive", 8)
    task.wait(0.3)

    for index, player in roster do
        local samples = command(player, "unreliable-composed-read")
        local targeted = countRange(samples, Fixture.composedAttemptCount + 1, Fixture.composedAttemptCount * 2)
        local broadcast = countRange(samples, Fixture.composedAttemptCount * 2 + 1, Fixture.composedAttemptCount * 3)
        assert(#samples <= Fixture.composedAttemptCount * 2, "bounded composed unreliable S2C observations")
        for _, sample in samples do
            assert(type(sample.sequence) == "number" and sample.sequence % 1 == 0
                and sample.sequence > Fixture.composedAttemptCount and sample.sequence <= Fixture.composedAttemptCount * 3,
                "composed unreliable S2C sample range")
        end
        assert((targeted > 0) == (index == 1), "composed unreliable targeted audience")
        assert(broadcast > 0, "composed unreliable broadcast audience")
    end
    mark("composable-native-values")
end

local function queuedFrameObserver(channel, remote, limit)
    table.insert(queuedFrameConnections, remote.OnServerEvent:Connect(function(player, endpointId, ...)
        if endpointId ~= 0 or select("#", ...) ~= 1 then return end
        local packet = ...
        local header = BatchFrame.header(packet, limit)
        if header == nil or #queuedFrames[channel] >= 32 then return end
        local ids, values = {}, {}
        local offset = 3
        for index = 1, header.count do
            local bodyBytes = buffer.readu16(packet, offset)
            local bodyOffset = offset + 2
            ids[index] = buffer.readu16(packet, bodyOffset + 1)
            values[index] = if bodyBytes >= 4 then buffer.readu8(packet, bodyOffset + 3) else -1
            offset = bodyOffset + bodyBytes
        end
        if offset ~= buffer.len(packet) then return end
        table.insert(queuedFrames[channel], {
            client = player.UserId,
            endpoint = endpointId,
            channel = channel,
            kind = header.kind,
            count = header.count,
            bytes = buffer.len(packet),
            ids = ids,
            values = values,
        })
    end))
end

local function queuedPlayerIds(players)
    local ids = table.create(#players)
    for _, player in players do table.insert(ids, player.UserId) end
    table.sort(ids)
    return ids
end

local function queuedReadyIds(eventName)
    local players, problem = session.events[eventName]:GetReadyPlayers()
    assert(players ~= nil and problem == nil, problem and problem.code)
    return queuedPlayerIds(players)
end

local function sameNumbers(actual, expected)
    if #actual ~= #expected then return false end
    for index, value in expected do if actual[index] ~= value then return false end end
    return true
end

local function waitQueuedReady(eventName, expected)
    local actual
    waitFor(function()
        actual = queuedReadyIds(eventName)
        return sameNumbers(actual, expected)
    end, "readiness audience " .. eventName, 10)
    return actual
end

local function queuedRead(player)
    return command(player, "queued-read")
end

local function queuedHas(values, expected)
    return table.find(values, expected) ~= nil
end

local function queuedFramesCopy()
    local output = { Reliable = {}, Unreliable = {} }
    for _, channel in { "Reliable", "Unreliable" } do
        for index, frame in queuedFrames[channel] do
            output[channel][index] = {
                client = frame.client, endpoint = frame.endpoint, channel = frame.channel,
                kind = frame.kind, count = frame.count, bytes = frame.bytes,
                ids = table.clone(frame.ids), values = table.clone(frame.values),
            }
        end
    end
    return output
end

local function findQueuedFrame(frames, client, kind, count)
    for _, frame in frames do
        if frame.client == client and frame.endpoint == 0 and frame.channel == "Reliable"
            and frame.kind == kind and frame.count == count then
            return {
                client = frame.client, endpoint = frame.endpoint, channel = frame.channel,
                kind = frame.kind, count = frame.count, bytes = frame.bytes,
                ids = table.clone(frame.ids), values = table.clone(frame.values),
            }
        end
    end
    return nil
end

local function createQueued(perPlayerCapacity, aggregateCapacity, refill, endpointRates, byteRates, cancellationTargetUserId)
    if session then session:Destroy() end
    session = nil
    assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "queued proof root leaked")
    all("absent")
    table.clear(queuedInputValues)
    table.clear(queuedUnreliableValues)
    table.clear(queuedIndependentValues)
    table.clear(queuedStateValues)
    table.clear(queuedImmediateValues)
    table.clear(queuedYieldCompleted)
    table.clear(queuedStartOrder)
    table.clear(queuedFrames.Reliable)
    table.clear(queuedFrames.Unreliable)
    for _, connection in queuedFrameConnections do connection:Disconnect() end
    table.clear(queuedFrameConnections)
    all("queued-prepare", cancellationTargetUserId)

    local created, problem = Relay.createServer(Fixture.createQueued(), {
        inboundRate = {
            perPlayer = { capacity = perPlayerCapacity or 128, refillPerSecond = refill or 128 },
            aggregate = { capacity = aggregateCapacity or 1024, refillPerSecond = refill or 1024 },
            endpoints = endpointRates,
            bytes = byteRates,
        },
    })
    assert(created ~= nil, problem and problem.message)
    session = created
    queuedInputConnection = assert(session.events.QueueInput:Connect(function(player, value)
        assert(player.Parent == Players, "queued server receives actual Player")
        local values = queuedInputValues[player]
        if values == nil then
            values = {}
            queuedInputValues[player] = values
        end
        table.insert(values, value)
        table.insert(queuedStartOrder, { client = player.UserId, event = "QueueInput", value = value })
        if value == 3 then
            task.wait(0.3)
            queuedYieldCompleted[player] = true
        end
    end))
    assert(session.events.UnreliableQueueInput:Connect(function(player, value)
        local values = queuedUnreliableValues[player]
        if values == nil then
            values = {}
            queuedUnreliableValues[player] = values
        end
        table.insert(values, value)
    end))
    assert(session.events.IndependentInput:Connect(function(player, value)
        local values = queuedIndependentValues[player]
        if values == nil then
            values = {}
            queuedIndependentValues[player] = values
        end
        table.insert(values, value)
        table.insert(queuedStartOrder, { client = player.UserId, event = "IndependentInput", value = value })
    end))
    assert(session.events.ToggleInput:Connect(function() error("malformed final Boolean reached a handler") end))
    assert(session.events.StateInput:Connect(function(player, value)
        local values = queuedStateValues[player]
        if values == nil then
            values = {}
            queuedStateValues[player] = values
        end
        table.insert(values, value)
    end))
    assert(session.events.ImmediateInput:Connect(function(player, value)
        local values = queuedImmediateValues[player]
        if values == nil then
            values = {}
            queuedImmediateValues[player] = values
        end
        table.insert(values, value)
    end))
    assert(session:Start())
    queuedFrameObserver("Reliable", ReplicatedStorage.RelayRemotes.Reliable, 8_192)
    queuedFrameObserver("Unreliable", ReplicatedStorage.RelayRemotes.Unreliable, 900)
    all("queued-start")
    return session
end

local function queuedCorrectness()
    createQueued()
    local allIds = queuedPlayerIds(roster)
    local otherIds = table.create(math.max(0, #roster - 1))
    for index, player in roster do if index ~= 1 then table.insert(otherIds, player.UserId) end end

    local readiness = {
        initial = {
            queue = waitQueuedReady("QueuePush", allIds),
            unreliable = waitQueuedReady("UnreliableQueuePush", allIds),
            once = waitQueuedReady("OncePush", allIds),
            state = waitQueuedReady("StatePush", {}),
        },
    }

    local normalReports = {}
    for index, player in roster do normalReports[index] = { client = player.UserId, report = command(player, "queued-send-normal") } end
    waitFor(function()
        for _, player in roster do
            local reliable = queuedInputValues[player] or {}
            if #reliable ~= 2 or reliable[1] ~= 1 or reliable[2] ~= 2 then return false end
        end
        return true
    end, "native FIFO accepted repeated endpoint records in order", 10)
    for _, player in roster do
        local actual, expected = queuedUnreliableValues[player] or {}, 1
        assert(#actual <= 1 and (actual[1] == nil or actual[1] == expected), "bounded native unreliable FIFO observation")
    end

    local yieldingPlayer = roster[1]
    command(yieldingPlayer, "queued-send-yield")
    waitFor(function()
        local inputs = queuedInputValues[yieldingPlayer] or {}
        local independent = queuedIndependentValues[yieldingPlayer] or {}
        return table.find(inputs, 3) ~= nil and table.find(independent, 5) ~= nil
    end, "yielding FIFO handler and independent endpoint start", 10)
    assert(queuedYieldCompleted[yieldingPlayer] ~= true, "independent record starts before yielding handler completes")
    local inputs = queuedInputValues[yieldingPlayer] or {}
    assert(table.find(inputs, 4) == nil, "same endpoint duplicate is dropped while its first handler yields")
    waitFor(function() return queuedYieldCompleted[yieldingPlayer] == true end, "yielding FIFO handler completion", 10)
    local inputDiagnostics = session:GetDiagnostics().events.QueueInput
    assert(inputDiagnostics.busy >= 1, "same endpoint yield charged the busy counter")

    local countersBefore = session:GetDiagnostics().counters
    local stateCountBefore = #(queuedStateValues[yieldingPlayer] or {})
    command(yieldingPlayer, "queued-hostile-protocol")
    waitFor(function()
        local counters = session:GetDiagnostics().counters
        return counters.received == countersBefore.received + 7
            and #(queuedStateValues[yieldingPlayer] or {}) == stateCountBefore + 2
    end, "queued hostile framing and valid State controls", 10)
    local countersAfter = session:GetDiagnostics().counters
    assert(countersAfter.invalidPayload == countersBefore.invalidPayload
        and countersAfter.invalidEndpoint == countersBefore.invalidEndpoint + 4
        and countersAfter.wrongChannel == countersBefore.wrongChannel + 1,
        "unknown kind, ID, direction, channel, and State-only kind checks")
    local stateValues = queuedStateValues[yieldingPlayer]
    assert(stateValues[stateCountBefore + 1] == 71 and stateValues[stateCountBefore + 2] == 72,
        "State capability is accepted in FIFO and State envelopes")

    readiness.disconnected = {}
    command(yieldingPlayer, "queued-readiness-disconnect")
    readiness.disconnected.queue = waitQueuedReady("QueuePush", otherIds)
    readiness.disconnected.once = waitQueuedReady("OncePush", allIds)
    readiness.reconnected = {}
    command(yieldingPlayer, "queued-readiness-connect")
    readiness.reconnected.queue = waitQueuedReady("QueuePush", allIds)
    readiness.reconnected.once = waitQueuedReady("OncePush", allIds)

    local manual, manualFailure = session:CreateBatch({ roster[1], roster[1] }, 0.03)
    assert(manual ~= nil, manualFailure and manualFailure.message or "manual queued batch creation failed")
    assert(manual.events.QueuePush:Send(50))
    local manualOk, manualFailure, manualReport = manual:Flush()
    assert(manualOk and manualFailure == nil and manualReport.selected == 1
        and manualReport.reliableHandoffs == 1 and manualReport.unreliableHandoffs == 0
        and manualReport.logicalHandoffs == 1, "manual batch deduplicates actual Player recipients")
    waitFor(function()
        for index, player in roster do
            local received = queuedRead(player).reliable
            if (queuedHas(received, 50)) ~= (index == 1) then return false end
        end
        return true
    end, "manual targeted batch audience", 10)

    local audience = table.clone(roster)
    table.insert(audience, roster[1])
    local automatic, automaticFailure = session:CreateBatch(audience, 0.03)
    assert(automatic ~= nil, automaticFailure and automaticFailure.message or "automatic queued batch creation failed")
    assert(automatic.events.QueuePush:Send(51))
    assert(automatic.events.UnreliableQueuePush:Send(52))
    local handoffsBefore = session:GetDiagnostics().counters.sendHandoffs
    waitFor(function()
        if session:GetDiagnostics().counters.sendHandoffs < handoffsBefore + #roster * 2 then return false end
        for _, player in roster do if not queuedHas(queuedRead(player).reliable, 51) then return false end end
        return true
    end, "automatic batch timer fanout", 10)
    local autoOk, autoFailure, autoReport = automatic:Flush()
    assert(autoOk and autoFailure == nil and autoReport.selected == 2
        and autoReport.reliableHandoffs == #roster and autoReport.unreliableHandoffs == #roster
        and autoReport.logicalHandoffs == #roster * 2, "automatic batch reports native local fanout")

    local onceAudience, onceProblem = session.events.OncePush:GetReadyPlayers()
    assert(onceAudience ~= nil and onceProblem == nil and #onceAudience == #roster, "Once readiness audience")
    local onceRecipients = table.clone(onceAudience)
    table.insert(onceRecipients, onceAudience[1])
    local onceBatch, onceBatchFailure = session:CreateBatch(onceRecipients, 0.03)
    assert(onceBatch ~= nil, onceBatchFailure and onceBatchFailure.message or "Once queued batch creation failed")
    assert(onceBatch.events.OncePush:Send(44))
    local onceOk, onceFailure, onceReport = onceBatch:Flush()
    assert(onceOk and onceFailure == nil and onceReport.selected == 1
        and onceReport.reliableHandoffs == #roster and onceReport.logicalHandoffs == #roster,
        "manual Once batch deduplicates a readiness audience")
    waitFor(function()
        for _, player in roster do if not queuedHas(queuedRead(player).once, 44) then return false end end
        return true
    end, "native Once handlers accepted the batch", 10)
    readiness.afterOnce = {
        once = waitQueuedReady("OncePush", {}),
        queue = waitQueuedReady("QueuePush", allIds),
    }

    local refresh = {}
    for index, player in roster do refresh[index] = { client = player.UserId, result = command(player, "queued-refresh-readiness") } end
    for _, entry in refresh do
        local result = entry.result
        assert(result.nilOk and result.nilError == nil and result.falseOk and result.falseError == nil
            and result.trueOk and result.trueError == nil, "bounded nil/false/true readiness refresh")
    end
    readiness.afterRefresh = {
        queue = waitQueuedReady("QueuePush", allIds),
        unreliable = waitQueuedReady("UnreliableQueuePush", allIds),
        once = waitQueuedReady("OncePush", {}),
    }
    command(yieldingPlayer, "queued-once-reconnect")
    readiness.replacement = waitQueuedReady("OncePush", { yieldingPlayer.UserId })

    local outboundReceipts = {}
    for _, player in roster do
        local values = queuedRead(player)
        table.insert(outboundReceipts, {
            client = player.UserId,
            reliable = values.reliable,
            unreliable = values.unreliable,
            once = values.once,
        })
    end
    local inputObservations = {}
    for _, player in roster do
        table.insert(inputObservations, {
            client = player.UserId,
            values = table.clone(queuedInputValues[player] or {}),
            unreliableValues = table.clone(queuedUnreliableValues[player] or {}),
            independentValues = table.clone(queuedIndependentValues[player] or {}),
        })
    end
    local yieldOrder = {}
    for _, entry in queuedStartOrder do
        if entry.client == yieldingPlayer.UserId and (entry.value == 3 or entry.value == 4 or entry.value == 5) then
            table.insert(yieldOrder, { event = entry.event, value = entry.value })
        end
    end
    queuedDiagnostics = {
        frames = queuedFramesCopy(),
        normalReports = normalReports,
        inputObservations = inputObservations,
        yield = { client = yieldingPlayer.UserId, order = yieldOrder, blockedValue = 4,
            completed = queuedYieldCompleted[yieldingPlayer] == true, busy = inputDiagnostics.busy },
        hostile = {
            invalidPayload = countersAfter.invalidPayload - countersBefore.invalidPayload,
            invalidEndpoint = countersAfter.invalidEndpoint - countersBefore.invalidEndpoint,
            wrongChannel = countersAfter.wrongChannel - countersBefore.wrongChannel,
            stateValues = { stateValues[stateCountBefore + 1], stateValues[stateCountBefore + 2] },
        },
        outbound = {
            manual = manualReport,
            automatic = autoReport,
            once = onceReport,
            receipts = outboundReceipts,
            refresh = refresh,
        },
        readiness = readiness,
    }

    local admission
    if #roster >= 2 then
        assert(#roster == 2, "cross-player batch admission proof requires exactly two actual Players")
        createQueued(9, 14, 0.000001)
        local budgetRosterIds = queuedPlayerIds(roster)
        waitQueuedReady("QueuePush", budgetRosterIds)
        local hostile = roster[1]
        local healthy = roster[2]
        local before = session:GetDiagnostics()
        assert(before.counters.received == 4 and before.counters.perPlayerRate == 0
            and before.counters.aggregateRate == 0,
            "two Hello/Ack handshakes leave seven per-player and ten aggregate application tokens")
        local hostileInputsBefore = #(queuedInputValues[hostile] or {})
        command(hostile, "queued-malformed-final")
        waitFor(function()
            return session:GetDiagnostics().counters.invalidPayload == before.counters.invalidPayload + 1
        end, "malformed final FIFO body charged before complete rejection", 10)
        local malformedFrame = findQueuedFrame(queuedFrames.Reliable, hostile.UserId, 1, 7)
        assert(malformedFrame ~= nil, "malformed final batch reached native endpoint 0")
        assert(#(queuedInputValues[hostile] or {}) == hostileInputsBefore
            and session:GetDiagnostics().events.ToggleInput.dispatched == 0,
            "malformed final record dispatches no earlier row")
        local afterMalformed = session:GetDiagnostics()
        local hostileSend = command(hostile, "queued-send-immediate", 77)
        assert(hostileSend.ok == true, "native immediate transport handoff")
        waitFor(function()
            return session:GetDiagnostics().counters.perPlayerRate == afterMalformed.counters.perPlayerRate + 1
        end, "hostile player logical batch charges exhaust only its bucket", 10)
        local afterHostile = session:GetDiagnostics()
        local healthyBatchReport = command(healthy, "queued-send-healthy")
        waitFor(function()
            local values = queuedInputValues[healthy] or {}
            return #values == 2 and values[1] == 41 and values[2] == 42
        end, "healthy Player uses remaining aggregate capacity", 10)
        local healthyFirst = command(healthy, "queued-send-immediate", 78)
        assert(healthyFirst.ok == true, "honest endpoint uses final aggregate token")
        waitFor(function() return #(queuedImmediateValues[healthy] or {}) == 1 end,
            "honest endpoint dispatch before aggregate exhaustion", 10)
        local aggregateBefore = session:GetDiagnostics().counters.aggregateRate
        local healthyLast = command(healthy, "queued-send-immediate", 79)
        assert(healthyLast.ok == true, "native event send is transport handoff only")
        waitFor(function()
            return session:GetDiagnostics().counters.aggregateRate == aggregateBefore + 1
        end, "aggregate capacity exhausts only after honest work", 10)
        admission = {
            exact = true,
            initialReceived = before.counters.received,
            initialPerPlayerRate = before.counters.perPlayerRate,
            initialAggregateRate = before.counters.aggregateRate,
            invalidPayload = afterMalformed.counters.invalidPayload - before.counters.invalidPayload,
            hostilePlayerRate = session:GetDiagnostics().counters.perPlayerRate - afterMalformed.counters.perPlayerRate,
            aggregateBeforeHealthy = afterHostile.counters.aggregateRate - before.counters.aggregateRate,
            healthyBatch = healthyBatchReport,
            healthyDelivered = table.clone(queuedInputValues[healthy]),
            healthyImmediate = table.clone(queuedImmediateValues[healthy]),
            aggregateRate = session:GetDiagnostics().counters.aggregateRate - before.counters.aggregateRate,
            hostileDelivered = table.clone(queuedInputValues[hostile] or {}),
            hostileImmediate = table.clone(queuedImmediateValues[hostile] or {}),
            malformedFrame = malformedFrame,
        }
    else
        local before = session:GetDiagnostics()
        local player = roster[1]
        local inputsBefore = #(queuedInputValues[player] or {})
        command(player, "queued-malformed-final")
        waitFor(function()
            return session:GetDiagnostics().counters.invalidPayload == before.counters.invalidPayload + 1
        end, "malformed final FIFO body rejection", 10)
        local malformedFrame = findQueuedFrame(queuedFrames.Reliable, player.UserId, 1, 7)
        assert(malformedFrame ~= nil, "malformed final batch reached native endpoint 0")
        assert(#(queuedInputValues[player] or {}) == inputsBefore
            and session:GetDiagnostics().events.ToggleInput.dispatched == 0,
            "malformed final record dispatches no earlier row")
        admission = { exact = false, invalidPayload = 1, delivered = table.clone(queuedInputValues[player] or {}),
            malformedFrame = malformedFrame }
    end
    queuedDiagnostics.admission = admission

    mark("bounded-batch-handler-starts")
    mark("listener-readiness-claims")
    for _, connection in queuedFrameConnections do connection:Disconnect() end
    table.clear(queuedFrameConnections)
    create()
    all("start")
end

local function endpointRateCorrectness()
    create(32, 256, 0.000001, {
        [1] = { capacity = 2, refillPerSecond = 0.5 },
        [13] = { capacity = 1, refillPerSecond = 0.000001 },
    })
    all("start")
    all("send", 3)
    waitFor(function()
        if session:GetDiagnostics().counters.endpointRate ~= #roster then return false end
        for _, player in roster do if count(player) ~= 2 then return false end end
        return true
    end, "per-player endpoint burst")
    command(roster[1], "rpc-inspect", 42)
    command(roster[1], "endpoint-rpc-timeout", 43)
    if #roster > 1 then command(roster[2], "rpc-inspect", 44) end
    assert(rpcInspectCalls == (if #roster > 1 then 2 else 1), "endpoint-limited RPC never invokes its handler")
    local independent = 0
    assert(session.events.SchemaInput:Connect(function(_player, ...)
        Fixture.checkSchema(...)
        independent += 1
    end))
    command(roster[1], "schema-send")
    waitFor(function() return independent == 2 end, "independent endpoint admission")
    task.wait(2.1)
    all("send", 1)
    waitFor(function()
        for _, player in roster do if count(player) ~= 3 then return false end end
        return true
    end, "endpoint refill recovery")
    local snapshot = session:GetDiagnostics()
    assert(snapshot.counters.endpointRate == #roster + 1 and snapshot.events.Input.endpointRate == #roster
        and snapshot.counters.perPlayerRate == 0 and snapshot.counters.aggregateRate == 0,
        "endpoint rejection attribution and shared budgets")
    endpointRateDiagnostics = {
        immediateRefusals = snapshot.events.Input.endpointRate, rpcRefusals = 1,
        rpcHandlers = rpcInspectCalls, independent = independent, recovered = #roster, queued = {},
    }
    all("destroy")
    session:Destroy()

    local readyIds = {}
    for index, player in roster do readyIds[index] = player.UserId end
    table.sort(readyIds)
    for kind = 1, 2 do
        local eventId = if kind == 1 then 1 else 5
        createQueued(5, #roster * 8, 0.000001, {
            [eventId] = { capacity = 1, refillPerSecond = 0.000001 },
        })
        waitQueuedReady("QueuePush", readyIds)
        assert(session:GetDiagnostics().counters.received == #roster * 2,
            "endpoint proof starts after Hello/Ack coarse charges")
        command(roster[1], "endpoint-queued-burst", { kind = kind, id = eventId })
        waitFor(function() return session:GetDiagnostics().counters.endpointRate == 1 end,
            "repeated queued endpoint rejects the complete frame")
        command(roster[1], "endpoint-queued-immediate", eventId)
        waitFor(function() return session:GetDiagnostics().counters.endpointRate == 2 end,
            "queued rejection retains the earlier endpoint charge")
        assert(command(roster[1], "queued-send-immediate", 78).ok)
        if #roster > 1 then assert(command(roster[2], "queued-send-immediate", 79).ok) end
        waitFor(function()
            return session:GetDiagnostics().counters.perPlayerRate == 1
                and (#roster == 1 or #(queuedImmediateValues[roster[2]] or {}) == 1)
        end, "queued endpoint rejection retains all logical coarse charges")
        task.wait()
        snapshot = session:GetDiagnostics()
        local limited = if kind == 1 then queuedInputValues else queuedStateValues
        local limitedCounters = if kind == 1 then snapshot.events.QueueInput else snapshot.events.StateInput
        assert(#(limited[roster[1]] or {}) == 0 and #(queuedImmediateValues[roster[1]] or {}) == 0
            and limitedCounters.dispatched == 0
            and snapshot.counters.endpointRate == 2 and snapshot.counters.aggregateRate == 0
            and snapshot.counters.invalidPayload == 0,
            "endpoint-limited FIFO/State has no partial callbacks or refunds")
        table.insert(endpointRateDiagnostics.queued, {
            kind = kind, endpointRate = snapshot.counters.endpointRate,
            perPlayerRate = snapshot.counters.perPlayerRate, limitedHandlers = 0,
            healthy = if #roster > 1 then #queuedImmediateValues[roster[2]] else 0,
        })
        all("destroy")
        session:Destroy()
        for _, connection in queuedFrameConnections do connection:Disconnect() end
        table.clear(queuedFrameConnections)
    end
    mark("per-endpoint-rate-burst")
end

local function color3Correctness()
    if session then session:Destroy() end
    all("absent")
    local native, composite, requests, colorFailure = 0, 0, 0, nil
    local function check(value)
        local ok, failure = pcall(Fixture.checkColor3, value)
        if not ok then colorFailure = tostring(failure) end
    end
    session = assert(Relay.createServer(Fixture.createColor3(), { inboundRate = {
        perPlayer = { capacity = 120, refillPerSecond = 60 },
        aggregate = { capacity = 960, refillPerSecond = 480 },
        bytes = { perPlayer = { capacity = 1024, refillPerSecond = 1024 },
            aggregate = { capacity = 8192, refillPerSecond = 8192 } },
    } }))
    assert(session.events.Input:Connect(function(_, value) check(value) native += 1 end))
    assert(session.events.CompositeInput:Connect(function(_, value) check(value.tint) composite += 1 end))
    assert(session.requests.Echo:Connect(function(_, value) check(value) requests += 1 return value end))
    assert(session:Start())
    for _, player in roster do assert(command(player, "color3-start") == 8, "client Color3 constructor probes") end
    all("color3-send")
    waitFor(function() return native == #roster and composite == #roster and requests == #roster end,
        "native Color3 receive/RPC")
    assert(colorFailure == nil, colorFailure)
    assert(session.events.Output:Broadcast(Fixture.color3Value()))
    assert(session.events.CompositeOutput:Broadcast({ tint = Fixture.color3Value() }))
    all("color3-read")
    local snapshot = session:GetDiagnostics()
    assert(snapshot.counters.invalidPayload == 0 and snapshot.counters.handlerErrors == 0
        and snapshot.counters.perPlayerBytes == 0 and snapshot.counters.aggregateBytes == 0,
        "native Color3 normal admission")
    color3Diagnostics = { constructorCases = Fixture.color3ProbeCount, runtimes = #roster + 1,
        nativeHandlers = native, compositeHandlers = composite, rpcHandlers = requests,
        nativeOutputs = #roster, compositeOutputs = #roster }
    all("color3-destroy")
    session:Destroy()
    all("absent")

    native, colorFailure = 0, nil
    session = assert(Relay.createServer(Fixture.createColor3(), { inboundRate = {
        perPlayer = { capacity = 120, refillPerSecond = 60 },
        aggregate = { capacity = 960, refillPerSecond = 480 },
        bytes = { perPlayer = { capacity = 15, refillPerSecond = 0.000001 },
            aggregate = { capacity = 15 * #roster, refillPerSecond = 0.000001 } },
    } }))
    assert(session.events.Input:Connect(function(_, value) check(value) native += 1 end))
    assert(session:Start())
    for _, player in roster do assert(command(player, "color3-start") == 8) end
    all("color3-byte")
    waitFor(function()
        return native == #roster and session:GetDiagnostics().counters.perPlayerBytes == 2 * #roster
    end, "native Color3 15-byte admission boundary")
    snapshot = session:GetDiagnostics()
    assert(colorFailure == nil, colorFailure)
    assert(snapshot.counters.invalidPayload == 0 and snapshot.counters.aggregateBytes == 0
        and snapshot.counters.perPlayerRate == 0 and snapshot.counters.aggregateRate == 0,
        "Color3 byte refusal precedes payload parsing")
    color3Diagnostics.byteHandlers = native
    color3Diagnostics.byteRefusals = snapshot.counters.perPlayerBytes
    all("color3-destroy")
    session:Destroy()
    mark("color3-native-values")
end

local function readiness64Snapshot()
    local others = table.create(63)
    for eventId = 1, 63 do
        table.insert(others, {
            id = eventId,
            clients = queuedReadyIds(string.format("E%02d", eventId)),
        })
    end
    return { highest = queuedReadyIds("Highest"), others = others }
end

local function readiness64AckRecord(frames, userId, phase, finalByte)
    for _, frame in frames do
        if frame.userId == userId and frame.phase == phase and frame.kind == 18 and frame.length == 90
            and frame.maskBytes ~= nil and frame.maskBytes[8] == finalByte then
            local fullPrefix = true
            for index = 1, 7 do if frame.maskBytes[index] ~= 255 then fullPrefix = false break end end
            if fullPrefix then return frame end
        end
    end
    return nil
end

local function readiness64RawRecord(frames, userId, phase, length)
    for _, frame in frames do
        if frame.userId == userId and frame.phase == phase and frame.kind == 18 and frame.length == length then
            return frame
        end
    end
    return nil
end

local function readiness64Correctness()
    if session then session:Destroy() end
    session = nil
    assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "64-endpoint proof root leaked")
    all("absent")

    local preparedByUser = {}
    for _, player in roster do
        local prepared = command(player, "readiness64-prepare")
        assert(prepared.listenerCount == 64 and prepared.highestId == 65535,
            "all 64 listeners are connected before client Start")
        preparedByUser[player.UserId] = prepared
    end

    local created, problem = Relay.createServer(Fixture.createReadiness64(), {
        inboundRate = {
            perPlayer = { capacity = 128, refillPerSecond = 0.000001 },
            aggregate = { capacity = 256, refillPerSecond = 0.000001 },
            bytes = {
                perPlayer = { capacity = 4096, refillPerSecond = 0.000001 },
                aggregate = { capacity = 32768, refillPerSecond = 0.000001 },
            },
        },
    })
    assert(created ~= nil, problem and problem.message or "64-endpoint server creation failed")
    session = created
    readiness64Phase = "initial"
    assert(session:Start())

    local frames = {}
    local reliable = ReplicatedStorage.RelayRemotes.Reliable
    local observer = reliable.OnServerEvent:Connect(function(player, endpointId, ...)
        if endpointId ~= 0 or select("#", ...) ~= 1 then return end
        local packet = ...
        if typeof(packet) ~= "buffer" or #frames >= 64 then return end
        local length = buffer.len(packet)
        local kind = if length >= 2 then buffer.readu8(packet, 1) else nil
        local frame = { userId = player.UserId, phase = readiness64Phase, length = length, kind = kind }
        if kind == 18 and length >= 90 then
            frame.maskBytes = table.create(8)
            for index = 1, 8 do frame.maskBytes[index] = buffer.readu8(packet, 81 + index) end
            if length == 90 then
                frame.rawPacket = buffer.create(90)
                buffer.copy(frame.rawPacket, 0, packet, 0, 90)
            end
        end
        table.insert(frames, frame)
    end)

    all("readiness64-start")
    local clientIds = queuedPlayerIds(roster)
    waitFor(function()
        local snapshot = readiness64Snapshot()
        if not sameNumbers(snapshot.highest, clientIds) then return false end
        for _, endpoint in snapshot.others do
            if not sameNumbers(endpoint.clients, clientIds) then return false end
        end
        for _, player in roster do
            if readiness64AckRecord(frames, player.UserId, "initial", 255) == nil then return false end
        end
        return true
    end, "64 listeners ready and full-width native Ack observed", 20)
    local readiness = { initial = readiness64Snapshot() }
    local initialAcks = {}
    for _, player in roster do
        local frame = readiness64AckRecord(frames, player.UserId, "initial", 255)
        assert(frame ~= nil and frame.length == 90 and frame.maskBytes[8] == 255,
            "native Ack carries eight full readiness bytes")
        initialAcks[player.UserId] = frame.rawPacket
    end

    local beforeMalformed = session:GetDiagnostics().counters
    readiness64Phase = "malformed"
    local malformed = command(roster[1], "readiness64-malformed", initialAcks[roster[1].UserId])
    assert(malformed.short == 89 and malformed.long == 91, "truncated and trailing full-width Ack copies")
    waitFor(function()
        local counters = session:GetDiagnostics().counters
        return counters.received == beforeMalformed.received + 2
            and counters.invalidPayload == beforeMalformed.invalidPayload + 2
            and readiness64RawRecord(frames, roster[1].UserId, "malformed", 89) ~= nil
            and readiness64RawRecord(frames, roster[1].UserId, "malformed", 91) ~= nil
    end, "malformed full-width Ack copies charged and rejected", 10)
    local afterMalformed = session:GetDiagnostics().counters
    assert(afterMalformed.perPlayerBytes == beforeMalformed.perPlayerBytes
        and afterMalformed.perPlayerRate == beforeMalformed.perPlayerRate
        and afterMalformed.aggregateRate == beforeMalformed.aggregateRate,
        "bounded malformed Ack copies are admitted to the parser")
    readiness.malformed = readiness64Snapshot()

    readiness64Phase = "disconnect"
    assert(command(roster[1], "readiness64-disconnect-high"))
    local remainingIds = if #roster > 1 then { roster[2].UserId } else {}
    waitFor(function()
        local snapshot = readiness64Snapshot()
        if not sameNumbers(snapshot.highest, remainingIds) then return false end
        for _, endpoint in snapshot.others do
            if not sameNumbers(endpoint.clients, clientIds) then return false end
        end
        return readiness64AckRecord(frames, roster[1].UserId, "disconnect", 127) ~= nil
    end, "only the highest endpoint disconnects for client one", 10)
    readiness.disconnected = readiness64Snapshot()

    readiness64Phase = "refresh"
    local refresh = command(roster[1], "readiness64-refresh")
    assert(refresh.sent and refresh.error == nil, "manual readiness refresh after disconnect")
    waitFor(function()
        return readiness64AckRecord(frames, roster[1].UserId, "refresh", 127) ~= nil
    end, "refreshed disconnected readiness mask observed", 10)
    readiness.refreshed = readiness64Snapshot()
    assert(sameNumbers(readiness.refreshed.highest, remainingIds), "refresh preserves the disconnected highest bit")

    readiness64Phase = "reconnect"
    assert(command(roster[1], "readiness64-reconnect-high"))
    waitFor(function()
        local snapshot = readiness64Snapshot()
        if not sameNumbers(snapshot.highest, clientIds) then return false end
        return readiness64AckRecord(frames, roster[1].UserId, "reconnect", 255) ~= nil
    end, "highest endpoint reconnect restores readiness", 10)
    readiness.reconnected = readiness64Snapshot()

    local sent, sendFailure = session.events.Highest:Broadcast(239)
    assert(sent, sendFailure and sendFailure.code or "highest endpoint broadcast failed")
    local clientResults = {}
    waitFor(function()
        table.clear(clientResults)
        for _, player in roster do
            local observed = command(player, "readiness64-read")
            if observed.failure ~= nil or #observed.deliveries ~= 1 then return false end
            local receipt = observed.deliveries[1]
            if receipt.id ~= 65535 or receipt.value ~= 239 then return false end
            table.insert(clientResults, {
                userId = player.UserId,
                prepared = preparedByUser[player.UserId],
                failure = observed.failure,
                deliveries = observed.deliveries,
            })
        end
        return #clientResults == #roster
    end, "native reliable delivery on ID 65535", 10)

    local ackRecords = {}
    for _, frame in frames do
        local record = { userId = frame.userId, phase = frame.phase, length = frame.length, kind = frame.kind }
        if frame.maskBytes ~= nil then record.maskBytes = table.clone(frame.maskBytes) end
        table.insert(ackRecords, record)
    end
    readiness64Diagnostics = {
        clients = clientResults,
        ackRecords = ackRecords,
        readiness = readiness,
        malformed = {
            before = { received = beforeMalformed.received, invalidPayload = beforeMalformed.invalidPayload,
                perPlayerBytes = beforeMalformed.perPlayerBytes },
            after = { received = afterMalformed.received, invalidPayload = afterMalformed.invalidPayload,
                perPlayerBytes = afterMalformed.perPlayerBytes },
        },
        listenerCount = 64,
        highestId = 65535,
    }
    readiness64Phase = "cleanup"
    all("readiness64-destroy")
    observer:Disconnect()
    session:Destroy()
    session = nil
    mark("full-width-readiness-64")
end

local function admissionCounters()
    local counters = session:GetDiagnostics().counters
    return {
        received = counters.received,
        perPlayerRate = counters.perPlayerRate,
        aggregateRate = counters.aggregateRate,
        perPlayerBytes = counters.perPlayerBytes,
        aggregateBytes = counters.aggregateBytes,
        endpointRate = counters.endpointRate,
        invalidPayload = counters.invalidPayload,
    }
end

local function contentByteCorrectness()
    if #roster ~= 2 then
        contentByteDiagnostics = { exact = false }
        mark("content-byte-admission")
        return
    end

    local function bytePolicy(capacity)
        return {
            perPlayer = { capacity = capacity, refillPerSecond = 0.000001 },
            aggregate = { capacity = capacity * 2, refillPerSecond = 0.000001 },
        }
    end

    local perPlayer, endpoint = {}, {}
    for kind = 1, 2 do
        local eventId = if kind == 1 then 1 else 5
        createQueued(4, 16, 0.000001, nil, bytePolicy(99))
        local clientIds = queuedPlayerIds(roster)
        waitQueuedReady("QueuePush", clientIds)
        local before = admissionCounters()
        assert(before.received == 4 and before.perPlayerRate == 0 and before.aggregateRate == 0
            and before.perPlayerBytes == 0 and before.aggregateBytes == 0,
            "two-client readiness charges fit before per-player byte admission")
        local hostile, healthy = roster[1], roster[2]
        command(hostile, "endpoint-queued-burst", { kind = kind, id = eventId })
        waitFor(function() return session:GetDiagnostics().counters.perPlayerBytes == 1 end,
            "15-byte repeated FIFO/State frame refused by the player's byte bucket", 10)
        local byteRefused = admissionCounters()
        local refusedFrame = findQueuedFrame(queuedFrames.Reliable, hostile.UserId, kind, 2)
        assert(refusedFrame ~= nil and refusedFrame.bytes == 15,
            "two four-byte bodies and their envelope total 15 bytes")
        assert(#(queuedInputValues[hostile] or {}) == 0 and #(queuedStateValues[hostile] or {}) == 0
            and #(queuedInputValues[healthy] or {}) == 0 and #(queuedStateValues[healthy] or {}) == 0,
            "byte refusal dispatches no partial FIFO or State rows")

        assert(command(healthy, "queued-send-immediate", 79).ok)
        waitFor(function() return #(queuedImmediateValues[healthy] or {}) == 1 end,
            "healthy Player retains independent byte capacity", 10)
        assert(command(hostile, "queued-send-immediate", 78).ok)
        waitFor(function() return #(queuedImmediateValues[hostile] or {}) == 1 end,
            "per-player coarse charge remains available after byte refusal", 10)
        assert(command(hostile, "queued-send-immediate", 77).ok)
        waitFor(function() return session:GetDiagnostics().counters.perPlayerRate == 1 end,
            "byte refusal retains the earlier coarse rate charge", 10)
        local final = admissionCounters()
        assert(#(queuedImmediateValues[hostile] or {}) == 1 and #(queuedImmediateValues[healthy] or {}) == 1
            and #(queuedInputValues[hostile] or {}) == 0 and #(queuedStateValues[hostile] or {}) == 0,
            "only healthy and permitted immediate handlers run")
        table.insert(perPlayer, {
            kind = kind, eventId = eventId, hostile = hostile.UserId, healthy = healthy.UserId,
            before = before, refused = byteRefused, final = final, frame = refusedFrame,
            handlers = { fifo = #(queuedInputValues[hostile] or {}), state = #(queuedStateValues[hostile] or {}),
                hostileImmediate = #(queuedImmediateValues[hostile] or {}),
                healthyImmediate = #(queuedImmediateValues[healthy] or {}) },
        })
        all("destroy")
        session:Destroy()
        session = nil
        for _, connection in queuedFrameConnections do connection:Disconnect() end
        table.clear(queuedFrameConnections)
    end

    for kind = 1, 2 do
        local eventId = if kind == 1 then 1 else 5
        createQueued(5, 16, 0.000001, {
            [eventId] = { capacity = 1, refillPerSecond = 0.000001 },
        }, bytePolicy(100))
        waitQueuedReady("QueuePush", queuedPlayerIds(roster))
        local before = admissionCounters()
        assert(before.received == 4 and before.perPlayerRate == 0 and before.perPlayerBytes == 0,
            "two-client readiness charges leave exactly 15 byte tokens")
        local hostile = roster[1]
        command(hostile, "endpoint-queued-burst", { kind = kind, id = eventId })
        waitFor(function() return session:GetDiagnostics().counters.endpointRate == 1 end,
            "admitted 15-byte repeated endpoint frame rejected atomically by endpoint rate", 10)
        local rateRejected = admissionCounters()
        local batchFrame = findQueuedFrame(queuedFrames.Reliable, hostile.UserId, kind, 2)
        assert(batchFrame ~= nil and batchFrame.bytes == 15,
            "endpoint-limited native frame retains its exact byte debit")
        assert(#(queuedInputValues[hostile] or {}) == 0 and #(queuedStateValues[hostile] or {}) == 0,
            "endpoint-limited frame dispatches no partial rows")
        local nativeImmediate
        local nativeImmediateFailure
        local rawConnection = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpointId, ...)
            if player ~= hostile then return end
            if nativeImmediate ~= nil or nativeImmediateFailure ~= nil then
                nativeImmediateFailure = nativeImmediateFailure or "duplicate native immediate frame"
                return
            end
            local arguments = table.pack(...)
            if endpointId ~= eventId or arguments.n ~= 1 or arguments[1] ~= 83 then
                nativeImmediateFailure = "unexpected native immediate endpoint/value/arity"
                return
            end
            nativeImmediate = {
                client = player.UserId,
                endpoint = endpointId,
                arity = arguments.n,
                value = arguments[1],
                contentBytes = 11,
            }
        end)
        assert(command(hostile, "endpoint-queued-immediate", kind))
        waitFor(function() return session:GetDiagnostics().counters.perPlayerBytes == 1 end,
            "retained 15-byte debit refuses the native immediate frame before endpoint parsing", 10)
        waitFor(function() return nativeImmediate ~= nil or nativeImmediateFailure ~= nil end,
            "native immediate endpoint/value/arity observed", 10)
        assert(nativeImmediateFailure == nil, nativeImmediateFailure or "native immediate observation failed")
        local final = admissionCounters()
        assert(final.endpointRate == 1 and final.perPlayerRate == 0
            and #(queuedInputValues[hostile] or {}) == 0 and #(queuedStateValues[hostile] or {}) == 0,
            "the byte refusal precedes endpoint parsing and leaves handlers untouched")
        rawConnection:Disconnect()
        table.insert(endpoint, {
            kind = kind, eventId = eventId, client = hostile.UserId, before = before,
            rateRejected = rateRejected, final = final, frame = batchFrame, nativeImmediate = nativeImmediate,
            handlers = { fifo = #(queuedInputValues[hostile] or {}), state = #(queuedStateValues[hostile] or {}) },
        })
        all("destroy")
        session:Destroy()
        session = nil
        for _, connection in queuedFrameConnections do connection:Disconnect() end
        table.clear(queuedFrameConnections)
    end

    contentByteDiagnostics = { exact = true, perPlayer = perPlayer, endpoint = endpoint }
    mark("content-byte-admission")
end

local function waitingHandler(state)
    return function()
        state.entered += 1
        state.thread = coroutine.running()
        task.wait(60)
        state.continued += 1
    end
end

local function terminateHandler(thread, method)
    local statusBefore = coroutine.status(thread)
    assert(statusBefore == "suspended", "callback thread must be suspended before termination")
    local result
    if method == "coroutine.close" then
        result = table.pack(pcall(coroutine.close, thread))
    else
        assert(method == "task.cancel", "unknown handler cancellation method")
        result = table.pack(pcall(task.cancel, thread))
    end
    return {
        callOk = result[1],
        returnValue = if result.n < 2 or result[2] == nil then "nil" else tostring(result[2]),
        callError = if result[1] then nil else tostring(result[2]),
        statusBefore = statusBefore,
        threadStatus = coroutine.status(thread),
    }
end

local function recordCancellationObservation(owner, method, targetUserId, termination)
    local outcome = if termination.callOk and termination.threadStatus == "dead" then "accepted"
        elseif not termination.callOk and termination.threadStatus == "suspended" then "refused"
        else "unexpected"
    termination.outcome = outcome
    termination.owner = owner
    termination.method = method
    termination.targetUserId = targetUserId
    termination.statusAfter = termination.threadStatus
    termination.threadObserved = true
    table.insert(handlerCancellationObservations, table.clone(termination))
    return termination
end

local function sendQueuePush(player, value)
    local batch, problem = session:CreateBatch({ player }, 0.05)
    assert(batch ~= nil, problem and problem.message or "cancellation FIFO batch creation failed")
    assert(batch.events.QueuePush:Send(value))
    local ok, failure = batch:Flush()
    assert(ok, failure and failure.code)
end

local function cancellationRecord(owner, method, targetUserId, statusBefore, termination, entered, continued,
    inFlightAtYield, inFlightAfterTermination, inFlightAfterReplacement, inFlightAfterDestroy,
    busyDelta, receivedDelta, endpointRateDelta, replacementCalls, freshDispatches, requestTimeout, duplicateCancelled)
    assert(entered == 1 and continued == 0, owner .. " callback must not continue")
    assert(inFlightAtYield == 1 and inFlightAfterTermination == 1 and inFlightAfterReplacement == 1,
        owner .. " lease remains owned through cancellation and replacement")
    assert(inFlightAfterDestroy == 0, owner .. " Destroy clears active accounting")
    assert(replacementCalls == 0 and freshDispatches == 1, owner .. " replacement/fresh session")
    return {
        owner = owner,
        method = method,
        targetUserId = targetUserId,
        threadObserved = true,
        statusBefore = statusBefore,
        callOk = termination.callOk,
        returnValue = termination.returnValue,
        callError = termination.callError,
        statusAfter = termination.threadStatus,
        outcome = termination.outcome,
        entered = entered,
        continued = continued,
        inFlightAtYield = inFlightAtYield,
        inFlightAfterTermination = inFlightAfterTermination,
        inFlightAfterReplacement = inFlightAfterReplacement,
        inFlightAfterDestroy = inFlightAfterDestroy,
        busyDelta = busyDelta,
        receivedDelta = receivedDelta,
        endpointRateDelta = endpointRateDelta,
        replacementCalls = replacementCalls,
        freshDispatches = freshDispatches,
        requestTimeout = requestTimeout,
        duplicateCancelled = duplicateCancelled,
    }
end

local function serverEventCancellation(owner, method)
    local queued = owner == "server-queued"
    local target = roster[1]
    local endpointRates = { [1] = { capacity = 2, refillPerSecond = 0.000001 } }
    if queued then
        createQueued(128, 1024, 128, endpointRates)
        waitQueuedReady("QueuePush", queuedPlayerIds(roster))
    else
        create(128, 1024, 128, endpointRates)
        all("start")
    end

    local state = { entered = 0, continued = 0, thread = nil }
    local replaceCalls = 0
    local listener
    if queued then
        queuedInputConnection:Disconnect()
        listener = assert(session.events.QueueInput:Connect(waitingHandler(state)))
        queuedInputConnection = listener
    else
        inputConnection:Disconnect()
        listener = assert(session.events.Input:Connect(waitingHandler(state)))
        inputConnection = listener
    end

    local function send(value)
        if queued then command(target, "cancel-queued-send", value)
        else command(target, "cancel-input-send", value) end
    end

    send(70)
    waitFor(function() return state.thread ~= nil and coroutine.status(state.thread) == "suspended" end,
        owner .. " native callback suspension", 10)
    local statusBefore = coroutine.status(state.thread)
    local atYield = session:GetDiagnostics()
    local termination = recordCancellationObservation(owner, method, target.UserId,
        terminateHandler(state.thread, method))
    task.wait(0.1)
    local afterTermination = session:GetDiagnostics()
    assert(state.entered == 1 and state.continued == 0 and afterTermination.inFlight == 1,
        owner .. " cancellation leaves its handler lease active")

    listener:Disconnect()
    if queued then
        listener = assert(session.events.QueueInput:Connect(function() replaceCalls += 1 end))
        queuedInputConnection = listener
    else
        listener = assert(session.events.Input:Connect(function() replaceCalls += 1 end))
        inputConnection = listener
    end
    local beforeRepeats = session:GetDiagnostics()
    send(71)
    waitFor(function() return session:GetDiagnostics().counters.busy > beforeRepeats.counters.busy end,
        owner .. " duplicate remains busy", 10)
    send(72)
    waitFor(function() return session:GetDiagnostics().counters.endpointRate == beforeRepeats.counters.endpointRate + 1 end,
        owner .. " busy duplicate consumes endpoint admission", 10)
    local afterRepeats = session:GetDiagnostics()
    assert(afterRepeats.inFlight == 1 and state.entered == 1 and state.continued == 0 and replaceCalls == 0,
        owner .. " busy admission does not resume or replace a cancelled handler")
    assert(afterRepeats.counters.received == beforeRepeats.counters.received + 2
        and afterRepeats.counters.busy == beforeRepeats.counters.busy + 1
        and afterRepeats.counters.endpointRate == beforeRepeats.counters.endpointRate + 1,
        owner .. " duplicate busy and endpoint-rate accounting")

    session:Destroy()
    local inFlightAfterDestroy = session:GetDiagnostics().inFlight
    task.wait(0.05)
    assert(state.continued == 0, owner .. " destroyed callback did not resume")

    local freshDispatches
    if queued then
        createQueued()
        waitQueuedReady("QueuePush", queuedPlayerIds(roster))
        command(target, "cancel-queued-send", 91)
        waitFor(function() return #(queuedInputValues[target] or {}) == 1 end, "fresh queued session dispatch", 10)
        freshDispatches = #(queuedInputValues[target] or {})
    else
        create()
        all("start")
        command(target, "send", 1)
        waitFor(function() return count(target) == 1 end, "fresh immediate session dispatch", 10)
        freshDispatches = count(target)
    end

    table.insert(handlerCancellationDiagnostics, cancellationRecord(owner, method, target.UserId, statusBefore, termination,
        state.entered, state.continued, atYield.inFlight, afterTermination.inFlight,
        afterRepeats.inFlight, inFlightAfterDestroy, afterRepeats.counters.busy - beforeRepeats.counters.busy,
        afterRepeats.counters.received - beforeRepeats.counters.received,
        afterRepeats.counters.endpointRate - beforeRepeats.counters.endpointRate,
        replaceCalls, freshDispatches, false, false))
end

local function serverRpcCancellation(method)
    local target = roster[1]
    create(128, 1024, 128, { [15] = { capacity = 2, refillPerSecond = 0.000001 } })
    all("start")
    local state = { entered = 0, continued = 0, thread = nil }
    local replacementCalls = 0
    rpcDelayConnection:Disconnect()
    rpcDelayConnection = assert(session.requests.Delay:Connect(waitingHandler(state)))
    command(target, "rpc-delay-start", { timeout = 0.6, seconds = 0.5 })
    waitFor(function() return state.thread ~= nil and coroutine.status(state.thread) == "suspended" end,
        "server RPC callback suspension", 10)
    local statusBefore = coroutine.status(state.thread)
    local atYield = session:GetDiagnostics()
    local termination = recordCancellationObservation("server-rpc", method, target.UserId,
        terminateHandler(state.thread, method))
    task.wait(0.1)
    local afterTermination = session:GetDiagnostics()
    assert(state.entered == 1 and state.continued == 0 and afterTermination.inFlight == 1,
        "server RPC cancellation leaves its handler lease active")
    command(target, "rpc-delay-await", "RequestTimeout")

    rpcDelayConnection:Disconnect()
    rpcDelayConnection = assert(session.requests.Delay:Connect(function()
        replacementCalls += 1
        return 8
    end))
    local beforeRepeats = session:GetDiagnostics()
    command(target, "rpc-delay-start", { timeout = 5, seconds = 0 })
    waitFor(function() return session:GetDiagnostics().counters.busy == beforeRepeats.counters.busy + 1 end,
        "replacement RPC request remains busy", 10)
    command(target, "rpc-delay-cancel")
    command(target, "rpc-delay-await", "Cancelled")
    local afterBusyRequest = session:GetDiagnostics()
    assert(afterBusyRequest.inFlight == 1 and replacementCalls == 0,
        "local RPC cancellation and listener replacement do not release the server lease")

    command(target, "rpc-delay-start", { timeout = 5, seconds = 0 })
    waitFor(function() return session:GetDiagnostics().counters.endpointRate == beforeRepeats.counters.endpointRate + 1 end,
        "busy RPC attempt consumes endpoint admission", 10)
    command(target, "rpc-delay-cancel")
    command(target, "rpc-delay-await", "Cancelled")
    local afterRepeats = session:GetDiagnostics()
    assert(afterRepeats.inFlight == 1 and replacementCalls == 0 and state.continued == 0,
        "RPC timeout and local cancellation leave the external handler untouched")
    assert(afterRepeats.counters.received == beforeRepeats.counters.received + 2
        and afterRepeats.counters.busy == beforeRepeats.counters.busy + 1
        and afterRepeats.counters.endpointRate == beforeRepeats.counters.endpointRate + 1,
        "RPC busy and endpoint-rate accounting")

    session:Destroy()
    local inFlightAfterDestroy = session:GetDiagnostics().inFlight
    assert(inFlightAfterDestroy == 0, "Destroy clears an externally terminated RPC lease")

    create()
    all("start")
    command(target, "rpc-delay-start", { timeout = 5, seconds = 0.05 })
    waitFor(function() return rpcDelayEntered == 1 end, "fresh RPC session handler", 10)
    command(target, "rpc-delay-await-value", 7)

    table.insert(handlerCancellationDiagnostics, cancellationRecord("server-rpc", method, target.UserId, statusBefore, termination,
        state.entered, state.continued, atYield.inFlight, afterTermination.inFlight,
        afterRepeats.inFlight, inFlightAfterDestroy, afterRepeats.counters.busy - beforeRepeats.counters.busy,
        afterRepeats.counters.received - beforeRepeats.counters.received,
        afterRepeats.counters.endpointRate - beforeRepeats.counters.endpointRate,
        replacementCalls, rpcDelayEntered, "RequestTimeout", true))
end

local function clientEventCancellation(owner, method)
    local queued = owner == "client-queued"
    local target = roster[1]
    local eventName = if queued then "QueuePush" else "State"
    if queued then
        createQueued(nil, nil, nil, nil, nil, target.UserId)
        waitQueuedReady("QueuePush", queuedPlayerIds(roster))
    else
        create()
        all("start", target.UserId)
    end

    local function send(value)
        if queued then sendQueuePush(target, value)
        else assert(session.events.State:Send(target, Fixture.values(value))) end
    end

    send(80)
    local initial
    waitFor(function()
        initial = command(target, "cancel-handler-read", eventName)
        return initial.entered == 1 and initial.threadStatus == "suspended" and initial.inFlight == 1
    end, owner .. " native callback suspension", 10)
    local termination = recordCancellationObservation(owner, method, target.UserId,
        command(target, "cancel-handler-terminate", method))
    local afterTermination = command(target, "cancel-handler-read", eventName)
    assert(termination.inFlight == 1
        and termination.continued == 0 and afterTermination.inFlight == 1,
        owner .. " cancellation leaves its receiver lease active")

    command(target, "cancel-handler-rebind", eventName)
    local beforeRepeats = command(target, "cancel-handler-read", eventName)
    send(81)
    waitFor(function()
        afterTermination = command(target, "cancel-handler-read", eventName)
        return afterTermination.busy == beforeRepeats.busy + 1
    end, owner .. " duplicate remains busy", 10)
    send(82)
    waitFor(function()
        afterTermination = command(target, "cancel-handler-read", eventName)
        return afterTermination.busy == beforeRepeats.busy + 2
    end, owner .. " repeated duplicate remains busy", 10)
    assert(afterTermination.inFlight == 1 and afterTermination.entered == 1
        and afterTermination.continued == 0 and afterTermination.replacementCalls == 0
        and afterTermination.received == beforeRepeats.received + 2,
        owner .. " duplicate deliveries do not resume or replace a cancelled handler")

    local inFlightAfterDestroy = command(target, "cancel-handler-destroy")
    assert(inFlightAfterDestroy == 0, owner .. " Destroy clears active accounting")
    command(target, "cancel-handler-fresh-start", eventName)
    if queued then waitQueuedReady("QueuePush", queuedPlayerIds(roster)) end
    send(91)
    local freshDispatches
    if queued then
        local fresh = command(target, "queued-read")
        waitFor(function()
            fresh = command(target, "queued-read")
            return #fresh.reliable == 1 and fresh.reliable[1] == 91
        end, "fresh queued client session dispatch", 10)
        freshDispatches = #fresh.reliable
    else
        local fresh = command(target, "read").received
        waitFor(function()
            fresh = command(target, "read").received
            return #fresh == 1 and fresh[1] == 91
        end, "fresh immediate client session dispatch", 10)
        freshDispatches = #fresh
    end

    table.insert(handlerCancellationDiagnostics, cancellationRecord(owner, method, target.UserId, initial.threadStatus, termination,
        afterTermination.entered, afterTermination.continued, initial.inFlight,
        termination.inFlight, afterTermination.inFlight, inFlightAfterDestroy,
        afterTermination.busy - beforeRepeats.busy, afterTermination.received - beforeRepeats.received,
        0, afterTermination.replacementCalls, freshDispatches, false, false))
end

local function handlerCancellationCorrectness()
    handlerCancellationDiagnostics = {}
    handlerCancellationObservations = {}
    for _, owner in { "server-immediate", "server-rpc", "server-queued", "client-immediate", "client-queued" } do
        for _, method in { "coroutine.close", "task.cancel" } do
            if owner == "server-rpc" then serverRpcCancellation(method)
            elseif owner == "client-immediate" or owner == "client-queued" then clientEventCancellation(owner, method)
            else serverEventCancellation(owner, method) end
        end
    end
    assert(#handlerCancellationDiagnostics == 10, "five native dispatch owners and both termination APIs")
    mark("handler-cancellation-contract")
end

local function correctness()
    create()
    all("start")
    for _, player in roster do command(player, "send", 3) end
    waitFor(function()
        for _, player in roster do if count(player) ~= 3 then return false end end
        return true
    end, "C2S ordered values")
    for _, player in roster do
        for index, sequence in deliveries[player] do assert(index == sequence, "C2S order") end
    end
    mark("c2s-values-order")

    assert(session.events.State:Send(roster[1], Fixture.values(10)))
    task.wait(0.3)
    for index, player in roster do
        local result = command(player, "read")
        assert(#result.received == (if index == 1 then 1 else 0), "target isolation")
        if index == 1 then assert(result.received[1] == 10) end
    end
    mark("target-isolation")
    assert(session.events.State:Broadcast(Fixture.values(11)))
    task.wait(0.3)
    for index, player in roster do
        local values = command(player, "read").received
        assert(#values == (if index == 1 then 2 else 1) and values[#values] == 11, "broadcast audience")
    end
    mark("broadcast-values")

    unreliableCorrectness()

    local schemaDeliveries = {}
    assert(session.events.SchemaInput:Connect(function(player, ...)
        schemaDeliveries[player] = schemaDeliveries[player] or {}
        table.insert(schemaDeliveries[player], Fixture.checkSchema(...))
    end))
    all("schema-send")
    waitFor(function()
        for _, player in roster do
            if not schemaDeliveries[player] or #schemaDeliveries[player] ~= 2 then return false end
        end
        return true
    end, "signed C2S extrema")
    for _, player in roster do
        assert(schemaDeliveries[player][1] == false and schemaDeliveries[player][2] == true, "signed C2S order")
    end
    assert(session.events.SchemaState:Send(roster[1], Fixture.schemaValues(false)))
    assert(session.events.SchemaState:Send(roster[1], Fixture.schemaValues(true)))
    task.wait(0.3)
    for index, player in roster do
        local values = command(player, "schema-read")
        assert(#values == (if index == 1 then 2 else 0), "signed target isolation")
        if index == 1 then assert(values[1] == false and values[2] == true, "signed targeted extrema") end
    end
    assert(session.events.SchemaState:Broadcast(Fixture.schemaValues(false)))
    assert(session.events.SchemaState:Broadcast(Fixture.schemaValues(true)))
    task.wait(0.3)
    for index, player in roster do
        local values = command(player, "schema-read")
        assert(#values == (if index == 1 then 4 else 2), "signed broadcast audience")
        assert(values[#values - 1] == false and values[#values] == true, "signed broadcast extrema")
    end
    mark("schema-native-values")

    compositeCorrectness()

    cframeDiagnostics = { serverSources = Fixture.poseSources(), c2s = {}, targeted = {}, broadcast = {} }
    local byPlayer = {}
    for index, player in roster do
        local entry = Fixture.poseRecord()
        entry.client, entry.sources = player.UserId, command(player, "pose-sources")
        cframeDiagnostics.c2s[index] = entry
        byPlayer[player] = entry
    end
    local poseConnection = assert(session.events.PoseInput:Connect(function(player, index, ...)
        Fixture.recordPose(byPlayer[player], "delivery", index, ...)
    end))
    local rawConnection = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, id, index, ...)
        if id == 5 and byPlayer[player] then Fixture.recordPose(byPlayer[player], "raw", index, ...) end
    end)
    all("pose-send")
    task.wait(0.3)
    for _, entry in cframeDiagnostics.c2s do Fixture.checkPoseProbe(entry, entry.sources) end
    rawConnection:Disconnect()
    poseConnection:Disconnect()

    all("pose-watch")
    for index, case in Fixture.poseCases do
        local ok, failure = session.events.PoseState:Send(roster[1], index, case.value)
        assert(ok == case.accepted, "CFrame targeted sender classification")
        if not ok then
            assert(failure.code == "InvalidPayload")
            ReplicatedStorage.RelayRemotes.Reliable:FireClient(roster[1], 6, index, case.value)
        end
    end
    task.wait(0.3)
    for index, player in roster do
        local result = command(player, "pose-read")
        if index == 1 then
            result.client = player.UserId
            cframeDiagnostics.targeted[1] = result
            Fixture.checkPoseProbe(result, cframeDiagnostics.serverSources)
        else
            assert(next(result.raw) == nil and result.rawState.count == 0 and not result.rawState.failure
                and result.deliveryState.count == 0 and not result.deliveryState.failure, "CFrame targeted raw audience")
            for _, delivered in result.delivered do assert(not delivered, "CFrame targeted Relay audience") end
        end
    end

    all("pose-watch")
    for index, case in Fixture.poseCases do
        local ok, failure = session.events.PoseState:Broadcast(index, case.value)
        assert(ok == case.accepted, "CFrame broadcast sender classification")
        if not ok then
            assert(failure.code == "InvalidPayload")
            ReplicatedStorage.RelayRemotes.Reliable:FireAllClients(6, index, case.value)
        end
    end
    task.wait(0.3)
    for index, player in roster do
        local result = command(player, "pose-read")
        result.client = player.UserId
        cframeDiagnostics.broadcast[index] = result
    end
    for _, result in cframeDiagnostics.broadcast do
        Fixture.checkPoseProbe(result, cframeDiagnostics.serverSources)
    end
    mark("cframe-native-boundaries")

    all("raw", "matrix")
    task.wait(0.3)
    for _, player in roster do assert(count(player) == 3, "malformed ingress dispatched") end
    mark("malformed-ingress")

    local compositeCallsBeforeMalformed = {}
    for _, player in roster do compositeCallsBeforeMalformed[player] = compositeHandlerCalls[player] or 0 end
    all("raw-composite", 1)
    task.wait(0.3)
    for _, player in roster do
        assert((compositeHandlerCalls[player] or 0) == compositeCallsBeforeMalformed[player],
            "malformed composite buffer entered the handler")
        assert(compositeDeliveries[player] and #compositeDeliveries[player] == 2, "malformed composite buffer dispatched")
    end
    mark("malformed-composite-buffer")

    all("disconnect")
    assert(session.events.State:Broadcast(Fixture.values(12)))
    task.wait(0.2)
    all("listen")
    assert(session.events.State:Broadcast(Fixture.values(13)))
    task.wait(0.2)
    for index, player in roster do
        local values = command(player, "read").received
        assert(#values == (if index == 1 then 3 else 2) and values[#values] == 13, "disconnect or replay")
    end
    mark("listener-disconnect")

    all("mode", "error")
    assert(session.events.State:Broadcast(Fixture.values(14)))
    task.wait(0.2)
    all("mode", "normal")
    assert(session.events.State:Broadcast(Fixture.values(15)))
    task.wait(0.2)
    all("mode", "yield")
    assert(session.events.State:Broadcast(Fixture.values(16)))
    task.wait(0.2)
    local before = {}
    for _, player in roster do before[player] = command(player, "read").entered end
    assert(session.events.State:Broadcast(Fixture.values(17)))
    task.wait(0.2)
    for _, player in roster do assert(command(player, "read").entered == before[player], "yielding handler cap") end
    all("release")
    task.wait(0.2)
    all("mode", "normal")
    assert(session.events.State:Broadcast(Fixture.values(18)))
    task.wait(0.2)
    for _, player in roster do
        local values = command(player, "read").received
        assert(values[#values] == 18 and values[#values - 1] == 16 and values[#values - 2] == 15, "handler recovery")
    end
    mark("client-listener-error-yield")

    local audienceBefore = {}
    for _, player in roster do audienceBefore[player] = #command(player, "read").received end
    local sentTo, toError, toCount = session.events.State:SendTo({ roster[1], roster[1] }, Fixture.values(19))
    assert(sentTo and toError == nil and toCount == 1, "deduplicated recipient count")
    task.wait(0.2)
    for index, player in roster do
        local values = command(player, "read").received
        assert(#values == audienceBefore[player] + (if index == 1 then 1 else 0), "recipient-list isolation")
        if index == 1 then assert(values[#values] == 19, "recipient-list values") end
    end
    local excluded, excludedError, excludedCount = session.events.State:SendExcept({ roster[1], roster[1] }, Fixture.values(20))
    assert(excluded and excludedError == nil and excludedCount == #roster - 1, "excluded recipient count")
    local empty, emptyError, emptyCount = session.events.State:SendTo({}, Fixture.values(21))
    assert(empty and emptyError == nil and emptyCount == 0, "empty audience")
    task.wait(0.2)
    for index, player in roster do
        local values = command(player, "read").received
        assert(#values == audienceBefore[player] + 1, "exclusion or empty audience")
        assert(values[#values] == (if index == 1 then 19 else 20), "exclusion values")
    end
    mark("recipient-list-exclusion")

    all("disconnect")
    all("once-listen")
    assert(session.events.State:Broadcast(Fixture.values(22)))
    task.wait(0.3)
    local onceSnapshots = {}
    for _, player in roster do onceSnapshots[player] = command(player, "diagnostics") end
    assert(session.events.State:Broadcast(Fixture.values(23)))
    task.wait(0.3)
    for _, player in roster do
        local after = command(player, "diagnostics")
        assert(after.dispatched == onceSnapshots[player].dispatched and after.noListener == onceSnapshots[player].noListener + 1,
            "native Once depletion and diagnostics")
    end
    all("listen")
    mark("once-diagnostics")

    for index, player in roster do
        assert(command(player, "rpc-inspect", index))
        command(player, "rpc-optional", false)
        command(player, "rpc-optional", true)
        command(player, "rpc-failure", false)
        command(player, "rpc-failure", true)
    end
    local delayBefore = rpcDelayEntered
    command(roster[1], "rpc-delay-start", { timeout = 0.05, seconds = 0.3 })
    waitFor(function() return rpcDelayEntered == delayBefore + 1 end, "RPC timeout handler entered")
    assert(command(roster[1], "rpc-delay-await", "RequestTimeout"))
    assert(command(roster[2] or roster[1], "rpc-inspect", 99))
    waitFor(function() return session:GetDiagnostics().inFlight == 0 end, "RPC timeout server lease completion")
    assert(command(roster[1], "rpc-delay-await", "RequestTimeout"), "late reply changed timeout")
    delayBefore = rpcDelayEntered
    command(roster[1], "rpc-delay-start", { timeout = 5, seconds = 0.3 })
    waitFor(function() return rpcDelayEntered == delayBefore + 1 end, "RPC cancellation handler entered")
    command(roster[1], "rpc-delay-cancel")
    assert(command(roster[1], "rpc-delay-await", "Cancelled"))
    waitFor(function() return session:GetDiagnostics().inFlight == 0 end, "RPC cancellation server lease completion")
    assert(command(roster[1], "rpc-delay-await", "Cancelled"), "late reply changed cancellation")
    mark("rpc-results-deadline-cancel")

    queuedCorrectness()
    statePutDiagnostics = proveStatePut()
    mark("native-state-put-expiry")

    inputConnection:Disconnect()
    local entered = 0
    local release = false
    inputConnection = assert(session.events.Input:Connect(function(_, ...)
        Fixture.check(...)
        entered += 1
        while not release do task.wait() end
    end))
    command(roster[1], "send", 1)
    waitFor(function() return entered == 1 end, "yielding server listener")
    command(roster[1], "send", 3)
    task.wait(0.2)
    assert(entered == 1, "server per-player endpoint handler cap")
    release = true
    task.wait(0.1)
    inputConnection:Disconnect()
    inputConnection = assert(session.events.Input:Connect(function()
        entered += 1
        error("deliberate trusted server handler failure")
    end))
    command(roster[1], "send", 1)
    waitFor(function() return entered == 2 end, "server handler error")
    inputConnection:Disconnect()
    inputConnection = assert(session.events.Input:Connect(function() entered += 1 end))
    command(roster[1], "send", 1)
    waitFor(function() return entered == 3 end, "server handler recovery")
    mark("server-listener-error-yield")

    all("destroy")
    all("mismatch")
    all("start")
    session:Destroy()
    task.wait(0.3)
    all("lost")
    all("destroy")
    all("timeout")
    mark("mismatch-loss-timeout")

    -- Exercise each real Instance mutation independently; fresh clients must bind
    -- to the next generation while the old session stays terminal.
    for _, mutation in { "root-name", "remote-name", "descriptor", "extra-child", "remote-destroy", "unreliable-remote-name", "unreliable-remote-destroy" } do
        create()
        all("start")
        local owned = ReplicatedStorage.RelayRemotes
        local foreign
        if mutation == "root-name" then owned.Name = "MovedRelayProof"
        elseif mutation == "remote-name" then owned.Reliable.Name = "MovedReliable"
        elseif mutation == "descriptor" then owned.Definition.Value = "incompatible"
        elseif mutation == "unreliable-remote-name" then owned.Unreliable.Name = "MovedUnreliable"
        elseif mutation == "extra-child" then
            foreign = Instance.new("Folder")
            foreign.Name = "Foreign"
            foreign.Parent = owned
        elseif mutation == "unreliable-remote-destroy" then owned.Unreliable:Destroy()
        else owned.Reliable:Destroy() end
        task.wait(0.3)
        local ok, failure = session.events.State:Broadcast(Fixture.values(1))
        assert(not ok and failure.code == "Destroyed", "server transport mutation")
        all("lost")
        all("destroy")
        if foreign then
            assert(foreign.Parent == owned and owned.Parent == ReplicatedStorage, "foreign child deleted")
            local contender = assert(Relay.createServer(Fixture.create(), {
                inboundRate = {
                    perPlayer = { capacity = 1, refillPerSecond = 1 },
                    aggregate = { capacity = 1, refillPerSecond = 1 },
                },
            }))
            local started, conflict = contender:Start()
            assert(not started and conflict.code == "RemoteOwnershipConflict", "contaminated root adopted")
            contender:Destroy()
        end
        -- Only the fixture removes contamination it created.
        owned:Destroy()
    end
    mark("transport-mutation-contamination")

    local baseline = #ReplicatedStorage:GetDescendants()
    for _ = 1, 100 do
        create()
        assert(#ReplicatedStorage.RelayRemotes:GetChildren() == 3, "exact owned hierarchy")
        session:Destroy()
        session:Destroy()
        assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "cleanup cycle root")
        assert(#ReplicatedStorage:GetDescendants() == baseline, "cleanup cycle Instance growth")
    end
    create()
    all("start")
    all("send", 1)
    task.wait(0.3)
    for _, player in roster do assert(count(player) == 1, "stale or duplicate callback after cycles") end
    all("destroy")
    session:Destroy()
    mark("cleanup-100-cycles")

    -- A finite overlong payload must drop after admission, consuming both budgets.
    create(4, #roster * 8, 0.000001)
    all("start")
    local overlongDeliveries = 0
    assert(session.events.SchemaInput:Connect(function() overlongDeliveries += 1 end))
    command(roster[1], "raw-overlong", 2)
    task.wait(0.3)
    assert(overlongDeliveries == 0, "overlong string dispatched")
    all("send", 4)
    task.wait(0.3)
    for index, player in roster do
        assert(count(player) == (if index == 1 then 2 else 4), "overlong string per-player charge")
    end
    mark("string-overlong-per-player-charged")
    all("destroy")

    create(4, 4, 0.000001)
    all("start")
    overlongDeliveries = 0
    assert(session.events.SchemaInput:Connect(function() overlongDeliveries += 1 end))
    command(roster[1], "raw-overlong", 2)
    task.wait(0.3)
    assert(overlongDeliveries == 0, "overlong string dispatched before aggregate proof")
    all("send", 4)
    task.wait(0.3)
    local accepted = 0
    for _, player in roster do accepted += count(player) end
    assert(accepted == 2, "overlong string aggregate charge")
    mark("string-overlong-aggregate-charged")
    all("destroy")

    create(4, #roster * 8, 0.000001)
    all("start")
    command(roster[1], "raw-composite", 4)
    task.wait(0.3)
    command(roster[1], "send", 4)
    task.wait(0.3)
    assert(count(roster[1]) == 0, "malformed composite buffers did not consume per-player budget")
    assert((compositeHandlerCalls[roster[1]] or 0) == 0, "charged malformed composite entered the handler")
    assert(not compositeDeliveries[roster[1]] or #compositeDeliveries[roster[1]] == 0, "malformed composite buffer dispatched")

    -- The one-client run proves per-player debit; the two-client run also isolates aggregate debit.
    if #roster > 1 then
        -- The untouched second per-player bucket isolates aggregate debit.
        create(4, 4, 0.000001)
        all("start")
        command(roster[1], "raw-composite", 2)
        task.wait(0.3)
        all("send", 4)
        task.wait(0.3)
        local compositeAccepted = 0
        for _, player in roster do
            compositeAccepted += count(player)
            assert((compositeHandlerCalls[player] or 0) == 0, "aggregate-charged malformed composite entered the handler")
        end
        assert(compositeAccepted == 2, "malformed composite aggregate charge")
    end
    mark("malformed-composite-charged")
    all("destroy")
    session:Destroy()
    endpointRateCorrectness()
    color3Correctness()
    readiness64Correctness()
    contentByteCorrectness()
    handlerCancellationCorrectness()
end

local function admission()
    create(4, #roster * 4, 0.000001)
    all("start")
    all("send", 32)
    task.wait(0.5)
    for _, player in roster do assert(count(player) == 4, "per-player admission") end
    mark("hostile-per-player")
    all("destroy")

    create(4, 4, 0.000001)
    all("start")
    all("send", 32)
    task.wait(0.5)
    local total = 0
    for _, player in roster do total += count(player) end
    assert(total == 4, "aggregate admission")
    mark("hostile-aggregate")
    all("destroy")

    create(4, #roster * 4, 0.000001)
    all("start")
    all("raw-composite", 4)
    task.wait(0.3)
    all("send", 4)
    task.wait(0.3)
    for _, player in roster do
        assert(count(player) == 0, "malformed frames bypassed charging")
        assert((compositeHandlerCalls[player] or 0) == 0, "charged malformed composite entered the handler")
        assert(not compositeDeliveries[player] or #compositeDeliveries[player] == 0, "malformed composite buffer dispatched")
    end
    mark("malformed-charged")
    all("destroy")

    if #roster > 1 then
        create(4, #roster * 4, 0.000001)
        all("start")
        for index = 1, #roster - 1 do command(roster[index], "send", 32) end
        task.wait(0.3)
        command(roster[#roster], "send", 4)
        task.wait(0.3)
        for _, player in roster do assert(count(player) == 4, "exhausted player drained honest budget") end
        mark("mixed-honest-budget")
        all("destroy")
    end
    session:Destroy()
end

task.spawn(function()
    local args = StudioTestService:GetTestArgs()
    local ok, failure = pcall(function()
        assert(type(args) == "table" and (args.clients == 1 or args.clients == 2 or args.clients == 4 or args.clients == 8))
        local presentCount, readyCount = 0, 0
        waitFor(function()
            local current = Players:GetPlayers()
            presentCount, readyCount = #current, 0
            for _, player in current do if readyPlayers[player] then readyCount += 1 end end
            if presentCount ~= args.clients or readyCount ~= args.clients then return false end
            roster = current
            return true
        end, function()
            return string.format("participant roster (expected=%d, present=%d, ready=%d)", args.clients, presentCount, readyCount)
        end, 60)
        table.sort(roster, function(left, right) return left.UserId < right.UserId end)
        if args.mode == "correctness" then correctness()
        elseif args.mode == "admission" then admission()
        else error("unknown proof mode") end
    end)
    if session then session:Destroy() end
    readyConnection:Disconnect()
    StudioTestService:EndTest({
        kind = "RelayReliableEventsProofV1",
        ok = ok,
        failure = if ok then nil else tostring(failure),
        clients = args.clients,
        mode = args.mode,
        completed = completed,
        cframe = cframeDiagnostics,
        unreliable = unreliableDiagnostics,
        queued = queuedDiagnostics,
        statePut = statePutDiagnostics,
        endpointRate = endpointRateDiagnostics,
        color3 = color3Diagnostics,
        readiness64 = readiness64Diagnostics,
        contentBytes = contentByteDiagnostics,
        handlerCancellation = handlerCancellationDiagnostics,
        handlerCancellationObservations = handlerCancellationObservations,
    })
end)
