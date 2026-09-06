local fs = require("@lune/fs")
local luau = require("@lune/luau")
local SessionOwner = require("../runner/SessionOwner")
local Assembler = require("../runner/ResultDraftAssembler")
local HostManifestV1 = require("../contracts/internal/HostManifestV1")
local HostManifestV2 = require("../contracts/internal/HostManifestV2")
local ResultV1 = require("../contracts/result-v1")
local ResultV2 = require("../contracts/result-v2")
local modules = {
	["../contracts/event-v1"] = require("../contracts/event-v1"),
	["../contracts/internal/HostManifestV1"] = HostManifestV1,
	["../contracts/internal/AdapterIdentity"] = require("../contracts/internal/AdapterIdentity"),
	["../contracts/internal/RepetitionFragmentV1"] = require("../contracts/internal/RepetitionFragmentV1"),
	["../contracts/result-v1"] = ResultV1,
	["../fixtures/event-v1"] = require("../fixtures/event-v1"),
	["../runner/ResultDraftAssembler"] = Assembler,
	["../adapters/AdapterContract"] = require("../adapters/AdapterContract"),
	["../runner/SessionOwner"] = SessionOwner,
}

-- Reuse the existing pure evidence fixtures without copying their large counts
-- and timing construction or executing unrelated suites.
local function fixturePrefix(path, marker, exports)
	local source = fs.readFile(path)
	local boundary = assert(string.find(source, marker, 1, true))
	return luau.load(string.sub(source, 1, boundary - 1) .. "\nreturn " .. exports, {
		debugName = path .. "-fixtures", environment = { require = function(name) return assert(modules[name], name) end },
	})()
end

local evidence = fixturePrefix("benchmarks/tests/result-draft-assembler.luau", "assertExactKeys(ResultDraftAssembler,",
	"{ manifest = manifest, snapshot = completeSnapshot, clone = deepClone, freeze = deepFreeze }")
local sessions = fixturePrefix("benchmarks/tests/session-owner.luau", "assertExactKeys(SessionOwner,",
	"{ runtime = newRuntimeInputs }")

local manifest = evidence.clone(evidence.manifest())
manifest.version = 2
manifest.adapter.identity.semantics.repetitionIsolation = "PersistentSession"
manifest.benchmarkSource.measurementFingerprint = "sha256:" .. string.rep("1", 64)
manifest.benchmarkSource.adapterFingerprint = "sha256:" .. string.rep("2", 64)
assert(HostManifestV1.validate(manifest).kind == "Invalid", "V2 identity cannot enter V1 manifest")
local checked = HostManifestV2.validate(manifest)
assert(checked.kind == "Valid", "persistent fixture must validate")
manifest = checked.value

local prepared = SessionOwner.prepare(manifest, manifest.adapter.identity, sessions.runtime(1, { {} }))
assert(prepared.kind == "Prepared" and prepared.value.manifest.version == 2,
	"persistent whole-case preparation must succeed")
local single = SessionOwner.prepare(manifest, manifest.adapter.identity, sessions.runtime(1, { {} }), {
	kind = "SingleRepetition", repetitionIndex = 1,
})
assert(single.kind == "Terminated" and single.termination.code == "HostManifestRejected",
	"persistent mode cannot pretend to be a process fragment")

local input = evidence.freeze({
	runId = "10213243-5465-7687-98a9-bacbdcedfe0f", manifest = manifest,
	snapshot = evidence.snapshot(), sessionProof = true,
})
local assembled = Assembler.assemble(input)
assert(assembled.kind == "Draft" and assembled.value.adapter.semantics.repetitionIsolation == "PersistentSession",
	"complete persistent evidence must assemble a V2-compatible draft")
local finalized = ResultV2.finalize(assembled.value)
assert(finalized.status == "Valid" and ResultV2.validate(finalized).status == "Valid")
assert(finalized.schema.id == "result-v2" and finalized.schema.version == 2)
assert(not pcall(ResultV1.validate, finalized), "persistent result must not validate as V1")
assert(assembled.value.conformance.sessionProof.passed == true)

local missing = evidence.clone(input)
missing.sessionProof = nil
assert(not pcall(Assembler.assemble, evidence.freeze(missing)), "missing physical-session proof must reject")
local failed = evidence.clone(input)
failed.sessionProof = false
assert(Assembler.assemble(evidence.freeze(failed)).kind == "Terminated", "failed physical-session proof must terminate")
assert(not pcall(Assembler.assemble, evidence.clone(input)), "unfrozen evidence must reject")

print("PASS Relay.Benchmarks.PersistentRunner")
