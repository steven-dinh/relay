--!strict

local MAX_EVENTS = 2400

local function runtimeEnabled(): boolean
	local ok, value = pcall(function()
		if script == nil then return false end
		local parent = script.Parent
		if parent == nil then return false end
		local profile: any = parent:FindFirstChild("ProfileReceive")
		if profile == nil and type(parent.WaitForChild) == "function" then
			profile = parent:WaitForChild("ProfileReceive", 15)
		end
		return profile ~= nil and profile.Value == true
	end)
	return ok and value == true
end

local enabled = runtimeEnabled()
local active: any = nil
local failure: string? = nil
local failureHandler: ((string) -> ())? = nil
local cpuMarker: string? = nil
local cpuStageNames: { [string]: string }? = nil
-- MicroProfiler timer descriptors retain 63 bytes; root + slash + suffix must fit.
local STAGE_SUFFIX: { [string]: string } = {
	["send.validate-encode"] = "sv",
	["send.handoff"] = "sh",
	["receive.total"] = "rt",
	["receive.validate-decode"] = "rv",
	["receive.dispatch"] = "rd",
}

local function reject(reason: string): never
	error("receive callback profile: " .. reason, 0)
end

local function latch(reason: string)
	if failure ~= nil then return end
	failure = reason
	local handler = failureHandler
	if handler ~= nil then pcall(handler, reason) end
end

local function validateAdapter(adapterId: any): string
	if type(adapterId) ~= "string" or adapterId == "" then
		reject("adapterId must be a non-empty string")
	end
	return adapterId
end

local function validateExpected(expectedCount: any): number
	if type(expectedCount) ~= "number" or expectedCount % 1 ~= 0
		or expectedCount < 1 or expectedCount > MAX_EVENTS then
		reject(`expectedCount must be an integer in 1..{MAX_EVENTS}`)
	end
	return expectedCount
end

-- This helper is deliberately the final call in the wrapper. Its varargs are
-- therefore the callback's original returns, including trailing nil values.
-- The end clock is read before the sample is inserted or any result is copied.
local function complete(state: any, started: number, ...: any): ...any
	local ended = os.clock()
	state.inflight -= 1

	if active ~= state then
		latch("callback completed after its phase ended")
	elseif state.count >= state.expected then
		latch("receive callback count exceeded expectedCount")
	else
		state.count += 1
		state.samples[state.count] = ended - started
	end

	return ...
end

local function finishScope(ok: boolean, ...: any): ...any
	debug.profileend()
	if not ok then error(select(1, ...), 0) end
	return ...
end

local function setCpuMarker(marker: string?)
	if marker ~= nil and (marker == "" or #marker > 60) then
		error("receive callback profile: CPU marker must be 1..60 bytes or nil", 0)
	end
	local stageNames: { [string]: string }? = nil
	if marker ~= nil then
		local names: { [string]: string } = {}
		for stage, suffix in STAGE_SUFFIX do names[stage] = marker .. "/" .. suffix end
		stageNames = names
	end
	cpuMarker = marker
	cpuStageNames = stageNames
end

-- Profile callbacks are synchronous benchmark work. Yielding handlers are not
-- supported because they would keep the engine marker open across a yield.
local function scope(stage: string, callback: (...any) -> ...any, ...: any): ...any
	local suffix = STAGE_SUFFIX[stage]
	if suffix == nil then error("receive callback profile: unsupported CPU stage: " .. stage, 0) end
	local stageNames = cpuStageNames
	if stageNames == nil then return callback(...) end
	debug.profilebegin(stageNames[stage] :: string)
	return finishScope(pcall(callback, ...))
end

local function begin(adapterId: string, expectedCount: number)
	if not enabled then return end
	if active ~= nil then reject("begin called while a phase is active") end
	if failure ~= nil then reject(failure) end
	adapterId = validateAdapter(adapterId)
	expectedCount = validateExpected(expectedCount)
	active = {
		adapterId = adapterId,
		expected = expectedCount,
		count = 0,
		inflight = 0,
		samples = table.create(expectedCount),
	}
end

local function wrap(adapterId: string, callback: (...any) -> ...any): (...any) -> ...any
	-- Returning the original callback is important when the profile is disabled:
	-- there is no clock read, closure, or sample allocation on that path.
	if not enabled then return callback end
	adapterId = validateAdapter(adapterId)
	assert(type(callback) == "function", "receive callback profile: callback must be a function")
	return function(...: any): ...any
		local state = active
		if failure ~= nil then
			return callback(...)
		end
		if state == nil then
			latch("callback arrived outside an active phase")
			return callback(...)
		end
		if state.adapterId ~= adapterId then
			latch("callback arrived for the wrong adapter phase")
			return callback(...)
		end
		if state.count + state.inflight >= state.expected then
			latch("callback count exceeded expectedCount")
			return callback(...)
		end

		state.inflight += 1
		local started = os.clock()
		if cpuMarker ~= nil then
			return complete(state, started, scope("receive.total", callback, ...))
		end
		return complete(state, started, callback(...))
	end
end

local function finish(adapterId: string): { number }
	if not enabled then return {} end
	adapterId = validateAdapter(adapterId)
	local state = active
	if state == nil then reject("finish called without an active phase") end
	if state.adapterId ~= adapterId then reject("finish called for the wrong adapter phase") end
	if failure ~= nil then reject(failure) end
	if state.inflight ~= 0 then reject("finish called while callbacks are still in flight") end
	if state.count ~= state.expected then
		reject(`expected {state.expected} callbacks but recorded {state.count}`)
	end
	local samples = state.samples
	active = nil
	return samples
end

local function setFailureHandler(handler: ((string) -> ())?)
	if not enabled then return end
	assert(handler == nil or type(handler) == "function",
		"receive callback profile: failure handler must be a function or nil")
	failureHandler = handler
	if failure ~= nil and handler ~= nil then pcall(handler, failure) end
end

return table.freeze({
	enabled = enabled,
	setCpuMarker = setCpuMarker,
	scope = scope,
	begin = begin,
	wrap = wrap,
	finish = finish,
	setFailureHandler = setFailureHandler,
})
