--!strict
-- Place this ModuleScript in ReplicatedStorage alongside Relay.
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema
-- Parenthesize the final field call so the pinned solver sees one ordered result.

local definition, definitionError = Relay.define({
	name = "Gameplay",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.ordered(
			s.field("sequence", s.u32()),
			(s.field("enabled", s.boolean()))
		)),
		State = s.serverToClient(2, s.ordered(
			s.field("sequence", s.u32()),
			(s.field("health", s.u8(nil, 100)))
		)),
	},
})

return assert(definition, definitionError and definitionError.message)
