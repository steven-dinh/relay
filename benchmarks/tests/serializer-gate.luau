local SerializerGate = require("../host/SerializerGate")

local BASE_REVISION = string.rep("a", 40)
local CANDIDATE_REVISION = string.rep("b", 40)
local BASE_ADAPTER = "sha256:" .. string.rep("1", 64)
local CANDIDATE_ADAPTER = "sha256:" .. string.rep("2", 64)
local BASE_PLACE = "sha256:" .. string.rep("4", 64)
local CANDIDATE_PLACE = "sha256:" .. string.rep("5", 64)
local MEASUREMENT = "sha256:" .. string.rep("3", 64)

local plan = {
	schema = "Relay.SerializerGatePlan",
	version = 1,
	baseline = { revision = BASE_REVISION, adapterFingerprint = BASE_ADAPTER, place = { sha256 = BASE_PLACE } },
	candidate = { revision = CANDIDATE_REVISION, adapterFingerprint = CANDIDATE_ADAPTER, place = { sha256 = CANDIDATE_PLACE } },
	cases = { "state-burst-c2s", "state-broadcast-s2c", "tiny-round-trip" },
	limits = {
		minimumWireSaving = 0.15,
		maximumCostRegression = 0.05,
		maximumLatencyRegression = 0.10,
		maximumDeliveryRegression = 0.05,
		maximumControlVariation = 0.05,
	},
}

local function makeRows(): { any }
	local rows = {}
	local run = 0
	local function metrics(caseId: string, role: string): any
		if caseId == "tiny-round-trip" then
			local p95 = if role == "candidate" then 10.4 else 10
			local p99 = if role == "candidate" then 20.8 else 20
			return { latencyP95Ms = p95, latencyP99Ms = p99 }
		end
		if role == "candidate" then
			return {
				wireBytesPerDelivery = 80,
				senderMedianUs = 5.1,
				senderP95Us = 10.2,
				receiverMedianUs = 4.08,
				receiverP95Us = 8.16,
				latencyP95Ms = 21,
				latencyP99Ms = 31,
				deliveredPerSecond = 9_800,
			}
		end
		return {
			wireBytesPerDelivery = 100,
			senderMedianUs = 5,
			senderP95Us = 10,
			receiverMedianUs = 4,
			receiverP95Us = 8,
			latencyP95Ms = 20,
			latencyP99Ms = 30,
			deliveredPerSecond = 10_000,
		}
	end
	local schedule = {
		{ pass = 1, role = "baseline" },
		{ pass = 1, role = "control" },
		{ pass = 1, role = "candidate" },
		{ pass = 2, role = "candidate" },
		{ pass = 2, role = "control" },
		{ pass = 2, role = "baseline" },
	}
	for _, caseId in plan.cases do
		for _, slot in schedule do
			run += 1
			table.insert(rows, {
				caseId = caseId,
				pass = slot.pass,
				role = slot.role,
				runId = `run-{run}`,
				revision = if slot.role == "candidate" then CANDIDATE_REVISION else BASE_REVISION,
				adapterFingerprint = if slot.role == "candidate" then CANDIDATE_ADAPTER else BASE_ADAPTER,
				placeFingerprint = if slot.role == "candidate" then CANDIDATE_PLACE else BASE_PLACE,
				measurementFingerprint = MEASUREMENT,
				compatibilityKey = `studio-compat-{caseId}`,
				metrics = metrics(caseId, slot.role),
				issues = {},
			})
		end
	end
	return rows
end

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, nested in value do copy[key] = clone(nested) end
	return copy
end

local function assertStatus(rows: any, expected: string, label: string, selectedPlan: any?)
	local result = SerializerGate.evaluate(selectedPlan or plan, rows)
	assert(result.schema == "Relay.SerializerGateReport" and result.version == 1, `{label}: report header differs`)
	assert(result.status == expected, `{label}: expected {expected}, got {result.status} ({table.concat(result.reasons, ",")})`)
	return result
end

local passingRows = makeRows()
local passing = assertStatus(passingRows, "EligibleForReview", "qualifying paired runs")
assert(#passing.comparisons == 36, "all workload and probe metrics must be compared in each pass")
assert(passing.comparisons[1].metric == "wireBytesPerDelivery"
	and math.abs(passing.comparisons[1].changeFraction + 0.2) < 1e-12,
	"wire comparison must report candidate change relative to baseline")

local exactThresholds = clone(passingRows)
for _, row in exactThresholds do
	if row.role ~= "baseline" then
		local baseline = nil
		for _, candidateBaseline in exactThresholds do
			if candidateBaseline.caseId == row.caseId and candidateBaseline.pass == row.pass
				and candidateBaseline.role == "baseline" then
				baseline = candidateBaseline
				break
			end
		end
		assert(baseline ~= nil, "threshold fixture baseline missing")
		for metric, value in row.metrics do
			local factor = if row.role == "control" then 1.05
				elseif metric == "wireBytesPerDelivery" then 0.85
				elseif metric == "deliveredPerSecond" then 0.95
				elseif metric == "latencyP95Ms" or metric == "latencyP99Ms" then 1.1
				else 1.05
			row.metrics[metric] = baseline.metrics[metric] * factor
		end
	end
end
assertStatus(exactThresholds, "EligibleForReview", "inclusive exact decision thresholds")

local tailRegression = clone(passingRows)
tailRegression[15].metrics.latencyP99Ms = 25.2
assertStatus(tailRegression, "Reject", "26% RTT p99 regression")

local missingBytes = clone(passingRows)
missingBytes[1].metrics.wireBytesPerDelivery = nil
assertStatus(missingBytes, "Inconclusive", "missing byte evidence")

local lowSaving = clone(passingRows)
lowSaving[3].metrics.wireBytesPerDelivery = 90
assertStatus(lowSaving, "Reject", "wire saving below gate")

local noisyControl = clone(passingRows)
noisyControl[2].metrics.senderMedianUs = 6
assertStatus(noisyControl, "Inconclusive", "control variation")

local sourceMismatch = clone(passingRows)
sourceMismatch[3].revision = BASE_REVISION
assertStatus(sourceMismatch, "Inconclusive", "candidate source pin mismatch")

for _, rowIndex in { 1, 2, 3 } do
	local placeMismatch = clone(passingRows)
	placeMismatch[rowIndex].placeFingerprint = if placeMismatch[rowIndex].role == "candidate" then BASE_PLACE else CANDIDATE_PLACE
	assertStatus(placeMismatch, "Inconclusive", `{placeMismatch[rowIndex].role} place pin mismatch`)
end

local missingPlace = clone(passingRows)
missingPlace[3].placeFingerprint = nil
assertStatus(missingPlace, "Inconclusive", "missing result place identity")

local missingPlanPlace = clone(plan)
missingPlanPlace.candidate.place.sha256 = nil
assertStatus(passingRows, "Inconclusive", "missing planned place identity", missingPlanPlace)

local harnessMismatch = clone(passingRows)
harnessMismatch[2].measurementFingerprint = "sha256:" .. string.rep("4", 64)
assertStatus(harnessMismatch, "Inconclusive", "measurement fingerprint mismatch")

local compatibilityMismatch = clone(passingRows)
compatibilityMismatch[2].compatibilityKey = "different-studio-profile"
assertStatus(compatibilityMismatch, "Inconclusive", "case compatibility mismatch")

local wrongOrder = clone(passingRows)
wrongOrder[1], wrongOrder[2] = wrongOrder[2], wrongOrder[1]
assertStatus(wrongOrder, "Inconclusive", "wrong schedule order")

local reusedRun = clone(passingRows)
reusedRun[2].runId = reusedRun[1].runId
assertStatus(reusedRun, "Inconclusive", "reused run id")

local nanEvidence = clone(passingRows)
nanEvidence[1].metrics.senderMedianUs = 0 / 0
assertStatus(nanEvidence, "Inconclusive", "NaN measurement")

local zeroEvidence = clone(passingRows)
zeroEvidence[15].metrics.latencyP95Ms = 0
assertStatus(zeroEvidence, "Inconclusive", "zero measurement")

local unchangedPlan = clone(plan)
unchangedPlan.candidate = clone(unchangedPlan.baseline)
unchangedPlan.candidate.revision = string.rep("c", 40)
assertStatus(passingRows, "Inconclusive", "identical candidate", unchangedPlan)

local noCandidatePlan = clone(plan)
noCandidatePlan.candidate = nil
assertStatus({}, "Inconclusive", "candidate absent", noCandidatePlan)

local summary = SerializerGate.summary({ 10, 4, 8, 2, 6, 12, 14, 16, 18, 20 })
assert(summary ~= nil and summary.count == 10 and summary.mean == 11 and summary.median == 11,
	"summary count, mean, or median differs")
assert(summary.p95 == 20 and summary.p99 == 20, "nearest-rank p95 or p99 differs")
assert(SerializerGate.summary({ 1, 0 / 0 }) == nil, "summary must reject NaN samples")

print("PASS Relay.Benchmarks.SerializerGate")
