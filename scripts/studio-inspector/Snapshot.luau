local MAX_TEXT_BYTES = 65_536
local TRUNCATED = "\n[Relay Inspector snapshot truncated at 65536 bytes]\n"
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

local function format(report, diagnostics, label, failures)
    local lines = {}
    local bytes = 0
    local truncated = false

    local function add(line)
        local size = #line + 1
        if bytes + size > MAX_TEXT_BYTES - #TRUNCATED then
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

    local reports = diagnostics.reports
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

    add("Observed API failures (RecordFailure; code-only counts):")
    local anyFailure = false
    for _, code in FAILURE_CODES do
        local count = failures[code]
        if type(count) == "number" and count > 0 then
            anyFailure = true
            if not add(string.format("  %s=%s", code, safeNumber(count))) then break end
        end
    end
    if not anyFailure then add("  none recorded") end

    local result = table.concat(lines, "\n")
    if truncated then result ..= TRUNCATED end
    return result
end

local function isFailureCode(code)
    for _, known in FAILURE_CODES do
        if known == code then return true end
    end
    return false
end

return table.freeze({ format = format, isFailureCode = isFailureCode, MAX_BYTES = MAX_TEXT_BYTES })
