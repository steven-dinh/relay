local Definition = require(if script then script.Parent.Definition else "./Definition")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")
local TokenBucket = require(if script then script.Parent.internal.TokenBucket else "./internal/TokenBucket")

local activeSession = nil

local failure = Definition.error

local function exactKeys(value, keys)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local count = 0
    for key in value do
        if not keys[key] then
            return false
        end
        count += 1
    end
    local expected = 0
    for key in keys do
        expected += 1
        if value[key] == nil then
            return false
        end
    end
    return count == expected
end

local function validRate(value, capacityLimit, refillLimit)
    if not exactKeys(value, { capacity = true, refillPerSecond = true }) then
        return false
    end
    local capacity, refill = value.capacity, value.refillPerSecond
    return type(capacity) == "number" and capacity % 1 == 0
        and capacity >= 1 and capacity <= capacityLimit
        and type(refill) == "number" and refill > 0 and refill <= refillLimit
end

local function validOptions(options)
    if not exactKeys(options, { inboundRate = true })
        or not exactKeys(options.inboundRate, { perPlayer = true, aggregate = true }) then
        return false
    end
    local rate = options.inboundRate
    return validRate(rate.perPlayer, 4096, 2048) and validRate(rate.aggregate, 32768, 16384)
        and rate.aggregate.capacity >= rate.perPlayer.capacity
        and rate.aggregate.refillPerSecond >= rate.perPlayer.refillPerSecond
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
    local root, descriptor, remote = nil, nil, nil
    local connections, listeners, roster = {}, {}, {}
    local removed = nil
    local aggregate = nil
    local inFlight = 0

    local function currentPlayer(player)
        return typeof(player) == "Instance" and player.ClassName == "Player" and player.Parent == players
    end

    local function intact()
        if root == nil or descriptor == nil or remote == nil
            or root.ClassName ~= "Folder" or root.Name ~= "RelayRemotes" or root.Parent ~= storage
            or descriptor.ClassName ~= "StringValue" or descriptor.Name ~= "Definition" or descriptor.Parent ~= root
            or remote.ClassName ~= "RemoteEvent" or remote.Name ~= "Reliable" or remote.Parent ~= root
            or descriptor.Value ~= compiled.descriptor then
            return false
        end
        local children = root:GetChildren()
        if #children ~= 2 or not ((children[1] == descriptor and children[2] == remote)
            or (children[1] == remote and children[2] == descriptor)) then
            return false
        end
        return true
    end

    local function uniqueRoot()
        for _, child in storage:GetChildren() do
            if child.Name == "RelayRemotes" and child ~= root then
                return false
            end
        end
        return true
    end

    local function destroy()
        if state == "Destroyed" then
            return
        end
        state = "Destroyed"
        if activeSession == identity then
            activeSession = nil
        end
        for _, listener in listeners do
            listener.active = false
            listener.handler = nil
        end
        table.clear(listeners)
        for _, connection in connections do
            pcall(function()
                connection:Disconnect()
            end)
        end
        table.clear(connections)
        for _, entry in roster do
            entry.active = false
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
                if #instance:GetChildren() ~= 0 then
                    return false
                end
                instance:Destroy()
                return true
            end)
            return ok and destroyed
        end
        local descriptorGone = destroyEmpty(descriptor)
        local remoteGone = destroyEmpty(remote)
        if descriptorGone and remoteGone then
            destroyEmpty(root)
        end
        root, descriptor, remote = nil, nil, nil
    end

    local function checkIntegrity()
        if state ~= "Started" then
            return false
        end
        local ok, valid = pcall(intact)
        if not ok or not valid then
            destroy()
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
            roster[player] = nil
        end
    end

    local function receive(player, ...)
        if not checkIntegrity() then
            return
        end
        local entry = roster[player]
        if entry == nil or not entry.active or not currentPlayer(player) then
            return
        end
        if not entry.bucket:take() or not aggregate:take() then
            return
        end
        local count = select("#", ...)
        local endpointId = ...
        local event = Frame.resolve(compiled, "ClientToServer", endpointId)
        if event == nil then
            return
        end
        local listener = listeners[event.id]
        if listener == nil or not listener.active or count ~= 1 + #event.fields then
            return
        end
        local values = Frame.validate(event, select(2, ...))
        if values == nil then
            return
        end
        -- All three caps are inspected before any reservation changes.
        if entry.slots[event.id] or entry.inFlight >= 8 or inFlight >= 64 then
            return
        end
        entry.slots[event.id] = true
        entry.inFlight += 1
        inFlight += 1
        local lease = { released = false }
        pcall(listener.handler, player, table.unpack(values, 1, #event.fields))
        if not lease.released then
            lease.released = true
            if state == "Started" then
                entry.slots[event.id] = nil
                entry.inFlight -= 1
                inFlight -= 1
            end
        end
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
            for _, child in storage:GetChildren() do
                if child.Name == "RelayRemotes" then
                    startupError = "RemoteOwnershipConflict"
                    return
                end
            end
            root = Instance.new("Folder")
            root.Name = "RelayRemotes"
            descriptor = Instance.new("StringValue")
            descriptor.Name = "Definition"
            descriptor.Value = compiled.descriptor
            remote = Instance.new("RemoteEvent")
            remote.Name = "Reliable"
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
            table.insert(connections, remote.OnServerEvent:Connect(receive))
            descriptor.Parent = root
            remote.Parent = root
            root.Parent = storage
            -- Attach after our own non-yielding parenting, so deferred startup
            -- notifications cannot be mistaken for later integrity violations.
            local function observe()
                if state == "Started" then
                    destroy()
                end
            end
            for _, instance in { root, descriptor, remote } do
                table.insert(connections, instance.AncestryChanged:Connect(observe))
                table.insert(connections, instance:GetPropertyChangedSignal("Name"):Connect(observe))
                table.insert(connections, instance.Destroying:Connect(observe))
            end
            table.insert(connections, descriptor:GetPropertyChangedSignal("Value"):Connect(observe))
            table.insert(connections, root.ChildAdded:Connect(observe))
            table.insert(connections, root.ChildRemoved:Connect(observe))
            local function observeStorage()
                if state == "Started" then
                    local checked, unique = pcall(uniqueRoot)
                    if not checked or not unique then
                        destroy()
                    else
                        checkIntegrity()
                    end
                end
            end
            table.insert(connections, storage.ChildAdded:Connect(observeStorage))
            table.insert(connections, storage.ChildRemoved:Connect(observeStorage))
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

    local function connect(event, handler)
        if state == "Destroyed" then
            return nil, failure("Destroyed")
        end
        if type(handler) ~= "function" then
            return nil, failure("InvalidHandler")
        end
        if listeners[event.id] ~= nil then
            return nil, failure("AlreadyConnected")
        end
        local listener = { active = true, handler = handler }
        listeners[event.id] = listener
        return table.freeze({ Disconnect = function()
            if not listener.active then
                return
            end
            listener.active = false
            listener.handler = nil
            if listeners[event.id] == listener then
                listeners[event.id] = nil
            end
        end }), nil
    end

    local function send(event, targeted, player, ...)
        if state == "Destroyed" then
            return false, failure("Destroyed")
        end
        if state ~= "Started" then
            return false, failure("NotStarted")
        end
        if targeted and not currentPlayer(player) then
            return false, failure("InvalidPlayer")
        end
        local values = Frame.validate(event, ...)
        if values == nil then
            return false, failure("InvalidPayload")
        end
        if not checkIntegrity() then
            return false, failure("Destroyed")
        end
        local ok = pcall(function()
            if targeted then
                remote:FireClient(player, event.id, table.unpack(values, 1, #event.fields))
            else
                remote:FireAllClients(event.id, table.unpack(values, 1, #event.fields))
            end
        end)
        if not ok then
            checkIntegrity()
            return false, failure("TransportFailure")
        end
        return true, nil
    end

    local events = {}
    for name, event in compiled.events do
        if event.direction == "ClientToServer" then
            events[name] = table.freeze({ Connect = function(_, handler)
                return connect(event, handler)
            end })
        else
            events[name] = table.freeze({
                Send = function(_, player, ...)
                    return send(event, true, player, ...)
                end,
                Broadcast = function(_, ...)
                    return send(event, false, nil, ...)
                end,
            })
        end
    end
    return table.freeze({ events = table.freeze(events), Start = start, Destroy = destroy }), nil
end

return table.freeze({ create = create })
