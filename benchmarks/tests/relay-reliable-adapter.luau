--!strict

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Host = require("../host/HostRuntime")

local source = fs.readFile("benchmarks/adapters/relay-reliable/init.luau")
luau.compile(source)
local function expectError(callback: any, code: string)
	local ok, message = pcall(callback)
	assert(not ok and message == "RELAY_RELIABLE_E_" .. code, tostring(message))
end

local function harness()
	local calls: any = { definitions = {}, sessions = {}, sends = {}, deliveries = {} }
	local roster = { {} }
	local storage: any = { Relay = {} }
	local remoteRoot: any = nil
	function storage:FindFirstChild(name)
		assert(name == "RelayRemotes")
		return remoteRoot
	end
	local relay: any = { VERSION = "0.1.0" }
	function relay.define(definition)
		table.insert(calls.definitions, definition)
		return definition
	end
	local function create(definition, options, isServer)
		local session: any = { events = {}, starts = 0, destroys = 0 }
		local callbacks = {}
		for name in definition.events do
			session.events[name] = {
				Connect = function(_, callback)
					callbacks[name] = callback
					return {}
				end,
				Send = function(_, ...)
					table.insert(calls.sends, { kind = "Send", values = table.pack(...) })
					return not calls.rejectSend
				end,
				Broadcast = function(_, ...)
					table.insert(calls.sends, { kind = "Broadcast", values = table.pack(...) })
					return not calls.rejectSend
				end,
			}
		end
		function session:Start()
			self.starts += 1
			if not isServer then assert(remoteRoot ~= nil and remoteRoot.Definition and remoteRoot.Reliable, "Start would yield") end
			return not calls.rejectStart
		end
		function session:Destroy() self.destroys += 1 end
		session.callbacks, session.options, session.isServer = callbacks, options, isServer
		table.insert(calls.sessions, session)
		return session
	end
	function relay.createServer(definition, options) return create(definition, options, true) end
	function relay.createClient(definition, options) return create(definition, options, false) end
	local factory = luau.load(source, { environment = {
		game = { GetService = function(_, name)
			if name == "ReplicatedStorage" then return storage end
			assert(name == "Players")
			return { GetPlayers = function() return roster end }
		end },
		require = function(module) assert(module == storage.Relay) return relay end,
		typeof = function(value) return if value == calls.resourceRoot then "Instance" else typeof(value) end,
	} })()
	calls.resourceRoot = {}
	function calls.context(payloadId, direction, probe)
		return {
			resourceRoot = calls.resourceRoot,
			selection = { payloadId = payloadId, direction = direction, kind = if probe then "SeparateProbe" else "Workload" },
			recipients = roster,
			envelopes = { positional = function(...) return table.pack(...) end },
			sink = function(values, metadata) table.insert(calls.deliveries, { values = values, metadata = metadata }) end,
		}
	end
	function calls.replicate(definition, reliable)
		remoteRoot = { Definition = definition, Reliable = reliable }
		function remoteRoot:FindFirstChild(name) return self[name] end
	end
	function calls.changeRoster() roster = { {}, {} } end
	return factory, calls
end

for _, payloadId in { "tiny", "state" } do
	for _, direction in { "ClientToServer", "ServerToClient", "Probe" } do
		local factory, calls = harness()
		local server = factory.constructServer(calls.context(payloadId, direction, direction == "Probe"))
		local client = factory.constructClient(calls.context(payloadId, direction, direction == "Probe"))
		assert(table.isfrozen(factory) and table.isfrozen(server) and table.isfrozen(client))
		assert((server.broadcast ~= nil) == (direction ~= "ClientToServer"))
		assert((client.submit ~= nil) == (direction ~= "ServerToClient"))
		expectError(server.ready, "READY")
		server.setup()
		client.setup()
		assert(calls.sessions[1].starts == 1 and calls.sessions[2].starts == 0, "client setup must not start/yield")
		assert(not client.ready(), "missing root must remain pending")
		calls.replicate({}, nil)
		assert(not client.ready() and calls.sessions[2].starts == 0, "partial replication must not call Start")
		calls.replicate({}, {})
		assert(client.ready() and client.ready() and calls.sessions[2].starts == 1)
		assert(server.ready())
		local rates = calls.sessions[1].options.inboundRate
		assert(table.isfrozen(rates) and table.isfrozen(rates.perPlayer) and table.isfrozen(rates.aggregate))
		assert(rates.perPlayer.capacity == 4096 and rates.perPlayer.refillPerSecond == 2048)
		assert(rates.aggregate.capacity == 32768 and rates.aggregate.refillPerSecond == 16384)
		local payload = { sequence = 123, enabled = true, entityId = 45, position = roblox.Vector3.new(1, 2, 3), yaw = 90, health = 99 }
		if client.submit then client.submit(payload, "FlushBeforeReturn") end
		if server.broadcast then server.broadcast(payload, "ContinueFrame") end
		for _, send in calls.sends do
			assert(send.values.n == (if payloadId == "tiny" then 2 else 5) and send.values[1] == 123)
			assert(send.values[2] == (if payloadId == "tiny" then true else 45))
			if payloadId == "state" then assert(send.values[3] == payload.position and send.values[4] == 90 and send.values[5] == 99) end
		end
		if calls.sessions[1].callbacks.Submit then calls.sessions[1].callbacks.Submit(calls.context().recipients[1], 123, true) end
		if calls.sessions[2].callbacks.Broadcast then calls.sessions[2].callbacks.Broadcast(123, true) end
		assert(#calls.deliveries == #calls.sends)
		for _, definition in calls.definitions do
			for _, event in definition.events do
				assert(#event.fields == (if payloadId == "tiny" then 2 else 5))
				if payloadId == "state" then
					assert(event.fields[3].type == "Vector3F32" and event.fields[3].minimum == -1024 and event.fields[3].maximum == 1024)
				end
			end
		end
		calls.rejectSend = true
		if client.submit then expectError(function() client.submit(payload) end, "SUBMIT") end
		if server.broadcast then expectError(function() server.broadcast(payload) end, "BROADCAST") end
		client.teardown(); client.teardown(); server.teardown(); server.teardown()
		assert(calls.sessions[1].destroys == 1 and calls.sessions[2].destroys == 1)
		local delivered = #calls.deliveries
		if calls.sessions[1].callbacks.Submit then calls.sessions[1].callbacks.Submit({}, 1, false) end
		if calls.sessions[2].callbacks.Broadcast then calls.sessions[2].callbacks.Broadcast(1, false) end
		assert(#calls.deliveries == delivered, "late callbacks delivered after teardown")
		expectError(client.ready, "READY")
	end
end

do
	local factory, calls = harness()
	local context = calls.context("tiny", "ClientToServer")
	local first = factory.constructClient(context)
	first.setup()
	calls.replicate({}, {})
	assert(first.ready())
	first.teardown()
	local second = factory.constructClient(context)
	second.setup()
	assert(not second.ready() and calls.sessions[2].starts == 0, "new generation bound the prior replicated transport")
	calls.replicate({}, nil)
	assert(not second.ready() and calls.sessions[2].starts == 0, "partial replacement must remain pending")
	calls.replicate({}, {})
	assert(second.ready() and calls.sessions[2].starts == 1, "replacement transport did not activate")
	second.teardown()
end

do
	local factory, calls = harness()
	local server = factory.constructServer(calls.context("state", "ServerToClient"))
	server.setup()
	calls.changeRoster()
	expectError(server.ready, "READY")
	server.teardown()
end

-- The allowlist binds both sides to one host-injected source pin, with no loose ID admission.
local place = roblox.Instance.new("DataModel")
local storage = roblox.Instance.new("ReplicatedStorage"); storage.Parent = place
local relay = roblox.Instance.new("ModuleScript"); relay.Name = "Relay"; relay.Source = 'return { VERSION = "0.1.0" }\r\n'; relay.Parent = storage
local bytes = roblox.serializePlace(place, true)
local binding = Host.collectRelayAdapter(string.rep("a", 40), bytes, roblox, serde.hash)
local changed = roblox.Instance.new("ModuleScript"); changed.Name = "Definition"; changed.Source = "return {}"; changed.Parent = relay
assert(Host.collectRelayAdapter(string.rep("a", 40), roblox.serializePlace(place, true), roblox, serde.hash).artifact.digest ~= binding.artifact.digest)
local expectedBytes = `5:Relay{#relay.Source}:{relay.Source}`
assert(binding.artifact.digest == "sha256:" .. serde.hash("sha256", expectedBytes), "source checksum must preserve exact bytes")
local serverStorage = roblox.Instance.new("ServerStorage"); serverStorage.Parent = place
local serverRoot = roblox.Instance.new("Folder"); serverRoot.Name = "RelayBenchmarkServer"; serverRoot.Parent = serverStorage
local benchmark = roblox.Instance.new("Folder"); benchmark.Name = "RelayBenchmark"; benchmark.Parent = storage
local adapterFolder = roblox.Instance.new("Folder"); adapterFolder.Name = "adapters"; adapterFolder.Parent = benchmark
local facts = {
	benchmarkSource = { revision = string.rep("a", 40), dirty = true, placeFingerprint = "sha256:" .. string.rep("b", 64) },
	contractFingerprint = "sha256:" .. string.rep("c", 64), host = { osFamily = "Windows", architecture = "x86_64" },
}
local options = { mode = "Benchmark", recipientCount = 1, selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" } }
local launchId = "00000000-0000-4000-8000-000000000000"
local manifest = Host.nativeManifest(launchId, "0.650.0.6500000", options.selection, facts, binding)
assert(manifest.adapter.identity.library.provenance.checksum == binding.artifact.digest and manifest.benchmarkSource.dirty)
local carrier = Host.carrierData(launchId, string.rep("ab", 32), 49152, options, facts, binding)
local launched = Host.launchPlaceBytes(roblox.serializePlace(place, true), carrier, roblox)
local launchedPlace = roblox.deserializePlace(launched)
local injected = launchedPlace:FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark"):FindFirstChild("adapters"):FindFirstChild("RelayAdapterPin")
assert(injected ~= nil and injected.ClassName == "ModuleScript")
assert(string.find(injected.Source, carrier.capability, 1, true) == nil, "private launch capability leaked into replicated pin")
local injectedBinding = luau.load(injected.Source)()
assert(injectedBinding.identity.library.provenance.checksum == binding.identity.library.provenance.checksum)
assert(injectedBinding.identity.library.provenance.revision == facts.benchmarkSource.revision)
local pin: any = binding
local pinModule = { IsA = function(_, name) return name == "ModuleScript" end }
local relayModule, adapterModule, factory = {}, {}, {}
local adapters = { RelayReliable = adapterModule, FindFirstChild = function(_, name) assert(name == "RelayAdapterPin") return pinModule end }
local allowlist = luau.load(fs.readFile("benchmarks/runner/AdapterAllowlist.luau"), { environment = {
	game = { GetService = function() return { Relay = relayModule, RelayBenchmark = { adapters = adapters } } end },
	require = function(module)
		if module == pinModule then return pin end
		if module == relayModule then return { VERSION = "0.1.0" } end
		assert(module == adapterModule); return factory
	end,
} })()
assert(allowlist.resolve(binding).factory == factory)
local function copy(value) return serde.decode("json", serde.encode("json", value)) end
for _, mutate in {
	function(value) value.identity.library.provenance.revision = string.rep("b", 40) end,
	function(value) value.identity.library.provenance.checksum = "sha256:" .. string.rep("b", 64) end,
	function(value) value.identity.library.provenance.sourceRepository = "https://example.com/relay" end,
	function(value) value.identity.library.version = "2.0.0" end,
	function(value) value.identity.semantics.intentionalAddedDeliveryFrames = 1 end,
	function(value) value.artifact.digest = "sha256:" .. string.rep("b", 64) end,
	function(value) value.extra = true end,
} do
	local foreign = copy(binding); mutate(foreign)
	assert(allowlist.resolve(foreign).kind == "Rejected")
end
pin = copy(binding); pin.identity.library.provenance.revision = "malformed"
assert(allowlist.resolve(binding).kind == "Rejected", "malformed trusted pin must fail closed")
pin = copy(binding); pin.identity.library.provenance.sourceRepository = "https://example.com/relay"
assert(allowlist.resolve(pin).kind == "Rejected", "foreign repository pin must fail closed")
print("Relay reliable adapter checks passed")
