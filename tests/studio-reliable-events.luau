local fs = require("@lune/fs")
local process = require("@lune/process")

local args = process.args
assert(#args == 0 or (#args == 2 and args[1] == "--studio"), "expected optional --studio <absolute path>")
local studio = if #args == 2 then args[2] else process.env.RELAY_STUDIO_PATH
if studio == nil then
    local versions = process.env.LOCALAPPDATA .. "/Roblox/Versions"
    if fs.isDir(versions) then
        for _, version in fs.readDir(versions) do
            local candidate = versions .. "/" .. version .. "/RobloxStudioBeta.exe"
            if fs.isFile(candidate) then
                assert(studio == nil, "multiple Studio installations; set RELAY_STUDIO_PATH or pass --studio")
                studio = candidate
            end
        end
    end
end
assert(studio ~= nil and fs.isFile(studio), "Studio unavailable; set RELAY_STUDIO_PATH or pass --studio")
if not fs.isDir(".tmp") then fs.writeDir(".tmp") end
local place = ".tmp/relay-reliable-events.rbxlx"
local built = process.exec("rojo", { "build", "tests/studio/reliable-events.project.json", "-o", place })
assert(built.ok and fs.isFile(place), "proof place build failed: " .. built.stderr)
local result = process.exec("lune", {
    "run", "tests/host/run-reliable-events.luau", "--studio", studio, "--place", place,
})
if #result.stdout > 0 then print(result.stdout) end
assert(result.ok, "Studio proof failed: " .. result.stderr)
