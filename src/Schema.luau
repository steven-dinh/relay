--!strict

-- Carry field/value order in the type without adding runtime metadata.
export type Ordered<T...> = { [number]: unknown } & { [never]: (T...) -> () }
type Delivery = "Reliable" | "Unreliable" | "OrderedUnreliable"
type ComposeError = { read code: "InvalidDefinition", read message: string }

type function mergedEvents(pack)
    local ordered
    if pack.tag == "intersection" then
        for _, part in pack:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
    end
    if not ordered or ordered.tag ~= "function" then error("composition requires ordered fragments") end
    local parameters = ordered:parameters()
    if parameters.tail then error("composition requires a fixed fragment pack") end
    local fragments: { type } = parameters.head or {}
    if #fragments < 1 or #fragments > 64 then error("composition requires 1 to 64 fragments") end

    local result = types.newtable()
    local count = 0
    for _, fragment in fragments do
        if fragment.tag ~= "table" or fragment:readindexer() then
            error("event fragments require literal event keys")
        end
        for name, property in fragment:properties() do
            if name.tag ~= "singleton" or type(name:value()) ~= "string" then
                error("event names must be literal keys")
            end
            if result:readproperty(name) then error("duplicate event name") end
            if not property.read then error("event must be readable") end
            count += 1
            if count > 64 then error("composition allows at most 64 events") end
            result:setproperty(name, property.read)
        end
    end
    if count == 0 then error("composition requires at least one event") end
    return result
end

local function composeFailure(message: string): (nil, ComposeError)
    return nil, table.freeze({ code = "InvalidDefinition" :: "InvalidDefinition", message = message })
end

local function runtimeCompose(...: unknown): ({ [string]: unknown }?, ComposeError?)
    local fragmentCount = select("#", ...)
    if fragmentCount < 1 or fragmentCount > 64 then
        return composeFailure("composition requires 1 to 64 fragments")
    end

    local fragments = { ... }
    local events: { [string]: unknown } = {}
    local ids: { [number]: boolean } = {}
    local count = 0
    for fragmentIndex = 1, fragmentCount do
        local fragment = fragments[fragmentIndex]
        if type(fragment) ~= "table" or getmetatable(fragment) ~= nil then
            return composeFailure("event fragment must be a plain table")
        end

        local rawFragment = fragment :: { [string]: unknown }
        local names: { string } = {}
        local name = next(rawFragment)
        while name ~= nil do
            if type(name) ~= "string" or #name < 1 or #name > 32
                or string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") == nil then
                return composeFailure("event keys must be valid Relay names")
            end
            count += 1
            if count > 64 then return composeFailure("composition allows at most 64 events") end
            table.insert(names, name)
            name = next(rawFragment, name)
        end
        table.sort(names)

        for _, key in names do
            if rawget(events, key) ~= nil then return composeFailure("duplicate event name") end
            local event = rawget(rawFragment, key)
            if type(event) ~= "table" or getmetatable(event) ~= nil then
                return composeFailure("event must be a plain table")
            end
            local rawEvent = event :: { [string]: unknown }
            local id = rawget(rawEvent, "id")
            if type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 65_535 then
                return composeFailure("invalid event ID")
            end
            if ids[id] then return composeFailure("duplicate event ID") end
            local direction = rawget(rawEvent, "direction")
            if direction ~= "ClientToServer" and direction ~= "ServerToClient" then
                return composeFailure("invalid event direction")
            end
            ids[id] = true
            events[key] = event
        end
    end

    if count == 0 then return composeFailure("composition requires at least one event") end
    return table.freeze(events), nil
end

type ComposeSignature = <P...>(P...) -> (mergedEvents<Ordered<P...>>?, ComposeError?)
local compose: ComposeSignature = (runtimeCompose :: unknown) :: ComposeSignature

local function ordered<T...>(...: T...): Ordered<T...>
    local values = { ... }
    for index, value in values do
        if type(value) == "table" then
            values[index] = table.freeze(table.clone(value :: any))
        end
    end
    return table.freeze(values) :: any
end

local function field<N, S>(name: N, shape: S): S & { name: N }
    local named = table.clone((shape :: unknown) :: { [string]: unknown })
    assert(rawget(named, "name") == nil, "field shape must not already have a name")
    named.name = name
    return (table.freeze(named) :: unknown) :: S & { name: N }
end

local function boolean(): { read type: "boolean" }
    return table.freeze({ type = "boolean" :: "boolean" })
end

local function string(maximumBytes: number): { read type: "string", read maximumBytes: number }
    return table.freeze({ type = "string" :: "string", maximumBytes = maximumBytes })
end

local function u8(minimum: number?, maximum: number?): { read type: "u8", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "u8" :: "u8", minimum = minimum, maximum = maximum })
end

local function u16(minimum: number?, maximum: number?): { read type: "u16", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "u16" :: "u16", minimum = minimum, maximum = maximum })
end

local function u32(minimum: number?, maximum: number?): { read type: "u32", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "u32" :: "u32", minimum = minimum, maximum = maximum })
end

local function i8(minimum: number?, maximum: number?): { read type: "i8", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "i8" :: "i8", minimum = minimum, maximum = maximum })
end

local function i16(minimum: number?, maximum: number?): { read type: "i16", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "i16" :: "i16", minimum = minimum, maximum = maximum })
end

local function i32(minimum: number?, maximum: number?): { read type: "i32", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "i32" :: "i32", minimum = minimum, maximum = maximum })
end

local function f32(minimum: number, maximum: number): { read type: "f32", read minimum: number, read maximum: number }
    return table.freeze({ type = "f32" :: "f32", minimum = minimum, maximum = maximum })
end

local function Vector2F32(minimum: number, maximum: number): { read type: "Vector2F32", read minimum: number, read maximum: number }
    return table.freeze({ type = "Vector2F32" :: "Vector2F32", minimum = minimum, maximum = maximum })
end

local function Vector3F32(minimum: number, maximum: number): { read type: "Vector3F32", read minimum: number, read maximum: number }
    return table.freeze({ type = "Vector3F32" :: "Vector3F32", minimum = minimum, maximum = maximum })
end

local function CFrame(minimum: number, maximum: number): { read type: "CFrame", read minimum: number, read maximum: number }
    return table.freeze({ type = "CFrame" :: "CFrame", minimum = minimum, maximum = maximum })
end

local function Color3(): { read type: "Color3" }
    return table.freeze({ type = "Color3" :: "Color3" })
end

local function robloxEnum<V...>(...: V...): { read type: "robloxEnum", read values: Ordered<V...> }
    return table.freeze({ type = "robloxEnum" :: "robloxEnum", values = ordered(...) })
end

local function UDim(minimumScale: number, maximumScale: number, minimumOffset: number, maximumOffset: number):
    { read type: "UDim", read minimumScale: number, read maximumScale: number, read minimumOffset: number, read maximumOffset: number }
    return table.freeze({ type = "UDim" :: "UDim", minimumScale = minimumScale, maximumScale = maximumScale,
        minimumOffset = minimumOffset, maximumOffset = maximumOffset })
end

local function UDim2(minimumScale: number, maximumScale: number, minimumOffset: number, maximumOffset: number):
    { read type: "UDim2", read minimumScale: number, read maximumScale: number, read minimumOffset: number, read maximumOffset: number }
    return table.freeze({ type = "UDim2" :: "UDim2", minimumScale = minimumScale, maximumScale = maximumScale,
        minimumOffset = minimumOffset, maximumOffset = maximumOffset })
end

local function NumberRange(minimum: number, maximum: number): { read type: "NumberRange", read minimum: number, read maximum: number }
    return table.freeze({ type = "NumberRange" :: "NumberRange", minimum = minimum, maximum = maximum })
end

local function Rect(minimum: number, maximum: number): { read type: "Rect", read minimum: number, read maximum: number }
    return table.freeze({ type = "Rect" :: "Rect", minimum = minimum, maximum = maximum })
end

local function BrickColor<V...>(...: V...): { read type: "BrickColor", read values: Ordered<V...> }
    return table.freeze({ type = "BrickColor" :: "BrickColor", values = ordered(...) })
end

local function Vector2int16(minimum: number?, maximum: number?):
    { read type: "Vector2int16", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "Vector2int16" :: "Vector2int16", minimum = minimum, maximum = maximum })
end

local function Vector3int16(minimum: number?, maximum: number?):
    { read type: "Vector3int16", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "Vector3int16" :: "Vector3int16", minimum = minimum, maximum = maximum })
end

local function NumberSequence(maximumKeypoints: number, minimum: number, maximum: number, maximumEnvelope: number):
    { read type: "NumberSequence", read maximumKeypoints: number, read minimum: number, read maximum: number, read maximumEnvelope: number }
    return table.freeze({ type = "NumberSequence" :: "NumberSequence", maximumKeypoints = maximumKeypoints,
        minimum = minimum, maximum = maximum, maximumEnvelope = maximumEnvelope })
end

local function ColorSequence(maximumKeypoints: number): { read type: "ColorSequence", read maximumKeypoints: number }
    return table.freeze({ type = "ColorSequence" :: "ColorSequence", maximumKeypoints = maximumKeypoints })
end

local function NumberSequenceKeypoint(minimum: number, maximum: number, maximumEnvelope: number):
    { read type: "NumberSequenceKeypoint", read minimum: number, read maximum: number, read maximumEnvelope: number }
    return table.freeze({ type = "NumberSequenceKeypoint" :: "NumberSequenceKeypoint", minimum = minimum,
        maximum = maximum, maximumEnvelope = maximumEnvelope })
end

local function ColorSequenceKeypoint(): { read type: "ColorSequenceKeypoint" }
    return table.freeze({ type = "ColorSequenceKeypoint" :: "ColorSequenceKeypoint" })
end

local function TweenInfo(maximumTime: number, maximumDelayTime: number, maximumRepeatCount: number, allowInfiniteRepeat: boolean?):
    { read type: "TweenInfo", read maximumTime: number, read maximumDelayTime: number, read maximumRepeatCount: number, read allowInfiniteRepeat: boolean? }
    return table.freeze({ type = "TweenInfo" :: "TweenInfo", maximumTime = maximumTime, maximumDelayTime = maximumDelayTime,
        maximumRepeatCount = maximumRepeatCount, allowInfiniteRepeat = allowInfiniteRepeat })
end

local function DateTime(minimum: number, maximum: number): { read type: "DateTime", read minimum: number, read maximum: number }
    return table.freeze({ type = "DateTime" :: "DateTime", minimum = minimum, maximum = maximum })
end

local function Ray(minimum: number, maximum: number, maximumDirectionMagnitude: number):
    { read type: "Ray", read minimum: number, read maximum: number, read maximumDirectionMagnitude: number }
    return table.freeze({ type = "Ray" :: "Ray", minimum = minimum, maximum = maximum,
        maximumDirectionMagnitude = maximumDirectionMagnitude })
end

local function Axes(): { read type: "Axes" }
    return table.freeze({ type = "Axes" :: "Axes" })
end

local function Faces(): { read type: "Faces" }
    return table.freeze({ type = "Faces" :: "Faces" })
end

local function Region3(minimum: number, maximum: number): { read type: "Region3", read minimum: number, read maximum: number }
    return table.freeze({ type = "Region3" :: "Region3", minimum = minimum, maximum = maximum })
end

local function Region3int16(minimum: number?, maximum: number?):
    { read type: "Region3int16", read minimum: number?, read maximum: number? }
    return table.freeze({ type = "Region3int16" :: "Region3int16", minimum = minimum, maximum = maximum })
end

local function PhysicalProperties(): { read type: "PhysicalProperties" }
    return table.freeze({ type = "PhysicalProperties" :: "PhysicalProperties" })
end

local function Font<V...>(...: V...): { read type: "Font", read families: Ordered<V...> }
    return table.freeze({ type = "Font" :: "Font", families = ordered(...) })
end

local function PathWaypoint(minimum: number, maximum: number, maximumLabelBytes: number):
    { read type: "PathWaypoint", read minimum: number, read maximum: number, read maximumLabelBytes: number }
    return table.freeze({ type = "PathWaypoint" :: "PathWaypoint", minimum = minimum, maximum = maximum,
        maximumLabelBytes = maximumLabelBytes })
end

local function struct<F...>(...: F...): { read type: "struct", read fields: Ordered<F...> }
    return table.freeze({ type = "struct" :: "struct", fields = ordered(...) })
end

local function taggedUnion<Tag, Variants>(tag: Tag, variants: Variants):
    { read type: "taggedUnion", read tag: Tag, read variants: Variants }
    local copiedVariants = table.clone((variants :: unknown) :: { [string]: unknown })
    return table.freeze({ type = "taggedUnion" :: "taggedUnion", tag = tag, variants = table.freeze(copiedVariants) })
end

local function enum<V...>(...: V...): { read type: "enum", read values: Ordered<V...> }
    return table.freeze({ type = "enum" :: "enum", values = ordered(...) })
end

local function array<S>(element: S, maximumLength: number): { read type: "array", read element: S, read maximumLength: number }
    return table.freeze({ type = "array" :: "array", element = element, maximumLength = maximumLength })
end

local function set<S>(element: S, maximumSize: number): { read type: "set", read element: S, read maximumSize: number }
    return table.freeze({ type = "set" :: "set", element = element, maximumSize = maximumSize })
end

local function map<K, V>(key: K, value: V, maximumSize: number):
    { read type: "map", read key: K, read value: V, read maximumSize: number }
    return table.freeze({ type = "map" :: "map", key = key, value = value, maximumSize = maximumSize })
end

local function optional<S>(value: S): { read type: "optional", read value: S }
    return table.freeze({ type = "optional" :: "optional", value = value })
end

local function clientToServer<F>(id: number, fields: F, delivery: Delivery?):
    { read id: number, read direction: "ClientToServer", read fields: F, read delivery: Delivery? }
    return table.freeze({ id = id, direction = "ClientToServer" :: "ClientToServer", fields = fields, delivery = delivery })
end

local function serverToClient<F>(id: number, fields: F, delivery: Delivery?):
    { read id: number, read direction: "ServerToClient", read fields: F, read delivery: Delivery? }
    return table.freeze({ id = id, direction = "ServerToClient" :: "ServerToClient", fields = fields, delivery = delivery })
end

local function request<F, R>(id: number, fields: F, response: R):
    { read id: number, read request: F, read response: R }
    return table.freeze({ id = id, request = fields, response = response })
end

return table.freeze({
    ordered = ordered,
    compose = compose,
    field = field,
    boolean = boolean,
    string = string,
    u8 = u8,
    u16 = u16,
    u32 = u32,
    i8 = i8,
    i16 = i16,
    i32 = i32,
    f32 = f32,
    Vector2F32 = Vector2F32,
    Vector3F32 = Vector3F32,
    CFrame = CFrame,
    Color3 = Color3,
    robloxEnum = robloxEnum,
    UDim = UDim,
    UDim2 = UDim2,
    NumberRange = NumberRange,
    Rect = Rect,
    BrickColor = BrickColor,
    Vector2int16 = Vector2int16,
    Vector3int16 = Vector3int16,
    NumberSequence = NumberSequence,
    ColorSequence = ColorSequence,
    NumberSequenceKeypoint = NumberSequenceKeypoint,
    ColorSequenceKeypoint = ColorSequenceKeypoint,
    TweenInfo = TweenInfo,
    DateTime = DateTime,
    Ray = Ray,
    Axes = Axes,
    Faces = Faces,
    Region3 = Region3,
    Region3int16 = Region3int16,
    PhysicalProperties = PhysicalProperties,
    Font = Font,
    PathWaypoint = PathWaypoint,
    struct = struct,
    taggedUnion = taggedUnion,
    enum = enum,
    array = array,
    set = set,
    map = map,
    optional = optional,
    clientToServer = clientToServer,
    serverToClient = serverToClient,
    request = request,
})
