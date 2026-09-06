-- Bounded diagnostic only: deliberately does not create a Result V1 or ranking.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Host = require("../host/HostRuntime")
local EventV1 = require("../contracts/event-v1")
local workload
for _, candidate in EventV1.workloads do
	if candidate.id == "state-burst-c2s" then workload = candidate; break end
end
assert(workload ~= nil and workload.repetitions == 30, "PILOT_E_CONTRACT")
local expectedDeliveries = (workload.warmupFrames + workload.measuredFrames) * workload.messagesPerFrame

local function parseArgs(arguments)
	assert(#arguments == 4, "usage: lune run benchmarks/pilot/run-session-reuse.luau --studio <absolute exe> --adapter quicknet|zap")
	local options = {}
	for index = 1, #arguments, 2 do
		local key = arguments[index]
		assert((key == "--studio" or key == "--adapter") and options[key] == nil, "PILOT_E_ARGUMENTS")
		options[key] = arguments[index + 1]
	end
	assert(options["--adapter"] == "quicknet" or options["--adapter"] == "zap", "PILOT_E_ADAPTER")
	assert(type(options["--studio"]) == "string" and string.match(options["--studio"], "^%a:[/\\]") ~= nil, "PILOT_E_STUDIO_PATH")
	return options["--studio"], options["--adapter"]
end

local function finite(value)
	return type(value) == "number" and value >= 0 and value < math.huge
end

local function validate(body, launchId, adapterId)
	assert(#body > 0 and #body <= 65_536 and Host.jsonPreflight(body), "PILOT_E_JSON")
	local value = serde.decode("json", body)
	assert(type(value) == "table" and value.kind == "RelaySessionReusePilot" and value.version == 1
		and value.launchId == launchId and value.adapterId == adapterId, "PILOT_E_IDENTITY")
	assert(type(value.studioVersion) == "string" and #value.studioVersion > 0 and #value.studioVersion <= 128, "PILOT_E_VERSION")
	assert(value.status == "Passed" or value.status == "Failed", "PILOT_E_STATUS")
	if value.error ~= nil then assert(type(value.error) == "string" and #value.error <= 512, "PILOT_E_ERROR") end
	if value.status == "Failed" then error("PILOT_E_FAILED: " .. (value.error or "unspecified"), 0) end
	assert(value.caseId == "state-burst-c2s" and value.recipientCount == 1
		and value.lifecycle == "PersistentSession" and value.rankingEligible == false
		and value.sharedClockProof == "NotRun", "PILOT_E_SELECTION")
	assert(finite(value.setupSeconds) and finite(value.sessionSeconds)
		and value.setupSeconds <= value.sessionSeconds
		and value.serverSetups == 1 and value.clientSetups == 1, "PILOT_E_SETUP")
	assert(type(value.windows) == "table" and #value.windows == 30, "PILOT_E_WINDOWS")
	local count = 0
	for key in value.windows do
		assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= 30, "PILOT_E_WINDOWS")
		count += 1
	end
	assert(count == 30, "PILOT_E_WINDOWS")
	for index, window in value.windows do
		assert(type(window) == "table" and window.index == index and window.expected == expectedDeliveries
			and window.received == window.expected
			and window.warmupQuietFrames == 60 and window.measuredQuietFrames == 60
			and finite(window.senderMeasuredSeconds) and finite(window.senderCallSeconds)
			and window.senderCallSeconds <= window.senderMeasuredSeconds, "PILOT_E_WINDOW")
	end
	return value
end

local function collect(log, capability, launchId, adapterId)
	assert(#log <= 1_048_576, "PILOT_E_LOG_SIZE")
	local chunks, total = {}, nil
	local expectedIndex = 1
	for line in string.gmatch(log, "[^\r\n]+") do
		local token, id, rawIndex, rawCount, encoded = string.match(line,
			"RELAY_SESSION_PILOT_1 ([0-9a-f]+) ([0-9a-f%-]+) (%d+) (%d+) ([0-9a-f]+)%s*$")
		if token ~= nil and Host.constantWorkCapability(token, capability) then
			local index, count = tonumber(rawIndex), tonumber(rawCount)
			assert(id == launchId and index == expectedIndex and count >= 1 and count <= 64
				and tostring(index) == rawIndex and tostring(count) == rawCount and index <= count
				and (total == nil or total == count) and #encoded <= 2048 and #encoded % 2 == 0, "PILOT_E_FRAME")
			total = count
			chunks[index] = string.gsub(encoded, "..", function(pair) return string.char(tonumber(pair, 16)) end)
			expectedIndex += 1
		end
	end
	assert(total ~= nil and #chunks == total, "PILOT_E_INCOMPLETE")
	return validate(table.concat(chunks), launchId, adapterId)
end

local function main(arguments)
	local studio, adapterId = parseArgs(arguments)
	assert(process.os == "windows" and fs.isFile(studio), "PILOT_E_STUDIO")
	local root = string.gsub(process.cwd, "\\", "/")
	Host.assertStudioIdle(process.os, process.exec)
	local launchId = Host.uuidV4(function(count) return Host.randomHex(count, process.os, process.exec) end)
	local capability = Host.randomHex(32, process.os, process.exec)
	local prefix = root .. "/.tmp/session-reuse-pilot-" .. launchId
	local paths = { project = prefix .. ".project.json", binding = prefix .. ".binding.luau",
		basePlace = prefix .. ".base.rbxlx", launchPlace = prefix .. ".rbxlx",
		bootstrap = prefix .. ".luau", output = prefix .. ".log" }
	local names = { "project", "binding", "basePlace", "launchPlace", "bootstrap", "output" }
	fs.writeDir(root .. "/.tmp")
	local owned = Host.reserveNamedPaths(paths, names, launchId, fs.isFile, function(path, value)
		fs.writeFile(path, value, { overwrite = false })
	end, fs.removeFile)
	local child, status
	local safeCleanup = true
	local started = os.clock()
	local ok, result = pcall(function()
		local prepared = Host.prepareExternalProject(root, adapterId, "./session-reuse-pilot-" .. launchId .. ".binding.luau",
			fs.readFile, function(value) return serde.decode("json", value) end, function(value) return serde.encode("json", value) end)
		local project = serde.decode("json", prepared.body)
		project.tree.ServerScriptService.RelayBenchmarkCoordinator = { ["$path"] = "../benchmarks/pilot/Server.server.luau" }
		project.tree.StarterPlayer.StarterPlayerScripts.RelayBenchmarkParticipant = { ["$path"] = "../benchmarks/pilot/Client.client.luau" }
		project.tree.ReplicatedStorage.RelayBenchmark.Pilot = {
			["$className"] = "Folder",
			PersistentSession = { ["$path"] = "../benchmarks/pilot/PersistentSession.luau" },
			DeliveryObserver = { ["$path"] = "../benchmarks/pilot/DeliveryObserver.luau" },
		}
		fs.writeFile(paths.project, serde.encode("json", project))
		fs.writeFile(paths.binding, prepared.bindingBody)
		local basePlace = Host.buildProject(root, paths.project, paths.basePlace, process.exec, fs.isFile, fs.readFile)
		Host.verifyExternalArtifacts(prepared.selected)
		local adapter = Host.collectExternalAdapter(prepared.selected, basePlace, roblox, serde.hash)
		local place = roblox.deserializePlace(basePlace)
		local config = roblox.Instance.new("ModuleScript")
		config.Name = "PilotConfig"
		config.Source = "return game:GetService(\"HttpService\"):JSONDecode(" .. string.format("%q", serde.encode("json", {
			adapterId = adapterId, identity = adapter.identity, launchId = launchId,
		})) .. ")"
		config.Parent = place:FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark")
		local pilotPlace = roblox.serializePlace(place, true)
		local facts = Host.collectSourceFacts(root, process.os, process.arch, process.exec, fs.readFile, serde.hash, pilotPlace)
		local launchPlace = Host.launchPlaceBytes(pilotPlace, { launchId = launchId, capability = capability, adapterId = adapterId }, roblox)
		fs.writeFile(paths.launchPlace, launchPlace)
		fs.writeFile(paths.bootstrap, fs.readFile(root .. "/benchmarks/pilot/Bootstrap.luau"))
		Host.assertStudioIdle(process.os, process.exec)
		local launched = os.clock()
		safeCleanup = false
		child = process.create(studio, Host.studioArguments(paths.launchPlace, paths.bootstrap, paths.output), { cwd = root })
		task.spawn(function() status = Host.childStatus(child) end)
		for _, reader in { child.stdout, child.stderr } do
			task.spawn(function() while reader:read() ~= nil do end end)
		end
		local outcome = Host.awaitOutcome(function() return status end, function()
			assert(Host.outputFileSize(paths.output, process.os, process.exec) <= 1_048_576, "PILOT_E_LOG_SIZE")
			return collect(fs.readFile(paths.output), capability, launchId, adapterId)
		end, function() Host.killChild(child) end, os.clock, task.wait, 600, 10)
		Host.assertStudioIdle(process.os, process.exec)
		safeCleanup = true
		assert(outcome.kind == "Complete", "PILOT_E_" .. outcome.kind)
		local value = outcome.terminal
		value.provenance = { benchmarkSource = facts.benchmarkSource,
			adapter = { id = adapterId, artifact = adapter.artifact, library = adapter.identity.library },
			host = facts.host, bootstrapSha256 = serde.hash("sha256", fs.readFile(paths.bootstrap)) }
		value.hostElapsedSeconds = os.clock() - started
		value.hostStudioSeconds = os.clock() - launched
		value.hostPreparationSeconds = launched - started
		-- Includes startup and shutdown; it is not a direct startup measurement.
		value.hostOutsideSessionSeconds = math.max(0, value.hostStudioSeconds - value.sessionSeconds)
		local outputPath = root .. "/benchmarks/results/local/session-reuse-pilot-" .. launchId .. ".json"
		fs.writeDir(root .. "/benchmarks/results/local")
		fs.writeFile(outputPath, serde.encode("json", value, true), { overwrite = false })
		return outputPath
	end)
	if not safeCleanup and child ~= nil then
		if status == nil then pcall(Host.killChild, child) end
		Host.confirmExit(function() return status end, os.clock, task.wait, 10)
		safeCleanup = pcall(Host.assertStudioIdle, process.os, process.exec)
	end
	if safeCleanup then
		if not ok and child ~= nil and fs.isFile(paths.output) then
			owned.output = nil
			warn("Failed pilot diagnostic log retained (private authenticated output): " .. paths.output)
		end
		assert(Host.cleanupNamedPaths(paths, names, owned, fs.isFile, fs.removeFile), "PILOT_E_CLEANUP")
	else
		warn("Pilot files retained: Studio exit is unconfirmed. " .. prefix)
	end
	if not ok then error(result, 0) end
	assert(safeCleanup, "PILOT_E_STUDIO_LIVE")
	print("PASS RelaySessionReusePilot (non-ranking) " .. result)
end

main(process.args)
