local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Paths = require("./Paths")
local Identity = require("./Identity")
local LUNE_VERSION = "0.11.0"

local function build(root, destination)
	root = Paths.resolve(root, process.cwd, true)
	destination = Paths.resolve(destination, process.cwd, false)
	assert(not fs.isDir(destination) and not fs.isFile(destination), "bundle destination already exists")
	for _, directory in { "src", "scripts/tooling", "scripts/studio-inspector" } do
		assert(not Paths.within(destination, root .. "/" .. directory), "bundle cannot be written inside its source closure")
	end
	assert(destination ~= root, "bundle cannot replace its source root")
	local source = Identity.collect(root)
	fs.writeDir(destination)
	local manifestPath = destination .. "/tooling-manifest.json"
	fs.writeFile(manifestPath, serde.encode("json", { schemaVersion = 1, status = "building" }))
	for _, file in source.files do
		local target = destination .. "/" .. file.path
		local parent = assert(string.match(target, "^(.*)/[^/]+$"))
		if not fs.isDir(parent) then fs.writeDir(parent) end
		fs.writeFile(target, source.contents[file.path])
	end
	local copied = Identity.collect(destination)
	assert(copied.compilerId == source.compilerId and copied.toolingId == source.toolingId, "bundle source parity failed")
	local manifest = { schemaVersion = 1, status = "complete", compilerId = source.compilerId,
		toolingId = source.toolingId, files = source.files,
		entrypoint = "scripts/relay-tools.luau", lune = LUNE_VERSION, cliHosts = { "windows" } }
	fs.writeFile(manifestPath, serde.encode("json", manifest) .. "\n")
	return manifest
end

return table.freeze({ build = build, LUNE_VERSION = LUNE_VERSION })
