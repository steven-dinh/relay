--!strict
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "Quickstart",
	version = 1,
	events = {
		Ping = s.clientToServer(1, s.fields(
			{ sequence = s.u32() }
		)),
	},
})

assert(definition, definitionError and definitionError.message)
return definition
