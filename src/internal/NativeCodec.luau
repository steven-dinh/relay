local FIXED_BYTES = table.freeze({
	robloxEnum = 4,
	UDim = 12,
	UDim2 = 24,
	NumberRange = 16,
	Rect = 32,
	BrickColor = 2,
	Vector2int16 = 4,
	Vector3int16 = 6,
	NumberSequenceKeypoint = 24,
	ColorSequenceKeypoint = 32,
	Color3RGB8 = 3,
	TweenInfo = 29,
	DateTime = 8,
	Ray = 48,
	Axes = 1,
	Faces = 1,
	Region3 = 48,
	Region3int16 = 12,
	PhysicalProperties = 48,
	Font = 9,
})
local MINIMUM_PHYSICAL_DENSITY = 0.00009999999747378752
local COLOR3_RGB8_CONSTRUCTION_ALLOWANCE = 2 ^ -24
local COLOR3_RGB8_MAXIMUM_ERROR = 1 / 510 + COLOR3_RGB8_CONSTRUCTION_ALLOWANCE
local AXIS_NAMES = table.freeze({ "X", "Y", "Z" })
local FACE_NAMES = table.freeze({ "Top", "Bottom", "Left", "Right", "Back", "Front" })

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value, minimum, maximum)
	return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function positiveZero(value)
	return if value == 0 then 0 else value
end

local function sameNumber(left, right)
	return left == right and (left ~= 0 or 1 / left == 1 / right)
end

local function inRange(value, minimum, maximum)
	return finite(value) and value >= minimum and value <= maximum
end

local function makeUDim(scale, offset)
	return UDim.new(scale, offset)
end

local function makeUDim2(scaleX, offsetX, scaleY, offsetY)
	return UDim2.new(scaleX, offsetX, scaleY, offsetY)
end

local function makeNumberRange(minimum, maximum)
	return NumberRange.new(minimum, maximum)
end

local function makeRect(minimum, maximum)
	return Rect.new(minimum, maximum)
end

local function makeVector2(x, y)
	return Vector2.new(x, y)
end

local function makeVector2int16(x, y)
	return Vector2int16.new(x, y)
end

local function makeVector3int16(x, y, z)
	return Vector3int16.new(x, y, z)
end

local function makeVector3(x, y, z)
	return Vector3.new(x, y, z)
end

local function makeColor3(red, green, blue)
	return Color3.new(red, green, blue)
end

local function makeNumberSequenceKeypoint(time, value, envelope)
	return NumberSequenceKeypoint.new(time, value, envelope)
end

local function makeColorSequenceKeypoint(time, color)
	return ColorSequenceKeypoint.new(time, color)
end

local function makeNumberSequence(points)
	return NumberSequence.new(points)
end

local function makeColorSequence(points)
	return ColorSequence.new(points)
end

local function makeTweenInfo(time, style, direction, repeatCount, reverses, delayTime)
	return TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)
end

local function makeDateTime(milliseconds)
	return DateTime.fromUnixTimestampMillis(milliseconds)
end

local function makeRay(origin, direction)
	return Ray.new(origin, direction)
end

local function makeAxes(items)
	return Axes.new(table.unpack(items, 1, #items))
end

local function makeFaces(items)
	return Faces.new(table.unpack(items, 1, #items))
end

local function makeRegion3(minimum, maximum)
	return Region3.new(minimum, maximum)
end

local function makeRegion3int16(minimum, maximum)
	return Region3int16.new(minimum, maximum)
end

local function makePhysicalProperties(density, friction, elasticity, frictionWeight, elasticityWeight, absorption)
	return PhysicalProperties.new(density, friction, elasticity, frictionWeight, elasticityWeight, absorption)
end

local function makeFont(family, weight, style)
	return Font.new(family, weight, style)
end

local function makePathWaypoint(position, action, label)
	return PathWaypoint.new(position, action, label)
end

local function protectedMake(callback, ...)
	local ok, value = pcall(callback, ...)
	return if ok then value else nil
end

local function color3RGB8Byte(value)
	return math.floor(value * 255 + 0.5)
end

local function validColor3RGB8Component(value, code)
	local expected = positiveZero(code / 255)
	return inRange(value, 0, 1) and math.abs(value - expected) <= COLOR3_RGB8_CONSTRUCTION_ALLOWANCE
		and color3RGB8Byte(value) == code and (code ~= 0 or 1 / value == math.huge)
end

local function makeColor3RGB8(red, green, blue)
	local color = protectedMake(makeColor3, positiveZero(red / 255), positiveZero(green / 255), positiveZero(blue / 255))
	if typeof(color) ~= "Color3" or not validColor3RGB8Component(color.R, red)
		or not validColor3RGB8Component(color.G, green) or not validColor3RGB8Component(color.B, blue) then
		return nil
	end
	return color
end

local function hasBytes(state, count)
	return count >= 0 and state.offset <= state.length - count
end

local function compileEnumPolicy(records, familyName)
	if type(records) ~= "table" or getmetatable(records) ~= nil then return nil end
	local ok, family = pcall(function() return Enum[familyName] end)
	if not ok or typeof(family) ~= "Enum" then return nil end

	local count, maximumIndex = 0, 0
	for index, record in records do
		count += 1
		if count > 32 or type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 32 then
			return nil
		end
		if index > maximumIndex then maximumIndex = index end
		if type(record) ~= "table" or getmetatable(record) ~= nil
			or type(record.name) ~= "string" or not integer(record.value, -2_147_483_648, 2_147_483_647) then
			return nil
		end
	end
	if count == 0 or count ~= maximumIndex then return nil end

	local items = table.create(count)
	local byValue = {}
	for index = 1, count do
		local record = rawget(records, index)
		local okItem, item = pcall(function() return family[record.name] end)
		if not okItem or typeof(item) ~= "EnumItem" or item.EnumType ~= family
			or item.Name ~= record.name or item.Value ~= record.value or byValue[record.value] ~= nil then
			return nil
		end
		items[index] = item
		byValue[record.value] = item
	end
	return { family = family, items = items, byValue = byValue }
end

local function compilePolicies(shape, names)
	local output = {}
	for _, name in names do
		local compiled = compileEnumPolicy(shape.enumPolicies and shape.enumPolicies[name], name)
		if compiled == nil then return nil end
		output[name] = compiled
	end
	return output
end

local function validPolicyItem(policy, value)
	if policy == nil or typeof(value) ~= "EnumItem" or value.EnumType ~= policy.family then return nil end
	local allowed = policy.byValue[value.Value]
	if allowed == nil or allowed.Name ~= value.Name then return nil end
	return allowed
end

local function enumValuePolicy(policy, value)
	local item = if policy == nil then nil else policy.byValue[value]
	return item
end

local function validEnumShape(shape)
	if typeof(shape.enumType) ~= "Enum" or type(shape.enumFamily) ~= "string"
		or tostring(shape.enumType) ~= shape.enumFamily or type(shape.values) ~= "table"
		or getmetatable(shape.values) ~= nil then
		return nil
	end
	local count, maximumIndex = 0, 0
	for index, value in shape.values do
		count += 1
		if count > 32 or type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 32 then return nil end
		if index > maximumIndex then maximumIndex = index end
		if typeof(value) ~= "EnumItem" or value.EnumType ~= shape.enumType
			or not integer(value.Value, -2_147_483_648, 2_147_483_647) then return nil end
	end
	if count == 0 or count ~= maximumIndex then return nil end
	local byValue, ordinals = {}, {}
	for index = 1, count do
		local value = rawget(shape.values, index)
		if byValue[value.Value] ~= nil then return nil end
		byValue[value.Value] = value
		ordinals[value.Value] = index
	end
	return { byValue = byValue, ordinals = ordinals }
end

local function validBrickColors(shape)
	if type(shape.values) ~= "table" or getmetatable(shape.values) ~= nil then return nil end
	local count, maximumIndex = 0, 0
	for index, value in shape.values do
		count += 1
		if count > 32 or type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 32 then return nil end
		if index > maximumIndex then maximumIndex = index end
		if typeof(value) ~= "BrickColor" or not integer(value.Number, 0, 65_535) then return nil end
	end
	if count == 0 or count ~= maximumIndex then return nil end
	local byNumber = {}
	for index = 1, count do
		local color = rawget(shape.values, index)
		if byNumber[color.Number] ~= nil then return nil end
		byNumber[color.Number] = color
	end
	return byNumber
end

local function validFamilies(shape)
	if type(shape.families) ~= "table" or getmetatable(shape.families) ~= nil then return nil end
	local count, maximumIndex = 0, 0
	local ordinals = {}
	for index, family in shape.families do
		count += 1
		if count > 32 or type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 32
			or type(family) ~= "string" or #family < 1 or #family > 256 then return nil end
		if index > maximumIndex then maximumIndex = index end
		if ordinals[family] ~= nil then return nil end
		ordinals[family] = index
	end
	if count == 0 or count ~= maximumIndex then return nil end
	return ordinals
end

local function vector3WithinOrigin(shape, x, y, z)
	return inRange(x, shape.minimum, shape.maximum) and inRange(y, shape.minimum, shape.maximum)
		and inRange(z, shape.minimum, shape.maximum)
end

local function directionWithinMagnitude(x, y, z, maximum)
	if not finite(x) or not finite(y) or not finite(z) then return false end
	local scale = math.max(math.abs(x), math.abs(y), math.abs(z))
	if scale == 0 then return true end
	if maximum == 0 then return false end
	local normalizedX, normalizedY, normalizedZ = x / scale, y / scale, z / scale
	local root = math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY + normalizedZ * normalizedZ)
	return scale <= maximum / root
end

local function makeFlagItems(family, names)
	local items = table.create(#names)
	for index, name in names do
		local ok, item = pcall(function() return Enum[family][name] end)
		if not ok or typeof(item) ~= "EnumItem" or item.EnumType ~= Enum[family] or item.Name ~= name then
			return nil
		end
		items[index] = item
	end
	return items
end

local function maskFromFlags(value, names)
	local mask = 0
	for index, name in names do
		local flag = value[name]
		if type(flag) ~= "boolean" then return nil end
		if flag then mask += 2 ^ (index - 1) end
	end
	return mask
end

local function makeAxesFromItems(items)
	return makeAxes(items)
end

local function makeFacesFromItems(items)
	return makeFaces(items)
end

local function exactUDim(value, scale, offset)
	return typeof(value) == "UDim" and sameNumber(value.Scale, scale) and value.Offset == offset
end

local function exactUDim2(value, scaleX, offsetX, scaleY, offsetY)
	return typeof(value) == "UDim2" and exactUDim(value.X, scaleX, offsetX) and exactUDim(value.Y, scaleY, offsetY)
end

local function exactVector2(value, x, y)
	return typeof(value) == "Vector2" and sameNumber(value.X, x) and sameNumber(value.Y, y)
end

local function exactVector3(value, x, y, z)
	return typeof(value) == "Vector3" and sameNumber(value.X, x) and sameNumber(value.Y, y) and sameNumber(value.Z, z)
end

local function exactVector2int16(value, x, y)
	return typeof(value) == "Vector2int16" and value.X == x and value.Y == y
end

local function exactVector3int16(value, x, y, z)
	return typeof(value) == "Vector3int16" and value.X == x and value.Y == y and value.Z == z
end

local function exactNumberKeypoint(value, time, number, envelope)
	return typeof(value) == "NumberSequenceKeypoint" and sameNumber(value.Time, time)
		and sameNumber(value.Value, number) and sameNumber(value.Envelope, envelope)
end

local function exactColorKeypoint(value, time, red, green, blue)
	local color = if typeof(value) == "ColorSequenceKeypoint" then value.Value else nil
	return color ~= nil and sameNumber(value.Time, time) and sameNumber(color.R, red)
		and sameNumber(color.G, green) and sameNumber(color.B, blue)
end

local function exactColor(color, red, green, blue)
	return typeof(color) == "Color3" and sameNumber(color.R, red) and sameNumber(color.G, green)
		and sameNumber(color.B, blue)
end

local function readNumbers(state, count)
	local byteCount = count * 8
	if not hasBytes(state, byteCount) then return nil end
	local values = table.create(count)
	local offset = state.offset
	for index = 1, count do
		values[index] = buffer.readf64(state.value, offset)
		offset += 8
	end
	return values, offset
end

local function readI16s(state, count)
	local byteCount = count * 2
	if not hasBytes(state, byteCount) then return nil end
	local values = table.create(count)
	local offset = state.offset
	for index = 1, count do
		values[index] = buffer.readi16(state.value, offset)
		offset += 2
	end
	return values, offset
end

local function denseBoundedCount(values, maximum)
	if type(values) ~= "table" or getmetatable(values) ~= nil then return nil end
	local count, maximumIndex = 0, 0
	for index in values do
		count += 1
		if count > maximum or type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > maximum then
			return nil
		end
		if index > maximumIndex then maximumIndex = index end
	end
	if count == 0 or count ~= maximumIndex then return nil end
	return count
end

local function validSequenceTimes(values, count, width)
	local previous = nil
	for index = 1, count do
		local time = values[(index - 1) * width + 1]
		if not inRange(time, 0, 1) or (previous ~= nil and time <= previous) then return false end
		if index == 1 and time ~= 0 then return false end
		previous = time
	end
	return previous == 1
end

local function sequenceComponents(shape, kind, points, count)
	local width = if kind == "NumberSequence" then 3 else 4
	local components = table.create(count * width)
	for index = 1, count do
		local point = rawget(points, index)
		local base = (index - 1) * width
		if kind == "NumberSequence" then
			if typeof(point) ~= "NumberSequenceKeypoint" then return nil end
			components[base + 1] = positiveZero(point.Time)
			components[base + 2] = positiveZero(point.Value)
			components[base + 3] = positiveZero(point.Envelope)
			if not inRange(components[base + 2], shape.minimum, shape.maximum)
				or not inRange(components[base + 3], 0, shape.maximumEnvelope) then return nil end
		else
			if typeof(point) ~= "ColorSequenceKeypoint" or typeof(point.Value) ~= "Color3" then return nil end
			components[base + 1] = positiveZero(point.Time)
			components[base + 2] = positiveZero(point.Value.R)
			components[base + 3] = positiveZero(point.Value.G)
			components[base + 4] = positiveZero(point.Value.B)
			if not inRange(components[base + 2], 0, 1) or not inRange(components[base + 3], 0, 1)
				or not inRange(components[base + 4], 0, 1) then return nil end
		end
	end
	if not validSequenceTimes(components, count, width) then return nil end
	return components, width
end

local function makeSequenceFromComponents(kind, components, count, width, shape)
	local points = table.create(count)
	for index = 1, count do
		local base = (index - 1) * width
		if kind == "NumberSequence" then
			local time, number, envelope = components[base + 1], components[base + 2], components[base + 3]
			local point = protectedMake(makeNumberSequenceKeypoint, time, number, envelope)
			if point == nil or not exactNumberKeypoint(point, time, number, envelope) then return nil end
			points[index] = point
		else
			local time, red, green, blue = components[base + 1], components[base + 2], components[base + 3], components[base + 4]
			local color = protectedMake(makeColor3, red, green, blue)
			if color == nil or not exactColor(color, red, green, blue) then return nil end
			local point = protectedMake(makeColorSequenceKeypoint, time, color)
			if point == nil or not exactColorKeypoint(point, time, red, green, blue) then return nil end
			points[index] = point
		end
	end
	local sequence = protectedMake(if kind == "NumberSequence" then makeNumberSequence else makeColorSequence, points)
	if sequence == nil then return nil end
	local actual = sequence.Keypoints
	if typeof(sequence) ~= kind or denseBoundedCount(actual, shape.maximumKeypoints) ~= count then return nil end
	local actualComponents = sequenceComponents(shape, kind, actual, count)
	if actualComponents == nil then return nil end
	for index, value in components do
		if not sameNumber(value, actualComponents[index]) then return nil end
	end
	return sequence
end

local function normalize(shape, policyData, value)
	local kind: string = shape.type
	if kind == "robloxEnum" then
		if typeof(value) ~= "EnumItem" or value.EnumType ~= shape.enumType then return false end
		local allowed = policyData.byValue[value.Value]
		if allowed == nil or allowed.Name ~= value.Name then return false end
		return true, allowed, 4
	elseif kind == "UDim" then
		if typeof(value) ~= "UDim" then return false end
		local scale = positiveZero(value.Scale)
		local offset = value.Offset
		if not inRange(scale, shape.minimumScale, shape.maximumScale)
			or not integer(offset, shape.minimumOffset, shape.maximumOffset) then return false end
		local result = protectedMake(makeUDim, scale, offset)
		if not exactUDim(result, scale, offset) then return false end
		return true, result, 12
	elseif kind == "UDim2" then
		if typeof(value) ~= "UDim2" then return false end
		local x, y = value.X, value.Y
		if typeof(x) ~= "UDim" or typeof(y) ~= "UDim" then return false end
		local scaleX, scaleY = positiveZero(x.Scale), positiveZero(y.Scale)
		local offsetX, offsetY = x.Offset, y.Offset
		if not inRange(scaleX, shape.minimumScale, shape.maximumScale)
			or not inRange(scaleY, shape.minimumScale, shape.maximumScale)
			or not integer(offsetX, shape.minimumOffset, shape.maximumOffset)
			or not integer(offsetY, shape.minimumOffset, shape.maximumOffset) then return false end
		local result = protectedMake(makeUDim2, scaleX, offsetX, scaleY, offsetY)
		if not exactUDim2(result, scaleX, offsetX, scaleY, offsetY) then return false end
		return true, result, 24
	elseif kind == "NumberRange" then
		if typeof(value) ~= "NumberRange" then return false end
		local minimum, maximum = positiveZero(value.Min), positiveZero(value.Max)
		if not inRange(minimum, shape.minimum, shape.maximum) or not inRange(maximum, shape.minimum, shape.maximum)
			or minimum > maximum then return false end
		local result = protectedMake(makeNumberRange, minimum, maximum)
		if typeof(result) ~= "NumberRange" or not sameNumber(result.Min, minimum) or not sameNumber(result.Max, maximum) then return false end
		return true, result, 16
	elseif kind == "Rect" then
		if typeof(value) ~= "Rect" then return false end
		local minimum, maximum = value.Min, value.Max
		if typeof(minimum) ~= "Vector2" or typeof(maximum) ~= "Vector2" then return false end
		local minX, minY = positiveZero(minimum.X), positiveZero(minimum.Y)
		local maxX, maxY = positiveZero(maximum.X), positiveZero(maximum.Y)
		if not inRange(minX, shape.minimum, shape.maximum) or not inRange(minY, shape.minimum, shape.maximum)
			or not inRange(maxX, shape.minimum, shape.maximum) or not inRange(maxY, shape.minimum, shape.maximum)
			or minX > maxX or minY > maxY then return false end
		local minVector = protectedMake(makeVector2, minX, minY)
		local maxVector = protectedMake(makeVector2, maxX, maxY)
		if not exactVector2(minVector, minX, minY) or not exactVector2(maxVector, maxX, maxY) then return false end
		local result = protectedMake(makeRect, minVector, maxVector)
		if typeof(result) ~= "Rect" or not exactVector2(result.Min, minX, minY) or not exactVector2(result.Max, maxX, maxY) then return false end
		return true, result, 32
	elseif kind == "BrickColor" then
		if typeof(value) ~= "BrickColor" then return false end
		local color = policyData[value.Number]
		if color == nil then return false end
		return true, color, 2
	elseif kind == "Vector2int16" then
		if typeof(value) ~= "Vector2int16" then return false end
		local x, y = value.X, value.Y
		if not integer(x, shape.minimum, shape.maximum) or not integer(y, shape.minimum, shape.maximum) then return false end
		local result = protectedMake(makeVector2int16, x, y)
		if not exactVector2int16(result, x, y) then return false end
		return true, result, 4
	elseif kind == "Vector3int16" then
		if typeof(value) ~= "Vector3int16" then return false end
		local x, y, z = value.X, value.Y, value.Z
		if not integer(x, shape.minimum, shape.maximum) or not integer(y, shape.minimum, shape.maximum)
			or not integer(z, shape.minimum, shape.maximum) then return false end
		local result = protectedMake(makeVector3int16, x, y, z)
		if not exactVector3int16(result, x, y, z) then return false end
		return true, result, 6
	elseif kind == "Color3RGB8" then
		if typeof(value) ~= "Color3" then return false end
		local red, green, blue = value.R, value.G, value.B
		if not inRange(red, 0, 1) or not inRange(green, 0, 1) or not inRange(blue, 0, 1) then return false end
		local redCode, greenCode, blueCode = color3RGB8Byte(red), color3RGB8Byte(green), color3RGB8Byte(blue)
		local result = makeColor3RGB8(redCode, greenCode, blueCode)
		if result == nil or math.abs(red - result.R) > COLOR3_RGB8_MAXIMUM_ERROR
			or math.abs(green - result.G) > COLOR3_RGB8_MAXIMUM_ERROR
			or math.abs(blue - result.B) > COLOR3_RGB8_MAXIMUM_ERROR then return false end
		return true, result, 3
	elseif kind == "NumberSequence" or kind == "ColorSequence" then
		if typeof(value) ~= kind then return false end
		local points = value.Keypoints
		local count = denseBoundedCount(points, shape.maximumKeypoints)
		if count == nil or count < 2 then return false end
		local components, width = sequenceComponents(shape, kind, points, count)
		if components == nil then return false end
		local result = makeSequenceFromComponents(kind, components, count, width, shape)
		if result == nil then return false end
		return true, result, 1 + count * width * 8
	elseif kind == "NumberSequenceKeypoint" then
		if typeof(value) ~= kind then return false end
		local time, number, envelope = positiveZero(value.Time), positiveZero(value.Value), positiveZero(value.Envelope)
		if not inRange(time, 0, 1) or not inRange(number, shape.minimum, shape.maximum)
			or not inRange(envelope, 0, shape.maximumEnvelope) then return false end
		local result = protectedMake(makeNumberSequenceKeypoint, time, number, envelope)
		if not exactNumberKeypoint(result, time, number, envelope) then return false end
		return true, result, 24
	elseif kind == "ColorSequenceKeypoint" then
		if typeof(value) ~= kind or typeof(value.Value) ~= "Color3" then return false end
		local time = positiveZero(value.Time)
		local red, green, blue = positiveZero(value.Value.R), positiveZero(value.Value.G), positiveZero(value.Value.B)
		if not inRange(time, 0, 1) or not inRange(red, 0, 1) or not inRange(green, 0, 1)
			or not inRange(blue, 0, 1) then return false end
		local color = protectedMake(makeColor3, red, green, blue)
		if not exactColor(color, red, green, blue) then return false end
		local result = protectedMake(makeColorSequenceKeypoint, time, color)
		if not exactColorKeypoint(result, time, red, green, blue) then return false end
		return true, result, 32
	elseif kind == "TweenInfo" then
		if typeof(value) ~= kind then return false end
		local time, delayTime = positiveZero(value.Time), positiveZero(value.DelayTime)
		local repeatCount, reverses = value.RepeatCount, value.Reverses
		local style = validPolicyItem(policyData.EasingStyle, value.EasingStyle)
		local direction = validPolicyItem(policyData.EasingDirection, value.EasingDirection)
		if not inRange(time, 0, shape.maximumTime) or not inRange(delayTime, 0, shape.maximumDelayTime)
			or not integer(repeatCount, if shape.allowInfiniteRepeat then -1 else 0, shape.maximumRepeatCount)
			or (repeatCount == -1 and not shape.allowInfiniteRepeat) or type(reverses) ~= "boolean"
			or style == nil or direction == nil then return false end
		local result = protectedMake(makeTweenInfo, time, style, direction, repeatCount, reverses, delayTime)
		if typeof(result) ~= kind or not sameNumber(result.Time, time) or not sameNumber(result.DelayTime, delayTime)
			or result.RepeatCount ~= repeatCount or result.Reverses ~= reverses
			or validPolicyItem(policyData.EasingStyle, result.EasingStyle) ~= style
			or validPolicyItem(policyData.EasingDirection, result.EasingDirection) ~= direction then return false end
		return true, result, 29
	elseif kind == "DateTime" then
		if typeof(value) ~= kind then return false end
		local milliseconds = value.UnixTimestampMillis
		if not integer(milliseconds, shape.minimum, shape.maximum) then return false end
		local result = protectedMake(makeDateTime, milliseconds)
		if typeof(result) ~= kind or result.UnixTimestampMillis ~= milliseconds then return false end
		return true, result, 8
	elseif kind == "Ray" then
		if typeof(value) ~= kind or typeof(value.Origin) ~= "Vector3" or typeof(value.Direction) ~= "Vector3" then return false end
		local ox, oy, oz = positiveZero(value.Origin.X), positiveZero(value.Origin.Y), positiveZero(value.Origin.Z)
		local dx, dy, dz = positiveZero(value.Direction.X), positiveZero(value.Direction.Y), positiveZero(value.Direction.Z)
		if not vector3WithinOrigin(shape, ox, oy, oz)
			or not directionWithinMagnitude(dx, dy, dz, shape.maximumDirectionMagnitude) then return false end
		local origin = protectedMake(makeVector3, ox, oy, oz)
		local direction = protectedMake(makeVector3, dx, dy, dz)
		if not exactVector3(origin, ox, oy, oz) or not exactVector3(direction, dx, dy, dz) then return false end
		local result = protectedMake(makeRay, origin, direction)
		if typeof(result) ~= kind or not exactVector3(result.Origin, ox, oy, oz)
			or not exactVector3(result.Direction, dx, dy, dz) then return false end
		return true, result, 48
	elseif kind == "Axes" or kind == "Faces" then
		if typeof(value) ~= kind then return false end
		local names = if kind == "Axes" then AXIS_NAMES else FACE_NAMES
		local mask = maskFromFlags(value, names)
		if mask == nil then return false end
		return true, value, 1
	elseif kind == "Region3" then
		if typeof(value) ~= kind or typeof(value.CFrame) ~= "CFrame" or typeof(value.Size) ~= "Vector3" then return false end
		local center = value.CFrame.Position
		local size = value.Size
		local cx, cy, cz = positiveZero(center.X), positiveZero(center.Y), positiveZero(center.Z)
		local sx, sy, sz = positiveZero(size.X), positiveZero(size.Y), positiveZero(size.Z)
		local minX, minY, minZ = cx - sx / 2, cy - sy / 2, cz - sz / 2
		local maxX, maxY, maxZ = cx + sx / 2, cy + sy / 2, cz + sz / 2
		if not finite(minX) or not finite(minY) or not finite(minZ) or not finite(maxX) or not finite(maxY) or not finite(maxZ)
			or not vector3WithinOrigin(shape, minX, minY, minZ) or not vector3WithinOrigin(shape, maxX, maxY, maxZ) then return false end
		local minimum = protectedMake(makeVector3, minX, minY, minZ)
		local maximum = protectedMake(makeVector3, maxX, maxY, maxZ)
		if not exactVector3(minimum, minX, minY, minZ) or not exactVector3(maximum, maxX, maxY, maxZ) then return false end
		local result = protectedMake(makeRegion3, minimum, maximum)
		if typeof(result) ~= kind or typeof(result.CFrame) ~= "CFrame" or typeof(result.Size) ~= "Vector3"
			or not exactVector3(result.CFrame.Position, cx, cy, cz) or not exactVector3(result.Size, sx, sy, sz) then return false end
		return true, result, 48
	elseif kind == "Region3int16" then
		if typeof(value) ~= kind then return false end
		local minimum, maximum = value.Min, value.Max
		if typeof(minimum) ~= "Vector3int16" or typeof(maximum) ~= "Vector3int16" then return false end
		local minX, minY, minZ = minimum.X, minimum.Y, minimum.Z
		local maxX, maxY, maxZ = maximum.X, maximum.Y, maximum.Z
		if not integer(minX, shape.minimum, shape.maximum) or not integer(minY, shape.minimum, shape.maximum)
			or not integer(minZ, shape.minimum, shape.maximum) or not integer(maxX, shape.minimum, shape.maximum)
			or not integer(maxY, shape.minimum, shape.maximum) or not integer(maxZ, shape.minimum, shape.maximum) then return false end
		local minVector = protectedMake(makeVector3int16, minX, minY, minZ)
		local maxVector = protectedMake(makeVector3int16, maxX, maxY, maxZ)
		if not exactVector3int16(minVector, minX, minY, minZ) or not exactVector3int16(maxVector, maxX, maxY, maxZ) then return false end
		local result = protectedMake(makeRegion3int16, minVector, maxVector)
		if typeof(result) ~= kind or not exactVector3int16(result.Min, minX, minY, minZ)
			or not exactVector3int16(result.Max, maxX, maxY, maxZ) then return false end
		return true, result, 12
	elseif kind == "PhysicalProperties" then
		if typeof(value) ~= kind then return false end
		local density = positiveZero(value.Density)
		local friction = positiveZero(value.Friction)
		local elasticity = positiveZero(value.Elasticity)
		local frictionWeight = positiveZero(value.FrictionWeight)
		local elasticityWeight = positiveZero(value.ElasticityWeight)
		local absorption = positiveZero(value.AcousticAbsorption)
		if not inRange(density, MINIMUM_PHYSICAL_DENSITY, 100) or not inRange(friction, 0, 2)
			or not inRange(elasticity, 0, 1) or not inRange(frictionWeight, 0, 100)
			or not inRange(elasticityWeight, 0, 100) or not inRange(absorption, 0, 1) then return false end
		local result = protectedMake(makePhysicalProperties, density, friction, elasticity, frictionWeight, elasticityWeight, absorption)
		if typeof(result) ~= kind or not sameNumber(result.Density, density) or not sameNumber(result.Friction, friction)
			or not sameNumber(result.Elasticity, elasticity) or not sameNumber(result.FrictionWeight, frictionWeight)
			or not sameNumber(result.ElasticityWeight, elasticityWeight)
			or not sameNumber(result.AcousticAbsorption, absorption) then return false end
		return true, result, 48
	elseif kind == "Font" then
		if typeof(value) ~= kind then return false end
		local family = value.Family
		local familyOrdinal = if type(family) == "string" then policyData.familyOrdinals[family] else nil
		local weight = validPolicyItem(policyData.FontWeight, value.Weight)
		local style = validPolicyItem(policyData.FontStyle, value.Style)
		if familyOrdinal == nil or weight == nil or style == nil then return false end
		local result = protectedMake(makeFont, family, weight, style)
		if typeof(result) ~= kind or result.Family ~= family or validPolicyItem(policyData.FontWeight, result.Weight) ~= weight
			or validPolicyItem(policyData.FontStyle, result.Style) ~= style then return false end
		return true, result, 9
	elseif kind == "PathWaypoint" then
		if typeof(value) ~= kind or typeof(value.Position) ~= "Vector3" then return false end
		local position = value.Position
		local x, y, z = positiveZero(position.X), positiveZero(position.Y), positiveZero(position.Z)
		local action = validPolicyItem(policyData.PathWaypointAction, value.Action)
		local label = value.Label
		if not vector3WithinOrigin(shape, x, y, z) or action == nil or type(label) ~= "string"
			or #label > shape.maximumLabelBytes then return false end
		local ownedPosition = protectedMake(makeVector3, x, y, z)
		if not exactVector3(ownedPosition, x, y, z) then return false end
		local result = protectedMake(makePathWaypoint, ownedPosition, action, label)
		if typeof(result) ~= kind or not exactVector3(result.Position, x, y, z)
			or validPolicyItem(policyData.PathWaypointAction, result.Action) ~= action or result.Label ~= label then return false end
		return true, result, 30 + #label
	end
	return false
end

local function decode(shape, policyData, state)
	local kind: string = shape.type
	local fixedBytes = FIXED_BYTES[kind]
	if fixedBytes ~= nil and not hasBytes(state, fixedBytes) then return false end
	local offset = state.offset
	if kind == "robloxEnum" then
		local number = buffer.readi32(state.value, offset)
		local item = policyData.byValue[number]
		if item == nil then return false end
		state.offset = offset + 4
		return true, item
	elseif kind == "UDim" then
		local scale = positiveZero(buffer.readf64(state.value, offset))
		local componentOffset = buffer.readi32(state.value, offset + 8)
		if not inRange(scale, shape.minimumScale, shape.maximumScale)
			or not integer(componentOffset, shape.minimumOffset, shape.maximumOffset) then return false end
		local value = protectedMake(makeUDim, scale, componentOffset)
		if not exactUDim(value, scale, componentOffset) then return false end
		state.offset = offset + 12
		return true, value
	elseif kind == "UDim2" then
		local scaleX = positiveZero(buffer.readf64(state.value, offset))
		local scaleY = positiveZero(buffer.readf64(state.value, offset + 12))
		local offsetX = buffer.readi32(state.value, offset + 8)
		local offsetY = buffer.readi32(state.value, offset + 20)
		if not inRange(scaleX, shape.minimumScale, shape.maximumScale)
			or not inRange(scaleY, shape.minimumScale, shape.maximumScale)
			or not integer(offsetX, shape.minimumOffset, shape.maximumOffset)
			or not integer(offsetY, shape.minimumOffset, shape.maximumOffset) then return false end
		local value = protectedMake(makeUDim2, scaleX, offsetX, scaleY, offsetY)
		if not exactUDim2(value, scaleX, offsetX, scaleY, offsetY) then return false end
		state.offset = offset + 24
		return true, value
	elseif kind == "NumberRange" then
		local values, nextOffset = readNumbers(state, 2)
		if values == nil then return false end
		local minimum, maximum = positiveZero(values[1]), positiveZero(values[2])
		if not inRange(minimum, shape.minimum, shape.maximum) or not inRange(maximum, shape.minimum, shape.maximum)
			or minimum > maximum then return false end
		local value = protectedMake(makeNumberRange, minimum, maximum)
		if typeof(value) ~= kind or not sameNumber(value.Min, minimum) or not sameNumber(value.Max, maximum) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "Rect" then
		local values, nextOffset = readNumbers(state, 4)
		if values == nil then return false end
		local minX, minY, maxX, maxY = positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3]), positiveZero(values[4])
		if not inRange(minX, shape.minimum, shape.maximum) or not inRange(minY, shape.minimum, shape.maximum)
			or not inRange(maxX, shape.minimum, shape.maximum) or not inRange(maxY, shape.minimum, shape.maximum)
			or minX > maxX or minY > maxY then return false end
		local minVector = protectedMake(makeVector2, minX, minY)
		local maxVector = protectedMake(makeVector2, maxX, maxY)
		if not exactVector2(minVector, minX, minY) or not exactVector2(maxVector, maxX, maxY) then return false end
		local value = protectedMake(makeRect, minVector, maxVector)
		if typeof(value) ~= kind or not exactVector2(value.Min, minX, minY) or not exactVector2(value.Max, maxX, maxY) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "BrickColor" then
		local number = buffer.readu16(state.value, offset)
		local color = policyData[number]
		if color == nil then return false end
		state.offset = offset + 2
		return true, color
	elseif kind == "Vector2int16" then
		local values, nextOffset = readI16s(state, 2)
		if values == nil then return false end
		local x, y = values[1], values[2]
		if not integer(x, shape.minimum, shape.maximum) or not integer(y, shape.minimum, shape.maximum) then return false end
		local value = protectedMake(makeVector2int16, x, y)
		if not exactVector2int16(value, x, y) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "Vector3int16" then
		local values, nextOffset = readI16s(state, 3)
		if values == nil then return false end
		local x, y, z = values[1], values[2], values[3]
		if not integer(x, shape.minimum, shape.maximum) or not integer(y, shape.minimum, shape.maximum)
			or not integer(z, shape.minimum, shape.maximum) then return false end
		local value = protectedMake(makeVector3int16, x, y, z)
		if not exactVector3int16(value, x, y, z) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "Color3RGB8" then
		local red, green, blue = buffer.readu8(state.value, offset), buffer.readu8(state.value, offset + 1),
			buffer.readu8(state.value, offset + 2)
		local value = makeColor3RGB8(red, green, blue)
		if value == nil then return false end
		state.offset = offset + 3
		return true, value
	elseif kind == "NumberSequenceKeypoint" then
		local values = readNumbers(state, 3)
		if values == nil then return false end
		local time, number, envelope = positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3])
		if not inRange(time, 0, 1) or not inRange(number, shape.minimum, shape.maximum)
			or not inRange(envelope, 0, shape.maximumEnvelope) then return false end
		local value = protectedMake(makeNumberSequenceKeypoint, time, number, envelope)
		if not exactNumberKeypoint(value, time, number, envelope) then return false end
		state.offset = offset + 24
		return true, value
	elseif kind == "ColorSequenceKeypoint" then
		local values = readNumbers(state, 4)
		if values == nil then return false end
		local time, red, green, blue = positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3]), positiveZero(values[4])
		if not inRange(time, 0, 1) or not inRange(red, 0, 1) or not inRange(green, 0, 1)
			or not inRange(blue, 0, 1) then return false end
		local color = protectedMake(makeColor3, red, green, blue)
		if not exactColor(color, red, green, blue) then return false end
		local value = protectedMake(makeColorSequenceKeypoint, time, color)
		if not exactColorKeypoint(value, time, red, green, blue) then return false end
		state.offset = offset + 32
		return true, value
	elseif kind == "NumberSequence" or kind == "ColorSequence" then
		if not hasBytes(state, 1) then return false end
		local count = buffer.readu8(state.value, offset)
		local width = if kind == "NumberSequence" then 3 else 4
		local maximumKeypoints = shape.maximumKeypoints
		if count < 2 or count > maximumKeypoints or count * width * 8 > state.length - (offset + 1) then return false end
		local components = table.create(count * width)
		local readOffset = offset + 1
		for index = 1, count * width do
			components[index] = positiveZero(buffer.readf64(state.value, readOffset))
			readOffset += 8
		end
		if not validSequenceTimes(components, count, width) then return false end
		for index = 1, count do
			local base = (index - 1) * width
			if kind == "NumberSequence" then
				if not inRange(components[base + 2], shape.minimum, shape.maximum)
					or not inRange(components[base + 3], 0, shape.maximumEnvelope) then return false end
			else
				if not inRange(components[base + 2], 0, 1) or not inRange(components[base + 3], 0, 1)
					or not inRange(components[base + 4], 0, 1) then return false end
			end
		end
		local value = makeSequenceFromComponents(kind, components, count, width, shape)
		if value == nil then return false end
		state.offset = readOffset
		return true, value
	elseif kind == "TweenInfo" then
		local time = positiveZero(buffer.readf64(state.value, offset))
		local delayTime = positiveZero(buffer.readf64(state.value, offset + 8))
		local repeatCount = buffer.readi32(state.value, offset + 16)
		local reverses = buffer.readu8(state.value, offset + 20)
		local styleValue = buffer.readi32(state.value, offset + 21)
		local directionValue = buffer.readi32(state.value, offset + 25)
		local style = enumValuePolicy(policyData.EasingStyle, styleValue)
		local direction = enumValuePolicy(policyData.EasingDirection, directionValue)
		if not inRange(time, 0, shape.maximumTime) or not inRange(delayTime, 0, shape.maximumDelayTime)
			or not integer(repeatCount, if shape.allowInfiniteRepeat then -1 else 0, shape.maximumRepeatCount)
			or (repeatCount == -1 and not shape.allowInfiniteRepeat) or reverses > 1 or style == nil or direction == nil then return false end
		local value = protectedMake(makeTweenInfo, time, style, direction, repeatCount, reverses == 1, delayTime)
		if typeof(value) ~= kind or not sameNumber(value.Time, time) or not sameNumber(value.DelayTime, delayTime)
			or value.RepeatCount ~= repeatCount or value.Reverses ~= (reverses == 1)
			or validPolicyItem(policyData.EasingStyle, value.EasingStyle) ~= style
			or validPolicyItem(policyData.EasingDirection, value.EasingDirection) ~= direction then return false end
		state.offset = offset + 29
		return true, value
	elseif kind == "DateTime" then
		local milliseconds = buffer.readf64(state.value, offset)
		if not integer(milliseconds, shape.minimum, shape.maximum) then return false end
		local value = protectedMake(makeDateTime, milliseconds)
		if typeof(value) ~= kind or value.UnixTimestampMillis ~= milliseconds then return false end
		state.offset = offset + 8
		return true, value
	elseif kind == "Ray" then
		local values, nextOffset = readNumbers(state, 6)
		if values == nil then return false end
		local ox, oy, oz = positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3])
		local dx, dy, dz = positiveZero(values[4]), positiveZero(values[5]), positiveZero(values[6])
		if not vector3WithinOrigin(shape, ox, oy, oz)
			or not directionWithinMagnitude(dx, dy, dz, shape.maximumDirectionMagnitude) then return false end
		local origin = protectedMake(makeVector3, ox, oy, oz)
		local direction = protectedMake(makeVector3, dx, dy, dz)
		if not exactVector3(origin, ox, oy, oz) or not exactVector3(direction, dx, dy, dz) then return false end
		local value = protectedMake(makeRay, origin, direction)
		if typeof(value) ~= kind or not exactVector3(value.Origin, ox, oy, oz)
			or not exactVector3(value.Direction, dx, dy, dz) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "Axes" or kind == "Faces" then
		local mask = buffer.readu8(state.value, offset)
		local names = if kind == "Axes" then AXIS_NAMES else FACE_NAMES
		local maximumMask = if kind == "Axes" then 7 else 63
		if mask > maximumMask then return false end
		local enumItems = policyData.items
		local items = {}
		for index, item in enumItems do
			if mask % (2 ^ index) >= 2 ^ (index - 1) then items[#items + 1] = item end
		end
		local value = protectedMake(if kind == "Axes" then makeAxesFromItems else makeFacesFromItems, items)
		if typeof(value) ~= kind or maskFromFlags(value, names) ~= mask then return false end
		state.offset = offset + 1
		return true, value
	elseif kind == "Region3" then
		local values, nextOffset = readNumbers(state, 6)
		if values == nil then return false end
		local cx, cy, cz = positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3])
		local sx, sy, sz = positiveZero(values[4]), positiveZero(values[5]), positiveZero(values[6])
		local minX, minY, minZ = cx - sx / 2, cy - sy / 2, cz - sz / 2
		local maxX, maxY, maxZ = cx + sx / 2, cy + sy / 2, cz + sz / 2
		if not finite(minX) or not finite(minY) or not finite(minZ) or not finite(maxX) or not finite(maxY) or not finite(maxZ)
			or not vector3WithinOrigin(shape, minX, minY, minZ) or not vector3WithinOrigin(shape, maxX, maxY, maxZ) then return false end
		local minimum = protectedMake(makeVector3, minX, minY, minZ)
		local maximum = protectedMake(makeVector3, maxX, maxY, maxZ)
		if not exactVector3(minimum, minX, minY, minZ) or not exactVector3(maximum, maxX, maxY, maxZ) then return false end
		local value = protectedMake(makeRegion3, minimum, maximum)
		if typeof(value) ~= kind or typeof(value.CFrame) ~= "CFrame" or typeof(value.Size) ~= "Vector3"
			or not exactVector3(value.CFrame.Position, cx, cy, cz) or not exactVector3(value.Size, sx, sy, sz) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "Region3int16" then
		local values, nextOffset = readI16s(state, 6)
		if values == nil then return false end
		local minX, minY, minZ = values[1], values[2], values[3]
		local maxX, maxY, maxZ = values[4], values[5], values[6]
		if not integer(minX, shape.minimum, shape.maximum) or not integer(minY, shape.minimum, shape.maximum)
			or not integer(minZ, shape.minimum, shape.maximum) or not integer(maxX, shape.minimum, shape.maximum)
			or not integer(maxY, shape.minimum, shape.maximum) or not integer(maxZ, shape.minimum, shape.maximum) then return false end
		local minimum = protectedMake(makeVector3int16, minX, minY, minZ)
		local maximum = protectedMake(makeVector3int16, maxX, maxY, maxZ)
		if not exactVector3int16(minimum, minX, minY, minZ) or not exactVector3int16(maximum, maxX, maxY, maxZ) then return false end
		local value = protectedMake(makeRegion3int16, minimum, maximum)
		if typeof(value) ~= kind or not exactVector3int16(value.Min, minX, minY, minZ)
			or not exactVector3int16(value.Max, maxX, maxY, maxZ) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "PhysicalProperties" then
		local values, nextOffset = readNumbers(state, 6)
		if values == nil then return false end
		local density, friction, elasticity, frictionWeight, elasticityWeight, absorption =
			positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3]), positiveZero(values[4]),
			positiveZero(values[5]), positiveZero(values[6])
		if not inRange(density, MINIMUM_PHYSICAL_DENSITY, 100) or not inRange(friction, 0, 2)
			or not inRange(elasticity, 0, 1) or not inRange(frictionWeight, 0, 100)
			or not inRange(elasticityWeight, 0, 100) or not inRange(absorption, 0, 1) then return false end
		local value = protectedMake(makePhysicalProperties, density, friction, elasticity, frictionWeight, elasticityWeight, absorption)
		if typeof(value) ~= kind or not sameNumber(value.Density, density) or not sameNumber(value.Friction, friction)
			or not sameNumber(value.Elasticity, elasticity) or not sameNumber(value.FrictionWeight, frictionWeight)
			or not sameNumber(value.ElasticityWeight, elasticityWeight) or not sameNumber(value.AcousticAbsorption, absorption) then return false end
		state.offset = nextOffset
		return true, value
	elseif kind == "Font" then
		local familyOrdinal = buffer.readu8(state.value, offset)
		local weightValue = buffer.readi32(state.value, offset + 1)
		local styleValue = buffer.readi32(state.value, offset + 5)
		local family = shape.families[familyOrdinal + 1]
		local weight = enumValuePolicy(policyData.FontWeight, weightValue)
		local style = enumValuePolicy(policyData.FontStyle, styleValue)
		if family == nil or weight == nil or style == nil then return false end
		local value = protectedMake(makeFont, family, weight, style)
		if typeof(value) ~= kind or value.Family ~= family or validPolicyItem(policyData.FontWeight, value.Weight) ~= weight
			or validPolicyItem(policyData.FontStyle, value.Style) ~= style then return false end
		state.offset = offset + 9
		return true, value
	elseif kind == "PathWaypoint" then
		if not hasBytes(state, 30) then return false end
		local values, baseOffset = readNumbers(state, 3)
		if values == nil then return false end
		local x, y, z = positiveZero(values[1]), positiveZero(values[2]), positiveZero(values[3])
		local actionValue = buffer.readi32(state.value, offset + 24)
		local labelLength = buffer.readu16(state.value, offset + 28)
		local action = enumValuePolicy(policyData.PathWaypointAction, actionValue)
		if not vector3WithinOrigin(shape, x, y, z) or action == nil or labelLength > shape.maximumLabelBytes
			or not hasBytes({ offset = baseOffset + 6, length = state.length }, labelLength) then return false end
		local label = buffer.readstring(state.value, baseOffset + 6, labelLength)
		local position = protectedMake(makeVector3, x, y, z)
		if not exactVector3(position, x, y, z) then return false end
		local value = protectedMake(makePathWaypoint, position, action, label)
		if typeof(value) ~= kind or not exactVector3(value.Position, x, y, z)
			or validPolicyItem(policyData.PathWaypointAction, value.Action) ~= action or value.Label ~= label then return false end
		state.offset = baseOffset + 6 + labelLength
		return true, value
	end
	return false
end

local function write(shape, policyData, value, output: buffer, offset: number): number
	local kind: string = shape.type
	if kind == "robloxEnum" then
		buffer.writei32(output, offset, value.Value)
		return offset + 4
	elseif kind == "UDim" then
		buffer.writef64(output, offset, value.Scale)
		buffer.writei32(output, offset + 8, value.Offset)
		return offset + 12
	elseif kind == "UDim2" then
		buffer.writef64(output, offset, value.X.Scale)
		buffer.writei32(output, offset + 8, value.X.Offset)
		buffer.writef64(output, offset + 12, value.Y.Scale)
		buffer.writei32(output, offset + 20, value.Y.Offset)
		return offset + 24
	elseif kind == "NumberRange" then
		buffer.writef64(output, offset, value.Min)
		buffer.writef64(output, offset + 8, value.Max)
		return offset + 16
	elseif kind == "Rect" then
		buffer.writef64(output, offset, value.Min.X)
		buffer.writef64(output, offset + 8, value.Min.Y)
		buffer.writef64(output, offset + 16, value.Max.X)
		buffer.writef64(output, offset + 24, value.Max.Y)
		return offset + 32
	elseif kind == "BrickColor" then
		buffer.writeu16(output, offset, value.Number)
		return offset + 2
	elseif kind == "Vector2int16" then
		buffer.writei16(output, offset, value.X)
		buffer.writei16(output, offset + 2, value.Y)
		return offset + 4
	elseif kind == "Vector3int16" then
		buffer.writei16(output, offset, value.X)
		buffer.writei16(output, offset + 2, value.Y)
		buffer.writei16(output, offset + 4, value.Z)
		return offset + 6
	elseif kind == "Color3RGB8" then
		buffer.writeu8(output, offset, color3RGB8Byte(value.R))
		buffer.writeu8(output, offset + 1, color3RGB8Byte(value.G))
		buffer.writeu8(output, offset + 2, color3RGB8Byte(value.B))
		return offset + 3
	elseif kind == "NumberSequenceKeypoint" then
		buffer.writef64(output, offset, value.Time)
		buffer.writef64(output, offset + 8, value.Value)
		buffer.writef64(output, offset + 16, value.Envelope)
		return offset + 24
	elseif kind == "ColorSequenceKeypoint" then
		buffer.writef64(output, offset, value.Time)
		buffer.writef64(output, offset + 8, value.Value.R)
		buffer.writef64(output, offset + 16, value.Value.G)
		buffer.writef64(output, offset + 24, value.Value.B)
		return offset + 32
	elseif kind == "NumberSequence" or kind == "ColorSequence" then
		local points = value.Keypoints
		local count = #points
		buffer.writeu8(output, offset, count)
		offset += 1
		for _, point in points do
			if kind == "NumberSequence" then
				buffer.writef64(output, offset, point.Time)
				buffer.writef64(output, offset + 8, point.Value)
				buffer.writef64(output, offset + 16, point.Envelope)
				offset += 24
			else
				buffer.writef64(output, offset, point.Time)
				buffer.writef64(output, offset + 8, point.Value.R)
				buffer.writef64(output, offset + 16, point.Value.G)
				buffer.writef64(output, offset + 24, point.Value.B)
				offset += 32
			end
		end
		return offset
	elseif kind == "TweenInfo" then
		buffer.writef64(output, offset, value.Time)
		buffer.writef64(output, offset + 8, value.DelayTime)
		buffer.writei32(output, offset + 16, value.RepeatCount)
		buffer.writeu8(output, offset + 20, if value.Reverses then 1 else 0)
		buffer.writei32(output, offset + 21, value.EasingStyle.Value)
		buffer.writei32(output, offset + 25, value.EasingDirection.Value)
		return offset + 29
	elseif kind == "DateTime" then
		buffer.writef64(output, offset, value.UnixTimestampMillis)
		return offset + 8
	elseif kind == "Ray" then
		buffer.writef64(output, offset, value.Origin.X)
		buffer.writef64(output, offset + 8, value.Origin.Y)
		buffer.writef64(output, offset + 16, value.Origin.Z)
		buffer.writef64(output, offset + 24, value.Direction.X)
		buffer.writef64(output, offset + 32, value.Direction.Y)
		buffer.writef64(output, offset + 40, value.Direction.Z)
		return offset + 48
	elseif kind == "Axes" then
		buffer.writeu8(output, offset, maskFromFlags(value, AXIS_NAMES) :: number)
		return offset + 1
	elseif kind == "Faces" then
		buffer.writeu8(output, offset, maskFromFlags(value, FACE_NAMES) :: number)
		return offset + 1
	elseif kind == "Region3" then
		local center, size = value.CFrame.Position, value.Size
		buffer.writef64(output, offset, center.X)
		buffer.writef64(output, offset + 8, center.Y)
		buffer.writef64(output, offset + 16, center.Z)
		buffer.writef64(output, offset + 24, size.X)
		buffer.writef64(output, offset + 32, size.Y)
		buffer.writef64(output, offset + 40, size.Z)
		return offset + 48
	elseif kind == "Region3int16" then
		buffer.writei16(output, offset, value.Min.X)
		buffer.writei16(output, offset + 2, value.Min.Y)
		buffer.writei16(output, offset + 4, value.Min.Z)
		buffer.writei16(output, offset + 6, value.Max.X)
		buffer.writei16(output, offset + 8, value.Max.Y)
		buffer.writei16(output, offset + 10, value.Max.Z)
		return offset + 12
	elseif kind == "PhysicalProperties" then
		buffer.writef64(output, offset, value.Density)
		buffer.writef64(output, offset + 8, value.Friction)
		buffer.writef64(output, offset + 16, value.Elasticity)
		buffer.writef64(output, offset + 24, value.FrictionWeight)
		buffer.writef64(output, offset + 32, value.ElasticityWeight)
		buffer.writef64(output, offset + 40, value.AcousticAbsorption)
		return offset + 48
	elseif kind == "Font" then
		buffer.writeu8(output, offset, policyData.familyOrdinals[value.Family] - 1)
		buffer.writei32(output, offset + 1, value.Weight.Value)
		buffer.writei32(output, offset + 5, value.Style.Value)
		return offset + 9
	elseif kind == "PathWaypoint" then
		buffer.writef64(output, offset, value.Position.X)
		buffer.writef64(output, offset + 8, value.Position.Y)
		buffer.writef64(output, offset + 16, value.Position.Z)
		buffer.writei32(output, offset + 24, value.Action.Value)
		buffer.writeu16(output, offset + 28, #value.Label)
		buffer.writestring(output, offset + 30, value.Label, #value.Label)
		return offset + 30 + #value.Label
	end
	return offset
end

local function compile(shape)
	if type(shape) ~= "table" or shape.native ~= true or type(shape.type) ~= "string" then return nil end
	local kind: string = shape.type
	if FIXED_BYTES[kind] == nil and kind ~= "NumberSequence" and kind ~= "ColorSequence" and kind ~= "PathWaypoint" then
		return nil
	end
	local policyData
	if kind == "robloxEnum" then
		policyData = validEnumShape(shape)
	elseif kind == "BrickColor" then
		policyData = validBrickColors(shape)
	elseif kind == "TweenInfo" then
		policyData = compilePolicies(shape, { "EasingStyle", "EasingDirection" })
	elseif kind == "Font" then
		policyData = compilePolicies(shape, { "FontWeight", "FontStyle" })
		if policyData ~= nil then policyData.familyOrdinals = validFamilies(shape) end
		if policyData ~= nil and policyData.familyOrdinals == nil then policyData = nil end
	elseif kind == "PathWaypoint" then
		policyData = compilePolicies(shape, { "PathWaypointAction" })
	elseif kind == "Axes" then
		policyData = { items = makeFlagItems("Axis", AXIS_NAMES) }
		if policyData.items == nil then policyData = nil end
	elseif kind == "Faces" then
		policyData = { items = makeFlagItems("NormalId", FACE_NAMES) }
		if policyData.items == nil then policyData = nil end
	else
		policyData = {}
	end
	if policyData == nil then return nil end
	local operations = {
		normalize = function(value) return normalize(shape, policyData, value) end,
		read = function(state) return decode(shape, policyData, state) end,
		write = function(value, output, offset) return write(shape, policyData, value, output, offset) end,
	}
	return table.freeze(operations)
end

return table.freeze({ compile = compile })
