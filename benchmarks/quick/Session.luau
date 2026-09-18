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

local selected = Model.selection(Config)
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
local receives = selected.kind == "SeparateProbe"
	or selected.direction == (if isServer then "ClientToServer" else "ServerToClient")
local fieldCount = if selected.payloadId == "tiny" then 2 else 5
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
	teardown()
	if not isServer then
		local remote = control or benchmark:FindFirstChild("QuickControl")
		if remote then task.spawn(function() pcall(function() remote:InvokeServer("Abort") end) end) end
	end
end

if profileEnabled and not isServer then CallbackTiming.setFailureHandler(fail) end

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

local function pace(state: any, inputs: any): any
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
	return {
		started = started, finished = finished, sent = sent,
		lastSubmissionReturnedAt = lastSubmissionReturnedAt,
		calls = calls, frames = frames, rtt = rtts, floorCalls = floorCalls,
		kbps = if #frames > 0 then weightedKbps / (previous - started) else nil,
	}
end

local function summarize(measurement: any): any
	return {
		elapsed = measurement.finished - measurement.started, sent = measurement.sent,
		calls = Model.summary(measurement.calls), floor = Model.summary(measurement.floorCalls),
		frames = if #measurement.frames > 0 then Model.summary(measurement.frames) else nil,
		rtt = if #measurement.rtt > 0 then Model.summary(measurement.rtt) else nil,
		kbps = measurement.kbps,
		-- Both timestamps are from the sender's clock. Includes acknowledgement
		-- and scheduling overhead, but no quiet interval or full verification.
		deliveryConfirmation = if selected.kind == "Workload"
			then measurement.confirmedAt - measurement.started else nil,
		acknowledgementTail = if selected.kind == "Workload"
			then measurement.confirmedAt - measurement.lastSubmissionReturnedAt else nil,
	}
end

local function initialize()
	assert(RunService:IsStudio(), "quick benchmarks run only in Studio")
	if not isServer then
		benchmark:GetAttributeChangedSignal("QuickFailure"):Connect(function()
			local remoteFailure = benchmark:GetAttribute("QuickFailure")
			if remoteFailure then fail(remoteFailure) end
		end)
	end
	assert(#adapterIds >= 1 and #adapterIds <= 9, "select 1..9 quick adapters")
	if profileEnabled then
		assert(selected.kind == "Workload" and selected.payloadId == "state"
			and selected.direction == "ServerToClient"
			and (Config.caseId == "state-broadcast-s2c" or Config.caseId == "state-broadcast-burst-s2c"),
			"receive profiling supports only State S2C quick workloads")
		assert(Config.warmupFrames * selected.messagesPerFrame <= 2400
			and Config.measuredFrames * selected.messagesPerFrame <= 2400,
			"receive profiling phase exceeds the bounded callback sample cap")
		for _, id in adapterIds do
			assert(id == "native-reliable" or id == "relay-reliable",
				"receive profiling supports only native-reliable and relay-reliable")
		end
	end
	local seen = {}
	for _, id in adapterIds do
		assert(not seen[id], "duplicate quick adapter")
		seen[id] = true
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
			root.Parent = benchmark.QuickTransports
		else
			waitUntil(function() return benchmark.QuickTransports:FindFirstChild(id) ~= nil end, 120)
			root = benchmark.QuickTransports[id]
		end
		local factory = require(benchmark.adapters[name])
		if external then
			assert(Readiness.prewarm(id, root, if isServer then "Server" else "Client", os.clock).kind == "Ready",
				"quick adapter prewarm failed: " .. id)
			check()
			factory = Readiness.wrapFactory(id, factory)
		end
		local state: any = { id = id }
		table.insert(sides, state)
		local function receive(delivery, metadata)
			if failure ~= nil then return end
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
					inputs = Model.runBatches(Config, selected, runIndex)
					roundIndex, position, phaseIndex, stage = 1, 1, 1, "Begin"
					benchmark:SetAttribute("QuickStatus", "Running")
					return runIndex
				end
				if command == "Complete" then
					completed, stage = true, "Start"
					benchmark:SetAttribute("QuickStatus", "Complete")
					return true
				end
				local state = sides[Model.adapterIndex(#sides, runIndex, roundIndex, position)]
				local batch = inputs[roundIndex][phaseIndex]
				if command == "Begin" then
					state.inputs = batch
					if receives then state.capture = Model.capture(selected.payloadId, batch) end
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
				phaseIndex += 1
				if phaseIndex > 2 then position += 1; phaseIndex = 1 end
				if position > #sides then roundIndex += 1; position = 1 end
				stage = if roundIndex > Model.roundCount then "Complete" else "Begin"
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

local function report(id: string, rounds: { any }): any
	local result = { adapterId = id, caseId = Config.caseId, rankingEligible = false,
		profile = if profileEnabled then "receive-callback" else "unprofiled",
		rounds = rounds, summary = Model.aggregate(rounds), sent = 0 }
	for _, round in rounds do result.sent += round.sent end
	-- Shared across reruns so a later terminal failure also invalidates rows
	-- already returned to callers, without retaining their result arrays here.
	result.validity = validity
	local stats = result.summary
	local message = string.format("[Relay quick] %s | %s | profile=%s | verified %d/%d over %d rounds | median [min..max]:",
		id, Config.caseId, result.profile, result.sent, result.sent, #rounds)
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
		local runIndex = request("Start")
		local batches = Model.runBatches(Config, selected, runIndex)
		local results, measurements = {}, {}
		for index = 1, #sides do measurements[index] = {} end
		print("[Relay quick] Iteration diagnostics; one shared Studio session, one client. Run " .. runIndex)
		for round, phases in batches do
			print(string.format("[Relay quick] Round %d/%d; first adapter: %s", round, Model.roundCount,
				sides[Model.adapterIndex(#sides, runIndex, round, 1)].id))
			for position = 1, #sides do
				local index = Model.adapterIndex(#sides, runIndex, round, position)
				local state, measured = sides[index], nil
				for phase, batch in phases do
					if receives then state.capture = Model.capture(selected.payloadId, batch) end
					if profileEnabled then CallbackTiming.begin(state.id, #batch) end
					request("Begin")
					local measurement
					if selected.direction ~= "ServerToClient" then
						quiet()
						measurement = pace(state, batch)
					end
					if receives then waitUntil(function() return state.capture.count() == #batch end) end
					local _, confirmedAt = request("Drain")
					if measurement then measurement.confirmedAt = confirmedAt end
					local response = request("Finish")
					if receives then state.capture.verify() end
					Model.verifyInputs(selected.payloadId, batch)
					local receiveCallbacks = if profileEnabled then CallbackTiming.finish(state.id) else nil
					if phase == 2 then
						measured = if measurement then summarize(measurement) else response
						if receiveCallbacks then
							measured.receiveCallbacks = Model.summary(receiveCallbacks)
							measured.receiveCallbackSamples = receiveCallbacks
						end
					end
				end
				table.insert(measurements[index], measured)
			end
		end
		check()
		-- The server can treat departure as normal closure only after the client
		-- has also verified every round. This acknowledgement is outside timing.
		request("Complete")
		for index, state in sides do table.insert(results, report(state.id, measurements[index])) end
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

return table.freeze({ serve = serve, run = run })
