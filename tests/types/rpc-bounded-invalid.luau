--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local badFloat = s.f24(-1, "1")
local badArray = s.array(s.u24(), 4, "zero")
local badDirection = s.request(1, s.ordered(), s.boolean(), { direction = "Both" })
local badConcurrency = s.request(2, s.ordered(), s.boolean(), { concurrency = "two" })
local badRefusals = s.request(3, s.ordered(), s.boolean(), { refusals = "yes" })

local invalidOptions = Relay.define({ name = "UnknownRpcOption", version = 1, events = {}, requests = {
    Query = s.request(4, s.ordered(), s.boolean(), { extra = true }),
} })
local invalidDirection = Relay.define({ name = "UnknownRpcDirection", version = 1, events = {}, requests = {
    Query = badDirection,
} })

local valid, issue = Relay.define({ name = "WrongRpcSide", version = 1, events = {}, requests = {
    Query = s.request(5, s.ordered(), s.boolean(), { direction = "ServerToClient" }),
} })
local token = assert(valid, issue and issue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
client.requests.Query:Request(3)

print(badFloat, badArray, badConcurrency, badRefusals, invalidOptions, invalidDirection)
