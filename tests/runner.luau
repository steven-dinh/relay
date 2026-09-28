local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Relay = require("../src")
local ordered = require("../examples/reliable-events/ordered")
local manifest = serde.decode("toml", fs.readFile("wally.toml"))
assert(type(Relay) == "table" and table.isfrozen(Relay))
assert(Relay.VERSION == "0.1.0" and Relay.VERSION == manifest.package.version)

local expected = { VERSION = "string", define = "function", createServer = "function", createClient = "function" }
local count = 0
for key, value in Relay do
    count += 1
    assert(expected[key] == type(value), "unexpected public surface")
end
assert(count == 4, "Relay must expose exactly four public keys")
assert(not pcall(function() Relay.VERSION = "changed" end), "public module must be frozen")

local token, problem = Relay.define({
    name = "PublicTest", version = 1,
    events = { Ping = { id = 1, direction = "ClientToServer", fields = {} } },
})
assert(token and problem == nil and table.isfrozen(token) and next(token) == nil and getmetatable(token) == nil)

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
