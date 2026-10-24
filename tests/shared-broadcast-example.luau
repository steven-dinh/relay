local fs = require("@lune/fs")
local luau = require("@lune/luau")
local DefinitionModule = require("../src/Definition")
local Schema = require("../src/Schema")
local BatchFrame = require("../src/internal/BatchFrame")
local ServerRuntime = require("./support/ServerRuntime")
local ClientRuntime = require("./support/ClientRuntime")

local relayMarker, definitionMarker = {}, {}
local definitionApi = { define = DefinitionModule.define, schema = Schema }
local definition = luau.load(fs.readFile("examples/shared-broadcast/Definition.luau"), {
	debugName = "SharedBroadcastDefinition",
	injectGlobals = true,
	environment = {
		game = { GetService = function(_, name)
			assert(name == "ReplicatedStorage")
			return { Relay = relayMarker }
		end },
		require = function(module)
			assert(module == relayMarker)
			return definitionApi
		end,
	},
})()

local function signal()
	local listeners = {}
	local value = {}
	function value:Connect(callback)
		local connection = { Connected = true }
		function connection:Disconnect()
			if self.Connected then
				self.Connected = false
				listeners[self] = nil
			end
		end
		listeners[connection] = callback
		return connection
	end
	function value:Fire(...)
		for connection, callback in table.clone(listeners) do
			if connection.Connected then callback(...) end
		end
	end
	function value:Count()
		local count = 0
		for _ in listeners do count += 1 end
		return count
	end
	return value
end

local function wireModules(storage, relayApi)
	storage.Relay = relayMarker
	storage.Definition = definitionMarker
	storage.WaitForChild = function(self, name)
		return self[name]
	end
	return function(module)
		if module == relayMarker then return relayApi end
		if module == definitionMarker then return definition end
		error(`unexpected example module: {module}`)
	end
end

local function launchServer(runtime)
	local heartbeat, destroying = signal(), signal()
	local originalGetService = runtime.game.GetService
	local game = { GetService = function(_, name)
		if name == "RunService" then
			return { Heartbeat = heartbeat, IsServer = function() return true end }
		end
		return originalGetService(runtime.game, name)
	end }
	local relayApi = {
		createServer = runtime.server.create,
	}
	local moduleRequire = wireModules(runtime.storage, relayApi)
	local output = { warnings = {}, prints = {} }
	luau.load(fs.readFile("examples/shared-broadcast/Server.server.luau"), {
		debugName = "SharedBroadcastServer",
		injectGlobals = true,
		environment = {
			game = game,
			script = { Destroying = destroying },
			require = moduleRequire,
			warn = function(...) table.insert(output.warnings, table.pack(...)) end,
			print = function(...) table.insert(output.prints, table.pack(...)) end,
		},
	})()
	return heartbeat, destroying, output
end

local function launchClient(runtime, descriptor)
	local _, _, remote = runtime:transport(descriptor, false)
	local destroying = signal()
	local relayApi = { createClient = runtime.module.create }
	local moduleRequire = wireModules(runtime.storage, relayApi)
	local output = { prints = {} }
	luau.load(fs.readFile("examples/shared-broadcast/Client.client.luau"), {
		debugName = "SharedBroadcastClient",
		injectGlobals = true,
		environment = {
			game = runtime.game,
			script = { Destroying = destroying },
			require = moduleRequire,
			print = function(...) table.insert(output.prints, table.pack(...)) end,
		},
	})()
	return remote, destroying, output
end

local serverRuntime = ServerRuntime.new()
serverRuntime:addPlayer()
serverRuntime:addPlayer()
local heartbeat, serverDestroying = launchServer(serverRuntime)
local root = serverRuntime.storage:FindFirstChild("RelayRemotes")
local descriptor = assert(root and root:FindFirstChild("Definition")).Value

local clients = {}
for index = 1, 2 do
	local runtime = ClientRuntime.create()
	local remote, destroying, clientOutput = launchClient(runtime, descriptor)
	-- The real client script connects both handlers before Start; actual packet
	-- delivery below verifies the named fields arrive in FIFO order.
	clients[index] = { runtime = runtime, remote = remote, destroying = destroying, output = clientOutput }
end

heartbeat:Fire(0.5)
assert(serverRuntime:activeTimers() == 0 and #serverRuntime.fires == 0)
heartbeat:Fire(0.5)
assert(serverRuntime:activeTimers() == 1 and #serverRuntime.fires == 0)
serverRuntime:advance(1 / 60)
assert(#serverRuntime.fires == 1 and serverRuntime.fires[1].kind == "broadcast"
	and serverRuntime.fires[1].values.n == 2 and serverRuntime.fires[1].values[1] == 0,
	"one reliable native shared broadcast carries the first populated window")
local firstHeader = assert(BatchFrame.header(serverRuntime.fires[1].values[2], 8_192))
assert(firstHeader.kind == 1 and firstHeader.count == 2)

for _, client in clients do
	client.remote.OnClientEvent:fire(table.unpack(serverRuntime.fires[1].values, 1, serverRuntime.fires[1].values.n))
	assert(#client.output.prints == 2
		and client.output.prints[1][1] == "Public round" and client.output.prints[1][2] == 1
		and client.output.prints[2][1] == "Public announcement"
		and client.output.prints[2][2] == "Round 1 is live",
		"both client handlers receive the exact FIFO fields")
end

-- A long Heartbeat step emits one fresh update, rather than one update per missed second.
heartbeat:Fire(10.5)
assert(serverRuntime:activeTimers() == 1)
serverRuntime:advance(1 / 60)
assert(#serverRuntime.fires == 2 and serverRuntime:activeTimers() == 0)
local secondHeader = assert(BatchFrame.header(serverRuntime.fires[2].values[2], 8_192))
assert(secondHeader.count == 2)
for _, client in clients do
	client.remote.OnClientEvent:fire(table.unpack(serverRuntime.fires[2].values, 1, serverRuntime.fires[2].values.n))
	assert(#client.output.prints == 4 and client.output.prints[3][2] == 2
		and client.output.prints[4][2] == "Round 2 is live")
end

-- Destroy with another automatic window pending; its timer cannot send later.
heartbeat:Fire(1)
assert(serverRuntime:activeTimers() == 1)
serverDestroying:Fire()
assert(heartbeat:Count() == 0 and serverRuntime:activeTimers() == 0
	and #serverRuntime.storage:GetChildren() == 0 and serverRuntime.connections == 0)
serverRuntime:advance(1)
assert(#serverRuntime.fires == 2, "destroy cancels a pending shared broadcast timer")

-- A terminal automatic handoff failure is reported once, then stops the producer.
local failedRuntime = ServerRuntime.new()
failedRuntime:addPlayer()
local failedHeartbeat, _, failedOutput = launchServer(failedRuntime)
failedHeartbeat:Fire(1)
failedRuntime.throwFire = true
failedRuntime:advance(1 / 60)
failedHeartbeat:Fire(1)
assert(#failedOutput.warnings == 1 and failedHeartbeat:Count() == 0
	and failedRuntime:activeTimers() == 0 and #failedRuntime.storage:GetChildren() == 0,
	"failed automatic handoff stops and cleans up the producer once")
failedHeartbeat:Fire(10)
assert(#failedOutput.warnings == 1 and #failedRuntime.fires == 0)

for _, client in clients do client.destroying:Fire() end

print("Shared broadcast example smoke passed")
