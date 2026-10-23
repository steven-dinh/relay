-- Keep these fixed protocol bounds aligned with ServerSession and the frame modules.
local MAXIMUM_NATIVE_ARGUMENTS = 8
local MAXIMUM_REFERENCES = 16
local REFERENCE_BYTES = 8
local BATCH_REFERENCE_FORMAT = 5
local ORDERED_REFERENCE_FORMAT = 6
local RPC_V2_FORMAT = 7

local function validEndpointId(endpointId)
    return type(endpointId) == "number" and endpointId % 1 == 0
        and endpointId >= 0 and endpointId <= 65_535
end

local function exactInbound(endpointId, ...)
    if not validEndpointId(endpointId) then return nil end

    local argumentCount = select("#", ...)
    if argumentCount > 0 then
        local payload = select(1, ...)
        if typeof(payload) == "buffer" then
            local length = buffer.len(payload)
            local format = if length > 0 then buffer.readu8(payload, 0) else nil
            local referenceCount

            if format == 4 or endpointId == 0 and format == BATCH_REFERENCE_FORMAT then
                if length < 4 then return nil end
                referenceCount = buffer.readu8(payload, 3)
            elseif endpointId ~= 0 and format == ORDERED_REFERENCE_FORMAT then
                if length < 12 then return nil end
                referenceCount = buffer.readu8(payload, 11)
            elseif endpointId == 0 and format == RPC_V2_FORMAT and length >= 48
                and buffer.readu8(payload, 44) == 4 then
                referenceCount = buffer.readu8(payload, 47)
            end

            if referenceCount ~= nil then
                if referenceCount > MAXIMUM_REFERENCES or argumentCount ~= referenceCount + 1 then
                    return nil
                end
                for index = 2, argumentCount do
                    local reference = select(index, ...)
                    if reference ~= nil and typeof(reference) ~= "Instance" then
                        return nil
                    end
                end
                return length + referenceCount * REFERENCE_BYTES
            end

            if argumentCount == 1 then
                return length
            end
        end
    end

    if argumentCount > MAXIMUM_NATIVE_ARGUMENTS then return nil end

    local bytes = 3
    for index = 1, argumentCount do
        local value = select(index, ...)
        local kind = typeof(value)
        if kind == "boolean" then
            bytes += 1
        elseif kind == "number" then
            bytes += 8
        elseif kind == "Vector2" then
            bytes += 8
        elseif kind == "Vector3" then
            bytes += 12
        elseif kind == "Color3" then
            bytes += 12
        elseif kind == "CFrame" then
            bytes += 96
        elseif kind == "string" then
            bytes += 2 + #value
        elseif kind == "buffer" then
            bytes += buffer.len(value)
        else
            return nil
        end
    end
    return bytes
end

return table.freeze({
	REFERENCE_BYTES = REFERENCE_BYTES,
	exactInbound = exactInbound,
})
