local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local RpcFrame = require("../src/internal/RpcFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")
local NativeRuntime = require("./support/NativeCodec")
local Roblox = require("@lune/roblox")

local spec = { name = "RpcSessionProof", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
    UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
}, requests = {
    False = { id = 3, request = { { name = "value", type = "u8" } }, response = { type = "boolean" } },
    Nil = { id = 4, request = {}, response = { type = "optional", value = { type = "u8" } } },
    Other = { id = 5, request = { { name = "value", type = "u8" } }, response = { type = "u8" } },
    Throw = { id = 6, request = {}, response = { type = "u8" } },
    Multi = { id = 7, request = {}, response = { type = "u8" } },
    Mixed = { id = 16, request = {
        { name = "flag", type = "boolean" },
        { name = "tail", type = "optional", value = { type = "u8" } },
    }, response = { type = "u8" } },
} }
for index = 1, 8 do
    spec.requests[`Method{index}`] = {
        id = 7 + index,
        request = {},
        response = { type = "boolean" },
    }
end
local definition = assert(Definition.define(spec))
local compiled = Definition.get(definition)
local guid = "01234567-89ab-cdef-0123-456789abcdef"
local options = { startupTimeoutSeconds = 3 }

local function serverOptions(playerCapacity, aggregateCapacity)
    return { inboundRate = {
        perPlayer = { capacity = playerCapacity or 4096, refillPerSecond = 1 },
        aggregate = { capacity = aggregateCapacity or 32768, refillPerSecond = 1 },
    } }
end

local function makeRequest(name, callId, sessionGuid, ...)
    local method = compiled.requests[name]
    local encoded = table.pack(Frame.compile(method.request, "encode")(...))
    assert(encoded[1] == true)
    return RpcFrame.wrap(1, method.id, callId, sessionGuid, encoded[2])
end

local function makeReply(name, callId, sessionGuid, kind, value)
    local method = compiled.requests[name]
    local body
    if kind == 2 then
        local encoded = table.pack(Frame.compile(method.response, "encode")(value))
        assert(encoded[1] == true)
        body = encoded[2]
    end
    return RpcFrame.wrap(kind, method.id, callId, sessionGuid, body)
end

local function serverSetup(rateOptions)
    local runtime = ServerRuntime.new()
    local player = runtime:addPlayer()
    local server = assert(runtime.server.create(definition, rateOptions or serverOptions()))
    assert(server:Start())
    return runtime, player, server, runtime:remote()
end

local function clientSetup()
    local runtime = ClientRuntime.create()
    local _, _, remote = runtime:transport(compiled.descriptor, true)
    local client = assert(runtime.module.create(definition, options))
    assert(client:Start())
    return runtime, client, remote
end

local function lastServerReply(runtime, player, expectedKind)
    local fire = runtime.fires[#runtime.fires]
    assert(fire and fire.kind == "target" and fire.player == player)
    assert(fire.values.n == 2 and fire.values[1] == 0)
    local header = RpcFrame.peek(fire.values[2], false)
    assert(header and header.kind == expectedKind)
    return fire.values[2], header
end

local function assertError(expected, value, err)
    assert(value == nil and err and err.code == expected,
        `expected {expected}, got {if err then err.code else "success"}`)
    assert(table.isfrozen(err))
end

local function timerCount(runtime)
    local count = 0
    for _ in runtime.timers do count += 1 end
    return count
end

local function collectForRpcWitness()
    for _ = 1, 64 do
        local garbage = table.create(4_096)
        for index = 1, 4_096 do garbage[index] = { index } end
    end
end

do
    local runtime, player, server, remote = serverSetup()
    local falseCalls, nilCalls, otherCalls, throwCalls, multiCalls, mixedCalls = 0, 0, 0, 0, 0, 0
    server.requests.False:Connect(function(sender, value)
        assert(sender == player and value == 7)
        falseCalls += 1
        return false
    end)
    server.requests.Nil:Connect(function(sender)
        assert(sender == player)
        nilCalls += 1
        return nil
    end)
    server.requests.Other:Connect(function(_, value)
        otherCalls += 1
        return if value == 8 then "wrong type" else value
    end)
    server.requests.Throw:Connect(function()
        throwCalls += 1
        error("private-handler-detail")
    end)
    server.requests.Multi:Connect(function()
        multiCalls += 1
        return 1, 2
    end)
    server.requests.Mixed:Connect(function(sender, ...)
        local flag, tail = ...
        assert(sender == player and select("#", ...) == 2 and flag == false and tail == nil,
            "multi-field RPC preserves false and an explicit trailing nil")
        mixedCalls += 1
        return 9
    end)

    local before = runtime.clockReads
    remote.OnServerEvent:Fire({}, 0, makeRequest("False", 1, guid, 7))
    assert(runtime.clockReads == before and server:GetDiagnostics().counters.ineligible == 1,
        "RPC rejects a non-rostered Player before token clocks")

    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 1, guid, 7))
    local falsePacket, falseHeader = lastServerReply(runtime, player, 2)
    local falseBody = assert(RpcFrame.readBody(falsePacket, falseHeader,
        compiled.requests.False.response.minimumEncodedBytes,
        compiled.requests.False.response.maximumEncodedBytes))
    local validFalse, falseValue = Frame.compile(compiled.requests.False.response, "decode")(falseBody)
    assert(validFalse and falseValue == false and falseCalls == 1)

    remote.OnServerEvent:Fire(player, 0, makeRequest("Nil", 2, guid))
    local nilPacket, nilHeader = lastServerReply(runtime, player, 2)
    local nilBody = assert(RpcFrame.readBody(nilPacket, nilHeader,
        compiled.requests.Nil.response.minimumEncodedBytes,
        compiled.requests.Nil.response.maximumEncodedBytes))
    local validNil, nilValue = Frame.compile(compiled.requests.Nil.response, "decode")(nilBody)
    assert(validNil and nilValue == nil and nilCalls == 1,
        "an explicit nil is one valid optional response root")

    remote.OnServerEvent:Fire(player, 0, makeRequest("Throw", 3, guid))
    local thrown, thrownHeader = lastServerReply(runtime, player, 3)
    assert(buffer.len(thrown) == 44 and thrownHeader.kind == 3 and throwCalls == 1)
    remote.OnServerEvent:Fire(player, 0, makeRequest("Other", 4, guid, 8))
    local invalidType, invalidTypeHeader = lastServerReply(runtime, player, 4)
    assert(buffer.len(invalidType) == 44 and invalidTypeHeader.kind == 4 and otherCalls == 1)
    remote.OnServerEvent:Fire(player, 0, makeRequest("Multi", 5, guid))
    local invalidCount, invalidCountHeader = lastServerReply(runtime, player, 4)
    assert(buffer.len(invalidCount) == 44 and invalidCountHeader.kind == 4 and multiCalls == 1)
    remote.OnServerEvent:Fire(player, 0, makeRequest("Mixed", 50, guid, false, nil))
    local _, mixedHeader = lastServerReply(runtime, player, 2)
    assert(mixedHeader.kind == 2 and mixedCalls == 1)

    local beforeFires = #runtime.fires
    remote.OnServerEvent:Fire(player, 0, makeRequest("Method8", 6, guid))
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 6, guid, 7), "extra")
    remote.OnServerEvent:Fire(player, 0, buffer.create(43))
    local falseRequestOk, falseRequestBody = Frame.compile(compiled.requests.False.request, "encode")(7)
    assert(falseRequestOk)
    remote.OnServerEvent:Fire(player, 0, RpcFrame.wrap(2, 3, 7, guid, falseRequestBody))
    runtime:unreliableRemote().OnServerEvent:Fire(player, 0, makeRequest("False", 8, guid, 7))
    assert(#runtime.fires == beforeFires, "malformed, wrong-kind, and unreliable RPC attempts are silent")
    local diagnostics = server:GetDiagnostics()
    assert(diagnostics.events.False == nil and diagnostics.counters.received == 12
        and diagnostics.counters.invalidPayload >= 3 and diagnostics.counters.wrongChannel == 1
        and diagnostics.counters.noListener == 1,
        "RPC counters are session-only and each eligible attempt is counted once")
    server:Destroy()
end

do
    local runtime, player, server, remote = serverSetup()
    runtime.captureThreads = true
    local falseCalls, otherCalls = 0, 0
    local oldConnection = assert(server.requests.False:Connect(function()
        falseCalls += 1
        coroutine.yield()
        return true
    end))
    server.requests.Other:Connect(function(_, value)
        otherCalls += 1
        return value
    end)
    local packet = makeRequest("False", 20, guid, 3)
    remote.OnServerEvent:Fire(player, 0, packet)
    local handlerThread = runtime.threads[#runtime.threads]
    assert(handlerThread and coroutine.status(handlerThread) == "suspended")
    local replies = #runtime.fires
    remote.OnServerEvent:Fire(player, 0, packet)
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 22, guid, 3))
    local shortBody = buffer.create(3)
    buffer.writeu8(shortBody, 0, 1)
    buffer.writeu16(shortBody, 1, compiled.requests.Other.id)
    local malformedDuplicate = RpcFrame.wrap(1, compiled.requests.Other.id, 20, guid, shortBody)
    oldConnection:Disconnect()
    local replacementCalls = 0
    server.requests.False:Connect(function(_, value)
        replacementCalls += 1
        if value == 1 then
            coroutine.yield()
        end
        return true
    end)
    remote.OnServerEvent:Fire(player, 0, malformedDuplicate)
    assert(falseCalls == 1 and otherCalls == 0 and #runtime.fires == replies,
        "active identities suppress duplicates across methods before decoding or replying")
    assert(coroutine.resume(handlerThread))
    assert(#runtime.fires == replies + 1)
    remote.OnServerEvent:Fire(player, 0, packet)
    assert(falseCalls == 1 and #runtime.fires == replies + 1,
        "the bounded recent replay ring suppresses completed calls")

    local secondPlayer = runtime:addPlayer()
    remote.OnServerEvent:Fire(secondPlayer, 0, packet)
    assert(falseCalls == 1 and replacementCalls == 1,
        "equal identities are independent for each actual Player")

    for callId = 21, 84 do
        remote.OnServerEvent:Fire(player, 0, makeRequest("Other", callId, guid, 1))
    end
    remote.OnServerEvent:Fire(player, 0, packet)
    assert(falseCalls == 1 and replacementCalls == 2,
        "an identity may execute after it leaves the 64-entry replay window")

    local leavingPacket = makeRequest("False", 90, guid, 1)
    remote.OnServerEvent:Fire(player, 0, leavingPacket)
    local leavingThread = runtime.threads[#runtime.threads]
    assert(coroutine.status(leavingThread) == "suspended")
    runtime:removePlayer(player)
    local before = #runtime.fires
    assert(coroutine.resume(leavingThread))
    assert(#runtime.fires == before and server:GetDiagnostics().inFlight == 0,
        "departure clears replay and leases and suppresses the late response")
    remote.OnServerEvent:Fire(secondPlayer, 0, makeRequest("False", 91, guid, 1))
    local destroyThread = runtime.threads[#runtime.threads]
    assert(coroutine.status(destroyThread) == "suspended")
    local beforeDestroy = #runtime.fires
    server:Destroy()
    assert(coroutine.resume(destroyThread))
    assert(#runtime.fires == beforeDestroy and server:GetDiagnostics().inFlight == 0,
        "destroy suppresses late replies and clears active leases")
end

do
    local runtime, player, server, remote = serverSetup(serverOptions(3, 3))
    runtime.captureThreads = true
    local continuationRan, replacementCalls = false, 0
    local oldConnection = assert(server.requests.False:Connect(function()
        coroutine.yield()
        continuationRan = true
        return true
    end))
    local packet = makeRequest("False", 20, guid, 3)
    remote.OnServerEvent:Fire(player, 0, packet)
    local handlerThread = runtime.threads[#runtime.threads]
    assert(handlerThread and coroutine.status(handlerThread) == "suspended")
    local replies = #runtime.fires
    remote.OnServerEvent:Fire(player, 0, packet)
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 21, guid, 3))
    assert(#runtime.fires == replies and server:GetDiagnostics().inFlight == 1)
    assert(coroutine.close(handlerThread) and coroutine.status(handlerThread) == "dead")
    assert(not continuationRan and server:GetDiagnostics().inFlight == 1)
    oldConnection:Disconnect()
    assert(server.requests.False:Connect(function()
        replacementCalls += 1
        return true
    end))
    runtime.now = 1
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 22, guid, 3))
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 23, guid, 3))
    local closedDiagnostics = server:GetDiagnostics()
    assert(replacementCalls == 0 and #runtime.fires == replies and closedDiagnostics.inFlight == 1
        and closedDiagnostics.counters.busy == 3 and closedDiagnostics.counters.perPlayerRate == 1,
        "closed RPC remains active, rejects replacement requests, and charges rejected attempts")
    server:Destroy()
    assert(server:GetDiagnostics().inFlight == 0, "Destroy clears a closed RPC reservation")

    local freshServer = assert(runtime.server.create(definition, serverOptions()))
    assert(freshServer:Start())
    local freshCalls = 0
    assert(freshServer.requests.False:Connect(function() freshCalls += 1; return false end))
    remote = runtime:remote()
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 24, guid, 3))
    assert(freshCalls == 1 and freshServer:GetDiagnostics().inFlight == 0,
        "a fresh server session can handle a request after Destroy")
    freshServer:Destroy()
end

do
    local runtime, firstPlayer, server, remote = serverSetup()
    runtime.captureThreads = true
    server.events.Input:Connect(function()
        coroutine.yield()
    end)
    for name, method in compiled.requests do
        local responseType = method.response.fields[1].type
        server.requests[name]:Connect(function()
            coroutine.yield()
            if responseType == "boolean" then
                return false
            elseif responseType == "optional" then
                return nil
            end
            return 1
        end)
    end

    remote.OnServerEvent:Fire(firstPlayer, 1, 1)
    local firstMethods = { "False", "Nil", "Other", "Throw", "Multi", "Method1", "Method2" }
    local function send(player, name)
        local method = compiled.requests[name]
        local callId = 100 + method.id
        if name == "False" or name == "Other" then
            remote.OnServerEvent:Fire(player, 0, makeRequest(name, callId, guid, 1))
        else
            remote.OnServerEvent:Fire(player, 0, makeRequest(name, callId, guid))
        end
    end
    for _, name in firstMethods do send(firstPlayer, name) end
    send(firstPlayer, "Method3")
    local playerDiagnostics = server:GetDiagnostics()
    assert(playerDiagnostics.inFlight == 8 and playerDiagnostics.counters.busy == 1,
        "one yielding event and seven requests share the eight-call Player lease cap")

    local allMethods = { "False", "Nil", "Other", "Throw", "Multi", "Method1", "Method2", "Method3" }
    for _ = 1, 7 do
        local player = runtime:addPlayer()
        for _, name in allMethods do send(player, name) end
    end
    local finalPlayer = runtime:addPlayer()
    send(finalPlayer, "Method4")
    local sessionDiagnostics = server:GetDiagnostics()
    assert(sessionDiagnostics.inFlight == 64 and sessionDiagnostics.counters.busy == 2,
        "all Player event and RPC invocations share the 64-call session lease cap")
    local beforeDestroy = #runtime.fires
    server:Destroy()
    for _, thread in runtime.threads do
        if coroutine.status(thread) == "suspended" then
            assert(coroutine.resume(thread))
        end
    end
    assert(#runtime.fires == beforeDestroy and server:GetDiagnostics().inFlight == 0,
        "destroy clears shared leases and suppresses every late RPC response")
end

do
    local runtime, player, server, remote = serverSetup(serverOptions(2, 2))
    local eventCalls = 0
    server.events.Input:Connect(function(_, value)
        eventCalls += value
    end)
    local malformed = buffer.create(43)
    remote.OnServerEvent:Fire(player, 0, malformed)
    remote.OnServerEvent:Fire(player, 1, 1)
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 1, guid, 1))
    assert(eventCalls == 1)
    local diagnostics = server:GetDiagnostics().counters
    assert(diagnostics.invalidPayload == 1 and diagnostics.perPlayerRate == 1
        and diagnostics.aggregateRate == 0,
        "event and RPC ingress share player-first token buckets")
    local secondPlayer = runtime:addPlayer()
    remote.OnServerEvent:Fire(secondPlayer, 0, makeRequest("False", 2, guid, 1))
    diagnostics = server:GetDiagnostics().counters
    assert(diagnostics.aggregateRate == 1,
        "aggregate exhaustion follows the per-Player debit without refund")
    server:Destroy()
end

do
    local eventOnly = assert(Definition.define({ name = "EventOnlyGuidProof", version = 1, events = {
        State = { id = 1, direction = "ServerToClient", fields = {} },
    } }))
    local eventOnlyRuntime = ClientRuntime.create()
    eventOnlyRuntime:transport(Definition.get(eventOnly).descriptor, false)
    local eventOnlyClient = assert(eventOnlyRuntime.module.create(eventOnly, options))
    assert(eventOnlyClient:Start() and eventOnlyRuntime.guidCalls == 0,
        "event-only sessions do not generate an RPC GUID")
    eventOnlyClient:Destroy()

    local runtime, client, remote = clientSetup()
    assert(runtime.guidCalls == 1, "RPC sessions mint one GUID")
    local initialTimers = timerCount(runtime)
    assertError("InvalidOptions", client.requests.False:Request(0, 7))
    assertError("InvalidPayload", client.requests.False:Request(1, "bad"))
    assert(timerCount(runtime) == initialTimers and #runtime.fires == 0,
        "local rejection does not reserve a timer or transport handoff")

    local pending = assert(client.requests.False:Request(5, 7))
    assert(runtime.fires[1][1] == 0 and runtime.fires[1][2] ~= nil)
    local requestHeader = RpcFrame.peek(runtime.fires[1][2], true)
    assert(requestHeader and requestHeader.kind == 1 and requestHeader.callId == 1
        and requestHeader.methodId == compiled.requests.False.id
        and requestHeader.sessionGuid == "abcdefab-cdef-4000-8000-000000000001")
    local second, secondError = client.requests.False:Request(5, 7)
    assert(second == nil and secondError.code == "RequestLimit" and timerCount(runtime) == 1,
        "one pending request per method, with no timer on rejection")
    runtime.forceNonYieldable = true
    local notYieldable = pending:Await()
    runtime.forceNonYieldable = false
    assert(notYieldable.ok == false and notYieldable.error.code == "NotYieldable")
    remote.OnClientEvent:fire(0, makeReply("False", 1, requestHeader.sessionGuid, 2, false))
    local result = pending:Await()
    assert(result.ok and result.value == false)

    local nilPending = assert(client.requests.Nil:Request(5))
    local nilHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    remote.OnClientEvent:fire(0, makeReply("Nil", nilHeader.callId, nilHeader.sessionGuid, 2, nil))
    local nilResult = nilPending:Await()
    assert(nilResult.ok and nilResult.value == nil)

    local reentrantRuntime, reentrantClient, reentrantRemote = clientSetup()
    reentrantRuntime.onFire = function(_, endpointId, packet)
        local header = RpcFrame.peek(packet, true)
        assert(endpointId == 0 and header ~= nil)
        reentrantRemote.OnClientEvent:fire(0, makeReply("False", header.callId,
            header.sessionGuid, 2, true))
    end
    local reentrant = assert(reentrantClient.requests.False:Request(5, 7))
    assert(reentrant:Await().ok and reentrant:Await().value == true,
        "pending ownership is installed before a reentrant response can arrive")
    reentrantClient:Destroy()

    local failurePending = assert(client.requests.Other:Request(5, 4))
    local failureHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    remote.OnClientEvent:fire(0, makeReply("Other", failureHeader.callId,
        failureHeader.sessionGuid, 3))
    assert(failurePending:Await().error.code == "HandlerFailure")

    local invalidPending = assert(client.requests.Other:Request(5, 4))
    local invalidHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    remote.OnClientEvent:fire(0, makeReply("Other", invalidHeader.callId,
        invalidHeader.sessionGuid, 4))
    assert(invalidPending:Await().error.code == "InvalidResponse")

    local mismatched = assert(client.requests.False:Request(5, 7))
    local mismatchHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    remote.OnClientEvent:fire(0, makeReply("Other", mismatchHeader.callId,
        mismatchHeader.sessionGuid, 2, 3))
    remote.OnClientEvent:fire(0, makeReply("False", mismatchHeader.callId,
        "11234567-89ab-cdef-0123-456789abcdef", 2, true))
    remote.OnClientEvent:fire(0, makeRequest("False", mismatchHeader.callId,
        mismatchHeader.sessionGuid, 7))
    runtime.forceNonYieldable = true
    assert(mismatched:Await().error.code == "NotYieldable",
        "cross-method and cross-session replies leave the matching call pending")
    runtime.forceNonYieldable = false
    remote.OnClientEvent:fire(0, makeReply("False", mismatchHeader.callId,
        mismatchHeader.sessionGuid, 2, true))
    assert(mismatched:Await().ok and mismatched:Await().value == true)

    local malformedResponse = assert(client.requests.Other:Request(5, 4))
    local malformedResponseHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    local shortResponseBody = buffer.create(3)
    buffer.writeu8(shortResponseBody, 0, 1)
    buffer.writeu16(shortResponseBody, 1, compiled.requests.Other.id)
    remote.OnClientEvent:fire(0, RpcFrame.wrap(2, compiled.requests.Other.id,
        malformedResponseHeader.callId, malformedResponseHeader.sessionGuid, shortResponseBody))
    runtime.forceNonYieldable = true
    assert(malformedResponse:Await().error.code == "NotYieldable",
        "a malformed legacy response leaves the pending call unsettled")
    runtime.forceNonYieldable = false
    remote.OnClientEvent:fire(0, makeReply("Other", malformedResponseHeader.callId,
        malformedResponseHeader.sessionGuid, 2, 4))
    assert(malformedResponse:Await().ok and malformedResponse:Await().value == 4)

    local waiting = assert(client.requests.False:Request(1, 7))
    local waiterResult
    local waiter = coroutine.create(function() waiterResult = waiting:Await() end)
    assert(coroutine.resume(waiter) and coroutine.status(waiter) == "suspended")
    local already = waiting:Await()
    assert(already.error.code == "AlreadyAwaiting")
    runtime:advance(1)
    assert(coroutine.status(waiter) == "dead" and waiterResult.error.code == "RequestTimeout")
    local afterTimer = waiting:Await()
    assert(afterTimer.error.code == "RequestTimeout")

    local foreignResume = assert(client.requests.False:Request(5, 7))
    local foreignResumeHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    local foreignResumeResult
    local foreignResumeReturned = false
    local foreignWaiter = coroutine.create(function()
        foreignResumeResult = foreignResume:Await()
        foreignResumeReturned = true
    end)
    assert(coroutine.resume(foreignWaiter) and coroutine.status(foreignWaiter) == "suspended")
    assert(coroutine.resume(foreignWaiter) and coroutine.status(foreignWaiter) == "suspended"
        and not foreignResumeReturned,
        "an unrelated resume keeps Await pending")
    local spawnedBeforeWake = #runtime.spawnedThreads
    remote.OnClientEvent:fire(0, makeReply("False", foreignResumeHeader.callId,
        foreignResumeHeader.sessionGuid, 2, true))
    runtime:flush()
    assert(coroutine.status(foreignWaiter) == "dead" and foreignResumeReturned
        and foreignResumeResult.ok and foreignResumeResult.value == true,
        "the active waiter returns its response after an unrelated resume")
    assert(#runtime.spawnedThreads == spawnedBeforeWake + 1
        and runtime.spawnedThreads[#runtime.spawnedThreads] == foreignWaiter,
        "a matching suspended waiter wakes exactly once through task.spawn(thread)")

    local resumedBeforeWake = assert(client.requests.False:Request(5, 7))
    local resumedHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    local resumedResult
    local reachedApplicationYield = false
    local resumedApplication = false
    local resumedWaiter = coroutine.create(function()
        resumedResult = resumedBeforeWake:Await()
        reachedApplicationYield = true
        coroutine.yield("application continuation")
        resumedApplication = true
    end)
    assert(coroutine.resume(resumedWaiter) and coroutine.status(resumedWaiter) == "suspended")
    local spawnedBeforeStaleWake = #runtime.spawnedThreads
    remote.OnClientEvent:fire(0, makeReply("False", resumedHeader.callId,
        resumedHeader.sessionGuid, 2, false))
    assert(#runtime.pending > 0, "settlement queues the deferred waiter wake")
    local externallyResumed, yieldedValue = coroutine.resume(resumedWaiter)
    assert(externallyResumed and yieldedValue == "application continuation"
        and coroutine.status(resumedWaiter) == "suspended" and reachedApplicationYield
        and resumedResult.ok and resumedResult.value == false,
        "an external resume can leave Await only after its result settles")
    runtime:flush()
    assert(coroutine.status(resumedWaiter) == "suspended" and not resumedApplication,
        "the deferred wake cannot resume an unrelated application continuation")
    assert(#runtime.spawnedThreads == spawnedBeforeStaleWake,
        "a stale waiter token is not scheduled")
    assert(coroutine.resume(resumedWaiter) and coroutine.status(resumedWaiter) == "dead"
        and resumedApplication, "the unrelated continuation remains owned by its caller")

    -- Keep the closed thread in its creator frame so its dead stack slot cannot mask GC.
    local function closeWaiterBeforeDeferredWake()
        local closedHandle = assert(client.requests.False:Request(5, 7))
        local closedHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
        local closedWaiter = coroutine.create(function() closedHandle:Await() end)
        local closedWaiterWitness = setmetatable({ closedWaiter }, { __mode = "v" })
        assert(coroutine.resume(closedWaiter) and coroutine.status(closedWaiter) == "suspended")
        local spawnedBeforeClosedWake = #runtime.spawnedThreads
        remote.OnClientEvent:fire(0, makeReply("False", closedHeader.callId,
            closedHeader.sessionGuid, 2, true))
        assert(#runtime.pending > 0, "settlement queues the closeable waiter wake")
        assert(coroutine.close(closedWaiter), "the suspended waiter can be closed before its wake")
        closedWaiter = nil
        runtime:flush()
        assert(#runtime.spawnedThreads == spawnedBeforeClosedWake,
            "a closed waiter is cleared without scheduling")
        return closedHandle, closedWaiterWitness
    end
    local closedHandle, closedWaiterWitness = closeWaiterBeforeDeferredWake()
    collectForRpcWitness()
    assert(closedWaiterWitness[1] == nil,
        "a settled handle must not retain a waiter coroutine closed before deferred wake")
    assert(closedHandle:Await().ok and closedHandle:Await().value == true,
        "clearing a closed waiter preserves the settled result")

    local delayedExpiration = assert(client.requests.False:Request(1, 7))
    local delayedExpirationHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    local delayedWaiterResult
    local delayedWaiter = coroutine.create(function()
        delayedWaiterResult = delayedExpiration:Await()
    end)
    assert(coroutine.resume(delayedWaiter) and coroutine.status(delayedWaiter) == "suspended")
    runtime.ignoreTimerCancel = true
    runtime.pausedTimers = true
    runtime:advance(2)
    remote.OnClientEvent:fire(0, makeReply("False", delayedExpirationHeader.callId,
        delayedExpirationHeader.sessionGuid, 2, true))
    runtime:flush()
    assert(coroutine.status(delayedWaiter) == "dead"
        and delayedWaiterResult.error.code == "RequestTimeout",
        "an expired reply settles the deadline even while its timer is postponed")
    local postponedTimers = runtime:collectTimers()
    runtime:resumeTimers(postponedTimers)
    runtime.ignoreTimerCancel = false
    runtime.pausedTimers = false
    assert(delayedExpiration:Await().error.code == "RequestTimeout")
    local afterDelayedExpiration = assert(client.requests.False:Request(5, 7))
    afterDelayedExpiration:Cancel()

    local cancelled = assert(client.requests.False:Request(5, 7))
    cancelled:Cancel()
    cancelled:Cancel()
    assert(cancelled:Await().error.code == "Cancelled")
    local cancelledHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    remote.OnClientEvent:fire(0, makeReply("False", cancelledHeader.callId,
        cancelledHeader.sessionGuid, 2, true))
    assert(cancelled:Await().error.code == "Cancelled", "late replies cannot change a settled call")

    local expireOnDecode = assert(client.requests.False:Request(1, 7))
    local decodeHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    local clockReads = runtime.clockReads
    runtime.clockHook = function(target, read)
        if read == clockReads + 2 then target.now = 100 end
    end
    remote.OnClientEvent:fire(0, makeReply("False", decodeHeader.callId,
        decodeHeader.sessionGuid, 2, true))
    runtime.clockHook = nil
    assert(expireOnDecode:Await().error.code == "RequestTimeout",
        "a success whose decode crosses the absolute deadline becomes a timeout")

    local delayed = assert(client.requests.False:Request(2, 7))
    local delayedHeader = RpcFrame.peek(runtime.fires[#runtime.fires][2], true)
    local dueTimers = runtime:collectTimers()
    runtime.ignoreTimerCancel = true
    remote.OnClientEvent:fire(0, makeReply("False", delayedHeader.callId,
        delayedHeader.sessionGuid, 2, false))
    assert(delayed:Await().ok and delayed:Await().value == false)
    runtime:resumeTimers(dueTimers)
    runtime.ignoreTimerCancel = false
    assert(delayed:Await().ok and delayed:Await().value == false,
        "a delayed timer cannot replace a timely response")
    local fireFailureRuntime, fireFailureClient = clientSetup()
    fireFailureRuntime.failFire = true
    assertError("TransportFailure", fireFailureClient.requests.False:Request(5, 7))
    fireFailureRuntime.failFire = false
    local afterFailure = assert(fireFailureClient.requests.False:Request(5, 7))
    local afterFailureHeader = RpcFrame.peek(fireFailureRuntime.fires[#fireFailureRuntime.fires][2], true)
    assert(afterFailureHeader.callId == 2, "transport failure consumes the reserved request ID")
    afterFailure:Cancel()

    local budgetRuntime, budgetClient, budgetRemote = clientSetup()
    local handles = {}
    for index = 1, 8 do
        handles[index] = assert(budgetClient.requests[`Method{index}`]:Request(60))
    end
    local countBeforeLimit = #budgetRuntime.fires
    local timersBeforeLimit = timerCount(budgetRuntime)
    assertError("RequestLimit", budgetClient.requests.Mixed:Request(60))
    assert(#budgetRuntime.fires == countBeforeLimit and timerCount(budgetRuntime) == timersBeforeLimit
        and budgetRemote ~= nil)
    budgetClient:Destroy()
    for _, handle in handles do
        assert(handle:Await().error.code == "Destroyed")
    end

    local destroyed = assert(client.requests.False:Request(5, 7))
    client:Destroy()
    assert(destroyed:Await().error.code == "Destroyed")
    runtime, client, remote = clientSetup()
    local disconnected = assert(client.requests.False:Request(5, 7))
    remote:Destroy()
    assert(disconnected:Await().error.code == "Disconnected")
end

do
    local events = {}
    for id = 1, 62 do
        events[`Event{id}`] = {
            id = id,
            direction = "ClientToServer",
            fields = { { name = "value", type = "u8" } },
        }
    end
    local maximum = assert(Definition.define({
        name = "MaximumMixedRouting",
        version = 1,
        events = events,
        requests = {
            HighRequest = { id = 63, request = {}, response = { type = "boolean" } },
            HighestRequest = {
                id = 64,
                request = { { name = "value", type = "u8" } },
                response = { type = "u8" },
            },
        },
    }))
    local maximumCompiled = Definition.get(maximum)
    assert(maximumCompiled.events.Event62.id == 62 and maximumCompiled.requests.HighestRequest.id == 64,
        "the 64-endpoint definition keeps its highest event and request IDs")

    local runtime = ServerRuntime.new()
    local player = runtime:addPlayer()
    local server = assert(runtime.server.create(maximum, serverOptions(4, 4)))
    assert(server:Start())
    local remote = runtime:remote()
    local eventCalls, requestCalls = 0, 0
    assert(server.events.Event62:Connect(function(_, value) eventCalls += value end))
    assert(server.requests.HighestRequest:Connect(function(_, value)
        requestCalls += 1
        return value
    end))

    remote.OnServerEvent:Fire(player, 62, 7)
    local requestOk, requestBody = Frame.compile(maximumCompiled.requests.HighestRequest.request, "encode")(9)
    assert(requestOk)
    remote.OnServerEvent:Fire(player, 0, RpcFrame.wrap(1, 64, 1, guid, requestBody))
    local replyFire = runtime.fires[#runtime.fires]
    local reply = assert(RpcFrame.peek(replyFire.values[2], false))
    assert(reply.methodId == 64 and reply.callId == 1 and reply.sessionGuid == guid)
    local replyBody = assert(RpcFrame.readBody(replyFire.values[2], reply,
        maximumCompiled.requests.HighestRequest.response.minimumEncodedBytes,
        maximumCompiled.requests.HighestRequest.response.maximumEncodedBytes))
    local responseOk, responseValue = Frame.compile(maximumCompiled.requests.HighestRequest.response, "decode")(
        replyBody)
    assert(responseOk and responseValue == 9 and eventCalls == 7 and requestCalls == 1,
        "the highest event and request route with the 64-endpoint limit")

    remote.OnServerEvent:Fire(player, 62, "bad")
    remote.OnServerEvent:Fire(player, 0, RpcFrame.wrap(1, 64, 2, guid, buffer.create(0)))
    local diagnostics = server:GetDiagnostics().counters
    assert(eventCalls == 7 and requestCalls == 1 and diagnostics.invalidPayload == 2,
        "invalid highest-endpoint payloads are rejected before handlers")
    remote.OnServerEvent:Fire(player, 62, 1)
    local secondPlayer = runtime:addPlayer()
    remote.OnServerEvent:Fire(secondPlayer, 62, 1)
    diagnostics = server:GetDiagnostics().counters
    assert(eventCalls == 7 and diagnostics.perPlayerRate == 1 and diagnostics.aggregateRate == 1,
        "invalid payloads retain player and aggregate admission charges at the endpoint limit")
    server:Destroy()
end

do
    local directionDefinition = assert(Definition.define({ name = "RpcDirectionProof", version = 1,
        events = {}, requests = {
            Ask = { id = 1, direction = "ServerToClient", concurrency = 2, refusals = true,
                request = { { name = "value", type = "u8" } }, response = { type = "boolean" } },
            Many = { id = 5, direction = "ServerToClient", concurrency = 8,
                request = { { name = "value", type = "u8" } }, response = { type = "boolean" } },
            NoListener = { id = 2, direction = "ServerToClient", refusals = true,
                request = { { name = "value", type = "boolean" } }, response = { type = "boolean" } },
            NilAsk = { id = 3, direction = "ServerToClient",
                request = {}, response = { type = "optional", value = { type = "u8" } } },
            Lookup = { id = 4, direction = "ServerToClient",
                request = { { name = "item", type = "Instance", className = "Part" } },
                response = { type = "Instance", className = "Part" } },
            ClientLookup = { id = 6,
                request = { { name = "item", type = "Instance", className = "Part" } },
                response = { type = "Instance", className = "Part" } },
        } }))
    local directionCompiled = Definition.get(directionDefinition)
    local serverRuntime = ServerRuntime.new()
    local player = serverRuntime:addPlayer()
    local settings = serverOptions()
    settings.instanceRoot = NativeRuntime.World
    local server = assert(serverRuntime.server.create(directionDefinition, settings))
    assert(server:Start() and serverRuntime.guidCalls == 1,
        "server RPC callers generate their own GUID without readiness")
    local remote = serverRuntime:remote()

    local clientRuntime = ClientRuntime.create()
    local _, _, clientRemote = clientRuntime:transport(directionCompiled.descriptor, false)
    local client = assert(clientRuntime.module.create(directionDefinition, options))
    assert(client:Start())
    local askCalls = 0
    assert(client.requests.Ask:Connect(function(value)
        assert(value == 42)
        askCalls += 1
        return false
    end))
    assert(client.requests.NilAsk:Connect(function() return nil end))
    local requestPart = Roblox.Instance.new("Part")
    local responsePart = Roblox.Instance.new("Part")
    requestPart.Parent = NativeRuntime.World
    responsePart.Parent = NativeRuntime.World
    assert(client.requests.Lookup:Connect(function(item)
        assert(item == requestPart)
        return responsePart
    end))
    assert(server.requests.ClientLookup:Connect(function(sender, item)
        assert(sender == player and item == requestPart)
        return responsePart
    end))

    local pending = assert(server.requests.Ask:Request(player, 5, 42))
    local askFire = serverRuntime.fires[#serverRuntime.fires]
    local askPacket = askFire.values[2]
    local askHeader = assert(RpcFrame.peek(askPacket, false, false, 0))
    assert(askFire.values.n == 2 and askHeader.kind == 1 and askHeader.envelopeVersion == 2
        and askHeader.sessionGuid ~= guid)
    local waiterResult
    local waiter = coroutine.create(function() waiterResult = pending:Await() end)
    assert(coroutine.resume(waiter) and coroutine.status(waiter) == "suspended")
    clientRemote.OnClientEvent:fire(0, askPacket)
    assert(askCalls == 1 and clientRuntime.fires[1].n == 2)
    local clientReply = clientRuntime.fires[1]
    remote.OnServerEvent:Fire(player, table.unpack(clientReply, 1, clientReply.n))
    serverRuntime:flush()
    assert(coroutine.status(waiter) == "dead" and waiterResult.ok and waiterResult.value == false
        and pending:Await().value == false,
        "server-to-client RPC preserves false and resumes one waiter after map cleanup")

    local nilPending = assert(server.requests.NilAsk:Request(player, 5))
    local nilPacket = serverRuntime.fires[#serverRuntime.fires].values[2]
    clientRemote.OnClientEvent:fire(0, nilPacket)
    local nilReply = clientRuntime.fires[#clientRuntime.fires]
    remote.OnServerEvent:Fire(player, table.unpack(nilReply, 1, nilReply.n))
    local nilResult = nilPending:Await()
    assert(nilResult.ok and nilResult.value == nil,
        "server-to-client RPC preserves one explicit nil response")

    local lookupPending = assert(server.requests.Lookup:Request(player, 5, requestPart))
    local lookupFire = serverRuntime.fires[#serverRuntime.fires]
    local lookupPacket = lookupFire.values[2]
    assert(lookupFire.values.n == 3 and lookupFire.values[3] == requestPart
        and buffer.readu8(lookupPacket, 0) == RpcFrame.V2_WIRE_TAG,
        "RPC request carries the bounded native Instance sidecar")
    clientRemote.OnClientEvent:fire(0, lookupPacket, lookupFire.values[3])
    local lookupReply = clientRuntime.fires[#clientRuntime.fires]
    assert(lookupReply.n == 3 and lookupReply[3] == responsePart,
        "RPC response carries the bounded native Instance sidecar")
    remote.OnServerEvent:Fire(player, table.unpack(lookupReply, 1, lookupReply.n))
    assert(lookupPending:Await().value == responsePart,
        "typed Instance request and response values survive the full RPC route")

    local clientLookupPending = assert(client.requests.ClientLookup:Request(5, requestPart))
    local clientLookupFire = clientRuntime.fires[#clientRuntime.fires]
    assert(clientLookupFire.n == 3 and clientLookupFire[3] == requestPart,
        "client-to-server RPC request carries its bounded Instance sidecar")
    remote.OnServerEvent:Fire(player, table.unpack(clientLookupFire, 1, clientLookupFire.n))
    local serverReply = serverRuntime.fires[#serverRuntime.fires]
    assert(serverReply.values.n == 3 and serverReply.values[3] == responsePart,
        "client-to-server RPC response carries its bounded Instance sidecar")
    clientRemote.OnClientEvent:fire(0, serverReply.values[2], serverReply.values[3])
    assert(clientLookupPending:Await().value == responsePart,
        "typed client-to-server Instance request and response values survive the full RPC route")

    local v2MalformedPending = assert(client.requests.ClientLookup:Request(5, requestPart))
    local v2Request = RpcFrame.peek(clientRuntime.fires[#clientRuntime.fires][2], true, false, 1)
    local validInstanceHeader = assert(RpcFrame.peek(serverReply.values[2], false, false, 1))
    local encodedInstanceResponse = assert(RpcFrame.readBody(serverReply.values[2], validInstanceHeader,
        directionCompiled.requests.ClientLookup.response.minimumEncodedBytes,
        directionCompiled.requests.ClientLookup.response.maximumEncodedBytes,
        directionCompiled.requests.ClientLookup.response.maximumAdmissionBytes,
        directionCompiled.requests.ClientLookup.response.maximumReferences, 1))
    assert(v2Request)
    local malformedInstanceResponse = assert(RpcFrame.wrap(2, directionCompiled.requests.ClientLookup.id,
        v2Request.callId, v2Request.sessionGuid, encodedInstanceResponse, false, 2, 1))
    local outOfScopePart = Roblox.Instance.new("Part")
    clientRemote.OnClientEvent:fire(0, malformedInstanceResponse, outOfScopePart)
    assert(v2MalformedPending:Await().error.code == "InvalidResponse",
        "a matching malformed v2 response settles without changing v1 pending semantics")

    local noListenerResponses = #clientRuntime.fires
    for index = 1, 7 do
        local noListenerPending = assert(server.requests.NoListener:Request(player, 5, true))
        local noListenerPacket = serverRuntime.fires[#serverRuntime.fires].values[2]
        clientRemote.OnClientEvent:fire(0, noListenerPacket)
        assert(#clientRuntime.fires == noListenerResponses + 1)
        noListenerResponses += 1
        local noListenerReply = clientRuntime.fires[#clientRuntime.fires]
        local refusalHeader = assert(RpcFrame.peek(noListenerReply[2], false, true, 0))
        assert(refusalHeader.kind == 7, "typed no-listener refusal uses its fixed bounded kind")
        remote.OnServerEvent:Fire(player, table.unpack(noListenerReply, 1, noListenerReply.n))
        assert(noListenerPending:Await().error.code == "NoListener")
    end
    local malformedPending = assert(server.requests.NoListener:Request(player, 5, true))
    local malformedPacket = serverRuntime.fires[#serverRuntime.fires].values[2]
    buffer.writeu8(malformedPacket, RpcFrame.ENVELOPE_BYTES + 3, 2)
    clientRemote.OnClientEvent:fire(0, malformedPacket)
    assert(#clientRuntime.fires == noListenerResponses,
        "malformed refusal candidate gets no reflective reply")
    malformedPending:Cancel()
    local droppedPending = assert(server.requests.NoListener:Request(player, 5, true))
    local droppedPacket = serverRuntime.fires[#serverRuntime.fires].values[2]
    clientRemote.OnClientEvent:fire(0, droppedPacket)
    assert(#clientRuntime.fires == noListenerResponses,
        "deep malformed refusal validation retains its work token")
    droppedPending:Cancel()

    local malformedResponsePending = assert(server.requests.Ask:Request(player, 5, 1))
    local malformedRequestHeader = assert(RpcFrame.peek(
        serverRuntime.fires[#serverRuntime.fires].values[2], false, false, 0))
    local malformedResponseBody = table.pack(Frame.compile(directionCompiled.requests.Ask.response, "encode")(true))
    assert(malformedResponseBody[1])
    buffer.writeu8(malformedResponseBody[2], 3, 2)
    local malformedResponsePacket = assert(RpcFrame.wrap(2, directionCompiled.requests.Ask.id,
        malformedRequestHeader.callId, malformedRequestHeader.sessionGuid, malformedResponseBody[2], false, 2))
    remote.OnServerEvent:Fire(player, 0, malformedResponsePacket)
    assert(malformedResponsePending:Await().error.code == "InvalidResponse")
    local invalidBeforeDuplicate = server:GetDiagnostics().counters.invalidPayload
    remote.OnServerEvent:Fire(player, 0, malformedResponsePacket)
    assert(server:GetDiagnostics().counters.invalidPayload == invalidBeforeDuplicate,
        "first matching malformed response settles and releases the pending identity")

    local wrongPlayer = serverRuntime:addPlayer()
    local correlatedPending = assert(server.requests.Ask:Request(player, 5, 2))
    local correlatedHeader = assert(RpcFrame.peek(serverRuntime.fires[#serverRuntime.fires].values[2],
        false, false, 0))
    local validResponse = table.pack(Frame.compile(directionCompiled.requests.Ask.response, "encode")(true))
    local validResponsePacket = assert(RpcFrame.wrap(2, directionCompiled.requests.Ask.id,
        correlatedHeader.callId, correlatedHeader.sessionGuid, validResponse[2], false, 2))
    remote.OnServerEvent:Fire(wrongPlayer, 0, validResponsePacket)
    remote.OnServerEvent:Fire(player, 0, validResponsePacket)
    assert(correlatedPending:Await().ok and correlatedPending:Await().value == true,
        "response correlation includes actual Player before settlement")

    local limitOne = assert(server.requests.Ask:Request(player, 5, 3))
    local limitTwo = assert(server.requests.Ask:Request(player, 5, 4))
    assertError("RequestLimit", server.requests.Ask:Request(player, 5, 5))
    limitOne:Cancel()
    limitTwo:Cancel()
    local perPlayerPending = table.create(8)
    for index = 1, 8 do
        perPlayerPending[index] = assert(server.requests.Many:Request(player, 5, index))
    end
    local perPlayerOverflow, perPlayerError = server.requests.Many:Request(player, 5, 9)
    assertError("RequestLimit", perPlayerOverflow, perPlayerError)
    serverRuntime:removePlayer(player)
    assert(limitOne:Await().error.code == "Cancelled" and limitTwo:Await().error.code == "Cancelled")
    for _, handle in perPlayerPending do
        assert(handle:Await().error.code == "Disconnected",
            "Player removal settles retained server RPC handles")
    end

    local aggregatePending = table.create(64)
    for _ = 1, 8 do
        local aggregatePlayer = serverRuntime:addPlayer()
        for index = 1, 8 do
            aggregatePending[#aggregatePending + 1] = assert(
                server.requests.Many:Request(aggregatePlayer, 5, index))
        end
    end
    local overflowPlayer = serverRuntime:addPlayer()
    local aggregateOverflow, aggregateError = server.requests.Many:Request(overflowPlayer, 5, 1)
    assertError("RequestLimit", aggregateOverflow, aggregateError)
    for _, handle in aggregatePending do handle:Cancel() end
    local destroyedPending = assert(server.requests.Ask:Request(overflowPlayer, 5, 6))
    server:Destroy()
    assert(destroyedPending:Await().error.code == "Destroyed",
        "destroy settles retained server RPC handles")
    client:Destroy()
    requestPart.Parent = nil
    responsePart.Parent = nil
end

do
    local yieldingDefinition = assert(Definition.define({ name = "RpcYieldingClientRequestProof", version = 1,
        events = {}, requests = {
            Ask = { id = 1, direction = "ServerToClient", concurrency = 1, refusals = true,
                request = { { name = "value", type = "u8" } }, response = { type = "boolean" } },
        } }))
    local yieldingCompiled = Definition.get(yieldingDefinition)
    local serverRuntime = ServerRuntime.new()
    local player = serverRuntime:addPlayer()
    local server = assert(serverRuntime.server.create(yieldingDefinition, serverOptions()))
    assert(server:Start())
    local remote = serverRuntime:remote()
    local clientRuntime = ClientRuntime.create()
    local _, _, clientRemote = clientRuntime:transport(yieldingCompiled.descriptor, false)
    local client = assert(clientRuntime.module.create(yieldingDefinition, options))
    assert(client:Start())
    local calls = 0
    assert(client.requests.Ask:Connect(function(value)
        calls += 1
        assert(value == 42 or value == 43 or value == 44)
        coroutine.yield()
        return false
    end))

    local first = assert(server.requests.Ask:Request(player, 5, 42))
    local firstPacket = serverRuntime.fires[#serverRuntime.fires].values[2]
    local firstHeader = assert(RpcFrame.peek(firstPacket, false, false, 0))
    local firstThreads = clientRemote.OnClientEvent:fire(0, firstPacket)
    assert(#firstThreads == 1 and coroutine.status(firstThreads[1]) == "suspended" and calls == 1)
    local active = client:GetDiagnostics()
    assert(active.inFlight == 1 and active.counters.dispatched == 1,
        "a yielding admitted server-to-client RPC counts as active and dispatched")

    local busyBody = table.pack(Frame.compile(yieldingCompiled.requests.Ask.request, "encode")(43))
    assert(busyBody[1])
    local busyPacket = assert(RpcFrame.wrap(1, yieldingCompiled.requests.Ask.id, firstHeader.callId + 100,
        firstHeader.sessionGuid, busyBody[2], false, firstHeader.envelopeVersion or 1))
    local firesBeforeBusy = #clientRuntime.fires
    clientRemote.OnClientEvent:fire(0, busyPacket)
    local busyReply = clientRuntime.fires[#clientRuntime.fires]
    local busyHeader = assert(RpcFrame.peek(busyReply[2], false, true, 0))
    local busy = client:GetDiagnostics()
    assert(#clientRuntime.fires == firesBeforeBusy + 1 and busyHeader.kind == 6 and calls == 1
        and busy.inFlight == 1 and busy.counters.busy == 1 and busy.counters.dispatched == 1,
        "a valid request refused as Busy does not dispatch or replace the active lease")

    assert(coroutine.resume(firstThreads[1]))
    local firstReply = clientRuntime.fires[#clientRuntime.fires]
    remote.OnServerEvent:Fire(player, table.unpack(firstReply, 1, firstReply.n))
    local completed = client:GetDiagnostics()
    assert(first:Await().ok and first:Await().value == false and completed.inFlight == 0
        and completed.counters.dispatched == 1,
        "a completed yielding handler releases its active count")

    local late = assert(server.requests.Ask:Request(player, 5, 44))
    local latePacket = serverRuntime.fires[#serverRuntime.fires].values[2]
    local lateThreads = clientRemote.OnClientEvent:fire(0, latePacket)
    assert(#lateThreads == 1 and coroutine.status(lateThreads[1]) == "suspended")
    assert(client:GetDiagnostics().inFlight == 1 and client:GetDiagnostics().counters.dispatched == 2)
    local firesBeforeDestroy = #clientRuntime.fires
    client:Destroy()
    assert(client:GetDiagnostics().inFlight == 0)
    assert(coroutine.resume(lateThreads[1]))
    local destroyed = client:GetDiagnostics()
    assert(#clientRuntime.fires == firesBeforeDestroy and destroyed.inFlight == 0
        and destroyed.counters.dispatched == 2,
        "teardown invalidates an active lease and suppresses a late handler response")
    server:Destroy()
    assert(late:Await().error.code == "Destroyed")
end

print("PASS Relay.RpcSession")
