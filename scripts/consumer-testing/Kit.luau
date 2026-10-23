local Definition = require("../../src/Definition")
local ClientRuntime = require("../../tests/support/ClientRuntime")
local ServerRuntime = require("../../tests/support/ServerRuntime")

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
		assert(key == "server" or key == "client", "options only accepts server and client")
	end
	local compiled = Definition.get(definition)
	assert(compiled ~= nil, "invalid Relay definition")
	assert(not compiled.hasOrderedClientToServer, "ordered client-to-server events need a native initialization exchange")
	assert(not compiled.hasUnreliable, "unreliable events need a native transport")
	assert(not compiled.hasReferences, "Instance references need one shared native Instance tree")

	local serverRuntime, clientRuntime, clientRoot, clientRemote
	local server, client, player
	local state = "Created"
	local time = 0
	local function teardown()
		if state == "Destroyed" then return end
		state = "Destroyed"
		if serverRuntime and player and player.Parent == serverRuntime.players then
			pcall(function() serverRuntime:removePlayer(player) end)
		end
		if client then pcall(function() client:Destroy() end) end
		if server then pcall(function() server:Destroy() end) end
		if clientRemote then pcall(function() clientRemote:Destroy() end) end
		if clientRoot then pcall(function() clientRoot:Destroy() end) end
		if clientRuntime then clear(clientRuntime.fires) end
		if serverRuntime then clear(serverRuntime.fires) end
	end

	local ok, fixture = pcall(function()
		serverRuntime = ServerRuntime.new()
		serverRuntime.serverTime = SERVER_TIME
		player = serverRuntime:addPlayer()
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

		clientRuntime = ClientRuntime.create()
		clientRuntime.serverTime = SERVER_TIME
		local clientRootName = if type(clientNamespace) == "string"
			then `RelayRemotes_{clientNamespace}` else nil
		local transportRoot, _, transportRemote = clientRuntime:transport(compiled.descriptor, false, clientRootName)
		clientRoot, clientRemote = transportRoot, transportRemote
		client = assert(clientRuntime.module.create(definition, clientOptions))

		local test = {
			server = server,
			client = client,
			player = player,
		}

		function test:Start()
			if state ~= "Created" then
				return false, Definition.error(if state == "Started" then "AlreadyStarted" else state)
			end
			local started, problem = server:Start()
			if not started then teardown(); return false, problem end
			started, problem = client:Start()
			if not started then teardown(); return false, problem end
			state = "Started"
			return true, nil
		end

		function test:Pump()
			if state == "Disconnected" then return 0 end
			assert(state == "Started", "start the fixture before pumping")
			local delivered = 0
			local function transportClosed()
				if state == "Started" and server:GetDiagnostics().state == "Destroyed" then
					self:Disconnect()
				end
				return state ~= "Started"
			end
			local function handoff(count)
				if delivered + count > MAXIMUM_MESSAGES then
					error("pump exceeded 1024 reliable handoffs; fixture destroyed", 0)
				end
				delivered += count
			end
			local function drainClient()
				local fires = table.clone(clientRuntime.fires)
				clear(clientRuntime.fires)
				local remote = serverRuntime:remote()
				local count = 0
				for _, fire in fires do
					if transportClosed() then break end
					handoff(1)
					assert(fire.remote == clientRemote, "unexpected client reliable remote")
					remote.OnServerEvent:Fire(player, table.unpack(fire, 1, fire.n))
					count += 1
				end
				return count
			end
			local function drainServer()
				local fires = table.clone(serverRuntime.fires)
				clear(serverRuntime.fires)
				local count = 0
				for _, fire in fires do
					if transportClosed() then break end
					handoff(1)
					if fire.kind == "broadcast" or fire.player == player then
						clientRemote.OnClientEvent:fire(table.unpack(fire.values, 1, fire.values.n))
					end
					count += 1
				end
				return count
			end

			local ok, problem = pcall(function()
				repeat
					if transportClosed() then break end
					local clientCount = drainClient()
					if transportClosed() then break end
					local serverCount = drainServer()
				until clientCount + serverCount == 0
			end)
			if not ok then teardown(); error(problem, 0) end
			return delivered
		end

		function test:Advance(seconds)
			if state == "Destroyed" then return false, "fixture is destroyed" end
			if not finite(seconds) or seconds < 0 then return false, "seconds must be finite and nonnegative" end
			if time + seconds > MAXIMUM_SECONDS then return false, "fixture time cannot exceed 60 seconds" end
			local ok, problem = pcall(function()
				clientRuntime.serverTime = serverRuntime.serverTime + seconds
				serverRuntime:advance(seconds)
				clientRuntime:advance(seconds)
			end)
			if not ok then teardown(); error(problem, 0) end
			time += seconds
			return true, nil
		end

		function test:Disconnect()
			if state == "Disconnected" or state == "Destroyed" then return end
			state = "Disconnected"
			local ok, problem = pcall(function() serverRuntime:removePlayer(player) end)
			pcall(function() clientRemote:Destroy() end)
			pcall(function() clientRoot:Destroy() end)
			clear(clientRuntime.fires)
			clear(serverRuntime.fires)
			if not ok then error(problem, 0) end
		end

		function test:Destroy()
			teardown()
		end

		function test:GetStatus()
			local clientTimers = 0
			for _ in clientRuntime.timers do clientTimers += 1 end
			return table.freeze({
				state = state,
				time = time,
				queuedMessages = #clientRuntime.fires + #serverRuntime.fires,
				activeTimers = clientTimers + serverRuntime:activeTimers(),
				connections = clientRuntime.connections + serverRuntime.connections,
				serverState = server:GetDiagnostics().state,
				clientState = client:GetDiagnostics().state,
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
