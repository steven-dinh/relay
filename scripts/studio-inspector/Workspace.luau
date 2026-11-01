local Result = require(if script then script.Parent.ToolingResult else "../tooling/Result")
local Project = require(if script then script.Parent.ToolingProject else "../tooling/Project")

local MAX_TEXT_BYTES = 65_536
local TRUNCATED = "\n[Captured report view truncated to 65536 bytes]"
local VIEW_NAMES = { Overview = true, Problems = true, Schema = true, Checks = true }
local RESULT_STATUSES = {
    passed = true, failed = true, running = true, cancelled = true, stale = true,
    unsupported = true, skipped = true, inconclusive = true,
}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function clean(value, maximum)
    if type(value) ~= "string" then return "Unknown" end
    return (string.gsub(string.sub(value, 1, maximum), "%c", " "))
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function number(value)
    return if finite(value) then string.format("%.15g", value) else "Unknown"
end

local function boolean(value)
    return if type(value) == "boolean" then tostring(value) else "Unknown"
end

local function keys(value)
    local result = {}
    if plain(value) then
        for key in value do
            if type(key) == "string" then table.insert(result, key) end
        end
    end
    table.sort(result)
    return result
end

local function representation(value)
    if value == "RelayBuffer" or value == "NativeTuple" then return value end
    return "Unknown"
end

local function direction(value)
    if value == "ClientToServer" or value == "ServerToClient" then return value end
    return "Unknown"
end

local function delivery(value)
    if value == "Reliable" or value == "Unreliable" or value == "OrderedUnreliable" then return value end
    return "Unknown"
end

local function byteRange(value)
    if value == "Unknown" then return "Unknown" end
    if not plain(value) then return "Unknown" end
    local minimum, maximum = number(value.minimum), number(value.maximum)
    if minimum == "Unknown" or maximum == "Unknown" then return "Unknown" end
    return minimum .. ".." .. maximum
end

local function byteSummary(value)
    if not plain(value) then return "Unknown bytes" end
    local kind = representation(value.representation)
    if kind == "NativeTuple" then
        return string.format("NativeTuple string-content<=%s; Roblox-encoded bytes Unknown",
            number(value.maximumStringContentBytes))
    end
    return string.format("%s %s / limit %s; Roblox-encoded bytes Unknown", kind,
        byteRange({ minimum = value.minimum, maximum = value.maximum }), number(value.limit))
end

local function appendEndpoints(report, add)
    if not plain(report) then return false end
    local found = false
    if plain(report.events) then
        for _, name in keys(report.events) do
            local event = report.events[name]
            if plain(event) then
                found = true
                if not add(string.format("Event #%s %s | %s | %s | fields %s depth %s nodes %s | %s",
                    number(event.id), clean(name, 128), direction(event.direction), delivery(event.delivery),
                    number(event.fieldCount), number(event.maximumDepth), number(event.maximumExpandedNodes),
                    byteSummary(event.bytes))) then return found end
            end
        end
    end
    if plain(report.requests) then
        for _, name in keys(report.requests) do
            local request = report.requests[name]
            if plain(request) then
                found = true
                local requestBytes = if plain(request.request) then byteSummary(request.request.bytes) else "Unknown bytes"
                local responseBytes = if plain(request.response) then byteSummary(request.response.bytes) else "Unknown bytes"
                if not add(string.format("Request #%s %s | %s | concurrency %s | request %s | response %s",
                    number(request.id), clean(name, 128), direction(request.direction), number(request.concurrency),
                    requestBytes, responseBytes)) then return found end
            end
        end
    end
    return found
end

local function renderSchema(data, add)
    if not plain(data) then
        add("Schema inspection data is unavailable.")
        return
    end
    add(string.format("Schema: %s v%s | protocol %s | descriptor %s bytes | readiness %s | bit packing %s",
        clean(data.name, 128), number(data.version), clean(data.protocol, 32), number(data.descriptorBytes),
        if data.readiness == true then "enabled" elseif data.readiness == false then "disabled" else "Unknown",
        if data.bitPacking == true then "enabled" elseif data.bitPacking == false then "disabled" else "Unknown"))
    if plain(data.outboundBytes) then
        add(string.format("Outbound budget: capacity %s; refill/sec %s", number(data.outboundBytes.capacity),
            number(data.outboundBytes.refillPerSecond)))
    end
    if not appendEndpoints(data, add) then add("No endpoint metadata is available.") end
    add("Roblox-encoded and physical wire byte sizes are Unknown.")
end

local function renderCompatibility(data, add)
    if not plain(data) then
        add("Compatibility data is unavailable.")
        return
    end
    local status = if data.status == "equal" or data.status == "changed" or data.status == "invalid-input"
        then data.status else "Unknown"
    add("Raw-schema compatibility: " .. status)
    add("Descriptor equal: " .. boolean(data.descriptorEqual))
    add("Requires matched deployment: " .. boolean(data.requiresMatchedDeployment))
    add("Advisory only: raw-schema comparison does not establish deployed-peer compatibility.")
    for _, sideName in { "before", "after" } do
        local side = data[sideName]
        if plain(side) and plain(side.metadata) then
            local metadata = side.metadata
            add(string.format("%s schema: %s v%s | protocol %s | readiness %s",
                if sideName == "before" then "Before" else "After", clean(metadata.name, 128),
                number(metadata.version), clean(metadata.protocol, 32), boolean(metadata.readiness)))
        end
    end
    if type(data.changes) == "table" then
        if #data.changes == 0 then add("Changes: none")
        else
            add("Changes:")
            for _, change in data.changes do
                if plain(change) and type(change.path) == "string"
                    and (change.kind == "added" or change.kind == "removed" or change.kind == "changed") then
                    if not add(string.format("  %s %s", change.kind, clean(change.path, 512))) then break end
                end
            end
        end
    end
end

local function renderBudget(data, add)
    if not plain(data) then
        add("Budget analysis data is unavailable.")
        return
    end
    if plain(data.aggregate) then
        add("Aggregate payload bytes/sec: " .. byteRange(data.aggregate.payloadBytesPerSecond))
        add("Aggregate modeled Relay buffer bytes/sec: " .. byteRange(data.aggregate.relayBufferBytesPerSecond))
    end
    if plain(data.budget) then
        local status = if data.budget.status == "passed" or data.budget.status == "unknown" or data.budget.status == "exceeded"
            then data.budget.status else "Unknown"
        add(string.format("Relay buffer budget <= %s bytes/sec: %s",
            number(data.budget.maximumRelayBufferBytesPerSecond), status))
    end
    if plain(data.endpoints) then
        for _, key in keys(data.endpoints) do
            local endpoint = data.endpoints[key]
            if plain(endpoint) then
                local kind = if endpoint.kind == "event" or endpoint.kind == "request" then endpoint.kind else "Unknown"
                if not add(string.format("%s | %s #%s | payload/sec %s | Relay buffer/sec %s",
                    clean(key, 128), kind, number(endpoint.id),
                    byteRange(endpoint.payloadBytesPerSecond), byteRange(endpoint.relayBufferBytesPerSecond))) then break end
            end
        end
    end
    add("Exclusions: NativeTuple sizes, Roblox-encoded bytes, and physical wire bytes are Unknown; compression and Instance-reference sidecar admission charges are excluded.")
end

local function decode(bytes, decodeJson)
    if type(bytes) ~= "string" then return nil, "captured report must be text" end
    if #bytes > Result.MAX_BYTES then return nil, "captured report exceeds the 4 MiB limit" end
    if type(decodeJson) ~= "function" then return nil, "JSON decoder is unavailable" end
    local ok, value = pcall(decodeJson, bytes)
    if not ok then return nil, "captured report is malformed JSON" end
    local valid, reason = Result.validate(value)
    if not valid then return nil, reason end
    return value, nil
end

local function render(result, view)
    if not Result.validate(result) then return "Invalid captured CLI report." end
    local lines, bytes, truncated = {}, 0, false
    local function add(line)
        if truncated then return false end
        local size = #line + (if #lines == 0 then 0 else 1)
        if bytes + size > MAX_TEXT_BYTES - #TRUNCATED then
            truncated = true
            return false
        end
        table.insert(lines, line)
        bytes += size
        return true
    end

    add("Captured CLI report; Studio source freshness is unverified.")
    add("Project: " .. clean(result.projectId, 64))
    add("Compiler: " .. clean(result.compilerId, 256))
    add("Tooling: " .. clean(result.toolingId, 256))
    add("Source: " .. clean(result.sourceId, 256))
    add("Host: " .. clean(result.host, 16))
    add("Run: " .. clean(result.runId, 128))
    add("Status: " .. (if RESULT_STATUSES[result.status] then result.status else "Unknown"))
    add("Operation: " .. clean(result.operation, 32))

    if not VIEW_NAMES[view] then
        add("Unsupported view.")
    elseif view == "Overview" then
        local diagnosticCount = #result.diagnostics
        for _, child in result.children or {} do diagnosticCount += #child.diagnostics end
        add("Diagnostics: " .. tostring(diagnosticCount))
        add("Artifacts: " .. tostring(#result.artifacts))
        local projection = if plain(result.data) then Project.validate(result.data.project) else nil
        if projection then
            add("Schema path: " .. projection.schema)
            for _, field in { "policy", "baseline", "workload", "typescript" } do
                if projection[field] then add(field .. " path: " .. projection[field]) end
            end
            for _, path in projection.tests or {} do add("Portable scenario: " .. path) end
        end
        add("Studio semantic evaluation: unavailable. Use the native Luau editor and captured CLI checks.")
        if result.status == "unsupported" then
            add("A required capability is unsupported; no pass is claimed.")
        elseif result.status == "stale" then
            add("This result is stale; verify project, compiler, tooling, source, host, and run identity.")
        end
    elseif view == "Problems" then
        local count = 0
        local function problems(items)
            for _, item in items do
                count += 1
                if not add(string.format("%s %s | %s", item.severity, clean(item.code, 64), clean(item.path, 512))) then break end
                if not add("  " .. clean(item.message, 1024)) then break end
                if not add("  Next action: " .. clean(item.action, 1024)) then break end
            end
        end
        problems(result.diagnostics)
        for _, child in result.children or {} do problems(child.diagnostics) end
        if count == 0 then add("No diagnostics.") end
    elseif view == "Schema" then
        if result.operation == "schema" then
            renderSchema(result.data, add)
        elseif result.operation == "compat" then
            renderCompatibility(result.data, add)
        elseif plain(result.children) then
            local found = false
            for _, child in result.children do
                if child.operation == "schema" then found = true; renderSchema(child.data, add)
                elseif child.operation == "compat" then found = true; renderCompatibility(child.data, add) end
                if truncated then break end
            end
            if not found then add("No schema or compatibility report is available.") end
        else
            add("No schema or compatibility report is available.")
        end
    elseif view == "Checks" then
        if plain(result.children) then
            local required, seen = {}, {}
            for _, name in result.required do required[name] = true end
            for _, child in result.children do
                seen[child.operation] = true
                local status = if Result.isCurrent(child, result) then child.status else "stale"
                if not add(string.format("%s: %s (%s)", clean(child.operation, 32), status,
                    if required[child.operation] then "required" else "optional")) then break end
                if child.operation == "budget" then renderBudget(child.data, add) end
            end
            if not truncated then
                for _, name in result.required do
                    if not seen[name] and not add(clean(name, 32) .. ": inconclusive (required; missing)") then break end
                end
            end
        else
            add(result.operation .. ": " .. result.status)
            if result.operation == "budget" then renderBudget(result.data, add)
            elseif result.operation == "compat" then renderCompatibility(result.data, add) end
        end
    end

    return table.concat(lines, "\n") .. (if truncated then TRUNCATED else "")
end

return table.freeze({ decode = decode, render = render, MAX_TEXT_BYTES = MAX_TEXT_BYTES })
