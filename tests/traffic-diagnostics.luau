local Definition = require("../src/Definition")
local Diagnostics = require("../src/internal/Diagnostics")
local ByteUnits = require("../src/internal/ByteUnits")
local BatchFrame = require("../src/internal/BatchFrame")
local Frame = require("../src/internal/Frame")
local OrderedFrame = require("../src/internal/OrderedFrame")
local RpcFrame = require("../src/internal/RpcFrame")
local roblox = require("@lune/roblox")
local reference = roblox.Instance.new("Part")

local function encodeQueuedBody(definition, eventId, ...)
	local event = assert(Definition.get(definition).queuedById[eventId])
	local encoded = table.pack(Frame.compile(event, "encode")(...))
	assert(encoded[1] == true)
	return encoded[2]
end

local function unknownQueuedBody(eventId)
	local body = buffer.create(3)
	buffer.writeu8(body, 0, 1)
	buffer.writeu16(body, 1, eventId)
	return body
end

assert(ByteUnits.exactInbound(1, 7) == 11,
    "a native u8 event uses the three-unit tuple prefix and eight modeled numeric units")
assert(ByteUnits.exactInbound(1, "abc") == 8 and ByteUnits.exactInbound(1) == 3)

local emptyBuffer = buffer.create(0)
assert(ByteUnits.exactInbound(1, emptyBuffer) == 0,
    "exact observation must not inherit the admission helper's empty-buffer minimum")
local oversizedBuffer = buffer.create(8_300)
assert(ByteUnits.exactInbound(1, oversizedBuffer) == 8_300,
    "known over-cap buffers keep their full modeled length")
assert(ByteUnits.exactInbound(1, {}) == nil
    and ByteUnits.exactInbound(1, reference) == nil
    and ByteUnits.exactInbound(1, 1, 2, 3, 4, 5, 6, 7, 8, 9) == nil,
    "unmodelled native values and over-arity tuples are reported as unknown")

local batchBody = buffer.create(3)
buffer.writeu8(batchBody, 0, 1)
buffer.writeu16(batchBody, 1, 1)
local batchPacket = assert(BatchFrame.wrap(1, { batchBody }, 8_192))
assert(ByteUnits.exactInbound(0, batchPacket) == buffer.len(batchPacket)
    and buffer.len(batchPacket) == 8,
    "batch channel units include its full envelope, record prefix and body")

local rpcBody = buffer.create(4)
buffer.writeu8(rpcBody, 0, 4)
buffer.writeu16(rpcBody, 1, 3)
buffer.writeu8(rpcBody, 3, 1)
local rpcPacket = assert(RpcFrame.wrap(1, 3, 1, "01234567-89ab-cdef-0123-456789abcdef",
    rpcBody, nil, 2, 1))
assert(ByteUnits.exactInbound(0, rpcPacket, reference) == buffer.len(rpcPacket) + 8
    and ByteUnits.exactInbound(0, rpcPacket, reference) == 56,
    "RPC channel units include the full envelope and Instance-reference sidecar")

local referenceFrame = buffer.create(12)
buffer.writeu8(referenceFrame, 0, 4)
buffer.writeu8(referenceFrame, 3, 1)
assert(ByteUnits.exactInbound(1, referenceFrame, reference) == 20
    and ByteUnits.exactInbound(1, referenceFrame) == nil
    and ByteUnits.exactInbound(1, referenceFrame, {}) == nil,
    "known sidecars add eight units each while malformed sidecars stay unmeasured")
local overReferenceFrame = buffer.create(12)
buffer.writeu8(overReferenceFrame, 0, 4)
buffer.writeu8(overReferenceFrame, 3, 17)
assert(ByteUnits.exactInbound(1, overReferenceFrame, reference) == nil,
    "reference counts above the fixed cap remain unmeasured")

local batchReferencePacket = buffer.create(4)
buffer.writeu8(batchReferencePacket, 0, 5)
buffer.writeu8(batchReferencePacket, 3, 1)
local orderedReferencePacket = buffer.create(12)
buffer.writeu8(orderedReferencePacket, 0, 6)
buffer.writeu8(orderedReferencePacket, 11, 1)
assert(ByteUnits.exactInbound(0, batchReferencePacket, reference) == 12
    and ByteUnits.exactInbound(1, orderedReferencePacket, reference) == 20
    and ByteUnits.exactInbound(1, buffer.create(4)) == 4,
    "batch and ordered sidecars use their bounded reference headers; plain buffers retain exact length")

local token, problem = Definition.define({
    name = "TrafficDiagnosticsTest",
    version = 1,
    events = {
        ReliableInput = { id = 1, direction = "ClientToServer", fields = {} },
        UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
    },
    requests = {
        Lookup = { id = 3, request = {}, response = { type = "boolean" } },
    },
})
assert(token ~= nil, problem and problem.message)
local compiled = Definition.get(token)

local disabled = Diagnostics.create(compiled.events, "Client", nil, { perEndpoint = 1 })
assert(disabled.traffic == nil and disabled.reports == nil)
Diagnostics.addTraffic(disabled, 1, "Reliable", "submittedRecords", 1)
Diagnostics.report(disabled, "InvalidPayload", 1, "Reliable")
local disabledSnapshot = Diagnostics.snapshot(disabled, "Created", 0)
assert(disabledSnapshot.traffic == nil and disabledSnapshot.reports == nil,
    "disabled diagnostics must not allocate optional state or snapshot fields")

local options = { traffic = true, reports = true }
local diagnostics = Diagnostics.create(compiled.events, "Server", nil, {}, nil, compiled.requests, options)
options.traffic = false
options.reports = false

local traffic = diagnostics.traffic
assert(traffic ~= nil and traffic.endpoints[1].id == 1
    and traffic.endpoints[1].kind == "Event"
    and traffic.endpoints[2].id == 2
    and traffic.endpoints[3].id == 3 and traffic.endpoints[3].kind == "Request",
    "traffic rows must include each declared event and request")

Diagnostics.addTraffic(diagnostics, 1, "Reliable", "submittedRecords", 1)
Diagnostics.addTraffic(diagnostics, 1, "Reliable", "submittedBytes", 12)
Diagnostics.addTraffic(diagnostics, 2, "Unreliable", "receivedPackets", 1)
Diagnostics.addTraffic(diagnostics, 2, "Unreliable", "receivedBytes", 900)
Diagnostics.addTraffic(diagnostics, 3, "Reliable", "sentPackets", 1)
Diagnostics.addTraffic(diagnostics, 3, "Reliable", "sentRecipientBytes", 24)
Diagnostics.addTraffic(diagnostics, nil, "Reliable", "unmeasuredPackets", 1)
local unknownBefore = traffic.channels.Reliable.receivedPackets
Diagnostics.addTraffic(diagnostics, 99, "Reliable", "receivedPackets", 1)
assert(traffic.channels.Reliable.receivedPackets == unknownBefore + 1 and traffic.byId[99] == nil,
    "unknown endpoint still counts its channel packet without allocating an endpoint row")
Diagnostics.addTraffic(diagnostics, 1, "Invalid", "receivedPackets", 1)
Diagnostics.addTraffic(diagnostics, 1, "Reliable", "submittedBytes", -1)

local saturated = traffic.endpoints[1].channels.Reliable
saturated.validatedBytes = 4_294_967_290
traffic.channels.Reliable.validatedBytes = 4_294_967_290
Diagnostics.addTraffic(diagnostics, 1, "Reliable", "validatedBytes", 10)

local reportReasons = {
    "PerPlayerRateLimited", "AggregateRateLimited", "EndpointRateLimited", "PerPlayerByteLimited",
    "AggregateByteLimited", "InvalidEndpoint", "WrongChannel", "Ineligible", "NoListener", "Busy",
    "InvalidPayload", "Stale", "TransportFailure", "TransportLoss", "HandlerError", "QueueFull",
    "QueueLimit", "QueueBusy", "OutboundRateLimited", "QueueClosed",
}
for _, reason in reportReasons do
    Diagnostics.report(diagnostics, reason, 1, "Reliable")
end
Diagnostics.report(diagnostics, "QueueClosed", 1, "Reliable")
Diagnostics.report(diagnostics, { attacker = true }, 1, "Reliable")
Diagnostics.report(diagnostics, "InvalidPayload", {}, "Reliable")

local snapshot = Diagnostics.snapshot(diagnostics, "Destroyed", 0)
assert(snapshot.traffic.channels.Reliable.submittedRecords == 1
    and snapshot.traffic.channels.Reliable.submittedBytes == 12
    and snapshot.traffic.channels.Reliable.unmeasuredPackets == 1
    and snapshot.traffic.channels.Unreliable.receivedPackets == 1
    and snapshot.traffic.channels.Unreliable.receivedBytes == 900)
assert(snapshot.traffic.endpoints[1].channels.Reliable.submittedRecords == 1
    and snapshot.traffic.endpoints[3].channels.Reliable.sentPackets == 1
    and snapshot.traffic.endpoints[3].channels.Reliable.sentRecipientBytes == 24
    and snapshot.traffic.endpoints[2].channels.Unreliable.receivedBytes == 900)
assert(snapshot.traffic.channels.Reliable.validatedBytes == 4_294_967_295
    and snapshot.traffic.endpoints[1].channels.Reliable.validatedBytes == 4_294_967_295,
    "traffic counters must saturate at the existing u32 limit")
assert(table.isfrozen(snapshot.traffic) and table.isfrozen(snapshot.traffic.channels)
    and table.isfrozen(snapshot.traffic.channels.Reliable)
    and table.isfrozen(snapshot.traffic.endpoints)
    and table.isfrozen(snapshot.traffic.endpoints[3])
    and table.isfrozen(snapshot.traffic.endpoints[3].channels.Reliable))

local reports = snapshot.reports
assert(reports.capacity == 16 and reports.total == 21 and #reports.entries == 16,
    "report history must retain only its fixed-capacity ring")
assert(reports.entries[1].reason == "AggregateByteLimited"
    and reports.entries[1].sequence == 5
    and reports.entries[16].reason == "QueueClosed"
    and reports.entries[16].sequence == 20
    and reports.entries[16].count == 2,
    "report ring must retain ordered scalar summaries and aggregate repeated reasons")
for _, entry in reports.entries do
    local keys = 0
    for key in entry do
        keys += 1
        assert(key == "reason" or key == "endpointId" or key == "channel" or key == "count" or key == "sequence")
    end
    assert(keys == 5 and table.isfrozen(entry))
end
assert(table.isfrozen(reports) and table.isfrozen(reports.entries))

Diagnostics.addTraffic(diagnostics, 1, "Reliable", "submittedRecords", 1)
Diagnostics.report(diagnostics, "Busy", 1, "Reliable")
assert(snapshot.traffic.channels.Reliable.submittedRecords == 1 and snapshot.reports.total == 21,
    "later updates must not mutate an earlier frozen snapshot")
assert(not pcall(function() snapshot.reports.entries[1].count = 0 end))

local collision = Diagnostics.create({ Ping = { id = 4 } }, "Client", nil, {}, nil,
    { Ping = { id = 5 } }, { traffic = true })
local collisionRows = 0
for _, row in collision.traffic.endpoints do
    if row.id == 4 or row.id == 5 then collisionRows += 1 end
end
assert(collisionRows == 2 and collision.traffic.endpoints[4].name == "Ping"
    and collision.traffic.endpoints[4].kind == "Event"
    and collision.traffic.endpoints[5].name == "Ping" and collision.traffic.endpoints[5].kind == "Request",
    "same-name event and request must retain separate named traffic rows")

local packetDiagnostics = Diagnostics.create(compiled.events, "Server", nil, {}, nil,
	compiled.requests, { traffic = true })
local packet = buffer.create(19)
local packetRows = {
	{ endpointId = 1, units = 5, body = buffer.create(5) },
	{ endpointId = 2, units = 7, body = buffer.create(7) },
	{ endpointId = 1, units = 9, body = buffer.create(9) },
}
Diagnostics.recordSentPacket(packetDiagnostics, "Reliable", packet, nil, packetRows, 3, 1, 2)
local packetSnapshot = Diagnostics.snapshot(packetDiagnostics, "Started", 0).traffic
assert(packetSnapshot.channels.Reliable.sentPackets == 1
	and packetSnapshot.channels.Reliable.sentRecords == 3
	and packetSnapshot.channels.Reliable.sentBytes == 19
	and packetSnapshot.channels.Reliable.sentRecipientBytes == 38,
	"one multi-endpoint packet is charged once at channel scope")
assert(packetSnapshot.endpoints[1].channels.Reliable.sentPackets == 1
	and packetSnapshot.endpoints[1].channels.Reliable.sentRecords == 2
	and packetSnapshot.endpoints[1].channels.Reliable.sentBytes == 14
	and packetSnapshot.endpoints[1].channels.Reliable.sentRecipientBytes == 28
	and packetSnapshot.endpoints[2].channels.Reliable.sentPackets == 1
	and packetSnapshot.endpoints[2].channels.Reliable.sentRecords == 1
	and packetSnapshot.endpoints[2].channels.Reliable.sentBytes == 7
	and packetSnapshot.endpoints[2].channels.Reliable.sentRecipientBytes == 14,
	"each distinct endpoint gets one packet while repeated rows add records and body units")

local ClientRuntime = require("./support/ClientRuntime")
local clientDefinition = assert(Definition.define({ name = "TrafficRouteClient", version = 1, events = {
	ReliableState = { id = 11, direction = "ServerToClient", fields = {} },
	UnreliableState = { id = 12, direction = "ServerToClient", delivery = "Unreliable", fields = {} },
	ClientInput = { id = 13, direction = "ClientToServer", fields = {} },
} }))
local clientRuntime = ClientRuntime.create()
local _, _, reliableRemote, unreliableRemote = clientRuntime:transport(
	Definition.get(clientDefinition).descriptor, true)
local client = assert(clientRuntime.module.create(clientDefinition, {
	startupTimeoutSeconds = 3,
	diagnostics = { traffic = true, reports = true },
}))
assert(client.events.ReliableState:Connect(function() end))
assert(client.events.UnreliableState:Connect(function() end))
assert(client:Start())
reliableRemote.OnClientEvent:fire(12)
unreliableRemote.OnClientEvent:fire(11)
reliableRemote.OnClientEvent:fire(13)
reliableRemote.OnClientEvent:fire(99)
local clientSnapshot = client:GetDiagnostics()
local clientRows = {}
local unknownClientRow
for _, entry in clientSnapshot.reports.entries do
	if entry.endpointId == nil then unknownClientRow = entry else clientRows[entry.endpointId] = entry end
end
assert(clientSnapshot.reports.total == 4
	and clientRows[12].reason == "WrongChannel" and clientRows[12].channel == "Reliable"
	and clientRows[11].reason == "WrongChannel" and clientRows[11].channel == "Unreliable"
	and clientRows[13].reason == "InvalidEndpoint" and clientRows[13].channel == "Reliable"
	and unknownClientRow.reason == "InvalidEndpoint" and unknownClientRow.channel == "Reliable",
	"reports retain known endpoint IDs and omit attribution for unknown numeric IDs")
assert(clientSnapshot.traffic.channels.Reliable.receivedPackets == 3
	and clientSnapshot.traffic.channels.Unreliable.receivedPackets == 1,
	"the wrong-channel observations still count once at channel scope")
assert(clientSnapshot.traffic.endpoints[13].channels.Reliable.receivedPackets == 1
	and clientSnapshot.traffic.endpoints[99] == nil,
	"known invalid endpoints retain their fixed row while unknown IDs allocate none")
client:Destroy()

local ServerRuntime = require("./support/ServerRuntime")

local queuedClientDefinition = assert(Definition.define({ name = "TrafficQueuedClientAttribution", version = 1,
	events = {
		ClientOnly = { id = 14, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		ServerBatch = { id = 15, direction = "ServerToClient", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
	},
}))
local queuedClientRuntime = ClientRuntime.create()
local _, _, queuedClientRemote = queuedClientRuntime:transport(
	Definition.get(queuedClientDefinition).descriptor, false)
local queuedClient = assert(queuedClientRuntime.module.create(queuedClientDefinition, {
	startupTimeoutSeconds = 3,
	diagnostics = { reports = true },
}))
assert(queuedClient:Start())
for _, input in {
	{ kind = 1, body = encodeQueuedBody(queuedClientDefinition, 14, 1) },
	{ kind = 2, body = encodeQueuedBody(queuedClientDefinition, 15, 2) },
	{ kind = 1, body = unknownQueuedBody(99) },
} do
	queuedClientRemote.OnClientEvent:fire(0,
		assert(BatchFrame.wrap(input.kind, { input.body }, 8_192)))
end
local queuedClientReports = queuedClient:GetDiagnostics().reports
local queuedClientById, queuedClientUnknown = {}, nil
for _, entry in queuedClientReports.entries do
	if entry.endpointId == nil then queuedClientUnknown = entry else queuedClientById[entry.endpointId] = entry end
end
assert(queuedClientReports.total == 3
	and queuedClientById[14].reason == "InvalidEndpoint" and queuedClientById[14].channel == "Reliable"
	and queuedClientById[15].reason == "InvalidEndpoint" and queuedClientById[15].channel == "Reliable"
	and queuedClientUnknown.reason == "InvalidEndpoint" and queuedClientUnknown.channel == "Reliable"
	and queuedClient:GetDiagnostics().counters.invalidEndpoint == 3,
	"client queued resolver reports known wrong-direction/non-State IDs and leaves an unknown ID unattributed")
queuedClient:Destroy()

local queuedServerDefinition = assert(Definition.define({ name = "TrafficQueuedServerAttribution", version = 1,
	events = {
		UnreliableInput = { id = 81, direction = "ClientToServer", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		BatchInput = { id = 82, direction = "ClientToServer", queue = "Batch",
			fields = { { name = "value", type = "u8" } } },
		ServerOnly = { id = 83, direction = "ServerToClient", queue = "State",
			fields = { { name = "value", type = "u8" } } },
	},
	requests = {
		ClientRequest = { id = 84, direction = "ClientToServer", request = {}, response = { type = "boolean" } },
	},
}))
local queuedServerRuntime = ServerRuntime.new()
local queuedServerPlayer = queuedServerRuntime:addPlayer()
local queuedServer = assert(queuedServerRuntime.server.create(queuedServerDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4_096, refillPerSecond = 1 },
		aggregate = { capacity = 32_768, refillPerSecond = 1 },
	},
	diagnostics = { reports = true },
}))
assert(queuedServer:Start())
local queuedServerInputs = {
	{ kind = 1, body = encodeQueuedBody(queuedServerDefinition, 81, 1) },
	{ kind = 2, body = encodeQueuedBody(queuedServerDefinition, 82, 2) },
	{ kind = 1, body = encodeQueuedBody(queuedServerDefinition, 83, 3) },
	{ kind = 1, body = unknownQueuedBody(99) },
}
for _, input in queuedServerInputs do
	queuedServerRuntime:remote().OnServerEvent:Fire(queuedServerPlayer, 0,
		assert(BatchFrame.wrap(input.kind, { input.body }, 8_192)))
end
local clientRequest = Definition.get(queuedServerDefinition).requests.ClientRequest
local responseEncoded = table.pack(Frame.compile(clientRequest.response, "encode")(true))
assert(responseEncoded[1] == true)
queuedServerRuntime:remote().OnServerEvent:Fire(queuedServerPlayer, 0,
	assert(RpcFrame.wrap(2, clientRequest.id, 1, "01234567-89ab-cdef-0123-456789abcdef",
		responseEncoded[2], false, 2)))
local unknownRpcBody = buffer.create(3)
buffer.writeu8(unknownRpcBody, 0, 1)
buffer.writeu16(unknownRpcBody, 1, 99)
queuedServerRuntime:remote().OnServerEvent:Fire(queuedServerPlayer, 0,
	assert(RpcFrame.wrap(2, 99, 2, "01234567-89ab-cdef-0123-456789abcdef", unknownRpcBody, false, 2)))
local queuedServerReports = queuedServer:GetDiagnostics().reports
local queuedServerById, queuedServerUnknown = {}, nil
for _, entry in queuedServerReports.entries do
	if entry.endpointId == nil then queuedServerUnknown = entry else queuedServerById[entry.endpointId] = entry end
end
assert(queuedServerReports.total == 6
	and queuedServerById[81].reason == "WrongChannel" and queuedServerById[81].channel == "Reliable"
	and queuedServerById[82].reason == "InvalidEndpoint" and queuedServerById[82].channel == "Reliable"
	and queuedServerById[83].reason == "InvalidEndpoint" and queuedServerById[83].channel == "Reliable"
	and queuedServerById[84].reason == "InvalidEndpoint" and queuedServerById[84].channel == "Reliable"
	and queuedServerUnknown.reason == "InvalidEndpoint" and queuedServerUnknown.channel == "Reliable"
	and queuedServerUnknown.count == 2
	and queuedServer:GetDiagnostics().counters.wrongChannel == 1
	and queuedServer:GetDiagnostics().counters.invalidEndpoint == 5,
	"server queued and RPC reports preserve known routes while unknown queued IDs remain unattributed")
queuedServer:Destroy()

local queuedABDefinition = assert(Definition.define({ name = "TrafficQueuedAB", version = 1,
	events = {
		A = { id = 51, direction = "ServerToClient", queue = "Batch", fields = { { name = "value", type = "u8" } } },
		B = { id = 52, direction = "ServerToClient", queue = "Batch", fields = { { name = "value", type = "u8" } } },
	},
}))
local queuedABRuntime = ServerRuntime.new()
local queuedABPlayer = queuedABRuntime:addPlayer()
local queuedABServer = assert(queuedABRuntime.server.create(queuedABDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true },
}))
assert(queuedABServer:Start())
local queuedAB = assert(queuedABServer:CreateBatcher({ queuedABPlayer }, 0.02))
assert(queuedAB.events.A:Send(1) and queuedAB.events.B:Send(2) and queuedAB.events.A:Send(3))
assert(queuedAB:Flush())
local queuedABSnapshot = queuedABServer:GetDiagnostics().traffic
local queuedABPacket = queuedABRuntime.fires[1].values[2]
local queuedABHeader = assert(BatchFrame.header(queuedABPacket, 8_192))
local queuedABRows = assert(BatchFrame.scan(queuedABPacket, queuedABHeader, function(id)
	return Definition.get(queuedABDefinition).queuedById[id]
end))
local bodyBytesA, bodyBytesB = 0, 0
for _, row in queuedABRows do
	if row.event.id == 51 then bodyBytesA += row.length + row.referenceCount * ByteUnits.REFERENCE_BYTES
	else bodyBytesB += row.length + row.referenceCount * ByteUnits.REFERENCE_BYTES end
end
assert(queuedABHeader.count == 3 and queuedABRows[1].event.id == 51
	and queuedABRows[2].event.id == 52 and queuedABRows[3].event.id == 51,
	"A, B, A accepted calls share one ordered batch packet")
assert(queuedABSnapshot.channels.Reliable.submittedRecords == 3
	and queuedABSnapshot.channels.Reliable.sentPackets == 1
	and queuedABSnapshot.channels.Reliable.sentRecords == 3
	and queuedABSnapshot.channels.Reliable.sentBytes == buffer.len(queuedABPacket),
	"submitted calls remain distinct while the shared packet is counted once")
assert(queuedABSnapshot.endpoints[51].channels.Reliable.submittedRecords == 2
	and queuedABSnapshot.endpoints[51].channels.Reliable.sentPackets == 1
	and queuedABSnapshot.endpoints[51].channels.Reliable.sentRecords == 2
	and queuedABSnapshot.endpoints[51].channels.Reliable.sentBytes == bodyBytesA
	and queuedABSnapshot.endpoints[52].channels.Reliable.submittedRecords == 1
	and queuedABSnapshot.endpoints[52].channels.Reliable.sentPackets == 1
	and queuedABSnapshot.endpoints[52].channels.Reliable.sentRecords == 1
	and queuedABSnapshot.endpoints[52].channels.Reliable.sentBytes == bodyBytesB,
	"endpoint rows count each distinct endpoint packet once and row bodies per accepted record")
queuedABServer:Destroy()

local streamDefinition = assert(Definition.define({ name = "TrafficStreamRecipients", version = 1, events = {
	Output = { id = 61, direction = "ServerToClient", delivery = "OrderedUnreliable", fields = {
		{ name = "time", type = "f64", minimum = 0, maximum = 2 ^ 41 },
		{ name = "value", type = "optional", value = { type = "u8" } },
	} },
} }))
local streamRuntime = ServerRuntime.new()
streamRuntime:addPlayer()
streamRuntime:addPlayer()
local streamServer = assert(streamRuntime.server.create(streamDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true, reports = true },
}))
assert(streamServer:Start())
local stream = assert(streamServer.events.Output:CreateBroadcastStream({ rate = 10 }))
assert(stream:Set(1))
streamRuntime:advance(0)
local streamSnapshot = streamServer:GetDiagnostics().traffic
local streamPacket = streamRuntime.fires[1].values[2]
local streamEndpoint = streamSnapshot.endpoints[61].channels.Unreliable
assert(streamEndpoint.sentPackets == 1 and streamEndpoint.sentRecords == 1
	and streamEndpoint.sentBytes == buffer.len(streamPacket) - 8
	and streamEndpoint.sentRecipientBytes == (buffer.len(streamPacket) - 8) * 2
	and streamSnapshot.channels.Unreliable.sentPackets == 1
	and streamSnapshot.channels.Unreliable.sentRecipientBytes == buffer.len(streamPacket) * 2,
	"a broadcast stream counts one native packet and models both recipients before handoff")
streamRuntime.throwFire = true
assert(stream:Set(2))
streamRuntime:advance(0.1)
local streamReports = streamServer:GetDiagnostics().reports
assert(streamReports.total == 1 and streamReports.entries[1].reason == "TransportFailure"
	and streamReports.entries[1].endpointId == 61 and streamReports.entries[1].channel == "Unreliable",
	"a stream native failure keeps its one session-owned structured report")
streamServer:Destroy()

local orderedInputDefinition = assert(Definition.define({ name = "TrafficOrderedInput", version = 1, events = {
	Input = { id = 62, direction = "ClientToServer", delivery = "OrderedUnreliable",
		fields = { { name = "value", type = "u8" } } },
} }))
local orderedInputRuntime = ServerRuntime.new()
local orderedInputPlayer = orderedInputRuntime:addPlayer()
local orderedInputServer = assert(orderedInputRuntime.server.create(orderedInputDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true },
}))
assert(orderedInputServer:Start())
local orderedInputReceived
assert(orderedInputServer.events.Input:Connect(function(_, value) orderedInputReceived = value end))
orderedInputRuntime:remote().OnServerEvent:Fire(orderedInputPlayer, 0,
	assert(OrderedFrame.hello("abcdefab-cdef-4000-8000-000000000010")))
local orderedInitialization = assert(OrderedFrame.readInitialization(
	orderedInputRuntime.fires[#orderedInputRuntime.fires].values[2]))
local orderedInputEvent = Definition.get(orderedInputDefinition).events.Input
local orderedInputEncoded = table.pack(Frame.compile(OrderedFrame.codecEvent(orderedInputEvent), "encode")(7))
assert(orderedInputEncoded[1] == true)
local orderedInputBody = orderedInputEncoded[2]
local orderedInputPacket = assert(OrderedFrame.wrap(orderedInputEvent, orderedInputBody,
	orderedInitialization.generation, 1))
orderedInputRuntime:unreliableRemote().OnServerEvent:Fire(orderedInputPlayer,
	orderedInputEvent.id, orderedInputPacket)
local orderedInputTraffic = orderedInputServer:GetDiagnostics().traffic
assert(orderedInputReceived == 7
	and orderedInputTraffic.channels.Unreliable.receivedBytes == buffer.len(orderedInputPacket)
	and orderedInputTraffic.endpoints[62].channels.Unreliable.receivedPackets == 1
	and orderedInputTraffic.endpoints[62].channels.Unreliable.receivedBytes == buffer.len(orderedInputBody)
	and orderedInputTraffic.endpoints[62].channels.Unreliable.validatedBytes == buffer.len(orderedInputBody),
	"ordered ingress separates full channel envelopes from endpoint body and validated units")
orderedInputServer:Destroy()

local rpcDefinition = assert(Definition.define({ name = "TrafficRpcFirstReason", version = 1,
	events = {}, requests = {
		Lookup = { id = 21, refusals = true, request = { { name = "flag", type = "boolean" } },
			response = { type = "boolean" } },
	},
}))
local rpcRuntime = ServerRuntime.new()
local rpcPlayer = rpcRuntime:addPlayer()
local rpcServer = assert(rpcRuntime.server.create(rpcDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { reports = true },
}))
assert(rpcServer:Start())
local rpcMethod = Definition.get(rpcDefinition).requests.Lookup
local shortBody = buffer.create(3)
buffer.writeu8(shortBody, 0, 1)
buffer.writeu16(shortBody, 1, rpcMethod.id)
local malformedRequest = assert(RpcFrame.wrap(1, rpcMethod.id, 1,
	"01234567-89ab-cdef-0123-456789abcdef", shortBody, false, rpcMethod.envelopeVersion))
rpcRuntime:remote().OnServerEvent:Fire(rpcPlayer, 0, malformedRequest)
local rpcSnapshot = rpcServer:GetDiagnostics()
assert(rpcSnapshot.counters.noListener == 1 and rpcSnapshot.counters.invalidPayload == 1
	and rpcSnapshot.reports.total == 1 and rpcSnapshot.reports.entries[1].reason == "NoListener"
	and rpcSnapshot.reports.entries[1].endpointId == rpcMethod.id
	and rpcSnapshot.reports.entries[1].channel == "Reliable",
	"a malformed request after a no-listener refusal keeps old counters and reports only its first reason")
rpcServer:Destroy()

local serverRequestDefinition = assert(Definition.define({ name = "TrafficServerRpcRequest", version = 1,
	events = {}, requests = {
		Push = { id = 22, direction = "ServerToClient", request = { { name = "value", type = "u8" } },
			response = { type = "boolean" } },
	},
}))
local serverRequestRuntime = ServerRuntime.new()
local serverRequestPlayer = serverRequestRuntime:addPlayer()
local serverRequestServer = assert(serverRequestRuntime.server.create(serverRequestDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true },
}))
assert(serverRequestServer:Start())
local beforeServerRequest = serverRequestServer:GetDiagnostics().traffic
local serverPending, serverRequestIssue = serverRequestServer.requests.Push:Request(serverRequestPlayer, 3, 7)
assert(serverPending, serverRequestIssue and serverRequestIssue.message)
local serverRequestPacket = serverRequestRuntime.fires[#serverRequestRuntime.fires].values[2]
local serverRequestHeader = assert(RpcFrame.peek(serverRequestPacket, true, true, 0))
local serverRequestMethod = Definition.get(serverRequestDefinition).requests.Push
local serverRequestBody = assert(RpcFrame.readBody(serverRequestPacket, serverRequestHeader,
	serverRequestMethod.request.minimumEncodedBytes, serverRequestMethod.request.maximumEncodedBytes,
	serverRequestMethod.request.maximumAdmissionBytes, serverRequestMethod.request.maximumReferences, 0))
local afterServerRequest = serverRequestServer:GetDiagnostics().traffic
local serverRequestChannel = afterServerRequest.channels.Reliable
local serverRequestRoute = afterServerRequest.endpoints[22].channels.Reliable
assert(serverRequestChannel.submittedRecords == beforeServerRequest.channels.Reliable.submittedRecords + 1
	and serverRequestChannel.submittedBytes == beforeServerRequest.channels.Reliable.submittedBytes
		+ buffer.len(serverRequestBody)
	and serverRequestChannel.sentPackets == beforeServerRequest.channels.Reliable.sentPackets + 1
	and serverRequestChannel.sentRecords == beforeServerRequest.channels.Reliable.sentRecords + 1
	and serverRequestChannel.sentBytes == beforeServerRequest.channels.Reliable.sentBytes
		+ buffer.len(serverRequestPacket)
	and serverRequestChannel.sentRecipientBytes == beforeServerRequest.channels.Reliable.sentRecipientBytes
		+ buffer.len(serverRequestPacket)
	and serverRequestRoute.submittedRecords == beforeServerRequest.endpoints[22].channels.Reliable.submittedRecords + 1
	and serverRequestRoute.submittedBytes == beforeServerRequest.endpoints[22].channels.Reliable.submittedBytes
		+ buffer.len(serverRequestBody)
	and serverRequestRoute.sentPackets == beforeServerRequest.endpoints[22].channels.Reliable.sentPackets + 1
	and serverRequestRoute.sentRecords == beforeServerRequest.endpoints[22].channels.Reliable.sentRecords + 1
	and serverRequestRoute.sentBytes == beforeServerRequest.endpoints[22].channels.Reliable.sentBytes
		+ buffer.len(serverRequestBody)
	and serverRequestRoute.sentRecipientBytes == beforeServerRequest.endpoints[22].channels.Reliable.sentRecipientBytes
		+ buffer.len(serverRequestBody),
	"server-initiated RPC requests count one full channel envelope and body-only method units")
serverPending:Cancel()
serverRequestServer:Destroy()

local timestampDefinition = assert(Definition.define({ name = "TrafficQueuedTimestamp", version = 1, events = {
	Good = { id = 25, direction = "ClientToServer", queue = "Batch", timestampWindow = 0.5,
		fields = { { name = "serverTime", type = "f64", minimum = 0, maximum = 2 ^ 41 },
			{ name = "value", type = "u8" } } },
	Bad = { id = 26, direction = "ClientToServer", queue = "Batch", timestampWindow = 0.5,
		fields = { { name = "serverTime", type = "f64", minimum = 0, maximum = 2 ^ 41 },
			{ name = "value", type = "u8" } } },
} }))
local timestampCompiled = Definition.get(timestampDefinition)
local timestampRuntime = ServerRuntime.new()
local timestampPlayer = timestampRuntime:addPlayer()
local function timestampBody(name, timestamp, value)
	local event = timestampCompiled.events[name]
	local encoded = table.pack(Frame.compile(timestampCompiled.queuedById[event.id], "encode")(timestamp, value))
	assert(encoded[1] == true)
	return encoded[2]
end
local timestampPacket = assert(BatchFrame.wrap(1, {
	timestampBody("Good", timestampRuntime.serverTime, 1),
	timestampBody("Bad", timestampRuntime.serverTime - 1, 2),
}, 8_192))
local timestampServer = assert(timestampRuntime.server.create(timestampDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true, reports = true },
}))
assert(timestampServer:Start())
assert(timestampServer.events.Good:Connect(function() end))
assert(timestampServer.events.Bad:Connect(function() end))
timestampRuntime:remote().OnServerEvent:Fire(timestampPlayer, 0, timestampPacket)
local timestampSnapshot = timestampServer:GetDiagnostics()
assert(timestampSnapshot.traffic.channels.Reliable.validatedRecords == 0
	and timestampSnapshot.traffic.endpoints[25].channels.Reliable.validatedRecords == 0
	and timestampSnapshot.traffic.endpoints[26].channels.Reliable.validatedRecords == 0
	and timestampSnapshot.reports.total == 1
	and timestampSnapshot.reports.entries[1].reason == "InvalidPayload"
	and timestampSnapshot.reports.entries[1].endpointId == 26
	and timestampSnapshot.reports.entries[1].channel == "Reliable",
	"a bad final timestamp invalidates the whole frame's validated-byte and record totals")
timestampServer:Destroy()

local budgetDefinition = assert(Definition.define({ name = "TrafficQueuedBudget", version = 1,
	outboundBytes = { capacity = 1, refillPerSecond = 1 },
	events = { State = { id = 31, direction = "ServerToClient", queue = "Batch",
		fields = { { name = "value", type = "u8" } } } },
}))
local budgetRuntime = ServerRuntime.new()
local budgetPlayer = budgetRuntime:addPlayer()
local budgetServer = assert(budgetRuntime.server.create(budgetDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { reports = true },
}))
assert(budgetServer:Start())
local budgetBatch = assert(budgetServer:CreateBatcher({ budgetPlayer }, 0.02))
assert(budgetBatch.events.State:Send(1))
local budgetSent, budgetIssue = budgetBatch:Flush()
local budgetReports = budgetServer:GetDiagnostics().reports
assert(not budgetSent and budgetIssue.code == "OutboundRateLimited"
	and budgetReports.total == 1 and budgetReports.entries[1].reason == "OutboundRateLimited",
	"a queued outbound-budget refusal produces one structured report")
budgetServer:Destroy()

local queuedDefinition = assert(Definition.define({ name = "TrafficQueuedFailure", version = 1,
	events = { State = { id = 41, direction = "ServerToClient", queue = "Batch",
		fields = { { name = "value", type = "u8" } } } },
}))
local queuedRuntime = ServerRuntime.new()
local queuedPlayer = queuedRuntime:addPlayer()
local queuedServer = assert(queuedRuntime.server.create(queuedDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true, reports = true },
}))
assert(queuedServer:Start())
local queuedBatch = assert(queuedServer:CreateBatcher({ queuedPlayer }, 0.02))
assert(queuedBatch.events.State:Send(1))
queuedRuntime.throwFire = true
local queuedSent = queuedBatch:Flush()
local queuedSnapshot = queuedServer:GetDiagnostics()
assert(not queuedSent and queuedSnapshot.reports.total == 1
	and queuedSnapshot.reports.entries[1].reason == "TransportFailure"
	and queuedSnapshot.reports.entries[1].channel == "Reliable"
	and queuedSnapshot.reports.entries[1].endpointId == nil,
	"a native queued handoff failure reports once and retains its known channel")
queuedRuntime.throwFire = false
queuedServer:Destroy()

local teardownRuntime = ServerRuntime.new()
local teardownPlayer = teardownRuntime:addPlayer()
local teardownServer = assert(teardownRuntime.server.create(queuedDefinition, {
	inboundRate = {
		perPlayer = { capacity = 4096, refillPerSecond = 1 },
		aggregate = { capacity = 32768, refillPerSecond = 1 },
	},
	diagnostics = { traffic = true, reports = true },
}))
assert(teardownServer:Start())
local teardownBatch = assert(teardownServer:CreateBatcher({ teardownPlayer }, 0.02))
assert(teardownBatch.events.State:Send(1))
teardownRuntime.afterFire = function() teardownServer:Destroy() end
assert(not teardownBatch:Flush())
local destroyedSnapshot = teardownServer:GetDiagnostics()
assert(destroyedSnapshot.state == "Destroyed"
	and destroyedSnapshot.traffic.channels.Reliable.submittedRecords == 1
	and destroyedSnapshot.traffic.channels.Reliable.sentPackets == 0
	and destroyedSnapshot.traffic.endpoints[41].channels.Reliable.sentPackets == 0
	and destroyedSnapshot.reports.total == 0,
	"a reentrant Destroy inside native handoff prevents every later sent/report update")
teardownBatch:Flush()
local laterSnapshot = teardownServer:GetDiagnostics()
assert(laterSnapshot.traffic.channels.Reliable.submittedRecords == 1
	and laterSnapshot.traffic.channels.Reliable.sentPackets == 0
	and laterSnapshot.reports.total == 0,
	"fixed scalar diagnostics remain unchanged after teardown")

print("PASS Relay.TrafficDiagnostics")
