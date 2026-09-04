--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local EventV1 = require("../contracts/event-v1")
local AdapterIdentity = require("../contracts/internal/AdapterIdentity")
local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local RepetitionFragmentV1 = require("../contracts/internal/RepetitionFragmentV1")
local ResultV1 = require("../contracts/result-v1")
local ResultDraftAssembler = require("../runner/ResultDraftAssembler")
local Acquisition = require("../../scripts/acquire-benchmark-libraries")
local ExternalAdapterCatalog = require("./ExternalAdapterCatalog")
local GeneratedAdapters = require("./GeneratedAdapters")

local FRAME_PREFIX = "RELAY_TERMINAL_V1"
local FRAME_CHUNK_BYTES = 1_024
local MAX_OUTPUT_LOG_BYTES = ResultV1.MAX_JSON_BYTES * 2 + 4_194_304
local JSON_DEPTH_MAX = 10
local JSON_OBJECT_KEY_BYTES_MAX = 128
local JSON_TOKEN_MAX = 131_072
local CONTROL_TIMEOUT_SECONDS = 240
local BENCHMARK_TIMEOUT_SECONDS = 7_440
local PROCESS_REPETITION_TIMEOUT_SECONDS = 300
local KILL_CONFIRM_SECONDS = 10
local PROCESS_REPETITIONS = 30
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

local function assertStudioIdle(osName: string, execute: any)
	if osName ~= "windows" then return end
	local ok, result = pcall(execute, "powershell.exe", {
		"-NoProfile", "-NonInteractive", "-Command",
		[[
$ErrorActionPreference = 'Stop'
$running = Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -eq 'RobloxStudioBeta' -or $_.ProcessName -eq 'RobloxStudio' }
if ($null -ne $running) { 'Busy' } else { 'Idle' }
]],
	})
	if not ok or type(result) ~= "table" or result.ok ~= true
		or type(result.stdout) ~= "string" or #result.stdout > 16
	then
		fail("HOST_E_STUDIO_CHECK")
	end
	local state = string.gsub(result.stdout, "%s+$", "")
	if state == "Busy" then fail("HOST_E_STUDIO_BUSY") end
	if state ~= "Idle" then fail("HOST_E_STUDIO_CHECK") end
end

local function parseArgs(arguments: { string }, osName: string): any
	if (#arguments ~= 8 and #arguments ~= 10)
		or arguments[1] ~= "--studio"
		or arguments[3] ~= "--mode"
		or arguments[5] ~= "--case"
		or arguments[7] ~= "--recipients"
	then
		fail("HOST_E_ARGS")
	end
	local adapterId = "native-reliable"
	if #arguments == 10 then
		if arguments[9] ~= "--adapter"
			or (
				arguments[10] ~= "native-reliable"
				and arguments[10] ~= "relay-reliable"
				and not ExternalAdapterCatalog.isExternal(arguments[10])
			)
		then fail("HOST_E_ARGS") end
		adapterId = arguments[10]
	end
	local external = ExternalAdapterCatalog.isExternal(adapterId)
	if adapterId == "suphi-packet" then
		fail("HOST_E_EXTERNAL_UNSUPPORTED_SUPHI_FRAME_BOUND")
	end
	if external and osName ~= "windows" then fail("HOST_E_EXTERNAL_OS") end
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
		if external then fail("HOST_E_ARGS") end
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
		adapterId = adapterId,
		external = external,
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

local function assertCleanSource(root: string, expectedRevision: string?, execute: any)
	local revision = string.gsub(command(execute, "git", { "rev-parse", "HEAD" }, root), "%s+$", "")
	if expectedRevision ~= nil and revision ~= expectedRevision then fail("HOST_E_SOURCE_CHANGED") end
	local status = command(execute, "git", {
		"status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none",
	}, root)
	if #status ~= 0 then fail("HOST_E_SOURCE_DIRTY") end
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

local function collectRelayAdapter(revision: string, placeBytes: string, robloxApi: any, hash: any): any
	local dataModel = robloxApi.deserializePlace(placeBytes)
	local storage = dataModel:FindFirstChild("ReplicatedStorage")
	local relay = if storage == nil then nil else storage:FindFirstChild("Relay")
	if relay == nil or relay.ClassName ~= "ModuleScript" then fail("HOST_E_SOURCE") end
	local entries = {}
	local function collect(module: any, path: string)
		if module.ClassName == "ModuleScript" then
			local bytes = module.Source
			table.insert(entries, `{#path}:{path}{#bytes}:{bytes}`)
		elseif module.ClassName ~= "Folder" then
			fail("HOST_E_SOURCE")
		end
		local children = module:GetChildren()
		table.sort(children, function(left, right) return left.Name < right.Name end)
		for _, child in children do
			collect(child, path .. "/" .. child.Name)
		end
	end
	collect(relay, "Relay")
	local checksum = sha256(hash, table.concat(entries), "HOST_E_SOURCE")
	local source = relay.Source
	local libraryVersion = string.match(source, 'VERSION%s*=%s*"([^"]+)"')
	if libraryVersion == nil then fail("HOST_E_SOURCE") end
	return {
		moduleId = "relay-reliable",
		artifact = { kind = "RepositoryModule", digest = checksum },
		identity = {
			id = "relay-reliable", displayName = "Relay Reliable", lane = "EquivalentSemantics",
			integrationKind = "Runtime",
			library = {
				id = "relay", displayName = "Relay", version = libraryVersion,
				provenance = {
					kind = "Repository", sourceRepository = "https://github.com/steven-dinh/relay",
					revision = revision, checksum = checksum, license = "MIT",
				},
			},
			semantics = {
				broadcastMode = "NativeBroadcast", intentionalAddedDeliveryFrames = 0,
				repetitionIsolation = "SessionRestart",
			},
			capabilities = {
				directions = { "ClientToServer", "ServerToClient" },
				deliverySemantics = { "ReliableOrdered" }, payloadIds = { "state", "tiny" },
			},
		},
	}
end

local function collectExternalAdapter(selectedEntry: any, placeBytes: string, robloxApi: any, hash: any): any
	local dataModel = robloxApi.deserializePlace(placeBytes)
	local replicatedStorage = dataModel:FindFirstChild("ReplicatedStorage")
	local benchmark = if replicatedStorage == nil then nil else replicatedStorage:FindFirstChild("RelayBenchmark")
	local adapters = if benchmark == nil then nil else benchmark:FindFirstChild("adapters")
	local selectedBinding = if adapters == nil then nil else adapters:FindFirstChild("ExternalSelected")
	local sharedBinding = if adapters == nil then nil else adapters:FindFirstChild("ExternalAdapter")
	local serverStorage = dataModel:FindFirstChild("ServerStorage")
	local serverRoot = if serverStorage == nil then nil else serverStorage:FindFirstChild("RelayBenchmarkServer")
	local template = if serverRoot == nil then nil else serverRoot:FindFirstChild("ExternalTemplate")
	if selectedBinding == nil or sharedBinding == nil or template == nil then fail("HOST_E_EXTERNAL_PROJECT") end
	local entries = {}
	local function collect(instance: any, path: string)
		if instance.ClassName == "ModuleScript" then
			local bytes = instance.Source
			table.insert(entries, `{#path}:{path}{#bytes}:{bytes}`)
		elseif instance.ClassName ~= "Folder" then
			fail("HOST_E_EXTERNAL_PROJECT")
		end
		local children = instance:GetChildren()
		table.sort(children, function(left, right) return left.Name < right.Name end)
		for _, child in children do collect(child, path .. "/" .. child.Name) end
	end
	collect(selectedBinding, "ExternalSelected")
	collect(sharedBinding, "ExternalAdapter")
	collect(template, "ExternalTemplate")
	local digest = sha256(hash, table.concat(entries), "HOST_E_EXTERNAL_PROJECT")
	return ExternalAdapterCatalog.adapter(selectedEntry, digest, "external-runtime")
end

local function nativeManifest(launchId: string, studioVersion: string, selection: any, facts: any, adapter: any?): any
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
	if adapter ~= nil then candidate.adapter = adapter end
	local checked = HostManifestV1.validate(candidate)
	if checked.kind ~= "Valid" then fail("HOST_E_MANIFEST") end
	return checked.value
end

local function carrierData(launchId: string, capability: string, options: any, facts: any, adapter: any?): any
	return {
		version = 1,
		launchId = launchId,
		capability = capability,
		mode = options.mode,
		recipientCount = options.recipientCount,
		selection = options.selection,
		benchmarkSource = facts.benchmarkSource,
		contractFingerprint = facts.contractFingerprint,
		host = facts.host,
		adapter = adapter,
	}
end

local function processCarrierData(
	launchId: string,
	capability: string,
	batchId: string,
	repetitionIndex: number,
	options: any,
	facts: any,
	adapter: any
): any
	local carrier = carrierData(launchId, capability, {
		mode = "ProcessRepetition",
		recipientCount = options.recipientCount,
		selection = options.selection,
	}, facts, adapter)
	carrier.batchId = batchId
	carrier.repetitionIndex = repetitionIndex
	return carrier
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
	if carrier.adapter ~= nil then
		local replicatedStorage = dataModel:FindFirstChild("ReplicatedStorage")
		local benchmark = if replicatedStorage == nil then nil else replicatedStorage:FindFirstChild("RelayBenchmark")
		local adapters = if benchmark == nil then nil else benchmark:FindFirstChild("adapters")
		local processIsolated = carrier.adapter.identity.semantics.repetitionIsolation == "ProcessRestart"
		local pinName = if processIsolated then "ExternalAdapterPin" else "RelayAdapterPin"
		if adapters == nil or adapters:FindFirstChild(pinName) ~= nil then fail("HOST_E_PLACE") end
		local pin = robloxApi.Instance.new("ModuleScript")
		pin.Name = pinName
		pin.Source = "return " .. luauLiteral(carrier.adapter)
		pin.Parent = adapters
	end
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
		if not ok then
			local diagnostic = string.sub(string.gsub(tostring(value), "[%c\127]", "?"), 1, 256)
			print(`DIAGNOSTIC Relay.EventV1.ResultSchema {diagnostic}`)
			pcall(function()
				for _, measurement in rawget(decoded, "measurements") do
					local summary = rawget(measurement, "summary")
					if type(summary) == "table" and rawget(summary, "kind") == "MedianAndP95" then
						local values = {}
						for _, group in rawget(measurement, "rawSamples") do
							for _, sample in rawget(group, "values") do table.insert(values, sample) end
						end
						table.sort(values)
						local count = #values
						local median = if count % 2 == 1 then values[(count + 1) / 2]
							else values[count / 2] + (values[count / 2 + 1] - values[count / 2]) / 2
						local rank = math.floor((95 * count + 99) / 100)
						local metadata = rawget(measurement, "metadata")
						local id = if type(metadata) == "table" then rawget(metadata, "id") else "unknown"
						print(string.format(
							"DIAGNOSTIC Relay.EventV1.Summary %s median=%.17g recomputed=%.17g p95=%.17g recomputedP95=%.17g",
							string.sub(string.gsub(tostring(id), "[%c\127]", "?"), 1, 64),
							rawget(summary, "median"),
							median,
							rawget(summary, "p95"),
							values[rank]
						))
					end
				end
			end)
			fail("HOST_E_SCHEMA")
		end
		return table.freeze({ kind = "Result", value = value })
	end
	if rawget(decoded, "schema") == "RelayRepetitionFragmentV1" then
		if #body > RepetitionFragmentV1.MAX_JSON_BYTES then fail("HOST_E_JSON") end
		local ok, value = pcall(RepetitionFragmentV1.validate, decoded)
		if not ok or value.kind ~= "Valid" then fail("HOST_E_SCHEMA") end
		return table.freeze({ kind = "RepetitionFragment", value = value.value })
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

local function prepareFragmentCollector(
	manifestCandidate: any,
	batchId: string,
	repetitionIndex: number
): any
	local checked = HostManifestV1.validate(manifestCandidate)
	if checked.kind ~= "Valid"
		or checked.value.adapter.identity.semantics.repetitionIsolation ~= "ProcessRestart"
		or type(batchId) ~= "string"
		or type(repetitionIndex) ~= "number"
		or repetitionIndex < 1
		or repetitionIndex > PROCESS_REPETITIONS
		or repetitionIndex % 1 ~= 0
	then
		fail("HOST_E_MANIFEST")
	end
	return table.freeze({
		kind = "Fragment",
		manifest = checked.value,
		batchId = batchId,
		repetitionIndex = repetitionIndex,
	})
end

local function validateFragmentProvenance(fragment: any, launchId: string, collector: any): boolean
	if type(fragment) ~= "table"
		or type(collector) ~= "table"
		or collector.kind ~= "Fragment"
		or collector.manifest.launchId ~= launchId
		or fragment.batchId ~= collector.batchId
		or fragment.repetitionIndex ~= collector.repetitionIndex
		or type(fragment.manifest) ~= "table"
		or fragment.manifest.launchId ~= launchId
		or not deepEqual(fragment.manifest, collector.manifest)
	then
		fail("HOST_E_PROVENANCE")
	end
	return true
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
	if decoded.kind == "RepetitionFragment" then
		local fragment = decoded.value
		validateFragmentProvenance(fragment, launchId, collector)
		return table.freeze({ kind = "RepetitionFragment", value = fragment })
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

local function completeBenchmark(terminal: any): any
	local publication = commitTerminal(terminal)
	if terminal.value.status ~= "Valid" then
		fail(`HOST_E_RESULT_{string.upper(terminal.value.status)}`)
	end
	return publication
end

local function collectBody(body: string, launchId: string, collector: any?): any
	local terminal = validateDecodedBody(body, launchId, collector, decodeRoot(body, launchId))
	if terminal.kind == "Result" then return commitTerminal(terminal) end
	return terminal
end

local function canonicalPositiveInteger(source: any, maximum: number): number?
	if type(source) ~= "string" or #source == 0 or #source > 10
		or string.match(source, "^%d+$") == nil or string.sub(source, 1, 1) == "0"
	then
		return nil
	end
	local value = tonumber(source)
	if value == nil or value > maximum or math.floor(value) ~= value or tostring(value) ~= source then
		return nil
	end
	return value
end

local function decodeLowerHex(source: any): string
	if type(source) ~= "string" or #source == 0 or #source % 2 ~= 0
		or string.match(source, "^[0-9a-f]+$") == nil
	then
		fail("HOST_E_FRAME")
	end
	local decoded = table.create(#source / 2)
	for index = 1, #source, 2 do
		decoded[(index + 1) / 2] = string.char(
			hexNibble(string.byte(source, index)) * 16 + hexNibble(string.byte(source, index + 1))
		)
	end
	return table.concat(decoded)
end

local function collectTerminalLog(
	output: string,
	capability: string,
	launchId: string,
	mode: string,
	collectorFactory: any
): any?
	if type(output) ~= "string" or #output > MAX_OUTPUT_LOG_BYTES then fail("HOST_E_OUTPUT_LIMIT") end
	if mode ~= "ControlProof" and mode ~= "Benchmark" and mode ~= "ProcessRepetition" then fail("HOST_E_ARGS") end
	if type(collectorFactory) ~= "function" then fail("HOST_E_MANIFEST") end
	local maximumBodyBytes = if mode == "ProcessRepetition"
		then RepetitionFragmentV1.MAX_JSON_BYTES
		else ResultV1.MAX_JSON_BYTES

	local bodyLength = nil
	local chunkCount = nil
	local studioVersion = nil
	local chunks = {}
	local nextChunk = 1
	local complete = false
	local frameStart = FRAME_PREFIX .. " "
	for line in string.gmatch(output, "[^\r\n]+") do
		if string.sub(line, 1, #frameStart) == frameStart then
			local remainder = string.sub(line, #frameStart + 1)
			local separator = string.find(remainder, " ", 1, true)
			local candidate = if separator == nil then remainder else string.sub(remainder, 1, separator - 1)
			if constantWorkCapability(candidate, capability) then
				if separator == nil or complete then fail("HOST_E_FRAME") end
				local authenticated = string.sub(remainder, separator + 1)
				local frameKind = string.match(authenticated, "^([^ ]+)")
				if frameKind == "BEGIN" then
					if bodyLength ~= nil then fail("HOST_E_FRAME") end
					local framedLaunchId, versionHex, lengthText, countText = string.match(
						authenticated,
						"^BEGIN ([^ ]+) ([0-9a-f]+) (%d+) (%d+)$"
					)
					if framedLaunchId ~= launchId or versionHex == nil or #versionHex > 128 then fail("HOST_E_FRAME") end
					local parsedLength = canonicalPositiveInteger(lengthText, maximumBodyBytes)
					local parsedCount = canonicalPositiveInteger(countText, math.ceil(maximumBodyBytes / FRAME_CHUNK_BYTES))
					if parsedLength == nil or parsedCount == nil
						or parsedCount ~= math.ceil(parsedLength / FRAME_CHUNK_BYTES)
					then
						fail("HOST_E_FRAME")
					end
					local decodedVersion = decodeLowerHex(versionHex)
					if #decodedVersion == 0 or #decodedVersion > 64 then fail("HOST_E_FRAME") end
					bodyLength = parsedLength
					chunkCount = parsedCount
					studioVersion = decodedVersion
				elseif frameKind == "CHUNK" then
					if bodyLength == nil or chunkCount == nil or nextChunk > chunkCount then fail("HOST_E_FRAME") end
					local framedLaunchId, indexText, chunkHex = string.match(
						authenticated,
						"^CHUNK ([^ ]+) (%d+) ([0-9a-f]+)$"
					)
					local parsedIndex = canonicalPositiveInteger(indexText, chunkCount)
					local expectedBytes = math.min(FRAME_CHUNK_BYTES, bodyLength - (nextChunk - 1) * FRAME_CHUNK_BYTES)
					if framedLaunchId ~= launchId or parsedIndex ~= nextChunk or chunkHex == nil
						or #chunkHex ~= expectedBytes * 2
					then
						fail("HOST_E_FRAME")
					end
					chunks[nextChunk] = decodeLowerHex(chunkHex)
					nextChunk += 1
				elseif frameKind == "END" then
					local framedLaunchId, lengthText, countText = string.match(
						authenticated,
						"^END ([^ ]+) (%d+) (%d+)$"
					)
					if bodyLength == nil or chunkCount == nil or framedLaunchId ~= launchId
						or lengthText ~= tostring(bodyLength) or countText ~= tostring(chunkCount)
						or nextChunk ~= chunkCount + 1
					then
						fail("HOST_E_FRAME")
					end
					complete = true
				else
					fail("HOST_E_FRAME")
				end
			end
		end
	end
	if bodyLength == nil then return nil end
	if not complete then fail("HOST_E_FRAME") end
	local body = table.concat(chunks)
	if #body ~= bodyLength then fail("HOST_E_FRAME") end
	local decoded = decodeRoot(body, launchId)
	if mode == "ControlProof" then
		if decoded.kind ~= "ControlProof" and decoded.kind ~= "HarnessTermination" then fail("HOST_E_SCHEMA") end
	elseif mode == "Benchmark" and decoded.kind ~= "Result" and decoded.kind ~= "HarnessTermination" then
		fail("HOST_E_SCHEMA")
	elseif mode == "ProcessRepetition"
		and decoded.kind ~= "RepetitionFragment"
		and decoded.kind ~= "HarnessTermination"
	then
		fail("HOST_E_SCHEMA")
	end
	local collector = collectorFactory(studioVersion)
	return validateDecodedBody(body, launchId, collector, decoded)
end

local function outputFileSize(path: string, osName: string, execute: any): number
	local result
	if osName == "windows" then
		result = execute("powershell.exe", {
			"-NoProfile", "-NonInteractive", "-Command",
			[[& { $ErrorActionPreference='Stop';$value=(Get-Item -LiteralPath $args[0] -Force).Length;[Console]::Out.Write($value) }]],
			path,
		})
	elseif osName == "macos" then
		result = execute("/usr/bin/stat", { "-f", "%z", path })
	else
		fail("HOST_E_OS")
	end
	if type(result) ~= "table" or result.ok ~= true or type(result.stdout) ~= "string" or #result.stdout > 32 then
		fail("HOST_E_OUTPUT")
	end
	local digits = string.match(result.stdout, "^([0-9]+)%s*$")
	if digits == nil or #digits > 15 then fail("HOST_E_OUTPUT") end
	local size = tonumber(digits)
	if size == nil or size < 0 or math.floor(size) ~= size then fail("HOST_E_OUTPUT") end
	return size
end

local function readTerminalFile(
	path: string,
	osName: string,
	execute: any,
	readFile: any,
	capability: string,
	launchId: string,
	mode: string,
	collectorFactory: any
): any?
	local size = outputFileSize(path, osName, execute)
	if size > MAX_OUTPUT_LOG_BYTES then fail("HOST_E_OUTPUT_LIMIT") end
	local output = readFile(path)
	if type(output) ~= "string" or #output ~= size or #output > MAX_OUTPUT_LOG_BYTES then fail("HOST_E_OUTPUT") end
	return collectTerminalLog(output, capability, launchId, mode, collectorFactory)
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

local function reserveNamedPaths(
	paths: any,
	names: { string },
	ownerValue: string,
	isFile: any,
	writeExclusive: any,
	removeFile: any
): any
	local owned = {}
	for _, name in names do owned[name] = false end
	for _, name in names do
		if not pcall(writeExclusive, paths[name], if name == "lock" then ownerValue else "") then
			for _, cleanupName in names do
				if owned[cleanupName] and isFile(paths[cleanupName]) then pcall(removeFile, paths[cleanupName]) end
			end
			fail("HOST_E_COLLISION")
		end
		owned[name] = true
	end
	return owned
end

local function cleanupNamedPaths(paths: any, names: { string }, owned: any, isFile: any, removeFile: any): boolean
	local clean = true
	for _, name in names do
		if owned[name] == true and type(paths[name]) == "string" and isFile(paths[name]) then
			if not pcall(removeFile, paths[name]) then clean = false end
		end
	end
	return clean
end

local function bootstrapSource(): string
	local source = [[local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")
local serverRoot = ServerStorage:WaitForChild("RelayBenchmarkServer")
local carrierModule = serverRoot:WaitForChild("LaunchCarrier")
local carrier = require(carrierModule)
carrierModule:Destroy()
local FRAME_PREFIX = "__RELAY_FRAME_PREFIX__"
local FRAME_CHUNK_BYTES = __RELAY_FRAME_CHUNK_BYTES__
local MAX_JSON_BYTES = __RELAY_MAX_JSON_BYTES__

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
if carrier.adapter ~= nil then manifestCandidate.adapter = carrier.adapter end
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
	local testArguments = {
		version = 1,
		launchId = carrier.launchId,
		mode = carrier.mode,
		recipientCount = carrier.recipientCount,
	}
	if carrier.mode == "ProcessRepetition" then
		testArguments.batchId = carrier.batchId
		testArguments.repetitionIndex = carrier.repetitionIndex
	end
	return StudioTestService:ExecuteMultiplayerTestAsync(carrier.recipientCount, testArguments)
end)
if manifestModule ~= nil then pcall(function() manifestModule:Destroy() end) end
local body
if executeOk and carrier.mode == "ControlProof" and result == "RelayStudioControlProofV1" then
	body = '{"kind":"RelayStudioControlProofV1","launchId":"' .. carrier.launchId .. '"}'
elseif executeOk and (carrier.mode == "Benchmark" or carrier.mode == "ProcessRepetition")
	and type(result) == "string"
then
	body = result
else
	body = HttpService:JSONEncode({
		kind = "RelayHarnessTerminationV1",
		code = "FinalizationFailure",
		stage = "Finalize",
	})
end
if type(body) ~= "string" or #body == 0 or #body > MAX_JSON_BYTES then
	body = HttpService:JSONEncode({
		kind = "RelayHarnessTerminationV1",
		code = "FinalizationFailure",
		stage = "Finalize",
	})
end

local HEX = "0123456789abcdef"
local function encodeHex(value)
	local encoded = table.create(#value * 2)
	for index = 1, #value do
		local byte = string.byte(value, index)
		encoded[index * 2 - 1] = string.sub(HEX, math.floor(byte / 16) + 1, math.floor(byte / 16) + 1)
		encoded[index * 2] = string.sub(HEX, byte % 16 + 1, byte % 16 + 1)
	end
	return table.concat(encoded)
end

local chunkCount = math.ceil(#body / FRAME_CHUNK_BYTES)
print(FRAME_PREFIX .. " " .. carrier.capability .. " BEGIN " .. carrier.launchId .. " "
	.. encodeHex(studioVersion) .. " " .. tostring(#body) .. " " .. tostring(chunkCount))
for index = 1, chunkCount do
	local first = (index - 1) * FRAME_CHUNK_BYTES + 1
	local chunk = string.sub(body, first, first + FRAME_CHUNK_BYTES - 1)
	print(FRAME_PREFIX .. " " .. carrier.capability .. " CHUNK " .. carrier.launchId .. " "
		.. tostring(index) .. " " .. encodeHex(chunk))
end
print(FRAME_PREFIX .. " " .. carrier.capability .. " END " .. carrier.launchId .. " "
	.. tostring(#body) .. " " .. tostring(chunkCount))
]]
	source = string.gsub(source, "__RELAY_FRAME_PREFIX__", FRAME_PREFIX)
	source = string.gsub(source, "__RELAY_FRAME_CHUNK_BYTES__", tostring(FRAME_CHUNK_BYTES))
	source = string.gsub(source, "__RELAY_MAX_JSON_BYTES__", tostring(ResultV1.MAX_JSON_BYTES))
	return source
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
	confirmExit(readStatus, now, wait, killConfirmSeconds or KILL_CONFIRM_SECONDS)
	-- Lune 0.10.5 publishes synthetic status after requesting a kill, without
	-- waiting for OS exit. That acknowledgement cannot authorize file cleanup.
	return table.freeze({ kind = "Timeout", childExited = false })
end

local function collectProcessFragments(
	batchId: string,
	nextLaunchId: (number) -> string,
	launch: (string, number) -> any
): { any }
	local used = { [batchId] = true }
	local fragments = table.create(PROCESS_REPETITIONS)
	for repetitionIndex = 1, PROCESS_REPETITIONS do
		local launchId = nextLaunchId(repetitionIndex)
		if type(launchId) ~= "string" or used[launchId] then fail("HOST_E_LAUNCH_ID") end
		used[launchId] = true
		local fragment = launch(launchId, repetitionIndex)
		if type(fragment) ~= "table"
			or fragment.batchId ~= batchId
			or fragment.repetitionIndex ~= repetitionIndex
			or type(fragment.manifest) ~= "table"
			or fragment.manifest.launchId ~= launchId
		then
			fail("HOST_E_FRAGMENT")
		end
		fragments[repetitionIndex] = fragment
	end
	table.freeze(fragments)
	return fragments
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

local function buildProject(
	root: string,
	projectPath: string,
	outputPath: string,
	execute: any,
	isFile: any,
	readFile: any
): string
	local result = execute("rojo", {
		"build",
		projectPath,
		"--output",
		outputPath,
	}, { cwd = root })
	if type(result) ~= "table" or result.ok ~= true or not isFile(outputPath) then fail("HOST_E_BUILD") end
	local placeBytes = readFile(outputPath)
	if type(placeBytes) ~= "string" or #placeBytes == 0 then fail("HOST_E_BUILD") end
	return placeBytes
end

local function buildPlace(root: string, outputPath: string, execute: any, isFile: any, readFile: any): string
	return buildProject(root, "benchmarks/event-v1.project.json", outputPath, execute, isFile, readFile)
end

local function verifyExternalArtifacts(selectedEntry: any, acquisition: any?, generatedAdapters: any?)
	local acquisitionModule = acquisition or Acquisition
	local generationModule = generatedAdapters or GeneratedAdapters
	acquisitionModule.verifyInstalled(selectedEntry.library)
	if selectedEntry.generatedId ~= nil then generationModule.verifyGenerated(selectedEntry.generatedId) end
end

local function prepareExternalProject(
	root: string,
	adapterId: string,
	bindingProjectPath: string,
	readFile: any,
	decodeJson: any,
	encodeJson: any,
	acquisition: any?,
	generatedAdapters: any?
): any
	local acquisitionModule = acquisition or Acquisition
	local lock = acquisitionModule.validateLock(decodeJson(readFile(root .. "/benchmarks/libraries.lock.json")))
	local selectedEntry = ExternalAdapterCatalog.selected(lock, adapterId)
	verifyExternalArtifacts(selectedEntry, acquisitionModule, generatedAdapters)
	local baseProject = decodeJson(readFile(root .. "/benchmarks/event-v1.project.json"))
	local bindingBody = readFile(root .. "/benchmarks/" .. selectedEntry.adapterPath)
	if type(bindingBody) ~= "string" or #bindingBody == 0 then fail("HOST_E_EXTERNAL_PROJECT") end
	local project = ExternalAdapterCatalog.composeProject(baseProject, selectedEntry, bindingProjectPath)
	local body = encodeJson(project)
	if type(body) ~= "string" or #body == 0 or #body > 1_048_576 then fail("HOST_E_EXTERNAL_PROJECT") end
	return table.freeze({ selected = selectedEntry, body = body, bindingBody = bindingBody })
end

local function runExternal(options: any, root: string)
	if process.os ~= "windows" then fail("HOST_E_EXTERNAL_OS") end
	assertCleanSource(root, nil, process.exec)
	assertStudioIdle(process.os, process.exec)
	local function secureRandom(count: number): string
		return randomHex(count, process.os, process.exec)
	end
	local batchId = uuidV4(secureRandom)
	print(`BEGIN Relay.EventV1.External {options.adapterId} {options.caseId}/{options.recipientCount} {batchId}`)
	local batchPrefix = root .. `/.tmp/relay-external-batch-{batchId}`
	local batchPaths = {
		lock = batchPrefix .. ".lock",
		project = batchPrefix .. ".project.json",
		binding = batchPrefix .. ".binding.luau",
		basePlace = batchPrefix .. ".base.rbxlx",
		bootstrap = batchPrefix .. ".luau",
	}
	local batchNames = { "lock", "project", "binding", "basePlace", "bootstrap" }
	local batchOwned = reserveNamedPaths(batchPaths, batchNames, batchId, fs.isFile, function(path, value)
		fs.writeFile(path, value, { overwrite = false })
	end, fs.removeFile)
	local batchCleanupAuthorized = true

	local ok, result = pcall(function()
		local preparedProject = prepareExternalProject(
			root,
			options.adapterId,
			`./relay-external-batch-{batchId}.binding.luau`,
			fs.readFile,
			function(value) return serde.decode("json", value) end,
			function(value) return serde.encode("json", value) end
		)
		fs.writeFile(batchPaths.project, preparedProject.body, { overwrite = true })
		fs.writeFile(batchPaths.binding, preparedProject.bindingBody, { overwrite = true })
		local basePlace = buildProject(
			root,
			batchPaths.project,
			batchPaths.basePlace,
			process.exec,
			fs.isFile,
			fs.readFile
		)
		verifyExternalArtifacts(preparedProject.selected)
		local facts = collectSourceFacts(
			root,
			process.os,
			process.arch,
			process.exec,
			fs.readFile,
			serde.hash,
			basePlace
		)
		if facts.benchmarkSource.dirty then fail("HOST_E_SOURCE_DIRTY") end
		local adapter = collectExternalAdapter(preparedProject.selected, basePlace, roblox, serde.hash)
		fs.writeFile(batchPaths.bootstrap, bootstrapSource(), { overwrite = true })
		local studioVersion: string? = nil

		local fragments = collectProcessFragments(batchId, function(_repetitionIndex)
			return uuidV4(secureRandom)
		end, function(launchId, repetitionIndex)
			local capability = secureRandom(32)
			local childPrefix = root .. `/.tmp/relay-external-{launchId}`
			local childPaths = {
				lock = childPrefix .. ".lock",
				launchPlace = childPrefix .. ".rbxlx",
				output = childPrefix .. ".log",
			}
			local childNames = { "lock", "launchPlace", "output" }
			local childOwned = reserveNamedPaths(childPaths, childNames, launchId, fs.isFile, function(path, value)
				fs.writeFile(path, value, { overwrite = false })
			end, fs.removeFile)
			local child = nil
			local status = nil
			local killRequested = false
			local function requestChildKill()
				killRequested = true
				killChild(child)
			end
			local childOk, outcome = pcall(function()
				local carrier = processCarrierData(
					launchId,
					capability,
					batchId,
					repetitionIndex,
					options,
					facts,
					adapter
				)
				local generatedPlace = launchPlaceBytes(basePlace, carrier, roblox)
				fs.writeFile(childPaths.launchPlace, generatedPlace, { overwrite = true })
				assertStudioIdle(process.os, process.exec)
				child = process.create(
					options.studio,
					studioArguments(childPaths.launchPlace, batchPaths.bootstrap, childPaths.output),
					{ cwd = root }
				)
				task.spawn(function() status = childStatus(child) end)
				drain(child.stdout)
				drain(child.stderr)
				return awaitOutcome(
					function() return status end,
					function()
						return readTerminalFile(
							childPaths.output,
							process.os,
							process.exec,
							fs.readFile,
							capability,
							launchId,
							"ProcessRepetition",
							function(candidateStudioVersion)
								if studioVersion ~= nil and candidateStudioVersion ~= studioVersion then
									fail("HOST_E_STUDIO_CHANGED")
								end
								local manifest = nativeManifest(
									launchId,
									candidateStudioVersion,
									options.selection,
									facts,
									adapter
								)
								return prepareFragmentCollector(manifest, batchId, repetitionIndex)
							end
						)
					end,
					requestChildKill,
					os.clock,
					task.wait,
					PROCESS_REPETITION_TIMEOUT_SECONDS
				)
			end)
			local childExited = child == nil or (status ~= nil and not killRequested)
			if not childOk and child ~= nil and not childExited then
				if not killRequested then pcall(requestChildKill) end
				confirmExit(function() return status end, os.clock, task.wait, KILL_CONFIRM_SECONDS)
				childExited = false
			elseif childOk then
				childExited = outcome.childExited
			end
			if not childExited then
				batchCleanupAuthorized = false
				fail("HOST_E_CHILD_LIVE")
			end
			local censusOk, censusError = pcall(assertStudioIdle, process.os, process.exec)
			if not censusOk then
				batchCleanupAuthorized = false
				error(censusError, 0)
			end
			local cleaned = cleanupNamedPaths(childPaths, childNames, childOwned, fs.isFile, fs.removeFile)
			if not cleaned then fail("HOST_E_CLEANUP") end
			if not childOk then error(outcome, 0) end
			if outcome.kind ~= "Complete" then fail(`HOST_E_{string.upper(outcome.kind)}`) end
			if outcome.terminal.kind == "HarnessTermination" then
				fail(`HOST_E_TERMINATION_{outcome.terminal.value.code}_{outcome.terminal.value.stage}`)
			elseif outcome.terminal.kind ~= "RepetitionFragment" then
				fail("HOST_E_FRAGMENT")
			end
			local fragment = outcome.terminal.value
			studioVersion = studioVersion or fragment.manifest.environment.studio.version
			print(`PROGRESS Relay.EventV1.External {options.adapterId} {batchId} {repetitionIndex}/{PROCESS_REPETITIONS}`)
			return fragment
		end)

		if studioVersion == nil then fail("HOST_E_FRAGMENT") end
		local assemblyInput = { runId = batchId, fragments = fragments }
		table.freeze(assemblyInput)
		local assembled = ResultDraftAssembler.assembleFragments(assemblyInput)
		if assembled.kind == "Terminated" then
			fail(`HOST_E_TERMINATION_{assembled.termination.code}_{assembled.termination.stage}`)
		elseif assembled.kind ~= "Draft" then
			fail("HOST_E_FINALIZATION")
		end
		local finalResult = ResultV1.validate(ResultV1.finalize(assembled.value))
		local finalManifest = nativeManifest(batchId, studioVersion, options.selection, facts, adapter)
		if not matchesManifest(finalResult, finalManifest) then fail("HOST_E_PROVENANCE") end
		local body = serde.encode("json", finalResult)
		if type(body) ~= "string" or #body == 0 or #body > ResultV1.MAX_JSON_BYTES then fail("HOST_E_JSON") end
		local collector = prepareCollector(finalManifest, root .. "/benchmarks/results/local")
		local terminal = validateDecodedBody(body, batchId, collector, decodeRoot(body, batchId))
		return table.freeze({
			terminal = terminal,
			revision = facts.benchmarkSource.revision,
			selected = preparedProject.selected,
		})
	end)
	if not batchCleanupAuthorized then
		if not ok then error(result, 0) end
		fail("HOST_E_CHILD_LIVE")
	end
	local cleaned = cleanupNamedPaths(batchPaths, batchNames, batchOwned, fs.isFile, fs.removeFile)
	if not cleaned then fail("HOST_E_CLEANUP") end
	if not ok then error(result, 0) end
	verifyExternalArtifacts(result.selected)
	assertCleanSource(root, result.revision, process.exec)
	local publication = completeBenchmark(result.terminal)
	print(`PASS Relay.EventV1.External {options.adapterId} {batchId} {publication.path}`)
end

local function main(arguments: { string })
	local options = parseArgs(arguments, process.os)
	if not fs.isFile(options.studio) then fail("HOST_E_STUDIO") end
	assertStudioIdle(process.os, process.exec)
	local root = string.gsub(process.cwd, "\\", "/")
	local temporaryDirectory = root .. "/.tmp"
	if not fs.isDir(temporaryDirectory) then
		local made = pcall(fs.writeDir, temporaryDirectory)
		if not made or not fs.isDir(temporaryDirectory) then fail("HOST_E_PATH") end
	end
	if options.external then
		runExternal(options, root)
		return
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
	local killRequested = false
	local function requestChildKill()
		killRequested = true
		killChild(child)
	end
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
		local adapter = if options.adapterId == "relay-reliable" then collectRelayAdapter(
			facts.benchmarkSource.revision, basePlace, roblox, serde.hash
		) else nil
		local function collectorFactory(studioVersion)
			local manifest = nativeManifest(launchId, studioVersion, options.selection, facts, adapter)
			return prepareCollector(manifest, root .. "/benchmarks/results/local")
		end
		local carrier = carrierData(launchId, capability, options, facts, adapter)
		local generatedPlace = launchPlaceBytes(basePlace, carrier, roblox)
		fs.writeFile(paths.launchPlace, generatedPlace, { overwrite = true })
		fs.writeFile(paths.bootstrap, bootstrapSource(), { overwrite = true })
		-- Studio multiplayer uses a shared server.rbxl even with unique places.
		-- Recheck after the build; this is a preflight, not an atomic launch lock.
		assertStudioIdle(process.os, process.exec)
		child = process.create(options.studio, studioArguments(paths.launchPlace, paths.bootstrap, paths.output), { cwd = root })
		task.spawn(function()
			status = childStatus(child)
		end)
		drain(child.stdout)
		drain(child.stderr)
		return awaitOutcome(
			function() return status end,
			function()
				return readTerminalFile(
					paths.output,
					process.os,
					process.exec,
					fs.readFile,
					capability,
					launchId,
					options.mode,
					collectorFactory
				)
			end,
			requestChildKill,
			os.clock,
			task.wait,
			if options.mode == "ControlProof" then CONTROL_TIMEOUT_SECONDS else BENCHMARK_TIMEOUT_SECONDS
		)
	end)
	local childExited = child == nil or (status ~= nil and not killRequested)
	if not ok and child ~= nil and not childExited then
		if not killRequested then pcall(requestChildKill) end
		confirmExit(function() return status end, os.clock, task.wait, KILL_CONFIRM_SECONDS)
		childExited = false
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
		local publication = completeBenchmark(outcome.terminal)
		print(`PASS Relay.EventV1.Benchmark {launchId} {publication.path}`)
	end
end

local Host = table.freeze({
	parseArgs = parseArgs,
	assertStudioIdle = assertStudioIdle,
	randomHex = randomHex,
	uuidV4 = uuidV4,
	envelope = envelope,
	constantWorkCapability = constantWorkCapability,
	MAX_OUTPUT_LOG_BYTES = MAX_OUTPUT_LOG_BYTES,
	jsonPreflight = jsonPreflight,
	decodeRoot = decodeRoot,
	matchesManifest = matchesManifest,
	prepareCollector = prepareCollector,
	publishResult = publishResult,
	commitTerminal = commitTerminal,
	completeBenchmark = completeBenchmark,
	collectBody = collectBody,
	collectTerminalLog = collectTerminalLog,
	outputFileSize = outputFileSize,
	readTerminalFile = readTerminalFile,
	cleanupLaunchFiles = cleanupLaunchFiles,
	cleanupProtectedLaunch = cleanupProtectedLaunch,
	reserveLaunchPaths = reserveLaunchPaths,
	reserveNamedPaths = reserveNamedPaths,
	cleanupNamedPaths = cleanupNamedPaths,
	collectSourceFacts = collectSourceFacts,
	assertCleanSource = assertCleanSource,
	collectRelayAdapter = collectRelayAdapter,
	collectExternalAdapter = collectExternalAdapter,
	nativeManifest = nativeManifest,
	carrierData = carrierData,
	processCarrierData = processCarrierData,
	launchPlaceBytes = launchPlaceBytes,
	prepareFragmentCollector = prepareFragmentCollector,
	validateFragmentProvenance = validateFragmentProvenance,
	bootstrapSource = bootstrapSource,
	studioArguments = studioArguments,
	awaitOutcome = awaitOutcome,
	childStatus = childStatus,
	killChild = killChild,
	buildPlace = buildPlace,
	buildProject = buildProject,
	verifyExternalArtifacts = verifyExternalArtifacts,
	prepareExternalProject = prepareExternalProject,
	collectProcessFragments = collectProcessFragments,
	confirmExit = confirmExit,
	main = main,
})

return Host
