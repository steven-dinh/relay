local ROOT_NAME = "RelayStudioInspector_v1"
local FORMAT_ATTRIBUTE = "RelayInspectorFormat"
local LABEL_ATTRIBUTE = "RelayInspectorLabel"
local MAX_ATTACHMENTS = 8
local MAX_PLAYERS = 64
local MAX_TEXT_BYTES = 65_536
local MAX_LAYOUT_WIDTH = 8_192
local MAX_LAYOUT_HEIGHT = 1_000_000

local toolbar = plugin:CreateToolbar("Relay")
local button = toolbar:CreateButton("RelayStudioInspector", "Toggle Relay Network Inspector", "")
local widget = plugin:CreateDockWidgetPluginGui("RelayStudioInspector",
    DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 420, 560, 320, 260))
widget.Title = "Relay Network Inspector"

local frame = Instance.new("Frame")
frame.Name = "Contents"
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.BorderSizePixel = 0
frame.Size = UDim2.fromScale(1, 1)
frame.Parent = widget

local selector = Instance.new("TextButton")
selector.Name = "NextSession"
selector.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
selector.BorderSizePixel = 0
selector.Font = Enum.Font.SourceSans
selector.Text = "No Relay snapshots"
selector.TextColor3 = Color3.fromRGB(240, 240, 240)
selector.TextSize = 16
selector.Size = UDim2.new(1, -12, 0, 30)
selector.Position = UDim2.fromOffset(6, 6)
selector.Parent = frame

local scrollingFrame = Instance.new("ScrollingFrame")
scrollingFrame.Name = "SnapshotScroll"
scrollingFrame.Active = true
scrollingFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
scrollingFrame.BorderSizePixel = 0
scrollingFrame.CanvasSize = UDim2.fromOffset(0, 0)
scrollingFrame.Position = UDim2.fromOffset(6, 42)
scrollingFrame.ScrollingDirection = Enum.ScrollingDirection.XY
scrollingFrame.ScrollBarThickness = 8
scrollingFrame.Size = UDim2.new(1, -12, 1, -48)
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
local connections = {}
local heartbeatConnection
local lastPoll = 0
local currentText = ""

local function setPanelText(text, resetScroll)
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

local function addRoot(parent, source)
    if parent == nil or #entries >= MAX_ATTACHMENTS then return end
    local root = parent:FindFirstChild(ROOT_NAME)
    if root == nil or root.ClassName ~= "Folder" or root:GetAttribute(FORMAT_ATTRIBUTE) ~= 1 then return end
    for index = 1, MAX_ATTACHMENTS do
        if #entries >= MAX_ATTACHMENTS then return end
        local value = root:FindFirstChild(string.format("Attachment%02d", index))
        if value ~= nil and value:IsA("StringValue") and value:GetAttribute(FORMAT_ATTRIBUTE) == 1 then
            local text = value.Value
            if type(text) == "string" then
                table.insert(entries, {
                    label = safeLabel(value:GetAttribute(LABEL_ATTRIBUTE), "Attachment " .. index),
                    source = source,
                    text = string.sub(text, 1, MAX_TEXT_BYTES),
                })
            end
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

local function showSelected(playersClipped, resetScroll)
    if #entries == 0 then
        selector.Text = "No Relay snapshots"
        setPanelText("No Relay inspector snapshots in this DataModel.\n"
            .. "Attach the development adapter and inspect the current server or client view.", resetScroll)
        return
    end

    selected = (selected - 1) % #entries + 1
    local entry = entries[selected]
    selector.Text = string.format("%d/%d  %s  (%s)", selected, #entries, entry.label, entry.source)
    local text = entry.text
    if playersClipped then text ..= "\nPlugin scan limited to the first 64 players." end
    setPanelText(text, resetScroll)
end

local function refresh(resetScroll)
    local playersClipped = scan()
    showSelected(playersClipped, resetScroll)
end

local function stopPolling()
    if heartbeatConnection ~= nil then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
end

local function startPolling()
    if heartbeatConnection ~= nil then return end
    lastPoll = os.clock()
    refresh(true)
    heartbeatConnection = game:GetService("RunService").Heartbeat:Connect(function()
        if not widget.Enabled then
            stopPolling()
            return
        end
        local now = os.clock()
        if now - lastPoll < 1 then return end
        lastPoll = now
        refresh(false)
    end)
end

table.insert(connections, button.Click:Connect(function()
    widget.Enabled = not widget.Enabled
end))
table.insert(connections, selector.Activated:Connect(function()
    if #entries > 1 then
        selected = selected % #entries + 1
        showSelected(false, true)
    else
        refresh(true)
    end
end))
table.insert(connections, widget:GetPropertyChangedSignal("Enabled"):Connect(function()
    button:SetActive(widget.Enabled)
    if widget.Enabled then startPolling() else stopPolling() end
end))
table.insert(connections, scrollingFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    if currentText ~= "" then setPanelText(currentText, false) end
end))

local function cleanup()
    stopPolling()
    for _, connection in connections do connection:Disconnect() end
    table.clear(connections)
    table.clear(entries)
    pcall(function() button:SetActive(false) end)
    pcall(function() widget:Destroy() end)
    pcall(function() button:Destroy() end)
    pcall(function() toolbar:Destroy() end)
end

table.insert(connections, plugin.Unloading:Connect(cleanup))
if widget.Enabled then startPolling() end
