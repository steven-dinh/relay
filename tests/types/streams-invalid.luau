--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local streamFields = s.ordered(
	s.field("serverTime", s.f64(0, 1e12)),
	(s.field("state", s.optional(s.u16())))
)
local definition, definitionError = Relay.define({ name = "OrderedStreamsInvalid", version = 1, events = {
	Output = {
		id = 1, direction = "ServerToClient" :: "ServerToClient",
		delivery = "OrderedUnreliable" :: "OrderedUnreliable", fields = streamFields,
	},
	Input = {
		id = 2, direction = "ClientToServer" :: "ClientToServer",
		delivery = "OrderedUnreliable" :: "OrderedUnreliable", fields = streamFields,
	},
	ReliableOutput = {
		id = 3, direction = "ServerToClient" :: "ServerToClient",
		delivery = "Reliable" :: "Reliable", fields = streamFields,
	},
	UnreliableOutput = {
		id = 4, direction = "ServerToClient" :: "ServerToClient",
		delivery = "Unreliable" :: "Unreliable", fields = streamFields,
	},
	BatchOutput = {
		id = 5, direction = "ServerToClient" :: "ServerToClient",
		delivery = "Reliable" :: "Reliable",
		queue = "Batch" :: "Batch", fields = streamFields,
	},
	StateOutput = {
		id = 6, direction = "ServerToClient" :: "ServerToClient",
		delivery = "Unreliable" :: "Unreliable",
		queue = "State" :: "State", fields = streamFields,
	},
	OneField = {
		id = 7, direction = "ServerToClient" :: "ServerToClient",
		delivery = "OrderedUnreliable" :: "OrderedUnreliable",
		fields = s.ordered(s.field("serverTime", s.f64(0, 1e12))),
	},
	WrongOrder = {
		id = 8, direction = "ServerToClient" :: "ServerToClient",
		delivery = "OrderedUnreliable" :: "OrderedUnreliable",
		fields = s.ordered(
			s.field("state", s.optional(s.u16())),
			(s.field("serverTime", s.f64(0, 1e12)))
		),
	},
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
local options: Relay.StreamOptions = { rate = 20 }

local streamResult, streamError = server.events.Output:CreateStream(player, options)
local stream = assert(streamResult, streamError and streamError.message)
stream:Set("wrong")
stream:Set(nil)
server.events.Output:CreateStream(7, options)
server.events.Output:CreateBroadcastStream({ rate = "fast" })

server.events.Input:CreateStream(player, options)
server.events.ReliableOutput:CreateBroadcastStream(options)
server.events.UnreliableOutput:CreateBroadcastStream(options)
server.events.BatchOutput:CreateBroadcastStream(options)
server.events.StateOutput:CreateStream(player, options)
server.events.OneField:CreateBroadcastStream(options)
server.events.WrongOrder:CreateStream(player, options)
client.events.Output:CreateBroadcastStream(options)

local packedDefinition, packedError = Relay.define({ name = "OrderedStreamsPacked", version = 1,
	bitPacking = true :: true, events = {
		Output = {
			id = 1, direction = "ServerToClient" :: "ServerToClient",
			delivery = "OrderedUnreliable" :: "OrderedUnreliable", fields = streamFields,
		},
	} })
local packedToken = assert(packedDefinition, packedError and packedError.message)
local packedResult, packedServerError = Relay.createServer(packedToken, { inboundRate = {
	perPlayer = { capacity = 8, refillPerSecond = 8 },
	aggregate = { capacity = 16, refillPerSecond = 16 },
} })
local packedServer = assert(packedResult, packedServerError and packedServerError.message)
packedServer.events.Output:CreateBroadcastStream(options)

local function broadHelper(delivery: "Reliable" | "Unreliable" | "OrderedUnreliable")
	return s.serverToClient(3, streamFields, { delivery = delivery })
end
local helperDefinition, helperDefinitionError = Relay.define({ name = "OrderedStreamsHelperFallback", version = 1, events = {
	DefaultOutput = s.serverToClient(1, streamFields),
	EmptyOptions = s.serverToClient(2, streamFields, {}),
	BroadOptions = broadHelper("OrderedUnreliable"),
	QueuedOutput = s.serverToClient(4, streamFields, {
		delivery = "Reliable" :: "Reliable", queue = "Batch" :: "Batch",
	}),
} })
local helperToken = assert(helperDefinition, helperDefinitionError and helperDefinitionError.message)
local helperServerResult, helperServerError = Relay.createServer(helperToken, { inboundRate = {
	perPlayer = { capacity = 8, refillPerSecond = 8 },
	aggregate = { capacity = 16, refillPerSecond = 16 },
} })
local helperServer = assert(helperServerResult, helperServerError and helperServerError.message)
helperServer.events.DefaultOutput:CreateBroadcastStream(options)
helperServer.events.EmptyOptions:CreateBroadcastStream(options)
helperServer.events.BroadOptions:CreateBroadcastStream(options)
helperServer.events.QueuedOutput:CreateBroadcastStream(options)
