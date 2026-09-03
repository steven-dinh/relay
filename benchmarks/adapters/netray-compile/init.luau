--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, _record, positional)
		local net = require(root.Library[if isServer then "Server" else "Client"])
		local event = net[if selection.payloadId == "tiny" then "Tiny" else "State"]
		if receives then
			local connection = if isServer then event.On(function(player, ...) positional(player, ...) end)
				else event.On(function(...) positional(nil, ...) end)
			session.disconnect = function() connection:Disconnect() end
		end
		local fire = if isServer then event.FireAll else event.Fire
		session.send = if selection.payloadId == "tiny" then function(payload)
			fire(payload.sequence, payload.enabled)
		end else function(payload)
			fire(payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health)
		end
		session.flush = net.StepReplication
	end,
})
