--!strict

-- Fixed C2S endpoints shared by the quick benchmark's matched payload suite.
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fixtures = require(script.Parent.SchemaFixtures)

local CHANNELS = table.freeze({
	{ payloadId = "tiny", name = "RelayEventV1", key = "Tiny" },
	{ payloadId = "schema-string", name = "RelayEventV1_Strings", key = "Strings" },
	{ payloadId = "schema-signed", name = "RelayEventV1_Numbers", key = "Numbers" },
	{ payloadId = "schema-vector3", name = "RelayEventV1_Vectors", key = "Vectors" },
	{ payloadId = "state", name = "RelayEventV1_State", key = "State" },
})

local CORE_SCHEMAS = table.freeze({
	tiny = table.freeze({ sequence = "NumberU32", enabled = "Boolean" }),
	["schema-string"] = table.freeze({ sequence = "NumberU32", text = "String" }),
	["schema-signed"] = table.freeze({ sequence = "NumberU32", small = "NumberI8", medium = "NumberI16", large = "NumberI32" }),
	["schema-vector3"] = table.freeze({ sequence = "NumberU32", position = "Vector3F32" }),
	state = table.freeze({ sequence = "NumberU32", entityId = "NumberU16", position = "Vector3F32", yaw = "NumberF32", health = "NumberU8" }),
})
local BYTENET_TYPES = table.freeze({ NumberU32 = "uint32", NumberU16 = "uint16", NumberU8 = "uint8",
	NumberI8 = "int8", NumberI16 = "int16", NumberI32 = "int32", NumberF32 = "float32",
	Boolean = "bool", String = "string", Vector3F32 = "vec3" })
local SATSET_TYPES = table.freeze({ NumberU32 = "u32", NumberU16 = "u16", NumberU8 = "u8",
	NumberI8 = "i8", NumberI16 = "i16", NumberI32 = "i32", NumberF32 = "f32",
	Boolean = "bool", String = "string", Vector3F32 = "Vector3" })

local function args(payloadId: string, payload: any): ...any
	if payloadId == "tiny" then return payload.sequence, payload.enabled end
	if payloadId == "schema-string" then return payload.sequence, payload.text end
	if payloadId == "schema-signed" then return payload.sequence, payload.small, payload.medium, payload.large end
	if payloadId == "schema-vector3" then return payload.sequence, payload.position end
	return payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health
end

local function relayDefinitionSpec(): any
	local tiny = {
		{ name = "sequence", type = "u32" }, { name = "enabled", type = "boolean" },
	}
	local state = {
		{ name = "sequence", type = "u32" }, { name = "entityId", type = "u16" },
		{ name = "position", type = "Vector3F32", minimum = -1024, maximum = 1024 },
		{ name = "yaw", type = "f32", minimum = -180, maximum = 180 },
		{ name = "health", type = "u8", maximum = 100 },
	}
	local payloads = { tiny = tiny, state = state }
	for _, channel in CHANNELS do
		if payloads[channel.payloadId] == nil then payloads[channel.payloadId] = Fixtures.fields[channel.payloadId] end
	end
	local events = {}
	for index, channel in CHANNELS do
		events[channel.key] = {
			id = index,
			direction = "ClientToServer",
			fields = payloads[channel.payloadId],
		}
	end
	return { name = "RelayQuickCore", version = 1, events = events }
end

local function makeSide(context: any, isServer: boolean): any
	local root = context.resourceRoot
	assert(typeof(root) == "Instance" and root:GetAttribute("QuickCore") == true, "quick core root required")
	assert(type(context.activePayloadId) == "function" and type(context.sink) == "function", "quick core context required")
	local libraryId = root.Name
	local envelopes, sink = context.envelopes, context.sink
	local open, setupComplete, tornDown = false, false, false
	local senders, handles, connections = {}, {}, {}
	local session, definition, namespace = nil, nil, nil
	local sessionStarted = false

	local function deliver(payloadId: string, player: any, ...: any)
		if open then
			sink(envelopes.positional(...), { kind = "ClientToServer", sender = player, payloadId = payloadId })
		end
	end

	local function deliverRecord(payloadId: string, player: any, value: any)
		if open then
			sink(envelopes.record(value), { kind = "ClientToServer", sender = player, payloadId = payloadId })
		end
	end

	local function exactRoster(): boolean
		local recipients = context.recipients
		if type(recipients) ~= "table" then return false end
		local actual = Players:GetPlayers()
		if #actual ~= #recipients then return false end
		for _, player in actual do
			if table.find(recipients, player) == nil then return false end
		end
		return true
	end

	local function setupNative()
		local known = {}
		for _, channel in CHANNELS do known[channel.name] = channel.payloadId end
		local function attach(remote: Instance)
			local payloadId = known[remote.Name]
			if payloadId == nil or handles[payloadId] ~= nil or not remote:IsA("RemoteEvent") then return end
			handles[payloadId] = remote
			if isServer then
				connections[#connections + 1] = (remote :: RemoteEvent).OnServerEvent:Connect(function(player, ...)
					deliver(payloadId, player, ...)
				end)
			else
				connections[#connections + 1] = (remote :: RemoteEvent).OnClientEvent:Connect(function(...)
					deliver(payloadId, nil, ...)
				end)
			end
		end
		connections[#connections + 1] = root.ChildAdded:Connect(attach)
		if isServer then
			for _, channel in CHANNELS do
				local remote = Instance.new("RemoteEvent")
				remote.Name = channel.name
				handles[channel.payloadId] = remote
				connections[#connections + 1] = remote.OnServerEvent:Connect(function(player, ...)
					deliver(channel.payloadId, player, ...)
				end)
				remote.Parent = root
			end
		else
			for _, child in root:GetChildren() do attach(child) end
		end
		for _, channel in CHANNELS do
			senders[channel.payloadId] = function(payload: any)
				local remote = handles[channel.payloadId]
				assert(remote ~= nil, "quick core native endpoint is not ready")
				local typedRemote = remote :: RemoteEvent
				typedRemote:FireServer(args(channel.payloadId, payload))
			end
		end
	end

	local function setupRelay()
		local Relay = require(ReplicatedStorage.Relay)
		definition = assert(Relay.define(relayDefinitionSpec()))
		local options = table.freeze({ inboundRate = table.freeze({
			perPlayer = table.freeze({ capacity = 4096, refillPerSecond = 2048 }),
			aggregate = table.freeze({ capacity = 32768, refillPerSecond = 16384 }),
		}) })
		session = if isServer then Relay.createServer(definition, options)
			else Relay.createClient(definition, { startupTimeoutSeconds = 1 })
		assert(session ~= nil, "quick core Relay session creation failed")
		for _, channel in CHANNELS do
			local payloadId = channel.payloadId
			if isServer then
				assert(session.events[channel.key]:Connect(function(player, ...)
					deliver(payloadId, player, ...)
				end) ~= nil, "quick core Relay listener registration failed")
			end
			handles[payloadId] = session.events[channel.key]
			senders[payloadId] = function(payload: any)
				assert(session.events[channel.key]:Send(args(payloadId, payload)), "quick core Relay send failed")
			end
		end
		if isServer then
			local started, issue = session:Start()
			assert(started, "quick core Relay server startup failed: " .. tostring(issue and issue.code))
			sessionStarted = true
		end
	end

	local function setupRuntime()
		if libraryId == "quicknet" then
			local net = require(root.Library)
			for _, channel in CHANNELS do
				local payloadId = channel.payloadId
				local schema = {}
				for name, typeName in CORE_SCHEMAS[payloadId] do schema[name] = net.Data[typeName] end
				local event = net:register(channel.name, schema)
				event:SetRateLimit(1_000_000, 1)
				handles[payloadId] = event
				if isServer then
					connections[#connections + 1] = event.OnServerEvent:Connect(function(player, value)
						deliverRecord(payloadId, player, value)
					end)
				end
				senders[payloadId] = if isServer then function() error("quick core server cannot submit", 0) end
					else function(payload) event:FireServer(payload) end
			end
		elseif libraryId == "bytenet" then
			local net = require(root.Library)
			namespace = net.defineNamespace("RelayEventV1", function()
				local packetSchemas = {}
				for _, channel in CHANNELS do
					local schema = {}
					for name, typeName in CORE_SCHEMAS[channel.payloadId] do
						schema[name] = net[BYTENET_TYPES[typeName]]
					end
					packetSchemas[channel.key] = net.definePacket({
						value = net.struct(schema), reliabilityType = "reliable",
					})
				end
				return packetSchemas
			end)
			for _, channel in CHANNELS do
				local payloadId = channel.payloadId
				local event = namespace[channel.key]
				handles[payloadId] = event
				if isServer then event.listen(function(value, player) deliverRecord(payloadId, player, value) end) end
				senders[payloadId] = if isServer then function() error("quick core server cannot submit", 0) end
					else function(payload) event.send(payload) end
			end
		elseif libraryId == "satset" then
			local net = require(root.Library)
			local types = net.Types
			for _, channel in CHANNELS do
				local payloadId = channel.payloadId
				local schema = {}
				for name, typeName in CORE_SCHEMAS[payloadId] do schema[name] = types[SATSET_TYPES[typeName]] end
				handles[payloadId] = net.definePacket({ name = channel.name, schema = schema, reliable = true })
			end
			net.start()
			for _, channel in CHANNELS do
				local payloadId = channel.payloadId
				local event = handles[payloadId]
				if isServer then event:listenServer(function(player, value) deliverRecord(payloadId, player, value) end) end
				senders[payloadId] = if isServer then function() error("quick core server cannot submit", 0) end
					else function(payload) event:fireServer(payload) end
			end
		elseif libraryId == "warp" then
			local events = require(root.Endpoint)
			for _, channel in CHANNELS do
				local payloadId = channel.payloadId
				local event = events[payloadId]
				assert(event ~= nil, "quick core Warp endpoint missing")
				handles[payloadId] = event
				if isServer then
					local key = event:Connect(function(player, ...) deliver(payloadId, player, ...) end)
					connections[#connections + 1] = function() event:Disconnect(key) end
				end
				senders[payloadId] = if isServer then function() error("quick core server cannot submit", 0) end
					else function(payload)
						event:Fire(true, args(payloadId, payload))
					end
			end
		elseif libraryId == "blink" or libraryId == "zap" or libraryId == "netray-compile" then
			local net = require(root.Library[if isServer then "Server" else "Client"])
			local names = if libraryId == "netray-compile"
				then { tiny = "Tiny", ["schema-string"] = "Strings", ["schema-signed"] = "Numbers", ["schema-vector3"] = "Vectors", state = "State" }
				else { tiny = "TinyC2S", ["schema-string"] = "StringsC2S", ["schema-signed"] = "NumbersC2S", ["schema-vector3"] = "VectorsC2S", state = "StateC2S" }
			for _, channel in CHANNELS do
				local payloadId = channel.payloadId
				local event = net[names[payloadId]]
				assert(event ~= nil, "quick core generated endpoint missing: " .. names[payloadId])
				handles[payloadId] = event
				if isServer then
					local callback = function(player, ...) deliver(payloadId, player, ...) end
					local cleanup = if libraryId == "zap" then event.SetCallback(callback) else event.On(callback)
					if type(cleanup) == "function" then connections[#connections + 1] = cleanup
					elseif cleanup ~= nil and type(cleanup.Disconnect) == "function" then
						connections[#connections + 1] = function() cleanup:Disconnect() end
					end
				end
				senders[payloadId] = if isServer then function() error("quick core server cannot submit", 0) end
					else function(payload)
						event.Fire(args(payloadId, payload))
					end
			end
			if libraryId == "blink" then session = { flush = net.StepReplication }
			elseif libraryId == "zap" then session = { flush = net.SendEvents }
			else session = { flush = net.StepReplication } end
		else
			error("unsupported quick core adapter: " .. libraryId, 0)
		end
	end

	local side: any = {}
	function side.setup()
		assert(not setupComplete and not tornDown, "quick core setup state")
		if libraryId == "native-reliable" then setupNative()
		elseif libraryId == "relay-reliable" then setupRelay()
		else setupRuntime() end
		setupComplete = true
	end
	function side.ready(): boolean
		assert(setupComplete and not tornDown, "quick core ready state")
		if libraryId == "relay-reliable" and not isServer and not sessionStarted then
			local rootRemotes = ReplicatedStorage:FindFirstChild("RelayRemotes")
			if rootRemotes == nil or rootRemotes:FindFirstChild("Definition") == nil
				or rootRemotes:FindFirstChild("Reliable") == nil then return false end
			assert(session:Start(), "quick core Relay client startup failed")
			sessionStarted = true
		end
		for _, channel in CHANNELS do
			if handles[channel.payloadId] == nil then return false end
		end
		if libraryId == "native-reliable" then
			if #root:GetChildren() ~= #CHANNELS then return false end
			for _, channel in CHANNELS do
				local remote = handles[channel.payloadId]
				if remote == nil or remote.Parent ~= root or remote.Name ~= channel.name then return false end
			end
		elseif libraryId == "quicknet" then
			local reliable = root.Library.QuickNetRemote
			local seen = {}
			for _, channel in CHANNELS do
				local identifierId = reliable:GetAttribute(channel.name)
				if type(identifierId) ~= "number" or identifierId % 1 ~= 0 or identifierId < 1
					or identifierId > 255 or seen[identifierId] then return false end
				seen[identifierId] = true
			end
		elseif libraryId == "bytenet" then
			local store = ReplicatedStorage:FindFirstChild("BytenetStorage")
			local replicated = if store == nil then nil else store:FindFirstChild("RelayEventV1")
			if replicated == nil or replicated.Value == "" then return false end
			local packetIds = HttpService:JSONDecode(replicated.Value).packets
			local seen = {}
			for _, channel in CHANNELS do
				local identifierId = packetIds[channel.key]
				if type(identifierId) ~= "number" or seen[identifierId] then return false end
				seen[identifierId] = true
			end
		elseif libraryId == "relay-reliable" then
			for _, channel in CHANNELS do assert(handles[channel.payloadId] ~= nil, "quick core Relay endpoint missing") end
		end
		if isServer and libraryId == "native-reliable" and not exactRoster() then return false end
		if isServer and libraryId == "relay-reliable" and not exactRoster() then return false end
		if libraryId == "warp" then
			local library = root.Library
			local eventFolder = library.Index.Event
			local reliable = eventFolder.Reliable
			local seen = {}
			for _, channel in CHANNELS do
				local event = handles[channel.payloadId]
				local identifierId = reliable:GetAttribute(channel.name)
				if type(identifierId) ~= "number" or identifierId % 1 ~= 0 or identifierId < 1 or identifierId > 255
					or seen[identifierId] or reliable:GetAttribute(tostring(identifierId)) ~= channel.name
					or type(event.id) ~= "string" or #event.id ~= 1 or string.byte(event.id, 1) ~= identifierId
				then return false end
				seen[identifierId] = true
			end
		end
		open = true
		return true
	end
	function side.teardown()
		if tornDown then return end
		open, tornDown = false, true
		for _, connection in connections do
			if type(connection) == "function" then pcall(connection)
			else pcall(function() connection:Disconnect() end) end
		end
		table.clear(connections)
		if libraryId == "relay-reliable" and session ~= nil then session:Destroy() end
		if isServer and libraryId == "native-reliable" then
			for _, remote in handles do pcall(function() remote:Destroy() end) end
		end
		table.clear(senders)
		table.clear(handles)
		sink, envelopes, session, definition, namespace, root = nil, nil, nil, nil, nil, nil
	end
	if not isServer then
		side.submit = function(payload: any, boundary: string)
			assert(open, "quick core submit state")
			local payloadId = context.activePayloadId()
			local send = senders[payloadId]
			assert(send ~= nil, "quick core category endpoint missing")
			send(payload)
			if boundary == "FlushBeforeReturn" and session ~= nil and session.flush ~= nil then session.flush() end
		end
	end
	return table.freeze(side)
end

return table.freeze({
	constructServer = function(context: any): any return makeSide(context, true) end,
	constructClient = function(context: any): any return makeSide(context, false) end,
	-- The focused raw-input test feeds the exact same event spec to ServerRuntime.
	relayDefinitionSpecForTests = function(): any return relayDefinitionSpec() end,
})
