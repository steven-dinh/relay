--!strict
local Relay = require("../../src/init")
local s = Relay.schema

type StreamState = {
	target: BasePart,
	entries: { [string]: { payload: buffer, position: Vector3 } },
	note: string?,
}

local entryShape = s.struct(
	s.field("payload" :: "payload", s.buffer(32)),
	(s.field("position" :: "position", s.Vector3F32(-100, 100)))
)
local entriesShape = s.map(s.string(24), entryShape, 4)
local stateShape = s.struct(
	s.field("target" :: "target", s.Instance("BasePart")),
	s.field("entries" :: "entries", entriesShape),
	(s.field("note" :: "note", s.optional(s.string(32))))
)
local streamFields = s.ordered(
	s.field("serverTime", s.f64(0, 1e12)),
	(s.field("state", s.optional(stateShape)))
)
local vectorFields = s.fields(
	s.field("serverTime", s.f64(0, 1e12)),
	(s.field("position", s.optional(s.Vector3F32(-100, 100))))
)
local definition, definitionError = Relay.define({ name = "OrderedStreams", version = 1, events = {
	Output = {
		id = 1,
		direction = "ServerToClient" :: "ServerToClient",
		delivery = "OrderedUnreliable" :: "OrderedUnreliable",
		fields = streamFields,
	},
	HelperOutputOptions = s.serverToClient(2, streamFields, { delivery = "OrderedUnreliable" }),
	HelperOutputString = s.serverToClient(3, streamFields, "OrderedUnreliable"),
	VectorOutputFields = s.serverToClient(4, vectorFields, { delivery = "OrderedUnreliable" }),
} })
local token = assert(definition, definitionError and definitionError.message)
local serverResult, serverError = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 8, refillPerSecond = 8 },
	aggregate = { capacity = 16, refillPerSecond = 16 },
} })
local server = assert(serverResult, serverError and serverError.message)
local clientResult, clientError = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientError and clientError.message)
local player: Player = error("type-only fixture")
local target: BasePart = error("type-only fixture")
local state: StreamState = {
	target = target,
	entries = { latest = { payload = buffer.create(4), position = Vector3.zero } },
	note = nil,
}
local options: Relay.StreamOptions = { rate = 20, fastRate = 40, keepalive = 2, epsilon = 0 }

local falseDefinition, falseError = Relay.define({ name = "OrderedStreamsNoPacking", version = 1,
	bitPacking = false :: false, events = {
		Output = {
			id = 1, direction = "ServerToClient" :: "ServerToClient",
			delivery = "OrderedUnreliable" :: "OrderedUnreliable", fields = streamFields,
		},
	} })
local falseToken = assert(falseDefinition, falseError and falseError.message)
local falseServerResult, falseServerError = Relay.createServer(falseToken, { inboundRate = {
	perPlayer = { capacity = 8, refillPerSecond = 8 },
	aggregate = { capacity = 16, refillPerSecond = 16 },
} })
local falseServer = assert(falseServerResult, falseServerError and falseServerError.message)
local falseBroadcast, falseBroadcastError = falseServer.events.Output:CreateBroadcastStream(options)
local explicitFalse: Relay.StreamHandle<StreamState> = assert(falseBroadcast, falseBroadcastError and falseBroadcastError.message)

client.events.Output:Connect(function(serverTime, value)
	local exactTime: number = serverTime
	local exactState: StreamState? = value
	print(exactTime, exactState)
end)
client.events.HelperOutputOptions:Connect(function(serverTime, value)
	local exactTime: number = serverTime
	local exactState: StreamState? = value
	print(exactTime, exactState)
end)
client.events.VectorOutputFields:Connect(function(serverTime, value)
	local exactTime: number = serverTime
	local exactPosition: Vector3? = value
	print(exactTime, exactPosition)
end)

local targetedResult, targetedError = server.events.Output:CreateStream(player, options)
local targeted: Relay.StreamHandle<StreamState> = assert(targetedResult, targetedError and targetedError.message)
local broadcastResult, broadcastError = server.events.Output:CreateBroadcastStream(options)
local broadcast: Relay.StreamHandle<StreamState> = assert(broadcastResult, broadcastError and broadcastError.message)
local helperTargetResult, helperTargetError = server.events.HelperOutputOptions:CreateStream(player, options)
local helperTarget: Relay.StreamHandle<StreamState> = assert(helperTargetResult, helperTargetError and helperTargetError.message)
local helperBroadcastResult, helperBroadcastError = server.events.HelperOutputOptions:CreateBroadcastStream(options)
local helperBroadcast: Relay.StreamHandle<StreamState> = assert(helperBroadcastResult,
	helperBroadcastError and helperBroadcastError.message)
local stringBroadcastResult, stringBroadcastError = server.events.HelperOutputString:CreateBroadcastStream(options)
local stringBroadcast: Relay.StreamHandle<StreamState> = assert(stringBroadcastResult,
	stringBroadcastError and stringBroadcastError.message)
local vectorBroadcastResult, vectorBroadcastError = server.events.VectorOutputFields:CreateBroadcastStream(options)
local vectorBroadcast: Relay.StreamHandle<Vector3> = assert(vectorBroadcastResult,
	vectorBroadcastError and vectorBroadcastError.message)
helperTarget:Set(state)
helperBroadcast:Set(state)
stringBroadcast:Set(state)
local position: Vector3 = Vector3.zero
vectorBroadcast:Set(position)

local setOk: boolean, setError: Relay.RelayError? = targeted:Set(state)
local clearOk: boolean, clearError: Relay.RelayError? = targeted:Clear()
local urgentOk: boolean, urgentError: Relay.RelayError? = targeted:Urgent()
local fastOk: boolean, fastError: Relay.RelayError? = targeted:SetFast(true)
local status: Relay.StreamStatus = targeted:GetStatus()
local statusState: "Idle" | "Active" | "Paused" | "Destroyed" = status.state
local statusFast: boolean = status.fast
local statusPending: boolean = status.pending
local lastError: Relay.RelayError? = status.lastError
local lastSentTime: number? = status.lastSentTime
targeted:Destroy()

broadcast:Set(state)
broadcast:Clear()
broadcast:Urgent()
broadcast:SetFast(false)
local broadcastStatus: Relay.StreamStatus = broadcast:GetStatus()
broadcast:Destroy()
print(setOk, setError, clearOk, clearError, urgentOk, urgentError, fastOk, fastError,
	statusState, statusFast, statusPending, lastError, lastSentTime, broadcastStatus, explicitFalse,
	helperTarget, helperBroadcast, stringBroadcast, vectorBroadcast)
