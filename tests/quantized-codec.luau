local Quantized = require("../src/internal/Quantized")
local support = require("./support/NativeCodec")
local CompositeCodec = support.CompositeCodec
local Frame = support.loadFrame()

local function schema(minimum, maximum, step)
	local value, suffix, reason = Quantized.schema({
		type = "quantized",
		minimum = minimum,
		maximum = maximum,
		step = step,
	})
	return value, suffix, reason
end

local function compile(minimum, maximum, step)
	local shape, suffix, reason = schema(minimum, maximum, step)
	assert(shape, `invalid quantized schema at {suffix}: {reason}`)
	local operations = assert(Quantized.compile(shape))
	return shape, operations
end

local function rejectSchema(minimum, maximum, step, expectedSuffix)
	local shape, suffix = schema(minimum, maximum, step)
	assert(shape == nil and suffix == expectedSuffix,
		`invalid quantized schema should fail at {expectedSuffix}, got {tostring(suffix)}`)
end

local function roundTrip(shape, operations, value, expectedIndex)
	local valid, canonical, width = operations.normalize(value)
	assert(valid and width == shape.width, "normalization returns a bounded canonical scalar and fixed width")
	assert(math.abs(canonical - value) <= shape.maximumError, "canonical value stays within the documented error bound")
	local body = buffer.create(width)
	assert(operations.write(canonical, body, 0) == width, "writer emits the checked scalar width")
	local index = if width == 1 then buffer.readu8(body, 0) else buffer.readu16(body, 0)
	assert(index == expectedIndex, `unexpected quantized index: {index} / {expectedIndex}`)
	local state = { value = body, offset = 0, length = width }
	local decoded, result = operations.read(state)
	assert(decoded and result == canonical and state.offset == width, "reader consumes and reconstructs one canonical scalar")
	local validAgain, canonicalAgain = operations.normalize(result)
	assert(validAgain and canonicalAgain == canonical, "decoded values normalize idempotently")
	local bodyAgain = buffer.create(width)
	assert(operations.write(canonicalAgain, bodyAgain, 0) == width
		and buffer.tostring(bodyAgain) == buffer.tostring(body), "canonical decode and re-encode preserves exact bytes")
	return canonical, body
end

local byteShape, byteOps = compile(0, 255, 1)
assert(byteShape.maximumIndex == 255 and byteShape.width == 1
	and byteShape.minimumEncodedBytes == 1 and byteShape.maximumEncodedBytes == 1)
assert(byteShape.descriptorToken == "Q1,0000000000000000,406fe00000000000,3ff0000000000000,255,1",
	"descriptor uses exact binary64 tokens and pins the derived width")
local byteCanonical, byteBody = roundTrip(byteShape, byteOps, 254.5, 255)
assert(byteCanonical == 255 and buffer.readu8(byteBody, 0) == 255)

local wordShape, wordOps = compile(0, 256, 1)
assert(wordShape.maximumIndex == 256 and wordShape.width == 2,
	"257 scalar codes switch to a two-byte body")
local wordCanonical, wordBody = roundTrip(wordShape, wordOps, 255.5, 256)
assert(wordCanonical == 256 and buffer.readu16(wordBody, 0) == 256)

local maximumShape, maximumOps = compile(0, 65_535, 1)
assert(maximumShape.maximumIndex == 65_535 and maximumShape.width == 2,
	"the maximum 65,536 scalar codes fit the bounded two-byte form")
roundTrip(maximumShape, maximumOps, 65_535, 65_535)
rejectSchema(0, 65_536, 1, ".step")

local minimumStep = Quantized.MINIMUM_STEP
assert(minimumStep == 2 ^ -974, "the minimum supported step keeps the roundoff allowance normal on Roblox")
local tinyShape, tinyOps = compile(0, 2 * minimumStep, minimumStep)
roundTrip(tinyShape, tinyOps, 0, 0)
local tinyInterior = roundTrip(tinyShape, tinyOps, minimumStep, 1)
assert(tinyInterior == minimumStep, "the exact minimum step retains a stable interior code")
roundTrip(tinyShape, tinyOps, 2 * minimumStep, 2)
local tinyRounded = roundTrip(tinyShape, tinyOps, 1.25 * minimumStep, 1)
assert(tinyRounded == minimumStep, "the exact minimum step rounds to its stable nearest index")
local immediatelyBelowMinimumStep = minimumStep - 2 ^ -1026
rejectSchema(0, 2 * immediatelyBelowMinimumStep, immediatelyBelowMinimumStep, ".step")

local residualMinimum = 1e13
local residualShape, residualOps = compile(residualMinimum, residualMinimum + 1.03125, 1)
assert(math.abs((residualShape.maximum - residualShape.minimum) - residualShape.step)
	<= residualShape.roundoffAllowance, "the authored endpoint residual is within its explicit allowance")
roundTrip(residualShape, residualOps, residualMinimum, 0)
roundTrip(residualShape, residualOps, residualShape.maximum, 1)
local residualRounded = roundTrip(residualShape, residualOps, residualMinimum + 0.5, 1)
assert(residualRounded == residualShape.maximum
	and math.abs(residualRounded - (residualMinimum + 0.5)) > residualShape.step / 2
	and math.abs(residualRounded - (residualMinimum + 0.5)) <= residualShape.maximumError,
	"a permitted large-offset residual has a stable code and stays within the declared error bound")

local decimalShape, decimalOps = compile(0.1, 0.1001, 0.0001)
assert(decimalShape.maximumIndex == 1 and decimalShape.width == 1,
	"decimal endpoint cancellation fits within the binary64 roundoff allowance")
roundTrip(decimalShape, decimalOps, 0.1, 0)
roundTrip(decimalShape, decimalOps, 0.1001, 1)
rejectSchema(0, 1.01, 1, ".maximum")

local negativeShape, negativeOps = compile(-2, 2, 1)
assert(roundTrip(negativeShape, negativeOps, -1.5 - 2 ^ -52, 0) == -2,
	"the representable value below a midpoint rounds down")
assert(roundTrip(negativeShape, negativeOps, -1.5, 1) == -1,
	"an exact midpoint rounds toward the higher numeric index")
assert(roundTrip(negativeShape, negativeOps, -1.5 + 2 ^ -52, 1) == -1,
	"the representable value above a midpoint rounds up")

local zeroShape, zeroOps = compile(-1, 1, 1)
local positiveZero = roundTrip(zeroShape, zeroOps, -0, 1)
assert(positiveZero == 0 and 1 / positiveZero == math.huge,
	"payload negative zero is canonicalized to positive zero")

for _, value in { -1, 256, math.huge, -math.huge, 0 / 0, true, "1" } do
	assert(byteOps.normalize(value) == false, "payload type, finiteness, and original bounds are checked before rounding")
end
assert(byteOps.normalize(nil) == false, "nil is not a quantized scalar")
assert(byteOps.normalize(-0.5) == false and byteOps.normalize(255.5) == false,
	"out-of-range values are rejected instead of clamped into the grid")

rejectSchema(1, 1, 1, ".maximum")
rejectSchema(2, 1, 1, ".maximum")
rejectSchema(0, 1, 0, ".step")
rejectSchema(0, 1, 2 ^ -975, ".step")
rejectSchema(-1e308, 1e308, 1, ".maximum")
rejectSchema(0, 1e308, Quantized.MINIMUM_STEP, ".step")
rejectSchema(1, 1 + 2 ^ -52, 2 ^ -53, ".step")

local unusedShape, unusedOps = compile(0, 3, 1)
local unused = buffer.create(1)
buffer.writeu8(unused, 0, 4)
local unusedState = { value = unused, offset = 0, length = 1 }
assert(unusedOps.read(unusedState) == false and unusedState.offset == 0,
	"unused byte codes reject before changing decoder state")

local truncated = buffer.create(1)
local truncatedState = { value = truncated, offset = 0, length = 1 }
assert(wordOps.read(truncatedState) == false and truncatedState.offset == 0,
	"a truncated two-byte code rejects before reading")
local unusedWord = buffer.create(2)
buffer.writeu16(unusedWord, 0, 257)
local unusedWordState = { value = unusedWord, offset = 0, length = 2 }
assert(wordOps.read(unusedWordState) == false and unusedWordState.offset == 0,
	"unused two-byte codes reject before reconstruction")

local function eventFor(shape, id)
	return {
		id = id,
		delivery = "Reliable",
		hasReferences = false,
		fields = { shape },
		minimumEncodedBytes = 3 + shape.minimumEncodedBytes,
		maximumEncodedBytes = 3 + shape.maximumEncodedBytes,
	}
end

local compositeEvent = eventFor(byteShape, 0x1234)
local encode = CompositeCodec.compile(compositeEvent, "encode", function() return nil end)
local decode = CompositeCodec.compile(compositeEvent, "decode", function() return nil end)
local encoded = table.pack(encode(254.5))
assert(encoded.n == 2 and encoded[1] == true and buffer.len(encoded[2]) == 4,
	"composite event uses the existing header and exact quantized body size")
assert(buffer.readu8(encoded[2], 0) == 1 and buffer.readu16(encoded[2], 1) == 0x1234
	and buffer.readu8(encoded[2], 3) == 255, "composite frame preserves the current format and writes the rounded code")
local decoded = table.pack(decode(encoded[2]))
assert(decoded.n == 2 and decoded[1] == true and decoded[2] == 255,
	"composite frame decodes the canonical rounded value")

local unusedEvent = eventFor(unusedShape, 0x1234)
local decodeUnused = CompositeCodec.compile(unusedEvent, "decode", function() return nil end)
local unusedFrame = buffer.create(4)
buffer.writeu8(unusedFrame, 0, 1)
buffer.writeu16(unusedFrame, 1, 0x1234)
buffer.writeu8(unusedFrame, 3, 4)
assert(decodeUnused(unusedFrame) == nil, "composite decoder rejects unused codes before returning a payload")
local trailingEvent = eventFor(byteShape, 0x1234)
trailingEvent.maximumEncodedBytes += 1
local decodeTrailing = CompositeCodec.compile(trailingEvent, "decode", function() return nil end)
local trailingFrame = buffer.create(5)
buffer.copy(trailingFrame, 0, encoded[2], 0, 4)
assert(decodeTrailing(trailingFrame) == nil, "composite decoder rejects trailing bytes after reading the scalar")

local world = support.World
local root = require("@lune/roblox").Instance.new("Folder")
root.Parent = world
local part = require("@lune/roblox").Instance.new("Part")
part.Parent = root
local mixedShape = compile(0, 10, 1)
local referenceShape = { type = "Instance", className = "Part", containsReferences = true,
	minimumEncodedBytes = 1, maximumEncodedBytes = 1 }
local mixedEvent = {
	id = 27,
	delivery = "Reliable",
	usesCodec = true,
	hasReferences = true,
	maximumReferences = 1,
	minimumEncodedBytes = 6,
	maximumEncodedBytes = 8_192,
	fields = { referenceShape, mixedShape },
}
local encodeMixed = Frame.compile(mixedEvent, "encode", { server = true, root = root })
local decodeMixed = Frame.compile(mixedEvent, "decode", { server = true, root = root })
local mixedEncoded = table.pack(encodeMixed(part, 5.6))
assert(mixedEncoded.n == 3 and mixedEncoded[1] == true and mixedEncoded[3] == part
	and buffer.readu8(mixedEncoded[2], 0) == 4 and buffer.readu16(mixedEncoded[2], 1) == mixedEvent.id
	and buffer.readu8(mixedEncoded[2], 3) == 1 and buffer.readu8(mixedEncoded[2], 4) == 1
	and buffer.readu8(mixedEncoded[2], 5) == 6,
	"mixed reference and quantized scalar encoding preserves format 4, slot order, and rounding")
local mixedDecoded = table.pack(decodeMixed(mixedEncoded[2], mixedEncoded[3]))
assert(mixedDecoded.n == 3 and mixedDecoded[1] == true and mixedDecoded[2] == part and mixedDecoded[3] == 6,
	"mixed reference recursion decodes the original object and rounded scalar")
local badMixedFrame = buffer.create(buffer.len(mixedEncoded[2]))
buffer.copy(badMixedFrame, 0, mixedEncoded[2], 0, buffer.len(mixedEncoded[2]))
buffer.writeu8(badMixedFrame, 5, 11)
assert(decodeMixed(badMixedFrame, mixedEncoded[3]) == nil,
	"a malformed quantized leaf rejects the complete mixed reference frame")

print("quantized codec checks passed")
