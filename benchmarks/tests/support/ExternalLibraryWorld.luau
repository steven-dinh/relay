--!strict

-- Executes the pinned library source. Only the engine services used by the
-- qualification cases are simulated; serializers and library queues are real.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local hostTypeof = typeof

local function new(clientCount: number, libraryId: string): any
	local runtimeNames = { quicknet = "QuickNet", bytenet = "ByteNet", satset = "Satset", warp = "Warp", ["suphi-packet"] = "SuphiPacket" }
	local generated = libraryId == "blink" or libraryId == "zap" or libraryId == "netray-compile"
	assert(runtimeNames[libraryId] ~= nil or generated, "unsupported qualification library")
	assert(clientCount >= 1 and clientCount <= 8, "invalid qualification roster")
	local world: any = { players = {}, transmissions = {}, warnings = {}, logs = {}, frame = 0 }
	local pending: { any } = {}
	local deferred: { any } = {}
	local instanceNodes: { [any]: any } = {}
	local sideViews: { [number]: { [any]: any } } = {}
	local moduleCaches: { [number]: { [any]: any } } = {}
	local sideGlobals: { [number]: any } = {}
	local services: { [number]: any } = {}
	local sourceNodes: { [string]: any } = {}
	local callbackKey = 500_000
	local view: (any, number) -> any
	local loadModule: (any, number) -> any

	local function resume(thread: thread, ...: any)
		local ok, issue = coroutine.resume(thread, ...)
		assert(ok, issue)
	end

	local function start(callback: any, ...: any): thread
		local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
		resume(thread, ...)
		return thread
	end

	local function signal(): any
		local records = {}
		local result: any = {}
		function result:Connect(callback: any): any
			local connection: any = { Connected = true }
			function connection:Disconnect() self.Connected = false end
			table.insert(records, { connection = connection, callback = callback })
			return connection
		end
		function result:Once(callback: any): any
			local connection
			connection = self:Connect(function(...)
				connection:Disconnect()
				callback(...)
			end)
			return connection
		end
		function result:Wait(): ...any
			local thread = coroutine.running()
			self:Once(function(...) resume(thread, ...) end)
			return coroutine.yield()
		end
		function result:fire(...: any)
			for _, record in table.clone(records) do
				if record.connection.Connected then start(record.callback, ...) end
			end
		end
		function result:disconnectAll()
			for _, record in records do record.connection:Disconnect() end
		end
		return result
	end

	local function node(className: string, name: string, sourcePath: string?): any
		return {
			className = className, name = name, sourcePath = sourcePath,
			source = if sourcePath ~= nil then fs.readFile(sourcePath) else nil,
			children = {}, attributes = {}, attributeSignals = {}, propertySignals = {},
			childAdded = signal(), childRemoved = signal(), destroying = signal(), changed = signal(), attributeChanged = signal(),
			value = if className == "StringValue" then "" else nil,
			serverEvent = signal(), clientEvents = {}, invokeCallbacks = {}, destroyed = false,
		}
	end

	local function attach(child: any, parent: any)
		if child.parent == parent then return end
		if child.parent ~= nil then
			local previous = child.parent
			for index, candidate in previous.children do
				if candidate == child then table.remove(previous.children, index) break end
			end
			child.parent = nil
			previous.childRemoved:fire(child)
		end
		child.parent = parent
		if parent ~= nil then
			table.insert(parent.children, child)
			parent.childAdded:fire(child)
		end
	end

	local function childNamed(parent: any, name: string): any
		for _, child in parent.children do
			if child.name == name then return child end
		end
		return nil
	end

	local function copyWire(value: any): any
		if type(value) == "buffer" then
			local result = buffer.create(buffer.len(value))
			buffer.copy(result, 0, value)
			return result
		elseif type(value) == "table" and instanceNodes[value] == nil then
			local result = {}
			for key, child in value do result[key] = copyWire(child) end
			return result
		end
		return value
	end

	local function send(remote: any, sender: number, recipient: number, ...: any)
		assert(not remote.destroyed, "destroyed remote send")
		local args = table.pack(...)
		for index = 1, args.n do args[index] = copyWire(args[index]) end
		local transmission = { remote = remote.name, sender = sender, recipient = recipient, arguments = args }
		table.insert(world.transmissions, transmission)
		table.insert(pending, { remote = remote, sender = sender, recipient = recipient, arguments = args })
	end

	local function instanceSignal(rawSignal: any, side: number): any
		return {
			Connect = function(_self, callback)
				return rawSignal:Connect(function(child) callback(view(child, side)) end)
			end,
		}
	end

	view = function(value: any, side: number): any
		if value == nil then return nil end
		local cached = sideViews[side][value]
		if cached ~= nil then return cached end
		local instance: any = {}
		sideViews[side][value] = instance
		instanceNodes[instance] = value
		local methods: any = {}
		function methods:IsA(className: string): boolean
			return className == value.className or className == "Instance"
		end
		function methods:GetChildren(): { any }
			local result = {}
			for _, child in value.children do table.insert(result, view(child, side)) end
			return result
		end
		function methods:FindFirstChild(name: string): any return view(childNamed(value, name), side) end
		function methods:WaitForChild(name: string): any
			while childNamed(value, name) == nil do value.childAdded:Wait() end
			return view(childNamed(value, name), side)
		end
		function methods:SetAttribute(name: string, attribute: any)
			value.attributes[name] = attribute
			if value.attributeSignals[name] then value.attributeSignals[name]:fire() end
			value.attributeChanged:fire(name)
		end
		function methods:GetAttribute(name: string): any return value.attributes[name] end
		function methods:GetAttributeChangedSignal(name: string): any
			value.attributeSignals[name] = value.attributeSignals[name] or signal()
			return value.attributeSignals[name]
		end
		function methods:GetPropertyChangedSignal(name: string): any
			value.propertySignals[name] = value.propertySignals[name] or signal()
			return value.propertySignals[name]
		end
		function methods:FireServer(...: any)
			assert(side > 0, "FireServer requires a client")
			send(value, side, 0, ...)
		end
		function methods:FireClient(player: any, ...: any)
			assert(side == 0, "FireClient requires the server")
			local index = table.find(world.players, player)
			assert(index ~= nil, "unknown remote recipient")
			send(value, side, index, ...)
		end
		function methods:FireAllClients(...: any)
			assert(side == 0, "FireAllClients requires the server")
			for index = 1, clientCount do send(value, side, index, ...) end
		end
		function methods:Destroy()
			if value.destroyed then return end
			value.destroyed = true
			value.destroying:fire()
			for _, child in table.clone(value.children) do view(child, side):Destroy() end
			attach(value, nil)
			value.serverEvent:disconnectAll()
			for _, event in value.clientEvents do event:disconnectAll() end
			value.childAdded:disconnectAll()
			value.childRemoved:disconnectAll()
		end
		setmetatable(instance, {
			__index = function(_self, key)
				if key == "Name" then return value.name end
				if key == "ClassName" then return value.className end
				if key == "Parent" then return view(value.parent, side) end
				if key == "Source" then return value.source end
				if key == "Value" then return value.value end
				if key == "Changed" then return value.changed end
				if key == "AttributeChanged" then return value.attributeChanged end
				if key == "ChildAdded" then return instanceSignal(value.childAdded, side) end
				if key == "ChildRemoved" then return instanceSignal(value.childRemoved, side) end
				if key == "Destroying" then return value.destroying end
				if key == "OnServerEvent" then return value.serverEvent end
				if key == "OnServerInvoke" or key == "OnClientInvoke" then return value.invokeCallbacks[side] end
				if key == "OnClientEvent" then
					value.clientEvents[side] = value.clientEvents[side] or signal()
					return value.clientEvents[side]
				end
				return methods[key] or view(childNamed(value, key), side)
			end,
			__newindex = function(_self, key, property)
				if key == "Parent" then attach(value, instanceNodes[property])
				elseif key == "Name" then value.name = property
				elseif key == "Value" then value.value = property value.changed:fire(property)
				elseif key == "OnServerInvoke" or key == "OnClientInvoke" then value.invokeCallbacks[side] = property
				else error(`unsupported qualification property {key}`, 0) end
				if value.propertySignals[key] then value.propertySignals[key]:fire() end
			end,
		})
		return instance
	end

	local function addSources(directory: string, parent: any)
		local entries = fs.readDir(directory)
		table.sort(entries)
		for _, entry in entries do
			local path = directory .. "/" .. entry
			if fs.isFile(path) and string.match(entry, "%.luau?$") then
				local name = string.gsub(entry, "%.luau?$", "")
				if name == "init" then
					parent.className = "ModuleScript"
					parent.sourcePath = path
					parent.source = fs.readFile(path)
					sourceNodes[path] = parent
				else
					local child = node("ModuleScript", name, path)
					attach(child, parent)
					sourceNodes[path] = child
				end
			end
		end
		for _, entry in entries do
			local path = directory .. "/" .. entry
			if fs.isDir(path) then
				local child = childNamed(parent, entry)
				if child == nil then child = node("Folder", entry) attach(child, parent) end
				addSources(path, child)
			end
		end
	end

	local function mappedSources(mapping: any, name: string, parent: any): any
		local path = if mapping["$path"] ~= nil then "benchmarks/" .. mapping["$path"] else nil
		local module = node(if path ~= nil and fs.isFile(path) then "ModuleScript" else "Folder", name,
			if path ~= nil and fs.isFile(path) then path else nil)
		attach(module, parent)
		if path ~= nil and fs.isDir(path) then addSources(path, module) end
		for key, childMapping in mapping do
			if string.sub(key, 1, 1) ~= "$" then mappedSources(childMapping, key, module) end
		end
		return module
	end
	local generation = node("Folder", "Generation")
	local library
	if generated then
		library = node("Folder", "Library")
		attach(library, generation)
		addSources(`benchmarks/generated/{libraryId}`, library)
	else
		local project = serde.decode("json", fs.readFile("benchmarks/external-runtime-libraries.project.json"))
		local mapping = project.tree.ReplicatedStorage.RelayBenchmarkExternal.Libraries[runtimeNames[libraryId]]
		library = mappedSources(mapping, "Library", generation)
	end
	local adapterSources = node("Folder", "adapters")
	addSources("benchmarks/adapters", adapterSources)
	local endpoint
	if libraryId == "warp" then
		endpoint = node("ModuleScript", "Endpoint", "benchmarks/adapters/warp/Endpoint.luau")
		attach(endpoint, generation)
	end
	local replicatedStorage = node("Folder", "ReplicatedStorage")
	local relay = node("Folder", "RelayBenchmark")
	attach(relay, replicatedStorage)
	attach(adapterSources, relay)

	local function sideIndex(role: string, index: number?): number
		assert(role == "Server" or role == "Client", "invalid qualification side")
		local side = if role == "Server" then 0 else index or 1
		assert(side >= 0 and side <= clientCount, "invalid qualification client")
		return side
	end

	for side = 0, clientCount do
		sideViews[side] = {}
		moduleCaches[side] = {}
		sideGlobals[side] = {}
		local runService = { PostSimulation = signal(), Heartbeat = signal() }
		function runService:IsServer() return side == 0 end
		function runService:IsClient() return side ~= 0 end
		function runService:IsRunning() return true end
		function runService:IsStudio() return true end
		services[side] = {
			RunService = runService,
			Players = { PlayerAdded = signal(), PlayerRemoving = signal() },
			ReplicatedStorage = view(replicatedStorage, side),
			HttpService = {
				JSONEncode = function(_self, value) return serde.encode("json", value) end,
				JSONDecode = function(_self, value) return serde.decode("json", value) end,
			},
		}
	end
	for index = 1, clientCount do
		local player = { Name = `Player{index}`, UserId = 10_000 + index, Parent = services[0].Players }
		function player:IsA(className) return className == "Player" or className == "Instance" end
		instanceNodes[player] = node("Player", player.Name)
		world.players[index] = player
	end
	for side = 0, clientCount do
		local players = services[side].Players
		function players:GetPlayers() return table.clone(world.players) end
		players.LocalPlayer = world.players[side]
	end

	local function defer(callback: any, ...: any): thread
		local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
		table.insert(deferred, { thread = thread, arguments = table.pack(...) })
		return thread
	end
	local function delay(seconds: number, callback: any, ...: any): thread
		local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
		table.insert(deferred, { thread = thread, arguments = table.pack(...),
			dueFrame = world.frame + math.max(1, math.ceil(seconds * 60)) })
		return thread
	end

	loadModule = function(module: any, side: number): any
		local cached = moduleCaches[side][module]
		if cached ~= nil then return cached end
		assert(module.sourcePath ~= nil, "qualification require needs a module")
		local environment: any = {}
		for key, value in roblox do environment[key] = value end
		environment._G = sideGlobals[side]
		environment.game = { GetService = function(_self, name)
			assert(services[side][name] ~= nil, `unsupported qualification service {name}`)
			return services[side][name]
		end }
		environment.script = view(module, side)
		environment.Instance = { new = function(className, parent)
			local created = node(className, className)
			if parent ~= nil then attach(created, instanceNodes[parent]) end
			return view(created, side)
		end }
		environment.typeof = function(value)
			return if instanceNodes[value] ~= nil then "Instance" else hostTypeof(value)
		end
		environment.task = { spawn = start, defer = defer, delay = delay, cancel = coroutine.close }
		environment.task.wait = function(seconds: number?)
			local elapsed = math.max(1, math.ceil((seconds or 0) * 60)) / 60
			delay(elapsed, coroutine.running(), elapsed)
			return coroutine.yield()
		end
		environment.os = table.clone(os)
		environment.os.clock = function() return world.frame / 60 end
		environment.debug = table.clone(debug)
		environment.debug.setmemorycategory = function(_name: string) end
		-- Warp uses Random only to name callback registrations, never for payloads.
		environment.Random = { new = function()
			return { NextNumber = function()
				callbackKey += 1
				return callbackKey / 1_000_000
			end }
		end }
		environment.warn = function(...) table.insert(world.warnings, table.pack(...)) end
		environment.print = function(...) table.insert(world.logs, table.pack(...)) end
		environment.require = function(candidate)
			local dependency = instanceNodes[candidate]
			assert(dependency ~= nil, "qualification require must use a mapped ModuleScript")
			return loadModule(dependency, side)
		end
		local value = luau.load(module.source, {
			debugName = module.sourcePath, environment = environment, injectGlobals = true,
		})()
		moduleCaches[side][module] = value
		return value
	end

	function world.contextRoot(role: string, index: number?): any return view(generation, sideIndex(role, index)) end
	function world.loadLibrary(role: string, index: number?): any
		return loadModule(if generated then childNamed(library, role) else library, sideIndex(role, index))
	end
	function world.prepare(role: string, index: number?)
		if endpoint == nil then return end
		local thread = start(function() loadModule(endpoint, sideIndex(role, index)) end)
		for _ = 1, 120 do
			if coroutine.status(thread) == "dead" then return end
			world.step()
		end
		error("qualification preparation did not complete", 0)
	end
	function world.loadAdapter(path: string, role: string, index: number?): any
		local module = sourceNodes[path]
		assert(module ~= nil, `unmapped qualification adapter {path}`)
		return loadModule(module, sideIndex(role, index))
	end
	function world.step()
		world.frame += 1
		for side = 0, clientCount do services[side].RunService.PostSimulation:fire(1 / 60) end
		for side = 0, clientCount do services[side].RunService.Heartbeat:fire(1 / 60) end
		local ready = deferred
		deferred = {}
		for _, item in ready do
			if coroutine.status(item.thread) ~= "dead" then
				if item.dueFrame ~= nil and item.dueFrame > world.frame then
					table.insert(deferred, item)
				else
					resume(item.thread, table.unpack(item.arguments, 1, item.arguments.n))
				end
			end
		end
		local deliveries = pending
		pending = {}
		for _, item in deliveries do
			if item.recipient == 0 then
				item.remote.serverEvent:fire(world.players[item.sender], table.unpack(item.arguments, 1, item.arguments.n))
			elseif item.remote.clientEvents[item.recipient] then
				item.remote.clientEvents[item.recipient]:fire(table.unpack(item.arguments, 1, item.arguments.n))
			end
		end
	end
	return world
end

return table.freeze({ new = new })
