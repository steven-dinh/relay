local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Catalog = require("../host/ExternalAdapterCatalog")
local Instrumentation = require("./ReceiveInstrumentation")

local PROJECT_PATH = ".tmp/relay-quick.project.json"
local PLACE_PATH = ".tmp/relay-quick.rbxlx"
local DEFAULT_IDS = { "native-reliable", "relay-reliable" }
local USAGE = "usage: lune run benchmarks/quick/build.luau [--profile-receive [--libmp <pinned LibMP.luau>]] [--category booleans|strings|numbers|vectors|mixed|all] [--all | --adapters <id,id,...>]"

local function parseIds(value: string): { string }
	local ids, seen = {}, {}
	for id in string.gmatch(value, "[^,]+") do
		assert(id == "native-reliable" or id == "relay-reliable" or Catalog.isSupported(id),
			`unsupported quick benchmark adapter: {id}`)
		assert(not seen[id], `duplicate quick benchmark adapter: {id}`)
		seen[id] = true
		table.insert(ids, id)
	end
	assert(#ids > 0 and table.concat(ids, ",") == value, "provide adapter IDs separated by commas without spaces")
	return ids
end

local function parseArgs(arguments: { string }): (boolean, { string }?, boolean, string?, string?)
	if #arguments == 0 then return false, table.clone(DEFAULT_IDS), false, nil, nil end
	local profile, all, ids, category = false, false, nil, nil
	local libmpPath = nil
	local index = 1
	while index <= #arguments do
		local argument = arguments[index]
		if argument == "--profile-receive" then
			assert(not profile, "duplicate --profile-receive")
			profile = true
			index += 1
		elseif argument == "--libmp" then
			assert(libmpPath == nil and index < #arguments, USAGE)
			libmpPath = arguments[index + 1]
			index += 2
		elseif argument == "--all" then
			assert(not all and ids == nil, "--all cannot be combined with --adapters")
			all = true
			index += 1
		elseif argument == "--adapters" then
			assert(ids == nil and not all and index < #arguments, USAGE)
			ids = parseIds(arguments[index + 1])
			index += 2
		elseif argument == "--category" then
			assert(category == nil and index < #arguments, USAGE)
			category = arguments[index + 1]
			index += 2
		else
			assert(false, USAGE)
		end
	end
	assert(not (all and profile), "--profile-receive cannot be combined with --all")
	assert(libmpPath == nil or profile, "--libmp requires --profile-receive")
	if category ~= nil then
		require("./Model").coreCategoryCases(category)
		assert(not profile, "core category suites do not support receive profiling")
	end
	if ids == nil and not all then ids = table.clone(DEFAULT_IDS) end
	return profile, ids, all, category, libmpPath
end

local function prefixPaths(node: any, prefix: string)
	if type(node) ~= "table" then return end
	for key, value in node do
		if key == "$path" then
			node[key] = prefix .. value
		else
			prefixPaths(value, prefix)
		end
	end
end

local function uniqueProfileRoot(): string
	fs.writeDir(".tmp")
	for attempt = 1, 12 do
		local token = string.sub(serde.hash("sha256", `{os.clock()}:{tostring({})}:{attempt}`), 1, 16)
		local root = `.tmp/relay-quick-profile-{token}`
		if not fs.isDir(root) and not fs.isFile(root) then
			return root
		end
	end
	error("could not reserve a unique receive profile build directory", 0)
end

local function validateProfileCase(): (string, { kind: string, direction: string? })
	local config = require("./Config")
	local caseId = config.caseId
	local model = require("./Model")
	local selection = model.selection(config)
	assert(model.receiveProfileCases[caseId] == true,
		"--profile-receive requires a Tiny/State C2S, State S2C, or schema-composite-c2s workload")
	return caseId, selection
end

local function addNormalAdapters(project: any, ids: { string }, coreEnabled: boolean)
	local benchmark = project.tree.ReplicatedStorage.RelayBenchmark
	benchmark.QuickAdapters["$properties"].Value = table.concat(ids, ",")
	local acquisition, lock, generated
	for _, id in ids do
		if not Catalog.isExternal(id) then continue end
		if acquisition == nil then
			acquisition = require("../../scripts/acquire-benchmark-libraries")
			lock = acquisition.validateLock(serde.decode("json", fs.readFile("benchmarks/libraries.lock.json")))
		end
		local selected = Catalog.selected(lock, id)
		acquisition.verifyInstalled(selected.library)
		local library = selected.libraryProject
		if selected.generatedId ~= nil then
			if generated == nil then generated = require("../host/GeneratedAdapters") end
			generated.verifyGenerated(selected.generatedId)
			library = {
				["$className"] = "Folder",
				Server = { ["$path"] = `generated/{id}/Server.luau` },
				Client = { ["$path"] = `generated/{id}/Client.luau` },
				Types = { ["$path"] = `generated/{id}/Types.luau` },
			}
		end
		prefixPaths(library, "../benchmarks/")
		local attributes = { QuickBroadcastMode = selected.broadcastMode }
		if coreEnabled then attributes.QuickCore = true end
		local template = {
			["$className"] = "Folder",
			["$attributes"] = attributes,
			Library = library,
		}
		if selected.endpointPath ~= nil then
			template.Endpoint = { ["$path"] = "../benchmarks/" .. selected.endpointPath }
		end
		project.tree.ServerStorage.RelayQuickTemplates[id] = template
		-- Rojo resolves an init.luau module through its containing directory.
		local adapterPath = string.gsub(selected.adapterPath, "/init%.luau$", "")
		benchmark.adapters[id] = { ["$path"] = "../benchmarks/" .. adapterPath }
	end
end

local function buildNormal(ids: { string }, category: string?)
	local project = serde.decode("json", fs.readFile("benchmarks/quick/quick.project.json"))
	prefixPaths(project, "../benchmarks/quick/")
	local coreCases = if category then require("./Model").coreCategoryCases(category) else {}
	project.tree.ReplicatedStorage.RelayBenchmark.Quick.QuickCoreCases["$properties"].Value = table.concat(coreCases, ",")
	addNormalAdapters(project, ids, #coreCases > 0)
	fs.writeDir(".tmp")
	fs.writeFile(PROJECT_PATH, serde.encode("json", project, true) .. "\n")
	local result = process.exec("rojo", { "build", PROJECT_PATH, "--output", PLACE_PATH })
	assert(result.ok, `Rojo build failed ({result.code})\n{result.stdout}\n{result.stderr}`)
	print(`Built {PLACE_PATH} for {table.concat(ids, ", ")}`)
	print(`Open in Studio and press F5 with one client. Rojo iteration: rojo serve {PROJECT_PATH}`)
end

local function buildProfile(ids: { string }, libmpPath: string?)
	local caseId, selection = validateProfileCase()
	if caseId == "schema-composite-c2s" then
		assert(#ids == 1 and ids[1] == "relay-reliable",
			"schema-composite-c2s receive profiling requires exactly one relay-reliable adapter")
	end
	for _, id in ids do
		assert(id == "native-reliable" or id == "relay-reliable",
			"--profile-receive supports only native-reliable and relay-reliable")
	end
	local libmp, sdkSource
	if libmpPath ~= nil then
		assert(selection.direction == "ClientToServer" and selection.kind == "Workload",
			"--libmp currently supports client-to-server workloads only")
		libmp = require("./CpuProfile")
		sdkSource = fs.readFile(libmpPath)
		assert(serde.hash("sha256", sdkSource) == libmp.SDK_SHA256, "LibMP SDK does not match the pinned revision")
	end
	local profileRoot = uniqueProfileRoot()
	local records = Instrumentation.copyProfileSources(process.cwd, profileRoot, sdkSource ~= nil)
	local project = serde.decode("json", fs.readFile("benchmarks/quick/quick.project.json"))
	Instrumentation.configureProfileProject(project, ids)
	if sdkSource ~= nil then
		project.tree.ReplicatedStorage.RelayBenchmark.Quick.ProfileCpu["$properties"].Value = true
		fs.writeFile(profileRoot .. "/source/Quick/LibMPSdk.luau", sdkSource, { overwrite = false })
		records["source/Quick/LibMPSdk.luau"] = {
			sourceSha256 = libmp.SDK_SHA256, generatedSha256 = libmp.SDK_SHA256,
			sourceSize = #sdkSource, generatedSize = #sdkSource,
		}
		project.tree.ReplicatedStorage.RelayBenchmark.Quick.LibMPSdk = { ["$path"] = "source/Quick/LibMPSdk.luau" }
	end
	Instrumentation.assertProfileMappings(project)
	local projectPath = profileRoot .. "/quick.project.json"
	local placePath = profileRoot .. "/relay-quick-receive-profile.rbxlx"
	local projectBody = serde.encode("json", project, true) .. "\n"
	fs.writeFile(projectPath, projectBody, { overwrite = false })
	local manifestPath = profileRoot .. "/manifest.json"
	local result = process.exec("rojo", { "build", projectPath, "--output", placePath })
	assert(result.ok, `Rojo profile build failed ({result.code})\n{result.stdout}\n{result.stderr}`)
	local manifest = {
		schema = "relay-quick-receive-profile-v1",
		mode = if libmp then "receive-callback+libmp-cpu" else "receive-callback",
		profileReceive = true,
		libmp = if libmp then {
			revision = libmp.SDK_REVISION, sha256 = libmp.SDK_SHA256, dataFormat = libmp.FORMAT,
			mode = "client-presimulation+server-receive", stageMarkers = true,
			captureFrames = 16, scanFrames = 8,
			containerFormat = "Compressed",
			rankingQualified = false, timingQualified = false,
		} else nil,
		maxEventsPerPhase = 2400,
		caseId = caseId,
		adapters = ids,
		projectPath = projectPath,
		placePath = placePath,
		sources = records,
		bindings = Instrumentation.exactBindings(),
		artifacts = {
			project = Instrumentation.artifact(projectPath),
			place = Instrumentation.artifact(placePath),
		},
	}
	fs.writeFile(manifestPath, serde.encode("json", manifest, true) .. "\n", { overwrite = false })
	print(`Built {placePath} for {table.concat(ids, ", ")} ({manifest.mode} profile)`)
	print(`Profile project: {projectPath}`)
	print(`Profile manifest: {manifestPath}`)
	print("Open the profiled place in Studio and press F5 with one client.")
end

if #process.args == 1 and process.args[1] == "--help" then
	print(USAGE)
	return
end

assert(fs.isFile("benchmarks/quick/quick.project.json"), "run the quick build from the Relay repository root")
local profile, ids, all, category, libmpPath = parseArgs(process.args)
if all then
	local selected = table.clone(DEFAULT_IDS)
	for _, id in Catalog.ids do
		if Catalog.isSupported(id) then table.insert(selected, id) end
	end
	-- Acquisition's module also handles --all as its download CLI. Normalize in
	-- a subprocess so requiring its verification helpers never starts acquisition.
	local arguments = { "run", "benchmarks/quick/build.luau", "--adapters", table.concat(selected, ",") }
	if category then table.insert(arguments, "--category"); table.insert(arguments, category) end
	local result = process.exec("lune", arguments)
	assert(result.ok, `quick build failed ({result.code})\n{result.stdout}\n{result.stderr}`)
	print(string.gsub(result.stdout, "\n$", ""))
	return
end

assert(ids ~= nil, "internal adapter selection error")
if profile then buildProfile(ids, libmpPath) else buildNormal(ids, category) end
