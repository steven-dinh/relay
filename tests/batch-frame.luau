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
local BatchFrame = luau.load(fs.readFile("src/internal/BatchFrame.luau"), {
	environment = { buffer = countedBuffer },
	injectGlobals = true,
})()
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		buffer = countedBuffer,
		require = function(path)
			assert(path == "./CompositeCodec")
			return CompositeCodec
		end,
	},
	injectGlobals = true,
})()

assert(table.isfrozen(BatchFrame), "batch frame exports must be frozen")
local exports = { header = true, scan = true, readBody = true, wrap = true }
local exportCount = 0
for key, value in BatchFrame do
	exportCount += 1
	assert(exports[key] and type(value) == "function", "batch frame exposes only fixed helpers")
end
assert(exportCount == 4)

local events = {
	[7] = { id = 7, usesCodec = true, minimumEncodedBytes = 3, maximumEncodedBytes = 16 },
	[8] = { id = 8, usesCodec = true, minimumEncodedBytes = 3, maximumEncodedBytes = 16 },
}
local function resolve(id)
	return events[id]
end
local function body(id)
	local result = buffer.create(3)
	buffer.writeu8(result, 0, 1)
	buffer.writeu16(result, 1, id)
	return result
end
local function bytes(value)
	return buffer.readstring(value, 0, buffer.len(value))
end
local function appended(value, byte)
	local result = buffer.create(buffer.len(value) + 1)
	buffer.copy(result, 0, value, 0, buffer.len(value))
	buffer.writeu8(result, buffer.len(value), byte)
	return result
end

local body7, body8 = body(7), body(8)
operations.creates, operations.copies = 0, 0
local packet = assert(BatchFrame.wrap(1, { body7, body8 }, 8_192))
assert(bytes(packet) == string.char(2, 1, 2, 3, 0, 1, 7, 0, 3, 0, 1, 8, 0),
	"Batch must match its exact format-2/two-record golden")
assert(operations.creates == 1 and operations.copies == 2,
	"wrap owns one envelope and copies each validated body once")
buffer.writeu16(body7, 1, 8)
assert(buffer.readu16(packet, 6) == 7, "wrap must own each body snapshot")

local packetHeader = assert(BatchFrame.header(packet, 8_192))
assert(packetHeader.kind == 1 and packetHeader.count == 2 and table.isfrozen(packetHeader))
local headerKeys = 0
for key in packetHeader do
	headerKeys += 1
	assert(key == "kind" or key == "count", "cheap batch header contains only kind and count")
end
assert(headerKeys == 2)
operations.creates, operations.copies = 0, 0
local rows = assert(BatchFrame.scan(packet, packetHeader, resolve))
assert(#rows == 2 and rows[1].event == events[7] and rows[1].offset == 5 and rows[1].length == 3
	and rows[2].event == events[8] and rows[2].offset == 10 and rows[2].length == 3)
assert(table.isfrozen(rows) and table.isfrozen(rows[1])
	and operations.creates == 0 and operations.copies == 0,
	"complete metadata scan resolves without copying or allocating bodies")
local ownedBody = assert(BatchFrame.readBody(packet, rows[1]))
assert(bytes(ownedBody) == string.char(1, 7, 0)
	and operations.creates == 1 and operations.copies == 1,
	"readBody makes one bounded owned copy after full metadata validation")
buffer.writeu8(packet, 5, 2)
assert(buffer.readu8(ownedBody, 0) == 1, "readBody result must own its bytes")
operations.creates, operations.copies = 0, 0
assert(BatchFrame.readBody(packet, rows[1]) == nil
	and operations.creates == 0 and operations.copies == 0,
	"readBody rechecks bounds and inner identity before copying a changed packet")
buffer.writeu16(packet, 3, 2)
assert(BatchFrame.readBody(packet, rows[1]) == nil
	and operations.creates == 0 and operations.copies == 0,
	"readBody rechecks the record length prefix before copying")

local malformedIdPacket = assert(BatchFrame.wrap(1, { body(7), body(99) }, 8_192))
operations.creates, operations.copies = 0, 0
assert(BatchFrame.scan(malformedIdPacket, BatchFrame.header(malformedIdPacket, 8_192), resolve) == nil
	and operations.creates == 0 and operations.copies == 0,
	"unknown final record rejects the whole metadata scan before body copies")

local malformedVersionPacket = assert(BatchFrame.wrap(1, { body(7), body(8) }, 8_192))
buffer.writeu8(malformedVersionPacket, 10, 2)
operations.creates, operations.copies = 0, 0
assert(BatchFrame.scan(malformedVersionPacket,
	BatchFrame.header(malformedVersionPacket, 8_192), resolve) == nil
	and operations.creates == 0 and operations.copies == 0,
	"invalid final body format rejects before any body copy")

local textEvent = {
	id = 41,
	usesCodec = true,
	minimumEncodedBytes = 5,
	maximumEncodedBytes = 7,
	delivery = "Reliable",
	fields = { { name = "value", type = "string", maximumBytes = 2 } },
}
local badStringBody = buffer.create(7)
buffer.writeu8(badStringBody, 0, 1)
buffer.writeu16(badStringBody, 1, 41)
buffer.writeu16(badStringBody, 3, 3)
buffer.writeu8(badStringBody, 5, string.byte("a"))
buffer.writeu8(badStringBody, 6, string.byte("b"))
events[41] = textEvent
local codecBoundaryPacket = assert(BatchFrame.wrap(2, { body(7), badStringBody }, 8_192))
local codecBoundaryRows = assert(BatchFrame.scan(codecBoundaryPacket,
	BatchFrame.header(codecBoundaryPacket, 8_192), resolve))
local copiedBadString = assert(BatchFrame.readBody(codecBoundaryPacket, codecBoundaryRows[2]))
local decodeText = Frame.compile(textEvent, "decode")
assert(decodeText(copiedBadString) == nil,
	"well-framed final body reaches the existing codec, which rejects its oversized string")

local function packetWithHeader(kind, count, length)
	local result = buffer.create(length)
	if length >= 1 then buffer.writeu8(result, 0, 2) end
	if length >= 2 then buffer.writeu8(result, 1, kind) end
	if length >= 3 then buffer.writeu8(result, 2, count) end
	return result
end
local function rejectsHeader(value, limit, message)
	assert(BatchFrame.header(value, limit) == nil, message)
end
rejectsHeader(buffer.create(7), 8_192, "short envelope rejects before count parsing")
rejectsHeader(packetWithHeader(1, 1, 8), 7, "invalid/too-small frame limit rejects")
rejectsHeader(packetWithHeader(1, 1, 8), 8_193, "frame limit cannot exceed Reliable cap")
rejectsHeader(packetWithHeader(16, 1, 8), 8_192, "readiness kind does not enter batch count parsing")
rejectsHeader(packetWithHeader(3, 1, 8), 8_192, "unknown format-2 kind rejects")
rejectsHeader(packetWithHeader(1, 0, 8), 8_192, "zero logical records reject")
rejectsHeader(packetWithHeader(1, 33, 8), 8_192, "more than 32 logical records reject")
local wrongVersion = packetWithHeader(1, 1, 8)
buffer.writeu8(wrongVersion, 0, 1)
rejectsHeader(wrongVersion, 8_192, "another envelope version rejects")
rejectsHeader(packetWithHeader(1, 1, 901), 900, "channel limit applies before record scan")
rejectsHeader(packetWithHeader(1, 1, 8_193), 8_192, "oversized envelope rejects before reads")

local trailingPacket = appended(assert(BatchFrame.wrap(1, { body(7) }, 8_192)), 0)
assert(BatchFrame.header(trailingPacket, 8_192) ~= nil
	and BatchFrame.scan(trailingPacket, BatchFrame.header(trailingPacket, 8_192), resolve) == nil,
	"scan rejects trailing bytes after the declared records")
local wrongBodyVersion = assert(BatchFrame.wrap(1, { body(7) }, 8_192))
buffer.writeu8(wrongBodyVersion, 5, 2)
assert(BatchFrame.scan(wrongBodyVersion, BatchFrame.header(wrongBodyVersion, 8_192), resolve) == nil,
	"scan rejects a wrong inner codec version")
local wrongInnerId = assert(BatchFrame.wrap(1, { body(7) }, 8_192))
buffer.writeu16(wrongInnerId, 6, 0)
assert(BatchFrame.scan(wrongInnerId, BatchFrame.header(wrongInnerId, 8_192), resolve) == nil,
	"zero inner endpoint rejects before resolver")
local missingPrefix = packetWithHeader(1, 1, 8)
assert(BatchFrame.scan(missingPrefix, BatchFrame.header(missingPrefix, 8_192), resolve) == nil,
	"truncated/zero body length rejects")
local shortRecord = packetWithHeader(1, 1, 8)
buffer.writeu16(shortRecord, 3, 2)
assert(BatchFrame.scan(shortRecord, BatchFrame.header(shortRecord, 8_192), resolve) == nil,
	"body shorter than the format-1 codec header rejects")
local overlongRecord = packetWithHeader(1, 1, 8)
buffer.writeu16(overlongRecord, 3, 4)
assert(BatchFrame.scan(overlongRecord, BatchFrame.header(overlongRecord, 8_192), resolve) == nil,
	"record length beyond remaining envelope rejects")
local inconsistentCount = assert(BatchFrame.wrap(1, { body(7) }, 8_192))
buffer.writeu8(inconsistentCount, 2, 2)
assert(BatchFrame.scan(inconsistentCount, BatchFrame.header(inconsistentCount, 8_192), resolve) == nil,
	"declared record count must consume the envelope exactly")

assert(BatchFrame.wrap(3, { body(7) }, 8_192) == nil
	and BatchFrame.wrap(1, {}, 8_192) == nil
	and BatchFrame.wrap(1, { body(7), [3] = body(8) }, 8_192) == nil,
	"wrap rejects unknown kind, empty arrays, and sparse arrays")
local keyedBodies = { body(7), extra = body(8) }
assert(BatchFrame.wrap(1, keyedBodies, 8_192) == nil
	and BatchFrame.wrap(1, setmetatable({ body(7) }, {}), 8_192) == nil,
	"wrap requires a plain dense array")
local wrongCodecBody = body(7)
buffer.writeu8(wrongCodecBody, 0, 2)
local zeroIdBody = body(7)
buffer.writeu16(zeroIdBody, 1, 0)
operations.creates = 0
assert(BatchFrame.wrap(1, { wrongCodecBody }, 8_192) == nil
	and BatchFrame.wrap(1, { zeroIdBody }, 8_192) == nil and operations.creates == 0,
	"invalid body headers reject before envelope allocation")
local thirtyTwoBodies = table.create(32)
for index = 1, 32 do thirtyTwoBodies[index] = body(7) end
local maximumCountPacket = assert(BatchFrame.wrap(1, thirtyTwoBodies, 8_192))
local maximumCountHeader = BatchFrame.header(maximumCountPacket, 8_192)
assert(maximumCountHeader and maximumCountHeader.count == 32
	and #BatchFrame.scan(maximumCountPacket, maximumCountHeader, resolve) == 32,
	"the exact 32-record logical bound is accepted")

local reliableMaximum = body(7)
local largeReliable = buffer.create(8_187)
buffer.copy(largeReliable, 0, reliableMaximum, 0, 3)
local reliableTail = string.rep("x", 8_184)
buffer.writestring(largeReliable, 3, reliableTail)
local maximumReliablePacket = assert(BatchFrame.wrap(1, { largeReliable }, 8_192))
assert(buffer.len(maximumReliablePacket) == 8_192
	and BatchFrame.header(maximumReliablePacket, 8_192) ~= nil,
	"exact Reliable envelope cap is accepted")
events[7].maximumEncodedBytes = 8_187
assert(BatchFrame.scan(maximumReliablePacket,
	BatchFrame.header(maximumReliablePacket, 8_192), resolve) ~= nil,
	"maximum Reliable record remains within its compiled event bound")
local unreliableMaximum = buffer.create(895)
buffer.copy(unreliableMaximum, 0, body(8), 0, 3)
buffer.writestring(unreliableMaximum, 3, string.rep("u", 892))
local maximumUnreliablePacket = assert(BatchFrame.wrap(2, { unreliableMaximum }, 900))
assert(buffer.len(maximumUnreliablePacket) == 900
	and BatchFrame.header(maximumUnreliablePacket, 900) ~= nil,
	"exact Unreliable envelope cap is accepted")
local overLimitBody = buffer.create(896)
buffer.copy(overLimitBody, 0, body(8), 0, 3)
buffer.writestring(overLimitBody, 3, string.rep("u", 893))
operations.creates = 0
assert(BatchFrame.wrap(2, { overLimitBody }, 900) == nil and operations.creates == 0,
	"over-limit Unreliable record rejects before envelope allocation")

print("PASS Relay.BatchFrame bounded format-2 framing and body ownership")
