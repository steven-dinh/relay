--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, record, _positional)
		local net = require(root.Library)
		local schema = if selection.payloadId == "tiny" then {
			sequence = net.uint32, enabled = net.bool,
		} else {
			sequence = net.uint32, entityId = net.uint16,
			position = net.vec3, yaw = net.float32, health = net.uint8,
		}
		local namespace = net.defineNamespace("RelayEventV1", function()
			return { Event = net.definePacket({ value = net.struct(schema), reliabilityType = "reliable" }) }
		end)
		local event = namespace.Event
		if receives then
			-- ByteNet has no public listener removal; the shared lifecycle closes admission.
			event.listen(function(value, player) record(player, value) end)
		end
		session.send = if isServer then event.sendToAll else event.send
	end,
})
