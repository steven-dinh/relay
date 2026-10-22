local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local ServerRuntime = require("./support/ServerRuntime")
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	debugName = "Frame",
	injectGlobals = true,
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		require = function(path)
			assert(path == "./CompositeCodec")
			return CompositeCodec
		end,
	},
})()

local sequence = 0
local function newDefinition(capacity, refillPerSecond)
	sequence += 1
	local spec = {
		name = `StateDeferral{sequence}`,
		version = 1,
		events = {
			Drain = { id = 1, direction = "ServerToClient", fields = { { name = "value", type = "u8" } } },
			ReliableState = { id = 2, direction = "ServerToClient", queue = "State",
				fields = { { name = "value", type = "u8" } } },
			UnreliableState = { id = 3, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
				fields = { { name = "value", type = "u8" } } },
			TextState = { id = 4, direction = "ServerToClient", queue = "State",
				fields = { { name = "value", type = "string", maximumBytes = 64 } } },
			UnreliableTextState = { id = 5, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
				fields = { { name = "value", type = "string", maximumBytes = 64 } } },
		},
	}
	if capacity ~= nil then
		spec.outboundBytes = { capacity = capacity, refillPerSecond = refillPerSecond }
	end
	local token, issue = Definition.define(spec)
	assert(token, issue and issue.message)
	return token
end

local function serverOptions()
	return { inboundRate = {
		perPlayer = { capacity = 4_096, refillPerSecond = 1 },
		aggregate = { capacity = 32_768, refillPerSecond = 1 },
	} }
end

local function setup(capacity, refillPerSecond)
	local runtime = ServerRuntime.new()
	local player = runtime:addPlayer()
	local definition = newDefinition(capacity, refillPerSecond)
	local server = assert(runtime.server.create(definition, serverOptions()))
	assert(server:Start())
	return runtime, server, player, definition
end

local function assertCode(expected, value, issue)
	assert((value == nil or value == false) and issue ~= nil and issue.code == expected,
		`expected {expected}, got {if issue then issue.code else "success"}`)
end

local function decodeState(packet, definition)
	local compiled = assert(Definition.get(definition))
	local header = assert(BatchFrame.header(packet, 8_192))
	local rows = assert(BatchFrame.scan(packet, header, function(id) return compiled.queuedById[id] end))
	assert(#rows == 1)
	local valid, values = Frame.compile(rows[1].event, "decode")(assert(BatchFrame.readBody(packet, rows[1])))
	assert(valid)
	return values
end

-- The closed, server-only scheduling opt-in requires a policy and exactly one captured player.
do
	local runtime, server, first = setup(nil)
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = true }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, false))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = 1 }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = false, extra = true }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, setmetatable({ deferOutbound = true }, {})))
	local second = runtime:addPlayer()
	local legacy = assert(server:CreateState({ first, second }, 0.02, { deferOutbound = false }))
	legacy:Destroy()
	server:Destroy()

	local runtime2, server2, eligible = setup(32, 18)
	local duplicate = assert(server2:CreateState({ eligible, eligible }, 0.02, { deferOutbound = true }))
	assertCode("InvalidAudience", server2:CreateState({}, 0.02, { deferOutbound = true }))
	local other = runtime2:addPlayer()
	assertCode("InvalidAudience", server2:CreateState({ eligible, other }, 0.02, { deferOutbound = true }))
	local peers = { duplicate }
	for _ = 1, 3 do
		peers[#peers + 1] = assert(server2:CreateState({ eligible }, 0.02))
	end
	assertCode("QueueLimit", server2:CreateState({ eligible }, 0.02, { deferOutbound = true }))
	for _, lane in peers do lane:Destroy() end
	server2:Destroy()
end

-- Combined reliable and unreliable packets are reserved together, then serviced automatically.
do
	local runtime, server, player = setup(32, 18)
	assert(server.events.Drain:Send(player, 1) and server.events.Drain:Send(player, 2))
	local firesBeforeState = #runtime.fires
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	local refused = state:GetStatus()
	assert(refused.pendingKeys == 2 and refused.lastFlush.error.code == "OutboundRateLimited"
		and refused.lastFlush.report.selected == 0 and refused.lastFlush.report.remaining == 2
		and #runtime.fires == firesBeforeState,
		"combined budget refusal retains both channels without a partial handoff")
	assert(runtime:activeTimers() == 1, "budget refusal schedules one bounded retry timer")
	runtime:advance(0.39)
	assert(#runtime.fires == firesBeforeState, "predicted refill deadline is not serviced early")
	runtime:advance(0.02)
	local delivered = state:GetStatus()
	assert(delivered.pendingKeys == 0 and delivered.lastFlush.ok and delivered.lastFlush.report.selected == 2
		and #runtime.fires == firesBeforeState + 2,
		"the retained dual-channel state sends once after refill without another Put or Flush")
	assert(runtime.fires[firesBeforeState + 1].remote.ClassName == "RemoteEvent"
		and runtime.fires[firesBeforeState + 2].remote.ClassName == "UnreliableRemoteEvent"
		and buffer.len(runtime.fires[firesBeforeState + 1].values[2]) == 9
		and buffer.len(runtime.fires[firesBeforeState + 2].values[2]) == 9,
		"both complete packet envelopes are reserved")
	server:Destroy()
end

-- Replacement retry sizing must not charge an absent channel's packet header.
for _, case in { { "TextState", "RemoteEvent" }, { "UnreliableTextState", "UnreliableRemoteEvent" } } do
	local eventName, remoteClass = case[1], case[2]
	local runtime, server, player = setup(10, 20)
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events[eventName]:Put(1, "Normal", string.rep("x", 40)))
	runtime:advance(0.05)
	assert(state:GetStatus().pendingKeys == 1 and state:GetStatus().lastFlush.error.code == "OutboundRateLimited"
		and runtime:activeTimers() == 1 and #runtime.fires == 0,
		"an over-capacity value waits for its existing expiry")
	local staleTimer = runtime.timers[#runtime.timers]
	runtime:advance(0.15)
	assert(state.events[eventName]:Put(1, "Normal", ""))
	assert(runtime:activeTimers() == 1, "replacement brings the single retry timer forward")
	staleTimer.callback()
	assert(#runtime.fires == 0 and runtime:activeTimers() == 1,
		"a canceled expiry callback cannot flush the replacement")
	runtime:advance(0.049)
	assert(#runtime.fires == 0, "replacement does not send before its minimum service interval")
	runtime:advance(0.002)
	local status = state:GetStatus()
	assert(status.pendingKeys == 0 and status.lastFlush.ok and status.lastFlush.report.selected == 1
		and #runtime.fires == 1 and runtime.fires[1].remote.ClassName == remoteClass
		and buffer.len(runtime.fires[1].values[2]) == 10
		and server:GetDiagnostics().counters.outboundBytesCharged == 10,
		"the exact-capacity 10-byte packet sends automatically on its own delivery channel")
	server:Destroy()
end

-- A new key can make the existing refused selection affordable and should advance its retry.
do
	local runtime, server, player = setup(200, 20)
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.TextState:Put(1, "Low", string.rep("x", 40)))
	for key = 1, 31 do
		assert(state.events.ReliableState:Put(key, "Normal", key))
	end
	runtime:advance(0.05)
	local refused = state:GetStatus()
	assert(refused.pendingKeys == 32 and refused.lastFlush.error.code == "OutboundRateLimited"
		and refused.lastFlush.report.selected == 0 and #runtime.fires == 0
		and runtime:activeTimers() == 1,
		"the 236-byte, 32-row selection waits after its initial rate refusal")
	local staleTimer = runtime.timers[#runtime.timers]
	runtime:advance(0.15)
	assert(state.events.ReliableState:Put(32, "High", 32))
	assert(runtime:activeTimers() == 1 and runtime.timers[#runtime.timers] ~= staleTimer,
		"a new key advances the single retry timer")
	staleTimer.callback()
	assert(#runtime.fires == 0 and runtime:activeTimers() == 1,
		"a canceled expiry callback cannot flush the newly affordable selection")
	runtime:advance(0.049)
	assert(#runtime.fires == 0, "the new key does not bypass the minimum service interval")
	runtime:advance(0.002)
	local delivered = state:GetStatus()
	assert(delivered.pendingKeys == 1 and delivered.lastFlush.ok
		and delivered.lastFlush.report.selected == 32 and delivered.lastFlush.report.expired == 0
		and #runtime.fires == 1 and buffer.len(runtime.fires[1].values[2]) == 195
		and server:GetDiagnostics().counters.outboundBytesCharged == 195,
		"the 195-byte selection sends automatically with its low-priority row retained")
	runtime:advance(0.75)
	local expired = state:GetStatus()
	assert(expired.pendingKeys == 0 and expired.lastFlush.report.expired == 1
		and #runtime.fires == 1 and runtime:activeTimers() == 0,
		"the retained low-priority key keeps its original expiry and is not delivered late")
	server:Destroy()
end

-- Removing one refused channel retries its exact-capacity survivor and rejects the stale timer.
do
	local runtime, server, player = setup(9, 18)
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	assert(state:GetStatus().lastFlush.error.code == "OutboundRateLimited"
		and state:GetStatus().pendingKeys == 2 and runtime:activeTimers() == 1)
	local staleTimer = runtime.timers[#runtime.timers]
	assert(state.events.ReliableState:Remove(1))
	assert(state:GetStatus().pendingKeys == 1 and runtime:activeTimers() == 1)
	staleTimer.callback()
	assert(#runtime.fires == 0 and runtime:activeTimers() == 1,
		"a canceled expiry callback cannot flush the surviving record")
	runtime:advance(0.049)
	assert(#runtime.fires == 0, "the survivor does not send before its minimum service interval")
	runtime:advance(0.002)
	local status = state:GetStatus()
	assert(status.pendingKeys == 0 and status.lastFlush.ok and status.lastFlush.report.selected == 1
		and #runtime.fires == 1 and runtime.fires[1].remote.ClassName == "UnreliableRemoteEvent"
		and buffer.len(runtime.fires[1].values[2]) == 9
		and server:GetDiagnostics().counters.outboundBytesCharged == 9,
		"Remove automatically sends the exact-capacity 9-byte survivor")
	server:Destroy()
end

-- Removal keeps the survivor's original first-dirty expiry.
do
	local runtime, server, player = setup(9, 18)
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	runtime:advance(0.9)
	assert(state.events.ReliableState:Remove(1))
	runtime:advance(0.05)
	local status = state:GetStatus()
	assert(status.pendingKeys == 0 and status.lastFlush.report.expired == 1
		and #runtime.fires == 0 and runtime:activeTimers() == 0,
		"a survivor removed at the original age limit expires without a late handoff")
	server:Destroy()
end

-- A very short producer interval cannot turn tiny retry estimates into a zero-delay loop.
do
	local runtime, server, player = setup(18, 1_000_000)
	assert(server.events.Drain:Send(player, 1))
	local state = assert(server:CreateState({ player }, 0.001, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	local ok, issue = state:Flush()
	assert(not ok and issue.code == "OutboundRateLimited" and runtime:activeTimers() == 1)
	runtime:advance(1 / 60 - 0.0001)
	assert(#runtime.fires == 1 and runtime:activeTimers() == 1,
		"tiny predicted refill still observes the 1/60-second minimum retry interval")
	runtime:advance(0.0002)
	assert(#runtime.fires == 2 and state:GetStatus().lastFlush.ok,
		"the minimum-spaced retry sends once after refill")
	server:Destroy()
end

-- An over-capacity frame waits only for expiry; at expiry, a survivor is reselected and can fit.
do
	local runtime, server, player = setup(16, 10)
	assert(server.events.Drain:Send(player, 1))
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	runtime:advance(0.04)
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.01)
	assert(state:GetStatus().lastFlush.error.code == "OutboundRateLimited"
		and state:GetStatus().pendingKeys == 2 and runtime:activeTimers() == 1,
		"an unattainable 18-byte combined charge waits for the first-dirty expiry")
	runtime:advance(0.95)
	local status = state:GetStatus()
	assert(status.pendingKeys == 0 and status.lastFlush.ok and status.lastFlush.report.expired == 1
		and status.lastFlush.report.selected == 1 and #runtime.fires == 2
		and runtime.fires[2].remote.ClassName == "UnreliableRemoteEvent",
		"the expiry wake drops the older value and reevaluates the surviving channel")
	server:Destroy()
end

-- Replacement can bring a retry forward with its latest value, without resetting first-dirty age.
do
	local runtime, server, player, definition = setup(24, 20)
	assert(server.events.Drain:Send(player, 1))
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.TextState:Put(1, "Normal", string.rep("x", 40)))
	runtime:advance(0.05)
	assert(state:GetStatus().lastFlush.error.code == "OutboundRateLimited")
	local staleTimer = runtime.timers[#runtime.timers]
	runtime:advance(0.15)
	assert(state.events.TextState:Put(1, "Normal", "new"))
	assert(runtime:activeTimers() == 1, "replacement reschedules the single retry timer")
	staleTimer.callback()
	assert(#runtime.fires == 1 and runtime:activeTimers() == 1,
		"a canceled budget callback cannot flush the replacement")
	runtime:advance(0.05)
	local decodedReplacement = if #runtime.fires >= 2 then decodeState(runtime.fires[2].values[2], definition) else nil
	assert(#runtime.fires == 2 and state:GetStatus().lastFlush.ok
		and decodedReplacement == "new",
		"a smaller latest replacement moves service forward and is the only value delivered")
	server:Destroy()

	local runtime2, server2, player2 = setup(18, 1)
	assert(server2.events.Drain:Send(player2, 1))
	local aging = assert(server2:CreateState({ player2 }, 0.05, { deferOutbound = true }))
	assert(aging.events.ReliableState:Put(7, "Normal", 1))
	runtime2:advance(0.05)
	runtime2:advance(0.94)
	assert(aging.events.ReliableState:Put(7, "High", 2))
	runtime2:advance(0.01)
	local agedStatus = aging:GetStatus()
	assert(agedStatus.pendingKeys == 0 and agedStatus.lastFlush.ok and agedStatus.lastFlush.report.expired == 1
		and #runtime2.fires == 1 and runtime2:activeTimers() == 0,
		"replacement retains its original age and is not sent after that age expires")
	server2:Destroy()
end

-- Impossible charges expire without polling, and removal/destroy release opted-in lanes.
do
	local runtime, server, player = setup(8, 1_000_000)
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	runtime:advance(0.05)
	assert(state:GetStatus().lastFlush.error.code == "OutboundRateLimited" and runtime:activeTimers() == 1)
	runtime:advance(0.94)
	assert(state:GetStatus().pendingKeys == 1 and runtime:activeTimers() == 1,
		"an over-capacity packet does not schedule repeated budget probes")
	runtime:advance(0.01)
	assert(state:GetStatus().pendingKeys == 0 and state:GetStatus().lastFlush.report.expired == 1
		and #runtime.fires == 0 and runtime:activeTimers() == 0,
		"the impossible packet is discarded only at the existing expiry")
	server:Destroy()

	local runtime2, server2, player2 = setup(8, 18)
	local pending = assert(server2:CreateState({ player2 }, 0.05, { deferOutbound = true }))
	assert(pending.events.ReliableState:Put(3, "Normal", 1))
	runtime2:advance(0.05)
	assert(pending:GetStatus().pendingKeys == 1 and runtime2:activeTimers() == 1)
	local staleTimer = runtime2.timers[#runtime2.timers]
	runtime2:removePlayer(player2)
	assert(pending:GetStatus().state == "Destroyed" and pending:GetStatus().activeKeys == 0
		and pending:GetStatus().pendingBodyBytes == 0 and runtime2:activeTimers() == 0,
		"player removal closes the opted-in lane and releases state accounting")
	local replacement = runtime2:addPlayer()
	staleTimer.callback()
	runtime2:advance(2)
	assert(#runtime2.fires == 0 and replacement.Parent == runtime2.players,
		"departed-player values never transfer to a replacement player or stale callback")
	server2:Destroy()

	local runtime3, server3, player3 = setup(32, 18)
	local destroyed = assert(server3:CreateState({ player3 }, 0.05, { deferOutbound = true }))
	assert(destroyed.events.ReliableState:Put(4, "Normal", 1))
	server3:Destroy()
	assert(destroyed:GetStatus().state == "Destroyed" and destroyed:GetStatus().pendingKeys == 0
		and runtime3:activeTimers() == 0)
	runtime3:advance(1)
	assert(#runtime3.fires == 0, "session destruction cancels deferred retries and releases payloads")
end

-- A possibly delivered packet is consumed once and is never replayed after transport failure.
do
	local runtime, server, player = setup(18, 10)
	local state = assert(server:CreateState({ player }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	runtime.afterFire = function() error("uncertain transport result") end
	local ok, issue, report = state:Flush()
	assert(not ok and issue.code == "TransportFailure" and report.selected == 1 and report.reliableHandoffs == 0
		and state:GetStatus().pendingKeys == 0 and #runtime.fires == 1,
		"selected bytes are consumed before an uncertain transport handoff")
	runtime.afterFire = nil
	local beforeRetry = server:GetDiagnostics().counters.outboundBytesCharged
	assert(state:Flush() and state:GetStatus().lastFlush.report.selected == 0)
	runtime:advance(2)
	assert(#runtime.fires == 1 and server:GetDiagnostics().counters.outboundBytesCharged == beforeRetry,
		"uncertain transport failure never causes automatic or explicit replay")
	server:Destroy()
end

print("PASS Relay.StateDeferral bounded retries, expiry, replacement and cleanup")
