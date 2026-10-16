local FORMAT_VERSION = 3
local CONTROL_FORMAT_VERSION = 2
local HEADER_BYTES = 11
local OVERHEAD_BYTES = HEADER_BYTES - 3
local MAXIMUM_BYTES = 900
local MAXIMUM_COUNTER = 4_294_967_295
local GUID_BYTES = 36

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
        minimumEncodedBytes = event.minimumEncodedBytes - OVERHEAD_BYTES,
        maximumEncodedBytes = event.maximumEncodedBytes - OVERHEAD_BYTES,
    })
end

local function wrap(event, codecPacket, generation, sequence)
    if typeof(codecPacket) ~= "buffer" or type(generation) ~= "number" or generation % 1 ~= 0
        or generation < 0 or generation > MAXIMUM_COUNTER or type(sequence) ~= "number"
        or sequence % 1 ~= 0 or sequence < 0 or sequence > MAXIMUM_COUNTER then
        return nil
    end
    local codecLength = buffer.len(codecPacket)
    if codecLength < event.minimumEncodedBytes - OVERHEAD_BYTES
        or codecLength > event.maximumEncodedBytes - OVERHEAD_BYTES
        or codecLength < 3 or buffer.readu8(codecPacket, 0) ~= 1
        or buffer.readu16(codecPacket, 1) ~= event.id then
        return nil
    end

    local length = codecLength + OVERHEAD_BYTES
    if length > MAXIMUM_BYTES then return nil end
    local packet = buffer.create(length)
    buffer.writeu8(packet, 0, FORMAT_VERSION)
    buffer.writeu16(packet, 1, event.id)
    buffer.writeu32(packet, 3, generation)
    buffer.writeu32(packet, 7, sequence)
    buffer.copy(packet, HEADER_BYTES, codecPacket, 3, codecLength - 3)
    return packet
end

local function peek(event, outerEndpointId, packet)
    if typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < HEADER_BYTES or length > MAXIMUM_BYTES
        or length < event.minimumEncodedBytes or length > event.maximumEncodedBytes
        or outerEndpointId ~= event.id or buffer.readu8(packet, 0) ~= FORMAT_VERSION then
        return nil
    end
    local endpointId = buffer.readu16(packet, 1)
    if endpointId ~= outerEndpointId then return nil end
    return table.freeze({
        endpointId = endpointId,
        generation = buffer.readu32(packet, 3),
        sequence = buffer.readu32(packet, 7),
    })
end

local function decode(event, packet, header, decodeCodec)
    if header == nil or header.endpointId ~= event.id or typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < HEADER_BYTES or length > MAXIMUM_BYTES then return nil end
    local codecPacket = buffer.create(length - OVERHEAD_BYTES)
    buffer.writeu8(codecPacket, 0, 1)
    buffer.writeu16(codecPacket, 1, event.id)
    buffer.copy(codecPacket, 3, packet, HEADER_BYTES, length - HEADER_BYTES)
    return decodeCodec(codecPacket)
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
