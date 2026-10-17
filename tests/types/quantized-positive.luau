--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local scalar = s.quantized(-1, 1, 0.01)
local raw: { type: "quantized", minimum: number, maximum: number, step: number } = {
	type = "quantized", minimum = 0, maximum = 10, step = 0.5,
}
local choice = s.taggedUnion("kind" :: "kind", {
	Scalar = s.struct((s.field("value" :: "value", scalar))),
	Raw = s.struct((s.field("value" :: "value", raw))),
})
local nested = s.struct(
	s.field("optional" :: "optional", s.optional(scalar)),
	s.field("array" :: "array", s.array(scalar, 4)),
	s.field("map" :: "map", s.map(s.string(8), scalar, 4)),
	(s.field("choice" :: "choice", choice))
)
local fields = s.ordered(s.field("value", scalar), s.field("raw", raw), (s.field("nested", nested)))
local definition, issue = Relay.define({
	name = "QuantizedTypes", version = 1,
	events = {
		Input = s.clientToServer(1, fields),
		Output = s.serverToClient(2, fields),
		Unreliable = s.clientToServer(3, s.ordered(s.field("value", scalar)), "Unreliable"),
		OrderedUnreliable = s.serverToClient(4, s.ordered(s.field("value", scalar)), "OrderedUnreliable"),
		Batch = { id = 5, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
			fields = s.ordered(s.field("value", scalar)) },
		State = { id = 6, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
			fields = s.ordered(s.field("value", scalar)) },
	},
	requests = { RoundTrip = s.request(7, s.ordered(s.field("value", scalar)), s.optional(scalar)) },
})
local token = assert(definition, issue and issue.message)
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")
local sent: number = 0.37

server.events.Input:Connect(function(_, value, rawValue, payload)
	local scalarValue: number = value
	local rawValueNumber: number = rawValue
	local optionalValue: number? = payload.optional
	local arrayValues: { number } = payload.array
	local mapValues: { [string]: number } = payload.map
	if payload.choice.kind == "Scalar" then
		local unionValue: number = payload.choice.value
		print(unionValue)
	else
		local rawUnionValue: number = payload.choice.value
		print(rawUnionValue)
	end
	print(scalarValue, rawValueNumber, optionalValue, arrayValues, mapValues)
end)
client.events.Output:Connect(function(value, rawValue, payload)
	local scalarValue: number = value
	local rawValueNumber: number = rawValue
	local optionalValue: number? = payload.optional
	print(scalarValue, rawValueNumber, optionalValue)
end)
server.requests.RoundTrip:Connect(function(_, value): number?
	local actual: number = value
	return actual
end)

client.events.Input:Send(sent, 2, { optional = nil, array = { 1 }, map = { entry = 2 },
	choice = { kind = "Scalar", value = 3 } })
server.events.Output:Send(player, sent, 2, { optional = sent, array = {}, map = {},
	choice = { kind = "Raw", value = 4 } })
client.events.Unreliable:Send(sent)
server.events.OrderedUnreliable:Send(player, sent)
local batchValue, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchValue, batchIssue and batchIssue.message)
batch.events.Batch:Send(sent)
local stateValue, stateIssue = server:CreateState({ player }, 0.02)
local state = assert(stateValue, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", sent)
local pendingValue, pendingIssue = client.requests.RoundTrip:Request(1, sent)
local pending = assert(pendingValue, pendingIssue and pendingIssue.message)
local result = pending:Await()
if result.ok then
	local response: number? = result.value
	print(response)
end
print(server, client, batch, state)
