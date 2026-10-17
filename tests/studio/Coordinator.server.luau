local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StudioTestService = game:GetService("StudioTestService")
local Relay = require(ReplicatedStorage.Relay)
local Fixture = require(ReplicatedStorage.RelayProofDefinition)
local InstanceValues = require(ReplicatedStorage.RelayProofInstanceValues)
local NativeValues = require(ReplicatedStorage.RelayProofNativeValues)
local QuantizedValues = require(ReplicatedStorage.RelayProofQuantizedValues)
local CompactTransport = require(ReplicatedStorage.RelayProofCompactTransport)
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
    local generations = {}
    for _, player in roster do
        values[player], rawCounts[player] = {}, 0
        generations[player] = command(player, "ordered-start")
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
        restart = { client = target.UserId, before = generations[target], after = newGeneration } }
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
    taggedUnionCorrectness()
    readiness64Correctness()
    contentByteCorrectness()
    handlerCancellationCorrectness()
    orderedUnreliableCorrectness()
    nativeValuesCorrectness()
    instanceReferencesCorrectness()
    quantizedCorrectness()
    compactTransportCorrectness()
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
        handlerCancellationObservations = handlerCancellationObservations,
    })
end)
