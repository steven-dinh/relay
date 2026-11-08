local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Host = require("../benchmarks/host/HostRuntime")
local Verification = require("../scripts/Verification")

local args = process.args
assert(#args == 2 and args[1] == "--studio", "expected --studio <absolute Studio executable>")
local studio = args[2]
assert(process.os == "windows" and string.match(studio, "^%a:[/\\]") and fs.isFile(studio),
	"an absolute Windows Studio executable is required")

local root = string.gsub(process.cwd, "\\", "/")
local studioTools = root .. "/tests/studio/tooling"
assert(fs.isDir(studioTools), "native tooling fixture is missing")
if not fs.isDir(root .. "/.tmp") then fs.writeDir(root .. "/.tmp") end

local function command(program, arguments)
	local result = process.exec(program, arguments, { cwd = root })
	assert(type(result) == "table" and result.ok == true, program .. " failed: " .. tostring(result.stderr))
	return string.gsub(result.stdout or "", "[\r\n]+$", "")
end

local launchId = Host.randomHex(16, process.os, process.exec)
local controlLaunchId = Host.randomHex(16, process.os, process.exec)
assert(#launchId == 32 and string.match(launchId, "^[0-9a-f]+$"), "invalid native tooling launch ID")
assert(#controlLaunchId == 32 and string.match(controlLaunchId, "^[0-9a-f]+$")
	and controlLaunchId ~= launchId, "invalid preinstall control launch ID")
local evidenceDirectory = root .. "/.tmp/tooling-native-" .. launchId
assert(not fs.isDir(evidenceDirectory) and not fs.isFile(evidenceDirectory), "native evidence path already exists")
fs.writeDir(evidenceDirectory)
local sourceManifestPath = evidenceDirectory .. "/source-identity.json"

local baselineCommit = "1a334399232cb8d9844092113efc09b7d17a813a"
local baselinePath = "scripts/studio-inspector/Snapshot.luau"
local baselineResult = process.exec("git", { "show", baselineCommit .. ":" .. baselinePath }, { cwd = root })
assert(baselineResult.ok and type(baselineResult.stdout) == "string", "pinned inspector baseline source unavailable")
local baselineSource = baselineResult.stdout
local baselineModulePath = evidenceDirectory .. "/BaselineSnapshot.luau"
fs.writeFile(baselineModulePath, baselineSource)
local baselineSnapshotSourceSha256 = "sha256:" .. serde.hash("sha256", baselineSource)
local sourceBefore = Verification.sourceIdentity()
assert(not sourceBefore.dirty, "native qualification requires a frozen clean source commit")
local sourceManifest = {
	identity = sourceBefore,
	baselineCommit = baselineCommit,
	baselinePath = baselinePath,
	baselineSnapshotSourceSha256 = baselineSnapshotSourceSha256,
}
fs.writeFile(sourceManifestPath, serde.encode("json", sourceManifest, true))

local placePath = evidenceDirectory .. "/tooling-native.rbxlx"
local pluginArtifact = evidenceDirectory .. "/RelayToolsQualification.rbxmx"
local projectPath = evidenceDirectory .. "/tooling-native.project.json"
local controlBootstrapPath = evidenceDirectory .. "/bootstrap-control.luau"
local qualificationBootstrapPath = evidenceDirectory .. "/bootstrap-qualification.luau"
local controlOutputPath = evidenceDirectory .. "/studio-control.log"
local outputPath = evidenceDirectory .. "/studio-qualification.log"
local receiptPath = evidenceDirectory .. "/receipt.json"
local rawControlResultPath = evidenceDirectory .. "/preinstall-control-result.json"
local rawResultPath = evidenceDirectory .. "/native-result.json"
local project = serde.decode("json", fs.readFile(studioTools .. "/default.project.json"))
local tree = project.tree
tree.ReplicatedStorage.Relay["$path"] = "../../src"
tree.ReplicatedStorage.RelayTools.Attachment["$path"] = "../../scripts/studio-inspector/Attachment.luau"
tree.ReplicatedStorage.RelayTools.Registration["$path"] = "../../scripts/studio-inspector/Registration.luau"
tree.ReplicatedStorage.RelayTools.Snapshot["$path"] = "../../scripts/studio-inspector/Snapshot.luau"
tree.ReplicatedStorage.RelayTools.Structured["$path"] = "../../scripts/studio-inspector/Structured.luau"
tree.ReplicatedStorage.RelayTools.BaselineSnapshot = { ["$path"] = "BaselineSnapshot.luau" }
tree.ReplicatedStorage.RelayToolingUI.ToolingResult["$path"] = "../../scripts/tooling/Result.luau"
tree.ReplicatedStorage.RelayToolingUI.ToolingProject["$path"] = "../../scripts/tooling/Project.luau"
tree.ReplicatedStorage.RelayToolingUI.Workspace["$path"] = "../../scripts/studio-inspector/Workspace.luau"
tree.ReplicatedStorage.RelayToolingDefinition["$path"] = "../../tests/studio/tooling/Definition.luau"
tree.ServerScriptService.ToolingServer["$path"] = "../../tests/studio/tooling/Server.server.luau"
tree.StarterPlayer.StarterPlayerScripts.ToolingClient["$path"] = "../../tests/studio/tooling/Client.client.luau"
fs.writeFile(projectPath, serde.encode("json", project, true))
local projectDigest = "sha256:" .. serde.hash("sha256", fs.readFile(projectPath))
local placeBuild = process.exec("rojo", { "build", projectPath, "-o", placePath }, { cwd = root })
assert(placeBuild.ok and fs.isFile(placePath), "tooling fixture place build failed: " .. tostring(placeBuild.stderr))
local pluginBuild = process.exec("rojo", {
	"build", root .. "/scripts/studio-inspector/plugin.project.json", "-o", pluginArtifact,
}, { cwd = root })
assert(pluginBuild.ok and fs.isFile(pluginArtifact), "Relay Tools plugin build failed: " .. tostring(pluginBuild.stderr))

local pluginBytes = fs.readFile(pluginArtifact)
local pluginDigest = "sha256:" .. serde.hash("sha256", pluginBytes)
local placeDigest = "sha256:" .. serde.hash("sha256", fs.readFile(placePath))
local pluginXml = pluginBytes
for _, moduleName in { "Workspace", "ToolingResult", "ToolingProject", "Structured", "Diagnosis" } do
	assert(string.find(pluginXml, '<string name="Name">' .. moduleName .. "</string>", 1, true),
		"packaged plugin is missing child ModuleScript " .. moduleName)
end

local localAppData = process.env.LOCALAPPDATA
assert(type(localAppData) == "string" and #localAppData > 0, "LOCALAPPDATA is unavailable for local plugin qualification")
local pluginDirectory = string.gsub(localAppData, "\\", "/") .. "/Roblox/Plugins"
local installedPlugin = pluginDirectory .. "/RelayToolsQual-" .. launchId .. ".rbxmx"
assert(not fs.isFile(installedPlugin) and not fs.isDir(installedPlugin), "unique local plugin filename already exists")

local terminalBodies = {}
local listener
local port
local legByPath = {
	["/" .. controlLaunchId] = "control",
	["/" .. launchId] = "qualification",
}
for candidate = 49_320, 49_351 do
	local ok, handle = pcall(net.serve, candidate, {
		address = "http://127.0.0.1",
		handleRequest = function(request)
			local leg = if type(request.path) == "string" then legByPath[request.path] else nil
			if leg == nil or terminalBodies[leg] ~= nil or request.method ~= "POST"
				or type(request.body) ~= "string" or #request.body > 65_536 then
				return { status = 404, body = "" }
			end
			terminalBodies[leg] = request.body
			return { status = 204, body = "" }
		end,
	})
	if ok then listener = handle; port = candidate; break end
end
assert(listener ~= nil, "native tooling result listener unavailable")

local template = fs.readFile(studioTools .. "/Bootstrap.template.luau")
local reportBase = "http://127.0.0.1:" .. tostring(port)
local function materializeBootstrap(legMode, legId, path)
	local reportUrl = reportBase .. "/" .. legId
	local bootstrap = string.gsub(template, "__REPORT_URL__", function() return string.format("%q", reportUrl) end)
	bootstrap = string.gsub(bootstrap, "__LAUNCH_ID__", function() return string.format("%q", legId) end)
	bootstrap = string.gsub(bootstrap, "__LEG_MODE__", function() return string.format("%q", legMode) end)
	bootstrap = string.gsub(bootstrap, "__PLUGIN_SHA256__", function() return string.format("%q", pluginDigest) end)
	for _, placeholder in { "__REPORT_URL__", "__LAUNCH_ID__", "__LEG_MODE__", "__PLUGIN_SHA256__" } do
		assert(not string.find(bootstrap, placeholder, 1, true), "bootstrap placeholder was not resolved: " .. placeholder)
	end
	fs.writeFile(path, bootstrap)
	return "sha256:" .. serde.hash("sha256", bootstrap)
end

local controlBootstrapDigest = materializeBootstrap("control", controlLaunchId, controlBootstrapPath)
local qualificationBootstrapDigest = materializeBootstrap("qualification", launchId, qualificationBootstrapPath)
sourceManifest.projectSha256 = projectDigest
sourceManifest.controlBootstrapSha256 = controlBootstrapDigest
sourceManifest.qualificationBootstrapSha256 = qualificationBootstrapDigest
sourceManifest.placeSha256 = placeDigest
sourceManifest.pluginSha256 = pluginDigest
fs.writeFile(sourceManifestPath, serde.encode("json", sourceManifest, true))
local sourceManifestDigest = "sha256:" .. serde.hash("sha256", fs.readFile(sourceManifestPath))

Host.assertStudioIdle(process.os, process.exec)
local lease = Host.openStudioLease()
local leaseLaunchPending = false
local installedPluginCreated = false
local installedPluginRemoved = false

local function drain(reader)
	local output = ""
	local truncated = false
	while true do
		local chunk = reader:read(1024)
		if chunk == nil then break end
		local remaining = 65_536 - #output
		if remaining > 0 then
			output ..= string.sub(chunk, 1, remaining)
			if #chunk > remaining then truncated = true end
		else
			truncated = true
		end
	end
	return output, truncated
end

local function runStudioLeg(leg, legId, bootstrapPath, outputPath, rawResultPath, installPlugin)
	Host.assertStudioIdle(process.os, process.exec)
	if installPlugin then
		assert(not fs.isFile(installedPlugin) and not fs.isDir(installedPlugin),
			"unique qualification plugin path changed before installation")
		if not fs.isDir(pluginDirectory) then fs.writeDir(pluginDirectory) end
		fs.writeFile(installedPlugin, pluginBytes)
		installedPluginCreated = true
	else
		assert(not fs.isFile(installedPlugin) and not fs.isDir(installedPlugin),
			"preinstall control cannot run while the qualification plugin file exists")
	end
	local child
	local status
	local stdoutDone = false
	local stderrDone = false
	local stdoutText = ""
	local stderrText = ""
	local stdoutTruncated = false
	local stderrTruncated = false
	local killRequested = false
	lease.beginLaunch()
	leaseLaunchPending = true
	child = process.create(studio, {
		"--task", "RunScript", "--localPlaceFile", placePath,
		"--runScriptFile", bootstrapPath, "--outputFile", outputPath, "--quitAfterExecution",
	}, { cwd = root })
	local ownedChild = child
	task.spawn(function() status = ownedChild:status() end)
	local stdoutThread = task.spawn(function()
		stdoutText, stdoutTruncated = drain(ownedChild.stdout)
		stdoutDone = true
	end)
	local stderrThread = task.spawn(function()
		stderrText, stderrTruncated = drain(ownedChild.stderr)
		stderrDone = true
	end)
	local deadline = os.clock() + 240
	while status == nil and os.clock() < deadline do task.wait(0.1) end
	if status == nil then
		killRequested = true
		pcall(function() ownedChild:kill() end)
		local killDeadline = os.clock() + 10
		while status == nil and os.clock() < killDeadline do task.wait(0.1) end
	end
	if status == nil or killRequested then
		if terminalBodies[leg] ~= nil then fs.writeFile(rawResultPath, terminalBodies[leg]) end
		pcall(task.cancel, stdoutThread)
		pcall(task.cancel, stderrThread)
		local reason = if status == nil then "Studio process exit was not observed" else "Studio process required forced termination"
		error(reason .. "; inspect " .. outputPath)
	end
	local drainDeadline = os.clock() + 10
	while (not stdoutDone or not stderrDone) and os.clock() < drainDeadline do task.wait(0.05) end
	local stdoutDrainComplete = stdoutDone
	local stderrDrainComplete = stderrDone
	if not stdoutDrainComplete then pcall(task.cancel, stdoutThread) end
	if not stderrDrainComplete then pcall(task.cancel, stderrThread) end
	local childExited = status ~= nil and not killRequested
	local idleOk = pcall(Host.assertStudioIdle, process.os, process.exec)
	local pluginCleaned = true
	if installPlugin and childExited and idleOk then
		if fs.isFile(installedPlugin) then
			if "sha256:" .. serde.hash("sha256", fs.readFile(installedPlugin)) == pluginDigest then
				local removed, removeFailure = pcall(fs.removeFile, installedPlugin)
				installedPluginRemoved = removed and not fs.isFile(installedPlugin)
				if not installedPluginRemoved then warn("Owned local plugin cleanup failed: " .. tostring(removeFailure)) end
			else
				warn("Owned local plugin changed; preserved for inspection: " .. installedPlugin)
			end
		else
			installedPluginRemoved = true
		end
		pluginCleaned = installedPluginRemoved
	end
	if childExited and idleOk and pluginCleaned then
		lease.confirmTeardown(true, true, true)
		leaseLaunchPending = false
	end
	if terminalBodies[leg] ~= nil then fs.writeFile(rawResultPath, terminalBodies[leg]) end
	assert(childExited and idleOk and pluginCleaned,
		"Studio teardown or owned plugin cleanup is unconfirmed; inspect " .. outputPath)
	assert(status.ok == true, "Studio process failed; inspect " .. outputPath
		.. " stdout=" .. stdoutText .. " stderr=" .. stderrText)
	return {
		status = status,
		stdout = stdoutText,
		stderr = stderrText,
		stdoutDrainComplete = stdoutDrainComplete,
		stderrDrainComplete = stderrDrainComplete,
		stdoutTruncated = stdoutTruncated,
		stderrTruncated = stderrTruncated,
		pipeDrainTimeoutSeconds = 10,
		outputPath = outputPath,
		bootstrapPath = bootstrapPath,
		bootstrapSha256 = if leg == "control" then controlBootstrapDigest else qualificationBootstrapDigest,
		pluginFileInstalledForLeg = installPlugin,
		studioIdleAfterExit = idleOk,
		ownedPluginRemovedAfterExit = if installPlugin then installedPluginRemoved else true,
		leg = leg,
		launchId = legId,
	}
end

local controlFacts
local qualificationFacts
local controlEnvelope
local qualificationEnvelope
local runOk, runFailure = pcall(function()
	controlFacts = runStudioLeg("control", controlLaunchId, controlBootstrapPath,
		controlOutputPath, rawControlResultPath, false)
	assert(terminalBodies.control ~= nil,
		"preinstall control result missing; inspect " .. controlOutputPath .. " and " .. rawControlResultPath)
	controlEnvelope = serde.decode("json", terminalBodies.control)
	assert(type(controlEnvelope) == "table" and controlEnvelope.launchId == controlLaunchId
		and controlEnvelope.legMode == "control" and controlEnvelope.pluginArtifactSha256 == pluginDigest,
		"preinstall control receipt identity mismatch; raw result: " .. rawControlResultPath)
	assert(controlEnvelope.ok == true,
		"preinstall control failed during " .. tostring(controlEnvelope.phase) .. ": "
			.. tostring(controlEnvelope.failure and controlEnvelope.failure.message)
			.. "; raw result: " .. rawControlResultPath)
	assert(type(controlEnvelope.preinstall) == "table"
		and controlEnvelope.preinstall.completeWidgetMatchCount == 0,
		"preinstall control found an existing complete Relay Tools widget; raw result: " .. rawControlResultPath)
	assert(terminalBodies.qualification == nil, "preinstall receipt occupied the qualification nonce path")

	qualificationFacts = runStudioLeg("qualification", launchId, qualificationBootstrapPath,
		outputPath, rawResultPath, true)
	assert(terminalBodies.qualification ~= nil,
		"qualification result missing; inspect " .. outputPath .. " and " .. rawResultPath)
	qualificationEnvelope = serde.decode("json", terminalBodies.qualification)
	assert(type(qualificationEnvelope) == "table" and qualificationEnvelope.launchId == launchId
		and qualificationEnvelope.legMode == "qualification"
		and qualificationEnvelope.pluginArtifactSha256 == pluginDigest,
		"qualification receipt identity mismatch; raw result: " .. rawResultPath)
	assert(qualificationEnvelope.ok == true,
		"Studio tooling fixture failed during " .. tostring(qualificationEnvelope.phase)
			.. ": " .. tostring(qualificationEnvelope.failure and qualificationEnvelope.failure.message)
			.. "; raw result: " .. rawResultPath)
end)

listener:stop()
local finalIdleOk = pcall(Host.assertStudioIdle, process.os, process.exec)
local safeCleanup = finalIdleOk and not leaseLaunchPending
if safeCleanup then
	if fs.isFile(installedPlugin) then
		if installedPluginCreated and "sha256:" .. serde.hash("sha256", fs.readFile(installedPlugin)) == pluginDigest then
			local removed, removeFailure = pcall(fs.removeFile, installedPlugin)
			installedPluginRemoved = removed and not fs.isFile(installedPlugin)
			if not installedPluginRemoved then warn("Owned local plugin cleanup failed: " .. tostring(removeFailure)) end
		else
			warn("Owned local plugin changed; preserved for inspection: " .. installedPlugin)
		end
	else
		installedPluginRemoved = true
	end
	safeCleanup = installedPluginRemoved
	if safeCleanup then lease.release() end
else
	warn("Studio teardown is unconfirmed; retain owned files and lease for inspection: " .. installedPlugin)
end

assert(safeCleanup, "Studio process, idle teardown, or owned plugin cleanup is unconfirmed")
assert(runOk, tostring(runFailure))
assert(controlFacts ~= nil and qualificationFacts ~= nil,
	"both preinstall control and qualification legs must complete")
assert(controlFacts.leg == "control" and controlFacts.launchId == controlLaunchId
	and controlFacts.pluginFileInstalledForLeg == false
	and controlFacts.bootstrapSha256 == controlBootstrapDigest
	and qualificationFacts.leg == "qualification" and qualificationFacts.launchId == launchId
	and qualificationFacts.pluginFileInstalledForLeg == true
	and qualificationFacts.bootstrapSha256 == qualificationBootstrapDigest
	and controlFacts.status.ok == true and qualificationFacts.status.ok == true,
	"native leg process, bootstrap, or installation identities do not match")
local sourceAfter = Verification.sourceIdentity()
assert(not sourceAfter.dirty and sourceAfter.fingerprint == sourceBefore.fingerprint,
	"native qualification source changed after its prebuild identity capture")
assert("sha256:" .. serde.hash("sha256", fs.readFile(baselineModulePath)) == baselineSnapshotSourceSha256
	and "sha256:" .. serde.hash("sha256", fs.readFile(projectPath)) == projectDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(controlBootstrapPath)) == controlBootstrapDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(qualificationBootstrapPath)) == qualificationBootstrapDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(placePath)) == placeDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(pluginArtifact)) == pluginDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(sourceManifestPath)) == sourceManifestDigest,
	"native qualification input artifact changed after prebuild capture")

local outputBytes = Host.outputFileSize(outputPath, process.os, process.exec)
assert(outputBytes <= Host.MAX_OUTPUT_LOG_BYTES, "Studio output file exceeded its capture cap")

local controlOutputBytes = Host.outputFileSize(controlOutputPath, process.os, process.exec)
assert(controlOutputBytes <= Host.MAX_OUTPUT_LOG_BYTES, "Studio control output file exceeded its capture cap")
assert(type(controlEnvelope.preinstall.pluginGuiServiceChildren) == "table"
	and type(controlEnvelope.preinstall.pluginGuiServiceChildren.entries) == "table"
	and #controlEnvelope.preinstall.pluginGuiServiceChildren.entries <= 16,
	"preinstall PluginGuiService census exceeded its declared bound")
assert(qualificationEnvelope.plugin and qualificationEnvelope.plugin.widgetName ~= nil
	and qualificationEnvelope.plugin.title == "Relay Tools"
	and qualificationEnvelope.plugin.modulesExecuted == true
	and qualificationEnvelope.plugin.titleMatchingWidgetCount >= 1
	and qualificationEnvelope.plugin.completeWidgetMatchCount == 1,
	"actual unique Relay Tools plugin UI was not observed")
assert(type(qualificationEnvelope.plugin.widgetName) == "string"
	and qualificationEnvelope.studioVersion == controlEnvelope.studioVersion,
	"qualification plugin or Studio identity is incomplete or differs from the control leg")
assert(type(qualificationEnvelope.plugin.controls) == "table" and #qualificationEnvelope.plugin.controls == 6,
	"actual Relay Tools controls were incomplete")
assert(type(qualificationEnvelope.ui) == "table" and qualificationEnvelope.ui.small.endpointCount == 1
	and qualificationEnvelope.ui.large.endpointCount == 64
	and qualificationEnvelope.ui.large.malformedRecordFailClosed == true,
	"native plugin responsiveness/retention observation is incomplete")
assert(type(qualificationEnvelope.budgets) == "table" and qualificationEnvelope.budgets.currentSnapshotFormatMs > 0
	and qualificationEnvelope.budgets.workspaceRenderMs > 0 and qualificationEnvelope.budgets.attachmentRefreshMs > 0
	and qualificationEnvelope.budgets.textLayoutMs > 0 and qualificationEnvelope.budgets.visibleUpdateMs > 0
	and qualificationEnvelope.budgets.snapshotHeapGrowthKb >= 256
	and qualificationEnvelope.budgets.textLayoutHeapGrowthKb >= 256
	and qualificationEnvelope.budgets.retainedHeapGrowthAfterSettlementKb == 1_024,
	"baseline-derived UI and sampling budgets were not captured")
assert(type(qualificationEnvelope.heap) == "table" and qualificationEnvelope.heap.attachmentsCleaned == true
	and qualificationEnvelope.heap.panelClosed == true
	and qualificationEnvelope.heap.idleStartKb ~= nil
	and qualificationEnvelope.heap.idleAfterWaitKb ~= nil
	and qualificationEnvelope.heap.idleGrowthKb ~= nil
	and qualificationEnvelope.heap.idleStatus == "stable"
	and type(qualificationEnvelope.heap.idleWaitSeconds) == "number"
	and qualificationEnvelope.heap.idleWaitSeconds >= 4.9
	and qualificationEnvelope.heap.idleWaitSeconds <= 10
	and qualificationEnvelope.heap.retainedAfterCleanupKb ~= nil
	and qualificationEnvelope.heap.retainedGrowthKb ~= nil
	and type(qualificationEnvelope.heap.settlementWaitSeconds) == "number"
	and qualificationEnvelope.heap.settlementWaitSeconds >= 0
	and qualificationEnvelope.heap.settlementWaitSeconds < math.huge
	and qualificationEnvelope.heap.retainedAfterSettlementKb ~= nil
	and qualificationEnvelope.heap.retainedGrowthAfterSettlementKb ~= nil
	and type(qualificationEnvelope.heap.metric) == "string"
	and string.find(qualificationEnvelope.heap.metric, "not per-operation allocation attribution", 1, true) ~= nil,
	"Studio heap-growth observation or cleanup endstate is incomplete")
assert(type(qualificationEnvelope.heapBudgetChecks) == "table"
	and type(qualificationEnvelope.heapBudgetChecks.idleBeforeTool) == "table"
	and qualificationEnvelope.heapBudgetChecks.idleBeforeTool.available == true
	and qualificationEnvelope.heapBudgetChecks.idleBeforeTool.exceeded == false
	and qualificationEnvelope.heapBudgetChecks.idleBeforeTool.limitKb == 1_024,
	"Studio idle heap observation was unstable or its budget was not preserved")
assert(type(qualificationEnvelope.nativeResult) == "string", "Studio multiplayer test returned no server result")
local native = serde.decode("json", qualificationEnvelope.nativeResult)
assert(type(native) == "table" and native.kind == "RelayToolsNativeQualification"
	and native.version == 1 and native.ok == true and type(native.server) == "table",
	"native server/client attachment proof failed")
assert(native.server.small.endpointCount == 1 and native.server.large.endpointCount == 64
	and native.server.clientProofCode == 127 and native.server.replacementIdChanged == true
	and native.server.terminalSamplerStopped == true and native.server.attachmentCleanup == true
	and native.server.malformedJsonRejected == true and type(native.server.clientChecks) == "table"
	and #native.server.clientChecks == 7,
	"native server/client lifecycle assertions were incomplete")
for _, side in { native.server.small, native.server.large } do
	assert(side.encodedBytes > 0 and side.encodedBytes <= 65_536
		and side.liveTextBytes > 0 and side.liveTextBytes <= 24_576
		and side.historyCount >= 2 and side.historyCount <= 16 and side.elapsed >= 0.9
		and type(side.sampleWaitSeconds) == "number" and side.sampleWaitSeconds >= 0
		and side.sampleWaitSeconds < math.huge,
		"native server retained a malformed or oversized structured snapshot")
end
for index, check in { "PlayerScriptsPlacement", "ConstructedV2Association", "EndpointRoster",
	"OneSecondSampling", "TerminalCleanup", "ReplacementIdentity", "MalformedJsonRejected" } do
	assert(native.server.clientChecks[index] == check, "native client proof omitted " .. check)
end

local receipt = {
	kind = "RelayToolsNativeQualification",
	version = 1,
	status = if installedPluginRemoved then "passed" else "failed",
	launchId = launchId,
	controlLaunchId = controlLaunchId,
	preinstallControl = {
		launchId = controlEnvelope.launchId,
		legMode = controlEnvelope.legMode,
		pluginArtifactSha256 = controlEnvelope.pluginArtifactSha256,
		studioVersion = controlEnvelope.studioVersion,
		matchingTitleCount = controlEnvelope.preinstall.matchingTitleCount,
		completeWidgetMatchCount = controlEnvelope.preinstall.completeWidgetMatchCount,
	},
	source = {
		revision = sourceBefore.revision,
		fingerprint = sourceBefore.fingerprint,
		postRunFingerprint = sourceAfter.fingerprint,
		exactSourceUnchanged = true,
		identityScope = "all tracked and non-ignored untracked Git files",
		manifestPath = sourceManifestPath,
		sourceManifestSha256 = sourceManifestDigest,
		projectSha256 = projectDigest,
		controlBootstrapSha256 = controlBootstrapDigest,
		qualificationBootstrapSha256 = qualificationBootstrapDigest,
		placeSha256 = placeDigest,
		pluginSha256 = pluginDigest,
		baselineCommit = baselineCommit,
		baselineSnapshotSourceSha256 = baselineSnapshotSourceSha256,
	},
	toolchain = {
		studioExecutable = studio,
		studioVersion = qualificationEnvelope.studioVersion,
		preinstallStudioVersion = controlEnvelope.studioVersion,
		lune = command("lune", { "--version" }),
		rojo = command("rojo", { "--version" }),
		architecture = process.arch,
		processor = process.env.PROCESSOR_IDENTIFIER,
		logicalProcessors = tonumber(process.env.NUMBER_OF_PROCESSORS),
	},
	plugin = qualificationEnvelope.plugin,
	pluginArtifactSha256 = pluginDigest,
	preinstallControlResultPath = rawControlResultPath,
	nativeResultPath = rawResultPath,
	ui = qualificationEnvelope.ui,
	budgets = qualificationEnvelope.budgets,
	heap = qualificationEnvelope.heap,
	native = native,
	process = {
		control = controlFacts,
		qualification = qualificationFacts,
		ownedLocalPluginRemoved = installedPluginRemoved,
		studioIdleAfterExit = finalIdleOk,
	},
}
fs.writeFile(receiptPath, serde.encode("json", receipt, true))
assert(installedPluginRemoved, "owned local plugin file was not cleaned up after Studio exit")
print("PASS Relay Studio Tools native qualification: " .. receiptPath)
