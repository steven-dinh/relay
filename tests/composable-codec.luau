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
} }))
local compiled = Definition.get(token)
local input = compiled.byId[1]
local output = compiled.byId[2]
local optional = compiled.byId[3]
local emptyItems = compiled.byId[5]
local collections = compiled.byId[6]
local bytes = compiled.byId[7]
local widths = compiled.byId[8]
assert(input.usesCodec and output.usesCodec and optional.usesCodec and emptyItems.usesCodec
    and collections.usesCodec and bytes.usesCodec and widths.usesCodec)
assert(input.minimumEncodedBytes == 3 + 1 + 2 + 1 + 2 + 96 + 1)
assert(input.maximumEncodedBytes <= 8_192 and output.maximumEncodedBytes <= 900)

local payload = {
    mode = "Run",
    samples = { Vector2.new(1.5, -2), Vector2.new(3, 4) },
    flags = { [false] = true, [true] = true },
}
local pose = CFrame.new(1, 2, 3)
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
local countedTable = table.clone(table)
countedTable.pack = function(...)
    packCalls += 1
    return table.pack(...)
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
local float32Subnormal = 2 ^ -149
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
