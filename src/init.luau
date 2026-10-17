export type ErrorCode = "InvalidDefinition" | "InvalidOptions" | "WrongRuntimeSide"
    | "AlreadyStarted" | "NotStarted" | "Destroyed" | "AlreadyConnected"
    | "InvalidHandler" | "InvalidPayload" | "InvalidPlayer" | "InvalidAudience" | "StartupTimeout"
    | "RemoteOwnershipConflict" | "DefinitionMismatch" | "Disconnected" | "TransportFailure"
    | "RequestLimit" | "RequestIdExhausted" | "RequestTimeout" | "Cancelled"
    | "AlreadyAwaiting" | "NotYieldable" | "HandlerFailure" | "InvalidResponse"
    | "ReadinessDisabled" | "ReadinessExhausted" | "QueueLimit" | "QueueFull" | "QueueClosed" | "QueueBusy"
    | "InvalidStateKey" | "InvalidPriority"

export type RelayError = { code: ErrorCode, message: string }
type NativePayloadTypes = {
    UDim: UDim,
    UDim2: UDim2,
    NumberRange: NumberRange,
    Rect: Rect,
    BrickColor: BrickColor,
    Vector2int16: Vector2int16,
    Vector3int16: Vector3int16,
    NumberSequence: NumberSequence,
    ColorSequence: ColorSequence,
    NumberSequenceKeypoint: NumberSequenceKeypoint,
    ColorSequenceKeypoint: ColorSequenceKeypoint,
    TweenInfo: TweenInfo,
    DateTime: DateTime,
    Ray: Ray,
    Axes: Axes,
    Faces: Faces,
    Region3: Region3,
    Region3int16: Region3int16,
    PhysicalProperties: PhysicalProperties,
    Font: Font,
    PathWaypoint: PathWaypoint,
    robloxEnum: EnumItem,
    Instance: {
        Instance: Instance,
        BasePart: BasePart,
        Part: Part,
        MeshPart: MeshPart,
        Model: Model,
        Humanoid: Humanoid,
        Tool: Tool,
        Attachment: Attachment,
        Player: Player,
        Folder: Folder,
        GuiObject: GuiObject,
        Sound: Sound,
        Animation: Animation,
        Animator: Animator,
    },
}

-- Literal variants support the new-solver field mapping; ordered(...) carries field order.
type ShapeSpec<Name = {}> =
    ({ type: "robloxEnum", values: { EnumItem } } & Name)
    | ({ type: "Instance", className: string } & Name)
    | ({ type: "UDim", minimumScale: number, maximumScale: number, minimumOffset: number, maximumOffset: number } & Name)
    | ({ type: "UDim2", minimumScale: number, maximumScale: number, minimumOffset: number, maximumOffset: number } & Name)
    | ({ type: "NumberRange", minimum: number, maximum: number } & Name)
    | ({ type: "Rect", minimum: number, maximum: number } & Name)
    | ({ type: "Region3", minimum: number, maximum: number } & Name)
    | ({ type: "DateTime", minimum: number, maximum: number } & Name)
    | ({ type: "Vector2int16", minimum: number?, maximum: number? } & Name)
    | ({ type: "Vector3int16", minimum: number?, maximum: number? } & Name)
    | ({ type: "Region3int16", minimum: number?, maximum: number? } & Name)
    | ({ type: "BrickColor", values: { BrickColor } } & Name)
    | ({ type: "NumberSequence", maximumKeypoints: number, minimum: number, maximum: number, maximumEnvelope: number } & Name)
    | ({ type: "ColorSequence", maximumKeypoints: number } & Name)
    | ({ type: "NumberSequenceKeypoint", minimum: number, maximum: number, maximumEnvelope: number } & Name)
    | ({ type: "ColorSequenceKeypoint" } & Name)
    | ({ type: "Axes" } & Name)
    | ({ type: "Faces" } & Name)
    | ({ type: "PhysicalProperties" } & Name)
    | ({ type: "TweenInfo", maximumTime: number, maximumDelayTime: number, maximumRepeatCount: number, allowInfiniteRepeat: boolean? } & Name)
    | ({ type: "Ray", minimum: number, maximum: number, maximumDirectionMagnitude: number } & Name)
    | ({ type: "Font", families: { string } } & Name)
    | ({ type: "PathWaypoint", minimum: number, maximum: number, maximumLabelBytes: number } & Name)
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
    | ({ type: "Color3" } & Name)
    | ({ type: "quantized", minimum: number, maximum: number, step: number } & Name)
    | ({ type: "struct", fields: { StructFieldSpec } } & Name)
    | ({ type: "taggedUnion", tag: string, variants: { [string]: TaggedUnionVariantSpec } } & Name)
    | ({ type: "array", element: ShapeSpec, maximumLength: number } & Name)
    | ({ type: "enum", values: { string } } & Name)
    | ({ type: "optional", value: ShapeSpec } & Name)
    | ({ type: "set", element: ShapeSpec, maximumSize: number } & Name)
    | ({ type: "map", key: ShapeSpec, value: ShapeSpec, maximumSize: number } & Name)
type StructFieldSpec = ShapeSpec<{ name: string }>
type TaggedUnionVariantSpec = { type: "struct", fields: { StructFieldSpec } }
export type FieldSpec = ShapeSpec<{ name: string }>
export type EventSpec = {
    id: number,
    direction: "ClientToServer" | "ServerToClient",
    fields: { FieldSpec },
    delivery: ("Reliable" | "Unreliable" | "OrderedUnreliable")?,
    queue: ("Batch" | "State")?,
}
export type RequestSpec = { id: number, request: { FieldSpec }, response: ShapeSpec }
export type DefinitionSpec = {
    name: string, version: number, events: { [string]: EventSpec }, requests: { [string]: RequestSpec }?,
    readiness: boolean?,
}
export type Definition<S> = { [never]: S }
export type EndpointRate = { capacity: number, refillPerSecond: number }
export type InboundByteRate = { perPlayer: EndpointRate, aggregate: EndpointRate }
export type InboundRate = {
    perPlayer: { capacity: number, refillPerSecond: number },
    aggregate: { capacity: number, refillPerSecond: number },
    endpoints: { [number]: EndpointRate }?,
    bytes: InboundByteRate?,
}
export type ServerOptions = { inboundRate: InboundRate, instanceRoot: Instance? }
export type ClientOptions = { startupTimeoutSeconds: number }
export type Connection = { Disconnect: (self: Connection) -> () }
export type RequestResult<T> = { ok: true, value: T } | { ok: false, error: RelayError }
export type PendingRequest<T> = {
    Await: (self: PendingRequest<T>) -> RequestResult<T>,
    Cancel: (self: PendingRequest<T>) -> (),
}
export type QueueReport = {
    reliableHandoffs: number, unreliableHandoffs: number, logicalHandoffs: number,
    selected: number, remaining: number, expired: number,
}
export type StateStatus = {
    state: "Open" | "Flushing" | "Destroyed",
    activeKeys: number, pendingKeys: number, pendingBodyBytes: number,
    lastFlush: { ok: boolean, error: RelayError?, report: QueueReport }?,
}
export type BatchHandle<E> = {
    events: E,
    Flush: (self: { events: E }) -> (boolean, RelayError?, QueueReport),
    Cancel: (self: { events: E }) -> (),
}
export type StateHandle<E> = {
    events: E,
    Flush: (self: { events: E }) -> (boolean, RelayError?, QueueReport),
    GetStatus: (self: { events: E }) -> StateStatus,
    Destroy: (self: { events: E }) -> (),
}
export type EventCounters = {
    noListener: number, busy: number, invalidPayload: number, stale: number, dispatched: number,
    endpointRate: number, handlerErrors: number, sendHandoffs: number, broadcastHandoffs: number,
    transportFailures: number,
}
export type DiagnosticCounters = EventCounters & {
    received: number, ineligible: number, perPlayerRate: number, aggregateRate: number,
    perPlayerBytes: number, aggregateBytes: number,
    invalidEndpoint: number, wrongChannel: number, transportLosses: number,
}
type SessionState = "Created" | "Starting" | "Started" | "Disconnected" | "Destroyed"
export type ServerDiagnostics = {
    side: "Server", state: SessionState, counterLimit: number, inFlight: number,
    inboundRate: InboundRate,
    handlerLimits: { perPlayerEndpoint: number, perPlayer: number, global: number },
    counters: DiagnosticCounters, events: { [string]: EventCounters },
}
export type ClientDiagnostics = {
    side: "Client", state: SessionState, counterLimit: number, inFlight: number,
    inboundRate: nil, handlerLimits: { perEndpoint: number },
    counters: DiagnosticCounters, events: { [string]: EventCounters },
}
export type EventBudget = {
    id: number, direction: "ClientToServer" | "ServerToClient",
    delivery: "Reliable" | "Unreliable" | "OrderedUnreliable",
    fieldCount: number, maximumDepth: number, maximumExpandedNodes: number,
    bytes: {
        representation: "RelayBuffer", minimum: number, maximum: number, limit: number,
        robloxEncodedBytes: "Unknown",
    } | {
        representation: "NativeTuple", maximumStringContentBytes: number,
        robloxEncodedBytes: "Unknown", unreliableSizeStatus: "Unknown"?,
    },
    queuedBytes: {
        bodyMinimum: number, bodyMaximum: number, singleRecordMinimum: number,
        singleRecordMaximum: number, limit: number, robloxEncodedBytes: "Unknown",
    }?,
    references: { maximumCount: number, perReferenceAdmissionBytes: number, maximumAdmissionBytes: number }?,
}
export type RequestBudget = {
    id: number,
    request: {
        fieldCount: number, maximumDepth: number, maximumExpandedNodes: number,
        bytes: { representation: "RelayBuffer", minimum: number, maximum: number, limit: number, robloxEncodedBytes: "Unknown" },
    },
    response: {
        maximumDepth: number, maximumExpandedNodes: number,
        bytes: { representation: "RelayBuffer", minimum: number, maximum: number, limit: number, robloxEncodedBytes: "Unknown" },
    },
}
export type DefinitionInspection = {
    name: string, version: number,
    protocol: "RR1" | "RR2" | "RR3" | "RR5" | "RR6" | "RR7" | "RR8" | "RR9" | "RR10", descriptorBytes: number,
    readiness: boolean,
    limits: {
        events: number, tupleFields: number, descriptorBytes: number, compositeDepth: number,
        expandedNodesPerEvent: number, authoredNodesPerEvent: number, arraySetCapacity: number,
        mapCapacity: number, nativeAllowlistValues: number, sequenceKeypoints: number, fontFamilyBytes: number,
        stringContentBytesPerField: number, reliableRelayBufferBytes: number, unreliableRelayBufferBytes: number,
        endpoints: number, rpcEnvelopeBytes: number, rpcBodyBytes: number, rpcBufferBytes: number,
        queuedLogicalRecords: number, instanceReferences: number, instanceReferenceAdmissionBytes: number,
        quantizedLevels: number,
    },
    events: { [string]: EventBudget },
    requests: { [string]: RequestBudget },
}
-- Lifecycle self types use this base; withMaps replaces both broad maps on the public result.
type ServerSessionBase = {
    read events: unknown,
    read requests: unknown,
    Start: (self: ServerSessionBase) -> (boolean, RelayError?),
    Destroy: (self: ServerSessionBase) -> (),
    GetDiagnostics: (self: ServerSessionBase) -> ServerDiagnostics,
}
type ClientSessionBase = {
    read events: unknown,
    read requests: unknown,
    Start: (self: ClientSessionBase) -> (boolean, RelayError?),
    Destroy: (self: ClientSessionBase) -> (),
    GetDiagnostics: (self: ClientSessionBase) -> ClientDiagnostics,
    RefreshReadiness: (self: ClientSessionBase, forceChallenge: boolean?) -> (boolean, RelayError?),
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

-- This closed map mirrors runtime native metadata; numeric values remain runtime-checked.
type function nativeShapeType(shape, nativeTypes)
    local kindType = shape:readproperty(types.singleton("type"))
    local kind = kindType:value()
    local allowed = {}
    local optional = {}
    local listKey = nil
    if kind == "robloxEnum" or kind == "BrickColor" then
        listKey = "values"
    elseif kind == "Instance" then
        -- className is checked against the closed native class map below.
    elseif kind == "Font" then
        listKey = "families"
    elseif kind == "UDim" or kind == "UDim2" then
        allowed = { "minimumScale", "maximumScale", "minimumOffset", "maximumOffset" }
    elseif kind == "Vector2int16" or kind == "Vector3int16" or kind == "Region3int16" then
        optional = { "minimum", "maximum" }
    elseif kind == "NumberRange" or kind == "Rect" or kind == "Region3" or kind == "DateTime" then
        allowed = { "minimum", "maximum" }
    elseif kind == "NumberSequence" then
        allowed = { "maximumKeypoints", "minimum", "maximum", "maximumEnvelope" }
    elseif kind == "ColorSequence" then
        allowed = { "maximumKeypoints" }
    elseif kind == "NumberSequenceKeypoint" then
        allowed = { "minimum", "maximum", "maximumEnvelope" }
    elseif kind == "TweenInfo" then
        allowed = { "maximumTime", "maximumDelayTime", "maximumRepeatCount" }
    elseif kind == "Ray" then
        allowed = { "minimum", "maximum", "maximumDirectionMagnitude" }
    elseif kind == "PathWaypoint" then
        allowed = { "minimum", "maximum", "maximumLabelBytes" }
    end
    local keys = { type = true, name = true }
    if kind == "Instance" then keys.className = true end
    for _, name in allowed do
        keys[name] = true
        local value = shape:readproperty(types.singleton(name))
        if not value or not value:issubtypeof(types.number) then error(`{kind} {name} must be number`) end
    end
    for _, name in optional do
        keys[name] = true
        local value = shape:readproperty(types.singleton(name))
        if value and not value:issubtypeof(types.optional(types.number)) then error(`{kind} {name} must be number`) end
    end
    if kind == "TweenInfo" then
        keys.allowInfiniteRepeat = true
        local value = shape:readproperty(types.singleton("allowInfiniteRepeat"))
        if value and not value:issubtypeof(types.optional(types.boolean)) then
            error("TweenInfo allowInfiniteRepeat must be boolean")
        end
    end
    local result = nativeTypes:readproperty(kindType)
    if kind == "Instance" then
        local className = shape:readproperty(types.singleton("className"))
        if not className or className.tag ~= "singleton" or type(className:value()) ~= "string" then
            error("Instance className must be a supported class literal")
        end
        local classes = nativeTypes:readproperty(kindType)
        local classType = classes and classes:readproperty(types.singleton(className:value()))
        if not classType then error(`unsupported Instance class '{className:value()}'`) end
        result = classType
    end
    if listKey then
        keys[listKey] = true
        local values = shape:readproperty(types.singleton(listKey))
        local ordered = nil
        if values and values.tag == "intersection" then
            for _, part in values:components() do
                if part.tag == "table" then
                    local indexer = part:readindexer()
                    if indexer and indexer.index.tag == "never" then ordered = indexer.result end
                end
            end
        end
        if not ordered or ordered.tag ~= "function" then error(`{kind} {listKey} must be ordered`) end
        local items = ordered:parameters().head or {}
        if #items < 1 or #items > 32 then error(`{kind} {listKey} must have 1 to 32 entries`) end
        local base = if kind == "Font" then types.string else nativeTypes:readproperty(kindType)
        for _, item in items do
            if not item:issubtypeof(base) then error(`{kind} {listKey} has an incompatible value`) end
            if kind == "robloxEnum" then
                if base:issubtypeof(item) then error("robloxEnum requires a precise enum family") end
                if result == base then result = item
                elseif not item:issubtypeof(result) or not result:issubtypeof(item) then
                    error("robloxEnum values must use one enum family")
                end
            end
        end
    end
    if shape:readindexer() then error(`{kind} shape keys must be literal strings`) end
    for key in shape:properties() do
        if key.tag ~= "singleton" or type(key:value()) ~= "string" or not keys[key:value()] then
            error(`unknown {kind} shape key`)
        end
    end
    return result
end

type function checkedSchema(schema, nativeTypes)
    if not schema:is("table") then error("definition must be a table") end
    local name = schema:readproperty(types.singleton("name"))
    local version = schema:readproperty(types.singleton("version"))
    local events = schema:readproperty(types.singleton("events"))
    if not name or not name:issubtypeof(types.string) then error("definition name must be string") end
    if not version or not version:issubtypeof(types.number) then error("definition version must be number") end
    if not events or not events:is("table") then error("definition events must be a table") end
    local readiness = schema:readproperty(types.singleton("readiness"))
    if readiness and not readiness:issubtypeof(types.optional(types.boolean)) then
        error("definition readiness must be boolean")
    end

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
        if nativeTypes:readproperty(fieldKind) then
            if (kind == "NumberSequence" or kind == "ColorSequence") and depth >= 4 then
                error(`{context}: schema exceeds maximum composite depth of 4`)
            end
            nativeShapeType(shape, nativeTypes)
            return kind == "Instance"
        end
        local containsReferences = false
        local composite = kind == "struct" or kind == "array" or kind == "optional" or kind == "set"
            or kind == "map"
            or kind == "taggedUnion"
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
        elseif kind == "Color3" then
            if minimum or maximum then error(`{context}: Color3 does not accept minimum or maximum`) end
            for key in shape:properties() do
                if key.tag ~= "singleton" or type(key:value()) ~= "string" then
                    error(`{context}: Color3 shape keys must be literal strings`)
                end
                local keyName = key:value()
                if keyName ~= "type" and not ((nameMode == "event" or nameMode == "struct") and keyName == "name") then
                    error(`{context}: unknown Color3 shape key '{keyName}'`)
                end
            end
        elseif kind == "quantized" then
            for _, boundName in { "minimum", "maximum", "step" } do
                local bound = shape:readproperty(types.singleton(boundName))
                if not bound then error(`{context}: quantized {boundName} is required`) end
                if not bound:issubtypeof(types.number) then error(`{context}: quantized {boundName} must be number`) end
            end
            for key in shape:properties() do
                if key.tag ~= "singleton" or type(key:value()) ~= "string" then
                    error(`{context}: quantized shape keys must be literal strings`)
                end
                local keyName = key:value()
                if keyName ~= "type" and keyName ~= "minimum" and keyName ~= "maximum" and keyName ~= "step"
                    and not ((nameMode == "event" or nameMode == "struct") and keyName == "name") then
                    error(`{context}: unknown quantized shape key '{keyName}'`)
                end
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
                if checkShape(field, childContext, "struct", depth) then containsReferences = true end
            end
        elseif kind == "taggedUnion" then
            for key in shape:properties() do
                if key.tag ~= "singleton" or type(key:value()) ~= "string" then
                    error(`{context}: tagged union shape keys must be literal strings`)
                end
                local keyName = key:value()
                if keyName ~= "type" and keyName ~= "tag" and keyName ~= "variants"
                    and not ((nameMode == "event" or nameMode == "struct") and keyName == "name") then
                    error(`{context}: unknown tagged union shape key '{keyName}'`)
                end
            end

            local tag = shape:readproperty(types.singleton("tag"))
            if not tag or tag.tag ~= "singleton" or type(tag:value()) ~= "string"
                or #tag:value() < 1 or #tag:value() > 32
                or string.match(tag:value(), "^[A-Za-z][A-Za-z0-9_]*$") == nil then
                error(`{context}: tagged union tag must be a valid string literal`)
            end

            local variants = shape:readproperty(types.singleton("variants"))
            if not variants or not variants:is("table") or variants:readindexer() then
                error(`{context}: tagged union variants must use literal keys`)
            end
            local variantCount = 0
            for variantName, property in variants:properties() do
                if variantName.tag ~= "singleton" or type(variantName:value()) ~= "string"
                    or #variantName:value() < 1 or #variantName:value() > 32
                    or string.match(variantName:value(), "^[A-Za-z][A-Za-z0-9_]*$") == nil then
                    error(`{context}: tagged union variant names must be valid string literals`)
                end
                variantCount += 1
                if variantCount > 32 then error(`{context}: tagged union allows at most 32 variants`) end
                local variant = property.read
                if not variant or not variant:is("table") then
                    error(`{context}, variant '{variantName:value()}': variant must be an anonymous struct shape`)
                end
                local variantType = variant:readproperty(types.singleton("type"))
                if not variantType or variantType.tag ~= "singleton" or variantType:value() ~= "struct" then
                    error(`{context}, variant '{variantName:value()}': variant must be an anonymous struct shape`)
                end
                local fieldTypes = orderedParameters(variant:readproperty(types.singleton("fields")),
                    context, "tagged union variant fields")
                if #fieldTypes > 7 then error(`{context}: tagged union variants allow at most 7 fields`) end
                if checkShape(variant, `{context}, variant '{variantName:value()}'`, "anonymous", depth) then
                    containsReferences = true
                end
                for index, field in ipairs(fieldTypes) do
                    field = schemaTable(field)
                    local branchFieldName = field:readproperty(types.singleton("name"))
                    if branchFieldName and branchFieldName.tag == "singleton"
                        and branchFieldName:value() == tag:value() then
                        error(`{context}, variant field {index}: field name conflicts with discriminator`)
                    end
                end
            end
            if variantCount == 0 then error(`{context}: tagged union needs at least one variant`) end
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
                if not integerElement and childKind ~= "boolean" and childKind ~= "string" and childKind ~= "enum" and childKind ~= "robloxEnum" then
                    error(`{context}: set element must be boolean, string, integer, or enum`)
                end
            end
            if checkShape(element, `{context}, {kind} element`, "anonymous", depth) then containsReferences = true end
        elseif kind == "map" then
            for key in shape:properties() do
                if key.tag ~= "singleton" or type(key:value()) ~= "string" then
                    error(`{context}: map shape keys must be literal strings`)
                end
                local keyName = key:value()
                if keyName ~= "type" and keyName ~= "key" and keyName ~= "value" and keyName ~= "maximumSize"
                    and not ((nameMode == "event" or nameMode == "struct") and keyName == "name") then
                    error(`{context}: unknown map shape key '{keyName}'`)
                end
            end

            local maximumSize = shape:readproperty(types.singleton("maximumSize"))
            if not maximumSize or not maximumSize:issubtypeof(types.number) then
                error(`{context}: map maximumSize must be number`)
            end

            local key = schemaTable(shape:readproperty(types.singleton("key")))
            if not key or not key:is("table") then error(`{context}: map key must be a shape table`) end
            local keyKind = key:readproperty(types.singleton("type"))
            if not keyKind or keyKind.tag ~= "singleton" then error(`{context}: map key type must be a singleton`) end
            local keyName = keyKind:value()
            local integerKey = keyName == "u8" or keyName == "u16" or keyName == "u32"
                or keyName == "i8" or keyName == "i16" or keyName == "i32"
            if keyName ~= "string" and keyName ~= "robloxEnum" and not integerKey then
                error(`{context}: map key must be string or integer`)
            end
            checkShape(key, `{context}, map key`, "anonymous", depth)

            local value = schemaTable(shape:readproperty(types.singleton("value")))
            if not value or not value:is("table") then error(`{context}: map value must be a shape table`) end
            local valueKind = value:readproperty(types.singleton("type"))
            if valueKind and valueKind.tag == "singleton" and valueKind:value() == "optional" then
                error(`{context}: map value cannot be optional`)
            end
            if checkShape(value, `{context}, map value`, "anonymous", depth) then containsReferences = true end
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
            if checkShape(value, `{context}, optional value`, "anonymous", depth) then containsReferences = true end
        elseif kind ~= "boolean" and kind ~= "string" and not integerKind and kind ~= "Color3" then
            error(`{context}: unsupported field type '{kind}'`)
        end
        return containsReferences
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
        local queue = event:readproperty(types.singleton("queue"))
        if not id or not id:issubtypeof(types.number) then error(`{eventContext}: event id must be number`) end
        local deliveries = types.optional(types.unionof(types.singleton("Reliable"),
            types.singleton("Unreliable"), types.singleton("OrderedUnreliable")))
        if delivery and not delivery:issubtypeof(deliveries) then
            error(`{eventContext}: invalid event delivery; expected 'Reliable', 'Unreliable', or 'OrderedUnreliable'`)
        end
        local queues = types.optional(types.unionof(types.singleton("Batch"), types.singleton("State")))
        if queue and not queue:issubtypeof(queues) then
            error(`{eventContext}: invalid queue capability; expected 'Batch' or 'State'`)
        end
        if delivery and delivery.tag == "singleton" and delivery:value() == "OrderedUnreliable"
            and queue and queue.tag == "singleton"
            and (queue:value() == "Batch" or queue:value() == "State") then
            error(`{eventContext}: OrderedUnreliable events cannot be queued`)
        end
        local directions = types.unionof(types.singleton("ClientToServer"), types.singleton("ServerToClient"))
        if not direction or not direction:issubtypeof(directions) then
            error(`{eventContext}: invalid event direction; expected 'ClientToServer' or 'ServerToClient'`)
        end
        local fieldTypes = orderedParameters(fields, eventContext, "fields")
        local hasReferences = false
        for fieldIndex, field in fieldTypes do
            local fieldContext = `{eventContext}, field {fieldIndex}`
            if checkShape(field, fieldContext, "event", 0) then hasReferences = true end
        end
        if hasReferences then
            if queue then error(`{eventContext}: Instance references require reliable immediate delivery`) end
            if delivery and not delivery:issubtypeof(types.optional(types.singleton("Reliable"))) then
                error(`{eventContext}: Instance references require reliable immediate delivery`)
            end
        end
    end
    local requests = schema:readproperty(types.singleton("requests"))
    if requests then
        if requests.tag ~= "table" then error("definition requests must be a table") end
        if requests:readindexer() then error("requests require literal keys") end
        for requestName, property in requests:properties() do
            local method = property.read
            local context = if requestName.tag == "singleton"
                then `request '{requestName:value()}'` else "request with non-literal name"
            if not method or method.tag ~= "table" then error(`{context} must be a table`) end
            local id = method:readproperty(types.singleton("id"))
            if not id or not id:issubtypeof(types.number) then error(`{context}: request id must be number`) end
            local fields = orderedParameters(method:readproperty(types.singleton("request")), context, "request fields")
            if #fields > 8 then error(`{context}: request has more than 8 fields`) end
            local hasReferences = false
            for index, field in fields do
                if checkShape(field, `{context}, field {index}`, "event", 0) then hasReferences = true end
            end
            if checkShape(method:readproperty(types.singleton("response")), `{context}, response`, "anonymous", 0) then
                hasReferences = true
            end
            if hasReferences then error(`{context}: Instance references are only supported in reliable immediate events`) end
        end
    end
    return schema
end

type function shapeType(shape, vector2, vector3, cframe, color3, nativeTypes, depth)
    shape = schemaTable(shape)
    if not shape or not shape:is("table") then error("shape must be a table") end
    local kindType = shape:readproperty(types.singleton("type"))
    if not kindType or kindType.tag ~= "singleton" then error("shape type must be a singleton") end
    local kind = kindType:value()
    if nativeTypes:readproperty(kindType) then
        if (kind == "NumberSequence" or kind == "ColorSequence") and depth >= 4 then
            error("shape exceeds maximum composite depth of 4")
        end
        return nativeShapeType(shape, nativeTypes)
    end
    local composite = kind == "struct" or kind == "array" or kind == "optional" or kind == "set"
        or kind == "map"
        or kind == "taggedUnion"
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
    elseif integerKind or kind == "f32" or kind == "quantized" then
        return types.number
    elseif kind == "Vector2F32" then
        return vector2
    elseif kind == "Vector3F32" then
        return vector3
    elseif kind == "CFrame" then
        return cframe
    elseif kind == "Color3" then
        return color3
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
            local valueType = shapeType(field, vector2, vector3, cframe, color3, nativeTypes, depth)
            result:setproperty(name, valueType)
        end
        return result
    elseif kind == "taggedUnion" then
        local tag = shape:readproperty(types.singleton("tag"))
        local variants = shape:readproperty(types.singleton("variants"))
        if not tag or tag.tag ~= "singleton" or type(tag:value()) ~= "string"
            or not variants or not variants:is("table") then
            error("tagged union requires a literal tag and variant table")
        end
        local result = nil
        for label, property in variants:properties() do
            if label.tag ~= "singleton" or type(label:value()) ~= "string" or not property.read then
                error("tagged union variants require literal readable entries")
            end
            local branch = shapeType(property.read, vector2, vector3, cframe, color3, nativeTypes, depth)
            if branch.tag ~= "table" then error("tagged union variant must produce a table") end
            branch:setproperty(types.singleton(tag:value()), types.singleton(label:value()))
            result = if result then types.unionof(result, branch) else branch
        end
        if not result then error("tagged union needs at least one variant") end
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
            if not integerElement and elementName ~= "boolean" and elementName ~= "string" and elementName ~= "enum" and elementName ~= "robloxEnum" then
                error("set element must be boolean, string, integer, or enum")
            end
        end
        local elementType = shapeType(element, vector2, vector3, cframe, color3, nativeTypes, depth)
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
    elseif kind == "map" then
        local key = schemaTable(shape:readproperty(types.singleton("key")))
        local value = schemaTable(shape:readproperty(types.singleton("value")))
        if not key or not key:is("table") then error("map key must be a shape table") end
        if not value or not value:is("table") then error("map value must be a shape table") end
        local keyKind = key:readproperty(types.singleton("type"))
        if not keyKind or keyKind.tag ~= "singleton" then error("map key type must be a singleton") end
        local keyName = keyKind:value()
        local integerKey = keyName == "u8" or keyName == "u16" or keyName == "u32"
            or keyName == "i8" or keyName == "i16" or keyName == "i32"
        if keyName ~= "string" and keyName ~= "robloxEnum" and not integerKey then error("map key must be string or integer") end
        local valueKind = value:readproperty(types.singleton("type"))
        if valueKind and valueKind.tag == "singleton" and valueKind:value() == "optional" then
            error("map value cannot be optional")
        end
        local result = types.newtable()
        result:setindexer(shapeType(key, vector2, vector3, cframe, color3, nativeTypes, depth),
            shapeType(value, vector2, vector3, cframe, color3, nativeTypes, depth))
        return result
    elseif kind == "optional" then
        local value = schemaTable(shape:readproperty(types.singleton("value")))
        if not value or not value:is("table") then error("optional value must be a shape table") end
        local valueKind = value:readproperty(types.singleton("type"))
        if valueKind and valueKind.tag == "singleton" and valueKind:value() == "optional" then
            error("nested optional shapes are not supported")
        end
        return types.optional(shapeType(value, vector2, vector3, cframe, color3, nativeTypes, depth))
    end
    error(`unsupported shape type '{kind}'`)
end

type function eventMap(schema, serverSide, player, relayError, connection, vector2, vector3, cframe, color3, nativeTypes)
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
            table.insert(payload, shapeType(field, vector2, vector3, cframe, color3, nativeTypes, 0))
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
            handle:setproperty(types.singleton("Once"), connect)
        else
            local sendArgs = { handle }
            if server then table.insert(sendArgs, player) end
            for _, payloadType in payload do table.insert(sendArgs, payloadType) end
            handle:setproperty(types.singleton("Send"), types.newfunction({ head = sendArgs }, { head = { types.boolean, types.optional(relayError) } }))
            if server then
                local broadcastArgs = { handle }
                for _, payloadType in payload do table.insert(broadcastArgs, payloadType) end
                handle:setproperty(types.singleton("Broadcast"), types.newfunction({ head = broadcastArgs }, { head = { types.boolean, types.optional(relayError) } }))
                local audience = types.newtable()
                audience:setindexer(types.number, player)
                local audienceArgs = { handle, audience }
                for _, payloadType in payload do table.insert(audienceArgs, payloadType) end
                local audienceSend = types.newfunction({ head = audienceArgs }, { head = { types.boolean, types.optional(relayError), types.number } })
                handle:setproperty(types.singleton("SendTo"), audienceSend)
                handle:setproperty(types.singleton("SendExcept"), audienceSend)
                handle:setproperty(types.singleton("GetReadyPlayers"), types.newfunction(
                    { head = { handle } }, { head = { types.optional(audience), types.optional(relayError) } }
                ))
            end
        end
        result:setproperty(name, handle)
    end
    return result
end

type function requestMap(schema, serverSide, player, relayError, connection, vector2, vector3, cframe, color3, nativeTypes)
    local result = types.newtable()
    local requests = schema:readproperty(types.singleton("requests"))
    if not requests then return result end
    for name, property in requests:properties() do
        local method = property.read
        if not method then error("request not readable") end
        local fields = method:readproperty(types.singleton("request"))
        local ordered
        if fields and fields.tag == "intersection" then
            for _, part in fields:components() do
                if part.tag == "table" then
                    local indexer = part:readindexer()
                    if indexer and indexer.index.tag == "never" then ordered = indexer.result end
                end
            end
        end
        if not ordered or ordered.tag ~= "function" then error("request fields lack ordered metadata") end
        local payload = {}
        for _, field in ordered:parameters().head or {} do
            table.insert(payload, shapeType(field, vector2, vector3, cframe, color3, nativeTypes, 0))
        end
        local response = shapeType(method:readproperty(types.singleton("response")), vector2, vector3, cframe, color3, nativeTypes, 0)
        local handle = types.newtable()
        if serverSide:value() then
            local args = { player }
            for _, value in payload do table.insert(args, value) end
            local handler = types.newfunction({ head = args }, { head = { response } })
            handle:setproperty(types.singleton("Connect"), types.newfunction(
                { head = { handle, handler } }, { head = { types.optional(connection), types.optional(relayError) } }
            ))
        else
            local success = types.newtable()
            success:setproperty(types.singleton("ok"), types.singleton(true))
            success:setproperty(types.singleton("value"), response)
            local failed = types.newtable()
            failed:setproperty(types.singleton("ok"), types.singleton(false))
            failed:setproperty(types.singleton("error"), relayError)
            local pending = types.newtable()
            pending:setproperty(types.singleton("Await"), types.newfunction(
                { head = { pending } }, { head = { types.unionof(success, failed) } }
            ))
            pending:setproperty(types.singleton("Cancel"), types.newfunction({ head = { pending } }, { head = {} }))
            local args = { handle, types.number }
            for _, value in payload do table.insert(args, value) end
            handle:setproperty(types.singleton("Request"), types.newfunction(
                { head = args }, { head = { types.optional(pending), types.optional(relayError) } }
            ))
        end
        result:setproperty(name, handle)
    end
    return result
end

type function queueSessionMethods(schema, serverSide, sessionBase, player, relayError, vector2, vector3, cframe, color3, nativeTypes)
    local events = schema:readproperty(types.singleton("events"))
    if not events then error("schema lacks events") end
    local batchEvents = types.newtable()
    local stateEvents = types.newtable()
    local server = serverSide:value()
    local priorities = types.unionof(types.singleton("High"), types.singleton("Normal"), types.singleton("Low"))

    for name, property in events:properties() do
        local event = property.read
        if not event then error("event not readable") end
        local direction = event:readproperty(types.singleton("direction"))
        local queue = event:readproperty(types.singleton("queue"))
        if direction and direction.tag == "singleton" and queue and queue.tag == "singleton" then
            local sendingDirection = if server then "ServerToClient" else "ClientToServer"
            local sending = direction:value() == sendingDirection
            local queueMode = queue:value()
            if sending and (queueMode == "Batch" or queueMode == "State") then
                local fields = event:readproperty(types.singleton("fields"))
                local ordered
                if fields and fields.tag == "intersection" then
                    for _, part in fields:components() do
                        if part.tag == "table" then
                            local indexer = part:readindexer()
                            if indexer and indexer.index.tag == "never" then ordered = indexer.result end
                        end
                    end
                end
                if not ordered or ordered.tag ~= "function" then error("fields lack ordered metadata") end
                local payload = {}
                for _, field in ordered:parameters().head or {} do
                    table.insert(payload, shapeType(field, vector2, vector3, cframe, color3, nativeTypes, 0))
                end

                local batchEvent = types.newtable()
                local sendArgs = { batchEvent }
                for _, value in payload do table.insert(sendArgs, value) end
                batchEvent:setproperty(types.singleton("Send"), types.newfunction(
                    { head = sendArgs }, { head = { types.boolean, types.optional(relayError) } }
                ))
                batchEvents:setproperty(name, batchEvent)

                if queueMode == "State" then
                    local stateEvent = types.newtable()
                    local putArgs = { stateEvent, types.number, priorities }
                    for _, value in payload do table.insert(putArgs, value) end
                    stateEvent:setproperty(types.singleton("Put"), types.newfunction(
                        { head = putArgs }, { head = { types.boolean, types.optional(relayError) } }
                    ))
                    stateEvent:setproperty(types.singleton("Remove"), types.newfunction(
                        { head = { stateEvent, types.number } },
                        { head = { types.boolean, types.optional(relayError) } }
                    ))
                    stateEvents:setproperty(name, stateEvent)
                end
            end
        end
    end

    local report = types.newtable()
    for _, name in { "reliableHandoffs", "unreliableHandoffs", "logicalHandoffs", "selected", "remaining", "expired" } do
        report:setproperty(types.singleton(name), types.number)
    end
    local flushResult = types.newtable()
    flushResult:setproperty(types.singleton("ok"), types.boolean)
    flushResult:setproperty(types.singleton("error"), types.optional(relayError))
    flushResult:setproperty(types.singleton("report"), report)

    local batchSelf = types.newtable()
    batchSelf:setproperty(types.singleton("events"), batchEvents)
    local batch = types.newtable()
    batch:setproperty(types.singleton("events"), batchEvents)
    batch:setproperty(types.singleton("Flush"), types.newfunction(
        { head = { batchSelf } }, { head = { types.boolean, types.optional(relayError), report } }
    ))
    batch:setproperty(types.singleton("Cancel"), types.newfunction({ head = { batchSelf } }, { head = {} }))

    local stateStatus = types.newtable()
    stateStatus:setproperty(types.singleton("state"), types.unionof(
        types.singleton("Open"), types.singleton("Flushing"), types.singleton("Destroyed")
    ))
    stateStatus:setproperty(types.singleton("activeKeys"), types.number)
    stateStatus:setproperty(types.singleton("pendingKeys"), types.number)
    stateStatus:setproperty(types.singleton("pendingBodyBytes"), types.number)
    stateStatus:setproperty(types.singleton("lastFlush"), types.optional(flushResult))

    local stateSelf = types.newtable()
    stateSelf:setproperty(types.singleton("events"), stateEvents)
    local state = types.newtable()
    state:setproperty(types.singleton("events"), stateEvents)
    state:setproperty(types.singleton("Flush"), types.newfunction(
        { head = { stateSelf } }, { head = { types.boolean, types.optional(relayError), report } }
    ))
    state:setproperty(types.singleton("GetStatus"), types.newfunction(
        { head = { stateSelf } }, { head = { stateStatus } }
    ))
    state:setproperty(types.singleton("Destroy"), types.newfunction({ head = { stateSelf } }, { head = {} }))

    local result = types.newtable()
    if server then
        local audience = types.newtable()
        audience:setindexer(types.number, player)
        result:setproperty(types.singleton("CreateBatch"), types.newfunction(
            { head = { sessionBase, audience, types.number } },
            { head = { types.optional(batch), types.optional(relayError) } }
        ))
        result:setproperty(types.singleton("CreateState"), types.newfunction(
            { head = { sessionBase, audience, types.number } },
            { head = { types.optional(state), types.optional(relayError) } }
        ))
    else
        result:setproperty(types.singleton("CreateBatch"), types.newfunction(
            { head = { sessionBase, types.number } },
            { head = { types.optional(batch), types.optional(relayError) } }
        ))
        result:setproperty(types.singleton("CreateState"), types.newfunction(
            { head = { sessionBase, types.number } },
            { head = { types.optional(state), types.optional(relayError) } }
        ))
    end
    return result
end

type function withMaps(base, events, requests, queueMethods)
    local result = types.copy(base)
    result:setproperty(types.singleton("events"), events)
    result:setproperty(types.singleton("requests"), requests)
    for name, property in queueMethods:properties() do
        if property.read then result:setproperty(name, property.read) end
    end
    return result
end

export type ServerSession<S> = withMaps<ServerSessionBase,
    eventMap<S, true, Player, RelayError, Connection, Vector2, Vector3, CFrame, Color3, NativePayloadTypes>,
    requestMap<S, true, Player, RelayError, Connection, Vector2, Vector3, CFrame, Color3, NativePayloadTypes>,
    queueSessionMethods<S, true, ServerSessionBase, Player, RelayError, Vector2, Vector3, CFrame, Color3, NativePayloadTypes>>
export type ClientSession<S> = withMaps<ClientSessionBase,
    eventMap<S, false, Player, RelayError, Connection, Vector2, Vector3, CFrame, Color3, NativePayloadTypes>,
    requestMap<S, false, Player, RelayError, Connection, Vector2, Vector3, CFrame, Color3, NativePayloadTypes>,
    queueSessionMethods<S, false, ClientSessionBase, Player, RelayError, Vector2, Vector3, CFrame, Color3, NativePayloadTypes>>

type DefineSignature = <S>(S) -> (Definition<checkedSchema<S, NativePayloadTypes>>?, RelayError?)
type InspectSignature = <S>(Definition<S>) -> (DefinitionInspection?, RelayError?)
type CreateServerSignature = <S>(Definition<S>, ServerOptions) -> (ServerSession<S>?, RelayError?)
type CreateClientSignature = <S>(Definition<S>, ClientOptions) -> (ClientSession<S>?, RelayError?)

local define: DefineSignature = (DefinitionModule.define :: unknown) :: DefineSignature
local inspect: InspectSignature = (DefinitionModule.inspect :: unknown) :: InspectSignature
local createServer: CreateServerSignature = (ServerSessionModule.create :: unknown) :: CreateServerSignature
local createClient: CreateClientSignature = (ClientSessionModule.create :: unknown) :: CreateClientSignature

return table.freeze({
    VERSION = "0.3.0",
    define = define,
    createServer = createServer,
    createClient = createClient,
    schema = SchemaModule,
    inspect = inspect,
})
