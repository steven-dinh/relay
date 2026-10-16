local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local token, problem = Definition.define({
    name = "UnreliableSize",
    version = 1,
    events = {
        Input = { id = 1, direction = "ClientToServer", delivery = "Unreliable", fields = {
            { name = "text", type = "string", maximumBytes = 895 },
        } },
        Output = { id = 2, direction = "ServerToClient", delivery = "Unreliable", fields = {
            { name = "text", type = "string", maximumBytes = 895 },
        } },
    },
})
assert(token ~= nil and problem == nil, tostring(problem and problem.message))

local compiled = Definition.get(token)
local report = Definition.inspect(token)
assert(compiled.descriptor:sub(1, 3) == "RR7" and compiled.events.Input.usesCodec
    and compiled.events.Output.usesCodec,
    "primitive unreliable events must select the codec descriptor and route")
assert(report.events.Input.bytes.representation == "RelayBuffer"
    and report.events.Input.bytes.minimum == 5 and report.events.Input.bytes.maximum == 900
    and report.events.Input.bytes.limit == 900
    and report.events.Input.bytes.robloxEncodedBytes == "Unknown",
    "inspection must report the primitive unreliable RelayBuffer bounds")

local maximum = string.rep("x", 895)
local tooLarge = string.rep("x", 896)
local function encodeEvent(event, ...)
    local result = table.pack(Frame.compile(event, "encode")(...))
    assert(result[1] == true)
    return result[2]
end

-- Client-to-server unreliable sends accept exactly 900 encoded bytes.
do
    local runtime = ClientRuntime.create()
    runtime:transport(compiled.descriptor, true)
    local client = assert(runtime.module.create(token, { startupTimeoutSeconds = 3 }))
    assert(client:Start())
    assert(client.events.Input:Send(maximum))
    assert(#runtime.fires == 1 and runtime.fires[1].n == 2
        and runtime.fires[1][1] == 1 and typeof(runtime.fires[1][2]) == "buffer"
        and buffer.len(runtime.fires[1][2]) == 900,
        "the 895-byte string must encode to one 900-byte unreliable frame")
    local decoded = table.pack(Frame.compile(compiled.events.Input, "decode")(runtime.fires[1][2]))
    assert(decoded.n == 2 and decoded[1] and decoded[2] == maximum)

    local ok, err = client.events.Input:Send(tooLarge)
    assert(not ok and err.code == "InvalidPayload" and table.isfrozen(err)
        and #runtime.fires == 1,
        "a 901-byte unreliable frame must reject before transport handoff")
    client:Destroy()
end

-- Every server route validates before transport, even when its audience is empty.
do
    local runtime = ServerRuntime.new()
    local first, second = runtime:addPlayer(), runtime:addPlayer()
    local server = assert(runtime.server.create(token, { inboundRate = {
        perPlayer = { capacity = 4, refillPerSecond = 1 },
        aggregate = { capacity = 4, refillPerSecond = 1 },
    } }))
    assert(server:Start())
    local output = server.events.Output
    local unreliableRemote = runtime:unreliableRemote()
    local decode = Frame.compile(compiled.events.Output, "decode")

    local function assertNewFrames(start, count)
        assert(#runtime.fires - start == count)
        for index = start + 1, #runtime.fires do
            local handoff = runtime.fires[index]
            assert(handoff.remote == unreliableRemote and handoff.values.n == 2
                and handoff.values[1] == 2 and typeof(handoff.values[2]) == "buffer"
                and buffer.len(handoff.values[2]) == 900)
            local values = table.pack(decode(handoff.values[2]))
            assert(values.n == 2 and values[1] and values[2] == maximum)
        end
    end

    local start = #runtime.fires
    assert(output:Send(first, maximum))
    assertNewFrames(start, 1)
    start = #runtime.fires
    assert(output:Broadcast(maximum))
    assertNewFrames(start, 1)
    start = #runtime.fires
    local ok, err, sent = output:SendTo({ first, second }, maximum)
    assert(ok and err == nil and sent == 2)
    assertNewFrames(start, 2)
    start = #runtime.fires
    ok, err, sent = output:SendExcept({ second }, maximum)
    assert(ok and err == nil and sent == 1)
    assertNewFrames(start, 1)

    start = #runtime.fires
    ok, err, sent = output:SendTo({}, maximum)
    assert(ok and err == nil and sent == 0 and #runtime.fires == start)
    ok, err, sent = output:SendExcept({ first, second }, maximum)
    assert(ok and err == nil and sent == 0 and #runtime.fires == start)

    local invalidRoutes = {
        function() return output:Send(first, tooLarge) end,
        function() return output:Broadcast(tooLarge) end,
        function() return output:SendTo({ first }, tooLarge) end,
        function() return output:SendExcept({ second }, tooLarge) end,
        function() return output:SendTo({}, tooLarge) end,
        function() return output:SendExcept({ first, second }, tooLarge) end,
    }
    for _, route in invalidRoutes do
        local before = #runtime.fires
        local sendOk, sendError, sentCount = route()
        assert(not sendOk and sendError.code == "InvalidPayload" and table.isfrozen(sendError)
            and (sentCount == nil or sentCount == 0) and #runtime.fires == before,
            "901-byte frames must reject on every server route before any handoff")
    end
    server:Destroy()
end

-- A legacy native tuple is charged before its decode fails and cannot reach a handler.
do
    local runtime = ServerRuntime.new()
    local player = runtime:addPlayer()
    local server = assert(runtime.server.create(token, { inboundRate = {
        perPlayer = { capacity = 1, refillPerSecond = 1 },
        aggregate = { capacity = 1, refillPerSecond = 1 },
    } }))
    local handlerCalls = 0
    assert(server.events.Input:Connect(function()
        handlerCalls += 1
    end))
    assert(server:Start())

    local beforeClock, beforeValidation = runtime.clockReads, runtime.validationCalls
    runtime:unreliableRemote().OnServerEvent:Fire(player, 1, maximum)
    assert(runtime.clockReads == beforeClock + 1 and runtime.validationCalls == beforeValidation + 1
        and handlerCalls == 0,
        "legacy tuple ingress must spend admission before rejecting its non-buffer payload")
    local validFrame = encodeEvent(compiled.events.Input, maximum)
    runtime:unreliableRemote().OnServerEvent:Fire(player, 1, validFrame)
    local diagnostics = server:GetDiagnostics()
    assert(runtime.validationCalls == beforeValidation + 1 and handlerCalls == 0
        and diagnostics.counters.invalidPayload == 1 and diagnostics.counters.perPlayerRate == 1
        and diagnostics.events.Input.invalidPayload == 1 and diagnostics.events.Input.dispatched == 0,
        "the malformed legacy tuple must retain its charge and valid traffic must not bypass it")
    server:Destroy()
end

-- Old RR2 descriptors cannot start a client using the RR7 primitive-unreliable codec.
do
    local runtime = ClientRuntime.create()
    local oldDescriptor = compiled.descriptor:gsub("^RR7", "RR2", 1)
    assert(oldDescriptor ~= compiled.descriptor)
    runtime:transport(oldDescriptor, true)
    local client = assert(runtime.module.create(token, { startupTimeoutSeconds = 3 }))
    local ok, err = client:Start()
    assert(not ok and err.code == "DefinitionMismatch" and table.isfrozen(err)
        and #runtime.fires == 0,
        "old descriptor mismatch must fail startup before any event handoff")
    client:Destroy()
end

print("PASS Relay.UnreliableSize primitive frame bounds, session routing, charging, and descriptor compatibility")
