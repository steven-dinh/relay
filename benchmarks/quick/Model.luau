--!strict

local Contract = require("../contracts/event-v1")
local Fixtures = require("../fixtures/event-v1")
local Comparator = require("../correctness/PayloadComparator")
local SchemaFixtures = require("./SchemaFixtures")
local ROUND_COUNT = 3

local function bounded(value: any, minimum: number, maximum: number, integer: boolean): boolean
	return type(value) == "number" and value >= minimum and value <= maximum
		and (not integer or value % 1 == 0)
end

local function selection(config: any): any
	assert(bounded(config.warmupFrames, 1, 120, true), "warmupFrames must be 1..120")
	assert(bounded(config.measuredFrames, 1, 600, true), "measuredFrames must be 1..600")
	assert(bounded(config.quietSeconds, 0.1, 3, false), "quietSeconds must be 0.1..3")
	assert(bounded(config.timeoutSeconds, 5, 120, false), "timeoutSeconds must be 5..120")
	assert(type(config.autoRun) == "boolean", "autoRun must be boolean")
	for payloadId, fields in SchemaFixtures.fields do
		if config.caseId == payloadId .. "-c2s" then
			return { kind = "Workload", id = config.caseId, payloadId = payloadId, schema = true, fieldCount = #fields,
				direction = "ClientToServer", delivery = "ReliableOrdered", schedule = "Steady",
				senderCount = 1, recipientCounts = { 1 }, messagesPerFrame = 1 }
		end
	end
	if config.caseId == "tiny-round-trip" then
		return { kind = "SeparateProbe", payloadId = "tiny", messagesPerFrame = 1 }
	end
	-- This diagnostic workload intentionally stays private to the quick runner.
	-- It uses the canonical State payload and fixture family without changing
	-- the frozen Event V1 workload contract.
	if config.caseId == "state-broadcast-burst-s2c" then
		return {
			kind = "Workload", id = config.caseId, payloadId = "state",
			direction = "ServerToClient", audience = "Broadcast",
			delivery = "ReliableOrdered", schedule = "Burst", senderCount = 1,
			recipientCounts = { 1 }, messagesPerFrame = 4,
		}
	end
	for _, workload in Contract.workloads do
		if workload.id == config.caseId then
			local result = table.clone(workload)
			result.kind = "Workload"
			return result
		end
	end
	error("unknown quick benchmark caseId", 0)
end

local function batches(config: any, selected: any, run: number): any
	local warmupCount = config.warmupFrames * selected.messagesPerFrame
	local count = warmupCount + config.measuredFrames * selected.messagesPerFrame
	assert(bounded(run, 1, math.floor(0xFFFFFFFF / count), true), "quick run sequence exhausted; Stop/Play")
	local all = {}
	if selected.schema then
		for index = 1, count do
			local expected = SchemaFixtures.generate(selected.payloadId, (run - 1) * count + index - 1)
			all[index] = { expected = expected, input = table.clone(expected) }
		end
		return { table.move(all, 1, warmupCount, 1, {}), table.move(all, warmupCount + 1, count, 1, {}) }
	end
	-- Reuse canonical Float32 fixture values; quick runs have their own sequence
	-- ranges and frame counts and are never canonical Result evidence.
	local caseId = if selected.payloadId == "tiny" then "tiny-steady-c2s" else "state-steady-c2s"
	for repetition = 1, math.ceil(count / 180) do
		local generated = Fixtures.generate(caseId, repetition)
		for _, phase in { generated.warmup, generated.measured } do
			for _, fixture in phase do
				if #all == count then break end
				local expected = Fixtures.newInput(fixture)
				expected.sequence = (run - 1) * count + #all
				table.insert(all, { expected = expected, input = table.clone(expected) })
			end
		end
	end
	return { table.move(all, 1, warmupCount, 1, {}), table.move(all, warmupCount + 1, count, 1, {}) }
end

local function runBatches(config: any, selected: any, run: number): any
	local rounds = {}
	for round = 1, ROUND_COUNT do
		rounds[round] = batches(config, selected, (run - 1) * ROUND_COUNT + round)
	end
	return rounds
end

local function adapterIndex(count: number, run: number, round: number, position: number): number
	return ((run - 1) * ROUND_COUNT + round - 1 + position - 1) % count + 1
end

local function capture(payloadId: string, expected: any): any
	local schemaFields = SchemaFixtures.fields[payloadId]
	local fields = schemaFields or Contract.payloads[payloadId].fields
	local received, times = {}, {}
	local failure: string? = nil
	local function reject()
		failure = failure or "unexpected, oversized, or malformed delivery"
		return false
	end
	local function push(envelope: any, now: number): boolean
		if failure ~= nil or #received >= #expected or type(envelope) ~= "table" then return reject() end
		local positional = envelope.kind == "Positional"
		local values = if positional then envelope.values else envelope.value
		if type(values) ~= "table" or getmetatable(values) ~= nil then return reject() end
		if positional then
			if envelope.count ~= #fields then return reject() end
		elseif envelope.kind ~= "Record" then
			return reject()
		end
		local keys = 0
		for key in next, values do
			keys += 1
			if keys > #fields then return reject() end
			if positional then
				if not bounded(key, 1, #fields, true) then return reject() end
			elseif rawget(expected[1].expected, key) == nil then
				return reject()
			end
		end
		if keys ~= #fields then return reject() end
		local copy = {}
		for index, field in fields do
			local value = rawget(values, if positional then index else field.name)
			local valueType = if schemaFields then field.type else field.valueType
			local requiredType = if valueType == "boolean" then "boolean"
				elseif valueType == "Vector3F32" then "Vector3"
				elseif valueType == "Vector2F32" then "Vector2"
				elseif valueType == "CFrame" then "CFrame"
				elseif valueType == "string" then "string" else "number"
			if typeof(value) ~= requiredType then return reject() end
			if valueType == "string" and #value > field.maximumBytes then return reject() end
			copy[field.name] = value
		end
		table.insert(received, copy)
		table.insert(times, now)
		return true
	end
	return {
		push = push,
		count = function() return #received end,
		time = function(index: number) return times[index] end,
		check = function() assert(failure == nil, failure) end,
		verify = function()
			assert(failure == nil, failure)
			assert(#received == #expected, "missing deliveries")
			for index, fixture in expected do
				assert(if schemaFields then SchemaFixtures.compare(payloadId, fixture.expected, received[index], false)
					else Comparator.compareRecord(payloadId, fixture.expected, received[index]),
					"payload mismatch, stale, duplicate, or out-of-order delivery")
			end
		end,
	}
end

local function verifyInputs(payloadId: string, inputs: any)
	for _, fixture in inputs do
		assert(if SchemaFixtures.fields[payloadId] then SchemaFixtures.compare(payloadId, fixture.expected, fixture.input, true)
			else Comparator.compareRecord(payloadId, fixture.expected, fixture.input), "adapter mutated its input")
	end
end

local function summary(samples: { number }): any
	assert(#samples > 0, "empty quick timing samples")
	local sorted, total = table.clone(samples), 0
	for _, value in samples do
		assert(bounded(value, 0, 1e9, false), "invalid quick timing sample")
		total += value
	end
	table.sort(sorted)
	local middle = math.floor(#sorted / 2)
	return {
		mean = total / #samples, p95 = sorted[math.ceil(#sorted * 0.95)],
		median = if #sorted % 2 == 0 then (sorted[middle] + sorted[middle + 1]) / 2 else sorted[middle + 1],
		min = sorted[1], max = sorted[#sorted],
	}
end

local function aggregate(rounds: { any }): any
	local samples = {
		offeredRate = {}, calls = {}, callMean = {}, callMedian = {}, callP95 = {}, floor = {},
		deliveryConfirmation = {}, acknowledgementTail = {}, receiveCallbacks = {},
		receiveCallbackMean = {}, receiveCallbackMedian = {}, receiveCallbackP95 = {},
		fps = {}, frameMean = {}, frameP95 = {}, kbps = {}, rttMean = {}, rttP95 = {},
	}
	for _, round in rounds do
		table.insert(samples.offeredRate, round.sent / round.elapsed)
		table.insert(samples.calls, round.calls.mean)
		table.insert(samples.callMean, round.calls.mean)
		if round.calls.median then table.insert(samples.callMedian, round.calls.median) end
		if round.calls.p95 then table.insert(samples.callP95, round.calls.p95) end
		table.insert(samples.floor, round.floor.mean)
		if round.deliveryConfirmation then table.insert(samples.deliveryConfirmation, round.deliveryConfirmation) end
		if round.acknowledgementTail then table.insert(samples.acknowledgementTail, round.acknowledgementTail) end
		if round.receiveCallbacks then
			table.insert(samples.receiveCallbacks, round.receiveCallbacks.mean)
			table.insert(samples.receiveCallbackMean, round.receiveCallbacks.mean)
			table.insert(samples.receiveCallbackMedian, round.receiveCallbacks.median)
			table.insert(samples.receiveCallbackP95, round.receiveCallbacks.p95)
		end
		if round.frames then
			table.insert(samples.fps, 1 / round.frames.mean)
			table.insert(samples.frameMean, round.frames.mean)
			table.insert(samples.frameP95, round.frames.p95)
			table.insert(samples.kbps, round.kbps)
		end
		if round.rtt then
			table.insert(samples.rttMean, round.rtt.mean)
			table.insert(samples.rttP95, round.rtt.p95)
		end
	end
	local result = {}
	for key, values in samples do
		if #values > 0 then result[key] = summary(values) end
	end
	return result
end

return table.freeze({
	selection = selection, batches = batches, capture = capture,
	verifyInputs = verifyInputs, summary = summary, aggregate = aggregate, roundCount = ROUND_COUNT,
	runBatches = runBatches, adapterIndex = adapterIndex,
})
