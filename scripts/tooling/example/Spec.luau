local s = if script then require(script.Parent.Relay.Schema) else require("@relay/schema")

return {
	name = "RelayToolsWalkthrough",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields({ value = s.u8() }), "Unreliable"),
	},
}
