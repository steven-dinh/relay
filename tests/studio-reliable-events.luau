local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Verification = require("../scripts/Verification")

local args = process.args
local modeFlag = args[#args]
local correctnessOnly = modeFlag == "--correctness-only"
local competitiveOnly = modeFlag == "--competitive-only"
local fairnessOnly = modeFlag == "--fairness-only"
assert(not ((correctnessOnly and competitiveOnly) or (correctnessOnly and fairnessOnly)
    or (competitiveOnly and fairnessOnly)), "proof mode flags are mutually exclusive")
local argumentCount = #args - (if correctnessOnly or competitiveOnly or fairnessOnly then 1 else 0)
assert(argumentCount == 0 or (argumentCount == 2 and args[1] == "--studio"),
    "expected optional --studio <absolute path> followed by one optional proof mode flag")
local studio = if argumentCount == 2 then args[2] else process.env.RELAY_STUDIO_PATH
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
local workspace = Verification.workspace("regression")
local place = workspace.artifacts .. "/reliable-events.rbxlx"
local sourceManifest = workspace.root .. "/source-identity.json"
local sourceBefore = Verification.sourceIdentity()
local built = process.exec("rojo", { "build", "tests/studio/reliable-events.project.json", "-o", place })
assert(built.ok and fs.isFile(place), "proof place build failed: " .. built.stderr)
local placeSha256 = "sha256:" .. serde.hash("sha256", fs.readFile(place))
fs.writeFile(sourceManifest, serde.encode("json", {
	identity = sourceBefore,
	placeSha256 = placeSha256,
}, true))
local hostArgs = {
    "run", "tests/host/run-reliable-events.luau", "--studio", studio, "--place", place,
}
if correctnessOnly then table.insert(hostArgs, "--correctness-only") end
if competitiveOnly then table.insert(hostArgs, "--competitive-only") end
if fairnessOnly then table.insert(hostArgs, "--fairness-only") end
table.insert(hostArgs, "--source-manifest")
table.insert(hostArgs, sourceManifest)
local result = process.exec("lune", hostArgs)
if #result.stdout > 0 then print(result.stdout) end
assert(result.ok, "Studio proof failed: " .. result.stderr)
