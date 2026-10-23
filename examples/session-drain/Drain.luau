--!strict

local DRAIN_SECONDS = 10
local MAX_ACTIVE_WORK = 256

type Drain = {
	Run: (Drain, () -> ()) -> (boolean, string?),
	Shutdown: (Drain) -> boolean,
	GetActiveWork: (Drain) -> number,
}

return function<T>(session: T & { Destroy: (T) -> () }, spawn: ((() -> ()) -> thread), clock: () -> number, wait: (number) -> number)
	local closing = false
	local destroyed = false
	local active = 0
	local drained = false

	local drain: Drain = {} :: any

	function drain:Run(callback: () -> ()): (boolean, string?)
		if closing then return false, "Closing" end
		if active >= MAX_ACTIVE_WORK then return false, "TooManyActive" end

		active += 1
		spawn(function()
			local ok, problem = pcall(callback)
			active -= 1
			if not ok then warn(problem) end
		end)
		return true, nil
	end

	function drain:Shutdown(): boolean
		if destroyed then return drained end
		if closing then return false end

		closing = true
		local deadline = clock() + DRAIN_SECONDS
		while active > 0 do
			local remaining = deadline - clock()
			if remaining <= 0 then break end
			wait(math.min(0.05, remaining))
		end

		drained = active == 0 and clock() <= deadline
		session:Destroy()
		destroyed = true
		return drained
	end

	function drain:GetActiveWork(): number
		return active
	end

	return drain
end
