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
assert(#launchId == 32 and string.match(launchId, "^[0-9a-f]+$"), "invalid native tooling launch ID")
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
local bootstrapPath = evidenceDirectory .. "/bootstrap.luau"
local outputPath = evidenceDirectory .. "/studio.log"
local receiptPath = evidenceDirectory .. "/receipt.json"
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

local terminalBody
local listener
local port
for candidate = 49_320, 49_351 do
	local ok, handle = pcall(net.serve, candidate, {
		address = "http://127.0.0.1",
		handleRequest = function(request)
			if terminalBody ~= nil or request.method ~= "POST" or request.path ~= "/" .. launchId
				or type(request.body) ~= "string" or #request.body > 65_536 then
				return { status = 404, body = "" }
			end
			terminalBody = request.body
			return { status = 204, body = "" }
		end,
	})
	if ok then listener = handle; port = candidate; break end
end
assert(listener ~= nil, "native tooling result listener unavailable")

local template = fs.readFile(studioTools .. "/Bootstrap.template.luau")
local reportUrl = "http://127.0.0.1:" .. tostring(port) .. "/" .. launchId
local bootstrap = string.gsub(template, "__REPORT_URL__", function() return string.format("%q", reportUrl) end)
bootstrap = string.gsub(bootstrap, "__LAUNCH_ID__", function() return string.format("%q", launchId) end)
assert(not string.find(bootstrap, "__REPORT_URL__", 1, true)
	and not string.find(bootstrap, "__LAUNCH_ID__", 1, true), "bootstrap placeholders were not resolved")
fs.writeFile(bootstrapPath, bootstrap)
local bootstrapDigest = "sha256:" .. serde.hash("sha256", bootstrap)
sourceManifest.projectSha256 = projectDigest
sourceManifest.bootstrapSha256 = bootstrapDigest
sourceManifest.placeSha256 = placeDigest
sourceManifest.pluginSha256 = pluginDigest
fs.writeFile(sourceManifestPath, serde.encode("json", sourceManifest, true))
local sourceManifestDigest = "sha256:" .. serde.hash("sha256", fs.readFile(sourceManifestPath))

Host.assertStudioIdle(process.os, process.exec)
local lease = Host.openStudioLease()
local child
local status
local stdoutDone = false
local stderrDone = false
local stdoutText = ""
local stderrText = ""
local launchPending = false
local killRequested = false
local installedPluginRemoved = false

local function drain(reader, key)
	local output = ""
	while true do
		local chunk = reader:read(1024)
		if chunk == nil then break end
		if #output < 65_536 then output ..= string.sub(chunk, 1, 65_536 - #output) end
	end
	if key == "stdout" then stdoutText = output; stdoutDone = true
	else stderrText = output; stderrDone = true end
end

local runOk, runFailure = pcall(function()
	Host.assertStudioIdle(process.os, process.exec)
	if not fs.isDir(pluginDirectory) then fs.writeDir(pluginDirectory) end
	fs.writeFile(installedPlugin, pluginBytes)
	lease.beginLaunch()
	launchPending = true
	child = process.create(studio, {
		"--task", "RunScript", "--localPlaceFile", placePath,
		"--runScriptFile", bootstrapPath, "--outputFile", outputPath, "--quitAfterExecution",
	}, { cwd = root })
	local ownedChild = child
	task.spawn(function() status = ownedChild:status() end)
	task.spawn(drain, ownedChild.stdout, "stdout")
	task.spawn(drain, ownedChild.stderr, "stderr")
	local deadline = os.clock() + 240
	while status == nil and os.clock() < deadline do task.wait(0.1) end
	if status == nil then
		killRequested = true
		pcall(function() ownedChild:kill() end)
		local killDeadline = os.clock() + 10
		while status == nil and os.clock() < killDeadline do task.wait(0.1) end
	end
	assert(status ~= nil, "Studio process exit was not observed")
	while not stdoutDone or not stderrDone do task.wait(0.05) end
	assert(status.ok == true and not killRequested,
		"Studio process failed; inspect " .. outputPath .. " stdout=" .. stdoutText .. " stderr=" .. stderrText)
	Host.assertStudioIdle(process.os, process.exec)
end)

listener:stop()
local idleOk = pcall(Host.assertStudioIdle, process.os, process.exec)
local childExited = status ~= nil and not killRequested
local safeCleanup = idleOk and (if launchPending then childExited else true)

if safeCleanup then
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
	if launchPending then
		lease.confirmTeardown(true, true, true)
		launchPending = false
	end
	lease.release()
else
	warn("Studio teardown is unconfirmed; retain the owned plugin and lease for inspection: " .. installedPlugin)
end

assert(runOk, tostring(runFailure))
assert(safeCleanup, "Studio process or idle teardown is unconfirmed")
local sourceAfter = Verification.sourceIdentity()
assert(not sourceAfter.dirty and sourceAfter.fingerprint == sourceBefore.fingerprint,
	"native qualification source changed after its prebuild identity capture")
assert("sha256:" .. serde.hash("sha256", fs.readFile(baselineModulePath)) == baselineSnapshotSourceSha256
	and "sha256:" .. serde.hash("sha256", fs.readFile(projectPath)) == projectDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(bootstrapPath)) == bootstrapDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(placePath)) == placeDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(pluginArtifact)) == pluginDigest
	and "sha256:" .. serde.hash("sha256", fs.readFile(sourceManifestPath)) == sourceManifestDigest,
	"native qualification input artifact changed after prebuild capture")

local outputBytes = Host.outputFileSize(outputPath, process.os, process.exec)
assert(outputBytes <= Host.MAX_OUTPUT_LOG_BYTES, "Studio output file exceeded its capture cap")
assert(terminalBody ~= nil, "Studio native result missing; inspect " .. outputPath)
local envelope = serde.decode("json", terminalBody)
assert(type(envelope) == "table" and envelope.launchId == launchId,
	"invalid native tooling result envelope")
assert(envelope.plugin and envelope.plugin.title == "Relay Tools" and envelope.plugin.modulesExecuted == true,
	"actual Relay Tools plugin UI was not observed")
assert(type(envelope.plugin.controls) == "table" and #envelope.plugin.controls == 6,
	"actual Relay Tools controls were incomplete")
assert(type(envelope.ui) == "table" and envelope.ui.small.endpointCount == 1
	and envelope.ui.large.endpointCount == 64 and envelope.ui.large.malformedRecordFailClosed == true,
	"native plugin responsiveness/retention observation is incomplete")
assert(type(envelope.budgets) == "table" and envelope.budgets.currentSnapshotFormatMs > 0
	and envelope.budgets.workspaceRenderMs > 0 and envelope.budgets.attachmentRefreshMs > 0
	and envelope.budgets.textLayoutMs > 0 and envelope.budgets.visibleUpdateMs > 0
	and envelope.budgets.snapshotHeapGrowthKb >= 256
	and envelope.budgets.textLayoutHeapGrowthKb >= 256
	and envelope.budgets.retainedHeapGrowthAfterCleanupKb == 1_024,
	"baseline-derived UI and sampling budgets were not captured")
assert(type(envelope.heap) == "table" and envelope.heap.attachmentsCleaned == true
	and envelope.heap.panelClosed == true and envelope.heap.retainedGrowthKb ~= nil
	and type(envelope.heap.metric) == "string"
	and string.find(envelope.heap.metric, "not per-operation allocation attribution", 1, true) ~= nil,
	"Studio heap-growth observation or cleanup endstate is incomplete")
assert(type(envelope.nativeResult) == "string", "Studio multiplayer test returned no server result")
local native = serde.decode("json", envelope.nativeResult)
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
		and side.historyCount >= 2 and side.elapsed >= 0.9 and side.elapsed <= 3,
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
	source = {
		revision = sourceBefore.revision,
		fingerprint = sourceBefore.fingerprint,
		postRunFingerprint = sourceAfter.fingerprint,
		exactSourceUnchanged = true,
		identityScope = "all tracked and non-ignored untracked Git files",
		manifestPath = sourceManifestPath,
		sourceManifestSha256 = sourceManifestDigest,
		projectSha256 = projectDigest,
		bootstrapSha256 = bootstrapDigest,
		placeSha256 = placeDigest,
		pluginSha256 = pluginDigest,
		baselineCommit = baselineCommit,
		baselineSnapshotSourceSha256 = baselineSnapshotSourceSha256,
	},
	toolchain = {
		studioExecutable = studio,
		studioVersion = envelope.studioVersion,
		lune = command("lune", { "--version" }),
		rojo = command("rojo", { "--version" }),
		architecture = process.arch,
		processor = process.env.PROCESSOR_IDENTIFIER,
		logicalProcessors = tonumber(process.env.NUMBER_OF_PROCESSORS),
	},
	plugin = envelope.plugin,
	ui = envelope.ui,
	budgets = envelope.budgets,
	heap = envelope.heap,
	native = native,
	process = {
		status = status,
		stdout = stdoutText,
		stderr = stderrText,
		outputPath = outputPath,
		ownedLocalPluginRemoved = installedPluginRemoved,
		studioIdleAfterExit = idleOk,
	},
}
fs.writeFile(receiptPath, serde.encode("json", receipt, true))
assert(installedPluginRemoved, "owned local plugin file was not cleaned up after Studio exit")
print("PASS Relay Studio Tools native qualification: " .. receiptPath)
