local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local BatchFrame = require("../src/internal/BatchFrame")
local Definition = require("../src/Definition")
local NativeSchema = require("../src/internal/NativeSchema")
local OrderedFrame = require("../src/internal/OrderedFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local Schema = require("../src/Schema")
local ServerRuntime = require("./support/ServerRuntime")
local support = require("./support/NativeCodec")
local NativeCodec = support.NativeCodec
local Frame = support.loadFrame()

local CONSTRUCTION_ALLOWANCE = 2 ^ -24
local MAXIMUM_ERROR = 1 / 510 + CONSTRUCTION_ALLOWANCE

local function define(spec, label)
	local token, problem = Definition.define(spec)
	assert(token ~= nil and problem == nil, `{label}: {problem and problem.message}`)
	return token, assert(Definition.get(token))
end

local function reject(spec, label)
	local token = Definition.define(spec)
	assert(token == nil, label)
end

local function encode(event, ...)
	local result = table.pack(Frame.compile(event, "encode")(...))
	assert(result[1] == true and typeof(result[2]) == "buffer",
		`RGB8 payload encodes through the checked buffer path: {tostring(result[1])}/{tostring(result[2])}`)
	return result[2]
end

local function hex(value)
	local bytes = table.create(buffer.len(value))
	for offset = 0, buffer.len(value) - 1 do
		bytes[offset + 1] = string.format("%02x", buffer.readu8(value, offset))
	end
	return table.concat(bytes)
end

local function near(actual, expected)
	return math.abs(actual - expected) <= CONSTRUCTION_ALLOWANCE
end

local nativeShape, suffix, reason = NativeSchema.compile({ type = "Color3RGB8" })
assert(nativeShape ~= nil and suffix == nil and reason == nil and nativeShape.native and nativeShape.containsCodec
	and nativeShape.minimumEncodedBytes == 3 and nativeShape.maximumEncodedBytes == 3
	and nativeShape.maximumDepth == 0 and nativeShape.maximumElements == 1
	and nativeShape.descriptorToken == "N10:Color3RGB8[1]",
	"RGB8 is a closed one-leaf, fixed-three-byte native shape with its own descriptor token")
local rgb8Keys, rgb8KeyCount = NativeSchema.keys("Color3RGB8")
assert(rgb8Keys ~= nil and rgb8Keys.type and rgb8KeyCount == 1,
	"RGB8 exposes only its type key to Definition's closed-shape validator")
local colorCodec = assert(NativeCodec.compile(nativeShape))

local helperShape = Schema.Color3RGB8()
assert(table.isfrozen(helperShape) and helperShape.type == "Color3RGB8")
local helperToken, helperCompiled = define({
	name = "RGB8SchemaParity", version = 1,
	events = { Input = { id = 1, direction = "ClientToServer", fields = { Schema.field("tint", helperShape) } } },
}, "RGB8 schema helper")
local rawToken, rawCompiled = define({
	name = "RGB8SchemaParity", version = 1,
	events = { Input = { id = 1, direction = "ClientToServer", fields = { { name = "tint", type = "Color3RGB8" } } } },
}, "raw RGB8 shape")
local helperReport = Definition.inspect(helperToken)
assert(helperCompiled.descriptor == rawCompiled.descriptor
	and helperCompiled.descriptor:find("N10:Color3RGB8[1]", 1, true) ~= nil
	and helperCompiled.descriptor:sub(1, 3) == "RR3"
	and helperCompiled.events.Input.usesCodec
	and helperReport.events.Input.bytes.maximum == 6 and rawToken ~= nil,
	"helper and raw shapes share the exact RR3 descriptor and six-byte reliable frame budget")
reject({ name = "RGB8Closed", version = 1, events = { Input = { id = 1, direction = "ClientToServer", fields = {
	{ name = "tint", type = "Color3RGB8", minimum = 0 },
} } } }, "definition rejects RGB8 bounds")
reject({ name = "RGB8Closed", version = 1, events = { Input = { id = 1, direction = "ClientToServer", fields = {
	{ name = "tint", type = "Color3RGB8", quantization = 1 },
} } } }, "definition rejects RGB8 tuning keys")
reject({ name = "RGB8SetKey", version = 1, events = { Input = { id = 1, direction = "ClientToServer", fields = {
	{ name = "tints", type = "set", maximumSize = 1, element = { type = "Color3RGB8" } },
} } } }, "RGB8 remains ineligible as a set key")
reject({ name = "RGB8MapKey", version = 1, events = { Input = { id = 1, direction = "ClientToServer", fields = {
	{ name = "tints", type = "map", maximumSize = 1, key = { type = "Color3RGB8" }, value = { type = "u8" } },
} } } }, "RGB8 remains ineligible as a map key")

local _, compiled = define({
	name = "RGB8Routes", version = 1,
	events = {
		Reliable = { id = 1, direction = "ClientToServer", fields = { { name = "tint", type = "Color3RGB8" } } },
		Unreliable = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
			fields = { { name = "tint", type = "Color3RGB8" } } },
		Ordered = { id = 3, direction = "ClientToServer", delivery = "OrderedUnreliable",
			fields = { { name = "tint", type = "Color3RGB8" } } },
		Nested = { id = 4, direction = "ClientToServer", fields = {
			{ name = "paint", type = "struct", fields = {
				{ name = "base", type = "Color3RGB8" },
				{ name = "swatches", type = "array", maximumLength = 3, element = { type = "Color3RGB8" } },
				{ name = "accent", type = "optional", value = { type = "Color3RGB8" } },
			} },
		} },
		Union = { id = 5, direction = "ClientToServer", fields = {
			{ name = "choice", type = "taggedUnion", tag = "kind", variants = {
				Color = { type = "struct", fields = { { name = "tint", type = "Color3RGB8" } } },
			} },
		} },
		Batch = { id = 6, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "tint", type = "Color3RGB8" } } },
		State = { id = 7, direction = "ServerToClient", queue = "State",
			fields = { { name = "tint", type = "Color3RGB8" } } },
	},
	requests = { Paint = { id = 8,
		request = { { name = "tint", type = "Color3RGB8" } }, response = { type = "Color3RGB8" } } },
}, "RGB8 route definition")
local _, packedCompiled = define({
	name = "RGB8Packed", version = 1, bitPacking = true,
	events = { Packed = { id = 1, direction = "ClientToServer", fields = {
		{ name = "enabled", type = "boolean" },
		{ name = "tint", type = "Color3RGB8" },
	} } },
}, "bit-packed RGB8 definition")

local actual = roblox.Color3.new(0.15, 0.2, 0.65)
local frame = encode(compiled.events.Reliable, actual)
local redByte = math.floor(actual.R * 255 + 0.5)
local greenByte = math.floor(actual.G * 255 + 0.5)
local blueByte = math.floor(actual.B * 255 + 0.5)
assert(buffer.len(frame) == 6 and buffer.readu8(frame, 0) == 1 and buffer.readu16(frame, 1) == 1
	and buffer.readu8(frame, 3) == redByte and buffer.readu8(frame, 4) == greenByte
	and buffer.readu8(frame, 5) == blueByte and hex(frame) == "0101002633a6",
	"reliable RGB8 uses a six-byte frame and rounds actual native R/G/B channels in order")

local half = roblox.Color3.new(0.5, 0.5, 0.5)
local halfNormalized, halfValue, halfSize = colorCodec.normalize(half)
local halfBody = buffer.create(halfSize)
assert(halfNormalized and halfSize == 3 and colorCodec.write(halfValue, halfBody, 0) == 3
	and hex(halfBody) == "808080" and math.abs(half.R - halfValue.R) <= MAXIMUM_ERROR
	and math.abs(half.G - halfValue.G) <= MAXIMUM_ERROR and math.abs(half.B - halfValue.B) <= MAXIMUM_ERROR,
	"exact half steps round upward within the documented per-channel error bound")
local sourceZero = roblox.Color3.new(-0, 0, 0)
local zeroOk, zeroValue, zeroSize = colorCodec.normalize(sourceZero)
assert(zeroOk and zeroSize == 3)
local zeroBody = buffer.create(zeroSize)
assert(colorCodec.write(zeroValue, zeroBody, 0) == 3
	and 1 / zeroValue.R == math.huge and hex(zeroBody) == "000000",
	"RGB8 normalization returns canonical positive zero")

for byte = 0, 255 do
	local body = buffer.create(3)
	buffer.writeu8(body, 0, byte)
	buffer.writeu8(body, 1, 255 - byte)
	buffer.writeu8(body, 2, byte)
	local state = { value = body, offset = 0, length = 3 }
	local read, color = colorCodec.read(state)
	assert(read and state.offset == 3 and typeof(color) == "Color3"
		and math.abs(color.R - byte / 255) <= CONSTRUCTION_ALLOWANCE
		and math.abs(color.G - (255 - byte) / 255) <= CONSTRUCTION_ALLOWANCE
		and math.abs(color.B - byte / 255) <= CONSTRUCTION_ALLOWANCE,
		`RGB8 decoder accepts every byte value with bounded construction: {byte}`)
	local normalized, canonical, size = colorCodec.normalize(color)
	local stable = buffer.create(size)
	assert(normalized and size == 3 and colorCodec.write(canonical, stable, 0) == 3
		and hex(stable) == hex(body), `RGB8 code is stable after native construction: {byte}`)
end

for _, invalidColor in {
	roblox.Color3.new(-0.01, 0, 0), roblox.Color3.new(1.01, 0, 0),
	roblox.Color3.new(0 / 0, 0, 0), roblox.Color3.new(0, math.huge, 0),
} do
	assert(colorCodec.normalize(invalidColor) == false, "RGB8 rejects nonfinite or out-of-domain native channels")
end

local function loadCodecWithColor3(newColor3)
	local environment = {}
	for name, value in roblox do environment[name] = value end
	environment.Color3 = { new = newColor3 }
	return luau.load(fs.readFile("src/internal/NativeCodec.luau"), {
		environment = environment,
		injectGlobals = true,
	})()
end

local constructorCalls = 0
local countingCodec = loadCodecWithColor3(function(red, green, blue)
	constructorCalls += 1
	return roblox.Color3.new(red, green, blue)
end).compile(nativeShape)
constructorCalls = 0
assert(countingCodec.normalize(roblox.Color3.new(1.01, 0, 0)) == false and constructorCalls == 0,
	"out-of-domain RGB8 input rejects before native construction")
local truncatedBody = buffer.create(2)
constructorCalls = 0
local truncatedState = { value = truncatedBody, offset = 0, length = 2 }
assert(countingCodec.read(truncatedState) == false and constructorCalls == 0 and truncatedState.offset == 0,
	"fixed-width truncation rejects before any RGB read or Color3 construction")

local changedCodec = loadCodecWithColor3(function(red, green, blue)
	return roblox.Color3.new(red + 1 / 255, green, blue)
end).compile(nativeShape)
local changedState = { value = buffer.create(3), offset = 0, length = 3 }
buffer.writeu8(changedState.value, 0, 10)
buffer.writeu8(changedState.value, 1, 20)
buffer.writeu8(changedState.value, 2, 30)
assert(changedCodec.read(changedState) == false and changedState.offset == 0
	and changedCodec.normalize(roblox.Color3.new(10 / 255, 20 / 255, 30 / 255)) == false,
	"native constructor representation changes fail closed on decode and normalization")
local throwingCodec = loadCodecWithColor3(function() error("constructor failure") end).compile(nativeShape)
assert(throwingCodec.read({ value = buffer.create(3), offset = 0, length = 3 }) == false
	and throwingCodec.normalize(half) == false,
	"native constructor exceptions fail closed")

local unreliableFrame = encode(compiled.events.Unreliable, half)
assert(buffer.len(unreliableFrame) == 6 and buffer.readu16(unreliableFrame, 1) == 2
	and buffer.readu8(unreliableFrame, 3) == 128 and hex(unreliableFrame) == "010200808080",
	"unreliable RGB8 reuses the existing three-byte frame header")
local unreliableDecoded = table.pack(Frame.compile(compiled.events.Unreliable, "decode")(unreliableFrame))
assert(unreliableDecoded[1] and near(unreliableDecoded[2].R, 128 / 255),
	"unreliable RGB8 decodes to the canonical native color")

local orderedCodecEvent = OrderedFrame.codecEvent(compiled.events.Ordered)
local orderedBody = encode(orderedCodecEvent, half)
local orderedFrame = assert(OrderedFrame.wrap(compiled.events.Ordered, orderedBody, 1, 1))
assert(buffer.len(orderedFrame) == 14 and buffer.readu8(orderedFrame, 0) == 3,
	"ordered RGB8 uses the existing eleven-byte wrapper plus six-byte codec frame")
local orderedHeader = assert(OrderedFrame.peek(compiled.events.Ordered, compiled.events.Ordered.id, orderedFrame))
local orderedDecoded = table.pack(OrderedFrame.decode(compiled.events.Ordered, orderedFrame, orderedHeader,
	Frame.compile(orderedCodecEvent, "decode")))
assert(orderedDecoded[1] and near(orderedDecoded[2].R, 128 / 255),
	"ordered RGB8 routes through the existing wrapped codec")

local nested = encode(compiled.events.Nested, {
	base = actual, swatches = { half, actual }, accent = half,
})
local nestedDecoded = table.pack(Frame.compile(compiled.events.Nested, "decode")(nested))
assert(nestedDecoded[1] and near(nestedDecoded[2].base.R, redByte / 255)
	and #nestedDecoded[2].swatches == 2 and near(nestedDecoded[2].swatches[1].R, 128 / 255)
	and near(nestedDecoded[2].accent.G, 128 / 255),
	"struct, array, and optional RGB8 leaves share composite validation")

local union = encode(compiled.events.Union, { kind = "Color", tint = actual })
local unionDecoded = table.pack(Frame.compile(compiled.events.Union, "decode")(union))
assert(unionDecoded[1] and unionDecoded[2].kind == "Color"
	and near(unionDecoded[2].tint.B, blueByte / 255),
	"tagged-union RGB8 leaves share the existing composite validator")

local packed = encode(packedCompiled.events.Packed, false, half)
local packedDecoded = table.pack(Frame.compile(packedCompiled.events.Packed, "decode")(packed))
assert(buffer.len(packed) == 7 and packedDecoded[1] and packedDecoded[2] == false
	and near(packedDecoded[3].R, 128 / 255) and buffer.readu8(packed, 3) == 0,
	"bit-packed flag masks preserve false and leave the RGB8 bytes in the existing codec body")

local method = compiled.requests.Paint
local requestBody = encode(method.request, half)
local guid = "01234567-89ab-cdef-0123-456789abcdef"
local request = assert(RpcFrame.wrap(1, method.id, 1, guid, requestBody))
local requestHeader = assert(RpcFrame.peek(request, true))
local checkedRequestBody = assert(RpcFrame.readBody(request, requestHeader,
	method.request.minimumEncodedBytes, method.request.maximumEncodedBytes))
local requestDecoded = table.pack(Frame.compile(method.request, "decode")(checkedRequestBody))
local responseBody = encode(method.response, requestDecoded[2])
local response = assert(RpcFrame.wrap(2, method.id, 1, guid, responseBody))
local responseHeader = assert(RpcFrame.peek(response, false))
local checkedResponseBody = assert(RpcFrame.readBody(response, responseHeader,
	method.response.minimumEncodedBytes, method.response.maximumEncodedBytes))
local responseDecoded = table.pack(Frame.compile(method.response, "decode")(checkedResponseBody))
assert(requestDecoded[1] and responseDecoded[1] and near(responseDecoded[2].G, 128 / 255),
	"RGB8 request and response bodies retain the existing RPC envelope")

for _, route in { { id = 6, kind = 1 }, { id = 7, kind = 2 } } do
	local event = compiled.queuedById[route.id]
	local body = encode(event, half)
	local envelope = assert(BatchFrame.wrap(route.kind, { body }, 8_192))
	local header = assert(BatchFrame.header(envelope, 8_192))
	local rows = assert(BatchFrame.scan(envelope, header, function(id) return compiled.queuedById[id] end))
	local queuedBody = assert(BatchFrame.readBody(envelope, rows[1]))
	local decoded = table.pack(Frame.compile(rows[1].event, "decode")(queuedBody))
	assert(buffer.len(body) == 6 and header.kind == route.kind and header.count == 1
		and decoded[1] and near(decoded[2].R, 128 / 255),
		`RGB8 {if route.kind == 1 then "FIFO" else "State"} retains the existing queued record route`)
end

local colors = table.create(64)
for index = 1, 64 do colors[index] = half end
local _, boundaryCompiled = define({
	name = "RGB8Unreliable900", version = 1,
	events = { Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {
		{ name = "colors", type = "array", maximumLength = 64, element = { type = "Color3RGB8" } },
		{ name = "padding", type = "string", maximumBytes = 701 },
	} } },
}, "900-byte RGB8 unreliable definition")
assert(boundaryCompiled.events.Input.maximumEncodedBytes == 900)
local boundaryFrame = encode(boundaryCompiled.events.Input, colors, string.rep("x", 701))
assert(buffer.len(boundaryFrame) == 900, "RGB8 worst-case unreliable frames retain the 900-byte cap")
reject({
	name = "RGB8Unreliable901", version = 1,
	events = { Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {
		{ name = "colors", type = "array", maximumLength = 64, element = { type = "Color3RGB8" } },
		{ name = "padding", type = "string", maximumBytes = 702 },
	} } },
}, "RGB8 unreliable schema rejects the next byte above the existing cap")

local runtime = ServerRuntime.new()
local player = runtime:addPlayer()
local server = assert(runtime.server.create(helperToken, { inboundRate = {
	perPlayer = { capacity = 4, refillPerSecond = 1 },
	aggregate = { capacity = 8, refillPerSecond = 1 },
	bytes = {
		perPlayer = { capacity = 12, refillPerSecond = 1 },
		aggregate = { capacity = 12, refillPerSecond = 1 },
	},
} }))
local calls = 0
assert(server.events.Input:Connect(function(sender, tint)
	assert(sender == player and typeof(tint) == "Color3" and near(tint.G, 128 / 255))
	calls += 1
end))
assert(server:Start())
local remote = runtime:remote()
local truncatedFrame = buffer.create(5)
buffer.writeu8(truncatedFrame, 0, 1)
buffer.writeu16(truncatedFrame, 1, 1)
remote.OnServerEvent:Fire(player, 1, truncatedFrame)
local validFrame = encode(helperCompiled.events.Input, half)
remote.OnServerEvent:Fire(player, 1, validFrame)
local counters = server:GetDiagnostics().counters
assert(calls == 1 and counters.invalidPayload == 1 and counters.perPlayerBytes == 0
	and counters.aggregateBytes == 0,
	"truncated RGB8 ingress is charged before decode, rejects whole, and never invokes handlers")
remote.OnServerEvent:Fire(player, 1, validFrame)
counters = server:GetDiagnostics().counters
assert(calls == 1 and counters.perPlayerBytes == 1,
	"the malformed frame's retained charge prevents a later RGB8 handoff")
server:Destroy()

local trailing = buffer.create(7)
buffer.copy(trailing, 0, validFrame, 0, 6)
local wrongEndpoint = buffer.create(6)
buffer.copy(wrongEndpoint, 0, validFrame, 0, 6)
buffer.writeu16(wrongEndpoint, 1, 2)
assert(Frame.compile(helperCompiled.events.Input, "decode")(trailing) == nil
	and Frame.compile(helperCompiled.events.Input, "decode")(wrongEndpoint) == nil,
	"trailing bytes and wrong endpoint IDs reject under whole-frame validation")

local legacyToken, legacyCompiled = define({
	name = "RGB8UnrelatedLegacy", version = 1,
	events = { Ping = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } } },
}, "unrelated legacy schema")
assert(legacyCompiled.descriptor == "RR1|D19:RGB8UnrelatedLegacy|V1|N1|E1,C,4:Ping,1|F5:value,u8,0,255"
	and legacyToken ~= nil,
	`definitions without RGB8 retain their legacy descriptor: {legacyCompiled.descriptor}`)

print("PASS RGB8 Color3 schema, codec, routes, limits, and malformed ingress proofs")
