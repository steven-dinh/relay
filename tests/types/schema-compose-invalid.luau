--!strict
local Relay = require("../../src/init")
local Combat = require("./schema-compose-combat")
local Inventory = require("./schema-compose-inventory")
local events, composeProblem = Relay.schema.compose(Combat, Inventory)
local merged = assert(events, composeProblem and composeProblem.message)
local tokenValue, tokenProblem = Relay.define({ name = "InvalidComposedTypes", version = 1, events = merged })
local token = assert(tokenValue, tokenProblem and tokenProblem.message)
local serverValue, serverProblem = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverProblem and serverProblem.message)
local clientValue, clientProblem = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientProblem and clientProblem.message)

client.events.Unknown:Send()
server.events.Attack:Send(7, { style = "Slash", sequence = { 1 } })
client.events.Attack:Send("bad", { style = "Slash", sequence = { 1 } })
client.events.Attack:Send(7, { style = "Other", sequence = { 1 } })
client.events.Attack:Send(7, { style = "Slash", sequence = { "bad" } })
client.events.Attack:Send(7, { style = "Slash", sequence = { 1 } }, true)
server.events.State:Broadcast({ true }, 3)

local duplicate = Relay.schema.compose(
    { Collision = Relay.schema.serverToClient(3, Relay.schema.ordered()) },
    { Collision = Relay.schema.clientToServer(4, Relay.schema.ordered()) }
)
local duplicateToken = Relay.define({
    name = "DuplicateComposedTypes", version = 1,
    events = assert(duplicate, "duplicate names must not compose"),
})

local broad: { [string]: typeof(Combat.Attack) } = {}
local broadEvents, broadProblem = Relay.schema.compose(broad)
local broadToken = Relay.define({
    name = "BroadComposedTypes", version = 1,
    events = assert(broadEvents, broadProblem and broadProblem.message),
})
print(duplicateToken, broadToken, client, server)
