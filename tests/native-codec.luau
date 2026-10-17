local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local support = require("./support/NativeCodec")
local NativeCodec = support.NativeCodec

local function schema(kind, fields)
	local result = { native = true, type = kind }
	for key, value in fields or {} do result[key] = value end
	return result
end

local function roundTrip(codec, value, expectedBytes, verify)
	local ok, normalized, bytes = codec.normalize(value)
	assert(ok and bytes == expectedBytes, `normalization size mismatch: {bytes} / {expectedBytes}`)
	local output = buffer.create(bytes)
	assert(codec.write(normalized, output, 0) == bytes, "writer returns the checked body end")
	local state = { value = output, offset = 0, length = bytes }
	local decoded, result = codec.read(state)
	assert(decoded and state.offset == bytes, `decoder consumes the complete native body: {decoded} at {state.offset}/{bytes}`)
	assert(typeof(result) == typeof(normalized), `decoded native type mismatch: {typeof(result)} / {typeof(normalized)}`)
	if verify then verify(normalized, result, output) end
	return normalized, result, output
end

local function rejectNormalize(codec, value, label)
	assert(codec.normalize(value) == false, label)
end

local function rejectBytes(codec, value, label)
	local state = { value = value, offset = 0, length = buffer.len(value) }
	assert(codec.read(state) == false and state.offset == 0, label)
end

local function writeF64s(value, values)
	for index, number in values do buffer.writef64(value, (index - 1) * 8, number) end
	return value
end

local function enumRecords(family, entries)
	local records = table.create(#entries)
	for index, entry in entries do
		local item = roblox.Enum[family][entry]
		records[index] = table.freeze({ name = entry, value = item.Value })
	end
	return table.freeze(records)
end

local easingStyles = enumRecords("EasingStyle", {
	"Linear", "Sine", "Back", "Quad", "Quart", "Quint", "Bounce", "Elastic", "Exponential", "Circular", "Cubic",
})
local easingDirections = enumRecords("EasingDirection", { "In", "Out", "InOut" })
local fontWeights = enumRecords("FontWeight", {
	"Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Heavy",
})
local fontStyles = enumRecords("FontStyle", { "Normal", "Italic" })
local waypointActions = enumRecords("PathWaypointAction", { "Walk", "Jump", "Custom" })

local enumShape = schema("robloxEnum", {
	enumType = roblox.Enum.EasingStyle,
	enumFamily = tostring(roblox.Enum.EasingStyle),
	values = table.freeze({ roblox.Enum.EasingStyle.Linear, roblox.Enum.EasingStyle.Quad }),
})
local enumCodec = assert(NativeCodec.compile(enumShape))
roundTrip(enumCodec, roblox.Enum.EasingStyle.Quad, 4, function(_, decoded, output)
	assert(decoded == roblox.Enum.EasingStyle.Quad and buffer.readi32(output, 0) == 3)
end)
rejectNormalize(enumCodec, roblox.Enum.EasingStyle.Back, "native enum allowlists reject omitted values")
local badEnum = buffer.create(4)
buffer.writei32(badEnum, 0, roblox.Enum.EasingStyle.Back.Value)
rejectBytes(enumCodec, badEnum, "native enum wire values reject omitted enum items")

local udimCodec = assert(NativeCodec.compile(schema("UDim", {
	minimumScale = -2, maximumScale = 2, minimumOffset = -100, maximumOffset = 100,
})))
roundTrip(udimCodec, roblox.UDim.new(0.25, -9), 12, function(_, decoded, output)
	assert(decoded.Scale == 0.25 and decoded.Offset == -9 and buffer.readi32(output, 8) == -9)
end)
local badUDim = buffer.create(12)
buffer.writef64(badUDim, 0, 3)
rejectBytes(udimCodec, badUDim, "UDim bounds reject before construction")
local roundedUDim = buffer.create(12)
buffer.writef64(roundedUDim, 0, 0.1)
rejectBytes(udimCodec, roundedUDim, "UDim rejects noncanonical wire precision instead of accepting constructor rounding")
local negativeZeroWire = buffer.create(12)
buffer.writef64(negativeZeroWire, 0, -0)
local zeroState = { value = negativeZeroWire, offset = 0, length = 12 }
local zeroValid, zeroValue = udimCodec.read(zeroState)
assert(zeroValid and zeroState.offset == 12 and 1 / zeroValue.Scale == math.huge,
	"UDim decoder canonicalizes negative zero after validating the raw component")
local negativeZeroUDim = roblox.UDim.new(-0, 0)
local positiveZeroUDim = roundTrip(udimCodec, negativeZeroUDim, 12)
assert(1 / positiveZeroUDim.Scale == math.huge, "UDim normalization canonicalizes negative zero")

local udim2Codec = assert(NativeCodec.compile(schema("UDim2", {
	minimumScale = -2, maximumScale = 2, minimumOffset = -100, maximumOffset = 100,
})))
roundTrip(udim2Codec, roblox.UDim2.new(0.25, -9, 0.75, 12), 24, function(_, decoded)
	assert(decoded.X.Scale == 0.25 and decoded.X.Offset == -9 and decoded.Y.Scale == 0.75 and decoded.Y.Offset == 12)
end)

local rangeCodec = assert(NativeCodec.compile(schema("NumberRange", { minimum = -1, maximum = 1 })))
roundTrip(rangeCodec, roblox.NumberRange.new(0.1, 0.7), 16, function(_, decoded, output)
	assert(decoded.Min == roblox.NumberRange.new(0.1, 0.7).Min and decoded.Max == roblox.NumberRange.new(0.1, 0.7).Max)
	assert(buffer.readf64(output, 0) == decoded.Min and buffer.readf64(output, 8) == decoded.Max)
end)
local reversedRange = writeF64s(buffer.create(16), { 0.75, 0.25 })
rejectBytes(rangeCodec, reversedRange, "reversed NumberRange wire endpoints reject before constructor sorting")
local roundedRange = writeF64s(buffer.create(16), { 0.1, 0.2 })
rejectBytes(rangeCodec, roundedRange, "NumberRange rejects wire components the constructor would round")

local rectCodec = assert(NativeCodec.compile(schema("Rect", { minimum = -100, maximum = 100 })))
roundTrip(rectCodec, roblox.Rect.new(roblox.Vector2.new(1, 2), roblox.Vector2.new(3, 4)), 32, function(_, decoded)
	assert(decoded.Min.X == 1 and decoded.Min.Y == 2 and decoded.Max.X == 3 and decoded.Max.Y == 4)
end)
local reorderedRect = writeF64s(buffer.create(32), { 3, 2, 1, 4 })
rejectBytes(rectCodec, reorderedRect, "unordered Rect wire corners reject before constructor sorting")

local brickColors = table.freeze({ roblox.BrickColor.new(21), roblox.BrickColor.new(37) })
local brickCodec = assert(NativeCodec.compile(schema("BrickColor", { values = brickColors })))
roundTrip(brickCodec, roblox.BrickColor.new(21), 2, function(_, decoded, output)
	assert(decoded.Number == 21 and buffer.readu16(output, 0) == 21)
end)
rejectNormalize(brickCodec, roblox.BrickColor.new(1001), "BrickColor rejects colors outside its declared palette")
local badBrick = buffer.create(2)
buffer.writeu16(badBrick, 0, 65_535)
rejectBytes(brickCodec, badBrick, "BrickColor never constructs from an unlisted wire palette number")

local vector2iCodec = assert(NativeCodec.compile(schema("Vector2int16", { minimum = -8, maximum = 8 })))
roundTrip(vector2iCodec, roblox.Vector2int16.new(-3, 7), 4, function(_, decoded, output)
	assert(decoded.X == -3 and decoded.Y == 7 and buffer.readi16(output, 0) == -3)
end)
local badVector2i = buffer.create(4)
buffer.writei16(badVector2i, 0, 9)
rejectBytes(vector2iCodec, badVector2i, "Vector2int16 narrowed bounds reject wire components")

local vector3iCodec = assert(NativeCodec.compile(schema("Vector3int16", { minimum = -8, maximum = 8 })))
roundTrip(vector3iCodec, roblox.Vector3int16.new(-3, 0, 7), 6, function(_, decoded, output)
	assert(decoded.X == -3 and decoded.Y == 0 and decoded.Z == 7 and buffer.readi16(output, 4) == 7)
end)

local numberKeypointShape = schema("NumberSequenceKeypoint", {
	minimum = -1, maximum = 1, maximumEnvelope = 0.5,
})
local numberKeypointCodec = assert(NativeCodec.compile(numberKeypointShape))
roundTrip(numberKeypointCodec, roblox.NumberSequenceKeypoint.new(0.25, 0.5, 0.25), 24, function(_, decoded, output)
	assert(decoded.Time == 0.25 and decoded.Value == 0.5 and decoded.Envelope == 0.25
		and buffer.readf64(output, 16) == decoded.Envelope)
end)
local badNumberKeypoint = writeF64s(buffer.create(24), { 0.25, 2, 0 })
rejectBytes(numberKeypointCodec, badNumberKeypoint, "keypoint scalar bounds reject before construction")

local colorKeypointCodec = assert(NativeCodec.compile(schema("ColorSequenceKeypoint", {})))
roundTrip(colorKeypointCodec, roblox.ColorSequenceKeypoint.new(0.5, roblox.Color3.new(1, 0.25, 0)), 32, function(_, decoded)
	assert(decoded.Time == 0.5 and decoded.Value.R == 1 and decoded.Value.G == 0.25 and decoded.Value.B == 0)
end)
local badColorKeypoint = writeF64s(buffer.create(32), { 0.5, 1.01, 0.25, 0 })
rejectBytes(colorKeypointCodec, badColorKeypoint, "color keypoint channels stay within [0, 1]")

local numberSequenceCodec = assert(NativeCodec.compile(schema("NumberSequence", {
	maximumKeypoints = 20, minimum = -1, maximum = 1, maximumEnvelope = 0.5,
})))
roundTrip(numberSequenceCodec, roblox.NumberSequence.new({
	roblox.NumberSequenceKeypoint.new(0, -0.25, 0),
	roblox.NumberSequenceKeypoint.new(0.5, 0.5, 0.25),
	roblox.NumberSequenceKeypoint.new(1, 0.75, 0),
}), 73, function(_, decoded, output)
	assert(#decoded.Keypoints == 3 and decoded.Keypoints[2].Time == 0.5
		and buffer.readu8(output, 0) == 3 and buffer.readf64(output, 25) == decoded.Keypoints[2].Time)
end)
local duplicateTimes = buffer.create(49)
buffer.writeu8(duplicateTimes, 0, 2)
for index, number in { 0, 0.25, 0, 0, 1, 0 } do buffer.writef64(duplicateTimes, 1 + (index - 1) * 8, number) end
rejectBytes(numberSequenceCodec, duplicateTimes, "NumberSequence duplicate times reject before point construction")
local oversizedSequence = buffer.create(49)
buffer.writeu8(oversizedSequence, 0, 21)
rejectBytes(numberSequenceCodec, oversizedSequence, "NumberSequence counts above the declared cap reject before allocation")
local shortSequence = buffer.create(48)
buffer.writeu8(shortSequence, 0, 2)
rejectBytes(numberSequenceCodec, shortSequence, "NumberSequence count times keypoint width must fit before allocation")

local colorSequenceCodec = assert(NativeCodec.compile(schema("ColorSequence", { maximumKeypoints = 20 })))
roundTrip(colorSequenceCodec, roblox.ColorSequence.new({
	roblox.ColorSequenceKeypoint.new(0, roblox.Color3.new(1, 0, 0)),
	roblox.ColorSequenceKeypoint.new(1, roblox.Color3.new(0, 0, 1)),
}), 65, function(_, decoded, output)
	assert(#decoded.Keypoints == 2 and decoded.Keypoints[1].Value.R == 1 and decoded.Keypoints[2].Value.B == 1
		and buffer.readu8(output, 0) == 2)
end)
local badColorSequence = buffer.create(65)
buffer.writeu8(badColorSequence, 0, 2)
buffer.writef64(badColorSequence, 1, 0)
buffer.writef64(badColorSequence, 9, 0)
buffer.writef64(badColorSequence, 17, 0)
buffer.writef64(badColorSequence, 25, 0)
buffer.writef64(badColorSequence, 33, 1)
buffer.writef64(badColorSequence, 41, 1.01)
buffer.writef64(badColorSequence, 49, 0)
buffer.writef64(badColorSequence, 57, 0)
rejectBytes(colorSequenceCodec, badColorSequence, "ColorSequence rejects out-of-range RGB before construction")

local tweenCodec = assert(NativeCodec.compile(schema("TweenInfo", {
	maximumTime = 10, maximumDelayTime = 5, maximumRepeatCount = 4, allowInfiniteRepeat = false,
	enumPolicies = { EasingStyle = easingStyles, EasingDirection = easingDirections },
})))
local badTween = buffer.create(29)
buffer.writef64(badTween, 0, 11)
rejectBytes(tweenCodec, badTween, "TweenInfo rejects time bounds before constructor access")
local missingTweenConstructor = buffer.create(29)
buffer.writef64(missingTweenConstructor, 0, 1)
buffer.writef64(missingTweenConstructor, 8, 0)
buffer.writei32(missingTweenConstructor, 16, 0)
buffer.writeu8(missingTweenConstructor, 20, 0)
buffer.writei32(missingTweenConstructor, 21, roblox.Enum.EasingStyle.Quad.Value)
buffer.writei32(missingTweenConstructor, 25, roblox.Enum.EasingDirection.Out.Value)
rejectBytes(tweenCodec, missingTweenConstructor, "Lune lacks TweenInfo, so a valid Roblox body is not claimed as portable proof")

local dateCodec = assert(NativeCodec.compile(schema("DateTime", {
	minimum = -17_987_443_200_000, maximum = 253_402_300_799_999,
})))
local badDate = buffer.create(8)
buffer.writef64(badDate, 0, 1.5)
rejectBytes(dateCodec, badDate, "DateTime rejects fractional epoch milliseconds before constructor access")
buffer.writef64(badDate, 0, 253_402_300_800_000)
rejectBytes(dateCodec, badDate, "DateTime rejects timestamps outside the declared calendar range")

local rayCodec = assert(NativeCodec.compile(schema("Ray", {
	minimum = -100, maximum = 100, maximumDirectionMagnitude = 10,
})))
roundTrip(rayCodec, roblox.Ray.new(roblox.Vector3.new(1, 2, 3), roblox.Vector3.new(3, 4, 0)), 48, function(_, decoded)
	assert(decoded.Origin.X == 1 and decoded.Direction.X == 3 and decoded.Direction.Y == 4)
end)
local overlongRay = writeF64s(buffer.create(48), { 0, 0, 0, 8, 8, 0 })
rejectBytes(rayCodec, overlongRay, "Ray direction magnitude is checked without overflow")

local axesCodec = assert(NativeCodec.compile(schema("Axes", {})))
roundTrip(axesCodec, roblox.Axes.new(roblox.Enum.Axis.X, roblox.Enum.Axis.Z), 1, function(_, decoded, output)
	assert(decoded.X and not decoded.Y and decoded.Z and buffer.readu8(output, 0) == 5)
end)
local badAxes = buffer.create(1)
buffer.writeu8(badAxes, 0, 8)
rejectBytes(axesCodec, badAxes, "Axes rejects bits outside its three-bit mask")

local facesCodec = assert(NativeCodec.compile(schema("Faces", {})))
roundTrip(facesCodec, roblox.Faces.new(roblox.Enum.NormalId.Top, roblox.Enum.NormalId.Front), 1, function(_, decoded, output)
	assert(decoded.Top and decoded.Front and not decoded.Bottom and buffer.readu8(output, 0) == 33)
end)
local badFaces = buffer.create(1)
buffer.writeu8(badFaces, 0, 64)
rejectBytes(facesCodec, badFaces, "Faces rejects bits outside its six-bit mask")

local regionCodec = assert(NativeCodec.compile(schema("Region3", { minimum = -100, maximum = 100 })))
roundTrip(regionCodec, roblox.Region3.new(roblox.Vector3.new(1, 2, 3), roblox.Vector3.new(4, 5, 6)), 48, function(_, decoded)
	assert(decoded.CFrame.Position.X == 2.5 and decoded.Size.X == 3 and decoded.Size.Y == 3)
end)
roundTrip(regionCodec, roblox.Region3.new(roblox.Vector3.new(4, 5, 6), roblox.Vector3.new(1, 2, 3)), 48, function(_, decoded)
	assert(decoded.Size.X == -3, "Region3 preserves explicitly reversed corners")
end)
local badRegion = writeF64s(buffer.create(48), { 0, 0, 0, 1000, 0, 0 })
rejectBytes(regionCodec, badRegion, "Region3 derived corners must remain finite and inside declared bounds")

local regionIntCodec = assert(NativeCodec.compile(schema("Region3int16", { minimum = -100, maximum = 100 })))
roundTrip(regionIntCodec, roblox.Region3int16.new(
	roblox.Vector3int16.new(4, 5, 6), roblox.Vector3int16.new(1, 2, 3)), 12, function(_, decoded, output)
	assert(decoded.Min.X == 4 and decoded.Max.X == 1 and buffer.readi16(output, 0) == 4)
end)

local physicalCodec = assert(NativeCodec.compile(schema("PhysicalProperties", {})))
roundTrip(physicalCodec, roblox.PhysicalProperties.new(1, 0.5, 0.25, 2, 3, 0.75), 48, function(_, decoded, output)
	assert(decoded.Density == 1 and decoded.Friction == 0.5 and decoded.AcousticAbsorption == 0.75
		and buffer.readf64(output, 40) == decoded.AcousticAbsorption)
end)
roundTrip(physicalCodec, roblox.PhysicalProperties.new(0.0001, 0, 0, 0, 0, 0), 48, function(_, decoded)
	assert(decoded.Density == 0.00009999999747378752, "the canonical float32 density boundary remains representable")
end)
local badPhysical = writeF64s(buffer.create(48), { 1, 0.5, 0.25, 2, 3, 1.01 })
rejectBytes(physicalCodec, badPhysical, "PhysicalProperties includes and bounds AcousticAbsorption")
local tooSmallDensity = writeF64s(buffer.create(48), { 0.000099, 0.5, 0.25, 2, 3, 0.5 })
rejectBytes(physicalCodec, tooSmallDensity, "PhysicalProperties rejects density below its native minimum")

local fontCodec = assert(NativeCodec.compile(schema("Font", {
	families = table.freeze({ "Arial", "SourceSansPro" }),
	enumPolicies = { FontWeight = fontWeights, FontStyle = fontStyles },
})))
local sourceFont = roblox.Font.new("Arial", roblox.Enum.FontWeight.Bold, roblox.Enum.FontStyle.Italic)
local ownedFont, decodedFont = roundTrip(fontCodec, sourceFont, 9, function(normalized, decoded, output)
	assert(normalized.Family == "Arial" and decoded.Family == "Arial"
		and normalized.Weight == roblox.Enum.FontWeight.Bold and normalized.Style == roblox.Enum.FontStyle.Italic
		and buffer.readu8(output, 0) == 0 and buffer.readi32(output, 1) == 700 and buffer.readi32(output, 5) == 1)
end)
sourceFont.Weight = roblox.Enum.FontWeight.Light
assert(ownedFont.Weight == roblox.Enum.FontWeight.Bold and decodedFont.Weight == roblox.Enum.FontWeight.Bold,
	"Font normalization and decoding return fresh mutable values")
ownedFont.Weight = roblox.Enum.FontWeight.Regular
assert(decodedFont.Weight == roblox.Enum.FontWeight.Bold, "Font decode owns a value separate from normalization")
local badFont = buffer.create(9)
buffer.writeu8(badFont, 0, 9)
rejectBytes(fontCodec, badFont, "Font rejects unknown family ordinals")

local pathCodec = assert(NativeCodec.compile(schema("PathWaypoint", {
	minimum = -100, maximum = 100, maximumLabelBytes = 32,
	enumPolicies = { PathWaypointAction = waypointActions },
})))
local badPath = buffer.create(30)
buffer.writef64(badPath, 0, 0)
buffer.writef64(badPath, 8, 0)
buffer.writef64(badPath, 16, 0)
buffer.writei32(badPath, 24, 99)
rejectBytes(pathCodec, badPath, "PathWaypoint rejects unknown actions before constructor access")
buffer.writei32(badPath, 24, roblox.Enum.PathWaypointAction.Walk.Value)
buffer.writeu16(badPath, 28, 33)
rejectBytes(pathCodec, badPath, "PathWaypoint rejects an oversized label before readstring")

local missingFontPolicy = schema("Font", {
	families = table.freeze({ "Arial" }),
	enumPolicies = {
		FontWeight = table.freeze({ table.freeze({ name = "RemovedWeight", value = -1 }) }),
		FontStyle = fontStyles,
	},
})
assert(NativeCodec.compile(missingFontPolicy) == nil, "an unavailable pinned enum policy fails codec compilation")

local unavailableComposite = luau.load(fs.readFile("src/internal/CompositeCodec.luau"), {
	environment = {
		require = function(path)
			if path == "./InstanceRefs" then return require("../src/internal/InstanceRefs") end
			if path == "./Quantized" then return require("../src/internal/Quantized") end
			if path == "./CompactValues" then return require("../src/internal/CompactValues") end
			if path == "./BitPacking" then return require("../src/internal/BitPacking") end
			assert(path == "./NativeCodec")
			return { compile = function() return nil end }
		end,
	},
	injectGlobals = true,
})()
local unavailableShape = schema("UDim", {
	minimumScale = -1, maximumScale = 1, minimumOffset = -100, maximumOffset = 100,
})
unavailableShape.minimumEncodedBytes = 12
unavailableShape.maximumEncodedBytes = 12
local unavailableEvent = {
	fields = { unavailableShape }, id = 77, delivery = "Reliable",
	minimumEncodedBytes = 3, maximumEncodedBytes = 128,
}
local unavailableValidator = unavailableComposite.compile(unavailableEvent, "validate", function() return nil end)
assert(unavailableValidator(roblox.UDim.new(0.5, 4)) == nil,
	"a native codec that cannot resolve safely rejects normalization without throwing")
local unavailablePacket = buffer.create(15)
buffer.writeu8(unavailablePacket, 0, 1)
buffer.writeu16(unavailablePacket, 1, 77)
buffer.writef64(unavailablePacket, 3, 0.5)
buffer.writei32(unavailablePacket, 11, 4)
local unavailableDecoder = unavailableComposite.compile(unavailableEvent, "decode", function() return nil end)
assert(unavailableDecoder(unavailablePacket) == nil,
	"a native codec that cannot resolve safely rejects decoding without throwing")

for _, case in {
	{ enumCodec, 4 }, { udimCodec, 12 }, { udim2Codec, 24 }, { rangeCodec, 16 }, { rectCodec, 32 }, { brickCodec, 2 },
	{ vector2iCodec, 4 }, { vector3iCodec, 6 }, { numberKeypointCodec, 24 }, { colorKeypointCodec, 32 },
	{ tweenCodec, 29 }, { dateCodec, 8 }, { rayCodec, 48 }, { axesCodec, 1 }, { facesCodec, 1 },
	{ regionCodec, 48 }, { regionIntCodec, 12 }, { physicalCodec, 48 }, { fontCodec, 9 }, { pathCodec, 30 },
} do
	local codec, size = case[1], case[2]
	local truncated = buffer.create(size - 1)
	assert(codec.read({ value = truncated, offset = 0, length = size - 1 }) == false,
		`fixed native body rejects truncation before reading: {size}`)
end
rejectBytes(numberSequenceCodec, buffer.create(0), "sequence body rejects a missing count byte")
rejectBytes(colorSequenceCodec, buffer.create(0), "color sequence rejects a missing count byte")

print("native codec portable checks passed; DateTime, TweenInfo, and PathWaypoint constructor proof requires Roblox Studio")
