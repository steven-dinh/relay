--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local ordered = require("../../examples/reliable-events/ordered")

local payload = s.taggedUnion("kind" :: "kind", {
	Success = s.struct(
		s.field("value" :: "value", s.u8()),
		(s.field("colors" :: "colors", s.array(s.Color3(), 2)))
	),
	Failure = s.struct((s.field("reason" :: "reason", s.string(24)))),
})
local nestedPayload = s.taggedUnion("state" :: "state", {
	Ready = s.struct((s.field("value" :: "value", s.u8()))),
	Failed = s.struct((s.field("reason" :: "reason", s.string(24)))),
})
local nested = s.struct(
	s.field("items" :: "items", s.array(nestedPayload, 2)),
	(s.field("maybe" :: "maybe", s.optional(nestedPayload)))
)

local definition, issue = Relay.define({
	name = "TaggedUnionTypes", version = 1,
	events = {
		Input = s.clientToServer(1, s.ordered(s.field("payload" :: "payload", payload))),
		Output = s.serverToClient(2, s.ordered(s.field("payload" :: "payload", payload))),
		Nested = s.clientToServer(3, s.ordered(s.field("payload" :: "payload", nested))),
		BatchInput = { id = 4, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
			fields = ordered(s.field("payload" :: "payload", payload)) },
		StateInput = { id = 5, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State",
			fields = ordered(s.field("payload" :: "payload", payload)) },
		BatchOutput = { id = 6, direction = "ServerToClient" :: "ServerToClient", queue = "Batch" :: "Batch",
			fields = ordered(s.field("payload" :: "payload", payload)) },
		StateOutput = { id = 7, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
			fields = ordered(s.field("payload" :: "payload", payload)) },
	},
	requests = {
		Inspect = s.request(8, ordered(s.field("payload" :: "payload", payload)), payload),
	},
})
local token = assert(definition, issue and issue.message)
local serverResult, serverProblem = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverProblem and serverProblem.message)
local clientResult, clientProblem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientProblem and clientProblem.message)
local player: Player = error("type-only fixture")

server.events.Input:Connect(function(_, value)
	if value.kind == "Success" then
		local amount: number = value.value
		local colors: { Color3 } = value.colors
		print(amount, colors)
	else
		local reason: string = value.reason
		print(reason)
	end
end)
client.events.Output:Connect(function(value)
	if value.kind == "Success" then
		local amount: number = value.value
		print(amount, value.colors)
	else
		local reason: string = value.reason
		print(reason)
	end
end)
server.events.Nested:Connect(function(_, value)
	local first = value.items[1]
	if first.state == "Ready" then
		local numberValue: number = first.value
		print(numberValue)
	else
		local reason: string = first.reason
		print(reason)
	end
	if value.maybe and value.maybe.state == "Failed" then
		local optionalReason: string = value.maybe.reason
		print(optionalReason)
	end
end)
server.requests.Inspect:Connect(function(_, request)
	if request.kind == "Success" then
		local amount: number = request.value
		print(amount)
	else
		local reason: string = request.reason
		print(reason)
	end
	return { kind = "Failure", reason = "not found" }
end)

client.events.Input:Send({ kind = "Success", value = 8, colors = { Color3.new(1, 0, 0) } })
server.events.Output:Send(player, { kind = "Failure", reason = "missing" })
server.events.Output:Broadcast({ kind = "Success", value = 4, colors = {} })
server.events.Output:SendTo({ player }, { kind = "Failure", reason = "targeted" })
client.events.Nested:Send({ items = { { state = "Failed", reason = "gone" } }, maybe = nil })
local pendingResult, pendingProblem = client.requests.Inspect:Request(3,
	{ kind = "Success", value = 1, colors = {} })
local pending = assert(pendingResult, pendingProblem and pendingProblem.message)
local result = pending:Await()
if result.ok then
	if result.value.kind == "Success" then
		local resultValue: number = result.value.value
		print(resultValue)
	else
		local resultReason: string = result.value.reason
		print(resultReason)
	end
else
	local resultCode: Relay.ErrorCode = result.error.code
	print(resultCode)
end
pending:Cancel()

local batchResult, batchProblem = client:CreateBatch(0.02)
local batch = assert(batchResult, batchProblem and batchProblem.message)
batch.events.BatchInput:Send({ kind = "Failure", reason = "batch" })
local stateResult, stateProblem = client:CreateState(0.02)
local state = assert(stateResult, stateProblem and stateProblem.message)
state.events.StateInput:Put(1, "Normal", { kind = "Success", value = 2, colors = {} })
local serverBatchResult, serverBatchProblem = server:CreateBatch({ player }, 0.02)
local serverBatch = assert(serverBatchResult, serverBatchProblem and serverBatchProblem.message)
serverBatch.events.BatchOutput:Send({ kind = "Failure", reason = "queued" })
local serverStateResult, serverStateProblem = server:CreateState({ player }, 0.02)
local serverState = assert(serverStateResult, serverStateProblem and serverStateProblem.message)
serverState.events.StateOutput:Put(2, "High", { kind = "Success", value = 3, colors = {} })

print(client, server, batch, state, serverBatch, serverState)
