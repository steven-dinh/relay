--!strict
-- Place this ModuleScript in ReplicatedStorage alongside Relay.
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "Gameplay",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields(
			{ sequence = s.u32() },
			{ enabled = s.boolean() }
		)),
		State = s.serverToClient(2, s.fields(
			{ sequence = s.u32() },
			{ health = s.u8(nil, 100) }
		)),
	},
})

return assert(definition, definitionError and definitionError.message)
