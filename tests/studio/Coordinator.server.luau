local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StudioTestService = game:GetService("StudioTestService")
local Relay = require(ReplicatedStorage.Relay)
local Fixture = require(ReplicatedStorage.RelayProofDefinition)
local TransportNamespaces = require(ReplicatedStorage.RelayProofTransportNamespaces)
local InstanceValues = require(ReplicatedStorage.RelayProofInstanceValues)
local RpcBoundedRoutes = require(ReplicatedStorage.RelayProofRpcBoundedRoutes)
local NativeValues = require(ReplicatedStorage.RelayProofNativeValues)
local QuantizedValues = require(ReplicatedStorage.RelayProofQuantizedValues)
local CompactTransport = require(ReplicatedStorage.RelayProofCompactTransport)
local BufferDeferral = require(ReplicatedStorage.RelayProofBufferDeferral)
local BroadcastBatching = require(ReplicatedStorage.RelayProofBroadcastBatching)
local Competitive = require(ReplicatedStorage.RelayProofCompetitive)
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
local rgb8Color3Diagnostics
local taggedUnionDiagnostics
local taggedRawConnection
local installationDiagnostics
local queuedInputValues = {}
local queuedReusableInputValues = {}
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
local orderedUnreliableDiagnostics
local nativeValueDiagnostics
local instanceReferenceDiagnostics
local quantizedDiagnostics
local compactTransportDiagnostics
local bufferDeferralDiagnostics
local stateDeferralDiagnostics
local rpcBoundedRouteDiagnostics
local broadcastBatchingDiagnostics
local competitiveDiagnostics
local fairnessDiagnostics
local competitiveRawConnections = {}
local handlerCancellationObservations = {}
local readiness64Phase = "initial"
local BatchFrame = require(ReplicatedStorage.Relay.internal.BatchFrame)
local transportNamespaceDiagnostics

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

local function create(capacity, aggregate, refill, endpointRates, fairness)
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
            fairness = fairness,
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

local function observeInstanceIngress()
    local rows = {}
    local remote = ReplicatedStorage.RelayRemotes.Reliable
    local connection = remote.OnServerEvent:Connect(function(player, endpointId, packet, ...)
        if type(endpointId) ~= "number" or endpointId < 1 or endpointId > 7 then return end
        local row = InstanceValues.rawReceipt(endpointId, packet, ...)
        row.client = player.UserId
        table.insert(rows, row)
    end)
    return rows, connection
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
    table.clear(queuedReusableInputValues)
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
    assert(session.events.ReusableInput:Connect(function(player, value)
        local values = queuedReusableInputValues[player]
        if values == nil then
            values = {}
            queuedReusableInputValues[player] = values
        end
        table.insert(values, value)
        local sent, failure = session.events.ReusablePush:Send(player, value)
        assert(sent, failure and failure.message or "reusable client batcher acknowledgement failed")
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

local function reusableBatcherCorrectness()
    local clientReports = table.create(#roster)
    local clientInputs = table.create(#roster)
    for index, player in roster do
        local report = command(player, "queued-reusable-batcher")
        clientReports[index] = { client = player.UserId, report = report }
    end
    waitFor(function()
        for _, player in roster do
            local values = queuedReusableInputValues[player] or {}
            if #values ~= 2 or values[1] ~= false or values[2] ~= true then return false end
        end
        return true
    end, "reusable client batcher delivered two reliable windows", 10)
    for index, player in roster do
        local values = queuedReusableInputValues[player]
        assert(#values == 2 and values[1] == false and values[2] == true,
            "reusable client windows preserve false and later values")
        clientInputs[index] = { client = player.UserId, values = table.clone(values) }
    end
    all("queued-reusable-reset")

    local recipient = roster[1]
    local excluded = roster[2]
    local audience = { recipient, recipient }
    local batcher, batchFailure = session:CreateBatcher(audience, 0.03)
    assert(batcher ~= nil, batchFailure and batchFailure.message or "reusable server batcher creation failed")
    local push = batcher.events.ReusablePush
    assert(push:Send(false))
    local manualOk, manualFailure, manualReport = batcher:Flush()
    assert(manualOk, manualFailure and manualFailure.code or "reusable server manual flush failed")
    local manualStatus = batcher:GetStatus()
    assert(manualStatus.state == "Open" and manualStatus.pendingRecords == 0,
        "reusable server manual flush reopens an empty window")
    waitFor(function()
        local targetValues = queuedRead(recipient).reusable
        local excludedValues = if excluded then queuedRead(excluded).reusable else {}
        return #targetValues == 1 and targetValues[1] == false and #excludedValues == 0
    end, "reusable server fixed audience and deduplicated manual window", 10)

    assert(push:Send(true))
    waitFor(function()
        local targetValues = queuedRead(recipient).reusable
        local excludedValues = if excluded then queuedRead(excluded).reusable else {}
        local status = batcher:GetStatus()
        return #targetValues == 2 and targetValues[1] == false and targetValues[2] == true
            and #excludedValues == 0 and status.state == "Open" and status.pendingRecords == 0
            and status.lastFlush ~= nil and status.lastFlush.ok == true
    end, "reusable server timer window stays within its fixed audience", 10)
    local automaticStatus = batcher:GetStatus()
    local targetValues = queuedRead(recipient).reusable
    local excludedValues = if excluded then queuedRead(excluded).reusable else {}
    local sameEventHandle = batcher.events.ReusablePush == push
    batcher:Cancel()
    local cleanup = batcher:GetStatus()
    local sendAfterCancel = push:Send(false)
    assert(cleanup.state == "Terminal" and cleanup.pendingRecords == 0 and not sendAfterCancel,
        "reusable server Cancel is terminal and releases queued records")
    local replacement, replacementFailure = session:CreateBatch({ recipient }, 0.03)
    assert(replacement ~= nil, replacementFailure and replacementFailure.message or "reusable server batch slot was retained")
    replacement:Cancel()
    local released = replacement:GetStatus()

    local outbound = {
        recipient = recipient.UserId,
        excluded = if excluded then excluded.UserId else nil,
        targetValues = table.clone(targetValues),
        excludedValues = table.clone(excludedValues),
        sameEventHandle = sameEventHandle,
        manualReport = manualReport,
        manualStatus = manualStatus,
        automaticStatus = automaticStatus,
        cleanup = cleanup,
        sendAfterCancel = sendAfterCancel,
        slotReleased = released.state == "Terminal" and released.pendingRecords == 0,
    }
    return { clientInputs = clientInputs, clientReports = clientReports, outbound = outbound }
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

    local reusable = reusableBatcherCorrectness()
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
    queuedDiagnostics.reusable = reusable

    mark("bounded-batch-handler-starts")
    mark("listener-readiness-claims")
    mark("reusable-opt-in-batching")
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

local function rgb8Color3Correctness()
    if session then session:Destroy() session = nil end
    all("absent")
    local c2sValues, rawIngress, failure = {}, {}, nil
    for _, player in roster do
        c2sValues[player.UserId], rawIngress[player.UserId] = {}, {}
    end
    local created, creationProblem = Relay.createServer(Fixture.createRgb8Color3(), { inboundRate = {
        perPlayer = { capacity = 4096, refillPerSecond = 2048 },
        aggregate = { capacity = 4096 * #roster, refillPerSecond = 2048 * #roster },
        bytes = {
            perPlayer = { capacity = 4096, refillPerSecond = 4096 },
            aggregate = { capacity = 4096 * #roster, refillPerSecond = 4096 * #roster },
        },
    } })
    assert(created, creationProblem and creationProblem.code)
    session = created
    assert(session.events.Input:Connect(function(player, index, value)
        assert(player.Parent == Players, "RGB8 Color3 callback has the actual Player")
        local ok, observation = pcall(Fixture.checkRgb8Color3, value, index)
        if not ok then failure = tostring(observation) return end
        table.insert(c2sValues[player.UserId], { index = index, value = observation })
    end))
    assert(session:Start())
    local ingressConnection = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpoint, packet)
        local row = CompactTransport.rawReceipt(endpoint, packet)
        if row ~= nil and row.eventId == 1 and rawIngress[player.UserId] ~= nil then
            row.client = player.UserId
            table.insert(rawIngress[player.UserId], row)
        end
    end)
    all("rgb8-start")
    all("rgb8-send")
    waitFor(function()
        if failure ~= nil then return true end
        for _, player in roster do
            if #c2sValues[player.UserId] ~= Fixture.rgb8Color3ProbeCount
                or #rawIngress[player.UserId] ~= Fixture.rgb8Color3ProbeCount then return false end
        end
        return true
    end, "RGB8 Color3 C2S value and raw body observations")
    assert(failure == nil, failure)

    local sampleIndices = { 0, 1, 127, 128, 255, 256, 257 }
    local samplePositionByIndex = {}
    for position, index in sampleIndices do samplePositionByIndex[index] = position end
    local function summarizeDirection(values, sources, rawRows, playerId, eventId, label)
        assert(#values == Fixture.rgb8Color3ProbeCount and #sources == Fixture.rgb8Color3ProbeCount
            and #rawRows == Fixture.rgb8Color3ProbeCount, label .. " RGB8 Color3 full observation cardinality")
        local coverage = { {}, {}, {} }
        local samples = table.create(#sampleIndices)
        local maxQuantizationError, maxConstructionError, stableCodes = 0, 0, 0
        for position = 1, Fixture.rgb8Color3ProbeCount do
            local index = position - 1
            local observedRow, sourceRow, raw = values[position], sources[position], rawRows[position]
            assert(observedRow.index == index and sourceRow.index == index,
                label .. " RGB8 Color3 ordered source and value observations")
            assert(raw.client == playerId and raw.endpoint == eventId and raw.eventId == eventId
                and raw.format == 1 and raw.length == 8 and #raw.bytes == 5,
                label .. " RGB8 Color3 actual Player, envelope, and raw width")
            local source, observed = sourceRow.value, observedRow.value
            assert(type(source) == "table" and type(source.negativeZeroR) == "boolean"
                and type(observed) == "table" and observed.negativeZeroR == false,
                label .. " RGB8 Color3 source and decoded records")
            local sourceComponents = { source.r, source.g, source.b }
            local observedComponents = { observed.r, observed.g, observed.b }
            local codes = table.create(3)
            for channel = 1, 3 do
                local sourceValue, observedValue = sourceComponents[channel], observedComponents[channel]
                assert(type(sourceValue) == "number" and sourceValue == sourceValue
                    and sourceValue ~= math.huge and sourceValue ~= -math.huge
                    and sourceValue >= 0 and sourceValue <= 1,
                    label .. " finite in-range native source component")
                assert(type(observedValue) == "number" and observedValue == observedValue
                    and observedValue ~= math.huge and observedValue ~= -math.huge
                    and observedValue >= 0 and observedValue <= 1,
                    label .. " finite in-range decoded component")
                local code = math.floor(sourceValue * 255 + 0.5)
                codes[channel] = code
                local canonical = code / 255
                local quantizationError = math.abs(sourceValue - canonical)
                local constructionError = math.abs(observedValue - canonical)
                assert(quantizationError <= 1 / 510 + 2 ^ -24,
                    label .. " native source quantization allowance")
                assert(constructionError <= 2 ^ -24
                    and math.floor(observedValue * 255 + 0.5) == code,
                    label .. " decoded constructor allowance and code stability")
                if code == 0 then
                    assert(observedValue == 0 and 1 / observedValue == math.huge,
                        label .. " decoded positive zero")
                end
                maxQuantizationError = math.max(maxQuantizationError, quantizationError)
                maxConstructionError = math.max(maxConstructionError, constructionError)
                stableCodes += 1
                if index < 256 then coverage[channel][code] = true end
            end
            assert(raw.bytes[1] == index % 256 and raw.bytes[2] == math.floor(index / 256)
                and raw.bytes[3] == codes[1] and raw.bytes[4] == codes[2] and raw.bytes[5] == codes[3],
                label .. " actual handoff index and RGB channel-order bytes")
            local samplePosition = samplePositionByIndex[index]
            if samplePosition ~= nil then
                if index == 256 then
                    samples[samplePosition] = {
                        source.r, source.g, source.b,
                        observed.r, observed.g, observed.b,
                        source.negativeZeroR, observed.negativeZeroR,
                        raw.bytes[1], raw.bytes[2], raw.bytes[3], raw.bytes[4], raw.bytes[5],
                    }
                else
                    samples[samplePosition] = {
                        observed.r, observed.g, observed.b,
                        source.negativeZeroR, observed.negativeZeroR,
                        raw.bytes[1], raw.bytes[2], raw.bytes[3], raw.bytes[4], raw.bytes[5],
                    }
                end
            end
        end
        local function coverageCount(channel)
            local count = 0
            for code = 0, 255 do if coverage[channel][code] then count += 1 end end
            return count
        end
        local channelCoverage = { r = coverageCount(1), g = coverageCount(2), b = coverageCount(3) }
        assert(channelCoverage.r == 256 and channelCoverage.g == 256 and channelCoverage.b == 256,
            label .. " every RGB8 code observed in every channel")
        return {
            count = #values,
            stableCodes = stableCodes,
            coverage = { channelCoverage.r, channelCoverage.g, channelCoverage.b },
            maxQuantizationError = maxQuantizationError,
            maxConstructionError = maxConstructionError,
            samples = samples,
        }
    end

    local serverSources = table.create(Fixture.rgb8Color3ProbeCount)
    for _, player in roster do
        for index = 0, Fixture.rgb8Color3ProbeCount - 1 do
            local value = Fixture.rgb8Color3Source(index)
            local source = Fixture.rgb8Color3Components(value)
            local codes = { Fixture.rgb8Color3Codes(value) }
            local components = { source.r, source.g, source.b }
            for channel = 1, 3 do
                local component, code = components[channel], codes[channel]
                assert(type(component) == "number" and component == component
                    and component ~= math.huge and component ~= -math.huge
                    and component >= 0 and component <= 1
                    and type(code) == "number" and code % 1 == 0 and code >= 0 and code <= 255
                    and math.abs(component - code / 255) <= 1 / 510 + 2 ^ -24,
                    "finite in-range native S2C source and RGB8 quantization")
            end
            if serverSources[index + 1] == nil then serverSources[index + 1] = { index = index, value = source } end
            assert(session.events.Output:Send(player, index, value))
        end
    end

    local clients = {}
    for _, player in roster do
        local result = command(player, "rgb8-read")
        assert(result.failure == nil and #result.values == Fixture.rgb8Color3ProbeCount
            and #result.sources == Fixture.rgb8Color3ProbeCount
            and #result.raw == Fixture.rgb8Color3ProbeCount, "RGB8 Color3 S2C value/raw receipt")
        for _, row in result.raw do row.client = player.UserId end
        table.insert(clients, {
            client = player.UserId,
            c2s = summarizeDirection(c2sValues[player.UserId], result.sources, rawIngress[player.UserId],
                player.UserId, 1, "RGB8 Color3 C2S"),
            s2c = summarizeDirection(result.values, serverSources, result.raw,
                player.UserId, 2, "RGB8 Color3 S2C"),
        })
    end
    ingressConnection:Disconnect()
    local snapshot = session:GetDiagnostics()
    assert(snapshot.counters.invalidPayload == 0 and snapshot.counters.handlerErrors == 0
        and snapshot.counters.perPlayerBytes == 0 and snapshot.counters.aggregateBytes == 0
        and snapshot.events.Input.dispatched == Fixture.rgb8Color3ProbeCount * #roster,
        "RGB8 Color3 value traffic has clean admission and dispatch counters")
    rgb8Color3Diagnostics = {
        probeCount = Fixture.rgb8Color3ProbeCount,
        sampleIndices = sampleIndices,
        rawC2S = { format = 1, endpoint = 1, eventId = 1, length = 8 },
        rawS2C = { format = 1, endpoint = 2, eventId = 2, length = 8 },
        clients = clients,
        inputHandlers = snapshot.events.Input.dispatched,
        malformed = nil,
    }
    all("rgb8-destroy")
    session:Destroy()
    session = nil
    all("absent")

    local malformedFrames, malformedHandlers = {}, 0
    for _, player in roster do malformedFrames[player.UserId] = {} end
    session = assert(Relay.createServer(Fixture.createRgb8Color3(), { inboundRate = {
        perPlayer = { capacity = 16, refillPerSecond = 16 },
        aggregate = { capacity = 16 * #roster, refillPerSecond = 16 * #roster },
        bytes = {
            perPlayer = { capacity = 8, refillPerSecond = 0.000001 },
            aggregate = { capacity = 8 * #roster, refillPerSecond = 0.000001 },
        },
    } }))
    assert(session.events.Input:Connect(function()
        malformedHandlers += 1
    end))
    assert(session:Start())
    local malformedConnection = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpoint, packet)
        local row = CompactTransport.rawReceipt(endpoint, packet)
        if row ~= nil and row.eventId == 1 and malformedFrames[player.UserId] ~= nil then
            row.client = player.UserId
            table.insert(malformedFrames[player.UserId], row)
        end
    end)
    all("rgb8-malformed-start")
    all("rgb8-malformed")
    waitFor(function()
        local counters = session:GetDiagnostics().counters
        return counters.invalidPayload == #roster and counters.perPlayerBytes == #roster
    end, "RGB8 Color3 truncated rejection and retained byte admission")
    waitFor(function()
        for _, player in roster do
            if #malformedFrames[player.UserId] ~= 2 then return false end
        end
        return true
    end, "RGB8 Color3 malformed and over-budget raw ingress observations")
    local malformedClients = {}
    for _, player in roster do
        local frames = malformedFrames[player.UserId]
        local truncated, overBudget = frames[1], frames[2]
        assert(#frames == 2 and truncated.client == player.UserId and overBudget.client == player.UserId
            and truncated.endpoint == 1 and truncated.eventId == 1 and truncated.format == 1 and truncated.length == 7
            and #truncated.bytes == 4 and truncated.bytes[1] == 0 and truncated.bytes[2] == 1
            and truncated.bytes[3] == 0 and truncated.bytes[4] == 127
            and overBudget.endpoint == 1 and overBudget.eventId == 1 and overBudget.format == 1
            and overBudget.length == 8 and #overBudget.bytes == 5 and overBudget.bytes[1] == 0
            and overBudget.bytes[2] == 0 and overBudget.bytes[3] == 0
            and overBudget.bytes[4] == 255 and overBudget.bytes[5] == 0,
            "RGB8 Color3 malformed and subsequent valid raw frames")
        table.insert(malformedClients, {
            client = player.UserId,
            truncated = table.clone(truncated.bytes),
            overBudget = table.clone(overBudget.bytes),
        })
    end
    local malformedSnapshot = session:GetDiagnostics()
    assert(malformedHandlers == 0 and malformedSnapshot.counters.received == 2 * #roster
        and malformedSnapshot.events.Input.dispatched == 0
        and malformedSnapshot.events.Input.invalidPayload == #roster
        and malformedSnapshot.counters.aggregateBytes == 0,
        "RGB8 Color3 truncated input rejects before callback and consumes its byte budget")
    rgb8Color3Diagnostics.malformed = {
        clients = malformedClients,
        frame = { endpoint = 1, eventId = 1, format = 1, truncatedLength = 7, overBudgetLength = 8 },
        handlers = malformedHandlers,
        perPlayerByteCapacity = 8,
        aggregateByteCapacity = 8 * #roster,
        received = malformedSnapshot.counters.received,
        invalidPayload = malformedSnapshot.counters.invalidPayload,
        perPlayerBytes = malformedSnapshot.counters.perPlayerBytes,
        aggregateBytes = malformedSnapshot.counters.aggregateBytes,
        inputInvalidPayload = malformedSnapshot.events.Input.invalidPayload,
        inputDispatched = malformedSnapshot.events.Input.dispatched,
    }
    malformedConnection:Disconnect()
    all("rgb8-destroy")
    session:Destroy()
    session = nil
    mark("rgb8-color3-native")
end

local function taggedUnionCorrectness()
    if session then session:Destroy() end
    all("absent")
    local records, failure = {}, nil
    for _, player in roster do
        records[player.UserId] = { c2s = {}, rpcRequests = {} }
    end
    local function record(destination, value)
        local ok, observation = pcall(Fixture.checkTagged, value)
        if not ok then failure = tostring(observation) return end
        table.insert(destination, observation)
    end
    session = assert(Relay.createServer(Fixture.createTaggedUnion(), { inboundRate = {
        perPlayer = { capacity = 128, refillPerSecond = 128 },
        aggregate = { capacity = 1024, refillPerSecond = 1024 },
    } }))
    assert(session.events.Input:Connect(function(player, value) record(records[player.UserId].c2s, value) end))
    assert(session.requests.Echo:Connect(function(player, value)
        record(records[player.UserId].rpcRequests, value)
        return value
    end))
    assert(session:Start())
    all("tagged-start")
    for _, player in roster do records[player.UserId].rpcResponses = command(player, "tagged-send") end
    waitFor(function()
        for _, player in roster do
            local result = records[player.UserId]
            if #result.c2s ~= 3 or #result.rpcRequests ~= 2 then return false end
        end
        return true
    end, "native tagged-union C2S and RPC branches")
    assert(failure == nil, failure)
    for _, player in roster do
        assert(session.events.Output:Send(player, Fixture.taggedSuccess("ready", 258)))
        assert(session.events.Output:Send(player, Fixture.taggedFailure()))
    end
    local clients = {}
    for _, player in roster do
        local result = records[player.UserId]
        result.s2c = command(player, "tagged-read")
        assert(#result.c2s == 3 and #result.rpcRequests == 2 and #result.rpcResponses == 2 and #result.s2c == 2,
            "native tagged-union branch counts")
        table.insert(clients, {
            client = player.UserId, c2s = result.c2s, rpcRequests = result.rpcRequests,
            rpcResponses = result.rpcResponses, s2c = result.s2c,
        })
    end
    local snapshot = session:GetDiagnostics()
    assert(snapshot.counters.received == 5 * #roster and snapshot.counters.dispatched == 5 * #roster
        and snapshot.counters.invalidPayload == 0 and snapshot.counters.handlerErrors == 0
        and snapshot.events.Input.dispatched == 3 * #roster
        and snapshot.events.Output.sendHandoffs == 2 * #roster,
        "native tagged-union reliable event/RPC diagnostics")
    taggedUnionDiagnostics = { labelOrder = { "Failure", "Success" }, correctness = { clients = clients } }
    all("tagged-destroy")
    session:Destroy()
    session = nil
    all("absent")

    local admissionHandlers, rawFrames = {}, {}
    for _, player in roster do
        admissionHandlers[player.UserId] = {}
        rawFrames[player.UserId] = {}
    end
    local created, createFailure = Relay.createServer(Fixture.createTaggedUnion(), { inboundRate = {
        perPlayer = { capacity = 4, refillPerSecond = 0.000001 },
        aggregate = { capacity = 4 * #roster, refillPerSecond = 0.000001 },
    } })
    assert(created ~= nil, createFailure and createFailure.message or "tagged-union admission server creation failed")
    session = created
    assert(session.events.Input:Connect(function(player, value)
        record(admissionHandlers[player.UserId], value)
    end))
    assert(session:Start())
    local reliable = ReplicatedStorage.RelayRemotes.Reliable
    taggedRawConnection = reliable.OnServerEvent:Connect(function(player, endpointId, ...)
        if endpointId ~= 1 or select("#", ...) ~= 1 then return end
        local packet = ...
        if typeof(packet) ~= "buffer" then return end
        local length = buffer.len(packet)
        if length < 4 then return end
        table.insert(rawFrames[player.UserId], {
            endpoint = endpointId, format = buffer.readu8(packet, 0), eventId = buffer.readu16(packet, 1),
            length = length, ordinal = buffer.readu8(packet, 3),
            byte1 = if length >= 5 then buffer.readu8(packet, 4) else false,
            byte2 = if length >= 6 then buffer.readu8(packet, 5) else false,
        })
    end)
    all("tagged-start")
    all("tagged-admission-send")
    waitFor(function()
        local observed = session:GetDiagnostics().counters
        if observed.received ~= 5 * #roster or observed.invalidPayload ~= 2 * #roster
            or observed.perPlayerRate ~= #roster or observed.aggregateRate ~= 0 then return false end
        for _, player in roster do
            if #rawFrames[player.UserId] ~= 5 or #admissionHandlers[player.UserId] ~= 2 then return false end
        end
        return true
    end, "tagged-union invalid frames retain per-player charges")
    assert(failure == nil, failure)
    snapshot = session:GetDiagnostics()
    assert(snapshot.counters.received == 5 * #roster and snapshot.counters.invalidPayload == 2 * #roster
        and snapshot.counters.perPlayerRate == #roster and snapshot.counters.aggregateRate == 0
        and snapshot.counters.dispatched == 2 * #roster and snapshot.counters.handlerErrors == 0
        and snapshot.events.Input.dispatched == 2 * #roster
        and snapshot.events.Input.invalidPayload == 2 * #roster,
        "tagged-union malformed frames charged before decode and fifth send refused")
    local admissionClients = {}
    for _, player in roster do
        local frames = rawFrames[player.UserId]
        assert(#frames == 5 and frames[1].length == 20 and frames[1].ordinal == 1
            and frames[2].length == 12 and frames[2].ordinal == 0
            and frames[3].length == 6 and frames[3].ordinal == 2
            and frames[4].length == 6 and frames[4].ordinal == 0
            and frames[4].byte1 == 4 and frames[4].byte2 == 0
            and frames[5].length == 27 and frames[5].ordinal == 1,
            "native tagged-union hostile buffers observed at reliable transport")
        for _, frame in frames do
            assert(frame.endpoint == 1 and frame.format == 1 and frame.eventId == 1,
                "native tagged-union transport and embedded endpoint headers")
        end
        table.insert(admissionClients, { client = player.UserId, handlers = admissionHandlers[player.UserId], raw = frames })
    end
    taggedUnionDiagnostics.admission = {
        counters = {
            received = snapshot.counters.received, invalidPayload = snapshot.counters.invalidPayload,
            perPlayerRate = snapshot.counters.perPlayerRate, aggregateRate = snapshot.counters.aggregateRate,
            dispatched = snapshot.counters.dispatched, handlerErrors = snapshot.counters.handlerErrors,
            eventDispatched = snapshot.events.Input.dispatched, eventInvalidPayload = snapshot.events.Input.invalidPayload,
        },
        clients = admissionClients,
    }
    taggedRawConnection:Disconnect()
    taggedRawConnection = nil
    all("tagged-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("tagged-union-native-values")
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

local function orderedUnreliableCorrectness()
    if session then session:Destroy() end
    all("absent")
    local values, rawCounts, maximumObserved = {}, {}, 0
    session = assert(Relay.createServer(Fixture.createOrderedUnreliable(), { inboundRate = {
        perPlayer = { capacity = 128, refillPerSecond = 128 },
        aggregate = { capacity = 1024, refillPerSecond = 1024 },
        bytes = { perPlayer = { capacity = 16384, refillPerSecond = 16384 },
            aggregate = { capacity = 131072, refillPerSecond = 131072 } },
    } }))
    assert(session.events.Input:Connect(function(player, text)
        if #text == 887 then assert(text == string.rep("x", 887), "ordered maximum payload contents") end
        table.insert(values[player], if #text == 887 then "maximum" else text)
    end))
    assert(session:Start())
    local unreliable = ReplicatedStorage.RelayRemotes.Unreliable
    local rawObserver = unreliable.OnServerEvent:Connect(function(player, endpoint, packet)
        if endpoint == 1 and typeof(packet) == "buffer" then
            rawCounts[player] += 1
            maximumObserved = math.max(maximumObserved, buffer.len(packet))
        end
    end)
    local generations, activeGenerations = {}, {}
    for _, player in roster do
        values[player], rawCounts[player] = {}, 0
        generations[player] = command(player, "ordered-start")
        activeGenerations[player] = generations[player]
        assert(generations[player] == 1, "first actual-player ordered generation")
    end
    local function waitRaw(expected, delivered, stale, invalid)
        waitFor(function()
            for _, player in roster do
                if rawCounts[player] ~= expected or #values[player] ~= delivered then return false end
            end
            local counters = session:GetDiagnostics().events.Input
            if counters.stale ~= stale or counters.invalidPayload ~= invalid then return false end
            return true
        end, "ordered native C2S observations (missing unreliable arrivals are inconclusive)", 8)
    end
    all("ordered-send-maximum")
    waitRaw(1, 1, 0, 0)
    -- Each phase waits for observed arrival before the next phase is sent. This
    -- verifies explicit stale frames, not naturally occurring network reordering.
    for index, sample in {
        { sequence = 10, text = "ten" }, { sequence = 9, text = "stale" },
        { sequence = 10, text = "duplicate" }, { sequence = 11, text = "invalid", malformed = true },
        { sequence = 11, text = "eleven" },
    } do
        all("ordered-send-raw", sample)
        waitRaw(index + 1, if index == 5 then 3 else 2,
            (if index >= 3 then 2 elseif index == 2 then 1 else 0) * #roster,
            if index >= 4 then #roster else 0)
    end
    local s2c = {}
    local function readClients(expected, delivered, stale, invalid)
        waitFor(function()
            for _, player in roster do
                s2c[player] = command(player, "ordered-read")
                if s2c[player].raw ~= expected or #s2c[player].values ~= delivered
                    or s2c[player].stale ~= stale or s2c[player].invalidPayload ~= invalid then return false end
            end
            return true
        end, "ordered native S2C observations (missing unreliable arrivals are inconclusive)", 8)
    end
    local maximum = string.rep("x", 887)
    for _, player in roster do assert(session.events.Output:Send(player, maximum)) end
    readClients(1, 1, 0, 0)
    assert(session.events.Output:Broadcast(maximum))
    readClients(2, 2, 0, 0)
    local before = session:GetDiagnostics().counters
    local sent, failure = session.events.Output:Broadcast(maximum .. "x")
    assert(not sent and failure.code == "InvalidPayload"
        and session:GetDiagnostics().counters.broadcastHandoffs == before.broadcastHandoffs,
        "ordered 901-byte server send rejects before handoff")
    for index, sample in {
        { sequence = 10, text = "ten" }, { sequence = 9, text = "stale" },
        { sequence = 10, text = "duplicate" }, { sequence = 11, text = "invalid", malformed = true },
        { sequence = 11, text = "eleven" },
    } do
        local packet = buffer.create(13 + #sample.text + (if sample.malformed then 1 else 0))
        buffer.writeu8(packet, 0, 3)
        buffer.writeu16(packet, 1, 2)
        buffer.writeu32(packet, 3, 0)
        buffer.writeu32(packet, 7, sample.sequence)
        buffer.writeu16(packet, 11, #sample.text)
        buffer.writestring(packet, 13, sample.text)
        for _, player in roster do unreliable:FireClient(player, 2, packet) end
        readClients(index + 2, if index == 5 then 4 else 3,
            if index >= 3 then 2 elseif index == 2 then 1 else 0, if index >= 4 then 1 else 0)
    end
    local outputs = {}
    for _, player in roster do
        local snapshot = s2c[player]
        assert(#snapshot.values == 4 and snapshot.values[1] == "maximum"
            and snapshot.values[2] == "maximum" and snapshot.values[3] == "ten"
            and snapshot.values[4] == "eleven" and snapshot.stale == 2
            and snapshot.invalidPayload == 1 and snapshot.maximumFrameBytes == 900,
            "native ordered client dispatch/refusals/maximum bytes")
        table.insert(outputs, { client = player.UserId, values = snapshot.values,
            stale = snapshot.stale, invalidPayload = snapshot.invalidPayload, raw = snapshot.raw,
            maximumFrameBytes = snapshot.maximumFrameBytes })
    end
    local target = roster[1]
    local newGeneration = command(target, "ordered-start")
    assert(newGeneration > generations[target], "native client recreation advances server generation")
    activeGenerations[target] = newGeneration
    assert(command(target, "ordered-send-maximum"))
    waitFor(function() return rawCounts[target] == 7 and #values[target] == 4 end, "ordered restarted client", 8)
    assert(command(target, "ordered-send-raw", {
        generation = generations[target], sequence = 12, text = "prior-generation",
    }))
    waitFor(function()
        return rawCounts[target] == 8 and session:GetDiagnostics().events.Input.stale == #roster * 2 + 1
    end, "old-generation native arrival", 8)
    assert(command(target, "ordered-send", "after-restart"))
    waitFor(function() return rawCounts[target] == 9 and #values[target] == 5 end,
        "fresh native generation after replay", 8)
    local function streamCounters()
        local current = session:GetDiagnostics().counters
        return { broadcastHandoffs = current.broadcastHandoffs, sendHandoffs = current.sendHandoffs,
            outboundBytesCharged = current.outboundBytesCharged, outboundByteRejected = current.outboundByteRejected }
    end
    local function streamDelta(before, after)
        return { broadcastHandoffs = after.broadcastHandoffs - before.broadcastHandoffs,
            sendHandoffs = after.sendHandoffs - before.sendHandoffs,
            outboundBytesCharged = after.outboundBytesCharged - before.outboundBytesCharged,
            outboundByteRejected = after.outboundByteRejected - before.outboundByteRejected }
    end
    local function assertSharedPhase(before, after, packetLength, label)
        local delta = streamDelta(before, after)
        assert(delta.broadcastHandoffs == 1 and delta.sendHandoffs == 0
            and delta.outboundBytesCharged == packetLength * #roster and delta.outboundByteRejected == 0,
            label .. " shared handoff and exact per-recipient byte debit")
        return delta
    end
    local function unchangedCounters(before, after)
        return before.broadcastHandoffs == after.broadcastHandoffs and before.sendHandoffs == after.sendHandoffs
            and before.outboundBytesCharged == after.outboundBytesCharged
            and before.outboundByteRejected == after.outboundByteRejected
    end
    local function streamRead(player)
        return command(player, "ordered-stream-read")
    end
    local streamBefore = streamCounters()
    local sharedStream, sharedFailure = session.events.SharedStream:CreateBroadcastStream({ rate = 5, keepalive = 1.5 })
    assert(sharedStream ~= nil, sharedFailure and sharedFailure.message or "shared stream construction")
    local targetStream, targetFailure = session.events.TargetedStream:CreateStream(target, { rate = 1, keepalive = 1 })
    assert(targetStream ~= nil, targetFailure and targetFailure.message or "targeted stream construction")
    assert(sharedStream:Set(0.25) and sharedStream:Set(0.5) and sharedStream:Set(0.75), "coalesced shared stream Set calls")
    local afterImmediateSets = streamCounters()
    assert(unchangedCounters(streamBefore, afterImmediateSets), "Set does not hand off before the next task step")
    waitFor(function()
        return streamCounters().broadcastHandoffs == streamBefore.broadcastHandoffs + 1
    end, "shared stream first scheduled handoff", 8)
    local afterInitialData = streamCounters()
    local initialDataPhase = assertSharedPhase(streamBefore, afterInitialData, 24, "initial stream data")
    local sharedObservations = {}
    waitFor(function()
        for _, player in roster do
            sharedObservations[player] = streamRead(player)
            local samples = sharedObservations[player].shared
            if #samples == 0 or not samples[#samples].statePresent or samples[#samples].state ~= 0.75 then return false end
        end
        return true
    end, "coalesced shared latest value at every receiver", 8)
    waitFor(function()
        return streamCounters().broadcastHandoffs == streamBefore.broadcastHandoffs + 2
    end, "shared stream stop-confirmation handoff", 8)
    local afterStopConfirmation = streamCounters()
    local stopStatus = sharedStream:GetStatus()
    local stopSentTime = stopStatus.lastSentTime
    assert(type(stopSentTime) == "number", "stop-confirmation records its server timestamp")
    local stopConfirmationPhase = assertSharedPhase(afterInitialData, afterStopConfirmation, 24,
        "stop-confirmation stream data")
    local suppressionWaitSeconds = 0.65
    local suppressionStartTime = Workspace:GetServerTimeNow()
    task.wait(suppressionWaitSeconds)
    local afterSuppression = streamCounters()
    local suppressionEndTime = Workspace:GetServerTimeNow()
    local suppressedStatus = sharedStream:GetStatus()
    local suppressionElapsed = suppressionEndTime - stopSentTime
    assert(afterSuppression.broadcastHandoffs == afterStopConfirmation.broadcastHandoffs
        and afterSuppression.outboundBytesCharged == afterStopConfirmation.outboundBytesCharged
        and suppressedStatus.state == "Active" and suppressedStatus.lastSentTime == stopSentTime
        and suppressionElapsed >= 0.5 and suppressionElapsed < 1.5,
        "unchanged shared state suppresses normal-rate sends before keepalive")
    local suppressionPhase = streamDelta(afterStopConfirmation, afterSuppression)
    assert(suppressionPhase.broadcastHandoffs == 0 and suppressionPhase.sendHandoffs == 0
        and suppressionPhase.outboundBytesCharged == 0 and suppressionPhase.outboundByteRejected == 0,
        "pre-keepalive suppression has no handoff or charge")
    waitFor(function()
        return streamCounters().broadcastHandoffs == streamBefore.broadcastHandoffs + 3
    end, "shared stream keepalive handoff", 4)
    local afterKeepalive = streamCounters()
    local keepaliveStatus = sharedStream:GetStatus()
    local keepaliveElapsed = keepaliveStatus.lastSentTime - stopSentTime
    local minimumKeepaliveInterval = 1.25
    assert(keepaliveElapsed >= minimumKeepaliveInterval,
        "shared keepalive does not precede its configured 1.5-second interval")
    local keepalivePhase = assertSharedPhase(afterSuppression, afterKeepalive, 24, "stream keepalive")
    local clearBefore = streamCounters()
    assert(sharedStream:Clear(), "shared stream clear accepted")
    assert(unchangedCounters(clearBefore, streamCounters()), "Clear waits for the next task step")
    waitFor(function()
        return streamCounters().broadcastHandoffs == clearBefore.broadcastHandoffs + 1
            and sharedStream:GetStatus().state == "Idle"
    end, "shared stream clear handoff and Idle status", 8)
    local clearAfter = streamCounters()
    local clearStatus = sharedStream:GetStatus()
    local clearPhase = assertSharedPhase(clearBefore, clearAfter, 20, "stream clear")
    assert(clearStatus.state == "Idle" and not clearStatus.pending, "clear releases the shared snapshot")
    for _, player in roster do sharedObservations[player] = streamRead(player) end
    local clearObserved = {}
    for _, player in roster do
        clearObserved[player] = false
        for _, sample in sharedObservations[player].shared do
            if not sample.statePresent then clearObserved[player] = true break end
        end
    end
    sharedStream:Destroy()
    assert(sharedStream:GetStatus().state == "Destroyed", "shared stream destroy releases the handle")
    local beforeSharedCleanupWait = streamCounters()
    task.wait(0.2)
    local afterSharedCleanupWait = streamCounters()
    assert(unchangedCounters(beforeSharedCleanupWait, afterSharedCleanupWait), "cleared shared stream has no late handoff or charge")

    local targetedBefore = streamCounters()
    assert(targetStream:Set(-12.5), "targeted stream Set")
    local afterImmediateTargetSet = streamCounters()
    assert(unchangedCounters(targetedBefore, afterImmediateTargetSet), "targeted Set waits for the next task step")
    waitFor(function()
        local targetState = streamRead(target)
        return streamCounters().sendHandoffs == targetedBefore.sendHandoffs + 1
            and #targetState.targeted > 0 and targetState.targeted[#targetState.targeted].statePresent
            and targetState.targeted[#targetState.targeted].state == -12.5
    end, "targeted stream reaches only its selected peer", 8)
    local targetedAfter = streamCounters()
    assert(targetedAfter.sendHandoffs == targetedBefore.sendHandoffs + 1
        and targetedAfter.broadcastHandoffs == targetedBefore.broadcastHandoffs
        and targetedAfter.outboundBytesCharged == targetedBefore.outboundBytesCharged + 24,
        "targeted stream uses one FireClient and charges one 24-byte packet")
    targetStream:Destroy()
    assert(targetStream:GetStatus().state == "Destroyed", "active targeted stream destroy")
    local beforeTargetCleanupWait = streamCounters()
    task.wait(1.1)
    local afterTargetCleanupWait = streamCounters()
    assert(unchangedCounters(beforeTargetCleanupWait, afterTargetCleanupWait), "destroyed targeted stream has no late handoff or charge")
    for _, player in roster do
        local snapshot = streamRead(player)
        if player ~= target then
            for _, sample in snapshot.targeted do
                assert(not sample.statePresent, "targeted stream has no value callback on a non-target peer")
            end
        end
    end

    local streamPhasePeers = {}
    for _, player in roster do
        streamPhasePeers[player] = streamRead(player)
        clearObserved[player] = false
        for _, sample in streamPhasePeers[player].shared do
            if not sample.statePresent then clearObserved[player] = true break end
        end
    end
    local streamProbeBefore = streamCounters()
    local streamProbe = {}
    local unreliableRemote = ReplicatedStorage.RelayRemotes.Unreliable
    local invalidTimestamp = 1_000_000_000_001
    local invalidFinalState = 1001
    for _, player in roster do
        local beforeProbe = streamRead(player)
        local probeSequence = beforeProbe.lastSequences.shared + 10
        local probeGeneration = 0
        local callbackCount = #beforeProbe.shared
        local invalidBefore = beforeProbe.invalidPayload
        local rawBefore = beforeProbe.rawCounts.shared
        local function probePacket(serverTime, state)
            local packet = buffer.create(24)
            buffer.writeu8(packet, 0, 3)
            buffer.writeu16(packet, 1, 3)
            buffer.writeu32(packet, 3, probeGeneration)
            buffer.writeu32(packet, 7, probeSequence)
            buffer.writef64(packet, 11, serverTime)
            buffer.writeu8(packet, 19, 1)
            buffer.writef32(packet, 20, state)
            return packet
        end
        unreliableRemote:FireClient(player, 3, probePacket(invalidTimestamp, 0.625))
        waitFor(function()
            local observed = streamRead(player)
            return observed.rawCounts.shared == rawBefore + 1 and observed.invalidPayload == invalidBefore + 1
        end, "invalid native stream timestamp reaches the decoder and is rejected", 8)
        local timestampRejected = streamRead(player)
        assert(#timestampRejected.shared == callbackCount, "invalid stream timestamp never invokes the callback")
        unreliableRemote:FireClient(player, 3, probePacket(Workspace:GetServerTimeNow(), invalidFinalState))
        waitFor(function()
            local observed = streamRead(player)
            return observed.rawCounts.shared == rawBefore + 2 and observed.invalidPayload == invalidBefore + 2
        end, "invalid final native stream value reaches the decoder and is rejected", 8)
        local valueRejected = streamRead(player)
        assert(#valueRejected.shared == callbackCount, "invalid final stream value never invokes the callback")
        local recoveryTime = Workspace:GetServerTimeNow()
        unreliableRemote:FireClient(player, 3, probePacket(recoveryTime, 0.625))
        waitFor(function()
            local observed = streamRead(player)
            local latest = observed.shared[#observed.shared]
            return observed.rawCounts.shared == rawBefore + 3 and observed.invalidPayload == invalidBefore + 2
                and #observed.shared == callbackCount + 1 and latest.statePresent and latest.state == 0.625
        end, "valid stream recovery reuses the rejected sequence", 8)
        local recoveryObserved = streamRead(player)
        local recoverySample = recoveryObserved.shared[#recoveryObserved.shared]
        streamProbe[player] = { sequence = probeSequence, generation = probeGeneration,
            invalidBefore = invalidBefore, afterTimestamp = timestampRejected.invalidPayload,
            afterFinalState = valueRejected.invalidPayload, callbacksBefore = callbackCount,
            callbacksAfterTimestamp = #timestampRejected.shared, callbacksAfterFinalState = #valueRejected.shared,
            callbacksAfterRecovery = callbackCount + 1, recoveryTime = recoverySample.serverTime,
            recoveryClientTime = recoverySample.clientTime, recoveryState = recoverySample.state }
    end
    assert(unchangedCounters(streamProbeBefore, streamCounters()), "direct malformed and recovery probes bypass Relay handoff charges")
    local streamPeers, clearObservedCount = {}, 0
    for _, player in roster do
        local finalSnapshot = streamRead(player)
        local phaseSnapshot = streamPhasePeers[player]
        if clearObserved[player] then clearObservedCount += 1 end
        table.insert(streamPeers, { client = player.UserId, generation = activeGenerations[player],
            shared = phaseSnapshot.shared, targeted = phaseSnapshot.targeted,
            raw = finalSnapshot.raw, rawCounts = finalSnapshot.rawCounts, probe = streamProbe[player],
            clearObserved = clearObserved[player], invalidPayload = finalSnapshot.invalidPayload })
    end
    local streamFinalCounters = streamCounters()
    local streamDiagnostics = {
        coalesce = { sets = 3, immediateCountersUnchanged = true, latestValue = 0.75 },
        initialData = initialDataPhase,
        stopConfirmation = { broadcastHandoffs = stopConfirmationPhase.broadcastHandoffs,
            sendHandoffs = stopConfirmationPhase.sendHandoffs,
            outboundBytesCharged = stopConfirmationPhase.outboundBytesCharged,
            outboundByteRejected = stopConfirmationPhase.outboundByteRejected,
            lastSentTime = stopSentTime },
        suppression = { seconds = suppressionElapsed,
            windowSeconds = suppressionEndTime - suppressionStartTime,
            broadcastHandoffs = suppressionPhase.broadcastHandoffs,
            sendHandoffs = suppressionPhase.sendHandoffs,
            outboundBytesCharged = suppressionPhase.outboundBytesCharged,
            outboundByteRejected = suppressionPhase.outboundByteRejected,
            lastSentTimeBefore = stopSentTime, lastSentTimeAfter = suppressedStatus.lastSentTime },
        keepalive = { broadcastHandoffs = keepalivePhase.broadcastHandoffs,
            sendHandoffs = keepalivePhase.sendHandoffs,
            outboundBytesCharged = keepalivePhase.outboundBytesCharged,
            outboundByteRejected = keepalivePhase.outboundByteRejected,
            lastSentTime = keepaliveStatus.lastSentTime, sinceStopSeconds = keepaliveElapsed,
            minimumIntervalSeconds = minimumKeepaliveInterval },
        clear = { broadcastHandoffs = clearPhase.broadcastHandoffs, sendHandoffs = clearPhase.sendHandoffs,
            outboundBytesCharged = clearPhase.outboundBytesCharged,
            outboundByteRejected = clearPhase.outboundByteRejected,
            packetLength = 20, idle = clearStatus.state == "Idle", pending = clearStatus.pending,
            observedClients = clearObservedCount },
        targeted = { client = target.UserId, value = -12.5, packetLength = 24,
            sendHandoffs = targetedAfter.sendHandoffs - targetedBefore.sendHandoffs,
            broadcastHandoffs = targetedAfter.broadcastHandoffs - targetedBefore.broadcastHandoffs,
            outboundBytesCharged = targetedAfter.outboundBytesCharged - targetedBefore.outboundBytesCharged,
            destroyed = true, noLateHandoffOrCharge = unchangedCounters(beforeTargetCleanupWait, afterTargetCleanupWait) },
        sharedCleanup = { destroyed = true, noLateHandoffOrCharge = unchangedCounters(beforeSharedCleanupWait, afterSharedCleanupWait) },
        counters = { broadcastHandoffs = streamFinalCounters.broadcastHandoffs - streamBefore.broadcastHandoffs,
            sendHandoffs = streamFinalCounters.sendHandoffs - streamBefore.sendHandoffs,
            outboundBytesCharged = streamFinalCounters.outboundBytesCharged - streamBefore.outboundBytesCharged,
            outboundByteRejected = streamFinalCounters.outboundByteRejected - streamBefore.outboundByteRejected,
            sharedDataPacketLength = 24, clearPacketLength = 20, targetedPacketLength = 24,
            sharedBytesPerRecipient = 24 * 3 + 20, targetedBytesPerRecipient = 24 },
        peers = streamPeers,
    }
    local inputs = {}
    for _, player in roster do
        local delivered = values[player]
        assert(#delivered == (if player == target then 5 else 3)
            and delivered[1] == "maximum" and delivered[2] == "ten" and delivered[3] == "eleven",
            "native ordered server dispatch/refusals")
        if player == target then
            assert(delivered[4] == "maximum" and delivered[5] == "after-restart",
                "native restart counter and old-generation isolation")
        end
        table.insert(inputs, { client = player.UserId, values = table.clone(delivered), raw = rawCounts[player] })
    end
    local counters = session:GetDiagnostics().events.Input
    assert(counters.stale == #roster * 2 + 1 and counters.invalidPayload == #roster
        and maximumObserved == 900, "native ordered admission diagnostics and maximum")
    orderedUnreliableDiagnostics = { maximumFrameBytes = maximumObserved, c2s = inputs, s2c = outputs,
        stale = counters.stale, invalidPayload = counters.invalidPayload,
        restart = { client = target.UserId, before = generations[target], after = newGeneration }, streams = streamDiagnostics }
    all("ordered-destroy")
    rawObserver:Disconnect()
    session:Destroy()
    mark("ordered-unreliable-native")
end

local function nativeValuesCorrectness()
    local function matches(actual, expected)
        if #actual ~= #expected then return false end
        for index, name in expected do if actual[index] ~= name then return false end end
        return true
    end

    local diagnostics = { groups = {}, intrinsicEnums = NativeValues.policyEvidence(),
        nativeRejections = NativeValues.verifyNativeRejections() }
    for groupIndex, group in NativeValues.groups do
        if session then
            session:Destroy()
            session = nil
        end
        all("absent")

        local received, receivedCounts, failure = {}, {}, nil
        for _, player in roster do
            received[player] = {}
            receivedCounts[player] = {}
        end
        session = assert(Relay.createServer(NativeValues.create(groupIndex), { inboundRate = {
            perPlayer = { capacity = 128, refillPerSecond = 128 },
            aggregate = { capacity = 1024, refillPerSecond = 1024 },
        } }))
        assert(session.events.Input:Connect(function(player, payload)
            local kind = if type(payload) == "table" and type(payload.kind) == "string" then payload.kind else nil
            local sampleIndex = if kind == nil then 1 else (receivedCounts[player][kind] or 0) + 1
            local ok, name = pcall(NativeValues.check, groupIndex, payload, sampleIndex)
            if not ok then
                failure = tostring(name)
                return
            end
            table.insert(received[player], name)
            receivedCounts[player][name] = sampleIndex
            if name == "Font" then
                payload.value.Weight = Enum.FontWeight.Light
            end
        end))
        assert(session:Start())
        all("native-values-start", groupIndex)
        all("native-values-send")

        local cases = NativeValues.names(groupIndex)
        local expectedInputs = {}
        for _, name in cases do
            for _ = 1, NativeValues.repeatCount(name) do table.insert(expectedInputs, name) end
        end
        waitFor(function()
            if failure ~= nil then return true end
            for _, player in roster do
                if #received[player] ~= #expectedInputs then return false end
            end
            return true
        end, "native C2S receipts " .. group.name)
        assert(failure == nil, failure)
        local c2s = {}
        for _, player in roster do
            assert(matches(received[player], expectedInputs), "native C2S case order/count " .. group.name)
            table.insert(c2s, { client = player.UserId, cases = table.clone(received[player]) })
        end

        for _, name in cases do
            for sampleIndex = 1, NativeValues.repeatCount(name) do
                assert(session.events.Output:Broadcast(NativeValues.make(groupIndex, name, sampleIndex)))
            end
        end
        local s2c = {}
        for _, player in roster do
            local receivedCases = command(player, "native-values-read")
            assert(matches(receivedCases, expectedInputs), "native S2C case order/count " .. group.name)
            table.insert(s2c, { client = player.UserId, cases = receivedCases })
        end

        table.insert(diagnostics.groups, { name = group.name, cases = cases, c2s = c2s, s2c = s2c })
        all("native-values-destroy")
        session:Destroy()
        session = nil
        all("absent")
    end
    nativeValueDiagnostics = diagnostics
    mark("native-roblox-values")
end

local function instanceReferencesCorrectness()
    local classes = table.clone(InstanceValues.classes)
    local _, scopeRoot = InstanceValues.prepare()
    local sourceOnly = InstanceValues.serverOnly()
    local fullReceipts, fullFailure = {}, nil
    local missingInputCalls, missingInputFailure = {}, nil
    for _, player in roster do
        fullReceipts[player] = {}
        missingInputCalls[player] = 0
    end

    local function startInstanceSession(instanceRoot, byteCapacity, install)
        local bytes
        if byteCapacity ~= nil then
            bytes = {
                perPlayer = { capacity = byteCapacity, refillPerSecond = 0.000001 },
                aggregate = { capacity = byteCapacity, refillPerSecond = 0.000001 },
            }
        end
        local created, problem = Relay.createServer(InstanceValues.create(), {
            instanceRoot = instanceRoot,
            inboundRate = {
                perPlayer = { capacity = 128, refillPerSecond = 128 },
                aggregate = { capacity = 1024, refillPerSecond = 1024 },
                bytes = bytes,
            },
        })
        if not created then
            error("createServer Instance proof: " .. tostring(problem.code) .. ": " .. tostring(problem.message))
        end
        session = created
        install(session)
        assert(session:Start())
        local ingress, connection = observeInstanceIngress()
        all("instance-values-start", roster[1].UserId)
        return ingress, connection
    end

    if session then
        session:Destroy()
        session = nil
    end
    all("absent")
    local ingress, rawConnection = startInstanceSession(game, nil, function(server)
        assert(server.events.Input:Connect(function(player, value)
            local ok, receipt = pcall(InstanceValues.check, value, InstanceValues.objects(player),
                value.choice.kind, value.animator ~= nil)
            if not ok then
                fullFailure = tostring(receipt)
                return
            end
            table.insert(fullReceipts[player], receipt)
        end))
        assert(server.events.MissingInput:Connect(function(player, value)
            if value ~= InstanceValues.objects(player).rootFolder then
                missingInputFailure = "valid reference after a missing client-only reference changed identity"
                return
            end
            missingInputCalls[player] += 1
        end))
    end)

    all("instance-values-send")
    waitFor(function()
        if fullFailure ~= nil then return true end
        for _, player in roster do if #fullReceipts[player] ~= 2 then return false end end
        return true
    end, "reliable C2S native Instance identities", 20)
    assert(fullFailure == nil, fullFailure)
    local c2s = {}
    for _, player in roster do
        local cases = fullReceipts[player]
        assert(cases[1].branch == "Model" and not cases[1].animatorPresent
            and cases[2].branch == "Tool" and cases[2].animatorPresent,
            "C2S native Instance optional/union order")
        table.insert(c2s, { client = player.UserId, cases = table.clone(cases) })
    end

    local peerObjects = InstanceValues.objects(roster[1])
    for _, branch in { "Model", "Tool" } do
        assert(session.events.Output:Broadcast(InstanceValues.payload(peerObjects, branch, branch == "Tool")))
    end
    local s2c = {}
    for _, player in roster do
        local cases = command(player, "instance-values-read")
        assert(#cases == 2 and cases[1].branch == "Model" and not cases[1].animatorPresent
            and cases[2].branch == "Tool" and cases[2].animatorPresent,
            "S2C native Instance identity/optional/union order")
        table.insert(s2c, { client = player.UserId, cases = cases })
    end

    all("instance-missing-client-send")
    waitFor(function()
        return session:GetDiagnostics().events.MissingInput.invalidPayload == #roster
    end, "client-only references arrive missing and reject", 10)
    assert(missingInputFailure == nil, "missing-reference proof state")
    for _, player in roster do
        assert(missingInputCalls[player] == 0, "client-only reference reached a handler")
    end
    all("instance-missing-client-valid")
    waitFor(function()
        local count = 0
        for _, player in roster do count += missingInputCalls[player] end
        return count == #roster
    end, "valid reference after a missing C2S reference", 10)
    assert(missingInputFailure == nil, missingInputFailure)

    local missingOutputSent, missingOutputProblem = session.events.MissingOutput:Broadcast(sourceOnly)
    assert(missingOutputSent, missingOutputProblem and missingOutputProblem.code or "server-only S2C handoff")
    local missingOutput = {}
    for _, player in roster do
        table.insert(missingOutput, { client = player.UserId,
            result = command(player, "instance-missing-output-await") })
    end
    for _, row in missingOutput do
        assert(row.result.invalidPayload == 1 and row.result.dispatched == 0 and row.result.callbacks == 0
            and row.result.failure == nil, "ServerStorage reference arrived nil without dispatch")
    end
    assert(session.events.MissingOutput:Broadcast(peerObjects.rootFolder))
    for _, row in missingOutput do
        row.validAfter = command(Players:GetPlayerByUserId(row.client), "instance-missing-output-valid")
        assert(row.validAfter.dispatched == 1 and row.validAfter.callbacks == 1 and row.validAfter.failure == nil,
            "valid S2C reference after a missing reference")
    end

    local farModel, farPart = InstanceValues.prepareFar()
    assert(Workspace.StreamingEnabled, "Studio place must have Workspace.StreamingEnabled")
    local absences = {}
    for _, player in roster do
        table.insert(absences, { client = player.UserId, result = command(player, "instance-stream-absence") })
    end
    for _, row in absences do
        assert(row.result.streamingEnabled and row.result.containerPresent and row.result.partAbsent
            and row.result.stableSeconds >= 1,
            "far Workspace Part was not observably absent under its replicated model before send")
    end
    assert(session.events.StreamingOutput:Broadcast(farPart))
    local streaming = {}
    for _, player in roster do
        table.insert(streaming, { client = player.UserId, result = command(player, "instance-stream-await") })
    end
    for _, row in streaming do
        assert(row.result.streamingEnabled and row.result.containerPresent and row.result.partAbsent
            and row.result.invalidPayload == 1
            and row.result.dispatched == 0 and row.result.callbacks == 0 and row.result.failure == nil,
            "unstreamed native Part reference was rejected immediately without callback")
    end

    local rawEgress = {}
    for _, player in roster do
        table.insert(rawEgress, { client = player.UserId, frames = command(player, "instance-raw-read") })
    end
    local mainIngress = table.clone(ingress)
    rawConnection:Disconnect()

    local budgetFailure, budgetCalls = nil, 0
    all("instance-values-destroy")
    session:Destroy()
    session = nil
    all("absent")
    local scopeIngress, scopeRawConnection = startInstanceSession(scopeRoot, 22, function(server)
        assert(server.events.ScopedInput:Connect(function(player, first, second)
            assert(table.find(roster, player) ~= nil, "scoped byte-budget callback player is rostered")
            budgetCalls += 1
            local ok, receipt = pcall(InstanceValues.scopeReceipt, first, second)
            if not ok then
                budgetFailure = tostring(receipt)
                return
            end
            assert(receipt.first.className == "Folder" and receipt.second.className == "Part")
        end))
    end)

    all("instance-scope-outside")
    waitFor(function()
        local diagnostics = session:GetDiagnostics()
        return diagnostics.counters.aggregateBytes == #roster - 1
            and diagnostics.events.ScopedInput.invalidPayload == 1
    end, "scoped second reference rejection and aggregate byte debit", 10)
    assert(budgetCalls == 0, "out-of-root second reference dispatched partially")
    all("instance-scope-valid")
    waitFor(function()
        return session:GetDiagnostics().counters.perPlayerBytes == #roster
    end, "malformed scoped references retain per-player byte debit", 10)
    local budgetDiagnostics = session:GetDiagnostics()
    assert(budgetFailure == nil and budgetCalls == 0
        and budgetDiagnostics.counters.aggregateBytes == #roster - 1
        and budgetDiagnostics.counters.perPlayerBytes == #roster,
        "Instance reference byte admission charges remain after scope rejection")
    local budget = {
        invalidPayload = budgetDiagnostics.events.ScopedInput.invalidPayload,
        aggregateBytes = budgetDiagnostics.counters.aggregateBytes,
        perPlayerBytes = budgetDiagnostics.counters.perPlayerBytes,
        handlerCalls = budgetCalls,
        configuredBytes = 22,
    }

    all("instance-values-destroy")
    session:Destroy()
    session = nil
    all("absent")
    local scopeReceipts, scopeFailure, scopeCalls = {}, nil, 0
    local recoveredScope, recoveredRawConnection = startInstanceSession(scopeRoot, nil, function(server)
        assert(server.events.ScopedInput:Connect(function(player, first, second)
            assert(table.find(roster, player) ~= nil, "scoped recovery callback player is rostered")
            scopeCalls += 1
            local ok, receipt = pcall(InstanceValues.scopeReceipt, first, second)
            if not ok then
                scopeFailure = tostring(receipt)
                return
            end
            local objects = InstanceValues.scopeObjects()
            if first ~= objects.folder or second ~= objects.part then
                scopeFailure = "scoped C2S reference identity changed"
                return
            end
            table.insert(scopeReceipts, receipt)
        end))
    end)

    all("instance-scope-malformed")
    waitFor(function()
        return session:GetDiagnostics().events.ScopedInput.invalidPayload == #roster
    end, "duplicate later sidecar ordinal is rejected", 10)
    assert(scopeCalls == 0, "malformed later reference ordinal reached the handler")
    all("instance-scope-valid")
    waitFor(function()
        if scopeFailure ~= nil then return true end
        return #scopeReceipts == #roster
    end, "valid scoped C2S reference after malformed later slot", 10)
    assert(scopeFailure == nil and scopeCalls == #roster,
        "valid C2S reference after malformed frame: " .. tostring(scopeFailure))

    local scopeObjects = InstanceValues.scopeObjects()
    local handoffs = session:GetDiagnostics().events.ScopedOutput.broadcastHandoffs
    local destroyedReference = Instance.new("Folder")
    destroyedReference.Name = "RelayProofDestroyedReference"
    destroyedReference.Parent = scopeObjects.root
    destroyedReference:Destroy()
    local destroyedSent, destroyedProblem = session.events.ScopedOutput:Broadcast(destroyedReference, scopeObjects.part)
    assert(not destroyedSent and destroyedProblem.code == "InvalidPayload"
        and session:GetDiagnostics().events.ScopedOutput.broadcastHandoffs == handoffs,
        "destroyed reference rejects before handoff")
    scopeObjects.part.Parent = scopeObjects.outsidePart
    local sent, scopeProblem = session.events.ScopedOutput:Broadcast(scopeObjects.folder, scopeObjects.part)
    assert(not sent and scopeProblem.code == "InvalidPayload"
        and session:GetDiagnostics().events.ScopedOutput.broadcastHandoffs == handoffs,
        "reparented reference outside server root rejects before handoff")
    scopeObjects.part.Parent = scopeObjects.root
    assert(session.events.ScopedOutput:Broadcast(scopeObjects.folder, scopeObjects.part))
    local scopeOutputs = {}
    for _, player in roster do
        table.insert(scopeOutputs, {
            client = player.UserId,
            result = command(player, "instance-scope-read"),
            raw = command(player, "instance-raw-read"),
        })
    end
    for _, row in scopeOutputs do
        assert(row.result.calls == 1 and row.result.failure == nil
            and row.result.references.first.path == scopeObjects.folder:GetFullName()
            and row.result.references.second.path == scopeObjects.part:GetFullName(),
            "valid scoped S2C references preserve identities after reparent rejection")
    end
    local scopeHandoffsAfter = session:GetDiagnostics().events.ScopedOutput.broadcastHandoffs

    local malformedRaw = table.clone(recoveredScope)
    scopeRawConnection:Disconnect()
    recoveredRawConnection:Disconnect()
    all("instance-values-destroy")
    session:Destroy()
    session = nil
    all("absent")

    instanceReferenceDiagnostics = {
        classes = classes,
        s2cPlayer = roster[1].UserId,
        c2s = c2s,
        s2c = s2c,
        raw = { ingress = mainIngress, egress = rawEgress },
        missing = {
            clientToServer = {
                source = { name = "RelayProofClientOnlyFolder", className = "Folder", parent = "Workspace" },
                invalidPayload = #roster,
                callbacks = 0,
                validAfter = #roster,
            },
            serverToClient = {
                source = { name = sourceOnly.Name, className = sourceOnly.ClassName, parent = sourceOnly.Parent.ClassName,
                    path = sourceOnly:GetFullName() },
                callbacksBeforeValid = 0,
                clients = missingOutput,
            },
        },
        streaming = {
            enabled = Workspace.StreamingEnabled,
            farPath = farPart:GetFullName(),
            modelName = farModel.Name,
            absences = absences,
            clients = streaming,
        },
        scope = {
            budget = budget,
            budgetIngress = table.clone(scopeIngress),
            malformed = {
                invalidPayload = #roster,
                handlerCallsBeforeValid = 0,
                validAfter = #scopeReceipts,
                clients = #roster,
                rawIngress = malformedRaw,
            },
            outputs = {
                rejectedDestroyed = true,
                rejectedReparent = true,
                handoffsBefore = handoffs,
                handoffsAfter = scopeHandoffsAfter,
                delivered = scopeOutputs,
            },
        },
    }
    mark("native-instance-references")
end

local function quantizedCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")

    local numericServer = QuantizedValues.numericProbes()
    local gridInputs, wideInputs, rawIngress = {}, {}, {}
    for _, player in roster do
        gridInputs[player.UserId] = {}
        wideInputs[player.UserId] = {}
        rawIngress[player.UserId] = {}
    end
    local created, failure = Relay.createServer(QuantizedValues.create(false), { inboundRate = {
        perPlayer = { capacity = 128, refillPerSecond = 128 },
        aggregate = { capacity = 1024, refillPerSecond = 1024 },
        bytes = {
            perPlayer = { capacity = 25, refillPerSecond = 0.000001 },
            aggregate = { capacity = 25 * #roster, refillPerSecond = 0.000001 },
        },
    } })
    assert(created ~= nil, failure and failure.message or "quantized byte-budget server creation failed")
    session = created
    assert(session.events.Input:Connect(function(player, ...)
        table.insert(gridInputs[player.UserId], QuantizedValues.checkGrid(...))
    end))
    assert(session.events.WideInput:Connect(function(player, value)
        assert(value == 256, "quantized u16 server callback value")
        table.insert(wideInputs[player.UserId], value)
    end))
    assert(session:Start())
    local rawObserver = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpoint, packet)
        local row = QuantizedValues.rawReceipt(endpoint, packet)
        if row ~= nil and (row.eventId == 1 or row.eventId == 3) then
            row.client = player.UserId
            table.insert(rawIngress[player.UserId], row)
        end
    end)
    local numericClients = {}
    for _, player in roster do
        numericClients[player.UserId] = command(player, "quantized-start", false).numeric
    end
    all("quantized-send")
    waitFor(function()
        local diagnostics = session:GetDiagnostics()
        if diagnostics.counters.perPlayerBytes ~= #roster
            or diagnostics.events.Input.dispatched ~= #roster
            or diagnostics.events.WideInput.dispatched ~= #roster
            or diagnostics.events.WideInput.invalidPayload ~= 2 * #roster
        then return false end
        for _, player in roster do
            if #rawIngress[player.UserId] ~= 5 or #gridInputs[player.UserId] ~= 1
                or #wideInputs[player.UserId] ~= 1 then return false end
        end
        return true
    end, "quantized immediate values and exact byte boundary", 20)
    local budgetSnapshot = session:GetDiagnostics()
    assert(budgetSnapshot.counters.perPlayerBytes == #roster
        and budgetSnapshot.counters.aggregateBytes == 0
        and budgetSnapshot.counters.invalidPayload == 2 * #roster
        and budgetSnapshot.events.Input.invalidPayload == 0
        and budgetSnapshot.events.Input.dispatched == #roster
        and budgetSnapshot.events.WideInput.invalidPayload == 2 * #roster
        and budgetSnapshot.events.WideInput.dispatched == #roster,
        "quantized malformed values retain exact pre-decode byte admission")
    rawObserver:Disconnect()

    local rawEgress = {}
    for _, player in roster do
        assert(session.events.Output:Send(player, QuantizedValues.gridValues()))
        assert(session.events.WideOutput:Send(player, 256))
    end
    local gridOutputs, wideOutputs, clientRaw = {}, {}, {}
    for _, player in roster do
        local result = command(player, "quantized-read")
        assert(result.failure == nil and #result.grid == 1 and #result.wide == 1,
            "quantized immediate S2C callbacks")
        table.insert(gridOutputs, { client = player.UserId, value = result.grid[1] })
        table.insert(wideOutputs, { client = player.UserId, value = result.wide[1] })
        table.insert(clientRaw, { client = player.UserId, frames = result.raw })
        for _, row in result.raw do
            row.client = player.UserId
            table.insert(rawEgress, row)
        end
    end
    local immediate = {
        c2s = {}, s2c = gridOutputs,
        wideC2S = {}, wideS2C = wideOutputs,
        raw = { ingress = {}, egress = rawEgress },
        numeric = { server = numericServer, clients = {} },
        counters = {
            perPlayerBytes = budgetSnapshot.counters.perPlayerBytes,
            aggregateBytes = budgetSnapshot.counters.aggregateBytes,
            invalidPayload = budgetSnapshot.counters.invalidPayload,
            inputDispatched = budgetSnapshot.events.Input.dispatched,
            wideDispatched = budgetSnapshot.events.WideInput.dispatched,
            wideInvalidPayload = budgetSnapshot.events.WideInput.invalidPayload,
        },
    }
    for _, player in roster do
        table.insert(immediate.c2s, { client = player.UserId, value = gridInputs[player.UserId][1] })
        table.insert(immediate.wideC2S, { client = player.UserId, value = wideInputs[player.UserId][1] })
        table.insert(immediate.numeric.clients, { client = player.UserId, probes = numericClients[player.UserId] })
        for _, row in rawIngress[player.UserId] do table.insert(immediate.raw.ingress, row) end
    end

    all("quantized-destroy")
    session:Destroy()
    session = nil
    all("absent")

    local queueInputs, rpcInputs, routeRequests = {}, {}, {}
    for _, player in roster do
        queueInputs[player.UserId] = {}
        rpcInputs[player.UserId] = {}
    end
    local routeCreated, routeFailure = Relay.createServer(QuantizedValues.create(true), { inboundRate = {
        perPlayer = { capacity = 128, refillPerSecond = 128 },
        aggregate = { capacity = 1024, refillPerSecond = 1024 },
    } })
    assert(routeCreated ~= nil, routeFailure and routeFailure.message or "quantized route server creation failed")
    session = routeCreated
    assert(session.events.QueueInput:Connect(function(player, value)
        assert(value == 0.5, "quantized FIFO C2S round trip")
        table.insert(queueInputs[player.UserId], value)
    end))
    assert(session.requests.Echo:Connect(function(player, value)
        assert(value == 0.5, "quantized RPC request round trip")
        table.insert(rpcInputs[player.UserId], value)
        return value
    end))
    assert(session:Start())
    all("quantized-route-start")
    waitQueuedReady("QueueOutput", queuedPlayerIds(roster))
    for _, player in roster do
        routeRequests[player.UserId] = command(player, "quantized-route-send")
    end
    waitFor(function()
        for _, player in roster do
            if #queueInputs[player.UserId] ~= 1 or #rpcInputs[player.UserId] ~= 1 then return false end
        end
        return true
    end, "quantized RPC and FIFO request paths", 20)
    local queueReports = {}
    for _, player in roster do
        local batch, batchFailure = session:CreateBatch({ player }, 0.03)
        assert(batch ~= nil, batchFailure and batchFailure.message or "quantized FIFO S2C batch creation failed")
        assert(batch.events.QueueOutput:Send(0.25))
        local ok, flushFailure, report = batch:Flush()
        assert(ok, flushFailure and flushFailure.code or "quantized FIFO S2C flush failed")
        table.insert(queueReports, { client = player.UserId, report = report })
    end
    local queueOutputs = {}
    for _, player in roster do
        table.insert(queueOutputs, { client = player.UserId, value = command(player, "quantized-route-read") })
    end
    local routeSnapshot = session:GetDiagnostics()
    assert(routeSnapshot.counters.invalidPayload == 0 and routeSnapshot.counters.handlerErrors == 0
        and routeSnapshot.events.QueueInput.dispatched == #roster
        and routeSnapshot.counters.dispatched == 2 * #roster,
        "quantized RPC/FIFO routes dispatch valid values")
    local routes = { rpc = {}, queueC2S = {}, queueS2C = queueOutputs, queueReports = queueReports }
    for _, player in roster do
        table.insert(routes.rpc, { client = player.UserId, request = rpcInputs[player.UserId][1],
            response = routeRequests[player.UserId].response,
            queueReport = routeRequests[player.UserId].queueReport })
        table.insert(routes.queueC2S, { client = player.UserId, value = queueInputs[player.UserId][1] })
    end
    quantizedDiagnostics = { immediate = immediate, routes = routes }
    all("quantized-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("bounded-scalar-quantization")
end

local function compactNativeCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")

    local vector3Inputs, vector2Inputs, frameInputs, rawIngress = {}, {}, {}, {}
    for _, player in roster do
        vector3Inputs[player.UserId], vector2Inputs[player.UserId] = {}, {}
        frameInputs[player.UserId], rawIngress[player.UserId] = {}, {}
    end
    local created, failure = Relay.createServer(CompactTransport.createCompact(false), { inboundRate = {
        perPlayer = { capacity = 4096, refillPerSecond = 2048 },
        aggregate = { capacity = 32768, refillPerSecond = 16384 },
        bytes = {
            perPlayer = { capacity = 230, refillPerSecond = 0.000001 },
            aggregate = { capacity = 32768, refillPerSecond = 16384 },
        },
    } })
    assert(created ~= nil, failure and failure.message or "compact native server creation failed")
    session = created
    assert(session.events.Vector3Input:Connect(function(player, value)
        assert(player.Parent == Players, "compact Vector3 callback has the actual Player")
        table.insert(vector3Inputs[player.UserId], CompactTransport.checkVector3(value))
    end))
    assert(session.events.Vector2Input:Connect(function(player, value)
        assert(player.Parent == Players, "compact Vector2 callback has the actual Player")
        table.insert(vector2Inputs[player.UserId], CompactTransport.checkVector2(value))
    end))
    assert(session.events.FrameInput:Connect(function(player, ...)
        assert(player.Parent == Players, "compact CFrame callback has the actual Player")
        table.insert(frameInputs[player.UserId], CompactTransport.checkFrames(...))
    end))
    assert(session:Start())
    local rawObserver = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpoint, packet)
        local row = CompactTransport.rawReceipt(endpoint, packet)
        if row ~= nil and (row.eventId == 1 or row.eventId == 3 or row.eventId == 5) then
            row.client = player.UserId
            table.insert(rawIngress[player.UserId], row)
        end
    end)
    all("compact-start", false)
    all("compact-send")
    waitFor(function()
        local diagnostics = session:GetDiagnostics()
        if diagnostics.events.Vector3Input.dispatched ~= 2 * #roster
            or diagnostics.events.Vector2Input.dispatched ~= #roster
            or diagnostics.events.FrameInput.dispatched ~= #roster
            or diagnostics.counters.invalidPayload ~= 4 * #roster
            or diagnostics.counters.perPlayerBytes ~= #roster then return false end
        for _, player in roster do
            if #vector3Inputs[player.UserId] ~= 2 or #vector2Inputs[player.UserId] ~= 1
                or #frameInputs[player.UserId] ~= 1 or #rawIngress[player.UserId] ~= 8 then return false end
        end
        return true
    end, "compact native ingress, malformed rejection and recovery", 20)
    local beforeOutput = session:GetDiagnostics()
    assert(beforeOutput.events.Vector3Input.invalidPayload == 2 * #roster
        and beforeOutput.events.FrameInput.invalidPayload == 2 * #roster
        and beforeOutput.events.Vector2Input.invalidPayload == 0
        and beforeOutput.counters.perPlayerBytes == #roster
        and beforeOutput.counters.aggregateBytes == 0
        and beforeOutput.counters.handlerErrors == 0,
        "compact malformed buffers are byte charged, rejected before callbacks, and valid traffic recovers")

    local rawEgress, s2cVector3, s2cVector2, s2cFrames = {}, {}, {}, {}
    for _, player in roster do
        assert(session.events.Vector3Output:Send(player, CompactTransport.vector3Value()))
        assert(session.events.Vector2Output:Send(player, CompactTransport.vector2Value()))
        assert(session.events.FrameOutput:Send(player, CompactTransport.frameValues()))
    end
    for _, player in roster do
        local result = command(player, "compact-read")
        assert(result.failure == nil and #result.vector3 == 1 and #result.vector2 == 1
            and #result.frames == 1, "compact native S2C callback receipt")
        table.insert(s2cVector3, { client = player.UserId, value = result.vector3[1] })
        table.insert(s2cVector2, { client = player.UserId, value = result.vector2[1] })
        table.insert(s2cFrames, { client = player.UserId, values = result.frames[1] })
        for _, row in result.raw do
            row.client = player.UserId
            table.insert(rawEgress, row)
        end
    end
    local ingressRows = {}
    for _, player in roster do
        for _, row in rawIngress[player.UserId] do table.insert(ingressRows, row) end
    end
    rawObserver:Disconnect()
    local counters = session:GetDiagnostics()
    compactTransportDiagnostics = compactTransportDiagnostics or {}
    compactTransportDiagnostics.compact = {
        c2sVector3 = {}, c2sVector2 = {}, c2sFrames = {},
        s2cVector3 = s2cVector3, s2cVector2 = s2cVector2, s2cFrames = s2cFrames,
        raw = { ingress = ingressRows, egress = rawEgress },
        counters = {
            invalidPayload = counters.counters.invalidPayload,
            vector3Invalid = counters.events.Vector3Input.invalidPayload,
            frameInvalid = counters.events.FrameInput.invalidPayload,
            vector3Dispatched = counters.events.Vector3Input.dispatched,
            vector2Dispatched = counters.events.Vector2Input.dispatched,
            frameDispatched = counters.events.FrameInput.dispatched,
            perPlayerByteRejected = counters.counters.perPlayerBytes,
            aggregateByteRejected = counters.counters.aggregateBytes,
        },
    }
    for _, player in roster do
        table.insert(compactTransportDiagnostics.compact.c2sVector3,
            { client = player.UserId, value = vector3Inputs[player.UserId][1],
                recovery = vector3Inputs[player.UserId][2] })
        table.insert(compactTransportDiagnostics.compact.c2sVector2,
            { client = player.UserId, value = vector2Inputs[player.UserId][1] })
        table.insert(compactTransportDiagnostics.compact.c2sFrames,
            { client = player.UserId, values = frameInputs[player.UserId][1] })
    end
    all("compact-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("compact-native-values")
end

local function outboundBudgetCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    local inbound = {
        perPlayer = { capacity = 4096, refillPerSecond = 2048 },
        aggregate = { capacity = 32768, refillPerSecond = 16384 },
    }

    local function start(kind, handler)
        local created, problem = Relay.createServer(CompactTransport.createBudget(kind, true), { inboundRate = inbound })
        assert(created ~= nil, problem and problem.message or "outbound budget server creation failed")
        session = created
        if handler ~= nil then assert(handler(session)) end
        assert(session:Start())
        all("budget-start", kind)
        waitQueuedReady("QueueOutput", queuedPlayerIds(roster))
        all("budget-arm", kind)
        return session:GetDiagnostics().counters.sendHandoffs
    end

    local fanoutControlHandoffs = start("fanout")
    local exhausted, healthy = roster[1], roster[2]
    local directOk = {}
    for index = 1, 2 do
        local ok, problem = session.events.Pulse:Send(exhausted, true)
        directOk[index] = ok == true and problem == nil
    end
    local targetedOk, targetedFailure = session.events.Pulse:Send(exhausted, false)
    local broadcastOk, broadcastFailure = session.events.Pulse:Broadcast(false)
    local healthyOk, healthyFailure, sendToOk, sendToFailure, exceptOk, exceptFailure
    if healthy ~= nil then
        healthyOk, healthyFailure = session.events.Pulse:Send(healthy, true)
        sendToOk, sendToFailure = session.events.Pulse:SendTo({ healthy }, false)
        exceptOk, exceptFailure = session.events.Pulse:SendExcept({ exhausted }, true)
        assert(healthyOk and healthyFailure == nil and sendToOk and sendToFailure == nil
            and not exceptOk and exceptFailure.code == "OutboundRateLimited",
            "outbound healthy-player debit and exhausted send-except refusal")
    end
    assert(directOk[1] and directOk[2] and not targetedOk and targetedFailure.code == "OutboundRateLimited"
        and not broadcastOk and broadcastFailure.code == "OutboundRateLimited",
        "outbound targeted/fanout refusal and no-debit recovery")
    local fanoutClients = {}
    for _, player in roster do
        local received = command(player, "budget-read", "fanout")
        assert(received.pulses ~= nil and #received.pulses == 2 and #received.raw == 2,
            "outbound broadcast refusal performs no partial native handoff")
        table.insert(fanoutClients, { client = player.UserId, values = received.pulses,
            raw = received.raw })
    end
    local fanoutDiagnostics = session:GetDiagnostics()
    compactTransportDiagnostics.outboundFanout = {
        attempts = { first = directOk[1], second = directOk[2], targeted = targetedOk,
            broadcast = broadcastOk },
        failures = { targeted = targetedFailure and targetedFailure.code,
            broadcast = broadcastFailure and broadcastFailure.code },
        clients = fanoutClients,
        counters = { rejected = fanoutDiagnostics.counters.outboundByteRejected,
            charged = fanoutDiagnostics.counters.outboundBytesCharged,
            handoffs = fanoutDiagnostics.counters.sendHandoffs - fanoutControlHandoffs,
            controlHandoffs = fanoutControlHandoffs,
            broadcasts = fanoutDiagnostics.counters.broadcastHandoffs },
    }
    if healthy ~= nil then
        compactTransportDiagnostics.outboundFanout.attempts.healthy = healthyOk
        compactTransportDiagnostics.outboundFanout.attempts.sendTo = sendToOk
        compactTransportDiagnostics.outboundFanout.attempts.sendExcept = exceptOk
        compactTransportDiagnostics.outboundFanout.failures.except = exceptFailure and exceptFailure.code
    end
    all("budget-destroy")
    session:Destroy()
    session = nil
    all("absent")

    local rpcCalls = {}
    for _, player in roster do rpcCalls[player.UserId] = 0 end
    start("rpc", function(server)
        return server.requests.Echo:Connect(function(player, value)
            assert(player.Parent == Players and value == true, "outbound RPC handler receives checked request")
            rpcCalls[player.UserId] += 1
            return true
        end)
    end)
    local rpcResults = {}
    for _, player in roster do
        local response = command(player, "budget-rpc")
        local received = command(player, "budget-read", "rpc")
        table.insert(rpcResults, { client = player.UserId, result = response, raw = received.rpcRaw,
            otherFrames = #received.other,
            handlerCalls = rpcCalls[player.UserId] })
    end
    local rpcSnapshot = session:GetDiagnostics()
    compactTransportDiagnostics.outboundRpc = {
        clients = rpcResults,
        counters = { rejected = rpcSnapshot.counters.outboundByteRejected,
            charged = rpcSnapshot.counters.outboundBytesCharged,
            dispatched = rpcSnapshot.counters.dispatched,
            handlerErrors = rpcSnapshot.counters.handlerErrors },
    }
    all("budget-destroy")
    session:Destroy()
    session = nil
    all("absent")

    local queueControlHandoffs = start("queues")
    local queueRows = {}
    for _, player in roster do
        local batch, batchFailure = session:CreateBatch({ player }, 0.1)
        assert(batch ~= nil, batchFailure and batchFailure.message or "outbound batch setup")
        assert(batch.events.QueueOutput:Send(true))
        local batchOk, batchError, batchReport = batch:Flush()
        local batchBefore = batch:GetStatus()
        batch:Cancel()
        local batchAfter = batch:GetStatus()

        local state, stateFailure = session:CreateState({ player }, 0.1)
        assert(state ~= nil, stateFailure and stateFailure.message or "outbound State setup")
        assert(state.events.StateOutput:Put(1, "Normal", true))
        local stateOk, stateError, stateReport = state:Flush()
        local stateBefore = state:GetStatus()
        state:Destroy()
        local stateAfter = state:GetStatus()

        assert(not batchOk and batchError.code == "OutboundRateLimited"
            and batchBefore.state == "Open" and batchBefore.pendingRecords == 1
            and batchBefore.lastFlush.error.code == "OutboundRateLimited"
            and batchReport.selected == 0 and batchReport.remaining == 1
            and batchAfter.state == "Terminal" and batchAfter.pendingRecords == 0
            and not stateOk and stateError.code == "OutboundRateLimited"
            and stateBefore.state == "Open" and stateBefore.pendingKeys == 1
            and stateBefore.lastFlush.error.code == "OutboundRateLimited"
            and stateReport.selected == 0 and stateReport.remaining == 1
            and stateAfter.state == "Destroyed" and stateAfter.pendingKeys == 0,
            "outbound Batch and State refusals retain records and clean up explicitly")
        local received = command(player, "budget-read", "queue")
        assert(#received.pulses == 0 and #received.queues == 0 and #received.states == 0
            and #received.raw == 0 and #received.rpcRaw == 0 and #received.other == 0,
            "outbound Batch/State refusal has no native packet or callback")
        table.insert(queueRows, { client = player.UserId,
            batch = { state = batchBefore.state, pending = batchBefore.pendingRecords,
                lastError = batchBefore.lastFlush.error.code, selected = batchReport.selected,
                remaining = batchReport.remaining, cleanupState = batchAfter.state,
                cleanupPending = batchAfter.pendingRecords },
            state = { state = stateBefore.state, pending = stateBefore.pendingKeys,
                lastError = stateBefore.lastFlush.error.code, selected = stateReport.selected,
                remaining = stateReport.remaining, cleanupState = stateAfter.state,
                cleanupPending = stateAfter.pendingKeys },
            received = { pulses = #received.pulses, queues = #received.queues,
                states = #received.states, raw = #received.raw,
                rpcRaw = #received.rpcRaw, other = #received.other } })
    end
    local queueSnapshot = session:GetDiagnostics()
    compactTransportDiagnostics.outboundQueues = {
        clients = queueRows,
        counters = { rejected = queueSnapshot.counters.outboundByteRejected,
            charged = queueSnapshot.counters.outboundBytesCharged,
            handoffs = queueSnapshot.counters.sendHandoffs - queueControlHandoffs,
            controlHandoffs = queueControlHandoffs },
    }
    all("budget-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("outbound-byte-backpressure")
end

local function packedFlagsCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")

    local tuples, arrays, records, rawIngress = {}, {}, {}, {}
    for _, player in roster do
        tuples[player.UserId], arrays[player.UserId], records[player.UserId] = {}, {}, {}
        rawIngress[player.UserId] = {}
    end
    local created, failure = Relay.createServer(CompactTransport.createPacked(false), { inboundRate = {
        perPlayer = { capacity = 4096, refillPerSecond = 2048 },
        aggregate = { capacity = 32768, refillPerSecond = 16384 },
        bytes = {
            perPlayer = { capacity = 88, refillPerSecond = 0.000001 },
            aggregate = { capacity = 32768, refillPerSecond = 16384 },
        },
    } })
    assert(created ~= nil, failure and failure.message or "packed flags server creation failed")
    session = created
    assert(session.events.Input:Connect(function(player, ...)
        table.insert(tuples[player.UserId], CompactTransport.packedTupleObservation(...))
    end))
    assert(session.events.ArrayInput:Connect(function(player, ...)
        table.insert(arrays[player.UserId], CompactTransport.packedArrayObservation(...))
    end))
    assert(session.events.StructInput:Connect(function(player, value)
        table.insert(records[player.UserId], CompactTransport.packedRecordObservation(value))
    end))
    assert(session:Start())
    local rawObserver = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpoint, packet)
        local row = CompactTransport.packedRawReceipt(endpoint, packet)
        if row ~= nil and (row.eventId == 1 or row.eventId == 3 or row.eventId == 5) then
            row.client = player.UserId
            table.insert(rawIngress[player.UserId], row)
        end
    end)
    all("packed-start", false)
    all("packed-send")
    waitFor(function()
        local diagnostics = session:GetDiagnostics()
        if diagnostics.events.Input.dispatched ~= 2 * #roster
            or diagnostics.events.ArrayInput.dispatched ~= 2 * #roster
            or diagnostics.events.StructInput.dispatched ~= 2 * #roster
            or diagnostics.counters.invalidPayload ~= 6 * #roster
            or diagnostics.counters.perPlayerBytes ~= #roster then return false end
        for _, player in roster do
            if #tuples[player.UserId] ~= 2 or #arrays[player.UserId] ~= 2
                or #records[player.UserId] ~= 2 or #rawIngress[player.UserId] ~= 12 then return false end
        end
        return true
    end, "packed malformed masks reject atomically and later valid frames recover", 20)
    local beforeOutput = session:GetDiagnostics()
    assert(beforeOutput.events.Input.invalidPayload == 4 * #roster
        and beforeOutput.events.ArrayInput.invalidPayload == 2 * #roster
        and beforeOutput.events.StructInput.invalidPayload == 0
        and beforeOutput.counters.perPlayerBytes == #roster
        and beforeOutput.counters.aggregateBytes == 0
        and beforeOutput.counters.handlerErrors == 0,
        "packed padding, enum, optional bits and truncation reject before handlers; exact byte budget blocks the trailing probe")

    for _, player in roster do
        assert(session.events.Output:Send(player, CompactTransport.packedTupleValues()))
        assert(session.events.ArrayOutput:Send(player, CompactTransport.packedArrays()))
        assert(session.events.StructOutput:Send(player, CompactTransport.packedRecord()))
    end
    local rawEgress, outputs = {}, { tuple = {}, arrays = {}, records = {} }
    for _, player in roster do
        local result = command(player, "packed-read")
        assert(result.failure == nil and #result.tuple == 1 and #result.arrays == 1
            and #result.records == 1, "packed S2C actual callback receipt")
        outputs.tuple[#outputs.tuple + 1] = { client = player.UserId, value = result.tuple[1] }
        outputs.arrays[#outputs.arrays + 1] = { client = player.UserId, value = result.arrays[1] }
        outputs.records[#outputs.records + 1] = { client = player.UserId, value = result.records[1] }
        for _, row in result.raw do
            row.client = player.UserId
            table.insert(rawEgress, row)
        end
    end
    local ingressRows, inputRows = {}, { tuple = {}, arrays = {}, records = {} }
    for _, player in roster do
        for _, row in rawIngress[player.UserId] do table.insert(ingressRows, row) end
        table.insert(inputRows.tuple, { client = player.UserId, values = table.clone(tuples[player.UserId]) })
        table.insert(inputRows.arrays, { client = player.UserId, values = table.clone(arrays[player.UserId]) })
        table.insert(inputRows.records, { client = player.UserId, values = table.clone(records[player.UserId]) })
    end
    rawObserver:Disconnect()
    local counters = session:GetDiagnostics()
    compactTransportDiagnostics.packed = {
        input = inputRows,
        output = outputs,
        raw = { ingress = ingressRows, egress = rawEgress },
        counters = { invalidPayload = counters.counters.invalidPayload,
            tupleInvalid = counters.events.Input.invalidPayload,
            arrayInvalid = counters.events.ArrayInput.invalidPayload,
            tupleDispatched = counters.events.Input.dispatched,
            arrayDispatched = counters.events.ArrayInput.dispatched,
            structDispatched = counters.events.StructInput.dispatched,
            perPlayerByteRejected = counters.counters.perPlayerBytes,
            aggregateByteRejected = counters.counters.aggregateBytes,
            handlerErrors = counters.counters.handlerErrors },
    }
    all("packed-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("packed-flags-enums")
end

local function compactTransportCorrectness()
    compactTransportDiagnostics = {}
    compactNativeCorrectness()
    outboundBudgetCorrectness()
    packedFlagsCorrectness()
end

local function bufferDeferralCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    local inputValues, rawIngress = {}, {}
    for _, player in roster do
        inputValues[player.UserId] = {}
        rawIngress[player.UserId] = {}
    end
    local created, failure = Relay.createServer(BufferDeferral.createBuffers(false), { inboundRate = {
        perPlayer = { capacity = 128, refillPerSecond = 128 },
        aggregate = { capacity = 1024, refillPerSecond = 1024 },
        bytes = {
            perPlayer = { capacity = 49, refillPerSecond = 0.000001 },
            aggregate = { capacity = 49 * #roster, refillPerSecond = 0.000001 },
        },
    } })
    assert(created ~= nil, failure and failure.message or "native buffer server creation failed")
    session = created
    assert(session.events.Input:Connect(function(player, value)
        table.insert(inputValues[player.UserId], BufferDeferral.bytesArray(value))
    end))
    assert(session:Start())
    all("buffer-start")
    all("buffer-arm")

    local rawObserver = ReplicatedStorage.RelayRemotes.Reliable.OnServerEvent:Connect(function(player, endpoint, ...)
        if select("#", ...) ~= 1 then return end
        local packet = ...
        if endpoint == 1 then
            local row = BufferDeferral.rawReceipt(endpoint, packet)
            if row ~= nil then
                row.client = player.UserId
                table.insert(rawIngress[player.UserId], row)
            end
        end
    end)

    local localSendResults = {}
    for _, player in roster do localSendResults[player.UserId] = command(player, "buffer-send") end
    waitFor(function()
        local counters = session:GetDiagnostics()
        if counters.events.Input.dispatched ~= 2 * #roster
            or counters.events.Input.invalidPayload ~= 4 * #roster
            or counters.counters.perPlayerBytes ~= #roster then return false end
        for _, player in roster do
            if #inputValues[player.UserId] ~= 2 or #rawIngress[player.UserId] ~= 7 then return false end
        end
        return true
    end, "bounded buffer valid, malformed, and byte-refused immediate C2S", 20)
    local beforeOutput = session:GetDiagnostics()
    assert(beforeOutput.events.Input.dispatched == 2 * #roster
        and beforeOutput.events.Input.invalidPayload == 4 * #roster
        and beforeOutput.counters.perPlayerBytes == #roster
        and beforeOutput.counters.aggregateBytes == 0
        and beforeOutput.counters.handlerErrors == 0,
        "bounded buffer malformed frames are charged, rejected atomically, and permit recovery")

    local queueReports = {}
    for _, player in roster do
        assert(session.events.Output:Send(player, BufferDeferral.outputValue()))
        local batch, batchFailure = session:CreateBatch({ player }, 0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message or "buffer snapshot batch creation failed")
        local source = BufferDeferral.queuedSource()
        assert(batch.events.QueuedOutput:Send(source))
        for offset = 0, buffer.len(source) - 1 do buffer.writeu8(source, offset, 99) end
        local flushOk, flushFailure, report = batch:Flush()
        assert(flushOk, flushFailure and flushFailure.code or "buffer snapshot batch flush failed")
        assert(report.selected == 1 and report.reliableHandoffs == 1 and report.logicalHandoffs == 1,
            "buffer snapshot is sent in one reliable Batch frame")
        table.insert(queueReports, { client = player.UserId, selected = report.selected,
            reliableHandoffs = report.reliableHandoffs, logicalHandoffs = report.logicalHandoffs })
    end

    local clients, rawEgress, rawQueuedEgress = {}, {}, {}
    for _, player in roster do
        local result = command(player, "buffer-read")
        assert(result.failure == nil and #result.output == 1 and #result.queued == 1,
            "native buffer immediate and queued S2C callbacks")
        table.insert(clients, { client = player.UserId, input = table.clone(inputValues[player.UserId]),
            output = result.output[1], queued = result.queued[1], send = localSendResults[player.UserId] })
        for _, row in result.raw do
            row.client = player.UserId
            table.insert(rawEgress, row)
        end
        for _, row in result.queuedRaw do
            row.client = player.UserId
            table.insert(rawQueuedEgress, row)
        end
    end
    local ingressRows = {}
    for _, player in roster do
        for _, row in rawIngress[player.UserId] do table.insert(ingressRows, row) end
    end
    rawObserver:Disconnect()
    local counters = session:GetDiagnostics()
    bufferDeferralDiagnostics = {
        clients = clients,
        queueReports = queueReports,
        raw = { ingress = ingressRows, egress = rawEgress, queuedEgress = rawQueuedEgress },
        counters = {
            invalidPayload = counters.counters.invalidPayload,
            inputInvalid = counters.events.Input.invalidPayload,
            inputDispatched = counters.events.Input.dispatched,
            perPlayerByteRejected = counters.counters.perPlayerBytes,
            aggregateByteRejected = counters.counters.aggregateBytes,
            handlerErrors = counters.counters.handlerErrors,
        },
    }
    all("buffer-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("bounded-native-buffers")
end

local function stateStatusSnapshot(state)
    local status = state:GetStatus()
    local flush = status.lastFlush
    local report = if flush == nil then nil else flush.report
    return {
        state = status.state,
        pendingKeys = status.pendingKeys,
        pendingBodyBytes = status.pendingBodyBytes,
        lastFlush = if flush == nil then nil else {
            ok = flush.ok,
            error = flush.error and flush.error.code,
            report = report and { selected = report.selected, remaining = report.remaining,
                expired = report.expired, logicalHandoffs = report.logicalHandoffs },
        },
    }
end

local function stateCounterSnapshot(before)
    local counters = session:GetDiagnostics().counters
    return {
        charged = counters.outboundBytesCharged - before.charged,
        rejected = counters.outboundByteRejected - before.rejected,
        handoffs = counters.sendHandoffs - before.handoffs,
    }
end

local function stateDeferralCorrectness()
    local target = roster[1]

    local function finishState(state)
        all("state-destroy")
        if state ~= nil then state:Destroy() end
        if session then session:Destroy() session = nil end
        all("absent")
    end

    local function startState()
        if session then session:Destroy() session = nil end
        all("absent")
        local created, failure = Relay.createServer(BufferDeferral.createStateDeferral(true), { inboundRate = {
            perPlayer = { capacity = 128, refillPerSecond = 128 },
            aggregate = { capacity = 1024, refillPerSecond = 1024 },
        } })
        assert(created ~= nil, failure and failure.message or "State deferral server creation failed")
        session = created
        assert(session:Start())
        all("state-start")
        local ids = queuedPlayerIds(roster)
        waitQueuedReady("Pulse", ids)
        waitQueuedReady("StateOutput", ids)
        all("state-arm")
        local counters = session:GetDiagnostics().counters
        return {
            charged = counters.outboundBytesCharged,
            rejected = counters.outboundByteRejected,
            handoffs = counters.sendHandoffs,
        }
    end

    local function precharge(before)
        for _ = 1, 3 do assert(session.events.Pulse:Send(target, BufferDeferral.prechargeValue())) end
        local read = command(target, "state-read", { pulses = 3, pulseRaw = 3 })
        assert(read.failure == nil and #read.pulses == 3 and #read.pulseRaw == 3
            and #read.states == 0 and #read.stateRaw == 0,
            "native State budget precharge callbacks and raw frames")
        local counters = session:GetDiagnostics().counters
        assert(counters.outboundBytesCharged - before.charged == 27
            and counters.outboundByteRejected == before.rejected,
            "three four-byte Pulse payloads use 9-byte frames and precharge exactly 27 outbound bytes")
        return read
    end

    local function newDeferredState(flushAfter)
        local created, failure = session:CreateState({ target }, flushAfter or 0.05, { deferOutbound = true })
        assert(created ~= nil, failure and failure.message or "single-player deferred State creation failed")
        return created
    end

    local function waitForRefusal(state, pending, label)
        waitFor(function()
            local status = state:GetStatus()
            return status.pendingKeys == pending and status.lastFlush ~= nil
                and status.lastFlush.error ~= nil and status.lastFlush.error.code == "OutboundRateLimited"
        end, label, 3)
        return stateStatusSnapshot(state)
    end

    local function waitForService(state, label)
        waitFor(function()
            local status = state:GetStatus()
            return status.pendingKeys == 0 and status.lastFlush ~= nil
                and status.lastFlush.error == nil and status.lastFlush.ok == true
        end, label, 3)
        return stateStatusSnapshot(state)
    end

    stateDeferralDiagnostics = {}

    local before = startState()
    precharge(before)
    local automatic = newDeferredState()
    assert(automatic.events.StateOutput:Put(1, "Normal", BufferDeferral.smallStateValue()))
    local firstAutomatic = waitForRefusal(automatic, 1, "deferred State initial outbound refusal")
    local finalAutomatic = waitForService(automatic, "State automatically retries after refill")
    local automaticRead = command(target, "state-read", { pulses = 3, pulseRaw = 3, states = 1, stateRaw = 1 })
    stateDeferralDiagnostics.automatic = { client = target.UserId, first = firstAutomatic,
        final = finalAutomatic, result = automaticRead, counters = stateCounterSnapshot(before) }
    finishState(automatic)

    before = startState()
    precharge(before)
    local replacement = newDeferredState()
    local original = BufferDeferral.largeStateValue()
    assert(replacement.events.StateOutput:Put(2, "Normal", original))
    local firstReplacement = waitForRefusal(replacement, 1, "deferred State replacement initial refusal")
    for offset = 0, buffer.len(original) - 1 do buffer.writeu8(original, offset, 99) end
    task.wait(0.1)
    local replacementValue = BufferDeferral.replacementStateValue()
    assert(replacement.events.StateOutput:Put(2, "Normal", replacementValue))
    buffer.writeu8(replacementValue, 0, 99)
    local finalReplacement = waitForService(replacement, "smaller replacement automatically reaches the native client")
    local replacementRead = command(target, "state-read", { pulses = 3, pulseRaw = 3, states = 1, stateRaw = 1 })
    stateDeferralDiagnostics.replacement = { client = target.UserId, first = firstReplacement,
        final = finalReplacement, result = replacementRead, counters = stateCounterSnapshot(before) }
    finishState(replacement)

    before = startState()
    precharge(before)
    local ageLane = newDeferredState()
    local oldValue = BufferDeferral.largeStateValue()
    assert(ageLane.events.StateOutput:Put(3, "Normal", oldValue))
    local firstAge = waitForRefusal(ageLane, 1, "deferred State age-boundary initial refusal")
    task.wait(0.55)
    local middleValue = BufferDeferral.middleStateValue()
    assert(ageLane.events.StateOutput:Put(3, "Normal", middleValue))
    for offset = 0, buffer.len(middleValue) - 1 do buffer.writeu8(middleValue, offset, 99) end
    local replacedPending = stateStatusSnapshot(ageLane)
    waitFor(function()
        local status = ageLane:GetStatus()
        return status.pendingKeys == 0 and status.lastFlush ~= nil and status.lastFlush.ok == true
    end, "replacement retains the original first-dirty expiry", 3)
    local finalAge = stateStatusSnapshot(ageLane)
    local ageRead = command(target, "state-read", { pulses = 3, pulseRaw = 3 })
    stateDeferralDiagnostics.replacementAge = { client = target.UserId, first = firstAge,
        replaced = replacedPending, final = finalAge, result = ageRead, counters = stateCounterSnapshot(before) }
    finishState(ageLane)

    before = startState()
    precharge(before)
    local impossible = newDeferredState()
    assert(impossible.events.StateOutput:Put(4, "Normal", BufferDeferral.largeStateValue()))
    local firstImpossible = waitForRefusal(impossible, 1, "over-capacity State packet refusal")
    waitFor(function()
        local status = impossible:GetStatus()
        return status.pendingKeys == 0 and status.lastFlush ~= nil and status.lastFlush.ok == true
    end, "over-capacity State record expires without retry polling", 3)
    local finalImpossible = stateStatusSnapshot(impossible)
    local impossibleRead = command(target, "state-read", { pulses = 3, pulseRaw = 3 })
    stateDeferralDiagnostics.impossible = { client = target.UserId, first = firstImpossible,
        final = finalImpossible, result = impossibleRead, counters = stateCounterSnapshot(before) }
    finishState(impossible)

    before = startState()
    precharge(before)
    local survivor = newDeferredState(0.1)
    assert(survivor.events.StateOutput:Put(5, "Normal", BufferDeferral.largeStateValue()))
    waitForRefusal(survivor, 1, "older over-capacity State record refusal")
    task.wait(0.3)
    assert(survivor.events.StateOutput:Put(6, "Normal", BufferDeferral.survivorStateValue()))
    local combinedOk, combinedFailure, combinedReport = survivor:Flush()
    assert(not combinedOk and combinedFailure.code == "OutboundRateLimited"
        and combinedReport.selected == 0 and combinedReport.remaining == 2,
        "explicit setup flush records combined State capacity refusal without consuming either key")
    local firstSurvivor = stateStatusSnapshot(survivor)
    waitForService(survivor, "surviving State record automatically retries after older expiry")
    local finalSurvivor = stateStatusSnapshot(survivor)
    local survivorRead = command(target, "state-read", { pulses = 3, pulseRaw = 3, states = 1, stateRaw = 1 })
    stateDeferralDiagnostics.survivor = { client = target.UserId, first = firstSurvivor,
        final = finalSurvivor, result = survivorRead, counters = stateCounterSnapshot(before) }
    finishState(survivor)

    before = startState()
    precharge(before)
    local destroyed = newDeferredState()
    assert(destroyed.events.StateOutput:Put(7, "Normal", BufferDeferral.smallStateValue()))
    local firstDestroyed = waitForRefusal(destroyed, 1, "destroyed State lane initial refusal")
    destroyed:Destroy()
    local destroyedStatus = stateStatusSnapshot(destroyed)
    task.wait(0.45)
    local destroyedRead = command(target, "state-read", { pulses = 3, pulseRaw = 3 })
    stateDeferralDiagnostics.destroy = { client = target.UserId, first = firstDestroyed,
        final = destroyedStatus, result = destroyedRead, counters = stateCounterSnapshot(before) }
    finishState(destroyed)

    mark("single-player-state-deferral")
end

local function rpcBoundedRoutesCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    local _, scopeRoot = InstanceValues.prepare()
    local scope = InstanceValues.scopeObjects()
    local inputNames = { "Input", "UnreliableInput", "OrderedInput", "QueueInput", "UnreliableQueueInput", "StateInput" }
    local serverValues, routeFailures, rawIngress = {}, {}, {}
    for _, player in roster do
        serverValues[player.UserId] = {}
        routeFailures[player.UserId] = nil
    end
    local function addReference(player, name, ...)
        local values = table.pack(...)
        local ok, receipt = pcall(RpcBoundedRoutes.checkReferences,
            values[1], values[2], values[3], player)
        if not ok then routeFailures[player.UserId] = tostring(receipt) return end
        local rows = serverValues[player.UserId][name]
        if rows == nil then rows = {} serverValues[player.UserId][name] = rows end
        table.insert(rows, receipt)
    end
    local created, problem = Relay.createServer(RpcBoundedRoutes.create(), {
        instanceRoot = scopeRoot,
        inboundRate = {
            perPlayer = { capacity = 512, refillPerSecond = 256 },
            aggregate = { capacity = 4096, refillPerSecond = 2048 },
        },
    })
    assert(created ~= nil, problem and problem.message or "RPC/bounded route server creation")
    session = created
    for _, name in inputNames do
        assert(session.events[name]:Connect(function(player, ...)
            addReference(player, name, ...)
        end))
    end
    assert(session.events.NumericInput:Connect(function(player, ...)
        local ok, value = pcall(RpcBoundedRoutes.checkNumeric, ...)
        if not ok then routeFailures[player.UserId] = tostring(value) return end
        serverValues[player.UserId].numeric = value
    end))
    assert(session.events.BoundedInput:Connect(function(player, value)
        local ok, result = pcall(RpcBoundedRoutes.checkBounded, value)
        if not ok then routeFailures[player.UserId] = tostring(result) return end
        serverValues[player.UserId].bounded = result
    end))
    assert(session.events.MinimumInput:Connect(function(player, value)
        local rows = serverValues[player.UserId].minimum or {}
        serverValues[player.UserId].minimum = rows
        table.insert(rows, value)
    end))
    assert(session.events.LegacyInput:Connect(function(player, value)
        serverValues[player.UserId].legacy = value
    end))
    assert(session.events.LegacyQueueInput:Connect(function(player, value)
        local rows = serverValues[player.UserId].legacyQueued or {}
        serverValues[player.UserId].legacyQueued = rows
        table.insert(rows, value)
    end))

    local echoCalls = {}
    assert(session.requests.Echo:Connect(function(player, value)
        local expected = RpcBoundedRoutes.objects(player)
        assert(value == expected, "C2S RPC request Instance identity")
        echoCalls[player.UserId] = (echoCalls[player.UserId] or 0) + 1
        return value
    end))
    assert(session.requests.LegacyRpc:Connect(function(_player, value) return value + 1 end))

    local concurrentActive, concurrentCalls, concurrentRelease = {}, {}, {}
    assert(session.requests.Concurrent:Connect(function(player, hold)
        concurrentCalls[player.UserId] = (concurrentCalls[player.UserId] or 0) + 1
        concurrentActive[player.UserId] = (concurrentActive[player.UserId] or 0) + 1
        waitFor(function() return concurrentRelease[player.UserId] == true end,
            "bounded C2S RPC release", 8)
        concurrentActive[player.UserId] -= 1
        return if hold then nil else false
    end))
    assert(session:Start())
    local function observe(remote, channel)
        return remote.OnServerEvent:Connect(function(player, endpoint, packet, ...)
            local row
            if channel == "Unreliable" and typeof(packet) == "buffer" and buffer.len(packet) >= 1
                and buffer.readu8(packet, 0) == 6 then
                row = RpcBoundedRoutes.rawOrderedReceipt(endpoint, packet, ...)
            else
                row = RpcBoundedRoutes.instanceReceipt(endpoint, packet, ...)
            end
            row.client = player.UserId
            row.channel = channel
            table.insert(rawIngress, row)
        end)
    end
    local rawConnections = {
        observe(ReplicatedStorage.RelayRemotes.Reliable, "Reliable"),
        observe(ReplicatedStorage.RelayRemotes.Unreliable, "Unreliable"),
    }
    all("rpc-bounded-start")

    local sendResults = {}
    for _, player in roster do
        sendResults[player.UserId] = command(player, "rpc-bounded-send-events")
    end
    waitFor(function()
        for _, player in roster do
            local values = serverValues[player.UserId]
            if not values.Input or #values.Input ~= 1
                or not values.UnreliableInput or #values.UnreliableInput ~= 1
                or not values.OrderedInput or #values.OrderedInput ~= 1
                or not values.QueueInput or #values.QueueInput ~= 1
                or not values.UnreliableQueueInput or #values.UnreliableQueueInput ~= 1
                or not values.StateInput or #values.StateInput ~= 1
                or not values.minimum or #values.minimum ~= 1
                or not values.legacyQueued or #values.legacyQueued ~= 2 then return false end
        end
        return true
    end, "native RR16 immediate, queued, and Instance route ingress", 20)

    all("rpc-bounded-hostile")
    waitFor(function()
        local events = session:GetDiagnostics().events
        return events.MinimumInput.invalidPayload >= #roster
            and events.Input.invalidPayload >= 3 * #roster
            and events.UnreliableInput.invalidPayload >= #roster
            and events.OrderedInput.invalidPayload >= #roster
            and events.QueueInput.invalidPayload >= 2 * #roster
            and events.UnreliableQueueInput.invalidPayload >= 2 * #roster
    end, "bounded prefix, reference, scope, and both queued-frame rejections", 15)
    for _, player in roster do
        local values = serverValues[player.UserId]
        assert(#values.Input == 1 and #values.UnreliableInput == 1 and #values.OrderedInput == 1
            and #values.QueueInput == 1 and #values.UnreliableQueueInput == 1 and #values.StateInput == 1
            and #values.minimum == 1, "hostile or out-of-scope reference reached an immediate or queued handler")
    end
    all("rpc-bounded-recovery")
    waitFor(function()
        for _, player in roster do
            local values = serverValues[player.UserId]
            if #values.Input ~= 2 or #values.UnreliableInput ~= 2 or #values.OrderedInput ~= 2
                or #values.QueueInput ~= 2 or #values.minimum ~= 2 then return false end
        end
        return true
    end, "valid native references dispatch after malformed and out-of-scope frames", 15)

    local target = roster[1]
    assert(command(target, "rpc-bounded-concurrency-start"))
    waitFor(function() return concurrentActive[target.UserId] == 2 end,
        "two concurrent C2S RPC handlers", 10)
    local c2sRefusal = command(target, "rpc-bounded-concurrency-third")
    assert(c2sRefusal.cancelled == "Cancelled" and c2sRefusal.busy == "Busy"
        and concurrentActive[target.UserId] == 2,
        "cancelled C2S caller keeps both yielded server handlers leased through Busy refusal")
    concurrentRelease[target.UserId] = true
    waitFor(function() return concurrentActive[target.UserId] == 0 end, "C2S RPC handler leases release", 10)
    local c2sResults = command(target, "rpc-bounded-concurrency-await")
    assert(concurrentCalls[target.UserId] == 3 and c2sResults.cancelled == "Cancelled"
        and c2sResults.nilValue and c2sResults.falseValue,
        "bounded C2S RPC refusal, handler lease, and typed nil/false results")

    local targetPart = RpcBoundedRoutes.objects(target)
    local first = assert(session.requests.ClientCall:Request(target, 10, targetPart, true, false, true))
    local second = assert(session.requests.ClientCall:Request(target, 10, targetPart, false, false, true))
    local clientCallStatus
    waitFor(function()
        clientCallStatus = command(target, "rpc-bounded-client-calls-status")
        return clientCallStatus.active == 2
    end, "two held S2C RPC handler leases", 10)
    local s2cHandoffsBeforeLimit = session:GetDiagnostics().counters.sendHandoffs
    local s2cLimited, s2cLimitProblem = session.requests.ClientCall:Request(target, 5,
        targetPart, false, false, false)
    local s2cHandoffsAfterLimit = session:GetDiagnostics().counters.sendHandoffs
    assert(s2cLimited == nil and s2cLimitProblem ~= nil and s2cLimitProblem.code == "RequestLimit",
        "S2C concurrent caller slot limit rejects locally")
    assert(s2cHandoffsAfterLimit == s2cHandoffsBeforeLimit,
        "S2C caller slot refusal does not hand off a native request")
    first:Cancel()
    local firstResult = first:Await()
    assert(not firstResult.ok and firstResult.error.code == "Cancelled", "S2C RPC caller cancellation")
    local third = assert(session.requests.ClientCall:Request(target, 5, targetPart, false, false, false))
    local thirdResult = third:Await()
    assert(not thirdResult.ok and thirdResult.error.code == "Busy", "S2C RPC active handler refusal")
    local heldStatus = command(target, "rpc-bounded-client-calls-status")
    assert(heldStatus.active == 2 and heldStatus.results == 0 and not heldStatus.released,
        "cancelled S2C caller retains the yielded callee lease")
    assert(command(target, "rpc-bounded-release-client-calls"))
    local secondResult = second:Await()
    assert(secondResult.ok and secondResult.value.part == targetPart and secondResult.value.status == false,
        "S2C RPC Instance response preserves typed false")
    waitFor(function()
        clientCallStatus = command(target, "rpc-bounded-client-calls-status")
        return clientCallStatus.active == 0 and clientCallStatus.results == 2
    end, "cancelled and successful S2C handler leases release", 10)
    local nilRequest = assert(session.requests.ClientCall:Request(target, 5, targetPart, true, false, false))
    local nilResult = nilRequest:Await()
    assert(nilResult.ok and nilResult.value.part == targetPart and nilResult.value.status == nil,
        "S2C RPC Instance response preserves typed nil")
    local noListener = assert(session.requests.NoListener:Request(target, 5, 1)):Await()
    assert(not noListener.ok and noListener.error.code == "NoListener", "opt-in NoListener reply is prompt")

    for _, player in roster do
        local part, folder = RpcBoundedRoutes.objects(player)
        local references = { part, part, folder }
        assert(session.events.Output:Send(player, table.unpack(references)))
        assert(session.events.UnreliableOutput:Send(player, table.unpack(references)))
        assert(session.events.OrderedOutput:Send(player, table.unpack(references)))
        assert(session.events.NumericOutput:Send(player, RpcBoundedRoutes.numericValues()))
        assert(session.events.BoundedOutput:Send(player, RpcBoundedRoutes.boundedValue()))
        assert(session.events.LegacyOutput:Send(player, 43))

        local batch, batchFailure = session:CreateBatch({ player }, 0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message)
        assert(batch.events.QueueOutput:Send(table.unpack(references)))
        assert(batch.events.LegacyQueueOutput:Send(44))
        assert(batch.events.UnreliableQueueOutput:Send(table.unpack(references)))
        local batchOk, batchProblem, batchReport = batch:Flush()
        assert(batchOk, batchProblem and batchProblem.code)
        assert(batchReport.selected == 3 and batchReport.reliableHandoffs == 1
            and batchReport.unreliableHandoffs == 1, "native S2C mixed queue channel handoffs")
        local legacyBatch, legacyFailure = session:CreateBatch({ player }, 0.05)
        assert(legacyBatch ~= nil, legacyFailure and legacyFailure.message)
        assert(legacyBatch.events.LegacyQueueOutput:Send(45))
        local legacyOk, legacyProblem, legacyReport = legacyBatch:Flush()
        assert(legacyOk, legacyProblem and legacyProblem.code)
        assert(legacyReport.selected == 1 and legacyReport.reliableHandoffs == 1,
            "native S2C no-reference queue keeps one legacy frame")

        local state, stateFailure = session:CreateState({ player }, 0.05)
        assert(state ~= nil, stateFailure and stateFailure.message)
        assert(state.events.StateOutput:Put(1, "Normal", table.unpack(references)))
        assert(state:Flush())
    end
    local clientReads = {}
    for _, player in roster do clientReads[player.UserId] = command(player, "rpc-bounded-read") end

    local outside = InstanceValues.objects(target).part
    local beforeScopeSends = session:GetDiagnostics().counters.sendHandoffs
    local scopeRejectedRoutes = {}
    local sent, scopeFailure = session.events.Output:Send(target, outside, outside, select(2, RpcBoundedRoutes.objects(target)))
    assert(not sent and scopeFailure.code == "InvalidPayload", "S2C immediate Instance scope check")
    table.insert(scopeRejectedRoutes, "Output")
    sent, scopeFailure = session.events.UnreliableOutput:Send(target, outside, outside,
        select(2, RpcBoundedRoutes.objects(target)))
    assert(not sent and scopeFailure.code == "InvalidPayload", "S2C immediate unreliable Instance scope check")
    table.insert(scopeRejectedRoutes, "UnreliableOutput")
    sent, scopeFailure = session.events.OrderedOutput:Send(target, outside, outside,
        select(2, RpcBoundedRoutes.objects(target)))
    assert(not sent and scopeFailure.code == "InvalidPayload", "S2C ordered unreliable Instance scope check")
    table.insert(scopeRejectedRoutes, "OrderedOutput")
    local rejectedBatch, batchProblem = session:CreateBatch({ target }, 0.05)
    assert(rejectedBatch ~= nil, batchProblem and batchProblem.message)
    sent, scopeFailure = rejectedBatch.events.QueueOutput:Send(outside, outside,
        select(2, RpcBoundedRoutes.objects(target)))
    assert(not sent and scopeFailure.code == "InvalidPayload", "S2C queued Instance scope check")
    table.insert(scopeRejectedRoutes, "QueueOutput")
    sent, scopeFailure = rejectedBatch.events.UnreliableQueueOutput:Send(outside, outside,
        select(2, RpcBoundedRoutes.objects(target)))
    assert(not sent and scopeFailure.code == "InvalidPayload", "S2C unreliable queued Instance scope check")
    table.insert(scopeRejectedRoutes, "UnreliableQueueOutput")
    rejectedBatch:Cancel()
    local rejectedState = assert(session:CreateState({ target }, 0.05))
    sent, scopeFailure = rejectedState.events.StateOutput:Put(2, "Normal", outside, outside,
        select(2, RpcBoundedRoutes.objects(target)))
    assert(not sent and scopeFailure.code == "InvalidPayload", "S2C State Instance scope check")
    table.insert(scopeRejectedRoutes, "StateOutput")
    rejectedState:Destroy()
    assert(session:GetDiagnostics().counters.sendHandoffs == beforeScopeSends,
        "out-of-scope Instance outputs reject before transport handoff")

    local mainSnapshot = session:GetDiagnostics()
    local mainEventCounters, mainServerRows, mainClientRows = {}, table.create(#roster), table.create(#roster)
    for _, name in { "Input", "UnreliableInput", "OrderedInput", "QueueInput", "UnreliableQueueInput",
        "StateInput", "NumericInput", "BoundedInput", "MinimumInput" } do
        local counters = mainSnapshot.events[name]
        mainEventCounters[name] = { invalidPayload = counters.invalidPayload, dispatched = counters.dispatched }
    end
    for index, player in roster do
        table.insert(mainServerRows, { client = player.UserId, values = serverValues[player.UserId],
            failure = routeFailures[player.UserId], echoCalls = echoCalls[player.UserId] or 0 })
        table.insert(mainClientRows, clientReads[player.UserId])
    end
    for _, connection in rawConnections do connection:Disconnect() end
    local mainRawIngress = table.clone(rawIngress)
    all("rpc-bounded-destroy")
    session:Destroy()
    session = nil
    all("absent")

    local serverStorage = game:GetService("ServerStorage")
    local serverOnlyPart = Instance.new("Part")
    serverOnlyPart.Name = "RelayRpcBoundedServerOnlyPart"
    serverOnlyPart.Parent = serverStorage
    local serverOnlyFolder = InstanceValues.serverOnly()
    local missingCreate, missingProblem = Relay.createServer(RpcBoundedRoutes.create(), {
        instanceRoot = game,
        inboundRate = {
            perPlayer = { capacity = 512, refillPerSecond = 256 },
            aggregate = { capacity = 4096, refillPerSecond = 2048 },
        },
    })
    assert(missingCreate ~= nil, missingProblem and missingProblem.message)
    session = missingCreate
    local missingEchoCalls = 0
    assert(session.requests.Echo:Connect(function(_player, value)
        missingEchoCalls += 1
        return value
    end))
    assert(session:Start())
    table.clear(rawIngress)
    rawConnections = {
        observe(ReplicatedStorage.RelayRemotes.Reliable, "Reliable"),
        observe(ReplicatedStorage.RelayRemotes.Unreliable, "Unreliable"),
    }
    all("rpc-bounded-start")
    local missingClientRequest = command(target, "rpc-bounded-missing-echo")
    local missingServerRequest = assert(session.requests.ClientCall:Request(target, 0.4,
        serverOnlyPart, false, false, false)):Await()
    assert(not missingServerRequest.ok and missingServerRequest.error.code == "RequestTimeout",
        "unavailable S2C RPC request reference is dropped without a refusal")
    local missingResponse = assert(session.requests.ClientCall:Request(target, 5,
        RpcBoundedRoutes.objects(target), false, true, false)):Await()
    assert(not missingResponse.ok and missingResponse.error.code == "InvalidResponse",
        "unavailable S2C RPC response reference settles the caller")
    assert(session.events.Output:Send(target, serverOnlyPart, serverOnlyPart, serverOnlyFolder),
        "ServerStorage references reach native FireClient for nil-sidecar rejection")
    local missingOutput = command(target, "rpc-bounded-missing-read")
    assert(missingOutput.invalidPayload == 1 and missingOutput.dispatched == 0 and missingOutput.callbacks == 0,
        "unavailable S2C event references reject without callback")
    local recoveryPart, recoveryFolder = RpcBoundedRoutes.objects(target)
    assert(session.events.Output:Send(target, recoveryPart, recoveryPart, recoveryFolder))
    local recoveredOutput = command(target, "rpc-bounded-output-recovery")
    assert(missingEchoCalls == 0 and missingClientRequest == "RequestTimeout"
        and recoveredOutput.part == recoveryPart:GetFullName(), "RPC and event recovery after missing references")
    for _, connection in rawConnections do connection:Disconnect() end
    local missingRawIngress = table.clone(rawIngress)
    all("rpc-bounded-destroy")
    session:Destroy()
    session = nil
    all("absent")
    serverOnlyPart:Destroy()
    serverOnlyFolder:Destroy()

    rpcBoundedRouteDiagnostics = {
        main = {
            clients = mainClientRows,
            server = mainServerRows,
            rpc = {
                rpcClient = target.UserId,
                c2sEchoCalls = echoCalls[target.UserId] or 0,
                c2sConcurrentCalls = concurrentCalls[target.UserId],
                c2sRequestLimit = c2sRefusal.requestLimit,
                c2sHandoffsBeforeLimit = c2sRefusal.handoffsBeforeLimit,
                c2sHandoffsAfterLimit = c2sRefusal.handoffsAfterLimit,
                c2sCancelled = c2sRefusal.cancelled,
                c2sBusy = c2sRefusal.busy,
                c2sResults = c2sResults,
                s2cRequestLimit = s2cLimitProblem.code,
                s2cHandoffsBeforeLimit = s2cHandoffsBeforeLimit,
                s2cHandoffsAfterLimit = s2cHandoffsAfterLimit,
                s2cCancelled = firstResult.error.code,
                s2cHeldAfterCancel = heldStatus.active == 2 and heldStatus.results == 0,
                s2cSecondFalse = secondResult.ok and secondResult.value.status == false,
                s2cFinalNil = nilResult.ok and nilResult.value.status == nil,
                s2cBusy = thirdResult.error.code,
                noListener = noListener.error.code,
                legacy = sendResults[target.UserId].legacyRpc,
            },
            rawIngress = mainRawIngress,
            eventCounters = mainEventCounters,
            invalidSends = sendResults[target.UserId].invalidEncodes,
            legacyQueue = { inbound = serverValues[target.UserId].legacyQueued,
                outbound = clientReads[target.UserId].scalars.LegacyQueueOutput },
            scopeRejected = true,
            scopeRejectedRoutes = scopeRejectedRoutes,
        },
        missing = {
            c2sRequest = missingClientRequest,
            s2cRequest = missingServerRequest.error.code,
            s2cResponse = missingResponse.error.code,
            output = missingOutput,
            recovered = recoveredOutput,
            serverHandlerCalls = missingEchoCalls,
            rawIngress = missingRawIngress,
        },
    }
    mark("rpc-bounded-routes")
end

local function broadcastBatchingCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    local _, instanceRoot = InstanceValues.prepare()
    local _, part, folder, outsidePart = BroadcastBatching.scope()
    local created, problem = Relay.createServer(BroadcastBatching.create(), {
        instanceRoot = instanceRoot,
        inboundRate = {
            perPlayer = { capacity = 64, refillPerSecond = 64 },
            aggregate = { capacity = 128, refillPerSecond = 128 },
        },
    })
    assert(created ~= nil, problem and problem.message or "shared broadcast server creation")
    session = created
    assert(session:Start())
    all("broadcast-start")

    local target = roster[1]
    local pulseAdmissions, pulseRefusal = 0, nil
    local pulsePayload = string.rep("p", 120)
    for _ = 1, 8 do
        local sent, failure = session.events.Pulse:Send(target, pulsePayload)
        if not sent then
            pulseRefusal = failure
            break
        end
        pulseAdmissions += 1
    end
    assert(pulseAdmissions > 0 and pulseRefusal ~= nil and pulseRefusal.code == "OutboundRateLimited",
        "one current recipient reaches its outbound byte limit")

    local batcher, batcherFailure = session:CreateBroadcastBatcher(0.1)
    assert(batcher ~= nil, batcherFailure and batcherFailure.message or "shared broadcast batcher creation")
    assert(batcher.events.ReliableOutput:Send(false, part, folder))
    assert(batcher.events.ReliableOutput:Send(true, part, folder))
    local invalid, invalidProblem = batcher.events.UnreliableOutput:Send(256, false)
    assert(not invalid and invalidProblem.code == "InvalidPayload",
        "shared unreliable broadcast preserves schema bounds")
    assert(batcher.events.UnreliableOutput:Send(7, false))
    assert(batcher.events.UnreliableOutput:Send(255, true))

    local beforeFlush = session:GetDiagnostics().counters
    local failed, refusal, refusedReport = batcher:Flush()
    assert(not failed and refusal.code == "OutboundRateLimited"
        and refusedReport.selected == 0 and refusedReport.remaining == 4,
        "shared fanout refusal keeps the complete FIFO window")
    local refusedStatus = batcher:GetStatus()
    assert(refusedStatus.state == "Open" and refusedStatus.pendingRecords == 4
        and refusedStatus.lastFlush.error.code == "OutboundRateLimited",
        "shared fanout refusal remains explicitly retryable")
    local afterRefusal = session:GetDiagnostics().counters
    assert(afterRefusal.broadcastHandoffs == beforeFlush.broadcastHandoffs
        and afterRefusal.sendHandoffs == beforeFlush.sendHandoffs
        and afterRefusal.outboundBytesCharged == beforeFlush.outboundBytesCharged,
        "shared fanout refusal neither partially hands off nor debits recipients")
    task.wait(0.1)
    local refusalPeers = {}
    for _, player in roster do
        local observed = command(player, "broadcast-snapshot")
        assert(#observed.reliable == 0 and #observed.unreliable == 0
            and #observed.raw.Reliable == 0 and #observed.raw.Unreliable == 0,
            "atomic outbound refusal reaches no recipient")
        table.insert(refusalPeers, observed)
    end

    task.wait(1.1)
    local retried, retryFailure, retryReport = batcher:Flush()
    assert(retried, retryFailure and retryFailure.code or "shared broadcast refill retry")
    assert(retryReport.selected == 4 and retryReport.reliableHandoffs == 1
        and retryReport.unreliableHandoffs == 1 and retryReport.logicalHandoffs == 4,
        "one native shared handoff per populated channel and one logical record count per queued event")
    local afterRetry = session:GetDiagnostics().counters
    assert(afterRetry.broadcastHandoffs - beforeFlush.broadcastHandoffs == 2
        and afterRetry.sendHandoffs == beforeFlush.sendHandoffs,
        "shared reliable and unreliable diagnostics count native calls")

    local invalidScope, scopeFailure = batcher.events.ReliableOutput:Send(false, outsidePart, folder)
    assert(not invalidScope and scopeFailure.code == "InvalidPayload",
        "shared broadcast queue enforces Instance scope")
    assert(batcher.events.ReliableOutput:Send(false, part, folder))
    local reused, reuseFailure, reuseReport = batcher:Flush()
    assert(reused, reuseFailure and reuseFailure.code or "reusable shared broadcast window")
    assert(reuseReport.selected == 1 and reuseReport.reliableHandoffs == 1
        and reuseReport.unreliableHandoffs == 0 and reuseReport.logicalHandoffs == 1,
        "shared batcher reopens for the next FIFO window")

    local cancelCounters = session:GetDiagnostics().counters
    assert(batcher.events.ReliableOutput:Send(true, part, folder))
    batcher:Cancel()
    local cancelledStatus = batcher:GetStatus()
    assert(cancelledStatus.state == "Terminal" and cancelledStatus.pendingRecords == 0,
        "shared batcher cancellation releases queued data")
    task.wait(0.2)
    local afterCancel = session:GetDiagnostics().counters
    assert(afterCancel.broadcastHandoffs == cancelCounters.broadcastHandoffs
        and afterCancel.sendHandoffs == cancelCounters.sendHandoffs,
        "cancelled shared window timer cannot hand off later")

    local peerRows = {}
    for _, player in roster do
        local observed = command(player, "broadcast-read")
        assert(observed.failure == nil and #observed.reliable == 3,
            "shared reliable callbacks arrive in both reusable windows")
        local expected = { false, true, false }
        for index, enabled in expected do
            local value = observed.reliable[index]
            assert(value.enabled == enabled and value.part == part:GetFullName()
                and value.folder == folder:GetFullName(),
                "shared reliable callback order, false value, and Instance identity")
        end
        assert(#observed.raw.Reliable == 2, "one reliable packet for each populated window")
        for index, expectedCount in { 2, 1 } do
            local raw = observed.raw.Reliable[index]
            local expectedLength = if index == 1 then 22 else 13
            assert(raw.endpoint == 0 and raw.format == 5 and raw.kind == 1
                and raw.count == expectedCount and raw.referenceCount == expectedCount * 2
                and raw.length == expectedLength and raw.length + raw.referenceCount * 8 <= 8_192,
                "actual shared reliable BatchFrame metadata and byte budget")
            for recordIndex, record in raw.records do
                assert(record.codec == 4 and record.eventId == 1 and record.referenceCount == 2
                    and record.bodyLength == 7
                    and record.ordinals[1] == 1 and record.ordinals[2] == 2,
                    "actual per-record reference ordinals remain local and ordered")
            end
            assert(type(raw.bytes) == "table" and #raw.bytes == raw.length,
                "actual shared reliable packet bytes are retained")
            assert(#raw.references == expectedCount * 2, "actual shared reliable native sidecar arity")
            for sidecarIndex, sidecar in raw.references do
                local expectedObject = if sidecarIndex % 2 == 1 then part else folder
                assert(sidecar.className == expectedObject.ClassName and sidecar.name == expectedObject.Name
                    and sidecar.path == expectedObject:GetFullName(),
                    "actual shared reliable Instance sidecar identity")
            end
        end
        assert(#observed.raw.Unreliable <= 1 and #observed.unreliable <= 2,
            "unreliable shared delivery may be lost without exceeding its bounded values")
        if #observed.raw.Unreliable == 1 then
            local raw = observed.raw.Unreliable[1]
            assert(raw.endpoint == 0 and raw.format == 2 and raw.kind == 1 and raw.count == 2
                and raw.referenceCount == 0 and raw.length == 17 and #raw.references == 0,
                "actual shared unreliable BatchFrame metadata and byte budget")
            assert(#observed.unreliable == 2, "observed unreliable packet dispatches its complete FIFO")
            assert(raw.records[1].codec == 1 and raw.records[1].eventId == 2
                and raw.records[1].bodyLength == 5 and raw.records[2].codec == 1
                and raw.records[2].eventId == 2 and raw.records[2].bodyLength == 5,
                "actual shared unreliable record identities")
            assert(observed.unreliable[1].sequence == 7 and observed.unreliable[1].enabled == false
                and observed.unreliable[2].sequence == 255 and observed.unreliable[2].enabled == true,
                "observed unreliable values remain bounded and ordered")
        else
            assert(#observed.unreliable == 0, "unreliable callback values require an observed packet")
        end
        table.insert(peerRows, observed)
    end

    local finalCounters = session:GetDiagnostics().counters
    local charged = finalCounters.outboundBytesCharged - beforeFlush.outboundBytesCharged
    local firstReliable = peerRows[1].raw.Reliable[1]
    local reusedReliable = peerRows[1].raw.Reliable[2]
    local retryUnreliableBytes = 17
    for _, row in peerRows do
        if #row.raw.Unreliable == 1 then
            retryUnreliableBytes = row.raw.Unreliable[1].length
            break
        end
    end
    local retryReliableCharge = firstReliable.length + firstReliable.referenceCount * 8
    local retryUnreliableCharge = retryUnreliableBytes
    local reuseReliableCharge = reusedReliable.length + reusedReliable.referenceCount * 8
    local perRecipientBytes = retryReliableCharge + retryUnreliableCharge + reuseReliableCharge
    assert(retryReliableCharge == 54 and retryUnreliableCharge == 17 and reuseReliableCharge == 29
        and perRecipientBytes == 100 and charged == 100 * #roster,
        "exact shared retry and reusable-window outbound debit is 100 bytes per current recipient")
    local byteBreakdown = {
        retry = {
            reliable = { frameBytes = firstReliable.length, headerBytes = 4, recordCount = 2,
                recordBodyBytes = { 7, 7 }, lengthPrefixBytes = 4, referenceCount = firstReliable.referenceCount,
                referenceUnitBytes = 8, referenceBytes = firstReliable.referenceCount * 8, charge = retryReliableCharge },
            unreliable = { frameBytes = retryUnreliableBytes, headerBytes = 3, recordCount = 2,
                recordBodyBytes = { 5, 5 }, lengthPrefixBytes = 4, referenceCount = 0,
                referenceUnitBytes = 8, referenceBytes = 0, charge = retryUnreliableCharge },
            totalCharge = retryReliableCharge + retryUnreliableCharge,
        },
        reuse = { frameBytes = reusedReliable.length, headerBytes = 4, recordCount = 1,
            recordBodyBytes = { 7 }, lengthPrefixBytes = 2, referenceCount = reusedReliable.referenceCount,
            referenceUnitBytes = 8, referenceBytes = reusedReliable.referenceCount * 8, charge = reuseReliableCharge },
        perRecipientBytes = perRecipientBytes,
    }

    local hostileSource = peerRows[1].raw.Reliable[1]
    local malformedPacket = buffer.create(hostileSource.length)
    for index, byte in hostileSource.bytes do buffer.writeu8(malformedPacket, index - 1, byte) end
    local malformedOffset = 4
    for index = 1, #hostileSource.records - 1 do
        malformedOffset += 2 + hostileSource.records[index].bodyLength
    end
    assert(hostileSource.format == 5 and hostileSource.kind == 1 and hostileSource.count == 2
        and malformedOffset == 13 and buffer.readu16(malformedPacket, malformedOffset) == 7,
        "shared malformed probe targets the final valid row length")
    buffer.writeu16(malformedPacket, malformedOffset, 0)
    local malformedBytes = table.create(buffer.len(malformedPacket))
    for index = 0, buffer.len(malformedPacket) - 1 do
        malformedBytes[index + 1] = buffer.readu8(malformedPacket, index)
    end
    local hostileBaselines = {}
    for _, player in roster do
        local baseline = command(player, "broadcast-hostile-start")
        assert(baseline.reliableCallbacks == 3, "malformed broadcast baseline retains complete normal FIFO")
        hostileBaselines[player] = baseline
    end
    local malformedInjectionBefore = session:GetDiagnostics().counters
    ReplicatedStorage.RelayRemotes.Reliable:FireAllClients(0, malformedPacket, part, folder, part, folder)
    local hostilePeers = {}
    for _, player in roster do
        local baseline = hostileBaselines[player]
        local receipt = command(player, "broadcast-hostile-read", baseline)
        assert(receipt.invalidPayload > baseline.invalidPayload
            and receipt.reliableCallbacks == baseline.reliableCallbacks and #receipt.frames == 1,
            "causal invalidPayload barrier rejects the whole malformed frame without partial callback")
        local raw = receipt.frames[1]
        assert(raw.endpoint == 0 and raw.format == 5 and raw.kind == 1 and raw.count == 2
            and raw.referenceCount == 4 and raw.length == #malformedBytes and #raw.bytes == #malformedBytes,
            "actual malformed shared frame header and bytes are captured separately")
        table.insert(hostilePeers, {
            client = player.UserId,
            invalidPayloadBefore = baseline.invalidPayload,
            invalidPayloadAfter = receipt.invalidPayload,
            reliableCallbacksBefore = baseline.reliableCallbacks,
            reliableCallbacksAfter = receipt.reliableCallbacks,
            frames = receipt.frames,
        })
    end
    all("broadcast-hostile-stop")
    local malformedInjectionAfter = session:GetDiagnostics().counters
    assert(malformedInjectionAfter.broadcastHandoffs == malformedInjectionBefore.broadcastHandoffs
        and malformedInjectionAfter.sendHandoffs == malformedInjectionBefore.sendHandoffs
        and malformedInjectionAfter.outboundBytesCharged == malformedInjectionBefore.outboundBytesCharged,
        "direct malformed test injection bypasses Relay handoff and outbound accounting")

    local recoveryBatcher, recoveryCreateFailure = session:CreateBroadcastBatcher(0.1)
    assert(recoveryBatcher ~= nil, recoveryCreateFailure and recoveryCreateFailure.message or "valid recovery batcher")
    assert(recoveryBatcher.events.ReliableOutput:Send(true, part, folder), "valid shared recovery record")
    local recoveryBefore = session:GetDiagnostics().counters
    local recovered, recoveryFailure, recoveryReport = recoveryBatcher:Flush()
    assert(recovered, recoveryFailure and recoveryFailure.code or "valid shared recovery flush")
    assert(recoveryReport.selected == 1 and recoveryReport.reliableHandoffs == 1
        and recoveryReport.unreliableHandoffs == 0 and recoveryReport.logicalHandoffs == 1,
        "valid shared recovery uses one reliable handoff")
    local recoveryAfter = session:GetDiagnostics().counters
    local recoveryCharged = recoveryAfter.outboundBytesCharged - recoveryBefore.outboundBytesCharged
    assert(recoveryAfter.broadcastHandoffs - recoveryBefore.broadcastHandoffs == 1
        and recoveryAfter.sendHandoffs == recoveryBefore.sendHandoffs
        and recoveryCharged == 29 * #roster,
        "valid recovery independently charges 29 bytes per recipient")
    recoveryBatcher:Cancel()
    local recoveryPeers = {}
    for _, player in roster do
        local observed = command(player, "broadcast-recovery-read")
        assert(observed.failure == nil and #observed.reliable == 4,
            "valid shared frame recovers on every peer after malformed rejection")
        table.insert(recoveryPeers, observed)
    end

    local stateRefillWaitSeconds = 2.1
    task.wait(stateRefillWaitSeconds)
    local stateLane, stateCreateFailure = session:CreateBroadcastState(0.1)
    assert(stateLane ~= nil, stateCreateFailure and stateCreateFailure.message or "shared State lane creation")
    local _, statePart, stateFolder = BroadcastBatching.scope()
    local stateFirstDirtyAt = os.clock()
    local stateMessages = { string.rep("1", 93), string.rep("2", 93) }
    for index = 1, 2 do
        assert(stateLane.events.ReliableState:Put(index, "Normal", index, "old-value", statePart, stateFolder))
        assert(stateLane.events.ReliableState:Put(index, "High", index + 10, stateMessages[index], statePart, stateFolder))
    end
    assert(stateLane.events.UnreliableState:Put(3, "Normal", 7, false))
    local statePending = stateLane:GetStatus()
    assert(statePending.state == "Open" and statePending.pendingKeys == 3,
        "shared State replacements coalesce two keys and retain one unreliable key")

    local stateBeforePulse = session:GetDiagnostics().counters
    local statePulseStarted = os.clock()
    local statePulseSent, statePulseFailure = session.events.Pulse:Send(target, "12345")
    assert(statePulseSent, statePulseFailure and statePulseFailure.code or "State refusal budget setup")
    local statePulseAdmissions = 1
    local stateBeforeFlush = session:GetDiagnostics().counters
    local statePulseToFlushElapsed = os.clock() - statePulseStarted
    assert(statePulseToFlushElapsed < 0.05
        and stateBeforeFlush.broadcastHandoffs == stateBeforePulse.broadcastHandoffs
        and stateBeforeFlush.sendHandoffs == stateBeforePulse.sendHandoffs + 1
        and stateBeforeFlush.outboundBytesCharged == stateBeforePulse.outboundBytesCharged + 10,
        "short targeted pulse leaves 246 budget units for an atomic 254-unit State selection")
    local stateFirstOk, stateRefusal, stateRefusedReport = stateLane:Flush()
    assert(not stateFirstOk and stateRefusal.code == "OutboundRateLimited"
        and stateRefusedReport.selected == 0 and stateRefusedReport.remaining == 3,
        "shared State refusal retains all coalesced keys")
    local stateAfterRefusal = session:GetDiagnostics().counters
    local stateRefusedStatus = stateLane:GetStatus()
    local stateRefusalElapsed = os.clock() - statePulseStarted
    assert(stateRefusedStatus.state == "Open" and stateRefusedStatus.pendingKeys == 3
        and stateRefusedStatus.lastFlush.error.code == "OutboundRateLimited"
        and stateRefusalElapsed < 0.05
        and stateAfterRefusal.broadcastHandoffs == stateBeforeFlush.broadcastHandoffs
        and stateAfterRefusal.sendHandoffs == stateBeforeFlush.sendHandoffs
        and stateAfterRefusal.outboundBytesCharged == stateBeforeFlush.outboundBytesCharged,
        "combined State refusal preserves bounded pending data with no debit or handoff")
    task.wait(0.25)
    local stateAfterNoDeferral = session:GetDiagnostics().counters
    local stateNoDeferralStatus = stateLane:GetStatus()
    local stateNoAutoElapsed = os.clock() - stateFirstDirtyAt
    assert(stateNoAutoElapsed < 0.9 and stateNoDeferralStatus.state == "Open"
        and stateNoDeferralStatus.pendingKeys == 3
        and stateAfterNoDeferral.broadcastHandoffs == stateAfterRefusal.broadcastHandoffs
        and stateAfterNoDeferral.sendHandoffs == stateAfterRefusal.sendHandoffs
        and stateAfterNoDeferral.outboundBytesCharged == stateAfterRefusal.outboundBytesCharged,
        "shared State refusal does not auto-defer or expire before explicit retry")

    local stateRetried, stateRetryFailure, stateRetryReport = stateLane:Flush()
    assert(stateRetried, stateRetryFailure and stateRetryFailure.code or "explicit shared State retry")
    assert(stateRetryReport.selected == 3 and stateRetryReport.remaining == 0
        and stateRetryReport.reliableHandoffs == 1 and stateRetryReport.unreliableHandoffs == 1
        and stateRetryReport.logicalHandoffs == 3,
        "shared State retry uses one native call per populated channel")
    local stateAfterRetry = session:GetDiagnostics().counters
    assert(stateAfterRetry.broadcastHandoffs - stateBeforeFlush.broadcastHandoffs == 2
        and stateAfterRetry.sendHandoffs == stateBeforeFlush.sendHandoffs,
        "shared State diagnostics count broadcast native calls, not targeted sends")

    local statePeerRows = {}
    for _, player in roster do
        local observed = command(player, "broadcast-state-read", { reliable = 2, reliableRaw = 1 })
        assert(observed.failure == nil and #observed.reliable == 2,
            "shared State latest values reach each current peer")
        local expectedMarkers = { 11, 12 }
        for index, marker in expectedMarkers do
            local value = observed.reliable[index]
            assert(value.marker == marker and value.message == stateMessages[index]
                and value.part == statePart:GetFullName() and value.folder == stateFolder:GetFullName(),
                "shared State replacement values and Instance identity")
        end
        assert(type(observed.raw.Reliable) == "table" and #observed.raw.Reliable == 1,
            "shared State reliable packet was observed")
        local raw = observed.raw.Reliable[1]
        assert(raw.endpoint == 0 and raw.format == 5 and raw.kind == 2 and raw.count == 2
            and raw.referenceCount == 4 and raw.length == 212 and raw.length + raw.referenceCount * 8 <= 8_192,
            "actual shared State reliable kind-2 frame and sidecars")
        for index, row in raw.records do
            assert(row.codec == 4 and row.eventId == 4 and row.bodyLength == 102
                and row.referenceCount == 2 and row.ordinals[1] == 1 and row.ordinals[2] == 2,
                "shared State reliable record and local reference ordinals")
            local referenceIndex = (index - 1) * 2
            local partReference, folderReference = raw.references[referenceIndex + 1], raw.references[referenceIndex + 2]
            assert(partReference.className == statePart.ClassName and partReference.path == statePart:GetFullName()
                and folderReference.className == stateFolder.ClassName and folderReference.path == stateFolder:GetFullName(),
                "shared State reliable native sidecar identity")
        end
        assert(type(observed.raw.Unreliable) == "table" and #observed.raw.Unreliable <= 1
            and type(observed.unreliable) == "table",
            "shared unreliable State observation is optional")
        if #observed.raw.Unreliable == 1 then
            local unreliable = observed.raw.Unreliable[1]
            assert(unreliable.endpoint == 0 and unreliable.format == 2 and unreliable.kind == 2
                and unreliable.count == 1 and unreliable.referenceCount == 0 and unreliable.length == 10
                and #observed.unreliable == 1 and observed.unreliable[1].sequence == 7
                and observed.unreliable[1].enabled == false,
                "observed unreliable State packet completes its callback barrier")
            assert(unreliable.records[1].codec == 1 and unreliable.records[1].eventId == 5
                and unreliable.records[1].bodyLength == 5,
                "actual shared unreliable State kind-2 record")
        else
            assert(#observed.unreliable == 0, "unreliable State callback requires a raw packet")
        end
        table.insert(statePeerRows, observed)
    end

    local reliableStateFrame = statePeerRows[1].raw.Reliable[1]
    local unreliableStateBytes = 10
    local stateCharge = reliableStateFrame.length + reliableStateFrame.referenceCount * 8 + unreliableStateBytes
    assert(reliableStateFrame.length + reliableStateFrame.referenceCount * 8 == 244
        and stateCharge == 254
        and stateAfterRetry.outboundBytesCharged - stateBeforeFlush.outboundBytesCharged == stateCharge * #roster,
        "shared State charges exact frame bytes plus eight units per sidecar for every recipient")

    local malformedStatePacket = buffer.create(reliableStateFrame.length)
    for index, byte in reliableStateFrame.bytes do buffer.writeu8(malformedStatePacket, index - 1, byte) end
    local malformedStateOffset = 4
    for index = 1, #reliableStateFrame.records - 1 do
        malformedStateOffset += 2 + reliableStateFrame.records[index].bodyLength
    end
    local originalStateFinalLength = reliableStateFrame.records[#reliableStateFrame.records].bodyLength
    assert(reliableStateFrame.format == 5 and reliableStateFrame.kind == 2 and reliableStateFrame.count == 2
        and malformedStateOffset == 108 and buffer.readu16(malformedStatePacket, malformedStateOffset) == originalStateFinalLength,
        "shared State malformed probe targets the final valid kind-2 row")
    buffer.writeu16(malformedStatePacket, malformedStateOffset, 0)
    local malformedStateBytes = table.create(buffer.len(malformedStatePacket))
    for index = 0, buffer.len(malformedStatePacket) - 1 do
        malformedStateBytes[index + 1] = buffer.readu8(malformedStatePacket, index)
    end
    local hostileStateBaselines = {}
    for _, player in roster do
        hostileStateBaselines[player] = command(player, "broadcast-state-hostile-start")
    end
    local malformedStateBefore = session:GetDiagnostics().counters
    ReplicatedStorage.RelayRemotes.Reliable:FireAllClients(0, malformedStatePacket,
        statePart, stateFolder, statePart, stateFolder)
    local malformedStatePeers = {}
    for _, player in roster do
        local baseline = hostileStateBaselines[player]
        local observed = command(player, "broadcast-state-hostile-read", baseline)
        assert(observed.invalidPayload > baseline.invalidPayload
            and observed.reliableCallbacks == baseline.reliableCallbacks and #observed.frames == 1,
            "shared malformed State barrier rejects the entire frame without a partial callback")
        local raw = observed.frames[1]
        assert(raw.endpoint == 0 and raw.format == 5 and raw.kind == 2 and raw.count == 2
            and raw.referenceCount == 4 and raw.length == #malformedStateBytes
            and #raw.bytes == #malformedStateBytes and #raw.references == 4,
            "actual malformed shared State bytes and sidecars are captured")
        table.insert(malformedStatePeers, {
            client = player.UserId,
            invalidPayloadBefore = baseline.invalidPayload,
            invalidPayloadAfter = observed.invalidPayload,
            reliableCallbacksBefore = baseline.reliableCallbacks,
            reliableCallbacksAfter = observed.reliableCallbacks,
            frames = observed.frames,
        })
    end
    all("broadcast-state-hostile-stop")
    local malformedStateAfter = session:GetDiagnostics().counters
    assert(malformedStateAfter.broadcastHandoffs == malformedStateBefore.broadcastHandoffs
        and malformedStateAfter.sendHandoffs == malformedStateBefore.sendHandoffs
        and malformedStateAfter.outboundBytesCharged == malformedStateBefore.outboundBytesCharged,
        "direct malformed State injection stays outside Relay counters and budgets")

    -- Refill the retry debit before testing an independent recovery handoff.
    task.wait(stateRefillWaitSeconds)
    assert(stateLane.events.ReliableState:Put(3, "Normal", 33, "recovered", statePart, stateFolder))
    local stateRecoveryOk, stateRecoveryFailure, stateRecoveryReport = stateLane:Flush()
    assert(stateRecoveryOk, stateRecoveryFailure and stateRecoveryFailure.code or "shared State recovery flush")
    assert(stateRecoveryReport.selected == 1 and stateRecoveryReport.remaining == 0
        and stateRecoveryReport.reliableHandoffs == 1 and stateRecoveryReport.unreliableHandoffs == 0
        and stateRecoveryReport.logicalHandoffs == 1,
        "valid shared State frame recovers after malformed rejection")
    local stateRecoveryAfter = session:GetDiagnostics().counters
    local stateRecoveryPeers = {}
    for _, player in roster do
        local observed = command(player, "broadcast-state-read", { reliable = 3, reliableRaw = 2 })
        assert(observed.failure == nil and #observed.reliable == 3 and #observed.raw.Reliable == 2,
            "valid shared State recovery reaches every peer")
        local recoveryValue = observed.reliable[3]
        assert(recoveryValue.marker == 33 and recoveryValue.message == "recovered"
            and recoveryValue.part == statePart:GetFullName() and recoveryValue.folder == stateFolder:GetFullName(),
            "shared State recovery values preserve Instances")
        table.insert(stateRecoveryPeers, observed)
    end
    local stateRecoveryFrame = stateRecoveryPeers[1].raw.Reliable[2]
    local stateRecoveryCharge = stateRecoveryFrame.length + stateRecoveryFrame.referenceCount * 8
    assert(stateRecoveryFrame.endpoint == 0 and stateRecoveryFrame.format == 5 and stateRecoveryFrame.kind == 2
        and stateRecoveryFrame.count == 1 and stateRecoveryFrame.referenceCount == 2
        and stateRecoveryFrame.length == 24 and stateRecoveryCharge == 40
        and stateRecoveryAfter.broadcastHandoffs - stateAfterRetry.broadcastHandoffs == 1
        and stateRecoveryAfter.sendHandoffs == stateAfterRetry.sendHandoffs
        and stateRecoveryAfter.outboundBytesCharged - stateAfterRetry.outboundBytesCharged == stateRecoveryCharge * #roster,
        "valid State recovery is independently charged by exact frame and sidecar bytes")

    assert(stateLane.events.ReliableState:Put(4, "Normal", 44, "destroyed", statePart, stateFolder))
    local destroyStateBefore = session:GetDiagnostics().counters
    stateLane:Destroy()
    local destroyedStateStatus = stateLane:GetStatus()
    task.wait(0.2)
    local destroyStateAfter = session:GetDiagnostics().counters
    assert(destroyedStateStatus.state == "Destroyed" and destroyedStateStatus.pendingKeys == 0
        and destroyStateAfter.broadcastHandoffs == destroyStateBefore.broadcastHandoffs
        and destroyStateAfter.sendHandoffs == destroyStateBefore.sendHandoffs
        and destroyStateAfter.outboundBytesCharged == destroyStateBefore.outboundBytesCharged,
        "Destroy releases a pending shared State timer without a late send")
    local stateCleanupPeers = {}
    for _, player in roster do
        local observed = command(player, "broadcast-state-snapshot")
        assert(observed.failure == nil and #observed.reliable == 3
            and #observed.raw.Reliable == 2,
            "destroyed shared State lane delivers no pending value")
        table.insert(stateCleanupPeers, observed)
    end

    local stateCounters = {
        broadcastHandoffs = stateAfterRetry.broadcastHandoffs - stateAfterRefusal.broadcastHandoffs,
        sendHandoffs = stateAfterRetry.sendHandoffs - stateAfterRefusal.sendHandoffs,
        outboundBytesCharged = stateAfterRetry.outboundBytesCharged - stateAfterRefusal.outboundBytesCharged,
        perRecipientBytes = stateCharge,
    }
    local stateRetryBytes = {
        capacity = 256,
        refusal = { fullRefillWaitSeconds = stateRefillWaitSeconds, availableAfterPulse = 246, pulseCharge = 10,
            reliableCharge = 244, unreliableCharge = 10, combinedCharge = stateCharge,
            pulseToFlushSeconds = statePulseToFlushElapsed, pulseToRefusalSeconds = stateRefusalElapsed },
        reliable = { frameBytes = reliableStateFrame.length, referenceCount = reliableStateFrame.referenceCount,
            referenceBytes = reliableStateFrame.referenceCount * 8, charge = reliableStateFrame.length
                + reliableStateFrame.referenceCount * 8 },
        unreliable = { frameBytes = unreliableStateBytes, referenceCount = 0, referenceBytes = 0,
            charge = unreliableStateBytes },
        perRecipientBytes = stateCharge,
    }

    broadcastBatchingDiagnostics = {
        refusal = { code = refusal.code, selected = refusedReport.selected, remaining = refusedReport.remaining,
            pending = refusedStatus.pendingRecords, pulseAdmissions = pulseAdmissions, peers = refusalPeers },
        retry = retryReport,
        reuse = reuseReport,
        peers = peerRows,
        byteBreakdown = byteBreakdown,
        counters = {
            broadcastHandoffs = finalCounters.broadcastHandoffs - beforeFlush.broadcastHandoffs,
            sendHandoffs = finalCounters.sendHandoffs - beforeFlush.sendHandoffs,
            outboundBytesCharged = charged,
            perRecipientBytes = perRecipientBytes,
        },
        malformed = {
            injected = true,
            excludedFromLibraryDiagnosticsAndBudget = true,
            endpoint = 0,
            format = 5,
            kind = 1,
            count = 2,
            referenceCount = 4,
            length = #malformedBytes,
            finalLengthOffset = malformedOffset,
            originalFinalLength = 7,
            malformedFinalLength = 0,
            bytes = malformedBytes,
            libraryCountersBefore = {
                broadcastHandoffs = malformedInjectionBefore.broadcastHandoffs,
                sendHandoffs = malformedInjectionBefore.sendHandoffs,
                outboundBytesCharged = malformedInjectionBefore.outboundBytesCharged,
            },
            libraryCountersAfter = {
                broadcastHandoffs = malformedInjectionAfter.broadcastHandoffs,
                sendHandoffs = malformedInjectionAfter.sendHandoffs,
                outboundBytesCharged = malformedInjectionAfter.outboundBytesCharged,
            },
            peers = hostilePeers,
        },
        recovery = {
            report = recoveryReport,
            counters = {
                broadcastHandoffs = recoveryAfter.broadcastHandoffs - recoveryBefore.broadcastHandoffs,
                sendHandoffs = recoveryAfter.sendHandoffs - recoveryBefore.sendHandoffs,
                outboundBytesCharged = recoveryCharged,
                perRecipientBytes = recoveryCharged / #roster,
            },
            peers = recoveryPeers,
        },
        state = {
            pulseAdmissions = statePulseAdmissions,
            pulse = {
                charge = 10,
                countersBefore = {
                    broadcastHandoffs = stateBeforePulse.broadcastHandoffs,
                    sendHandoffs = stateBeforePulse.sendHandoffs,
                    outboundBytesCharged = stateBeforePulse.outboundBytesCharged,
                },
                countersAfter = {
                    broadcastHandoffs = stateBeforeFlush.broadcastHandoffs,
                    sendHandoffs = stateBeforeFlush.sendHandoffs,
                    outboundBytesCharged = stateBeforeFlush.outboundBytesCharged,
                },
            },
            refusal = { code = stateRefusal.code, selected = stateRefusedReport.selected,
                remaining = stateRefusedReport.remaining, pending = stateRefusedStatus.pendingKeys,
                fullRefillWaitSeconds = stateRefillWaitSeconds,
                availableAfterPulse = 246, pulseCharge = 10, reliableCharge = 244,
                unreliableCharge = 10, combinedCharge = stateCharge,
                pulseToFlushSeconds = statePulseToFlushElapsed, pulseToRefusalSeconds = stateRefusalElapsed,
                countersBefore = {
                    broadcastHandoffs = stateBeforeFlush.broadcastHandoffs,
                    sendHandoffs = stateBeforeFlush.sendHandoffs,
                    outboundBytesCharged = stateBeforeFlush.outboundBytesCharged,
                },
                countersAfter = {
                    broadcastHandoffs = stateAfterRefusal.broadcastHandoffs,
                    sendHandoffs = stateAfterRefusal.sendHandoffs,
                    outboundBytesCharged = stateAfterRefusal.outboundBytesCharged,
                },
            },
            noAutoDeferral = { pending = stateNoDeferralStatus.pendingKeys,
                elapsedBeforeExpiry = stateNoAutoElapsed,
                counters = {
                    broadcastHandoffs = stateAfterNoDeferral.broadcastHandoffs,
                    sendHandoffs = stateAfterNoDeferral.sendHandoffs,
                    outboundBytesCharged = stateAfterNoDeferral.outboundBytesCharged,
                },
            },
            retry = stateRetryReport,
            peers = statePeerRows,
            byteBreakdown = stateRetryBytes,
            counters = stateCounters,
            malformed = {
                injected = true,
                excludedFromLibraryDiagnosticsAndBudget = true,
                endpoint = 0,
                format = 5,
                kind = 2,
                count = 2,
                referenceCount = 4,
                length = #malformedStateBytes,
                finalLengthOffset = malformedStateOffset,
                originalFinalLength = originalStateFinalLength,
                malformedFinalLength = 0,
                bytes = malformedStateBytes,
                libraryCountersBefore = {
                    broadcastHandoffs = malformedStateBefore.broadcastHandoffs,
                    sendHandoffs = malformedStateBefore.sendHandoffs,
                    outboundBytesCharged = malformedStateBefore.outboundBytesCharged,
                },
                libraryCountersAfter = {
                    broadcastHandoffs = malformedStateAfter.broadcastHandoffs,
                    sendHandoffs = malformedStateAfter.sendHandoffs,
                    outboundBytesCharged = malformedStateAfter.outboundBytesCharged,
                },
                peers = malformedStatePeers,
            },
            recovery = {
                report = stateRecoveryReport,
                frame = stateRecoveryFrame,
                charge = stateRecoveryCharge,
                counters = {
                    broadcastHandoffs = stateRecoveryAfter.broadcastHandoffs - stateAfterRetry.broadcastHandoffs,
                    sendHandoffs = stateRecoveryAfter.sendHandoffs - stateAfterRetry.sendHandoffs,
                    outboundBytesCharged = stateRecoveryAfter.outboundBytesCharged - stateAfterRetry.outboundBytesCharged,
                    perRecipientBytes = stateRecoveryCharge,
                },
                peers = stateRecoveryPeers,
            },
            cleanup = { state = destroyedStateStatus.state, pending = destroyedStateStatus.pendingKeys,
                noLateHandoff = destroyStateAfter.broadcastHandoffs == destroyStateBefore.broadcastHandoffs,
                peers = stateCleanupPeers },
        },
        cleanup = { state = cancelledStatus.state, pending = cancelledStatus.pendingRecords,
            noLateHandoff = afterCancel.broadcastHandoffs == cancelCounters.broadcastHandoffs },
    }
    all("broadcast-destroy")
    session:Destroy()
    session = nil
    all("absent")
    mark("shared-broadcast-batching")
end

local function competitivePacedCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    local part, instanceRoot = Competitive.prepare()
    local created, problem = Relay.createServer(Competitive.createPaced(), {
        inboundRate = {
            perPlayer = { capacity = 128, refillPerSecond = 128 },
            aggregate = { capacity = 1024, refillPerSecond = 1024 },
        },
        instanceRoot = instanceRoot,
    })
    assert(created ~= nil, problem and problem.message or "competitive paced server creation")
    session = created
    local received = {}
    for _, player in roster do received[player] = { reliable = {}, unreliable = {}, raw = { Reliable = {}, Unreliable = {} } } end
    assert(session.events.ReliableInput:Connect(function(player, sequence, reference)
        assert(reference == part, "paced reliable Instance identity")
        table.insert(received[player].reliable, sequence)
    end))
    assert(session.events.UnreliableInput:Connect(function(player, sequence, reference)
        assert(reference == part, "paced unreliable Instance identity")
        table.insert(received[player].unreliable, sequence)
    end))
    assert(session:Start())
    all("competitive-paced-start")
    for _, channel in { "Reliable", "Unreliable" } do
        local remote = ReplicatedStorage.RelayRemotes[channel]
        table.insert(competitiveRawConnections, remote.OnServerEvent:Connect(function(player, endpoint, packet, ...)
            local target = received[player]
            if target == nil then return end
            local row = Competitive.rawBatchReceipt(channel, endpoint, packet, ...)
            if row ~= nil then table.insert(target.raw[channel], row) end
        end))
    end

    local preDue = {}
    for _, player in roster do preDue[player] = command(player, "competitive-paced-send") end
    for _, player in roster do
        local receipt = received[player]
        assert(preDue[player].selected == 0 and preDue[player].reliableHandoffs == 0
            and preDue[player].unreliableHandoffs == 0 and preDue[player].pendingRecords == 80
            and #receipt.raw.Reliable == 0 and #receipt.raw.Unreliable == 0
            and #receipt.reliable == 0 and #receipt.unreliable == 0,
            "manual pacer produces no native sends before its first due time")
    end

    local steps = {}
    for stepIndex, selected in { 32, 32, 16 } do
        task.wait(if stepIndex == 2 then 0.35 else 0.12)
        for _, player in roster do
            local step = command(player, "competitive-paced-step")
            local report = step.report
            assert(report.selected == selected and report.reliableHandoffs == 1
                and report.unreliableHandoffs == 1 and report.logicalHandoffs == selected,
                "one bounded per-channel round per manual paced step")
            table.insert(steps, { client = if player == roster[1] then 1 else 2,
                selected = report.selected, reliableHandoffs = report.reliableHandoffs,
                unreliableHandoffs = report.unreliableHandoffs,
                logicalHandoffs = report.logicalHandoffs, pendingRecords = step.pendingRecords })
        end
        if stepIndex < 3 then task.wait(0.01) end
    end
    waitFor(function()
        for _, player in roster do if #received[player].reliable ~= 40 then return false end end
        return true
    end, "paced reliable FIFO callbacks", 15)

    local clients = {}
    for clientIndex, player in roster do
        local row = received[player]
        assert(#row.raw.Reliable == 3 and #row.reliable == 40,
            "paced reliable emits three actual native frames for forty rows")
        local reliableSequence = 0
        for frameIndex, expectedCount in { 16, 16, 8 } do
            local frame = row.raw.Reliable[frameIndex]
            assert(frame.endpoint == 0 and frame.format == 5 and frame.kind == 1
                and frame.count == expectedCount and frame.referenceCount == expectedCount
                and frame.length + frame.referenceCount * 8 <= 8_192,
                "paced actual reliable BatchFrame record/reference/byte caps")
            for _, record in frame.records do
                assert(record.codec == 4 and record.eventId == 1 and record.referenceCount == 1,
                    "paced reliable frame contains only its declared native route")
                reliableSequence += 1
                assert(record.value == reliableSequence, "paced reliable frame rows preserve FIFO sequence")
            end
        end
        for sequence = 1, 40 do assert(row.reliable[sequence] == sequence, "paced reliable FIFO callback order") end
        assert(#row.raw.Unreliable <= 3 and #row.unreliable <= 40,
            "paced unreliable transport loss is permitted within the fixed bound")
        local unreliableRows = 0
        local unreliableSequences = {}
        for _, frame in row.raw.Unreliable do
            assert(frame.endpoint == 0 and frame.format == 5 and frame.kind == 1
                and frame.count <= 16 and frame.referenceCount == frame.count
                and frame.length + frame.referenceCount * 8 <= 900,
                "paced actual unreliable BatchFrame obeys row/reference/byte caps")
            unreliableRows += frame.count
            local previous = 0
            for _, record in frame.records do
                assert(record.codec == 4 and record.eventId == 2 and record.referenceCount == 1,
                    "paced unreliable frame contains only its declared route")
                assert(record.value > previous and record.value >= 1 and record.value <= 40,
                    "each observed unreliable frame preserves its internal FIFO order")
                previous = record.value
                unreliableSequences[record.value] = true
            end
        end
        if #row.raw.Unreliable > 0 then
            assert(#row.unreliable == unreliableRows, "observed unreliable packet dispatches all frame rows")
            for _, sequence in row.unreliable do
                assert(unreliableSequences[sequence], "unreliable callback corresponds to an observed frame row")
                unreliableSequences[sequence] = nil
            end
            assert(next(unreliableSequences) == nil, "observed unreliable frame rows all reach callbacks")
        else
            assert(#row.unreliable == 0, "unreliable callbacks require an observed packet")
        end
        local destroyed = command(player, "competitive-paced-destroy")
        assert(destroyed.pendingBefore == 2 and destroyed.pendingAfter == 0 and destroyed.state == "Terminal",
            "paced destroy clears a newly queued unsent tail")
        local function compactFrames(frames)
            local result = table.create(#frames)
            for index, frame in frames do
                result[index] = { format = frame.format, kind = frame.kind, count = frame.count,
                    referenceCount = frame.referenceCount, length = frame.length }
            end
            return result
        end
        table.insert(clients, { client = clientIndex, reliableCallbacks = #row.reliable,
            reliableFirst = row.reliable[1], reliableLast = row.reliable[#row.reliable],
            reliableFrames = compactFrames(row.raw.Reliable), unreliableCallbacks = #row.unreliable,
            unreliableFrames = compactFrames(row.raw.Unreliable), destroy = destroyed })
    end
    local reliableFrameCount, unreliableFrameCount, reliableCallbacks, unreliableCallbacks = 0, 0, 0, 0
    for _, player in roster do
        local row = received[player]
        reliableFrameCount += #row.raw.Reliable
        unreliableFrameCount += #row.raw.Unreliable
        reliableCallbacks += #row.reliable
        unreliableCallbacks += #row.unreliable
    end
    task.wait(0.15)
    for _, player in roster do
        assert(#received[player].raw.Reliable == 3 and #received[player].raw.Unreliable <= 3
            and #received[player].reliable == 40,
            "destroyed paced tail produces no late native frame or callback")
    end
    session:Destroy()
    session = nil
    for _, item in competitiveRawConnections do item:Disconnect() end
    table.clear(competitiveRawConnections)
    all("absent")
    return { steps = steps, clients = clients, reliableFrames = reliableFrameCount,
        unreliableFrames = unreliableFrameCount, reliableCallbacks = reliableCallbacks,
        unreliableCallbacks = unreliableCallbacks, destroyedLateCalls = 0 }
end

local function competitiveIndependentStateCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    Competitive.prepare()
    local created, problem = Relay.createServer(Competitive.createIndependent(), {
        inboundRate = {
            perPlayer = { capacity = 128, refillPerSecond = 128 },
            aggregate = { capacity = 1024, refillPerSecond = 1024 },
        },
    })
    assert(created ~= nil, problem and problem.message or "competitive independent State server creation")
    session = created
    assert(session:Start())
    all("competitive-independent-start")
    local function drain(player)
        local ok, failure = session.events.Drain:Send(player, 1)
        assert(ok, failure and failure.code or "outbound budget drain")
    end
    drain(roster[1])
    drain(roster[1])
    local atomicBefore = session:GetDiagnostics().counters
    local atomic = assert(session:CreateState(roster, 0.1, { deferOutbound = true }))
    assert(atomic.events.ReliableState:Put(1, "Normal", 4))
    assert(atomic.events.UnreliableState:Put(2, "Normal", 7))
    local atomicOk, atomicFailure, atomicReport = atomic:Flush()
    local atomicAfter = session:GetDiagnostics().counters
    assert(not atomicOk and atomicFailure.code == "OutboundRateLimited" and atomicReport.selected == 0
        and atomicReport.remaining == 2
        and atomicAfter.outboundBytesCharged == atomicBefore.outboundBytesCharged
        and atomicAfter.sendHandoffs == atomicBefore.sendHandoffs,
        "deferred multi-recipient State refuses both channels without partial debit or native calls")
    atomic:Destroy()
    task.wait(0.1)

    local lane = assert(session:CreateState(roster, 0.1,
        { deferOutbound = true, progress = "Independent" }))
    assert(lane.events.ReliableState:Put(1, "Normal", 4))
    assert(lane.events.ReliableState:Put(1, "High", 9))
    assert(lane.events.UnreliableState:Put(2, "Normal", 7))
    local firstOk, firstFailure, firstReport = lane:Flush()
    assert(not firstOk and firstFailure ~= nil and firstFailure.code == "OutboundRateLimited",
        "independent State reports blocked-recipient refusal after affordable-peer progress")
    assert(firstReport.selected == 2 and firstReport.remaining == 2
        and firstReport.reliableHandoffs == 1 and firstReport.unreliableHandoffs == 1,
        "independent State consumes both channels for the one affordable recipient")
    local firstCounters = session:GetDiagnostics().counters
    local initialBudgetCharge = firstCounters.outboundBytesCharged - atomicAfter.outboundBytesCharged
    local initialNativeHandoffs = firstCounters.sendHandoffs - atomicAfter.sendHandoffs
    assert(initialBudgetCharge == 18 and initialNativeHandoffs == 2,
        "independent progress charges and hands off exactly both channels for one recipient")
    assert(type(firstReport.recipients) == "table" and #firstReport.recipients == 2,
        "independent report contains the captured recipient rows")
    local firstRecipients = {}
    for index, target in { roster[1], roster[2] } do
        local progress = firstReport.recipients[index]
        assert(progress.player == target and progress.selected == (if index == 1 then 0 else 2)
            and progress.remaining == (if index == 1 then 2 else 0)
            and progress.reliableHandoffs == (if index == 1 then 0 else 1)
            and progress.unreliableHandoffs == (if index == 1 then 0 else 1)
            and progress.logicalHandoffs == (if index == 1 then 0 else 2)
            and (if index == 1 then progress.error ~= nil and progress.error.code == "OutboundRateLimited"
                else progress.error == nil),
            "independent per-recipient channel-atomic progress")
        table.insert(firstRecipients, { recipient = index, selected = progress.selected,
            remaining = progress.remaining, reliableHandoffs = progress.reliableHandoffs,
            unreliableHandoffs = progress.unreliableHandoffs, logicalHandoffs = progress.logicalHandoffs,
            error = if progress.error == nil then "none" else progress.error.code })
    end
    waitFor(function()
        local status = lane:GetStatus()
        return status.pendingKeys == 0
    end, "independent State refill retry", 0.9)
    local finalStatus = lane:GetStatus()
    local finalCounters = session:GetDiagnostics().counters
    local retryBudgetCharge = finalCounters.outboundBytesCharged - firstCounters.outboundBytesCharged
    local retryNativeHandoffs = finalCounters.sendHandoffs - firstCounters.sendHandoffs
    assert(finalStatus.pendingKeys == 0 and type(finalStatus.recipients) == "table"
        and #finalStatus.recipients == 2 and retryBudgetCharge == 18 and retryNativeHandoffs == 2,
        "independent State retries only the blocked recipient after exact refill charge")
    assert(finalStatus.recipients[1].selected == 2 and finalStatus.recipients[1].remaining == 0
        and finalStatus.recipients[1].reliableHandoffs == 1 and finalStatus.recipients[1].unreliableHandoffs == 1
        and finalStatus.recipients[2].selected == 0 and finalStatus.recipients[2].remaining == 0
        and finalStatus.recipients[2].reliableHandoffs == 0 and finalStatus.recipients[2].unreliableHandoffs == 0,
        "refill retry reports no replay for the recipient already served")
    local clients = {}
    local function compactFrames(frames)
        local result = table.create(#frames)
        for index, frame in frames do
            result[index] = { format = frame.format, kind = frame.kind, count = frame.count,
                length = frame.length, eventId = frame.records[1] and frame.records[1].eventId }
        end
        return result
    end
    for clientIndex, player in roster do
        local observed = command(player, "competitive-independent-read")
        assert(#observed.reliable == 1 and observed.reliable[1] == 9,
            "independent State emits only the latest replacement")
        assert(#observed.reliableRaw == 1 and observed.reliableRaw[1].kind == 2
            and observed.reliableRaw[1].format == 2 and observed.reliableRaw[1].count == 1
            and observed.reliableRaw[1].records[1].eventId == 2,
            "actual reliable State kind-2 handoff")
        assert(#observed.unreliableRaw <= 1 and #observed.unreliable <= 1,
            "unreliable State receipt is bounded under permitted packet loss")
        if #observed.unreliableRaw == 1 then
            assert(#observed.unreliable == 1 and observed.unreliable[1] == 7
                and observed.unreliableRaw[1].kind == 2 and observed.unreliableRaw[1].count == 1
                and observed.unreliableRaw[1].records[1].eventId == 3,
                "observed unreliable State packet dispatches its complete selected snapshot")
        else
            assert(#observed.unreliable == 0, "unreliable State callback requires observed raw packet")
        end
        table.insert(clients, { client = clientIndex, reliable = observed.reliable,
            reliableRaw = compactFrames(observed.reliableRaw), unreliable = observed.unreliable,
            unreliableRaw = compactFrames(observed.unreliableRaw) })
    end
    local beforeExpiry = session:GetDiagnostics().counters.sendHandoffs
    local expiring = assert(session:CreateState(roster, 0.1,
        { deferOutbound = true, progress = "Independent" }))
    assert(expiring.events.SlowState:Put(1, "Normal", string.rep("x", 64)))
    task.wait(1.1)
    local expiredStatus = expiring:GetStatus()
    assert(expiredStatus.pendingKeys == 0 and session:GetDiagnostics().counters.sendHandoffs == beforeExpiry,
        "unaffordable independent State expires without a late native handoff")
    expiring:Destroy()
    local destroyed = assert(session:CreateState(roster, 0.1,
        { deferOutbound = true, progress = "Independent" }))
    assert(destroyed.events.ReliableState:Put(1, "Normal", 11))
    local beforeDestroy = session:GetDiagnostics().counters.sendHandoffs
    destroyed:Destroy()
    task.wait(0.15)
    assert(destroyed:GetStatus().pendingKeys == 0
        and session:GetDiagnostics().counters.sendHandoffs == beforeDestroy,
        "destroyed independent State cannot hand off retained work later")
    lane:Destroy()
    for _, player in roster do command(player, "competitive-independent-destroy") end
    session:Destroy()
    session = nil
    all("absent")
    return { atomic = { ok = atomicOk, error = atomicFailure.code, selected = atomicReport.selected,
        remaining = atomicReport.remaining, noDebit = true, noHandoffs = true },
        independent = { firstRecipients = firstRecipients, retryCleared = finalStatus.pendingKeys == 0,
            initialBudgetCharge = initialBudgetCharge, initialNativeHandoffs = initialNativeHandoffs,
            retryBudgetCharge = retryBudgetCharge, retryNativeHandoffs = retryNativeHandoffs, clients = clients },
        expiry = { pendingAfterExpiry = expiredStatus.pendingKeys, lateHandoffs = 0 },
        destroy = { pendingAfterDestroy = 0, lateHandoffs = 0 } }
end

local function competitiveTimestampsCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    Competitive.prepare()
    local created, problem = Relay.createServer(Competitive.createTimestamps(), {
        inboundRate = {
            perPlayer = { capacity = 256, refillPerSecond = 128 },
            aggregate = { capacity = 2048, refillPerSecond = 1024 },
            endpoints = {
                [1] = { capacity = 32, refillPerSecond = 16 },
                [2] = { capacity = 32, refillPerSecond = 16 },
                [3] = { capacity = 32, refillPerSecond = 16 },
                [4] = { capacity = 32, refillPerSecond = 16 },
                [5] = { capacity = 32, refillPerSecond = 16 },
            },
            bytes = {
                perPlayer = { capacity = 8192, refillPerSecond = 8192 },
                aggregate = { capacity = 16384, refillPerSecond = 16384 },
            },
        },
        diagnostics = { traffic = true, reports = true },
    })
    assert(created ~= nil, problem and problem.message or "competitive timestamp server creation")
    session = created
    local calls = {}
    for _, player in roster do calls[player] = { reliable = {}, unreliable = {}, ordered = {}, batch = {}, state = {} } end
    for _, name in { "ReliableInput", "UnreliableInput", "OrderedInput", "BatchInput", "StateInput" } do
        local destination = if name == "ReliableInput" then "reliable"
            elseif name == "UnreliableInput" then "unreliable"
            elseif name == "OrderedInput" then "ordered"
            elseif name == "BatchInput" then "batch" else "state"
        assert(session.events[name]:Connect(function(player, serverTime, value)
            table.insert(calls[player][destination], { serverTime = serverTime,
                deliveredAt = Workspace:GetServerTimeNow(), value = value })
        end))
    end
    assert(session:Start())
    all("competitive-timestamps-start")
    local raw = { Reliable = {}, Unreliable = {} }
    for _, channel in { "Reliable", "Unreliable" } do
        local remote = ReplicatedStorage.RelayRemotes[channel]
        table.insert(competitiveRawConnections, remote.OnServerEvent:Connect(function(player, endpoint, ...)
            local args = table.pack(...)
            if endpoint == 0 and typeof(args[1]) == "buffer" then
                local ok, row = pcall(Competitive.rawBatchReceipt, channel, endpoint, args[1],
                    table.unpack(args, 2, args.n))
                if ok and row ~= nil then
                    row.client = if player == roster[1] then 1 else 2
                    table.insert(raw[channel], row)
                end
            elseif (endpoint == 1 or endpoint == 2) and typeof(args[1]) == "buffer" then
                local packet = args[1]
                if buffer.len(packet) == 12 and buffer.readu8(packet, 0) == 1
                    and buffer.readu16(packet, 1) == endpoint then
                    table.insert(raw[channel], { endpoint = endpoint,
                        client = if player == roster[1] then 1 else 2,
                        serverTime = buffer.readf64(packet, 3), value = buffer.readu8(packet, 11),
                        length = buffer.len(packet) })
                end
            elseif endpoint == 3 and typeof(args[1]) == "buffer" then
                local packet = args[1]
                if buffer.len(packet) == 20 and buffer.readu8(packet, 0) == 3 then
                    table.insert(raw[channel], { endpoint = endpoint, client = if player == roster[1] then 1 else 2,
                        format = 3,
                        eventId = buffer.readu16(packet, 1), generation = buffer.readu32(packet, 3),
                        sequence = buffer.readu32(packet, 7), serverTime = buffer.readf64(packet, 11),
                        value = buffer.readu8(packet, 19), receivedAt = Workspace:GetServerTimeNow(),
                        length = buffer.len(packet) })
                end
            end
        end))
    end
    local function orderedFramesFor(clientIndex)
        local result = {}
        for _, frame in raw.Unreliable do
            if frame.endpoint == 3 and frame.client == clientIndex then table.insert(result, frame) end
        end
        return result
    end
    local function expectedOrderedValues(clientIndex)
        local expected, highestSequence = {}, 0
        for _, frame in orderedFramesFor(clientIndex) do
            if frame.value == 3 or frame.value == 5 then
                if frame.sequence > highestSequence then
                    expected[frame.value] = (expected[frame.value] or 0) + 1
                    highestSequence = frame.sequence
                end
            end
        end
        return expected
    end
    local function orderedCallbacksMatchObserved()
        for clientIndex, player in roster do
            local expectedValues = expectedOrderedValues(clientIndex)
            for _, frame in orderedFramesFor(clientIndex) do
                if frame.value ~= 3 and frame.value ~= 5
                    and frame.value ~= 49 and frame.value ~= 50 and frame.value ~= 51 then
                    return false
                end
            end
            local callbackValues = {}
            for _, record in calls[player].ordered do
                if record.value == 3 or record.value == 5 then
                    callbackValues[record.value] = (callbackValues[record.value] or 0) + 1
                else
                    return false
                end
            end
            if (expectedValues[3] or 0) ~= (callbackValues[3] or 0)
                or (expectedValues[5] or 0) ~= (callbackValues[5] or 0) then return false end
        end
        return true
    end
    local function orderedInvalidCount()
        local count = 0
        for _, frame in orderedFramesFor(1) do
            if frame.value == 49 or frame.value == 50 or frame.value == 51 then count += 1 end
        end
        return count
    end
    local function orderedRecoveryObserved()
        local sawInvalid = false
        for _, frame in orderedFramesFor(1) do
            if frame.value == 49 or frame.value == 50 or frame.value == 51 then
                sawInvalid = true
            elseif frame.value == 5 and frame.sequence == 2 and sawInvalid then
                return true
            end
        end
        return false
    end
    local function staleUnreliableCount()
        local count = 0
        for _, frame in raw.Unreliable do
            if frame.endpoint == 2 and frame.value == 47 then count += 1 end
        end
        return count
    end
    local function unreliableCallbacksMatchObserved()
        for clientIndex, player in roster do
            local observedValid = 0
            for _, frame in raw.Unreliable do
                if frame.endpoint == 2 and frame.client == clientIndex then
                    if frame.value == 2 then
                        observedValid += 1
                    elseif frame.value ~= 47 then
                        return false
                    end
                end
            end
            local deliveredValid = 0
            for _, record in calls[player].unreliable do
                if record.value == 2 then deliveredValid += 1 else return false end
            end
            if deliveredValid ~= observedValid then return false end
        end
        return true
    end
    for _, player in roster do command(player, "competitive-timestamps-send") end
    waitFor(function()
        for _, player in roster do
            local row = calls[player]
            if #row.reliable ~= 1 or #row.batch ~= 1 or #row.state ~= 1 then return false end
        end
        return true
    end, "valid timestamps on reliable, Batch, and State paths", 15)
    waitFor(orderedCallbacksMatchObserved,
        "observed initial ordered unreliable timestamps finish without requiring delivery", 5)
    local beforeInvalid = session:GetDiagnostics()
    command(roster[1], "competitive-timestamps-invalid")
    waitFor(function()
        local diagnostics = session:GetDiagnostics()
        local observedOrderedInvalid = orderedInvalidCount()
        return diagnostics.events.BatchInput.invalidPayload >= beforeInvalid.events.BatchInput.invalidPayload + 2
            and diagnostics.events.StateInput.invalidPayload >= beforeInvalid.events.StateInput.invalidPayload + 1
            and diagnostics.counters.invalidPayload >= beforeInvalid.counters.invalidPayload + 5 + observedOrderedInvalid
            and diagnostics.events.ReliableInput.invalidPayload >= beforeInvalid.events.ReliableInput.invalidPayload + 1
            and observedOrderedInvalid >= 1
            and diagnostics.events.OrderedInput.invalidPayload
                >= beforeInvalid.events.OrderedInput.invalidPayload + observedOrderedInvalid
            and orderedRecoveryObserved() and orderedCallbacksMatchObserved()
    end, "observed ordered timestamp probes reject before low-sequence recovery", 10)
    task.wait(0.15)
    local recovery = session:GetDiagnostics()
    local batchRow = recovery.traffic.endpoints[4].channels.Reliable
    local stateRow = recovery.traffic.endpoints[5].channels.Reliable
    assert(batchRow.validatedRecords == 3 and batchRow.validatedBytes == 36
        and stateRow.validatedRecords == 3 and stateRow.validatedBytes == 56,
        "only valid Batch and State rows contribute validated units")
    local clients = {}
    local orderedRawObservations, actualQueuedFrames = {}, 0
    for clientIndex, player in roster do
        assert(#calls[player].reliable == 1 and orderedCallbacksMatchObserved()
            and #calls[player].batch == (if player == roster[1] then 2 else 1)
            and #calls[player].state == (if player == roster[1] then 2 else 1),
            "invalid timestamps never reach callbacks and valid recovery does")
        assert(calls[player].batch[1].value == 4
            and (player ~= roster[1] or calls[player].batch[2].value == 6),
            "stale and malformed final Batch rows suppress the entire frame")
        assert(calls[player].state[1].value == "state"
            and (player ~= roster[1] or calls[player].state[2].value == "recover"),
            "stale final State row suppresses the whole frame before valid recovery")
        local reliableRaw = {}
        for _, frame in raw.Reliable do
            if frame.client == clientIndex and frame.endpoint == 1 then table.insert(reliableRaw, frame) end
        end
        assert(#reliableRaw == (if clientIndex == 1 then 2 else 1)
            and reliableRaw[1].length == 12 and reliableRaw[1].value == 1,
            "each client hands off its stamped reliable event as the checked codec buffer")
        if clientIndex == 1 then
            assert(reliableRaw[2].length == 12 and reliableRaw[2].value == 48,
                "stale reliable timestamp probe reaches the timestamp validator as a checked codec buffer")
        end
        for _, values in { calls[player].reliable, calls[player].unreliable, calls[player].ordered,
            calls[player].batch, calls[player].state } do
            for _, record in values do
                assert(record.serverTime >= record.deliveredAt - 2.1
                    and record.serverTime <= record.deliveredAt + 0.1,
                    "callback receives the finite server-clock timestamp")
            end
        end
        local expectedOrdered = expectedOrderedValues(clientIndex)
        local actualOrdered = {}
        for _, record in calls[player].ordered do
            actualOrdered[record.value] = (actualOrdered[record.value] or 0) + 1
        end
        assert(#calls[player].ordered == (expectedOrdered[3] or 0) + (expectedOrdered[5] or 0)
            and (actualOrdered[3] or 0) == (expectedOrdered[3] or 0)
            and (actualOrdered[5] or 0) == (expectedOrdered[5] or 0),
            "ordered callbacks match the received valid sequence progression")
        local batchRaw, stateRaw = {}, {}
        for _, frame in raw.Reliable do
            if frame.client == clientIndex and frame.kind == 1
                and frame.records[1] and frame.records[1].eventId == 4 then
                table.insert(batchRaw, frame)
            elseif frame.client == clientIndex and frame.kind == 2
                and frame.records[1] and frame.records[1].eventId == 5 then
                table.insert(stateRaw, frame)
            end
        end
        assert(#batchRaw == (if clientIndex == 1 then 4 else 1)
            and #stateRaw == (if clientIndex == 1 then 3 else 1),
            "each client hands off its own timestamp Batch and State frames, including the rejected State probe")
        actualQueuedFrames += #batchRaw + #stateRaw
        for _, frame in batchRaw do
            assert(frame.records[1].bodyBytes >= 12 and type(frame.records[1].serverTime) == "number",
                "queued timestamp is an inline eight-byte f64 field")
        end
        for _, frame in stateRaw do
            assert(frame.records[1].bodyBytes >= 12 and type(frame.records[1].serverTime) == "number",
                "queued timestamp is an inline eight-byte f64 field")
        end
        table.insert(clients, { client = clientIndex, reliable = #calls[player].reliable,
            unreliable = #calls[player].unreliable, ordered = #calls[player].ordered,
            batch = #calls[player].batch, state = #calls[player].state })
    end
    waitFor(function()
        return session:GetDiagnostics().events.UnreliableInput.invalidPayload
                >= beforeInvalid.events.UnreliableInput.invalidPayload + staleUnreliableCount()
            and unreliableCallbacksMatchObserved()
    end, "observed unreliable native timestamp callbacks finish without requiring delivery", 3)
    local beforeByteBudgetProbe = session:GetDiagnostics().counters.perPlayerBytes
    command(roster[1], "competitive-timestamps-byte-budget")
    waitFor(function()
        return session:GetDiagnostics().counters.perPlayerBytes >= beforeByteBudgetProbe + 1
    end, "configured byte admission refuses an over-cap native frame before decoding", 5)
    local oversizedByteRefused = session:GetDiagnostics().counters.perPlayerBytes >= beforeByteBudgetProbe + 1
    assert(oversizedByteRefused, "native over-cap packet is refused by the configured byte budget")
    waitFor(function()
        local diagnostics = session:GetDiagnostics()
        return diagnostics.events.OrderedInput.invalidPayload
                == beforeInvalid.events.OrderedInput.invalidPayload + orderedInvalidCount()
            and diagnostics.events.UnreliableInput.invalidPayload
                == beforeInvalid.events.UnreliableInput.invalidPayload + staleUnreliableCount()
            and orderedRecoveryObserved() and orderedCallbacksMatchObserved() and unreliableCallbacksMatchObserved()
    end, "final observed unreliable timestamp set matches rejection diagnostics and callbacks", 5)
    local finalDiagnostics = session:GetDiagnostics()
    local observedOrderedInvalid, unreliableObserved = orderedInvalidCount(), 0
    assert(observedOrderedInvalid >= 1 and orderedRecoveryObserved()
        and finalDiagnostics.events.OrderedInput.invalidPayload
            == beforeInvalid.events.OrderedInput.invalidPayload + observedOrderedInvalid,
        "every observed ordered timestamp probe has one rejection report")
    assert(finalDiagnostics.events.UnreliableInput.invalidPayload
        == beforeInvalid.events.UnreliableInput.invalidPayload + staleUnreliableCount(),
        "every observed stale unreliable timestamp has one rejection report")
    local orderedGenerations = {}
    for clientIndex, player in roster do
        for _, frame in orderedFramesFor(clientIndex) do
            assert(frame.eventId == 3 and frame.length == 20 and frame.format == 3 and frame.generation > 0,
                "observed ordered frame has its expected epoch and fixed wire shape")
            if orderedGenerations[clientIndex] == nil then
                orderedGenerations[clientIndex] = frame.generation
            else
                assert(frame.generation == orderedGenerations[clientIndex], "ordered frame keeps its client epoch")
            end
            if frame.value == 3 or frame.value == 5 then
                assert(frame.sequence == (if frame.value == 3 then 1 else 2)
                    and frame.serverTime >= frame.receivedAt - 2.1 and frame.serverTime <= frame.receivedAt + 0.1,
                    "observed valid ordered frame has its expected sequence and server timestamp")
            elseif frame.value == 49 then
                assert(frame.sequence == 100 and frame.serverTime < frame.receivedAt - 2,
                    "observed stale ordered probe reaches timestamp validation")
            elseif frame.value == 50 then
                assert(frame.sequence == 101 and frame.serverTime > frame.receivedAt + 0.1,
                    "observed future ordered probe reaches timestamp validation")
            else
                assert(frame.value == 51 and frame.sequence == 102 and frame.serverTime == math.huge,
                    "observed nonfinite ordered probe reaches timestamp validation")
            end
            table.insert(orderedRawObservations, { client = clientIndex, sequence = frame.sequence,
                generation = frame.generation, value = frame.value, length = frame.length })
        end
        clients[clientIndex].ordered = #calls[player].ordered
        clients[clientIndex].unreliable = #calls[player].unreliable
    end
    for _, frame in raw.Unreliable do
        if frame.endpoint == 2 then
            unreliableObserved += 1
            local matchingCallbacks = 0
            local player = roster[frame.client]
            for _, record in calls[player].unreliable do
                if record.value == frame.value then matchingCallbacks += 1 end
            end
            assert(matchingCallbacks == (if frame.value == 2 then 1 else 0),
                "observed unreliable timestamp passes only when its server time is valid")
        end
    end
    for _, item in competitiveRawConnections do item:Disconnect() end
    table.clear(competitiveRawConnections)
    session:Destroy()
    session = nil
    for _, player in roster do command(player, "competitive-timestamps-destroy") end
    all("absent")
    return { clients = clients, invalid = { batchFrames = 3, ordered = observedOrderedInvalid, reliable = 1, state = 1,
        oversizedByteRefused = oversizedByteRefused, wholeFrameRejected = true, orderedRecovery = true },
        orderedRawObservations = orderedRawObservations, actualOrderedFrames = #orderedRawObservations,
        actualQueuedFrames = actualQueuedFrames, unreliableObserved = unreliableObserved }
end

local function competitiveDiagnosticsCorrectness()
    if session then session:Destroy() session = nil end
    all("absent")
    Competitive.prepare()
    local created, problem = Relay.createServer(Competitive.createDiagnostics(), {
        inboundRate = {
            perPlayer = { capacity = 128, refillPerSecond = 128 },
            aggregate = { capacity = 1024, refillPerSecond = 1024 },
        },
        diagnostics = { traffic = true, reports = true },
    })
    assert(created ~= nil, problem and problem.message or "competitive diagnostics server creation")
    session = created
    local calls = { input = {}, unreliableInput = {}, batchInput = {}, requests = {} }
    local raw = { Reliable = {}, Unreliable = {} }
    for _, player in roster do
        calls.input[player], calls.unreliableInput[player], calls.batchInput[player], calls.requests[player] = {}, {}, {}, {}
    end
    assert(session.events.Input:Connect(function(player, value)
        if value == 99 then error("competitive diagnostics handler proof") end
        table.insert(calls.input[player], value)
    end))
    assert(session.events.UnreliableInput:Connect(function(player, value)
        table.insert(calls.unreliableInput[player], value)
    end))
    assert(session.events.BatchInput:Connect(function(player, value)
        table.insert(calls.batchInput[player], value)
    end))
    assert(session.requests.Inspect:Connect(function(player, value)
        table.insert(calls.requests[player], value)
        return value + 1
    end))
    assert(session:Start())
    local initial = session:GetDiagnostics()
    for _, channel in { "Reliable", "Unreliable" } do
        local remote = ReplicatedStorage.RelayRemotes[channel]
        table.insert(competitiveRawConnections, remote.OnServerEvent:Connect(function(player, endpoint, ...)
            local arguments = table.pack(...)
            local entry = { client = if player == roster[1] then 1 else 2, endpoint = endpoint, channel = channel }
            if endpoint == 0 and typeof(arguments[1]) == "buffer" then
                local packet = arguments[1]
                local tag = buffer.readu8(packet, 0)
                if (tag == 1 or tag == 7) and buffer.len(packet) >= 47 then
                    entry.methodId = buffer.readu16(packet, 2)
                    entry.rpcKind = buffer.readu8(packet, 1)
                    entry.length = buffer.len(packet)
                    entry.referenceCount = arguments.n - 1
                    table.insert(raw[channel], entry)
                else
                    local ok, frame = pcall(Competitive.rawBatchReceipt, channel, endpoint, packet,
                        table.unpack(arguments, 2, arguments.n))
                    if ok and frame ~= nil then
                        entry.frame = frame
                        table.insert(raw[channel], entry)
                    end
                end
            elseif endpoint == 1 then
                entry.value = arguments[1]
                table.insert(raw[channel], entry)
            elseif endpoint == 2 then
                entry.value = Competitive.codecByte(arguments[1], 2)
                entry.length = if entry.value == nil then nil else 4
                table.insert(raw[channel], entry)
            end
        end))
    end
    all("competitive-diagnostics-start")
    waitQueuedReady("Output", queuedPlayerIds(roster))
    local ready = session:GetDiagnostics()
    assert(ready.traffic ~= nil and ready.reports ~= nil,
        "server exposes only requested diagnostics snapshots")
    local controlReceives = ready.traffic.channels.Reliable.receivedPackets
        - initial.traffic.channels.Reliable.receivedPackets
    assert(controlReceives >= #roster, "readiness/control packets are counted at channel scope")
    for _, player in roster do assert(command(player, "competitive-diagnostics-baseline")) end
    for id, endpoint in initial.traffic.endpoints do
        for _, channel in { "Reliable", "Unreliable" } do
            assert(ready.traffic.endpoints[id].channels[channel].receivedPackets
                == endpoint.channels[channel].receivedPackets,
                "readiness/control packets are not attributed to an application endpoint")
        end
    end

    for _, player in roster do command(player, "competitive-diagnostics-send") end
    waitFor(function()
        for _, player in roster do
            if #calls.input[player] ~= 1 or #calls.batchInput[player] ~= 1 or #calls.requests[player] ~= 1 then return false end
        end
        return true
    end, "diagnostics observes immediate, Batch, and RPC C2S routes", 12)
    local beforeOutput = session:GetDiagnostics()

    local target = roster[1]
    assert(session.events.Output:Send(target, 10))
    assert(session.events.Output:Broadcast(11))
    assert(session.events.UnreliableOutput:Broadcast(12))
    local batcher = assert(session:CreateBroadcastBatcher(0.1))
    assert(batcher.events.BatchOutput:Send(13))
    local batchOk, batchFailure, batchReport = batcher:Flush()
    assert(batchOk, batchFailure and batchFailure.code or "diagnostics shared Batch handoff")
    local state = assert(session:CreateBroadcastState(0.1))
    assert(state.events.StateOutput:Put(1, "Normal", 14))
    local stateOk, stateFailure, stateReport = state:Flush()
    assert(stateOk, stateFailure and stateFailure.code or "diagnostics shared State handoff")
    assert(batchReport.selected == 1 and batchReport.reliableHandoffs == 1
        and batchReport.logicalHandoffs == 1 and stateReport.selected == 1
        and stateReport.reliableHandoffs == 1 and stateReport.logicalHandoffs == 1,
        "diagnostics focus sends one shared packet per queued route")
    batcher:Cancel()
    state:Destroy()
    for _, player in roster do command(player, "competitive-diagnostics-read") end
    command(roster[1], "competitive-diagnostics-errors")
    waitFor(function()
        local snapshot = session:GetDiagnostics()
        local entries = snapshot.reports.entries
        local reasons = {}
        for _, entry in entries do reasons[entry.reason] = true end
        return reasons.HandlerError == true and reasons.InvalidPayload == true
    end, "bounded diagnostics reports handler and invalid-payload refusals", 10)
    task.wait(0.15)
    waitFor(function()
        local observed = { [roster[1]] = 0, [roster[2]] = 0 }
        for _, entry in raw.Unreliable do
            if entry.endpoint == 2 then observed[roster[entry.client]] += 1 end
        end
        for _, player in roster do
            if #(calls.unreliableInput[player] or {}) < observed[player] then return false end
        end
        return true
    end, "observed unreliable native inputs finish their callback barrier", 3)

    local server = session:GetDiagnostics()
    local function route(snapshot, id, name, kind, channel)
        local endpoint = snapshot.traffic.endpoints[id]
        assert(endpoint ~= nil and endpoint.id == id and endpoint.name == name and endpoint.kind == kind,
            "ID-keyed diagnostic endpoint identity " .. tostring(id))
        local counters = endpoint.channels[channel]
        assert(counters ~= nil, "diagnostic endpoint channel")
        return counters
    end
    local function value(counters, name, expected, label)
        assert(counters[name] == expected, label .. " " .. name .. " expected " .. tostring(expected)
            .. ", got " .. tostring(counters[name]))
    end
    local function rawRpc(channel, client, rpcKind)
        for _, entry in raw[channel] do
            if entry.client == client and entry.methodId == 100 and entry.rpcKind == rpcKind then return entry end
        end
        return nil
    end
    local requestBytes, replyBytes = {}, {}
    for clientIndex = 1, #roster do
        local request = rawRpc("Reliable", clientIndex, 1)
        assert(request ~= nil and request.length >= 47 and request.referenceCount == 0,
            "native C2S RPC request packet with bounded reference arity")
        requestBytes[clientIndex] = request.length
        local client = command(roster[clientIndex], "competitive-diagnostics-read")
        local before, after = client.baselineRoutes, client.routes
        local response
        for _, frame in client.rpcFrames do
            if frame.methodId == 100 and frame.kind == 2 then response = frame break end
        end
        assert(response ~= nil and response.length >= 47 and response.referenceCount == 0,
            "native S2C RPC response packet")
        replyBytes[clientIndex] = response.length
        assert(#client.batch == 1 and client.batch[1] == 13 and #client.state == 1 and client.state[1] == 14,
            "actual reliable Batch and State callbacks")
        assert(#client.reliable == (if clientIndex == 1 then 2 else 1)
            and client.reliable[#client.reliable] == 11,
            "targeted and broadcast immediate callback counts")
        assert(#client.reliableFrames == 2,
            "actual Batch kind-1 and State kind-2 native frames")
        local kinds = {}
        for _, frame in client.reliableFrames do
            if frame.format == 2 or frame.format == 5 then
                assert(frame.count == 1 and frame.referenceCount == 0 and frame.length == 9
                    and frame.records[1].eventId == (if frame.kind == 1 then 6 else 7),
                    "actual queued diagnostic route and full native frame bytes")
                kinds[frame.kind] = (kinds[frame.kind] or 0) + 1
            end
        end
        assert(kinds[1] == 1 and kinds[2] == 1, "both native queued route kinds observed")
        local unreliableCount = 0
        for _, frame in client.unreliableFrames do
            if frame.endpoint == 5 then
                unreliableCount += 1
                assert(frame.value == 12, "observed unreliable output has its authored value")
            end
        end
        assert(unreliableCount <= 1 and #client.unreliable <= 1
            and ((unreliableCount == 0 and #client.unreliable == 0)
                or (unreliableCount == 1 and #client.unreliable == 1 and client.unreliable[1] == 12)),
            "unreliable output may be lost, but an observed handoff matches callback data")

        local input = after.inputReliable
        local clientInput = before.inputReliable
        value(input, "submittedRecords", 1, "client Input submission")
        value(input, "submittedBytes", 11, "client Input modeled bytes")
        value(input, "sentPackets", 1, "client Input native handoff")
        value(input, "sentBytes", 11, "client Input handoff units")
        value(clientInput, "submittedRecords", 0, "client diagnostics baseline")
        local batchInput = after.batchInput
        value(batchInput, "submittedRecords", 1, "client Batch submission")
        value(batchInput, "submittedBytes", 4, "client Batch endpoint body bytes")
        value(batchInput, "sentPackets", 1, "client Batch native handoff")
        value(batchInput, "sentBytes", 4, "client Batch endpoint handoff units")
        local clientOutput = after.outputReliable
        value(clientOutput, "receivedPackets", if clientIndex == 1 then 2 else 1, "client Output received calls")
        value(clientOutput, "receivedBytes", if clientIndex == 1 then 22 else 11, "client Output native tuple bytes")
        local clientBatchOutput = after.batchOutput
        value(clientBatchOutput, "receivedPackets", 1, "client BatchOutput received packet")
        value(clientBatchOutput, "receivedBytes", 4, "client BatchOutput endpoint content units")
        value(clientBatchOutput, "validatedRecords", 1, "client BatchOutput validated row")
        local clientStateOutput = after.stateOutput
        value(clientStateOutput, "receivedPackets", 1, "client StateOutput received packet")
        value(clientStateOutput, "receivedBytes", 4, "client StateOutput endpoint content units")
        value(clientStateOutput, "validatedRecords", 1, "client StateOutput validated row")
        local unreliableInput = after.unreliableInput
        value(unreliableInput, "submittedRecords", 1, "client unreliable submission")
        value(unreliableInput, "submittedBytes", 4, "client unreliable encoded buffer units")
        local clientRpc = after.inspectReliable
        value(clientRpc, "sentPackets", 1, "client RPC request handoff")
        value(clientRpc, "sentBytes", requestBytes[clientIndex] - 44, "client RPC method body units")
        value(clientRpc, "submittedRecords", 1, "client RPC request submission")
        value(clientRpc, "submittedBytes", requestBytes[clientIndex] - 44, "client RPC submitted method units")
        value(clientRpc, "receivedPackets", 1, "client RPC response receive")
        value(clientRpc, "receivedBytes", replyBytes[clientIndex] - 44, "client RPC response method units")
        local beforeReliable = before.channels.reliable
        local afterReliable = after.channels.reliable
        local outgoingExpected = 11 + 9 + requestBytes[clientIndex]
        value(afterReliable, "sentPackets", beforeReliable.sentPackets + 3, "client channel native outgoing calls")
        value(afterReliable, "sentBytes", beforeReliable.sentBytes + outgoingExpected,
            "client full native outgoing packet units")
        value(afterReliable, "sentRecords", beforeReliable.sentRecords + 3, "client channel logical outgoing records")
        local incomingCalls = (if clientIndex == 1 then 2 else 1) + 3
        local incomingBytes = 11 * (if clientIndex == 1 then 2 else 1) + 9 + 9 + replyBytes[clientIndex]
        value(afterReliable, "receivedPackets", beforeReliable.receivedPackets + incomingCalls,
            "client channel native receive calls")
        value(afterReliable, "receivedBytes", beforeReliable.receivedBytes + incomingBytes,
            "client full native receive packet units")
        local beforeUnreliable = before.channels.unreliable
        local afterUnreliable = after.channels.unreliable
        value(afterUnreliable, "sentPackets", beforeUnreliable.sentPackets + 1,
            "client unreliable channel handoff")
        value(afterUnreliable, "sentBytes", beforeUnreliable.sentBytes + 4,
            "client unreliable native codec buffer units")
        local clientUnreliableOutput = after.unreliableOutput
        value(clientUnreliableOutput, "receivedPackets", unreliableCount, "observed unreliable output packets")
        value(clientUnreliableOutput, "receivedBytes", unreliableCount * 4, "observed unreliable output codec units")
    end

    local inputRoute = route(server, 1, "Input", "Event", "Reliable")
    value(inputRoute, "receivedPackets", #roster + 2, "server Input native receives including two fault probes")
    value(inputRoute, "receivedBytes", (#roster + 2) * 11, "server Input native tuple observations")
    value(inputRoute, "validatedRecords", #roster + 1, "server Input validated records before handler error")
    value(inputRoute, "validatedBytes", (#roster + 1) * 11, "server Input validated modeled bytes")
    local batchRoute = route(server, 3, "BatchInput", "Event", "Reliable")
    value(batchRoute, "receivedPackets", #roster, "server BatchInput frame count")
    value(batchRoute, "receivedBytes", #roster * 4, "server BatchInput endpoint body units")
    value(batchRoute, "validatedRecords", #roster, "server BatchInput validated rows")
    value(batchRoute, "validatedBytes", #roster * 4, "server BatchInput row body units")
    local requestRoute = route(server, 100, "Inspect", "Request", "Reliable")
    value(requestRoute, "receivedPackets", #roster, "server RPC request packets")
    local expectedRequestBytes = 0
    local expectedRequestBodyBytes = 0
    for _, size in requestBytes do
        expectedRequestBytes += size
        expectedRequestBodyBytes += size - 44
    end
    value(requestRoute, "receivedBytes", expectedRequestBodyBytes, "server RPC method body units")
    value(requestRoute, "validatedRecords", #roster, "server RPC validated requests")

    local outputRoute = route(server, 4, "Output", "Event", "Reliable")
    value(outputRoute, "submittedRecords", 2, "targeted and broadcast submissions")
    value(outputRoute, "submittedBytes", 22, "immediate output tuple units")
    value(outputRoute, "sentPackets", 2, "targeted and one broadcast native call")
    value(outputRoute, "sentRecords", 2, "immediate output logical records")
    value(outputRoute, "sentBytes", 22, "immediate output native tuple units")
    value(outputRoute, "sentRecipientBytes", 11 * (#roster + 1), "immediate per-recipient modeled bytes")
    local unreliableOutput = route(server, 5, "UnreliableOutput", "Event", "Unreliable")
    value(unreliableOutput, "sentPackets", 1, "unreliable broadcast handoff")
    value(unreliableOutput, "sentBytes", 4, "unreliable native codec buffer units")
    value(unreliableOutput, "sentRecipientBytes", 4 * #roster, "unreliable modeled recipient units")
    for _, spec in { { 6, "BatchOutput", 1 }, { 7, "StateOutput", 2 } } do
        local counters = route(server, spec[1], spec[2], "Event", "Reliable")
        value(counters, "submittedRecords", 1, spec[2] .. " submission")
        value(counters, "submittedBytes", 4, spec[2] .. " endpoint content units")
        value(counters, "sentPackets", 1, spec[2] .. " shared native packet")
        value(counters, "sentRecords", 1, spec[2] .. " logical record")
        value(counters, "sentBytes", 4, spec[2] .. " endpoint content units")
        value(counters, "sentRecipientBytes", 4 * #roster, spec[2] .. " per-recipient endpoint units")
    end
    value(requestRoute, "sentPackets", #roster, "server RPC response handoffs")
    value(requestRoute, "sentRecords", #roster, "server RPC response records")
    local expectedReplyBytes = 0
    local expectedReplyBodyBytes = 0
    for _, size in replyBytes do
        expectedReplyBytes += size
        expectedReplyBodyBytes += size - 44
    end
    value(requestRoute, "sentBytes", expectedReplyBodyBytes, "server RPC method reply units")
    value(requestRoute, "sentRecipientBytes", expectedReplyBodyBytes, "server RPC method recipient units")
    local readyReliable = ready.traffic.channels.Reliable
    local beforeOutputReliable = beforeOutput.traffic.channels.Reliable
    value(beforeOutputReliable, "sentPackets", readyReliable.sentPackets + #roster,
        "server RPC reply channel handoffs")
    value(beforeOutputReliable, "sentBytes", readyReliable.sentBytes + expectedReplyBytes,
        "server RPC complete native reply packet units")
    value(beforeOutputReliable, "sentRecipientBytes", readyReliable.sentRecipientBytes + expectedReplyBytes,
        "server RPC full per-recipient channel units")

    local initialReliable = ready.traffic.channels.Reliable
    local receivedReliable = server.traffic.channels.Reliable
    value(receivedReliable, "receivedPackets",
        initialReliable.receivedPackets + (#roster + 2) + #roster + #roster,
        "channel observed immediate, Batch, RPC, and hostile native packets")
    value(receivedReliable, "receivedBytes",
        initialReliable.receivedBytes + (#roster + 2) * 11 + #roster * 9 + expectedRequestBytes,
        "channel complete C2S native packet units")
    value(receivedReliable, "validatedRecords", initialReliable.validatedRecords + (#roster + 1)
        + #roster + #roster, "channel validated rows exclude malformed input")
    value(receivedReliable, "validatedBytes", initialReliable.validatedBytes + (#roster + 1) * 11
        + #roster * 4 + expectedRequestBodyBytes, "channel validated logical content units")
    local beforeReliable = beforeOutput.traffic.channels.Reliable
    value(receivedReliable, "sentRecords", beforeReliable.sentRecords + 4, "server channel output logical rows")
    value(receivedReliable, "sentPackets", beforeReliable.sentPackets + 4, "server channel shared output native calls")
    value(receivedReliable, "sentBytes", beforeReliable.sentBytes + 22 + 9 + 9,
        "server channel full S2C native packet units")
    value(receivedReliable, "sentRecipientBytes", beforeReliable.sentRecipientBytes
        + 11 * (#roster + 1) + 9 * #roster + 9 * #roster,
        "server channel per-recipient S2C units")
    local receivedUnreliable = server.traffic.channels.Unreliable
    local unreliableRoute = route(server, 2, "UnreliableInput", "Event", "Unreliable")
    local rawUnreliableInputs = 0
    local rawUnreliableByClient = { 0, 0 }
    for _, entry in raw.Unreliable do
        if entry.endpoint == 2 then
            rawUnreliableInputs += 1
            rawUnreliableByClient[entry.client] += 1
            assert(entry.value == 2, "observed unreliable input native value")
        end
    end
    for clientIndex, player in roster do
        assert(#calls.unreliableInput[player] == rawUnreliableByClient[clientIndex],
            "observed unreliable input handoffs finish exactly one callback")
        for _, value in calls.unreliableInput[player] do
            assert(value == 2, "unreliable input callback matches its native value")
        end
    end
    value(unreliableRoute, "receivedPackets", rawUnreliableInputs, "server observed unreliable input calls")
    value(unreliableRoute, "receivedBytes", rawUnreliableInputs * 4, "server observed unreliable input codec units")
    value(unreliableRoute, "validatedRecords", rawUnreliableInputs, "server validated unreliable input records")
    value(receivedUnreliable, "receivedPackets", rawUnreliableInputs,
        "unreliable channel receive count matches actual native callbacks")
    value(receivedUnreliable, "sentPackets", beforeOutput.traffic.channels.Unreliable.sentPackets + 1,
        "server unreliable channel broadcast handoff")
    value(receivedUnreliable, "sentBytes", beforeOutput.traffic.channels.Unreliable.sentBytes + 4,
        "server unreliable full codec buffer units")
    value(receivedUnreliable, "sentRecipientBytes",
        beforeOutput.traffic.channels.Unreliable.sentRecipientBytes + 4 * #roster,
        "server unreliable per-recipient modeled units")

    local function verifyReports(reports, expectedReasons)
        assert(type(reports) == "table" and reports.capacity == 16 and type(reports.entries) == "table"
            and #reports.entries <= 16, "diagnostics fixed report capacity")
        local reasons = {}
        for _, entry in reports.entries do
            for key in entry do
                assert(key == "reason" or key == "endpointId" or key == "channel"
                    or key == "count" or key == "sequence", "report contains only bounded scalar fields")
            end
            assert(type(entry.reason) == "string" and type(entry.count) == "number"
                and type(entry.sequence) == "number", "report entry has no dynamic message or payload")
            reasons[entry.reason] = (reasons[entry.reason] or 0) + entry.count
        end
        for reason, minimum in expectedReasons do
            assert((reasons[reason] or 0) >= minimum, "diagnostic refusal report " .. reason)
        end
        return reasons
    end
    local serverReasons = verifyReports(server.reports, { HandlerError = 1, InvalidPayload = 1 })
    local clientBeforeMalformedOutput, clientLocalRefusalsUnreported = {}, {}
    for clientIndex, player in roster do
        local expectedOutputs = if clientIndex == 1 then 2 else 1
        local snapshot = command(player, "competitive-diagnostics-read", { expectedReliable = expectedOutputs })
        local reasons = verifyReports(snapshot.reports, {})
        clientLocalRefusalsUnreported[clientIndex] = (reasons.InvalidPayload or 0) == 0
        assert(clientLocalRefusalsUnreported[clientIndex] and #snapshot.reliable == expectedOutputs
            and snapshot.routes.outputReliable.receivedPackets
                - snapshot.baselineRoutes.outputReliable.receivedPackets == expectedOutputs
            and snapshot.routes.outputReliable.receivedBytes
                - snapshot.baselineRoutes.outputReliable.receivedBytes == expectedOutputs * 11,
            "local send refusals are not reports and valid Output callbacks are complete before probe")
        clientBeforeMalformedOutput[clientIndex] = snapshot.routes
    end
    local reliableRemote = ReplicatedStorage.RelayRemotes.Reliable
    for _, player in roster do reliableRemote:FireClient(player, 4, 256) end
    local clients = {}
    for clientIndex, player in roster do
        local expectedOutputs = if clientIndex == 1 then 2 else 1
        local snapshot = command(player, "competitive-diagnostics-read",
            { expectedReliable = expectedOutputs, requireInvalidOutput = true })
        local reasons = verifyReports(snapshot.reports, { InvalidPayload = 1 })
        assert(reasons.InvalidPayload == 1, "one malformed native Output produces one client refusal report")
        local malformedOutputReport
        local invalidReportCount = 0
        for _, entry in snapshot.reports.entries do
            if entry.reason == "InvalidPayload" then
                assert(entry.endpointId == 4 and entry.channel == "Reliable" and entry.count == 1,
                    "malformed Output report identifies the actual endpoint and channel")
                invalidReportCount += 1
                malformedOutputReport = { endpointId = entry.endpointId, channel = entry.channel, count = entry.count }
            end
        end
        assert(invalidReportCount == 1 and malformedOutputReport ~= nil,
            "malformed Output is the only reported client-side InvalidPayload")
        local beforeRoutes = clientBeforeMalformedOutput[clientIndex]
        local afterOutput = snapshot.routes.outputReliable
        value(afterOutput, "receivedPackets", beforeRoutes.outputReliable.receivedPackets + 1,
            "malformed native Output increments endpoint receive packets")
        value(afterOutput, "receivedBytes", beforeRoutes.outputReliable.receivedBytes + 11,
            "malformed native Output adds one modeled tuple")
        value(afterOutput, "validatedRecords", beforeRoutes.outputReliable.validatedRecords,
            "malformed native Output is not validated")
        value(afterOutput, "validatedBytes", beforeRoutes.outputReliable.validatedBytes,
            "malformed native Output adds no validated bytes")
        local beforeReliableChannel = beforeRoutes.channels.reliable
        local afterReliableChannel = snapshot.routes.channels.reliable
        value(afterReliableChannel, "receivedPackets", beforeReliableChannel.receivedPackets + 1,
            "malformed native Output increments client channel receives")
        value(afterReliableChannel, "receivedBytes", beforeReliableChannel.receivedBytes + 11,
            "malformed native Output adds one full channel tuple")
        value(afterReliableChannel, "validatedRecords", beforeReliableChannel.validatedRecords,
            "malformed native Output is excluded from channel validated records")
        value(afterReliableChannel, "validatedBytes", beforeReliableChannel.validatedBytes,
            "malformed native Output is excluded from channel validated bytes")
        assert(#snapshot.reliable == expectedOutputs,
            "malformed native Output does not reach client application callbacks")
        clients[clientIndex] = { client = clientIndex, reliable = #snapshot.reliable,
            batch = #snapshot.batch, state = #snapshot.state, reports = reasons,
            unreliable = snapshot.routes.unreliableInput, output = afterOutput,
            rpc = snapshot.routes.inspectReliable, invalidOutputReport = malformedOutputReport,
            reliableChannelPacketDelta = afterReliableChannel.receivedPackets - beforeReliableChannel.receivedPackets,
            reliableChannelByteDelta = afterReliableChannel.receivedBytes - beforeReliableChannel.receivedBytes,
            localRefusalsUnreported = clientLocalRefusalsUnreported[clientIndex] }
    end
    for clientIndex, player in roster do
        local receipt = command(player, "competitive-diagnostics-postmortem")
        assert(receipt.readable and receipt.stable and receipt.refused and receipt.started,
            "C06 client post-Destroy diagnostics proof")
        clients[clientIndex].postmortem = receipt
    end
    all("competitive-diagnostics-disabled")
    for _, player in roster do command(player, "competitive-diagnostics-stop") end
    local beforeDestroy = session:GetDiagnostics()
    session:Destroy()
    local afterDestroy = session:GetDiagnostics()
    local sent, failure = session.events.Output:Send(roster[1], 16)
    task.wait(0.15)
    local afterLateWork = session:GetDiagnostics()
    local serverPostmortem = {
        readable = afterDestroy.state == "Destroyed" and afterDestroy.traffic ~= nil
            and afterDestroy.reports ~= nil and afterDestroy.counters ~= nil,
        stable = Competitive.diagnosticsStable(afterDestroy, afterLateWork),
        refused = not sent and failure ~= nil and failure.code == "Destroyed",
        started = beforeDestroy.state == "Started",
    }
    assert(serverPostmortem.readable and serverPostmortem.stable and serverPostmortem.refused
        and serverPostmortem.started, "C06 server post-Destroy diagnostics proof")
    session = nil
    for _, item in competitiveRawConnections do item:Disconnect() end
    table.clear(competitiveRawConnections)
    all("absent")
    return { control = { channelReceives = controlReceives, noEndpointAttribution = true },
        server = { inputValidated = inputRoute.validatedRecords, batchPackets = batchRoute.receivedPackets,
            unreliableInputPackets = unreliableRoute.receivedPackets,
            unreliableInputValidated = unreliableRoute.validatedRecords,
            rpcRequests = requestRoute.receivedPackets, rpcReplies = requestRoute.sentPackets,
            outputHandoffs = outputRoute.sentPackets, outputRecipientBytes = outputRoute.sentRecipientBytes,
            batch = { packets = route(server, 6, "BatchOutput", "Event", "Reliable").sentPackets, kind = 1 },
            state = { packets = route(server, 7, "StateOutput", "Event", "Reliable").sentPackets, kind = 2 },
            reports = serverReasons, postmortem = serverPostmortem }, clients = clients,
        disabled = { trafficOmitted = true, reportsOmitted = true },
        native = { reliableC2sPackets = #raw.Reliable, unreliableC2sPackets = #raw.Unreliable,
            rpcRequestBytes = requestBytes, rpcReplyBytes = replyBytes } }
end

local function competitiveCorrectness()
    assert(#roster == 2, "competitive native proof requires two clients")
    local report = {}
    report.c03 = competitivePacedCorrectness()
    mark("competitive-c03-paced-batch")
    report.c04 = competitiveIndependentStateCorrectness()
    mark("competitive-c04-independent-state")
    report.c05 = competitiveTimestampsCorrectness()
    mark("competitive-c05-server-time")
    report.c06 = competitiveDiagnosticsCorrectness()
    mark("competitive-c06-traffic-diagnostics")
    competitiveDiagnostics = report
end

local function transportNamespacesCorrectness()
    assert(#roster == 2, "transport namespace proof requires two clients")
    if session then session:Destroy() session = nil end
    all("absent")

    local servers, inputs = {}, {}
    local function serverOptions(namespace, capacity)
        local options = { inboundRate = {
            perPlayer = { capacity = capacity, refillPerSecond = 0.000001 },
            aggregate = { capacity = 16, refillPerSecond = 0.000001 },
        } }
        if namespace then options.namespace = namespace end
        return options
    end
    local function startServer(label, namespace, capacity)
        local created, problem = Relay.createServer(TransportNamespaces.create(Relay), serverOptions(namespace, capacity))
        assert(created ~= nil, problem and problem.code or "namespace server creation")
        servers[label], inputs[label] = created, {}
        assert(created.events.Input:Connect(function(player, value)
            table.insert(inputs[label], { client = player.UserId, value = value })
        end))
        assert(created:Start())
    end
    local function inputValues(label)
        local result = {}
        for _, entry in inputs[label] do table.insert(result, entry.value) end
        return result
    end
    local function reads(player, labels)
        local result = {}
        for _, label in labels do result[label] = command(player, "namespace-read", label) end
        return result
    end

    startServer("default", nil, 5)
    startServer("game", "game", 4)
    startServer("package", "package", 5)
    for _, root in { "RelayRemotes", "RelayRemotes_game", "RelayRemotes_package" } do
        assert(ReplicatedStorage:FindFirstChild(root) ~= nil, "namespace root missing: " .. root)
    end

    local same = assert(Relay.createServer(TransportNamespaces.create(Relay), serverOptions("game", 1)))
    local sameStarted, sameFailure = same:Start()
    assert(not sameStarted and sameFailure.code == "AlreadyStarted", "same-copy server collision")
    same:Destroy()
    local moduleCopy = ReplicatedStorage.Relay:Clone()
    moduleCopy.Name = "RelayNamespaceServerProbe"
    moduleCopy.Parent = ReplicatedStorage
    local copiedRelay = require(moduleCopy)
    local copied = assert(copiedRelay.createServer(TransportNamespaces.create(copiedRelay), serverOptions("package", 1)))
    local copiedStarted, copiedFailure = copied:Start()
    assert(not copiedStarted and copiedFailure.code == "RemoteOwnershipConflict", "loaded-copy server collision")
    copied:Destroy()
    moduleCopy:Destroy()

    all("namespace-start", { label = "default", listen = true })
    all("namespace-start", { label = "game", namespace = "game", listen = true })
    all("namespace-start", { label = "package", namespace = "package", listen = false })
    for _, root in { "RelayRemotes", "RelayRemotes_game", "RelayRemotes_package" } do
        assert(ReplicatedStorage:FindFirstChild("RelayClientSession_" .. root) == nil,
            "client-local namespace marker replicated to server")
    end
    local clientCollision = command(roster[1], "namespace-collisions", "game")
    assert(clientCollision.sameCopy == "AlreadyStarted" and clientCollision.loadedCopy == "AlreadyStarted",
        "same-copy and loaded-copy client collision")

    local expectedReady = queuedPlayerIds(roster)
    local ready = {}
    waitFor(function()
        for _, label in { "default", "game", "package" } do
            local players, problem = servers[label].events.Output:GetReadyPlayers()
            assert(players ~= nil, problem and problem.code or "namespace readiness")
            ready[label] = queuedPlayerIds(players)
        end
        return sameNumbers(ready.default, expectedReady) and sameNumbers(ready.game, expectedReady)
            and #ready.package == 0
    end, "namespace readiness isolation", 10)

    for label, value in { default = 11, game = 21, package = 31 } do
        command(roster[1], "namespace-send", { label = label, value = value })
    end
    waitFor(function() return #inputs.default == 1 and #inputs.game == 1 and #inputs.package == 1 end,
        "independent namespace C2S delivery", 10)
    for label, value in { default = 11, game = 21, package = 31 } do
        assert(inputs[label][1].client == roster[1].UserId and inputs[label][1].value == value,
            "namespace C2S value isolation: " .. label)
    end
    local initialC2S = { default = inputValues("default"), game = inputValues("game"), package = inputValues("package") }

    for label, value in { default = 111, game = 121, package = 131 } do
        assert(servers[label].events.Output:Send(roster[1], value))
    end
    task.wait(0.3)
    local initialS2C = { target = reads(roster[1], { "default", "game", "package" }),
        peer = reads(roster[2], { "default", "game", "package" }) }
    assert(sameNumbers(initialS2C.target.default, { 111 }) and sameNumbers(initialS2C.target.game, { 121 })
        and #initialS2C.target.package == 0 and #initialS2C.peer.default == 0
        and #initialS2C.peer.game == 0 and #initialS2C.peer.package == 0, "namespace S2C isolation")

    local beforeMalformed = servers.game:GetDiagnostics()
    command(roster[1], "namespace-malformed", "game")
    waitFor(function()
        return servers.game:GetDiagnostics().events.Input.invalidPayload
            == beforeMalformed.events.Input.invalidPayload + 1
    end, "malformed namespace ingress rejection", 10)
    assert(#inputs.game == 1, "malformed namespace ingress reached handler")
    local afterMalformed = servers.game:GetDiagnostics()
    command(roster[1], "namespace-send", { label = "game", value = 22 })
    waitFor(function()
        return servers.game:GetDiagnostics().counters.perPlayerRate == afterMalformed.counters.perPlayerRate + 1
    end, "malformed namespace ingress charge", 10)
    command(roster[1], "namespace-send", { label = "default", value = 12 })
    command(roster[1], "namespace-send", { label = "package", value = 32 })
    waitFor(function() return #inputs.default == 2 and #inputs.package == 2 end,
        "other namespace budgets remain independent", 10)
    local defaultAdmission, gameAdmission, packageAdmission = servers.default:GetDiagnostics(),
        servers.game:GetDiagnostics(), servers.package:GetDiagnostics()
    assert(#inputs.game == 1 and gameAdmission.events.Input.invalidPayload == 1
        and gameAdmission.counters.perPlayerRate == 1 and defaultAdmission.counters.perPlayerRate == 0
        and packageAdmission.counters.perPlayerRate == 0, "malformed charge stays in its namespace")

    local ownedGameRoot = assert(ReplicatedStorage:FindFirstChild("RelayRemotes_game"),
        "live game namespace root missing before duplicate probe")
    local foreignGameRoot = Instance.new("Folder")
    foreignGameRoot.Name = "RelayRemotes_game"
    foreignGameRoot.Parent = ReplicatedStorage
    waitFor(function() return servers.game:GetDiagnostics().state == "Destroyed" end,
        "live duplicate namespace owner shutdown", 10)
    local liveDuplicateOwnerDestroyed = servers.game:GetDiagnostics().state == "Destroyed"
    assert(liveDuplicateOwnerDestroyed, "live duplicate namespace did not fail closed")

    local clientDisconnects = {}
    for index, player in roster do
        waitFor(function()
            local result = command(player, "namespace-status", "game")
            clientDisconnects[index] = result
            return result.state == "Disconnected" and not result.markerPresent
        end, "client live duplicate namespace disconnect", 10)
    end

    local removedMarkers = {}
    for _, player in roster do
        local result = command(player, "namespace-destroy", "game")
        assert(result.markerRemoved, "isolated client marker cleanup")
        table.insert(removedMarkers, result.markerRemoved)
    end
    local gameRootRemoved = ownedGameRoot.Parent == nil
    local foreignDuplicatePreserved = foreignGameRoot.Parent == ReplicatedStorage
        and foreignGameRoot.Name == "RelayRemotes_game"
    local defaultRetained = ReplicatedStorage:FindFirstChild("RelayRemotes") ~= nil
    local packageRetained = ReplicatedStorage:FindFirstChild("RelayRemotes_package") ~= nil
    assert(gameRootRemoved and foreignDuplicatePreserved and defaultRetained and packageRetained,
        "duplicate cleanup changed foreign or independent namespace roots")
    foreignGameRoot:Destroy()
    waitFor(function()
        return foreignGameRoot.Parent == nil and ReplicatedStorage:FindFirstChild("RelayRemotes_game") == nil
    end, "fixture duplicate namespace cleanup", 10)
    local foreignDuplicateRemoved = foreignGameRoot.Parent == nil
    assert(foreignDuplicateRemoved, "fixture duplicate namespace root leaked")
    servers.game = nil

    assert(servers.default.events.Output:Send(roster[1], 112))
    assert(servers.package.events.Output:Send(roster[1], 132))
    task.wait(0.3)
    local survivedS2C = { target = reads(roster[1], { "default", "package" }),
        peer = reads(roster[2], { "default", "package" }) }
    assert(sameNumbers(survivedS2C.target.default, { 111, 112 })
        and #survivedS2C.target.package == 0 and #survivedS2C.peer.default == 0,
        "default and other named namespace survive isolated destroy")

    startServer("game", "game", 4)
    all("namespace-start", { label = "game", namespace = "game", listen = true })
    local restartedReady
    waitFor(function()
        local players, problem = servers.game.events.Output:GetReadyPlayers()
        assert(players ~= nil, problem and problem.code or "restarted namespace readiness")
        restartedReady = queuedPlayerIds(players)
        return sameNumbers(restartedReady, expectedReady)
    end, "restarted namespace readiness", 10)
    command(roster[2], "namespace-send", { label = "game", value = 23 })
    waitFor(function() return #inputs.game == 1 end, "restarted namespace C2S", 10)
    assert(inputs.game[1].client == roster[2].UserId and inputs.game[1].value == 23)
    assert(servers.game.events.Output:Send(roster[2], 123))
    task.wait(0.3)
    local restartedS2C = { target = command(roster[2], "namespace-read", "game"),
        peer = command(roster[1], "namespace-read", "game") }
    assert(sameNumbers(restartedS2C.target, { 123 }) and #restartedS2C.peer == 0,
        "restarted namespace routes independently")

    for _, label in { "game", "package", "default" } do
        for _, player in roster do
            assert(command(player, "namespace-destroy", label).markerRemoved, "full client marker cleanup")
        end
    end
    for _, server in servers do server:Destroy() end
    waitFor(function()
        return ReplicatedStorage:FindFirstChild("RelayRemotes") == nil
            and ReplicatedStorage:FindFirstChild("RelayRemotes_game") == nil
            and ReplicatedStorage:FindFirstChild("RelayRemotes_package") == nil
    end, "full namespace remote cleanup", 10)
    local clientMarkers = { command(roster[1], "namespace-markers-absent"),
        command(roster[2], "namespace-markers-absent") }
    for _, markers in clientMarkers do
        assert(markers.default and markers.game and markers.package, "full client marker teardown")
    end
    transportNamespaceDiagnostics = {
        c2s = { initial = initialC2S, restartedGame = inputValues("game") },
        s2c = { initial = initialS2C, survived = survivedS2C, restartedGame = restartedS2C },
        readiness = { default = #ready.default, game = #ready.game, package = #ready.package,
            restartedGame = #restartedReady },
        collisions = { serverSameCopy = sameFailure.code, serverLoadedCopy = copiedFailure.code,
            clientSameCopy = clientCollision.sameCopy, clientLoadedCopy = clientCollision.loadedCopy },
        admission = { gameInvalidPayload = gameAdmission.events.Input.invalidPayload,
            gamePerPlayerRate = gameAdmission.counters.perPlayerRate,
            defaultPerPlayerRate = defaultAdmission.counters.perPlayerRate,
            packagePerPlayerRate = packageAdmission.counters.perPlayerRate,
            gameDispatched = gameAdmission.events.Input.dispatched,
            defaultDispatched = defaultAdmission.events.Input.dispatched,
            packageDispatched = packageAdmission.events.Input.dispatched },
        destroy = { gameRootRemoved = gameRootRemoved, defaultRetained = defaultRetained,
            packageRetained = packageRetained, clientMarkers = removedMarkers,
            liveDuplicateOwnerDestroyed = liveDuplicateOwnerDestroyed,
            foreignDuplicatePreserved = foreignDuplicatePreserved,
            foreignDuplicateRemoved = foreignDuplicateRemoved, clientDisconnects = clientDisconnects },
        teardown = { rootsRemoved = true, clientMarkers = clientMarkers, clientMarkersPrivate = true },
    }
    mark("transport-namespaces")
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
    local firstInputs = {}
    for _, player in roster do
        table.insert(firstInputs, { client = player.UserId, values = table.clone(deliveries[player]) })
    end
    installationDiagnostics = { version = Relay.VERSION, firstInputs = firstInputs }
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
    rgb8Color3Correctness()
    taggedUnionCorrectness()
    readiness64Correctness()
    contentByteCorrectness()
    handlerCancellationCorrectness()
    orderedUnreliableCorrectness()
    nativeValuesCorrectness()
    instanceReferencesCorrectness()
    quantizedCorrectness()
    compactTransportCorrectness()
    bufferDeferralCorrectness()
    stateDeferralCorrectness()
    rpcBoundedRoutesCorrectness()
    broadcastBatchingCorrectness()
    if #roster > 1 then transportNamespacesCorrectness() end
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

local function fairAdmission()
    assert(#roster == 2, "fair admission proof requires exactly two actual Players")
    local hostile, honest = roster[1], roster[2]
    local function delivered(player)
        return table.clone(deliveries[player] or {})
    end
    local function send(player, first, count)
        return command(player, "fairness-send", { first = first, count = count })
    end
    local function waitForDelivery(player, expectedCount, label)
        waitFor(function() return count(player) >= expectedCount end, label)
        assert(count(player) == expectedCount, label .. " had an extra callback")
    end

    create(4, 4, 0.4)
    all("start")
    task.wait(10.1)
    local defaultRefusals = session:GetDiagnostics().counters.aggregateRate
    local defaultHostileAttempts, defaultHonestAttempts = {}, {}
    for round = 1, 2 do
        local hostileBefore = count(hostile)
        defaultHostileAttempts[round] = send(hostile, (round - 1) * 4 + 1, 4)
        assert(defaultHostileAttempts[round] == 4, "default hostile sent four calls")
        waitForDelivery(hostile, hostileBefore + 4, "default hostile burst")
        local hostileArrivalAt = os.clock()
        local honestBefore = count(honest)
        local refusalsBefore = session:GetDiagnostics().counters.aggregateRate
        defaultHonestAttempts[round] = send(honest, 100 + round, 1)
        waitFor(function()
            return count(honest) > honestBefore
                or session:GetDiagnostics().counters.aggregateRate > refusalsBefore
        end, "default honest command admission result")
        assert(count(honest) == honestBefore
            and session:GetDiagnostics().counters.aggregateRate == refusalsBefore + 1,
            string.format("default aggregate burst starves the honest command (4 calls at 0.4/s; %.3fs barrier)",
                os.clock() - hostileArrivalAt))
        if round == 1 then task.wait(10.1) end
    end
    local default = {
        hostile = delivered(hostile),
        honest = delivered(honest),
        refusals = session:GetDiagnostics().counters.aggregateRate - defaultRefusals,
        hostileAttempts = defaultHostileAttempts,
        honestAttempts = defaultHonestAttempts,
        aggregateCapacity = 4,
        aggregateRefillPerSecond = 0.4,
        refillWaitSeconds = 10.1,
    }
    all("destroy")
    session:Destroy()

    create(4, 4, 0.4, nil, { maxPeers = 2, reserve = { capacity = 1, refillPerSecond = 0.1 } })
    all("start")
    task.wait(10.1)
    local optedInRefusals = session:GetDiagnostics().counters.aggregateRate
    local optedInHostileAttempts, optedInHonestAttempts = {}, {}
    for round = 1, 2 do
        local hostileBefore, honestBefore = count(hostile), count(honest)
        local refusalsBefore = session:GetDiagnostics().counters.aggregateRate
        local hostileWindowStarted = os.clock()
        optedInHostileAttempts[round] = send(hostile, 201 + (round - 1) * 4, 4)
        assert(optedInHostileAttempts[round] == 4, "opt-in hostile offered four calls")
        waitFor(function()
            return count(hostile) >= hostileBefore + 3
                and session:GetDiagnostics().counters.aggregateRate == refusalsBefore + 1
        end, "fourth hostile call is refused after reserve and shared tokens")
        assert(count(hostile) == hostileBefore + 3,
            string.format("hostile uses reserve plus shared pool (four attempts; %.3fs barrier)",
                os.clock() - hostileWindowStarted))
        optedInHonestAttempts[round] = send(honest, 300 + round, 1)
        assert(optedInHonestAttempts[round] == 1, "opt-in honest sent one call")
        waitForDelivery(honest, honestBefore + 1, "reserved honest command")
        if round == 1 then task.wait(10.1) end
    end

    task.wait(10.1)
    local beforeMalformed = session:GetDiagnostics().counters
    local hostileBefore, honestBefore = count(hostile), count(honest)
    local malformedAttempts = command(hostile, "fairness-malformed-burst", { first = 401, count = 3 })
    assert(type(malformedAttempts) == "table" and malformedAttempts.malformed == 1
        and malformedAttempts.valid == 3, "one malformed then three valid hostile attempts")
    waitFor(function()
        local counters = session:GetDiagnostics().counters
        return count(hostile) == hostileBefore + 2
            and counters.invalidPayload == beforeMalformed.invalidPayload + 1
            and counters.aggregateRate == beforeMalformed.aggregateRate + 1
    end, "malformed payload consumes the hostile call reservation")
    assert(count(hostile) == hostileBefore + 2, "malformed burst dispatches no extra hostile callbacks")
    local malformedWindowHonestAttempts = send(honest, 303, 1)
    assert(malformedWindowHonestAttempts == 1, "honest sent one command after malformed traffic")
    waitForDelivery(honest, honestBefore + 1, "honest reserve survives malformed hostile traffic")

    local afterMalformedRefusals = session:GetDiagnostics().counters.aggregateRate
    assert(afterMalformedRefusals == beforeMalformed.aggregateRate + 1,
        "malformed call and hostile shared exhaustion produce one aggregate refusal")
    task.wait(10.1)
    hostileBefore, honestBefore = count(hostile), count(honest)
    local recoveryRefusals = session:GetDiagnostics().counters.aggregateRate
    local recoveryHostileAttempts = send(hostile, 404, 4)
    assert(recoveryHostileAttempts == 4, "recovery hostile offered four calls")
    local recoveryArrivalAt = os.clock()
    waitFor(function()
        return count(hostile) >= hostileBefore + 3
            and session:GetDiagnostics().counters.aggregateRate == recoveryRefusals + 1
    end, "hostile admission and shared refusal recover after refill")
    assert(count(hostile) == hostileBefore + 3,
        string.format("recovered hostile burst remains capped at three calls (%.3fs barrier)", os.clock() - recoveryArrivalAt))
    local recoveryHonestAttempts = send(honest, 304, 1)
    assert(recoveryHonestAttempts == 1, "honest sent one command after refill")
    waitForDelivery(honest, honestBefore + 1, "honest admission repeats after refill")
    local afterMalformed = session:GetDiagnostics().counters
    assert(afterMalformed.invalidPayload == beforeMalformed.invalidPayload + 1
        and afterMalformed.aggregateRate == recoveryRefusals + 1,
        "malformed and exhausted shared demand retain bounded admission accounting")
    fairnessDiagnostics = {
        hostile = hostile.UserId,
        honest = honest.UserId,
        defaults = default,
        optedIn = {
            hostile = delivered(hostile),
            honest = delivered(honest),
            hostileAttempts = optedInHostileAttempts,
            honestAttempts = optedInHonestAttempts,
            malformedAttempts = malformedAttempts,
            malformedWindowHonestAttempts = malformedWindowHonestAttempts,
            recoveryHostileAttempts = recoveryHostileAttempts,
            recoveryHonestAttempts = recoveryHonestAttempts,
            malformed = afterMalformed.invalidPayload - beforeMalformed.invalidPayload,
            malformedAggregateRefusals = afterMalformedRefusals - beforeMalformed.aggregateRate,
            aggregateRefusals = afterMalformed.aggregateRate - optedInRefusals,
            perPlayerCapacity = 4,
            aggregateCapacity = 4,
            reserveCapacity = 1,
            perPlayerRefillPerSecond = 0.4,
            aggregateRefillPerSecond = 0.4,
            reserveRefillPerSecond = 0.1,
            refillWaitSeconds = 10.1,
        },
    }
    all("destroy")
    session:Destroy()
    mark("bounded-peer-admission-fairness")
end

task.spawn(function()
    local args = StudioTestService:GetTestArgs()
    local ok, failure = pcall(function()
        assert(type(args) == "table" and (args.clients == 1 or args.clients == 2 or args.clients == 4 or args.clients == 8))
        if args.mode == "fairness" then assert(args.clients == 2, "fair admission needs two Players") end
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
        elseif args.mode == "competitive" then competitiveCorrectness()
        elseif args.mode == "admission" then admission()
        elseif args.mode == "fairness" then fairAdmission()
        else error("unknown proof mode") end
    end)
    if session then session:Destroy() end
    if taggedRawConnection then taggedRawConnection:Disconnect() end
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
        rgb8Color3 = rgb8Color3Diagnostics,
        taggedUnion = taggedUnionDiagnostics,
        installation = installationDiagnostics,
        readiness64 = readiness64Diagnostics,
        contentBytes = contentByteDiagnostics,
        handlerCancellation = handlerCancellationDiagnostics,
        orderedUnreliable = orderedUnreliableDiagnostics,
        nativeValues = nativeValueDiagnostics,
        instanceReferences = instanceReferenceDiagnostics,
        quantized = quantizedDiagnostics,
        compactTransport = compactTransportDiagnostics,
        bufferDeferral = bufferDeferralDiagnostics,
        stateDeferral = stateDeferralDiagnostics,
        rpcBoundedRoutes = rpcBoundedRouteDiagnostics,
        broadcastBatching = broadcastBatchingDiagnostics,
        competitive = competitiveDiagnostics,
        fairness = fairnessDiagnostics,
        handlerCancellationObservations = handlerCancellationObservations,
        transportNamespaces = transportNamespaceDiagnostics,
    })
end)
