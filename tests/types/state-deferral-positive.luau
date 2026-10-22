--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local schema = { name = "StateDeferralTypes", version = 1, events = {
	State = { id = 1, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
		fields = s.ordered((s.field("value" :: "value", s.u8()))) },
} }
local definition, issue = Relay.define(schema)
local token = assert(definition, issue and issue.message)
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 },
	aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")

local options: Relay.StateOptions = { deferOutbound = true }
local emptyOptions: Relay.StateOptions = {}
local withOptionsValue, withOptionsIssue = server:CreateState({ player }, 0.02, options)
local withOptions = assert(withOptionsValue, withOptionsIssue and withOptionsIssue.message)
local falseOptionsValue, falseOptionsIssue = server:CreateState({ player }, 0.02, { deferOutbound = false })
local falseOptions = assert(falseOptionsValue, falseOptionsIssue and falseOptionsIssue.message)
local defaultValue, defaultIssue = server:CreateState({ player }, 0.02)
local defaultState = assert(defaultValue, defaultIssue and defaultIssue.message)
local publicServer: Relay.ServerSession<typeof(schema)> = server
local generatedValue, generatedIssue = publicServer:CreateState({ player }, 0.02, emptyOptions)
local generatedState = assert(generatedValue, generatedIssue and generatedIssue.message)
local clientStateValue, clientStateIssue = client:CreateState(0.02)
local clientState = assert(clientStateValue, clientStateIssue and clientStateIssue.message)
print(withOptions, falseOptions, defaultState, generatedState, clientState)
