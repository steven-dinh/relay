--!strict
-- Keep Lune's relative path out of Roblox's type resolver.
local s: typeof(require(script.Parent.Relay).schema) =
	if script then require(script.Parent.Relay).schema else (require :: any)("../../src/Schema")

return {
	name = "Gameplay",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields(
			{ sequence = s.u32() },
			{ enabled = s.boolean() }
		)),
		State = s.serverToClient(2, s.fields(
			{ sequence = s.u32() },
			{ health = s.u8(nil, 100) }
		)),
	},
}
