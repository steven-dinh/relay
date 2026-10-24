--!strict

local ExternalAdapter = require(script.Parent.ExternalAdapter)

local function valueFor(payloadId: string, payload: any): any
	if payloadId == "tiny" then
		return { Sequence = payload.sequence, Enabled = payload.enabled }
	elseif payloadId == "state" then
		return {
			Sequence = payload.sequence,
			EntityId = payload.entityId,
			PositionX = payload.position.X,
			PositionY = payload.position.Y,
			PositionZ = payload.position.Z,
			Yaw = payload.yaw,
			Health = payload.health,
		}
	end
end

local function receive(positional: any, payloadId: string, player: any, payload: any)
	if payloadId == "tiny" then
		positional(player, payload.Sequence, payload.Enabled)
	elseif payloadId == "state" then
		positional(player, payload.Sequence, payload.EntityId,
			Vector3.new(payload.PositionX, payload.PositionY, payload.PositionZ), payload.Yaw, payload.Health)
	end
end

return ExternalAdapter.new({
	setup = function(session, root, selection, isServer, receives, _record, positional)
		local net = require(root.Library[if isServer then "Server" else "Client"])
		local payloadId = selection.payloadId
		local eventName = if payloadId == "tiny" then "Tiny" else "State"
		local outbound = net[eventName .. (if isServer then "S2C" else "C2S")]
		if receives then
			local inbound = net[eventName .. (if isServer then "C2S" else "S2C")]
			session.disconnect = if isServer then inbound.On(function(player, payload)
				receive(positional, payloadId, player, payload)
			end) else inbound.On(function(payload)
				receive(positional, payloadId, nil, payload)
			end)
		end
		session.send = if isServer then function(payload) outbound.FireAll(valueFor(payloadId, payload)) end
			else function(payload) outbound.Fire(valueFor(payloadId, payload)) end
		session.flush = net.StepReplication
	end,
})
