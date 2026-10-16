local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../src/Definition")
local BatchFrame = require("../src/internal/BatchFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local ReadinessFrame = require("../src/internal/ReadinessFrame")
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
	environment = {
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		require = function(path)
			assert(path == "./CompositeCodec")
			return CompositeCodec
		end,
	},
	injectGlobals = true,
})()

-- Legacy descriptor and frame fixtures recorded from published v0.2.0
-- (60d4eb80e4307b7170a352efea0e910573c7b2fa).
local GOLDEN = {
	RR1 = "RR1|D14:CompatReliable|V1|N1|E1,C,8:Reliable,1|F5:value,u16,0,65535",
	-- Retained only as the legacy descriptor that current RR7 must reject at startup.
	RR2 = "RR2|D16:CompatUnreliable|V1|N1|E2,C,U,5:Pulse,1|F5:value,b,-,-",
	RR3 = "RR3|D15:CompatComposite|V1|N1|E3,S,R,8:Snapshot,1F4:pose=T2[F1:x=P3:i16[-32768,32767]F5:label=P3:str[-,8]]",
	RR5 = "RR5|D9:Inventory|V1|N1|E7,C,R,4:Ping,1F5:value=P3:u16[0,10]|Q1|R9,7:Inspect,1[F6:itemId=P3:u16[0,10]]=T2[F5:owned=P1:b[-,-]F5:count=P3:u16[0,10]]",
	RR6 = "RR6|D11:CompatQueue|V1|R1|N2|E1,S,R,S,5:State,1F5:value=P3:u16[0,65535]|E2,S,R,B,5:Batch,1F4:flag=P1:b[-,-]|Q0",
	-- Current RR7 fixture; this representation was not in the published package.
	RR7Primitive = "RR7|D16:CompatUnreliable|V1|N1|E2,C,U,5:Pulse,1|F5:value,b,-,-",
}

local function define(spec, protocol)
	local token, problem = Definition.define(spec)
	assert(token, problem and problem.message)
	local compiled = Definition.get(token)
	assert(string.sub(compiled.descriptor, 1, 3) == protocol)
	assert(compiled.descriptor == GOLDEN[protocol], protocol .. " descriptor changed: " .. compiled.descriptor)
	return token, compiled
end

local reliableToken, reliable = define({
	name = "CompatReliable",
	version = 1,
	events = {
		Reliable = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u16" } } },
	},
}, "RR1")
local unreliableToken, unreliableProblem = Definition.define({
	name = "CompatUnreliable",
	version = 1,
	events = {
		Pulse = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
			fields = { { name = "value", type = "boolean" } } },
	},
})
assert(unreliableToken and unreliableProblem == nil)
local unreliable = Definition.get(unreliableToken)
assert(unreliable.descriptor == GOLDEN.RR7Primitive,
	"primitive unreliable events must select the literal RR7 descriptor: " .. unreliable.descriptor)
local _, composite = define({
	name = "CompatComposite",
	version = 1,
	events = {
		Snapshot = { id = 3, direction = "ServerToClient", fields = { { name = "pose", type = "struct", fields = {
			{ name = "x", type = "i16" },
			{ name = "label", type = "string", maximumBytes = 8 },
		} } } },
	},
}, "RR3")
local _, rpc = define({
	name = "Inventory",
	version = 1,
	events = {
		Ping = { id = 7, direction = "ClientToServer", fields = { { name = "value", type = "u16", maximum = 10 } } },
	},
	requests = {
		Inspect = { id = 9, request = { { name = "itemId", type = "u16", maximum = 10 } }, response = { type = "struct", fields = {
			{ name = "owned", type = "boolean" },
			{ name = "count", type = "u16", maximum = 10 },
		} } },
	},
}, "RR5")
local _, queued = define({
	name = "CompatQueue",
	version = 1,
	readiness = true,
	events = {
		State = { id = 1, direction = "ServerToClient", queue = "State", fields = { { name = "value", type = "u16" } } },
		Batch = { id = 2, direction = "ServerToClient", queue = "Batch", fields = { { name = "flag", type = "boolean" } } },
	},
}, "RR6")

assert(not reliable.byId[1].usesCodec and reliable.byId[1].delivery == "Reliable"
	and unreliable.byId[2].usesCodec and unreliable.byId[2].delivery == "Unreliable",
	"RR1 reliable primitives retain native tuples while RR7 unreliable primitives use buffers")
assert(composite.byId[3].usesCodec and rpc.requests.Inspect.request.usesCodec
	and queued.queuedById[1].queue == "State" and queued.queuedById[2].queue == "Batch",
	"RR3/RR5/RR6 keep their compiled codec and queue selections")
for _, protocol in { "RR1", "RR3" } do
	assert(not string.find(GOLDEN[protocol], "|R0", 1, true)
		and not string.find(GOLDEN[protocol], "|Q0", 1, true),
		protocol .. " must retain the old descriptor when optional feature metadata is absent")
end

-- A fixed RR7 grammar fixture pins the 64-event descriptor, all readiness bits,
-- queue metadata, and sorting through the maximum endpoint ID.
local maximumEvents = { name = "Compat64", version = 1, readiness = true, events = {} }
maximumEvents.events.Top = { id = 65_535, direction = "ServerToClient", fields = {} }
maximumEvents.events.State = { id = 63, direction = "ServerToClient", queue = "State", fields = {} }
for id = 62, 3, -1 do
	local name = "Event" .. id
	maximumEvents.events[name] = { id = id, direction = "ServerToClient", fields = {} }
end
maximumEvents.events.Empty = { id = 2, direction = "ServerToClient", delivery = "Unreliable", fields = {} }
maximumEvents.events.Pulse = { id = 1, direction = "ServerToClient", delivery = "Unreliable",
	fields = { { name = "value", type = "boolean" } } }
local maximumToken, maximumProblem = Definition.define(maximumEvents)
assert(maximumToken and maximumProblem == nil)
local maximum = Definition.get(maximumToken)
local expected64 = { "RR7|D8:Compat64|V1|R1|N64",
	"|E1,S,U,N,5:Pulse,1F5:value=P1:b[-,-]", "|E2,S,U,N,5:Empty,0" }
for id = 3, 62 do
	local name = "Event" .. id
	table.insert(expected64, `|E{id},S,R,N,{#name}:{name},0`)
end
table.insert(expected64, "|E63,S,R,S,5:State,0")
table.insert(expected64, "|E65535,S,R,N,3:Top,0|Q0")
assert(maximum.descriptor == table.concat(expected64), "64-endpoint RR7 descriptor or highest ID changed")
assert(maximum.readiness.count == 64 and maximum.readiness.bytes == 8
	and maximum.readiness.byId[1] == 0 and maximum.readiness.byId[65_535] == 63
	and maximum.byId[65_535].name == "Top" and maximum.queuedById[63].queue == "State",
	"64-event readiness and highest endpoint metadata changed")

local mixedToken, mixedProblem = Definition.define({
	name = "CompatFeatures",
	version = 1,
	readiness = true,
	events = {
		Pulse = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
			fields = { { name = "value", type = "boolean" } } },
		Queue = { id = 7, direction = "ServerToClient", queue = "Batch", fields = {} },
	},
	requests = { Lookup = { id = 9, request = {}, response = { type = "boolean" } } },
})
assert(mixedToken and mixedProblem == nil)
local mixedFeatures = Definition.get(mixedToken)
assert(mixedFeatures and mixedFeatures.descriptor
	== "RR7|D14:CompatFeatures|V1|R1|N2|E2,C,U,N,5:Pulse,1F5:value=P1:b[-,-]|E7,S,R,B,5:Queue,0|Q1|R9,6:Lookup,0[]=P1:b[-,-]",
	"RR7 must retain explicit readiness, queue, and request grammar: " .. mixedFeatures.descriptor)

-- Primitive-only unreliable frames now use the checked buffer codec in RR7.
local function hex(value)
	local result = table.create(buffer.len(value))
	for index = 0, buffer.len(value) - 1 do
		result[index + 1] = string.format("%02x", buffer.readu8(value, index))
	end
	return table.concat(result)
end
local pulseOk, pulseFrame = Frame.compile(maximum.byId[1], "encode")(false)
local emptyOk, emptyFrame = Frame.compile(maximum.byId[2], "encode")()
assert(pulseOk and hex(pulseFrame) == "01010000", "RR7 false primitive frame bytes changed")
assert(emptyOk and hex(emptyFrame) == "010200", "RR7 zero-field primitive frame bytes changed")

-- A full-width Ack uses a literal 90-byte format-2 frame with every listener bit set.
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
local fullWidthMask = string.char(255, 255, 255, 255, 255, 255, 255, 255)
local fullWidthAckGolden = string.char(2, 18) .. serverGuid .. string.char(1, 2, 3, 4)
	.. clientGuid .. string.char(5, 6, 7, 8) .. fullWidthMask
local fullWidthAck = assert(ReadinessFrame.ack(serverGuid, 0x04030201, clientGuid,
	0x08070605, fullWidthMask, maximum.readiness.count))
assert(buffer.len(fullWidthAck) == 90 and bytes(fullWidthAck) == fullWidthAckGolden,
	"64-listener Ack must match its literal 90-byte golden")
local fullWidthHeader = assert(ReadinessFrame.peek(fullWidthAck, true, 64))
assert(fullWidthHeader.maskString == fullWidthMask and fullWidthHeader.listenerCount == 64,
	"64-listener Ack must preserve all 64 mask bits")
assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, string.rep("\255", 7), 64) == nil
	and ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, string.rep("\255", 9), 64) == nil,
	"full-width Ack builder must reject either mask width mismatch")
assert(ReadinessFrame.peek(copyWithLength(fullWidthAck, 89), true, 64) == nil
	and ReadinessFrame.peek(copyWithLength(fullWidthAck, 91), true, 64) == nil,
	"full-width Ack parser must reject truncation and trailing bytes")
local unusedSixtyFourthBit = copyWithLength(fullWidthAck, 90)
assert(ReadinessFrame.peek(unusedSixtyFourthBit, true, 63) == nil,
	"a bit outside the 63-listener mask must reject")
assert(ReadinessFrame.ack(serverGuid, 1, clientGuid, 1, fullWidthMask, 63) == nil,
	"full-width builder must reject an unused final mask bit")

-- This RR1 fixture pins the native Roblox tuple handoff for reliable primitives.
local ClientRuntime = require("./support/ClientRuntime")
local reliableRuntime = ClientRuntime.create()
local _, _, reliableRemote = reliableRuntime:transport(GOLDEN.RR1, false)
local reliableClient = assert(reliableRuntime.module.create(reliableToken, { startupTimeoutSeconds = 1 }))
assert(reliableClient:Start() and reliableClient.events.Reliable:Send(513))
local reliableFire = reliableRuntime.fires[1]
assert(reliableFire.remote == reliableRemote and reliableFire.n == 2
	and reliableFire[1] == 1 and reliableFire[2] == 513,
	"RR1 reliable primitive retains its native endpoint/payload tuple")
reliableClient:Destroy()

-- The published RR2 descriptor is a deliberate mismatch for the RR7 token.
local legacyRuntime = ClientRuntime.create()
legacyRuntime:transport(GOLDEN.RR2, true)
local legacyClient = assert(legacyRuntime.module.create(unreliableToken, { startupTimeoutSeconds = 1 }))
local legacyStarted, legacyError = legacyClient:Start()
assert(not legacyStarted and legacyError and legacyError.code == "DefinitionMismatch"
	and legacyRuntime.connections == 0 and #legacyRuntime.fires == 0,
	"the legacy RR2 descriptor must fail before any application handoff")
legacyClient:Destroy()

local rr7Runtime = ClientRuntime.create()
local _, _, _, unreliableRemote = rr7Runtime:transport(GOLDEN.RR7Primitive, true)
local rr7Client = assert(rr7Runtime.module.create(unreliableToken, { startupTimeoutSeconds = 1 }))
assert(rr7Client:Start() and rr7Client.events.Pulse:Send(false))
local rr7Fire = rr7Runtime.fires[1]
assert(rr7Fire.remote == unreliableRemote and rr7Fire.n == 2 and rr7Fire[1] == 2
	and typeof(rr7Fire[2]) == "buffer" and hex(rr7Fire[2]) == "01020000",
	"a fresh RR7 match must hand off the golden false frame")
rr7Client:Destroy()

local function encode(event, ...)
	local ok, body = Frame.compile(event, "encode")(...)
	assert(ok and typeof(body) == "buffer")
	return body
end

local rr3Body = encode(composite.byId[3], { x = -2, label = "cat" })
assert(hex(rr3Body) == "010300feff0300636174", "RR3 composite body bytes changed")

local rpcBody = encode(rpc.requests.Inspect.request, 5)
assert(hex(rpcBody) == "0109000500", "RR5 request body bytes changed")
local rpcFrame = assert(RpcFrame.wrap(1, 9, 7, "01234567-89ab-cdef-0123-456789abcdef", rpcBody))
assert(hex(rpcFrame) == "010109000700000030313233343536372d383961622d636465662d303132332d3435363738396162636465660109000500",
	"RR5 request envelope bytes changed")

local batchBody = encode(queued.queuedById[2], true)
assert(hex(batchBody) == "01020001", "RR6 batch record body bytes changed")
local batchFrame = assert(BatchFrame.wrap(1, { batchBody }, 8_192))
assert(hex(batchFrame) == "020101040001020001", "RR6 batch frame bytes changed")

local stateBody = encode(queued.queuedById[1], 513)
assert(hex(stateBody) == "0101000102", "RR6 State record body bytes changed")
local stateFrame = assert(BatchFrame.wrap(2, { stateBody }, 8_192))
assert(hex(stateFrame) == "02020105000101000102", "RR6 State frame bytes changed")
assert(hex(ReadinessFrame.hello()) == "0210", "RR6 readiness Hello bytes changed")

local changedToken, changedProblem = Definition.define({
	name = "CompatReliable",
	version = 1,
	events = {
		Reliable = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u16", maximum = 10 } } },
	},
})
assert(changedToken and changedProblem == nil)
local changedDescriptor = Definition.get(changedToken).descriptor
assert(changedDescriptor ~= GOLDEN.RR1, "a changed field bound must change the compatibility descriptor")

local runtime = ClientRuntime.create()
runtime:transport(GOLDEN.RR1, false)
local client = assert(runtime.module.create(changedToken, { startupTimeoutSeconds = 1 }))
local started, mismatch = client:Start()
assert(not started and mismatch and mismatch.code == "DefinitionMismatch" and runtime.connections == 0,
	"changed schema descriptor rejects startup against the published RR1 descriptor")

print("PASS Relay compatibility descriptors and frames (RR1/RR2 legacy mismatch/RR3/RR5/RR6/RR7)")
