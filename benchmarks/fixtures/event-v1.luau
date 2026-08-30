--!strict

local Contract = require("../contracts/event-v1")

local Vector3Class = if Vector3 ~= nil then Vector3 else require("@lune/roblox").Vector3

local BASE = 0x9E3779B9
local PROBE_SALT = 0x165667B1
local SEQUENCE_SALT = 0x85EBCA6B
local FIELD_SALT = 0xC2B2AE35
local COMPONENT_SALT = 0x27D4EB2F
local UINT32_MAX = 0xFFFFFFFF

type Phase = "Warmup" | "Measured"
type PayloadRecord = { [string]: any }
type LogicalSubmission = {
	sequence: number,
	payloadId: string,
	phase: Phase,
	frameIndex: number,
	senderIndex: number,
	messageIndex: number,
	expected: PayloadRecord,
}
export type FixtureSet = {
	contractVersion: number,
	workloadId: string,
	repetitionIndex: number,
	warmup: { LogicalSubmission },
	measured: { LogicalSubmission },
}
type ProbeSample = {
	sequence: number,
	payloadId: string,
	phase: Phase,
	sampleIndex: number,
	expected: PayloadRecord,
}
export type ProbeFixtureSet = {
	contractVersion: number,
	probeId: string,
	repetitionIndex: number,
	warmup: { ProbeSample },
	measured: { ProbeSample },
}
type InputSubmission = {
	payloadId: string,
	expected: PayloadRecord,
}

local function scramble(value: number): number
	value = bit32.bxor(value, bit32.lshift(value, 13))
	value = bit32.bxor(value, bit32.rshift(value, 17))
	return bit32.bxor(value, bit32.lshift(value, 5))
end

local function workloadSeed(workloadPosition: number): number
	local state = scramble(bit32.bxor(BASE, Contract.version))
	state = scramble(bit32.bxor(state, Contract.fixture.seed))
	return scramble(bit32.bxor(state, workloadPosition))
end

local function probeSeed(probePosition: number): number
	local state = scramble(bit32.bxor(BASE, Contract.version))
	state = scramble(bit32.bxor(state, Contract.fixture.seed))
	state = scramble(bit32.bxor(state, PROBE_SALT))
	return scramble(bit32.bxor(state, probePosition))
end

local function mix(seed: number, sequence: number, fieldPosition: number, componentPosition: number): number
	local state = scramble(bit32.bxor(seed, sequence, SEQUENCE_SALT))
	state = scramble(bit32.bxor(state, fieldPosition, FIELD_SALT))
	return scramble(bit32.bxor(state, componentPosition, COMPONENT_SALT))
end

local function integerInRange(value: number, minimum: number, maximum: number): number
	return minimum + value % (maximum - minimum + 1)
end

local function float32InRange(
	value: number,
	minimum: number,
	maximum: number,
	floatBuffer: buffer
): number
	local mapped = minimum + (maximum - minimum) * (value / UINT32_MAX)
	buffer.writef32(floatBuffer, 0, mapped)
	local normalized = buffer.readf32(floatBuffer, 0)
	return if normalized == 0 then 0 else normalized
end

local function deepFreeze(value: any): any
	if type(value) ~= "table" or table.isfrozen(value) then
		return value
	end

	for _, nested in value do
		deepFreeze(nested)
	end
	return table.freeze(value)
end

local function findWorkload(workloadId: string)
	for workloadPosition, workload in Contract.workloads do
		if workload.id == workloadId then
			return workload, workloadPosition
		end
	end

	error(`unknown Event V1 workload {workloadId}`, 2)
end

local function findProbe(probeId: string)
	for probePosition, probe in Contract.probes do
		if probe.id == probeId then
			return probe, probePosition
		end
	end

	error(`unknown Event V1 probe {probeId}`, 2)
end

local function buildExpected(
	payload: any,
	seed: number,
	sequence: number,
	floatBuffer: buffer
): PayloadRecord
	local expected: PayloadRecord = {}
	for fieldPosition, field in payload.fields do
		if field.name == "sequence" then
			expected[field.name] = sequence
		elseif field.valueType == "boolean" then
			local value = mix(seed, sequence, fieldPosition, 0)
			expected[field.name] = bit32.band(value, 1) == 1
		elseif field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32" then
			local value = mix(seed, sequence, fieldPosition, 0)
			expected[field.name] = integerInRange(value, field.minimum, field.maximum)
		elseif field.valueType == "f32" then
			local value = mix(seed, sequence, fieldPosition, 0)
			expected[field.name] = float32InRange(value, field.minimum, field.maximum, floatBuffer)
		elseif field.valueType == "Vector3F32" then
			local x = float32InRange(mix(seed, sequence, fieldPosition, 1), field.minimum, field.maximum, floatBuffer)
			local y = float32InRange(mix(seed, sequence, fieldPosition, 2), field.minimum, field.maximum, floatBuffer)
			local z = float32InRange(mix(seed, sequence, fieldPosition, 3), field.minimum, field.maximum, floatBuffer)
			expected[field.name] = Vector3Class.new(x, y, z)
		else
			error(`unsupported Event V1 value type {field.valueType}`, 2)
		end
	end
	return expected
end

local function generate(workloadId: string, repetitionIndex: number): FixtureSet
	local workload, workloadPosition = findWorkload(workloadId)
	assert(
		type(repetitionIndex) == "number"
			and repetitionIndex % 1 == 0
			and repetitionIndex >= 1
			and repetitionIndex <= workload.repetitions,
		`repetitionIndex must be an integer in 1..{workload.repetitions}`
	)

	local payload = Contract.payloads[workload.payloadId]
	local warmupCount = workload.warmupFrames * workload.senderCount * workload.messagesPerFrame
	local measuredCount = workload.measuredFrames * workload.senderCount * workload.messagesPerFrame
	local submissionsPerRepetition = warmupCount + measuredCount
	local ordinal = 0
	local seed = workloadSeed(workloadPosition)
	local floatBuffer = buffer.create(4)

	local function generatePhase(phase: Phase, frameCount: number): { LogicalSubmission }
		local submissions = {}
		for frameIndex = 1, frameCount do
			for senderIndex = 1, workload.senderCount do
				for messageIndex = 1, workload.messagesPerFrame do
					local sequence = (repetitionIndex - 1) * submissionsPerRepetition + ordinal
					ordinal += 1
					table.insert(submissions, {
						sequence = sequence,
						payloadId = workload.payloadId,
						phase = phase,
						frameIndex = frameIndex,
						senderIndex = senderIndex,
						messageIndex = messageIndex,
						expected = buildExpected(payload, seed, sequence, floatBuffer),
					})
				end
			end
		end
		return submissions
	end

	return deepFreeze({
		contractVersion = Contract.version,
		workloadId = workload.id,
		repetitionIndex = repetitionIndex,
		warmup = generatePhase("Warmup", workload.warmupFrames),
		measured = generatePhase("Measured", workload.measuredFrames),
	})
end

local function generateProbe(probeId: string, repetitionIndex: number): ProbeFixtureSet
	local probe, probePosition = findProbe(probeId)
	assert(
		type(repetitionIndex) == "number"
			and repetitionIndex % 1 == 0
			and repetitionIndex >= 1
			and repetitionIndex <= probe.repetitions,
		`repetitionIndex must be an integer in 1..{probe.repetitions}`
	)

	local payload = Contract.payloads[probe.payloadId]
	local samplesPerRepetition = probe.warmupSamples + probe.measuredSamples
	local ordinal = 0
	local seed = probeSeed(probePosition)
	local floatBuffer = buffer.create(4)

	local function generatePhase(phase: Phase, sampleCount: number): { ProbeSample }
		local samples = {}
		for sampleIndex = 1, sampleCount do
			local sequence = (repetitionIndex - 1) * samplesPerRepetition + ordinal
			ordinal += 1
			table.insert(samples, {
				sequence = sequence,
				payloadId = probe.payloadId,
				phase = phase,
				sampleIndex = sampleIndex,
				expected = buildExpected(payload, seed, sequence, floatBuffer),
			})
		end
		return samples
	end

	return deepFreeze({
		contractVersion = Contract.version,
		probeId = probe.id,
		repetitionIndex = repetitionIndex,
		warmup = generatePhase("Warmup", probe.warmupSamples),
		measured = generatePhase("Measured", probe.measuredSamples),
	})
end

local function newInput(submission: InputSubmission): PayloadRecord
	local payload = Contract.payloads[submission.payloadId]
	local input: PayloadRecord = {}
	for _, field in payload.fields do
		input[field.name] = submission.expected[field.name]
	end
	return input
end

return {
	generate = generate,
	generateProbe = generateProbe,
	newInput = newInput,
}
