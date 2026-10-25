local fs = require("@lune/fs")
local luau = require("@lune/luau")

local operations = { creates = 0, copies = 0, copiedBytes = 0 }
local countedBuffer = table.clone(buffer)
countedBuffer.create = function(length)
	operations.creates += 1
	return buffer.create(length)
end
countedBuffer.copy = function(target, targetOffset, source, sourceOffset, count)
	operations.copies += 1
	operations.copiedBytes += count
	return buffer.copy(target, targetOffset, source, sourceOffset, count)
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
	assert(key == "format" or key == "kind" or key == "count" or key == "referenceCount" or key == "limit",
		"batch header contains only bounded frame metadata")
end
assert(headerKeys == 5)
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

local Definition = require("../src/Definition")
local ordered = require("../examples/reliable-events/ordered")
local fixtureToken = assert(Definition.define({ name = "BatchSliceBaseline", version = 1, events = {
	Text = { id = 41, direction = "ClientToServer", queue = "Batch", fields = ordered(
		{ name = "value", type = "string", maximumBytes = 2 }
	) },
	EmptyItems = { id = 42, direction = "ClientToServer", queue = "Batch", fields = ordered(
		{ name = "items", type = "array", maximumLength = 64,
			element = { type = "struct", fields = ordered() } },
		{ name = "tail", type = "optional", value = { type = "boolean" } }
	) },
} }))
local compiledFixture = Definition.get(fixtureToken)
local textEvent = compiledFixture.queuedById[41]
local emptyEvent = compiledFixture.queuedById[42]
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

-- Untimed copied-body baseline for a future bounded-slice decoder. These are explicit
-- buffer operations, not native allocation or CPU measurements.
local encodedText = table.pack(Frame.compile(textEvent, "encode")("ab"))
assert(encodedText.n == 2 and encodedText[1] == true and buffer.len(encodedText[2]) == 7)
local validTextBody = encodedText[2]
for _, count in { 1, 2, 8, 32 } do
	local bodies = table.create(count)
	for index = 1, count do bodies[index] = validTextBody end
	local textPacket = assert(BatchFrame.wrap(1, bodies, 8_192))
	operations.creates, operations.copies, operations.copiedBytes = 0, 0, 0
	local textHeader = assert(BatchFrame.header(textPacket, 8_192))
	local textRows = assert(BatchFrame.scan(textPacket, textHeader, resolve))
	assert(#textRows == count and operations.creates == 0 and operations.copies == 0,
		"queued metadata scan leaves bodies untouched")
	local firstCopy
	for index, row in textRows do
		local copiedBody = assert(BatchFrame.readBody(textPacket, row))
		if index == 1 then firstCopy = copiedBody end
		local decoded = table.pack(decodeText(copiedBody))
		assert(decoded.n == 2 and decoded[1] == true and decoded[2] == "ab")
	end
	assert(operations.creates == count and operations.copies == count
		and operations.copiedBytes == 7 * count,
		"queued receive copies one exact seven-byte body per record")
	buffer.writeu8(textPacket, textRows[1].offset + 5, string.byte("z"))
	assert(table.pack(decodeText(firstCopy))[2] == "ab",
		"copied queued body remains owned after packet mutation")
end

local truncatedStringBody = buffer.create(6)
buffer.writeu8(truncatedStringBody, 0, 1)
buffer.writeu16(truncatedStringBody, 1, 41)
buffer.writeu16(truncatedStringBody, 3, 2)
buffer.writeu8(truncatedStringBody, 5, string.byte("a"))
for _, corruptIndex in { 1, 2, 4 } do
	local bodies = { validTextBody, validTextBody, validTextBody, validTextBody }
	bodies[corruptIndex] = truncatedStringBody
	local adjacentPacket = assert(BatchFrame.wrap(1, bodies, 8_192))
	local adjacentRows = assert(BatchFrame.scan(adjacentPacket,
		BatchFrame.header(adjacentPacket, 8_192), resolve))
	for index, row in adjacentRows do
		local copiedBody = assert(BatchFrame.readBody(adjacentPacket, row))
		local decoded = table.pack(decodeText(copiedBody))
		if index == corruptIndex then
			assert(decoded.n == 1 and decoded[1] == nil,
				"a truncated string cannot consume the adjacent record's bytes")
		else
			assert(decoded.n == 2 and decoded[1] == true and decoded[2] == "ab")
		end
	end
end

events[42] = emptyEvent
local items = table.create(64)
for index = 1, 64 do items[index] = {} end
local encodedEmpty = table.pack(Frame.compile(emptyEvent, "encode")(items, nil))
assert(encodedEmpty.n == 2 and encodedEmpty[1] == true)
local emptyPacket = assert(BatchFrame.wrap(1, { validTextBody, encodedEmpty[2], validTextBody }, 8_192))
local emptyRows = assert(BatchFrame.scan(emptyPacket, BatchFrame.header(emptyPacket, 8_192), resolve))
local decodedEmpty = table.pack(Frame.compile(emptyEvent, "decode")(
	assert(BatchFrame.readBody(emptyPacket, emptyRows[2]))))
assert(decodedEmpty.n == 3 and decodedEmpty[1] == true and #decodedEmpty[2] == 64
	and decodedEmpty[3] == nil,
	"zero-byte struct elements and trailing nil retain their bounded queued decode")
for index = 1, 64 do assert(next(decodedEmpty[2][index]) == nil) end

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

local roblox = require("@lune/roblox")
local referenceEvent = { id = 50, usesCodec = true, hasReferences = true,
	maximumReferences = 16, minimumEncodedBytes = 4, maximumEncodedBytes = 32 }
local reference = roblox.Instance.new("Part")
local referenceBody = buffer.create(5)
buffer.writeu8(referenceBody, 0, 4)
buffer.writeu16(referenceBody, 1, referenceEvent.id)
buffer.writeu8(referenceBody, 3, 1)
buffer.writeu8(referenceBody, 4, 1)
local referenceArguments = table.pack(reference)
local referencePacket, outgoingReferences = assert(BatchFrame.wrap(1,
	{ { body = referenceBody, references = referenceArguments } }, 8_192))
assert(buffer.readu8(referencePacket, 0) == 5 and buffer.readu8(referencePacket, 3) == 1
	and buffer.len(referencePacket) + 8 == 19 and outgoingReferences.n == 1
	and outgoingReferences[1] == reference,
	"format-5 keeps the local format-4 body and charges one native sidecar")
operations.creates = 0
assert(BatchFrame.wrap(1, { { body = referenceBody } }, 8_192) == nil
	and BatchFrame.wrap(1, { { body = referenceBody, references = table.pack(false) } }, 8_192) == nil
	and operations.creates == 0,
	"outgoing reference rows reject missing or non-Instance sidecars before envelope allocation")
assert(BatchFrame.header(referencePacket, 8_192) == nil,
	"format-5 rejects missing exact-arity sidecars before scanning")
local referenceHeader = assert(BatchFrame.header(referencePacket, 8_192, referenceArguments))
local referenceRows = assert(BatchFrame.scan(referencePacket, referenceHeader,
	function(id) return if id == referenceEvent.id then referenceEvent else nil end, referenceArguments))
assert(#referenceRows == 1 and referenceRows[1].referenceStart == 1
	and referenceRows[1].referenceCount == 1)
local copiedReferenceBody, copiedReferences = BatchFrame.readBody(referencePacket, referenceRows[1], referenceArguments)
assert(bytes(copiedReferenceBody) == bytes(referenceBody) and copiedReferences.n == 1
	and copiedReferences[1] == reference,
	"format-5 body read returns only this row's owned body and exact reference slice")
assert(BatchFrame.header(referencePacket, 8_192, table.pack()) == nil,
	"format-5 rejects an incorrect sidecar count")
local nonInstance = table.pack({})
assert(BatchFrame.header(referencePacket, 8_192, nonInstance) == nil,
	"format-5 rejects non-Instance sidecars before body traversal")

local lateMalformed = assert(BatchFrame.wrap(1, {
	{ body = referenceBody, references = referenceArguments },
	{ body = referenceBody, references = referenceArguments },
}, 8_192))
local latePacketHeader = assert(BatchFrame.header(lateMalformed, 8_192, table.pack(reference, reference)))
buffer.writeu8(lateMalformed, 4 + 2 + buffer.len(referenceBody) + 2 + 3, 2)
operations.creates, operations.copies = 0, 0
assert(BatchFrame.scan(lateMalformed, latePacketHeader, function() return referenceEvent end,
	table.pack(reference, reference)) == nil and operations.creates == 0 and operations.copies == 0,
	"late local-count mismatch rejects the whole frame before body copies")
local sixteenReferences = { n = 16 }
for index = 1, 16 do sixteenReferences[index] = reference end
local sixteenReferenceBody = buffer.create(4)
buffer.writeu8(sixteenReferenceBody, 0, 4)
buffer.writeu16(sixteenReferenceBody, 1, referenceEvent.id)
buffer.writeu8(sixteenReferenceBody, 3, 16)
local overReferenceCap = assert(BatchFrame.wrap(1,
	{ { body = sixteenReferenceBody, references = sixteenReferences } }, 8_192))
buffer.writeu8(overReferenceCap, 3, 17)
assert(BatchFrame.header(overReferenceCap, 8_192, sixteenReferences) == nil,
	"format-5 rejects aggregate sidecar counts above 16 before scanning")

local unreliableReferenceBody = buffer.create(878)
buffer.writeu8(unreliableReferenceBody, 0, 4)
buffer.writeu16(unreliableReferenceBody, 1, referenceEvent.id)
buffer.writeu8(unreliableReferenceBody, 3, 2)
local twoReferences = table.pack(reference, reference)
local exactUnreliableReferencePacket = assert(BatchFrame.wrap(1,
	{ { body = unreliableReferenceBody, references = twoReferences } }, 900))
assert(buffer.len(exactUnreliableReferencePacket) + 16 == 900,
	"queued Unreliable format-5 accepts the exact complete 900-unit ceiling")
local overUnreliableReferenceBody = buffer.create(879)
buffer.writeu8(overUnreliableReferenceBody, 0, 4)
buffer.writeu16(overUnreliableReferenceBody, 1, referenceEvent.id)
buffer.writeu8(overUnreliableReferenceBody, 3, 2)
operations.creates = 0
assert(BatchFrame.wrap(1, { { body = overUnreliableReferenceBody, references = twoReferences } }, 900) == nil
	and operations.creates == 0,
	"queued Unreliable format-5 rejects payload plus sidecars over 900 before allocation")

print("PASS Relay.BatchFrame bounded format-2 framing and body ownership")
