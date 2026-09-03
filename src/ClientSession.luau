local Definition = require(if script then script.Parent.Definition else "./Definition")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")

local activeSession = nil

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
    local storage, root, descriptor, remote = nil, nil, nil, nil
    local connections = {}
    local receivers = {}

    local function stop(nextState)
        state = nextState
        attempt = nil
        if activeSession == identity then
            activeSession = nil
        end
        for _, receiver in receivers do
            receiver.handler = nil
            receiver.connection = nil
            -- A running handler owns its endpoint until its protected call returns.
        end
        for _, connection in connections do
            pcall(function()
                connection:Disconnect()
            end)
        end
        table.clear(connections)
        storage, root, descriptor, remote = nil, nil, nil, nil
    end

    local function transportValid(checkDefinition)
        if root == nil or descriptor == nil or remote == nil then
            return false
        end
        if root.ClassName ~= "Folder" or root.Name ~= "RelayRemotes" or root.Parent ~= storage
            or descriptor.ClassName ~= "StringValue" or descriptor.Name ~= "Definition" or descriptor.Parent ~= root
            or remote.ClassName ~= "RemoteEvent" or remote.Name ~= "Reliable" or remote.Parent ~= root
            or (checkDefinition ~= false and descriptor.Value ~= compiled.descriptor)
        then
            return false
        end
        local children = root:GetChildren()
        return #children == 2
            and ((children[1] == descriptor and children[2] == remote)
                or (children[1] == remote and children[2] == descriptor))
    end

    local function uniqueRoot()
        for _, child in storage:GetChildren() do
            if child.Name == "RelayRemotes" and child ~= root then
                return false
            end
        end
        return true
    end

    local function checkTransport()
        local ok, valid = pcall(transportValid)
        if not ok or not valid then
            stop("Disconnected")
            return false
        end
        return true
    end

    local events = {}
    for name, event in compiled.events do
        if event.direction == "ClientToServer" then
            events[name] = table.freeze({
                Send = function(_, ...)
                    if state == "Destroyed" or state == "Disconnected" then
                        return false, Definition.error(state)
                    end
                    if state ~= "Started" then
                        return false, Definition.error("NotStarted")
                    end
                    local values = Frame.validate(event, ...)
                    if values == nil then
                        return false, Definition.error("InvalidPayload")
                    end
                    if not checkTransport() then
                        return false, Definition.error("Disconnected")
                    end
                    local ok = pcall(function()
                        remote:FireServer(event.id, table.unpack(values, 1, #event.fields))
                    end)
                    if not ok then
                        if state == "Started" then
                            checkTransport()
                        end
                        return false, Definition.error("TransportFailure")
                    end
                    return true, nil
                end,
            })
        else
            local receiver = { handler = nil, connection = nil, busy = false }
            receivers[event.id] = receiver
            events[name] = table.freeze({
                Connect = function(_, handler)
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
                            end
                        end,
                    })
                    receiver.handler = handler
                    receiver.connection = connection
                    return connection, nil
                end,
            })
        end
    end

    local function receive(endpointId, ...)
        if state ~= "Started" or not checkTransport() then
            return
        end
        local event = Frame.resolve(compiled, "ServerToClient", endpointId)
        if event == nil then
            return
        end
        local receiver = receivers[event.id]
        if receiver.handler == nil or receiver.busy then
            return
        end
        local values = Frame.validate(event, ...)
        if values == nil then
            return
        end
        receiver.busy = true
        local handler = receiver.handler
        pcall(handler, table.unpack(values, 1, #event.fields))
        receiver.busy = false
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
                child = parent:WaitForChild(name, remaining)
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
                if child == root or not uniqueRoot() then
                    lost()
                else
                    checkTransport()
                end
            end
            observe(remote.OnClientEvent, receive)
            observe(storage.ChildAdded, storageChanged)
            observe(storage.ChildRemoved, storageChanged)
            observe(root.ChildAdded, lost)
            observe(root.ChildRemoved, lost)
            for _, instance in { root, descriptor, remote } do
                observe(instance.AncestryChanged, function(child, parent)
                    if state == "Started" and ((child == root and parent ~= storage)
                        or ((child == descriptor or child == remote) and parent ~= root)) then
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

    return table.freeze({
        events = table.freeze(events),
        Start = start,
        Destroy = function()
            if state ~= "Destroyed" then
                stop("Destroyed")
            end
        end,
    }), nil
end

return table.freeze({ create = create })
