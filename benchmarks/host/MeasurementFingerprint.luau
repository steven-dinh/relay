--!strict

-- Versioned common measurement inputs, deliberately independent of Git revision,
-- adapter bindings, production Relay, vendors/generated code, reports, and docs.
-- All Luau files in these four shared directories are covered (including helpers
-- used only by some adapters). Unknown executable roots in a built place fail
-- closed. A new shared dependency outside this list requires explicit coverage.
local DIRECTORIES = { "runner", "contracts", "correctness", "fixtures" }
local FILES = { "event-v1.project.json", "adapters/AdapterContract.luau",
	"adapters/ExternalAdapter.luau", "tests/support/StudioProofReports.luau" }

local function digest(entries: any, hash: any, domain: string?): string
	local keys = {}
	for key in entries do table.insert(keys, key) end
	table.sort(keys)
	local framed = { domain or "RelayMeasurementFingerprint:1:PersistentSession" }
	for _, key in keys do
		local value = entries[key]
		table.insert(framed, `{#key}:{key}{#value}:{value}`)
	end
	local value = hash("sha256", table.concat(framed))
	assert(type(value) == "string" and #value == 64 and string.match(value, "^[0-9a-f]+$") ~= nil, "HOST_E_MEASUREMENT_HASH")
	return "sha256:" .. value
end

local function collect(root: string, placeBytes: string, io: any, robloxApi: any, hash: any): string
	local entries = {}
	local sources = {}
	local function add(path)
		local source = io.readFile(root .. "/benchmarks/" .. path)
		assert(type(source) == "string", "HOST_E_MEASUREMENT_SOURCE")
		entries[path] = source
		if string.sub(path, -5) == ".luau" then sources[source] = true end
	end
	local function directory(path)
		for _, name in io.readDir(root .. "/benchmarks/" .. path) do
			local child = path .. "/" .. name
			if io.isDir(root .. "/benchmarks/" .. child) then directory(child)
			elseif string.sub(name, -5) == ".luau" then add(child)
			elseif string.sub(name, -3) ~= ".md" then error("HOST_E_MEASUREMENT_UNCLASSIFIED: " .. child, 0) end
		end
	end
	for _, path in DIRECTORIES do directory(path) end
	for _, path in FILES do add(path) end
	local sharedRoots = {
		["ReplicatedStorage/RelayBenchmark/Runner"] = true,
		["ReplicatedStorage/RelayBenchmark/contracts"] = true,
		["ReplicatedStorage/RelayBenchmark/correctness"] = true,
		["ReplicatedStorage/RelayBenchmark/fixtures"] = true,
		["ReplicatedStorage/RelayBenchmark/adapters/AdapterContract"] = true,
		["ReplicatedStorage/RelayBenchmark/adapters/ExternalAdapter"] = true,
		["ServerStorage/RelayBenchmarkServer/AdapterAllowlist"] = true,
		["ServerScriptService/RelayBenchmarkCoordinator"] = true,
		["StarterPlayer/StarterPlayerScripts/RelayBenchmarkParticipant"] = true,
	}
	local artifactRoots = {
		["ReplicatedStorage/Relay"] = true,
		["ReplicatedStorage/RelayBenchmark/adapters/NativeReliable"] = true,
		["ReplicatedStorage/RelayBenchmark/adapters/RelayReliable"] = true,
		["ReplicatedStorage/RelayBenchmark/adapters/ExternalSelected"] = true,
		["ServerStorage/RelayBenchmarkServer/ExternalTemplate"] = true,
	}
	local function under(path, roots)
		for prefix in roots do
			if path == prefix or string.sub(path, 1, #prefix + 1) == prefix .. "/" then return true end
		end
		return false
	end
	local function inspect(node, path)
		if node.ClassName == "ModuleScript" or node.ClassName == "Script" or node.ClassName == "LocalScript" then
			if under(path, sharedRoots) then
				assert(sources[node.Source] == true, "HOST_E_MEASUREMENT_UNCLASSIFIED: " .. path)
			elseif not under(path, artifactRoots) then
				error("HOST_E_MEASUREMENT_UNCLASSIFIED: " .. path, 0)
			end
		end
		for _, child in node:GetChildren() do inspect(child, if path == "" then child.Name else path .. "/" .. child.Name) end
	end
	inspect(robloxApi.deserializePlace(placeBytes), "")
	return digest(entries, hash)
end

return table.freeze({ collect = collect, digest = digest })
