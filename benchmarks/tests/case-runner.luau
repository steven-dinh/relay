local AdapterContract = require("../adapters/AdapterContract")
local CaseRunner = require("../runner/CaseRunner")
local EventV1 = require("../contracts/event-v1")
local KernelFanout = require("../runner/KernelFanout")
local SessionOwner = require("../runner/SessionOwner")
local FakeAdapter = require("./support/FakeAdapter")

local STUDIO_VERSION = "0.650.0.6500000"
local RUN_ID = "00112233-4455-6677-8899-aabbccddeeff"

local function assertExactKeys(value, keys, label)
	assert(type(value) == "table", `{label} must be a table`)
	local expected = {}
	for _, key in keys do
		expected[key] = true
	end
	local count = 0
	for key in next, value do
		count += 1
		assert(expected[key] == true, `{label} has unexpected key {tostring(key)}`)
	end
	assert(count == #keys, `{label} must have exactly {#keys} keys`)
end

local function assertStateError(callback, label)
	local ok, detail = pcall(callback)
	assert(not ok and tostring(detail) == "CASE_RUNNER_E_STATE", `{label} must raise state sentinel`)
end

local function hasFailure(result, code)
	for _, failure in result.failures do
		if failure.code == code then
			return true
		end
	end
	return false
end

local function failureCodes(result)
	local codes = table.create(#result.failures)
	for index, failure in result.failures do
		codes[index] = failure.code
	end
	return table.concat(codes, ",")
end

local function failureOccurrences(result, code)
	local occurrences = 0
	for _, failure in result.failures do
		if failure.code == code then
			occurrences += failure.occurrences
		end
	end
	return occurrences
end

local function assertSingleExecutionInvariant(facts, label)
	assert(#facts == 1, `{label} must record exactly one invariant fact`)
	local fact = facts[1]
	assert(fact.code == "InternalError" and fact.occurrences == 1, `{label} invariant fact differs`)
	assert(fact.discriminator.kind == "Stage" and fact.discriminator.value == "Execution",
		`{label} invariant discriminator differs`)
end

local function repositoryIdentity()
	return {
		id = "repo-adapter",
		displayName = "Repository Adapter",
		lane = "EquivalentSemantics",
		integrationKind = "Runtime",
		library = {
			id = "repo-library",
			displayName = "Repository Library",
			version = "1.2.3",
			provenance = {
				kind = "Repository",
				sourceRepository = "https://example.com/relay-adapter",
				revision = string.rep("d", 40),
				checksum = "sha256:" .. string.rep("e", 64),
				license = "MIT",
			},
		},
		semantics = {
			broadcastMode = "NativeBroadcast",
			intentionalAddedDeliveryFrames = 0,
			repetitionIsolation = "SessionRestart",
		},
		capabilities = {
			directions = { "ClientToServer", "ServerToClient" },
			deliverySemantics = { "ReliableOrdered" },
			payloadIds = { "state", "tiny" },
		},
	}
end

local function manifest(identity, selection)
	return {
		version = 1,
		launchId = RUN_ID,
		benchmarkSource = {
			revision = string.rep("a", 40),
			dirty = false,
			placeFingerprint = "sha256:" .. string.rep("c", 64),
		},
		contractFingerprint = "sha256:" .. string.rep("b", 64),
		adapter = {
			moduleId = "repo-adapter-module",
			artifact = {
				kind = "RepositoryModule",
				digest = identity.library.provenance.checksum,
			},
			identity = identity,
		},
		selection = selection,
		environment = {
			studio = {
				version = STUDIO_VERSION,
				channel = "production",
			},
			host = {
				osFamily = "Windows",
				architecture = "x86_64",
				osVersion = "11",
				cpuModel = "Test CPU",
				logicalProcessorCount = 8,
				memoryMiB = 16_384,
				gpuModel = "Test GPU",
			},
		},
	}
end

local function newFrameSystem()
	local frame = 0
	local sharedValue = 0
	local subscribers = {}
	local function connect(callback)
		local record = { active = true, callback = callback }
		table.insert(subscribers, record)
		return function()
			record.active = false
		end
	end
	local scheduler = {
		currentFrame = function()
			return frame
		end,
		connectPostSimulation = function(callback)
			connect(callback)
			return {}
		end,
	}
	local driver = {
		step = function()
			frame += 1
			local count = #subscribers
			for index = 1, count do
				local record = subscribers[index]
				if record.active then
					record.callback()
				end
			end
		end,
		frame = function()
			return frame
		end,
		sharedNow = function()
			sharedValue += 0.000_001
			return sharedValue
		end,
	}
	return scheduler, driver, connect
end

local function newProcess(connect, frameDriver, offset, measurementOrder, timeoutState)
	local localValue = offset
	local currentProducer = nil
	connect(function()
		if currentProducer ~= nil then
			currentProducer()
		end
	end)
	local source = {
		connectPostSimulation = function(callback)
			assert(currentProducer == nil, "process multiplexer accepts one generation producer")
			currentProducer = callback
			return function()
				currentProducer = nil
			end
		end,
	}
	local clocks = {
		localNowSeconds = function()
			if measurementOrder ~= nil then
				local operationThread = measurementOrder.operationThread
				local operationStatus = if operationThread == nil then "none" else coroutine.status(operationThread)
				table.insert(measurementOrder, `RawLocalClockRead/{operationStatus}`)
			end
			localValue += 0.000_001
			return localValue
		end,
		sharedNowSeconds = function()
			if measurementOrder ~= nil then
				local operationThread = measurementOrder.operationThread
				local operationStatus = if operationThread == nil then "none" else coroutine.status(operationThread)
				table.insert(measurementOrder, `RawSharedClockRead/{operationStatus}`)
			end
			return frameDriver.sharedNow()
		end,
		timeoutNowSeconds = function()
			return frameDriver.frame() / 60 + timeoutState.offset
		end,
	}
	return { clocks = clocks, postSimulation = source }
end

local function buildRig(options)
	options = options or {}
	local scheduler, driver, connect = newFrameSystem()
	local timeoutState = { offset = 0 }
	-- Install case-lifetime participant multiplexers before FakeAdapter is
	-- allowed to attach its persistent tail drain during setup.
	local serverProcess = newProcess(connect, driver, 0, options.measurementOrder, timeoutState)
	local identity = repositoryIdentity()
	local selection = options.selection or {
		kind = "Workload",
		workloadId = "tiny-steady-c2s",
		recipientCount = 1,
	}
	local supported = AdapterContract.preflight(identity, selection, STUDIO_VERSION)
	assert(supported.kind == "Supported", "valid CaseRunner selection must preflight")
	local clientProcesses = {}
	local clients = {}
	local clientTokens = {}
	for index = 1, supported.selection.clientProcessCount do
		local process = newProcess(connect, driver, index, options.measurementOrder, timeoutState)
		clientProcesses[index] = process
		clients[index] = process
		clientTokens[index] = index
	end
	if options.clientLocalClockFailure == "Missing" then
		clientProcesses[1].clocks.localNowSeconds = function() end
	elseif options.clientLocalClockFailure == "Yield" then
		clientProcesses[1].clocks.localNowSeconds = function()
			coroutine.yield()
			return 0
		end
	elseif options.clientLocalClockFailure == "Extra" then
		clientProcesses[1].clocks.localNowSeconds = function()
			return 0, 1
		end
	end
	local preparedResult = SessionOwner.prepare(manifest(identity, selection), identity, {
		server = {
			clocks = serverProcess.clocks,
			postSimulation = serverProcess.postSimulation,
			clientTokens = clientTokens,
		},
		clients = clients,
	})
	assert(preparedResult.kind == "Prepared", "valid CaseRunner rig must prepare")

	local adapter, control = FakeAdapter.newTestRig(scheduler)
	control:loadFaultScript(options.faults or {})
	if options.measurementOrder ~= nil then
		local base = adapter
		local function wrapSide(side)
			local wrapped = {}
			for key, value in next, side do
				wrapped[key] = value
			end
			for _, operationName in { "submit", "broadcast" } do
				local rawOperation = rawget(side, operationName)
				if type(rawOperation) == "function" then
					wrapped[operationName] = function(payload, boundary)
						options.measurementOrder.operationThread = coroutine.running()
						table.insert(options.measurementOrder, `RawAdapter{operationName}/{boundary}`)
						return rawOperation(payload, boundary)
					end
				end
			end
			table.freeze(wrapped)
			return wrapped
		end
		adapter = {
			constructServer = function(context)
				return wrapSide(base.constructServer(context))
			end,
			constructClient = function(context)
				return wrapSide(base.constructClient(context))
			end,
		}
	end
	if options.mutateClientSubmitAt ~= nil or options.mutateServerBroadcastAt ~= nil then
		local base = adapter
		local clientSubmitCount = 0
		local serverBroadcastCount = 0
		adapter = {
			constructServer = function(context)
				local side = base.constructServer(context)
				if options.mutateServerBroadcastAt == nil then return side end
				local wrapped = {}
				for key, value in next, side do wrapped[key] = value end
				local rawBroadcast = side.broadcast
				wrapped.broadcast = function(payload, boundary)
					serverBroadcastCount += 1
					local results = table.pack(rawBroadcast(payload, boundary))
					if serverBroadcastCount == options.mutateServerBroadcastAt then
						payload.enabled = not payload.enabled
					end
					return table.unpack(results, 1, results.n)
				end
				table.freeze(wrapped)
				return wrapped
			end,
			constructClient = function(context)
				local side = base.constructClient(context)
				if options.mutateClientSubmitAt == nil then return side end
				local wrapped = {}
				for key, value in next, side do wrapped[key] = value end
				local rawSubmit = side.submit
				wrapped.submit = function(payload, boundary)
					clientSubmitCount += 1
					local results = table.pack(rawSubmit(payload, boundary))
					if clientSubmitCount == options.mutateClientSubmitAt then
						payload.enabled = not payload.enabled
					end
					return table.unpack(results, 1, results.n)
				end
				table.freeze(wrapped)
				return wrapped
			end,
		}
	end
	local rawSubmitCount = 0
	if options.senderOnlyIngressOnFirstSubmit then
		local base = adapter
		adapter = {
			constructServer = base.constructServer,
			constructClient = function(context)
				local side = base.constructClient(context)
				local wrapped = {}
				for key, value in next, side do
					wrapped[key] = value
				end
				local rawSubmit = side.submit
				wrapped.submit = function(payload, boundary)
					rawSubmitCount += 1
					if rawSubmitCount == 1 then
						context.sink()
					end
					return rawSubmit(payload, boundary)
				end
				table.freeze(wrapped)
				return wrapped
			end,
		}
	end
	local timeoutJumped = false
	if options.timeoutJumpAfterC2SSubmitCount ~= nil then
		local base = adapter
		local timedSubmitCount = 0
		adapter = {
			constructServer = base.constructServer,
			constructClient = function(context)
				local side = base.constructClient(context)
				local wrapped = {}
				for key, value in next, side do
					wrapped[key] = value
				end
				local rawSubmit = side.submit
				wrapped.submit = function(payload, boundary)
					timedSubmitCount += 1
					local result = table.pack(rawSubmit(payload, boundary))
					if timedSubmitCount == options.timeoutJumpAfterC2SSubmitCount then
						timeoutState.offset = 1_000
						timeoutJumped = true
					end
					return table.unpack(result, 1, result.n)
				end
				table.freeze(wrapped)
				return wrapped
			end,
		}
	end
	local constructorStaleTeardownCalls = 0
	if options.constructorStaleDuringNextClient then
		local base = adapter
		local previousClientSink = nil
		local function countTeardown(side)
			local wrapped = {}
			for key, value in next, side do
				wrapped[key] = value
			end
			local rawTeardown = side.teardown
			wrapped.teardown = function()
				constructorStaleTeardownCalls += 1
				return rawTeardown()
			end
			table.freeze(wrapped)
			return wrapped
		end
		adapter = {
			constructServer = function(context)
				return countTeardown(base.constructServer(context))
			end,
			constructClient = function(context)
				if previousClientSink ~= nil then
					previousClientSink()
				end
				previousClientSink = context.sink
				return countTeardown(base.constructClient(context))
			end,
		}
	end
	local teardownResumed = false
	if options.rawTeardownBehavior ~= nil then
		local base = adapter
		local function constructClient(context)
			local side = base.constructClient(context)
			local wrapped = {}
			for key, value in next, side do
				wrapped[key] = value
			end
			local originalTeardown = side.teardown
			wrapped.teardown = function()
				if options.rawTeardownBehavior == "Yield" then
					coroutine.yield()
					teardownResumed = true
					return
				end
				originalTeardown()
				return "extra"
			end
			table.freeze(wrapped)
			return wrapped
		end
		adapter = {
			constructServer = base.constructServer,
			constructClient = constructClient,
		}
	end
	local sharedStateDirty = false
	if options.sharedStateLeak then
		local base = adapter
		adapter = {
			constructServer = function(context)
				sharedStateDirty = true
				return base.constructServer(context)
			end,
			constructClient = base.constructClient,
		}
	end
	local rootCalls = 0
	local destroyCalls = 0
	local rootFactory = function()
		rootCalls += 1
		if options.rootFactoryFails then
			error("hostile root detail", 0)
		end
		return {
			resourceRoot = { generation = rootCalls },
			destroy = function()
				destroyCalls += 1
				if options.rootDestroyFails then
					error("hostile destroy detail", 0)
				end
			end,
		}
	end
	local runner = CaseRunner.new(preparedResult.value, adapter, rootFactory, RUN_ID)
	return {
		runner = runner,
		control = control,
		driver = driver,
		rootCalls = function()
			return rootCalls
		end,
		destroyCalls = function()
			return destroyCalls
		end,
		teardownResumed = function()
			return teardownResumed
		end,
		rawSubmitCount = function()
			return rawSubmitCount
		end,
		timeoutJumped = function()
			return timeoutJumped
		end,
		constructorStaleTeardownCalls = function()
			return constructorStaleTeardownCalls
		end,
		resetClean = function()
			return not sharedStateDirty
		end,
	}
end

local function drive(rig, rejectResetAt, verifyReset)
	local immediateBudget = 100_000
	while immediateBudget > 0 do
		immediateBudget -= 1
		local result = rig.runner.step()
		assert(table.isfrozen(result), "every CaseRunner step result must be frozen")
		if result.kind == "Continue" then
			continue
		elseif result.kind == "NeedsFrame" then
			assertStateError(rig.runner.step, "step while frame pending")
			rig.driver.step()
			result = rig.runner.resumeAfterFrame()
			if result.kind == "Result" or result.kind == "Terminated" then
				assertStateError(rig.runner.step, "step after frame terminal")
				return result
			elseif result.kind == "GenerationClosed" then
				rig.control:assertConsumed()
				if rejectResetAt == result.repetitionIndex or (verifyReset ~= nil and not verifyReset()) then
					assert(rig.runner.rejectGenerationReset().kind == "Continue", "reset rejection must continue")
				else
					rig.control:reset()
					assert(rig.runner.confirmGenerationReset().kind == "Continue", "reset confirmation must continue")
					rig.control:loadFaultScript({})
				end
				continue
			end
			assert(result.kind == "Continue", `frame resume must return Continue, got {tostring(result.kind)}`)
			assertStateError(rig.runner.resumeAfterFrame, "second frame resume")
		elseif result.kind == "GenerationClosed" then
			assertExactKeys(result, { "kind", "repetitionIndex" }, "generation barrier")
			assertStateError(rig.runner.step, "step while reset pending")
			rig.control:assertConsumed()
			if rejectResetAt == result.repetitionIndex or (verifyReset ~= nil and not verifyReset()) then
				local rejected = rig.runner.rejectGenerationReset()
				assert(rejected.kind == "Continue", "reset rejection must continue toward finalization")
			else
				rig.control:reset()
				local confirmed = rig.runner.confirmGenerationReset()
				assert(confirmed.kind == "Continue", "reset confirmation must continue")
				rig.control:loadFaultScript({})
			end
		elseif result.kind == "Result" or result.kind == "Terminated" then
			assertStateError(rig.runner.step, "step after terminal")
			return result
		else
			error(`unexpected runner arm {tostring(result.kind)}`)
		end
	end
	error("CaseRunner immediate budget exhausted")
end

-- The internal fanout seam proves multiple trusted-kernel call defects fold to
-- one bounded runner invariant instead of one fact per participant.
do
	assertExactKeys(KernelFanout, { "abortAllKernels", "commandAll" }, "KernelFanout")
	assert(table.isfrozen(KernelFanout), "KernelFanout must be frozen")
	local facts = {}
	local terminations = {}
	local preparedStatus = { kind = "State", phase = "Prepared", quietFrames = 0 }
	local clean = KernelFanout.commandAll({
		{
			status = function()
				return preparedStatus
			end,
			command = function()
				coroutine.yield()
			end,
		},
		{
			status = function()
				return preparedStatus
			end,
			command = function()
				return preparedStatus, "extra"
			end,
		},
	}, { kind = "BeginWarmup" }, function(fact)
		table.insert(facts, fact)
	end, function(termination)
		table.insert(terminations, termination)
	end)
	assert(not clean and #terminations == 0, "malformed command fanout must be nonterminal dirty")
	assertSingleExecutionInvariant(facts, "malformed command fanout")
end

do
	local facts = {}
	local terminations = {}
	local clean = KernelFanout.abortAllKernels({
		{
			status = function()
				coroutine.yield()
			end,
			command = function()
				error("unreachable")
			end,
		},
		{
			status = function()
				return { kind = "State", phase = "Prepared", quietFrames = 0 }, "extra"
			end,
			command = function()
				error("unreachable")
			end,
		},
	}, function(fact)
		table.insert(facts, fact)
	end, function(termination)
		table.insert(terminations, termination)
	end)
	assert(not clean and #terminations == 0, "malformed abort status fanout must be nonterminal dirty")
	assertSingleExecutionInvariant(facts, "malformed abort status fanout")
end

assertExactKeys(CaseRunner, { "new" }, "CaseRunner")
assert(type(CaseRunner.new) == "function" and table.isfrozen(CaseRunner), "CaseRunner public surface differs")

-- The private prepared-session brand is the first guard; an unbranded hostile
-- lookalike cannot trigger reads or any supplied construction callback.
do
	local reads = 0
	local calls = 0
	local hostile = setmetatable({}, {
		__index = function()
			reads += 1
			error("hostile prepared read", 0)
		end,
	})
	local ok, detail = pcall(CaseRunner.new, hostile, {
		constructServer = function()
			calls += 1
		end,
		constructClient = function()
			calls += 1
		end,
	}, function()
		calls += 1
	end, "INVALID")
	assert(not ok and detail == "SESSION_OWNER_E_PREPARED", "prepared brand must be the first guard")
	assert(reads == 0 and calls == 0, "unbranded input must be rejected without reads or construction")
end

-- The unchanged production fake completes every approved workload topology and
-- probe. CaseRunner never advances the source itself and requires one explicit
-- reset barrier between generations.
	do
	local selections = {}
	for _, probe in EventV1.probes do
		table.insert(selections, {
			label = probe.id,
			value = { kind = "SeparateProbe", probeId = probe.id },
		})
	end
	for _, workload in EventV1.workloads do
		local recipientCounts = if workload.audience == "Broadcast" then { 1, 4, 8 } else { 1 }
		for _, recipientCount in recipientCounts do
			table.insert(selections, {
				label = `{workload.id}/{recipientCount}`,
				value = {
					kind = "Workload",
					workloadId = workload.id,
					recipientCount = recipientCount,
				},
			})
		end
	end
	for selectionIndex, entry in selections do
		local rig = buildRig({ selection = entry.value })
		if selectionIndex == 1 then
			assertExactKeys(rig.runner, { "step", "resumeAfterFrame", "confirmGenerationReset", "rejectGenerationReset" }, "Runner")
			assert(table.isfrozen(rig.runner), "Runner must be frozen")
			assertStateError(rig.runner.resumeAfterFrame, "resume before frame")
			assertStateError(rig.runner.confirmGenerationReset, "confirm before reset")
			assertStateError(rig.runner.rejectGenerationReset, "reject before reset")
		end
		local result = drive(rig)
		if result.kind == "Terminated" then
			error(`clean {entry.label} run terminated {result.termination.code}/{result.termination.stage} roots={rig.rootCalls()} frame={rig.driver.frame()}`)
		end
		assertExactKeys(result, { "kind", "value" }, `{entry.label} clean result arm`)
		assert(result.kind == "Result" and result.value.status == "Valid", `{entry.label} clean run must be Valid`)
		assert(result.value.runId == RUN_ID, `{entry.label} must retain the configured run ID`)
		assert(result.value.case.startedRepetitions == result.value.case.scheduledRepetitions,
			`{entry.label} must start every repetition`)
		assert(result.value.case.completedRepetitions == result.value.case.scheduledRepetitions,
			`{entry.label} must complete every repetition`)
		assert(rig.rootCalls() == result.value.case.scheduledRepetitions,
			`{entry.label} must open one root per repetition`)
		assert(rig.destroyCalls() == rig.rootCalls(), `{entry.label} must close every root exactly once`)
	end
end

-- Each measured wrapped adapter operation is bracketed by the two raw local
-- reads, for both submit and broadcast, and retains its frame-flush boundary.
for _, entry in {
	{
		label = "submit",
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		rawOperation = "RawAdaptersubmit",
	},
	{
		label = "broadcast",
		selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 1 },
		rawOperation = "RawAdapterbroadcast",
	},
} do
	local measurementOrder = {}
	local rig = buildRig({ selection = entry.selection, measurementOrder = measurementOrder })
	local result = drive(rig, 1)
	assert(result.kind == "Result" and result.value.case.completedRepetitions == 1,
		`{entry.label} timing-order run must complete its measured repetition`)
	local workload
	for _, candidate in EventV1.workloads do
		if candidate.id == entry.selection.workloadId then
			workload = candidate
			break
		end
	end
	assert(workload ~= nil, `{entry.label} timing-order workload missing`)
	local warmupOperations = workload.warmupFrames * workload.senderCount * workload.messagesPerFrame
	local operationIndex = 0
	local measuredOperations = 0
	local firstMeasuredOperationIndex = nil
	local finalMeasuredOperationIndex = nil
	for index = 1, #measurementOrder do
		local event = measurementOrder[index]
		if string.sub(event, 1, #entry.rawOperation) == entry.rawOperation then
			operationIndex += 1
			if operationIndex > warmupOperations then
				measuredOperations += 1
				firstMeasuredOperationIndex = firstMeasuredOperationIndex or index
				finalMeasuredOperationIndex = index
				assert(string.sub(measurementOrder[index - 1], 1, #"RawLocalClockRead/") == "RawLocalClockRead/",
					`{entry.label} measured start raw read must immediately precede the raw operation`)
				assert(measurementOrder[index + 1] == "RawLocalClockRead/normal",
					`{entry.label} measured return raw read must immediately follow the raw operation at {index}, got {tostring(measurementOrder[index - 2])} | {tostring(measurementOrder[index - 1])} | {event} | {tostring(measurementOrder[index + 1])} | {tostring(measurementOrder[index + 2])}`)
				assert(string.sub(event, -#"FlushBeforeReturn") == "FlushBeforeReturn",
					`{entry.label} final frame operation must retain FlushBeforeReturn`)
			end
		end
	end
	assert(measuredOperations == workload.measuredFrames * workload.senderCount * workload.messagesPerFrame,
		`{entry.label} measured operation trace cardinality differs`)
	local firstIndex = firstMeasuredOperationIndex :: number
	local finalIndex = finalMeasuredOperationIndex :: number
	assert(string.sub(measurementOrder[firstIndex - 3], 1, #"RawLocalClockRead/") == "RawLocalClockRead/"
		and string.sub(measurementOrder[firstIndex - 2], 1, #"RawSharedClockRead/") == "RawSharedClockRead/"
		and string.sub(measurementOrder[firstIndex - 1], 1, #"RawLocalClockRead/") == "RawLocalClockRead/",
		`{entry.label} first-repetition timing order differs`)
	assert(string.sub(measurementOrder[finalIndex + 1], 1, #"RawLocalClockRead/") == "RawLocalClockRead/"
		and string.sub(measurementOrder[finalIndex + 2], 1, #"RawLocalClockRead/") == "RawLocalClockRead/"
		and string.sub(measurementOrder[finalIndex + 3], 1, #"RawSharedClockRead/") == "RawSharedClockRead/",
		`{entry.label} final-repetition timing order differs`)
end

-- Probe request timing is captured in the same nonyielding call as the raw
-- submit, directly before that adapter edge.
do
	local measurementOrder = {}
	local rig = buildRig({
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		measurementOrder = measurementOrder,
	})
	local result = drive(rig, 1)
	assert(result.kind == "Result" and result.value.case.completedRepetitions == 1,
		"probe timing-order run must complete its measured repetition")
	local submitIndex = 0
	local measuredSubmits = 0
	for index = 1, #measurementOrder do
		if string.sub(measurementOrder[index], 1, #"RawAdaptersubmit") == "RawAdaptersubmit" then
			submitIndex += 1
			if submitIndex > 60 then
				measuredSubmits += 1
				assert(string.sub(measurementOrder[index - 1], 1, #"RawLocalClockRead/") == "RawLocalClockRead/",
					"probe round-trip start must immediately precede raw submit")
			end
		end
	end
	assert(measuredSubmits == 120, "probe measured submit trace cardinality differs")
end

-- A synchronous sender-only ingress can terminate during the first raw burst
-- submission. The returned transition must stop the remaining burst calls.
do
	local rig = buildRig({
		selection = { kind = "Workload", workloadId = "state-burst-c2s", recipientCount = 1 },
		senderOnlyIngressOnFirstSubmit = true,
	})
	local result = drive(rig)
	assert(result.kind == "Terminated", "sender-only burst ingress must terminate")
	assert(result.termination.code == "IngressLimitExceeded" and result.termination.stage == "Execution",
		"sender-only burst ingress termination differs")
	assert(rig.rawSubmitCount() == 1, "sender-only burst ingress must halt remaining raw submissions")
end

-- Once successful delivery verification starts the required quiet drain, its
-- completed delivery deadline no longer has authority to abort the repetition.
do
	local rig = buildRig({
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		timeoutJumpAfterC2SSubmitCount = 180,
	})
	local result = drive(rig, 1)
	assert(result.kind == "Result" and result.value.case.completedRepetitions == 1,
		"verified delivery must complete quiet drain after the timeout clock jump")
	assert(rig.timeoutJumped(), "verified delivery timeout regression must jump its clock")
	assert(not hasFailure(result.value, "Timeout"), "completed delivery deadline must not record Timeout")
end

-- A previous sender-only sink can terminate the case while the next Ready
-- session is still being constructed. That unadopted session is rolled back
-- completely instead of leaking its root or sides.
do
	local rig = buildRig({ constructorStaleDuringNextClient = true })
	local result = drive(rig)
	assert(result.kind == "Terminated", "constructor-time stale sender sink must terminate")
	assert(result.termination.code == "IngressLimitExceeded" and result.termination.stage == "Execution",
		"constructor-time stale sender termination differs")
	assert(rig.rootCalls() == 2 and rig.destroyCalls() == 2,
		"unadopted Ready session root must close exactly once")
	assert(rig.constructorStaleTeardownCalls() == 4,
		"adopted and unadopted session sides must each teardown exactly once")
end

-- Exercise every frozen fake delivery fault through the public runner. The
-- table also pins broadcast aggregation and probe-valid dispositions.
local deliveryFaultCases = {
	{
		label = "drop c2s",
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		fault = { kind = "Drop", target = { direction = "ClientToServer", submitIndex = 180, receiverIndex = 0 } },
		status = "Invalid", finality = "Final", started = 30, completed = 30,
		counts = { expectedSubmissions = 3600, submitted = 3600, expectedDeliveries = 3600, received = 3599, correct = 3599, missing = 1 },
		failures = { MissingDelivery = 1, Timeout = 1, RequiredMeasurementUnavailable = 3 },
	},
	{
		label = "duplicate c2s",
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		fault = { kind = "Duplicate", target = { direction = "ClientToServer", submitIndex = 61, receiverIndex = 0 } },
		status = "Invalid", finality = "Final",
		counts = { received = 3601, correct = 3600, duplicate = 1 }, failures = { DuplicateDelivery = 1 },
	},
	{
		label = "corrupt c2s",
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		fault = { kind = "Corrupt", target = { direction = "ClientToServer", submitIndex = 61, receiverIndex = 0 } },
		status = "Invalid", finality = "Final",
		counts = { received = 3600, correct = 3599, mismatch = 1 }, failures = { PayloadMismatch = 1 },
	},
	{
		label = "reorder c2s",
		selection = { kind = "Workload", workloadId = "tiny-steady-c2s", recipientCount = 1 },
		fault = { kind = "ReorderNext", target = { direction = "ClientToServer", submitIndex = 61, receiverIndex = 0 } },
		status = "Invalid", finality = "Final",
		counts = { received = 3600, correct = 3600, outOfOrder = 1 }, failures = { OutOfOrderDelivery = 1 },
	},
	{
		label = "delay broadcast",
		selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 4 },
		fault = { kind = "Delay", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 2 }, frames = 2 },
		status = "Valid", finality = "Final", failures = {},
	},
	{
		label = "corrupt broadcast",
		selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 4 },
		fault = { kind = "Corrupt", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 2 } },
		status = "Invalid", finality = "Final",
		counts = { expectedSubmissions = 3600, submitted = 3600, expectedDeliveries = 14400, received = 14400, correct = 14399, mismatch = 1 },
		failures = { PayloadMismatch = 1 },
	},
	{
		label = "unexpected broadcast",
		selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 4 },
		fault = { kind = "Unexpected", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 3 } },
		status = "Invalid", finality = "Final",
		counts = { received = 14401, correct = 14400, unexpected = 1 }, failures = { UnexpectedDelivery = 1 },
	},
	{
		label = "stale broadcast",
		selection = { kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 4 },
		fault = { kind = "StaleAfterTeardown", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 4 } },
		status = "Invalid", finality = "Final", failures = { StaleCallback = 1 },
	},
	{
		label = "drop probe request",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "Drop", target = { direction = "ClientToServer", submitIndex = 61, receiverIndex = 0 } },
		status = "Invalid", started = 1, completed = 0,
		failures = { Timeout = 1, RequiredMeasurementUnavailable = 1 },
	},
	{
		label = "corrupt probe request",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "Corrupt", target = { direction = "ClientToServer", submitIndex = 61, receiverIndex = 0 } },
		status = "Invalid", started = 1, completed = 0,
		failures = { PayloadMismatch = 1, Timeout = 1, RequiredMeasurementUnavailable = 1 },
	},
	{
		label = "corrupt probe response",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "Corrupt", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 1 } },
		status = "Invalid", failures = { PayloadMismatch = 1 },
	},
	{
		label = "duplicate probe request",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "Duplicate", target = { direction = "ClientToServer", submitIndex = 61, receiverIndex = 0 } },
		status = "Invalid", failures = { StaleCallback = 1 },
	},
	{
		label = "unexpected probe response",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "Unexpected", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 1 } },
		status = "Invalid", failures = { StaleCallback = 1 },
	},
	{
		label = "delayed probe response",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "Delay", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 1 }, frames = 2 },
		status = "Valid", failures = {},
	},
	{
		label = "stale probe response",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "StaleAfterTeardown", target = { direction = "ServerToClient", submitIndex = 61, receiverIndex = 1 } },
		status = "Invalid", failures = { StaleCallback = 1 },
	},
	{
		label = "failed probe response",
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		fault = { kind = "FailSubmit", direction = "ServerToClient", submitIndex = 61 },
		status = "Invalid", started = 1, completed = 0,
		failures = { SubmitFailure = 1, RequiredMeasurementUnavailable = 1 },
	},
}

for _, entry in deliveryFaultCases do
	local rig = buildRig({ selection = entry.selection, faults = { entry.fault } })
	local result = drive(rig)
	if entry.termination ~= nil then
		assert(result.kind == "Terminated" and result.termination.code == entry.termination,
			`{entry.label} termination differs: got {result.kind}/{if result.kind == "Terminated" then result.termination.code else result.value.status}/{if result.kind == "Result" then failureCodes(result.value) else ""}`)
		continue
	end
	assert(result.kind == "Result", `{entry.label} must remain representable, got {result.kind}/{if result.kind == "Terminated" then result.termination.code else "none"}, roots={rig.rootCalls()}, frame={rig.driver.frame()}`)
	assert(result.value.status == entry.status, `{entry.label} status differs`)
	assert(result.value.case.startedRepetitions == (entry.started or result.value.case.scheduledRepetitions),
		`{entry.label} started progress differs`)
	assert(result.value.case.completedRepetitions == (entry.completed or result.value.case.scheduledRepetitions),
		`{entry.label} completed progress differs`)
	if entry.selection.kind == "Workload" then
		assert(result.value.counts.finality == entry.finality, `{entry.label} finality differs`)
		for key, value in entry.counts or {} do
			assert(result.value.counts[key] == value, `{entry.label} count {key} differs`)
		end
	else
		assert(rawget(result.value, "counts") == nil, `{entry.label} probe must omit counts`)
		for _, code in { "SubmissionShortfall", "MissingDelivery", "DuplicateDelivery", "UnexpectedDelivery", "OutOfOrderDelivery" } do
			assert(not hasFailure(result.value, code), `{entry.label} emitted workload-only {code}`)
		end
	end
	for code, occurrences in entry.failures do
		assert(failureOccurrences(result.value, code) == occurrences,
			`{entry.label} {code} occurrences differ: {failureCodes(result.value)}`)
	end
	for _, failure in result.value.failures do
		assert(entry.failures[failure.code] ~= nil,
			`{entry.label} emitted unexpected {failure.code}: {failureCodes(result.value)}`)
	end
	assert(rig.destroyCalls() == rig.rootCalls(), `{entry.label} must close every opened root`)
end

-- Rejecting the first completed generation reset preserves the completed
-- repetition and projects the exact isolation failure as Partial evidence.
do
	local rig = buildRig({
		selection = {
			kind = "Workload",
			workloadId = "state-broadcast-s2c",
			recipientCount = 4,
		},
		sharedStateLeak = true,
	})
	local result = drive(rig, nil, rig.resetClean)
	assert(result.kind == "Result", "reset rejection must remain representable")
	assert(result.value.status == "Invalid", "reset rejection must invalidate the result")
	assert(result.value.counts.finality == "Partial", "reset rejection must project Partial counts")
	assert(result.value.case.startedRepetitions == 1 and result.value.case.completedRepetitions == 1,
		"reset rejection must retain exactly one completed repetition")
	local isolationOccurrences = 0
	for _, failure in result.value.failures do
		if failure.code == "IsolationFailure" then
			isolationOccurrences += failure.occurrences
		end
	end
	assert(isolationOccurrences == 1, "reset rejection must record one IsolationFailure")
	assert(not hasFailure(result.value, "FinalizationFailure"), "sender isolation failure must validate directly")
	assert(rig.rootCalls() == 1, "reset rejection must not open the next generation")
	assertStateError(rig.runner.rejectGenerationReset, "double reset rejection")
end

-- A measured adapter submission failure aborts the open repetition after its
-- mandatory teardown observation and never increments completed progress.
do
	local rig = buildRig({
		faults = {
			{ kind = "FailSubmit", direction = "ClientToServer", submitIndex = 61 },
		},
	})
	local result = drive(rig)
	assert(result.kind == "Result", "measured submit failure must remain representable")
	assert(result.value.status == "Invalid", "measured submit failure must invalidate the result")
	assert(result.value.counts.finality == "Partial", "measured abort must project Partial counts")
	assert(result.value.case.startedRepetitions == 1 and result.value.case.completedRepetitions == 0,
		"measured abort must retain one open-started and zero completed repetitions")
	assert(hasFailure(result.value, "SubmitFailure"), "measured abort must record SubmitFailure")
	assert(rig.destroyCalls() == 1, "measured abort must still close its generation root")
end

-- Caller-owned inputs remain stable across an accepted adapter operation. The
-- operation is still counted before the contract violation aborts the case.
do
	local rig = buildRig({ mutateClientSubmitAt = 61 })
	local result = drive(rig)
	assert(result.kind == "Result", "measured input mutation must remain representable")
	assert(result.value.status == "Invalid", "measured input mutation must invalidate the result")
	assert(result.value.counts.finality == "Partial", "measured input mutation must project Partial counts")
	assert(result.value.case.startedRepetitions == 1 and result.value.case.completedRepetitions == 0,
		"measured input mutation must abort the open repetition")
	assert(failureOccurrences(result.value, "InputMutation") == 1,
		"measured input mutation must record one bounded contract failure")
	assert(not hasFailure(result.value, "SubmitFailure"),
		"an accepted mutated input must not be reported as a submit failure")
	assert(result.value.counts.submitted == 1,
		"an accepted mutated input must remain counted as submitted")
	assert(rig.destroyCalls() == 1, "measured input mutation must still close its generation root")
end

-- Warmup uses the same guard but remains outside measured submission counts.
do
	local rig = buildRig({ mutateClientSubmitAt = 1 })
	local result = drive(rig)
	assert(result.kind == "Result", "warmup input mutation must remain representable")
	assert(result.value.status == "Invalid", "warmup input mutation must invalidate the result")
	assert(result.value.counts.finality == "NotStarted", "warmup input mutation must remain NotStarted")
	assert(result.value.case.startedRepetitions == 0 and result.value.case.completedRepetitions == 0,
		"warmup input mutation must prevent measured progress")
	assert(failureOccurrences(result.value, "InputMutation") == 1,
		"warmup input mutation must record one bounded contract failure")
	assert(not hasFailure(result.value, "SubmitFailure"),
		"accepted warmup work must not be reported as a submit failure")
	assert(result.value.counts.submitted == 0, "warmup input mutation must not increment measured submissions")
	assert(rig.destroyCalls() == 1, "warmup input mutation must still close its generation root")
end

-- Ordinary teardown failure on either side preserves the warmup mutation
-- that stopped the case, including when the receiver's teardown fails.
for _, side in { "Client", "Server" } do
	local rig = buildRig({
		mutateClientSubmitAt = 1,
		faults = {
			{ kind = "FailTeardown", side = side, participantIndex = if side == "Client" then 1 else 0 },
		},
	})
	local result = drive(rig)
	assert(result.kind == "Result", `warmup mutation with {side} teardown failure must remain representable`)
	assert(result.value.status == "Invalid" and result.value.counts.finality == "NotStarted",
		"warmup mutation teardown failure must remain unranked and NotStarted")
	assert(result.value.case.startedRepetitions == 0 and result.value.case.completedRepetitions == 0,
		"warmup mutation teardown failure must retain zero measured progress")
	assert(failureOccurrences(result.value, "InputMutation") == 1
		and failureOccurrences(result.value, "TeardownFailure") == 1,
		"warmup mutation teardown failure must preserve both causes")
	assert(not hasFailure(result.value, "SetupFailure"), "warmup mutation must not become a setup failure")
	for _, measurement in result.value.measurements do
		assert(measurement.state == "Unavailable", "warmup mutation must not publish measured samples")
	end
	assert(rig.destroyCalls() == 1, "warmup mutation teardown failure must still destroy its root once")
end

-- A synchronous probe can expose the same mutation independently on its
-- request and response sides. Both participant facts collapse to one case latch.
do
	local rig = buildRig({
		selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
		mutateClientSubmitAt = 61,
		mutateServerBroadcastAt = 61,
	})
	local result = drive(rig)
	assert(result.kind == "Result", "two-sided probe input mutation must remain representable")
	assert(result.value.status == "Invalid", "two-sided probe input mutation must invalidate the result")
	assert(result.value.case.startedRepetitions == 1 and result.value.case.completedRepetitions == 0,
		"two-sided probe input mutation must abort before verification")
	assert(failureOccurrences(result.value, "InputMutation") == 1,
		"two-sided probe facts must deduplicate to one case failure")
	assert(not hasFailure(result.value, "SubmitFailure"),
		"accepted probe operations must not be reported as submit failures")
	assert(rig.destroyCalls() == 1, "two-sided probe input mutation must close its generation root")
end

-- On the final accepted operation, receivers may finish locally before the
-- sender compares its input. The case remains globally partial and Invalid.
for _, entry in {
	{
		label = "final C2S submission",
		options = { mutateClientSubmitAt = 180 },
		expectedSubmitted = 120,
	},
	{
		label = "final S2C broadcast",
		options = {
			selection = {
				kind = "Workload", workloadId = "state-broadcast-s2c", recipientCount = 1,
			},
			mutateServerBroadcastAt = 180,
		},
		expectedSubmitted = 120,
	},
	{
		label = "final probe response",
		options = {
			selection = { kind = "SeparateProbe", probeId = "tiny-round-trip" },
			mutateServerBroadcastAt = 180,
		},
	},
} do
	local rig = buildRig(entry.options)
	local result = drive(rig)
	assert(result.kind == "Result", `{entry.label} mutation must remain representable, got {result.kind}{if result.kind == "Terminated" then ":" .. result.termination.code else ""}`)
	assert(result.value.status == "Invalid", `{entry.label} mutation must invalidate the result`)
	assert(result.value.case.startedRepetitions == 1 and result.value.case.completedRepetitions == 0,
		`{entry.label} mutation must preserve the globally incomplete repetition`)
	assert(failureOccurrences(result.value, "InputMutation") == 1,
		`{entry.label} mutation must retain one case latch`)
	if entry.expectedSubmitted ~= nil then
		assert(result.value.counts.submitted == entry.expectedSubmitted,
			`{entry.label} mutation must count every accepted operation`)
	end
	assert(rig.destroyCalls() == 1, `{entry.label} mutation must close its generation root`)
end

-- Guarded underlying clock failures all arrive as the one approved clock
-- sentinel, abort before measured work, and retain zero progress.
for _, clockFailure in { "Missing", "Yield", "Extra" } do
	local rig = buildRig({ clientLocalClockFailure = clockFailure })
	local result = drive(rig)
	assert(result.kind == "Result", `{clockFailure} clock failure must remain representable`)
	assert(result.value.status == "Error", `{clockFailure} clock failure must be Error`)
	assert(result.value.counts.finality == "NotStarted", `{clockFailure} clock failure must be NotStarted`)
		assert(result.value.case.startedRepetitions == 0 and result.value.case.completedRepetitions == 0,
			`{clockFailure} clock failure must retain zero progress`)
		assert(hasFailure(result.value, "ClockProofFailure"), `{clockFailure} must record ClockProofFailure`)
		assert(not hasFailure(result.value, "InternalError"), `{clockFailure} guarded sentinel must not record InternalError`)
	assert(rig.destroyCalls() == 1, `{clockFailure} clock abort must still close its root`)
end

-- Raw teardown yield or extra return makes side cleanup ownership unprovable;
-- both paths still attempt the generation root exactly once and terminate.
for _, behavior in { "Yield", "Extra" } do
	local rig = buildRig({ rawTeardownBehavior = behavior })
	local result = drive(rig)
	assert(result.kind == "Terminated", `{behavior} raw teardown must terminate`)
	assert(result.termination.code == "CleanupFailure" and result.termination.stage == "Finalize",
		`{behavior} raw teardown termination differs`)
	assert(rig.destroyCalls() == 1, `{behavior} raw teardown must still destroy the root once`)
	assert(not rig.teardownResumed(), "yielded raw teardown must never resume")
end

-- An ordinary adapter teardown failure is repetition-owned evidence rather
-- than a case-owned cleanup termination.
do
	local rig = buildRig({
		faults = {
			{ kind = "FailTeardown", side = "Client", participantIndex = 1 },
		},
	})
	local result = drive(rig)
	assert(result.kind == "Result", "ordinary teardown failure must remain representable")
	assert(result.value.status == "Invalid", "ordinary teardown failure must invalidate the result")
	assert(hasFailure(result.value, "TeardownFailure"), "ordinary teardown failure must record TeardownFailure")
	assert(rig.destroyCalls() == result.value.case.scheduledRepetitions,
		"ordinary teardown failure must retain the complete repetition loop")
end

-- Case-owned root cleanup failure overrides otherwise representable evidence
-- with the fixed redacted B7 termination.
do
	local rig = buildRig({ rootDestroyFails = true })
	local result = drive(rig)
	assert(result.kind == "Terminated", "root cleanup failure must terminate")
	assert(result.termination.code == "CleanupFailure" and result.termination.stage == "Finalize",
		"root cleanup termination differs")
	assert(rig.destroyCalls() == 1, "failing root destroy must be attempted exactly once")
end

-- A later case-owned root cleanup failure overrides an earlier pre-start
-- final-evidence termination and remains the final sticky envelope.
do
	local rig = buildRig({
		clientLocalClockFailure = "Missing",
		rootDestroyFails = true,
		faults = {
			{ kind = "FailTeardown", side = "Client", participantIndex = 1 },
		},
	})
	local result = drive(rig)
	assert(result.kind == "Terminated", "combined pre-start teardown/root failure must terminate")
	assert(result.termination.code == "CleanupFailure" and result.termination.stage == "Finalize",
		"later root cleanup failure must override the earlier termination")
	assert(rig.destroyCalls() == 1, "combined cleanup failure must attempt root destroy once")
end

-- A pre-construction setup failure produces one schema-valid NotStarted
-- result and never exposes the hostile exception detail.
do
	local rig = buildRig({ rootFactoryFails = true })
	local result = drive(rig)
	assert(result.kind == "Result", "root allocation failure must remain representable")
	assert(result.value.status == "Invalid", "setup failure result must be Invalid")
	assert(result.value.case.startedRepetitions == 0, "setup failure must not start measured work")
	assert(result.value.failures[1].code == "SetupFailure", "setup failure code differs")
	assert(rig.destroyCalls() == 0, "allocation-atomic root failure must not destroy an unreturned root")
end

-- An activation-time side setup failure rolls back the opened generation and
-- projects the same bounded NotStarted setup evidence.
do
	local rig = buildRig({
		faults = {
			{ kind = "FailSetup", side = "Server", participantIndex = 0 },
		},
	})
	local result = drive(rig)
	assert(result.kind == "Result", "activation setup failure must remain representable")
	assert(result.value.status == "Invalid", "activation setup failure must be Invalid")
	assert(result.value.counts.finality == "NotStarted", "activation setup failure must be NotStarted")
	assert(result.value.case.startedRepetitions == 0 and result.value.case.completedRepetitions == 0,
		"activation setup failure must retain zero progress")
	assert(hasFailure(result.value, "SetupFailure"), "activation setup failure code differs")
	assert(rig.destroyCalls() == 1, "activation rollback must destroy the opened root once")
end

print("PASS Relay.Benchmarks.CaseRunner")
