--!strict
local Relay = require("../../src/init")
local Snapshot = require("./schema-helpers-shapes")
local s = Relay.schema

local function bind<N, S>(name: N, shape: S): S & { name: N }
    return s.field(name, shape)
end
local Count = s.u16()
local LocalRecord = s.struct(s.field("count" :: "count", Count))
-- Parentheses make the final builder expression a single result in ordered packs.
local primitiveInput = s.ordered(
    s.field("enabled", s.boolean()), s.field("label", s.string(16)),
    s.field("a", s.u8()), s.field("b", Count), s.field("c", s.u32()),
    s.field("d", s.i8()), s.field("e", s.i16(-10, nil)), (bind("f", s.i32(nil, 100)))
)
local primitiveState = s.ordered(
    s.field("ratio", s.f32(-1, 1)), s.field("point2", s.Vector2F32(-1, 1)),
    s.field("point3", s.Vector3F32(-1, 1)), (s.field("pose", s.CFrame(-1, 1)))
)
local mixed = s.ordered(s.field("sequence", Count), s.field("snapshot", Snapshot), (s.field("local", LocalRecord)))
local definition, issue = Relay.define({ name = "HelperTypes", version = 1, events = {
    Input = s.clientToServer(1, primitiveInput),
    State = s.serverToClient(2, primitiveState, "Unreliable"),
    SnapshotInput = s.clientToServer(3, mixed),
    SnapshotState = s.serverToClient(4, mixed),
    Empty = s.serverToClient(5, s.ordered()),
    Deep = s.clientToServer(6, s.ordered(s.field("deep", s.array(s.array(s.array(s.array(s.boolean(), 1), 1), 1), 1)))),
} })
assert(definition, issue and issue.message)
local server, serverIssue = Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 10, refillPerSecond = 1 }, aggregate = { capacity = 100, refillPerSecond = 10 },
} })
assert(server, serverIssue and serverIssue.message)
local client, clientIssue = Relay.createClient(definition, { startupTimeoutSeconds = 10 })
assert(client, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")

server.events.Input:Connect(function(sender, enabled, label, a, b, c, d, e, f)
    local userId: number = sender.UserId
    local flag: boolean = enabled
    local text: string = label
    local total: number = a + b + c + d + e + f
    print(userId, flag, text, total)
end)
client.events.State:Connect(function(ratio, point2, point3, pose)
    local numberValue: number = ratio
    local vector2Value: Vector2 = point2
    local vector3Value: Vector3 = point3
    local cframeValue: CFrame = pose
    print(numberValue, vector2Value, vector3Value, cframeValue)
end)
server.events.SnapshotInput:Connect(function(sender, sequence, snapshot, record)
    local userId: number = sender.UserId
    local count: number = sequence + record.count
    local mode: "Idle" | "Run" = snapshot.mode
    local modes: { Idle: true?, Run: true? } = snapshot.modes
    local singleMode: { Only: true? } = snapshot.singleMode
    local scores: { number } = snapshot.scores
    local tags: { [string]: true } = snapshot.tags
    local target: number? = snapshot.target
    print(userId, count, mode, modes, singleMode, scores, tags, target)
end)
client.events.SnapshotState:Connect(function(sequence, snapshot, record)
    local total: number = sequence + record.count
    local mode: "Idle" | "Run" = snapshot.mode
    print(total, mode)
end)
client.events.Empty:Connect(function() end)
client.events.Input:Send(true, "a", 1, 2, 3, -1, -2, -3)
server.events.State:Send(player, 0.5, Vector2.new(), Vector3.new(), CFrame.new())
server.events.State:Broadcast(0.5, Vector2.new(), Vector3.new(), CFrame.new())
client.events.SnapshotInput:Send(1, {
    mode = "Idle", modes = { Run = true }, singleMode = {}, scores = { 1, 2 }, tags = { blue = true }, target = 42,
}, { count = 3 })
server.events.SnapshotState:Broadcast(1, {
    mode = "Run", modes = {}, singleMode = { Only = true }, scores = {}, tags = {},
}, { count = 4 })
client.events.Deep:Send({{{{true}}}})
server.events.Empty:Broadcast()
server:Destroy()
client:Destroy()
