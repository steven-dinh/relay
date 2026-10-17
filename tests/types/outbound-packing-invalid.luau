--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local wrongFlagType = Relay.define({ name = "WrongBitPacking", version = 1, bitPacking = "true", events = {} })
local wrongBudgetType = Relay.define({ name = "WrongOutboundBudget", version = 1,
	outboundBytes = { capacity = "4096", refillPerSecond = 2048 }, events = {} })
local missingBudgetField = Relay.define({ name = "MissingOutboundRate", version = 1,
	outboundBytes = { capacity = 4096 }, events = {} })
local unknownBudgetField = Relay.define({ name = "UnknownOutboundField", version = 1,
	outboundBytes = { capacity = 4096, refillPerSecond = 2048, extra = 1 }, events = {} })
local wrongEnum = s.enum("Idle" :: "Idle", "Run" :: "Run")
local token = assert(Relay.define({ name = "WrongPackedPayload", version = 1, bitPacking = true, events = {
	Input = s.clientToServer(1, s.ordered(s.field("active" :: "active", s.boolean()),
		(s.field("mode" :: "mode", wrongEnum)))),
} }), "type-only invalid packed payload fixture")
local clientValue, _issue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, "type-only client")
client.events.Input:Send("true", "Unknown")

local noBudget = assert(Relay.define({ name = "NoBudgetBatch", version = 1, events = {
	Input = { id = 2, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
		fields = s.ordered((s.field("active" :: "active", s.boolean()))) },
} }), "type-only batch fixture")
local noBudgetClientValue, _noBudgetIssue = Relay.createClient(noBudget, { startupTimeoutSeconds = 3 })
local noBudgetClient = assert(noBudgetClientValue, "type-only batch client")
local batchValue, _batchIssue = noBudgetClient:CreateBatch(0.02)
local batch = assert(batchValue, "type-only batch")
batch:GetStatus("extra")
print(wrongFlagType, wrongBudgetType, missingBudgetField, unknownBudgetField)
