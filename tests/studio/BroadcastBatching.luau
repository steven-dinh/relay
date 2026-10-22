-- Native fixture for shared server broadcast batching.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local InstanceValues = require(ReplicatedStorage.RelayProofInstanceValues)
local BatchFrame = require(ReplicatedStorage.Relay.internal.BatchFrame)
local schema = Relay.schema

local function create()
	local definition, failure = Relay.define({
		name = "RelayBroadcastBatchingProof",
		version = 1,
		outboundBytes = { capacity = 256, refillPerSecond = 128 },
		events = {
			ReliableOutput = { id = 1, direction = "ServerToClient", queue = "Batch", fields = {
				schema.field("enabled", schema.boolean()),
				schema.field("part", schema.Instance("Part")),
				schema.field("folder", schema.Instance("Folder")),
			} },
			UnreliableOutput = { id = 2, direction = "ServerToClient", delivery = "Unreliable", queue = "Batch", fields = {
				schema.field("sequence", schema.u8()),
				schema.field("enabled", schema.boolean()),
			} },
			Pulse = { id = 3, direction = "ServerToClient", fields = {
				schema.field("value", schema.string(128)),
			} },
			ReliableState = { id = 4, direction = "ServerToClient", queue = "State", fields = {
				schema.field("marker", schema.u8()),
				schema.field("message", schema.string(93)),
				schema.field("part", schema.Instance("Part")),
				schema.field("folder", schema.Instance("Folder")),
			} },
			UnreliableState = { id = 5, direction = "ServerToClient", delivery = "Unreliable", queue = "State", fields = {
				schema.field("sequence", schema.u8()),
				schema.field("enabled", schema.boolean()),
			} },
		},
	})
	assert(definition ~= nil, failure and failure.message or "shared broadcast batching definition")
	return definition
end

local function scope()
	local values = InstanceValues.scopeObjects()
	return values.root, values.part, values.folder, values.outsidePart
end

local function rawReceipt(channel, endpoint, packet, ...)
	if endpoint ~= 0 or typeof(packet) ~= "buffer" then return nil end
	local arguments = table.pack(...)
	local sidecars = { n = arguments.n }
	for index = 1, arguments.n do sidecars[index] = arguments[index] end
	local limit = if channel == "Reliable" then 8_192 else 900
	local header = BatchFrame.header(packet, limit, sidecars)
	assert(header ~= nil, "shared broadcast raw frame header and sidecars")
	local records = table.create(header.count)
	local offset = if header.format == 5 then 4 else 3
	for index = 1, header.count do
		assert(offset <= buffer.len(packet) - 2, "shared broadcast raw record prefix")
		local bodyLength = buffer.readu16(packet, offset)
		local bodyOffset = offset + 2
		assert(bodyLength >= 3 and bodyLength <= buffer.len(packet) - bodyOffset,
			"shared broadcast raw record bounds")
		local codec = buffer.readu8(packet, bodyOffset)
		local record = { codec = codec, eventId = buffer.readu16(packet, bodyOffset + 1),
			bodyLength = bodyLength, referenceCount = 0, ordinals = {} }
		if codec == 4 then
			assert(bodyLength >= 4, "shared broadcast reference body prefix")
			record.referenceCount = buffer.readu8(packet, bodyOffset + 3)
			assert(record.referenceCount <= 16, "shared broadcast reference count bound")
			local ordinalOffset = bodyOffset + 5
			if record.eventId == 4 then
				assert(bodyLength >= 7, "shared State reference string prefix")
				local messageLength = buffer.readu16(packet, bodyOffset + 5)
				assert(record.referenceCount == 2 and messageLength <= 93
					and bodyLength == 7 + messageLength + record.referenceCount,
					"shared State string and reference bounds")
				ordinalOffset = bodyOffset + 7 + messageLength
			else
				assert(5 + record.referenceCount <= bodyLength, "shared broadcast reference body bounds")
			end
			for ordinal = 1, record.referenceCount do
				record.ordinals[ordinal] = buffer.readu8(packet, ordinalOffset + ordinal - 1)
			end
		end
		records[index] = record
		offset = bodyOffset + bodyLength
	end
	assert(offset == buffer.len(packet), "shared broadcast raw frame has no trailing bytes")
	local references = table.create(arguments.n)
	for index = 1, arguments.n do
		local value = arguments[index]
		assert(typeof(value) == "Instance", "shared broadcast sidecar identity")
		references[index] = { className = value.ClassName, name = value.Name, path = value:GetFullName() }
	end
	local bytes = table.create(buffer.len(packet))
	for index = 0, buffer.len(packet) - 1 do
		bytes[index + 1] = buffer.readu8(packet, index)
	end
	return {
		endpoint = endpoint,
		format = header.format,
		kind = header.kind,
		count = header.count,
		referenceCount = header.referenceCount,
		length = buffer.len(packet),
		bytes = bytes,
		records = records,
		references = references,
	}
end

return table.freeze({ create = create, scope = scope, rawReceipt = rawReceipt })
