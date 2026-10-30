--!strict
-- Place this ModuleScript in ReplicatedStorage alongside Relay.
local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "PacedState",
	version = 1,
	outboundBytes = { capacity = 64, refillPerSecond = 96 },
	events = {
		Input = s.clientToServer(1, s.fields(
			{ serverTime = s.f64(0, 2^42) },
			{ value = s.u8(0, 100) }
		), { queue = "Batch", timestampWindow = 1 }),
		Snapshot = s.serverToClient(2, s.fields(
			{ value = s.u8(0, 100) },
			{ observedAt = s.f64(0, 2^42) }
		), { queue = "State" }),
	},
})

return (assert(definition, definitionError and definitionError.message))
