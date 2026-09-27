--!strict
local Relay = require("../../src/init")

local definition, _ = Relay.define({
    name = "TypeConsumer",
    version = 1,
    events = { Empty = { id = 1, direction = "ClientToServer", fields = {} } },
})

if definition then
    Relay.createClient(definition, { startupTimeoutSeconds = "wrong" })
end

Relay.define({
    name = "MissingStringLimit",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = {
        { name = "label", type = "string" },
    } } },
})

Relay.define({
    name = "MissingFloatMaximum",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = {
        { name = "ratio", type = "f32", minimum = 0 },
    } } },
})

Relay.define({
    name = "MissingVectorMinimum",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = {
        { name = "point", type = "Vector3F32", maximum = 1 },
    } } },
})

Relay.define({
    name = "MissingCFrameMaximum",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = {
        { name = "pose", type = "CFrame", minimum = -1 },
    } } },
})
