local FLOAT32_BUFFER = buffer.create(4)

local UNSIGNED_MAXIMUMS = table.freeze({
    u8 = 255,
    u16 = 65_535,
    u32 = 4_294_967_295,
})

local function isFinite(value)
    return value == value and value > -math.huge and value < math.huge
end

local function normalizeFloat32(value, minimum, maximum)
    if type(value) ~= "number" or not isFinite(value) then
        return nil
    end

    if value < minimum or value > maximum then
        return nil
    end

    if value == 0 then
        value = 0
    end

    buffer.writef32(FLOAT32_BUFFER, 0, value)
    local normalized = buffer.readf32(FLOAT32_BUFFER, 0)

    if not isFinite(normalized) or normalized < minimum or normalized > maximum then
        return nil
    end

    if normalized == 0 then
        return 0
    end

    return normalized
end

local function normalizeUnsigned(field, value, baseMaximum)
    if type(value) ~= "number" or not isFinite(value) or value % 1 ~= 0 then
        return nil
    end

    if value < 0 or value > baseMaximum then
        return nil
    end

    local minimum = field.minimum
    local maximum = field.maximum

    if minimum == nil then
        minimum = 0
    end

    if maximum == nil then
        maximum = baseMaximum
    end

    if value < minimum or value > maximum then
        return nil
    end

    return if value == 0 then 0 else value
end

local function normalizeValue(field, value)
    local fieldType = field.type

    if fieldType == "boolean" then
        if type(value) ~= "boolean" then
            return nil
        end

        return value
    end

    local unsignedMaximum = UNSIGNED_MAXIMUMS[fieldType]

    if unsignedMaximum ~= nil then
        return normalizeUnsigned(field, value, unsignedMaximum)
    end

    if fieldType == "f32" then
        return normalizeFloat32(value, field.minimum, field.maximum)
    end

    if fieldType == "Vector3F32" then
        if typeof(value) ~= "Vector3" then
            return nil
        end

        local x = normalizeFloat32(value.X, field.minimum, field.maximum)
        local y = normalizeFloat32(value.Y, field.minimum, field.maximum)
        local z = normalizeFloat32(value.Z, field.minimum, field.maximum)

        if x == nil or y == nil or z == nil then
            return nil
        end

        return Vector3.new(x, y, z)
    end

    return nil
end

local function resolveEndpoint(compiled, expectedDirection, endpointId)
    if expectedDirection ~= "ClientToServer" and expectedDirection ~= "ServerToClient" then
        return nil
    end

    if type(endpointId) ~= "number"
        or not isFinite(endpointId)
        or endpointId % 1 ~= 0
        or endpointId < 1
        or endpointId > 65_535
    then
        return nil
    end

    local event = compiled.byId[endpointId]

    if event == nil or event.direction ~= expectedDirection then
        return nil
    end

    return event
end

local function validatePayload(event, ...)
    local fields = event.fields
    local arity = select("#", ...)
    local fieldCount = #fields

    if arity ~= fieldCount or fieldCount > 8 then
        return nil
    end

    local normalized = table.create(fieldCount)

    for index = 1, fieldCount do
        local value = normalizeValue(fields[index], select(index, ...))

        if value == nil then
            return nil
        end

        normalized[index] = value
    end

    return normalized
end

return table.freeze({
    resolve = resolveEndpoint,
    validate = validatePayload,
})
