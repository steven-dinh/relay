local roblox = require("@lune/roblox")
local Definition = require("../src/Definition")
local NativeRuntime = require("./support/NativeCodec")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local Frame = NativeRuntime.loadFrame()
local world = NativeRuntime.World

local scope = roblox.Instance.new("Folder")
scope.Parent = world
local part = roblox.Instance.new("Part")
part.Parent = scope
local model = roblox.Instance.new("Model")
model.Parent = scope
local secondModel = roblox.Instance.new("Model")
secondModel.Parent = scope
local outside = roblox.Instance.new("Folder")
outside.Parent = world
local outsideModel = roblox.Instance.new("Model")
outsideModel.Parent = outside
local wrongClass = roblox.Instance.new("Folder")
wrongClass.Parent = scope
local detachedRoot = roblox.Instance.new("Folder")
local detachedModel = roblox.Instance.new("Model")
detachedModel.Parent = detachedRoot

local function instance(className)
    return { type = "Instance", className = className }
end

local function field(name, shape)
    shape = table.clone(shape)
    shape.name = name
    return shape
end

local token, definitionError = Definition.define({
    name = "InstanceRuntimeProof",
    version = 1,
    events = {
        Input = { id = 1, direction = "ClientToServer", fields = {
            field("target", instance("BasePart")),
            field("owners", { type = "array", maximumLength = 2, element = instance("Model") }),
        } },
        OptionalInput = { id = 2, direction = "ClientToServer", fields = {
            field("target", { type = "optional", value = instance("BasePart") }),
        } },
        Output = { id = 3, direction = "ServerToClient", fields = {
            field("target", instance("BasePart")),
        } },
        OnceInput = { id = 4, direction = "ClientToServer", fields = {
            field("target", instance("BasePart")),
        } },
        YieldInput = { id = 5, direction = "ClientToServer", fields = {
            field("target", instance("BasePart")),
        } },
    },
})
assert(token, definitionError and definitionError.message)
local compiled = assert(Definition.get(token))

local function encode(event, ...)
    local values = table.pack(Frame.compile(event, "encode")(...))
    assert(values[1] == true, "Instance frame encodes")
    return table.pack(table.unpack(values, 2, values.n))
end

local function copy(value)
    local result = buffer.create(buffer.len(value))
    buffer.copy(result, 0, value, 0, buffer.len(value))
    return result
end

local function options(root, byteCapacity)
    local inboundRate = {
        perPlayer = { capacity = 128, refillPerSecond = 128 },
        aggregate = { capacity = 256, refillPerSecond = 256 },
    }
    if byteCapacity ~= nil then
        inboundRate.bytes = {
            perPlayer = { capacity = byteCapacity, refillPerSecond = 1 },
            aggregate = { capacity = byteCapacity, refillPerSecond = 1 },
        }
    end
    return { inboundRate = inboundRate, instanceRoot = root }
end

local runtime = ServerRuntime.new()
local player, secondPlayer = runtime:addPlayer(), runtime:addPlayer()
local server, createError = runtime.server.create(token, options(nil))
assert(server == nil and createError.code == "InvalidOptions", "reference events require a live scope root")
server, createError = runtime.server.create(token, options(detachedRoot))
assert(server == nil and createError.code == "InvalidOptions", "a detached scope root is rejected")
local plainToken = assert(Definition.define({ name = "NoReferences", version = 1, events = {
    Ping = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "boolean" } } },
} }))
server, createError = runtime.server.create(plainToken, options(scope))
assert(server == nil and createError.code == "InvalidOptions", "a reference root is rejected when unused")

server = assert(runtime.server.create(token, options(scope)))
assert(server:Start())
local remote = runtime:remote()
local referenceContext = runtime.frameContexts[1]
assert(referenceContext ~= nil and referenceContext.server == true and referenceContext.root == scope,
    "immediate event codecs share the server-owned scope context")

local clientRuntime = ClientRuntime.create()
local _, _, clientRemote = clientRuntime:transport(compiled.descriptor, false)
local client = assert(clientRuntime.module.create(token, { startupTimeoutSeconds = 3 }))
assert(client:Start())

local calls, previousOwners = 0, nil
assert(server.events.Input:Connect(function(sender, receivedPart, owners)
    assert(sender == player and receivedPart == part)
    assert(owners[1] == model and owners[2] == secondModel)
    assert(owners ~= previousOwners, "each decode owns its composite reference table")
    previousOwners = owners
    calls += 1
end))

assert(client.events.Input:Send(part, { model, secondModel }))
local sent = clientRuntime.fires[#clientRuntime.fires]
assert(sent[1] == 1 and sent.n == 5 and buffer.readu8(sent[2], 0) == 4
    and buffer.readu8(sent[2], 3) == 3 and sent[3] == part and sent[4] == model
    and sent[5] == secondModel, "references use ordered native varargs and format 4")
remote.OnServerEvent:Fire(player, sent[1], table.unpack(sent, 2, sent.n))
remote.OnServerEvent:Fire(player, sent[1], table.unpack(sent, 2, sent.n))
assert(calls == 2, "repeated references decode and dispatch independently")

local malformedSlot = copy(sent[2])
buffer.writeu8(malformedSlot, 4, 2)
remote.OnServerEvent:Fire(player, 1, malformedSlot, part, model, secondModel)
local malformedCount = copy(sent[2])
buffer.writeu8(malformedCount, 3, 2)
remote.OnServerEvent:Fire(player, 1, malformedCount, part, model, secondModel)
remote.OnServerEvent:Fire(player, 1, sent[2], part, nil, secondModel)
remote.OnServerEvent:Fire(player, 1, sent[2], part, outsideModel, secondModel)
remote.OnServerEvent:Fire(player, 1, sent[2], part, wrongClass, secondModel)
remote.OnServerEvent:Fire(player, 1, sent[2], part, detachedModel, secondModel)
local destroyedModel = roblox.Instance.new("Model")
destroyedModel.Parent = scope
destroyedModel:Destroy()
remote.OnServerEvent:Fire(player, 1, sent[2], part, destroyedModel, secondModel)
assert(calls == 2 and server:GetDiagnostics().events.Input.invalidPayload == 7,
    "bad slot, count, nil, wrong class, out-of-scope, detached, and destroyed refs reject the whole event")

local optionalCalls = 0
assert(server.events.OptionalInput:Connect(function(sender, value)
    assert(sender == player and value == nil)
    optionalCalls += 1
end))
assert(client.events.OptionalInput:Send(nil))
local optionalFrame = clientRuntime.fires[#clientRuntime.fires]
assert(optionalFrame[1] == 2 and optionalFrame.n == 2 and buffer.readu8(optionalFrame[2], 3) == 0,
    "absent optional references consume no sidecar slot")
remote.OnServerEvent:Fire(player, optionalFrame[1], table.unpack(optionalFrame, 2, optionalFrame.n))
assert(optionalCalls == 1)

local onceCalls = 0
local oncePayload = encode(compiled.events.OnceInput, part)
assert(server.events.OnceInput:Once(function(sender, receivedPart)
    assert(sender == player and receivedPart == part)
    onceCalls += 1
    remote.OnServerEvent:Fire(player, 4, table.unpack(oncePayload, 1, oncePayload.n))
end))
remote.OnServerEvent:Fire(player, 4, table.unpack(oncePayload, 1, oncePayload.n))
assert(onceCalls == 1 and server:GetDiagnostics().events.OnceInput.noListener == 1,
    "Once is removed before a reentrant reference event arrives")

runtime.captureThreads = true
local yielded = false
local yieldPayload = encode(compiled.events.YieldInput, part)
assert(server.events.YieldInput:Connect(function(_, receivedPart)
    assert(receivedPart == part)
    coroutine.yield()
    yielded = true
end))
remote.OnServerEvent:Fire(player, 5, table.unpack(yieldPayload, 1, yieldPayload.n))
assert(server:GetDiagnostics().inFlight == 1 and not yielded)
local handlerThread = runtime.threads[#runtime.threads]
assert(coroutine.resume(handlerThread))
assert(yielded and server:GetDiagnostics().inFlight == 0,
    "yielding reference handlers release their reservation after resume")

local outputCalls = 0
assert(client.events.Output:Connect(function(receivedPart)
    assert(receivedPart == part)
    outputCalls += 1
end))
assert(server.events.Output:Send(player, part))
local output = runtime.fires[#runtime.fires].values
assert(output[1] == 3 and output.n == 3 and output[3] == part)
clientRemote.OnClientEvent:fire(table.unpack(output, 1, output.n))
assert(outputCalls == 1, "server-to-client reliable events preserve native Instance sidecars")

local accepted, outputError = server.events.Output:Send(player, outsideModel)
assert(not accepted and outputError.code == "InvalidPayload", "server encoders enforce the configured scope")
scope.Parent = detachedRoot
local detachedRootFires = #runtime.fires
local detachedRootAccepted, detachedRootError = server.events.Output:Send(player, part)
assert(not detachedRootAccepted and detachedRootError.code == "InvalidPayload"
    and #runtime.fires == detachedRootFires, "a scope root reparented outside game is rejected at use time")
scope.Parent = world
local movingPart = roblox.Instance.new("Part")
movingPart.Parent = scope
local validations = runtime.validationCalls
local audienceHandoffs = 0
runtime.afterFire = function(_, endpointId)
    assert(endpointId == 3)
    audienceHandoffs += 1
    if audienceHandoffs == 1 then
        movingPart.Parent = outside
    end
end
local audienceAccepted, audienceError, sentCount = server.events.Output:SendTo({ player, secondPlayer }, movingPart)
assert(not audienceAccepted and audienceError.code == "InvalidPayload" and sentCount == 1
    and runtime.validationCalls == validations + 1,
    "audiences encode once, recheck scope before each handoff, and report partial sends")
assert(server:GetDiagnostics().counters.transportFailures == 0,
    "a scope change between handoffs is a payload rejection, not a transport failure")
runtime.afterFire = nil
movingPart.Parent = scope
local broadcasts = server:GetDiagnostics().counters.broadcastHandoffs
assert(server.events.Output:Broadcast(part))
assert(server:GetDiagnostics().counters.broadcastHandoffs == broadcasts + 1,
    "a reference broadcast uses one FireAllClients handoff")

local references = encode(compiled.events.Input, part, { model, secondModel })
local referenceBytes = buffer.len(references[1]) + 3 * NativeRuntime.InstanceRefs.REFERENCE_BYTES
local byteRuntime = ServerRuntime.new()
local bytePlayer = byteRuntime:addPlayer()
local byteServer = assert(byteRuntime.server.create(token, options(scope, referenceBytes)))
assert(byteServer:Start())
local byteCalls = 0
assert(byteServer.events.Input:Connect(function() byteCalls += 1 end))
byteRuntime:remote().OnServerEvent:Fire(bytePlayer, 1, references[1], part, nil, secondModel)
byteRuntime:remote().OnServerEvent:Fire(bytePlayer, 1, references[1], part, model, secondModel)
local byteCounters = byteServer:GetDiagnostics().counters
assert(byteCalls == 0 and byteCounters.invalidPayload == 1 and byteCounters.perPlayerBytes == 1
    and byteCounters.aggregateBytes == 0,
    "nil sidecars pay the full declared charge before decoder rejection")
byteServer:Destroy()

local exactSingleCost = buffer.len(references[1]) + 3 * NativeRuntime.InstanceRefs.REFERENCE_BYTES
local retainedRuntime = ServerRuntime.new()
local retainedPlayer = retainedRuntime:addPlayer()
local retainedServer = assert(retainedRuntime.server.create(token, options(scope, exactSingleCost)))
assert(retainedServer:Start())
local retainedCalls = 0
assert(retainedServer.events.Input:Connect(function() retainedCalls += 1 end))
local retainedBadSlot = copy(references[1])
buffer.writeu8(retainedBadSlot, 4, 2)
retainedRuntime:remote().OnServerEvent:Fire(retainedPlayer, 1, retainedBadSlot, part, model, secondModel)
retainedRuntime:remote().OnServerEvent:Fire(retainedPlayer, 1, references[1], part, model, secondModel)
local retainedCounters = retainedServer:GetDiagnostics().counters
assert(retainedCalls == 0 and retainedCounters.invalidPayload == 1 and retainedCounters.perPlayerBytes == 1
    and retainedCounters.aggregateBytes == 0,
    "malformed reference frames retain the player byte debit before a later valid event is refused")
retainedServer:Destroy()

local mismatchRuntime = ServerRuntime.new()
local mismatchPlayer = mismatchRuntime:addPlayer()
local mismatchServer = assert(mismatchRuntime.server.create(token, options(scope, exactSingleCost)))
assert(mismatchServer:Start())
local mismatchCalls = 0
assert(mismatchServer.events.Input:Connect(function() mismatchCalls += 1 end))
local mismatchHeader = copy(references[1])
buffer.writeu8(mismatchHeader, 3, 1)
mismatchRuntime:remote().OnServerEvent:Fire(mismatchPlayer, 1, mismatchHeader)
local mismatchCounters = mismatchServer:GetDiagnostics().counters
assert(mismatchCalls == 0 and mismatchCounters.invalidPayload == 0 and mismatchCounters.perPlayerBytes == 1
    and mismatchRuntime.validationCalls == 0,
    "a format4 header declaring sidecars with single-buffer arity is refused before decode")
mismatchServer:Destroy()

local rateRuntime = ServerRuntime.new()
local ratePlayer = rateRuntime:addPlayer()
local rateOptions = options(scope)
rateOptions.inboundRate.perPlayer = { capacity = 2, refillPerSecond = 0.01 }
rateOptions.inboundRate.aggregate = { capacity = 2, refillPerSecond = 0.01 }
rateOptions.inboundRate.endpoints = { [1] = { capacity = 1, refillPerSecond = 0.01 } }
local rateServer = assert(rateRuntime.server.create(token, rateOptions))
assert(rateServer:Start())
local rateCalls = 0
assert(rateServer.events.Input:Connect(function() rateCalls += 1 end))
local rateBadSlot = copy(references[1])
buffer.writeu8(rateBadSlot, 4, 2)
local rateRemote = rateRuntime:remote()
rateRemote.OnServerEvent:Fire(ratePlayer, 1, rateBadSlot, part, model, secondModel)
rateRemote.OnServerEvent:Fire(ratePlayer, 1, rateBadSlot, part, model, secondModel)
rateRemote.OnServerEvent:Fire(ratePlayer, 1, references[1], part, model, secondModel)
local rateCounters = rateServer:GetDiagnostics().counters
assert(rateCalls == 0 and rateCounters.invalidPayload == 1 and rateCounters.endpointRate == 1
    and rateCounters.perPlayerRate == 1 and rateRuntime.validationCalls == 1,
    "malformed references retain shared call and endpoint debits before later admission")
rateServer:Destroy()

local timersBeforeDestroy = runtime:activeTimers()
server:Destroy()
client:Destroy()
assert(referenceContext.root == nil, "Destroy releases the session-owned reference scope")
assert(runtime:activeTimers() == timersBeforeDestroy and timersBeforeDestroy == 0,
    "reliable Instance references create no timers and teardown adds none")
local sendsBeforeDestroy = #runtime.fires
local destroyedSend, destroyedError = server.events.Output:Send(player, part)
assert(not destroyedSend and destroyedError.code == "Destroyed" and #runtime.fires == sendsBeforeDestroy,
    "destroyed sessions cannot hand off retained Instance references")

part:Destroy()
model:Destroy()
secondModel:Destroy()
outsideModel:Destroy()
wrongClass:Destroy()
detachedModel:Destroy()
detachedRoot:Destroy()
scope:Destroy()
outside:Destroy()

print("PASS Relay.Instance.Runtime bounded reliable references and admission")
