--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local Host = require("./HostRuntime")
local Fingerprint = require("./MeasurementFingerprint")
local Evidence = require("./SerializerEvidence")
local Gate = require("./SerializerGate")

local function write(path: string, value: any)
	fs.writeFile(path, serde.encode("json", value, true) .. "\n", { overwrite = false })
end

local function execute(program: string, arguments: { string }, root: string): string
	local result = process.exec(program, arguments, { cwd = root })
	assert(result.ok, result.stderr)
	return string.gsub(result.stdout, "%s+$", "")
end

local args = process.args
if args[1] == "--init" and #args >= 2 and #args <= 4 then
	local directory = args[2]
	assert(not fs.isDir(directory) and not fs.isFile(directory), "output directory already exists")
	fs.writeDir(directory)
	local function pin(root: string, role: string): any
		local place = directory .. "/" .. role .. ".rbxlx"
		-- Resolve output relative to this invocation, not the selected checkout.
		if not string.match(place, "^%a:[/\\]") and string.sub(place, 1, 1) ~= "/" then place = process.cwd .. "/" .. place end
		local revision = execute("git", { "rev-parse", "HEAD" }, root)
		execute("rojo", { "build", "benchmarks/event-v1.project.json", "--output", place }, root)
		local bytes = fs.readFile(place)
		local adapter = Host.collectRelayAdapter(revision, bytes, roblox, serde.hash, "PersistentSession")
		return {
			revision = revision, adapterFingerprint = adapter.artifact.digest,
			measurementFingerprint = Fingerprint.collect(root, bytes, fs, roblox, serde.hash),
			place = Evidence.artifact(place), root = root,
			dirtyAtPlanning = execute("git", { "status", "--porcelain" }, root) ~= "",
		}
	end
	local plan: any = {
		schema = "Relay.SerializerGatePlan", version = 1,
		baseline = pin(args[3] or process.cwd, "baseline"),
		cases = { "state-burst-c2s", "state-broadcast-s2c", "tiny-round-trip" },
		limits = { minimumWireSaving = 0.15, maximumCostRegression = 0.05,
			maximumLatencyRegression = 0.10, maximumDeliveryRegression = 0.05, maximumControlVariation = 0.05 },
	}
	if args[4] then plan.candidate = pin(args[4], "candidate") end
	write(directory .. "/plan.json", plan)
	local entries = {}
	for _, caseId in plan.cases do
		for pass, order in { { "baseline", "control", "candidate" }, { "candidate", "control", "baseline" } } do
			for _, role in order do table.insert(entries, { caseId = caseId, pass = pass, role = role }) end
		end
	end
	write(directory .. "/evidence.json", {
		planSha256 = Evidence.artifact(directory .. "/plan.json").sha256, entries = entries,
	})
	print("Created measurement plan and empty evidence schedule: " .. directory)
	print("Draft only: bind clean baseline/candidate snapshots and predeclare the plan before collecting. No serializer is approved.")
elseif args[1] == "--evaluate" and (#args == 3 or (#args == 5 and args[4] == "--tshark")) then
	local directory, output = args[2], args[3]
	if args[5] then
		assert(string.match(args[5], "^%a:[/\\]") or string.sub(args[5], 1, 1) == "/", "TShark path must be absolute")
	end
	local planBytes = fs.readFile(directory .. "/plan.json")
	local evidenceBytes = fs.readFile(directory .. "/evidence.json")
	assert(#planBytes <= 65536 and #evidenceBytes <= 1024 * 1024, "plan/evidence index too large")
	local plan = serde.decode("json", planBytes)
	local planHash = "sha256:" .. serde.hash("sha256", planBytes)
	local evidence = serde.decode("json", evidenceBytes)
	assert(evidence.planSha256 == planHash, "plan changed after evidence was bound; start a new study")
	assert(type(evidence.entries) == "table" and #evidence.entries <= 18, "invalid evidence schedule")
	local rows = {}
	for _, entry in evidence.entries do table.insert(rows, Evidence.load(directory, entry, planHash, args[5])) end
	local snapshotOk, snapshotIssue = pcall(function()
		for _, role in { "baseline", "candidate" } do
			local pin = plan[role]
			if pin then
				local _, bytes = Evidence.verified(directory, pin.place)
				local adapter = Host.collectRelayAdapter(pin.revision, bytes, roblox, serde.hash, "PersistentSession")
				assert(adapter.artifact.digest == pin.adapterFingerprint, "planned place differs from adapter pin")
				assert(pin.measurementFingerprint == plan.baseline.measurementFingerprint, "planned harnesses differ")
			end
		end
	end)
	-- Pin the shared measurement implementation too, including when every row
	-- was consistently collected using a different harness from the planned one.
	local previousFinish = -math.huge
	for _, row in rows do
		if not snapshotOk then table.insert(row.issues, tostring(snapshotIssue)) end
		if row.measurementFingerprint ~= plan.baseline.measurementFingerprint then
			table.insert(row.issues, "measurement fingerprint differs from predeclared baseline")
		end
		if row.startedUnix and row.finishedUnix then
			if row.startedUnix < previousFinish then table.insert(row.issues, "sessions overlap or contradict the declared order") end
			previousFinish = row.finishedUnix
		end
	end
	local report = table.clone(Gate.evaluate(plan, rows))
	report.planSha256, report.evidence = planHash, {
		path = directory .. "/evidence.json", sha256 = "sha256:" .. serde.hash("sha256", evidenceBytes), size = #evidenceBytes,
	}
	report.observations = rows
	report.scope = "Reliable State C2S, native State broadcast, and separate Tiny RTT; captured connection frames; sender/receiver window means"
	write(output, report)
	print(report.status .. ": " .. output)
	for _, reason in report.reasons do print("- " .. reason) end
	if report.status ~= "EligibleForReview" then process.exit(2) end
elseif args[1] == "--hash" and #args == 2 then
	print(serde.encode("json", Evidence.artifact(args[2])))
else
	error("Usage: --init <new-directory> [baseline-root] [candidate-root]\n"
		.. "       --evaluate <directory> <new-report.json> [--tshark <absolute-executable>]\n"
		.. "       --hash <artifact>", 0)
end
