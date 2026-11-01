local process = require("@lune/process")
local Relay = require("../src")
local Scenarios = require("../scripts/tooling/Scenarios")
local Source = require("./support/Source")

local s = Relay.schema
local definition = assert(Relay.define({
    name = "ToolingScenarios",
    version = 1,
    events = {
        Input = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
        Delayed = s.clientToServer(2, s.fields(s.field("value", s.u8())), { delivery = "Unreliable" }),
    },
}))

local function fifoAndClock(context)
    assert(context.definition == definition, "scenario receives the actual compiler token")
    local received, delayedValue = {}, nil
    context.withFixture(function(fixture)
        assert(fixture.server.events.Input:Connect(function(_, value) table.insert(received, value) end))
        assert(fixture.server.events.Delayed:Connect(function(_, value) delayedValue = value end))
        assert(fixture:Start())
        assert(fixture.client.events.Input:Send(11) and fixture.client.events.Input:Send(12))
        assert(#received == 0, "sending does not bypass Pump")
        assert(fixture:Pump() == 2 and received[1] == 11 and received[2] == 12,
            "Pump delivers reliable records in FIFO order")

        assert(fixture.client.events.Delayed:Send(13))
        local pending = fixture:GetPending()
        assert(#pending == 1 and fixture:Delay(pending[1].id, 0.5))
        assert(fixture:Advance(0.5) and delayedValue == nil,
            "Advance moves logical time without delivering transport")
        assert(fixture:Pump() == 1 and delayedValue == 13,
            "Pump delivers unreliable transport once its due time arrives")
    end)
end

if process.args[1] == "--source-path-smoke" then
    assert(string.find(Source.read("src/Definition.luau"), "local function define", 1, true))
    local result, diagnostics = Scenarios.run(definition, { "scenarios/portable.luau" }, function()
        return fifoAndClock
    end)
    assert(result.mode == "portable" and result.cases[1].status == "passed" and #diagnostics == 0)
    print("PASS Relay portable scenario source-path smoke")
    return
end

local loaded, diagnostics = Scenarios.run(definition, { "scenarios/portable.luau" }, function(path)
    assert(path == "scenarios/portable.luau")
    return fifoAndClock
end)
assert(loaded.mode == "portable" and loaded.cases[1].path == "scenarios/portable.luau"
    and loaded.cases[1].status == "passed" and #diagnostics == 0)

local failedFixture
local failed, failedDiagnostics = Scenarios.run(definition, { "scenarios/failure.luau" }, function()
    return function(context)
        context.withFixture(function(fixture)
            failedFixture = fixture
            assert(fixture.server.events.Input:Connect(function() end))
            assert(fixture:Start() and fixture.client.events.Input:Send(21))
            assert(fixture:GetStatus().queuedMessages > 0 and fixture:GetStatus().connections > 0)
            assert(false, "intentional scenario assertion")
        end)
    end
end)
local failedStatus = failedFixture:GetStatus()
assert(failed.cases[1].status == "failed" and failedDiagnostics[1].code == "ScenarioAssertionFailed"
    and failedDiagnostics[1].severity == "error" and failedDiagnostics[1].action ~= ""
    and string.find(failedDiagnostics[1].message, "intentional scenario assertion", 1, true)
    and failedStatus.state == "Destroyed" and failedStatus.queuedMessages == 0
    and failedStatus.activeTimers == 0 and failedStatus.connections == 0,
    "scenario assertion failures are reported after Kit teardown")

local scriptPath = string.gsub(debug.info(1, "s"), "\\", "/")
scriptPath = string.gsub(scriptPath, "^[@=]", "")
if string.sub(scriptPath, 1, 1) ~= "/" and string.match(scriptPath, "^%a:[/\\\\]") == nil then
    scriptPath = process.cwd .. "/" .. scriptPath
end
local changedCwd = if string.sub(process.cwd, 1, 1) == "/" then "/" else string.sub(process.cwd, 1, 3)
local child = process.exec("lune", { "run", scriptPath, "--source-path-smoke" }, {
    cwd = changedCwd,
    stdio = "default",
})
assert(child.ok, "scenario runner failed from a different cwd: " .. child.stderr)

print("PASS Relay portable project scenarios")
