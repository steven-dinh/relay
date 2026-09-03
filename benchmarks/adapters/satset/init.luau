--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, record, _positional)
		local net = require(root.Library)
		local types = net.Types
		local schema = if selection.payloadId == "tiny" then {
			sequence = types.u32, enabled = types.bool,
		} else {
			sequence = types.u32, entityId = types.u16,
			position = types.Vector3, yaw = types.f32, health = types.u8,
		}
		local event = net.definePacket({ name = "RelayEventV1", schema = schema, reliable = true })
		net.start()
		if receives then
			-- Satset has no public listener removal; the shared lifecycle closes admission.
			event:listen(function(value, player) record(player, value) end)
		end
		session.send = if isServer then function(payload) event:fireAllClients(payload) end
			else function(payload) event:fireServer(payload) end
	end,
})
