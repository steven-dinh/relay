local Definition = require("../src/Definition")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local definition = assert(Definition.define({
	name = "TransportNamespaceProof", version = 1, readiness = true, events = {
		Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
		State = { id = 2, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
		Other = { id = 3, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
	},
}))
local descriptor = Definition.get(definition).descriptor

local function serverOptions(namespace, capacity)
	local options = { inboundRate = {
		perPlayer = { capacity = capacity or 4096, refillPerSecond = 1 },
		aggregate = { capacity = math.max(capacity or 4096, 32768), refillPerSecond = 1 },
	} }
	if namespace ~= nil then options.namespace = namespace end
	return options
end

local function clientOptions(namespace)
	local options = { startupTimeoutSeconds = 3 }
	if namespace ~= nil then options.namespace = namespace end
	return options
end

local function expectCode(expected, value, problem)
	assert((value == nil or value == false) and problem ~= nil and problem.code == expected,
		`expected {expected}, got {if problem then problem.code else "success"}`)
end

local function expectInvalidClient(namespace)
	local runtime = ClientRuntime.create()
	local value, problem = runtime.module.create(definition, clientOptions(namespace))
	expectCode("InvalidOptions", value, problem)
end

local function expectInvalidServer(namespace)
	local runtime = ServerRuntime.new()
	local value, problem = runtime.server.create(definition, serverOptions(namespace))
	expectCode("InvalidOptions", value, problem)
end

local invalidNamespaces = { "", "Upper", "1st", "a.b", "a/b", "a:b", string.rep("a", 33), false, 7 }
for _, namespace in invalidNamespaces do
	expectInvalidClient(namespace)
	expectInvalidServer(namespace)
end
local maximumNamespace = "a" .. string.rep("0", 31)
assert(ClientRuntime.create().module.create(definition, clientOptions(maximumNamespace)))
assert(ServerRuntime.new().server.create(definition, serverOptions(maximumNamespace)))

-- Options are snapshotted at creation, and omission remains a distinct default root.
do
	local clientRuntime = ClientRuntime.create()
	clientRuntime:transport(descriptor, false, "RelayRemotes_game")
	local options = clientOptions("game")
	local client = assert(clientRuntime.module.create(definition, options))
	options.namespace = "changed"
	assert(client:Start())
	assert(clientRuntime.storage:FindFirstChild("RelayRemotes_game") ~= nil)
	assert(clientRuntime.storage:FindFirstChild("RelayClientSession_RelayRemotes_game") ~= nil)
	client:Destroy()

	local serverRuntime = ServerRuntime.new()
	local optionsForServer = serverOptions("game")
	local server = assert(serverRuntime.server.create(definition, optionsForServer))
	optionsForServer.namespace = "changed"
	assert(server:Start())
	assert(serverRuntime.storage:FindFirstChild("RelayRemotes_game") ~= nil)
	server:Destroy()
end

-- Default, game, and package sessions route independently and bind readiness to their own remote.
do
	local names = { false, "game", "package" }
	local serverRuntime = ServerRuntime.new()
	local player = serverRuntime:addPlayer()
	local clientRuntime = ClientRuntime.create()
	local sessions = {}
	local serverReceives, clientReceives, otherReceives = {}, {}, {}
	for index, name in names do
		local namespace = if name == false then nil else name
		local server = assert(serverRuntime.server.create(definition, serverOptions(namespace)))
		assert(server:Start())
		local rootName = if namespace == nil then "RelayRemotes" else `RelayRemotes_{namespace}`
		local root, _, clientRemote = clientRuntime:transport(descriptor, false, rootName)
		local client = assert(clientRuntime.module.create(definition, clientOptions(namespace)))
		local serverRemote = assert(serverRuntime.storage:FindFirstChild(rootName))
		serverRemote = assert(serverRemote:FindFirstChild("Reliable"))
		serverReceives[index], clientReceives[index], otherReceives[index] = 0, 0, 0
		assert(server.events.Input:Connect(function(sender, value)
			assert(sender == player and value == index + 10)
			serverReceives[index] += 1
		end))
		assert(client.events.State:Connect(function(value)
			assert(value == index + 20)
			clientReceives[index] += 1
		end))
		if namespace == "game" then
			assert(client.events.Other:Connect(function(value)
				assert(value == 77)
				otherReceives[index] += 1
			end))
		end
		assert(client:Start())
		sessions[index] = {
			server = server, serverRemote = serverRemote, client = client, clientRemote = clientRemote,
			clientRuntime = clientRuntime, serverRuntime = serverRuntime, player = player,
			clientCursor = 1, serverCursor = 1, name = name,
			root = root,
		}
	end

	local function pump(session)
		local clientRuntimeForSession, serverRuntimeForSession = session.clientRuntime, session.serverRuntime
		for _ = 1, 12 do
			local progressed = false
			while session.clientCursor <= #clientRuntimeForSession.fires do
				local fire = clientRuntimeForSession.fires[session.clientCursor]
				session.clientCursor += 1
				if fire.remote == session.clientRemote then
					session.serverRemote.OnServerEvent:Fire(session.player, table.unpack(fire, 1, fire.n))
					progressed = true
				end
			end
			while session.serverCursor <= #serverRuntimeForSession.fires do
				local fire = serverRuntimeForSession.fires[session.serverCursor]
				session.serverCursor += 1
				if fire.remote == session.serverRemote
					and (fire.kind == "broadcast" or fire.player == session.player) then
					session.clientRemote.OnClientEvent:fire(table.unpack(fire.values, 1, fire.values.n))
					progressed = true
				end
			end
			if not progressed then return end
		end
		assert(false, "readiness exchange did not quiesce")
	end

	for _, session in sessions do pump(session) end
	for index, session in sessions do
		local ready = assert(session.server.events.State:GetReadyPlayers())
		assert(table.find(ready, player) ~= nil, "each namespace must bind its own readiness Hello/Ack")
		local otherReady = assert(session.server.events.Other:GetReadyPlayers())
		assert((table.find(otherReady, player) ~= nil) == (session.name == "game"),
			"readiness masks must not leak between namespaces")
	end

	local initialClientScans, initialServerScans = clientRuntime.storageScans, serverRuntime.storageScans
	for index, session in sessions do
		assert(session.client.events.Input:Send(index + 10))
		pump(session)
		assert(serverReceives[index] == 1 and clientReceives[index] == 0)
		assert(session.server.events.State:Send(player, index + 20))
		pump(session)
		assert(clientReceives[index] == 1 and serverReceives[index] == 1)
		if session.name == "game" then
			assert(session.server.events.Other:Send(player, 77))
			pump(session)
		end
		assert(otherReceives[index] == if session.name == "game" then 1 else 0)
	end
	assert(clientRuntime.storageScans == initialClientScans and serverRuntime.storageScans == initialServerScans,
		"packet routing and readiness must not enumerate storage siblings")

	sessions[2].client:Destroy()
	pump(sessions[2])
	local closedReady = assert(sessions[2].server.events.State:GetReadyPlayers())
	assert(table.find(closedReady, player) == nil, "Destroy closes readiness only on its own namespace")
	for _, index in { 1, 3 } do
		assert(sessions[index].client.events.Input:Send(index + 10))
		pump(sessions[index])
		assert(serverReceives[index] == 2)
	end
	sessions[3].server:Destroy()
	assert(serverRuntime.storage:FindFirstChild("RelayRemotes_package") == nil)
	assert(serverRuntime.storage:FindFirstChild("RelayRemotes") ~= nil
		and serverRuntime.storage:FindFirstChild("RelayRemotes_game") ~= nil)
	assert(sessions[1].client.events.Input:Send(11))
	pump(sessions[1])
	assert(serverReceives[1] == 3, "destroying one server namespace must leave the default route alive")

	for index, session in sessions do
		if index ~= 2 and index ~= 3 then session.client:Destroy() end
		if index ~= 3 then session.server:Destroy() end
	end
end

-- Malformed payload admission and per-player budgets are local to each server session.
do
	local inputOnly = assert(Definition.define({ name = "NamespaceBudgetProof", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
	} }))
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local default = assert(runtime.server.create(inputOnly, serverOptions(nil, 1)))
	local game = assert(runtime.server.create(inputOnly, serverOptions("game", 1)))
	assert(default:Start() and game:Start())
	local calls = { default = 0, game = 0 }
	assert(default.events.Input:Connect(function() calls.default += 1 end))
	assert(game.events.Input:Connect(function() calls.game += 1 end))
	runtime.storage:FindFirstChild("RelayRemotes"):FindFirstChild("Reliable").OnServerEvent:Fire(player, 1, {})
	runtime.storage:FindFirstChild("RelayRemotes"):FindFirstChild("Reliable").OnServerEvent:Fire(player, 1, 1)
	runtime.storage:FindFirstChild("RelayRemotes_game"):FindFirstChild("Reliable").OnServerEvent:Fire(player, 1, 1)
	assert(calls.default == 0 and calls.game == 1)
	assert(default:GetDiagnostics().counters.invalidPayload == 1
		and default:GetDiagnostics().counters.perPlayerRate == 1
		and game:GetDiagnostics().counters.dispatched == 1,
		"malformed input is charged to its namespace without spending another namespace's budget")
	default:Destroy()
	game:Destroy()
end

-- Duplicate server roots collide across module copies, and reserved-prefix occupants count toward capacity.
do
	local runtime = ServerRuntime.new()
	local copies = { runtime.server }
	for index = 2, 7 do copies[index] = runtime.reloadServer() end
	local servers = {}
	for index = 1, 7 do
		local server = assert(copies[index].create(definition, serverOptions(`slot{index}`)))
		assert(server:Start())
		servers[index] = server
	end
	local foreign = runtime.newInstance("Folder")
	foreign.Name = "RelayRemotes_foreign"
	foreign.Parent = runtime.storage
	local rejectedEighth = assert(runtime.server.create(definition, serverOptions("slot8")))
	expectCode("RemoteOwnershipConflict", rejectedEighth:Start())
	assert(runtime.storage:FindFirstChild("RelayRemotes_slot8") == nil)
	foreign.Name = "foreign"
	local eighth = assert(runtime.server.create(definition, serverOptions("slot8")))
	assert(eighth:Start(), "failed named startup must release its keyed guard")
	servers[8] = eighth
	local sameCopy = assert(runtime.server.create(definition, serverOptions("slot8")))
	expectCode("AlreadyStarted", sameCopy:Start())
	local otherCopy = runtime.reloadServer()
	local collision = assert(otherCopy.create(definition, serverOptions("slot8")))
	expectCode("RemoteOwnershipConflict", collision:Start())
	local ninth = assert(otherCopy.create(definition, serverOptions("slot9")))
	expectCode("RemoteOwnershipConflict", ninth:Start())
	local default = assert(otherCopy.create(definition, serverOptions(nil)))
	assert(default:Start(), "the unnamed default slot is independent of eight named roots")
	default:Destroy()
	for index = 1, 8 do servers[index]:Destroy() end
end

-- Client markers enforce cross-copy capacity, release failed claims, and preserve foreign children.
do
	local runtime = ClientRuntime.create()
	runtime:transport(descriptor, false, "RelayRemotes_game")
	for index = 1, 8 do
		runtime:instance("Folder", `RelayClientSession_unrelated_{index}`, runtime.storage)
	end
	local client = assert(runtime.module.create(definition, clientOptions("game")))
	assert(client:Start(), "unrelated RelayClientSession_ siblings do not consume named slots")
	client:Destroy()
end

do
	local runtime = ClientRuntime.create()
	for index = 1, 8 do
		local name = `RelayRemotes_slot{index}`
		runtime:transport(descriptor, false, name)
	end
	local clients = {}
	local firstCopy = runtime.module
	for index = 1, 7 do
		local client = assert(firstCopy.create(definition, clientOptions(`slot{index}`)))
		assert(client:Start())
		clients[index] = client
	end
	local foreign = runtime:instance("Folder", "RelayClientSession_RelayRemotes_corrupt", runtime.storage)
	local rejectedEighth = assert(firstCopy.create(definition, clientOptions("slot8")))
	expectCode("RemoteOwnershipConflict", rejectedEighth:Start())
	assert(runtime.storage:FindFirstChild("RelayClientSession_RelayRemotes_slot8") == nil)
	foreign.Name = "foreign"
	local eighth = assert(firstCopy.create(definition, clientOptions("slot8")))
	assert(eighth:Start(), "failed marker capacity claim must release its keyed guard")
	clients[8] = eighth
	local duplicate = assert(firstCopy.create(definition, clientOptions("slot8")))
	expectCode("AlreadyStarted", duplicate:Start())
	local otherCopy = runtime.reloadModule()
	local collision = assert(otherCopy.create(definition, clientOptions("slot8")))
	expectCode("AlreadyStarted", collision:Start())
	local ninth = assert(otherCopy.create(definition, clientOptions("slot9")))
	expectCode("RemoteOwnershipConflict", ninth:Start())
	runtime:transport(descriptor, false, "RelayRemotes")
	local default = assert(otherCopy.create(definition, clientOptions(nil)))
	assert(default:Start(), "the default client marker does not consume named capacity")
	default:Destroy()
	for index = 1, 8 do clients[index]:Destroy() end
end

-- A cross-copy server collision and a live duplicate root affect only the matching namespace.
do
	local serverRuntime = ServerRuntime.new()
	local server = assert(serverRuntime.server.create(definition, serverOptions("game")))
	assert(server:Start())
	local otherCopy = serverRuntime.reloadServer()
	local collision = assert(otherCopy.create(definition, serverOptions("game")))
	expectCode("RemoteOwnershipConflict", collision:Start())
	local defaultServer = assert(serverRuntime.server.create(definition, serverOptions(nil)))
	assert(defaultServer:Start())
	local duplicateServerRoot = serverRuntime.newInstance("Folder")
	duplicateServerRoot.Name = "RelayRemotes_game"
	duplicateServerRoot.Parent = serverRuntime.storage
	local _, destroyedProblem = server.events.Input:Connect(function() end)
	expectCode("Destroyed", nil, destroyedProblem)
	assert(defaultServer.events.Input:Connect(function() end),
		"a duplicate server root must destroy only its matching namespace")
	local clientRuntime = ClientRuntime.create()
	clientRuntime:transport(descriptor, false, "RelayRemotes")
	clientRuntime:transport(descriptor, false, "RelayRemotes_game")
	local default = assert(clientRuntime.module.create(definition, clientOptions(nil)))
	local game = assert(clientRuntime.module.create(definition, clientOptions("game")))
	assert(default:Start() and game:Start())
	local duplicate = clientRuntime:instance("Folder", "RelayRemotes_game", clientRuntime.storage)
	expectCode("Disconnected", game.events.Input:Send(1))
	assert(default.events.Input:Send(1), "a duplicate named root must not disconnect the default client")
	default:Destroy()
	game:Destroy()
	duplicate:Destroy()
	server:Destroy()
	defaultServer:Destroy()
	duplicateServerRoot:Destroy()
end

-- Timeout, mismatch, marker loss, contamination, and reparenting all release only their owner.
do
	local runtime = ClientRuntime.create()
	local waiting = assert(runtime.module.create(definition, clientOptions("waiting")))
	local result = {}
	local thread = coroutine.create(function() result[1], result[2] = waiting:Start() end)
	assert(coroutine.resume(thread) and coroutine.status(thread) == "suspended")
	local marker = assert(runtime.storage:FindFirstChild("RelayClientSession_RelayRemotes_waiting"))
	runtime:advance(3)
	assert(coroutine.status(thread) == "dead")
	expectCode("StartupTimeout", result[1], result[2])
	assert(marker.Parent == nil and marker.destroyed)
	runtime:transport(descriptor, false, "RelayRemotes_waiting")
	local replacement = assert(runtime.module.create(definition, clientOptions("waiting")))
	assert(replacement:Start(), "timeout must release marker and keyed guard")
	replacement:Destroy()

	local cancelRuntime = ClientRuntime.create()
	cancelRuntime.ignoreTimerCancel = true
	local cancelled = assert(cancelRuntime.module.create(definition, clientOptions("cancelled")))
	local cancelledResult = {}
	local cancelledThread = coroutine.create(function()
		cancelledResult[1], cancelledResult[2] = cancelled:Start()
	end)
	assert(coroutine.resume(cancelledThread) and coroutine.status(cancelledThread) == "suspended")
	local cancelledMarker = assert(cancelRuntime.storage:FindFirstChild("RelayClientSession_RelayRemotes_cancelled"))
	cancelled:Destroy()
	cancelRuntime:flush()
	assert(coroutine.status(cancelledThread) == "dead")
	expectCode("Destroyed", cancelledResult[1], cancelledResult[2])
	assert(cancelledMarker.Parent == nil and cancelledMarker.destroyed)
	cancelRuntime:transport(descriptor, false, "RelayRemotes_cancelled")
	local current = assert(cancelRuntime.module.create(definition, clientOptions("cancelled")))
	assert(current:Start(), "cancellation must release the marker and keyed guard")
	cancelRuntime:advance(3)
	local competing = assert(cancelRuntime.module.create(definition, clientOptions("cancelled")))
	expectCode("AlreadyStarted", competing:Start())
	assert(current.events.Input:Send(1), "a stale cancelled timeout must not clear the replacement guard")
	current:Destroy()

	local mismatchRuntime = ClientRuntime.create()
	local root, value = mismatchRuntime:transport(descriptor, false, "RelayRemotes_mismatch")
	value.Value = "wrong descriptor"
	local stale = assert(mismatchRuntime.module.create(definition, clientOptions("mismatch")))
	expectCode("DefinitionMismatch", stale:Start())
	assert(mismatchRuntime.storage:FindFirstChild("RelayClientSession_RelayRemotes_mismatch") == nil)
	value.Value = descriptor
	local fresh = assert(mismatchRuntime.module.create(definition, clientOptions("mismatch")))
	assert(fresh:Start(), "descriptor mismatch must release the local claim")
	fresh:Destroy()
	assert(root.Parent == mismatchRuntime.storage)
end

do
	local runtime = ClientRuntime.create()
	runtime:transport(descriptor, false, "RelayRemotes_game")
	runtime:transport(descriptor, false, "RelayRemotes_package")
	local game = assert(runtime.module.create(definition, clientOptions("game")))
	local package = assert(runtime.module.create(definition, clientOptions("package")))
	assert(game:Start() and package:Start())
	local gameMarker = assert(runtime.storage:FindFirstChild("RelayClientSession_RelayRemotes_game"))
	gameMarker.Name = "Tampered"
	expectCode("Disconnected", game.events.Input:Send(1))
	assert(gameMarker.Parent == nil and package.events.Input:Send(1),
		"marker tampering must disconnect and release only its client")

	local packageMarker = assert(runtime.storage:FindFirstChild("RelayClientSession_RelayRemotes_package"))
	local intruder = runtime:instance("Folder", "foreign-child", packageMarker)
	expectCode("Disconnected", package:Start())
	assert(packageMarker.Parent == runtime.storage and intruder.Parent == packageMarker,
		"cleanup must preserve foreign marker descendants")
	packageMarker:Destroy()
	local replacement = assert(runtime.module.create(definition, clientOptions("package")))
	assert(replacement:Start(), "removing a contaminated marker permits a fresh owner")

	runtime:transport(descriptor, false, "RelayRemotes_reparent")
	local reparented = assert(runtime.module.create(definition, clientOptions("reparent")))
	assert(reparented:Start())
	local marker = assert(runtime.storage:FindFirstChild("RelayClientSession_RelayRemotes_reparent"))
	local otherParent = runtime:instance("Folder", "other-parent")
	marker.Parent = otherParent
	assert(marker.destroyed and marker.Parent == nil and otherParent:FindFirstChild(marker.Name) == nil,
		"transport loss must destroy the empty owned marker after reparenting")
	assert(replacement.events.Input:Send(1), "marker loss must not affect another namespace")
	replacement:Destroy()
	package:Destroy()
end

print("transport namespace acceptance passed")
