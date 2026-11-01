local fs = require("@lune/fs")
local process = require("@lune/process")

local function absolute(path)
    return string.sub(path, 1, 1) == "/" or string.match(path, "^%a:[/\\\\]") ~= nil
end

local function parent(path)
    local value = string.gsub(path, "/+$", "")
    if value == "" then return "/" end
    if string.match(value, "^//[^/]+/[^/]+$") then return value end
    if string.match(value, "^%a:$") then return value .. "/" end
    local result = string.match(value, "^(.*)/[^/]+$")
    if result == nil then return value end
    if result == "" then return "/" end
    if string.match(result, "^%a:$") then return result .. "/" end
    return result
end

local modulePath = string.gsub(debug.info(1, "s"), "\\", "/")
modulePath = string.gsub(modulePath, "^[@=]", "")
if not absolute(modulePath) then
    modulePath = string.gsub(process.cwd, "\\", "/") .. "/" .. modulePath
end
local directory = string.match(modulePath, "^(.*)/[^/]+$") or modulePath
local projectRoot = parent(parent(directory))
assert(fs.isFile(projectRoot .. "/src/Definition.luau"),
    "Relay source root was not found next to the Source module")

local function read(path)
    assert(type(path) == "string" and path ~= "" and not string.find(path, "%c"),
        "source path must be a relative Relay source path")
    path = string.gsub(path, "\\", "/")
    while string.sub(path, 1, 2) == "./" do path = string.sub(path, 3) end
    assert(not absolute(path) and string.sub(path, 1, 4) == "src/",
        "source path must be inside the Relay src directory")
    for part in string.gmatch(path, "[^/]+") do
        assert(part ~= "..", "source path must stay inside the Relay src directory")
    end
    return fs.readFile(projectRoot .. "/" .. path)
end

return table.freeze({ read = read })
