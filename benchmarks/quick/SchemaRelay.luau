--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Fixtures = require(script.Parent.SchemaFixtures)
local SERVER_OPTIONS = table.freeze({ inboundRate = table.freeze({
	perPlayer = table.freeze({ capacity = 4096, refillPerSecond = 2048 }),
	aggregate = table.freeze({ capacity = 32768, refillPerSecond = 16384 }),
}) })
local CLIENT_OPTIONS = table.freeze({ startupTimeoutSeconds = 1 })
local lastClientRoot = nil

local function makeSide(context: any, isServer: boolean): any
	local selection = context.selection
	local fields = Fixtures.fields[selection.payloadId]
	assert(selection.schema == true and selection.kind == "Workload" and selection.direction == "ClientToServer"
		and fields ~= nil, "invalid quick schema selection")
	local definition = assert(Relay.define({ name = "RelayQuickSchema", version = 1, events = {
		Submit = { id = 1, direction = "ClientToServer", fields = fields },
	} }))
	local session, setupComplete, deliveryOpen, tornDown = nil, false, false, false
	local function setup()
		assert(not setupComplete and not tornDown, "quick schema setup state")
		session = assert(if isServer then Relay.createServer(definition, SERVER_OPTIONS) else Relay.createClient(definition, CLIENT_OPTIONS))
		if isServer then
			local sink, envelopes = context.sink, context.envelopes
			assert(session.events.Submit:Connect(function(player, ...)
				-- The quick Session owns unexpected/late-delivery failure, including queued callbacks.
				sink(envelopes.positional(...), { kind = "ClientToServer", sender = player })
			end))
			assert(session:Start(), "quick schema server startup")
		end
		setupComplete = true
	end
	local function ready(): boolean
		assert(setupComplete and not tornDown, "quick schema ready state")
		if not isServer and not deliveryOpen then
			local root = ReplicatedStorage:FindFirstChild("RelayRemotes")
			if root == nil or root == lastClientRoot or root:FindFirstChild("Definition") == nil
				or root:FindFirstChild("Reliable") == nil then return false end
			assert(session:Start(), "quick schema client startup")
			lastClientRoot = root
		end
		deliveryOpen = true
		return true
	end
	local function teardown()
		if tornDown then return end
		tornDown, deliveryOpen = true, false
		if session then session:Destroy() session = nil end
	end
	local side: any = { setup = setup, ready = ready, teardown = teardown }
	if not isServer then
		if selection.payloadId == "schema-signed" then
			side.submit = function(payload, _boundary)
				assert(deliveryOpen, "quick schema submit state")
				assert(session.events.Submit:Send(payload.sequence, payload.small, payload.medium, payload.large), "quick schema send")
			end
		else
			local fieldName = fields[2].name
			side.submit = function(payload, _boundary)
				assert(deliveryOpen, "quick schema submit state")
				assert(session.events.Submit:Send(payload.sequence, payload[fieldName]), "quick schema send")
			end
		end
	end
	return table.freeze(side)
end

return table.freeze({
	constructServer = function(context: any): any return makeSide(context, true) end,
	constructClient = function(context: any): any return makeSide(context, false) end,
})
