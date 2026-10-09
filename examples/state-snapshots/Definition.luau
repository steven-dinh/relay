--!strict

local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "StateSnapshots",
	version = 1,
	events = {
		Pose = {
			id = 1,
			direction = "ServerToClient" :: "ServerToClient",
			delivery = "Unreliable" :: "Unreliable",
			queue = "State" :: "State",
			fields = s.ordered(
				s.field("tick", s.u32(0, 4_294_967_295)),
				(s.field("position", s.Vector3F32(-8192, 8192)))
			),
		},
	},
})

return assert(definition, definitionError and definitionError.message)
