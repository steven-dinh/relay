--!strict
local Relay = require(script.Parent.Relay)
local s = Relay.schema

local definition, problem = Relay.define({
	name = "SessionDrainExample",
	version = 1,
	events = {
		Work = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
	},
})
return assert(definition, problem and problem.message)
