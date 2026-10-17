local Definition = require("../src/Definition")
local Refs = require("../src/internal/InstanceRefs")
local function field(shape, name)
    local copy = table.clone(shape)
    copy.name = name or "value"
    return copy
end
local instance = { type = "Instance", className = "BasePart" }
local function make(shape, options)
    options = options or {}
    return { name = "InstanceSchema", version = 1, events = { Input = {
        id = 1, direction = "ClientToServer", fields = { field(shape) },
        delivery = options.delivery, queue = options.queue,
    } } }
end
local function valid(spec)
    local token, issue = Definition.define(spec)
    assert(token, issue and issue.message)
    return Definition.get(token), token
end
local function invalid(spec, reason)
    local token, issue = Definition.define(spec)
    assert(token == nil and issue and issue.code == "InvalidDefinition", "expected InvalidDefinition")
    if reason then assert(string.find(issue.message, reason, 1, true), issue.message) end
end
local classCount = 0
for className in Refs.CLASSES do
    classCount += 1
    local compiled, token = valid(make({ type = "Instance", className = className }))
    local event = compiled.events.Input
    assert(compiled.hasReferences and event.hasReferences and event.usesCodec
        and event.maximumReferences == 1 and event.maximumEncodedBytes == 5
        and event.minimumEncodedBytes == 5 and event.maximumAdmissionBytes == 13)
    assert(string.sub(compiled.descriptor, 1, 3) == "RR9"
        and string.find(compiled.descriptor, "|I4,16,8", 1, true))
    local report = assert(Definition.inspect(token))
    assert(report.protocol == "RR9" and report.limits.instanceReferences == 16
        and report.limits.instanceReferenceAdmissionBytes == 8
        and report.events.Input.references.maximumCount == 1
        and report.events.Input.references.maximumAdmissionBytes == 13)
end
assert(classCount == 14, "closed Instance class list")
invalid(make({ type = "Instance", className = "NotAClass" }), "supported Instance class")
invalid(make({ type = "Instance", className = 1 }), "supported Instance class")
invalid(make({ type = "Instance", className = "Part", extra = true }), "unknown key")
local invoked = false
invalid(make(setmetatable(table.clone(instance), { __iter = function() invoked = true end })))
assert(not invoked, "metatables reject before iteration")
local array = { type = "array", element = instance, maximumLength = 16 }
local compiled = valid(make(array))
assert(compiled.events.Input.maximumReferences == 16
    and compiled.events.Input.maximumEncodedBytes == 22
    and compiled.events.Input.maximumAdmissionBytes == 150)
invalid(make({ type = "array", element = instance, maximumLength = 17 }), "reference count exceeds 16")
local manyFields = make(array)
manyFields.events.Input.fields[2] = field(instance, "extra")
invalid(manyFields, "reference count exceeds 16")
local optional = valid(make({ type = "optional", value = instance }))
assert(optional.events.Input.minimumEncodedBytes == 5 and optional.events.Input.maximumEncodedBytes == 6)
local map = { type = "map", key = { type = "string", maximumBytes = 4 }, value = instance, maximumSize = 16 }
assert(valid(make(map)).events.Input.maximumReferences == 16)
invalid(make({ type = "set", element = instance, maximumSize = 1 }), "set elements")
invalid(make({ type = "map", key = instance, value = { type = "boolean" }, maximumSize = 1 }), "map keys")
local union = { type = "taggedUnion", tag = "kind", variants = {
    First = { type = "struct", fields = { field(array) } },
    Second = { type = "struct", fields = { field(instance) } },
} }
assert(valid(make(union)).events.Input.maximumReferences == 16, "union counts max branch, not sum")
local zero = { type = "array", element = instance, maximumLength = 0 }
local zeroCompiled = valid(make(zero))
assert(zeroCompiled.events.Input.hasReferences and zeroCompiled.events.Input.maximumReferences == 0)
for _, shape in { instance, zero, map, union } do
    for _, options in { { delivery = "Unreliable" }, { delivery = "OrderedUnreliable" },
        { queue = "Batch" }, { queue = "State" } } do
        invalid(make(shape, options), "reliable immediate events")
    end
    invalid({ name = "BadRequest", version = 1, events = {}, requests = {
        Lookup = { id = 1, request = { field(shape) }, response = { type = "boolean" } },
    } }, "reliable immediate events")
    invalid({ name = "BadResponse", version = 1, events = {}, requests = {
        Lookup = { id = 1, request = {}, response = shape },
    } }, "reliable immediate events")
end
local nested = instance
for _ = 1, 4 do nested = { type = "array", element = nested, maximumLength = 1 } end
assert(valid(make(nested)).events.Input.fields[1].maximumDepth == 4)
invalid(make({ type = "array", element = nested, maximumLength = 1 }), "depth")
local function byteBoundary(padding)
    local spec = make(instance)
    spec.events.Input.fields = {
        field({ type = "array", element = { type = "string", maximumBytes = 1024 }, maximumLength = 7 }, "chunks"),
        field({ type = "string", maximumBytes = padding }, "padding"), field(instance),
    }
    return spec
end
local byteCompiled = valid(byteBoundary(993))
assert(byteCompiled.events.Input.maximumEncodedBytes == 8184 and byteCompiled.events.Input.maximumAdmissionBytes == 8192)
invalid(byteBoundary(994), "admission size exceeds 8192")
local mixed = make(instance)
mixed.events.Unreliable = { id = 2, direction = "ServerToClient", delivery = "Unreliable", fields = {} }
mixed.events.Queued = { id = 3, direction = "ServerToClient", queue = "Batch", fields = {} }
mixed.requests = { Lookup = { id = 4, request = {}, response = { type = "boolean" } } }
assert(valid(mixed).hasReferences, "non-reference event/request capabilities may coexist")
local old = valid(make({ type = "u8" }))
assert(not old.hasReferences and string.sub(old.descriptor, 1, 3) == "RR1")
print("PASS bounded Instance schemas, routes, descriptors, and admission bounds")
