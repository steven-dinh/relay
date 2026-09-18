local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Catalog = require("../host/ExternalAdapterCatalog")
local Instrumentation = require("./ReceiveInstrumentation")

local PROJECT_PATH = ".tmp/relay-quick.project.json"
local PLACE_PATH = ".tmp/relay-quick.rbxlx"
local DEFAULT_IDS = { "native-reliable", "relay-reliable" }
local USAGE = "usage: lune run benchmarks/quick/build.luau [--profile-receive] [--all | --adapters <id,id,...>]"

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

local function parseArgs(arguments: { string }): (boolean, { string }?, boolean)
	if #arguments == 0 then return false, table.clone(DEFAULT_IDS), false end
	local profile, all, ids = false, false, nil
	local index = 1
	while index <= #arguments do
		local argument = arguments[index]
		if argument == "--profile-receive" then
			assert(not profile, "duplicate --profile-receive")
			profile = true
			index += 1
		elseif argument == "--all" then
			assert(not all and ids == nil, "--all cannot be combined with --adapters")
			all = true
			index += 1
		elseif argument == "--adapters" then
			assert(ids == nil and not all and index < #arguments, USAGE)
			ids = parseIds(arguments[index + 1])
			index += 2
		else
			assert(false, USAGE)
		end
	end
	assert(not (all and profile), "--profile-receive cannot be combined with --all")
	if ids == nil and not all then ids = table.clone(DEFAULT_IDS) end
	return profile, ids, all
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

local function validateProfileCase(): string
	local config = require("./Config")
	local caseId = config.caseId
	assert(caseId == "state-broadcast-s2c" or caseId == "state-broadcast-burst-s2c",
		"--profile-receive requires caseId state-broadcast-s2c or state-broadcast-burst-s2c")
	return caseId
end

local function addNormalAdapters(project: any, ids: { string })
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
		local template = { ["$className"] = "Folder", Library = library }
		if selected.endpointPath ~= nil then
			template.Endpoint = { ["$path"] = "../benchmarks/" .. selected.endpointPath }
		end
		project.tree.ServerStorage.RelayQuickTemplates[id] = template
		-- Rojo resolves an init.luau module through its containing directory.
		local adapterPath = string.gsub(selected.adapterPath, "/init%.luau$", "")
		benchmark.adapters[id] = { ["$path"] = "../benchmarks/" .. adapterPath }
	end
end

local function buildNormal(ids: { string })
	local project = serde.decode("json", fs.readFile("benchmarks/quick/quick.project.json"))
	prefixPaths(project, "../benchmarks/quick/")
	addNormalAdapters(project, ids)
	fs.writeDir(".tmp")
	fs.writeFile(PROJECT_PATH, serde.encode("json", project, true) .. "\n")
	local result = process.exec("rojo", { "build", PROJECT_PATH, "--output", PLACE_PATH })
	assert(result.ok, `Rojo build failed ({result.code})\n{result.stdout}\n{result.stderr}`)
	print(`Built {PLACE_PATH} for {table.concat(ids, ", ")}`)
	print(`Open in Studio and press F5 with one client. Rojo iteration: rojo serve {PROJECT_PATH}`)
end

local function buildProfile(ids: { string })
	local caseId = validateProfileCase()
	for _, id in ids do
		assert(id == "native-reliable" or id == "relay-reliable",
			"--profile-receive supports only native-reliable and relay-reliable")
	end
	local profileRoot = uniqueProfileRoot()
	local records = Instrumentation.copyProfileSources(process.cwd, profileRoot)
	local project = serde.decode("json", fs.readFile("benchmarks/quick/quick.project.json"))
	Instrumentation.configureProfileProject(project, ids)
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
		mode = "receive-callback",
		profileReceive = true,
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
	print(`Built {placePath} for {table.concat(ids, ", ")} (receive profile)`)
	print(`Profile project: {projectPath}`)
	print(`Profile manifest: {manifestPath}`)
	print("Open the profiled place in Studio and press F5 with one client.")
end

if #process.args == 1 and process.args[1] == "--help" then
	print(USAGE)
	return
end

assert(fs.isFile("benchmarks/quick/quick.project.json"), "run the quick build from the Relay repository root")
local profile, ids, all = parseArgs(process.args)
if all then
	local selected = table.clone(DEFAULT_IDS)
	for _, id in Catalog.ids do
		if Catalog.isSupported(id) then table.insert(selected, id) end
	end
	-- Acquisition's module also handles --all as its download CLI. Normalize in
	-- a subprocess so requiring its verification helpers never starts acquisition.
	local result = process.exec("lune", { "run", "benchmarks/quick/build.luau", "--adapters", table.concat(selected, ",") })
	assert(result.ok, `quick build failed ({result.code})\n{result.stdout}\n{result.stderr}`)
	print(string.gsub(result.stdout, "\n$", ""))
	return
end

assert(ids ~= nil, "internal adapter selection error")
if profile then buildProfile(ids) else buildNormal(ids) end
