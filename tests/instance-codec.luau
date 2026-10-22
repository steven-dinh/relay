local roblox = require("@lune/roblox")
local support = require("./support/NativeCodec")
local Definition = require("../src/Definition")
local OrderedFrame = require("../src/internal/OrderedFrame")

local World = support.World
local InstanceRefs = support.InstanceRefs
local Frame = support.loadFrame()

local root = roblox.Instance.new("Folder")
root.Parent = World
local context = { server = true, root = root }
local part = roblox.Instance.new("Part")
part.Parent = root
local otherPart = roblox.Instance.new("Part")
otherPart.Parent = root
local model = roblox.Instance.new("Model")
model.Parent = root
local modelPart = roblox.Instance.new("Part")
modelPart.Parent = model
local siblingRoot = roblox.Instance.new("Folder")
siblingRoot.Parent = World
local siblingPart = roblox.Instance.new("Part")
siblingPart.Parent = siblingRoot

local function instance(className)
	return { type = "Instance", className = className, containsReferences = true,
		minimumEncodedBytes = 1, maximumEncodedBytes = 1 }
end

local function prepareBounds(shape)
	if shape.type == "string" or shape.type == "buffer" then
		shape.minimumBytes = shape.minimumBytes or 0
		shape.countBytes = shape.countBytes or 2
	elseif shape.type == "array" then
		shape.minimumLength = shape.minimumLength or 0
		shape.countBytes = shape.countBytes or 2
		prepareBounds(shape.element)
	elseif shape.type == "set" or shape.type == "map" then
		shape.minimumSize = shape.minimumSize or 0
		shape.countBytes = shape.countBytes or 2
		if shape.element then prepareBounds(shape.element) end
		if shape.key then prepareBounds(shape.key) end
		if shape.value then prepareBounds(shape.value) end
	elseif shape.type == "optional" then
		prepareBounds(shape.value)
	elseif shape.type == "struct" then
		for _, field in shape.fields do prepareBounds(field) end
	elseif shape.type == "taggedUnion" then
		for _, variant in shape.variants do prepareBounds(variant.shape) end
	end
end

local function compileEvent(id, fields, maximumReferences)
	local minimumEncodedBytes, maximumEncodedBytes = InstanceRefs.HEADER_BYTES, InstanceRefs.HEADER_BYTES
	for _, field in fields do
		prepareBounds(field)
		minimumEncodedBytes += field.minimumEncodedBytes
		maximumEncodedBytes += field.maximumEncodedBytes
	end
	local event = { id = id, delivery = "Reliable", usesCodec = true, hasReferences = true,
		maximumReferences = maximumReferences, fields = fields,
		minimumEncodedBytes = minimumEncodedBytes, maximumEncodedBytes = maximumEncodedBytes }
	return event, Frame.compile(event, "encode", context), Frame.compile(event, "decode", context)
end

local function copy(value, length)
	local result = buffer.create(length)
	buffer.copy(result, 0, value, 0, math.min(length, buffer.len(value)))
	return result
end

local directEvent, directEncode, directDecode = compileEvent(1, { instance("BasePart") }, 1)
local direct = table.pack(directEncode(part))
assert(direct.n == 3 and direct[1] == true and direct[3] == part)
assert(buffer.len(direct[2]) == 5 and buffer.readu8(direct[2], 0) == InstanceRefs.FORMAT
	and buffer.readu16(direct[2], 1) == directEvent.id and buffer.readu8(direct[2], 3) == 1
	and buffer.readu8(direct[2], 4) == 1, "format 4 writes one ordered reference slot")
local directResult = table.pack(directDecode(direct[2], direct[3]))
assert(directResult.n == 2 and directResult[1] == true and directResult[2] == part,
	"direct Instance references round-trip through Frame")
assert(directEncode(model) == nil and directEncode(siblingPart) == nil,
	"class and server-root scope checks reject before encoding")
assert(InstanceRefs.valid(root, "Folder", context) and InstanceRefs.valid(modelPart, "BasePart", context)
	and not InstanceRefs.valid(siblingPart, "BasePart", context)
	and InstanceRefs.valid(siblingPart, "BasePart"),
	"server scope includes its live root; client checks require only a live game descendant")
assert(not InstanceRefs.valid(World, "Instance", context), "DataModel is a root only, never a payload reference")

assert(directDecode(direct[2]) == nil and directDecode(direct[2], part, part) == nil
	and directDecode(direct[2], nil) == nil, "reference frame requires exact non-nil sidecar arity")
assert(directDecode(direct[2], model) == nil and directDecode(direct[2], siblingPart) == nil,
	"decoder rejects wrong class and out-of-scope references")
assert(InstanceRefs.scopeArguments(context, direct[2], part)
	and not InstanceRefs.scopeArguments(context, direct[2], siblingPart),
	"pre-send scope check validates every owned reference")

local badVersion = copy(direct[2], 5)
buffer.writeu8(badVersion, 0, 1)
local badEndpoint = copy(direct[2], 5)
buffer.writeu16(badEndpoint, 1, 2)
local badOrdinal = copy(direct[2], 5)
buffer.writeu8(badOrdinal, 4, 0)
local repeatedOrdinal = copy(direct[2], 5)
buffer.writeu8(repeatedOrdinal, 4, 2)
local badCount = copy(direct[2], 5)
buffer.writeu8(badCount, 3, 17)
local truncated = copy(direct[2], 4)
local trailing = copy(direct[2], 6)
assert(directDecode(badVersion, part) == nil and directDecode(badEndpoint, part) == nil
	and directDecode(badOrdinal, part) == nil and directDecode(repeatedOrdinal, part) == nil
	and directDecode(badCount, part) == nil and directDecode(truncated, part) == nil
	and directDecode(trailing, part) == nil, "malformed, truncated, and trailing frames reject")

local detached = roblox.Instance.new("Folder")
local detachedChild = roblox.Instance.new("Part")
detachedChild.Parent = detached
assert(directEncode(detachedChild) == nil, "a non-nil parent in a detached tree is not live")
local detachedContext = { server = true, root = detached }
assert(not InstanceRefs.isLiveRoot(detached)
	and Frame.compile(directEvent, "encode", detachedContext)(part) == nil,
	"detached roots and roots outside the live DataModel reject")
part.Parent = nil
assert(directEncode(part) == nil and not InstanceRefs.scopeArguments(context, direct[2], part),
	"destroyed or unparented references fail at each use")
part.Parent = root

local repeatedFields = {
		{ name = "first", type = "Instance", className = "BasePart", containsReferences = true,
			minimumEncodedBytes = 1, maximumEncodedBytes = 1 },
		{ name = "second", type = "Instance", className = "BasePart", containsReferences = true,
			minimumEncodedBytes = 1, maximumEncodedBytes = 1 },
	}
local _, repeatedEncode, repeatedDecode = compileEvent(2, {
	{ type = "struct", containsReferences = true, minimumEncodedBytes = 2, maximumEncodedBytes = 2,
		fields = repeatedFields },
}, 2)
local repeated = table.pack(repeatedEncode({ first = part, second = part }))
assert(repeated.n == 4 and repeated[1] == true and repeated[3] == part and repeated[4] == part
	and buffer.readu8(repeated[2], 3) == 2 and buffer.readu8(repeated[2], 4) == 1
	and buffer.readu8(repeated[2], 5) == 2, "repeated object occurrences use distinct slots")
local repeatedResult = table.pack(repeatedDecode(repeated[2], repeated[3], repeated[3]))
assert(repeatedResult.n == 2 and repeatedResult[1] == true
	and repeatedResult[2].first == part and repeatedResult[2].second == part,
	"struct slot order round-trips repeated references")
local outOfOrder = copy(repeated[2], buffer.len(repeated[2]))
buffer.writeu8(outOfOrder, 4, 2)
local repeatedSlot = copy(repeated[2], buffer.len(repeated[2]))
buffer.writeu8(repeatedSlot, 5, 1)
assert(repeatedDecode(outOfOrder, part, part) == nil and repeatedDecode(repeatedSlot, part, part) == nil,
	"decoder requires reference slots in exact traversal order")

local _, optionalEncode, optionalDecode = compileEvent(3, {
	{ type = "optional", containsReferences = true, minimumEncodedBytes = 1, maximumEncodedBytes = 2,
		value = instance("BasePart") },
}, 1)
local absent = table.pack(optionalEncode(nil))
assert(absent.n == 2 and absent[1] == true and buffer.readu8(absent[2], 3) == 0
	and buffer.readu8(absent[2], 4) == 0, "optional absence has no reference slot")
local absentResult = table.pack(optionalDecode(absent[2]))
assert(absentResult.n == 2 and absentResult[1] == true and absentResult[2] == nil,
	"explicit optional absence round-trips without a sidecar")
local present = table.pack(optionalEncode(part))
local presentResult = table.pack(optionalDecode(present[2], present[3]))
assert(present.n == 3 and buffer.readu8(present[2], 3) == 1 and buffer.readu8(present[2], 4) == 1
	and presentResult[1] == true and presentResult[2] == part, "present optional references use one slot")
assert(optionalEncode() == nil and optionalDecode(absent[2], nil) == nil,
	"optional values still require exact event and sidecar arity")
local unusedSlot = copy(absent[2], buffer.len(absent[2]))
buffer.writeu8(unusedSlot, 3, 1)
assert(optionalDecode(unusedSlot, part) == nil,
	"decoder rejects a live but unused sidecar reference")

local arrayElement = instance("BasePart")
local arrayShape = { type = "array", containsReferences = true, minimumEncodedBytes = 2,
	maximumEncodedBytes = 4, maximumLength = 2, element = arrayElement }
local _, arrayEncode, arrayDecode = compileEvent(4, { arrayShape }, 2)
local arrayFrame = table.pack(arrayEncode({ part, otherPart }))
local arrayResult = table.pack(arrayDecode(arrayFrame[2], arrayFrame[3], arrayFrame[4]))
assert(arrayResult.n == 2 and arrayResult[1] == true and arrayResult[2][1] == part
	and arrayResult[2][2] == otherPart, "bounded reference arrays preserve slot order")
local emptyArray = table.pack(arrayEncode({}))
assert(emptyArray[1] == true and arrayEncode({ part, otherPart, modelPart }) == nil,
	"array capacity is checked before reference traversal")

local mapShape = { type = "map", containsReferences = true, minimumEncodedBytes = 2,
	maximumEncodedBytes = 28, maximumSize = 2,
	key = { type = "string", maximumBytes = 10, minimumEncodedBytes = 2, maximumEncodedBytes = 12 },
	value = instance("BasePart") }
local _, mapEncode, mapDecode = compileEvent(5, { mapShape }, 2)
local mapFrame = table.pack(mapEncode({ left = part, right = otherPart }))
local mapResult = table.pack(mapDecode(mapFrame[2], table.unpack(mapFrame, 3, mapFrame.n)))
assert(mapResult.n == 2 and mapResult[1] == true and mapResult[2].left == part
	and mapResult[2].right == otherPart, "map value slot ordering follows the encoded entries")

local unionVariant = { type = "struct", containsReferences = true, minimumEncodedBytes = 1,
	maximumEncodedBytes = 1, fields = {
		{ name = "target", type = "Instance", className = "BasePart", containsReferences = true,
			minimumEncodedBytes = 1, maximumEncodedBytes = 1 },
	} }
local unionShape = { type = "taggedUnion", containsReferences = true, minimumEncodedBytes = 2,
	maximumEncodedBytes = 2, tag = "kind", variants = { { label = "target", shape = unionVariant } } }
local _, unionEncode, unionDecode = compileEvent(6, { unionShape }, 1)
local unionFrame = table.pack(unionEncode({ kind = "target", target = part }))
local unionResult = table.pack(unionDecode(unionFrame[2], unionFrame[3]))
assert(unionResult.n == 2 and unionResult[1] == true and unionResult[2].kind == "target"
	and unionResult[2].target == part, "tagged-union reference slots round-trip")

local limitedEvent = { id = 7, delivery = "Reliable", usesCodec = true, hasReferences = true,
	maximumReferences = 2, minimumEncodedBytes = 8, maximumEncodedBytes = 8_192,
	fields = {
		{ type = "Instance", className = "BasePart", containsReferences = true,
			minimumEncodedBytes = 1, maximumEncodedBytes = 1 },
		{ type = "Instance", className = "BasePart", containsReferences = true,
			minimumEncodedBytes = 1, maximumEncodedBytes = 1 },
		{ type = "string", maximumBytes = 8_184, minimumEncodedBytes = 2, maximumEncodedBytes = 8_186 },
	} }
for _, field in limitedEvent.fields do prepareBounds(field) end
local limitedEncode = Frame.compile(limitedEvent, "encode", context)
assert(limitedEncode(part, otherPart, string.rep("x", 8_184)) == nil,
	"reference admission includes eight bytes per sidecar before output allocation")

local tooManyReferences = { direct[2] }
for _ = 1, 17 do table.insert(tooManyReferences, part) end
assert(not InstanceRefs.scopeArguments(context, direct[2], nil)
	and not InstanceRefs.scopeArguments(context, table.unpack(tooManyReferences)),
	"pre-send validation rejects missing and over-limit reference slots")

local function routeField(name, shape)
	local result = table.clone(shape)
	result.name = name
	return result
end

local function defineRoutes(name, bitPacking, events)
	local token, issue = Definition.define({ name = name, version = 1, bitPacking = bitPacking, events = events })
	assert(token, issue and issue.message or "reference route definition rejected")
	return Definition.get(token)
end

local routes = defineRoutes("ReferenceCodecRoutes", false, {
	Reliable = { id = 10, direction = "ClientToServer", fields = {
		routeField("target", { type = "Instance", className = "BasePart" }),
		routeField("text", { type = "string", maximumBytes = 32 }),
	} },
	Unreliable = { id = 11, direction = "ClientToServer", delivery = "Unreliable", fields = {
		routeField("target", { type = "Instance", className = "BasePart" }),
		routeField("text", { type = "string", maximumBytes = 32 }),
	} },
	Ordered = { id = 12, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
		routeField("target", { type = "Instance", className = "BasePart" }),
		routeField("text", { type = "string", maximumBytes = 32 }),
	} },
})
local packedRoutes = defineRoutes("PackedReferenceCodecRoutes", true, {
	Unreliable = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {
		routeField("active", { type = "boolean" }),
		routeField("target", { type = "Instance", className = "BasePart" }),
	} },
	Ordered = { id = 2, direction = "ClientToServer", delivery = "OrderedUnreliable", fields = {
		routeField("active", { type = "boolean" }),
		routeField("target", { type = "Instance", className = "BasePart" }),
	} },
})

local function routeRoundTrip(event, ordered, ...)
	local codecEvent = if ordered then OrderedFrame.codecEvent(event) else event
	local encode = Frame.compile(codecEvent, "encode", context)
	local decode = Frame.compile(codecEvent, "decode", context)
	local encoded = table.pack(encode(...))
	assert(encoded[1] == true and typeof(encoded[2]) == "buffer",
		`{event.delivery} reference codec accepts a valid Instance payload`)
	assert(buffer.readu8(encoded[2], 0) == InstanceRefs.FORMAT and buffer.readu8(encoded[2], 3) == 1,
		"reference codec uses format 4 and records one sidecar")
	local sidecars = table.pack(table.unpack(encoded, 3, encoded.n))
	if not ordered then
		return table.pack(decode(encoded[2], table.unpack(sidecars, 1, sidecars.n)))
	end
	assert(codecEvent.delivery == "Unreliable", "OrderedUnreliable selects the unreliable codec limit")
	local packet, outgoingSidecars = OrderedFrame.wrap(event, encoded[2], 1, 1, sidecars)
	assert(packet and outgoingSidecars == sidecars, "ordered wrapper retains reference sidecars")
	local header = OrderedFrame.peek(event, event.id, packet, outgoingSidecars)
	assert(header, "ordered wrapper admits a valid format-6 reference packet")
	return table.pack(OrderedFrame.decode(event, packet, header, decode, outgoingSidecars))
end

local reliableRoute = routeRoundTrip(routes.events.Reliable, false, part, "reliable")
assert(reliableRoute.n == 3 and reliableRoute[1] and reliableRoute[2] == part and reliableRoute[3] == "reliable")
local unreliableRoute = routeRoundTrip(routes.events.Unreliable, false, part, "unreliable")
assert(unreliableRoute.n == 3 and unreliableRoute[1] and unreliableRoute[2] == part
	and unreliableRoute[3] == "unreliable")
local orderedRoute = routeRoundTrip(routes.events.Ordered, true, part, "ordered")
assert(orderedRoute.n == 3 and orderedRoute[1] and orderedRoute[2] == part and orderedRoute[3] == "ordered")

local packedUnreliableRoute = routeRoundTrip(packedRoutes.events.Unreliable, false, true, part)
assert(packedUnreliableRoute.n == 3 and packedUnreliableRoute[1] and packedUnreliableRoute[2] == true
	and packedUnreliableRoute[3] == part, "bit-packed unreliable references round trip")
local packedOrderedRoute = routeRoundTrip(packedRoutes.events.Ordered, true, true, part)
assert(packedOrderedRoute.n == 3 and packedOrderedRoute[1] and packedOrderedRoute[2] == true
	and packedOrderedRoute[3] == part, "bit-packed ordered references round trip")

local budget = defineRoutes("ReferenceCodecBudget", false, {
	Reliable = { id = 1, direction = "ClientToServer", fields = {
		routeField("text", { type = "string", maximumBytes = 886 }),
		routeField("target", { type = "Instance", className = "BasePart" }),
	} },
})
local reliableBudgetEvent = budget.events.Reliable
local unreliableBudgetEvent = table.clone(reliableBudgetEvent)
unreliableBudgetEvent.delivery = "Unreliable"
unreliableBudgetEvent.maximumEncodedBytes = 900
local encodeReliable = Frame.compile(reliableBudgetEvent, "encode", context)
local decodeUnreliable = Frame.compile(unreliableBudgetEvent, "decode", context)
local encodeUnreliable = Frame.compile(unreliableBudgetEvent, "encode", context)
local exactOk, exactPacket, exactReference = encodeUnreliable(string.rep("x", 885), part)
assert(exactOk and buffer.len(exactPacket) == 892 and exactReference == part
	and decodeUnreliable(exactPacket, part) ~= nil,
	"unreliable reference codecs accept an exact 900-unit buffer-plus-sidecar budget")
local reliableOk, oversizedPacket, oversizedReference = encodeReliable(string.rep("x", 886), part)
assert(reliableOk and buffer.len(oversizedPacket) == 893 and oversizedReference == part,
	"the same reference packet remains inside the reliable 8192-unit budget")
assert(encodeUnreliable(string.rep("x", 886), part) == nil
	and decodeUnreliable(oversizedPacket, part) == nil,
	"unreliable reference encode and decode reject a packet whose sidecar pushes it over 900")

local packedBudget = defineRoutes("PackedReferenceCodecBudget", true, {
	Reliable = { id = 1, direction = "ClientToServer", fields = {
		routeField("active", { type = "boolean" }),
		routeField("text", { type = "string", maximumBytes = 885 }),
		routeField("target", { type = "Instance", className = "BasePart" }),
	} },
})
local reliablePackedBudgetEvent = packedBudget.events.Reliable
local unreliablePackedBudgetEvent = table.clone(reliablePackedBudgetEvent)
unreliablePackedBudgetEvent.delivery = "Unreliable"
unreliablePackedBudgetEvent.maximumEncodedBytes = 900
local encodeReliablePacked = Frame.compile(reliablePackedBudgetEvent, "encode", context)
local encodeUnreliablePacked = Frame.compile(unreliablePackedBudgetEvent, "encode", context)
local decodeUnreliablePacked = Frame.compile(unreliablePackedBudgetEvent, "decode", context)
local packedExactOk, packedExactPacket, packedExactReference = encodeUnreliablePacked(true, string.rep("x", 884), part)
assert(packedExactOk and buffer.len(packedExactPacket) == 892 and packedExactReference == part
	and decodeUnreliablePacked(packedExactPacket, part) ~= nil,
	"bit-packed unreliable codecs accept the exact complete-byte budget")
local packedReliableOk, packedOversizedPacket, packedOversizedReference = encodeReliablePacked(true,
	string.rep("x", 885), part)
assert(packedReliableOk and buffer.len(packedOversizedPacket) == 893 and packedOversizedReference == part,
	"bit-packed references remain available on reliable codec routes")
assert(encodeUnreliablePacked(true, string.rep("x", 885), part) == nil
	and decodeUnreliablePacked(packedOversizedPacket, part) == nil,
	"bit-packed unreliable encode and decode reject complete payloads above 900")

print("PASS Relay.InstanceRefs reliable/unreliable/ordered composite and packed codec checks")
