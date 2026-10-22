--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition, issue = Relay.define({ name = "InvalidStateDeferralTypes", version = 1, events = {
	State = { id = 1, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
		fields = s.ordered((s.field("value" :: "value", s.u8()))) },
} })
local token = assert(definition, issue and issue.message)
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 },
	aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")

local wrongOptionType: Relay.StateOptions = { deferOutbound = "yes" }
local wrongOptions = server:CreateState({ player }, 0.02, "defer")
local wrongBoolean = server:CreateState({ player }, 0.02, { deferOutbound = 1 })
local clientOption = client:CreateState(0.02, { deferOutbound = true })
print(wrongOptionType, wrongOptions, wrongBoolean, clientOption)
