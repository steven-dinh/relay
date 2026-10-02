--!strict
local Relay = require("../../src/init")
local ordered = require("../../examples/reliable-events/ordered")

local primitiveAlias: Relay.FieldSpec = { name = "primitive", type = "u8" :: "u8" }
local nestedAlias: Relay.FieldSpec = {
    name = "record", type = "struct" :: "struct",
    fields = ordered({ name = "enabled" :: "enabled", type = "boolean" :: "boolean" }),
}
print(primitiveAlias, nestedAlias)

local input = ordered({
    name = "snapshot", type = "struct" :: "struct",
    fields = ordered(
        { name = "mode" :: "mode", type = "enum" :: "enum",
            values = ordered("Idle" :: "Idle", "Run" :: "Run") },
        { name = "modes" :: "modes", type = "set" :: "set", maximumSize = 8,
            element = { type = "enum" :: "enum", values = ordered("Idle" :: "Idle", "Run" :: "Run") } },
        { name = "singleMode" :: "singleMode", type = "set" :: "set", maximumSize = 1,
            element = { type = "enum" :: "enum", values = ordered("Only" :: "Only") } },
        { name = "scores" :: "scores", type = "array" :: "array",
            maximumLength = 16, element = { type = "u16" :: "u16" } },
        { name = "tags" :: "tags", type = "set" :: "set",
            maximumSize = 8, element = { type = "string" :: "string", maximumBytes = 24 } },
        { name = "target" :: "target", type = "optional" :: "optional",
            value = { type = "u32" :: "u32" } }
    ),
})
local deep = ordered({
    name = "deep", type = "array" :: "array", maximumLength = 1,
    element = {
        type = "array" :: "array", maximumLength = 1,
        element = {
            type = "array" :: "array", maximumLength = 1,
            element = {
                type = "array" :: "array", maximumLength = 1,
                element = { type = "boolean" :: "boolean" },
            },
        },
    },
})

local definition, definitionError = Relay.define({
    name = "ComposableTypes",
    version = 1,
    events = {
        Input = {
            id = 1,
            direction = "ClientToServer" :: "ClientToServer",
            fields = input,
        },
        State = {
            id = 2,
            direction = "ServerToClient" :: "ServerToClient",
            fields = input,
        },
        Deep = {
            id = 3,
            direction = "ClientToServer" :: "ClientToServer",
            fields = deep,
        },
        Optional = {
            id = 4,
            direction = "ClientToServer" :: "ClientToServer",
            fields = ordered({ name = "value", type = "optional" :: "optional",
                value = { type = "boolean" :: "boolean" } }),
        },
    },
})
assert(definition, definitionError and definitionError.message)

local server, serverError = Relay.createServer(definition, {
    inboundRate = {
        perPlayer = { capacity = 10, refillPerSecond = 1 },
        aggregate = { capacity = 100, refillPerSecond = 10 },
    },
})
assert(server, serverError and serverError.message)
local client, clientError = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
assert(client, clientError and clientError.message)
local player: Player = error("type-only fixture")

local inputConnection, inputError = server.events.Input:Connect(function(_, snapshot)
    local mode: "Idle" | "Run" = snapshot.mode
    local modes: { Idle: true?, Run: true? } = snapshot.modes
    local singleModes: { Only: true? } = snapshot.singleMode
    local scores: { number } = snapshot.scores
    local tags: { [string]: true } = snapshot.tags
    local target: number? = snapshot.target
    print(mode, modes, singleModes, scores, tags, target)
end)
assert(inputConnection, inputError and inputError.message)

local stateConnection, stateConnectError = client.events.State:Connect(function(snapshot)
    local mode: "Idle" | "Run" = snapshot.mode
    local scores: { number } = snapshot.scores
    local tags: { [string]: true } = snapshot.tags
    local target: number? = snapshot.target
    print(mode, scores, tags, target)
end)
assert(stateConnection, stateConnectError and stateConnectError.message)

local stateSent, stateError = server.events.State:Send(player, {
    mode = "Run",
    modes = { Idle = true },
    singleMode = { Only = true },
    scores = { 10, 20 },
    tags = { blue = true },
})
assert(stateSent, stateError and stateError.message)

local inputSent, inputSendError = client.events.Input:Send({
    mode = "Idle",
    modes = {},
    singleMode = {},
    scores = {},
    tags = {},
    target = 42,
})
assert(inputSent, inputSendError and inputSendError.message)
client.events.Deep:Send({{{{true}}}})
-- Generated nullable trailing parameters allow this statically; runtime requires explicit nil.
client.events.Optional:Send()
client.events.Optional:Send(nil)

server:Destroy()
client:Destroy()
