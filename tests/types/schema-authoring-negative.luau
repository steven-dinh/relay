--!strict
local Relay = require("../../src/init")
local Shapes = require("./schema-authoring-shapes")
local s = Relay.schema
local definitionResult, definitionProblem = Relay.define({
	name = "SchemaAuthoringInvalidTypes",
	version = 1,
	events = {
		InputBatch = s.clientToServer(1, s.fields({ payload = Shapes.Result }), { queue = "Batch" }),
		InputState = s.clientToServer(2, s.fields({ payload = Shapes.Result }), { queue = "State" }),
		OutputState = s.serverToClient(3, s.fields({ payload = Shapes.Result }), { queue = "State" }),
	},
})
local definition = assert(definitionResult, definitionProblem and definitionProblem.message)
local clientResult, clientProblem = Relay.createClient(definition, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientProblem and clientProblem.message)
local stateResult, stateProblem = client:CreateState(0.02)
local state = assert(stateResult, stateProblem and stateProblem.message)
local batchResult, batchProblem = client:CreateBatch(0.02)
local batch = assert(batchResult, batchProblem and batchProblem.message)

local rejectedBatchOrdered = s.clientToServer(4, s.fields({ value = s.u8() }), {
	queue = "Batch",
	delivery = "OrderedUnreliable",
})
local rejectedStateOrdered = s.serverToClient(5, s.fields({ value = s.u8() }), {
	queue = "State",
	delivery = "OrderedUnreliable",
})
local invalidQueue = s.clientToServer(6, s.fields({ value = s.u8() }), { queue = "Stream" })
local wrongBatchPut = batch.events.InputBatch.Put
local wrongStateQueue = state.events.InputBatch
client.events.InputBatch:Send({ kind = "Success", reason = "wrong payload" })
client.events.InputBatch:Send({ kind = "Other", value = 1 })
client.events.OutputState:Connect(function(payload)
	if payload.kind == "Success" then
		local wrong: string = payload.value
		print(wrong)
	end
end)
print(rejectedBatchOrdered, rejectedStateOrdered, invalidQueue, wrongBatchPut, wrongStateQueue)
s.clientToServer(7, s.fields(), { delivery = "Slow" })
