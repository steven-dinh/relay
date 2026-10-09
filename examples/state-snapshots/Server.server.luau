--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))

local serverResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 128, refillPerSecond = 64 },
	},
})
local server = assert(serverResult, createError and createError.message)

local started, startError = server:Start()
assert(started, startError and startError.message)

type PoseStateEvent = {
	Put: (self: PoseStateEvent, key: number, priority: "High" | "Normal" | "Low", tick: number, position: Vector3) -> (boolean, Relay.RelayError?),
	Remove: (self: PoseStateEvent, key: number) -> (boolean, Relay.RelayError?),
}
type PoseState = Relay.StateHandle<{ Pose: PoseStateEvent }>

-- Create one lane from the game-selected audience snapshot. New players are
-- not added automatically; destroy and recreate the lane when that set changes.
local poseState: PoseState? = nil
local function _beginPoseStream(audience: { Player })
	if poseState ~= nil then poseState:Destroy() end
	local stateResult, stateError = server:CreateState(audience, 0.02)
	poseState = assert(stateResult, stateError and stateError.message)
end

-- Call for each authoritative pose update, using a monotonically increasing
-- u32 tick that continues across lane recreation. Key 1 is the only demo entity;
-- repeated Puts replace its still-pending absolute snapshot until service.
local function _publishPose(tick: number, position: Vector3): (number?, number?)
	local state = poseState
	if state == nil then return nil, nil end
	local queued, queueError = state.events.Pose:Put(1, "High", tick, position)
	if not queued then
		warn("Pose snapshot was not queued", queueError and queueError.code)
		return nil, nil
	end

	local status = state:GetStatus()
	return status.pendingKeys, status.pendingBodyBytes
end

-- Use for an explicit boundary; otherwise the lane services itself after its
-- configured first-dirty delay (at most 100 ms); platform scheduling can run later.
local function _flushPose(): number?
	local state = poseState
	if state == nil then return nil end
	local flushed, flushError, report = state:Flush()
	if not flushed then
		warn("Pose flush failed", flushError and flushError.code)
	end
	return report.logicalHandoffs
end

-- Remove releases the local key and pending body. It does not tell clients to
-- forget an already received pose; declare an explicit removal event for that.
local function _removePose()
	local state = poseState
	if state == nil then return end
	local removed, removeError = state.events.Pose:Remove(1)
	if not removed then warn("Pose key was not removed", removeError and removeError.code) end
end

script.Destroying:Connect(function()
	if poseState ~= nil then poseState:Destroy() end
	server:Destroy()
end)
