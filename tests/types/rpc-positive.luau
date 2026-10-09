--!strict
local Relay = require("../../src/init")
local Methods = require("./rpc-methods")
local definition, problem = Relay.define({
    name = "RpcConsumer", version = 1,
    events = { Input = Relay.schema.clientToServer(1, Relay.schema.ordered()) },
    requests = Methods,
})
local token = assert(definition, problem and problem.message)
local serverValue, serverProblem = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverProblem and serverProblem.message)
local clientValue, clientProblem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientProblem and clientProblem.message)
server.requests.Inspect:Connect(function(player, itemId)
    local actualPlayer: Player = player
    local actualId: number = itemId
    print(actualPlayer, actualId)
    return { mode = "Owned", items = { { id = itemId, count = 3 } } }
end)
server.requests.Enabled:Connect(function(player)
    local actualPlayer: Player = player
    print(actualPlayer)
    return false
end)
server.requests.Selected:Connect(function(player, slot)
    local actualSlot: number = slot
    print(player, actualSlot)
    return nil
end)
local pendingValue, requestProblem = client.requests.Inspect:Request(5, 123)
local pending = assert(pendingValue, requestProblem and requestProblem.message)
local result = pending:Await()
if result.ok then
    local mode: "Owned" | "Missing" = result.value.mode
    local count: number = result.value.items[1].count
    print(mode, count)
else
    local errorCode: Relay.ErrorCode = result.error.code
    print(errorCode)
end
pending:Cancel()
local enabledValue, enabledProblem = client.requests.Enabled:Request(2)
local enabled = assert(enabledValue, enabledProblem and enabledProblem.message)
local enabledResult = enabled:Await()
if enabledResult.ok then
    local value: boolean = enabledResult.value
    print(value)
end
local selectedValue, selectedProblem = client.requests.Selected:Request(1, 2)
local selected = assert(selectedValue, selectedProblem and selectedProblem.message)
local selectedResult = selected:Await()
if selectedResult.ok then
    local value: number? = selectedResult.value
    print(value)
end
local noRpcValue, noRpcProblem = Relay.define({ name = "NoRpc", version = 1,
    events = { Ping = Relay.schema.clientToServer(1, Relay.schema.ordered()) }, requests = {},
})
local noRpcDefinition = assert(noRpcValue, noRpcProblem and noRpcProblem.message)
print(noRpcDefinition, client, server)
