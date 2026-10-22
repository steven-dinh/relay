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
		Optional = {
			id = 15,
			direction = "ServerToClient",
			queue = "Batch",
			fields = schema.ordered(schema.field("value", schema.optional(schema.boolean()))),
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
	function owner.handoff(delivery, packet, audience, references)
		table.insert(runtime.fires, { delivery = delivery, packet = packet, audience = audience, references = references })
		if runtime.onHandoff then return runtime.onHandoff(delivery, packet, audience, references) end
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

local function create(Batch, owner, recipients, delay, reusable)
	local handle, problem = Batch.create(owner, recipients, delay or 0.02, reusable)
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

do
local reusableModule, reusableRuntime, reusableOwner = newFixture()
local reusableRecipients = audience()
local reusable = create(reusableModule, reusableOwner, reusableRecipients, 0.02, true)
assert(reusableRuntime:activeTimers() == 0 and reusable:GetStatus().state == "Open")
local oneShotWhileReusable, oneShotProblem = reusableModule.create(reusableOwner, reusableRecipients, 0.02)
assert(oneShotWhileReusable == nil and oneShotProblem.code == "QueueLimit",
	"an idle reusable handle keeps the shared batch slot")
local emptyReusableOk, _, emptyReusableReport = reusable:Flush()
local emptyReusableStatus = reusable:GetStatus()
assert(emptyReusableOk and emptyReusableStatus.state == "Open" and emptyReusableStatus.pendingRecords == 0
	and emptyReusableStatus.lastFlush.report == emptyReusableReport and table.isfrozen(emptyReusableReport)
	and reusableRuntime:activeTimers() == 0 and #reusableRuntime.fires == 0,
	"an empty reusable flush records its result and reopens without a timer")
assert(reusable.events.Reliable:Send(false))
local firstReusableTimer = reusableRuntime.timers[#reusableRuntime.timers]
reusableRuntime.now = 0.01
local composite = { count = 17 }
assert(reusable.events.Nested:Send(composite))
assert(reusable.events.Optional:Send(nil))
assert(reusableRuntime:activeTimers() == 1 and firstReusableTimer.deadline == 0.02,
	"later sends do not extend the window deadline")
composite.count = 91
local firstReusableOk, _, firstReusableReport = reusable:Flush()
local firstReusableStatus = reusable:GetStatus()
assert(firstReusableOk and firstReusableReport.selected == 3 and firstReusableStatus.state == "Open"
	and firstReusableStatus.pendingRecords == 0 and firstReusableStatus.lastFlush.report == firstReusableReport
	and reusableRuntime:activeTimers() == 0 and #reusableRuntime.fires == 1,
	"manual flush reopens the same reusable sender after one FIFO handoff")
local reusableRows = assert(BatchFrame.scan(reusableRuntime.fires[1].packet,
	BatchFrame.header(reusableRuntime.fires[1].packet, 8_192), function(id) return eventRows[id] end))
local reusableFalse, reusableFalseValue = Frame.compile(eventRows[7], "decode")(
	BatchFrame.readBody(reusableRuntime.fires[1].packet, reusableRows[1]))
local reusableNested, reusableNestedValue = Frame.compile(eventRows[9], "decode")(
	BatchFrame.readBody(reusableRuntime.fires[1].packet, reusableRows[2]))
local optionalOk, optionalValue = Frame.compile(eventRows[15], "decode")(
	BatchFrame.readBody(reusableRuntime.fires[1].packet, reusableRows[3]))
assert(reusableFalse and reusableFalseValue == false and reusableNested and reusableNestedValue.count == 17
	and optionalOk and optionalValue == nil,
	"reusable windows retain false, nil, and frozen composite payloads")
local emptyAgainOk, _, emptyAgainReport = reusable:Flush()
assert(emptyAgainOk and emptyAgainReport.selected == 0 and #reusableRuntime.fires == 1
	and reusable:GetStatus().state == "Open", "an empty retry cannot resend an earlier window")
assert(reusable.events.Reliable:Send(true))
local secondReusableTimer = reusableRuntime.timers[#reusableRuntime.timers]
assert(secondReusableTimer ~= firstReusableTimer and secondReusableTimer.deadline == 0.03)
local firesBeforeStaleReusable = #reusableRuntime.fires
reusableRuntime:fireStale(firstReusableTimer)
assert(reusableRuntime:activeTimers() == 1 and #reusableRuntime.fires == firesBeforeStaleReusable,
	"a stale timer from the previous window cannot flush the next window")
local secondReusableOk, _, secondReusableReport = reusable:Flush()
assert(secondReusableOk and secondReusableReport.selected == 1 and #reusableRuntime.fires == 2
	and reusable:GetStatus().state == "Open", "a second manual window reuses the same event handle")
local secondRows = assert(BatchFrame.scan(reusableRuntime.fires[2].packet,
	BatchFrame.header(reusableRuntime.fires[2].packet, 8_192), function(id) return eventRows[id] end))
local secondValueOk, secondValue = Frame.compile(eventRows[7], "decode")(
	BatchFrame.readBody(reusableRuntime.fires[2].packet, secondRows[1]))
assert(secondValueOk and secondValue == true, "the next window contains only its new payload")
reusable:Cancel()
assert(reusable:GetStatus().state == "Terminal" and reusableOwner.batch == nil
	and reusableRuntime:activeTimers() == 0, "Cancel releases an idle reusable slot")
end

do
local automaticModule, automaticRuntime, automaticOwner = newFixture()
local automatic = create(automaticModule, automaticOwner, nil, 0.02, true)
assert(automatic.events.Reliable:Send(false))
local automaticFirstTimer = automaticRuntime.timers[#automaticRuntime.timers]
automaticRuntime.now = automaticFirstTimer.deadline
automaticRuntime:fire(automaticFirstTimer)
assert(automatic:GetStatus().state == "Open" and automatic:GetStatus().pendingRecords == 0
	and automaticRuntime:activeTimers() == 0 and #automaticRuntime.fires == 1,
	"automatic expiry flushes and reopens without leaving an idle timer")
automaticRuntime.now = 0.06
assert(automatic.events.Reliable:Send(true))
local automaticSecondTimer = automaticRuntime.timers[#automaticRuntime.timers]
assert(automaticSecondTimer.deadline == 0.08)
local automaticBeforeStale = #automaticRuntime.fires
automaticRuntime:fireStale(automaticFirstTimer)
assert(automaticRuntime:activeTimers() == 1 and #automaticRuntime.fires == automaticBeforeStale,
	"the completed automatic timer cannot flush a later submission")
automaticRuntime.now = automaticSecondTimer.deadline
automaticRuntime:fire(automaticSecondTimer)
assert(automatic:GetStatus().state == "Open" and automatic:GetStatus().pendingRecords == 0
	and automaticRuntime:activeTimers() == 0 and #automaticRuntime.fires == automaticBeforeStale + 1,
	"the same reusable sender supports consecutive automatic windows")
automatic:Cancel()
end

do
local retainedModule, retainedRuntime, retainedOwner = newFixture()
local retainedRecipients = audience()
local retained = create(retainedModule, retainedOwner, retainedRecipients, 0.02, true)
local admissionCalls, admittedAudience = 0, nil
retainedOwner.admit = function(_, targets)
	admissionCalls += 1
	admittedAudience = targets
	return admissionCalls > 1
end
assert(retained.events.Reliable:Send(false))
local refusalTimer = retainedRuntime.timers[#retainedRuntime.timers]
local refused, refusalProblem, refusalReport = retained:Flush()
assert(not refused and refusalProblem.code == "OutboundRateLimited" and refusalReport.remaining == 1
	and retained:GetStatus().state == "Open" and retained:GetStatus().pendingRecords == 1
	and retainedRuntime:activeTimers() == 0,
	"outbound refusal retains a reusable window and stops its timer")
assert(retained.events.Reliable:Send(true) and retainedRuntime:activeTimers() == 0
	and refusalTimer.cancelled, "additional sends after refusal do not restart an automatic retry timer")
local retryOk, _, retryReport = retained:Flush()
assert(retryOk and retryReport.selected == 2 and retained:GetStatus().state == "Open"
	and retainedRuntime:activeTimers() == 0 and admissionCalls == 2
	and admittedAudience ~= retainedRecipients and #retainedRuntime.fires == 1
	and retainedRuntime.fires[1].audience == admittedAudience,
	"explicit retry uses the same copied audience for admission and handoff, then reopens")
retained:Cancel()
end

do
local capacityModule, _, capacityOwner = newFixture()
local capacityBatcher = create(capacityModule, capacityOwner, nil, 0.02, true)
for _ = 1, 32 do assert(capacityBatcher.events.Empty:Send()) end
local reusableCountOverflow, reusableCountProblem = capacityBatcher.events.Empty:Send()
assert(not reusableCountOverflow and reusableCountProblem.code == "QueueFull")
local reusableCountOk, _, reusableCountReport = capacityBatcher:Flush()
assert(reusableCountOk and reusableCountReport.selected == 32)
for _ = 1, 32 do assert(capacityBatcher.events.Empty:Send()) end
local reusableCountOverflowAgain, reusableCountProblemAgain = capacityBatcher.events.Empty:Send()
assert(not reusableCountOverflowAgain and reusableCountProblemAgain.code == "QueueFull",
	"the 32-record cap resets for each reusable window")
assert(capacityBatcher:Flush())
	local largeValues = table.create(64, 0)
	for index = 1, 64 do largeValues[index] = 0 end
	for _ = 1, 31 do assert(capacityBatcher.events.Large:Send(largeValues)) end
	local reusableByteOverflow, reusableByteProblem = capacityBatcher.events.Large:Send(largeValues)
	assert(not reusableByteOverflow and reusableByteProblem.code == "QueueFull")
	local reusableByteOk, _, reusableByteReport = capacityBatcher:Flush()
	assert(reusableByteOk and reusableByteReport.selected == 31)
	assert(capacityBatcher.events.Large:Send(largeValues))
	local resetByteOk, _, resetByteReport = capacityBatcher:Flush()
	assert(resetByteOk and resetByteReport.selected == 1,
		"the Reliable byte budget resets after a reusable window succeeds")
capacityBatcher:Cancel()
end

do
local sharedModule, sharedRuntime, sharedOwner = newFixture()
local sharedBatcher = create(sharedModule, sharedOwner, nil, 0.02, true)
assert(sharedBatcher.events.Reliable:Send(false))
sharedOwner.flushOwner = {}
sharedBatcher:Cancel()
assert(sharedBatcher:GetStatus().state == "Open" and sharedBatcher:GetStatus().pendingRecords == 1
	and sharedRuntime:activeTimers() == 1, "Cancel preserves the inherited shared flush guard")
sharedOwner.flushOwner = nil
sharedBatcher:Cancel()
assert(sharedBatcher:GetStatus().state == "Terminal" and sharedOwner.batch == nil
	and sharedRuntime:activeTimers() == 0, "a later Cancel releases a reusable sender")
end

do
local partialModule, partialRuntime, partialOwner = newFixture()
local partialBatcher = create(partialModule, partialOwner, audience(), 0.02, true)
assert(partialBatcher.events.Reliable:Send(false))
assert(partialBatcher.events.Reliable:Send(true))
assert(partialBatcher.events.Unreliable:Send(2))
partialRuntime.onHandoff = function(delivery)
	if delivery == "Reliable" then
		local reentrantOk, reentrantProblem = partialBatcher:Flush()
		assert(not reentrantOk and reentrantProblem.code == "QueueBusy")
		partialBatcher:Cancel()
		return false, Definition.error("TransportFailure"), 1
	end
	return true, nil, 3
end
local partialOk, partialProblem, partialReport = partialBatcher:Flush()
assert(not partialOk and partialProblem.code == "TransportFailure" and partialReport.selected == 3
	and partialReport.reliableHandoffs == 1 and partialReport.unreliableHandoffs == 0
	and partialReport.logicalHandoffs == 2 and partialBatcher:GetStatus().state == "Terminal"
	and partialOwner.batch == nil and partialRuntime:activeTimers() == 0,
	"partial handoff failure terminates the reusable sender and releases its slot")
local _, _, partialAgain = partialBatcher:Flush()
local partialSend, partialSendProblem = partialBatcher.events.Reliable:Send(false)
assert(partialAgain == partialReport and not partialSend and partialSendProblem.code == "QueueClosed"
	and #partialRuntime.fires == 1, "terminal reusable failure cannot retransmit the window")

local destroyedModule, destroyedRuntime, destroyedOwner = newFixture()
local destroyedBatcher = create(destroyedModule, destroyedOwner, audience(), 0.02, true)
assert(destroyedBatcher.events.Reliable:Send(false))
assert(destroyedBatcher.events.Unreliable:Send(7))
destroyedRuntime.onHandoff = function(delivery)
	if delivery == "Reliable" then
		destroyedOwner.alive = false
		destroyedOwner.terminalError = Definition.error("Destroyed")
		destroyedModule.destroy(destroyedOwner)
		return true, nil, 1
	end
	return true, nil, 3
end
local destroyedOk, destroyedProblem, destroyedReport = destroyedBatcher:Flush()
assert(not destroyedOk and destroyedProblem.code == "Destroyed" and destroyedReport.selected == 2
	and destroyedReport.reliableHandoffs == 1 and destroyedReport.unreliableHandoffs == 0
	and destroyedBatcher:GetStatus().state == "Terminal" and destroyedOwner.batch == nil
	and destroyedOwner.flushOwner == nil and #destroyedRuntime.fires == 1,
	"teardown during handoff cannot reopen or continue a reusable sender")
local _, _, destroyedAgain = destroyedBatcher:Flush()
assert(destroyedAgain == destroyedReport and #destroyedRuntime.fires == 1)
end

do
local audienceModule, _, audienceOwner = newFixture()
local audienceRecipients = audience()
local audienceBatcher = create(audienceModule, audienceOwner, table.clone(audienceRecipients), 0.02, true)
local admissionSnapshot
audienceOwner.admit = function(_, targets)
	admissionSnapshot = targets
	return true
end
local firstVisitCount, firstHandOffAudience
function audienceOwner.handoff(_, _, targets)
	assert(targets == admissionSnapshot, "admission and handoff share one per-flush audience copy")
	firstHandOffAudience = targets
	local visited = 0
	for _, player in targets do
		visited += 1
		if visited == 1 then audienceModule.prune(audienceOwner, audienceRecipients[2]) end
	end
	firstVisitCount = visited
	return true, nil, visited
end
assert(audienceBatcher.events.Reliable:Send(false))
local audienceFirstOk, _, audienceFirstReport = audienceBatcher:Flush()
assert(audienceFirstOk and firstVisitCount == 3 and #firstHandOffAudience == 3
	and audienceFirstReport.reliableHandoffs == 3,
	"removal during handoff prunes retained audience without changing the active iterator")
assert(audienceBatcher.events.Reliable:Send(true))
local audienceSecondOk, _, audienceSecondReport = audienceBatcher:Flush()
assert(audienceSecondOk and audienceSecondReport.reliableHandoffs == 2
	and #admissionSnapshot == 2 and admissionSnapshot[1] == audienceRecipients[1]
	and admissionSnapshot[2] == audienceRecipients[3],
	"the next reusable window uses the pruned retained audience")
audienceBatcher:Cancel()
end

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

do
	local referenceModule, referenceRuntime, referenceOwner = newFixture()
	local reference = roblox.Instance.new("Part")
	local otherReference = roblox.Instance.new("Part")
	local sourceReferences = table.pack(reference)
	local body = buffer.create(5)
	buffer.writeu8(body, 0, 4)
	buffer.writeu16(body, 1, 16)
	buffer.writeu8(body, 3, 1)
	buffer.writeu8(body, 4, 1)
	referenceOwner.events.Reference = {
		id = 16, delivery = "Reliable", queue = "Batch",
		encode = function()
			return true, body, table.unpack(sourceReferences, 1, sourceReferences.n)
		end,
	}
	local referenceBatch = create(referenceModule, referenceOwner, nil)
	assert(referenceBatch.events.Reference:Send())
	assert(referenceOwner.batch.reliableBytes == 19 and referenceOwner.batch.reliableReferences == 1,
		"FIFO admission includes the format-5 header and per-reference charge")
	sourceReferences[1] = otherReference
	local referenceOk, _, referenceReport = referenceBatch:Flush()
	local referenceFire = referenceRuntime.fires[#referenceRuntime.fires]
	assert(referenceOk and referenceReport.selected == 1 and referenceFire.references.n == 1
		and referenceFire.references[1] == reference,
		"FIFO owns a bounded copy of native references until handoff")
	local referenceHeader = assert(BatchFrame.header(referenceFire.packet, 8_192, referenceFire.references))
	local referenceRows = assert(BatchFrame.scan(referenceFire.packet, referenceHeader,
		function(id)
			return if id == 16 then { id = 16, usesCodec = true, hasReferences = true,
				maximumReferences = 1, minimumEncodedBytes = 4, maximumEncodedBytes = 16 } else nil
		end, referenceFire.references))
	local copiedBody, copiedReferences = BatchFrame.readBody(referenceFire.packet, referenceRows[1], referenceFire.references)
	assert(buffer.readu8(copiedBody, 0) == 4 and copiedReferences[1] == reference,
		"FIFO handoff keeps each queued record's local reference ordinal and sidecar")
	referenceFire.references = nil
	local sixteen = { n = 16 }
	for index = 1, 16 do sixteen[index] = reference end
	local body16 = buffer.create(4)
	buffer.writeu8(body16, 0, 4)
	buffer.writeu16(body16, 1, 17)
	buffer.writeu8(body16, 3, 16)
	referenceOwner.events.SixteenReferences = {
		id = 17, delivery = "Reliable", queue = "Batch",
		encode = function() return true, body16, table.unpack(sixteen, 1, sixteen.n) end,
	}
	-- Handles are fixed at Create time, so register all events before creating the batch.
	local fullReferenceBatch = create(referenceModule, referenceOwner, nil)
	assert(fullReferenceBatch.events.SixteenReferences:Send())
	local overflowBody = buffer.create(5)
	buffer.writeu8(overflowBody, 0, 4)
	buffer.writeu16(overflowBody, 1, 18)
	buffer.writeu8(overflowBody, 3, 1)
	buffer.writeu8(overflowBody, 4, 1)
	referenceOwner.events.OneReference = {
		id = 18, delivery = "Reliable", queue = "Batch",
		encode = function() return true, overflowBody, reference end,
	}
	fullReferenceBatch:Cancel()
	fullReferenceBatch = create(referenceModule, referenceOwner, nil)
	assert(fullReferenceBatch.events.SixteenReferences:Send())
	local overflow, overflowProblem = fullReferenceBatch.events.OneReference:Send()
	assert(not overflow and overflowProblem.code == "QueueFull"
		and fullReferenceBatch:GetStatus().pendingRecords == 1
		and referenceOwner.batch.reliableReferences == 16,
		"FIFO rejects a seventeenth queued reference without disturbing admitted work")
	fullReferenceBatch:Cancel()
end

print("PASS Relay.BatchQueue bounded FIFO ownership, deadlines, handoff, and cleanup")
