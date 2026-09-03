--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, record, _positional)
		local net = require(root.Library)
		local data = net.Data
		-- A single record avoids QuickNet 0.3.4's positional fastUnpack nil padding.
		local schema = if selection.payloadId == "tiny" then {
			sequence = data.NumberU32, enabled = data.Boolean,
		} else {
			sequence = data.NumberU32, entityId = data.NumberU16,
			position = data.Vector3F32, yaw = data.NumberF32, health = data.NumberU8,
		}
		local event = net:register("RelayEventV1", schema)
		if isServer then
			-- The public default (120/s) would reject the contract's four/frame burst.
			event:SetRateLimit(1_000_000, 1)
			if receives then
				local connection = event.OnServerEvent:Connect(function(player, value) record(player, value) end)
				session.disconnect = function() connection:Disconnect() end
			end
			session.send = function(payload) event:FireAllClients(payload) end
		else
			if receives then
				local connection = event.OnClientEvent:Connect(function(value) record(nil, value) end)
				session.disconnect = function() connection:Disconnect() end
			end
			session.send = function(payload) event:FireServer(payload) end
		end
	end,
})
