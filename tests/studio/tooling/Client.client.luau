local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsStudio() and RunService:IsClient(), "native tooling fixture requires a Studio client")

local Relay = require(ReplicatedStorage.Relay)
local Registration = require(ReplicatedStorage.RelayTools.Registration)
local Structured = require(ReplicatedStorage.RelayTools.Structured)
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
	local untilTime = os.clock() + 3
	repeat
		state.attachment:Refresh()
		task.wait(0.1)
		record, decodeProblem = Structured.decode(function(bytes)
			return HttpService:JSONDecode(bytes)
		end, state.value.Value)
	until (record ~= nil and #record.history >= 2 and record.scalars.state == "Created") or os.clock() >= untilTime
	assert(record ~= nil, "client record stopped decoding: " .. tostring(decodeProblem))
	assert(state.value.Parent == state.root and state.root.Parent == playerScripts
		and record.format == 2 and record.association == "constructed" and record.identityStatus == "unverified"
		and #record.inspection.events == #state.record.inspection.events and record.scalars.side == "Client",
		"client v2 record lost its local placement, definition association, or side")
	state.localPlacement = true
	state.association = record.format == 2 and record.association == "constructed"
	state.endpointCountMatches = #record.inspection.events == #state.record.inspection.events
	state.clientSide = record.scalars.side == "Client"

	assert(#record.history >= 2 and record.scalars.state == "Created"
		and record.elapsed >= 0.9 and record.elapsed <= 3,
		"client did not retain a valid sampled record: " .. tostring(decodeProblem))
	record.encodedBytes = #state.value.Value
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
