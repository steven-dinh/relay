-- Place this ModuleScript in ReplicatedStorage alongside the Relay package.
local Relay = require(game:GetService("ReplicatedStorage").Relay)

return assert(Relay.define({
	name = "Gameplay",
	version = 1,
	events = {
		Input = {
			id = 1,
			direction = "ClientToServer",
			fields = {
				{ name = "sequence", type = "u32" },
				{ name = "enabled", type = "boolean" },
			},
		},
		State = {
			id = 2,
			direction = "ServerToClient",
			fields = {
				{ name = "sequence", type = "u32" },
				{ name = "health", type = "u8", maximum = 100 },
			},
		},
	},
}))
