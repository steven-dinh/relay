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

type function namedFields(pack)
    local ordered
    if pack.tag == "intersection" then
        for _, part in pack:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
    end
    if not ordered or ordered.tag ~= "function" then error("fixed ordered field entries required") end
    local parameters = ordered:parameters()
    if parameters.tail then error("fixed ordered field entries required") end
    local input: { type } = parameters.head or {}
    if #input > 8 then error("fields allows at most eight entries") end

    local output: { type } = {}
    for _, entry in input do
        local legacyName: type = types.never
        local legacyKind: type = types.never
        if entry.tag == "intersection" then
            for _, part in entry:components() do
                if part.tag == "table" then
                    local nameProperty = part:readproperty(types.singleton("name"))
                    local typeProperty = part:readproperty(types.singleton("type"))
                    if nameProperty then legacyName = nameProperty end
                    if typeProperty and typeProperty.tag == "singleton" and type(typeProperty:value()) == "string" then
                        legacyKind = typeProperty
                    end
                end
            end
        else
            if entry.tag ~= "table" or entry:readindexer() then error("field entry must be a literal table") end
            local nameProperty = entry:readproperty(types.singleton("name"))
            local typeProperty = entry:readproperty(types.singleton("type"))
            if nameProperty then legacyName = nameProperty end
            if typeProperty and typeProperty.tag == "singleton" and type(typeProperty:value()) == "string" then
                legacyKind = typeProperty
            end
        end
        if legacyName.tag ~= "never" and legacyKind.tag ~= "never" then
            table.insert(output, entry)
            continue
        end
        if entry.tag ~= "table" or entry:readindexer() then error("field entry must be a literal table") end
        local name: type = types.never
        local shape: type = types.never
        local count = 0
        for key, property in entry:properties() do
            count += 1
            if count > 1 then error("field entry must contain exactly one shape") end
            if key.tag ~= "singleton" or type(key:value()) ~= "string" or not property.read then
                error("field entry requires one literal name and shape")
            end
            name = key
            shape = property.read
        end
        if count ~= 1 or name.tag == "never" or shape.tag == "never" then
            error("field entry requires exactly one anonymous shape")
        end
        if shape.tag ~= "table" then error("field entry requires exactly one anonymous shape") end
        if shape:readproperty(types.singleton("name")) then error("field shape must be anonymous") end
        local field = types.copy(shape)
        field:setproperty(types.singleton("name"), name)
        table.insert(output, field)
    end
    return types.newfunction({ head = output }, { head = {} })
end

type FieldTypes<P...> = { [number]: unknown } & { [never]: namedFields<Ordered<P...>> }
type StructFields<P...> = FieldTypes<P...>

type function enumValues(pack)
    local ordered
    if pack.tag == "intersection" then
        for _, part in pack:components() do
            if part.tag == "table" then
                local indexer = part:readindexer()
                if indexer and indexer.index.tag == "never" then ordered = indexer.result end
            end
        end
    end
    if not ordered or ordered.tag ~= "function" then error("ordered enum values required") end
    local parameters = ordered:parameters()
    if parameters.tail then error("fixed enum values required") end
    local input: { type } = parameters.head or {}
    if #input ~= 1 or input[1].tag ~= "table" then
        return types.newfunction({ head = input }, { head = {} })
    end

    local source = input[1]
    if source:readindexer() then error("enum requires literal label keys") end
    local count = 0
    local output: { type } = {}
    for label, property in source:properties() do
        if label.tag ~= "singleton" or type(label:value()) ~= "string" or not property.read then
            error("enum map requires literal string labels and numeric ordinals")
        end
        if not property.read:issubtypeof(types.number) then error("enum ordinals must be numeric") end
        count += 1
        if count > 32 then error("enum allows at most 32 labels") end
        table.insert(output, label)
    end
    if count == 0 then error("enum requires at least one label") end
    return types.newfunction({ head = output }, { head = {} })
end

type EnumValues<P...> = { [number]: unknown } & { [never]: enumValues<Ordered<P...>> }

type function taggedUnionShape(source)
    if source.tag ~= "table" or source:readindexer() then error("tagged union requires one literal wrapper key") end
    local tag, variants
    local count = 0
    for key, property in source:properties() do
        count += 1
        if count > 1 then error("tagged union requires exactly one wrapper key") end
        if key.tag ~= "singleton" or type(key:value()) ~= "string" or not property.read then
            error("tagged union wrapper key must be a string literal")
        end
        tag = key
        variants = property.read
    end
    if count ~= 1 or not tag or not variants then error("tagged union requires exactly one wrapper key") end
    local result = types.newtable()
    result:setproperty(types.singleton("type"), types.singleton("taggedUnion"))
    result:setproperty(types.singleton("tag"), tag)
    result:setproperty(types.singleton("variants"), variants)
    return result
end

type TaggedUnion<Source> = taggedUnionShape<Source>

type QueuedDelivery = "Reliable" | "Unreliable"
type Queue = "Batch" | "State"
type Event<Direction, Fields, DeliveryValue = Delivery?> = {
    read id: number,
    read direction: Direction,
    read fields: Fields,
    read delivery: DeliveryValue,
}
type QueuedEvent<Direction, Fields, QueueValue> = {
    read id: number,
    read direction: Direction,
    read fields: Fields,
    read delivery: QueuedDelivery?,
    read queue: QueueValue,
}
type NoQueueOptions = { [string]: any } & { read queue: nil?, read delivery: Delivery? }
type QueueOptions<QueueValue> = { read queue: QueueValue & Queue, read delivery: QueuedDelivery? }
type Endpoint<Direction> =
    (<Fields>(id: number, fields: Fields) -> Event<Direction, Fields, nil?>)
    & (<Fields, EventDelivery>(id: number, fields: Fields, delivery: EventDelivery & Delivery) -> Event<Direction, Fields, EventDelivery>)
    & (<Fields>(id: number, fields: Fields, options: NoQueueOptions) -> Event<Direction, Fields>)
    & (<Fields, QueueValue>(id: number, fields: Fields, options: QueueOptions<QueueValue>) -> QueuedEvent<Direction, Fields, QueueValue>)

local function ordered<T...>(...: T...): Ordered<T...>
    local values = { ... }
    for index, value in values do
        if type(value) == "table" then
            values[index] = table.freeze(table.clone(value :: any))
        end
    end
    return table.freeze(values) :: any
end

local function plainTable(value: unknown, message: string): any
    assert(type(value) == "table" and getmetatable(value) == nil, message)
    return value
end

local function assertSmallRecord(value: any, message: string)
    local count = 0
    local key = next(value)
    while key ~= nil do
        count += 1
        assert(count <= 8, message)
        key = next(value, key)
    end
end

local function field<N, S>(name: N, shape: S): S & { name: N }
    local source = plainTable(shape, "field shape must be a plain anonymous table")
    assertSmallRecord(source, "field shape has too many keys")
    local named = table.clone(source)
    assert(rawget(named, "name") == nil, "field shape must not already have a name")
    named.name = name
    return (table.freeze(named) :: unknown) :: S & { name: N }
end

local function oneNamedShape(value: unknown, message: string): (string, any)
    local entry = plainTable(value, message)
    local name, shape = next(entry)
    assert(type(name) == "string" and shape ~= nil and next(entry, name) == nil,
        "entry must contain exactly one named shape")
    shape = plainTable(shape, "field shape must be a plain anonymous table")
    assert(rawget(shape, "name") == nil, "field shape must be anonymous")
    return name, shape
end

local function normalizeFields(...: unknown): any
    local count = select("#", ...)
    assert(count <= 8, "schema allows at most eight fields")
    local output = table.create(count)
    for index = 1, count do
        local entry = plainTable(select(index, ...), "field entry must be a plain table")
        local name = rawget(entry, "name")
        local kind = rawget(entry, "type")
        if type(name) == "string" and type(kind) == "string" then
            assertSmallRecord(entry, "legacy field record has too many keys")
            output[index] = entry
        else
            local fieldName, shape = oneNamedShape(entry, "field entry must be a plain table")
            output[index] = field(fieldName, shape)
        end
    end
    return ordered(table.unpack(output, 1, count)) :: any
end

local function fields<P...>(...: P...): FieldTypes<P...>
    return normalizeFields(...) :: any
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

type InstanceClass = "Instance" | "BasePart" | "Part" | "MeshPart" | "Model" | "Humanoid" | "Tool"
    | "Attachment" | "Player" | "Folder" | "GuiObject" | "Sound" | "Animation" | "Animator"
local function Instance<ClassName>(className: ClassName & InstanceClass): { read type: "Instance", read className: ClassName }
    return table.freeze({ type = "Instance" :: "Instance", className = className })
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

local function struct<P...>(...: P...): { read type: "struct", read fields: StructFields<P...> }
    return table.freeze({ type = "struct" :: "struct", fields = normalizeFields(...) }) :: any
end

local function taggedUnionRecord<Tag, Variants>(tag: Tag, variants: Variants):
    { read type: "taggedUnion", read tag: Tag, read variants: Variants }
    local copiedVariants = table.clone((variants :: unknown) :: { [string]: unknown })
    return table.freeze({ type = "taggedUnion" :: "taggedUnion", tag = tag, variants = table.freeze(copiedVariants) })
end

type TaggedUnionSignature =
    (<Tag, Variants>(tag: Tag, variants: Variants) -> { read type: "taggedUnion", read tag: Tag, read variants: Variants })
    & (<Source>(source: Source) -> TaggedUnion<Source>)

local function taggedUnionRuntime(sourceOrTag: unknown, legacyVariants: unknown): any
    if legacyVariants ~= nil then
        return taggedUnionRecord(sourceOrTag, legacyVariants)
    end

    local source = plainTable(sourceOrTag, "tagged union wrapper must be a plain table")
    local tag, variants = next(source)
    assert(type(tag) == "string" and variants ~= nil and next(source, tag) == nil,
        "tagged union wrapper must contain exactly one discriminator")
    local variantTable = plainTable(variants, "tagged union variants must be a plain table")
    local count = 0
    local label = next(variantTable)
    while label ~= nil do
        count += 1
        assert(count <= 32, "tagged union allows at most 32 variants")
        assert(type(label) == "string", "tagged union variant labels must be strings")
        label = next(variantTable, label)
    end
    return taggedUnionRecord(tag, variantTable)
end

local taggedUnion: TaggedUnionSignature = (taggedUnionRuntime :: unknown) :: TaggedUnionSignature

local function enum<P...>(...: P...): { read type: "enum", read values: EnumValues<P...> }
    local arguments = { ... }
    local count = select("#", ...)
    if count == 1 and type(arguments[1]) == "table" then
        local source = plainTable(arguments[1], "enum map must be a plain table")
        local byOrdinal: { [number]: string } = {}
        local labelCount = 0
        local label, ordinal = next(source)
        while label ~= nil do
            labelCount += 1
            assert(labelCount <= 32, "enum allows at most 32 labels")
            assert(type(label) == "string", "enum labels must be strings")
            assert(type(ordinal) == "number" and ordinal == ordinal and ordinal % 1 == 0
                and ordinal >= 1 and ordinal <= 32, "enum ordinals must be integers from one to 32")
            assert(byOrdinal[ordinal] == nil, "enum ordinals must be unique")
            byOrdinal[ordinal] = label
            label, ordinal = next(source, label)
        end
        assert(labelCount > 0, "enum requires at least one label")
        local values = table.create(labelCount)
        for index = 1, labelCount do
            local value = byOrdinal[index]
            assert(value ~= nil, "enum ordinals must be dense")
            values[index] = value
        end
        return table.freeze({ type = "enum" :: "enum", values = ordered(table.unpack(values, 1, labelCount)) }) :: any
    end
    return table.freeze({ type = "enum" :: "enum", values = ordered(table.unpack(arguments, 1, count)) }) :: any
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

local function endpoint(direction: string, id: number, fieldsValue: any, third: any): any
    local delivery, queue
    if type(third) == "string" then
        delivery = third
    elseif third ~= nil then
        local options = plainTable(third, "endpoint options must be a plain table")
        local key = next(options)
        local optionCount = 0
        while key ~= nil do
            optionCount += 1
            assert(optionCount <= 2, "endpoint options contain unknown keys")
            if key == "delivery" then
                delivery = rawget(options, key)
            elseif key == "queue" then
                queue = rawget(options, key)
            else
                error("endpoint options contain an unknown key")
            end
            key = next(options, key)
        end
        assert(delivery == nil or delivery == "Reliable" or delivery == "Unreliable"
            or delivery == "OrderedUnreliable", "invalid endpoint delivery")
        assert(queue == nil or queue == "Batch" or queue == "State", "invalid endpoint queue")
        assert(queue == nil or delivery ~= "OrderedUnreliable", "OrderedUnreliable cannot be queued")
    end
    return table.freeze({ id = id, direction = direction, fields = fieldsValue, delivery = delivery, queue = queue })
end

local function clientToServerRuntime(id: number, fieldsValue: any, third: any): any
    return endpoint("ClientToServer" :: "ClientToServer", id, fieldsValue, third)
end

local function serverToClientRuntime(id: number, fieldsValue: any, third: any): any
    return endpoint("ServerToClient" :: "ServerToClient", id, fieldsValue, third)
end

local clientToServer: Endpoint<"ClientToServer"> = (clientToServerRuntime :: unknown) :: Endpoint<"ClientToServer">
local serverToClient: Endpoint<"ServerToClient"> = (serverToClientRuntime :: unknown) :: Endpoint<"ServerToClient">

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
    Instance = Instance,
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
    fields = fields,
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
