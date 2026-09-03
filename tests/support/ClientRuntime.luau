local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../../src/Definition")
local Frame = require("../../src/internal/Frame")

local function create()
    local runtime = { now = 0, connections = 0, fires = {}, client = true, silent = false,
        deferred = false, pending = {}, storageScans = 0 }

    function runtime:flush()
        local pending = self.pending
        self.pending = {}
        for _, dispatch in pending do dispatch() end
    end

    local function signal()
        local callbacks = {}
        local result = {}
        function result:Connect(callback)
            if runtime.failConnect then
                error("local connection failure")
            end
            local connection = { active = true }
            callbacks[connection] = callback
            runtime.connections += 1
            function connection:Disconnect()
                if self.active then
                    self.active = false
                    callbacks[self] = nil
                    runtime.connections -= 1
                end
            end
            return connection
        end
        function result:fire(...)
            local threads = {}
            if runtime.silent then return threads end
            local snapshot = table.clone(callbacks)
            for connection, callback in snapshot do
                if connection.active then
                    local arguments = table.pack(...)
                    local function dispatch()
                        if not connection.active then return end
                        local thread = coroutine.create(callback)
                        assert(coroutine.resume(thread, table.unpack(arguments, 1, arguments.n)))
                        table.insert(threads, thread)
                    end
                    if runtime.deferred then
                        table.insert(runtime.pending, dispatch)
                    else
                        dispatch()
                    end
                end
            end
            return threads
        end
        function result:snapshot()
            return table.clone(callbacks)
        end
        return result
    end

    function runtime:instance(className, name, parent)
        local props = { ClassName = className, Name = name, Value = "" }
        local children = {}
        local changed = {}
        local methods = {
            ChildAdded = signal(), ChildRemoved = signal(), AncestryChanged = signal(),
            Destroying = signal(), OnClientEvent = signal(),
        }
        local instance
        function methods:GetChildren()
            if className == "ReplicatedStorage" then runtime.storageScans += 1 end
            return table.clone(children)
        end
        function methods:FindFirstChild(childName)
            for _, child in children do
                if child.Name == childName then return child end
            end
            return nil
        end
        function methods:WaitForChild(childName, seconds)
            if runtime.onWait then
                runtime.onWait(self, childName, seconds)
            else
                runtime.now += seconds
            end
            return self:FindFirstChild(childName)
        end
        function methods:GetPropertyChangedSignal(property)
            if not changed[property] then changed[property] = signal() end
            return changed[property]
        end
        function methods:FireServer(...)
            if runtime.onFire then runtime.onFire(self) end
            if runtime.failFire then error("private transport detail") end
            table.insert(runtime.fires, table.pack(...))
        end
        function methods:Destroy()
            methods.Destroying:fire()
            self.Parent = nil
        end
        function methods:add(child)
            table.insert(children, child)
            methods.ChildAdded:fire(child)
        end
        function methods:remove(child)
            local index = table.find(children, child)
            if index then table.remove(children, index) end
            methods.ChildRemoved:fire(child)
        end
        instance = setmetatable({}, {
            __index = function(_, key)
                if methods[key] ~= nil then return methods[key] end
                return props[key]
            end,
            __newindex = function(_, key, value)
                local previous = props[key]
                props[key] = value
                if key == "Parent" and previous ~= value then
                    if previous then previous:remove(instance) end
                    if value then value:add(instance) end
                    methods.AncestryChanged:fire(instance, value)
                end
                if previous ~= value and changed[key] then changed[key]:fire() end
            end,
        })
        instance.Parent = parent
        return instance
    end

    runtime.storage = runtime:instance("ReplicatedStorage", "ReplicatedStorage")
    runtime.game = {
        GetService = function(_, name)
            if name == "ReplicatedStorage" then return runtime.storage end
            assert(name == "RunService")
            return { IsClient = function() return runtime.client end }
        end,
    }
    function runtime:transport(descriptor)
        local root = self:instance("Folder", "RelayRemotes", self.storage)
        local definition = self:instance("StringValue", "Definition", root)
        definition.Value = descriptor
        local remote = self:instance("RemoteEvent", "Reliable", root)
        return root, definition, remote
    end
    runtime.module = luau.load(fs.readFile("src/ClientSession.luau"), {
        debugName = "ClientSession",
        injectGlobals = true,
        environment = {
            game = runtime.game,
            os = { clock = function() return runtime.now end },
            require = function(path)
                if path == "./Definition" then return Definition end
                assert(path == "./internal/Frame")
                return Frame
            end,
        },
    })()
    return runtime
end

return table.freeze({ create = create })
