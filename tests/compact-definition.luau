local Schema = require("../src/Schema")
local Definition = require("../src/Definition")

local vector3 = Schema.quantizedVector3(-4, 4, 0.5)
local vector2 = Schema.quantizedVector2(0, 256, 1)
local frame = Schema.compactCFrame(-16, 16, 0.25)

local function field(shape, name)
	local result = table.clone(shape)
	result.name = name
	return result
end

local function spec(shape, delivery, queue)
	return { name = "CompactDefinition", version = 1, events = { Input = {
		id = 1, direction = "ClientToServer", delivery = delivery, queue = queue,
		fields = { field(shape, "value") },
	} } }
end

local function valid(source)
	local token, issue = Definition.define(source)
	assert(token, issue and issue.message)
	return Definition.get(token), token
end

local function invalid(source, message)
	local token, issue = Definition.define(source)
	assert(token == nil and issue and issue.code == "InvalidDefinition", "expected InvalidDefinition")
	if message then assert(string.find(issue.message, message, 1, true), issue.message) end
end

local vector3Schema = valid(spec(vector3))
local vector3Field = vector3Schema.events.Input.fields[1]
assert(vector3Schema.events.Input.usesCodec and vector3Field.width == 3
	and vector3Field.maximumComponentError > 0.25 and vector3Field.maximumDepth == 0)
assert(string.match(vector3Schema.descriptor, "^RR11|D")
	and string.find(vector3Schema.descriptor, "|VQ1", 1, true)
	and vector3Field.descriptorToken == "VQ1,Vector3,c010000000000000,4010000000000000,3fe0000000000000,16,1",
	"Vector3 pins its exact native scalar grid and protocol token")
assert(vector3Schema.events.Input.minimumEncodedBytes == 6
	and vector3Schema.events.Input.maximumEncodedBytes == 6)

local narrow2 = valid(spec(Schema.quantizedVector2(-1, 1, 1))).events.Input
local wide2 = valid(spec(vector2)).events.Input
assert(narrow2.fields[1].width == 2 and narrow2.maximumEncodedBytes == 5
	and wide2.fields[1].width == 4 and wide2.maximumEncodedBytes == 7,
	"Vector2 uses one or two bytes per component from the derived grid width")
local wide3 = valid(spec(Schema.quantizedVector3(0, 256, 1))).events.Input
assert(wide3.fields[1].width == 6 and wide3.maximumEncodedBytes == 9)

local cframeSchema = valid(spec(frame))
local cframeField = cframeSchema.events.Input.fields[1]
assert(string.match(cframeSchema.descriptor, "^RR12|D")
	and string.find(cframeSchema.descriptor, "|CF1", 1, true)
	and cframeField.width == 9 and cframeSchema.events.Input.maximumEncodedBytes == 12
	and cframeField.descriptorToken == "CF1,c030000000000000,4030000000000000,3fd0000000000000,128,1,XYZu16",
	"compact CFrame pins position grid and the six-byte XYZ angle form")
local wideFrame = valid(spec(Schema.compactCFrame(0, 256, 1))).events.Input
assert(wideFrame.fields[1].width == 12 and wideFrame.maximumEncodedBytes == 15,
	"wide CFrame position codes use two bytes while rotation stays six bytes")

local legacy = valid({ name = "CompatReliable", version = 1, events = { Reliable = {
		id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u16" } },
	} } })
assert(legacy.descriptor == "RR1|D14:CompatReliable|V1|N1|E1,C,8:Reliable,1|F5:value,u16,0,65535",
	"definitions without compact shapes keep the literal legacy descriptor")

local zeroCapacity = spec({ type = "array", maximumLength = 0, element = vector3 })
local zeroCompiled = valid(zeroCapacity)
assert(string.match(zeroCompiled.descriptor, "^RR11|D")
	and zeroCompiled.events.Input.fields[1].maximumEncodedBytes == 2,
	"a compact vector authored below a zero-capacity array still selects its protocol")

for _, sample in {
	{ "quantizedVector3", 0.1, 1, 0.1, ".minimum" },
	{ "quantizedVector2", 0, 0.1, 0.1, ".maximum" },
	{ "compactCFrame", 0.1, 1, 0.1, ".minimum" },
} do
	local shape = if sample[1] == "compactCFrame"
		then Schema.compactCFrame(sample[2], sample[3], sample[4])
		else if sample[1] == "quantizedVector3"
			then Schema.quantizedVector3(sample[2], sample[3], sample[4])
			else Schema.quantizedVector2(sample[2], sample[3], sample[4])
	invalid(spec(shape), sample[5])
end
invalid(spec(Schema.quantizedVector3(0, 2 ^ -122, 2 ^ -123)), "native vector precision")
invalid(spec(Schema.quantizedVector2(0, 1, 0.3)), "range endpoints")

local extraVectorKey = table.clone(vector3)
extraVectorKey.extra = true
invalid(spec(extraVectorKey), "unknown key")
local extraFrameKey = table.clone(frame)
extraFrameKey.step = extraFrameKey.positionStep
invalid(spec(extraFrameKey), "unknown key")
local missingFrameStep = table.clone(frame)
missingFrameStep.positionStep = nil
invalid(spec(missingFrameStep), "positionStep")
local missingVectorStep = table.clone(vector3)
missingVectorStep.step = nil
invalid(spec(missingVectorStep))
invalid(spec({ type = "quantizedVector3", minimum = 0, maximum = 1, step = "1" }))
invalid(spec({ type = "compactCFrame", minimum = 0, maximum = math.huge, positionStep = 1 }))
invalid(spec({ type = "set", maximumSize = 1, element = vector3 }), "set elements")
invalid(spec({ type = "map", maximumSize = 1, key = vector3,
	value = { type = "boolean" } }), "map keys")

local function nestedArray(shape, count)
	for _ = 1, count do shape = { type = "array", maximumLength = 1, element = shape } end
	return shape
end
assert(valid(spec(nestedArray(vector3, 4))).events.Input.fields[1].maximumDepth == 4)
invalid(spec(nestedArray(vector3, 5)), "depth")
assert(valid(spec({ type = "array", maximumLength = 64, element = vector3 })).events.Input.fields[1].maximumLength == 64)
invalid(spec({ type = "array", maximumLength = 65, element = vector3 }), "maximumLength")

local tuple8 = {}
for index = 1, 8 do tuple8[index] = field(vector3, `v{index}`) end
assert(valid({ name = "CompactTuple", version = 1, events = { Input = {
		id = 1, direction = "ClientToServer", fields = tuple8,
	} } }).events.Input.maximumEncodedBytes == 27)
tuple8[9] = field(vector3, "v9")
invalid({ name = "CompactTuple", version = 1, events = { Input = {
		id = 1, direction = "ClientToServer", fields = tuple8,
	} } }, "at most 8 entries")

local endpoints = {}
for index = 1, 64 do
	endpoints[`Event{index}`] = { id = index, direction = "ClientToServer",
		fields = if index == 1 then { field(vector3, "value") } else {} }
end
local endpoint64 = valid({ name = "CompactEndpoints", version = 1, events = endpoints })
local endpointCount = 0
for _ in endpoint64.events do endpointCount += 1 end
assert(string.match(endpoint64.descriptor, "^RR11|D") and endpointCount == 64)
endpoints.Event65 = { id = 65, direction = "ClientToServer", fields = {} }
invalid({ name = "CompactEndpoints", version = 1, events = endpoints }, "64 endpoints")

local function authoredTree(name, innerCount, includeVector)
	local inner = {}
	for group = 1, innerCount do
		local leaves = {}
		for leaf = 1, 8 do
			local leafName = string.char(96 + leaf)
			leaves[leaf] = if includeVector and group == 1 and leaf == 1
				then field(vector3, leafName) else { name = leafName, type = "struct", fields = {} }
		end
		inner[group] = { name = string.char(96 + group), type = "struct", fields = leaves }
	end
	return { name = name, type = "struct", fields = inner }
end
local authored256 = { authoredTree("a", 8, true), authoredTree("b", 8, false),
	authoredTree("c", 8, false), authoredTree("d", 4, false) }
for index, shape in authored256 do
	if index ~= nil then shape.name = string.char(96 + index) end
end
local authoredSpec = { name = "CompactNodes", version = 1, events = { Input = {
	id = 1, direction = "ClientToServer", fields = authored256,
} } }
local authoredCompiled = valid(authoredSpec)
assert(authoredCompiled.events.Input.maximumElements == 256,
	"compact leaves preserve the existing authored and expanded node ceiling")
authoredSpec.events.Input.fields[5] = { name = "e", type = "boolean" }
invalid(authoredSpec, "256")

local expanded = { type = "array", maximumLength = 51,
	element = { type = "array", maximumLength = 4, element = vector3 } }
assert(valid(spec(expanded)).events.Input.maximumElements == 256,
	"expanded array nodes retain the exact 256-node boundary")
local expandedOverflow = spec(expanded)
expandedOverflow.events.Input.fields[2] = { name = "extra", type = "boolean" }
invalid(expandedOverflow, "expanded node count")

local function padded(shape, bytes, delivery, queue)
	local fields = { field(shape, "value"), { name = "padding", type = "string", maximumBytes = bytes } }
	return { name = "CompactSize", version = 1, events = { Input = {
		id = 1, direction = "ClientToServer", delivery = delivery, queue = queue, fields = fields,
	} } }
end
local reliableMaximum = { name = "CompactSize", version = 1, events = { Input = {
	id = 1, direction = "ClientToServer", fields = {
		{ name = "texts", type = "array", maximumLength = 7,
			element = { type = "string", maximumBytes = 1_024 } },
		{ name = "padding", type = "string", maximumBytes = 1_000 },
		field(vector3, "vector"),
	},
} } }
assert(valid(reliableMaximum).events.Input.maximumEncodedBytes == 8_192)
reliableMaximum.events.Input.fields[2].maximumBytes += 1
invalid(reliableMaximum, "8192")
assert(valid(padded(vector3, 892, "Unreliable")).events.Input.maximumEncodedBytes == 900)
invalid(padded(vector3, 893, "Unreliable"), "900")
assert(valid(padded(vector3, 884, "OrderedUnreliable")).events.Input.maximumEncodedBytes == 900)
invalid(padded(vector3, 885, "OrderedUnreliable"), "892 bytes")
local queuedReliable = table.clone(reliableMaximum)
queuedReliable.name = "CompactQueue"
queuedReliable.events = table.clone(reliableMaximum.events)
queuedReliable.events.Input = table.clone(reliableMaximum.events.Input)
queuedReliable.events.Input.queue = "Batch"
queuedReliable.events.Input.fields = table.clone(reliableMaximum.events.Input.fields)
queuedReliable.events.Input.fields[2] = table.clone(reliableMaximum.events.Input.fields[2])
queuedReliable.events.Input.fields[2].maximumBytes = 995
assert(valid(queuedReliable).queuedById[1].maximumEncodedBytes == 8_187)
queuedReliable.events.Input.fields[2].maximumBytes += 1
invalid(queuedReliable, "8187")
assert(valid(padded(vector3, 887, "Unreliable", "State")).queuedById[1].maximumEncodedBytes == 895)
invalid(padded(vector3, 888, "Unreliable", "State"), "895")

local rpcFields = {
	{ name = "texts", type = "array", maximumLength = 7,
		element = { type = "string", maximumBytes = 1_024 } },
	{ name = "padding", type = "string", maximumBytes = 956 },
	field(vector3, "vector"),
}
local rpc = { name = "CompactRpc", version = 1, events = {}, requests = {
	Lookup = { id = 1, request = rpcFields, response = { type = "boolean" } },
} }
assert(valid(rpc).requests.Lookup.request.maximumEncodedBytes == 8_148)
rpc.requests.Lookup.request[2].maximumBytes += 1
invalid(rpc, "8148 bytes")

local rpcResponse = { name = "CompactRpcResponse", version = 1, events = {}, requests = {
	Lookup = { id = 1, request = {}, response = { type = "struct", fields = {
		{ name = "texts", type = "array", maximumLength = 7,
			element = { type = "string", maximumBytes = 1_024 } },
		{ name = "padding", type = "string", maximumBytes = 956 },
		field(vector3, "vector"),
	} } },
} }
assert(valid(rpcResponse).requests.Lookup.response.maximumEncodedBytes == 8_148)
rpcResponse.requests.Lookup.response.fields[2].maximumBytes += 1
invalid(rpcResponse, "8148 bytes")

print("PASS compact native definition identity, exact caps, and legacy precedence")
