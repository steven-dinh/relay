local roblox = require("@lune/roblox")

Vector3 = roblox.Vector3

local Definition = require("../src/Definition")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
    environment = { Vector3 = roblox.Vector3 },
    injectGlobals = true,
})()

local function resolveEndpoint(byId, direction, id)
    return Frame.resolve({ byId = byId }, direction, id)
end

local function validatePayload(fields, ...)
    return Frame.validate({ fields = fields }, ...)
end

local function expectRejected(value, message)
    assert(value == nil, message)
end

local function roundFloat32(value)
    local storage = buffer.create(4)
    buffer.writef32(storage, 0, value)
    return buffer.readf32(storage, 0)
end

assert(type(Frame) == "table", "Frame must return a table")
assert(table.isfrozen(Frame), "Frame export must be frozen")
assert(type(Frame.resolve) == "function", "Frame.resolve must be a function")
assert(type(Frame.validate) == "function", "Frame.validate must be a function")

local publicKeyCount = 0

for key in Frame do
    publicKeyCount += 1
    assert(key == "resolve" or key == "validate", `unexpected Frame key: {tostring(key)}`)
end

assert(publicKeyCount == 2, "Frame must expose exactly two keys")

local mutationSucceeded = pcall(function()
    Frame.extra = true
end)

assert(not mutationSucceeded, "Frame export must reject mutation")

local integrationToken, integrationError = Definition.define({
	name = "Integration",
	version = 1,
	events = {
		Input = {
			id = 7,
			direction = "ClientToServer",
			fields = {
				{ name = "count", type = "u16", maximum = 10 },
				{ name = "ratio", type = "f32", minimum = -1, maximum = 1 },
			},
		},
	},
})
assert(integrationToken ~= nil and integrationError == nil, "integration definition must compile")
local integrationCompiled = Definition.get(integrationToken)
assert(integrationCompiled ~= nil, "integration definition must resolve")
local integrationEvent = resolveEndpoint(integrationCompiled.byId, "ClientToServer", 7)
assert(integrationEvent == integrationCompiled.byId[7], "Frame must resolve Definition's compiled event shape")
local integrationPayload = validatePayload(integrationEvent.fields, 10, 0.1)
assert(integrationPayload ~= nil, "Frame must validate Definition's compiled field shape")
assert(
	integrationPayload[1] == 10 and integrationPayload[2] == roundFloat32(0.1),
	"compiled integration payload changed"
)

local clientToServer = table.freeze({
    direction = "ClientToServer",
    fields = table.freeze({}),
})
local serverToClient = table.freeze({
    direction = "ServerToClient",
    fields = table.freeze({}),
})
local byId = table.freeze({
    [1] = clientToServer,
    [2] = table.freeze({ direction = "Unknown", fields = table.freeze({}) }),
    [65_535] = serverToClient,
})

assert(resolveEndpoint(byId, "ClientToServer", 1) == clientToServer, "minimum endpoint ID must resolve")
assert(resolveEndpoint(byId, "ServerToClient", 65_535) == serverToClient, "maximum endpoint ID must resolve")
expectRejected(resolveEndpoint(byId, "ServerToClient", 1), "wrong direction must reject")
expectRejected(resolveEndpoint(byId, "Unknown", 1), "unknown direction must reject")
expectRejected(resolveEndpoint(byId, "Unknown", 2), "matching unsupported direction must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", nil), "nil endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", "1"), "non-number endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", 1.5), "fractional endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", 0 / 0), "NaN endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", math.huge), "positive infinity endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", -math.huge), "negative infinity endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", -1), "negative endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", 0), "zero endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", 2), "unknown endpoint ID must reject")
expectRejected(resolveEndpoint(byId, "ClientToServer", 65_536), "endpoint ID above maximum must reject")

local emptyPayload = validatePayload({})
assert(type(emptyPayload) == "table" and #emptyPayload == 0, "empty payload must normalize")
expectRejected(validatePayload({}, nil), "explicit nil must count toward arity")

local falsePayload = validatePayload({ { name = "value", type = "boolean" } }, false)
assert(falsePayload ~= nil and falsePayload[1] == false, "false must be a valid boolean payload")

local zeroUnsigned = validatePayload({ { name = "value", type = "u8" } }, -1 / math.huge)
assert(zeroUnsigned ~= nil and 1 / zeroUnsigned[1] == math.huge, "unsigned negative zero must become positive zero")

local optionalBoundPayload = validatePayload(
    {
        { name = "maximumOnly", type = "u8", maximum = 5 },
        { name = "minimumOnly", type = "u16", minimum = 5 },
        { name = "baseBounds", type = "u32" },
    },
    0,
    65_535,
    0
)
assert(optionalBoundPayload ~= nil, "unsigned optional bound shapes must use effective base bounds")

for _, unsignedCase in {
    { type = "u8", maximum = 255 },
    { type = "u16", maximum = 65_535 },
    { type = "u32", maximum = 4_294_967_295 },
} do
    local fieldType = unsignedCase.type
    local maximum = unsignedCase.maximum

    assert(
        validatePayload({ { name = "value", type = fieldType } }, 0) ~= nil,
        `{fieldType} base minimum must be accepted`
    )
    assert(
        validatePayload({ { name = "value", type = fieldType } }, maximum) ~= nil,
        `{fieldType} base maximum must be accepted`
    )
    expectRejected(
        validatePayload({ { name = "value", type = fieldType } }, -1),
        `{fieldType} below its base minimum must reject`
    )
    expectRejected(
        validatePayload({ { name = "value", type = fieldType } }, maximum + 1),
        `{fieldType} above its base maximum must reject`
    )
    assert(
        validatePayload({ { name = "value", type = fieldType, minimum = 1 } }, 1) ~= nil,
        `{fieldType} minimum-only bound must accept its boundary`
    )
    expectRejected(
        validatePayload({ { name = "value", type = fieldType, minimum = 1 } }, 0),
        `{fieldType} minimum-only bound must reject below its boundary`
    )
    assert(
        validatePayload({ { name = "value", type = fieldType, maximum = maximum - 1 } }, maximum - 1) ~= nil,
        `{fieldType} maximum-only bound must accept its boundary`
    )
    expectRejected(
        validatePayload({ { name = "value", type = fieldType, maximum = maximum - 1 } }, maximum),
        `{fieldType} maximum-only bound must reject above its boundary`
    )
end

local allFields = {
    { name = "active", type = "boolean" },
    { name = "small", type = "u8", minimum = 1, maximum = 254 },
    { name = "medium", type = "u16", minimum = 0, maximum = 65_535 },
    { name = "large", type = "u32", minimum = 0, maximum = 4_294_967_295 },
    { name = "weight", type = "f32", minimum = -1, maximum = 1 },
    { name = "position", type = "Vector3F32", minimum = -1, maximum = 1 },
}
local negativeZero = -1 / math.huge

assert(1 / negativeZero == -math.huge, "test setup must produce negative zero")

local payload = validatePayload(
    allFields,
    true,
    1,
    65_535,
    4_294_967_295,
    0.1,
    Vector3.new(0.1, -0.1, negativeZero)
)

assert(payload ~= nil, "all six field types must normalize")
assert(payload[1] == true, "boolean must be preserved")
assert(payload[2] == 1, "u8 minimum must be preserved")
assert(payload[3] == 65_535, "u16 maximum must be preserved")
assert(payload[4] == 4_294_967_295, "u32 maximum must be preserved")
assert(payload[5] == roundFloat32(0.1), "f32 must round to Float32")
assert(typeof(payload[6]) == "Vector3", "Vector3F32 must deliver a Vector3")
assert(payload[6].X == roundFloat32(0.1), "Vector3F32 X must round to Float32")
assert(payload[6].Y == roundFloat32(-0.1), "Vector3F32 Y must round to Float32")
assert(payload[6].Z == 0 and 1 / payload[6].Z == math.huge, "Vector3F32 negative zero must become positive zero")

expectRejected(validatePayload(allFields, true, 1), "missing fields must reject")
expectRejected(
    validatePayload(allFields, true, 1, 65_535, 4_294_967_295, 0.1, Vector3.zero, false),
    "extra fields must reject"
)
expectRejected(
    validatePayload({ { name = "first", type = "boolean" }, { name = "second", type = "u8" } }, true, nil),
    "explicit nil in a present field must reject"
)
expectRejected(
    validatePayload(
        {
            { name = "one", type = "boolean" },
            { name = "two", type = "boolean" },
            { name = "three", type = "boolean" },
            { name = "four", type = "boolean" },
            { name = "five", type = "boolean" },
            { name = "six", type = "boolean" },
            { name = "seven", type = "boolean" },
            { name = "eight", type = "boolean" },
            { name = "nine", type = "boolean" },
        },
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true
    ),
    "payload schemas above the frozen field limit must reject"
)

local maximumFields = {
    { name = "one", type = "boolean" },
    { name = "two", type = "boolean" },
    { name = "three", type = "boolean" },
    { name = "four", type = "boolean" },
    { name = "five", type = "boolean" },
    { name = "six", type = "boolean" },
    { name = "seven", type = "boolean" },
    { name = "eight", type = "boolean" },
}
local maximumArityPayload = validatePayload(
    maximumFields,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false
)
assert(maximumArityPayload ~= nil and #maximumArityPayload == 8, "eight fields must remain valid")

for arity = 0, 10 do
    local values = table.create(arity, true)
    local arityPayload = validatePayload(maximumFields, table.unpack(values, 1, arity))

    if arity == 8 then
        assert(arityPayload ~= nil, "exact maximum arity must be accepted")
    else
        expectRejected(arityPayload, `arity {arity} must reject for an eight-field schema`)
    end
end

expectRejected(validatePayload({ { name = "value", type = "boolean" } }, 1), "boolean wrong type must reject")
expectRejected(validatePayload({ { name = "value", type = "u8" } }, "1"), "unsigned wrong type must reject")
expectRejected(validatePayload({ { name = "value", type = "u8" } }, 1.5), "fractional unsigned value must reject")
expectRejected(validatePayload({ { name = "value", type = "u8" } }, 0 / 0), "NaN unsigned value must reject")
expectRejected(validatePayload({ { name = "value", type = "u8" } }, math.huge), "infinite unsigned value must reject")
expectRejected(validatePayload({ { name = "value", type = "u8" } }, -1), "unsigned value below base range must reject")
expectRejected(validatePayload({ { name = "value", type = "u8" } }, 256), "unsigned value above base range must reject")
expectRejected(
    validatePayload({ { name = "value", type = "u8", minimum = -1, maximum = 256 } }, 256),
    "unsigned bounds must not widen the base type"
)
expectRejected(
    validatePayload({ { name = "value", type = "u8", minimum = 2, maximum = 3 } }, 1),
    "unsigned value below narrowed range must reject"
)
expectRejected(
    validatePayload({ { name = "value", type = "u8", minimum = 2, maximum = 3 } }, 4),
    "unsigned value above narrowed range must reject"
)

local negativeZeroPayload = validatePayload(
    { { name = "value", type = "f32", minimum = -1, maximum = 1 } },
    negativeZero
)
assert(negativeZeroPayload ~= nil, "f32 negative zero must be accepted in range")
assert(negativeZeroPayload[1] == 0 and 1 / negativeZeroPayload[1] == math.huge, "f32 negative zero must become positive zero")

local underflowPayload = validatePayload(
    { { name = "value", type = "f32", minimum = -1, maximum = 1 } },
    -1e-50
)
assert(underflowPayload ~= nil, "f32 underflow must be accepted when original and zero are in range")
assert(underflowPayload[1] == 0 and 1 / underflowPayload[1] == math.huge, "f32 underflow must deliver positive zero")

expectRejected(validatePayload({ { name = "value", type = "f32", minimum = -1, maximum = 1 } }, "0"), "f32 wrong type must reject")
expectRejected(validatePayload({ { name = "value", type = "f32", minimum = -1, maximum = 1 } }, 0 / 0), "f32 NaN must reject")
expectRejected(validatePayload({ { name = "value", type = "f32", minimum = -1, maximum = 1 } }, math.huge), "f32 infinity must reject")
expectRejected(validatePayload({ { name = "value", type = "f32", minimum = -1, maximum = 1 } }, -math.huge), "f32 negative infinity must reject")
expectRejected(validatePayload({ { name = "value", type = "f32", minimum = 0, maximum = 1 } }, -1e-50), "f32 original value below range must reject even when it rounds to zero")
expectRejected(validatePayload({ { name = "value", type = "f32", minimum = 0.1, maximum = 0.1 } }, 0.1), "f32 rounded value outside bounds must reject")
expectRejected(validatePayload({ { name = "value", type = "f32", minimum = -1e39, maximum = 1e39 } }, 3.5e38), "finite value that rounds to infinity must reject")

expectRejected(
    validatePayload({ { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } }, { X = 0, Y = 0, Z = 0 }),
    "Vector3F32 must reject table lookalikes"
)
expectRejected(
    validatePayload({ { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } }, Vector3.new(0, 2, 0)),
    "Vector3F32 must reject any component outside bounds"
)
expectRejected(
    validatePayload({ { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } }, Vector3.new(0, math.huge, 0)),
    "Vector3F32 must reject a nonfinite component"
)
local vectorBoundsPayload = validatePayload(
    { { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } },
    Vector3.new(-1, 1, 0)
)
assert(vectorBoundsPayload ~= nil, "Vector3F32 inclusive component bounds must be accepted")
expectRejected(
    validatePayload(
        { { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } },
        Vector3.new(0 / 0, 0, 0)
    ),
    "Vector3F32 must reject a NaN X component"
)
expectRejected(
    validatePayload(
        { { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } },
        Vector3.new(0, math.huge, 0)
    ),
    "Vector3F32 must reject a positive-infinite Y component"
)
expectRejected(
    validatePayload(
        { { name = "value", type = "Vector3F32", minimum = -1, maximum = 1 } },
        Vector3.new(0, 0, -math.huge)
    ),
    "Vector3F32 must reject a negative-infinite Z component"
)
expectRejected(validatePayload({ { name = "value", type = "unknown" } }, false), "unknown field type must reject")

print("PASS Relay.ReliableEvents.Frame")
