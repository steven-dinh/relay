-- Fixed, untimed Relay/four-client clock diagnostic. Never publishes Result V1/V2.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Host = require("../../host/HostRuntime")
local Fingerprint = require("../../host/MeasurementFingerprint")
local BASELINE = "sha256:10729c469a27cd393dbaa2512139e6be42a8c4e50098f2ed9aab91d995395f00"

local function instrumentPlace(base, source)
	local place = roblox.deserializePlace(base)
	local runner = place:FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark"):FindFirstChild("Runner")
	runner:FindFirstChild("ControlProtocol").Name = "ClockDiagnosticOriginal"
	local tap = roblox.Instance.new("ModuleScript")
	tap.Name, tap.Source, tap.Parent = "ControlProtocol", source, runner
	return roblox.serializePlace(place, true)
end

local function unhex(value)
	assert(#value % 2 == 0 and string.match(value, "^[0-9a-f]+$"), "CLOCK_DIAGNOSTIC_E_HEX")
	return (string.gsub(value, "..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function collect(log, capability, launchId)
	assert(type(log) == "string" and #log <= 1_048_576, "CLOCK_DIAGNOSTIC_E_LOG")
	local length, count, studioVersion
	local chunks, complete = {}, false
	for line in string.gmatch(log, "[^\r\n]+") do
		local token, frame = string.match(line, "^RELAY_TERMINAL_V1 ([^ ]+) (.+)$")
		if token ~= nil and Host.constantWorkCapability(token, capability) then
			assert(not complete, "CLOCK_DIAGNOSTIC_E_FRAME")
			local id, versionHex, rawLength, rawCount = string.match(frame, "^BEGIN ([0-9a-f%-]+) ([0-9a-f]+) (%d+) (%d+)$")
			if id ~= nil then
				assert(length == nil and id == launchId and #versionHex <= 128, "CLOCK_DIAGNOSTIC_E_BEGIN")
				length, count, studioVersion = tonumber(rawLength), tonumber(rawCount), unhex(versionHex)
				assert(length >= 1 and length <= 65_536 and count == math.ceil(length / 1024)
					and rawLength == tostring(length) and rawCount == tostring(count)
					and #studioVersion > 0, "CLOCK_DIAGNOSTIC_E_SIZE")
			else
				local chunkId, rawIndex, encoded = string.match(frame, "^CHUNK ([0-9a-f%-]+) (%d+) ([0-9a-f]+)$")
				if chunkId ~= nil then
					local index = tonumber(rawIndex)
					assert(length ~= nil and chunkId == launchId and index == #chunks + 1
						and rawIndex == tostring(index) and index <= count
						and #encoded == math.min(1024, length - #chunks * 1024) * 2, "CLOCK_DIAGNOSTIC_E_CHUNK")
					table.insert(chunks, unhex(encoded))
				else
					local endId, endLength, endCount = string.match(frame, "^END ([0-9a-f%-]+) (%d+) (%d+)$")
					assert(length ~= nil and endId == launchId and endLength == tostring(length)
						and endCount == tostring(count) and #chunks == count, "CLOCK_DIAGNOSTIC_E_END")
					complete = true
				end
			end
		end
	end
	assert(complete, "CLOCK_DIAGNOSTIC_E_INCOMPLETE")
	local body = table.concat(chunks)
	assert(#body == length and Host.jsonPreflight(body), "CLOCK_DIAGNOSTIC_E_JSON")
	local value = serde.decode("json", body)
	assert(type(value) == "table" and value.kind == "RelayClockDiagnostic" and value.version == 1
		and value.launchId == launchId and value.adapterId == "relay-reliable"
		and value.caseId == "state-broadcast-s2c" and value.recipientCount == 4
		and value.rankingEligible == false and value.measuredWorkStarted == false and value.warmupStarted == false,
		"CLOCK_DIAGNOSTIC_E_IDENTITY")
	assert(value.status == "ClockRejected" or value.status == "ClockAccepted" or value.status == "BoundaryStopped",
		"CLOCK_DIAGNOSTIC_E_STATUS")
	assert(type(value.readinessTail) == "table" and #value.readinessTail <= 32
		and type(value.formalReplies) == "table" and #value.formalReplies <= 4
		and type(value.readinessReplyCount) == "number" and value.readinessReplyCount >= 0
		and value.readinessReplyCount <= 480, "CLOCK_DIAGNOSTIC_E_RECORDS")
	if value.status == "ClockAccepted" then assert(#value.formalReplies == 4, "CLOCK_DIAGNOSTIC_E_PROOF") end
	if value.status == "ClockRejected" then assert(type(value.rejection) == "table", "CLOCK_DIAGNOSTIC_E_REJECTION") end
	value.studioVersion = studioVersion
	return value
end

local function main(arguments)
	assert(#arguments == 2 and arguments[1] == "--studio", "usage: lune run benchmarks/diagnostics/clock/run.luau --studio <absolute exe>")
	local studio = arguments[2]
	assert(process.os == "windows" and type(studio) == "string" and string.match(studio, "^%a:[/\\]")
		and fs.isFile(studio), "CLOCK_DIAGNOSTIC_E_STUDIO")
	local root = string.gsub(process.cwd, "\\", "/")
	Host.assertStudioIdle(process.os, process.exec)
	Host.assertCleanSource(root, nil, process.exec)
	local launchId = Host.uuidV4(function(size) return Host.randomHex(size, process.os, process.exec) end)
	local capability = Host.randomHex(32, process.os, process.exec)
	local prefix = root .. "/.tmp/clock-diagnostic-" .. launchId
	local paths = { basePlace = prefix .. ".base.rbxlx", launchPlace = prefix .. ".rbxlx",
		bootstrap = prefix .. ".luau", output = prefix .. ".log" }
	local names = { "basePlace", "launchPlace", "bootstrap", "output" }
	fs.writeDir(root .. "/.tmp")
	local owned = Host.reserveNamedPaths(paths, names, launchId, fs.isFile, function(path, value)
		fs.writeFile(path, value, { overwrite = false })
	end, fs.removeFile)
	local child, status
	local safeCleanup = true
	local started = os.clock()
	local ok, result = pcall(function()
		local base = Host.buildPlace(root, paths.basePlace, process.exec, fs.isFile, fs.readFile)
		assert(Fingerprint.collect(root, base, fs, roblox, serde.hash) == BASELINE, "CLOCK_DIAGNOSTIC_E_BASELINE_CHANGED")
		local facts = Host.collectSourceFacts(root, process.os, process.arch, process.exec, fs.readFile, serde.hash, base)
		local adapter = Host.collectRelayAdapter(facts.benchmarkSource.revision, base, roblox, serde.hash, "PersistentSession")
		local source = fs.readFile(root .. "/benchmarks/diagnostics/clock/ClockTap.luau")
		local diagnosticPlace = instrumentPlace(base, source)
		facts = table.clone(facts)
		facts.benchmarkSource = table.clone(facts.benchmarkSource)
		facts.benchmarkSource.placeFingerprint = "sha256:" .. serde.hash("sha256", diagnosticPlace)
		facts.benchmarkSource.measurementFingerprint = Fingerprint.digest({ baseline = BASELINE, observer = source }, serde.hash, "RelayClockDiagnostic:1")
		facts.benchmarkSource.adapterFingerprint = adapter.artifact.digest
		facts.contractFingerprint = Fingerprint.digest({
			["event-v1.luau"] = fs.readFile(root .. "/benchmarks/contracts/event-v1.luau"),
			["PersistentSessionProfile.luau"] = fs.readFile(root .. "/benchmarks/contracts/internal/PersistentSessionProfile.luau"),
		}, serde.hash, "RelayContractFingerprint:1:event-session-v1")
		local options = Host.parseArgs({ "--studio", studio, "--mode", "PersistentBenchmark", "--case", "state-broadcast-s2c", "--recipients", "4", "--adapter", "relay-reliable" }, process.os)
		local carrier = Host.carrierData(launchId, capability, options, facts, adapter)
		local launchBytes = Host.launchPlaceBytes(diagnosticPlace, carrier, roblox)
		fs.writeFile(paths.launchPlace, launchBytes)
		local bootstrap = Host.bootstrapSource()
		fs.writeFile(paths.bootstrap, bootstrap)
		Host.assertCleanSource(root, facts.benchmarkSource.revision, process.exec)
		Host.assertStudioIdle(process.os, process.exec)
		safeCleanup = false
		child = process.create(studio, Host.studioArguments(paths.launchPlace, paths.bootstrap, paths.output), { cwd = root })
		task.spawn(function() status = Host.childStatus(child) end)
		for _, reader in { child.stdout, child.stderr } do
			task.spawn(function() while reader:read() ~= nil do end end)
		end
		local outcome = Host.awaitOutcome(function() return status end, function()
			assert(Host.outputFileSize(paths.output, process.os, process.exec) <= 1_048_576, "CLOCK_DIAGNOSTIC_E_LOG")
			return collect(fs.readFile(paths.output), capability, launchId)
		end, function() Host.killChild(child) end, os.clock, task.wait, 180, 10)
		Host.assertStudioIdle(process.os, process.exec)
		safeCleanup = true
		assert(outcome.kind == "Complete", "CLOCK_DIAGNOSTIC_E_" .. outcome.kind)
		Host.assertCleanSource(root, facts.benchmarkSource.revision, process.exec)
		assert(Fingerprint.collect(root, base, fs, roblox, serde.hash) == BASELINE, "CLOCK_DIAGNOSTIC_E_BASELINE_CHANGED")
		local value = outcome.terminal
		value.provenance = { sourceRevision = facts.benchmarkSource.revision, sourceDirty = facts.benchmarkSource.dirty,
			baselineMeasurementFingerprint = BASELINE, diagnosticPlaceFingerprint = facts.benchmarkSource.placeFingerprint,
			observerFingerprint = "sha256:" .. serde.hash("sha256", source), bootstrapFingerprint = "sha256:" .. serde.hash("sha256", bootstrap) }
		value.hostElapsedSeconds = os.clock() - started
		value.studioExitConfirmed = true
		local output = root .. "/benchmarks/results/local/clock-diagnostic-" .. launchId .. ".json"
		fs.writeDir(root .. "/benchmarks/results/local")
		fs.writeFile(output, serde.encode("json", value, true), { overwrite = false })
		return output
	end)
	if not safeCleanup and child ~= nil then
		if status == nil then pcall(Host.killChild, child) end
		Host.confirmExit(function() return status end, os.clock, task.wait, 10)
		safeCleanup = pcall(Host.assertStudioIdle, process.os, process.exec)
	end
	if safeCleanup then
		if not ok and child ~= nil and fs.isFile(paths.output) then
			owned.output = nil
			warn("Private diagnostic log retained: " .. paths.output)
		end
		assert(Host.cleanupNamedPaths(paths, names, owned, fs.isFile, fs.removeFile), "CLOCK_DIAGNOSTIC_E_CLEANUP")
	else
		warn("Diagnostic files retained: Studio exit unconfirmed. " .. prefix)
	end
	if not ok then error(result, 0) end
	assert(safeCleanup, "CLOCK_DIAGNOSTIC_E_STUDIO_LIVE")
	print("CAPTURED RelayClockDiagnostic (untimed, non-ranking) " .. result)
end

return table.freeze({ main = main, collect = collect, instrumentPlace = instrumentPlace, BASELINE = BASELINE })
