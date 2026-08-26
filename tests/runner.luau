local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Relay = require("../src")
local manifest = serde.decode("toml", fs.readFile("wally.toml"))

assert(type(Relay) == "table", "Relay must return a table")
assert(table.isfrozen(Relay), "Relay export must be frozen")
assert(type(Relay.VERSION) == "string", "Relay.VERSION must be a string")
assert(Relay.VERSION == "0.1.0", "Relay foundation version must be 0.1.0")
assert(type(manifest) == "table", "wally.toml must decode to a table")
assert(type(manifest.package) == "table", "wally.toml must define [package]")
assert(Relay.VERSION == manifest.package.version, "Relay.VERSION must match wally.toml")

local publicKeyCount = 0

for key in Relay do
    publicKeyCount += 1
    assert(key == "VERSION", `unexpected public key: {tostring(key)}`)
end

assert(publicKeyCount == 1, "Relay must expose exactly one public key")

local mutationSucceeded = pcall(function()
    Relay.VERSION = "changed"
end)

assert(not mutationSucceeded, "Relay export must reject mutation")

print("PASS Relay.Foundation.Module")
