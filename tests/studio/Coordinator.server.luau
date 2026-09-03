local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Relay = require(ReplicatedStorage.Relay)
local Fixture = require(ReplicatedStorage.RelayProofDefinition)
local control = ReplicatedStorage.RelayProofControl
local readyPlayers = {}
local readyConnection = ReplicatedStorage.RelayProofReady.OnServerEvent:Connect(function(player)
    readyPlayers[player] = true
end)
local session
local inputConnection
local roster
local deliveries = {}
local completed = {}

local function waitFor(predicate, label)
    local deadline = os.clock() + 30
    repeat
        if predicate() then return end
        task.wait(0.03)
    until os.clock() >= deadline
    error("timed out: " .. label)
end

local function command(player, name, argument)
    return control:InvokeClient(player, name, argument)
end

local function all(name, argument)
    for _, player in roster do assert(command(player, name, argument)) end
end

local function create(capacity, aggregate, refill)
    if session then session:Destroy() end
    assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "owned root leaked")
    -- The test coordinator, not Relay, orders replication between generations.
    -- Old sessions are one-shot and must never adopt a replacement transport.
    all("absent")
    table.clear(deliveries)
    session = assert(Relay.createServer(Fixture.create(), {
        inboundRate = {
            perPlayer = { capacity = capacity or 128, refillPerSecond = refill or 128 },
            aggregate = { capacity = aggregate or 1024, refillPerSecond = refill or 1024 },
        },
    }))
    inputConnection = assert(session.events.Input:Connect(function(player, ...)
        assert(player.Parent == Players, "engine supplied current player")
        local sequence = Fixture.check(...)
        deliveries[player] = deliveries[player] or {}
        table.insert(deliveries[player], sequence)
    end))
    assert(session:Start())
    return session
end

local function count(player)
    return if deliveries[player] then #deliveries[player] else 0
end

local function mark(name)
    table.insert(completed, name)
end

local function correctness()
    create()
    all("start")
    for _, player in roster do command(player, "send", 3) end
    waitFor(function()
        for _, player in roster do if count(player) ~= 3 then return false end end
        return true
    end, "C2S ordered values")
    for _, player in roster do
        for index, sequence in deliveries[player] do assert(index == sequence, "C2S order") end
    end
    mark("c2s-values-order")

    assert(session.events.State:Send(roster[1], Fixture.values(10)))
    task.wait(0.3)
    for index, player in roster do
        local result = command(player, "read")
        assert(#result.received == (if index == 1 then 1 else 0), "target isolation")
        if index == 1 then assert(result.received[1] == 10) end
    end
    mark("target-isolation")
    assert(session.events.State:Broadcast(Fixture.values(11)))
    task.wait(0.3)
    for index, player in roster do
        local values = command(player, "read").received
        assert(#values == (if index == 1 then 2 else 1) and values[#values] == 11, "broadcast audience")
    end
    mark("broadcast-values")

    all("raw", "matrix")
    task.wait(0.3)
    for _, player in roster do assert(count(player) == 3, "malformed ingress dispatched") end
    mark("malformed-ingress")

    all("disconnect")
    assert(session.events.State:Broadcast(Fixture.values(12)))
    task.wait(0.2)
    all("listen")
    assert(session.events.State:Broadcast(Fixture.values(13)))
    task.wait(0.2)
    for index, player in roster do
        local values = command(player, "read").received
        assert(#values == (if index == 1 then 3 else 2) and values[#values] == 13, "disconnect or replay")
    end
    mark("listener-disconnect")

    all("mode", "error")
    assert(session.events.State:Broadcast(Fixture.values(14)))
    task.wait(0.2)
    all("mode", "normal")
    assert(session.events.State:Broadcast(Fixture.values(15)))
    task.wait(0.2)
    all("mode", "yield")
    assert(session.events.State:Broadcast(Fixture.values(16)))
    task.wait(0.2)
    local before = {}
    for _, player in roster do before[player] = command(player, "read").entered end
    assert(session.events.State:Broadcast(Fixture.values(17)))
    task.wait(0.2)
    for _, player in roster do assert(command(player, "read").entered == before[player], "yielding handler cap") end
    all("release")
    task.wait(0.2)
    all("mode", "normal")
    assert(session.events.State:Broadcast(Fixture.values(18)))
    task.wait(0.2)
    for _, player in roster do
        local values = command(player, "read").received
        assert(values[#values] == 18 and values[#values - 1] == 16 and values[#values - 2] == 15, "handler recovery")
    end
    mark("client-listener-error-yield")

    inputConnection:Disconnect()
    local entered = 0
    local release = false
    inputConnection = assert(session.events.Input:Connect(function(_, ...)
        Fixture.check(...)
        entered += 1
        while not release do task.wait() end
    end))
    command(roster[1], "send", 1)
    waitFor(function() return entered == 1 end, "yielding server listener")
    command(roster[1], "send", 3)
    task.wait(0.2)
    assert(entered == 1, "server per-player endpoint handler cap")
    release = true
    task.wait(0.1)
    inputConnection:Disconnect()
    inputConnection = assert(session.events.Input:Connect(function()
        entered += 1
        error("deliberate trusted server handler failure")
    end))
    command(roster[1], "send", 1)
    waitFor(function() return entered == 2 end, "server handler error")
    inputConnection:Disconnect()
    inputConnection = assert(session.events.Input:Connect(function() entered += 1 end))
    command(roster[1], "send", 1)
    waitFor(function() return entered == 3 end, "server handler recovery")
    mark("server-listener-error-yield")

    all("destroy")
    all("mismatch")
    all("start")
    session:Destroy()
    task.wait(0.3)
    all("lost")
    all("destroy")
    all("timeout")
    mark("mismatch-loss-timeout")

    -- Exercise each real Instance mutation independently; fresh clients must bind
    -- to the next generation while the old session stays terminal.
    for _, mutation in { "root-name", "remote-name", "descriptor", "extra-child", "remote-destroy" } do
        create()
        all("start")
        local owned = ReplicatedStorage.RelayRemotes
        local foreign
        if mutation == "root-name" then owned.Name = "MovedRelayProof"
        elseif mutation == "remote-name" then owned.Reliable.Name = "MovedReliable"
        elseif mutation == "descriptor" then owned.Definition.Value = "incompatible"
        elseif mutation == "extra-child" then
            foreign = Instance.new("Folder")
            foreign.Name = "Foreign"
            foreign.Parent = owned
        else owned.Reliable:Destroy() end
        task.wait(0.3)
        local ok, failure = session.events.State:Broadcast(Fixture.values(1))
        assert(not ok and failure.code == "Destroyed", "server transport mutation")
        all("lost")
        all("destroy")
        if foreign then
            assert(foreign.Parent == owned and owned.Parent == ReplicatedStorage, "foreign child deleted")
            local contender = assert(Relay.createServer(Fixture.create(), {
                inboundRate = {
                    perPlayer = { capacity = 1, refillPerSecond = 1 },
                    aggregate = { capacity = 1, refillPerSecond = 1 },
                },
            }))
            local started, conflict = contender:Start()
            assert(not started and conflict.code == "RemoteOwnershipConflict", "contaminated root adopted")
            contender:Destroy()
        end
        -- Only the fixture removes contamination it created.
        owned:Destroy()
    end
    mark("transport-mutation-contamination")

    local baseline = #ReplicatedStorage:GetDescendants()
    for _ = 1, 100 do
        create()
        assert(#ReplicatedStorage.RelayRemotes:GetChildren() == 2, "exact owned hierarchy")
        session:Destroy()
        session:Destroy()
        assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "cleanup cycle root")
        assert(#ReplicatedStorage:GetDescendants() == baseline, "cleanup cycle Instance growth")
    end
    create()
    all("start")
    all("send", 1)
    task.wait(0.3)
    for _, player in roster do assert(count(player) == 1, "stale or duplicate callback after cycles") end
    all("destroy")
    session:Destroy()
    mark("cleanup-100-cycles")
end

local function admission()
    create(4, #roster * 4, 0.000001)
    all("start")
    all("send", 32)
    task.wait(0.5)
    for _, player in roster do assert(count(player) == 4, "per-player admission") end
    mark("hostile-per-player")
    all("destroy")

    create(4, 4, 0.000001)
    all("start")
    all("send", 32)
    task.wait(0.5)
    local total = 0
    for _, player in roster do total += count(player) end
    assert(total == 4, "aggregate admission")
    mark("hostile-aggregate")
    all("destroy")

    create(4, #roster * 4, 0.000001)
    all("start")
    all("raw", 4)
    task.wait(0.3)
    all("send", 4)
    task.wait(0.3)
    for _, player in roster do assert(count(player) == 0, "malformed frames bypassed charging") end
    mark("malformed-charged")
    all("destroy")

    if #roster > 1 then
        create(4, #roster * 4, 0.000001)
        all("start")
        for index = 1, #roster - 1 do command(roster[index], "send", 32) end
        task.wait(0.3)
        command(roster[#roster], "send", 4)
        task.wait(0.3)
        for _, player in roster do assert(count(player) == 4, "exhausted player drained honest budget") end
        mark("mixed-honest-budget")
        all("destroy")
    end
    session:Destroy()
end

task.spawn(function()
    local args = StudioTestService:GetTestArgs()
    local ok, failure = pcall(function()
        assert(type(args) == "table" and (args.clients == 1 or args.clients == 2 or args.clients == 4 or args.clients == 8))
        waitFor(function()
            local current = Players:GetPlayers()
            if #current ~= args.clients then return false end
            for _, player in current do if not readyPlayers[player] then return false end end
            roster = current
            return true
        end, "participant roster")
        table.sort(roster, function(left, right) return left.UserId < right.UserId end)
        if args.mode == "correctness" then correctness()
        elseif args.mode == "admission" then admission()
        else error("unknown proof mode") end
    end)
    if session then session:Destroy() end
    readyConnection:Disconnect()
    StudioTestService:EndTest({
        kind = "RelayReliableEventsProofV1",
        ok = ok,
        failure = if ok then nil else tostring(failure),
        clients = args.clients,
        mode = args.mode,
        completed = completed,
    })
end)
