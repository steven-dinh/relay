--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local vector3 = s.quantizedVector3(-256, 256, 0.25)
local vector2 = s.quantizedVector2(-256, 256, 0.25)
local frame = s.compactCFrame(-256, 256, 0.25)
local rawVector3: { type: "quantizedVector3", minimum: number, maximum: number, step: number } = {
	type = "quantizedVector3", minimum = -256, maximum = 256, step = 0.25,
}
local pose = s.struct(
	s.field("position" :: "position", vector3),
	s.field("plane" :: "plane", vector2),
	s.field("frame" :: "frame", frame),
	(s.field("optionalFrame" :: "optionalFrame", s.optional(frame)))
)
local fields = s.ordered(s.field("position" :: "position", vector3), s.field("plane" :: "plane", vector2),
	s.field("frame" :: "frame", frame), s.field("pose" :: "pose", pose), (s.field("raw" :: "raw", rawVector3)))
local definition, issue = Relay.define({
	name = "CompactValueTypes", version = 1,
	events = {
		Input = s.clientToServer(1, fields),
		Output = s.serverToClient(2, fields),
		Batch = { id = 3, direction = "ClientToServer" :: "ClientToServer", queue = "Batch" :: "Batch",
			fields = s.ordered((s.field("value" :: "value", vector3))) },
		State = { id = 4, direction = "ServerToClient" :: "ServerToClient", queue = "State" :: "State",
			fields = s.ordered((s.field("value" :: "value", frame))) },
	},
	requests = { RoundTrip = s.request(5, s.ordered((s.field("value" :: "value", vector3))), frame) },
})
local token = assert(definition, issue and issue.message)
local serverValue, serverIssue = Relay.createServer(token, { inboundRate = {
	perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })
local server = assert(serverValue, serverIssue and serverIssue.message)
local clientValue, clientIssue = Relay.createClient(token, { startupTimeoutSeconds = 3 })
local client = assert(clientValue, clientIssue and clientIssue.message)
local player: Player = error("type-only fixture")
local position = Vector3.new(1, 2, 3)
local plane = Vector2.new(4, 5)
local cframe = CFrame.new(1, 2, 3)

server.events.Input:Connect(function(_, actualPosition, actualPlane, actualFrame, actualPose, raw)
	local typedPosition: Vector3 = actualPosition
	local typedPlane: Vector2 = actualPlane
	local typedFrame: CFrame = actualFrame
	local nestedPosition: Vector3 = actualPose.position
	local optionalFrame: CFrame? = actualPose.optionalFrame
	local rawPosition: Vector3 = raw
	print(typedPosition, typedPlane, typedFrame, nestedPosition, optionalFrame, rawPosition)
end)
client.events.Output:Connect(function(actualPosition, actualPlane, actualFrame, actualPose)
	local typedPosition: Vector3 = actualPosition
	local typedPlane: Vector2 = actualPlane
	local typedFrame: CFrame = actualFrame
	local nestedFrame: CFrame = actualPose.frame
	print(typedPosition, typedPlane, typedFrame, nestedFrame)
end)
server.requests.RoundTrip:Connect(function(_, actualPosition): CFrame
	local typedPosition: Vector3 = actualPosition
	print(typedPosition)
	return cframe
end)

client.events.Input:Send(position, plane, cframe, { position = position, plane = plane, frame = cframe }, position)
server.events.Output:Send(player, position, plane, cframe,
	{ position = position, plane = plane, frame = cframe, optionalFrame = nil }, position)
local batchValue, batchIssue = client:CreateBatch(0.02)
local batch = assert(batchValue, batchIssue and batchIssue.message)
batch.events.Batch:Send(position)
local stateValue, stateIssue = server:CreateState({ player }, 0.02)
local state = assert(stateValue, stateIssue and stateIssue.message)
state.events.State:Put(1, "Normal", cframe)
local pendingValue, pendingIssue = client.requests.RoundTrip:Request(1, position)
local pending = assert(pendingValue, pendingIssue and pendingIssue.message)
local result = pending:Await()
if result.ok then
	local typedFrame: CFrame = result.value
	print(typedFrame)
end
print(server, client, batch, state)
