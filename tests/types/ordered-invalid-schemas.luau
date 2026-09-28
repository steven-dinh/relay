--!strict
local Relay = require("../../src/init")
local ordered = require("../../examples/reliable-events/ordered")

local invalidName = Relay.define({ name = 42, version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered() } } })
local invalidVersion = Relay.define({ name = "BadVersion", version = "bad", events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered() } } })
local missingId = Relay.define({ name = "MissingId", version = 1, events = { Input = { direction = "ClientToServer" :: "ClientToServer", fields = ordered() } } })
local badDirection = Relay.define({ name = "BadDirection", version = 1, events = { Input = { id = 1, direction = "Sideways" :: "Sideways", fields = ordered() } } })
local plainFields = Relay.define({ name = "PlainFields", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = {} } } })
local missingStringLimit = Relay.define({ name = "MissingStringLimit", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "text", type = "string" :: "string" }) } } })
local missingF32Minimum = Relay.define({ name = "MissingF32Minimum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "f32" :: "f32", maximum = 1 }) } } })
local missingF32Maximum = Relay.define({ name = "MissingF32Maximum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "f32" :: "f32", minimum = -1 }) } } })
local missingVector2Minimum = Relay.define({ name = "MissingVector2Minimum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "Vector2F32" :: "Vector2F32", maximum = 1 }) } } })
local missingVector2Maximum = Relay.define({ name = "MissingVector2Maximum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "Vector2F32" :: "Vector2F32", minimum = -1 }) } } })
local missingVector3Minimum = Relay.define({ name = "MissingVector3Minimum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "Vector3F32" :: "Vector3F32", maximum = 1 }) } } })
local missingVector3Maximum = Relay.define({ name = "MissingVector3Maximum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "Vector3F32" :: "Vector3F32", minimum = -1 }) } } })
local missingCFrameMinimum = Relay.define({ name = "MissingCFrameMinimum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "CFrame" :: "CFrame", maximum = 1 }) } } })
local missingCFrameMaximum = Relay.define({ name = "MissingCFrameMaximum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "CFrame" :: "CFrame", minimum = -1 }) } } })
local invalidBoundType = Relay.define({ name = "InvalidBoundType", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "u8" :: "u8", minimum = "bad" }) } } })
local unsupportedKind = Relay.define({ name = "UnsupportedKind", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "i64" :: "i64" }) } } })
local invalidFieldName = Relay.define({ name = "InvalidFieldName", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = 1, type = "u8" :: "u8" }) } } })
local scalarField = Relay.define({ name = "ScalarField", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered(42) } } })

print(invalidName, invalidVersion, missingId, badDirection, plainFields, missingStringLimit, missingF32Minimum, missingF32Maximum, missingVector2Minimum, missingVector2Maximum, missingVector3Minimum, missingVector3Maximum, missingCFrameMinimum, missingCFrameMaximum, invalidBoundType, unsupportedKind, invalidFieldName, scalarField)

local function optionalNumber(value: number?): number?
    return value
end
local function optionalString(value: string?): string?
    return value
end
local invalidOptionalStringBound = Relay.define({ name = "InvalidOptionalStringBound", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "u8" :: "u8", minimum = optionalString("bad") }) } } })
local optionalF32Minimum = Relay.define({ name = "OptionalF32Minimum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "f32" :: "f32", minimum = optionalNumber(nil), maximum = 1 }) } } })
local optionalF32Maximum = Relay.define({ name = "OptionalF32Maximum", version = 1, events = { Input = { id = 1, direction = "ClientToServer" :: "ClientToServer", fields = ordered({ name = "value", type = "f32" :: "f32", minimum = -1, maximum = optionalNumber(nil) }) } } })
print(invalidOptionalStringBound, optionalF32Minimum, optionalF32Maximum)
