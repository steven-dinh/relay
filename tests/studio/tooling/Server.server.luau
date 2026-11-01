local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local runServiceContext

local function runServerTest()
	local isRunning = RunService:IsRunning()
	runServiceContext = {
		isStudio = RunService:IsStudio(),
		isServer = RunService:IsServer(),
		isClient = RunService:IsClient(),
		isRunning = isRunning,
		isRunMode = RunService:IsRunMode(),
		mode = if isRunning then "running" else "not-running",
	}
	assert(runServiceContext.isStudio and runServiceContext.isServer,
		"native tooling fixture requires Studio and server RunService context")

	local Relay = require(ReplicatedStorage.Relay)
	local Registration = require(ReplicatedStorage.RelayTools.Registration)
	local Structured = require(ReplicatedStorage.RelayTools.Structured)
	local Definition = require(ReplicatedStorage.RelayToolingDefinition)
	local serverStorage = ServerStorage

	local function options(namespace)
		return {
			namespace = namespace,
			inboundRate = {
				perPlayer = { capacity = 16, refillPerSecond = 8 },
				aggregate = { capacity = 128, refillPerSecond = 64 },
			},
			diagnostics = { traffic = true, reports = true },
		}
	end

	local function problemCode(problem)
		return if type(problem) == "table" and type(problem.code) == "string" then problem.code else nil
	end

	local metadata = {
		label = "Native tooling proof",
		projectId = "relay-native-proof",
		compilerId = "relay-compiler-native",
		toolingId = "relay-tools-native",
		sourceId = "native-fixture-source",
	}

	local function readRecord(value)
		local record, problem = Structured.decode(function(bytes)
			return HttpService:JSONDecode(bytes)
		end, value.Value)
		assert(record ~= nil, "server structured record failed: " .. tostring(problem))
		return record
	end

	local function createRegistration(count, namespace)
		local definition = Definition.create(Relay, count)
		local session, attachment, problem = Registration.createServer(Relay, definition, options(namespace), metadata)
		assert(session ~= nil and attachment ~= nil and problem == nil,
			"server registration failed: " .. (problemCode(problem) or "session or attachment was not returned"))
		local root = serverStorage:FindFirstChild("RelayStudioInspector_v1")
		assert(root ~= nil, "server attachment root missing from ServerStorage")
		local value = root:FindFirstChild("Attachment" .. string.format("%02d", namespace == "native_small" and 1 or 2))
		assert(value ~= nil and value.Parent == root, "server attachment record missing")
		local record = readRecord(value)
		assert(record.format == 2 and record.association == "constructed"
			and record.identityStatus == "application-supplied" and record.projectId == metadata.projectId
			and #record.inspection.events == count and record.inspection.events[1].name == "ClientProof"
			and record.inspection.descriptor == nil and record.diagnostics == nil and record.payload == nil,
			"server record must be v2, bounded, and associated with the constructed Relay definition")
		return { definition = definition, session = session, attachment = attachment, root = root, value = value, record = record }
	end

	local small = createRegistration(1, "native_small")
	local large = createRegistration(64, "native_large")
	local reportDefinition = Definition.create(Relay, 1)
	local reportSession, reportProblem = Relay.createServer(reportDefinition, options("native_report"))
	assert(reportSession ~= nil, "server result session failed: " .. (problemCode(reportProblem) or "session was not returned"))
	local clientProofCode
	assert(reportSession.events.ClientProof:Connect(function(_, code) clientProofCode = code end) ~= nil,
		"server proof event connection failed")
	local reportStarted, reportProblem = reportSession:Start()
	assert(reportStarted, reportProblem and reportProblem.code or "server result session failed to start")

	local function sampleOnce(state)
		local started = os.clock()
		local untilTime = started + 3
		local record
		repeat
			state.attachment:Refresh()
			task.wait(0.1)
			record = readRecord(state.value)
		until (#record.history >= 2 and record.scalars.state == "Created") or os.clock() >= untilTime
		local waitSeconds = os.clock() - started
		assert(record.sessionId == state.record.sessionId and #record.history >= 2
			and #record.history <= Structured.MAX_HISTORY_SAMPLES
			and record.scalars.side == "Server" and record.scalars.state == "Created",
			"server v2 snapshot did not retain a sampled record")
		assert(record.elapsed >= 0.9 and waitSeconds <= 3,
			"server sampler did not retain a roughly one-second sample within the local observation deadline")
		record.encodedBytes = #state.value.Value
		record.sampleWaitSeconds = waitSeconds
		return record
	end

	local sampledSmall = sampleOnce(small)
	local sampledLarge = sampleOnce(large)

	local function closeAndVerify(state)
		state.session:Destroy()
		local untilTime = os.clock() + 3
		local terminal
		repeat
			task.wait(0.1)
			terminal = readRecord(state.value)
		until terminal.scalars.state == "Destroyed" or os.clock() >= untilTime
		assert(terminal.scalars.state == "Destroyed" and #terminal.history >= 3,
			"terminal state was not sampled as the final snapshot")
		local terminalBytes = state.value.Value
		task.wait(1.1)
		assert(state.value.Value == terminalBytes, "terminal sampler continued writing after its final sample")
		state.attachment:Destroy()
		assert(state.value.Parent == nil and state.root:FindFirstChild(state.value.Name) == nil,
			"attachment Destroy did not remove its retained record")
		return terminal.sessionId
	end

	local oldSmallSessionId = closeAndVerify(small)
	local oldLargeSessionId = closeAndVerify(large)

	local replacementDefinition = Definition.create(Relay, 1)
	local replacement, replacementAttachment, replacementProblem = Registration.createServer(
		Relay, replacementDefinition, options("native_small"), metadata)
	assert(replacement ~= nil and replacementAttachment ~= nil and replacementProblem == nil,
		"server replacement registration failed: "
			.. (problemCode(replacementProblem) or "session or attachment was not returned"))
	local replacementRoot = serverStorage:FindFirstChild("RelayStudioInspector_v1")
	local replacementValue = replacementRoot and replacementRoot:FindFirstChild("Attachment01")
	assert(replacementValue ~= nil, "server replacement attachment record missing")
	local replacementRecord = readRecord(replacementValue)
	assert(replacementRecord.sessionId ~= oldSmallSessionId and replacementRecord.sessionId ~= oldLargeSessionId,
		"server replacement reuses a previous local session identity")
	replacement:Destroy()
	replacementAttachment:Destroy()
	assert(replacementValue.Parent == nil and ServerStorage:FindFirstChild("RelayStudioInspector_v1") == nil,
		"server replacement attachment cleanup failed")

	local malformed, malformedProblem = Structured.decode(function()
		error("malformed JSON must be contained")
	end, "{")
	assert(malformed == nil and malformedProblem == "MalformedJson", "server structured reader failed open on malformed JSON")

	local proofDeadline = os.clock() + 25
	while clientProofCode == nil and os.clock() < proofDeadline do task.wait(0.1) end
	assert(clientProofCode == 127, "client did not report all local placement/lifecycle checks through Relay")
	reportSession:Destroy()

	local function observation(record)
		return {
			endpointCount = #record.inspection.events,
			encodedBytes = record.encodedBytes,
			liveTextBytes = #record.liveText,
			historyCount = #record.history,
			elapsed = record.elapsed,
			sampleWaitSeconds = record.sampleWaitSeconds,
			association = record.association,
			identityStatus = record.identityStatus,
			namespace = record.namespace,
		}
	end

	local report = {
		kind = "RelayToolsNativeQualification",
		version = 1,
		ok = true,
		server = {
			runService = runServiceContext,
			small = observation(sampledSmall),
			large = observation(sampledLarge),
			serverStorage = true,
			clientProofCode = clientProofCode,
			clientChecks = {
				"PlayerScriptsPlacement",
				"ConstructedV2Association",
				"EndpointRoster",
				"OneSecondSampling",
				"TerminalCleanup",
				"ReplacementIdentity",
				"MalformedJsonRejected",
			},
			replacementIdChanged = replacementRecord.sessionId ~= oldSmallSessionId,
			terminalSamplerStopped = true,
			attachmentCleanup = true,
			malformedJsonRejected = true,
		},
	}

	return report
end

local runOk, result = pcall(runServerTest)
local function failureResult(code, message)
	local encodeOk, payload = pcall(function()
		return HttpService:JSONEncode({
			kind = "RelayToolsNativeQualification",
			version = 1,
			ok = false,
			runService = runServiceContext,
			failure = { code = code, message = message },
		})
	end)
	if encodeOk and type(payload) == "string" and #payload <= 1_024 then return payload end
	return '{"kind":"RelayToolsNativeQualification","version":1,"ok":false,"failure":{"code":"ResultEncodingFailed"}}'
end

local payload
if runOk then
	local encodeOk, encoded = pcall(function() return HttpService:JSONEncode(result) end)
	if encodeOk and type(encoded) == "string" and #encoded <= 4_096 then
		payload = encoded
	else
		payload = failureResult("ResultEncodingFailed", "native result was not bounded JSON")
	end
else
	local message = if type(result) == "string" then string.sub(result, 1, 512) else "native fixture failed"
	payload = failureResult("FixtureFailure", message)
end
StudioTestService:EndTest(payload)
