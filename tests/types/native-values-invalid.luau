--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local material = s.robloxEnum(Enum.Material.Plastic, Enum.Material.Wood)
local collections = s.ordered(s.field("map", s.map(material, s.UDim(-2, 2, -100, 100), 4)),
    (s.field("set", s.set(material, 4))))
local definition, issue = Relay.define({ name = "BadNativeTypes", version = 1, events = {
    Native1 = s.clientToServer(1, s.ordered(s.field("value", s.UDim(-2, 2, -100, 100)))),
    Native2 = s.clientToServer(2, s.ordered(s.field("value", s.UDim2(-2, 2, -100, 100)))),
    Native3 = s.clientToServer(3, s.ordered(s.field("value", s.NumberRange(-10, 10)))),
    Native4 = s.clientToServer(4, s.ordered(s.field("value", s.Rect(-10, 10)))),
    Native5 = s.clientToServer(5, s.ordered(s.field("value", s.BrickColor(BrickColor.new("Really red"))))),
    Native6 = s.clientToServer(6, s.ordered(s.field("value", s.Vector2int16()))),
    Native7 = s.clientToServer(7, s.ordered(s.field("value", s.Vector3int16()))),
    Native8 = s.clientToServer(8, s.ordered(s.field("value", s.NumberSequence(4, 0, 10, 2)))),
    Native9 = s.clientToServer(9, s.ordered(s.field("value", s.ColorSequence(4)))),
    Native10 = s.clientToServer(10, s.ordered(s.field("value", s.NumberSequenceKeypoint(0, 10, 2)))),
    Native11 = s.clientToServer(11, s.ordered(s.field("value", s.ColorSequenceKeypoint()))),
    Native12 = s.clientToServer(12, s.ordered(s.field("value", s.TweenInfo(10, 10, 3, true)))),
    Native13 = s.clientToServer(13, s.ordered(s.field("value", s.DateTime(0, 2000000000000)))),
    Native14 = s.clientToServer(14, s.ordered(s.field("value", s.Ray(-10, 10, 10)))),
    Native15 = s.clientToServer(15, s.ordered(s.field("value", s.Axes()))),
    Native16 = s.clientToServer(16, s.ordered(s.field("value", s.Faces()))),
    Native17 = s.clientToServer(17, s.ordered(s.field("value", s.Region3(-10, 10)))),
    Native18 = s.clientToServer(18, s.ordered(s.field("value", s.Region3int16()))),
    Native19 = s.clientToServer(19, s.ordered(s.field("value", s.PhysicalProperties()))),
    Native20 = s.clientToServer(20, s.ordered(s.field("value", s.Font("rbxasset://fonts/families/SourceSansPro.json")))),
    Native21 = s.clientToServer(21, s.ordered(s.field("value", s.PathWaypoint(-10, 10, 16)))),
    Native22 = s.clientToServer(22, s.ordered(s.field("value", s.robloxEnum(Enum.Material.Plastic, Enum.Material.Wood)))),
    Collections = s.clientToServer(23, collections),
    Batch = { id = 24, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch", fields = collections },
    State = { id = 25, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State", fields = collections },
}, requests = { Lookup = s.request(26, s.ordered(s.field("material", material)), material) } })
local token = assert(definition, issue and issue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
local serverResult, serverIssue = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverIssue and serverIssue.message)
client.events.Native1:Send("bad")
client.events.Native2:Send("bad")
client.events.Native3:Send("bad")
client.events.Native4:Send("bad")
client.events.Native5:Send("bad")
client.events.Native6:Send("bad")
client.events.Native7:Send("bad")
client.events.Native8:Send("bad")
client.events.Native9:Send("bad")
client.events.Native10:Send("bad")
client.events.Native11:Send("bad")
client.events.Native12:Send("bad")
client.events.Native13:Send("bad")
client.events.Native14:Send("bad")
client.events.Native15:Send("bad")
client.events.Native16:Send("bad")
client.events.Native17:Send("bad")
client.events.Native18:Send("bad")
client.events.Native19:Send("bad")
client.events.Native20:Send("bad")
client.events.Native21:Send("bad")
client.events.Native22:Send("bad")
client.events.Native22:Send(Enum.KeyCode.Space)
local wrongMap: { [Enum.KeyCode]: UDim } = { [Enum.KeyCode.Space] = UDim.new(1, 0) }
local wrongSet: { [Enum.KeyCode]: true } = { [Enum.KeyCode.Space] = true }
client.events.Collections:Send(wrongMap, {})
client.events.Collections:Send({}, wrongSet)
client.requests.Lookup:Request(3, Enum.KeyCode.Space)
server.requests.Lookup:Connect(function() return Enum.KeyCode.Space end)
server.events.Native22:Connect(function(_, value)
    local wrong: Enum.KeyCode = value
    print(wrong)
end)
local batchResult, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchResult, batchIssue and batchIssue.message)
batch.events.Batch:Send(wrongMap, {})
local stateResult, stateIssue = client:CreateState(0.02)
local state = assert(stateResult, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", {}, wrongSet)
local mixed = Relay.define({ name = "MixedEnum", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.robloxEnum(Enum.Material.Wood, Enum.KeyCode.Space)))),
} })
local broad: EnumItem = Enum.Material.Wood
local broadEnum = Relay.define({ name = "BroadEnum", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.robloxEnum(broad)))),
} })
local missing = Relay.define({ name = "MissingBounds", version = 1, events = {
    Input = s.clientToServer(1, s.ordered({ name = "value", type = "UDim" :: "UDim", minimumScale = 0 })),
} })
local unknown = Relay.define({ name = "UnknownNative", version = 1, events = {
    Input = s.clientToServer(1, s.ordered({ name = "value", type = "Axes" :: "Axes", extra = true })),
} })
local wrongFamilies = Relay.define({ name = "BadFonts", version = 1, events = {
    Input = s.clientToServer(1, s.ordered(s.field("value", s.Font(123)))),
} })
print(mixed, broadEnum, missing, unknown, wrongFamilies)
