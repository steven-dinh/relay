-- Native Studio inputs for compact values, outbound budgets, and packed flags.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local schema = Relay.schema

local vector3Shape = schema.quantizedVector3(0, 256, 1)
local vector2Shape = schema.quantizedVector2(0, 256, 1)
local cframeShape = schema.compactCFrame(0, 256, 1)
-- Mirror the scalar grid's half-step bound and binary64 roundoff allowance.
local cframeScale = math.max(math.abs(cframeShape.minimum), math.abs(cframeShape.maximum), cframeShape.positionStep)
local cframePositionError = cframeShape.positionStep / 2 + 16 * 2 ^ -52 * cframeScale
local enum5 = schema.enum("Idle", "Run", "Jump", "Swim", "Duck")

local function frameValues()
    return CFrame.new(1, 2, 3),
        CFrame.new(1, 2, 3) * CFrame.fromEulerAnglesXYZ(math.pi, 0, 0),
        CFrame.new(1.5, 2.5, 3.5) * CFrame.fromEulerAnglesXYZ(0.4, math.pi / 2, -0.7),
        CFrame.new(1.5, 2.5, 3.5) * CFrame.fromEulerAnglesXYZ(0.4, -math.pi / 2, -0.7),
        CFrame.new(1.5, 2.5, 3.5) * CFrame.fromEulerAnglesXYZ(0.7, -1.1, 2.4)
end

local function vector3Value()
    return Vector3.new(1.5, 255.5, 0.25)
end

local function vector2Value()
    return Vector2.new(1.5, 255.5)
end

local function checkVector3(value)
    assert(typeof(value) == "Vector3" and value == Vector3.new(2, 256, 0),
        "quantized Vector3 callback is native and uses the rounded component grid")
    return { value.X, value.Y, value.Z }
end

local function checkVector2(value)
    assert(typeof(value) == "Vector2" and value == Vector2.new(2, 256),
        "quantized Vector2 callback is native and uses the rounded component grid")
    return { value.X, value.Y }
end

local function checkFrames(...)
    local actual = table.pack(...)
    local source = table.pack(frameValues())
    assert(actual.n == source.n, "compact CFrame field count")
    local result = table.create(actual.n)
    for index = 1, actual.n do
        local value, original = actual[index], source[index]
        assert(typeof(value) == "CFrame", "compact CFrame callback retains native type")
        local x, y, z = value:GetComponents()
        local ox, oy, oz = original:GetComponents()
        local positionError = math.max(math.abs(x - ox), math.abs(y - oy), math.abs(z - oz))
        local rotationError = original:AngleBetween(value)
        assert(positionError <= cframePositionError,
            "compact CFrame translation meets its scalar error bound after construction")
        assert(rotationError <= 0.002,
            "compact CFrame rotation meets its angular error bound after construction")
        assert(x == (if index <= 2 then 1 else 2)
            and y == (if index <= 2 then 2 else 3)
            and z == (if index <= 2 then 3 else 4), "compact CFrame canonical native position")
        result[index] = {
            position = { x, y, z },
            positionError = positionError,
            rotationError = rotationError,
        }
    end
    return result
end

local function createCompact(withReadiness)
    local definition, failure = Relay.define({
        name = "RelayCompactTransportStudioProof",
        version = 1,
        readiness = if withReadiness then true else nil,
        events = {
            Vector3Input = { id = 1, direction = "ClientToServer", fields = {
                schema.field("value", vector3Shape),
            } },
            Vector3Output = { id = 2, direction = "ServerToClient", fields = {
                schema.field("value", vector3Shape),
            } },
            Vector2Input = { id = 3, direction = "ClientToServer", fields = {
                schema.field("value", vector2Shape),
            } },
            Vector2Output = { id = 4, direction = "ServerToClient", fields = {
                schema.field("value", vector2Shape),
            } },
            FrameInput = { id = 5, direction = "ClientToServer", fields = {
                schema.field("identity", cframeShape),
                schema.field("pi", cframeShape),
                schema.field("gimbalPositive", cframeShape),
                schema.field("gimbalNegative", cframeShape),
                schema.field("general", cframeShape),
            } },
            FrameOutput = { id = 6, direction = "ServerToClient", fields = {
                schema.field("identity", cframeShape),
                schema.field("pi", cframeShape),
                schema.field("gimbalPositive", cframeShape),
                schema.field("gimbalNegative", cframeShape),
                schema.field("general", cframeShape),
            } },
        },
    })
    assert(definition ~= nil, failure and failure.message or "compact Studio definition failed")
    return definition
end

local function compactUnusedVector3()
    local packet = buffer.create(9)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    buffer.writeu16(packet, 3, 257)
    return packet
end

local function compactTruncatedVector3()
    local packet = buffer.create(8)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    return packet
end

local function compactUnusedFrame()
    local packet = buffer.create(63)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 5)
    buffer.writeu16(packet, 3, 257)
    return packet
end

local function compactTruncatedFrame()
    local packet = buffer.create(62)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 5)
    return packet
end

local function rawReceipt(endpoint, packet)
    if type(endpoint) ~= "number" or endpoint % 1 ~= 0 or endpoint < 1 or endpoint > 6
        or typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < 3 or buffer.readu8(packet, 0) ~= 1 then return nil end
    local eventId = buffer.readu16(packet, 1)
    if endpoint ~= eventId then return nil end
    local bytes = table.create(length - 3)
    for offset = 3, length - 1 do bytes[offset - 2] = buffer.readu8(packet, offset) end
    return { endpoint = endpoint, eventId = eventId, format = 1, length = length, bytes = bytes }
end

local function createBudget(kind, withReadiness)
    local capacity = if kind == "fanout" then 8 elseif kind == "rpc" then 43 else 4
    local definition, failure = Relay.define({
        name = "RelayBudgetStudioProof" .. kind,
        version = 1,
        readiness = if withReadiness then true else nil,
        outboundBytes = { capacity = capacity, refillPerSecond = 0.000001 },
        events = {
            Pulse = { id = 1, direction = "ServerToClient", fields = {
                schema.field("value", schema.boolean()),
            } },
            QueueOutput = { id = 2, direction = "ServerToClient", queue = "Batch", fields = {
                schema.field("value", schema.boolean()),
            } },
            StateOutput = { id = 3, direction = "ServerToClient", queue = "State", fields = {
                schema.field("value", schema.boolean()),
            } },
        },
        requests = {
            Echo = { id = 4,
                request = { schema.field("value", schema.boolean()) },
                response = schema.boolean(),
            },
        },
    })
    assert(definition ~= nil, failure and failure.message or "outbound budget Studio definition failed")
    return definition
end

local function createPacked(withReadiness)
    local shortEnum = schema.enum("Idle", "Run", "Jump")
    local record = schema.struct(
        schema.field("enabled", schema.boolean()),
        schema.field("mode", shortEnum),
        schema.field("count", schema.u8(0, 255))
    )
    local tupleFields = {
        schema.field("enabled", schema.boolean()),
        schema.field("mode", enum5),
        schema.field("optionalFlag", schema.optional(schema.boolean())),
        schema.field("optionalMode", schema.optional(enum5)),
        schema.field("tail", schema.u16(0, 65_535)),
    }
    local arrayFields = {
        schema.field("flags", schema.array(schema.boolean(), 5)),
        schema.field("modes", schema.array(enum5, 5)),
    }
    local definition, failure = Relay.define({
        name = "RelayPackedFlagsStudioProof",
        version = 1,
        readiness = if withReadiness then true else nil,
        bitPacking = true,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = tupleFields },
            Output = { id = 2, direction = "ServerToClient", fields = tupleFields },
            ArrayInput = { id = 3, direction = "ClientToServer", fields = arrayFields },
            ArrayOutput = { id = 4, direction = "ServerToClient", fields = arrayFields },
            StructInput = { id = 5, direction = "ClientToServer", fields = {
                schema.field("value", record),
            } },
            StructOutput = { id = 6, direction = "ServerToClient", fields = {
                schema.field("value", record),
            } },
        },
    })
    assert(definition ~= nil, failure and failure.message or "packed Studio definition failed")
    return definition
end

local function packedTupleValues()
    return true, "Duck", false, "Run", 513
end

local function packedArrays()
    return { true, false, true, false, true }, { "Idle", "Duck", "Jump" }
end

local function packedRecord()
    return { enabled = true, mode = "Jump", count = 201 }
end

local function packedTupleObservation(enabled, mode, optionalFlag, optionalMode, tail)
    assert(enabled == true and mode == "Duck" and optionalFlag == false
        and optionalMode == "Run" and tail == 513, "packed tuple actual callback values")
    return { enabled = enabled, mode = mode, optionalFlag = optionalFlag,
        optionalMode = optionalMode, tail = tail }
end

local function packedArrayObservation(flags, modes)
    local expectedFlags, expectedModes = packedArrays()
    assert(type(flags) == "table" and #flags == #expectedFlags
        and type(modes) == "table" and #modes == #expectedModes,
        "packed array callback cardinality")
    for index, value in expectedFlags do assert(flags[index] == value, "packed boolean array value") end
    for index, value in expectedModes do assert(modes[index] == value, "packed enum array value") end
    return { flags = table.clone(flags), modes = table.clone(modes) }
end

local function packedRecordObservation(value)
    local expected = packedRecord()
    assert(type(value) == "table" and value.enabled == expected.enabled
        and value.mode == expected.mode and value.count == expected.count,
        "packed struct actual callback values")
    return table.clone(value)
end

local function packedRawReceipt(endpoint, packet)
    if type(endpoint) ~= "number" or endpoint % 1 ~= 0 or endpoint < 1 or endpoint > 6
        or typeof(packet) ~= "buffer" then return nil end
    local length = buffer.len(packet)
    if length < 3 or buffer.readu8(packet, 0) ~= 1 then return nil end
    local eventId = buffer.readu16(packet, 1)
    if endpoint ~= eventId then return nil end
    local bytes = table.create(length - 3)
    for offset = 3, length - 1 do bytes[offset - 2] = buffer.readu8(packet, offset) end
    return { endpoint = endpoint, eventId = eventId, format = 1, length = length, bytes = bytes }
end

local function packedPaddingMask()
    local packet = buffer.create(7)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    buffer.writeu8(packet, 3, 0xD9)
    buffer.writeu8(packet, 4, 0x04)
    buffer.writeu16(packet, 5, 513)
    return packet
end

local function packedUnusedEnum()
    local packet = buffer.create(7)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    buffer.writeu8(packet, 3, 0x0B) -- enabled=true, 5 is outside enum ordinals 0..4
    buffer.writeu16(packet, 5, 513)
    return packet
end

local function packedAbsentValueBits()
    local packet = buffer.create(7)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    buffer.writeu8(packet, 3, 0x80) -- optional enum absent, with a nonzero value code
    buffer.writeu16(packet, 5, 513)
    return packet
end

local function packedTruncated()
    local packet = buffer.create(6)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 1)
    buffer.writeu8(packet, 3, 0xD9)
    buffer.writeu8(packet, 4, 0)
    return packet
end

local function packedArrayPadding()
    local packet = buffer.create(8)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 3)
    buffer.writeu16(packet, 3, 5)
    buffer.writeu8(packet, 5, 0x80) -- only five bool bits are used
    buffer.writeu16(packet, 6, 0)
    return packet
end

local function packedArrayUnusedEnum()
    local packet = buffer.create(9)
    buffer.writeu8(packet, 0, 1)
    buffer.writeu16(packet, 1, 3)
    buffer.writeu16(packet, 3, 0)
    buffer.writeu16(packet, 5, 3)
    buffer.writeu8(packet, 7, 0xA5) -- first enum code 5 is unused
    buffer.writeu8(packet, 8, 0)
    return packet
end

local function rpcRawReceipt(packet)
    if typeof(packet) ~= "buffer" or buffer.len(packet) < 2 then return nil end
    if buffer.readu8(packet, 0) ~= 1 or buffer.readu8(packet, 1) ~= 5 then return nil end
    return { kind = buffer.readu8(packet, 1), length = buffer.len(packet) }
end

return table.freeze({
    createCompact = createCompact,
    vector3Value = vector3Value,
    vector2Value = vector2Value,
    frameValues = frameValues,
    checkVector3 = checkVector3,
    checkVector2 = checkVector2,
    checkFrames = checkFrames,
    compactUnusedVector3 = compactUnusedVector3,
    compactTruncatedVector3 = compactTruncatedVector3,
    compactUnusedFrame = compactUnusedFrame,
    compactTruncatedFrame = compactTruncatedFrame,
    rawReceipt = rawReceipt,
    createBudget = createBudget,
    createPacked = createPacked,
    packedTupleValues = packedTupleValues,
    packedArrays = packedArrays,
    packedRecord = packedRecord,
    packedTupleObservation = packedTupleObservation,
    packedArrayObservation = packedArrayObservation,
    packedRecordObservation = packedRecordObservation,
    packedRawReceipt = packedRawReceipt,
    packedPaddingMask = packedPaddingMask,
    packedUnusedEnum = packedUnusedEnum,
    packedAbsentValueBits = packedAbsentValueBits,
    packedTruncated = packedTruncated,
    packedArrayPadding = packedArrayPadding,
    packedArrayUnusedEnum = packedArrayUnusedEnum,
    rpcRawReceipt = rpcRawReceipt,
})
