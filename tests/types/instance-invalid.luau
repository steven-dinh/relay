--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local part = s.Instance("Part")
local basePart = s.Instance("BasePart")
local instance = s.Instance("Folder")
local fields = s.ordered(s.field("value", part))
local partValue: Part = error("type-only fixture")
local folderValue: Folder = error("type-only fixture")
local wideClassName: string = "Part"
local widened = s.Instance(wideClassName)
local invalidClass = s.Instance("NoSuchClass")

local wrongInstance = Relay.define({ name = "WrongInstance", version = 1, events = {
    Input = s.clientToServer(1, fields),
} })
local wrongPayload, wrongPayloadIssue = Relay.define({ name = "WrongPayload", version = 1, events = {
    Input = s.clientToServer(2, s.ordered(s.field("value", basePart))),
} })
local token = assert(wrongPayload, wrongPayloadIssue and wrongPayloadIssue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
client.events.Input:Send(folderValue)
client.events.Input:Send(partValue)

local widenedDefinition = Relay.define({ name = "WidenedClass", version = 1, events = {
    Input = s.clientToServer(3, s.ordered(s.field("value", widened))),
} })
local unknownClassDefinition = Relay.define({ name = "UnknownClass", version = 1, events = {
    Input = s.clientToServer(4, s.ordered(s.field("value", invalidClass))),
} })
local queued = Relay.define({ name = "QueuedInstance", version = 1, events = {
    Input = { id = 5, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch", fields = fields },
} })
local unreliable = Relay.define({ name = "UnreliableInstance", version = 1, events = {
    Input = s.clientToServer(6, fields, "Unreliable"),
} })
local ordered = Relay.define({ name = "OrderedInstance", version = 1, events = {
    Input = s.clientToServer(7, fields, "OrderedUnreliable"),
} })
local requestRef = Relay.define({ name = "RequestInstance", version = 1, events = {}, requests = {
    Lookup = s.request(8, fields, s.boolean()),
} })
local responseRef = Relay.define({ name = "ResponseInstance", version = 1, events = {}, requests = {
    Lookup = s.request(9, s.ordered(s.field("id", s.u8())), instance),
} })
local mapKey = Relay.define({ name = "InstanceMapKey", version = 1, events = {
    Input = s.clientToServer(10, s.ordered(s.field("value", s.map(s.Instance("Part"), s.boolean(), 2)))),
} })
local setKey = Relay.define({ name = "InstanceSetKey", version = 1, events = {
    Input = s.clientToServer(11, s.ordered(s.field("value", s.set(s.Instance("Part"), 2)))),
} })
print(wrongInstance, widenedDefinition, unknownClassDefinition, queued, unreliable, ordered, requestRef, responseRef, mapKey, setKey)
