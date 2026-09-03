--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, _record, positional)
		local Packet = require(root.Library)
		local tiny = selection.payloadId == "tiny"
		local event = if tiny then Packet("RelayEventV1", Packet.NumberU32, Packet.Boolean8)
			else Packet("RelayEventV1", Packet.NumberU32, Packet.NumberU16,
				Packet.Vector3F32, Packet.NumberF32, Packet.NumberU8)
		if receives then
			local connection = if isServer then event.OnServerEvent:Connect(function(player, ...)
				positional(player, ...)
			end) else event.OnClientEvent:Connect(function(...)
				positional(nil, ...)
			end)
			session.disconnect = function() connection:Disconnect() end
		end
		session.ready = function() return event.Id ~= nil end
		session.send = if tiny then function(payload) event:Fire(payload.sequence, payload.enabled) end
			else function(payload)
				event:Fire(payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health)
			end
	end,
})
