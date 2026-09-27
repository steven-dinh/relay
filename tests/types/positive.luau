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

if definition then
    local server, serverError = Relay.createServer(definition, {
        inboundRate = {
            perPlayer = { capacity = 10, refillPerSecond = 1 },
            aggregate = { capacity = 100, refillPerSecond = 10 },
        },
    })
    if server then
        server:Destroy()
    elseif serverError then
        print(serverError.code, serverError.message)
    end

    local client, clientError = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
    if client then
        client:Destroy()
    elseif clientError then
        print(clientError.code, clientError.message)
    end
elseif definitionError then
    print(definitionError.code, definitionError.message)
end

local function playerId(player: Player): number
    return player.UserId
end

local moduleName: string = script.Name
print(moduleName, playerId)
