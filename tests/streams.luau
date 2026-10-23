local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local NativeRuntime = require("./support/NativeCodec")
local ServerRuntime = require("./support/ServerRuntime")
local Frame = NativeRuntime.loadFrame()
local OrderedFrame = require("../src/internal/OrderedFrame")

local scope = roblox.Instance.new("Folder")
scope.Parent = NativeRuntime.World
local part = roblox.Instance.new("Part")
part.Parent = scope

local definition, definitionIssue = Definition.define({
	name = "StreamsProof",
	version = 1,
	events = {
		Output = { id = 1, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = { type = "u8" } },
		} },
		Float = { id = 2, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = { type = "f32", minimum = -100, maximum = 100 } },
		} },
		Vector = { id = 3, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = {
				type = "Vector2F32", minimum = -100, maximum = 100,
			} },
		} },
		Array = { id = 4, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = {
				type = "array", maximumLength = 2, element = { type = "u8" },
			} },
		} },
		Reference = { id = 5, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = { type = "Instance", className = "Part" } },
		} },
		Narrow = { id = 6, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1 },
			{ name = "value", type = "optional", value = { type = "u8" } },
		} },
		Positive = { id = 7, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 1, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = { type = "u8" } },
		} },
		Single = { id = 8, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "value", type = "u8" },
		} },
		Regular = { id = 9, direction = "ServerToClient", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = { type = "u8" } },
		} },
	},
})
assert(definition, definitionIssue and definitionIssue.message)
local compiled = assert(Definition.get(definition))

local function sessionOptions()
	return { inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 2048 },
		aggregate = { capacity = 32768, refillPerSecond = 16384 },
	}, instanceRoot = scope }
end

local function setup(value)
	local runtime = ServerRuntime.new()
	local player, other = runtime:addPlayer(), runtime:addPlayer()
	local selectedDefinition = value or definition
	local selectedOptions = sessionOptions()
	if not assert(Definition.get(selectedDefinition)).hasReferences then selectedOptions.instanceRoot = nil end
	local server = assert(runtime.server.create(selectedDefinition, selectedOptions))
	return runtime, player, other, server
end

local function assertCode(expected, result, problem)
	assert((result == nil or result == false) and problem ~= nil and problem.code == expected,
		`expected {expected}, got {if problem then problem.code else "success"}`)
end

local function latest(runtime, eventId, kind)
	for index = #runtime.fires, 1, -1 do
		local fire = runtime.fires[index]
		if fire.values[1] == eventId and (kind == nil or fire.kind == kind) then return fire end
	end
	return nil
end

local function decodeFire(event, fire, referenceRoot)
	local packet = fire.values[2]
	local references = table.create(math.max(0, fire.values.n - 2))
	references.n = math.max(0, fire.values.n - 2)
	for index = 1, references.n do references[index] = fire.values[index + 2] end
	local sidecars = if references.n == 0 then nil else references
	local header = assert(OrderedFrame.peek(event, event.id, packet, sidecars))
	local context = if referenceRoot == nil then nil else { server = true, root = referenceRoot }
	local decode = Frame.compile(OrderedFrame.codecEvent(event), "decode", context)
	local values = if sidecars == nil then table.pack(OrderedFrame.decode(event, packet, header, decode))
		else table.pack(OrderedFrame.decode(event, packet, header, decode, sidecars))
	assert(values[1] == true)
	return packet, header, values
end

do
	local runtime, player, other, server = setup()
	local events = server.events
	assert(events.Output.CreateStream ~= nil and events.Output.CreateBroadcastStream ~= nil)
	assert(events.Regular.CreateStream == nil and events.Single.CreateStream == nil)
	assertCode("NotStarted", events.Output:CreateStream(player, { rate = 10 }))
	assert(server:Start())
	assertCode("InvalidOptions", events.Output:CreateStream(player, nil))
	for _, badOptions in {
		{},
		{ rate = 0.09 },
		{ rate = 10, fastRate = 10 },
		{ rate = 10, keepalive = 0.09 },
		{ rate = 10, epsilon = 1_000_001 },
		{ rate = 10, epsilon = 0.01, extra = true },
	} do
		assertCode("InvalidOptions", events.Output:CreateStream(player, badOptions))
	end
	assertCode("InvalidOptions", events.Output:CreateStream(player, { rate = 10, epsilon = 0.1 }))
	assertCode("InvalidPlayer", events.Output:CreateStream(runtime.newInstance("Player"), { rate = 10 }))
	assertCode("InvalidPlayer", events.Output:CreateStream(nil, { rate = 10 }))
	assert(runtime:activeTimers() == 0 and #runtime.fires == 0,
		"a rejected nil targeted player claims no owner or timer and emits nothing")
	assertCode("InvalidOptions", events.Narrow:CreateStream(player, { rate = 10 }))
	assertCode("InvalidOptions", events.Positive:CreateStream(player, { rate = 10 }))
	local stream = assert(events.Output:CreateStream(player, { rate = 10, fastRate = 20, keepalive = 1 }))
	assert(runtime:activeTimers() == 0, "an Idle stream has no timer")
	assertCode("QueueBusy", events.Output:CreateStream(player, { rate = 10 }))
	local second = assert(events.Output:CreateStream(other, { rate = 10 }))
	assertCode("QueueBusy", events.Output:CreateBroadcastStream({ rate = 10 }))
	assertCode("InvalidPayload", stream:Set(nil))
	assertCode("InvalidPayload", stream:Set(256))
	assert(stream:GetStatus().state == "Idle" and runtime:activeTimers() == 0,
		"a rejected Set leaves the Idle handle and schedule unchanged")
	assert(stream:Set(7))
	assert(stream:GetStatus().pending and runtime:activeTimers() == 1)
	stream:Destroy()
	assert(stream:GetStatus().state == "Destroyed" and runtime:activeTimers() == 0)
	assert(second:GetStatus().state == "Idle")
	runtime:removePlayer(other)
	assert(second:GetStatus().state == "Destroyed", "PlayerRemoving releases a targeted owner")
	local replacement = assert(events.Output:CreateBroadcastStream({ rate = 10 }))
	replacement:Destroy()
	server:Destroy()
end

do
	local runtime, player, other, server = setup()
	assert(server:Start())
	local event = server.events.Output
	local handles = {
		assert(event:CreateStream(player, { rate = 10 })),
		assert(event:CreateStream(other, { rate = 10 })),
	}
	for _ = 1, 62 do
		handles[#handles + 1] = assert(event:CreateStream(runtime:addPlayer(), { rate = 10 }))
	end
	local overflow = runtime:addPlayer()
	assertCode("QueueLimit", event:CreateStream(overflow, { rate = 10 }))
	handles[1]:Destroy()
	assert(event:CreateStream(overflow, { rate = 10 }))
	server:Destroy()
end

do
	local runtime, _, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Array:CreateBroadcastStream({ rate = 10, keepalive = 0.5 }))
	local callerValue = { 7, 8 }
	assert(stream:Set(callerValue))
	callerValue[1] = 99
	assert(runtime:activeTimers() == 1)
	runtime:advance(0)
	local fire = assert(latest(runtime, compiled.events.Array.id, "broadcast"))
	local _, _, values = decodeFire(compiled.events.Array, fire)
	assert(values[2] == runtime.serverTime - runtime.now and values[3][1] == 7 and values[3][2] == 8,
		"Set owns its encoded composite snapshot and stamps synchronized server time")
	assert(stream:GetStatus().pending, "a changed handoff arms one stop confirmation")
	assert(stream:Set({ 7, 8 }))
	runtime:advance(0.1)
	assert(#runtime.fires == 2 and stream:GetStatus().pending == false,
		"the stop confirmation sends once and identical state suppresses further rate sends")
	runtime:advance(0.49)
	assert(#runtime.fires == 2)
	runtime:advance(0.01)
	assert(#runtime.fires == 3, "keepalive sends unchanged state at its deadline")
	assert(stream:Clear())
	runtime:advance(0.1)
	local clear = assert(latest(runtime, compiled.events.Array.id, "broadcast"))
	local _, _, clearValues = decodeFire(compiled.events.Array, clear)
	assert(clearValues[3] == nil and stream:GetStatus().state == "Idle"
		and runtime:activeTimers() == 0, "Clear hands off explicit nil and returns to Idle")
	local idle = assert(server.events.Output:CreateBroadcastStream({ rate = 10 }))
	assert(idle:Clear())
	runtime:advance(0)
	local idleClear = assert(latest(runtime, compiled.events.Output.id, "broadcast"))
	local _, _, idleValues = decodeFire(compiled.events.Output, idleClear)
	assert(idleValues[3] == nil and idle:GetStatus().state == "Idle", "Idle Clear is sent explicitly")
	server:Destroy()
end

do
	local runtime, _, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Output:CreateBroadcastStream({ rate = 10, fastRate = 20, keepalive = 1 }))
	assert(stream:Urgent() and runtime:activeTimers() == 0, "Urgent is a no-op while Idle")
	assert(stream:Set(3))
	assert(stream:Urgent() and stream:Urgent() and runtime:activeTimers() == 1,
		"repeated Urgent requests coalesce into one next-step timer")
	runtime:advance(5)
	assert(#runtime.fires == 1 and runtime:activeTimers() == 1,
		"a hitch sends once and schedules from the current monotonic time")
	assert(stream:SetFast(true) and stream:GetStatus().fast)
	assert(stream:Urgent())
	runtime:advance(0.05)
	assert(#runtime.fires == 2, "fast cadence brings a pending stop confirmation forward")
	assert(stream:SetFast(false) and not stream:GetStatus().fast)
	local plain = assert(server.events.Float:CreateBroadcastStream({ rate = 10 }))
	assertCode("InvalidOptions", plain:SetFast(true))
	server:Destroy()
end

do
	local runtime, _, _, server = setup()
	assert(server:Start())
	local clearStream = assert(server.events.Output:CreateBroadcastStream({ rate = 0.1, fastRate = 0.2 }))
	assert(clearStream:Set(1))
	runtime:advance(0)
	assert(#runtime.fires == 1)
	assert(clearStream:SetFast(true))
	assert(clearStream:Clear() and clearStream:Clear())
	local clearDeadline = runtime.timers[#runtime.timers].deadline
	assert(clearStream:SetFast(false) and runtime:activeTimers() == 1
		and runtime.timers[#runtime.timers].deadline == clearDeadline)
	runtime:advance(0.1)
	local clearFire = assert(latest(runtime, compiled.events.Output.id, "broadcast"))
	local _, _, clearValues = decodeFire(compiled.events.Output, clearFire)
	assert(#runtime.fires == 2 and clearValues[3] == nil and clearStream:GetStatus().state == "Idle",
		"Clear coalesces at the next step after a handoff, even when normal rate is restored")

	local urgentStream = assert(server.events.Float:CreateBroadcastStream({ rate = 0.1, fastRate = 0.2 }))
	assert(urgentStream:Set(2))
	runtime:advance(0)
	assert(#runtime.fires == 3)
	assert(urgentStream:SetFast(true))
	assert(urgentStream:Urgent() and urgentStream:Urgent())
	local urgentDeadline = runtime.timers[#runtime.timers].deadline
	assert(urgentStream:SetFast(false) and runtime:activeTimers() == 1
		and runtime.timers[#runtime.timers].deadline == urgentDeadline)
	runtime:advance(0.1)
	assert(#runtime.fires == 4, "Urgent coalesces at the next step after a handoff")
	server:Destroy()
end

do
	local runtime, _, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Output:CreateBroadcastStream({ rate = 1, fastRate = 10, keepalive = 5 }))
	assert(stream:Set(1))
	runtime:advance(0)
	assert(stream:SetFast(true) and stream:Set(2))
	runtime:advance(0.1)
	assert(#runtime.fires == 2 and stream:GetStatus().pending)
	assert(stream:SetFast(false))
	runtime:advance(0.1)
	assert(#runtime.fires == 2, "restoring normal rate moves a rate-driven timer later")
	runtime:advance(0.89)
	assert(#runtime.fires == 2)
	runtime:advance(0.01)
	assert(#runtime.fires == 3, "the stop confirmation follows the restored normal interval")

	local first = assert(server.events.Float:CreateBroadcastStream({ rate = 1, fastRate = 10 }))
	assert(first:Set(3) and first:SetFast(true) and first:SetFast(false))
	runtime:advance(0)
	assert(#runtime.fires == 4, "changing rate before the first Set callback preserves its immediate deadline")
	server:Destroy()
end

do
	local runtime, _, _, server = setup()
	assert(server:Start())
	local scalar = assert(server.events.Float:CreateBroadcastStream({ rate = 10, keepalive = 1, epsilon = 0.1 }))
	assert(scalar:Set(1))
	runtime:advance(0)
	runtime:advance(0.1)
	assert(scalar:Set(1.05))
	runtime:advance(0.1)
	assert(#runtime.fires == 2, "positive epsilon compares normalized scalar payloads")
	local vector = assert(server.events.Vector:CreateBroadcastStream({ rate = 10, epsilon = 0.1 }))
	assert(vector:Set(roblox.Vector2.new(2, 3)))
	runtime:advance(0)
	runtime:advance(0.1)
	assert(vector:Set(roblox.Vector2.new(2.05, 3.05)))
	runtime:advance(0.1)
	assert(#runtime.fires == 4, "positive epsilon compares vector components")
	server:Destroy()
end

do
	local runtime, player, _, server = setup()
	assert(server:Start())
	runtime.failServerTime = true
	assertCode("InvalidOptions", server.events.Output:CreateStream(player, { rate = 10 }))
	runtime.failServerTime = false
	local stream = assert(server.events.Output:CreateStream(player, { rate = 10 }))
	assert(stream:Set(1))
	runtime.failServerTime = true
	runtime:advance(0)
	assert(#runtime.fires == 0 and stream:GetStatus().state == "Paused"
		and stream:GetStatus().lastError.code == "InvalidPayload",
		"a synchronized clock failure pauses without emitting or consuming a sequence")
	runtime.failServerTime = false
	assert(stream:Set(2))
	runtime:advance(0)
	local fire = assert(latest(runtime, compiled.events.Output.id, "target"))
	local _, header, values = decodeFire(compiled.events.Output, fire)
	assert(header.sequence == 1 and values[3] == 2)
	server:Destroy()
end

do
	local budgetDefinition = assert(Definition.define({
		name = "StreamBudgetProof", version = 1, outboundBytes = { capacity = 21, refillPerSecond = 0.1 },
		events = { Output = { id = 1, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
			{ name = "time", type = "f64", minimum = 0, maximum = 1_000_000_000_000 },
			{ name = "value", type = "optional", value = { type = "u8" } },
		} } },
	}))
	local runtime, player, _, server = setup(budgetDefinition)
	assert(server:Start())
	local stream = assert(server.events.Output:CreateStream(player, { rate = 1, fastRate = 10 }))
	assert(stream:Set(1))
	runtime:advance(0)
	assert(#runtime.fires == 1 and server:GetDiagnostics().counters.outboundBytesCharged == 21)
	local firstTime = stream:GetStatus().lastSentTime
	assert(stream:SetFast(true))
	runtime:advance(0.1)
	assert(#runtime.fires == 1 and stream:GetStatus().lastSentTime == firstTime
		and stream:GetStatus().lastError.code == "OutboundRateLimited" and stream:GetStatus().pending,
		"budget refusal does not claim delivery and retries at the configured cadence")
	assert(stream:SetFast(false))
	local retryTimer = runtime.timers[#runtime.timers]
	local cancelledTimers = runtime.cancelledTimers
	assert(stream:Urgent() and stream:Urgent() and runtime:activeTimers() == 1
		and runtime.timers[#runtime.timers] == retryTimer and runtime.cancelledTimers == cancelledTimers
		and #runtime.fires == 1 and server:GetDiagnostics().counters.outboundByteRejected == 1
		and server:GetDiagnostics().counters.outboundBytesCharged == 21,
		"repeated Urgent preserves the same rate-limit retry timer without another handoff or charge")
	runtime:advance(0.1)
	assert(#runtime.fires == 1 and server:GetDiagnostics().counters.outboundByteRejected == 1,
		"automatic budget retry follows the restored selected cadence")
	runtime:advance(0.89)
	assert(server:GetDiagnostics().counters.outboundByteRejected == 1)
	runtime:advance(0.01)
	assert(server:GetDiagnostics().counters.outboundByteRejected == 2)
	runtime:advance(210)
	local delivered = assert(latest(runtime, compiled.events.Output.id, "target"))
	local _, header = decodeFire(compiled.events.Output, delivered)
	assert(#runtime.fires == 2 and stream:GetStatus().lastError == nil and header.sequence == 2,
		"budget refusals do not commit an ordered sequence")
	server:Destroy()
end

do
	local runtime, player, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Output:CreateStream(player, { rate = 10 }))
	runtime.throwFire = true
	assert(stream:Set(4))
	runtime:advance(0)
	assert(stream:GetStatus().state == "Paused" and stream:GetStatus().lastError.code == "TransportFailure"
		and runtime:activeTimers() == 0)
	runtime.throwFire = false
	assert(stream:Urgent())
	runtime:advance(10)
	assert(#runtime.fires == 0 and stream:GetStatus().state == "Paused",
		"Urgent does not replay an uncertain transport failure")
	assert(stream:Set(5))
	runtime:advance(0)
	assert(#runtime.fires == 1 and stream:GetStatus().state == "Active")
	runtime.throwFire = true
	runtime:advance(0.1)
	assert(stream:GetStatus().state == "Paused" and #runtime.fires == 1)
	runtime.throwFire = false
	assert(stream:Set(5), "Set is a fresh submission from Paused, even when it matches the last handoff")
	runtime:advance(0.1)
	assert(#runtime.fires == 2 and stream:GetStatus().state == "Active")
	runtime.throwFire = true
	assert(stream:Set(6))
	runtime:advance(0.1)
	assert(#runtime.fires == 2 and stream:GetStatus().state == "Paused")
	runtime.throwFire = false
	assert(stream:Clear(), "Clear is a fresh explicit nil submission from Paused")
	runtime:advance(0.1)
	local clearFire = assert(latest(runtime, compiled.events.Output.id, "target"))
	local _, _, clearValues = decodeFire(compiled.events.Output, clearFire)
	assert(#runtime.fires == 3 and clearValues[3] == nil and stream:GetStatus().state == "Idle",
		"Clear replaces uncertain paused state and completes without replaying it")
	server:Destroy()
end

do
	local runtime, player, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Output:CreateStream(player, { rate = 10 }))
	assert(stream:Set(9))
	runtime.serverTime = 1_000_000_000_001
	runtime:advance(0)
	assert(#runtime.fires == 0 and stream:GetStatus().state == "Paused"
		and stream:GetStatus().lastError.code == "InvalidPayload", "expired authored timestamp bounds pause before handoff")
	runtime.serverTime = 999_999_999_999
	assert(stream:Set(10))
	runtime:advance(0.1)
	local fire = assert(latest(runtime, compiled.events.Output.id, "target"))
	local _, header, values = decodeFire(compiled.events.Output, fire)
	assert(header.sequence == 1 and values[3] == 10,
		"a rejected timestamp neither advances ordered sequence nor records delivery")
	server:Destroy()
end

do
	local runtime, player, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Reference:CreateStream(player, { rate = 10 }))
	assert(stream:Set(part))
	runtime:advance(0)
	local fire = assert(latest(runtime, compiled.events.Reference.id, "target"))
	local packet, header, values = decodeFire(compiled.events.Reference, fire, scope)
	assert(header.format == 6 and fire.values[3] == part and values[3] == part
		and buffer.readf64(packet, 12) == runtime.serverTime,
		"reference-format stream stamps after its four-byte codec header")
	part.Parent = NativeRuntime.World
	runtime:advance(0.1)
	assert(#runtime.fires == 1 and stream:GetStatus().state == "Paused"
		and stream:GetStatus().lastError.code == "InvalidPayload",
		"scope mutation is rejected before a native handoff")
	part.Parent = scope
	assert(stream:Set(part))
	runtime:advance(0.1)
	assert(#runtime.fires == 2, "a fresh explicit Set resumes after scope repair")
	server:Destroy()
end

do
	local runtime, player, _, server = setup()
	assert(server:Start())
	local stream = assert(server.events.Output:CreateStream(player, { rate = 10 }))
	assert(stream:Set(2))
	player.Parent = nil
	runtime:advance(0)
	assert(#runtime.fires == 0 and stream:GetStatus().state == "Destroyed"
		and stream:GetStatus().lastError.code == "InvalidPlayer",
		"targeted handoff preflights deparented players without outbound-byte policy")
	local reentrant = assert(server.events.Output:CreateBroadcastStream({ rate = 10 }))
	local replaced = false
	runtime.afterBroadcast = function(remote, eventId)
		if not replaced and remote.Name == "Unreliable" and eventId == compiled.events.Output.id then
			replaced = true
			assert(reentrant:Set(9))
		end
	end
	assert(reentrant:Set(8))
	runtime:advance(0)
	assert(reentrant:GetStatus().state == "Active" and reentrant:GetStatus().pending
		and runtime:activeTimers() == 1, "reentrant Set remains pending after the older handoff")
	runtime:advance(0.1)
	local latestFire = assert(latest(runtime, compiled.events.Output.id, "broadcast"))
	local _, _, latestValues = decodeFire(compiled.events.Output, latestFire)
	assert(latestValues[3] == 9, "the older handoff does not mark a newer state delivered")
	reentrant:Destroy()
	local doomed = assert(server.events.Output:CreateBroadcastStream({ rate = 10 }))
	runtime.afterBroadcast = function(remote, eventId)
		if remote.Name == "Unreliable" and eventId == compiled.events.Output.id then doomed:Destroy() end
	end
	assert(doomed:Set(10))
	runtime:advance(0)
	assert(doomed:GetStatus().state == "Destroyed" and runtime:activeTimers() == 0,
		"reentrant Destroy cannot be resurrected after handoff")
	server:Destroy()
end

print("PASS Relay.Streams")
