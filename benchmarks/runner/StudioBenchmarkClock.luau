--!strict

local Workspace = game:GetService("Workspace")

local function newPort()
	return table.freeze({
		localNowSeconds = os.clock,
		sharedNowSeconds = function(): number
			return Workspace:GetServerTimeNow()
		end,
		timeoutNowSeconds = os.clock,
	})
end

return table.freeze({ newPort = newPort })
