-- Native Studio fixtures for bounded buffers and deferred State service.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local schema = Relay.schema

local function bytesValue(values)
    local value = buffer.create(#values)
    for index, byte in values do buffer.writeu8(value, index - 1, byte) end
    return value
end

local function bytesArray(value)
    assert(typeof(value) == "buffer", "native buffer callback value")
    local result = table.create(buffer.len(value))
    for offset = 0, buffer.len(value) - 1 do result[offset + 1] = buffer.readu8(value, offset) end
    return result
end

local function createBuffers(withReadiness)
    local binary = schema.buffer(4)
    local definition, failure = Relay.define({
        name = "RelayBufferNativeProof",
        version = 1,
        readiness = if withReadiness then true else nil,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = {
                schema.field("value", binary),
            } },
            Output = { id = 2, direction = "ServerToClient", fields = {
                schema.field("value", binary),
            } },
            QueuedOutput = { id = 3, direction = "ServerToClient", queue = "Batch", fields = {
                schema.field("value", binary),
            } },
        },
    })
    assert(definition ~= nil, failure and failure.message or "native buffer definition failed")
    return definition
end

local function createStateDeferral(withReadiness)
    local smallBuffer = schema.buffer(4)
    local stateBuffer = schema.buffer(32)
    local definition, failure = Relay.define({
        name = "RelayStateDeferralProof",
        version = 1,
        readiness = if withReadiness then true else nil,
        outboundBytes = { capacity = 27, refillPerSecond = 18 },
        events = {
            Pulse = { id = 1, direction = "ServerToClient", fields = {
                schema.field("value", smallBuffer),
            } },
            StateOutput = { id = 2, direction = "ServerToClient", queue = "State", fields = {
                schema.field("value", stateBuffer),
            } },
        },
    })
    assert(definition ~= nil, failure and failure.message or "State deferral definition failed")
    return definition
end

local function rawInput(body)
    local packet = buffer.create(3 + #body)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    for index, byte in body do buffer.writeu8(packet, index + 2, byte) end
    return packet
end

local function overCapProbe()
    return rawInput({ 5, 0, 10, 20, 30, 40, 50 })
end

local function truncatedPrefixProbe()
    return rawInput({ 4 })
end

local function truncatedBodyProbe()
    return rawInput({ 4, 0, 11, 22 })
end

local function trailingDataProbe()
    return rawInput({ 4, 0, 1, 2, 3, 4, 5 })
end

local function rawReceipt(endpoint, packet)
    if type(endpoint) ~= "number" or endpoint < 1 or endpoint > 3
        or typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    local frameBytes = bytesArray(packet)
    local completeHeader = length >= 3
    local format = if length >= 1 then buffer.readu8(packet, 0) else nil
    local eventId = if completeHeader then buffer.readu16(packet, 1) else nil
    local payload = table.create(math.max(0, length - 3))
    for offset = 3, length - 1 do payload[offset - 2] = buffer.readu8(packet, offset) end
    return {
        endpoint = endpoint,
        eventId = eventId,
        format = format,
        headerComplete = completeHeader,
        length = length,
        bytes = payload,
        frameBytes = frameBytes,
    }
end

local function packetReceipt(packet)
    if typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < 3 then return nil end
    local bytes = table.create(length)
    for offset = 0, length - 1 do bytes[offset + 1] = buffer.readu8(packet, offset) end
    return { length = length, bytes = bytes }
end

local function inputValue()
    return bytesValue({ 0, 128, 255, 3 })
end

local function recoveryValue()
    return bytesValue({ 9, 8, 7, 6 })
end

local function outputValue()
    return bytesValue({ 5, 0, 255, 128 })
end

local function queuedSource()
    return bytesValue({ 12, 34, 56, 78 })
end

local function prechargeValue()
    return bytesValue({ 1, 2, 3, 4 })
end

local function smallStateValue()
    return bytesValue({ 46 })
end

local function largeStateValue()
    local values = table.create(32)
    for index = 1, 32 do values[index] = index - 1 end
    return bytesValue(values)
end

local function middleStateValue()
    local values = table.create(20)
    for index = 1, 20 do values[index] = index - 1 end
    return bytesValue(values)
end

local function replacementStateValue()
    return bytesValue({ 31 })
end

local function survivorStateValue()
    return bytesValue({ 77 })
end

return table.freeze({
    createBuffers = createBuffers,
    createStateDeferral = createStateDeferral,
    bytesValue = bytesValue,
    bytesArray = bytesArray,
    inputValue = inputValue,
    recoveryValue = recoveryValue,
    outputValue = outputValue,
    queuedSource = queuedSource,
    prechargeValue = prechargeValue,
    smallStateValue = smallStateValue,
    largeStateValue = largeStateValue,
    middleStateValue = middleStateValue,
    replacementStateValue = replacementStateValue,
    survivorStateValue = survivorStateValue,
    oversizedValue = function() return bytesValue({ 1, 2, 3, 4, 5 }) end,
    overCapProbe = overCapProbe,
    truncatedPrefixProbe = truncatedPrefixProbe,
    truncatedBodyProbe = truncatedBodyProbe,
    trailingDataProbe = trailingDataProbe,
    rawReceipt = rawReceipt,
    packetReceipt = packetReceipt,
})
