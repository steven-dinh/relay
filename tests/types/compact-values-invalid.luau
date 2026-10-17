--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local wrongVectorStep = s.quantizedVector3(0, 10, "0.1")
local wrongVectorType = Relay.define({ name = "WrongVectorType", version = 1, events = {
	Input = s.clientToServer(1, s.ordered({ name = "value", type = "quantizedVector3" :: "quantizedVector3",
		minimum = 0, maximum = 10, step = true })),
} })
local missingVectorStep = Relay.define({ name = "MissingVectorStep", version = 1, events = {
	Input = s.clientToServer(2, s.ordered({ name = "value", type = "quantizedVector2" :: "quantizedVector2",
		minimum = 0, maximum = 10 })),
} })
local unknownVectorKey = Relay.define({ name = "UnknownVectorKey", version = 1, events = {
	Input = s.clientToServer(3, s.ordered({ name = "value", type = "quantizedVector3" :: "quantizedVector3",
		minimum = 0, maximum = 10, step = 1, extra = true })),
} })
local wrongCFrameStep = Relay.define({ name = "WrongCompactCFrameStep", version = 1, events = {
	Input = s.clientToServer(4, s.ordered({ name = "value", type = "compactCFrame" :: "compactCFrame",
		minimum = 0, maximum = 10, positionStep = true })),
} })
local wrongPayload = Relay.define({ name = "WrongCompactValuePayload", version = 1, events = {
	Vector3Input = s.clientToServer(5, s.ordered(s.field("value", s.quantizedVector3(0, 10, 1)))),
	Vector2Input = s.clientToServer(6, s.ordered(s.field("value", s.quantizedVector2(0, 10, 1)))),
	CFrameInput = s.clientToServer(7, s.ordered(s.field("value", s.compactCFrame(0, 10, 1)))),
} })
local token = assert(wrongPayload, "type-only invalid payload fixture")
local clientValue, _issue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, "type-only client")
client.events.Vector3Input:Send("not a Vector3")
client.events.Vector2Input:Send("not a Vector2")
client.events.CFrameInput:Send(Vector3.zero)

local setElement = Relay.define({ name = "CompactVectorSetKey", version = 1, events = {
	Input = s.clientToServer(8, s.ordered(s.field("values", s.set(s.quantizedVector3(0, 10, 1), 4)))),
} })
local mapKey = Relay.define({ name = "CompactFrameMapKey", version = 1, events = {
	Input = s.clientToServer(9, s.ordered(s.field("values", s.map(s.compactCFrame(0, 10, 1), s.boolean(), 4)))),
} })
print(wrongVectorStep, wrongVectorType, missingVectorStep, unknownVectorKey, wrongCFrameStep, setElement, mapKey)
