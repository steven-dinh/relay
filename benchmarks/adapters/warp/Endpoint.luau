--!strict

-- Map beside Library and require before adapter construction, server before clients.
-- Warp's client constructor always yields, even when its identifier is replicated.
local Warp = require(script.Parent.Library)

local runService = game:GetService("RunService")
local isServer = runService:IsServer()
local function endpoint(name: string): any
	return if isServer
		then Warp.Server(name, { rateLimit = { maxEntrance = 1_000_000, interval = 1 } })
		else Warp.Client(name, { yieldWait = 10 })
end

if script.Parent:GetAttribute("QuickCore") == true then
	local events: any = { tiny = endpoint("RelayEventV1") }
	for _, channel in {
		{ payloadId = "schema-string", name = "RelayEventV1_Strings" },
		{ payloadId = "schema-signed", name = "RelayEventV1_Numbers" },
		{ payloadId = "schema-vector3", name = "RelayEventV1_Vectors" },
		{ payloadId = "state", name = "RelayEventV1_State" },
	} do
		events[channel.payloadId] = endpoint(channel.name)
	end
	return table.freeze(events)
end

return endpoint("RelayEventV1")
