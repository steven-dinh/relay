local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Relay = require("../src")
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
