local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../src/Definition")
local Schema = require("../src/Schema")
local ServerRuntime = require("./support/ServerRuntime")
local ClientRuntime = require("./support/ClientRuntime")

local function groupsModule(runtime)
	return luau.load(fs.readFile("examples/interest-management/Groups.luau"), {
		debugName = "InterestGroups", injectGlobals = true,
		environment = { typeof = function(value)
			if runtime.instances[value] then
				value.IsA = function(self, className) return self.ClassName == className end
				return "Instance"
			end
			return typeof(value)
		end },
	})()
end

local relayMarker = {}
local definition = luau.load(fs.readFile("examples/interest-management/Definition.luau"), {
	debugName = "InterestDefinition", injectGlobals = true,
	environment = {
		game = { GetService = function() return {
			Relay = relayMarker, WaitForChild = function() return relayMarker end,
		} end },
		require = function(module)
			assert(module == relayMarker)
			return { define = Definition.define, schema = Schema }
		end,
	},
})()

do
	local runtime = ServerRuntime.new()
	local first, second = runtime:addPlayer(), runtime:addPlayer()
	local groups = groupsModule(runtime).new(runtime.players)
	local members = { first, first, second }
	assert(groups:Set("room:a", members))
	members[1] = second
	local snapshot = assert(groups:Members("room:a"))
	assert(#snapshot == 2 and snapshot[1] == first and snapshot[2] == second)
	table.clear(snapshot)
	assert(#assert(groups:Members("room:a")) == 2, "members are copied in both directions")
	assert(groups:Set("room:a", table.create(64, first)), "raw entry ceiling accepts duplicates then deduplicates")
	assert(#assert(groups:Members("room:a")) == 1)
	assert(groups:Set("room:a", { first, second }))
	for _, invalid in {
		{ [1] = first, [3] = second }, { extra = first }, { false },
		table.create(65, first), setmetatable({ first }, {}),
		{ runtime.newInstance("Folder") }, { runtime.newInstance("Player") },
	} do
		assert(not groups:Set("room:a", invalid))
		assert(#assert(groups:Members("room:a")) == 2, "invalid replacement preserves membership")
	end
	assert(not groups:Set("", {}) and not groups:Set(string.rep("a", 65), {}))
	local unrostered = runtime:addPlayer()
	local getPlayers = runtime.players.GetPlayers
	runtime.players.GetPlayers = function()
		return { first, second }
	end
	assert(not groups:Set("room:a", { unrostered }), "Parent alone does not establish current roster membership")
	runtime.players.GetPlayers = getPlayers
	assert(groups:Set("empty", {}) and #assert(groups:Members("empty")) == 0)
	for index = 1, 14 do assert(groups:Set(`group:{index}`, {})) end
	assert(not groups:Set("overflow", {}), "group count is bounded even for empty groups")
	assert(groups:Delete("empty"))
	assert(groups:Set("replacement", {}))
	assert(groups:Delete("replacement") and groups:Delete("replacement"))
	assert(groups:Members("missing") == nil)
	runtime:removePlayer(first)
	assert(#assert(groups:Members("room:a")) == 1 and assert(groups:Members("room:a"))[1] == second)
	assert(not groups:Set("room:a", { first }), "departed players cannot rejoin by stale reference")
	second.Parent = nil
	assert(#assert(groups:Members("room:a")) == 0, "snapshots filter stale members without a signal")
	groups:Destroy(); groups:Destroy()
	assert(runtime.connections == 0)
	assert(not groups:Set("room:a", {}) and groups:Members("room:a") == nil and not groups:Delete("room:a"))
end

-- Use the real public server handles: private sends never target the outsider;
-- captured State lanes change only when their owner destroys and rebuilds them.
do
	local runtime = ServerRuntime.new()
	local first, second, outsider = runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
	local groups = groupsModule(runtime).new(runtime.players)
	local server = assert(runtime.server.create(definition, {
		inboundRate = { perPlayer = { capacity = 16, refillPerSecond = 8 },
			aggregate = { capacity = 128, refillPerSecond = 64 } },
	}))
	assert(server:Start())
	assert(groups:Set("team:red", { first, first, second }))
	local ok, problem, count = server.events.Notice:SendTo(assert(groups:Members("team:red")), "private red")
	assert(ok and problem == nil and count == 2 and #runtime.fires == 2)
	assert(runtime.fires[1].player == first and runtime.fires[2].player == second)
	assert(groups:Set("empty", {}))
	assert(server.events.Notice:SendTo(assert(groups:Members("empty")), "empty"))
	assert(#runtime.fires == 2)
	ok, problem, count = server.events.Notice:SendExcept(assert(groups:Members("team:red")), "public")
	assert(ok and count == 1 and runtime.fires[3].player == outsider)

	local audience = assert(groups:Members("team:red"))
	local lane = assert(server:CreateState(audience, 0.02))
	assert(lane.events.Score:Put(1, "Normal", 1, 10))
	assert(groups:Set("team:red", { second }))
	table.clear(audience)
	assert(lane:Flush())
	assert(#runtime.fires == 5 and runtime.fires[4].player == first and runtime.fires[5].player == second,
		"group edits and caller-array edits do not mutate a captured lane")
	assert(lane.events.Score:Put(1, "Normal", 2, 20))
	lane:Destroy()
	local before = #runtime.fires
	runtime:advance(0.02)
	assert(#runtime.fires == before and runtime:activeTimers() == 0, "destroy discards old pending work")
	lane = assert(server:CreateState(assert(groups:Members("team:red")), 0.02))
	assert(lane:Flush() and #runtime.fires == before, "membership does not automatically seed or replay")
	assert(lane.events.Score:Put(1, "Normal", 3, 20))
	runtime:advance(0.02)
	assert(#runtime.fires == before + 1 and runtime.fires[#runtime.fires].player == second,
		"explicit current-state seed targets only the rebuilt audience")
	assert(lane.events.Score:Put(1, "Normal", 4, 30))
	runtime:removePlayer(second)
	runtime:advance(0.02)
	assert(#runtime.fires == before + 1 and #assert(groups:Members("team:red")) == 0)
	lane:Destroy(); groups:Destroy(); server:Destroy()
	assert(runtime.connections == 0 and runtime:activeTimers() == 0)
end

local function signal()
	local listeners = {}
	local value = {}
	function value:Connect(callback)
		local connection = { Connected = true }
		function connection:Disconnect()
			self.Connected = false
			listeners[self] = nil
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

local definitionMarker, groupsMarker = {}, {}
local function wire(storage, relay, groups)
	storage.Relay, storage.Definition, storage.Groups = relayMarker, definitionMarker, groupsMarker
	storage.WaitForChild = function(self, name) return self[name] end
	return function(module)
		if module == relayMarker then return relay end
		if module == definitionMarker then return definition end
		assert(module == groupsMarker and groups ~= nil)
		return groups
	end
end

local function launchServer(runtime)
	local heartbeat, destroying = signal(), signal()
	local getService = runtime.game.GetService
	local warnings = {}
	luau.load(fs.readFile("examples/interest-management/Server.server.luau"), {
		debugName = "InterestServer", injectGlobals = true,
		environment = {
			game = { GetService = function(_, name)
				if name == "RunService" then return { Heartbeat = heartbeat } end
				return getService(runtime.game, name)
			end },
			script = { Destroying = destroying },
			require = wire(runtime.storage, { createServer = runtime.server.create }, groupsModule(runtime)),
			print = function() end,
			warn = function(...) table.insert(warnings, table.pack(...)) end,
		},
	})()
	return heartbeat, destroying, warnings
end

local function launchClient()
	local runtime = ClientRuntime.create()
	local _, _, remote = runtime:transport(assert(Definition.get(definition)).descriptor, false)
	local destroying, output = signal(), {}
	luau.load(fs.readFile("examples/interest-management/Client.client.luau"), {
		debugName = "InterestClient", injectGlobals = true,
		environment = {
			game = runtime.game, script = { Destroying = destroying },
			require = wire(runtime.storage, { createClient = runtime.module.create }),
			print = function(...) table.insert(output, table.pack(...)) end,
		},
	})()
	return { runtime = runtime, remote = remote, destroying = destroying, output = output }
end

-- Execute the actual example scripts and decode their handoffs with public clients.
do
	local runtime = ServerRuntime.new()
	local players, clients = {}, {}
	for index = 1, 4 do
		players[index] = runtime:addPlayer()
		clients[players[index]] = launchClient()
	end
	local heartbeat, destroying, warnings = launchServer(runtime)
	runtime:advance(0.02)
	assert(#runtime.fires == 1 and runtime.fires[1].player == players[4], "new spectator gets explicit current-state seed")
	heartbeat:Fire(1)
	runtime:advance(0.02)
	for _, fire in runtime.fires do
		local client = assert(clients[fire.player], "no out-of-group or broadcast handoff")
		client.remote.OnClientEvent:fire(table.unpack(fire.values, 1, fire.values.n))
	end
	for index, player in players do
		local notices, scores = {}, 0
		for _, entry in clients[player].output do
			if entry[1] == "Notice received" then table.insert(notices, entry[2]) end
			if entry[1] == "Score snapshot" then scores += 1 end
		end
		if index == 4 then
			assert(#notices == 0 and scores == 2, "spectator sees current scores, no private room/team notices")
		else
			assert(scores == 0 and #notices == (if index == 2 then 2 else 3))
			for _, message in notices do
				if string.sub(message, 1, 5) == "Arena" then assert(index == 1) end
				if string.sub(message, 1, 5) == "Lobby" then assert(index == 2 or index == 3) end
				if string.sub(message, 1, 3) == "Red" then assert(index == 1 or index == 3) end
			end
		end
	end
	heartbeat:Fire(1) -- Queue another score for the old spectator audience.
	local before = #runtime.fires
	runtime:removePlayer(players[1]) -- Fourth player now becomes active under demo policy.
	runtime:advance(0.02)
	assert(#runtime.fires == before and runtime:activeTimers() == 0,
		"departure rebuild discards old pending spectator state before role revocation")
	runtime:addPlayer() -- A new fourth roster entry seeds a fresh spectator lane.
	assert(runtime:activeTimers() == 1)
	destroying:Fire(); destroying:Fire()
	runtime:advance(1)
	assert(#runtime.fires == before and heartbeat:Count() == 0 and runtime.connections == 0
		and runtime:activeTimers() == 0 and #warnings == 0)
	for _, client in clients do
		client.destroying:Fire()
		assert(client.runtime.connections == 0)
	end
end

do
	local runtime = ServerRuntime.new()
	for _ = 1, 4 do runtime:addPlayer() end
	local heartbeat, _, warnings = launchServer(runtime)
	runtime.throwFire = true
	heartbeat:Fire(1)
	runtime:advance(1)
	assert(#warnings == 1 and heartbeat:Count() == 0 and runtime.connections == 0
		and runtime:activeTimers() == 0 and #runtime.fires == 0,
		"failed handoff stops production once and discards pending state")
end

do
	local runtime = ServerRuntime.new()
	for _ = 1, 65 do runtime:addPlayer() end
	local heartbeat, _, warnings = launchServer(runtime)
	assert(#warnings == 1 and heartbeat:Count() == 0 and runtime.connections == 0
		and runtime:activeTimers() == 0, "unsupported roster stops cleanly before producing")
end

print("PASS interest management membership, public audience isolation, captured lanes, demo and cleanup")
