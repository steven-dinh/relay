local fs = require("@lune/fs")
local process = require("@lune/process")
local Generator = require("./Generator")

local USAGE = "Usage: lune run scripts/roblox-ts/generate.luau <repo-relative-spec.luau> <repo-relative-output.d.ts>"

local function fail(message)
	print("ERROR " .. message)
	process.exit(1)
end

local function repoPath(path, extension, label)
	if type(path) ~= "string" or path == "" then fail(label .. " path is required") end
	path = string.gsub(path, "\\", "/")
	while string.sub(path, 1, 2) == "./" do
		path = string.sub(path, 3)
	end
	if string.sub(path, 1, 1) == "/" or string.match(path, "^[A-Za-z]:") ~= nil then
		fail(label .. " path must be repository-relative")
	end
	for component in string.gmatch(path, "[^/]+") do
		if component == "." or component == ".." then fail(label .. " path cannot traverse directories") end
	end
	if string.sub(path, -#extension) ~= extension then
		fail(label .. " path must end in " .. extension)
	end
	return path
end

if #process.args ~= 2 then fail(USAGE) end
local specPath = repoPath(process.args[1], ".luau", "schema")
local outputPath = repoPath(process.args[2], ".d.ts", "declaration output")

local modulePath = string.gsub(specPath, "%.luau$", "")
local loaded, spec = pcall(require, "../../" .. modulePath)
if not loaded then fail("could not load schema module: " .. tostring(spec)) end

local generated, declaration = pcall(Generator.generate, spec)
if not generated then fail(tostring(declaration)) end

local written, writeError = pcall(fs.writeFile, outputPath, declaration)
if not written then fail("could not write declaration: " .. tostring(writeError)) end
print("Generated " .. outputPath)
