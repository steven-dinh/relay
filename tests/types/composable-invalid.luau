--!strict
local Relay = require("../../src/init")
local ordered = require("../../examples/reliable-events/ordered")

local badStructName = Relay.define({ name = "BadStructName", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "record", type = "struct" :: "struct", fields = ordered(
        { name = "mode" :: string, type = "boolean" :: "boolean" }
    ) }),
} } })

local badArrayChild = Relay.define({ name = "BadArrayChild", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "items", type = "array" :: "array", maximumLength = 4,
        element = { type = "optional" :: "optional", value = { type = "boolean" :: "boolean" } } }),
} } })

local badSetKey = Relay.define({ name = "BadSetKey", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "items", type = "set" :: "set", maximumSize = 4,
        element = { type = "Vector3F32" :: "Vector3F32", minimum = -1, maximum = 1 } }),
} } })

local badEnumLiteral = Relay.define({ name = "BadEnumLiteral", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "mode", type = "enum" :: "enum", values = ordered("Idle", "Run") }),
} } })

print(badStructName, badArrayChild, badSetKey, badEnumLiteral)

local validDefinition = Relay.define({ name = "BadPayloadTypes", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "snapshot", type = "struct" :: "struct", fields = ordered(
        { name = "mode" :: "mode", type = "enum" :: "enum", values = ordered("Idle" :: "Idle", "Run" :: "Run") },
        { name = "scores" :: "scores", type = "array" :: "array", maximumLength = 4,
            element = { type = "u16" :: "u16" } },
        { name = "tags" :: "tags", type = "set" :: "set", maximumSize = 4,
            element = { type = "string" :: "string", maximumBytes = 8 } },
        { name = "target" :: "target", type = "optional" :: "optional",
            value = { type = "u32" :: "u32" } }
    ) }),
} } })
if validDefinition then
    local client = Relay.createClient(validDefinition, { startupTimeoutSeconds = 10 })
    if client then
        client.events.Input:Send({ mode = "Other", scores = {}, tags = {} })
        client.events.Input:Send({ mode = "Idle", scores = { "bad" }, tags = {} })
        client.events.Input:Send({ mode = "Idle", scores = {}, tags = { blue = false } })
        client.events.Input:Send({ mode = "Idle", scores = {}, tags = { [1] = true } })
        client.events.Input:Send({ mode = "Idle", scores = {}, tags = {}, target = "bad" })
    end
end

local depthFiveFifth = { type = "array" :: "array", maximumLength = 1,
    element = { type = "boolean" :: "boolean" } }
local depthFiveFourth = { type = "array" :: "array", maximumLength = 1, element = depthFiveFifth }
local depthFiveThird = { type = "array" :: "array", maximumLength = 1, element = depthFiveFourth }
local depthFiveSecond = { type = "array" :: "array", maximumLength = 1, element = depthFiveThird }
local depthFiveDefinition = Relay.define({ name = "DepthFive", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "value", type = "array" :: "array", maximumLength = 1,
        element = depthFiveSecond }),
} } })

type RecursiveShape = { type: "array", maximumLength: number, element: RecursiveShape }
local recursive: RecursiveShape = (nil :: any)
local recursiveSpec = { name = "Recursive", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "items", type = "array" :: "array", maximumLength = 1, element = recursive }),
} } }
local recursiveDefinition = Relay.define(recursiveSpec)
type RecursiveClientSession = Relay.ClientSession<typeof(recursiveSpec)>
local recursiveSession: RecursiveClientSession = error("type-only fixture")
print(depthFiveDefinition, recursiveDefinition, recursiveSession)

local enumSetDefinition = Relay.define({ name = "EnumSetValues", version = 1, events = { Input = {
    id = 1, direction = "ClientToServer" :: "ClientToServer",
    fields = ordered({ name = "modes", type = "set" :: "set", maximumSize = 4,
        element = { type = "enum" :: "enum", values = ordered("Idle" :: "Idle", "Run" :: "Run") } }),
} } })
if enumSetDefinition then
    local enumSetClient = Relay.createClient(enumSetDefinition, { startupTimeoutSeconds = 10 })
    if enumSetClient then
        enumSetClient.events.Input:Send({ Idle = true })
        enumSetClient.events.Input:Send({ Idle = false })
    end
end
