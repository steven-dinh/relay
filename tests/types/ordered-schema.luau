--!strict
local Relay = require("../../src/init")
local ordered = require("../../examples/reliable-events/ordered")

local definition, definitionError = Relay.define({
    name = "TypeConsumer",
    version = 1,
    events = {
        Input = {
            id = 1,
            direction = "ClientToServer" :: "ClientToServer",
            fields = ordered(
                { name = "sequence", type = "u8" :: "u8" },
                { name = "pressed", type = "boolean" :: "boolean" },
                { name = "label", type = "string" :: "string", maximumBytes = 16 },
                { name = "delta", type = "i16" :: "i16", minimum = -10 },
                { name = "ratio", type = "f32" :: "f32", minimum = -1, maximum = 1 },
                { name = "point2", type = "Vector2F32" :: "Vector2F32", minimum = -1, maximum = 1 },
                { name = "point3", type = "Vector3F32" :: "Vector3F32", minimum = -1, maximum = 1 },
                { name = "pose", type = "CFrame" :: "CFrame", minimum = -10, maximum = 10 }
            ),
        },
        State = {
            id = 2,
            direction = "ServerToClient" :: "ServerToClient",
            fields = ordered(
                { name = "a", type = "u16" :: "u16" },
                { name = "b", type = "u32" :: "u32" },
                { name = "c", type = "i8" :: "i8" },
                { name = "d", type = "i32" :: "i32" }
            ),
        },
        Empty = { id = 3, direction = "ServerToClient" :: "ServerToClient", fields = ordered() },
    },
})
assert(definition, definitionError and definitionError.message)
return definition
