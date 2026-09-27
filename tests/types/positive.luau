--!strict
local Relay = require("../../src/init")

local definition, definitionError = Relay.define({
    name = "TypeConsumer",
    version = 1,
    events = {
        Input = {
            id = 1,
            direction = "ClientToServer",
            fields = {
                { name = "count", type = "u8" },
                { name = "delta", type = "i16", minimum = -10 },
                { name = "limited", type = "u16", maximum = 100 },
                { name = "label", type = "string", maximumBytes = 32 },
                { name = "ratio", type = "f32", minimum = 0, maximum = 1 },
                { name = "point2", type = "Vector2F32", minimum = -1, maximum = 1 },
                { name = "point3", type = "Vector3F32", minimum = -1, maximum = 1 },
                { name = "pose", type = "CFrame", minimum = -10, maximum = 10 },
            },
        },
        Empty = { id = 2, direction = "ServerToClient", fields = {} },
    },
})

if definitionError then
    print(definitionError.code, definitionError.message)
end
assert(definition, definitionError and definitionError.message)

local server, serverError = Relay.createServer(definition, {
    inboundRate = {
        perPlayer = { capacity = 10, refillPerSecond = 1 },
        aggregate = { capacity = 100, refillPerSecond = 10 },
    },
})
assert(server, serverError and serverError.message)
local serverStarted, serverStartError = server:Start()
assert(serverStarted, serverStartError and serverStartError.message)
server:Destroy()

local client, clientError = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
assert(client, clientError and clientError.message)
local clientStarted, clientStartError = client:Start()
assert(clientStarted, clientStartError and clientStartError.message)
client:Destroy()

local function playerId(player: Player): number
    return player.UserId
end

local moduleName: string = script.Name
print(moduleName, playerId)
