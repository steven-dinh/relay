--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local mode = s.enum("Idle" :: "Idle", "Run" :: "Run", "Jump" :: "Jump")
local definition, issue = Relay.define({
	name = "OutboundPackingTypes", version = 1, bitPacking = true,
	outboundBytes = { capacity = 4096, refillPerSecond = 2048 },
	events = {
		Input = s.clientToServer(1, s.ordered(s.field("active" :: "active", s.boolean()),
			s.field("mode" :: "mode", mode), s.field("maybeActive" :: "maybeActive", s.optional(s.boolean())),
			(s.field("maybeMode" :: "maybeMode", s.optional(mode))))),
		Output = s.serverToClient(2, s.ordered(s.field("active" :: "active", s.boolean()),
			(s.field("mode" :: "mode", mode)))),
		Batch = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
			fields = s.ordered(s.field("active" :: "active", s.boolean()), (s.field("mode" :: "mode", mode))) },
		State = { id = 4, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
			fields = s.ordered(s.field("active" :: "active", s.boolean()), (s.field("mode" :: "mode", mode))) },
	},
})
local token = assert(definition, issue and issue.message)
local inspectionValue, inspectionIssue = Relay.inspect(token)
local inspection = assert(inspectionValue, inspectionIssue and inspectionIssue.message)
local packed: boolean = inspection.bitPacking
local capacity: number? = inspection.outboundBytes and inspection.outboundBytes.capacity
local limit: number = inspection.limits.compactRotationErrorRadians
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")

local serverDiagnostics = server:GetDiagnostics()
local outboundPolicy: Relay.EndpointRate? = serverDiagnostics.outboundBytes
local rejectedCount: number = serverDiagnostics.counters.outboundByteRejected
local chargedBytes: number = serverDiagnostics.counters.outboundBytesCharged
local clientDiagnostics = client:GetDiagnostics()
local clientOutboundPolicy: nil = clientDiagnostics.outboundBytes
client.events.Input:Send(true, "Run", false, "Jump")
server.events.Output:Send(player, true, "Idle")

local batchValue, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchValue, batchIssue and batchIssue.message)
batch.events.Batch:Send(true, "Run")
local batchStatus = batch:GetStatus()
local batchState: "Open" | "Sealed" | "Terminal" = batchStatus.state
local pendingRecords: number = batchStatus.pendingRecords
local lastBatchReport: Relay.QueueReport? = batchStatus.lastFlush and batchStatus.lastFlush.report
local stateValue, stateIssue = server:CreateState({ player }, 0.02)
local state = assert(stateValue, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", true, "Idle")
local stateStatus = state:GetStatus()
local stateKeys: number = stateStatus.pendingKeys
print(packed, capacity, limit, outboundPolicy, rejectedCount, chargedBytes, clientOutboundPolicy,
	batchState, pendingRecords, lastBatchReport, stateKeys)
