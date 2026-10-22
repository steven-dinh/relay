local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")
local BatchFrame = require(if script then script.Parent.BatchFrame else "./BatchFrame")

local MAXIMUM_RECORDS = 32
local MAXIMUM_PENDING_RECORDS = 128
local MAXIMUM_REFERENCES = 16
local MAXIMUM_PENDING_UNITS = 32_768
local REFERENCE_BYTES = 8
local REFERENCE_CODEC_VERSION = 4
local RELIABLE_LIMIT = 8_192
local UNRELIABLE_LIMIT = 900
local MINIMUM_INTERVAL = 1 / 60
local MAXIMUM_INTERVAL = 0.1
local ZERO_REPORT = table.freeze({
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

local function result(ok, problem, finalReport)
	return table.freeze({ ok = ok, error = problem, report = finalReport })
end

local function cancelTimer(record)
	local timer = record.timer
	if timer == nil then return end
	record.timer = nil
	record.timerGeneration += 1
	pcall(task.cancel, timer)
end

local function clearOwner(record, owner)
	if owner.pacedBatcher == record then owner.pacedBatcher = nil end
	if owner.flushOwner == record then owner.flushOwner = nil end
end

local function clearRecords(record)
	table.clear(record.records)
	record.count = 0
	record.units = 0
	record.nextDue = nil
end

local function terminal(record, owner, problem)
	if record.state == "Terminal" then return end
	cancelTimer(record)
	if owner ~= nil then clearOwner(record, owner) end
	record.owner = nil
	record.terminalError = problem
	clearRecords(record)
	record.state = "Terminal"
	record.lastStep = result(false, problem, ZERO_REPORT)
end

local function terminalError(record, owner)
	return record.terminalError or (owner and owner.terminalError) or Definition.error("Destroyed")
end

local step

local function schedule(record, delay)
	if record.manual or record.state ~= "Open" or record.count == 0 or record.timer ~= nil then return end
	local owner = record.owner
	if owner == nil or not owner.alive then return end
	record.timerGeneration += 1
	local generation = record.timerGeneration
	record.timer = task.delay(delay, function()
		if record.timerGeneration ~= generation or record.state ~= "Open" then return end
		record.timer = nil
		step(record)
	end)
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
	local format = buffer.readu8(body, 0)
	if format == REFERENCE_CODEC_VERSION then
		if buffer.len(body) < 4 or buffer.readu8(body, 3) ~= referenceCount then return nil end
	elseif referenceCount ~= 0 then
		return nil
	end
	if references ~= nil or format == REFERENCE_CODEC_VERSION then
		return { body = body, references = references }, referenceCount, format == REFERENCE_CODEC_VERSION
	end
	return body, 0, false
end

local function eventRecord(event, ...)
	local encoded, referenceCount, referenceFormat = snapshotEncode(event, ...)
	if encoded == nil then return nil end
	local body = if typeof(encoded) == "buffer" then encoded else encoded.body
	local bodyBytes = buffer.len(body)
	local delivery = event.delivery
	local unreliable = delivery == "Unreliable"
	local limit = if unreliable then UNRELIABLE_LIMIT else RELIABLE_LIMIT
	local frameHeaderBytes = if referenceFormat then 4 else 3
	local recordBytes = frameHeaderBytes + 2 + bodyBytes + referenceCount * REFERENCE_BYTES
	if recordBytes > limit then return false end
	return {
		delivery = delivery,
		body = body,
		references = if typeof(encoded) == "buffer" then nil else encoded.references,
		referenceCount = referenceCount,
		referenceFormat = referenceFormat,
		units = bodyBytes + referenceCount * REFERENCE_BYTES,
	}
end

local function validOptions(interval, options)
	if type(interval) ~= "number" or not (interval >= MINIMUM_INTERVAL and interval <= MAXIMUM_INTERVAL) then
		return false
	end
	if options == nil then return true end
	if type(options) ~= "table" or getmetatable(options) ~= nil then return false end
	for key in options do
		if key ~= "manual" then return false end
	end
	return options.manual == nil or type(options.manual) == "boolean"
end

local function noWork(record)
	return report(0, 0, 0, 0, record.count)
end

local function selectedForChannel(record, delivery, limit, selectedSet)
	local rows = table.create(MAXIMUM_RECORDS)
	local count, frameBytes, referenceCount, hasReferenceFormat, units = 0, 3, 0, false, 0
	local blocked = false
	for index = 1, record.count do
		local queued = record.records[index]
		if queued.delivery == delivery and not blocked then
			local nextReferenceFormat = hasReferenceFormat or queued.referenceFormat
			local nextFrameBytes = frameBytes + 2 + buffer.len(queued.body)
				+ queued.referenceCount * REFERENCE_BYTES
				+ (if nextReferenceFormat and not hasReferenceFormat then 1 else 0)
			if count >= MAXIMUM_RECORDS or referenceCount + queued.referenceCount > MAXIMUM_REFERENCES
				or nextFrameBytes > limit then
				blocked = true
			else
				count += 1
				frameBytes = nextFrameBytes
				referenceCount += queued.referenceCount
				hasReferenceFormat = nextReferenceFormat
				units += queued.units
				rows[count] = if queued.referenceFormat then { body = queued.body, references = queued.references }
					else queued.body
				selectedSet[queued] = true
			end
		end
	end
	return rows, count, units
end

local function consumeSelected(record, selectedSet)
	local write = 1
	for read = 1, record.count do
		local queued = record.records[read]
		if not selectedSet[queued] then
			record.records[write] = queued
			write += 1
		end
	end
	for index = write, record.count do record.records[index] = nil end
	record.count = write - 1
end

step = function(record)
	if record.state ~= "Open" then
		local problem = terminalError(record, record.owner)
		local last = record.lastStep
		return false, problem, if last then last.report else ZERO_REPORT
	end
	local owner = record.owner
	if owner == nil or not owner.alive then
		local problem = terminalError(record, owner)
		terminal(record, owner, problem)
		return false, problem, ZERO_REPORT
	end
	if record.count == 0 then
		local finalReport = noWork(record)
		record.lastStep = result(true, nil, finalReport)
		return true, nil, finalReport
	end
	local now = owner.now()
	if record.nextDue ~= nil and now < record.nextDue then
		local finalReport = noWork(record)
		record.lastStep = result(true, nil, finalReport)
		schedule(record, record.nextDue - now)
		return true, nil, finalReport
	end
	cancelTimer(record)
	local alive, problem = owner.check()
	if not alive then
		problem = problem or terminalError(record, owner)
		terminal(record, owner, problem)
		return false, problem, ZERO_REPORT
	end
	if record.state ~= "Open" or record.owner ~= owner or owner.pacedBatcher ~= record then
		problem = terminalError(record, owner)
		return false, problem, ZERO_REPORT
	end
	if owner.flushOwner ~= nil then
		record.nextDue = now + record.interval
		local busyReport = noWork(record)
		local busyResult = result(false, Definition.error("QueueBusy"), busyReport)
		record.lastStep = busyResult
		schedule(record, record.interval)
		return busyResult.ok, busyResult.error, busyResult.report
	end
	owner.flushOwner = record
	alive, problem = owner.check()
	if not alive or record.state ~= "Open" or record.owner ~= owner or owner.pacedBatcher ~= record then
		problem = problem or terminalError(record, owner)
		terminal(record, owner, problem)
		return false, problem, ZERO_REPORT
	end

	local selectedSet = {}
	local reliableRows, reliableCount, reliableUnits = selectedForChannel(
		record, "Reliable", RELIABLE_LIMIT, selectedSet)
	local unreliableRows, unreliableCount, unreliableUnits = selectedForChannel(
		record, "Unreliable", UNRELIABLE_LIMIT, selectedSet)
	local reliablePacket, reliableReferences
	local unreliablePacket, unreliableReferences
	if reliableCount > 0 then
		reliablePacket, reliableReferences = BatchFrame.wrap(1, reliableRows, RELIABLE_LIMIT)
	end
	if unreliableCount > 0 then
		unreliablePacket, unreliableReferences = BatchFrame.wrap(1, unreliableRows, UNRELIABLE_LIMIT)
	end
	if (reliableCount > 0 and reliablePacket == nil) or (unreliableCount > 0 and unreliablePacket == nil) then
		table.clear(selectedSet)
		table.clear(reliableRows)
		table.clear(unreliableRows)
		local failedReport = report(0, 0, 0, 0, 0)
		local failure = Definition.error("TransportFailure")
		terminal(record, owner, failure)
		record.lastStep = result(false, failure, failedReport)
		return false, failure, failedReport
	end

	local selected = reliableCount + unreliableCount
	consumeSelected(record, selectedSet)
	record.units -= reliableUnits + unreliableUnits
	table.clear(selectedSet)
	table.clear(reliableRows)
	table.clear(unreliableRows)
	local reliableHandoffs, unreliableHandoffs, logicalHandoffs = 0, 0, 0
	local failed
	local function handoff(delivery, packet, references, count)
		local ok, handoffError, handoffs = owner.handoff(delivery, packet, nil, references)
		if delivery == "Reliable" then
			reliableHandoffs += handoffs
		else
			unreliableHandoffs += handoffs
		end
		logicalHandoffs += handoffs * count
		if not ok then return handoffError or Definition.error("TransportFailure") end
		return nil
	end

	if reliableCount > 0 then
		failed = handoff("Reliable", reliablePacket, reliableReferences, reliableCount)
	end
	if failed == nil and (record.state ~= "Open" or record.owner ~= owner or owner.pacedBatcher ~= record
		or not owner.alive) then
		failed = terminalError(record, owner)
	end
	if failed == nil and unreliableCount > 0 then
		failed = handoff("Unreliable", unreliablePacket, unreliableReferences, unreliableCount)
	end
	reliablePacket, reliableReferences, unreliablePacket, unreliableReferences = nil, nil, nil, nil
	local finalReport = report(reliableHandoffs, unreliableHandoffs, logicalHandoffs, selected, record.count)
	if failed == nil and (record.state ~= "Open" or record.owner ~= owner or owner.pacedBatcher ~= record
		or not owner.alive) then
		failed = terminalError(record, owner)
	end
	if failed ~= nil then
		if record.state ~= "Terminal" then terminal(record, owner, failed) end
		finalReport = report(reliableHandoffs, unreliableHandoffs, logicalHandoffs, selected, 0)
		local failedResult = result(false, failed, finalReport)
		record.lastStep = failedResult
		return failedResult.ok, failedResult.error, failedResult.report
	end
	if owner.flushOwner == record then owner.flushOwner = nil end
	local stepNow = owner.now()
	if record.count > 0 then
		record.nextDue = stepNow + record.interval
		schedule(record, record.interval)
	else
		record.nextDue = nil
	end
	local completed = result(true, nil, finalReport)
	record.lastStep = completed
	return completed.ok, completed.error, completed.report
end

local function submit(record, eventName, ...)
	if record.state ~= "Open" then return false, Definition.error("QueueClosed") end
	local owner = record.owner
	if owner == nil or owner.pacedBatcher ~= record then return false, Definition.error("QueueClosed") end
	if not owner.alive then
		local problem = terminalError(record, owner)
		terminal(record, owner, problem)
		return false, problem
	end
	if owner.flushOwner ~= nil then return false, Definition.error("QueueBusy") end
	local alive, problem = owner.check()
	if not alive then
		problem = problem or terminalError(record, owner)
		terminal(record, owner, problem)
		return false, problem
	end
	if record.count >= MAXIMUM_PENDING_RECORDS then return false, Definition.error("QueueFull") end
	local encoded = eventRecord(record.events[eventName], ...)
	if encoded == nil then return false, Definition.error("InvalidPayload") end
	if encoded == false or record.units + encoded.units > MAXIMUM_PENDING_UNITS then
		return false, Definition.error("QueueFull")
	end
	local first = record.count == 0
	record.count += 1
	record.units += encoded.units
	record.records[record.count] = encoded
	if first then
		record.nextDue = owner.now() + record.interval
		schedule(record, record.interval)
	end
	return true, nil
end

local function create(owner, interval, options)
	if not validOptions(interval, options) then return nil, Definition.error("InvalidOptions") end
	local alive, problem = owner.check()
	if not alive then return nil, problem end
	if owner.pacedBatcher ~= nil then return nil, Definition.error("QueueLimit") end
	local record = {
		owner = owner,
		interval = interval,
		manual = options ~= nil and options.manual == true,
		state = "Open",
		records = table.create(MAXIMUM_PENDING_RECORDS),
		count = 0,
		units = 0,
		timer = nil,
		timerGeneration = 0,
		nextDue = nil,
		events = owner.events,
		lastStep = nil,
		terminalError = nil,
	}
	local eventHandles = {}
	for name in owner.events do
		local eventName = name
		eventHandles[name] = table.freeze({
			Send = function(_, ...)
				return submit(record, eventName, ...)
			end,
		})
	end
	local handle = table.freeze({
		events = table.freeze(eventHandles),
		Step = function()
			return step(record)
		end,
		GetStatus = function()
			return table.freeze({
				state = record.state,
				pendingRecords = record.count,
				pendingUnits = record.units,
				manual = record.manual,
				lastStep = record.lastStep,
			})
		end,
		Destroy = function()
			if record.state == "Open" then terminal(record, record.owner, Definition.error("Cancelled")) end
		end,
	})
	owner.pacedBatcher = record
	return handle, nil
end

local function destroy(owner)
	local record = owner.pacedBatcher
	if record == nil then return end
	terminal(record, owner, terminalError(record, owner))
end

return table.freeze({ create = create, destroy = destroy })
