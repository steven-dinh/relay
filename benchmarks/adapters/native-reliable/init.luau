--!strict

local Players = game:GetService("Players")

local CONSTRUCT_ERROR = "NATIVE_RELIABLE_E_CONSTRUCT"
local SETUP_ERROR = "NATIVE_RELIABLE_E_SETUP"
local READY_ERROR = "NATIVE_RELIABLE_E_READY"
local SUBMIT_ERROR = "NATIVE_RELIABLE_E_SUBMIT"
local BROADCAST_ERROR = "NATIVE_RELIABLE_E_BROADCAST"
local TEARDOWN_ERROR = "NATIVE_RELIABLE_E_TEARDOWN"

local function fail(code: string): never
	error(code, 0)
end

local function endpointName(payloadId: string): string
	if payloadId == "tiny" then
		return "tiny"
	elseif payloadId == "state" then
		return "state"
	end

	fail(CONSTRUCT_ERROR)
end

local function serverReceives(selection: any): boolean
	return selection.kind == "SeparateProbe" or selection.direction == "ClientToServer"
end

local function serverBroadcasts(selection: any): boolean
	return selection.kind == "SeparateProbe" or selection.direction == "ServerToClient"
end

local function clientReceives(selection: any): boolean
	return selection.kind == "SeparateProbe" or selection.direction == "ServerToClient"
end

local function clientSubmits(selection: any): boolean
	return selection.kind == "SeparateProbe" or selection.direction == "ClientToServer"
end

local function makeSide(context: any, role: "Server" | "Client"): any
	if typeof(context.resourceRoot) ~= "Instance" then
		fail(CONSTRUCT_ERROR)
	end

	local isServer = role == "Server"
	local selection = context.selection
	local payloadId: string = selection.payloadId
	local selectedName = endpointName(payloadId)
	local receives = if isServer then serverReceives(selection) else clientReceives(selection)
	local hasOperation = if isServer then serverBroadcasts(selection) else clientSubmits(selection)

	local resourceRoot: Instance? = context.resourceRoot
	local envelopes: any? = context.envelopes
	local sink: any? = context.sink
	local recipients: { Player }? = if isServer then context.recipients else nil

	local endpoint: RemoteEvent? = nil
	local createdEndpoint: RemoteEvent? = nil
	local childAddedConnection: RBXScriptConnection? = nil
	local childRemovedConnection: RBXScriptConnection? = nil
	local endpointNameConnection: RBXScriptConnection? = nil
	local receiveConnection: RBXScriptConnection? = nil
	local setupComplete = false
	local readyComplete = false
	local deliveryOpen = false
	local conflict = false
	local tearingDown = false
	local tornDown = false

	local function latchConflict()
		conflict = true
		if readyComplete then
			deliveryOpen = false
		end
	end

	local function deliverClient(...: any)
		if not deliveryOpen then
			return
		end

		local envelopeFactory = envelopes
		local deliverySink = sink
		if envelopeFactory == nil or deliverySink == nil then
			return
		end

		deliverySink(envelopeFactory.positional(...), {
			kind = "ServerToClient",
		})
	end

	local function deliverServer(player: Player, ...: any)
		if not deliveryOpen then
			return
		end

		local envelopeFactory = envelopes
		local deliverySink = sink
		if envelopeFactory == nil or deliverySink == nil then
			return
		end

		deliverySink(envelopeFactory.positional(...), {
			kind = "ClientToServer",
			sender = player,
		})
	end

	local function observeEndpointName(remote: RemoteEvent)
		local ok, connection = pcall(function()
			return remote:GetPropertyChangedSignal("Name"):Connect(function()
				if not tearingDown and remote == endpoint and remote.Name ~= selectedName then
					latchConflict()
				end
			end)
		end)
		if ok then
			endpointNameConnection = connection :: RBXScriptConnection
		else
			latchConflict()
		end
	end

	local function observeChild(child: Instance)
		if tearingDown or child.Name ~= selectedName then
			return
		end

		if endpoint ~= nil then
			if child ~= endpoint then
				latchConflict()
			end
			return
		end

		if isServer or conflict or not child:IsA("RemoteEvent") then
			latchConflict()
			return
		end

		endpoint = child
		observeEndpointName(child)
		if receives then
			local ok, connection = pcall(function()
				return child.OnClientEvent:Connect(deliverClient)
			end)
			if ok then
				receiveConnection = connection :: RBXScriptConnection
			else
				latchConflict()
			end
		end
	end

	local function observeRemoval(child: Instance)
		if not tearingDown and child == endpoint then
			latchConflict()
		end
	end

	local function setup()
		if setupComplete or tearingDown then
			fail(SETUP_ERROR)
		end

		local ok = pcall(function()
			local root = resourceRoot
			if root == nil then
				fail(SETUP_ERROR)
			end

			childAddedConnection = root.ChildAdded:Connect(observeChild)
			childRemovedConnection = root.ChildRemoved:Connect(observeRemoval)
			for _, child in root:GetChildren() do
				observeChild(child)
			end

			if isServer then
				if conflict then
					fail(SETUP_ERROR)
				end

				local remote = Instance.new("RemoteEvent")
				remote.Name = selectedName
				endpoint = remote
				createdEndpoint = remote
				if receives then
					receiveConnection = remote.OnServerEvent:Connect(deliverServer)
				end
				remote.Parent = root
				observeEndpointName(remote)
			end
		end)

		if not ok then
			fail(SETUP_ERROR)
		end
		setupComplete = true
	end

	local function exactRoster(): boolean
		local expected = recipients
		if expected == nil then
			return false
		end

		local actual = Players:GetPlayers()
		if #actual ~= #expected then
			return false
		end
		for _, actualPlayer in actual do
			local found = false
			for _, expectedPlayer in expected do
				if actualPlayer == expectedPlayer then
					found = true
					break
				end
			end
			if not found then
				return false
			end
		end
		return true
	end

	local function ready(): boolean
		if not setupComplete or tearingDown or conflict then
			fail(READY_ERROR)
		end

		local root = resourceRoot
		local remote = endpoint
		if root == nil then
			fail(READY_ERROR)
		elseif remote == nil then
			return false
		elseif remote.Parent ~= root or remote.Name ~= selectedName then
			latchConflict()
			fail(READY_ERROR)
		elseif receives and receiveConnection == nil then
			latchConflict()
			fail(READY_ERROR)
		elseif isServer and hasOperation and not exactRoster() then
			latchConflict()
			fail(READY_ERROR)
		end

		if not readyComplete then
			readyComplete = true
			deliveryOpen = true
		end
		return deliveryOpen
	end

	local function operationEndpoint(code: string): RemoteEvent
		local remote = endpoint
		if not deliveryOpen or remote == nil then
			fail(code)
		end
		return remote
	end

	local function teardown()
		if tornDown then
			return
		end

		deliveryOpen = false
		tearingDown = true
		local failed = false

		local function disconnect(connection: RBXScriptConnection?)
			if connection ~= nil and not pcall(function()
				connection:Disconnect()
			end) then
				failed = true
			end
		end

		disconnect(receiveConnection)
		disconnect(childAddedConnection)
		disconnect(childRemovedConnection)
		disconnect(endpointNameConnection)
		receiveConnection = nil
		childAddedConnection = nil
		childRemovedConnection = nil
		endpointNameConnection = nil

		local ownedEndpoint = createdEndpoint
		if isServer and ownedEndpoint ~= nil and not pcall(function()
			ownedEndpoint:Destroy()
		end) then
			failed = true
		end

		endpoint = nil
		createdEndpoint = nil
		resourceRoot = nil
		envelopes = nil
		sink = nil
		recipients = nil
		tornDown = true

		if failed then
			fail(TEARDOWN_ERROR)
		end
	end

	local side: any = {
		setup = setup,
		ready = ready,
		teardown = teardown,
	}

	if hasOperation then
		if isServer then
			side.broadcast = function(payload: any, _boundary: any)
				local remote = operationEndpoint(BROADCAST_ERROR)

				if payloadId == "tiny" then
					remote:FireAllClients(payload.sequence, payload.enabled)
				else
					remote:FireAllClients(
						payload.sequence,
						payload.entityId,
						payload.position,
						payload.yaw,
						payload.health
					)
				end
			end
		else
			side.submit = function(payload: any, _boundary: any)
				local remote = operationEndpoint(SUBMIT_ERROR)
				if payloadId == "tiny" then
					remote:FireServer(payload.sequence, payload.enabled)
				else
					remote:FireServer(
						payload.sequence,
						payload.entityId,
						payload.position,
						payload.yaw,
						payload.health
					)
				end
			end
		end
	end

	table.freeze(side)
	return side
end

local factory = {
	constructServer = function(context: any): any
		return makeSide(context, "Server")
	end,
	constructClient = function(context: any): any
		return makeSide(context, "Client")
	end,
}

table.freeze(factory)
return factory
