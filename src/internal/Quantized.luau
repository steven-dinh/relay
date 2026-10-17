local MAXIMUM_LEVELS = 65_536
local MINIMUM_STEP = 2 ^ -974
local EPSILON = 2 ^ -52

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function canonicalZero(value)
	return if value == 0 then 0 else value
end

local function exactFloatToken(value)
	local bytes = buffer.create(8)
	buffer.writef64(bytes, 0, canonicalZero(value))
	return string.format("%08x%08x", buffer.readu32(bytes, 4), buffer.readu32(bytes, 0))
end

local function decodeIndex(minimum, maximum, step, maximumIndex, maximumError, value)
	if not finite(value) or value < minimum or value > maximum then return nil end
	if value == minimum then return 0 end
	if value == maximum then return maximumIndex end

	local position = (value - minimum) / step
	if not finite(position) then return nil end
	local lower = math.floor(position)
	local index = lower + (if position - lower >= 0.5 then 1 else 0)
	if index < 0 or index > maximumIndex then return nil end

	local decoded
	if index == 0 then
		decoded = minimum
	elseif index == maximumIndex then
		decoded = maximum
	else
		decoded = canonicalZero(minimum + index * step)
	end
	if not finite(decoded) or decoded < minimum or decoded > maximum or math.abs(decoded - value) > maximumError then
		return nil
	end
	return index
end

local function schema(source)
	if type(source) ~= "table" then return nil, "", "must be a shape table" end
	local minimum, maximum, step = rawget(source, "minimum"), rawget(source, "maximum"), rawget(source, "step")
	if not finite(minimum) then return nil, ".minimum", "must be a finite number" end
	if not finite(maximum) then return nil, ".maximum", "must be a finite number" end
	if not finite(step) or step < MINIMUM_STEP then
		return nil, ".step", "must be a finite number at least 2^-974"
	end
	minimum, maximum = canonicalZero(minimum), canonicalZero(maximum)
	if minimum >= maximum then return nil, ".maximum", "must be greater than minimum" end

	local span = maximum - minimum
	if not finite(span) or span <= 0 then return nil, ".maximum", "range span must be finite and positive" end
	local quotient = span / step
	if not finite(quotient) then return nil, ".step", "range contains too many quantization levels" end
	local lower = math.floor(quotient)
	local maximumIndex = lower + (if quotient - lower >= 0.5 then 1 else 0)
	if maximumIndex < 1 or maximumIndex >= MAXIMUM_LEVELS then
		return nil, ".step", "range must contain 1 to 65535 quantization intervals"
	end

	local scale = math.max(math.abs(minimum), math.abs(maximum), step)
	local roundoffAllowance = 16 * EPSILON * scale
	if not finite(roundoffAllowance) or roundoffAllowance <= 0 or roundoffAllowance > step / 16 then
		return nil, ".step", "step is too small relative to the numeric range"
	end
	local nominalSpan = maximumIndex * step
	if not finite(nominalSpan) or math.abs(span - nominalSpan) > roundoffAllowance then
		return nil, ".maximum", "range endpoints do not align to the step within binary64 roundoff"
	end
	local maximumError = step / 2 + roundoffAllowance
	if not finite(maximumError) or maximumError <= 0 then
		return nil, ".step", "maximum quantization error must be finite and positive"
	end
	local width = if maximumIndex <= 255 then 1 else 2
	local descriptorToken = "Q1," .. exactFloatToken(minimum) .. "," .. exactFloatToken(maximum)
		.. "," .. exactFloatToken(step) .. "," .. tostring(maximumIndex) .. "," .. tostring(width)

	return {
		type = "quantized",
		minimum = minimum,
		maximum = maximum,
		step = step,
		maximumIndex = maximumIndex,
		width = width,
		roundoffAllowance = roundoffAllowance,
		maximumError = maximumError,
		minimumEncodedBytes = width,
		maximumEncodedBytes = width,
		maximumDepth = 0,
		maximumElements = 1,
		descriptorToken = descriptorToken,
	}
end

local function compile(shape)
	if type(shape) ~= "table" or shape.type ~= "quantized" then return nil end
	local minimum, maximum, step = shape.minimum, shape.maximum, shape.step
	local maximumIndex, width = shape.maximumIndex, shape.width
	local maximumError = shape.maximumError
	if not finite(minimum) or not finite(maximum) or not finite(step) or not finite(maximumError)
		or not finite(maximumIndex) or maximumIndex % 1 ~= 0 or maximumIndex < 1 or maximumIndex >= MAXIMUM_LEVELS
		or (width ~= 1 and width ~= 2) or width ~= if maximumIndex <= 255 then 1 else 2 then
		return nil
	end

	local function indexFor(value)
		return decodeIndex(minimum, maximum, step, maximumIndex, maximumError, value)
	end
	local function decodedValue(index)
		if index == 0 then return minimum end
		if index == maximumIndex then return maximum end
		local value = canonicalZero(minimum + index * step)
		if finite(value) and value >= minimum and value <= maximum then return value end
		return nil
	end
	local function stable(index)
		local value = decodedValue(index)
		return if value ~= nil and indexFor(value) == index then value else nil
	end

	return table.freeze({
		normalize = function(value)
			local index = indexFor(value)
			if index == nil then return false end
			local normalized = stable(index)
			if normalized == nil or math.abs(normalized - value) > maximumError then return false end
			return true, normalized, width
		end,
		read = function(state)
			local offset, length = state.offset, state.length
			if offset < 0 or length < 0 or offset > length - width then return false end
			local index = if width == 1 then buffer.readu8(state.value, offset) else buffer.readu16(state.value, offset)
			if index > maximumIndex then return false end
			local value = stable(index)
			if value == nil then return false end
			state.offset = offset + width
			return true, value
		end,
		write = function(value, output, offset)
			local index = indexFor(value)
			if index == nil or stable(index) ~= value then return offset end
			if width == 1 then
				buffer.writeu8(output, offset, index)
			else
				buffer.writeu16(output, offset, index)
			end
			return offset + width
		end,
	})
end

return table.freeze({
	MAXIMUM_LEVELS = MAXIMUM_LEVELS,
	MINIMUM_STEP = MINIMUM_STEP,
	schema = schema,
	compile = compile,
})
