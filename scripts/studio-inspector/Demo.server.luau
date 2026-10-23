local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end

local Relay = require(ReplicatedStorage.Relay)
local Attachment = require(ReplicatedStorage.RelayInspectorTools.Attachment)

local definition = assert(Relay.define({
    name = "StudioInspectorDemo",
    version = 1,
    readiness = false,
    events = {
        Pulse = {
            id = 1,
            direction = "ServerToClient",
            fields = { { name = "sequence", type = "u32" } },
        },
    },
}))

local session, createFailure = Relay.createServer(definition, {
    inboundRate = {
        perPlayer = { capacity = 16, refillPerSecond = 8 },
        aggregate = { capacity = 128, refillPerSecond = 64 },
    },
    diagnostics = { traffic = true, reports = true },
})
assert(session, createFailure and createFailure.code or "createServer failed")

local attachment, attachFailure = Attachment.Attach(Relay, definition, session, "Inspector demo")
assert(attachment, attachFailure)

local started, startFailure = session:Start()
if not started then
    if startFailure ~= nil then attachment:RecordFailure(startFailure.code) end
    session:Destroy()
    script.Destroying:Connect(function() attachment:Destroy() end)
    return
end

local readyPlayers, readinessFailure = session.events.Pulse:GetReadyPlayers()
if readyPlayers == nil and readinessFailure ~= nil then
    attachment:RecordFailure(readinessFailure.code)
end

local elapsed = 0
local sequence = 0
local finished = false
local heartbeatConnection

local function stop()
    if finished then return end
    finished = true
    if heartbeatConnection ~= nil then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
    session:Destroy()
end

heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
    if finished then return end
    elapsed += deltaTime
    if elapsed < 1 then return end
    elapsed = 0
    sequence = sequence % 1_000 + 1
    session.events.Pulse:Broadcast(sequence)
    if sequence >= 30 then stop() end
end)

script.Destroying:Connect(function()
    stop()
    attachment:Destroy()
end)
