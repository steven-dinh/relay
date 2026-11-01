local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Paths = require("./Paths")
local Fingerprint = require("../../benchmarks/host/MeasurementFingerprint")

local DIRECTORIES = { "src", "scripts/tooling", "scripts/studio-inspector" }
local FILES = {
	"LICENSE",
	"rokit.toml",
	"scripts/relay-tools.luau",
	"scripts/schema-check-core.luau",
	"scripts/schema-compatibility-core.luau",
	"scripts/analyze-schema-budget-core.luau",
	"scripts/check-schema.md",
	"scripts/schema-compatibility.md",
	"scripts/analyze-schema-budget.md",
	"docs/reference.md",
	"benchmarks/host/MeasurementFingerprint.luau",
	"scripts/consumer-testing/Kit.luau",
	"scripts/consumer-testing/README.md",
	"tests/support/ClientRuntime.luau",
	"tests/support/ServerRuntime.luau",
	"tests/support/NativeCodec.luau",
	"tests/support/Source.luau",
	"scripts/roblox-ts/Generator.luau",
	"scripts/roblox-ts/generate.luau",
	"scripts/roblox-ts/project-check.mjs",
	"scripts/roblox-ts/check.mjs",
	"scripts/roblox-ts/package.json",
	"scripts/roblox-ts/package-lock.json",
	"scripts/roblox-ts/tsconfig.json",
	"scripts/roblox-ts/README.md",
	"scripts/roblox-ts/consumer/default.project.json",
	"scripts/roblox-ts/consumer/src/Spec.luau",
	"scripts/roblox-ts/consumer/src/Network.luau",
	"scripts/roblox-ts/consumer/src/server.server.ts",
	"scripts/roblox-ts/consumer/src/client.client.ts",
	"scripts/roblox-ts/consumer/src/contracts.ts",
	"tests/roblox-ts/negative.ts",
}

local function collect(root)
	root = Paths.resolve(root, root, true)
	local paths = {}
	local function add(path)
		assert(#paths < 256, "tooling source closure exceeds 256 files")
		table.insert(paths, path)
	end
	local pending, depth, directories = table.clone(DIRECTORIES), 0, #DIRECTORIES
	while #pending > 0 do
		assert(depth <= 8, "tooling source directory nesting exceeds eight levels")
		local requests = {}
		for _, relative in pending do table.insert(requests, { path = relative, mustExist = true }) end
		local resolved = Paths.resolveMany(root, requests)
		local nextLevel = {}
		for index, relative in pending do
			assert(Paths.within(resolved[index], root), "tooling source escapes its root")
			for _, name in fs.readDir(resolved[index]) do
				local child = relative .. "/" .. name
				if fs.isDir(root .. "/" .. child) then
					directories += 1
					assert(directories <= 256, "tooling source closure exceeds 256 directories")
					table.insert(nextLevel, child)
				elseif string.match(name, "%.luau$") or string.match(name, "%.ps1$") or string.match(name, "%.md$")
					or string.match(name, "%.json$") then
					add(child)
				end
			end
		end
		pending, depth = nextLevel, depth + 1
	end
	for _, path in FILES do add(path) end
	table.sort(paths)
	local requests = {}
	for _, path in paths do table.insert(requests, { path = path, mustExist = true }) end
	local resolved = Paths.resolveMany(root, requests)
	local contents, compiler, files, total = {}, {}, {}, 0
	for index, path in paths do
		assert(Paths.within(resolved[index], root), "tooling source escapes its root")
		local size = fs.metadata(resolved[index]).size
		assert(size <= 4_194_304 and total + size <= 16_777_216, "tooling source exceeds byte limits")
		local bytes = fs.readFile(resolved[index])
		total += #bytes
		assert(#bytes <= 4_194_304 and total <= 16_777_216, "tooling source exceeds byte limits")
		assert(contents[path] == nil, "duplicate tooling source path")
		contents[path] = bytes
		if string.sub(path, 1, 4) == "src/" then compiler[path] = bytes end
		table.insert(files, { path = path, digest = "sha256:" .. serde.hash("sha256", bytes) })
	end
	return {
		compilerId = Fingerprint.digest(compiler, serde.hash, "RelayToolsCompiler:1"),
		toolingId = Fingerprint.digest(contents, serde.hash, "RelayToolsBuild:1"),
		contents = contents,
		files = files,
	}
end

return table.freeze({ collect = collect })
