--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)

-- One declared benchmark profile; production admission remains enabled.
local SERVER_OPTIONS = table.freeze({
	inboundRate = table.freeze({
		perPlayer = table.freeze({ capacity = 4096, refillPerSecond = 2048 }),
		aggregate = table.freeze({ capacity = 32768, refillPerSecond = 16384 }),
	}),
})
local CLIENT_OPTIONS = table.freeze({ startupTimeoutSeconds = 1 })
local lastClientRoot: Instance? = nil

local function fail(code: string): never
	error("RELAY_RELIABLE_E_" .. code, 0)
end

local function makeSide(context: any, isServer: boolean): any
	if typeof(context.resourceRoot) ~= "Instance" then fail("CONSTRUCT") end
	local selection = context.selection
	local payloadId = selection.payloadId
	if payloadId ~= "tiny" and payloadId ~= "state" then fail("CONSTRUCT") end
	local c2s = selection.kind == "SeparateProbe" or selection.direction == "ClientToServer"
	local s2c = selection.kind == "SeparateProbe" or selection.direction == "ServerToClient"
	local fields = if payloadId == "tiny" then {
		{ name = "sequence", type = "u32" },
		{ name = "enabled", type = "boolean" },
	} else {
		{ name = "sequence", type = "u32" },
		{ name = "entityId", type = "u16" },
		{ name = "position", type = "Vector3F32", minimum = -1024, maximum = 1024 },
		{ name = "yaw", type = "f32", minimum = -180, maximum = 180 },
		{ name = "health", type = "u8", maximum = 100 },
	}
	local events = {}
	if c2s then events.Submit = { id = 1, direction = "ClientToServer", fields = fields } end
	if s2c then
		local copiedFields = {}
		for index, field in fields do copiedFields[index] = table.clone(field) end
		events.Broadcast = { id = 2, direction = "ServerToClient", fields = copiedFields }
	end
	local definition = Relay.define({ name = "RelayBenchmark", version = 1, events = events })
	if definition == nil then fail("CONSTRUCT") end
	local session: any = nil
	local sink, envelopes = context.sink, context.envelopes
	local recipients = if isServer then context.recipients else nil
	local setupComplete, deliveryOpen, tornDown = false, false, false

	local function setup()
		if setupComplete or tornDown then fail("SETUP") end
		session = if isServer then Relay.createServer(definition, SERVER_OPTIONS)
			else Relay.createClient(definition, CLIENT_OPTIONS)
		if session == nil then fail("SETUP") end
		if isServer and c2s then
			if session.events.Submit:Connect(function(player: Player, ...: any)
				if deliveryOpen then sink(envelopes.positional(...), { kind = "ClientToServer", sender = player }) end
			end) == nil then fail("SETUP") end
		elseif not isServer and s2c then
			if session.events.Broadcast:Connect(function(...: any)
				if deliveryOpen then sink(envelopes.positional(...), { kind = "ServerToClient" }) end
			end) == nil then fail("SETUP") end
		end
		if isServer and not session:Start() then fail("SETUP") end
		setupComplete = true
	end

	local function exactRoster(): boolean
		local actual = Players:GetPlayers()
		if #actual ~= #recipients then return false end
		for _, player in actual do
			if table.find(recipients, player) == nil then return false end
		end
		return true
	end

	local function ready(): boolean
		if not setupComplete or tornDown then fail("READY") end
		if isServer and s2c and not exactRoster() then fail("READY") end
		if not deliveryOpen and not isServer then
			-- Probe the production hierarchy without waiting. Start validates its exact
			-- identity and descriptor, and cannot yield when both leaves are present.
			local root = ReplicatedStorage:FindFirstChild("RelayRemotes")
			if root == nil or root == lastClientRoot
				or root:FindFirstChild("Definition") == nil or root:FindFirstChild("Reliable") == nil
			then
				return false
			end
			if not session:Start() then fail("READY") end
			-- Generation-token replication may precede the old global transport's
			-- removal. A new session must never bind that preceding transport.
			lastClientRoot = root
		end
		deliveryOpen = true
		return true
	end

	local function teardown()
		if tornDown then return end
		deliveryOpen, tornDown = false, true
		local owned = session
		session, sink, envelopes, recipients, definition = nil, nil, nil, nil, nil
		if owned ~= nil then owned:Destroy() end
	end

	local side: any = { setup = setup, ready = ready, teardown = teardown }
	if (isServer and s2c) or (not isServer and c2s) then
		local function send(payload: any, _boundary: any)
			if not deliveryOpen then fail(if isServer then "BROADCAST" else "SUBMIT") end
			local event = if isServer then session.events.Broadcast else session.events.Submit
			local operation = if isServer then event.Broadcast else event.Send
			local ok
			if payloadId == "tiny" then
				ok = operation(event, payload.sequence, payload.enabled)
			else
				ok = operation(event, payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health)
			end
			if not ok then fail(if isServer then "BROADCAST" else "SUBMIT") end
		end
		if isServer then side.broadcast = send else side.submit = send end
	end
	return table.freeze(side)
end

return table.freeze({
	constructServer = function(context: any): any return makeSide(context, true) end,
	constructClient = function(context: any): any return makeSide(context, false) end,
})
