local MAXIMUM_NAME_BYTES = 32
local MAXIMUM_VERSION = 2_147_483_647
local MAXIMUM_EVENTS = 16
local MAXIMUM_EVENT_ID = 65_535
local MAXIMUM_FIELDS = 8
local MAXIMUM_DESCRIPTOR_BYTES = 4_096
local MAXIMUM_STRING_BYTES = 1_024
local MAXIMUM_SCHEMA_DEPTH = 4
local MAXIMUM_SCHEMA_ELEMENTS = 256
local MAXIMUM_AUTHORED_NODES = 256
local MAXIMUM_COMPOSITE_LENGTH = 64
local MAXIMUM_STRUCT_FIELDS = 8
local MAXIMUM_ENUM_VALUES = 32
local MAXIMUM_ENUM_VALUE_BYTES = 32
local MAXIMUM_CODEC_BYTES = 8_192
local UNRELIABLE_CODEC_BYTES = 900
local CODEC_HEADER_BYTES = 3

local DEFINITION_KEYS = table.freeze({
    name = true,
    version = true,
    events = true,
})

local EVENT_KEYS = table.freeze({
    id = true,
    direction = true,
    fields = true,
    delivery = true,
})

local BOOLEAN_FIELD_KEYS = table.freeze({
    type = true,
})

local STRING_FIELD_KEYS = table.freeze({
    type = true,
    maximumBytes = true,
})

local BOUNDED_FIELD_KEYS = table.freeze({
    type = true,
    minimum = true,
    maximum = true,
})

local STRUCT_FIELD_KEYS = table.freeze({ type = true, fields = true })
local ARRAY_FIELD_KEYS = table.freeze({ type = true, element = true, maximumLength = true })
local ENUM_FIELD_KEYS = table.freeze({ type = true, values = true })
local OPTIONAL_FIELD_KEYS = table.freeze({ type = true, value = true })
local SET_FIELD_KEYS = table.freeze({ type = true, element = true, maximumSize = true })

local INTEGER_WIDTHS = table.freeze({
    u8 = 1,
    i8 = 1,
    u16 = 2,
    i16 = 2,
    u32 = 4,
    i32 = 4,
})

local SET_ELEMENT_TYPES = table.freeze({
    boolean = true,
    string = true,
    u8 = true,
    u16 = true,
    u32 = true,
    i8 = true,
    i16 = true,
    i32 = true,
    enum = true,
})

local INTEGER_MINIMUMS = table.freeze({
    u8 = 0,
    u16 = 0,
    u32 = 0,
    i8 = -128,
    i16 = -32_768,
    i32 = -2_147_483_648,
})

local INTEGER_MAXIMUMS = table.freeze({
    u8 = 255,
    u16 = 65_535,
    u32 = 4_294_967_295,
    i8 = 127,
    i16 = 32_767,
    i32 = 2_147_483_647,
})

local TYPE_CODES = table.freeze({
    boolean = "b",
    string = "str",
    u8 = "u8",
    u16 = "u16",
    u32 = "u32",
    i8 = "i8",
    i16 = "i16",
    i32 = "i32",
    f32 = "f32",
    Vector3F32 = "v3f32",
    Vector2F32 = "v2f32",
    CFrame = "cf1",
})

local INVALID_DEFINITION = table.freeze({
    code = "InvalidDefinition",
    message = "definition does not satisfy the Relay v0.1 contract",
})

local errors = { InvalidDefinition = INVALID_DEFINITION }
for code, message in {
    InvalidOptions = "Invalid Relay options.",
    WrongRuntimeSide = "Operation is unavailable on this runtime side.",
    AlreadyStarted = "A Relay session is already starting or started.",
    NotStarted = "Relay session has not started.",
    Destroyed = "Relay session is destroyed.",
    AlreadyConnected = "An event listener is already connected.",
    InvalidHandler = "Event handler must be a function.",
    InvalidPayload = "Payload does not match the event definition.",
    InvalidPlayer = "Target must be a current Player.",
    StartupTimeout = "Relay startup timed out.",
    RemoteOwnershipConflict = "Relay transport ownership conflicts.",
    DefinitionMismatch = "Relay definitions do not match.",
    Disconnected = "Relay transport is disconnected.",
    TransportFailure = "Relay transport operation failed.",
} do
    errors[code] = table.freeze({ code = code, message = message })
end
table.freeze(errors)

local FLOAT32_BUFFER = buffer.create(4)
local HEX_DIGITS = "0123456789abcdef"

-- Values deliberately never refer back to their keys, so registry membership
-- does not extend the lifetime of an otherwise unreachable public token.
local registry = setmetatable({}, table.freeze({ __mode = "k" }))

local function isFinite(value)
    return value == value and value > -math.huge and value < math.huge
end

local function isIntegerInRange(value, minimum, maximum)
    return type(value) == "number"
        and isFinite(value)
        and value % 1 == 0
        and value >= minimum
        and value <= maximum
end

local function isName(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= MAXIMUM_NAME_BYTES
        and string.match(value, "^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

local function scanAllowedKeys(value, allowed, maximumCount)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end

    local count = 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if count > maximumCount or allowed[key] ~= true then
            return nil
        end

        key = next(value, key)
    end

    return count
end

local function normalizeInteger(value)
    if value == 0 then
        return 0
    end

    return value
end

local function normalizeFloat32Bound(value)
    if type(value) ~= "number" or not isFinite(value) then
        return nil
    end

    if value == 0 then
        value = 0
    end

    buffer.writef32(FLOAT32_BUFFER, 0, value)
    local normalized = buffer.readf32(FLOAT32_BUFFER, 0)

    if not isFinite(normalized) or normalized ~= value then
        return nil
    end

    if normalized == 0 then
        return 0
    end

    return normalized
end

local function formatInteger(value)
    return string.format("%.0f", normalizeInteger(value))
end

local function float32Token(value)
    if value == 0 then
        value = 0
    end

    buffer.writef32(FLOAT32_BUFFER, 0, value)
    local bits = buffer.readu32(FLOAT32_BUFFER, 0)
    local characters = table.create(8)

    for index = 8, 1, -1 do
        local digit = bits % 16
        characters[index] = string.sub(HEX_DIGITS, digit + 1, digit + 1)
        bits = math.floor(bits / 16)
    end

    return table.concat(characters)
end

local function scanDenseArray(value, maximumCount)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end

    local count, maximumIndex = 0, 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if count > maximumCount
            or type(key) ~= "number"
            or not isFinite(key)
            or key % 1 ~= 0
            or key < 1
            or key > maximumCount
        then
            return nil
        end

        if key > maximumIndex then maximumIndex = key end
        key = next(value, key)
    end

    if count ~= maximumIndex then return nil end

    return count
end

local function scanShapeKeys(value, allowed, named, maximumCount)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end

    local count = 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if count > maximumCount
            or (key == "name" and not named)
            or (key ~= "name" and allowed[key] ~= true)
        then
            return nil
        end

        key = next(value, key)
    end

    return count
end

local function encodedWidth(fieldType)
    if fieldType == "boolean" or fieldType == "enum" then
        return 1
    elseif INTEGER_WIDTHS[fieldType] ~= nil then
        return INTEGER_WIDTHS[fieldType]
    elseif fieldType == "f32" then
        return 4
    elseif fieldType == "Vector2F32" then
        return 8
    elseif fieldType == "Vector3F32" then
        return 12
    elseif fieldType == "CFrame" then
        return 96
    end

    return nil
end

local function compileShape(value, named, state)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end

    if state.ancestors[value] or state.authoredNodes >= MAXIMUM_AUTHORED_NODES then
        return nil
    end

    state.authoredNodes += 1
    state.ancestors[value] = true

    local fieldType = rawget(value, "type")
    local name = if named then rawget(value, "name") else nil

    if type(fieldType) ~= "string" or (named and not isName(name)) then
        state.ancestors[value] = nil
        return nil
    end

    local isComposite = fieldType == "struct"
        or fieldType == "array"
        or fieldType == "optional"
        or fieldType == "set"
    local maximumDepth = 0

    if isComposite then
        if state.compositeDepth >= MAXIMUM_SCHEMA_DEPTH then
            state.ancestors[value] = nil
            return nil
        end

        state.compositeDepth += 1
        maximumDepth = 1
    end

    local function finish(shape, containsCodec)
        if shape ~= nil
            and (shape.maximumEncodedBytes > MAXIMUM_CODEC_BYTES
                or shape.maximumElements > MAXIMUM_SCHEMA_ELEMENTS
                or shape.maximumDepth > MAXIMUM_SCHEMA_DEPTH)
        then
            shape = nil
        end

        state.ancestors[value] = nil

        if isComposite then
            state.compositeDepth -= 1
        end

        return shape, containsCodec
    end

    local function freezeShape(shape, containsCodec)
        if named then
            shape.name = name
        end

        return finish(table.freeze(shape), containsCodec == true)
    end

    local keyCount
    local allowed

    if fieldType == "boolean" then
        allowed = BOOLEAN_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 2 else 1)
        if keyCount ~= (if named then 2 else 1) then return finish(nil) end
    elseif fieldType == "string" then
        allowed = STRING_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2)
        if keyCount ~= (if named then 3 else 2) then return finish(nil) end
    elseif INTEGER_MAXIMUMS[fieldType] ~= nil then
        allowed = BOUNDED_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3)
        if keyCount == nil or keyCount < (if named then 2 else 1) then return finish(nil) end
    elseif fieldType == "f32" or fieldType == "Vector3F32" or fieldType == "Vector2F32" or fieldType == "CFrame" then
        allowed = BOUNDED_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3)
        if keyCount ~= (if named then 4 else 3) then return finish(nil) end
    elseif fieldType == "struct" then
        allowed = STRUCT_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2)
        if keyCount ~= (if named then 3 else 2) then return finish(nil) end
    elseif fieldType == "array" then
        allowed = ARRAY_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3)
        if keyCount ~= (if named then 4 else 3) then return finish(nil) end
    elseif fieldType == "enum" then
        allowed = ENUM_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2)
        if keyCount ~= (if named then 3 else 2) then return finish(nil) end
    elseif fieldType == "optional" then
        allowed = OPTIONAL_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2)
        if keyCount ~= (if named then 3 else 2) then return finish(nil) end
    elseif fieldType == "set" then
        allowed = SET_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3)
        if keyCount ~= (if named then 4 else 3) then return finish(nil) end
    else
        return finish(nil)
    end

    if fieldType == "boolean" then
        return freezeShape({
            type = fieldType,
            maximumDepth = maximumDepth,
            maximumElements = 1,
            minimumEncodedBytes = 1,
            maximumEncodedBytes = 1,
        })
    end

    if fieldType == "string" then
        local maximumBytes = rawget(value, "maximumBytes")
        if not isIntegerInRange(maximumBytes, 0, MAXIMUM_STRING_BYTES) then return finish(nil) end
        maximumBytes = normalizeInteger(maximumBytes)
        return freezeShape({
            type = fieldType,
            maximumBytes = maximumBytes,
            maximumDepth = maximumDepth,
            maximumElements = 1,
            minimumEncodedBytes = 2,
            maximumEncodedBytes = 2 + maximumBytes,
        })
    end

    if INTEGER_MAXIMUMS[fieldType] ~= nil
        or fieldType == "f32"
        or fieldType == "Vector3F32"
        or fieldType == "Vector2F32"
        or fieldType == "CFrame"
    then
        local minimum = rawget(value, "minimum")
        local maximum = rawget(value, "maximum")
        local baseMinimum = INTEGER_MINIMUMS[fieldType]
        local baseMaximum = INTEGER_MAXIMUMS[fieldType]

        if baseMaximum ~= nil then
            if minimum == nil then
                minimum = baseMinimum
            elseif not isIntegerInRange(minimum, baseMinimum, baseMaximum) then
                return finish(nil)
            end

            if maximum == nil then
                maximum = baseMaximum
            elseif not isIntegerInRange(maximum, baseMinimum, baseMaximum) then
                return finish(nil)
            end

            minimum = normalizeInteger(minimum)
            maximum = normalizeInteger(maximum)
        else
            minimum = normalizeFloat32Bound(minimum)
            maximum = normalizeFloat32Bound(maximum)

            if minimum == nil or maximum == nil then
                return finish(nil)
            end
        end

        if minimum > maximum then
            return finish(nil)
        end

        local width = encodedWidth(fieldType)
        return freezeShape({
            type = fieldType,
            minimum = minimum,
            maximum = maximum,
            maximumDepth = maximumDepth,
            maximumElements = 1,
            minimumEncodedBytes = width,
            maximumEncodedBytes = width,
        })
    end

    if fieldType == "enum" then
        local sourceValues = rawget(value, "values")
        local count = scanDenseArray(sourceValues, MAXIMUM_ENUM_VALUES)

        if count == nil or count == 0 then
            return finish(nil)
        end

        local values = table.create(count)
        local seenValues = {}

        for index = 1, count do
            local enumValue = rawget(sourceValues, index)
            if type(enumValue) ~= "string"
                or #enumValue < 1
                or #enumValue > MAXIMUM_ENUM_VALUE_BYTES
                or seenValues[enumValue]
            then
                return finish(nil)
            end

            seenValues[enumValue] = true
            values[index] = enumValue
        end

        return freezeShape({
            type = fieldType,
            values = table.freeze(values),
            maximumDepth = 0,
            maximumElements = 1,
            minimumEncodedBytes = 1,
            maximumEncodedBytes = 1,
        }, true)
    end

    if fieldType == "struct" then
        local sourceFields = rawget(value, "fields")
        local count = scanDenseArray(sourceFields, MAXIMUM_STRUCT_FIELDS)

        if count == nil then
            return finish(nil)
        end

        local fields = table.create(count)
        local names = {}
        local minimumEncodedBytes = 0
        local maximumEncodedBytes = 0
        local maximumElements = 1
        local childDepth = 0

        for index = 1, count do
            local field = compileShape(rawget(sourceFields, index), true, state)
            if field == nil or names[field.name] then
                return finish(nil)
            end

            names[field.name] = true
            fields[index] = field
            minimumEncodedBytes += field.minimumEncodedBytes
            maximumEncodedBytes += field.maximumEncodedBytes
            maximumElements += field.maximumElements
            childDepth = math.max(childDepth, field.maximumDepth)
        end

        return freezeShape({
            type = fieldType,
            fields = table.freeze(fields),
            maximumDepth = 1 + childDepth,
            maximumElements = maximumElements,
            minimumEncodedBytes = minimumEncodedBytes,
            maximumEncodedBytes = maximumEncodedBytes,
        }, true)
    end

    if fieldType == "array" or fieldType == "set" then
        local capacity = rawget(value, if fieldType == "array" then "maximumLength" else "maximumSize")
        if not isIntegerInRange(capacity, 0, MAXIMUM_COMPOSITE_LENGTH) then
            return finish(nil)
        end

        capacity = normalizeInteger(capacity)
        local element = compileShape(rawget(value, "element"), false, state)
        if element == nil
            or (fieldType == "array" and element.type == "optional")
            or (fieldType == "set" and not SET_ELEMENT_TYPES[element.type])
        then
            return finish(nil)
        end

        local maximumElements = 1 + capacity * element.maximumElements
        local minimumEncodedBytes = 2
        local maximumEncodedBytes = 2 + capacity * element.maximumEncodedBytes

        local shape = {
            type = fieldType,
            element = element,
            maximumDepth = 1 + element.maximumDepth,
            maximumElements = maximumElements,
            minimumEncodedBytes = minimumEncodedBytes,
            maximumEncodedBytes = maximumEncodedBytes,
        }

        if fieldType == "array" then
            shape.maximumLength = capacity
        else
            shape.maximumSize = capacity
        end

        return freezeShape(shape, true)
    end

    if fieldType == "optional" then
        local child = compileShape(rawget(value, "value"), false, state)
        if child == nil or child.type == "optional" then
            return finish(nil)
        end

        local maximumElements = 1 + child.maximumElements

        return freezeShape({
            type = fieldType,
            value = child,
            maximumDepth = 1 + child.maximumDepth,
            maximumElements = maximumElements,
            minimumEncodedBytes = 1,
            maximumEncodedBytes = 1 + child.maximumEncodedBytes,
        }, true)
    end

    return finish(nil)
end

local function compileFields(value, state)
    local count = scanDenseArray(value, MAXIMUM_FIELDS)

    if count == nil then
        return nil
    end

    local fields = table.create(count)
    local names = {}
    local containsCodec = false
    local maximumElements = 0
    local minimumEncodedBytes = 0
    local maximumEncodedBytes = 0

    for index = 1, count do
        local field, fieldUsesCodec = compileShape(rawget(value, index), true, state)

        if field == nil or names[field.name] then
            return nil
        end

        names[field.name] = true
        fields[index] = field
        containsCodec = containsCodec or fieldUsesCodec
        maximumElements += field.maximumElements
        minimumEncodedBytes += field.minimumEncodedBytes
        maximumEncodedBytes += field.maximumEncodedBytes

        if maximumElements > MAXIMUM_SCHEMA_ELEMENTS then
            return nil
        end
    end

    return table.freeze(fields), containsCodec, maximumElements, minimumEncodedBytes, maximumEncodedBytes
end

local function encodeField(field)
    local minimumToken
    local maximumToken

    if field.type == "boolean" then
        minimumToken = "-"
        maximumToken = "-"
    elseif field.type == "string" then
        minimumToken = "-"
        maximumToken = formatInteger(field.maximumBytes)
    elseif field.type == "f32" or field.type == "Vector3F32" or field.type == "Vector2F32" or field.type == "CFrame" then
        minimumToken = float32Token(field.minimum)
        maximumToken = float32Token(field.maximum)
    else
        minimumToken = formatInteger(field.minimum)
        maximumToken = formatInteger(field.maximum)
    end

    return "|F"
        .. formatInteger(#field.name)
        .. ":"
        .. field.name
        .. ","
        .. TYPE_CODES[field.type]
        .. ","
        .. minimumToken
        .. ","
        .. maximumToken
end

local encodeShapeField

local function encodeShape(shape)
    if shape.type == "struct" then
        local pieces = { "T", formatInteger(#shape.fields), "[" }
        for _, field in shape.fields do
            table.insert(pieces, encodeShapeField(field))
        end
        table.insert(pieces, "]")
        return table.concat(pieces)
    elseif shape.type == "array" then
        return "A" .. formatInteger(shape.maximumLength) .. "[" .. encodeShape(shape.element) .. "]"
    elseif shape.type == "set" then
        return "S" .. formatInteger(shape.maximumSize) .. "[" .. encodeShape(shape.element) .. "]"
    elseif shape.type == "optional" then
        return "O[" .. encodeShape(shape.value) .. "]"
    elseif shape.type == "enum" then
        local pieces = { "E", formatInteger(#shape.values), "[" }
        for _, value in shape.values do
            table.insert(pieces, formatInteger(#value))
            table.insert(pieces, ":")
            table.insert(pieces, value)
        end
        table.insert(pieces, "]")
        return table.concat(pieces)
    end

    local minimumToken
    local maximumToken

    if shape.type == "boolean" then
        minimumToken = "-"
        maximumToken = "-"
    elseif shape.type == "string" then
        minimumToken = "-"
        maximumToken = formatInteger(shape.maximumBytes)
    elseif shape.type == "f32"
        or shape.type == "Vector3F32"
        or shape.type == "Vector2F32"
        or shape.type == "CFrame"
    then
        minimumToken = float32Token(shape.minimum)
        maximumToken = float32Token(shape.maximum)
    else
        minimumToken = formatInteger(shape.minimum)
        maximumToken = formatInteger(shape.maximum)
    end

    local typeCode = TYPE_CODES[shape.type]
    return "P" .. formatInteger(#typeCode) .. ":" .. typeCode .. "[" .. minimumToken .. "," .. maximumToken .. "]"
end

encodeShapeField = function(field)
    return "F"
        .. formatInteger(#field.name)
        .. ":"
        .. field.name
        .. "="
        .. encodeShape(field)
end

local function buildDescriptor(name, version, sortedEvents, hasUnreliable, hasCodecShape)
    local pieces = {
        if hasCodecShape then "RR3|D" elseif hasUnreliable then "RR2|D" else "RR1|D",
        formatInteger(#name),
        ":",
        name,
        "|V",
        formatInteger(version),
        "|N",
        formatInteger(#sortedEvents),
    }

    for _, entry in sortedEvents do
        local event = entry.event
        local directionCode = "S"

        if event.direction == "ClientToServer" then
            directionCode = "C"
        end

        table.insert(pieces, "|E")
        table.insert(pieces, formatInteger(entry.id))
        table.insert(pieces, ",")
        table.insert(pieces, directionCode)
        table.insert(pieces, ",")
        if hasUnreliable or hasCodecShape then
            table.insert(pieces, if event.delivery == "Unreliable" then "U" else "R")
            table.insert(pieces, ",")
        end
        table.insert(pieces, formatInteger(#event.name))
        table.insert(pieces, ":")
        table.insert(pieces, event.name)
        table.insert(pieces, ",")
        table.insert(pieces, formatInteger(#event.fields))

        for _, field in event.fields do
            table.insert(pieces, if hasCodecShape then encodeShapeField(field) else encodeField(field))
        end
    end

    local descriptor = table.concat(pieces)

    if #descriptor > MAXIMUM_DESCRIPTOR_BYTES then
        return nil
    end

    return descriptor
end


local function compileDefinition(spec)
    if scanAllowedKeys(spec, DEFINITION_KEYS, 3) ~= 3 then
        return nil
    end

    local name = rawget(spec, "name")
    local version = rawget(spec, "version")
    local events = rawget(spec, "events")

    if not isName(name) or not isIntegerInRange(version, 1, MAXIMUM_VERSION) then
        return nil
    end

    if type(events) ~= "table" or getmetatable(events) ~= nil then
        return nil
    end

    local eventCount = 0
    local seenIds = {}
    local sortedEvents = {}
    local hasUnreliable = false
    local hasCodecShape = false
    local eventName = next(events)

    while eventName ~= nil do
        eventCount += 1

        if eventCount > MAXIMUM_EVENTS or not isName(eventName) then
            return nil
        end

        local sourceEvent = rawget(events, eventName)

        local eventKeyCount = scanAllowedKeys(sourceEvent, EVENT_KEYS, 4)
        if eventKeyCount ~= 3 and eventKeyCount ~= 4 then
            return nil
        end

        local id = rawget(sourceEvent, "id")
        local direction = rawget(sourceEvent, "direction")
        local delivery = rawget(sourceEvent, "delivery")

        if not isIntegerInRange(id, 1, MAXIMUM_EVENT_ID)
            or seenIds[id]
            or (direction ~= "ClientToServer" and direction ~= "ServerToClient")
            or (delivery ~= nil and delivery ~= "Reliable" and delivery ~= "Unreliable")
        then
            return nil
        end

        delivery = delivery or "Reliable"

        local fields, usesCodec, maximumElements, minimumFieldBytes, maximumFieldBytes = compileFields(
            rawget(sourceEvent, "fields"),
            { ancestors = {}, authoredNodes = 0, compositeDepth = 0 }
        )

        if fields == nil then
            return nil
        end

        local minimumEncodedBytes = CODEC_HEADER_BYTES + minimumFieldBytes
        local maximumEncodedBytes = CODEC_HEADER_BYTES + maximumFieldBytes
        local maximumAllowedBytes = if delivery == "Unreliable" then UNRELIABLE_CODEC_BYTES else MAXIMUM_CODEC_BYTES

        if usesCodec and maximumEncodedBytes > maximumAllowedBytes then
            return nil
        end

        seenIds[id] = true
        if delivery == "Unreliable" then
            hasUnreliable = true
        end
        hasCodecShape = hasCodecShape or usesCodec
        table.insert(sortedEvents, {
            id = id,
            event = table.freeze({
                id = id,
                name = eventName,
                direction = direction,
                delivery = delivery,
                fields = fields,
                usesCodec = usesCodec,
                minimumEncodedBytes = minimumEncodedBytes,
                maximumEncodedBytes = maximumEncodedBytes,
                maximumElements = maximumElements,
            }),
        })

        eventName = next(events, eventName)
    end

    if eventCount == 0 then
        return nil
    end

    table.sort(sortedEvents, function(left, right)
        return left.id < right.id
    end)

    local descriptor = buildDescriptor(name, version, sortedEvents, hasUnreliable, hasCodecShape)

    if descriptor == nil then
        return nil
    end

    local eventsById = {}
    local eventsByName = {}

    for _, entry in sortedEvents do
        eventsById[entry.id] = entry.event
        eventsByName[entry.event.name] = entry.event
    end

    return table.freeze({
        name = name,
        version = version,
        hasUnreliable = hasUnreliable,
        descriptor = descriptor,
        byId = table.freeze(eventsById),
        events = table.freeze(eventsByName),
    })
end

local function define(spec)
    local compiled = compileDefinition(spec)

    if compiled == nil then
        return nil, INVALID_DEFINITION
    end

    local token = table.freeze({})
    registry[token] = compiled

    return token, nil
end

local function resolve(value)
    if type(value) ~= "table" then
        return nil
    end

    return registry[value]
end

return table.freeze({
    define = define,
    get = resolve,
    error = function(code)
        return errors[code]
    end,
})
