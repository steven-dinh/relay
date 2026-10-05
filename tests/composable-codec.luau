local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
Vector2 = roblox.Vector2
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local CompositeCodec = require("../src/internal/CompositeCodec")
local ordered = require("../examples/reliable-events/ordered")

local integerKinds = {
    { type = "u8", width = 1, minimum = 0, maximum = 255, narrowMinimum = 10, narrowMaximum = 20,
        read = buffer.readu8, write = buffer.writeu8 },
    { type = "i8", width = 1, minimum = -128, maximum = 127, narrowMinimum = -10, narrowMaximum = 10,
        read = buffer.readi8, write = buffer.writei8 },
    { type = "u16", width = 2, minimum = 0, maximum = 65_535, narrowMinimum = 1_000, narrowMaximum = 2_000,
        read = buffer.readu16, write = buffer.writeu16 },
    { type = "i16", width = 2, minimum = -32_768, maximum = 32_767,
        narrowMinimum = -1_000, narrowMaximum = 1_000, read = buffer.readi16, write = buffer.writei16 },
    { type = "u32", width = 4, minimum = 0, maximum = 4_294_967_295,
        narrowMinimum = 100_000, narrowMaximum = 200_000, read = buffer.readu32, write = buffer.writeu32 },
    { type = "i32", width = 4, minimum = -2_147_483_648, maximum = 2_147_483_647,
        narrowMinimum = -200_000, narrowMaximum = 200_000, read = buffer.readi32, write = buffer.writei32 },
}
local fullIntegerFields, narrowIntegerFields = table.create(#integerKinds), table.create(#integerKinds)
for index, kind in integerKinds do
    fullIntegerFields[index] = { name = kind.type, type = kind.type }
    narrowIntegerFields[index] = { name = kind.type, type = kind.type,
        minimum = kind.narrowMinimum, maximum = kind.narrowMaximum }
end

local token = assert(Definition.define({ name = "CompositeCodecTest", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", fields = ordered(
        { name = "payload", type = "struct", fields = ordered(
            { name = "mode", type = "enum", values = ordered("Idle", "Run") },
            { name = "samples", type = "array", maximumLength = 2,
                element = { type = "Vector2F32", minimum = -10, maximum = 10 } },
            { name = "note", type = "optional", value = { type = "string", maximumBytes = 8 } },
            { name = "flags", type = "set", maximumSize = 2, element = { type = "boolean" } }
        ) },
        { name = "pose", type = "CFrame", minimum = -10, maximum = 10 },
        { name = "optionalTail", type = "optional", value = { type = "u8", minimum = 0, maximum = 10 } }
    ) },
    Output = { id = 2, direction = "ServerToClient", delivery = "Unreliable", fields = ordered(
        { name = "numbers", type = "set", maximumSize = 3,
            element = { type = "i16", minimum = -5, maximum = 5 } },
        { name = "mode", type = "enum", values = ordered("Ready", "Busy") }
    ) },
    Optional = { id = 3, direction = "ClientToServer", fields = ordered(
        { name = "value", type = "optional", value = { type = "boolean" } }
    ) },
    EmptyItems = { id = 5, direction = "ClientToServer", fields = ordered(
        { name = "items", type = "array", maximumLength = 64,
            element = { type = "struct", fields = ordered() } }
    ) },
    Collections = { id = 6, direction = "ClientToServer", fields = ordered(
        { name = "values", type = "array", maximumLength = 2, element = { type = "boolean" } },
        { name = "flags", type = "set", maximumSize = 2, element = { type = "boolean" } }
    ) },
    Bytes = { id = 7, direction = "ClientToServer", fields = ordered(
        { name = "record", type = "struct", fields = ordered(
            { name = "value", type = "string", maximumBytes = 8 }
        ) }
    ) },
    Widths = { id = 8, direction = "ClientToServer", fields = ordered(
        { name = "values", type = "struct", fields = ordered(
            { name = "byte", type = "u8", minimum = 0, maximum = 255 },
            { name = "word", type = "i16", minimum = -5, maximum = 5 },
            { name = "ratio", type = "f32", minimum = -10, maximum = 10 },
            { name = "point", type = "Vector2F32", minimum = -10, maximum = 10 }
        ) }
    ) },
    IntegerCodec = { id = 9, direction = "ClientToServer", fields = ordered(
        { name = "full", type = "struct", fields = ordered(table.unpack(fullIntegerFields)) },
        { name = "narrow", type = "struct", fields = ordered(table.unpack(narrowIntegerFields)) },
        { name = "array", type = "array", maximumLength = 2,
            element = { type = "i16", minimum = -10, maximum = 10 } },
        { name = "maybe", type = "optional", value = { type = "u32", minimum = 1, maximum = 20 } }
    ) },
} }))
local compiled = Definition.get(token)
local input = compiled.byId[1]
local output = compiled.byId[2]
local optional = compiled.byId[3]
local emptyItems = compiled.byId[5]
local collections = compiled.byId[6]
local bytes = compiled.byId[7]
local widths = compiled.byId[8]
local integerCodec = compiled.byId[9]
assert(input.usesCodec and output.usesCodec and optional.usesCodec and emptyItems.usesCodec
    and collections.usesCodec and bytes.usesCodec and widths.usesCodec and integerCodec.usesCodec)
assert(input.minimumEncodedBytes == 3 + 1 + 2 + 1 + 2 + 96 + 1)
assert(input.maximumEncodedBytes <= 8_192 and output.maximumEncodedBytes <= 900)

local payload = {
    mode = "Run",
    samples = { Vector2.new(1.5, -2), Vector2.new(3, 4) },
    flags = { [false] = true, [true] = true },
}
local pose = CFrame.new(1, 2, 3)

local iterationCallbacks = 0
local hostileMetatable = {
    __iter = function(value)
        iterationCallbacks += 1
        return next, value
    end,
    __index = function()
        iterationCallbacks += 1
        return nil
    end,
    __metatable = false,
}
local function hostile(value)
    return setmetatable(value, hostileMetatable)
end
local hostileStructPayload = hostile(table.clone(payload))
local hostileArrayPayload = table.clone(payload)
hostileArrayPayload.samples = hostile({ Vector2.zero })
local hostileSetPayload = table.clone(payload)
hostileSetPayload.flags = hostile({ [false] = true })
local inputValidators = { Frame.compile(input, "encode"), Frame.compile(input) }
for _, invalidPayload in { hostileStructPayload, hostileArrayPayload, hostileSetPayload } do
    for _, validate in inputValidators do
        assert(validate(invalidPayload, pose, nil) == nil,
            "protected composite metatables reject before encode or validation callbacks")
    end
end
assert(iterationCallbacks == 0, "protected __iter and __index callbacks are never invoked")

local encoded = table.pack(Frame.compile(input, "encode")(payload, pose, nil))
assert(encoded.n == 2 and encoded[1] == true and typeof(encoded[2]) == "buffer")
assert(buffer.len(encoded[2]) == 3 + 1 + 2 + 16 + 1 + 2 + 2 + 96 + 1)

local decoded = table.pack(Frame.compile(input, "decode")(encoded[2]))
assert(decoded.n == 4 and decoded[1] == true and decoded[4] == nil,
    "decode preserves explicit trailing nil arity")
assert(decoded[2].mode == "Run" and decoded[2].note == nil)
assert(decoded[2].samples[1] == Vector2.new(1.5, -2) and decoded[2].samples[2] == Vector2.new(3, 4))
assert(decoded[2].flags[false] == true and decoded[2].flags[true] == true)
assert(decoded[3] == pose)

local validated = table.pack(Frame.compile(input)(payload, pose, nil))
assert(validated.n == 4 and validated[1] == true and validated[4] == nil)
assert(validated[2] ~= payload and validated[2].samples ~= payload.samples,
    "local validation returns invocation-owned copies")
assert(Frame.compile(input, "encode")(payload, pose) == nil, "encode requires exact top-level arity")
assert(Frame.compile(input, "decode")() == nil, "decode requires exactly one buffer")
assert(Frame.compile(input, "decode")("bad") == nil, "decode rejects non-buffer input")

for _, badPayload in {
    { mode = "Bad", samples = {}, flags = {} },
    { samples = {}, flags = {} },
    { mode = "Run", samples = { [1] = Vector2.zero, [3] = Vector2.zero }, flags = {} },
    { mode = "Run", samples = { [2] = Vector2.zero }, flags = {} },
    { mode = "Run", samples = { [1] = Vector2.zero, [1.5] = Vector2.zero }, flags = {} },
    { mode = "Run", samples = { Vector2.zero, extra = Vector2.zero }, flags = {} },
    { mode = "Run", samples = {}, flags = { [false] = 1 } },
    { mode = "Run", samples = {}, flags = {}, extra = true },
    setmetatable({ mode = "Run", samples = {}, flags = {} }, {}),
} do
    assert(Frame.compile(input, "encode")(badPayload, pose, nil) == nil, "invalid struct payload rejected")
end
assert(Frame.compile(input, "encode")(payload, CFrame.new(11, 0, 0), nil) == nil,
    "scalar CFrame bounds still apply inside composites")

local function copied(bufferValue, length)
    local result = buffer.create(length)
    buffer.copy(result, 0, bufferValue, 0, math.min(length, buffer.len(bufferValue)))
    return result
end

local function rejects(value, label)
    assert(Frame.compile(input, "decode")(value) == nil, label)
end

local function encode(event, ...)
    local result = table.pack(Frame.compile(event, "encode")(...))
    assert(result.n == 2 and result[1] == true, "expected composite encode to succeed")
    return result[2]
end

local fullIntegerValues = { u8 = 0, i8 = -128, u16 = 65_535, i16 = -32_768,
    u32 = 4_294_967_295, i32 = -2_147_483_648 }
local narrowIntegerValues = { u8 = 10, i8 = -10, u16 = 2_000, i16 = -1_000,
    u32 = 100_000, i32 = -200_000 }
local integerEncoder = Frame.compile(integerCodec, "encode")
local integerValidator = Frame.compile(integerCodec, "validate")
local integerDecoder = Frame.compile(integerCodec, "decode")
local integerGolden = buffer.fromstring(string.char(
    1, 9, 0,
    0, 128, 255, 255, 0, 128, 255, 255, 255, 255, 0, 0, 0, 128,
    10, 246, 208, 7, 24, 252, 160, 134, 1, 0, 192, 242, 252, 255,
    2, 0, 246, 255, 10, 0, 1, 20, 0, 0, 0
))
local integerPacket = encode(integerCodec, fullIntegerValues, narrowIntegerValues, { -10, 10 }, 20)
assert(buffer.len(integerPacket) == 42 and buffer.len(integerGolden) == 42,
    "six integer widths use fixed wire offsets")
for offset = 0, buffer.len(integerGolden) - 1 do
    assert(buffer.readu8(integerPacket, offset) == buffer.readu8(integerGolden, offset),
        "integer golden bytes preserve type-specific offsets")
end
local fullOffset, narrowOffset = 3, 17
for _, kind in integerKinds do
    assert(kind.read(integerPacket, fullOffset) == fullIntegerValues[kind.type])
    assert(kind.read(integerPacket, narrowOffset) == narrowIntegerValues[kind.type])
    fullOffset += kind.width
    narrowOffset += kind.width
end
local integerDecoded = table.pack(integerDecoder(integerPacket))
assert(integerDecoded.n == 5 and integerDecoded[1] == true
    and integerDecoded[4][1] == -10 and integerDecoded[4][2] == 10 and integerDecoded[5] == 20,
    "integer leaves round trip through structs, array, and optional")
for _, kind in integerKinds do
    assert(integerDecoded[2][kind.type] == fullIntegerValues[kind.type]
        and integerDecoded[3][kind.type] == narrowIntegerValues[kind.type])
end

for _, kind in integerKinds do
    for _, boundary in { kind.minimum, kind.maximum } do
        local values = table.clone(fullIntegerValues)
        values[kind.type] = boundary
        local encodedBoundary = table.pack(integerEncoder(values, narrowIntegerValues, {}, nil))
        assert(encodedBoundary.n == 2 and encodedBoundary[1] == true)
        local decodedBoundary = table.pack(integerDecoder(encodedBoundary[2]))
        assert(decodedBoundary.n == 5 and decodedBoundary[1] == true
            and decodedBoundary[2][kind.type] == boundary and decodedBoundary[5] == nil,
            "full integer bounds encode and decode")
    end
    for _, invalid in { kind.minimum - 1, kind.maximum + 1 } do
        local values = table.clone(fullIntegerValues)
        values[kind.type] = invalid
        assert(integerEncoder(values, narrowIntegerValues, {}, nil) == nil,
            "encode rejects values outside the integer width")
    end
    for _, invalid in { kind.narrowMinimum - 1, kind.narrowMaximum + 1 } do
        local narrowed = table.clone(narrowIntegerValues)
        narrowed[kind.type] = invalid
        assert(integerEncoder(fullIntegerValues, narrowed, {}, nil) == nil,
            "encode enforces narrower integer schema bounds")
    end
end

for _, invalid in { 1.5, "bad", 65_536 } do
    local invalidFull = table.clone(fullIntegerValues)
    invalidFull.u16 = invalid
    assert(integerEncoder(invalidFull, narrowIntegerValues, {}, nil) == nil
        and integerValidator(invalidFull, narrowIntegerValues, {}, nil) == nil,
        "composite input paths retain full-range integer normalization")
end

narrowOffset = 17
for _, kind in integerKinds do
    for _, invalid in { kind.narrowMinimum - 1, kind.narrowMaximum + 1 } do
        local outOfBounds = copied(integerPacket, buffer.len(integerPacket))
        kind.write(outOfBounds, narrowOffset, invalid)
        assert(integerDecoder(outOfBounds) == nil, "decode enforces narrower integer schema bounds")
    end
    narrowOffset += kind.width
end

local negativeZero = -1 / math.huge
local zeroIntegers = {}
for _, kind in integerKinds do zeroIntegers[kind.type] = negativeZero end
local normalizedIntegers = table.pack(integerValidator(zeroIntegers, narrowIntegerValues, {}, nil))
assert(normalizedIntegers.n == 5 and normalizedIntegers[1] == true)
for _, kind in integerKinds do
    local value = normalizedIntegers[2][kind.type]
    assert(value == 0 and 1 / value == math.huge, "integer negative zero canonicalizes")
end
local encodedZeroIntegers = table.pack(integerEncoder(zeroIntegers, narrowIntegerValues,
    { negativeZero, negativeZero }, nil))
assert(encodedZeroIntegers.n == 2 and encodedZeroIntegers[1] == true)
local decodedZeroIntegers = table.pack(integerDecoder(encodedZeroIntegers[2]))
assert(decodedZeroIntegers.n == 5 and decodedZeroIntegers[1] == true)
for _, kind in integerKinds do
    local value = decodedZeroIntegers[2][kind.type]
    assert(value == 0 and 1 / value == math.huge, "full-range integer decode preserves positive zero")
end
for index = 1, 2 do
    local value = decodedZeroIntegers[4][index]
    assert(value == 0 and 1 / value == math.huge, "integer array decode preserves positive zero")
end
local ownedIntegers = table.pack(integerValidator(fullIntegerValues, narrowIntegerValues, { -10, 10 }, nil))
local anotherDecode = table.pack(integerDecoder(integerPacket))
assert(ownedIntegers.n == 5 and ownedIntegers[2] ~= fullIntegerValues
    and ownedIntegers[3] ~= narrowIntegerValues and ownedIntegers[4] ~= integerDecoded[4]
    and anotherDecode[2] ~= integerDecoded[2] and anotherDecode[4] ~= integerDecoded[4],
    "integer validation and decoding return invocation-owned tables")
local nilIntegerPacket = encode(integerCodec, fullIntegerValues, narrowIntegerValues, { -10, 10 }, nil)
local nilIntegerResult = table.pack(integerDecoder(nilIntegerPacket))
assert(nilIntegerResult.n == 5 and nilIntegerResult[1] == true and nilIntegerResult[5] == nil,
    "integer optional preserves exact trailing-nil result arity")
assert(integerDecoder(copied(integerPacket, 34)) == nil,
    "truncated array integer rejects before reading")
local optionalIntegerPacket = encode(integerCodec, fullIntegerValues, narrowIntegerValues, {}, 20)
assert(integerDecoder(copied(optionalIntegerPacket, 35)) == nil,
    "truncated optional integer rejects before reading")

local goldenPose = CFrame.new(4, -3, 2) * CFrame.Angles(0.3, -0.7, 1.1)
local goldenComponents = { goldenPose:GetComponents() }
local goldenEncoded = encode(input, payload, goldenPose, nil)
local expectedCFrameBytes = buffer.create(96)
for index, component in goldenComponents do
    buffer.writef64(expectedCFrameBytes, (index - 1) * 8, component)
end
for byte = 0, 95 do
    assert(buffer.readu8(goldenEncoded, 27 + byte) == buffer.readu8(expectedCFrameBytes, byte),
        "CFrame uses the native component order and f64 layout")
end
local goldenDecoded = table.pack(Frame.compile(input, "decode")(goldenEncoded))
local decodedComponents = { goldenDecoded[3]:GetComponents() }
for index = 1, 12 do
    local raw, rebuilt = goldenComponents[index], decodedComponents[index]
    assert(raw == rebuilt and (raw ~= 0 or 1 / raw == 1 / rebuilt),
        "CFrame round trip preserves every component and zero sign")
end

local badVersion = copied(encoded[2], buffer.len(encoded[2]))
buffer.writeu8(badVersion, 0, 2)
rejects(badVersion, "unknown frame version rejected")
local wrongEndpoint = copied(encoded[2], buffer.len(encoded[2]))
buffer.writeu16(wrongEndpoint, 1, 2)
rejects(wrongEndpoint, "inner endpoint mismatch rejected")
local badEnum = copied(encoded[2], buffer.len(encoded[2]))
buffer.writeu8(badEnum, 3, 255)
rejects(badEnum, "unknown enum ordinal rejected")
local oversizedArray = copied(encoded[2], buffer.len(encoded[2]))
buffer.writeu16(oversizedArray, 4, 3)
rejects(oversizedArray, "array count above schema maximum rejected")
local outOfBoundsVector = copied(encoded[2], buffer.len(encoded[2]))
buffer.writef32(outOfBoundsVector, 6, 11)
rejects(outOfBoundsVector, "raw vector bounds are checked before construction")
local nonfiniteVector = copied(encoded[2], buffer.len(encoded[2]))
buffer.writef32(nonfiniteVector, 6, math.huge)
rejects(nonfiniteVector, "raw vector nonfinite values are rejected")
local signedZeroAndSubnormal = copied(encoded[2], buffer.len(encoded[2]))
local negativeZero = -1 / math.huge
local float32Subnormal = 2 ^ -149
buffer.writef32(signedZeroAndSubnormal, 6, negativeZero)
buffer.writef32(signedZeroAndSubnormal, 10, float32Subnormal)
local rawVectorDecoded = table.pack(Frame.compile(input, "decode")(signedZeroAndSubnormal))
assert(rawVectorDecoded.n == 4 and rawVectorDecoded[1] == true
    and rawVectorDecoded[2].samples[1].X == 0 and 1 / rawVectorDecoded[2].samples[1].X == math.huge
    and rawVectorDecoded[2].samples[1].Y == float32Subnormal,
    "raw vectors canonicalize zero and preserve Float32 subnormals")
local nonfinitePose = copied(encoded[2], buffer.len(encoded[2]))
buffer.writef64(nonfinitePose, 27, math.huge)
rejects(nonfinitePose, "nonfinite raw CFrame translation rejected")
local invalidPoseRotation = copied(encoded[2], buffer.len(encoded[2]))
buffer.writef64(invalidPoseRotation, 51, 2)
rejects(invalidPoseRotation, "invalid raw CFrame rotation rejected")
local invalidFinalPoseComponent = copied(goldenEncoded, buffer.len(goldenEncoded))
buffer.writef64(invalidFinalPoseComponent, 27 + 88, 2)
rejects(invalidFinalPoseComponent, "invalid final raw CFrame component rejected")
rejects(copied(encoded[2], 27 + 95), "truncated CFrame rejected by the full-component bounds check")
rejects(copied(encoded[2], buffer.len(encoded[2]) - 1), "truncated frame rejected")
local trailing = copied(encoded[2], buffer.len(encoded[2]) + 1)
rejects(trailing, "trailing bytes rejected")

local optionalResult = table.pack(Frame.compile(optional, "encode")(nil))
assert(optionalResult[1] == true)
local optionalEncoded = optionalResult[2]
local optionalNilDecoded = table.pack(Frame.compile(optional, "decode")(optionalEncoded))
assert(optionalNilDecoded.n == 2 and optionalNilDecoded[1] == true and optionalNilDecoded[2] == nil,
    "optional nil keeps exact tuple arity")
local trailingOptional = copied(optionalEncoded, buffer.len(optionalEncoded) + 1)
local optionalTrailingResult = table.pack(Frame.compile(optional, "decode")(trailingOptional))
assert(optionalTrailingResult.n == 1 and optionalTrailingResult[1] == nil,
    "single-field decode rejects trailing bytes")
local optionalFalseEncoded = encode(optional, false)
local optionalFalseDecoded = table.pack(Frame.compile(optional, "decode")(optionalFalseEncoded))
assert(optionalFalseDecoded.n == 2 and optionalFalseDecoded[1] == true and optionalFalseDecoded[2] == false,
    "optional false is preserved")
local badOptionalTag = copied(optionalEncoded, buffer.len(optionalEncoded))
buffer.writeu8(badOptionalTag, 3, 2)
local rejectedTag = table.pack(Frame.compile(optional, "decode")(badOptionalTag))
assert(rejectedTag.n == 1 and rejectedTag[1] == nil, "invalid optional tag returns one rejection value")

local emptyCollections = encode(collections, {}, {})
assert(buffer.len(emptyCollections) == 7 and buffer.readu16(emptyCollections, 3) == 0
    and buffer.readu16(emptyCollections, 5) == 0, "empty array and set prefixes")
local fullCollections = encode(collections, { false, true }, { [false] = true, [true] = true })
assert(buffer.len(fullCollections) == 11 and buffer.readu16(fullCollections, 3) == 2
    and buffer.readu8(fullCollections, 5) == 0 and buffer.readu8(fullCollections, 6) == 1
    and buffer.readu16(fullCollections, 7) == 2, "maximum array and set prefixes include false values")
local decodedCollections = table.pack(Frame.compile(collections, "decode")(fullCollections))
assert(decodedCollections.n == 3 and decodedCollections[2][1] == false and decodedCollections[2][2] == true
    and decodedCollections[3][false] and decodedCollections[3][true], "false collection values round trip")

local allEmptyItems = table.create(64)
for index = 1, 64 do allEmptyItems[index] = {} end
local emptyItemsEncoded = encode(emptyItems, {})
assert(buffer.len(emptyItemsEncoded) == 5 and buffer.readu16(emptyItemsEncoded, 3) == 0,
    "empty dense array prefix")
local maxEmptyItemsEncoded = encode(emptyItems, allEmptyItems)
assert(buffer.len(maxEmptyItemsEncoded) == 5 and buffer.readu16(maxEmptyItemsEncoded, 3) == 64,
    "maximum dense array prefix")

local arbitraryBytes = string.char(0, 255, 128, 1)
local bytesEncoded = encode(bytes, { value = arbitraryBytes })
assert(buffer.len(bytesEncoded) == 9 and buffer.readu16(bytesEncoded, 3) == #arbitraryBytes)
local bytesDecoded = table.pack(Frame.compile(bytes, "decode")(bytesEncoded))
assert(bytesDecoded.n == 2 and bytesDecoded[1] == true and bytesDecoded[2].value == arbitraryBytes,
    "bounded strings preserve arbitrary bytes")
local oversizedString = copied(bytesEncoded, buffer.len(bytesEncoded))
buffer.writeu16(oversizedString, 3, 9)
local rejectedString = table.pack(Frame.compile(bytes, "decode")(oversizedString))
assert(rejectedString.n == 1 and rejectedString[1] == nil, "string bound rejects before reading content")

local widthsEncoded = encode(widths, { byte = 255, word = -5, ratio = 0.25, point = Vector2.new(1, 2) })
assert(buffer.len(widthsEncoded) == 18, "compiled scalar widths set exact encoded size")
local widthsDecoded = table.pack(Frame.compile(widths, "decode")(widthsEncoded))
assert(widthsDecoded.n == 2 and widthsDecoded[1] == true and widthsDecoded[2].byte == 255
    and widthsDecoded[2].word == -5 and widthsDecoded[2].ratio == 0.25
    and widthsDecoded[2].point == Vector2.new(1, 2),
    "compiled scalar widths round trip")

local operations = { reads = 0, writes = 0, vector2 = 0, vector3 = 0 }
local checkedBuffer = table.clone(buffer)
checkedBuffer.readf32 = function(...)
    operations.reads += 1
    return buffer.readf32(...)
end
checkedBuffer.writef32 = function(...)
    operations.writes += 1
    return buffer.writef32(...)
end
local packCalls = 0
local createCalls = 0
local countedTable = table.clone(table)
countedTable.pack = function(...)
    packCalls += 1
    return table.pack(...)
end
countedTable.create = function(...)
    createCalls += 1
    return table.create(...)
end
local countedCodec = luau.load(fs.readFile("src/internal/CompositeCodec.luau"), {
    environment = { buffer = checkedBuffer, table = countedTable }, injectGlobals = true,
})()
local vector2Override, vector3Override
local countedFrame = luau.load(fs.readFile("src/internal/Frame.luau"), {
    environment = {
        buffer = checkedBuffer,
        Vector2 = { new = function(x, y)
            operations.vector2 += 1
            return if vector2Override then vector2Override(x, y) else roblox.Vector2.new(x, y)
        end },
        Vector3 = { new = function(x, y, z)
            operations.vector3 += 1
            return if vector3Override then vector3Override(x, y, z) else roblox.Vector3.new(x, y, z)
        end },
        CFrame = roblox.CFrame,
        require = function(path) assert(path == "./CompositeCodec"); return countedCodec end,
    }, injectGlobals = true,
})()
local singleOptionalEncode = countedFrame.compile(optional, "encode")
local singleOptionalValidate = countedFrame.compile(optional, "validate")
packCalls = 0
local encodedOptionalNil = table.pack(singleOptionalEncode(nil))
assert(encodedOptionalNil.n == 2 and encodedOptionalNil[1] == true and buffer.len(encodedOptionalNil[2]) == 4
    and buffer.readu8(encodedOptionalNil[2], 0) == 1 and buffer.readu16(encodedOptionalNil[2], 1) == optional.id
    and buffer.readu8(encodedOptionalNil[2], 3) == 0 and packCalls == 0,
    "single optional encode preserves nil bytes without packing arguments")
local encodedOptionalFalse = table.pack(singleOptionalEncode(false))
assert(encodedOptionalFalse.n == 2 and encodedOptionalFalse[1] == true and buffer.len(encodedOptionalFalse[2]) == 5
    and buffer.readu8(encodedOptionalFalse[2], 3) == 1 and buffer.readu8(encodedOptionalFalse[2], 4) == 0
    and packCalls == 0, "single optional encode preserves false bytes without packing arguments")
local validatedOptionalFalse = table.pack(singleOptionalValidate(false))
assert(validatedOptionalFalse.n == 2 and validatedOptionalFalse[1] == true
    and validatedOptionalFalse[2] == false and packCalls == 0,
    "single optional validation preserves false without packing arguments")
local validatedOptionalNil = table.pack(singleOptionalValidate(nil))
assert(validatedOptionalNil.n == 2 and validatedOptionalNil[1] == true
    and validatedOptionalNil[2] == nil and packCalls == 0,
    "single optional validation preserves nil arity without packing arguments")
assert(singleOptionalEncode() == nil and singleOptionalEncode(nil, nil) == nil
    and singleOptionalValidate() == nil and singleOptionalValidate(nil, nil) == nil
    and singleOptionalEncode("invalid") == nil and singleOptionalValidate("invalid") == nil
    and packCalls == 0, "single optional paths preserve arity and payload rejection without packing arguments")

local twoOptionalEvent = { id = 95, delivery = "Reliable", usesCodec = true,
    fields = {
        { type = "optional", minimumEncodedBytes = 1,
            value = { type = "boolean", minimumEncodedBytes = 1 } },
        { type = "optional", minimumEncodedBytes = 1,
            value = { type = "boolean", minimumEncodedBytes = 1 } },
    }, minimumEncodedBytes = 5, maximumEncodedBytes = 7 }
local twoOptionalEncode = countedFrame.compile(twoOptionalEvent, "encode")
local twoOptionalValidate = countedFrame.compile(twoOptionalEvent, "validate")
local twoOptionalDecode = countedFrame.compile(twoOptionalEvent, "decode")
packCalls, createCalls = 0, 0
local nilFalseEncoded = table.pack(twoOptionalEncode(nil, false))
assert(nilFalseEncoded.n == 2 and nilFalseEncoded[1] == true and buffer.len(nilFalseEncoded[2]) == 6
    and buffer.readu8(nilFalseEncoded[2], 0) == 1
    and buffer.readu16(nilFalseEncoded[2], 1) == twoOptionalEvent.id
    and buffer.readu8(nilFalseEncoded[2], 3) == 0
    and buffer.readu8(nilFalseEncoded[2], 4) == 1 and buffer.readu8(nilFalseEncoded[2], 5) == 0,
    "two-root nil/false encode preserves exact wire bytes")
assert(packCalls == 0 and createCalls == 0, "two-root encode needs no argument or output tuple table")
local nilFalseValidated = table.pack(twoOptionalValidate(nil, false))
assert(nilFalseValidated.n == 3 and nilFalseValidated[1] == true
    and nilFalseValidated[2] == nil and nilFalseValidated[3] == false
    and packCalls == 0 and createCalls == 0, "two-root validation preserves nil/false arity without tuple tables")
local falseNilEncoded = table.pack(twoOptionalEncode(false, nil))
assert(falseNilEncoded.n == 2 and falseNilEncoded[1] == true and buffer.len(falseNilEncoded[2]) == 6
    and buffer.readu8(falseNilEncoded[2], 3) == 1 and buffer.readu8(falseNilEncoded[2], 4) == 0
    and buffer.readu8(falseNilEncoded[2], 5) == 0,
    "two-root false/nil encode preserves exact wire bytes")
local falseNilValidated = table.pack(twoOptionalValidate(false, nil))
assert(falseNilValidated.n == 3 and falseNilValidated[1] == true
    and falseNilValidated[2] == false and falseNilValidated[3] == nil,
    "two-root validation preserves false/nil arity")
local decodedNilFalse = table.pack(twoOptionalDecode(nilFalseEncoded[2]))
assert(decodedNilFalse.n == 3 and decodedNilFalse[1] == true
    and decodedNilFalse[2] == nil and decodedNilFalse[3] == false
    and packCalls == 0 and createCalls == 0, "two-root decode preserves nil/false without a result tuple table")
local decodedFalseNil = table.pack(twoOptionalDecode(falseNilEncoded[2]))
assert(decodedFalseNil.n == 3 and decodedFalseNil[1] == true
    and decodedFalseNil[2] == false and decodedFalseNil[3] == nil,
    "two-root decode preserves false/nil arity")
assert(twoOptionalEncode() == nil and twoOptionalEncode(nil, false, nil) == nil
    and twoOptionalValidate() == nil and twoOptionalValidate(nil, false, nil) == nil
    and twoOptionalDecode() == nil and twoOptionalDecode(nilFalseEncoded[2], nil) == nil,
    "two-root paths retain exact arity checks")
local badTwoOptionalHeader = copied(nilFalseEncoded[2], buffer.len(nilFalseEncoded[2]))
buffer.writeu8(badTwoOptionalHeader, 0, 2)
assert(twoOptionalDecode(badTwoOptionalHeader) == nil, "two-root decode rejects an invalid header")
local badTwoOptionalTag = copied(nilFalseEncoded[2], buffer.len(nilFalseEncoded[2]))
buffer.writeu8(badTwoOptionalTag, 3, 2)
assert(twoOptionalDecode(badTwoOptionalTag) == nil, "two-root decode rejects an invalid optional tag")
assert(twoOptionalDecode(copied(nilFalseEncoded[2], buffer.len(nilFalseEncoded[2]) - 1)) == nil,
    "two-root decode rejects a truncated optional")
assert(twoOptionalDecode(copied(nilFalseEncoded[2], buffer.len(nilFalseEncoded[2]) + 1)) == nil,
    "two-root decode rejects trailing bytes")
assert(packCalls == 0 and createCalls == 0, "two-root rejection paths allocate no tuple tables")

local countedCollectionsDecode = countedFrame.compile(collections, "decode")
packCalls, createCalls = 0, 0
local ownedCollections = table.pack(countedCollectionsDecode(fullCollections))
assert(ownedCollections.n == 3 and ownedCollections[1] == true
    and ownedCollections[2][1] == false and ownedCollections[2][2] == true
    and ownedCollections[3][false] and ownedCollections[3][true]
    and packCalls == 0 and createCalls == 1,
    "two-root collection decode creates only its nested array, not a result tuple")
packCalls, createCalls = 0, 0
local nextOwnedCollections = table.pack(countedCollectionsDecode(fullCollections))
assert(nextOwnedCollections.n == 3 and nextOwnedCollections[1] == true
    and ownedCollections[2] ~= nextOwnedCollections[2] and ownedCollections[3] ~= nextOwnedCollections[3]
    and packCalls == 0 and createCalls == 1, "two-root nested collections belong to each decode invocation")
local oversizedRootArray = copied(fullCollections, buffer.len(fullCollections))
buffer.writeu16(oversizedRootArray, 3, 3)
packCalls, createCalls = 0, 0
assert(countedCollectionsDecode(oversizedRootArray) == nil and packCalls == 0 and createCalls == 0,
    "two-root decode rejects oversized array counts before allocation")
local oversizedRootSet = copied(fullCollections, buffer.len(fullCollections))
buffer.writeu16(oversizedRootSet, 7, 3)
packCalls, createCalls = 0, 0
assert(countedCollectionsDecode(oversizedRootSet) == nil and packCalls == 0 and createCalls == 1,
    "two-root decode rejects oversized set counts")

local operationEvent = { id = 90, delivery = "Reliable", usesCodec = true,
    fields = {
        { type = "f32", minimum = -1, maximum = 1, minimumEncodedBytes = 4 },
        { type = "Vector2F32", minimum = -1, maximum = 1, minimumEncodedBytes = 8 },
        { type = "Vector3F32", minimum = -1, maximum = 1, minimumEncodedBytes = 12 },
    }, minimumEncodedBytes = 27, maximumEncodedBytes = 27 }
local operationEncoder = countedFrame.compile(operationEvent, "encode")
local operationDecoder = countedFrame.compile(operationEvent, "decode")
local operationPacket = assert(select(2, operationEncoder(0.25, Vector2.new(0.5, -0.5), Vector3.new(0.25, 0.5, -0.75))))
local function resetOperations()
    for key in operations do operations[key] = 0 end
end
local vectorEvent = { id = 96, delivery = "Reliable", usesCodec = true,
    fields = {
        { type = "Vector2F32", minimum = -1, maximum = 1, minimumEncodedBytes = 8 },
        { type = "Vector3F32", minimum = -1, maximum = 1, minimumEncodedBytes = 12 },
    }, minimumEncodedBytes = 23, maximumEncodedBytes = 23 }
local vectorValidate = countedFrame.compile(vectorEvent, "validate")
local vectorEncode = countedFrame.compile(vectorEvent, "encode")
local float32Subnormal = 2 ^ -149
local outboundVector2 = Vector2.new(0.5, float32Subnormal)
local outboundVector3 = Vector3.new(-0.25, 0, float32Subnormal)
resetOperations()
packCalls, createCalls = 0, 0
local canonicalVectorValidation = table.pack(vectorValidate(outboundVector2, outboundVector3))
assert(canonicalVectorValidation.n == 3 and canonicalVectorValidation[1] == true
    and canonicalVectorValidation[2] == outboundVector2 and canonicalVectorValidation[3] == outboundVector3
    and operations.vector2 == 0 and operations.vector3 == 0 and packCalls == 0 and createCalls == 0,
    "finite canonical outbound vectors preserve values without constructors or tuple tables")
resetOperations()
packCalls, createCalls = 0, 0
local canonicalVectorEncoding = table.pack(vectorEncode(outboundVector2, outboundVector3))
assert(canonicalVectorEncoding.n == 2 and canonicalVectorEncoding[1] == true
    and buffer.len(canonicalVectorEncoding[2]) == 23
    and buffer.readf32(canonicalVectorEncoding[2], 7) == float32Subnormal
    and buffer.readf32(canonicalVectorEncoding[2], 19) == float32Subnormal
    and operations.vector2 == 0 and operations.vector3 == 0 and packCalls == 0 and createCalls == 0,
    "finite canonical vector encoding preserves subnormals without constructors or tuple tables")

local fallbackVectorEvent = { id = 97, delivery = "Reliable", usesCodec = true,
    fields = {
        { type = "Vector2F32", minimum = -math.huge, maximum = math.huge, minimumEncodedBytes = 8 },
        { type = "Vector3F32", minimum = -math.huge, maximum = math.huge, minimumEncodedBytes = 12 },
    }, minimumEncodedBytes = 23, maximumEncodedBytes = 23 }
local fallbackVectorValidate = countedFrame.compile(fallbackVectorEvent, "validate")
local fallbackVectorEncode = countedFrame.compile(fallbackVectorEvent, "encode")
resetOperations()
packCalls, createCalls = 0, 0
local fallbackCanonicalValidation = table.pack(fallbackVectorValidate(outboundVector2, outboundVector3))
assert(fallbackCanonicalValidation.n == 3 and fallbackCanonicalValidation[1] == true
    and fallbackCanonicalValidation[2] == outboundVector2 and fallbackCanonicalValidation[3] == outboundVector3
    and operations.vector2 == 0 and operations.vector3 == 0 and packCalls == 0 and createCalls == 0,
    "fallback canonical outbound vectors preserve values without constructors or tuple tables")
resetOperations()
packCalls, createCalls = 0, 0
local fallbackCanonicalEncoding = table.pack(fallbackVectorEncode(outboundVector2, outboundVector3))
assert(fallbackCanonicalEncoding.n == 2 and fallbackCanonicalEncoding[1] == true
    and buffer.readf32(fallbackCanonicalEncoding[2], 7) == float32Subnormal
    and buffer.readf32(fallbackCanonicalEncoding[2], 19) == float32Subnormal
    and operations.vector2 == 0 and operations.vector3 == 0 and packCalls == 0 and createCalls == 0,
    "fallback canonical vector encoding preserves subnormals without constructors or tuple tables")
assert(vectorValidate(Vector2.new(2, 0), outboundVector3) == nil
    and fallbackVectorValidate(Vector2.new(math.huge, 0), outboundVector3) == nil,
    "finite vector bounds and fallback finite checks reject invalid inputs")

local outboundNegativeZero = -1 / math.huge
local signedVector2 = Vector2.new(outboundNegativeZero, float32Subnormal)
local signedVector3 = Vector3.new(outboundNegativeZero, outboundNegativeZero, float32Subnormal)
resetOperations()
packCalls, createCalls = 0, 0
local signedVectorValidation = table.pack(vectorValidate(signedVector2, signedVector3))
assert(signedVectorValidation.n == 3 and signedVectorValidation[1] == true
    and 1 / signedVectorValidation[2].X == math.huge
    and signedVectorValidation[2].Y == float32Subnormal
    and 1 / signedVectorValidation[3].X == math.huge
    and 1 / signedVectorValidation[3].Y == math.huge
    and signedVectorValidation[3].Z == float32Subnormal
    and operations.vector2 == 1 and operations.vector3 == 1 and packCalls == 0 and createCalls == 0,
    "finite negative-zero vectors reconstruct once and preserve subnormals")
resetOperations()
packCalls, createCalls = 0, 0
local signedVectorEncoding = table.pack(vectorEncode(signedVector2, signedVector3))
assert(signedVectorEncoding.n == 2 and signedVectorEncoding[1] == true
    and 1 / buffer.readf32(signedVectorEncoding[2], 3) == math.huge
    and buffer.readf32(signedVectorEncoding[2], 7) == float32Subnormal
    and 1 / buffer.readf32(signedVectorEncoding[2], 11) == math.huge
    and 1 / buffer.readf32(signedVectorEncoding[2], 15) == math.huge
    and buffer.readf32(signedVectorEncoding[2], 19) == float32Subnormal
    and operations.vector2 == 1 and operations.vector3 == 1 and packCalls == 0 and createCalls == 0,
    "finite negative-zero encoding canonicalizes signs and preserves subnormals")
resetOperations()
packCalls, createCalls = 0, 0
local fallbackSignedVectorEncoding = table.pack(fallbackVectorEncode(signedVector2, signedVector3))
assert(fallbackSignedVectorEncoding.n == 2 and fallbackSignedVectorEncoding[1] == true
    and 1 / buffer.readf32(fallbackSignedVectorEncoding[2], 3) == math.huge
    and buffer.readf32(fallbackSignedVectorEncoding[2], 7) == float32Subnormal
    and 1 / buffer.readf32(fallbackSignedVectorEncoding[2], 11) == math.huge
    and 1 / buffer.readf32(fallbackSignedVectorEncoding[2], 15) == math.huge
    and buffer.readf32(fallbackSignedVectorEncoding[2], 19) == float32Subnormal
    and operations.vector2 == 1 and operations.vector3 == 1 and packCalls == 0 and createCalls == 0,
    "fallback negative-zero encoding canonicalizes signs and preserves subnormals")

resetOperations()
local operationResult = table.pack(operationDecoder(operationPacket))
assert(operationResult.n == 4 and operationResult[1] == true and operationResult[2] == 0.25
    and operationResult[3] == Vector2.new(0.5, -0.5) and operationResult[4] == Vector3.new(0.25, 0.5, -0.75))
assert(operations.reads == 6 and operations.writes == 0 and operations.vector2 == 1 and operations.vector3 == 1,
    "ordinary scalar and vector decode reads raw floats once and constructs each vector once")

local scalarEvent = { id = 91, delivery = "Reliable", usesCodec = true,
    fields = { { type = "f32", minimum = -1, maximum = 1, minimumEncodedBytes = 4 } },
    minimumEncodedBytes = 7, maximumEncodedBytes = 7 }
local scalarDecode = countedFrame.compile(scalarEvent, "decode")
local function scalarPacket(eventId, value)
    local result = buffer.create(7)
    buffer.writeu8(result, 0, 1)
    buffer.writeu16(result, 1, eventId)
    buffer.writef32(result, 3, value)
    return result
end
local scalarZero = table.pack(scalarDecode(scalarPacket(scalarEvent.id, -1 / math.huge)))
assert(scalarZero.n == 2 and scalarZero[1] == true and scalarZero[2] == 0
    and 1 / scalarZero[2] == math.huge, "raw negative f32 zero canonicalizes directly")
local scalarSubnormal = table.pack(scalarDecode(scalarPacket(scalarEvent.id, float32Subnormal)))
assert(scalarSubnormal.n == 2 and scalarSubnormal[1] == true and scalarSubnormal[2] == float32Subnormal,
    "raw f32 subnormal is preserved")
for _, invalid in { 0 / 0, math.huge, -math.huge, 1.5 } do
    assert(scalarDecode(scalarPacket(scalarEvent.id, invalid)) == nil,
        "raw f32 rejects nonfinite and out-of-bounds values")
end
local positiveScalarEvent = { id = 92, delivery = "Reliable", usesCodec = true,
    fields = { { type = "f32", minimum = 0.5, maximum = 1, minimumEncodedBytes = 4 } },
    minimumEncodedBytes = 7, maximumEncodedBytes = 7 }
assert(countedFrame.compile(positiveScalarEvent, "decode")(scalarPacket(positiveScalarEvent.id, 0)) == nil,
    "raw f32 zero outside bounds rejects")
local fallbackScalarEvent = { id = 93, delivery = "Reliable", usesCodec = true,
    fields = { { type = "f32", minimum = -math.huge, maximum = math.huge, minimumEncodedBytes = 4 } },
    minimumEncodedBytes = 7, maximumEncodedBytes = 7 }
local fallbackScalarDecode = countedFrame.compile(fallbackScalarEvent, "decode")
assert(fallbackScalarDecode(scalarPacket(fallbackScalarEvent.id, 0.5)) == true,
    "raw f32 with internal nonfinite bounds retains finite values")
for _, invalid in { 0 / 0, math.huge, -math.huge } do
    assert(fallbackScalarDecode(scalarPacket(fallbackScalarEvent.id, invalid)) == nil,
        "raw f32 internal-bound fallback rejects nonfinite values")
end

local rawOutOfBoundsVector = buffer.create(buffer.len(operationPacket))
buffer.copy(rawOutOfBoundsVector, 0, operationPacket, 0, buffer.len(operationPacket))
buffer.writef32(rawOutOfBoundsVector, 7, 2)
resetOperations()
assert(operationDecoder(rawOutOfBoundsVector) == nil and operations.vector2 == 0,
    "raw vector bounds reject before construction")
vector2Override = function(_, y) return roblox.Vector2.new(2, y) end
resetOperations()
assert(operationDecoder(operationPacket) == nil and operations.vector2 == 1,
    "post-construction Vector2 bounds reject after one construction")
vector2Override = nil
vector3Override = function(x, y) return roblox.Vector3.new(2, y, 0) end
resetOperations()
assert(operationDecoder(operationPacket) == nil and operations.vector2 == 1 and operations.vector3 == 1,
    "post-construction Vector3 bounds reject after one construction")
vector3Override = nil
local negativeZeroVector = buffer.create(buffer.len(operationPacket))
buffer.copy(negativeZeroVector, 0, operationPacket, 0, buffer.len(operationPacket))
buffer.writef32(negativeZeroVector, 7, -1 / math.huge)
buffer.writef32(negativeZeroVector, 23, -1 / math.huge)
resetOperations()
local canonicalVectors = table.pack(operationDecoder(negativeZeroVector))
assert(canonicalVectors.n == 4 and canonicalVectors[1] == true
    and 1 / canonicalVectors[3].X == math.huge and 1 / canonicalVectors[4].Z == math.huge
    and operations.vector2 == 2 and operations.vector3 == 2,
    "native negative zero takes the second construction only for canonicalization")

local setEvent = { id = 94, delivery = "Reliable", usesCodec = true,
    fields = { { type = "set", maximumSize = 64, minimumEncodedBytes = 2,
        element = { type = "i16", minimum = -32_768, maximum = 32_767, minimumEncodedBytes = 2 } } },
    minimumEncodedBytes = 5, maximumEncodedBytes = 133 }
local setEncode = countedFrame.compile(setEvent, "encode")
local maximumSet = {}
for key = 0, 63 do maximumSet[key] = true end
local maximumSetResult = table.pack(setEncode(maximumSet))
assert(maximumSetResult.n == 2 and maximumSetResult[1] == true and buffer.len(maximumSetResult[2]) == 133,
    "set capacity 64 normalizes and sizes in one bounded scan")
local oversizedSet = table.clone(maximumSet)
oversizedSet[64] = true
assert(setEncode(oversizedSet) == nil, "set capacity 65 rejects")
assert(setEncode({ [40_000] = true }) == nil, "invalid set members reject")
assert(setEncode({ [1] = false }) == nil, "set entries must be true")

local protectedDecode = CompositeCodec.compile({ id = 9, delivery = "Reliable",
    fields = { { type = "Vector2F32", minimum = -1, maximum = 1, minimumEncodedBytes = 8 } },
    minimumEncodedBytes = 11, maximumEncodedBytes = 11 }, "decode", function()
    return function() return nil end, function() return true end, function()
        error("test decoder failure")
    end
end)
local throwingFrame = buffer.create(11)
buffer.writeu8(throwingFrame, 0, 1)
buffer.writeu16(throwingFrame, 1, 9)
buffer.writef32(throwingFrame, 3, 0)
buffer.writef32(throwingFrame, 7, 0)
local protectedResult = table.pack(protectedDecode(throwingFrame))
assert(protectedResult.n == 1 and protectedResult[1] == nil, "decode errors remain protected rejections")

local setResult = table.pack(Frame.compile(output, "encode")({ [-2] = true, [3] = true }, "Ready"))
assert(setResult[1] == true)
local setEncoded = setResult[2]
assert(buffer.len(setEncoded) <= 900)
local duplicateSet = copied(setEncoded, buffer.len(setEncoded))
local firstSetValue = buffer.readi16(duplicateSet, 5)
assert(firstSetValue == -2 or firstSetValue == 3)
buffer.writei16(duplicateSet, 7, firstSetValue)
assert(Frame.compile(output, "decode")(duplicateSet) == nil, "duplicate set member rejected")
local badSetValue = copied(setEncoded, buffer.len(setEncoded))
buffer.writei16(badSetValue, 5, 6)
assert(Frame.compile(output, "decode")(badSetValue) == nil, "out-of-schema set value rejected")

local roundTripOutput = table.pack(Frame.compile(output, "decode")(setEncoded))
assert(roundTripOutput.n == 3 and roundTripOutput[1] == true)
assert(roundTripOutput[2][-2] and roundTripOutput[2][3] and roundTripOutput[3] == "Ready")

local zeroByteChildren = buffer.create(emptyItems.minimumEncodedBytes)
buffer.writeu8(zeroByteChildren, 0, 1)
buffer.writeu16(zeroByteChildren, 1, emptyItems.id)
buffer.writeu16(zeroByteChildren, 3, 64)
local emptyDecoded = table.pack(Frame.compile(emptyItems, "decode")(zeroByteChildren))
assert(emptyDecoded[1] == true and #emptyDecoded[2] == 64,
    "trusted count bounds visits when children encode zero bytes")
buffer.writeu16(zeroByteChildren, 3, 65)
assert(Frame.compile(emptyItems, "decode")(zeroByteChildren) == nil,
    "zero-byte array count above maximum rejected before allocation")

print("PASS Relay.CompositeCodec bounded validation, wire checks, and tuple semantics")
