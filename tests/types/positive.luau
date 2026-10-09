--!strict
local Relay = require("../../src/init")
local definition = require("./ordered-schema")
local ordered = require("../../examples/reliable-events/ordered")

local server, serverError = Relay.createServer(definition, {
    inboundRate = {
        perPlayer = { capacity = 10, refillPerSecond = 1 },
        aggregate = { capacity = 100, refillPerSecond = 10 },
    },
})
assert(server, serverError and serverError.message)

local client, clientError = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
assert(client, clientError and clientError.message)
local player: Player = error("type-only fixture")

local inputConnection, inputError = server.events.Input:Connect(function(sender, sequence, pressed, label, delta, ratio, point2, point3, pose)
    local userId: number = sender.UserId
    local numberValue: number = sequence + delta + ratio
    local pressedValue: boolean = pressed
    local labelValue: string = label
    local vector2Value: Vector2 = point2
    local vector3Value: Vector3 = point3
    local poseValue: CFrame = pose
    print(userId, numberValue, pressedValue, labelValue, vector2Value, vector3Value, poseValue)
end)
assert(inputConnection, inputError and inputError.message)
local stateConnection, stateError = client.events.State:Connect(function(a, b, c, d)
    local total: number = a + b + c + d
    print(total)
end)
assert(stateConnection, stateError and stateError.message)
local prefixConnection, prefixError = client.events.State:Connect(function(first)
    local value: number = first
    print(value)
end)
assert(prefixConnection, prefixError and prefixError.message)
local emptyConnection, emptyError = client.events.Empty:Connect(function() end)
assert(emptyConnection, emptyError and emptyError.message)

local sent, sendError = client.events.Input:Send(1, true, "a", -1, 0.5, Vector2.new(), Vector3.new(), CFrame.new())
assert(sent, sendError and sendError.message)
local stateSent, stateSendError = server.events.State:Send(player, 1, 2, -3, -4)
assert(stateSent, stateSendError and stateSendError.message)
local broadcast, broadcastError = server.events.State:Broadcast(1, 2, -3, -4)
assert(broadcast, broadcastError and broadcastError.message)
local emptyBroadcast, emptyBroadcastError = server.events.Empty:Broadcast()
assert(emptyBroadcast, emptyBroadcastError and emptyBroadcastError.message)
local function optionalNumber(value: number?): number?
    return value
end
local optionalBoundsDefinition, optionalBoundsError = Relay.define({
    name = "OptionalIntegerBounds",
    version = 1,
    events = {
        Bounds = {
            id = 1,
            direction = "ClientToServer" :: "ClientToServer",
            fields = ordered(
                { name = "unsigned", type = "u16" :: "u16", minimum = optionalNumber(nil), maximum = optionalNumber(100) },
                { name = "signed", type = "i16" :: "i16", minimum = optionalNumber(-10), maximum = optionalNumber(nil) }
            ),
        },
    },
})
assert(optionalBoundsDefinition, optionalBoundsError and optionalBoundsError.message)
local boundsClient, boundsClientError = Relay.createClient(optionalBoundsDefinition, { startupTimeoutSeconds = 10 })
assert(boundsClient, boundsClientError and boundsClientError.message)
local boundsSent, boundsSendError = boundsClient.events.Bounds:Send(1, -1)
assert(boundsSent, boundsSendError and boundsSendError.message)
boundsClient:Destroy()
local started, startError = server:Start()
assert(started, startError and startError.message)
local clientStarted, clientStartError = client:Start()
assert(clientStarted, clientStartError and clientStartError.message)
if inputConnection then inputConnection:Disconnect() end
if stateConnection then stateConnection:Disconnect() end
if prefixConnection then prefixConnection:Disconnect() end
if emptyConnection then emptyConnection:Disconnect() end
client:Destroy()
server:Destroy()

local audienceSent: boolean, audienceError: Relay.RelayError?, sentCount: number = server.events.State:SendTo({ player, player }, 1, 2, -3, -4)
local excludedSent: boolean, excludedError: Relay.RelayError?, excludedCount: number = server.events.State:SendExcept({}, 1, 2, -3, -4)
local emptySent: boolean, emptyAudienceError: Relay.RelayError?, emptyCount: number = server.events.Empty:SendTo({})
local errorCode: Relay.ErrorCode = "InvalidAudience"
local count: number = sentCount + excludedCount + emptyCount
