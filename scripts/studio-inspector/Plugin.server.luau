local Workspace = require(if script then script.Workspace else "./Workspace")
local Structured = require(if script then script.Structured else "./Structured")
local Diagnosis = require(if script then script.Diagnosis else "./Diagnosis")

local ROOT_NAME = "RelayStudioInspector_v1"
local FORMAT_ATTRIBUTE = "RelayInspectorFormat"
local LABEL_ATTRIBUTE = "RelayInspectorLabel"
local MAX_ATTACHMENTS = 8
local MAX_PLAYERS = 64
local MAX_TEXT_BYTES = 65_536
local MAX_HISTORY_BYTES = 24_576
local MAX_HISTORY_SAMPLES = 16
local MAX_FILTER_BYTES = 32
local HISTORY_MARKER = "\n[Relay Inspector History]\n"
local SAMPLE_MARKER = "\n[Relay Inspector Sample]\n"
local MAX_LAYOUT_WIDTH = 8_192
local MAX_LAYOUT_HEIGHT = 1_000_000
local VIEWS = { "Sessions", "Diagnosis", "Overview", "Problems", "Schema", "Checks" }
local OVERVIEW_VIEW = 3
local MAX_PROJECTS = 4
local MAX_REPORT_BYTES = 4_194_304

local toolbar = plugin:CreateToolbar("Relay")
local button = toolbar:CreateButton("RelayStudioInspector", "Toggle Relay Tools", "")
local widget = plugin:CreateDockWidgetPluginGui("RelayStudioInspector",
    DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 420, 560, 320, 260))
widget.Title = "Relay Tools"

local frame = Instance.new("Frame")
frame.Name = "Contents"
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.BorderSizePixel = 0
frame.Size = UDim2.fromScale(1, 1)
frame.Parent = widget

local importButton = Instance.new("TextButton")
importButton.Name = "ImportReport"
importButton.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
importButton.BorderSizePixel = 0
importButton.Font = Enum.Font.SourceSans
importButton.Text = "Import report"
importButton.TextColor3 = Color3.fromRGB(240, 240, 240)
importButton.TextSize = 16
importButton.Size = UDim2.new(0, 132, 0, 30)
importButton.Position = UDim2.fromOffset(6, 6)
importButton.Parent = frame

local viewSelector = Instance.new("TextButton")
viewSelector.Name = "NextView"
viewSelector.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
viewSelector.BorderSizePixel = 0
viewSelector.Font = Enum.Font.SourceSans
viewSelector.Text = "View: Sessions"
viewSelector.TextColor3 = Color3.fromRGB(240, 240, 240)
viewSelector.TextSize = 16
viewSelector.Size = UDim2.new(1, -150, 0, 30)
viewSelector.Position = UDim2.fromOffset(144, 6)
viewSelector.Parent = frame

local selector = Instance.new("TextButton")
selector.Name = "NextSession"
selector.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
selector.BorderSizePixel = 0
selector.Font = Enum.Font.SourceSans
selector.Text = "No Relay snapshots"
selector.TextColor3 = Color3.fromRGB(240, 240, 240)
selector.TextSize = 16
selector.Size = UDim2.new(1, -154, 0, 30)
selector.Position = UDim2.fromOffset(6, 42)
selector.Parent = frame

local historySelector = Instance.new("TextButton")
historySelector.Name = "NextSample"
historySelector.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
historySelector.BorderSizePixel = 0
historySelector.Font = Enum.Font.SourceSans
historySelector.Text = "History: Live"
historySelector.TextColor3 = Color3.fromRGB(240, 240, 240)
historySelector.TextSize = 16
historySelector.Size = UDim2.new(0, 136, 0, 30)
historySelector.Position = UDim2.new(1, -142, 0, 42)
historySelector.Parent = frame

local endpointFilter = Instance.new("TextBox")
endpointFilter.Name = "EndpointFilter"
endpointFilter.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
endpointFilter.BorderSizePixel = 0
endpointFilter.ClearTextOnFocus = false
endpointFilter.Font = Enum.Font.SourceSans
endpointFilter.PlaceholderText = "Filter endpoints by name or #ID"
endpointFilter.Text = ""
endpointFilter.TextColor3 = Color3.fromRGB(240, 240, 240)
endpointFilter.TextSize = 16
endpointFilter.Size = UDim2.new(1, -12, 0, 26)
endpointFilter.Position = UDim2.fromOffset(6, 78)
endpointFilter.Parent = frame

local scrollingFrame = Instance.new("ScrollingFrame")
scrollingFrame.Name = "SnapshotScroll"
scrollingFrame.Active = true
scrollingFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
scrollingFrame.BorderSizePixel = 0
scrollingFrame.CanvasSize = UDim2.fromOffset(0, 0)
scrollingFrame.Position = UDim2.fromOffset(6, 110)
scrollingFrame.ScrollingDirection = Enum.ScrollingDirection.XY
scrollingFrame.ScrollBarThickness = 8
scrollingFrame.Size = UDim2.new(1, -12, 1, -116)
scrollingFrame.Parent = frame

local textBox = Instance.new("TextBox")
textBox.Name = "Snapshot"
textBox.BackgroundTransparency = 1
textBox.BorderSizePixel = 0
textBox.ClearTextOnFocus = false
textBox.Font = Enum.Font.Code
textBox.MultiLine = true
textBox.RichText = false
textBox.Text = ""
textBox.TextColor3 = Color3.fromRGB(230, 230, 230)
textBox.TextEditable = false
textBox.TextSize = 14
textBox.TextWrapped = false
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Position = UDim2.fromOffset(0, 0)
textBox.Parent = scrollingFrame

local entries = {}
local selected = 1
local selectedValue
local selectedSample = 0
local selectedSampleText
local connections = {}
local heartbeatConnection
local lastPoll = 0
local currentText = ""
local viewIndex = 1
local projects = {}
local selectedProject = 1
local reportBytes = 0
local importGeneration = 0
local importing = false
local importNotice
local observations = {}

local function sessionView()
    return viewIndex <= 2
end

local function setPanelText(text, resetScroll)
    if #text > MAX_TEXT_BYTES then text = string.sub(text, 1, MAX_TEXT_BYTES - 32) .. "\n[Panel text truncated]" end
    currentText = text
    textBox.Text = text
    local bounds = game:GetService("TextService"):GetTextSize(text, textBox.TextSize, textBox.Font,
        Vector2.new(MAX_LAYOUT_WIDTH, MAX_LAYOUT_HEIGHT))
    local width = math.max(bounds.X + 16, scrollingFrame.AbsoluteSize.X - 16)
    local height = math.max(bounds.Y + 16, scrollingFrame.AbsoluteSize.Y - 16)
    scrollingFrame.CanvasSize = UDim2.fromOffset(width, height)
    textBox.Size = UDim2.fromOffset(width, height)
    if resetScroll then scrollingFrame.CanvasPosition = Vector2.new(0, 0) end
end

local function safeLabel(value, fallback)
    if type(value) ~= "string" then return fallback end
    return string.sub(string.gsub(value, "[%c]", "?"), 1, 48)
end

local function showProject(resetScroll)
    viewSelector.Text = "View: " .. VIEWS[viewIndex]
    endpointFilter.Visible = false
    historySelector.Text = "Forget project"
    if #projects == 0 then
        selector.Text = "No captured projects"
        setPanelText(importNotice or "Import the JSON result of a Relay Tools command to open a project.\n"
            .. "CLI analysis is captured evidence. Studio semantic evaluation is unavailable.\n"
            .. "Use the native Luau editor for static feedback and Sessions for opt-in Play diagnostics.", resetScroll)
        return
    end
    selectedProject = (selectedProject - 1) % #projects + 1
    local project = projects[selectedProject]
    selector.Text = string.format("%d/%d  %s (captured)", selectedProject, #projects,
        safeLabel(project.result.projectId, "Project"))
    setPanelText(if importNotice then importNotice else Workspace.render(project.result, VIEWS[viewIndex]), resetScroll)
end

local function addRoot(parent, source)
    if parent == nil or #entries >= MAX_ATTACHMENTS then return end
    local root = parent:FindFirstChild(ROOT_NAME)
    if root == nil or root.ClassName ~= "Folder" or root:GetAttribute(FORMAT_ATTRIBUTE) ~= 1 then return end
    for index = 1, MAX_ATTACHMENTS do
        if #entries >= MAX_ATTACHMENTS then return end
        local value = root:FindFirstChild(string.format("Attachment%02d", index))
        if value ~= nil and value:IsA("StringValue") and value:GetAttribute(FORMAT_ATTRIBUTE) ~= nil then
            table.insert(entries, {
                value = value,
                label = safeLabel(value:GetAttribute(LABEL_ATTRIBUTE), "Attachment " .. index),
                source = source,
                format = value:GetAttribute(FORMAT_ATTRIBUTE),
            })
        end
    end
end

local function scan()
    table.clear(entries)
    local serverStorage = game:GetService("ServerStorage")
    addRoot(serverStorage, "ServerStorage")

    local players = game:GetService("Players"):GetPlayers()
    local playerLimit = math.min(#players, MAX_PLAYERS)
    for index = 1, playerLimit do
        local playerScripts = players[index]:FindFirstChild("PlayerScripts")
        addRoot(playerScripts, "PlayerScripts " .. index)
        if #entries >= MAX_ATTACHMENTS then break end
    end
    return #players > MAX_PLAYERS
end

local function decodeSnapshot(text)
    if type(text) ~= "string" then return "", {}, false end
    if #text > MAX_TEXT_BYTES then text = string.sub(text, 1, MAX_TEXT_BYTES) end
    local markerStart = string.find(text, HISTORY_MARKER, 1, true)
    if markerStart == nil then return text, {}, true end

    if #text - markerStart + 1 > MAX_HISTORY_BYTES then return text, {}, false end
    local encoded = string.sub(text, markerStart + #HISTORY_MARKER)
    if encoded == "" then return text, {}, false end
    local samples = {}
    local start = 1
    while true do
        if #samples >= MAX_HISTORY_SAMPLES then return text, {}, false end
        local separator = string.find(encoded, SAMPLE_MARKER, start, true)
        local finish = if separator == nil then #encoded else separator - 1
        local sample = string.sub(encoded, start, finish)
        if string.sub(sample, 1, 9) ~= "Sample t=" then return text, {}, false end
        table.insert(samples, sample)
        if separator == nil then break end
        start = separator + #SAMPLE_MARKER
    end
    return string.sub(text, 1, markerStart - 1), samples, true
end

local function decodeEntry(entry)
    if entry.format == 1 then
        local live, history, valid = decodeSnapshot(entry.value.Value)
        return "Association: unverified (independently attached definition/session).\n" .. live, history, valid
    end
    if entry.format ~= 2 then return "Unsupported Relay inspector format. Update the plugin to read this record.", {}, false end
    local record, issue = Structured.decode(function(bytes)
        return game:GetService("HttpService"):JSONDecode(bytes)
    end, entry.value.Value)
    if not record then return "Invalid structured inspector record: " .. issue, {}, false end
    local header = "Session: " .. record.sessionId .. " | " .. (record.namespace or "default namespace")
        .. "\nAssociation: constructed from the application's Relay/definition.\n"
        .. "Build/source identity: " .. record.identityStatus .. "; not independently verified.\n"
    if record.projectId then header ..= "Project: " .. record.projectId .. "\n" end
    return header .. record.liveText, record.history, true, record, header
end

local function filterEndpointRows(text)
    local query = string.lower(endpointFilter.Text)
    if query == "" then return text end
    local idQuery = string.match(query, "^#?(%d+)$")
    local lines = {}
    local matches = 0
    for _, line in string.split(text, "\n") do
        local kind, id, name = string.match(line, "^%s+(%a+) #(%d+) ([%w_]+)")
        if kind == "Event" or kind == "Request" then
            if (idQuery ~= nil and idQuery == id)
                or (idQuery == nil and string.find(string.lower(name), query, 1, true) ~= nil) then
                matches += 1
                table.insert(lines, line)
            end
        else
            table.insert(lines, line)
        end
    end
    if matches == 0 then table.insert(lines, "No matching endpoint rows in this snapshot.") end
    return table.concat(lines, "\n")
end

local function showSelected(playersClipped, resetScroll)
    viewSelector.Text = "View: " .. VIEWS[viewIndex]
    endpointFilter.Visible = true
    if #entries == 0 then
        selector.Text = "No Relay snapshots"
        historySelector.Text = "History: Live"
        setPanelText("No Relay inspector snapshots in this DataModel.\n"
            .. "Attach the development adapter and inspect the current server or client view.", resetScroll)
        return
    end

    selected = (selected - 1) % #entries + 1
    local entry = entries[selected]
    selector.Text = string.format("%d/%d  %s  (%s)", selected, #entries, entry.label, entry.source)
    local live, samples, _, record, header = decodeEntry(entry)
    if viewIndex == 2 then
        endpointFilter.Visible = false
        local captured = projects[selectedProject]
        historySelector.Text = if captured then "Project: " .. safeLabel(captured.result.projectId, "Unknown") else "No project report"
        if not record then
            setPanelText("Diagnosis requires a v2 registered session.\nUse Registration.createServer/createClient; manual v1 snapshots remain in Sessions.\n" .. live, resetScroll)
            return
        end
        local observation = observations[entry.value]
        if observation == nil or observation.current.sessionId ~= record.sessionId then
            observation = { current = record }
            observations[entry.value] = observation
        elseif observation.current.elapsed ~= record.elapsed then
            observation.previous = observation.current
            observation.current = record
        else
            observation.current = record
        end
        setPanelText(Diagnosis.render(record, if captured then captured.result else nil, observation.previous), resetScroll)
        return
    end
    selectedSample = 0
    if selectedSampleText ~= nil then
        for index, sample in samples do
            if sample == selectedSampleText then
                selectedSample = index
                break
            end
        end
        if selectedSample == 0 then selectedSampleText = nil end
    end
    local text = if selectedSample == 0 then live else selectedSampleText
    if selectedSample ~= 0 and record then text = header .. text end
    historySelector.Text = if #samples == 0 then "History: Live"
        elseif selectedSample == 0 then string.format("History: Live (%d)", #samples)
        else string.format("History %d/%d", selectedSample, #samples)
    if selectedSample == 1 and string.find(text, "^Sample t=0%.000s") == nil then
        text ..= "\nPreceding sample was evicted; deltas refer to that capture."
    end
    if selectedSample == 0 then text = filterEndpointRows(text) end
    if playersClipped then text ..= "\nPlugin scan limited to the first 64 players." end
    setPanelText(text, resetScroll)
end

local function refresh(resetScroll)
    if not sessionView() then showProject(resetScroll); return end
    local playersClipped = scan()
    local retained = {}
    for _, entry in entries do retained[entry.value] = true end
    for value in observations do if not retained[value] then observations[value] = nil end end
    local found = false
    if selectedValue ~= nil then
        for index, entry in entries do
            if entry.value == selectedValue then
                selected = index
                found = true
                break
            end
        end
    end
    if not found then
        selected = 1
        selectedValue = if #entries == 0 then nil else entries[1].value
        selectedSample = 0
        selectedSampleText = nil
    end
    showSelected(playersClipped, resetScroll)
end

local function stopPolling()
    if heartbeatConnection ~= nil then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
end

local function clearPanel()
    table.clear(entries)
    table.clear(observations)
    selected = 1
    selectedValue = nil
    selectedSample = 0
    selectedSampleText = nil
    selector.Text = "No Relay snapshots"
    historySelector.Text = "History: Live"
    endpointFilter.Text = ""
    setPanelText("", true)
end

local function closePanel()
    importGeneration += 1
    stopPolling()
    clearPanel()
end

local function startPolling()
    if heartbeatConnection ~= nil then return end
    lastPoll = os.clock()
    refresh(true)
    heartbeatConnection = game:GetService("RunService").Heartbeat:Connect(function()
        if not widget.Enabled then
            closePanel()
            return
        end
        local now = os.clock()
        if now - lastPoll < 1 then return end
        lastPoll = now
        if sessionView() then refresh(false) end
    end)
end

table.insert(connections, button.Click:Connect(function()
    widget.Enabled = not widget.Enabled
end))
table.insert(connections, selector.Activated:Connect(function()
    if not sessionView() then
        selectedProject += 1
        importNotice = nil
        showProject(true)
        return
    end
    if #entries > 1 then
        selected = selected % #entries + 1
        selectedValue = entries[selected].value
        selectedSample = 0
        selectedSampleText = nil
        showSelected(false, true)
    else
        refresh(true)
    end
end))
table.insert(connections, historySelector.Activated:Connect(function()
    if viewIndex == 2 then
        if #projects > 0 then selectedProject = selectedProject % #projects + 1 end
        showSelected(false, true)
        return
    elseif not sessionView() then
        if projects[selectedProject] then
            reportBytes -= projects[selectedProject].bytes
            table.remove(projects, selectedProject)
        end
        importNotice = nil
        showProject(true)
        return
    end
    if #entries == 0 then return end
    local _, samples = decodeEntry(entries[selected])
    if #samples > 0 then
        local currentSample = 0
        if selectedSampleText ~= nil then
            for index, sample in samples do
                if sample == selectedSampleText then currentSample = index; break end
            end
            if currentSample == 0 then
                selectedSample = 0
                selectedSampleText = nil
                showSelected(false, true)
                return
            end
        end
        selectedSample = (currentSample + 1) % (#samples + 1)
        selectedSampleText = if selectedSample == 0 then nil else samples[selectedSample]
    end
    showSelected(false, true)
end))
table.insert(connections, endpointFilter:GetPropertyChangedSignal("Text"):Connect(function()
    local bounded = string.sub(endpointFilter.Text, 1, MAX_FILTER_BYTES)
    if endpointFilter.Text ~= bounded then
        endpointFilter.Text = bounded
    end
    if viewIndex == 1 and #entries > 0 then showSelected(false, true) end
end))
table.insert(connections, viewSelector.Activated:Connect(function()
    viewIndex = viewIndex % #VIEWS + 1
    importNotice = nil
    refresh(true)
end))
table.insert(connections, importButton.Activated:Connect(function()
    if importing then return end
    importing = true
    importGeneration += 1
    local generation = importGeneration
    local ok, result, size = pcall(function()
        local file = game:GetService("StudioService"):PromptImportFileAsync({ "json" })
        if file == nil then return nil end
        assert(file.Size <= MAX_REPORT_BYTES, "Report exceeds the 4 MiB input limit.")
        local bytes = file:GetBinaryContents()
        local captured, issue = Workspace.decode(bytes, function(value)
            return game:GetService("HttpService"):JSONDecode(value)
        end)
        assert(captured, issue)
        return captured, #bytes
    end)
    importing = false
    if generation ~= importGeneration or not widget.Enabled then return end
    if not ok then
        importNotice = "Report import failed. Select a valid Relay Tools JSON result of at most 4 MiB.\n"
            .. safeLabel(tostring(result), "Invalid report")
        viewIndex = OVERVIEW_VIEW
    elseif result ~= nil then
        local replacement
        for index, project in projects do
            if project.result.projectId == result.projectId then replacement = index; break end
        end
        local retained = reportBytes - (if replacement then projects[replacement].bytes else 0) + size
        if retained > MAX_REPORT_BYTES or (replacement == nil and #projects >= MAX_PROJECTS) then
            importNotice = "Captured project limit reached (4 projects / 4 MiB total). Forget a project and import again."
        else
            selectedProject = replacement or #projects + 1
            projects[selectedProject] = { result = result, bytes = size }
            reportBytes = retained
            importNotice = nil
        end
        viewIndex = OVERVIEW_VIEW
    end
    refresh(true)
end))
table.insert(connections, widget:GetPropertyChangedSignal("Enabled"):Connect(function()
    button:SetActive(widget.Enabled)
    if widget.Enabled then startPolling() else closePanel() end
end))
table.insert(connections, scrollingFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    if currentText ~= "" then setPanelText(currentText, false) end
end))

local function cleanup()
    closePanel()
    for _, connection in connections do connection:Disconnect() end
    table.clear(connections)
    table.clear(projects)
    reportBytes = 0
    pcall(function() button:SetActive(false) end)
    pcall(function() widget:Destroy() end)
    pcall(function() button:Destroy() end)
    pcall(function() historySelector:Destroy() end)
    pcall(function() toolbar:Destroy() end)
end

table.insert(connections, plugin.Unloading:Connect(cleanup))
if widget.Enabled then startPolling() end
