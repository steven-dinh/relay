--!strict

local serde = require("@lune/serde")
local Manifest = require("../host/StudyInputManifest")

local files: any = {}
local directories: any = {}
local root = "E:/relay"
local candidate = "E:/candidate"
local toolRoot = "C:/Rokit"
local systemRoot = "C:/Windows"
local studio = "C:/Studio.exe"
local tracked = { "benchmarks/event-v1.project.json", "rokit.toml", "src/init.luau",
    "benchmarks/runner/Foo.luau" }
local project = serde.encode("json", { tree = { Relay = { ["$path"] = "../src" },
    Runner = { ["$path"] = "runner/Foo.luau" } } })
local config = '[tools]\nlune = "lune-org/lune@0.10.5"\nrojo = "rojo-rbx/rojo@7.7.0"\n'
local function install(base: string)
    directories[base] = true
    directories[base .. "/benchmarks"] = true
    directories[base .. "/benchmarks/runner"] = true
    directories[base .. "/src"] = true
    files[base .. "/benchmarks/event-v1.project.json"] = project
    files[base .. "/benchmarks/runner/Foo.luau"] = "return 1"
    files[base .. "/benchmarks/runner/Foo.meta.json"] = "{}" -- ignored file-path sibling
    files[base .. "/src/init.luau"] = "return 2"
    files[base .. "/src/init.meta.json"] = "{}" -- ignored, but Rojo-visible
    files[base .. "/rokit.toml"] = config
end
install(root)
install(candidate)
files[studio] = "studio-binary"
files[systemRoot .. "/System32/where.exe"] = "trusted-resolver"
for _, entry in { { "lune-org", "lune", "0.10.5" }, { "rojo-rbx", "rojo", "7.7.0" } } do
    local owner, name, version = entry[1], entry[2], entry[3]
    files[toolRoot .. "/tool-storage/" .. owner .. "/" .. name .. "/" .. version .. "/" .. name .. ".exe"] = name .. "-binary"
    files[toolRoot .. "/bin/" .. name .. ".exe"] = name .. "-shim"
end
local surface = {
    isFile = function(path) return files[path] ~= nil end,
    isDir = function(path) return directories[path] == true end,
    readFile = function(path)
        assert(files[path] ~= nil, `missing fixture {path}`)
        return files[path]
    end,
    readDir = function(path)
        local names = {}
        local prefix = path .. "/"
        for name in files do
            if string.sub(name, 1, #prefix) == prefix then
                local suffix = string.sub(name, #prefix + 1)
                if string.find(suffix, "/", 1, true) == nil then table.insert(names, suffix) end
            end
        end
        for name in directories do
            if string.sub(name, 1, #prefix) == prefix then
                local suffix = string.sub(name, #prefix + 1)
                if string.find(suffix, "/", 1, true) == nil then table.insert(names, suffix) end
            end
        end
        return names
    end,
}
local versionMismatch = false
local candidateToolVersion = false
local malformedGit = false
local shadowedTool = false
local function execute(program: string, arguments: { string }, options: any): any
    if program == "git" then
        assert(arguments[1] == "ls-files" and arguments[2] == "--cached" and arguments[3] == "-z")
        return { ok = true, stdout = if malformedGit then "unterminated" else table.concat(tracked, "\0") .. "\0" }
    end
    if program == systemRoot .. "/System32/where.exe" then
        return { ok = true, stdout = if shadowedTool and arguments[1] == "rojo"
            then "C:\\Other\\rojo.exe\r\n" else toolRoot .. "/bin/" .. arguments[1] .. ".exe\r\n" }
    end
    if program == "lune" then return { ok = true, stdout = if versionMismatch or (candidateToolVersion and options.cwd == candidate)
        then "lune 0.10.4" else "lune 0.10.5" } end
    if program == "rojo" then return { ok = true, stdout = "Rojo 7.7.0" } end
    error(`unexpected program {program} in {options.cwd}`, 0)
end
local options = { os = "windows", baseline = root, candidate = nil, studio = studio }
local plan = { topology = { recipients = 1, mode = "PersistentBenchmark" }, schedule = { "native", "baseline" } }
local deps = { fs = surface, execute = execute, hash = serde.hash, toolRoot = toolRoot, systemRoot = systemRoot }
local function collect() return Manifest.collect(options, plan, deps) end
local initial = collect()
assert(initial.version == 1 and initial.baseline.files == 6 and initial.candidate == nil
    and initial.sha256 == collect().sha256 and Manifest.verify(initial, serde.hash),
    "manifest must include tracked and ignored Rojo inputs deterministically")
local damaged = table.clone(initial)
damaged.planSha256 = initial.baseline.sha256
assert(not Manifest.verify(damaged, serde.hash), "tampered manifest summary was accepted")
local damagedCount = table.clone(initial)
damagedCount.baseline = table.clone(initial.baseline)
damagedCount.baseline.files += 1
assert(not Manifest.verify(damagedCount, serde.hash), "tampered source file count was accepted")
local function changed(path: string, replacement: string)
    local previous = files[path]
    files[path] = replacement
    assert(collect().sha256 ~= initial.sha256, `changed input did not invalidate manifest: {path}`)
    files[path] = previous
end
changed(root .. "/src/init.luau", "return 3")
changed(root .. "/src/init.meta.json", '{"className":"ModuleScript"}')
changed(root .. "/benchmarks/runner/Foo.meta.json", '{"className":"ModuleScript"}')
changed(root .. "/benchmarks/event-v1.project.json", serde.encode("json", { tree = { Relay = { ["$path"] = "../src" } } }))
changed(root .. "/rokit.toml", config .. "# policy change\n")
changed(toolRoot .. "/tool-storage/lune-org/lune/0.10.5/lune.exe", "changed-lune")
changed(toolRoot .. "/bin/rojo.exe", "changed-shim")
changed(systemRoot .. "/System32/where.exe", "changed-resolver")
changed(studio, "changed-studio")
plan.topology.recipients = 4
assert(collect().sha256 ~= initial.sha256, "measurement topology did not invalidate manifest")
plan.topology.recipients = 1
options.candidate = candidate
local paired = collect()
assert(paired.candidate ~= nil and paired.sha256 ~= initial.sha256 and Manifest.verify(paired, serde.hash),
    "candidate source identity was omitted")
files[candidate .. "/src/init.luau"] = "candidate-change"
assert(collect().sha256 ~= paired.sha256, "candidate source change was not detected")
files[candidate .. "/src/init.luau"] = "return 2"
candidateToolVersion = true
files[candidate .. "/rokit.toml"] = string.gsub(config, "lune@0%.10%.5", "lune@0.10.4")
files[toolRoot .. "/tool-storage/lune-org/lune/0.10.4/lune.exe"] = "candidate-lune"
local distinctCandidateTool = collect()
assert(distinctCandidateTool.tools.candidate.lune ~= paired.tools.candidate.lune
    and distinctCandidateTool.sha256 ~= paired.sha256,
    "candidate-specific tool binary and pin were omitted")
files[candidate .. "/rokit.toml"] = config
candidateToolVersion = false
options.candidate = nil
local function reject(code: string, callback: () -> ())
    local ok, message = pcall(callback)
    assert(not ok and string.find(tostring(message), code, 1, true) ~= nil,
        `expected {code}, got {tostring(message)}`)
end
versionMismatch = true
reject("BCAST_E_INPUT_TOOL", collect)
versionMismatch = false
shadowedTool = true
reject("BCAST_E_INPUT_TOOL", collect)
shadowedTool = false
malformedGit = true
reject("BCAST_E_INPUT_GIT", collect)
malformedGit = false
files[root .. "/benchmarks/event-v1.project.json"] = serde.encode("json", { tree = { Bad = { ["$path"] = "../../outside" } } })
reject("BCAST_E_INPUT_PATH", collect)
files[root .. "/benchmarks/event-v1.project.json"] = project
files[root .. "/src/default.project.json"] = '{"tree":{"External":{"$path":"../../outside"}}}'
reject("BCAST_E_INPUT_PROJECT", collect)
files[root .. "/src/default.project.json"] = nil
files[root .. "/benchmarks/runner/extra.project.json"] = '{"tree":{}}'
reject("BCAST_E_INPUT_PROJECT", collect)
files[root .. "/benchmarks/runner/extra.project.json"] = nil

local originalProject = files[root .. "/benchmarks/event-v1.project.json"]
files[root .. "/benchmarks/event-v1.project.json"] = serde.encode("json", {
    tree = { Relay = { ["$path"] = "../src" } },
})
local overLimitBody = "OVER_LIMIT_FILE_SENTINEL"
local overLimitPath = root .. "/src/overflow-4092.luau"
for index = 1, 4092 do
    files[root .. "/src/overflow-" .. string.format("%04d", index) .. ".luau"] =
        if index == 4092 then overLimitBody else "return " .. tostring(index)
end
local overLimitReads = 0
local overLimitHashes = 0
local guardedSurface = table.clone(surface)
guardedSurface.readFile = function(path)
    if path == overLimitPath then overLimitReads += 1 end
    return surface.readFile(path)
end
guardedSurface.readDir = function(path)
    local names = surface.readDir(path)
    if path == root .. "/src" then table.sort(names) end
    return names
end
local function guardedHash(algorithm: string, input: string): string
    if string.find(input, overLimitBody, 1, true) ~= nil then overLimitHashes += 1 end
    return serde.hash(algorithm, input)
end
local guardedDeps = table.clone(deps)
guardedDeps.fs = guardedSurface
guardedDeps.hash = guardedHash
reject("BCAST_E_INPUT_LIMIT", function() Manifest.collect(options, plan, guardedDeps) end)
assert(overLimitReads == 0 and overLimitHashes == 0,
    "first over-limit ignored Rojo input was read or hashed")
for index = 1, 4092 do files[root .. "/src/overflow-" .. string.format("%04d", index) .. ".luau"] = nil end
files[root .. "/benchmarks/event-v1.project.json"] = originalProject

files[root .. "/src/init.luau"] = nil
reject("BCAST_E_INPUT_FILE", collect)

print("PASS Relay.Benchmarks.StudyInputManifest")
