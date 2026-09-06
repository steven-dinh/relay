--!strict

local Observer = require("../pilot/DeliveryObserver")
local Fixtures = require("../fixtures/event-v1")
local Contract = require("../contracts/event-v1")

local sender = {}
local metadata = { kind = "ClientToServer", sender = sender }
local fixture = Fixtures.generate("state-burst-c2s", 1)

local function record(sample: any): any
	return { kind = "Record", value = Fixtures.newInput(sample) }
end

local function positional(sample: any): any
	local values = {}
	for _, field in Contract.payloads[sample.payloadId].fields do
		table.insert(values, sample.expected[field.name])
	end
	return { kind = "Positional", values = values, count = #values }
end

for _, envelope in { record, positional } do
	local observer = Observer.new(sender)
	assert(table.isfrozen(observer))
	local expectedTotal = 0
	for repetition = 1, 30 do
		local samples = Fixtures.generate("state-burst-c2s", repetition)
		for _, phase in { samples.warmup, samples.measured } do
			observer.arm(phase)
			assert(not pcall(observer.arm, phase), "cannot replace active phase")
			assert(not pcall(observer.close), "missing delivery must prevent close")
			for _, sample in phase do observer.sink(envelope(sample), metadata) end
			assert(observer.count() == #phase)
			expectedTotal += #phase
			observer.close()
			assert(observer.count() == #phase)
			observer.assertHealthy()
		end
	end
	assert(observer.total() == expectedTotal)
end

local function rejects(label: string, operation: any)
	local observer = Observer.new(sender)
	observer.arm(fixture.warmup)
	assert(pcall(operation, observer), `{label}: sink must not throw`)
	local healthy, first = pcall(observer.assertHealthy)
	assert(not healthy, `{label}: failure must latch`)
	local before = observer.total()
	observer.sink(record(fixture.warmup[1]), metadata)
	assert(observer.total() == before + 1, "failed callbacks must still be counted")
	local _, later = pcall(observer.assertHealthy)
	assert(first == later, "first failure must remain sticky")
	assert(not pcall(observer.close), "failed phase cannot close")
	assert(not pcall(observer.arm, fixture.measured), "failure cannot be reset by rearming")
end

rejects("missing arguments", function(o) o.sink() end)
rejects("extra arguments", function(o) o.sink(record(fixture.warmup[1]), metadata, nil) end)
rejects("wrong envelope", function(o) o.sink({ kind = "Other" }, metadata) end)
rejects("extra envelope field", function(o)
	local value = record(fixture.warmup[1]); value.extra = true; o.sink(value, metadata)
end)
rejects("missing payload field", function(o)
	local value = record(fixture.warmup[1]); value.value.sequence = nil; o.sink(value, metadata)
end)
rejects("wrong sequence type", function(o)
	local value = record(fixture.warmup[1]); value.value.sequence = "1"; o.sink(value, metadata)
end)
rejects("positional arity", function(o)
	local value = positional(fixture.warmup[1]); value.count += 1; o.sink(value, metadata)
end)
rejects("wrong sender", function(o) o.sink(record(fixture.warmup[1]), { kind = "ClientToServer", sender = {} }) end)
rejects("wrong direction", function(o) o.sink(record(fixture.warmup[1]), { kind = "ServerToClient", sender = sender }) end)
rejects("extra metadata", function(o) o.sink(record(fixture.warmup[1]), { kind = "ClientToServer", sender = sender, extra = true }) end)
rejects("future phase", function(o) o.sink(record(fixture.measured[1]), metadata) end)
rejects("future repetition", function(o) o.sink(record(Fixtures.generate("state-burst-c2s", 2).warmup[1]), metadata) end)
rejects("out of order", function(o) o.sink(record(fixture.warmup[2]), metadata) end)
rejects("duplicate", function(o)
	o.sink(record(fixture.warmup[1]), metadata); o.sink(record(fixture.warmup[1]), metadata)
end)
rejects("extra delivery", function(o)
	for _, sample in fixture.warmup do o.sink(record(sample), metadata) end
	o.sink(record(fixture.warmup[1]), metadata)
end)
rejects("between phases", function(o)
	for _, sample in fixture.warmup do o.sink(record(sample), metadata) end
	o.close(); o.sink(record(fixture.measured[1]), metadata)
end)
rejects("old phase", function(o)
	for _, sample in fixture.warmup do o.sink(record(sample), metadata) end
	o.close(); o.arm(fixture.measured); o.sink(record(fixture.warmup[1]), metadata)
end)
rejects("hostile metatable", function(o)
	o.sink(setmetatable({}, { __index = function() error("must not execute") end }), metadata)
end)

-- Even an unexpected comparator exception cannot escape an asynchronous sink.
do
	local o = Observer.new(sender)
	o.arm({ { payloadId = "unknown-payload", expected = {} } })
	assert(pcall(o.sink, { kind = "Record", value = {} }, metadata))
	assert(not pcall(o.assertHealthy))
end
do
	local o = Observer.new(sender)
	assert(pcall(o.sink, record(fixture.warmup[1]), metadata))
	assert(not pcall(o.assertHealthy), "receipt before first phase must fail")
end

print("PASS session reuse observer: record/positional, 30 warmup/measured windows, sticky invalid-delivery rejection")
