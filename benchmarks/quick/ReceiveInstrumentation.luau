--!strict

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local M = {}

local RELAY_CALLBACK = [[function(endpointId, ...)
                receive("Reliable", endpointId, ...)
            end]]
local RELAY_BINDING = "observe(remote.OnClientEvent, " .. RELAY_CALLBACK .. ")"
local NATIVE_BINDING = "child.OnClientEvent:Connect(deliverClient)"
local PROFILE_REQUIRE = 'local CallbackTiming = require(game:GetService("ReplicatedStorage"):WaitForChild("RelayBenchmark"):WaitForChild("Quick"):WaitForChild("CallbackTiming"))\n'

local function slash(path: string): string
	return string.gsub(path, "\\", "/")
end

local function join(left: string, right: string): string
	if left == "" then return right end
	left = string.gsub(left, "[\\/]+$", "")
	local separator = if string.find(left, "\\", 1, true) ~= nil then "\\" else "/"
	right = string.gsub(right, "[\\/]", separator)
	return left .. separator .. right
end

local function replaceExactly(source: string, needle: string, replacement: string, label: string): string
	local start, finish = string.find(source, needle, 1, true)
	assert(start ~= nil, `missing {label} binding`)
	assert(string.find(source, needle, finish + 1, true) == nil, `ambiguous {label} binding`)
	return string.sub(source, 1, start - 1) .. replacement .. string.sub(source, finish + 1)
end

local function addRequire(source: string, anchor: string, label: string): string
	return replaceExactly(source, anchor, anchor .. PROFILE_REQUIRE, label .. " require anchor")
end

local function fileRecord(original: string, generated: string): any
	return {
		sourceSha256 = serde.hash("sha256", original),
		sourceSize = #original,
		generatedSha256 = serde.hash("sha256", generated),
		generatedSize = #generated,
	}
end

function M.instrumentRelaySource(source: string): string
	local result = addRequire(source,
		'local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")\n', "Relay ClientSession")
	return replaceExactly(result, RELAY_BINDING,
		'observe(remote.OnClientEvent, CallbackTiming.wrap("relay-reliable", ' .. RELAY_CALLBACK .. '))', "Relay ClientSession")
end

function M.instrumentNativeSource(source: string): string
	local result = addRequire(source, "local Players = game:GetService(\"Players\")\n", "native adapter")
	return replaceExactly(result, NATIVE_BINDING,
		'child.OnClientEvent:Connect(CallbackTiming.wrap("native-reliable", deliverClient))', "native adapter")
end

local function copyTree(source: string, destination: string, transform: ((string, string) -> string)?, records: any, prefix: string)
	assert(fs.isDir(source), `missing source directory: {source}`)
	assert(not fs.isDir(destination) and not fs.isFile(destination), `profile output already exists: {destination}`)
	fs.writeDir(destination)
	for _, name in ipairs(fs.readDir(source)) do
		local sourcePath = join(source, name)
		local destinationPath = join(destination, name)
		local relative = if prefix == "" then name else prefix .. "/" .. name
		if fs.isDir(sourcePath) then
			copyTree(sourcePath, destinationPath, transform, records, relative)
		else
			assert(fs.isFile(sourcePath), `unsupported source entry: {sourcePath}`)
			local original = fs.readFile(sourcePath)
			local generated = if transform == nil then original else transform(relative, original)
			fs.writeFile(destinationPath, generated, { overwrite = false })
			records[slash(join(prefix, name))] = fileRecord(original, generated)
		end
	end
end

function M.copyTree(source: string, destination: string, transform: ((string, string) -> string)?, records: any?, prefix: string?): any
	local output = records or {}
	copyTree(source, destination, transform, output, prefix or "")
	return output
end

local function copyFile(source: string, destination: string, generated: string?, records: any, key: string)
	assert(fs.isFile(source), `missing source file: {source}`)
	local original = fs.readFile(source)
	local output = if generated == nil then original else generated
	fs.writeFile(destination, output, { overwrite = false })
	records[slash(key)] = fileRecord(original, output)
end

-- Create the complete source island consumed by a profiled quick place. The
-- caller owns the unique destination directory; this function never touches
-- the source tree or a prior generated build.
function M.copyProfileSources(root: string, destination: string): any
	assert(not fs.isDir(destination) and not fs.isFile(destination),
		`profile output already exists: {destination}`)
	fs.writeDir(destination)
	local records = {}
	local sourceRoot = join(destination, "source")
	fs.writeDir(sourceRoot)

	M.copyTree(join(root, "src"), join(sourceRoot, "Relay"), function(relative, source)
		return if string.sub(relative, -#"ClientSession.luau") == "ClientSession.luau"
			then M.instrumentRelaySource(source) else source
	end, records, "source/Relay")
	M.copyTree(join(root, "benchmarks/adapters/native-reliable"), join(sourceRoot, "NativeReliable"),
		function(relative, source)
			return if string.sub(relative, -#"init.luau") == "init.luau"
				then M.instrumentNativeSource(source) else source
		end, records, "source/NativeReliable")
	M.copyTree(join(root, "benchmarks/adapters/relay-reliable"), join(sourceRoot, "RelayReliable"), nil,
		records, "source/RelayReliable")
	M.copyTree(join(root, "benchmarks/contracts"), join(sourceRoot, "contracts"), nil,
		records, "source/contracts")
	M.copyTree(join(root, "benchmarks/correctness"), join(sourceRoot, "correctness"), nil,
		records, "source/correctness")
	M.copyTree(join(root, "benchmarks/fixtures"), join(sourceRoot, "fixtures"), nil,
		records, "source/fixtures")
	local adapterDestination = join(sourceRoot, "adapters")
	local runnerDestination = join(sourceRoot, "runner")
	fs.writeDir(adapterDestination)
	fs.writeDir(runnerDestination)
	copyFile(join(join(root, "benchmarks/adapters"), "AdapterContract.luau"),
		join(adapterDestination, "AdapterContract.luau"), nil, records, "source/adapters/AdapterContract.luau")
	copyFile(join(join(root, "benchmarks/adapters"), "ExternalAdapter.luau"),
		join(adapterDestination, "ExternalAdapter.luau"), nil, records, "source/adapters/ExternalAdapter.luau")
	copyFile(join(join(root, "benchmarks/runner"), "ExternalReadiness.luau"),
		join(runnerDestination, "ExternalReadiness.luau"), nil, records, "source/runner/ExternalReadiness.luau")

	local quickDestination = join(sourceRoot, "Quick")
	fs.writeDir(quickDestination)
	for _, name in { "Client.client.luau", "Config.luau", "Model.luau", "SchemaFixtures.luau", "SchemaRelay.luau", "Server.server.luau", "Session.luau", "CallbackTiming.luau" } do
		copyFile(join(join(root, "benchmarks/quick"), name), join(quickDestination, name), nil, records, "source/Quick/" .. name)
	end
	return records
end

function M.configureProfileProject(project: any, ids: { string }): any
	local benchmark = project.tree.ReplicatedStorage.RelayBenchmark
	local quick = benchmark.Quick
	benchmark.QuickAdapters["$properties"].Value = table.concat(ids, ",")
	project.name = "relay-quick-receive-profile"

	project.tree.ReplicatedStorage.Relay["$path"] = "source/Relay"
	benchmark.contracts["$path"] = "source/contracts"
	benchmark.correctness["$path"] = "source/correctness"
	benchmark.fixtures["$path"] = "source/fixtures"
	benchmark.adapters.AdapterContract["$path"] = "source/adapters/AdapterContract.luau"
	benchmark.adapters.ExternalAdapter["$path"] = "source/adapters/ExternalAdapter.luau"
	benchmark.adapters.NativeReliable["$path"] = "source/NativeReliable"
	benchmark.adapters.RelayReliable["$path"] = "source/RelayReliable"
	benchmark.Runner.ExternalReadiness["$path"] = "source/runner/ExternalReadiness.luau"
	for _, name in { "Config", "Model", "SchemaFixtures", "SchemaRelay", "Session", "CallbackTiming" } do
		quick[name]["$path"] = "source/Quick/" .. name .. ".luau"
	end
	project.tree.ServerScriptService.RelayQuickServer["$path"] = "source/Quick/Server.server.luau"
	project.tree.StarterPlayer.StarterPlayerScripts.RelayQuickClient["$path"] = "source/Quick/Client.client.luau"
	quick.ProfileReceive["$properties"].Value = true
	return project
end

function M.assertProfileMappings(project: any)
	local function visit(node: any)
		if type(node) ~= "table" then return end
		for key, value in node do
			if key == "$path" then
				assert(type(value) == "string" and string.sub(value, 1, 7) == "source/",
					`profile project path escapes its source snapshot: {tostring(value)}`)
			else
				visit(value)
			end
		end
	end
	visit(project)
end

function M.artifact(path: string): any
	local bytes = fs.readFile(path)
	return { sha256 = serde.hash("sha256", bytes), size = #bytes }
end

function M.exactBindings(): any
	return table.freeze({ relay = RELAY_BINDING, native = NATIVE_BINDING })
end

return table.freeze(M)
