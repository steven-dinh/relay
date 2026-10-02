local fs = require("@lune/fs")

local Definition = require("../src/Definition")

local function countKeys(value)
    local count = 0

    for _ in value do
        count += 1
    end

    return count
end

local function assertDeepFrozen(value, path)
    if type(value) ~= "table" then
        return
    end

    assert(table.isfrozen(value), `{path} must be frozen`)

    for key, nested in value do
        assertDeepFrozen(nested, `{path}.{tostring(key)}`)
    end
end

local function emptyEvent(id, direction)
    return {
        id = id or 1,
        direction = direction or "ClientToServer",
        fields = {},
    }
end

local function simpleSpec()
    return {
        name = "Test",
        version = 1,
        events = {
            Ping = emptyEvent(),
        },
    }
end

local function assertInvalid(spec, label)
    local callSucceeded, token, definitionError = pcall(Definition.define, spec)

    assert(callSucceeded, `{label} must not throw`)
    assert(token == nil, `{label} must reject`)
    assert(type(definitionError) == "table", `{label} must return an error`)
    assert(table.isfrozen(definitionError), `{label} error must be frozen`)
    assert(definitionError.code == "InvalidDefinition", `{label} must map to InvalidDefinition`)
    assert(type(definitionError.message) == "string", `{label} error must have a message`)
    assert(countKeys(definitionError) == 2, `{label} error must have exactly two keys`)

    local mutationSucceeded = pcall(function()
        definitionError.code = "changed"
    end)
    assert(not mutationSucceeded, `{label} error must reject mutation`)
end

local function assertValid(spec, label)
    local token, definitionError = Definition.define(spec)

    assert(definitionError == nil, `{label} unexpectedly returned an error`)
    assert(type(token) == "table", `{label} must return a token`)
    assert(getmetatable(token) == nil, `{label} token must have no metatable`)
    assert(table.isfrozen(token), `{label} token must be frozen`)
    assert(next(token) == nil, `{label} token must have zero keys`)

    local compiled = Definition.get(token)
    assert(type(compiled) == "table", `{label} token must resolve`)
    assertDeepFrozen(compiled, `{label}.compiled`)

    return token, compiled
end

local function forceCollection()
    -- Lune exposes collection telemetry but does not permit a forced collection.
    -- Bounded allocation pressure advances its collector for the weak-key proofs.
    for _ = 1, 64 do
        local garbage = table.create(4_096)

        for index = 1, 4_096 do
            garbage[index] = { index }
        end
    end
end

assert(type(Definition) == "table", "Definition must return a table")
assert(table.isfrozen(Definition), "Definition module surface must be frozen")
assert(countKeys(Definition) == 3, "Definition module must expose exactly three keys")
assert(type(Definition.define) == "function", "Definition.define must be a function")
assert(type(Definition.get) == "function", "Definition.get must be a function")
assert(type(Definition.error) == "function", "Definition.error must be a function")

for key in Definition do
    assert(key == "define" or key == "get" or key == "error", `unexpected Definition module key {tostring(key)}`)
end

local moduleMutationSucceeded = pcall(function()
    Definition.get = nil
end)
assert(not moduleMutationSucceeded, "Definition module surface must reject mutation")

local simpleToken, simpleCompiled = assertValid(simpleSpec(), "simple definition")
assert(simpleCompiled.descriptor == "RR1|D4:Test|V1|N1|E1,C,4:Ping,0", "simple descriptor golden changed")
assert(countKeys(simpleCompiled) == 6, "compiled definition must have exactly six keys")
assert(countKeys(simpleCompiled.byId) == 1, "compiled definition must contain one event")
assert(simpleCompiled.name == "Test" and simpleCompiled.version == 1, "compiled definition identity changed")
assert(not simpleCompiled.hasUnreliable, "reliable-only definition must not have an unreliable channel")
assert(simpleCompiled.events.Ping == simpleCompiled.byId[1], "name and ID must resolve the same compiled event")
assert(simpleCompiled.events.Ping.id == 1, "compiled event ID changed")
assert(simpleCompiled.byId[1].name == "Ping", "compiled event name changed")
assert(simpleCompiled.byId[1].direction == "ClientToServer", "compiled event direction changed")
assert(simpleCompiled.byId[1].delivery == "Reliable", "omitted delivery must default to Reliable")
assert(#simpleCompiled.byId[1].fields == 0, "empty event fields must remain empty")
assert(not simpleCompiled.byId[1].usesCodec, "primitive event must retain native tuples")
assert(simpleCompiled.byId[1].minimumEncodedBytes == 3 and simpleCompiled.byId[1].maximumEncodedBytes == 3,
    "empty event encoded-size metadata must include the header")
assert(simpleCompiled.byId[1].maximumElements == 0, "empty event has no expanded shape nodes")
assert(Definition.get(table.freeze({})) == nil, "copied empty token must not resolve")
assert(Definition.get({}) == nil, "mutable empty table must not resolve")
assert(Definition.get(nil) == nil, "nil must not resolve")
assert(Definition.get("not a token") == nil, "non-table must not resolve")

local explicitReliableSpec = simpleSpec()
explicitReliableSpec.events.Ping.delivery = "Reliable"
local _, explicitReliableCompiled = assertValid(explicitReliableSpec, "explicit reliable delivery")
assert(explicitReliableCompiled.events.Ping.delivery == "Reliable", "explicit delivery must be retained")
assert(explicitReliableCompiled.descriptor == simpleCompiled.descriptor, "explicit Reliable must preserve RR1 bytes")

local mixedDeliverySpec = {
    name = "Test",
    version = 1,
    events = {
        Ping = emptyEvent(1),
        Pong = emptyEvent(2, "ServerToClient"),
    },
}
mixedDeliverySpec.events.Ping.delivery = "Unreliable"
local _, mixedDeliveryCompiled = assertValid(mixedDeliverySpec, "mixed delivery definition")
assert(mixedDeliveryCompiled.hasUnreliable, "mixed delivery definition must expose its unreliable channel")
assert(mixedDeliveryCompiled.events.Ping.delivery == "Unreliable", "unreliable delivery must be retained")
assert(mixedDeliveryCompiled.events.Pong.delivery == "Reliable", "omitted mixed delivery must default to Reliable")
assert(mixedDeliveryCompiled.descriptor
    == "RR2|D4:Test|V1|N2|E1,C,U,4:Ping,0|E2,S,R,4:Pong,0", "RR2 mixed delivery descriptor changed")
local switchedDeliverySpec = table.clone(mixedDeliverySpec)
switchedDeliverySpec.events = table.clone(mixedDeliverySpec.events)
switchedDeliverySpec.events.Pong = table.clone(mixedDeliverySpec.events.Pong)
switchedDeliverySpec.events.Pong.delivery = "Unreliable"
local _, switchedDeliveryCompiled = assertValid(switchedDeliverySpec, "changed mixed delivery definition")
assert(switchedDeliveryCompiled.descriptor
    == "RR2|D4:Test|V1|N2|E1,C,U,4:Ping,0|E2,S,U,4:Pong,0", "RR2 changed delivery descriptor changed")
assert(switchedDeliveryCompiled.descriptor ~= mixedDeliveryCompiled.descriptor,
    "changing one RR2 event delivery must change the descriptor")
local reverseMixedDeliverySpec = { name = "Test", version = 1, events = {} }
reverseMixedDeliverySpec.events.Pong = emptyEvent(2, "ServerToClient")
reverseMixedDeliverySpec.events.Ping = emptyEvent(1)
reverseMixedDeliverySpec.events.Ping.delivery = "Unreliable"
local _, reverseMixedDeliveryCompiled = assertValid(reverseMixedDeliverySpec, "reverse mixed delivery definition")
assert(reverseMixedDeliveryCompiled.descriptor == mixedDeliveryCompiled.descriptor,
    "mixed delivery descriptor must ignore event insertion order")

local unreliableOnlySpec = simpleSpec()
unreliableOnlySpec.events.Ping.delivery = "Unreliable"
local _, unreliableOnlyCompiled = assertValid(unreliableOnlySpec, "unreliable-only definition")
assert(unreliableOnlyCompiled.hasUnreliable, "unreliable-only definition must expose its unreliable channel")
assert(unreliableOnlyCompiled.descriptor == "RR2|D4:Test|V1|N1|E1,C,U,4:Ping,0",
    "unreliable-only descriptor changed")

for _, invalidDelivery in { "BestEffort", false, 1, {}, setmetatable({}, {}) } do
    local invalidDeliverySpec = simpleSpec()
    invalidDeliverySpec.events.Ping.delivery = invalidDelivery
    assertInvalid(invalidDeliverySpec, "invalid delivery")
end

if not fs.isDir(".tmp") then
	fs.writeDir(".tmp")
end

local foreignModulePath = ".tmp/DefinitionForeign.luau"
fs.writeFile(foreignModulePath, fs.readFile("src/Definition.luau"))
local ForeignDefinition = require("../.tmp/DefinitionForeign")
fs.removeFile(foreignModulePath)
assert(ForeignDefinition ~= Definition, "foreign Definition test must load a separate module instance")
assert(ForeignDefinition.get(simpleToken) == nil, "foreign module must reject the local token")
local foreignToken = assert(ForeignDefinition.define(simpleSpec()))
assert(Definition.get(foreignToken) == nil, "local module must reject a foreign token")

local boundsSpec = {
    name = "Bounds",
    version = 7,
    events = {
        State = {
            id = 5,
            direction = "ServerToClient",
            fields = {
                { name = "flag", type = "boolean" },
                { name = "byte", type = "u8" },
                { name = "short", type = "u16", minimum = 1 },
                { name = "count", type = "u32", maximum = 10 },
                { name = "ratio", type = "f32", minimum = -0, maximum = 1 },
                { name = "vector", type = "Vector3F32", minimum = -2, maximum = 2 },
            },
        },
    },
}

local _, boundsCompiled = assertValid(boundsSpec, "all type bounds")
assert(
    boundsCompiled.descriptor
        == "RR1|D6:Bounds|V7|N1|E5,S,5:State,6"
            .. "|F4:flag,b,-,-"
            .. "|F4:byte,u8,0,255"
            .. "|F5:short,u16,1,65535"
            .. "|F5:count,u32,0,10"
            .. "|F5:ratio,f32,00000000,3f800000"
            .. "|F6:vector,v3f32,c0000000,40000000",
    "six-type descriptor golden changed"
)

local compiledFields = boundsCompiled.byId[5].fields
assert(countKeys(compiledFields[1]) == 6, "boolean compiled field must omit bounds but keep codec metadata")
assert(compiledFields[1].minimumEncodedBytes == 1 and compiledFields[1].maximumEncodedBytes == 1,
    "boolean encoded-size bounds changed")
assert(compiledFields[2].minimum == 0 and compiledFields[2].maximum == 255, "u8 effective bounds changed")
assert(compiledFields[3].minimum == 1 and compiledFields[3].maximum == 65_535, "u16 one-sided bounds changed")
assert(compiledFields[4].minimum == 0 and compiledFields[4].maximum == 10, "u32 one-sided bounds changed")
assert(compiledFields[5].minimum == 0, "Float32 negative zero must canonicalize to positive zero")
assert(1 / compiledFields[5].minimum == math.huge, "compiled Float32 zero must have a positive sign")

local implicitBounds = simpleSpec()
implicitBounds.events.Ping.fields = {
    { name = "a", type = "u8" },
    { name = "b", type = "u16" },
    { name = "c", type = "u32" },
}
local explicitBounds = simpleSpec()
explicitBounds.events.Ping.fields = {
    { name = "a", type = "u8", minimum = 0, maximum = 255 },
    { name = "b", type = "u16", minimum = 0, maximum = 65_535 },
    { name = "c", type = "u32", minimum = 0, maximum = 4_294_967_295 },
}

local _, implicitCompiled = assertValid(implicitBounds, "implicit unsigned bounds")
local _, explicitCompiled = assertValid(explicitBounds, "explicit unsigned bounds")
assert(
    implicitCompiled.descriptor == explicitCompiled.descriptor,
    "omitted and explicit base unsigned bounds must share one descriptor"
)

for _, unsigned in { { "u8", 255 }, { "u16", 65_535 }, { "u32", 4_294_967_295 } } do
    for _, bounds in {
        {},
        { minimum = 0 },
        { maximum = unsigned[2] },
        { minimum = -1 / math.huge, maximum = unsigned[2] },
    } do
        local spec = simpleSpec()
        local field = { name = "value", type = unsigned[1] }
        for key, value in bounds do
            field[key] = value
        end
        spec.events.Ping.fields = { field }
        local _, compiled = assertValid(spec, "unsigned bound keyset")
        assert(compiled.descriptor == `RR1|D4:Test|V1|N1|E1,C,4:Ping,1|F5:value,{unsigned[1]},0,{unsigned[2]}`,
            "every unsigned optional bound keyset must share its effective-bound golden")
        assert(1 / compiled.events.Ping.fields[1].minimum == math.huge, "unsigned negative zero must canonicalize")
    end
end

for _, signed in { { "i8", -128, 127 }, { "i16", -32_768, 32_767 }, { "i32", -2_147_483_648, 2_147_483_647 } } do
    for _, bounds in {
        {}, { minimum = signed[2] }, { maximum = signed[3] },
        { minimum = signed[2], maximum = signed[3] },
        { minimum = -5, maximum = 5 }, { minimum = -1 / math.huge, maximum = 0 },
    } do
        local spec = simpleSpec()
        local field = { name = "value", type = signed[1] }
        for key, value in bounds do field[key] = value end
        spec.events.Ping.fields = { field }
        local _, compiled = assertValid(spec, "signed bounds")
        local minimum = if bounds.minimum == nil then signed[2] else bounds.minimum
        local maximum = if bounds.maximum == nil then signed[3] else bounds.maximum
        local minimumToken = string.format("%.0f", if minimum == 0 then 0 else minimum)
        assert(compiled.descriptor == `RR1|D4:Test|V1|N1|E1,C,4:Ping,1|F5:value,{signed[1]},{minimumToken},{maximum}`,
            "signed descriptor golden changed")
        local result = compiled.events.Ping.fields[1]
        assert(result.minimum == minimum and result.maximum == maximum, "signed effective bounds")
        if minimum == 0 then assert(1 / result.minimum == math.huge, "signed positive zero") end
    end
    for _, bounds in {
        { minimum = signed[2] - 1 }, { maximum = signed[3] + 1 },
        { minimum = 1, maximum = -1 }, { minimum = -0.5 }, { maximum = 0.5 },
        { minimum = 0 / 0 }, { maximum = math.huge }, { minimum = -math.huge },
        { maximum = "1" }, { minimum = false }, { extra = true },
    } do
        local spec = simpleSpec()
        local field = { name = "value", type = signed[1] }
        for key, value in bounds do field[key] = value end
        spec.events.Ping.fields = { field }
        assertInvalid(spec, "invalid signed bound or key")
    end
end

local vector2Spec = simpleSpec()
vector2Spec.events.Ping.fields = { { name = "direction", type = "Vector2F32", minimum = -1, maximum = 1 } }
local _, vector2Compiled = assertValid(vector2Spec, "Vector2 bounds")
assert(vector2Compiled.descriptor == "RR1|D4:Test|V1|N1|E1,C,4:Ping,1|F9:direction,v2f32,bf800000,3f800000",
    "Vector2 descriptor golden")
for _, bounds in {
    {}, { minimum = -1 }, { maximum = 1 }, { minimum = 0.1, maximum = 1 },
    { minimum = -1, maximum = 0.1 }, { minimum = 0 / 0, maximum = 1 },
    { minimum = -math.huge, maximum = 1 }, { minimum = -1, maximum = math.huge },
    { minimum = 1, maximum = -1 }, { minimum = "0", maximum = 1 },
    { minimum = -1, maximum = 1, extra = true },
} do
    local spec = simpleSpec()
    local field = { name = "direction", type = "Vector2F32" }
    for key, value in bounds do field[key] = value end
    spec.events.Ping.fields = { field }
    assertInvalid(spec, "invalid Vector2 bounds or keys")
end

local previousStringDescriptor
for _, maximumBytes in { 0, -1 / math.huge, 4, 1_024 } do
    local spec = simpleSpec()
    spec.events.Ping.fields = { { name = "text", type = "string", maximumBytes = maximumBytes } }
    local _, compiled = assertValid(spec, "bounded byte string")
    local field = compiled.events.Ping.fields[1]
    assert(field.maximumBytes == maximumBytes and countKeys(field) == 7, "compiled string byte limit and metadata")
    assert(table.isfrozen(field), "compiled string immutable")
    local token = string.format("%.0f", if maximumBytes == 0 then 0 else maximumBytes)
    assert(compiled.descriptor == `RR1|D4:Test|V1|N1|E1,C,4:Ping,1|F4:text,str,-,{token}`, "string descriptor golden")
    if maximumBytes > 0 then assert(compiled.descriptor ~= previousStringDescriptor, "string limits affect descriptor") end
    previousStringDescriptor = compiled.descriptor
end
for _, bounds in { {}, { maximumBytes = -1 }, { maximumBytes = 1_025 }, { maximumBytes = 0.5 },
    { maximumBytes = math.huge }, { maximumBytes = -math.huge }, { maximumBytes = 0 / 0 },
    { maximumBytes = "4" }, { maximumBytes = false }, { maximumBytes = 4, minimum = 0 },
    { maximumBytes = 4, maximum = 4 }, { maximumBytes = 4, extra = true } } do
    local spec = simpleSpec()
    local field = { name = "text", type = "string" }
    for key, value in bounds do field[key] = value end
    spec.events.Ping.fields = { field }
    assertInvalid(spec, "invalid string limit or keys")
end

local cframeSpec = simpleSpec()
cframeSpec.events.Ping.fields = { { name = "pose", type = "CFrame", minimum = -1024, maximum = 1024 } }
local _, cframeCompiled = assertValid(cframeSpec, "CFrame bounds")
assert(cframeCompiled.descriptor == "RR1|D4:Test|V1|N1|E1,C,4:Ping,1|F4:pose,cf1,c4800000,44800000",
    "CFrame versioned descriptor golden")
for _, bounds in { {}, { minimum = -1 }, { maximum = 1 }, { minimum = 0.1, maximum = 1 },
    { minimum = -1, maximum = 0.1 }, { minimum = -math.huge, maximum = 1 },
    { minimum = -1, maximum = math.huge }, { minimum = 0 / 0, maximum = 1 },
    { minimum = 2, maximum = 1 }, { minimum = "0", maximum = 1 },
    { minimum = -1, maximum = 1, epsilon = 0.001 } } do
    local spec = simpleSpec()
    local field = { name = "pose", type = "CFrame" }
    for key, value in bounds do field[key] = value end
    spec.events.Ping.fields = { field }
    assertInvalid(spec, "invalid CFrame bounds or keys")
end
cframeSpec.events.Ping.fields[1].maximum = 512
local _, changedCFrame = assertValid(cframeSpec, "changed CFrame translation bound")
assert(changedCFrame.descriptor ~= cframeCompiled.descriptor, "CFrame bounds affect descriptor")

local function compositeSpec()
    return {
        name = "Test",
        version = 1,
        events = {
            Ping = {
                id = 1,
                direction = "ClientToServer",
                fields = {
                    {
                        name = "state",
                        type = "struct",
                        fields = {
                            { name = "mode", type = "enum", values = { "Idle", "Run" } },
                            { name = "flags", type = "set", maximumSize = 4, element = { type = "boolean" } },
                            { name = "samples", type = "array", maximumLength = 2,
                                element = { type = "u16", minimum = 0, maximum = 100 } },
                            { name = "note", type = "optional", value = { type = "string", maximumBytes = 8 } },
                        },
                    },
                    { name = "marker", type = "optional", value = { type = "boolean" } },
                },
            },
        },
    }
end

local compositeSource = compositeSpec()
local compositeToken, compositeCompiled = assertValid(compositeSource, "composable schema")
local compositeEvent = compositeCompiled.byId[1]
assert(compositeCompiled.descriptor
    == "RR3|D4:Test|V1|N1|E1,C,R,4:Ping,2F5:state=T4[F4:mode=E2[4:Idle3:Run]F5:flags=S4[P1:b[-,-]]"
        .. "F7:samples=A2[P3:u16[0,100]]F4:note=O[P3:str[-,8]]]"
        .. "F6:marker=O[P1:b[-,-]]",
    "RR3 recursive descriptor golden changed")
assert(compositeEvent.usesCodec, "composite event must select the codec path")
assert(compositeEvent.minimumEncodedBytes == 10 and compositeEvent.maximumEncodedBytes == 29,
    "event encoded-size bounds must sum fields and include the header")
assert(compositeEvent.maximumElements == 14, "event expanded-node maximum changed")
local stateShape = compositeEvent.fields[1]
assert(stateShape.maximumDepth == 2 and stateShape.maximumElements == 12,
    "struct depth and expanded-node bounds changed")
assert(stateShape.minimumEncodedBytes == 6 and stateShape.maximumEncodedBytes == 24,
    "struct encoded-size bounds changed")
assert(stateShape.fields[2].element.type == "boolean" and stateShape.fields[2].element.name == nil,
    "set child must compile as an anonymous shape")
assert(stateShape.fields[3].maximumLength == 2 and stateShape.fields[3].element.name == nil,
    "array child and capacity must be retained")
assert(stateShape.fields[4].value.type == "string" and stateShape.fields[4].value.name == nil,
    "optional child must compile as an anonymous shape")
assert(table.isfrozen(stateShape.fields[1].values), "enum values must be frozen")

local changedComposite = compositeSpec()
changedComposite.events.Ping.fields[1].fields[1].values = { "Run", "Idle" }
local _, changedCompositeCompiled = assertValid(changedComposite, "changed enum order")
assert(changedCompositeCompiled.descriptor ~= compositeCompiled.descriptor,
    "enum ordinal order must affect RR3 descriptor")

changedComposite = compositeSpec()
changedComposite.events.Ping.fields[1].fields[3].maximumLength = 3
local _, changedCapacityCompiled = assertValid(changedComposite, "changed array capacity")
assert(changedCapacityCompiled.descriptor ~= compositeCompiled.descriptor,
    "array capacity must affect RR3 descriptor")

local compositeDescriptor = compositeCompiled.descriptor
compositeSource.events.Ping.fields[1].fields[1].values[1] = "Changed"
compositeSource.events.Ping.fields[1].fields[3].maximumLength = 9
assert(Definition.get(compositeToken) == compositeCompiled, "composite token must retain its compiled record")
assert(compositeCompiled.descriptor == compositeDescriptor, "source mutations must not alter RR3 metadata")
assert(compositeEvent.fields[1].fields[1].values[1] == "Idle", "source mutation must not alter enum values")

local mixedCodecSpec = compositeSpec()
mixedCodecSpec.events.Pong = {
    id = 2,
    direction = "ServerToClient",
    fields = { { name = "count", type = "u8" } },
}
local _, mixedCodecCompiled = assertValid(mixedCodecSpec, "primitive event in RR3 definition")
assert(mixedCodecCompiled.byId[1].usesCodec and mixedCodecCompiled.byId[2].usesCodec == false,
    "RR3 definition must preserve per-event native fast paths")
assert(string.find(mixedCodecCompiled.descriptor, "|E2,S,R,4:Pong,1F5:count=P2:u8[0,255]", 1, true) ~= nil,
    "RR3 must include delivery and scalar schema tokens for every event")

local function specWithField(field)
    local spec = simpleSpec()
    spec.events.Ping.fields = { field }
    return spec
end

local invalidShapes = {
    { label = "struct extra key", field = { name = "value", type = "struct", fields = {}, extra = true } },
    { label = "array extra key", field = { name = "value", type = "array", element = { type = "boolean" }, maximumLength = 1, extra = true } },
    { label = "enum extra key", field = { name = "value", type = "enum", values = { "A" }, extra = true } },
    { label = "optional extra key", field = { name = "value", type = "optional", value = { type = "boolean" }, extra = true } },
    { label = "set extra key", field = { name = "value", type = "set", element = { type = "boolean" }, maximumSize = 1, extra = true } },
    { label = "named anonymous array child", field = { name = "value", type = "array", maximumLength = 1,
        element = { name = "item", type = "boolean" } } },
    { label = "direct optional array child", field = { name = "value", type = "array", maximumLength = 1,
        element = { type = "optional", value = { type = "boolean" } } } },
    { label = "nested optional", field = { name = "value", type = "optional",
        value = { type = "optional", value = { type = "boolean" } } } },
    { label = "unsupported set child", field = { name = "value", type = "set", maximumSize = 1,
        element = { type = "f32", minimum = 0, maximum = 1 } } },
    { label = "composite set child", field = { name = "value", type = "set", maximumSize = 1,
        element = { type = "array", maximumLength = 1, element = { type = "boolean" } } } },
    { label = "duplicate struct field names", field = { name = "value", type = "struct", fields = {
        { name = "same", type = "boolean" }, { name = "same", type = "u8" },
    } } },
    { label = "duplicate enum values", field = { name = "value", type = "enum", values = { "Idle", "Idle" } } },
    { label = "empty enum", field = { name = "value", type = "enum", values = {} } },
    { label = "oversized enum literal", field = { name = "value", type = "enum", values = { string.rep("X", 33) } } },
    { label = "sparse enum values", field = { name = "value", type = "enum", values = { [1] = "A", [3] = "C" } } },
    { label = "array child metatable", field = { name = "value", type = "array", maximumLength = 1,
        element = setmetatable({ type = "boolean" }, {}) } },
}

for _, invalid in invalidShapes do
    assertInvalid(specWithField(invalid.field), invalid.label)
end

for _, capacity in { -1, 0.5, 65, math.huge, "1" } do
    assertInvalid(specWithField({ name = "items", type = "array", maximumLength = capacity,
        element = { type = "boolean" } }), "invalid array length")
    assertInvalid(specWithField({ name = "items", type = "set", maximumSize = capacity,
        element = { type = "boolean" } }), "invalid set size")
end

for _, values in {
    setmetatable({ "A" }, {}),
    { [1] = "A", [2] = "B", [34] = "C" },
    (function()
        local result = {}
        for index = 1, 33 do result[index] = `Value{index}` end
        return result
    end)(),
} do
    assertInvalid(specWithField({ name = "mode", type = "enum", values = values }), "invalid enum values list")
end

local cycleShape = { name = "node", type = "struct", fields = {} }
cycleShape.fields[1] = cycleShape
assertInvalid(specWithField(cycleShape), "cyclic composite schema")

local function arrayLayer(element)
    return { type = "array", maximumLength = 0, element = element }
end

local depthFour = { type = "boolean" }
for _ = 1, 3 do depthFour = arrayLayer(depthFour) end
local depthFourSpec = specWithField({ name = "deep", type = "array", maximumLength = 0, element = depthFour })
local _, depthFourCompiled = assertValid(depthFourSpec, "maximum schema depth")
assert(depthFourCompiled.events.Ping.fields[1].maximumDepth == 4, "schema depth limit must include four composites")

local depthFive = arrayLayer(depthFour)
assertInvalid(specWithField({ name = "deep", type = "array", maximumLength = 0, element = depthFive }),
    "excessive schema depth")

assertInvalid(specWithField({ name = "items", type = "array", maximumLength = 64,
    element = { type = "array", maximumLength = 64, element = { type = "struct", fields = {} } } }),
    "excessive expanded element count with zero-byte children")
assertInvalid(specWithField({ name = "items", type = "array", maximumLength = 64,
    element = { type = "string", maximumBytes = 1_024 } }), "excessive encoded byte bound")

local function zeroExpandedTree(rootName)
    local branches = {}
    for branch = 1, 8 do
        local leaves = {}
        for leaf = 1, 8 do
            leaves[leaf] = { name = `leaf{leaf}`, type = "array", maximumLength = 0,
                element = { type = "boolean" } }
        end
        branches[branch] = { name = `branch{branch}`, type = "array", maximumLength = 0,
            element = { type = "struct", fields = leaves } }
    end
    return { name = rootName, type = "struct", fields = branches }
end

local excessiveAuthoredNodes = simpleSpec()
excessiveAuthoredNodes.events.Ping.fields = { zeroExpandedTree("first"), zeroExpandedTree("second") }
assertInvalid(excessiveAuthoredNodes, "authored-node occurrence limit with zero capacity")

local sharedChild = { type = "boolean" }
local sharedSchema = specWithField({ name = "record", type = "struct", fields = {
    { name = "first", type = "array", maximumLength = 0, element = sharedChild },
    { name = "second", type = "array", maximumLength = 0, element = sharedChild },
} })
local _, sharedCompiled = assertValid(sharedSchema, "shared acyclic schema child")
assert(sharedCompiled.events.Ping.fields[1].fields[1].element ~= sharedCompiled.events.Ping.fields[1].fields[2].element,
    "shared source nodes must compile into independent records")

local maximumArray = specWithField({ name = "items", type = "array", maximumLength = 64,
    element = { type = "boolean" } })
local _, maximumArrayCompiled = assertValid(maximumArray, "maximum bounded array")
assert(maximumArrayCompiled.events.Ping.fields[1].maximumElements == 65,
    "array expanded-node maximum must include its node and capacity")

local maximumEnumValues = {}
for index = 1, 32 do maximumEnumValues[index] = string.format("%02d", index) .. string.rep("x", 30) end
assertValid(specWithField({ name = "mode", type = "enum", values = maximumEnumValues }), "maximum enum values")

local reliableBytes = specWithField({ name = "items", type = "array", maximumLength = 7,
    element = { type = "string", maximumBytes = 1_024 } })
local _, reliableBytesCompiled = assertValid(reliableBytes, "reliable encoded-byte boundary")
assert(reliableBytesCompiled.events.Ping.maximumEncodedBytes == 7_187,
    "reliable encoded-byte limit calculation changed")

local unreliableBytes = simpleSpec()
unreliableBytes.events.Ping.delivery = "Unreliable"
unreliableBytes.events.Ping.fields = { { name = "items", type = "array", maximumLength = 1,
    element = { type = "string", maximumBytes = 893 } } }
local _, unreliableBytesCompiled = assertValid(unreliableBytes, "unreliable encoded-byte boundary")
assert(unreliableBytesCompiled.events.Ping.maximumEncodedBytes == 900,
    "unreliable encoded-byte limit must include the header")

assertInvalid(specWithField({ name = "items", type = "array", maximumLength = 8,
    element = { type = "string", maximumBytes = 1_024 } }), "reliable encoded-byte limit")

local tooManyUnreliableBytes = simpleSpec()
tooManyUnreliableBytes.events.Ping.delivery = "Unreliable"
tooManyUnreliableBytes.events.Ping.fields = { { name = "items", type = "array", maximumLength = 1,
    element = { type = "string", maximumBytes = 894 } } }
assertInvalid(tooManyUnreliableBytes, "unreliable encoded-byte limit")

local legacyLongStrings = simpleSpec()
legacyLongStrings.events.Ping.fields = {}
for index = 1, 8 do
    legacyLongStrings.events.Ping.fields[index] = { name = `text{index}`, type = "string", maximumBytes = 1_024 }
end
local _, legacyLongStringsCompiled = assertValid(legacyLongStrings, "native primitive byte contract")
assert(not legacyLongStringsCompiled.events.Ping.usesCodec
    and legacyLongStringsCompiled.events.Ping.maximumEncodedBytes == 8_211,
    "native primitive tuples must not use codec byte caps")

for _, code in {
    "InvalidDefinition", "InvalidOptions", "WrongRuntimeSide", "AlreadyStarted", "NotStarted",
    "Destroyed", "AlreadyConnected", "InvalidHandler", "InvalidPayload", "InvalidPlayer",
    "StartupTimeout", "RemoteOwnershipConflict", "DefinitionMismatch", "Disconnected", "TransportFailure",
} do
    local result = Definition.error(code)
    assert(result.code == code and countKeys(result) == 2 and table.isfrozen(result), "fixed error shape changed")
    assert(Definition.error(code) == result, "errors must not allocate per rejected frame")
end

local firstOrder = {
    name = "Ordering",
    version = 9,
    events = {},
}
firstOrder.events.Second = emptyEvent(20, "ServerToClient")
firstOrder.events.First = emptyEvent(2, "ClientToServer")

local secondOrder = {
    name = "Ordering",
    version = 9,
    events = {},
}
secondOrder.events.First = emptyEvent(2, "ClientToServer")
secondOrder.events.Second = emptyEvent(20, "ServerToClient")

local _, firstOrderCompiled = assertValid(firstOrder, "first event insertion order")
local _, secondOrderCompiled = assertValid(secondOrder, "second event insertion order")
assert(firstOrderCompiled.descriptor == secondOrderCompiled.descriptor, "event iteration order must not affect descriptor")
assert(
    firstOrderCompiled.descriptor
        == "RR1|D8:Ordering|V9|N2|E2,C,5:First,0|E20,S,6:Second,0",
    "event ID ordering descriptor golden changed"
)

local function semanticSpec()
    return {
        name = "Semantic",
        version = 1,
        events = {
            Change = {
                id = 1,
                direction = "ClientToServer",
                fields = {
                    { name = "first", type = "u8", minimum = 1, maximum = 2 },
                    { name = "second", type = "boolean" },
                },
            },
        },
    }
end

local _, semanticBaseline = assertValid(semanticSpec(), "semantic descriptor baseline")
local semanticVariations = {
    function(spec) spec.name = "Semantic2" end,
    function(spec) spec.version = 2 end,
    function(spec)
        spec.events.Renamed = spec.events.Change
        spec.events.Change = nil
    end,
    function(spec) spec.events.Change.id = 2 end,
    function(spec) spec.events.Change.direction = "ServerToClient" end,
    function(spec) spec.events.Change.fields[1].name = "renamed" end,
    function(spec) spec.events.Change.fields[1].type = "u16" end,
    function(spec) spec.events.Change.fields[1].minimum = 0 end,
    function(spec) spec.events.Change.fields[1].maximum = 3 end,
    function(spec)
        local fields = spec.events.Change.fields
        fields[1], fields[2] = fields[2], fields[1]
    end,
}

for index, mutate in semanticVariations do
    local spec = semanticSpec()
    mutate(spec)
    local _, compiled = assertValid(spec, `semantic descriptor variation {index}`)
    assert(compiled.descriptor ~= semanticBaseline.descriptor, `semantic variation {index} must change descriptor`)
end

local structuralLimits = {
    name = string.rep("D", 32),
    version = 2_147_483_647,
    events = {},
}

for index = 1, 16 do
    local id = index

    if index == 16 then
        id = 65_535
    end

    structuralLimits.events[`Event{index}`] = emptyEvent(id)
end


structuralLimits.events.Event1.fields = {}
for index = 1, 8 do
    structuralLimits.events.Event1.fields[index] = { name = `field{index}`, type = "boolean" }
end
assertValid(structuralLimits, "accepted structural maxima")

local sourceField = { name = "value", type = "u16", minimum = 1, maximum = 10 }
local sourceFields = { sourceField }
local sourceEvent = { id = 3, direction = "ClientToServer", fields = sourceFields }
local sourceEvents = { Change = sourceEvent }
local sourceSpec = { name = "Copy", version = 2, events = sourceEvents }
local sourceToken, sourceCompiled = assertValid(sourceSpec, "copy isolation")
local sourceDescriptor = sourceCompiled.descriptor

assert(rawget(sourceSpec, "descriptor") == nil, "define must not mutate the source definition")
assert(countKeys(sourceField) == 4, "define must not mutate source field shape")

sourceSpec.name = "Mutated"
sourceSpec.version = 99
sourceEvent.id = 99
sourceEvent.direction = "ServerToClient"
sourceField.name = "mutated"
sourceField.minimum = 5
sourceFields[1] = { name = "replacement", type = "boolean" }
sourceEvents.Change = nil

local resolvedAfterMutation = Definition.get(sourceToken)
assert(resolvedAfterMutation == sourceCompiled, "token must keep the same compiled record")
assert(resolvedAfterMutation.descriptor == sourceDescriptor, "source mutation must not alter compiled descriptor")
assert(resolvedAfterMutation.byId[3].fields[1].name == "value", "source mutation must not alter fields")

local compiledMutationSucceeded = pcall(function()
    resolvedAfterMutation.byId[3].fields[1].minimum = 2
end)
assert(not compiledMutationSucceeded, "compiled nested records must reject mutation")

local retainedToken
local sourceWitness = setmetatable({}, { __mode = "k" })

local function compileWitnessedSource()
    local field = { name = "value", type = "u8" }
    local fields = { field }
    local event = { id = 1, direction = "ClientToServer", fields = fields }
    local events = { Ping = event }
    local spec = { name = "Witness", version = 1, events = events }

    sourceWitness[field] = true
    sourceWitness[fields] = true
    sourceWitness[event] = true
    sourceWitness[events] = true
    sourceWitness[spec] = true

    retainedToken = assertValid(spec, "source retention witness")
end

compileWitnessedSource()
forceCollection()
assert(next(sourceWitness) == nil, "compiled definition must retain no author table")
assert(Definition.get(retainedToken) ~= nil, "source collection must not invalidate the token")

local tokenWitness = setmetatable({}, { __mode = "k" })

local function createUnretainedToken()
    local token = assertValid(simpleSpec(), "token GC witness")
    tokenWitness[token] = true
end

createUnretainedToken()
forceCollection()
assert(next(tokenWitness) == nil, "weak registry value must not retain its token key")

assertInvalid(nil, "nil definition")
assertInvalid("definition", "non-table definition")
assertInvalid({}, "empty root")
assertInvalid({ name = "Test", version = 1, events = {}, extra = true }, "extra root key")
assertInvalid(setmetatable(simpleSpec(), {}), "root metatable")

for _, invalidName in { "", "_Name", "9Name", "Bad-Name", string.rep("A", 33), "évent" } do
    local spec = simpleSpec()
    spec.name = invalidName
    assertInvalid(spec, "invalid definition name")
end

for _, invalidVersion in { 0, -1, 1.5, 2_147_483_648, math.huge, -math.huge, 0 / 0, "1" } do
    local spec = simpleSpec()
    spec.version = invalidVersion
    assertInvalid(spec, "invalid version")
end

local frozenSpec = simpleSpec()
table.freeze(frozenSpec.events.Ping.fields)
table.freeze(frozenSpec.events.Ping)
table.freeze(frozenSpec.events)
table.freeze(frozenSpec)
assertValid(frozenSpec, "frozen author tables")

local zeroEvents = simpleSpec()
zeroEvents.events = {}
assertInvalid(zeroEvents, "zero events")

local eventMapMetatable = simpleSpec()
eventMapMetatable.events = setmetatable({}, {})
assertInvalid(eventMapMetatable, "event map metatable")

local numericEventKey = simpleSpec()
numericEventKey.events = { [1] = emptyEvent() }
assertInvalid(numericEventKey, "numeric event name")

local badEventName = simpleSpec()
badEventName.events = { ["Bad-Event"] = emptyEvent() }
assertInvalid(badEventName, "invalid event name")

local tooManyEvents = simpleSpec()
tooManyEvents.events = {}
for index = 1, 17 do
    tooManyEvents.events[`Event{index}`] = emptyEvent(index)
end
assertInvalid(tooManyEvents, "too many events")

local duplicateIds = simpleSpec()
duplicateIds.events.Other = emptyEvent(1, "ServerToClient")
assertInvalid(duplicateIds, "duplicate event IDs")

for _, invalidId in { 0, -1, 1.5, 65_536, math.huge, "1" } do
    local spec = simpleSpec()
    spec.events.Ping.id = invalidId
    assertInvalid(spec, "invalid event ID")
end

for _, invalidDirection in { "C", "Server", "clienttoserver", 1, false } do
    local spec = simpleSpec()
    spec.events.Ping.direction = invalidDirection
    assertInvalid(spec, "invalid event direction")
end

local extraEventKey = simpleSpec()
extraEventKey.events.Ping.extra = true
assertInvalid(extraEventKey, "extra event key")

local eventMetatable = simpleSpec()
eventMetatable.events.Ping = setmetatable(emptyEvent(), {})
assertInvalid(eventMetatable, "event metatable")

local cyclicEvent = simpleSpec()
cyclicEvent.events.Ping = cyclicEvent
assertInvalid(cyclicEvent, "cyclic event shape")

local fieldsMetatable = simpleSpec()
fieldsMetatable.events.Ping.fields = setmetatable({}, {})
assertInvalid(fieldsMetatable, "fields metatable")

local sparseFields = simpleSpec()
sparseFields.events.Ping.fields = {
    [1] = { name = "first", type = "boolean" },
    [3] = { name = "third", type = "boolean" },
}
assertInvalid(sparseFields, "sparse fields")

local reverseDenseFields = simpleSpec()
reverseDenseFields.events.Ping.fields = {}
reverseDenseFields.events.Ping.fields[2] = { name = "second", type = "boolean" }
reverseDenseFields.events.Ping.fields[1] = { name = "first", type = "boolean" }
local _, reverseDenseCompiled = assertValid(reverseDenseFields, "reverse-inserted dense fields")
assert(reverseDenseCompiled.byId[1].fields[1].name == "first"
    and reverseDenseCompiled.byId[1].fields[2].name == "second",
    "reverse insertion must preserve dense field order")

local zeroFieldIndex = simpleSpec()
zeroFieldIndex.events.Ping.fields = { [0] = { name = "bad", type = "boolean" } }
assertInvalid(zeroFieldIndex, "zero field index")

local namedFieldIndex = simpleSpec()
namedFieldIndex.events.Ping.fields = { bad = { name = "bad", type = "boolean" } }
assertInvalid(namedFieldIndex, "named field index")

local tooManyFields = simpleSpec()
tooManyFields.events.Ping.fields = {}
for index = 1, 9 do
    tooManyFields.events.Ping.fields[index] = { name = `field{index}`, type = "boolean" }
end
assertInvalid(tooManyFields, "too many fields")

local duplicateFieldNames = simpleSpec()
duplicateFieldNames.events.Ping.fields = {
    { name = "same", type = "boolean" },
    { name = "same", type = "u8" },
}
assertInvalid(duplicateFieldNames, "duplicate field names")

local fieldMetatable = simpleSpec()
fieldMetatable.events.Ping.fields = { setmetatable({ name = "value", type = "u8" }, {}) }
assertInvalid(fieldMetatable, "field metatable")

local extraFieldKey = simpleSpec()
extraFieldKey.events.Ping.fields = { { name = "value", type = "u8", extra = true } }
assertInvalid(extraFieldKey, "extra field key")

local booleanBounds = simpleSpec()
booleanBounds.events.Ping.fields = { { name = "flag", type = "boolean", minimum = 0 } }
assertInvalid(booleanBounds, "boolean bounds")

local unsupportedField = simpleSpec()
unsupportedField.events.Ping.fields = { { name = "value", type = "unknown" } }
assertInvalid(unsupportedField, "unsupported field type")

for _, invalidFieldType in { 0 / 0, 1, false, {} } do
    local spec = simpleSpec()
    spec.events.Ping.fields = { { name = "value", type = invalidFieldType } }
    assertInvalid(spec, "non-string field type")
end

for _, invalidFieldName in { "", "_field", "field-name", string.rep("F", 33) } do
    local spec = simpleSpec()
    spec.events.Ping.fields = { { name = invalidFieldName, type = "u8" } }
    assertInvalid(spec, "invalid field name")
end

local unsignedBoundCases = {
    { name = "negative minimum", field = { name = "value", type = "u8", minimum = -1 } },
    { name = "maximum above base", field = { name = "value", type = "u8", maximum = 256 } },
    { name = "fractional minimum", field = { name = "value", type = "u16", minimum = 0.5 } },
    { name = "string maximum", field = { name = "value", type = "u32", maximum = "10" } },
    { name = "unordered bounds", field = { name = "value", type = "u16", minimum = 2, maximum = 1 } },
    { name = "infinite bound", field = { name = "value", type = "u32", maximum = math.huge } },
}

for _, case in unsignedBoundCases do
    local spec = simpleSpec()
    spec.events.Ping.fields = { case.field }
    assertInvalid(spec, case.name)
end

local floatBoundCases = {
    { name = "missing float minimum", field = { name = "value", type = "f32", maximum = 1 } },
    { name = "missing float maximum", field = { name = "value", type = "f32", minimum = 0 } },
    { name = "non-exact float minimum", field = { name = "value", type = "f32", minimum = 0.1, maximum = 1 } },
    { name = "NaN float bound", field = { name = "value", type = "f32", minimum = 0 / 0, maximum = 1 } },
    { name = "infinite float bound", field = { name = "value", type = "f32", minimum = 0, maximum = math.huge } },
    { name = "unordered float bounds", field = { name = "value", type = "f32", minimum = 2, maximum = 1 } },
    { name = "missing vector minimum", field = { name = "value", type = "Vector3F32", maximum = 1 } },
    { name = "non-exact vector maximum", field = { name = "value", type = "Vector3F32", minimum = 0, maximum = 0.1 } },
}

for _, case in floatBoundCases do
    local spec = simpleSpec()
    spec.events.Ping.fields = { case.field }
    assertInvalid(spec, case.name)
end

local oversizedDescriptor = {
    name = string.rep("D", 32),
    version = 1,
    events = {},
}

for eventIndex = 1, 16 do
    local eventName = `E{string.format("%02d", eventIndex)}{string.rep("_", 29)}`
    local fields = {}

    for fieldIndex = 1, 8 do
        fields[fieldIndex] = {
            name = `F{fieldIndex}{string.rep("_", 30)}`,
            type = "u32",
        }
    end

    oversizedDescriptor.events[eventName] = {
        id = eventIndex,
        direction = "ClientToServer",
        fields = fields,
    }
end

assertInvalid(oversizedDescriptor, "descriptor over 4096 bytes")

assert(Definition.get(simpleToken) == simpleCompiled, "earlier tokens must remain stable")

print("PASS Relay.ReliableEvents.Definition")
