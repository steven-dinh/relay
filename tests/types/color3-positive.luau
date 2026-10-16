--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local definition, _problem = Relay.define({
    name = "Color3Types",
    version = 1,
    events = {
        Input = s.clientToServer(1, s.ordered(s.field("tint", s.Color3()))),
        Output = s.serverToClient(2, s.ordered(s.field("tint", { type = "Color3" :: "Color3" }))),
        Composite = s.clientToServer(3, s.ordered(s.field("paint", s.struct(
            s.field("swatches" :: "swatches", s.array(s.Color3(), 3))
        )))),
        ClientBatch = {
            id = 4, direction = "ClientToServer" :: "ClientToServer",
            queue = "Batch" :: "Batch", fields = s.ordered(s.field("tint", s.Color3())),
        },
        ClientState = {
            id = 5, direction = "ClientToServer" :: "ClientToServer",
            queue = "State" :: "State", fields = s.ordered(s.field("tint", s.Color3())),
        },
        ServerBatch = {
            id = 6, direction = "ServerToClient" :: "ServerToClient",
            queue = "Batch" :: "Batch", fields = s.ordered(s.field("tint", s.Color3())),
        },
        ServerState = {
            id = 7, direction = "ServerToClient" :: "ServerToClient",
            queue = "State" :: "State", fields = s.ordered(s.field("tint", s.Color3())),
        },
        Optional = s.clientToServer(8, s.ordered(s.field("paint", s.struct(
            s.field("accent" :: "accent", s.optional(s.Color3()))
        )))),
    },
    requests = { Paint = s.request(9, s.ordered(s.field("tint", s.Color3())), s.Color3()) },
})
local token = assert(definition, "Color3 definition")
local serverResult, _serverProblem = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, "Color3 server")
local clientResult, _clientProblem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, "Color3 client")
local player: Player = error("type-only fixture")
local tint = Color3.new(0.25, 0.5, 0.75)

server.events.Input:Connect(function(sender, value)
    local actualPlayer: Player = sender
    local actualColor: Color3 = value
    print(actualPlayer, actualColor)
end)
client.events.Output:Connect(function(value)
    local actualColor: Color3 = value
    print(actualColor)
end)
server.events.Composite:Connect(function(sender, paint)
    local actualSwatches: { Color3 } = paint.swatches
    print(sender, actualSwatches)
end)
server.events.Optional:Connect(function(sender, paint)
    local actualAccent: Color3? = paint.accent
    print(sender, actualAccent)
end)
server.requests.Paint:Connect(function(sender, value)
    local actualPlayer: Player = sender
    local actualColor: Color3 = value
    print(actualPlayer)
    return actualColor
end)

local inputSent: boolean, inputProblem: Relay.RelayError? = client.events.Input:Send(tint)
local outputSent: boolean, outputProblem: Relay.RelayError? = server.events.Output:Send(player, tint)
local broadcastSent: boolean, broadcastProblem: Relay.RelayError? = server.events.Output:Broadcast(tint)
local nestedSent: boolean, nestedProblem: Relay.RelayError? = client.events.Composite:Send({ swatches = { tint } })
local optionalSent: boolean, optionalProblem: Relay.RelayError? = client.events.Optional:Send({ accent = tint })
local requestValue, requestProblem = client.requests.Paint:Request(1, tint)
if requestValue then
    local result = requestValue:Await()
    if result.ok then
        local response: Color3 = result.value
        print(response)
    end
end

local serverBatchResult, _serverBatchError = server:CreateBatch({ player }, 0.02)
local serverBatch = assert(serverBatchResult, "server batch")
local serverBatchSent: boolean, serverBatchProblem: Relay.RelayError? = serverBatch.events.ServerBatch:Send(tint)
local serverStateResult, _serverStateError = server:CreateState({ player }, 0.02)
local serverState = assert(serverStateResult, "server state")
local serverPut: boolean, serverPutProblem: Relay.RelayError? = serverState.events.ServerState:Put(1, "High", tint)
local clientBatchResult, _clientBatchError = client:CreateBatch(0.02)
local clientBatch = assert(clientBatchResult, "client batch")
local clientBatchSent: boolean, clientBatchProblem: Relay.RelayError? = clientBatch.events.ClientBatch:Send(tint)
local clientStateResult, _clientStateError = client:CreateState(0.02)
local clientState = assert(clientStateResult, "client state")
local clientPut: boolean, clientPutProblem: Relay.RelayError? = clientState.events.ClientState:Put(1, "Normal", tint)
print(inputSent, inputProblem, outputSent, outputProblem, broadcastSent, broadcastProblem, nestedSent,
    nestedProblem, optionalSent, optionalProblem, requestProblem, serverBatchSent, serverBatchProblem, serverPut, serverPutProblem,
    clientBatchSent, clientBatchProblem, clientPut, clientPutProblem)
