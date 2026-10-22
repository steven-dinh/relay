-- Native value cases used by the Studio-only multi-client proof.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local NativeSchema = require(ReplicatedStorage.Relay.internal.NativeSchema)
local NativeCodec = require(ReplicatedStorage.Relay.internal.NativeCodec)
local schema = Relay.schema

local function vector2(x, y)
    return Vector2.new(x, y)
end

local function vector3(x, y, z)
    return Vector3.new(x, y, z)
end

local function sameVector2(actual, expected)
    return actual.X == expected.X and actual.Y == expected.Y
end

local function sameVector3(actual, expected)
    return actual.X == expected.X and actual.Y == expected.Y and actual.Z == expected.Z
end

local function sameColor3(actual, expected)
    return actual.R == expected.R and actual.G == expected.G and actual.B == expected.B
end

local function keypoint(kind, time, value, envelope)
    if kind == "NumberSequenceKeypoint" then
        return NumberSequenceKeypoint.new(time, value, envelope)
    end
    return ColorSequenceKeypoint.new(time, value)
end

local function exact(kind, typeofName, actual, expected)
    assert(typeof(actual) == typeofName, kind .. " native typeof")
    if kind == "robloxEnum" then
        assert(actual == expected, "native enum family/value")
    elseif kind == "UDim" then
        assert(actual.Scale == expected.Scale and actual.Offset == expected.Offset, kind .. " components")
    elseif kind == "UDim2" then
        assert(actual.X.Scale == expected.X.Scale and actual.X.Offset == expected.X.Offset
            and actual.Y.Scale == expected.Y.Scale and actual.Y.Offset == expected.Y.Offset, kind .. " components")
    elseif kind == "NumberRange" then
        assert(actual.Min == expected.Min and actual.Max == expected.Max, kind .. " endpoints")
    elseif kind == "Rect" then
        assert(sameVector2(actual.Min, expected.Min) and sameVector2(actual.Max, expected.Max), kind .. " corners")
    elseif kind == "BrickColor" then
        assert(actual.Number == expected.Number and actual.Name == expected.Name, kind .. " palette identity")
    elseif kind == "Vector2int16" then
        assert(actual.X == expected.X and actual.Y == expected.Y, kind .. " components")
    elseif kind == "Vector3int16" then
        assert(actual.X == expected.X and actual.Y == expected.Y and actual.Z == expected.Z, kind .. " components")
    elseif kind == "NumberSequence" or kind == "ColorSequence" then
        assert(#actual.Keypoints == #expected.Keypoints, kind .. " keypoint count")
        for index, point in actual.Keypoints do
            local expectedPoint = expected.Keypoints[index]
            assert(point.Time == expectedPoint.Time, kind .. " keypoint time")
            if kind == "NumberSequence" then
                assert(point.Value == expectedPoint.Value and point.Envelope == expectedPoint.Envelope,
                    kind .. " keypoint number/envelope")
            else
                assert(sameColor3(point.Value, expectedPoint.Value), kind .. " keypoint color")
            end
        end
    elseif kind == "NumberSequenceKeypoint" then
        assert(actual.Time == expected.Time and actual.Value == expected.Value
            and actual.Envelope == expected.Envelope, kind .. " properties")
    elseif kind == "ColorSequenceKeypoint" then
        assert(actual.Time == expected.Time and sameColor3(actual.Value, expected.Value), kind .. " properties")
    elseif kind == "TweenInfo" then
        assert(actual.Time == expected.Time and actual.DelayTime == expected.DelayTime
            and actual.RepeatCount == expected.RepeatCount and actual.Reverses == expected.Reverses
            and actual.EasingStyle == expected.EasingStyle and actual.EasingDirection == expected.EasingDirection,
            kind .. " properties")
    elseif kind == "DateTime" then
        assert(actual.UnixTimestampMillis == expected.UnixTimestampMillis, kind .. " epoch milliseconds")
    elseif kind == "Ray" then
        assert(sameVector3(actual.Origin, expected.Origin) and sameVector3(actual.Direction, expected.Direction),
            kind .. " origin/direction")
    elseif kind == "Axes" then
        assert(actual.X == expected.X and actual.Y == expected.Y and actual.Z == expected.Z, kind .. " mask")
    elseif kind == "Faces" then
        assert(actual.Back == expected.Back and actual.Bottom == expected.Bottom and actual.Front == expected.Front
            and actual.Left == expected.Left and actual.Right == expected.Right and actual.Top == expected.Top,
            kind .. " mask")
    elseif kind == "Region3" then
        assert(sameVector3(actual.CFrame.Position, expected.CFrame.Position)
            and sameVector3(actual.Size, expected.Size), kind .. " center/size")
    elseif kind == "Region3int16" then
        assert(actual.Min.X == expected.Min.X and actual.Min.Y == expected.Min.Y and actual.Min.Z == expected.Min.Z
            and actual.Max.X == expected.Max.X and actual.Max.Y == expected.Max.Y and actual.Max.Z == expected.Max.Z,
            kind .. " stored corners")
    elseif kind == "PhysicalProperties" then
        assert(actual.Density == expected.Density and actual.Friction == expected.Friction
            and actual.Elasticity == expected.Elasticity and actual.FrictionWeight == expected.FrictionWeight
            and actual.ElasticityWeight == expected.ElasticityWeight
            and actual.AcousticAbsorption == expected.AcousticAbsorption, kind .. " six properties")
    elseif kind == "Font" then
        assert(actual.Family == expected.Family and actual.Weight == expected.Weight and actual.Style == expected.Style,
            kind .. " family/weight/style")
    elseif kind == "PathWaypoint" then
        assert(sameVector3(actual.Position, expected.Position) and actual.Action == expected.Action
            and actual.Label == expected.Label, kind .. " position/action/label")
    else
        error("unhandled native value: " .. kind)
    end
end

local function densityMinimum()
    local encoded = buffer.create(4)
    buffer.writef32(encoded, 0, 0.0001)
    return buffer.readf32(encoded, 0)
end

local dateMinimum = -17_987_443_200_000
local dateMaximum = 253_402_300_799_999
local dateSamples = { dateMinimum, 1_700_000_000_123, dateMaximum }

local function sequencePoints(color)
    local points = table.create(20)
    for index = 0, 19 do
        local time = index / 19
        if color then
            points[index + 1] = ColorSequenceKeypoint.new(time,
                Color3.new(time, 1 - time, (index % 2)))
        else
            points[index + 1] = NumberSequenceKeypoint.new(time, index - 10, 0.5)
        end
    end
    return points
end

local sourceSans = "rbxasset://fonts/families/SourceSansPro.json"
local lowCorner3, highCorner3 = vector3(-4, -5, -6), vector3(4, 5, 6)
local reversedLow3, reversedHigh3 = highCorner3, lowCorner3
local reversedLow16, reversedHigh16 = Vector3int16.new(4, 5, 6), Vector3int16.new(-4, -5, -6)

local groups: { any } = {}
groups = {
    {
        name = "basic",
        cases = {
            { name = "robloxEnum", shape = schema.robloxEnum(Enum.Material.Grass, Enum.Material.Sand),
                make = function(index) return if index == 1 then Enum.Material.Grass else Enum.Material.Sand end,
                check = function(value, index)
                    exact("robloxEnum", "EnumItem", value, if index == 1 then Enum.Material.Grass else Enum.Material.Sand)
                end },
            { name = "UDim", shape = schema.UDim(-1, 1, -16, 16),
                make = function() return UDim.new(0.25, -12) end,
                check = function(value) exact("UDim", "UDim", value, UDim.new(0.25, -12)) end },
            { name = "UDim2", shape = schema.UDim2(-1, 1, -16, 16),
                make = function() return UDim2.new(0.25, -12, -0.5, 8) end,
                check = function(value) exact("UDim2", "UDim2", value, UDim2.new(0.25, -12, -0.5, 8)) end },
            { name = "NumberRange", shape = schema.NumberRange(-2, 4),
                make = function() return NumberRange.new(-1, 3) end,
                check = function(value) exact("NumberRange", "NumberRange", value, NumberRange.new(-1, 3)) end },
            { name = "Rect", shape = schema.Rect(-4, 4),
                make = function() return Rect.new(vector2(-3, -2), vector2(3, 2)) end,
                check = function(value) exact("Rect", "Rect", value, Rect.new(vector2(-3, -2), vector2(3, 2))) end },
            { name = "BrickColor", shape = schema.BrickColor(BrickColor.new("Bright red"), BrickColor.new("Bright blue")),
                make = function(index) return BrickColor.new(if index == 1 then "Bright red" else "Bright blue") end,
                check = function(value, index)
                    local expected = BrickColor.new(if index == 1 then "Bright red" else "Bright blue")
                    exact("BrickColor", "BrickColor", value, expected)
                end },
        },
    },
    {
        name = "vectors-sequences",
        cases = {
            { name = "Vector2int16", shape = schema.Vector2int16(-100, 100),
                make = function() return Vector2int16.new(-12, 34) end,
                check = function(value) exact("Vector2int16", "Vector2int16", value, Vector2int16.new(-12, 34)) end },
            { name = "Vector3int16", shape = schema.Vector3int16(-100, 100),
                make = function() return Vector3int16.new(-12, 34, -56) end,
                check = function(value) exact("Vector3int16", "Vector3int16", value, Vector3int16.new(-12, 34, -56)) end },
            { name = "NumberSequence", shape = schema.NumberSequence(20, -10, 10, 1),
                make = function() return NumberSequence.new(sequencePoints(false)) end,
                check = function(value) exact("NumberSequence", "NumberSequence", value, groups[2].cases[3].make()) end },
            { name = "ColorSequence", shape = schema.ColorSequence(20),
                make = function() return ColorSequence.new(sequencePoints(true)) end,
                check = function(value) exact("ColorSequence", "ColorSequence", value, groups[2].cases[4].make()) end },
            { name = "NumberSequenceKeypoint", shape = schema.NumberSequenceKeypoint(-2, 2, 1),
                make = function() return keypoint("NumberSequenceKeypoint", 0.5, 1, 0.25) end,
                check = function(value) exact("NumberSequenceKeypoint", "NumberSequenceKeypoint", value,
                    keypoint("NumberSequenceKeypoint", 0.5, 1, 0.25)) end },
            { name = "ColorSequenceKeypoint", shape = schema.ColorSequenceKeypoint(),
                make = function() return keypoint("ColorSequenceKeypoint", 0.5, Color3.fromRGB(40, 120, 220)) end,
                check = function(value) exact("ColorSequenceKeypoint", "ColorSequenceKeypoint", value,
                    keypoint("ColorSequenceKeypoint", 0.5, Color3.fromRGB(40, 120, 220))) end },
        },
    },
    {
        name = "geometry-time-font",
        cases = {
            { name = "TweenInfo", shape = schema.TweenInfo(4, 1, 4, false),
                make = function()
                    return TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true, 0.25)
                end,
                check = function(value) exact("TweenInfo", "TweenInfo", value,
                    TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true, 0.25)) end },
            { name = "DateTime", shape = schema.DateTime(dateMinimum, dateMaximum),
                make = function(index)
                    local value = DateTime.fromUnixTimestampMillis(dateSamples[index])
                    assert(value.UnixTimestampMillis == dateSamples[index], "DateTime source milliseconds are exact")
                    return value
                end,
                check = function(value, index)
                    exact("DateTime", "DateTime", value, DateTime.fromUnixTimestampMillis(dateSamples[index]))
                end },
            { name = "Ray", shape = schema.Ray(-4, 4, 10),
                make = function() return Ray.new(vector3(1, 2, 3), vector3(3, 4, 0)) end,
                check = function(value) exact("Ray", "Ray", value, Ray.new(vector3(1, 2, 3), vector3(3, 4, 0))) end },
            { name = "Axes", shape = schema.Axes(),
                make = function() return Axes.new(Enum.Axis.X, Enum.Axis.Z) end,
                check = function(value) exact("Axes", "Axes", value, Axes.new(Enum.Axis.X, Enum.Axis.Z)) end },
            { name = "Faces", shape = schema.Faces(),
                make = function() return Faces.new(Enum.NormalId.Right, Enum.NormalId.Top) end,
                check = function(value) exact("Faces", "Faces", value, Faces.new(Enum.NormalId.Right, Enum.NormalId.Top)) end },
            { name = "Region3", shape = schema.Region3(-6, 6),
                make = function()
                    local value = Region3.new(reversedLow3, reversedHigh3)
                    assert(value.Size.X == -8 and value.Size.Y == -10 and value.Size.Z == -12,
                        "Region3 preserves negative source size")
                    return value
                end,
                check = function(value) exact("Region3", "Region3", value, Region3.new(reversedLow3, reversedHigh3)) end },
        },
    },
    {
        name = "region-physical-font-path",
        cases = {
            { name = "Region3int16", shape = schema.Region3int16(-100, 100),
                make = function()
                    local value = Region3int16.new(reversedLow16, reversedHigh16)
                    assert(value.Min.X == 4 and value.Min.Y == 5 and value.Min.Z == 6
                        and value.Max.X == -4 and value.Max.Y == -5 and value.Max.Z == -6,
                        "Region3int16 preserves reversed source corners")
                    return value
                end,
                check = function(value) exact("Region3int16", "Region3int16", value,
                    Region3int16.new(reversedLow16, reversedHigh16)) end },
            { name = "PhysicalProperties", shape = schema.PhysicalProperties(),
                make = function() return PhysicalProperties.new(densityMinimum(), 2, 1, 100, 100, 1) end,
                check = function(value) exact("PhysicalProperties", "PhysicalProperties", value,
                    PhysicalProperties.new(densityMinimum(), 2, 1, 100, 100, 1)) end },
            { name = "Font", shape = schema.Font(sourceSans),
                make = function() return Font.new(sourceSans, Enum.FontWeight.SemiBold, Enum.FontStyle.Italic) end,
                check = function(value) exact("Font", "Font", value,
                    Font.new(sourceSans, Enum.FontWeight.SemiBold, Enum.FontStyle.Italic)) end },
            { name = "PathWaypoint", shape = schema.PathWaypoint(-4, 4, 32),
                make = function() return PathWaypoint.new(vector3(1, 2, 3), Enum.PathWaypointAction.Jump, "relay") end,
                check = function(value) exact("PathWaypoint", "PathWaypoint", value,
                    PathWaypoint.new(vector3(1, 2, 3), Enum.PathWaypointAction.Jump, "relay")) end },
        },
    },
}

local enumPolicies = {
    EasingStyle = { { "Linear", 0 }, { "Sine", 1 }, { "Back", 2 }, { "Quad", 3 }, { "Quart", 4 },
        { "Quint", 5 }, { "Bounce", 6 }, { "Elastic", 7 }, { "Exponential", 8 }, { "Circular", 9 }, { "Cubic", 10 } },
    EasingDirection = { { "In", 0 }, { "Out", 1 }, { "InOut", 2 } },
    FontWeight = { { "Thin", 100 }, { "ExtraLight", 200 }, { "Light", 300 }, { "Regular", 400 },
        { "Medium", 500 }, { "SemiBold", 600 }, { "Bold", 700 }, { "ExtraBold", 800 }, { "Heavy", 900 } },
    FontStyle = { { "Normal", 0 }, { "Italic", 1 } },
    PathWaypointAction = { { "Walk", 0 }, { "Jump", 1 }, { "Custom", 2 } },
}

local engineOnlyEasingStyles = { { "Bezier", 11 }, { "Spring", 12 } }

local function policyEvidence()
    local evidence = {}
    for familyName, expected in enumPolicies do
        local family = Enum[familyName]
        assert(family ~= nil, "missing intrinsic enum family " .. familyName)
        local actualItems = family:GetEnumItems()
        local engineOnly = if familyName == "EasingStyle" then engineOnlyEasingStyles else {}
        assert(#actualItems == #expected + #engineOnly, "intrinsic enum policy count drift: " .. familyName)
        local actualByName, expectedNames = {}, {}
        for _, item in actualItems do
            assert(actualByName[item.Name] == nil, "duplicate intrinsic enum item: " .. familyName)
            actualByName[item.Name] = item.Value
        end
        local values = {}
        for index, pair in expected do
            local item = family[pair[1]]
            expectedNames[pair[1]] = true
            assert(item ~= nil and item.Value == pair[2] and actualByName[pair[1]] == pair[2],
                "intrinsic enum policy drift: " .. familyName .. "." .. pair[1])
            values[index] = { name = pair[1], value = item.Value }
        end
        for _, pair in engineOnly do
            expectedNames[pair[1]] = true
            assert(actualByName[pair[1]] == pair[2],
                "engine-only easing style catalog drift: " .. pair[1])
        end
        for name in actualByName do assert(expectedNames[name], "unlisted intrinsic enum item: " .. familyName .. "." .. name) end
        evidence[familyName] = values
    end
    return evidence
end

local function nativeOperations(shape)
    local compiled, suffix, reason = NativeSchema.compile(shape)
    assert(compiled ~= nil, "native schema compile " .. tostring(suffix) .. ": " .. tostring(reason))
    local operations = NativeCodec.compile(compiled)
    assert(operations ~= nil, "native codec compile " .. shape.type)
    return operations
end

local function encodeNative(operations, value)
    local valid, normalized, byteCount = operations.normalize(value)
    assert(valid and type(byteCount) == "number", "native normalization for raw probe")
    local output = buffer.create(byteCount)
    assert(operations.write(normalized, output, 0) == byteCount, "native write length for raw probe")
    return output
end

local function copyBuffer(source)
    local result = buffer.create(buffer.len(source))
    buffer.copy(result, 0, source, 0, buffer.len(source))
    return result
end

local function rejectRaw(probes, name, operations, raw)
    local state = { value = raw, offset = 0, length = buffer.len(raw) }
    local callOk, valid, value = pcall(operations.read, state)
    assert(callOk and valid == false and value == nil, "native raw probe accepted or threw: " .. name)
    table.insert(probes, name)
end

local function acceptRaw(probes, name, operations, raw, check)
    local state = { value = raw, offset = 0, length = buffer.len(raw) }
    local valid, value = operations.read(state)
    assert(valid == true and value ~= nil, "native raw probe rejected: " .. name)
    if check then check(value) end
    table.insert(probes, name)
end

local function verifyNativeRejections()
    local probes = {}

    local dateOperations = nativeOperations({ type = "DateTime", minimum = dateMinimum, maximum = dateMaximum })
    local dateRaw = encodeNative(dateOperations, DateTime.fromUnixTimestampMillis(1_700_000_000_123))
    for _, sample in {
        { name = "datetime-fraction", value = 1.5 },
        { name = "datetime-below-minimum", value = dateMinimum - 1 },
        { name = "datetime-above-maximum", value = dateMaximum + 1 },
    } do
        local raw = copyBuffer(dateRaw)
        buffer.writef64(raw, 0, sample.value)
        rejectRaw(probes, sample.name, dateOperations, raw)
    end

    local tweenShape = { type = "TweenInfo", maximumTime = 4, maximumDelayTime = 1, maximumRepeatCount = 4 }
    local tweenOperations = nativeOperations(tweenShape)
    local tweenRaw = encodeNative(tweenOperations,
        TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true, 0.25))
    local repeatRaw = copyBuffer(tweenRaw)
    buffer.writei32(repeatRaw, 16, -1)
    rejectRaw(probes, "tween-infinite-repeat-default", tweenOperations, repeatRaw)
    for _, sample in {
        { name = "tween-negative-time", offset = 0, value = -1 },
        { name = "tween-delay-above-maximum", offset = 8, value = 2 },
    } do
        local raw = copyBuffer(tweenRaw)
        buffer.writef64(raw, sample.offset, sample.value)
        rejectRaw(probes, sample.name, tweenOperations, raw)
    end
    for _, sample in {
        { name = "tween-invalid-easing-style", offset = 21 },
        { name = "tween-invalid-easing-direction", offset = 25 },
    } do
        local raw = copyBuffer(tweenRaw)
        buffer.writei32(raw, sample.offset, 2_147_483_647)
        rejectRaw(probes, sample.name, tweenOperations, raw)
    end
    for _, pair in engineOnlyEasingStyles do
        local easingStyle = Enum.EasingStyle[pair[1]]
        local constructorOk, constructorError = pcall(function()
            return TweenInfo.new(1.5, easingStyle, Enum.EasingDirection.InOut, 2, true, 0.25)
        end)
        assert(not constructorOk and type(constructorError) == "string"
            and string.find(constructorError, "does not support", 1, true) ~= nil
            and string.find(constructorError, pair[1], 1, true) ~= nil,
            "engine TweenInfo constructor rejects unsupported easing style: " .. pair[1])

        local raw = copyBuffer(tweenRaw)
        buffer.writei32(raw, 21, pair[2])
        rejectRaw(probes, "tween-unsupported-easing-style-" .. pair[1], tweenOperations, raw)
    end
    local reversesRaw = copyBuffer(tweenRaw)
    buffer.writeu8(reversesRaw, 20, 2)
    rejectRaw(probes, "tween-invalid-reverses", tweenOperations, reversesRaw)

    local infiniteTweenOperations = nativeOperations({ type = "TweenInfo", maximumTime = 4,
        maximumDelayTime = 1, maximumRepeatCount = 4, allowInfiniteRepeat = true })
    local infiniteTween = TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In,
        -1, false, 0.25)
    acceptRaw(probes, "tween-infinite-repeat-opt-in", infiniteTweenOperations,
        encodeNative(infiniteTweenOperations, infiniteTween), function(value)
            exact("TweenInfo", "TweenInfo", value, infiniteTween)
        end)

    local pathOperations = nativeOperations({ type = "PathWaypoint", minimum = -4,
        maximum = 4, maximumLabelBytes = 4 })
    local pathValue = PathWaypoint.new(vector3(1, 2, 3), Enum.PathWaypointAction.Jump, "test")
    local pathRaw = encodeNative(pathOperations, pathValue)
    acceptRaw(probes, "path-label-maximum-boundary", pathOperations, pathRaw, function(value)
        exact("PathWaypoint", "PathWaypoint", value, pathValue)
    end)
    local longLabelRaw = copyBuffer(pathRaw)
    buffer.writeu16(longLabelRaw, 28, 5)
    rejectRaw(probes, "path-label-over-maximum", pathOperations, longLabelRaw)
    local invalidActionRaw = copyBuffer(pathRaw)
    buffer.writei32(invalidActionRaw, 24, 2_147_483_647)
    rejectRaw(probes, "path-invalid-action", pathOperations, invalidActionRaw)

    local numberSequenceOperations = nativeOperations({ type = "NumberSequence", maximumKeypoints = 20,
        minimum = -10, maximum = 10, maximumEnvelope = 1 })
    local numberSequence = NumberSequence.new({
        NumberSequenceKeypoint.new(0, -1, 0),
        NumberSequenceKeypoint.new(0.5, 0, 0),
        NumberSequenceKeypoint.new(1, 1, 0),
    })
    local numberSequenceRaw = encodeNative(numberSequenceOperations, numberSequence)
    for _, count in { 1, 21 } do
        local raw = buffer.create(1)
        buffer.writeu8(raw, 0, count)
        rejectRaw(probes, if count == 1 then "number-sequence-count-below-minimum"
            else "number-sequence-count-above-maximum", numberSequenceOperations, raw)
    end
    local numberTruncatedRaw = buffer.create(1)
    buffer.writeu8(numberTruncatedRaw, 0, 20)
    rejectRaw(probes, "number-sequence-truncated-before-allocation", numberSequenceOperations, numberTruncatedRaw)
    local duplicateNumberTimeRaw = copyBuffer(numberSequenceRaw)
    buffer.writef64(duplicateNumberTimeRaw, 25, 0)
    rejectRaw(probes, "number-sequence-duplicate-time", numberSequenceOperations, duplicateNumberTimeRaw)
    local numberFirstTimeRaw = copyBuffer(numberSequenceRaw)
    buffer.writef64(numberFirstTimeRaw, 1, 0.1)
    rejectRaw(probes, "number-sequence-first-time-not-zero", numberSequenceOperations, numberFirstTimeRaw)
    local numberLastTimeRaw = copyBuffer(numberSequenceRaw)
    buffer.writef64(numberLastTimeRaw, 49, 0.9)
    rejectRaw(probes, "number-sequence-last-time-not-one", numberSequenceOperations, numberLastTimeRaw)
    local coercedNumberRaw = copyBuffer(numberSequenceRaw)
    buffer.writef64(coercedNumberRaw, 33, 0.1)
    rejectRaw(probes, "number-sequence-constructor-coercion", numberSequenceOperations, coercedNumberRaw)

    local colorSequenceOperations = nativeOperations({ type = "ColorSequence", maximumKeypoints = 20 })
    local colorSequence = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
        ColorSequenceKeypoint.new(0.5, Color3.new(0.5, 0.5, 0.5)),
        ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
    })
    local colorSequenceRaw = encodeNative(colorSequenceOperations, colorSequence)
    for _, count in { 1, 21 } do
        local raw = buffer.create(1)
        buffer.writeu8(raw, 0, count)
        rejectRaw(probes, if count == 1 then "color-sequence-count-below-minimum"
            else "color-sequence-count-above-maximum", colorSequenceOperations, raw)
    end
    local colorTruncatedRaw = buffer.create(1)
    buffer.writeu8(colorTruncatedRaw, 0, 20)
    rejectRaw(probes, "color-sequence-truncated-before-allocation", colorSequenceOperations, colorTruncatedRaw)
    local duplicateColorTimeRaw = copyBuffer(colorSequenceRaw)
    buffer.writef64(duplicateColorTimeRaw, 33, 0)
    rejectRaw(probes, "color-sequence-duplicate-time", colorSequenceOperations, duplicateColorTimeRaw)
    local colorFirstTimeRaw = copyBuffer(colorSequenceRaw)
    buffer.writef64(colorFirstTimeRaw, 1, 0.1)
    rejectRaw(probes, "color-sequence-first-time-not-zero", colorSequenceOperations, colorFirstTimeRaw)
    local colorLastTimeRaw = copyBuffer(colorSequenceRaw)
    buffer.writef64(colorLastTimeRaw, 65, 0.9)
    rejectRaw(probes, "color-sequence-last-time-not-one", colorSequenceOperations, colorLastTimeRaw)
    local coercedColorRaw = copyBuffer(colorSequenceRaw)
    buffer.writef64(coercedColorRaw, 41, 0.1)
    rejectRaw(probes, "color-sequence-constructor-coercion", colorSequenceOperations, coercedColorRaw)

    local physicalOperations = nativeOperations({ type = "PhysicalProperties" })
    local physicalValue = PhysicalProperties.new(densityMinimum(), 2, 1, 100, 100, 1)
    assert(physicalValue.Density == densityMinimum() and physicalValue.Friction == 2
        and physicalValue.Elasticity == 1 and physicalValue.FrictionWeight == 100
        and physicalValue.ElasticityWeight == 100 and physicalValue.AcousticAbsorption == 1,
        "PhysicalProperties preserves its six exact source boundary values")
    local physicalRaw = encodeNative(physicalOperations, physicalValue)
    acceptRaw(probes, "physical-density-minimum-six-fields", physicalOperations, physicalRaw, function(value)
        exact("PhysicalProperties", "PhysicalProperties", value, physicalValue)
    end)
    local physicalInvalid = {
        { field = 1, component = "density", below = 0, above = 101 },
        { field = 2, component = "friction", below = -1, above = 3 },
        { field = 3, component = "elasticity", below = -1, above = 2 },
        { field = 4, component = "friction-weight", below = -1, above = 101 },
        { field = 5, component = "elasticity-weight", below = -1, above = 101 },
        { field = 6, component = "acoustic-absorption", below = -1, above = 2 },
    }
    for _, sample in physicalInvalid do
        local belowRaw = copyBuffer(physicalRaw)
        buffer.writef64(belowRaw, (sample.field - 1) * 8, sample.below)
        rejectRaw(probes, "physical-" .. sample.component .. "-below-minimum", physicalOperations, belowRaw)
        local aboveRaw = copyBuffer(physicalRaw)
        buffer.writef64(aboveRaw, (sample.field - 1) * 8, sample.above)
        rejectRaw(probes, "physical-" .. sample.component .. "-above-maximum", physicalOperations, aboveRaw)
    end

    return { engineVerified = true, probes = probes, count = #probes }
end

local function names(groupIndex)
    local result = {}
    for index, case in groups[groupIndex].cases do result[index] = case.name end
    return result
end

local function repeatCount(caseName)
    if caseName == "robloxEnum" or caseName == "BrickColor" or caseName == "Font" then return 2 end
    if caseName == "DateTime" then return 3 end
    return 1
end

local function findCase(groupIndex, caseName)
    for _, case in groups[groupIndex].cases do if case.name == caseName then return case end end
    error("unknown native value case " .. tostring(caseName))
end

local function create(groupIndex)
    local group = groups[groupIndex]
    assert(group ~= nil, "unknown native value group")
    policyEvidence()
    local variants = {}
    for _, case in group.cases do
        variants[case.name] = { type = "struct", fields = { schema.field("value", case.shape) } }
    end
    local union = schema.taggedUnion("kind", variants)
    local unionField = { name = "value", type = union.type, tag = union.tag, variants = union.variants }
    local definition, problem = Relay.define({ name = "RelayNativeValueProof" .. tostring(groupIndex), version = 1,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = { unionField } },
            Output = { id = 2, direction = "ServerToClient", fields = { unionField } },
        },
    })
    assert(definition ~= nil, problem and problem.message or "native value proof definition failed")
    return definition
end

local function make(groupIndex, caseName, sampleIndex)
    local case = findCase(groupIndex, caseName)
    return { kind = case.name, value = case.make(sampleIndex or 1) }
end

local function check(groupIndex, payload, sampleIndex)
    assert(type(payload) == "table" and type(payload.kind) == "string", "native tagged value record")
    local case = findCase(groupIndex, payload.kind)
    local expected = case.make(sampleIndex or 1)
    case.check(payload.value, sampleIndex or 1)
    exact(case.name, if case.name == "robloxEnum" then "EnumItem" else case.name, payload.value, expected)
    return case.name
end

return table.freeze({
    groups = groups,
    names = names,
    repeatCount = repeatCount,
    make = make,
    check = check,
    create = create,
    policyEvidence = policyEvidence,
    verifyNativeRejections = verifyNativeRejections,
})
