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
local launchId = "00000000-0000-4000-8000-000000000001"

local function reject(callback)
	assert(not pcall(callback), "invalid diagnostic input accepted")
end

local function scenario(kind)
	local captured
	local tap = luau.load(source, { debugName = "ClockTap", environment = {
		require = function(path) assert(path == "./ClockDiagnosticOriginal"); return Protocol end,
		game = { GetService = function(_, name)
			if name == "HttpService" then return { JSONEncode = function(_, value) return serde.encode("json", value) end } end
			assert(name == "StudioTestService")
			return { EndTest = function(_, body) assert(captured == nil); captured = serde.decode("json", body) end }
		end },
	} })()
	assert(tap.newParticipant == Protocol.newParticipant, "client protocol changed")
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
		roundTrip({ kind = "ClockReadinessChallenge" }, { kind = "ClockReadinessReply", participantSharedSeconds = 100 })
	end
	local returned = false
	local thread = coroutine.create(function()
		if kind == "boundary" then
			coordinator.command(1, { kind = "BeginWarmup", repetitionIndex = 1 })
		else
			for index = 1, 4 do
				assert(participants[index].receive(coordinator.command(index, { kind = "ClockChallenge" }).body).kind == "Accepted")
			end
			if kind == "regressed" then clock = 99 end
			if kind == "invalid" then clock = 0 / 0 end
			if kind == "throws" then throws = true end
			local client = if kind == "before" then 99 elseif kind == "after" then 101 else 100
			for index = 1, 4 do
				local body = participants[index].report({ kind = "ClockReply", participantSharedSeconds = client,
					localBeforeSeconds = 1, localAfterSeconds = 1 }).body
				coordinator.receive(roster[index], body)
			end
		end
		returned = true
	end)
	local ok, problem = coroutine.resume(thread)
	assert(ok, problem)
	assert(captured ~= nil and not returned and coroutine.status(thread) == "suspended", "diagnostic continued into warmup")
	coroutine.close(thread)
	assert(captured.rankingEligible == false and captured.measuredWorkStarted == false and captured.warmupStarted == false)
	if kind == "accepted" then
		assert(captured.status == "ClockAccepted" and #captured.formalReplies == 4)
		assert(captured.readinessReplyCount == 40 and #captured.readinessTail == 32)
	elseif kind == "boundary" then
		assert(captured.status == "BoundaryStopped" and #captured.formalReplies == 0)
	else
		local expected = if kind == "before" then "ClientBeforeServerSend" elseif kind == "after" then "ClientAfterServerReceive" else "ServerReadRejected"
		assert(captured.status == "ClockRejected" and captured.rejection.reason == expected)
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
for _, kind in { "accepted", "before", "after", "regressed", "invalid", "throws", "boundary" } do captured = scenario(kind) end
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
	local bytes = Diagnostic.instrumentPlace(base, source)
	local runner = roblox.deserializePlace(bytes):FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark"):FindFirstChild("Runner")
	assert(runner:FindFirstChild("ClockDiagnosticOriginal").Source == original)
	assert(runner:FindFirstChild("ControlProtocol").Source == source)
	reject(function() Fingerprint.collect(root, bytes, fs, roblox, serde.hash) end)
end)
fs.removeFile(path)
assert(builtOk, builtError)
print("PASS clock-diagnostic: real protocol capture, pre-warmup stop, invalid input rejection, unchanged baseline build")
