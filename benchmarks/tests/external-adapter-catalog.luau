local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Catalog = require("../host/ExternalAdapterCatalog")
local Acquisition = require("../../scripts/acquire-benchmark-libraries")

local function expectError(code, callback)
	local ok, message = pcall(callback)
	assert(not ok and message == code, `expected {code}, got {tostring(message)}`)
end

local expected = {
	quicknet = { "Runtime", "AdapterFanOut", 1 },
	bytenet = { "Runtime", "NativeBroadcast", 1 },
	satset = { "Runtime", "NativeBroadcast", 1 },
	warp = { "Runtime", "AdapterFanOut", 1 },
	blink = { "Generated", "AdapterFanOut", 0 },
	zap = { "Generated", "AdapterFanOut", 0 },
	["netray-compile"] = { "Generated", "NativeBroadcast", 0 },
}

assert(#Catalog.ids == 8 and Catalog.ids[8] == "suphi-packet", "closed external catalog changed")
assert(Catalog.isExternal("suphi-packet") and not Catalog.isSupported("suphi-packet"),
	"Suphi must remain catalogued but unsupported")
assert(not Catalog.isExternal("unknown") and not Catalog.isSupported("unknown"), "unknown adapter admitted")

local lock = Acquisition.validateLock(serde.decode("json", fs.readFile("benchmarks/libraries.lock.json")))
local digest = "sha256:" .. string.rep("a", 64)
for id, semantics in expected do
	local selected = Catalog.selected(lock, id)
	local adapter = Catalog.adapter(selected, digest, "0.737.0.7371584")
	assert(adapter.moduleId == id and adapter.artifact.kind == "RepositoryModule"
		and adapter.artifact.digest == digest, `{id} artifact changed`)
	local identity = adapter.identity
	assert(identity.id == id and identity.lane == "EquivalentSemantics"
		and identity.integrationKind == semantics[1], `{id} identity changed`)
	assert(identity.library.version == selected.library.tag
		and identity.library.provenance.sourceRepository == selected.library.repository
		and identity.library.provenance.revision == selected.library.revision
		and identity.library.provenance.license == selected.library.license
		and identity.library.provenance.checksum == digest, `{id} lock provenance changed`)
	assert(identity.semantics.broadcastMode == semantics[2]
		and identity.semantics.intentionalAddedDeliveryFrames == semantics[3]
		and identity.semantics.repetitionIsolation == "ProcessRestart", `{id} semantics changed`)
end
expectError("HOST_E_EXTERNAL_UNSUPPORTED_SUPHI_FRAME_BOUND", function()
	Catalog.selected(lock, "suphi-packet")
end)
expectError("HOST_E_EXTERNAL_ADAPTER", function() Catalog.selected(lock, "unknown") end)

local baseProject = serde.decode("json", fs.readFile("benchmarks/event-v1.project.json"))
local quicknet = Catalog.composeProject(baseProject, Catalog.selected(lock, "quicknet"), "./selected.luau")
assert(quicknet.tree.HttpService["$properties"].HttpEnabled == false, "external project enabled HTTP")
assert(quicknet.tree.ReplicatedStorage.Relay == nil, "external project retained Relay")
local adapters = quicknet.tree.ReplicatedStorage.RelayBenchmark.adapters
assert(adapters.NativeReliable == nil and adapters.RelayReliable == nil
	and adapters.ExternalSelected["$path"] == "./selected.luau"
	and adapters.ExternalAdapter["$path"] == "../benchmarks/adapters/ExternalAdapter.luau",
	"external project adapter bindings changed")
assert(quicknet.tree.ReplicatedStorage.RelayBenchmark.Runner.ExternalReadiness["$path"]
	== "../benchmarks/runner/ExternalReadiness.luau", "readiness mapping missing")
local quickTemplate = quicknet.tree.ServerStorage.RelayBenchmarkServer.ExternalTemplate
assert(quickTemplate.Library["$path"] == "../benchmarks/vendor/quicknet/src/QuickNet.luau"
	and quickTemplate.Endpoint == nil, "QuickNet template changed")
assert(quicknet.tree.ReplicatedStorage.RelayBenchmark.contracts["$path"] == "../benchmarks/contracts",
	"dynamic project paths were not rebased")

local warp = Catalog.composeProject(baseProject, Catalog.selected(lock, "warp"), "./selected.luau")
assert(warp.tree.ServerStorage.RelayBenchmarkServer.ExternalTemplate.Endpoint["$path"]
	== "../benchmarks/adapters/warp/Endpoint.luau", "Warp endpoint mapping missing")
local blink = Catalog.composeProject(baseProject, Catalog.selected(lock, "blink"), "./selected.luau")
local generated = blink.tree.ServerStorage.RelayBenchmarkServer.ExternalTemplate.Library
assert(generated["$className"] == "Folder"
	and generated.Server["$path"] == "../benchmarks/generated/blink/Server.luau"
	and generated.Client["$path"] == "../benchmarks/generated/blink/Client.luau"
	and generated.Types["$path"] == "../benchmarks/generated/blink/Types.luau",
	"generated library template changed")

for _, id in { "quicknet", "warp", "blink" } do
	local selected = Catalog.selected(lock, id)
	local token = string.sub(serde.hash("sha256", `{id}:{os.clock()}:{tostring({})}`), 1, 16)
	local projectPath = `.tmp/external-catalog-{id}-{token}.project.json`
	local bindingPath = `.tmp/external-catalog-{id}-{token}.binding.luau`
	local placePath = `.tmp/external-catalog-{id}-{token}.rbxlx`
	local project = Catalog.composeProject(baseProject, selected, `./external-catalog-{id}-{token}.binding.luau`)
	fs.writeFile(projectPath, serde.encode("json", project), { overwrite = false })
	fs.writeFile(bindingPath, fs.readFile(`benchmarks/{selected.adapterPath}`), { overwrite = false })
	local ok, result = pcall(function()
		local built = process.exec("rojo", { "build", projectPath, "--output", placePath })
		assert(built.ok and fs.isFile(placePath) and #fs.readFile(placePath) > 0,
			`dynamic external project did not build for {id}: {built.stderr}`)
		local dataModel = roblox.deserializePlace(fs.readFile(placePath))
		local benchmark = dataModel:FindFirstChild("ReplicatedStorage"):FindFirstChild("RelayBenchmark")
		local mappedAdapters = benchmark:FindFirstChild("adapters")
		assert(mappedAdapters:FindFirstChild("ExternalSelected") ~= nil
			and mappedAdapters:FindFirstChild("ExternalAdapter") ~= nil
			and mappedAdapters:FindFirstChild("AdapterContract") ~= nil
			and mappedAdapters:FindFirstChild("NativeReliable") == nil
			and mappedAdapters:FindFirstChild("RelayReliable") == nil,
			`dynamic external adapter mapping changed for {id}`)
		assert(benchmark:FindFirstChild("Runner"):FindFirstChild("ExternalReadiness") ~= nil
			and benchmark:FindFirstChild("contracts"):FindFirstChild("internal")
				:FindFirstChild("RepetitionFragmentV1") ~= nil,
			`dynamic process-repetition mapping missing for {id}`)
		local mappedTemplate = dataModel:FindFirstChild("ServerStorage"):FindFirstChild("RelayBenchmarkServer")
			:FindFirstChild("ExternalTemplate")
		assert(mappedTemplate ~= nil and mappedTemplate:FindFirstChild("Library") ~= nil,
			`server-only external template missing for {id}`)
	end)
	if fs.isFile(placePath) then fs.removeFile(placePath) end
	if fs.isFile(bindingPath) then fs.removeFile(bindingPath) end
	if fs.isFile(projectPath) then fs.removeFile(projectPath) end
	if not ok then error(result, 0) end
end

print("PASS Relay.EventV1.ExternalAdapterCatalog")
