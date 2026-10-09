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

-- Exercise raw composite decoding in both native runtimes, before transport.
do
    local Definition = require(ReplicatedStorage.Relay.Definition)
    local token = assert(Definition.define({ name = "CodecNormalization", version = 1, events = {
        Vectors = { id = 1, direction = "ClientToServer", fields = {
            { name = "v2", type = "Vector2F32", minimum = -1, maximum = 1 },
            { name = "v3", type = "Vector3F32", minimum = -1, maximum = 1 },
            { name = "tail", type = "optional", value = { type = "boolean" } },
        } },
        Pose = { id = 2, direction = "ClientToServer", fields = {
            { name = "value", type = "optional", value = { type = "CFrame", minimum = -1, maximum = 1 } },
        } },
    } }))
    local compiled = Definition.get(token)
    local decodeVectors = Frame.compile(compiled.byId[1], "decode")
    local bytes = buffer.create(24)
    buffer.writeu8(bytes, 0, 1)
    buffer.writeu16(bytes, 1, 1)
    local components = { -1 / math.huge, 2 ^ -149, -(2 ^ -149), 1, -1 }
    for index, value in components do buffer.writef32(bytes, 3 + (index - 1) * 4, value) end
    local result = table.pack(decodeVectors(bytes))
    assert(result.n == 4 and result[1] == true and result[4] == nil, "native composite vector tuple")
    local valid2, expected2 = Frame.compile({ fields = { compiled.byId[1].fields[1] } })(
        Vector2.new(buffer.readf32(bytes, 3), buffer.readf32(bytes, 7)))
    local valid3, expected3 = Frame.compile({ fields = { compiled.byId[1].fields[2] } })(
        Vector3.new(buffer.readf32(bytes, 11), buffer.readf32(bytes, 15), buffer.readf32(bytes, 19)))
    assert(valid2 and valid3, "native vector reference normalization")
    for index, expected in { expected2, expected3 } do
        for _, axis in (if index == 1 then { "X", "Y" } else { "X", "Y", "Z" }) do
            local actual, reference = result[index + 1][axis], expected[axis]
            assert(actual == reference and (actual ~= 0 or 1 / actual == 1 / reference),
                "native decoded vector matches post-construction normalization")
        end
    end
    for index = 1, 5 do
        local offset = 3 + (index - 1) * 4
        for _, invalid in { 0 / 0, math.huge, 2 } do
            buffer.writef32(bytes, offset, invalid)
            assert(decodeVectors(bytes) == nil, "native composite vector invalid component")
        end
        buffer.writef32(bytes, offset, components[index])
    end
    buffer.writef32(bytes, 11, -1 / math.huge)
    local valid, _, vector3 = decodeVectors(bytes)
    assert(valid and vector3.X == 0 and 1 / vector3.X == math.huge, "native decoded Vector3 canonical zero")

    local decodePose = Frame.compile(compiled.byId[2], "decode")
    local poseBytes = buffer.create(100)
    buffer.writeu8(poseBytes, 0, 1)
    buffer.writeu16(poseBytes, 1, 2)
    buffer.writeu8(poseBytes, 3, 1)
    local poseComponents = { CFrame.new(-1 / math.huge, 0, 0, 1, -1 / math.huge, 0, 0, 1, 0, 0, 0, 1):GetComponents() }
    for index, value in poseComponents do buffer.writef64(poseBytes, 4 + (index - 1) * 8, value) end
    local poseValid, pose = decodePose(poseBytes)
    assert(poseValid, "native raw CFrame accepted")
    local rebuilt = { pose:GetComponents() }
    for index, value in poseComponents do
        assert(value == rebuilt[index] and (value ~= 0 or 1 / value == 1 / rebuilt[index]),
            "native decoded CFrame components and zero signs")
    end
    buffer.writef64(poseBytes, 4, 0.1)
    assert(decodePose(poseBytes) == nil, "native CFrame reconstruction must not round raw components")
    buffer.writef64(poseBytes, 4, 0)
    buffer.writef64(poseBytes, 28, 2)
    assert(decodePose(poseBytes) == nil, "native raw CFrame invalid rotation")
end

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
    local unreliableFields = ordered(
        { name = "sampleId", type = "u8" :: "u8" },
        { name = "value", type = "u16" :: "u16" },
        { name = "enabled", type = "boolean" :: "boolean" }
    )
    local modes = ordered("Idle" :: "Idle", "Run" :: "Run")
    local compositeFields = ordered(
        {
            name = "snapshot",
            type = "struct" :: "struct",
            fields = ordered(
                { name = "sequence" :: "sequence", type = "u8" :: "u8" },
                { name = "mode" :: "mode", type = "enum" :: "enum", values = modes },
                { name = "scores" :: "scores", type = "array" :: "array", maximumLength = 3,
                    element = { type = "u16" :: "u16" } },
                { name = "steps" :: "steps", type = "array" :: "array", maximumLength = 2,
                    element = { type = "struct" :: "struct", fields = ordered(
                        { name = "value" :: "value", type = "u16" :: "u16" },
                        { name = "label" :: "label", type = "optional" :: "optional",
                            value = { type = "string" :: "string", maximumBytes = 8 } }
                    ) } },
                { name = "tags" :: "tags", type = "set" :: "set", maximumSize = 2,
                    element = { type = "string" :: "string", maximumBytes = 8 } },
                { name = "codes" :: "codes", type = "set" :: "set", maximumSize = 2,
                    element = { type = "u8" :: "u8" } },
                { name = "toggles" :: "toggles", type = "set" :: "set", maximumSize = 2,
                    element = { type = "boolean" :: "boolean" } },
                { name = "poses" :: "poses", type = "array" :: "array", maximumLength = 3,
                    element = { type = "CFrame" :: "CFrame", minimum = -1024, maximum = 1024 } }
            ),
        },
        { name = "ticket", type = "optional" :: "optional", value = { type = "u8" :: "u8" } }
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
            UnreliableInput = { id = 7, direction = "ClientToServer" :: "ClientToServer", delivery = "Unreliable" :: "Unreliable", fields = unreliableFields },
            UnreliableState = { id = 8, direction = "ServerToClient" :: "ServerToClient", delivery = "Unreliable" :: "Unreliable", fields = unreliableFields },
            CompositeInput = { id = 9, direction = "ClientToServer" :: "ClientToServer", fields = compositeFields },
            CompositeState = { id = 10, direction = "ServerToClient" :: "ServerToClient", fields = compositeFields },
            UnreliableCompositeInput = { id = 11, direction = "ClientToServer" :: "ClientToServer", delivery = "Unreliable" :: "Unreliable", fields = compositeFields },
            UnreliableCompositeState = { id = 12, direction = "ServerToClient" :: "ServerToClient", delivery = "Unreliable" :: "Unreliable", fields = compositeFields },
        },
        requests = {
            Inspect = Relay.schema.request(13, ordered({ name = "sequence", type = "u16" :: "u16" }),
                Relay.schema.struct(
                    Relay.schema.field("sequence" :: "sequence", Relay.schema.u16()),
                    (Relay.schema.field("owner" :: "owner", Relay.schema.string(32)))
                )),
            Optional = Relay.schema.request(14, ordered({ name = "present", type = "boolean" :: "boolean" }),
                Relay.schema.optional(Relay.schema.boolean())),
            Delay = Relay.schema.request(15, ordered({ name = "seconds", type = "f32" :: "f32", minimum = 0, maximum = 1 }),
                Relay.schema.u16()),
            Failure = Relay.schema.request(16, ordered({ name = "invalidReturn", type = "boolean" :: "boolean" }),
                Relay.schema.boolean()),
        },
    })
    return assert(definition, definitionError and definitionError.message)
end

local function createQueued()
    local definition, definitionError = Relay.define({
        name = "StudioQueuedProof",
        version = 1,
        readiness = true,
        events = {
            QueueInput = { id = 1, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            UnreliableQueueInput = { id = 2, direction = "ClientToServer" :: "ClientToServer", delivery = "Unreliable" :: "Unreliable",
                queue = "Batch" :: "Batch", fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            IndependentInput = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            ToggleInput = { id = 4, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
                fields = ordered({ name = "value", type = "boolean" :: "boolean" }) },
            StateInput = { id = 5, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            ImmediateInput = { id = 6, direction = "ClientToServer" :: "ClientToServer",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            QueuePush = { id = 7, direction = "ServerToClient" :: "ServerToClient", queue = "Batch" :: "Batch",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            UnreliableQueuePush = { id = 8, direction = "ServerToClient" :: "ServerToClient", delivery = "Unreliable" :: "Unreliable",
                queue = "Batch" :: "Batch", fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            OncePush = { id = 9, direction = "ServerToClient" :: "ServerToClient", queue = "Batch" :: "Batch",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
            StatePush = { id = 10, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
                fields = ordered({ name = "value", type = "u8" :: "u8" }) },
        },
    })
    return assert(definition, definitionError and definitionError.message)
end

local unreliableSampleCount = 8

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

local function unreliableValues(sampleId)
    return sampleId, sampleId * 257, sampleId % 2 == 0
end

local function checkUnreliable(sampleId, value, enabled, ...)
    assert(select("#", ...) == 0, "extra unreliable fields")
    assert(type(sampleId) == "number" and sampleId % 1 == 0 and sampleId >= 1
        and sampleId <= unreliableSampleCount * 3, "unreliable sample identity")
    assert(value == sampleId * 257 and enabled == (sampleId % 2 == 0), "unreliable tuple values")
    return sampleId, value, enabled
end

local compositePoses = { poseCases[1].value, poseCases[4].value, poseCases[6].value }

local function composedValues(sequence)
    local active = sequence % 2 == 0
    return {
        sequence = sequence,
        mode = if active then "Run" else "Idle",
        scores = { sequence, sequence + 10, 65535 },
        steps = {
            { value = sequence, label = if active then "step" else nil },
            { value = 255 },
        },
        tags = { blue = true, relay = true },
        codes = { [7] = true, [201] = true },
        toggles = { [false] = true, [true] = true },
        poses = table.clone(compositePoses),
    }, if active then sequence else nil
end

local function checkSet(set, expectedCount)
    local count = 0
    for _, present in set do
        assert(present == true, "set member marker")
        count += 1
    end
    assert(count == expectedCount, "set size")
end

local function samePoseComponents(actual, expected)
    if typeof(actual) ~= "CFrame" then return false end
    local actualComponents = { actual:GetComponents() }
    local expectedComponents = { expected:GetComponents() }
    for index, component in expectedComponents do
        if actualComponents[index] ~= component then return false end
        if component == 0 and 1 / actualComponents[index] ~= 1 / component then return false end
    end
    return true
end

local function checkComposed(...)
    assert(select("#", ...) == 2, "composed event arity including trailing optional")
    local payload, ticket = ...
    assert(type(payload) == "table", "composed struct")
    local snapshot = payload
    local sequence = snapshot.sequence
    assert(type(sequence) == "number" and sequence % 1 == 0 and sequence >= 1 and sequence <= 255, "composed sequence")
    local active = sequence % 2 == 0
    assert(snapshot.mode == (if active then "Run" else "Idle"), "string enum")
    assert(type(snapshot.scores) == "table" and #snapshot.scores == 3
        and snapshot.scores[1] == sequence and snapshot.scores[2] == sequence + 10 and snapshot.scores[3] == 65535,
        "bounded array values")
    assert(type(snapshot.steps) == "table" and #snapshot.steps == 2
        and snapshot.steps[1].value == sequence and snapshot.steps[1].label == (if active then "step" else nil)
        and snapshot.steps[2].value == 255 and snapshot.steps[2].label == nil, "array of structs and optional fields")

    checkSet(snapshot.tags, 2)
    assert(snapshot.tags.blue == true and snapshot.tags.relay == true, "string set keys")
    checkSet(snapshot.codes, 2)
    assert(snapshot.codes[7] == true and snapshot.codes[201] == true, "integer set keys")
    checkSet(snapshot.toggles, 2)
    assert(snapshot.toggles[false] == true and snapshot.toggles[true] == true, "boolean set keys")

    assert(type(snapshot.poses) == "table" and #snapshot.poses == #compositePoses, "CFrame array")
    for index, expected in compositePoses do
        local components = { expected:GetComponents() }
        assert(samePoseComponents(CFrame.new(table.unpack(components)), expected), "native CFrame constructor component round trip")
        assert(samePoseComponents(snapshot.poses[index], expected), "composed CFrame component/zero preservation")
    end
    assert(ticket == (if active then sequence else nil), "optional trailing nil/value")
    return sequence, ticket
end

local composedAttemptCount = 8

return table.freeze({ create = create, createQueued = createQueued, values = values, check = check,
    schemaValues = schemaValues, checkSchema = checkSchema,
    unreliableSampleCount = unreliableSampleCount, unreliableValues = unreliableValues, checkUnreliable = checkUnreliable,
    composedValues = composedValues, checkComposed = checkComposed, composedAttemptCount = composedAttemptCount,
    poseCases = poseCases, poseSources = poseSources, receivePose = receivePose, checkPoseProbe = checkPoseProbe, poseRecord = poseRecord, recordPose = recordPose })
