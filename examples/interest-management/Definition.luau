--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "InterestManagement",
	version = 1,
	events = {
		Notice = s.serverToClient(1, s.fields(
			{ message = s.string(128) }
		)),
		Score = s.serverToClient(2, s.fields(
			{ tick = s.u32(0, 4_294_967_295) },
			{ score = s.u16(0, 65_535) }
		), { queue = "State" }),
	},
})

return assert(definition, definitionError and definitionError.message)
