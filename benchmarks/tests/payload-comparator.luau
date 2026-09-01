local Contract = require("../contracts/event-v1")
local Fixtures = require("../fixtures/event-v1")
local PayloadComparator = require("../correctness/PayloadComparator")

local Vector3Class = if Vector3 ~= nil then Vector3 else require("@lune/roblox").Vector3
local NO_VALUE = {}
local MAX_SAFE_INTEGER = 9_007_199_254_740_991
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
end

local function cloneRecord(source)
	local result = {}
	for key, value in source do
		result[key] = value
	end
	return result
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
		assert(rawget(expected, key) ~= nil, `{path} has unexpected key {tostring(key)}`)
		assertDeepEqual(actualValue, rawget(expected, key), `{path}.{tostring(key)}`)
	end

	local expectedCount = 0
	for key in expected do
		expectedCount += 1
		assert(rawget(actual, key) ~= nil, `{path} is missing key {tostring(key)}`)
	end
	assert(actualCount == expectedCount, `{path} has a key-count mismatch`)
end

local function floatBits(value)
	buffer.writef32(floatBuffer, 0, value)
	return buffer.readu32(floatBuffer, 0)
end

local function floatFromBits(bits)
	buffer.writeu32(floatBuffer, 0, bits)
	return buffer.readf32(floatBuffer, 0)
end

local function assertScalarEqual(actual, expected, label)
	assert(type(actual) == type(expected), `{label} has a type mismatch`)
	assert(actual == expected, `{label} differs`)
	if type(expected) == "number" and expected == 0 then
		assert(1 / actual == 1 / expected, `{label} has the wrong zero sign`)
	end
end

local function assertMismatch(
	ok,
	mismatch,
	path,
	reason,
	expectedPresent,
	actualPresent,
	expectedValue,
	actualValue,
	label
)
	assert(ok == false, `{label} must fail`)
	assert(type(mismatch) == "table", `{label} must return a mismatch`)
	assert(mismatch.path == path, `{label} expected path {path}, got {tostring(mismatch.path)}`)
	assert(mismatch.reason == reason, `{label} expected reason {reason}, got {tostring(mismatch.reason)}`)
	assert(mismatch.expectedPresent == expectedPresent, `{label} expectedPresent differs`)
	assert(mismatch.actualPresent == actualPresent, `{label} actualPresent differs`)

	local allowed = {
		path = true,
		reason = true,
		expectedPresent = true,
		actualPresent = true,
		expected = true,
		actual = true,
	}
	local count = 0
	for key in mismatch do
		count += 1
		assert(allowed[key], `{label} has unexpected mismatch key {tostring(key)}`)
	end

	local expectedStored = rawget(mismatch, "expected") ~= nil
	local actualStored = rawget(mismatch, "actual") ~= nil
	assert(expectedStored == (expectedValue ~= NO_VALUE), `{label} expected diagnostic presence differs`)
	assert(actualStored == (actualValue ~= NO_VALUE), `{label} actual diagnostic presence differs`)
	if expectedStored then
		assertScalarEqual(mismatch.expected, expectedValue, `{label}.expected`)
	end
	if actualStored then
		assertScalarEqual(mismatch.actual, actualValue, `{label}.actual`)
	end
	local expectedCount = 4 + (if expectedStored then 1 else 0) + (if actualStored then 1 else 0)
	assert(count == expectedCount, `{label} mismatch key count differs`)
end

local function assertRecordMismatch(label, payloadId, expected, actual, path, reason, expectedPresent, actualPresent, expectedValue, actualValue)
	local ok, mismatch = PayloadComparator.compareRecord(payloadId, expected, actual)
	assertMismatch(
		ok,
		mismatch,
		path,
		reason,
		expectedPresent,
		actualPresent,
		expectedValue,
		actualValue,
		label
	)
	return mismatch
end

local function assertPositionalSuccess(submission, label)
	local descriptor = Contract.payloads[submission.payloadId]
	local input = Fixtures.newInput(submission)
	local arguments = table.create(#descriptor.fields)
	for index, field in descriptor.fields do
		arguments[index] = rawget(input, field.name)
	end

	local ok, mismatch = PayloadComparator.comparePositional(
		submission.payloadId,
		submission.expected,
		table.unpack(arguments, 1, #descriptor.fields)
	)
	assert(ok == true and mismatch == nil, `{label} positional payload must pass`)
	assertDeepEqual(input, submission.expected, `{label}.positionalInput`)
end

assertExactKeys(
	PayloadComparator,
	{ "compareCapturedPositional", "compareRecord", "comparePositional" },
	"PayloadComparator"
)
assert(
	type(PayloadComparator.compareCapturedPositional) == "function",
	"compareCapturedPositional must be a function"
)
assert(type(PayloadComparator.compareRecord) == "function", "compareRecord must be a function")
assert(type(PayloadComparator.comparePositional) == "function", "comparePositional must be a function")

local representativeSubmissions = {
	Fixtures.generate("tiny-steady-c2s", 1).warmup[1],
	Fixtures.generate("tiny-steady-c2s", 1).measured[120],
	Fixtures.generate("state-steady-c2s", 1).measured[1],
	Fixtures.generate("state-steady-c2s", 2).warmup[1],
	Fixtures.generate("state-burst-c2s", 1).measured[40],
}

for index, submission in representativeSubmissions do
	local label = `canonical[{index}]`
	local input = Fixtures.newInput(submission)
	local before = cloneRecord(input)
	local ok, mismatch = PayloadComparator.compareRecord(submission.payloadId, submission.expected, input)
	assert(ok == true and mismatch == nil, `{label} record payload must pass`)
	assertDeepEqual(input, before, `{label}.recordInput`)
	assertDeepEqual(submission.expected, before, `{label}.oracle`)
	assert(table.isfrozen(submission.expected), `{label} oracle must stay frozen`)
	assertPositionalSuccess(submission, label)
end

local tinySubmission = Fixtures.generate("tiny-steady-c2s", 1).warmup[1]
local tinyExpected = tinySubmission.expected
local stateSubmission = Fixtures.generate("state-steady-c2s", 1).warmup[1]
local stateExpected = stateSubmission.expected

assertRecordMismatch(
	"large string container",
	"tiny",
	tinyExpected,
	string.rep("payload", 1_024),
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE
)
assertRecordMismatch(
	"buffer container",
	"tiny",
	tinyExpected,
	buffer.create(4_096),
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE
)

local missingEnabled = cloneRecord(tinyExpected)
missingEnabled.enabled = nil
assertRecordMismatch(
	"missing field",
	"tiny",
	tinyExpected,
	missingEnabled,
	"enabled",
	"MissingField",
	true,
	false,
	tinyExpected.enabled,
	NO_VALUE
)

local metatableAccessed = false
local metatableRecord = cloneRecord(tinyExpected)
setmetatable(metatableRecord, {
	__metatable = "protected",
	__index = function()
		metatableAccessed = true
		error("payload comparator invoked a record metamethod")
	end,
})
assertRecordMismatch(
	"metatable-backed record",
	"tiny",
	tinyExpected,
	metatableRecord,
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE
)
assert(not metatableAccessed, "metatable rejection must not invoke metamethods")

local extraString = cloneRecord(tinyExpected)
extraString.unexpected = string.rep("x", 4_096)
assertRecordMismatch(
	"extra string key",
	"tiny",
	tinyExpected,
	extraString,
	"$",
	"ExtraField",
	false,
	true,
	NO_VALUE,
	NO_VALUE
)

local extraNumeric = cloneRecord(tinyExpected)
extraNumeric[17] = buffer.create(4_096)
assertRecordMismatch(
	"extra numeric key",
	"tiny",
	tinyExpected,
	extraNumeric,
	"$",
	"ExtraField",
	false,
	true,
	NO_VALUE,
	NO_VALUE
)

local manyExtras = cloneRecord(tinyExpected)
for index = 1, 100_000 do
	manyExtras[index] = index
end
assertRecordMismatch(
	"many extra keys",
	"tiny",
	tinyExpected,
	manyExtras,
	"$",
	"ExtraField",
	false,
	true,
	NO_VALUE,
	NO_VALUE
)

local tableKeyA = {}
local extrasA = cloneRecord(tinyExpected)
extrasA.firstExtra = string.rep("a", 4_096)
extrasA[tableKeyA] = buffer.create(4_096)
local mismatchA = assertRecordMismatch(
	"multiple extras first order",
	"tiny",
	tinyExpected,
	extrasA,
	"$",
	"ExtraField",
	false,
	true,
	NO_VALUE,
	NO_VALUE
)

local tableKeyB = {}
local extrasB = cloneRecord(tinyExpected)
extrasB[tableKeyB] = buffer.create(4_096)
extrasB.firstExtra = string.rep("b", 4_096)
local mismatchB = assertRecordMismatch(
	"multiple extras second order",
	"tiny",
	tinyExpected,
	extrasB,
	"$",
	"ExtraField",
	false,
	true,
	NO_VALUE,
	NO_VALUE
)
assertDeepEqual(mismatchA, mismatchB, "multiple extras deterministic mismatch")

local ok, mismatch = PayloadComparator.comparePositional("tiny", tinyExpected, tinyExpected.sequence)
assertMismatch(ok, mismatch, "$", "ArityMismatch", true, true, 2, 1, "positional too few")

ok, mismatch = PayloadComparator.comparePositional("tiny", tinyExpected, tinyExpected.sequence, nil)
assertMismatch(
	ok,
	mismatch,
	"enabled",
	"WrongType",
	true,
	true,
	tinyExpected.enabled,
	NO_VALUE,
	"positional explicit nil"
)

ok, mismatch = PayloadComparator.comparePositional("tiny", tinyExpected, tinyExpected.sequence, tinyExpected.enabled, 3)
assertMismatch(ok, mismatch, "$", "ArityMismatch", true, true, 2, 3, "positional too many")

local capturedExact = {
	[1] = tinyExpected.sequence,
	[2] = tinyExpected.enabled,
}
local capturedExactBefore = cloneRecord(capturedExact)
local tinyExpectedBefore = cloneRecord(tinyExpected)
ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, capturedExact, 2)
assert(ok == true and mismatch == nil, "captured exact arity must pass")
assertDeepEqual(capturedExact, capturedExactBefore, "captured exact values")
assertDeepEqual(tinyExpected, tinyExpectedBefore, "captured exact oracle")

ok, mismatch = PayloadComparator.compareCapturedPositional(
	"tiny",
	tinyExpected,
	{ [1] = tinyExpected.sequence },
	1
)
assertMismatch(ok, mismatch, "$", "ArityMismatch", true, true, 2, 1, "captured too few")

local capturedNilHole = { [1] = tinyExpected.sequence }
local capturedNilHoleBefore = cloneRecord(capturedNilHole)
ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, capturedNilHole, 2)
assertMismatch(
	ok,
	mismatch,
	"enabled",
	"WrongType",
	true,
	true,
	tinyExpected.enabled,
	NO_VALUE,
	"captured nil hole"
)
assertDeepEqual(capturedNilHole, capturedNilHoleBefore, "captured nil-hole values")

local capturedFieldCountPlusOne = {
	[1] = tinyExpected.sequence,
	[2] = tinyExpected.enabled,
	[3] = buffer.create(4_096),
}
ok, mismatch = PayloadComparator.compareCapturedPositional(
	"tiny",
	tinyExpected,
	capturedFieldCountPlusOne,
	3
)
assertMismatch(ok, mismatch, "$", "ArityMismatch", true, true, 2, 3, "captured field count plus one")

ok, mismatch = PayloadComparator.compareCapturedPositional(
	"tiny",
	tinyExpected,
	capturedFieldCountPlusOne,
	MAX_SAFE_INTEGER
)
assertMismatch(
	ok,
	mismatch,
	"$",
	"ArityMismatch",
	true,
	true,
	2,
	MAX_SAFE_INTEGER,
	"captured huge safe count"
)

ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, "not storage", 2)
assertMismatch(
	ok,
	mismatch,
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE,
	"captured non-table storage"
)

ok, mismatch = PayloadComparator.compareCapturedPositional(
	"tiny",
	tinyExpected,
	{
		[1] = tinyExpected.sequence,
		[2] = tinyExpected.enabled,
		unexpected = true,
	},
	2
)
assertMismatch(
	ok,
	mismatch,
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE,
	"captured malformed storage key"
)

ok, mismatch = PayloadComparator.compareCapturedPositional(
	"tiny",
	tinyExpected,
	{
		[1] = tinyExpected.sequence,
		[2] = tinyExpected.enabled,
		[3] = true,
	},
	2
)
assertMismatch(
	ok,
	mismatch,
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE,
	"captured out-of-bound storage"
)

ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, "not storage", -1)
assertMismatch(
	ok,
	mismatch,
	"$",
	"ArityMismatch",
	true,
	true,
	2,
	-1,
	"captured invalid count precedes storage"
)

for _, case in {
	{ label = "wrong type", count = "2", diagnostic = NO_VALUE },
	{ label = "negative", count = -1, diagnostic = -1 },
	{ label = "fractional", count = 1.5, diagnostic = 1.5 },
	{ label = "NaN", count = 0 / 0, diagnostic = NO_VALUE },
	{ label = "infinity", count = math.huge, diagnostic = NO_VALUE },
	{ label = "above safe integer", count = MAX_SAFE_INTEGER + 1, diagnostic = MAX_SAFE_INTEGER + 1 },
	{ label = "negative zero", count = -0, diagnostic = -0 },
} do
	ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, capturedExact, case.count)
	assertMismatch(
		ok,
		mismatch,
		"$",
		"ArityMismatch",
		true,
		true,
		2,
		case.diagnostic,
		`captured invalid count {case.label}`
	)
end

local capturedMetatableAccessed = false
local capturedMetatable = cloneRecord(capturedExact)
setmetatable(capturedMetatable, {
	__metatable = "protected",
	__index = function()
		capturedMetatableAccessed = true
		error("payload comparator invoked a captured-storage metamethod")
	end,
})
ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, capturedMetatable, 3)
assertMismatch(
	ok,
	mismatch,
	"$",
	"ArityMismatch",
	true,
	true,
	2,
	3,
	"captured arity precedes storage"
)
ok, mismatch = PayloadComparator.compareCapturedPositional("tiny", tinyExpected, capturedMetatable, 2)
assertMismatch(
	ok,
	mismatch,
	"$",
	"WrongContainerType",
	true,
	true,
	NO_VALUE,
	NO_VALUE,
	"captured metatable storage"
)
assert(not capturedMetatableAccessed, "captured metatable rejection must not invoke metamethods")

local wrongBooleanType = cloneRecord(tinyExpected)
wrongBooleanType.enabled = "true"
assertRecordMismatch(
	"boolean wrong type",
	"tiny",
	tinyExpected,
	wrongBooleanType,
	"enabled",
	"WrongType",
	true,
	true,
	tinyExpected.enabled,
	NO_VALUE
)

local wrongBooleanValue = cloneRecord(tinyExpected)
wrongBooleanValue.enabled = not tinyExpected.enabled
assertRecordMismatch(
	"boolean wrong value",
	"tiny",
	tinyExpected,
	wrongBooleanValue,
	"enabled",
	"ValueMismatch",
	true,
	true,
	tinyExpected.enabled,
	wrongBooleanValue.enabled
)

for _, field in Contract.payloads.state.fields do
	if field.valueType == "u8" or field.valueType == "u16" or field.valueType == "u32" then
		local expectedValue = stateExpected[field.name]
		local differentValue = if expectedValue < field.maximum then expectedValue + 1 else expectedValue - 1
		local cases = {
			{ label = "wrong type", value = {}, reason = "WrongType", diagnostic = NO_VALUE },
			{ label = "fractional", value = expectedValue + 0.5, reason = "NonInteger", diagnostic = expectedValue + 0.5 },
			{ label = "below bound", value = field.minimum - 1, reason = "OutOfRange", diagnostic = field.minimum - 1 },
			{ label = "above bound", value = field.maximum + 1, reason = "OutOfRange", diagnostic = field.maximum + 1 },
			{ label = "different value", value = differentValue, reason = "ValueMismatch", diagnostic = differentValue },
		}

		for _, case in cases do
			local actual = cloneRecord(stateExpected)
			actual[field.name] = case.value
			assertRecordMismatch(
				`{field.valueType} {case.label}`,
				"state",
				stateExpected,
				actual,
				field.name,
				case.reason,
				true,
				true,
				expectedValue,
				case.diagnostic
			)
		end
	end
end

local infiniteInteger = cloneRecord(stateExpected)
infiniteInteger.sequence = math.huge
assertRecordMismatch(
	"integer non-finite",
	"state",
	stateExpected,
	infiniteInteger,
	"sequence",
	"NonFinite",
	true,
	true,
	stateExpected.sequence,
	NO_VALUE
)
local wrongFloatType = cloneRecord(stateExpected)
wrongFloatType.yaw = buffer.create(4_096)
assertRecordMismatch(
	"float wrong type",
	"state",
	stateExpected,
	wrongFloatType,
	"yaw",
	"WrongType",
	true,
	true,
	stateExpected.yaw,
	NO_VALUE
)

for _, case in {
	{ label = "NaN", value = 0 / 0 },
	{ label = "positive infinity", value = math.huge },
	{ label = "negative infinity", value = -math.huge },
} do
	local actual = cloneRecord(stateExpected)
	actual.yaw = case.value
	assertRecordMismatch(
		`float {case.label}`,
		"state",
		stateExpected,
		actual,
		"yaw",
		"NonFinite",
		true,
		true,
		stateExpected.yaw,
		NO_VALUE
	)
end

local yawDescriptor = Contract.payloads.state.fields[4]
assert(yawDescriptor.name == "yaw", "state yaw descriptor order drifted")
for _, case in {
	{ label = "below bound", value = yawDescriptor.minimum - 1 },
	{ label = "above bound", value = yawDescriptor.maximum + 1 },
} do
	local actual = cloneRecord(stateExpected)
	actual.yaw = case.value
	assertRecordMismatch(
		`float {case.label}`,
		"state",
		stateExpected,
		actual,
		"yaw",
		"OutOfRange",
		true,
		true,
		stateExpected.yaw,
		case.value
	)
end

local adjacentYaw = floatFromBits(floatBits(stateExpected.yaw) + 1)
local nonFloat32Yaw = (stateExpected.yaw + adjacentYaw) / 2
local nonFloat32 = cloneRecord(stateExpected)
nonFloat32.yaw = nonFloat32Yaw
assertRecordMismatch(
	"float not normalized",
	"state",
	stateExpected,
	nonFloat32,
	"yaw",
	"NotFloat32",
	true,
	true,
	stateExpected.yaw,
	nonFloat32Yaw
)

local wrongFloatValue = cloneRecord(stateExpected)
wrongFloatValue.yaw = adjacentYaw
assertRecordMismatch(
	"float adjacent value",
	"state",
	stateExpected,
	wrongFloatValue,
	"yaw",
	"ValueMismatch",
	true,
	true,
	stateExpected.yaw,
	adjacentYaw
)

local zeroFloatExpected = cloneRecord(stateExpected)
zeroFloatExpected.yaw = 0
local negativeZeroFloat = cloneRecord(zeroFloatExpected)
negativeZeroFloat.yaw = -0
assertRecordMismatch(
	"float zero sign",
	"state",
	zeroFloatExpected,
	negativeZeroFloat,
	"yaw",
	"ValueMismatch",
	true,
	true,
	zeroFloatExpected.yaw,
	negativeZeroFloat.yaw
)

local missingVector = cloneRecord(stateExpected)
missingVector.position = nil
assertRecordMismatch(
	"missing vector",
	"state",
	stateExpected,
	missingVector,
	"position",
	"MissingField",
	true,
	false,
	NO_VALUE,
	NO_VALUE
)

local wrongVectorType = cloneRecord(stateExpected)
wrongVectorType.position = { X = 1, Y = 2, Z = 3 }
assertRecordMismatch(
	"vector wrong type",
	"state",
	stateExpected,
	wrongVectorType,
	"position",
	"WrongType",
	true,
	true,
	NO_VALUE,
	NO_VALUE
)

local nonFiniteVector = cloneRecord(stateExpected)
nonFiniteVector.position = Vector3Class.new(math.huge, stateExpected.position.Y, stateExpected.position.Z)
assertRecordMismatch(
	"vector X non-finite",
	"state",
	stateExpected,
	nonFiniteVector,
	"position.X",
	"NonFinite",
	true,
	true,
	stateExpected.position.X,
	NO_VALUE
)

local outOfRangeVector = cloneRecord(stateExpected)
outOfRangeVector.position = Vector3Class.new(stateExpected.position.X, 1_025, stateExpected.position.Z)
assertRecordMismatch(
	"vector Y out of range",
	"state",
	stateExpected,
	outOfRangeVector,
	"position.Y",
	"OutOfRange",
	true,
	true,
	stateExpected.position.Y,
	outOfRangeVector.position.Y
)

local adjacentZ = floatFromBits(floatBits(stateExpected.position.Z) + 1)
local wrongVectorValue = cloneRecord(stateExpected)
wrongVectorValue.position = Vector3Class.new(stateExpected.position.X, stateExpected.position.Y, adjacentZ)
assertRecordMismatch(
	"vector Z adjacent value",
	"state",
	stateExpected,
	wrongVectorValue,
	"position.Z",
	"ValueMismatch",
	true,
	true,
	stateExpected.position.Z,
	adjacentZ
)

local zeroVectorExpected = cloneRecord(stateExpected)
zeroVectorExpected.position = Vector3Class.new(0, 0, 0)
local negativeZeroVector = cloneRecord(zeroVectorExpected)
negativeZeroVector.position = Vector3Class.new(-0, 0, 0)
assertRecordMismatch(
	"vector zero sign",
	"state",
	zeroVectorExpected,
	negativeZeroVector,
	"position.X",
	"ValueMismatch",
	true,
	true,
	zeroVectorExpected.position.X,
	negativeZeroVector.position.X
)

local unknownRecordSucceeded = pcall(function()
	PayloadComparator.compareRecord("unknown", tinyExpected, cloneRecord(tinyExpected))
end)
assert(not unknownRecordSucceeded, "unknown record payload id must be rejected")

local unknownPositionalSucceeded = pcall(function()
	PayloadComparator.comparePositional("unknown", tinyExpected, tinyExpected.sequence, tinyExpected.enabled)
end)
assert(not unknownPositionalSucceeded, "unknown positional payload id must be rejected")

print("PASS Relay.Benchmarks.PayloadComparator")
