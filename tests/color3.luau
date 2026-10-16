local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../src/Definition")
local Schema = require("../src/Schema")
local CompositeCodec = require("../src/internal/CompositeCodec")
local RpcFrame = require("../src/internal/RpcFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local constructorCalls = 0
local colorApi = {
    new = function(red, green, blue)
        constructorCalls += 1
        return roblox.Color3.new(red, green, blue)
    end,
}
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
    environment = {
        Vector2 = roblox.Vector2,
        Vector3 = roblox.Vector3,
        CFrame = roblox.CFrame,
        Color3 = colorApi,
        require = function(path)
            assert(path == "./CompositeCodec")
            return CompositeCodec
        end,
    },
    injectGlobals = true,
})()

local function valid(spec, label)
    local definition, problem = Definition.define(spec)
    assert(definition ~= nil and problem == nil, `{label}: {problem and problem.message}`)
    return definition, assert(Definition.get(definition))
end

local function invalid(spec, label)
    local definition = Definition.define(spec)
    assert(definition == nil, label)
end

local function encode(event, ...)
    local result = table.pack(Frame.compile(event, "encode")(...))
    assert(result[1] == true, "Color3 encoding succeeds")
    return result[2]
end

local helperShape = Schema.Color3()
assert(table.isfrozen(helperShape) and helperShape.type == "Color3")
local helperToken, helperCompiled = valid({
    name = "Color3Helper",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = {
        Schema.field("tint", helperShape),
    } } },
})
local _, rawCompiled = valid({
    name = "Color3Helper",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", fields = {
        { name = "tint", type = "Color3" },
    } } },
})
assert(helperCompiled.descriptor == rawCompiled.descriptor
    and helperCompiled.descriptor:find("c3f32,00000000,3f800000", 1, true) ~= nil,
    `helper and raw Color3 definitions share the fixed domain descriptor: {helperCompiled.descriptor} / {rawCompiled.descriptor}`)
local helperField = helperCompiled.events.Input.fields[1]
assert(helperField.minimum == 0 and helperField.maximum == 1
    and helperField.minimumEncodedBytes == 12 and helperField.maximumEncodedBytes == 12
    and not helperCompiled.events.Input.usesCodec
    and Definition.inspect(helperToken).events.Input.bytes.representation == "NativeTuple",
    "reliable primitive Color3 remains a native tuple with fixed twelve-byte schema cost")

for _, field in {
    { name = "tint", type = "Color3", minimum = 0, maximum = 1 },
    { name = "tint", type = "Color3", extra = true },
} do
    invalid({ name = "Color3Closed", version = 1, events = {
        Input = { id = 1, direction = "ClientToServer", fields = { field } },
    } }, "Color3 rejects bounds and unknown keys")
end
invalid({ name = "Color3Set", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", fields = { { name = "tints", type = "set",
        maximumSize = 4, element = { type = "Color3" } } } },
} }, "Color3 remains ineligible as a set key")

local boundary = {
    name = "Color3Unreliable900",
    version = 1,
    events = { Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {
        { name = "colors", type = "array", maximumLength = 64, element = { type = "Color3" } },
        { name = "padding", type = "string", maximumBytes = 125 },
    } } },
}
local _, boundaryCompiled = valid(boundary, "900-byte Color3 unreliable schema")
assert(boundaryCompiled.events.Input.maximumEncodedBytes == 900)
boundary.events.Input.fields[2].maximumBytes = 126
invalid(boundary, "901-byte Color3 unreliable schema is rejected")

local token, compiled = valid({
    name = "Color3Codec",
    version = 1,
    events = {
        Reliable = { id = 1, direction = "ClientToServer", fields = { { name = "tint", type = "Color3" } } },
        Unreliable = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
            fields = { { name = "tint", type = "Color3" } } },
        Nested = { id = 3, direction = "ClientToServer", fields = {
            { name = "paint", type = "struct", fields = {
                { name = "base", type = "Color3" },
                { name = "swatches", type = "array", maximumLength = 3, element = { type = "Color3" } },
                { name = "accent", type = "optional", value = { type = "Color3" } },
            } },
        } },
        Batch = { id = 4, direction = "ServerToClient", queue = "Batch",
            fields = { { name = "tint", type = "Color3" } } },
        State = { id = 5, direction = "ServerToClient", queue = "State",
            fields = { { name = "tint", type = "Color3" } } },
    },
    requests = { Paint = { id = 6, request = { { name = "tint", type = "Color3" } }, response = { type = "Color3" } } },
})
assert(compiled.descriptor:find("c3f32[00000000,3f800000]", 1, true) ~= nil
    and compiled.events.Reliable.usesCodec == false
    and compiled.events.Unreliable.usesCodec == true
    and compiled.queuedById[4].usesCodec and compiled.queuedById[5].usesCodec,
    "only unreliable, composite, request, and queued paths force Color3 buffers")

local negativeZero = -1 / math.huge
local sourceColor = roblox.Color3.new(0.1, 0.2, 0.3)
local normalize = Frame.compile({ fields = { { type = "Color3", minimum = 0, maximum = 1 } } })
constructorCalls = 0
local normalizedResult = table.pack(normalize(sourceColor))
assert(normalizedResult.n == 2 and normalizedResult[1] == true
    and typeof(normalizedResult[2]) == "Color3"
    and normalizedResult[2].R == sourceColor.R and normalizedResult[2].G == sourceColor.G
    and normalizedResult[2].B == sourceColor.B and constructorCalls == 0,
    "already normalized immutable Color3 reuses its native value")
local normalizedZero = table.pack(normalize(roblox.Color3.new(negativeZero, 0.5, 1)))
assert(normalizedZero[1] and normalizedZero[2].R == 0 and 1 / normalizedZero[2].R == math.huge
    and normalizedZero[2].G == 0.5 and normalizedZero[2].B == 1,
    "negative zero becomes positive without changing valid channels")
for _, bad in {
    { R = 0, G = 0, B = 0 },
    roblox.Color3.new(-0.01, 0, 0), roblox.Color3.new(1.01, 0, 0),
    roblox.Color3.new(0 / 0, 0, 0), roblox.Color3.new(0, math.huge, 0),
    roblox.Color3.new(0, 0, -math.huge),
} do
    assert(normalize(bad) == nil, "wrong type and invalid channel values reject without repair")
end

local unreliableFrame = encode(compiled.events.Unreliable, sourceColor)
assert(typeof(unreliableFrame) == "buffer" and buffer.len(unreliableFrame) == 15
    and buffer.readu8(unreliableFrame, 0) == 1 and buffer.readu16(unreliableFrame, 1) == 2
    and buffer.readf32(unreliableFrame, 3) == sourceColor.R
    and buffer.readf32(unreliableFrame, 7) == sourceColor.G
    and buffer.readf32(unreliableFrame, 11) == sourceColor.B,
    "Color3 uses the existing three-byte header and ordered twelve-byte f32 body")
local decodeUnreliable = Frame.compile(compiled.events.Unreliable, "decode")
constructorCalls = 0
local decodedColor = table.pack(decodeUnreliable(unreliableFrame))
assert(decodedColor.n == 2 and decodedColor[1] and typeof(decodedColor[2]) == "Color3"
    and decodedColor[2].R == sourceColor.R and decodedColor[2].G == sourceColor.G
    and decodedColor[2].B == sourceColor.B and constructorCalls == 1,
    "forced Color3 codec reconstructs the checked native value")

local truncated = buffer.create(14)
buffer.writeu8(truncated, 0, 1)
buffer.writeu16(truncated, 1, 2)
constructorCalls = 0
assert(decodeUnreliable(truncated) == nil and constructorCalls == 0,
    "truncated Color3 is rejected before construction")
local malformed = buffer.create(15)
buffer.writeu8(malformed, 0, 1)
buffer.writeu16(malformed, 1, 2)
buffer.writef32(malformed, 3, 1.01)
buffer.writef32(malformed, 7, 0.5)
buffer.writef32(malformed, 11, 0.25)
constructorCalls = 0
assert(decodeUnreliable(malformed) == nil and constructorCalls == 0,
    "out-of-range wire channels reject before Color3 construction")
buffer.writef32(malformed, 3, math.huge)
constructorCalls = 0
assert(decodeUnreliable(malformed) == nil and constructorCalls == 0,
    "nonfinite wire channels reject before Color3 construction")
local trailing = buffer.create(16)
buffer.copy(trailing, 0, unreliableFrame, 0, 15)
constructorCalls = 0
assert(decodeUnreliable(trailing) == nil, "trailing bytes reject the complete Color3 frame")

local nestedColor = roblox.Color3.new(0.25, 0.5, 0.75)
local nestedFrame = encode(compiled.events.Nested, {
    base = sourceColor, swatches = { nestedColor, sourceColor }, accent = nestedColor,
})
local nestedResult = table.pack(Frame.compile(compiled.events.Nested, "decode")(nestedFrame))
assert(nestedResult[1] and typeof(nestedResult[2].base) == "Color3"
    and #nestedResult[2].swatches == 2 and nestedResult[2].swatches[1].G == nestedColor.G
    and nestedResult[2].accent.R == nestedColor.R,
    "struct, array, and optional Color3 shapes round-trip through the composite codec")
for _, id in { 4, 5 } do
    local body = encode(compiled.queuedById[id], sourceColor)
    assert(buffer.len(body) == 15 and Frame.compile(compiled.queuedById[id], "decode")(body),
        "queued Color3 bodies use the forced codec")
end

local method = compiled.requests.Paint
local requestBody = encode(method.request, sourceColor)
local guid = "01234567-89ab-cdef-0123-456789abcdef"
local requestPacket = assert(RpcFrame.wrap(1, method.id, 1, guid, requestBody))
local runtime = ServerRuntime.new()
local player = runtime:addPlayer()
local server = assert(runtime.server.create(token, { inboundRate = {
    perPlayer = { capacity = 32, refillPerSecond = 1 },
    aggregate = { capacity = 64, refillPerSecond = 1 },
} }))
local requestCalls = 0
assert(server.requests.Paint:Connect(function(sender, tint)
    assert(sender == player and typeof(tint) == "Color3" and tint.R == sourceColor.R)
    requestCalls += 1
    return tint
end))
assert(server:Start())
runtime:remote().OnServerEvent:Fire(player, 0, requestPacket)
local reply = runtime.fires[#runtime.fires]
assert(requestCalls == 1 and reply and reply.kind == "target" and reply.values.n == 2)
local replyHeader = assert(RpcFrame.peek(reply.values[2], false))
assert(replyHeader.kind == 2 and replyHeader.methodId == method.id)
local replyBody = assert(RpcFrame.readBody(reply.values[2], replyHeader,
    method.response.minimumEncodedBytes, method.response.maximumEncodedBytes))
local responseResult = table.pack(Frame.compile(method.response, "decode")(replyBody))
assert(responseResult[1] and typeof(responseResult[2]) == "Color3"
    and responseResult[2].R == sourceColor.R and responseResult[2].B == sourceColor.B,
    "Color3 RPC request and response use the bounded composite codec")
server:Destroy()

local byteLimited, byteCompiled = valid({
    name = "Color3ByteAdmission", version = 1,
    events = {
        Native = { id = 1, direction = "ClientToServer", fields = { { name = "tint", type = "Color3" } } },
        Raw = { id = 2, direction = "ClientToServer", delivery = "Unreliable",
            fields = { { name = "tint", type = "Color3" } } },
    },
})
do
    local nativeRuntime = ServerRuntime.new()
    local nativePlayer = nativeRuntime:addPlayer()
    local nativeServer = assert(nativeRuntime.server.create(byteLimited, { inboundRate = {
        perPlayer = { capacity = 4, refillPerSecond = 1 }, aggregate = { capacity = 8, refillPerSecond = 1 },
        bytes = { perPlayer = { capacity = 15, refillPerSecond = 1 },
            aggregate = { capacity = 15, refillPerSecond = 1 } },
    } }))
    local nativeCalls = 0
    assert(nativeServer.events.Native:Connect(function(_, tint)
        assert(typeof(tint) == "Color3")
        nativeCalls += 1
    end))
    assert(nativeServer:Start())
    nativeRuntime:remote().OnServerEvent:Fire(nativePlayer, 1, sourceColor)
    nativeRuntime:remote().OnServerEvent:Fire(nativePlayer, 1, sourceColor)
    local nativeCounters = nativeServer:GetDiagnostics().counters
    assert(nativeCalls == 1 and nativeCounters.perPlayerBytes == 1
        and nativeCounters.aggregateBytes == 0,
        "native Color3 charges twelve content bytes plus the existing three-byte header")
    nativeServer:Destroy()
end

do
    local rawRuntime = ServerRuntime.new()
    local rawPlayer = rawRuntime:addPlayer()
    local rawServer = assert(rawRuntime.server.create(byteLimited, { inboundRate = {
        perPlayer = { capacity = 4, refillPerSecond = 1 }, aggregate = { capacity = 8, refillPerSecond = 1 },
        bytes = { perPlayer = { capacity = 15, refillPerSecond = 1 },
            aggregate = { capacity = 15, refillPerSecond = 1 } },
    } }))
    local rawCalls = 0
    assert(rawServer.events.Raw:Connect(function() rawCalls += 1 end))
    assert(rawServer:Start())
    local rawRemote = assert(rawRuntime:unreliableRemote())
    rawRemote.OnServerEvent:Fire(rawPlayer, 2, malformed)
    local validFrame = encode(byteCompiled.events.Raw, sourceColor)
    rawRemote.OnServerEvent:Fire(rawPlayer, 2, validFrame)
    local rawCounters = rawServer:GetDiagnostics().counters
    assert(rawCalls == 0 and rawCounters.invalidPayload == 1 and rawCounters.perPlayerBytes == 1
        and rawRuntime.validationCalls == 1,
        "raw Color3 frame charges its full fifteen bytes before malformed-body rejection")
    rawServer:Destroy()
end

do
    local colorToken, colorCompiled = valid({
        name = "Color3Descriptor",
        version = 1,
        events = { Input = { id = 1, direction = "ClientToServer", fields = {
            { name = "tint", type = "Color3" },
        } } },
    }, "Color3 compatibility definition")
    local _, scalarCompiled = valid({
        name = "Color3Descriptor",
        version = 1,
        events = { Input = { id = 1, direction = "ClientToServer", fields = {
            { name = "tint", type = "f32", minimum = 0, maximum = 1 },
        } } },
    }, "prior scalar compatibility definition")
    assert(colorCompiled.descriptor:sub(1, 3) == scalarCompiled.descriptor:sub(1, 3)
        and colorCompiled.descriptor ~= scalarCompiled.descriptor,
        "Color3 descriptor must differ from the prior f32 shape while retaining the compatible descriptor revision")

    local runtime = ClientRuntime.create()
    runtime:transport(scalarCompiled.descriptor, false)
    local client = assert(runtime.module.create(colorToken, { startupTimeoutSeconds = 3 }))
    local started, problem = client:Start()
    assert(not started and problem and problem.code == "DefinitionMismatch" and table.isfrozen(problem)
        and #runtime.fires == 0,
        "a prior non-Color3 descriptor must reject startup before any application handoff")
    client:Destroy()
end

print("PASS Color3 schema, codec, runtime, RPC, and byte-admission proofs")
