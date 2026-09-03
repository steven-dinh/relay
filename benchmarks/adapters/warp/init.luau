--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, _record, positional)
		-- Endpoint must already be cached by the untimed bootstrap.
		local event = require(root.Endpoint)
		if receives then
			local key = if isServer then event:Connect(function(player, ...) positional(player, ...) end)
				else event:Connect(function(...) positional(nil, ...) end)
			-- The pinned Destroy calls a missing buffer method; only detach this callback.
			session.disconnect = function() event:Disconnect(key) end
		end
		local fire = if isServer then event.Fires else event.Fire
		session.send = if selection.payloadId == "tiny" then function(payload)
			fire(event, true, payload.sequence, payload.enabled)
		end else function(payload)
			fire(event, true, payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health)
		end
	end,
})
