--!strict

local Comparator = require("../correctness/PayloadComparator")
local METADATA_KEYS = { "kind", "sender" }
local RECORD_KEYS = { "kind", "value" }
local POSITIONAL_KEYS = { "kind", "values", "count" }

local function exactKeys(value: any, keys: { string }): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for _, key in keys do
		if rawget(value, key) == nil then return false end
	end
	local count = 0
	for _ in next, value do
		count += 1
		if count > #keys then return false end
	end
	return count == #keys
end

local function new(expectedSender: any)
	assert(expectedSender ~= nil, "expected sender is required")
	local active: any = nil
	local received = 0
	local observed = 0
	local failure: string? = nil

	local function assertHealthy()
		if failure ~= nil then error(failure, 0) end
	end

	local function observe(...: any)
		assert(active ~= nil, "delivery outside an active phase")
		assert(select("#", ...) == 2, "delivery argument count mismatch")
		local envelope, metadata = ...
		assert(exactKeys(metadata, METADATA_KEYS), "invalid delivery metadata")
		assert(metadata.kind == "ClientToServer" and rawequal(metadata.sender, expectedSender), "wrong delivery sender or direction")
		local sample = active[received + 1]
		assert(sample ~= nil, "extra delivery")
		assert(type(envelope) == "table" and getmetatable(envelope) == nil, "invalid delivery envelope")
		local valid
		if rawget(envelope, "kind") == "Record" then
			assert(exactKeys(envelope, RECORD_KEYS), "invalid record envelope")
			valid = Comparator.compareRecord(sample.payloadId, sample.expected, envelope.value)
		elseif rawget(envelope, "kind") == "Positional" then
			assert(exactKeys(envelope, POSITIONAL_KEYS), "invalid positional envelope")
			valid = Comparator.compareCapturedPositional(sample.payloadId, sample.expected, envelope.values, envelope.count)
		else
			error("unknown delivery envelope", 0)
		end
		assert(valid, "delivery payload or sequence mismatch")
		received += 1
	end

	return table.freeze({
		arm = function(samples: any)
			assertHealthy()
			assert(active == nil, "previous phase must be closed")
			active = samples
			received = 0
		end,
		sink = function(...: any)
			observed += 1
			if failure ~= nil then return end
			local ok, problem = pcall(observe, ...)
			if not ok then
				failure = if type(problem) == "string" then string.sub(problem, 1, 512) else "delivery observer exception"
			end
		end,
		count = function() return received end,
		total = function() return observed end,
		close = function()
			assertHealthy()
			assert(active ~= nil, "no active phase")
			assert(received == #active, "missing deliveries")
			active = nil
		end,
		assertHealthy = assertHealthy,
	})
end

return table.freeze({ new = new })
