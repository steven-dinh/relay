local MAXIMUM_ALLOWLIST_VALUES = 32
local MAXIMUM_FONT_FAMILY_BYTES = 256
local MAXIMUM_SEQUENCE_KEYPOINTS = 20
local MINIMUM_SEQUENCE_KEYPOINTS = 2
local MAXIMUM_LABEL_BYTES = 1_024
local MAXIMUM_I32 = 2_147_483_647
local MINIMUM_I32 = -2_147_483_648
local MAXIMUM_I16 = 32_767
local MINIMUM_I16 = -32_768
local MINIMUM_DATE_MILLISECONDS = -17_987_443_200_000
local MAXIMUM_DATE_MILLISECONDS = 253_402_300_799_999
local densityBytes = buffer.create(4)
buffer.writef32(densityBytes, 0, 0.0001)
local FLOAT32_MINIMUM_DENSITY = buffer.readf32(densityBytes, 0)

local function keys(...)
    local result = {}
    for _, key in { ... } do result[key] = true end
    return table.freeze({ allowed = table.freeze(result), maximumCount = select("#", ...) })
end

local ALLOWED_KEYS = table.freeze({
    robloxEnum = keys("type", "values"),
    UDim = keys("type", "minimumScale", "maximumScale", "minimumOffset", "maximumOffset"),
    UDim2 = keys("type", "minimumScale", "maximumScale", "minimumOffset", "maximumOffset"),
    NumberRange = keys("type", "minimum", "maximum"),
    Rect = keys("type", "minimum", "maximum"),
    BrickColor = keys("type", "values"),
    Vector2int16 = keys("type", "minimum", "maximum"),
    Vector3int16 = keys("type", "minimum", "maximum"),
    NumberSequence = keys("type", "maximumKeypoints", "minimum", "maximum", "maximumEnvelope"),
    ColorSequence = keys("type", "maximumKeypoints"),
    NumberSequenceKeypoint = keys("type", "minimum", "maximum", "maximumEnvelope"),
    ColorSequenceKeypoint = keys("type"),
    TweenInfo = keys("type", "maximumTime", "maximumDelayTime", "maximumRepeatCount", "allowInfiniteRepeat"),
    DateTime = keys("type", "minimum", "maximum"),
    Ray = keys("type", "minimum", "maximum", "maximumDirectionMagnitude"),
    Axes = keys("type"),
    Faces = keys("type"),
    Region3 = keys("type", "minimum", "maximum"),
    Region3int16 = keys("type", "minimum", "maximum"),
    PhysicalProperties = keys("type"),
    Font = keys("type", "families"),
    PathWaypoint = keys("type", "minimum", "maximum", "maximumLabelBytes"),
})

local function policy(...)
    local values = table.create(select("#", ...) / 2)
    for index = 1, select("#", ...), 2 do
        values[#values + 1] = table.freeze({ name = select(index, ...), value = select(index + 1, ...) })
    end
    return table.freeze(values)
end

local ENUM_POLICIES = table.freeze({
    EasingStyle = policy("Linear", 0, "Sine", 1, "Back", 2, "Quad", 3, "Quart", 4, "Quint", 5,
        "Bounce", 6, "Elastic", 7, "Exponential", 8, "Circular", 9, "Cubic", 10),
    EasingDirection = policy("In", 0, "Out", 1, "InOut", 2),
    FontWeight = policy("Thin", 100, "ExtraLight", 200, "Light", 300, "Regular", 400,
        "Medium", 500, "SemiBold", 600, "Bold", 700, "ExtraBold", 800, "Heavy", 900),
    FontStyle = policy("Normal", 0, "Italic", 1),
    PathWaypointAction = policy("Walk", 0, "Jump", 1, "Custom", 2),
})

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function canonicalZero(value)
    return if value == 0 then 0 else value
end

local function integerInRange(value, minimum, maximum)
    return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function floatToken(value)
    local bytes = buffer.create(8)
    buffer.writef64(bytes, 0, canonicalZero(value))
    return string.format("%08x%08x", buffer.readu32(bytes, 4), buffer.readu32(bytes, 0))
end

local function integerToken(value)
    return string.format("%.0f", if value == 0 then 0 else value)
end

local function stringToken(value)
    return tostring(#value) .. ":" .. value
end

local function descriptor(kind, parts)
    return "N" .. tostring(#kind) .. ":" .. kind .. "[" .. table.concat(parts, ",") .. "]"
end

local function compileResult(kind, minimumBytes, maximumBytes, maximumDepth, maximumElements, parts, fields)
    local result = {
        type = kind,
        native = true,
        containsCodec = true,
        maximumDepth = maximumDepth,
        maximumElements = maximumElements,
        minimumEncodedBytes = minimumBytes,
        maximumEncodedBytes = maximumBytes,
        descriptorToken = descriptor(kind, parts),
    }
    for key, value in fields do result[key] = value end
    return result
end

local function readFloat(source, key, suffix)
    local value = rawget(source, key)
    if not finite(value) then return nil, suffix, "must be a finite number" end
    return canonicalZero(value)
end

local function readFloatPair(source, firstKey, secondKey)
    local first, suffix, reason = readFloat(source, firstKey, "." .. firstKey)
    if first == nil then return nil, nil, suffix, reason end
    local second
    second, suffix, reason = readFloat(source, secondKey, "." .. secondKey)
    if second == nil then return nil, nil, suffix, reason end
    if first > second then return nil, nil, "." .. secondKey, "must be greater than or equal to " .. firstKey end
    return first, second
end

local function readScalarBounds(source, minimumDefault, maximumDefault, integer)
    local minimum = rawget(source, "minimum")
    local maximum = rawget(source, "maximum")
    if minimum == nil then minimum = minimumDefault end
    if maximum == nil then maximum = maximumDefault end
    if integer then
        if not integerInRange(minimum, MINIMUM_I16, MAXIMUM_I16) then
            return nil, nil, ".minimum", "must be a signed 16-bit integer"
        end
        if not integerInRange(maximum, MINIMUM_I16, MAXIMUM_I16) then
            return nil, nil, ".maximum", "must be a signed 16-bit integer"
        end
    else
        if not finite(minimum) then return nil, nil, ".minimum", "must be a finite number" end
        if not finite(maximum) then return nil, nil, ".maximum", "must be a finite number" end
        minimum, maximum = canonicalZero(minimum), canonicalZero(maximum)
    end
    if minimum > maximum then return nil, nil, ".maximum", "must be greater than or equal to minimum" end
    return minimum, maximum, nil, nil, {
        if integer then integerToken(minimum) else floatToken(minimum),
        if integer then integerToken(maximum) else floatToken(maximum),
    }
end

local function denseArray(source, maximumCount, suffix)
    if type(source) ~= "table" or getmetatable(source) ~= nil then
        return nil, suffix, "must be a plain dense array"
    end
    local count, maximumIndex = 0, 0
    local key = next(source)
    while key ~= nil do
        count += 1
        if count > maximumCount then return nil, suffix, "contains too many values" end
        if not integerInRange(key, 1, maximumCount) then return nil, suffix, "must be a dense array" end
        maximumIndex = math.max(maximumIndex, key)
        key = next(source, key)
    end
    if count ~= maximumIndex then return nil, suffix, "must be a dense array" end
    return count
end

local function enumValues(source)
    local sourceValues = rawget(source, "values")
    local count, suffix, reason = denseArray(sourceValues, MAXIMUM_ALLOWLIST_VALUES, ".values")
    if count == nil then return nil, suffix, reason end
    if count < 1 then return nil, ".values", "must contain 1 to 32 values" end
    local values = table.create(count)
    local names, numbers = {}, {}
    local enumType, enumFamily
    local parts = { tostring(count) }
    for index = 1, count do
        local item = rawget(sourceValues, index)
        if typeof(item) ~= "EnumItem" then return nil, string.format(".values[%d]", index), "must be an EnumItem" end
        local itemType, name, value = item.EnumType, item.Name, item.Value
        local family = tostring(itemType)
		if type(family) ~= "string" or #family < 1
			or type(name) ~= "string" or #name < 1
            or not integerInRange(value, MINIMUM_I32, MAXIMUM_I32) then
            return nil, string.format(".values[%d]", index), "must have a bounded enum family, name, and signed 32-bit value"
        end
        if index == 1 then
            enumType, enumFamily = itemType, family
        elseif itemType ~= enumType or family ~= enumFamily then
            return nil, string.format(".values[%d]", index), "all EnumItems must belong to one family"
        end
        if names[name] or numbers[value] then return nil, string.format(".values[%d]", index), "enum names and values must be unique" end
        names[name], numbers[value] = true, true
        values[index] = item
        parts[#parts + 1] = stringToken(name)
        parts[#parts + 1] = integerToken(value)
    end
    parts[#parts + 1] = stringToken(enumFamily)
    return table.freeze(values), enumType, enumFamily, parts
end

local function brickColors(source)
    local sourceValues = rawget(source, "values")
    local count, suffix, reason = denseArray(sourceValues, MAXIMUM_ALLOWLIST_VALUES, ".values")
    if count == nil then return nil, suffix, reason end
    if count < 1 then return nil, ".values", "must contain 1 to 32 values" end
    local values = table.create(count)
    local numbers, parts = {}, { tostring(count) }
    for index = 1, count do
        local color = rawget(sourceValues, index)
        if typeof(color) ~= "BrickColor" then return nil, string.format(".values[%d]", index), "must be a BrickColor" end
        local number = color.Number
        if not integerInRange(number, 0, 65_535) then
            return nil, string.format(".values[%d]", index), "must have a 16-bit palette number"
        end
        if numbers[number] then return nil, string.format(".values[%d]", index), "duplicate BrickColor palette number" end
        numbers[number] = true
        values[index] = color
        parts[#parts + 1] = integerToken(number)
    end
    return table.freeze(values), parts
end

local function fontFamilies(source)
    local sourceFamilies = rawget(source, "families")
    local count, suffix, reason = denseArray(sourceFamilies, MAXIMUM_ALLOWLIST_VALUES, ".families")
    if count == nil then return nil, suffix, reason end
    if count < 1 then return nil, ".families", "must contain 1 to 32 values" end
    local families, seen, parts = table.create(count), {}, { tostring(count) }
    for index = 1, count do
        local family = rawget(sourceFamilies, index)
        if type(family) ~= "string" or #family < 1 or #family > MAXIMUM_FONT_FAMILY_BYTES then
            return nil, string.format(".families[%d]", index), "must be a string of 1 to 256 bytes"
        end
        if seen[family] then return nil, string.format(".families[%d]", index), "duplicate font family" end
        seen[family] = true
        families[index] = family
        parts[#parts + 1] = stringToken(family)
    end
    return table.freeze(families), parts
end

local function addPolicies(parts, ...)
    local copied = {}
    for _, family in { ... } do
        local values = ENUM_POLICIES[family]
        copied[family] = values
        parts[#parts + 1] = stringToken(family)
        parts[#parts + 1] = tostring(#values)
        for _, item in values do
            parts[#parts + 1] = stringToken(item.name)
            parts[#parts + 1] = integerToken(item.value)
        end
    end
    return table.freeze(copied)
end

local function compile(source)
    if type(source) ~= "table" or getmetatable(source) ~= nil then
        return nil, "", "must be a plain shape table without a metatable"
    end
    local kind = rawget(source, "type")
    if type(kind) ~= "string" or ALLOWED_KEYS[kind] == nil then return nil, ".type", "unsupported native shape type" end
    local parts, fields = {}, {}
    local minimumBytes, maximumBytes, maximumDepth, maximumElements

    if kind == "robloxEnum" then
        local values, enumType, enumFamily, enumParts = enumValues(source)
        if values == nil then return nil, enumType, enumFamily end
        parts = enumParts
        fields.values, fields.enumType, fields.enumFamily = values, enumType, enumFamily
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 4, 4, 0, 1
    elseif kind == "BrickColor" then
        local values, colorParts, reason = brickColors(source)
        if values == nil then return nil, colorParts, reason end
        parts, fields.values = colorParts, values
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 2, 2, 0, 1
    elseif kind == "UDim" or kind == "UDim2" then
        local minScale, maxScale, suffix, reason = readFloatPair(source, "minimumScale", "maximumScale")
        if minScale == nil then return nil, suffix, reason end
        local minOffset, maxOffset = rawget(source, "minimumOffset"), rawget(source, "maximumOffset")
        if not integerInRange(minOffset, MINIMUM_I32, MAXIMUM_I32) then return nil, ".minimumOffset", "must be a signed 32-bit integer" end
        if not integerInRange(maxOffset, MINIMUM_I32, MAXIMUM_I32) then return nil, ".maximumOffset", "must be a signed 32-bit integer" end
        if minOffset > maxOffset then return nil, ".maximumOffset", "must be greater than or equal to minimumOffset" end
        fields.minimumScale, fields.maximumScale = minScale, maxScale
        fields.minimumOffset, fields.maximumOffset = minOffset, maxOffset
        parts = { floatToken(minScale), floatToken(maxScale), integerToken(minOffset), integerToken(maxOffset) }
        minimumBytes, maximumBytes, maximumDepth, maximumElements = if kind == "UDim" then 12 else 24, if kind == "UDim" then 12 else 24, 0, 1
    elseif kind == "NumberRange" then
        local minimum, maximum, suffix, reason = readFloatPair(source, "minimum", "maximum")
        if minimum == nil then return nil, suffix, reason end
        fields.minimum, fields.maximum = minimum, maximum
        parts = { floatToken(minimum), floatToken(maximum) }
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 16, 16, 0, 1
    elseif kind == "Rect" then
        local minimum, maximum, suffix, reason, boundParts = readScalarBounds(source, nil, nil, false)
        if minimum == nil then return nil, suffix, reason end
        fields.minimum, fields.maximum = minimum, maximum
        parts = boundParts
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 32, 32, 0, 1
    elseif kind == "Vector2int16" or kind == "Vector3int16" or kind == "Region3int16" then
        local minimum, maximum, suffix, reason, vectorParts = readScalarBounds(source, MINIMUM_I16, MAXIMUM_I16, true)
        if minimum == nil then return nil, suffix, reason end
        fields.minimum, fields.maximum = minimum, maximum
        parts = vectorParts
        minimumBytes, maximumBytes, maximumDepth, maximumElements = if kind == "Vector2int16" then 4 else if kind == "Vector3int16" then 6 else 12,
            if kind == "Vector2int16" then 4 else if kind == "Vector3int16" then 6 else 12, 0, 1
    elseif kind == "NumberSequence" or kind == "ColorSequence" then
        local maximumKeypoints = rawget(source, "maximumKeypoints")
        if not integerInRange(maximumKeypoints, MINIMUM_SEQUENCE_KEYPOINTS, MAXIMUM_SEQUENCE_KEYPOINTS) then
            return nil, ".maximumKeypoints", "must be an integer from 2 to 20"
        end
        fields.maximumKeypoints = maximumKeypoints
        parts = { integerToken(maximumKeypoints) }
        if kind == "NumberSequence" then
            local minimum, maximum, suffix, reason = readFloatPair(source, "minimum", "maximum")
            if minimum == nil then return nil, suffix, reason end
            local maximumEnvelope
            maximumEnvelope, suffix, reason = readFloat(source, "maximumEnvelope", ".maximumEnvelope")
            if maximumEnvelope == nil then return nil, suffix, reason end
            if maximumEnvelope < 0 then return nil, ".maximumEnvelope", "must be greater than or equal to zero" end
            fields.minimum, fields.maximum, fields.maximumEnvelope = minimum, maximum, maximumEnvelope
            parts[#parts + 1], parts[#parts + 2], parts[#parts + 3] = floatToken(minimum), floatToken(maximum), floatToken(maximumEnvelope)
            minimumBytes, maximumBytes = 1 + MINIMUM_SEQUENCE_KEYPOINTS * 24, 1 + maximumKeypoints * 24
        else
            minimumBytes, maximumBytes = 1 + MINIMUM_SEQUENCE_KEYPOINTS * 32, 1 + maximumKeypoints * 32
        end
        maximumDepth, maximumElements = 1, 1 + maximumKeypoints
    elseif kind == "NumberSequenceKeypoint" then
        local minimum, maximum, suffix, reason = readFloatPair(source, "minimum", "maximum")
        if minimum == nil then return nil, suffix, reason end
        local maximumEnvelope
        maximumEnvelope, suffix, reason = readFloat(source, "maximumEnvelope", ".maximumEnvelope")
        if maximumEnvelope == nil then return nil, suffix, reason end
        if maximumEnvelope < 0 then return nil, ".maximumEnvelope", "must be greater than or equal to zero" end
        fields.minimum, fields.maximum, fields.maximumEnvelope = minimum, maximum, maximumEnvelope
        parts = { floatToken(minimum), floatToken(maximum), floatToken(maximumEnvelope) }
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 24, 24, 0, 1
    elseif kind == "ColorSequenceKeypoint" then
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 32, 32, 0, 1
    elseif kind == "TweenInfo" then
        local maximumTime, suffix, reason = readFloat(source, "maximumTime", ".maximumTime")
        if maximumTime == nil then return nil, suffix, reason end
        local maximumDelayTime
        maximumDelayTime, suffix, reason = readFloat(source, "maximumDelayTime", ".maximumDelayTime")
        if maximumDelayTime == nil then return nil, suffix, reason end
        local maximumRepeatCount = rawget(source, "maximumRepeatCount")
        if not integerInRange(maximumRepeatCount, 0, MAXIMUM_I32) then return nil, ".maximumRepeatCount", "must be a nonnegative signed 32-bit integer" end
        local allowInfiniteRepeat = rawget(source, "allowInfiniteRepeat")
        if allowInfiniteRepeat == nil then allowInfiniteRepeat = false end
        if type(allowInfiniteRepeat) ~= "boolean" then return nil, ".allowInfiniteRepeat", "must be a boolean" end
        if maximumTime < 0 then return nil, ".maximumTime", "must be greater than or equal to zero" end
        if maximumDelayTime < 0 then return nil, ".maximumDelayTime", "must be greater than or equal to zero" end
        fields.maximumTime, fields.maximumDelayTime = maximumTime, maximumDelayTime
        fields.maximumRepeatCount, fields.allowInfiniteRepeat = maximumRepeatCount, allowInfiniteRepeat
        parts = { floatToken(maximumTime), floatToken(maximumDelayTime), integerToken(maximumRepeatCount), if allowInfiniteRepeat then "1" else "0" }
        fields.enumPolicies = addPolicies(parts, "EasingStyle", "EasingDirection")
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 29, 29, 0, 1
    elseif kind == "DateTime" then
        local minimum, maximum, suffix, reason = readFloatPair(source, "minimum", "maximum")
        if minimum == nil then return nil, suffix, reason end
        if not integerInRange(minimum, MINIMUM_DATE_MILLISECONDS, MAXIMUM_DATE_MILLISECONDS) then return nil, ".minimum", "must be an in-range integer Unix millisecond value" end
        if not integerInRange(maximum, MINIMUM_DATE_MILLISECONDS, MAXIMUM_DATE_MILLISECONDS) then return nil, ".maximum", "must be an in-range integer Unix millisecond value" end
        fields.minimum, fields.maximum = minimum, maximum
        parts = { integerToken(minimum), integerToken(maximum) }
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 8, 8, 0, 1
    elseif kind == "Ray" then
        local minimum, maximum, suffix, reason, boundParts = readScalarBounds(source, nil, nil, false)
        if minimum == nil then return nil, suffix, reason end
        local maximumDirectionMagnitude
        maximumDirectionMagnitude, suffix, reason = readFloat(source, "maximumDirectionMagnitude", ".maximumDirectionMagnitude")
        if maximumDirectionMagnitude == nil then return nil, suffix, reason end
        if maximumDirectionMagnitude < 0 then return nil, ".maximumDirectionMagnitude", "must be greater than or equal to zero" end
        fields.minimum, fields.maximum = minimum, maximum
        fields.maximumDirectionMagnitude = maximumDirectionMagnitude
        parts = { boundParts[1], boundParts[2], floatToken(maximumDirectionMagnitude) }
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 48, 48, 0, 1
    elseif kind == "Axes" then
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 1, 1, 0, 1
    elseif kind == "Faces" then
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 1, 1, 0, 1
    elseif kind == "Region3" then
        local minimum, maximum, suffix, reason, boundParts = readScalarBounds(source, nil, nil, false)
        if minimum == nil then return nil, suffix, reason end
        fields.minimum, fields.maximum = minimum, maximum
        parts = boundParts
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 48, 48, 0, 1
    elseif kind == "PhysicalProperties" then
        parts = {
            floatToken(FLOAT32_MINIMUM_DENSITY), floatToken(100), floatToken(0), floatToken(2),
            floatToken(0), floatToken(1), floatToken(0), floatToken(100), floatToken(0), floatToken(100),
            floatToken(0), floatToken(1),
        }
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 48, 48, 0, 1
    elseif kind == "Font" then
        local families, familyParts, reason = fontFamilies(source)
        if families == nil then return nil, familyParts, reason end
        fields.families = families
        parts = familyParts
        fields.enumPolicies = addPolicies(parts, "FontWeight", "FontStyle")
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 9, 9, 0, 1
    elseif kind == "PathWaypoint" then
        local minimum, maximum, suffix, reason, boundParts = readScalarBounds(source, nil, nil, false)
        if minimum == nil then return nil, suffix, reason end
        local maximumLabelBytes = rawget(source, "maximumLabelBytes")
        if not integerInRange(maximumLabelBytes, 0, MAXIMUM_LABEL_BYTES) then return nil, ".maximumLabelBytes", "must be an integer from 0 to 1024" end
        fields.minimum, fields.maximum = minimum, maximum
        fields.maximumLabelBytes = maximumLabelBytes
        parts = { boundParts[1], boundParts[2], integerToken(maximumLabelBytes) }
        fields.enumPolicies = addPolicies(parts, "PathWaypointAction")
        minimumBytes, maximumBytes, maximumDepth, maximumElements = 30, 30 + maximumLabelBytes, 0, 1
    end

    return compileResult(kind, minimumBytes, maximumBytes, maximumDepth, maximumElements, parts, fields)
end

return table.freeze({
    keys = function(kind)
        local entry = ALLOWED_KEYS[kind]
        if entry == nil then return nil end
        return entry.allowed, entry.maximumCount
    end,
    compile = compile,
})
