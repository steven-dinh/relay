--!strict
-- Place this ModuleScript in ReplicatedStorage alongside Relay.
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "SharedBroadcast",
	version = 1,
	events = {
		Round = s.serverToClient(1, s.fields(
			{ round = s.u8(1, 100) }
		), { queue = "Batch" }),
		Announcement = s.serverToClient(2, s.fields(
			{ message = s.string(64) }
		), { queue = "Batch" }),
	},
})

return assert(definition, definitionError and definitionError.message)
