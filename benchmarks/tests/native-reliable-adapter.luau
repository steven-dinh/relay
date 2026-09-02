--!strict

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local AdapterContract = require("../adapters/AdapterContract")
local Fixtures = require("../fixtures/event-v1")

local STUDIO_VERSION = "0.650.0.6500000"
local ADAPTER_PATH = "benchmarks/adapters/native-reliable/init.luau"

local function assertExactKeys(value: unknown, expectedKeys: { string }, label: string)
	assert(type(value) == "table", `{label} must be a table`)
	local expected: { [string]: boolean } = {}
	for _, key in expectedKeys do
		expected[key] = true
	end

	local count = 0
	for key in next, value :: any do
		count += 1
		assert(type(key) == "string" and expected[key] == true, `{label} has an unexpected key`)
	end
	assert(count == #expectedKeys, `{label} must have exactly {#expectedKeys} keys`)
end

local function assertFrozenExact(value: unknown, expectedKeys: { string }, label: string)
	assertExactKeys(value, expectedKeys, label)
	assert(table.isfrozen(value :: any), `{label} must be frozen`)
end

local function assertFailsWith(callback: () -> (), expected: string, label: string)
	local ok, issue = pcall(callback)
	assert(not ok, `{label} must fail`)
	assert(tostring(issue) == expected, `{label} returned {tostring(issue)} instead of {expected}`)
end

local function repositoryIdentity(): any
	return {
		id = "native-reliable-test",
		displayName = "Native Reliable Test",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "native-reliable-test-library",
			displayName = "Native Reliable Test Library",
			version = "1.0.0",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/native-reliable-test",
				revision = string.rep("a", 40),
				checksum = "sha256:" .. string.rep("b", 64),
				license = "MIT",
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "SessionRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function workloadSelection(workloadId: string, recipientCount: number): any
	return {
		kind = "Workload",
		workloadId = workloadId,
		recipientCount = recipientCount,
	}
end

local function probeSelection(): any
	return {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
	}
end

local function supported(selection: any): any
	local result = AdapterContract.preflight(repositoryIdentity(), selection, STUDIO_VERSION)
	assert(result.kind == "Supported", "native adapter test selection must be supported")
	return result
end

local function newSignal(onDisconnect: () -> ()): any
	local records: { any } = {}
	local historical: { (...any) -> () } = {}
	local signal: any = {}

	function signal:Connect(callback: (...any) -> ()): any
		assert(self == signal, "signal Connect must use method syntax")
		assert(type(callback) == "function", "signal callback must be a function")
		local record: any = {
			callback = callback,
			connected = true,
		}
		local connection: any = {}
		function connection:Disconnect()
			assert(self == connection, "connection Disconnect must use method syntax")
			if not record.connected then
				return
			end
			record.connected = false
			onDisconnect()
		end
		table.insert(records, record)
		table.insert(historical, callback)
		return connection
	end

	function signal:fire(...: any)
		local snapshot = table.clone(records)
		for _, record in snapshot do
			if record.connected then
				record.callback(...)
			end
		end
	end

	function signal:fireStale(...: any)
		for _, callback in historical do
			callback(...)
		end
	end

	return signal
end

local instanceKinds: { [any]: string } = setmetatable({}, { __mode = "k" })
local activeWorld: any = nil
local hostTypeof = typeof

local function fakeTypeof(value: any): string
	if instanceKinds[value] ~= nil then
		return "Instance"
	end
	return hostTypeof(value)
end

local function newPlayer(userId: number): any
	local player: any = {
		UserId = userId,
	}
	function player:IsA(className: string): boolean
		assert(self == player, "Player IsA must use method syntax")
		return className == "Player" or className == "Instance"
	end
	instanceKinds[player] = "Player"
	return player
end

local function newWorld(clientCount: number): any
	local world: any = {
		destroyCalls = 0,
		disconnectCalls = 0,
		fireServerCalls = 0,
		fireAllClientsCalls = 0,
		getChildrenCalls = 0,
		players = {},
		roster = {},
		remote = nil,
		remotes = {},
	}
	for index = 1, clientCount do
		world.players[index] = newPlayer(10_000 + index)
	end
	world.roster = table.clone(world.players)

	local children: { any } = {}
	local childAdded = newSignal(function()
		world.disconnectCalls += 1
	end)
	local childRemoved = newSignal(function()
		world.disconnectCalls += 1
	end)
	local root: any = {
		Name = "Generation",
		ChildAdded = childAdded,
		ChildRemoved = childRemoved,
	}
	function root:FindFirstChild(name: string): any
		assert(self == root, "FindFirstChild must use method syntax")
		for _, child in children do
			if child.Name == name and child.Parent == root then
				return child
			end
		end
		return nil
	end
	function root:GetChildren(): { any }
		assert(self == root, "GetChildren must use method syntax")
		world.getChildrenCalls += 1
		return table.clone(children)
	end
	instanceKinds[root] = "Folder"
	world.root = root

	function world:createRemote(): any
		assert(self == world, "remote must be created by the active world")
		local state: any = {
			name = "RemoteEvent",
			parent = nil,
			destroyed = false,
		}
		local serverSignal = newSignal(function()
			world.disconnectCalls += 1
		end)
		local clientSignal = newSignal(function()
			world.disconnectCalls += 1
		end)
		local nameChangedSignal = newSignal(function()
			world.disconnectCalls += 1
		end)
		local remote: any = {}
		local methods: any = {}

		local function removeFromRoot()
			if state.parent ~= root then
				return
			end
			for index, child in children do
				if child == remote then
					table.remove(children, index)
					break
				end
			end
			state.parent = nil
			childRemoved:fire(remote)
		end

		function methods:IsA(className: string): boolean
			assert(self == remote, "IsA must use method syntax")
			return className == "RemoteEvent" or className == "Instance"
		end

		function methods:GetPropertyChangedSignal(propertyName: string): any
			assert(self == remote, "GetPropertyChangedSignal must use method syntax")
			assert(propertyName == "Name", "native adapter may observe only RemoteEvent.Name")
			return nameChangedSignal
		end

		function methods:FireServer(...: any)
			assert(self == remote, "FireServer must use method syntax")
			assert(not state.destroyed, "destroyed remote cannot fire")
			world.fireServerCalls += 1
			serverSignal:fire(world.players[1], ...)
		end

		function methods:FireAllClients(...: any)
			assert(self == remote, "FireAllClients must use method syntax")
			assert(not state.destroyed, "destroyed remote cannot fire")
			world.fireAllClientsCalls += 1
			clientSignal:fire(...)
		end

		function methods:Destroy()
			assert(self == remote, "Destroy must use method syntax")
			if state.destroyed then
				return
			end
			state.destroyed = true
			world.destroyCalls += 1
			removeFromRoot()
		end

		setmetatable(remote, {
			__index = function(_self, key)
				if key == "Name" then
					return state.name
				elseif key == "Parent" then
					return state.parent
				elseif key == "OnServerEvent" then
					return serverSignal
				elseif key == "OnClientEvent" then
					return clientSignal
				end
				return methods[key]
			end,
			__newindex = function(_self, key, value)
				if key == "Name" then
					assert(type(value) == "string", "RemoteEvent.Name must be a string")
					if state.name == value then
						return
					end
					state.name = value
					nameChangedSignal:fire()
					return
				elseif key == "Parent" then
					assert(value == nil or value == root, "remote parent must be nil or the generation root")
					if state.parent == value then
						return
					end
					removeFromRoot()
					if value == root then
						assert(not state.destroyed, "destroyed remote cannot be parented")
						state.parent = root
						table.insert(children, remote)
						childAdded:fire(remote)
					end
					return
				end
				error(`unsupported RemoteEvent property {tostring(key)}`, 0)
			end,
		})

		instanceKinds[remote] = "RemoteEvent"
		table.insert(world.remotes, remote)
		if world.remote == nil then
			world.remote = remote
		end
		return remote
	end

	function world:addRemote(name: string): any
		assert(self == world, "remote must be added to the active world")
		local remote = self:createRemote()
		remote.Name = name
		remote.Parent = root
		return remote
	end

	function world:setRoster(players: { any })
		assert(self == world, "roster must be set on the active world")
		self.roster = table.clone(players)
	end

	function world:newPlayer(userId: number): any
		assert(self == world, "Player must be created by the active world")
		return newPlayer(userId)
	end

	function world:activate()
		activeWorld = self
	end

	return world
end

local fakeInstance = {
	new = function(className: string): any
		assert(className == "RemoteEvent", "native adapter may create only a RemoteEvent")
		assert(activeWorld ~= nil, "a test world must be active")
		return activeWorld:createRemote()
	end,
}

local fakePlayers: any = {}
function fakePlayers:GetPlayers(): { any }
	assert(self == fakePlayers, "Players:GetPlayers must use method syntax")
	assert(activeWorld ~= nil, "a test world must be active")
	return table.clone(activeWorld.roster)
end

local fakeGame: any = {}
function fakeGame:GetService(serviceName: string): any
	assert(self == fakeGame, "game:GetService must use method syntax")
	assert(serviceName == "Players", "native adapter may request only Players")
	return fakePlayers
end

local adapterSource = fs.readFile(ADAPTER_PATH)
local adapterChunk = luau.load(adapterSource, {
	debugName = ADAPTER_PATH,
	environment = {
		game = fakeGame,
		Instance = fakeInstance,
		typeof = fakeTypeof,
	},
	injectGlobals = true,
})
local NativeReliable = adapterChunk()

assertFrozenExact(NativeReliable, { "constructServer", "constructClient" }, "native reliable factory")

local function observingFactory(): (any, any)
	local observed: any = {
		server = nil,
		clients = {},
	}
	local factory = {
		constructServer = function(context: any): any
			local side = NativeReliable.constructServer(context)
			observed.server = side
			return side
		end,
		constructClient = function(context: any): any
			local side = NativeReliable.constructClient(context)
			observed.clients[context.participantIndex] = side
			return side
		end,
	}
	return factory, observed
end

local function constructRig(selection: any, clientCount: number, serverSink: any, clientSinks: { any }): any
	local world = newWorld(clientCount)
	world:activate()
	local preflight = supported(selection)
	local factory, rawSides = observingFactory()
	local recipients = {}
	if selection.kind == "SeparateProbe" or selection.workloadId == "state-broadcast-s2c" then
		for index = 1, clientCount do
			recipients[index] = world.players[index]
		end
	end
	local server = AdapterContract.constructServer(preflight, factory, world.root, recipients, serverSink)
	local clients = {}
	for index = 1, clientCount do
		clients[index] = AdapterContract.constructClient(
			preflight,
			factory,
			world.root,
			index,
			clientSinks[index] or function() end
		)
	end
	return {
		world = world,
		server = server,
		clients = clients,
		rawSides = rawSides,
	}
end

local function cloneRecord(record: any): any
	local copied = {}
	for key, value in next, record do
		copied[key] = value
	end
	return copied
end

local function assertRecordUnchanged(before: any, after: any, label: string)
	local count = 0
	for key, value in next, after do
		count += 1
		assert(before[key] == value, `{label}.{tostring(key)} changed`)
	end
	local beforeCount = 0
	for _ in next, before do
		beforeCount += 1
	end
	assert(count == beforeCount, `{label} key set changed`)
end

local function assertPositional(delivery: any, expected: { any }, label: string)
	assertFrozenExact(delivery, { "kind", "values", "count" }, label)
	assert(delivery.kind == "Positional", `{label} must be positional`)
	assert(delivery.count == #expected, `{label} arity differs`)
	assert(table.isfrozen(delivery.values), `{label} values must be frozen`)
	for index, value in expected do
		assert(delivery.values[index] == value, `{label} value {index} differs`)
	end
end

-- Every Event V1 selection receives only the side operation owned by its direction.
do
	local c2s = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function() end, { function() end })
	assertFrozenExact(c2s.server, { "setup", "ready", "teardown" }, "C2S server side")
	assertFrozenExact(c2s.clients[1], { "setup", "ready", "teardown", "submit" }, "C2S client side")
	c2s.clients[1].teardown()
	c2s.server.teardown()

	local s2c = constructRig(workloadSelection("state-broadcast-s2c", 1), 1, function() end, { function() end })
	assertFrozenExact(s2c.server, { "setup", "ready", "teardown", "broadcast" }, "S2C server side")
	assertFrozenExact(s2c.clients[1], { "setup", "ready", "teardown" }, "S2C client side")
	s2c.clients[1].teardown()
	s2c.server.teardown()

	local probe = constructRig(probeSelection(), 1, function() end, { function() end })
	assertFrozenExact(probe.server, { "setup", "ready", "teardown", "broadcast" }, "probe server side")
	assertFrozenExact(probe.clients[1], { "setup", "ready", "teardown", "submit" }, "probe client side")
	probe.clients[1].teardown()
	probe.server.teardown()
end

-- Client discovery remains pending until the server-owned endpoint appears.
do
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function() end, { function() end })
	rig.clients[1].setup()
	assert(rig.clients[1].ready() == false, "missing client endpoint must remain pending")
	local unrelated = rig.world:addRemote("state")
	assert(rig.clients[1].ready() == false, "another payload's endpoint must not satisfy readiness")
	rig.server.setup()
	assert(rig.world.root:FindFirstChild("tiny") ~= nil, "server must create the selected payload endpoint")
	assert(rig.clients[1].ready() == true, "client must discover the selected payload endpoint")
	rig.clients[1].teardown()
	local disconnects = rig.world.disconnectCalls
	rig.clients[1].teardown()
	rig.rawSides.clients[1].teardown()
	assert(rig.world.disconnectCalls == disconnects, "double client teardown must be idempotent")
	rig.server.teardown()
	assert(unrelated.Parent == rig.world.root, "server teardown must preserve an unrelated payload endpoint")
end

-- A client set up after the server must discover the existing endpoint through the root scan.
do
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function() end, { function() end })
	rig.server.setup()
	local scansBeforeClient = rig.world.getChildrenCalls
	assert(rig.world.root:FindFirstChild("tiny") ~= nil, "server-first setup must create the endpoint")
	rig.clients[1].setup()
	assert(
		rig.world.getChildrenCalls == scansBeforeClient + 1,
		"later client setup must scan existing generation children exactly once"
	)
	assert(rig.clients[1].ready() == true, "later client must discover the existing endpoint")
	assert(rig.server.ready() == true, "server-first side must become ready")
	rig.clients[1].teardown()
	rig.server.teardown()
end

-- C2S delivery uses the engine-authenticated Player and exact tiny positional fields.
do
	local deliveries = {}
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function(delivery, metadata)
		table.insert(deliveries, { delivery = delivery, metadata = metadata })
	end, { function() end })
	rig.clients[1].setup()
	rig.server.setup()
	assert(rig.world.remote.Name == "tiny", "tiny selection must use the tiny endpoint")
	assert(rig.clients[1].ready() == true, "client must discover the server endpoint")

	local submission = Fixtures.generate("tiny-steady-c2s", 1).measured[1]
	local payload = Fixtures.newInput(submission)
	local before = cloneRecord(payload)
	rig.clients[1].submit(payload, "ContinueFrame")
	assert(#deliveries == 0, "server callback must reject delivery before server readiness")
	assertRecordUnchanged(before, payload, "pre-ready tiny payload")

	assert(rig.server.ready() == true, "server must become ready")
	rig.clients[1].submit(payload, "FlushBeforeReturn")
	assert(rig.world.fireServerCalls == 2, "each submit must use one native FireServer call")
	assert(#deliveries == 1, "ready server must receive one C2S delivery")
	local observed = deliveries[1]
	assertPositional(observed.delivery, { payload.sequence, payload.enabled }, "tiny C2S delivery")
	assertExactKeys(observed.metadata, { "kind", "sender" }, "C2S metadata")
	assert(observed.metadata.kind == "ClientToServer", "C2S metadata kind differs")
	assert(rawequal(observed.metadata.sender, rig.world.players[1]), "C2S must preserve Player identity")
	assertRecordUnchanged(before, payload, "tiny payload")

	local remote = rig.world.remote
	rig.clients[1].teardown()
	rig.server.teardown()
	local delivered = #deliveries
	remote.OnServerEvent:fireStale(rig.world.players[1], payload.sequence, payload.enabled)
	assert(#deliveries == delivered, "disconnected C2S callback must reject stale delivery")
	local destroys = rig.world.destroyCalls
	local disconnects = rig.world.disconnectCalls
	rig.server.teardown()
	rig.rawSides.server.teardown()
	assert(rig.world.destroyCalls == destroys, "double server teardown must not destroy twice")
	assert(rig.world.disconnectCalls == disconnects, "double server teardown must not disconnect twice")
end

-- State C2S submits the exact five positional fields without mutating the input.
do
	local deliveries = {}
	local rig = constructRig(workloadSelection("state-steady-c2s", 1), 1, function(delivery, metadata)
		table.insert(deliveries, { delivery = delivery, metadata = metadata })
	end, { function() end })
	rig.clients[1].setup()
	rig.server.setup()
	assert(rig.world.remote.Name == "state", "state C2S selection must use the state endpoint")
	assert(rig.server.ready() == true, "state C2S server must become ready")
	assert(rig.clients[1].ready() == true, "state C2S client must become ready")

	local submission = Fixtures.generate("state-steady-c2s", 1).measured[1]
	local payload = Fixtures.newInput(submission)
	local before = cloneRecord(payload)
	rig.clients[1].submit(payload, "FlushBeforeReturn")
	assert(rig.world.fireServerCalls == 1, "state C2S submit must use one native FireServer call")
	assert(#deliveries == 1, "state C2S server must receive one delivery")
	local observed = deliveries[1]
	assertPositional(observed.delivery, {
		payload.sequence,
		payload.entityId,
		payload.position,
		payload.yaw,
		payload.health,
	}, "state C2S delivery")
	assertExactKeys(observed.metadata, { "kind", "sender" }, "state C2S metadata")
	assert(observed.metadata.kind == "ClientToServer", "state C2S metadata kind differs")
	assert(rawequal(observed.metadata.sender, rig.world.players[1]), "state C2S must preserve Player identity")
	assertRecordUnchanged(before, payload, "state C2S payload")
	rig.clients[1].teardown()
	rig.server.teardown()
end

-- The tiny SeparateProbe executes one complete client request and server response.
do
	local serverDeliveries = {}
	local clientDeliveries = {}
	local rig = constructRig(probeSelection(), 1, function(delivery, metadata)
		table.insert(serverDeliveries, { delivery = delivery, metadata = metadata })
	end, { function(delivery, metadata)
		table.insert(clientDeliveries, { delivery = delivery, metadata = metadata })
	end })
	rig.clients[1].setup()
	rig.server.setup()
	assert(rig.world.remote.Name == "tiny", "tiny probe must use the tiny endpoint")
	assert(rig.server.ready() == true, "probe server must become ready")
	assert(rig.clients[1].ready() == true, "probe client must become ready")

	local sample = Fixtures.generateProbe("tiny-round-trip", 1).measured[1]
	local payload = Fixtures.newInput(sample)
	local before = cloneRecord(payload)
	rig.clients[1].submit(payload, "FlushBeforeReturn")
	assert(#serverDeliveries == 1, "probe server must receive one request")
	assert(#clientDeliveries == 0, "probe client must wait for the explicit response")
	assertPositional(serverDeliveries[1].delivery, { payload.sequence, payload.enabled }, "probe request")
	assertExactKeys(serverDeliveries[1].metadata, { "kind", "sender" }, "probe request metadata")
	assert(serverDeliveries[1].metadata.kind == "ClientToServer", "probe request direction differs")
	assert(
		rawequal(serverDeliveries[1].metadata.sender, rig.world.players[1]),
		"probe request must preserve Player identity"
	)

	rig.server.broadcast(payload, "FlushBeforeReturn")
	assert(rig.world.fireServerCalls == 1, "probe request must use one native FireServer call")
	assert(rig.world.fireAllClientsCalls == 1, "probe response must use one native FireAllClients call")
	assert(#clientDeliveries == 1, "probe client must receive one response")
	assertPositional(clientDeliveries[1].delivery, { payload.sequence, payload.enabled }, "probe response")
	assertExactKeys(clientDeliveries[1].metadata, { "kind" }, "probe response metadata")
	assert(clientDeliveries[1].metadata.kind == "ServerToClient", "probe response direction differs")
	assertRecordUnchanged(before, payload, "probe payload")
	rig.clients[1].teardown()
	rig.server.teardown()
end

-- Native broadcast routes one state payload to every client sink without mutation.
do
	local clientDeliveries = { {}, {}, {}, {} }
	local sinks = {}
	for index = 1, 4 do
		sinks[index] = function(delivery, metadata)
			table.insert(clientDeliveries[index], { delivery = delivery, metadata = metadata })
		end
	end
	local rig = constructRig(workloadSelection("state-broadcast-s2c", 4), 4, function() end, sinks)
	for _, client in rig.clients do
		client.setup()
	end
	rig.server.setup()
	assert(rig.world.remote.Name == "state", "state selection must use the state endpoint")
	assert(rig.server.ready() == true, "broadcast server must become ready")

	local submission = Fixtures.generate("state-broadcast-s2c", 1).measured[1]
	local payload = Fixtures.newInput(submission)
	local before = cloneRecord(payload)
	rig.server.broadcast(payload, "ContinueFrame")
	for index = 1, 4 do
		assert(#clientDeliveries[index] == 0, `client {index} must reject pre-ready broadcast`)
	end
	assertRecordUnchanged(before, payload, "pre-ready state payload")

	for index, client in rig.clients do
		assert(client.ready() == true, `client {index} must become ready`)
	end
	rig.server.broadcast(payload, "FlushBeforeReturn")
	assert(rig.world.fireAllClientsCalls == 2, "each broadcast must use one native FireAllClients call")
	for index = 1, 4 do
		assert(#clientDeliveries[index] == 1, `client {index} must receive one broadcast`)
		local observed = clientDeliveries[index][1]
		assertPositional(observed.delivery, {
			payload.sequence,
			payload.entityId,
			payload.position,
			payload.yaw,
			payload.health,
		}, `state S2C delivery {index}`)
		assertExactKeys(observed.metadata, { "kind" }, `S2C metadata {index}`)
		assert(observed.metadata.kind == "ServerToClient", `S2C metadata {index} kind differs`)
	end
	assertRecordUnchanged(before, payload, "state payload")

	local remote = rig.world.remote
	for _, client in rig.clients do
		client.teardown()
		client.teardown()
	end
	assert(rig.world.destroyCalls == 0, "clients must not destroy the server-owned endpoint")
	local counts = {}
	for index = 1, 4 do
		counts[index] = #clientDeliveries[index]
	end
	remote.OnClientEvent:fireStale(
		payload.sequence,
		payload.entityId,
		payload.position,
		payload.yaw,
		payload.health
	)
	for index = 1, 4 do
		assert(#clientDeliveries[index] == counts[index], `client {index} must reject stale broadcast`)
	end

	rig.server.teardown()
	assert(rig.world.destroyCalls == 1, "server teardown must destroy its endpoint once")
	assert(rig.world.root:FindFirstChild("state") == nil, "destroyed endpoint must leave the generation root")
	local disconnects = rig.world.disconnectCalls
	rig.server.teardown()
	rig.rawSides.server.teardown()
	for _, rawClient in rig.rawSides.clients do
		rawClient.teardown()
	end
	assert(rig.world.destroyCalls == 1, "raw double teardown must remain idempotent")
	assert(rig.world.disconnectCalls == disconnects, "raw double teardown must not repeat cleanup")
end

-- A duplicate selected endpoint is a permanent conflict for both sides.
do
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function() end, { function() end })
	rig.clients[1].setup()
	rig.server.setup()
	local duplicate = rig.world:addRemote("tiny")
	assertFailsWith(function()
		rig.server.ready()
	end, "ADAPTER_E_READY", "duplicate endpoint server readiness")
	assertFailsWith(function()
		rig.clients[1].ready()
	end, "ADAPTER_E_READY", "duplicate endpoint client readiness")
	rig.clients[1].teardown()
	rig.server.teardown()
	assert(duplicate.Parent == rig.world.root, "server must destroy only its owned endpoint")
	assert(rig.world.destroyCalls == 1, "duplicate endpoint must not be destroyed by adapter teardown")
end

-- Removing or renaming the selected endpoint invalidates readiness.
do
	local removed = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function() end, { function() end })
	removed.clients[1].setup()
	removed.server.setup()
	removed.world.remote.Parent = nil
	assertFailsWith(function()
		removed.server.ready()
	end, "ADAPTER_E_READY", "removed endpoint server readiness")
	assertFailsWith(function()
		removed.clients[1].ready()
	end, "ADAPTER_E_READY", "removed endpoint client readiness")
	removed.clients[1].teardown()
	removed.server.teardown()

	local renamed = constructRig(workloadSelection("state-broadcast-s2c", 1), 1, function() end, { function() end })
	renamed.clients[1].setup()
	renamed.server.setup()
	renamed.world.remote.Name = "state-renamed"
	assertFailsWith(function()
		renamed.server.ready()
	end, "ADAPTER_E_READY", "renamed endpoint server readiness")
	assertFailsWith(function()
		renamed.clients[1].ready()
	end, "ADAPTER_E_READY", "renamed endpoint client readiness")
	renamed.clients[1].teardown()
	renamed.server.teardown()
end

-- Removing or renaming a ready endpoint closes delivery and all owned operations.
do
	local removedDeliveries = {}
	local removed = constructRig(workloadSelection("tiny-steady-c2s", 1), 1, function(delivery, metadata)
		table.insert(removedDeliveries, { delivery = delivery, metadata = metadata })
	end, { function() end })
	removed.clients[1].setup()
	removed.server.setup()
	assert(removed.server.ready() == true, "removed endpoint server must first become ready")
	assert(removed.clients[1].ready() == true, "removed endpoint client must first become ready")
	local removedRemote = removed.world.remote
	local removedPayload = Fixtures.newInput(Fixtures.generate("tiny-steady-c2s", 1).measured[1])
	removedRemote.Parent = nil
	assertFailsWith(function()
		removed.clients[1].submit(removedPayload, "FlushBeforeReturn")
	end, "ADAPTER_E_SUBMIT", "removed endpoint client submit")
	removedRemote.OnServerEvent:fireStale(
		removed.world.players[1],
		removedPayload.sequence,
		removedPayload.enabled
	)
	assert(#removedDeliveries == 0, "removed endpoint must keep the server callback closed")
	assert(removed.world.fireServerCalls == 0, "removed endpoint submit must not call FireServer")
	removed.clients[1].teardown()
	removed.server.teardown()

	local renamedDeliveries = {}
	local renamed = constructRig(workloadSelection("state-broadcast-s2c", 1), 1, function() end, { function(delivery, metadata)
		table.insert(renamedDeliveries, { delivery = delivery, metadata = metadata })
	end })
	renamed.clients[1].setup()
	renamed.server.setup()
	assert(renamed.server.ready() == true, "renamed endpoint server must first become ready")
	assert(renamed.clients[1].ready() == true, "renamed endpoint client must first become ready")
	local renamedRemote = renamed.world.remote
	local renamedPayload = Fixtures.newInput(Fixtures.generate("state-broadcast-s2c", 1).measured[1])
	renamedRemote.Name = "state-renamed"
	assertFailsWith(function()
		renamed.server.broadcast(renamedPayload, "FlushBeforeReturn")
	end, "ADAPTER_E_BROADCAST", "renamed endpoint server broadcast")
	renamedRemote.OnClientEvent:fireStale(
		renamedPayload.sequence,
		renamedPayload.entityId,
		renamedPayload.position,
		renamedPayload.yaw,
		renamedPayload.health
	)
	assert(#renamedDeliveries == 0, "renamed endpoint must keep the client callback closed")
	assert(renamed.world.fireAllClientsCalls == 0, "renamed endpoint broadcast must not call FireAllClients")
	renamed.clients[1].teardown()
	renamed.server.teardown()
end

-- Server send readiness requires the exact Player identity set, independent of roster order.
do
	local reordered = constructRig(workloadSelection("state-broadcast-s2c", 4), 4, function() end, {
		function() end,
		function() end,
		function() end,
		function() end,
	})
	reordered.server.setup()
	reordered.world:setRoster({
		reordered.world.players[4],
		reordered.world.players[3],
		reordered.world.players[2],
		reordered.world.players[1],
	})
	assert(reordered.server.ready() == true, "roster order must not affect exact Player membership")
	reordered.server.teardown()

	local missing = constructRig(workloadSelection("state-broadcast-s2c", 4), 4, function() end, {
		function() end,
		function() end,
		function() end,
		function() end,
	})
	missing.server.setup()
	missing.world:setRoster({ missing.world.players[1], missing.world.players[2], missing.world.players[3] })
	assertFailsWith(function()
		missing.server.ready()
	end, "ADAPTER_E_READY", "missing Player roster readiness")
	missing.server.teardown()

	local replaced = constructRig(workloadSelection("state-broadcast-s2c", 4), 4, function() end, {
		function() end,
		function() end,
		function() end,
		function() end,
	})
	replaced.server.setup()
	replaced.world:setRoster({
		replaced.world.players[1],
		replaced.world.players[2],
		replaced.world.players[3],
		replaced.world:newPlayer(99_999),
	})
	assertFailsWith(function()
		replaced.server.ready()
	end, "ADAPTER_E_READY", "replaced Player roster readiness")
	replaced.server.teardown()
end

print("PASS Relay.Benchmarks.NativeReliableAdapter")
