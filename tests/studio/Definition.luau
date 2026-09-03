-- Test fixtures are deliberately outside the publishable package.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)

local function create(version)
    local fields = {
        { name = "sequence", type = "u32" },
        { name = "enabled", type = "boolean" },
        { name = "small", type = "u8" },
        { name = "medium", type = "u16" },
        { name = "scalar", type = "f32", minimum = -1024, maximum = 1024 },
        { name = "position", type = "Vector3F32", minimum = -1024, maximum = 1024 },
    }
    return assert(Relay.define({
        name = "StudioProof",
        version = version or 1,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = fields },
            State = { id = 2, direction = "ServerToClient", fields = fields },
        },
    }))
end

local function values(sequence)
    return sequence, true, 255, 65535, 0.1, Vector3.new(0.1, -0.25, 1024)
end

local function check(sequence, enabled, small, medium, scalar, position, ...)
    assert(select("#", ...) == 0, "extra delivered fields")
    local bytes = buffer.create(4)
    buffer.writef32(bytes, 0, 0.1)
    assert(type(sequence) == "number" and sequence % 1 == 0, "sequence")
    assert(enabled == true and small == 255 and medium == 65535, "positional values")
    assert(scalar == buffer.readf32(bytes, 0), "f32 normalization")
    assert(position == Vector3.new(0.1, -0.25, 1024), "Vector3 normalization")
    return sequence
end

return table.freeze({ create = create, values = values, check = check })
