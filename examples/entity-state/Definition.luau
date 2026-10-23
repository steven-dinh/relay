--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local s = Relay.schema

local entity = s.struct(
	{ id = s.u16(1, 65_535) },
	{ health = s.u16(0, 1_000) }
)
local update = s.struct(
	{ epoch = s.u32(1, 4_294_967_295) },
	{ revision = s.u32(0, 4_294_967_295) },
	{ kind = s.enum({ Put = 1, Delete = 2, Reset = 3, Closed = 4 }) },
	{ id = s.u16(0, 65_535) },
	{ health = s.u16(0, 1_000) }
)
local snapshot = s.struct(
	{ status = s.enum({ Ready = 1, Denied = 2, Busy = 3 }) },
	{ epoch = s.u32(0, 4_294_967_295) },
	{ revision = s.u32(0, 4_294_967_295) },
	{ entities = s.array(entity, 32) }
)

local definition, definitionError = Relay.define({
	name = "EntityState",
	version = 1,
	events = {
		Update = s.serverToClient(1, s.fields({ update = update })),
	},
	requests = {
		Snapshot = s.request(2, s.ordered(), snapshot, { concurrency = 1, refusals = true }),
	},
})

return (assert(definition, definitionError and definitionError.message))
