local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Fixture = require(ReplicatedStorage:WaitForChild("RelayProofDefinition"))
local TransportNamespaces = require(ReplicatedStorage:WaitForChild("RelayProofTransportNamespaces"))
local InstanceValues = require(ReplicatedStorage:WaitForChild("RelayProofInstanceValues"))
local RpcBoundedRoutes = require(ReplicatedStorage:WaitForChild("RelayProofRpcBoundedRoutes"))
local NativeValues = require(ReplicatedStorage:WaitForChild("RelayProofNativeValues"))
local QuantizedValues = require(ReplicatedStorage:WaitForChild("RelayProofQuantizedValues"))
local CompactTransport = require(ReplicatedStorage:WaitForChild("RelayProofCompactTransport"))
local BufferDeferral = require(ReplicatedStorage:WaitForChild("RelayProofBufferDeferral"))
local BroadcastBatching = require(ReplicatedStorage:WaitForChild("RelayProofBroadcastBatching"))
local Competitive = require(ReplicatedStorage:WaitForChild("RelayProofCompetitive"))
local ReadinessFrame = require(ReplicatedStorage.Relay.internal.ReadinessFrame)
local control = ReplicatedStorage:WaitForChild("RelayProofControl")
local ready = ReplicatedStorage:WaitForChild("RelayProofReady")
local session
local namespaceSessions = {}
local namespaceReceived = {}
local namespaceMarkers = {}
local connection
local received = {}
local schemaReceived = {}
local compositeReceived = {}
local unreliableReceived = {}
local unreliableCompositeReceived = {}
local unreliableFailure
local compositeFailure
local poseResult = Fixture.poseRecord()
local poseObserver
local handlerMode = "normal"
local release = false
local entered = 0
local pendingRpc
local color3Received
local color3Failure
local rgb8Color3Received = {}
local rgb8Color3Sources = {}
local rgb8Color3Failure
local rgb8Color3RawConnection
local rgb8Color3RawFrames = {}
local taggedUnionReceived
local taggedUnionFailure
local queuedReceived = { reliable = {}, unreliable = {}, once = {}, reusable = {} }
local queuedPushConnection
local BatchFrame = require(ReplicatedStorage.Relay.internal.BatchFrame)
local readiness64Connections = {}
local readiness64Deliveries = {}
local readiness64Failure
local readiness64Prepared
local cancellationThread
local cancellationEntered = 0
local cancellationContinued = 0
local cancellationReplacementCalls = 0
local orderedGeneration
local orderedValues = {}
local orderedInitObserver
local orderedRawObserver
local orderedRawCount = 0
local orderedMaximumBytes = 0
local orderedStreamValues = { shared = {}, targeted = {} }
local orderedStreamRawSamples = {}
local orderedStreamRawCounts = { shared = 0, targeted = 0 }
local orderedStreamLastSequences = { shared = 0, targeted = 0 }
local nativeValueGroup
local nativeValueReceived = {}
local nativeValueReceivedCounts = {}
local nativeValueFailure
local instancePeerPlayer
local instanceReceived = {}
local instanceFailure
local instanceMissingOutputCalls = 0
local instanceScopeCalls = 0
local instanceScopeReceipt
local instanceStreamCalls = 0
local instanceLocalOnly
local instanceRawConnection
local instanceRawFrames = {}
local quantizedReceived = { grid = {}, wide = {} }
local quantizedFailure
local quantizedRawConnection
local quantizedRawFrames = {}
local quantizedQueueValue
local compactReceived = { vector3 = {}, vector2 = {}, frames = {} }
local compactFailure
local compactRawConnection
local compactRawFrames = {}
local budgetFailure
local budgetPulseValues = {}
local budgetQueueValues = {}
local budgetStateValues = {}
local budgetRawConnection
local budgetRawFrames = {}
local budgetRpcFrames = {}
local budgetOtherFrames = {}
local packedReceived = { tuple = {}, arrays = {}, records = {} }
local packedFailure
local packedRawConnection
local packedRawFrames = {}
local bufferOutputValues = {}
local bufferQueueValues = {}
local bufferFailure
local bufferRawConnection
local bufferRawFrames = {}
local bufferQueueRawFrames = {}
local broadcastBatchingSession
local broadcastBatchingConnections = {}
local broadcastBatchingRawConnections = {}
local broadcastBatchingReliableValues = {}
local broadcastBatchingUnreliableValues = {}
local broadcastBatchingRawFrames = { Reliable = {}, Unreliable = {} }
local broadcastStateReliableValues = {}
local broadcastStateUnreliableValues = {}
local broadcastStateRawFrames = { Reliable = {}, Unreliable = {} }
local broadcastBatchingHostileRawFrames = { Reliable = {} }
local broadcastBatchingHostileCapture = false
local broadcastBatchingFailure
local statePulseValues = {}
local stateOutputValues = {}
local stateFailure
local stateRawConnection
local statePulseRawFrames = {}
local stateOutputRawFrames = {}
local rpcBoundedRouteReceipts = {}
local rpcBoundedRawFrames = { Reliable = {}, Unreliable = {} }
local rpcBoundedRawConnections = {}
local rpcBoundedConnections = {}
local rpcBoundedClientCallResults = {}
local rpcBoundedClientCallActive = 0
local rpcBoundedClientCallMax = 0
local rpcBoundedClientCallRelease = false
local rpcBoundedFailure
local rpcBoundedPending
local rpcBoundedScalars = {}
local competitivePacer
local competitiveStateConnections = {}
local competitiveStateRows = { reliable = {}, unreliable = {}, reliableRaw = {}, unreliableRaw = {}, drain = 0 }
local competitiveTimestampGeneration
local competitiveTimestampInitConnection
local competitiveDiagnosticsValues = { reliable = {}, unreliable = {}, batch = {}, state = {} }
local competitiveDiagnosticsRaw = { Reliable = {}, Unreliable = {} }
local competitiveDiagnosticsConnections = {}
local competitiveDiagnosticsBaseline

local function diagnosticsRoute(snapshot, id, name, kind, channel)
    local endpoint = snapshot.traffic.endpoints[id]
    assert(endpoint ~= nil and endpoint.id == id and endpoint.name == name and endpoint.kind == kind,
        "ID-keyed diagnostic endpoint identity " .. tostring(id))
    local counters = endpoint.channels[channel]
    assert(counters ~= nil, "diagnostic endpoint channel")
    return table.clone(counters)
end

local function competitiveDiagnosticsRoutes(snapshot)
    return {
        inputReliable = diagnosticsRoute(snapshot, 1, "Input", "Event", "Reliable"),
        unreliableInput = diagnosticsRoute(snapshot, 2, "UnreliableInput", "Event", "Unreliable"),
        batchInput = diagnosticsRoute(snapshot, 3, "BatchInput", "Event", "Reliable"),
        outputReliable = diagnosticsRoute(snapshot, 4, "Output", "Event", "Reliable"),
        unreliableOutput = diagnosticsRoute(snapshot, 5, "UnreliableOutput", "Event", "Unreliable"),
        batchOutput = diagnosticsRoute(snapshot, 6, "BatchOutput", "Event", "Reliable"),
        stateOutput = diagnosticsRoute(snapshot, 7, "StateOutput", "Event", "Reliable"),
        inspectReliable = diagnosticsRoute(snapshot, 100, "Inspect", "Request", "Reliable"),
        channels = {
            reliable = table.clone(snapshot.traffic.channels.Reliable),
            unreliable = table.clone(snapshot.traffic.channels.Unreliable),
        },
    }
end

local function competitiveTimestampRoutes(snapshot)
    return {
        reliableInput = diagnosticsRoute(snapshot, 1, "ReliableInput", "Event", "Reliable"),
        unreliableInput = diagnosticsRoute(snapshot, 2, "UnreliableInput", "Event", "Unreliable"),
        orderedInput = diagnosticsRoute(snapshot, 3, "OrderedInput", "Event", "Unreliable"),
        batchInput = diagnosticsRoute(snapshot, 4, "BatchInput", "Event", "Reliable"),
        stateInput = diagnosticsRoute(snapshot, 5, "StateInput", "Event", "Reliable"),
    }
end

local function orderedPacket(eventId, generation, sequence, text, malformed)
    local packet = buffer.create(13 + #text + (if malformed then 1 else 0))
    buffer.writeu8(packet, 0, 3)
    buffer.writeu16(packet, 1, eventId)
    buffer.writeu32(packet, 3, generation)
    buffer.writeu32(packet, 7, sequence)
    buffer.writeu16(packet, 11, #text)
    buffer.writestring(packet, 13, text)
    return packet
end

local function recordReadiness64(eventId, value)
    local ok, failure = pcall(function()
        assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 255,
            "64-endpoint native value")
        table.insert(readiness64Deliveries, { id = eventId, value = value })
    end)
    if not ok then readiness64Failure = tostring(failure) end
end

local function connectReadiness64(eventId, name)
    local connected, failure = session.events[name]:Connect(function(value)
        recordReadiness64(eventId, value)
    end)
    assert(connected, failure and failure.code or "64-endpoint listener connection failed")
    return connected
end

local function recordComposed(destination, ...)
    local ok, sequence, ticket = pcall(Fixture.checkComposed, ...)
    if not ok then compositeFailure = tostring(sequence) return end
    table.insert(destination, { sequence = sequence, ticket = ticket })
end

local function assertSend(ok, failure, label)
    if ok then return end
    local detail = if type(failure) == "table"
        then tostring(failure.code) .. ": " .. tostring(failure.message) else tostring(failure)
    error(label .. ": " .. detail, 2)
end

local function recordRpcBoundedReferences(name, ...)
    local values = table.pack(...)
    if values.n ~= 3 then
        rpcBoundedFailure = "unexpected Instance route tuple arity: " .. name
        return
    end
    local ok, receipt = pcall(RpcBoundedRoutes.checkReferences,
        values[1], values[2], values[3], Players.LocalPlayer)
    if not ok then rpcBoundedFailure = tostring(receipt) return end
    local list = rpcBoundedRouteReceipts[name]
    if list == nil then list = {} rpcBoundedRouteReceipts[name] = list end
    table.insert(list, receipt)
end

local function recordRpcBoundedRaw(channel, endpoint, packet, ...)
    local row
    if channel == "Unreliable" and typeof(packet) == "buffer" and buffer.len(packet) >= 1
        and buffer.readu8(packet, 0) == 6 then
        row = RpcBoundedRoutes.rawOrderedReceipt(endpoint, packet, ...)
    else
        row = RpcBoundedRoutes.instanceReceipt(endpoint, packet, ...)
    end
    table.insert(rpcBoundedRawFrames[channel], row)
end

local function recordBroadcastBatchingRaw(channel, endpoint, packet, ...)
    if broadcastBatchingHostileCapture and channel == "Reliable" then
        local arguments = table.pack(...)
        local ok, row = pcall(function()
            local sidecars = { n = arguments.n }
            for index = 1, arguments.n do sidecars[index] = arguments[index] end
            assert(endpoint == 0 and typeof(packet) == "buffer", "shared malformed broadcast receipt shape")
            local header = BatchFrame.header(packet, 8_192, sidecars)
            assert(header ~= nil, "shared malformed broadcast header and sidecars")
            local references = table.create(arguments.n)
            for index = 1, arguments.n do
                local value = arguments[index]
                assert(typeof(value) == "Instance", "shared malformed broadcast sidecar identity")
                references[index] = { className = value.ClassName, name = value.Name, path = value:GetFullName() }
            end
            local bytes = table.create(buffer.len(packet))
            for index = 0, buffer.len(packet) - 1 do
                bytes[index + 1] = buffer.readu8(packet, index)
            end
            return {
                endpoint = endpoint,
                format = header.format,
                kind = header.kind,
                count = header.count,
                referenceCount = header.referenceCount,
                length = buffer.len(packet),
                bytes = bytes,
                references = references,
            }
        end)
        if not ok then broadcastBatchingFailure = tostring(row) return end
        table.insert(broadcastBatchingHostileRawFrames.Reliable, row)
        return
    end
    local ok, row = pcall(BroadcastBatching.rawReceipt, channel, endpoint, packet, ...)
    if not ok then broadcastBatchingFailure = tostring(row) return end
    if row ~= nil then
        table.insert(if row.kind == 2 then broadcastStateRawFrames[channel] else broadcastBatchingRawFrames[channel], row)
    end
end

local function broadcastBatchingSnapshot()
    return {
        client = Players.LocalPlayer.UserId,
        reliable = table.clone(broadcastBatchingReliableValues),
        unreliable = table.clone(broadcastBatchingUnreliableValues),
        raw = { Reliable = table.clone(broadcastBatchingRawFrames.Reliable),
            Unreliable = table.clone(broadcastBatchingRawFrames.Unreliable) },
        failure = broadcastBatchingFailure,
    }
end

local function broadcastStateSnapshot()
    return {
        client = Players.LocalPlayer.UserId,
        reliable = table.clone(broadcastStateReliableValues),
        unreliable = table.clone(broadcastStateUnreliableValues),
        raw = { Reliable = table.clone(broadcastStateRawFrames.Reliable),
            Unreliable = table.clone(broadcastStateRawFrames.Unreliable) },
        failure = broadcastBatchingFailure,
    }
end

local function listen(once, cancellationProbe)
    local method = if once then session.events.State.Once else session.events.State.Connect
    connection = assert(method(session.events.State, function(...)
        if cancellationProbe then
            cancellationEntered += 1
            cancellationThread = coroutine.running()
            task.wait(60)
            cancellationContinued += 1
            return
        end
        local sequence = Fixture.check(...)
        entered += 1
        if handlerMode == "error" then error("deliberate trusted test handler failure") end
        if handlerMode == "yield" then
            while not release do task.wait() end
        end
        table.insert(received, sequence)
    end))
end

local function connectQueuedListeners(cancellationProbe)
    queuedPushConnection = assert(session.events.QueuePush:Connect(function(value)
        if cancellationProbe then
            cancellationEntered += 1
            cancellationThread = coroutine.running()
            task.wait(60)
            cancellationContinued += 1
            return
        end
        table.insert(queuedReceived.reliable, value)
    end))
    assert(session.events.UnreliableQueuePush:Connect(function(value)
        table.insert(queuedReceived.unreliable, value)
    end))
    assert(session.events.OncePush:Once(function(value)
        table.insert(queuedReceived.once, value)
    end))
    assert(session.events.ReusablePush:Connect(function(value)
        table.insert(queuedReceived.reusable, value)
    end))
end

local function queuedBody(eventId, value)
    local body = buffer.create(4)
    buffer.writeu8(body, 0, 1)
    buffer.writeu16(body, 1, eventId)
    buffer.writeu8(body, 3, value)
    return body
end

local function queuedEnvelope(kind, bodies)
    return assert(BatchFrame.wrap(kind, bodies, 8_192))
end

local function observeFarPart()
    local model = Workspace:FindFirstChild(InstanceValues.farModelName)
    return model ~= nil, model == nil or model:FindFirstChild("UnstreamedPart") == nil
end

control.OnClientInvoke = function(command, argument)
    if command == "competitive-paced-start" then
        if session then session:Destroy() end
        Competitive.prepare()
        session = assert(Relay.createClient(Competitive.createPaced(), { startupTimeoutSeconds = 10 }))
        assert(session:Start())
        competitivePacer = assert(session:CreatePacedBatcher(0.1, { manual = true }))
        return true
    elseif command == "competitive-paced-send" then
        local part = Competitive.prepare()
        assert(competitivePacer.events.ReliableInput:Send(1, part))
        assert(competitivePacer.events.UnreliableInput:Send(1, part))
        local ok, failure, report = competitivePacer:Step()
        local firstStatus = competitivePacer:GetStatus()
        assert(ok and failure == nil and report.selected == 0 and report.reliableHandoffs == 0
            and report.unreliableHandoffs == 0 and firstStatus.pendingRecords == 2,
            "manual pacer before first due time must retain rows without handoff")
        for sequence = 2, 40 do
            assert(competitivePacer.events.ReliableInput:Send(sequence, part))
            assert(competitivePacer.events.UnreliableInput:Send(sequence, part))
        end
        local status = competitivePacer:GetStatus()
        assert(status.pendingRecords == 80, "manual pacer retains all queued rows")
        return { selected = report.selected, reliableHandoffs = report.reliableHandoffs,
            unreliableHandoffs = report.unreliableHandoffs, pendingRecords = status.pendingRecords }
    elseif command == "competitive-paced-step" then
        local ok, failure, report = competitivePacer:Step()
        assert(ok, failure and failure.code or "manual pacer step")
        return { report = report, pendingRecords = competitivePacer:GetStatus().pendingRecords }
    elseif command == "competitive-paced-destroy" then
        local part = Competitive.prepare()
        assert(competitivePacer.events.ReliableInput:Send(250, part))
        assert(competitivePacer.events.UnreliableInput:Send(250, part))
        local before = competitivePacer:GetStatus()
        competitivePacer:Destroy()
        task.wait(0.15)
        local after = competitivePacer:GetStatus()
        assert(after.state == "Terminal" and after.pendingRecords == 0,
            "manual pacer destroy clears retained rows")
        session:Destroy()
        session = nil
        return { pendingBefore = before.pendingRecords, pendingAfter = after.pendingRecords, state = after.state }
    elseif command == "competitive-independent-start" then
        if session then session:Destroy() end
        Competitive.prepare()
        table.clear(competitiveStateRows.reliable)
        table.clear(competitiveStateRows.unreliable)
        table.clear(competitiveStateRows.reliableRaw)
        table.clear(competitiveStateRows.unreliableRaw)
        competitiveStateRows.drain = 0
        local created = assert(Relay.createClient(Competitive.createIndependent(), { startupTimeoutSeconds = 10 }))
        session = created
        assert(session.events.Drain:Connect(function() competitiveStateRows.drain += 1 end))
        assert(session.events.ReliableState:Connect(function(value)
            table.insert(competitiveStateRows.reliable, value)
        end))
        assert(session.events.UnreliableState:Connect(function(value)
            table.insert(competitiveStateRows.unreliable, value)
        end))
        local remotes = ReplicatedStorage:WaitForChild("RelayRemotes")
        table.insert(competitiveStateConnections, remotes.Reliable.OnClientEvent:Connect(function(endpoint, packet, ...)
            local row = Competitive.rawBatchReceipt("Reliable", endpoint, packet, ...)
            if row ~= nil then table.insert(competitiveStateRows.reliableRaw, row) end
        end))
        if remotes:FindFirstChild("Unreliable") then
            table.insert(competitiveStateConnections, remotes.Unreliable.OnClientEvent:Connect(function(endpoint, packet, ...)
                local row = Competitive.rawBatchReceipt("Unreliable", endpoint, packet, ...)
                if row ~= nil then table.insert(competitiveStateRows.unreliableRaw, row) end
            end))
        end
        assert(session:Start())
        return true
    elseif command == "competitive-independent-read" then
        local deadline = os.clock() + 10
        repeat
            if #competitiveStateRows.reliable >= 1 and #competitiveStateRows.reliableRaw >= 1
                and (#competitiveStateRows.unreliableRaw == 0
                    or #competitiveStateRows.unreliable >= #competitiveStateRows.unreliableRaw) then break end
            task.wait(0.03)
        until os.clock() >= deadline
        return {
            reliable = table.clone(competitiveStateRows.reliable),
            unreliable = table.clone(competitiveStateRows.unreliable),
            reliableRaw = table.clone(competitiveStateRows.reliableRaw),
            unreliableRaw = table.clone(competitiveStateRows.unreliableRaw),
            drain = competitiveStateRows.drain,
        }
    elseif command == "competitive-independent-destroy" then
        for _, item in competitiveStateConnections do item:Disconnect() end
        table.clear(competitiveStateConnections)
        if session then session:Destroy() session = nil end
        return true
    elseif command == "competitive-timestamps-start" then
        if session then session:Destroy() end
        Competitive.prepare()
        competitiveTimestampGeneration = nil
        local remotes = ReplicatedStorage:WaitForChild("RelayRemotes")
        if competitiveTimestampInitConnection then competitiveTimestampInitConnection:Disconnect() end
        competitiveTimestampInitConnection = remotes.Reliable.OnClientEvent:Connect(function(endpoint, packet)
            if endpoint == 0 and typeof(packet) == "buffer" and buffer.len(packet) == 42
                and buffer.readu8(packet, 0) == 2 and buffer.readu8(packet, 1) == 33 then
                competitiveTimestampGeneration = buffer.readu32(packet, 38)
            end
        end)
        session = assert(Relay.createClient(Competitive.createTimestamps(), { startupTimeoutSeconds = 10,
            diagnostics = { traffic = true, reports = true } }))
        assert(session:Start())
        local deadline = os.clock() + 10
        repeat
            if competitiveTimestampGeneration ~= nil then break end
            task.wait(0.03)
        until os.clock() >= deadline
        assert(competitiveTimestampGeneration ~= nil and competitiveTimestampGeneration > 0,
            "timestamp ordered generation initialized")
        return true
    elseif command == "competitive-timestamps-send" then
        assert(session.events.ReliableInput:Send(1))
        assert(session.events.UnreliableInput:Send(2))
        assert(session.events.OrderedInput:Send(3))
        local batch = assert(session:CreateBatch(0.05))
        assert(batch.events.BatchInput:Send(4))
        local batchOk, batchFailure = batch:Flush()
        assert(batchOk, batchFailure and batchFailure.code or "timestamp batch submission")
        local state = assert(session:CreateState(0.05))
        assert(state.events.StateInput:Put(1, "Normal", "state"))
        local stateOk, stateFailure = state:Flush()
        assert(stateOk, stateFailure and stateFailure.code or "timestamp State submission")
        return { reliable = 1, unreliable = 1, ordered = 1, batch = 1, state = 1 }
    elseif command == "competitive-timestamps-invalid" then
        local now = Workspace:GetServerTimeNow()
        local remote = ReplicatedStorage.RelayRemotes.Reliable
        local rows = {
            { serverTime = now, value = 41 },
            { serverTime = now - 5, value = 42 },
        }
        remote:FireServer(0, Competitive.timestampBatch(4, rows))
        remote:FireServer(0, Competitive.malformedTimestampBatch(4, {
            { serverTime = now, value = 43 }, { serverTime = now, value = 44 },
        }))
        remote:FireServer(0, Competitive.timestampBatch(4, {
            { serverTime = now, value = 45 }, { serverTime = math.huge, value = 46 },
        }))
        remote:FireServer(0, Competitive.timestampStateFrame(5, {
            { serverTime = now, value = "partial" },
            { serverTime = now - 5, value = "reject" },
        }))
        local unreliable = ReplicatedStorage.RelayRemotes.Unreliable
        unreliable:FireServer(2, Competitive.timestampPacket(2, now - 5, 47))
        remote:FireServer(1, Competitive.timestampPacket(1, now + 5, 48))
        unreliable:FireServer(3, Competitive.orderedTimestampPacket(3, competitiveTimestampGeneration, 100,
            now - 5, 49))
        unreliable:FireServer(3, Competitive.orderedTimestampPacket(3, competitiveTimestampGeneration, 101,
            now + 5, 50))
        unreliable:FireServer(3, Competitive.orderedTimestampPacket(3, competitiveTimestampGeneration, 102,
            math.huge, 51))
        assert(session.events.OrderedInput:Send(5), "valid ordered timestamp follows invalid high sequences")
        local batch = assert(session:CreateBatch(0.05))
        assert(batch.events.BatchInput:Send(6))
        local ok, failure = batch:Flush()
        assert(ok, failure and failure.code or "timestamp batch recovery")
        local state = assert(session:CreateState(0.05))
        assert(state.events.StateInput:Put(2, "High", "recover"))
        local stateOk, stateFailure = state:Flush()
        assert(stateOk, stateFailure and stateFailure.code or "timestamp State recovery")
        return true
    elseif command == "competitive-timestamps-byte-budget" then
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(0, buffer.create(8_193))
        return true
    elseif command == "competitive-timestamps-read" then
        local snapshot = session:GetDiagnostics()
        return { routes = competitiveTimestampRoutes(snapshot), reports = snapshot.reports }
    elseif command == "competitive-timestamps-destroy" then
        if competitiveTimestampInitConnection then competitiveTimestampInitConnection:Disconnect() end
        competitiveTimestampInitConnection = nil
        if session then session:Destroy() session = nil end
        return true
    elseif command == "competitive-diagnostics-start" then
        if session then session:Destroy() end
        competitiveDiagnosticsValues = { reliable = {}, unreliable = {}, batch = {}, state = {} }
        competitiveDiagnosticsRaw = { Reliable = {}, Unreliable = {} }
        session = assert(Relay.createClient(Competitive.createDiagnostics(), {
            startupTimeoutSeconds = 10, diagnostics = { traffic = true, reports = true },
        }))
        assert(session.events.Output:Connect(function(value)
            table.insert(competitiveDiagnosticsValues.reliable, value)
        end))
        assert(session.events.UnreliableOutput:Connect(function(value)
            table.insert(competitiveDiagnosticsValues.unreliable, value)
        end))
        assert(session.events.BatchOutput:Connect(function(value)
            table.insert(competitiveDiagnosticsValues.batch, value)
        end))
        assert(session.events.StateOutput:Connect(function(value)
            table.insert(competitiveDiagnosticsValues.state, value)
        end))
        local remotes = ReplicatedStorage:WaitForChild("RelayRemotes")
        for _, channel in { "Reliable", "Unreliable" } do
            local remote = remotes:FindFirstChild(channel)
            if remote ~= nil then
                table.insert(competitiveDiagnosticsConnections, remote.OnClientEvent:Connect(function(endpoint, packet, ...)
                    if endpoint == 4 then
                        local value = packet
                        table.insert(competitiveDiagnosticsRaw[channel], { endpoint = endpoint, value = value })
                    elseif endpoint == 5 then
                        local value = Competitive.codecByte(packet, 5)
                        table.insert(competitiveDiagnosticsRaw[channel], { endpoint = endpoint, value = value })
                    elseif endpoint == 0 then
                        local row = Competitive.rawBatchReceipt(channel, endpoint, packet, ...)
                        if row ~= nil then table.insert(competitiveDiagnosticsRaw[channel], row) end
                        if row == nil and typeof(packet) == "buffer" and buffer.len(packet) >= 47
                            and (buffer.readu8(packet, 0) == 1 or buffer.readu8(packet, 0) == 7) then
                            table.insert(competitiveDiagnosticsRaw[channel], {
                                endpoint = endpoint, methodId = buffer.readu16(packet, 2),
                                kind = buffer.readu8(packet, 1), length = buffer.len(packet),
                                referenceCount = select("#", ...),
                            })
                        end
                    end
                end))
            end
        end
        assert(session:Start())
        return true
    elseif command == "competitive-diagnostics-baseline" then
        competitiveDiagnosticsBaseline = session:GetDiagnostics()
        return true
    elseif command == "competitive-diagnostics-send" then
        assert(session.events.Input:Send(1))
        assert(session.events.UnreliableInput:Send(2))
        local batch = assert(session:CreateBatch(0.05))
        assert(batch.events.BatchInput:Send(3))
        local batchOk, batchFailure = batch:Flush()
        assert(batchOk, batchFailure and batchFailure.code or "diagnostics Batch submission")
        local pending, problem = session.requests.Inspect:Request(5, 7)
        assert(pending ~= nil, problem and problem.code or "diagnostics RPC request")
        local response = pending:Await()
        assert(response ~= nil and response.ok and response.value == 8,
            "diagnostics RPC response failed: "
                .. tostring(response and response.error and response.error.code or response and response.value))
        local invalid, invalidFailure = session.events.Input:Send(256)
        assert(not invalid and invalidFailure.code == "InvalidPayload", "diagnostics local validation refusal")
        return true
    elseif command == "competitive-diagnostics-read" then
        local expectedReliable = if type(argument) == "table" then argument.expectedReliable else 1
        local requireInvalidOutput = type(argument) == "table" and argument.requireInvalidOutput == true
        local deadline = os.clock() + 10
        repeat
            local observedUnreliable = 0
            for _, row in competitiveDiagnosticsRaw.Unreliable do
                if row.endpoint == 5 then observedUnreliable += 1 end
            end
            local snapshot = session:GetDiagnostics()
            local invalidOutputObserved = false
            for _, entry in snapshot.reports.entries do
                if entry.reason == "InvalidPayload" and entry.endpointId == 4
                    and entry.channel == "Reliable" and entry.count == 1 then
                    invalidOutputObserved = true
                end
            end
            local outputBaseline = competitiveDiagnosticsBaseline.traffic.endpoints[4].channels.Reliable.receivedPackets
            local observedMalformedOutput = snapshot.traffic.endpoints[4].channels.Reliable.receivedPackets
                >= outputBaseline + expectedReliable + 1
            if #competitiveDiagnosticsValues.reliable >= expectedReliable
                and #competitiveDiagnosticsValues.batch >= 1 and #competitiveDiagnosticsValues.state >= 1
                and #competitiveDiagnosticsValues.unreliable >= observedUnreliable
                and (not requireInvalidOutput or (invalidOutputObserved and observedMalformedOutput)) then break end
            task.wait(0.03)
        until os.clock() >= deadline
        task.wait(0.15)
        local snapshot = session:GetDiagnostics()
        if requireInvalidOutput then
            local reportCount = 0
            for _, entry in snapshot.reports.entries do
                if entry.reason == "InvalidPayload" then
                    assert(entry.endpointId == 4 and entry.channel == "Reliable" and entry.count == 1,
                        "C06 malformed Output report names its endpoint and channel")
                    reportCount += 1
                end
            end
            assert(reportCount == 1
                and snapshot.traffic.endpoints[4].channels.Reliable.receivedPackets
                    >= competitiveDiagnosticsBaseline.traffic.endpoints[4].channels.Reliable.receivedPackets
                        + expectedReliable + 1,
                "C06 final diagnostics read observed the malformed native Output")
        end
        local reliableFrames, unreliableFrames = {}, {}
        for _, value in competitiveDiagnosticsRaw.Reliable do
            if value.format == 2 or value.format == 5 then table.insert(reliableFrames, value) end
        end
        for _, value in competitiveDiagnosticsRaw.Unreliable do
            if value.format == 2 or value.format == 5 or value.endpoint == 5 then
                table.insert(unreliableFrames, value)
            end
        end
        return { reliable = table.clone(competitiveDiagnosticsValues.reliable),
            unreliable = table.clone(competitiveDiagnosticsValues.unreliable),
            batch = table.clone(competitiveDiagnosticsValues.batch), state = table.clone(competitiveDiagnosticsValues.state),
            reliableFrames = reliableFrames, unreliableFrames = unreliableFrames,
            rpcFrames = table.clone(competitiveDiagnosticsRaw.Reliable),
            baselineRoutes = competitiveDiagnosticsRoutes(competitiveDiagnosticsBaseline),
            routes = competitiveDiagnosticsRoutes(snapshot), reports = snapshot.reports }
    elseif command == "competitive-diagnostics-errors" then
        local invalid, failure = session.events.Input:Send(256)
        assert(not invalid and failure.code == "InvalidPayload", "diagnostics repeated local refusal")
        local remote = ReplicatedStorage.RelayRemotes.Reliable
        remote:FireServer(1, 99)
        remote:FireServer(1, 256)
        return true
    elseif command == "competitive-diagnostics-postmortem" then
        local enabled = assert(session)
        local before = enabled:GetDiagnostics()
        enabled:Destroy()
        local afterDestroy = enabled:GetDiagnostics()
        local sent, failure = enabled.events.Input:Send(1)
        task.wait(0.15)
        local afterLateWork = enabled:GetDiagnostics()
        local receipt = {
            readable = afterDestroy.state == "Destroyed" and afterDestroy.traffic ~= nil
                and afterDestroy.reports ~= nil and afterDestroy.counters ~= nil,
            stable = Competitive.diagnosticsStable(afterDestroy, afterLateWork),
            refused = not sent and failure ~= nil and failure.code == "Destroyed",
            started = before.state == "Started",
        }
        assert(receipt.readable and receipt.stable and receipt.refused and receipt.started,
            "destroyed diagnostics stay readable and stable while old event APIs refuse work")
        session = nil
        return receipt
    elseif command == "competitive-diagnostics-disabled" then
        if session then session:Destroy() end
        session = assert(Relay.createClient(Competitive.createDiagnostics(), { startupTimeoutSeconds = 10 }))
        assert(session:Start())
        local snapshot = session:GetDiagnostics()
        assert(snapshot.traffic == nil and snapshot.reports == nil,
            "disabled diagnostics omit all optional snapshot allocations")
        session:Destroy()
        session = nil
        for _, item in competitiveDiagnosticsConnections do item:Disconnect() end
        table.clear(competitiveDiagnosticsConnections)
        return { trafficOmitted = true, reportsOmitted = true }
    elseif command == "competitive-diagnostics-stop" then
        for _, item in competitiveDiagnosticsConnections do item:Disconnect() end
        table.clear(competitiveDiagnosticsConnections)
        if session then session:Destroy() session = nil end
        return true
    elseif command == "ordered-start" then
        if session then session:Destroy() end
        if orderedInitObserver then orderedInitObserver:Disconnect() end
        if orderedRawObserver then orderedRawObserver:Disconnect() end
        orderedGeneration, orderedValues, orderedRawCount, orderedMaximumBytes = nil, {}, 0, 0
        orderedStreamValues, orderedStreamRawSamples = { shared = {}, targeted = {} }, {}
        orderedStreamRawCounts, orderedStreamLastSequences = { shared = 0, targeted = 0 }, { shared = 0, targeted = 0 }
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        orderedInitObserver = root.Reliable.OnClientEvent:Connect(function(endpoint, packet)
            if endpoint == 0 and typeof(packet) == "buffer" and buffer.len(packet) == 42
                and buffer.readu8(packet, 0) == 2 and buffer.readu8(packet, 1) == 33 then
                orderedGeneration = buffer.readu32(packet, 38)
            end
        end)
        session = assert(Relay.createClient(Fixture.createOrderedUnreliable(), { startupTimeoutSeconds = 10 }))
        assert(session.events.Output:Connect(function(text)
            if #text == 887 then assert(text == string.rep("x", 887), "ordered maximum payload contents") end
            table.insert(orderedValues, if #text == 887 then "maximum" else text)
        end))
        assert(session.events.SharedStream:Connect(function(serverTime, value)
            if #orderedStreamValues.shared < 16 then
                table.insert(orderedStreamValues.shared, { serverTime = serverTime, clientTime = Workspace:GetServerTimeNow(),
                    statePresent = value ~= nil, state = value })
            end
        end))
        assert(session.events.TargetedStream:Connect(function(serverTime, value)
            if #orderedStreamValues.targeted < 16 then
                table.insert(orderedStreamValues.targeted, { serverTime = serverTime, clientTime = Workspace:GetServerTimeNow(),
                    statePresent = value ~= nil, state = value })
            end
        end))
        assert(session:Start())
        assert(orderedGeneration ~= nil and orderedGeneration > 0, "ordered startup generation")
        orderedRawObserver = root.Unreliable.OnClientEvent:Connect(function(endpoint, packet)
            if endpoint == 2 then
                orderedRawCount += 1
                if typeof(packet) == "buffer" then
                    orderedMaximumBytes = math.max(orderedMaximumBytes, buffer.len(packet))
                end
            elseif (endpoint == 3 or endpoint == 4) and typeof(packet) == "buffer" then
                local key = if endpoint == 3 then "shared" else "targeted"
                orderedStreamRawCounts[key] += 1
                if buffer.len(packet) >= 20 and buffer.readu8(packet, 0) == 3 then
                    local sequence = buffer.readu32(packet, 7)
                    local serverTime = buffer.readf64(packet, 11)
                    local statePresent = buffer.readu8(packet, 19) == 1
                    orderedStreamLastSequences[key] = sequence
                    if #orderedStreamRawSamples < 16 then
                        table.insert(orderedStreamRawSamples, { endpoint = endpoint, format = 3,
                            eventId = buffer.readu16(packet, 1), generation = buffer.readu32(packet, 3),
                            length = buffer.len(packet), sequence = sequence, serverTime = serverTime,
                            statePresent = statePresent,
                            state = if statePresent and buffer.len(packet) >= 24 then buffer.readf32(packet, 20) else nil })
                    end
                end
            end
        end)
        return orderedGeneration
    elseif command == "ordered-send-maximum" then
        assert(session.events.Input:Send(string.rep("x", 887)))
        local before = session:GetDiagnostics().counters.sendHandoffs
        local sent, failure = session.events.Input:Send(string.rep("x", 888))
        assert(not sent and failure.code == "InvalidPayload"
            and session:GetDiagnostics().counters.sendHandoffs == before,
            "ordered 901-byte client send rejects before handoff")
        return true
    elseif command == "ordered-send" then
        assert(session.events.Input:Send(argument))
        return true
    elseif command == "ordered-send-raw" then
        ReplicatedStorage.RelayRemotes.Unreliable:FireServer(1,
            orderedPacket(1, argument.generation or orderedGeneration, argument.sequence, argument.text, argument.malformed))
        return true
    elseif command == "ordered-read" then
        local snapshot = session:GetDiagnostics()
        return { values = table.clone(orderedValues), raw = orderedRawCount, maximumFrameBytes = orderedMaximumBytes,
            stale = snapshot.events.Output.stale, invalidPayload = snapshot.events.Output.invalidPayload }
    elseif command == "ordered-stream-read" then
        local snapshot = session:GetDiagnostics()
        return { generation = orderedGeneration, shared = table.clone(orderedStreamValues.shared),
            targeted = table.clone(orderedStreamValues.targeted), raw = table.clone(orderedStreamRawSamples),
            rawCounts = table.clone(orderedStreamRawCounts), lastSequences = table.clone(orderedStreamLastSequences),
            invalidPayload = snapshot.events.SharedStream.invalidPayload }
    elseif command == "ordered-destroy" then
        session:Destroy()
        orderedInitObserver:Disconnect()
        orderedRawObserver:Disconnect()
        orderedInitObserver, orderedRawObserver = nil, nil
        return true
    elseif command == "color3-start" then
        if session then session:Destroy() end
        session = assert(Relay.createClient(Fixture.createColor3(), { startupTimeoutSeconds = 10 }))
        color3Received, color3Failure = { native = 0, composite = 0 }, nil
        local function record(name, value)
            local ok, failure = pcall(Fixture.checkColor3, value)
            if not ok then color3Failure = tostring(failure) end
            color3Received[name] += 1
        end
        assert(session.events.Output:Connect(function(value) record("native", value) end))
        assert(session.events.CompositeOutput:Connect(function(value) record("composite", value.tint) end))
        assert(session:Start())
        return Fixture.color3ProbeCount
    elseif command == "color3-send" then
        assert(session.events.Input:Send(Fixture.color3Value()))
        assert(session.events.CompositeInput:Send({ tint = Fixture.color3Value() }))
        local pending = assert(session.requests.Echo:Request(5, Fixture.color3Value()))
        local result = pending:Await()
        assert(result.ok, "native Color3 RPC response")
        Fixture.checkColor3(result.value)
    elseif command == "color3-read" then
        local deadline = os.clock() + 10
        repeat
            if color3Failure ~= nil then error(color3Failure) end
            if color3Received.native == 1 and color3Received.composite == 1 then return true end
            task.wait(0.03)
        until os.clock() >= deadline
        error("native Color3 output timeout")
    elseif command == "color3-byte" then
        assert(session.events.Input:Send(Fixture.color3Value()))
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(0, buffer.create(0))
        assert(session.events.Input:Send(Fixture.color3Value()))
    elseif command == "color3-destroy" then
        session:Destroy()
        session:Destroy()
        local ok, failure = session.events.Input:Send(Fixture.color3Value())
        assert(not ok and failure.code == "Destroyed", "destroyed Color3 client")
    elseif command == "rgb8-start" then
        if session then session:Destroy() end
        if rgb8Color3RawConnection then rgb8Color3RawConnection:Disconnect() end
        rgb8Color3Received, rgb8Color3Sources, rgb8Color3Failure, rgb8Color3RawFrames = {}, {}, nil, {}
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        rgb8Color3RawConnection = root.Reliable.OnClientEvent:Connect(function(endpoint, packet)
            local row = CompactTransport.rawReceipt(endpoint, packet)
            if row ~= nil and row.eventId == 2 then table.insert(rgb8Color3RawFrames, row) end
        end)
        session = assert(Relay.createClient(Fixture.createRgb8Color3(), { startupTimeoutSeconds = 10 }))
        assert(session.events.Output:Connect(function(index, value)
            local ok, observation = pcall(Fixture.checkRgb8Color3, value, index)
            if not ok then rgb8Color3Failure = tostring(observation) return end
            table.insert(rgb8Color3Received, { index = index, value = observation })
        end))
        assert(session:Start())
        return true
    elseif command == "rgb8-send" then
        for index = 0, Fixture.rgb8Color3ProbeCount - 1 do
            local value = Fixture.rgb8Color3Source(index)
            table.insert(rgb8Color3Sources, { index = index, value = Fixture.rgb8Color3Components(value) })
            assert(session.events.Input:Send(index, value))
        end
        return true
    elseif command == "rgb8-read" then
        local deadline = os.clock() + 15
        repeat
            if rgb8Color3Failure ~= nil then error(rgb8Color3Failure) end
            if #rgb8Color3Received == Fixture.rgb8Color3ProbeCount
                and #rgb8Color3RawFrames == Fixture.rgb8Color3ProbeCount then
                return { values = table.clone(rgb8Color3Received), sources = table.clone(rgb8Color3Sources),
                    raw = table.clone(rgb8Color3RawFrames), failure = rgb8Color3Failure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("RGB8 Color3 S2C receipt timeout")
    elseif command == "rgb8-destroy" then
        if rgb8Color3RawConnection then rgb8Color3RawConnection:Disconnect() end
        rgb8Color3RawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "rgb8-malformed-start" then
        if session then session:Destroy() end
        if rgb8Color3RawConnection then rgb8Color3RawConnection:Disconnect() end
        rgb8Color3RawConnection = nil
        session = assert(Relay.createClient(Fixture.createRgb8Color3(), { startupTimeoutSeconds = 10 }))
        assert(session:Start())
        return true
    elseif command == "rgb8-malformed" then
        local remote = ReplicatedStorage.RelayRemotes.Reliable
        local truncated = buffer.create(7)
        buffer.writeu8(truncated, 0, 1)
        buffer.writeu16(truncated, 1, 1)
        buffer.writeu16(truncated, 3, 256)
        buffer.writeu8(truncated, 5, 0)
        buffer.writeu8(truncated, 6, 127)
        remote:FireServer(1, truncated)
        local valid = buffer.create(8)
        buffer.writeu8(valid, 0, 1)
        buffer.writeu16(valid, 1, 1)
        buffer.writeu16(valid, 3, 0)
        buffer.writeu8(valid, 5, 0)
        buffer.writeu8(valid, 6, 255)
        buffer.writeu8(valid, 7, 0)
        remote:FireServer(1, valid)
        return true
    elseif command == "native-values-start" then
        if session then session:Destroy() end
        nativeValueGroup = argument
        nativeValueReceived = {}
        nativeValueReceivedCounts = {}
        nativeValueFailure = nil
        session = assert(Relay.createClient(NativeValues.create(nativeValueGroup), { startupTimeoutSeconds = 10 }))
        assert(session.events.Output:Connect(function(value)
            local kind = if type(value) == "table" and type(value.kind) == "string" then value.kind else nil
            local sampleIndex = if kind == nil then 1 else (nativeValueReceivedCounts[kind] or 0) + 1
            local ok, name = pcall(NativeValues.check, nativeValueGroup, value, sampleIndex)
            if not ok then
                nativeValueFailure = tostring(name)
                return
            end
            table.insert(nativeValueReceived, name)
            nativeValueReceivedCounts[name] = sampleIndex
            if name == "Font" then
                value.value.Weight = Enum.FontWeight.Light
            end
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "native value client start failed")
        return true
    elseif command == "native-values-send" then
        for _, name in NativeValues.names(nativeValueGroup) do
            for sampleIndex = 1, NativeValues.repeatCount(name) do
                local value = NativeValues.make(nativeValueGroup, name, sampleIndex)
                local ok, failure = session.events.Input:Send(value)
                assertSend(ok, failure, "native C2S " .. name)
                if name == "Font" then
                    value.value.Weight = Enum.FontWeight.Light
                end
            end
        end
        if table.find(NativeValues.names(nativeValueGroup), "TweenInfo") then
            local handoffs = session:GetDiagnostics().counters.sendHandoffs
            local invalid = { kind = "TweenInfo", value = TweenInfo.new(1, Enum.EasingStyle.Linear,
                Enum.EasingDirection.In, -1, false, 0) }
            local ok, failure = session.events.Input:Send(invalid)
            assert(not ok and failure.code == "InvalidPayload"
                and session:GetDiagnostics().counters.sendHandoffs == handoffs,
                "infinite TweenInfo requires explicit schema opt-in")
        end
        return true
    elseif command == "native-values-read" then
        local expected = 0
        for _, name in NativeValues.names(nativeValueGroup) do expected += NativeValues.repeatCount(name) end
        local deadline = os.clock() + 10
        repeat
            if nativeValueFailure ~= nil then error(nativeValueFailure) end
            if #nativeValueReceived == expected then return table.clone(nativeValueReceived) end
            task.wait(0.03)
        until os.clock() >= deadline
        error("native value S2C receipt timeout")
    elseif command == "native-values-destroy" then
        if session then session:Destroy() end
        return true
    elseif command == "instance-values-start" then
        if session then session:Destroy() end
        if instanceRawConnection then instanceRawConnection:Disconnect() end
        instancePeerPlayer = assert(Players:GetPlayerByUserId(argument), "Instance proof peer Player")
        instanceReceived, instanceFailure = {}, nil
        instanceMissingOutputCalls = 0
        instanceScopeCalls, instanceScopeReceipt = 0, nil
        instanceStreamCalls = 0
        instanceRawFrames = {}
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        instanceRawConnection = root.Reliable.OnClientEvent:Connect(function(endpointId, packet, ...)
            if type(endpointId) ~= "number" or endpointId < 1 or endpointId > 7 then return end
            local receipt = InstanceValues.rawReceipt(endpointId, packet, ...)
            receipt.client = Players.LocalPlayer.UserId
            table.insert(instanceRawFrames, receipt)
        end)
        session = assert(Relay.createClient(InstanceValues.create(), { startupTimeoutSeconds = 10 }))
        assert(session.events.Output:Connect(function(value)
            local ok, receipt = pcall(InstanceValues.check, value, InstanceValues.objects(instancePeerPlayer),
                value.choice.kind, value.animator ~= nil)
            if not ok then instanceFailure = tostring(receipt) return end
            table.insert(instanceReceived, receipt)
        end))
        assert(session.events.MissingOutput:Connect(function(value)
            instanceMissingOutputCalls += 1
            local ok, problem = pcall(function()
                assert(value == InstanceValues.objects(instancePeerPlayer).rootFolder,
                    "valid Folder identity after missing S2C reference")
            end)
            if not ok then instanceFailure = tostring(problem) end
        end))
        assert(session.events.ScopedOutput:Connect(function(first, second)
            instanceScopeCalls += 1
            local ok, receipt = pcall(InstanceValues.scopeReceipt, first, second)
            if not ok then instanceFailure = tostring(receipt) return end
            local objects = InstanceValues.scopeObjects()
            if first ~= objects.folder or second ~= objects.part then
                instanceFailure = "scoped S2C Instance identity changed"
                return
            end
            instanceScopeReceipt = receipt
        end))
        assert(session.events.StreamingOutput:Connect(function()
            instanceStreamCalls += 1
            instanceFailure = "unstreamed Instance reached a callback"
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "Instance proof client start failed")
        return true
    elseif command == "instance-values-send" then
        local valueObjects = InstanceValues.objects(Players.LocalPlayer)
        for _, branch in { "Model", "Tool" } do
            local value = InstanceValues.payload(valueObjects, branch, branch == "Tool")
            local ok, failure = session.events.Input:Send(value)
            assertSend(ok, failure, "native Instance C2S " .. branch)
        end
        return true
    elseif command == "instance-values-read" then
        local deadline = os.clock() + 10
        repeat
            if instanceFailure ~= nil then error(instanceFailure) end
            if #instanceReceived == 2 then return table.clone(instanceReceived) end
            task.wait(0.03)
        until os.clock() >= deadline
        error("native Instance S2C receipt timeout")
    elseif command == "instance-missing-client-send" then
        if instanceLocalOnly then instanceLocalOnly:Destroy() end
        instanceLocalOnly = Instance.new("Folder")
        instanceLocalOnly.Name = "RelayProofClientOnlyFolder"
        instanceLocalOnly.Parent = Workspace
        assert(instanceLocalOnly:IsDescendantOf(game), "client-only Instance is live in the client DataModel")
        local ok, failure = session.events.MissingInput:Send(instanceLocalOnly)
        assertSend(ok, failure, "client-only Instance C2S")
        return true
    elseif command == "instance-missing-client-valid" then
        local value = InstanceValues.objects(Players.LocalPlayer).rootFolder
        local ok, failure = session.events.MissingInput:Send(value)
        assertSend(ok, failure, "valid Instance after client-only reference")
        return true
    elseif command == "instance-missing-output-await" then
        local deadline = os.clock() + 10
        repeat
            if instanceFailure ~= nil then error(instanceFailure) end
            local diagnostics = session:GetDiagnostics().events.MissingOutput
            if diagnostics.invalidPayload >= 1 then
                return { invalidPayload = diagnostics.invalidPayload, dispatched = diagnostics.dispatched,
                    callbacks = instanceMissingOutputCalls, failure = instanceFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("ServerStorage Instance rejection timeout")
    elseif command == "instance-missing-output-valid" then
        local deadline = os.clock() + 10
        repeat
            if instanceFailure ~= nil then error(instanceFailure) end
            local dispatched = session:GetDiagnostics().events.MissingOutput.dispatched
            if dispatched >= 1 and instanceMissingOutputCalls >= 1 then
                return { dispatched = dispatched, callbacks = instanceMissingOutputCalls, failure = instanceFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("valid Instance after ServerStorage reference timeout")
    elseif command == "instance-stream-absence" then
        assert(Workspace.StreamingEnabled, "client Workspace streaming must be enabled")
        local started = os.clock()
        local absentSince
        local containerPresent, partAbsent = false, false
        repeat
            containerPresent, partAbsent = observeFarPart()
            if containerPresent and partAbsent then
                absentSince = absentSince or os.clock()
                local stableSeconds = os.clock() - absentSince
                if stableSeconds >= 1 then
                    return { streamingEnabled = true, containerPresent = true, partAbsent = true,
                        stableSeconds = stableSeconds }
                end
            else
                absentSince = nil
            end
            task.wait(0.05)
        until os.clock() - started >= 10
        containerPresent, partAbsent = observeFarPart()
        return { streamingEnabled = true, containerPresent = containerPresent, partAbsent = partAbsent,
            stableSeconds = if absentSince then os.clock() - absentSince else 0 }
    elseif command == "instance-stream-await" then
        local deadline = os.clock() + 10
        repeat
            local diagnostics = session:GetDiagnostics().events.StreamingOutput
            if diagnostics.invalidPayload >= 1 then
                local containerPresent, partAbsent = observeFarPart()
                return { streamingEnabled = Workspace.StreamingEnabled, containerPresent = containerPresent,
                    partAbsent = partAbsent,
                    invalidPayload = diagnostics.invalidPayload, dispatched = diagnostics.dispatched,
                    callbacks = instanceStreamCalls, failure = instanceFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("unstreamed Instance rejection timeout")
    elseif command == "instance-scope-outside" then
        local objects = InstanceValues.scopeObjects()
        local ok, failure = session.events.ScopedInput:Send(objects.folder, objects.outsidePart)
        assertSend(ok, failure, "out-of-server-root Instance C2S")
        return true
    elseif command == "instance-scope-malformed" then
        local objects = InstanceValues.scopeObjects()
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(5,
            InstanceValues.duplicateSecondSlotPacket(), objects.folder, objects.part)
        return true
    elseif command == "instance-scope-valid" then
        local objects = InstanceValues.scopeObjects()
        local ok, failure = session.events.ScopedInput:Send(objects.folder, objects.part)
        assertSend(ok, failure, "valid scoped Instance C2S")
        return true
    elseif command == "instance-scope-read" then
        local deadline = os.clock() + 10
        repeat
            if instanceFailure ~= nil then error(instanceFailure) end
            if instanceScopeCalls >= 1 then
                return { calls = instanceScopeCalls, failure = instanceFailure, references = instanceScopeReceipt }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("scoped Instance S2C receipt timeout")
    elseif command == "instance-raw-read" then
        return table.clone(instanceRawFrames)
    elseif command == "instance-values-destroy" then
        if instanceRawConnection then instanceRawConnection:Disconnect() end
        instanceRawConnection = nil
        if instanceLocalOnly then instanceLocalOnly:Destroy() end
        instanceLocalOnly = nil
        if session then session:Destroy() end
        return true
    elseif command == "buffer-start" then
        if session then session:Destroy() end
        if bufferRawConnection then bufferRawConnection:Disconnect() end
        bufferOutputValues, bufferQueueValues = {}, {}
        bufferRawFrames, bufferQueueRawFrames, bufferFailure = {}, {}, nil
        session = assert(Relay.createClient(BufferDeferral.createBuffers(false), { startupTimeoutSeconds = 10 }))
        assert(session.events.Output:Connect(function(value)
            local ok, result = pcall(BufferDeferral.bytesArray, value)
            if not ok then bufferFailure = tostring(result) return end
            table.insert(bufferOutputValues, result)
        end))
        assert(session.events.QueuedOutput:Connect(function(value)
            local ok, result = pcall(BufferDeferral.bytesArray, value)
            if not ok then bufferFailure = tostring(result) return end
            table.insert(bufferQueueValues, result)
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "native buffer client session start failed")
        return true
    elseif command == "buffer-arm" then
        if bufferRawConnection then bufferRawConnection:Disconnect() end
        bufferRawFrames, bufferQueueRawFrames = {}, {}
        local remote = ReplicatedStorage:WaitForChild("RelayRemotes").Reliable
        bufferRawConnection = remote.OnClientEvent:Connect(function(endpoint, ...)
            if select("#", ...) ~= 1 then return end
            local row = BufferDeferral.rawReceipt(endpoint, ...)
            if endpoint == 2 and row ~= nil then
                table.insert(bufferRawFrames, row)
            elseif endpoint == 0 then
                local packet = ...
                local header = BatchFrame.header(packet, 8_192)
                if header ~= nil and header.kind == 1 and header.count == 1
                    and buffer.readu16(packet, 3) >= 9 and buffer.readu16(packet, 6) == 3 then
                    local queued = BufferDeferral.packetReceipt(packet)
                    if queued ~= nil then
                        queued.kind = header.kind
                        queued.eventId = buffer.readu16(packet, 6)
                        queued.bodyBytes = buffer.readu16(packet, 3)
                        table.insert(bufferQueueRawFrames, queued)
                    end
                end
            end
        end)
        return true
    elseif command == "buffer-send" then
        local before = session:GetDiagnostics().counters.sendHandoffs
        local oversizedOk, oversizedFailure = session.events.Input:Send(BufferDeferral.oversizedValue())
        local after = session:GetDiagnostics().counters.sendHandoffs
        assert(not oversizedOk and oversizedFailure.code == "InvalidPayload" and after == before,
            "oversized buffer rejects before any native handoff")
        assert(session.events.Input:Send(BufferDeferral.inputValue()))
        local reliable = ReplicatedStorage.RelayRemotes.Reliable
        reliable:FireServer(1, BufferDeferral.overCapProbe())
        reliable:FireServer(1, BufferDeferral.truncatedPrefixProbe())
        reliable:FireServer(1, BufferDeferral.truncatedBodyProbe())
        reliable:FireServer(1, BufferDeferral.trailingDataProbe())
        assert(session.events.Input:Send(BufferDeferral.recoveryValue()))

        local shortProbe = buffer.create(1)
        buffer.writeu8(shortProbe, 0, 1)
        reliable:FireServer(1, shortProbe)
        return { oversizedSent = oversizedOk, oversizedError = oversizedFailure.code,
            handoffDelta = after - before }
    elseif command == "buffer-read" then
        local deadline = os.clock() + 10
        repeat
            if bufferFailure ~= nil then error(bufferFailure) end
            if #bufferOutputValues == 1 and #bufferQueueValues == 1
                and #bufferRawFrames >= 1 and #bufferQueueRawFrames >= 1 then
                return { output = table.clone(bufferOutputValues), queued = table.clone(bufferQueueValues),
                    raw = table.clone(bufferRawFrames), queuedRaw = table.clone(bufferQueueRawFrames),
                    failure = bufferFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("native buffer S2C receipt timeout")
    elseif command == "buffer-destroy" then
        if bufferRawConnection then bufferRawConnection:Disconnect() end
        bufferRawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "state-start" then
        if session then session:Destroy() end
        if stateRawConnection then stateRawConnection:Disconnect() end
        statePulseValues, stateOutputValues = {}, {}
        statePulseRawFrames, stateOutputRawFrames, stateFailure = {}, {}, nil
        session = assert(Relay.createClient(BufferDeferral.createStateDeferral(true), { startupTimeoutSeconds = 10 }))
        assert(session.events.Pulse:Connect(function(value)
            local ok, result = pcall(BufferDeferral.bytesArray, value)
            if not ok then stateFailure = tostring(result) return end
            table.insert(statePulseValues, result)
        end))
        assert(session.events.StateOutput:Connect(function(value)
            local ok, result = pcall(BufferDeferral.bytesArray, value)
            if not ok then stateFailure = tostring(result) return end
            table.insert(stateOutputValues, result)
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "State deferral client session start failed")
        return true
    elseif command == "state-arm" then
        if stateRawConnection then stateRawConnection:Disconnect() end
        statePulseRawFrames, stateOutputRawFrames = {}, {}
        local remote = ReplicatedStorage:WaitForChild("RelayRemotes").Reliable
        stateRawConnection = remote.OnClientEvent:Connect(function(endpoint, ...)
            if select("#", ...) ~= 1 then return end
            local packet = ...
            if endpoint == 1 then
                local row = BufferDeferral.rawReceipt(endpoint, packet)
                if row ~= nil then table.insert(statePulseRawFrames, row) end
            elseif endpoint == 0 and typeof(packet) == "buffer" and buffer.len(packet) >= 11
                and buffer.readu8(packet, 0) == 2 and buffer.readu8(packet, 1) == 2
                and buffer.readu16(packet, 3) >= 6 and buffer.readu16(packet, 6) == 2 then
                local row = BufferDeferral.packetReceipt(packet)
                if row ~= nil then table.insert(stateOutputRawFrames, row) end
            end
        end)
        return true
    elseif command == "state-read" then
        local expected = argument or {}
        local deadline = os.clock() + 5
        repeat
            if stateFailure ~= nil then error(stateFailure) end
            if #statePulseValues >= (expected.pulses or 0)
                and #stateOutputValues >= (expected.states or 0)
                and #statePulseRawFrames >= (expected.pulseRaw or 0)
                and #stateOutputRawFrames >= (expected.stateRaw or 0) then
                return { pulses = table.clone(statePulseValues), states = table.clone(stateOutputValues),
                    pulseRaw = table.clone(statePulseRawFrames), stateRaw = table.clone(stateOutputRawFrames),
                    failure = stateFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("State deferral native receipt timeout")
    elseif command == "state-destroy" then
        if stateRawConnection then stateRawConnection:Disconnect() end
        stateRawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "compact-start" then
        if session then session:Destroy() end
        if compactRawConnection then compactRawConnection:Disconnect() end
        compactReceived, compactFailure, compactRawFrames = { vector3 = {}, vector2 = {}, frames = {} }, nil, {}
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        compactRawConnection = root.Reliable.OnClientEvent:Connect(function(endpoint, packet)
            local row = CompactTransport.rawReceipt(endpoint, packet)
            if row ~= nil and (row.eventId == 2 or row.eventId == 4 or row.eventId == 6) then
                table.insert(compactRawFrames, row)
            end
        end)
        session = assert(Relay.createClient(CompactTransport.createCompact(argument == true), {
            startupTimeoutSeconds = 10,
        }))
        assert(session.events.Vector3Output:Connect(function(value)
            local ok, result = pcall(CompactTransport.checkVector3, value)
            if not ok then compactFailure = tostring(result) return end
            table.insert(compactReceived.vector3, result)
        end))
        assert(session.events.Vector2Output:Connect(function(value)
            local ok, result = pcall(CompactTransport.checkVector2, value)
            if not ok then compactFailure = tostring(result) return end
            table.insert(compactReceived.vector2, result)
        end))
        assert(session.events.FrameOutput:Connect(function(...)
            local ok, result = pcall(CompactTransport.checkFrames, ...)
            if not ok then compactFailure = tostring(result) return end
            table.insert(compactReceived.frames, result)
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "compact-value client session start failed")
        return true
    elseif command == "compact-send" then
        assert(session.events.Vector3Input:Send(CompactTransport.vector3Value()))
        assert(session.events.Vector2Input:Send(CompactTransport.vector2Value()))
        assert(session.events.FrameInput:Send(CompactTransport.frameValues()))
        local reliable = ReplicatedStorage.RelayRemotes.Reliable
        reliable:FireServer(1, CompactTransport.compactUnusedVector3())
        reliable:FireServer(1, CompactTransport.compactTruncatedVector3())
        reliable:FireServer(5, CompactTransport.compactUnusedFrame())
        reliable:FireServer(5, CompactTransport.compactTruncatedFrame())
        assert(session.events.Vector3Input:Send(CompactTransport.vector3Value()))
        reliable:FireServer(1, buffer.create(1))
        return true
    elseif command == "compact-read" then
        local deadline = os.clock() + 10
        repeat
            if compactFailure ~= nil then error(compactFailure) end
            if #compactReceived.vector3 == 1 and #compactReceived.vector2 == 1
                and #compactReceived.frames == 1 and #compactRawFrames >= 3 then
                return { vector3 = table.clone(compactReceived.vector3),
                    vector2 = table.clone(compactReceived.vector2),
                    frames = table.clone(compactReceived.frames), raw = table.clone(compactRawFrames),
                    failure = compactFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("compact native S2C receipt timeout")
    elseif command == "compact-destroy" then
        if compactRawConnection then compactRawConnection:Disconnect() end
        compactRawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "budget-start" then
        if session then session:Destroy() end
        if budgetRawConnection then budgetRawConnection:Disconnect() end
        budgetFailure, budgetPulseValues, budgetQueueValues, budgetStateValues = nil, {}, {}, {}
        budgetRawFrames, budgetRpcFrames, budgetOtherFrames = {}, {}, {}
        session = assert(Relay.createClient(CompactTransport.createBudget(argument, true), {
            startupTimeoutSeconds = 10,
        }))
        assert(session.events.Pulse:Connect(function(value)
            if type(value) ~= "boolean" then budgetFailure = "outbound Pulse retained strict boolean type" end
            table.insert(budgetPulseValues, value)
        end))
        assert(session.events.QueueOutput:Connect(function(value)
            if value ~= true then budgetFailure = "outbound Batch delivered value" end
            table.insert(budgetQueueValues, value)
        end))
        assert(session.events.StateOutput:Connect(function(value)
            if value ~= true then budgetFailure = "outbound State delivered value" end
            table.insert(budgetStateValues, value)
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "outbound-budget client session start failed")
        return true
    elseif command == "budget-arm" then
        if budgetRawConnection then budgetRawConnection:Disconnect() end
        budgetRawFrames, budgetRpcFrames, budgetOtherFrames = {}, {}, {}
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        budgetRawConnection = root.Reliable.OnClientEvent:Connect(function(endpoint, ...)
            local packet = ...
            local argumentCount = select("#", ...)
            if endpoint == 1 then
                table.insert(budgetRawFrames, { endpoint = endpoint, argumentCount = argumentCount, value = packet })
            elseif endpoint == 0 then
                local rpc = CompactTransport.rpcRawReceipt(packet)
                if rpc ~= nil then
                    table.insert(budgetRpcFrames, rpc)
                elseif argumentCount ~= 1 or ReadinessFrame.peek(packet, false, 3) == nil then
                    table.insert(budgetOtherFrames, { endpoint = endpoint, argumentCount = argumentCount })
                end
            else
                table.insert(budgetOtherFrames, { endpoint = endpoint, argumentCount = argumentCount })
            end
        end)
        return true
    elseif command == "budget-rpc" then
        local pending, problem = session.requests.Echo:Request(5, true)
        assert(pending ~= nil, problem and problem.code or "outbound-budget RPC request failed")
        local result = pending:Await()
        return { ok = result.ok, error = if result.error == nil then nil else result.error.code }
    elseif command == "budget-read" then
        local deadline = os.clock() + 5
        if argument == "fanout" then
            repeat task.wait(0.03) until #budgetPulseValues >= 2 and #budgetRawFrames >= 2
                or os.clock() >= deadline
        elseif argument == "rpc" then
            repeat task.wait(0.03) until #budgetRpcFrames >= 1 or os.clock() >= deadline
        elseif argument == "queue" then
            task.wait(0.1)
        end
        if budgetFailure ~= nil then error(budgetFailure) end
        return { pulses = table.clone(budgetPulseValues), queues = table.clone(budgetQueueValues),
            states = table.clone(budgetStateValues), raw = table.clone(budgetRawFrames),
            rpcRaw = table.clone(budgetRpcFrames), other = table.clone(budgetOtherFrames) }
    elseif command == "budget-destroy" then
        if budgetRawConnection then budgetRawConnection:Disconnect() end
        budgetRawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "packed-start" then
        if session then session:Destroy() end
        if packedRawConnection then packedRawConnection:Disconnect() end
        packedReceived, packedFailure, packedRawFrames = { tuple = {}, arrays = {}, records = {} }, nil, {}
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        packedRawConnection = root.Reliable.OnClientEvent:Connect(function(endpoint, packet)
            local row = CompactTransport.packedRawReceipt(endpoint, packet)
            if row ~= nil and (row.eventId == 2 or row.eventId == 4 or row.eventId == 6) then
                table.insert(packedRawFrames, row)
            end
        end)
        session = assert(Relay.createClient(CompactTransport.createPacked(argument == true), {
            startupTimeoutSeconds = 10,
        }))
        assert(session.events.Output:Connect(function(...)
            local ok, result = pcall(CompactTransport.packedTupleObservation, ...)
            if not ok then packedFailure = tostring(result) return end
            table.insert(packedReceived.tuple, result)
        end))
        assert(session.events.ArrayOutput:Connect(function(...)
            local ok, result = pcall(CompactTransport.packedArrayObservation, ...)
            if not ok then packedFailure = tostring(result) return end
            table.insert(packedReceived.arrays, result)
        end))
        assert(session.events.StructOutput:Connect(function(value)
            local ok, result = pcall(CompactTransport.packedRecordObservation, value)
            if not ok then packedFailure = tostring(result) return end
            table.insert(packedReceived.records, result)
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "packed client session start failed")
        return true
    elseif command == "packed-send" then
        local function sendValidSet()
            assert(session.events.Input:Send(CompactTransport.packedTupleValues()))
            assert(session.events.ArrayInput:Send(CompactTransport.packedArrays()))
            assert(session.events.StructInput:Send(CompactTransport.packedRecord()))
        end
        sendValidSet()
        local reliable = ReplicatedStorage.RelayRemotes.Reliable
        reliable:FireServer(1, CompactTransport.packedPaddingMask())
        reliable:FireServer(1, CompactTransport.packedUnusedEnum())
        reliable:FireServer(1, CompactTransport.packedAbsentValueBits())
        reliable:FireServer(1, CompactTransport.packedTruncated())
        reliable:FireServer(3, CompactTransport.packedArrayPadding())
        reliable:FireServer(3, CompactTransport.packedArrayUnusedEnum())
        sendValidSet()
        reliable:FireServer(1, buffer.create(1))
        return true
    elseif command == "packed-read" then
        local deadline = os.clock() + 10
        repeat
            if packedFailure ~= nil then error(packedFailure) end
            if #packedReceived.tuple == 1 and #packedReceived.arrays == 1
                and #packedReceived.records == 1 and #packedRawFrames >= 3 then
                return { tuple = table.clone(packedReceived.tuple), arrays = table.clone(packedReceived.arrays),
                    records = table.clone(packedReceived.records), raw = table.clone(packedRawFrames),
                    failure = packedFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("packed flag/enum S2C receipt timeout")
    elseif command == "packed-destroy" then
        if packedRawConnection then packedRawConnection:Disconnect() end
        packedRawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "quantized-start" then
        if session then session:Destroy() end
        if quantizedRawConnection then quantizedRawConnection:Disconnect() end
        quantizedReceived, quantizedFailure, quantizedRawFrames = { grid = {}, wide = {} }, nil, {}
        local root = ReplicatedStorage:WaitForChild("RelayRemotes")
        quantizedRawConnection = root.Reliable.OnClientEvent:Connect(function(endpoint, packet)
            local row = QuantizedValues.rawReceipt(endpoint, packet)
            if row ~= nil and (row.eventId == 2 or row.eventId == 4) then
                table.insert(quantizedRawFrames, row)
            end
        end)
        session = assert(Relay.createClient(QuantizedValues.create(argument == true), { startupTimeoutSeconds = 10 }))
        assert(session.events.Output:Connect(function(...)
            local ok, value = pcall(QuantizedValues.checkGrid, ...)
            if not ok then quantizedFailure = tostring(value) return end
            table.insert(quantizedReceived.grid, value)
        end))
        assert(session.events.WideOutput:Connect(function(value)
            if value ~= 256 then quantizedFailure = "quantized u16 S2C value" return end
            table.insert(quantizedReceived.wide, value)
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "quantized client session start failed")
        return { numeric = QuantizedValues.numericProbes() }
    elseif command == "quantized-send" then
        assert(session.events.Input:Send(QuantizedValues.gridValues()))
        local reliable = ReplicatedStorage.RelayRemotes.Reliable
        reliable:FireServer(3, QuantizedValues.malformedUnusedCode())
        reliable:FireServer(3, QuantizedValues.truncatedWideCode())
        assert(session.events.WideInput:Send(256))
        assert(session.events.WideInput:Send(0))
        return true
    elseif command == "quantized-read" then
        local deadline = os.clock() + 10
        repeat
            if quantizedFailure ~= nil then error(quantizedFailure) end
            if #quantizedReceived.grid == 1 and #quantizedReceived.wide == 1 then
                return { grid = table.clone(quantizedReceived.grid), wide = table.clone(quantizedReceived.wide),
                    raw = table.clone(quantizedRawFrames), failure = quantizedFailure }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("quantized immediate S2C receipt timeout")
    elseif command == "quantized-route-start" then
        if session then session:Destroy() end
        quantizedFailure, quantizedQueueValue = nil, nil
        session = assert(Relay.createClient(QuantizedValues.create(true), { startupTimeoutSeconds = 10 }))
        assert(session.events.QueueOutput:Connect(function(value)
            if value ~= 0.5 then quantizedFailure = "quantized FIFO S2C value" return end
            quantizedQueueValue = value
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "quantized route client session start failed")
        return true
    elseif command == "quantized-route-send" then
        local pending, failure = session.requests.Echo:Request(5, 0.25)
        assert(pending ~= nil, failure and failure.code or "quantized RPC request failed")
        local result = pending:Await()
        assert(result.ok and result.value == 0.5, "quantized RPC response value")
        local batch, batchFailure = session:CreateBatch(0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message or "quantized FIFO batch creation failed")
        assert(batch.events.QueueInput:Send(0.25))
        local ok, flushFailure, report = batch:Flush()
        assert(ok and report.selected == 1 and report.reliableHandoffs == 1
            and report.logicalHandoffs == 1, flushFailure and flushFailure.code or "quantized FIFO batch flush failed")
        return { response = result.value, queueReport = report }
    elseif command == "quantized-route-read" then
        local deadline = os.clock() + 10
        repeat
            if quantizedFailure ~= nil then error(quantizedFailure) end
            if quantizedQueueValue ~= nil then return quantizedQueueValue end
            task.wait(0.03)
        until os.clock() >= deadline
        error("quantized FIFO S2C receipt timeout")
    elseif command == "quantized-destroy" then
        if quantizedRawConnection then quantizedRawConnection:Disconnect() end
        quantizedRawConnection = nil
        if session then session:Destroy() end
        return true
    elseif command == "tagged-start" then
        if session then session:Destroy() end
        session = assert(Relay.createClient(Fixture.createTaggedUnion(), { startupTimeoutSeconds = 10 }))
        taggedUnionReceived, taggedUnionFailure = {}, nil
        assert(session.events.Output:Connect(function(value)
            local ok, observation = pcall(Fixture.checkTagged, value)
            if not ok then taggedUnionFailure = tostring(observation) return end
            table.insert(taggedUnionReceived, observation)
        end))
        assert(session:Start())
        return true
    elseif command == "tagged-send" then
        assert(session.events.Input:Send(Fixture.taggedSuccess(nil, 257)))
        assert(session.events.Input:Send(Fixture.taggedSuccess("ready", 258)))
        assert(session.events.Input:Send(Fixture.taggedFailure()))
        local responses = {}
        for _, value in { Fixture.taggedSuccess("ready", 258), Fixture.taggedFailure() } do
            local pending = assert(session.requests.Echo:Request(5, value))
            local result = pending:Await()
            assert(result.ok, "native tagged-union RPC response")
            table.insert(responses, Fixture.checkTagged(result.value))
        end
        return responses
    elseif command == "tagged-read" then
        local deadline = os.clock() + 10
        repeat
            if taggedUnionFailure ~= nil then error(taggedUnionFailure) end
            if #taggedUnionReceived == 2 then return table.clone(taggedUnionReceived) end
            task.wait(0.03)
        until os.clock() >= deadline
        error("native tagged-union output timeout")
    elseif command == "tagged-admission-send" then
        assert(session.events.Input:Send(Fixture.taggedSuccess(nil, 257)))
        assert(session.events.Input:Send(Fixture.taggedFailure()))
        local unknownOrdinal = buffer.create(6)
        buffer.writeu8(unknownOrdinal, 0, 1)
        buffer.writeu16(unknownOrdinal, 1, 1)
        buffer.writeu8(unknownOrdinal, 3, 2)
        buffer.writeu16(unknownOrdinal, 4, 0)
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(1, unknownOrdinal)
        local truncatedFailure = buffer.create(6)
        buffer.writeu8(truncatedFailure, 0, 1)
        buffer.writeu16(truncatedFailure, 1, 1)
        buffer.writeu8(truncatedFailure, 3, 0)
        buffer.writeu16(truncatedFailure, 4, 4)
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(1, truncatedFailure)
        assert(session.events.Input:Send(Fixture.taggedSuccess("ready", 258)))
        return true
    elseif command == "tagged-destroy" then
        session:Destroy()
        session:Destroy()
        local ok, failure = session.events.Input:Send(Fixture.taggedSuccess(nil, 257))
        assert(not ok and failure.code == "Destroyed", "destroyed tagged-union client")
        return true
    elseif command == "readiness64-prepare" then
        if session then session:Destroy() end
        table.clear(readiness64Connections)
        table.clear(readiness64Deliveries)
        readiness64Failure = nil
        readiness64Prepared = nil
        local created, createFailure = Relay.createClient(Fixture.createReadiness64(), { startupTimeoutSeconds = 10 })
        assert(created ~= nil, createFailure and createFailure.message or "64-endpoint client creation failed")
        session = created
        for eventId = 1, 63 do
            readiness64Connections[eventId] = connectReadiness64(eventId, string.format("E%02d", eventId))
        end
        readiness64Connections[64] = connectReadiness64(65535, "Highest")
        readiness64Prepared = { listenerCount = 64, highestId = 65535 }
        return table.clone(readiness64Prepared)
    elseif command == "readiness64-start" then
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "64-endpoint client start failed")
        return true
    elseif command == "readiness64-malformed" then
        assert(typeof(argument) == "buffer" and buffer.len(argument) == 90
            and buffer.readu8(argument, 1) == 18, "server did not provide the observed full Ack")
        local short = buffer.create(89)
        buffer.copy(short, 0, argument, 0, 89)
        local long = buffer.create(91)
        buffer.copy(long, 0, argument, 0, 90)
        buffer.writeu8(long, 90, 0)
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(0, short)
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(0, long)
        return { short = buffer.len(short), long = buffer.len(long) }
    elseif command == "readiness64-disconnect-high" then
        readiness64Connections[64]:Disconnect()
        readiness64Connections[64] = nil
        return true
    elseif command == "readiness64-refresh" then
        local ok, failure = session:RefreshReadiness()
        return { sent = ok, error = failure and failure.code }
    elseif command == "readiness64-reconnect-high" then
        readiness64Connections[64] = connectReadiness64(65535, "Highest")
        return true
    elseif command == "readiness64-read" then
        return {
            prepared = table.clone(readiness64Prepared or {}),
            failure = readiness64Failure,
            deliveries = table.clone(readiness64Deliveries),
        }
    elseif command == "readiness64-destroy" then
        if session then session:Destroy() end
        return true
    elseif command == "queued-prepare" then
        if session then session:Destroy() end
        queuedReceived = { reliable = {}, unreliable = {}, once = {}, reusable = {} }
        queuedPushConnection = nil
        local created, createFailure = Relay.createClient(Fixture.createQueued(), { startupTimeoutSeconds = 10 })
        assert(created ~= nil, createFailure and createFailure.message or "queued client session creation failed")
        session = created
        cancellationThread, cancellationEntered, cancellationContinued, cancellationReplacementCalls = nil, 0, 0, 0
        connectQueuedListeners(argument == game:GetService("Players").LocalPlayer.UserId)
        return true
    elseif command == "queued-start" then
        local ok, failure = session:Start()
        assert(ok, failure and failure.code)
        return true
    elseif command == "queued-send-normal" then
        local batch, batchFailure = session:CreateBatch(0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message or "queued client batch creation failed")
        assert(batch.events.QueueInput:Send(1))
        assert(batch.events.QueueInput:Send(2))
        assert(batch.events.UnreliableQueueInput:Send(1))
        local ok, failure, report = batch:Flush()
        assert(ok, failure and failure.code)
        assert(report.selected == 3 and report.reliableHandoffs == 1 and report.unreliableHandoffs == 1
            and report.logicalHandoffs == 3, "native batch sends one bounded frame per channel")
        return report
    elseif command == "queued-reusable-batcher" then
        local batcher, batchFailure = session:CreateBatcher(0.03)
        assert(batcher ~= nil, batchFailure and batchFailure.message or "reusable client batcher creation failed")
        local input = batcher.events.ReusableInput
        local firstObservation = #queuedReceived.reusable + 1

        assert(input:Send(false))
        local manualOk, manualFailure, manualReport = batcher:Flush()
        assert(manualOk, manualFailure and manualFailure.code or "reusable client manual flush failed")
        local deadline = os.clock() + 5
        repeat task.wait(0.03) until #queuedReceived.reusable >= firstObservation or os.clock() >= deadline
        assert(queuedReceived.reusable[firstObservation] == false,
            "reusable client manual window reached the existing handler")
        local manualStatus = batcher:GetStatus()
        assert(manualStatus.state == "Open" and manualStatus.pendingRecords == 0,
            "reusable client manual flush reopens an empty window")

        assert(input:Send(true))
        deadline = os.clock() + 5
        repeat task.wait(0.03) until #queuedReceived.reusable >= firstObservation + 1 or os.clock() >= deadline
        assert(queuedReceived.reusable[firstObservation + 1] == true,
            "reusable client timer window reached the existing handler")
        local automaticStatus = batcher:GetStatus()
        assert(automaticStatus.state == "Open" and automaticStatus.pendingRecords == 0,
            "reusable client timer flush reopens an empty window")
        local sameEventHandle = batcher.events.ReusableInput == input
        batcher:Cancel()
        local cleanup = batcher:GetStatus()
        local sendAfterCancel = input:Send(false)
        assert(cleanup.state == "Terminal" and cleanup.pendingRecords == 0 and not sendAfterCancel,
            "reusable client Cancel is terminal and releases queued records")
        local replacement, replacementFailure = session:CreateBatch(0.03)
        assert(replacement ~= nil, replacementFailure and replacementFailure.message or "reusable client batch slot was retained")
        replacement:Cancel()
        local released = replacement:GetStatus()
        return {
            client = Players.LocalPlayer.UserId,
            sameEventHandle = sameEventHandle,
            manualReport = manualReport,
            manualStatus = manualStatus,
            automaticStatus = automaticStatus,
            cleanup = cleanup,
            sendAfterCancel = sendAfterCancel,
            slotReleased = released.state == "Terminal" and released.pendingRecords == 0,
        }
    elseif command == "queued-send-yield" then
        local batch, batchFailure = session:CreateBatch(0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message or "queued client batch creation failed")
        assert(batch.events.QueueInput:Send(3))
        assert(batch.events.QueueInput:Send(4))
        assert(batch.events.IndependentInput:Send(5))
        local ok, failure, report = batch:Flush()
        assert(ok, failure and failure.code)
        assert(report.selected == 3 and report.reliableHandoffs == 1 and report.logicalHandoffs == 3)
        return report
    elseif command == "queued-hostile-protocol" then
        local reliable = ReplicatedStorage.RelayRemotes.Reliable
        local unknownKind = queuedEnvelope(1, { queuedBody(1, 70) })
        buffer.writeu8(unknownKind, 1, 9)
        reliable:FireServer(0, unknownKind)
        reliable:FireServer(0, queuedEnvelope(1, { queuedBody(15, 70) }))
        reliable:FireServer(0, queuedEnvelope(1, { queuedBody(7, 70) }))
        reliable:FireServer(0, queuedEnvelope(1, { queuedBody(2, 70) }))
        reliable:FireServer(0, queuedEnvelope(2, { queuedBody(1, 70) }))
        reliable:FireServer(0, queuedEnvelope(1, { queuedBody(5, 71) }))
        reliable:FireServer(0, queuedEnvelope(2, { queuedBody(5, 72) }))
        return true
    elseif command == "queued-read" then
        return {
            reliable = table.clone(queuedReceived.reliable),
            unreliable = table.clone(queuedReceived.unreliable),
            once = table.clone(queuedReceived.once),
            reusable = table.clone(queuedReceived.reusable),
        }
    elseif command == "queued-reusable-reset" then
        table.clear(queuedReceived.reusable)
        return true
    elseif command == "queued-readiness-disconnect" then
        queuedPushConnection:Disconnect()
        queuedPushConnection = nil
        return true
    elseif command == "queued-readiness-connect" then
        queuedPushConnection = assert(session.events.QueuePush:Connect(function(value)
            table.insert(queuedReceived.reliable, value)
        end))
        return true
    elseif command == "queued-once-reconnect" then
        assert(session.events.OncePush:Connect(function(value)
            table.insert(queuedReceived.once, value)
        end))
        return true
    elseif command == "queued-refresh-readiness" then
        local nilOk, nilFailure = session:RefreshReadiness()
        local falseOk, falseFailure = session:RefreshReadiness(false)
        local trueOk, trueFailure = session:RefreshReadiness(true)
        return {
            nilOk = nilOk, nilError = nilFailure and nilFailure.code,
            falseOk = falseOk, falseError = falseFailure and falseFailure.code,
            trueOk = trueOk, trueError = trueFailure and trueFailure.code,
        }
    elseif command == "queued-send-immediate" then
        local ok, failure = session.events.ImmediateInput:Send(argument)
        return { ok = ok, error = failure and failure.code }
    elseif command == "cancel-queued-send" then
        local batch, problem = session:CreateBatch(0.05)
        assert(batch ~= nil, problem and problem.message or "cancellation FIFO batch creation failed")
        assert(batch.events.QueueInput:Send(argument))
        local ok, failure, report = batch:Flush()
        assert(ok, failure and failure.code)
        return report
    elseif command == "endpoint-queued-burst" then
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(0, queuedEnvelope(argument.kind, {
            queuedBody(argument.id, 81), queuedBody(argument.id, 82),
        }))
    elseif command == "endpoint-queued-immediate" then
        local event = if argument == 1 then session.events.QueueInput else session.events.StateInput
        assert(event:Send(83))
    elseif command == "queued-malformed-final" then
        local bodies = table.create(7)
        for index = 1, 6 do bodies[index] = queuedBody(1, 30 + index) end
        bodies[7] = queuedBody(4, 2)
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(0, queuedEnvelope(1, bodies))
        return true
    elseif command == "queued-send-healthy" then
        local batch, batchFailure = session:CreateBatch(0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message or "queued client batch creation failed")
        assert(batch.events.QueueInput:Send(41))
        assert(batch.events.QueueInput:Send(42))
        local ok, failure, report = batch:Flush()
        assert(ok, failure and failure.code)
        assert(report.selected == 2 and report.reliableHandoffs == 1 and report.logicalHandoffs == 2)
        return report
    elseif command == "start" or command == "mismatch" then
        if session then session:Destroy() end
        table.clear(received)
        table.clear(schemaReceived)
        table.clear(compositeReceived)
        table.clear(unreliableReceived)
        table.clear(unreliableCompositeReceived)
        unreliableFailure = nil
        compositeFailure = nil
        poseResult = Fixture.poseRecord()
        if poseObserver then poseObserver:Disconnect() poseObserver = nil end
        entered = 0
        handlerMode = "normal"
        release = false
        session = assert(Relay.createClient(Fixture.create(if command == "mismatch" then 2 else 1), {
            startupTimeoutSeconds = 10,
        }))
        cancellationThread, cancellationEntered, cancellationContinued, cancellationReplacementCalls = nil, 0, 0, 0
        listen(false, command == "start" and argument == game:GetService("Players").LocalPlayer.UserId)
        assert(session.events.SchemaState:Connect(function(...)
            table.insert(schemaReceived, Fixture.checkSchema(...))
        end))
        assert(session.events.CompositeState:Connect(function(...)
            recordComposed(compositeReceived, ...)
        end))
        assert(session.events.UnreliableState:Connect(function(sampleId, value, enabled, ...)
            local ok, checkedId, checkedValue, checkedEnabled = pcall(Fixture.checkUnreliable, sampleId, value, enabled, ...)
            if not ok then unreliableFailure = tostring(checkedId) return end
            if checkedId <= Fixture.unreliableSampleCount then
                unreliableFailure = "S2C unreliable sample ID outside its range"
                return
            end
            unreliableReceived[checkedId] = { sampleId = checkedId, value = checkedValue, enabled = checkedEnabled }
        end))
        assert(session.events.UnreliableCompositeState:Connect(function(...)
            recordComposed(unreliableCompositeReceived, ...)
        end))
        assert(session.events.PoseState:Connect(function(index, ...)
            Fixture.recordPose(poseResult, "delivery", index, ...)
        end))
        local ok, failure = session:Start()
        if command == "mismatch" then
            assert(not ok and failure.code == "DefinitionMismatch", "descriptor mismatch")
            local snapshot = session:GetDiagnostics()
            local startFailure = assert(snapshot.lastStartFailure, "native startup failure record")
            local comparison = assert(startFailure.descriptorMismatch, "native descriptor comparison")
            assert(startFailure.stage == "DescriptorVerification" and startFailure.code == failure.code,
                "native descriptor mismatch stage")
            local expectedBytes = assert(Relay.inspect(Fixture.create(2))).descriptorBytes
            local observedBytes = #ReplicatedStorage.RelayRemotes.Definition.Value
            assert(comparison.expectedBytes == expectedBytes
                and comparison.observedBytes == math.min(observedBytes, expectedBytes + 1)
                and comparison.observedBytesCapped == (observedBytes > expectedBytes + 1)
                and comparison.firstDifferenceByte >= 1 and comparison.firstDifferenceByte <= expectedBytes + 1,
                "native bounded descriptor facts")
            assert(table.isfrozen(snapshot) and table.isfrozen(startFailure) and table.isfrozen(comparison),
                "native immutable startup failure")
            assert(ReplicatedStorage:FindFirstChild("RelayClientSession_RelayRemotes") == nil,
                "native mismatch releases client marker")
            session:Destroy()
            assert(session:GetDiagnostics().lastStartFailure == nil and snapshot.lastStartFailure == startFailure,
                "native Destroy clears current failure without changing old snapshot")
        else
            assert(ok, failure and failure.code)
            assert(session:GetDiagnostics().lastStartFailure == nil, "native successful startup clears failure")
            assert(ReplicatedStorage.RelayRemotes.Unreliable.ClassName == "UnreliableRemoteEvent",
                "native unreliable remote class")
        end
    elseif command == "schema-send" then
        assert(session.events.SchemaInput:Send(Fixture.schemaValues(false)))
        assert(session.events.SchemaInput:Send(Fixture.schemaValues(true)))
        local ok, failure = session.events.SchemaInput:Send(false, -129, -32_768, -2_147_483_648, Vector2.zero, "", CFrame.new())
        assert(not ok and failure.code == "InvalidPayload", "signed send overflow")
        ok, failure = session.events.SchemaInput:Send(false, -128, -32_768, -2_147_483_648, Vector2.zero, "", CFrame.new(), nil)
        assert(not ok and failure.code == "InvalidPayload", "signed send trailing nil")
    elseif command == "broadcast-start" then
        table.clear(broadcastBatchingReliableValues)
        table.clear(broadcastBatchingUnreliableValues)
        table.clear(broadcastBatchingRawFrames.Reliable)
        table.clear(broadcastBatchingRawFrames.Unreliable)
        table.clear(broadcastStateReliableValues)
        table.clear(broadcastStateUnreliableValues)
        table.clear(broadcastStateRawFrames.Reliable)
        table.clear(broadcastStateRawFrames.Unreliable)
        table.clear(broadcastBatchingHostileRawFrames.Reliable)
        broadcastBatchingHostileCapture = false
        table.clear(broadcastBatchingConnections)
        table.clear(broadcastBatchingRawConnections)
        broadcastBatchingFailure = nil
        broadcastBatchingSession = assert(Relay.createClient(BroadcastBatching.create(), { startupTimeoutSeconds = 10 }))
        local _, expectedPart, expectedFolder = BroadcastBatching.scope()
        local reliableConnection = assert(broadcastBatchingSession.events.ReliableOutput:Connect(function(enabled, part, folder)
            if type(enabled) ~= "boolean" or part ~= expectedPart or folder ~= expectedFolder then
                broadcastBatchingFailure = "shared reliable broadcast values or Instance identity"
                return
            end
            table.insert(broadcastBatchingReliableValues, {
                enabled = enabled,
                part = part:GetFullName(),
                folder = folder:GetFullName(),
            })
        end))
        local unreliableConnection = assert(broadcastBatchingSession.events.UnreliableOutput:Connect(function(sequence, enabled)
            if type(sequence) ~= "number" or (sequence ~= 7 and sequence ~= 255) or type(enabled) ~= "boolean" then
                broadcastBatchingFailure = "shared unreliable broadcast value outside its schema bounds"
                return
            end
            table.insert(broadcastBatchingUnreliableValues, { sequence = sequence, enabled = enabled })
        end))
        local stateReliableConnection = assert(broadcastBatchingSession.events.ReliableState:Connect(function(marker, message, part, folder)
            if type(marker) ~= "number" or type(message) ~= "string" or part ~= expectedPart or folder ~= expectedFolder then
                broadcastBatchingFailure = "shared State broadcast values or Instance identity"
                return
            end
            table.insert(broadcastStateReliableValues, {
                marker = marker,
                message = message,
                part = part:GetFullName(),
                folder = folder:GetFullName(),
            })
        end))
        local stateUnreliableConnection = assert(broadcastBatchingSession.events.UnreliableState:Connect(function(sequence, enabled)
            if sequence ~= 7 or enabled ~= false then
                broadcastBatchingFailure = "shared unreliable State values outside their schema bounds"
                return
            end
            table.insert(broadcastStateUnreliableValues, { sequence = sequence, enabled = enabled })
        end))
        table.insert(broadcastBatchingConnections, reliableConnection)
        table.insert(broadcastBatchingConnections, unreliableConnection)
        table.insert(broadcastBatchingConnections, stateReliableConnection)
        table.insert(broadcastBatchingConnections, stateUnreliableConnection)
        local started, startFailure = broadcastBatchingSession:Start()
        assert(started, startFailure and startFailure.code or "shared broadcast client start")
        local remotes = ReplicatedStorage:WaitForChild("RelayRemotes")
        local reliableRaw = remotes.Reliable.OnClientEvent:Connect(function(endpoint, packet, ...)
            recordBroadcastBatchingRaw("Reliable", endpoint, packet, ...)
        end)
        local unreliableRaw = remotes.Unreliable.OnClientEvent:Connect(function(endpoint, packet, ...)
            recordBroadcastBatchingRaw("Unreliable", endpoint, packet, ...)
        end)
        table.insert(broadcastBatchingRawConnections, reliableRaw)
        table.insert(broadcastBatchingRawConnections, unreliableRaw)
        return true
    elseif command == "broadcast-snapshot" then
        assert(broadcastBatchingFailure == nil, broadcastBatchingFailure)
        return broadcastBatchingSnapshot()
    elseif command == "broadcast-read" then
        local deadline = os.clock() + 15
        repeat
            if broadcastBatchingFailure ~= nil then error(broadcastBatchingFailure) end
            local unreliableSettled = #broadcastBatchingRawFrames.Unreliable == 0
                or #broadcastBatchingUnreliableValues >= 2
            if #broadcastBatchingReliableValues >= 3 and #broadcastBatchingRawFrames.Reliable >= 2
                and unreliableSettled then
                return broadcastBatchingSnapshot()
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("shared broadcast native reliable frames timeout")
    elseif command == "broadcast-state-snapshot" then
        assert(broadcastBatchingFailure == nil, broadcastBatchingFailure)
        return broadcastStateSnapshot()
    elseif command == "broadcast-state-read" then
        local expected = argument or {}
        local deadline = os.clock() + 10
        repeat
            if broadcastBatchingFailure ~= nil then error(broadcastBatchingFailure) end
            if #broadcastStateReliableValues >= (expected.reliable or 0)
                and #broadcastStateRawFrames.Reliable >= (expected.reliableRaw or 0) then
                task.wait(0.1)
                if #broadcastStateRawFrames.Unreliable == 0
                    or #broadcastStateUnreliableValues >= #broadcastStateRawFrames.Unreliable then
                    return broadcastStateSnapshot()
                end
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("shared broadcast State native receipt timeout")
    elseif command == "broadcast-state-hostile-start" then
        assert(broadcastBatchingSession ~= nil and broadcastBatchingFailure == nil,
            "shared malformed State broadcast active client")
        table.clear(broadcastBatchingHostileRawFrames.Reliable)
        broadcastBatchingHostileCapture = true
        local diagnostics = broadcastBatchingSession:GetDiagnostics()
        return {
            invalidPayload = diagnostics.counters.invalidPayload,
            reliableCallbacks = #broadcastStateReliableValues,
        }
    elseif command == "broadcast-state-hostile-read" then
        local deadline = os.clock() + 15
        repeat
            if broadcastBatchingFailure ~= nil then error(broadcastBatchingFailure) end
            local diagnostics = broadcastBatchingSession:GetDiagnostics()
            if #broadcastBatchingHostileRawFrames.Reliable >= 1
                and diagnostics.counters.invalidPayload > argument.invalidPayload then
                return {
                    invalidPayload = diagnostics.counters.invalidPayload,
                    reliableCallbacks = #broadcastStateReliableValues,
                    frames = table.clone(broadcastBatchingHostileRawFrames.Reliable),
                    failure = broadcastBatchingFailure,
                }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("shared malformed State broadcast rejection receipt timeout")
    elseif command == "broadcast-state-hostile-stop" then
        broadcastBatchingHostileCapture = false
        return true
    elseif command == "broadcast-hostile-start" then
        assert(broadcastBatchingSession ~= nil and broadcastBatchingFailure == nil,
            "shared malformed broadcast active client")
        table.clear(broadcastBatchingHostileRawFrames.Reliable)
        broadcastBatchingHostileCapture = true
        local diagnostics = broadcastBatchingSession:GetDiagnostics()
        return {
            invalidPayload = diagnostics.counters.invalidPayload,
            reliableCallbacks = #broadcastBatchingReliableValues,
        }
    elseif command == "broadcast-hostile-read" then
        local deadline = os.clock() + 15
        repeat
            if broadcastBatchingFailure ~= nil then error(broadcastBatchingFailure) end
            local diagnostics = broadcastBatchingSession:GetDiagnostics()
            if #broadcastBatchingHostileRawFrames.Reliable >= 1
                and diagnostics.counters.invalidPayload > argument.invalidPayload then
                return {
                    invalidPayload = diagnostics.counters.invalidPayload,
                    reliableCallbacks = #broadcastBatchingReliableValues,
                    frames = table.clone(broadcastBatchingHostileRawFrames.Reliable),
                    failure = broadcastBatchingFailure,
                }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("shared malformed broadcast rejection receipt timeout")
    elseif command == "broadcast-hostile-stop" then
        broadcastBatchingHostileCapture = false
        return true
    elseif command == "broadcast-recovery-read" then
        local deadline = os.clock() + 15
        repeat
            if broadcastBatchingFailure ~= nil then error(broadcastBatchingFailure) end
            local unreliableSettled = #broadcastBatchingRawFrames.Unreliable == 0
                or #broadcastBatchingUnreliableValues >= 2
            if #broadcastBatchingReliableValues >= 4 and #broadcastBatchingRawFrames.Reliable >= 3
                and unreliableSettled then
                return broadcastBatchingSnapshot()
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("shared valid recovery broadcast receipt timeout")
    elseif command == "broadcast-destroy" then
        broadcastBatchingHostileCapture = false
        for _, item in broadcastBatchingRawConnections do item:Disconnect() end
        for _, item in broadcastBatchingConnections do item:Disconnect() end
        table.clear(broadcastBatchingRawConnections)
        table.clear(broadcastBatchingConnections)
        if broadcastBatchingSession then broadcastBatchingSession:Destroy() end
        broadcastBatchingSession = nil
        return true
    elseif command == "rpc-bounded-start" then
        if session then session:Destroy() end
        for _, item in rpcBoundedRawConnections do item:Disconnect() end
        for _, item in rpcBoundedConnections do item:Disconnect() end
        table.clear(rpcBoundedRawConnections)
        table.clear(rpcBoundedConnections)
        table.clear(rpcBoundedRouteReceipts)
        table.clear(rpcBoundedClientCallResults)
        table.clear(rpcBoundedRawFrames.Reliable)
        table.clear(rpcBoundedRawFrames.Unreliable)
        table.clear(rpcBoundedScalars)
        rpcBoundedClientCallActive, rpcBoundedClientCallMax = 0, 0
        rpcBoundedClientCallRelease = false
        rpcBoundedFailure, rpcBoundedPending = nil, nil
        session = assert(Relay.createClient(RpcBoundedRoutes.create(), { startupTimeoutSeconds = 10 }))
        for _, name in { "Output", "UnreliableOutput", "OrderedOutput", "QueueOutput",
            "UnreliableQueueOutput", "StateOutput" } do
            local connection = assert(session.events[name]:Connect(function(...)
                recordRpcBoundedReferences(name, ...)
            end))
            table.insert(rpcBoundedConnections, connection)
        end
        assert(session.events.NumericOutput:Connect(function(...)
            local ok, value = pcall(RpcBoundedRoutes.checkNumeric, ...)
            if not ok then rpcBoundedFailure = tostring(value) return end
            rpcBoundedScalars.NumericOutput = value
        end))
        assert(session.events.BoundedOutput:Connect(function(value)
            local ok, receipt = pcall(RpcBoundedRoutes.checkBounded, value)
            if not ok then rpcBoundedFailure = tostring(receipt) return end
            rpcBoundedScalars.BoundedOutput = receipt
        end))
        assert(session.events.LegacyOutput:Connect(function(value)
            rpcBoundedScalars.LegacyOutput = value
        end))
        assert(session.events.LegacyQueueOutput:Connect(function(value)
            rpcBoundedScalars.LegacyQueueOutput = value
        end))
        assert(session.requests.ClientCall:Connect(function(reference, returnNil, returnMissing, hold)
            local expectedPart = RpcBoundedRoutes.objects(Players.LocalPlayer)
            if reference ~= expectedPart then rpcBoundedFailure = "S2C RPC request Instance identity" end
            rpcBoundedClientCallActive += 1
            rpcBoundedClientCallMax = math.max(rpcBoundedClientCallMax, rpcBoundedClientCallActive)
            local concurrentActive = rpcBoundedClientCallActive
            if hold then
                repeat task.wait() until rpcBoundedClientCallRelease
            else
                task.wait(0.15)
            end
            rpcBoundedClientCallActive -= 1
            table.insert(rpcBoundedClientCallResults, {
                returnNil = returnNil,
                returnMissing = returnMissing,
                hold = hold,
                concurrentActive = concurrentActive,
                part = if typeof(reference) == "Instance" then reference:GetFullName() else "missing",
            })
            local responsePart = reference
            if returnMissing then
                responsePart = Instance.new("Part")
                responsePart.Name = "RelayProofClientOnlyRpcResponse"
                responsePart.Parent = workspace
                task.delay(1, function()
                    if responsePart.Parent ~= nil then responsePart:Destroy() end
                end)
            end
            return { part = responsePart, status = if returnNil then nil else false }
        end))
        local ok, failure = session:Start()
        assert(ok, failure and failure.code or "RPC/bounded native client start")
        local remotes = ReplicatedStorage:WaitForChild("RelayRemotes")
        table.insert(rpcBoundedRawConnections, remotes.Reliable.OnClientEvent:Connect(function(endpoint, packet, ...)
            recordRpcBoundedRaw("Reliable", endpoint, packet, ...)
        end))
        table.insert(rpcBoundedRawConnections, remotes.Unreliable.OnClientEvent:Connect(function(endpoint, packet, ...)
            recordRpcBoundedRaw("Unreliable", endpoint, packet, ...)
        end))
        return true
    elseif command == "rpc-bounded-send-events" then
        local part, folder = RpcBoundedRoutes.objects(Players.LocalPlayer)
        local references = { part, part, folder }
        for _, name in { "Input", "UnreliableInput", "OrderedInput" } do
            assert(session.events[name]:Send(table.unpack(references)), "native reference route send " .. name)
        end
        local batch, batchFailure = session:CreateBatch(0.05)
        assert(batch ~= nil, batchFailure and batchFailure.message or "native reference batch creation")
        assert(batch.events.QueueInput:Send(table.unpack(references)))
        assert(batch.events.LegacyQueueInput:Send(42))
        assert(batch.events.UnreliableQueueInput:Send(table.unpack(references)))
        local batchOk, batchProblem, batchReport = batch:Flush()
        assert(batchOk, batchProblem and batchProblem.code or "native reference batch flush")
        assert(batchReport.selected == 3 and batchReport.reliableHandoffs == 1
            and batchReport.unreliableHandoffs == 1, "native mixed reference/legacy queue handoffs")
        local legacyBatch = assert(session:CreateBatch(0.05))
        assert(legacyBatch.events.LegacyQueueInput:Send(43))
        local legacyOk, legacyProblem, legacyReport = legacyBatch:Flush()
        assert(legacyOk, legacyProblem and legacyProblem.code)
        assert(legacyReport.selected == 1 and legacyReport.reliableHandoffs == 1,
            "native no-reference queue keeps one legacy frame")

        local state, stateFailure = session:CreateState(0.05)
        assert(state ~= nil, stateFailure and stateFailure.message or "native reference state creation")
        assert(state.events.StateInput:Put(1, "Normal", table.unpack(references)))
        local stateOk, stateProblem, stateReport = state:Flush()
        assert(stateOk, stateProblem and stateProblem.code or "native reference state flush")

        local numeric = table.pack(RpcBoundedRoutes.numericValues())
        assert(session.events.NumericInput:Send(table.unpack(numeric, 1, numeric.n)))
        assert(session.events.BoundedInput:Send(RpcBoundedRoutes.boundedValue()))
        assert(session.events.MinimumInput:Send("abc"))
        assert(session.events.LegacyInput:Send(41))

        local pending, problem = session.requests.Echo:Request(5, part)
        assert(pending ~= nil, problem and problem.code or "C2S Instance RPC request")
        local result = pending:Await()
        assert(result.ok and result.value == part and pending:Await() == result,
            "C2S Instance RPC response and cached Await")
        local legacy, legacyProblem = session.requests.LegacyRpc:Request(5, 42)
        assert(legacy ~= nil, legacyProblem and legacyProblem.code or "legacy RPC request in upgraded definition")
        local legacyResult = legacy:Await()
        assert(legacyResult.ok and legacyResult.value == 43, "legacy v1 RPC value")

        local beforeInvalid = session:GetDiagnostics().counters.sendHandoffs
        local invalidCount = 0
        local function reject(call, label)
            local sent, failure = call()
            assert(not sent and failure.code == "InvalidPayload", label .. " rejects before handoff")
            invalidCount += 1
        end
        local badNumeric = table.clone(numeric)
        badNumeric[1] = 16_777_216
        reject(function() return session.events.NumericInput:Send(table.unpack(badNumeric, 1, badNumeric.n)) end,
            "u24 overflow")
        local bad = RpcBoundedRoutes.boundedValue()
        bad.text = "ab"
        reject(function() return session.events.BoundedInput:Send(bad) end, "string below minimum")
        bad = RpcBoundedRoutes.boundedValue()
        bad.binary = buffer.create(1)
        reject(function() return session.events.BoundedInput:Send(bad) end, "buffer below minimum")
        bad = RpcBoundedRoutes.boundedValue()
        bad.exact = { 10 }
        reject(function() return session.events.BoundedInput:Send(bad) end, "exact array length")
        bad = RpcBoundedRoutes.boundedValue()
        bad.items = { 12 }
        reject(function() return session.events.BoundedInput:Send(bad) end, "array below minimum")
        bad = RpcBoundedRoutes.boundedValue()
        bad.members = { [1] = true }
        reject(function() return session.events.BoundedInput:Send(bad) end, "set below minimum")
        bad = RpcBoundedRoutes.boundedValue()
        bad.scores = { [1] = 0x010203 }
        reject(function() return session.events.BoundedInput:Send(bad) end, "map below minimum")
        reject(function() return session.events.MinimumInput:Send("ab") end, "string minimum")
        local wrongClass = Instance.new("Model")
        wrongClass.Parent = workspace
        reject(function() return session.events.Input:Send(wrongClass, part, folder) end, "Instance class")
        wrongClass:Destroy()
        assert(session:GetDiagnostics().counters.sendHandoffs == beforeInvalid,
            "invalid native bounded sends do not reach transport")
        return {
            invalidEncodes = invalidCount,
            echo = result.value:GetFullName(),
            legacyRpc = legacyResult.value,
            batch = batchReport,
            state = stateReport,
        }
    elseif command == "rpc-bounded-concurrency-start" then
        local first, firstProblem = session.requests.Concurrent:Request(10, true)
        local second, secondProblem = session.requests.Concurrent:Request(10, false)
        assert(first ~= nil and second ~= nil, (firstProblem or secondProblem) and (firstProblem or secondProblem).code)
        rpcBoundedPending = { first, second }
        return true
    elseif command == "rpc-bounded-concurrency-third" then
        local handoffsBeforeLimit = session:GetDiagnostics().counters.sendHandoffs
        local limited, limitProblem = session.requests.Concurrent:Request(5, true)
        local handoffsAfterLimit = session:GetDiagnostics().counters.sendHandoffs
        assert(limited == nil and limitProblem ~= nil and limitProblem.code == "RequestLimit",
            "C2S concurrent caller slot limit rejects locally")
        assert(handoffsAfterLimit == handoffsBeforeLimit,
            "C2S caller slot refusal does not hand off a native request")
        rpcBoundedPending[1]:Cancel()
        local cancelled = rpcBoundedPending[1]:Await()
        assert(not cancelled.ok and cancelled.error.code == "Cancelled",
            "cancelled C2S caller settles without releasing the handler")
        local pending, problem = session.requests.Concurrent:Request(5, true)
        assert(pending ~= nil, problem and problem.code or "bounded concurrency third request")
        local result = pending:Await()
        assert(not result.ok and result.error.code == "Busy", "client receives bounded Busy refusal")
        return { requestLimit = limitProblem.code, handoffsBeforeLimit = handoffsBeforeLimit,
            handoffsAfterLimit = handoffsAfterLimit, cancelled = cancelled.error.code, busy = result.error.code }
    elseif command == "rpc-bounded-concurrency-await" then
        assert(type(rpcBoundedPending) == "table", "pending concurrency calls missing")
        local first, second = rpcBoundedPending[1]:Await(), rpcBoundedPending[2]:Await()
        assert(not first.ok and first.error.code == "Cancelled" and second.ok and second.value == false,
            "cancelled and successful concurrent response ownership")
        local nilPending, nilProblem = session.requests.Concurrent:Request(5, true)
        assert(nilPending ~= nil, nilProblem and nilProblem.code or "post-release nil RPC request")
        local nilResult = nilPending:Await()
        assert(nilResult.ok and nilResult.value == nil, "C2S RPC preserves typed nil response")
        return { cancelled = first.error.code, nilValue = nilResult.value == nil,
            falseValue = second.value == false }
    elseif command == "rpc-bounded-hostile" then
        local reliable, unreliable = ReplicatedStorage.RelayRemotes.Reliable, ReplicatedStorage.RelayRemotes.Unreliable
        local part, folder = RpcBoundedRoutes.objects(Players.LocalPlayer)
        local outside = InstanceValues.objects(Players.LocalPlayer).part
        reliable:FireServer(17, RpcBoundedRoutes.malformedMinimumPacket())
        reliable:FireServer(1, RpcBoundedRoutes.malformedReferencePacket(1), part, part, folder)
        local sidecars = RpcBoundedRoutes.queueSidecars(Players.LocalPlayer)
        reliable:FireServer(0, RpcBoundedRoutes.malformedLateQueuePacket(1, 7), table.unpack(sidecars, 1, 6))
        unreliable:FireServer(0, RpcBoundedRoutes.malformedLateQueuePacket(1, 9), table.unpack(sidecars, 1, 6))
        assert(session.events.Input:Send(outside, outside, folder), "out-of-scope reliable Instance reaches server validation")
        assert(session.events.UnreliableInput:Send(outside, outside, folder),
            "out-of-scope unreliable Instance reaches server validation")
        assert(session.events.OrderedInput:Send(outside, outside, folder),
            "out-of-scope ordered Instance reaches server validation")
        reliable:FireServer(0, RpcBoundedRoutes.outOfScopeQueuePacket(1, 7), outside, outside, folder)
        unreliable:FireServer(0, RpcBoundedRoutes.outOfScopeQueuePacket(1, 9), outside, outside, folder)
        local missing = Instance.new("Part")
        missing.Name = "RelayRpcBoundedClientOnlyPart"
        missing.Parent = workspace
        assert(session.events.Input:Send(missing, part, folder), "client-only Instance submitted for nil-sidecar proof")
        task.wait(0.25)
        missing:Destroy()
        return true
    elseif command == "rpc-bounded-recovery" then
        local part, folder = RpcBoundedRoutes.objects(Players.LocalPlayer)
        local references = { part, part, folder }
        assert(session.events.Input:Send(table.unpack(references)))
        assert(session.events.UnreliableInput:Send(table.unpack(references)))
        assert(session.events.OrderedInput:Send(table.unpack(references)))
        local batch = assert(session:CreateBatch(0.05))
        assert(batch.events.QueueInput:Send(table.unpack(references)))
        local ok, failure = batch:Flush()
        assert(ok, failure and failure.code)
        assert(session.events.MinimumInput:Send("abc"))
        return true
    elseif command == "rpc-bounded-read" then
        local expected = { "Output", "UnreliableOutput", "OrderedOutput", "QueueOutput",
            "UnreliableQueueOutput", "StateOutput" }
        local deadline = os.clock() + 20
        repeat
            if rpcBoundedFailure ~= nil then error(rpcBoundedFailure) end
            local ready = true
            for _, name in expected do
                if rpcBoundedRouteReceipts[name] == nil or #rpcBoundedRouteReceipts[name] < 1 then ready = false end
            end
            if ready and rpcBoundedScalars.NumericOutput ~= nil and rpcBoundedScalars.BoundedOutput ~= nil
                and rpcBoundedScalars.LegacyOutput == 43 and rpcBoundedScalars.LegacyQueueOutput == 45 then
                return {
                    client = Players.LocalPlayer.UserId,
                    references = table.clone(rpcBoundedRouteReceipts),
                    scalars = table.clone(rpcBoundedScalars),
                    clientCalls = table.clone(rpcBoundedClientCallResults),
                    clientCallMaximumActive = rpcBoundedClientCallMax,
                    raw = { Reliable = table.clone(rpcBoundedRawFrames.Reliable),
                        Unreliable = table.clone(rpcBoundedRawFrames.Unreliable) },
                    failure = rpcBoundedFailure,
                }
            end
            task.wait(0.03)
        until os.clock() >= deadline
        error("RPC/bounded native route output timeout")
    elseif command == "rpc-bounded-read-client-calls" then
        local deadline = os.clock() + 10
        repeat
            if rpcBoundedFailure ~= nil then error(rpcBoundedFailure) end
            if #rpcBoundedClientCallResults >= 2 then return table.clone(rpcBoundedClientCallResults) end
            task.wait(0.03)
        until os.clock() >= deadline
        error("S2C RPC native handler timeout")
    elseif command == "rpc-bounded-client-calls-status" then
        return { active = rpcBoundedClientCallActive, maximum = rpcBoundedClientCallMax,
            results = #rpcBoundedClientCallResults, released = rpcBoundedClientCallRelease }
    elseif command == "rpc-bounded-release-client-calls" then
        rpcBoundedClientCallRelease = true
        return true
    elseif command == "rpc-bounded-missing-echo" then
        local missing = Instance.new("Part")
        missing.Name = "RelayProofClientOnlyRpcRequest"
        missing.Parent = workspace
        local pending, problem = session.requests.Echo:Request(0.4, missing)
        assert(pending ~= nil, problem and problem.code or "missing Instance RPC request")
        local result = pending:Await()
        missing:Destroy()
        assert(not result.ok and result.error.code == "RequestTimeout",
            "unavailable native RPC request reference is silently dropped")
        return result.error.code
    elseif command == "rpc-bounded-missing-read" then
        local deadline = os.clock() + 10
        local snapshot = session:GetDiagnostics()
        repeat
            if rpcBoundedFailure ~= nil then error(rpcBoundedFailure) end
            snapshot = session:GetDiagnostics()
            if snapshot.events.Output.invalidPayload >= 1 then break end
            task.wait(0.03)
        until os.clock() >= deadline
        return {
            invalidPayload = snapshot.events.Output.invalidPayload,
            dispatched = snapshot.events.Output.dispatched,
            callbacks = if rpcBoundedRouteReceipts.Output == nil then 0 else #rpcBoundedRouteReceipts.Output,
            clientCalls = table.clone(rpcBoundedClientCallResults),
            raw = { Reliable = table.clone(rpcBoundedRawFrames.Reliable),
                Unreliable = table.clone(rpcBoundedRawFrames.Unreliable) },
        }
    elseif command == "rpc-bounded-output-recovery" then
        local deadline = os.clock() + 10
        repeat
            if rpcBoundedFailure ~= nil then error(rpcBoundedFailure) end
            local values = rpcBoundedRouteReceipts.Output
            if values ~= nil and #values == 1 then return values[1] end
            task.wait(0.03)
        until os.clock() >= deadline
        error("S2C native reference output did not recover after a missing Instance")
    elseif command == "rpc-bounded-destroy" then
        for _, item in rpcBoundedRawConnections do item:Disconnect() end
        for _, item in rpcBoundedConnections do item:Disconnect() end
        table.clear(rpcBoundedRawConnections)
        table.clear(rpcBoundedConnections)
        if session then session:Destroy() end
        return true
    elseif command == "rpc-inspect" then
        local pending, problem = session.requests.Inspect:Request(5, argument)
        assert(pending, problem and problem.code)
        local result = pending:Await()
        assert(result.ok and result.value.sequence == argument
            and result.value.owner == game:GetService("Players").LocalPlayer.Name, "RPC identity/struct response")
        local again = pending:Await()
        assert(again == result and again.value == result.value, "RPC repeated Await ownership")
        return true
    elseif command == "rpc-optional" then
        local pending, problem = session.requests.Optional:Request(5, argument)
        assert(pending, problem and problem.code)
        local result = pending:Await()
        assert(result.ok and (if argument then result.value == false else result.value == nil), "RPC false/nil response")
    elseif command == "endpoint-rpc-timeout" then
        local pending, problem = session.requests.Inspect:Request(0.25, argument)
        assert(pending, problem and problem.code)
        local result = pending:Await()
        assert(not result.ok and result.error.code == "RequestTimeout", "endpoint-limited RPC keeps its deadline")
    elseif command == "rpc-failure" then
        local pending, problem = session.requests.Failure:Request(5, argument)
        assert(pending, problem and problem.code)
        local result = pending:Await()
        assert(not result.ok and result.error.code == (if argument then "InvalidResponse" else "HandlerFailure"),
            "RPC fixed failure result")
    elseif command == "rpc-delay-start" then
        local pending, problem = session.requests.Delay:Request(argument.timeout, argument.seconds)
        assert(pending, problem and problem.code)
        pendingRpc = pending
        local rejected, limit = session.requests.Delay:Request(5, 0)
        assert(rejected == nil and limit.code == "RequestLimit", "RPC one pending per method")
    elseif command == "rpc-delay-await" then
        local result = pendingRpc:Await()
        assert(not result.ok and result.error.code == argument, "RPC deadline/cancellation result")
        return true
    elseif command == "rpc-delay-await-value" then
        local result = pendingRpc:Await()
        assert(result.ok and result.value == argument, "RPC response after fresh session")
        return true
    elseif command == "rpc-delay-cancel" then
        pendingRpc:Cancel()
        pendingRpc:Cancel()
    elseif command == "diagnostics" then
        local snapshot = session:GetDiagnostics()
        assert(table.isfrozen(snapshot) and table.isfrozen(snapshot.counters), "native frozen diagnostics")
        return { inFlight = snapshot.inFlight, noListener = snapshot.events.State.noListener,
            dispatched = snapshot.events.State.dispatched, handlerErrors = snapshot.counters.handlerErrors }
    elseif command == "cancel-handler-read" then
        local eventName = argument
        local snapshot = session:GetDiagnostics()
        return {
            threadStatus = if cancellationThread ~= nil then coroutine.status(cancellationThread) else "missing",
            entered = cancellationEntered,
            continued = cancellationContinued,
            replacementCalls = cancellationReplacementCalls,
            inFlight = snapshot.inFlight,
            busy = snapshot.events[eventName].busy,
            received = snapshot.counters.received,
        }
    elseif command == "cancel-handler-terminate" then
        assert(cancellationThread ~= nil, "cancellation callback thread missing")
        local statusBefore = coroutine.status(cancellationThread)
        local result
        if argument == "coroutine.close" then
            result = table.pack(pcall(coroutine.close, cancellationThread))
        else
            assert(argument == "task.cancel", "unknown handler cancellation method")
            result = table.pack(pcall(task.cancel, cancellationThread))
        end
        return {
            callOk = result[1],
            returnValue = if result.n < 2 or result[2] == nil then "nil" else tostring(result[2]),
            callError = if result[1] then nil else tostring(result[2]),
            statusBefore = statusBefore,
            threadStatus = coroutine.status(cancellationThread),
            entered = cancellationEntered,
            continued = cancellationContinued,
            inFlight = session:GetDiagnostics().inFlight,
        }
    elseif command == "cancel-handler-rebind" then
        if argument == "QueuePush" then
            queuedPushConnection:Disconnect()
            queuedPushConnection = assert(session.events.QueuePush:Connect(function()
                cancellationReplacementCalls += 1
            end))
        else
            connection:Disconnect()
            connection = assert(session.events.State:Connect(function()
                cancellationReplacementCalls += 1
            end))
        end
        return true
    elseif command == "cancel-handler-destroy" then
        session:Destroy()
        return session:GetDiagnostics().inFlight
    elseif command == "cancel-handler-fresh-start" then
        local queued = argument == "QueuePush"
        if session then session:Destroy() end
        cancellationThread, cancellationEntered, cancellationContinued, cancellationReplacementCalls = nil, 0, 0, 0
        if queued then
            session = assert(Relay.createClient(Fixture.createQueued(), { startupTimeoutSeconds = 10 }))
            queuedReceived = { reliable = {}, unreliable = {}, once = {}, reusable = {} }
            connectQueuedListeners()
        else
            session = assert(Relay.createClient(Fixture.create(), { startupTimeoutSeconds = 10 }))
            table.clear(received)
            entered = 0
            handlerMode, release = "normal", false
            listen()
        end
        local ok, failure = session:Start()
        assert(ok, failure and failure.code)
        return true
    elseif command == "composed-send" then
        for sequence = 1, 2 do
            local ok, failure = session.events.CompositeInput:Send(Fixture.composedValues(sequence))
            assertSend(ok, failure, "composed reliable send " .. tostring(sequence))
        end
    elseif command == "composed-read" then
        assert(compositeFailure == nil, "composed S2C validation: " .. tostring(compositeFailure))
        return table.clone(compositeReceived)
    elseif command == "unreliable-composed-send" then
        for sequence = 1, Fixture.composedAttemptCount do
            local ok, failure = session.events.UnreliableCompositeInput:Send(Fixture.composedValues(sequence))
            assertSend(ok, failure, "composed unreliable send " .. tostring(sequence))
        end
    elseif command == "unreliable-composed-read" then
        assert(compositeFailure == nil, "unreliable composed S2C validation: " .. tostring(compositeFailure))
        return table.clone(unreliableCompositeReceived)
    elseif command == "raw-overlong" then
        for _ = 1, argument do
            ReplicatedStorage.RelayRemotes.Reliable:FireServer(3, false, -128, -32_768, -2_147_483_648,
                Vector2.zero, "12345", CFrame.new())
        end
    elseif command == "pose-watch" then
        poseResult = Fixture.poseRecord()
        if poseObserver then poseObserver:Disconnect() end
        poseObserver = ReplicatedStorage.RelayRemotes.Reliable.OnClientEvent:Connect(function(id, index, ...)
            if id == 6 then Fixture.recordPose(poseResult, "raw", index, ...) end
        end)
    elseif command == "pose-sources" then
        return Fixture.poseSources()
    elseif command == "pose-send" then
        for index, case in Fixture.poseCases do
            local ok, failure = session.events.PoseInput:Send(index, case.value)
            assert(ok == case.accepted, "CFrame public sender classification")
            if not ok then
                assert(failure.code == "InvalidPayload")
                ReplicatedStorage.RelayRemotes.Reliable:FireServer(5, index, case.value)
            end
        end
    elseif command == "pose-read" then
        return poseResult
    elseif command == "schema-read" then
        return table.clone(schemaReceived)
    elseif command == "send" then
        for sequence = 1, argument do assert(session.events.Input:Send(Fixture.values(sequence))) end
    elseif command == "cancel-input-send" then
        assert(session.events.Input:Send(Fixture.values(argument)))
        return true
    elseif command == "unreliable-send" then
        local handoffs = session:GetDiagnostics().counters.sendHandoffs
        local sent, problem = session.events.UnreliableInput:Send(1, 257, false, Fixture.unreliablePadding .. "x")
        assert(not sent and problem.code == "InvalidPayload"
            and session:GetDiagnostics().counters.sendHandoffs == handoffs,
            "oversized primitive unreliable input rejects before handoff")
        for sampleId = 1, Fixture.unreliableSampleCount do
            assert(session.events.UnreliableInput:Send(Fixture.unreliableValues(sampleId)))
        end
    elseif command == "unreliable-read" then
        assert(unreliableFailure == nil, "unreliable S2C validation: " .. tostring(unreliableFailure))
        local samples = {}
        for _, tuple in unreliableReceived do table.insert(samples, tuple) end
        table.sort(samples, function(left, right) return left.sampleId < right.sampleId end)
        return samples
    elseif command == "raw" then
        local remote = ReplicatedStorage.RelayRemotes.Reliable
        if argument == "matrix" then
            remote:FireServer()
            remote:FireServer("1", Fixture.values(1))
            remote:FireServer(65535, Fixture.values(1))
            remote:FireServer(2, Fixture.values(1))
            remote:FireServer(1, 1)
            remote:FireServer(1, 1, true, 255, 65535, 0.1, Vector3.zero, "extra")
            remote:FireServer(1, 1, true, 256, 65535, 0.1, Vector3.zero)
            remote:FireServer(1, 1, true, 255, 65535, 0 / 0, Vector3.zero)
            remote:FireServer(1, 1, true, 255, 65535, math.huge, Vector3.zero)
            remote:FireServer(1, 1, true, 255, 65535, 0.1, {})
            remote:FireServer({ { 1, 1 }, { 1, 2 } })
            remote:FireServer(buffer.create(8))
        else
            for _ = 1, argument do remote:FireServer("invalid") end
        end
    elseif command == "raw-composite" then
        local remote = ReplicatedStorage.RelayRemotes.Reliable
        for _ = 1, argument do
            local malformed = buffer.create(3)
            buffer.writeu16(malformed, 1, 9)
            remote:FireServer(9, malformed)
        end
    elseif command == "fairness-send" then
        assert(type(argument) == "table" and type(argument.first) == "number"
            and argument.first % 1 == 0 and argument.first >= 1 and argument.first <= 65_532
            and type(argument.count) == "number"
            and argument.count % 1 == 0 and argument.count >= 1 and argument.count <= 4,
            "bounded fairness send command")
        for sequence = argument.first, argument.first + argument.count - 1 do
            assert(session.events.Input:Send(Fixture.values(sequence)))
        end
        return argument.count
    elseif command == "fairness-malformed-burst" then
        assert(type(argument) == "table" and argument.first == 401 and argument.count == 3,
            "fixed malformed fairness burst")
        ReplicatedStorage.RelayRemotes.Reliable:FireServer(1, "invalid")
        for sequence = argument.first, argument.first + argument.count - 1 do
            assert(session.events.Input:Send(Fixture.values(sequence)))
        end
        return { malformed = 1, valid = argument.count }
    elseif command == "read" then
        return { received = table.clone(received), entered = entered }
    elseif command == "mode" then
        handlerMode = argument
        release = false
    elseif command == "release" then
        release = true
    elseif command == "disconnect" then
        connection:Disconnect()
        connection:Disconnect()
    elseif command == "listen" then
        listen()
    elseif command == "once-listen" then
        listen(true)
    elseif command == "lost" then
        local ok, failure = session.events.Input:Send(Fixture.values(1))
        assert(not ok and failure.code == "Disconnected", "client must fail closed")
        assert(not session:Start(), "client must not reconnect")
    elseif command == "destroy" then
        if poseObserver then poseObserver:Disconnect() poseObserver = nil end
        session:Destroy()
        session:Destroy()
        local ok, failure
        if session.events.Input ~= nil then
            ok, failure = session.events.Input:Send(Fixture.values(1))
        else
            ok, failure = session.events.QueueInput:Send(1)
        end
        assert(not ok and failure.code == "Destroyed", "destroyed client")
    elseif command == "timeout" then
        if session then session:Destroy() end
        session = assert(Relay.createClient(Fixture.create(), { startupTimeoutSeconds = 0.1 }))
        local ok, failure = session:Start()
        assert(not ok and failure.code == "StartupTimeout", "startup deadline")
        local timeoutFailure = assert(session:GetDiagnostics().lastStartFailure, "native timeout failure record")
        assert(timeoutFailure.stage == "Root" and timeoutFailure.code == "StartupTimeout"
            and timeoutFailure.descriptorMismatch == nil, "native missing-root timeout stage")
        assert(ReplicatedStorage:FindFirstChild("RelayClientSession_RelayRemotes") == nil,
            "native timeout releases client marker")
        session:Destroy()
        assert(session:GetDiagnostics().lastStartFailure == nil, "native timeout Destroy clears failure")
        session = assert(Relay.createClient(Fixture.create(), { startupTimeoutSeconds = 10 }))
        local cancelled
        task.spawn(function()
            cancelled = table.pack(session:Start())
        end)
        assert(cancelled == nil, "startup must wait for the absent transport")
        session:Destroy()
        task.wait()
        assert(cancelled and not cancelled[1] and cancelled[2].code == "Destroyed",
            "destroy must resume startup without waiting for its deadline")
        assert(session:GetDiagnostics().lastStartFailure == nil
            and ReplicatedStorage:FindFirstChild("RelayClientSession_RelayRemotes") == nil,
            "native cancelled continuation cannot retain failure or marker")
    elseif command == "namespace-start" then
        assert(namespaceSessions[argument.label] == nil, "native namespace client already exists")
        local options = { startupTimeoutSeconds = 10 }
        if argument.namespace ~= nil then options.namespace = argument.namespace end
        local created, problem = Relay.createClient(TransportNamespaces.create(Relay), options)
        assert(created ~= nil, problem and problem.code or "namespace client creation")
        namespaceSessions[argument.label] = created
        namespaceReceived[argument.label] = {}
        local rootName = if argument.namespace == nil then "RelayRemotes" else "RelayRemotes_" .. argument.namespace
        namespaceMarkers[argument.label] = "RelayClientSession_" .. rootName
        if argument.listen then
            assert(created.events.Output:Connect(function(value)
                table.insert(namespaceReceived[argument.label], value)
            end))
        end
        local started, startProblem = created:Start()
        assert(started, startProblem and startProblem.code or "namespace client start")
    elseif command == "namespace-send" then
        local current = assert(namespaceSessions[argument.label], "native namespace client missing")
        local sent, problem = current.events.Input:Send(argument.value)
        assert(sent, problem and problem.code or "namespace client send")
    elseif command == "namespace-read" then
        assert(namespaceSessions[argument], "native namespace client missing")
        return table.clone(namespaceReceived[argument])
    elseif command == "namespace-malformed" then
        local remoteRoot = assert(ReplicatedStorage:FindFirstChild("RelayRemotes_" .. argument),
            "named native transport missing")
        remoteRoot.Reliable:FireServer(1, buffer.create(0))
    elseif command == "namespace-collisions" then
        local namespace = argument
        local sameCopy = assert(Relay.createClient(TransportNamespaces.create(Relay), {
            namespace = namespace, startupTimeoutSeconds = 1,
        }))
        local sameStarted, sameFailure = sameCopy:Start()
        assert(not sameStarted and sameFailure.code == "AlreadyStarted", "same-copy client namespace collision")
        sameCopy:Destroy()

        local moduleCopy = ReplicatedStorage.Relay:Clone()
        moduleCopy.Name = "RelayNamespaceClientProbe"
        moduleCopy.Parent = ReplicatedStorage
        local copiedRelay = require(moduleCopy)
        local copiedClient = assert(copiedRelay.createClient(TransportNamespaces.create(copiedRelay), {
            namespace = namespace, startupTimeoutSeconds = 1,
        }))
        local copiedStarted, copiedFailure = copiedClient:Start()
        assert(not copiedStarted and copiedFailure.code == "AlreadyStarted", "loaded-copy client namespace collision")
        copiedClient:Destroy()
        moduleCopy:Destroy()
        return { sameCopy = sameFailure.code, loadedCopy = copiedFailure.code }
    elseif command == "namespace-status" then
        local current = assert(namespaceSessions[argument], "native namespace client missing")
        return { state = current:GetDiagnostics().state,
            markerPresent = ReplicatedStorage:FindFirstChild(namespaceMarkers[argument]) ~= nil }
    elseif command == "namespace-destroy" then
        local current = assert(namespaceSessions[argument], "native namespace client missing")
        current:Destroy()
        namespaceSessions[argument] = nil
        return { markerRemoved = ReplicatedStorage:FindFirstChild(namespaceMarkers[argument]) == nil }
    elseif command == "namespace-markers-absent" then
        local result = {}
        for _, label in { "default", "game", "package" } do
            result[label] = ReplicatedStorage:FindFirstChild(namespaceMarkers[label]) == nil
        end
        return result
    elseif command == "absent" then
        local deadline = os.clock() + 10
        while ReplicatedStorage:FindFirstChild("RelayRemotes") ~= nil and os.clock() < deadline do task.wait() end
        assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "old transport still replicated")
    else
        error("unknown proof command")
    end
    return true
end
ready:FireServer()
