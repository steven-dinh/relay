local Definition = require(if script then script.Parent.Definition else "./Definition")
local PendingRequests = require(if script then script.Parent.internal.PendingRequests else "./internal/PendingRequests")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")
local TokenBucket = require(if script then script.Parent.internal.TokenBucket else "./internal/TokenBucket")
local Diagnostics = require(if script then script.Parent.internal.Diagnostics else "./internal/Diagnostics")
local RpcFrame = require(if script then script.Parent.internal.RpcFrame else "./internal/RpcFrame")
local ReadinessFrame = require(if script then script.Parent.internal.ReadinessFrame else "./internal/ReadinessFrame")
local OrderedFrame = require(if script then script.Parent.internal.OrderedFrame else "./internal/OrderedFrame")
local Batch = require(if script then script.Parent.internal.Batch else "./internal/Batch")
local BatchFrame = require(if script then script.Parent.internal.BatchFrame else "./internal/BatchFrame")
local StateQueue = require(if script then script.Parent.internal.StateQueue else "./internal/StateQueue")
local Streams = require(if script then script.Parent.internal.Streams else "./internal/Streams")
local InstanceRefs = require(if script then script.Parent.internal.InstanceRefs else "./internal/InstanceRefs")

local activeSession = nil

local failure = Definition.error
local MAXIMUM_AUDIENCE = 1024
local MAXIMUM_READINESS_GENERATION = 4_294_967_295
local MAXIMUM_ORDERED_GENERATION = 4_294_967_295
local MAXIMUM_ORDERED_COUNTER = 4_294_967_296
local MAXIMUM_READINESS_BYTES = 90
local MAXIMUM_BATCH_RECORDS = 32
local MAXIMUM_NATIVE_ARGUMENTS = 8
local MAXIMUM_CALL_ID = 4_294_967_295

local function disconnect(connection)
    connection:Disconnect()
end

local function onlyKeys(value, firstKey, secondKey, thirdKey, fourthKey)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    for key in value do
        if key ~= firstKey and key ~= secondKey and key ~= thirdKey and key ~= fourthKey then
            return false
        end
    end
    return true
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function stateQueueOptions(options)
    if options == nil then return true, false end
    if not onlyKeys(options, "deferOutbound") then return false, false end
    local deferOutbound = rawget(options, "deferOutbound")
    if deferOutbound ~= nil and type(deferOutbound) ~= "boolean" then return false, false end
    return true, deferOutbound == true
end

local function validRate(value, capacityLimit, refillLimit)
    if not onlyKeys(value, "capacity", "refillPerSecond") then
        return false
    end
    local capacity, refill = value.capacity, value.refillPerSecond
    return type(capacity) == "number" and capacity % 1 == 0
        and capacity >= 1 and capacity <= capacityLimit
        and type(refill) == "number" and refill > 0 and refill <= refillLimit
end

local function validOptions(options, compiled)
    if not onlyKeys(options, "inboundRate", "instanceRoot")
        or not onlyKeys(options.inboundRate, "perPlayer", "aggregate", "endpoints", "bytes") then
        return false
    end
    if compiled.hasReferences then
        if not InstanceRefs.isLiveRoot(options.instanceRoot) then
            return false
        end
    elseif options.instanceRoot ~= nil then
        return false
    end
    local rate = options.inboundRate
    if not validRate(rate.perPlayer, 4096, 2048) or not validRate(rate.aggregate, 32768, 16384)
        or rate.aggregate.capacity < rate.perPlayer.capacity
        or rate.aggregate.refillPerSecond < rate.perPlayer.refillPerSecond then
        return false
    end

    local bytes = rate.bytes
    if bytes ~= nil then
        if not onlyKeys(bytes, "perPlayer", "aggregate")
            or not validRate(bytes.perPlayer, 33_554_432, 16_777_216)
            or not validRate(bytes.aggregate, 268_435_456, 134_217_728)
            or bytes.aggregate.capacity < bytes.perPlayer.capacity
            or bytes.aggregate.refillPerSecond < bytes.perPlayer.refillPerSecond then
            return false
        end
    end

    local endpoints = rate.endpoints
    if endpoints == nil then
        return true
    end
    if type(endpoints) ~= "table" or getmetatable(endpoints) ~= nil then
        return false
    end
    local count = 0
    for id, endpointRate in endpoints do
        count += 1
        if count > 64 or type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 65_535
            or not validRate(endpointRate, 4096, 2048) then
            return false
        end
        local event = compiled.byId[id]
        local request = compiled.requestsById[id]
        if (event == nil or event.direction ~= "ClientToServer")
            and (request == nil or (request.direction or "ClientToServer") ~= "ClientToServer") then
            return false
        end
    end
    return true
end

local function estimateInboundBytes(endpointId, capacity, ...)
    if type(endpointId) ~= "number" or endpointId < 0 or endpointId > 65_535 or endpointId % 1 ~= 0 then
        return capacity + 1
    end

    local argumentCount = select("#", ...)
    if argumentCount > 0 then
        local payload = select(1, ...)
        if typeof(payload) == "buffer" then
            local length = buffer.len(payload)
            local format = if length > 0 then buffer.readu8(payload, 0) else nil
            local referenceCount
            if format == InstanceRefs.FORMAT or endpointId == 0 and format == 5 then
                if length < 4 then return capacity + 1 end
                referenceCount = buffer.readu8(payload, 3)
            elseif endpointId ~= 0 and format == 6 then
                if length < 12 then return capacity + 1 end
                referenceCount = buffer.readu8(payload, 11)
            elseif endpointId == 0 and format == RpcFrame.V2_WIRE_TAG and length >= 48
                and buffer.readu8(payload, 44) == InstanceRefs.FORMAT then
                referenceCount = buffer.readu8(payload, 47)
            end
            if referenceCount ~= nil then
                if referenceCount > InstanceRefs.MAXIMUM_REFERENCES
                    or argumentCount ~= referenceCount + 1 then
                    return capacity + 1
                end
                for index = 2, argumentCount do
                    local reference = select(index, ...)
                    if reference ~= nil and typeof(reference) ~= "Instance" then
                        return capacity + 1
                    end
                end
                local bytes = length + referenceCount * InstanceRefs.REFERENCE_BYTES
                return if bytes > capacity then capacity + 1 else bytes
            end
        end
    end
    if argumentCount == 1 then
        local payload = ...
        if typeof(payload) == "buffer" then
            local bytes = buffer.len(payload)
            if bytes < 1 then
                bytes = 1
            end
            return if bytes > capacity then capacity + 1 else bytes
        end
    end
    if argumentCount > MAXIMUM_NATIVE_ARGUMENTS then
        return capacity + 1
    end

    local bytes = 3
    for index = 1, argumentCount do
        local value = select(index, ...)
        local kind = typeof(value)
        if kind == "boolean" then
            bytes += 1
        elseif kind == "number" then
            bytes += 8
        elseif kind == "Vector2" then
            bytes += 8
        elseif kind == "Vector3" then
            bytes += 12
        elseif kind == "Color3" then
            bytes += 12
        elseif kind == "CFrame" then
            bytes += 96
        elseif kind == "string" then
            bytes += 2 + #value
        elseif kind == "buffer" then
            bytes += buffer.len(value)
        else
            return capacity + 1
        end
        if bytes > capacity then
            return capacity + 1
        end
    end
    return bytes
end

local function audienceLength(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end
    local count, maximum = 0, 0
    for key, player in value do
        count += 1
        if count > MAXIMUM_AUDIENCE or type(key) ~= "number" or key % 1 ~= 0
            or key < 1 or key > MAXIMUM_AUDIENCE
            or typeof(player) ~= "Instance" or player.ClassName ~= "Player" then
            return nil
        end
        maximum = math.max(maximum, key)
    end
    -- Positive integer keys with matching maximum/count prove density.
    return if maximum == count then count else nil
end

local function generateServerGuid()
    local ok, value = pcall(function()
        return game:GetService("HttpService"):GenerateGUID(false)
    end)
    if not ok or type(value) ~= "string" then
        return nil
    end
    value = string.lower(value)
    return if ReadinessFrame.challenge(value, 1) ~= nil then value else nil
end

local function create(definition, options)
    if game == nil or not game:GetService("RunService"):IsServer() then
        return nil, failure("WrongRuntimeSide")
    end
    local compiled = Definition.get(definition)
    if compiled == nil then
        return nil, failure("InvalidDefinition")
    end
    if not validOptions(options, compiled) then
        return nil, failure("InvalidOptions")
    end

    local hasClientRequests, hasServerRequests, hasRefusalMethods = false, false, false
    for _, method in compiled.requests do
        if (method.direction or "ClientToServer") == "ClientToServer" then
            hasClientRequests = true
            if method.refusals == true then hasRefusalMethods = true end
        else
            hasServerRequests = true
        end
    end
    local players = game:GetService("Players")
    local storage = game:GetService("ReplicatedStorage")
    local workspace = nil
    local playerCapacity = options.inboundRate.perPlayer.capacity
    local playerRefill = options.inboundRate.perPlayer.refillPerSecond
    local aggregateCapacity = options.inboundRate.aggregate.capacity
    local aggregateRefill = options.inboundRate.aggregate.refillPerSecond
    local outboundBytes = compiled.outboundBytes
    local state = "Created"
    local identity = {}
    local referenceContext = if compiled.hasReferences then { server = true, root = options.instanceRoot } else nil
    local root, descriptor, remote, unreliableRemote, serverGuid, serverRpcGuid = nil, nil, nil, nil, nil, nil
    local connections, listeners, requestListeners, roster, storageSiblingWatchers = {}, {}, {}, {}, {}
    local orderedSendSequences = {}
    local removed = nil
    local aggregate = nil
    local aggregateBytes = nil
    local inFlight = 0
    local serverRpcCallIdCounter, serverPendingCount = 0, 0
    local serverPendingById = {}
    local aggregateRefusalBucket = nil
    local rpcClockHighWater = -math.huge
    local requestRuntimes = {}
    local batchOwner = nil
    local queueClockHighWater = -math.huge
    local queuedReceivers = {}
    for eventId, event in compiled.queuedById or {} do
        if event.direction == "ClientToServer" then
            queuedReceivers[eventId] = {
                event = event,
                decode = Frame.compile(event, "decode", referenceContext),
            }
        end
    end
    local diagnostics = Diagnostics.create(compiled.events, "Server", options.inboundRate, {
        perPlayerEndpoint = 1,
        perPlayer = 8,
        global = 64,
    }, outboundBytes)

    local function count(name, eventCounters)
        Diagnostics.increment(diagnostics.counters, name)
        if eventCounters ~= nil then
            Diagnostics.increment(eventCounters, name)
        end
    end

    local function rpcNow()
        local now = os.clock()
        if now > rpcClockHighWater then rpcClockHighWater = now end
        return rpcClockHighWater
    end

    local function settleServerPending(record, result)
        return PendingRequests.settle(record, result, function()
            if serverPendingById[record.callId] ~= record then return false end
            serverPendingById[record.callId] = nil
            serverPendingCount -= 1
            local entry = record.entry
            if entry.serverPendingById[record.callId] == record then
                entry.serverPendingById[record.callId] = nil
                entry.serverPendingCount -= 1
                local methodCount = entry.serverPendingByMethod[record.methodId] - 1
                entry.serverPendingByMethod[record.methodId] = if methodCount == 0 then nil else methodCount
            end
            return true
        end)
    end

    local function settleServerPendingForPlayer(player, code)
        local pending = table.clone(serverPendingById)
        for _, record in pending do
            if record.player == player then
                settleServerPending(record, PendingRequests.failure(code))
            end
        end
    end

    local function settleAllServerPending(code)
        local pending = table.clone(serverPendingById)
        for _, record in pending do
            settleServerPending(record, PendingRequests.failure(code))
        end
    end

    for _, method in compiled.requests do
        requestRuntimes[method.id] = {
            decodeRequest = Frame.compile(method.request, "decode", referenceContext),
            encodeRequest = Frame.compile(method.request, "encode", referenceContext),
            decodeResponse = Frame.compile(method.response, "decode", referenceContext),
            encodeResponse = Frame.compile(method.response, "encode", referenceContext),
        }
    end
    if hasRefusalMethods then
        aggregateRefusalBucket = TokenBucket.new(64, 64)
    end

    local endpointRates = diagnostics.inboundRate.endpoints
    local hasEndpointRates = endpointRates ~= nil and next(endpointRates) ~= nil
    local byteRates = diagnostics.inboundRate.bytes
    local hasByteRates = byteRates ~= nil

    local function takeEndpointRate(entry, eventId, timestamp, eventCounters)
        local buckets = entry.endpointBuckets
        local bucket = if buckets == nil then nil else buckets[eventId]
        if bucket ~= nil and not bucket:take(timestamp) then
            count("endpointRate", eventCounters)
            return false
        end
        return true
    end

    local function currentPlayer(player)
        return typeof(player) == "Instance" and player.ClassName == "Player" and player.Parent == players
    end

    local function reserveOutbound(targets, bytes, singlePlayer)
        if outboundBytes == nil then return true end
        local timestamp = os.clock()
        local targetCount = if singlePlayer then 1 else #targets
        local eligible = 0
        for index = 1, targetCount do
            local player = if singlePlayer then targets else targets[index]
            if currentPlayer(player) then
                local entry = roster[player]
                local bucket = if entry ~= nil and entry.active then entry.outboundBucket else nil
                if bucket == nil or not bucket:canTake(timestamp, bytes) then
                    count("outboundByteRejected")
                    return false
                end
                eligible += 1
            end
        end
        for index = 1, targetCount do
            local player = if singlePlayer then targets else targets[index]
            if currentPlayer(player) then
                local bucket = roster[player].outboundBucket
                -- No yield separates preflight from debit, so each checked take must succeed.
                bucket:take(timestamp, bytes)
            end
        end
        Diagnostics.add(diagnostics.counters, "outboundBytesCharged", bytes * eligible)
        return true
    end

    local function intact()
        -- Cached classes are fixed at construction; only mutable topology needs rechecking.
        if root == nil or descriptor == nil or remote == nil
            or root.Name ~= "RelayRemotes" or root.Parent ~= storage
            or descriptor.Name ~= "Definition" or descriptor.Parent ~= root
            or remote.Name ~= "Reliable" or remote.Parent ~= root
            or descriptor.Value ~= compiled.descriptor then
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

    local function destroy(transportLost)
        if state == "Destroyed" then
            return
        end
        if transportLost and state == "Started" then
            count("transportLosses")
        end
        state = "Destroyed"
        settleAllServerPending(if transportLost then "Disconnected" else "Destroyed")
        if referenceContext ~= nil then
            referenceContext.root = nil
        end
        if batchOwner ~= nil then
            batchOwner.alive = false
            batchOwner.terminalError = failure("Destroyed")
            Streams.destroy(batchOwner)
            Batch.destroy(batchOwner)
            StateQueue.destroy(batchOwner)
        end
        if activeSession == identity then
            activeSession = nil
        end
        for _, listener in listeners do
            listener.active = false
            listener.handler = nil
            listener.validate = nil
        end
        table.clear(listeners)
        for _, listener in requestListeners do
            listener.active = false
            listener.handler = nil
            listener.decodeRequest = nil
            listener.encodeResponse = nil
        end
        table.clear(requestListeners)
        for _, connection in connections do
            pcall(disconnect, connection)
        end
        table.clear(connections)
        for _, connection in storageSiblingWatchers do
            pcall(disconnect, connection)
        end
        table.clear(storageSiblingWatchers)
        for _, entry in roster do
            entry.active = false
            table.clear(entry.slots)
            if entry.orderedHighWater ~= nil then
                table.clear(entry.orderedHighWater)
            end
            if hasClientRequests then
                table.clear(entry.activeRequests)
                table.clear(entry.replayGuids)
                table.clear(entry.replayCallIds)
                entry.replayCursor = 1
            end
            if entry.requestCounts ~= nil then table.clear(entry.requestCounts) end
            if entry.serverPendingById ~= nil then table.clear(entry.serverPendingById) end
            if entry.serverPendingByMethod ~= nil then table.clear(entry.serverPendingByMethod) end
            entry.inFlight = 0
            if entry.endpointBuckets ~= nil then
                table.clear(entry.endpointBuckets)
                entry.endpointBuckets = nil
            end
            entry.byteBucket = nil
            entry.outboundBucket = nil
            if entry.readiness ~= nil then
                entry.readiness.phase = "Closed"
                entry.readiness.generation = 0
                entry.readiness.clientGuid = nil
                entry.readiness.revision = 0
                entry.readiness.mask = nil
            end
        end
        table.clear(roster)
        table.clear(orderedSendSequences)
        removed = nil
        aggregate = nil
        aggregateBytes = nil
        aggregateRefusalBucket = nil
        inFlight = 0
        serverPendingCount = 0
        table.clear(serverPendingById)

        local function destroyEmpty(instance)
            if instance == nil then
                return true
            end
            local ok, destroyed = pcall(function()
                if instance:FindFirstChildWhichIsA("Instance") ~= nil then
                    return false
                end
                instance:Destroy()
                return true
            end)
            return ok and destroyed
        end
        local descriptorGone = destroyEmpty(descriptor)
        local remoteGone = destroyEmpty(remote)
        local unreliableRemoteGone = destroyEmpty(unreliableRemote)
        if descriptorGone and remoteGone and unreliableRemoteGone then
            destroyEmpty(root)
        end
        root, descriptor, remote, unreliableRemote, serverGuid, serverRpcGuid = nil, nil, nil, nil, nil, nil
    end

    local function watchStorageSibling(child)
        if child == root or child.Parent ~= storage or storageSiblingWatchers[child] ~= nil then
            return
        end
        storageSiblingWatchers[child] = child:GetPropertyChangedSignal("Name"):Connect(function()
            if state == "Started" and child.Parent == storage and child.Name == "RelayRemotes" then
                destroy(true)
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

    local function checkIntegrity()
        if state ~= "Started" then
            return false
        end
        local ok, valid = pcall(intact)
        if not ok or not valid then
            destroy(true)
            return false
        end
        return true
    end

    local function addPlayer(player)
        if (state ~= "Starting" and state ~= "Started") or not currentPlayer(player)
            or (removed ~= nil and removed[player]) or roster[player] ~= nil then
            return
        end
        roster[player] = {
            active = true,
            bucket = TokenBucket.new(playerCapacity, playerRefill),
            slots = {},
            inFlight = 0,
            requestCounts = if hasClientRequests then {} else nil,
            activeRequests = if hasClientRequests then {} else nil,
            replayGuids = if hasClientRequests then table.create(64) else nil,
            replayCallIds = if hasClientRequests then table.create(64) else nil,
            replayCursor = if hasClientRequests then 1 else nil,
            refusalBucket = if hasRefusalMethods then TokenBucket.new(8, 8) else nil,
            serverPendingById = if hasServerRequests then {} else nil,
            serverPendingCount = 0,
            serverPendingByMethod = if hasServerRequests then {} else nil,
            readiness = if compiled.readiness ~= nil then {
                phase = "Idle",
                generation = 0,
                clientGuid = nil,
                revision = 0,
                mask = nil,
            } else nil,
            orderedGeneration = 0,
            orderedHighWater = if compiled.hasOrderedClientToServer then {} else nil,
            endpointBuckets = if hasEndpointRates then {} else nil,
            byteBucket = if hasByteRates then TokenBucket.new(byteRates.perPlayer.capacity,
                byteRates.perPlayer.refillPerSecond) else nil,
            outboundBucket = if outboundBytes == nil then nil else TokenBucket.new(outboundBytes.capacity,
                outboundBytes.refillPerSecond),
        }
        if hasEndpointRates then
            for id, rate in endpointRates do
                roster[player].endpointBuckets[id] = TokenBucket.new(rate.capacity, rate.refillPerSecond)
            end
        end
    end

    local function removePlayer(player)
        if state ~= "Starting" and state ~= "Started" then
            return
        end
        if removed ~= nil then
            removed[player] = true
        end
        if batchOwner ~= nil then
            Streams.prune(batchOwner, player)
            Batch.prune(batchOwner, player)
            StateQueue.prune(batchOwner, player)
        end
        local entry = roster[player]
        if entry ~= nil then
            settleServerPendingForPlayer(player, "Disconnected")
            entry.active = false
            inFlight -= entry.inFlight
            entry.inFlight = 0
            table.clear(entry.slots)
            if hasClientRequests then
                table.clear(entry.activeRequests)
                table.clear(entry.replayGuids)
                table.clear(entry.replayCallIds)
                entry.replayCursor = 1
            end
            if entry.requestCounts ~= nil then table.clear(entry.requestCounts) end
            if entry.serverPendingById ~= nil then table.clear(entry.serverPendingById) end
            if entry.serverPendingByMethod ~= nil then table.clear(entry.serverPendingByMethod) end
            entry.refusalBucket = nil
            if entry.readiness ~= nil then
                entry.readiness.phase = "Closed"
                entry.readiness.generation = 0
                entry.readiness.clientGuid = nil
                entry.readiness.revision = 0
                entry.readiness.mask = nil
            end
            if entry.orderedHighWater ~= nil then
                table.clear(entry.orderedHighWater)
                entry.orderedHighWater = nil
            end
            entry.orderedGeneration = nil
            if entry.endpointBuckets ~= nil then
                table.clear(entry.endpointBuckets)
                entry.endpointBuckets = nil
            end
            entry.byteBucket = nil
            entry.outboundBucket = nil
            roster[player] = nil
        end
    end

    local function disconnectListener(eventId, listener)
        if not listener.active then
            return
        end
        listener.active = false
        listener.handler = nil
        listener.validate = nil
        if listeners[eventId] == listener then
            listeners[eventId] = nil
        end
    end

    local function dispatch(entry, event, listener, player, eventCounters, valid, ...)
        if not valid then
            count("invalidPayload", eventCounters)
            return
        end
        local handler = listener.handler
        entry.slots[event.id] = true
        entry.inFlight += 1
        inFlight += 1
        if listener.once then
            disconnectListener(event.id, listener)
        end
        count("dispatched", eventCounters)
        local ok = pcall(handler, player, ...)
        if not ok and state == "Started" then
            count("handlerErrors", eventCounters)
        end
        if state == "Started" and entry.active and roster[player] == entry then
            entry.slots[event.id] = nil
            entry.inFlight -= 1
            inFlight -= 1
        end
    end

    local function replayed(entry, sessionGuid, callId)
        local active = entry.activeRequests[sessionGuid]
        if active ~= nil and active[callId] ~= nil then
            return true
        end
        for index = 1, #entry.replayGuids do
            if entry.replayGuids[index] == sessionGuid and entry.replayCallIds[index] == callId then
                return true
            end
        end
        return false
    end

    local function rememberRequest(entry, sessionGuid, callId)
        local cursor = entry.replayCursor
        entry.replayGuids[cursor] = sessionGuid
        entry.replayCallIds[cursor] = callId
        entry.replayCursor = if cursor == 64 then 1 else cursor + 1
    end

    local function releaseRequest(entry, player, methodId, sessionGuid, callId, lease)
        if state ~= "Started" or not entry.active or roster[player] ~= entry then
            return
        end
        if not lease.active then return end
        lease.active = false
        entry.inFlight -= 1
        inFlight -= 1
        local methodCount = entry.requestCounts[methodId] - 1
        entry.requestCounts[methodId] = if methodCount == 0 then nil else methodCount
        local active = entry.activeRequests[sessionGuid]
        if active ~= nil and active[callId] == lease then
            active[callId] = nil
            if next(active) == nil then
                entry.activeRequests[sessionGuid] = nil
            end
        end
    end

    local function sendRequestResponse(entry, player, method, header, kind, body, references)
        if state ~= "Started" or not entry.active or roster[player] ~= entry or player.Parent ~= players
            or not checkIntegrity() then
            return false
        end
        local referenceCount = if references == nil then 0 else references.n
        local version = method.envelopeVersion or 1
        if body ~= nil and not InstanceRefs.scopeArguments(referenceContext, body,
            table.unpack(references, 1, referenceCount)) then
            count("invalidPayload")
            kind, body, references, referenceCount = 4, nil, nil, 0
        end
        local packet = RpcFrame.wrap(kind, method.id, header.callId, header.sessionGuid, body,
            kind == 5, version, referenceCount)
        if packet == nil then
            count("invalidPayload")
            return false
        end
        if outboundBytes ~= nil and not reserveOutbound(player,
            buffer.len(packet) + referenceCount * RpcFrame.REFERENCE_BYTES, true) then
            if kind >= 6 and kind <= 8 then return false end
            packet = RpcFrame.wrap(5, method.id, header.callId, header.sessionGuid, nil, true, version)
            if packet == nil then return false end
            if version ~= 1 and not reserveOutbound(player, buffer.len(packet), true) then return false end
            references, referenceCount = nil, 0
        end
        if referenceCount > 0 and not InstanceRefs.scopeArguments(referenceContext, body,
            table.unpack(references, 1, referenceCount)) then
            count("invalidPayload")
            return false
        end
        local ok
        if referenceCount == 0 then
            ok = pcall(remote.FireClient, remote, player, 0, packet)
        else
            ok = pcall(remote.FireClient, remote, player, 0, packet,
                table.unpack(references, 1, referenceCount))
        end
        if ok then
            count("sendHandoffs")
        else
            count("transportFailures")
            checkIntegrity()
        end
        return ok
    end

    local function dispatchRequest(entry, player, method, listener, header, valid, ...)
        if valid ~= true then
            count("invalidPayload")
            return
        end
        local methodId = method.id
        local sessionGuid, callId = header.sessionGuid, header.callId
        local handler = listener.handler
        local encodeResponse = listener.encodeResponse
        local lease = { active = true }
        entry.inFlight += 1
        inFlight += 1
        entry.requestCounts[methodId] = (entry.requestCounts[methodId] or 0) + 1
        local active = entry.activeRequests[sessionGuid]
        if active == nil then
            active = {}
            entry.activeRequests[sessionGuid] = active
        end
        active[callId] = lease
        rememberRequest(entry, sessionGuid, callId)

        count("dispatched")
        local invocation = table.pack(pcall(handler, player, ...))
        if state ~= "Started" or not entry.active or roster[player] ~= entry or player.Parent ~= players then
            releaseRequest(entry, player, methodId, sessionGuid, callId, lease)
            return
        end
        local kind, body, references
        if not invocation[1] then
            count("handlerErrors")
            kind = 3
        elseif invocation.n ~= 2 then
            count("handlerErrors")
            kind = 4
        else
            local encoded = table.pack(encodeResponse(invocation[2]))
            if encoded[1] == true then
                kind, body = 2, encoded[2]
                references = table.create(encoded.n - 2)
                references.n = encoded.n - 2
                for index = 1, references.n do references[index] = encoded[index + 2] end
            else
                count("handlerErrors")
                kind = 4
            end
        end

        sendRequestResponse(entry, player, method, header, kind, body, references)
        releaseRequest(entry, player, methodId, sessionGuid, callId, lease)
    end

    local function refusalKindForError(code)
        if code == "Busy" then return 6 end
        if code == "NoListener" then return 7 end
        if code == "EndpointRateLimited" then return 8 end
        return nil
    end

    local function takeRefusalTokens(entry, timestamp)
        if entry.refusalBucket == nil or not entry.refusalBucket:take(timestamp) then return false end
        return aggregateRefusalBucket ~= nil and aggregateRefusalBucket:take(timestamp)
    end

    local function receiveRequest(delivery, player, entry, timestamp, packet, ...)
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        local sidecarCount = select("#", ...)
        local header = RpcFrame.peek(packet, true, outboundBytes ~= nil, sidecarCount)
        if header == nil then
            count("invalidPayload")
            return
        end
        local method = compiled.requestsById[header.methodId]
        if method == nil then
            count("invalidEndpoint")
            return
        end
        if (method.direction or "ClientToServer") ~= "ClientToServer" or header.kind ~= 1 then
            count("invalidEndpoint")
            return
        end
        if (header.envelopeVersion or 1) ~= (method.envelopeVersion or 1) then
            count("invalidPayload")
            return
        end
        local endpointAllowed = not hasEndpointRates
            or takeEndpointRate(entry, method.id, timestamp)
        if replayed(entry, header.sessionGuid, header.callId) then
            count("busy")
            return
        end
        local listener = requestListeners[method.id]
        local refusalCode
        if not endpointAllowed then
            refusalCode = "EndpointRateLimited"
        elseif listener == nil or not listener.active then
            refusalCode = "NoListener"
            count("noListener")
        elseif (entry.requestCounts[method.id] or 0) >= (method.concurrency or 1)
            or entry.inFlight >= 8 or inFlight >= 64 then
            refusalCode = "Busy"
            count("busy")
        end
        if refusalCode ~= nil and method.refusals ~= true then return end
        if refusalCode ~= nil and not takeRefusalTokens(entry, timestamp) then return end

        if sidecarCount > RpcFrame.MAXIMUM_REFERENCES then
            count("invalidPayload")
            return
        end
        local references = table.pack(...)
        if header.referencesValid == false
            or not InstanceRefs.scopeArguments(referenceContext, packet,
                table.unpack(references, 1, references.n)) then
            count("invalidPayload")
            return
        end
        local request = requestRuntimes[method.id]
        local body = RpcFrame.readBody(packet, header, method.request.minimumEncodedBytes,
            method.request.maximumEncodedBytes, method.request.maximumAdmissionBytes,
            method.request.maximumReferences, references.n)
        if body == nil then
            count("invalidPayload")
            return
        end
        local decoded = table.pack(request.decodeRequest(body, table.unpack(references, 1, references.n)))
        if decoded[1] ~= true then
            count("invalidPayload")
            return
        end
        if refusalCode ~= nil then
            rememberRequest(entry, header.sessionGuid, header.callId)
            sendRequestResponse(entry, player, method, header, refusalKindForError(refusalCode))
            return
        end
        dispatchRequest(entry, player, method, listener, header, true,
            table.unpack(decoded, 2, decoded.n))
    end

    local function receiveServerResponse(delivery, player, entry, packet, ...)
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        local sidecarCount = select("#", ...)
        local header = RpcFrame.peek(packet, true, true, sidecarCount)
        if header == nil then
            count("invalidPayload")
            return
        end
        local method = compiled.requestsById[header.methodId]
        if method == nil or (method.direction or "ClientToServer") ~= "ServerToClient" then
            count("invalidEndpoint")
            return
        end
        if (header.envelopeVersion or 1) ~= (method.envelopeVersion or 1) then
            count("invalidPayload")
            return
        end
        if header.kind == 1 then
            count("invalidEndpoint")
            return
        end
        local record = serverPendingById[header.callId]
        if record == nil or record.player ~= player or record.entry ~= entry
            or record.methodId ~= header.methodId or record.sessionGuid ~= header.sessionGuid then
            count("invalidEndpoint")
            return
        end
        if rpcNow() >= record.deadline then
            settleServerPending(record, PendingRequests.failure("RequestTimeout"))
            return
        end
        if sidecarCount > RpcFrame.MAXIMUM_REFERENCES then
            count("invalidPayload")
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        end
        if header.referencesValid == false then
            count("invalidPayload")
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        end
        if header.kind == 3 then
            settleServerPending(record, PendingRequests.failure("HandlerFailure"))
            return
        elseif header.kind == 4 then
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        elseif header.kind == 5 then
            settleServerPending(record, PendingRequests.failure("OutboundRateLimited"))
            return
        elseif header.kind == 6 or header.kind == 7 or header.kind == 8 then
            if method.refusals ~= true then
                count("invalidPayload")
                settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            else
                settleServerPending(record, PendingRequests.failure(if header.kind == 6 then "Busy"
                    elseif header.kind == 7 then "NoListener" else "EndpointRateLimited"))
            end
            return
        elseif header.kind ~= 2 then
            count("invalidPayload")
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        end
        local references = table.pack(...)
        if not InstanceRefs.scopeArguments(referenceContext, packet,
            table.unpack(references, 1, references.n)) then
            count("invalidPayload")
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        end
        local response = method.response
        local body = RpcFrame.readBody(packet, header, response.minimumEncodedBytes,
            response.maximumEncodedBytes, response.maximumAdmissionBytes,
            response.maximumReferences, references.n)
        if body == nil then
            count("invalidPayload")
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        end
        local decoded = table.pack(record.decodeResponse(body,
            table.unpack(references, 1, references.n)))
        if decoded[1] ~= true then
            count("invalidPayload")
            settleServerPending(record, PendingRequests.failure("InvalidResponse"))
            return
        end
        if rpcNow() >= record.deadline then
            settleServerPending(record, PendingRequests.failure("RequestTimeout"))
            return
        end
        settleServerPending(record, table.freeze({ ok = true, value = decoded[2] }))
    end

    local function sendReadinessChallenge(player, entry, generation)
        if state ~= "Started" or roster[player] ~= entry or not entry.active or player.Parent ~= players
            or not checkIntegrity() then
            return
        end
        local packet = ReadinessFrame.challenge(serverGuid, generation)
        if packet == nil then
            return
        end
        local ok = pcall(remote.FireClient, remote, player, 0, packet)
        if state ~= "Started" or activeSession ~= identity then
            return
        end
        if ok then
            count("sendHandoffs")
        else
            count("transportFailures")
            checkIntegrity()
        end
    end

    local function receiveReadiness(player, entry, packet)
        local header = ReadinessFrame.peek(packet, true, compiled.readiness.count)
        if header == nil then
            count("invalidPayload")
            return
        end
        local record = entry.readiness
        if record == nil then
            count("invalidEndpoint")
            return
        end
        if header.kind == 16 then
            if record.phase == "Exhausted" then
                return
            end
            if record.generation >= MAXIMUM_READINESS_GENERATION then
                record.phase = "Exhausted"
                record.clientGuid = nil
                record.revision = 0
                record.mask = nil
                return
            end
            local generation = record.generation + 1
            record.generation = generation
            record.phase = "Offered"
            record.clientGuid = nil
            record.revision = 0
            record.mask = nil
            sendReadinessChallenge(player, entry, generation)
            return
        end
        if header.serverGuid ~= serverGuid or header.generation ~= record.generation then
            return
        end
        if header.kind == 18 then
            if record.phase ~= "Offered" and record.phase ~= "Bound" then
                return
            end
            if record.phase == "Bound" then
                if header.clientGuid ~= record.clientGuid or header.revision < record.revision then
                    return
                end
                if header.revision == record.revision then
                    return
                end
            end
            record.phase = "Bound"
            record.clientGuid = header.clientGuid
            record.revision = header.revision
            record.mask = header.maskString
            return
        end
        if header.kind == 19 and (record.phase == "Offered"
            or (record.phase == "Bound" and header.clientGuid == record.clientGuid)) then
            record.phase = "Closed"
            record.clientGuid = nil
            record.revision = 0
            record.mask = nil
        end
    end

    local function receiveOrderedInitialization(player, entry, packet)
        local clientGuid = OrderedFrame.readHello(packet)
        if clientGuid == nil then
            count("invalidPayload")
            return
        end
        if not compiled.hasOrderedClientToServer then
            count("invalidEndpoint")
            return
        end
        if entry.orderedGeneration >= MAXIMUM_ORDERED_GENERATION then
            return
        end

        local generation = entry.orderedGeneration + 1
        entry.orderedGeneration = generation
        table.clear(entry.orderedHighWater)
        local response = OrderedFrame.initialization(clientGuid, generation)
        if response == nil then
            return
        end
        local ok = pcall(remote.FireClient, remote, player, 0, response)
        if ok then
            count("sendHandoffs")
        else
            count("transportFailures")
            checkIntegrity()
        end
    end

    local function chargeBatchRecords(entry, timestamp, recordCount)
        for _ = 2, recordCount do
            if not entry.bucket:take(timestamp) then
                count("perPlayerRate")
                return false
            end
            if not aggregate:take(timestamp) then
                count("aggregateRate")
                return false
            end
        end
        return true
    end

    local function dispatchBatch(player, entry, rows, tuples)
        for index, row in rows do
            local event = row.event
            local eventId = event.id
            local values = tuples[index]
            tuples[index] = nil
            if state ~= "Started" or not entry.active or roster[player] ~= entry then
                break
            end
            local eventCounters = diagnostics.byId[eventId]
            local listener = listeners[eventId]
            if listener == nil or not listener.active then
                count("noListener", eventCounters)
            elseif entry.slots[eventId] ~= nil or entry.inFlight >= 8 or inFlight >= 64 then
                count("busy", eventCounters)
            else
                local lease = {}
                local handler = listener.handler
                entry.slots[eventId] = lease
                entry.inFlight += 1
                inFlight += 1
                if listener.once then
                    disconnectListener(event.id, listener)
                end
                task.spawn(coroutine.create(function()
                    if state ~= "Started" or not entry.active or roster[player] ~= entry
                        or entry.slots[eventId] ~= lease then
                        return
                    end
                    count("dispatched", eventCounters)
                    local ok = pcall(handler, player, table.unpack(values, 2, values.n))
                    if not ok and state == "Started" then
                        count("handlerErrors", eventCounters)
                    end
                    if state == "Started" and entry.active and roster[player] == entry
                        and entry.slots[eventId] == lease then
                        entry.slots[eventId] = nil
                        entry.inFlight -= 1
                        inFlight -= 1
                    end
                end))
            end
        end
        table.clear(tuples)
    end

    local function receiveBatch(delivery, player, entry, timestamp, packet, kind, references)
        local packetBytes = buffer.len(packet)
        if packetBytes < 3 then
            count("invalidPayload")
            return
        end
        local recordCount = buffer.readu8(packet, 2)
        if recordCount < 1 or recordCount > MAXIMUM_BATCH_RECORDS then
            count("invalidPayload")
            return
        end
        if not chargeBatchRecords(entry, timestamp, recordCount) then
            return
        end

        local limit = if delivery == "Reliable" then 8_192 else 900
        local header = BatchFrame.header(packet, limit, references)
        if header == nil or header.kind ~= kind then
            count("invalidPayload")
            return
        end
        if compiled.queuedById == nil then
            count("invalidEndpoint")
            return
        end

        local metadataError
        local rows = BatchFrame.scan(packet, header, function(eventId)
            local queued = queuedReceivers[eventId]
            if queued == nil then
                metadataError = "invalidEndpoint"
                return nil
            end
            if queued.event.delivery ~= delivery then
                metadataError = "wrongChannel"
                return nil
            end
            if kind == 2 and queued.event.queue ~= "State" then
                metadataError = "invalidEndpoint"
                return nil
            end
            return queued.event
        end, references)
        if rows == nil then
            count(metadataError or "invalidPayload")
            return
        end

        if hasEndpointRates then
            for _, row in rows do
                local event = row.event
                if not takeEndpointRate(entry, event.id, timestamp, diagnostics.byId[event.id]) then
                    return
                end
            end
        end

        local tuples = table.create(#rows)
        for index, row in rows do
            local queued = queuedReceivers[row.event.id]
            local body, localReferences = BatchFrame.readBody(packet, row, references)
            if body == nil then
                count("invalidPayload", diagnostics.byId[row.event.id])
                return
            end
            local values = if localReferences == nil then table.pack(queued.decode(body))
                else table.pack(queued.decode(body, table.unpack(localReferences, 1, localReferences.n)))
            if values[1] ~= true then
                count("invalidPayload", diagnostics.byId[row.event.id])
                return
            end
            tuples[index] = values
        end
        dispatchBatch(player, entry, rows, tuples)
    end

    local function receiveEndpointZero(delivery, player, entry, timestamp, ...)
        local argumentCount = select("#", ...)
        if argumentCount < 1 then
            count("invalidPayload")
            return
        end
        local packet = select(1, ...)
        if typeof(packet) ~= "buffer" then
            count("invalidPayload")
            return
        end
        local length = buffer.len(packet)
        if length < 2 or length > 8_192 then
            count("invalidPayload")
            return
        end
        local format = buffer.readu8(packet, 0)
        if format == 1 then
            if argumentCount ~= 1 then
                count("invalidPayload")
                return
            end
            receiveRequest(delivery, player, entry, timestamp, packet)
            return
        end
        if format == RpcFrame.V2_WIRE_TAG then
            if buffer.readu8(packet, 1) == 1 then
                receiveRequest(delivery, player, entry, timestamp, packet, select(2, ...))
            else
                receiveServerResponse(delivery, player, entry, packet, select(2, ...))
            end
            return
        end
        if format ~= 2 and format ~= 5 then
            count("invalidPayload")
            return
        end
        local kind = buffer.readu8(packet, 1)
        if kind == 1 or kind == 2 then
            if argumentCount > InstanceRefs.MAXIMUM_REFERENCES + 1 then
                count("invalidPayload")
                return
            end
            local references = if argumentCount > 1 then table.pack(select(2, ...)) else nil
            receiveBatch(delivery, player, entry, timestamp, packet, kind, references)
            return
        end
        if argumentCount ~= 1 or format ~= 2 then
            count("invalidPayload")
            return
        end
        if kind == 32 or kind == 33 then
            if length > MAXIMUM_READINESS_BYTES then
                count("invalidPayload")
                return
            end
            if delivery ~= "Reliable" then
                count("wrongChannel")
                return
            end
            if kind ~= 32 or not compiled.hasOrderedClientToServer then
                count("invalidEndpoint")
                return
            end
            receiveOrderedInitialization(player, entry, packet)
            return
        end
        if kind < 16 or kind > 19 then
            count("invalidEndpoint")
            return
        end
        if length > MAXIMUM_READINESS_BYTES then
            count("invalidPayload")
            return
        end
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        if compiled.readiness == nil then
            count("invalidEndpoint")
            return
        end
        receiveReadiness(player, entry, packet)
    end

    local function receive(delivery, player, endpointId, ...)
        if not checkIntegrity() then
            return
        end
        count("received")
        local entry = roster[player]
        -- Roster admission already proves the immutable Instance type and class.
        if entry == nil or not entry.active or player.Parent ~= players then
            count("ineligible")
            return
        end
        local timestamp = os.clock()
        if not entry.bucket:take(timestamp) then
            count("perPlayerRate")
            return
        end
        if not aggregate:take(timestamp) then
            count("aggregateRate")
            return
        end
        if hasByteRates then
            local cost = estimateInboundBytes(endpointId, byteRates.perPlayer.capacity, ...)
            if not entry.byteBucket:take(timestamp, cost) then
                count("perPlayerBytes")
                return
            end
            if not aggregateBytes:take(timestamp, cost) then
                count("aggregateBytes")
                return
            end
        end
        if endpointId == 0 then
            receiveEndpointZero(delivery, player, entry, timestamp, ...)
            return
        end
        local event = Frame.resolve(compiled, "ClientToServer", endpointId)
        if event == nil then
            count("invalidEndpoint")
            return
        end
        local eventCounters = diagnostics.byId[event.id]
        if event.delivery ~= delivery then
            count("wrongChannel")
            return
        end
        local listener = listeners[event.id]
        if hasEndpointRates and not takeEndpointRate(entry, event.id, timestamp, eventCounters) then
            return
        end
        if listener == nil or not listener.active then
            count("noListener", eventCounters)
            return
        end
        -- All three caps are inspected before any reservation changes.
        if entry.slots[event.id] or entry.inFlight >= 8 or inFlight >= 64 then
            count("busy", eventCounters)
            return
        end
        if event.ordered then
            local argumentCount = select("#", ...)
            if argumentCount < 1 or argumentCount > InstanceRefs.MAXIMUM_REFERENCES + 1 then
                count("invalidPayload", eventCounters)
                return
            end
            local packet = select(1, ...)
            local references = if argumentCount > 1 then table.pack(select(2, ...)) else nil
            local header = OrderedFrame.peek(event, endpointId, packet, references)
            if header == nil then
                count("invalidPayload", eventCounters)
                return
            end
            if header.generation == 0 or header.generation ~= entry.orderedGeneration then
                count("stale", eventCounters)
                return
            end
            local previous = entry.orderedHighWater[event.id]
            local difference = if previous == nil then 1 else (header.sequence - previous) % MAXIMUM_ORDERED_COUNTER
            if previous ~= nil and (difference == 0 or difference >= MAXIMUM_ORDERED_COUNTER / 2) then
                count("stale", eventCounters)
                return
            end
            local values = table.pack(OrderedFrame.decode(event, packet, header, listener.validate, references))
            if values[1] ~= true then
                count("invalidPayload", eventCounters)
                return
            end
            entry.orderedHighWater[event.id] = header.sequence
            dispatch(entry, event, listener, player, eventCounters, table.unpack(values, 1, values.n))
            return
        end
        dispatch(entry, event, listener, player, eventCounters, listener.validate(...))
    end

    local function start()
        if state == "Destroyed" then
            return false, failure("Destroyed")
        end
        if state ~= "Created" or activeSession ~= nil then
            return false, failure("AlreadyStarted")
        end
        state = "Starting"
        activeSession = identity
        local startupError = "TransportFailure"
        local ok = pcall(function()
            if compiled.readiness ~= nil then
                serverGuid = generateServerGuid()
                if serverGuid == nil then
                    return
                end
            end
            if hasServerRequests then
                serverRpcGuid = generateServerGuid()
                if serverRpcGuid == nil then return end
            end
            if storage:FindFirstChild("RelayRemotes") ~= nil then
                startupError = "RemoteOwnershipConflict"
                return
            end
            root = Instance.new("Folder")
            root.Name = "RelayRemotes"
            descriptor = Instance.new("StringValue")
            descriptor.Name = "Definition"
            descriptor.Value = compiled.descriptor
            remote = Instance.new("RemoteEvent")
            remote.Name = "Reliable"
            if compiled.hasUnreliable then
                unreliableRemote = Instance.new("UnreliableRemoteEvent")
                unreliableRemote.Name = "Unreliable"
            end
            aggregate = TokenBucket.new(aggregateCapacity, aggregateRefill)
            if hasByteRates then
                aggregateBytes = TokenBucket.new(byteRates.aggregate.capacity, byteRates.aggregate.refillPerSecond)
            end
            removed = {}
            table.insert(connections, players.PlayerAdded:Connect(addPlayer))
            table.insert(connections, players.PlayerRemoving:Connect(removePlayer))
            for _, player in players:GetPlayers() do
                addPlayer(player)
            end
            for player, entry in roster do
                if removed[player] or not currentPlayer(player) then
                    entry.active = false
                    roster[player] = nil
                end
            end
            removed = nil
            table.insert(connections, remote.OnServerEvent:Connect(function(player, endpointId, ...)
                receive("Reliable", player, endpointId, ...)
            end))
            if unreliableRemote ~= nil then
                table.insert(connections, unreliableRemote.OnServerEvent:Connect(function(player, endpointId, ...)
                    receive("Unreliable", player, endpointId, ...)
                end))
            end
            descriptor.Parent = root
            remote.Parent = root
            if unreliableRemote ~= nil then
                unreliableRemote.Parent = root
            end
            root.Parent = storage
            -- Attach after our own non-yielding parenting, so deferred startup
            -- notifications cannot be mistaken for later integrity violations.
            local function observe()
                if state == "Started" then
                    destroy(true)
                end
            end
            local ownedInstances = { root, descriptor, remote }
            if unreliableRemote ~= nil then
                table.insert(ownedInstances, unreliableRemote)
            end
            for _, instance in ownedInstances do
                table.insert(connections, instance.AncestryChanged:Connect(observe))
                table.insert(connections, instance:GetPropertyChangedSignal("Name"):Connect(observe))
                table.insert(connections, instance.Destroying:Connect(observe))
            end
            table.insert(connections, descriptor:GetPropertyChangedSignal("Value"):Connect(observe))
            table.insert(connections, root.ChildAdded:Connect(observe))
            table.insert(connections, root.ChildRemoved:Connect(observe))
            local function observeStorage(child)
                if state == "Started" then
                    if child.Parent == storage then
                        watchStorageSibling(child)
                    else
                        unwatchStorageSibling(child)
                    end
                    local checked, unique = pcall(uniqueRoot)
                    if not checked or not unique then
                        destroy(true)
                    else
                        checkIntegrity()
                    end
                end
            end
            table.insert(connections, storage.ChildAdded:Connect(observeStorage))
            table.insert(connections, storage.ChildRemoved:Connect(observeStorage))
            for _, child in storage:GetChildren() do
                watchStorageSibling(child)
            end
            if not intact() or not uniqueRoot() then
                startupError = "RemoteOwnershipConflict"
                return
            end
            state = "Started"
        end)
        if not ok or state ~= "Started" then
            destroy()
            return false, failure(if ok then startupError else "TransportFailure")
        end
        return true, nil
    end

    local function connect(event, validate, handler, once)
        local eventId = event.id
        if state == "Destroyed" then
            return nil, failure("Destroyed")
        end
        if type(handler) ~= "function" then
            return nil, failure("InvalidHandler")
        end
        if listeners[eventId] ~= nil then
            return nil, failure("AlreadyConnected")
        end
        local listener = { active = true, handler = handler, validate = validate, once = once }
        listeners[eventId] = listener
        return table.freeze({ Disconnect = function()
            disconnectListener(eventId, listener)
        end }), nil
    end

    local function fire(event, targeted, player, ...)
        local transport = if event.delivery == "Unreliable" then unreliableRemote else remote
        if targeted then
            transport:FireClient(player, event.id, ...)
        else
            transport:FireAllClients(event.id, ...)
        end
    end

    local function sendValidated(event, targeted, player, valid, ...)
        if not valid then
            return false, failure("InvalidPayload")
        end
        if not checkIntegrity() then
            return false, failure("Destroyed")
        end
        if event.hasReferences
            and not InstanceRefs.scopeArguments(referenceContext, ...) then
            return false, failure("InvalidPayload")
        end
        local targets
        if outboundBytes ~= nil then
            if targeted then
                targets = player
            else
                local ok, actual = pcall(players.GetPlayers, players)
                if not ok or type(actual) ~= "table" or #actual > MAXIMUM_AUDIENCE then
                    count("outboundByteRejected")
                    return false, failure("OutboundRateLimited")
                end
                targets = table.create(#actual)
                local seen = {}
                for index = 1, #actual do
                    local recipient = actual[index]
                    if typeof(recipient) ~= "Instance" or recipient.ClassName ~= "Player" then
                        count("outboundByteRejected")
                        return false, failure("OutboundRateLimited")
                    end
                    if recipient.Parent == players then
                        if seen[recipient] then
                            count("outboundByteRejected")
                            return false, failure("OutboundRateLimited")
                        end
                        seen[recipient] = true
                        local entry = roster[recipient]
                        if entry == nil or not entry.active or entry.outboundBucket == nil then
                            count("outboundByteRejected")
                            return false, failure("OutboundRateLimited")
                        end
                        targets[#targets + 1] = recipient
                    end
                end
            end
        end
        if event.ordered then
            local encodedPayload = select(1, ...)
            local references = if event.hasReferences then table.pack(select(2, ...)) else nil
            local referenceCount = if references == nil then 0 else references.n
            local sequence = ((orderedSendSequences[event.id] or 0) + 1) % MAXIMUM_ORDERED_COUNTER
            local packet = OrderedFrame.wrap(event, encodedPayload, 0, sequence, references)
            if packet == nil then
                return false, failure("InvalidPayload")
            end
            if outboundBytes ~= nil and not reserveOutbound(targets,
                buffer.len(packet) + referenceCount * InstanceRefs.REFERENCE_BYTES, targeted) then
                return false, failure("OutboundRateLimited")
            end
            orderedSendSequences[event.id] = sequence
            local ok = if references == nil then pcall(fire, event, targeted, player, packet)
                else pcall(fire, event, targeted, player, packet, table.unpack(references, 1, referenceCount))
            if not ok then
                count("transportFailures", diagnostics.byId[event.id])
                checkIntegrity()
                return false, failure("TransportFailure")
            end
            count(if targeted then "sendHandoffs" else "broadcastHandoffs", diagnostics.byId[event.id])
            return true, nil
        end
        if outboundBytes ~= nil and not reserveOutbound(targets,
            estimateInboundBytes(event.id, outboundBytes.capacity, ...), targeted) then
            return false, failure("OutboundRateLimited")
        end
        local ok = pcall(fire, event, targeted, player, ...)
        if not ok then
            count("transportFailures", diagnostics.byId[event.id])
            checkIntegrity()
            return false, failure("TransportFailure")
        end
        count(if targeted then "sendHandoffs" else "broadcastHandoffs", diagnostics.byId[event.id])
        return true, nil
    end

    local function send(event, validate, targeted, player, ...)
        if state == "Destroyed" then
            return false, failure("Destroyed")
        end
        if state ~= "Started" then
            return false, failure("NotStarted")
        end
        if targeted and not currentPlayer(player) then
            return false, failure("InvalidPlayer")
        end
        return sendValidated(event, targeted, player, validate(...))
    end

    local function snapshotAudience(value, excluded)
        local count = audienceLength(value)
        if count == nil then
            return nil
        end
        local seen, targets = {}, {}
        local targetCount = 0
        for index = 1, count do
            local player = value[index]
            if not seen[player] then
                seen[player] = true
                if not excluded then
                    local entry = roster[player]
                    if entry ~= nil and entry.active and player.Parent == players then
                        targetCount += 1
                        targets[targetCount] = player
                    end
                end
            end
        end
        if excluded then
            for player, entry in roster do
                if not seen[player] and entry.active and player.Parent == players then
                    targetCount += 1
                    if targetCount > MAXIMUM_AUDIENCE then
                        return nil
                    end
                    targets[targetCount] = player
                end
            end
        end
        return targets
    end

    local function sendAudienceValidated(event, targets, valid, ...)
        if not valid then
            return false, failure("InvalidPayload"), 0
        end
        if not checkIntegrity() then
            return false, failure("Destroyed"), 0
        end
        if #targets == 0 then return true, nil, 0 end
        local eventCounters = diagnostics.byId[event.id]
        local orderedPacket
        local references = if event.ordered and event.hasReferences then table.pack(select(2, ...)) else nil
        local referenceCount = if references == nil then 0 else references.n
        local sequence
        if event.ordered and #targets > 0 then
            local encodedPayload = ...
            sequence = ((orderedSendSequences[event.id] or 0) + 1) % MAXIMUM_ORDERED_COUNTER
            orderedPacket = OrderedFrame.wrap(event, encodedPayload, 0, sequence, references)
            if orderedPacket == nil then
                return false, failure("InvalidPayload"), 0
            end
        end
        if outboundBytes ~= nil then
            if event.hasReferences and not InstanceRefs.scopeArguments(referenceContext, ...) then
                return false, failure("InvalidPayload"), 0
            end
            local bytes = if event.ordered
                then buffer.len(orderedPacket) + referenceCount * InstanceRefs.REFERENCE_BYTES
                else estimateInboundBytes(event.id, outboundBytes.capacity, ...)
            if not reserveOutbound(targets, bytes) then
                return false, failure("OutboundRateLimited"), 0
            end
        end
        if sequence ~= nil then orderedSendSequences[event.id] = sequence end
        local sentCount = 0
        for _, player in targets do
            local entry = roster[player]
            if entry ~= nil and entry.active and player.Parent == players then
                if event.hasReferences and not InstanceRefs.scopeArguments(referenceContext, ...) then
                    return false, failure("InvalidPayload"), sentCount
                end
                local ok = if event.ordered
                    then if references == nil then pcall(fire, event, true, player, orderedPacket)
                        else pcall(fire, event, true, player, orderedPacket, table.unpack(references, 1, referenceCount))
                    else pcall(fire, event, true, player, ...)
                if not ok then
                    count("transportFailures", eventCounters)
                    checkIntegrity()
                    return false, failure("TransportFailure"), sentCount
                end
                sentCount += 1
                count("sendHandoffs", eventCounters)
                if not checkIntegrity() then
                    return false, failure("Destroyed"), sentCount
                end
            end
        end
        return true, nil, sentCount
    end

    local function sendAudience(event, validate, excluded, value, ...)
        if state == "Destroyed" then
            return false, failure("Destroyed"), 0
        end
        if state ~= "Started" then
            return false, failure("NotStarted"), 0
        end
        local targets = snapshotAudience(value, excluded)
        if targets == nil then
            return false, failure("InvalidAudience"), 0
        end
        return sendAudienceValidated(event, targets, validate(...))
    end

    local batchEvents = {}
    for name, event in compiled.events do
        local queued = if compiled.queuedById == nil then nil else compiled.queuedById[event.id]
        if event.direction == "ServerToClient" and queued ~= nil then
            batchEvents[name] = {
                id = queued.id,
                delivery = queued.delivery,
                queue = queued.queue,
                encode = Frame.compile(queued, "encode", referenceContext),
            }
        end
    end
    batchOwner = {
        alive = true,
        terminalError = nil,
        streams = {},
        events = batchEvents,
        batch = nil,
        flushOwner = nil,
        check = function()
            if state == "Destroyed" then
                return false, batchOwner.terminalError or failure("Destroyed")
            end
            if state ~= "Started" then
                return false, failure("NotStarted")
            end
            if not checkIntegrity() then
                return false, failure("Destroyed")
            end
            return true, nil
        end,
        now = function()
            local now = os.clock()
            if now > queueClockHighWater then
                queueClockHighWater = now
            end
            return queueClockHighWater
        end,
        serverNow = function()
            if workspace == nil then workspace = game:GetService("Workspace") end
            local ok, timestamp = pcall(workspace.GetServerTimeNow, workspace)
            if not ok or not finite(timestamp) then return nil end
            return timestamp
        end,
        playerActive = function(player)
            if not currentPlayer(player) then return false end
            local entry = roster[player]
            return entry ~= nil and entry.active
        end,
        streamHandoff = function(stream, packet, references)
            local targeted = stream.target ~= nil
            if targeted and not batchOwner.playerActive(stream.target) then
                return false, failure("InvalidPlayer")
            end
            if references == nil then
                return sendValidated(stream.event, targeted, stream.target, true, packet)
            end
            return sendValidated(stream.event, targeted, stream.target, true, packet,
                table.unpack(references, 1, references.n))
        end,
        admit = if outboundBytes == nil then nil else function(bytes, targets, requireSinglePlayer)
            if requireSinglePlayer then
                local player = if type(targets) == "table" and #targets == 1 then targets[1] else nil
                local entry = if player == nil then nil else roster[player]
                if not currentPlayer(player) or entry == nil or not entry.active or entry.outboundBucket == nil then
                    count("outboundByteRejected")
                    return false
                end
            end
            return reserveOutbound(targets, bytes)
        end,
        resolveBroadcastAudience = function()
            local ok, actual = pcall(players.GetPlayers, players)
            if state ~= "Started" or not batchOwner.alive then
                return nil, batchOwner.terminalError or failure("Destroyed")
            end
            if not ok then return nil, failure("InvalidAudience") end
            local actualCount = audienceLength(actual)
            if actualCount == nil then return nil, failure("InvalidAudience") end

            local targets = table.create(actualCount)
            local seen = {}
            for index = 1, actualCount do
                local player = actual[index]
                if not currentPlayer(player) or seen[player] then
                    return nil, failure("InvalidAudience")
                end
                seen[player] = true
                local entry = roster[player]
                if entry == nil or not entry.active or (outboundBytes ~= nil and entry.outboundBucket == nil) then
                    if outboundBytes ~= nil then
                        count("outboundByteRejected")
                        return nil, failure("OutboundRateLimited")
                    end
                    return nil, failure("InvalidAudience")
                end
                targets[index] = player
            end
            return targets, nil
        end,
        retryAfter = if outboundBytes == nil then nil else function(bytes, targets)
            if type(targets) ~= "table" or #targets ~= 1 then return nil end
            local player = targets[1]
            if not currentPlayer(player) then return nil end
            local entry = roster[player]
            local bucket = if entry ~= nil and entry.active then entry.outboundBucket else nil
            if bucket == nil then return nil end
            return bucket:retryAfter(os.clock(), bytes)
        end,
        handoff = function(delivery, packet, targets, references)
            if state ~= "Started" or not batchOwner.alive then
                return false, batchOwner.terminalError or failure("Destroyed"), 0
            end
            if not checkIntegrity() then
                return false, failure("Destroyed"), 0
            end
            local transport = if delivery == "Unreliable" then unreliableRemote else remote
            local handoffs = 0
            for _, player in targets do
                local entry = roster[player]
                if entry ~= nil and entry.active and player.Parent == players then
                    if references ~= nil and not InstanceRefs.scopeArguments(referenceContext, packet,
                        table.unpack(references, 1, references.n)) then
                        return false, failure("InvalidPayload"), handoffs
                    end
                    local ok = if references == nil then pcall(transport.FireClient, transport, player, 0, packet)
                        else pcall(transport.FireClient, transport, player, 0, packet,
                            table.unpack(references, 1, references.n))
                    if not ok then
                        count("transportFailures")
                        checkIntegrity()
                        return false, failure("TransportFailure"), handoffs
                    end
                    handoffs += 1
                    count("sendHandoffs")
                    if not checkIntegrity() then
                        return false, failure("Destroyed"), handoffs
                    end
                end
            end
            return true, nil, handoffs
        end,
        broadcastHandoff = function(delivery, packet, references)
            if state ~= "Started" or not batchOwner.alive then
                return false, batchOwner.terminalError or failure("Destroyed"), 0
            end
            if not checkIntegrity() then
                return false, failure("Destroyed"), 0
            end
            if references ~= nil and not InstanceRefs.scopeArguments(referenceContext, packet,
                table.unpack(references, 1, references.n)) then
                return false, failure("InvalidPayload"), 0
            end
            local transport = if delivery == "Unreliable" then unreliableRemote else remote
            local ok = if references == nil then pcall(transport.FireAllClients, transport, 0, packet)
                else pcall(transport.FireAllClients, transport, 0, packet,
                    table.unpack(references, 1, references.n))
            if not ok then
                count("transportFailures")
                checkIntegrity()
                return false, failure("TransportFailure"), 0
            end
            count("broadcastHandoffs")
            if not checkIntegrity() then
                return false, failure("Destroyed"), 1
            end
            return true, nil, 1
        end,
    }

    local function createBatch(recipients, flushAfter, reusable, broadcast)
        if state == "Destroyed" then
            return nil, failure("Destroyed")
        end
        if state ~= "Started" then
            return nil, failure("NotStarted")
        end
        if type(flushAfter) ~= "number" or not (flushAfter > 0 and flushAfter <= 0.1) then
            return nil, failure("InvalidOptions")
        end
        local targets
        if not broadcast then
            targets = snapshotAudience(recipients, false)
            if targets == nil then
                return nil, failure("InvalidAudience")
            end
        end
        return Batch.create(batchOwner, targets, flushAfter, reusable, broadcast)
    end

    local function createState(recipients, flushAfter, options, broadcast)
        if state == "Destroyed" then
            return nil, failure("Destroyed")
        end
        if state ~= "Started" then
            return nil, failure("NotStarted")
        end
        local validOptions, deferOutbound = stateQueueOptions(options)
        if not validOptions or (deferOutbound and outboundBytes == nil) then
            return nil, failure("InvalidOptions")
        end
        if type(flushAfter) ~= "number" or not (flushAfter > 0 and flushAfter <= 0.1) then
            return nil, failure("InvalidOptions")
        end
        local targets
        if not broadcast then
            targets = snapshotAudience(recipients, false)
            if targets == nil then
                return nil, failure("InvalidAudience")
            end
        end
        if deferOutbound and (targets == nil or #targets ~= 1) then
            return nil, failure("InvalidAudience")
        end
        return StateQueue.create(batchOwner, targets, flushAfter, deferOutbound, broadcast)
    end

    local events = {}
    local requests = {}
    for name, method in compiled.requests do
        local direction = method.direction or "ClientToServer"
        local requestRuntime = requestRuntimes[method.id]
        if direction == "ClientToServer" then
            requests[name] = table.freeze({
                Connect = function(_, handler)
                    if state == "Destroyed" then
                        return nil, failure("Destroyed")
                    end
                    if type(handler) ~= "function" then
                        return nil, failure("InvalidHandler")
                    end
                    if requestListeners[method.id] ~= nil then
                        return nil, failure("AlreadyConnected")
                    end
                    local listener = {
                        active = true,
                        handler = handler,
                        decodeRequest = requestRuntime.decodeRequest,
                        encodeResponse = requestRuntime.encodeResponse,
                    }
                    requestListeners[method.id] = listener
                    return table.freeze({ Disconnect = function()
                        if requestListeners[method.id] == listener then
                            listener.active = false
                            listener.handler = nil
                            listener.decodeRequest = nil
                            listener.encodeResponse = nil
                            requestListeners[method.id] = nil
                        end
                    end }), nil
                end,
            })
        else
            requests[name] = table.freeze({
                Request = function(_, player, timeoutSeconds, ...)
                    if state == "Destroyed" then return nil, failure("Destroyed") end
                    if state ~= "Started" then return nil, failure("NotStarted") end
                    if not currentPlayer(player) then return nil, failure("InvalidPlayer") end
                    local entry = roster[player]
                    if entry == nil or not entry.active then return nil, failure("InvalidPlayer") end
                    if type(timeoutSeconds) ~= "number" or not (timeoutSeconds > 0 and timeoutSeconds <= 60) then
                        return nil, failure("InvalidOptions")
                    end
                    if entry.serverPendingCount >= 8 or serverPendingCount >= 64
                        or (entry.serverPendingByMethod[method.id] or 0) >= (method.concurrency or 1) then
                        return nil, failure("RequestLimit")
                    end
                    if serverRpcCallIdCounter >= MAXIMUM_CALL_ID then
                        return nil, failure("RequestIdExhausted")
                    end
                    if not checkIntegrity() then return nil, failure("Destroyed") end

                    local encoded = table.pack(requestRuntime.encodeRequest(...))
                    if encoded[1] ~= true then return nil, failure("InvalidPayload") end
                    local encodedBody = encoded[2]
                    local referenceCount = encoded.n - 2
                    if buffer.len(encodedBody) + referenceCount * RpcFrame.REFERENCE_BYTES
                        > (method.request.maximumAdmissionBytes or 8_148)
                        or not InstanceRefs.scopeArguments(referenceContext, encodedBody,
                            table.unpack(encoded, 3, encoded.n)) then
                        return nil, failure("InvalidPayload")
                    end
                    local callId = serverRpcCallIdCounter + 1
                    local packet = RpcFrame.wrap(1, method.id, callId, serverRpcGuid, encodedBody,
                        false, method.envelopeVersion or 1, referenceCount)
                    if packet == nil then return nil, failure("InvalidPayload") end
                    local admissionBytes = buffer.len(packet) + referenceCount * RpcFrame.REFERENCE_BYTES
                    if outboundBytes ~= nil and not reserveOutbound(player, admissionBytes, true) then
                        return nil, failure("OutboundRateLimited")
                    end
                    if not checkIntegrity() or not InstanceRefs.scopeArguments(referenceContext, encodedBody,
                        table.unpack(encoded, 3, encoded.n)) then
                        return nil, failure(if state == "Started" then "InvalidPayload" else "Destroyed")
                    end

                    serverRpcCallIdCounter = callId
                    local deadline = rpcNow() + timeoutSeconds
                    local record = {
                        callId = callId,
                        methodId = method.id,
                        player = player,
                        entry = entry,
                        sessionGuid = serverRpcGuid,
                        deadline = deadline,
                        readClock = rpcNow,
                        decodeResponse = requestRuntime.decodeResponse,
                        settled = false,
                        result = nil,
                        timer = nil,
                        waiterToken = nil,
                        waiterThread = nil,
                    }
                    serverPendingById[callId] = record
                    entry.serverPendingById[callId] = record
                    entry.serverPendingCount += 1
                    entry.serverPendingByMethod[method.id] = (entry.serverPendingByMethod[method.id] or 0) + 1
                    serverPendingCount += 1
                    record.settle = function(_, result) return settleServerPending(record, result) end
                    PendingRequests.arm(record)

                    if state ~= "Started" or not checkIntegrity() then
                        settleServerPending(record, PendingRequests.failure("Destroyed"))
                        return nil, failure("Destroyed")
                    end
                    if referenceCount > 0 and not InstanceRefs.scopeArguments(referenceContext, encodedBody,
                        table.unpack(encoded, 3, encoded.n)) then
                        settleServerPending(record, PendingRequests.failure("InvalidPayload"))
                        return nil, failure("InvalidPayload")
                    end

                    local ok
                    if referenceCount == 0 then
                        ok = pcall(remote.FireClient, remote, player, 0, packet)
                    else
                        ok = pcall(remote.FireClient, remote, player, 0, packet,
                            table.unpack(encoded, 3, encoded.n))
                    end
                    if not ok then
                        count("transportFailures")
                        settleServerPending(record, PendingRequests.failure("TransportFailure"))
                        if state == "Started" then checkIntegrity() end
                        return nil, failure("TransportFailure")
                    end
                    count("sendHandoffs")
                    return PendingRequests.handle(record), nil
                end,
            })
        end
    end
    for name, event in compiled.events do
        local validate
        if event.usesCodec and event.queue ~= nil then
            validate = if event.direction == "ClientToServer"
                then queuedReceivers[event.id].decode else batchEvents[name].encode
        else
            local mode = if event.usesCodec then
                (if event.direction == "ClientToServer" then "decode" else "encode") else nil
            validate = Frame.compile(if event.ordered then OrderedFrame.codecEvent(event) else event,
                mode, referenceContext)
        end
        if event.direction == "ClientToServer" then
            events[name] = table.freeze({
                Connect = function(_, handler)
                    return connect(event, validate, handler, false)
                end,
                Once = function(_, handler)
                    return connect(event, validate, handler, true)
                end,
            })
        else
            local readinessByteIndex, readinessBitValue
            if compiled.readiness ~= nil then
                local bit = compiled.readiness.byId[event.id]
                readinessByteIndex = math.floor(bit / 8) + 1
                readinessBitValue = 2 ^ (bit % 8)
            end
            local eventHandle = {
                Send = function(_, player, ...)
                    return send(event, validate, true, player, ...)
                end,
                Broadcast = function(_, ...)
                    return send(event, validate, false, nil, ...)
                end,
                SendTo = function(_, recipients, ...)
                    return sendAudience(event, validate, false, recipients, ...)
                end,
                SendExcept = function(_, excluded, ...)
                    return sendAudience(event, validate, true, excluded, ...)
                end,
                GetReadyPlayers = function()
                    if state == "Destroyed" then
                        return nil, failure("Destroyed")
                    end
                    if state ~= "Started" then
                        return nil, failure("NotStarted")
                    end
                    if compiled.readiness == nil then
                        return nil, failure("ReadinessDisabled")
                    end
                    if not checkIntegrity() then
                        return nil, failure("Destroyed")
                    end
                    local targets = {}
                    for player, entry in roster do
                        local record = entry.readiness
                        local byte = if record ~= nil and record.phase == "Bound" and record.mask ~= nil
                            then string.byte(record.mask, readinessByteIndex) else 0
                        if player.Parent == players and byte ~= nil
                            and math.floor(byte / readinessBitValue) % 2 == 1 then
                            local count = #targets + 1
                            if count > MAXIMUM_AUDIENCE then
                                return nil, failure("InvalidAudience")
                            end
                            targets[count] = player
                        end
                    end
                    return targets, nil
                end,
            }
            if Streams.eligible(event) then
                local decode = Frame.compile(OrderedFrame.codecEvent(event), "decode", referenceContext)
                eventHandle.CreateStream = function(_, player, streamOptions)
                    return Streams.create(batchOwner, event, player, false, streamOptions, validate, decode)
                end
                eventHandle.CreateBroadcastStream = function(_, streamOptions)
                    return Streams.create(batchOwner, event, nil, true, streamOptions, validate, decode)
                end
            end
            events[name] = table.freeze(eventHandle)
        end
    end
    return table.freeze({
        events = table.freeze(events),
        requests = table.freeze(requests),
        Start = start,
        CreateBatch = function(_, recipients, flushAfter)
            return createBatch(recipients, flushAfter)
        end,
        CreateBatcher = function(_, recipients, flushAfter)
            return createBatch(recipients, flushAfter, true)
        end,
        CreateBroadcastBatcher = function(_, flushAfter)
            return createBatch(nil, flushAfter, true, true)
        end,
        CreateState = function(_, recipients, flushAfter, options)
            return createState(recipients, flushAfter, options)
        end,
        CreateBroadcastState = function(_, flushAfter)
            return createState(nil, flushAfter, nil, true)
        end,
        Destroy = function()
            destroy()
        end,
        GetDiagnostics = function()
            return Diagnostics.snapshot(diagnostics, state, inFlight)
        end,
    }), nil
end

return table.freeze({ create = create })
