--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition, issue = Relay.define({ name = "InvalidBufferTypes", version = 1, events = {
	Input = s.clientToServer(1, s.ordered((s.field("data" :: "data", s.buffer(16))))),
	Output = s.serverToClient(2, s.ordered((s.field("data" :: "data", s.buffer(16))))),
	Batch = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
		fields = s.ordered((s.field("data" :: "data", s.buffer(16)))) },
	State = { id = 4, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State",
		fields = s.ordered((s.field("data" :: "data", s.buffer(16)))) },
}, requests = { RoundTrip = s.request(5, s.ordered((s.field("data" :: "data", s.buffer(16)))), s.buffer(16)) } })
local token = assert(definition, issue and issue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 },
	aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local player: Player = error("type-only fixture")
local payload: buffer = buffer.create(8)

local wrongBuffer: buffer = "not a buffer"
client.events.Input:Send("not a buffer")
client.events.Input:Send({ 1, 2, 3 })
server.events.Input:Connect(function(_, data: string)
	print(data)
end)
server.events.Output:Send(player, "not a buffer")
server.requests.RoundTrip:Connect(function(_, data)
	print(data)
	return "not a buffer"
end)
client.requests.RoundTrip:Request(1, "not a buffer")
local batchValue, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchValue, batchIssue and batchIssue.message)
batch.events.Batch:Send("not a buffer")
local stateValue, stateIssue = client:CreateState(0.02)
local state = assert(stateValue, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", "not a buffer")

local wrongMaximum = s.buffer("sixteen")
local wrongMaximumShape: { type: "buffer", maximumBytes: string } = { type = "buffer", maximumBytes = "16" }
local missingMaximumShape = { type = "buffer" :: "buffer" }
local extraKeyShape = { type = "buffer" :: "buffer", maximumBytes = 16, extra = true }
local rawWrongType = Relay.define({ name = "WrongBufferMaximumType", version = 1, events = {
	Input = s.clientToServer(1, s.ordered((s.field("data" :: "data", wrongMaximumShape)))),
} })
local rawMissingMaximum = Relay.define({ name = "MissingBufferMaximum", version = 1, events = {
	Input = s.clientToServer(1, s.ordered((s.field("data" :: "data", missingMaximumShape)))),
} })
local rawExtraKey = Relay.define({ name = "ExtraBufferKey", version = 1, events = {
	Input = s.clientToServer(1, s.ordered((s.field("data" :: "data", extraKeyShape)))),
} })
local badMapKey = Relay.define({ name = "BufferMapKey", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("data", s.map(s.buffer(16), s.u8(), 4)))),
} })
local badSetElement = Relay.define({ name = "BufferSetElement", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("data", s.set(s.buffer(16), 4)))),
} })
print(wrongBuffer, wrongMaximum, rawWrongType, rawMissingMaximum, rawExtraKey, badMapKey, badSetElement,
	payload, server)
