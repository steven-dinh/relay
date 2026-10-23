local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local BatchFrame = require("../src/internal/BatchFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local Runtime = require("./support/ServerRuntime")

local definition = assert(Definition.define({ name = "AdmissionFairnessTest", version = 1, events = {
	Important = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
	Other = { id = 2, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
	Empty = { id = 3, direction = "ClientToServer", fields = {} },
	Fifo = { id = 4, direction = "ClientToServer", queue = "Batch", fields = { { name = "value", type = "u8" } } },
	State = { id = 5, direction = "ClientToServer", queue = "State", fields = { { name = "value", type = "u8" } } },
	Unreliable = { id = 6, direction = "ClientToServer", delivery = "Unreliable",
		fields = { { name = "value", type = "u8" } } },
}, requests = {
	Ping = { id = 20, request = {}, response = { type = "boolean" } },
} }))
local compiled = assert(Definition.get(definition))

local function rateOptions(playerCapacity, playerRefill, aggregateCapacity, aggregateRefill,
	maxPeers, reserveCapacity, reserveRefill)
	local rate = {
		perPlayer = { capacity = playerCapacity, refillPerSecond = playerRefill },
		aggregate = { capacity = aggregateCapacity, refillPerSecond = aggregateRefill },
	}
	if maxPeers ~= nil then
		rate.fairness = {
			maxPeers = maxPeers,
			reserve = { capacity = reserveCapacity, refillPerSecond = reserveRefill },
		}
	end
	return { inboundRate = rate }
end

local function assertInvalidOptions(options)
	local runtime = Runtime.new()
	local server, problem = runtime.server.create(definition, options)
	assert(server == nil and problem.code == "InvalidOptions")
end

local function start(runtime, options)
	local server = assert(runtime.server.create(definition, options))
	assert(server:Start())
	return server, runtime:remote()
end

local function queuedBody(eventId, value)
	local encoded = table.pack(Frame.compile(compiled.queuedById[eventId], "encode")(value))
	assert(encoded[1] == true)
	return encoded[2]
end

-- The current aggregate budget reproduces starvation from repeated malformed traffic.
do
	local runtime = Runtime.new()
	local attacker, honest = runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(4, 4, 4, 4))
	local calls = 0
	assert(server.events.Important:Connect(function(sender, value)
		assert(sender == honest and value == 7)
		calls += 1
	end))

	for burst = 1, 2 do
		if burst == 2 then runtime:advance(1) end
		for _ = 1, 4 do remote.OnServerEvent:Fire(attacker, 255) end
		remote.OnServerEvent:Fire(honest, 1, 7)
		assert(calls == 0, "the shared aggregate bucket blocks the honest command")
	end
	local counters = server:GetDiagnostics().counters
	assert(counters.received == 10 and counters.invalidEndpoint == 8
		and counters.aggregateRate == 2 and counters.dispatched == 0)
	server:Destroy()
end

-- Configuration is bounded, copied by value, and visible as a frozen diagnostic snapshot.
do
	for _, invalid in {
		{ 0, 1, 1 }, { 65, 1, 1 }, { 1.5, 1, 1 }, { 2, 2, 1 }, { 2, 1, 2 },
	} do
		assertInvalidOptions(rateOptions(4, 4, 4, 4, invalid[1], invalid[2], invalid[3]))
	end
	for _, invalid in {
		{ 0, 1 }, { 5, 1 }, { 1, 5 }, { 2, 2 },
	} do
		assertInvalidOptions(rateOptions(4, 4, 4, 4, 2, invalid[1], invalid[2]))
	end
	local invalid = rateOptions(4, 4, 4, 4, 2, 1, 1)
	invalid.inboundRate.fairness.extra = true
	assertInvalidOptions(invalid)
	invalid = rateOptions(4, 4, 4, 4, 2, 1, 1)
	setmetatable(invalid.inboundRate.fairness, {})
	assertInvalidOptions(invalid)

	local runtime = Runtime.new()
	local attacker, honest = runtime:addPlayer(), runtime:addPlayer()
	local options = rateOptions(4, 4, 4, 4, 2, 1, 1)
	local fairness = options.inboundRate.fairness
	local server = assert(runtime.server.create(definition, options))
	fairness.maxPeers = 1
	fairness.reserve.capacity = 2
	fairness.reserve.refillPerSecond = 2
	local snapshot = server:GetDiagnostics()
	assert(snapshot.inboundRate.fairness.maxPeers == 2
		and snapshot.inboundRate.fairness.reserve.capacity == 1
		and table.isfrozen(snapshot.inboundRate) and table.isfrozen(snapshot.inboundRate.fairness)
		and table.isfrozen(snapshot.inboundRate.fairness.reserve))
	local calls = 0
	assert(server.events.Important:Connect(function(sender) assert(sender == honest); calls += 1 end))
	local reads = runtime.clockReads
	assert(server:Start())
	assert(runtime.clockReads == reads + 3, "one Start clock sample seeds the aggregate and both fixed slots")
	local remote = runtime:remote()
	for _ = 1, 4 do remote.OnServerEvent:Fire(attacker, 255) end
	remote.OnServerEvent:Fire(honest, 1, 7)
	assert(calls == 1, "post-construction option mutation does not change slot assignment or quotas")
	server:Destroy()
end

-- Each slotted peer keeps one reserved token while the attacker drains reserve and shared capacity.
do
	local runtime = Runtime.new()
	local attacker, honest, overflow = runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
	local options = rateOptions(4, 4, 4, 4, 2, 1, 1)
	local fairness = options.inboundRate.fairness
	local server = assert(runtime.server.create(definition, options))
	local calls = 0
	assert(server.events.Important:Connect(function(sender, value)
		assert(sender == honest and value == 7)
		calls += 1
	end))
	assert(server:Start())
	local remote, unreliable = runtime:remote(), runtime:unreliableRemote()
	for window = 1, 3 do
		if window > 1 then runtime:advance(1) end
		remote.OnServerEvent:Fire(attacker, 255)
		unreliable.OnServerEvent:Fire(attacker, 1, 9)
		remote.OnServerEvent:Fire(attacker, 255)
		remote.OnServerEvent:Fire(attacker, 255)
		remote.OnServerEvent:Fire(honest, 1, 7)
		assert(calls == window, "the slotted honest peer recovers once per refill window")
	end
	local counters = server:GetDiagnostics().counters
	assert(counters.invalidEndpoint == 6 and counters.wrongChannel == 3
		and counters.aggregateRate == 3 and counters.dispatched == 3 and counters.perPlayerRate == 0)
	server:Destroy()
	assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)
	assert(fairness.maxPeers == 2, "the caller retains ownership of its mutable options")
end

-- Per-player exhaustion returns before it can spend another admission pool.
do
	local runtime = Runtime.new()
	local attacker, honest, overflow = runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(1, 1, 4, 4, 2, 1, 1))
	local calls = 0
	assert(server.events.Important:Connect(function(sender) assert(sender == honest); calls += 1 end))
	assert(server.events.Other:Connect(function(sender) assert(sender == overflow); calls += 1 end))
	remote.OnServerEvent:Fire(attacker, 255)
	remote.OnServerEvent:Fire(attacker, 1, 7)
	remote.OnServerEvent:Fire(attacker, 1, 7)
	remote.OnServerEvent:Fire(honest, 1, 7)
	remote.OnServerEvent:Fire(overflow, 2, 8)
	local counters = server:GetDiagnostics().counters
	assert(calls == 2 and counters.invalidEndpoint == 1 and counters.perPlayerRate == 2
		and counters.aggregateRate == 0 and counters.dispatched == 2)
	server:Destroy()
end

-- A byte refusal and an endpoint refusal still spend their earlier call admission.
do
	local runtime = Runtime.new()
	local attacker, honest = runtime:addPlayer(), runtime:addPlayer()
	local options = rateOptions(4, 4, 4, 4, 2, 1, 1)
	options.inboundRate.bytes = {
		perPlayer = { capacity = 3, refillPerSecond = 1 },
		aggregate = { capacity = 3, refillPerSecond = 1 },
	}
	local server, remote = start(runtime, options)
	remote.OnServerEvent:Fire(attacker, 1, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	local counters = server:GetDiagnostics().counters
	assert(counters.perPlayerBytes == 3 and counters.aggregateBytes == 0
		and counters.aggregateRate == 1 and counters.dispatched == 0,
		"three later byte rejections keep their reserved/shared call charges")
	server:Destroy()

	runtime = Runtime.new()
	attacker, honest = runtime:addPlayer(), runtime:addPlayer()
	options = rateOptions(4, 4, 4, 4, 2, 1, 1)
	options.inboundRate.endpoints = { [1] = { capacity = 1, refillPerSecond = 1 } }
	server, remote = start(runtime, options)
	local calls = 0
	assert(server.events.Important:Connect(function() calls += 1 end))
	assert(server.events.Other:Connect(function() calls += 1 end))
	remote.OnServerEvent:Fire(attacker, 1, 1)
	remote.OnServerEvent:Fire(attacker, 1, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	counters = server:GetDiagnostics().counters
	assert(calls == 2 and counters.endpointRate == 1 and counters.aggregateRate == 1
		and counters.dispatched == 2,
		"an endpoint rejection retains its shared charge while the aggregate still has the other peer's reserve")
	server:Destroy()
end

-- A busy rejection spends the same fixed/shared call pool, leaving other peer reserve intact.
do
	local runtime = Runtime.new()
	local attacker, honest = runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(4, 4, 4, 4, 2, 1, 1))
	local waiting
	assert(server.events.Important:Connect(function()
		waiting = coroutine.running()
		coroutine.yield()
	end))
	local otherCalls = 0
	assert(server.events.Other:Connect(function() otherCalls += 1 end))
	remote.OnServerEvent:Fire(attacker, 1, 1)
	remote.OnServerEvent:Fire(attacker, 1, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	remote.OnServerEvent:Fire(attacker, 2, 1)
	local counters = server:GetDiagnostics().counters
	assert(waiting ~= nil and otherCalls == 1 and counters.busy == 1 and counters.aggregateRate == 1
		and counters.dispatched == 2,
		"busy consumes the last shared token without consuming the honest peer's reserve")
	server:Destroy()
	assert(coroutine.resume(waiting))
end

-- A queued frame that cannot afford every logical call spends earlier debits and dispatches no rows.
for _, item in { { id = 4, kind = 1 }, { id = 5, kind = 2 } } do
	local runtime = Runtime.new()
	local player, honest, overflow = runtime:addPlayer(), runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(8, 8, 8, 8, 2, 1, 1))
	local calls = 0
	local honestCalls = 0
	assert(server.events[item.id == 4 and "Fifo" or "State"]:Connect(function() calls += 1 end))
	assert(server.events.Important:Connect(function(sender) assert(sender == honest); honestCalls += 1 end))
	local body = queuedBody(item.id, 9)
	local packet = assert(BatchFrame.wrap(item.kind,
		{ body, body, body, body, body, body, body, body }, 8_192))
	remote.OnServerEvent:Fire(player, 0, packet)
	remote.OnServerEvent:Fire(overflow, 3)
	remote.OnServerEvent:Fire(honest, 1, 7)
	local counters = server:GetDiagnostics().counters
	assert(calls == 0 and honestCalls == 1 and counters.aggregateRate == 2 and counters.invalidPayload == 0
		and counters.perPlayerRate == 0 and counters.dispatched == 1,
		"the refused frame keeps its shared charges while preserving the other slot")
	server:Destroy()
end

-- Fractional and backward timestamps do not mint slot/shared admission tokens.
do
	local runtime = Runtime.new()
	local slotted, overflow = runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(8, 2, 8, 2, 1, 1, 1))
	remote.OnServerEvent:Fire(slotted, 255)
	for _ = 1, 7 do remote.OnServerEvent:Fire(overflow, 255) end
	runtime:advance(0.25)
	remote.OnServerEvent:Fire(slotted, 255)
	runtime:advance(0.25)
	remote.OnServerEvent:Fire(slotted, 255)
	runtime:advance(-0.25)
	remote.OnServerEvent:Fire(slotted, 255)
	runtime:advance(0.25)
	remote.OnServerEvent:Fire(slotted, 255)
	runtime:advance(0.5)
	remote.OnServerEvent:Fire(slotted, 255)
	remote.OnServerEvent:Fire(overflow, 255)
	local counters = server:GetDiagnostics().counters
	assert(counters.aggregateRate == 4 and counters.invalidEndpoint == 10 and counters.perPlayerRate == 0,
		"fractional waits and backward time refuse until slot and shared buckets refill")
	server:Destroy()
end

-- Malformed endpoint-zero traffic and RPC use the same aggregate fairness pools.
do
	local runtime = Runtime.new()
	local player, overflow = runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(5, 5, 5, 5, 1, 2, 2))
	local calls = 0
	assert(server.requests.Ping:Connect(function(sender)
		assert(sender == player)
		calls += 1
		return true
	end))
	remote.OnServerEvent:Fire(player, 0, buffer.create(1))
	local encoded = table.pack(Frame.compile(compiled.requests.Ping.request, "encode")())
	assert(encoded[1] == true)
	local request = assert(RpcFrame.wrap(1, compiled.requests.Ping.id, 1,
		"01234567-89ab-cdef-0123-456789abcdef", encoded[2]))
	remote.OnServerEvent:Fire(player, 0, request)
	for _ = 1, 3 do remote.OnServerEvent:Fire(overflow, 255) end
	remote.OnServerEvent:Fire(player, 0, buffer.create(1))
	local counters = server:GetDiagnostics().counters
	assert(calls == 1 and counters.invalidPayload == 1 and counters.dispatched == 1
		and counters.invalidEndpoint == 3 and counters.aggregateRate == 1 and counters.perPlayerRate == 0,
		"endpoint-zero malformed traffic and RPC consume the reserved pool before refusal")
	server:Destroy()
end

-- Removed peers do not transfer slot ownership; reused slots retain their bucket state.
do
	local runtime = Runtime.new()
	local slotted, overflow = runtime:addPlayer(), runtime:addPlayer()
	local server, remote = start(runtime, rateOptions(3, 100, 3, 100, 1, 2, 1))
	remote.OnServerEvent:Fire(slotted, 255)
	remote.OnServerEvent:Fire(overflow, 255)
	runtime:removePlayer(slotted)
	runtime:advance(0.01)
	remote.OnServerEvent:Fire(overflow, 255)
	local replacement = runtime:addPlayer()
	remote.OnServerEvent:Fire(replacement, 3)
	local counters = server:GetDiagnostics().counters
	assert(counters.aggregateRate == 1 and counters.invalidEndpoint == 2 and counters.noListener == 1,
		"the overflow peer is not promoted; the new owner inherits the remaining slot token")
	server:Destroy()
	assert(runtime.connections == 0 and #runtime.storage:GetChildren() == 0)

	runtime = Runtime.new()
	slotted, overflow = runtime:addPlayer(), runtime:addPlayer()
	server, remote = start(runtime, rateOptions(2, 100, 2, 100, 1, 1, 1))
	remote.OnServerEvent:Fire(slotted, 255)
	remote.OnServerEvent:Fire(overflow, 255)
	runtime:removePlayer(slotted)
	runtime:advance(0.01)
	replacement = runtime:addPlayer()
	remote.OnServerEvent:Fire(replacement, 3)
	counters = server:GetDiagnostics().counters
	assert(counters.aggregateRate == 1 and counters.noListener == 0,
		"slot reuse cannot mint a fresh reserve token while the aggregate refills")
	server:Destroy()
end

print("PASS Relay.AdmissionFairness")
