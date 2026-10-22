--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local direct = s.buffer(64)
local rawBuffer: { type: "buffer", maximumBytes: number } = {
	type = "buffer", maximumBytes = 32,
}
local record = s.struct(
	s.field("parts" :: "parts", s.array(s.buffer(24), 4)),
	(s.field("optional" :: "optional", s.optional(s.buffer(0))))
)
local choice = s.taggedUnion("kind" :: "kind", {
	Chunk = s.struct((s.field("data" :: "data", s.buffer(16)))),
	Count = s.struct((s.field("count" :: "count", s.u16()))),
})
local definition, issue = Relay.define({
	name = "BufferTypes", version = 1,
	events = {
		Input = s.clientToServer(1, s.ordered(s.field("data" :: "data", direct),
			s.field("record" :: "record", record), s.field("choice" :: "choice", choice),
			(s.field("raw" :: "raw", rawBuffer)))),
		Output = s.serverToClient(2, s.ordered((s.field("data" :: "data", direct)))),
		Batch = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
			fields = s.ordered((s.field("data" :: "data", direct))) },
		State = { id = 4, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
			fields = s.ordered((s.field("data" :: "data", direct))) },
	},
	requests = { RoundTrip = s.request(5, s.ordered((s.field("data" :: "data", direct))), direct) },
})
local token = assert(definition, issue and issue.message)
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 },
	aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")
local payload: buffer = buffer.create(8)

client.events.Input:Send(payload, { parts = { payload }, optional = nil }, { kind = "Chunk", data = payload }, payload)
server.events.Output:Send(player, payload)
server.events.Input:Connect(function(_, data, nested, variant, raw)
	local typedData: buffer = data
	local typedPart: buffer = nested.parts[1]
	local optionalPart: buffer? = nested.optional
	local typedVariant: buffer
	if variant.kind == "Chunk" then
		typedVariant = variant.data
	else
		typedVariant = buffer.create(0)
	end
	local typedRaw: buffer = raw
	print(typedData, typedPart, optionalPart, typedVariant, typedRaw)
end)
client.events.Output:Connect(function(data)
	local typedData: buffer = data
	print(typedData)
end)
server.requests.RoundTrip:Connect(function(_, data): buffer
	local typedRequest: buffer = data
	return typedRequest
end)
local pendingValue, pendingIssue = client.requests.RoundTrip:Request(1, payload)
local pending = assert(pendingValue, pendingIssue and pendingIssue.message)
local response = pending:Await()
if response.ok then
	local typedResponse: buffer = response.value
	print(typedResponse)
end

local batchValue, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchValue, batchIssue and batchIssue.message)
batch.events.Batch:Send(payload)
local stateValue, stateIssue = server:CreateState({ player }, 0.02)
local state = assert(stateValue, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", payload)
print(token, server, client, batch, state)
