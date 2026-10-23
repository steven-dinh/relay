local Snapshot = require(if script then script.Parent.Snapshot else "./Snapshot")

local ROOT_NAME = "RelayStudioInspector_v1"
local FORMAT_ATTRIBUTE = "RelayInspectorFormat"
local LABEL_ATTRIBUTE = "RelayInspectorLabel"
local MAX_ATTACHMENTS = 8
local SAMPLE_SECONDS = 1
local COUNTER_LIMIT = Snapshot.COUNTER_LIMIT

local function slotName(index)
    return string.format("Attachment%02d", index)
end

local function cleanLabel(label)
    if type(label) ~= "string" then label = "Relay session" end
    local cleaned = string.sub(string.gsub(label, "[^%w_.%-]", "_"), 1, 48)
    return if cleaned == "" then "Relay session" else cleaned
end

local function terminal(state)
    return state == "Destroyed" or state == "Disconnected"
end

local function Attach(Relay, definition, session, label)
    if game == nil then return nil, "NotStudio" end
    local ok, runService, isStudio = pcall(function()
        local service = game:GetService("RunService")
        return service, service:IsStudio()
    end)
    if not ok or isStudio ~= true then return nil, "NotStudio" end

    if type(Relay) ~= "table" or type(Relay.inspect) ~= "function" then return nil, "InvalidRelay" end
    if type(session) ~= "table" or type(session.GetDiagnostics) ~= "function" then
        return nil, "InvalidSession"
    end

    local inspected, report = pcall(Relay.inspect, definition)
    if not inspected or type(report) ~= "table" then return nil, "InvalidDefinition" end

    local readOk, initial = pcall(function() return session:GetDiagnostics() end)
    if not readOk or type(initial) ~= "table" then return nil, "InvalidSession" end
    if terminal(initial.state) then return nil, "TerminalSession" end

    local parent
    if initial.side == "Server" and runService:IsServer() then
        parent = game:GetService("ServerStorage")
    elseif initial.side == "Client" and runService:IsClient() then
        local players = game:GetService("Players")
        local player = players.LocalPlayer
        local playerScripts = if player == nil then nil else player:FindFirstChild("PlayerScripts")
        if playerScripts == nil then return nil, "MissingPlayerScripts" end
        parent = playerScripts
    else
        return nil, "UnsupportedRuntimeSide"
    end

    local root = parent:FindFirstChild(ROOT_NAME)
    if root == nil then
        root = Instance.new("Folder")
        root.Name = ROOT_NAME
        root:SetAttribute(FORMAT_ATTRIBUTE, 1)
        root.Parent = parent
    elseif root.ClassName ~= "Folder" or root:GetAttribute(FORMAT_ATTRIBUTE) ~= 1 then
        return nil, "VersionConflict"
    end

    local count, freeName = 0, nil
    for index = 1, MAX_ATTACHMENTS do
        local name = slotName(index)
        local existing = root:FindFirstChild(name)
        if existing == nil then
            freeName = freeName or name
        elseif existing:IsA("StringValue") and existing:GetAttribute(FORMAT_ATTRIBUTE) == 1 then
            count += 1
        end
    end
    if count >= MAX_ATTACHMENTS or freeName == nil then
        if #root:GetChildren() == 0 then root:Destroy() end
        return nil, "AttachmentLimit"
    end

    local safeLabel = cleanLabel(label)
    local value = Instance.new("StringValue")
    value.Name = freeName
    value:SetAttribute(FORMAT_ATTRIBUTE, 1)
    value:SetAttribute(LABEL_ATTRIBUTE, safeLabel)

    local currentSession = session
    local cachedDiagnostics
    local lastText
    local history = {}
    local previousScalars
    local statusNotice
    local heartbeatConnection
    local ancestryConnection
    local detached = false
    local destroyed = false
    local failures = {}

    local function removeEmptyRoot()
        if root.Parent == parent and root:GetAttribute(FORMAT_ATTRIBUTE) == 1
            and #root:GetChildren() == 0 then
            root:Destroy()
        end
    end

    local function setText(text)
        assert(#text <= Snapshot.MAX_BYTES, "inspector snapshot exceeds its byte limit")
        lastText = text
        if not destroyed and not detached and value.Parent == root then
            value.Value = lastText
        end
    end

    local function render(diagnostics, samples)
        local formatOk, text = pcall(Snapshot.formatWithHistory, report, diagnostics, safeLabel, failures,
            if samples == nil then history else samples, statusNotice)
        if formatOk and type(text) == "string" then
            setText(text)
            return true
        end
        return false
    end

    local function stopSampler()
        currentSession = nil
        if heartbeatConnection ~= nil then
            heartbeatConnection:Disconnect()
            heartbeatConnection = nil
        end
    end

    local function detach()
        if detached then return end
        detached = true
        stopSampler()
        if ancestryConnection ~= nil then
            ancestryConnection:Disconnect()
            ancestryConnection = nil
        end
        removeEmptyRoot()
        pcall(function() value.Value = "" end)
        cachedDiagnostics = nil
        report = nil
        safeLabel = nil
        previousScalars = nil
        statusNotice = nil
        lastText = nil
        table.clear(history)
        table.clear(failures)
    end

    local function stopWithNotice(notice)
        statusNotice = notice
        if cachedDiagnostics ~= nil then render(cachedDiagnostics) end
        stopSampler()
    end

    local function sample(elapsedSeconds)
        local activeSession = currentSession
        if activeSession == nil then return false end
        local sampleOk, diagnostics = pcall(function() return activeSession:GetDiagnostics() end)
        if not sampleOk or type(diagnostics) ~= "table" then
            stopWithNotice("\nSession sampling stopped: diagnostics unavailable; error text omitted.")
            return false
        end

        local historyOk, entry, scalars = pcall(Snapshot.historySample, diagnostics, failures,
            elapsedSeconds, previousScalars)
        if not historyOk or type(entry) ~= "string" or type(scalars) ~= "table" then
            stopWithNotice("\nSession sampling stopped: invalid diagnostics; details omitted.")
            return false
        end

        local nextHistory = table.clone(history)
        table.insert(nextHistory, entry)
        while #nextHistory > Snapshot.MAX_HISTORY_SAMPLES
            or Snapshot.historyBytes(nextHistory) > Snapshot.MAX_HISTORY_BYTES do
            table.remove(nextHistory, 1)
        end
        assert(#nextHistory > 0, "one inspector history sample must fit its byte limit")
        if not render(diagnostics, nextHistory) then
            stopWithNotice("\nSession sampling stopped: invalid diagnostics; details omitted.")
            return false
        end
        history = nextHistory
        previousScalars = scalars
        cachedDiagnostics = diagnostics
        if terminal(diagnostics.state) then
            stopSampler()
            return false
        end
        return true
    end

    local initialHistoryOk, initialEntry, initialScalars = pcall(Snapshot.historySample,
        initial, failures, 0, nil)
    local initialHistory = if initialHistoryOk and type(initialEntry) == "string" then { initialEntry } else {}
    local initialFormatOk, initialText = pcall(Snapshot.formatWithHistory,
        report, initial, safeLabel, failures, initialHistory, nil)
    if not initialHistoryOk or type(initialScalars) ~= "table"
        or not initialFormatOk or type(initialText) ~= "string" then
        if #root:GetChildren() == 0 then root:Destroy() end
        value:Destroy()
        return nil, "InvalidDiagnostics"
    end
    history = initialHistory
    previousScalars = initialScalars
    cachedDiagnostics = initial
    lastText = initialText
    value.Value = initialText
    value.Parent = root

    local clockOrigin = os.clock()
    if type(clockOrigin) ~= "number" or clockOrigin ~= clockOrigin or math.abs(clockOrigin) == math.huge then
        clockOrigin = 0
    end
    local lastClock = clockOrigin
    local lastSample = clockOrigin
    local lastElapsed = 0
    heartbeatConnection = runService.Heartbeat:Connect(function()
        if destroyed or detached or value.Parent ~= root or root.Parent ~= parent then
            detach()
            return
        end
        local now = os.clock()
        if type(now) ~= "number" or now ~= now or math.abs(now) == math.huge or now < lastClock then
            now = lastClock
        else
            lastClock = now
        end
        if now - lastSample < SAMPLE_SECONDS then return end
        lastSample = now
        local elapsed = now - clockOrigin
        if elapsed ~= elapsed or math.abs(elapsed) == math.huge then elapsed = Snapshot.MAX_ELAPSED_SECONDS end
        lastElapsed = math.max(lastElapsed, math.clamp(elapsed, 0, Snapshot.MAX_ELAPSED_SECONDS))
        sample(lastElapsed)
    end)
    ancestryConnection = value.AncestryChanged:Connect(function()
        if value.Parent ~= root or root.Parent ~= parent then detach() end
    end)

    local attachment = {}
    attachment.RecordFailure = function(_, issue)
        if destroyed or detached or not Snapshot.isFailureCode(issue) then return false end
        local countSoFar = failures[issue] or 0
        if countSoFar < COUNTER_LIMIT then failures[issue] = countSoFar + 1 end
        if cachedDiagnostics ~= nil then render(cachedDiagnostics) end
        return true
    end
    attachment.Destroy = function()
        if destroyed then return end
        destroyed = true
        stopSampler()
        if ancestryConnection ~= nil then
            ancestryConnection:Disconnect()
            ancestryConnection = nil
        end
        if value.Parent == root then
            pcall(function() value.Value = "" end)
            value:Destroy()
        end
        removeEmptyRoot()
        currentSession = nil
        cachedDiagnostics = nil
        report = nil
        safeLabel = nil
        previousScalars = nil
        statusNotice = nil
        lastText = nil
        table.clear(history)
        table.clear(failures)
    end
    return table.freeze(attachment), nil
end

return table.freeze({ Attach = Attach })
