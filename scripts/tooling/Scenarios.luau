local Kit = require("../consumer-testing/Kit")
local Result = require("./Result")

local MAXIMUM_SCENARIOS = 32
local MAXIMUM_PATH_BYTES = 1_024
local diagnostic = Result.diagnostic

local function firstErrorLine(value, fallback)
    local ok, text = pcall(tostring, value)
    if not ok or type(text) ~= "string" then return fallback end
    local ending = string.find(text, "[\r\n]")
    local line = string.sub(text, 1, math.min((ending or (#text + 1)) - 1, 1_024))
    line = string.gsub(line, "%c", " ")
    return if line == "" then fallback else line
end

local function countPaths(paths)
    if type(paths) ~= "table" or getmetatable(paths) ~= nil then return nil end
    local count = #paths
    if count < 1 or count > MAXIMUM_SCENARIOS then return nil end
    local entries = 0
    for key in paths do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then return nil end
        entries += 1
    end
    return if entries == count then count else nil
end

local function run(definition, paths, load)
    local result = { mode = "portable", cases = {} }
    local diagnostics = {}
    local count = countPaths(paths)
    if count == nil then
        table.insert(diagnostics, diagnostic("InvalidScenarioList", "tests",
            "must contain 1..32 project scenario paths", "Configure a nonempty project tests list."))
        return result, diagnostics
    elseif type(load) ~= "function" then
        table.insert(diagnostics, diagnostic("ScenarioLoaderUnavailable", "tests",
            "scenario loading is unavailable", "Use the host project loader for each scenario path."))
        return result, diagnostics
    end

    local function withFixture(callback, options)
        return Kit.withFixture(definition, callback, options)
    end
    local context = table.freeze({ definition = definition, withFixture = withFixture })

    for index = 1, count do
        local path = paths[index]
        if type(path) ~= "string" or path == "" or #path > MAXIMUM_PATH_BYTES or string.find(path, "%c") then
            table.insert(result.cases, { path = "tests[" .. index .. "]", status = "failed" })
            table.insert(diagnostics, diagnostic("InvalidScenarioPath", "tests[" .. index .. "]",
                "scenario path must be a nonempty bounded string without control characters",
                "Correct the project tests entry and rerun."))
            continue
        end

        local loaded, scenario, loadProblem = pcall(load, path)
        if not loaded or type(scenario) ~= "function" then
            table.insert(result.cases, { path = path, status = "failed" })
            table.insert(diagnostics, diagnostic("ScenarioLoadFailed",
                path,
                if not loaded then firstErrorLine(scenario, "scenario module could not be loaded")
                    elseif loadProblem ~= nil then firstErrorLine(loadProblem, "scenario module could not be loaded")
                    else "scenario module must return a function",
                "Check the configured scenario path and module imports."))
            continue
        end

        local succeeded, problem = pcall(scenario, context)
        if succeeded then
            table.insert(result.cases, { path = path, status = "passed" })
        else
            table.insert(result.cases, { path = path, status = "failed" })
            table.insert(diagnostics, diagnostic("ScenarioAssertionFailed",
                path,
                firstErrorLine(problem, "scenario function raised an assertion or runtime error"),
                "Fix the scenario failure and rerun the portable profile."))
        end
    end

    return result, diagnostics
end

return table.freeze({ run = run })
