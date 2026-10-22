local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")
local BatchFrame = require(if script then script.Parent.BatchFrame else "./BatchFrame")

local MAXIMUM_RECORDS = 32
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8
local REFERENCE_CODEC_VERSION = 4
local RELIABLE_LIMIT = 8_192
local UNRELIABLE_LIMIT = 900
local REPORT_ZERO = table.freeze({
	reliableHandoffs = 0,
	unreliableHandoffs = 0,
	logicalHandoffs = 0,
	selected = 0,
	remaining = 0,
	expired = 0,
})

local function report(reliable, unreliable, logical, selected, remaining)
	return table.freeze({
		reliableHandoffs = reliable,
		unreliableHandoffs = unreliable,
		logicalHandoffs = logical,
		selected = selected,
		remaining = remaining,
		expired = 0,
	})
end

local function queueBusyReport(record)
	return report(0, 0, 0, 0, record.count)
end

local function cancelTimer(record)
	local timer = record.timer
	if timer == nil then return end
	record.timer = nil
	record.timerGeneration += 1
	pcall(task.cancel, timer)
end

local function clearOwner(record, owner)
	if owner.batch == record then owner.batch = nil end
	if owner.flushOwner == record then owner.flushOwner = nil end
end

local function clearPayload(record)
	record.audience = nil
	record.events = nil
	record.reliable = nil
	record.unreliable = nil
	record.count = 0
	record.reliableBytes = 3
	record.unreliableBytes = 3
	record.reliableReferenceFormat = false
	record.unreliableReferenceFormat = false
	record.reliableReferences = 0
	record.unreliableReferences = 0
end

local function snapshotEncode(event, ...)
	local encoded = table.pack(event.encode(...))
	if encoded[1] ~= true or typeof(encoded[2]) ~= "buffer" then return nil end
	local body = encoded[2]
	if buffer.len(body) < 3 then return nil end
	local referenceCount = encoded.n - 2
	if referenceCount < 0 or referenceCount > MAXIMUM_REFERENCES then return nil end
	local references = if referenceCount > 0 then table.create(referenceCount) else nil
	if references ~= nil then references.n = referenceCount end
	for index = 1, referenceCount do
		local reference = encoded[index + 2]
		if typeof(reference) ~= "Instance" then return nil end
		references[index] = reference
	end
	if buffer.readu8(body, 0) == REFERENCE_CODEC_VERSION then
		if buffer.len(body) < 4 or buffer.readu8(body, 3) ~= referenceCount then return nil end
	elseif referenceCount ~= 0 then
		return nil
	end
	if references ~= nil or buffer.readu8(body, 0) == REFERENCE_CODEC_VERSION then
		return { body = body, references = references }, referenceCount
	end
	return body, 0
end

local function settle(record, owner, ok, problem, finalReport)
	if record.result ~= nil then return record.result end
	cancelTimer(record)
	if owner ~= nil then clearOwner(record, owner) end
	record.owner = nil
	clearPayload(record)
	record.state = "Terminal"
	local result = table.freeze({ ok = ok, error = problem, report = finalReport })
	record.result = result
	record.lastFlush = result
	return result
end

local function retainOpenFailure(record, owner, problem)
	if owner.flushOwner == record then owner.flushOwner = nil end
	local finalReport = report(0, 0, 0, 0, record.count)
	local result = table.freeze({ ok = false, error = problem, report = finalReport })
	record.lastFlush = result
	return result.ok, result.error, result.report
end

local function terminalError(owner)
	return owner.terminalError or Definition.error("Destroyed")
end

local function invalidate(record, owner, problem)
	if record.result ~= nil then return record.result end
	if record.state == "Sealed" then
		cancelTimer(record)
		clearOwner(record, owner)
		record.owner = nil
		record.terminalError = problem
		clearPayload(record)
		return nil
	end
	return settle(record, owner, false, problem, REPORT_ZERO)
end

local flush

local function schedule(record, delay)
	if record.state ~= "Open" or record.owner == nil or not record.owner.alive then return end
	record.timerGeneration += 1
	local generation = record.timerGeneration
	record.timer = task.delay(delay, function()
		if record.timerGeneration ~= generation or record.state ~= "Open" then return end
		record.timer = nil
		local owner = record.owner
		if owner == nil then return end
		if not owner.alive then
			invalidate(record, owner, terminalError(owner))
			return
		end

		local remaining = record.deadline - owner.now()
		if remaining > 0 then
			schedule(record, remaining)
			return
		end

		local ok, problem = flush(record)
		if not ok and problem == Definition.error("QueueBusy")
			and record.state == "Open" and record.owner == owner and owner.alive then
			schedule(record, record.flushAfter)
		end
	end)
end

local function submit(record, eventName, ...)
	if record.state ~= "Open" then return false, Definition.error("QueueClosed") end
	local owner = record.owner
	if owner == nil or owner.batch ~= record then return false, Definition.error("QueueClosed") end
	if not owner.alive then
		local problem = terminalError(owner)
		invalidate(record, owner, problem)
		return false, problem
	end
	if owner.flushOwner ~= nil then return false, Definition.error("QueueBusy") end
	local alive, problem = owner.check()
	if not alive then
		invalidate(record, owner, problem)
		return false, problem
	end
	if record.count >= MAXIMUM_RECORDS then return false, Definition.error("QueueFull") end

	local event = record.events[eventName]
	local queued, referenceCount = snapshotEncode(event, ...)
	if queued == nil then return false, Definition.error("InvalidPayload") end
	local body = if typeof(queued) == "buffer" then queued else queued.body
	local bodyBytes = buffer.len(body)
	local delivery = event.delivery
	local unreliable = delivery == "Unreliable"
	local bytes = if unreliable then record.unreliableBytes else record.reliableBytes
	local queuedReferences = if unreliable then record.unreliableReferences else record.reliableReferences
	local hasReferenceFormat = buffer.readu8(body, 0) == REFERENCE_CODEC_VERSION
	local alreadyHasReferenceFormat = if unreliable then record.unreliableReferenceFormat else record.reliableReferenceFormat
	local limit = if unreliable then UNRELIABLE_LIMIT else RELIABLE_LIMIT
	local addedBytes = 2 + bodyBytes + referenceCount * REFERENCE_BYTES
		+ (if hasReferenceFormat and not alreadyHasReferenceFormat then 1 else 0)
	if queuedReferences + referenceCount > MAXIMUM_REFERENCES or bodyBytes < 3 or bytes + addedBytes > limit then
		return false, Definition.error("QueueFull")
	end

	local channel = if unreliable then record.unreliable else record.reliable
	channel[#channel + 1] = queued
	record.count += 1
	if unreliable then
		record.unreliableBytes += addedBytes
		record.unreliableReferenceFormat = alreadyHasReferenceFormat or hasReferenceFormat
		record.unreliableReferences += referenceCount
	else
		record.reliableBytes += addedBytes
		record.reliableReferenceFormat = alreadyHasReferenceFormat or hasReferenceFormat
		record.reliableReferences += referenceCount
	end

	if record.count == 1 then
		record.deadline = owner.now() + record.flushAfter
		schedule(record, record.flushAfter)
	end
	return true, nil
end

flush = function(record)
	if record.result ~= nil then
		local result = record.result
		return result.ok, result.error, result.report
	end
	if record.state ~= "Open" then
		return false, Definition.error("QueueBusy"), queueBusyReport(record)
	end
	local owner = record.owner
	if owner == nil then
		local problem = record.terminalError or Definition.error("QueueClosed")
		local result = settle(record, nil, false, problem, REPORT_ZERO)
		return result.ok, result.error, result.report
	end
	if owner.flushOwner ~= nil then
		return false, Definition.error("QueueBusy"), queueBusyReport(record)
	end
	owner.flushOwner = record

	if not owner.alive then
		local problem = terminalError(owner)
		local result = settle(record, owner, false, problem, REPORT_ZERO)
		return result.ok, result.error, result.report
	end
	local alive, problem = owner.check()
	if not alive then
		local result = settle(record, owner, false, problem, REPORT_ZERO)
		return result.ok, result.error, result.report
	end

	cancelTimer(record)
	local totalBytes = (if #record.reliable > 0 then record.reliableBytes else 0)
		+ (if #record.unreliable > 0 then record.unreliableBytes else 0)
	local audience = record.audience
	if record.broadcast and record.count > 0 then
		local resolved, resolveProblem = owner.resolveBroadcastAudience()
		if record.result ~= nil then
			local result = record.result
			return result.ok, result.error, result.report
		end
		if record.owner ~= owner or owner.batch ~= record or owner.flushOwner ~= record or not owner.alive then
			local result = settle(record, owner, false, terminalError(owner), REPORT_ZERO)
			return result.ok, result.error, result.report
		end
		if resolved == nil then
			return retainOpenFailure(record, owner, resolveProblem or Definition.error("InvalidAudience"))
		end
		audience = resolved
	elseif record.reusable and audience ~= nil then
		audience = table.clone(audience)
	end
	if totalBytes > 0 and owner.admit ~= nil and not owner.admit(totalBytes, audience) then
		return retainOpenFailure(record, owner, Definition.error("OutboundRateLimited"))
	end
	record.state = "Sealed"
	local selected = record.count
	local remaining = 0
	local reliable = record.reliable
	local unreliable = record.unreliable
	local reliableCount = #reliable
	local unreliableCount = #unreliable
	record.count = 0
	if not record.reusable then
		record.audience = nil
		record.reliable = nil
		record.unreliable = nil
		record.events = nil
	end

	local reliableHandoffs, unreliableHandoffs, logicalHandoffs = 0, 0, 0
	local failed
	local function sendChannel(delivery, bodies, count, limit)
		if count == 0 then return true, nil end
		local packet, references = BatchFrame.wrap(1, bodies, limit)
		table.clear(bodies)
		if packet == nil then return false, Definition.error("TransportFailure") end
		local handoffOk, handoffError, handoffs
		if record.broadcast then
			handoffOk, handoffError, handoffs = owner.broadcastHandoff(delivery, packet, references)
		else
			handoffOk, handoffError, handoffs = owner.handoff(delivery, packet, audience, references)
		end
		if delivery == "Reliable" then
			reliableHandoffs += handoffs
		else
			unreliableHandoffs += handoffs
		end
		logicalHandoffs += handoffs * count
		return handoffOk, handoffError
	end

	local reliableOk, reliableError = sendChannel("Reliable", reliable, reliableCount, RELIABLE_LIMIT)
	if not owner.alive or (record.reusable and (record.owner ~= owner or owner.batch ~= record
		or owner.flushOwner ~= record)) then
		failed = owner.terminalError or Definition.error("Destroyed")
	elseif not reliableOk then
		failed = reliableError
	else
		local unreliableOk, unreliableError = sendChannel("Unreliable", unreliable, unreliableCount, UNRELIABLE_LIMIT)
		if not owner.alive or (record.reusable and (record.owner ~= owner or owner.batch ~= record
			or owner.flushOwner ~= record)) then
			failed = owner.terminalError or Definition.error("Destroyed")
		elseif not unreliableOk then
			failed = unreliableError
		end
	end

	table.clear(unreliable)
	local finalReport = report(reliableHandoffs, unreliableHandoffs, logicalHandoffs, selected, remaining)
	if failed == nil and record.reusable and (record.owner ~= owner or owner.batch ~= record
		or owner.flushOwner ~= record or not owner.alive) then
		failed = record.terminalError or terminalError(owner)
	end
	if owner.flushOwner == record then owner.flushOwner = nil end
	audience = nil
	if failed == nil and record.reusable then
		record.state = "Open"
		record.deadline = nil
		record.count = 0
		record.reliableBytes = 3
		record.unreliableBytes = 3
		record.reliableReferenceFormat = false
		record.unreliableReferenceFormat = false
		record.reliableReferences = 0
		record.unreliableReferences = 0
		record.reliable = reliable
		record.unreliable = unreliable
		local result = table.freeze({ ok = true, error = nil, report = finalReport })
		record.lastFlush = result
		return true, nil, finalReport
	end
	local result = settle(record, owner, failed == nil, failed, finalReport)
	return result.ok, result.error, result.report
end

local function create(owner, audience, flushAfter, reusable, broadcast)
	local alive, problem = owner.check()
	if not alive then return nil, problem end
	if owner.batch ~= nil then return nil, Definition.error("QueueLimit") end
	local record = {
		owner = owner,
		audience = audience,
		reusable = reusable == true,
		broadcast = broadcast == true,
		flushAfter = flushAfter,
		state = "Open",
		count = 0,
		reliableBytes = 3,
		unreliableBytes = 3,
		reliableReferenceFormat = false,
		unreliableReferenceFormat = false,
		reliableReferences = 0,
		unreliableReferences = 0,
		reliable = {},
		unreliable = {},
		events = owner.events,
		timer = nil,
		timerGeneration = 0,
		deadline = nil,
		result = nil,
		terminalError = nil,
	}
	local eventHandles = {}
	for name, event in owner.events do
		local eventName = name
		eventHandles[name] = table.freeze({
			Send = function(_, ...)
				return submit(record, eventName, ...)
			end,
		})
	end
	local handle = table.freeze({
		events = table.freeze(eventHandles),
		Flush = function()
			return flush(record)
		end,
		GetStatus = function()
			return table.freeze({ state = record.state, pendingRecords = record.count, lastFlush = record.lastFlush })
		end,
		Cancel = function()
			if record.state ~= "Open" or record.result ~= nil then return end
			local currentOwner = record.owner
			if currentOwner == nil or currentOwner.flushOwner ~= nil then return end
			if not currentOwner.alive then
				invalidate(record, currentOwner, terminalError(currentOwner))
				return
			end
			settle(record, currentOwner, false, Definition.error("Cancelled"), REPORT_ZERO)
		end,
	})
	owner.batch = record
	return handle, nil
end

local function destroy(owner)
	local record = owner.batch
	if record == nil then return end
	local problem = terminalError(owner)
	invalidate(record, owner, problem)
end

local function prune(owner, player)
	local record = owner.batch
	if record == nil or (record.state ~= "Open" and not record.reusable) or record.audience == nil then return end
	local audience = record.audience
	local write = 1
	for read = 1, #audience do
		local current = audience[read]
		if current ~= player then
			audience[write] = current
			write += 1
		end
	end
	for index = #audience, write, -1 do audience[index] = nil end
end

return table.freeze({ create = create, destroy = destroy, prune = prune })
