local FORMAT_VERSION = 3
local REFERENCE_FORMAT_VERSION = 6
local CONTROL_FORMAT_VERSION = 2
local HEADER_BYTES = 11
local REFERENCE_HEADER_BYTES = 12
local OVERHEAD_BYTES = HEADER_BYTES - 3
local MAXIMUM_BYTES = 900
local MAXIMUM_COUNTER = 4_294_967_295
local GUID_BYTES = 36
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8

local function validGuid(value)
    if type(value) ~= "string" or #value ~= GUID_BYTES then return false end
    for index = 1, GUID_BYTES do
        local byte = string.byte(value, index)
        if index == 9 or index == 14 or index == 19 or index == 24 then
            if byte ~= 45 then return false end
        elseif not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then
            return false
        end
    end
    return true
end

local function validGuidAt(packet, offset)
    for index = 0, GUID_BYTES - 1 do
        local byte = buffer.readu8(packet, offset + index)
        if index == 8 or index == 13 or index == 18 or index == 23 then
            if byte ~= 45 then return false end
        elseif not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then
            return false
        end
    end
    return true
end

local function codecEvent(event)
    return table.freeze({
        id = event.id,
        delivery = "Unreliable",
        fields = event.fields,
        usesCodec = true,
        bitPacking = event.bitPacking,
        hasReferences = event.hasReferences,
        maximumReferences = event.maximumReferences,
        maximumAdmissionBytes = event.maximumAdmissionBytes,
        minimumEncodedBytes = event.minimumEncodedBytes - OVERHEAD_BYTES,
        maximumEncodedBytes = event.maximumEncodedBytes - OVERHEAD_BYTES,
    })
end

local function validSidecars(sidecars, expectedCount)
	if sidecars == nil then return expectedCount == 0 end
	if type(sidecars) ~= "table" or getmetatable(sidecars) ~= nil then return false end
	local count = rawget(sidecars, "n")
	if type(count) ~= "number" or count % 1 ~= 0 or count ~= expectedCount
		or count < 0 or count > MAXIMUM_REFERENCES then return false end
	local observed = 0
	for key, value in sidecars do
		if key == "n" then
			if value ~= count then return false end
		elseif type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count
			or typeof(value) ~= "Instance" then
			return false
		else
			observed += 1
		end
	end
	return observed == count
end

local function wrap(event, codecPacket, generation, sequence, sidecars)
    if typeof(codecPacket) ~= "buffer" or type(generation) ~= "number" or generation % 1 ~= 0
        or generation < 0 or generation > MAXIMUM_COUNTER or type(sequence) ~= "number"
        or sequence % 1 ~= 0 or sequence < 0 or sequence > MAXIMUM_COUNTER then
        return nil
    end
    local codecLength = buffer.len(codecPacket)
    local hasReferences = event.hasReferences == true
    local codecHeaderBytes = if hasReferences then 4 else 3
    if codecLength < event.minimumEncodedBytes - OVERHEAD_BYTES
        or codecLength > event.maximumEncodedBytes - OVERHEAD_BYTES
        or codecLength < codecHeaderBytes
        or buffer.readu8(codecPacket, 0) ~= (if hasReferences then 4 else 1)
        or buffer.readu16(codecPacket, 1) ~= event.id then
        return nil
    end

    local referenceCount = if hasReferences then buffer.readu8(codecPacket, 3) else 0
    if referenceCount > MAXIMUM_REFERENCES
        or (hasReferences and (type(event.maximumReferences) ~= "number"
            or referenceCount > event.maximumReferences))
        or not validSidecars(sidecars, referenceCount) then
        return nil
    end

    local length = codecLength - codecHeaderBytes
        + (if hasReferences then REFERENCE_HEADER_BYTES else HEADER_BYTES)
    if length + referenceCount * REFERENCE_BYTES > MAXIMUM_BYTES then return nil end
    local packet = buffer.create(length)
    buffer.writeu8(packet, 0, if hasReferences then REFERENCE_FORMAT_VERSION else FORMAT_VERSION)
    buffer.writeu16(packet, 1, event.id)
    buffer.writeu32(packet, 3, generation)
    buffer.writeu32(packet, 7, sequence)
    if hasReferences then buffer.writeu8(packet, 11, referenceCount) end
    buffer.copy(packet, if hasReferences then REFERENCE_HEADER_BYTES else HEADER_BYTES,
        codecPacket, codecHeaderBytes, codecLength - codecHeaderBytes)
    if hasReferences and referenceCount > 0 then return packet, sidecars end
    return packet
end

local function peek(event, outerEndpointId, packet, sidecars)
    if typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < HEADER_BYTES or length > MAXIMUM_BYTES or outerEndpointId ~= event.id then
        return nil
    end
    local format = buffer.readu8(packet, 0)
    local headerBytes, referenceCount
    if format == FORMAT_VERSION and event.hasReferences ~= true then
        headerBytes, referenceCount = HEADER_BYTES, 0
    elseif format == REFERENCE_FORMAT_VERSION and event.hasReferences == true then
        if length < REFERENCE_HEADER_BYTES then return nil end
        headerBytes = REFERENCE_HEADER_BYTES
        referenceCount = buffer.readu8(packet, 11)
        if referenceCount > MAXIMUM_REFERENCES or type(event.maximumReferences) ~= "number"
            or referenceCount > event.maximumReferences or not validSidecars(sidecars, referenceCount) then return nil end
    else
        return nil
    end
    if length < headerBytes or length < event.minimumEncodedBytes or length > event.maximumEncodedBytes
        or length + referenceCount * REFERENCE_BYTES > MAXIMUM_BYTES then return nil end
    local endpointId = buffer.readu16(packet, 1)
    if endpointId ~= outerEndpointId then return nil end
    return table.freeze({
        format = format,
        endpointId = endpointId,
        generation = buffer.readu32(packet, 3),
        sequence = buffer.readu32(packet, 7),
        referenceCount = referenceCount,
    })
end

local function decode(event, packet, header, decodeCodec, sidecars)
    if header == nil or header.endpointId ~= event.id or typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < HEADER_BYTES or length > MAXIMUM_BYTES or buffer.readu8(packet, 0) ~= header.format
        or buffer.readu16(packet, 1) ~= event.id
        or buffer.readu32(packet, 3) ~= header.generation or buffer.readu32(packet, 7) ~= header.sequence then return nil end
    if header.format == FORMAT_VERSION and event.hasReferences ~= true then
        if length < HEADER_BYTES or length < event.minimumEncodedBytes or length > event.maximumEncodedBytes
            or not validSidecars(sidecars, 0) then return nil end
        local codecPacket = buffer.create(length - OVERHEAD_BYTES)
        buffer.writeu8(codecPacket, 0, 1)
        buffer.writeu16(codecPacket, 1, event.id)
        buffer.copy(codecPacket, 3, packet, HEADER_BYTES, length - HEADER_BYTES)
        return decodeCodec(codecPacket)
    elseif header.format == REFERENCE_FORMAT_VERSION and event.hasReferences == true then
        if length < REFERENCE_HEADER_BYTES or buffer.readu8(packet, 0) ~= REFERENCE_FORMAT_VERSION
            or length < event.minimumEncodedBytes or length > event.maximumEncodedBytes then return nil end
        local referenceCount = buffer.readu8(packet, 11)
        if referenceCount ~= header.referenceCount or referenceCount > MAXIMUM_REFERENCES
            or type(event.maximumReferences) ~= "number" or referenceCount > event.maximumReferences
            or length + referenceCount * REFERENCE_BYTES > MAXIMUM_BYTES
            or not validSidecars(sidecars, referenceCount) then return nil end
        local codecPacket = buffer.create(length - OVERHEAD_BYTES)
        buffer.writeu8(codecPacket, 0, 4)
        buffer.writeu16(codecPacket, 1, event.id)
        buffer.writeu8(codecPacket, 3, referenceCount)
        buffer.copy(codecPacket, 4, packet, REFERENCE_HEADER_BYTES, length - REFERENCE_HEADER_BYTES)
        return decodeCodec(codecPacket, table.unpack(sidecars or {}, 1, referenceCount))
    end
    return nil
end

local function hello(clientGuid)
    if not validGuid(clientGuid) then return nil end
    local packet = buffer.create(38)
    buffer.writeu8(packet, 0, CONTROL_FORMAT_VERSION)
    buffer.writeu8(packet, 1, 32)
    buffer.writestring(packet, 2, clientGuid)
    return packet
end

local function readHello(packet)
    if typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length ~= 38 or buffer.readu8(packet, 0) ~= CONTROL_FORMAT_VERSION
        or buffer.readu8(packet, 1) ~= 32 or not validGuidAt(packet, 2) then
        return nil
    end
    return buffer.readstring(packet, 2, GUID_BYTES)
end

local function initialization(clientGuid, generation)
    if not validGuid(clientGuid) or type(generation) ~= "number" or generation % 1 ~= 0
        or generation < 1 or generation > MAXIMUM_COUNTER then
        return nil
    end
    local packet = buffer.create(42)
    buffer.writeu8(packet, 0, CONTROL_FORMAT_VERSION)
    buffer.writeu8(packet, 1, 33)
    buffer.writestring(packet, 2, clientGuid)
    buffer.writeu32(packet, 38, generation)
    return packet
end

local function readInitialization(packet)
    if typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length ~= 42 or buffer.readu8(packet, 0) ~= CONTROL_FORMAT_VERSION
        or buffer.readu8(packet, 1) ~= 33 or not validGuidAt(packet, 2) then
        return nil
    end
    local generation = buffer.readu32(packet, 38)
    if generation == 0 then return nil end
    return table.freeze({ clientGuid = buffer.readstring(packet, 2, GUID_BYTES), generation = generation })
end

return table.freeze({
    codecEvent = codecEvent,
    wrap = wrap,
    peek = peek,
    decode = decode,
    hello = hello,
    readHello = readHello,
    initialization = initialization,
    readInitialization = readInitialization,
})
