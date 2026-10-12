--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local benchmark = script.Parent.Parent
local Config = require(script.Parent.Config)
local Model = require(script.Parent.Model)
local Readiness = require(benchmark.Runner.ExternalReadiness)
local CallbackTiming = require(script.Parent.CallbackTiming)

local coreValue
local cpuValue: BoolValue?
if type(script.Parent.WaitForChild) == "function" then
	coreValue = script.Parent:WaitForChild("QuickCoreCases", Config.timeoutSeconds)
	assert(coreValue ~= nil, "QuickCoreCases did not replicate before timeout")
	cpuValue = script.Parent:WaitForChild("ProfileCpu", Config.timeoutSeconds) :: BoolValue?
	assert(cpuValue ~= nil, "ProfileCpu did not replicate before timeout")
elseif type(script.Parent.FindFirstChild) == "function" then
	-- Portable test fixtures may not implement Roblox's yielding Instance API.
	coreValue = script.Parent:FindFirstChild("QuickCoreCases")
	cpuValue = script.Parent:FindFirstChild("ProfileCpu") :: BoolValue?
end
local coreCaseIds = Model.coreCases(if coreValue then coreValue.Value else nil)
local coreEnabled = #coreCaseIds > 0
if not coreEnabled then coreCaseIds = { Config.caseId } end
local initialConfig = table.clone(Config)
if coreEnabled then initialConfig.caseId = coreCaseIds[1] end
local selected = Model.selection(initialConfig)
local adapterIds = string.split(benchmark.QuickAdapters.Value, ",")
local sides = {}
local failure: string? = nil
local validity = { valid = true, failure = nil :: string? }
local initialized, running = false, false
local completed, closed = false, false
local control: RemoteFunction? = nil
local player: Player? = nil
local isServer = RunService:IsServer()
local profileEnabled = CallbackTiming.enabled == true
local sdkInstance
if cpuValue ~= nil and cpuValue.Value == true and not isServer then
	assert(profileEnabled, "LibMP profiling requires receive profiling")
	sdkInstance = if type(script.Parent.WaitForChild) == "function"
		then script.Parent:WaitForChild("LibMPSdk", Config.timeoutSeconds)
		else script.Parent:FindFirstChild("LibMPSdk")
	assert(sdkInstance ~= nil, "LibMP SDK did not replicate before timeout")
end
local cpu: any = nil
local latestCpuReport: any = nil
local cpuConnection: RBXScriptConnection? = nil
local cpuToken: string? = nil
local cpuCaptureOrdinal = 0
local function receiving(selection: any): boolean
	return selection.kind == "SeparateProbe"
		or selection.direction == (if isServer then "ClientToServer" else "ServerToClient")
end
local receives = receiving(selected)
local fieldCount = selected.fieldCount or (if selected.payloadId == "tiny" then 2 else 5)
local envelopes = {
	record = function(value) return { kind = "Record", value = value } end,
	positional = function(...)
		local count = select("#", ...)
		local values = {}
		for index = 1, math.min(count, fieldCount + 1) do values[index] = select(index, ...) end
		return { kind = "Positional", values = values, count = count }
	end,
}

local function teardown()
	for _, state in sides do
		local side = state.side
		state.side = nil
		if side then pcall(side.teardown) end
	end
end

local function fail(reason: any)
	if failure ~= nil then return end
	failure = string.sub(tostring(reason), 1, 512)
	validity.valid, validity.failure = false, failure
	benchmark:SetAttribute("QuickStatus", "Failed")
	if isServer then benchmark:SetAttribute("QuickFailure", failure) end
	warn("[Relay quick] FAILED; all results from this Play session are invalid. Stop/Play to retry: " .. failure)
	if cpuConnection then cpuConnection:Disconnect(); cpuConnection = nil end
	if cpu then pcall(function() cpu:close() end) end
	teardown()
	if not isServer then
		local remote = control or benchmark:FindFirstChild("QuickControl")
		if remote then task.spawn(function() pcall(function() remote:InvokeServer("Abort") end) end) end
	end
end

if profileEnabled then CallbackTiming.setFailureHandler(fail) end

local function check()
	local remoteFailure = benchmark:GetAttribute("QuickFailure")
	if remoteFailure then fail(remoteFailure) end
	assert(failure == nil, failure)
	for _, state in sides do
		if state.capture then state.capture.check() end
	end
end

local function waitUntil(predicate, timeout: number?)
	local deadline = os.clock() + (timeout or Config.timeoutSeconds)
	repeat
		check()
		if predicate() then return end
		assert(os.clock() < deadline, "quick benchmark timed out")
		RunService.PostSimulation:Wait()
	until false
end

local function quiet()
	local finish = os.clock() + Config.quietSeconds
	waitUntil(function() return os.clock() >= finish end)
end

-- Calibration and real sends use the same timed loop. The no-op floor is
-- reported separately; it is never subtracted from the real measurements.
local function submitFrame(operation, inputs, sent: number): (number, number, number, number)
	local before = os.clock()
	for message = 1, selected.messagesPerFrame do
		sent += 1
		operation(inputs[sent].input, if message == selected.messagesPerFrame
			then "FlushBeforeReturn" else "ContinueFrame")
	end
	local returned = os.clock()
	return (returned - before) / selected.messagesPerFrame, sent, before, returned
end

local function noop(_payload, _boundary) end

local function pace(state: any, inputs: any, captureCpu: boolean?): any
	local operation = if isServer then state.side.broadcast else state.side.submit
	local frameCount = #inputs / selected.messagesPerFrame
	local frames, calls, rtts = table.create(frameCount), table.create(frameCount), table.create(#inputs)
	local floorCalls, floorSent = table.create(frameCount), 0
	for index = 1, frameCount do
		floorCalls[index], floorSent = submitFrame(noop, inputs, floorSent)
	end
	local sent, weightedKbps = 0, 0
	local lastSubmissionReturnedAt = 0
	local _submissionStartedAt
	local deadline = os.clock() + Config.timeoutSeconds
	local cpuReport = nil
	local cpuMarker = ""
	if captureCpu then
		cpuCaptureOrdinal += 1
		cpuMarker = `RelayQuickCPU/{cpuToken}/{cpuCaptureOrdinal}`
		latestCpuReport = nil
		cpu:begin()
	end
	RunService.PostSimulation:Wait()
	check()
	local started = os.clock()
	local previous = started
	if selected.kind == "SeparateProbe" then
		for index = 1, #inputs do
			check()
			assert(os.clock() < deadline, "quick probe timed out")
			local before
			calls[index], sent, before = submitFrame(operation, inputs, sent)
			waitUntil(function() return state.capture.count() >= index end, deadline - os.clock())
			-- A final echo can arrive after expiry before the waiting thread resumes.
			assert(os.clock() < deadline, "quick probe timed out")
			rtts[index] = state.capture.time(index) - before
		end
	elseif captureCpu then
		local index = 0
		local callbackFailure: any = nil
		cpuConnection = RunService.PreSimulation:Connect(function()
			if index >= frameCount or callbackFailure ~= nil then return end
			if os.clock() >= deadline then callbackFailure = "quick CPU workload timed out"; return end
			local ok, sample, nextSent, _before, returned
			debug.profilebegin(cpuMarker)
			ok, sample, nextSent, _before, returned = pcall(submitFrame, operation, inputs, sent)
			debug.profileend()
			if not ok then callbackFailure = sample; return end
			index += 1
			calls[index], sent, lastSubmissionReturnedAt = sample, nextSent, returned
			local now = os.clock()
			frames[index] = now - previous
			weightedKbps += Stats.DataSendKbps * (now - previous)
			previous = now
		end)
		while index < frameCount and callbackFailure == nil do
			check()
			assert(os.clock() < deadline, "quick CPU workload timed out")
			RunService.Heartbeat:Wait()
		end
		cpuConnection:Disconnect(); cpuConnection = nil
		assert(callbackFailure == nil, callbackFailure)
	else
		for index = 1, frameCount do
			check()
			assert(os.clock() < deadline, "quick workload timed out")
			calls[index], sent, _submissionStartedAt, lastSubmissionReturnedAt = submitFrame(operation, inputs, sent)
			RunService.PostSimulation:Wait()
			local now = os.clock()
			frames[index] = now - previous
			weightedKbps += Stats.DataSendKbps * (now - previous)
			previous = now
		end
	end
	local finished = os.clock()
	check()
	if captureCpu then
		-- A diagnostic delay, not a guarantee that profiler records have drained.
		for _ = 1, 4 do RunService.Heartbeat:Wait() end
		cpuReport = cpu:finish(cpuMarker)
		cpuReport.caseId, cpuReport.adapterId = selected.id, state.id
		cpuReport.captureOrdinal = cpuCaptureOrdinal
		latestCpuReport = cpuReport
	end
	return {
		started = started, finished = finished, sent = sent,
		lastSubmissionReturnedAt = lastSubmissionReturnedAt,
		calls = calls, frames = frames, rtt = rtts, floorCalls = floorCalls,
		cpuCapture = cpuReport,
		kbps = if #frames > 0 then weightedKbps / (previous - started) else nil,
	}
end

local function summarize(measurement: any): any
	return {
		elapsed = measurement.finished - measurement.started, sent = measurement.sent,
		calls = Model.summary(measurement.calls), floor = Model.summary(measurement.floorCalls),
		callSamples = measurement.calls, frameSamples = measurement.frames, floorSamples = measurement.floorCalls,
		frames = if #measurement.frames > 0 then Model.summary(measurement.frames) else nil,
		rtt = if #measurement.rtt > 0 then Model.summary(measurement.rtt) else nil,
		kbps = measurement.kbps,
		cpuCapture = measurement.cpuCapture,
		-- Both timestamps are from the sender's clock. Includes acknowledgement
		-- and scheduling overhead, but no quiet interval or full verification.
		deliveryConfirmation = if selected.kind == "Workload" and measurement.cpuCapture == nil
			then measurement.confirmedAt - measurement.started else nil,
		acknowledgementTail = if selected.kind == "Workload" and measurement.cpuCapture == nil
			then measurement.confirmedAt - measurement.lastSubmissionReturnedAt else nil,
	}
end

local function selectCase(caseId: string)
	local config = table.clone(Config)
	config.caseId = caseId
	local nextSelection = Model.selection(config)
	table.clear(selected)
	for key, value in nextSelection do selected[key] = value end
	receives = receiving(selected)
	fieldCount = selected.fieldCount or (if selected.payloadId == "tiny" then 2 else 5)
end

local function initialize()
	assert(RunService:IsStudio(), "quick benchmarks run only in Studio")
	if coreEnabled then
		assert(not profileEnabled, "core category suites do not support receive profiling")
		for _, caseId in coreCaseIds do
			local caseConfig = table.clone(Config)
			caseConfig.caseId = caseId
			local coreSelection = Model.selection(caseConfig)
			assert(coreSelection.direction == "ClientToServer" and coreSelection.messagesPerFrame == 1,
				"core categories require one reliable C2S message per frame")
		end
	end
	if selected.schema and not coreEnabled then
		assert(not profileEnabled or Config.caseId == "schema-composite-c2s",
			"only schema-composite-c2s schema diagnostics support receive profiling")
		assert(#adapterIds == 1 and adapterIds[1] == "relay-reliable",
			"schema diagnostics require exactly one relay-reliable adapter")
	end
	assert(#adapterIds >= 1 and #adapterIds <= 9, "select 1..9 quick adapters")
	if profileEnabled then
		assert(Model.receiveProfileCases[Config.caseId] == true,
			"receive profiling supports only Tiny/State C2S, State S2C, and schema-composite-c2s workloads")
		assert(Config.warmupFrames * selected.messagesPerFrame <= 2400
			and Config.measuredFrames * selected.messagesPerFrame <= 2400,
			"receive profiling phase exceeds the bounded callback sample cap")
		for _, id in adapterIds do
			assert(id == "native-reliable" or id == "relay-reliable",
				"receive profiling supports only native-reliable and relay-reliable")
		end
	end
	if sdkInstance ~= nil then
		assert(not coreEnabled and selected.kind == "Workload" and selected.direction == "ClientToServer",
			"LibMP profiling requires a client-to-server workload")
		cpu = require(script.Parent.CpuProfile).new(require(sdkInstance))
		cpuToken = game:GetService("HttpService"):GenerateGUID(false)
	end
	local seen = {}
	for _, id in adapterIds do
		assert(not seen[id], "duplicate quick adapter")
		seen[id] = true
	end
	if not isServer then
		benchmark:GetAttributeChangedSignal("QuickFailure"):Connect(function()
			local remoteFailure = benchmark:GetAttribute("QuickFailure")
			if remoteFailure then fail(remoteFailure) end
		end)
	end
	if isServer then
		waitUntil(function() return #Players:GetPlayers() > 0 end, 120)
		assert(#Players:GetPlayers() == 1, "quick benchmarks require exactly one client")
		player = Players:GetPlayers()[1]
		Players.PlayerAdded:Connect(function()
			if not closed then fail("quick benchmarks require exactly one client") end
		end)
		Players.PlayerRemoving:Connect(function(departing)
			if departing ~= player or closed then return end
			if completed and failure == nil then
				closed = true
				benchmark:SetAttribute("QuickStatus", "Closed")
				teardown()
			else
				fail("quick benchmark client left")
			end
		end)
	end
	for _, id in adapterIds do
		local name = if id == "native-reliable" then "NativeReliable"
			else if id == "relay-reliable" then "RelayReliable" else id
		local external = name == id
		local root
		if isServer then
			root = if external then game:GetService("ServerStorage").RelayQuickTemplates[id]:Clone()
				else Instance.new("Folder")
			root.Name = id
			if coreEnabled then root:SetAttribute("QuickCore", true) end
			root.Parent = benchmark.QuickTransports
		else
			waitUntil(function() return benchmark.QuickTransports:FindFirstChild(id) ~= nil end, 120)
			root = benchmark.QuickTransports[id]
			if coreEnabled then
				waitUntil(function() return root:GetAttribute("QuickCore") == true end, 120)
			end
		end
		local broadcastMode = nil
		if selected.direction == "ServerToClient" then
			if external and not isServer then
				waitUntil(function()
					local mode = root:GetAttribute("QuickBroadcastMode")
					return mode == "NativeBroadcast" or mode == "AdapterFanOut"
				end, 120)
			end
			broadcastMode = if external then root:GetAttribute("QuickBroadcastMode") else "NativeBroadcast"
			assert(broadcastMode == "NativeBroadcast" or broadcastMode == "AdapterFanOut",
				"quick S2C requires a supported broadcast mode for " .. id)
		end
		local factory = if coreEnabled then require(script.Parent.CoreAdapters)
			else if selected.schema then require(script.Parent.SchemaRelay) else require(benchmark.adapters[name])
		if external then
			assert(Readiness.prewarm(id, root, if isServer then "Server" else "Client", os.clock).kind == "Ready",
				"quick adapter prewarm failed: " .. id)
			check()
			factory = Readiness.wrapFactory(id, factory)
		end
		local state: any = { id = id, broadcastMode = broadcastMode }
		table.insert(sides, state)
		local function receive(delivery, metadata)
			if failure ~= nil then return end
			if coreEnabled and (type(metadata) ~= "table" or metadata.payloadId ~= selected.payloadId) then
				fail("unexpected quick benchmark payload category")
				return
			end
			if not receives or (isServer and metadata.sender ~= player) or state.capture == nil then
				fail("unexpected quick benchmark delivery")
				return
			end
			if not state.capture.push(delivery, os.clock()) then fail("invalid quick benchmark delivery"); return end
			if isServer and selected.kind == "SeparateProbe" then
				-- Echo only a bounded, prebuilt fixture. Verify the received values
				-- after the probe; corruption never produces a successful result.
				local ok, reason = pcall(state.side.broadcast,
					state.inputs[state.capture.count()].input, "FlushBeforeReturn")
				if not ok then fail(reason) end
			end
		end
		local context = {
			resourceRoot = root, selection = selected, recipients = { player }, participantIndex = 1,
			activePayloadId = function() return selected.payloadId end,
			envelopes = envelopes,
			sink = receive,
		}
		state.side = (if isServer then factory.constructServer else factory.constructClient)(context)
		state.side.setup()
		check()
		waitUntil(state.side.ready, 120)
	end
	initialized = true
end

local function serve()
	assert(isServer and not running, "quick server already started or wrong side")
	running = true
	local ok, reason = pcall(function()
		initialize()
		local runIndex, roundIndex, position, phaseIndex = 0, 1, 1, 1
		local currentCaseIndex = 1
		local stage, busy = "Start", false
		local inputs
		local remote = Instance.new("RemoteFunction")
		control = remote
		remote.Name = "QuickControl"
		remote.OnServerInvoke = function(sender, command, ...)
			local receivedAt = os.clock()
			-- Closed sessions cannot restart. A valid late Abort still reports a
			-- genuine client failure; closure never suppresses delivery faults.
			if closed and (sender ~= player or command ~= "Abort" or select("#", ...) ~= 0) then return false end
			-- Abort remains available while a yielding handler is busy. Every wait
			-- checks the terminal latch; no continuation can revive an aborted run.
			if sender ~= player or select("#", ...) ~= 0 or type(command) ~= "string" then
				fail("invalid quick control request"); return false
			end
			if command == "Abort" then fail("quick benchmark aborted"); return false end
			if busy or failure ~= nil or command ~= stage then
				fail("out-of-order quick control request"); return false
			end
			busy = true
			local accepted, response = pcall(function()
				check()
				if command == "Start" then
					completed = false
					runIndex += 1
					currentCaseIndex = 1
					if coreEnabled then selectCase(coreCaseIds[1]) end
					for _, state in sides do state.capture, state.inputs, state.measurement = nil, nil, nil end
					inputs = Model.runBatches(Config, selected, runIndex, #sides)
					roundIndex, position, phaseIndex, stage = 1, 1, 1, "Begin"
					benchmark:SetAttribute("QuickStatus", "Running")
					return runIndex
				end
				if command == "Complete" then
					completed, stage = true, "Start"
					benchmark:SetAttribute("QuickStatus", "Complete")
					return true
				end
				if command == "NextCase" then
					assert(coreEnabled and currentCaseIndex < #coreCaseIds,
						"quick category suite cannot advance to another case")
					for _, state in sides do state.capture, state.inputs, state.measurement = nil, nil, nil end
					currentCaseIndex += 1
					selectCase(coreCaseIds[currentCaseIndex])
					inputs = Model.runBatches(Config, selected, runIndex, #sides)
					roundIndex, position, phaseIndex, stage = 1, 1, 1, "Begin"
					return selected.id
				end
				local state = sides[Model.adapterIndex(#sides, runIndex, roundIndex, position)]
				local batch = inputs[roundIndex][phaseIndex]
				if command == "Begin" then
					state.inputs = batch
					if receives then state.capture = Model.capture(selected.payloadId, batch) end
					if profileEnabled and receives then CallbackTiming.begin(state.id, #batch) end
					stage = "Drain"
					if selected.direction == "ServerToClient" then
						quiet()
						state.measurement = pace(state, batch)
					end
					return true
				end
				if command == "Drain" then
					if receives then waitUntil(function() return state.capture.count() == #batch end) end
					if selected.direction == "ServerToClient" then state.measurement.confirmedAt = receivedAt end
					stage = "Finish"
					return true
				end
				quiet()
				if receives then state.capture.verify() end
				Model.verifyInputs(selected.payloadId, batch)
				check()
				local result = if selected.direction == "ServerToClient" then summarize(state.measurement) else true
				if profileEnabled and receives then
					result = { receiveCallbackSamples = CallbackTiming.finish(state.id) }
				end
				phaseIndex += 1
				if phaseIndex > 2 then position += 1; phaseIndex = 1 end
				if position > #sides then roundIndex += 1; position = 1 end
				stage = if roundIndex > Model.roundCount(#sides)
					then if coreEnabled and currentCaseIndex < #coreCaseIds then "NextCase" else "Complete"
					else "Begin"
				return result
			end)
			if not accepted then fail(response) end
			busy = false
			return if accepted and failure == nil then response else false
		end
		remote.Parent = benchmark
		benchmark:SetAttribute("QuickStatus", "Ready")
	end)
	if not ok then fail(reason) end
end

local function request(command: string): (any, number)
	local done, accepted, response, returnedAt = false, false, nil, 0
	local worker = task.spawn(function()
		accepted, response = pcall(function() return control:InvokeServer(command) end)
		returnedAt = os.clock()
		done = true
	end)
	local ok, reason = pcall(waitUntil, function() return done end,
		Config.timeoutSeconds + Config.quietSeconds + 5)
	if not ok then pcall(task.cancel, worker); error(reason, 0) end
	check()
	assert(accepted and response ~= false, "quick control request failed: " .. command)
	return response, returnedAt
end

local function range(stats: any, scale: number): string
	return string.format("%.2f [%.2f..%.2f]", stats.median * scale, stats.min * scale, stats.max * scale)
end

local function report(id: string, rounds: { any }, caseId: string): any
	local result = { adapterId = id, caseId = caseId, rankingEligible = false,
		profile = if cpu then "receive-callback+libmp-cpu" elseif profileEnabled then "receive-callback" else "unprofiled",
		rounds = rounds, summary = Model.aggregate(rounds), sent = 0 }
	for _, round in rounds do result.sent += round.sent end
	-- Shared across reruns so a later terminal failure also invalidates rows
	-- already returned to callers, without retaining their result arrays here.
	result.validity = validity
	local stats = result.summary
	local message = string.format("[Relay quick] %s | %s | profile=%s | verified %d/%d over %d rounds | median [min..max]:",
		id, caseId, result.profile, result.sent, result.sent, #rounds)
	message ..= " offered " .. range(stats.offeredRate, 1) .. " msg/s"
	message ..= " | public call mean " .. range(stats.callMean, 1e6) .. " us"
	message ..= " | public call median " .. range(stats.callMedian, 1e6) .. " us"
	message ..= " | public call p95 " .. range(stats.callP95, 1e6) .. " us"
	message ..= " | no-op floor avg " .. range(stats.floor, 1e6) .. " us"
	if stats.deliveryConfirmation then
		message ..= " | delivery confirmation " .. range(stats.deliveryConfirmation, 1000) .. " ms"
	end
	if stats.acknowledgementTail then
		message ..= " | acknowledgement tail " .. range(stats.acknowledgementTail, 1000) .. " ms"
	end
	if stats.frameMean then
		message ..= " | sender FPS " .. range(stats.fps, 1)
		message ..= " | frame avg " .. range(stats.frameMean, 1000) .. " ms"
		message ..= " | frame p95 " .. range(stats.frameP95, 1000) .. " ms"
		message ..= " | engine send " .. range(stats.kbps, 1) .. " KB/s"
	end
	if stats.rttMean then
		message ..= " | RTT avg " .. range(stats.rttMean, 1000) .. " ms"
		message ..= " | RTT p95 " .. range(stats.rttP95, 1000) .. " ms"
	end
	if stats.receiveCallbacks then
		message ..= " | receive callback mean " .. range(stats.receiveCallbackMean, 1e6) .. " us"
		message ..= " | receive callback median " .. range(stats.receiveCallbackMedian, 1e6) .. " us"
		message ..= " | receive callback p95 " .. range(stats.receiveCallbackP95, 1e6) .. " us"
	end
	print(message)
	return result
end

local function run(): any
	assert(not isServer, "run quick benchmarks from the client Command Bar")
	assert(not running, "a quick benchmark is already running")
	assert(benchmark:GetAttribute("QuickStatus") ~= "Closed", "quick benchmark session is closed; Stop/Play to retry")
	running = true
	local ok, result = pcall(function()
		check()
		if not initialized then initialize() end
		waitUntil(function() return benchmark:FindFirstChild("QuickControl") ~= nil end, 120)
		control = benchmark.QuickControl
		if coreEnabled then
			selectCase(coreCaseIds[1])
			for _, state in sides do state.capture, state.inputs, state.measurement = nil, nil, nil end
		end
		local runIndex = request("Start")
		local results, measurementsByCase = {}, {}
		print("[Relay quick] Iteration diagnostics; one shared Studio session, one client. Run " .. runIndex)
		for selectedCaseIndex, caseId in coreCaseIds do
			if coreEnabled and selectedCaseIndex > 1 then
				local serverCase = request("NextCase")
				for _, state in sides do state.capture, state.inputs, state.measurement = nil, nil, nil end
				selectCase(caseId)
				assert(serverCase == selected.id, "quick category transition did not match the declared suite")
			end
			local batches = Model.runBatches(Config, selected, runIndex, #sides)
			local measurements = table.create(#sides)
			for index = 1, #sides do measurements[index] = {} end
			for round, phases in batches do
				print(string.format("[Relay quick] %s | round %d/%d; first adapter: %s", caseId, round, #batches,
					sides[Model.adapterIndex(#sides, runIndex, round, 1)].id))
				for position = 1, #sides do
					local index = Model.adapterIndex(#sides, runIndex, round, position)
					local state, measured = sides[index], nil
					for phase, batch in phases do
						if receives then state.capture = Model.capture(selected.payloadId, batch) end
						if profileEnabled and receives then CallbackTiming.begin(state.id, #batch) end
						request("Begin")
						local measurement
						if selected.direction ~= "ServerToClient" then
							quiet()
							measurement = pace(state, batch, cpu ~= nil and phase == 2)
						end
						if receives then waitUntil(function() return state.capture.count() == #batch end) end
						local _, confirmedAt = request("Drain")
						if measurement then measurement.confirmedAt = confirmedAt end
						local response = request("Finish")
						if receives then state.capture.verify() end
						Model.verifyInputs(selected.payloadId, batch)
						local receiveSamples
						if profileEnabled then
							if receives then
								receiveSamples = CallbackTiming.finish(state.id)
							else
								assert(type(response) == "table", "missing server receive profile")
								receiveSamples = response.receiveCallbackSamples
							end
							assert(type(receiveSamples) == "table" and #receiveSamples == #batch,
								"receive profile sample count mismatch")
							local count = 0
							for key in receiveSamples do
								count += 1
								assert(count <= #batch and type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #batch,
									"invalid receive profile sample array")
							end
							assert(count == #batch, "receive profile sample count mismatch")
						end
						local receiveCallbacks = if receiveSamples then Model.summary(receiveSamples) else nil
						if phase == 2 then
							measured = if measurement then summarize(measurement) else response
							if receiveCallbacks then
								measured.receiveCallbacks = receiveCallbacks
								measured.receiveCallbackSamples = receiveSamples
							end
						end
					end
					table.insert(measurements[index], measured)
				end
			end
			measurementsByCase[selectedCaseIndex] = measurements
		end
		check()
		-- The server can treat departure as normal closure only after the client
		-- has also verified every round. This acknowledgement is outside timing.
		request("Complete")
		for selectedCaseIndex, caseId in coreCaseIds do
			selectCase(caseId)
			local categoryResults, summaryBroadcastModes = {}, if selected.direction == "ServerToClient" then {} else nil
			for index, state in sides do
				local result = report(state.id, measurementsByCase[selectedCaseIndex][index], caseId)
				table.insert(results, result)
				table.insert(categoryResults, result)
				if summaryBroadcastModes ~= nil then summaryBroadcastModes[state.id] = state.broadcastMode end
			end
			print("[Relay quick] Payload category: " .. Model.category(caseId) .. " (" .. caseId .. ")")
			print(Model.renderSummary(categoryResults, summaryBroadcastModes))
		end
		print("[Relay quick] Complete. Rerun: require(game.ReplicatedStorage.RelayBenchmark.Quick.Session).run()")
		return results
	end)
	running = false
	if not ok then
		fail(result)
		error("[Relay quick] FAILED; Stop/Play to retry: " .. tostring(result), 0)
	end
	return result
end

return table.freeze({ serve = serve, run = run,
	getCpuSnapshot = function() return if cpu then cpu:latestSnapshot() else nil end,
	getCpuReport = function() return latestCpuReport end,
})
