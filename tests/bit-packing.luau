local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
Vector2, Vector3, CFrame, Color3 = roblox.Vector2, roblox.Vector3, roblox.CFrame, roblox.Color3
local support = require("./support/NativeCodec")
local Definition = require("../src/Definition")
local Frame = support.loadFrame()
local InstanceRefs = support.InstanceRefs
local Quantized = require("../src/internal/Quantized")
local BitPacking = require("../src/internal/BitPacking")
local LengthBounds = require("../src/internal/LengthBounds")
local NumericFormats = require("../src/internal/NumericFormats")
local OrderedFrame = require("../src/internal/OrderedFrame")
local Runtime = require("./support/ServerRuntime")
local ordered = require("../examples/reliable-events/ordered")

local enum32 = table.create(32)
for index = 1, 32 do enum32[index] = `Value{index}` end

local token, definitionIssue = Definition.define({ name = "BitPackingCodec", version = 1, bitPacking = true, events = {
	Flags = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "one", type = "enum", values = ordered("Only") },
		{ name = "three", type = "enum", values = ordered("A", "B", "C") },
		{ name = "thirtyTwo", type = "enum", values = ordered(table.unpack(enum32)) },
		{ name = "maybeBoolean", type = "optional", value = { type = "boolean" } },
		{ name = "maybeEnum", type = "optional", value = { type = "enum", values = ordered("A", "B", "C") } },
		{ name = "note", type = "optional", value = { type = "string", maximumBytes = 8 } },
		{ name = "tail", type = "u8" }
	) },
	Optional = { id = 2, direction = "ClientToServer", fields = ordered(
		{ name = "note", type = "optional", value = { type = "string", maximumBytes = 8 } },
		{ name = "enabled", type = "boolean" }
	) },
	Nested = { id = 3, direction = "ClientToServer", fields = ordered(
		{ name = "record", type = "struct", fields = ordered(
			{ name = "enabled", type = "boolean" },
			{ name = "mode", type = "enum", values = ordered("A", "B", "C") },
			{ name = "value", type = "u8" }
		) }
	) },
	Union = { id = 4, direction = "ClientToServer", fields = ordered(
		{ name = "choice", type = "taggedUnion", tag = "kind", variants = {
			Alpha = { type = "struct", fields = ordered(
				{ name = "enabled", type = "boolean" },
				{ name = "mode", type = "enum", values = ordered("A", "B", "C") },
				{ name = "value", type = "u8" }
			) },
			Beta = { type = "struct", fields = ordered(
				{ name = "maybe", type = "optional", value = { type = "boolean" } },
				{ name = "value", type = "u8" }
			) },
		} }
	) },
	Arrays = { id = 5, direction = "ClientToServer", fields = ordered(
		{ name = "booleans", type = "array", maximumLength = 64, element = { type = "boolean" } },
		{ name = "values", type = "array", maximumLength = 64, element = { type = "enum", values = ordered("A", "B", "C") } },
		{ name = "wide", type = "array", maximumLength = 64, element = { type = "enum", values = ordered(table.unpack(enum32)) } }
	) },
	Map = { id = 6, direction = "ClientToServer", fields = ordered(
		{ name = "values", type = "map", maximumSize = 4,
			key = { type = "string", maximumBytes = 8 },
			value = { type = "enum", values = ordered("A", "B", "C") } }
	) },
	InstanceMix = { id = 7, direction = "ClientToServer", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "target", type = "Instance", className = "BasePart" }
	) },
	CompactMix = { id = 8, direction = "ClientToServer", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "scalar", type = "quantized", minimum = 0, maximum = 10, step = 1 },
		{ name = "position", type = "quantizedVector3", minimum = -1, maximum = 1, step = 1 }
	) },
	Sets = { id = 9, direction = "ClientToServer", fields = ordered(
		{ name = "values", type = "set", maximumSize = 3, element = { type = "enum", values = ordered("A", "B", "C") } }
	) },
	OrderedFlags = { id = 10, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "mode", type = "enum", values = ordered("A", "B", "C") },
		{ name = "value", type = "u8" }
	) },
	NativeMix = { id = 11, direction = "ClientToServer", fields = ordered(
		{ name = "vector", type = "Vector3int16", minimum = -8, maximum = 8 },
		{ name = "sequence", type = "NumberSequence", maximumKeypoints = 3,
			minimum = -1, maximum = 1, maximumEnvelope = 0.5 }
	) },
} })
assert(token, definitionIssue and definitionIssue.message or "definition rejected without an issue")
local compiled = Definition.get(token)
local legacyToken = assert(Definition.define({ name = "BitPackingLegacy", version = 1, events = {
	Legacy = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "mode", type = "enum", values = ordered("A", "B", "C") }
	) },
} }))
local legacyCompiled = Definition.get(legacyToken)
local function codecs(name, context)
	local event = compiled.events[name]
	return Frame.compile(event, "encode", context), Frame.compile(event, "decode", context), event
end
local function loadCountingComposite()
	local counts = {}
	local function counted(module)
		return { compile = function(shape)
			local operations = module.compile(shape)
			if operations == nil then return nil end
			local normalize = operations.normalize
			operations = table.clone(operations)
			operations.normalize = function(value)
				counts[shape.type] = (counts[shape.type] or 0) + 1
				return normalize(value)
			end
			return operations
		end }
	end
	local environment = table.clone(roblox)
	local modules = {
		["./NativeCodec"] = counted(support.NativeCodec),
		["./InstanceRefs"] = support.InstanceRefs,
		["./Quantized"] = counted(Quantized),
		["./CompactValues"] = counted(support.CompactValues),
		["./BitPacking"] = BitPacking,
		["./LengthBounds"] = LengthBounds,
		["./NumericFormats"] = NumericFormats,
	}
	environment.require = function(path)
		local module = modules[path]
		assert(module ~= nil, `unexpected composite codec dependency: {path}`)
		return module
	end
	local composite = luau.load(fs.readFile("src/internal/CompositeCodec.luau"), {
		environment = environment, injectGlobals = true,
	})()
	return composite, counts
end
local function encodePacket(encode, ...)
	local valid, packet = encode(...)
	assert(valid and typeof(packet) == "buffer", "packed encoder rejects the test payload")
	return packet
end
local function copy(value, length)
	local output = buffer.create(length)
	buffer.copy(output, 0, value, 0, math.min(length, buffer.len(value)))
	return output
end

do
	local composite, counts = loadCountingComposite()
	local compactEvent = table.clone(compiled.events.CompactMix)
	compactEvent.fields = { compiled.events.CompactMix.fields[2], compiled.events.CompactMix.fields[3] }
	local compactEncode = composite.compile(compactEvent, "encode")
	assert(compactEncode(5.6, Vector3.new(0.9, 0.1, -0.9))
		and counts.quantized == 1 and counts.quantizedVector3 == 1,
		"fixed Quantized and CompactValues leaves are each normalized once before sizing")
	assert(compactEncode(5.6, Vector3.new(2, 0, 0)) == nil and counts.quantizedVector3 == 2,
		"fixed CompactValues still rejects invalid input after one normalization")
	local nativeEncode = composite.compile(compiled.events.NativeMix, "encode")
	local sequence = roblox.NumberSequence.new({
		roblox.NumberSequenceKeypoint.new(0, -0.25, 0),
		roblox.NumberSequenceKeypoint.new(1, 0.75, 0),
	})
	local vector = roblox.Vector3int16.new(-3, 4, 5)
	assert(nativeEncode(vector, sequence) and counts.Vector3int16 == 1 and counts.NumberSequence == 2,
		"fixed NativeCodec leaf is normalized once while variable sequence sizing retains its fallback")
	assert(nativeEncode(roblox.Vector3int16.new(9, 0, 0), sequence) == nil
		and counts.Vector3int16 == 2 and counts.NumberSequence == 2,
		"fixed NativeCodec leaf still rejects invalid bounded input before sequence normalization")
end

do
	local encode, decode, event = codecs("Flags")
	local packet = encodePacket(encode, true, "Only", "B", "Value32", false, "C", nil, 42)
	assert(event.minimumEncodedBytes == 6 and event.maximumEncodedBytes == 16
		and buffer.len(packet) == 6 and buffer.readu8(packet, 3) == 245 and buffer.readu8(packet, 4) == 43
		and buffer.readu8(packet, 5) == 42,
		"tuple mask packs bool, 1/3/32-value enums, optional flags, and leaves body bytes in field order")
	local result = table.pack(decode(packet))
	assert(result.n == 9 and result[1] == true and result[2] == true and result[3] == "Only"
		and result[4] == "B" and result[5] == "Value32" and result[6] == false and result[7] == "C"
		and result[8] == nil and result[9] == 42, "packed tuple preserves false and exact nil positions")

	local badPadding = copy(packet, buffer.len(packet))
	buffer.writeu8(badPadding, 4, bit32.bor(buffer.readu8(badPadding, 4), 128))
	assert(decode(badPadding) == nil, "tuple rejects nonzero padding bits")
	assert(decode(copy(packet, buffer.len(packet) - 1)) == nil, "tuple rejects truncation")
	local trailing = copy(packet, buffer.len(packet) + 1)
	assert(decode(trailing) == nil, "tuple rejects trailing bytes")
	local absentEnum = encodePacket(encode, true, "Only", "A", "Value1", nil, nil, nil, 42)
	local nonzeroAbsentEnum = copy(absentEnum, buffer.len(absentEnum))
	buffer.writeu8(nonzeroAbsentEnum, 4, bit32.bor(buffer.readu8(nonzeroAbsentEnum, 4), 16))
	assert(decode(nonzeroAbsentEnum) == nil, "absent optional enum rejects nonzero reserved value bits")
end

do
	local encode, decode = codecs("Optional")
	local present = encodePacket(encode, "x", false)
	assert(buffer.len(present) == 7 and buffer.readu8(present, 3) == 1
		and buffer.readu16(present, 4) == 1 and buffer.readu8(present, 6) == string.byte("x"),
		"optional nonflag presence shares its block mask and payload follows in field order")
	local decodedPresent = table.pack(decode(present))
	assert(decodedPresent.n == 3 and decodedPresent[1] == true and decodedPresent[2] == "x"
		and decodedPresent[3] == false)
	local absent = encodePacket(encode, nil, true)
	assert(buffer.len(absent) == 4 and buffer.readu8(absent, 3) == 2)
	local decodedAbsent = table.pack(decode(absent))
	assert(decodedAbsent.n == 3 and decodedAbsent[1] == true and decodedAbsent[2] == nil
		and decodedAbsent[3] == true, "absent optional has no body while the following false/true flag stays distinct")
	local absentValueBits = copy(absent, buffer.len(absent))
	buffer.writeu8(absentValueBits, 3, 6)
	assert(decode(absentValueBits) == nil, "absent optional flag rejects nonzero reserved value bits")
end

do
	local encode, decode = codecs("Nested")
	local packet = encodePacket(encode, { enabled = false, mode = "C", value = 9 })
	assert(buffer.len(packet) == 5 and buffer.readu8(packet, 3) == 4 and buffer.readu8(packet, 4) == 9,
		"struct starts its own byte-aligned mask")
	local valid, record = decode(packet)
	assert(valid and record.enabled == false and record.mode == "C" and record.value == 9)
	local encodeUnion, decodeUnion = codecs("Union")
	local unionPacket = encodePacket(encodeUnion, { kind = "Alpha", enabled = true, mode = "B", value = 7 })
	assert(buffer.len(unionPacket) == 6 and buffer.readu8(unionPacket, 3) == 0
		and buffer.readu8(unionPacket, 4) == 3 and buffer.readu8(unionPacket, 5) == 7,
		"tagged union keeps its u8 discriminator and packs the selected variant struct")
	local unionValid, choice = decodeUnion(unionPacket)
	assert(unionValid and choice.kind == "Alpha" and choice.enabled == true
		and choice.mode == "B" and choice.value == 7)
end

do
	local encode, decode, event = codecs("Arrays")
	local packet = encodePacket(encode, { true, false, true }, { "A", "C" }, { "Value1", "Value32" })
	assert(buffer.len(packet) == 13 and buffer.readu16(packet, 3) == 3 and buffer.readu8(packet, 5) == 5
		and buffer.readu16(packet, 6) == 2 and buffer.readu8(packet, 8) == 8
		and buffer.readu16(packet, 9) == 2 and buffer.readu8(packet, 11) == 224
		and buffer.readu8(packet, 12) == 3,
		"arrays use count-sized low-bit-first masks for 1/2/5-bit elements")
	local result = table.pack(decode(packet))
	assert(result.n == 4 and result[1] == true and result[2][1] == true and result[2][2] == false
		and result[2][3] == true and result[3][1] == "A" and result[3][2] == "C"
		and result[4][1] == "Value1" and result[4][2] == "Value32")
	local badCode = copy(packet, buffer.len(packet))
	buffer.writeu8(badCode, 8, 3)
	assert(decode(badCode) == nil, "array rejects unused literal-enum ordinals")
	local tooMany = buffer.create(5)
	buffer.writeu8(tooMany, 0, 1)
	buffer.writeu16(tooMany, 1, event.id)
	buffer.writeu16(tooMany, 3, 65)
	assert(decode(tooMany) == nil, "array count is rejected before mask allocation or traversal")
	local badArrayPadding = buffer.create(6)
	buffer.writeu8(badArrayPadding, 0, 1)
	buffer.writeu16(badArrayPadding, 1, event.id)
	buffer.writeu16(badArrayPadding, 3, 1)
	buffer.writeu8(badArrayPadding, 5, 128)
	assert(decode(badArrayPadding) == nil, "count-sized array masks reject nonzero padding")
end

do
	local encode, decode, event = codecs("Sets")
	local packet = encodePacket(encode, { A = true, B = true, C = true })
	assert(buffer.len(packet) == 6 and buffer.readu16(packet, 3) == 3,
		"set writes its count and a count-sized packed enum mask")
	local result = table.pack(decode(packet))
	assert(result.n == 2 and result[1] == true and result[2].A == true
		and result[2].B == true and result[2].C == true,
		"packed enum set round-trips all members")

	local duplicate = buffer.create(6)
	buffer.writeu8(duplicate, 0, 1)
	buffer.writeu16(duplicate, 1, event.id)
	buffer.writeu16(duplicate, 3, 2)
	buffer.writeu8(duplicate, 5, 0)
	assert(decode(duplicate) == nil, "packed set decoder rejects duplicate enum members")
	local badPadding = buffer.create(6)
	buffer.writeu8(badPadding, 0, 1)
	buffer.writeu16(badPadding, 1, event.id)
	buffer.writeu16(badPadding, 3, 1)
	buffer.writeu8(badPadding, 5, 128)
	assert(decode(badPadding) == nil, "count-sized set masks reject nonzero padding")
	local tooMany = buffer.create(5)
	buffer.writeu8(tooMany, 0, 1)
	buffer.writeu16(tooMany, 1, event.id)
	buffer.writeu16(tooMany, 3, 4)
	assert(decode(tooMany) == nil, "set count is rejected before mask allocation or traversal")
end

do
	local encode, decode, event = codecs("Map")
	local valid, packet = encode({ first = "A", second = "C" })
	assert(valid and buffer.readu16(packet, 3) == 2 and buffer.len(packet) > event.minimumEncodedBytes,
		"map retains its count and gives each key/value pair a mask block")
	local decoded, values = decode(packet)
	assert(decoded and values.first == "A" and values.second == "C")
	local duplicate = buffer.create(13)
	buffer.writeu8(duplicate, 0, 1)
	buffer.writeu16(duplicate, 1, event.id)
	buffer.writeu16(duplicate, 3, 2)
	buffer.writeu8(duplicate, 5, 0)
	buffer.writeu16(duplicate, 6, 1)
	buffer.writeu8(duplicate, 8, string.byte("a"))
	buffer.writeu8(duplicate, 9, 0)
	buffer.writeu16(duplicate, 10, 1)
	buffer.writeu8(duplicate, 12, string.byte("a"))
	assert(decode(duplicate) == nil, "map decoder rejects duplicate packed keys")
end

do
	local root = roblox.Instance.new("Folder")
	root.Parent = support.World
	local part = roblox.Instance.new("Part")
	part.Parent = root
	local context = { server = true, root = root }
	local encode, decode = codecs("InstanceMix", context)
	local result = table.pack(encode(false, part))
	assert(result.n == 3 and result[1] == true and buffer.len(result[2]) == 6
		and buffer.readu8(result[2], 0) == 4 and buffer.readu8(result[2], 4) == 0
		and buffer.readu8(result[2], 5) == 1 and result[3] == part,
		"packed block uses the existing format-4 reference sidecar and ordinal writer")
	local decoded = table.pack(decode(result[2], part))
	assert(decoded.n == 3 and decoded[1] == true and decoded[2] == false and decoded[3] == part,
		"packed decoder preserves Instance reference validation and ordering")
	local badVersion = copy(result[2], buffer.len(result[2]))
	buffer.writeu8(badVersion, 0, 1)
	assert(decode(badVersion, part) == nil, "packed reference decoder retains format-4 enforcement")
	assert(InstanceRefs.scopeArguments(context, result[2], part)
		and not InstanceRefs.scopeArguments(context, result[2], support.World),
		"packed reference frame passes the existing pre-send sidecar scope guard")

	local compactEncode, compactDecode = codecs("CompactMix")
	local compactPacket = encodePacket(compactEncode, true, 5.6, Vector3.new(0.9, 0.1, -0.9))
	assert(buffer.len(compactPacket) == 8 and buffer.readu8(compactPacket, 3) == 1
		and buffer.readu8(compactPacket, 4) == 6 and buffer.readu8(compactPacket, 5) == 2
		and buffer.readu8(compactPacket, 6) == 1 and buffer.readu8(compactPacket, 7) == 0,
		"existing scalar and Vector3 quantizers keep their native codes after the packed mask")
	local compactResult = table.pack(compactDecode(compactPacket))
	assert(compactResult.n == 4 and compactResult[1] == true and compactResult[2] == true
		and compactResult[3] == 6 and compactResult[4] == Vector3.new(1, 0, -1))
end

do
	local encode = Frame.compile(legacyCompiled.events.Legacy, "encode")
	local decode = Frame.compile(legacyCompiled.events.Legacy, "decode")
	local packet = encodePacket(encode, true, "B")
	assert(buffer.len(packet) == 5 and buffer.readu8(packet, 3) == 1 and buffer.readu8(packet, 4) == 1
		and decode(packet) == true,
		"definitions without bitPacking keep the legacy byte-per-field representation")
end

do
	local event = compiled.events.OrderedFlags
	local codecEvent = OrderedFrame.codecEvent(event)
	local encode = Frame.compile(codecEvent, "encode")
	local decode = Frame.compile(codecEvent, "decode")
	local body = encodePacket(encode, true, "C", 17)
	assert(buffer.len(body) == 5 and buffer.readu8(body, 3) == 5 and buffer.readu8(body, 4) == 17,
		"ordered codec event preserves the bit-packing option and emits the compact mask")
	local wrapped = assert(OrderedFrame.wrap(event, body, 3, 9))
	local header = assert(OrderedFrame.peek(event, event.id, wrapped))
	local result = table.pack(OrderedFrame.decode(event, wrapped, header, decode))
	assert(result.n == 4 and result[1] == true and result[2] == true
		and result[3] == "C" and result[4] == 17,
		"ordered wrapper round-trips a bit-packed payload")
end

do
	local event = compiled.events.Flags
	local encode = Frame.compile(event, "encode")
	local packet = encodePacket(encode, true, "Only", "B", "Value32", false, "C", nil, 42)
	local malformed = copy(packet, buffer.len(packet))
	buffer.writeu8(malformed, 4, bit32.bor(buffer.readu8(malformed, 4), 128))
	local runtime = Runtime.new()
	local player = runtime:addPlayer()
	local root = roblox.Instance.new("Folder")
	root.Parent = support.World
	local byteCapacity = 2 * buffer.len(packet)
	local server = assert(runtime.server.create(token, {
		instanceRoot = root,
		inboundRate = {
			perPlayer = { capacity = 3, refillPerSecond = 1 },
			aggregate = { capacity = 6, refillPerSecond = 2 },
			endpoints = { [event.id] = { capacity = 2, refillPerSecond = 0.1 } },
			bytes = {
				perPlayer = { capacity = byteCapacity, refillPerSecond = byteCapacity },
				aggregate = { capacity = byteCapacity, refillPerSecond = byteCapacity },
			},
		},
	}))
	local calls = 0
	assert(server.events.Flags:Connect(function(sender)
		assert(sender == player)
		calls += 1
	end))
	assert(server:Start())
	local remote = runtime:remote()
	remote.OnServerEvent:Fire(player, event.id, malformed)
	local counters = server:GetDiagnostics().counters
	assert(calls == 0 and counters.invalidPayload == 1,
		"malformed packed tuple is rejected after admission and cannot reach the handler")
	remote.OnServerEvent:Fire(player, event.id, packet)
	counters = server:GetDiagnostics().counters
	assert(calls == 1 and counters.invalidPayload == 1 and counters.perPlayerBytes == 0
		and counters.aggregateBytes == 0,
		"the exactly funded valid packed tuple dispatches after the malformed frame spends bytes")
	remote.OnServerEvent:Fire(player, event.id, packet)
	counters = server:GetDiagnostics().counters
	assert(calls == 1 and counters.perPlayerBytes == 1 and counters.aggregateBytes == 0,
		"the next packed tuple is refused at the exhausted per-player byte budget")
	runtime.now = 1
	remote.OnServerEvent:Fire(player, event.id, packet)
	counters = server:GetDiagnostics().counters
	assert(calls == 1 and counters.endpointRate == 1 and counters.invalidPayload == 1
		and counters.perPlayerBytes == 1 and counters.aggregateBytes == 0
		and counters.perPlayerRate == 0 and counters.aggregateRate == 0,
		"malformed and valid packed events retain shared and endpoint charges before later admission")
	server:Destroy()
end

print("PASS Relay.BitPacking bounded masks, composite blocks, malformed frames, and legacy codec")
