--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local s = Relay.schema
local Combat = require(ReplicatedStorage.Combat)
local Inventory = require(ReplicatedStorage.Inventory)

local events, composeError = s.compose(Combat, Inventory)
local composedEvents = assert(events, composeError and composeError.message)
local inspectResult = s.struct(
	s.field("owned" :: "owned", s.boolean()),
	(s.field("count" :: "count", s.u16(0, 65_535)))
)

local definition, definitionError = Relay.define({
	name = "CombatInventory",
	version = 1,
	events = composedEvents,
	requests = {
		Inspect = s.request(3, s.ordered(s.field("itemId", s.u16(1, 65_535))), inspectResult),
	},
})

return assert(definition, definitionError and definitionError.message)
