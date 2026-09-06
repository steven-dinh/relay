local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ResultV1 = require("../contracts/result-v1")
local ResultV2 = require("../contracts/result-v2")
local ResultReporter = require("../reporting/ResultReporter")
local HostRuntimeFixtures = require("./support/HostRuntimeFixtures")

local function clone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, nested in value do copied[key] = clone(nested) end
	return copied
end

local function occurrences(source, needle)
	local count, cursor = 0, 1
	while true do
		local found = string.find(source, needle, cursor, true)
		if found == nil then return count end
		count += 1
		cursor = found + #needle
	end
end

local function expectError(code, operation)
	local ok, failure = pcall(operation)
	assert(not ok and string.find(tostring(failure), code, 1, true),
		`expected {code}, got {tostring(failure)}`)
end

local _, base = HostRuntimeFixtures.maximum()
local function legacy(index, isolation)
	local candidate = clone(base)
	candidate.runId = string.format("%08d-0000-4000-8000-%012d", index, index)
	candidate.adapter.semantics.repetitionIsolation = isolation or "ProcessRestart"
	return ResultV1.validate(candidate)
end

local function persistent(index, revision, measurementFingerprint)
	local candidate = clone(legacy(index))
	candidate.schema = { id = "result-v2", version = 2 }
	candidate.benchmark.version = 2
	candidate.contract.id = "event-session-v1"
	candidate.adapter.semantics.repetitionIsolation = "PersistentSession"
	candidate.benchmark.source.revision = string.rep(revision or "a", 40)
	candidate.benchmark.source.measurementFingerprint = "sha256:" .. string.rep(measurementFingerprint or "c", 64)
	candidate.benchmark.source.adapterFingerprint = "sha256:" .. string.rep("d", 64)
	candidate.conformance.sessionProof = { version = 1, passed = true }
	return ResultV2.validate(candidate)
end

local function report(left, right)
	return ResultReporter.render({
		{ path = "left.json", result = left },
		{ path = "right.json", result = right },
	})
end

local first = persistent(1)
local secondCandidate = clone(persistent(2, "b"))
secondCandidate.benchmark.source.adapterFingerprint = "sha256:" .. string.rep("e", 64)
secondCandidate.benchmark.source.placeFingerprint = "sha256:" .. string.rep("f", 64)
local second = ResultV2.validate(secondCandidate)
local matched = report(first, second)
assert(occurrences(matched, "### frameTime (milliseconds)") == 1,
	"same shared fingerprint must compare across clean Git revisions and adapter/place bytes")
assert(not string.find(matched, "### Incompatible evidence", 1, true), "compatible persistent runs were separated")
assert(occurrences(matched, (string.gsub(first.runId, "-", "&#45;"))) == 1
	and occurrences(matched, (string.gsub(second.runId, "-", "&#45;"))) == 1,
	"each persistent input must retain its own timing row")
assert(string.find(matched, "profile=event&#45;session&#45;v1/1 · isolation=PersistentSession", 1, true),
	"persistent execution profile must be visible")

local changed = report(first, persistent(3, "b", "d"))
assert(occurrences(changed, "### frameTime (milliseconds) · C") == 2,
	"changed shared fingerprint must create separate cohorts")
assert(string.find(changed, "Measurement fingerprint", 1, true)
	and string.find(changed, string.rep("d", 64), 1, true), "fingerprint mismatch evidence missing")

local mixed = report(first, legacy(4))
assert(occurrences(mixed, "## Workload:") == 2 and occurrences(mixed, "### frameTime (milliseconds)") == 2,
	"Result V1 and persistent V2 profiles must never pool")
local legacyIsolation = report(legacy(5), legacy(6, "SessionRestart"))
assert(occurrences(legacyIsolation, "## Workload:") == 2,
	"legacy ProcessRestart and SessionRestart evidence must not pool")
assert(string.find(legacyIsolation, "isolation=SessionRestart", 1, true)
	and string.find(legacyIsolation, "isolation=ProcessRestart", 1, true), "legacy isolation labels missing")
local legacyRevision = clone(legacy(7))
legacyRevision.benchmark.source.revision = string.rep("c", 40)
assert(occurrences(report(legacy(8), legacyRevision), "### frameTime (milliseconds) · C") == 2,
	"legacy results must retain Git revision compatibility")

local dirty = clone(second)
dirty.benchmark.source.dirty = true
expectError("RESULT_REPORT_E_DIRTY", function() report(first, dirty) end)
local unknown = clone(second)
unknown.schema.id = "result-future"
expectError("RESULT_REPORT_E_SCHEMA", function() report(first, unknown) end)
local unknownProfile = clone(second)
unknownProfile.contract.id = "event-future"
expectError("RESULT_REPORT_E_SCHEMA", function() report(first, unknownProfile) end)
local fabricatedLegacy = clone(legacy(9))
fabricatedLegacy.benchmark.source.measurementFingerprint = first.benchmark.source.measurementFingerprint
expectError("RESULT_REPORT_E_SCHEMA", function() report(first, fabricatedLegacy) end)

local tempRoot = ".tmp/persistent-reporter-test"
assert(not fs.isDir(tempRoot) and not fs.isFile(tempRoot), "persistent reporter fixture directory collided")
if not fs.isDir(".tmp") then fs.writeDir(".tmp") end
fs.writeDir(tempRoot)
local createdFiles = {}
local function writeFixture(name, value)
	local path = tempRoot .. "/" .. name
	fs.writeFile(path, serde.encode("json", value))
	table.insert(createdFiles, path)
	return path
end

local cliOk, cliFailure = pcall(function()
	local firstPath = writeFixture("first.json", first)
	local secondPath = writeFixture("second.json", second)
	local function run(path)
		return process.exec("lune", { "run", "benchmarks/reporting/compare-results.luau",
			"--result", firstPath, "--result", path })
	end
	local cli = run(secondPath)
	assert(cli.ok, "persistent comparison CLI failed: " .. cli.stderr)
	local output = string.gsub(string.gsub(cli.stdout, "\r\n", "\n"), "\n$", "")
	assert(output == ResultReporter.render({
		{ path = firstPath, result = first }, { path = secondPath, result = second },
	}), "persistent CLI differs from the validated pure reporter")
	for _, fixture in {
		{ name = "dirty.json", value = dirty, code = "RESULT_REPORT_E_DIRTY" },
		{ name = "unknown.json", value = unknown, code = "RESULT_REPORT_E_SCHEMA" },
	} do
		local path = writeFixture(fixture.name, fixture.value)
		local rejected = run(path)
		assert(not rejected.ok and string.find(rejected.stderr, fixture.code .. ":" .. path, 1, true),
			"persistent CLI did not reject " .. fixture.name .. ": " .. rejected.stderr)
	end
end)
for _, path in createdFiles do fs.removeFile(path) end
fs.removeDir(tempRoot)
assert(cliOk, cliFailure)

print("PASS Relay.Benchmarks.PersistentReporter")
