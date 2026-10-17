--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local scalar = s.quantized(0, 1, 0.1)
local definition = Relay.define({ name = "QuantizedInvalid", version = 1, events = {
	Input = s.clientToServer(1, s.ordered(s.field("value", scalar))),
} })
local token = assert(definition, "quantized definition")
local clientValue, _issue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, "quantized client")
client.events.Input:Send("not a number")

local wrongConstructor = s.quantized(0, 1, "0.1")
local wrongConfigType = Relay.define({ name = "QuantizedWrongConfigType", version = 1, events = {
	Input = s.clientToServer(2, s.ordered({ name = "value", type = "quantized" :: "quantized",
		minimum = 0, maximum = 1, step = true })),
} })
local missingStep = Relay.define({ name = "QuantizedMissingStep", version = 1, events = {
	Input = s.clientToServer(3, s.ordered({ name = "value", type = "quantized" :: "quantized",
		minimum = 0, maximum = 1 })),
} })
local unknownKey = Relay.define({ name = "QuantizedUnknownKey", version = 1, events = {
	Input = s.clientToServer(4, s.ordered({ name = "value", type = "quantized" :: "quantized",
		minimum = 0, maximum = 1, step = 0.1, extra = true })),
} })
local setElement = Relay.define({ name = "QuantizedSetElement", version = 1, events = {
	Input = s.clientToServer(5, s.ordered(s.field("values", s.set(scalar, 4)))),
} })
local mapKey = Relay.define({ name = "QuantizedMapKey", version = 1, events = {
	Input = s.clientToServer(6, s.ordered(s.field("values", s.map(scalar, s.boolean(), 4)))),
} })
print(wrongConstructor, wrongConfigType, missingStep, unknownKey, setElement, mapKey)
