--!strict

export type Code =
	"HostManifestRejected"
	| "WarmupEvidenceRejected"
	| "IngressLimitExceeded"
	| "DistributedOverflowUnrepresentable"
	| "FinalEvidenceUnrepresentable"
	| "ControlProtocolRejected"
	| "CleanupFailure"
	| "FinalizationFailure"
	| "RunIdCollision"

export type Stage = "Preflight" | "Setup" | "Execution" | "Finalize"

export type HarnessTerminationV1 =
	{
		kind: "RelayHarnessTerminationV1",
		code: "HostManifestRejected" | "RunIdCollision",
		stage: "Preflight",
	}
	| {
		kind: "RelayHarnessTerminationV1",
		code: "IngressLimitExceeded" | "ControlProtocolRejected",
		stage: "Setup" | "Execution",
	}
	| {
		kind: "RelayHarnessTerminationV1",
		code: "WarmupEvidenceRejected"
			| "DistributedOverflowUnrepresentable"
			| "FinalEvidenceUnrepresentable",
		stage: "Execution",
	}
	| {
		kind: "RelayHarnessTerminationV1",
		code: "CleanupFailure" | "FinalizationFailure",
		stage: "Finalize",
	}

local KIND = "RelayHarnessTerminationV1"
local ERROR = "HARNESS_TERMINATION_E_INVALID"

local ALLOWED_STAGES: { [string]: { [string]: boolean } } = {
	HostManifestRejected = { Preflight = true },
	WarmupEvidenceRejected = { Execution = true },
	IngressLimitExceeded = { Setup = true, Execution = true },
	DistributedOverflowUnrepresentable = { Execution = true },
	FinalEvidenceUnrepresentable = { Execution = true },
	ControlProtocolRejected = { Setup = true, Execution = true },
	CleanupFailure = { Finalize = true },
	FinalizationFailure = { Finalize = true },
	RunIdCollision = { Preflight = true },
}

local ENVELOPE_KEYS: { [string]: boolean } = {
	kind = true,
	code = true,
	stage = true,
}

local function fail(): never
	error(ERROR, 0)
end

local function copy(codeCandidate: unknown, stageCandidate: unknown): HarnessTerminationV1
	if type(codeCandidate) ~= "string" or type(stageCandidate) ~= "string" then
		fail()
	end
	local allowedStages = rawget(ALLOWED_STAGES, codeCandidate)
	if allowedStages == nil or rawget(allowedStages, stageCandidate) ~= true then
		fail()
	end

	local envelope = {
		kind = KIND,
		code = codeCandidate :: Code,
		stage = stageCandidate :: Stage,
	} :: any
	table.freeze(envelope)
	return envelope
end

local function new(code: unknown, stage: unknown): HarnessTerminationV1
	return copy(code, stage)
end

local function validate(candidate: unknown): HarnessTerminationV1
	if type(candidate) ~= "table" or getmetatable(candidate) ~= nil then
		fail()
	end

	local count = 0
	local key = next(candidate)
	while key ~= nil do
		count += 1
		if
			count > 3
			or type(key) ~= "string"
			or rawget(ENVELOPE_KEYS, key) ~= true
		then
			fail()
		end
		key = next(candidate, key)
	end

	if count ~= 3 or rawget(candidate, "kind") ~= KIND then
		fail()
	end

	return copy(rawget(candidate, "code"), rawget(candidate, "stage"))
end

local HarnessTerminationV1 = {
	new = new,
	validate = validate,
}

table.freeze(HarnessTerminationV1)

return HarnessTerminationV1
