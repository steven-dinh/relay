-- Native Studio proof inputs for bounded scalar quantization.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Quantized = require(ReplicatedStorage.Relay.internal.Quantized)
local schema = Relay.schema

local grid = schema.quantized(-1, 1, 0.5)
local decimal = schema.quantized(0, 1, 0.01)
local cancellation = schema.quantized(0.1, 0.1001, 0.0001)
local wide = schema.quantized(0, 256, 1)

local gridFields = {
    schema.field("beforeTie", grid),
    schema.field("tie", grid),
    schema.field("afterTie", grid),
    schema.field("zero", grid),
    schema.field("minimum", grid),
    schema.field("maximum", grid),
    schema.field("decimal", decimal),
    schema.field("cancellation", cancellation),
}

local function create(withReadiness)
    local definition, failure = Relay.define({
        name = "RelayQuantizedScalarStudioProof",
        version = 1,
        readiness = if withReadiness then true else nil,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = gridFields },
            Output = { id = 2, direction = "ServerToClient", fields = gridFields },
            WideInput = { id = 3, direction = "ClientToServer", fields = { schema.field("value", wide) } },
            WideOutput = { id = 4, direction = "ServerToClient", fields = { schema.field("value", wide) } },
            QueueInput = { id = 5, direction = "ClientToServer", queue = "Batch", fields = {
                schema.field("value", grid),
            } },
            QueueOutput = { id = 6, direction = "ServerToClient", queue = "Batch", fields = {
                schema.field("value", grid),
            } },
        },
        requests = {
            Echo = {
                id = 7,
                request = { schema.field("value", grid) },
                response = grid,
            },
        },
    })
    assert(definition ~= nil, failure and failure.message or "quantized Studio definition failed")
    return definition
end

local function gridValues()
    return -0.75 - 2 ^ -53, -0.75, -0.75 + 2 ^ -53, -0, -1, 1, 0.346, 0.1001
end

local function checkGrid(...)
    local values = table.pack(...)
    assert(values.n == 8, "quantized grid arity")
    local expected = { -1, -0.5, -0.5, 0, -1, 1, 35 * 0.01, 0.1001 }
    local normalized = table.create(8)
    for index, value in expected do
        assert(values[index] == value, "quantized scalar value " .. tostring(index))
        normalized[index] = values[index]
    end
    assert(1 / values[4] == math.huge, "quantized zero canonicalization")
    return { values = normalized, zeroPositive = true }
end

local function rawReceipt(endpoint, packet)
    if type(endpoint) ~= "number" or endpoint % 1 ~= 0 or endpoint < 1 or endpoint > 6
        or typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < 3 or buffer.readu8(packet, 0) ~= 1 then return nil end
    local eventId = buffer.readu16(packet, 1)
    if endpoint ~= eventId then return nil end
    if eventId == 1 or eventId == 2 then
        if length ~= 11 then
            return { endpoint = endpoint, eventId = eventId, format = 1, length = length, codes = {} }
        end
        local codes = table.create(8)
        for index = 1, 8 do codes[index] = buffer.readu8(packet, index + 2) end
        return { endpoint = endpoint, eventId = eventId, format = 1, length = length, codes = codes }
    elseif eventId == 3 or eventId == 4 then
        local bytes = {}
        for offset = 3, length - 1 do bytes[offset - 2] = buffer.readu8(packet, offset) end
        return { endpoint = endpoint, eventId = eventId, format = 1, length = length, bytes = bytes }
    end
    return nil
end

local function malformedUnusedCode()
    local packet = buffer.create(5)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 3)
    buffer.writeu16(packet, 3, 257)
    return packet
end

local function truncatedWideCode()
    local packet = buffer.create(4)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 3)
    buffer.writeu8(packet, 3, 1)
    return packet
end

local function numericProbes()
    local function probe(name, minimum, maximum, step, input)
        local shape, suffix, reason = Quantized.schema({
            type = "quantized", minimum = minimum, maximum = maximum, step = step,
        })
        assert(shape ~= nil, name .. " quantized schema: " .. tostring(suffix) .. tostring(reason))
        local codec = assert(Quantized.compile(shape), name .. " quantized codec")
        local valid, normalized, width = codec.normalize(input)
        assert(valid and width == shape.width, name .. " quantized normalization")
        local output = buffer.create(width)
        assert(codec.write(normalized, output, 0) == width, name .. " quantized write")
        local code = if width == 1 then buffer.readu8(output, 0) else buffer.readu16(output, 0)
        local state = { value = output, offset = 0, length = width }
        local read, value = codec.read(state)
        assert(read and state.offset == width, name .. " quantized read")
        local stable, stableValue, stableWidth = codec.normalize(value)
        local rewrite = buffer.create(width)
        local rewriteOffset = if stable then codec.write(stableValue, rewrite, 0) else -1
        local rewriteCode = if rewriteOffset == width
            then (if width == 1 then buffer.readu8(rewrite, 0) else buffer.readu16(rewrite, 0)) else -1
        local error = math.abs(value - input)
        return {
            name = name,
            minimum = minimum,
            maximum = maximum,
            step = step,
            input = input,
            value = value,
            code = code,
            width = width,
            error = error,
            maximumError = shape.maximumError,
            stable = stable == true and stableWidth == width and stableValue == value
                and rewriteOffset == width and rewriteCode == code,
            rewriteCode = rewriteCode,
        }
    end

    local minimumStep = Quantized.MINIMUM_STEP
    return {
        minimumStep = probe("minimum-step", 0, minimumStep, minimumStep, minimumStep / 2),
        largeOffset = probe("large-offset-residual", 1e13, 1e13 + 1.03125, 1, 1e13 + 0.5),
    }
end

return table.freeze({
    create = create,
    gridValues = gridValues,
    checkGrid = checkGrid,
    rawReceipt = rawReceipt,
    malformedUnusedCode = malformedUnusedCode,
    truncatedWideCode = truncatedWideCode,
    numericProbes = numericProbes,
})
