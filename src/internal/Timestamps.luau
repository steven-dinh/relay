local workspace = nil

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function sample()
	local ok, value = pcall(function()
		if workspace == nil then workspace = game:GetService("Workspace") end
		return workspace:GetServerTimeNow()
	end)
	if not ok or not finite(value) then return nil end
	return value
end

local function normalize(value, window, now)
	if not finite(value) or not finite(window) or window <= 0 or window > 2 or not finite(now) then
		return nil
	end
	if value < now - window or value > now + 0.1 then return nil end
	return math.min(value, now)
end

return table.freeze({ sample = sample, normalize = normalize })
