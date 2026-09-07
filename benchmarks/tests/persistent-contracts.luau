local ResultV1 = require("../contracts/result-v1")
local ResultV2 = require("../contracts/result-v2")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local HostManifestV2 = require("../contracts/internal/HostManifestV2")
local Identity = require("../contracts/internal/AdapterIdentity")
local AdapterContract = require("../adapters/AdapterContract")
local Profile = require("../contracts/internal/PersistentSessionProfile")
local Fixtures = require("./support/HostRuntimeFixtures")

local function clone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, nested in value do copied[key] = clone(nested) end
	return copied
end

local function rejects(operation, label)
	local ok = pcall(operation)
	assert(not ok, label .. " must reject")
end

local legacyManifest, legacyResult = Fixtures.maximum()
local manifest = clone(legacyManifest)
manifest.version = 2
manifest.adapter.identity.semantics.repetitionIsolation = "PersistentSession"
manifest.benchmarkSource.measurementFingerprint = "sha256:" .. string.rep("c", 64)
manifest.benchmarkSource.adapterFingerprint = "sha256:" .. string.rep("d", 64)
local result = clone(legacyResult)
result.schema = { id = "result-v2", version = 2 }
result.benchmark.version = 2
result.benchmark.source = clone(manifest.benchmarkSource)
result.contract.id = "event-session-v1"
result.adapter = clone(manifest.adapter.identity)
result.conformance.sessionProof = { version = 1, passed = true }

assert(table.isfrozen(Profile) and Profile.ID == "event-session-v1" and Profile.VERSION == 1)
assert(Profile.isolation == "PersistentSession")
assert(Profile.ID == "event-session-v1" and Profile.VERSION == 1, "historical V2 profile identity stays readable")
assert(Profile.startupClockAdmissionToleranceMilliseconds == 3, "fixed persistent startup admission allowance")
assert(ResultV2.ID == "result-v2" and ResultV2.VERSION == 2 and ResultV2.BENCHMARK_VERSION == 2)
local apiCount = 0
for key in ResultV2 do
	apiCount += 1
	assert(ResultV1[key] ~= nil, "V2 must preserve the seven-function/constant API shape")
end
assert(apiCount == 7)
local checkedManifest = HostManifestV2.validate(manifest)
assert(checkedManifest.kind == "Valid", if checkedManifest.kind == "Invalid" then checkedManifest.issue.code .. ":" .. checkedManifest.issue.path else "")
assert(ResultV2.validate(result).status == "Valid")
assert(HostManifestV1.validate(manifest).kind == "Invalid")
assert(HostManifestV2.validate(legacyManifest).kind == "Invalid")
rejects(function() ResultV1.validate(result) end, "V1 rejects V2")
rejects(function() ResultV2.validate(legacyResult) end, "V2 rejects V1")

local identity = manifest.adapter.identity
local studioVersion = manifest.environment.studio.version
assert(Identity.check(identity, "Canonical", studioVersion, "$.adapter").kind == "Invalid")
assert(Identity.check(identity, "Canonical", studioVersion, "$.adapter", "wrong-profile").kind == "Invalid")
assert(Identity.check(identity, "Canonical", studioVersion, "$.adapter", "PersistentSession").kind == "Valid")
assert(Identity.check(legacyResult.adapter, "Canonical", studioVersion, "$.adapter", "PersistentSession").kind == "Invalid")
rejects(function() AdapterContract.preflight(identity, manifest.selection, studioVersion) end, "legacy preflight")
rejects(function() AdapterContract.preflight(identity, manifest.selection, studioVersion, "wrong-profile") end, "unknown profile")
assert(AdapterContract.preflight(identity, manifest.selection, studioVersion, "PersistentSession").kind == "Supported")

local draft = {
	runId = result.runId, benchmarkSource = clone(result.benchmark.source),
	contractFingerprint = result.contract.fingerprint, adapter = clone(result.adapter),
	case = clone(result.case), counts = clone(result.counts), failures = clone(result.failures),
	conformance = clone(result.conformance), environment = clone(result.environment), measurements = {},
}
for _, measurement in result.measurements do
	local entry = clone(measurement)
	entry.id = entry.metadata.id
	entry.metadata = nil
	entry.summary = nil
	table.insert(draft.measurements, entry)
end
local finalized = ResultV2.finalize(draft)
assert(finalized.status == "Valid" and finalized.contract.id == Profile.ID)
assert(finalized.benchmark.source.measurementFingerprint == manifest.benchmarkSource.measurementFingerprint)
assert(finalized.benchmark.source.adapterFingerprint == manifest.benchmarkSource.adapterFingerprint)
assert(table.isfrozen(finalized.conformance.sessionProof))
assert(ResultV2.validate(finalized).status == "Valid")
rejects(function() ResultV1.finalize(draft) end, "V1 finalize rejects persistent draft")

for _, field in { "measurementFingerprint", "adapterFingerprint" } do
	for _, bad in { false, "sha256:bad" } do
		local badResult, badDraft, badManifest = clone(result), clone(draft), clone(manifest)
		badResult.benchmark.source[field] = if bad == false then nil else bad
		badDraft.benchmarkSource[field] = if bad == false then nil else bad
		badManifest.benchmarkSource[field] = if bad == false then nil else bad
		rejects(function() ResultV2.validate(badResult) end, field)
		rejects(function() ResultV2.finalize(badDraft) end, field)
		assert(HostManifestV2.validate(badManifest).kind == "Invalid")
	end
	local badLegacyResult, badLegacyManifest = clone(legacyResult), clone(legacyManifest)
	badLegacyResult.benchmark.source[field] = manifest.benchmarkSource[field]
	badLegacyManifest.benchmarkSource[field] = manifest.benchmarkSource[field]
	rejects(function() ResultV1.validate(badLegacyResult) end, "V1 extra source field")
	assert(HostManifestV1.validate(badLegacyManifest).kind == "Invalid")
end

for _, proof in { false, { version = 1, passed = false }, { version = 2, passed = true }, { version = 1, passed = true, extra = true } } do
	local badResult, badDraft = clone(result), clone(draft)
	badResult.conformance.sessionProof = if proof == false then nil else clone(proof)
	badDraft.conformance.sessionProof = if proof == false then nil else clone(proof)
	rejects(function() ResultV2.validate(badResult) end, "session proof")
	rejects(function() ResultV2.finalize(badDraft) end, "session proof draft")
end

for _, isolation in { "SessionRestart", "ProcessRestart" } do
	local badResult, badManifest = clone(result), clone(manifest)
	badResult.adapter.semantics.repetitionIsolation = isolation
	badManifest.adapter.identity.semantics.repetitionIsolation = isolation
	rejects(function() ResultV2.validate(badResult) end, "V2 rejects legacy isolation")
	assert(HostManifestV2.validate(badManifest).kind == "Invalid")
end

-- New proof fields cannot be smuggled into otherwise valid V1 data.
local badLegacyResult = clone(legacyResult)
badLegacyResult.conformance.sessionProof = { version = 1, passed = true }
rejects(function() ResultV1.validate(badLegacyResult) end, "V1 extra conformance field")
assert(ResultV1.validate(legacyResult).status == "Valid")
assert(HostManifestV1.validate(legacyManifest).kind == "Valid")
print("PASS Relay.Benchmarks.PersistentContracts")
