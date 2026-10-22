local Definition = require("../src/Definition")
local NumericFormats = require("../src/internal/NumericFormats")
local Schema = require("../src/Schema")
local Frame = require("./support/NativeCodec").loadFrame()

local function numericShape(kind, minimum, maximum)
	local shape, suffix, reason = NumericFormats.schema(kind, minimum, maximum)
	assert(shape, `invalid {kind} schema at {suffix}: {reason}`)
	return shape, assert(NumericFormats.compile(shape))
end

local function encodeNumber(operations, value)
	local valid, normalized, width = operations.normalize(value)
	assert(valid, "bounded numeric input normalizes")
	local output = buffer.create(width)
	assert(operations.write(normalized, output, 0) == width)
	return normalized, output
end

local function decodeNumber(operations, input)
	local state = { value = input, offset = 0, length = buffer.len(input) }
	local valid, value = operations.read(state)
	return valid, value, state.offset
end

local halfShape, halfOps = numericShape("f16", -65_504, 65_504)
local halfEven, halfEvenBytes = encodeNumber(halfOps, 1 + 2 ^ -11)
assert(halfEven == 1 and buffer.readu16(halfEvenBytes, 0) == 0x3c00,
	"binary16 midpoint rounds to the even lower significand")
local halfOdd, halfOddBytes = encodeNumber(halfOps, 1 + 3 * 2 ^ -11)
assert(halfOdd == 1 + 2 * 2 ^ -10 and buffer.readu16(halfOddBytes, 0) == 0x3c02,
	"binary16 midpoint above an odd significand rounds to even")
local halfSubnormal, halfSubnormalBytes = encodeNumber(halfOps, 2 ^ -24)
assert(halfSubnormal == 2 ^ -24 and buffer.readu16(halfSubnormalBytes, 0) == 1,
	"binary16 encodes its minimum subnormal")
local halfUnderflow, halfUnderflowBytes = encodeNumber(halfOps, 2 ^ -25)
assert(halfUnderflow == 0 and buffer.readu16(halfUnderflowBytes, 0) == 0,
	"binary16 subnormal midpoint rounds to canonical positive zero")

local compactShape, compactOps = numericShape("f24", -4_294_950_912, 4_294_950_912)
local compactOne, compactBytes = encodeNumber(compactOps, 1)
assert(compactOne == 1 and buffer.readu8(compactBytes, 0) == 0
	and buffer.readu8(compactBytes, 1) == 0 and buffer.readu8(compactBytes, 2) == 0x3e,
	"f24 uses the specified 1/6/17 IEEE layout in little-endian order")
local compactSubnormal, compactSubnormalBytes = encodeNumber(compactOps, 2 ^ -47)
assert(compactSubnormal == 2 ^ -47 and buffer.readu8(compactSubnormalBytes, 0) == 1
	and buffer.readu8(compactSubnormalBytes, 1) == 0 and buffer.readu8(compactSubnormalBytes, 2) == 0,
	"f24 encodes its minimum subnormal")

local doubleShape, doubleOps = numericShape("f64", -math.pi, math.pi)
local double, doubleBytes = encodeNumber(doubleOps, math.pi)
assert(double == math.pi and buffer.readf64(doubleBytes, 0) == math.pi,
	"f64 preserves finite authored values without quantization")
assert(halfShape.maximumError == 16 and compactShape.maximumError == 8_192
	and doubleShape.maximumError == 0,
	"format error bounds reflect half an ULP at the format's maximum exponent")

for _, malformed in {
	{ ops = halfOps, width = 2, bits = 0x7c00 },
	{ ops = halfOps, width = 2, bits = 0x7e00 },
	{ ops = halfOps, width = 2, bits = 0x8000 },
} do
	local input = buffer.create(malformed.width)
	buffer.writeu16(input, 0, malformed.bits)
	local valid, _, offset = decodeNumber(malformed.ops, input)
	assert(not valid and offset == 0, "binary16 rejects nonfinite encodings and negative zero without advancing")
end
local invalidCompact = buffer.create(3)
buffer.writeu8(invalidCompact, 0, 0)
buffer.writeu8(invalidCompact, 1, 0)
buffer.writeu8(invalidCompact, 2, 0x7e)
local compactDecoded, _, compactOffset = decodeNumber(compactOps, invalidCompact)
assert(not compactDecoded and compactOffset == 0, "f24 rejects the reserved exponent before advancing")

local boundedHalfShape, boundedHalfOps = numericShape("f16", 1.0001, 2)
assert(boundedHalfOps.normalize(1.0001) == false,
	"a finite authored bound rejects a value whose rounded representation falls below the bound")
local boundedDoubleShape, boundedDoubleOps = numericShape("f64", -1, 1)
assert(boundedDoubleOps.normalize(2) == false and boundedDoubleShape.maximum == 1,
	"finite authored f64 bounds reject out-of-range payload values")

local S = Schema
local numericToken, numericIssue = Definition.define({
	name = "BoundedNumbers",
	version = 1,
	events = { Values = { id = 1, direction = "ClientToServer", fields = {
		S.field("unsigned", S.u24()),
		S.field("signed", S.i24()),
		S.field("half", S.f16(0, 2)),
		S.field("compact", S.f24(-2, 2)),
		S.field("double", S.f64(-4, 4)),
		S.field("grid", S.quantized(0, 4_294_967_295, 1)),
	} } },
})
assert(numericToken, numericIssue and numericIssue.message or "bounded numeric definition rejected")
local numericDefinition = Definition.get(numericToken)
local numericEvent = numericDefinition.events.Values
assert(numericEvent.usesCodec and numericEvent.minimumEncodedBytes == 3 + 3 + 3 + 2 + 3 + 8 + 4
	and string.find(numericDefinition.descriptor, "|Q1,65536", 1, true)
	and string.find(numericDefinition.descriptor, "|Q2,4294967296", 1, true)
	and string.find(numericDefinition.descriptor, "|BND1", 1, true),
	"wide numeric formats select the bounded codec and explicit capability markers")
local encodeNumbers, decodeNumbers = Frame.compile(numericEvent, "encode"), Frame.compile(numericEvent, "decode")
local numbersOk, packet = encodeNumbers(0xabcdef, -1_234_567, 1 + 2 ^ -11, 1, math.pi, 4_294_967_295)
assert(numbersOk and buffer.len(packet) == 26 and buffer.readu8(packet, 3) == 0xef
	and buffer.readu8(packet, 4) == 0xcd and buffer.readu8(packet, 5) == 0xab
	and buffer.readu16(packet, 9) == 0x3c00 and buffer.readu8(packet, 11) == 0
	and buffer.readu8(packet, 12) == 0 and buffer.readu8(packet, 13) == 0x3e
	and buffer.readf64(packet, 14) == math.pi and buffer.readu32(packet, 22) == 4_294_967_295,
	"u24/i24, rounded f16/f24, native f64, and a four-byte quantized index use compact little-endian wire forms")
local numbers = table.pack(decodeNumbers(packet))
assert(numbers.n == 7 and numbers[1] and numbers[2] == 0xabcdef and numbers[3] == -1_234_567
	and numbers[4] == 1 and numbers[5] == 1 and numbers[6] == math.pi and numbers[7] == 4_294_967_295,
	"the bounded numeric tuple decodes the canonical values")
assert(encodeNumbers(0x1000000, 0, 1, 0, 0, 0) == nil,
	"u24 rejects values outside its signed-width domain before writing")

local boundedShape = S.struct(
	S.field("text", S.string(5, 3)),
	S.field("binary", S.buffer(4, 2)),
	S.field("fixed", S.array(S.u8(), 2, 2)),
	S.field("items", S.array(S.u8(), 4, 2)),
	S.field("members", S.set(S.u8(), 4, 2)),
	S.field("scores", S.map(S.u8(), S.u8(), 4, 2)),
	S.field("flags", S.array(S.boolean(), 4, 2)),
	S.field("fixedFlags", S.array(S.boolean(), 2, 2))
)
local function defineLengths(bitPacking)
	local token, issue = Definition.define({
		name = if bitPacking then "PackedBounds" else "Bounds",
		version = 1,
		bitPacking = bitPacking,
		events = { Values = { id = 2, direction = "ClientToServer", fields = {
			S.field("value", boundedShape),
		} } },
	})
	assert(token, issue and issue.message or "bounded length definition rejected")
	return Definition.get(token)
end

local sample = {
	text = "abc",
	binary = buffer.create(2),
	fixed = { 7, 8 },
	items = { 1, 2, 3 },
	members = { [5] = true, [6] = true },
	scores = { [1] = 10, [2] = 20 },
	flags = { true, false, true },
	fixedFlags = { true, false },
}
buffer.writeu8(sample.binary, 0, 0xaa)
buffer.writeu8(sample.binary, 1, 0xbb)

for _, bitPacking in { false, true } do
	local compiled = defineLengths(bitPacking)
	local event = compiled.events.Values
	assert(event.usesCodec and event.minimumEncodedBytes == (if bitPacking then 26 else 28)
		and event.maximumEncodedBytes == (if bitPacking then 38 else 42),
		"length schema computes minimum encoded bytes from compact and exact counts")
	local encode, decode = Frame.compile(event, "encode"), Frame.compile(event, "decode")
	local valid, packet = encode(sample)
	assert(valid and buffer.len(packet) == (if bitPacking then 27 else 30),
		"bounded strings, buffers and collections fit the compiled maximum")
	assert(buffer.readu8(packet, 3) == 0 and buffer.readu8(packet, 7) == 0
		and buffer.readu8(packet, 12) == 1 and buffer.readu8(packet, 16) == 0,
		"minimum-offset count prefixes use compact bytes and exact arrays omit their prefix")
	local decoded = table.pack(decode(packet))
	assert(decoded.n == 2 and decoded[1] and decoded[2].text == "abc"
		and buffer.len(decoded[2].binary) == 2 and decoded[2].fixed[2] == 8
		and #decoded[2].items == 3 and decoded[2].members[5] == true
		and decoded[2].scores[2] == 20 and #decoded[2].flags == 3
		and #decoded[2].fixedFlags == 2,
		"bounded and exact lengths round-trip through both regular and bit-packed paths")

	for _, invalid in {
		{ text = "ab", binary = sample.binary, fixed = sample.fixed, items = sample.items,
			members = sample.members, scores = sample.scores, flags = sample.flags, fixedFlags = sample.fixedFlags },
		{ text = sample.text, binary = buffer.create(1), fixed = sample.fixed, items = sample.items,
			members = sample.members, scores = sample.scores, flags = sample.flags, fixedFlags = sample.fixedFlags },
		{ text = sample.text, binary = sample.binary, fixed = { 7 }, items = sample.items,
			members = sample.members, scores = sample.scores, flags = sample.flags, fixedFlags = sample.fixedFlags },
		{ text = sample.text, binary = sample.binary, fixed = sample.fixed, items = { 1 },
			members = sample.members, scores = sample.scores, flags = sample.flags, fixedFlags = sample.fixedFlags },
	} do
		assert(encode(invalid) == nil, "authored minimum lengths are enforced before serialization")
	end

	local badString = buffer.create(buffer.len(packet))
	buffer.copy(badString, 0, packet, 0, buffer.len(packet))
	buffer.writeu8(badString, 3, 3)
	assert(decode(badString) == nil, "a compact string count above its span rejects before reading content")
	local badArray = buffer.create(buffer.len(packet))
	buffer.copy(badArray, 0, packet, 0, buffer.len(packet))
	buffer.writeu8(badArray, 12, 3)
	assert(decode(badArray) == nil, "a compact array count above its span rejects before allocating elements")
	for _, countOffset in { 7, 16, 19, 24 } do
		local malformed = buffer.create(buffer.len(packet))
		buffer.copy(malformed, 0, packet, 0, buffer.len(packet))
		buffer.writeu8(malformed, countOffset, 3)
		assert(decode(malformed) == nil,
			"compact buffer, set, map, and packed-boolean counts above their spans reject")
	end
end

for _, shape in {
	S.string(5, 6),
	S.buffer(4, 5),
	S.array(S.u8(), 4, 5),
	S.set(S.u8(), 4, 5),
	S.map(S.u8(), S.u8(), 4, 5),
} do
	local token, issue = Definition.define({ name = "InvalidLength", version = 1, events = {
		Values = { id = 1, direction = "ClientToServer", fields = { S.field("value", shape) } },
	} })
	assert(token == nil and issue and issue.code == "InvalidDefinition",
		"schema rejects minimum counts that exceed their maximum")
end

local wideToken = assert(Definition.define({ name = "WideLength", version = 1, events = {
	Binary = { id = 1, direction = "ClientToServer", fields = {
		S.field("value", S.buffer(8_187, 0)),
	} },
} }))
local wideEvent = Definition.get(wideToken).events.Binary
local wideData = buffer.create(300)
local widePacketOk, widePacket = Frame.compile(wideEvent, "encode")(wideData)
assert(widePacketOk and buffer.len(widePacket) == 305 and buffer.readu16(widePacket, 3) == 300,
	"two-byte compact offsets preserve the existing 8187-byte buffer cap")
local badWidePacket = buffer.create(buffer.len(widePacket))
buffer.copy(badWidePacket, 0, widePacket, 0, buffer.len(widePacket))
buffer.writeu16(badWidePacket, 3, 8_188)
assert(Frame.compile(wideEvent, "decode")(badWidePacket) == nil,
	"two-byte offsets above the retained buffer cap reject before copying the payload")

local variableMapToken = assert(Definition.define({ name = "PackedMapMinimum", version = 1,
    bitPacking = true, events = { Values = { id = 1, direction = "ClientToServer", fields = {
        S.field("values", S.map(S.u8(), S.string(8, 1), 2, 2)),
    } } },
}))
local variableMap = Definition.get(variableMapToken).events.Values
local shortMapOk, shortMapPacket = Frame.compile(variableMap, "encode")({ [1] = "a", [2] = "bc" })
assert(shortMapOk and variableMap.minimumEncodedBytes == 9
    and variableMap.maximumEncodedBytes == 23 and buffer.len(shortMapPacket) == 10,
    "packed map minima use each entry's minimum rather than its maximum")
local shortMapDecoded, shortMapValue = Frame.compile(variableMap, "decode")(shortMapPacket)
assert(shortMapDecoded and shortMapValue[1] == "a" and shortMapValue[2] == "bc",
    "valid short entries in exact-size packed maps round-trip")

print("bounded format checks passed")
