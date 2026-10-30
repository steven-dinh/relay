local fs = require("@lune/fs")
local luau = require("@lune/luau")
local DefinitionModule = require("../src/Definition")
local Schema = require("../src/Schema")
local ServerRuntime = require("./support/ServerRuntime")
local ClientRuntime = require("./support/ClientRuntime")

local relayMarker, definitionMarker = {}, {}
local definitionApi = { define = DefinitionModule.define, schema = Schema }
local definitionResults = table.pack(luau.load(fs.readFile("examples/paced-state/Definition.luau"), {
	debugName = "PacedStateDefinition",
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
})())
assert(definitionResults.n == 1, "the definition ModuleScript returns exactly one value")
local definition = definitionResults[1]

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
	storage.WaitForChild = function(self, name) return self[name] end
	return function(module)
		if module == relayMarker then return relayApi end
		if module == definitionMarker then return definition end
		error(`unexpected example module: {module}`)
	end
end

local function launchServer(runtime, captureLane)
	local heartbeat, destroying = signal(), signal()
	local originalGetService = runtime.game.GetService
	local game = { GetService = function(_, name)
		if name == "RunService" then
			return { Heartbeat = heartbeat, IsServer = function() return true end }
		end
		return originalGetService(runtime.game, name)
	end }
	local captured = {}
	local relayApi = {
		createServer = function(token, options)
			local server, problem = runtime.server.create(token, options)
			if captureLane and server ~= nil then
				local session = server
				local proxy = setmetatable({}, { __index = session })
				proxy.CreateState = function(_, ...)
					local lane, issue = session:CreateState(...)
					captured.stateLane = lane
					return lane, issue
				end
				server = proxy
			end
			captured.server = server
			return server, problem
		end,
	}
	local moduleRequire = wireModules(runtime.storage, relayApi)
	local output = { warnings = {}, prints = {} }
	luau.load(fs.readFile("examples/paced-state/Server.server.luau"), {
		debugName = "PacedStateServer",
		injectGlobals = true,
		environment = {
			game = game,
			script = { Destroying = destroying },
			require = moduleRequire,
			warn = function(...) table.insert(output.warnings, table.pack(...)) end,
			print = function(...) table.insert(output.prints, table.pack(...)) end,
		},
	})()
	return heartbeat, destroying, output, captured
end

local function launchClient(runtime, descriptor)
	local _, _, remote = runtime:transport(descriptor, false)
	local heartbeat, destroying = signal(), signal()
	local originalGetService = runtime.game.GetService
	local game = { GetService = function(_, name)
		if name == "RunService" then
			return { Heartbeat = heartbeat, IsClient = function() return true end }
		end
		return originalGetService(runtime.game, name)
	end }
	local relayApi = { createClient = runtime.module.create }
	local moduleRequire = wireModules(runtime.storage, relayApi)
	local output = { warnings = {}, prints = {} }
	luau.load(fs.readFile("examples/paced-state/Client.client.luau"), {
		debugName = "PacedStateClient",
		injectGlobals = true,
		environment = {
			game = game,
			script = { Destroying = destroying },
			require = moduleRequire,
			warn = function(...) table.insert(output.warnings, table.pack(...)) end,
			print = function(...) table.insert(output.prints, table.pack(...)) end,
		},
	})()
	return { runtime = runtime, remote = remote, heartbeat = heartbeat,
		destroying = destroying, output = output }
end

local function deliverInput(client, serverRuntime, player)
	local fire = assert(client.runtime.fires[#client.runtime.fires], "client paced input handoff")
	serverRuntime:remote().OnServerEvent:Fire(player, table.unpack(fire, 1, fire.n))
end

local function heartbeatClient(client, serverRuntime, deltaTime)
	client.runtime:advance(deltaTime)
	client.runtime.serverTime = serverRuntime.serverTime
	client.heartbeat:Fire(deltaTime)
end

local function deliverSnapshot(fire, clients, players)
	assert(fire.kind == "target")
	local index = assert(table.find(players, fire.player), "snapshot recipient belongs to the fixed roster")
	local client = clients[index]
	client.remote.OnClientEvent:fire(table.unpack(fire.values, 1, fire.values.n))
end

local function snapshotValues(client)
	local values = {}
	for _, entry in client.output.prints do
		if entry[1] == "Public snapshot" then values[#values + 1] = entry[2] end
	end
	return values
end

local function hasPrint(output, label)
	for _, entry in output.prints do
		if entry[1] == label then return true end
	end
	return false
end

local serverRuntime = ServerRuntime.new()
local players = { serverRuntime:addPlayer(), serverRuntime:addPlayer() }
local serverHeartbeat, serverDestroying, serverOutput, captured = launchServer(serverRuntime)
local server = assert(captured.server)
local root = serverRuntime.storage:FindFirstChild("RelayRemotes")
local descriptor = assert(root and root:FindFirstChild("Definition")).Value

local clients = {}
for index = 1, 2 do
	clients[index] = launchClient(ClientRuntime.create(), descriptor)
	clients[index].runtime.serverTime = serverRuntime.serverTime
end

-- Drain one recipient's public outbound budget; Independent State service must
-- still reach the other recipient and retain only the latest value for the first.
local refused = false
for _ = 1, 32 do
	local sent, problem = server.events.Snapshot:Send(players[1], 100, serverRuntime.serverTime)
	if not sent then
		assert(problem and problem.code == "OutboundRateLimited")
		refused = true
		break
	end
end
assert(refused, "the first player's bounded outbound budget is exercised")
table.clear(serverRuntime.fires)

local firstClient = clients[1]
local secondClient = clients[2]
local firstBaseline = #firstClient.runtime.fires
heartbeatClient(firstClient, serverRuntime, 1)
assert(#firstClient.runtime.fires == firstBaseline,
	"a manual pacer waits for its first interval after accepting a row")
heartbeatClient(firstClient, serverRuntime, 1 / 30)
assert(#firstClient.runtime.fires == firstBaseline + 1,
	"the client sends one application field through the manually stepped pacer")
deliverInput(firstClient, serverRuntime, players[1])
assert(server:GetDiagnostics().events.Input.dispatched == 1,
	"the server receives the timestamped C2S input through its real dispatcher")

serverRuntime:advance(0.05)
assert(#serverRuntime.fires == 1 and serverRuntime.fires[1].player == players[2],
	"Independent State progresses to the unpressured recipient")
deliverSnapshot(serverRuntime.fires[1], clients, players)
assert(#snapshotValues(secondClient) == 1 and snapshotValues(secondClient)[1] == 1
	and #snapshotValues(firstClient) == 0,
	"the pressured recipient keeps its pending absolute value without blocking the other")

-- A ten-second delayed Heartbeat yields one current value, not ten catch-up sends.
heartbeatClient(firstClient, serverRuntime, 10)
assert(#firstClient.runtime.fires == firstBaseline + 1,
	"a delayed Heartbeat queues one sample for the next paced service")
heartbeatClient(firstClient, serverRuntime, 1 / 30)
assert(#firstClient.runtime.fires == firstBaseline + 2,
	"a long Heartbeat delay emits one bounded current sample")
deliverInput(firstClient, serverRuntime, players[1])
assert(server:GetDiagnostics().events.Input.dispatched == 2)
serverRuntime:advance(0.5)
for _, fire in serverRuntime.fires do deliverSnapshot(fire, clients, players) end
local firstValues = snapshotValues(firstClient)
local secondValues = snapshotValues(secondClient)
assert(#firstValues == 1 and firstValues[1] == 2,
	"deferred latest progress replaces the stale value before the pressured recipient catches up")
assert(#secondValues >= 2 and secondValues[#secondValues] == 2,
	"the unpressured recipient receives each current absolute sample")

serverHeartbeat:Fire(10)
assert(hasPrint(serverOutput, "State local handoffs")
	and hasPrint(serverOutput, "Relay content units"),
	"the server samples State handoffs and bounded diagnostics outside packet handlers")
assert(hasPrint(firstClient.output, "Relay content units"),
	"the client samples traffic and bounded reports periodically")
local traffic = server:GetDiagnostics().traffic
local reports = server:GetDiagnostics().reports
assert(traffic ~= nil and reports ~= nil and reports.capacity == 16,
	"opt-in diagnostics expose traffic and a bounded report ring")

-- A too-early manual step leaves one bounded row in the pacer; Destroy discards it.
local pendingClientBaseline = #firstClient.runtime.fires
firstClient.heartbeat:Fire(1)
assert(#firstClient.runtime.fires == pendingClientBaseline)
firstClient.destroying:Fire()
firstClient.runtime:advance(1)
assert(#firstClient.runtime.fires == pendingClientBaseline and firstClient.runtime.connections == 0,
	"client teardown releases its pending manual pacer and handlers")

-- Leave one State service pending and prove script teardown cancels its timer/resources.
heartbeatClient(secondClient, serverRuntime, 1)
heartbeatClient(secondClient, serverRuntime, 1 / 30)
deliverInput(secondClient, serverRuntime, players[2])
assert(serverRuntime:activeTimers() > 0)
local fireCountBeforeDestroy = #serverRuntime.fires
serverDestroying:Fire()
assert(serverHeartbeat:Count() == 0 and serverRuntime:activeTimers() == 0
	and #serverRuntime.storage:GetChildren() == 0 and serverRuntime.connections == 0,
	"server teardown cancels the deferred lane and releases roster/session resources")
serverRuntime:advance(1)
assert(#serverRuntime.fires == fireCountBeforeDestroy,
	"no native State send occurs after lane/session teardown")
secondClient.destroying:Fire()
assert(secondClient.runtime.connections == 0)

-- A failed client pacer handoff is terminal and stops the producer once.
local failedClient = launchClient(ClientRuntime.create(), descriptor)
local failedClientBaseline = #failedClient.runtime.fires
failedClient.runtime.failFire = true
heartbeatClient(failedClient, serverRuntime, 1)
heartbeatClient(failedClient, serverRuntime, 1 / 30)
assert(#failedClient.output.warnings == 1
	and failedClient.heartbeat:Count() == 0 and failedClient.runtime.connections == 0,
	"a failed paced native send warns once and releases the client session")
failedClient.runtime.failFire = false
failedClient.runtime:advance(1)
failedClient.heartbeat:Fire(10)
assert(#failedClient.output.warnings == 1 and #failedClient.runtime.fires == failedClientBaseline,
	"a stopped client producer makes no late sends")
failedClient.destroying:Fire()

-- A failed automatic State handoff is observed by Heartbeat and cleans up once.
local failedServerRuntime = ServerRuntime.new()
local failedPlayers = { failedServerRuntime:addPlayer(), failedServerRuntime:addPlayer() }
local failedHeartbeat, failedDestroying, failedServerOutput, failedCapture = launchServer(failedServerRuntime, true)
local failedServer = assert(failedCapture.server)
local failedRoot = failedServerRuntime.storage:FindFirstChild("RelayRemotes")
local failedDescriptor = assert(failedRoot and failedRoot:FindFirstChild("Definition")).Value
local failedInputClient = launchClient(ClientRuntime.create(), failedDescriptor)
heartbeatClient(failedInputClient, failedServerRuntime, 1)
heartbeatClient(failedInputClient, failedServerRuntime, 1 / 30)
deliverInput(failedInputClient, failedServerRuntime, failedPlayers[1])
failedServerRuntime.throwFire = true
failedServerRuntime:advance(0.05)
assert(#failedServerOutput.warnings == 0,
	"automatic failure is reported by the producer's next Heartbeat inspection")
failedServerRuntime.throwFire = false
failedServerRuntime:advance(0.05)
local recoveredStatus = assert(failedCapture.stateLane):GetStatus().lastFlush
assert(recoveredStatus ~= nil and recoveredStatus.ok and recoveredStatus.report.logicalHandoffs == 1
	and #failedServerRuntime.fires == 1 and failedServerRuntime.fires[1].player == failedPlayers[2],
	"the second recipient succeeds on the next service and overwrites the failed lane status")
assert(failedServer:GetDiagnostics().counters.transportFailures == 1,
	"the monotonic session counter retains the earlier native handoff failure")
local failedFireCount = #failedServerRuntime.fires
failedHeartbeat:Fire(0)
assert(#failedServerOutput.warnings == 1 and failedHeartbeat:Count() == 0
	and failedServerRuntime:activeTimers() == 0
	and #failedServerRuntime.storage:GetChildren() == 0 and failedServerRuntime.connections == 0,
	"the failed automatic State handoff warns once and releases lane, roster and session resources")
failedServerRuntime.throwFire = false
failedServerRuntime:advance(1)
failedHeartbeat:Fire(10)
assert(#failedServerOutput.warnings == 1 and #failedServerRuntime.fires == failedFireCount,
	"a stopped server producer makes no late sends")
failedDestroying:Fire()
failedInputClient.destroying:Fire()

-- A remote ownership loss destroys the session without another Input; Heartbeat
-- must stop the otherwise-live producer and release the session resources.
local lostRuntime = ServerRuntime.new()
local lostPlayer = lostRuntime:addPlayer()
local lostHeartbeat, lostDestroying, lostOutput, lostCapture = launchServer(lostRuntime, true)
local lostServer = assert(lostCapture.server)
local lostRoot = assert(lostRuntime.storage:FindFirstChild("RelayRemotes"))
local lostDescriptor = assert(lostRoot:FindFirstChild("Definition")).Value
local lostClient = launchClient(ClientRuntime.create(), lostDescriptor)
heartbeatClient(lostClient, lostRuntime, 1)
heartbeatClient(lostClient, lostRuntime, 1 / 30)
deliverInput(lostClient, lostRuntime, lostPlayer)
assert(lostRuntime:activeTimers() > 0, "a queued State value owns pending work before transport loss")
lostRoot.Name = "Changed"
local lostStatus = lostServer:GetDiagnostics()
assert(lostStatus.state == "Destroyed" and lostStatus.counters.transportLosses == 1,
	"changing the Relay root terminally loses the server session")
lostHeartbeat:Fire(0)
assert(#lostOutput.warnings == 1 and lostOutput.warnings[1][2] == "TransportLoss"
	and lostHeartbeat:Count() == 0 and lostRuntime:activeTimers() == 0
	and #lostRuntime.storage:GetChildren() == 0 and lostRuntime.connections == 0,
	"the next Heartbeat warns once and releases the producer, lane and server session")
local lostFireCount = #lostRuntime.fires
lostRuntime:advance(1)
lostHeartbeat:Fire(10)
assert(#lostOutput.warnings == 1 and #lostRuntime.fires == lostFireCount,
	"a lost transport leaves no later sends or warnings")
lostDestroying:Fire()
lostClient.destroying:Fire()

print("Paced state example smoke passed")
