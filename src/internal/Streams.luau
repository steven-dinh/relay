local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")
local Diagnostics = require(if script then script.Parent.Diagnostics else "./Diagnostics")

local MAXIMUM_STREAMS = 64
local MAXIMUM_RATE = 60
local MINIMUM_RATE = 0.1
local MAXIMUM_KEEPALIVE = 60
local MAXIMUM_EPSILON = 1_000_000
local REFERENCE_BYTES = 8

local function recordReport(owner, reason, endpointId, delivery)
	if owner == nil or not owner.alive then return end
	local diagnostics = owner.diagnostics
	if diagnostics ~= nil then Diagnostics.report(diagnostics, reason, endpointId, delivery) end
end

local function recordSubmitted(owner, record, snapshot)
	if owner == nil or not owner.alive then return end
	local diagnostics = owner.diagnostics
	if diagnostics == nil or diagnostics.traffic == nil then return end
	local referenceCount = if snapshot.references == nil then 0 else snapshot.references.n
	Diagnostics.recordSubmitted(diagnostics, record.eventId, record.event.delivery,
		buffer.len(snapshot.body) + referenceCount * REFERENCE_BYTES)
end

local function recordSent(owner, endpointId, delivery, packet, references, handoffs, recipientCount)
	if owner == nil or not owner.alive then return end
	local diagnostics = owner.diagnostics
	if diagnostics == nil or diagnostics.traffic == nil or handoffs <= 0 then return end
	local endpointBytes = buffer.len(packet) + (if references == nil then 0 else references.n) * REFERENCE_BYTES
	Diagnostics.recordSentSingle(diagnostics, endpointId, delivery, endpointBytes + 8,
		endpointBytes, handoffs, recipientCount)
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function onlyKeys(value, ...)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local allowed = table.pack(...)
	for key in value do
		local found = false
		for index = 1, allowed.n do
			if key == allowed[index] then found = true; break end
		end
		if not found then return false end
	end
	return true
end

local function eligible(event)
	if event == nil or event.direction ~= "ServerToClient" or event.ordered ~= true
		or event.delivery ~= "Unreliable" or event.queue ~= nil or event.bitPacking == true
		or #event.fields ~= 2 then
		return false
	end
	return event.fields[1].type == "f64" and event.fields[2].type == "optional"
		and event.fields[2].value.type ~= "optional"
end

local function optionsFor(value, payloadType)
	if not onlyKeys(value, "rate", "fastRate", "keepalive", "epsilon") then return nil end
	local rate, fastRate, keepalive, epsilon = rawget(value, "rate"), rawget(value, "fastRate"),
		rawget(value, "keepalive"), rawget(value, "epsilon")
	if not finite(rate) or rate < MINIMUM_RATE or rate > MAXIMUM_RATE then return nil end
	if fastRate ~= nil and (not finite(fastRate) or fastRate <= rate or fastRate > MAXIMUM_RATE) then return nil end
	if keepalive ~= nil and (not finite(keepalive) or keepalive < 1 / rate or keepalive > MAXIMUM_KEEPALIVE) then
		return nil
	end
	if epsilon == nil then epsilon = 0 end
	if not finite(epsilon) or epsilon < 0 or epsilon > MAXIMUM_EPSILON then return nil end
	if epsilon > 0 and payloadType ~= "f32" and payloadType ~= "f64"
		and payloadType ~= "Vector2F32" and payloadType ~= "Vector3F32" then
		return nil
	end
	return {
		rate = rate,
		fastRate = fastRate,
		keepalive = if keepalive == nil then math.max(1, 1 / rate) else keepalive,
		epsilon = epsilon,
	}
end

local function cancelTimer(record)
	local timer = record.timer
	if timer ~= nil then
		record.timer = nil
		pcall(task.cancel, timer)
	end
	record.timerGeneration += 1
end

local function removeOwner(record, owner)
	local streams = if owner == nil then nil else owner.streams
	if streams == nil then return end
	for index = #streams, 1, -1 do
		if streams[index] == record then
			table.remove(streams, index)
			return
		end
	end
end

local function release(record, owner, state, problem)
	if record.state == "Destroyed" then return end
	cancelTimer(record)
	removeOwner(record, owner)
	record.owner = nil
	record.state = state
	record.lastError = problem
	record.deadline = nil
	record.deadlineKind = nil
	record.target = nil
	record.event = nil
	record.encode = nil
	record.decode = nil
	record.current = nil
	record.last = nil
	record.pendingClear = false
	record.urgent = false
	record.stopPending = false
end

local function copySnapshot(record, ...)
	local body, references
	local referenceCount = 0
	if record.event.hasReferences then
		local encoded = table.pack(record.encode(...))
		if encoded[1] ~= true or typeof(encoded[2]) ~= "buffer" then return nil end
		body = encoded[2]
		referenceCount = encoded.n - 2
		if referenceCount < 0 or referenceCount > 16 then return nil end
		if referenceCount > 0 then
			references = table.create(referenceCount)
			references.n = referenceCount
			for index = 1, referenceCount do
				local reference = encoded[index + 2]
				if typeof(reference) ~= "Instance" then return nil end
				references[index] = reference
			end
		end
	else
		local valid
		valid, body = record.encode(...)
		if valid ~= true or typeof(body) ~= "buffer" then return nil end
	end
	local headerBytes = if record.event.hasReferences then 4 else 3
	if buffer.len(body) < headerBytes + 8 or buffer.readu8(body, 0) ~= (if record.event.hasReferences then 4 else 1)
		or (record.event.hasReferences and buffer.readu8(body, 3) ~= referenceCount)
		or (not record.event.hasReferences and referenceCount ~= 0) then
		return nil
	end
	local snapshot = { body = body, references = references, clear = select(2, ...) == nil }
	if record.epsilon > 0 and not snapshot.clear then
		local valid, _, value = record.decode(body)
		if valid ~= true then return nil end
		snapshot.value = value
	end
	return snapshot
end

local function sameReferences(left, right)
	local leftCount = if left == nil then 0 else left.n
	local rightCount = if right == nil then 0 else right.n
	if leftCount ~= rightCount then return false end
	for index = 1, leftCount do
		if left[index] ~= right[index] then return false end
	end
	return true
end

local function sameSnapshot(record, left, right)
	if left == nil or right == nil then return false end
	if left == right then return true end
	if not sameReferences(left.references, right.references) then return false end
	if record.epsilon > 0 then
		local leftValue, rightValue = left.value, right.value
		if type(leftValue) == "number" then
			return math.abs(leftValue - rightValue) <= record.epsilon
		elseif typeof(leftValue) == "Vector2" then
			return math.abs(leftValue.X - rightValue.X) <= record.epsilon
				and math.abs(leftValue.Y - rightValue.Y) <= record.epsilon
		end
		return math.abs(leftValue.X - rightValue.X) <= record.epsilon
			and math.abs(leftValue.Y - rightValue.Y) <= record.epsilon
			and math.abs(leftValue.Z - rightValue.Z) <= record.epsilon
	end
	local leftBody, rightBody = left.body, right.body
	local length = buffer.len(leftBody)
	if length ~= buffer.len(rightBody) then return false end
	local stampOffset = if record.event.hasReferences then 4 else 3
	for offset = 0, length - 1 do
		if (offset < stampOffset or offset >= stampOffset + 8)
			and buffer.readu8(leftBody, offset) ~= buffer.readu8(rightBody, offset) then
			return false
		end
	end
	return true
end

local function interval(record)
	return 1 / (if record.fast then record.fastRate else record.rate)
end

local function arm(record, owner, deadline, deadlineKind)
	cancelTimer(record)
	if record.state ~= "Active" or record.owner ~= owner or not owner.alive then return end
	local generation = record.timerGeneration
	record.deadline = deadline
	record.deadlineKind = deadlineKind
	record.timer = task.delay(math.max(0, deadline - owner.now()), function()
		if record.timerGeneration ~= generation or record.state ~= "Active" then return end
		record.timer = nil
		local currentDeadline = record.deadline
		local currentDeadlineKind = record.deadlineKind
		local currentOwner = record.owner
		if currentOwner == nil then return end
		if not currentOwner.alive then
			release(record, currentOwner, "Destroyed", currentOwner.terminalError or Definition.error("Destroyed"))
			return
		end
		local valid, problem = currentOwner.check()
		if not valid then
			if record.state ~= "Destroyed" then release(record, currentOwner, "Destroyed", problem) end
			return
		end
		local now = currentOwner.now()
		if currentDeadline ~= nil and now < currentDeadline then
			arm(record, currentOwner, currentDeadline, currentDeadlineKind)
			return
		end
		record.deadline = nil
		record.deadlineKind = nil
		local beforeGeneration = record.timerGeneration
		local selected = record.current
		if selected == nil then return end
		local changed = selected.clear or not sameSnapshot(record, selected, record.last)
		local keepaliveDue = record.lastSentLocal == nil or now >= record.lastSentLocal + record.keepalive
		local retryingBudget = record.lastError == Definition.error("OutboundRateLimited")
		if not changed and not record.urgent and not record.stopPending and not keepaliveDue and not retryingBudget then
			arm(record, currentOwner, record.lastSentLocal + record.keepalive, "keepalive")
			return
		end
		local selectedRevision = record.revision
		local attempt = record.attempts + 1
		record.attempts = attempt
		local attemptedUrgent = record.urgent
		record.urgent = false
		local timestamp = currentOwner.serverNow()
		if not finite(timestamp) or timestamp < 0
			or timestamp < record.minimumTime or timestamp > record.maximumTime then
			record.lastError = Definition.error("InvalidPayload")
			record.state = "Paused"
			return
		end
		if timestamp == 0 then timestamp = 0 end
		local eventId, delivery = record.eventId, record.event.delivery
		record.lastAttemptLocal = now
		local ok, handoffError, handoffs, recipientCount = currentOwner.streamHandoff(
			record, selected.body, selected.references, timestamp)
		handoffs = handoffs or (if ok then 1 else 0)
		recordSent(currentOwner, eventId, delivery, selected.body, selected.references, handoffs, recipientCount)
		if not ok and handoffError ~= nil and handoffError.code ~= "TransportFailure"
			and handoffError.code ~= "OutboundRateLimited" then
			recordReport(currentOwner, handoffError.code, eventId, delivery)
		end
		if record.state == "Destroyed" or record.owner ~= currentOwner then return end
		if ok then
			if attempt > record.lastCommittedAttempt then
				record.lastCommittedAttempt = attempt
				record.last = if selected.clear then nil else selected
				record.lastSentTime = timestamp
				record.lastSentLocal = currentOwner.now()
				record.stopPending = changed and not selected.clear
			end
			if record.revision == selectedRevision then record.lastError = nil end
			if selected.clear and record.revision == selectedRevision and record.current == selected
				and attempt >= record.lastCommittedAttempt then
				cancelTimer(record)
				record.current = nil
				record.last = nil
				record.pendingClear = false
				record.stopPending = false
				record.state = "Idle"
				return
			end
		elseif handoffError ~= nil and handoffError.code == "InvalidPlayer" then
			release(record, currentOwner, "Destroyed", handoffError)
			return
		elseif handoffError == Definition.error("OutboundRateLimited") then
			record.urgent = record.urgent or attemptedUrgent
			record.lastError = handoffError
		elseif handoffError == Definition.error("InvalidPayload")
			or handoffError == Definition.error("TransportFailure") then
			if record.revision == selectedRevision then
				cancelTimer(record)
				record.state = "Paused"
				record.lastError = handoffError
				return
			end
		else
			if handoffError ~= nil and handoffError.code == "Destroyed" then
				release(record, currentOwner, "Destroyed", handoffError)
				return
			end
			record.urgent = record.urgent or attemptedUrgent
		end
		if record.state == "Active" and record.owner == currentOwner and record.timer == nil
			and record.timerGeneration == beforeGeneration then
			local after = currentOwner.now()
			local nextDeadline, nextDeadlineKind
			if handoffError == Definition.error("OutboundRateLimited") then
				nextDeadline = after + interval(record)
				nextDeadlineKind = "rate"
			elseif ok and selected.clear then
				nextDeadline = nil
			elseif ok and record.stopPending then
				nextDeadline = after + interval(record)
				nextDeadlineKind = "rate"
			else
				if record.lastSentLocal == nil then
					nextDeadline = after + interval(record)
					nextDeadlineKind = "rate"
				else
					nextDeadline = record.lastSentLocal + record.keepalive
					nextDeadlineKind = "keepalive"
				end
			end
			if nextDeadline ~= nil then arm(record, currentOwner, nextDeadline, nextDeadlineKind) end
		end
	end)
end

local function armEarlier(record, owner, deadline, deadlineKind)
	if record.timer ~= nil and record.deadline ~= nil and record.deadline <= deadline then return end
	arm(record, owner, deadline, deadlineKind)
end

local function dueAfterRate(record, now)
	if record.lastAttemptLocal == nil then return now end
	return math.max(now, record.lastAttemptLocal + interval(record))
end

local function scheduleSubmission(record, now)
	armEarlier(record, record.owner, dueAfterRate(record, now), "rate")
end

local function scheduleNextStep(record, now)
	if record.timer ~= nil and record.deadline ~= nil and record.deadline <= now then
		record.deadlineKind = "nextStep"
		return
	end
	arm(record, record.owner, now, "nextStep")
end

local function create(owner, event, target, broadcast, options, encode, decode)
	if not eligible(event) then return nil, Definition.error("InvalidOptions") end
	local alive, problem = owner.check()
	if not alive then return nil, problem end
	if not broadcast and not owner.playerActive(target) then return nil, Definition.error("InvalidPlayer") end
	local payloadType = event.fields[2].value.type
	local parsed = optionsFor(options, payloadType)
	if parsed == nil then return nil, Definition.error("InvalidOptions") end
	local timeField = event.fields[1]
	local now = owner.serverNow()
	if not finite(timeField.minimum) or not finite(timeField.maximum) or timeField.minimum > 0
		or timeField.maximum < 0 or not finite(now) or now < 0
		or now < timeField.minimum or now > timeField.maximum then
		return nil, Definition.error("InvalidOptions")
	end
	local streams = owner.streams
	local count = if streams == nil then 0 else #streams
	if count >= MAXIMUM_STREAMS then return nil, Definition.error("QueueLimit") end
	local existingStreams = if streams == nil then {} else streams
	for _, existing in existingStreams do
		if existing.eventId == event.id and (existing.target == nil or target == nil or existing.target == target) then
			return nil, Definition.error("QueueBusy")
		end
	end
	local record = {
		owner = owner,
		event = event,
		eventId = event.id,
		target = target,
		encode = encode,
		decode = decode,
		minimumTime = timeField.minimum,
		maximumTime = timeField.maximum,
		rate = parsed.rate,
		fastRate = parsed.fastRate,
		keepalive = parsed.keepalive,
		epsilon = parsed.epsilon,
		state = "Idle",
		fast = false,
		pendingClear = false,
		urgent = false,
		stopPending = false,
		timer = nil,
		timerGeneration = 0,
		deadline = nil,
		deadlineKind = nil,
		lastAttemptLocal = nil,
		lastSentLocal = nil,
		lastSentTime = nil,
		lastError = nil,
		current = nil,
		last = nil,
		revision = 0,
		attempts = 0,
		lastCommittedAttempt = 0,
	}
	record.handle = table.freeze({
		Set = function(_, value)
			if record.state == "Destroyed" then return false, Definition.error("Destroyed") end
			if value == nil then
				recordReport(record.owner, "InvalidPayload", record.eventId, record.event.delivery)
				return false, Definition.error("InvalidPayload")
			end
			local resuming = record.state == "Paused"
			local snapshot = copySnapshot(record, 0, value)
			if snapshot == nil then
				recordReport(record.owner, "InvalidPayload", record.eventId, record.event.delivery)
				return false, Definition.error("InvalidPayload")
			end
			local currentOwner = record.owner
			if currentOwner == nil or not currentOwner.alive then return false, Definition.error("Destroyed") end
			recordSubmitted(currentOwner, record, snapshot)
			record.current = snapshot
			record.pendingClear = false
			record.revision += 1
			record.state = "Active"
			if resuming then record.urgent = true end
			record.lastError = nil
			scheduleSubmission(record, currentOwner.now())
			return true, nil
		end,
		Clear = function()
			if record.state == "Destroyed" then return false, Definition.error("Destroyed") end
			local snapshot = copySnapshot(record, 0, nil)
			if snapshot == nil then
				recordReport(record.owner, "InvalidPayload", record.eventId, record.event.delivery)
				return false, Definition.error("InvalidPayload")
			end
			local currentOwner = record.owner
			if currentOwner == nil or not currentOwner.alive then return false, Definition.error("Destroyed") end
			recordSubmitted(currentOwner, record, snapshot)
			record.current = snapshot
			record.pendingClear = true
			record.revision += 1
			record.state = "Active"
			record.lastError = nil
			scheduleNextStep(record, currentOwner.now())
			return true, nil
		end,
		Urgent = function()
			if record.state == "Destroyed" then return false, Definition.error("Destroyed") end
			if record.state ~= "Active" then return true, nil end
			record.urgent = true
			if record.lastError ~= Definition.error("OutboundRateLimited") then
				scheduleNextStep(record, record.owner.now())
			end
			return true, nil
		end,
		SetFast = function(_, fast)
			if record.state == "Destroyed" then return false, Definition.error("Destroyed") end
			if type(fast) ~= "boolean" or (fast and record.fastRate == nil) then
				return false, Definition.error("InvalidOptions")
			end
			record.fast = fast
			if record.state == "Active" then
				local currentOwner = record.owner
				local now = currentOwner.now()
				if not fast then
					if record.timer == nil then
						scheduleSubmission(record, now)
					elseif record.deadlineKind == "rate" and record.lastAttemptLocal ~= nil then
						local deadline = math.max(now, record.lastAttemptLocal + interval(record))
						if record.deadline == nil or record.deadline < deadline then
							arm(record, currentOwner, deadline, "rate")
						end
					end
				else
					scheduleSubmission(record, now)
				end
			end
			return true, nil
		end,
		Destroy = function()
			release(record, record.owner, "Destroyed", nil)
		end,
		GetStatus = function()
			local pending = record.pendingClear or record.urgent or record.stopPending
			if not pending and record.state == "Active" and record.current ~= nil then
				pending = not sameSnapshot(record, record.current, record.last)
			end
			return table.freeze({
				state = record.state,
				fast = record.fast,
				pending = pending,
				lastError = record.lastError,
				lastSentTime = record.lastSentTime,
			})
		end,
	})
	if streams == nil then
		streams = {}
		owner.streams = streams
	end
	table.insert(streams, record)
	return record.handle, nil
end

local function destroy(owner)
	local streams = owner.streams
	if streams == nil then return end
	while #streams > 0 do
		local record = streams[#streams]
		release(record, owner, "Destroyed", owner.terminalError or Definition.error("Destroyed"))
	end
	owner.streams = nil
end

local function prune(owner, player)
	local streams = owner.streams
	if streams == nil then return end
	for index = #streams, 1, -1 do
		local record = streams[index]
		if record.target == player then
			release(record, owner, "Destroyed", Definition.error("InvalidPlayer"))
		end
	end
end

return table.freeze({
	eligible = eligible,
	create = create,
	destroy = destroy,
	prune = prune,
})
