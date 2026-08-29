local HarnessTerminationV1 = require("../contracts/internal/HarnessTerminationV1")

local CODES = {
	"HostManifestRejected",
	"WarmupEvidenceRejected",
	"IngressLimitExceeded",
	"DistributedOverflowUnrepresentable",
	"FinalEvidenceUnrepresentable",
	"ControlProtocolRejected",
	"CleanupFailure",
	"FinalizationFailure",
	"RunIdCollision",
}

local STAGES = {
	"Preflight",
	"Setup",
	"Execution",
	"Finalize",
}

local APPROVED_PAIRS = {
	{ code = "HostManifestRejected", stage = "Preflight" },
	{ code = "WarmupEvidenceRejected", stage = "Execution" },
	{ code = "IngressLimitExceeded", stage = "Setup" },
	{ code = "IngressLimitExceeded", stage = "Execution" },
	{ code = "DistributedOverflowUnrepresentable", stage = "Execution" },
	{ code = "FinalEvidenceUnrepresentable", stage = "Execution" },
	{ code = "ControlProtocolRejected", stage = "Setup" },
	{ code = "ControlProtocolRejected", stage = "Execution" },
	{ code = "CleanupFailure", stage = "Finalize" },
	{ code = "FinalizationFailure", stage = "Finalize" },
	{ code = "RunIdCollision", stage = "Preflight" },
}

local function isApprovedPair(code, stage)
	for _, pair in APPROVED_PAIRS do
		if pair.code == code and pair.stage == stage then
			return true
		end
	end
	return false
end

local function assertExactKeys(value, expectedKeys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local allowed = {}
	for _, key in expectedKeys do
		allowed[key] = true
	end

	local count = 0
	for key in next, value do
		count += 1
		assert(rawget(allowed, key) == true, `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #expectedKeys, `{label} must have exactly {#expectedKeys} keys`)
end

local function assertDeepFrozen(value, label, seen)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	assert(table.isfrozen(value), `{label} must be frozen`)
	for key, nested in next, value do
		assertDeepFrozen(key, `{label}.key`, seen)
		assertDeepFrozen(nested, `{label}.{tostring(key)}`, seen)
	end
end

local function assertInvalid(operation, label)
	local ok, problem = pcall(operation)
	assert(not ok, `{label} must fail`)
	assert(tostring(problem) == "HARNESS_TERMINATION_E_INVALID", `{label} must use the fixed error`)
end

assertExactKeys(HarnessTerminationV1, { "new", "validate" }, "HarnessTerminationV1")
assert(table.isfrozen(HarnessTerminationV1), "HarnessTerminationV1 must be frozen")
assert(type(HarnessTerminationV1.new) == "function", "HarnessTerminationV1.new must be a function")
assert(type(HarnessTerminationV1.validate) == "function", "HarnessTerminationV1.validate must be a function")

-- Every approved code-stage pair constructs and validates canonically.
for _, pair in APPROVED_PAIRS do
	local code = pair.code
	local stage = pair.stage
	local constructed = HarnessTerminationV1.new(code, stage)
	assertExactKeys(constructed, { "kind", "code", "stage" }, `{code}/{stage}`)
	assert(constructed.kind == "RelayHarnessTerminationV1", `{code}/{stage} kind differs`)
	assert(constructed.code == code, `{code}/{stage} code differs`)
	assert(constructed.stage == stage, `{code}/{stage} stage differs`)
	assertDeepFrozen(constructed, `{code}/{stage}`)

	local validated = HarnessTerminationV1.validate(constructed)
	assert(validated ~= constructed, `{code}/{stage} validation must copy`)
	assert(validated.kind == constructed.kind, `{code}/{stage} validated kind differs`)
	assert(validated.code == code, `{code}/{stage} validated code differs`)
	assert(validated.stage == stage, `{code}/{stage} validated stage differs`)
	assertDeepFrozen(validated, `{code}/{stage}.validated`)
end

-- Every other pair in the complete code-stage matrix is rejected by both entry points.
for _, code in CODES do
	for _, stage in STAGES do
		if not isApprovedPair(code, stage) then
			assertInvalid(function()
				HarnessTerminationV1.new(code, stage)
			end, `new wrong pair {code}/{stage}`)
			assertInvalid(function()
				HarnessTerminationV1.validate({
					kind = "RelayHarnessTerminationV1",
					code = code,
					stage = stage,
				})
			end, `validate wrong pair {code}/{stage}`)
		end
	end
end

local INVALID_VALUES = {
	false,
	0,
	1.5,
	{},
	function() end,
	coroutine.create(function() end),
}

-- Construction rejects every non-string type and every unapproved string in either enum slot.
for index, value in INVALID_VALUES do
	assertInvalid(function()
		HarnessTerminationV1.new(value, "Preflight")
	end, `new invalid code type {index}`)
	assertInvalid(function()
		HarnessTerminationV1.new("HostManifestRejected", value)
	end, `new invalid stage type {index}`)
end
for _, value in { "", "Unknown", "HostManifestRejected\0", "hostmanifestrejected" } do
	assertInvalid(function()
		HarnessTerminationV1.new(value, "Preflight")
	end, `new invalid code {value}`)
end
for _, value in { "", "Unknown", "Preflight\0", "preflight" } do
	assertInvalid(function()
		HarnessTerminationV1.new("HostManifestRejected", value)
	end, `new invalid stage {value}`)
end
assertInvalid(function()
	HarnessTerminationV1.new(nil, "Preflight")
end, "new missing code")
assertInvalid(function()
	HarnessTerminationV1.new("HostManifestRejected", nil)
end, "new missing stage")

local function validCandidate()
	return {
		kind = "RelayHarnessTerminationV1",
		code = "HostManifestRejected",
		stage = "Preflight",
	}
end

-- Validation rejects every invalid root type without reflecting hostile values.
for index, value in INVALID_VALUES do
	assertInvalid(function()
		HarnessTerminationV1.validate(value)
	end, `validate invalid root type {index}`)
end
assertInvalid(function()
	HarnessTerminationV1.validate(nil)
end, "validate nil root")
assertInvalid(function()
	HarnessTerminationV1.validate("RelayHarnessTerminationV1")
end, "validate string root")

-- Exact raw keyset checks cover each missing key and several extra-key shapes.
for _, missing in { "kind", "code", "stage" } do
	local candidate = validCandidate()
	candidate[missing] = nil
	assertInvalid(function()
		HarnessTerminationV1.validate(candidate)
	end, `missing {missing}`)
end
for _, extraKey in { "detail", "value", "errors", "path", "stack", 1, false } do
	local candidate = validCandidate()
	candidate[extraKey] = "must-not-appear-in-errors"
	assertInvalid(function()
		HarnessTerminationV1.validate(candidate)
	end, `extra key {tostring(extraKey)}`)
end

-- Exact kind, code, and stage values are independently enforced during validation.
for _, kind in { "", "result-v1", "RelayHarnessTerminationV2", false, 1, {} } do
	local candidate = validCandidate()
	candidate.kind = kind
	assertInvalid(function()
		HarnessTerminationV1.validate(candidate)
	end, `invalid kind {tostring(kind)}`)
end
for _, code in { "", "Unknown", false, 1, {} } do
	local candidate = validCandidate()
	candidate.code = code
	assertInvalid(function()
		HarnessTerminationV1.validate(candidate)
	end, `invalid code {tostring(code)}`)
end
for _, stage in { "", "Unknown", false, 1, {} } do
	local candidate = validCandidate()
	candidate.stage = stage
	assertInvalid(function()
		HarnessTerminationV1.validate(candidate)
	end, `invalid stage {tostring(stage)}`)
end

-- Metamethods are never used, and any metatable is rejected.
for _, metatable in {
	{ __index = function() error("must-not-appear-in-errors") end },
	{ __iter = function() error("must-not-appear-in-errors") end },
	{ __pairs = function() error("must-not-appear-in-errors") end },
	{ __metatable = false },
} do
	local candidate = setmetatable(validCandidate(), metatable)
	assertInvalid(function()
		HarnessTerminationV1.validate(candidate)
	end, "metatable candidate")
end

-- Validation copies scalar fields and retains no reference to the mutable input table.
do
	local candidate = validCandidate()
	local validated = HarnessTerminationV1.validate(candidate)
	candidate.kind = "result-v1"
	candidate.code = "RunIdCollision"
	candidate.stage = "Finalize"
	candidate.detail = "must-not-appear-in-errors"
	assert(validated.kind == "RelayHarnessTerminationV1", "validated kind retained input mutation")
	assert(validated.code == "HostManifestRejected", "validated code retained input mutation")
	assert(validated.stage == "Preflight", "validated stage retained input mutation")
	assert(rawget(validated, "detail") == nil, "validated output retained an extra field")
	assert(not pcall(function()
		validated.code = "RunIdCollision"
	end), "validated output must reject mutation")
end

-- A termination envelope cannot be confused with either a ResultV1 document or a lookalike.
do
	local termination = HarnessTerminationV1.new("FinalEvidenceUnrepresentable", "Execution")
	assert(rawget(termination, "schema") == nil, "termination must not expose a ResultV1 schema")
	assert(rawget(termination, "runId") == nil, "termination must not expose a ResultV1 runId")
	assert(rawget(termination, "status") == nil, "termination must not expose a ResultV1 status")
	assert(rawget(termination, "failures") == nil, "termination must not expose ResultV1 failures")

	assertInvalid(function()
		HarnessTerminationV1.validate({
			schema = { id = "result-v1", version = 1 },
			runId = "00000000-0000-4000-8000-000000000000",
			status = "Error",
		})
	end, "ResultV1-looking document")
	assertInvalid(function()
		HarnessTerminationV1.validate({
			kind = "result-v1",
			code = "FinalEvidenceUnrepresentable",
			stage = "Execution",
		})
	end, "ResultV1 kind lookalike")
end

print("PASS Relay.Benchmarks.HarnessTerminationV1")
