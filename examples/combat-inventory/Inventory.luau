--!strict

local s = require(game:GetService("ReplicatedStorage").Relay).schema

return table.freeze({
	InventoryUpdate = s.serverToClient(2, s.ordered(
		s.field("itemId", s.u16(1, 65_535)),
		(s.field("count", s.u16(0, 65_535)))
	)),
})
