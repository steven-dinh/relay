local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Definition = require("../src/Definition")
local Diagnostics = require("../src/internal/Diagnostics")
local Snapshot = require("../scripts/studio-inspector/Snapshot")
local Structured = require("../scripts/studio-inspector/Structured")

local function signal()
    local result = { connections = {} }
    function result:Connect(callback)
        local connection = { active = true, callback = callback }
        function connection:Disconnect() self.active = false end
        table.insert(self.connections, connection)
        return connection
    end
    function result:Fire(...)
        for _, connection in table.clone(self.connections) do
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
        Value = "",
        _parent = nil,
        _children = {},
        _attributes = {},
        AncestryChanged = signal(),
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
    function instance:Destroy()
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
local localPlayer = mockInstance("Player")
function localPlayer:FindFirstChild(name)
    return if name == "PlayerScripts" then playerScripts else nil
end
local players = { LocalPlayer = localPlayer }
local heartbeat = signal()
local runtime = { studio = true, side = "Server", Heartbeat = heartbeat }
function runtime:IsStudio() return self.studio end
function runtime:IsServer() return self.side == "Server" end
function runtime:IsClient() return self.side == "Client" end
local guidCount = 0
local httpService = {}
function httpService:GenerateGUID(_)
    guidCount += 1
    return string.format("00000000-0000-4000-8000-%012x", guidCount)
end
function httpService:JSONEncode(value) return serde.encode("json", value) end
local gameMock = {}
function gameMock:GetService(name)
    if name == "RunService" then return runtime end
    if name == "ServerStorage" then return serverStorage end
    if name == "Players" then return players end
    if name == "HttpService" then return httpService end
    error("unexpected service " .. name)
end
local Instance = { new = mockInstance }
local clock = 0
local osMock = { clock = function() return clock end }

local definition = assert(Definition.define({
    name = "RegistrationTest",
    version = 1,
    events = { Input = { id = 500, direction = "ClientToServer", fields = {} } },
    requests = { Lookup = { id = 650, request = {}, response = { type = "boolean" } } },
}))
local compiled = assert(Definition.get(definition))
local function newSession(side)
    local raw = Diagnostics.create(compiled.events, side, nil,
        if side == "Server" then { global = 64, perPlayer = 8, perPlayerEndpoint = 1 } else { perEndpoint = 1 },
        nil, compiled.requests, { traffic = true, reports = true })
    local session = { state = "Created", calls = 0, destroyCalls = 0 }
    function session:GetDiagnostics()
        self.calls += 1
        return table.clone(Diagnostics.snapshot(raw, self.state, 0))
    end
    function session:Destroy() self.destroyCalls += 1 end
    return session
end

local sources = {
    ["./Snapshot"] = Snapshot,
    ["./Structured"] = Structured,
}
local attachmentEnvironment = {
    script = nil,
    game = gameMock,
    Instance = Instance,
    os = osMock,
    require = function(path) return assert(sources[path], "unexpected Attachment import " .. path) end,
}
local Attachment = luau.load(fs.readFile("scripts/studio-inspector/Attachment.luau"), {
    environment = attachmentEnvironment,
    injectGlobals = true,
})()
sources["./Attachment"] = Attachment
local Registration = luau.load(fs.readFile("scripts/studio-inspector/Registration.luau"), {
    environment = {
        script = nil,
        game = gameMock,
        require = function(path) return assert(sources[path], "unexpected Registration import " .. path) end,
    },
    injectGlobals = true,
})()

local createdServer, createdClient
local serverOptions, clientOptions = { namespace = "server_scope" }, {}
local serverCreateError
local serverCreateCalls, clientCreateCalls, inspectCalls = 0, 0, 0
local Relay = {
    inspect = function(value)
        assert(value == definition, "inspection receives the registered definition")
        inspectCalls += 1
        return Definition.inspect(value)
    end,
    createServer = function(value, options)
        assert(value == definition and options == serverOptions, "server constructor gets the exact pair and options")
        serverCreateCalls += 1
        if serverCreateError ~= nil then return nil, serverCreateError end
        createdServer = newSession("Server")
        return createdServer, nil
    end,
    createClient = function(value, options)
        assert(value == definition and options == clientOptions, "client constructor gets the exact pair and options")
        clientCreateCalls += 1
        createdClient = newSession("Client")
        return createdClient, nil
    end,
}
local metadata = {
    label = "Project Alpha",
    projectId = "projectAlpha",
    compilerId = "compiler-sha256:abc",
    toolingId = "tooling-sha256:def",
    sourceId = "source-sha256:ghi",
}
local function decode(value)
    local record, decodeError = Structured.decode(function(text) return serde.decode("json", text) end, value.Value)
    assert(record, decodeError)
    return record
end

runtime.studio = false
local gatedSession, gatedAttachment, gatedError = Registration.createServer(Relay, definition, serverOptions, metadata)
assert(gatedSession == nil and gatedAttachment == nil and gatedError == "NotStudio" and serverCreateCalls == 0,
    "the Studio gate runs before construction")
runtime.studio = true

local relayError = { code = "InvalidOptions" }
serverCreateError = relayError
local failedSession, failedAttachment, returnedRelayError = Registration.createServer(
    Relay, definition, serverOptions, metadata)
assert(failedSession == nil and failedAttachment == nil and returnedRelayError == relayError,
    "constructor failures are returned without creating an attachment")
serverCreateError = nil

local session1, attachment1, attachError1 = Registration.createServer(Relay, definition, serverOptions, metadata)
assert(session1 == createdServer and attachment1 ~= nil and attachError1 == nil and inspectCalls > 0,
	`structured server registration failed: {tostring(attachError1)} session={type(session1)} expected={type(createdServer)} get={if session1 then type(session1.GetDiagnostics) else "nil"}`)
local serverRoot = serverStorage:FindFirstChild("RelayStudioInspector_v1")
local value1 = serverRoot:FindFirstChild("Attachment01")
assert(serverRoot:GetAttribute("RelayInspectorFormat") == 1
    and value1:GetAttribute("RelayInspectorFormat") == 2,
    "v2 records share the existing marked format-1 root")
local first = decode(value1)
local maximumVersionRecord = table.clone(first)
maximumVersionRecord.inspection = table.clone(first.inspection)
maximumVersionRecord.inspection.version = 2_147_483_647
assert(Structured.validate(maximumVersionRecord), "the structured reader accepts Relay's maximum definition version")
assert(first.format == 2 and first.association == "constructed"
    and first.identityStatus == "application-supplied" and first.sessionId ~= ""
    and first.projectId == metadata.projectId and first.compilerId == metadata.compilerId
    and first.toolingId == metadata.toolingId and first.sourceId == metadata.sourceId
    and first.namespace == "server_scope", "structured identity is application-declared with bounded diagnostics namespace")
assert(first.inspection.name == "RegistrationTest" and first.inspection.events[1].id == 500
    and first.inspection.requests[1].id == 650 and #first.liveText <= Structured.MAX_LIVE_TEXT_BYTES
    and #value1.Value <= Structured.MAX_SERIALIZED_BYTES and first.descriptor == nil
    and first.inspection.descriptor == nil and first.diagnostics == nil,
    "structured reports retain public definition metadata and endpoint IDs without descriptors")
assert(Structured.encodedHistoryBytes(first.history) == #serde.encode("json", first.history),
    "history retention cap measures its exact encoded JSON bytes")

local callsBeforeFailure = session1.calls
local historyBeforeFailure = #first.history
assert(attachment1:RecordFailure("RemoteOwnershipConflict"), "allowlisted RecordFailure remains supported")
local afterFailure = decode(value1)
assert(session1.calls == callsBeforeFailure and #afterFailure.history == historyBeforeFailure
    and afterFailure.scalars["failure.RemoteOwnershipConflict"] == 1
    and string.find(afterFailure.liveText, "RemoteOwnershipConflict=1", 1, true),
    "RecordFailure refreshes cached presentation without reading diagnostics or adding a sample")

clock = 1
assert(attachment1:Refresh(), "explicit refresh takes a startup sample after the one-second bound")
local refreshed = decode(value1)
assert(#refreshed.history == 2 and refreshed.elapsed == 1)

local session2, attachment2, attachError2 = Registration.createServer(
    Relay, definition, serverOptions, { projectId = metadata.projectId })
assert(session2 == createdServer and attachment2 ~= nil and attachError2 == nil)
local value2 = serverRoot:FindFirstChild("Attachment02")
local second = decode(value2)
assert(second.sessionId ~= first.sessionId and second.identityStatus == "unverified"
    and second.projectId == metadata.projectId and second.compilerId == nil,
    "replacement attachments get a new session identity and partial metadata stays unverified")

local untouched = newSession("Server")
local beforeBadAttach = serverCreateCalls
local badSession, badAttachment, badAttachError = Registration.createServer(Relay, definition, serverOptions,
    { projectId = "projectAlpha", unexpected = "rejected" })
assert(badSession == nil and badAttachment == nil and badAttachError == "InvalidMetadata"
    and serverCreateCalls == beforeBadAttach + 1 and createdServer.destroyCalls == 1
    and session1.destroyCalls == 0 and untouched.destroyCalls == 0,
    "failed structured attachment destroys only the session created by that registration")

local malformed, malformedError = Structured.decode(function() error("decoder should run for malformed JSON") end, "{")
assert(malformed == nil and malformedError == "MalformedJson")
local decoderCalled = false
local oversized, oversizedError = Structured.decode(function() decoderCalled = true; return {} end,
    string.rep("x", Structured.MAX_SERIALIZED_BYTES + 1))
assert(oversized == nil and oversizedError == "RecordTooLarge" and not decoderCalled,
    "serialized size is checked before JSON decoding")
local unknown = table.clone(first)
unknown.payload = "not allowed"
local unknownText = serde.encode("json", unknown)
local unknownRecord, unknownError = Structured.decode(function(text) return serde.decode("json", text) end, unknownText)
assert(unknownRecord == nil and unknownError == "InvalidRecord", "unknown structured fields are rejected")
local missingRequiredScalars = table.clone(first)
missingRequiredScalars.scalars = {}
local missingScalarsRecord, missingScalarsError = Structured.decode(
    function(text) return serde.decode("json", text) end, serde.encode("json", missingRequiredScalars))
assert(missingScalarsRecord == nil and missingScalarsError == "InvalidRecord",
    "v2 records require side and state scalars before diagnosis")
local unexpectedDescriptor = table.clone(first)
unexpectedDescriptor.inspection = table.clone(first.inspection)
unexpectedDescriptor.inspection.descriptor = "not retained"
assert(Structured.validate(unexpectedDescriptor) == false, "unknown inspection data is rejected")
local oversizedRecord, oversizedRecordError = Structured.encode(function() return string.rep("x",
    Structured.MAX_SERIALIZED_BYTES + 1) end, first)
assert(oversizedRecord == nil and oversizedRecordError == "RecordTooLarge")
local tooManyHistory = table.clone(first)
tooManyHistory.history = table.clone(first.history)
for _ = 1, Structured.MAX_HISTORY_SAMPLES do table.insert(tooManyHistory.history, first.history[1]) end
assert(Structured.validate(tooManyHistory) == false, "history sample count remains bounded")
local tooMuchHistory = table.clone(first)
tooMuchHistory.history = { string.rep("A", Structured.MAX_HISTORY_BYTES) }
assert(Structured.validate(tooMuchHistory) == false, "encoded history bytes remain bounded")

local session3, attachment3 = Registration.createServer(Relay, definition, serverOptions, metadata)
local session4, attachment4 = Registration.createServer(Relay, definition, serverOptions, metadata)
assert(session3 and attachment3 and session4 and attachment4)
local legacyHandles = {}
for index = 1, 4 do
    legacyHandles[index] = assert(Attachment.Attach(Relay, definition, session1, "Legacy " .. index))
end
local slotCount = 0
for index = 1, 8 do
    local value = serverRoot:FindFirstChild(string.format("Attachment%02d", index))
    if value ~= nil then slotCount += 1 end
end
assert(slotCount == 8, "format-1 and format-2 records share the eight-slot limit")
local ninthSession, ninthAttachment, limitError = Registration.createServer(Relay, definition, serverOptions, metadata)
assert(ninthSession == nil and ninthAttachment == nil and limitError == "AttachmentLimit")
local legacyValue = serverRoot:FindFirstChild("Attachment05")
assert(legacyValue:GetAttribute("RelayInspectorFormat") == 1
    and string.find(legacyValue.Value, "Relay Studio Inspector v1", 1, true),
    "legacy attachment output remains version 1 text")
local legacyCalls = session1.calls
assert(legacyHandles[1]:RecordFailure("ReadinessDisabled") and session1.calls == legacyCalls,
    "legacy RecordFailure remains cached-only")

local activeBeforeTerminal = heartbeat:activeCount()
session2.state = "Destroyed"
clock = 2
heartbeat:Fire(1)
local terminalRecord = decode(value2)
assert(terminalRecord.scalars.state == "Destroyed" and #terminalRecord.history == 2
    and heartbeat:activeCount() == activeBeforeTerminal - 1,
    "terminal diagnostics become the final retained sample and release that sampler")
local terminalCalls = session2.calls
clock = 3
heartbeat:Fire(1)
assert(session2.calls == terminalCalls, "terminal attachments do not sample again")

runtime.side = "Client"
local clientSession, clientAttachment, clientError = Registration.createClient(
    Relay, definition, clientOptions, nil)
assert(clientSession == createdClient and clientAttachment ~= nil and clientError == nil
    and clientCreateCalls == 1)
local clientRoot = playerScripts:FindFirstChild("RelayStudioInspector_v1")
local clientValue = if clientRoot == nil then nil else clientRoot:FindFirstChild("Attachment01")
local clientRecord = if clientValue == nil then nil else decode(clientValue)
assert(clientRoot ~= nil and clientValue:GetAttribute("RelayInspectorFormat") == 2
    and clientRecord.identityStatus == "unverified" and clientRecord.projectId == nil,
    "client registrations stay in local PlayerScripts")
clientAttachment:Destroy()
assert(playerScripts:FindFirstChild("RelayStudioInspector_v1") == nil)

for _, handle in legacyHandles do handle:Destroy() end
for _, handle in { attachment1, attachment2, attachment3, attachment4 } do handle:Destroy() end
assert(serverStorage:FindFirstChild("RelayStudioInspector_v1") == nil,
    "Destroy clears structured and legacy retained values and removes the empty root")

print("PASS Relay.Tooling.Registration")
