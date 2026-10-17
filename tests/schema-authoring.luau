local Relay = require("../src")
local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local s = Relay.schema

local function compile(name, events, requests)
	local token, problem = Relay.define({ name = name, version = 1, events = events, requests = requests })
	assert(token, problem and problem.message)
	return Definition.get(token), token
end

local function encoded(compiled, eventName, values)
	local result = table.pack(Frame.compile(compiled.events[eventName], "encode")(table.unpack(values, 1, values.n)))
	assert(result[1], `could not encode {eventName}`)
	return result
end

local function sameEncoding(left, right, label)
	assert(left.n == right.n, `{label} changed encoded result arity`)
	for index = 2, left.n do
		local leftValue, rightValue = left[index], right[index]
		if type(leftValue) == "buffer" then
			assert(type(rightValue) == "buffer" and buffer.tostring(leftValue) == buffer.tostring(rightValue),
				`{label} changed encoded bytes`)
		else
			assert(leftValue == rightValue, `{label} changed encoded tuple value`)
		end
	end
end

local newMode = s.enum({ Idle = 1, Run = 2 })
local oldMode = s.enum("Idle", "Run")
assert(newMode.values[1] == "Idle" and newMode.values[2] == "Run")
local newRecord = s.struct({ id = s.u32() }, { mode = newMode })
local oldRecord = s.struct(s.field("id", s.u32()), s.field("mode", oldMode))
local mixedRecord = s.struct({ id = s.u32() }, s.field("count", s.u16()), { mode = newMode })
local oldMixedRecord = s.struct(s.field("id", s.u32()), s.field("count", s.u16()), s.field("mode", oldMode))
local namedKeyRecord = s.struct({ name = s.u8() }, { type = s.string(8) })
local oldNamedKeyRecord = s.struct(s.field("name", s.u8()), s.field("type", s.string(8)))
local legacyFields = s.fields(s.field("sequence", s.u32()), s.field("enabled", s.boolean()))
assert(newRecord.fields[1].name == "id" and newRecord.fields[2].name == "mode")
assert(mixedRecord.fields[1].name == "id" and mixedRecord.fields[2].name == "count"
	and mixedRecord.fields[3].name == "mode")
assert(s.struct().fields[1] == nil and #s.fields() == 0)
assert(s.struct({ name = s.u8() }, { type = s.string(8) }).fields[1].name == "name",
	"name and type are valid keyed field names")

local newResult = s.taggedUnion({
	kind = {
		Success = s.struct({ value = s.u8() }),
		Failure = s.struct({ reason = s.string(24) }),
	},
})
local oldResult = s.taggedUnion("kind", {
	Success = s.struct(s.field("value", s.u8())),
	Failure = s.struct(s.field("reason", s.string(24))),
})

local newEvents = {
	Input = s.clientToServer(1, s.fields({ sequence = s.u32() }, { enabled = s.boolean() })),
	Unreliable = s.serverToClient(2, s.fields({ value = s.u8() }), { delivery = "Unreliable" }),
	Composite = s.clientToServer(3, s.fields({ record = newRecord }, { result = newResult },
		{ mixed = mixedRecord }, { namedKeys = namedKeyRecord })),
	Ordered = s.serverToClient(4, s.fields({ value = s.u8() }), { delivery = "OrderedUnreliable" }),
	Batch = s.serverToClient(5, s.fields({ result = newResult }), { queue = "Batch" }),
	State = s.serverToClient(6, s.fields({ result = newResult }), { delivery = "Unreliable", queue = "State" }),
	EmptyOptions = s.clientToServer(8, s.fields(), {}),
	LegacyFields = s.clientToServer(9, legacyFields),
}
local oldEvents = {
	Input = { id = 1, direction = "ClientToServer", fields = s.ordered(
		s.field("sequence", s.u32()), s.field("enabled", s.boolean())) },
	Unreliable = s.serverToClient(2, s.ordered(s.field("value", s.u8())), "Unreliable"),
	Composite = { id = 3, direction = "ClientToServer", fields = s.ordered(
		s.field("record", oldRecord), s.field("result", oldResult), s.field("mixed", oldMixedRecord),
		s.field("namedKeys", oldNamedKeyRecord)) },
	Ordered = s.serverToClient(4, s.ordered(s.field("value", s.u8())), "OrderedUnreliable"),
	Batch = { id = 5, direction = "ServerToClient", queue = "Batch",
		fields = s.ordered(s.field("result", oldResult)) },
	State = { id = 6, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
		fields = s.ordered(s.field("result", oldResult)) },
	EmptyOptions = { id = 8, direction = "ClientToServer", fields = s.ordered() },
	LegacyFields = { id = 9, direction = "ClientToServer",
		fields = s.ordered(s.field("sequence", s.u32()), s.field("enabled", s.boolean())) },
}
local newRequests = { Inspect = s.request(7, s.fields({ query = s.string(24) }), newResult) }
local oldRequests = { Inspect = { id = 7, request = s.ordered(s.field("query", s.string(24))), response = oldResult } }
local newCompiled, newToken = compile("SchemaAuthoringParity", newEvents, newRequests)
local oldCompiled = compile("SchemaAuthoringParity", oldEvents, oldRequests)
for eventName, event in newEvents do
	local candidate = compile("SchemaAuthoringParity", { [eventName] = event })
	local legacy = compile("SchemaAuthoringParity", { [eventName] = oldEvents[eventName] })
	assert(candidate.descriptor == legacy.descriptor, `descriptor mismatch for {eventName}: {#candidate.descriptor}/{#legacy.descriptor}`)
end
local newRequestOnly = compile("SchemaAuthoringParity", {}, newRequests)
local oldRequestOnly = compile("SchemaAuthoringParity", {}, oldRequests)
assert(newRequestOnly.descriptor == oldRequestOnly.descriptor, "request descriptor mismatch")
assert(newCompiled.descriptor == oldCompiled.descriptor, "new authoring forms must preserve descriptors")
assert(Definition.inspect(newToken).events.Input.bytes.representation == "NativeTuple",
	"reliable primitive tuple must retain native path")

for _, pair in {
	{ "Input", table.pack(42, true) },
	{ "Unreliable", table.pack(8) },
	{ "Composite", table.pack({ id = 10, mode = "Run" }, { kind = "Success", value = 3 },
		{ id = 11, count = 2, mode = "Idle" }, { name = 6, type = "value" }) },
	{ "Ordered", table.pack(9) },
	{ "EmptyOptions", table.pack() },
	{ "LegacyFields", table.pack(43, false) },
} do
	sameEncoding(encoded(newCompiled, pair[1], pair[2]), encoded(oldCompiled, pair[1], pair[2]), pair[1])
end
for _, eventName in { "Batch", "State" } do
	local payload = { kind = "Failure", reason = "missing" }
	local newBytes = table.pack(Frame.compile(newCompiled.queuedById[newEvents[eventName].id], "encode")(payload))
	local oldBytes = table.pack(Frame.compile(oldCompiled.queuedById[oldEvents[eventName].id], "encode")(payload))
	assert(newBytes[1] and oldBytes[1], `queued {eventName} payload encoding failed`)
	sameEncoding(newBytes, oldBytes, `queued {eventName}`)
end
local newRequestBytes = table.pack(Frame.compile(newCompiled.requests.Inspect.request, "encode")("find"))
local oldRequestBytes = table.pack(Frame.compile(oldCompiled.requests.Inspect.request, "encode")("find"))
assert(newRequestBytes[1] and oldRequestBytes[1], "request payload encoding failed")
sameEncoding(newRequestBytes, oldRequestBytes, "request")

local rawChild = { type = "boolean" }
local nested = s.fields({ child = s.array(rawChild, 2) })
assert(nested[1] ~= rawChild and nested[1].element == rawChild and not table.isfrozen(rawChild),
	"normalization must own only the immediate field wrapper")
assert(table.isfrozen(nested) and table.isfrozen(nested[1]))
local optionsEvent = s.serverToClient(8, s.fields({ value = s.u8() }), { delivery = "Unreliable", queue = "State" })
assert(table.isfrozen(optionsEvent) and optionsEvent.delivery == "Unreliable" and optionsEvent.queue == "State")

local called = 0
local trap = setmetatable({}, {
	__index = function() called += 1; error("__index must not run") end,
	__iter = function() called += 1; error("__iter must not run") end,
})
local function rejects(callback, label)
	assert(not pcall(callback), label .. " must reject")
end
rejects(function() s.fields(trap) end, "metatable field entry")
rejects(function() s.fields({ value = trap }) end, "metatable field shape")
rejects(function() s.struct(trap) end, "metatable struct entry")
rejects(function() s.enum(trap) end, "metatable enum map")
rejects(function() s.taggedUnion(trap) end, "metatable union wrapper")
rejects(function() s.clientToServer(9, s.fields(), trap) end, "metatable endpoint options")
rejects(function() s.taggedUnion({ kind = setmetatable({ Ready = s.struct() }, trap) }) end,
	"metatable union variants")
assert(called == 0, "normalizers must reject metatables before invoking callbacks")

rejects(function() s.fields({ left = s.u8(), right = s.u8() }) end, "multi-key field entry")
rejects(function() s.fields({ value = s.field("alreadyNamed", s.u8()) }) end, "named field shape")
rejects(function() s.struct({ left = s.u8(), right = s.u8() }) end, "multi-key struct entry")
rejects(function() s.struct({ value = s.field("alreadyNamed", s.u8()) }) end, "named keyed struct shape")
rejects(function() s.enum({ First = 1, Duplicate = 1 }) end, "duplicate enum ordinal")
rejects(function() s.enum({ First = 1, Sparse = 3 }) end, "sparse enum ordinal")
rejects(function() s.enum({ First = 1.5 }) end, "fractional enum ordinal")
rejects(function() s.enum({ First = 0 }) end, "zero enum ordinal")
rejects(function() s.enum({ First = math.huge }) end, "infinite enum ordinal")
rejects(function() s.taggedUnion({}) end, "empty union wrapper")
rejects(function() s.taggedUnion({ kind = {}, other = {} }) end, "multi-key union wrapper")
rejects(function() s.clientToServer(10, s.fields(), { unknown = true }) end, "unknown endpoint option")
rejects(function() s.serverToClient(11, s.fields(), { queue = "Unknown" }) end, "unknown queue")
rejects(function() s.clientToServer(12, s.fields(), { delivery = "Slow" }) end, "unknown delivery")
rejects(function() s.clientToServer(12, s.fields(), { queue = "Batch", delivery = "OrderedUnreliable" }) end,
	"ordered unreliable queued event")

local tooManyFields = table.create(9)
for index = 1, 9 do tooManyFields[index] = { ["value" .. index] = s.u8() } end
rejects(function() s.fields(table.unpack(tooManyFields)) end, "tuple field limit")
rejects(function() s.struct(table.unpack(tooManyFields)) end, "struct field limit")
local tooManyShape = { type = "u8" }
for index = 1, 8 do tooManyShape["extra" .. index] = true end
rejects(function() s.field("value", tooManyShape) end, "field shape key limit")
local tooManyLegacyRecord = { name = "value", type = "u8" }
for index = 1, 7 do tooManyLegacyRecord["extra" .. index] = true end
rejects(function() s.fields(tooManyLegacyRecord) end, "legacy fields record key limit")
rejects(function() s.struct(tooManyLegacyRecord) end, "legacy struct record key limit")
local tooManyVariants = {}
for index = 1, 33 do tooManyVariants["Variant" .. index] = s.struct() end
rejects(function() s.taggedUnion({ kind = tooManyVariants }) end, "union variant limit")

print("PASS bounded schema authoring normalization and legacy descriptor/byte parity")
