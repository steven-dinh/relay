local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsStudio() and RunService:IsClient(), "native tooling fixture requires a Studio client")

local Relay = require(ReplicatedStorage.Relay)
local Registration = require(ReplicatedStorage.RelayTools.Registration)
local Structured = require(ReplicatedStorage.RelayTools.Structured)
local Snapshot = require(ReplicatedStorage.RelayTools.Snapshot)
local Definition = require(ReplicatedStorage.RelayToolingDefinition)
local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")

local function options(namespace)
	return { namespace = namespace, startupTimeoutSeconds = 15 }
end

local function createRegistration(count, namespace, slot)
	local definition = Definition.create(Relay, count)
	local session, attachment, problem = Registration.createClient(Relay, definition, options(namespace), nil)
	assert(session ~= nil and attachment ~= nil and problem == nil,
		"client registration failed: " .. tostring(problem))
	local root = playerScripts:FindFirstChild("RelayStudioInspector_v1")
	assert(root ~= nil and root.Parent == playerScripts, "client attachment was not created under local PlayerScripts")
	local value = root:FindFirstChild("Attachment" .. string.format("%02d", slot))
	assert(value ~= nil and value.Parent == root, "client attachment record missing")
	local record, decodeProblem = Structured.decode(function(bytes)
		return HttpService:JSONDecode(bytes)
	end, value.Value)
	assert(record ~= nil, "client structured record failed: " .. tostring(decodeProblem))
	assert(record.format == 2 and record.association == "constructed" and record.identityStatus == "unverified"
		and record.projectId == nil and #record.inspection.events == count
		and record.inspection.descriptor == nil and record.diagnostics == nil and record.payload == nil,
		"client record must use the actual Relay definition with no application identity claim")
	return { definition = definition, session = session, attachment = attachment, root = root, value = value, record = record }
end

local function sampleOnce(state)
	local record, decodeProblem
	local started = os.clock()
	local untilTime = started + 3
	repeat
		state.attachment:Refresh()
		task.wait(0.1)
		record, decodeProblem = Structured.decode(function(bytes)
			return HttpService:JSONDecode(bytes)
		end, state.value.Value)
	until (record ~= nil and #record.history >= 2 and record.scalars.state == "Created") or os.clock() >= untilTime
	local waitSeconds = os.clock() - started
	local historyCount = if record ~= nil and type(record.history) == "table" then #record.history else 0
	local stateName = if record ~= nil and type(record.scalars) == "table"
		and type(record.scalars.state) == "string" then record.scalars.state else "unavailable"
	local side = if record ~= nil and type(record.scalars) == "table"
		and type(record.scalars.side) == "string" then record.scalars.side else "unavailable"
	local elapsed = if record ~= nil and type(record.elapsed) == "number" then record.elapsed else nil
	local encodedBytes = #state.value.Value
	local sessionMatches = record ~= nil and record.sessionId == state.record.sessionId
	local recordValid = record ~= nil and sessionMatches
		and state.value.Parent == state.root and state.root.Parent == playerScripts
		and record.format == 2 and record.association == "constructed" and record.identityStatus == "unverified"
		and #record.inspection.events == #state.record.inspection.events and side == "Client"
		and historyCount >= 2 and historyCount <= Snapshot.MAX_HISTORY_SAMPLES
		and stateName == "Created" and elapsed ~= nil and elapsed >= 0.9
		and waitSeconds >= 0 and waitSeconds < math.huge
		and encodedBytes <= Snapshot.MAX_BYTES and #record.liveText <= Structured.MAX_LIVE_TEXT_BYTES
	if not recordValid then
		local decode = if type(decodeProblem) == "string" then string.sub(decodeProblem, 1, 80) else "none"
		local elapsedText = if elapsed ~= nil then string.format("%.3f", elapsed) else "unavailable"
		local failure = string.format(
			"client sample invalid: waitSeconds=%.3f historyCount=%d state=%s elapsed=%s decode=%s sessionMatches=%s side=%s encodedBytes=%d",
			waitSeconds, historyCount, stateName, elapsedText, decode, tostring(sessionMatches), side, encodedBytes)
		warn(failure)
		error(failure, 0)
	end
	state.localPlacement = true
	state.association = record.format == 2 and record.association == "constructed"
	state.endpointCountMatches = #record.inspection.events == #state.record.inspection.events
	state.clientSide = record.scalars.side == "Client"
	record.encodedBytes = encodedBytes
	print(string.format("RelayToolsClientSampleV1 waitSeconds=%.3f historyCount=%d state=%s elapsed=%.3f side=%s encodedBytes=%d",
		waitSeconds, historyCount, stateName, elapsed, side, encodedBytes))
	state.sampled = true
	return record
end

local small = createRegistration(1, "native_small", 1)
local large = createRegistration(64, "native_large", 2)
sampleOnce(small)
sampleOnce(large)

local function closeAndVerify(state)
	local oldSessionId = state.record.sessionId
	state.session:Destroy()
	local untilTime = os.clock() + 3
	local terminal
	repeat
		task.wait(0.1)
		terminal = Structured.decode(function(bytes)
			return HttpService:JSONDecode(bytes)
		end, state.value.Value)
	until terminal ~= nil and terminal.scalars.state == "Destroyed" or os.clock() >= untilTime
	assert(terminal ~= nil and terminal.scalars.state == "Destroyed" and #terminal.history >= 3,
		"client terminal state was not sampled")
	local terminalBytes = state.value.Value
	task.wait(1.1)
	assert(state.value.Value == terminalBytes, "client terminal sampler continued after final sample")
	state.terminalSamplerStopped = true
	state.attachment:Destroy()
	assert(state.value.Parent == nil and state.root:FindFirstChild(state.value.Name) == nil,
		"client attachment Destroy did not clear local PlayerScripts")
	state.attachmentCleanup = true
	return oldSessionId
end

local oldSmallSessionId = closeAndVerify(small)
local oldLargeSessionId = closeAndVerify(large)

local replacement = createRegistration(1, "native_small", 1)
assert(replacement.record.sessionId ~= oldSmallSessionId and replacement.record.sessionId ~= oldLargeSessionId,
	"client replacement reuses a previous local session identity")
replacement.replacementIdChanged = true
replacement.session:Destroy()
replacement.attachment:Destroy()
assert(replacement.value.Parent == nil and playerScripts:FindFirstChild("RelayStudioInspector_v1") == nil,
	"client replacement attachment cleanup failed")

local malformed, malformedProblem = Structured.decode(function()
	error("malformed JSON must be contained")
end, "{")
assert(malformed == nil and malformedProblem == "MalformedJson", "client structured reader failed open on malformed JSON")

local clientProofCode = 0
if small.localPlacement and large.localPlacement then clientProofCode += 1 end
if small.association and large.association then clientProofCode += 2 end
if small.endpointCountMatches and large.endpointCountMatches then clientProofCode += 4 end
if small.sampled and large.sampled then clientProofCode += 8 end
if small.terminalSamplerStopped and large.terminalSamplerStopped
	and small.attachmentCleanup and large.attachmentCleanup then clientProofCode += 16 end
if replacement.replacementIdChanged then clientProofCode += 32 end
if malformed == nil and malformedProblem == "MalformedJson" then clientProofCode += 64 end
assert(clientProofCode == 127, "client lifecycle proof was incomplete")

local reportDefinition = Definition.create(Relay, 1)
local reportSession = assert(Relay.createClient(reportDefinition, options("native_report")))
local reportStarted, reportProblem = reportSession:Start()
assert(reportStarted, reportProblem and reportProblem.code or "client result session failed to start")
assert(reportSession.events.ClientProof:Send(clientProofCode), "client lifecycle result was not accepted by Relay")
task.wait(1)
reportSession:Destroy()
