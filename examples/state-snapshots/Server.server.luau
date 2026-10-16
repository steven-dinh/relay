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

-- Intersect the game's authorized audience with the latest listener claims.
-- Readiness is not authorization or a receipt. The captured audience stays fixed;
-- call this hook when the game decides to change it, then submit current game state.
local poseState: PoseState? = nil
local function _beginPoseStream(authorizedAudience: { Player })
	local readyResult, readyError = server.events.Pose:GetReadyPlayers()
	local ready = assert(readyResult, readyError and readyError.message)
	local readySet: { [Player]: boolean } = {}
	for _, player in ready do readySet[player] = true end
	local audience: { Player } = {}
	for _, player in authorizedAudience do
		if readySet[player] then table.insert(audience, player) end
	end
	if poseState ~= nil then poseState:Destroy(); poseState = nil end
	if #audience == 0 then return end
	local stateResult, stateError = server:CreateState(audience, 0.02)
	poseState = assert(stateResult, stateError and stateError.message)
end

-- Call for each authoritative pose update, using a monotonically increasing
-- u32 tick that continues across lane recreation. Key 1 is the only demo entity;
-- repeated Puts replace its still-pending absolute snapshot until service.
local function _publishPose(tick: number, position: Vector3): (boolean, Relay.RelayError?, Relay.StateStatus?)
	local state = poseState
	if state == nil then return false, nil, nil end
	local queued, queueError = state.events.Pose:Put(1, "High", tick, position)
	if not queued then
		if queueError and queueError.code == "QueueFull" then
			-- The previous pending snapshot remains intact. Skip this sample;
			-- let normal service run and submit current state on a later game update.
			-- Do not flush/retry in a loop or retain a growing retry list.
		else
			warn("Pose snapshot was not queued", queueError and queueError.code)
		end
	end

	-- This lane's counters help the game observe pressure; caps are shared across
	-- the session's lanes. lastFlush also reports automatic flush failures.
	return queued, queueError, state:GetStatus()
end

-- Use for an explicit boundary; otherwise the lane services itself after its
-- configured first-dirty delay (at most 100 ms); platform scheduling can run later.
local function _flushPose(): number?
	local state = poseState
	if state == nil then return nil end
	local flushed, flushError, report = state:Flush()
	if not flushed then
		warn("Pose flush failed", flushError and flushError.code, "local handoffs", report.logicalHandoffs)
	end
	-- Selected bodies are consumed even on uncertain handoff. This count is not
	-- a receipt; use a later absolute update rather than replaying this report.
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
