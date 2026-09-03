local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../../src/Definition")
local Frame = require("../../src/internal/Frame")
local TokenBucket = require("../../src/internal/TokenBucket")

local function new()
    local runtime = { now = 0, connections = 0, instances = {}, fires = {}, deferred = false, pending = {} }
    local function signal()
        local listeners = {}
        local value = {}
        function value:Connect(handler)
            local connection = { Connected = true, handler = handler }
            runtime.connections += 1
            function connection:Disconnect()
                if self.Connected then
                    self.Connected = false
                    runtime.connections -= 1
                end
            end
            table.insert(listeners, connection)
            return connection
        end
        function value:Fire(...)
            local args = table.pack(...)
            for _, connection in table.clone(listeners) do
                if connection.Connected then
                    local function invoke()
                        local thread = coroutine.create(connection.handler)
                        local ok, err = coroutine.resume(thread, table.unpack(args, 1, args.n))
                        assert(ok, err)
                        return thread
                    end
                    if runtime.deferred then
                        table.insert(runtime.pending, invoke)
                    else
                        invoke()
                    end
                end
            end
        end
        return value
    end
    local function instance(className)
        local properties = { ClassName = className, Name = className, Value = "", Parent = nil }
        local children, changed = {}, {}
        local methods = {
            ChildAdded = signal(), ChildRemoved = signal(), AncestryChanged = signal(), Destroying = signal(),
        }
        if className == "RemoteEvent" then
            methods.OnServerEvent = signal()
        end
        local object
        function methods:GetChildren()
            if object == runtime.storage then
                runtime.storageScans = (runtime.storageScans or 0) + 1
            end
            return table.clone(children)
        end
        function methods:FindFirstChild(name)
            for _, child in children do
                if child.Name == name then
                    return child
                end
            end
            return nil
        end
        function methods:GetPropertyChangedSignal(name)
            if changed[name] == nil then
                changed[name] = signal()
            end
            return changed[name]
        end
        function methods:Destroy()
            if methods.destroyed then
                return
            end
            methods.destroyed = true
            methods.Destroying:Fire()
            self.Parent = nil
            for _, child in table.clone(children) do
                child:Destroy()
            end
        end
        function methods:FireClient(player, ...)
            if runtime.beforeFire then
                runtime.beforeFire(player)
            end
            if runtime.throwFire or player.Parent ~= runtime.players then
                error("private transport error")
            end
            table.insert(runtime.fires, { kind = "target", player = player, values = table.pack(...) })
        end
        function methods:FireAllClients(...)
            if runtime.throwFire then
                error("private transport error")
            end
            table.insert(runtime.fires, { kind = "broadcast", values = table.pack(...) })
        end
        object = setmetatable({}, {
            __index = function(_, key)
                return methods[key] or properties[key]
            end,
            __newindex = function(_, key, value)
                local previous = properties[key]
                properties[key] = value
                if key == "Parent" and previous ~= value then
                    if previous then
                        local oldChildren = previous._children
                        table.remove(oldChildren, assert(table.find(oldChildren, object)))
                        previous.ChildRemoved:Fire(object)
                    end
                    if value then
                        table.insert(value._children, object)
                        value.ChildAdded:Fire(object)
                    end
                    methods.AncestryChanged:Fire(object, value)
                end
                if changed[key] then
                    changed[key]:Fire()
                end
            end,
        })
        methods._children = children
        runtime.instances[object] = true
        return object
    end
    runtime.newInstance = instance
    runtime.storage = instance("ReplicatedStorage")
    runtime.players = instance("Players")
    runtime.players.PlayerAdded = signal()
    runtime.players.PlayerRemoving = signal()
    runtime.players.GetPlayers = function()
        local snapshot = runtime.players:GetChildren()
        if runtime.snapshotHook then
            runtime.snapshotHook(snapshot)
        end
        return snapshot
    end
    runtime.game = { GetService = function(_, name)
        if name == "RunService" then
            return { IsServer = function()
                return runtime.isServer ~= false
            end }
        end
        return if name == "Players" then runtime.players else runtime.storage
    end }
    function runtime:addPlayer()
        local player = instance("Player")
        player.Parent = self.players
        self.players.PlayerAdded:Fire(player)
        return player
    end
    function runtime:removePlayer(player)
        self.players.PlayerRemoving:Fire(player)
        player.Parent = nil
    end
    function runtime:remote()
        for _, root in self.storage:GetChildren() do
            for _, child in root:GetChildren() do
                if child.ClassName == "RemoteEvent" then
                    return child
                end
            end
        end
        return nil
    end
    function runtime:flush()
        local pending = self.pending
        self.pending = {}
        for _, callback in pending do
            callback()
        end
    end
    runtime.server = luau.load(fs.readFile("src/ServerSession.luau"), {
        debugName = "ServerSession",
        injectGlobals = true,
        environment = {
            game = runtime.game,
            Instance = { new = instance },
            typeof = function(value)
                return if runtime.instances[value] then "Instance" else typeof(value)
            end,
            require = function(path)
                if path == "./Definition" then
                    return Definition
                elseif path == "./internal/Frame" then
                    return Frame
                end
                assert(path == "./internal/TokenBucket")
                return { new = function(capacity, refill)
                    return TokenBucket.new(capacity, refill, function()
                        return runtime.now
                    end)
                end }
            end,
        },
    })()
    return runtime
end

return table.freeze({ new = new })
