--!strict

local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, problem = Relay.define({
	name = "ConsumerTesting", version = 1,
	events = {
		Ready = s.clientToServer(1, s.fields()),
		Notice = s.serverToClient(2, s.fields({ value = s.u8() })),
		Input = s.clientToServer(3, s.fields({ value = s.u8() }), { queue = "Batch" }),
		Close = s.clientToServer(4, s.fields()),
	},
	requests = {
		Slow = s.request(5, s.fields({ value = s.u8() }), s.u8()),
	},
})

return assert(definition, problem and problem.message)
