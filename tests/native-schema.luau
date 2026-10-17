local roblox = require("@lune/roblox")
local NativeSchema = require("../src/internal/NativeSchema")
local Definition = require("../src/Definition")
local Schema = require("../src/Schema")

local function compile(shape)
    local result, suffix, reason = NativeSchema.compile(shape)
    assert(result ~= nil, `{shape.type}{suffix}: {reason}`)
    assert(result.type == shape.type and result.native and result.containsCodec)
    assert(result.values == nil or table.isfrozen(result.values))
    return result
end

local function rejected(shape, expectedSuffix)
    local result, suffix, reason = NativeSchema.compile(shape)
    assert(result == nil and type(reason) == "string" and #reason > 0)
    if expectedSuffix ~= nil then assert(suffix == expectedSuffix, `{shape.type}: expected {expectedSuffix}, got {suffix}`) end
end

local rock, water = roblox.Enum.Material.Rock, roblox.Enum.Material.Water
local red, blue = roblox.BrickColor.new("Bright red"), roblox.BrickColor.new("Bright blue")

local shapes = {
    { type = "robloxEnum", values = { rock, water } },
    { type = "UDim", minimumScale = -2, maximumScale = 2, minimumOffset = -8, maximumOffset = 8 },
    { type = "UDim2", minimumScale = -2, maximumScale = 2, minimumOffset = -8, maximumOffset = 8 },
    { type = "NumberRange", minimum = -2.5, maximum = 3.5 },
    { type = "Rect", minimum = -10, maximum = 10 },
    { type = "BrickColor", values = { red, blue } },
    { type = "Vector2int16" },
    { type = "Vector3int16", minimum = -20, maximum = 20 },
    { type = "NumberSequence", maximumKeypoints = 20, minimum = -3, maximum = 4, maximumEnvelope = 5 },
    { type = "ColorSequence", maximumKeypoints = 20 },
    { type = "NumberSequenceKeypoint", minimum = -3, maximum = 4, maximumEnvelope = 5 },
    { type = "ColorSequenceKeypoint" },
    { type = "TweenInfo", maximumTime = 30, maximumDelayTime = 10, maximumRepeatCount = 8 },
    { type = "DateTime", minimum = -17_987_443_200_000, maximum = 253_402_300_799_999 },
    { type = "Ray", minimum = -100, maximum = 100, maximumDirectionMagnitude = 20 },
    { type = "Axes" },
    { type = "Faces" },
    { type = "Region3", minimum = -1_000, maximum = 1_000 },
    { type = "Region3int16" },
    { type = "PhysicalProperties" },
    { type = "Font", families = { "rbxasset://fonts/families/BuilderSans.json", "custom-font" } },
    { type = "PathWaypoint", minimum = -100, maximum = 100, maximumLabelBytes = 1_024 },
}

local expected = {
    robloxEnum = { 4, 4, 0, 1 }, UDim = { 12, 12, 0, 1 }, UDim2 = { 24, 24, 0, 1 },
    NumberRange = { 16, 16, 0, 1 }, Rect = { 32, 32, 0, 1 }, BrickColor = { 2, 2, 0, 1 },
    Vector2int16 = { 4, 4, 0, 1 }, Vector3int16 = { 6, 6, 0, 1 },
    NumberSequence = { 49, 481, 1, 21 }, ColorSequence = { 65, 641, 1, 21 },
    NumberSequenceKeypoint = { 24, 24, 0, 1 }, ColorSequenceKeypoint = { 32, 32, 0, 1 },
    TweenInfo = { 29, 29, 0, 1 }, DateTime = { 8, 8, 0, 1 }, Ray = { 48, 48, 0, 1 },
    Axes = { 1, 1, 0, 1 }, Faces = { 1, 1, 0, 1 }, Region3 = { 48, 48, 0, 1 },
    Region3int16 = { 12, 12, 0, 1 }, PhysicalProperties = { 48, 48, 0, 1 },
    Font = { 9, 9, 0, 1 }, PathWaypoint = { 30, 1_054, 0, 1 },
}

local compiledByKind = {}
for _, shape in shapes do
    local result = compile(shape)
    local bounds = expected[shape.type]
    assert(result.minimumEncodedBytes == bounds[1] and result.maximumEncodedBytes == bounds[2]
        and result.maximumDepth == bounds[3] and result.maximumElements == bounds[4],
        `{shape.type}: native bounds match the design`)
    assert(string.sub(result.descriptorToken, 1, #(`N{#shape.type}:{shape.type}[`)) == `N{#shape.type}:{shape.type}[`,
        `{shape.type}: descriptor has the native token prefix`)
    local allowed, maximumCount = NativeSchema.keys(shape.type)
    assert(allowed ~= nil and table.isfrozen(allowed) and maximumCount ~= nil and allowed.type
        and maximumCount == (function() local count = 0 for _ in allowed do count += 1 end return count end)(),
        `{shape.type}: closed key set and count`)
    compiledByKind[shape.type] = result
end
assert(#shapes == 22, "all new native shapes have metadata contracts")

assert(compiledByKind.robloxEnum.enumType == rock.EnumType
    and compiledByKind.robloxEnum.enumFamily == tostring(rock.EnumType)
    and compiledByKind.robloxEnum.values[1] == rock and table.isfrozen(compiledByKind.robloxEnum.values),
    "native Enum allowlist snapshots keep their family and exact items")
assert(compiledByKind.BrickColor.values[1] == red and table.isfrozen(compiledByKind.BrickColor.values),
    "BrickColor allowlist snapshots keep exact palette objects")
assert(compiledByKind.Vector2int16.minimum == -32_768 and compiledByKind.Vector2int16.maximum == 32_767
    and compiledByKind.Region3int16.minimum == -32_768 and compiledByKind.Region3int16.maximum == 32_767,
    "integer vector and region defaults retain the signed 16-bit range")
assert(compiledByKind.TweenInfo.allowInfiniteRepeat == false
    and table.isfrozen(compiledByKind.TweenInfo.enumPolicies)
    and table.isfrozen(compiledByKind.TweenInfo.enumPolicies.EasingStyle),
    "default repeat policy and copied enum policy tables are frozen")
assert(compiledByKind.Font.enumPolicies.FontWeight[7].name == "Bold"
    and compiledByKind.Font.enumPolicies.FontStyle[2].value == 1
    and table.isfrozen(compiledByKind.Font.families), "Font metadata freezes the family and intrinsic enum snapshots")
assert(compiledByKind.PathWaypoint.enumPolicies.PathWaypointAction[3].name == "Custom",
    "PathWaypoint action policy is pinned")

local sameZero = compile({ type = "NumberRange", minimum = -0.0, maximum = 1 })
local positiveZero = compile({ type = "NumberRange", minimum = 0, maximum = 1 })
assert(sameZero.minimum == 0 and 1 / sameZero.minimum == math.huge
    and sameZero.descriptorToken == positiveZero.descriptorToken, "new floating zero bounds canonicalize in metadata and descriptors")
assert(compile({ type = "NumberRange", minimum = 0, maximum = 1 }).descriptorToken
    ~= compile({ type = "NumberRange", minimum = 0, maximum = 2 }).descriptorToken,
    "numeric bounds participate in the descriptor")
assert(compile({ type = "robloxEnum", values = { rock } }).descriptorToken
    ~= compile({ type = "robloxEnum", values = { water } }).descriptorToken,
    "selected native enum items participate in the descriptor")
assert(compile({ type = "BrickColor", values = { red } }).descriptorToken
    ~= compile({ type = "BrickColor", values = { blue } }).descriptorToken,
    "selected BrickColor palette IDs participate in the descriptor")
assert(compile({ type = "Font", families = { "custom-font" } }).descriptorToken
    ~= compile({ type = "Font", families = { "other-font" } }).descriptorToken,
    "font family allowlists participate in the descriptor")

rejected({ type = "UDim", minimumScale = 0, maximumScale = math.huge, minimumOffset = 0, maximumOffset = 1 }, ".maximumScale")
rejected({ type = "UDim", minimumScale = 2, maximumScale = 1, minimumOffset = 0, maximumOffset = 1 }, ".maximumScale")
rejected({ type = "UDim", minimumScale = 0, maximumScale = 1, minimumOffset = -0.5, maximumOffset = 1 }, ".minimumOffset")
rejected({ type = "NumberRange", minimum = 2, maximum = 1 }, ".maximum")
rejected({ type = "Vector2int16", minimum = -32_769, maximum = 1 }, ".minimum")
rejected({ type = "Vector3int16", minimum = 2, maximum = 1 }, ".maximum")
rejected({ type = "NumberSequence", maximumKeypoints = 1, minimum = 0, maximum = 1, maximumEnvelope = 0 }, ".maximumKeypoints")
rejected({ type = "NumberSequence", maximumKeypoints = 21, minimum = 0, maximum = 1, maximumEnvelope = 0 }, ".maximumKeypoints")
rejected({ type = "ColorSequence", maximumKeypoints = 2.5 }, ".maximumKeypoints")
rejected({ type = "NumberSequenceKeypoint", minimum = 0, maximum = 1, maximumEnvelope = -1 }, ".maximumEnvelope")
rejected({ type = "TweenInfo", maximumTime = -1, maximumDelayTime = 0, maximumRepeatCount = 0 }, ".maximumTime")
rejected({ type = "TweenInfo", maximumTime = 1, maximumDelayTime = 1, maximumRepeatCount = 0, allowInfiniteRepeat = 1 }, ".allowInfiniteRepeat")
rejected({ type = "DateTime", minimum = 1.5, maximum = 2 }, ".minimum")
rejected({ type = "DateTime", minimum = -17_987_443_200_001, maximum = 2 }, ".minimum")
rejected({ type = "Ray", minimum = 0, maximum = 1, maximumDirectionMagnitude = math.huge }, ".maximumDirectionMagnitude")
rejected({ type = "Region3", minimum = 2, maximum = 1 }, ".maximum")
rejected({ type = "Font", families = { "same", "same" } }, ".families[2]")
rejected({ type = "Font", families = { string.rep("x", 257) } }, ".families[1]")
rejected({ type = "PathWaypoint", minimum = 0, maximum = 1, maximumLabelBytes = 1_025 }, ".maximumLabelBytes")

rejected({ type = "robloxEnum", values = {} }, ".values")
rejected({ type = "robloxEnum", values = { rock, roblox.Enum.UserInputType.MouseButton1 } }, ".values[2]")
rejected({ type = "robloxEnum", values = { rock, rock } }, ".values[2]")
rejected({ type = "BrickColor", values = { red, red } }, ".values[2]")
rejected({ type = "robloxEnum", values = setmetatable({ rock }, {}) }, ".values")
rejected({ type = "robloxEnum", values = { [1] = rock, [3] = water } }, ".values")
local tooMany = table.create(33)
for index = 1, 33 do tooMany[index] = rock end
rejected({ type = "robloxEnum", values = tooMany }, ".values")

local iterated = false
local hostile = setmetatable({ type = "Axes" }, {
    __iter = function() iterated = true error("must not iterate") end,
    __index = function() iterated = true error("must not index") end,
})
rejected(hostile, "")
assert(not iterated, "NativeSchema rejects metatables without invoking metamethods")

assert(Schema.robloxEnum(rock, water).values[1] == rock
    and Schema.UDim(-1, 1, -10, 10).type == "UDim"
    and Schema.Vector2int16().minimum == nil
    and Schema.Font("family").families[1] == "family",
    "public helpers create frozen raw metadata with their declared fields")

local function defineOne(shape, name, delivery, queue)
    local definition, problem = Definition.define({
        name = name,
        version = 1,
        events = {
            Input = {
                id = 1,
                direction = "ClientToServer",
                delivery = delivery,
                queue = queue,
                fields = { Schema.field("value", shape) },
            },
        },
    })
    return definition, problem, if definition then Definition.get(definition) else nil
end

local allNativeEvents = {}
for index, shape in shapes do
    allNativeEvents[`Native{index}`] = {
        id = index,
        direction = "ClientToServer",
        fields = { Schema.field("value", shape) },
    }
end
local allNativeDefinition, allNativeProblem = Definition.define({
    name = "AllNativeSchemas",
    version = 1,
    events = allNativeEvents,
})
assert(allNativeDefinition ~= nil and allNativeProblem == nil, allNativeProblem and allNativeProblem.message)
local allNativeCompiled = assert(Definition.get(allNativeDefinition))
for index, shape in shapes do
    local event = assert(allNativeCompiled.events[`Native{index}`])
    assert(event.delivery == "Reliable" and event.usesCodec and event.fields[1].native,
        `{shape.type}: reliable native values route through the checked codec`)
end

local unknownNativeKey, unknownNativeKeyError = defineOne({ type = "Axes", unexpected = true }, "NativeUnknownKey")
assert(unknownNativeKey == nil and unknownNativeKeyError ~= nil
    and string.find(unknownNativeKeyError.message, "unknown key", 1, true) ~= nil,
    "Definition rejects unknown native shape keys")

local nativeSequence = { type = "NumberSequence", maximumKeypoints = 20, minimum = 0, maximum = 1, maximumEnvelope = 0 }
local nestedSequence = nativeSequence
for _ = 1, 3 do nestedSequence = { type = "array", maximumLength = 1, element = nestedSequence } end
local depthFourToken, depthFourError, depthFourCompiled = defineOne(nestedSequence, "NativeDepthFour")
assert(depthFourToken ~= nil and depthFourError == nil
    and depthFourCompiled.events.Input.fields[1].maximumDepth == 4,
    "sequence intrinsic depth counts toward the shared limit of four")
nestedSequence = { type = "array", maximumLength = 1, element = nestedSequence }
local depthFiveToken = defineOne(nestedSequence, "NativeDepthFive")
assert(depthFiveToken == nil, "sequence nested at composite depth five is rejected")

local function sequenceArray(maximumLength)
    return {
        type = "array",
        maximumLength = maximumLength,
        element = nativeSequence,
    }
end
local expandedFitToken, expandedFitError, expandedFitCompiled = defineOne(sequenceArray(12), "NativeExpanded253")
assert(expandedFitToken ~= nil and expandedFitError == nil
    and expandedFitCompiled.events.Input.maximumElements == 253,
    "expanded native sequence count fits at 253 schema nodes")
local expandedOverflowToken = defineOne(sequenceArray(13), "NativeExpanded274")
assert(expandedOverflowToken == nil, "expanded native sequence count rejects above 256 nodes")

local longFamilies = table.create(32)
for index = 1, 32 do
    local prefix = tostring(index) .. ":"
    longFamilies[index] = prefix .. string.rep("f", 256 - #prefix)
end
local familiesUnderDescriptorCap = table.create(14)
for index = 1, 14 do familiesUnderDescriptorCap[index] = longFamilies[index] end
local familyFitToken, familyFitError = defineOne({ type = "Font", families = familiesUnderDescriptorCap }, "NativeFontDescriptorFit")
assert(familyFitToken ~= nil and familyFitError == nil, "bounded Font families fit within the existing descriptor cap")
local familyOverflowToken, familyOverflowError = defineOne({ type = "Font", families = longFamilies }, "NativeFontDescriptorOverflow")
assert(familyOverflowToken == nil and familyOverflowError ~= nil
    and string.find(familyOverflowError.message, "descriptor", 1, true) ~= nil,
    "Font family data remains subject to the 4096-byte descriptor cap")

local function definePath(labelBytes, delivery, queue, name)
    return defineOne({ type = "PathWaypoint", minimum = -1, maximum = 1, maximumLabelBytes = labelBytes }, name, delivery, queue)
end
local ordinaryPathToken, ordinaryPathError, ordinaryPathCompiled = definePath(867, "Unreliable", nil, "NativePathUnreliable900")
assert(ordinaryPathToken ~= nil and ordinaryPathError == nil
    and ordinaryPathCompiled.events.Input.maximumEncodedBytes == 900,
    "an unreliable PathWaypoint at 867 label bytes reaches the 900-byte limit")
assert(definePath(868, "Unreliable", nil, "NativePathUnreliable901") == nil,
    "an unreliable PathWaypoint above 900 bytes is rejected")
local orderedPathToken, orderedPathError, orderedPathCompiled = definePath(859, "OrderedUnreliable", nil, "NativePathOrdered900")
assert(orderedPathToken ~= nil and orderedPathError == nil
    and orderedPathCompiled.events.Input.maximumEncodedBytes == 900,
    "an ordered-unreliable PathWaypoint at 859 label bytes reaches the 900-byte frame limit")
assert(definePath(860, "OrderedUnreliable", nil, "NativePathOrdered901") == nil,
    "an ordered-unreliable PathWaypoint above 900 bytes is rejected")
local queuedPathToken, queuedPathError, queuedPathCompiled = definePath(862, "Unreliable", "Batch", "NativePathQueued900")
assert(queuedPathToken ~= nil and queuedPathError == nil
    and queuedPathCompiled.events.Input.maximumEncodedBytes == 895,
    "a queued unreliable PathWaypoint at 862 label bytes fits the 895-byte queued body limit")
assert(definePath(863, "Unreliable", "Batch", "NativePathQueued901") == nil,
    "a queued unreliable PathWaypoint above its body limit is rejected")

local enumKey = { type = "robloxEnum", values = { rock, water } }
local enumKeysToken, enumKeysError, enumKeysCompiled = defineOne({
    type = "map",
    key = enumKey,
    value = { type = "u8" },
    maximumSize = 2,
}, "NativeEnumMapKey")
assert(enumKeysToken ~= nil and enumKeysError == nil
    and enumKeysCompiled.events.Input.fields[1].key.type == "robloxEnum",
    "native enum values compile as map keys")
local enumSetToken, enumSetError, enumSetCompiled = defineOne({
    type = "set",
    element = enumKey,
    maximumSize = 2,
}, "NativeEnumSetKey")
assert(enumSetToken ~= nil and enumSetError == nil
    and enumSetCompiled.events.Input.fields[1].element.type == "robloxEnum",
    "native enum values compile as set keys")
assert(defineOne({ type = "map", key = { type = "BrickColor", values = { red } }, value = { type = "u8" }, maximumSize = 1 },
    "NativeBrickColorMapKey") == nil, "other native values remain ineligible as map keys")
assert(defineOne({ type = "set", element = { type = "BrickColor", values = { red } }, maximumSize = 1 },
    "NativeBrickColorSetKey") == nil, "other native values remain ineligible as set keys")

print("PASS closed native metadata, descriptor tokens, frozen allowlists, and bounded native schemas")
