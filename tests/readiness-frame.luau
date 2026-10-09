local fs = require("@lune/fs")
local luau = require("@lune/luau")

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
local ReadinessFrame = luau.load(fs.readFile("src/internal/ReadinessFrame.luau"), {
	environment = { buffer = countedBuffer },
	injectGlobals = true,
})()

assert(table.isfrozen(ReadinessFrame), "readiness frame exports must be frozen")
local exports = { peek = true, hello = true, challenge = true, ack = true, close = true }
local exportCount = 0
for key, value in ReadinessFrame do
	exportCount += 1
	assert(exports[key] and type(value) == "function", "readiness frame exposes only fixed helpers")
end
assert(exportCount == 5)

local serverGuid = "01234567-89ab-cdef-0123-456789abcdef"
local clientGuid = "fedcba98-7654-3210-fedc-ba9876543210"
local function bytes(value)
	return buffer.readstring(value, 0, buffer.len(value))
end
local function copyWithLength(value, length)
	local copy = buffer.create(length)
	buffer.copy(copy, 0, value, 0, math.min(buffer.len(value), length))
	return copy
end

local hello = ReadinessFrame.hello()
assert(bytes(hello) == string.char(2, 16), "Hello must match its exact two-byte golden")
local challenge = assert(ReadinessFrame.challenge(serverGuid, 0x04030201))
assert(bytes(challenge) == string.char(2, 17) .. serverGuid .. string.char(1, 2, 3, 4),
	"Challenge must use the canonical GUID and little-endian generation")
local ack = assert(ReadinessFrame.ack(serverGuid, 0x04030201, clientGuid, 0x08070605,
	string.char(0x05, 0x01), 10))
assert(buffer.len(ack) == 84 and bytes(ack) == string.char(2, 18) .. serverGuid
	.. string.char(1, 2, 3, 4) .. clientGuid .. string.char(5, 6, 7, 8, 0x05, 0x01),
	"Ack must match its exact two-byte-mask golden")
local close = assert(ReadinessFrame.close(serverGuid, 0x04030201, clientGuid))
assert(buffer.len(close) == 78 and bytes(close) == string.char(2, 19) .. serverGuid
	.. string.char(1, 2, 3, 4) .. clientGuid, "Close must match its exact 78-byte golden")

operations.creates, operations.copies = 0, 0
local helloHeader = assert(ReadinessFrame.peek(hello, true, 16))
assert(helloHeader.kind == 16 and table.isfrozen(helloHeader))
assert(ReadinessFrame.peek(hello, false, 16) == nil, "Hello is client-to-server only")
local challengeHeader = assert(ReadinessFrame.peek(challenge, false, 16))
assert(challengeHeader.kind == 17 and challengeHeader.serverGuid == serverGuid
	and challengeHeader.generation == 0x04030201)
assert(ReadinessFrame.peek(challenge, true, 16) == nil, "Challenge is server-to-client only")
local ackHeader = assert(ReadinessFrame.peek(ack, true, 10))
assert(ackHeader.kind == 18 and ackHeader.serverGuid == serverGuid and ackHeader.clientGuid == clientGuid
	and ackHeader.generation == 0x04030201 and ackHeader.revision == 0x08070605
	and ackHeader.maskString == string.char(0x05, 0x01) and ackHeader.listenerCount == 10)
assert(ReadinessFrame.peek(ack, true, 8) == nil, "Ack length must match the compiled listener count")
assert(ReadinessFrame.peek(ack, false, 10) == nil, "Ack is client-to-server only")
local closeHeader = assert(ReadinessFrame.peek(close, true, 16))
assert(closeHeader.kind == 19 and closeHeader.clientGuid == clientGuid)
assert(ReadinessFrame.peek(close, false, 16) == nil, "Close is client-to-server only")
assert(operations.creates == 0 and operations.copies == 0,
	"peek validates fixed frames without allocating or copying buffers")

local mutableChallenge = copyWithLength(challenge, buffer.len(challenge))
local detachedHeader = assert(ReadinessFrame.peek(mutableChallenge, false, 16))
buffer.writeu8(mutableChallenge, 2, string.byte("f"))
assert(detachedHeader.serverGuid == serverGuid, "header owns parsed scalar/string data, not the packet")

local maximumAck = assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, string.rep("\0", 8), 64))
assert(buffer.len(maximumAck) == 90 and ReadinessFrame.peek(maximumAck, true, 64) ~= nil,
	"the reviewed 64-listener helper bound is eight mask bytes")
assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, "\2", 1) == nil,
	"unused one-listener mask bits reject before construction")
assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, string.char(0, 2), 9) == nil,
	"unused high bits in a partial final mask byte reject before construction")
assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, "\0", 0) == nil
	and ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, "\0", 65) == nil,
	"listener counts stay within the reviewed fixed range")
assert(ReadinessFrame.ack("01234567-89AB-cdef-0123-456789abcdef", 1,
	clientGuid, 1, "\0", 1) == nil, "builder rejects noncanonical uppercase GUIDs")
assert(ReadinessFrame.challenge(serverGuid, 0) == nil
	and ReadinessFrame.close(serverGuid, 1.5, clientGuid) == nil,
	"builder counters must be positive integers")
assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 4_294_967_296, "\0", 1) == nil,
	"revision must fit the nonwrapping u32 range")

local function expectRejected(packet, serverSide, listenerCount, message)
	assert(ReadinessFrame.peek(packet, serverSide, listenerCount) == nil, message)
end
operations.creates, operations.copies = 0, 0
expectRejected(buffer.create(1), true, 16, "short control rejects before reads")
expectRejected(copyWithLength(hello, 3), true, 16, "Hello rejects trailing bytes")
expectRejected(copyWithLength(challenge, 41), false, 16, "truncated Challenge rejects")
expectRejected(copyWithLength(challenge, 43), false, 16, "Challenge rejects trailing bytes")
expectRejected(copyWithLength(ack, 83), true, 10, "truncated Ack rejects")
expectRejected(copyWithLength(ack, 85), true, 10, "Ack rejects trailing bytes")
expectRejected(copyWithLength(close, 77), true, 16, "truncated Close rejects")
expectRejected(copyWithLength(close, 79), true, 16, "Close rejects trailing bytes")
expectRejected(buffer.create(91), true, 64, "oversized control rejects before reads")
expectRejected(maximumAck, true, 65, "invalid listener count rejects before mask reads")

local unknownKind = copyWithLength(hello, 2)
buffer.writeu8(unknownKind, 1, 20)
expectRejected(unknownKind, true, 16, "unknown format-2 kind rejects")
local badVersion = copyWithLength(hello, 2)
buffer.writeu8(badVersion, 0, 1)
expectRejected(badVersion, true, 16, "readiness rejects another envelope format")
local badServerGuid = copyWithLength(challenge, 42)
buffer.writeu8(badServerGuid, 11, string.byte("_"))
expectRejected(badServerGuid, false, 16, "noncanonical GUID byte rejects")
local badClientGuid = copyWithLength(ack, 84)
buffer.writeu8(badClientGuid, 51, string.byte("A"))
expectRejected(badClientGuid, true, 10, "noncanonical client GUID rejects")
local zeroGeneration = copyWithLength(challenge, 42)
buffer.writeu32(zeroGeneration, 38, 0)
expectRejected(zeroGeneration, false, 16, "zero generation rejects")
local zeroRevision = copyWithLength(ack, 84)
buffer.writeu32(zeroRevision, 78, 0)
expectRejected(zeroRevision, true, 10, "zero revision rejects")
local badMask = copyWithLength(ack, 84)
buffer.writeu8(badMask, 83, 0x80)
expectRejected(badMask, true, 10, "unused mask bits reject before string extraction")
expectRejected(hello, true, false, "listener count must be a bounded integer")
assert(operations.creates == 0 and operations.copies == 0,
	"rejected controls never allocate or copy a packet")

print("PASS Relay.ReadinessFrame fixed control validation and builders")
