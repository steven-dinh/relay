--!strict

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local EventV1 = require("../contracts/event-v1")
local AdapterIdentity = require("../contracts/internal/AdapterIdentity")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local ResultV1 = require("../contracts/result-v1")

local PATH = "/relay-event-v1/v1"
local CAPABILITY_HEADER = "x-relay-capability"
local STUDIO_VERSION_HEADER = "x-relay-studio-version"
local CONTENT_TYPE = "application/json"
local ADDRESS = "http://127.0.0.1"
local PORT_MIN = 49_152
local PORT_SPAN = 16_384
local PORT_ATTEMPTS = 64
local HEADER_COUNT_MAX = 32
local HEADER_NAME_MAX = 64
local HEADER_VALUE_MAX = 1_024
local HEADER_BYTES_MAX = 8_192
local JSON_DEPTH_MAX = 6
local JSON_OBJECT_KEY_BYTES_MAX = 128
local JSON_TOKEN_MAX = 131_072
local CONTROL_TIMEOUT_SECONDS = 240
local BENCHMARK_TIMEOUT_SECONDS = 7_440
local KILL_CONFIRM_SECONDS = 10
local SENTINEL = "RelayStudioControlProofV1"
local PENDING_RESULT_MARKER = {}

local function fail(code: string): never
	error(code, 0)
end

local function isAbsolute(path: string, osName: string): boolean
	if osName == "windows" then
		return string.match(path, "^%a:[/\\]") ~= nil
	elseif osName == "macos" then
		return string.sub(path, 1, 1) == "/"
	end
	return false
end

local function parseArgs(arguments: { string }, osName: string): any
	if #arguments ~= 8
		or arguments[1] ~= "--studio"
		or arguments[3] ~= "--mode"
		or arguments[5] ~= "--case"
		or arguments[7] ~= "--recipients"
	then
		fail("HOST_E_ARGS")
	end
	local studio = arguments[2]
	local mode = arguments[4]
	local caseId = arguments[6]
	local recipientText = arguments[8]
	local recipientCount = tonumber(recipientText)
	if not isAbsolute(studio, osName)
		or (mode ~= "ControlProof" and mode ~= "Benchmark")
		or recipientCount == nil
		or tostring(recipientCount) ~= recipientText
	then
		fail("HOST_E_ARGS")
	end
	local selection
	if mode == "ControlProof" then
		if caseId ~= "state-broadcast-s2c"
			or (recipientCount ~= 1 and recipientCount ~= 4 and recipientCount ~= 8)
		then
			fail("HOST_E_ARGS")
		end
		selection = {
			kind = "Workload",
			workloadId = caseId,
			recipientCount = recipientCount,
		}
	elseif caseId == "tiny-round-trip" and recipientCount == 1 then
		selection = { kind = "SeparateProbe", probeId = caseId }
	elseif (caseId == "tiny-steady-c2s" or caseId == "state-steady-c2s" or caseId == "state-burst-c2s")
		and recipientCount == 1
	then
		selection = {
			kind = "Workload",
			workloadId = caseId,
			recipientCount = recipientCount,
		}
	elseif caseId == "state-broadcast-s2c"
		and (recipientCount == 1 or recipientCount == 4 or recipientCount == 8)
	then
		selection = {
			kind = "Workload",
			workloadId = caseId,
			recipientCount = recipientCount,
		}
	else
		fail("HOST_E_ARGS")
	end
	table.freeze(selection)
	return table.freeze({
		studio = studio,
		mode = mode,
		caseId = caseId,
		recipientCount = recipientCount,
		selection = selection,
	})
end

local function cleanHex(value: string): string
	return string.lower(string.gsub(value, "%s", ""))
end

local function randomHex(byteCount: number, osName: string, execute: any): string
	local result
	if osName == "windows" then
		local script = string.format(
			"$b=New-Object byte[] %d;[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b);-join($b|ForEach-Object{$_.ToString('x2')})",
			byteCount
		)
		result = execute("powershell.exe", { "-NoProfile", "-NonInteractive", "-Command", script })
	elseif osName == "macos" then
		result = execute("/usr/bin/od", { "-An", `-N{byteCount}`, "-tx1", "/dev/urandom" })
	else
		fail("HOST_E_OS")
	end
	if type(result) ~= "table" or result.ok ~= true or type(result.stdout) ~= "string" then
		fail("HOST_E_RANDOM")
	end
	local value = cleanHex(result.stdout)
	if #value ~= byteCount * 2 or string.match(value, "^[0-9a-f]+$") == nil then
		fail("HOST_E_RANDOM")
	end
	return value
end

local function uuidV4(random: (number) -> string): string
	local source = random(16)
	if #source ~= 32 or string.match(source, "^[0-9a-f]+$") == nil then
		fail("HOST_E_RANDOM")
	end
	local bytes = table.create(16)
	for index = 1, 16 do
		bytes[index] = tonumber(string.sub(source, index * 2 - 1, index * 2), 16)
	end
	bytes[7] = bit32.bor(bit32.band(bytes[7], 0x0f), 0x40)
	bytes[9] = bit32.bor(bit32.band(bytes[9], 0x3f), 0x80)
	local hex = table.create(16)
	for index, byte in bytes do
		hex[index] = string.format("%02x", byte)
	end
	local joined = table.concat(hex)
	return string.format(
		"%s-%s-%s-%s-%s",
		string.sub(joined, 1, 8),
		string.sub(joined, 9, 12),
		string.sub(joined, 13, 16),
		string.sub(joined, 17, 20),
		string.sub(joined, 21, 32)
	)
end

local function randomPort(random: (number) -> string): number
	local value = random(2)
	if #value ~= 4 or string.match(value, "^[0-9a-f]+$") == nil then
		fail("HOST_E_RANDOM")
	end
	return PORT_MIN + (tonumber(value, 16) :: number) % PORT_SPAN
end

local function envelope(launchId: string): string
	return '{"kind":"' .. SENTINEL .. '","launchId":"' .. launchId .. '"}'
end

local function command(execute: any, program: string, arguments: { string }, root: string): string
	local result = execute(program, arguments, { cwd = root })
	if type(result) ~= "table" or result.ok ~= true or type(result.stdout) ~= "string" then
		fail("HOST_E_SOURCE")
	end
	return result.stdout
end

local function sha256(hash: any, value: string, code: string): string
	local digest = hash("sha256", value)
	if type(digest) ~= "string" or #digest ~= 64 or string.match(digest, "^[0-9a-f]+$") == nil then
		fail(code)
	end
	return "sha256:" .. digest
end

local function collectSourceFacts(
	root: string,
	osName: string,
	architecture: string,
	execute: any,
	readFile: any,
	hash: any,
	placeBytes: string
): any
	local revision = string.gsub(command(execute, "git", { "rev-parse", "HEAD" }, root), "%s+$", "")
	if (#revision ~= 40 and #revision ~= 64) or string.match(revision, "^[0-9a-f]+$") == nil then
		fail("HOST_E_SOURCE")
	end
	local dirty = #command(execute, "git", {
		"status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none",
	}, root) > 0
	local contract = readFile(root .. "/benchmarks/contracts/event-v1.luau")
	if type(contract) ~= "string" then fail("HOST_E_SOURCE") end
	contract = string.gsub(string.gsub(contract, "\r\n", "\n"), "\r", "\n")
	if type(placeBytes) ~= "string" or #placeBytes == 0 then fail("HOST_E_PLACE") end
	local contractFingerprint = sha256(hash, contract, "HOST_E_SOURCE")
	local placeFingerprint = sha256(hash, placeBytes, "HOST_E_PLACE")
	local osFamily = if osName == "windows" then "Windows" elseif osName == "macos" then "macOS" else nil
	local hostArchitecture = if architecture == "x86_64" then "x86_64" elseif architecture == "aarch64" then "arm64" else nil
	if osFamily == nil or hostArchitecture == nil then fail("HOST_E_OS") end
	return table.freeze({
		benchmarkSource = table.freeze({
			revision = revision,
			dirty = dirty,
			placeFingerprint = placeFingerprint,
		}),
		contractFingerprint = contractFingerprint,
		host = table.freeze({ osFamily = osFamily, architecture = hostArchitecture }),
	})
end

local function luauLiteral(value: any): string
	local kind = type(value)
	if kind == "string" then return string.format("%q", value) end
	if kind == "number" or kind == "boolean" then return tostring(value) end
	if kind ~= "table" then fail("HOST_E_CARRIER") end
	local keys = {}
	for key in value do
		if type(key) ~= "string" and type(key) ~= "number" then fail("HOST_E_CARRIER") end
		table.insert(keys, key)
	end
	table.sort(keys, function(left, right)
		if type(left) == type(right) then return left < right end
		return type(left) < type(right)
	end)
	local fields = table.create(#keys)
	for index, key in keys do
		fields[index] = "[" .. luauLiteral(key) .. "]=" .. luauLiteral(rawget(value, key))
	end
	return "{" .. table.concat(fields, ",") .. "}"
end

local function nativeManifest(launchId: string, studioVersion: string, selection: any, facts: any): any
	local candidate = {
		version = 1,
		launchId = launchId,
		benchmarkSource = facts.benchmarkSource,
		contractFingerprint = facts.contractFingerprint,
		adapter = {
			moduleId = "native-reliable",
			artifact = { kind = "EngineBuiltIn" },
			identity = {
				id = "native-reliable",
				displayName = "Roblox RemoteEvent",
				lane = "EquivalentSemantics",
				integrationKind = "EngineBuiltIn",
				library = {
					id = "roblox-remote-event",
					displayName = "Roblox RemoteEvent",
					version = studioVersion,
					provenance = { kind = "EngineBuiltIn", studioVersion = studioVersion },
				},
				semantics = {
					broadcastMode = "NativeBroadcast",
					intentionalAddedDeliveryFrames = 0,
					repetitionIsolation = "SessionRestart",
				},
				capabilities = {
					directions = { "ClientToServer", "ServerToClient" },
					deliverySemantics = { "ReliableOrdered" },
					payloadIds = { "state", "tiny" },
				},
			},
		},
		selection = selection,
		environment = {
			studio = { version = studioVersion },
			host = facts.host,
		},
	}
	local checked = HostManifestV1.validate(candidate)
	if checked.kind ~= "Valid" then fail("HOST_E_MANIFEST") end
	return checked.value
end

local function carrierData(launchId: string, capability: string, port: number, options: any, facts: any): any
	return {
		version = 1,
		launchId = launchId,
		capability = capability,
		port = port,
		mode = options.mode,
		recipientCount = options.recipientCount,
		selection = options.selection,
		benchmarkSource = facts.benchmarkSource,
		contractFingerprint = facts.contractFingerprint,
		host = facts.host,
	}
end

local function launchPlaceBytes(placeBytes: string, carrier: any, robloxApi: any): (string, string)
	local dataModel = robloxApi.deserializePlace(placeBytes)
	local serverStorage = dataModel:FindFirstChild("ServerStorage")
	local serverRoot = if serverStorage == nil then nil else serverStorage:FindFirstChild("RelayBenchmarkServer")
	if serverRoot == nil or serverRoot:FindFirstChild("LaunchCarrier") ~= nil then fail("HOST_E_PLACE") end
	local source = "return " .. luauLiteral(carrier)
	local module = robloxApi.Instance.new("ModuleScript")
	module.Name = "LaunchCarrier"
	module.Source = source
	module.Parent = serverRoot
	return robloxApi.serializePlace(dataModel, true), source
end

local function hexNibble(byte: number?): number
	if byte == nil then return 0 end
	if byte >= 48 and byte <= 57 then return byte - 48 end
	if byte >= 97 and byte <= 102 then return byte - 87 end
	return 0
end

local function constantWorkCapability(actual: any, expected: string): boolean
	local candidate = if type(actual) == "string" then actual else ""
	local difference = if #candidate == 64 then 0 else 1
	for index = 1, 32 do
		local offset = index * 2 - 1
		local leftHigh = string.byte(candidate, offset)
		local leftLow = string.byte(candidate, offset + 1)
		local rightHigh = string.byte(expected, offset)
		local rightLow = string.byte(expected, offset + 1)
		if leftHigh == nil or leftLow == nil
			or not ((leftHigh >= 48 and leftHigh <= 57) or (leftHigh >= 97 and leftHigh <= 102))
			or not ((leftLow >= 48 and leftLow <= 57) or (leftLow >= 97 and leftLow <= 102))
		then
			difference = bit32.bor(difference, 1)
		end
		local left = hexNibble(leftHigh) * 16 + hexNibble(leftLow)
		local right = hexNibble(rightHigh) * 16 + hexNibble(rightLow)
		difference = bit32.bor(difference, bit32.bxor(left, right))
	end
	return difference == 0
end

local function jsonPreflight(source: string): boolean
	if type(source) ~= "string" or #source > ResultV1.MAX_JSON_BYTES then fail("HOST_E_JSON") end
	local length = #source
	local cursor = 1
	local tokens = 0

	local function bump()
		tokens += 1
		if tokens > JSON_TOKEN_MAX then fail("HOST_E_JSON") end
	end

	local function skipWhitespace()
		while cursor <= length do
			local byte = string.byte(source, cursor)
			if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then break end
			cursor += 1
		end
	end

	local function hexValue(byte: number?): number?
		if byte == nil then return nil end
		if byte >= 48 and byte <= 57 then return byte - 48 end
		if byte >= 65 and byte <= 70 then return byte - 55 end
		if byte >= 97 and byte <= 102 then return byte - 87 end
		return nil
	end

	local function readCodeUnit(): number
		local value = 0
		for _ = 1, 4 do
			local digit = hexValue(string.byte(source, cursor))
			if digit == nil then fail("HOST_E_JSON") end
			value = value * 16 + digit
			cursor += 1
		end
		return value
	end

	local function parseString(capture: boolean): string?
		if string.byte(source, cursor) ~= 34 then fail("HOST_E_JSON") end
		cursor += 1
		local output = if capture then {} else nil
		local outputBytes = 0
		local function appendOutput(value: string)
			if output == nil then return end
			outputBytes += #value
			if outputBytes > JSON_OBJECT_KEY_BYTES_MAX then fail("HOST_E_JSON") end
			table.insert(output, value)
		end
		while cursor <= length do
			local byte = string.byte(source, cursor)
			if byte == 34 then
				cursor += 1
				return if output == nil then nil else table.concat(output)
			elseif byte == nil or byte < 32 then
				fail("HOST_E_JSON")
			elseif byte ~= 92 then
				appendOutput(string.char(byte))
				cursor += 1
			else
				cursor += 1
				local escaped = string.byte(source, cursor)
				if escaped == nil then fail("HOST_E_JSON") end
				cursor += 1
				if escaped == 117 then
					local codepoint = readCodeUnit()
					if codepoint >= 0xD800 and codepoint <= 0xDBFF then
						if string.sub(source, cursor, cursor + 1) ~= "\\u" then fail("HOST_E_JSON") end
						cursor += 2
						local low = readCodeUnit()
						if low < 0xDC00 or low > 0xDFFF then fail("HOST_E_JSON") end
						codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + low - 0xDC00
					elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
						fail("HOST_E_JSON")
					end
					appendOutput(utf8.char(codepoint))
				else
					local decoded = ({
						[34] = '"', [92] = "\\", [47] = "/", [98] = "\b",
						[102] = "\f", [110] = "\n", [114] = "\r", [116] = "\t",
					})[escaped]
					if decoded == nil then fail("HOST_E_JSON") end
					appendOutput(decoded)
				end
			end
		end
		fail("HOST_E_JSON")
	end

	local function parseNumber()
		local start = cursor
		if string.byte(source, cursor) == 45 then cursor += 1 end
		local first = string.byte(source, cursor)
		if first == 48 then
			cursor += 1
			local nextByte = string.byte(source, cursor)
			if nextByte ~= nil and nextByte >= 48 and nextByte <= 57 then fail("HOST_E_JSON") end
		elseif first ~= nil and first >= 49 and first <= 57 then
			repeat cursor += 1
			until cursor > length or string.byte(source, cursor) < 48 or string.byte(source, cursor) > 57
		else
			fail("HOST_E_JSON")
		end
		if string.byte(source, cursor) == 46 then
			cursor += 1
			local fraction = string.byte(source, cursor)
			if fraction == nil or fraction < 48 or fraction > 57 then fail("HOST_E_JSON") end
			repeat cursor += 1
			until cursor > length or string.byte(source, cursor) < 48 or string.byte(source, cursor) > 57
		end
		local exponent = string.byte(source, cursor)
		if exponent == 69 or exponent == 101 then
			cursor += 1
			local sign = string.byte(source, cursor)
			if sign == 43 or sign == 45 then cursor += 1 end
			local digit = string.byte(source, cursor)
			if digit == nil or digit < 48 or digit > 57 then fail("HOST_E_JSON") end
			repeat cursor += 1
			until cursor > length or string.byte(source, cursor) < 48 or string.byte(source, cursor) > 57
		end
		local text = string.sub(source, start, cursor - 1)
		local value = tonumber(text)
		if value == nil or value ~= value or value == math.huge or value == -math.huge
			or (value == 0 and string.byte(text, 1) == 45)
		then
			fail("HOST_E_JSON")
		end
	end

	local parseValue
	parseValue = function(depth: number)
		skipWhitespace()
		bump()
		local byte = string.byte(source, cursor)
		if byte == 123 then
			if depth + 1 > JSON_DEPTH_MAX then fail("HOST_E_JSON") end
			cursor += 1
			skipWhitespace()
			local keys = {}
			if string.byte(source, cursor) == 125 then cursor += 1 return end
			while true do
				local key = parseString(true) :: string
				bump()
				if keys[key] then fail("HOST_E_JSON") end
				keys[key] = true
				skipWhitespace()
				if string.byte(source, cursor) ~= 58 then fail("HOST_E_JSON") end
				cursor += 1
				parseValue(depth + 1)
				skipWhitespace()
				local separator = string.byte(source, cursor)
				if separator == 125 then cursor += 1 break end
				if separator ~= 44 then fail("HOST_E_JSON") end
				cursor += 1
				skipWhitespace()
			end
		elseif byte == 91 then
			if depth + 1 > JSON_DEPTH_MAX then fail("HOST_E_JSON") end
			cursor += 1
			skipWhitespace()
			if string.byte(source, cursor) == 93 then cursor += 1 return end
			while true do
				parseValue(depth + 1)
				skipWhitespace()
				local separator = string.byte(source, cursor)
				if separator == 93 then cursor += 1 break end
				if separator ~= 44 then fail("HOST_E_JSON") end
				cursor += 1
			end
		elseif byte == 34 then
			parseString(false)
		elseif byte == 116 and string.sub(source, cursor, cursor + 3) == "true" then
			cursor += 4
		elseif byte == 102 and string.sub(source, cursor, cursor + 4) == "false" then
			cursor += 5
		elseif byte == 110 and string.sub(source, cursor, cursor + 3) == "null" then
			fail("HOST_E_JSON")
		elseif byte == 45 or (byte ~= nil and byte >= 48 and byte <= 57) then
			parseNumber()
		else
			fail("HOST_E_JSON")
		end
	end

	parseValue(0)
	skipWhitespace()
	if cursor ~= length + 1 then fail("HOST_E_JSON") end
	return true
end

local function boundedHeaders(headers: any): (boolean, { [string]: string })
	if type(headers) ~= "table" then return false, {} end
	local normalized = {}
	local count = 0
	local total = 0
	for name, value in headers do
		if type(name) ~= "string" or type(value) ~= "string" or #name == 0
			or #name > HEADER_NAME_MAX or #value > HEADER_VALUE_MAX
		then
			return false, {}
		end
		count += 1
		total += #name + #value
		if count > HEADER_COUNT_MAX or total > HEADER_BYTES_MAX then return false, {} end
		local lower = string.lower(name)
		if normalized[lower] ~= nil then return false, {} end
		normalized[lower] = value
	end
	return true, normalized
end

local function exactControlProof(value: any, launchId: string): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local count = 0
	for key in value do
		if key ~= "kind" and key ~= "launchId" then return false end
		count += 1
	end
	return count == 2 and rawget(value, "kind") == SENTINEL and rawget(value, "launchId") == launchId
end

local function decodeRoot(body: string, launchId: string): any
	jsonPreflight(body)
	local decodedOk, decoded = pcall(serde.decode, "json", body)
	if not decodedOk or type(decoded) ~= "table" then fail("HOST_E_SCHEMA") end
	if exactControlProof(decoded, launchId) then
		return table.freeze({ kind = "ControlProof" })
	end
	if rawget(decoded, "kind") == "RelayHarnessTerminationV1" then
		local ok, value = pcall(HarnessTerminationV1.validate, decoded)
		if not ok then fail("HOST_E_SCHEMA") end
		return table.freeze({ kind = "HarnessTermination", value = value })
	end
	if type(rawget(decoded, "schema")) == "table" and rawget(rawget(decoded, "schema"), "id") == "result-v1" then
		local ok, value = pcall(ResultV1.validate, decoded)
		if not ok then fail("HOST_E_SCHEMA") end
		return table.freeze({ kind = "Result", value = value })
	end
	fail("HOST_E_SCHEMA")
end

local function deepEqual(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	local count = 0
	for key, value in left do
		count += 1
		if rawget(right, key) == nil or not deepEqual(value, rawget(right, key)) then return false end
	end
	local rightCount = 0
	for _ in right do rightCount += 1 end
	return count == rightCount
end

local function expectedCase(manifest: any): any
	local selection = manifest.selection
	if selection.kind == "Workload" then
		for _, workload in EventV1.workloads do
			if workload.id == selection.workloadId then
				return {
					kind = "Workload",
					workloadId = workload.id,
					senderCount = workload.senderCount,
					recipientCount = selection.recipientCount,
					scheduledRepetitions = workload.repetitions,
				}
			end
		end
	else
		for _, probe in EventV1.probes do
			if probe.id == selection.probeId then
				return {
					kind = "SeparateProbe",
					probeId = probe.id,
					clientCount = probe.clientCount,
					scheduledRepetitions = probe.repetitions,
				}
			end
		end
	end
	fail("HOST_E_MANIFEST")
end

local function matchesManifest(result: any, manifest: any): boolean
	if result.runId ~= manifest.launchId
		or not deepEqual(result.benchmark.source, manifest.benchmarkSource)
		or result.contract.fingerprint ~= manifest.contractFingerprint
		or not deepEqual(result.adapter, manifest.adapter.identity)
		or not deepEqual(result.environment.studio, manifest.environment.studio)
		or not deepEqual(result.environment.host, manifest.environment.host)
	then
		return false
	end
	local caseExpectation = expectedCase(manifest)
	for key, value in caseExpectation do
		if rawget(result.case, key) ~= value then return false end
	end
	local resolved = AdapterIdentity.resolveSelection(manifest.selection)
	if resolved.kind ~= "Valid" then return false end
	return deepEqual(result.environment.execution, {
		mode = "StudioMultiplayer",
		targetFrameRate = EventV1.execution.targetFrameRate,
		serverCount = 1,
		clientCount = resolved.value.clientProcessCount,
	})
end

local DEFAULT_FILE_IO = table.freeze({
	writeExclusive = function(path: string, contents: string)
		fs.writeFile(path, contents, { overwrite = false })
	end,
	readFile = fs.readFile,
	move = fs.move,
	removeFile = fs.removeFile,
})

local function prepareCollector(manifestCandidate: any, outputDirectory: string, random: any?, fileIo: any?): any
	local checked = HostManifestV1.validate(manifestCandidate)
	if checked.kind ~= "Valid" or type(outputDirectory) ~= "string" or #outputDirectory == 0 then
		fail("HOST_E_MANIFEST")
	end
	local secureRandom = random or function(count: number)
		return randomHex(count, process.os, process.exec)
	end
	return table.freeze({
		manifest = checked.value,
		outputDirectory = string.gsub(outputDirectory, "[/\\]+$", ""),
		random = secureRandom,
		fileIo = fileIo or DEFAULT_FILE_IO,
	})
end

local function publishResult(body: string, result: any, collector: any): string
	if not matchesManifest(result, collector.manifest) then fail("HOST_E_PROVENANCE") end
	local random = collector.random(16)
	if type(random) ~= "string" or #random ~= 32 or string.match(random, "^[0-9a-f]+$") == nil then
		fail("HOST_E_RANDOM")
	end
	local directory = collector.outputDirectory
	local finalPath = directory .. "/" .. collector.manifest.launchId .. ".result-v1.json"
	local temporaryPath = directory .. "/." .. collector.manifest.launchId .. "." .. random .. ".tmp"
	local io = collector.fileIo
	local temporaryOwned = false
	local ok = pcall(function()
		io.writeExclusive(temporaryPath, body)
		temporaryOwned = true
		local readback = io.readFile(temporaryPath)
		if readback ~= body then fail("HOST_E_PUBLICATION") end
		local decoded = decodeRoot(readback, collector.manifest.launchId)
		if decoded.kind ~= "Result" or not matchesManifest(decoded.value, collector.manifest) then
			fail("HOST_E_PUBLICATION")
		end
		io.move(temporaryPath, finalPath)
		temporaryOwned = false
	end)
	if temporaryOwned then pcall(io.removeFile, temporaryPath) end
	if not ok then fail("HOST_E_PUBLICATION") end
	return finalPath
end

local function validateDecodedBody(body: string, launchId: string, collector: any?, decoded: any): any
	if decoded.kind == "ControlProof" and body ~= envelope(launchId) then fail("HOST_E_SCHEMA") end
	if decoded.kind == "Result" then
		if collector == nil or collector.manifest.launchId ~= launchId
			or not matchesManifest(decoded.value, collector.manifest)
		then
			fail("HOST_E_PROVENANCE")
		end
		return table.freeze({
			kind = "Result",
			marker = PENDING_RESULT_MARKER,
			body = body,
			value = decoded.value,
			collector = collector,
		})
	end
	return decoded
end

local function commitTerminal(terminal: any): any
	if type(terminal) ~= "table" or rawget(terminal, "kind") ~= "Result"
		or rawget(terminal, "marker") ~= PENDING_RESULT_MARKER
	then
		fail("HOST_E_PUBLICATION")
	end
	local path = publishResult(terminal.body, terminal.value, terminal.collector)
	return table.freeze({ kind = "Result", path = path })
end

local function collectBody(body: string, launchId: string, collector: any?): any
	local terminal = validateDecodedBody(body, launchId, collector, decodeRoot(body, launchId))
	if terminal.kind == "Result" then return commitTerminal(terminal) end
	return terminal
end

local function requestFields(request: any): (boolean, any, any, any, any, any)
	local requestType = type(request)
	if requestType == "table" then
		return true,
			rawget(request, "method"),
			rawget(request, "path"),
			rawget(request, "query"),
			rawget(request, "headers"),
			rawget(request, "body")
	end
	if requestType ~= "userdata" then return false, nil, nil, nil, nil, nil end
	local ok, method, path, query, headers, body = pcall(function()
		return request.method, request.path, request.query, request.headers, request.body
	end)
	return ok, method, path, query, headers, body
end

local function newHandler(capability: string, launchId: string, mode: string, collectorFactory: any): (any, () -> any?)
	if mode ~= "ControlProof" and mode ~= "Benchmark" then fail("HOST_E_ARGS") end
	if type(collectorFactory) ~= "function" then fail("HOST_E_MANIFEST") end
	local terminal = nil
	local claimInFlight = false
	local function reject()
		return { status = 404, body = "" }
	end
	local function handle(request: any): any
		local readOk, method, path, query, requestHeaders, body = requestFields(request)
		if terminal ~= nil or claimInFlight or not readOk or method ~= "POST" or path ~= PATH
			or type(query) ~= "table" or next(query) ~= nil or type(body) ~= "string"
			or #body > ResultV1.MAX_JSON_BYTES
		then
			return reject()
		end
		local validHeaders, headers = boundedHeaders(requestHeaders)
		if not validHeaders or headers["content-type"] ~= CONTENT_TYPE or headers["content-encoding"] ~= nil
			or not constantWorkCapability(headers[CAPABILITY_HEADER], capability)
			or type(headers[STUDIO_VERSION_HEADER]) ~= "string"
		then
			return reject()
		end
		claimInFlight = true
		local collected, value = pcall(function()
			local decoded = decodeRoot(body, launchId)
			if mode == "ControlProof" then
				if decoded.kind ~= "ControlProof" and decoded.kind ~= "HarnessTermination" then fail("HOST_E_SCHEMA") end
			elseif decoded.kind ~= "Result" and decoded.kind ~= "HarnessTermination" then
				fail("HOST_E_SCHEMA")
			end
			local collector = collectorFactory(headers[STUDIO_VERSION_HEADER])
			return validateDecodedBody(body, launchId, collector, decoded)
		end)
		if not collected then
			claimInFlight = false
			return reject()
		end
		terminal = value
		claimInFlight = false
		return { status = 204, body = "" }
	end
	return handle, function()
		return terminal
	end
end

local function bindListener(serve: any, random: (number) -> string, handler: any): (any, number)
	for _ = 1, PORT_ATTEMPTS do
		local port = randomPort(random)
		local ok, handle = pcall(serve, port, {
			address = ADDRESS,
			handleRequest = handler,
		})
		if ok then return handle, port end
	end
	fail("HOST_E_BIND")
end

local function closeListener(listener: any)
	pcall(function() listener:stop() end)
end

local function cleanupLaunchFiles(paths: any, owned: any, isFile: any, removeFile: any): boolean
	local clean = true
	for _, name in { "bootstrap", "launchPlace", "basePlace", "output", "lock" } do
		local path = rawget(paths, name)
		if rawget(owned, name) == true and type(path) == "string" and isFile(path) then
			if not pcall(removeFile, path) then clean = false end
		end
	end
	return clean
end

local function cleanupProtectedLaunch(
	childExited: boolean,
	paths: any,
	owned: any,
	isFile: any,
	removeFile: any
): boolean
	if not childExited then return false end
	return cleanupLaunchFiles(paths, owned, isFile, removeFile)
end

local function reserveLaunchPaths(paths: any, launchId: string, isFile: any, writeExclusive: any, removeFile: any): any
	local owned = {
		lock = false,
		basePlace = false,
		launchPlace = false,
		bootstrap = false,
		output = false,
	}
	if not pcall(writeExclusive, paths.lock, launchId) then fail("HOST_E_COLLISION") end
	owned.lock = true
	for _, name in { "basePlace", "launchPlace", "bootstrap", "output" } do
		if not pcall(writeExclusive, paths[name], "") then
			cleanupLaunchFiles(paths, owned, isFile, removeFile)
			fail("HOST_E_COLLISION")
		end
		owned[name] = true
	end
	return owned
end

local function bootstrapSource(): string
	return [[local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")
local serverRoot = ServerStorage:WaitForChild("RelayBenchmarkServer")
local carrierModule = serverRoot:WaitForChild("LaunchCarrier")
local carrier = require(carrierModule)
carrierModule:Destroy()

local function literal(value)
	local kind = type(value)
	if kind == "string" then return string.format("%q", value) end
	if kind == "number" or kind == "boolean" then return tostring(value) end
	assert(kind == "table", "manifest serialization rejected")
	local keys = {}
	for key in value do table.insert(keys, key) end
	table.sort(keys, function(left, right)
		if type(left) == type(right) then return left < right end
		return type(left) < type(right)
	end)
	local fields = {}
	for index, key in keys do fields[index] = "[" .. literal(key) .. "]=" .. literal(value[key]) end
	return "{" .. table.concat(fields, ",") .. "}"
end

local studioVersion = version()
local manifestCandidate = {
	version = 1,
	launchId = carrier.launchId,
	benchmarkSource = carrier.benchmarkSource,
	contractFingerprint = carrier.contractFingerprint,
	adapter = {
		moduleId = "native-reliable",
		artifact = { kind = "EngineBuiltIn" },
		identity = {
			id = "native-reliable",
			displayName = "Roblox RemoteEvent",
			lane = "EquivalentSemantics",
			integrationKind = "EngineBuiltIn",
			library = {
				id = "roblox-remote-event",
				displayName = "Roblox RemoteEvent",
				version = studioVersion,
				provenance = { kind = "EngineBuiltIn", studioVersion = studioVersion },
			},
			semantics = {
				broadcastMode = "NativeBroadcast",
				intentionalAddedDeliveryFrames = 0,
				repetitionIsolation = "SessionRestart",
			},
			capabilities = {
				directions = { "ClientToServer", "ServerToClient" },
				deliverySemantics = { "ReliableOrdered" },
				payloadIds = { "state", "tiny" },
			},
		},
	},
	selection = carrier.selection,
	environment = {
		studio = { version = studioVersion },
		host = carrier.host,
	},
}
local HostManifestV1 = require(ReplicatedStorage:WaitForChild("RelayBenchmark"):WaitForChild("contracts"):WaitForChild("internal"):WaitForChild("HostManifestV1"))
local manifestModule = nil
local executeOk, result = pcall(function()
	local checked = HostManifestV1.validate(manifestCandidate)
	assert(checked.kind == "Valid", "host manifest rejected")
	assert(serverRoot:FindFirstChild("HostManifest") == nil, "host manifest already exists")
	manifestModule = Instance.new("ModuleScript")
	manifestModule.Name = "HostManifest"
	manifestModule.Source = "return " .. literal(checked.value)
	manifestModule.Parent = serverRoot
	return StudioTestService:ExecuteMultiplayerTestAsync(carrier.recipientCount, {
		version = 1,
		launchId = carrier.launchId,
		mode = carrier.mode,
		recipientCount = carrier.recipientCount,
	})
end)
if manifestModule ~= nil then pcall(function() manifestModule:Destroy() end) end
local body
if executeOk and carrier.mode == "ControlProof" and result == "RelayStudioControlProofV1" then
	body = '{"kind":"RelayStudioControlProofV1","launchId":"' .. carrier.launchId .. '"}'
elseif executeOk and carrier.mode == "Benchmark" and type(result) == "string" then
	body = result
else
	body = HttpService:JSONEncode({
		kind = "RelayHarnessTerminationV1",
		code = "FinalizationFailure",
		stage = "Finalize",
	})
end
local response = HttpService:RequestAsync({
	Url = "http://127.0.0.1:" .. tostring(carrier.port) .. "/relay-event-v1/v1",
	Method = "POST",
	Headers = {
		["Content-Type"] = "application/json",
		["x-relay-capability"] = carrier.capability,
		["x-relay-studio-version"] = studioVersion,
	},
	Body = body,
})
assert(response.Success and response.StatusCode == 204, "terminal egress failed")
]]
end

local function studioArguments(placePath: string, bootstrapPath: string, outputPath: string): { string }
	return {
		"--task", "RunScript",
		"--localPlaceFile", placePath,
		"--runScriptFile", bootstrapPath,
		"--outputFile", outputPath,
		"--quitAfterExecution",
	}
end

local function confirmExit(
	readStatus: () -> any,
	now: () -> number,
	wait: (number) -> (),
	timeout: number
): boolean
	local deadline = now() + timeout
	repeat
		if readStatus() ~= nil then return true end
		wait(0.05)
	until now() >= deadline
	return readStatus() ~= nil
end

local function awaitOutcome(
	readStatus: () -> any,
	terminal: () -> any?,
	kill: () -> (),
	now: () -> number,
	wait: (number) -> (),
	timeout: number,
	killConfirmSeconds: number?
): any
	local deadline = now() + timeout
	while now() < deadline do
		local status = readStatus()
		if status ~= nil then
			local acceptedTerminal = terminal()
			if acceptedTerminal ~= nil and status.ok == true then
				return table.freeze({ kind = "Complete", terminal = acceptedTerminal, childExited = true })
			end
			return table.freeze({ kind = "ProcessFailure", childExited = true })
		end
		wait(0.05)
	end
	pcall(kill)
	local childExited = confirmExit(readStatus, now, wait, killConfirmSeconds or KILL_CONFIRM_SECONDS)
	return table.freeze({ kind = "Timeout", childExited = childExited })
end

local function drain(reader: any)
	task.spawn(function()
		while reader:read() ~= nil do end
	end)
end

local function childStatus(child: any): any
	return child:status()
end

local function killChild(child: any)
	child:kill()
end

local function buildPlace(root: string, outputPath: string, execute: any, isFile: any, readFile: any): string
	local result = execute("rojo", {
		"build",
		"benchmarks/event-v1.project.json",
		"--output",
		outputPath,
	}, { cwd = root })
	if type(result) ~= "table" or result.ok ~= true or not isFile(outputPath) then fail("HOST_E_BUILD") end
	local placeBytes = readFile(outputPath)
	if type(placeBytes) ~= "string" or #placeBytes == 0 then fail("HOST_E_BUILD") end
	return placeBytes
end

local function main(arguments: { string })
	local options = parseArgs(arguments, process.os)
	if not fs.isFile(options.studio) then fail("HOST_E_STUDIO") end
	local root = string.gsub(process.cwd, "\\", "/")
	local temporaryDirectory = root .. "/.tmp"
	if not fs.isDir(temporaryDirectory) then
		local made = pcall(fs.writeDir, temporaryDirectory)
		if not made or not fs.isDir(temporaryDirectory) then fail("HOST_E_PATH") end
	end
	local function secureRandom(count: number): string
		return randomHex(count, process.os, process.exec)
	end
	local launchId = uuidV4(secureRandom)
	local capability = secureRandom(32)
	local prefix = root .. `/.tmp/relay-launch-{launchId}`
	local paths = {
		lock = prefix .. ".lock",
		basePlace = prefix .. ".base.rbxlx",
		launchPlace = prefix .. ".rbxlx",
		bootstrap = prefix .. ".luau",
		output = prefix .. ".log",
	}
	local owned = reserveLaunchPaths(paths, launchId, fs.isFile, function(path, value)
		fs.writeFile(path, value, { overwrite = false })
	end, fs.removeFile)

	local child = nil
	local status = nil
	local listener = nil
	local ok, outcome = pcall(function()
		local basePlace = buildPlace(root, paths.basePlace, process.exec, fs.isFile, fs.readFile)
		local facts = collectSourceFacts(
			root,
			process.os,
			process.arch,
			process.exec,
			fs.readFile,
			serde.hash,
			basePlace
		)
		local handler, terminal = newHandler(capability, launchId, options.mode, function(studioVersion)
			local manifest = nativeManifest(launchId, studioVersion, options.selection, facts)
			return prepareCollector(manifest, root .. "/benchmarks/results/local")
		end)
		local port
		listener, port = bindListener(net.serve, secureRandom, handler)
		local carrier = carrierData(launchId, capability, port, options, facts)
		local generatedPlace = launchPlaceBytes(basePlace, carrier, roblox)
		fs.writeFile(paths.launchPlace, generatedPlace, { overwrite = true })
		fs.writeFile(paths.bootstrap, bootstrapSource(), { overwrite = true })
		child = process.create(options.studio, studioArguments(paths.launchPlace, paths.bootstrap, paths.output), { cwd = root })
		task.spawn(function()
			status = childStatus(child)
		end)
		drain(child.stdout)
		drain(child.stderr)
		return awaitOutcome(
			function() return status end,
			terminal,
			function() killChild(child) end,
			os.clock,
			task.wait,
			if options.mode == "ControlProof" then CONTROL_TIMEOUT_SECONDS else BENCHMARK_TIMEOUT_SECONDS
		)
	end)
	if listener ~= nil then closeListener(listener) end
	local childExited = child == nil or status ~= nil
	if not ok and child ~= nil and not childExited then
		pcall(killChild, child)
		childExited = confirmExit(function() return status end, os.clock, task.wait, KILL_CONFIRM_SECONDS)
	elseif ok then
		childExited = outcome.childExited
	end
	local cleaned = cleanupProtectedLaunch(childExited, paths, owned, fs.isFile, fs.removeFile)
	if not childExited then fail("HOST_E_CHILD_LIVE") end
	if not cleaned then fail("HOST_E_CLEANUP") end
	if not ok then
		error(outcome, 0)
	end
	if outcome.kind ~= "Complete" then fail(`HOST_E_{string.upper(outcome.kind)}`) end
	if outcome.terminal.kind == "HarnessTermination" then
		fail(`HOST_E_TERMINATION_{outcome.terminal.value.code}_{outcome.terminal.value.stage}`)
	elseif options.mode == "ControlProof" then
		print(`PASS Relay.EventV1.ControlProof {launchId}`)
	else
		local publication = commitTerminal(outcome.terminal)
		print(`PASS Relay.EventV1.Benchmark {launchId} {publication.path}`)
	end
end

local Host = table.freeze({
	parseArgs = parseArgs,
	randomHex = randomHex,
	uuidV4 = uuidV4,
	randomPort = randomPort,
	envelope = envelope,
	constantWorkCapability = constantWorkCapability,
	jsonPreflight = jsonPreflight,
	decodeRoot = decodeRoot,
	matchesManifest = matchesManifest,
	prepareCollector = prepareCollector,
	publishResult = publishResult,
	commitTerminal = commitTerminal,
	collectBody = collectBody,
	newHandler = newHandler,
	bindListener = bindListener,
	closeListener = closeListener,
	cleanupLaunchFiles = cleanupLaunchFiles,
	cleanupProtectedLaunch = cleanupProtectedLaunch,
	reserveLaunchPaths = reserveLaunchPaths,
	collectSourceFacts = collectSourceFacts,
	nativeManifest = nativeManifest,
	carrierData = carrierData,
	launchPlaceBytes = launchPlaceBytes,
	bootstrapSource = bootstrapSource,
	studioArguments = studioArguments,
	awaitOutcome = awaitOutcome,
	childStatus = childStatus,
	killChild = killChild,
	buildPlace = buildPlace,
	confirmExit = confirmExit,
	main = main,
})

if process.args[1] == "--studio" then
	main(process.args)
end

return Host
