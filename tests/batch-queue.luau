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
local exactReliableFields = {}
for index = 1, 7 do exactReliableFields[index] = schema.field(`part{index}`, schema.string(1_024)) end
exactReliableFields[8] = schema.field("last", schema.string(1_000))
local token, definitionProblem = Relay.define({
	name = "BatchQueueTest",
	version = 1,
	events = {
		Reliable = {
			id = 7,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(schema.field("value", schema.boolean())),
		},
		Unreliable = {
			id = 8,
			direction = "ServerToClient",
			delivery = "Unreliable",
			queue = "Batch",
			fields = schema.ordered(schema.field("value", schema.u8())),
		},
		Nested = {
			id = 9,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(schema.field("value", schema.struct(schema.field("count", schema.u8())))),
		},
		Empty = {
			id = 10,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(),
		},
		Large = {
			id = 11,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(schema.field("values", schema.array(schema.u32(), 64))),
		},
		LargeUnreliable = {
			id = 12,
			direction = "ServerToClient",
			delivery = "Unreliable",
			queue = "Batch",
			fields = schema.ordered(schema.field("values", schema.array(schema.u32(), 64))),
		},
		ExactReliable = {
			id = 13,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(table.unpack(exactReliableFields)),
		},
		ExactUnreliable = {
			id = 14,
			direction = "ServerToClient",
			delivery = "Unreliable",
			queue = "Batch",
			fields = schema.ordered(schema.field("value", schema.string(890))),
		},
	},
})
assert(token, definitionProblem and definitionProblem.message)
local compiled = assert(Definition.get(token))

local function newFixture()
	local runtime = { now = 0, timers = {}, cancelledTimers = 0, fires = {}, onHandoff = nil }
	local scheduler = {
		delay = function(seconds, callback)
			local timer = { deadline = runtime.now + seconds, callback = callback, cancelled = false, fired = false }
			table.insert(runtime.timers, timer)
			return timer
		end,
		cancel = function(timer)
			timer.cancelled = true
			runtime.cancelledTimers += 1
		end,
	}
	local Batch = luau.load(fs.readFile("src/internal/Batch.luau"), {
		debugName = "Batch",
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
		local queued = compiled.queuedById[event.id]
		events[name] = {
			id = queued.id,
			delivery = queued.delivery,
			queue = queued.queue,
			encode = Frame.compile(queued, "encode"),
		}
	end
	local owner = {
		alive = true,
		terminalError = nil,
		events = events,
		batch = nil,
		flushOwner = nil,
	}
	function owner.check()
		return owner.alive, if owner.alive then nil else owner.terminalError or Definition.error("Destroyed")
	end
	function owner.now()
		return runtime.now
	end
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
	function runtime:due()
		local snapshot = table.clone(self.timers)
		for _, timer in snapshot do
			if not timer.cancelled and not timer.fired and timer.deadline <= self.now then
				self:fire(timer)
			end
		end
	end
	return Batch, runtime, owner
end

local function audience()
	return { { Name = "A" }, { Name = "B" }, { Name = "C" } }
end

local function create(Batch, owner, recipients, delay)
	local handle, problem = Batch.create(owner, recipients, delay or 0.02)
	assert(handle, problem and problem.message)
	return handle
end

local function checkBody(packet, expectedIds, limit, eventById)
	local header = assert(BatchFrame.header(packet, limit))
	assert(header.kind == 1 and header.count == #expectedIds, "FIFO uses kind 1 on either channel")
	local rows = assert(BatchFrame.scan(packet, header, function(id) return eventById[id] end))
	for index, id in expectedIds do assert(rows[index].event.id == id) end
end

local function eventById()
	local result = {}
	for _, event in compiled.queuedById do result[event.id] = event end
	return result
end

local Batch, runtime, owner = newFixture()
assert(table.isfrozen(Batch) and Batch.create and Batch.destroy and Batch.prune)
local batchExports = 0
for key in Batch do
	batchExports += 1
	assert(key == "create" or key == "destroy" or key == "prune")
end
assert(batchExports == 3)

local emptyModule, emptyRuntime, emptyOwner = newFixture()
emptyOwner.events = {}
local emptyBatch = create(emptyModule, emptyOwner, nil)
local emptyOk, emptyProblem, emptyReport = emptyBatch:Flush()
local _, _, emptyAgain = emptyBatch:Flush()
assert(emptyOk and emptyProblem == nil and table.isfrozen(emptyReport) and emptyAgain == emptyReport
	and emptyReport.selected == 0 and emptyReport.reliableHandoffs == 0
	and #emptyRuntime.fires == 0 and emptyOwner.batch == nil,
	"a batch with no sendable events flushes empty after lifecycle checks")

local rejectedCreateModule, _, rejectedCreateOwner = newFixture()
rejectedCreateOwner.check = function()
	return false, Definition.error("Disconnected")
end
local rejectedCreate, rejectedCreateProblem = rejectedCreateModule.create(rejectedCreateOwner, nil, 0.02)
assert(rejectedCreate == nil and rejectedCreateProblem.code == "Disconnected"
	and rejectedCreateOwner.batch == nil, "creation checks lifecycle before taking the session slot")

local rejectedSendModule, _, rejectedSendOwner = newFixture()
local rejectedSendBatch = create(rejectedSendModule, rejectedSendOwner, nil)
rejectedSendOwner.check = function()
	return false, Definition.error("Disconnected")
end
local rejectedSend, rejectedSendProblem = rejectedSendBatch.events.Reliable:Send(false)
assert(not rejectedSend and rejectedSendProblem.code == "Disconnected" and rejectedSendOwner.batch == nil,
	"failed lifecycle checks discard the open batch without retaining its queue")

local recipients = audience()
local batch = create(Batch, owner, recipients)
local duplicate, duplicateProblem = Batch.create(owner, recipients, 0.02)
assert(duplicate == nil and duplicateProblem.code == "QueueLimit")
local eventRows = eventById()

assert(batch.events.Reliable:Send(false))
assert(batch.events.Unreliable:Send(9))
assert(batch.events.Empty:Send())
assert(batch.events.Reliable:Send(true))
assert(#runtime.fires == 0 and runtime:activeTimers() == 1)
local ok, problem, result = batch:Flush()
assert(ok and problem == nil and table.isfrozen(result))
assert(result.selected == 4 and result.remaining == 0 and result.expired == 0
	and result.reliableHandoffs == 3 and result.unreliableHandoffs == 3
	and result.logicalHandoffs == 12, "reports count successful audience calls and represented records")
assert(#runtime.fires == 2 and runtime.fires[1].delivery == "Reliable"
	and runtime.fires[2].delivery == "Unreliable", "Reliable handoff precedes Unreliable")
checkBody(runtime.fires[1].packet, { 7, 10, 7 }, 8_192, eventRows)
checkBody(runtime.fires[2].packet, { 8 }, 900, eventRows)
assert(runtime.fires[1].audience == recipients and owner.batch == nil and owner.flushOwner == nil)
local repeatedOk, repeatedProblem, repeatedReport = batch:Flush()
assert(repeatedOk and repeatedProblem == nil and repeatedReport == result and #runtime.fires == 2,
	"terminal Flush returns the cached result without retry")

local invalidBatch = create(Batch, owner, nil)
local badArity, badArityProblem = invalidBatch.events.Reliable:Send()
assert(not badArity and badArityProblem.code == "InvalidPayload" and runtime:activeTimers() == 0)
local badType, badTypeProblem = invalidBatch.events.Reliable:Send("false")
assert(not badType and badTypeProblem.code == "InvalidPayload")
assert(invalidBatch.events.Empty:Send(), "zero-field payloads retain exact arity")
invalidBatch:Cancel()
local cancelledOk, cancelledProblem, cancelledReport = invalidBatch:Flush()
assert(not cancelledOk and cancelledProblem.code == "Cancelled" and cancelledReport.selected == 0)
assert(runtime:activeTimers() == 0 and owner.batch == nil)
local closedSend, closedProblem = invalidBatch.events.Empty:Send()
assert(not closedSend and closedProblem.code == "QueueClosed")

local mutationBatch = create(Batch, owner, nil)
local source = { count = 17 }
assert(mutationBatch.events.Nested:Send(source))
source.count = 91
local mutationOk, _, mutationReport = mutationBatch:Flush()
assert(mutationOk and mutationReport.reliableHandoffs == 1)
local mutationRows = assert(BatchFrame.scan(runtime.fires[#runtime.fires].packet,
	BatchFrame.header(runtime.fires[#runtime.fires].packet, 8_192), function(id) return eventRows[id] end))
local mutationBody = assert(BatchFrame.readBody(runtime.fires[#runtime.fires].packet, mutationRows[1]))
local decodeNested = Frame.compile(eventRows[9], "decode")
local decodedNested, decodedValue = decodeNested(mutationBody)
assert(decodedNested and decodedValue.count == 17, "queued body owns the encoded caller snapshot")

local overflowBatch = create(Batch, owner, nil)
local largeValues = table.create(64, 0)
for index = 1, 64 do largeValues[index] = 0 end
for _ = 1, 31 do assert(overflowBatch.events.Large:Send(largeValues)) end
local overflowTimerCount = runtime:activeTimers()
local overflow, overflowProblem = overflowBatch.events.Large:Send(largeValues)
assert(not overflow and overflowProblem.code == "QueueFull" and #runtime.fires == 3,
	"per-envelope byte overflow rejects before handoff and retains prior records")
assert(runtime:activeTimers() == overflowTimerCount, "overflow leaves the original timer intact")
local overflowOk, _, overflowReport = overflowBatch:Flush()
assert(overflowOk and overflowReport.selected == 31)

local countBatch = create(Batch, owner, nil)
for _ = 1, 32 do assert(countBatch.events.Empty:Send()) end
local countOverflow, countProblem = countBatch.events.Empty:Send()
assert(not countOverflow and countProblem.code == "QueueFull")
local countOk, _, countReport = countBatch:Flush()
assert(countOk and countReport.selected == 32)

local unreliableBatch = create(Batch, owner, nil)
for _ = 1, 3 do assert(unreliableBatch.events.LargeUnreliable:Send(largeValues)) end
local unreliableOverflow, unreliableProblem = unreliableBatch.events.LargeUnreliable:Send(largeValues)
assert(not unreliableOverflow and unreliableProblem.code == "QueueFull",
	"Unreliable complete-envelope bytes have an independent 900-byte cap")
local unreliableOk, _, unreliableReport = unreliableBatch:Flush()
assert(unreliableOk and unreliableReport.selected == 3 and unreliableReport.unreliableHandoffs == 1)

local exactReliableBatch = create(Batch, owner, nil)
local exactParts = table.create(8, string.rep("r", 1_024))
for index = 1, 7 do exactParts[index] = string.rep("r", 1_024) end
exactParts[8] = string.rep("s", 1_000)
assert(exactReliableBatch.events.ExactReliable:Send(table.unpack(exactParts)))
local exactReliableOk = exactReliableBatch:Flush()
assert(exactReliableOk and buffer.len(runtime.fires[#runtime.fires].packet) == 8_192
	and BatchFrame.header(runtime.fires[#runtime.fires].packet, 8_192) ~= nil,
	"the exact Reliable complete-envelope limit is accepted")

local exactUnreliableBatch = create(Batch, owner, nil)
assert(exactUnreliableBatch.events.ExactUnreliable:Send(string.rep("u", 890)))
local exactUnreliableOk = exactUnreliableBatch:Flush()
assert(exactUnreliableOk and buffer.len(runtime.fires[#runtime.fires].packet) == 900
	and BatchFrame.header(runtime.fires[#runtime.fires].packet, 900) ~= nil,
	"the exact Unreliable complete-envelope limit is accepted")

local deadlineBatch = create(Batch, owner, nil)
assert(deadlineBatch.events.Reliable:Send(false))
local fireCountBeforeDeadline = #runtime.fires
local originalTimer = runtime.timers[#runtime.timers]
owner.now = function() return runtime.now end
runtime.now = 0.01
assert(deadlineBatch.events.Reliable:Send(true))
assert(runtime:activeTimers() == 1 and originalTimer.deadline == 0.02,
	"later submissions do not extend the first deadline")
runtime:fire(originalTimer)
assert(runtime:activeTimers() == 1 and #runtime.fires == fireCountBeforeDeadline,
	"early timer execution re-arms only the remaining delay")
local earlyTimer = runtime.timers[#runtime.timers]
assert(earlyTimer.deadline == 0.02)
runtime.now = 0.02
runtime:fire(earlyTimer)
assert(runtime:activeTimers() == 0 and #runtime.fires == fireCountBeforeDeadline + 1,
	"automatic service flushes at the established deadline")

local busyBatch = create(Batch, owner, nil)
assert(busyBatch.events.Reliable:Send(false))
local fireCountBeforeBusy = #runtime.fires
local busyTimer = runtime.timers[#runtime.timers]
owner.flushOwner = {}
local busyOk, busyProblem = busyBatch:Flush()
assert(not busyOk and busyProblem.code == "QueueBusy" and not busyTimer.cancelled
	and runtime:activeTimers() == 1, "manual QueueBusy preserves its timer and work")
busyBatch:Cancel()
assert(owner.batch ~= nil, "Cancel during another flush is an unchanged no-op")
runtime.now = busyTimer.deadline
runtime:fire(busyTimer)
assert(runtime:activeTimers() == 1 and owner.batch ~= nil and #runtime.fires == fireCountBeforeBusy,
	"automatic QueueBusy rearms one positive-delay service")
local busyRearm = runtime.timers[#runtime.timers]
assert(busyRearm.deadline == runtime.now + 0.02, "automatic QueueBusy uses one positive flushAfter delay")
runtime:fireStale(busyTimer)
assert(runtime:activeTimers() == 1 and owner.batch ~= nil,
	"a stale cancelled timer cannot create another service")
runtime.now = busyRearm.deadline
runtime:fire(busyRearm)
assert(runtime:activeTimers() == 1 and owner.batch ~= nil)
local busyRearmAgain = runtime.timers[#runtime.timers]
owner.flushOwner = nil
runtime.now = busyRearmAgain.deadline
runtime:fire(busyRearmAgain)
assert(runtime:activeTimers() == 0 and owner.batch == nil and #runtime.fires == fireCountBeforeBusy + 1,
	"the single busy rearm flushes once the shared guard is released")

local partialBatch = create(Batch, owner, audience())
assert(partialBatch.events.Reliable:Send(false))
assert(partialBatch.events.Reliable:Send(true))
assert(partialBatch.events.Unreliable:Send(2))
runtime.onHandoff = function(delivery)
	if delivery == "Reliable" then
		local reentrantOk, reentrantProblem = partialBatch:Flush()
		assert(not reentrantOk and reentrantProblem.code == "QueueBusy")
		partialBatch:Cancel()
		return false, Definition.error("TransportFailure"), 1
	end
	return true, nil, 3
end
local fireCountBeforePartial = #runtime.fires
local partialOk, partialProblem, partialReport = partialBatch:Flush()
assert(not partialOk and partialProblem.code == "TransportFailure"
	and partialReport.selected == 3 and partialReport.remaining == 0
	and partialReport.reliableHandoffs == 1 and partialReport.unreliableHandoffs == 0
	and partialReport.logicalHandoffs == 2 and #runtime.fires == fireCountBeforePartial + 1,
	"partial audience failure counts successful calls, stops, and never retries")
local _, _, partialAgain = partialBatch:Flush()
assert(partialAgain == partialReport and #runtime.fires == fireCountBeforePartial + 1)
runtime.onHandoff = nil

local departedSnapshot = table.clone(recipients)
local departedBatch = create(Batch, owner, departedSnapshot)
assert(departedBatch.events.Reliable:Send(false))
Batch.prune(owner, recipients[2])
assert(owner.batch.audience[1] == recipients[1] and owner.batch.audience[2] == recipients[3]
	and owner.batch.audience[3] == nil, "prune removes departures in place and preserves order")
local departedOk = departedBatch:Flush()
assert(departedOk and runtime.fires[#runtime.fires].audience[2] == recipients[3]
	and #runtime.fires == fireCountBeforePartial + 2)

local destroyedBatch = create(Batch, owner, audience())
assert(destroyedBatch.events.Reliable:Send(false))
assert(destroyedBatch.events.Unreliable:Send(7))
runtime.onHandoff = function(delivery)
	if delivery == "Reliable" then
		owner.alive = false
		owner.terminalError = Definition.error("Destroyed")
		Batch.destroy(owner)
		assert(owner.batch == nil and owner.flushOwner == nil,
			"Destroy immediately invalidates both shared owner slots")
		local reentrantOk, reentrantProblem = destroyedBatch:Flush()
		assert(not reentrantOk and reentrantProblem.code == "QueueBusy")
		return true, nil, 1
	end
	return true, nil, 3
end
local fireCountBeforeDestroy = #runtime.fires
local destroyedOk, destroyedProblem, destroyedReport = destroyedBatch:Flush()
assert(not destroyedOk and destroyedProblem.code == "Destroyed" and destroyedReport.reliableHandoffs == 1
	and destroyedReport.logicalHandoffs == 1 and destroyedReport.unreliableHandoffs == 0
	and owner.batch == nil and owner.flushOwner == nil and #runtime.fires == fireCountBeforeDestroy + 1,
	"Destroy during handoff keeps actual prior counts and cannot hand off later channels")
local _, _, destroyedAgain = destroyedBatch:Flush()
assert(destroyedAgain == destroyedReport and #runtime.fires == fireCountBeforeDestroy + 1)
runtime.onHandoff = nil

local memoryBatchModule, memoryRuntime, memoryOwner = newFixture()
local memoryRecipients = audience()
local retainedHandle = create(memoryBatchModule, memoryOwner, memoryRecipients)
assert(retainedHandle.events.Reliable:Send(false))
retainedHandle:Cancel()
assert(memoryOwner.batch == nil and memoryRuntime:activeTimers() == 0
	and table.isfrozen(retainedHandle) and retainedHandle.events.Reliable,
	"terminal cleanup releases the owner slot and timer while retaining a usable fixed handle")

local deadModule, deadRuntime, deadOwner = newFixture()
local deadBatch = create(deadModule, deadOwner, nil)
assert(deadBatch.events.Reliable:Send(false))
local deadTimer = deadRuntime.timers[#deadRuntime.timers]
deadOwner.alive = false
deadOwner.terminalError = Definition.error("Disconnected")
deadModule.destroy(deadOwner)
assert(deadOwner.batch == nil and deadRuntime:activeTimers() == 0 and deadTimer.cancelled)
local deadOk, deadProblem = deadBatch:Flush()
assert(not deadOk and deadProblem.code == "Disconnected")

local busyDestroyModule, busyDestroyRuntime, busyDestroyOwner = newFixture()
local busyDestroyBatch = create(busyDestroyModule, busyDestroyOwner, nil)
assert(busyDestroyBatch.events.Reliable:Send(false))
local firstBusyTimer = busyDestroyRuntime.timers[#busyDestroyRuntime.timers]
busyDestroyOwner.flushOwner = {}
busyDestroyRuntime.now = firstBusyTimer.deadline
busyDestroyRuntime:fire(firstBusyTimer)
local pendingAfterBusy = busyDestroyRuntime.timers[#busyDestroyRuntime.timers]
assert(busyDestroyRuntime:activeTimers() == 1 and not pendingAfterBusy.cancelled)
busyDestroyOwner.alive = false
busyDestroyOwner.terminalError = Definition.error("Destroyed")
busyDestroyModule.destroy(busyDestroyOwner)
assert(busyDestroyRuntime:activeTimers() == 0 and pendingAfterBusy.cancelled
	and busyDestroyOwner.batch == nil, "Destroy cancels a busy automatic rearm")
busyDestroyRuntime:fireStale(pendingAfterBusy)
assert(#busyDestroyRuntime.fires == 0 and busyDestroyOwner.batch == nil)

print("PASS Relay.BatchQueue bounded FIFO ownership, deadlines, handoff, and cleanup")
