local Definition = require("../src/Definition")

local function countKeys(value)
	local count = 0
	for _ in value do count += 1 end
	return count
end

local function assertFrozen(value, path)
	if type(value) ~= "table" then return end
	assert(table.isfrozen(value), path .. " must be frozen")
	for key, child in value do
		assertFrozen(child, path .. "." .. tostring(key))
	end
end

local function define(spec, label)
	local token, problem = Definition.define(spec)
	assert(token ~= nil, label .. " rejected: " .. tostring(problem and problem.message))
	assert(problem == nil, label .. " unexpectedly returned an error")
	return Definition.get(token), token
end

local function invalid(spec, label, path, reason)
	local ok, token, problem = pcall(Definition.define, spec)
	assert(ok, label .. " must return without throwing")
	assert(token == nil and type(problem) == "table", label .. " must reject")
	assert(table.isfrozen(problem) and countKeys(problem) == 2, label .. " error must be a frozen pair")
	assert(problem.code == "InvalidDefinition" and #problem.message <= 256, label .. " error contract changed")
	assert(problem.message:find(path, 1, true), label .. " missing path: " .. problem.message)
	assert(problem.message:find(reason, 1, true), label .. " missing reason: " .. problem.message)
end

local function specWith(event, extra)
	local spec = { name = "Legacy", version = 1, events = { Ping = event } }
	for key, value in extra or {} do spec[key] = value end
	return spec
end

local reliable = { id = 1, direction = "ServerToClient", fields = {} }
local unreliable = { id = 1, direction = "ServerToClient", delivery = "Unreliable", fields = {} }
local composite = {
	id = 1,
	direction = "ServerToClient",
	fields = { { name = "items", type = "array", maximumLength = 2,
		element = { type = "u8", minimum = 0, maximum = 3 } } },
}
local request = {
	Query = { id = 2, request = {}, response = { type = "boolean" } },
}

for index, event in { reliable, unreliable, composite } do
	local absent = define(specWith(event), "legacy descriptor " .. index)
	local disabled = define(specWith(event, { readiness = false }), "disabled legacy descriptor " .. index)
	assert(absent.descriptor == disabled.descriptor,
		"absent and false readiness must preserve legacy descriptor bytes")
	assert(disabled.readiness == nil and disabled.queuedById == nil,
		"disabled readiness must not add compiled feature keys")
	assert(disabled.events.Ping.queue == nil, "unmarked event must not add a false queue flag")
end
local rr5Absent = define(specWith(reliable, { requests = request }), "legacy RR5 descriptor")
local rr5Disabled = define(specWith(reliable, { requests = request, readiness = false }), "disabled RR5 descriptor")
assert(rr5Absent.descriptor:sub(1, 3) == "RR5" and rr5Absent.descriptor == rr5Disabled.descriptor,
	"absent and false readiness must preserve request-bearing RR5 bytes")

local mixed = {
	name = "Ready",
	version = 1,
	readiness = true,
	events = {
		Up = { id = 7, direction = "ServerToClient", queue = "State", fields = {} },
		Down = { id = 2, direction = "ClientToServer", delivery = "Unreliable", queue = "Batch",
			fields = { { name = "value", type = "u8", minimum = 0, maximum = 10 } } },
		Other = { id = 4, direction = "ServerToClient", fields = {
			{ name = "live", type = "boolean" },
		} },
	},
	requests = { Query = { id = 9, request = {}, response = { type = "boolean" } } },
}
local compiled = define(mixed, "RR6 mixed readiness/RPC/queue descriptor")
local expected = "RR6|D5:Ready|V1|R1|N3"
	.. "|E2,C,U,B,4:Down,1F5:value=P2:u8[0,10]"
	.. "|E4,S,R,N,5:Other,1F4:live=P1:b[-,-]"
	.. "|E7,S,R,S,2:Up,0"
	.. "|Q1|R9,5:Query,0[]=P1:b[-,-]"
assert(compiled.descriptor == expected,
	"RR6 literal descriptor changed: " .. compiled.descriptor .. " expected " .. expected)

local readiness = compiled.readiness
assert(readiness.count == 2 and readiness.bytes == 1
	and readiness.byId[4] == 0 and readiness.byId[7] == 1,
	"readiness bits must follow ascending ServerToClient IDs")
assert(compiled.queuedById[2].usesCodec and compiled.queuedById[2] ~= compiled.events.Down
	and compiled.queuedById[2].fields == compiled.events.Down.fields
	and compiled.queuedById[2].direction == compiled.events.Down.direction
	and compiled.queuedById[2].delivery == compiled.events.Down.delivery
	and compiled.queuedById[2].queue == "Batch",
	"queued primitive route must force the codec while retaining the compiled payload schema")
assert(not compiled.events.Down.usesCodec and not compiled.events.Up.usesCodec,
	"queue capability must not change either event's immediate native route")
assert(compiled.queuedById[7].usesCodec and compiled.queuedById[7].minimumEncodedBytes == 3
	and compiled.queuedById[7].maximumEncodedBytes == 3,
	"zero-field queued events still include the three-byte codec header")
assert(compiled.queuedById[4] == nil, "unmarked events must not enter the queued map")
assertFrozen(compiled, "compiled RR6 definition")

local reordered = {
	name = mixed.name,
	version = mixed.version,
	readiness = mixed.readiness,
	events = {
		Other = mixed.events.Other,
		Down = mixed.events.Down,
		Up = mixed.events.Up,
	},
	requests = mixed.requests,
}
assert(define(reordered, "reordered RR6 definition").descriptor == compiled.descriptor,
	"RR6 descriptor and readiness bits must ignore source map iteration order")

local queueOnly = define(specWith({ id = 1, direction = "ClientToServer", queue = "Batch", fields = {} }),
	"queue-only RR6 descriptor")
assert(queueOnly.descriptor == "RR6|D6:Legacy|V1|R0|N1|E1,C,R,B,4:Ping,0|Q0"
	and queueOnly.readiness == nil and queueOnly.queuedById[1].usesCodec,
	"queue-only RR6 must use R0, recursive event grammar, and an empty request section")
local readinessOnly = define({
	name = "Simple", version = 1, readiness = true,
	events = { Up = { id = 1, direction = "ServerToClient", fields = {} } },
}, "readiness-only RR6 descriptor")
assert(readinessOnly.descriptor == "RR6|D6:Simple|V1|R1|N1|E1,S,R,N,2:Up,0|Q0"
	and readinessOnly.queuedById == nil,
	"readiness-only RR6 must include Q0 without an empty queued map")

local manyReady = { name = "ManyReady", version = 1, readiness = true, events = {} }
for index = 16, 1, -1 do
	manyReady.events["Event" .. index] = { id = index * 2, direction = "ServerToClient", fields = {} }
end
local twoByteReady = define(manyReady, "sixteen readiness listeners")
assert(twoByteReady.readiness.count == 16 and twoByteReady.readiness.bytes == 2,
	"nine through sixteen listeners require the compiled two-byte mask")
for index = 1, 16 do
	assert(twoByteReady.readiness.byId[index * 2] == index - 1,
		"two-byte readiness mapping must follow sorted IDs")
end

local descriptorFields = {}
for fieldIndex = 1, 4 do
	local values = {}
	for index = 1, 32 do
		values[index] = string.format("%d%02d", fieldIndex, index) .. string.rep("x", 7)
	end
	descriptorFields[fieldIndex] = { name = "choice" .. fieldIndex, type = "enum", values = values }
end
local descriptorSpec = { name = "DescriptorCap", version = 1, readiness = true,
	events = { Data = { id = 1, direction = "ServerToClient", queue = "Batch", fields = descriptorFields } } }
local padding = 4096 - #define(descriptorSpec, "RR6 descriptor padding base").descriptor
assert(padding > 0)
for _, field in descriptorFields do
	for index, value in field.values do
		local added = math.min(padding, 32 - #value)
		field.values[index] = value .. string.rep("x", added)
		padding -= added
	end
end
assert(padding == 0, "bounded enum fixture must reach the descriptor cap")
assert(#define(descriptorSpec, "RR6 descriptor exactly at cap").descriptor == 4096,
	"RR6 must accept exactly 4096 descriptor bytes")
assert(#descriptorFields[4].values[32] < 32)
descriptorFields[4].values[32] ..= "x"
invalid(descriptorSpec, "RR6 descriptor one byte over cap", "descriptor", "exceeds 4096 bytes")

local report, reportError = Definition.inspect(select(2, define(mixed, "RR6 inspect definition")))
assert(reportError == nil and report.protocol == "RR6" and report.readiness == true
	and report.limits.queuedLogicalRecords == 32,
	"inspector must report RR6 readiness and the fixed logical-record limit")
local immediatePrimitive = report.events.Down
assert(immediatePrimitive.bytes.representation == "NativeTuple"
	and immediatePrimitive.bytes.robloxEncodedBytes == "Unknown",
	"queued primitive inspection must preserve immediate NativeTuple bytes")
assert(immediatePrimitive.queuedBytes.bodyMinimum == 4 and immediatePrimitive.queuedBytes.bodyMaximum == 4
	and immediatePrimitive.queuedBytes.singleRecordMinimum == 9
	and immediatePrimitive.queuedBytes.singleRecordMaximum == 9
	and immediatePrimitive.queuedBytes.limit == 900
	and immediatePrimitive.queuedBytes.robloxEncodedBytes == "Unknown",
	"queued route inspection must report codec body and envelope bounds separately")
assert(report.events.Other.queuedBytes == nil,
	"unmarked events must omit queued byte inspection")
assertFrozen(report, "RR6 inspector report")

local compositeQueue = define({
	name = "Composite", version = 1,
	events = { State = { id = 1, direction = "ServerToClient", queue = "State",
		fields = { { name = "items", type = "array", maximumLength = 2,
			element = { type = "u8", minimum = 0, maximum = 3 } } } } },
}, "composite queue event")
assert(compositeQueue.events.State.usesCodec and compositeQueue.queuedById[1].usesCodec
	and compositeQueue.events.State.minimumEncodedBytes == compositeQueue.queuedById[1].minimumEncodedBytes
	and compositeQueue.events.State.maximumEncodedBytes == compositeQueue.queuedById[1].maximumEncodedBytes,
	"queued composite route must preserve the existing immediate codec metadata")

local maximumReliableFields = table.create(8)
for index = 1, 7 do
	maximumReliableFields[index] = { name = "s" .. index, type = "string", maximumBytes = 1_024 }
end
maximumReliableFields[8] = { name = "last", type = "string", maximumBytes = 1_000 }
local reliableAtLimit = define({
	name = "Limit", version = 1,
	events = { Data = { id = 1, direction = "ServerToClient", queue = "Batch", fields = maximumReliableFields } },
}, "reliable queued body at cap")
assert(reliableAtLimit.queuedById[1].maximumEncodedBytes == 8_187,
	"reliable queued body must accept the exact worst-case boundary")
maximumReliableFields[8].maximumBytes += 1
invalid({ name = "Limit", version = 1,
	events = { Data = { id = 1, direction = "ServerToClient", queue = "Batch", fields = maximumReliableFields } },
}, "reliable queued body over cap", "events.Data.fields", "8187 bytes for Reliable")

local unreliableAtLimit = define({
	name = "Ulimit", version = 1,
	events = { Data = { id = 1, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
		fields = { { name = "text", type = "string", maximumBytes = 890 } } } },
}, "unreliable queued body at cap")
assert(unreliableAtLimit.queuedById[1].maximumEncodedBytes == 895,
	"unreliable queued body must accept the exact worst-case boundary")
invalid({ name = "Ulimit", version = 1,
	events = { Data = { id = 1, direction = "ServerToClient", delivery = "Unreliable", queue = "State",
		fields = { { name = "text", type = "string", maximumBytes = 891 } } } },
}, "unreliable queued body over cap", "events.Data.fields", "895 bytes for Unreliable")

invalid(specWith({ id = 1, direction = "ServerToClient", queue = "batch", fields = {} }),
	"invalid queue mode", "events.Ping.queue", "must be Batch or State")
invalid(specWith({ id = 1, direction = "ClientToServer", fields = {} }, { readiness = "yes" }),
	"non-boolean readiness", "readiness", "must be a boolean")
invalid({ name = "NoReady", version = 1, readiness = true,
	events = { Ping = { id = 1, direction = "ClientToServer", fields = {} } } },
	"readiness without ServerToClient event", "readiness", "requires at least one ServerToClient")
invalid({ name = "NoReady", version = 1,
	events = { Ping = { id = 1, direction = "ClientToServer", fields = {} } },
	requests = { Query = { id = 2, queue = "Batch", request = {}, response = { type = "boolean" } } } },
	"queue metadata on a request", "requests.Query.queue", "unknown key")
local eventWithMetatable = setmetatable({ id = 1, direction = "ServerToClient", queue = "Batch", fields = {} }, {})
invalid(specWith(eventWithMetatable), "event metatable", "events.Ping", "plain table without a metatable")
local definitionWithMetatable = setmetatable(specWith(reliable), {})
invalid(definitionWithMetatable, "definition metatable", "definition", "plain table without a metatable")

for _, code in {
    "ReadinessDisabled", "ReadinessExhausted", "QueueLimit", "QueueFull", "QueueClosed", "QueueBusy",
    "InvalidStateKey", "InvalidPriority",
} do
    local problem = Definition.error(code)
    assert(problem and table.isfrozen(problem) and problem.code == code and type(problem.message) == "string")
    local count = 0
    for key in problem do
        count += 1
        assert(key == "code" or key == "message")
    end
    assert(count == 2, "queue/readiness errors must be fixed two-key records")
end

print("PASS Relay.ReliableEvents.QueuedDefinition RR6 compilation, queue bounds, and inspection")
