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

-- The closed, server-only scheduling opt-in requires a policy; independent progress has a separate audience cap.
do
	local runtime, server, first = setup(nil)
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = true }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = true, progress = "Independent" }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { progress = "Independent" }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, false))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = 1 }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = false, extra = true }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, { deferOutbound = true, progress = "independent" }))
	assertCode("InvalidOptions", server:CreateState({ first }, 0.02, setmetatable({ deferOutbound = true }, {})))
	local second = runtime:addPlayer()
	local legacy = assert(server:CreateState({ first, second }, 0.02, { deferOutbound = false }))
	legacy:Destroy()
	server:Destroy()

	local runtime2, server2, eligible = setup(32, 18)
	local duplicate = assert(server2:CreateState({ eligible, eligible }, 0.02, { deferOutbound = true }))
	assertCode("InvalidAudience", server2:CreateState({}, 0.02, { deferOutbound = true }))
	local other = runtime2:addPlayer()
	local atomicMulti = assert(server2:CreateState({ eligible, other }, 0.02, { deferOutbound = true }))
	atomicMulti:Destroy()
	local independent = assert(server2:CreateState({ eligible, other }, 0.02,
		{ deferOutbound = true, progress = "Independent" }))
	independent:Destroy()
	local tooMany = { eligible, other }
	for _ = 1, 63 do tooMany[#tooMany + 1] = runtime2:addPlayer() end
	assertCode("InvalidAudience", server2:CreateState(tooMany, 0.02,
		{ deferOutbound = true, progress = "Independent" }))
	local peers = { duplicate }
	for _ = 1, 3 do
		peers[#peers + 1] = assert(server2:CreateState({ eligible }, 0.02))
	end
	assertCode("QueueLimit", server2:CreateState({ eligible }, 0.02, { deferOutbound = true }))
	for _, lane in peers do lane:Destroy() end
	server2:Destroy()
end

-- Independent automatic service keeps the 1/60-second floor even when flushAfter is 1ms.
do
	local runtime, server, player = setup(1_024, 1_024)
	local firesBeforeState = #runtime.fires
	local state = assert(server:CreateState({ player }, 0.001,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	runtime:advance(0.001)
	assert(#runtime.fires == firesBeforeState and state:GetStatus().pendingKeys == 1,
		"independent initial service cannot follow a sub-floor producer interval")
	runtime:advance(1 / 60 - 0.001 - 0.0001)
	assert(#runtime.fires == firesBeforeState, "independent service remains behind the 1/60-second floor")
	runtime:advance(0.0002)
	assert(#runtime.fires == firesBeforeState + 1 and state:GetStatus().pendingKeys == 0,
		"independent service starts once the floor elapses")
	server:Destroy()
end

-- A record-count split also waits one floored interval before automatically sending its leftover key.
do
	local runtime, server, player = setup(1_024, 1_024)
	local firesBeforeState = #runtime.fires
	local state = assert(server:CreateState({ player }, 0.001,
		{ deferOutbound = true, progress = "Independent" }))
	for key = 1, 33 do
		assert(state.events.ReliableState:Put(key, "Normal", key))
	end
	local floor = 1 / 60
	runtime:advance(floor - 0.0001)
	assert(#runtime.fires == firesBeforeState, "the first count-split packet observes the minimum service interval")
	runtime:advance(0.0002)
	local firstFlush = state:GetStatus().lastFlush.report
	assert(#runtime.fires == firesBeforeState + 1 and firstFlush.selected == 32
		and firstFlush.remaining == 1 and state:GetStatus().pendingKeys == 1,
		"the first automatic packet respects the existing 32-record limit")
	runtime:advance(0.001)
	assert(#runtime.fires == firesBeforeState + 1,
		"a count-split leftover cannot flush at the 1ms producer interval")
	runtime:advance(floor - 0.0011 - 0.0001)
	assert(#runtime.fires == firesBeforeState + 1,
		"the leftover remains queued until the next floored service deadline")
	runtime:advance(0.0002)
	assert(#runtime.fires == firesBeforeState + 2 and state:GetStatus().pendingKeys == 0
		and state:GetStatus().lastFlush.report.selected == 1,
		"the leftover key is sent automatically after a second minimum-spaced interval")
	server:Destroy()
end

-- An Independent timer that collides with another lane's flush retries at the floor after QueueBusy.
do
	local runtime, server, first = setup(1_024, 1_024)
	local second = runtime:addPlayer()
	local firesBeforeState = #runtime.fires
	local otherLane = assert(server:CreateState({ first }, 1 / 60))
	local independent = assert(server:CreateState({ second }, 0.001,
		{ deferOutbound = true, progress = "Independent" }))
	assert(otherLane.events.ReliableState:Put(1, "Normal", 1))
	assert(independent.events.ReliableState:Put(2, "Normal", 2))
	local independentTimer = runtime.timers[#runtime.timers]
	local collided = false
	runtime.afterFire = function()
		if not collided then
			collided = true
			independentTimer.callback()
		end
	end
	runtime:advance(1 / 60 + 0.0001)
	runtime.afterFire = nil
	assert(collided and #runtime.fires == firesBeforeState + 1
		and otherLane:GetStatus().pendingKeys == 0 and independent:GetStatus().pendingKeys == 1,
		"the Independent timer observes QueueBusy while the other lane owns the flush")
	runtime:advance(0.001)
	assert(#runtime.fires == firesBeforeState + 1 and independent:GetStatus().pendingKeys == 1,
		"a QueueBusy retry cannot fall back to the 1ms producer interval")
	runtime:advance(1 / 60 - 0.001 - 0.0001)
	assert(#runtime.fires == firesBeforeState + 1,
		"the QueueBusy retry remains queued until its next floored deadline")
	runtime:advance(0.0002)
	assert(#runtime.fires == firesBeforeState + 2 and independent:GetStatus().pendingKeys == 0,
		"the Independent QueueBusy retry eventually hands off the retained value")
	server:Destroy()
end

-- An earlier key expiry only cleans that key; repeated submissions cannot postpone its retained service deadline.
do
	local runtime, server, player, definition = setup(10, 20)
	local firesBeforeState = #runtime.fires
	local state = assert(server:CreateState({ player }, 0.1,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.TextState:Put(1, "Normal", string.rep("x", 40)))
	runtime:advance(0.1)
	assert(state:GetStatus().lastFlush.error.code == "OutboundRateLimited"
		and state:GetStatus().pendingKeys == 1 and #runtime.fires == firesBeforeState,
		"an impossible charge remains queued until its first-dirty expiry")
	runtime:advance(0.85)
	assert(state.events.ReliableState:Put(2, "Normal", 1))
	runtime:advance(0.03)
	assert(state.events.ReliableState:Put(2, "Normal", 2))
	runtime:advance(0.02)
	assert(#runtime.fires == firesBeforeState and state:GetStatus().pendingKeys == 1
		and state:GetStatus().recipients[1].remaining == 1
		and state:GetStatus().lastFlush.report.expired == 1,
		"the old key expiry cleans only that key and keeps the new key pending")
	runtime:advance(0.049)
	assert(#runtime.fires == firesBeforeState and state:GetStatus().pendingKeys == 1,
		"a replacement at 0.98 cannot postpone service to 1.08 or send before 1.05")
	runtime:advance(0.002)
	assert(#runtime.fires == firesBeforeState + 1 and state:GetStatus().pendingKeys == 0
		and state:GetStatus().lastFlush.ok and state:GetStatus().lastFlush.report.logicalHandoffs == 1
		and decodeState(runtime.fires[firesBeforeState + 1].values[2], definition) == 2,
		"the latest surviving value is handed off once at the original 1.05 service deadline")
	server:Destroy()
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

-- Deferred multi-recipient state admits both channels for everyone or debits nobody, then waits for the slowest bucket.
do
	local runtime, server, first = setup(18, 20)
	local second = runtime:addPlayer()
	assert(server.events.Drain:Send(first, 1))
	local firesBeforeState = #runtime.fires
	local chargedBeforeState = server:GetDiagnostics().counters.outboundBytesCharged
	local state = assert(server:CreateState({ first, second }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	local refused = state:GetStatus()
	assert(refused.pendingKeys == 2 and refused.lastFlush.error.code == "OutboundRateLimited"
		and refused.lastFlush.report.selected == 0 and #runtime.fires == firesBeforeState
		and server:GetDiagnostics().counters.outboundBytesCharged == chargedBeforeState,
		"one blocked recipient refuses the whole multi-recipient selection without debiting the affordable peer")
	runtime:advance(0.49)
	assert(#runtime.fires == firesBeforeState, "atomic retry waits for the slowest captured recipient")
	runtime:advance(0.02)
	local delivered = state:GetStatus()
	assert(delivered.pendingKeys == 0 and delivered.lastFlush.ok
		and delivered.lastFlush.report.selected == 2 and delivered.lastFlush.report.reliableHandoffs == 2
		and delivered.lastFlush.report.unreliableHandoffs == 2 and delivered.lastFlush.report.logicalHandoffs == 4
		and #runtime.fires == firesBeforeState + 4
		and server:GetDiagnostics().counters.outboundBytesCharged == chargedBeforeState + 36,
		"atomic retry sends both complete channels to both recipients and charges each exact frame")
	server:Destroy()
end

-- Independent departure drops only that player's pending flags, rejects stale timers, and closes only at an empty audience.
do
	local runtime, server, first = setup(18, 10)
	local second = runtime:addPlayer()
	assert(server.events.Drain:Send(first, 1))
	local firesBeforeState = #runtime.fires
	local state = assert(server:CreateState({ first, second }, 0.05,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	local staleTimer = runtime.timers[#runtime.timers]
	assert(state:GetStatus().pendingKeys == 2 and #runtime.fires == 3 and runtime:activeTimers() == 1)
	runtime:removePlayer(first)
	assert(state:GetStatus().state == "Open" and state:GetStatus().pendingKeys == 0
		and state:GetStatus().pendingBodyBytes == 0 and #state:GetStatus().recipients == 1
		and state:GetStatus().recipients[1].player == second and runtime:activeTimers() == 0,
		"departure removes only that recipient's flags and retains the live lane for its remaining audience")
	staleTimer.callback()
	runtime:advance(2)
	assert(#runtime.fires == 3, "a canceled independent retry cannot send departed or consumed values")
	runtime:removePlayer(second)
	assert(state:GetStatus().state == "Destroyed" and state:GetStatus().activeKeys == 0)
	server:Destroy()
end

-- A partial native failure consumes only attempted recipients and never replays uncertain handoffs.
do
	local runtime, server, first = setup(256, 256)
	local second = runtime:addPlayer()
	local third = runtime:addPlayer()
	local state = assert(server:CreateState({ first, second, third }, 0.05,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime.afterFire = function(player)
		if player == second then error("uncertain native handoff") end
	end
	local ok, issue, report = state:Flush()
	assert(not ok and issue.code == "TransportFailure" and report.selected == 2 and report.remaining == 2
		and report.reliableHandoffs == 1 and report.unreliableHandoffs == 1
		and report.logicalHandoffs == 2 and #runtime.fires == 3
		and server:GetDiagnostics().counters.outboundBytesCharged == 36,
		"a recipient failure preserves earlier successes and leaves the unattempted recipient's exact budget untouched")
	assert(report.recipients[1].selected == 2 and report.recipients[1].remaining == 0
		and report.recipients[2].selected == 2 and report.recipients[2].remaining == 0
		and report.recipients[2].error.code == "TransportFailure"
		and report.recipients[3].selected == 0 and report.recipients[3].remaining == 2,
		"recipient reports distinguish successful, uncertain and unattempted flags")
	runtime.afterFire = nil
	runtime:advance(0.05)
	assert(#runtime.fires == 5 and runtime.fires[1].player == first and runtime.fires[2].player == first
		and runtime.fires[3].player == second and runtime.fires[4].player == third
		and runtime.fires[5].player == third and state:GetStatus().pendingKeys == 0
		and server:GetDiagnostics().counters.outboundBytesCharged == 54,
		"automatic follow-up services only the unattempted recipient without replaying uncertain work")
	server:Destroy()
end

-- Reentrant teardown during a recipient handoff clears pending recipients and prevents further native sends.
do
	local runtime, server, first = setup(32, 32)
	local second = runtime:addPlayer()
	local state = assert(server:CreateState({ first, second }, 0.05,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	runtime.afterFire = function(player)
		if player == first then server:Destroy() end
	end
	local ok, issue, report = state:Flush()
	assert(not ok and issue.code == "Destroyed" and report.selected == 1 and report.remaining == 0
		and #runtime.fires == 1 and state:GetStatus().state == "Destroyed"
		and state:GetStatus().pendingKeys == 0 and runtime:activeTimers() == 0,
		"session teardown during FireClient consumes uncertain work once and releases the remaining audience")
	runtime:advance(2)
	assert(#runtime.fires == 1, "teardown prevents delayed recipient sends")
end

-- Removing a blocker from a deferred atomic audience preserves other recipients and invalidates the old retry callback.
do
	local runtime, server, first = setup(18, 10)
	local second = runtime:addPlayer()
	assert(server.events.Drain:Send(first, 1))
	local firesBeforeState = #runtime.fires
	local chargedBeforeState = server:GetDiagnostics().counters.outboundBytesCharged
	local state = assert(server:CreateState({ first, second }, 0.05, { deferOutbound = true }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	local staleTimer = runtime.timers[#runtime.timers]
	assert(state:GetStatus().pendingKeys == 2 and runtime:activeTimers() == 1)
	runtime:removePlayer(first)
	assert(state:GetStatus().state == "Open" and state:GetStatus().pendingKeys == 2
		and runtime:activeTimers() == 1,
		"a deferred atomic lane prunes one departed player and stays open for its surviving audience")
	staleTimer.callback()
	assert(#runtime.fires == firesBeforeState and runtime:activeTimers() == 1,
		"a canceled slow-recipient retry callback cannot flush the pruned audience")
	runtime:advance(0.049)
	assert(#runtime.fires == firesBeforeState, "the surviving audience still observes the producer interval")
	runtime:advance(0.002)
	assert(state:GetStatus().pendingKeys == 0 and state:GetStatus().lastFlush.ok
		and state:GetStatus().lastFlush.report.selected == 2 and #runtime.fires == firesBeforeState + 2
		and server:GetDiagnostics().counters.outboundBytesCharged == chargedBeforeState + 18,
		"the survivor receives both channels with exact per-player charging")
	runtime:removePlayer(second)
	assert(state:GetStatus().state == "Destroyed" and state:GetStatus().pendingBodyBytes == 0
		and runtime:activeTimers() == 0,
		"the deferred lane closes and releases accounting only after its captured audience is empty")
	server:Destroy()
end

-- Reentrant pruning after a processed recipient's partial selection omits its now-stale cached progress row.
do
	local runtime, server, first = setup(10_000, 10_000)
	local second = runtime:addPlayer()
	local state = assert(server:CreateState({ first, second }, 0.05,
		{ deferOutbound = true, progress = "Independent" }))
	for key = 1, 33 do assert(state.events.ReliableState:Put(key, "Normal", key % 256)) end
	runtime.afterFire = function(player)
		if player == second then
			runtime.afterFire = nil
			runtime:removePlayer(first)
		end
	end
	local ok, _, report = state:Flush()
	assert(ok and report.selected == 32 and report.remaining == 1 and #report.recipients == 1
		and report.recipients[1].player == second and report.recipients[1].selected == 32
		and report.recipients[1].remaining == 1 and state:GetStatus().pendingKeys == 1,
		"a later handoff prunes a processed recipient without reporting stale tail progress or changing the survivor's count")
	local nextOk, _, nextReport = state:Flush()
	assert(nextOk and nextReport.selected == 1 and nextReport.remaining == 0
		and #runtime.fires == 3 and runtime.fires[3].player == second,
		"the surviving recipient's partial-selection tail remains queued exactly once")
	server:Destroy()
end

-- Independent mode advances an affordable peer and replacement re-enables only that key for every captured recipient.
do
	local runtime, server, first = setup(18, 20)
	local second = runtime:addPlayer()
	assert(server.events.Drain:Send(first, 1))
	local firesBeforeState = #runtime.fires
	local chargedBeforeState = server:GetDiagnostics().counters.outboundBytesCharged
	local state = assert(server:CreateState({ first, second }, 0.05,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	local report = state:GetStatus().lastFlush.report
	assert(not state:GetStatus().lastFlush.ok and report.error == nil and report.selected == 2
		and report.remaining == 2 and report.reliableHandoffs == 1 and report.unreliableHandoffs == 1
		and report.logicalHandoffs == 2 and #runtime.fires == firesBeforeState + 2
		and server:GetDiagnostics().counters.outboundBytesCharged == chargedBeforeState + 18,
		"one blocked recipient retains its flags while the affordable peer is charged and sent both channels")
	local firstProgress, secondProgress = report.recipients[1], report.recipients[2]
	assert(table.isfrozen(report.recipients) and table.isfrozen(firstProgress) and table.isfrozen(secondProgress)
		and firstProgress.player == first and firstProgress.selected == 0 and firstProgress.remaining == 2
		and firstProgress.error.code == "OutboundRateLimited"
		and secondProgress.player == second and secondProgress.selected == 2 and secondProgress.remaining == 0
		and secondProgress.reliableHandoffs == 1 and secondProgress.unreliableHandoffs == 1
		and secondProgress.logicalHandoffs == 2 and secondProgress.error == nil,
		"recipient reports separate refused work, retained keys and successful per-player handoffs")
	assert(state:GetStatus().recipients[1].remaining == 2 and state:GetStatus().recipients[2].remaining == 0,
		"GetStatus exposes current bounded per-recipient pending progress")
	runtime:advance(0.1)
	assert(state.events.ReliableState:Put(1, "High", 3))
	assert(state:GetStatus().recipients[1].remaining == 2 and state:GetStatus().recipients[2].remaining == 1,
		"replacing one latest value resets its pending flags for the captured audience")
	runtime:advance(0.34)
	assert(#runtime.fires == firesBeforeState + 2, "neither recipient is serviced before its refill becomes affordable")
	runtime:advance(0.02)
	local partial = state:GetStatus().lastFlush.report
	assert(state:GetStatus().pendingKeys == 2 and partial.selected == 1 and partial.remaining == 2
		and partial.reliableHandoffs == 1 and partial.unreliableHandoffs == 0
		and partial.logicalHandoffs == 1 and #runtime.fires == firesBeforeState + 3
		and runtime.fires[firesBeforeState + 3].player == second
		and server:GetDiagnostics().counters.outboundBytesCharged == chargedBeforeState + 27,
		"the affordable peer receives its replacement while the blocked peer retains both channel flags")
	runtime:advance(0.05)
	local delivered = state:GetStatus().lastFlush.report
	assert(state:GetStatus().pendingKeys == 0 and delivered.selected == 2 and delivered.remaining == 0
		and delivered.reliableHandoffs == 1 and delivered.unreliableHandoffs == 1
		and delivered.logicalHandoffs == 2 and #runtime.fires == firesBeforeState + 5
		and runtime.fires[firesBeforeState + 4].player == first
		and runtime.fires[firesBeforeState + 5].player == first
		and server:GetDiagnostics().counters.outboundBytesCharged == chargedBeforeState + 45,
		"the replacement reaches both recipients for its key while the other channel stays limited to its pending audience")
	server:Destroy()
end

-- Independent replacement preserves first-dirty expiry even when a peer can retry its smaller selected channel first.
do
	local runtime, server, first = setup(18, 10)
	local second = runtime:addPlayer()
	assert(server.events.Drain:Send(first, 1))
	local firesBeforeState = #runtime.fires
	local state = assert(server:CreateState({ first, second }, 0.05,
		{ deferOutbound = true, progress = "Independent" }))
	assert(state.events.ReliableState:Put(1, "Normal", 1))
	assert(state.events.UnreliableState:Put(2, "Normal", 2))
	runtime:advance(0.05)
	runtime:advance(0.89)
	assert(state.events.ReliableState:Put(1, "High", 3))
	runtime:advance(0.049)
	assert(#runtime.fires == firesBeforeState + 2, "replacement does not bypass either recipient's actual byte budget")
	runtime:advance(0.002)
	local partial = state:GetStatus().lastFlush.report
	assert(not state:GetStatus().lastFlush.ok and partial.error == nil
		and partial.selected == 1 and partial.remaining == 2 and #runtime.fires == firesBeforeState + 3
		and partial.recipients[1].error.code == "OutboundRateLimited"
		and partial.recipients[1].remaining == 2
		and partial.recipients[2].selected == 1 and partial.recipients[2].remaining == 0,
		"the affordable peer receives the replacement while the other retains its original age")
	runtime:advance(0.05)
	local expired = state:GetStatus()
	assert(expired.pendingKeys == 0 and expired.pendingBodyBytes == 0
		and expired.lastFlush.report.expired == 2 and #runtime.fires == firesBeforeState + 3
		and runtime:activeTimers() == 0,
		"independent values expire at their original first-dirty deadline instead of gaining a fresh second")
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
