--!strict
local Relay = require("../../src/init")
local Combat = require("./schema-compose-combat")
local Inventory = require("./schema-compose-inventory")

local events, composeProblem = Relay.schema.compose(Combat, Inventory)
local merged = assert(events, composeProblem and composeProblem.message)
local definition, problem = Relay.define({ name = "ComposedTypes", version = 1, events = merged })
local token = assert(definition, problem and problem.message)
local server, serverProblem = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local serverSession = assert(server, serverProblem and serverProblem.message)
local client, clientProblem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local clientSession = assert(client, clientProblem and clientProblem.message)
local player: Player = error("type-only fixture")

clientSession.events.Attack:Send(7, { style = "Slash", sequence = { 1, 2 } })
serverSession.events.Attack:Connect(function(sender, amount, move)
    local _player: Player = sender
    local _amount: number = amount
    local _style: "Slash" | "Guard" = move.style
    local _sequence: { number } = move.sequence
end)
serverSession.events.State:Broadcast({ 1, 2 }, 3)
clientSession.events.State:Connect(function(items, selected)
    local _items: { number } = items
    local _selected: number? = selected
end)
serverSession.events.State:Send(player, {}, nil)


-- Literal keys exercise mapped session types at the combined endpoint limit.
local s = Relay.schema
local fields = s.ordered(s.field("enabled", s.boolean()))
local largeEvents = require("./endpoint-limit-events")
local largeComposed, largeComposeProblem = s.compose(largeEvents)
local largeMerged = assert(largeComposed, largeComposeProblem and largeComposeProblem.message)
local largeDefinition, largeProblem = Relay.define({
    name = "MaximumMixedTypes", version = 1,
    events = largeMerged,
    requests = { Query = s.request(64, s.ordered(s.field("id", s.u16())), s.boolean()) },
})
local largeToken = assert(largeDefinition, largeProblem and largeProblem.message)
local largeServerValue, largeServerProblem = Relay.createServer(largeToken, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local largeServer = assert(largeServerValue, largeServerProblem and largeServerProblem.message)
local largeClientValue, largeClientProblem = Relay.createClient(largeToken, { startupTimeoutSeconds = 3 })
local largeClient = assert(largeClientValue, largeClientProblem and largeClientProblem.message)
largeClient.events.E63:Send(true)
largeServer.events.E63:Connect(function(sender, enabled)
    local _player: Player = sender
    local _enabled: boolean = enabled
end)
largeServer.requests.Query:Connect(function(sender, id)
    local _player: Player = sender
    local _id: number = id
    return true
end)
local pending, requestProblem = largeClient.requests.Query:Request(3, 7)
local result = assert(pending, requestProblem and requestProblem.message):Await()
if result.ok then
    local _answer: boolean = result.value
end

local allEvents, allComposeProblem = s.compose(largeEvents, { E64 = s.serverToClient(64, fields) })
local allMerged = assert(allEvents, allComposeProblem and allComposeProblem.message)
local allDefinition, allProblem = Relay.define({
    name = "MaximumEventTypes", version = 1,
    events = allMerged,
})
local allClientValue, allClientProblem = Relay.createClient(assert(allDefinition, allProblem and allProblem.message),
    { startupTimeoutSeconds = 3 })
local allClient = assert(allClientValue, allClientProblem and allClientProblem.message)
allClient.events.E64:Connect(function(enabled)
    local _enabled: boolean = enabled
end)

return { client = largeClient, server = largeServer }
