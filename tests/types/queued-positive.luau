--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local reusableFields = s.ordered(s.field("sequence", s.u16()), (s.field("enabled", s.boolean())))
local definition, definitionProblem = Relay.define({
    name = "QueuedTypes", version = 1,
    events = {
        ServerBatch = {
            id = 1, direction = "ServerToClient" :: "ServerToClient",
            delivery = "Reliable" :: "Reliable", queue = "Batch" :: "Batch",
            fields = reusableFields,
        },
        ClientBatch = {
            id = 2, direction = "ClientToServer" :: "ClientToServer",
            delivery = "Reliable" :: "Reliable", queue = "Batch" :: "Batch",
            fields = s.ordered(s.field("input", s.enum("Jump" :: "Jump", "Move" :: "Move"))),
        },
        ServerState = {
            id = 3, direction = "ServerToClient" :: "ServerToClient",
            delivery = "Unreliable" :: "Unreliable", queue = "State" :: "State",
            fields = s.ordered(s.field("tick", s.u32()), (s.field("position", s.Vector3F32(-100, 100)))),
        },
        ClientState = {
            id = 4, direction = "ClientToServer" :: "ClientToServer",
            delivery = "Unreliable" :: "Unreliable", queue = "State" :: "State",
            fields = s.ordered(s.field("aim", s.Vector2F32(-1, 1))),
        },
        Immediate = s.serverToClient(5, s.ordered(s.field("value", s.u8()))),
        ReusedBatch = {
            id = 6, direction = "ServerToClient" :: "ServerToClient",
            queue = "Batch" :: "Batch", fields = reusableFields,
        },
    },
})
local token = assert(definition, definitionProblem and definitionProblem.message)
local serverValue, serverProblem = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverProblem and serverProblem.message)
local clientValue, clientProblem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientProblem and clientProblem.message)
local player: Player = error("type-only fixture")

local batchValue, batchProblem = server:CreateBatch({ player }, 0.02)
local batch = assert(batchValue, batchProblem and batchProblem.message)
local publicBatch: Relay.BatchHandle<typeof(batch.events)> = batch
local batchSent: boolean, batchSendProblem: Relay.RelayError? = batch.events.ServerBatch:Send(7, true)
local stateInBatchSent: boolean, stateInBatchProblem: Relay.RelayError? = batch.events.ServerState:Send(8, Vector3.new())
local reusedSent: boolean, reusedProblem: Relay.RelayError? = batch.events.ReusedBatch:Send(9, false)
local batchOk: boolean, batchError: Relay.RelayError?, batchReport: Relay.QueueReport = publicBatch:Flush()
local report: Relay.QueueReport = batchReport
local logicalHandoffs: number = report.logicalHandoffs
local reliableHandoffs: number = report.reliableHandoffs
local unreliableHandoffs: number = report.unreliableHandoffs
local selected: number = report.selected
local remaining: number = report.remaining
local expired: number = report.expired
local inspection = assert((Relay.inspect(token)))
local budget = inspection.events.ServerBatch
if budget.queuedBytes then
    local bodyMaximum: number = budget.queuedBytes.bodyMaximum
    local singleRecordMaximum: number = budget.queuedBytes.singleRecordMaximum
    local engineBytes: "Unknown" = budget.queuedBytes.robloxEncodedBytes
    print(bodyMaximum, singleRecordMaximum, engineBytes)
end
if budget.bytes.representation == "NativeTuple" then
    local stringBytes: number = budget.bytes.maximumStringContentBytes
    local engineBytes: "Unknown" = budget.bytes.robloxEncodedBytes
    print(stringBytes, engineBytes)
else
    local rawMaximum: number = budget.bytes.maximum
    print(rawMaximum)
end
batch:Cancel()

local stateValue, stateProblem = server:CreateState({ player }, 0.02)
local state = assert(stateValue, stateProblem and stateProblem.message)
local publicState: Relay.StateHandle<typeof(state.events)> = state
local put: boolean, putProblem: Relay.RelayError? = state.events.ServerState:Put(0, "High", 9, Vector3.new())
local replace: boolean, replaceProblem: Relay.RelayError? = state.events.ServerState:Put(0, "Low", 10, Vector3.new(1, 2, 3))
local removed: boolean, removeProblem: Relay.RelayError? = state.events.ServerState:Remove(0)
local stateOk: boolean, stateError: Relay.RelayError?, stateReport: Relay.QueueReport = state:Flush()
local status: Relay.StateStatus = publicState:GetStatus()
local statusState: "Open" | "Flushing" | "Destroyed" = status.state
local activeKeys: number = status.activeKeys
local pendingKeys: number = status.pendingKeys
local bodyBytes: number = status.pendingBodyBytes
if status.lastFlush then
    local lastReport: Relay.QueueReport = status.lastFlush.report
    print(lastReport.expired)
end
publicState:Destroy()

local clientBatchValue, clientBatchProblem = client:CreateBatch(0.02)
local clientBatch = assert(clientBatchValue, clientBatchProblem and clientBatchProblem.message)
local inputSent: boolean, inputProblem: Relay.RelayError? = clientBatch.events.ClientBatch:Send("Jump")
local clientStateValue, clientStateProblem = client:CreateState(0.02)
local clientState = assert(clientStateValue, clientStateProblem and clientStateProblem.message)
local aimSent: boolean, aimProblem: Relay.RelayError? = clientState.events.ClientState:Put(4, "Normal", Vector2.new())
local callback, callbackProblem = server.events.ClientBatch:Connect(function(sender, input)
    local actualPlayer: Player = sender
    local actualInput: "Jump" | "Move" = input
    print(actualPlayer, actualInput)
end)
print(publicBatch, batchSent, batchSendProblem, stateInBatchSent, stateInBatchProblem, reusedSent, reusedProblem, batchOk, batchError,
    logicalHandoffs, reliableHandoffs, unreliableHandoffs, selected, remaining, expired,
    put, putProblem, replace, replaceProblem, removed, removeProblem, stateOk, stateError,
    stateReport.selected, publicState, statusState, bodyBytes, inputSent, inputProblem, aimSent, aimProblem,
    activeKeys, pendingKeys, callback, callbackProblem)
