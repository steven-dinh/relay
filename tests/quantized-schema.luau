local Definition = require("../src/Definition")

local function field(shape, name)
    local result = table.clone(shape)
    result.name = name or "value"
    return result
end
local function quantized(minimum, maximum, step)
    return { type = "quantized", minimum = minimum, maximum = maximum, step = step }
end
local function spec(shape, delivery, queue)
    return { name = "QuantizedSchema", version = 1, events = { Input = {
        id = 1, direction = "ClientToServer", delivery = delivery, queue = queue,
        fields = { field(shape) },
    } } }
end
local function valid(source)
    local token, issue = Definition.define(source)
    assert(token, issue and issue.message)
    return Definition.get(token), token
end
local function invalid(source, message)
    local token, issue = Definition.define(source)
    assert(token == nil and issue and issue.code == "InvalidDefinition", "expected InvalidDefinition")
    if message then assert(string.find(issue.message, message, 1, true), issue.message) end
end

local compiled, token = valid(spec(quantized(-1, 1, 0.01)))
local event = compiled.events.Input
assert(event.usesCodec and event.minimumEncodedBytes == 4 and event.maximumEncodedBytes == 4)
assert(event.maximumElements == 1 and event.fields[1].maximumDepth == 0)
assert(event.fields[1].maximumIndex == 200 and not event.fields[1].native)
assert(table.isfrozen(event.fields[1]) and event.fields[1].maximumError >= 0.005)
assert(string.match(compiled.descriptor, "^RR10|D") and string.find(compiled.descriptor, "|Q1,65536", 1, true))
local report = assert(Definition.inspect(token))
assert(report.protocol == "RR10" and report.limits.quantizedLevels == 65536
    and report.events.Input.bytes.minimum == 4 and report.events.Input.bytes.maximum == 4)
for _, sample in {
    { 0, 255, 1, 1 }, { 0, 256, 1, 2 }, { 0, 65535, 1, 2 },
    { 0.1, 0.3, 0.1, 1 }, { 0.1, 0.1001, 0.0001, 1 },
} do
    local result = valid(spec(quantized(sample[1], sample[2], sample[3])))
    assert(result.events.Input.maximumEncodedBytes == 3 + sample[4])
end
for _, sample in {
    { 0, 65536, 1 }, { 0, 1, 0.3 }, { 1, 1, 0.1 }, { 1, 0, 0.1 },
    { 0, 1, 0 }, { 0, 1, -1 }, { 0, 1, 2 ^ -1074 },
    { -1e308, 1e308, 1e308 }, { 1e16, 1e16 + 2, 1 },
} do invalid(spec(quantized(sample[1], sample[2], sample[3]))) end
for _, value in { 0/0, math.huge, -math.huge, "1", true, {} } do
    invalid(spec(quantized(value, 1, 0.01)))
    invalid(spec(quantized(0, value, 0.01)))
    invalid(spec(quantized(0, 1, value)))
end
local missing = quantized(0, 1, 0.1)
missing.step = nil
invalid(spec(missing))
local extra = quantized(0, 1, 0.1)
extra.rounding = "Clamp"
invalid(spec(extra), "unknown key")
local invoked = false
invalid(spec(setmetatable(quantized(0, 1, 0.1), { __iter = function() invoked = true end })))
assert(not invoked)
invalid(spec({ type = "set", element = quantized(0, 1, 0.1), maximumSize = 1 }), "set elements")
invalid(spec({ type = "map", key = quantized(0, 1, 0.1), value = { type = "boolean" }, maximumSize = 1 }), "map keys")

local zero = { type = "array", maximumLength = 0, element = quantized(0, 1, 0.1) }
local empty = valid(spec(zero))
assert(string.match(empty.descriptor, "^RR10|") and empty.events.Input.maximumEncodedBytes == 5,
    "authored quantized children select RR10 even at zero capacity")
local nested = quantized(0, 1, 0.1)
for _ = 1, 4 do nested = { type = "array", maximumLength = 1, element = nested } end
assert(valid(spec(nested)).events.Input.fields[1].maximumDepth == 4)
invalid(spec({ type = "array", maximumLength = 1, element = nested }), "depth")

for _, delivery in { "Reliable", "Unreliable", "OrderedUnreliable" } do
    local result = valid(spec(quantized(-1, 1, 0.01), delivery))
    assert(result.events.Input.maximumEncodedBytes == (if delivery == "OrderedUnreliable" then 12 else 4))
end
for _, queue in { "Batch", "State" } do
    local result = valid(spec(quantized(-1, 1, 0.01), "Unreliable", queue))
    assert(result.queuedById[1].maximumEncodedBytes == 4)
end
local function requestSpec(request, response)
    return { name = "QuantizedRpc", version = 1, events = {}, requests = {
        Lookup = { id = 1, request = { field(request) }, response = response },
    } }
end
for _, source in {
    requestSpec(quantized(0, 256, 1), { type = "boolean" }),
    requestSpec({ type = "boolean" }, quantized(-1, 1, 0.01)),
    requestSpec(zero, { type = "boolean" }),
} do
    assert(string.match(valid(source).descriptor, "^RR10|"), "request/response-only quantization selects RR10")
end
local mixed = spec(quantized(-1, 1, 0.01))
mixed.events.Input.fields[2] = field({ type = "Instance", className = "Part" }, "target")
local withReferences = valid(mixed)
assert(withReferences.hasReferences and withReferences.events.Input.maximumEncodedBytes == 6
    and withReferences.events.Input.maximumAdmissionBytes == 14
    and string.find(withReferences.descriptor, "|I4,16,8", 1, true), "RR10 retains reference framing and admission")
mixed.events.Input.delivery = "Unreliable"
invalid(mixed, "reliable immediate events")

local function sized(padding, delivery)
    local source = spec(quantized(0, 1, 0.01), delivery)
    source.events.Input.fields[2] = field({ type = "string", maximumBytes = padding }, "padding")
    return source
end
assert(valid(sized(894, "Unreliable")).events.Input.maximumEncodedBytes == 900)
invalid(sized(895, "Unreliable"), "900")
assert(valid(sized(886, "OrderedUnreliable")).events.Input.maximumEncodedBytes == 900)
invalid(sized(887, "OrderedUnreliable"), "900")
local large = spec(quantized(0, 1, 0.01))
large.events.Input.fields[2] = field({ type = "array", maximumLength = 7,
    element = { type = "string", maximumBytes = 1024 } }, "chunks")
large.events.Input.fields[3] = field({ type = "string", maximumBytes = 1002 }, "padding")
assert(valid(large).events.Input.maximumEncodedBytes == 8192)
large.events.Input.fields[3].maximumBytes = 1003
invalid(large, "8192")

local old = valid(spec({ type = "f32", minimum = -1, maximum = 1 }))
assert(string.match(old.descriptor, "^RR1|") and not old.events.Input.usesCodec)
local oldInstance = valid(spec({ type = "Instance", className = "Part" }))
assert(string.match(oldInstance.descriptor, "^RR9|"), "quantized compilation must not contaminate later definitions")
local shifted = valid(spec(quantized(-1, 1, 0.02)))
assert(shifted.descriptor ~= compiled.descriptor, "declared precision is part of definition identity")
local positiveZero = valid(spec(quantized(0, 1, 0.1)))
local negativeZero = valid(spec(quantized(-1/math.huge, 1, 0.1)))
assert(positiveZero.descriptor == negativeZero.descriptor, "zero signs canonicalize in exact f64 identity")
print("PASS bounded scalar quantization schemas, RR10, routes, and byte limits")
