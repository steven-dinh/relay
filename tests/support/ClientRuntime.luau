local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Definition = require("../../src/Definition")
local CompositeCodec = require("../../src/internal/CompositeCodec")
local Diagnostics = require("../../src/internal/Diagnostics")
local RpcFrame = require("../../src/internal/RpcFrame")
local ReadinessFrame = require("../../src/internal/ReadinessFrame")
local BatchFrame = require("../../src/internal/BatchFrame")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
    environment = {
        Vector2 = roblox.Vector2,
        Vector3 = roblox.Vector3,
        CFrame = roblox.CFrame,
        require = function(path) assert(path == "./CompositeCodec"); return CompositeCodec end,
    },
    injectGlobals = true,
})()

local function create()
    local runtime = { now = 0, clockReads = 0, connections = 0, fires = {}, client = true, silent = false,
        deferred = false, pending = {}, timers = {}, storageScans = 0, guidCalls = 0,
        pausedTimers = false, ignoreTimerCancel = false, forceNonYieldable = false, deferSpawn = false,
        spawnedThreads = {} }
    local coroutineApi = table.clone(coroutine)
    coroutineApi.isyieldable = function()
        return not runtime.forceNonYieldable and coroutine.isyieldable()
    end

    function runtime:flush()
        while #self.pending > 0 do
            local pending = self.pending
            self.pending = {}
            for _, dispatch in pending do dispatch() end
        end
    end

    local scheduler = {
        delay = function(seconds, callback)
            local thread = coroutine.create(callback)
            runtime.timers[thread] = runtime.now + seconds
            return thread
        end,
        cancel = function(thread)
            if runtime.ignoreTimerCancel then return end
            assert(coroutine.status(thread) == "suspended", "only pending timers may be cancelled")
            runtime.timers[thread] = nil
            assert(coroutine.close(thread))
        end,
        defer = function(thread)
            if type(thread) == "thread" then
                table.insert(runtime.pending, function()
                    if coroutine.status(thread) == "suspended" then
                        assert(coroutine.resume(thread))
                    end
                end)
                return thread
            end
            table.insert(runtime.pending, thread)
            return thread
        end,
        spawn = function(thread)
            assert(type(thread) == "thread", "task.spawn thread scheduling requires a coroutine")
            table.insert(runtime.spawnedThreads, thread)
            if runtime.deferSpawn then
                table.insert(runtime.pending, function()
                    if coroutine.status(thread) == "suspended" then
                        assert(coroutine.resume(thread))
                    end
                end)
            else
                local ok, problem = coroutine.resume(thread)
                assert(ok, problem)
            end
            return thread
        end,
    }
    local Batch = luau.load(fs.readFile("src/internal/Batch.luau"), {
        debugName = "Batch",
        injectGlobals = true,
        environment = {
            task = scheduler,
            require = function(path)
                if path == "../Definition" then return Definition end
                assert(path == "./BatchFrame")
                return BatchFrame
            end,
        },
    })()
    function runtime:runTimers()
        for thread, deadline in self.timers do
            if deadline <= self.now then
                self.timers[thread] = nil
                if coroutine.status(thread) == "suspended" then
                    assert(coroutine.resume(thread))
                end
            end
        end
    end

    function runtime:collectTimers()
        local timers = {}
        for thread in table.clone(self.timers) do
            timers[#timers + 1] = thread
            self.timers[thread] = nil
        end
        return timers
    end

    function runtime:resumeTimers(timers)
        for _, thread in timers do
            if coroutine.status(thread) == "suspended" then
                assert(coroutine.resume(thread))
            end
        end
    end

    function runtime:advance(seconds)
        self.now += seconds
        if not self.pausedTimers then
            self:runTimers()
        end
        self:flush()
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
        function methods:GetPropertyChangedSignal(property)
            if not changed[property] then changed[property] = signal() end
            return changed[property]
        end
        function methods:FireServer(...)
            if runtime.onFire then runtime.onFire(self, ...) end
            if runtime.failFire then error("private transport detail") end
            local fired = table.pack(...)
            fired.remote = self
            table.insert(runtime.fires, fired)
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
            if name == "HttpService" then
                return { GenerateGUID = function()
                    runtime.guidCalls += 1
                    return `ABCDEFAB-CDEF-4000-8000-{string.format("%012d", runtime.guidCalls)}`
                end }
            end
            assert(name == "RunService")
            return { IsClient = function() return runtime.client end }
        end,
    }
    function runtime:transport(descriptor, hasUnreliable)
        local root = self:instance("Folder", "RelayRemotes", self.storage)
        local definition = self:instance("StringValue", "Definition", root)
        definition.Value = descriptor
        local remote = self:instance("RemoteEvent", "Reliable", root)
        local unreliableRemote = if hasUnreliable then
            self:instance("UnreliableRemoteEvent", "Unreliable", root) else nil
        return root, definition, remote, unreliableRemote
    end
    runtime.module = luau.load(fs.readFile("src/ClientSession.luau"), {
        debugName = "ClientSession",
        injectGlobals = true,
        environment = {
            game = runtime.game,
            os = { clock = function()
                runtime.clockReads += 1
                if runtime.clockHook then runtime.clockHook(runtime, runtime.clockReads) end
                return runtime.now
            end },
            task = scheduler,
            coroutine = coroutineApi,
            require = function(path)
                if path == "./Definition" then return Definition end
                if path == "./internal/Frame" then return Frame end
                if path == "./internal/RpcFrame" then return RpcFrame end
                if path == "./internal/ReadinessFrame" then return ReadinessFrame end
                if path == "./internal/Batch" then return Batch end
                if path == "./internal/BatchFrame" then return BatchFrame end
                assert(path == "./internal/Diagnostics")
                return Diagnostics
            end,
        },
    })()
    return runtime
end

return table.freeze({ create = create })
