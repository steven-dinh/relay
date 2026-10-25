local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Definition = require("../src/Definition")
local Diagnostics = require("../src/internal/Diagnostics")
local Snapshot = require("../scripts/studio-inspector/Snapshot")
local HISTORY_MARKER = "\n[Relay Inspector History]\n"
local SAMPLE_MARKER = "\n[Relay Inspector Sample]\n"

local function retainedHistory(text)
    local start = string.find(text, HISTORY_MARKER, 1, true)
    if start == nil then return "", 0 end
    local encoded = string.sub(text, start)
    local count = 1
    local offset = 1
    while true do
        local nextSample = string.find(encoded, SAMPLE_MARKER, offset, true)
        if nextSample == nil then break end
        count += 1
        offset = nextSample + #SAMPLE_MARKER
    end
    return encoded, count
end

local definition = assert(Definition.define({
    name = "InspectorTest",
    version = 2,
    readiness = false,
    events = {
        Zulu = { id = 2, direction = "ServerToClient", fields = {} },
        Alpha = { id = 1, direction = "ClientToServer", fields = {
            { name = "value", type = "u16", maximum = 7 },
        } },
    },
    requests = {
        Lookup = { id = 3, request = {}, response = { type = "boolean" } },
    },
}))
local compiled = Definition.get(definition)
local report = assert(Definition.inspect(definition))

local function newDiagnostics(side, options)
    return Diagnostics.create(compiled.events, side, nil,
        if side == "Server" then { global = 64, perPlayer = 8, perPlayerEndpoint = 1 }
        else { perEndpoint = 1 }, nil, compiled.requests, options)
end

local raw = newDiagnostics("Server", { traffic = true, reports = true })
Diagnostics.addTraffic(raw, 2, "Reliable", "sentPackets", 4)
Diagnostics.addTraffic(raw, 3, "Unreliable", "sentPackets", 7)
Diagnostics.add(raw.counters, "outboundBytesCharged", 96)
Diagnostics.increment(raw.counters, "invalidEndpoint")
Diagnostics.increment(raw.events.Alpha, "busy")
Diagnostics.report(raw, "Busy", 1, "Reliable")
local serverSnapshot = Diagnostics.snapshot(raw, "Started", 5)
local text = Snapshot.format(report, serverSnapshot, "Demo", { ReadinessDisabled = 2 })

assert(string.find(text, "Event #2 Zulu | ServerToClient", 1, true))
assert(string.find(text, "Event #1 Alpha | ClientToServer", 1, true))
assert(string.find(text, "Request #3 Lookup | ClientToServer", 1, true))
assert(string.find(text, "Event #2 Zulu / Reliable", 1, true))
assert(string.find(text, "Request #3 Lookup / Unreliable", 1, true))
assert(string.find(text, "sentPackets=4", 1, true) and string.find(text, "sentPackets=7", 1, true))
assert(string.find(text, "outboundBytesCharged=96", 1, true))
assert(string.find(text, "inFlight 5 (global active Relay leases)", 1, true))
assert(string.find(text, "Traffic *Bytes fields use modeled content units", 1, true))
assert(string.find(text, "local successful handoffs, not receipts", 1, true))
assert(string.find(text, "Busy x1", 1, true) and string.find(text, "ReadinessDisabled=2", 1, true))
assert(not Snapshot.isFailureCode("Free-form error text"), "failure recording accepts only allowlisted codes")

local clientSnapshot = Diagnostics.snapshot(newDiagnostics("Client", { traffic = true }), "Created", 0)
local clientText = Snapshot.format(report, clientSnapshot, "Client", { StartupTimeout = 1 })
assert(string.find(clientText, "side Client", 1, true)
    and string.find(clientText, "perEndpoint=1", 1, true)
    and string.find(clientText, "StartupTimeout=1", 1, true))

local disabledSnapshot = Diagnostics.snapshot(newDiagnostics("Server"), "Created", 0)
local disabledText = Snapshot.format(report, disabledSnapshot, "No reports", {})
assert(string.find(disabledText, "Rejection reports disabled", 1, true)
    and string.find(disabledText, "Event counters:", 1, true)
    and string.find(disabledText, "ineligible=0", 1, true))

local oversized = table.clone(report)
oversized.name = string.rep("X", 70_000)
local truncated = Snapshot.format(oversized, serverSnapshot, "Large", {})
assert(#truncated <= Snapshot.MAX_BYTES and string.find(truncated, "snapshot truncated", 1, true))

local historyBase = {
    side = "Server", state = "Started", inFlight = 4,
    counters = { received = 10, invalidPayload = 4 },
    reports = { total = 2, entries = { { reason = "PRIVATE_REASON" } } },
    traffic = nil, payload = "PRIVATE_PAYLOAD", endpoint = "PRIVATE_ENDPOINT",
}
local firstSample, firstScalars = Snapshot.historySample(historyBase, { ReadinessDisabled = 1 }, 0, nil)
assert(string.find(firstSample, "t=0.000s (os.clock elapsed seconds)", 1, true)
    and string.find(firstSample, "state=Started (baseline)", 1, true)
    and string.find(firstSample, "session.received=10 | delta=baseline", 1, true))
assert(not string.find(firstSample, "PRIVATE_", 1, true), "history retains allowlisted scalar fields only")
assert(not pcall(function() firstScalars["session.received"] = 99 end), "copied history scalars are immutable")
historyBase.counters.received = 99
assert(firstScalars["session.received"] == 10 and string.find(firstSample, "session.received=10", 1, true),
    "mutating source diagnostics cannot change retained scalar samples")

local nextHistoryDiagnostics = {
    side = "Server", state = "Disconnected", inFlight = 1,
    counters = { received = 12, invalidPayload = 0 },
    reports = { total = 5 },
    traffic = { channels = { Reliable = { sentPackets = 9 } } },
}
local nextSample = Snapshot.historySample(nextHistoryDiagnostics,
    { ReadinessDisabled = 3 }, 1.25, firstScalars)
assert(string.find(nextSample, "state=Disconnected (from Started)", 1, true)
    and string.find(nextSample, "inFlight=1 | delta=-3", 1, true)
    and string.find(nextSample, "session.received=12 | delta=+2", 1, true)
    and string.find(nextSample, "session.invalidPayload=0 | delta=reset", 1, true)
    and string.find(nextSample, "traffic.Reliable.sentPackets=9 | delta=unavailable", 1, true)
    and string.find(nextSample, "reports.total=5 | delta=+3", 1, true),
    "adjacent deltas handle gauges, counters, resets, and newly enabled diagnostics")

local beforeSaturation = table.clone(nextHistoryDiagnostics)
beforeSaturation.counters = { received = Snapshot.COUNTER_LIMIT - 1 }
local _, beforeSaturationScalars = Snapshot.historySample(beforeSaturation, {}, 2, nil)
local atSaturation = table.clone(beforeSaturation)
atSaturation.counters = { received = Snapshot.COUNTER_LIMIT }
local saturatedSample, saturatedScalars = Snapshot.historySample(atSaturation, {}, 3, beforeSaturationScalars)
assert(string.find(saturatedSample, "session.received=4294967295 (saturated) | delta=at least 1", 1, true))
local stillSaturated = Snapshot.historySample(atSaturation, {}, 4, saturatedScalars)
assert(string.find(stillSaturated, "delta=at least 0", 1, true), "saturated counters never claim an exact delta")
local afterReset = table.clone(atSaturation)
afterReset.counters = { received = 5 }
local resetSample = Snapshot.historySample(afterReset, {}, 5, saturatedScalars)
assert(string.find(resetSample, "session.received=5 | delta=reset", 1, true))

local oversizedWithHistory = Snapshot.formatWithHistory(oversized, serverSnapshot, "Large",
    { ReadinessDisabled = 4 }, { firstSample, nextSample })
local encodedHistory = retainedHistory(oversizedWithHistory)
assert(#oversizedWithHistory <= Snapshot.MAX_BYTES and #encodedHistory <= Snapshot.MAX_HISTORY_BYTES
    and string.find(oversizedWithHistory, "snapshot truncated", 1, true)
    and string.find(oversizedWithHistory, "Observed API failures: ReadinessDisabled=4", 1, true),
    "live output reserves the complete history framing and keeps the failure summary before truncation")

local function signal()
    local result = { connections = {} }
    function result:Connect(callback)
        local connection = { active = true, callback = callback }
        function connection:Disconnect() self.active = false end
        table.insert(self.connections, connection)
        return connection
    end
    function result:Fire(...)
        for _, connection in self.connections do
            if connection.active then connection.callback(...) end
        end
    end
    function result:activeCount()
        local count = 0
        for _, connection in self.connections do if connection.active then count += 1 end end
        return count
    end
    return result
end

local function mockInstance(className)
    local instance = {
        ClassName = className,
        Name = "",
        _parent = nil,
        _children = {},
        _attributes = {},
        _propertySignals = {},
        _destroyed = false,
        AbsoluteSize = { X = 420, Y = 560 },
        AncestryChanged = signal(),
        Destroying = signal(),
        Activated = signal(),
    }

    local function fireAncestry(root)
        root.AncestryChanged:Fire(root, root.Parent)
        for _, child in root._children do fireAncestry(child) end
    end

    function instance:IsA(name) return self.ClassName == name end
    function instance:FindFirstChild(name)
        for _, child in self._children do if child.Name == name then return child end end
        return nil
    end
    function instance:GetChildren() return table.clone(self._children) end
    function instance:SetAttribute(name, value) self._attributes[name] = value end
    function instance:GetAttribute(name) return self._attributes[name] end
    function instance:GetPropertyChangedSignal(name)
        local changed = self._propertySignals[name]
        if changed == nil then
            changed = signal()
            self._propertySignals[name] = changed
        end
        return changed
    end
    function instance:SetProperty(name, value)
        rawset(self, name, value)
        local changed = self._propertySignals[name]
        if changed ~= nil then changed:Fire() end
    end
    function instance:Destroy()
        self._destroyed = true
        self.Destroying:Fire()
        for _, child in table.clone(self._children) do child:Destroy() end
        self.Parent = nil
    end

    return setmetatable(instance, {
        __index = function(self, key)
            if key == "Parent" then return rawget(self, "_parent") end
            return nil
        end,
        __newindex = function(self, key, value)
            if key ~= "Parent" then rawset(self, key, value); return end
            local old = rawget(self, "_parent")
            if old == value then return end
            if old ~= nil then
                for index, child in old._children do
                    if child == self then table.remove(old._children, index); break end
                end
            end
            rawset(self, "_parent", value)
            if value ~= nil then table.insert(value._children, self) end
            fireAncestry(self)
        end,
    })
end

local serverStorage = mockInstance("ServerStorage")
local playerScripts = mockInstance("Folder")
playerScripts.Name = "PlayerScripts"
local localPlayer = mockInstance("Player")
function localPlayer:FindFirstChild(name)
    if name == "PlayerScripts" then return playerScripts end
    return nil
end
local players = { LocalPlayer = localPlayer }
function players:GetPlayers() return self.list or {} end
local heartbeat = signal()
local runService = { Heartbeat = heartbeat, studio = true, client = false }
function runService:IsStudio() return self.studio end
function runService:IsClient() return self.client end
function runService:IsServer()
    if self.serverOverride ~= nil then return self.serverOverride end
    return not self.client
end
local gameMock = {}
function gameMock:GetService(name)
    if name == "RunService" then return runService end
    if name == "ServerStorage" then return serverStorage end
    if name == "Players" then return players end
    error("unexpected service " .. name)
end
local Instance = { new = mockInstance }
local clock = 0
local osMock = { clock = function() return clock end }
local attachmentSource = fs.readFile("scripts/studio-inspector/Attachment.luau")
local loadAttachment = luau.load(attachmentSource, {
    environment = {
        script = nil,
        game = gameMock,
        Instance = Instance,
        os = osMock,
        require = function(path)
            assert(path == "./Snapshot")
            return Snapshot
        end,
    },
    injectGlobals = true,
})
local Attachment = loadAttachment()

local function sessionWith(stateGetter)
    local session = { calls = 0 }
    function session:GetDiagnostics()
        self.calls += 1
        return stateGetter()
    end
    return session
end

local studioSession = sessionWith(function() return Diagnostics.snapshot(raw, "Started", 0) end)
runService.studio = false
local noStudio, noStudioError = Attachment.Attach(false, nil, false, "No")
assert(noStudio == nil and noStudioError == "NotStudio", "Studio guard precedes Relay and session access")
runService.studio = true
local invalidPrimitive, primitiveError = Attachment.Attach(Definition, definition, false, "Bad")
assert(invalidPrimitive == nil and primitiveError == "InvalidSession", "primitive sessions are rejected")
local invalidDefinition, definitionError = Attachment.Attach(Definition, {}, studioSession, "Bad")
assert(invalidDefinition == nil and definitionError == "InvalidDefinition")

local absentPlayerSession = sessionWith(function() return clientSnapshot end)
runService.client = true
players.LocalPlayer = nil
local absent, absentError = Attachment.Attach(Definition, definition, absentPlayerSession, "Absent")
assert(absent == nil and absentError == "MissingPlayerScripts")

runService.serverOverride = true
local serverInDualRuntime = assert(Attachment.Attach(Definition, definition,
    sessionWith(function() return serverSnapshot end), "Dual runtime server"))
assert(serverStorage:FindFirstChild("RelayStudioInspector_v1") ~= nil
    and playerScripts:FindFirstChild("RelayStudioInspector_v1") == nil,
    "server diagnostics use ServerStorage when Studio reports both runtime sides")
serverInDualRuntime:Destroy()
runService.serverOverride = nil

players.LocalPlayer = localPlayer
runService.client = false
local incompatible, incompatibleError = Attachment.Attach(Definition, definition,
    sessionWith(function() return clientSnapshot end), "Wrong runtime side")
assert(incompatible == nil and incompatibleError == "UnsupportedRuntimeSide",
    "diagnostic side must match the available runtime side")
runService.client = true
local clientAttachment = assert(Attachment.Attach(Definition, definition,
    sessionWith(function() return clientSnapshot end), "Local client"))
local clientRoot = playerScripts:FindFirstChild("RelayStudioInspector_v1")
assert(clientRoot ~= nil and serverStorage:FindFirstChild("RelayStudioInspector_v1") == nil,
    "client diagnostics stay under local PlayerScripts")
clientAttachment:Destroy()
clientAttachment:Destroy()
assert(playerScripts:FindFirstChild("RelayStudioInspector_v1") == nil, "empty client root is removed")

runService.client = false
local mutableState = "Created"
local sampled = sessionWith(function() return Diagnostics.snapshot(raw, mutableState, 3) end)
local attachment = assert(Attachment.Attach(Definition, definition, sampled, "Demo"))
local root = serverStorage:FindFirstChild("RelayStudioInspector_v1")
local value = root:FindFirstChild("Attachment01")
assert(value ~= nil and #value.Value <= Snapshot.MAX_BYTES)
local initialHistory, initialHistoryCount = retainedHistory(value.Value)
assert(initialHistoryCount == 1 and #initialHistory <= Snapshot.MAX_HISTORY_BYTES)
assert(attachment:RecordFailure("ReadinessDisabled") and string.find(value.Value, "ReadinessDisabled=1", 1, true),
    "code-only failure updates the displayed snapshot without sampling")
local _, failureHistoryCount = retainedHistory(value.Value)
assert(failureHistoryCount == initialHistoryCount, "RecordFailure updates live text without sampling history")
assert(not attachment:RecordFailure("raw message"), "free-form issue strings are rejected")
assert(sampled.calls == 1, "RecordFailure does not invoke GetDiagnostics")

clock = 0.5
heartbeat:Fire(0.5)
assert(sampled.calls == 1, "sampling is no faster than once per second")
clock = 1
heartbeat:Fire(0.5)
assert(sampled.calls == 2)
local _, secondHistoryCount = retainedHistory(value.Value)
assert(secondHistoryCount == 2)
clock = 3
heartbeat:Fire(2)
assert(sampled.calls == 3, "delayed Heartbeat does not catch up")
local _, thirdHistoryCount = retainedHistory(value.Value)
assert(thirdHistoryCount == 3)
clock = 2
heartbeat:Fire(1)
assert(sampled.calls == 3, "backwards os.clock movement does not create or rewind a sample")
mutableState = "Destroyed"
clock = 4
heartbeat:Fire(1)
assert(sampled.calls == 4 and heartbeat:activeCount() == 0)
local terminalHistory, terminalHistoryCount = retainedHistory(value.Value)
assert(terminalHistoryCount == 4 and string.find(terminalHistory, "state=Destroyed (from Created)", 1, true),
    "terminal diagnostics become the final historical sample")
clock = 100
heartbeat:Fire(96)
assert(sampled.calls == 4, "terminal sessions release their sampler")
assert(string.find(value.Value, "state Destroyed", 1, true), "terminal text remains for postmortem inspection")
assert(attachment:RecordFailure("StartupTimeout"))
assert(string.find(value.Value, "StartupTimeout=1", 1, true), "postmortem code counts remain visible")
local _, terminalFailureHistoryCount = retainedHistory(value.Value)
assert(terminalFailureHistoryCount == terminalHistoryCount, "postmortem failure recording does not add history")
attachment:Destroy()
assert(value.Value == "", "Destroy clears retained snapshot text")
assert(serverStorage:FindFirstChild("RelayStudioInspector_v1") == nil, "destroy removes only empty owned root")

local compactDiagnostics = {
    side = "Server", state = "Started", inFlight = 0, counters = {}, events = {}, handlerLimits = {},
}
local countLimited = assert(Attachment.Attach(Definition, definition,
    sessionWith(function() return compactDiagnostics end), "Count bound"))
for _ = 1, 20 do
    clock += 1
    heartbeat:Fire(1)
end
local countBoundValue = serverStorage:FindFirstChild("RelayStudioInspector_v1"):FindFirstChild("Attachment01")
local countBoundText, countBoundSamples = retainedHistory(countBoundValue.Value)
assert(countBoundSamples == Snapshot.MAX_HISTORY_SAMPLES
    and #countBoundText <= Snapshot.MAX_HISTORY_BYTES, "history sample count remains capped at 16")
countLimited:Destroy()

local byteLimited = assert(Attachment.Attach(Definition, definition,
    sessionWith(function() return serverSnapshot end), "Byte bound"))
for _ = 1, 24 do
    clock += 1
    heartbeat:Fire(1)
end
local byteBoundValue = serverStorage:FindFirstChild("RelayStudioInspector_v1"):FindFirstChild("Attachment01")
local byteBoundText, byteBoundSamples = retainedHistory(byteBoundValue.Value)
assert(byteBoundSamples < Snapshot.MAX_HISTORY_SAMPLES
    and #byteBoundText <= Snapshot.MAX_HISTORY_BYTES and #byteBoundValue.Value <= Snapshot.MAX_BYTES,
    "encoded history byte cap evicts complete old samples and preserves the shared 64-KiB limit")
byteLimited:Destroy()

local capHandles = {}
local capSession = sessionWith(function() return serverSnapshot end)
for index = 1, 8 do
    capHandles[index] = assert(Attachment.Attach(Definition, definition, capSession, "Cap " .. index))
end
local ninth, capError = Attachment.Attach(Definition, definition, capSession, "Overflow")
assert(ninth == nil and capError == "AttachmentLimit", "at most eight attachments share one root")
for _, handle in capHandles do handle:Destroy() end
assert(serverStorage:FindFirstChild("RelayStudioInspector_v1") == nil)

local externalSession = sessionWith(function() return serverSnapshot end)
local external = assert(Attachment.Attach(Definition, definition, externalSession, "External"))
local externalRoot = serverStorage:FindFirstChild("RelayStudioInspector_v1")
local externalValue = externalRoot:FindFirstChild("Attachment01")
externalValue:Destroy()
assert(heartbeat:activeCount() == 0, "external value removal releases the sampler")
assert(externalValue.Value == "", "external removal clears retained snapshot text")
assert(not external:RecordFailure("ReadinessDisabled"), "detached attachments reject writes")
external:Destroy()
assert(serverStorage:FindFirstChild("RelayStudioInspector_v1") == nil, "external removal cleans the empty root")

local terminalSession = sessionWith(function() return Diagnostics.snapshot(raw, "Disconnected", 0) end)
local terminalAttachment, terminalError = Attachment.Attach(Definition, definition, terminalSession, "Terminal")
assert(terminalAttachment == nil and terminalError == "TerminalSession", "terminal sessions are not reattached")

local function pluginHarness(initialEnabled)
    local pluginMock = { Unloading = signal() }
    local pluginHeartbeat = signal()
    local pluginRunService = { Heartbeat = pluginHeartbeat }
    local textService = {}
    function textService:GetTextSize(content, textSize, _, bounds)
        local lines = 1
        for _ in string.gmatch(content, "\n") do lines += 1 end
        return { X = math.min(#content * 7, bounds.X), Y = lines * textSize }
    end

    function pluginMock:CreateToolbar(name)
        local toolbar = mockInstance("PluginToolbar")
        toolbar.Name = name
        function toolbar:CreateButton(name, _, _)
            local button = mockInstance("PluginToolbarButton")
            button.Name = name
            button.Click = signal()
            function button:SetActive(active) self.active = active end
            pluginMock.button = button
            return button
        end
        self.toolbar = toolbar
        return toolbar
    end
    function pluginMock:CreateDockWidgetPluginGui(name, _)
        local widget = mockInstance("DockWidgetPluginGui")
        widget.Name = name
        widget.Enabled = initialEnabled
        self.widget = widget
        return widget
    end

    local enumMeta
    enumMeta = {
        __index = function(value, key)
            local member = setmetatable({}, enumMeta)
            rawset(value, key, member)
            return member
        end,
    }
    local enum = setmetatable({}, enumMeta)
    local gameForPlugin = {}
    function gameForPlugin:GetService(name)
        if name == "ServerStorage" then return serverStorage end
        if name == "Players" then return players end
        if name == "RunService" then return pluginRunService end
        if name == "TextService" then return textService end
        error("unexpected plugin service " .. name)
    end

    local pluginEnvironment = {
        plugin = pluginMock,
        game = gameForPlugin,
        Instance = Instance,
        DockWidgetPluginGuiInfo = { new = function(...) return { ... } end },
        Enum = enum,
        Color3 = { fromRGB = function(...) return { ... } end },
        UDim2 = {
            fromScale = function(...) return { ... } end,
            fromOffset = function(...) return { ... } end,
            new = function(...) return { ... } end,
        },
        Vector2 = { new = function(x, y) return { X = x, Y = y } end },
        os = osMock,
    }
    local pluginSource = fs.readFile("scripts/studio-inspector/Plugin.server.luau")
    local loadPlugin = luau.load(pluginSource, { environment = pluginEnvironment, injectGlobals = true })
    loadPlugin()
    return pluginMock, pluginHeartbeat
end

local fixture = assert(Attachment.Attach(Definition, definition,
    sessionWith(function() return serverSnapshot end), "Plugin fixture"))
players.list = {}
clock = 200
local pluginMock, pluginHeartbeat = pluginHarness(false)
local widget = pluginMock.widget
local frame = widget:FindFirstChild("Contents")
local selector = frame:FindFirstChild("NextSession")
local historySelector = frame:FindFirstChild("NextSample")
local endpointFilter = frame:FindFirstChild("EndpointFilter")
local scrollingFrame = frame:FindFirstChild("SnapshotScroll")
local textBox = scrollingFrame:FindFirstChild("Snapshot")
assert(endpointFilter ~= nil, "plugin exposes a local endpoint filter")
assert(pluginHeartbeat:activeCount() == 0, "disabled saved widget starts without polling")
widget:SetProperty("Enabled", true)
assert(pluginHeartbeat:activeCount() == 1 and pluginMock.button.active, "enabling starts one poller")
assert(string.find(textBox.Text, "InspectorTest", 1, true)
    and string.find(textBox.Text, "Event #1 Alpha", 1, true)
    and string.find(textBox.Text, "Event #2 Zulu", 1, true)
    and string.find(textBox.Text, "Request #3 Lookup", 1, true),
    "enabled widget defaults to all endpoint details")
historySelector.Activated:Fire()
assert(historySelector.Text == "History 1/1" and string.find(textBox.Text, "Sample t=0.000s", 1, true),
    "history selection displays the initial baseline sample")
local initialSampleText = textBox.Text
endpointFilter:SetProperty("Text", "aLpHa")
assert(historySelector.Text == "History 1/1" and textBox.Text == initialSampleText,
    "changing the filter preserves the selected history sample")
historySelector.Activated:Fire()
assert(historySelector.Text == "History: Live (1)"
    and string.find(textBox.Text, "Event #1 Alpha", 1, true)
    and string.find(textBox.Text, "    Event #1 Alpha |", 1, true)
    and not string.find(textBox.Text, "Event #2 Zulu", 1, true)
    and not string.find(textBox.Text, "Request #3 Lookup", 1, true)
    and string.find(textBox.Text, "Busy x1", 1, true),
    "name filtering keeps matching endpoint rows and unrelated diagnostics")
endpointFilter:SetProperty("Text", "#3")
assert(string.find(textBox.Text, "Request #3 Lookup", 1, true)
    and string.find(textBox.Text, "Request #3 Lookup / Unreliable", 1, true)
    and not string.find(textBox.Text, "Event #1 Alpha", 1, true)
    and not string.find(textBox.Text, "Event #2 Zulu", 1, true),
    "ID filtering matches the requested endpoint")
endpointFilter:SetProperty("Text", "3")
assert(string.find(textBox.Text, "Request #3 Lookup", 1, true)
    and not string.find(textBox.Text, "Event #1 Alpha", 1, true), "numeric ID filtering works without a prefix")
endpointFilter:SetProperty("Text", "missing")
assert(string.find(textBox.Text, "No matching endpoint rows in this snapshot.", 1, true)
    and string.find(textBox.Text, "Session:", 1, true), "no-match filtering preserves session diagnostics")
endpointFilter:SetProperty("Text", "Alpha")
assert(string.find(textBox.Text, "Event #1 Alpha", 1, true))
endpointFilter:SetProperty("Text", string.rep("q", 32) .. "Alpha")
assert(#endpointFilter.Text == 32 and not string.find(textBox.Text, "Event #1 Alpha", 1, true)
    and string.find(textBox.Text, "No matching endpoint rows in this snapshot.", 1, true),
    "filter input is capped at 32 bytes before matching")
endpointFilter:SetProperty("Text", "")
assert(string.find(textBox.Text, "Event #1 Alpha", 1, true)
    and string.find(textBox.Text, "Event #2 Zulu", 1, true)
    and string.find(textBox.Text, "Request #3 Lookup", 1, true), "clearing the filter restores all endpoints")
historySelector.Activated:Fire()
assert(historySelector.Text == "History 1/1" and string.find(textBox.Text, "Sample t=0.000s", 1, true))

clock += 1
heartbeat:Fire(1)
pluginHeartbeat:Fire(1)
assert(historySelector.Text == "History 1/2" and string.find(textBox.Text, "Sample t=0.000s", 1, true),
    "history selection stays on the same captured sample as new samples append")
for _ = 1, 20 do
    clock += 1
    heartbeat:Fire(1)
end
pluginHeartbeat:Fire(20)
local _, pluginHistoryCount = retainedHistory(serverStorage:FindFirstChild("RelayStudioInspector_v1")
    :FindFirstChild("Attachment01").Value)
assert(historySelector.Text == string.format("History: Live (%d)", pluginHistoryCount)
    and pluginHistoryCount < Snapshot.MAX_HISTORY_SAMPLES and string.find(textBox.Text, "Attachment:", 1, true)
    and not string.find(textBox.Text, "Sample t=0.000s", 1, true),
    "an evicted selected sample falls back to Live instead of changing captures")
historySelector.Activated:Fire()
assert(historySelector.Text == "History 1/" .. pluginHistoryCount
    and string.find(textBox.Text, "Preceding sample was evicted", 1, true),
    "oldest retained history explains its evicted predecessor")

fixture:Destroy()
clock += 1
pluginHeartbeat:Fire(1)
assert(string.find(textBox.Text, "No Relay inspector snapshots", 1, true), "an absent root clears stale text")
assert(selector.Text == "No Relay snapshots")

fixture = assert(Attachment.Attach(Definition, definition,
    sessionWith(function() return serverSnapshot end), "Plugin fixture"))
clock += 1
pluginHeartbeat:Fire(1)
assert(historySelector.Text == "History: Live (1)" and string.find(textBox.Text, "InspectorTest", 1, true),
    "a replacement StringValue with the same label and slot starts in Live")

local widgetRoot = serverStorage:FindFirstChild("RelayStudioInspector_v1")
local legacyValue = Instance.new("StringValue")
legacyValue.Name = "Attachment02"
legacyValue:SetAttribute("RelayInspectorFormat", 1)
legacyValue:SetAttribute("RelayInspectorLabel", "Legacy")
legacyValue.Value = "Relay Studio Inspector v1\nLegacy snapshot"
legacyValue.Parent = widgetRoot
clock += 1
pluginHeartbeat:Fire(1)
selector.Activated:Fire()
assert(string.find(textBox.Text, "Legacy snapshot", 1, true), "legacy raw v1 snapshots remain readable")
legacyValue.Value = "Relay Studio Inspector v1\n  Event #3 Lookup | detail\n  Event #4 Stage3 | detail"
endpointFilter:SetProperty("Text", "3")
assert(string.find(textBox.Text, "Event #3 Lookup", 1, true)
    and not string.find(textBox.Text, "Event #4 Stage3", 1, true),
    "numeric queries match endpoint IDs without matching digits in names")
endpointFilter:SetProperty("Text", "")
legacyValue.Value = "legacy raw \n[Relay Inspector History]\nmalformed framing"
clock += 1
pluginHeartbeat:Fire(1)
assert(string.find(textBox.Text, "malformed framing", 1, true), "malformed history framing falls back to raw text")
legacyValue:Destroy()

endpointFilter:SetProperty("Text", "Alpha")
widget:SetProperty("Enabled", false)
assert(pluginHeartbeat:activeCount() == 0 and textBox.Text == ""
    and historySelector.Text == "History: Live" and endpointFilter.Text == "",
    "closing the widget stops polling and clears the filter and cached text")
widget:SetProperty("Enabled", true)
assert(pluginHeartbeat:activeCount() == 1 and string.find(textBox.Text, "InspectorTest", 1, true)
    and string.find(textBox.Text, "Event #2 Zulu", 1, true),
    "reopening the widget refreshes the current StringValue with all endpoints")

local clickSignal = pluginMock.button.Click
local activatedSignal = selector.Activated
local historySignal = historySelector.Activated
local filterSignal = endpointFilter:GetPropertyChangedSignal("Text")
local enabledSignal = widget:GetPropertyChangedSignal("Enabled")
local sizeSignal = scrollingFrame:GetPropertyChangedSignal("AbsoluteSize")
local unloadingSignal = pluginMock.Unloading
pluginMock.Unloading:Fire()
assert(pluginHeartbeat:activeCount() == 0, "unload disconnects the plugin poller")
assert(clickSignal:activeCount() == 0 and activatedSignal:activeCount() == 0 and historySignal:activeCount() == 0
    and filterSignal:activeCount() == 0
    and enabledSignal:activeCount() == 0 and sizeSignal:activeCount() == 0
    and unloadingSignal:activeCount() == 0, "unload disconnects persistent UI connections")
assert(widget._destroyed and pluginMock.button._destroyed and historySelector._destroyed and endpointFilter._destroyed
    and pluginMock.toolbar._destroyed,
    "unload destroys the widget, button, and toolbar")

local restoredPlugin, restoredHeartbeat = pluginHarness(true)
assert(restoredHeartbeat:activeCount() == 1, "saved enabled state starts polling on plugin load")
local restoredSnapshot = restoredPlugin.widget:FindFirstChild("Contents")
    :FindFirstChild("SnapshotScroll"):FindFirstChild("Snapshot")
local restoredFilter = restoredPlugin.widget:FindFirstChild("Contents"):FindFirstChild("EndpointFilter")
assert(restoredFilter.Text == "" and string.find(restoredSnapshot.Text, "InspectorTest", 1, true)
    and string.find(restoredSnapshot.Text, "Event #2 Zulu", 1, true),
    "restored enabled widget reads the current snapshot without a stale filter")
restoredPlugin.Unloading:Fire()
assert(restoredHeartbeat:activeCount() == 0 and restoredPlugin.widget._destroyed,
    "restored plugin unload also disconnects and destroys its UI")
fixture:Destroy()
assert(heartbeat:activeCount() == 0 and serverStorage:FindFirstChild("RelayStudioInspector_v1") == nil)

print("PASS Relay.StudioInspector")
