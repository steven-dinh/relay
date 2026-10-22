local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Quantized = require("../src/internal/Quantized")

local CompactValues = luau.load(fs.readFile("src/internal/CompactValues.luau"), {
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		require = function(path)
			assert(path == "./Quantized", `unexpected compact-value dependency: {path}`)
			return Quantized
		end,
	},
	injectGlobals = true,
})()

local function schema(kind, minimum, maximum, step)
	local source = { type = kind, minimum = minimum, maximum = maximum }
	source[if kind == "compactCFrame" then "positionStep" else "step"] = step
	local shape, suffix, reason = CompactValues.schema(source)
	assert(shape, `invalid {kind} schema at {suffix}: {reason}`)
	return shape
end

local function reject(kind, minimum, maximum, step, expectedSuffix)
	local source = { type = kind, minimum = minimum, maximum = maximum }
	source[if kind == "compactCFrame" then "positionStep" else "step"] = step
	local shape, suffix = CompactValues.schema(source)
	assert(shape == nil and suffix == expectedSuffix,
		`invalid {kind} schema should fail at {expectedSuffix}, got {tostring(suffix)}`)
end

local function roundTrip(shape, operations, value, expectedWidth)
	local valid, normalized, width = operations.normalize(value)
	assert(valid and normalized == value and width == expectedWidth,
		"normalization preserves the checked immutable native value and fixed encoded width")
	local body = buffer.create(width)
	assert(operations.write(normalized, body, 0) == width, "writer emits the full checked leaf")
	local state = { value = body, offset = 0, length = width }
	local decoded, result = operations.read(state)
	assert(decoded and state.offset == width and typeof(result) == typeof(value),
		"reader constructs the native Roblox value only after validating the full leaf")
	assert(operations.normalize(result), "decoded native value satisfies its schema")
	return result, body
end

local vector3Shape = schema("quantizedVector3", -1, 1, 0.5)
local vector3Ops = assert(CompactValues.compile(vector3Shape))
assert(vector3Shape.width == 3 and vector3Shape.minimumEncodedBytes == 3 and vector3Shape.maximumDepth == 0
	and vector3Shape.maximumComponentError > 0.25 and vector3Shape.maximumComponentError < 0.251,
	"Vector3 stores one bounded scalar code per component")
assert(string.find(vector3Shape.descriptorToken, "VQ1,Vector3,", 1, true) == 1,
	"Vector3 descriptor identifies its type and scalar grid")
local vector3Result, vector3Body = roundTrip(vector3Shape, vector3Ops, roblox.Vector3.new(0.25, -0.75, 1), 3)
assert(vector3Result == roblox.Vector3.new(0.5, -0.5, 1)
	and buffer.readu8(vector3Body, 0) == 3 and buffer.readu8(vector3Body, 1) == 1
	and buffer.readu8(vector3Body, 2) == 4,
	"Vector3 rounds each component with higher-index ties and uses one byte per axis")
local vector3Zero = roundTrip(vector3Shape, vector3Ops, roblox.Vector3.new(-0, -0.5, 0), 3)
assert(1 / vector3Zero.X == math.huge and 1 / vector3Zero.Z == math.huge,
	"vector zero components are canonicalized through scalar codes")
for _, value in {
	roblox.Vector2.new(0, 0),
	roblox.Vector3.new(math.huge, 0, 0),
	roblox.Vector3.new(1.01, 0, 0),
	roblox.Vector3.new(0 / 0, 0, 0),
} do
	assert(vector3Ops.normalize(value) == false, "Vector3 checks exact native type, finiteness and original bounds")
end

local vector2Shape = schema("quantizedVector2", 0, 256, 1)
local vector2Ops = assert(CompactValues.compile(vector2Shape))
assert(vector2Shape.width == 4 and vector2Shape.scalarWidth == 2,
	"257 scalar codes select the two-byte component form")
local vector2Result, vector2Body = roundTrip(vector2Shape, vector2Ops, roblox.Vector2.new(255.5, 0), 4)
assert(vector2Result == roblox.Vector2.new(256, 0)
	and buffer.readu16(vector2Body, 0) == 256 and buffer.readu16(vector2Body, 2) == 0,
	"Vector2 uses complete little-endian component words")

local vector3WideShape = schema("quantizedVector3", 0, 65_536, 1)
local vector3WideOps = assert(CompactValues.compile(vector3WideShape))
local vector3Wide, vector3WideBody = roundTrip(vector3WideShape, vector3WideOps,
	roblox.Vector3.new(65_536, 0, 1), 9)
assert(vector3Wide == roblox.Vector3.new(65_536, 0, 1)
	and buffer.readu8(vector3WideBody, 0) == 0 and buffer.readu8(vector3WideBody, 1) == 0
	and buffer.readu8(vector3WideBody, 2) == 1 and buffer.readu8(vector3WideBody, 3) == 0
	and buffer.readu8(vector3WideBody, 4) == 0 and buffer.readu8(vector3WideBody, 5) == 0
	and buffer.readu8(vector3WideBody, 6) == 1 and buffer.readu8(vector3WideBody, 7) == 0
	and buffer.readu8(vector3WideBody, 8) == 0
	and string.sub(vector3WideShape.descriptorToken, 1, 4) == "VQ2,",
	"Vector3 supports three-byte component indexes while retaining its native precision guard")

reject("quantizedVector3", 0.1, 1, 0.1, ".minimum")
reject("quantizedVector2", 0, 1, 2 ^ -126, ".step")
reject("compactCFrame", 0.1, 1, 0.1, ".minimum")
reject("compactCFrame", 0, 1, 0, ".positionStep")

local frameShape = schema("compactCFrame", -100, 100, 1)
local frameOps = assert(CompactValues.compile(frameShape))
assert(frameShape.width == 9 and frameShape.minimumEncodedBytes == 9
	and CompactValues.ROTATION_ERROR == 0.002
	and string.find(frameShape.descriptorToken, "CF1,", 1, true) == 1,
	"compact CFrame pins its position grid, six-byte XYZ rotation and error contract")

local fourByteFrameShape = schema("compactCFrame", 0, 4_294_967_040, 1)
local fourByteFrameOps = assert(CompactValues.compile(fourByteFrameShape))
local fourByteFrame, fourByteFrameBody = roundTrip(fourByteFrameShape, fourByteFrameOps,
	roblox.CFrame.new(4_294_967_040, 0, 0), 18)
assert(fourByteFrame == roblox.CFrame.new(4_294_967_040, 0, 0)
	and buffer.readu32(fourByteFrameBody, 0) == 4_294_967_040
	and string.sub(fourByteFrameShape.descriptorToken, 1, 4) == "CF2,",
	"compact CFrame supports four-byte stable position indexes with a distinct wide descriptor token")

local identity, identityBytes = roundTrip(frameShape, frameOps, roblox.CFrame.new(), 9)
assert(identity == roblox.CFrame.new() and buffer.readu16(identityBytes, 3) == 0
	and buffer.readu16(identityBytes, 5) == 0 and buffer.readu16(identityBytes, 7) == 0,
	"identity rotation has three canonical zero codes")

local piFrame = roblox.CFrame.fromEulerAnglesXYZ(math.pi, 0, 0)
local piResult, piBytes = roundTrip(frameShape, frameOps, piFrame, 9)
assert(buffer.readu16(piBytes, 3) == 32_768 and piResult:AngleBetween(piFrame) <= CompactValues.ROTATION_ERROR,
	"the pi code represents the same rotation through the [-pi, pi) decode convention")

local wrappedCode = buffer.create(9)
buffer.writeu16(wrappedCode, 7, 65_535)
local wrappedState = { value = wrappedCode, offset = 0, length = buffer.len(wrappedCode) }
assert(frameOps.read(wrappedState) and wrappedState.offset == 9,
	"all unsigned rotation words, including the wraparound code, are valid")

for _, angles in {
	{ 0, math.pi / 2, 0 },
	{ 0.7, -1.1, 2.4 },
	{ -2.2, 0.3, -0.9 },
} do
	local source = roblox.CFrame.new(10.25, -5.5, 2.75) * roblox.CFrame.fromEulerAnglesXYZ(angles[1], angles[2], angles[3])
	local result = roundTrip(frameShape, frameOps, source, 9)
	local sx, sy, sz = source:GetComponents()
	local rx, ry, rz = result:GetComponents()
	assert(math.abs(rx - sx) <= frameShape.maximumPositionError
		and math.abs(ry - sy) <= frameShape.maximumPositionError
		and math.abs(rz - sz) <= frameShape.maximumPositionError
		and source:AngleBetween(result) <= CompactValues.ROTATION_ERROR,
		"CFrame position and rotation meet their separate post-construction error bounds")
end

for _, value in {
	roblox.Vector3.new(0, 0, 0),
	roblox.CFrame.new(101, 0, 0),
	roblox.CFrame.new(0, 0, 0, 1.01, 0, 0, 0, 1, 0, 0, 0, 1),
	roblox.CFrame.new(0, 0, 0, -1, 0, 0, 0, 1, 0, 0, 0, 1),
} do
	assert(frameOps.normalize(value) == false, "CFrame checks exact type, position bounds and proper rigid rotation")
end
local nonfiniteOk, nonfiniteFrame = pcall(roblox.CFrame.new, math.huge, 0, 0)
if nonfiniteOk then
	assert(frameOps.normalize(nonfiniteFrame) == false, "nonfinite CFrame components are rejected before decomposition")
end

local function rejectRead(operations, body, message)
	local state = { value = body, offset = 0, length = buffer.len(body) }
	assert(operations.read(state) == false and state.offset == 0, message)
end

local vectorUnused = buffer.create(3)
buffer.writeu8(vectorUnused, 0, 5)
rejectRead(vector3Ops, vectorUnused, "unused vector component codes reject without advancing the caller state")
rejectRead(vector2Ops, buffer.create(3), "truncated vector words reject before a partial read")

local frameUnusedPosition = buffer.create(9)
buffer.writeu8(frameUnusedPosition, 0, 201)
rejectRead(frameOps, frameUnusedPosition, "unused CFrame position codes reject before constructing a CFrame")
rejectRead(frameOps, buffer.create(8), "truncated CFrames reject before a partial read")

print("compact value checks passed")
