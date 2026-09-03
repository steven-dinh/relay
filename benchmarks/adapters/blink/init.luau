--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, _record, positional)
		local net = require(root.Library[if isServer then "Server" else "Client"])
		local name = if selection.payloadId == "tiny" then "Tiny" else "State"
		local outbound = net[name .. (if isServer then "S2C" else "C2S")]
		if receives then
			local inbound = net[name .. (if isServer then "C2S" else "S2C")]
			session.disconnect = if isServer then inbound.On(function(player, ...) positional(player, ...) end)
				else inbound.On(function(...) positional(nil, ...) end)
		end
		local fire = if isServer then outbound.FireAll else outbound.Fire
		session.send = if selection.payloadId == "tiny" then function(payload)
			fire(payload.sequence, payload.enabled)
		end else function(payload)
			fire(payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health)
		end
		session.flush = net.StepReplication
	end,
})
