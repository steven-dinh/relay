export type ErrorCode = "InvalidDefinition" | "InvalidOptions" | "WrongRuntimeSide"
    | "AlreadyStarted" | "NotStarted" | "Destroyed" | "AlreadyConnected"
    | "InvalidHandler" | "InvalidPayload" | "InvalidPlayer" | "StartupTimeout"
    | "RemoteOwnershipConflict" | "DefinitionMismatch" | "Disconnected" | "TransportFailure"

export type RelayError = { code: ErrorCode, message: string }
export type FieldSpec = {
    name: string,
    type: "boolean" | "u8" | "u16" | "u32" | "f32" | "Vector3F32",
    minimum: number?,
    maximum: number?,
}
export type EventSpec = {
    id: number,
    direction: "ClientToServer" | "ServerToClient",
    fields: { FieldSpec },
}
export type DefinitionSpec = { name: string, version: number, events: { [string]: EventSpec } }
export type Definition = {}
export type ServerOptions = {
    inboundRate: {
        perPlayer: { capacity: number, refillPerSecond: number },
        aggregate: { capacity: number, refillPerSecond: number },
    },
}
export type ClientOptions = { startupTimeoutSeconds: number }
export type Connection = { Disconnect: (self: Connection) -> () }
export type ServerReceiveEvent = {
    Connect: (self: ServerReceiveEvent, handler: (Player, ...any) -> ()) -> (Connection?, RelayError?),
}
export type ServerSendEvent = {
    Send: (self: ServerSendEvent, player: Player, ...any) -> (boolean, RelayError?),
    Broadcast: (self: ServerSendEvent, ...any) -> (boolean, RelayError?),
}
export type ClientReceiveEvent = {
    Connect: (self: ClientReceiveEvent, handler: (...any) -> ()) -> (Connection?, RelayError?),
}
export type ClientSendEvent = {
    Send: (self: ClientSendEvent, ...any) -> (boolean, RelayError?),
}
export type ServerSession = {
    events: { [string]: any },
    Start: (self: ServerSession) -> (boolean, RelayError?),
    Destroy: (self: ServerSession) -> (),
}
export type ClientSession = {
    events: { [string]: any },
    Start: (self: ClientSession) -> (boolean, RelayError?),
    Destroy: (self: ClientSession) -> (),
}

local DefinitionModule = require(if script then script.Definition else "./src/Definition")
local ServerSessionModule = require(if script then script.ServerSession else "./src/ServerSession")
local ClientSessionModule = require(if script then script.ClientSession else "./src/ClientSession")

return table.freeze({
    VERSION = "0.1.0",
    define = DefinitionModule.define,
    createServer = ServerSessionModule.create,
    createClient = ClientSessionModule.create,
})
