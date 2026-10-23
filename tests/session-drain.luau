--!strict
local newDrain = require("../examples/session-drain/Drain")

local function fixture(resumeOnWait: boolean?, overshootLastWait: boolean?)
	local now = 0
	local jobs = {}
	local destroyed = false
	local destroyCount = 0
	local drain
	local function spawn(callback)
		local thread = coroutine.create(callback)
		jobs[#jobs + 1] = thread
		local ok, problem = coroutine.resume(thread)
		assert(ok, problem)
		return thread
	end
	local function wait(seconds)
		now += seconds
		if overshootLastWait and now >= 9.95 then now += 0.1 end
		if resumeOnWait and (not overshootLastWait or now > 10) then
			for _, thread in jobs do
				if coroutine.status(thread) == "suspended" then
					local ok, problem = coroutine.resume(thread)
					assert(ok, problem)
				end
			end
		end
		return seconds
	end
	local session = {
		Destroy = function()
			if not destroyed then destroyed = true; destroyCount += 1 end
		end,
	}
	drain = newDrain(session, spawn, function() return now end, wait)
	return drain, session, jobs, function() return now end, function() return destroyCount end
end

local drained, _, _, _, completedDestroyCount = fixture(true)
local completed = false
assert(drained:Run(function() coroutine.yield(); completed = true end))
assert(drained:GetActiveWork() == 1)
assert(drained:Shutdown() and completed and drained:GetActiveWork() == 0)
assert(not drained:Run(function() end))
assert(completedDestroyCount() == 1 and drained:Shutdown())
assert(completedDestroyCount() == 1, "shutdown destroys the session once")

local late, lateSession, lateJobs, lateNow, lateDestroyCount = fixture(false)
assert(late:Run(function() coroutine.yield() end))
local diagnosticsInFlight = 1
diagnosticsInFlight = 0 -- Player removal/teardown may clear Relay's own count first.
assert(diagnosticsInFlight == 0 and late:GetActiveWork() == 1,
	"Relay bookkeeping cleanup must not complete application work")
lateSession:Destroy() -- Models player-removal teardown clearing Relay's own bookkeeping.
assert(not late:Shutdown(), "session teardown must not imply callback completion")
assert(lateNow() == 10 and late:GetActiveWork() == 1 and lateDestroyCount() == 1)
assert(not late:Run(function() end), "new work is refused during shutdown")
local resumed, resumeError = coroutine.resume(lateJobs[1])
assert(resumed, resumeError)
assert(late:GetActiveWork() == 0, "late callback completion releases its count")
assert(not late:Shutdown() and lateDestroyCount() == 1, "timed-out result remains idempotent")

local overshot, _, _, overshotNow = fixture(true, true)
assert(overshot:Run(function() coroutine.yield() end))
assert(not overshot:Shutdown(), "completion after the deadline does not count as drained")
assert(overshotNow() > 10 and overshot:GetActiveWork() == 0,
	"a scheduler wake after the deadline may observe completed work too late")

local failed = fixture(false)
assert(failed:Run(function() error("expected callback failure") end))
assert(failed:GetActiveWork() == 0, "callback error releases its count")
assert(failed:Shutdown(), "callback error does not strand shutdown")

local capped, _, capJobs = fixture(false)
for _ = 1, 256 do assert(capped:Run(function() coroutine.yield() end)) end
local accepted, refusal = capped:Run(function() end)
assert(not accepted and refusal == "TooManyActive", "active-work state stays capped")
for _, thread in capJobs do
	local resumed, resumeError = coroutine.resume(thread)
	assert(resumed, resumeError)
end
assert(capped:GetActiveWork() == 0, "all bounded work releases its count")

print("session drain lifecycle checks passed")
