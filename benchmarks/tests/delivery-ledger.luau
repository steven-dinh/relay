local Contract = require("../contracts/event-v1")
local Fixtures = require("../fixtures/event-v1")
local DeliveryLedger = require("../correctness/DeliveryLedger")
local PayloadComparator = require("../correctness/PayloadComparator")

local SNAPSHOT_KEYS = {
	"expectedDeliveries",
	"received",
	"correct",
	"missing",
	"duplicate",
	"unexpected",
	"outOfOrder",
	"mismatch",
}

local function assertExactKeys(value, expectedKeys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local allowed = {}
	for _, key in expectedKeys do
		allowed[key] = true
	end

	local count = 0
	for key in value do
		count += 1
		assert(allowed[key], `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #expectedKeys, `{label} must have exactly {#expectedKeys} keys`)
end

local function cloneRecord(source)
	local result = {}
	for key, value in source do
		result[key] = value
	end
	return result
end

local function frozenSubmissionWith(source, field, value)
	local result = cloneRecord(source)
	result[field] = value
	return table.freeze(result)
end

local function expectedSnapshot(expectedDeliveries, overrides)
	local expected = {
		expectedDeliveries = expectedDeliveries,
		received = 0,
		correct = 0,
		missing = expectedDeliveries,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
	}
	for key, value in overrides do
		assert(expected[key] ~= nil, `unknown snapshot override {tostring(key)}`)
		expected[key] = value
	end
	return expected
end

local function assertSnapshot(actual, expected, label)
	assertExactKeys(actual, SNAPSHOT_KEYS, label)
	for _, key in SNAPSHOT_KEYS do
		local value = actual[key]
		assert(
			type(value) == "number" and value >= 0 and value % 1 == 0 and value < math.huge,
			`{label}.{key} must be a nonnegative finite integer`
		)
		assert(value == expected[key], `{label}.{key} expected {expected[key]}, got {value}`)
	end
end

local function assertRejected(callback, label)
	local succeeded = pcall(callback)
	assert(not succeeded, `{label} must be rejected`)
end

local function assertRecordUnchanged(actual, before, label)
	assertExactKeys(actual, (function()
		local keys = {}
		for key in before do
			table.insert(keys, key)
		end
		return keys
	end)(), label)
	for key, value in before do
		assert(actual[key] == value, `{label}.{tostring(key)} was mutated`)
	end
end

local function recordCompared(ledger, submission, mode, actual, label)
	local expected = ledger:expectedFor(submission.payloadId, submission.sequence)
	assert(expected == submission, `{label} must resolve the frozen fixture submission by reference`)
	assert(table.isfrozen(expected), `{label} expected submission must remain frozen`)

	actual = actual or Fixtures.newInput(submission)
	local before = cloneRecord(actual)
	local matches, mismatch
	if mode == "record" then
		matches, mismatch = PayloadComparator.compareRecord(expected.payloadId, expected.expected, actual)
	elseif mode == "positional" then
		local descriptor = Contract.payloads[expected.payloadId]
		local arguments = table.create(#descriptor.fields)
		for index, field in descriptor.fields do
			arguments[index] = rawget(actual, field.name)
		end
		matches, mismatch = PayloadComparator.comparePositional(
			expected.payloadId,
			expected.expected,
			table.unpack(arguments, 1, #descriptor.fields)
		)
	else
		error(`unknown comparator mode {tostring(mode)}`)
	end

	assert(matches == (mismatch == nil), `{label} comparator result and diagnostic must agree`)
	assertRecordUnchanged(actual, before, `{label}.actual`)
	local status, firstReceiptsCompletedNow = ledger:recordDelivery(
		submission.payloadId,
		submission.sequence,
		matches
	)
	return status, firstReceiptsCompletedNow, matches, mismatch
end

local function deliverAll(ledger, submissions, mode, label)
	local receiptEdges = 0
	for index, submission in submissions do
		local status, firstReceiptsCompletedNow, matches = recordCompared(
			ledger,
			submission,
			mode,
			nil,
			`{label}[{index}]`
		)
		assert(status == "Expected", `{label}[{index}] must be Expected`)
		assert(matches, `{label}[{index}] canonical payload must match`)
		assert(
			firstReceiptsCompletedNow == (index == #submissions),
			`{label}[{index}] receipt-complete edge differs`
		)
		if firstReceiptsCompletedNow then
			receiptEdges += 1
		end
	end
	assert(receiptEdges == 1, `{label} must emit exactly one receipt-complete edge`)
end

local function runCanonicalShard(submissions, mode, label)
	local ledger = DeliveryLedger.new(submissions)
	assert(ledger:expectedFor(submissions[1].payloadId, submissions[1].sequence) == submissions[1], `{label} lookup differs`)

	local isClean, becameCleanNow, initial = ledger:verify()
	assert(not isClean and not becameCleanNow, `{label} must begin dirty without a clean edge`)
	assertSnapshot(initial, expectedSnapshot(#submissions, {}), `{label}.initial`)

	deliverAll(ledger, submissions, mode, `{label}.delivery`)
	isClean, becameCleanNow, initial = ledger:verify()
	assert(isClean and becameCleanNow, `{label} must become clean exactly after canonical delivery`)
	assertSnapshot(
		initial,
		expectedSnapshot(#submissions, {
			received = #submissions,
			correct = #submissions,
			missing = 0,
		}),
		`{label}.firstClean`
	)

	local stillClean, secondCleanEdge, secondSnapshot = ledger:verify()
	assert(stillClean and not secondCleanEdge, `{label} clean edge must be one-time`)
	assert(secondSnapshot ~= initial, `{label} open verify must return a fresh snapshot`)
	assertSnapshot(
		secondSnapshot,
		expectedSnapshot(#submissions, {
			received = #submissions,
			correct = #submissions,
			missing = 0,
		}),
		`{label}.stillClean`
	)
	assert(ledger:expectedFor(submissions[#submissions].payloadId, submissions[#submissions].sequence) == submissions[#submissions], `{label} verify must not seal lookup`)

	local closedClean, sealed = ledger:close()
	assert(closedClean, `{label} canonical close must be clean`)
	assert(table.isfrozen(sealed), `{label} sealed snapshot must be frozen`)
	local closedAgain, sealedAgain = ledger:close()
	assert(closedAgain and sealedAgain == sealed, `{label} repeated close must reuse authoritative facts`)
	local verifiedAfterClose, edgeAfterClose, verifiedSnapshot = ledger:verify()
	assert(verifiedAfterClose and not edgeAfterClose and verifiedSnapshot == sealed, `{label} closed verify must reuse sealed facts`)
	assert(ledger:expectedFor(submissions[1].payloadId, submissions[1].sequence) == nil, `{label} closed lookup must be nil`)
	return sealed
end

local function sumSnapshots(snapshots)
	local sum = expectedSnapshot(0, {})
	for _, snapshot in snapshots do
		for _, key in SNAPSHOT_KEYS do
			sum[key] += snapshot[key]
		end
	end
	return sum
end

assertExactKeys(DeliveryLedger, { "new" }, "DeliveryLedger")
assert(type(DeliveryLedger.new) == "function", "DeliveryLedger.new must be a function")

-- Canonical client-to-server shards compose both comparator entry points with real fixtures.
local tinyMeasured = Fixtures.generate("tiny-steady-c2s", 1).measured
local stateMeasured = Fixtures.generate("state-steady-c2s", 1).measured
runCanonicalShard(tinyMeasured, "record", "tiny c2s server shard")
runCanonicalShard(stateMeasured, "positional", "state c2s server shard")

-- Broadcast delivery is receiver-local; global delivery totals are sums of independent shards.
local broadcastMeasured = Fixtures.generate("state-broadcast-s2c", 1).measured
for _, recipientCount in { 1, 4, 8 } do
	local snapshots = {}
	for receiverIndex = 1, recipientCount do
		table.insert(
			snapshots,
			runCanonicalShard(
				broadcastMeasured,
				"record",
				`broadcast {recipientCount} receivers shard {receiverIndex}`
			)
		)
	end
	local expectedDeliveries = #broadcastMeasured * recipientCount
	assertSnapshot(
		sumSnapshots(snapshots),
		expectedSnapshot(expectedDeliveries, {
			received = expectedDeliveries,
			correct = expectedDeliveries,
			missing = 0,
		}),
		`broadcast {recipientCount} receivers sum`
	)
	assert(expectedDeliveries == ({ 120, 480, 960 })[if recipientCount == 1 then 1 elseif recipientCount == 4 then 2 else 3], `broadcast {recipientCount} expected total drifted`)
end

-- A comparator mismatch consumes the known identity, never becomes missing, and cannot be repaired by a duplicate.
do
	local ledger = DeliveryLedger.new(stateMeasured)
	local corruptIndex = 37
	local receiptEdges = 0
	for index, submission in stateMeasured do
		local actual = nil
		if index == corruptIndex then
			actual = Fixtures.newInput(submission)
			actual.health = if actual.health < 100 then actual.health + 1 else actual.health - 1
		end
		local status, receiptEdge, matches, mismatch = recordCompared(
			ledger,
			submission,
			"record",
			actual,
			`corrupt[{index}]`
		)
		assert(status == "Expected", `corrupt[{index}] known identity must be Expected`)
		assert(matches == (index ~= corruptIndex), `corrupt[{index}] comparator verdict differs`)
		assert((mismatch ~= nil) == (index == corruptIndex), `corrupt[{index}] mismatch diagnostic differs`)
		if receiptEdge then
			receiptEdges += 1
			assert(index == #stateMeasured, "corrupt receipt edge must wait for every first identity")
		end
	end
	assert(receiptEdges == 1, "corrupt shard must emit receipt completion once")

	local isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, "corrupt shard must not become clean")
	assertSnapshot(
		snapshot,
		expectedSnapshot(#stateMeasured, {
			received = #stateMeasured,
			correct = #stateMeasured - 1,
			missing = 0,
			mismatch = 1,
		}),
		"corrupt snapshot"
	)

	local repairedStatus, repairedEdge, repairedMatch = recordCompared(
		ledger,
		stateMeasured[corruptIndex],
		"record",
		nil,
		"corrupt attempted repair"
	)
	assert(repairedStatus == "Duplicate" and not repairedEdge and repairedMatch, "duplicate must not repair corrupt first receipt")
	isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, "attempted repair must remain dirty")
	assertSnapshot(
		snapshot,
		expectedSnapshot(#stateMeasured, {
			received = #stateMeasured + 1,
			correct = #stateMeasured - 1,
			missing = 0,
			duplicate = 1,
			mismatch = 1,
		}),
		"corrupt attempted repair snapshot"
	)
end

-- Missing derives from unseen identities, so equal raw counts cannot mask a gap.
for _, maskingKind in { "duplicate", "unexpected" } do
	local ledger = DeliveryLedger.new(tinyMeasured)
	for index = 1, #tinyMeasured - 1 do
		local status, receiptEdge, matches = recordCompared(
			ledger,
			tinyMeasured[index],
			"record",
			nil,
			`missing {maskingKind}[{index}]`
		)
		assert(status == "Expected" and not receiptEdge and matches, `missing {maskingKind}[{index}] delivery differs`)
	end

	if maskingKind == "duplicate" then
		local status, receiptEdge = ledger:recordDelivery(
			tinyMeasured[1].payloadId,
			tinyMeasured[1].sequence,
			true
		)
		assert(status == "Duplicate" and not receiptEdge, "duplicate mask must classify Duplicate")
	else
		local status, receiptEdge = ledger:recordDelivery("unknown-payload", tinyMeasured[#tinyMeasured].sequence, true)
		assert(status == "Unexpected" and not receiptEdge, "unexpected mask must classify Unexpected")
	end

	local isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, `missing {maskingKind} mask must remain dirty`)
	assertSnapshot(
		snapshot,
		expectedSnapshot(#tinyMeasured, {
			received = #tinyMeasured,
			correct = #tinyMeasured - 1,
			missing = 1,
			duplicate = if maskingKind == "duplicate" then 1 else 0,
			unexpected = if maskingKind == "unexpected" then 1 else 0,
		}),
		`missing {maskingKind} mask snapshot`
	)
end

-- A duplicate increments received and duplicate, but correct remains a per-identity first verdict.
do
	local ledger = DeliveryLedger.new(tinyMeasured)
	local first = tinyMeasured[1]
	local status, receiptEdge = ledger:recordDelivery(first.payloadId, first.sequence, true)
	assert(status == "Expected" and not receiptEdge, "first duplicate case delivery must be Expected")
	status, receiptEdge = ledger:recordDelivery(first.payloadId, first.sequence, true)
	assert(status == "Duplicate" and not receiptEdge, "second duplicate case delivery must be Duplicate")
	local isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, "partial duplicate case must remain dirty")
	assertSnapshot(
		snapshot,
		expectedSnapshot(#tinyMeasured, {
			received = 2,
			correct = 1,
			missing = #tinyMeasured - 1,
			duplicate = 1,
		}),
		"duplicate snapshot"
	)
end

-- Malformed and unknown identities only affect scalar counters and never enter expected lookup state.
do
	local ledger = DeliveryLedger.new(tinyMeasured)
	local first = tinyMeasured[1]
	local unknownPayloadTable = { sentinel = "payload" }
	local unknownSequenceTable = { sentinel = "sequence" }
	local cases = {
		{ label = "nil payload id", payloadId = nil, sequence = first.sequence },
		{ label = "table payload id", payloadId = unknownPayloadTable, sequence = first.sequence },
		{ label = "unknown payload id", payloadId = "unknown-payload", sequence = first.sequence },
		{ label = "nil sequence", payloadId = first.payloadId, sequence = nil },
		{ label = "table sequence", payloadId = first.payloadId, sequence = unknownSequenceTable },
		{ label = "fractional sequence", payloadId = first.payloadId, sequence = first.sequence + 0.5 },
		{ label = "NaN sequence", payloadId = first.payloadId, sequence = 0 / 0 },
		{ label = "positive infinity sequence", payloadId = first.payloadId, sequence = math.huge },
		{ label = "negative infinity sequence", payloadId = first.payloadId, sequence = -math.huge },
		{ label = "unknown integer sequence", payloadId = first.payloadId, sequence = 4_294_967_295 },
	}

	for _, case in cases do
		assert(ledger:expectedFor(case.payloadId, case.sequence) == nil, `{case.label} lookup must be nil`)
		local status, receiptEdge = ledger:recordDelivery(case.payloadId, case.sequence, true)
		assert(status == "Unexpected" and not receiptEdge, `{case.label} must be Unexpected without an edge`)
		assert(ledger:expectedFor(case.payloadId, case.sequence) == nil, `{case.label} must not be retained`)
	end
	assert(unknownPayloadTable.sentinel == "payload", "unexpected payload identity table must not be mutated")
	assert(unknownSequenceTable.sentinel == "sequence", "unexpected sequence identity table must not be mutated")

	local isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, "malformed identities must leave shard dirty")
	assertSnapshot(
		snapshot,
		expectedSnapshot(#tinyMeasured, {
			received = #cases,
			unexpected = #cases,
		}),
		"malformed identity snapshot"
	)
	local _, _, repeatedSnapshot = ledger:verify()
	assert(repeatedSnapshot ~= snapshot, "open malformed verification must return a fresh snapshot")
	assertSnapshot(repeatedSnapshot, expectedSnapshot(#tinyMeasured, {
		received = #cases,
		unexpected = #cases,
	}), "malformed identity repeated snapshot")
end

-- Filling an adjacent gap advances over the already-seen identity without cascading reorder faults.
do
	local ledger = DeliveryLedger.new(stateMeasured)
	for _, index in { 1, 3, 2 } do
		local status, receiptEdge, matches = recordCompared(
			ledger,
			stateMeasured[index],
			"record",
			nil,
			`adjacent reorder[{index}]`
		)
		assert(status == "Expected" and not receiptEdge and matches, `adjacent reorder[{index}] delivery differs`)
	end
	for index = 4, #stateMeasured do
		local status, receiptEdge, matches = recordCompared(
			ledger,
			stateMeasured[index],
			"record",
			nil,
			`adjacent tail[{index}]`
		)
		assert(status == "Expected" and matches, `adjacent tail[{index}] delivery differs`)
		assert(receiptEdge == (index == #stateMeasured), `adjacent tail[{index}] receipt edge differs`)
	end
	local isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, "reordered shard must remain dirty")
	assertSnapshot(
		snapshot,
		expectedSnapshot(#stateMeasured, {
			received = #stateMeasured,
			correct = #stateMeasured,
			missing = 0,
			outOfOrder = 1,
		}),
		"adjacent reorder snapshot"
	)
end

-- Only the receiver-local shard that reordered is faulty; aggregation preserves that single fault.
do
	local snapshots = {}
	local cleanShards = 0
	for receiverIndex = 1, 4 do
		local ledger = DeliveryLedger.new(broadcastMeasured)
		if receiverIndex == 3 then
			for _, index in { 1, 3, 2 } do
				local status = recordCompared(ledger, broadcastMeasured[index], "record", nil, `bad broadcast[{index}]`)
				assert(status == "Expected", `bad broadcast[{index}] must be Expected`)
			end
			for index = 4, #broadcastMeasured do
				local status = recordCompared(ledger, broadcastMeasured[index], "record", nil, `bad broadcast tail[{index}]`)
				assert(status == "Expected", `bad broadcast tail[{index}] must be Expected`)
			end
		else
			deliverAll(ledger, broadcastMeasured, "record", `clean broadcast shard {receiverIndex}`)
		end

		local isClean, becameCleanNow, snapshot = ledger:verify()
		if receiverIndex == 3 then
			assert(not isClean and not becameCleanNow, "reordered broadcast shard must be dirty")
		else
			assert(isClean and becameCleanNow, `broadcast shard {receiverIndex} must be clean`)
			cleanShards += 1
		end
		local closedClean, sealed = ledger:close()
		assert(closedClean == isClean, `broadcast shard {receiverIndex} close cleanliness differs`)
		table.insert(snapshots, sealed)
	end
	assert(cleanShards == 3, "exactly three broadcast shards must remain clean")
	assertSnapshot(
		sumSnapshots(snapshots),
		expectedSnapshot(480, {
			received = 480,
			correct = 480,
			missing = 0,
			outOfOrder = 1,
		}),
		"one bad broadcast shard sum"
	)
end

-- Verification is non-sealing: a late duplicate after the clean edge remains observable.
do
	local ledger = DeliveryLedger.new(tinyMeasured)
	deliverAll(ledger, tinyMeasured, "record", "late duplicate canonical")
	local isClean, becameCleanNow = ledger:verify()
	assert(isClean and becameCleanNow, "late duplicate case must first become clean")
	local status, receiptEdge = ledger:recordDelivery(tinyMeasured[1].payloadId, tinyMeasured[1].sequence, true)
	assert(status == "Duplicate" and not receiptEdge, "late callback must be observed as Duplicate")
	local snapshot
	isClean, becameCleanNow, snapshot = ledger:verify()
	assert(not isClean and not becameCleanNow, "late duplicate must invalidate the next verification without a new edge")
	assertSnapshot(
		snapshot,
		expectedSnapshot(#tinyMeasured, {
			received = #tinyMeasured + 1,
			correct = #tinyMeasured,
			missing = 0,
			duplicate = 1,
		}),
		"late duplicate snapshot"
	)
end

-- One sink closure routes atomically from a warmup shard to a fresh measured shard.
do
	local fixtures = Fixtures.generate("tiny-steady-c2s", 2)
	local warmupLedger = DeliveryLedger.new(fixtures.warmup)
	local measuredLedger = DeliveryLedger.new(fixtures.measured)
	local activeShard = warmupLedger
	local callbackCount = 0

	local function deliverySink(submission)
		callbackCount += 1
		local expected = activeShard:expectedFor(submission.payloadId, submission.sequence)
		if expected == nil then
			return activeShard:recordDelivery(submission.payloadId, submission.sequence, false)
		end
		local actual = Fixtures.newInput(submission)
		local matches = PayloadComparator.compareRecord(expected.payloadId, expected.expected, actual)
		return activeShard:recordDelivery(submission.payloadId, submission.sequence, matches)
	end

	for index, submission in fixtures.warmup do
		local status, receiptEdge = deliverySink(submission)
		assert(status == "Expected", `warmup route[{index}] must be Expected`)
		assert(receiptEdge == (index == #fixtures.warmup), `warmup route[{index}] receipt edge differs`)
	end
	local warmupClean, warmupEdge = warmupLedger:verify()
	assert(warmupClean and warmupEdge, "warmup shard must become clean before routing switch")

	activeShard = measuredLedger
	local closedWarmup, warmupSnapshot = warmupLedger:close()
	assert(closedWarmup and table.isfrozen(warmupSnapshot), "warmup must seal clean after atomic switch")
	local status, receiptEdge = deliverySink(fixtures.warmup[1])
	assert(status == "Unexpected" and not receiptEdge, "late warmup identity must reach measured as Unexpected")
	assert(callbackCount == #fixtures.warmup + 1, "stable sink callback count differs")

	local measuredClean, measuredEdge, measuredSnapshot = measuredLedger:verify()
	assert(not measuredClean and not measuredEdge, "fresh measured shard with late warmup data must be dirty")
	assertSnapshot(
		measuredSnapshot,
		expectedSnapshot(#fixtures.measured, {
			received = 1,
			unexpected = 1,
		}),
		"warmup to measured route snapshot"
	)
end

-- Close before verification is idempotent and authoritative; later calls cannot alter it or emit a clean edge.
do
	local warmup = Fixtures.generate("tiny-steady-c2s", 3).warmup
	local ledger = DeliveryLedger.new(warmup)
	deliverAll(ledger, warmup, "record", "sealed lifecycle")
	local closedClean, sealed = ledger:close()
	local closedAgain, sealedAgain = ledger:close()
	assert(closedClean and closedAgain and sealedAgain == sealed, "close must be idempotent")
	assert(table.isfrozen(sealed), "close snapshot must be frozen")
	assertRejected(function()
		sealed.received = 0
	end, "sealed snapshot mutation")

	local sealedExpected = expectedSnapshot(#warmup, {
		received = #warmup,
		correct = #warmup,
		missing = 0,
	})
	assertSnapshot(sealed, sealedExpected, "sealed authoritative snapshot")
	assert(ledger:expectedFor(warmup[1].payloadId, warmup[1].sequence) == nil, "closed expectedFor must return nil")
	local status, receiptEdge = ledger:recordDelivery(warmup[1].payloadId, warmup[1].sequence, true)
	assert(status == "AfterTeardown" and not receiptEdge, "closed delivery must be AfterTeardown")
	local verifiedClean, verifiedEdge, verifiedSnapshot = ledger:verify()
	assert(verifiedClean and not verifiedEdge and verifiedSnapshot == sealed, "closed verify must return sealed authority")
	assertSnapshot(verifiedSnapshot, sealedExpected, "post-teardown unchanged snapshot")
	local finalClean, finalSnapshot = ledger:close()
	assert(finalClean and finalSnapshot == sealed, "post-teardown close must remain identical")
end

-- Constructor rejects fixture/config defects before allocating an observation shard.
do
	local fixture = Fixtures.generate("tiny-steady-c2s", 4)
	local valid = fixture.warmup[1]
	assertRejected(function()
		DeliveryLedger.new(nil)
	end, "nil submissions")
	assertRejected(function()
		DeliveryLedger.new({})
	end, "empty submissions")
	assertRejected(function()
		DeliveryLedger.new({ [1] = valid, [3] = fixture.warmup[3] })
	end, "sparse submissions")
	assertRejected(function()
		DeliveryLedger.new({ [1] = valid, extra = fixture.warmup[2] })
	end, "submissions with extra key")
	assertRejected(function()
		DeliveryLedger.new({ "not a submission" })
	end, "non-table submission")
	assertRejected(function()
		DeliveryLedger.new({ cloneRecord(valid) })
	end, "mutable submission")
	assertRejected(function()
		DeliveryLedger.new({ frozenSubmissionWith(valid, "phase", "Setup") })
	end, "invalid phase")
	assertRejected(function()
		DeliveryLedger.new({ fixture.warmup[1], fixture.measured[1] })
	end, "mixed phases")
	assertRejected(function()
		DeliveryLedger.new({ frozenSubmissionWith(valid, "payloadId", "unknown-payload") })
	end, "unknown payload id")
	assertRejected(function()
		DeliveryLedger.new({ frozenSubmissionWith(valid, "payloadId", {}) })
	end, "malformed payload id")
	for _, case in {
		{ label = "nil sequence", value = nil },
		{ label = "table sequence", value = {} },
		{ label = "fractional sequence", value = valid.sequence + 0.5 },
		{ label = "NaN sequence", value = 0 / 0 },
		{ label = "positive infinity sequence", value = math.huge },
		{ label = "negative infinity sequence", value = -math.huge },
		{ label = "negative sequence", value = -1 },
	} do
		assertRejected(function()
			DeliveryLedger.new({ frozenSubmissionWith(valid, "sequence", case.value) })
		end, `constructor {case.label}`)
	end
	assertRejected(function()
		DeliveryLedger.new({ frozenSubmissionWith(valid, "senderIndex", 2) })
	end, "multiple-sender submission")
	assertRejected(function()
		DeliveryLedger.new({ valid, valid })
	end, "duplicate expected identity")

	local validLedger = DeliveryLedger.new(fixture.warmup)
	assert(validLedger:expectedFor(valid.payloadId, valid.sequence) == valid, "valid constructor must retain submission reference")
	assert(table.isfrozen(valid) and table.isfrozen(valid.expected), "constructor must not thaw fixture data")
	local isClean, becameCleanNow, snapshot = validLedger:verify()
	assert(not isClean and not becameCleanNow, "valid untouched constructor must begin dirty")
	assertSnapshot(snapshot, expectedSnapshot(#fixture.warmup, {}), "valid untouched constructor snapshot")
end

print("PASS Relay.Benchmarks.DeliveryLedger")
