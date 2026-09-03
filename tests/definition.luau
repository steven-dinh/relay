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
assert(countKeys(simpleCompiled) == 5, "compiled definition must have exactly five keys")
assert(countKeys(simpleCompiled.byId) == 1, "compiled definition must contain one event")
assert(simpleCompiled.name == "Test" and simpleCompiled.version == 1, "compiled definition identity changed")
assert(simpleCompiled.events.Ping == simpleCompiled.byId[1], "name and ID must resolve the same compiled event")
assert(simpleCompiled.events.Ping.id == 1, "compiled event ID changed")
assert(simpleCompiled.byId[1].name == "Ping", "compiled event name changed")
assert(simpleCompiled.byId[1].direction == "ClientToServer", "compiled event direction changed")
assert(#simpleCompiled.byId[1].fields == 0, "empty event fields must remain empty")
assert(Definition.get(table.freeze({})) == nil, "copied empty token must not resolve")
assert(Definition.get({}) == nil, "mutable empty table must not resolve")
assert(Definition.get(nil) == nil, "nil must not resolve")
assert(Definition.get("not a token") == nil, "non-table must not resolve")

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
assert(countKeys(compiledFields[1]) == 2, "boolean compiled field must omit bounds")
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
unsupportedField.events.Ping.fields = { { name = "value", type = "string" } }
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
