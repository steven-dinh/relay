-- Test fixtures are deliberately outside the publishable package.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)

-- Check native Vector3 storage and compare its validator with scalar Float32
-- normalization in both Studio runtimes before exercising the transport.
do
    local Frame = require(ReplicatedStorage.Relay.internal.Frame)
    local bytes = buffer.create(4)
    buffer.writef32(bytes, 0, 0.1)
    assert(Vector3.new(0.1, 0, 0).X == buffer.readf32(bytes, 0), "Vector3 Float32 storage")
    assert(Vector3.new(16777217, 0, 0).X == 16777216, "Vector3 Float32 integer precision")
    local maximum = (2 - 2 ^ -23) * 2 ^ 127
    local scalarField = { type = "f32", minimum = -maximum, maximum = maximum }
    local scalarEvent = { fields = { scalarField, scalarField, scalarField } }
    local vectorEvent = { fields = { { type = "Vector3F32", minimum = -maximum, maximum = maximum } } }
    local validateScalar = Frame.compile(scalarEvent)
    local validateVector = Frame.compile(vectorEvent)
    for _, value in {
        Vector3.new(-1 / math.huge, 0, -1 / math.huge),
        Vector3.new(0, -1 / math.huge, 0),
        Vector3.new(2 ^ -149, -(2 ^ -149), 2 ^ -126),
        Vector3.new(maximum, -maximum, 0.1),
        Vector3.new(0 / 0, 0, 0),
        Vector3.new(0, math.huge, 0),
        Vector3.new(0, 0, -math.huge),
        Vector3.new(3.5e38, 0, 0),
    } do
        local expected = validateScalar(value.X, value.Y, value.Z)
        local actual = validateVector(value)
        assert((expected == nil) == (actual == nil), "Vector3 rejection parity")
        if expected then
            for index, axis in { "X", "Y", "Z" } do
                assert(actual[1][axis] == expected[index], "Vector3 Float32 parity")
                if expected[index] == 0 then
                    assert(1 / actual[1][axis] == math.huge, "Vector3 positive-zero normalization")
                end
            end
        end
    end
    local bounded = { fields = { { type = "Vector3F32", minimum = -1, maximum = 1 } } }
    local validateBounded = Frame.compile(bounded)
    assert(validateBounded(Vector3.new(-1, 1, 0)) ~= nil, "Vector3 inclusive bounds")
    assert(validateBounded(Vector3.new(0, 2, 0)) == nil, "Vector3 out-of-range rejection")
end

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
