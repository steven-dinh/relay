--!strict

local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "StateSnapshots",
	version = 1,
	readiness = true,
	events = {
		Pose = s.serverToClient(1, s.fields(
			{ tick = s.u32(0, 4_294_967_295) },
			{ position = s.Vector3F32(-8192, 8192) }
		), { delivery = "Unreliable", queue = "State" }),
	},
})

return assert(definition, definitionError and definitionError.message)
