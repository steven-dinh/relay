local MAX_TEXT_BYTES = 65_536
local MAX_HISTORY_BYTES = 24_576
local MAX_HISTORY_SAMPLES = 16
local COUNTER_LIMIT = 4_294_967_295
local MAX_ELAPSED_SECONDS = 4_294_967
local HISTORY_MARKER = "\n[Relay Inspector History]\n"
local SAMPLE_MARKER = "\n[Relay Inspector Sample]\n"
local TRUNCATED = "\n[Relay Inspector snapshot truncated to remaining byte budget]\n"
local CHANNELS = { "Reliable", "Unreliable" }
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
    "InvalidOptions", "NotStarted", "ReadinessDisabled", "ReadinessExhausted", "StartupTimeout",
    "TransportFailure", "WrongRuntimeSide",
}
local STATES = { "Created", "Starting", "Started", "Disconnected", "Destroyed" }

local function contains(values, value)
    for _, candidate in values do
        if candidate == value then return true end
    end
    return false
end

local function safeNumber(value)
    if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
        return string.format("%.0f", value)
    end
    return "-"
end

local function sortedKeys(value, numeric)
    local result = {}
    for key in value or {} do
        if type(key) == (if numeric then "number" else "string") then
            table.insert(result, key)
        end
    end
    table.sort(result)
    return result
end

local function format(report, diagnostics, label, failures, maximumBytes)
    local textLimit = if type(maximumBytes) == "number" then math.clamp(maximumBytes, #TRUNCATED, MAX_TEXT_BYTES)
        else MAX_TEXT_BYTES
    local lines = {}
    local bytes = 0
    local truncated = false

    local function add(line)
        local size = #line + 1
        if bytes + size > textLimit - #TRUNCATED then
            truncated = true
            return false
        end
        table.insert(lines, line)
        bytes += size
        return true
    end

    add("Relay Studio Inspector v1")
    add("Attachment: " .. label)
    add(string.format("Definition: %s v%s | protocol %s | descriptor %s bytes | readiness %s",
        report.name, safeNumber(report.version), report.protocol, safeNumber(report.descriptorBytes),
        if report.readiness then "enabled" else "disabled"))

    local reports = diagnostics.reports
    add("Live summary: " .. (if reports == nil then "rejection reports disabled"
        else "rejection reports total=" .. safeNumber(reports.total)))
    local failureValues = {}
    for _, code in FAILURE_CODES do
        local count = failures[code]
        if type(count) == "number" and count > 0 then
            table.insert(failureValues, code .. "=" .. safeNumber(count))
        end
    end
    add("Observed API failures: " .. (if #failureValues == 0 then "none" else table.concat(failureValues, ", ")))

    add("Events:")
    for _, name in sortedKeys(report.events) do
        local event = report.events[name]
        local budget = event.bytes
        local bounds = if budget.minimum ~= nil
            then string.format("%s %s..%s / limit %s", budget.representation, safeNumber(budget.minimum),
                safeNumber(budget.maximum), safeNumber(budget.limit))
            else string.format("%s string-content<=%s; Roblox-encoded bytes unknown", budget.representation,
                safeNumber(budget.maximumStringContentBytes))
        if not add(string.format("  Event #%s %s | %s | %s | fields %s depth %s nodes %s | %s",
            safeNumber(event.id), name, event.direction, event.delivery, safeNumber(event.fieldCount),
            safeNumber(event.maximumDepth), safeNumber(event.maximumExpandedNodes), bounds)) then break end
    end

    add("Requests:")
    for _, name in sortedKeys(report.requests) do
        local request = report.requests[name]
        if not add(string.format("  Request #%s %s | %s | concurrency %s | request %s %s..%s | response %s %s..%s",
            safeNumber(request.id), name, request.direction, safeNumber(request.concurrency),
            request.request.bytes.representation, safeNumber(request.request.bytes.minimum),
            safeNumber(request.request.bytes.maximum), request.response.bytes.representation,
            safeNumber(request.response.bytes.minimum), safeNumber(request.response.bytes.maximum))) then break end
    end

    add("Session:")
    add(string.format("  side %s | state %s | inFlight %s (global active Relay leases)", diagnostics.side,
        diagnostics.state, safeNumber(diagnostics.inFlight)))
    add("  Handler limits: " .. (function()
        local values = {}
        for _, key in sortedKeys(diagnostics.handlerLimits) do
            table.insert(values, key .. "=" .. safeNumber(diagnostics.handlerLimits[key]))
        end
        return table.concat(values, ", ")
    end)())
    add("Diagnostic *Bytes fields use modeled content units; outboundBytesCharged counts admission reservations, not wire bytes.")
    add("sendHandoffs/broadcastHandoffs count successful local native handoffs, not receipts.")
    add("  Session counters:")
    for _, counter in SESSION_COUNTERS do
        if not add(string.format("    %s=%s", counter, safeNumber(diagnostics.counters[counter]))) then break end
    end
    add("  Event counters:")
    for _, name in sortedKeys(diagnostics.events) do
        local row = diagnostics.events[name]
        local values = {}
        for _, counter in sortedKeys(row) do
            table.insert(values, counter .. "=" .. safeNumber(row[counter]))
        end
        if not add(string.format("    Event #%s %s | %s", safeNumber(report.events[name].id), name,
            table.concat(values, ", "))) then break end
    end

    local traffic = diagnostics.traffic
    if traffic == nil then
        add("Traffic diagnostics disabled.")
    else
        add("Traffic *Bytes fields use modeled content units. sentPackets counts local successful handoffs, not receipts; sentRecords counts represented logical records.")
        add("Channel traffic:")
        for _, channel in CHANNELS do
            local row = traffic.channels[channel]
            if row ~= nil then
                local values = {}
                for _, counter in TRAFFIC_COUNTERS do
                    table.insert(values, counter .. "=" .. safeNumber(row[counter]))
                end
                if not add("  " .. channel .. " | " .. table.concat(values, ", ")) then break end
            end
        end
        add("Endpoint traffic:")
        for _, id in sortedKeys(traffic.endpoints, true) do
            local endpoint = traffic.endpoints[id]
            for _, channel in CHANNELS do
                local row = endpoint.channels[channel]
                if row ~= nil then
                    local values = {}
                    for _, counter in TRAFFIC_COUNTERS do
                        table.insert(values, counter .. "=" .. safeNumber(row[counter]))
                    end
                    if not add(string.format("  %s #%s %s / %s | %s", endpoint.kind, safeNumber(endpoint.id),
                        endpoint.name, channel, table.concat(values, ", "))) then break end
                end
            end
        end
    end

    if reports == nil then
        add("Rejection reports disabled; session and event scalar counters remain available.")
    else
        add(string.format("Rejection reports (latest %s of %s):", safeNumber(#reports.entries), safeNumber(reports.total)))
        for _, entry in reports.entries do
            local endpoint = if entry.endpointId == nil then "session" else "#" .. safeNumber(entry.endpointId)
            local channel = if entry.channel == nil then "" else " / " .. entry.channel
            if not add(string.format("  %s%s %s x%s", endpoint, channel, entry.reason, safeNumber(entry.count))) then break end
        end
    end

    local result = table.concat(lines, "\n")
    if truncated then result ..= TRUNCATED end
    return result
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function counterValue(value)
    if not finite(value) or value < 0 or value % 1 ~= 0 then return nil end
    return math.min(value, COUNTER_LIMIT)
end

local function gaugeValue(value)
    if not finite(value) or value % 1 ~= 0 or math.abs(value) > COUNTER_LIMIT then return nil end
    return value
end

local function counterDelta(value, previous)
    if previous == nil then return "unavailable" end
    if value < previous then return "reset" end
    local amount = value - previous
    if value == COUNTER_LIMIT then return "at least " .. string.format("%.0f", amount) end
    return string.format("%+.0f", amount)
end

local function historySample(diagnostics, failures, elapsedSeconds, previous)
    local elapsed = if finite(elapsedSeconds) then math.clamp(elapsedSeconds, 0, MAX_ELAPSED_SECONDS) else 0
    local side = if diagnostics.side == "Server" or diagnostics.side == "Client" then diagnostics.side else "Unknown"
    local state = if contains(STATES, diagnostics.state) then diagnostics.state else "Unknown"
    local values = {}
    local function category(name, value)
        local old = if previous == nil then nil else previous[name]
        return if previous == nil then "baseline" elseif old == nil then "unavailable"
            elseif old == value then "unchanged" else "from " .. old
    end
    values.side = side
    values.state = state
    local lines = { string.format("Sample t=%.3fs (os.clock elapsed seconds) | side=%s (%s) state=%s (%s)",
        elapsed, side, category("side", side), state, category("state", state)) }

    local function addGauge(name, value)
        if value == nil then return end
        local delta = if previous == nil then "baseline"
            elseif previous[name] == nil then "unavailable" else string.format("%+.0f", value - previous[name])
        values[name] = value
        table.insert(lines, string.format("  %s=%s | delta=%s", name, string.format("%.0f", value), delta))
    end

    local function addCounter(name, value)
        if value == nil then return end
        local old = if previous == nil then nil else previous[name]
        local delta = if previous == nil then "baseline" else counterDelta(value, old)
        values[name] = value
        table.insert(lines, string.format("  %s=%s%s | delta=%s", name, string.format("%.0f", value),
            if value == COUNTER_LIMIT then " (saturated)" else "", delta))
    end

    addGauge("inFlight", gaugeValue(diagnostics.inFlight))
    local counters = if type(diagnostics.counters) == "table" then diagnostics.counters else nil
    for _, counter in SESSION_COUNTERS do
        addCounter("session." .. counter, counterValue(if counters == nil then nil else counters[counter]))
    end

    local traffic = if type(diagnostics.traffic) == "table" then diagnostics.traffic else nil
    if traffic == nil then
        table.insert(lines, "  traffic diagnostics disabled")
    else
        local channels = if type(traffic.channels) == "table" then traffic.channels else nil
        for _, channel in CHANNELS do
            local row = if channels == nil then nil else channels[channel]
            if type(row) == "table" then
                for _, counter in TRAFFIC_COUNTERS do
                    addCounter("traffic." .. channel .. "." .. counter, counterValue(row[counter]))
                end
            end
        end
    end

    for _, code in FAILURE_CODES do
        addCounter("failure." .. code, counterValue(failures[code] or 0))
    end
    local reports = if type(diagnostics.reports) == "table" then diagnostics.reports else nil
    if reports == nil then
        table.insert(lines, "  rejection report diagnostics disabled")
    else
        addCounter("reports.total", counterValue(reports.total))
    end

    local sampleText = table.concat(lines, "\n")
    return sampleText, table.freeze(values)
end

local function encodeHistory(history)
    if #history == 0 then return "" end
    return HISTORY_MARKER .. table.concat(history, SAMPLE_MARKER)
end

local function historyBytes(history)
    return #encodeHistory(history)
end

local function formatWithHistory(report, diagnostics, label, failures, history, notice)
    local suffix = encodeHistory(history)
    assert(#suffix <= MAX_HISTORY_BYTES, "history frame exceeds its byte limit")
    local status = if type(notice) == "string" then notice else ""
    local liveLimit = MAX_TEXT_BYTES - #suffix - #status
    local live = format(report, diagnostics, label, failures, liveLimit)
    local result = live .. status .. suffix
    assert(#result <= MAX_TEXT_BYTES, "inspector snapshot exceeds its byte limit")
    return result
end

local function isFailureCode(code)
    for _, known in FAILURE_CODES do
        if known == code then return true end
    end
    return false
end

return table.freeze({
    format = format,
    formatWithHistory = formatWithHistory,
    historySample = historySample,
    historyBytes = historyBytes,
    isFailureCode = isFailureCode,
    MAX_BYTES = MAX_TEXT_BYTES,
    MAX_HISTORY_BYTES = MAX_HISTORY_BYTES,
    MAX_HISTORY_SAMPLES = MAX_HISTORY_SAMPLES,
    COUNTER_LIMIT = COUNTER_LIMIT,
    MAX_ELAPSED_SECONDS = MAX_ELAPSED_SECONDS,
})
