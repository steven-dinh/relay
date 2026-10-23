-- Shared native fixtures for the focused C03-C06 proof mode.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local BatchFrame = require(ReplicatedStorage.Relay.internal.BatchFrame)
local schema = Relay.schema

local OBJECTS_NAME = "RelayCompetitiveObjects"

local function prepare()
	local root = ReplicatedStorage:FindFirstChild(OBJECTS_NAME)
	if root == nil then
		root = Instance.new("Folder")
		root.Name = OBJECTS_NAME
		root.Parent = ReplicatedStorage
		local part = Instance.new("Part")
		part.Name = "Reference"
		part.Anchored = true
		part.Parent = root
	end
	local part = root:FindFirstChild("Reference")
	assert(part ~= nil and part:IsA("Part"), "competitive reference Instance")
	return part, root
end

local function define(spec, label)
	local token, failure = Relay.define(spec)
	assert(token ~= nil, failure and failure.message or label)
	return token
end

local function createPaced()
	return define({
		name = "RelayCompetitivePacedProof",
		version = 1,
		events = {
			ReliableInput = { id = 1, direction = "ClientToServer", queue = "Batch", fields = {
				schema.field("sequence", schema.u8()),
				schema.field("part", schema.Instance("Part")),
			} },
			UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", queue = "Batch", fields = {
				schema.field("sequence", schema.u8()),
				schema.field("part", schema.Instance("Part")),
			} },
		},
	}, "competitive paced definition")
end

local function createIndependent()
	return define({
		name = "RelayCompetitiveIndStateProof",
		version = 1,
		outboundBytes = { capacity = 32, refillPerSecond = 18 },
		events = {
			Drain = { id = 1, direction = "ServerToClient", fields = {
				schema.field("value", schema.u8()),
			} },
			ReliableState = { id = 2, direction = "ServerToClient", queue = "State", fields = {
				schema.field("value", schema.u8()),
			} },
			UnreliableState = { id = 3, direction = "ServerToClient", delivery = "Unreliable", queue = "State", fields = {
				schema.field("value", schema.u8()),
			} },
			SlowState = { id = 4, direction = "ServerToClient", queue = "State", fields = {
				schema.field("value", schema.string(64)),
			} },
		},
	}, "competitive independent State definition")
end

local function timestampField()
	return schema.field("serverTime", schema.f64(0, 4_503_599_627_370_496))
end

local function timestampFields(payload)
	return { timestampField(), schema.field("value", payload or schema.u8()) }
end

local function timestampPacket(eventId, serverTime, value)
	local packet = buffer.create(12)
	buffer.writeu8(packet, 0, 1)
	buffer.writeu16(packet, 1, eventId)
	buffer.writef64(packet, 3, serverTime)
	buffer.writeu8(packet, 11, value)
	return packet
end

local function codecByte(packet, eventId)
	if typeof(packet) ~= "buffer" or buffer.len(packet) ~= 4
		or buffer.readu8(packet, 0) ~= 1 or buffer.readu16(packet, 1) ~= eventId then
		return nil
	end
	return buffer.readu8(packet, 3)
end

local function createTimestamps()
	return define({
		name = "RelayCompetitiveTimestampProof",
		version = 1,
		events = {
			ReliableInput = { id = 1, direction = "ClientToServer", timestampWindow = 2,
				fields = timestampFields() },
			UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", timestampWindow = 2,
				fields = timestampFields() },
			OrderedInput = { id = 3, direction = "ClientToServer", delivery = "OrderedUnreliable", timestampWindow = 2,
				fields = timestampFields() },
			BatchInput = { id = 4, direction = "ClientToServer", queue = "Batch", timestampWindow = 2,
				fields = timestampFields() },
			StateInput = { id = 5, direction = "ClientToServer", queue = "State", timestampWindow = 2,
				fields = { timestampField(), schema.field("value", schema.string(16)) } },
		},
	}, "competitive timestamp definition")
end

local function createDiagnostics()
	return define({
		name = "RelayCompetitiveDiagnosticsProof",
		version = 1,
		readiness = true,
		events = {
			Input = { id = 1, direction = "ClientToServer", fields = {
				schema.field("value", schema.u8()),
			} },
			UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", fields = {
				schema.field("value", schema.u8()),
			} },
			BatchInput = { id = 3, direction = "ClientToServer", queue = "Batch", fields = {
				schema.field("value", schema.u8()),
			} },
			Output = { id = 4, direction = "ServerToClient", fields = {
				schema.field("value", schema.u8()),
			} },
			UnreliableOutput = { id = 5, direction = "ServerToClient", delivery = "Unreliable", fields = {
				schema.field("value", schema.u8()),
			} },
			BatchOutput = { id = 6, direction = "ServerToClient", queue = "Batch", fields = {
				schema.field("value", schema.u8()),
			} },
			StateOutput = { id = 7, direction = "ServerToClient", queue = "State", fields = {
				schema.field("value", schema.u8()),
			} },
		},
		requests = {
			Inspect = schema.request(100, { schema.field("value", schema.u8()) }, schema.u8()),
		},
	}, "competitive diagnostics definition")
end

local function timestampBatch(eventId, rows)
	assert(type(rows) == "table" and #rows >= 1 and #rows <= 32, "timestamp batch row bound")
	local bodyBytes = 12
	local packet = buffer.create(3 + #rows * (2 + bodyBytes))
	buffer.writeu8(packet, 0, 2)
	buffer.writeu8(packet, 1, 1)
	buffer.writeu8(packet, 2, #rows)
	local offset = 3
	for _, row in rows do
		buffer.writeu16(packet, offset, bodyBytes)
		buffer.writeu8(packet, offset + 2, 1)
		buffer.writeu16(packet, offset + 3, eventId)
		buffer.writef64(packet, offset + 5, row.serverTime)
		buffer.writeu8(packet, offset + 13, row.value)
		offset += 2 + bodyBytes
	end
	return packet
end

local function malformedTimestampBatch(eventId, rows)
	assert(#rows >= 2, "malformed timestamp frame requires a final row")
	local packet = timestampBatch(eventId, rows)
	local finalPrefix = 3 + (#rows - 1) * (2 + 12)
	buffer.writeu16(packet, finalPrefix, 13)
	return packet
end

local function timestampStateFrame(eventId, rows)
	assert(type(rows) == "table" and #rows >= 1 and #rows <= 32, "timestamp State row bound")
	local bodies = table.create(#rows)
	for index, row in rows do
		local value = row.value
		assert(type(value) == "string" and #value <= 16, "timestamp State value bound")
		local body = buffer.create(13 + #value)
		buffer.writeu8(body, 0, 1)
		buffer.writeu16(body, 1, eventId)
		buffer.writef64(body, 3, row.serverTime)
		buffer.writeu16(body, 11, #value)
		buffer.writestring(body, 13, value, #value)
		bodies[index] = body
	end
	return assert(BatchFrame.wrap(2, bodies, 8_192))
end

local function orderedTimestampPacket(eventId, generation, sequence, serverTime, value)
	local packet = buffer.create(20)
	buffer.writeu8(packet, 0, 3)
	buffer.writeu16(packet, 1, eventId)
	buffer.writeu32(packet, 3, generation)
	buffer.writeu32(packet, 7, sequence)
	buffer.writef64(packet, 11, serverTime)
	buffer.writeu8(packet, 19, value)
	return packet
end

local function bytes(packet)
	local result = table.create(buffer.len(packet))
	for offset = 0, buffer.len(packet) - 1 do result[offset + 1] = buffer.readu8(packet, offset) end
	return result
end

local function sameValue(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return left == right end
	local leftCount, rightCount = 0, 0
	for key, value in left do
		leftCount += 1
		if not sameValue(value, right[key]) then return false end
	end
	for _ in right do rightCount += 1 end
	return leftCount == rightCount
end

local function diagnosticsStable(afterDestroy, afterLateWork)
	if type(afterDestroy) ~= "table" or type(afterLateWork) ~= "table" then return false end
	for key, value in afterDestroy do
		if key ~= "state" and key ~= "inFlight" and not sameValue(value, afterLateWork[key]) then return false end
	end
	for key in afterLateWork do
		if key ~= "state" and key ~= "inFlight" and afterDestroy[key] == nil then return false end
	end
	return true
end

local function rawBatchReceipt(channel, endpoint, packet, ...)
	if endpoint ~= 0 or typeof(packet) ~= "buffer" then return nil end
	local arguments = table.pack(...)
	local sidecars = { n = arguments.n }
	for index = 1, arguments.n do sidecars[index] = arguments[index] end
	local limit = if channel == "Reliable" then 8_192 else 900
	local header = BatchFrame.header(packet, limit, sidecars)
	if header == nil then return nil end
	assert(header.kind == 1 or header.kind == 2, "competitive actual BatchFrame kind")
	assert(header.count <= 32 and header.referenceCount <= 16
		and buffer.len(packet) + header.referenceCount * 8 <= limit, "competitive frame caps")
	local references = table.create(arguments.n)
	for index = 1, arguments.n do
		local value = arguments[index]
		assert(typeof(value) == "Instance", "competitive sidecar Instance")
		references[index] = { className = value.ClassName, name = value.Name, path = value:GetFullName() }
	end
	local records = table.create(header.count)
	local offset = if header.format == 5 then 4 else 3
	for index = 1, header.count do
		assert(offset <= buffer.len(packet) - 2, "competitive record length prefix")
		local bodyBytes = buffer.readu16(packet, offset)
		local bodyOffset = offset + 2
		assert(bodyBytes >= 3 and bodyBytes <= buffer.len(packet) - bodyOffset,
			"competitive record bounds")
		local codec = buffer.readu8(packet, bodyOffset)
		local referenceCount = if codec == 4 then buffer.readu8(packet, bodyOffset + 3) else 0
		local eventId = buffer.readu16(packet, bodyOffset + 1)
		local record = { codec = codec, eventId = eventId, bodyBytes = bodyBytes, referenceCount = referenceCount }
		if codec == 4 and bodyBytes >= 5 and (eventId == 1 or eventId == 2) then
			record.value = buffer.readu8(packet, bodyOffset + 4)
		end
		if codec == 1 and (eventId == 4 or eventId == 5) and bodyBytes >= 11 then
			record.serverTime = buffer.readf64(packet, bodyOffset + 3)
		end
		table.insert(records, record)
		offset = bodyOffset + bodyBytes
	end
	assert(offset == buffer.len(packet), "competitive frame has no trailing data")
	return {
		endpoint = endpoint,
		channel = channel,
		format = header.format,
		kind = header.kind,
		count = header.count,
		referenceCount = header.referenceCount,
		length = buffer.len(packet),
		records = records,
		references = references,
	}
end

return table.freeze({
	prepare = prepare,
	createPaced = createPaced,
	createIndependent = createIndependent,
	createTimestamps = createTimestamps,
	createDiagnostics = createDiagnostics,
	timestampPacket = timestampPacket,
	codecByte = codecByte,
	timestampBatch = timestampBatch,
	malformedTimestampBatch = malformedTimestampBatch,
	timestampStateFrame = timestampStateFrame,
	orderedTimestampPacket = orderedTimestampPacket,
	bytes = bytes,
	rawBatchReceipt = rawBatchReceipt,
	diagnosticsStable = diagnosticsStable,
})
