local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Relay = require("../src")
local Definition = require("../src/Definition")
local ordered = require("../examples/reliable-events/ordered")
local manifest = serde.decode("toml", fs.readFile("wally.toml"))
assert(type(Relay) == "table" and table.isfrozen(Relay))
assert(Relay.VERSION == "0.1.0" and Relay.VERSION == manifest.package.version)

local expected = { VERSION = "string", define = "function", createServer = "function", createClient = "function", schema = "table", inspect = "function" }
local count = 0
for key, value in Relay do
    count += 1
    assert(expected[key] == type(value), "unexpected public surface")
end
assert(count == 6, "Relay must expose exactly six public keys")
assert(not pcall(function() Relay.VERSION = "changed" end), "public module must be frozen")

local token, problem = Relay.define({
    name = "PublicTest", version = 1,
    events = { Ping = { id = 1, direction = "ClientToServer", fields = {} } },
})
assert(token and problem == nil and table.isfrozen(token) and next(token) == nil and getmetatable(token) == nil)
local publicReport, inspectError = Relay.inspect(token)
assert(publicReport and inspectError == nil and publicReport.name == "PublicTest" and table.isfrozen(publicReport))
local forgedReport, forgedError = Relay.inspect({})
assert(forgedReport == nil and forgedError.code == "InvalidDefinition")

local sourceField = { name = "sequence", type = "u8" }
local fields = ordered(sourceField, { name = "pressed", type = "boolean" })
assert(#fields == 2 and fields[1] ~= sourceField and fields[1].type == "u8")
assert(table.isfrozen(fields) and table.isfrozen(fields[1]) and table.isfrozen(fields[2]))
sourceField.type = "boolean"
assert(fields[1].type == "u8", "caller mutation must not change ordered field metadata")
assert(not pcall(function() fields[1] = { name = "sequence", type = "boolean" } end))
assert(not pcall(function() fields[1].type = "boolean" end))
assert(#ordered() == 0)
local orderedToken, orderedError = Relay.define({
    name = "OrderedPublicTest", version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = fields } },
})
assert(orderedToken and orderedError == nil and table.isfrozen(orderedToken))
local invalidOrdered, invalidOrderedError = Relay.define({
    name = "InvalidOrderedTest", version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = ordered(42) } },
})
assert(invalidOrdered == nil and invalidOrderedError.code == "InvalidDefinition")

local s = Relay.schema
assert(table.isfrozen(s), "schema helpers must be frozen")
local helperNames = {
    "ordered", "compose", "field", "boolean", "string", "u8", "u16", "u32", "i8", "i16", "i32", "f32",
    "Vector2F32", "Vector3F32", "CFrame", "struct", "enum", "array", "set", "optional",
    "clientToServer", "serverToClient", "request",
}
local helperCount = 0
for key, value in s do
    helperCount += 1
    assert(table.find(helperNames, key) and type(value) == "function", "unexpected schema helper")
end
assert(helperCount == #helperNames)
assert(not pcall(function() s.field = nil end))
for _, shape in {
    s.boolean(), s.string(16), s.u8(), s.u16(1, 20), s.u32(), s.i8(), s.i16(), s.i32(), s.f32(-1, 1),
    s.Vector2F32(-1, 1), s.Vector3F32(-1, 1), s.CFrame(-1, 1),
    s.struct(s.field("enabled", s.boolean())), s.enum("Idle", "Run"),
    s.array(s.u8(), 4), s.set(s.u8(), 4), s.optional(s.u8()),
} do
    assert(table.isfrozen(shape), "helper shape records must be frozen")
end
local anonymous = s.array(s.u16(), 4)
local bound = s.field("scores", anonymous)
assert(bound ~= anonymous and bound.element == anonymous.element and anonymous.name == nil)
assert(bound.name == "scores" and table.isfrozen(bound))
assert(not pcall(function() s.field("other", bound) end), "field must reject already-named shapes")
assert(not pcall(function() bound.name = "other" end))
local raw = { type = "u8" }
local boundRaw = s.field("value", raw)
raw.type = "boolean"
assert(boundRaw.type == "u8" and raw.name == nil, "field must isolate immediate caller mutation")
local rawChild = { type = "u8" }
assert(s.array(rawChild, 4).element == rawChild and not table.isfrozen(rawChild),
    "builders must not traverse or freeze caller-owned nested tables")
local helperFields = s.ordered(sourceField, bound)
assert(helperFields[1] ~= sourceField and table.isfrozen(helperFields) and table.isfrozen(helperFields[1]))
sourceField.type = "string"
assert(helperFields[1].type == "boolean", "schema ordered must retain caller mutation isolation")
assert(#s.ordered() == 0)
local c2s = s.clientToServer(1, s.ordered())
local s2c = s.serverToClient(2, s.ordered(), "Unreliable")
assert(table.isfrozen(c2s) and table.isfrozen(s2c))
assert(c2s.direction == "ClientToServer" and c2s.delivery == nil)
assert(s2c.direction == "ServerToClient" and s2c.delivery == "Unreliable")

local function descriptor(event)
    local definition, issue = Relay.define({ name = "Helpers", version = 1, events = { Input = event } })
    assert(definition, issue and issue.message)
    return Definition.get(definition).descriptor
end
for _, delivery in { "Reliable", "Unreliable" } do
    assert(descriptor(s.clientToServer(1, s.ordered(s.field("score", s.u16())), delivery))
        == descriptor({ id = 1, direction = "ClientToServer", delivery = delivery,
            fields = { { name = "score", type = "u16" } } }), "helpers must preserve RR1/RR2 descriptor bytes")
end
local snapshot = s.struct(
    s.field("mode", s.enum("Run", "Idle")), s.field("scores", s.array(s.u16(), 4)),
    s.field("tags", s.set(s.string(8), 4)), s.field("target", s.optional(s.u32()))
)
local reusedFields = s.ordered(s.field("first", snapshot), s.field("second", snapshot))
local reusedToken, reusedProblem = Relay.define({ name = "Reuse", version = 1, events = {
    Input = s.clientToServer(1, reusedFields),
} })
assert(reusedToken, reusedProblem and reusedProblem.message)
local compiled = Definition.get(reusedToken)
assert(compiled.events.Input.fields[1].fields[1] ~= compiled.events.Input.fields[2].fields[1],
    "reused authoring shapes must compile independently")
local inlineSnapshot = {
    name = "snapshot", type = "struct", fields = {
        { name = "mode", type = "enum", values = { "Run", "Idle" } },
        { name = "scores", type = "array", maximumLength = 4, element = { type = "u16" } },
        { name = "tags", type = "set", maximumSize = 4, element = { type = "string", maximumBytes = 8 } },
        { name = "target", type = "optional", value = { type = "u32" } },
    },
}
assert(snapshot.name == nil and descriptor(s.clientToServer(1, s.ordered(s.field("snapshot", snapshot))))
    == descriptor({ id = 1, direction = "ClientToServer", fields = { inlineSnapshot } }),
    "helpers must preserve RR3 descriptor bytes and enum order")
local malformedHelperToken, malformedHelperError = Relay.define({ name = "InvalidHelper", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.array(s.optional(s.u8()), 4)))),
} })
assert(malformedHelperToken == nil and malformedHelperError.code == "InvalidDefinition",
    "define remains authoritative for helper-built schemas")

local invalid, failure = Relay.define({})
assert(invalid == nil and failure.code == "InvalidDefinition" and table.isfrozen(failure))
assert(type(failure.message) == "string")
local errorKeys = 0
for key in failure do
    errorKeys += 1
    assert(key == "code" or key == "message")
end
assert(errorKeys == 2)

-- Importing the public package is service/Instance-free in a plain Luau runtime.
-- Expected calls on the wrong runtime side reject before definition/options.
for _, create in { Relay.createServer, Relay.createClient } do
    local object, issue = create({}, {})
    assert(object == nil and issue.code == "WrongRuntimeSide" and table.isfrozen(issue))
end

print("PASS Relay.Public.Module")
