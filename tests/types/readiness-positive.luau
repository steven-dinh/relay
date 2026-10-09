--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local readyDefinition, readyProblem = Relay.define({
    name = "ReadinessTypes", version = 1, readiness = true,
    events = {
        State = s.serverToClient(1, s.ordered(s.field("sequence", s.u32()))),
        Input = s.clientToServer(2, s.ordered(s.field("enabled", s.boolean()))),
    },
})
local readyToken = assert(readyDefinition, readyProblem and readyProblem.message)
local serverValue, serverProblem = Relay.createServer(readyToken, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverProblem and serverProblem.message)
local clientValue, clientProblem = Relay.createClient(readyToken, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientProblem and clientProblem.message)
local player: Player = error("type-only fixture")

local players: { Player }?, readyError: Relay.RelayError? = server.events.State:GetReadyPlayers()
local readyPlayers: { Player } = assert(players, readyError and readyError.message)
local sent: boolean, sendError: Relay.RelayError?, sentCount: number = server.events.State:SendTo(readyPlayers, 12)
local force: boolean = true
local refreshed: boolean, refreshError: Relay.RelayError? = client:RefreshReadiness()
local nilRefresh: boolean, nilRefreshError: Relay.RelayError? = client:RefreshReadiness(nil)
local falseRefresh: boolean, falseRefreshError: Relay.RelayError? = client:RefreshReadiness(false)
local trueRefresh: boolean, trueRefreshError: Relay.RelayError? = client:RefreshReadiness(force)
local c2sConnection: Relay.Connection?, c2sProblem: Relay.RelayError? = server.events.Input:Connect(function(sender, enabled)
    local actualPlayer: Player = sender
    local actualEnabled: boolean = enabled
    print(actualPlayer, actualEnabled)
end)

local disabledDefinition = assert((Relay.define({
    name = "ReadinessDisabledTypes", version = 1, readiness = false,
    events = { State = s.serverToClient(1, s.ordered()) },
})))
local disabledClient = assert((Relay.createClient(disabledDefinition, { startupTimeoutSeconds = 3 })))
local stillTyped: boolean, stillTypedError: Relay.RelayError? = disabledClient:RefreshReadiness(false)
print(player, sent, sendError, sentCount, refreshed, refreshError, nilRefresh, nilRefreshError,
    falseRefresh, falseRefreshError, trueRefresh, trueRefreshError, c2sConnection, c2sProblem, stillTyped, stillTypedError)
