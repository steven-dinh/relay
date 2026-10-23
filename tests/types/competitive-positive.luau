--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local clientServerTime = s.field("serverTime" :: "serverTime", s.f64(0, 2^42))
local clientSequence = s.field("sequence" :: "sequence", s.u8())
local clientEnabled = s.field("enabled" :: "enabled", s.boolean())
local clientAction = s.field("action" :: "action", s.enum("Jump" :: "Jump", "Move" :: "Move"))
local timestampHelperFields = s.fields(
    { serverTime = s.f64(0, 2^42) },
    { origin = s.Vector3F32(-100, 100) },
    { direction = s.Vector3F32(-1, 1) }
)
local clientBatchFields = s.ordered(clientServerTime, clientSequence)
local clientStateFields = s.ordered(clientServerTime, clientEnabled)
local immediateFields = s.ordered(clientServerTime, clientAction)
local schema = {
    name = "CompetitiveTypes",
    version = 1,
    events = {
        ClientBatch = s.clientToServer(1, clientBatchFields, { queue = "Batch", timestampWindow = 0.5 }),
        ClientState = s.clientToServer(2, clientStateFields, { queue = "State", timestampWindow = 1 }),
        ServerBatch = {
            id = 3,
            direction = "ServerToClient" :: "ServerToClient",
            queue = "Batch" :: "Batch",
            fields = s.ordered(s.field("sequence" :: "sequence", s.u8())),
        },
        ServerState = {
            id = 4,
            direction = "ServerToClient" :: "ServerToClient",
            queue = "State" :: "State",
            fields = s.ordered(s.field("value" :: "value", s.u8())),
        },
        Immediate = s.clientToServer(5, immediateFields, { timestampWindow = 0.25 }),
        Ordered = {
            id = 6,
            direction = "ClientToServer" :: "ClientToServer",
            delivery = "OrderedUnreliable" :: "OrderedUnreliable",
            fields = s.ordered(s.field("sequence" :: "sequence", s.u8())),
        },
        TimestampHelper = s.clientToServer(7, timestampHelperFields, { timestampWindow = 0.5 }),
    },
    requests = require("./rpc-methods"),
}
local definition, defineError = Relay.define(schema)
local token = assert(definition, defineError and defineError.message)
local serverValue, serverError = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 32, refillPerSecond = 32 },
    aggregate = { capacity = 64, refillPerSecond = 64 },
} })
local server = assert(serverValue, serverError and serverError.message)
local clientValue, clientError = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientError and clientError.message)
local player: Player = error("type-only fixture")
local diagnosticsOptions: Relay.SessionDiagnosticsOptions = { traffic = true, reports = true }
local diagnosticServerValue, diagnosticServerError = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 32, refillPerSecond = 32 },
    aggregate = { capacity = 64, refillPerSecond = 64 },
}, diagnostics = diagnosticsOptions })
local diagnosticServer = assert(diagnosticServerValue, diagnosticServerError and diagnosticServerError.message)
local diagnosticClientValue, diagnosticClientError = Relay.createClient(token, {
    startupTimeoutSeconds = 3, diagnostics = { traffic = true },
})
local diagnosticClient = assert(diagnosticClientValue, diagnosticClientError and diagnosticClientError.message)
local serverDiagnostics: Relay.ServerDiagnostics = diagnosticServer:GetDiagnostics()
local clientDiagnostics: Relay.ClientDiagnostics = diagnosticClient:GetDiagnostics()
local traffic: Relay.TrafficDiagnostics? = serverDiagnostics.traffic
local reports: Relay.DiagnosticReports? = clientDiagnostics.reports
if traffic then
    local bytes: number = traffic.channels.Reliable.sentRecipientBytes
    local endpoint: Relay.EndpointTraffic? = traffic.endpoints[1]
    if endpoint then
        local endpointKind: "Event" | "Request" = endpoint.kind
        print(bytes, endpoint.id, endpointKind, endpoint.channels.Unreliable.unmeasuredPackets)
    end
end
if reports then
    local reportEntry: Relay.DiagnosticReportEntry? = reports.entries[1]
    if reportEntry then
        local reason: Relay.DiagnosticReportReason = reportEntry.reason
        local channel: ("Reliable" | "Unreliable")? = reportEntry.channel
        print(reports.capacity, reports.total, reason, channel)
    end
end

local pacedValue, pacedError = client:CreatePacedBatcher(1 / 30, { manual = true })
local paced = assert(pacedValue, pacedError and pacedError.message)
local publicPaced: Relay.PacedBatcherHandle<typeof(paced.events)> = paced
local pacedSend: boolean, pacedSendError: Relay.RelayError? = publicPaced.events.ClientBatch:Send(4)
local pacedStateSend: boolean, pacedStateError: Relay.RelayError? = publicPaced.events.ClientState:Send(false)
local pacedStatus: Relay.PacedBatcherStatus = publicPaced:GetStatus()
local pacedPending: number = pacedStatus.pendingRecords + pacedStatus.pendingUnits
local pacedManual: boolean = pacedStatus.manual
local pacedStep: boolean, pacedStepError: Relay.RelayError?, pacedStepReport: Relay.QueueReport = publicPaced:Step()
local pacedStepStatus = pacedStatus.lastStep
if pacedStepStatus then print(pacedStepStatus.report.selected) end
publicPaced:Destroy()

local sent: boolean, sendError: Relay.RelayError? = client.events.Immediate:Send("Jump")
local helperSent: boolean, helperSendError: Relay.RelayError? = client.events.TimestampHelper:Send(
    Vector3.new(0, 0, 0), Vector3.new(0, 0, 1)
)
local orderedSent: boolean, orderedError: Relay.RelayError? = client.events.Ordered:Send(5)
local batchValue, batchError = client:CreateBatch(0.02)
local batch = assert(batchValue, batchError and batchError.message)
local batchSent: boolean, batchSendError: Relay.RelayError? = batch.events.ClientBatch:Send(6)
local clientStateValue, clientStateError = client:CreateState(0.02)
local clientState = assert(clientStateValue, clientStateError and clientStateError.message)
local put: boolean, putError: Relay.RelayError? = clientState.events.ClientState:Put(9, "High", true)

local callback, callbackError = server.events.Immediate:Connect(function(sender, serverTime, action)
    local actualPlayer: Player = sender
    local actualTime: number = serverTime
    local actualAction: "Jump" | "Move" = action
    print(actualPlayer, actualTime, actualAction)
end)
local helperCallback, helperCallbackError = server.events.TimestampHelper:Connect(function(sender, serverTime, origin, direction)
    local actualPlayer: Player = sender
    local actualTime: number = serverTime
    local actualOrigin: Vector3 = origin
    local actualDirection: Vector3 = direction
    print(actualPlayer, actualTime, actualOrigin, actualDirection)
end)
local stateValue, stateError = server:CreateState({ player }, 0.02, {
    deferOutbound = true,
    progress = "Independent",
})
local state = assert(stateValue, stateError and stateError.message)
local current: Relay.StateStatus = state:GetStatus()
if current.recipients then
    local recipient: Relay.QueueRecipientProgress = current.recipients[1]
    local recipientPlayer: Player = recipient.player
    local remaining: number = recipient.remaining
    print(recipientPlayer, remaining)
end
local stateFlushOk, stateFlushError, stateReport = state:Flush()
local typedStateReport: Relay.QueueReport = stateReport
if typedStateReport.recipients then
    local reportRecipient: Relay.QueueRecipientProgress = typedStateReport.recipients[1]
    local handoffs: number = reportRecipient.logicalHandoffs
    local recipientError: Relay.RelayError? = reportRecipient.error
    print(handoffs, recipientError)
end
local inspectionValue, inspectionError = Relay.inspect(token)
local inspection = assert(inspectionValue, inspectionError and inspectionError.message)
local immediateTimestampWindow: number? = inspection.events.Immediate.timestampWindow
local protocol: "RR1" | "RR2" | "RR3" | "RR5" | "RR6" | "RR7" | "RR8" | "RR9" | "RR10"
    | "RR11" | "RR12" | "RR13" | "RR14" | "RR15" | "RR16" | "RR17" = inspection.protocol

print(pacedSend, pacedSendError, pacedStateSend, pacedStateError, pacedPending, pacedManual, pacedStep,
    pacedStepError, pacedStepReport.selected, stateFlushOk, stateFlushError,
    sent, sendError, helperSent, helperSendError, orderedSent, orderedError, batchSent, batchSendError, put, putError,
    callback, callbackError, helperCallback, helperCallbackError,
    typedStateReport.selected, typedStateReport.remaining, immediateTimestampWindow, protocol)

local nilTimestampField = s.field("serverTime", s.f64(0, 2^42))
local nilTimestampPayload = s.field("payload", s.u8())
local nilTimestampFields = s.ordered(nilTimestampField, nilTimestampPayload)
local nilTimestampDefinitionValue, nilTimestampDefinitionError = Relay.define({
    name = "NilTimestampWindow",
    version = 1,
    events = {
        Immediate = {
            id = 1,
            direction = "ClientToServer" :: "ClientToServer",
            timestampWindow = nil,
            fields = nilTimestampFields,
        },
        Batch = {
            id = 2,
            direction = "ClientToServer" :: "ClientToServer",
            queue = "Batch" :: "Batch",
            timestampWindow = nil,
            fields = nilTimestampFields,
        },
        State = {
            id = 3,
            direction = "ClientToServer" :: "ClientToServer",
            queue = "State" :: "State",
            timestampWindow = nil,
            fields = nilTimestampFields,
        },
    },
})
local nilTimestampDefinition = assert(nilTimestampDefinitionValue, nilTimestampDefinitionError and nilTimestampDefinitionError.message)
local nilTimestampClientValue = Relay.createClient(nilTimestampDefinition, { startupTimeoutSeconds = 3 })
local nilTimestampClient = assert(nilTimestampClientValue)
nilTimestampClient.events.Immediate:Send(0.5, 2)
local nilTimestampBatchValue = nilTimestampClient:CreateBatch(0.02)
local nilTimestampBatch = assert(nilTimestampBatchValue)
nilTimestampBatch.events.Batch:Send(0.5, 2)
local nilTimestampStateValue = nilTimestampClient:CreateState(0.02)
local nilTimestampState = assert(nilTimestampStateValue)
nilTimestampState.events.State:Put(1, "High", 0.5, 2)
