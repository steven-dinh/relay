local s = require(if script then script.Parent.Relay.Schema else "../../../../src/Schema")
local native = if script then { Enum = Enum, BrickColor = BrickColor } else require("@lune/roblox")
local material = s.robloxEnum(native.Enum.Material.Plastic, native.Enum.Material.Wood)
local choice = s.taggedUnion("kind", {
	Point = s.struct({ position = s.Vector3F32(-100, 100) }),
	Text = s.struct({ text = s.string(32) }),
})
local payload = s.struct(
	{ label = s.optional(s.string(32)) },
	{ items = s.array(s.u16(), 4) },
	{ scores = s.map(s.string(16), s.u8(), 4) },
	{ flags = s.set(s.enum({ Active = 1, Hidden = 2 }), 2) },
	{ choice = choice }
)

return {
	name = "RobloxTSExample", version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ sequence = s.u16() }, { payload = payload })),
		Output = s.serverToClient(2, s.fields({ message = s.string(32) }, { accepted = s.boolean() })),
		Timed = s.clientToServer(3, s.fields({ serverTime = s.f64(0, 1099511627776) }, { value = s.u8() }),
			{ timestampWindow = 1 }),
		Native1 = s.clientToServer(4, s.fields(
			{ udim = s.UDim(-2, 2, -100, 100) }, { udim2 = s.UDim2(-2, 2, -100, 100) },
			{ range = s.NumberRange(-10, 10) }, { rect = s.Rect(-10, 10) },
			{ brick = s.BrickColor(native.BrickColor.new("Really red")) }, { v2 = s.Vector2int16() },
			{ v3 = s.Vector3int16() }, { sequence = s.NumberSequence(4, 0, 10, 2) }
		)),
		Native2 = s.clientToServer(5, s.fields(
			{ colors = s.ColorSequence(4) }, { key = s.NumberSequenceKeypoint(0, 10, 2) },
			{ colorKey = s.ColorSequenceKeypoint() }, { tween = s.TweenInfo(10, 10, 3, true) },
			{ date = s.DateTime(0, 2000000000000) }, { ray = s.Ray(-10, 10, 10) },
			{ axes = s.Axes() }, { faces = s.Faces() }
		)),
		Native3 = s.clientToServer(6, s.fields(
			{ region = s.Region3(-10, 10) }, { region16 = s.Region3int16() },
			{ properties = s.PhysicalProperties() }, { font = s.Font("rbxasset://fonts/families/SourceSansPro.json") },
			{ waypoint = s.PathWaypoint(-10, 10, 16) }, { material = material },
			{ color = s.Color3RGB8() }, { part = s.Instance("BasePart") }
		)),
		Formats = s.clientToServer(7, s.fields(
			{ bytes = s.buffer(16) }, { scalar = s.quantized(0, 1, 0.25) },
			{ v2 = s.quantizedVector2(-1, 1, 0.25) }, { v3 = s.quantizedVector3(-1, 1, 0.25) },
			{ pose = s.compactCFrame(-1, 1, 0.25) }, { color = s.Color3() },
			{ optional = s.optional(s.u8()) }, { after = s.boolean() }
		)),
		["default"] = s.serverToClient(8, s.fields({ escaped = s.enum("quote\"", "line\n", "nul\0", "slash\\") })),
		Empty = s.serverToClient(9, s.fields()),
	},
	requests = {
		Lookup = s.request(10, s.fields({ id = s.u32() }), s.struct(
			{ owned = s.boolean() }, { material = material }, { note = s.optional(s.string(32)) }
		)),
		Confirm = s.request(11, s.fields({ choice = choice }), s.boolean(), { direction = "ServerToClient" }),
	},
}
