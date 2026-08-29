--!strict

local fs = require("@lune/fs")

local AdapterContract = require("../adapters/AdapterContract")
local EventContract = require("../contracts/event-v1")
local DeliveryLedger = require("../correctness/DeliveryLedger")
local PayloadComparator = require("../correctness/PayloadComparator")
local Fixtures = require("../fixtures/event-v1")
local ResultV1 = require("../contracts/result-v1")
local FakeAdapter = require("./support/FakeAdapter")

local STUDIO_VERSION = "0.650.0.6500000"
local SECRET = "fake-secret-must-not-appear"

local function assertExactKeys(value: unknown, expectedKeys: { string }, label: string)
	assert(type(value) == "table", `{label} must be a table`)
	local expected: { [string]: boolean } = {}
	for _, key in expectedKeys do
		expected[key] = true
	end
	local count = 0
	for key in next, value :: any do
		count += 1
		assert(type(key) == "string" and expected[key] == true, `{label} has an unexpected key`)
	end
	assert(count == #expectedKeys, `{label} must have exactly {#expectedKeys} keys`)
end

local function assertFrozenExact(value: unknown, expectedKeys: { string }, label: string)
	assertExactKeys(value, expectedKeys, label)
	assert(table.isfrozen(value :: any), `{label} must be frozen`)
end

local function assertError(operation: () -> (), expected: string, label: string)
	local ok, problem = pcall(operation)
	assert(not ok, `{label} must fail`)
	local message = tostring(problem)
	assert(message == expected, `{label} expected {expected}, got {message}`)
	assert(not string.find(message, SECRET, 1, true), `{label} reflected hostile input`)
end

local function cloneRecord(record: any): any
	local copied = {}
	for key, value in next, record do
		copied[key] = value
	end
	return copied
end

local function assertRecordEqual(payloadId: string, expected: any, actual: any, label: string)
	local matches, mismatch = PayloadComparator.compareRecord(payloadId, expected, actual)
	assert(matches, `{label}: {if mismatch == nil then "unknown mismatch" else mismatch.path}`)
	assert(mismatch == nil, `{label} must not produce mismatch details`)
end

local function assertPending(control: any, expected: any, label: string)
	local first = control:pending()
	local second = control:pending()
	assertFrozenExact(first, { "generation", "scheduled", "heldReorder", "retainedStale" }, label)
	assert(first ~= second, `{label} must return a fresh snapshot`)
	for key, value in next, expected do
		assert(first[key] == value, `{label}.{key} expected {value}, got {first[key]}`)
	end
end

local function repositoryIdentity()
	return {
		id = "fake-adapter-test",
		displayName = "Fake Adapter Test",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "fake-library",
			displayName = "Fake Library",
			version = "1.0.0",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/fake-adapter",
				revision = string.rep("a", 40),
				checksum = "sha256:" .. string.rep("b", 64),
				license = "MIT",
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "SessionRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function workloadSelection(workloadId: string, recipientCount: number)
	return {
		kind = "Workload",
		workloadId = workloadId,
		recipientCount = recipientCount,
	}
end

local function probeSelection()
	return {
		kind = "SeparateProbe",
		probeId = "tiny-round-trip",
	}
end

local function supported(selection: any)
	local result = AdapterContract.preflight(repositoryIdentity(), selection, STUDIO_VERSION)
	assert(result.kind == "Supported", "fake test selection must be supported")
	return result
end

local function newScheduler()
	local frame = 0
	local subscribers: { () -> () } = {}
	local schedulerSubscriptions = 0
	local producerOperation: (() -> ())? = nil
	local producerInstalled = false
	local connectReturn = setmetatable({}, {
		__index = function()
			error("connect return must be ignored", 0)
		end,
	})

	local scheduler = {
		currentFrame = function(...: any): number
			assert(select("#", ...) == 0, "scheduler.currentFrame must use dot semantics")
			return frame
		end,
		connectPostSimulation = function(callback: () -> (), ...: any): any
			assert(select("#", ...) == 0, "scheduler.connectPostSimulation must use dot semantics")
			assert(type(callback) == "function", "scheduler callback must be a function")
			schedulerSubscriptions += 1
			table.insert(subscribers, callback)
			return connectReturn
		end,
	}

	local driver: any
	driver = {
		installProducer = function()
			assert(not producerInstalled, "scheduler producer must be installed once")
			producerInstalled = true
			table.insert(subscribers, function()
				local operation = producerOperation
				if operation ~= nil then
					producerOperation = nil
					operation()
				end
			end)
		end,
		run = function(operation: () -> ())
			assert(producerInstalled, "scheduler producer must be installed before run")
			assert(producerOperation == nil, "scheduler producer accepts one operation per frame")
			producerOperation = operation
			local stepCall = table.pack(pcall(driver.step))
			producerOperation = nil
			if stepCall[1] ~= true then
				error(stepCall[2], 0)
			end
		end,
		step = function()
			frame += 1
			local count = #subscribers
			for index = 1, count do
				subscribers[index]()
			end
		end,
		emit = function(nextFrame: number)
			frame = nextFrame
			local count = #subscribers
			for index = 1, count do
				subscribers[index]()
			end
		end,
		frame = function(): number
			return frame
		end,
		subscriberCount = function(): number
			return #subscribers
		end,
		schedulerSubscriptionCount = function(): number
			return schedulerSubscriptions
		end,
	}

	return scheduler, driver
end

local function clientCount(selection: any): number
	return if selection.kind == "SeparateProbe" then 1 else selection.recipientCount
end

local function serverRecipientCount(selection: any): number
	if selection.kind == "SeparateProbe" then
		return 1
	end
	return if selection.workloadId == "state-broadcast-s2c" then selection.recipientCount else 0
end

local function constructRig(
	selection: any,
	serverSink: (any, any) -> (),
	clientSinks: { (any, any) -> () },
	actions: { any }?
): any
	local scheduler, driver = newScheduler()
	local adapter, control = FakeAdapter.newTestRig(scheduler)
	driver.installProducer()
	if actions ~= nil then
		control:loadFaultScript(actions)
	end

	local preflight = supported(selection)
	local recipients = {}
	for index = 1, serverRecipientCount(selection) do
		recipients[index] = { participantIndex = index }
	end
	local server = AdapterContract.constructServer(
		preflight,
		adapter,
		{ side = "Server" },
		recipients,
		serverSink
	)
	local clients = {}
	for index = 1, clientCount(selection) do
		clients[index] = AdapterContract.constructClient(
			preflight,
			adapter,
			{ side = "Client", participantIndex = index },
			index,
			clientSinks[index] or function() end
		)
	end

	return {
		adapter = adapter,
		control = control,
		driver = driver,
		server = server,
		clients = clients,
	}
end

local function readyRig(rig: any)
	assert(rig.driver.schedulerSubscriptionCount() == 0, "fake must not subscribe before setup")
	rig.server.setup()
	assert(rig.driver.schedulerSubscriptionCount() == 1, "first successful setup must install the fake tail subscriber")
	assert(rig.server.ready() == true, "server must become ready")
	for _, client in rig.clients do
		client.setup()
		assert(rig.driver.schedulerSubscriptionCount() == 1, "later setup must reuse the fake tail subscriber")
		assert(client.ready() == true, "client must become ready")
	end
end

local function teardownRig(rig: any)
	for _, client in rig.clients do
		client.teardown()
		client.teardown()
	end
	rig.server.teardown()
	rig.server.teardown()
end

local function runOperation(rig: any, operation: () -> ())
	rig.driver.run(operation)
end

local function recordLedgerDelivery(ledger: any, delivery: any): (string, any?)
	assertFrozenExact(delivery, { "kind", "value" }, "record delivery envelope")
	assert(delivery.kind == "Record", "fake must forward a record envelope")
	local actual = delivery.value
	local payloadId = if rawget(actual, "enabled") ~= nil then "tiny" else "state"
	local sequence = rawget(actual, "sequence")
	local expected = ledger:expectedFor(payloadId, sequence)
	if expected == nil then
		local status = ledger:recordDelivery(payloadId, sequence, false)
		return status, nil
	end
	local matches, mismatch = PayloadComparator.compareRecord(payloadId, expected.expected, actual)
	local status = ledger:recordDelivery(payloadId, sequence, matches)
	return status, mismatch
end

-- Exact module/factory/control surfaces, scheduler seam, and a production-contract construction.
assertFrozenExact(FakeAdapter, { "newTestRig" }, "FakeAdapter")
do
	local scheduler, driver = newScheduler()
	local adapter, control = FakeAdapter.newTestRig(scheduler)
	assert(driver.subscriberCount() == 0, "fake must not subscribe before setup")
	assertFrozenExact(adapter, { "constructServer", "constructClient" }, "fake adapter")
	assertFrozenExact(control, { "loadFaultScript", "pending", "assertConsumed", "reset" }, "fake control")
	assertPending(control, {
		generation = 1,
		scheduled = 0,
		heldReorder = 0,
		retainedStale = 0,
	}, "initial pending")
	assertError(function()
		control.pending({})
	end, "FAKE_E_STATE", "control dot/self misuse")
end

-- Canonical tiny/state client-to-server paths use the real comparator and ledger.
local function runCleanClientToServer(workloadId: string)
	local fixture = Fixtures.generate(workloadId, 1)
	local activeLedger: any = nil
	local senderCallbacks = 0
	local rig = constructRig(workloadSelection(workloadId, 1), function(delivery, metadata)
		assertFrozenExact(metadata, { "kind", "sender" }, "client-to-server metadata")
		assert(metadata.kind == "ClientToServer", "client-to-server metadata kind must match")
		assert(metadata.sender == 1, "fake sender token must be participantIndex 1")
		senderCallbacks += 1
		local status, mismatch = recordLedgerDelivery(activeLedger, delivery)
		assert(status == "Expected", "clean client-to-server delivery must be Expected")
		assert(mismatch == nil, "clean client-to-server delivery must compare")
	end, { function() end })
	readyRig(rig)

	for _, submissions in { fixture.warmup, fixture.measured } do
		activeLedger = DeliveryLedger.new(submissions)
		for index, submission in submissions do
			local input = Fixtures.newInput(submission)
			local before = cloneRecord(input)
			runOperation(rig, function()
				rig.clients[1].submit(input, if index == #submissions then "FlushBeforeReturn" else "ContinueFrame")
			end)
			assertRecordEqual(submission.payloadId, before, input, "client-to-server caller input")
		end
		local clean, snapshot = activeLedger:close()
		assert(clean, `{workloadId} phase must close cleanly`)
		assert(snapshot.received == #submissions, `{workloadId} received count must match`)
		assert(snapshot.correct == #submissions, `{workloadId} correct count must match`)
		assert(snapshot.missing == 0 and snapshot.duplicate == 0 and snapshot.unexpected == 0, `{workloadId} counters must stay clean`)
	end

	assert(senderCallbacks == #fixture.warmup + #fixture.measured, `{workloadId} callback count must match`)
	assertPending(rig.control, { scheduled = 0, heldReorder = 0, retainedStale = 0 }, `{workloadId} clean pending`)
	teardownRig(rig)
	rig.control:assertConsumed()
	rig.control:reset()
	assertPending(rig.control, { generation = 2, scheduled = 0, heldReorder = 0, retainedStale = 0 }, `{workloadId} reset`)
end

runCleanClientToServer("tiny-steady-c2s")
runCleanClientToServer("state-steady-c2s")

-- One logical broadcast expands to 1/4/8 independent recipient ledgers in ascending order.
local function runCleanBroadcast(recipientCount: number)
	local fixture = Fixtures.generate("state-broadcast-s2c", 1)
	local ledgers = {}
	local sinks = {}
	local order = {}
	for receiverIndex = 1, recipientCount do
		ledgers[receiverIndex] = DeliveryLedger.new(fixture.measured)
		sinks[receiverIndex] = function(delivery, metadata)
			assertFrozenExact(metadata, { "kind" }, "server-to-client metadata")
			assert(metadata.kind == "ServerToClient", "server-to-client metadata kind must match")
			table.insert(order, receiverIndex)
			local status, mismatch = recordLedgerDelivery(ledgers[receiverIndex], delivery)
			assert(status == "Expected", "clean broadcast delivery must be Expected")
			assert(mismatch == nil, "clean broadcast delivery must compare")
		end
	end
	local rig = constructRig(workloadSelection("state-broadcast-s2c", recipientCount), function() end, sinks)
	readyRig(rig)

	for submitIndex, submission in fixture.measured do
		local input = Fixtures.newInput(submission)
		local before = cloneRecord(input)
		runOperation(rig, function()
			rig.server.broadcast(input, if submitIndex == #fixture.measured then "FlushBeforeReturn" else "ContinueFrame")
		end)
		assertRecordEqual("state", before, input, "broadcast caller input")
		local offset = (submitIndex - 1) * recipientCount
		for receiverIndex = 1, recipientCount do
			assert(order[offset + receiverIndex] == receiverIndex, "broadcast recipients must dispatch in ascending order")
		end
	end

	local aggregateReceived = 0
	for receiverIndex = 1, recipientCount do
		local clean, snapshot = ledgers[receiverIndex]:close()
		assert(clean, `recipient {receiverIndex} ledger must close cleanly`)
		assert(snapshot.received == 120 and snapshot.correct == 120, `recipient {receiverIndex} must receive 120 records`)
		aggregateReceived += snapshot.received
	end
	assert(aggregateReceived == 120 * recipientCount, `broadcast aggregate for {recipientCount} recipients must match`)
	teardownRig(rig)
	rig.control:assertConsumed()
end

runCleanBroadcast(1)
runCleanBroadcast(4)
runCleanBroadcast(8)

-- SeparateProbe remains test-owned request/echo composition with one item in flight.
do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local currentSubmission: any = nil
	local submissionFrame = -1
	local echoOrder = {}
	local serverCallbacks = 0
	local clientCallbacks = 0
	local rig: any = nil
	rig = constructRig(probeSelection(), function(delivery, metadata)
		assert(rig.driver.frame() == submissionFrame, "probe request must drain in its submission frame")
		assert(metadata.kind == "ClientToServer" and metadata.sender == 1, "probe request metadata must authenticate participant 1")
		assert(delivery.kind == "Record", "probe request must be a record")
		assertRecordEqual("tiny", currentSubmission.expected, delivery.value, "probe request")
		serverCallbacks += 1
		table.insert(echoOrder, "broadcast-start")
		rig.server.broadcast(delivery.value, "FlushBeforeReturn")
		table.insert(echoOrder, "broadcast-returned")
	end, { function(delivery, metadata)
		assert(rig.driver.frame() == submissionFrame, "nested probe echo must drain in its submission frame")
		assert(metadata.kind == "ServerToClient", "probe response metadata must match")
		assert(delivery.kind == "Record", "probe response must be a record")
		assertRecordEqual("tiny", currentSubmission.expected, delivery.value, "probe response")
		table.insert(echoOrder, "client-sink")
		clientCallbacks += 1
	end })
	readyRig(rig)

	for _, submissions in { fixture.warmup, fixture.measured } do
		for _, submission in submissions do
			currentSubmission = submission
			echoOrder = {}
			local input = Fixtures.newInput(submission)
			local before = cloneRecord(input)
			runOperation(rig, function()
				submissionFrame = rig.driver.frame()
				rig.clients[1].submit(input, "FlushBeforeReturn")
			end)
			assert(
				echoOrder[1] == "broadcast-start"
					and echoOrder[2] == "broadcast-returned"
					and echoOrder[3] == "client-sink"
					and #echoOrder == 3,
				"nested probe client sink must run after broadcast returns"
			)
			assert(clientCallbacks == serverCallbacks, "probe response must complete in the same fake tail before the next sample")
			assertRecordEqual("tiny", before, input, "probe caller input")
		end
	end
	assert(serverCallbacks == 180 and clientCallbacks == 180, "probe must run all 60 warmup and 120 measured samples")
	teardownRig(rig)
	rig.control:assertConsumed()
end

local function deliveryTarget(direction: string, submitIndex: number, receiverIndex: number)
	return {
		direction = direction,
		submitIndex = submitIndex,
		receiverIndex = receiverIndex,
	}
end

local function action(kind: string, direction: string, submitIndex: number, receiverIndex: number): any
	return {
		kind = kind,
		target = deliveryTarget(direction, submitIndex, receiverIndex),
	}
end

local function constructGeneration(
	adapter: any,
	selection: any,
	serverSink: (any, any) -> (),
	clientSinks: { (any, any) -> () }
): (any, { any })
	local preflight = supported(selection)
	local recipients = {}
	for index = 1, serverRecipientCount(selection) do
		recipients[index] = { participantIndex = index }
	end
	local server = AdapterContract.constructServer(
		preflight,
		adapter,
		{ side = "Server" },
		recipients,
		serverSink
	)
	local clients = {}
	for index = 1, clientCount(selection) do
		clients[index] = AdapterContract.constructClient(
			preflight,
			adapter,
			{ side = "Client", participantIndex = index },
			index,
			clientSinks[index] or function() end
		)
	end
	return server, clients
end

local function readyGeneration(server: any, clients: { any })
	server.setup()
	assert(server.ready() == true, "generation server must become ready")
	for _, client in clients do
		client.setup()
		assert(client.ready() == true, "generation client must become ready")
	end
end

local function teardownGeneration(server: any, clients: { any })
	for _, client in clients do
		client.teardown()
	end
	server.teardown()
end

-- Lifecycle misuse is rejected by the frozen production wrapper, and reset enables a clean generation.
do
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local rig = constructRig(selection, function() end, { function() end })
	local input = Fixtures.newInput(Fixtures.generate("tiny-steady-c2s", 1).measured[1])
	assertError(function()
		rig.clients[1].submit(input, "ContinueFrame")
	end, "ADAPTER_E_STATE", "submit before setup")
	readyRig(rig)
	assertError(function()
		rig.clients[1].setup()
	end, "ADAPTER_E_STATE", "duplicate setup")
	teardownRig(rig)
	assertError(function()
		rig.clients[1].submit(input, "ContinueFrame")
	end, "ADAPTER_E_STATE", "submit after teardown")
	assertError(function()
		rig.clients[1].ready()
	end, "ADAPTER_E_STATE", "ready after teardown")
	rig.control:reset()
	local callbacks = 0
	local server, clients = constructGeneration(rig.adapter, selection, function()
		callbacks += 1
	end, { function() end })
	readyGeneration(server, clients)
	runOperation(rig, function()
		clients[1].submit(input, "FlushBeforeReturn")
	end)
	assert(callbacks == 1, "reset generation must deliver normally")
	teardownGeneration(server, clients)
	assertPending(rig.control, { generation = 2, scheduled = 0, heldReorder = 0, retainedStale = 0 }, "repeated generation")
end

-- Scheduler configuration is exact, dot-called, starts at zero, and advances one integer at a time.
do
	local function assertBadScheduler(candidate: any, label: string)
		assertError(function()
			FakeAdapter.newTestRig(candidate)
		end, "FAKE_E_SCHEDULER", label)
	end
	assertBadScheduler({}, "empty scheduler")
	assertBadScheduler({ currentFrame = function()
		return 0
	end }, "scheduler missing connector")
	assertBadScheduler({
		currentFrame = function()
			return 0
		end,
		connectPostSimulation = function() end,
		extra = SECRET,
	}, "scheduler extra key")
	assertBadScheduler(setmetatable({
		currentFrame = function()
			return 0
		end,
		connectPostSimulation = function() end,
	}, {}), "scheduler metatable")
	assertBadScheduler({
		currentFrame = function()
			return 1
		end,
		connectPostSimulation = function() end,
	}, "scheduler nonzero start")
	assertBadScheduler({
		currentFrame = function()
			return 0, SECRET
		end,
		connectPostSimulation = function() end,
	}, "scheduler extra frame return")
	local connectorFailure = {
		currentFrame = function()
			return 0
		end,
		connectPostSimulation = function()
			error(SECRET, 0)
		end,
	}
	local connectorAdapter = FakeAdapter.newTestRig(connectorFailure)
	local connectorSelection = workloadSelection("tiny-steady-c2s", 1)
	local connectorServer = AdapterContract.constructServer(
		supported(connectorSelection),
		connectorAdapter,
		{ side = "Server" },
		{},
		function() end
	)
	assertError(function()
		connectorServer.setup()
	end, "ADAPTER_E_SETUP", "scheduler connector failure moves to setup")

	local function assertBadFrames(frames: { number }, label: string)
		local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function() end, { function() end })
		readyRig(rig)
		assertError(function()
			for _, frame in frames do
				rig.driver.emit(frame)
			end
		end, "FAKE_E_SCHEDULER", label)
	end
	assertBadFrames({ 1, 1 }, "repeated scheduler frame")
	assertBadFrames({ 2 }, "skipped scheduler frame")
	assertBadFrames({ 1, 0 }, "decreasing scheduler frame")
	assertBadFrames({ 0.5 }, "fractional scheduler frame")
	assertBadFrames({ -1 }, "negative scheduler frame")
	assertBadFrames({ 0 / 0 }, "NaN scheduler frame")
	assertBadFrames({ math.huge }, "infinite scheduler frame")
end

-- Registering the producer after setup reverses the required producer/tail order and fails closed.
do
	local scheduler, driver = newScheduler()
	local adapter, control = FakeAdapter.newTestRig(scheduler)
	local selection = workloadSelection("tiny-steady-c2s", 1)
	local server, clients = constructGeneration(adapter, selection, function() end, { function() end })
	readyGeneration(server, clients)
	assert(driver.subscriberCount() == 1, "fake tail must be the only subscriber before the late producer")
	driver.installProducer()
	assertError(function()
		driver.run(function()
			clients[1].submit(Fixtures.newInput(Fixtures.generate("tiny-steady-c2s", 1).measured[1]), "ContinueFrame")
		end)
	end, "ADAPTER_E_SUBMIT", "late producer ordering")
	assertPending(control, { scheduled = 0, heldReorder = 0, retainedStale = 0 }, "late producer rejection")
	teardownGeneration(server, clients)
end

-- Tail dispatch occurs after submit returns in the same frame; delays and equal-frame FIFO remain exact.
do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local callbacks = 0
	local order = {}
	local sinkFrame = -1
	local rig: any
	rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function()
		callbacks += 1
		sinkFrame = rig.driver.frame()
		table.insert(order, "sink")
	end, { function() end })
	readyRig(rig)
	runOperation(rig, function()
		table.insert(order, "submit-start")
		rig.clients[1].submit(Fixtures.newInput(fixture.measured[1]), "ContinueFrame")
		table.insert(order, "submit-returned")
	end)
	assert(callbacks == 1 and sinkFrame == 1, "normal delivery must drain in the submission frame")
	assert(
		order[1] == "submit-start" and order[2] == "submit-returned" and order[3] == "sink",
		"fake tail delivery must occur only after submit returns"
	)
	teardownRig(rig)
end

-- Capacity preflight counts every accepted record before mutation or partial fan-out.
local function assertPendingAddition(kind: string, actionValue: any?, expected: any)
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local actions = if actionValue == nil then nil else { actionValue }
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function() end, { function() end }, actions)
	readyRig(rig)
	runOperation(rig, function()
		rig.clients[1].submit(Fixtures.newInput(fixture.measured[1]), "ContinueFrame")
		assertPending(rig.control, expected, `{kind} capacity addition before tail`)
		if kind == "ReorderNext" then
			rig.clients[1].submit(Fixtures.newInput(fixture.measured[2]), "ContinueFrame")
		end
	end)
	rig.control:assertConsumed()
	teardownRig(rig)
	if kind == "StaleAfterTeardown" then
		rig.driver.step()
	end
	assertPending(rig.control, {
		scheduled = 0,
		heldReorder = 0,
		retainedStale = 0,
	}, `{kind} capacity addition cleanup`)
end

assertPendingAddition("Normal", nil, { scheduled = 1, heldReorder = 0, retainedStale = 0 })
assertPendingAddition("Duplicate", action("Duplicate", "ClientToServer", 1, 0), {
	scheduled = 2,
	heldReorder = 0,
	retainedStale = 0,
})
assertPendingAddition("Unexpected", action("Unexpected", "ClientToServer", 1, 0), {
	scheduled = 2,
	heldReorder = 0,
	retainedStale = 0,
})
assertPendingAddition("StaleAfterTeardown", action("StaleAfterTeardown", "ClientToServer", 1, 0), {
	scheduled = 1,
	heldReorder = 0,
	retainedStale = 1,
})
assertPendingAddition("ReorderNext", action("ReorderNext", "ClientToServer", 1, 0), {
	scheduled = 0,
	heldReorder = 1,
	retainedStale = 0,
})
assertPendingAddition("Drop", action("Drop", "ClientToServer", 1, 0), {
	scheduled = 0,
	heldReorder = 0,
	retainedStale = 0,
})

local withinDeadlineSnapshot: any = nil
do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local submissions = { fixture.measured[1], fixture.measured[2] }
	local ledger = DeliveryLedger.new(submissions)
	local deliveredFrames = {}
	local deliveredSequences = {}
	local rig: any = nil
	rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		table.insert(deliveredFrames, rig.driver.frame())
		table.insert(deliveredSequences, delivery.value.sequence)
		local status, mismatch = recordLedgerDelivery(ledger, delivery)
		assert(status == "Expected" and mismatch == nil, "within-deadline delay must compare as Expected")
	end, { function() end }, {
		{
			kind = "Delay",
			target = deliveryTarget("ClientToServer", 1, 0),
			frames = 3,
		},
	})
	readyRig(rig)
	local firstInput = Fixtures.newInput(submissions[1])
	local secondInput = Fixtures.newInput(submissions[2])
	local firstBefore = cloneRecord(firstInput)
	local secondBefore = cloneRecord(secondInput)
	runOperation(rig, function()
		rig.clients[1].submit(firstInput, "ContinueFrame")
		rig.clients[1].submit(secondInput, "FlushBeforeReturn")
	end)
	assert(#deliveredFrames == 0, "delayed delivery must not dispatch before its due frame")
	assertPending(rig.control, { scheduled = 2, heldReorder = 0, retainedStale = 0 }, "delayed pending")
	rig.driver.step()
	rig.driver.step()
	assert(#deliveredFrames == 0, "delay must not dispatch early")
	rig.driver.step()
	assert(deliveredFrames[1] == 4 and deliveredFrames[2] == 4, "delay must dispatch on the exact due frame")
	assert(
		deliveredSequences[1] == submissions[1].sequence and deliveredSequences[2] == submissions[2].sequence,
		"within-deadline delay must preserve route FIFO"
	)
	assertRecordEqual("tiny", firstBefore, firstInput, "within-deadline first caller input")
	assertRecordEqual("tiny", secondBefore, secondInput, "within-deadline second caller input")
	local clean, snapshot = ledger:close()
	assert(clean, "within-deadline delay ledger must close cleanly")
	assert(
		snapshot.received == 2
			and snapshot.correct == 2
			and snapshot.missing == 0
			and snapshot.duplicate == 0
			and snapshot.unexpected == 0
			and snapshot.outOfOrder == 0
			and snapshot.mismatch == 0,
		"within-deadline delay must produce exact clean FIFO evidence"
	)
	withinDeadlineSnapshot = snapshot
	assertPending(rig.control, { scheduled = 0 }, "delayed drained")
	teardownRig(rig)
	rig.control:assertConsumed()
end

do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local observed = {}
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		table.insert(observed, delivery.value.sequence)
	end, { function() end }, {
		{ kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 3 },
		{ kind = "Delay", target = deliveryTarget("ClientToServer", 2, 0), frames = 1 },
	})
	readyRig(rig)
	runOperation(rig, function()
		rig.clients[1].submit(Fixtures.newInput(fixture.measured[1]), "ContinueFrame")
		rig.clients[1].submit(Fixtures.newInput(fixture.measured[2]), "ContinueFrame")
	end)
	assertPending(rig.control, { scheduled = 2 }, "equal-frame FIFO pending")
	rig.driver.step()
	assert(#observed == 0, "route clamp must keep the second record behind the first")
	rig.driver.step()
	assert(#observed == 0, "equal due records must remain pending before their due frame")
	rig.driver.step()
	assert(#observed == 2, "both clamped records must dispatch at the exact due frame")
	assert(observed[1] == fixture.measured[1].sequence and observed[2] == fixture.measured[2].sequence, "equal-frame dispatch must preserve insertion FIFO")
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Teardown cancels ordinary delayed work, while an explicit reorder exposes and releases its hold.
do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local callbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function()
		callbacks += 1
	end, { function() end }, {
		{ kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 3 },
	})
	readyRig(rig)
	runOperation(rig, function()
		rig.clients[1].submit(Fixtures.newInput(fixture.measured[1]), "ContinueFrame")
	end)
	assertPending(rig.control, { scheduled = 1 }, "teardown cancellation before")
	teardownRig(rig)
	assertPending(rig.control, { scheduled = 0 }, "teardown cancellation after")
	rig.driver.step()
	rig.driver.step()
	rig.driver.step()
	assert(callbacks == 0, "canceled ordinary delivery must never call the sink")
	rig.control:assertConsumed()
end

do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local ledger = DeliveryLedger.new({ fixture.measured[1], fixture.measured[2] })
	local order = {}
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		table.insert(order, delivery.value.sequence)
		recordLedgerDelivery(ledger, delivery)
	end, { function() end }, {
		action("ReorderNext", "ClientToServer", 1, 0),
	})
	readyRig(rig)
	local firstInput = Fixtures.newInput(fixture.measured[1])
	local secondInput = Fixtures.newInput(fixture.measured[2])
	local firstBefore = cloneRecord(firstInput)
	local secondBefore = cloneRecord(secondInput)
	runOperation(rig, function()
		rig.clients[1].submit(firstInput, "ContinueFrame")
	end)
	assertPending(rig.control, { scheduled = 0, heldReorder = 1 }, "reorder held")
	assertError(function()
		rig.control:assertConsumed()
	end, "FAKE_E_SCRIPT", "reorder without partner")
	runOperation(rig, function()
		rig.clients[1].submit(secondInput, "ContinueFrame")
	end)
	assertRecordEqual("tiny", firstBefore, firstInput, "reorder first caller input")
	assertRecordEqual("tiny", secondBefore, secondInput, "reorder second caller input")
	assertPending(rig.control, { heldReorder = 0 }, "reorder released")
	rig.control:assertConsumed()
	local _, snapshot = ledger:close()
	assert(order[1] == fixture.measured[2].sequence and order[2] == fixture.measured[1].sequence, "ReorderNext must reverse exactly one adjacent pair")
	assert(snapshot.outOfOrder == 1 and snapshot.received == 2 and snapshot.correct == 2, "reorder ledger counters must be exact")
	teardownRig(rig)
end

-- Multiple partnered reorder pairs on one delayed route remain independent.
do
	local fixture = Fixtures.generate("tiny-steady-c2s", 1)
	local observed = {}
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		table.insert(observed, delivery.value.sequence)
	end, { function() end }, {
		{ kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 3 },
		action("ReorderNext", "ClientToServer", 2, 0),
		action("ReorderNext", "ClientToServer", 4, 0),
	})
	readyRig(rig)
	local inputs = {}
	local before = {}
	runOperation(rig, function()
		for index = 1, 5 do
			inputs[index] = Fixtures.newInput(fixture.measured[index])
			before[index] = cloneRecord(inputs[index])
			rig.clients[1].submit(inputs[index], "ContinueFrame")
		end
	end)
	assertPending(rig.control, { scheduled = 3, heldReorder = 2 }, "multiple reorder pairs pending")
	rig.driver.step()
	rig.driver.step()
	assert(#observed == 0, "multiple reorder pairs must stay delayed")
	rig.driver.step()
	local expectedOrder = { 1, 3, 2, 5, 4 }
	for position, fixtureIndex in expectedOrder do
		assert(observed[position] == fixture.measured[fixtureIndex].sequence, `multiple reorder position {position} must match`)
	end
	for index = 1, 5 do
		assertRecordEqual("tiny", before[index], inputs[index], `multiple reorder caller input {index}`)
	end
	assertPending(rig.control, { scheduled = 0, heldReorder = 0 }, "multiple reorder pairs drained")
	rig.control:assertConsumed()
	teardownRig(rig)
end

-- Fault scripts are copied bounded data and reject every unapproved shape without reflection.
do
	local validDrop = action("Drop", "ClientToServer", 1, 0)
	local function assertScriptRejected(script: any, label: string)
		local scheduler = newScheduler()
		local _, control = FakeAdapter.newTestRig(scheduler)
		assertError(function()
			control:loadFaultScript(script)
		end, "FAKE_E_SCRIPT", label)
	end
	assertScriptRejected({ [2] = validDrop }, "sparse script")
	local oversized = table.create(33, validDrop)
	assertScriptRejected(oversized, "oversized script")
	assertScriptRejected({ validDrop, action("Corrupt", "ClientToServer", 1, 0) }, "duplicate delivery target")
	assertScriptRejected({ action("ReorderNext", "ClientToServer", 1, 0), action("Drop", "ClientToServer", 2, 0) }, "overlapping reorder partner")
	assertScriptRejected({ { kind = "Unknown", secret = SECRET } }, "bad action enum")
	assertScriptRejected({ { kind = "Drop", target = deliveryTarget("Wrong", 1, 0) } }, "bad direction")
	assertScriptRejected({ action("Drop", "ClientToServer", 0, 0) }, "zero submit index")
	assertScriptRejected({ action("Drop", "ClientToServer", 2001, 0) }, "oversized submit index")
	assertScriptRejected({ action("Drop", "ClientToServer", 1.5, 0) }, "fractional submit index")
	assertScriptRejected({ action("Drop", "ClientToServer", 1, 1) }, "bad server receiver")
	assertScriptRejected({ action("Drop", "ServerToClient", 1, 0) }, "bad client receiver")
	assertScriptRejected({ action("Drop", "ServerToClient", 1, 9) }, "oversized client receiver")
	assertScriptRejected({ { kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 0 } }, "zero delay")
	assertScriptRejected({ { kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 121 } }, "oversized delay")
	assertScriptRejected({ { kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 1.5 } }, "fractional delay")
	assertScriptRejected({ { kind = "Drop", target = deliveryTarget("ClientToServer", 1, 0), callback = function() end } }, "callback action value")
	assertScriptRejected({ { kind = "Drop", target = deliveryTarget("ClientToServer", 1, 0), payload = { secret = SECRET } } }, "arbitrary payload action value")
	assertScriptRejected(setmetatable({ validDrop }, {}), "script metatable")
	assertScriptRejected({ setmetatable(validDrop, {}) }, "action metatable")
	assertScriptRejected({ { kind = "Drop", target = setmetatable(deliveryTarget("ClientToServer", 1, 0), {}) } }, "target metatable")
	assertScriptRejected({ { kind = "FailSetup", side = "Wrong", participantIndex = 0 } }, "bad setup side")
	assertScriptRejected({ { kind = "FailSetup", side = "Server", participantIndex = 1 } }, "bad server participant")
	assertScriptRejected({ { kind = "FailSetup", side = "Client", participantIndex = 0 } }, "bad client participant")
	assertScriptRejected({ { kind = "FailSubmit", direction = "Wrong", submitIndex = 1 } }, "bad failure direction")
	assertScriptRejected({ { kind = "FailTeardown", side = "Client", participantIndex = 9 } }, "bad teardown participant")

	local scheduler = newScheduler()
	local _, control = FakeAdapter.newTestRig(scheduler)
	control:loadFaultScript({})
	assertError(function()
		control:loadFaultScript({})
	end, "FAKE_E_STATE", "script replacement")
end

-- Script input is detached: mutation after load cannot alter the installed action.
do
	local originalTarget = deliveryTarget("ClientToServer", 1, 0)
	local originalAction = { kind = "Drop", target = originalTarget }
	local script = { originalAction }
	local callbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function()
		callbacks += 1
	end, { function() end }, script)
	originalAction.kind = "Duplicate"
	originalTarget.submitIndex = 2
	script[1] = nil
	readyRig(rig)
	runOperation(rig, function()
		rig.clients[1].submit(Fixtures.newInput(Fixtures.generate("tiny-steady-c2s", 1).measured[1]), "ContinueFrame")
	end)
	assert(callbacks == 0, "installed script must be detached from caller mutation")
	rig.control:assertConsumed()
	teardownRig(rig)
end

-- Reset rejects live sides and unconsumed scripts.
do
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function() end, { function() end })
	assertError(function()
		rig.control:reset()
	end, "FAKE_E_STATE", "reset with live sides")
	teardownRig(rig)
	local scheduler = newScheduler()
	local _, control = FakeAdapter.newTestRig(scheduler)
	control:loadFaultScript({ action("Drop", "ClientToServer", 1, 0) })
	assertError(function()
		control:reset()
	end, "FAKE_E_SCRIPT", "reset with unconsumed action")
end

local function singleMeasured(workloadId: string, index: number?): any
	return Fixtures.generate(workloadId, 1).measured[index or 1]
end

local observedMappings: { [string]: any } = {}

-- Drop workload: no callback, one missing receipt, and a deterministic drain timeout.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local ledger = DeliveryLedger.new({ submission })
	local callbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		callbacks += 1
		recordLedgerDelivery(ledger, delivery)
	end, { function() end }, { action("Drop", "ClientToServer", 1, 0) })
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "drop caller input")
	assert(callbacks == 0, "Drop workload must suppress its callback")
	local clean, snapshot = ledger:close()
	assert(not clean, "Drop workload ledger must not be clean")
	assert(snapshot.received == 0 and snapshot.correct == 0 and snapshot.missing == 1, "Drop workload counters must be exact")
	observedMappings.dropWorkload = snapshot
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Drop probe: request never reaches server or response client; no workload ledger is involved.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local serverCallbacks = 0
	local clientCallbacks = 0
	local rig = constructRig(probeSelection(), function()
		serverCallbacks += 1
	end, { function()
		clientCallbacks += 1
	end }, { action("Drop", "ClientToServer", 1, 0) })
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "drop probe caller input")
	assert(serverCallbacks == 0 and clientCallbacks == 0, "Drop probe must reach neither sink")
	observedMappings.dropProbe = { timeout = true }
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Duplicate workload: the first receipt is Expected and the exact extra is Duplicate.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local ledger = DeliveryLedger.new({ submission })
	local statuses = {}
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		local status = recordLedgerDelivery(ledger, delivery)
		table.insert(statuses, status)
	end, { function() end }, { action("Duplicate", "ClientToServer", 1, 0) })
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "duplicate caller input")
	local _, snapshot = ledger:close()
	assert(statuses[1] == "Expected" and statuses[2] == "Duplicate" and #statuses == 2, "Duplicate must add exactly one callback")
	assert(snapshot.received == 2 and snapshot.correct == 1 and snapshot.duplicate == 1 and snapshot.missing == 0, "Duplicate counters must be exact")
	observedMappings.duplicateWorkload = snapshot
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Duplicate probe: first echo completes, and the second echo is lifecycle-stale.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local completed = false
	local staleCallbacks = 0
	local acceptedCallbacks = 0
	local rig: any = nil
	rig = constructRig(probeSelection(), function(delivery)
		rig.server.broadcast(delivery.value, "FlushBeforeReturn")
	end, { function(delivery)
		if completed then
			staleCallbacks += 1
			return
		end
		completed = true
		acceptedCallbacks += 1
		assertRecordEqual("tiny", submission.expected, delivery.value, "duplicate probe accepted echo")
	end }, { action("Duplicate", "ServerToClient", 1, 1) })
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "duplicate probe caller input")
	assert(acceptedCallbacks == 1 and staleCallbacks == 1, "Duplicate probe must map its extra echo to one stale callback")
	observedMappings.duplicateProbe = { staleCallbacks = staleCallbacks }
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Corrupt one of eight broadcast recipients without mutating the caller or seven siblings.
do
	local submission = singleMeasured("state-broadcast-s2c")
	local ledgers = {}
	local sinks = {}
	local received = {}
	local mismatches = {}
	for receiverIndex = 1, 8 do
		ledgers[receiverIndex] = DeliveryLedger.new({ submission })
		sinks[receiverIndex] = function(delivery)
			received[receiverIndex] = delivery.value
			local _, mismatch = recordLedgerDelivery(ledgers[receiverIndex], delivery)
			mismatches[receiverIndex] = mismatch
		end
	end
	local rig = constructRig(workloadSelection("state-broadcast-s2c", 8), function() end, sinks, {
		action("Corrupt", "ServerToClient", 1, 4),
	})
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.server.broadcast(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("state", before, input, "corrupt broadcast caller input")
	for receiverIndex = 1, 8 do
		assert(received[receiverIndex] ~= input, "broadcast recipient must receive a transport-owned clone")
		if receiverIndex == 4 then
			local mismatch = mismatches[receiverIndex]
			assert(mismatch ~= nil and mismatch.reason == "ValueMismatch" and mismatch.path == "health", "corruption must produce health ValueMismatch")
			assert(received[receiverIndex].sequence == submission.expected.sequence, "corruption must preserve identity")
			assert(received[receiverIndex].health == (submission.expected.health + 1) % 101, "corruption must stay in the valid health range")
		else
			assert(mismatches[receiverIndex] == nil, `broadcast sibling {receiverIndex} must remain unchanged`)
			assertRecordEqual("state", submission.expected, received[receiverIndex], `broadcast sibling {receiverIndex}`)
		end
	end
	for left = 1, 8 do
		for right = left + 1, 8 do
			assert(received[left] ~= received[right], "broadcast siblings must not alias")
		end
	end
	local mismatchSnapshot: any = nil
	for receiverIndex = 1, 8 do
		local _, snapshot = ledgers[receiverIndex]:close()
		if receiverIndex == 4 then
			assert(snapshot.received == 1 and snapshot.correct == 0 and snapshot.mismatch == 1 and snapshot.missing == 0, "corrupt recipient counters must be exact")
			mismatchSnapshot = snapshot
		else
			assert(snapshot.received == 1 and snapshot.correct == 1 and snapshot.mismatch == 0, "sibling counters must stay clean")
		end
	end
	observedMappings.corrupt = { snapshot = mismatchSnapshot, mismatch = mismatches[4] }
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Delay beyond a test-owned deadline maps to timeout/missing and is canceled at teardown.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local ledger = DeliveryLedger.new({ submission })
	local callbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		callbacks += 1
		recordLedgerDelivery(ledger, delivery)
	end, { function() end }, {
		{ kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 3 },
	})
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	rig.driver.step()
	assert(callbacks == 0, "beyond-deadline delay must still be pending at the injected deadline")
	assertRecordEqual("tiny", before, input, "delay caller input")
	teardownRig(rig)
	assertPending(rig.control, { scheduled = 0 }, "beyond-deadline cancellation")
	local _, snapshot = ledger:close()
	assert(snapshot.missing == 1 and snapshot.received == 0, "beyond-deadline workload counters must show one missing")
	observedMappings.delayBeyond = snapshot
	rig.control:assertConsumed()
end

-- SeparateProbe Delay beyond its test-owned deadline yields timeout-only evidence and cancels cleanly.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local serverCallbacks = 0
	local clientCallbacks = 0
	local rig: any = nil
	rig = constructRig(probeSelection(), function(delivery)
		serverCallbacks += 1
		rig.server.broadcast(delivery.value, "FlushBeforeReturn")
	end, { function()
		clientCallbacks += 1
	end }, {
		{ kind = "Delay", target = deliveryTarget("ClientToServer", 1, 0), frames = 3 },
	})
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertPending(rig.control, { scheduled = 1 }, "probe beyond-deadline pending")
	rig.driver.step()
	assert(serverCallbacks == 0 and clientCallbacks == 0, "probe must have no response before delayed request is due")
	assertRecordEqual("tiny", before, input, "probe delay caller input")
	teardownRig(rig)
	assertPending(rig.control, { scheduled = 0 }, "probe beyond-deadline teardown cancellation")
	rig.driver.step()
	rig.driver.step()
	assert(serverCallbacks == 0 and clientCallbacks == 0, "canceled probe delay must never reach either sink")
	rig.control:assertConsumed()
	observedMappings.delayProbe = { timeout = true }
end

-- Unexpected workload: normal receipt succeeds; sequence -1 bypasses comparator and increments unexpected.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local ledger = DeliveryLedger.new({ submission })
	local comparatorCalls = 0
	local sequences = {}
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function(delivery)
		local actual = delivery.value
		table.insert(sequences, actual.sequence)
		local expected = ledger:expectedFor("tiny", actual.sequence)
		if expected == nil then
			ledger:recordDelivery("tiny", actual.sequence, false)
		else
			comparatorCalls += 1
			local matches = PayloadComparator.compareRecord("tiny", expected.expected, actual)
			ledger:recordDelivery("tiny", actual.sequence, matches)
		end
	end, { function() end }, { action("Unexpected", "ClientToServer", 1, 0) })
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "unexpected caller input")
	local _, snapshot = ledger:close()
	assert(sequences[1] == submission.sequence and sequences[2] == -1 and #sequences == 2, "Unexpected must append one fixed sequence -1 clone")
	assert(comparatorCalls == 1, "comparator must not run for the unresolved unexpected identity")
	assert(snapshot.received == 2 and snapshot.correct == 1 and snapshot.unexpected == 1 and snapshot.missing == 0, "Unexpected counters must be exact")
	observedMappings.unexpectedWorkload = snapshot
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- Unexpected probe: the extra unchanged echo is lifecycle-stale.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local completed = false
	local staleCallbacks = 0
	local acceptedCallbacks = 0
	local rig: any = nil
	rig = constructRig(probeSelection(), function(delivery)
		rig.server.broadcast(delivery.value, "FlushBeforeReturn")
	end, { function(delivery)
		if completed then
			staleCallbacks += 1
			return
		end
		completed = true
		acceptedCallbacks += 1
		assertRecordEqual("tiny", submission.expected, delivery.value, "unexpected probe accepted echo")
	end }, { action("Unexpected", "ServerToClient", 1, 1) })
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "unexpected probe caller input")
	assert(acceptedCallbacks == 1 and staleCallbacks == 1, "Unexpected probe must append one stale echo")
	observedMappings.unexpectedProbe = { staleCallbacks = staleCallbacks }
	teardownRig(rig)
	rig.control:assertConsumed()
end

-- A retained generation-N callback remains bound to the old sink after reset and never enters N+1.
do
	local submission = singleMeasured("tiny-steady-c2s")
	local ledger = DeliveryLedger.new({ submission })
	local runnerGeneration = 1
	local staleCallbacks = 0
	local comparatorCalls = 0
	local oldSinkCalls = 0
	local newSinkCalls = 0
	local function oldSink(delivery: any)
		oldSinkCalls += 1
		if runnerGeneration ~= 1 then
			staleCallbacks += 1
			return
		end
		comparatorCalls += 1
		recordLedgerDelivery(ledger, delivery)
	end
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), oldSink, { function() end }, {
		action("StaleAfterTeardown", "ClientToServer", 1, 0),
	})
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	runOperation(rig, function()
		rig.clients[1].submit(input, "FlushBeforeReturn")
	end)
	assertRecordEqual("tiny", before, input, "stale caller input")
	assert(oldSinkCalls == 1 and comparatorCalls == 1, "stale action must deliver normally first")
	assertPending(rig.control, { retainedStale = 1 }, "stale retained before teardown")
	teardownRig(rig)
	rig.control:assertConsumed()
	rig.control:reset()
	runnerGeneration = 2
	local server, clients = constructGeneration(rig.adapter, workloadSelection("tiny-steady-c2s", 1), function()
		newSinkCalls += 1
	end, { function() end })
	readyGeneration(server, clients)
	assertPending(rig.control, { generation = 2, retainedStale = 1 }, "stale retained after reset")
	rig.driver.step()
	assert(oldSinkCalls == 2 and staleCallbacks == 1, "retained callback must reach only its captured old sink")
	assert(newSinkCalls == 0, "retained callback must never enter the new-generation sink")
	assert(comparatorCalls == 1, "generation gate must stop stale callback before comparator")
	local _, snapshot = ledger:close()
	assert(snapshot.received == 1 and snapshot.correct == 1 and snapshot.duplicate == 0, "stale callback must not change ledger counters")
	assertPending(rig.control, { retainedStale = 0 }, "stale released")
	observedMappings.stale = { staleCallbacks = staleCallbacks, snapshot = snapshot }
	teardownGeneration(server, clients)
end

-- Lifecycle failures use only the production wrapper's redacted ordinary failure channel.
do
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function() end, { function() end }, {
		{ kind = "FailSetup", side = "Server", participantIndex = 0 },
	})
	assertError(function()
		rig.server.setup()
	end, "ADAPTER_E_SETUP", "fixed setup failure")
	assert(rig.driver.schedulerSubscriptionCount() == 0, "failed setup must not install the fake tail subscriber")
	rig.server.teardown()
	rig.clients[1].teardown()
	assertPending(rig.control, { scheduled = 0, heldReorder = 0, retainedStale = 0 }, "setup failure rollback")
	rig.control:assertConsumed()
	observedMappings.failSetup = { started = 0 }
end

do
	local submission = singleMeasured("tiny-steady-c2s")
	local callbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function()
		callbacks += 1
	end, { function() end }, {
		{ kind = "FailSubmit", direction = "ClientToServer", submitIndex = 1 },
	})
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	assertError(function()
		runOperation(rig, function()
			rig.clients[1].submit(input, "FlushBeforeReturn")
		end)
	end, "ADAPTER_E_SUBMIT", "fixed client submit failure")
	assertRecordEqual("tiny", before, input, "submit failure caller input")
	assert(callbacks == 0, "submit failure must precede transport acceptance")
	teardownRig(rig)
	rig.control:assertConsumed()
	observedMappings.failSubmit = { submitted = 0, received = 0 }
end

do
	local submission = singleMeasured("state-broadcast-s2c")
	local callbacks = 0
	local rig = constructRig(workloadSelection("state-broadcast-s2c", 1), function() end, { function()
		callbacks += 1
	end }, {
		{ kind = "FailSubmit", direction = "ServerToClient", submitIndex = 1 },
	})
	readyRig(rig)
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	assertError(function()
		runOperation(rig, function()
			rig.server.broadcast(input, "FlushBeforeReturn")
		end)
	end, "ADAPTER_E_BROADCAST", "fixed broadcast failure")
	assertRecordEqual("state", before, input, "broadcast failure caller input")
	assert(callbacks == 0, "broadcast failure must precede fan-out acceptance")
	teardownRig(rig)
	rig.control:assertConsumed()
end

do
	local callbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function()
		callbacks += 1
	end, { function() end }, {
		{ kind = "FailTeardown", side = "Client", participantIndex = 1 },
	})
	readyRig(rig)
	assertError(function()
		rig.clients[1].teardown()
	end, "ADAPTER_E_TEARDOWN", "fixed teardown failure")
	rig.clients[1].teardown()
	rig.server.teardown()
	rig.driver.step()
	assert(callbacks == 0, "teardown failure must not synthesize a callback")
	assertPending(rig.control, { scheduled = 0, heldReorder = 0, retainedStale = 0 }, "teardown failure cleanup")
	rig.control:assertConsumed()
	observedMappings.failTeardown = { cleaned = true }
end

-- Reorder is a configuration error for SeparateProbe and never becomes Result V1 evidence.
do
	local scheduler = newScheduler()
	local adapter, control = FakeAdapter.newTestRig(scheduler)
	control:loadFaultScript({ action("ReorderNext", "ClientToServer", 1, 0) })
	local preflight = supported(probeSelection())
	assertError(function()
		AdapterContract.constructServer(preflight, adapter, {}, { {} }, function() end)
	end, "ADAPTER_E_CONSTRUCT", "probe reorder configuration")
	assertError(function()
		control:assertConsumed()
	end, "FAKE_E_SCRIPT", "probe reorder remains non-result configuration")
end

-- The 16,384-record cap counts retained stale plus scheduled work and rejects atomically.
do
	local scheduler, driver = newScheduler()
	local adapter, control = FakeAdapter.newTestRig(scheduler)
	driver.installProducer()
	local tinySelection = workloadSelection("tiny-steady-c2s", 1)
	local tinyInput = Fixtures.newInput(singleMeasured("tiny-steady-c2s"))
	local retained = 0
	local function prepareRetainedGeneration(generationIndex: number): (any, { any }, number)
		local actionCount = if generationIndex <= 12 then 32 else 8
		local actions = {}
		for submitIndex = 1, actionCount do
			actions[submitIndex] = action("StaleAfterTeardown", "ClientToServer", submitIndex, 0)
		end
		control:loadFaultScript(actions)
		local server, clients = constructGeneration(adapter, tinySelection, function() end, { function() end })
		readyGeneration(server, clients)
		return server, clients, actionCount
	end

	local currentServer, currentClients, currentActionCount = prepareRetainedGeneration(1)
	local rawServer: any = nil
	local rawClients = {}
	local stateInput = Fixtures.newInput(singleMeasured("state-broadcast-s2c"))
	local before = cloneRecord(stateInput)
	local server: any = nil
	local clients: { any } = {}
	driver.run(function()
		for generationIndex = 1, 13 do
			if generationIndex > 1 then
				currentServer, currentClients, currentActionCount = prepareRetainedGeneration(generationIndex)
			end
			for _ = 1, currentActionCount do
				currentClients[1].submit(tinyInput, "ContinueFrame")
			end
			retained += currentActionCount
			assertPending(control, {
				scheduled = currentActionCount,
				retainedStale = retained,
			}, `cap retained generation {generationIndex} before teardown`)
			teardownGeneration(currentServer, currentClients)
			assertPending(control, {
				scheduled = 0,
				retainedStale = retained,
			}, `cap retained generation {generationIndex}`)
			control:assertConsumed()
			control:reset()
		end
		assert(retained == 392, "cap setup must retain exactly 392 stale callbacks")
		assertPending(control, { generation = 14, retainedStale = 392 }, "cap retained baseline")

		local delayActions = {}
		for receiverIndex = 1, 8 do
			delayActions[receiverIndex] = {
				kind = "Delay",
				target = deliveryTarget("ServerToClient", 1, receiverIndex),
				frames = 120,
			}
		end
		control:loadFaultScript(delayActions)
		local observingFactory = {
			constructServer = function(context: any)
				rawServer = adapter.constructServer(context)
				return rawServer
			end,
			constructClient = function(context: any)
				local rawClient = adapter.constructClient(context)
				rawClients[context.participantIndex] = rawClient
				return rawClient
			end,
		}
		server, clients = constructGeneration(
			observingFactory,
			workloadSelection("state-broadcast-s2c", 8),
			function() end,
			{ function() end, function() end, function() end, function() end, function() end, function() end, function() end, function() end }
		)
		readyGeneration(server, clients)
		for _ = 1, 1999 do
			server.broadcast(stateInput, "ContinueFrame")
		end
		assertPending(control, { scheduled = 15_992, retainedStale = 392 }, "pending-cap exactly full")
		assertError(function()
			rawServer.broadcast(stateInput, "FlushBeforeReturn")
		end, "FAKE_E_LIMIT", "pending-cap atomic rejection")
		assertPending(control, { scheduled = 15_992, retainedStale = 392 }, "pending-cap unchanged after rejection")
		control:assertConsumed()
	end)
	assertRecordEqual("state", before, stateInput, "pending-cap caller input")
	assertPending(control, { scheduled = 15_992, retainedStale = 392 }, "pending-cap exactly full")
	teardownGeneration(server, clients)
	assertPending(control, { scheduled = 0, retainedStale = 392 }, "pending-cap teardown cancellation")
	driver.step()
	assertPending(control, { scheduled = 0, retainedStale = 0 }, "pending-cap retained release")
end

-- A side is transport-active only after its own readiness observation, never merely after setup.
do
	local submission = singleMeasured("state-broadcast-s2c")
	local clientCallbacks = 0
	local rig = constructRig(workloadSelection("state-broadcast-s2c", 1), function() end, { function()
		clientCallbacks += 1
	end })
	rig.server.setup()
	assert(rig.server.ready() == true, "server must become ready independently")
	rig.clients[1].setup()
	assertError(function()
		rig.server.broadcast(Fixtures.newInput(submission), "FlushBeforeReturn")
	end, "ADAPTER_E_BROADCAST", "broadcast to AwaitingReady client")
	assert(clientCallbacks == 0, "AwaitingReady client sink must not be invoked")
	teardownRig(rig)
end

do
	local submission = singleMeasured("tiny-steady-c2s")
	local serverCallbacks = 0
	local rig = constructRig(workloadSelection("tiny-steady-c2s", 1), function()
		serverCallbacks += 1
	end, { function() end })
	rig.server.setup()
	rig.clients[1].setup()
	assert(rig.clients[1].ready() == true, "client must become ready independently")
	assertError(function()
		rig.clients[1].submit(Fixtures.newInput(submission), "FlushBeforeReturn")
	end, "ADAPTER_E_SUBMIT", "submit to AwaitingReady server")
	assert(serverCallbacks == 0, "AwaitingReady server sink must not be invoked")
	teardownRig(rig)
end

-- Compose raw evidence into in-memory Result V1 values without giving Result ownership to the fake.
local function findDefinition(values: { any }, id: string): any
	for _, value in values do
		if value.id == id then
			return value
		end
	end
	error(`unknown Event V1 definition {id}`, 0)
end

local function copyArray(values: { any }): { any }
	local copied = {}
	for _, value in values do
		table.insert(copied, value)
	end
	return copied
end

local function resultEnvironment(caseValue: any): any
	local count = if caseValue.kind == "SeparateProbe"
		then caseValue.clientCount
		elseif caseValue.workloadId == "state-broadcast-s2c" then caseValue.recipientCount
		else caseValue.senderCount
	return {
		studio = { version = STUDIO_VERSION, channel = "production" },
		host = {
			osFamily = "Windows",
			osVersion = "11",
			architecture = "x86_64",
			cpuModel = "Fake Test CPU",
			logicalProcessorCount = 8,
			memoryMiB = 16_384,
			gpuModel = "Fake Test GPU",
		},
		execution = {
			mode = "StudioMultiplayer",
			targetFrameRate = EventContract.execution.targetFrameRate,
			serverCount = 1,
			clientCount = count,
		},
	}
end

local function resultConformance(): any
	return {
		timingExclusionsConfirmed = {
			setup = true,
			warmup = true,
			quiescence = true,
			resultExtraction = true,
		},
		localClock = {
			source = "os.clock",
			unit = "seconds",
			scope = "SingleParticipant",
			quality = "Direct",
		},
		sharedClock = {
			source = "Workspace:GetServerTimeNow",
			unit = "seconds",
			scope = "CrossParticipant",
			quality = "EngineApproximation",
		},
		clockProof = { version = 1, passed = true },
	}
end

local function selectedMeasurements(caseValue: any): { any }
	local selected = {}
	for _, measurement in EventContract.measurements do
		if measurement.scope == caseValue.kind
			and (measurement.probeId == nil or measurement.probeId == caseValue.probeId)
		then
			table.insert(selected, measurement)
		end
	end
	return selected
end

local function addRequiredMeasurementFailures(failures: { any }, caseValue: any)
	for _, measurement in selectedMeasurements(caseValue) do
		if measurement.availability == "Required" then
			table.insert(failures, {
				category = "Measurement",
				code = "RequiredMeasurementUnavailable",
				occurrences = 1,
				discriminator = { measurementId = measurement.id },
			})
		end
	end
end

local function resultRawSamples(measurement: any, caseValue: any, definition: any, exactTotal: number?): { any }
	local participants = if measurement.capture.role == "Sender"
		then caseValue.senderCount
		elseif measurement.capture.role == "ProbeClient" then caseValue.clientCount
		else 1
	local cadence = measurement.capture.cadence
	local perGroup = if cadence == "PerMeasuredFrame"
		then definition.measuredFrames
		elseif cadence == "PerRepetition" then 1
		elseif cadence == "PerSubmission" then definition.measuredFrames * definition.messagesPerFrame
		elseif cadence == "PerProbe" then definition.measuredSamples
		else error("unknown Event V1 measurement cadence", 0)
	local groupCount = caseValue.scheduledRepetitions * participants
	local quotient = if exactTotal == nil then 0 else math.floor(exactTotal / groupCount)
	local remainder = if exactTotal == nil then 0 else exactTotal % groupCount
	if exactTotal ~= nil then
		assert(perGroup == 1, "exact Result V1 measurement must be PerRepetition")
	end
	local groups = table.create(groupCount)
	local ordinal = 0
	for repetitionIndex = 1, caseValue.scheduledRepetitions do
		for participantIndex = 1, participants do
			ordinal += 1
			local values = table.create(perGroup, 1)
			if exactTotal ~= nil then
				values[1] = quotient + (if ordinal <= remainder then 1 else 0)
			end
			local group = { repetitionIndex = repetitionIndex, values = values }
			if measurement.capture.role == "Sender" or measurement.capture.role == "ProbeClient" then
				group.participantIndex = participantIndex
			end
			groups[ordinal] = group
		end
	end
	return groups
end

local function completedMeasurements(caseValue: any, definition: any, counts: any?, failures: { any }): { any }
	local measurements = {}
	local valid = #failures == 0
	for _, measurement in selectedMeasurements(caseValue) do
		if measurement.availability == "Optional" then
			table.insert(measurements, {
				id = measurement.id,
				state = "Unavailable",
				unavailableReason = { code = "CaptureFailed" },
			})
		else
			local exactTotal: number? = nil
			if measurement.summary == "Exact" then
				assert(counts ~= nil and counts[measurement.id] ~= nil, `missing Result V1 exact count {measurement.id}`)
				exactTotal = counts[measurement.id]
			end
			table.insert(measurements, {
				id = measurement.id,
				state = if valid or measurement.summary == "Exact" then "Available" else "Diagnostic",
				rawSamples = resultRawSamples(measurement, caseValue, definition, exactTotal),
			})
		end
	end
	return measurements
end

local function incompleteMeasurements(caseValue: any): { any }
	local measurements = {}
	for _, measurement in selectedMeasurements(caseValue) do
		table.insert(measurements, {
			id = measurement.id,
			state = "Unavailable",
			unavailableReason = { code = "CaseNotCompleted" },
		})
	end
	return measurements
end

local function resultDraft(caseValue: any, failures: { any }, measurements: { any }, counts: any?): any
	local draft: any = {
		runId = "11111111-2222-4333-8444-555555555555",
		benchmarkSource = { revision = string.rep("a", 40), dirty = true },
		contractFingerprint = "sha256:" .. string.rep("c", 64),
		adapter = repositoryIdentity(),
		case = caseValue,
		failures = failures,
		conformance = resultConformance(),
		measurements = measurements,
		environment = resultEnvironment(caseValue),
	}
	if counts ~= nil then
		draft.counts = counts
	end
	return draft
end

local function workloadResult(
	workloadId: string,
	recipientCount: number,
	countOverrides: any?,
	suppliedFailures: { any }
): any
	local workload = findDefinition(EventContract.workloads, workloadId)
	local caseValue = {
		kind = "Workload",
		workloadId = workload.id,
		senderCount = workload.senderCount,
		recipientCount = recipientCount,
		scheduledRepetitions = workload.repetitions,
		startedRepetitions = workload.repetitions,
		completedRepetitions = workload.repetitions,
	}
	local expectedSubmissions = workload.repetitions * workload.senderCount * workload.measuredFrames * workload.messagesPerFrame
	local expectedDeliveries = expectedSubmissions * recipientCount
	local counts: any = {
		finality = "Final",
		expectedSubmissions = expectedSubmissions,
		submitted = expectedSubmissions,
		expectedDeliveries = expectedDeliveries,
		received = expectedDeliveries,
		correct = expectedDeliveries,
		missing = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
	}
	for key, value in countOverrides or {} do
		counts[key] = value
	end
	local failures = copyArray(suppliedFailures)
	return ResultV1.finalize(resultDraft(
		caseValue,
		failures,
		completedMeasurements(caseValue, workload, counts, failures),
		counts
	))
end

local function incompleteWorkloadResult(kind: "Setup" | "Submit"): any
	local workload = findDefinition(EventContract.workloads, "tiny-steady-c2s")
	local started = if kind == "Setup" then 0 else 1
	local caseValue = {
		kind = "Workload",
		workloadId = workload.id,
		senderCount = workload.senderCount,
		recipientCount = 1,
		scheduledRepetitions = workload.repetitions,
		startedRepetitions = started,
		completedRepetitions = 0,
	}
	local expected = workload.repetitions * workload.senderCount * workload.measuredFrames * workload.messagesPerFrame
	local counts = {
		finality = if kind == "Setup" then "NotStarted" else "Partial",
		expectedSubmissions = expected,
		submitted = 0,
		expectedDeliveries = expected,
		received = 0,
		correct = 0,
		missing = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
	}
	local failures = {
		{ category = "Lifecycle", code = if kind == "Setup" then "SetupFailure" else "SubmitFailure", occurrences = 1 },
	}
	addRequiredMeasurementFailures(failures, caseValue)
	return ResultV1.finalize(resultDraft(caseValue, failures, incompleteMeasurements(caseValue), counts))
end

local function probeResult(suppliedFailures: { any }, complete: boolean): any
	local probe = findDefinition(EventContract.probes, "tiny-round-trip")
	local failures = copyArray(suppliedFailures)
	local caseValue = {
		kind = "SeparateProbe",
		probeId = probe.id,
		clientCount = probe.clientCount,
		scheduledRepetitions = probe.repetitions,
		startedRepetitions = if complete then probe.repetitions else 1,
		completedRepetitions = if complete then probe.repetitions else 0,
	}
	local measurements
	if complete then
		measurements = completedMeasurements(caseValue, probe, nil, failures)
	else
		addRequiredMeasurementFailures(failures, caseValue)
		measurements = incompleteMeasurements(caseValue)
	end
	return ResultV1.finalize(resultDraft(caseValue, failures, measurements, nil))
end

local function assertMappedFailure(result: any, category: string, code: string, label: string)
	assert(result.status == "Invalid", `{label} must finalize Invalid`)
	assert(table.isfrozen(result), `{label} Result V1 must be frozen`)
	for _, failure in result.failures do
		if failure.category == category and failure.code == code then
			return
		end
	end
	error(`{label} is missing {category}/{code}`, 0)
end

local function assertNoFailure(result: any, code: string, label: string)
	for _, failure in result.failures do
		assert(failure.code ~= code, `{label} must not contain {code}`)
	end
end

assert(ResultV1.VERSION == 1, "focused fake test must compose the real Result V1 module")

local cleanResult = workloadResult("tiny-steady-c2s", 1, nil, {})
assert(cleanResult.status == "Valid" and #cleanResult.failures == 0, "None must map to a valid in-memory Result V1")
assert(withinDeadlineSnapshot ~= nil, "within-deadline raw ledger evidence must exist before Result V1 mapping")
local withinDeadlineResult = workloadResult("tiny-steady-c2s", 1, {
	received = 3_600 + withinDeadlineSnapshot.received - withinDeadlineSnapshot.expectedDeliveries,
	correct = 3_600 + withinDeadlineSnapshot.correct - withinDeadlineSnapshot.expectedDeliveries,
	missing = withinDeadlineSnapshot.missing,
	duplicate = withinDeadlineSnapshot.duplicate,
	unexpected = withinDeadlineSnapshot.unexpected,
	outOfOrder = withinDeadlineSnapshot.outOfOrder,
	mismatch = withinDeadlineSnapshot.mismatch,
}, {})
assert(withinDeadlineResult.status == "Valid", "within-deadline Delay must add no failure")
assert(
	withinDeadlineResult.counts.received == withinDeadlineResult.counts.expectedDeliveries
		and withinDeadlineResult.counts.correct == withinDeadlineResult.counts.expectedDeliveries,
	"within-deadline raw clean FIFO evidence must map to complete valid counts"
)

local dropResult = workloadResult("tiny-steady-c2s", 1, {
	received = 3_599,
	correct = 3_599,
	missing = 1,
}, {
	{ category = "Correctness", code = "MissingDelivery", occurrences = 1 },
	{ category = "Lifecycle", code = "Timeout", occurrences = 1 },
})
assertMappedFailure(dropResult, "Correctness", "MissingDelivery", "Drop workload")
assertMappedFailure(dropResult, "Lifecycle", "Timeout", "Drop workload timeout")

local duplicateResult = workloadResult("tiny-steady-c2s", 1, {
	received = 3_601,
	duplicate = 1,
}, {
	{ category = "Correctness", code = "DuplicateDelivery", occurrences = 1 },
})
assertMappedFailure(duplicateResult, "Correctness", "DuplicateDelivery", "Duplicate workload")

local mismatch = observedMappings.corrupt.mismatch
local corruptResult = workloadResult("state-broadcast-s2c", 1, {
	correct = 3_599,
	mismatch = 1,
}, {
	{
		category = "Correctness",
		code = "PayloadMismatch",
		occurrences = 1,
		discriminator = { mismatchReason = mismatch.reason },
		firstOccurrence = {
			repetitionIndex = 1,
			participant = { role = "Recipient", index = 1 },
			mismatch = mismatch,
		},
	},
})
assertMappedFailure(corruptResult, "Correctness", "PayloadMismatch", "Corrupt")
assert(corruptResult.failures[1].discriminator.mismatchReason == "ValueMismatch", "Corrupt Result V1 must retain ValueMismatch")

local reorderResult = workloadResult("tiny-steady-c2s", 1, { outOfOrder = 1 }, {
	{ category = "Correctness", code = "OutOfOrderDelivery", occurrences = 1 },
})
assertMappedFailure(reorderResult, "Correctness", "OutOfOrderDelivery", "ReorderNext workload")

local delayedTimeoutResult = workloadResult("tiny-steady-c2s", 1, {
	received = 3_599,
	correct = 3_599,
	missing = 1,
}, {
	{ category = "Correctness", code = "MissingDelivery", occurrences = 1 },
	{ category = "Lifecycle", code = "Timeout", occurrences = 1 },
})
assertMappedFailure(delayedTimeoutResult, "Correctness", "MissingDelivery", "Delay beyond deadline missing")
assertMappedFailure(delayedTimeoutResult, "Lifecycle", "Timeout", "Delay beyond deadline")
assertNoFailure(delayedTimeoutResult, "AddedDeliveryFrameLimitExceeded", "transport Delay")

local unexpectedResult = workloadResult("tiny-steady-c2s", 1, {
	received = 3_601,
	unexpected = 1,
}, {
	{ category = "Correctness", code = "UnexpectedDelivery", occurrences = 1 },
})
assertMappedFailure(unexpectedResult, "Correctness", "UnexpectedDelivery", "Unexpected workload")

local staleResult = workloadResult("tiny-steady-c2s", 1, nil, {
	{ category = "Contract", code = "StaleCallback", occurrences = 1 },
})
assertMappedFailure(staleResult, "Contract", "StaleCallback", "StaleAfterTeardown")
assert(staleResult.counts.received == staleResult.counts.expectedDeliveries, "stale callback must not change Result V1 counts")

local setupResult = incompleteWorkloadResult("Setup")
assertMappedFailure(setupResult, "Lifecycle", "SetupFailure", "FailSetup")
assert(setupResult.counts.finality == "NotStarted", "FailSetup must permit zero started repetitions")

local submitResult = incompleteWorkloadResult("Submit")
assertMappedFailure(submitResult, "Lifecycle", "SubmitFailure", "FailSubmit")
assert(submitResult.counts.finality == "Partial" and submitResult.counts.submitted == 0, "FailSubmit must remain Partial before acceptance")
assertNoFailure(submitResult, "SubmissionShortfall", "FailSubmit Partial result")
assertNoFailure(submitResult, "MissingDelivery", "FailSubmit Partial result")

local teardownResult = workloadResult("tiny-steady-c2s", 1, nil, {
	{ category = "Lifecycle", code = "TeardownFailure", occurrences = 1 },
})
assertMappedFailure(teardownResult, "Lifecycle", "TeardownFailure", "FailTeardown")

local dropProbeResult = probeResult({
	{ category = "Lifecycle", code = "Timeout", occurrences = 1 },
}, false)
assertMappedFailure(dropProbeResult, "Lifecycle", "Timeout", "Drop probe")
assert(dropProbeResult.counts == nil, "probe Result V1 must omit counts")

assert(observedMappings.delayProbe ~= nil and observedMappings.delayProbe.timeout == true, "probe delay timeout evidence must exist")
local delayedProbeResult = probeResult({
	{ category = "Lifecycle", code = "Timeout", occurrences = 1 },
}, false)
assertMappedFailure(delayedProbeResult, "Lifecycle", "Timeout", "Delay beyond deadline probe")
assert(delayedProbeResult.counts == nil, "delayed probe Result V1 must omit counts")
assertNoFailure(delayedProbeResult, "AddedDeliveryFrameLimitExceeded", "probe transport Delay")

for _, probeMapping in {
	{ label = "Duplicate probe", evidence = observedMappings.duplicateProbe },
	{ label = "Unexpected probe", evidence = observedMappings.unexpectedProbe },
	{ label = "Stale probe", evidence = observedMappings.stale },
} do
	assert(probeMapping.evidence ~= nil, `{probeMapping.label} raw evidence must exist`)
	local result = probeResult({
		{ category = "Contract", code = "StaleCallback", occurrences = 1 },
	}, true)
	assertMappedFailure(result, "Contract", "StaleCallback", probeMapping.label)
	assert(result.counts == nil, `{probeMapping.label} must omit counts`)
end

-- Static source boundary: no clocks, waits, benchmark registries, or correctness/result dependencies in the fake.
local fakeSource = fs.readFile("benchmarks/tests/support/FakeAdapter.luau")
assert(type(fakeSource) == "string" and #fakeSource > 0, "fake source must be readable")
for _, forbidden in {
	"os.clock",
	"tick",
	"time",
	"DateTime",
	"Workspace",
	"wait",
	"RemoteEvent",
	"require(",
	"AdapterContract",
	"Fixtures",
	"PayloadComparator",
	"DeliveryLedger",
	"ResultV1",
	"reporter",
	"reporting",
	"registry",
	"benchmarks/adapters",
} do
	assert(not string.find(fakeSource, forbidden, 1, true), `fake source must not contain {forbidden}`)
end

print("PASS Relay.Benchmarks.FakeAdapter")
