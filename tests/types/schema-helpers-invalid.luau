--!strict
local Relay = require("../../src/init")
local Snapshot = require("./schema-helpers-shapes")
local s = Relay.schema

local widenedName = Relay.define({ name = "WidenedName", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("record", s.struct(s.field("score", s.u16()))))),
} })
local widenedEnum = Relay.define({ name = "WidenedEnum", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("mode", s.enum("Idle", "Run")))),
} })
local badName = Relay.define({ name = "BadName", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field(42, s.u8()))),
} })
local badKind = Relay.define({ name = "BadKind", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", { type = "i64" :: "i64" }))),
} })
local badChild = Relay.define({ name = "BadChild", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.array(42, 4)))),
} })
local namedChild = Relay.define({ name = "NamedChild", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.array(s.field("nested", s.u8()), 4)))),
} })
local optionalArray = Relay.define({ name = "OptionalArray", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.array(s.optional(s.u8()), 4)))),
} })
local badSet = Relay.define({ name = "BadSet", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.set(s.f32(-1, 1), 4)))),
} })
local excessiveDepth = Relay.define({ name = "Deep", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.array(s.array(s.array(s.array(s.array(s.boolean(), 1), 1), 1), 1), 1)))),
} })
local conflictingKind: { type: "u8", name: string } & { type: "boolean" } = error("type-only fixture")
local badIntersectionKind = Relay.define({ name = "ConflictKind", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(conflictingKind)),
} })
local conflictingName: { type: "u8", name: "first" } & { name: "second" } = error("type-only fixture")
local badIntersectionName = Relay.define({ name = "ConflictName", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(conflictingName)),
} })
local nonTable: { type: "u8", name: string } & (() -> ()) = error("type-only fixture")
local badIntersectionPart = Relay.define({ name = "NonTable", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(nonTable)),
} })
s.string("wide")
s.u16(false)
s.clientToServer(1, s.ordered(), "Slow")
print(widenedName, widenedEnum, badName, badKind, badChild, namedChild, optionalArray, badSet,
    excessiveDepth, badIntersectionKind, badIntersectionName, badIntersectionPart)

local fields = s.ordered(s.field("snapshot", Snapshot), (s.field("count", s.u16())))
local definition = Relay.define({ name = "Payloads", version = 1, events = {
    Input = s.clientToServer(1, fields), State = s.serverToClient(2, fields), Empty = s.serverToClient(3, s.ordered()),
} })
assert(definition)
local server = Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 10, refillPerSecond = 1 }, aggregate = { capacity = 100, refillPerSecond = 10 },
} })
assert(server)
local client = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
assert(client)
client.events.Unknown:Send()
server.events.Input:Send()
client.events.State:Send()
client.events.Input:Connect(function() end)
client.events.Input:Send({ mode = "Other", modes = {}, singleMode = {}, scores = {}, tags = {} }, 1)
client.events.Input:Send({ mode = "Idle", modes = {}, singleMode = {}, scores = { "bad" }, tags = {} }, 1)
client.events.Input:Send({ mode = "Idle", modes = { Idle = false }, singleMode = {}, scores = {}, tags = {} }, 1)
client.events.Input:Send({ mode = "Idle", modes = {}, singleMode = {}, scores = {}, tags = {}, target = "bad" }, 1)
client.events.Input:Send({ mode = "Idle", modes = {}, singleMode = {}, scores = {}, tags = {} }, false)
client.events.Input:Send({ mode = "Idle", modes = {}, singleMode = {}, scores = {}, tags = {} }, 1, 2)
server.events.Empty:Broadcast(true)
server.events.Input:Connect(function(_: Player, _: string, _: number) end)
server.events.Input:Connect(function(_, snapshot)
    print(snapshot.unknown)
end)
Relay.createClient(definition, { startupTimeoutSeconds = "late" })
Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = "many", refillPerSecond = 1 }, aggregate = { capacity = 100, refillPerSecond = 10 },
} })
