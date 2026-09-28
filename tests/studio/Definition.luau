-- Test fixtures are deliberately outside the publishable package.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local ordered = require(ReplicatedStorage.RelayProofOrdered)

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

local Frame = require(ReplicatedStorage.Relay.internal.Frame)
local validatePose = Frame.compile({ fields = { { type = "CFrame", minimum = -1024, maximum = 1024 } } })
local determinantInside = (1 + 0.9e-4) ^ (1 / 3)
local determinantOutside = (1 + 1.1e-4) ^ (1 / 3)
local inverseScale = 1 + 0.9e-4
local poseCases = {
    { name = "identity-zero", value = CFrame.new(-1 / math.huge, 0, 0, 1, -1 / math.huge, 0, 0, 1, 0, 0, 0, 1), accepted = true },
    { name = "general", value = CFrame.new(1, -2, 3) * CFrame.Angles(0.3, -0.7, 1.1), accepted = true },
    { name = "translation-boundary", value = CFrame.new(-1024, 1024, 0) * CFrame.Angles(0, math.pi / 2, 0), accepted = true },
    { name = "norm-inside", value = CFrame.new(0, 0, 0, math.sqrt(1 + 0.9e-4), 0, 0, 0, 1, 0, 0, 0, 1), accepted = true },
    { name = "norm-outside", value = CFrame.new(0, 0, 0, math.sqrt(1 + 1.1e-4), 0, 0, 0, 1, 0, 0, 0, 1), accepted = false },
    { name = "shear-inside", value = CFrame.new(0, 0, 0, 1, 0.9e-4, 0, 0, 1, 0, 0, 0, 1), accepted = true },
    { name = "shear-outside", value = CFrame.new(0, 0, 0, 1, 1.1e-4, 0, 0, 1, 0, 0, 0, 1), accepted = false },
    { name = "inverse-scale", value = CFrame.new(0, 0, 0, inverseScale, 0, 0, 0, 1 / inverseScale, 0, 0, 0, 1), accepted = false },
    { name = "determinant-inside", value = CFrame.new(0, 0, 0, determinantInside, 0, 0, 0, determinantInside, 0, 0, 0, determinantInside), accepted = true },
    { name = "determinant-outside", value = CFrame.new(0, 0, 0, determinantOutside, 0, 0, 0, determinantOutside, 0, 0, 0, determinantOutside), accepted = false },
    { name = "translation-outside", value = CFrame.new(1025, 0, 0), accepted = false },
}

-- Test-only diagnostics retain the actual stored matrix, not constructor inputs.
local function observePose(value)
    local components = { value:GetComponents() }
    local _, _, _, a, b, c, d, e, f, g, h, i = value:GetComponents()
    local valid, normalized = validatePose(value)
    local preserved = true
    local zeroSigns = table.create(12, 0)
    for index, component in components do
        if component == 0 then zeroSigns[index] = if 1 / component == -math.huge then -1 else 1 end
    end
    if valid then
        local after = { normalized:GetComponents() }
        for index, before in components do
            if after[index] ~= before or (before == 0 and 1 / after[index] ~= 1 / before) then preserved = false end
        end
    end
    return {
        components = components, zeroSigns = zeroSigns, valid = valid == true, localPreserved = preserved,
        residuals = { math.abs(a*a+d*d+g*g-1), math.abs(b*b+e*e+h*h-1), math.abs(c*c+f*f+i*i-1),
            math.abs(a*b+d*e+g*h), math.abs(a*c+d*f+g*i), math.abs(b*c+e*f+h*i),
            math.abs(a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)-1) },
    }
end

-- Nonfinite inputs stay local so diagnostics remain valid JSON.
do
    for index = 1, 12 do
        for _, invalid in { 0 / 0, math.huge, -math.huge } do
            local components = { CFrame.new():GetComponents() }
            components[index] = invalid
            assert(validatePose(CFrame.new(table.unpack(components))) == nil, "native CFrame nonfinite component")
        end
    end
    for _, value in {
        CFrame.new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        CFrame.new(0, 0, 0, -1, 0, 0, 0, 1, 0, 0, 0, 1),
        CFrame.new(0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1),
    } do assert(validatePose(value) == nil, "native CFrame degenerate/reflection/scale") end
end

local function poseSources()
    local sources = {}
    for index, case in poseCases do
        sources[index] = observePose(case.value)
        sources[index].name = case.name
        sources[index].expected = case.accepted
    end
    return sources
end

local function receivePose(index, value)
    assert(type(index) == "number" and poseCases[index] ~= nil and typeof(value) == "CFrame", "bounded pose probe")
    local result = observePose(value)
    result.caseId = index
    local original = { poseCases[index].value:GetComponents() }
    local translationDelta, rotationDelta = 0, 0
    for component, actual in result.components do
        local delta = math.abs(actual - original[component])
        if component <= 3 then translationDelta = math.max(translationDelta, delta)
        else rotationDelta = math.max(rotationDelta, delta) end
    end
    result.translationDelta, result.rotationDelta = translationDelta, rotationDelta
    return result
end

local function poseRecord()
    return { raw = {}, delivered = table.create(#poseCases, false), deliveryValues = table.create(#poseCases, false),
        rawState = { count = 0, last = 0 }, deliveryState = { count = 0, last = 0 } }
end

-- Native signal/Relay handler errors are not propagated to the coordinator.
-- Latch failures and retain at most one observation per declared case instead.
local function recordPose(record, direction, index, ...)
    local state = if direction == "raw" then record.rawState else record.deliveryState
    if state.failure then return end
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #poseCases
        or index <= state.last or state.count >= #poseCases or select("#", ...) ~= 1 then
        state.failure = "CFrame probe identity/order/arity"
        return
    end
    local value = ...
    if typeof(value) ~= "CFrame" then state.failure = "CFrame probe native type" return end
    local ok, observation = pcall(receivePose, index, value)
    if not ok then state.failure = "CFrame probe observation failed" return end
    state.count += 1
    state.last = index
    if direction == "raw" then record.raw[index] = observation
    else
        record.delivered[index] = true
        record.deliveryValues[index] = { caseId = index, components = observation.components,
            zeroSigns = observation.zeroSigns, valid = observation.valid }
    end
end

local function checkPoseProbe(record, sources)
    local raw, delivered = record.raw, record.delivered
    assert(not record.rawState.failure and not record.deliveryState.failure, "CFrame callback identity/order/arity")
    assert(record.rawState.count == #poseCases and #raw == #poseCases, "all raw CFrame cases observed")
    for index in poseCases do
        local source, received = sources[index], raw[index]
        local translationDelta, rotationDelta = 0, 0
        for component, actual in received.components do
            local delta = math.abs(actual - source.components[component])
            assert(delta == delta and delta < math.huge, "finite CFrame source-to-receiver delta")
            if component <= 3 then translationDelta = math.max(translationDelta, delta)
            else rotationDelta = math.max(rotationDelta, delta) end
        end
        received.translationDelta, received.rotationDelta = translationDelta, rotationDelta
    end
    for index, case in poseCases do
        local source, received = sources[index], raw[index]
        local translationDelta, rotationDelta = received.translationDelta, received.rotationDelta
        assert(source.valid == case.accepted and source.localPreserved, "native stored CFrame source classification: " .. case.name)
        if case.accepted then
            assert(received.valid and delivered[index] == true, "stable CFrame delivery: " .. case.name)
            assert(translationDelta == 0 and rotationDelta <= 0.0001, "CFrame native precision: " .. case.name)
        else
            -- Native serialization may repair rejected rotation matrices; inspect its result.
            assert((delivered[index] == true) == received.valid, "received CFrame predicate/delivery agreement")
        end
        if delivered[index] then
            local value = record.deliveryValues[index]
            assert(value.valid, "delivered CFrame predicate")
            for component = 1, 12 do
                assert(value.components[component] == received.components[component]
                    and value.zeroSigns[component] == received.zeroSigns[component], "Relay CFrame tuple unchanged from raw receive")
            end
        end
        if case.name == "translation-outside" then assert(not received.valid and not delivered[index], "raw translation overflow dropped") end
    end
end

local function create(version)
    local fields = ordered(
        { name = "sequence", type = "u32" :: "u32" },
        { name = "enabled", type = "boolean" :: "boolean" },
        { name = "small", type = "u8" :: "u8" },
        { name = "medium", type = "u16" :: "u16" },
        { name = "scalar", type = "f32" :: "f32", minimum = -1024, maximum = 1024 },
        { name = "position", type = "Vector3F32" :: "Vector3F32", minimum = -1024, maximum = 1024 }
    )
    local schemaFields = ordered(
        { name = "upper", type = "boolean" :: "boolean" },
        { name = "small", type = "i8" :: "i8" },
        { name = "medium", type = "i16" :: "i16" },
        { name = "large", type = "i32" :: "i32" },
        { name = "direction", type = "Vector2F32" :: "Vector2F32", minimum = -1, maximum = 1 },
        { name = "text", type = "string" :: "string", maximumBytes = 4 },
        { name = "pose", type = "CFrame" :: "CFrame", minimum = -1024, maximum = 1024 }
    )
    local poseFields = ordered(
        { name = "caseId", type = "u8" :: "u8" },
        { name = "pose", type = "CFrame" :: "CFrame", minimum = -1024, maximum = 1024 }
    )
    local definition, definitionError = Relay.define({
        name = "StudioProof",
        version = version or 1,
        events = {
            Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = fields },
            State = { id = 2, direction = "ServerToClient" :: "ServerToClient", fields = fields },
            SchemaInput = { id = 3, direction = "ClientToServer" :: "ClientToServer", fields = schemaFields },
            SchemaState = { id = 4, direction = "ServerToClient" :: "ServerToClient", fields = schemaFields },
            PoseInput = { id = 5, direction = "ClientToServer" :: "ClientToServer", fields = poseFields },
            PoseState = { id = 6, direction = "ServerToClient" :: "ServerToClient", fields = poseFields },
        },
    })
    return assert(definition, definitionError and definitionError.message)
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
    if upper then return true, 127, 32_767, 2_147_483_647, Vector2.new(0.1, 1), string.char(0, 255, 195, 169), poseCases[2].value end
    return false, -128, -32_768, -2_147_483_648, Vector2.new(-1, -1 / math.huge), "", poseCases[3].value
end

local function checkSchema(...)
    assert(select("#", ...) == 7, "schema delivered arity")
    local upper, small, medium, large, direction, text, pose = ...
    assert(type(upper) == "boolean", "signed tuple marker")
    local _, expectedSmall, expectedMedium, expectedLarge, expectedDirection, expectedText = schemaValues(upper)
    assert(small == expectedSmall and medium == expectedMedium and large == expectedLarge, "signed native extrema")
    assert(typeof(direction) == "Vector2" and direction == expectedDirection, "Vector2 native delivery")
    if not upper then assert(1 / direction.Y == math.huge, "Vector2 delivered positive zero") end
    assert(text == expectedText, "string native byte preservation")
    local observation = receivePose(if upper then 2 else 3, pose)
    assert(observation.valid and observation.translationDelta == 0 and observation.rotationDelta <= 0.0001, "schema native CFrame")
    return upper
end

return table.freeze({ create = create, values = values, check = check,
    schemaValues = schemaValues, checkSchema = checkSchema,
    poseCases = poseCases, poseSources = poseSources, receivePose = receivePose, checkPoseProbe = checkPoseProbe, poseRecord = poseRecord, recordPose = recordPose })
