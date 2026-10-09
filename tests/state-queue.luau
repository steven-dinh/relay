local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Relay = require("../src")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		require = function(path)
			assert(path == "./CompositeCodec")
			return CompositeCodec
		end,
	},
	injectGlobals = true,
})()

local schema = Relay.schema
local bigFields = {}
for index = 1, 7 do bigFields[index] = schema.field(`part{index}`, schema.string(1_024)) end
bigFields[8] = schema.field("last", schema.string(1_000))
local token, definitionProblem = Relay.define({
	name = "StateQueueTest",
	version = 1,
	events = {
		Value = {
			id = 1,
			direction = "ServerToClient",
			queue = "State",
			fields = schema.ordered(schema.field("value", schema.u32())),
		},
		Optional = {
			id = 2,
			direction = "ServerToClient",
			queue = "State",
			fields = schema.ordered(schema.field("value", schema.optional(schema.string(1_024)))),
		},
		Unreliable = {
			id = 3,
			direction = "ServerToClient",
			delivery = "Unreliable",
			queue = "State",
			fields = schema.ordered(schema.field("value", schema.boolean())),
		},
		Medium = {
			id = 4,
			direction = "ServerToClient",
			queue = "State",
			fields = schema.ordered(
				schema.field("a", schema.string(1_024)),
				schema.field("b", schema.string(1_024)),
				schema.field("c", schema.string(1_024)),
				schema.field("d", schema.string(1_024))
			),
		},
		Nested = {
			id = 5,
			direction = "ServerToClient",
			queue = "State",
			fields = schema.ordered(schema.field("value", schema.struct(schema.field("count", schema.u8())))),
		},
		Big = {
			id = 6,
			direction = "ServerToClient",
			queue = "State",
			fields = schema.ordered(table.unpack(bigFields)),
		},
		Input = {
			id = 7,
			direction = "ClientToServer",
			queue = "State",
			fields = schema.ordered(schema.field("value", schema.u16())),
		},
		FifoOnly = {
			id = 8,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(schema.field("value", schema.boolean())),
		},
		Tiny = {
			id = 9,
			direction = "ServerToClient",
			queue = "State",
			fields = schema.ordered(schema.field("value", schema.boolean())),
		},
	},
})
assert(token, definitionProblem and definitionProblem.message)
local compiled = assert(Definition.get(token))

local function newFixture(direction)
	local runtime = { now = 0, timers = {}, fires = {}, onHandoff = nil }
	local scheduler = {
		delay = function(seconds, callback)
			local timer = { deadline = runtime.now + seconds, callback = callback, cancelled = false, fired = false }
			table.insert(runtime.timers, timer)
			return timer
		end,
		cancel = function(timer) timer.cancelled = true end,
	}
	local StateQueue = luau.load(fs.readFile("src/internal/StateQueue.luau"), {
		debugName = "StateQueue",
		injectGlobals = true,
		environment = {
			task = scheduler,
			require = function(path)
				if path == "../Definition" then return Definition end
				assert(path == "./BatchFrame")
				return BatchFrame
			end,
		},
	})()
	local events = {}
	for name, event in compiled.events do
		if event.direction == direction then
			local queued = compiled.queuedById[event.id]
			if queued ~= nil then
				events[name] = {
					id = queued.id,
					delivery = queued.delivery,
					queue = queued.queue,
					encode = Frame.compile(queued, "encode"),
				}
			end
		end
	end
	local owner = { alive = true, terminalError = nil, events = events, flushOwner = nil }
	function owner.check()
		return owner.alive, if owner.alive then nil else owner.terminalError or Definition.error("Destroyed")
	end
	function owner.now() return runtime.now end
	function owner.handoff(delivery, packet, audience)
		table.insert(runtime.fires, { delivery = delivery, packet = packet, audience = audience })
		if runtime.onHandoff then return runtime.onHandoff(delivery, packet, audience) end
		return true, nil, if audience == nil then 1 else #audience
	end
	function runtime:activeTimers()
		local count = 0
		for _, timer in self.timers do
			if not timer.cancelled and not timer.fired then count += 1 end
		end
		return count
	end
	function runtime:fire(timer)
		if timer.fired then return end
		timer.fired = true
		if not timer.cancelled then timer.callback() end
	end
	function runtime:fireStale(timer)
		timer.fired = true
		timer.callback()
	end
	local definitions = {}
	for _, event in compiled.queuedById do definitions[event.id] = event end
	return StateQueue, runtime, owner, definitions
end

local function audience()
	return { { Name = "A" }, { Name = "B" }, { Name = "C" } }
end

local function create(StateQueue, owner, recipients, delay)
	local handle, problem = StateQueue.create(owner, recipients, delay or 0.02)
	assert(handle, problem and problem.message)
	return handle
end

local function read(packet, limit, definitions)
	local header = assert(BatchFrame.header(packet, limit))
	assert(header.kind == 2)
	local rows = assert(BatchFrame.scan(packet, header, function(id) return definitions[id] end))
	local values = {}
	for index, row in rows do
		local body = assert(BatchFrame.readBody(packet, row))
		local decode = Frame.compile(row.event, "decode")
		local ok, value = decode(body)
		assert(ok)
		values[index] = { id = row.event.id, value = value }
	end
	return values
end

local StateQueue, runtime, owner, definitions = newFixture("ServerToClient")
local audienceSnapshot = audience()
local state = create(StateQueue, owner, audienceSnapshot)
local firstTimer
assert(state.events.Optional:Put(1, "Normal", "older"))
runtime.now = 0.01
assert(state.events.Value:Put(8, "Normal", 80))
firstTimer = runtime.timers[#runtime.timers]
assert(state.events.Value:Put(2, "Normal", 20))
assert(runtime:activeTimers() == 1 and firstTimer.deadline == 0.02,
	"later keys do not extend the lane's first pending deadline")
assert(state.events.Value:Put(9, "High", 90))
assert(state.events.Unreliable:Put(1, "Low", true))
local status = state:GetStatus()
assert(table.isfrozen(status) and status.state == "Open" and status.activeKeys == 5
	and status.pendingKeys == 5 and status.pendingBodyBytes > 0 and table.isfrozen(state:GetStatus()))
local ok, problem, report = state:Flush()

assert(ok and problem == nil and table.isfrozen(report) and report.selected == 5 and report.remaining == 0
	and report.expired == 0 and report.reliableHandoffs == 3 and report.unreliableHandoffs == 3
	and report.logicalHandoffs == 15, "flush report counts actual audience handoffs times records")
assert(#runtime.fires == 2 and runtime.fires[1].delivery == "Reliable"
	and runtime.fires[2].delivery == "Unreliable")
local values = read(runtime.fires[1].packet, 8_192, definitions)
assert(#values == 4 and values[1].id == 1 and values[1].value == 90
	and values[2].id == 2 and values[2].value == "older"
	and values[3].id == 1 and values[3].value == 20
	and values[4].id == 1 and values[4].value == 80,
	"priority then first-dirty time, event ID, and numeric key give deterministic order")
local unreliableValues = read(runtime.fires[2].packet, 900, definitions)
assert(unreliableValues[1].id == 3 and unreliableValues[1].value == true)
assert(state:GetStatus().activeKeys == 5 and state:GetStatus().pendingKeys == 0
	and state:GetStatus().pendingBodyBytes == 0, "clean active keys remain reusable after handoff")

local badKey, badKeyProblem = state.events.Value:Put(-1, "High", 1)
local fractionalKey, fractionalProblem = state.events.Value:Put(1.5, "High", 1)
local badPriority, priorityProblem = state.events.Value:Put(4, "Urgent", 1)
assert(not badKey and badKeyProblem.code == "InvalidStateKey"
	and not fractionalKey and fractionalProblem.code == "InvalidStateKey"
	and not badPriority and priorityProblem.code == "InvalidPriority")
local invalid, invalidProblem = state.events.Value:Put(4, "High", "bad")
assert(not invalid and invalidProblem.code == "InvalidPayload" and runtime:activeTimers() == 0)

local input = { count = 17 }
assert(state.events.Nested:Put(10, "Normal", input))
input.count = 91
local ownedOk = state:Flush()
assert(ownedOk)
local nested = read(runtime.fires[#runtime.fires].packet, 8_192, definitions)
assert(nested[1].value.count == 17, "Put retains only its owned encoded snapshot")
local identityState = create(StateQueue, owner, nil)
assert(identityState.events.Value:Put(0, "Normal", 0))
assert(identityState.events.Optional:Put(0, "Normal", nil))
assert(identityState:GetStatus().activeKeys == 2, "event ID distinguishes equal numeric keys")
identityState:Destroy()
state:Destroy()

local capacityState = create(StateQueue, owner, nil)
local big = table.create(8, string.rep("b", 1_024))
for index = 1, 7 do big[index] = string.rep("b", 1_024) end
big[8] = string.rep("z", 999)
assert(capacityState.events.Big:Put(1, "Low", table.unpack(big)))
assert(capacityState.events.Big:Put(2, "Low", table.unpack(big)))
assert(capacityState.events.Unreliable:Put(1, "Low", true))
assert(capacityState.events.Optional:Put(1, "Normal", nil))
assert(capacityState.events.Tiny:Put(1, "High", true))
local fullStatus = capacityState:GetStatus()
local capacityTimer = runtime.timers[#runtime.timers]
assert(fullStatus.pendingBodyBytes == 16_384, "all lanes share the exact session byte ceiling")
local replacement, replacementProblem = capacityState.events.Optional:Put(1, "High", "a")
assert(not replacement and replacementProblem.code == "QueueFull"
	and capacityState:GetStatus().pendingBodyBytes == fullStatus.pendingBodyBytes
	and runtime:activeTimers() == 1 and not capacityTimer.cancelled,
	"byte overflow preserves the old snapshot, priority, and timer")
local fullOk, _, fullReport = capacityState:Flush()
assert(fullOk and fullReport.selected == 3 and fullReport.remaining == 2)
local fullValues = read(runtime.fires[#runtime.fires - 1].packet, 8_192, definitions)
assert(fullValues[1].id == 9 and fullValues[2].id == 2,
	"failed replacement leaves its previous Normal priority intact")
capacityState:Destroy()

local packingState = create(StateQueue, owner, nil)
local medium = table.create(4, string.rep("m", 1_024))
for index = 1, 4 do medium[index] = string.rep("m", 1_024) end
assert(packingState.events.Medium:Put(1, "High", table.unpack(medium)))
assert(packingState.events.Medium:Put(2, "Normal", table.unpack(medium)))
assert(packingState.events.Value:Put(3, "Low", 3))
assert(packingState.events.Value:Put(4, "Low", 4))
local packingOk, _, packingReport = packingState:Flush()
assert(packingOk and packingReport.selected == 3 and packingReport.remaining == 1)
local packingRows = read(runtime.fires[#runtime.fires].packet, 8_192, definitions)
assert(#packingRows == 3 and packingRows[1].id == 4 and packingRows[2].id == 1
	and packingRows[3].id == 1,
	"greedy priority packing skips a non-fitting record and admits a later small body")
packingState:Destroy()

local expiryState = create(StateQueue, owner, nil)
assert(expiryState.events.Value:Put(1, "Low", 11))
local expiryTimer = runtime.timers[#runtime.timers]
runtime.now = 0.4
assert(expiryState.events.Value:Put(1, "High", 12))
assert(runtime.timers[#runtime.timers] == expiryTimer and not expiryTimer.cancelled,
	"replacement preserves first-dirty timer")
runtime.now = 0.8
assert(expiryState.events.Value:Put(1, "Low", 14))
assert(runtime.timers[#runtime.timers] == expiryTimer and not expiryTimer.cancelled,
	"continuous replacement still preserves first-dirty age")
runtime.now = 1.01
local beforeFailedPut = expiryState:GetStatus().pendingBodyBytes
local failedReplacement, failedReplacementProblem = expiryState.events.Value:Put(1, "High", "bad")
assert(not failedReplacement and failedReplacementProblem.code == "InvalidPayload"
	and expiryState:GetStatus().pendingKeys == 1
	and expiryState:GetStatus().pendingBodyBytes == beforeFailedPut and not expiryTimer.cancelled,
	"failed Put leaves expired work and its timer for ordinary service")
assert(expiryState.events.Value:Put(1, "Normal", 13))
local replacementTimer = runtime.timers[#runtime.timers]
assert(expiryTimer.cancelled and replacementTimer.deadline == 1.03
	and expiryState:GetStatus().pendingKeys == 1,
	"a valid post-expiry replacement starts a new dirty interval")
runtime.now = 2.0
local expireOk, _, expireReport = expiryState:Flush()
assert(expireOk and expireReport.expired == 0 and expireReport.selected == 1,
	"the fresh replacement remains younger than its new one-second expiry")
assert(expiryState.events.Value:Put(2, "Low", 22))
runtime.now = 3.0
local agedOk, _, agedReport = expiryState:Flush()
assert(agedOk and agedReport.expired == 1 and agedReport.selected == 0
	and expiryState:GetStatus().activeKeys == 2 and expiryState:GetStatus().pendingKeys == 0,
	"a serviced one-second expiry releases the body but retains the active key")
expiryState:Destroy()

local timerState = create(StateQueue, owner, nil, 0.05)
assert(timerState.events.Value:Put(5, "Normal", 5))
local timer = runtime.timers[#runtime.timers]
runtime.now = timer.deadline - 0.01
runtime:fire(timer)
assert(runtime:activeTimers() == 1 and runtime.timers[#runtime.timers].deadline == timer.deadline,
	"an early callback rearms only the remaining interval")
local busyTimer = runtime.timers[#runtime.timers]
owner.flushOwner = {}
local manualBusy, manualBusyProblem, manualBusyReport = timerState:Flush()
local removedWhileBusy, removeBusyProblem = timerState.events.Value:Remove(5)
assert(not manualBusy and manualBusyProblem.code == "QueueBusy" and manualBusyReport.remaining == 1
	and not removedWhileBusy and removeBusyProblem.code == "QueueBusy"
	and not busyTimer.cancelled and timerState:GetStatus().lastFlush == nil,
	"manual busy Flush and Remove preserve pending work, deadline, timer, and result")
runtime.now = busyTimer.deadline
runtime:fire(busyTimer)
local busyRearm = runtime.timers[#runtime.timers]
assert(runtime:activeTimers() == 1 and busyRearm.deadline == runtime.now + 0.05,
	"automatic QueueBusy owns one positive delayed rearm")
runtime:fireStale(busyTimer)
assert(runtime:activeTimers() == 1, "stale timer callbacks cannot multiply service")
owner.flushOwner = nil
runtime.now = busyRearm.deadline
runtime:fire(busyRearm)
assert(runtime:activeTimers() == 0 and timerState:GetStatus().lastFlush.ok,
	"the single rearmed timer flushes after the shared guard releases")
timerState:Destroy()

local removeState = create(StateQueue, owner, nil)
assert(removeState.events.Value:Put(1, "Normal", 1))
assert(removeState:GetStatus().activeKeys == 1 and removeState:GetStatus().pendingKeys == 1)
assert(removeState.events.Value:Remove(1))
assert(removeState:GetStatus().activeKeys == 0 and removeState:GetStatus().pendingBodyBytes == 0
	and runtime:activeTimers() == 0, "Remove releases both slot and pending body")
assert(removeState.events.Value:Remove(1), "removing an absent key succeeds")
assert(removeState.events.Value:Put(1, "High", 2) and removeState:GetStatus().activeKeys == 1,
	"a removed key begins a clean reusable slot")
removeState:Destroy()

local lanes = { create(StateQueue, owner, nil), create(StateQueue, owner, nil),
	create(StateQueue, owner, nil), create(StateQueue, owner, nil) }
local fifthLane, fifthLaneProblem = StateQueue.create(owner, nil, 0.02)
assert(fifthLane == nil and fifthLaneProblem.code == "QueueLimit")
for _, lane in lanes do
	for key = 1, 16 do assert(lane.events.Value:Put(key, "Low", key)) end
	assert(lane:Flush())
end
assert(owner.stateKeys == 64 and owner.stateBytes == 0, "the active-key cap is shared across four lanes")
local sixtyFifth, sixtyFifthProblem = lanes[1].events.Value:Put(17, "Low", 17)
assert(not sixtyFifth and sixtyFifthProblem.code == "QueueLimit")
local sameKeyDifferentEvent, differentEventProblem = lanes[1].events.Optional:Put(1, "Normal", nil)
assert(not sameKeyDifferentEvent and differentEventProblem.code == "QueueLimit")
for _, lane in lanes do lane:Destroy() end

local partialState = create(StateQueue, owner, audience())
assert(partialState.events.Value:Put(1, "High", 1))
assert(partialState.events.Unreliable:Put(2, "Low", true))
runtime.onHandoff = function(delivery)
	if delivery == "Reliable" then
		local putOk, putProblem = partialState.events.Value:Put(3, "High", 3)
		local removeOk, removeProblem = partialState.events.Value:Remove(1)
		local nestedOk, nestedProblem = partialState:Flush()
		assert(not putOk and putProblem.code == "QueueBusy"
			and not removeOk and removeProblem.code == "QueueBusy"
			and not nestedOk and nestedProblem.code == "QueueBusy"
			and partialState:GetStatus().state == "Flushing",
			"reentrant state mutation and Flush share the session guard")
		return true, nil, 2
	end
	return false, Definition.error("TransportFailure"), 1
end
local partialOk, partialProblem, partialReport = partialState:Flush()
assert(not partialOk and partialProblem.code == "TransportFailure"
	and partialReport.reliableHandoffs == 2 and partialReport.unreliableHandoffs == 1
	and partialReport.logicalHandoffs == 3 and partialReport.selected == 2
	and partialState:GetStatus().lastFlush.error.code == "TransportFailure",
	"partial transport failure retains prior actual handoff counts and is not retried")
local priorFires = #runtime.fires
assert(partialState:Flush() and #runtime.fires == priorFires, "selected state is consumed exactly once")
runtime.onHandoff = nil
partialState:Destroy()

local pruneAudience = audience()
local pruneState = create(StateQueue, owner, pruneAudience)
local remainingPlayer = pruneAudience[3]
assert(pruneState.events.Value:Put(1, "Normal", 1))
StateQueue.prune(owner, pruneAudience[2])
assert(#owner.states[#owner.states].audience == 2 and owner.states[#owner.states].audience[2] == remainingPlayer)
assert(pruneState:Flush() and runtime.fires[#runtime.fires].audience[2] == remainingPlayer,
	"audience pruning removes departed identities in place")
pruneState:Destroy()

local destroyState = create(StateQueue, owner, audience())
assert(destroyState.events.Value:Put(1, "High", 1))
assert(destroyState.events.Unreliable:Put(2, "Low", true))
runtime.onHandoff = function(delivery)
	if delivery == "Reliable" then
		destroyState:Destroy()
		assert(owner.flushOwner == nil and #owner.states == 0 and owner.stateKeys == 0 and owner.stateBytes == 0,
			"Destroy releases shared guard and lane ownership synchronously")
		return true, nil, 1
	end
	return true, nil, 3
end
local destroyFires = #runtime.fires
local destroyOk, destroyProblem, destroyReport = destroyState:Flush()
assert(not destroyOk and destroyProblem.code == "QueueClosed" and destroyReport.reliableHandoffs == 1
	and destroyReport.unreliableHandoffs == 0 and #runtime.fires == destroyFires + 1
	and destroyState:GetStatus().state == "Destroyed" and destroyState:GetStatus().activeKeys == 0,
	"reentrant Destroy prevents later channel handoff and cannot revive the lane")
runtime.onHandoff = nil

local cleanupState = create(StateQueue, owner, audience())
assert(cleanupState.events.Value:Put(1, "Normal", 1))
local staleTimer = runtime.timers[#runtime.timers]
cleanupState:Destroy()
local frozenStatus = cleanupState:GetStatus()
assert(table.isfrozen(frozenStatus) and frozenStatus.state == "Destroyed" and frozenStatus.activeKeys == 0
	and frozenStatus.pendingBodyBytes == 0 and runtime:activeTimers() == 0 and staleTimer.cancelled)
local callCount = #runtime.fires
runtime:fireStale(staleTimer)
assert(#runtime.fires == callCount and cleanupState:GetStatus().lastFlush == nil,
	"terminal timer callbacks hold no live queue work")

local deadStateModule, deadRuntime, deadOwner = newFixture("ServerToClient")
local deadState = create(deadStateModule, deadOwner, nil)
assert(deadState.events.Value:Put(1, "Normal", 1))
local deadTimer = deadRuntime.timers[#deadRuntime.timers]
deadOwner.alive = false
deadOwner.terminalError = Definition.error("Disconnected")
deadStateModule.destroy(deadOwner)
assert(#deadOwner.states == 0 and deadOwner.stateKeys == 0 and deadOwner.stateBytes == 0
	and deadRuntime:activeTimers() == 0 and deadTimer.cancelled)
assert(deadState:GetStatus().state == "Destroyed" and deadState:GetStatus().pendingKeys == 0)

local clientModule, clientRuntime, clientOwner, clientDefinitions = newFixture("ClientToServer")
local clientState = create(clientModule, clientOwner, nil)
assert(clientState.events.Input ~= nil and clientState.events.Value == nil
	and clientState.events.FifoOnly == nil, "client lanes expose only client-sending State events")
assert(clientState.events.Input:Put(0, "Normal", 5))
local clientOk, _, clientReport = clientState:Flush()
assert(clientOk and clientReport.logicalHandoffs == 1 and #clientRuntime.fires == 1
	and clientRuntime.fires[1].audience == nil
	and read(clientRuntime.fires[1].packet, 8_192, clientDefinitions)[1].id == 7,
	"client State uses the same bounded envelope with no caller audience")
clientState:Destroy()

local function makeRetentionWitness()
	local module, retainedRuntime, retainedOwner = newFixture("ServerToClient")
	local recipients = audience()
	local ownerWitness = setmetatable({ retainedOwner }, { __mode = "v" })
	local playerWitness = setmetatable({ recipients[1] }, { __mode = "v" })
	local retainedState = create(module, retainedOwner, recipients)
	assert(retainedState.events.Value:Put(1, "Normal", 1))
	local heldTimer = retainedRuntime.timers[#retainedRuntime.timers]
	retainedState:Destroy()
	return ownerWitness, playerWitness, retainedState, retainedRuntime, heldTimer
end

local ownerWitness, playerWitness, retainedState, retainedRuntime, heldTimer = makeRetentionWitness()
for _ = 1, 64 do
	local garbage = table.create(4_096)
	for index = 1, 4_096 do garbage[index] = { index } end
end
assert(ownerWitness[1] == nil and playerWitness[1] == nil and heldTimer.cancelled
	and retainedRuntime:activeTimers() == 0 and retainedState:GetStatus().state == "Destroyed",
	"a retained public handle and stale timer do not retain owner or audience after Destroy")

print("PASS Relay.StateQueue bounded latest-unsent replacement, selection, expiry, and cleanup")
