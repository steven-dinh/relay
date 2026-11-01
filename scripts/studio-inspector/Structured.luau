local MAX_SERIALIZED_BYTES = 65_536
local MAX_LIVE_TEXT_BYTES = 24_576
local MAX_HISTORY_BYTES = 24_576
local MAX_HISTORY_SAMPLES = 16
local MAX_ENDPOINTS = 64
local MAX_ENDPOINT_ID = 65_535
local MAX_SCALARS = 128
local MAX_COUNTER = 4_294_967_295
local MAX_ELAPSED_SECONDS = 4_294_967

local TOP_LEVEL_KEYS = {
    format = true, sessionId = true, association = true, identityStatus = true, label = true,
    projectId = true, compilerId = true, toolingId = true, sourceId = true, namespace = true,
    inspection = true, liveText = true, history = true, scalars = true, elapsed = true, notice = true,
}
local INSPECTION_KEYS = { name = true, version = true, protocol = true, descriptorBytes = true,
    readiness = true, events = true, requests = true }
local EVENT_KEYS = { kind = true, name = true, id = true, direction = true, delivery = true }
local REQUEST_KEYS = { kind = true, name = true, id = true, direction = true }
local DIRECTIONS = { ClientToServer = true, ServerToClient = true }
local DELIVERIES = { Reliable = true, Unreliable = true, OrderedUnreliable = true }
local NOTICES = {
    ["\nSession sampling stopped: diagnostics unavailable; error text omitted."] = true,
    ["\nSession sampling stopped: invalid diagnostics; details omitted."] = true,
}
local SCALAR_KEYS = { side = true, state = true, inFlight = true, ["reports.total"] = true }
local SESSION_COUNTERS = {
    "received", "ineligible", "perPlayerRate", "aggregateRate", "perPlayerBytes", "aggregateBytes",
    "endpointRate", "invalidEndpoint", "wrongChannel", "noListener", "busy", "invalidPayload", "stale",
    "dispatched", "handlerErrors", "sendHandoffs", "broadcastHandoffs", "transportFailures", "transportLosses",
    "outboundByteRejected", "outboundBytesCharged",
}
local TRAFFIC_COUNTERS = {
    "submittedRecords", "submittedBytes", "sentPackets", "sentRecords", "sentBytes", "sentRecipientBytes",
    "receivedPackets", "receivedBytes", "validatedRecords", "validatedBytes", "unmeasuredPackets",
}
local FAILURE_CODES = {
    "AlreadyStarted", "DefinitionMismatch", "Disconnected", "Destroyed", "InvalidAudience", "InvalidDefinition",
    "InvalidOptions", "NotStarted", "ReadinessDisabled", "ReadinessExhausted", "RemoteOwnershipConflict",
    "StartupTimeout", "TransportFailure", "WrongRuntimeSide",
}

for _, counter in SESSION_COUNTERS do SCALAR_KEYS["session." .. counter] = true end
for _, channel in { "Reliable", "Unreliable" } do
    for _, counter in TRAFFIC_COUNTERS do SCALAR_KEYS["traffic." .. channel .. "." .. counter] = true end
end
for _, code in FAILURE_CODES do SCALAR_KEYS["failure." .. code] = true end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function exactKeys(value, allowed)
    if not plain(value) then return false end
    for key in value do
        if type(key) ~= "string" or allowed[key] ~= true then return false end
    end
    return true
end

local function denseArray(value, maximum)
    if not plain(value) or #value > maximum then return false end
    local count = 0
    for key in value do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
        count += 1
    end
    return count == #value
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function boundedString(value, maximum, allowNewlines)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and (allowNewlines == true or not string.find(value, "%c"))
end

local function validGuid(value)
    return type(value) == "string" and #value == 36
        and string.match(value, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function validNamespace(value)
    return value == nil or (boundedString(value, 32)
        and string.match(value, "^[a-z][a-z0-9_%-]*$") ~= nil)
end

local function validEndpointName(value)
    return boundedString(value, 32) and string.match(value, "^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

local function validEndpointRows(rows, kind)
    if not denseArray(rows, MAX_ENDPOINTS) then return false end
    local seenIds, seenNames = {}, {}
    for _, row in rows do
        local allowed = if kind == "event" then EVENT_KEYS else REQUEST_KEYS
        if not exactKeys(row, allowed) or row.kind ~= kind or not validEndpointName(row.name)
            or not finite(row.id) or row.id % 1 ~= 0 or row.id < 1 or row.id > MAX_ENDPOINT_ID
            or not DIRECTIONS[row.direction] or seenIds[row.id] or seenNames[row.name] then
            return false
        end
        if kind == "event" and not DELIVERIES[row.delivery] then return false end
        seenIds[row.id], seenNames[row.name] = true, true
    end
    return true
end

local function validInspection(value)
    if not exactKeys(value, INSPECTION_KEYS) then return false end
    local protocol = if type(value.protocol) == "string"
        then tonumber(string.match(value.protocol, "^RR(%d%d?)$")) else nil
    if not validEndpointName(value.name)
        or not finite(value.version) or value.version % 1 ~= 0 or value.version < 1 or value.version > 2_147_483_647
        or protocol == nil or protocol < 1 or protocol > 17
        or not finite(value.descriptorBytes) or value.descriptorBytes % 1 ~= 0
        or value.descriptorBytes < 1 or value.descriptorBytes > 4_096 or type(value.readiness) ~= "boolean"
        or not validEndpointRows(value.events, "event") or not validEndpointRows(value.requests, "request") then
        return false
    end
    if #value.events + #value.requests > MAX_ENDPOINTS then return false end
    local seenIds = {}
    for _, endpoints in { value.events, value.requests } do
        for _, endpoint in endpoints do
            if seenIds[endpoint.id] then return false end
            seenIds[endpoint.id] = true
        end
    end
    return true
end

local function safeHistoryText(value)
    if not boundedString(value, MAX_HISTORY_BYTES, true) then return false end
    for index = 1, #value do
        local byte = string.byte(value, index)
        local allowed = (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122) or byte == 10
            or string.find(" .,+-_=|():", string.char(byte), 1, true) ~= nil
        if not allowed then return false end
    end
    return true
end

local function encodedHistoryBytes(history)
    local bytes = 2 + math.max(0, #history - 1)
    for _, sample in history do
        bytes += #sample + 2
        for index = 1, #sample do
            if string.byte(sample, index) == 10 then bytes += 1 end
        end
    end
    return bytes
end

local function validScalars(value)
    if not plain(value) then return false end
    local count = 0
    for key, scalar in value do
        if type(key) ~= "string" or not SCALAR_KEYS[key] then return false end
        if key == "side" then
            if scalar ~= "Server" and scalar ~= "Client" and scalar ~= "Unknown" then return false end
        elseif key == "state" then
            if scalar ~= "Created" and scalar ~= "Starting" and scalar ~= "Started"
                and scalar ~= "Disconnected" and scalar ~= "Destroyed" and scalar ~= "Unknown" then return false end
        elseif not finite(scalar) or scalar % 1 ~= 0 or math.abs(scalar) > MAX_COUNTER
            or (key ~= "inFlight" and scalar < 0) then
            return false
        end
        count += 1
        if count > MAX_SCALARS then return false end
    end
    return true
end

local function validate(value)
    if not exactKeys(value, TOP_LEVEL_KEYS) or value.format ~= 2 or not validGuid(value.sessionId)
        or value.association ~= "constructed"
        or (value.identityStatus ~= "application-supplied" and value.identityStatus ~= "unverified")
        or not boundedString(value.label, 48) or not validNamespace(value.namespace)
        or not validInspection(value.inspection)
        or not boundedString(value.liveText, MAX_LIVE_TEXT_BYTES, true)
        or not denseArray(value.history, MAX_HISTORY_SAMPLES) or #value.history == 0
        or not validScalars(value.scalars) or not finite(value.elapsed)
        or value.elapsed < 0 or value.elapsed > MAX_ELAPSED_SECONDS
        or (value.notice ~= nil and not NOTICES[value.notice]) then
        return false, "InvalidRecord"
    end
    local allIdentity = value.projectId ~= nil and value.compilerId ~= nil
        and value.toolingId ~= nil and value.sourceId ~= nil
    for _, field in { "projectId", "compilerId", "toolingId", "sourceId" } do
        local current = value[field]
        local maximum = if field == "projectId" then 64 else 256
        if current ~= nil and not boundedString(current, maximum) then return false, "InvalidIdentity" end
    end
    if (value.identityStatus == "application-supplied") ~= allIdentity then return false, "InvalidIdentityStatus" end
    for _, sample in value.history do
        if not safeHistoryText(sample) then return false, "InvalidHistory" end
    end
    if encodedHistoryBytes(value.history) > MAX_HISTORY_BYTES then return false, "HistoryTooLarge" end
    return true, nil
end

local function encode(jsonEncode, value)
    if type(jsonEncode) ~= "function" then return nil, "InvalidEncoder" end
    local valid, reason = validate(value)
    if not valid then return nil, reason end
    local ok, text = pcall(jsonEncode, value)
    if not ok or type(text) ~= "string" then return nil, "EncodeFailed" end
    if #text > MAX_SERIALIZED_BYTES then return nil, "RecordTooLarge" end
    return text, nil
end

local function decode(jsonDecode, text)
    if type(text) ~= "string" then return nil, "InvalidText" end
    if #text > MAX_SERIALIZED_BYTES then return nil, "RecordTooLarge" end
    if type(jsonDecode) ~= "function" then return nil, "InvalidDecoder" end
    local ok, value = pcall(jsonDecode, text)
    if not ok then return nil, "MalformedJson" end
    local valid, reason = validate(value)
    if not valid then return nil, reason end
    return value, nil
end

local function inspection(report)
    if type(report) ~= "table" or type(report.events) ~= "table" or type(report.requests) ~= "table" then
        return nil, "InvalidInspection"
    end
    local result = {
        name = report.name,
        version = report.version,
        protocol = report.protocol,
        descriptorBytes = report.descriptorBytes,
        readiness = report.readiness == true,
        events = {},
        requests = {},
    }
    local function append(source, target, kind)
        for name, endpoint in source do
            table.insert(target, { kind = kind, name = name, id = endpoint.id, direction = endpoint.direction,
                delivery = if kind == "event" then endpoint.delivery else nil })
        end
        table.sort(target, function(left, right)
            if left.id == right.id then return left.name < right.name end
            return left.id < right.id
        end)
    end
    append(report.events, result.events, "event")
    append(report.requests, result.requests, "request")
    if not validInspection(result) then return nil, "InvalidInspection" end
    return result, nil
end

return table.freeze({
    encode = encode,
    decode = decode,
    inspection = inspection,
    validate = validate,
    encodedHistoryBytes = encodedHistoryBytes,
    MAX_SERIALIZED_BYTES = MAX_SERIALIZED_BYTES,
    MAX_LIVE_TEXT_BYTES = MAX_LIVE_TEXT_BYTES,
    MAX_HISTORY_BYTES = MAX_HISTORY_BYTES,
    MAX_HISTORY_SAMPLES = MAX_HISTORY_SAMPLES,
})
