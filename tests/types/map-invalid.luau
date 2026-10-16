--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local entry = s.struct((s.field("amount" :: "amount", s.u8())))
local totals = s.map(s.string(16), s.u16(), 8)
local records = s.map(s.u8(), entry, 4)
local definition, issue = Relay.define({ name = "BadMapTypes", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("totals", totals), (s.field("records", records)))),
	Batch = { id = 2, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
		fields = s.ordered(s.field("records", records)) },
	State = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State",
		fields = s.ordered(s.field("records", records)) },
}, requests = { Lookup = s.request(4, s.ordered(s.field("records", records)), totals) } })
local token = assert(definition, issue and issue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
local serverResult, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverIssue and serverIssue.message)
local wrongCounts: { [string]: string } = { potion = "bad" }
local wrongKeys: { [string]: { amount: number } } = { wrong = { amount = 1 } }
client.events.Input:Send(wrongCounts, {})
client.events.Input:Send({ [1] = 2 }, {})
client.events.Input:Send({}, wrongKeys)
client.events.Input:Send({}, { [1] = { amount = "bad" } })
server.events.Input:Connect(function(_, counts, values)
	local wrongCount: string = counts.potion
	local wrongValue: string = values[1].amount
	print(wrongCount, wrongValue)
end)
client.requests.Lookup:Request(3, { [1] = { amount = "bad" } })
server.requests.Lookup:Connect(function() return wrongCounts end)
local batchResult, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchResult, batchIssue and batchIssue.message)
batch.events.Batch:Send({ [1] = { amount = "bad" } })
local stateResult, stateIssue = client:CreateState(0.02)
local state = assert(stateResult, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", wrongKeys)

local badKey = Relay.define({ name = "BoolMapKey", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("value", s.map(s.boolean(), s.u8(), 4)))),
} })
local optionalValue = Relay.define({ name = "OptionalMapValue", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("value", s.map(s.string(8), s.optional(s.u8()), 4)))),
} })
local namedKey = Relay.define({ name = "NamedMapKey", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("value", s.map(s.field("key", s.u8()), s.u8(), 4)))),
} })
local badCapacity = s.map(s.u8(), s.u8(), "four")
print(badKey, optionalValue, namedKey, badCapacity)
