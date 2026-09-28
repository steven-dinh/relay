export type ErrorCode = "InvalidDefinition" | "InvalidOptions" | "WrongRuntimeSide"
    | "AlreadyStarted" | "NotStarted" | "Destroyed" | "AlreadyConnected"
    | "InvalidHandler" | "InvalidPayload" | "InvalidPlayer" | "StartupTimeout"
    | "RemoteOwnershipConflict" | "DefinitionMismatch" | "Disconnected" | "TransportFailure"

export type RelayError = { code: ErrorCode, message: string }
-- Literal variants support the new-solver field mapping; ordered(...) carries field order.
export type FieldSpec =
    | { name: string, type: "boolean" }
    | { name: string, type: "string", maximumBytes: number }
    | { name: string, type: "u8", minimum: number?, maximum: number? }
    | { name: string, type: "u16", minimum: number?, maximum: number? }
    | { name: string, type: "u32", minimum: number?, maximum: number? }
    | { name: string, type: "i8", minimum: number?, maximum: number? }
    | { name: string, type: "i16", minimum: number?, maximum: number? }
    | { name: string, type: "i32", minimum: number?, maximum: number? }
    | { name: string, type: "f32", minimum: number, maximum: number }
    | { name: string, type: "Vector3F32", minimum: number, maximum: number }
    | { name: string, type: "Vector2F32", minimum: number, maximum: number }
    | { name: string, type: "CFrame", minimum: number, maximum: number }
export type EventSpec = {
    id: number,
    direction: "ClientToServer" | "ServerToClient",
    fields: { FieldSpec },
}
export type DefinitionSpec = { name: string, version: number, events: { [string]: EventSpec } }
export type Definition<S> = { [never]: S }
export type ServerOptions = {
    inboundRate: {
        perPlayer: { capacity: number, refillPerSecond: number },
        aggregate: { capacity: number, refillPerSecond: number },
    },
}
export type ClientOptions = { startupTimeoutSeconds: number }
export type Connection = { Disconnect: (self: Connection) -> () }
-- Lifecycle self types use this base; withEvents replaces its broad map on the public result.
type ServerSessionBase = {
    events: { [string]: any },
    Start: (self: ServerSessionBase) -> (boolean, RelayError?),
    Destroy: (self: ServerSessionBase) -> (),
}
type ClientSessionBase = {
    events: { [string]: any },
    Start: (self: ClientSessionBase) -> (boolean, RelayError?),
    Destroy: (self: ClientSessionBase) -> (),
}

local DefinitionModule = require(if script then script.Definition else "./src/Definition")
local ServerSessionModule = require(if script then script.ServerSession else "./src/ServerSession")
local ClientSessionModule = require(if script then script.ClientSession else "./src/ClientSession")

type function checkedSchema(schema)
    if not schema:is("table") then error("definition must be a table") end
    local name = schema:readproperty(types.singleton("name"))
    local version = schema:readproperty(types.singleton("version"))
    local events = schema:readproperty(types.singleton("events"))
    if not name or not name:issubtypeof(types.string) then error("definition name must be string") end
    if not version or not version:issubtypeof(types.number) then error("definition version must be number") end
    if not events or not events:is("table") then error("definition events must be a table") end
    for eventName, property in events:properties() do
        local event = property.read
        local eventContext = if eventName.tag == "singleton"
            then `event '{eventName:value()}'`
            else "event with non-literal name"
        if not event or not event:is("table") then error(`{eventContext} must be a table`) end
        local id = event:readproperty(types.singleton("id"))
        local direction = event:readproperty(types.singleton("direction"))
        local fields = event:readproperty(types.singleton("fields"))
        if not id or not id:issubtypeof(types.number) then error(`{eventContext}: event id must be number`) end
        local directions = types.unionof(types.singleton("ClientToServer"), types.singleton("ServerToClient"))
        if not direction or not direction:issubtypeof(directions) then
            error(`{eventContext}: invalid event direction; expected 'ClientToServer' or 'ServerToClient'`)
        end
        if not fields or fields.tag ~= "intersection" then error(`{eventContext}: fields must be ordered`) end
        local ordered = nil
        for _, part in fields:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
        if not ordered or ordered.tag ~= "function" then error(`{eventContext}: fields lack ordered metadata`) end
        for fieldIndex, field in ordered:parameters().head or {} do
            local fieldContext = `{eventContext}, field {fieldIndex}`
            if field.tag ~= "table" then error(`{fieldContext}: field must be a table`) end
            local fieldName = field:readproperty(types.singleton("name"))
            local fieldKind = field:readproperty(types.singleton("type"))
            if not fieldName or not fieldName:issubtypeof(types.string) then
                error(`{fieldContext}: field name must be string`)
            end
            if not fieldKind or fieldKind.tag ~= "singleton" then
                error(`{fieldContext}: field type must be a singleton`)
            end
            local kind = fieldKind:value()
            local integerKind = kind == "u8" or kind == "u16" or kind == "u32"
                or kind == "i8" or kind == "i16" or kind == "i32"
            local minimum = field:readproperty(types.singleton("minimum"))
            local maximum = field:readproperty(types.singleton("maximum"))
            local maximumBytes = field:readproperty(types.singleton("maximumBytes"))
            local boundType = if integerKind then types.optional(types.number) else types.number
            if minimum and not minimum:issubtypeof(boundType) then
                error(`{fieldContext}: field minimum must be number`)
            end
            if maximum and not maximum:issubtypeof(boundType) then
                error(`{fieldContext}: field maximum must be number`)
            end
            if kind == "string" then
                if not maximumBytes or not maximumBytes:issubtypeof(types.number) then
                    error(`{fieldContext}: string maximumBytes must be number`)
                end
            elseif kind == "f32" or kind == "Vector2F32" or kind == "Vector3F32" or kind == "CFrame" then
                if not minimum and not maximum then
                    error(`{fieldContext}: bounded field needs minimum and maximum`)
                elseif not minimum then
                    error(`{fieldContext}: bounded field is missing minimum`)
                elseif not maximum then
                    error(`{fieldContext}: bounded field is missing maximum`)
                end
            elseif kind ~= "boolean" and not integerKind then
                error(`{fieldContext}: unsupported field type '{kind}'`)
            end
        end
    end
    return schema
end

type function eventMap(schema, serverSide, player, relayError, connection, vector2, vector3, cframe)
    local events = schema:readproperty(types.singleton("events"))
    if not events then error("schema lacks events") end
    local result = types.newtable()
    local server = serverSide:value()
    for name, property in events:properties() do
        local event = property.read
        if not event then error("event not readable") end
        local direction = event:readproperty(types.singleton("direction"))
        if not direction or direction.tag ~= "singleton" then error("direction must be a singleton") end
        local fields = event:readproperty(types.singleton("fields"))
        if not fields then error("event lacks fields") end
        local ordered = nil
        if fields.tag == "intersection" then
            for _, part in fields:components() do
                if part.tag == "table" then
                    local indexer = part:readindexer()
                    if indexer and indexer.index.tag == "never" then ordered = indexer.result end
                end
            end
        end
        if not ordered or ordered.tag ~= "function" then error("fields lack ordered metadata") end
        local fieldPack: { type } = ordered:parameters().head or {}
        local payload = {}
        for _, field in ipairs(fieldPack) do
            local fieldType = field:readproperty(types.singleton("type"))
            if not fieldType or fieldType.tag ~= "singleton" then error("field type must be a singleton") end
            local kind = fieldType:value()
            if kind == "boolean" then
                table.insert(payload, types.boolean)
            elseif kind == "string" then
                table.insert(payload, types.string)
            elseif kind == "Vector2F32" then
                table.insert(payload, vector2)
            elseif kind == "Vector3F32" then
                table.insert(payload, vector3)
            elseif kind == "CFrame" then
                table.insert(payload, cframe)
            else
                table.insert(payload, types.number)
            end
        end
        local handle = types.newtable()
        local c2s = direction:value() == "ClientToServer"
        if c2s == server then
            local handlerArgs = {}
            if server then table.insert(handlerArgs, player) end
            for _, payloadType in payload do table.insert(handlerArgs, payloadType) end
            local handler = types.newfunction({ head = handlerArgs }, { head = {} })
            local connect = types.newfunction({ head = { handle, handler } }, { head = { types.optional(connection), types.optional(relayError) } })
            handle:setproperty(types.singleton("Connect"), connect)
        else
            local sendArgs = { handle }
            if server then table.insert(sendArgs, player) end
            for _, payloadType in payload do table.insert(sendArgs, payloadType) end
            handle:setproperty(types.singleton("Send"), types.newfunction({ head = sendArgs }, { head = { types.boolean, types.optional(relayError) } }))
            if server then
                local broadcastArgs = { handle }
                for _, payloadType in payload do table.insert(broadcastArgs, payloadType) end
                handle:setproperty(types.singleton("Broadcast"), types.newfunction({ head = broadcastArgs }, { head = { types.boolean, types.optional(relayError) } }))
            end
        end
        result:setproperty(name, handle)
    end
    return result
end

type function withEvents(base, events)
    local result = types.copy(base)
    result:setproperty(types.singleton("events"), events)
    return result
end

export type ServerSession<S> = withEvents<ServerSessionBase, eventMap<S, true, Player, RelayError, Connection, Vector2, Vector3, CFrame>>
export type ClientSession<S> = withEvents<ClientSessionBase, eventMap<S, false, Player, RelayError, Connection, Vector2, Vector3, CFrame>>

type DefineSignature = <S>(S) -> (Definition<checkedSchema<S>>?, RelayError?)
type CreateServerSignature = <S>(Definition<S>, ServerOptions) -> (ServerSession<S>?, RelayError?)
type CreateClientSignature = <S>(Definition<S>, ClientOptions) -> (ClientSession<S>?, RelayError?)

local define: DefineSignature = (DefinitionModule.define :: unknown) :: DefineSignature
local createServer: CreateServerSignature = (ServerSessionModule.create :: unknown) :: CreateServerSignature
local createClient: CreateClientSignature = (ClientSessionModule.create :: unknown) :: CreateClientSignature

return table.freeze({
    VERSION = "0.1.0",
    define = define,
    createServer = createServer,
    createClient = createClient,
})
