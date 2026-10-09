export type ErrorCode = "InvalidDefinition" | "InvalidOptions" | "WrongRuntimeSide"
    | "AlreadyStarted" | "NotStarted" | "Destroyed" | "AlreadyConnected"
    | "InvalidHandler" | "InvalidPayload" | "InvalidPlayer" | "InvalidAudience" | "StartupTimeout"
    | "RemoteOwnershipConflict" | "DefinitionMismatch" | "Disconnected" | "TransportFailure"

export type RelayError = { code: ErrorCode, message: string }
-- Literal variants support the new-solver field mapping; ordered(...) carries field order.
type ShapeSpec<Name = {}> =
    | ({ type: "boolean" } & Name)
    | ({ type: "string", maximumBytes: number } & Name)
    | ({ type: "u8", minimum: number?, maximum: number? } & Name)
    | ({ type: "u16", minimum: number?, maximum: number? } & Name)
    | ({ type: "u32", minimum: number?, maximum: number? } & Name)
    | ({ type: "i8", minimum: number?, maximum: number? } & Name)
    | ({ type: "i16", minimum: number?, maximum: number? } & Name)
    | ({ type: "i32", minimum: number?, maximum: number? } & Name)
    | ({ type: "f32", minimum: number, maximum: number } & Name)
    | ({ type: "Vector3F32", minimum: number, maximum: number } & Name)
    | ({ type: "Vector2F32", minimum: number, maximum: number } & Name)
    | ({ type: "CFrame", minimum: number, maximum: number } & Name)
    | ({ type: "struct", fields: { StructFieldSpec } } & Name)
    | ({ type: "array", element: ShapeSpec, maximumLength: number } & Name)
    | ({ type: "enum", values: { string } } & Name)
    | ({ type: "optional", value: ShapeSpec } & Name)
    | ({ type: "set", element: ShapeSpec, maximumSize: number } & Name)
type StructFieldSpec = ShapeSpec<{ name: string }>
export type FieldSpec = ShapeSpec<{ name: string }>
export type EventSpec = {
    id: number,
    direction: "ClientToServer" | "ServerToClient",
    fields: { FieldSpec },
    delivery: ("Reliable" | "Unreliable")?,
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
type SchemaAPI = typeof(require(script.Schema))
local SchemaModule: SchemaAPI = require(if script then script.Schema else "./src/Schema")

-- field(...) adds its name as a table intersection; keep every component's constraints.
type function schemaTable(shape)
    if not shape or shape.tag ~= "intersection" then return shape end
    local result = types.newtable()
    for _, part in shape:components() do
        if not part:is("table") then return shape end
        for name, property in part:properties() do
            if property.read then
                local value = property.read
                local previous = result:readproperty(name)
                if previous then
                    if previous:issubtypeof(value) then value = previous
                    elseif not value:issubtypeof(previous) then value = types.intersectionof(previous, value) end
                end
                result:setproperty(name, value)
            end
        end
    end
    return result
end

type function checkedSchema(schema)
    if not schema:is("table") then error("definition must be a table") end
    local name = schema:readproperty(types.singleton("name"))
    local version = schema:readproperty(types.singleton("version"))
    local events = schema:readproperty(types.singleton("events"))
    if not name or not name:issubtypeof(types.string) then error("definition name must be string") end
    if not version or not version:issubtypeof(types.number) then error("definition version must be number") end
    if not events or not events:is("table") then error("definition events must be a table") end

    local function orderedParameters(value, context, label)
        if not value or value.tag ~= "intersection" then error(`{context}: {label} must be ordered`) end
        local ordered = nil
        for _, part in value:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
        if not ordered or ordered.tag ~= "function" then error(`{context}: {label} lack ordered metadata`) end
        return ordered:parameters().head or {}
    end

    local function checkShape(shape, context, nameMode, depth)
        shape = schemaTable(shape)
        if not shape or not shape:is("table") then error(`{context}: field must be a table`) end
        local fieldName = shape:readproperty(types.singleton("name"))
        if nameMode == "event" then
            if not fieldName or fieldName.tag == "never" or fieldName.tag == "intersection"
                or not fieldName:issubtypeof(types.string) then
                error(`{context}: field name must be string`)
            end
        elseif nameMode == "struct" then
            if not fieldName or fieldName.tag ~= "singleton" or type(fieldName:value()) ~= "string" then
                error(`{context}: struct field name must be a string literal`)
            end
        elseif fieldName then
            error(`{context}: child shape must not have a name`)
        end

        local fieldKind = shape:readproperty(types.singleton("type"))
        if not fieldKind or fieldKind.tag ~= "singleton" then
            error(`{context}: field type must be a singleton`)
        end
        local kind = fieldKind:value()
        local composite = kind == "struct" or kind == "array" or kind == "optional" or kind == "set"
        if composite then
            if depth >= 4 then error(`{context}: schema exceeds maximum composite depth of 4`) end
            depth += 1
        end
        local integerKind = kind == "u8" or kind == "u16" or kind == "u32"
            or kind == "i8" or kind == "i16" or kind == "i32"
        local minimum = shape:readproperty(types.singleton("minimum"))
        local maximum = shape:readproperty(types.singleton("maximum"))
        local maximumBytes = shape:readproperty(types.singleton("maximumBytes"))
        local boundType = if integerKind then types.optional(types.number) else types.number
        if minimum and not minimum:issubtypeof(boundType) then
            error(`{context}: field minimum must be number`)
        end
        if maximum and not maximum:issubtypeof(boundType) then
            error(`{context}: field maximum must be number`)
        end
        if kind == "string" then
            if not maximumBytes or not maximumBytes:issubtypeof(types.number) then
                error(`{context}: string maximumBytes must be number`)
            end
        elseif kind == "f32" or kind == "Vector2F32" or kind == "Vector3F32" or kind == "CFrame" then
            if not minimum and not maximum then
                error(`{context}: bounded field needs minimum and maximum`)
            elseif not minimum then
                error(`{context}: bounded field is missing minimum`)
            elseif not maximum then
                error(`{context}: bounded field is missing maximum`)
            end
        elseif kind == "struct" then
            local fields = shape:readproperty(types.singleton("fields"))
            local fieldTypes = orderedParameters(fields, context, "struct fields")
            if #fieldTypes > 8 then error(`{context}: struct has more than 8 fields`) end
            local names = {}
            for index, field in ipairs(fieldTypes) do
                field = schemaTable(field)
                local childContext = `{context}, struct field {index}`
                if not field:is("table") then error(`{childContext}: field must be a table`) end
                local childName = field:readproperty(types.singleton("name"))
                if not childName or childName.tag ~= "singleton" or type(childName:value()) ~= "string" then
                    error(`{childContext}: struct field name must be a string literal`)
                end
                local literalName = childName:value()
                if names[literalName] then error(`{childContext}: duplicate struct field name '{literalName}'`) end
                names[literalName] = true
                checkShape(field, childContext, "struct", depth)
            end
        elseif kind == "array" or kind == "set" then
            local limitName = if kind == "array" then "maximumLength" else "maximumSize"
            local limit = shape:readproperty(types.singleton(limitName))
            if not limit or not limit:issubtypeof(types.number) then
                error(`{context}: {kind} {limitName} must be number`)
            end
            local element = schemaTable(shape:readproperty(types.singleton("element")))
            if not element or not element:is("table") then
                error(`{context}: {kind} element must be a shape table`)
            end
            local elementKind = element:readproperty(types.singleton("type"))
            if not elementKind or elementKind.tag ~= "singleton" then
                error(`{context}: {kind} element type must be a singleton`)
            end
            local childKind = elementKind:value()
            if kind == "array" and childKind == "optional" then
                error(`{context}: array element cannot be optional`)
            elseif kind == "set" then
                local integerElement = childKind == "u8" or childKind == "u16" or childKind == "u32"
                    or childKind == "i8" or childKind == "i16" or childKind == "i32"
                if not integerElement and childKind ~= "boolean" and childKind ~= "string" and childKind ~= "enum" then
                    error(`{context}: set element must be boolean, string, integer, or enum`)
                end
            end
            checkShape(element, `{context}, {kind} element`, "anonymous", depth)
        elseif kind == "enum" then
            local values = shape:readproperty(types.singleton("values"))
            local literals = orderedParameters(values, context, "enum values")
            if #literals < 1 or #literals > 32 then error(`{context}: enum must have 1 to 32 values`) end
            local seen = {}
            for index, value in ipairs(literals) do
                local valueContext = `{context}, enum value {index}`
                if value.tag ~= "singleton" or type(value:value()) ~= "string" then
                    error(`{valueContext}: enum value must be a string literal`)
                end
                local literal = value:value()
                if #literal < 1 or #literal > 32 then error(`{valueContext}: enum value must be 1 to 32 bytes`) end
                if seen[literal] then error(`{valueContext}: duplicate enum value '{literal}'`) end
                seen[literal] = true
            end
        elseif kind == "optional" then
            local value = schemaTable(shape:readproperty(types.singleton("value")))
            if not value or not value:is("table") then
                error(`{context}: optional value must be a shape table`)
            end
            local childKind = value:readproperty(types.singleton("type"))
            if childKind and childKind.tag == "singleton" and childKind:value() == "optional" then
                error(`{context}: nested optional shapes are not supported`)
            end
            checkShape(value, `{context}, optional value`, "anonymous", depth)
        elseif kind ~= "boolean" and kind ~= "string" and not integerKind then
            error(`{context}: unsupported field type '{kind}'`)
        end
    end

    for eventName, property in events:properties() do
        local event = property.read
        local eventContext = if eventName.tag == "singleton"
            then `event '{eventName:value()}'`
            else "event with non-literal name"
        if not event or not event:is("table") then error(`{eventContext} must be a table`) end
        local id = event:readproperty(types.singleton("id"))
        local direction = event:readproperty(types.singleton("direction"))
        local fields = event:readproperty(types.singleton("fields"))
        local delivery = event:readproperty(types.singleton("delivery"))
        if not id or not id:issubtypeof(types.number) then error(`{eventContext}: event id must be number`) end
        local deliveries = types.optional(types.unionof(types.singleton("Reliable"), types.singleton("Unreliable")))
        if delivery and not delivery:issubtypeof(deliveries) then
            error(`{eventContext}: invalid event delivery; expected 'Reliable' or 'Unreliable'`)
        end
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
            checkShape(field, fieldContext, "event", 0)
        end
    end
    return schema
end

type function shapeType(shape, vector2, vector3, cframe, depth)
    shape = schemaTable(shape)
    if not shape or not shape:is("table") then error("shape must be a table") end
    local kindType = shape:readproperty(types.singleton("type"))
    if not kindType or kindType.tag ~= "singleton" then error("shape type must be a singleton") end
    local kind = kindType:value()
    local composite = kind == "struct" or kind == "array" or kind == "optional" or kind == "set"
    if composite then
        if depth >= 4 then error("shape exceeds maximum composite depth of 4") end
        depth += 1
    end
    local integerKind = kind == "u8" or kind == "u16" or kind == "u32"
        or kind == "i8" or kind == "i16" or kind == "i32"
    if kind == "boolean" then
        return types.boolean
    elseif kind == "string" then
        return types.string
    elseif integerKind or kind == "f32" then
        return types.number
    elseif kind == "Vector2F32" then
        return vector2
    elseif kind == "Vector3F32" then
        return vector3
    elseif kind == "CFrame" then
        return cframe
    elseif kind == "enum" then
        local values = shape:readproperty(types.singleton("values"))
        if not values or values.tag ~= "intersection" then error("enum values must be ordered") end
        local ordered = nil
        for _, part in values:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
        if not ordered or ordered.tag ~= "function" then error("enum values lack ordered metadata") end
        local result = nil
        for _, value in ordered:parameters().head or {} do
            if value.tag ~= "singleton" or type(value:value()) ~= "string" then
                error("enum values must be string literals")
            end
            local literal = types.singleton(value:value())
            result = if result then types.unionof(result, literal) else literal
        end
        if not result then error("enum values must not be empty") end
        return result
    elseif kind == "struct" then
        local fields = shape:readproperty(types.singleton("fields"))
        if not fields or fields.tag ~= "intersection" then error("struct fields must be ordered") end
        local ordered = nil
        for _, part in fields:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
        if not ordered or ordered.tag ~= "function" then error("struct fields lack ordered metadata") end
        local result = types.newtable()
        for _, field in ordered:parameters().head or {} do
            field = schemaTable(field)
            if field.tag ~= "table" then error("struct field must be a table") end
            local name = field:readproperty(types.singleton("name"))
            if not name or name.tag ~= "singleton" or type(name:value()) ~= "string" then
                error("struct field name must be a string literal")
            end
            local valueType = shapeType(field, vector2, vector3, cframe, depth)
            result:setproperty(name, valueType)
        end
        return result
    elseif kind == "array" or kind == "set" then
        local element = schemaTable(shape:readproperty(types.singleton("element")))
        if not element or not element:is("table") then error(`{kind} element must be a shape table`) end
        local elementKind = element:readproperty(types.singleton("type"))
        if not elementKind or elementKind.tag ~= "singleton" then error(`{kind} element type must be a singleton`) end
        local elementName = elementKind:value()
        if elementName == "optional" and kind == "array" then
            error("array element cannot be optional")
        elseif elementName == "optional" then
            error("set element cannot be optional")
        end
        if kind == "set" then
            local integerElement = elementName == "u8" or elementName == "u16" or elementName == "u32"
                or elementName == "i8" or elementName == "i16" or elementName == "i32"
            if not integerElement and elementName ~= "boolean" and elementName ~= "string" and elementName ~= "enum" then
                error("set element must be boolean, string, integer, or enum")
            end
        end
        local elementType = shapeType(element, vector2, vector3, cframe, depth)
        local result = types.newtable()
        if kind == "array" then
            result:setindexer(types.number, elementType)
        elseif elementName == "enum" then
            local presentValue = types.optional(types.singleton(true))
            if elementType.tag == "singleton" then
                result:setproperty(elementType, presentValue)
            else
                for _, literal in elementType:components() do
                    result:setproperty(literal, presentValue)
                end
            end
        else
            result:setindexer(elementType, types.singleton(true))
        end
        return result
    elseif kind == "optional" then
        local value = schemaTable(shape:readproperty(types.singleton("value")))
        if not value or not value:is("table") then error("optional value must be a shape table") end
        local valueKind = value:readproperty(types.singleton("type"))
        if valueKind and valueKind.tag == "singleton" and valueKind:value() == "optional" then
            error("nested optional shapes are not supported")
        end
        return types.optional(shapeType(value, vector2, vector3, cframe, depth))
    end
    error(`unsupported shape type '{kind}'`)
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
            table.insert(payload, shapeType(field, vector2, vector3, cframe, 0))
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
    schema = SchemaModule,
})
