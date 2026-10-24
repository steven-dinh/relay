--!strict

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
local COMPOSITE_CHANNEL = table.freeze({ payloadId = "schema-composite", name = "RelayEventV1_Composite", key = "Composite" })

local function selectedChannels(context: any): { any }
	local channels = table.clone(CHANNELS)
	if context.selection.kind == "RpcProbe" then return {} end
	if table.find(context.corePayloadIds or {}, "schema-composite-c2s") ~= nil then
		table.insert(channels, COMPOSITE_CHANNEL)
	end
	return channels
end

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
	if payloadId == "schema-composite" then return payload.sequence, payload.items end
	return payload.sequence, payload.entityId, payload.position, payload.yaw, payload.health
end

local function blinkBloxValue(payloadId: string, payload: any): any
	if payloadId == "tiny" then return { Sequence = payload.sequence, Enabled = payload.enabled } end
	if payloadId == "schema-string" then return { Sequence = payload.sequence, Text = payload.text } end
	if payloadId == "schema-signed" then
		return { Sequence = payload.sequence, Small = payload.small, Medium = payload.medium, Large = payload.large }
	end
	if payloadId == "schema-vector3" then
		return { Sequence = payload.sequence, PositionX = payload.position.X, PositionY = payload.position.Y, PositionZ = payload.position.Z }
	end
	if payloadId == "state" then
		-- BlinkBlox v1.2.1 bounds vector magnitude, not each component. These
		-- bounded scalar fields are restored to Relay's Vector3 shape here.
		return {
			Sequence = payload.sequence, EntityId = payload.entityId,
			PositionX = payload.position.X, PositionY = payload.position.Y, PositionZ = payload.position.Z,
			Yaw = payload.yaw, Health = payload.health,
		}
	end
	local items = table.create(#payload.items)
	for index, item in payload.items do
		items[index] = { EntityId = item.entityId, Score = item.score, Enabled = item.enabled }
	end
	return { Sequence = payload.sequence, Items = items }
end

local function blinkBloxPayload(payloadId: string, payload: any): any
	if payloadId == "tiny" then return { sequence = payload.Sequence, enabled = payload.Enabled } end
	if payloadId == "schema-string" then return { sequence = payload.Sequence, text = payload.Text } end
	if payloadId == "schema-signed" then
		return { sequence = payload.Sequence, small = payload.Small, medium = payload.Medium, large = payload.Large }
	end
	if payloadId == "schema-vector3" then
		return {
			sequence = payload.Sequence,
			position = Vector3.new(payload.PositionX, payload.PositionY, payload.PositionZ),
		}
	end
	if payloadId == "state" then
		return {
			sequence = payload.Sequence, entityId = payload.EntityId,
			position = Vector3.new(payload.PositionX, payload.PositionY, payload.PositionZ),
			yaw = payload.Yaw, health = payload.Health,
		}
	end
	local items = table.create(#payload.Items)
	for index, item in payload.Items do
		items[index] = { entityId = item.EntityId, score = item.Score, enabled = item.Enabled }
	end
	return { sequence = payload.Sequence, items = items }
end

local function relayRpcDefinitionSpec(): any
	return {
		name = "RelayQuickRpc",
		version = 1,
		events = {},
		requests = {
			TinyRpc = {
				id = 1,
				request = { { name = "sequence", type = "u32" }, { name = "enabled", type = "boolean" } },
				response = { type = "struct", fields = {
					{ name = "sequence", type = "u32" }, { name = "enabled", type = "boolean" },
				} },
			},
		},
	}
end

local function relayDefinitionSpec(includeComposite: boolean?): any
	local tiny = {
		{ name = "sequence", type = "u32" }, { name = "enabled", type = "boolean" },
	}
	local state = {
		{ name = "sequence", type = "u32" }, { name = "entityId", type = "u16" },
		{ name = "position", type = "Vector3F32", minimum = -1024, maximum = 1024 },
		{ name = "yaw", type = "f32", minimum = -180, maximum = 180 },
		{ name = "health", type = "u8", maximum = 100 },
	}
	local channels = table.clone(CHANNELS)
	if includeComposite then table.insert(channels, COMPOSITE_CHANNEL) end
	local payloads = { tiny = tiny, state = state }
	for _, channel in channels do
		if payloads[channel.payloadId] == nil then payloads[channel.payloadId] = Fixtures.fields[channel.payloadId] end
	end
	local events = {}
	for index, channel in channels do
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
	local rpcProbe = context.selection.kind == "RpcProbe"
	local channels = selectedChannels(context)
	local envelopes, sink = context.envelopes, context.sink
	local open, setupComplete, tornDown = false, false, false
	local senders, handles, connections = {}, {}, {}
	local session, definition, namespace, invoke, rpcRemoteNames = nil, nil, nil, nil, nil
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

	local function deliverReply(payloadId: string, value: any)
		if open then sink(envelopes.record(value), { kind = "ServerToClient", payloadId = payloadId }) end
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
		if isServer then
			for _, channel in channels do
				local remote = Instance.new("RemoteEvent")
				remote.Name = channel.name
				handles[channel.payloadId] = remote
				connections[#connections + 1] = remote.OnServerEvent:Connect(function(player, ...)
					deliver(channel.payloadId, player, ...)
				end)
				remote.Parent = root
			end
		else
			local known = {}
			for _, channel in channels do known[channel.name] = channel.payloadId end
			local function attach(remote: Instance)
				local payloadId = known[remote.Name]
				if payloadId == nil or handles[payloadId] ~= nil or not remote:IsA("RemoteEvent") then return end
				handles[payloadId] = remote
				connections[#connections + 1] = (remote :: RemoteEvent).OnClientEvent:Connect(function(...)
					deliver(payloadId, nil, ...)
				end)
			end
			connections[#connections + 1] = root.ChildAdded:Connect(attach)
			for _, child in root:GetChildren() do attach(child) end
			for _, channel in channels do
				senders[channel.payloadId] = function(payload: any)
					local remote = handles[channel.payloadId]
					assert(remote ~= nil, "quick core native endpoint is not ready")
					local typedRemote = remote :: RemoteEvent
					typedRemote:FireServer(args(channel.payloadId, payload))
				end
			end
		end
	end

	local function setupRelay()
		local Relay = require(ReplicatedStorage.Relay)
		definition = assert(Relay.define(if rpcProbe then relayRpcDefinitionSpec()
			else relayDefinitionSpec(table.find(context.corePayloadIds or {}, "schema-composite-c2s") ~= nil)))
		if isServer then
			local options = table.freeze({ inboundRate = table.freeze({
				perPlayer = table.freeze({ capacity = 4096, refillPerSecond = 2048 }),
				aggregate = table.freeze({ capacity = 32768, refillPerSecond = 16384 }),
			}) })
			session = Relay.createServer(definition, options)
		else
			session = Relay.createClient(definition, { startupTimeoutSeconds = 1 })
		end
		assert(session ~= nil, "quick core Relay session creation failed")
		if rpcProbe then
			local endpoint = session.requests.TinyRpc
			handles.tiny = endpoint
			if isServer then
				assert(endpoint:Connect(function(player, sequence, enabled)
					deliver("tiny", player, sequence, enabled)
					return { sequence = sequence, enabled = enabled }
				end) ~= nil, "quick Relay RPC listener registration failed")
			else
				invoke = function(payload: any)
					local pending = assert(endpoint:Request(context.requestTimeoutSeconds, payload.sequence, payload.enabled), "quick Relay RPC request failed")
					local response = pending:Await()
					assert(type(response) == "table" and response.ok == true and type(response.value) == "table",
						"quick Relay RPC did not return a valid response")
					deliverReply("tiny", response.value)
					return response.value
				end
			end
		end
		for _, channel in channels do
			local payloadId = channel.payloadId
			local event = session.events[channel.key]
			if isServer then
				assert(event:Connect(function(player, ...)
					deliver(payloadId, player, ...)
				end) ~= nil, "quick core Relay listener registration failed")
			end
			handles[payloadId] = event
			if not isServer then
				senders[payloadId] = function(payload: any)
					assert(event:Send(args(payloadId, payload)), "quick core Relay send failed")
				end
			end
		end
		if isServer then
			local started, issue = session:Start()
			assert(started, "quick core Relay server startup failed: " .. tostring(issue and issue.code))
			sessionStarted = true
		end
	end

	local function setupRuntime()
		if libraryId == "blinkblox" and rpcProbe then
			local net = require(root.RpcLibrary[if isServer then "Server" else "Client"])
			local endpoint = net.TinyRpc
			assert(endpoint ~= nil, "quick BlinkBlox RPC endpoint missing")
			handles.tiny = endpoint
			rpcRemoteNames = net.Remotes
			if isServer then
				endpoint.On(function(player, sequence, enabled)
					deliver("tiny", player, sequence, enabled)
					return sequence, enabled
				end)
			else
				invoke = function(payload: any)
					local sequence, enabled = endpoint.Invoke(payload.sequence, payload.enabled)
					local value = { sequence = sequence, enabled = enabled }
					deliverReply("tiny", value)
					return value
				end
			end
		elseif libraryId == "quicknet" then
			local net = require(root.Library)
			for _, channel in channels do
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
				if not isServer then
					senders[payloadId] = function(payload) event:FireServer(payload) end
				end
			end
		elseif libraryId == "bytenet" then
			local net = require(root.Library)
			namespace = net.defineNamespace("RelayEventV1", function()
				local packetSchemas = {}
				for _, channel in channels do
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
			for _, channel in channels do
				local payloadId = channel.payloadId
				local event = namespace[channel.key]
				handles[payloadId] = event
				if isServer then event.listen(function(value, player) deliverRecord(payloadId, player, value) end) end
				if not isServer then
					senders[payloadId] = function(payload) event.send(payload) end
				end
			end
		elseif libraryId == "satset" then
			local net = require(root.Library)
			local types = net.Types
			for _, channel in channels do
				local payloadId = channel.payloadId
				local schema = {}
				for name, typeName in CORE_SCHEMAS[payloadId] do schema[name] = types[SATSET_TYPES[typeName]] end
				handles[payloadId] = net.definePacket({ name = channel.name, schema = schema, reliable = true })
			end
			net.start()
			for _, channel in channels do
				local payloadId = channel.payloadId
				local event = handles[payloadId]
				if isServer then event:listenServer(function(player, value) deliverRecord(payloadId, player, value) end) end
				if not isServer then
					senders[payloadId] = function(payload) event:fireServer(payload) end
				end
			end
		elseif libraryId == "warp" then
			local events = require(root.Endpoint)
			for _, channel in channels do
				local payloadId = channel.payloadId
				local event = events[payloadId]
				assert(event ~= nil, "quick core Warp endpoint missing")
				handles[payloadId] = event
				if isServer then
					local key = event:Connect(function(player, ...) deliver(payloadId, player, ...) end)
					connections[#connections + 1] = function() event:Disconnect(key) end
				end
				if not isServer then
					senders[payloadId] = function(payload)
						event:Fire(true, args(payloadId, payload))
					end
				end
			end
		elseif libraryId == "blink" or libraryId == "blinkblox" or libraryId == "zap" or libraryId == "netray-compile" then
			local net = require(root.Library[if isServer then "Server" else "Client"])
			local names = if libraryId == "netray-compile"
				then { tiny = "Tiny", ["schema-string"] = "Strings", ["schema-signed"] = "Numbers", ["schema-vector3"] = "Vectors", state = "State", ["schema-composite"] = "Composite" }
				else { tiny = "TinyC2S", ["schema-string"] = "StringsC2S", ["schema-signed"] = "NumbersC2S", ["schema-vector3"] = "VectorsC2S", state = "StateC2S", ["schema-composite"] = "CompositeC2S" }
			for _, channel in channels do
				local payloadId = channel.payloadId
				local event = net[names[payloadId]]
				assert(event ~= nil, "quick core generated endpoint missing: " .. names[payloadId])
				handles[payloadId] = event
				if isServer then
					local callback = if libraryId == "blinkblox" then function(player, payload)
						deliverRecord(payloadId, player, blinkBloxPayload(payloadId, payload))
					end
					else function(player, ...) deliver(payloadId, player, ...) end
					local cleanup = if libraryId == "zap" then event.SetCallback(callback) else event.On(callback)
					if type(cleanup) == "function" then connections[#connections + 1] = cleanup
					elseif cleanup ~= nil and type(cleanup.Disconnect) == "function" then
						connections[#connections + 1] = function() cleanup:Disconnect() end
					end
				end
				if not isServer then
					senders[payloadId] = function(payload)
						if libraryId == "blinkblox" then event.Fire(blinkBloxValue(payloadId, payload))
						else event.Fire(args(payloadId, payload)) end
					end
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
			local started, issue = session:Start()
			assert(started, "quick core Relay client startup failed: " .. tostring(issue and issue.code))
			sessionStarted = true
		end
		for _, channel in channels do
			if handles[channel.payloadId] == nil then return false end
		end
		if rpcProbe and handles.tiny == nil then return false end
		if rpcProbe and libraryId == "blinkblox" then
			for _, name in rpcRemoteNames do
				if ReplicatedStorage:FindFirstChild(name) == nil then return false end
			end
		end
		if libraryId == "native-reliable" then
			if #root:GetChildren() ~= #channels then return false end
			for _, channel in channels do
				local remote = handles[channel.payloadId]
				if remote.Parent ~= root or remote.Name ~= channel.name then return false end
			end
		elseif libraryId == "quicknet" then
			local reliable = root.Library.QuickNetRemote
			local seen = {}
			for _, channel in channels do
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
			for _, channel in channels do
				local identifierId = packetIds[channel.key]
				if type(identifierId) ~= "number" or seen[identifierId] then return false end
				seen[identifierId] = true
			end
		end
		if isServer and libraryId == "native-reliable" and not exactRoster() then return false end
		if isServer and libraryId == "relay-reliable" and not exactRoster() then return false end
		if libraryId == "warp" then
			local library = root.Library
			local eventFolder = library.Index.Event
			local reliable = eventFolder.Reliable
			local seen = {}
			for _, channel in channels do
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
		sink, envelopes, session, definition, namespace, invoke, rpcRemoteNames, root = nil, nil, nil, nil, nil, nil, nil, nil
	end
	if not isServer then
		if rpcProbe then
			side.invoke = function(payload: any)
				assert(open and invoke ~= nil, "quick core RPC state")
				return invoke(payload)
			end
		else
			side.submit = function(payload: any, boundary: string)
				assert(open, "quick core submit state")
				local payloadId = context.activePayloadId()
				local send = senders[payloadId]
				assert(send ~= nil, "quick core category endpoint missing")
				send(payload)
				if boundary == "FlushBeforeReturn" and session ~= nil and session.flush ~= nil then session.flush() end
			end
		end
	end
	return table.freeze(side)
end

return table.freeze({
	constructServer = function(context: any): any return makeSide(context, true) end,
	constructClient = function(context: any): any return makeSide(context, false) end,
	-- The focused raw-input test feeds the exact same event spec to ServerRuntime.
	relayDefinitionSpecForTests = function(): any return relayDefinitionSpec() end,
	relayRpcDefinitionSpecForTests = relayRpcDefinitionSpec,
})
