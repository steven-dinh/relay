local Definition = require("../../src/Definition")
local OrderedFrame = require("../../src/internal/OrderedFrame")
local ClientRuntime = require("../../tests/support/ClientRuntime")
local ServerRuntime = require("../../tests/support/ServerRuntime")

local MAXIMUM_CLIENTS = 4
local MAXIMUM_MESSAGES = 1_024
local MAXIMUM_SECONDS = 60
local SERVER_TIME = 1_000_000_000

local function clear(values)
	table.clear(values)
end

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function new(definition, options)
	assert(options == nil or (type(options) == "table" and getmetatable(options) == nil),
		"options must be a plain table")
	for key in options or {} do
		assert(key == "server" or key == "client" or key == "clients", "options only accepts server, client, and clients")
	end
	local clientCount = if options and options.clients ~= nil then options.clients else 1
	assert(finite(clientCount) and clientCount % 1 == 0 and clientCount >= 1 and clientCount <= MAXIMUM_CLIENTS,
		"clients must be an integer from 1 to 4")
	local compiled = Definition.get(definition)
	assert(compiled ~= nil, "invalid Relay definition")
	assert(not compiled.hasReferences, "Instance references need one shared native Instance tree")

	local serverRuntime, serverReliable, serverUnreliable
	local server
	local clients = {}
	local clientsByPlayer = {}
	local messages = {}
	local state = "Created"
	local time = 0
	local nextMessageId = 0
	local failureReason

	local function clearRuntimeFires()
		if serverRuntime then clear(serverRuntime.fires) end
		for _, entry in clients do
			if entry.runtime then clear(entry.runtime.fires) end
		end
	end

	local function teardown()
		if state == "Destroyed" then return end
		state = "Destroyed"
		for _, entry in clients do
			entry.active = false
			entry.state = "Destroyed"
			if serverRuntime and entry.player and entry.player.Parent == serverRuntime.players then
				pcall(function() serverRuntime:removePlayer(entry.player) end)
			end
			if entry.client then pcall(function() entry.client:Destroy() end) end
			if entry.reliableRemote then pcall(function() entry.reliableRemote:Destroy() end) end
			if entry.unreliableRemote then pcall(function() entry.unreliableRemote:Destroy() end) end
			if entry.root then pcall(function() entry.root:Destroy() end) end
		end
		if server then pcall(function() server:Destroy() end) end
		clear(messages)
		clearRuntimeFires()
	end

	local function queuedCount()
		local count = #messages
		if serverRuntime then count += #serverRuntime.fires end
		for _, entry in clients do
			if entry.runtime then count += #entry.runtime.fires end
		end
		return count
	end

	local function queueOverflow()
		failureReason = "fixture pending message limit exceeded; fixture destroyed"
		teardown()
		error(failureReason, 0)
	end

	local function preflight(additional)
		if queuedCount() + additional > MAXIMUM_MESSAGES then queueOverflow() end
	end

	local function appendMessage(entry, direction, delivery, dueTime, values, remote)
		nextMessageId += 1
		local message = {
			id = nextMessageId,
			direction = direction,
			client = entry.index,
			delivery = delivery,
			dueTime = dueTime,
			values = values,
			player = entry.player,
			remote = remote,
		}
		table.insert(messages, message)
		return message
	end

	local function deliveryFor(remote, reliableRemote, unreliableRemote)
		if remote == unreliableRemote and unreliableRemote ~= nil then return "Unreliable" end
		if remote == reliableRemote then return "Reliable" end
		error("consumer fixture captured an unknown transport", 0)
	end

	local function recipientEntries()
		local result = {}
		for _, player in serverRuntime.players:GetPlayers() do
			local entry = clientsByPlayer[player]
			if not entry or not entry.active then
				error("consumer fixture found an unknown Player", 0)
			end
			table.insert(result, entry)
		end
		return result
	end

	local function queueClientCapture(entry, remote, capture)
		local delivery = deliveryFor(remote, entry.reliableRemote, entry.unreliableRemote)
		local destination = if delivery == "Reliable" then serverReliable else serverUnreliable
		assert(destination ~= nil, "consumer fixture is missing the matching server transport")
		appendMessage(entry, "ClientToServer", delivery, time, capture, destination)
	end

	local function queueServerCapture(entry, remote, values)
		local delivery = deliveryFor(remote, serverReliable, serverUnreliable)
		local destination = if delivery == "Reliable" then entry.reliableRemote else entry.unreliableRemote
		assert(destination ~= nil, "consumer fixture is missing the matching client transport")
		appendMessage(entry, "ServerToClient", delivery, time, values, destination)
	end

	local function deliverMessage(message)
		if message.direction == "ClientToServer" then
			message.remote.OnServerEvent:Fire(message.player, table.unpack(message.values, 1, message.values.n))
		else
			message.remote.OnClientEvent:fire(table.unpack(message.values, 1, message.values.n))
		end
	end

	local ok, fixture = pcall(function()
		serverRuntime = ServerRuntime.new()
		serverRuntime.serverTime = SERVER_TIME
		for index = 1, clientCount do
			local player = serverRuntime:addPlayer()
			local entry = { index = index, player = player, active = true, state = "Created" }
			clients[index] = entry
			clientsByPlayer[player] = entry
		end
		local serverOptions = if options and options.server ~= nil then options.server else {
			inboundRate = {
				perPlayer = { capacity = 4_096, refillPerSecond = 1 },
				aggregate = { capacity = 32_768, refillPerSecond = 1 },
			},
		}
		local clientOptions = if options and options.client ~= nil then options.client
			else { startupTimeoutSeconds = 3 }
		local serverNamespace = if type(serverOptions) == "table" then serverOptions.namespace else nil
		local clientNamespace = if type(clientOptions) == "table" then clientOptions.namespace else nil
		assert(serverNamespace == clientNamespace, "server and client namespaces must match")
		server = assert(serverRuntime.server.create(definition, serverOptions))

		local clientRootName = if type(clientNamespace) == "string"
			then `RelayRemotes_{clientNamespace}` else nil
		for _, entry in clients do
			local runtime = ClientRuntime.create()
			runtime.serverTime = SERVER_TIME
			local root, _, reliableRemote, unreliableRemote = runtime:transport(compiled.descriptor,
				compiled.hasUnreliable, clientRootName)
			entry.runtime = runtime
			entry.root = root
			entry.reliableRemote = reliableRemote
			entry.unreliableRemote = unreliableRemote
			entry.client = assert(runtime.module.create(definition, clientOptions))
		end

		local function disconnectClient(index)
			local entry = clients[index]
			if not entry or not entry.active then return false, "client is already disconnected" end
			entry.active = false
			entry.state = "Disconnected"
			for messageIndex = #messages, 1, -1 do
				if messages[messageIndex].client == index then table.remove(messages, messageIndex) end
			end
			clear(entry.runtime.fires)
			local ok, problem = pcall(function() serverRuntime:removePlayer(entry.player) end)
			pcall(function() entry.reliableRemote:Destroy() end)
			if entry.unreliableRemote then pcall(function() entry.unreliableRemote:Destroy() end) end
			pcall(function() entry.root:Destroy() end)
			pcall(function() entry.client:Destroy() end)
			if not ok then error(problem, 0) end
			local active = false
			for _, other in clients do active = active or other.active end
			if not active then
				state = "Disconnected"
				clear(messages)
				if server then pcall(function() server:Destroy() end) end
				clear(serverRuntime.fires)
			end
			return true, nil
		end

		local function detectServerClose()
			if state == "Started" and server:GetDiagnostics().state == "Destroyed" then
				for index, entry in clients do
					if entry.active then disconnectClient(index) end
				end
			end
			return state == "Disconnected"
		end

		for _, entry in clients do
			entry.runtime.onFire = function(remote)
				if not entry.active or (state ~= "Starting" and state ~= "Started") then
					error("client transport is disconnected", 0)
				end
				preflight(1)
			end
			entry.runtime.afterFire = function(remote)
				local capture = entry.runtime.fires[#entry.runtime.fires]
				assert(capture and capture.remote == remote, "consumer fixture lost a client transport capture")
				queueClientCapture(entry, remote, capture)
				table.remove(entry.runtime.fires, #entry.runtime.fires)
			end
		end

		serverRuntime.beforeFire = function(player)
			local entry = clientsByPlayer[player]
			if not entry or not entry.active or player.Parent ~= serverRuntime.players then
				error("target Player is unknown or disconnected", 0)
			end
			preflight(1)
		end
		serverRuntime.afterFire = function(player)
			local capture = serverRuntime.fires[#serverRuntime.fires]
			local entry = clientsByPlayer[player]
			assert(capture and capture.kind == "target" and entry, "consumer fixture lost a target capture")
			queueServerCapture(entry, capture.remote, capture.values)
			table.remove(serverRuntime.fires, #serverRuntime.fires)
		end
		local broadcastRecipients
		serverRuntime.beforeBroadcast = function()
			broadcastRecipients = recipientEntries()
			preflight(#broadcastRecipients)
		end
		serverRuntime.afterBroadcast = function()
			local capture = serverRuntime.fires[#serverRuntime.fires]
			assert(capture and capture.kind == "broadcast" and broadcastRecipients,
				"consumer fixture lost a broadcast capture")
			for _, entry in broadcastRecipients do
				queueServerCapture(entry, capture.remote, capture.values)
			end
			table.remove(serverRuntime.fires, #serverRuntime.fires)
			broadcastRecipients = nil
		end

		local publicClients = {}
		for _, entry in clients do
			table.insert(publicClients, table.freeze({ client = entry.client, player = entry.player }))
		end
		local test = {
			server = server,
			client = clients[1].client,
			player = clients[1].player,
			clients = table.freeze(publicClients),
		}
		local function startupMessage(entry, direction, read)
			for index, message in messages do
				if message.client == entry.index and message.direction == direction
					and message.delivery == "Reliable" then
					local values = message.values
					if values.n == 2 and values[1] == 0 and read(values[2]) ~= nil then return index end
					return nil -- Keep reliable FIFO when other traffic precedes the exchange.
				end
			end
			return nil
		end

		local function startOrderedClient(entry)
			local started, problem
			local thread = coroutine.create(function() started, problem = entry.client:Start() end)
			local ok, issue = coroutine.resume(thread)
			if not ok then error(issue, 0) end
			if coroutine.status(thread) == "suspended" then
				local index = startupMessage(entry, "ClientToServer", OrderedFrame.readHello)
				if index then deliverMessage(table.remove(messages, index)) end
				index = startupMessage(entry, "ServerToClient", OrderedFrame.readInitialization)
				if index then deliverMessage(table.remove(messages, index)) end
				if failureReason then error(failureReason, 0) end
				entry.runtime:flush()
				if coroutine.status(thread) == "suspended" then
					local advanced, reason = test:Advance(clientOptions.startupTimeoutSeconds)
					if not advanced then error(reason, 0) end
				end
			end
			assert(coroutine.status(thread) == "dead", "ordered startup did not settle")
			return started, problem
		end

		function test:Start()
			if state ~= "Created" then
				return false, Definition.error(if state == "Started" then "AlreadyStarted" else state)
			end
			state = "Starting"
			local started, problem = server:Start()
			if not started then teardown(); return false, problem end
			serverReliable = serverRuntime:remote()
			serverUnreliable = serverRuntime:unreliableRemote()
			for _, entry in clients do
				if entry.active then
					if compiled.hasOrderedClientToServer then
						local ok, result, issue = pcall(startOrderedClient, entry)
						if not ok then teardown(); error(result, 0) end
						started, problem = result, issue
					else
						started, problem = entry.client:Start()
					end
					if not started then teardown(); return false, problem end
					entry.state = "Started"
				end
			end
			state = "Started"
			return true, nil
		end

		function test:Pump()
			if failureReason then error(failureReason, 0) end
			if state == "Disconnected" then return 0 end
			assert(state == "Started", "start the fixture before pumping")
			local delivered = 0
			local function deliveryIndex()
				for index, message in messages do
					if message.dueTime <= time then
						return index
					end
				end
				return nil
			end
			local ok, problem = pcall(function()
				repeat
					if detectServerClose() then break end
					local index = deliveryIndex()
					if not index then break end
					if delivered >= MAXIMUM_MESSAGES then
						error("pump exceeded 1024 actual deliveries; fixture destroyed", 0)
					end
					local message = table.remove(messages, index)
					deliverMessage(message)
					delivered += 1
					if failureReason then error(failureReason, 0) end
				until false
			end)
			if not ok then teardown(); error(problem, 0) end
			return delivered
		end

		function test:Advance(seconds)
			if state == "Destroyed" or state == "Disconnected" then
				return false, "fixture is disconnected"
			end
			if not finite(seconds) or seconds < 0 then return false, "seconds must be finite and nonnegative" end
			if time + seconds > MAXIMUM_SECONDS then return false, "fixture time cannot exceed 60 seconds" end
			time += seconds
			local ok, problem = pcall(function()
				serverRuntime:advance(seconds)
				for _, entry in clients do
					entry.runtime.serverTime = serverRuntime.serverTime
					entry.runtime:advance(seconds)
				end
			end)
			if not ok then teardown(); error(problem, 0) end
			return true, nil
		end

		function test:Disconnect(index)
			index = if index == nil then 1 else index
			if not finite(index) or index % 1 ~= 0 or index < 1 or index > #clients then
				return false, "client index must be an integer in this fixture"
			end
			if state == "Destroyed" then return false, "fixture is destroyed" end
			return disconnectClient(index)
		end

		local function findMessage(id)
			if not finite(id) or id % 1 ~= 0 or id < 1 then return nil end
			for index, message in messages do
				if message.id == id then return index, message end
			end
			return nil
		end

		local function unreliableMessage(id)
			local index, message = findMessage(id)
			if not index then return nil, "message ID is invalid or stale" end
			if message.delivery ~= "Unreliable" then return nil, "control applies only to unreliable messages" end
			return index, message
		end

		function test:GetPending()
			local snapshot = {}
			for _, message in messages do
				table.insert(snapshot, table.freeze({
					id = message.id,
					direction = message.direction,
					client = message.client,
					delivery = message.delivery,
					dueTime = message.dueTime,
				}))
			end
			return table.freeze(snapshot)
		end

		function test:Drop(id)
			local index, problem = unreliableMessage(id)
			if not index then return false, problem end
			table.remove(messages, index)
			return true, nil
		end

		function test:Duplicate(id)
			local index, message = unreliableMessage(id)
			if not index then return false, message end
			if queuedCount() >= MAXIMUM_MESSAGES then return false, "fixture pending message limit reached" end
			nextMessageId += 1
			local duplicate = table.clone(message)
			duplicate.id = nextMessageId
			table.insert(messages, duplicate)
			return duplicate.id, nil
		end

		function test:Delay(id, seconds)
			local index, message = unreliableMessage(id)
			if not index then return false, message end
			if not finite(seconds) or seconds < 0 then return false, "seconds must be finite and nonnegative" end
			if time + seconds > MAXIMUM_SECONDS then
				return false, "message due time cannot exceed 60 seconds"
			end
			message.dueTime = time + seconds
			return true, nil
		end

		local function deliverOne(index)
			local message = table.remove(messages, index)
			local ok, problem = pcall(function()
				deliverMessage(message)
			end)
			if not ok then teardown(); return false, tostring(problem) end
			if failureReason then return false, failureReason end
			return true, nil
		end

		function test:Deliver(id)
			if detectServerClose() then return false, "fixture is disconnected" end
			local index, problem = unreliableMessage(id)
			if not index then return false, problem end
			return deliverOne(index)
		end

		function test:Destroy()
			teardown()
		end

		local function runtimeStatus(entry)
			local queuedMessages = 0
			for _, message in messages do
				if message.client == entry.index then queuedMessages += 1 end
			end
			local activeTimers = 0
			for _ in entry.runtime.timers do activeTimers += 1 end
			return table.freeze({
				state = entry.state,
				clientState = entry.client:GetDiagnostics().state,
				activeTimers = activeTimers,
				connections = entry.runtime.connections,
				queuedMessages = queuedMessages,
			})
		end

		function test:GetStatus()
			local clientStatuses = {}
			local activeTimers = serverRuntime:activeTimers()
			local connections = serverRuntime.connections
			for _, entry in clients do
				local status = runtimeStatus(entry)
				table.insert(clientStatuses, status)
				activeTimers += status.activeTimers
				connections += status.connections
			end
			return table.freeze({
				state = state,
				time = time,
				queuedMessages = queuedCount(),
				activeTimers = activeTimers,
				connections = connections,
				serverState = server:GetDiagnostics().state,
				clientState = clients[1].client:GetDiagnostics().state,
				clients = table.freeze(clientStatuses),
			})
		end

		return table.freeze(test)
	end)
	if not ok then teardown(); error(fixture, 0) end
	return fixture
end

local function withFixture(definition, callback, options)
	assert(type(callback) == "function", "callback must be a function")
	local fixture = new(definition, options)
	local result = table.pack(pcall(callback, fixture))
	fixture:Destroy()
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end

return table.freeze({ new = new, withFixture = withFixture })
