local FORMAT_VERSION = 2
local REFERENCE_FORMAT_VERSION = 5
local CODEC_VERSION = 1
local REFERENCE_CODEC_VERSION = 4
local MINIMUM_FRAME_BYTES = 8
local MAXIMUM_FRAME_BYTES = 8_192
local MAXIMUM_RECORDS = 32
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8
local MAXIMUM_BODY_BYTES = MAXIMUM_FRAME_BYTES - 5
local InstanceRefs = require(if script then script.Parent.InstanceRefs else "./InstanceRefs")
local validSidecars = InstanceRefs.validSidecars

local function snapshotEncode(event, ...)
	if event.hasReferences == false then
		local valid, body = event.encode(...)
		if valid ~= true or typeof(body) ~= "buffer" then return nil end
		local bodyBytes = buffer.len(body)
		if bodyBytes < 3 then return nil end
		local referenceFormat = buffer.readu8(body, 0) == REFERENCE_CODEC_VERSION
		if referenceFormat and (bodyBytes < 4 or buffer.readu8(body, 3) ~= 0) then return nil end
		return body, bodyBytes, nil, 0, referenceFormat
	end
	local encoded = table.pack(event.encode(...))
	local body = encoded[2]
	if encoded[1] ~= true or typeof(body) ~= "buffer" then return nil end
	local bodyBytes = buffer.len(body)
	if bodyBytes < 3 then return nil end
	local referenceCount = encoded.n - 2
	if referenceCount < 0 or referenceCount > MAXIMUM_REFERENCES then return nil end
	local references = if referenceCount > 0 then table.create(referenceCount) else nil
	if references ~= nil then references.n = referenceCount end
	for index = 1, referenceCount do
		local reference = encoded[index + 2]
		if typeof(reference) ~= "Instance" then return nil end
		references[index] = reference
	end
	local referenceFormat = buffer.readu8(body, 0) == REFERENCE_CODEC_VERSION
	if referenceFormat then
		if bodyBytes < 4 or buffer.readu8(body, 3) ~= referenceCount then return nil end
	elseif referenceCount ~= 0 then
		return nil
	end
	return body, bodyBytes, references, referenceCount, referenceFormat
end

local function isInteger(value)
	return type(value) == "number" and value % 1 == 0
end

local function validLimit(limit)
	return isInteger(limit) and limit >= MINIMUM_FRAME_BYTES and limit <= MAXIMUM_FRAME_BYTES
end

local function validKind(kind)
	return isInteger(kind) and (kind == 1 or kind == 2)
end

local function validCount(count)
	return isInteger(count) and count >= 1 and count <= MAXIMUM_RECORDS
end

local function validEndpointId(id)
	return isInteger(id) and id >= 1 and id <= 65_535
end

local function validHeader(packet, header, sidecars)
	if typeof(packet) ~= "buffer" or type(header) ~= "table" or not validLimit(header.limit) then return false end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > header.limit then return false end
	local version = buffer.readu8(packet, 0)
	local format, references
	if version == FORMAT_VERSION then
		format, references = FORMAT_VERSION, 0
	elseif version == REFERENCE_FORMAT_VERSION then
		format = REFERENCE_FORMAT_VERSION
		references = buffer.readu8(packet, 3)
		if references > MAXIMUM_REFERENCES or length + references * REFERENCE_BYTES > header.limit then return false end
	else
		return false
	end
	return header.format == format
		and validKind(header.kind) and buffer.readu8(packet, 1) == header.kind
		and validCount(header.count) and buffer.readu8(packet, 2) == header.count
		and header.referenceCount == references
		and validSidecars(sidecars, references)
end

local function validCompiledEvent(event, id, bodyBytes, codecVersion)
	if not validEndpointId(id) or type(event) ~= "table" or event.id ~= id or event.usesCodec ~= true then
		return false
	end
	local minimumBytes, maximumBytes = event.minimumEncodedBytes, event.maximumEncodedBytes
	if not (isInteger(minimumBytes) and isInteger(maximumBytes)
		and minimumBytes >= 3 and maximumBytes >= minimumBytes and maximumBytes <= MAXIMUM_BODY_BYTES
		and bodyBytes >= minimumBytes and bodyBytes <= maximumBytes) then
		return false
	end
	if event.hasReferences == true then
		return codecVersion == REFERENCE_CODEC_VERSION
	end
	return event.hasReferences ~= true and codecVersion == CODEC_VERSION
end

local function parseHeader(packet, limit, sidecars)
	if typeof(packet) ~= "buffer" or not validLimit(limit) then return nil end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > limit then return nil end
	local format = buffer.readu8(packet, 0)
	local kind = buffer.readu8(packet, 1)
	local count = buffer.readu8(packet, 2)
	if (kind ~= 1 and kind ~= 2) or count < 1 or count > MAXIMUM_RECORDS then return nil end
	local referenceCount = 0
	if format == REFERENCE_FORMAT_VERSION then
		referenceCount = buffer.readu8(packet, 3)
		if referenceCount > MAXIMUM_REFERENCES or length + referenceCount * REFERENCE_BYTES > limit then return nil end
	elseif format ~= FORMAT_VERSION then
		return nil
	end
	if not validSidecars(sidecars, referenceCount) then return nil end
	return table.freeze({ format = format, kind = kind, count = count, referenceCount = referenceCount, limit = limit })
end

local function scanRows(packet, frameHeader, resolve, requireFrozenEvents)
	local packetBytes = buffer.len(packet)
	local rows = table.create(frameHeader.count)
	local offset = if frameHeader.format == REFERENCE_FORMAT_VERSION then 4 else 3
	local referenceStart = 1
	for index = 1, frameHeader.count do
		if offset > packetBytes - 2 then return nil end
		local bodyBytes = buffer.readu16(packet, offset)
		local bodyOffset = offset + 2
		if bodyBytes < 3 or bodyBytes > packetBytes - bodyOffset then return nil end
		local codecVersion = buffer.readu8(packet, bodyOffset)
		if codecVersion ~= CODEC_VERSION and codecVersion ~= REFERENCE_CODEC_VERSION then return nil end
		if frameHeader.format == FORMAT_VERSION and codecVersion ~= CODEC_VERSION then return nil end
		local id = buffer.readu16(packet, bodyOffset + 1)
		if id == 0 then return nil end
		local localReferences = 0
		local event = resolve(id)
		if requireFrozenEvents and (type(event) ~= "table" or getmetatable(event) ~= nil or not table.isfrozen(event)) then
			return nil
		end
		if codecVersion == REFERENCE_CODEC_VERSION then
			if frameHeader.format ~= REFERENCE_FORMAT_VERSION or bodyBytes < 4 then return nil end
			localReferences = buffer.readu8(packet, bodyOffset + 3)
			local maximumReferences = if type(event) == "table" then event.maximumReferences else nil
			if localReferences > MAXIMUM_REFERENCES or not isInteger(maximumReferences)
				or localReferences > maximumReferences then return nil end
		end
		if not validCompiledEvent(event, id, bodyBytes, codecVersion) then return nil end
		if referenceStart + localReferences - 1 > frameHeader.referenceCount then return nil end
		rows[index] = table.freeze({
			event = event,
			offset = bodyOffset,
			length = bodyBytes,
			format = codecVersion,
			referenceStart = referenceStart,
			referenceCount = localReferences,
			limit = frameHeader.limit,
		})
		referenceStart += localReferences
		offset = bodyOffset + bodyBytes
	end
	if offset ~= packetBytes or referenceStart ~= frameHeader.referenceCount + 1 then return nil end
	return table.freeze(rows)
end

local function scan(packet, frameHeader, resolve, sidecars)
	if type(resolve) ~= "function" or not validHeader(packet, frameHeader, sidecars) then return nil end
	return scanRows(packet, frameHeader, resolve, false)
end

local function matchesRow(packet, offset, bodyBytes, codecVersion, eventId, localReferences)
	return buffer.readu16(packet, offset - 2) == bodyBytes
		and buffer.readu8(packet, offset) == codecVersion
		and buffer.readu16(packet, offset + 1) == eventId
		and (if codecVersion == REFERENCE_CODEC_VERSION then buffer.readu8(packet, offset + 3) else 0) == localReferences
end

local function copyRow(packet, offset, bodyBytes, sidecars, referenceStart, localReferences)
	local body = buffer.create(bodyBytes)
	buffer.copy(body, 0, packet, offset, bodyBytes)
	if localReferences == 0 then return body end
	local localSidecars = table.create(localReferences)
	localSidecars.n = localReferences
	for index = 1, localReferences do localSidecars[index] = sidecars[referenceStart + index - 1] end
	return body, localSidecars
end

local function readBody(packet, row, sidecars)
	if typeof(packet) ~= "buffer" or type(row) ~= "table" then return nil end
	local packetBytes = buffer.len(packet)
	local limit = row.limit
	if not validLimit(limit) or packetBytes < MINIMUM_FRAME_BYTES or packetBytes > limit then return nil end
	local format = buffer.readu8(packet, 0)
	if format ~= FORMAT_VERSION and format ~= REFERENCE_FORMAT_VERSION then return nil end
	local kind, count = buffer.readu8(packet, 1), buffer.readu8(packet, 2)
	if (kind ~= 1 and kind ~= 2) or count < 1 or count > MAXIMUM_RECORDS then return nil end
	local totalReferences = if format == REFERENCE_FORMAT_VERSION then buffer.readu8(packet, 3) else 0
	if totalReferences > MAXIMUM_REFERENCES or packetBytes + totalReferences * REFERENCE_BYTES > limit
		or not validSidecars(sidecars, totalReferences) then return nil end
	local offset, bodyBytes, codecVersion = row.offset, row.length, row.format
	local event = row.event
	if not isInteger(offset) or offset < (if format == REFERENCE_FORMAT_VERSION then 6 else 5)
		or not isInteger(bodyBytes) or bodyBytes < (if codecVersion == REFERENCE_CODEC_VERSION then 4 else 3)
		or offset > packetBytes or bodyBytes > packetBytes - offset
		or not isInteger(codecVersion) or (codecVersion ~= CODEC_VERSION and codecVersion ~= REFERENCE_CODEC_VERSION)
		or type(event) ~= "table" or not validCompiledEvent(event, event.id, bodyBytes, codecVersion) then
		return nil
	end
	local localReferences, referenceStart = row.referenceCount, row.referenceStart
	if (format == FORMAT_VERSION and codecVersion ~= CODEC_VERSION)
		or not matchesRow(packet, offset, bodyBytes, codecVersion, event.id, localReferences)
		or localReferences > totalReferences or not isInteger(referenceStart) or referenceStart < 1
		or referenceStart + localReferences - 1 > totalReferences then
		return nil
	end
	return copyRow(packet, offset, bodyBytes, sidecars, referenceStart, localReferences)
end

local function open(packet, limit, sidecars)
	local header = parseHeader(packet, limit, sidecars)
	if header == nil then return nil end
	if sidecars ~= nil and not table.isfrozen(sidecars) then table.freeze(sidecars) end
	-- The fourth byte is either the aggregate reference count or part of the first row's length.
	local firstWord = buffer.readu32(packet, 0)
	return header, function(resolve)
		if type(resolve) ~= "function" or buffer.readu32(packet, 0) ~= firstWord then return nil end
		local rows = scanRows(packet, header, resolve, true)
		if rows == nil then return nil end
		return rows, function(index)
			local row = rows[index]
			-- Only the bytes can change. This buffer's length, row bounds and compiled event are fixed.
			if row == nil or buffer.readu32(packet, 0) ~= firstWord then return nil end
			local offset, bodyBytes, localReferences = row.offset, row.length, row.referenceCount
			if not matchesRow(packet, offset, bodyBytes, row.format, row.event.id, localReferences) then return nil end
			return copyRow(packet, offset, bodyBytes, sidecars, row.referenceStart, localReferences)
		end
	end
end

local function denseLength(values)
	if type(values) ~= "table" or getmetatable(values) ~= nil then return nil end
	local count, maximumIndex = 0, 0
	for key in values do
		if not isInteger(key) or key < 1 or key > MAXIMUM_RECORDS then return nil end
		count += 1
		if key > maximumIndex then maximumIndex = key end
	end
	if count < 1 or count > MAXIMUM_RECORDS or maximumIndex ~= count then return nil end
	return count
end

local function recordParts(record)
	if typeof(record) == "buffer" then return record, nil, 0 end
	if type(record) ~= "table" or getmetatable(record) ~= nil then return nil end
	local body, sidecars = rawget(record, "body"), rawget(record, "references")
	if typeof(body) ~= "buffer" then return nil end
	local format = if buffer.len(body) >= 1 then buffer.readu8(body, 0) else nil
	if format == CODEC_VERSION then
		if sidecars ~= nil and not validSidecars(sidecars, 0) then return nil end
		return body, nil, 0
	elseif format == REFERENCE_CODEC_VERSION then
		local count = if buffer.len(body) >= 4 then buffer.readu8(body, 3) else nil
		if count == nil or not validSidecars(sidecars, count) then return nil end
		return body, sidecars, count
	end
	return nil
end

local function wrap(kind, records, limit)
	if not validKind(kind) or not validLimit(limit) then return nil end
	local count = denseLength(records)
	if count == nil then return nil end
	local frameBytes, totalReferences, hasReferenceFormat = 3, 0, false
	for index = 1, count do
		local body, _, referenceCount = recordParts(records[index])
		if body == nil then return nil end
		local bodyBytes = buffer.len(body)
		local format = buffer.readu8(body, 0)
		if (format ~= CODEC_VERSION and format ~= REFERENCE_CODEC_VERSION)
			or bodyBytes < (if format == REFERENCE_CODEC_VERSION then 4 else 3)
			or bodyBytes > MAXIMUM_BODY_BYTES or buffer.readu16(body, 1) == 0 then return nil end
		totalReferences += referenceCount
		if totalReferences > MAXIMUM_REFERENCES then return nil end
		if format == REFERENCE_CODEC_VERSION then hasReferenceFormat = true end
		frameBytes += 2 + bodyBytes
	end
	if hasReferenceFormat then frameBytes += 1 end
	if frameBytes + totalReferences * REFERENCE_BYTES > limit then return nil end
	local packet = buffer.create(frameBytes)
	buffer.writeu8(packet, 0, if hasReferenceFormat then REFERENCE_FORMAT_VERSION else FORMAT_VERSION)
	buffer.writeu8(packet, 1, kind)
	buffer.writeu8(packet, 2, count)
	if hasReferenceFormat then buffer.writeu8(packet, 3, totalReferences) end
	local flatReferences = if totalReferences > 0 then table.create(totalReferences) else nil
	if flatReferences ~= nil then flatReferences.n = totalReferences end
	local offset = if hasReferenceFormat then 4 else 3
	local referenceIndex = 1
	for index = 1, count do
		local body, sidecars, referenceCount = recordParts(records[index])
		local bodyBytes = buffer.len(body)
		buffer.writeu16(packet, offset, bodyBytes)
		buffer.copy(packet, offset + 2, body, 0, bodyBytes)
		offset += 2 + bodyBytes
		for sidecarIndex = 1, referenceCount do
			flatReferences[referenceIndex] = sidecars[sidecarIndex]
			referenceIndex += 1
		end
	end
	if flatReferences ~= nil then return packet, flatReferences end
	return packet
end

return table.freeze({ header = parseHeader, open = open, scan = scan, readBody = readBody, wrap = wrap, snapshotEncode = snapshotEncode })
