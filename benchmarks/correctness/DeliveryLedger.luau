--!strict

local Contract = require("../contracts/event-v1")

export type Phase = "Warmup" | "Measured"
export type DeliveryStatus = "Expected" | "Duplicate" | "Unexpected" | "AfterTeardown"

export type LogicalSubmission = {
	sequence: number,
	payloadId: string,
	phase: Phase,
	frameIndex: number,
	senderIndex: number,
	messageIndex: number,
	expected: { [string]: any },
}

export type Snapshot = {
	expectedDeliveries: number,
	received: number,
	correct: number,
	missing: number,
	duplicate: number,
	unexpected: number,
	outOfOrder: number,
	mismatch: number,
}

type ExpectedEntry = {
	submission: LogicalSubmission,
	ordinal: number,
	seen: boolean,
}

type State = {
	expectedCount: number,
	expectedByPayload: { [string]: { [number]: ExpectedEntry } },
	orderedEntries: { ExpectedEntry },
	nextUnseenOrdinal: number,
	seenCount: number,
	received: number,
	correct: number,
	duplicate: number,
	unexpected: number,
	outOfOrder: number,
	mismatch: number,
	receiptsCompletionEmitted: boolean,
	cleanEdgeEmitted: boolean,
	closed: boolean,
	sealedClean: boolean,
	sealedSnapshot: Snapshot?,
}

local Ledger = {}
Ledger.__index = Ledger

export type DeliveryLedger = typeof(setmetatable({} :: State, Ledger))

local UINT32_MAX = 0xFFFFFFFF

local function isSequence(value: any): boolean
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
		and value % 1 == 0
		and value >= 0
		and value <= UINT32_MAX
end

local function submissionCount(submissions: any): number
	assert(type(submissions) == "table", "submissions must be a table")

	local count = 0
	for key in submissions do
		assert(
			type(key) == "number" and key % 1 == 0 and key >= 1,
			"submissions must be a dense array"
		)
		count += 1
	end

	assert(count > 0, "submissions must not be empty")
	for index = 1, count do
		assert(rawget(submissions, index) ~= nil, "submissions must be a dense array")
	end

	return count
end

local function makeSnapshot(state: State): Snapshot
	return table.freeze({
		expectedDeliveries = state.expectedCount,
		received = state.received,
		correct = state.correct,
		missing = state.expectedCount - state.seenCount,
		duplicate = state.duplicate,
		unexpected = state.unexpected,
		outOfOrder = state.outOfOrder,
		mismatch = state.mismatch,
	})
end

local function isClean(snapshot: Snapshot): boolean
	return snapshot.received == snapshot.expectedDeliveries
		and snapshot.correct == snapshot.expectedDeliveries
		and snapshot.missing == 0
		and snapshot.duplicate == 0
		and snapshot.unexpected == 0
		and snapshot.outOfOrder == 0
		and snapshot.mismatch == 0
end

function Ledger.expectedFor(
	self: DeliveryLedger,
	payloadId: unknown,
	sequence: unknown
): LogicalSubmission?
	if self.closed or type(payloadId) ~= "string" or not isSequence(sequence) then
		return nil
	end

	local expectedBySequence = self.expectedByPayload[payloadId]
	if expectedBySequence == nil then
		return nil
	end

	local entry = expectedBySequence[sequence :: number]
	return if entry == nil then nil else entry.submission
end

function Ledger.recordDelivery(
	self: DeliveryLedger,
	payloadId: unknown,
	sequence: unknown,
	payloadMatches: boolean
): (DeliveryStatus, boolean)
	if self.closed then
		return "AfterTeardown", false
	end

	assert(type(payloadMatches) == "boolean", "payloadMatches must be a boolean")
	self.received += 1

	if type(payloadId) ~= "string" or not isSequence(sequence) then
		self.unexpected += 1
		return "Unexpected", false
	end

	local expectedBySequence = self.expectedByPayload[payloadId]
	local entry = if expectedBySequence == nil then nil else expectedBySequence[sequence :: number]
	if entry == nil then
		self.unexpected += 1
		return "Unexpected", false
	end

	if entry.seen then
		self.duplicate += 1
		return "Duplicate", false
	end

	entry.seen = true
	self.seenCount += 1
	if entry.ordinal ~= self.nextUnseenOrdinal then
		self.outOfOrder += 1
	end

	while self.nextUnseenOrdinal <= self.expectedCount do
		local nextEntry = self.orderedEntries[self.nextUnseenOrdinal]
		if not nextEntry.seen then
			break
		end
		self.nextUnseenOrdinal += 1
	end

	if payloadMatches then
		self.correct += 1
	else
		self.mismatch += 1
	end

	local firstReceiptsCompletedNow = false
	if self.seenCount == self.expectedCount and not self.receiptsCompletionEmitted then
		self.receiptsCompletionEmitted = true
		firstReceiptsCompletedNow = true
	end

	return "Expected", firstReceiptsCompletedNow
end

function Ledger.verify(self: DeliveryLedger): (boolean, boolean, Snapshot)
	local sealedSnapshot = self.sealedSnapshot
	if sealedSnapshot ~= nil then
		return self.sealedClean, false, sealedSnapshot
	end

	local snapshot = makeSnapshot(self)
	local clean = isClean(snapshot)
	local becameCleanNow = clean and not self.cleanEdgeEmitted
	if becameCleanNow then
		self.cleanEdgeEmitted = true
	end

	return clean, becameCleanNow, snapshot
end

function Ledger.close(self: DeliveryLedger): (boolean, Snapshot)
	local sealedSnapshot = self.sealedSnapshot
	if sealedSnapshot ~= nil then
		return self.sealedClean, sealedSnapshot
	end

	local snapshot = makeSnapshot(self)
	local clean = isClean(snapshot)
	self.closed = true
	self.sealedClean = clean
	self.sealedSnapshot = snapshot
	return clean, snapshot
end

local function new(submissions: { LogicalSubmission }): DeliveryLedger
	local count = submissionCount(submissions)
	local expectedByPayload: { [string]: { [number]: ExpectedEntry } } = {}
	local orderedEntries: { ExpectedEntry } = table.create(count)
	local phase: Phase? = nil

	for ordinal = 1, count do
		local submission: any = rawget(submissions, ordinal)
		assert(type(submission) == "table", `submission {ordinal} must be a table`)
		assert(table.isfrozen(submission), `submission {ordinal} must be frozen`)
		assert(
			submission.phase == "Warmup" or submission.phase == "Measured",
			`submission {ordinal} has an invalid phase`
		)
		if phase == nil then
			phase = submission.phase
		else
			assert(submission.phase == phase, "submissions must belong to one phase")
		end

		local payloadId = submission.payloadId
		assert(
			type(payloadId) == "string" and Contract.payloads[payloadId] ~= nil,
			`submission {ordinal} has an invalid payloadId`
		)
		local sequence = submission.sequence
		assert(isSequence(sequence), `submission {ordinal} has an invalid sequence`)
		assert(
			submission.senderIndex == 1,
			`submission {ordinal} must use Event V1's single senderIndex 1`
		)

		local expectedBySequence = expectedByPayload[payloadId]
		if expectedBySequence == nil then
			expectedBySequence = {}
			expectedByPayload[payloadId] = expectedBySequence
		end
		assert(
			expectedBySequence[sequence] == nil,
			`submission {ordinal} duplicates payloadId/sequence identity`
		)

		local entry: ExpectedEntry = {
			submission = submission,
			ordinal = ordinal,
			seen = false,
		}
		expectedBySequence[sequence] = entry
		orderedEntries[ordinal] = entry
	end

	return setmetatable({
		expectedCount = count,
		expectedByPayload = expectedByPayload,
		orderedEntries = orderedEntries,
		nextUnseenOrdinal = 1,
		seenCount = 0,
		received = 0,
		correct = 0,
		duplicate = 0,
		unexpected = 0,
		outOfOrder = 0,
		mismatch = 0,
		receiptsCompletionEmitted = false,
		cleanEdgeEmitted = false,
		closed = false,
		sealedClean = false,
		sealedSnapshot = nil,
	}, Ledger)
end

return {
	new = new,
}
