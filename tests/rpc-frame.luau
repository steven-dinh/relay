local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")

local operations = { creates = 0, copies = 0 }
local countedBuffer = table.clone(buffer)
countedBuffer.create = function(length)
	operations.creates += 1
	return buffer.create(length)
end
countedBuffer.copy = function(...)
	operations.copies += 1
	return buffer.copy(...)
end
local RpcFrame = luau.load(fs.readFile("src/internal/RpcFrame.luau"), {
	environment = { buffer = countedBuffer },
	injectGlobals = true,
})()

assert(table.isfrozen(RpcFrame), "RPC frame exports must be frozen")
local exportCount = 0
for key, value in RpcFrame do
	exportCount += 1
	assert((key == "peek" or key == "readBody" or key == "wrap") and type(value) == "function",
		"RPC frame must expose only its three helpers")
end
assert(exportCount == 3)

local guid = "01234567-89ab-cdef-0123-456789abcdef"
local token, issue = Definition.define({ name = "RpcFrameTest", version = 1, events = {
	Primitive = { id = 41, direction = "ClientToServer", fields = {
		{ name = "value", type = "u16" },
	} },
	Text = { id = 42, direction = "ClientToServer", fields = {
		{ name = "value", type = "string", maximumBytes = 2 },
	} },
} })
assert(token, issue and issue.message)
local compiled = Definition.get(token)
local primitiveEvent = table.clone(compiled.byId[41])
primitiveEvent.usesCodec = true
local textEvent = table.clone(compiled.byId[42])
textEvent.usesCodec = true
local function encode(event, ...)
	local result = table.pack(Frame.compile(event, "encode")(...))
	assert(result[1] == true, "fixture codec must encode")
	return result[2]
end

local primitiveBody = encode(primitiveEvent, 123)
assert(buffer.len(primitiveBody) == 5 and buffer.readu8(primitiveBody, 0) == 1
	and buffer.readu16(primitiveBody, 1) == 41, "primitive fixture must use the existing codec")
local request = assert(RpcFrame.wrap(1, 41, 7, guid, primitiveBody))
operations.creates, operations.copies = 0, 0
local requestHeader = assert(RpcFrame.peek(request, true))
assert(requestHeader.kind == 1 and requestHeader.methodId == 41 and requestHeader.callId == 7
	and requestHeader.sessionGuid == guid and requestHeader.bodyBytes == 5)
assert(operations.creates == 0 and operations.copies == 0, "peek validates without copying the body")
local headerKeys = 0
for key in requestHeader do
	headerKeys += 1
	assert(key == "kind" or key == "methodId" or key == "callId"
		or key == "sessionGuid" or key == "bodyBytes", "peek must retain only bounded header values")
end
assert(headerKeys == 5 and table.isfrozen(requestHeader))
assert(RpcFrame.peek(request, false) == nil, "request kind is server-only")

local bodyBytes = buffer.len(primitiveBody)
assert(buffer.readu16(request, 47) == 123)
buffer.writeu16(primitiveBody, 3, 999)
assert(buffer.readu16(request, 47) == 123, "wrap must own one exact copy of the codec body")
buffer.writeu16(primitiveBody, 3, 123)

operations.creates, operations.copies = 0, 0
assert(RpcFrame.readBody(request, requestHeader, 6, 8) == nil
	and operations.creates == 0 and operations.copies == 0,
	"compiled body minimum rejects before allocation or copy")
assert(RpcFrame.readBody(request, requestHeader, 5, 4) == nil
	and operations.creates == 0 and operations.copies == 0,
	"invalid compiled bounds reject before allocation or copy")
local ownedBody = assert(RpcFrame.readBody(request, requestHeader,
	primitiveEvent.minimumEncodedBytes, primitiveEvent.maximumEncodedBytes))
assert(buffer.len(ownedBody) == bodyBytes and operations.creates == 1 and operations.copies == 1,
	"bounded body extraction allocates and copies once")
buffer.writeu16(request, 47, 456)
assert(buffer.readu16(ownedBody, 3) == 123, "readBody result must own its bytes")

local success = assert(RpcFrame.wrap(2, 41, 8, guid, primitiveBody))
local successHeader = assert(RpcFrame.peek(success, false))
assert(successHeader.kind == 2 and RpcFrame.peek(success, true) == nil,
	"success kind is client-only")
for _, kind in { 3, 4 } do
	local failure = assert(RpcFrame.wrap(kind, 41, 9, guid))
	assert(buffer.len(failure) == 44 and RpcFrame.peek(failure, false).kind == kind,
		"fixed failures contain only the 44-byte envelope")
	assert(RpcFrame.peek(failure, true) == nil, "failure kinds are client-only")
	local failureWithTrailingByte = buffer.create(45)
	buffer.copy(failureWithTrailingByte, 0, failure, 0, 44)
	buffer.writeu8(failureWithTrailingByte, 44, 0)
	assert(RpcFrame.peek(failureWithTrailingByte, false) == nil,
		"failure kinds reject any trailing body byte")
end

local function copied(value, length)
	local result = buffer.create(length)
	buffer.copy(result, 0, value, 0, math.min(length, buffer.len(value)))
	return result
end
local function rejects(packet, serverSide, message)
	assert(RpcFrame.peek(packet, serverSide) == nil, message)
end

rejects(buffer.create(43), true, "truncated envelope rejects before reads")
local bodylessRequest = copied(request, 44)
rejects(bodylessRequest, true, "body-bearing request requires at least three codec bytes")
rejects(copied(request, 46), true, "truncated codec header rejects")
local overlong = buffer.create(8_193)
rejects(overlong, true, "overlong packet rejects before reads")
rejects(request, nil, "side selector must be boolean")

local badOuterVersion = copied(request, buffer.len(request))
buffer.writeu8(badOuterVersion, 0, 2)
rejects(badOuterVersion, true, "unknown envelope version rejects")
local badKind = copied(request, buffer.len(request))
buffer.writeu8(badKind, 1, 5)
rejects(badKind, true, "unknown envelope kind rejects")
local zeroMethod = copied(request, buffer.len(request))
buffer.writeu16(zeroMethod, 2, 0)
rejects(zeroMethod, true, "zero method ID rejects")
local zeroCall = copied(request, buffer.len(request))
buffer.writeu32(zeroCall, 4, 0)
rejects(zeroCall, true, "zero call ID rejects")
local uppercaseGuid = copied(request, buffer.len(request))
buffer.writeu8(uppercaseGuid, 8, string.byte("A"))
rejects(uppercaseGuid, true, "uppercase GUID bytes reject")
local malformedGuid = copied(request, buffer.len(request))
buffer.writeu8(malformedGuid, 16, string.byte("_"))
rejects(malformedGuid, true, "noncanonical GUID separators reject")
local badCodecVersion = copied(request, buffer.len(request))
buffer.writeu8(badCodecVersion, 44, 2)
rejects(badCodecVersion, true, "unknown body codec version rejects")
local badInnerMethod = copied(request, buffer.len(request))
buffer.writeu16(badInnerMethod, 45, 42)
rejects(badInnerMethod, true, "inner and outer method IDs must match")

operations.creates, operations.copies = 0, 0
assert(RpcFrame.wrap(1, 42, 1, guid, primitiveBody) == nil
	and RpcFrame.wrap(1, 41, 1, "short", primitiveBody) == nil
	and RpcFrame.wrap(1, 41, 1, "01234567-89AB-cdef-0123-456789abcdef", primitiveBody) == nil
	and operations.creates == 0 and operations.copies == 0,
	"outbound method identity and canonical GUID are checked before allocation")
assert(RpcFrame.wrap(3, 41, 1, guid, primitiveBody) == nil,
	"failure kinds cannot carry bodies")

local shortCodecBody = buffer.create(3)
buffer.writeu8(shortCodecBody, 0, 1)
buffer.writeu16(shortCodecBody, 1, 42)
local shortPacket = assert(RpcFrame.wrap(1, 42, 1, guid, shortCodecBody))
local shortHeader = assert(RpcFrame.peek(shortPacket, true))
operations.creates, operations.copies = 0, 0
assert(RpcFrame.readBody(shortPacket, shortHeader,
	textEvent.minimumEncodedBytes, textEvent.maximumEncodedBytes) == nil
	and operations.creates == 0 and operations.copies == 0,
	"body shorter than the compiled shape rejects before allocation")

local tooLongCodecBody = buffer.create(8)
buffer.copy(tooLongCodecBody, 0, encode(textEvent, ""), 0, 5)
buffer.writeu8(tooLongCodecBody, 0, 1)
buffer.writeu16(tooLongCodecBody, 1, 42)
local tooLongPacket = assert(RpcFrame.wrap(1, 42, 2, guid, tooLongCodecBody))
local tooLongHeader = assert(RpcFrame.peek(tooLongPacket, true))
operations.creates, operations.copies = 0, 0
assert(RpcFrame.readBody(tooLongPacket, tooLongHeader,
	textEvent.minimumEncodedBytes, textEvent.maximumEncodedBytes) == nil
	and operations.creates == 0 and operations.copies == 0,
	"body longer than the compiled shape rejects before allocation")

local textBody = encode(textEvent, "")
local textBodyWithTrailingByte = buffer.create(buffer.len(textBody) + 1)
buffer.copy(textBodyWithTrailingByte, 0, textBody, 0, buffer.len(textBody))
buffer.writeu8(textBodyWithTrailingByte, buffer.len(textBody), 255)
local trailingPacket = assert(RpcFrame.wrap(1, 42, 3, guid, textBodyWithTrailingByte))
local trailingHeader = assert(RpcFrame.peek(trailingPacket, true))
local trailingBody = assert(RpcFrame.readBody(trailingPacket, trailingHeader,
	textEvent.minimumEncodedBytes, textEvent.maximumEncodedBytes))
assert(Frame.compile(textEvent, "decode")(trailingBody) == nil,
	"existing codec rejects a structurally valid body with trailing bytes")

local malformedStringBody = buffer.create(textEvent.maximumEncodedBytes)
buffer.writeu8(malformedStringBody, 0, 1)
buffer.writeu16(malformedStringBody, 1, 42)
buffer.writeu16(malformedStringBody, 3, 3)
buffer.writeu8(malformedStringBody, 5, string.byte("a"))
buffer.writeu8(malformedStringBody, 6, string.byte("b"))
local malformedStringPacket = assert(RpcFrame.wrap(1, 42, 4, guid, malformedStringBody))
local malformedStringHeader = assert(RpcFrame.peek(malformedStringPacket, true))
local malformedStringCopy = assert(RpcFrame.readBody(malformedStringPacket, malformedStringHeader,
	textEvent.minimumEncodedBytes, textEvent.maximumEncodedBytes))
assert(Frame.compile(textEvent, "decode")(malformedStringCopy) == nil,
	"existing codec rejects an oversized declared string length after bounded extraction")

local maximumBody = buffer.create(8_148)
buffer.writeu8(maximumBody, 0, 1)
buffer.writeu16(maximumBody, 1, 41)
local maximumPacket = assert(RpcFrame.wrap(2, 41, 10, guid, maximumBody))
assert(buffer.len(maximumPacket) == 8_192 and RpcFrame.peek(maximumPacket, false) ~= nil,
	"exact total byte limit is accepted")
local overBudgetBody = buffer.create(8_149)
buffer.writeu8(overBudgetBody, 0, 1)
buffer.writeu16(overBudgetBody, 1, 41)
operations.creates, operations.copies = 0, 0
assert(RpcFrame.wrap(2, 41, 11, guid, overBudgetBody) == nil
	and operations.creates == 0 and operations.copies == 0,
	"body above the envelope budget rejects before allocation")

print("PASS Relay.RpcFrame bounded envelope validation and body ownership")
