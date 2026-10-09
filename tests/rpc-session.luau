local Definition = require("../src/Definition")
local Frame = require("../src/internal/Frame")
local RpcFrame = require("../src/internal/RpcFrame")
local ClientRuntime = require("./support/ClientRuntime")
local ServerRuntime = require("./support/ServerRuntime")

local spec = { name = "RpcSessionProof", version = 1, events = {
    Input = { id = 1, direction = "ClientToServer", fields = { { name = "value", type = "u8" } } },
    UnreliableInput = { id = 2, direction = "ClientToServer", delivery = "Unreliable", fields = {} },
}, requests = {
    False = { id = 3, request = { { name = "value", type = "u8" } }, response = { type = "boolean" } },
    Nil = { id = 4, request = {}, response = { type = "optional", value = { type = "u8" } } },
    Other = { id = 5, request = { { name = "value", type = "u8" } }, response = { type = "u8" } },
    Throw = { id = 6, request = {}, response = { type = "u8" } },
    Multi = { id = 7, request = {}, response = { type = "u8" } },
} }
for index = 1, 9 do
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
    local falseCalls, nilCalls, otherCalls, throwCalls, multiCalls = 0, 0, 0, 0, 0
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

    local beforeFires = #runtime.fires
    remote.OnServerEvent:Fire(player, 0, makeRequest("Method9", 6, guid))
    remote.OnServerEvent:Fire(player, 0, makeRequest("False", 6, guid, 7), "extra")
    remote.OnServerEvent:Fire(player, 0, buffer.create(43))
    local falseRequestOk, falseRequestBody = Frame.compile(compiled.requests.False.request, "encode")(7)
    assert(falseRequestOk)
    remote.OnServerEvent:Fire(player, 0, RpcFrame.wrap(2, 3, 7, guid, falseRequestBody))
    runtime:unreliableRemote().OnServerEvent:Fire(player, 0, makeRequest("False", 8, guid, 7))
    assert(#runtime.fires == beforeFires, "malformed, wrong-kind, and unreliable RPC attempts are silent")
    local diagnostics = server:GetDiagnostics()
    assert(diagnostics.events.False == nil and diagnostics.counters.received == 11
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
    assert(server:GetDiagnostics().inFlight == 8 and server:GetDiagnostics().counters.busy == 1,
        "one yielding event and seven requests share the eight-call Player lease cap")

    local allMethods = { "False", "Nil", "Other", "Throw", "Multi", "Method1", "Method2", "Method3" }
    for _ = 1, 7 do
        local player = runtime:addPlayer()
        for _, name in allMethods do send(player, name) end
    end
    local finalPlayer = runtime:addPlayer()
    send(finalPlayer, "Method4")
    assert(server:GetDiagnostics().inFlight == 64 and server:GetDiagnostics().counters.busy == 2,
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
        "a malformed response body leaves the pending call unsettled")
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
    assertError("RequestLimit", budgetClient.requests.Method9:Request(60))
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

print("PASS Relay.RpcSession")
