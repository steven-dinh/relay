local FLOAT32_BUFFER = buffer.create(4)

local UNSIGNED_MAXIMUMS = table.freeze({
    u8 = 255,
    u16 = 65_535,
    u32 = 4_294_967_295,
})

local function isFinite(value)
    return value == value and value > -math.huge and value < math.huge
end

local function reject()
    return nil
end

local function normalizeBoolean(value)
    if type(value) ~= "boolean" then
        return nil
    end
    return value
end

local function compileField(field)
    local fieldType = field.type
    if fieldType == "boolean" then
        return normalizeBoolean
    end

    local minimum, maximum = field.minimum, field.maximum
    local baseMaximum = UNSIGNED_MAXIMUMS[fieldType]
    if baseMaximum ~= nil then
        minimum = math.max(0, if minimum == nil then 0 else minimum)
        maximum = math.min(baseMaximum, if maximum == nil then baseMaximum else maximum)
    end

    -- Finite bounds make positive interval checks reject NaN and infinities too.
    -- Select this path once; ad hoc internal records retain explicit finite checks.
    if type(minimum) == "number" and type(maximum) == "number"
        and isFinite(minimum) and isFinite(maximum) then
        if baseMaximum ~= nil then
            return function(value)
                if type(value) ~= "number" or not (value >= minimum and value <= maximum)
                    or value % 1 ~= 0 then
                    return nil
                end
                return if value == 0 then 0 else value
            end
        elseif fieldType == "f32" then
            return function(value)
                if type(value) ~= "number" or not (value >= minimum and value <= maximum) then
                    return nil
                end
                if value == 0 then
                    value = 0
                end
                buffer.writef32(FLOAT32_BUFFER, 0, value)
                local normalized = buffer.readf32(FLOAT32_BUFFER, 0)
                if not (normalized >= minimum and normalized <= maximum) then
                    return nil
                end
                return if normalized == 0 then 0 else normalized
            end
        elseif fieldType == "Vector3F32" then
            return function(value)
                if typeof(value) ~= "Vector3" then
                    return nil
                end
                local x, y, z = value.X, value.Y, value.Z
                if not (x >= minimum and x <= maximum
                    and y >= minimum and y <= maximum
                    and z >= minimum and z <= maximum) then
                    return nil
                end
                return Vector3.new(
                    if x == 0 then 0 else x,
                    if y == 0 then 0 else y,
                    if z == 0 then 0 else z
                )
            end
        end
    end

    if baseMaximum ~= nil then
        return function(value)
            if type(value) ~= "number" or not isFinite(value) or value % 1 ~= 0
                or value < minimum or value > maximum then
                return nil
            end
            return if value == 0 then 0 else value
        end
    end

    if fieldType == "f32" then
        return function(value)
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
            return if normalized == 0 then 0 else normalized
        end
    end

    if fieldType == "Vector3F32" then
        return function(value)
            if typeof(value) ~= "Vector3" then
                return nil
            end
            -- Vector3 components already use Float32 storage.
            local x, y, z = value.X, value.Y, value.Z
            if not isFinite(x) or not isFinite(y) or not isFinite(z)
                or x < minimum or x > maximum
                or y < minimum or y > maximum
                or z < minimum or z > maximum then
                return nil
            end
            return Vector3.new(
                if x == 0 then 0 else x,
                if y == 0 then 0 else y,
                if z == 0 then 0 else z
            )
        end
    end
    return reject
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

local function compilePayload(event)
    local fields = event.fields
    local fieldCount = #fields
    if fieldCount > 8 then
        return reject
    end
    if fieldCount == 0 then
        return function(...)
            return if select("#", ...) == 0 then true else nil
        end
    end
    local normalizers = table.create(fieldCount)
    for index = 1, fieldCount do
        normalizers[index] = compileField(fields[index])
    end
    -- Select arity once. Success is separate from false payloads, with exact
    -- multiple returns held by each invocation instead of a temporary array.
    local n1, n2, n3, n4, n5, n6, n7, n8 = table.unpack(normalizers, 1, fieldCount)
    if fieldCount == 1 then
        return function(...)
            if select("#", ...) ~= 1 then return nil end
            local v1 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            return true, v1
        end
    elseif fieldCount == 2 then
        return function(...)
            if select("#", ...) ~= 2 then return nil end
            local v1, v2 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            return true, v1, v2
        end
    elseif fieldCount == 3 then
        return function(...)
            if select("#", ...) ~= 3 then return nil end
            local v1, v2, v3 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            return true, v1, v2, v3
        end
    elseif fieldCount == 4 then
        return function(...)
            if select("#", ...) ~= 4 then return nil end
            local v1, v2, v3, v4 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            return true, v1, v2, v3, v4
        end
    elseif fieldCount == 5 then
        return function(...)
            if select("#", ...) ~= 5 then return nil end
            local v1, v2, v3, v4, v5 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            return true, v1, v2, v3, v4, v5
        end
    elseif fieldCount == 6 then
        return function(...)
            if select("#", ...) ~= 6 then return nil end
            local v1, v2, v3, v4, v5, v6 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            v6 = n6(v6)
            if v6 == nil then return nil end
            return true, v1, v2, v3, v4, v5, v6
        end
    elseif fieldCount == 7 then
        return function(...)
            if select("#", ...) ~= 7 then return nil end
            local v1, v2, v3, v4, v5, v6, v7 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            v6 = n6(v6)
            if v6 == nil then return nil end
            v7 = n7(v7)
            if v7 == nil then return nil end
            return true, v1, v2, v3, v4, v5, v6, v7
        end
    elseif fieldCount == 8 then
        return function(...)
            if select("#", ...) ~= 8 then return nil end
            local v1, v2, v3, v4, v5, v6, v7, v8 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            v6 = n6(v6)
            if v6 == nil then return nil end
            v7 = n7(v7)
            if v7 == nil then return nil end
            v8 = n8(v8)
            if v8 == nil then return nil end
            return true, v1, v2, v3, v4, v5, v6, v7, v8
        end
    end
end

return table.freeze({
    resolve = resolveEndpoint,
    compile = compilePayload,
})
