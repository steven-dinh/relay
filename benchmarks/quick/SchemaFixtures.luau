--!strict

-- Private diagnostic payloads; the frozen Event V1 fixtures stay unchanged.
local fields = {
	["schema-signed"] = {
		{ name = "sequence", type = "u32" }, { name = "small", type = "i8" },
		{ name = "medium", type = "i16" }, { name = "large", type = "i32" },
	},
	["schema-vector2"] = {
		{ name = "sequence", type = "u32" }, { name = "direction", type = "Vector2F32", minimum = -1024, maximum = 1024 },
	},
	["schema-vector3"] = {
		{ name = "sequence", type = "u32" }, { name = "position", type = "Vector3F32", minimum = -1024, maximum = 1024 },
	},
	["schema-string"] = {
		{ name = "sequence", type = "u32" }, { name = "text", type = "string", maximumBytes = 64 },
	},
	["schema-cframe"] = {
		{ name = "sequence", type = "u32" }, { name = "pose", type = "CFrame", minimum = -1024, maximum = 1024 },
	},
	["schema-composite"] = {
		{ name = "sequence", type = "u32" },
		{ name = "items", type = "array", maximumLength = 16, element = { type = "struct", fields = {
			{ name = "entityId", type = "u16" }, { name = "score", type = "i32" },
			{ name = "enabled", type = "boolean" },
		} } },
	},
	["schema-compact-numbers"] = {
		{ name = "sequence", type = "u32" },
		{ name = "values", type = "struct", fields = {
			{ name = "u24", type = "u24", minimum = 0, maximum = 16_777_215 },
			{ name = "i24", type = "i24", minimum = -8_388_608, maximum = 8_388_607 },
			{ name = "f16", type = "f16", minimum = -16, maximum = 16 },
			{ name = "f24", type = "f24", minimum = -16, maximum = 16 },
			{ name = "f64", type = "f64", minimum = -64, maximum = 64 },
		} },
	},
	["schema-buffer"] = {
		{ name = "sequence", type = "u32" },
		{ name = "data", type = "buffer", maximumBytes = 64, minimumBytes = 0 },
	},
	["schema-bounded"] = {
		{ name = "sequence", type = "u32" },
		{ name = "values", type = "struct", fields = {
			{ name = "empty", type = "string", maximumBytes = 0, minimumBytes = 0 },
			{ name = "text", type = "string", maximumBytes = 12, minimumBytes = 2 },
			{ name = "bytes", type = "buffer", maximumBytes = 8, minimumBytes = 2 },
			{ name = "fixed", type = "array", minimumLength = 2, maximumLength = 2, element = { type = "u8" } },
			{ name = "items", type = "array", minimumLength = 0, maximumLength = 3, element = { type = "u16" } },
			{ name = "lookup", type = "map", minimumSize = 0, maximumSize = 3,
				key = { type = "string", maximumBytes = 8 }, value = { type = "i16", minimum = -1_000, maximum = 1_000 } },
			{ name = "tags", type = "set", minimumSize = 0, maximumSize = 3,
				element = { type = "enum", values = { "A", "B", "C", "D" } } },
		} },
	},
	["schema-quantized"] = {
		{ name = "sequence", type = "u32" },
		{ name = "values", type = "struct", fields = {
			{ name = "scalar3", type = "quantized", minimum = -1, maximum = 1, step = 1 / 131_072 },
			{ name = "scalar4", type = "quantized", minimum = -1, maximum = 1, step = 1 / 16_777_216 },
			{ name = "vector2", type = "quantizedVector2", minimum = -1, maximum = 1, step = 1 / 32_768 },
			{ name = "vector3", type = "quantizedVector3", minimum = -1, maximum = 1, step = 1 / 131_072 },
			{ name = "pose", type = "compactCFrame", minimum = -16, maximum = 16, positionStep = 0.125 },
		} },
	},
	["schema-packed"] = {
		{ name = "sequence", type = "u32" },
		{ name = "values", type = "struct", fields = {
			{ name = "flag", type = "boolean" },
			{ name = "mode", type = "enum", values = { "Idle", "Move", "Jump" } },
			{ name = "maybeFlag", type = "optional", value = { type = "boolean" } },
			{ name = "maybeMode", type = "optional", value = { type = "enum", values = { "Idle", "Move", "Jump" } } },
			{ name = "flags", type = "array", minimumLength = 0, maximumLength = 5, element = { type = "boolean" } },
			{ name = "modes", type = "array", minimumLength = 0, maximumLength = 5,
				element = { type = "enum", values = { "Idle", "Move", "Jump" } } },
		} },
	},
	["schema-color3"] = {
		{ name = "sequence", type = "u32" },
		{ name = "values", type = "struct", fields = {
			{ name = "color", type = "Color3" },
			{ name = "rgb8", type = "Color3RGB8" },
		} },
	},
}

local function freezeShape(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then return end
	for _, child in value do freezeShape(child) end
	table.freeze(value)
end
for _, payload in fields do freezeShape(payload) end
table.freeze(fields)

local relayTypes = table.freeze({
	["schema-compact-numbers"] = true,
	["schema-buffer"] = true,
	["schema-bounded"] = true,
	["schema-quantized"] = true,
	["schema-packed"] = true,
	["schema-color3"] = true,
})
local definitionOptions = table.freeze({ ["schema-packed"] = table.freeze({ bitPacking = true }) })

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function roundNearestEven(value: number, fractionBits: number, minimumNormalExponent: number, minimumSubnormalExponent: number): number
	if value == 0 then return 0 end
	local magnitude = math.abs(value)
	local exponent = math.floor(math.log(magnitude) / math.log(2))
	while magnitude < 2 ^ exponent do exponent -= 1 end
	while magnitude >= 2 ^ (exponent + 1) do exponent += 1 end
	local unit = if exponent < minimumNormalExponent then 2 ^ minimumSubnormalExponent else 2 ^ (exponent - fractionBits)
	local scaled = magnitude / unit
	local lower = math.floor(scaled)
	local remainder = scaled - lower
	if remainder > 0.5 or (remainder == 0.5 and lower % 2 == 1) then lower += 1 end
	local rounded = lower * unit
	return if value < 0 then -rounded else rounded
end

local function compactFloat16(value: number): number
	return roundNearestEven(value, 10, -14, -24)
end

local function compactFloat24(value: number): number
	return roundNearestEven(value, 17, -30, -47)
end

local function quantizedValue(value: number, minimum: number, maximum: number, step: number): number
	if value == minimum then return minimum end
	if value == maximum then return maximum end
	local position = (value - minimum) / step
	local lower = math.floor(position)
	local index = lower + (if position - lower >= 0.5 then 1 else 0)
	local rounded = minimum + index * step
	return if rounded == 0 then 0 else rounded
end

local function color3(r: number, g: number, b: number): Color3
	local class = if Color3 ~= nil then Color3 else require("@lune/roblox").Color3
	return class.new(r, g, b)
end

local function generate(payloadId: string, sequence: number): any
	local value: any = { sequence = sequence }
	if payloadId == "schema-signed" then
		value.small = sequence % 256 - 128
		value.medium = (sequence * 257) % 65536 - 32768
		value.large = (sequence * 104729) % 4294967296 - 2147483648
	elseif payloadId == "schema-vector2" then
		local class = if Vector2 ~= nil then Vector2 else require("@lune/roblox").Vector2
		value.direction = class.new((sequence % 2049) - 1024, ((sequence * 17) % 8193) / 4 - 1024)
	elseif payloadId == "schema-vector3" then
		local class = if Vector3 ~= nil then Vector3 else require("@lune/roblox").Vector3
		value.position = class.new(((sequence * 17) % 8193) / 4 - 1024,
			((sequence * 101) % 8193) / 4 - 1024, ((sequence * 257) % 8193) / 4 - 1024)
	elseif payloadId == "schema-string" then
		local bytes = table.create(64)
		for index = 1, 64 do bytes[index] = string.char((sequence * 17 + index * 29) % 256) end
		value.text = table.concat(bytes)
	elseif payloadId == "schema-cframe" then
		local class = if CFrame ~= nil then CFrame else require("@lune/roblox").CFrame
		value.pose = class.new(sequence % 2049 - 1024, (sequence * 7) % 2049 - 1024, (sequence * 13) % 2049 - 1024)
			* class.Angles((sequence % 37) / 17, (sequence % 53) / 19, (sequence % 71) / 23)
	elseif payloadId == "schema-composite" then
		local items = table.create(16)
		for index = 1, 16 do
			local offset = index - 1
			local itemSequence = sequence + offset
			items[index] = {
				entityId = itemSequence % 65536,
				score = itemSequence % 65536 - 32768,
				enabled = itemSequence % 2 == 0,
			}
		end
		value.items = items
	elseif payloadId == "schema-compact-numbers" then
		local halfTies = { 1 + 2 ^ -11, 1 + 3 * 2 ^ -11, -1 - 2 ^ -11, 1.1 }
		local quarterTies = { 1 + 2 ^ -18, 1 + 3 * 2 ^ -18, -1 - 2 ^ -18, 1.1 }
		value.values = {
			u24 = (sequence * 257) % 16_777_216,
			i24 = (sequence * 8191) % 16_777_216 - 8_388_608,
			f16 = halfTies[sequence % #halfTies + 1],
			f24 = quarterTies[sequence % #quarterTies + 1],
			f64 = (sequence % 1024 - 512) / 8 + 2 ^ -40,
		}
	elseif payloadId == "schema-buffer" then
		local length = sequence % 65
		local bytes = buffer.create(length)
		for index = 0, length - 1 do buffer.writeu8(bytes, index, (sequence * 37 + index * 71) % 256) end
		value.data = bytes
	elseif payloadId == "schema-bounded" then
		local length = sequence % 4
		local bytesLength = sequence % 7 + 2
		local bytes = buffer.create(bytesLength)
		for index = 0, bytesLength - 1 do buffer.writeu8(bytes, index, (sequence * 29 + index * 53) % 256) end
		local fixed = { (sequence * 3) % 256, (sequence * 7 + 1) % 256 }
		local items, lookup, tags = table.create(length), {}, {}
		for index = 1, length do
			items[index] = (sequence * 31 + index * 101) % 65_536
			lookup[string.char(96 + index)] = (sequence + index) % 2001 - 1000
			tags[({ "A", "B", "C", "D" })[(sequence + index - 1) % 4 + 1]] = true
		end
		value.values = {
			empty = "",
			text = string.rep("x", sequence % 11 + 2),
			bytes = bytes,
			fixed = fixed,
			items = items,
			lookup = lookup,
			tags = tags,
		}
	elseif payloadId == "schema-quantized" then
		local vector2 = if Vector2 ~= nil then Vector2 else require("@lune/roblox").Vector2
		local vector3 = if Vector3 ~= nil then Vector3 else require("@lune/roblox").Vector3
		local cframe = if CFrame ~= nil then CFrame else require("@lune/roblox").CFrame
		local function sourceGrid(index: number, step: number, intervals: number): number
			return -1 + (index % (intervals - 1)) * step + step * (if sequence % 2 == 0 then 0.5 else 0.25)
		end
		local xIndex, yIndex, zIndex = sequence * 7 % 255, sequence * 11 % 255, sequence * 13 % 255
		local pose = cframe.new(-16 + xIndex * 0.125 + 0.0625,
			-16 + yIndex * 0.125 + 0.0625, -16 + zIndex * 0.125 + 0.03125)
			* cframe.fromEulerAnglesXYZ(sequence % 31 / 64, sequence % 23 / 64, sequence % 17 / 64)
		value.values = {
			scalar3 = sourceGrid(sequence * 127, 1 / 131_072, 262_144),
			scalar4 = sourceGrid(sequence * 257, 1 / 16_777_216, 33_554_432),
			vector2 = vector2.new(sourceGrid(sequence * 17, 1 / 32_768, 65_536),
				sourceGrid(sequence * 29 + 1, 1 / 32_768, 65_536)),
			vector3 = vector3.new(sourceGrid(sequence * 19, 1 / 131_072, 262_144),
				sourceGrid(sequence * 31 + 1, 1 / 131_072, 262_144),
				sourceGrid(sequence * 43 + 2, 1 / 131_072, 262_144)),
			pose = pose,
		}
	elseif payloadId == "schema-packed" then
		local names = { "Idle", "Move", "Jump" }
		local flagsLength, modesLength = sequence % 6, (sequence + 1) % 6
		local flags, modes = table.create(flagsLength), table.create(modesLength)
		for index = 1, flagsLength do flags[index] = (sequence + index) % 2 == 0 end
		for index = 1, modesLength do modes[index] = names[(sequence + index - 1) % #names + 1] end
		local packed: any = {
			flag = sequence % 2 == 0,
			mode = names[sequence % #names + 1],
			flags = flags,
			modes = modes,
		}
		if sequence % 2 == 0 then packed.maybeFlag = sequence % 4 == 0 end
		if sequence % 3 == 0 then packed.maybeMode = names[(sequence + 1) % #names + 1] end
		value.values = packed
	elseif payloadId == "schema-color3" then
		value.values = {
			color = color3(((sequence * 17) % 249 + 0.25) / 250,
				((sequence * 31) % 249 + 0.5) / 250, ((sequence * 47) % 249 + 0.75) / 250),
			rgb8 = color3(((sequence * 13) % 253 + 0.37) / 255,
				((sequence * 29) % 253 + 0.61) / 255, ((sequence * 43) % 253 + 0.83) / 255),
		}
	else error("unknown quick schema payload", 0) end
	return value
end

local function compareComposite(expected: any, actual: any): boolean
	if type(actual) ~= "table" or getmetatable(actual) ~= nil then return false end
	local rootCount = 0
	for key in next, actual do
		rootCount += 1
		if rootCount > 2 or (key ~= "sequence" and key ~= "items") then return false end
	end
	if rootCount ~= 2 or rawget(actual, "sequence") ~= expected.sequence then return false end
	local items = rawget(actual, "items")
	local maximumLength = fields["schema-composite"][2].maximumLength
	if type(items) ~= "table" or getmetatable(items) ~= nil then return false end
	local itemCount = 0
	for key in next, items do
		itemCount += 1
		if itemCount > maximumLength or type(key) ~= "number" or key % 1 ~= 0
			or key < 1 or key > maximumLength then return false end
	end
	if itemCount ~= maximumLength then return false end
	for index = 1, maximumLength do
		local expectedItem, actualItem = expected.items[index], rawget(items, index)
		if type(actualItem) ~= "table" or getmetatable(actualItem) ~= nil then return false end
		local fieldCount = 0
		for key in next, actualItem do
			fieldCount += 1
			if fieldCount > 3 or (key ~= "entityId" and key ~= "score" and key ~= "enabled") then return false end
		end
		if fieldCount ~= 3 or rawget(actualItem, "entityId") ~= expectedItem.entityId
			or rawget(actualItem, "score") ~= expectedItem.score
			or rawget(actualItem, "enabled") ~= expectedItem.enabled then return false end
	end
	return true
end

local function bounded(value: any, minimum: number, maximum: number, integer: boolean?): boolean
	return finite(value) and value >= minimum and value <= maximum
		and (not integer or value % 1 == 0)
end

local function recordKeys(value: any, allowed: any, required: any, minimumCount: number, maximumCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local count = 0
	for key in next, value do
		count += 1
		if count > maximumCount or type(key) ~= "string" or not allowed[key] then return false end
	end
	if count < minimumCount then return false end
	for _, key in required do if rawget(value, key) == nil then return false end end
	return true
end

local function arrayLength(value: any, minimum: number, maximum: number): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local count = 0
	for key in next, value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximum then return nil end
		count += 1
		if count > maximum then return nil end
	end
	if count < minimum then return nil end
	for index = 1, count do if rawget(value, index) == nil then return nil end end
	return count
end

local function dictionaryLength(value: any, maximum: number): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local count = 0
	for _ in next, value do
		count += 1
		if count > maximum then return nil end
	end
	return count
end

local function copyBuffer(value: any, minimum: number, maximum: number): buffer?
	if typeof(value) ~= "buffer" then return nil end
	local length = buffer.len(value)
	if length < minimum or length > maximum then return nil end
	local result = buffer.create(length)
	if length > 0 then buffer.copy(result, 0, value, 0, length) end
	return result
end

local function validVector2(value: any): boolean
	return typeof(value) == "Vector2" and finite(value.X) and finite(value.Y)
		and value.X >= -1 and value.X <= 1 and value.Y >= -1 and value.Y <= 1
end

local function validVector3(value: any): boolean
	return typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z)
		and value.X >= -1 and value.X <= 1 and value.Y >= -1 and value.Y <= 1
		and value.Z >= -1 and value.Z <= 1
end

local function validFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then return false end
	local components = { value:GetComponents() }
	for _, component in components do if not finite(component) then return false end end
	return components[1] >= -16 and components[1] <= 16 and components[2] >= -16 and components[2] <= 16
		and components[3] >= -16 and components[3] <= 16
end

local function validColor3(value: any): boolean
	return typeof(value) == "Color3" and finite(value.R) and finite(value.G) and finite(value.B)
		and value.R >= 0 and value.R <= 1 and value.G >= 0 and value.G <= 1 and value.B >= 0 and value.B <= 1
end

local function snapshot(payloadId: string, record: any): any?
	local secondName = if payloadId == "schema-buffer" then "data" else "values"
	if not relayTypes[payloadId] or not recordKeys(record, { sequence = true, [secondName] = true }, { "sequence", secondName }, 2, 2)
		or not bounded(rawget(record, "sequence"), 0, 4_294_967_295, true) then return nil end
	local sequence = rawget(record, "sequence")
	local second = rawget(record, secondName)
	if payloadId == "schema-buffer" then
		local data = copyBuffer(second, 0, 64)
		return if data ~= nil then { sequence = sequence, data = data } else nil
	elseif payloadId == "schema-compact-numbers" then
		local keys = { u24 = true, i24 = true, f16 = true, f24 = true, f64 = true }
		local required = { "u24", "i24", "f16", "f24", "f64" }
		if not recordKeys(second, keys, required, 5, 5) then return nil end
		local u24, i24, f16, f24, f64 = rawget(second, "u24"), rawget(second, "i24"), rawget(second, "f16"), rawget(second, "f24"), rawget(second, "f64")
		if not bounded(u24, 0, 16_777_215, true) or not bounded(i24, -8_388_608, 8_388_607, true)
			or not bounded(f16, -16, 16) or not bounded(f24, -16, 16) or not bounded(f64, -64, 64) then return nil end
		return { sequence = sequence, values = { u24 = u24, i24 = i24, f16 = f16, f24 = f24, f64 = f64 } }
	elseif payloadId == "schema-bounded" then
		local allowed = { empty = true, text = true, bytes = true, fixed = true, items = true, lookup = true, tags = true }
		local required = { "empty", "text", "bytes", "fixed", "items", "lookup", "tags" }
		if not recordKeys(second, allowed, required, 7, 7) then return nil end
		local empty, text, bytes = rawget(second, "empty"), rawget(second, "text"), rawget(second, "bytes")
		local fixed, items, lookup, tags = rawget(second, "fixed"), rawget(second, "items"), rawget(second, "lookup"), rawget(second, "tags")
		local fixedCount = arrayLength(fixed, 2, 2)
		local itemCount = arrayLength(items, 0, 3)
		local lookupCount = dictionaryLength(lookup, 3)
		local tagCount = dictionaryLength(tags, 3)
		if empty ~= "" or type(text) ~= "string" or #text < 2 or #text > 12
			or typeof(bytes) ~= "buffer" or buffer.len(bytes) < 2 or buffer.len(bytes) > 8
			or fixedCount ~= 2 or itemCount == nil or lookupCount == nil or tagCount == nil then return nil end
		for index = 1, fixedCount do if not bounded(rawget(fixed, index), 0, 255, true) then return nil end end
		for index = 1, itemCount do if not bounded(rawget(items, index), 0, 65_535, true) then return nil end end
		for key, item in next, lookup do
			if type(key) ~= "string" or #key > 8 or not bounded(item, -1_000, 1_000, true) then return nil end
		end
		for key, item in next, tags do
			if (key ~= "A" and key ~= "B" and key ~= "C" and key ~= "D") or item ~= true then return nil end
		end
		local bytesCopy = copyBuffer(bytes, 2, 8)
		if bytesCopy == nil then return nil end
		local fixedCopy, itemsCopy, lookupCopy, tagsCopy = table.create(fixedCount), table.create(itemCount), {}, {}
		for index = 1, fixedCount do fixedCopy[index] = rawget(fixed, index) end
		for index = 1, itemCount do itemsCopy[index] = rawget(items, index) end
		for key, item in next, lookup do lookupCopy[key] = item end
		for key, item in next, tags do tagsCopy[key] = item end
		return { sequence = sequence, values = { empty = empty, text = text, bytes = bytesCopy,
			fixed = fixedCopy, items = itemsCopy, lookup = lookupCopy, tags = tagsCopy } }
	elseif payloadId == "schema-quantized" then
		local keys = { scalar3 = true, scalar4 = true, vector2 = true, vector3 = true, pose = true }
		local required = { "scalar3", "scalar4", "vector2", "vector3", "pose" }
		if not recordKeys(second, keys, required, 5, 5) then return nil end
		local scalar3, scalar4 = rawget(second, "scalar3"), rawget(second, "scalar4")
		local vector2, vector3, pose = rawget(second, "vector2"), rawget(second, "vector3"), rawget(second, "pose")
		if not bounded(scalar3, -1, 1) or not bounded(scalar4, -1, 1) or not validVector2(vector2)
			or not validVector3(vector3) or not validFrame(pose) then return nil end
		return { sequence = sequence, values = { scalar3 = scalar3, scalar4 = scalar4,
			vector2 = vector2, vector3 = vector3, pose = pose } }
	elseif payloadId == "schema-packed" then
		local allowed = { flag = true, mode = true, maybeFlag = true, maybeMode = true, flags = true, modes = true }
		local required = { "flag", "mode", "flags", "modes" }
		if not recordKeys(second, allowed, required, 4, 6) then return nil end
		local flag, mode = rawget(second, "flag"), rawget(second, "mode")
		local maybeFlag, maybeMode = rawget(second, "maybeFlag"), rawget(second, "maybeMode")
		local flags, modes = rawget(second, "flags"), rawget(second, "modes")
		local flagsCount, modesCount = arrayLength(flags, 0, 5), arrayLength(modes, 0, 5)
		if type(flag) ~= "boolean" or (mode ~= "Idle" and mode ~= "Move" and mode ~= "Jump")
			or (maybeFlag ~= nil and type(maybeFlag) ~= "boolean")
			or (maybeMode ~= nil and maybeMode ~= "Idle" and maybeMode ~= "Move" and maybeMode ~= "Jump")
			or flagsCount == nil or modesCount == nil then return nil end
		for index = 1, flagsCount do if type(rawget(flags, index)) ~= "boolean" then return nil end end
		for index = 1, modesCount do
			local item = rawget(modes, index)
			if item ~= "Idle" and item ~= "Move" and item ~= "Jump" then return nil end
		end
		local flagsCopy, modesCopy = table.create(flagsCount), table.create(modesCount)
		for index = 1, flagsCount do flagsCopy[index] = rawget(flags, index) end
		for index = 1, modesCount do modesCopy[index] = rawget(modes, index) end
		local values: any = { flag = flag, mode = mode, flags = flagsCopy, modes = modesCopy }
		if maybeFlag ~= nil then values.maybeFlag = maybeFlag end
		if maybeMode ~= nil then values.maybeMode = maybeMode end
		return { sequence = sequence, values = values }
	elseif payloadId == "schema-color3" then
		local keys = { color = true, rgb8 = true }
		local required = { "color", "rgb8" }
		if not recordKeys(second, keys, required, 2, 2) then return nil end
		local color, rgb8 = rawget(second, "color"), rawget(second, "rgb8")
		if not validColor3(color) or not validColor3(rgb8) then return nil end
		return { sequence = sequence, values = { color = color, rgb8 = rgb8 } }
	end
	return nil
end

local function same(left: any, right: any): boolean
	local kind = typeof(left)
	if kind ~= typeof(right) then return false end
	if kind == "buffer" then
		if buffer.len(left) ~= buffer.len(right) then return false end
		for index = 0, buffer.len(left) - 1 do
			if buffer.readu8(left, index) ~= buffer.readu8(right, index) then return false end
		end
		return true
	elseif kind == "Vector2" then
		return same(left.X, right.X) and same(left.Y, right.Y)
	elseif kind == "Vector3" then
		return same(left.X, right.X) and same(left.Y, right.Y) and same(left.Z, right.Z)
	elseif kind == "Color3" then
		return same(left.R, right.R) and same(left.G, right.G) and same(left.B, right.B)
	elseif kind == "CFrame" then
		local before, after = { left:GetComponents() }, { right:GetComponents() }
		for index = 1, 12 do
			if before[index] ~= after[index] or (before[index] == 0 and 1 / before[index] ~= 1 / after[index]) then return false end
		end
		return true
	elseif kind == "table" then
		local count = 0
		for key, item in next, left do
			count += 1
			if rawget(right, key) == nil or not same(item, rawget(right, key)) then return false end
		end
		local otherCount = 0
		for _ in next, right do otherCount += 1 end
		return count == otherCount
	end
	return left == right and (kind ~= "number" or left ~= 0 or 1 / left == 1 / right)
end

local function expectedPose(value: CFrame): CFrame
	local class = if CFrame ~= nil then CFrame else require("@lune/roblox").CFrame
	local values = { value:GetComponents() }
	local rx, ry, rz = value:ToEulerAnglesXYZ()
	local twoPi, increment = 2 * math.pi, 2 * math.pi / 65_536
	local function angle(value: number): number
		local position = (value % twoPi) / increment
		local code = (math.floor(position + 0.5)) % 65_536
		return (((code + 32_768) % 65_536) - 32_768) * increment
	end
	local rotation = class.fromEulerAnglesXYZ(angle(rx), angle(ry), angle(rz))
	local rotationValues = { rotation:GetComponents() }
	return class.new(quantizedValue(values[1], -16, 16, 0.125), quantizedValue(values[2], -16, 16, 0.125),
		quantizedValue(values[3], -16, 16, 0.125), table.unpack(rotationValues, 4, 12))
end

local function compareNew(payloadId: string, expected: any, actual: any, localInput: boolean): boolean
	local before, after = snapshot(payloadId, expected), snapshot(payloadId, actual)
	if before == nil or after == nil then return false end
	if localInput then return same(before, after) end
	local values = before.values
	if payloadId == "schema-compact-numbers" then
		values.f16 = compactFloat16(values.f16)
		values.f24 = compactFloat24(values.f24)
	elseif payloadId == "schema-quantized" then
		values.scalar3 = quantizedValue(values.scalar3, -1, 1, 1 / 131_072)
		values.scalar4 = quantizedValue(values.scalar4, -1, 1, 1 / 16_777_216)
		local vector2 = if Vector2 ~= nil then Vector2 else require("@lune/roblox").Vector2
		local vector3 = if Vector3 ~= nil then Vector3 else require("@lune/roblox").Vector3
		values.vector2 = vector2.new(quantizedValue(values.vector2.X, -1, 1, 1 / 32_768),
			quantizedValue(values.vector2.Y, -1, 1, 1 / 32_768))
		values.vector3 = vector3.new(quantizedValue(values.vector3.X, -1, 1, 1 / 131_072),
			quantizedValue(values.vector3.Y, -1, 1, 1 / 131_072), quantizedValue(values.vector3.Z, -1, 1, 1 / 131_072))
		values.pose = expectedPose(values.pose)
	elseif payloadId == "schema-color3" then
		local color = values.rgb8
		values.rgb8 = color3(math.floor(color.R * 255 + 0.5) / 255,
			math.floor(color.G * 255 + 0.5) / 255, math.floor(color.B * 255 + 0.5) / 255)
	end
	return same(before, after)
end

local function compare(payloadId: string, expected: any, actual: any, localInput: boolean): boolean
	if relayTypes[payloadId] then return compareNew(payloadId, expected, actual, localInput) end
	if payloadId == "schema-composite" then return compareComposite(expected, actual) end
	if type(actual) ~= "table" then return false end
	local payloadFields = fields[payloadId]
	local fieldCount = #payloadFields
	local count = 0
	for _ in next, actual do count += 1 if count > fieldCount then return false end end
	if count ~= fieldCount then return false end
	for _, field in payloadFields do
		local left, right = expected[field.name], actual[field.name]
		if field.type == "CFrame" then
			if typeof(right) ~= "CFrame" then return false end
			local before, after = { left:GetComponents() }, { right:GetComponents() }
			for index = 1, 12 do
				if localInput then
					if before[index] ~= after[index] or (before[index] == 0 and 1 / before[index] ~= 1 / after[index]) then return false end
				elseif index <= 3 then
					if before[index] ~= after[index] then return false end
				elseif not (math.abs(before[index] - after[index]) <= 0.0001) then return false end
			end
		elseif field.type == "Vector2F32" then
			if typeof(right) ~= "Vector2" or left.X ~= right.X or left.Y ~= right.Y then return false end
		elseif field.type == "Vector3F32" then
			if typeof(right) ~= "Vector3" or left.X ~= right.X or left.Y ~= right.Y or left.Z ~= right.Z then return false end
		elseif left ~= right then return false end
	end
	return true
end

return table.freeze({
	fields = fields,
	relayTypes = relayTypes,
	definitionOptions = definitionOptions,
	generate = generate,
	compare = compare,
	snapshot = snapshot,
})
