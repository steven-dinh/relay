--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ResultV1 = require("../contracts/result-v1")
local ResultV2 = require("../contracts/result-v2")
local ResultReporter = require("./ResultReporter")

local JSON_DEPTH_MAX = 10
local JSON_OBJECT_KEY_BYTES_MAX = 128
local JSON_TOKEN_MAX = 131_072
local MAX_DIAGNOSTIC_BYTES = 512
local MAX_JSON_BYTES = math.max(ResultV1.MAX_JSON_BYTES, ResultV2.MAX_JSON_BYTES)

local function diagnosticText(value: string): string
	local limit = math.min(#value, MAX_DIAGNOSTIC_BYTES)
	local sanitized = table.create(limit)
	for index = 1, limit do
		local byte = string.byte(value, index)
		sanitized[index] = if byte <= 31 or byte == 127 then "?" else string.char(byte)
	end
	if #value > MAX_DIAGNOSTIC_BYTES then
		sanitized[MAX_DIAGNOSTIC_BYTES - 2] = "."
		sanitized[MAX_DIAGNOSTIC_BYTES - 1] = "."
		sanitized[MAX_DIAGNOSTIC_BYTES] = "."
	end
	return table.concat(sanitized)
end

local function fail(code: string, path: string?): never
	error(if path == nil then code else code .. ":" .. diagnosticText(path), 0)
end

local function resultFileSize(path: string): number
	local metadataOk, metadata = pcall(fs.metadata, path)
	if not metadataOk or type(metadata) ~= "table"
		or metadata.exists ~= true or metadata.kind ~= "file"
	then
		fail("RESULT_REPORT_E_FILE", path)
	end

	local command
	local arguments
	local options = nil
	if process.os == "windows" then
		command = "powershell.exe"
		arguments = {
			"-NoProfile", "-NonInteractive", "-Command",
			[[& { $ErrorActionPreference='Stop';$value=(Get-Item -LiteralPath $env:RELAY_REPORT_RESULT_PATH -Force).Length;[Console]::Out.Write($value) }]],
		}
		options = { env = { RELAY_REPORT_RESULT_PATH = path } }
	elseif process.os == "macos" then
		command = "/usr/bin/stat"
		arguments = { "-f", "%z", if string.sub(path, 1, 1) == "-" then "./" .. path else path }
	elseif process.os == "linux" then
		command = "/usr/bin/stat"
		arguments = { "-c", "%s", "--", path }
	else
		fail("RESULT_REPORT_E_FILE", path)
	end

	local executeOk, result = pcall(process.exec, command, arguments, options)
	if not executeOk or type(result) ~= "table" or result.ok ~= true
		or type(result.stdout) ~= "string" or #result.stdout > 32
	then
		fail("RESULT_REPORT_E_READ", path)
	end
	local digits = string.match(result.stdout, "^([0-9]+)%s*$")
	if digits == nil or #digits > 15 then
		fail("RESULT_REPORT_E_READ", path)
	end
	local size = tonumber(digits)
	if size == nil or size < 0 or math.floor(size) ~= size then
		fail("RESULT_REPORT_E_READ", path)
	end
	if size > MAX_JSON_BYTES then
		fail("RESULT_REPORT_E_SIZE", path)
	end
	return size
end

local function jsonPreflight(source: string, path: string)
	if type(source) ~= "string" or #source > MAX_JSON_BYTES then
		fail("RESULT_REPORT_E_JSON", path)
	end
	local length = #source
	local cursor = 1
	local tokens = 0

	local function bump()
		tokens += 1
		if tokens > JSON_TOKEN_MAX then
			fail("RESULT_REPORT_E_JSON", path)
		end
	end

	local function skipWhitespace()
		while cursor <= length do
			local byte = string.byte(source, cursor)
			if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
				break
			end
			cursor += 1
		end
	end

	local function hexValue(byte: number?): number?
		if byte == nil then
			return nil
		end
		if byte >= 48 and byte <= 57 then
			return byte - 48
		end
		if byte >= 65 and byte <= 70 then
			return byte - 55
		end
		if byte >= 97 and byte <= 102 then
			return byte - 87
		end
		return nil
	end

	local function readCodeUnit(): number
		local value = 0
		for _ = 1, 4 do
			local digit = hexValue(string.byte(source, cursor))
			if digit == nil then
				fail("RESULT_REPORT_E_JSON", path)
			end
			value = value * 16 + digit
			cursor += 1
		end
		return value
	end

	local function parseString(capture: boolean): string?
		if string.byte(source, cursor) ~= 34 then
			fail("RESULT_REPORT_E_JSON", path)
		end
		cursor += 1
		local output = if capture then {} else nil
		local outputBytes = 0
		local function appendOutput(value: string)
			if output == nil then
				return
			end
			outputBytes += #value
			if outputBytes > JSON_OBJECT_KEY_BYTES_MAX then
				fail("RESULT_REPORT_E_JSON", path)
			end
			table.insert(output, value)
		end

		while cursor <= length do
			local byte = string.byte(source, cursor)
			if byte == 34 then
				cursor += 1
				return if output == nil then nil else table.concat(output)
			elseif byte == nil or byte < 32 then
				fail("RESULT_REPORT_E_JSON", path)
			elseif byte ~= 92 then
				appendOutput(string.char(byte))
				cursor += 1
			else
				cursor += 1
				local escaped = string.byte(source, cursor)
				if escaped == nil then
					fail("RESULT_REPORT_E_JSON", path)
				end
				cursor += 1
				if escaped == 117 then
					local codepoint = readCodeUnit()
					if codepoint >= 0xD800 and codepoint <= 0xDBFF then
						if string.sub(source, cursor, cursor + 1) ~= "\\u" then
							fail("RESULT_REPORT_E_JSON", path)
						end
						cursor += 2
						local low = readCodeUnit()
						if low < 0xDC00 or low > 0xDFFF then
							fail("RESULT_REPORT_E_JSON", path)
						end
						codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + low - 0xDC00
					elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
						fail("RESULT_REPORT_E_JSON", path)
					end
					appendOutput(utf8.char(codepoint))
				else
					local decoded = ({
						[34] = '"',
						[92] = "\\",
						[47] = "/",
						[98] = "\b",
						[102] = "\f",
						[110] = "\n",
						[114] = "\r",
						[116] = "\t",
					})[escaped]
					if decoded == nil then
						fail("RESULT_REPORT_E_JSON", path)
					end
					appendOutput(decoded)
				end
			end
		end
		fail("RESULT_REPORT_E_JSON", path)
	end

	local function parseNumber()
		local start = cursor
		if string.byte(source, cursor) == 45 then
			cursor += 1
		end
		local first = string.byte(source, cursor)
		if first == 48 then
			cursor += 1
			local nextByte = string.byte(source, cursor)
			if nextByte ~= nil and nextByte >= 48 and nextByte <= 57 then
				fail("RESULT_REPORT_E_JSON", path)
			end
		elseif first ~= nil and first >= 49 and first <= 57 then
			repeat
				cursor += 1
			until cursor > length or string.byte(source, cursor) < 48 or string.byte(source, cursor) > 57
		else
			fail("RESULT_REPORT_E_JSON", path)
		end

		if string.byte(source, cursor) == 46 then
			cursor += 1
			local fraction = string.byte(source, cursor)
			if fraction == nil or fraction < 48 or fraction > 57 then
				fail("RESULT_REPORT_E_JSON", path)
			end
			repeat
				cursor += 1
			until cursor > length or string.byte(source, cursor) < 48 or string.byte(source, cursor) > 57
		end

		local exponent = string.byte(source, cursor)
		if exponent == 69 or exponent == 101 then
			cursor += 1
			local sign = string.byte(source, cursor)
			if sign == 43 or sign == 45 then
				cursor += 1
			end
			local digit = string.byte(source, cursor)
			if digit == nil or digit < 48 or digit > 57 then
				fail("RESULT_REPORT_E_JSON", path)
			end
			repeat
				cursor += 1
			until cursor > length or string.byte(source, cursor) < 48 or string.byte(source, cursor) > 57
		end

		local text = string.sub(source, start, cursor - 1)
		local value = tonumber(text)
		local nonzeroSignificand = false
		for index = start, cursor - 1 do
			local byte = string.byte(source, index)
			if byte == 69 or byte == 101 then
				break
			elseif byte >= 49 and byte <= 57 then
				nonzeroSignificand = true
			end
		end
		if value == nil or value ~= value or value == math.huge or value == -math.huge
			or (value == 0 and (string.byte(text, 1) == 45 or nonzeroSignificand))
		then
			fail("RESULT_REPORT_E_JSON", path)
		end
	end

	local parseValue
	parseValue = function(depth: number)
		skipWhitespace()
		bump()
		local byte = string.byte(source, cursor)
		if byte == 123 then
			if depth + 1 > JSON_DEPTH_MAX then
				fail("RESULT_REPORT_E_JSON", path)
			end
			cursor += 1
			skipWhitespace()
			local keys = {}
			if string.byte(source, cursor) == 125 then
				cursor += 1
				return
			end
			while true do
				local key = parseString(true) :: string
				bump()
				if keys[key] then
					fail("RESULT_REPORT_E_JSON", path)
				end
				keys[key] = true
				skipWhitespace()
				if string.byte(source, cursor) ~= 58 then
					fail("RESULT_REPORT_E_JSON", path)
				end
				cursor += 1
				parseValue(depth + 1)
				skipWhitespace()
				local separator = string.byte(source, cursor)
				if separator == 125 then
					cursor += 1
					break
				end
				if separator ~= 44 then
					fail("RESULT_REPORT_E_JSON", path)
				end
				cursor += 1
				skipWhitespace()
			end
		elseif byte == 91 then
			if depth + 1 > JSON_DEPTH_MAX then
				fail("RESULT_REPORT_E_JSON", path)
			end
			cursor += 1
			skipWhitespace()
			if string.byte(source, cursor) == 93 then
				cursor += 1
				return
			end
			while true do
				parseValue(depth + 1)
				skipWhitespace()
				local separator = string.byte(source, cursor)
				if separator == 93 then
					cursor += 1
					break
				end
				if separator ~= 44 then
					fail("RESULT_REPORT_E_JSON", path)
				end
				cursor += 1
			end
		elseif byte == 34 then
			parseString(false)
		elseif byte == 116 and string.sub(source, cursor, cursor + 3) == "true" then
			cursor += 4
		elseif byte == 102 and string.sub(source, cursor, cursor + 4) == "false" then
			cursor += 5
		elseif byte == 110 and string.sub(source, cursor, cursor + 3) == "null" then
			fail("RESULT_REPORT_E_JSON", path)
		elseif byte == 45 or (byte ~= nil and byte >= 48 and byte <= 57) then
			parseNumber()
		else
			fail("RESULT_REPORT_E_JSON", path)
		end
	end

	parseValue(0)
	skipWhitespace()
	if cursor ~= length + 1 then
		fail("RESULT_REPORT_E_JSON", path)
	end
end

local function parsePaths(arguments: { string }): { string }
	if #arguments < 4 or #arguments % 2 ~= 0 then
		fail("RESULT_REPORT_E_ARGS")
	end
	local paths = table.create(#arguments / 2)
	local seen = {}
	for index = 1, #arguments, 2 do
		if arguments[index] ~= "--result" or type(arguments[index + 1]) ~= "string" or #arguments[index + 1] == 0 then
			fail("RESULT_REPORT_E_ARGS")
		end
		local path = arguments[index + 1]
		if seen[path] then
			fail("RESULT_REPORT_E_DUPLICATE_PATH", path)
		end
		seen[path] = true
		table.insert(paths, path)
	end
	return paths
end

local function loadResult(path: string): any
	local expectedSize = resultFileSize(path)
	local readOk, body = pcall(fs.readFile, path)
	if not readOk or type(body) ~= "string" then
		fail("RESULT_REPORT_E_READ", path)
	end
	if #body ~= expectedSize then
		fail("RESULT_REPORT_E_READ", path)
	end

	jsonPreflight(body, path)
	local decodeOk, decoded = pcall(serde.decode, "json", body)
	if not decodeOk then
		fail("RESULT_REPORT_E_JSON", path)
	end
	local schema = if type(decoded) == "table" then rawget(decoded, "schema") else nil
	local schemaId = if type(schema) == "table" then rawget(schema, "id") else nil
	local validator = if schemaId == ResultV1.ID then ResultV1.validate
		elseif schemaId == ResultV2.ID then ResultV2.validate else nil
	if validator == nil then fail("RESULT_REPORT_E_SCHEMA", path) end
	local validateOk, result = pcall(validator, decoded)
	if not validateOk then
		fail("RESULT_REPORT_E_SCHEMA", path .. ":" .. tostring(result))
	end
	return result
end

local paths = parsePaths(process.args)
local entries = table.create(#paths)
for _, path in paths do
	table.insert(entries, { path = path, result = loadResult(path) })
end
print(ResultReporter.render(entries))
