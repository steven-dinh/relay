local Definition = require(if script then script.Parent.Definition else "./Definition")
local PendingRequests = require(if script then script.Parent.internal.PendingRequests else "./internal/PendingRequests")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")
local Diagnostics = require(if script then script.Parent.internal.Diagnostics else "./internal/Diagnostics")
local ByteUnits = require(if script then script.Parent.internal.ByteUnits else "./internal/ByteUnits")
local RpcFrame = require(if script then script.Parent.internal.RpcFrame else "./internal/RpcFrame")
local TokenBucket = require(if script then script.Parent.internal.TokenBucket else "./internal/TokenBucket")
local ReadinessFrame = require(if script then script.Parent.internal.ReadinessFrame else "./internal/ReadinessFrame")
local OrderedFrame = require(if script then script.Parent.internal.OrderedFrame else "./internal/OrderedFrame")
local InstanceRefs = require(if script then script.Parent.internal.InstanceRefs else "./internal/InstanceRefs")
local Batch = require(if script then script.Parent.internal.Batch else "./internal/Batch")
local BatchFrame = require(if script then script.Parent.internal.BatchFrame else "./internal/BatchFrame")
local PacedBatcher = require(if script then script.Parent.internal.PacedBatcher else "./internal/PacedBatcher")
local StateQueue = require(if script then script.Parent.internal.StateQueue else "./internal/StateQueue")
local Timestamps = require(if script then script.Parent.internal.Timestamps else "./internal/Timestamps")

local activeSession = nil
local MAXIMUM_CALL_ID = 4_294_967_295
local MAXIMUM_READINESS_COUNTER = 4_294_967_295
local MAXIMUM_READINESS_BYTES = 90
local MAXIMUM_ORDERED_COUNTER = 4_294_967_296
local MAXIMUM_BATCH_RECORDS = 32

local function canonicalGuid(value)
    if type(value) ~= "string" or #value ~= 36 then
        return nil
    end
    for index = 1, 36 do
        local byte = string.byte(value, index)
        if index == 9 or index == 14 or index == 19 or index == 24 then
            if byte ~= 45 then return nil end
        elseif not ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70)
            or (byte >= 97 and byte <= 102)) then
            return nil
        end
    end
    return string.lower(value)
end

local function disconnect(connection)
    connection:Disconnect()
end

local function validOptions(options)
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return false
    end

    for key in options do
        if key ~= "startupTimeoutSeconds" and key ~= "diagnostics" then
            return false
        end
    end

    local timeout = options.startupTimeoutSeconds
    local diagnostics = options.diagnostics
    if diagnostics ~= nil then
        if type(diagnostics) ~= "table" or getmetatable(diagnostics) ~= nil then return false end
        for key in diagnostics do
            if key ~= "traffic" and key ~= "reports" then return false end
        end
        if diagnostics.traffic ~= nil and type(diagnostics.traffic) ~= "boolean" then return false end
        if diagnostics.reports ~= nil and type(diagnostics.reports) ~= "boolean" then return false end
    end
    return type(timeout) == "number" and timeout > 0 and timeout <= 60
end

local function create(definition, options)
    if game == nil or not game:GetService("RunService"):IsClient() then
        return nil, Definition.error("WrongRuntimeSide")
    end

    local compiled = Definition.get(definition)
    if compiled == nil then
        return nil, Definition.error("InvalidDefinition")
    end
    if not validOptions(options) then
        return nil, Definition.error("InvalidOptions")
    end

    local timeout = options.startupTimeoutSeconds
    local state = "Created"
    local identity = {}
    local attempt = nil
    local cancelWait = nil
    local storage, root, descriptor, remote, unreliableRemote = nil, nil, nil, nil, nil
    local connections, storageSiblingWatchers = {}, {}
    local receivers = {}
    local pendingById, pendingMethodCounts = {}, {}
    local inboundRequestListeners, inboundActiveRequests = {}, {}
    local inboundReplayGuids, inboundReplayCallIds = table.create(64), table.create(64)
    local inboundReplayCursor, inboundRequestCount = 1, 0
    local inboundMethodCounts = {}
    local inboundRefusalBucket = nil
    local requestRuntimes = {}
    local receiveRpc
    local pendingCount, callIdCounter, rpcSessionGuid = 0, 0, nil
    local readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
    local readinessRevision, readinessMask, readinessExhausted = 0, nil, false
    local readinessCompiled = compiled.readiness
    local orderedSendSequences, orderedReceiveHighWater = {}, {}
    local orderedGeneration = 0
    local orderedInitAttempt = nil
    local rpcClockHighWater = -math.huge
    local batchOwner = nil
    local queuedReceivers = {}
    for eventId, event in compiled.queuedById or {} do
        if event.direction == "ServerToClient" then
            queuedReceivers[eventId] = {
                event = event,
                decode = Frame.compile(event, "decode"),
            }
        end
    end
    local diagnostics = Diagnostics.create(compiled.events, "Client", nil, { perEndpoint = 1 }, nil,
        compiled.requests, options.diagnostics)
    local diagnosticsActive = true

    local function rpcNow()
        local now = os.clock()
        if now > rpcClockHighWater then
            rpcClockHighWater = now
        end
        return rpcClockHighWater
    end

    local function settlePending(record, result)
        return PendingRequests.settle(record, result, function()
            if pendingById[record.callId] ~= record then return false end
            pendingById[record.callId] = nil
            pendingCount -= 1
            local methodCount = pendingMethodCounts[record.methodId] - 1
            pendingMethodCounts[record.methodId] = if methodCount == 0 then nil else methodCount
            return true
        end)
    end

    local function settleAllPending(code)
        local pending = table.clone(pendingById)
        for _, record in pending do
            settlePending(record, PendingRequests.failure(code))
        end
    end

    local reportReasons = {
        invalidEndpoint = "InvalidEndpoint",
        wrongChannel = "WrongChannel",
        noListener = "NoListener",
        busy = "Busy",
        invalidPayload = "InvalidPayload",
        stale = "Stale",
        handlerErrors = "HandlerError",
        transportFailures = "TransportFailure",
        transportLosses = "TransportLoss",
    }

    local function count(name, eventCounters, endpointId, delivery, includeReport)
        if not diagnosticsActive then return end
        Diagnostics.increment(diagnostics.counters, name)
        if eventCounters ~= nil and eventCounters[name] ~= nil then
            Diagnostics.increment(eventCounters, name)
        end
        if includeReport ~= false and diagnostics.reports ~= nil then
            local reason = reportReasons[name]
            if reason ~= nil then Diagnostics.report(diagnostics, reason, endpointId, delivery) end
        end
    end

    local function knownEndpointId(endpointId)
        if type(endpointId) ~= "number" or endpointId < 1 or endpointId > 65_535 or endpointId % 1 ~= 0 then
            return nil
        end
        local endpoint = compiled.byId[endpointId] or compiled.requestsById[endpointId]
        return if endpoint == nil then nil else endpoint.id
    end

    local function observedTraffic(delivery, endpointId, ...)
        if not diagnosticsActive or diagnostics.traffic == nil then return nil end
        local bytes = ByteUnits.exactInbound(endpointId, ...)
        Diagnostics.addTraffic(diagnostics, nil, delivery, "receivedPackets", 1)
        if bytes == nil then
            Diagnostics.addTraffic(diagnostics, nil, delivery, "unmeasuredPackets", 1)
        else
            Diagnostics.addTraffic(diagnostics, nil, delivery, "receivedBytes", bytes)
        end
        if endpointId ~= 0 then
            local endpointBytes = bytes
            local event = compiled.byId[endpointId]
            if event ~= nil and event.ordered and endpointBytes ~= nil then
                endpointBytes = if endpointBytes >= 8 then endpointBytes - 8 else nil
            end
            Diagnostics.observeEndpoint(diagnostics, endpointId, delivery, endpointBytes)
        end
        return bytes
    end

    local function validatedTraffic(endpointId, delivery, bytes)
		if not diagnosticsActive then return end
        Diagnostics.recordValidated(diagnostics, endpointId, delivery, bytes)
    end

    local function receivedRows(delivery, rows)
		if not diagnosticsActive then return end
        Diagnostics.recordReceivedRows(diagnostics, delivery, rows)
    end

    local function observedMethod(methodId, delivery, header)
		if not diagnosticsActive or diagnostics.traffic == nil then return end
		local bytes = if header.referencesValid == false then nil else header.bodyBytes
			+ (header.referenceCount or 0) * ByteUnits.REFERENCE_BYTES
		Diagnostics.observeEndpoint(diagnostics, methodId, delivery, bytes)
	end

	local function sentControl(delivery, packet)
		if not diagnosticsActive or diagnostics.traffic == nil then return end
		local bytes = buffer.len(packet)
		Diagnostics.recordSentSingle(diagnostics, nil, delivery, bytes, bytes, 1, 1)
	end

    local function stop(nextState)
        if state == "Started" and nextState == "Disconnected" then
            count("transportLosses")
        end
        state = nextState
        diagnosticsActive = false
        if batchOwner ~= nil then
            batchOwner.alive = false
            batchOwner.terminalError = Definition.error(nextState)
            Batch.destroy(batchOwner)
            PacedBatcher.destroy(batchOwner)
            StateQueue.destroy(batchOwner)
        end
        attempt = nil
        orderedInitAttempt = nil
        settleAllPending(nextState)
        for _, listener in inboundRequestListeners do
            listener.active = false
            listener.handler = nil
        end
        table.clear(inboundRequestListeners)
        for _, active in inboundActiveRequests do
            for _, lease in active do lease.active = false end
        end
        table.clear(inboundActiveRequests)
        table.clear(inboundReplayGuids)
        table.clear(inboundReplayCallIds)
        inboundReplayCursor, inboundRequestCount = 1, 0
        table.clear(inboundMethodCounts)
        inboundRefusalBucket = nil
        if activeSession == identity then
            activeSession = nil
        end
        for _, receiver in receivers do
            receiver.handler = nil
            receiver.connection = nil
            receiver.once = false
            receiver.validate = nil
            receiver.busy = false
            receiver.batchLease = nil
        end
        for _, connection in connections do
            pcall(disconnect, connection)
        end
        table.clear(connections)
        for _, connection in storageSiblingWatchers do
            pcall(disconnect, connection)
        end
        table.clear(storageSiblingWatchers)
        storage, root, descriptor, remote, unreliableRemote = nil, nil, nil, nil, nil
        rpcSessionGuid = nil
        readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
        readinessRevision, readinessMask, readinessExhausted = 0, nil, false
        orderedGeneration = 0
        table.clear(orderedSendSequences)
        table.clear(orderedReceiveHighWater)
        if cancelWait then
            cancelWait()
        end
    end

    local function transportValid(checkDefinition)
        if root == nil or descriptor == nil or remote == nil then
            return false
        end
        -- Discovery establishes immutable classes; cached references are never rebound.
        if root.Name ~= "RelayRemotes" or root.Parent ~= storage
            or descriptor.Name ~= "Definition" or descriptor.Parent ~= root
            or remote.Name ~= "Reliable" or remote.Parent ~= root
            or (checkDefinition ~= false and descriptor.Value ~= compiled.descriptor)
        then
            return false
        end
        if compiled.hasUnreliable then
            if unreliableRemote == nil or unreliableRemote.Name ~= "Unreliable"
                or unreliableRemote.Parent ~= root then
                return false
            end
        elseif unreliableRemote ~= nil then
            return false
        end
        -- All distinct leaves are direct children, so the count proves exact membership.
        return #root:GetChildren() == if compiled.hasUnreliable then 3 else 2
    end

    local function uniqueRoot()
        for _, child in storage:GetChildren() do
            if child.Name == "RelayRemotes" and child ~= root then
                return false
            end
        end
        return true
    end

    local function watchStorageSibling(child)
        if child == root or child.Parent ~= storage or storageSiblingWatchers[child] ~= nil then
            return
        end
        storageSiblingWatchers[child] = child:GetPropertyChangedSignal("Name"):Connect(function()
            if state == "Started" and child.Parent == storage and child.Name == "RelayRemotes" then
                stop("Disconnected")
            end
        end)
    end

    local function unwatchStorageSibling(child)
        local connection = storageSiblingWatchers[child]
        if connection ~= nil then
            storageSiblingWatchers[child] = nil
            pcall(disconnect, connection)
        end
    end

    local function checkTransport()
        local ok, valid = pcall(transportValid)
        if not ok or not valid then
            stop("Disconnected")
            return false
        end
        return true
    end

    local function buildReadinessMask()
        local bytes = table.create(readinessCompiled.bytes, 0)
        for eventId, bit in readinessCompiled.byId do
            local receiver = receivers[eventId]
            if receiver ~= nil and receiver.handler ~= nil then
                local index = math.floor(bit / 8) + 1
                bytes[index] += 2 ^ (bit % 8)
            end
        end
        local parts = table.create(readinessCompiled.bytes)
        for index = 1, readinessCompiled.bytes do
            parts[index] = string.char(bytes[index])
        end
        return table.concat(parts)
    end

    local function handoffReadiness(packet)
        if not checkTransport() then
            return false, Definition.error(state)
        end
        local ok = pcall(remote.FireServer, remote, 0, packet)
        if not ok then
            if state == "Started" then
                count("transportFailures", nil, nil, "Reliable")
                checkTransport()
            end
            return false, Definition.error("TransportFailure")
        end
        if state ~= "Started" then
            return false, Definition.error(state)
        end
        count("sendHandoffs")
        sentControl("Reliable", packet)
        return true, nil
    end

    local function closeReadinessForExhaustion()
        local packet = if readinessHeldGeneration ~= nil and readinessServerGuid ~= nil and rpcSessionGuid ~= nil
            then ReadinessFrame.close(readinessServerGuid, readinessHeldGeneration, rpcSessionGuid) else nil
        readinessExhausted = true
        readinessHeldGeneration = nil
        readinessMask = nil
        if packet ~= nil then
            handoffReadiness(packet)
        end
    end

    local function updateReadinessListener(eventId, connected)
        if readinessCompiled == nil or state ~= "Started" or readinessExhausted then
            return
        end
        local bit = readinessCompiled.byId[eventId]
        if bit == nil or readinessMask == nil then
            return
        end
        local index = math.floor(bit / 8) + 1
        local bitValue = 2 ^ (bit % 8)
        local byte = string.byte(readinessMask, index)
        local installed = math.floor(byte / bitValue) % 2 == 1
        if installed == connected then
            return
        end
        if readinessRevision >= MAXIMUM_READINESS_COUNTER then
            closeReadinessForExhaustion()
            return
        end
        readinessRevision += 1
        local updatedByte = if connected then byte + bitValue else byte - bitValue
        readinessMask = string.sub(readinessMask, 1, index - 1) .. string.char(updatedByte)
            .. string.sub(readinessMask, index + 1)
        if readinessHeldGeneration ~= nil then
            local packet = ReadinessFrame.ack(readinessServerGuid, readinessHeldGeneration,
                rpcSessionGuid, readinessRevision, readinessMask, readinessCompiled.count)
            if packet ~= nil then
                handoffReadiness(packet)
            end
        end
    end

    local function receiveReadiness(delivery, packet)
        if delivery ~= "Reliable" then
            count("wrongChannel", nil, nil, delivery)
            return
        end
        if readinessCompiled == nil then
            count("invalidEndpoint", nil, nil, delivery)
            return
        end
        local header = ReadinessFrame.peek(packet, false, readinessCompiled.count)
        if header == nil then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        if readinessExhausted then
            return
        end
        if (readinessServerGuid ~= nil and header.serverGuid ~= readinessServerGuid)
            or (readinessGenerationHighWater ~= nil and header.generation <= readinessGenerationHighWater) then
            count("invalidEndpoint", nil, nil, delivery)
            return
        end
        readinessServerGuid = header.serverGuid
        readinessGenerationHighWater = header.generation
        readinessHeldGeneration = header.generation
        local acknowledgement = ReadinessFrame.ack(readinessServerGuid, readinessHeldGeneration,
            rpcSessionGuid, readinessRevision, readinessMask, readinessCompiled.count)
        if acknowledgement ~= nil then
            handoffReadiness(acknowledgement)
        end
    end

    local function dispatchBatch(rows, tuples)
        for index, row in rows do
            local event = row.event
            local eventId = event.id
            local values = tuples[index]
            tuples[index] = nil
            if state ~= "Started" then
                break
            end
            local eventCounters = diagnostics.byId[eventId]
            local receiver = receivers[eventId]
            if receiver == nil or receiver.handler == nil then
                count("noListener", eventCounters, eventId, row.event.delivery)
            elseif receiver.busy then
                count("busy", eventCounters, eventId, row.event.delivery)
            else
                local lease = {}
                local handler = receiver.handler
                receiver.busy = true
                receiver.batchLease = lease
                if receiver.once then
                    receiver.handler = nil
                    receiver.connection = nil
                    receiver.once = false
                    updateReadinessListener(receiver.id, false)
                end
                if state == "Started" and receiver.batchLease == lease then
                    task.spawn(coroutine.create(function()
                        if state ~= "Started" or receiver.batchLease ~= lease then
                            return
                        end
                        count("dispatched", eventCounters)
                        local ok = pcall(handler, table.unpack(values, 2, values.n))
                        if not ok and state == "Started" then
                            count("handlerErrors", eventCounters, eventId, row.event.delivery)
                        end
                        if state == "Started" and receiver.batchLease == lease then
                            receiver.busy = false
                            receiver.batchLease = nil
                        end
                    end))
                end
            end
        end
        table.clear(tuples)
    end

    local function receiveBatch(delivery, packet, kind, references)
        local limit = if delivery == "Reliable" then 8_192 else 900
        local header = BatchFrame.header(packet, limit, references)
        if header == nil or header.kind ~= kind then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        if compiled.queuedById == nil then
            count("invalidEndpoint", nil, nil, delivery)
            return
        end

        local metadataError
        local metadataEndpointId
        local rows = BatchFrame.scan(packet, header, function(eventId)
            local queued = queuedReceivers[eventId]
            if queued == nil then
                metadataError = "invalidEndpoint"
                if diagnosticsActive and diagnostics.reports ~= nil then
                    metadataEndpointId = knownEndpointId(eventId)
                end
                return nil
            end
            if queued.event.delivery ~= delivery then
                metadataError = "wrongChannel"
                if diagnosticsActive and diagnostics.reports ~= nil then
                    metadataEndpointId = knownEndpointId(eventId)
                end
                return nil
            end
            if kind == 2 and queued.event.queue ~= "State" then
                metadataError = "invalidEndpoint"
                if diagnosticsActive and diagnostics.reports ~= nil then
                    metadataEndpointId = knownEndpointId(eventId)
                end
                return nil
            end
            return queued.event
        end, references)
        if rows == nil then
            count(metadataError or "invalidPayload", nil,
                if metadataError == nil then nil else metadataEndpointId, delivery)
            return
        end
        receivedRows(delivery, rows)

        local tuples = table.create(#rows)
        for index, row in rows do
            local queued = queuedReceivers[row.event.id]
            local body, localReferences = BatchFrame.readBody(packet, row, references)
            if body == nil then
                count("invalidPayload", diagnostics.byId[row.event.id], row.event.id, delivery)
                return
            end
            local values = if localReferences == nil then table.pack(queued.decode(body))
                else table.pack(queued.decode(body, table.unpack(localReferences, 1, localReferences.n)))
            if values[1] ~= true then
                count("invalidPayload", diagnostics.byId[row.event.id], row.event.id, delivery)
                return
            end
            tuples[index] = values
        end
        if diagnostics.traffic ~= nil then
            for index, row in rows do
                validatedTraffic(row.event.id, delivery,
                    row.length + row.referenceCount * ByteUnits.REFERENCE_BYTES)
            end
        end
        dispatchBatch(rows, tuples)
    end

    local function receiveEndpointZero(delivery, ...)
        local argumentCount = select("#", ...)
        if argumentCount < 1 then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        local packet = select(1, ...)
        if typeof(packet) ~= "buffer" then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        local length = buffer.len(packet)
        if length < 2 or length > 8_192 then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        if state == "Starting" then
            if argumentCount ~= 1 then
                count("invalidPayload", nil, nil, delivery)
                return
            end
            if length > MAXIMUM_READINESS_BYTES then
                count("invalidPayload", nil, nil, delivery)
                return
            end
            if buffer.readu8(packet, 0) ~= 2 or buffer.readu8(packet, 1) ~= 33 then
                count("invalidEndpoint", nil, nil, delivery)
                return
            end
            if delivery ~= "Reliable" then
                count("wrongChannel", nil, nil, delivery)
                return
            end
            local header = OrderedFrame.readInitialization(packet)
            if header == nil then
                count("invalidPayload", nil, nil, delivery)
                return
            end
            local pending = orderedInitAttempt
            if not compiled.hasOrderedClientToServer or pending == nil or pending.attempt ~= attempt
                or not pending.helloSent or pending.generation ~= nil or header.clientGuid ~= pending.clientGuid then
                count("stale", nil, nil, delivery)
                return
            end
            pending.generation = header.generation
            if pending.finish ~= nil then
                pending.finish(nil)
            end
            return
        end
        local format = buffer.readu8(packet, 0)
        if format == RpcFrame.LEGACY_WIRE_TAG or format == RpcFrame.V2_WIRE_TAG then
            receiveRpc(delivery, packet, select(2, ...))
            return
        end
        if format ~= 2 and format ~= 5 then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        local kind = buffer.readu8(packet, 1)
        if kind == 1 or kind == 2 then
            if argumentCount > InstanceRefs.MAXIMUM_REFERENCES + 1 then
                count("invalidPayload", nil, nil, delivery)
                return
            end
            local references = if argumentCount > 1 then table.pack(select(2, ...)) else nil
            receiveBatch(delivery, packet, kind, references)
            return
        end
        if argumentCount ~= 1 or format ~= 2 then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        if kind == 32 or kind == 33 then
            if length > MAXIMUM_READINESS_BYTES then
                count("invalidPayload", nil, nil, delivery)
                return
            end
            if delivery ~= "Reliable" then
                count("wrongChannel", nil, nil, delivery)
                return
            end
            if kind ~= 33 or not compiled.hasOrderedClientToServer then
                count("invalidEndpoint", nil, nil, delivery)
                return
            end
            if OrderedFrame.readInitialization(packet) == nil then
                count("invalidPayload", nil, nil, delivery)
            else
                count("stale", nil, nil, delivery)
            end
            return
        end
        if kind < 16 or kind > 19 then
            count("invalidEndpoint", nil, nil, delivery)
            return
        end
        if length > MAXIMUM_READINESS_BYTES then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        receiveReadiness(delivery, packet)
    end

    local function fire(event, ...)
        local transport = if event.delivery == "Unreliable" then unreliableRemote else remote
        transport:FireServer(event.id, ...)
    end

    local function withTimestamp(event, encode)
        if event.timestampWindow == nil then return encode end
        return function(...)
            local serverTime = Timestamps.sample()
            if serverTime == nil then return nil end
            return encode(serverTime, ...)
        end
    end

    local function sendValidated(event, valid, ...)
        if not valid then
            return false, Definition.error("InvalidPayload")
        end
        if not checkTransport() then
            return false, Definition.error("Disconnected")
        end
        local contentBytes
        if diagnosticsActive and diagnostics.traffic ~= nil and not event.ordered then
            contentBytes = ByteUnits.exactInbound(event.id, ...)
        end
        if event.ordered then
            local encodedPayload = select(1, ...)
            local references = if event.hasReferences then table.pack(select(2, ...)) else nil
            if event.hasReferences and not InstanceRefs.scopeArguments(nil, ...) then
                return false, Definition.error("InvalidPayload")
            end
            local sequence = ((orderedSendSequences[event.id] or 0) + 1) % MAXIMUM_ORDERED_COUNTER
            local packet = OrderedFrame.wrap(event, encodedPayload, orderedGeneration, sequence, references)
            if packet == nil then
                return false, Definition.error("InvalidPayload")
            end
            if diagnosticsActive and diagnostics.traffic ~= nil then
                local referenceCount = if references == nil then 0 else references.n
                local endpointBytes = buffer.len(packet) - 8 + referenceCount * ByteUnits.REFERENCE_BYTES
                Diagnostics.recordSubmitted(diagnostics, event.id, event.delivery, endpointBytes)
            end
            orderedSendSequences[event.id] = sequence
            local ok = if references == nil then pcall(fire, event, packet)
                else pcall(fire, event, packet, table.unpack(references, 1, references.n))
            if not ok then
                count("transportFailures", diagnostics.byId[event.id], event.id, event.delivery)
                if state == "Started" then
                    checkTransport()
                end
                return false, Definition.error("TransportFailure")
            end
            count("sendHandoffs", diagnostics.byId[event.id])
            if diagnosticsActive and diagnostics.traffic ~= nil then
                local referenceCount = if references == nil then 0 else references.n
                local endpointBytes = buffer.len(packet) - 8 + referenceCount * ByteUnits.REFERENCE_BYTES
                Diagnostics.recordSentSingle(diagnostics, event.id, event.delivery,
                    buffer.len(packet) + referenceCount * ByteUnits.REFERENCE_BYTES,
                    endpointBytes, 1, 1)
            end
            return true, nil
        end
        if diagnosticsActive and diagnostics.traffic ~= nil then
            Diagnostics.recordSubmitted(diagnostics, event.id, event.delivery, contentBytes)
        end
        local ok = pcall(fire, event, ...)
        if not ok then
            count("transportFailures", diagnostics.byId[event.id], event.id, event.delivery)
            if state == "Started" then
                checkTransport()
            end
            return false, Definition.error("TransportFailure")
        end
        count("sendHandoffs", diagnostics.byId[event.id])
        if diagnosticsActive and diagnostics.traffic ~= nil then
            Diagnostics.recordSentSingle(diagnostics, event.id, event.delivery,
                contentBytes, contentBytes, 1, 1)
        end
        return true, nil
    end

    local function connect(receiver, handler, once)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if type(handler) ~= "function" then
            return nil, Definition.error("InvalidHandler")
        end
        if receiver.handler ~= nil then
            return nil, Definition.error("AlreadyConnected")
        end
        local connection
        connection = table.freeze({
            Disconnect = function()
                if receiver.connection == connection then
                    receiver.handler = nil
                    receiver.connection = nil
                    receiver.once = false
                    updateReadinessListener(receiver.id, false)
                end
            end,
        })
        receiver.handler = handler
        receiver.connection = connection
        receiver.once = once
        updateReadinessListener(receiver.id, true)
        return connection, nil
    end

    local batchEvents = {}
    for name, event in compiled.events do
        local queued = if compiled.queuedById == nil then nil else compiled.queuedById[event.id]
        if event.direction == "ClientToServer" and queued ~= nil then
            batchEvents[name] = {
                id = queued.id,
                delivery = queued.delivery,
                queue = queued.queue,
                encode = withTimestamp(queued, Frame.compile(queued, "encode")),
            }
        end
    end
    batchOwner = {
        alive = true,
        terminalError = nil,
        diagnostics = diagnostics,
        events = batchEvents,
        batch = nil,
        pacedBatcher = nil,
        flushOwner = nil,
        check = function()
            if state == "Destroyed" or state == "Disconnected" then
                return false, batchOwner.terminalError or Definition.error(state)
            end
            if state ~= "Started" then
                return false, Definition.error("NotStarted")
            end
            if not checkTransport() then
                return false, Definition.error(state)
            end
            return true, nil
        end,
        now = rpcNow,
        handoff = function(delivery, packet, _, references)
            if state ~= "Started" or not batchOwner.alive then
                return false, batchOwner.terminalError or Definition.error(state), 0
            end
            if not checkTransport() then
                return false, Definition.error(state), 0
            end
            local transport = if delivery == "Unreliable" then unreliableRemote else remote
            if references ~= nil and not InstanceRefs.scopeArguments(nil, packet,
                table.unpack(references, 1, references.n)) then
                return false, Definition.error("InvalidPayload"), 0
            end
            local ok = if references == nil then pcall(transport.FireServer, transport, 0, packet)
                else pcall(transport.FireServer, transport, 0, packet, table.unpack(references, 1, references.n))
            if ok then
                count("sendHandoffs")
            else
                count("transportFailures", nil, nil, delivery)
                if state == "Started" then
                    checkTransport()
                end
                return false, Definition.error("TransportFailure"), 0
            end
            if state ~= "Started" then
                return false, Definition.error(state), 1
            end
            if not checkTransport() then
                return false, Definition.error(state), 1
            end
            return true, nil, 1
        end,
    }

    local function createBatch(flushAfter, reusable)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if state ~= "Started" then
            return nil, Definition.error("NotStarted")
        end
        if type(flushAfter) ~= "number" or not (flushAfter > 0 and flushAfter <= 0.1) then
            return nil, Definition.error("InvalidOptions")
        end
        return Batch.create(batchOwner, nil, flushAfter, reusable)
    end

    local function createPacedBatcher(interval, options)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if state ~= "Started" then
            return nil, Definition.error("NotStarted")
        end
        return PacedBatcher.create(batchOwner, interval, options)
    end

    local function createState(flushAfter)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if state ~= "Started" then
            return nil, Definition.error("NotStarted")
        end
        if type(flushAfter) ~= "number" or not (flushAfter > 0 and flushAfter <= 0.1) then
            return nil, Definition.error("InvalidOptions")
        end
        return StateQueue.create(batchOwner, nil, flushAfter)
    end

    local events = {}
    local requests = {}
    for name, event in compiled.events do
        local validate
        if event.usesCodec and event.queue ~= nil then
            validate = if event.direction == "ClientToServer"
                then batchEvents[name].encode else queuedReceivers[event.id].decode
        else
            local mode = if event.usesCodec then
                (if event.direction == "ClientToServer" then "encode" else "decode") else nil
            validate = Frame.compile(if event.ordered then OrderedFrame.codecEvent(event) else event, mode)
            validate = withTimestamp(event, validate)
        end
        if event.direction == "ClientToServer" then
            events[name] = table.freeze({
                Send = function(_, ...)
                    if state == "Destroyed" or state == "Disconnected" then
                        return false, Definition.error(state)
                    end
                    if state ~= "Started" then
                        return false, Definition.error("NotStarted")
                    end
                    return sendValidated(event, validate(...))
                end,
            })
        else
            local receiver = { id = event.id, handler = nil, connection = nil, once = false, busy = false,
                validate = validate }
            receivers[event.id] = receiver
            events[name] = table.freeze({
                Connect = function(_, handler)
                    return connect(receiver, handler, false)
                end,
                Once = function(_, handler)
                    return connect(receiver, handler, true)
                end,
            })
        end
    end

    local function rememberInbound(guid, callId)
        local cursor = inboundReplayCursor
        inboundReplayGuids[cursor] = guid
        inboundReplayCallIds[cursor] = callId
        inboundReplayCursor = if cursor == 64 then 1 else cursor + 1
    end

    local function inboundReplayed(guid, callId)
        local active = inboundActiveRequests[guid]
        if active ~= nil and active[callId] ~= nil then return true end
        for index = 1, 64 do
            if inboundReplayGuids[index] == guid and inboundReplayCallIds[index] == callId then return true end
        end
        return false
    end

    local function releaseInboundRequest(lease)
        if not lease.active then return false end
        local active = inboundActiveRequests[lease.sessionGuid]
        if active == nil or active[lease.callId] ~= lease then return false end
        lease.active = false
        active[lease.callId] = nil
        if next(active) == nil then inboundActiveRequests[lease.sessionGuid] = nil end
        inboundRequestCount -= 1
        local methodCount = inboundMethodCounts[lease.methodId] - 1
        inboundMethodCounts[lease.methodId] = if methodCount == 0 then nil else methodCount
        return true
    end

    local function sendInboundResponse(method, header, kind, body, references)
        if state ~= "Started" or not checkTransport() then return end
        local referenceCount = if references == nil then 0 else references.n
        if body ~= nil and (references == nil
            or not InstanceRefs.scopeArguments(nil, body, table.unpack(references, 1, referenceCount))) then
            count("invalidPayload", nil, method.id, "Reliable")
            return
        end
        local version = method.envelopeVersion or 1
        local packet = RpcFrame.wrap(kind, method.id, header.callId, header.sessionGuid, body,
            kind == 5, version, referenceCount)
        if packet == nil then
            count("invalidPayload", nil, method.id, "Reliable")
            return
        end
        local endpointBytes = (if body == nil then 0 else buffer.len(body))
            + referenceCount * ByteUnits.REFERENCE_BYTES
        if diagnosticsActive and diagnostics.traffic ~= nil then
            Diagnostics.recordSubmitted(diagnostics, method.id, "Reliable", endpointBytes)
        end
        local ok
        if referenceCount == 0 then
            ok = pcall(remote.FireServer, remote, 0, packet)
        else
            ok = pcall(remote.FireServer, remote, 0, packet, table.unpack(references, 1, referenceCount))
        end
        if ok then
            count("sendHandoffs")
            if diagnosticsActive and diagnostics.traffic ~= nil then
                Diagnostics.recordSentSingle(diagnostics, method.id, "Reliable",
                    buffer.len(packet) + referenceCount * ByteUnits.REFERENCE_BYTES,
                    endpointBytes, 1, 1)
            end
        else
            count("transportFailures", nil, method.id, "Reliable")
            if state == "Started" then checkTransport() end
        end
    end

    local function refusalKindForError(code)
        if code == "Busy" then return 6 end
        if code == "NoListener" then return 7 end
        if code == "EndpointRateLimited" then return 8 end
        return nil
    end

    local function handleInboundRequest(delivery, method, header, packet, references)
        if delivery ~= "Reliable" then
            count("wrongChannel", nil, method.id, delivery)
            return
        end
        if method.direction ~= "ServerToClient" or header.kind ~= 1 then
            count("invalidEndpoint", nil, method.id, delivery)
            return
        end
        if inboundReplayed(header.sessionGuid, header.callId) then
            count("busy", nil, method.id, delivery)
            return
        end
        if not header.referencesValid then
            count("invalidPayload", nil, method.id, delivery)
            return
        end
        local listener = inboundRequestListeners[method.id]
        local refusalCode
        local reportReasonRecorded = false
        if listener == nil or not listener.active then
            refusalCode = "NoListener"
            count("noListener", nil, method.id, delivery)
            reportReasonRecorded = true
        elseif (inboundMethodCounts[method.id] or 0) >= (method.concurrency or 1)
            or inboundRequestCount >= 8 then
            refusalCode = "Busy"
            count("busy", nil, method.id, delivery)
            reportReasonRecorded = true
        end

        if refusalCode ~= nil and method.refusals ~= true then return end
        if refusalCode ~= nil then
            if inboundRefusalBucket == nil or not inboundRefusalBucket:take(rpcNow()) then return end
        end
        if not InstanceRefs.scopeArguments(nil, packet, table.unpack(references, 1, references.n)) then
            count("invalidPayload", nil, method.id, delivery, not reportReasonRecorded)
            return
        end
        local request = requestRuntimes[method.id]
        local body = RpcFrame.readBody(packet, header, method.request.minimumEncodedBytes,
            method.request.maximumEncodedBytes, method.request.maximumAdmissionBytes,
            method.request.maximumReferences, references.n)
        if body == nil then
            count("invalidPayload", nil, method.id, delivery, not reportReasonRecorded)
            return
        end
        local decoded = table.pack(request.decodeRequest(body, table.unpack(references, 1, references.n)))
        if decoded[1] ~= true then
            count("invalidPayload", nil, method.id, delivery, not reportReasonRecorded)
            return
        end
        validatedTraffic(method.id, delivery, buffer.len(body)
            + references.n * ByteUnits.REFERENCE_BYTES)
        if refusalCode ~= nil then
            rememberInbound(header.sessionGuid, header.callId)
            sendInboundResponse(method, header, refusalKindForError(refusalCode), nil, nil)
            return
        end

        local lease = {
            active = true,
            callId = header.callId,
            methodId = method.id,
            sessionGuid = header.sessionGuid,
        }
        local active = inboundActiveRequests[header.sessionGuid]
        if active == nil then
            active = {}
            inboundActiveRequests[header.sessionGuid] = active
        end
        active[header.callId] = lease
        inboundRequestCount += 1
        inboundMethodCounts[method.id] = (inboundMethodCounts[method.id] or 0) + 1
        rememberInbound(header.sessionGuid, header.callId)

        count("dispatched")
        local invocation = table.pack(pcall(listener.handler, table.unpack(decoded, 2, decoded.n)))
        if state ~= "Started" or not lease.active then
            releaseInboundRequest(lease)
            return
        end
        local kind, body, referencesOut
        if not invocation[1] then
            count("handlerErrors", nil, method.id, delivery)
            kind = 3
        elseif invocation.n ~= 2 then
            count("handlerErrors", nil, method.id, delivery)
            kind = 4
        else
            local encoded = table.pack(request.encodeResponse(invocation[2]))
            if encoded[1] == true then
                kind, body = 2, encoded[2]
                referencesOut = table.create(encoded.n - 2)
                referencesOut.n = encoded.n - 2
                for index = 1, referencesOut.n do referencesOut[index] = encoded[index + 2] end
            else
                count("handlerErrors", nil, method.id, delivery)
                kind = 4
            end
        end
        sendInboundResponse(method, header, kind, body, referencesOut)
        releaseInboundRequest(lease)
    end

    for name, method in compiled.requests do
        local direction = method.direction or "ClientToServer"
        local version = method.envelopeVersion or 1
        local requestRuntime = {
            encodeRequest = Frame.compile(method.request, "encode"),
            decodeRequest = Frame.compile(method.request, "decode"),
            decodeResponse = Frame.compile(method.response, "decode"),
            encodeResponse = Frame.compile(method.response, "encode"),
        }
        requestRuntimes[method.id] = requestRuntime
        if direction == "ServerToClient" and method.refusals == true and inboundRefusalBucket == nil then
            inboundRefusalBucket = TokenBucket.new(8, 8)
        end
        if direction == "ServerToClient" then
            requests[name] = table.freeze({
                Connect = function(_, handler)
                    if state == "Destroyed" or state == "Disconnected" then
                        return nil, Definition.error(state)
                    end
                    if type(handler) ~= "function" then return nil, Definition.error("InvalidHandler") end
                    if inboundRequestListeners[method.id] ~= nil then
                        return nil, Definition.error("AlreadyConnected")
                    end
                    local listener = { active = true, handler = handler }
                    inboundRequestListeners[method.id] = listener
                    return table.freeze({ Disconnect = function()
                        if inboundRequestListeners[method.id] == listener then
                            listener.active = false
                            listener.handler = nil
                            inboundRequestListeners[method.id] = nil
                        end
                    end }), nil
                end,
            })
        else
            requests[name] = table.freeze({
                Request = function(_, timeoutSeconds, ...)
                    if state == "Destroyed" or state == "Disconnected" then
                        return nil, Definition.error(state)
                    end
                    if state ~= "Started" then return nil, Definition.error("NotStarted") end
                    if type(timeoutSeconds) ~= "number" or not (timeoutSeconds > 0 and timeoutSeconds <= 60) then
                        return nil, Definition.error("InvalidOptions")
                    end
                    if pendingCount >= 8 or (pendingMethodCounts[method.id] or 0) >= (method.concurrency or 1) then
                        return nil, Definition.error("RequestLimit")
                    end
                    if callIdCounter >= MAXIMUM_CALL_ID then
                        return nil, Definition.error("RequestIdExhausted")
                    end
                    if not checkTransport() then return nil, Definition.error("Disconnected") end
                    local encoded = table.pack(requestRuntime.encodeRequest(...))
                    if encoded[1] ~= true then return nil, Definition.error("InvalidPayload") end
                    local encodedBody = encoded[2]
                    local referenceCount = encoded.n - 2
                    if buffer.len(encodedBody) + referenceCount * RpcFrame.REFERENCE_BYTES
                        > (method.request.maximumAdmissionBytes or 8_148)
                        or not InstanceRefs.scopeArguments(nil, encodedBody,
                            table.unpack(encoded, 3, encoded.n)) then
                        return nil, Definition.error("InvalidPayload")
                    end
                    local callId = callIdCounter + 1
                    local packet = RpcFrame.wrap(1, method.id, callId, rpcSessionGuid, encodedBody,
                        false, version, referenceCount)
                    if packet == nil then return nil, Definition.error("InvalidPayload") end
                    local endpointBytes = buffer.len(encodedBody)
                        + referenceCount * ByteUnits.REFERENCE_BYTES
                    local deadline = rpcNow() + timeoutSeconds
                    callIdCounter = callId
                    local record = {
                        callId = callId,
                        methodId = method.id,
                        deadline = deadline,
                        readClock = rpcNow,
                        decodeResponse = requestRuntime.decodeResponse,
                        settled = false,
                        result = nil,
                        timer = nil,
                        waiterToken = nil,
                        waiterThread = nil,
                    }
                    pendingById[callId] = record
                    pendingMethodCounts[method.id] = (pendingMethodCounts[method.id] or 0) + 1
                    pendingCount += 1
                    record.settle = function(_, result) return settlePending(record, result) end
                    PendingRequests.arm(record)
                    if state ~= "Started" or not checkTransport() then
                        settlePending(record, PendingRequests.failure("Disconnected"))
                        return nil, Definition.error("Disconnected")
                    end
                    if referenceCount > 0 and not InstanceRefs.scopeArguments(nil, encodedBody,
                        table.unpack(encoded, 3, encoded.n)) then
                        settlePending(record, PendingRequests.failure("InvalidPayload"))
                        return nil, Definition.error("InvalidPayload")
                    end
                    if diagnosticsActive and diagnostics.traffic ~= nil then
                        Diagnostics.recordSubmitted(diagnostics, method.id, "Reliable", endpointBytes)
                    end
                    local ok = pcall(remote.FireServer, remote, 0, packet,
                        table.unpack(encoded, 3, encoded.n))
                    if not ok then
                        count("transportFailures", nil, method.id, "Reliable")
                        settlePending(record, PendingRequests.failure("TransportFailure"))
                        if state == "Started" then checkTransport() end
                        return nil, Definition.error("TransportFailure")
                    end
                    count("sendHandoffs")
                    if diagnosticsActive and diagnostics.traffic ~= nil then
                        Diagnostics.recordSentSingle(diagnostics, method.id, "Reliable",
                            buffer.len(packet) + referenceCount * ByteUnits.REFERENCE_BYTES,
                            endpointBytes, 1, 1)
                    end
                    return PendingRequests.handle(record), nil
                end,
            })
        end
    end

    receiveRpc = function(delivery, packet, ...)
        local sidecarCount = select("#", ...)
        local header = RpcFrame.peek(packet, false, compiled.outboundBytes ~= nil, sidecarCount)
        if header == nil then
            count("invalidPayload", nil, nil, delivery)
            return
        end
        local method = compiled.requestsById[header.methodId]
        if delivery ~= "Reliable" then
            count("wrongChannel", nil, if method == nil then nil else method.id, delivery)
            return
        end
        if method == nil then
            count("invalidEndpoint", nil, nil, delivery)
            return
        end
        observedMethod(method.id, delivery, header)
        if (header.envelopeVersion or 1) ~= (method.envelopeVersion or 1) then
            count("invalidPayload", nil, method.id, delivery)
            return
        end
        local direction = method.direction or "ClientToServer"
        if header.kind == 1 then
            if direction ~= "ServerToClient" then
                count("invalidEndpoint", nil, method.id, delivery)
                return
            end
            if header.referencesValid == false or sidecarCount > RpcFrame.MAXIMUM_REFERENCES then
                count("invalidPayload", nil, method.id, delivery)
                return
            end
            local references = table.pack(...)
            handleInboundRequest(delivery, method, header, packet, references)
            return
        end
        if direction ~= "ClientToServer" then
            count("invalidEndpoint", nil, method.id, delivery)
            return
        end
        if rpcSessionGuid == nil or header.sessionGuid ~= rpcSessionGuid then
            count("invalidEndpoint", nil, method.id, delivery)
            return
        end
        local record = pendingById[header.callId]
        if record == nil or record.methodId ~= header.methodId then
            count("invalidEndpoint", nil, method.id, delivery)
            return
        end
        if rpcNow() >= record.deadline then
            record:settle(PendingRequests.failure("RequestTimeout"))
            return
        end
        if header.referencesValid == false then
            count("invalidPayload", nil, method.id, delivery)
            if header.envelopeVersion == 2 then
                record:settle(PendingRequests.failure("InvalidResponse"))
            end
            return
        end
        if header.kind == 3 then
            validatedTraffic(method.id, delivery, 0)
            record:settle(PendingRequests.failure("HandlerFailure"))
            return
        elseif header.kind == 4 then
            validatedTraffic(method.id, delivery, 0)
            record:settle(PendingRequests.failure("InvalidResponse"))
            return
        elseif header.kind == 5 then
            validatedTraffic(method.id, delivery, 0)
            record:settle(PendingRequests.failure("OutboundRateLimited"))
            return
        elseif header.kind == 6 or header.kind == 7 or header.kind == 8 then
            if method.refusals ~= true then
                count("invalidPayload", nil, method.id, delivery)
                return
            end
            validatedTraffic(method.id, delivery, 0)
            record:settle(PendingRequests.failure(if header.kind == 6 then "Busy"
                elseif header.kind == 7 then "NoListener" else "EndpointRateLimited"))
            return
        elseif header.kind ~= 2 then
            count("invalidPayload", nil, method.id, delivery)
            return
        end
        local references = table.pack(...)
        if not InstanceRefs.scopeArguments(nil, packet, table.unpack(references, 1, references.n)) then
            count("invalidPayload", nil, method.id, delivery)
            if header.envelopeVersion == 2 then
                record:settle(PendingRequests.failure("InvalidResponse"))
            end
            return
        end
        local response = method.response
        local body = RpcFrame.readBody(packet, header, response.minimumEncodedBytes,
            response.maximumEncodedBytes, response.maximumAdmissionBytes, response.maximumReferences,
            references.n)
        if body == nil then
            count("invalidPayload", nil, method.id, delivery)
            if header.envelopeVersion == 2 then
                record:settle(PendingRequests.failure("InvalidResponse"))
            end
            return
        end
        local decoded = table.pack(record.decodeResponse(body,
            table.unpack(references, 1, references.n)))
        if decoded[1] ~= true then
            count("invalidPayload", nil, method.id, delivery)
            if header.envelopeVersion == 2 then
                record:settle(PendingRequests.failure("InvalidResponse"))
            end
            return
        end
        validatedTraffic(method.id, delivery, buffer.len(body)
            + references.n * ByteUnits.REFERENCE_BYTES)
        if rpcNow() >= record.deadline then
            record:settle(PendingRequests.failure("RequestTimeout"))
            return
        end
        record:settle(table.freeze({ ok = true, value = decoded[2] }))
    end

    local function dispatch(receiver, eventCounters, endpointId, delivery, contentBytes, valid, ...)
        if not valid then
            count("invalidPayload", eventCounters, endpointId, delivery)
            return
        end
        validatedTraffic(endpointId, delivery, contentBytes)
        local handler = receiver.handler
        receiver.busy = true
        if receiver.once then
            receiver.handler = nil
            receiver.connection = nil
            receiver.once = false
            updateReadinessListener(receiver.id, false)
        end
        count("dispatched", eventCounters)
        local ok = pcall(handler, ...)
        if not ok and state == "Started" then
            count("handlerErrors", eventCounters, endpointId, delivery)
        end
        receiver.busy = false
    end

    local function receive(delivery, endpointId, ...)
        if state == "Starting" then
            if endpointId == 0 then observedTraffic(delivery, endpointId, ...) end
            if endpointId == 0 and compiled.hasOrderedClientToServer and transportValid() then
                receiveEndpointZero(delivery, ...)
            end
            return
        end
        if state ~= "Started" or not checkTransport() then
            return
        end
        count("received")
        local observedBytes = observedTraffic(delivery, endpointId, ...)
        if endpointId == 0 then
            receiveEndpointZero(delivery, ...)
            return
        end
        local event = Frame.resolve(compiled, "ServerToClient", endpointId)
        if event == nil then
            count("invalidEndpoint", nil, knownEndpointId(endpointId), delivery)
            return
        end
        local eventCounters = diagnostics.byId[event.id]
        if event.delivery ~= delivery then
            count("wrongChannel", eventCounters, event.id, delivery)
            return
        end
        local receiver = receivers[event.id]
        if receiver.handler == nil then
            count("noListener", eventCounters, event.id, delivery)
            return
        end
        if receiver.busy then
            count("busy", eventCounters, event.id, delivery)
            return
        end
        if event.ordered then
            local argumentCount = select("#", ...)
            if argumentCount < 1 or argumentCount > InstanceRefs.MAXIMUM_REFERENCES + 1 then
                count("invalidPayload", eventCounters, event.id, delivery)
                return
            end
            local packet = select(1, ...)
            local references = if argumentCount > 1 then table.pack(select(2, ...)) else nil
            local header = OrderedFrame.peek(event, endpointId, packet, references)
            if header == nil then
                count("invalidPayload", eventCounters, event.id, delivery)
                return
            end
            if header.generation ~= 0 then
                count("stale", eventCounters, event.id, delivery)
                return
            end
            local previous = orderedReceiveHighWater[event.id]
            local difference = if previous == nil then 1 else (header.sequence - previous) % MAXIMUM_ORDERED_COUNTER
            if previous ~= nil and (difference == 0 or difference >= MAXIMUM_ORDERED_COUNTER / 2) then
                count("stale", eventCounters, event.id, delivery)
                return
            end
            local values = table.pack(OrderedFrame.decode(event, packet, header, receiver.validate, references))
            if values[1] ~= true then
                count("invalidPayload", eventCounters, event.id, delivery)
                return
            end
            orderedReceiveHighWater[event.id] = header.sequence
            dispatch(receiver, eventCounters, event.id, delivery,
                if observedBytes == nil then nil else observedBytes - 8,
                table.unpack(values, 1, values.n))
            return
        end
        dispatch(receiver, eventCounters, event.id, delivery, observedBytes, receiver.validate(...))
    end

    local function start()
        if state == "Destroyed" or state == "Disconnected" then
            return false, Definition.error(state)
        end
        if state == "Starting" or state == "Started" then
            return false, Definition.error("AlreadyStarted")
        end
        if activeSession ~= nil then
            stop("Destroyed")
            return false, Definition.error("AlreadyStarted")
        end
        state = "Starting"
        activeSession = identity
        local token = {}
        attempt = token
        local deadline = os.clock() + timeout

        local function waitForOrderedInitialization(pending)
            if pending.generation ~= nil then
                return if os.clock() < deadline then nil else "StartupTimeout"
            end
            local remaining = deadline - os.clock()
            if remaining <= 0 then return "StartupTimeout" end
            local thread = coroutine.running()
            local timer = nil
            local finished, waiting = false, false
            local function finish(code)
                if finished then return end
                finished = true
                pending.finish = nil
                cancelWait = nil
                if timer ~= nil then
                    task.cancel(timer)
                    timer = nil
                end
                pending.waitError = code
                if waiting then task.defer(thread) end
            end
            pending.finish = finish
            cancelWait = function() finish("Destroyed") end
            timer = task.delay(remaining, function()
                timer = nil
                finish("StartupTimeout")
            end)
            if pending.generation ~= nil then finish(nil) end
            if not finished then
                waiting = true
                coroutine.yield()
            end
            if attempt ~= pending.attempt then return "Destroyed" end
            return pending.waitError
        end

        local function discover(parent, name, className)
            if attempt ~= token then
                return nil, "Destroyed"
            end
            local child = parent:FindFirstChild(name)
            if child == nil then
                local remaining = deadline - os.clock()
                if remaining <= 0 then
                    return nil, "StartupTimeout"
                end
                local thread = coroutine.running()
                local connection, timer = nil, nil
                local finished, waiting = false, false
                local function finish(found)
                    if finished then return end
                    finished = true
                    cancelWait = nil
                    if connection then connection:Disconnect() end
                    if timer then
                        task.cancel(timer)
                        timer = nil
                    end
                    child = found
                    if waiting then task.defer(thread) end
                end
                cancelWait = finish
                connection = parent.ChildAdded:Connect(function(added)
                    if added.Name == name then finish(added) end
                end)
                timer = task.delay(remaining, function()
                    timer = nil
                    finish(nil)
                end)
                -- Subscribe before rechecking so an arriving child cannot be missed.
                local found = parent:FindFirstChild(name)
                if found then finish(found) end
                if not finished then
                    waiting = true
                    coroutine.yield()
                end
                if attempt ~= token then
                    return nil, "Destroyed"
                end
            end
            if child == nil then
                return nil, "StartupTimeout"
            end
            if child.ClassName ~= className or child.Name ~= name or child.Parent ~= parent then
                return nil, "RemoteOwnershipConflict"
            end
            return child, nil
        end

        local ok, failure = pcall(function()
            storage = game:GetService("ReplicatedStorage")
            local code
            root, code = discover(storage, "RelayRemotes", "Folder")
            if code then return code end
            descriptor, code = discover(root, "Definition", "StringValue")
            if code then return code end
            remote, code = discover(root, "Reliable", "RemoteEvent")
            if code then return code end
            if compiled.hasUnreliable then
                unreliableRemote, code = discover(root, "Unreliable", "UnreliableRemoteEvent")
                if code then return code end
            end
            if not transportValid(false) or not uniqueRoot() then
                return "RemoteOwnershipConflict"
            end
            if descriptor.Value ~= compiled.descriptor then
                return "DefinitionMismatch"
            end
            if attempt ~= token then
                return "Destroyed"
            end

            local function observe(signal, callback)
                table.insert(connections, signal:Connect(callback))
            end
            local function lost()
                if state == "Started" then
                    stop("Disconnected")
                end
            end
            local function storageChanged(child)
                if state ~= "Started" then return end
                if child.Parent == storage then
                    watchStorageSibling(child)
                else
                    unwatchStorageSibling(child)
                end
                if child == root or not uniqueRoot() then
                    lost()
                else
                    checkTransport()
                end
            end
            observe(remote.OnClientEvent, function(endpointId, ...)
                receive("Reliable", endpointId, ...)
            end)
            if unreliableRemote ~= nil then
                observe(unreliableRemote.OnClientEvent, function(endpointId, ...)
                    receive("Unreliable", endpointId, ...)
                end)
            end
            observe(storage.ChildAdded, storageChanged)
            observe(storage.ChildRemoved, storageChanged)
            for _, child in storage:GetChildren() do
                watchStorageSibling(child)
            end
            observe(root.ChildAdded, lost)
            observe(root.ChildRemoved, lost)
            local ownedInstances = { root, descriptor, remote }
            if unreliableRemote ~= nil then
                table.insert(ownedInstances, unreliableRemote)
            end
            for _, instance in ownedInstances do
                observe(instance.AncestryChanged, function(child, parent)
                    if state == "Started" and ((child == root and parent ~= storage)
                        or ((child == descriptor or child == remote or child == unreliableRemote)
                            and parent ~= root)) then
                        lost()
                    end
                end)
                observe(instance:GetPropertyChangedSignal("Name"), lost)
                observe(instance.Destroying, lost)
            end
            observe(descriptor:GetPropertyChangedSignal("Value"), lost)
            if attempt ~= token then
                return "Destroyed"
            end
            if not transportValid() or not uniqueRoot() then
                return "RemoteOwnershipConflict"
            end
            if os.clock() >= deadline then
                return "StartupTimeout"
            end
            if next(compiled.requests) ~= nil or readinessCompiled ~= nil then
                local guidOk, guid = pcall(function()
                    return game:GetService("HttpService"):GenerateGUID(false)
                end)
                if not guidOk then
                    return "TransportFailure"
                end
                rpcSessionGuid = canonicalGuid(guid)
                if rpcSessionGuid == nil then
                    return "TransportFailure"
                end
            end
            if readinessCompiled ~= nil then
                readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
                readinessRevision = 1
                readinessMask = buildReadinessMask()
                readinessExhausted = false
            end
            if compiled.hasOrderedClientToServer then
                local guidOk, guid = pcall(function()
                    return game:GetService("HttpService"):GenerateGUID(false)
                end)
                if not guidOk then
                    return "TransportFailure"
                end
                local clientGuid = canonicalGuid(guid)
                if clientGuid == nil then
                    return "TransportFailure"
                end
                local hello = OrderedFrame.hello(clientGuid)
                if hello == nil then
                    return "TransportFailure"
                end
                local pending = { attempt = token, clientGuid = clientGuid, generation = nil, helloSent = false }
                orderedInitAttempt = pending
                pending.helloSent = true
                local helloOk = pcall(remote.FireServer, remote, 0, hello)
                if not helloOk then
                    count("transportFailures", nil, nil, "Reliable")
                    return "TransportFailure"
                end
                count("sendHandoffs")
                sentControl("Reliable", hello)
                code = waitForOrderedInitialization(pending)
                if code ~= nil then
                    return code
                end
                if attempt ~= token then
                    return "Destroyed"
                end
                orderedGeneration = pending.generation
                orderedInitAttempt = nil
                if not transportValid() or not uniqueRoot() then
                    return "RemoteOwnershipConflict"
                end
                if os.clock() >= deadline then
                    return "StartupTimeout"
                end
            end
            state = "Started"
            attempt = nil
            return nil
        end)

        if not ok or failure ~= nil then
            stop("Destroyed")
            return false, Definition.error(if ok then failure else "TransportFailure")
        end
        if readinessCompiled ~= nil then
            local handedOff, handoffError = handoffReadiness(ReadinessFrame.hello())
            if not handedOff then
                if handoffError.code == "TransportFailure" and state == "Started" then
                    stop("Destroyed")
                end
                return false, handoffError
            end
            if state ~= "Started" then
                return false, Definition.error(state)
            end
        end
        return true, nil
    end

    local function inFlight()
        if state ~= "Started" then
            return 0
        end
        local count = inboundRequestCount
        for _, receiver in receivers do
            if receiver.busy then
                count += 1
            end
        end
        return count
    end

    local function refreshReadiness(_, forceChallenge)
        if state == "Destroyed" or state == "Disconnected" then
            return false, Definition.error(state)
        end
        if state ~= "Started" then
            return false, Definition.error("NotStarted")
        end
        if forceChallenge ~= nil and type(forceChallenge) ~= "boolean" then
            return false, Definition.error("InvalidOptions")
        end
        if readinessCompiled == nil then
            return false, Definition.error("ReadinessDisabled")
        end
        if readinessExhausted then
            return false, Definition.error("ReadinessExhausted")
        end
        if forceChallenge == true or readinessHeldGeneration == nil then
            readinessHeldGeneration = nil
            return handoffReadiness(ReadinessFrame.hello())
        end
        local packet = ReadinessFrame.ack(readinessServerGuid, readinessHeldGeneration,
            rpcSessionGuid, readinessRevision, readinessMask, readinessCompiled.count)
        if packet == nil then
            return false, Definition.error("InvalidPayload")
        end
        return handoffReadiness(packet)
    end

    local function destroyClient()
        if state == "Destroyed" then
            return
        end
        local packet, transport
        if state == "Started" and readinessCompiled ~= nil and not readinessExhausted
            and readinessHeldGeneration ~= nil and readinessServerGuid ~= nil and rpcSessionGuid ~= nil then
            local ok, valid = pcall(function()
                return transportValid() and uniqueRoot()
            end)
            if ok and valid then
                packet = ReadinessFrame.close(readinessServerGuid, readinessHeldGeneration, rpcSessionGuid)
                transport = remote
            end
        end
        stop("Destroyed")
        if packet ~= nil and transport ~= nil then
            local ok = pcall(transport.FireServer, transport, 0, packet)
            count(if ok then "sendHandoffs" else "transportFailures")
        end
    end

    return table.freeze({
        events = table.freeze(events),
        requests = table.freeze(requests),
        Start = start,
        CreateBatch = function(_, flushAfter)
            return createBatch(flushAfter)
        end,
        CreateBatcher = function(_, flushAfter)
            return createBatch(flushAfter, true)
        end,
        CreatePacedBatcher = function(_, interval, options)
            return createPacedBatcher(interval, options)
        end,
        CreateState = function(_, flushAfter)
            return createState(flushAfter)
        end,
        Destroy = function()
            destroyClient()
        end,
        RefreshReadiness = refreshReadiness,
        GetDiagnostics = function()
            return Diagnostics.snapshot(diagnostics, state, inFlight())
        end,
    }), nil
end

return table.freeze({ create = create })
