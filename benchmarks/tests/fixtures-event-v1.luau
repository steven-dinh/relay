local Contract = require("../contracts/event-v1")
local Fixtures = require("../fixtures/event-v1")

local FIXTURE_KEYS = { "contractVersion", "workloadId", "repetitionIndex", "warmup", "measured" }
local PROBE_FIXTURE_KEYS = { "contractVersion", "probeId", "repetitionIndex", "warmup", "measured" }
local SUBMISSION_KEYS = {
	"sequence",
	"payloadId",
	"phase",
	"frameIndex",
	"senderIndex",
	"messageIndex",
	"expected",
}
local PROBE_SAMPLE_KEYS = { "sequence", "payloadId", "phase", "sampleIndex", "expected" }

local floatBuffer = buffer.create(4)

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
	for _, key in expectedKeys do
		assert(value[key] ~= nil, `{label} is missing {key}`)
	end
end

assertExactKeys(Fixtures, { "generate", "generateProbe", "newInput" }, "Fixtures")
assert(type(Fixtures.generate) == "function", "Fixtures.generate must be a function")
assert(type(Fixtures.generateProbe) == "function", "Fixtures.generateProbe must be a function")
assert(type(Fixtures.newInput) == "function", "Fixtures.newInput must be a function")

local function assertDenseArray(value, expectedCount, label)
	assert(type(value) == "table", `{label} must be a table`)
	assert(#value == expectedCount, `{label} expected {expectedCount} entries, got {#value}`)
	local count = 0
	for key in value do
		count += 1
		assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= expectedCount, `{label} is not dense`)
	end
	assert(count == expectedCount, `{label} must not have extra keys`)
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

local function assertDeepEqual(actual, expected, path)
	assert(type(actual) == type(expected), `{path} has a type mismatch`)
	if type(actual) ~= "table" then
		assert(actual == expected, `{path} differs`)
		return
	end

	local actualCount = 0
	for key, actualValue in actual do
		actualCount += 1
		assert(expected[key] ~= nil, `{path} has unexpected key {tostring(key)}`)
		assertDeepEqual(actualValue, expected[key], `{path}.{tostring(key)}`)
	end

	local expectedCount = 0
	for key in expected do
		expectedCount += 1
		assert(actual[key] ~= nil, `{path} is missing key {tostring(key)}`)
	end
	assert(actualCount == expectedCount, `{path} has a key-count mismatch`)
end

local function assertFloat32(value, minimum, maximum, label)
	assert(type(value) == "number", `{label} must be a number`)
	assert(value == value and value > -math.huge and value < math.huge, `{label} must be finite`)
	assert(value >= minimum and value <= maximum, `{label} is outside its declared bounds`)
	assert(value ~= 0 or 1 / value == math.huge, `{label} must canonicalize negative zero`)
	buffer.writef32(floatBuffer, 0, value)
	assert(buffer.readf32(floatBuffer, 0) == value, `{label} must round-trip exactly through Float32`)
end

local function floatBits(value)
	buffer.writef32(floatBuffer, 0, value)
	return buffer.readu32(floatBuffer, 0)
end

local function assertPayload(payload, descriptor, sequence, label, observed)
	local fieldNames = {}
	for _, field in descriptor.fields do
		table.insert(fieldNames, field.name)
	end
	assertExactKeys(payload, fieldNames, label)

	for _, field in descriptor.fields do
		local value = payload[field.name]
		local fieldLabel = `{label}.{field.name}`
		if field.name == "sequence" then
			assert(value == sequence, `{fieldLabel} must equal the logical sequence`)
		end

		if field.valueType == "boolean" then
			assert(type(value) == "boolean", `{fieldLabel} must be boolean`)
		elseif field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32" then
			assert(type(value) == "number" and value % 1 == 0, `{fieldLabel} must be an integer`)
			assert(value >= field.minimum and value <= field.maximum, `{fieldLabel} is outside its declared bounds`)
		elseif field.valueType == "f32" then
			assertFloat32(value, field.minimum, field.maximum, fieldLabel)
		elseif field.valueType == "Vector3F32" then
			assert(typeof(value) == "Vector3", `{fieldLabel} must be a Vector3`)
			assertFloat32(value.X, field.minimum, field.maximum, `{fieldLabel}.X`)
			assertFloat32(value.Y, field.minimum, field.maximum, `{fieldLabel}.Y`)
			assertFloat32(value.Z, field.minimum, field.maximum, `{fieldLabel}.Z`)
		else
			error(`test does not recognize contract value type {field.valueType}`)
		end

		if field.name ~= "sequence" then
			if observed.has[field.name] then
				if value ~= observed.first[field.name] then
					observed.varied[field.name] = true
				end
			else
				observed.has[field.name] = true
				observed.first[field.name] = value
			end
			if field.valueType == "boolean" then
				observed.booleans[value] = true
			end
		end
	end
end

local function inspectPhase(fixture, workload, repetitionIndex, phaseName, frameCount, sequenceOffset, state)
	local submissions = phaseName == "Warmup" and fixture.warmup or fixture.measured
	local expectedCount = frameCount * workload.senderCount * workload.messagesPerFrame
	assertDenseArray(submissions, expectedCount, `{workload.id}.{repetitionIndex}.{phaseName}`)

	local index = 0
	for frameIndex = 1, frameCount do
		for senderIndex = 1, workload.senderCount do
			for messageIndex = 1, workload.messagesPerFrame do
				index += 1
				local submission = submissions[index]
				local sequence = (repetitionIndex - 1) * state.perRepetition + sequenceOffset + index - 1
				local label = `{workload.id}.{repetitionIndex}.{phaseName}[{index}]`
				assertExactKeys(submission, SUBMISSION_KEYS, label)
				assert(submission.sequence == sequence, `{label} sequence/order drifted`)
				assert(submission.payloadId == workload.payloadId, `{label} payload id drifted`)
				assert(submission.phase == phaseName, `{label} phase drifted`)
				assert(submission.frameIndex == frameIndex, `{label} frame order drifted`)
				assert(submission.senderIndex == senderIndex, `{label} sender order drifted`)
				assert(submission.messageIndex == messageIndex, `{label} message order drifted`)
				assert(not state.sequences[sequence], `{label} repeats sequence {sequence}`)
				state.sequences[sequence] = true
				state.sequenceCount += 1
				assert(submission.expected ~= state.previousPayload, `{label} must own one payload object`)
				state.previousPayload = submission.expected
				assertPayload(submission.expected, Contract.payloads[workload.payloadId], sequence, `{label}.expected`, state.observed)
			end
		end
	end
end

local workloadById = {}
for _, workload in Contract.workloads do
	workloadById[workload.id] = workload
	local warmupCount = workload.warmupFrames * workload.senderCount * workload.messagesPerFrame
	local measuredCount = workload.measuredFrames * workload.senderCount * workload.messagesPerFrame
	local state = {
		perRepetition = warmupCount + measuredCount,
		sequences = {},
		sequenceCount = 0,
		previousPayload = nil,
		observed = { has = {}, first = {}, varied = {}, booleans = {} },
	}

	for repetitionIndex = 1, workload.repetitions do
		local fixture = Fixtures.generate(workload.id, repetitionIndex)
		local label = `{workload.id}.{repetitionIndex}`
		assertExactKeys(fixture, FIXTURE_KEYS, label)
		assert(fixture.contractVersion == Contract.version, `{label} contract version drifted`)
		assert(fixture.workloadId == workload.id, `{label} workload identity drifted`)
		assert(fixture.repetitionIndex == repetitionIndex, `{label} repetition identity drifted`)
		assertDeepFrozen(fixture, label)
		inspectPhase(fixture, workload, repetitionIndex, "Warmup", workload.warmupFrames, 0, state)
		inspectPhase(fixture, workload, repetitionIndex, "Measured", workload.measuredFrames, warmupCount, state)
	end

	assert(
		state.sequenceCount == state.perRepetition * workload.repetitions,
		`{workload.id} must have one stable unique sequence per submission`
	)
	for _, field in Contract.payloads[workload.payloadId].fields do
		if field.name ~= "sequence" then
			assert(state.observed.varied[field.name], `{workload.id}.{field.name} must vary across messages`)
		end
	end
	if workload.payloadId == "tiny" then
		assert(state.observed.booleans[true] and state.observed.booleans[false], `{workload.id} must exercise both booleans`)
	end
end

local broadcastWorkload = workloadById["state-broadcast-s2c"]
local broadcast = Fixtures.generate(broadcastWorkload.id, 1)
assert(#broadcastWorkload.recipientCounts == 3, "broadcast must retain all declared recipient variants")
for _, recipientCount in broadcastWorkload.recipientCounts do
	assert(recipientCount == 1 or recipientCount == 4 or recipientCount == 8, "unexpected recipient variant")
	assert(#broadcast.warmup == 60 and #broadcast.measured == 120, "recipients must not multiply logical fixtures")
end

local function assertRejected(callback, label)
	local succeeded = pcall(callback)
	assert(not succeeded, `{label} must be rejected`)
end

assertRejected(function()
	Fixtures.generate("unknown-workload", 1)
end, "unknown workload")
assertRejected(function()
	Fixtures.generate(Contract.workloads[1].id, 0)
end, "repetition zero")
assertRejected(function()
	Fixtures.generate(Contract.workloads[1].id, 1.5)
end, "fractional repetition")
assertRejected(function()
	Fixtures.generate(Contract.workloads[1].id, Contract.workloads[1].repetitions + 1)
end, "repetition past the workload limit")

local probe = Contract.probes[1]
assertRejected(function()
	Fixtures.generateProbe("unknown-probe", 1)
end, "unknown probe")
assertRejected(function()
	Fixtures.generateProbe(Contract.workloads[1].id, 1)
end, "workload id as probe")
assertRejected(function()
	Fixtures.generate(probe.id, 1)
end, "probe id as workload")
assertRejected(function()
	Fixtures.generateProbe(probe.id, 0)
end, "probe repetition zero")
assertRejected(function()
	Fixtures.generateProbe(probe.id, 1.5)
end, "fractional probe repetition")
assertRejected(function()
	Fixtures.generateProbe(probe.id, probe.repetitions + 1)
end, "repetition past the probe limit")

local aThenB = Fixtures.generate("tiny-steady-c2s", 3)
local bAfterA = Fixtures.generate("state-burst-c2s", 2)
local bThenA = Fixtures.generate("state-burst-c2s", 2)
local aAfterB = Fixtures.generate("tiny-steady-c2s", 3)
assertDeepEqual(aThenB, aAfterB, "callOrder.tiny")
assertDeepEqual(bAfterA, bThenA, "callOrder.burst")

math.randomseed(73_921)
local controlFirst = math.random()
local controlSecond = math.random()
math.randomseed(73_921)
assert(math.random() == controlFirst, "random control seed must be reproducible")
Fixtures.generate("state-steady-c2s", 4)
assert(math.random() == controlSecond, "generation must not mutate global random state")
local randomIndependent = Fixtures.generate("state-steady-c2s", 4)
for _ = 1, 37 do
	math.random()
end
assertDeepEqual(randomIndependent, Fixtures.generate("state-steady-c2s", 4), "randomIndependence")

local probeFirst = Fixtures.generateProbe(probe.id, 3)
local workloadAfterProbe = Fixtures.generate("tiny-steady-c2s", 2)
local workloadFirst = Fixtures.generate("tiny-steady-c2s", 2)
local probeAfterWorkload = Fixtures.generateProbe(probe.id, 3)
assertDeepEqual(probeFirst, probeAfterWorkload, "callOrder.probe")
assertDeepEqual(workloadAfterProbe, workloadFirst, "callOrder.workloadAfterProbe")

math.randomseed(47_119)
local probeControlFirst = math.random()
local probeControlSecond = math.random()
math.randomseed(47_119)
assert(math.random() == probeControlFirst, "probe random control seed must be reproducible")
Fixtures.generateProbe(probe.id, 4)
assert(math.random() == probeControlSecond, "probe generation must not mutate global random state")

local oracleSubmission = Fixtures.generate("state-steady-c2s", 1).warmup[1]
local oracle = oracleSubmission.expected
local firstInput = Fixtures.newInput(oracleSubmission)
local secondInput = Fixtures.newInput(oracleSubmission)
assert(firstInput ~= secondInput and firstInput ~= oracle and secondInput ~= oracle, "newInput must return fresh records")
assert(not table.isfrozen(firstInput) and not table.isfrozen(secondInput), "newInput records must be mutable")
assertDeepEqual(firstInput, oracle, "newInput.first")
assertDeepEqual(secondInput, oracle, "newInput.second")
local oracleHealth = oracle.health
firstInput.health += 1
assert(firstInput.health ~= oracle.health, "mutating an input must make it differ from its oracle")
assert(oracle.health == oracleHealth and secondInput.health == oracleHealth, "input mutation must not affect oracle or sibling")

local tinyOracleSubmission = Fixtures.generate("tiny-steady-c2s", 1).warmup[1]
local tinyFirstInput = Fixtures.newInput(tinyOracleSubmission)
local tinySecondInput = Fixtures.newInput(tinyOracleSubmission)
assertExactKeys(tinyFirstInput, { "sequence", "enabled" }, "newInput.tiny.first")
assertExactKeys(tinySecondInput, { "sequence", "enabled" }, "newInput.tiny.second")
assert(
	tinyFirstInput ~= tinySecondInput and tinyFirstInput ~= tinyOracleSubmission.expected,
	"tiny newInput must return fresh records"
)
assert(not table.isfrozen(tinyFirstInput) and not table.isfrozen(tinySecondInput), "tiny inputs must be mutable")
assertDeepEqual(tinyFirstInput, tinyOracleSubmission.expected, "newInput.tiny.first")
assertDeepEqual(tinySecondInput, tinyOracleSubmission.expected, "newInput.tiny.second")

local probeFixture = Fixtures.generateProbe(probe.id, 1)
assertExactKeys(probeFixture, PROBE_FIXTURE_KEYS, "probe.1")
assert(probeFixture.contractVersion == Contract.version, "probe contract version drifted")
assert(probeFixture.probeId == probe.id, "probe identity drifted")
assert(probeFixture.repetitionIndex == 1, "probe repetition identity drifted")
assertDenseArray(probeFixture.warmup, probe.warmupSamples, "probe.1.Warmup")
assertDenseArray(probeFixture.measured, probe.measuredSamples, "probe.1.Measured")
assertDeepFrozen(probeFixture, "probe.1")

local probeSequences = {}
local function inspectProbePhase(samples, phase, sequenceOffset)
	for sampleIndex, sample in samples do
		local sequence = sequenceOffset + sampleIndex - 1
		local label = `probe.1.{phase}[{sampleIndex}]`
		assertExactKeys(sample, PROBE_SAMPLE_KEYS, label)
		assert(sample.sequence == sequence, `{label} sequence/order drifted`)
		assert(sample.payloadId == probe.payloadId, `{label} payload id drifted`)
		assert(sample.phase == phase, `{label} phase drifted`)
		assert(sample.sampleIndex == sampleIndex, `{label} sample order drifted`)
		assert(not probeSequences[sequence], `{label} repeats sequence {sequence}`)
		probeSequences[sequence] = true
		assertPayload(sample.expected, Contract.payloads[probe.payloadId], sequence, `{label}.expected`, {
			has = {},
			first = {},
			varied = {},
			booleans = {},
		})
	end
end

inspectProbePhase(probeFixture.warmup, "Warmup", 0)
inspectProbePhase(probeFixture.measured, "Measured", probe.warmupSamples)

local finalProbeRepetition = Fixtures.generateProbe(probe.id, probe.repetitions)
local finalProbeSequence = probe.repetitions * (probe.warmupSamples + probe.measuredSamples) - 1
assert(
	finalProbeRepetition.measured[#finalProbeRepetition.measured].sequence == finalProbeSequence,
	"probe sequences must remain unique across repetition boundaries"
)

local probeOracle = probeFixture.warmup[1].expected
local probeFirstInput = Fixtures.newInput(probeFixture.warmup[1])
local probeSecondInput = Fixtures.newInput(probeFixture.warmup[1])
assert(
	probeFirstInput ~= probeSecondInput and probeFirstInput ~= probeOracle and probeSecondInput ~= probeOracle,
	"probe newInput must return fresh records"
)
assert(not table.isfrozen(probeFirstInput) and not table.isfrozen(probeSecondInput), "probe inputs must be mutable")
assertDeepEqual(probeFirstInput, probeOracle, "probe.newInput.first")
assertDeepEqual(probeSecondInput, probeOracle, "probe.newInput.second")
local probeEnabled = probeOracle.enabled
probeFirstInput.enabled = not probeFirstInput.enabled
assert(
	probeOracle.enabled == probeEnabled and probeSecondInput.enabled == probeEnabled,
	"probe input mutation must not affect oracle or sibling"
)

local function assertGoldenIdentity(submission, sequence, phase, frameIndex, messageIndex, payloadId)
	assert(submission.sequence == sequence, "golden sequence drifted")
	assert(submission.phase == phase, "golden phase drifted")
	assert(submission.frameIndex == frameIndex, "golden frame drifted")
	assert(submission.senderIndex == 1, "golden sender drifted")
	assert(submission.messageIndex == messageIndex, "golden message index drifted")
	assert(submission.payloadId == payloadId and submission.expected.sequence == sequence, "golden payload identity drifted")
end

local function assertStateGolden(submission, sequence, phase, frameIndex, messageIndex, expected)
	assertGoldenIdentity(submission, sequence, phase, frameIndex, messageIndex, "state")
	local payload = submission.expected
	assert(payload.entityId == expected.entityId, "golden entityId drifted")
	assert(floatBits(payload.position.X) == expected.x, "golden position.X bits drifted")
	assert(floatBits(payload.position.Y) == expected.y, "golden position.Y bits drifted")
	assert(floatBits(payload.position.Z) == expected.z, "golden position.Z bits drifted")
	assert(floatBits(payload.yaw) == expected.yaw, "golden yaw bits drifted")
	assert(payload.health == expected.health, "golden health drifted")
end

local tinyRep1 = Fixtures.generate("tiny-steady-c2s", 1)
assertGoldenIdentity(tinyRep1.warmup[1], 0, "Warmup", 1, 1, "tiny")
assert(tinyRep1.warmup[1].expected.enabled == true, "tiny warmup golden drifted")
assertGoldenIdentity(tinyRep1.measured[1], 60, "Measured", 1, 1, "tiny")
assert(tinyRep1.measured[1].expected.enabled == false, "tiny measured golden drifted")
assertGoldenIdentity(tinyRep1.measured[120], 179, "Measured", 120, 1, "tiny")
assert(tinyRep1.measured[120].expected.enabled == false, "tiny final measured golden drifted")
local tinyRep2 = Fixtures.generate("tiny-steady-c2s", 2)
assertGoldenIdentity(tinyRep2.warmup[1], 180, "Warmup", 1, 1, "tiny")
assert(tinyRep2.warmup[1].expected.enabled == true, "tiny repetition-boundary golden drifted")

assert(probeFixture.warmup[1].sequence == 0, "probe warmup golden sequence drifted")
assert(probeFixture.warmup[1].sampleIndex == 1, "probe warmup golden sample identity drifted")
assert(probeFixture.warmup[1].expected.enabled == true, "probe warmup golden payload drifted")
assert(probeFixture.measured[1].sequence == 60, "probe measured golden sequence drifted")
assert(probeFixture.measured[1].sampleIndex == 1, "probe measured golden sample identity drifted")
assert(probeFixture.measured[1].expected.enabled == false, "probe measured golden payload drifted")
assert(probeFixture.measured[120].sequence == 179, "probe final measured golden sequence drifted")
assert(probeFixture.measured[120].sampleIndex == 120, "probe final measured golden sample identity drifted")
assert(probeFixture.measured[120].expected.enabled == false, "probe final measured golden payload drifted")
local probeRep2 = Fixtures.generateProbe(probe.id, 2)
assert(probeRep2.warmup[1].sequence == 180, "probe repetition-boundary golden sequence drifted")
assert(probeRep2.warmup[1].expected.enabled == true, "probe repetition-boundary golden payload drifted")

local steady = Fixtures.generate("state-steady-c2s", 1)
assertStateGolden(steady.warmup[1], 0, "Warmup", 1, 1, {
	entityId = 5_952, x = 0x43BF94C6, y = 0x43BFA544, z = 0x43BFB5C5, yaw = 0x4291FDF1, health = 4,
})
assertStateGolden(steady.measured[1], 60, "Measured", 1, 1, {
	entityId = 39_697, x = 0xC47E2486, y = 0xC47E3C45, z = 0xC47E3405, yaw = 0xC30B64EB, health = 36,
})

local burstRep1 = Fixtures.generate("state-burst-c2s", 1)
assertStateGolden(burstRep1.warmup[1_000], 999, "Warmup", 10, 100, {
	entityId = 19_305, x = 0x44549EDB, y = 0x4454861A, z = 0x44548E5A, yaw = 0x43264E0A, health = 57,
})
assertStateGolden(burstRep1.measured[1], 1_000, "Measured", 1, 1, {
	entityId = 59_395, x = 0x43AD2739, y = 0x43AD16B9, z = 0x43AD063A, yaw = 0x429B709D, health = 35,
})
assertStateGolden(burstRep1.measured[1_000], 1_999, "Measured", 10, 100, {
	entityId = 2_148, x = 0x42F132E4, y = 0x42F1F4E2, z = 0x42F1B6E0, yaw = 0x41D7185F, health = 97,
})
local burstRep2 = Fixtures.generate("state-burst-c2s", 2)
assertStateGolden(burstRep2.warmup[1], 2_000, "Warmup", 1, 1, {
	entityId = 57_818, x = 0xC4705870, y = 0xC47040B1, z = 0xC47048F1, yaw = 0xC30CCF2A, health = 67,
})

assertStateGolden(broadcast.warmup[1], 0, "Warmup", 1, 1, {
	entityId = 56_394, x = 0xC469660B, y = 0xC4697ECC, z = 0xC469768C, yaw = 0xC3134C32, health = 1,
})

print("PASS Relay.Benchmarks.EventFixturesV1")
