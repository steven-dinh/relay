local Result = require(if script then script.Parent.ToolingResult else "../tooling/Result")
local Project = require(if script then script.Parent.ToolingProject else "../tooling/Project")
local Structured = require(if script then script.Parent.Structured else "./Structured")

local MAX_TEXT_BYTES = 16_384
local TRUNCATED = "\n[Diagnosis truncated to 16384 bytes]"
local COUNTER_LIMIT = 4_294_967_295
local IDENTITY_FIELDS = { "projectId", "compilerId", "toolingId", "sourceId" }
local QUEUE_CODES = { "QueueFull", "QueueLimit", "QueueBusy", "QueueClosed" }
local OUTPUT_DIAGNOSTICS = {
    GeneratedOutputChanged = true,
    GeneratedOutputMissing = true,
    GeneratedOutputStale = true,
}
local REFUSALS = {
    { "session.perPlayerRate", "Per-player call rate refusals", "call" },
    { "session.aggregateRate", "Aggregate call rate refusals", "call" },
    { "session.perPlayerBytes", "Per-player byte admission refusals", "byte" },
    { "session.aggregateBytes", "Aggregate byte admission refusals", "byte" },
    { "session.endpointRate", "Endpoint rate refusals", "endpoint" },
    { "session.invalidEndpoint", "Invalid endpoint IDs", "endpoint" },
    { "session.outboundByteRejected", "Outbound byte budget refusals", "byte" },
}
local START_FAILURE_STAGES = { "Root", "Definition", "Reliable", "Unreliable", "DescriptorVerification",
    "OrderedInitialization", "Activation" }

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function number(value)
    return if finite(value) then string.format("%.15g", value) else "Unknown"
end

local function clean(value, maximum)
    if type(value) ~= "string" then return "Unknown" end
    return (string.gsub(string.sub(value, 1, maximum), "%c", " "))
end

local function endpointCount(value)
    if not plain(value) then return nil end
    local count = 0
    for name, endpoint in value do
        if type(name) ~= "string" or not plain(endpoint) then return nil end
        count += 1
    end
    return count
end

local function sameInspection(recordInspection, inspection)
    if not plain(inspection) or recordInspection.name ~= inspection.name
        or recordInspection.version ~= inspection.version or recordInspection.protocol ~= inspection.protocol
        or recordInspection.descriptorBytes ~= inspection.descriptorBytes
        or recordInspection.readiness ~= inspection.readiness then
        return false
    end
    local events, requests = endpointCount(inspection.events), endpointCount(inspection.requests)
    if events == nil or requests == nil or events ~= #recordInspection.events or requests ~= #recordInspection.requests then
        return false
    end
    for _, row in recordInspection.events do
        local event = inspection.events[row.name]
        if not plain(event) or event.id ~= row.id or event.direction ~= row.direction or event.delivery ~= row.delivery then
            return false
        end
    end
    for _, row in recordInspection.requests do
        local request = inspection.requests[row.name]
        if not plain(request) or request.id ~= row.id or request.direction ~= row.direction then return false end
    end
    return true
end

local function schemaResult(result)
    if result.operation == "schema" then return result end
    if plain(result.children) then
        for _, child in result.children do
            if child.operation == "schema" then return child end
        end
    end
    return nil
end

local function associationProblem(record, recordValid, result, project, add)
    if not recordValid then
        add("Live/schema association: unavailable; no valid structured session record was supplied.")
        add("Action: re-import a structured registration record.")
        return false
    elseif record.identityStatus ~= "application-supplied" then
        add("Live/schema association: unverified; the application did not declare all four project/compiler/tooling/source IDs.")
        add("Action: register the constructed session with complete application metadata, then re-import the check.")
        return false
    elseif result == nil then
        add("Live/schema association: unverified; no common captured check was supplied.")
        add("Action: run the project check and import its captured result.")
        return false
    elseif not Result.validate(result) then
        add("Live/schema association: unavailable; the common captured result is invalid.")
        add("Action: re-export and import a valid common result.")
        return false
    elseif result.operation ~= "check" and result.operation ~= "ts-check" then
        add("Live/schema association: unavailable; the captured result is not a common project check.")
        add("Action: run the project check and import its common result.")
        return false
    elseif result.status == "stale" then
        add("Live/schema association: stale; the common result does not represent the current run identity.")
        add("Action: rerun the project check and import the new result.")
        return false
    elseif project == nil then
        add("Live/schema association: unverified; the captured result has no valid project projection.")
        add("Action: import a common check containing its validated project manifest.")
        return false
    elseif project.id ~= result.projectId or project.id ~= record.projectId then
        add("Live/schema association: mismatch; the declared project ID differs from the captured project.")
        add("Action: select the matching project, then rerun checks or update registration metadata.")
        return false
    end

    for _, field in IDENTITY_FIELDS do
        if record[field] ~= result[field] then
            add("Live/schema association: mismatch; declared " .. field .. " differs from the captured check.")
            add("Action: rerun the check for this source/compiler/tooling identity or refresh registration metadata.")
            return false
        end
    end

    local child = schemaResult(result)
    if child == nil then
        add("Live/schema association: unavailable; the captured result has no schema check.")
        add("Action: include the schema check in the captured project result.")
        return false
    elseif child.status ~= "passed" then
        add("Live/schema association: unavailable; the schema check is not passed.")
        add("Action: fix schema diagnostics, rerun the check, and import its result.")
        return false
    elseif not Result.isCurrent(child, result) then
        add("Live/schema association: stale; the schema child identity differs from the captured result.")
        add("Action: rerun the project check and import the new result.")
        return false
    elseif not sameInspection(record.inspection, child.data) then
        add("Live/schema association: mismatch; captured inspection summary or endpoint roster differs.")
        add("Action: verify the application declaration, re-register the session, and rerun the schema check.")
        return false
    else
        add("Live/schema association: captured inspection summary and endpoint roster match (advisory only).")
        add("Field shapes and descriptor contents are not compared; this is not source freshness or deployed-peer proof.")
        return true
    end
end

local function projectPaths(project, validResult, linked, add)
    if not validResult or project == nil then
        add("Logical project paths: unavailable.")
        return
    end
    add(if linked then "Logical project paths (text hints, not source-line links):"
        else "Captured project paths (unlinked hints; association did not match):")
    add("  schema: " .. clean(project.schema, 1_024))
    for _, field in { "policy", "baseline", "workload", "typescript" } do
        if project[field] ~= nil then add("  " .. field .. ": " .. clean(project[field], 1_024)) end
    end
    for _, path in project.tests or {} do add("  test scenario: " .. clean(path, 1_024)) end
end

local function projectProjection(result, validResult)
    if not validResult or not plain(result.data) then return nil end
    return Project.validate(result.data.project)
end

local function capturedDiagnostics(result, add)
    if not Result.validate(result) then return end
    local function scan(items)
        for _, item in items do
            if item.code == "SourceChanged" then
                add("Source freshness diagnostic (SourceChanged): " .. clean(item.message, 1_024))
                add("Action: " .. clean(item.action, 1_024))
            elseif OUTPUT_DIAGNOSTICS[item.code] then
                add("Stale declaration diagnostic (" .. item.code .. "): " .. clean(item.message, 1_024))
                add("Action: " .. clean(item.action, 1_024))
            end
        end
    end
    scan(result.diagnostics)
    for _, child in result.children or {} do scan(child.diagnostics) end
end

local function observedSignals(record, project, add)
    local scalars = record.scalars
    local queueReports = {}
    for _, code in QUEUE_CODES do
        local count = scalars["queue." .. code]
        if finite(count) and count > 0 then table.insert(queueReports, code .. " x" .. number(count)) end
    end
    local queueObserved = #queueReports > 0
    if queueObserved then
        add("Queue pressure observed in retained rejection data: " .. table.concat(queueReports, ", ") .. ".")
    else
        for _, code in QUEUE_CODES do
            if string.find(record.liveText, code .. " x", 1, true) then
                queueObserved = true
                add("Queue pressure observed: " .. code .. " appears in the live rejection report.")
                break
            end
        end
    end
    if queueObserved then
        local action = "Action: inspect queue capacity and run the relevant portable scenario."
        if project and project.tests and #project.tests > 0 then
            action ..= " Scenario path: " .. clean(project.tests[1], 1_024) .. "."
        end
        add(action)
    end

    local mismatchCount = scalars["failure.DefinitionMismatch"]
    local mismatchLine = "\n" .. record.liveText .. "\n"
    local mismatchText = false
    for _, stage in START_FAILURE_STAGES do
        if string.find(mismatchLine, "\n  Last start failure: " .. stage .. " [DefinitionMismatch]\n", 1, true) then
            mismatchText = true
            break
        end
    end
    if (finite(mismatchCount) and mismatchCount > 0)
        or mismatchText then
        add("Startup mismatch observed: DefinitionMismatch.")
        add("Action: compare the application declaration with the captured schema check; refresh registration after verified changes.")
    end

    for _, refusal in REFUSALS do
        local count = scalars[refusal[1]]
        if finite(count) and count > 0 then
            local category = refusal[3]
            local hint = if category == "endpoint" then " Review endpoint IDs and the inbound policy."
                elseif category == "byte" then " Review modeled byte budgets and the configured workload."
                else " Review inbound call-rate policy and workload assumptions."
            if project and project.policy then hint ..= " Policy path: " .. clean(project.policy, 1_024) .. "." end
            if project and project.workload then hint ..= " Workload path: " .. clean(project.workload, 1_024) .. "." end
            add(refusal[2] .. ": " .. number(count) .. ". Action:" .. hint)
        end
    end

end

local function validCounter(value)
    return finite(value) and value >= 0 and value % 1 == 0 and value < COUNTER_LIMIT
end

local function counterRate(current, previous, elapsed)
    if current == nil or previous == nil then return "unavailable (counter missing)" end
    if not finite(current) or not finite(previous) or current < 0 or previous < 0
        or current % 1 ~= 0 or previous % 1 ~= 0 then
        return "unavailable (counter invalid)"
    elseif current >= COUNTER_LIMIT or previous >= COUNTER_LIMIT then
        return "unavailable (counter saturated)"
    elseif current < previous then
        return "unavailable (counter reset)"
    end
    local rate = (current - previous) / elapsed
    return if finite(rate) then number(rate) else "unavailable (rate is not finite)"
end

local function rates(record, previous, add)
    if previous == nil then
        add("Rates unavailable: previous same-session sample is missing.")
        return
    elseif not Structured.validate(previous) then
        add("Rates unavailable: previous structured sample is invalid.")
        return
    elseif record.sessionId ~= previous.sessionId then
        add("Rates unavailable: the attachment/session was replaced.")
        return
    elseif record.scalars.side ~= previous.scalars.side then
        add("Rates unavailable: samples are from different DataModel sides.")
        return
    end

    local elapsed = record.elapsed - previous.elapsed
    if not finite(elapsed) or elapsed <= 0 then
        add("Rates unavailable: same-session elapsed delta is not positive.")
        return
    end
    add("Same-session rates over " .. number(elapsed) .. " elapsed seconds:")
    for _, channel in { "Reliable", "Unreliable" } do
        for _, counter in { "sentBytes", "receivedBytes" } do
            local key = "traffic." .. channel .. "." .. counter
            add("  " .. channel .. " " .. counter .. ": "
                .. counterRate(record.scalars[key], previous.scalars[key], elapsed)
                .. (if record.scalars[key] ~= nil and previous.scalars[key] ~= nil
                    and validCounter(record.scalars[key]) and validCounter(previous.scalars[key])
                    and record.scalars[key] >= previous.scalars[key] then " modeled content units/sec" else ""))
        end
    end
    local current, old = record.scalars["session.outboundBytesCharged"], previous.scalars["session.outboundBytesCharged"]
    add("  outboundBytesCharged: " .. counterRate(current, old, elapsed)
        .. (if current ~= nil and old ~= nil and validCounter(current) and validCounter(old) and current >= old
            then " reservation units/sec" else ""))
end

local function render(record, capturedResult, previousRecord)
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

    add("Live diagnosis (advisory; no deployment, receipt, wire, or CPU proof).")
    local validRecord = Structured.validate(record)
    local validResult = Result.validate(capturedResult)
    if validResult then
        add("Captured check status: " .. capturedResult.status .. ".")
        if capturedResult.status == "unsupported" then
            add("A required capability is unsupported; no pass is claimed.")
        elseif capturedResult.status == "stale" then
            add("This check is stale; rerun it before using its paths or diagnosis.")
        end
    end
    local project = projectProjection(capturedResult, validResult)
    local linked = associationProblem(record, validRecord, capturedResult, project, add)
    if validRecord then
        add("Session: " .. clean(record.label, 48) .. " | " .. record.scalars.side .. " | " .. record.scalars.state
            .. " | sessionId " .. record.sessionId)
        local inFlight = record.scalars.inFlight
        add("In-flight handlers: " .. (if finite(inFlight) and inFlight >= 0 then number(inFlight) else "Unknown")
            .. " (gauge, not a rate).")
        observedSignals(record, if linked then project else nil, add)
    end
    projectPaths(project, validResult, linked, add)
    if validRecord then
        add("Declared endpoint rows:")
        for _, endpoint in record.inspection.events do
            if not add(string.format("  event #%s %s | %s | %s", number(endpoint.id), clean(endpoint.name, 32),
                endpoint.direction, endpoint.delivery)) then break end
        end
        for _, endpoint in record.inspection.requests do
            if not add(string.format("  request #%s %s | %s", number(endpoint.id), clean(endpoint.name, 32),
                endpoint.direction)) then break end
        end
    else
        add("Live diagnosis unavailable: structured record is absent or invalid.")
        add("Action: re-import a valid structured registration record.")
    end

    capturedDiagnostics(capturedResult, add)
    if validRecord then rates(record, previousRecord, add) end
    add("Rates use modeled content units/sec; outboundBytesCharged is reservation units/sec. No server/client clock alignment is implied.")

    return table.concat(lines, "\n") .. (if truncated then TRUNCATED else "")
end

return table.freeze({ render = render, MAX_TEXT_BYTES = MAX_TEXT_BYTES })
