local MAXIMUM_F64 = 1.7976931348623157e308

local FORMATS = table.freeze({
	f16 = table.freeze({ exponentBits = 5, fractionBits = 10, bias = 15, minimumExponent = -14,
		maximumExponent = 15, maximum = 65_504, width = 2 }),
	f24 = table.freeze({ exponentBits = 6, fractionBits = 17, bias = 31, minimumExponent = -30,
		maximumExponent = 31, maximum = 4_294_950_912, width = 3 }),
	f64 = table.freeze({ width = 8, maximum = MAXIMUM_F64 }),
})

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function normalizeZero(value)
	return if value == 0 then 0 else value
end

local function roundEven(value)
	local lower = math.floor(value)
	local fraction = value - lower
	if fraction > 0.5 or (fraction == 0.5 and lower % 2 == 1) then return lower + 1 end
	return lower
end

local function encodeBits(format, value)
	local magnitude = math.abs(value)
	if magnitude == 0 then return 0 end
	local fractionLimit = 2 ^ format.fractionBits
	local mantissa, exponent = math.frexp(magnitude)
	local unbiased = exponent - 1
	local encodedExponent, fraction
	if unbiased < format.minimumExponent then
		local quantum = 2 ^ (format.minimumExponent - format.fractionBits)
		local code = roundEven(magnitude / quantum)
		if code == 0 then
			encodedExponent, fraction = 0, 0
		elseif code >= fractionLimit then
			encodedExponent, fraction = 1, 0
		else
			encodedExponent, fraction = 0, code
		end
	else
		fraction = roundEven((mantissa * 2 - 1) * fractionLimit)
		if fraction == fractionLimit then
			unbiased += 1
			fraction = 0
		end
		if unbiased > format.maximumExponent then return nil end
		encodedExponent = unbiased + format.bias
	end
	if encodedExponent == 0 and fraction == 0 then return 0 end
	local sign = if value < 0 then 1 else 0
	return sign * 2 ^ (format.exponentBits + format.fractionBits)
		+ encodedExponent * fractionLimit + fraction
end

local function decodeBits(format, bits)
	local fractionLimit = 2 ^ format.fractionBits
	local signScale = 2 ^ (format.exponentBits + format.fractionBits)
	local sign = math.floor(bits / signScale)
	local magnitudeBits = bits % signScale
	local exponent = math.floor(magnitudeBits / fractionLimit)
	local fraction = magnitudeBits % fractionLimit
	local reservedExponent = 2 ^ format.exponentBits - 1
	if exponent == reservedExponent or (sign == 1 and exponent == 0 and fraction == 0) then return nil end
	local magnitude
	if exponent == 0 then
		magnitude = math.ldexp(fraction, format.minimumExponent - format.fractionBits)
	else
		magnitude = math.ldexp(1 + fraction / fractionLimit, exponent - format.bias)
	end
	local value = if sign == 1 then -magnitude else magnitude
	return if finite(value) then normalizeZero(value) else nil
end

local function schema(fieldType, minimum, maximum)
	local format = FORMATS[fieldType]
	if format == nil then return nil, "type", "unsupported compact numeric format" end
	if not finite(minimum) then return nil, "minimum", "must be a finite number" end
	if not finite(maximum) then return nil, "maximum", "must be a finite number" end
	minimum, maximum = normalizeZero(minimum), normalizeZero(maximum)
	if minimum < -format.maximum or minimum > format.maximum then
		return nil, "minimum", "must be within the finite format range"
	elseif maximum < -format.maximum or maximum > format.maximum then
		return nil, "maximum", "must be within the finite format range"
	elseif minimum > maximum then
		return nil, "maximum", "must be greater than or equal to minimum"
	end
	return { type = fieldType, minimum = minimum, maximum = maximum, width = format.width,
		maximumError = if fieldType == "f64" then 0
			else 2 ^ (format.maximumExponent - format.fractionBits - 1),
		minimumEncodedBytes = format.width, maximumEncodedBytes = format.width,
		maximumDepth = 0, maximumElements = 1 }
end

local function compile(shape)
	local fieldType = shape.type
	local format = FORMATS[fieldType]
	if format == nil or not finite(shape.minimum) or not finite(shape.maximum)
		or shape.minimum < -format.maximum or shape.maximum > format.maximum
		or shape.minimum > shape.maximum then return nil end

	local function normalize(value)
		if not finite(value) or value < shape.minimum or value > shape.maximum then return false end
		value = normalizeZero(value)
		if fieldType == "f64" then return true, value, format.width end
		local bits = encodeBits(format, value)
		if bits == nil then return false end
		local rounded = decodeBits(format, bits)
		if rounded == nil or rounded < shape.minimum or rounded > shape.maximum then return false end
		return true, rounded, format.width
	end

	local function read(state)
		local offset, length = state.offset, state.length
		if offset < 0 or length < 0 or offset > length - format.width then return false end
		local value
		if fieldType == "f64" then
			value = buffer.readf64(state.value, offset)
			if not finite(value) or (value == 0 and 1 / value == -math.huge) then return false end
			value = normalizeZero(value)
		else
			local bits
			if format.width == 2 then
				bits = buffer.readu16(state.value, offset)
			else
				bits = buffer.readu8(state.value, offset)
				bits += buffer.readu8(state.value, offset + 1) * 256
				bits += buffer.readu8(state.value, offset + 2) * 65_536
			end
			value = decodeBits(format, bits)
			if value == nil then return false end
		end
		if value < shape.minimum or value > shape.maximum then return false end
		state.offset = offset + format.width
		return true, value
	end

	local function write(value, output, offset)
		if fieldType == "f64" then
			buffer.writef64(output, offset, normalizeZero(value))
		elseif format.width == 2 then
			local bits = encodeBits(format, value)
			if bits == nil then return offset end
			buffer.writeu16(output, offset, bits)
		else
			local bits = encodeBits(format, value)
			if bits == nil then return offset end
			buffer.writeu8(output, offset, bits % 256)
			buffer.writeu8(output, offset + 1, math.floor(bits / 256) % 256)
			buffer.writeu8(output, offset + 2, math.floor(bits / 65_536) % 256)
		end
		return offset + format.width
	end

	return table.freeze({ normalize = normalize, read = read, write = write })
end

return table.freeze({ formats = FORMATS, schema = schema, compile = compile })
