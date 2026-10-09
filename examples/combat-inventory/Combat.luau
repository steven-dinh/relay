--!strict

local s = require(game:GetService("ReplicatedStorage").Relay).schema

return table.freeze({
	Attack = s.clientToServer(1, s.ordered(
		s.field("sequence", s.u16(0, 65_535)),
		(s.field("targetId", s.u16(1, 65_535)))
	)),
})
