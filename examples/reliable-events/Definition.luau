--!strict
-- Place this ModuleScript and ordered.luau in ReplicatedStorage alongside Relay.
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local ordered = require(game:GetService("ReplicatedStorage").ordered)

local definition, definitionError = Relay.define({
	name = "Gameplay",
	version = 1,
	events = {
		Input = {
			id = 1,
			direction = "ClientToServer" :: "ClientToServer",
			fields = ordered(
				{ name = "sequence", type = "u32" :: "u32" },
				{ name = "enabled", type = "boolean" :: "boolean" }
			),
		},
		State = {
			id = 2,
			direction = "ServerToClient" :: "ServerToClient",
			fields = ordered(
				{ name = "sequence", type = "u32" :: "u32" },
				{ name = "health", type = "u8" :: "u8", maximum = 100 }
			),
		},
	},
})

return assert(definition, definitionError and definitionError.message)
