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

	local idleHeapStartKb = heapKilobytes()
	local idleWaitStartedAt = os.clock()
	task.wait(5)
	local idleWaitSeconds = os.clock() - idleWaitStartedAt
	local idleHeapAfterWaitKb = heapKilobytes()
	local idleHeapGrowthKb = if idleHeapStartKb and idleHeapAfterWaitKb
		then idleHeapAfterWaitKb - idleHeapStartKb else nil
	local retainedHeapStartKb = idleHeapAfterWaitKb

	local function exercise(count)
		phase = "registration-and-snapshot"
		if runServiceContext.isStudio ~= true or runServiceContext.isServer ~= true then
			failureDetails = { runService = runServiceContext }
			error("native UI registration requires Studio and server RunService context")
		end
		local definition = Definition.create(Relay, count)
		local report, inspectProblem = Relay.inspect(definition)
		assert(report ~= nil, inspectProblem and inspectProblem.message or "native schema inspection failed")
		local registrationStarted = os.clock()
		local session, attachment, attachProblem = Registration.createServer(Relay, definition,
			{
				namespace = "native_ui",
				inboundRate = {
					perPlayer = { capacity = 16, refillPerSecond = 8 },
					aggregate = { capacity = 128, refillPerSecond = 64 },
				},
			}, metadata)
		local registrationAndAttachmentMs = (os.clock() - registrationStarted) * 1_000
		if session == nil or attachment == nil or attachProblem ~= nil then
			local problemCode = if type(attachProblem) == "table" and type(attachProblem.code) == "string"
				then boundedString(attachProblem.code, 80) else nil
			failureDetails = {
				runService = runServiceContext,
				registrationAndAttachmentMs = registrationAndAttachmentMs,
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
			registrationAndAttachmentMs = registrationAndAttachmentMs,
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

		local refreshCalls = {}
		local refreshSampledCallCount = 0
		local refreshMaxCallMs = 0
		local nonSamplingRefreshMaxCallMs = 0
		local lastDecodedRecord = record
		local lastDecodeProblem
		local function observeRecord()
			local observed, problem = Structured.decode(function(bytes)
				return HttpService:JSONDecode(bytes)
			end, value.Value)
			if observed ~= nil then
				lastDecodedRecord = observed
				lastDecodeProblem = nil
			else
				lastDecodeProblem = problem
			end
			return observed
		end
		local function refreshObservation()
			local nonSamplingCallCount = #refreshCalls - refreshSampledCallCount
			return {
				method = "Attachment.Refresh invocation",
				measurementKind = "explicit method-call duration only",
				calls = refreshCalls,
				callCount = #refreshCalls,
				sampledCallCount = refreshSampledCallCount,
				nonSamplingCallCount = nonSamplingCallCount,
				maxCallDurationMs = refreshMaxCallMs,
				maxNonSamplingCallDurationMs = nonSamplingRefreshMaxCallMs,
				automaticSamplerCpuMeasured = false,
			}
		end
		local function sampleObservation(candidate, waitSeconds)
			local history = if type(candidate) == "table" and type(candidate.history) == "table"
				then candidate.history else {}
			local scalars = if type(candidate) == "table" and type(candidate.scalars) == "table"
				then candidate.scalars else nil
			return {
				sessionId = if type(candidate) == "table" then candidate.sessionId else nil,
				association = if type(candidate) == "table" then candidate.association else nil,
				side = if scalars ~= nil then scalars.side else nil,
				state = if scalars ~= nil then scalars.state else nil,
				historyCount = #history,
				lastHistoryEntry = if #history > 0 then boundedString(history[#history], 512) else nil,
				elapsed = if type(candidate) == "table" then candidate.elapsed else nil,
				waitSeconds = waitSeconds,
				encodedBytes = #value.Value,
				decodeProblem = if lastDecodeProblem ~= nil then boundedString(lastDecodeProblem, 80) else nil,
			}
		end
		local function refreshAndObserve()
			assert(#refreshCalls < 32, "native Refresh observation exceeded its 32-call bound")
			local started = os.clock()
			local sampled = attachment:Refresh()
			local durationMs = (os.clock() - started) * 1_000
			table.insert(refreshCalls, { durationMs = durationMs, sampled = sampled })
			refreshMaxCallMs = math.max(refreshMaxCallMs, durationMs)
			if sampled then
				refreshSampledCallCount += 1
			else
				nonSamplingRefreshMaxCallMs = math.max(nonSamplingRefreshMaxCallMs, durationMs)
			end
			return observeRecord()
		end

		local sampleStartedAt = os.clock()
		local sampleDeadline = sampleStartedAt + 3
		local refreshed = record
		local secondSampleObserved = false
		repeat
			refreshed = refreshAndObserve()
			secondSampleObserved = type(refreshed) == "table"
				and type(refreshed.history) == "table" and #refreshed.history >= 2
			if secondSampleObserved or os.clock() >= sampleDeadline or #refreshCalls >= 32 then break end
			task.wait(0.1)
		until false
		local sampleWaitSeconds = os.clock() - sampleStartedAt
		if secondSampleObserved and refreshCalls[#refreshCalls].sampled and #refreshCalls < 32 then
			refreshed = refreshAndObserve()
		end
		local refreshMetrics = refreshObservation()
		local validSecondSample = type(refreshed) == "table" and secondSampleObserved
			and refreshed.sessionId == record.sessionId
			and refreshed.format == 2 and refreshed.association == "constructed"
			and refreshed.identityStatus == "application-supplied"
			and type(refreshed.scalars) == "table" and refreshed.scalars.side == "Server"
			and refreshed.scalars.state == "Created"
			and type(refreshed.inspection) == "table" and type(refreshed.inspection.events) == "table"
			and #refreshed.inspection.events == count
			and type(refreshed.history) == "table" and #refreshed.history >= 2
			and #refreshed.history <= Snapshot.MAX_HISTORY_SAMPLES
			and type(refreshed.elapsed) == "number" and refreshed.elapsed >= 0.9
			and type(sampleWaitSeconds) == "number" and sampleWaitSeconds >= 0 and sampleWaitSeconds < math.huge
			and type(refreshed.liveText) == "string"
			and #value.Value <= Snapshot.MAX_BYTES
		if not validSecondSample then
			failureDetails = {
				runService = runServiceContext,
				registrationAndAttachmentMs = registrationAndAttachmentMs,
				sampleObservation = sampleObservation(refreshed or lastDecodedRecord, sampleWaitSeconds),
				refreshObservation = refreshMetrics,
			}
			error("native attachment did not retain a second valid bounded history sample")
		end
		measurements.attachmentRefreshMaxCallMs = refreshMetrics.maxCallDurationMs
		measurements.attachmentRefresh = refreshMetrics
		measurements.sampleObservation = sampleObservation(refreshed, sampleWaitSeconds)
		measurements.structuredRecordBytes = #value.Value
		measurements.structuredLiveTextBytes = #refreshed.liveText

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
	local settlementStartedAt = os.clock()
	task.wait(5)
	local settlementWaitSeconds = os.clock() - settlementStartedAt
	local retainedHeapAfterSettlementKb = heapKilobytes()
	local retainedHeapGrowthAfterSettlementKb = if retainedHeapStartKb and retainedHeapAfterSettlementKb
		then retainedHeapAfterSettlementKb - retainedHeapStartKb else nil

	local baselineLarge = ui.large.baselineSnapshotFormat.maxMs
	local baselineLayoutLarge = ui.large.baselineTextLayout.maxMs
	local function heapGrowthBudget(baseline, minimum)
		return math.max(minimum, math.max(0, baseline.heapDeltaKb or 0) * 4 + 64)
	end
	local budgets = {
		currentSnapshotFormatMs = math.max(5, baselineLarge * 4),
		workspaceRenderMs = math.max(5, baselineLarge * 4),
		registrationAndAttachmentMs = math.max(10, baselineLarge * 4),
		attachmentRefreshMs = math.max(10, baselineLarge * 4),
		nonSamplingRefreshCallMs = math.max(10, baselineLarge * 4),
		automaticSamplerCpuMeasured = false,
		textLayoutMs = math.max(16.7, baselineLayoutLarge * 4),
		visibleUpdateMs = math.max(50, (baselineLarge + baselineLayoutLarge) * 4),
		retainedStructuredRecordBytes = 65_536,
		retainedStructuredLiveTextBytes = 24_576,
		workspaceReportBytes = 4_194_304,
		workspaceVisibleTextBytes = 65_536,
		snapshotHeapGrowthKb = heapGrowthBudget(ui.large.baselineSnapshotFormat, 256),
		workspaceHeapGrowthKb = heapGrowthBudget(ui.large.baselineSnapshotFormat, 512),
		textLayoutHeapGrowthKb = heapGrowthBudget(ui.large.baselineTextLayout, 256),
		retainedHeapGrowthAfterSettlementKb = 1_024,
	}
	local idleHeapStatus = if idleHeapGrowthKb == nil then "unavailable"
		elseif math.abs(idleHeapGrowthKb) > budgets.retainedHeapGrowthAfterSettlementKb then "inconclusive"
		else "stable"
	local heapMetrics = {
		metric = "gcinfo net heap growth in the shared Studio VM; immediate and post-5s-settle readings are affected by collection timing, not per-operation allocation attribution",
		idleStartKb = idleHeapStartKb,
		idleAfterWaitKb = idleHeapAfterWaitKb,
		idleGrowthKb = idleHeapGrowthKb,
		idleWaitSeconds = idleWaitSeconds,
		idleStatus = idleHeapStatus,
		retainedStartKb = retainedHeapStartKb,
		retainedAfterCleanupKb = retainedHeapAfterCleanupKb,
		retainedGrowthKb = retainedHeapGrowthKb,
		settlementWaitSeconds = settlementWaitSeconds,
		retainedAfterSettlementKb = retainedHeapAfterSettlementKb,
		retainedGrowthAfterSettlementKb = retainedHeapGrowthAfterSettlementKb,
		attachmentsCleaned = true,
		panelClosed = true,
	}
	local function heapBudgetCheck(value, budget)
		local available = type(value) == "number"
		local observedKb = if available then math.max(0, value) else 0
		return {
			available = available,
			observedKb = observedKb,
			limitKb = budget,
			exceeded = available and observedKb > budget,
		}
	end
	local heapBudgetChecks = {
		idleBeforeTool = heapBudgetCheck(if idleHeapGrowthKb then math.abs(idleHeapGrowthKb) else nil,
			budgets.retainedHeapGrowthAfterSettlementKb),
		currentSnapshotFormat = heapBudgetCheck(ui.large.currentSnapshotFormat.heapDeltaKb, budgets.snapshotHeapGrowthKb),
		workspaceRender = heapBudgetCheck(ui.large.workspaceRender.heapDeltaKb, budgets.workspaceHeapGrowthKb),
		currentTextLayout = heapBudgetCheck(ui.large.currentTextLayout.heapDeltaKb, budgets.textLayoutHeapGrowthKb),
		workspaceTextLayout = heapBudgetCheck(ui.large.workspaceTextLayout.heapDeltaKb, budgets.textLayoutHeapGrowthKb),
		retainedAfterSettlement = heapBudgetCheck(
			retainedHeapGrowthAfterSettlementKb, budgets.retainedHeapGrowthAfterSettlementKb),
	}
	local responsiveness = {
		ui = ui,
		budgets = budgets,
		heap = heapMetrics,
		heapBudgetChecks = heapBudgetChecks,
	}
	failureDetails = {
		runService = runServiceContext,
		responsiveness = responsiveness,
	}
	phase = "native-multiplayer"
	local marker = {
		kind = "RelayToolsResponsivenessV1",
		version = 1,
		launchId = launchId,
		pluginArtifactSha256 = pluginArtifactSha256,
		phase = "before-native-multiplayer",
		ui = ui,
		budgets = budgets,
		heap = heapMetrics,
		heapBudgetChecks = heapBudgetChecks,
	}
	local markerPayload = HttpService:JSONEncode(marker)
	assert(#markerPayload <= 32_768, "native responsiveness marker exceeded its 32768-byte bound")
	print("RELAY_TOOLING_RESPONSIVENESS_V1 " .. markerPayload)
	local nativeOk, nativeResult = pcall(function()
		return StudioTestService:ExecuteMultiplayerTestAsync(1, { launchId = launchId })
	end)
	if not nativeOk then
		local nativeFailure = if type(nativeResult) == "string" then boundedString(nativeResult, 512)
			else "Studio multiplayer test failed"
		responsiveness.nativeFailure = nativeFailure
		error("Studio multiplayer test failed: " .. nativeFailure)
	end
	responsiveness.nativeResult = nativeResult
	phase = "responsiveness-budget-checks"

	assert(ui.large.currentSnapshotFormat.maxMs <= budgets.currentSnapshotFormatMs,
		"64-endpoint snapshot formatter exceeded its baseline-derived budget")
	assert(ui.large.workspaceRender.maxMs <= budgets.workspaceRenderMs
		and ui.large.registrationAndAttachmentMs <= budgets.registrationAndAttachmentMs
		and ui.large.attachmentRefreshMaxCallMs <= budgets.attachmentRefreshMs
		and ui.large.attachmentRefresh.nonSamplingCallCount > 0
		and ui.large.attachmentRefresh.maxNonSamplingCallDurationMs <= budgets.nonSamplingRefreshCallMs,
		"64-endpoint workspace, registration, or explicit Refresh invocation exceeded its baseline-derived budget")
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
		and retainedHeapGrowthKb ~= nil and retainedHeapGrowthAfterSettlementKb ~= nil,
		"Studio heap-growth observations are unavailable")
	assert(heapMetrics.idleStatus == "stable",
		"shared Studio VM idle heap drift makes the retained growth observation inconclusive")
	assert(math.max(0, ui.large.currentSnapshotFormat.heapDeltaKb) <= budgets.snapshotHeapGrowthKb
		and math.max(0, ui.large.workspaceRender.heapDeltaKb) <= budgets.workspaceHeapGrowthKb
		and math.max(0, ui.large.currentTextLayout.heapDeltaKb) <= budgets.textLayoutHeapGrowthKb
		and math.max(0, ui.large.workspaceTextLayout.heapDeltaKb) <= budgets.textLayoutHeapGrowthKb
		and math.max(0, retainedHeapGrowthAfterSettlementKb) <= budgets.retainedHeapGrowthAfterSettlementKb,
		"64-endpoint Studio heap growth exceeded its baseline-derived budget")

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
		heap = heapMetrics,
		heapBudgetChecks = heapBudgetChecks,
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
