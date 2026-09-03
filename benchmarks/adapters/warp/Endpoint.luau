--!strict

-- Map beside Library and require before adapter construction, server before clients.
-- Warp's client constructor always yields, even when its identifier is replicated.
local Warp = require(script.Parent.Library)

return if game:GetService("RunService"):IsServer()
	then Warp.Server("RelayEventV1", { rateLimit = { maxEntrance = 1_000_000, interval = 1 } })
	else Warp.Client("RelayEventV1", { yieldWait = 10 })
