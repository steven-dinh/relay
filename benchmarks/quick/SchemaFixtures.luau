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
	["schema-string"] = {
		{ name = "sequence", type = "u32" }, { name = "text", type = "string", maximumBytes = 64 },
	},
	["schema-cframe"] = {
		{ name = "sequence", type = "u32" }, { name = "pose", type = "CFrame", minimum = -1024, maximum = 1024 },
	},
}
for _, payload in fields do
	for _, field in payload do table.freeze(field) end
	table.freeze(payload)
end
table.freeze(fields)

local function generate(payloadId: string, sequence: number): any
	local value: any = { sequence = sequence }
	if payloadId == "schema-signed" then
		value.small = sequence % 256 - 128
		value.medium = (sequence * 257) % 65536 - 32768
		value.large = (sequence * 104729) % 4294967296 - 2147483648
	elseif payloadId == "schema-vector2" then
		local class = if Vector2 ~= nil then Vector2 else require("@lune/roblox").Vector2
		value.direction = class.new((sequence % 2049) - 1024, ((sequence * 17) % 8193) / 4 - 1024)
	elseif payloadId == "schema-string" then
		local bytes = table.create(64)
		for index = 1, 64 do bytes[index] = string.char((sequence * 17 + index * 29) % 256) end
		value.text = table.concat(bytes)
	elseif payloadId == "schema-cframe" then
		local class = if CFrame ~= nil then CFrame else require("@lune/roblox").CFrame
		value.pose = class.new(sequence % 2049 - 1024, (sequence * 7) % 2049 - 1024, (sequence * 13) % 2049 - 1024)
			* class.Angles((sequence % 37) / 17, (sequence % 53) / 19, (sequence % 71) / 23)
	else error("unknown quick schema payload", 0) end
	return value
end

local function compare(payloadId: string, expected: any, actual: any, localInput: boolean): boolean
	if type(actual) ~= "table" then return false end
	local count = 0
	for _ in next, actual do count += 1 if count > #fields[payloadId] then return false end end
	if count ~= #fields[payloadId] then return false end
	for _, field in fields[payloadId] do
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
		elseif left ~= right then return false end
	end
	return true
end

return table.freeze({ fields = fields, generate = generate, compare = compare })
