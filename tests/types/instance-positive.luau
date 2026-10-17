--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local instance = s.Instance("Instance")
local basePart = s.Instance("BasePart")
local partShape = s.Instance("Part")
local meshPartShape = s.Instance("MeshPart")
local modelShape = s.Instance("Model")
local humanoidShape = s.Instance("Humanoid")
local toolShape = s.Instance("Tool")
local attachmentShape = s.Instance("Attachment")
local playerShape = s.Instance("Player")
local folderShape = s.Instance("Folder")
local guiShape = s.Instance("GuiObject")
local soundShape = s.Instance("Sound")
local animationShape = s.Instance("Animation")
local animatorShape = s.Instance("Animator")

local first = s.ordered(
    s.field("instance", instance), s.field("basePart", basePart), s.field("part", partShape),
    s.field("meshPart", meshPartShape), s.field("model", modelShape), s.field("humanoid", humanoidShape),
    s.field("tool", toolShape), (s.field("attachment", attachmentShape))
)
local second = s.ordered(
    s.field("player", playerShape), s.field("folder", folderShape), s.field("gui", guiShape),
    s.field("sound", soundShape), s.field("animation", animationShape), (s.field("animator", animatorShape))
)
local nested = s.struct(
    s.field("maybe" :: "maybe", s.optional(s.Instance("Attachment"))),
    s.field("parts" :: "parts", s.array(s.Instance("BasePart"), 0)),
    s.field("models" :: "models", s.map(s.string(16), s.Instance("Model"), 4)),
    (s.field("choice" :: "choice", s.taggedUnion("kind" :: "kind", {
        Part = s.struct((s.field("value" :: "value", s.Instance("Part")))),
        Folder = s.struct((s.field("value" :: "value", s.Instance("Folder")))),
    })))
)

local definition, issue = Relay.define({ name = "InstanceTypes", version = 1, events = {
    InputA = s.clientToServer(1, first),
    OutputA = s.serverToClient(2, first),
    InputB = s.clientToServer(3, second),
    OutputB = s.serverToClient(4, second),
    NestedInput = s.clientToServer(5, s.ordered(s.field("value", nested))),
    ReliableInput = s.clientToServer(6, s.ordered(s.field("value", s.Instance("Part"))), "Reliable"),
} })
local token = assert(definition, issue and issue.message)
local player: Player = error("type-only fixture")
local instanceValue: Instance = error("type-only fixture")
local basePartValue: BasePart = error("type-only fixture")
local part: Part = error("type-only fixture")
local meshPart: MeshPart = error("type-only fixture")
local model: Model = error("type-only fixture")
local humanoid: Humanoid = error("type-only fixture")
local tool: Tool = error("type-only fixture")
local attachment: Attachment = error("type-only fixture")
local folder: Folder = error("type-only fixture")
local gui: GuiObject = error("type-only fixture")
local sound: Sound = error("type-only fixture")
local animation: Animation = error("type-only fixture")
local animator: Animator = error("type-only fixture")

local serverResult, serverIssue = Relay.createServer(token, {
    inboundRate = { perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 } },
    instanceRoot = workspace,
})
local server = assert(serverResult, serverIssue and serverIssue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
local inspectionResult, inspectionIssue = Relay.inspect(token)
local inspection = assert(inspectionResult, inspectionIssue and inspectionIssue.message)
assert(inspection.protocol == "RR9")
local protocol: "RR9" = inspection.protocol
local referenceLimit: number = inspection.limits.instanceReferences
local referenceCharge: number = inspection.limits.instanceReferenceAdmissionBytes
local referenceBudget = assert(inspection.events.NestedInput.references)
local maximumReferences: number = referenceBudget.maximumCount
local perReferenceBytes: number = referenceBudget.perReferenceAdmissionBytes
local maximumAdmissionBytes: number = referenceBudget.maximumAdmissionBytes

server.events.InputA:Connect(function(_, value1, value2, value3, value4, value5, value6, value7, value8)
    local typed1: Instance = value1
    local typed2: BasePart = value2
    local typed3: Part = value3
    local typed4: MeshPart = value4
    local typed5: Model = value5
    local typed6: Humanoid = value6
    local typed7: Tool = value7
    local typed8: Attachment = value8
    print(typed1, typed2, typed3, typed4, typed5, typed6, typed7, typed8)
end)
client.events.OutputA:Connect(function(value1, value2, value3, value4, value5, value6, value7, value8)
    local typed1: Instance = value1
    local typed2: BasePart = value2
    local typed3: Part = value3
    local typed4: MeshPart = value4
    local typed5: Model = value5
    local typed6: Humanoid = value6
    local typed7: Tool = value7
    local typed8: Attachment = value8
    print(typed1, typed2, typed3, typed4, typed5, typed6, typed7, typed8)
end)
server.events.InputB:Connect(function(_, value1, value2, value3, value4, value5, value6)
    local typed1: Player = value1
    local typed2: Folder = value2
    local typed3: GuiObject = value3
    local typed4: Sound = value4
    local typed5: Animation = value5
    local typed6: Animator = value6
    print(typed1, typed2, typed3, typed4, typed5, typed6)
end)
client.events.OutputB:Connect(function(value1, value2, value3, value4, value5, value6)
    local typed1: Player = value1
    local typed2: Folder = value2
    local typed3: GuiObject = value3
    local typed4: Sound = value4
    local typed5: Animation = value5
    local typed6: Animator = value6
    print(typed1, typed2, typed3, typed4, typed5, typed6)
end)
server.events.NestedInput:Connect(function(_, value)
    local maybeAttachment: Attachment? = value.maybe
    local parts: { BasePart } = value.parts
    local models: { [string]: Model } = value.models
    if value.choice.kind == "Part" then
        local nestedPart: Part = value.choice.value
        print(nestedPart)
    else
        local nestedFolder: Folder = value.choice.value
        print(nestedFolder)
    end
    print(maybeAttachment, parts, models)
end)
server.events.ReliableInput:Connect(function(_, value)
    local typed: Part = value
    print(typed)
end)

client.events.InputA:Send(instanceValue, basePartValue, part, meshPart, model, humanoid, tool, attachment)
client.events.InputB:Send(player, folder, gui, sound, animation, animator)
server.events.OutputA:Send(player, instanceValue, basePartValue, part, meshPart, model, humanoid, tool, attachment)
server.events.OutputA:SendTo({ player }, instanceValue, basePartValue, part, meshPart, model, humanoid, tool, attachment)
server.events.OutputA:SendExcept({ player }, instanceValue, basePartValue, part, meshPart, model, humanoid, tool, attachment)
client.events.NestedInput:Send({ maybe = nil, parts = {}, models = {}, choice = { kind = "Part", value = part } })
print(server, client, protocol, referenceLimit, referenceCharge, maximumReferences, perReferenceBytes, maximumAdmissionBytes)
