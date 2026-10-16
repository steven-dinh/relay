--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local payload = s.taggedUnion("kind" :: "kind", {
	Success = s.struct((s.field("value" :: "value", s.u8()))),
	Failure = s.struct((s.field("reason" :: "reason", s.string(24)))),
})
local definitionResult, definitionProblem = Relay.define({ name = "TaggedUnionInvalidTypes", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("payload" :: "payload", payload))),
} })
local definition = assert(definitionResult, definitionProblem and definitionProblem.message)
local clientResult, clientProblem = Relay.createClient(definition, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientProblem and clientProblem.message)
local serverResult, serverProblem = Relay.createServer(definition, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverProblem and serverProblem.message)

client.events.Input:Send({ kind = "Other", value = 1 })
server.events.Input:Connect(function(_, value)
	if value.kind == "Success" then
		local wrongBranch: string = value.reason
		print(wrongBranch)
	else
		local wrongBranch: number = value.value
		print(wrongBranch)
	end
end)
