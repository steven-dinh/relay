local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Paths = require("./Paths")
local Fingerprint = require("../../benchmarks/host/MeasurementFingerprint")

local DIRECTORIES = { "src", "scripts/tooling" }
local FILES = {
	"scripts/relay-tools.luau",
	"scripts/schema-check-core.luau",
	"scripts/schema-compatibility-core.luau",
	"scripts/analyze-schema-budget-core.luau",
	"benchmarks/host/MeasurementFingerprint.luau",
}

local function collect(root)
	root = Paths.resolve(root, root, true)
	local paths = {}
	local function add(path)
		assert(#paths < 256, "tooling source closure exceeds 256 files")
		table.insert(paths, path)
	end
	local function walk(relative, depth)
		assert(depth <= 8, "tooling source directory nesting exceeds eight levels")
		local directory = Paths.resolve(relative, root, true)
		assert(Paths.within(directory, root), "tooling source escapes its root")
		for _, name in fs.readDir(directory) do
			local child = relative .. "/" .. name
			if fs.isDir(root .. "/" .. child) then
				walk(child, depth + 1)
			elseif string.match(name, "%.luau$") or string.match(name, "%.ps1$") or string.match(name, "%.md$") then
				add(child)
			end
		end
	end
	for _, directory in DIRECTORIES do walk(directory, 0) end
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
