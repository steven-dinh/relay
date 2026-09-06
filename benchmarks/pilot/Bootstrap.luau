-- Editor-only bridge. The capability never enters the multiplayer test arguments.
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local carrierModule = game:GetService("ServerStorage"):WaitForChild("RelayBenchmarkServer"):WaitForChild("LaunchCarrier")
local carrier = require(carrierModule)
carrierModule:Destroy()

local ok, result = pcall(function()
	return StudioTestService:ExecuteMultiplayerTestAsync(1, { launchId = carrier.launchId })
end)
local body
if ok and type(result) == "string" and #result > 0 and #result <= 65_536 then
	local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, result)
	if decodedOk and type(decoded) == "table" then
		decoded.studioVersion = version()
		body = HttpService:JSONEncode(decoded)
	end
end
if body == nil or #body > 65_536 then
	body = HttpService:JSONEncode({
		kind = "RelaySessionReusePilot", version = 1, launchId = carrier.launchId,
		adapterId = carrier.adapterId, status = "Failed", studioVersion = version(),
		error = "Pilot execution did not return a bounded result",
	})
end

local function hex(value)
	return (string.gsub(value, ".", function(character)
		return string.format("%02x", string.byte(character))
	end))
end
local count = math.ceil(#body / 1024)
for index = 1, count do
	print("RELAY_SESSION_PILOT_1 " .. carrier.capability .. " " .. carrier.launchId .. " "
		.. tostring(index) .. " " .. tostring(count) .. " "
		.. hex(string.sub(body, (index - 1) * 1024 + 1, index * 1024)))
end
