local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Fixture = require(ReplicatedStorage:WaitForChild("RelayProofDefinition"))
local control = ReplicatedStorage:WaitForChild("RelayProofControl")
local ready = ReplicatedStorage:WaitForChild("RelayProofReady")
local session
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
local queuedReceived = { reliable = {}, unreliable = {}, once = {} }
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

control.OnClientInvoke = function(command, argument)
    if command == "ordered-start" then
        if session then session:Destroy() end
        if orderedInitObserver then orderedInitObserver:Disconnect() end
        if orderedRawObserver then orderedRawObserver:Disconnect() end
        orderedGeneration, orderedValues, orderedRawCount, orderedMaximumBytes = nil, {}, 0, 0
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
        assert(session:Start())
        assert(orderedGeneration ~= nil and orderedGeneration > 0, "ordered startup generation")
        orderedRawObserver = root.Unreliable.OnClientEvent:Connect(function(endpoint, packet)
            if endpoint == 2 then
                orderedRawCount += 1
                if typeof(packet) == "buffer" then
                    orderedMaximumBytes = math.max(orderedMaximumBytes, buffer.len(packet))
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
        queuedReceived = { reliable = {}, unreliable = {}, once = {} }
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
        }
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
        else
            assert(ok, failure and failure.code)
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
            queuedReceived = { reliable = {}, unreliable = {}, once = {} }
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
