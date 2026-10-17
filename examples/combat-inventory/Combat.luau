--!strict

local s = require(game:GetService("ReplicatedStorage").Relay).schema

return table.freeze({
	Attack = s.clientToServer(1, s.fields(
		{ sequence = s.u16(0, 65_535) },
		{ targetId = s.u16(1, 65_535) }
	)),
})
