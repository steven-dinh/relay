--!strict

-- A deliberately fixed, non-ranking Studio pilot. V1 admission, lifecycle, and
-- result contracts are not changed. Only local clocks are used here.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")
local HttpService = game:GetService("HttpService")
local benchmark = ReplicatedStorage:WaitForChild("RelayBenchmark")
local AdapterContract = require(benchmark.adapters.AdapterContract)
local Fixtures = require(benchmark.fixtures["event-v1"])
local Comparator = require(benchmark.correctness.PayloadComparator)
local Contract = require(benchmark.contracts["event-v1"])
local Readiness = require(benchmark.Runner.ExternalReadiness)
local Clock = require(benchmark.Runner.BenchmarkClock)
local StudioClock = require(benchmark.Runner.StudioBenchmarkClock)
local Observer = require(script.Parent.DeliveryObserver)

local CASE_ID = "state-burst-c2s"
local SELECTION = { kind = "Workload", workloadId = CASE_ID, recipientCount = 1 }
local definition: any
for _, workload in Contract.workloads do
	if workload.id == CASE_ID then definition = workload; break end
end
assert(definition ~= nil and definition.repetitions == 30)

local function finiteSeconds(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function fixtures(): any
	local result = {}
	for index = 1, definition.repetitions do result[index] = Fixtures.generate(CASE_ID, index) end
	return result
end

local function waitUntil(predicate: () -> boolean, check: () -> (), now: () -> number, seconds: number)
	local deadline = now() + seconds
	repeat
		check()
		if predicate() then return end
		assert(now() < deadline, "PILOT_E_DEADLINE")
		RunService.PostSimulation:Wait()
	until false
end

local function quiet(check: () -> ())
	for _ = 1, Contract.execution.quiescenceFrames do
		check()
		RunService.PostSimulation:Wait()
	end
	check()
end

local function preflight(config: any): any
	assert(RunService:IsStudio(), "PILOT_E_STUDIO_ONLY")
	assert(config.adapterId == "quicknet" or config.adapterId == "zap", "PILOT_E_ADAPTER")
	-- Existing identity is used only for capability/operation validation, never
	-- as evidence that these warm windows performed ProcessRestart isolation.
	local result = AdapterContract.preflight(config.identity, SELECTION, version())
	assert(result.kind == "Supported", "PILOT_E_PREFLIGHT")
	return result
end

local function runServer()
	local config = require(benchmark:WaitForChild("PilotConfig"))
	local clock = Clock.new(StudioClock.newPort())
	local now = clock.localNowSeconds
	local started = now()
	local failure: string? = nil
	local side: any = nil
	local observer: any = nil
	local control: RemoteFunction? = nil
	local connections = {}
	local report: any = {
		kind = "RelaySessionReusePilot", version = 1, launchId = config.launchId,
		adapterId = config.adapterId, caseId = CASE_ID, recipientCount = 1,
		lifecycle = "PersistentSession", rankingEligible = false, sharedClockProof = "NotRun",
		studioVersion = version(), status = "Failed", setupSeconds = 0, sessionSeconds = 0,
		serverSetups = 0, clientSetups = 0, windows = {},
	}
	local function latch(reason: any)
		if failure == nil then failure = string.sub(tostring(reason), 1, 512) end
	end
	local function check()
		assert(failure == nil, failure or "PILOT_E_FAILURE")
		if observer ~= nil then observer.assertHealthy() end
	end
	local ok, message = pcall(function()
		local supported = preflight(config)
		local windows = fixtures()
		waitUntil(function() return #Players:GetPlayers() == 1 end, check, now, 120)
		local player = Players:GetPlayers()[1]
		table.insert(connections, Players.PlayerAdded:Connect(function() latch("PILOT_E_EXTRA_PLAYER") end))
		table.insert(connections, Players.PlayerRemoving:Connect(function() latch("PILOT_E_PLAYER_LEFT") end))
		observer = Observer.new(player)
		local root = ServerStorage.RelayBenchmarkServer.ExternalTemplate:Clone()
		root.Name = "PilotTransport"
		root.Parent = benchmark
		assert(Readiness.prewarm(config.adapterId, root, "Server", clock.timeoutNowSeconds).kind == "Ready",
			"PILOT_E_SERVER_PREWARM")
		local factory = Readiness.wrapFactory(config.adapterId, require(benchmark.adapters.ExternalSelected))
		side = AdapterContract.constructServer(supported, factory, root, {}, observer.sink)
		side.setup()
		report.serverSetups += 1
		waitUntil(side.ready, check, now, 120)

		local nextIndex, nextPhase = 1, "Warmup"
		local stage, busy, done = "AwaitReady", false, false
		local remote = Instance.new("RemoteFunction")
		control = remote
		remote.Name = "PilotControl"
		remote.OnServerInvoke = function(sender: Player, command: any, ...: any): any
			local count = select("#", ...)
			if sender ~= player or count > 4 or busy then latch("PILOT_E_CONTROL"); return false end
			local arguments = table.pack(...)
			busy = true
			local accepted, reason = pcall(function()
				check()
				assert(#Players:GetPlayers() == 1 and Players:GetPlayers()[1] == player, "PILOT_E_ROSTER")
				if command == "Abort" then
					assert(count == 1 and type(arguments[1]) == "string" and #arguments[1] <= 512,
						"PILOT_E_CONTROL")
					error("PILOT_E_CLIENT: " .. arguments[1], 0)
				elseif command == "Ready" then
					assert(count == 0 and stage == "AwaitReady", "PILOT_E_CONTROL")
					report.clientSetups = 1
					report.setupSeconds = now() - started
					stage = "BetweenPhases"
				elseif command == "Begin" then
					assert(count == 2 and stage == "BetweenPhases" and arguments[1] == nextIndex
						and arguments[2] == nextPhase and nextIndex <= definition.repetitions, "PILOT_E_CONTROL")
					local fixture = windows[nextIndex]
					observer.arm(if nextPhase == "Warmup" then fixture.warmup else fixture.measured)
					if nextPhase == "Warmup" then
						report.windows[nextIndex] = {
							index = nextIndex, expected = #fixture.warmup + #fixture.measured, received = 0,
							warmupQuietFrames = 0, measuredQuietFrames = 0,
							senderMeasuredSeconds = 0, senderCallSeconds = 0,
						}
					end
					stage = "Sending"
					-- Arm the receiver before the client can enter a sending frame.
					RunService.PostSimulation:Wait()
				elseif command == "End" then
					assert(count == 4 and stage == "Sending" and arguments[1] == nextIndex
						and arguments[2] == nextPhase and finiteSeconds(arguments[3])
						and finiteSeconds(arguments[4]) and arguments[4] <= arguments[3], "PILOT_E_CONTROL")
					local fixture = windows[nextIndex]
					local samples = if nextPhase == "Warmup" then fixture.warmup else fixture.measured
					waitUntil(function() return observer.count() == #samples end, check, now, 30)
					local row = report.windows[nextIndex]
					row.received += observer.count()
					observer.close()
					-- The callback stays installed: any delivery now fails the session.
					quiet(check)
					if nextPhase == "Warmup" then
						row.warmupQuietFrames = Contract.execution.quiescenceFrames
						nextPhase = "Measured"
					else
						row.measuredQuietFrames = Contract.execution.quiescenceFrames
						row.senderMeasuredSeconds, row.senderCallSeconds = arguments[3], arguments[4]
						nextIndex += 1
						nextPhase = "Warmup"
					end
					stage = "BetweenPhases"
				elseif command == "Finish" then
					assert(count == 0 and stage == "BetweenPhases" and nextIndex == definition.repetitions + 1,
						"PILOT_E_CONTROL")
					stage, done = "Finished", true
				else
					error("PILOT_E_CONTROL", 0)
				end
				check()
			end)
			busy = false
			if not accepted then latch(reason) end
			return accepted
		end
		remote.Parent = benchmark
		waitUntil(function() return done and not busy end, check, now, 480)
		quiet(check)
		local expected = definition.repetitions * definition.messagesPerFrame
			* (definition.warmupFrames + definition.measuredFrames)
		assert(observer.total() == expected, "PILOT_E_TOTAL")
		check()
		report.status = "Passed"
	end)
	if not ok then latch(message) end
	-- One physical teardown at the end, not one per window. Host-confirmed
	-- Studio exit, not this callback gate, proves final singleton cleanup.
	if side ~= nil then
		local cleaned, reason = pcall(side.teardown)
		if not cleaned then latch(reason) end
	end
	for _, connection in connections do connection:Disconnect() end
	if control ~= nil then control.OnServerInvoke = nil end
	if failure ~= nil then report.status, report.error = "Failed", failure end
	report.sessionSeconds = now() - started
	StudioTestService:EndTest(HttpService:JSONEncode(report))
end

local function runClient()
	local config = require(benchmark:WaitForChild("PilotConfig"))
	local clock = Clock.new(StudioClock.newPort())
	local now = clock.localNowSeconds
	local failure: string? = nil
	local side: any = nil
	local control: RemoteFunction? = nil
	local tornDown = false
	local function check() assert(failure == nil, failure or "PILOT_E_CLIENT_DELIVERY") end
	local ok, message = pcall(function()
		local supported = preflight(config)
		local windows = fixtures()
		-- Fresh inputs are prepared outside timed calls and retained for a final
		-- deferred-mutation check, including after the adapter is torn down.
		local inputs = {}
		for _, fixture in windows do
			for _, phase in { fixture.warmup, fixture.measured } do
				for _, sample in phase do inputs[sample.sequence] = Fixtures.newInput(sample) end
			end
		end
		local root = benchmark:WaitForChild("PilotTransport", 120)
		assert(root ~= nil, "PILOT_E_REPLICATION")
		assert(Readiness.prewarm(config.adapterId, root, "Client", clock.timeoutNowSeconds).kind == "Ready",
			"PILOT_E_CLIENT_PREWARM")
		local factory = Readiness.wrapFactory(config.adapterId, require(benchmark.adapters.ExternalSelected))
		side = AdapterContract.constructClient(supported, factory, root, 1, function()
			failure = failure or "PILOT_E_UNEXPECTED_CLIENT_DELIVERY"
		end)
		side.setup()
		waitUntil(side.ready, check, now, 120)
		local remote = benchmark:WaitForChild("PilotControl", 120)
		assert(remote ~= nil and remote:IsA("RemoteFunction"), "PILOT_E_CONTROL")
		control = remote :: RemoteFunction
		local function command(name: string, ...: any)
			check()
			assert((remote :: RemoteFunction):InvokeServer(name, ...) == true, "PILOT_E_SERVER_REJECTED")
			check()
		end
		command("Ready")
		for index, fixture in windows do
			for _, phase in { "Warmup", "Measured" } do
				local samples = if phase == "Warmup" then fixture.warmup else fixture.measured
				command("Begin", index, phase)
				local first: number? = nil
				local callSeconds = 0
				for offset, sample in samples do
					check()
					if offset == 1 or samples[offset - 1].frameIndex ~= sample.frameIndex then
						RunService.PostSimulation:Wait()
					end
					local input = inputs[sample.sequence]
					local nextSample = samples[offset + 1]
					local boundary = if nextSample == nil or nextSample.frameIndex ~= sample.frameIndex
						then "FlushBeforeReturn" else "ContinueFrame"
					local callStart = now()
					if first == nil then first = callStart end
					side.submit(input, boundary)
					callSeconds += now() - callStart
					-- Payload comparison is outside the adapter-call timing boundary.
					assert(Comparator.compareRecord(sample.payloadId, sample.expected, input), "PILOT_E_INPUT_MUTATION")
				end
				RunService.PostSimulation:Wait()
				local elapsed = now() - (first :: number)
				for _, sample in samples do
					assert(Comparator.compareRecord(sample.payloadId, sample.expected, inputs[sample.sequence]),
						"PILOT_E_DEFERRED_MUTATION")
				end
				command("End", index, phase, elapsed, callSeconds)
			end
		end
		side.teardown()
		tornDown = true
		quiet(check)
		for _, fixture in windows do
			for _, phase in { fixture.warmup, fixture.measured } do
				for _, sample in phase do
					assert(Comparator.compareRecord(sample.payloadId, sample.expected, inputs[sample.sequence]),
						"PILOT_E_FINAL_MUTATION")
				end
			end
		end
		command("Finish")
	end)
	if not ok then
		if side ~= nil and not tornDown then pcall(side.teardown) end
		local remote = control or benchmark:FindFirstChild("PilotControl")
		if remote ~= nil then
			pcall(function() (remote :: RemoteFunction):InvokeServer("Abort", string.sub(tostring(message), 1, 512)) end)
		end
		warn("RelaySessionReusePilot.ClientFailure", tostring(message))
	end
end

return table.freeze({ runServer = runServer, runClient = runClient })
