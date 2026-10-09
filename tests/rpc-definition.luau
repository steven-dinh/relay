local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../src/Definition")
local CompositeCodec = require("../src/internal/CompositeCodec")
local Frame = luau.load(fs.readFile("src/internal/Frame.luau"), {
    environment = {
        Vector2 = roblox.Vector2,
        Vector3 = roblox.Vector3,
        CFrame = roblox.CFrame,
        require = function(path)
            assert(path == "./CompositeCodec")
            return CompositeCodec
        end,
    },
    injectGlobals = true,
})()

local function countKeys(value)
    local count = 0
    for _ in value do count += 1 end
    return count
end

local function assertFrozen(value, path)
    if type(value) ~= "table" then return end
    assert(table.isfrozen(value), path .. " must be frozen")
    for key, child in value do
        assertFrozen(child, path .. "." .. tostring(key))
    end
end

local function define(spec, label)
    local token, problem = Definition.define(spec)
    assert(token ~= nil, label .. " rejected: " .. tostring(problem and problem.message))
    assert(problem == nil, label .. " unexpectedly returned an error")
    return Definition.get(token), token
end

local function invalid(spec, label, path, reason)
    local ok, token, problem = pcall(Definition.define, spec)
    assert(ok, label .. " must return without throwing")
    assert(token == nil and type(problem) == "table", label .. " must reject")
    assert(table.isfrozen(problem) and countKeys(problem) == 2, label .. " error must be a frozen pair")
    assert(problem.code == "InvalidDefinition" and #problem.message <= 256, label .. " error contract changed")
    if path ~= nil then assert(string.find(problem.message, path, 1, true), label .. " missing path") end
    if reason ~= nil then assert(string.find(problem.message, reason, 1, true), label .. " missing reason") end
end

local function requestField(name, maximum)
    return { name = name, type = "u16", maximum = maximum or 10 }
end

local function basicSpec()
    return {
        name = "Inventory",
        version = 1,
        events = {
            Ping = { id = 7, direction = "ClientToServer", fields = {
                { name = "value", type = "u16", maximum = 10 },
            } },
        },
        requests = {
            Inspect = {
                id = 9,
                request = { requestField("itemId") },
                response = { type = "struct", fields = {
                    { name = "owned", type = "boolean" },
                    { name = "count", type = "u16", maximum = 10 },
                } },
            },
        },
    }
end

local spec = basicSpec()
local compiled = define(spec, "RR5 definition")
local expected = "RR5|D9:Inventory|V1|N1|E7,C,R,4:Ping,1F5:value=P3:u16[0,10]"
    .. "|Q1|R9,7:Inspect,1[F6:itemId=P3:u16[0,10]]="
    .. "T2[F5:owned=P1:b[-,-]F5:count=P3:u16[0,10]]"
assert(compiled.descriptor == expected,
    "RR5 literal descriptor changed: " .. compiled.descriptor .. " expected " .. expected)
assert(countKeys(compiled) == 8, "compiled definition must include both event and request registries")
assert(compiled.events.Ping == compiled.byId[7] and compiled.events.Ping.direction == "ClientToServer")
assert(compiled.requests.Inspect == compiled.requestsById[9], "request name and ID maps must share the method")

local method = compiled.requests.Inspect
assert(countKeys(method) == 4 and method.id == 9 and method.name == "Inspect")
assert(method.request.usesCodec and method.request.delivery == "Reliable"
    and method.request.direction == "ClientToServer" and method.request.minimumEncodedBytes == 5
    and method.request.maximumEncodedBytes == 5 and method.request.maximumElements == 1)
assert(method.response.usesCodec and method.response.delivery == "Reliable"
    and method.response.direction == "ServerToClient" and method.response.minimumEncodedBytes == 6
    and method.response.maximumEncodedBytes == 6 and method.response.maximumElements == 3)
assert(method.response.fields[1].name == "Inspect" and method.response.fields[1].type == "struct",
    "the compiled response must have its private named root")
assert(rawget(spec.requests.Inspect.response, "name") == nil, "response compilation must not mutate its source")
assertFrozen(compiled, "compiled RPC definition")

local encodeRequest = Frame.compile(method.request, "encode")
local decodeRequest = Frame.compile(method.request, "decode")
local requestOk, requestBuffer = encodeRequest(7)
assert(requestOk and buffer.len(requestBuffer) == 5 and buffer.readu16(requestBuffer, 3) == 7,
    "synthetic request record must encode through Frame")
local requestDecoded, requestValue = decodeRequest(requestBuffer)
assert(requestDecoded and requestValue == 7, "synthetic request record must decode through Frame")

local encodeResponse = Frame.compile(method.response, "encode")
local decodeResponse = Frame.compile(method.response, "decode")
local responseOk, responseBuffer = encodeResponse({ owned = true, count = 4 })
assert(responseOk and buffer.len(responseBuffer) == 6, "synthetic response record must encode through Frame")
local responseDecoded, responseValue = decodeResponse(responseBuffer)
assert(responseDecoded and responseValue.owned and responseValue.count == 4,
    "synthetic response record must decode through Frame")

local zeroField, optionalNil = define({
    name = "RpcOnly",
    version = 1,
    events = {},
    requests = {
        None = { id = 1, request = {}, response = { type = "optional", value = { type = "boolean" } } },
        EmptyReply = { id = 2, request = {}, response = { type = "boolean" } },
    },
}, "RPC-only definition")
assert(zeroField.descriptor:find("|N0|Q2", 1, true) ~= nil, "RPC-only descriptor must encode zero events")
assert(zeroField.requests.None.request.minimumEncodedBytes == 3
    and zeroField.requests.None.request.maximumEncodedBytes == 3
    and zeroField.requests.None.request.maximumElements == 0, "zero-field request bounds changed")
local encodeEmpty = Frame.compile(zeroField.requests.EmptyReply.request, "encode")
local decodeEmpty = Frame.compile(zeroField.requests.EmptyReply.request, "decode")
local emptyOk, emptyBuffer = encodeEmpty()
local emptyDecoded = decodeEmpty(emptyBuffer)
assert(emptyOk and buffer.len(emptyBuffer) == 3 and emptyDecoded, "zero-field request must be a codec frame")
local encodeOptional = Frame.compile(zeroField.requests.None.response, "encode")
local decodeOptional = Frame.compile(zeroField.requests.None.response, "decode")
local nilResult = table.pack(encodeOptional(nil))
assert(nilResult.n == 2 and nilResult[1] == true and buffer.len(nilResult[2]) == 4,
    "optional nil response must encode as one root")
local decodedNil = table.pack(decodeOptional(nilResult[2]))
assert(decodedNil.n == 2 and decodedNil[1] == true and decodedNil[2] == nil,
    "optional nil response must retain its root arity")

local eventOnlyShapes = {
    { id = 1, direction = "ClientToServer", fields = {} },
    { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
    { id = 1, direction = "ClientToServer", fields = {
        { name = "value", type = "array", maximumLength = 2, element = { type = "boolean" } },
    } },
}
for index, event in eventOnlyShapes do
    local without = define({ name = "Legacy", version = 1, events = { State = event } }, "legacy descriptor " .. index)
    local withEmpty = define({ name = "Legacy", version = 1, events = { State = event }, requests = {} },
        "empty request map " .. index)
    assert(without.descriptor == withEmpty.descriptor, "empty requests must preserve legacy RR1/RR2/RR3 bytes")
end

local reordered = basicSpec()
reordered.events = { Ping = reordered.events.Ping }
reordered.requests = {
    Other = { id = 11, request = {}, response = { type = "boolean" } },
    Inspect = reordered.requests.Inspect,
}
local orderVariant = basicSpec()
orderVariant.events = { Ping = orderVariant.events.Ping }
orderVariant.requests = {
    Inspect = orderVariant.requests.Inspect,
    Other = { id = 11, request = {}, response = { type = "boolean" } },
}
assert(define(reordered, "first insertion order").descriptor == define(orderVariant, "second insertion order").descriptor,
    "request map insertion order must not affect RR5")

local function descriptorFor(change)
    local value = basicSpec()
    change(value)
    return define(value, "descriptor variant").descriptor
end

for _, change in {
    function(value) value.requests.Other = { id = 11, request = {}, response = { type = "boolean" } } end,
    function(value)
        value.requests.Renamed = value.requests.Inspect
        value.requests.Inspect = nil
    end,
    function(value) value.requests.Inspect.id = 10 end,
    function(value) value.requests.Inspect.request[1].name = "otherId" end,
    function(value) value.requests.Inspect.request[1].maximum = 9 end,
    function(value) value.requests.Inspect.request[1] = { name = "itemId", type = "u8", maximum = 10 } end,
    function(value) value.requests.Inspect.response.fields[2].maximum = 9 end,
    function(value) value.events.Ping.delivery = "Unreliable" end,
} do
    assert(descriptorFor(change) ~= expected, "a changed request or RR5 event shape must change the descriptor")
end

local enumSpec = basicSpec()
enumSpec.requests.Inspect.response = { type = "enum", values = { "|Q", "]", "=" } }
local enumCompiled = define(enumSpec, "enum delimiter response")
assert(enumCompiled.descriptor:find("E3[2:|Q1:]1:=]", 1, true) ~= nil,
    "length-prefixed enum punctuation must remain delimited in RR5")
local changedEnum = basicSpec()
changedEnum.requests.Inspect.response = { type = "enum", values = { "|Q", "]", "==" } }
assert(define(changedEnum, "changed enum delimiter").descriptor ~= enumCompiled.descriptor,
    "length-prefixed delimiter changes must remain distinct")

local orderedArgs = basicSpec()
orderedArgs.requests.Inspect.request = { requestField("first", 10), requestField("second", 20) }
local reversedArgs = basicSpec()
reversedArgs.requests.Inspect.request = { requestField("second", 20), requestField("first", 10) }
assert(define(orderedArgs, "ordered request arguments").descriptor
    ~= define(reversedArgs, "reversed request arguments").descriptor,
    "request argument order must affect RR5")

local copySpec = basicSpec()
local copyCompiled = define(copySpec, "copy source")
local originalDescriptor = copyCompiled.descriptor
copySpec.requests.Inspect.request[1].maximum = 9
copySpec.requests.Inspect.response.fields[2].maximum = 9
local retained = define(basicSpec(), "retained comparison")
assert(originalDescriptor == expected and retained.descriptor == expected and copyCompiled.descriptor == expected
    and copyCompiled.requests.Inspect.request.fields[1].maximum == 10,
    "source mutation after compile must not alter the frozen definition")

local exactByteFields = {}
for index = 1, 8 do
    exactByteFields[index] = { name = "text" .. index, type = "string", maximumBytes = if index == 8 then 961 else 1_024 }
end
local exactByteCompiled = define({
    name = "ByteLimit",
    version = 1,
    events = {},
    requests = { Exact = { id = 1, request = exactByteFields, response = { type = "boolean" } } },
}, "RPC body at byte limit")
assert(exactByteCompiled.requests.Exact.request.maximumEncodedBytes == 8_148,
    "8148-byte codec body must be accepted")
exactByteFields[8].maximumBytes = 962
invalid({ name = "ByteLimit", version = 1, events = {},
    requests = { TooLarge = { id = 1, request = exactByteFields, response = { type = "boolean" } } },
}, "request over byte limit", "requests.TooLarge.request", "8148 bytes")

local tooLargeResponseFields = {}
for index = 1, 8 do
    tooLargeResponseFields[index] = { name = "text" .. index, type = "string", maximumBytes = if index == 8 then 962 else 1_024 }
end
invalid({ name = "ByteLimit", version = 1, events = {}, requests = {
    TooLarge = { id = 1, request = {}, response = { type = "struct", fields = tooLargeResponseFields } },
} }, "response over byte limit", "requests.TooLarge.response", "8148 bytes")

local authoredOverflowFields = {}
for index = 1, 4 do
    local nestedFields = {}
    for fieldIndex = 1, 8 do
        local leafFields = {}
        for leafIndex = 1, 8 do
            leafFields[leafIndex] = { name = "value" .. leafIndex, type = "boolean" }
        end
        nestedFields[fieldIndex] = { name = "branch" .. fieldIndex, type = "array", maximumLength = 0,
            element = { type = "struct", fields = leafFields } }
    end
    authoredOverflowFields[index] = { name = "tree" .. index, type = "struct", fields = nestedFields }
end
invalid({ name = "NodeLimit", version = 1, events = {}, requests = {
    TooMany = { id = 1, request = authoredOverflowFields, response = { type = "boolean" } },
} }, "request authored-node limit", "requests.TooMany.request", "authored node count exceeds 256")

invalid({ name = "ExpandedLimit", version = 1, events = {}, requests = {
    TooMany = { id = 1, request = {}, response = { type = "array", maximumLength = 64,
        element = { type = "struct", fields = {
            { name = "a", type = "boolean" }, { name = "b", type = "boolean" },
            { name = "c", type = "boolean" }, { name = "d", type = "boolean" },
        } } } },
} }, "response expanded-node limit", "requests.TooMany.response", "expanded node count exceeds 256")

local tooManyMethods = {}
for index = 1, 17 do
    tooManyMethods["Method" .. index] = { id = index, request = {}, response = { type = "boolean" } }
end
invalid({ name = "TooMany", version = 1, events = {}, requests = tooManyMethods },
    "more than 16 total endpoints", "requests", "at most 16 endpoints")
invalid({ name = "Collision", version = 1, events = { Ping = {
    id = 1, direction = "ClientToServer", fields = {},
} }, requests = { Query = { id = 1, request = {}, response = { type = "boolean" } } } },
    "event/request ID collision", "requests.Query.id", "duplicate endpoint ID")
invalid({ name = "NoEndpoint", version = 1, events = {}, requests = {} },
    "empty endpoint maps", "events", "at least one endpoint")

local overDescriptor = {}
for methodIndex = 1, 16 do
    local values = {}
    for valueIndex = 1, 32 do
        values[valueIndex] = string.format("v%02d", valueIndex) .. string.rep("x", 29)
    end
    overDescriptor["Method" .. methodIndex] = {
        id = methodIndex,
        request = {},
        response = { type = "enum", values = values },
    }
end
invalid({ name = "Descriptor", version = 1, events = {}, requests = overDescriptor },
    "RPC descriptor over 4096 bytes", "descriptor", "exceeds 4096 bytes")

invalid({ name = "MissingResponse", version = 1, events = {}, requests = {
    Query = { id = 1, request = {} },
} }, "missing response shape", "requests.Query.response", "plain shape table")
invalid({ name = "UnknownKey", version = 1, events = {}, requests = {
    Query = { id = 1, request = {}, response = { type = "boolean" }, delivery = "Unreliable" },
} }, "closed request record", "requests.Query.delivery", "unknown key")
local tooManyArguments = {}
for index = 1, 9 do tooManyArguments[index] = requestField("arg" .. index) end
invalid({ name = "Arity", version = 1, events = {}, requests = {
    Query = { id = 1, request = tooManyArguments, response = { type = "boolean" } },
} }, "more than eight request arguments", "requests.Query.request", "at most 8 entries")
local requestArrayMeta = setmetatable({}, {})
invalid({ name = "Meta", version = 1, events = {}, requests = {
    Query = { id = 1, request = requestArrayMeta, response = { type = "boolean" } },
} }, "request tuple metatable", "requests.Query.request", "dense array")
invalid({ name = "Meta", version = 1, events = {}, requests = {
    Query = { id = 1, request = {}, response = setmetatable({ type = "boolean" }, {}) },
} }, "response shape metatable", "requests.Query.response", "plain shape")

local requestMeta = setmetatable({}, { __index = function() error("must not invoke metatable") end })
invalid({ name = "Meta", version = 1, events = {}, requests = requestMeta }, "request map metatable", "requests", "plain request table")
local methodMetaSpec = { name = "Meta", version = 1, events = {}, requests = {
    Query = setmetatable({ id = 1, request = {}, response = { type = "boolean" } }, {}),
} }
invalid(methodMetaSpec, "request record metatable", "requests.Query", "plain table")

local reportToken = select(2, define(basicSpec(), "inspection source"))
local report = Definition.inspect(reportToken)
local requestReport = report.requests.Inspect
assert(report.protocol == "RR5" and report.limits.endpoints == 16
    and report.limits.rpcEnvelopeBytes == 44 and report.limits.rpcBodyBytes == 8_148
    and report.limits.rpcBufferBytes == 8_192)
assert(requestReport.id == 9 and requestReport.request.fieldCount == 1
    and requestReport.request.bytes.representation == "RelayBuffer"
    and requestReport.request.bytes.minimum == 5 and requestReport.request.bytes.maximum == 5
    and requestReport.request.bytes.limit == 8_148
    and requestReport.response.bytes.minimum == 6 and requestReport.response.bytes.maximum == 6
    and requestReport.response.bytes.limit == 8_148)
assert(requestReport.request.fields == nil and requestReport.response.shape == nil,
    "inspection must not expose payload or compiled shape records")
assertFrozen(report, "RPC inspection report")

for _, code in {
    "RequestLimit", "RequestIdExhausted", "RequestTimeout", "Cancelled", "AlreadyAwaiting",
    "NotYieldable", "HandlerFailure", "InvalidResponse",
} do
    local problem = Definition.error(code)
    assert(problem ~= nil and problem.code == code and countKeys(problem) == 2 and table.isfrozen(problem),
        "RPC diagnostic must be a fixed frozen pair: " .. code)
    assert(Definition.error(code) == problem, "RPC diagnostic records must be reused")
end

print("PASS Relay.ReliableEvents.RpcDefinition")
