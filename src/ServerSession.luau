local Definition = require(if script then script.Parent.Definition else "./Definition")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")
local TokenBucket = require(if script then script.Parent.internal.TokenBucket else "./internal/TokenBucket")
local Diagnostics = require(if script then script.Parent.internal.Diagnostics else "./internal/Diagnostics")
local RpcFrame = require(if script then script.Parent.internal.RpcFrame else "./internal/RpcFrame")

local activeSession = nil

local failure = Definition.error
local MAXIMUM_AUDIENCE = 1024

local function disconnect(connection)
    connection:Disconnect()
end

local function onlyKeys(value, firstKey, secondKey)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    for key in value do
        if key ~= firstKey and key ~= secondKey then
            return false
        end
    end
    return true
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

local function validOptions(options)
    if not onlyKeys(options, "inboundRate")
        or not onlyKeys(options.inboundRate, "perPlayer", "aggregate") then
        return false
    end
    local rate = options.inboundRate
    return validRate(rate.perPlayer, 4096, 2048) and validRate(rate.aggregate, 32768, 16384)
        and rate.aggregate.capacity >= rate.perPlayer.capacity
        and rate.aggregate.refillPerSecond >= rate.perPlayer.refillPerSecond
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

local function create(definition, options)
    if game == nil or not game:GetService("RunService"):IsServer() then
        return nil, failure("WrongRuntimeSide")
    end
    local compiled = Definition.get(definition)
    if compiled == nil then
        return nil, failure("InvalidDefinition")
    end
    if not validOptions(options) then
        return nil, failure("InvalidOptions")
    end

    local players = game:GetService("Players")
    local storage = game:GetService("ReplicatedStorage")
    local playerCapacity = options.inboundRate.perPlayer.capacity
    local playerRefill = options.inboundRate.perPlayer.refillPerSecond
    local aggregateCapacity = options.inboundRate.aggregate.capacity
    local aggregateRefill = options.inboundRate.aggregate.refillPerSecond
    local state = "Created"
    local identity = {}
    local root, descriptor, remote, unreliableRemote = nil, nil, nil, nil
    local connections, listeners, requestListeners, roster, storageSiblingWatchers = {}, {}, {}, {}, {}
    local removed = nil
    local aggregate = nil
    local inFlight = 0
    local diagnostics = Diagnostics.create(compiled.events, "Server", options.inboundRate, {
        perPlayerEndpoint = 1,
        perPlayer = 8,
        global = 64,
    })

    local function count(name, eventCounters)
        Diagnostics.increment(diagnostics.counters, name)
        if eventCounters ~= nil then
            Diagnostics.increment(eventCounters, name)
        end
    end

    local function currentPlayer(player)
        return typeof(player) == "Instance" and player.ClassName == "Player" and player.Parent == players
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
            table.clear(entry.activeRequests)
            table.clear(entry.replayGuids)
            table.clear(entry.replayCallIds)
            entry.replayCursor = 1
            entry.inFlight = 0
        end
        table.clear(roster)
        removed = nil
        aggregate = nil
        inFlight = 0

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
        root, descriptor, remote, unreliableRemote = nil, nil, nil, nil
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
            activeRequests = {},
            replayGuids = table.create(64),
            replayCallIds = table.create(64),
            replayCursor = 1,
        }
    end

    local function removePlayer(player)
        if state ~= "Starting" and state ~= "Started" then
            return
        end
        if removed ~= nil then
            removed[player] = true
        end
        local entry = roster[player]
        if entry ~= nil then
            entry.active = false
            inFlight -= entry.inFlight
            entry.inFlight = 0
            table.clear(entry.slots)
            table.clear(entry.activeRequests)
            table.clear(entry.replayGuids)
            table.clear(entry.replayCallIds)
            entry.replayCursor = 1
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
        for index = 1, 64 do
            if entry.replayGuids[index] == sessionGuid and entry.replayCallIds[index] == callId then
                return true
            end
        end
        return false
    end

    local function releaseRequest(entry, player, methodId, sessionGuid, callId, lease)
        if state ~= "Started" or not entry.active or roster[player] ~= entry then
            return
        end
        if entry.slots[methodId] == lease then
            entry.slots[methodId] = nil
            entry.inFlight -= 1
            inFlight -= 1
        end
        local active = entry.activeRequests[sessionGuid]
        if active ~= nil and active[callId] == lease then
            active[callId] = nil
            if next(active) == nil then
                entry.activeRequests[sessionGuid] = nil
            end
        end
    end

    local function sendRequestResponse(entry, player, methodId, callId, sessionGuid, kind, body)
        if state ~= "Started" or not entry.active or roster[player] ~= entry or not currentPlayer(player)
            or not checkIntegrity() then
            return
        end
        local packet = RpcFrame.wrap(kind, methodId, callId, sessionGuid, body)
        if packet == nil then
            return
        end
        local ok = pcall(remote.FireClient, remote, player, 0, packet)
        if ok then
            count("sendHandoffs")
        else
            count("transportFailures")
            checkIntegrity()
        end
    end

    local function dispatchRequest(entry, player, method, listener, header, values)
        local methodId = method.id
        local sessionGuid, callId = header.sessionGuid, header.callId
        local handler = listener.handler
        local encodeResponse = listener.encodeResponse
        local lease = {}
        entry.slots[methodId] = lease
        entry.inFlight += 1
        inFlight += 1
        local active = entry.activeRequests[sessionGuid]
        if active == nil then
            active = {}
            entry.activeRequests[sessionGuid] = active
        end
        active[callId] = lease
        local cursor = entry.replayCursor
        entry.replayGuids[cursor] = sessionGuid
        entry.replayCallIds[cursor] = callId
        entry.replayCursor = if cursor == 64 then 1 else cursor + 1

        count("dispatched")
        local invocation = table.pack(pcall(handler, player, table.unpack(values, 2, values.n)))
        if state ~= "Started" or not entry.active or roster[player] ~= entry or not currentPlayer(player) then
            releaseRequest(entry, player, methodId, sessionGuid, callId, lease)
            return
        end
        local kind, body
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
            else
                count("handlerErrors")
                kind = 4
            end
        end

        sendRequestResponse(entry, player, methodId, callId, sessionGuid, kind, body)
        releaseRequest(entry, player, methodId, sessionGuid, callId, lease)
    end

    local function receiveRequest(delivery, player, entry, ...)
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        if select("#", ...) ~= 1 then
            count("invalidPayload")
            return
        end
        local packet = ...
        local header = RpcFrame.peek(packet, true)
        if header == nil then
            count("invalidPayload")
            return
        end
        local method = compiled.requestsById[header.methodId]
        if method == nil then
            count("invalidEndpoint")
            return
        end
        if replayed(entry, header.sessionGuid, header.callId) then
            count("busy")
            return
        end
        local listener = requestListeners[method.id]
        if listener == nil or not listener.active then
            count("noListener")
            return
        end
        if entry.slots[method.id] ~= nil or entry.inFlight >= 8 or inFlight >= 64 then
            count("busy")
            return
        end
        local body = RpcFrame.readBody(packet, header, method.request.minimumEncodedBytes,
            method.request.maximumEncodedBytes)
        if body == nil then
            count("invalidPayload")
            return
        end
        local values = table.pack(listener.decodeRequest(body))
        if values[1] ~= true then
            count("invalidPayload")
            return
        end
        dispatchRequest(entry, player, method, listener, header, values)
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
        if endpointId == 0 then
            receiveRequest(delivery, player, entry, ...)
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
        if listener == nil or not listener.active then
            count("noListener", eventCounters)
            return
        end
        -- All three caps are inspected before any reservation changes.
        if entry.slots[event.id] or entry.inFlight >= 8 or inFlight >= 64 then
            count("busy", eventCounters)
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
        local sentCount = 0
        for _, player in targets do
            local entry = roster[player]
            if entry ~= nil and entry.active and player.Parent == players then
                local ok = pcall(fire, event, true, player, ...)
                if not ok then
                    count("transportFailures", diagnostics.byId[event.id])
                    checkIntegrity()
                    return false, failure("TransportFailure"), sentCount
                end
                sentCount += 1
                count("sendHandoffs", diagnostics.byId[event.id])
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

    local events = {}
    local requests = {}
    for name, method in compiled.requests do
        local requestRuntime = {
            decodeRequest = Frame.compile(method.request, "decode"),
            encodeResponse = Frame.compile(method.response, "encode"),
        }
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
    end
    for name, event in compiled.events do
        local mode = if event.usesCodec then
            (if event.direction == "ClientToServer" then "decode" else "encode") else nil
        local validate = Frame.compile(event, mode)
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
            events[name] = table.freeze({
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
            })
        end
    end
    return table.freeze({
        events = table.freeze(events),
        requests = table.freeze(requests),
        Start = start,
        Destroy = function()
            destroy()
        end,
        GetDiagnostics = function()
            return Diagnostics.snapshot(diagnostics, state, inFlight)
        end,
    }), nil
end

return table.freeze({ create = create })
