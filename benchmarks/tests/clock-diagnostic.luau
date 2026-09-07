local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Host = require("../host/HostRuntime")
local Fingerprint = require("../host/MeasurementFingerprint")
local Protocol = require("../runner/ControlProtocol")
local Diagnostic = require("../diagnostics/clock/Host")
local source = fs.readFile("benchmarks/diagnostics/clock/ClockTap.luau")
local originalSource = fs.readFile("benchmarks/runner/ControlProtocol.luau")
local candidateSource = Diagnostic.candidateSource(originalSource)
local Candidate = luau.load(candidateSource, { debugName = "ClockDiagnosticCandidate", environment = {
	require = function(path) return require("../runner/" .. path) end,
} })()
local launchId = "00000000-0000-4000-8000-000000000001"

local function reject(callback)
	assert(not pcall(callback), "invalid diagnostic input accepted")
end

reject(function() Diagnostic.candidateSource("") end)
reject(function() Diagnostic.candidateSource(originalSource .. originalSource) end)

local function scenario(kind)
	local captured
	local tap = luau.load(source, { debugName = "ClockTap", environment = {
		require = function(path) assert(path == "./ClockDiagnosticCandidate"); return Candidate end,
		game = { GetService = function(_, name)
			if name == "HttpService" then return { JSONEncode = function(_, value) return serde.encode("json", value) end } end
			assert(name == "StudioTestService")
			return { EndTest = function(_, body) assert(captured == nil); captured = serde.decode("json", body) end }
		end },
	} })()
	assert(tap.newParticipant == Candidate.newParticipant, "client observer added")
	local binding = { protocolVersion = 1, runId = launchId, adapterId = "relay-reliable",
		caseId = "state-broadcast-s2c", recipientCount = 4 }
	local roster, participants = {}, {}
	for index = 1, 4 do
		roster[index] = {}
		local participantBinding = table.clone(binding)
		participantBinding.participantIndex = index
		participants[index] = Protocol.newParticipant(participantBinding)
	end
	local clock = 100
	local throws = false
	local coordinator = tap.newCoordinator(binding, roster, function()
		if throws then error("synthetic clock exception", 0) end
		return clock
	end, function() return true end).coordinator
	local function roundTrip(command, reply)
		for index = 1, 4 do
			assert(participants[index].receive(coordinator.command(index, command).body).kind == "Accepted")
		end
		for index = 1, 4 do
			assert(coordinator.receive(roster[index], participants[index].report(reply).body).kind == "Accepted")
		end
	end
	roundTrip({ kind = "BindCase" }, { kind = "BoundReport" })
	roundTrip({ kind = "PrepareRepetition", repetitionIndex = 1 }, { kind = "ReadyReport", outcome = "Ready" })
	for _ = 1, if kind == "accepted" then 10 else 2 do
		roundTrip({ kind = "ClockReadinessChallenge" }, { kind = "ClockReadinessReply",
			participantSharedSeconds = if kind == "tolerated_after" then 100.002999 else 100 })
	end
	local returned = false
	local thread = coroutine.create(function()
		if kind == "boundary" then
			coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = 1 })
		else
			for index = 1, if kind == "early" then 1 else 4 do
				assert(participants[index].receive(coordinator.command(index, { kind = "ClockChallenge" }).body).kind == "Accepted")
			end
			if kind == "regressed" then clock = 99 end
			if kind == "invalid" then clock = 0 / 0 end
			if kind == "throws" then throws = true end
			for index = 1, 4 do
				local client = if kind == "before" then 99 elseif kind == "after" then 101
					elseif kind == "tolerated_before" then 99.997001 elseif kind == "tolerated_after" then 100.002999
					elseif kind == "first_failure" and index == 1 then 100.003001
					elseif kind == "last_failure" and index == 4 then 100.003001 else 100
				local body = participants[index].report({ kind = "ClockReply", participantSharedSeconds = client,
					localBeforeSeconds = 1, localAfterSeconds = 1 }).body
				if kind == "malformed" then
					local bad = table.clone(body)
					bad.extra = true
					assert(coordinator.receive(roster[index], bad).kind == "Terminated", "malformed reply masked")
					return
				end
				local result = coordinator.receive(roster[index], body)
				if index < 4 then
					local failed = kind == "before" or kind == "after" or kind == "regressed"
						or kind == "invalid" or kind == "throws" or (kind == "first_failure" and index == 1)
					assert(result.kind == (if failed then "Ignored" else "Accepted"))
				end
				if kind == "first_failure" and index == 1 then
					assert(coordinator.receive(roster[index], body).kind == "Ignored", "duplicate failure counted twice")
				end
			end
		end
		returned = true
	end)
	local ok, problem = coroutine.resume(thread)
	if kind == "early" then
		assert(not ok and string.find(tostring(problem), "CLOCK_DIAGNOSTIC_E_INCOMPLETE_CHALLENGE", 1, true))
		assert(captured == nil)
		return
	elseif kind == "malformed" then
		assert(ok and captured == nil and coroutine.status(thread) == "dead")
		return
	end
	assert(ok, problem)
	assert(captured ~= nil and not returned and coroutine.status(thread) == "suspended", "diagnostic continued into warmup")
	coroutine.close(thread)
	assert(captured.rankingEligible == false and captured.measuredWorkStarted == false and captured.warmupStarted == false)
	assert(captured.version == 2 and captured.toleranceMilliseconds == 3 and captured.readinessPhaseMilliseconds >= 0)
	if kind == "accepted" then
		assert(captured.status == "ClockAccepted" and #captured.formalReplies == 4)
		assert(captured.readinessReplyCount == 40 and #captured.readinessTail == 32)
	elseif kind == "tolerated_before" or kind == "tolerated_after" then
		assert(captured.status == "ClockAccepted" and #captured.formalReplies == 4)
		for _, sample in captured.formalReplies do
			assert(not sample.inBracket and sample.withinTolerance and sample.protocolAccepted)
		end
		if kind == "tolerated_after" then
			assert(captured.readinessStrictOutsideCount == 8 and captured.readinessToleranceOutsideCount == 0)
			assert(captured.readinessMaxViolationMilliseconds > 2.998 and captured.readinessMaxViolationMilliseconds < 3)
		end
	elseif kind == "boundary" then
		assert(captured.status == "BoundaryStopped" and #captured.formalReplies == 0)
	else
		local expected = if kind == "before" then "ClientBeforeServerSend"
			elseif kind == "after" or kind == "first_failure" or kind == "last_failure" then "ClientAfterServerReceive" else "ServerReadRejected"
		assert(captured.status == "ClockRejected" and captured.rejection.reason == expected)
		assert(#captured.formalReplies == 4, "stopped at first rejection instead of collecting all four replies")
		if kind == "first_failure" or kind == "last_failure" then
			local rejectedIndex = if kind == "first_failure" then 1 else 4
			assert(captured.rejection.participantIndex == rejectedIndex)
			for index, sample in captured.formalReplies do assert(sample.protocolAccepted == (index ~= rejectedIndex)) end
		end
		local sample = captured.formalReplies[1]
		assert(sample.serverBefore.seconds == 100 and sample.serverAfter.previousSeconds == 100)
		if kind == "regressed" then assert(sample.serverAfter.status == "Regressed" and sample.serverAfter.seconds == 99) end
		if kind == "invalid" then assert(sample.serverAfter.status == "Invalid" and sample.serverAfter.seconds == nil) end
		if kind == "throws" then assert(sample.serverAfter.status == "Threw") end
	end
	local wrong = table.clone(binding)
	wrong.caseId = "state-burst-c2s"
	reject(function() tap.newCoordinator(wrong, roster, function() return 100 end, function() return true end) end)
	return captured
end

local captured
local cases = {}
for _, kind in { "accepted", "tolerated_before", "tolerated_after", "before", "after", "first_failure", "last_failure", "regressed", "invalid", "throws", "early", "malformed", "boundary" } do
	captured = scenario(kind)
	cases[kind] = captured
end
local function hex(value)
	return (string.gsub(value, ".", function(character) return string.format("%02x", string.byte(character)) end))
end
local capability = string.rep("a", 64)
local function frame(value)
	local body = serde.encode("json", value)
	local count = math.ceil(#body / 1024)
	local lines = { `RELAY_TERMINAL_V1 {capability} BEGIN {launchId} {hex("0.737.0.7371584")} {#body} {count}` }
	for index = 1, count do
		table.insert(lines, `RELAY_TERMINAL_V1 {capability} CHUNK {launchId} {index} {hex(string.sub(body, (index - 1) * 1024 + 1, index * 1024))}`)
	end
	table.insert(lines, `RELAY_TERMINAL_V1 {capability} END {launchId} {#body} {count}`)
	return table.concat(lines, "\n"), body
end
local log, body = frame(captured)
assert(Diagnostic.collect(log, capability, launchId).status == "BoundaryStopped")
reject(function() Diagnostic.collect(log, string.rep("b", 64), launchId) end)
reject(function() Diagnostic.collect(string.sub(log, 1, #log - 10), capability, launchId) end)
reject(function() Diagnostic.collect(log .. "\n" .. log, capability, launchId) end)
reject(function() Host.decodeRoot(body, launchId) end)
for _, kind in { "accepted", "tolerated_after", "first_failure", "last_failure", "regressed" } do
	assert(Diagnostic.collect(frame(cases[kind]), capability, launchId).status == cases[kind].status)
end
local wrongTolerance = table.clone(captured)
wrongTolerance.toleranceMilliseconds = 5
reject(function() Diagnostic.collect(frame(wrongTolerance), capability, launchId) end)
local falsePass = table.clone(cases.first_failure)
falsePass.status = "ClockAccepted"
reject(function() Diagnostic.collect(frame(falsePass), capability, launchId) end)
local repeated = table.clone(cases.accepted)
repeated.formalReplies = table.clone(repeated.formalReplies)
repeated.formalReplies[4] = repeated.formalReplies[1]
reject(function() Diagnostic.collect(frame(repeated), capability, launchId) end)
for _, field in { "rankingEligible", "measuredWorkStarted", "warmupStarted" } do
	local bad = table.clone(captured)
	bad[field] = true
	reject(function() Diagnostic.collect(frame(bad), capability, launchId) end)
end

-- The actual ordinary build keeps its frozen fingerprint; the overlay cannot
-- pass as a normal measured place, and its original protocol source is intact.
local root = string.gsub(process.cwd, "\\", "/")
local path = root .. "/.tmp/clock-diagnostic-build-" .. Host.randomHex(16, process.os, process.exec) .. ".rbxlx"
fs.writeFile(path, "", { overwrite = false })
local builtOk, builtError = pcall(function()
	local base = Host.buildPlace(root, path, process.exec, fs.isFile, fs.readFile)
	assert(Fingerprint.collect(root, base, fs, roblox, serde.hash) == Diagnostic.BASELINE)
	local original = roblox.deserializePlace(base):FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark"):FindFirstChild("Runner"):FindFirstChild("ControlProtocol").Source
	local bytes, candidate = Diagnostic.instrumentPlace(base, source)
	local runner = roblox.deserializePlace(bytes):FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark"):FindFirstChild("Runner")
	assert(runner:FindFirstChild("ClockDiagnosticOriginal").Source == original)
	assert(runner:FindFirstChild("ClockDiagnosticCandidate").Source == candidate
		and candidate == Diagnostic.candidateSource(original))
	assert(runner:FindFirstChild("ControlProtocol").Source == source)
	reject(function() Fingerprint.collect(root, bytes, fs, roblox, serde.hash) end)
end)
fs.removeFile(path)
assert(builtOk, builtError)
print("PASS clock-diagnostic: 3 ms candidate, all-four capture after rejection, pre-warmup stop, invalid input rejection, unchanged baseline build")
