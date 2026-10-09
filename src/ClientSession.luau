local Definition = require(if script then script.Parent.Definition else "./Definition")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")
local Diagnostics = require(if script then script.Parent.internal.Diagnostics else "./internal/Diagnostics")
local RpcFrame = require(if script then script.Parent.internal.RpcFrame else "./internal/RpcFrame")

local activeSession = nil
local MAXIMUM_CALL_ID = 4_294_967_295

local function requestFailure(code)
    return table.freeze({ ok = false, error = Definition.error(code) })
end

local function awaitPending(record)
    if record.settled then
        return record.result
    end
    if record.waiterToken ~= nil then
        if record.waiterThread ~= nil and coroutine.status(record.waiterThread) ~= "dead" then
            return requestFailure("AlreadyAwaiting")
        end
        record.waiterToken = nil
        record.waiterThread = nil
    end
    if not coroutine.isyieldable() then
        return requestFailure("NotYieldable")
    end
    local token = {}
    local thread = coroutine.running()
    record.waiterToken = token
    record.waiterThread = thread
    while not record.settled do
        if record.readClock() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
            break
        end
        coroutine.yield()
    end
    if record.waiterToken == token then
        record.waiterToken = nil
        record.waiterThread = nil
    end
    return record.result
end

local function cancelPending(record)
    if not record.settled then
        record.settle(requestFailure("Cancelled"))
    end
end

local function pendingHandle(record)
    return table.freeze({
        Await = function()
            return awaitPending(record)
        end,
        Cancel = function()
            cancelPending(record)
        end,
    })
end

local function armPendingTimer(record)
    record.timer = task.delay(record.deadline - record.readClock(), function()
        if record.settled then
            return
        end
        record.timer = nil
        if record.readClock() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
        else
            armPendingTimer(record)
        end
    end)
end

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
        if key ~= "startupTimeoutSeconds" then
            return false
        end
    end

    local timeout = options.startupTimeoutSeconds
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
    local pendingById, pendingByMethod = {}, {}
    local receiveRequestResponse
    local pendingCount, callIdCounter, rpcSessionGuid = 0, 0, nil
    local rpcClockHighWater = -math.huge
    local diagnostics = Diagnostics.create(compiled.events, "Client", nil, { perEndpoint = 1 })

    local function rpcNow()
        local now = os.clock()
        if now > rpcClockHighWater then
            rpcClockHighWater = now
        end
        return rpcClockHighWater
    end

    local function settlePending(record, result)
        if record.settled or pendingById[record.callId] ~= record then
            return false
        end
        record.settled = true
        pendingById[record.callId] = nil
        if pendingByMethod[record.methodId] == record then
            pendingByMethod[record.methodId] = nil
        end
        pendingCount -= 1
        local timer = record.timer
        record.timer = nil
        if timer ~= nil then
            pcall(task.cancel, timer)
        end
        local waiterToken = record.waiterToken
        local waiterThread = record.waiterThread
        record.result = result
        record.readClock = nil
        record.settle = nil
        record.decodeResponse = nil
        if waiterToken ~= nil and waiterThread ~= nil then
            if coroutine.status(waiterThread) == "dead" then
                if record.waiterToken == waiterToken and record.waiterThread == waiterThread then
                    record.waiterToken = nil
                    record.waiterThread = nil
                end
            else
                task.defer(function()
                    if record.waiterToken ~= waiterToken or record.waiterThread ~= waiterThread then
                        return
                    end
                    local function clearWaiter()
                        if record.waiterToken == waiterToken and record.waiterThread == waiterThread then
                            record.waiterToken = nil
                            record.waiterThread = nil
                        end
                    end
                    local status = coroutine.status(waiterThread)
                    if status == "dead" then
                        clearWaiter()
                    elseif status == "suspended" then
                        task.spawn(waiterThread)
                        if coroutine.status(waiterThread) == "dead" then
                            clearWaiter()
                        end
                    end
                end)
            end
        end
        return true
    end

    local function settleAllPending(code)
        local pending = table.clone(pendingById)
        for _, record in pending do
            settlePending(record, requestFailure(code))
        end
    end

    local function count(name, eventCounters)
        Diagnostics.increment(diagnostics.counters, name)
        if eventCounters ~= nil then
            Diagnostics.increment(eventCounters, name)
        end
    end

    local function stop(nextState)
        if state == "Started" and nextState == "Disconnected" then
            count("transportLosses")
        end
        state = nextState
        attempt = nil
        settleAllPending(nextState)
        if activeSession == identity then
            activeSession = nil
        end
        for _, receiver in receivers do
            receiver.handler = nil
            receiver.connection = nil
            receiver.once = false
            receiver.validate = nil
            -- A running handler owns its endpoint until its protected call returns.
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

    local function fire(event, ...)
        local transport = if event.delivery == "Unreliable" then unreliableRemote else remote
        transport:FireServer(event.id, ...)
    end

    local function sendValidated(event, valid, ...)
        if not valid then
            return false, Definition.error("InvalidPayload")
        end
        if not checkTransport() then
            return false, Definition.error("Disconnected")
        end
        local ok = pcall(fire, event, ...)
        if not ok then
            count("transportFailures", diagnostics.byId[event.id])
            if state == "Started" then
                checkTransport()
            end
            return false, Definition.error("TransportFailure")
        end
        count("sendHandoffs", diagnostics.byId[event.id])
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
                end
            end,
        })
        receiver.handler = handler
        receiver.connection = connection
        receiver.once = once
        return connection, nil
    end

    local events = {}
    local requests = {}
    for name, event in compiled.events do
        local mode = if event.usesCodec then
            (if event.direction == "ClientToServer" then "encode" else "decode") else nil
        local validate = Frame.compile(event, mode)
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
            local receiver = { handler = nil, connection = nil, once = false, busy = false, validate = validate }
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

    for name, method in compiled.requests do
        local requestRuntime = {
            encodeRequest = Frame.compile(method.request, "encode"),
            decodeResponse = Frame.compile(method.response, "decode"),
        }
        requests[name] = table.freeze({
            Request = function(_, timeoutSeconds, ...)
                if state == "Destroyed" or state == "Disconnected" then
                    return nil, Definition.error(state)
                end
                if state ~= "Started" then
                    return nil, Definition.error("NotStarted")
                end
                if type(timeoutSeconds) ~= "number" or not (timeoutSeconds > 0 and timeoutSeconds <= 60) then
                    return nil, Definition.error("InvalidOptions")
                end
                if pendingCount >= 8 or pendingByMethod[method.id] ~= nil then
                    return nil, Definition.error("RequestLimit")
                end
                if callIdCounter >= MAXIMUM_CALL_ID then
                    return nil, Definition.error("RequestIdExhausted")
                end
                if not checkTransport() then
                    return nil, Definition.error("Disconnected")
                end
                local encoded = table.pack(requestRuntime.encodeRequest(...))
                if encoded[1] ~= true then
                    return nil, Definition.error("InvalidPayload")
                end
                local callId = callIdCounter + 1
                local packet = RpcFrame.wrap(1, method.id, callId, rpcSessionGuid, encoded[2])
                if packet == nil then
                    return nil, Definition.error("InvalidPayload")
                end
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
                record.settle = function(result)
                    return settlePending(record, result)
                end
                pendingById[callId] = record
                pendingByMethod[method.id] = record
                pendingCount += 1
                armPendingTimer(record)
                local ok = pcall(remote.FireServer, remote, 0, packet)
                if not ok then
                    count("transportFailures")
                    settlePending(record, requestFailure("TransportFailure"))
                    if state == "Started" then
                        checkTransport()
                    end
                    return nil, Definition.error("TransportFailure")
                end
                count("sendHandoffs")
                return pendingHandle(record), nil
            end,
        })
    end

    receiveRequestResponse = function(delivery, ...)
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        if rpcSessionGuid == nil then
            count("invalidEndpoint")
            return
        end
        if select("#", ...) ~= 1 then
            count("invalidPayload")
            return
        end
        local packet = ...
        local header = RpcFrame.peek(packet, false)
        if header == nil then
            count("invalidPayload")
            return
        end
        if header.sessionGuid ~= rpcSessionGuid then
            count("invalidEndpoint")
            return
        end
        local record = pendingById[header.callId]
        if record == nil or record.methodId ~= header.methodId then
            count("invalidEndpoint")
            return
        end
        if rpcNow() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
            return
        end
        if header.kind == 3 then
            record.settle(requestFailure("HandlerFailure"))
            return
        elseif header.kind == 4 then
            record.settle(requestFailure("InvalidResponse"))
            return
        end
        local method = compiled.requestsById[header.methodId]
        local body = RpcFrame.readBody(packet, header, method.response.minimumEncodedBytes,
            method.response.maximumEncodedBytes)
        if body == nil then
            count("invalidPayload")
            return
        end
        local decoded = table.pack(record.decodeResponse(body))
        if decoded[1] ~= true then
            count("invalidPayload")
            return
        end
        if rpcNow() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
            return
        end
        record.settle(table.freeze({ ok = true, value = decoded[2] }))
    end

    local function dispatch(receiver, eventCounters, valid, ...)
        if not valid then
            count("invalidPayload", eventCounters)
            return
        end
        local handler = receiver.handler
        receiver.busy = true
        if receiver.once then
            receiver.handler = nil
            receiver.connection = nil
            receiver.once = false
        end
        count("dispatched", eventCounters)
        local ok = pcall(handler, ...)
        if not ok and state == "Started" then
            count("handlerErrors", eventCounters)
        end
        receiver.busy = false
    end

    local function receive(delivery, endpointId, ...)
        if state ~= "Started" or not checkTransport() then
            return
        end
        count("received")
        if endpointId == 0 then
            receiveRequestResponse(delivery, ...)
            return
        end
        local event = Frame.resolve(compiled, "ServerToClient", endpointId)
        if event == nil then
            count("invalidEndpoint")
            return
        end
        local eventCounters = diagnostics.byId[event.id]
        if event.delivery ~= delivery then
            count("wrongChannel")
            return
        end
        local receiver = receivers[event.id]
        if receiver.handler == nil then
            count("noListener", eventCounters)
            return
        end
        if receiver.busy then
            count("busy", eventCounters)
            return
        end
        dispatch(receiver, eventCounters, receiver.validate(...))
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
            if next(compiled.requests) ~= nil then
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
            state = "Started"
            attempt = nil
            return nil
        end)

        if not ok or failure ~= nil then
            stop("Destroyed")
            return false, Definition.error(if ok then failure else "TransportFailure")
        end
        return true, nil
    end

    local function inFlight()
        if state ~= "Started" then
            return 0
        end
        local count = 0
        for _, receiver in receivers do
            if receiver.busy then
                count += 1
            end
        end
        return count
    end

    return table.freeze({
        events = table.freeze(events),
        requests = table.freeze(requests),
        Start = start,
        Destroy = function()
            if state ~= "Destroyed" then
                stop("Destroyed")
            end
        end,
        GetDiagnostics = function()
            return Diagnostics.snapshot(diagnostics, state, inFlight())
        end,
    }), nil
end

return table.freeze({ create = create })
