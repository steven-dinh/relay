--!strict
local Relay = require("../../src/init")
local Shapes = require("./schema-authoring-shapes")
local s = Relay.schema

local definitionResult, definitionProblem = Relay.define({
	name = "SchemaAuthoringTypes",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ sequence = s.u32() }, { enabled = s.boolean() })),
		Empty = s.serverToClient(2, s.fields()),
		LegacyDelivery = s.clientToServer(3, s.fields({ value = s.u8() }), "Unreliable"),
		Unreliable = s.serverToClient(4, s.fields({ value = s.u8() }), { delivery = "Unreliable" }),
		Ordered = s.clientToServer(5, s.fields({ value = s.u8() }), { delivery = "OrderedUnreliable" }),
		BatchInput = s.clientToServer(6, s.fields({ payload = Shapes.Result }), { queue = "Batch" }),
		StateInput = s.clientToServer(7, s.fields({ payload = Shapes.Result }), { delivery = "Unreliable", queue = "State" }),
		BatchOutput = s.serverToClient(8, s.fields({ payload = Shapes.Result }), { queue = "Batch" }),
		StateOutput = s.serverToClient(9, s.fields({ payload = Shapes.Result }), { delivery = "Unreliable", queue = "State" }),
		LegacyFields = s.serverToClient(13, s.fields(s.field("value" :: "value", s.u16()))),
		Composite = s.serverToClient(10, s.fields(
			{ record = Shapes.Record }, { legacy = Shapes.LegacyRecord },
			{ mixed = Shapes.MixedRecord }, { namedKeys = Shapes.NamedKeys }
		)),
		Native = s.serverToClient(11, s.fields(
			{ position = s.Vector3F32(-100, 100) }, { tint = s.Color3() }, { offset = s.UDim(-2, 2, -100, 100) }
		)),
	},
	requests = {
		Inspect = s.request(12, s.fields({ query = s.string(24) }), Shapes.Result),
	},
})
local definition = assert(definitionResult, definitionProblem and definitionProblem.message)
local serverResult, serverProblem = Relay.createServer(definition, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 },
	aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverProblem and serverProblem.message)
local clientResult, clientProblem = Relay.createClient(definition, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientProblem and clientProblem.message)
local player: Player = error("type-only fixture")

client.events.Input:Send(42, true)
client.events.BatchInput:Send({ kind = "Success", value = 8 })
server.events.StateOutput:Send(player, { kind = "Failure", reason = "missing" })
server.events.BatchOutput:Send(player, { kind = "Success", value = 7 })
server.events.Unreliable:Send(player, 4)
server.events.Native:Broadcast(Vector3.new(), Color3.new(), UDim.new(0.5, 2))

server.events.Input:Connect(function(sender, sequence, enabled)
	local actualPlayer: Player = sender
	local actualSequence: number = sequence
	local actualEnabled: boolean = enabled
	print(actualPlayer, actualSequence, actualEnabled)
end)
client.events.Composite:Connect(function(record, legacy, mixed, namedKeys)
	local mode: "Idle" | "Run" = record.mode
	local legacyValue: number = legacy.value
	local mixedValue: number = mixed.id + mixed.count
	local mixedMode: "Idle" | "Run" = mixed.mode
	local namedValue: number = namedKeys.name
	local typeValue: string = namedKeys.type
	print(mode, legacyValue, mixedValue, mixedMode, namedValue, typeValue)
end)
client.events.LegacyFields:Connect(function(value)
	local legacyValue: number = value
	print(legacyValue)
end)
client.events.StateOutput:Connect(function(payload)
	if payload.kind == "Success" then
		local value: number = payload.value
		print(value)
	else
		local reason: string = payload.reason
		print(reason)
	end
end)
server.requests.Inspect:Connect(function(_, query)
	local actualQuery: string = query
	print(actualQuery)
	return { kind = "Failure", reason = "not found" }
end)

local pendingResult, pendingProblem = client.requests.Inspect:Request(1, "find")
local pending = assert(pendingResult, pendingProblem and pendingProblem.message)
local response = pending:Await()
if response.ok then
	if response.value.kind == "Success" then
		local value: number = response.value.value
		print(value)
	else
		local reason: string = response.value.reason
		print(reason)
	end
end
pending:Cancel()

local batchResult, batchProblem = client:CreateBatch(0.02)
local batch = assert(batchResult, batchProblem and batchProblem.message)
batch.events.BatchInput:Send({ kind = "Failure", reason = "batch" })
local stateResult, stateProblem = client:CreateState(0.02)
local state = assert(stateResult, stateProblem and stateProblem.message)
state.events.StateInput:Put(2, "High", { kind = "Success", value = 2 })
local serverBatchResult, serverBatchProblem = server:CreateBatch({ player }, 0.02)
local serverBatch = assert(serverBatchResult, serverBatchProblem and serverBatchProblem.message)
serverBatch.events.BatchOutput:Send({ kind = "Failure", reason = "queued" })
local serverStateResult, serverStateProblem = server:CreateState({ player }, 0.02)
local serverState = assert(serverStateResult, serverStateProblem and serverStateProblem.message)
serverState.events.StateOutput:Put(3, "Low", { kind = "Success", value = 3 })
print(Shapes.Mode, batch, state, serverBatch, serverState)
