--!strict
local Relay = require("../../src/init")
local s = Relay.schema
local shape1 = s.UDim(-2, 2, -100, 100)
local shape2 = s.UDim2(-2, 2, -100, 100)
local shape3 = s.NumberRange(-10, 10)
local shape4 = s.Rect(-10, 10)
local shape5 = s.BrickColor(BrickColor.new("Really red"))
local shape6 = s.Vector2int16()
local shape7 = s.Vector3int16()
local shape8 = s.NumberSequence(4, 0, 10, 2)
local shape9 = s.ColorSequence(4)
local shape10 = s.NumberSequenceKeypoint(0, 10, 2)
local shape11 = s.ColorSequenceKeypoint()
local shape12 = s.TweenInfo(10, 10, 3, true)
local shape13 = s.DateTime(0, 2000000000000)
local shape14 = s.Ray(-10, 10, 10)
local shape15 = s.Axes()
local shape16 = s.Faces()
local shape17 = s.Region3(-10, 10)
local shape18 = s.Region3int16()
local shape19 = s.PhysicalProperties()
local shape20 = s.Font("rbxasset://fonts/families/SourceSansPro.json")
local shape21 = s.PathWaypoint(-10, 10, 16)
local shape22 = s.robloxEnum(Enum.Material.Plastic, Enum.Material.Wood)
local fields1 = s.ordered(s.field("value1", shape1), s.field("value2", shape2), s.field("value3", shape3), s.field("value4", shape4), s.field("value5", shape5), s.field("value6", shape6), s.field("value7", shape7), (s.field("value8", shape8)))
local fields2 = s.ordered(s.field("value9", shape9), s.field("value10", shape10), s.field("value11", shape11), s.field("value12", shape12), s.field("value13", shape13), s.field("value14", shape14), s.field("value15", shape15), (s.field("value16", shape16)))
local fields3 = s.ordered(s.field("value17", shape17), s.field("value18", shape18), s.field("value19", shape19), s.field("value20", shape20), s.field("value21", shape21), (s.field("value22", shape22)))
local enum = shape22
local collections = s.ordered(s.field("map", s.map(enum, s.UDim(-2, 2, -100, 100), 4)),
    (s.field("set", s.set(enum, 4))))
local definition, issue = Relay.define({ name = "NativeTypes", version = 1, events = {
    Input1 = s.clientToServer(1, fields1), Output1 = s.serverToClient(4, fields1),
    Input2 = s.clientToServer(2, fields2), Output2 = s.serverToClient(5, fields2),
    Input3 = s.clientToServer(3, fields3), Output3 = s.serverToClient(6, fields3),
    Collections = s.clientToServer(7, collections),
    Batch = { id = 8, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch", fields = collections },
    State = { id = 9, direction = "ClientToServer" :: "ClientToServer", queue = "State" :: "State", fields = collections },
}, requests = { Lookup = s.request(10, s.ordered(s.field("material", enum)), enum) } })
local token = assert(definition, issue and issue.message)
local serverResult, serverIssue = Relay.createServer(token, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverResult, serverIssue and serverIssue.message)
local clientResult, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientResult, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")
server.events.Input1:Connect(function(_, value1, value2, value3, value4, value5, value6, value7, value8)
    local typed1: UDim = value1
    print(typed1)
    local typed2: UDim2 = value2
    print(typed2)
    local typed3: NumberRange = value3
    print(typed3)
    local typed4: Rect = value4
    print(typed4)
    local typed5: BrickColor = value5
    print(typed5)
    local typed6: Vector2int16 = value6
    print(typed6)
    local typed7: Vector3int16 = value7
    print(typed7)
    local typed8: NumberSequence = value8
    print(typed8)
end)
client.events.Output1:Connect(function(value1, value2, value3, value4, value5, value6, value7, value8)
    local typed1: UDim = value1
    print(typed1)
    local typed2: UDim2 = value2
    print(typed2)
    local typed3: NumberRange = value3
    print(typed3)
    local typed4: Rect = value4
    print(typed4)
    local typed5: BrickColor = value5
    print(typed5)
    local typed6: Vector2int16 = value6
    print(typed6)
    local typed7: Vector3int16 = value7
    print(typed7)
    local typed8: NumberSequence = value8
    print(typed8)
end)
client.events.Input1:Send(UDim.new(0.5, 3), UDim2.new(0.5, 3, 1, -4), NumberRange.new(1, 2), Rect.new(1, 2, 3, 4), BrickColor.new("Really red"), Vector2int16.new(1, 2), Vector3int16.new(1, 2, 3), NumberSequence.new(1))
server.events.Output1:Send(player, UDim.new(0.5, 3), UDim2.new(0.5, 3, 1, -4), NumberRange.new(1, 2), Rect.new(1, 2, 3, 4), BrickColor.new("Really red"), Vector2int16.new(1, 2), Vector3int16.new(1, 2, 3), NumberSequence.new(1))
server.events.Input2:Connect(function(_, value9, value10, value11, value12, value13, value14, value15, value16)
    local typed9: ColorSequence = value9
    print(typed9)
    local typed10: NumberSequenceKeypoint = value10
    print(typed10)
    local typed11: ColorSequenceKeypoint = value11
    print(typed11)
    local typed12: TweenInfo = value12
    print(typed12)
    local typed13: DateTime = value13
    print(typed13)
    local typed14: Ray = value14
    print(typed14)
    local typed15: Axes = value15
    print(typed15)
    local typed16: Faces = value16
    print(typed16)
end)
client.events.Output2:Connect(function(value9, value10, value11, value12, value13, value14, value15, value16)
    local typed9: ColorSequence = value9
    print(typed9)
    local typed10: NumberSequenceKeypoint = value10
    print(typed10)
    local typed11: ColorSequenceKeypoint = value11
    print(typed11)
    local typed12: TweenInfo = value12
    print(typed12)
    local typed13: DateTime = value13
    print(typed13)
    local typed14: Ray = value14
    print(typed14)
    local typed15: Axes = value15
    print(typed15)
    local typed16: Faces = value16
    print(typed16)
end)
client.events.Input2:Send(ColorSequence.new(Color3.new(1, 0, 0)), NumberSequenceKeypoint.new(0.5, 1, 0), ColorSequenceKeypoint.new(0.5, Color3.new(1, 0, 0)), TweenInfo.new(1), DateTime.fromUnixTimestampMillis(1000), Ray.new(Vector3.zero, Vector3.new(1, 0, 0)), Axes.new(Enum.Axis.X), Faces.new(Enum.NormalId.Top))
server.events.Output2:Send(player, ColorSequence.new(Color3.new(1, 0, 0)), NumberSequenceKeypoint.new(0.5, 1, 0), ColorSequenceKeypoint.new(0.5, Color3.new(1, 0, 0)), TweenInfo.new(1), DateTime.fromUnixTimestampMillis(1000), Ray.new(Vector3.zero, Vector3.new(1, 0, 0)), Axes.new(Enum.Axis.X), Faces.new(Enum.NormalId.Top))
server.events.Input3:Connect(function(_, value17, value18, value19, value20, value21, value22)
    local typed17: Region3 = value17
    print(typed17)
    local typed18: Region3int16 = value18
    print(typed18)
    local typed19: PhysicalProperties = value19
    print(typed19)
    local typed20: Font = value20
    print(typed20)
    local typed21: PathWaypoint = value21
    print(typed21)
    local typed22: Enum.Material = value22
    print(typed22)
end)
client.events.Output3:Connect(function(value17, value18, value19, value20, value21, value22)
    local typed17: Region3 = value17
    print(typed17)
    local typed18: Region3int16 = value18
    print(typed18)
    local typed19: PhysicalProperties = value19
    print(typed19)
    local typed20: Font = value20
    print(typed20)
    local typed21: PathWaypoint = value21
    print(typed21)
    local typed22: Enum.Material = value22
    print(typed22)
end)
client.events.Input3:Send(Region3.new(Vector3.zero, Vector3.one), Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(1, 1, 1)), PhysicalProperties.new(1, 0.5, 0.5), Font.new("rbxasset://fonts/families/SourceSansPro.json"), PathWaypoint.new(Vector3.zero, Enum.PathWaypointAction.Walk, "ok"), Enum.Material.Plastic)
server.events.Output3:Send(player, Region3.new(Vector3.zero, Vector3.one), Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(1, 1, 1)), PhysicalProperties.new(1, 0.5, 0.5), Font.new("rbxasset://fonts/families/SourceSansPro.json"), PathWaypoint.new(Vector3.zero, Enum.PathWaypointAction.Walk, "ok"), Enum.Material.Plastic)
server.events.Collections:Connect(function(_, map, set)
    local typedMap: { [Enum.Material]: UDim } = map
    local typedSet: { [Enum.Material]: true } = set
    print(typedMap, typedSet)
end)
client.events.Collections:Send({ [Enum.Material.Plastic] = UDim.new(1, 0) }, { [Enum.Material.Wood] = true })
server.requests.Lookup:Connect(function(_, material)
    local typed: Enum.Material = material
    return typed
end)
local pendingResult, pendingIssue = client.requests.Lookup:Request(3, Enum.Material.Wood)
local pending = assert(pendingResult, pendingIssue and pendingIssue.message)
local result = pending:Await()
if result.ok then local material: Enum.Material = result.value; print(material) end
local batchResult, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchResult, batchIssue and batchIssue.message)
batch.events.Batch:Send({}, { [Enum.Material.Plastic] = true })
local stateResult, stateIssue = client:CreateState(0.02)
local state = assert(stateResult, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", { [Enum.Material.Wood] = UDim.new(0, 1) }, {})
local raw: Relay.FieldSpec = { name = "value", type = "UDim" :: "UDim", minimumScale = -2, maximumScale = 2,
    minimumOffset = -100, maximumOffset = 100 }
print(raw)
