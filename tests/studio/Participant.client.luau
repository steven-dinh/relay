local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Fixture = require(ReplicatedStorage:WaitForChild("RelayProofDefinition"))
local control = ReplicatedStorage:WaitForChild("RelayProofControl")
local ready = ReplicatedStorage:WaitForChild("RelayProofReady")
local session
local connection
local received = {}
local schemaReceived = {}
local unreliableReceived = {}
local unreliableFailure
local poseResult = Fixture.poseRecord()
local poseObserver
local handlerMode = "normal"
local release = false
local entered = 0

local function listen()
    connection = assert(session.events.State:Connect(function(...)
        local sequence = Fixture.check(...)
        entered += 1
        if handlerMode == "error" then error("deliberate trusted test handler failure") end
        if handlerMode == "yield" then
            while not release do task.wait() end
        end
        table.insert(received, sequence)
    end))
end

control.OnClientInvoke = function(command, argument)
    if command == "start" or command == "mismatch" then
        if session then session:Destroy() end
        table.clear(received)
        table.clear(schemaReceived)
        table.clear(unreliableReceived)
        unreliableFailure = nil
        poseResult = Fixture.poseRecord()
        if poseObserver then poseObserver:Disconnect() poseObserver = nil end
        entered = 0
        handlerMode = "normal"
        release = false
        session = assert(Relay.createClient(Fixture.create(if command == "mismatch" then 2 else 1), {
            startupTimeoutSeconds = 10,
        }))
        listen()
        assert(session.events.SchemaState:Connect(function(...)
            table.insert(schemaReceived, Fixture.checkSchema(...))
        end))
        assert(session.events.UnreliableState:Connect(function(sampleId, value, enabled, ...)
            local ok, checkedId, checkedValue, checkedEnabled = pcall(Fixture.checkUnreliable, sampleId, value, enabled, ...)
            if not ok then unreliableFailure = tostring(checkedId) return end
            if checkedId <= Fixture.unreliableSampleCount then
                unreliableFailure = "S2C unreliable sample ID outside its range"
                return
            end
            unreliableReceived[checkedId] = { sampleId = checkedId, value = checkedValue, enabled = checkedEnabled }
        end))
        assert(session.events.PoseState:Connect(function(index, ...)
            Fixture.recordPose(poseResult, "delivery", index, ...)
        end))
        local ok, failure = session:Start()
        if command == "mismatch" then
            assert(not ok and failure.code == "DefinitionMismatch", "descriptor mismatch")
        else
            assert(ok, failure and failure.code)
            assert(ReplicatedStorage.RelayRemotes.Unreliable.ClassName == "UnreliableRemoteEvent",
                "native unreliable remote class")
        end
    elseif command == "schema-send" then
        assert(session.events.SchemaInput:Send(Fixture.schemaValues(false)))
        assert(session.events.SchemaInput:Send(Fixture.schemaValues(true)))
        local ok, failure = session.events.SchemaInput:Send(false, -129, -32_768, -2_147_483_648, Vector2.zero, "", CFrame.new())
        assert(not ok and failure.code == "InvalidPayload", "signed send overflow")
        ok, failure = session.events.SchemaInput:Send(false, -128, -32_768, -2_147_483_648, Vector2.zero, "", CFrame.new(), nil)
        assert(not ok and failure.code == "InvalidPayload", "signed send trailing nil")
    elseif command == "raw-overlong" then
        for _ = 1, argument do
            ReplicatedStorage.RelayRemotes.Reliable:FireServer(3, false, -128, -32_768, -2_147_483_648,
                Vector2.zero, "12345", CFrame.new())
        end
    elseif command == "pose-watch" then
        poseResult = Fixture.poseRecord()
        if poseObserver then poseObserver:Disconnect() end
        poseObserver = ReplicatedStorage.RelayRemotes.Reliable.OnClientEvent:Connect(function(id, index, ...)
            if id == 6 then Fixture.recordPose(poseResult, "raw", index, ...) end
        end)
    elseif command == "pose-sources" then
        return Fixture.poseSources()
    elseif command == "pose-send" then
        for index, case in Fixture.poseCases do
            local ok, failure = session.events.PoseInput:Send(index, case.value)
            assert(ok == case.accepted, "CFrame public sender classification")
            if not ok then
                assert(failure.code == "InvalidPayload")
                ReplicatedStorage.RelayRemotes.Reliable:FireServer(5, index, case.value)
            end
        end
    elseif command == "pose-read" then
        return poseResult
    elseif command == "schema-read" then
        return table.clone(schemaReceived)
    elseif command == "send" then
        for sequence = 1, argument do assert(session.events.Input:Send(Fixture.values(sequence))) end
    elseif command == "unreliable-send" then
        for sampleId = 1, Fixture.unreliableSampleCount do
            assert(session.events.UnreliableInput:Send(Fixture.unreliableValues(sampleId)))
        end
    elseif command == "unreliable-read" then
        assert(unreliableFailure == nil, "unreliable S2C validation: " .. tostring(unreliableFailure))
        local samples = {}
        for _, tuple in unreliableReceived do table.insert(samples, tuple) end
        table.sort(samples, function(left, right) return left.sampleId < right.sampleId end)
        return samples
    elseif command == "raw" then
        local remote = ReplicatedStorage.RelayRemotes.Reliable
        if argument == "matrix" then
            remote:FireServer()
            remote:FireServer("1", Fixture.values(1))
            remote:FireServer(65535, Fixture.values(1))
            remote:FireServer(2, Fixture.values(1))
            remote:FireServer(1, 1)
            remote:FireServer(1, 1, true, 255, 65535, 0.1, Vector3.zero, "extra")
            remote:FireServer(1, 1, true, 256, 65535, 0.1, Vector3.zero)
            remote:FireServer(1, 1, true, 255, 65535, 0 / 0, Vector3.zero)
            remote:FireServer(1, 1, true, 255, 65535, math.huge, Vector3.zero)
            remote:FireServer(1, 1, true, 255, 65535, 0.1, {})
            remote:FireServer({ { 1, 1 }, { 1, 2 } })
            remote:FireServer(buffer.create(8))
        else
            for _ = 1, argument do remote:FireServer("invalid") end
        end
    elseif command == "read" then
        return { received = table.clone(received), entered = entered }
    elseif command == "mode" then
        handlerMode = argument
        release = false
    elseif command == "release" then
        release = true
    elseif command == "disconnect" then
        connection:Disconnect()
        connection:Disconnect()
    elseif command == "listen" then
        listen()
    elseif command == "lost" then
        local ok, failure = session.events.Input:Send(Fixture.values(1))
        assert(not ok and failure.code == "Disconnected", "client must fail closed")
        assert(not session:Start(), "client must not reconnect")
    elseif command == "destroy" then
        if poseObserver then poseObserver:Disconnect() poseObserver = nil end
        session:Destroy()
        session:Destroy()
        local ok, failure = session.events.Input:Send(Fixture.values(1))
        assert(not ok and failure.code == "Destroyed", "destroyed client")
    elseif command == "timeout" then
        if session then session:Destroy() end
        session = assert(Relay.createClient(Fixture.create(), { startupTimeoutSeconds = 0.1 }))
        local ok, failure = session:Start()
        assert(not ok and failure.code == "StartupTimeout", "startup deadline")
        session = assert(Relay.createClient(Fixture.create(), { startupTimeoutSeconds = 10 }))
        local cancelled
        task.spawn(function()
            cancelled = table.pack(session:Start())
        end)
        assert(cancelled == nil, "startup must wait for the absent transport")
        session:Destroy()
        task.wait()
        assert(cancelled and not cancelled[1] and cancelled[2].code == "Destroyed",
            "destroy must resume startup without waiting for its deadline")
    elseif command == "absent" then
        local deadline = os.clock() + 10
        while ReplicatedStorage:FindFirstChild("RelayRemotes") ~= nil and os.clock() < deadline do task.wait() end
        assert(ReplicatedStorage:FindFirstChild("RelayRemotes") == nil, "old transport still replicated")
    else
        error("unknown proof command")
    end
    return true
end
ready:FireServer()
