local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Relay = require(ReplicatedStorage.Relay)
local Fixture = require(ReplicatedStorage.RelayProofDefinition)
local control = ReplicatedStorage.RelayProofControl
local readyPlayers = {}
local readyConnection = ReplicatedStorage.RelayProofReady.OnServerEvent:Connect(function(player)
    readyPlayers[player] = true
end)
local session
local inputConnection
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
    if string.sub(name, 1, 4) == "rpc-" then print("Relay proof command begin", name, player.Name) end
    task.spawn(function()
        result = table.pack(pcall(control.InvokeClient, control, player, name, argument))
        done = true
    end)
    waitFor(function() return done end, "client command " .. name .. " for " .. player.Name)
    assert(result[1], result[2])
    if string.sub(name, 1, 4) == "rpc-" then print("Relay proof command end", name, player.Name) end
    return table.unpack(result, 2, result.n)
end

local function all(name, argument)
    for _, player in roster do assert(command(player, name, argument)) end
end

local function create(capacity, aggregate, refill)
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
    local created, failure = Relay.createServer(Fixture.create(), {
        inboundRate = {
            perPlayer = { capacity = capacity or 128, refillPerSecond = refill or 128 },
            aggregate = { capacity = aggregate or 1024, refillPerSecond = refill or 1024 },
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
        return { sequence = sequence, owner = player.Name }
    end))
    assert(session.requests.Optional:Connect(function(_player, present)
        if present then return false end
        return nil
    end))
    assert(session.requests.Delay:Connect(function(_player, seconds)
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
        local checkedId, value, enabled = Fixture.checkUnreliable(tuple.sampleId, tuple.value, tuple.enabled)
        if checkedId >= firstSample and checkedId <= lastSample then
            table.insert(samples, { sampleId = checkedId, value = value, enabled = enabled })
        end
    end
    table.sort(samples, function(left, right) return left.sampleId < right.sampleId end)
    return samples
end

local function unreliableCorrectness()
    local count = Fixture.unreliableSampleCount
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

local function createQueued(perPlayerCapacity, aggregateCapacity, refill)
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
    all("queued-prepare")

    local created, problem = Relay.createServer(Fixture.createQueued(), {
        inboundRate = {
            perPlayer = { capacity = perPlayerCapacity or 128, refillPerSecond = refill or 128 },
            aggregate = { capacity = aggregateCapacity or 1024, refillPerSecond = refill or 1024 },
        },
    })
    assert(created ~= nil, problem and problem.message)
    session = created
    assert(session.events.QueueInput:Connect(function(player, value)
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
    table.sort(otherIds)

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
    })
end)
