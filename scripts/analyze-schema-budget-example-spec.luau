local s = require("../src/Schema")

return {
	name = "CombatAndInventory",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ buttons = s.u16() }, { axes = s.array(s.i8(), 4) }),
			{ queue = "Batch" }),
		NearbyState = s.serverToClient(2, s.fields({ entity = s.u16() }, { health = s.u8() }),
			{ delivery = "OrderedUnreliable" }),
		InventoryDelta = s.serverToClient(3, s.fields({ item = s.u16() }, { count = s.u8() }),
			{ queue = "State" }),
	},
	requests = {
		InspectItem = s.request(4, s.fields({ item = s.u16() }), s.struct({ owned = s.boolean() }, { count = s.u8() })),
	},
}
