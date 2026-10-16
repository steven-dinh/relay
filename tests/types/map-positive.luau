--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local entry = s.taggedUnion("kind" :: "kind", {
	Ready = s.struct(s.field("amount" :: "amount", s.u8()),
		(s.field("note" :: "note", s.optional(s.string(8))))),
	Missing = s.struct(),
})
local totals = s.map(s.string(16), s.u16(), 8)
local records = s.map(s.u8(), entry, 4)
local fields = s.ordered(s.field("totals", totals), (s.field("records", records)))
local recordFields = s.ordered(s.field("records", records))
local definition, issue = Relay.define({ name = "MapTypes", version = 1, events = {
	Input = s.clientToServer(1, fields),
	Output = s.serverToClient(2, fields),
	Batch = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch", fields = recordFields },
	State = { id = 4, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State", fields = recordFields },
	BatchOutput = { id = 5, direction = "ServerToClient" :: "ServerToClient", queue = "Batch" :: "Batch", fields = recordFields },
	StateOutput = { id = 6, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State", fields = recordFields },
	Raw = { id = 7, direction = "ClientToServer" :: "ClientToServer", fields = s.ordered({
		name = "flags", type = "map" :: "map", key = { type = "i16" :: "i16" },
		value = { type = "boolean" :: "boolean" }, maximumSize = 4,
	}) },
}, requests = { Lookup = s.request(8, recordFields, totals) } })
local token = assert(definition, issue and issue.message)
local serverResult, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverIssue and serverIssue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")

server.events.Input:Connect(function(sender, counts, values)
	local userId: number = sender.UserId
	local count: number = counts.potion
	local value = values[1]
	if value.kind == "Ready" then
		local amount: number = value.amount
		local note: string? = value.note
		print(userId, count, amount, note)
	end
end)
client.events.Output:Connect(function(counts, values)
	local countsType: { [string]: number } = counts
	if values[1].kind == "Missing" then print(countsType) end
end)
server.events.Raw:Connect(function(_, flags)
	local typed: { [number]: boolean } = flags
	print(typed[-1])
end)
server.requests.Lookup:Connect(function(_, values)
	local value = values[1]
	if value.kind == "Ready" then
		local amount: number = value.amount
		print(amount)
	end
	return { potion = 4 }
end)
client.events.Input:Send({ potion = 3 }, { [1] = { kind = "Ready", amount = 2, note = nil } })
client.events.Raw:Send({ [-1] = false })
server.events.Output:Send(player, {}, { [2] = { kind = "Missing" } })
server.events.Output:Broadcast({ potion = 1 }, {})
server.events.Output:SendTo({ player }, {}, {})
local pendingResult, pendingIssue = client.requests.Lookup:Request(3, { [1] = { kind = "Missing" } })
local pending = assert(pendingResult, pendingIssue and pendingIssue.message)
local result = pending:Await()
if result.ok then
	local response: { [string]: number } = result.value
	print(response.potion)
end
local batchResult, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchResult, batchIssue and batchIssue.message)
batch.events.Batch:Send({ [1] = { kind = "Ready", amount = 2, note = "ok" } })
local stateResult, stateIssue = client:CreateState(0.02)
local state = assert(stateResult, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", { [2] = { kind = "Missing" } })
local serverBatchResult, serverBatchIssue = server:CreateBatch({ player }, 0.02)
local serverBatch = assert(serverBatchResult, serverBatchIssue and serverBatchIssue.message)
serverBatch.events.BatchOutput:Send({ [1] = { kind = "Missing" } })
local serverStateResult, serverStateIssue = server:CreateState({ player }, 0.02)
local serverState = assert(serverStateResult, serverStateIssue and serverStateIssue.message)
serverState.events.StateOutput:Put(1, "High", { [1] = { kind = "Ready", amount = 1 } })
local alias: Relay.FieldSpec = { name = "counts", type = "map" :: "map", key = { type = "string" :: "string", maximumBytes = 8 },
	value = { type = "u16" :: "u16" }, maximumSize = 4 }
local inspectionResult, inspectionIssue = Relay.inspect(token)
local inspection = assert(inspectionResult, inspectionIssue and inspectionIssue.message)
local capacity: number = inspection.limits.mapCapacity
print(alias, capacity)
