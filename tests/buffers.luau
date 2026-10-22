local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local support = require("./support/NativeCodec")
local Definition = require("../src/Definition")
local Schema = require("../src/Schema")
local Frame = support.loadFrame()
local ordered = require("../examples/reliable-events/ordered")

local function define(spec)
	local token, problem = Definition.define(spec)
	assert(token, problem and problem.message or "definition rejected without an issue")
	return Definition.get(token)
end

local function invalid(spec, message)
	local token, problem = Definition.define(spec)
	assert(token == nil and problem and problem.code == "InvalidDefinition", message)
end

local function copied(value, length)
	local result = buffer.create(length)
	buffer.copy(result, 0, value, 0, math.min(length, buffer.len(value)))
	return result
end

local function bytes(values)
	local result = buffer.create(#values)
	for index, value in values do buffer.writeu8(result, index - 1, value) end
	return result
end

local function equals(left, right)
	if typeof(left) ~= "buffer" or typeof(right) ~= "buffer" or buffer.len(left) ~= buffer.len(right) then
		return false
	end
	for index = 0, buffer.len(left) - 1 do
		if buffer.readu8(left, index) ~= buffer.readu8(right, index) then return false end
	end
	return true
end

local apiShape = Schema.buffer(0)
assert(table.isfrozen(apiShape) and apiShape.type == "buffer" and apiShape.maximumBytes == 0)

local legacy = define({ name = "BufferCompat", version = 1, events = {
	Ping = { id = 1, direction = "ClientToServer", fields = ordered() },
} })
assert(legacy.descriptor == "RR1|D12:BufferCompat|V1|N1|E1,C,4:Ping,0",
	"definitions without buffers retain their original descriptor")

local rawDefinition = define({ name = "BufferCodec", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = ordered({ name = "payload", type = "struct", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 256 },
		{ name = "maybe", type = "optional", value = { type = "buffer", maximumBytes = 3 } },
		{ name = "list", type = "array", maximumLength = 2, element = { type = "buffer", maximumBytes = 4 } },
		{ name = "lookup", type = "map", maximumSize = 1, key = { type = "u8" },
			value = { type = "buffer", maximumBytes = 2 } },
		{ name = "choice", type = "taggedUnion", tag = "kind", variants = {
			Raw = { type = "struct", fields = ordered({ name = "blob", type = "buffer", maximumBytes = 2 }) },
			Empty = { type = "struct", fields = ordered() },
		} }
	) }) },
	Empty = { id = 2, direction = "ClientToServer", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 0 }
	) },
	ZeroArray = { id = 3, direction = "ClientToServer", fields = ordered(
		{ name = "bytes", type = "array", maximumLength = 0, element = { type = "buffer", maximumBytes = 1 } }
	) },
	Guarded = { id = 4, direction = "ClientToServer", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 2 },
		{ name = "tail", type = "boolean" }
	) },
} })
local inputEvent = rawDefinition.events.Input
assert(inputEvent.usesCodec and inputEvent.fields[1].fields[1].minimumEncodedBytes == 2
	and inputEvent.fields[1].fields[1].maximumEncodedBytes == 258)
assert(string.sub(rawDefinition.descriptor, 1, 6) == "RR15|D" and string.find(rawDefinition.descriptor, "|BUF1,2,8187", 1, true)
	and string.find(rawDefinition.descriptor, "B256;", 1, true),
	"buffer definitions use RR15, the bounded-buffer marker, and exact per-leaf caps")
assert(string.find(rawDefinition.descriptor, "B1;", 1, true),
	"a buffer authored below a zero-capacity collection still marks the descriptor")

local allBytes = table.create(256)
for index = 0, 255 do allBytes[index + 1] = index end
local source = bytes(allBytes)
local maybe = bytes({ 0, 127, 255 })
local listFirst = bytes({ 5, 0, 6, 255 })
local mapValue = bytes({ 9, 10 })
local unionValue = bytes({ 200, 201 })
local payload = {
	bytes = source,
	maybe = maybe,
	list = { listFirst },
	lookup = { [7] = mapValue },
	choice = { kind = "Raw", blob = unionValue },
}
local encode = Frame.compile(inputEvent, "encode")
local decode = Frame.compile(inputEvent, "decode")
local validate = Frame.compile(inputEvent)

local valid, normalized = validate(payload)
assert(valid and normalized ~= payload and normalized.bytes ~= source and equals(normalized.bytes, source),
	"local validation returns an owned buffer copy")
buffer.writeu8(source, 0, 42)
assert(buffer.readu8(normalized.bytes, 0) == 0, "normalized buffers do not alias caller storage")
buffer.writeu8(source, 0, 0)

local encoded, packet = encode(payload)
assert(encoded and buffer.len(packet) == 287 and buffer.readu16(packet, 3) == 256,
	"u16 little-endian prefix and exact binary buffer bytes are written")
for index = 0, 255 do assert(buffer.readu8(packet, 5 + index) == index, "binary payload byte changed") end
buffer.writeu8(payload.bytes, 1, 99)
assert(buffer.readu8(packet, 6) == 1, "encoded frames own their buffer contents")

local decoded = table.pack(decode(packet))
assert(decoded.n == 2 and decoded[1] and equals(decoded[2].bytes, normalized.bytes)
	and equals(decoded[2].maybe, maybe) and equals(decoded[2].list[1], listFirst)
	and equals(decoded[2].lookup[7], mapValue) and equals(decoded[2].choice.blob, unionValue),
	"buffer leaves round trip through optional, array, map value and tagged-union shapes")
assert(decoded[2].bytes ~= packet and decoded[2].bytes ~= normalized.bytes,
	"receiver owns a fresh buffer copy")
buffer.writeu8(decoded[2].bytes, 0, 88)
local decodedAgainOk, decodedAgain = decode(packet)
assert(decodedAgainOk and buffer.readu8(decodedAgain.bytes, 0) == 0,
	"mutating a received buffer does not mutate the packet or later decoded values")

local emptyEvent = rawDefinition.events.Empty
local emptyEncoded, emptyPacket = Frame.compile(emptyEvent, "encode")(buffer.create(0))
assert(emptyEncoded and buffer.len(emptyPacket) == 5 and buffer.readu16(emptyPacket, 3) == 0)
local emptyDecoded = table.pack(Frame.compile(emptyEvent, "decode")(emptyPacket))
assert(emptyDecoded[1] and typeof(emptyDecoded[2]) == "buffer" and buffer.len(emptyDecoded[2]) == 0)
local maximumDefinition = define({ name = "BufferMaximum", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 8187 }
	) },
} })
assert(maximumDefinition.events.Input.maximumEncodedBytes == 8192,
	"the maximum buffer cap exactly fits the reliable Relay frame")

for _, maximumBytes in { -1, 1.5, 8188, math.huge, "8" } do
	invalid({ name = "BadBufferCap", version = 1, events = {
		Input = { id = 1, direction = "ClientToServer", fields = ordered(
			{ name = "bytes", type = "buffer", maximumBytes = maximumBytes }
		) },
	} }, "buffer caps must be integers from zero through 8187")
end
invalid({ name = "BufferExtraKey", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 2, extra = true }
	) },
} }, "buffer shape keys are closed")
local metatableBuffer = setmetatable({ name = "bytes", type = "buffer", maximumBytes = 2 }, {})
invalid({ name = "BufferMetatable", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = ordered(metatableBuffer) },
} }, "buffer shapes with metatables are rejected")
for _, wrongValue in { "bytes", {}, 12 } do
	assert(encode(wrongValue) == nil and validate(wrongValue) == nil, "non-buffer substitutes are rejected")
end
local tooLong = buffer.create(257)
local tooLongPayload = table.clone(payload)
tooLongPayload.bytes = tooLong
assert(encode(tooLongPayload) == nil, "buffers above their schema cap are rejected")
invalid({ name = "BufferMapKey", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "values", type = "map", maximumSize = 1, key = { type = "buffer", maximumBytes = 2 },
			value = { type = "u8" } }
	) },
} }, "buffers cannot be map keys")
invalid({ name = "BufferSetKey", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "values", type = "set", maximumSize = 1, element = { type = "buffer", maximumBytes = 2 } }
	) },
} }, "buffers cannot be set elements")

local routeDefinition = define({ name = "BufferRoutes", version = 1, events = {
	Unreliable = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 895 }
	) },
	Ordered = { id = 2, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 887 }
	) },
	Fifo = { id = 3, direction = "ServerToClient", queue = "Batch", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 8182 }
	) },
	State = { id = 4, direction = "ServerToClient", queue = "State", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 8182 }
	) },
} , requests = {
	Echo = { id = 5, request = ordered({ name = "bytes", type = "buffer", maximumBytes = 8143 }),
		response = { type = "buffer", maximumBytes = 8143 } },
} })
assert(routeDefinition.events.Unreliable.maximumEncodedBytes == 900
	and routeDefinition.events.Ordered.maximumEncodedBytes == 900
	and routeDefinition.queuedById[3].maximumEncodedBytes == 8187
	and routeDefinition.queuedById[4].maximumEncodedBytes == 8187
	and routeDefinition.requests.Echo.request.maximumEncodedBytes == 8148
	and routeDefinition.requests.Echo.response.maximumEncodedBytes == 8148,
	"buffer schemas preserve complete-frame limits for unreliable, ordered, FIFO, State and RPC routes")
invalid({ name = "BufferTooWideUnreliable", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 896 }
	) },
} }, "unreliable buffer caps include the full Relay frame limit")
invalid({ name = "BufferTooWideOrdered", version = 1, events = {
	Input = { id = 1, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = ordered(
		{ name = "bytes", type = "buffer", maximumBytes = 888 }
	) },
} }, "ordered buffer caps include the existing envelope overhead")
invalid({ name = "BufferTooWideRpc", version = 1, events = {
	Ping = { id = 1, direction = "ClientToServer", fields = ordered() },
}, requests = {
	Echo = { id = 2, request = ordered({ name = "bytes", type = "buffer", maximumBytes = 8144 }),
		response = { type = "u8" } },
} }, "RPC buffers include the existing request envelope budget")

local packedDefinition = define({ name = "PackedBuffers", version = 1, bitPacking = true, events = {
	Plain = { id = 1, direction = "ClientToServer", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "bytes", type = "buffer", maximumBytes = 8 }
	) },
	InstanceMix = { id = 2, direction = "ClientToServer", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "target", type = "Instance", className = "BasePart" },
		{ name = "bytes", type = "buffer", maximumBytes = 8 }
	) },
	Ordered = { id = 3, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = ordered(
		{ name = "enabled", type = "boolean" },
		{ name = "bytes", type = "buffer", maximumBytes = 8 }
	) },
} })
assert(string.find(packedDefinition.descriptor, "|BP1|BUF1,2,8187", 1, true),
	"buffer and packed tuple markers coexist in the new descriptor")
local packedEvent = packedDefinition.events.Plain
local packedPayload = bytes({ 1, 2, 255 })
local packedEncode = Frame.compile(packedEvent, "encode")
local packedDecode = Frame.compile(packedEvent, "decode")
local packedOk, packedPacket = packedEncode(true, packedPayload)
assert(packedOk and buffer.len(packedPacket) == 9 and buffer.readu8(packedPacket, 3) == 1
	and buffer.readu16(packedPacket, 4) == 3 and buffer.readu8(packedPacket, 6) == 1
	and buffer.readu8(packedPacket, 8) == 255,
	"packed buffer size, mask, and leaf writer agree")
local packedResult = table.pack(packedDecode(packedPacket))
assert(packedResult.n == 3 and packedResult[1] and packedResult[2] and equals(packedResult[3], packedPayload),
	"packed buffer leaf round trips through the shared checked codec helpers")

local root = roblox.Instance.new("Folder")
root.Parent = support.World
local part = roblox.Instance.new("Part")
part.Parent = root
local referenceEvent = packedDefinition.events.InstanceMix
local context = { server = true, root = root }
local referenceEncode = Frame.compile(referenceEvent, "encode", context)
local referenceDecode = Frame.compile(referenceEvent, "decode", context)
local refOk, refPacket, sidecar = referenceEncode(false, part, packedPayload)
assert(refOk and sidecar == part and buffer.readu8(refPacket, 0) == 4
	and buffer.readu16(refPacket, 1) == referenceEvent.id and buffer.readu8(refPacket, 3) == 1,
	"packed buffer plus Instance keeps format-4 reference sidecars")
local refDecoded = table.pack(referenceDecode(refPacket, part))
assert(refDecoded.n == 4 and refDecoded[1] and refDecoded[2] == false and refDecoded[3] == part
	and equals(refDecoded[4], packedPayload), "format-4 packed reference frames decode buffers atomically")

local orderedEvent = packedDefinition.events.Ordered
local orderedCodec = require("../src/internal/OrderedFrame")
local bodyEncode = Frame.compile(orderedCodec.codecEvent(orderedEvent), "encode")
local bodyDecode = Frame.compile(orderedCodec.codecEvent(orderedEvent), "decode")
local bodyOk, body = bodyEncode(true, packedPayload)
local wrapped = assert(orderedCodec.wrap(orderedEvent, body, 1, 2))
local header = assert(orderedCodec.peek(orderedEvent, orderedEvent.id, wrapped))
local orderedResult = table.pack(orderedCodec.decode(orderedEvent, wrapped, header, bodyDecode))
assert(bodyOk and orderedResult.n == 3 and orderedResult[1] and orderedResult[2]
	and equals(orderedResult[3], packedPayload), "ordered unreliable wrapper carries a packed buffer payload")

local allocationCounts = { create = 0, copy = 0 }
local guardedBuffer = table.clone(buffer)
guardedBuffer.create = function(length)
	allocationCounts.create += 1
	return buffer.create(length)
end
guardedBuffer.copy = function(...)
	allocationCounts.copy += 1
	return buffer.copy(...)
end
local guardedComposite = luau.load(fs.readFile("src/internal/CompositeCodec.luau"), {
	injectGlobals = true,
	environment = {
		buffer = guardedBuffer,
		require = function(path)
			if path == "./NativeCodec" then return support.NativeCodec end
			if path == "./InstanceRefs" then return support.InstanceRefs end
			if path == "./Quantized" then return require("../src/internal/Quantized") end
			if path == "./CompactValues" then return support.CompactValues end
			if path == "./BitPacking" then return require("../src/internal/BitPacking") end
			if path == "./LengthBounds" then return require("../src/internal/LengthBounds") end
			if path == "./NumericFormats" then return require("../src/internal/NumericFormats") end
			assert(false, `unexpected composite codec dependency: {path}`)
		end,
	},
})()
local guardedFrame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	injectGlobals = true,
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		buffer = guardedBuffer,
		require = function(path) assert(path == "./CompositeCodec"); return guardedComposite end,
	},
})()
local malformedEvent = rawDefinition.events.Guarded
local malformedDecode = guardedFrame.compile(malformedEvent, "decode")
local overCap = buffer.create(6)
buffer.writeu8(overCap, 0, 1)
buffer.writeu16(overCap, 1, malformedEvent.id)
buffer.writeu16(overCap, 3, 3)
buffer.writeu8(overCap, 5, 0)
allocationCounts.create, allocationCounts.copy = 0, 0
assert(malformedDecode(overCap) == nil and allocationCounts.create == 0 and allocationCounts.copy == 0,
	"decoder checks a claimed length against the cap before allocating or copying")
local truncated = buffer.create(6)
buffer.writeu8(truncated, 0, 1)
buffer.writeu16(truncated, 1, malformedEvent.id)
buffer.writeu16(truncated, 3, 2)
buffer.writeu8(truncated, 5, 0)
allocationCounts.create, allocationCounts.copy = 0, 0
assert(malformedDecode(truncated) == nil and allocationCounts.create == 0 and allocationCounts.copy == 0,
	"decoder checks remaining tuple bytes before allocating or copying a truncated leaf")
local trailing = copied(emptyPacket, buffer.len(emptyPacket) + 1)
buffer.writeu8(trailing, buffer.len(trailing) - 1, 0)
assert(Frame.compile(emptyEvent, "decode")(trailing) == nil,
	"the complete Relay frame rejects trailing bytes after a valid empty buffer")

print("PASS Relay.Buffers bounded native buffer schema, codec, ownership, compatibility, and route limits")
