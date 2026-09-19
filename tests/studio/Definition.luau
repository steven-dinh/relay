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
        local expectedOk, x, y, z = validateScalar(value.X, value.Y, value.Z)
        local actualOk, actual = validateVector(value)
        assert(expectedOk == actualOk, "Vector3 rejection parity")
        if expectedOk then
            local expected = { x, y, z }
            for index, axis in { "X", "Y", "Z" } do
                assert(actual[axis] == expected[index], "Vector3 Float32 parity")
                if expected[index] == 0 then
                    assert(1 / actual[axis] == math.huge, "Vector3 positive-zero normalization")
                end
            end
        end
    end
    local bounded = { fields = { { type = "Vector3F32", minimum = -1, maximum = 1 } } }
    local validateBounded = Frame.compile(bounded)
    assert(validateBounded(Vector3.new(-1, 1, 0)) ~= nil, "Vector3 inclusive bounds")
    assert(validateBounded(Vector3.new(0, 2, 0)) == nil, "Vector3 out-of-range rejection")
end

-- Prove native Vector2 precision and normalization independently in both runtimes.
do
    local Frame = require(ReplicatedStorage.Relay.internal.Frame)
    local bytes = buffer.create(4)
    buffer.writef32(bytes, 0, 0.1)
    assert(Vector2.new(0.1, 0).X == buffer.readf32(bytes, 0), "Vector2 Float32 storage")
    assert(Vector2.new(16777217, 0).X == 16777216, "Vector2 Float32 integer precision")
    local maximum = (2 - 2 ^ -23) * 2 ^ 127
    local field = { type = "f32", minimum = -maximum, maximum = maximum }
    local scalar = Frame.compile({ fields = { field, field } })
    local vector = Frame.compile({ fields = { { type = "Vector2F32", minimum = -maximum, maximum = maximum } } })
    for _, value in { Vector2.new(-1 / math.huge, 0), Vector2.new(0, -1 / math.huge),
        Vector2.new(2 ^ -149, -(2 ^ -149)), Vector2.new(maximum, -maximum), Vector2.new(0.1, -0.1),
        Vector2.new(0 / 0, 0), Vector2.new(0, math.huge), Vector2.new(-math.huge, 0) } do
        local expectedOk, x, y = scalar(value.X, value.Y)
        local actualOk, actual = vector(value)
        assert(actualOk == expectedOk, "Vector2 scalar rejection parity")
        if expectedOk then
            assert(actual.X == x and actual.Y == y, "Vector2 scalar normalization parity")
            if x == 0 then assert(1 / actual.X == math.huge, "Vector2 positive X zero") end
            if y == 0 then assert(1 / actual.Y == math.huge, "Vector2 positive Y zero") end
        end
    end
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
    local schemaFields = {
        { name = "upper", type = "boolean" },
        { name = "small", type = "i8" },
        { name = "medium", type = "i16" },
        { name = "large", type = "i32" },
        { name = "direction", type = "Vector2F32", minimum = -1, maximum = 1 },
    }
    return assert(Relay.define({
        name = "StudioProof",
        version = version or 1,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = fields },
            State = { id = 2, direction = "ServerToClient", fields = fields },
            SchemaInput = { id = 3, direction = "ClientToServer", fields = schemaFields },
            SchemaState = { id = 4, direction = "ServerToClient", fields = schemaFields },
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

local function schemaValues(upper)
    if upper then return true, 127, 32_767, 2_147_483_647, Vector2.new(0.1, 1) end
    return false, -128, -32_768, -2_147_483_648, Vector2.new(-1, -1 / math.huge)
end

local function checkSchema(...)
    assert(select("#", ...) == 5, "schema delivered arity")
    local upper, small, medium, large, direction = ...
    assert(type(upper) == "boolean", "signed tuple marker")
    local _, expectedSmall, expectedMedium, expectedLarge, expectedDirection = schemaValues(upper)
    assert(small == expectedSmall and medium == expectedMedium and large == expectedLarge, "signed native extrema")
    assert(typeof(direction) == "Vector2" and direction == expectedDirection, "Vector2 native delivery")
    if not upper then assert(1 / direction.Y == math.huge, "Vector2 delivered positive zero") end
    return upper
end

return table.freeze({ create = create, values = values, check = check,
    schemaValues = schemaValues, checkSchema = checkSchema })
