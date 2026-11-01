local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local PluginGuiService = game:GetService("PluginGuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

local reportUrl = __REPORT_URL__
local launchId = __LAUNCH_ID__
local legMode = __LEG_MODE__
local pluginArtifactSha256 = __PLUGIN_SHA256__
local phase = "plugin-discovery"
local failureDetails

local isRunning = RunService:IsRunning()
local isEdit = RunService:IsEdit()
local runServiceContext = {
	isStudio = RunService:IsStudio(),
	isServer = RunService:IsServer(),
	isClient = RunService:IsClient(),
	isEdit = isEdit,
	isRunning = isRunning,
	isRunMode = RunService:IsRunMode(),
	mode = if isRunning then "running" elseif isEdit then "edit" else "paused-or-transitioning",
}

local function boundedString(value, limit)
	local text = if type(value) == "string" then value else tostring(value)
	if #text > limit then return string.sub(text, 1, limit) end
	return text
end

local function safeProperty(instance, property)
	local ok, value = pcall(function() return instance[property] end)
	if not ok then return "<unavailable>" end
	return boundedString(value, 80)
end

local function contains(text, value)
	return type(text) == "string" and string.find(text, value, 1, true) ~= nil
end

local function waitFor(predicate, seconds, message)
	local deadline = os.clock() + seconds
	repeat
		if predicate() then return end
		task.wait(0.05)
	until os.clock() >= deadline
	assert(predicate(), message)
end

local function findSnapshot(candidate)
	local contents = candidate:FindFirstChild("Contents")
	local scroll = contents and contents:FindFirstChild("SnapshotScroll")
	local snapshot = scroll and scroll:FindFirstChild("Snapshot")
	if contents == nil or contents:FindFirstChild("ImportReport") == nil
		or contents:FindFirstChild("NextView") == nil or contents:FindFirstChild("NextSession") == nil
		or contents:FindFirstChild("NextSample") == nil or contents:FindFirstChild("EndpointFilter") == nil
		or snapshot == nil or not snapshot:IsA("TextBox") then
		return nil
	end
	return snapshot
end

local function pluginGuiCensus()
	local children = PluginGuiService:GetChildren()
	local entries = {}
	for index = 1, math.min(#children, 16) do
		local child = children[index]
		table.insert(entries, {
			class = safeProperty(child, "ClassName"),
			name = safeProperty(child, "Name"),
			title = safeProperty(child, "Title"),
		})
	end
	return { directChildCount = #children, entries = entries, truncated = #children > 16 }
end

local function matchingWidgets()
	local widgets = {}
	local titleMatches = 0
	for _, child in PluginGuiService:GetChildren() do
		if child:IsA("DockWidgetPluginGui") and child.Title == "Relay Tools" then
			titleMatches += 1
			local candidateSnapshot = findSnapshot(child)
			if candidateSnapshot ~= nil then
				table.insert(widgets, { widget = child, snapshot = candidateSnapshot })
			end
		end
	end
	return widgets, titleMatches
end

local function runQualification()
	local widgets
	local matchingTitleCount
	local deadline = os.clock() + 20
	repeat
		widgets, matchingTitleCount = matchingWidgets()
		if legMode == "control" and #widgets > 0 then break end
		if os.clock() < deadline then task.wait(0.1) end
	until os.clock() >= deadline
	local candidateDetails = {
		matchingTitleCount = matchingTitleCount,
		completeWidgetMatchCount = #widgets,
		pluginGuiServiceChildren = pluginGuiCensus(),
	}
	if legMode == "control" then
		phase = "preinstall-control"
		if #widgets > 0 then
			return {
				launchId = launchId,
				legMode = legMode,
				pluginArtifactSha256 = pluginArtifactSha256,
				studioVersion = version(),
				runService = runServiceContext,
				ok = false,
				phase = phase,
				failure = {
					message = "a complete Relay Tools dock widget existed before the qualification plugin was installed",
					details = candidateDetails,
				},
			}
		end
		return {
			launchId = launchId,
			legMode = legMode,
			pluginArtifactSha256 = pluginArtifactSha256,
			studioVersion = version(),
			runService = runServiceContext,
			ok = true,
			preinstall = candidateDetails,
		}
	end
	if legMode ~= "qualification" then error("unknown native qualification leg mode") end
	if #widgets ~= 1 then
		failureDetails = {
			matchingTitleCount = candidateDetails.matchingTitleCount,
			completeWidgetMatchCount = candidateDetails.completeWidgetMatchCount,
			pluginGuiServiceChildren = candidateDetails.pluginGuiServiceChildren,
		}
		error("expected exactly one complete Relay Tools dock widget; observed " .. tostring(#widgets))
	end
	local widget = widgets[1].widget
	local snapshot = widgets[1].snapshot

	phase = "plugin-controls"
	widget.Enabled = false
	waitFor(function() return snapshot.Text == "" end, 3, "Relay Tools panel did not start in a cleared state")

	phase = "registration-and-snapshot"
	local Relay = require(ReplicatedStorage.Relay)
	local Definition = require(ReplicatedStorage.RelayToolingDefinition)
	local Registration = require(ReplicatedStorage.RelayTools.Registration)
	local Structured = require(ReplicatedStorage.RelayTools.Structured)
	local Snapshot = require(ReplicatedStorage.RelayTools.Snapshot)
	local BaselineSnapshot = require(ReplicatedStorage.RelayTools.BaselineSnapshot)
	local Result = require(ReplicatedStorage.RelayToolingUI.ToolingResult)
	local Workspace = require(ReplicatedStorage.RelayToolingUI.Workspace)

	local metadata = {
		label = "Native UI proof",
		projectId = "relay-native-ui",
		compilerId = "relay-compiler-native",
		toolingId = "relay-tools-native",
		sourceId = launchId,
	}
	local identity = {
		projectId = metadata.projectId,
		compilerId = metadata.compilerId,
		toolingId = metadata.toolingId,
		sourceId = metadata.sourceId,
		host = "studio",
		runId = "run:" .. launchId,
	}

	local function heapKilobytes()
		local ok, value = pcall(gcinfo)
		return if ok and type(value) == "number" then value else nil
	end

	local function measure(label, operation)
		local samples = {}
		local beforeHeap = heapKilobytes()
		local output = ""
		for index = 1, 3 do
			local started = os.clock()
			output = operation()
			samples[index] = (os.clock() - started) * 1_000
		end
		local maximum = 0
		for _, value in samples do maximum = math.max(maximum, value) end
		local afterHeap = heapKilobytes()
		return {
			name = label,
			samplesMs = samples,
			maxMs = maximum,
			outputBytes = #output,
			heapDeltaKb = if beforeHeap and afterHeap then afterHeap - beforeHeap else nil,
		}
	end

	local function layout(text)
		local bounds = TextService:GetTextSize(text, 14, Enum.Font.Code,
			Vector2.new(8_192, 1_000_000))
		return string.format("%d x %d", math.floor(bounds.X), math.floor(bounds.Y))
	end

	local retainedHeapStartKb = heapKilobytes()

	local function exercise(count)
		phase = "registration-and-snapshot"
		if runServiceContext.isStudio ~= true or runServiceContext.isServer ~= true then
			failureDetails = { runService = runServiceContext }
			error("native UI registration requires Studio and server RunService context")
		end
		local definition = Definition.create(Relay, count)
		local report, inspectProblem = Relay.inspect(definition)
		assert(report ~= nil, inspectProblem and inspectProblem.message or "native schema inspection failed")
		local session, attachment, attachProblem = Registration.createServer(Relay, definition,
			{
				namespace = "native_ui",
				inboundRate = {
					perPlayer = { capacity = 16, refillPerSecond = 8 },
					aggregate = { capacity = 128, refillPerSecond = 64 },
				},
			}, metadata)
		if session == nil or attachment == nil or attachProblem ~= nil then
			local problemCode = if type(attachProblem) == "table" and type(attachProblem.code) == "string"
				then boundedString(attachProblem.code, 80) else nil
			failureDetails = {
				runService = runServiceContext,
				registrationProblemCode = problemCode,
			}
			error("native UI registration failed: " .. (problemCode or "session or attachment was not returned"))
		end

		local root = ServerStorage:FindFirstChild("RelayStudioInspector_v1")
		local value = root and root:FindFirstChild("Attachment01")
		assert(value ~= nil, "native UI fixture record is missing")
		local record, recordProblem = Structured.decode(function(bytes)
			return HttpService:JSONDecode(bytes)
		end, value.Value)
		assert(record ~= nil and record.format == 2 and record.association == "constructed"
			and record.identityStatus == "application-supplied" and #record.inspection.events == count,
			"native UI fixture snapshot is not the expected structured record: " .. tostring(recordProblem))

		local baselineText = BaselineSnapshot.format(report, session:GetDiagnostics(), "Native UI proof", {}, 65_536)
		local currentText = Snapshot.format(report, session:GetDiagnostics(), "Native UI proof", {}, 65_536)
		local result = Result.new("schema", identity, "passed", report)
		local workspaceText = Workspace.render(result, "Schema")
		local measurements = {
			endpointCount = count,
			baselineSnapshotFormat = measure("baseline snapshot", function()
				return BaselineSnapshot.format(report, session:GetDiagnostics(), "Native UI proof", {}, 65_536)
			end),
			currentSnapshotFormat = measure("current snapshot", function()
				return Snapshot.format(report, session:GetDiagnostics(), "Native UI proof", {}, 65_536)
			end),
			workspaceRender = measure("workspace render", function()
				return Workspace.render(result, "Schema")
			end),
			baselineTextLayout = measure("baseline TextService layout", function()
				layout(baselineText)
				return baselineText
			end),
			currentTextLayout = measure("current TextService layout", function()
				layout(currentText)
				return currentText
			end),
			workspaceTextLayout = measure("workspace TextService layout", function()
				layout(workspaceText)
				return workspaceText
			end),
			baselineTextBytes = #baselineText,
			currentTextBytes = #currentText,
			workspaceTextBytes = #workspaceText,
			structuredRecordBytes = #value.Value,
			structuredLiveTextBytes = #record.liveText,
			workspaceReportBytes = #HttpService:JSONEncode(result),
		}

		local sampleDeadline = os.clock() + 3
		local sampleMilliseconds
		while sampleMilliseconds == nil and os.clock() < sampleDeadline do
			local started = os.clock()
			if attachment:Refresh() then sampleMilliseconds = (os.clock() - started) * 1_000 else task.wait(0.1) end
		end
		assert(sampleMilliseconds ~= nil, "native attachment Refresh did not take a one-second sample")
		measurements.attachmentRefreshMs = sampleMilliseconds
		measurements.structuredRecordBytes = #value.Value
		local refreshed, refreshProblem = Structured.decode(function(bytes)
			return HttpService:JSONDecode(bytes)
		end, value.Value)
		assert(refreshed ~= nil and #refreshed.history >= 2,
			"native attachment Refresh did not retain a bounded sample: " .. tostring(refreshProblem))

		local function openAndRead()
			phase = "plugin-rendering"
			local started = os.clock()
			widget.Enabled = true
			local updateDeadline = os.clock() + 3
			repeat
				if contains(snapshot.Text, record.sessionId) then break end
				task.wait(0.01)
			until os.clock() >= updateDeadline
			assert(contains(snapshot.Text, record.sessionId), "Relay Tools UI did not render the attached session")
			return (os.clock() - started) * 1_000
		end

		measurements.visibleUpdateMs = openAndRead()
		assert(contains(snapshot.Text, "Definition: " .. report.name)
			and contains(snapshot.Text, "Association: constructed from the application's Relay/definition."),
			"Relay Tools UI did not render the actual definition and constructed association")
		measurements.panelLayout = layout(snapshot.Text)
		measurements.panelTextBytes = #snapshot.Text

		widget.Enabled = false
		waitFor(function() return snapshot.Text == "" end, 3, "closing the Relay Tools panel did not clear its text")
		phase = "plugin-rendering"
		measurements.reopenedUpdateMs = openAndRead()
		assert(contains(snapshot.Text, record.sessionId), "reopening Relay Tools did not refetch the current session")

		local originalValue = value.Value
		phase = "malformed-record-handling"
		widget.Enabled = false
		waitFor(function() return snapshot.Text == "" end, 3, "Relay Tools panel did not clear before malformed-record check")
		value.Value = "{"
		widget.Enabled = true
		waitFor(function()
			return contains(snapshot.Text, "Invalid structured inspector record: MalformedJson")
		end, 3, "Relay Tools did not display the malformed-record failure")
		measurements.malformedRecordFailClosed = true
		widget.Enabled = false
		waitFor(function() return snapshot.Text == "" end, 3, "Relay Tools did not clear malformed data on close")
		value.Value = originalValue
		widget.Enabled = true
		waitFor(function()
			return contains(snapshot.Text, record.sessionId)
		end, 3, "Relay Tools did not recover after a valid record replaced malformed text")
		widget.Enabled = false
		waitFor(function() return snapshot.Text == "" end, 3, "Relay Tools panel did not clear after UI recovery check")

		phase = "attachment-cleanup"
		session:Destroy()
		attachment:Destroy()
		assert(value.Parent == nil and ServerStorage:FindFirstChild("RelayStudioInspector_v1") == nil,
			"native UI fixture did not release its owned attachment root")
		return measurements
	end

	local ui = {
		small = exercise(1),
		large = exercise(64),
	}
	assert(not widget.Enabled and ServerStorage:FindFirstChild("RelayStudioInspector_v1") == nil,
		"native UI fixture did not end with its owned attachments cleaned up and panel closed")
	local retainedHeapAfterCleanupKb = heapKilobytes()
	local retainedHeapGrowthKb = if retainedHeapStartKb and retainedHeapAfterCleanupKb
		then retainedHeapAfterCleanupKb - retainedHeapStartKb else nil

	phase = "responsiveness-budget-checks"
	local baselineLarge = ui.large.baselineSnapshotFormat.maxMs
	local baselineLayoutLarge = ui.large.baselineTextLayout.maxMs
	local function heapGrowthBudget(baseline, minimum)
		return math.max(minimum, math.max(0, baseline.heapDeltaKb or 0) * 4 + 64)
	end
	local budgets = {
		currentSnapshotFormatMs = math.max(5, baselineLarge * 4),
		workspaceRenderMs = math.max(5, baselineLarge * 4),
		attachmentRefreshMs = math.max(10, baselineLarge * 4),
		textLayoutMs = math.max(16.7, baselineLayoutLarge * 4),
		visibleUpdateMs = math.max(50, (baselineLarge + baselineLayoutLarge) * 4),
		retainedStructuredRecordBytes = 65_536,
		retainedStructuredLiveTextBytes = 24_576,
		workspaceReportBytes = 4_194_304,
		workspaceVisibleTextBytes = 65_536,
		snapshotHeapGrowthKb = heapGrowthBudget(ui.large.baselineSnapshotFormat, 256),
		workspaceHeapGrowthKb = heapGrowthBudget(ui.large.baselineSnapshotFormat, 512),
		textLayoutHeapGrowthKb = heapGrowthBudget(ui.large.baselineTextLayout, 256),
		retainedHeapGrowthAfterCleanupKb = 1_024,
	}
	assert(ui.large.currentSnapshotFormat.maxMs <= budgets.currentSnapshotFormatMs,
		"64-endpoint snapshot formatter exceeded its baseline-derived budget")
	assert(ui.large.workspaceRender.maxMs <= budgets.workspaceRenderMs
		and ui.large.attachmentRefreshMs <= budgets.attachmentRefreshMs,
		"64-endpoint workspace render or attachment refresh exceeded its baseline-derived budget")
	assert(ui.large.currentTextLayout.maxMs <= budgets.textLayoutMs
		and ui.large.workspaceTextLayout.maxMs <= budgets.textLayoutMs,
		"64-endpoint TextService layout exceeded its baseline-derived budget")
	assert(ui.large.visibleUpdateMs <= budgets.visibleUpdateMs and ui.large.reopenedUpdateMs <= budgets.visibleUpdateMs,
		"64-endpoint visible update exceeded its baseline-derived budget")
	assert(ui.large.structuredRecordBytes <= budgets.retainedStructuredRecordBytes
		and ui.large.structuredLiveTextBytes <= budgets.retainedStructuredLiveTextBytes
		and ui.large.workspaceReportBytes <= budgets.workspaceReportBytes
		and ui.large.workspaceTextBytes <= budgets.workspaceVisibleTextBytes,
		"64-endpoint retained Studio UI data exceeded its declared bound")
	assert(ui.large.baselineSnapshotFormat.heapDeltaKb ~= nil and ui.large.currentSnapshotFormat.heapDeltaKb ~= nil
		and ui.large.workspaceRender.heapDeltaKb ~= nil and ui.large.baselineTextLayout.heapDeltaKb ~= nil
		and ui.large.currentTextLayout.heapDeltaKb ~= nil and ui.large.workspaceTextLayout.heapDeltaKb ~= nil
		and retainedHeapGrowthKb ~= nil, "Studio heap-growth observations are unavailable")
	assert(math.max(0, ui.large.currentSnapshotFormat.heapDeltaKb) <= budgets.snapshotHeapGrowthKb
		and math.max(0, ui.large.workspaceRender.heapDeltaKb) <= budgets.workspaceHeapGrowthKb
		and math.max(0, ui.large.currentTextLayout.heapDeltaKb) <= budgets.textLayoutHeapGrowthKb
		and math.max(0, ui.large.workspaceTextLayout.heapDeltaKb) <= budgets.textLayoutHeapGrowthKb
		and math.max(0, retainedHeapGrowthKb) <= budgets.retainedHeapGrowthAfterCleanupKb,
		"64-endpoint Studio heap growth exceeded its baseline-derived budget")

	phase = "native-multiplayer"
	task.wait(5)
	local ok, nativeResult = pcall(function()
		return StudioTestService:ExecuteMultiplayerTestAsync(1, { launchId = launchId })
	end)
	if not ok then error("Studio multiplayer test failed: " .. tostring(nativeResult)) end
	phase = "success-receipt"
	return {
		launchId = launchId,
		legMode = legMode,
		pluginArtifactSha256 = pluginArtifactSha256,
		ok = true,
		studioVersion = version(),
		plugin = {
			widgetName = widget.Name,
			title = widget.Title,
			titleMatchingWidgetCount = matchingTitleCount,
			completeWidgetMatchCount = #widgets,
			modulesExecuted = true,
			controls = { "ImportReport", "NextView", "NextSession", "NextSample", "EndpointFilter", "Snapshot" },
		},
		runService = runServiceContext,
		ui = ui,
		budgets = budgets,
		heap = {
			metric = "gcinfo net heap growth in the shared Studio VM; affected by collection timing, not per-operation allocation attribution",
			retainedStartKb = retainedHeapStartKb,
			retainedAfterCleanupKb = retainedHeapAfterCleanupKb,
			retainedGrowthKb = retainedHeapGrowthKb,
			attachmentsCleaned = true,
			panelClosed = true,
		},
		nativeResult = nativeResult,
	}
end

local runOk, result = pcall(runQualification)
local envelope
if runOk then
	envelope = result
else
	envelope = {
		launchId = launchId,
		legMode = legMode,
		pluginArtifactSha256 = pluginArtifactSha256,
		studioVersion = version(),
		runService = runServiceContext,
		ok = false,
		phase = phase,
		failure = {
			message = boundedString(result, 512),
			details = failureDetails,
		},
	}
end

local encodeOk, payload = pcall(function() return HttpService:JSONEncode(envelope) end)
if not encodeOk or type(payload) ~= "string" or #payload > 65_536 then
	envelope = {
		launchId = launchId,
		legMode = legMode,
		pluginArtifactSha256 = pluginArtifactSha256,
		studioVersion = version(),
		runService = runServiceContext,
		ok = false,
		phase = "result-encoding",
		failure = { message = "Studio result was not JSON-encodable within the 65536-byte receipt limit" },
	}
	payload = HttpService:JSONEncode(envelope)
end
local requestOk, response = pcall(function()
	return HttpService:RequestAsync({
		Url = reportUrl,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = payload,
	})
end)
local responseOk = requestOk and type(response) == "table" and response.Success == true and response.StatusCode == 204
local responseFailure = if requestOk then response and response.StatusMessage or "empty HTTP response" else response
assert(responseOk, "Studio tooling result egress failed: " .. boundedString(responseFailure, 256))
