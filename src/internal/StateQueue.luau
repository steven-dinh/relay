local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")
local BatchFrame = require(if script then script.Parent.BatchFrame else "./BatchFrame")
local Diagnostics = require(if script then script.Parent.Diagnostics else "./Diagnostics")

local MAXIMUM_LANES = 4
local MAXIMUM_KEYS = 64
local MAXIMUM_BODY_BYTES = 16_384
local MAXIMUM_RECORDS = 32
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8
local REFERENCE_CODEC_VERSION = 4
local MAXIMUM_INDEPENDENT_RECIPIENTS = 64
local RELIABLE_LIMIT = 8_192
local UNRELIABLE_LIMIT = 900
local MAXIMUM_AGE = 1
local MINIMUM_BUDGET_RETRY = 1 / 60
local flush, scheduleNextService, scheduleIndependentService, scheduleBudgetRetry, recordIndependentExpiry

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local REPORT_ZERO = table.freeze({
	reliableHandoffs = 0,
	unreliableHandoffs = 0,
	logicalHandoffs = 0,
	selected = 0,
	remaining = 0,
	expired = 0,
})

local function makeReport(reliable, unreliable, logical, selected, remaining, expired, recipients)
	local report = {
		reliableHandoffs = reliable,
		unreliableHandoffs = unreliable,
		logicalHandoffs = logical,
		selected = selected,
		remaining = remaining,
		expired = expired,
	}
	if recipients ~= nil then report.recipients = recipients end
	return table.freeze(report)
end

local function pendingReport(record)
	return makeReport(0, 0, 0, 0, record.pendingKeys, 0)
end

local function isKey(value)
	return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 4_294_967_295
end

local function priorityRank(value)
	if value == "High" then return 1 end
	if value == "Normal" then return 2 end
	if value == "Low" then return 3 end
	return nil
end

local function cancelTimer(record)
	local timer = record.timer
	if timer == nil then return end
	record.timer = nil
	record.expiryOnly = nil
	record.timerGeneration += 1
	pcall(task.cancel, timer)
end

local function removeLane(owner, record)
	local lanes = owner.states
	if lanes == nil then return end
	for index = 1, #lanes do
		if lanes[index] == record then
			table.remove(lanes, index)
			return
		end
	end
end

local function clearPending(owner, record, slot)
	local body = slot.body
	if body == nil then return 0 end
	local bodyBytes = buffer.len(body)
	local referenceCount = if slot.references == nil then 0 else slot.references.n
	local retainedBytes = bodyBytes + referenceCount * REFERENCE_BYTES
	slot.body = nil
	slot.references = nil
	slot.pendingRecipients = nil
	slot.pendingRecipientCount = nil
	slot.priority = nil
	slot.firstDirty = nil
	slot.latestSubmit = nil
	record.pendingKeys -= 1
	record.pendingBodyBytes -= retainedBytes
	owner.stateBytes -= retainedBytes
	return retainedBytes
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
	if references ~= nil then return { body = body, references = references }, referenceCount end
	return body, 0
end

local function clearContents(owner, record)
	cancelTimer(record)
	if owner.stateKeys ~= nil then owner.stateKeys -= record.activeKeys end
	if owner.stateBytes ~= nil then owner.stateBytes -= record.pendingBodyBytes end
	if record.audience ~= nil then table.clear(record.audience) end
	if record.recipients ~= nil then
		for _, recipient in record.recipients do recipient.player = nil end
		table.clear(record.recipients)
	end
	if record.keys ~= nil then table.clear(record.keys) end
	record.pendingKeys = 0
	record.pendingBodyBytes = 0
	record.activeKeys = 0
	record.events = nil
	record.audience = nil
	record.recipients = nil
	record.keys = nil
	record.serviceDeadline = nil
end

local function closeLane(record, owner, problem)
	if record.state == "Destroyed" then return end
	cancelTimer(record)
	if owner ~= nil then
		if owner.flushOwner == record then owner.flushOwner = nil end
		removeLane(owner, record)
		clearContents(owner, record)
	end
	record.owner = nil
	record.state = "Destroyed"
	record.terminalError = problem or Definition.error("QueueClosed")
end

local function terminalError(owner)
	return owner.terminalError or Definition.error("Destroyed")
end

local function recordReport(owner, reason, endpointId, delivery)
	if owner == nil or not owner.alive then return end
	local diagnostics = owner.diagnostics
	if diagnostics ~= nil then Diagnostics.report(diagnostics, reason, endpointId, delivery) end
end

local function recordSubmitted(owner, endpointId, delivery, bytes)
	if owner == nil or not owner.alive then return end
	local diagnostics = owner.diagnostics
	if diagnostics == nil or diagnostics.traffic == nil then return end
	Diagnostics.recordSubmitted(diagnostics, endpointId, delivery, bytes)
end

local function recordSent(owner, delivery, packet, references, bodies, bodyCount, handoffs, recipientCount)
	if owner == nil or not owner.alive then return end
	local diagnostics = owner.diagnostics
	if diagnostics == nil or diagnostics.traffic == nil then return end
	Diagnostics.recordSentPacket(diagnostics, delivery, packet, references, bodies, bodyCount, handoffs, recipientCount)
end

local function failLifecycle(record, owner)
	local problem = terminalError(owner)
	closeLane(record, owner, problem)
	return problem
end

local function findSlot(record, eventId, key)
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.eventId == eventId and slot.key == key then return slot, index end
	end
	return nil
end

local function earliestExpiry(record)
	local earliest = nil
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.body ~= nil then
			local deadline = slot.firstDirty + MAXIMUM_AGE
			if earliest == nil or deadline < earliest then earliest = deadline end
		end
	end
	return earliest
end

local function scheduleAt(record, deadline, expiryOnly, serviceDeadline)
	local owner = record.owner
	if record.state ~= "Open" or owner == nil or not owner.alive or record.pendingKeys == 0 then return end
	cancelTimer(record)
	record.timerGeneration += 1
	local generation = record.timerGeneration
	record.serviceDeadline = if record.independent then serviceDeadline else deadline
	record.expiryOnly = expiryOnly == true
	local delay = math.max(0, deadline - owner.now())
	record.timer = task.delay(delay, function()
		if record.timerGeneration ~= generation or record.state ~= "Open" then return end
		record.timer = nil
		local cleanupOnly = record.expiryOnly == true
		record.expiryOnly = nil
		local currentOwner = record.owner
		if currentOwner == nil then return end
		if not currentOwner.alive then
			failLifecycle(record, currentOwner)
			return
		end

		local now = currentOwner.now()
		local serviceAt = record.serviceDeadline
		if record.independent and cleanupOnly then
			local alive, problem = currentOwner.check()
			if not alive then
				closeLane(record, currentOwner, problem)
				return
			end
			local expired = 0
			for _, slot in record.keys do
				if slot.body ~= nil and now - slot.firstDirty >= MAXIMUM_AGE then
					clearPending(currentOwner, record, slot)
					expired += 1
				end
			end
			if expired > 0 then recordIndependentExpiry(record, expired) end
			if record.pendingKeys == 0 then
				record.serviceDeadline = nil
				return
			end
			if serviceAt ~= nil and now < serviceAt then
				scheduleIndependentService(record, serviceAt)
				return
			elseif serviceAt == nil then
				scheduleBudgetRetry(record, currentOwner, 0)
				return
			end
		elseif cleanupOnly then
			if serviceAt ~= nil and now < serviceAt then
				scheduleAt(record, serviceAt, true)
				return
			end
			local alive, problem = currentOwner.check()
			if not alive then
				closeLane(record, currentOwner, problem)
				return
			end
			for _, slot in record.keys do
				if slot.body ~= nil and now - slot.firstDirty >= MAXIMUM_AGE then
					clearPending(currentOwner, record, slot)
				end
			end
			record.serviceDeadline = nil
			local expiry = earliestExpiry(record)
			if expiry ~= nil then scheduleAt(record, expiry, true) end
			return
		elseif serviceAt ~= nil and now < serviceAt then
			if record.independent then
				scheduleIndependentService(record, serviceAt)
			else
				scheduleAt(record, serviceAt)
			end
			return
		end
		record.serviceDeadline = nil

		local flushOk, flushError = flush(record)
		if not flushOk and flushError == Definition.error("QueueBusy")
			and record.state == "Open" and record.owner == currentOwner and currentOwner.alive
			and record.pendingKeys > 0 then
			local retryAt = currentOwner.now()
			if record.independent then
				scheduleNextService(record, currentOwner, retryAt)
			else
				scheduleAt(record, retryAt + record.flushAfter)
			end
		end
	end)
end

scheduleNextService = function(record, owner, now, expiry)
	local interval = if record.independent
		then math.max(record.flushAfter, MINIMUM_BUDGET_RETRY)
		else record.flushAfter
	local deadline = now + interval
	if expiry == nil then expiry = earliestExpiry(record) end
	if record.independent then
		scheduleIndependentService(record, deadline, expiry)
	else
		if expiry ~= nil and expiry < deadline then deadline = expiry end
		scheduleAt(record, deadline)
	end
end

scheduleIndependentService = function(record, serviceDeadline, expiry)
	if expiry == nil then expiry = earliestExpiry(record) end
	local wakeDeadline = serviceDeadline
	local expiryOnly = false
	if expiry ~= nil and (wakeDeadline == nil or expiry < wakeDeadline) then
		wakeDeadline = expiry
		expiryOnly = true
	end
	if wakeDeadline ~= nil then
		scheduleAt(record, wakeDeadline, expiryOnly, serviceDeadline)
	else
		cancelTimer(record)
		record.serviceDeadline = nil
	end
end

local function expireOwner(owner, expired)
	local lanes = owner.states
	if lanes == nil then return end
	local nextExpired = 1
	for index = 1, #lanes do
		local record = lanes[index]
		while expired[nextExpired] == record do
			clearPending(owner, record, expired[nextExpired + 1])
			nextExpired += 2
		end
		if record.pendingKeys == 0 then
			cancelTimer(record)
			record.serviceDeadline = nil
		end
	end
end

local function sortSelection(rows)
	table.sort(rows, function(left, right)
		if left.priority ~= right.priority then return left.priority < right.priority end
		if left.firstDirty ~= right.firstDirty then return left.firstDirty < right.firstDirty end
		if left.eventId ~= right.eventId then return left.eventId < right.eventId end
		return left.key < right.key
	end)
end

local function selection(rows, limit)
	sortSelection(rows)
	local capacity = math.min(#rows, MAXIMUM_RECORDS)
	local selected = table.create(capacity)
	local selectedSlots = table.create(capacity)
	local usedBytes, usedReferences, hasReferenceFormat = 3, 0, false
	for _, slot in rows do
		if #selected == MAXIMUM_RECORDS then break end
		local bodyBytes = buffer.len(slot.body)
		local references = if slot.references == nil then 0 else slot.references.n
		local referenceFormat = buffer.readu8(slot.body, 0) == REFERENCE_CODEC_VERSION
		local headerBytes = if referenceFormat and not hasReferenceFormat then 1 else 0
		local nextBytes = usedBytes + headerBytes + 2 + bodyBytes + references * REFERENCE_BYTES
		if usedReferences + references <= MAXIMUM_REFERENCES and nextBytes <= limit then
			selected[#selected + 1] = if references > 0
				then { body = slot.body, references = slot.references }
				else slot.body
			selectedSlots[#selectedSlots + 1] = slot
			usedBytes = nextBytes
			usedReferences += references
			hasReferenceFormat = hasReferenceFormat or referenceFormat
		end
	end
	return selected, selectedSlots, if #selected > 0 then usedBytes else 0
end

local function selectedPacketBytes(record, now, recipientIndex)
	local reliableRows, unreliableRows = {}, {}
	for _, slot in record.keys do
		if slot.body ~= nil and now - slot.firstDirty < MAXIMUM_AGE
			and (recipientIndex == nil or (slot.pendingRecipients ~= nil and slot.pendingRecipients[recipientIndex] == true)) then
			if slot.delivery == "Reliable" then
				reliableRows[#reliableRows + 1] = slot
			elseif slot.delivery == "Unreliable" then
				unreliableRows[#unreliableRows + 1] = slot
			end
		end
	end
	local _, _, reliableBytes = selection(reliableRows, RELIABLE_LIMIT)
	local _, _, unreliableBytes = selection(unreliableRows, UNRELIABLE_LIMIT)
	return reliableBytes + unreliableBytes
end

local function recipientPendingCount(record, recipientIndex)
	if record.keys == nil then return 0 end
	local count = 0
	for _, slot in record.keys do
		if slot.body ~= nil and slot.pendingRecipients ~= nil and slot.pendingRecipients[recipientIndex] == true then
			count += 1
		end
	end
	return count
end

local function retryDeadline(record, owner, bytes, now)
	local expiry = earliestExpiry(record)
	if owner.retryAfter == nil then return if record.independent then nil else expiry end
	if record.independent then
		local retryDeadline = nil
		for index, recipient in record.recipients do
			if recipient.player ~= nil then
				local recipientBytes = selectedPacketBytes(record, now, index)
				if recipientBytes > 0 then
					local retryAfter = owner.retryAfter(recipientBytes, recipient.player)
					if retryAfter ~= nil and finite(retryAfter) and retryAfter >= 0 then
						local candidate = now + math.max(retryAfter, MINIMUM_BUDGET_RETRY, record.flushAfter)
						if finite(candidate) and (retryDeadline == nil or candidate < retryDeadline) then
							retryDeadline = candidate
						end
					end
				end
			end
		end
		return retryDeadline
	end
	local retryAfter = owner.retryAfter(bytes, record.audience)
	if retryAfter ~= nil and finite(retryAfter) and retryAfter >= 0 then
		local candidate = now + math.max(retryAfter, MINIMUM_BUDGET_RETRY, record.flushAfter)
		if finite(candidate) and (expiry == nil or candidate < expiry) then expiry = candidate end
	end
	return expiry
end

scheduleBudgetRetry = function(record, owner, bytes)
	local now = owner.now()
	local deadline = retryDeadline(record, owner, bytes, now)
	if record.independent then
		scheduleIndependentService(record, deadline)
	elseif deadline ~= nil then
		scheduleAt(record, deadline)
	end
end

local function bringRetryForward(record, owner, now, expiryDeadline)
	if not record.deferOutbound or record.timer == nil or record.lastFlush == nil
		or record.lastFlush.error ~= Definition.error("OutboundRateLimited") then return end
	local bytes = if record.independent then 0 else selectedPacketBytes(record, now)
	if not record.independent and bytes == 0 then return end
	if owner.retryAfter == nil then return end
	local deadline = retryDeadline(record, owner, bytes, now)
	if record.independent then
		if deadline ~= nil and (record.serviceDeadline == nil or deadline < record.serviceDeadline) then
			scheduleIndependentService(record, deadline, expiryDeadline)
		end
		return
	end
	if deadline == nil then return end
	if expiryDeadline ~= nil and expiryDeadline < deadline then deadline = expiryDeadline end
	if record.serviceDeadline == nil or deadline < record.serviceDeadline then
		scheduleAt(record, deadline)
	end
end

local function independentReportRow(player, selected, remaining, reliable, unreliable, logical, problem)
	local row = {
		player = player,
		selected = selected,
		remaining = remaining,
		reliableHandoffs = reliable,
		unreliableHandoffs = unreliable,
		logicalHandoffs = logical,
	}
	if problem ~= nil then row.error = problem end
	return table.freeze(row)
end

local function statusRecipients(record)
	if record.recipients == nil then return table.freeze({}) end
	local recipients = table.create(#record.recipients)
	local latest = if record.lastFlush == nil then nil else record.lastFlush.report.recipients
	local count = 0
	for index, recipient in record.recipients do
		local player = recipient.player
		if player ~= nil then
			local previous
			if latest ~= nil then
				for _, row in latest do
					if row.player == player then previous = row; break end
				end
			end
			count += 1
			recipients[count] = independentReportRow(player,
				if previous == nil then 0 else previous.selected,
				recipientPendingCount(record, index),
				if previous == nil then 0 else previous.reliableHandoffs,
				if previous == nil then 0 else previous.unreliableHandoffs,
				if previous == nil then 0 else previous.logicalHandoffs,
				if previous == nil then nil else previous.error)
		end
	end
	for index = count + 1, #recipients do recipients[index] = nil end
	return table.freeze(recipients)
end

recordIndependentExpiry = function(record, expired)
	local recipients = table.create(#record.recipients)
	local count = 0
	for index, recipient in record.recipients do
		if recipient.player ~= nil then
			count += 1
			recipients[count] = independentReportRow(recipient.player, 0,
				recipientPendingCount(record, index), 0, 0, 0, nil)
		end
	end
	for index = count + 1, #recipients do recipients[index] = nil end
	table.freeze(recipients)
	record.lastFlush = table.freeze({ ok = true, error = nil, report = makeReport(0, 0, 0, 0,
		record.pendingKeys, expired, recipients) })
end

local function flushIndependent(record, owner, now, expired)
	local recipients = table.create(#record.recipients)
	for index, recipient in record.recipients do recipients[index] = recipient end
	record.state = "Flushing"
	local reliableHandoffs, unreliableHandoffs, logicalHandoffs = 0, 0, 0
	local selectedKeys = {}
	local results = {}
	local failed

	for index, recipient in recipients do
		local player = recipient.player
		if player ~= nil then
			local reliableRows, unreliableRows = {}, {}
			for _, slot in record.keys do
				if slot.body ~= nil and slot.pendingRecipients ~= nil and slot.pendingRecipients[index] == true then
					if slot.delivery == "Reliable" then
						reliableRows[#reliableRows + 1] = slot
					elseif slot.delivery == "Unreliable" then
						unreliableRows[#unreliableRows + 1] = slot
					end
				end
			end
			local reliableBodies, reliableSlots, reliableBytes = selection(reliableRows, RELIABLE_LIMIT)
			local unreliableBodies, unreliableSlots, unreliableBytes = selection(unreliableRows, UNRELIABLE_LIMIT)
			reliableRows, unreliableRows = nil, nil
			local reliableCount, unreliableCount = #reliableBodies, #unreliableBodies
			if reliableCount == 0 then reliableBytes = 0 end
			if unreliableCount == 0 then unreliableBytes = 0 end
			local selected = reliableCount + unreliableCount
			local progress = { selected = 0, reliableHandoffs = 0, unreliableHandoffs = 0, logicalHandoffs = 0 }

			if selected > 0 and not owner.admit(reliableBytes + unreliableBytes, { player }, true) then
				progress.error = Definition.error("OutboundRateLimited")
				if failed == nil then failed = progress.error end
			elseif selected > 0 then
				for _, slot in reliableSlots do
					slot.pendingRecipients[index] = nil
					slot.pendingRecipientCount -= 1
					selectedKeys[slot] = true
					if slot.pendingRecipientCount == 0 then clearPending(owner, record, slot) end
				end
				for _, slot in unreliableSlots do
					slot.pendingRecipients[index] = nil
					slot.pendingRecipientCount -= 1
					selectedKeys[slot] = true
					if slot.pendingRecipientCount == 0 then clearPending(owner, record, slot) end
				end
				progress.selected = selected

				local reliablePacket, reliableReferences
				if reliableCount > 0 then reliablePacket, reliableReferences = BatchFrame.wrap(2, reliableBodies, RELIABLE_LIMIT) end
				local unreliablePacket, unreliableReferences
				if unreliableCount > 0 then unreliablePacket, unreliableReferences = BatchFrame.wrap(2, unreliableBodies, UNRELIABLE_LIMIT) end
				local function handoff(delivery, packet, references, bodies, count)
					if packet == nil then
						recordReport(owner, "TransportFailure")
						return false, Definition.error("TransportFailure"), 0
					end
					local ok, issue, handoffs = owner.handoff(delivery, packet, { player }, references)
					handoffs = handoffs or 0
					if delivery == "Reliable" then
						progress.reliableHandoffs += handoffs
						reliableHandoffs += handoffs
					else
						progress.unreliableHandoffs += handoffs
						unreliableHandoffs += handoffs
					end
					progress.logicalHandoffs += handoffs * count
					logicalHandoffs += handoffs * count
					recordSent(owner, delivery, packet, references, bodies, count, handoffs, handoffs)
					return ok, issue
				end

				local issue
				if reliableCount > 0 then
					local handoffOk, handoffError = handoff("Reliable", reliablePacket, reliableReferences,
						reliableBodies, reliableCount)
					if not handoffOk then issue = handoffError end
				end
				if issue == nil and record.state ~= "Destroyed" and owner.alive and unreliableCount > 0 then
					local handoffOk, handoffError = handoff("Unreliable", unreliablePacket, unreliableReferences,
						unreliableBodies, unreliableCount)
					if not handoffOk then issue = handoffError end
				end
				for bodyIndex = 1, #reliableBodies do reliableBodies[bodyIndex] = nil end
				for bodyIndex = 1, #unreliableBodies do unreliableBodies[bodyIndex] = nil end
				table.clear(reliableSlots)
				table.clear(unreliableSlots)
				reliablePacket, unreliablePacket = nil, nil
				if issue ~= nil then
					progress.error = issue
					progress.remaining = recipientPendingCount(record, index)
					results[index] = progress
					failed = issue
					break
				end
			end
			progress.remaining = recipientPendingCount(record, index)
			results[index] = progress
		end
		if record.state == "Destroyed" or not owner.alive then break end
	end

	if record.state == "Destroyed" then
		failed = record.terminalError or owner.terminalError or Definition.error("QueueClosed")
	elseif not owner.alive then
		failed = owner.terminalError or Definition.error("Destroyed")
		closeLane(record, owner, failed)
	end

	local recipientReports = table.create(#recipients)
	local recipientReportCount = 0
	for index, recipient in recipients do
		local player = recipient.player
		if player ~= nil then
			local progress = results[index]
			local row = independentReportRow(player,
				if progress == nil then 0 else progress.selected or 0,
				recipientPendingCount(record, index),
				if progress == nil then 0 else progress.reliableHandoffs or 0,
				if progress == nil then 0 else progress.unreliableHandoffs or 0,
				if progress == nil then 0 else progress.logicalHandoffs or 0,
				if progress == nil then nil else progress.error)
			recipientReportCount += 1
			recipientReports[recipientReportCount] = row
		end
	end
	for index = recipientReportCount + 1, #recipientReports do recipientReports[index] = nil end
	table.freeze(recipientReports)
	local selectedCount = 0
	for _ in selectedKeys do selectedCount += 1 end
	local finalReport = makeReport(reliableHandoffs, unreliableHandoffs, logicalHandoffs,
		selectedCount, record.pendingKeys, expired, recipientReports)
	local result = table.freeze({ ok = failed == nil, error = failed, report = finalReport })
	if record.owner == owner and record.state ~= "Destroyed" then
		owner.flushOwner = nil
		record.state = "Open"
		record.lastFlush = result
		if record.pendingKeys > 0 then
			if failed == Definition.error("OutboundRateLimited") then
				scheduleBudgetRetry(record, owner, 0)
			else
				scheduleNextService(record, owner, owner.now())
			end
		end
	end
	return result.ok, result.error, result.report
end

local function submit(record, eventName, key, priority, ...)
	local event = if record.events == nil then nil else record.events[eventName]
	local endpointId = if event == nil then nil else event.id
	if record.state == "Flushing" then
		recordReport(record.owner, "QueueBusy", endpointId, if event == nil then nil else event.delivery)
		return false, Definition.error("QueueBusy")
	end
	if record.state ~= "Open" then
		recordReport(record.owner, "QueueClosed", endpointId, if event == nil then nil else event.delivery)
		return false, Definition.error("QueueClosed")
	end
	local owner = record.owner
	if owner == nil or owner.flushOwner ~= nil then
		local reason = if owner == nil then "QueueClosed" else "QueueBusy"
		recordReport(owner, reason, endpointId, if event == nil then nil else event.delivery)
		return false, Definition.error(reason)
	end
	if not owner.alive then return false, failLifecycle(record, owner) end
	local alive, problem = owner.check()
	if not alive then
		closeLane(record, owner, problem)
		recordReport(owner, if problem == nil then nil else problem.code, endpointId, if event == nil then nil else event.delivery)
		return false, problem
	end
	if not isKey(key) then return false, Definition.error("InvalidStateKey") end
	local rank = priorityRank(priority)
	if rank == nil then return false, Definition.error("InvalidPriority") end

	if event == nil then
		recordReport(owner, "QueueClosed")
		return false, Definition.error("QueueClosed")
	end
	local slot = findSlot(record, event.id, key)
	if slot == nil and owner.stateKeys >= MAXIMUM_KEYS then
		recordReport(owner, "QueueLimit", endpointId, event.delivery)
		return false, Definition.error("QueueLimit")
	end

	local queued, referenceCount = snapshotEncode(event, ...)
	if queued == nil then
		recordReport(owner, "InvalidPayload", endpointId, event.delivery)
		return false, Definition.error("InvalidPayload")
	end
	local body = if typeof(queued) == "buffer" then queued else queued.body
	local bodyBytes = buffer.len(body)
	local limit = if event.delivery == "Unreliable" then UNRELIABLE_LIMIT else RELIABLE_LIMIT
	local retainedBodyBytes = bodyBytes + referenceCount * REFERENCE_BYTES
	local referenceFormat = buffer.readu8(body, 0) == REFERENCE_CODEC_VERSION
	if bodyBytes < 3 or bodyBytes + 5 + referenceCount * REFERENCE_BYTES
		+ (if referenceFormat then 1 else 0) > limit then
		recordReport(owner, "QueueFull", endpointId, event.delivery)
		return false, Definition.error("QueueFull")
	end

	local now = owner.now()
	local expiredBytes = 0
	local expired = nil
	local earliestExpiryDeadline = nil
	local lanes = owner.states
	for laneIndex = 1, #lanes do
		local lane = lanes[laneIndex]
		for keyIndex = 1, #lane.keys do
			local candidate = lane.keys[keyIndex]
			if candidate.body ~= nil then
				if now - candidate.firstDirty >= MAXIMUM_AGE then
					expiredBytes += buffer.len(candidate.body)
						+ (if candidate.references == nil then 0 else candidate.references.n * REFERENCE_BYTES)
					if expired == nil then expired = {} end
					local nextExpired = #expired + 1
					expired[nextExpired], expired[nextExpired + 1] = lane, candidate
				elseif lane == record then
					local deadline = candidate.firstDirty + MAXIMUM_AGE
					if earliestExpiryDeadline == nil or deadline < earliestExpiryDeadline then
						earliestExpiryDeadline = deadline
					end
				end
			end
		end
	end
	local previousBodyBytes = 0
	if slot ~= nil and slot.body ~= nil and now - slot.firstDirty < MAXIMUM_AGE then
		previousBodyBytes = buffer.len(slot.body)
			+ (if slot.references == nil then 0 else slot.references.n * REFERENCE_BYTES)
	end
	local retainedBytes = owner.stateBytes - expiredBytes - previousBodyBytes
	if retainedBytes + retainedBodyBytes > MAXIMUM_BODY_BYTES then
		recordReport(owner, "QueueFull", endpointId, event.delivery)
		return false, Definition.error("QueueFull")
	end

	-- Apply the invocation's expiry plan only after byte admission succeeds.
	if expired ~= nil then expireOwner(owner, expired) end
	local hadPending = record.pendingKeys > 0
	if slot == nil then
		slot = {
			eventId = event.id,
			delivery = event.delivery,
			key = key,
			body = nil,
			references = nil,
			priority = nil,
			firstDirty = nil,
			latestSubmit = nil,
			pendingRecipients = nil,
			pendingRecipientCount = nil,
		}
		record.keys[#record.keys + 1] = slot
		record.activeKeys += 1
		owner.stateKeys += 1
	end

	local wasPending = previousBodyBytes > 0
	if not wasPending then
		local deadline = now + MAXIMUM_AGE
		if earliestExpiryDeadline == nil or deadline < earliestExpiryDeadline then
			earliestExpiryDeadline = deadline
		end
	end
	slot.body = body
	slot.references = if typeof(queued) == "buffer" then nil else queued.references
	if record.independent then
		local pendingRecipients = table.create(#record.recipients)
		local pendingRecipientCount = 0
		for index, recipient in record.recipients do
			if recipient.player ~= nil then
				pendingRecipients[index] = true
				pendingRecipientCount += 1
			end
		end
		slot.pendingRecipients = pendingRecipients
		slot.pendingRecipientCount = pendingRecipientCount
	else
		slot.pendingRecipients = nil
		slot.pendingRecipientCount = nil
	end
	slot.priority = rank
	slot.latestSubmit = now
	if not wasPending then slot.firstDirty = now end
	record.pendingBodyBytes += retainedBodyBytes - previousBodyBytes
	owner.stateBytes += retainedBodyBytes - previousBodyBytes
	if not wasPending then record.pendingKeys += 1 end
	recordSubmitted(owner, endpointId, event.delivery, retainedBodyBytes)

	if not hadPending or record.timer == nil or record.expiryOnly then
		if record.independent and record.expiryOnly and record.serviceDeadline ~= nil then
			scheduleIndependentService(record, record.serviceDeadline, earliestExpiryDeadline)
			bringRetryForward(record, owner, now, earliestExpiryDeadline)
		else
			scheduleNextService(record, owner, now, earliestExpiryDeadline)
		end
	elseif record.deferOutbound then
		bringRetryForward(record, owner, now, earliestExpiryDeadline)
	end
	return true, nil
end

flush = function(record)
	if record.state == "Destroyed" then
		return false, record.terminalError or Definition.error("QueueClosed"), REPORT_ZERO
	end
	local owner = record.owner
	if owner == nil then return false, record.terminalError or Definition.error("QueueClosed"), REPORT_ZERO end
	if record.state == "Flushing" or owner.flushOwner ~= nil then
		recordReport(owner, "QueueBusy")
		return false, Definition.error("QueueBusy"), pendingReport(record)
	end
	if record.state ~= "Open" then return false, Definition.error("QueueClosed"), pendingReport(record) end
	owner.flushOwner = record
	if not owner.alive then
		local problem = failLifecycle(record, owner)
		return false, problem, REPORT_ZERO
	end
	local alive, problem = owner.check()
	if not alive then
		closeLane(record, owner, problem)
		return false, problem, REPORT_ZERO
	end

	cancelTimer(record)
	record.serviceDeadline = nil
	local now = owner.now()
	local expired = 0
	local reliableRows, unreliableRows = {}, {}
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.body ~= nil then
			if now - slot.firstDirty >= MAXIMUM_AGE then
				clearPending(owner, record, slot)
				expired += 1
			elseif not record.independent and slot.delivery == "Reliable" then
				reliableRows[#reliableRows + 1] = slot
			elseif not record.independent and slot.delivery == "Unreliable" then
				unreliableRows[#unreliableRows + 1] = slot
			end
		end
	end
	if record.independent then return flushIndependent(record, owner, now, expired) end
	local reliableBodies, reliableSlots, reliablePacketBytes = selection(reliableRows, RELIABLE_LIMIT)
	local unreliableBodies, unreliableSlots, unreliablePacketBytes = selection(unreliableRows, UNRELIABLE_LIMIT)
	reliableRows, unreliableRows = nil, nil
	local selected = #reliableBodies + #unreliableBodies
	local reliableCount, unreliableCount = #reliableBodies, #unreliableBodies
	reliablePacketBytes = if reliableCount > 0 then reliablePacketBytes else 0
	unreliablePacketBytes = if unreliableCount > 0 then unreliablePacketBytes else 0
	local audience = if record.deferOutbound and record.audience ~= nil
		then table.clone(record.audience) else record.audience
	local refusal
	if record.broadcast and selected > 0 then
		local resolved, resolveProblem = owner.resolveBroadcastAudience()
		if record.state ~= "Open" or record.owner ~= owner or owner.flushOwner ~= record or not owner.alive then
			return false, record.terminalError or terminalError(owner), REPORT_ZERO
		end
		if resolved == nil then
			refusal = resolveProblem or Definition.error("InvalidAudience")
		else
			audience = resolved
		end
	end
	if refusal == nil and reliablePacketBytes + unreliablePacketBytes > 0 and owner.admit ~= nil
		and not owner.admit(reliablePacketBytes + unreliablePacketBytes, audience, record.deferOutbound) then
		refusal = Definition.error("OutboundRateLimited")
	end
	if refusal ~= nil then
		table.clear(reliableBodies)
		table.clear(unreliableBodies)
		table.clear(reliableSlots)
		table.clear(unreliableSlots)
		owner.flushOwner = nil
		local finalReport = makeReport(0, 0, 0, 0, record.pendingKeys, expired)
		local result = table.freeze({ ok = false, error = refusal, report = finalReport })
		record.lastFlush = result
		if record.deferOutbound then
			scheduleBudgetRetry(record, owner, reliablePacketBytes + unreliablePacketBytes)
		else
			local expiry = earliestExpiry(record)
			if expiry ~= nil then scheduleAt(record, expiry, true) end
		end
		return result.ok, result.error, result.report
	end
	for _, slot in reliableSlots do clearPending(owner, record, slot) end
	for _, slot in unreliableSlots do clearPending(owner, record, slot) end
	local remaining = record.pendingKeys
	local reliablePacket, reliableReferences
	if reliableCount > 0 then reliablePacket, reliableReferences = BatchFrame.wrap(2, reliableBodies, RELIABLE_LIMIT) end
	local unreliablePacket, unreliableReferences
	if unreliableCount > 0 then unreliablePacket, unreliableReferences = BatchFrame.wrap(2, unreliableBodies, UNRELIABLE_LIMIT) end
	record.state = "Flushing"

	local reliableHandoffs, unreliableHandoffs, logicalHandoffs = 0, 0, 0
	local failed
	local function handoff(delivery, packet, references, bodies, count)
		if packet == nil then
			recordReport(owner, "TransportFailure")
			return false, Definition.error("TransportFailure")
		end
		local handoffOk, handoffError, handoffs
		if record.broadcast then
			handoffOk, handoffError, handoffs = owner.broadcastHandoff(delivery, packet, references)
		else
			handoffOk, handoffError, handoffs = owner.handoff(delivery, packet, audience, references)
		end
		if delivery == "Reliable" then reliableHandoffs += handoffs else unreliableHandoffs += handoffs end
		logicalHandoffs += handoffs * count
		local recipientCount = if record.broadcast then handoffs * #audience else handoffs
		recordSent(owner, delivery, packet, references, bodies, count, handoffs, recipientCount)
		return handoffOk, handoffError
	end

	if reliableCount > 0 then
		local handoffOk, handoffError = handoff("Reliable", reliablePacket, reliableReferences,
			reliableBodies, reliableCount)
		if not handoffOk then failed = handoffError end
	end
	if failed == nil and record.state ~= "Destroyed" and owner.alive and unreliableCount > 0 then
		local handoffOk, handoffError = handoff("Unreliable", unreliablePacket, unreliableReferences,
			unreliableBodies, unreliableCount)
		if not handoffOk then failed = handoffError end
	end
	if record.state == "Destroyed" then
		failed = record.terminalError or owner.terminalError or Definition.error("QueueClosed")
	elseif not owner.alive then
		failed = owner.terminalError or Definition.error("Destroyed")
		closeLane(record, owner, failed)
	end

	reliablePacket, unreliablePacket = nil, nil
	for index = 1, #reliableBodies do reliableBodies[index] = nil end
	for index = 1, #unreliableBodies do unreliableBodies[index] = nil end
	table.clear(reliableSlots)
	table.clear(unreliableSlots)
	reliableBodies, unreliableBodies, reliableSlots, unreliableSlots = nil, nil, nil, nil
	local finalReport = makeReport(reliableHandoffs, unreliableHandoffs, logicalHandoffs, selected, remaining, expired)
	local result = table.freeze({ ok = failed == nil, error = failed, report = finalReport })
	if record.owner == owner and record.state ~= "Destroyed" then
		owner.flushOwner = nil
		record.state = "Open"
		record.lastFlush = result
		if record.pendingKeys > 0 then
			local expiry = earliestExpiry(record)
			local deadline = owner.now() + record.flushAfter
			if expiry ~= nil and expiry < deadline then deadline = expiry end
			scheduleAt(record, deadline)
		end
	end
	return result.ok, result.error, result.report
end

local function create(owner, audience, flushAfter, deferOutbound, broadcast, independent)
	local alive, problem = owner.check()
	if not alive then return nil, problem end
	if independent and (audience == nil or #audience < 1 or #audience > MAXIMUM_INDEPENDENT_RECIPIENTS) then
		return nil, Definition.error("InvalidAudience")
	end
	if owner.states == nil then
		owner.states = {}
		owner.stateKeys = 0
		owner.stateBytes = 0
	else
		owner.stateKeys = owner.stateKeys or 0
		owner.stateBytes = owner.stateBytes or 0
	end
	if #owner.states >= MAXIMUM_LANES then return nil, Definition.error("QueueLimit") end
	local recipients = if independent then table.create(#audience) else nil
	if recipients ~= nil then
		for index, player in audience do recipients[index] = { player = player } end
	end
	local record = {
		owner = owner,
		audience = if independent then nil else audience,
		recipients = recipients,
		flushAfter = flushAfter,
		deferOutbound = deferOutbound == true,
		independent = independent == true,
		broadcast = broadcast == true,
		state = "Open",
		keys = {},
		activeKeys = 0,
		pendingKeys = 0,
		pendingBodyBytes = 0,
		events = owner.events,
		timer = nil,
		timerGeneration = 0,
		serviceDeadline = nil,
		lastFlush = nil,
		terminalError = nil,
	}
	local eventHandles = {}
	for name, event in owner.events do
		if event.queue == "State" then
			local eventName = name
			local eventId = event.id
			eventHandles[name] = table.freeze({
				Put = function(_, key, priority, ...)
					return submit(record, eventName, key, priority, ...)
				end,
				Remove = function(_, key)
					if record.state == "Flushing" then return false, Definition.error("QueueBusy") end
					if record.state ~= "Open" then return false, Definition.error("QueueClosed") end
					local currentOwner = record.owner
					if currentOwner == nil then return false, Definition.error("QueueClosed") end
					if currentOwner.flushOwner ~= nil then return false, Definition.error("QueueBusy") end
					if not currentOwner.alive then return false, failLifecycle(record, currentOwner) end
					local ownerAlive, ownerProblem = currentOwner.check()
					if not ownerAlive then
						closeLane(record, currentOwner, ownerProblem)
						return false, ownerProblem
					end
					if not isKey(key) then return false, Definition.error("InvalidStateKey") end
					local slot, index = findSlot(record, eventId, key)
					if slot == nil then return true, nil end
					clearPending(currentOwner, record, slot)
					table.remove(record.keys, index)
					record.activeKeys -= 1
					currentOwner.stateKeys -= 1
					if record.pendingKeys == 0 then
						cancelTimer(record)
						record.serviceDeadline = nil
					elseif record.deferOutbound then
						bringRetryForward(record, currentOwner, currentOwner.now(), earliestExpiry(record))
					end
					return true, nil
				end,
			})
		end
	end
	local handle = table.freeze({
		events = table.freeze(eventHandles),
		Flush = function()
			return flush(record)
		end,
		GetStatus = function()
			local status = {
				state = record.state,
				activeKeys = record.activeKeys,
				pendingKeys = record.pendingKeys,
				pendingBodyBytes = record.pendingBodyBytes,
				lastFlush = record.lastFlush,
			}
			if record.independent then status.recipients = statusRecipients(record) end
			return table.freeze(status)
		end,
		Destroy = function()
			closeLane(record, record.owner, Definition.error("QueueClosed"))
		end,
	})
	owner.states[#owner.states + 1] = record
	return handle, nil
end

local function destroy(owner)
	local lanes = owner.states
	if lanes == nil then return end
	while #lanes > 0 do
		local record = lanes[#lanes]
		closeLane(record, owner, terminalError(owner))
	end
	owner.stateKeys = 0
	owner.stateBytes = 0
end

local function prune(owner, player)
	local lanes = owner.states
	if lanes == nil then return end
	for laneIndex = #lanes, 1, -1 do
		local record = lanes[laneIndex]
		if record.independent then
			local removed = false
			for recipientIndex, recipient in record.recipients do
				if recipient.player == player then
					recipient.player = nil
					removed = true
					for _, slot in record.keys do
						if slot.body ~= nil and slot.pendingRecipients ~= nil
							and slot.pendingRecipients[recipientIndex] == true then
							slot.pendingRecipients[recipientIndex] = nil
							slot.pendingRecipientCount -= 1
							if slot.pendingRecipientCount == 0 then clearPending(owner, record, slot) end
						end
					end
				end
			end
			if removed then
				local activeRecipients = 0
				for _, recipient in record.recipients do
					if recipient.player ~= nil then activeRecipients += 1 end
				end
				if activeRecipients == 0 then
					if record.deferOutbound then closeLane(record, owner, Definition.error("QueueClosed")) end
				elseif record.pendingKeys == 0 then
					cancelTimer(record)
					record.serviceDeadline = nil
				elseif record.deferOutbound then
					bringRetryForward(record, owner, owner.now(), earliestExpiry(record))
				end
			end
		else
			local audience = record.audience
			if audience ~= nil then
				local write = 1
				local removed = false
				for read = 1, #audience do
					local current = audience[read]
					if current ~= player then
						audience[write] = current
						write += 1
					else
						removed = true
					end
				end
				for index = #audience, write, -1 do audience[index] = nil end
				if removed and record.deferOutbound then
					if #audience == 0 then
						closeLane(record, owner, Definition.error("QueueClosed"))
					elseif record.pendingKeys == 0 then
						cancelTimer(record)
						record.serviceDeadline = nil
					else
						bringRetryForward(record, owner, owner.now(), earliestExpiry(record))
					end
				end
			end
		end
	end
end

return table.freeze({ create = create, destroy = destroy, prune = prune })
