--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local partShape = s.Instance("Part")
local scalarU24 = s.field("u24" :: "u24", s.u24(0, 16_777_215))
local scalarI24 = s.field("i24" :: "i24", s.i24(-8_388_608, 8_388_607))
local scalarHalf = s.field("half" :: "half", s.f16(-10, 10))
local scalarFloat = s.field("custom" :: "custom", s.f24(-1000, 1000))
local scalarDouble = s.field("double" :: "double", s.f64(-1e100, 1e100))
local scalarLabel = s.field("label" :: "label", s.string(32, 0))
local scalarPayload = s.field("payload" :: "payload", s.buffer(64, 0))
local scalarFields = s.ordered(scalarU24, scalarI24, scalarHalf, scalarFloat, scalarDouble, scalarLabel, scalarPayload)
local collectionItems = s.field("items" :: "items", s.array(s.u24(), 8, 0))
local collectionFlags = s.field("flags" :: "flags", s.set(s.i24(), 8, 1))
local collectionScores = s.field("scores" :: "scores", s.map(s.u24(), s.f16(-1, 1), 8, 0))
local collectionFields = s.ordered(collectionItems, collectionFlags, collectionScores)

local rawMinimum: Relay.FieldSpec = {
    name = "items", type = "array" :: "array", element = { type = "u24" :: "u24" },
    maximumLength = 8, minimumLength = 0,
}
local rawRequest: Relay.RequestSpec = {
    id = 10,
    request = { { name = "target", type = "Instance" :: "Instance", className = "Part" } },
    response = { type = "optional" :: "optional", value = { type = "Instance" :: "Instance", className = "Part" } },
    direction = "ServerToClient",
    concurrency = 3,
    refusals = true,
}
local requestOptions: Relay.RequestOptions = {
    direction = "ClientToServer", concurrency = 2, refusals = false,
}

local definition, definitionIssue = Relay.define({ name = "RpcBoundedTypes", version = 1, events = {
    Reliable = s.serverToClient(1, s.ordered(s.field("value", partShape))),
    Unreliable = s.serverToClient(2, s.ordered(s.field("value", partShape)), "Unreliable"),
    Ordered = s.clientToServer(3, s.ordered(s.field("value", partShape)), "OrderedUnreliable"),
    Batch = s.serverToClient(4, s.ordered(s.field("value", partShape)), { queue = "Batch" }),
    State = s.serverToClient(5, s.ordered(s.field("value", partShape)), { queue = "State" }),
    Scalars = s.clientToServer(6, scalarFields),
    Collections = s.clientToServer(9, collectionFields),
}, requests = {
    Fetch = s.request(7, s.ordered(s.field("target", partShape)), s.optional(partShape), {
        concurrency = 2, refusals = true,
    }),
    Push = s.request(8, s.ordered(s.field("target", partShape)), s.optional(partShape), {
        direction = "ServerToClient", concurrency = 3, refusals = true,
    }),
    Flag = s.request(10, s.ordered(), s.boolean()),
} })
local token = assert(definition, definitionIssue and definitionIssue.message)
local player: Player = error("type-only fixture")
local part: Part = error("type-only fixture")
local serverResult, serverIssue = Relay.createServer(token, {
    inboundRate = { perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 } },
    instanceRoot = workspace,
})
local server = assert(serverResult, serverIssue and serverIssue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)

server.requests.Fetch:Connect(function(_player, target)
    local typed: Part = target
    return typed
end)
local pending, pendingIssue = client.requests.Fetch:Request(3, part)
local clientPending = assert(pending, pendingIssue and pendingIssue.message)
local clientResultValue = clientPending:Await()
if clientResultValue.ok then
    local _response: Part? = clientResultValue.value
end
server.requests.Flag:Connect(function(_player)
    return false
end)
local flagPending, flagIssue = client.requests.Flag:Request(3)
local flagResult = assert(flagPending, flagIssue and flagIssue.message):Await()
if flagResult.ok then
    local _flag: boolean = flagResult.value
end

server.requests.Push:Request(player, 3, part)
client.requests.Push:Connect(function(target)
    local typed: Part = target
    return typed
end)

local reliableReference: Part? = part
server.events.Reliable:SendTo({ player }, reliableReference :: Part)
server.events.Unreliable:SendTo({ player }, part)
client.events.Ordered:Send(part)
local batch, batchIssue = server:CreateBatch({ player }, 8)
local batcher = assert(batch, batchIssue and batchIssue.message)
batcher.events.Batch:Send(part)
local state, stateIssue = server:CreateState({ player }, 8)
local stateHandle = assert(state, stateIssue and stateIssue.message)
stateHandle.events.State:Put(1, "Normal", part)

local inspectionResult, inspectionIssue = Relay.inspect(token)
local inspection = assert(inspectionResult, inspectionIssue and inspectionIssue.message)
local requestConcurrency: number = inspection.requests.Fetch.concurrency
local requestDirection: Relay.RequestDirection = inspection.requests.Push.direction
local requestRefBudget = inspection.requests.Push.request.bytes.references
local responseRefBudget = inspection.requests.Push.response.bytes.references
local referenceCount: number? = if requestRefBudget then requestRefBudget.maximumCount else nil
local responseReferenceCount: number? = if responseRefBudget then responseRefBudget.maximumCount else nil
local refusalSetting: boolean = inspection.requests.Fetch.refusals
local envelopeVersion: number = inspection.requests.Push.envelopeVersion
local queuedBytes = inspection.events.Batch.queuedBytes
local maximumAdmissionBytes: number? = if queuedBytes then queuedBytes.maximumAdmissionBytes else nil
local busyCode: Relay.ErrorCode = "Busy"
local noListenerCode: Relay.ErrorCode = "NoListener"
local endpointRateCode: Relay.ErrorCode = "EndpointRateLimited"
print(rawMinimum, rawRequest, requestConcurrency, requestDirection, referenceCount, responseReferenceCount,
    refusalSetting, envelopeVersion, maximumAdmissionBytes, requestOptions, busyCode, noListenerCode, endpointRateCode)
