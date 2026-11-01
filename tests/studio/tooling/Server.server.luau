local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsStudio() and RunService:IsServer(), "native tooling fixture requires a Studio server")

local Relay = require(ReplicatedStorage.Relay)
local Registration = require(ReplicatedStorage.RelayTools.Registration)
local Structured = require(ReplicatedStorage.RelayTools.Structured)
local Definition = require(ReplicatedStorage.RelayToolingDefinition)
local serverStorage = ServerStorage

local function options(namespace)
	return {
		namespace = namespace,
		diagnostics = { traffic = true, reports = true },
	}
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
		"server registration failed: " .. tostring(problem))
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
local reportSession = assert(Relay.createServer(reportDefinition, options("native_report")))
local clientProofCode
assert(reportSession.events.ClientProof:Connect(function(_, code) clientProofCode = code end) ~= nil,
	"server proof event connection failed")
local reportStarted, reportProblem = reportSession:Start()
assert(reportStarted, reportProblem and reportProblem.code or "server result session failed to start")

local function sampleOnce(state)
	local untilTime = os.clock() + 3
	local record
	repeat
		state.attachment:Refresh()
		task.wait(0.1)
		record = readRecord(state.value)
	until (#record.history >= 2 and record.scalars.state == "Created") or os.clock() >= untilTime
	assert(#record.history >= 2 and record.scalars.side == "Server" and record.scalars.state == "Created",
		"server v2 snapshot did not retain a sampled record")
	assert(record.elapsed >= 0.9 and record.elapsed <= 3,
		"server sampler did not retain a roughly one-second sample")
	record.encodedBytes = #state.value.Value
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
	"server replacement registration failed")
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

StudioTestService:EndTest(HttpService:JSONEncode(report))
