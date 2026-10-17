local Quantized = require(if script then script.Parent.Quantized else "./Quantized")

local ROTATION_ERROR = 0.002
local RIGID_TOLERANCE = 1e-6
local TWO_PI = 2 * math.pi
local ANGLE_DELTA = TWO_PI / 65_536

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function canonicalZero(value)
	return if value == 0 then 0 else value
end

local function exactFloat32(value)
	local bytes = buffer.create(4)
	buffer.writef32(bytes, 0, value)
	local rounded = buffer.readf32(bytes, 0)
	return finite(rounded) and rounded == value
end

local function scalarShape(source, stepKey)
	local minimum, maximum, step = rawget(source, "minimum"), rawget(source, "maximum"), rawget(source, stepKey)
	if not finite(minimum) then return nil, ".minimum", "must be a finite number" end
	if not finite(maximum) then return nil, ".maximum", "must be a finite number" end
	if not finite(step) then return nil, "." .. stepKey, "must be a finite number" end
	minimum, maximum = canonicalZero(minimum), canonicalZero(maximum)
	if not exactFloat32(minimum) then return nil, ".minimum", "must be exactly representable as a finite Float32" end
	if not exactFloat32(maximum) then return nil, ".maximum", "must be exactly representable as a finite Float32" end
	local scalar, suffix, reason = Quantized.schema({ type = "quantized", minimum = minimum, maximum = maximum, step = step })
	if scalar == nil then
		if stepKey ~= "step" and suffix == ".step" then suffix = "." .. stepKey end
		return nil, suffix, reason
	end
	return scalar
end

local function nativeAllowance(scalar)
	local scale = math.max(math.abs(scalar.minimum), math.abs(scalar.maximum), scalar.step)
	local allowance = math.max(2 ^ -126, 2 ^ -23 * scale)
	if not finite(allowance) or allowance > scalar.step / 16 then return nil end
	return allowance
end

local function scalarDescriptor(kind, scalar)
	return kind .. "," .. Quantized.numberToken(scalar.minimum) .. "," .. Quantized.numberToken(scalar.maximum)
		.. "," .. Quantized.numberToken(scalar.step) .. "," .. tostring(scalar.maximumIndex) .. "," .. tostring(scalar.width)
end

local function schema(source)
	if type(source) ~= "table" then return nil, "", "must be a shape table" end
	local kind = rawget(source, "type")
	if kind == "quantizedVector3" or kind == "quantizedVector2" then
		local scalar, suffix, reason = scalarShape(source, "step")
		if scalar == nil then return nil, suffix, reason end
		local allowance = nativeAllowance(scalar)
		if allowance == nil then return nil, ".step", "step is too small for native vector precision" end
		local dimensions = if kind == "quantizedVector3" then 3 else 2
		return {
			type = kind,
			containsCodec = true,
			minimum = scalar.minimum,
			maximum = scalar.maximum,
			step = scalar.step,
			maximumIndex = scalar.maximumIndex,
			scalarWidth = scalar.width,
			width = dimensions * scalar.width,
			nativeAllowance = allowance,
			maximumComponentError = scalar.maximumError + allowance,
			minimumEncodedBytes = dimensions * scalar.width,
			maximumEncodedBytes = dimensions * scalar.width,
			maximumDepth = 0,
			maximumElements = 1,
			descriptorToken = "VQ1," .. scalarDescriptor(if dimensions == 3 then "Vector3" else "Vector2", scalar),
		}
	elseif kind == "compactCFrame" then
		local scalar, suffix, reason = scalarShape(source, "positionStep")
		if scalar == nil then return nil, suffix, reason end
		local positionWidth = 3 * scalar.width
		return {
			type = kind,
			containsCodec = true,
			minimum = scalar.minimum,
			maximum = scalar.maximum,
			positionStep = scalar.step,
			maximumIndex = scalar.maximumIndex,
			scalarWidth = scalar.width,
			positionWidth = positionWidth,
			width = positionWidth + 6,
			maximumPositionError = scalar.maximumError,
			minimumEncodedBytes = positionWidth + 6,
			maximumEncodedBytes = positionWidth + 6,
			maximumDepth = 0,
			maximumElements = 1,
			descriptorToken = "CF1," .. Quantized.numberToken(scalar.minimum) .. "," .. Quantized.numberToken(scalar.maximum)
				.. "," .. Quantized.numberToken(scalar.step) .. "," .. tostring(scalar.maximumIndex) .. ","
				.. tostring(scalar.width) .. ",XYZu16",
		}
	end
	return nil, ".type", "unsupported compact native shape type"
end

local function compile(shape)
	if type(shape) ~= "table" then return nil end
	local kind = shape.type
	if kind ~= "quantizedVector3" and kind ~= "quantizedVector2" and kind ~= "compactCFrame" then return nil end
	local scalar = Quantized.schema({
		type = "quantized",
		minimum = shape.minimum,
		maximum = shape.maximum,
		step = if kind == "compactCFrame" then shape.positionStep else shape.step,
	})
	if scalar == nil or shape.maximumIndex ~= scalar.maximumIndex or shape.scalarWidth ~= scalar.width then return nil end
	local scalarOps = Quantized.compile(scalar)
	if scalarOps == nil then return nil end
	if kind == "quantizedVector3" or kind == "quantizedVector2" then
		local dimensions = if kind == "quantizedVector3" then 3 else 2
		local width = dimensions * scalar.width
		local allowance = nativeAllowance(scalar)
		if allowance == nil or shape.width ~= width or shape.nativeAllowance ~= allowance then return nil end
		local constructor = if dimensions == 3 then Vector3.new else Vector2.new
		local vectorType = if dimensions == 3 then "Vector3" else "Vector2"
		local components = if dimensions == 3 then { "X", "Y", "Z" } else { "X", "Y" }

		local function selectValues(value)
			if typeof(value) ~= vectorType then return nil end
			local original = table.create(dimensions)
			local selected = table.create(dimensions)
			for index = 1, dimensions do
				local component = value[components[index]]
				if not finite(component) or component < scalar.minimum or component > scalar.maximum then return nil end
				local valid, canonical = scalarOps.normalize(component)
				if not valid then return nil end
				original[index], selected[index] = component, canonical
			end
			local ok, candidate = pcall(constructor, table.unpack(selected, 1, dimensions))
			if not ok or typeof(candidate) ~= vectorType then return nil end
			for index = 1, dimensions do
				local actual = candidate[components[index]]
				if not finite(actual) or actual < scalar.minimum or actual > scalar.maximum
					or math.abs(actual - selected[index]) > allowance
					or math.abs(actual - original[index]) > shape.maximumComponentError then
					return nil
				end
				local valid, stable = scalarOps.normalize(actual)
				if not valid or stable ~= selected[index] then return nil end
			end
			return selected
		end

		return table.freeze({
			normalize = function(value)
				if selectValues(value) == nil then return false end
				return true, value, width
			end,
			read = function(state)
				local offset, length = state.offset, state.length
				if offset < 0 or length < 0 or offset > length - width then return false end
				local localState = { value = state.value, offset = offset, length = length }
				local selected = table.create(dimensions)
				for index = 1, dimensions do
					local valid, component = scalarOps.read(localState)
					if not valid then return false end
					selected[index] = component
				end
				local ok, candidate = pcall(constructor, table.unpack(selected, 1, dimensions))
				if not ok or typeof(candidate) ~= vectorType then return false end
				for index = 1, dimensions do
					local actual = candidate[components[index]]
					if not finite(actual) or actual < scalar.minimum or actual > scalar.maximum
						or math.abs(actual - selected[index]) > allowance then return false end
					local stable, canonical = scalarOps.normalize(actual)
					if not stable or canonical ~= selected[index] then return false end
				end
				state.offset = localState.offset
				return true, candidate
			end,
			write = function(value, output, offset)
				local selected = selectValues(value)
				if selected == nil then return offset end
				for index = 1, dimensions do
					offset = scalarOps.write(selected[index], output, offset)
				end
				return offset
			end,
		})
	end

	local width, positionWidth = 3 * scalar.width + 6, 3 * scalar.width
	if shape.width ~= width or shape.positionWidth ~= positionWidth
		or shape.maximumPositionError ~= scalar.maximumError then return nil end

	local function components(value)
		if typeof(value) ~= "CFrame" then return nil end
		local ok, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = pcall(function()
			return value:GetComponents()
		end)
		if not ok then return nil end
		local result = { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }
		for index = 1, 12 do
			if not finite(result[index]) then return nil end
		end
		return result
	end

	local function properRotation(values)
		local a, b, c, d, e, f, g, h, i = values[4], values[5], values[6], values[7], values[8], values[9], values[10], values[11], values[12]
		if math.abs(a) > 1 + RIGID_TOLERANCE or math.abs(b) > 1 + RIGID_TOLERANCE
			or math.abs(c) > 1 + RIGID_TOLERANCE or math.abs(d) > 1 + RIGID_TOLERANCE
			or math.abs(e) > 1 + RIGID_TOLERANCE or math.abs(f) > 1 + RIGID_TOLERANCE
			or math.abs(g) > 1 + RIGID_TOLERANCE or math.abs(h) > 1 + RIGID_TOLERANCE
			or math.abs(i) > 1 + RIGID_TOLERANCE then return false end
		local function unit(x, y, z)
			return math.abs(x * x + y * y + z * z - 1) <= RIGID_TOLERANCE
		end
		local function orthogonal(x1, y1, z1, x2, y2, z2)
			return math.abs(x1 * x2 + y1 * y2 + z1 * z2) <= RIGID_TOLERANCE
		end
		if not unit(a, b, c) or not unit(d, e, f) or not unit(g, h, i)
			or not unit(a, d, g) or not unit(b, e, h) or not unit(c, f, i)
			or not orthogonal(a, b, c, d, e, f) or not orthogonal(a, b, c, g, h, i)
			or not orthogonal(d, e, f, g, h, i) or not orthogonal(a, d, g, b, e, h)
			or not orthogonal(a, d, g, c, f, i) or not orthogonal(b, e, h, c, f, i) then return false end
		local determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
		return finite(determinant) and math.abs(determinant - 1) <= RIGID_TOLERANCE
	end

	local function angleCode(angle)
		if not finite(angle) then return nil end
		local position = (angle % TWO_PI) / ANGLE_DELTA
		if not finite(position) then return nil end
		local lower = math.floor(position)
		local code = lower + (if position - lower >= 0.5 then 1 else 0)
		return code % 65_536
	end

	local function angleFromCode(code)
		return (((code + 32_768) % 65_536) - 32_768) * ANGLE_DELTA
	end

	local function frameFromSelection(x, y, z, codeX, codeY, codeZ)
		local rotationOk, rotation = pcall(CFrame.fromEulerAnglesXYZ,
			angleFromCode(codeX), angleFromCode(codeY), angleFromCode(codeZ))
		if not rotationOk or typeof(rotation) ~= "CFrame" then return nil end
		local rotationComponents = components(rotation)
		if rotationComponents == nil or not properRotation(rotationComponents) then return nil end
		local frameOk, frame = pcall(CFrame.new, x, y, z,
			rotationComponents[4], rotationComponents[5], rotationComponents[6],
			rotationComponents[7], rotationComponents[8], rotationComponents[9],
			rotationComponents[10], rotationComponents[11], rotationComponents[12])
		if not frameOk or typeof(frame) ~= "CFrame" then return nil end
		local frameComponents = components(frame)
		if frameComponents == nil or not properRotation(frameComponents) then return nil end
		return frame, frameComponents
	end

	local function stablePosition(values, selected, original)
		for index = 1, 3 do
			local actual = values[index]
			if actual < scalar.minimum or actual > scalar.maximum
				or math.abs(actual - selected[index]) > scalar.maximumError then return false end
			local valid, canonical = scalarOps.normalize(actual)
			if not valid or canonical ~= selected[index] then return false end
			if original ~= nil and math.abs(actual - original[index]) > scalar.maximumError then return false end
		end
		return true
	end

	local function prepare(value)
		local source = components(value)
		if source == nil or not properRotation(source) then return nil end
		local selected, original = table.create(3), table.create(3)
		for index = 1, 3 do
			local coordinate = source[index]
			if coordinate < scalar.minimum or coordinate > scalar.maximum then return nil end
			local valid, canonical = scalarOps.normalize(coordinate)
			if not valid then return nil end
			original[index], selected[index] = coordinate, canonical
		end
		local angleOk, rx, ry, rz = pcall(function() return value:ToEulerAnglesXYZ() end)
		if not angleOk then return nil end
		local codeX, codeY, codeZ = angleCode(rx), angleCode(ry), angleCode(rz)
		if codeX == nil or codeY == nil or codeZ == nil then return nil end
		local candidate, rebuilt = frameFromSelection(selected[1], selected[2], selected[3], codeX, codeY, codeZ)
		if candidate == nil or not stablePosition(rebuilt, selected, original) then return nil end
		local angleOk, angle = pcall(function() return value:AngleBetween(candidate) end)
		if not angleOk or not finite(angle) or angle > ROTATION_ERROR then return nil end
		return selected, codeX, codeY, codeZ
	end

	return table.freeze({
		normalize = function(value)
			if prepare(value) == nil then return false end
			return true, value, width
		end,
		read = function(state)
			local offset, length = state.offset, state.length
			if offset < 0 or length < 0 or offset > length - width then return false end
			local localState = { value = state.value, offset = offset, length = length }
			local selected = table.create(3)
			for index = 1, 3 do
				local valid, coordinate = scalarOps.read(localState)
				if not valid then return false end
				selected[index] = coordinate
			end
			local codeX = buffer.readu16(state.value, localState.offset)
			local codeY = buffer.readu16(state.value, localState.offset + 2)
			local codeZ = buffer.readu16(state.value, localState.offset + 4)
			local frame, rebuilt = frameFromSelection(selected[1], selected[2], selected[3], codeX, codeY, codeZ)
			if frame == nil or not stablePosition(rebuilt, selected, nil) then return false end
			state.offset = localState.offset + 6
			return true, frame
		end,
		write = function(value, output, offset)
			local selected, codeX, codeY, codeZ = prepare(value)
			if selected == nil then return offset end
			for index = 1, 3 do
				offset = scalarOps.write(selected[index], output, offset)
			end
			buffer.writeu16(output, offset, codeX)
			buffer.writeu16(output, offset + 2, codeY)
			buffer.writeu16(output, offset + 4, codeZ)
			return offset + 6
		end,
	})
end

return table.freeze({
	ROTATION_ERROR = ROTATION_ERROR,
	schema = schema,
	compile = compile,
})
