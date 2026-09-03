local MAXIMUM_NAME_BYTES = 32
local MAXIMUM_VERSION = 2_147_483_647
local MAXIMUM_EVENTS = 16
local MAXIMUM_EVENT_ID = 65_535
local MAXIMUM_FIELDS = 8
local MAXIMUM_DESCRIPTOR_BYTES = 4_096

local DEFINITION_KEYS = table.freeze({
    name = true,
    version = true,
    events = true,
})

local EVENT_KEYS = table.freeze({
    id = true,
    direction = true,
    fields = true,
})

local BOOLEAN_FIELD_KEYS = table.freeze({
    name = true,
    type = true,
})

local BOUNDED_FIELD_KEYS = table.freeze({
    name = true,
    type = true,
    minimum = true,
    maximum = true,
})

local UNSIGNED_MAXIMUMS = table.freeze({
    u8 = 255,
    u16 = 65_535,
    u32 = 4_294_967_295,
})

local TYPE_CODES = table.freeze({
    boolean = "b",
    u8 = "u8",
    u16 = "u16",
    u32 = "u32",
    f32 = "f32",
    Vector3F32 = "v3f32",
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

local function scanDenseFields(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end

    local count = 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if count > MAXIMUM_FIELDS
            or type(key) ~= "number"
            or not isFinite(key)
            or key % 1 ~= 0
            or key < 1
            or key > MAXIMUM_FIELDS
        then
            return nil
        end

        key = next(value, key)
    end

    for index = 1, count do
        if rawget(value, index) == nil then
            return nil
        end
    end

    return count
end

local function compileField(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end

    local fieldType = rawget(value, "type")
    local keyCount

    if type(fieldType) ~= "string" then
        return nil
    end

    if fieldType == "boolean" then
        keyCount = scanAllowedKeys(value, BOOLEAN_FIELD_KEYS, 2)

        if keyCount ~= 2 then
            return nil
        end
    elseif UNSIGNED_MAXIMUMS[fieldType] ~= nil then
        keyCount = scanAllowedKeys(value, BOUNDED_FIELD_KEYS, 4)

        if keyCount == nil or keyCount < 2 then
            return nil
        end
    elseif fieldType == "f32" or fieldType == "Vector3F32" then
        keyCount = scanAllowedKeys(value, BOUNDED_FIELD_KEYS, 4)

        if keyCount ~= 4 then
            return nil
        end
    else
        return nil
    end

    local name = rawget(value, "name")

    if not isName(name) then
        return nil
    end

    if fieldType == "boolean" then
        return table.freeze({
            name = name,
            type = fieldType,
        })
    end

    local minimum = rawget(value, "minimum")
    local maximum = rawget(value, "maximum")
    local baseMaximum = UNSIGNED_MAXIMUMS[fieldType]

    if baseMaximum ~= nil then
        if minimum == nil then
            minimum = 0
        elseif not isIntegerInRange(minimum, 0, baseMaximum) then
            return nil
        end

        if maximum == nil then
            maximum = baseMaximum
        elseif not isIntegerInRange(maximum, 0, baseMaximum) then
            return nil
        end

        minimum = normalizeInteger(minimum)
        maximum = normalizeInteger(maximum)
    else
        minimum = normalizeFloat32Bound(minimum)
        maximum = normalizeFloat32Bound(maximum)

        if minimum == nil or maximum == nil then
            return nil
        end
    end

    if minimum > maximum then
        return nil
    end

    return table.freeze({
        name = name,
        type = fieldType,
        minimum = minimum,
        maximum = maximum,
    })
end

local function compileFields(value)
    local count = scanDenseFields(value)

    if count == nil then
        return nil
    end

    local fields = table.create(count)
    local names = {}

    for index = 1, count do
        local field = compileField(rawget(value, index))

        if field == nil or names[field.name] then
            return nil
        end

        names[field.name] = true
        fields[index] = field
    end

    return table.freeze(fields)
end

local function encodeField(field)
    local minimumToken
    local maximumToken

    if field.type == "boolean" then
        minimumToken = "-"
        maximumToken = "-"
    elseif field.type == "f32" or field.type == "Vector3F32" then
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

local function buildDescriptor(name, version, sortedEvents)
    local pieces = {
        "RR1|D",
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
        table.insert(pieces, formatInteger(#event.name))
        table.insert(pieces, ":")
        table.insert(pieces, event.name)
        table.insert(pieces, ",")
        table.insert(pieces, formatInteger(#event.fields))

        for _, field in event.fields do
            table.insert(pieces, encodeField(field))
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
    local eventName = next(events)

    while eventName ~= nil do
        eventCount += 1

        if eventCount > MAXIMUM_EVENTS or not isName(eventName) then
            return nil
        end

        local sourceEvent = rawget(events, eventName)

        if scanAllowedKeys(sourceEvent, EVENT_KEYS, 3) ~= 3 then
            return nil
        end

        local id = rawget(sourceEvent, "id")
        local direction = rawget(sourceEvent, "direction")

        if not isIntegerInRange(id, 1, MAXIMUM_EVENT_ID)
            or seenIds[id]
            or (direction ~= "ClientToServer" and direction ~= "ServerToClient")
        then
            return nil
        end

        local fields = compileFields(rawget(sourceEvent, "fields"))

        if fields == nil then
            return nil
        end

        seenIds[id] = true
        table.insert(sortedEvents, {
            id = id,
            event = table.freeze({
                id = id,
                name = eventName,
                direction = direction,
                fields = fields,
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

    local descriptor = buildDescriptor(name, version, sortedEvents)

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
