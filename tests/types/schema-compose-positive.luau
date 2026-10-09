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
