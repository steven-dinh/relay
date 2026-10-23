--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage.EntityState.Definition)
local EntityStateClient = require(ReplicatedStorage.EntityState.Client)
local Types = require(ReplicatedStorage.EntityState.Types)
local controls = ReplicatedStorage:WaitForChild("EntityStateFixture")

type Update = Types.Update
type Snapshot = Types.Snapshot

local created, createError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local session = assert(created, createError and createError.message)
local state = EntityStateClient.new()
local command = controls:WaitForChild("Command") :: RemoteEvent
local report = controls:WaitForChild("Report") :: RemoteEvent

local stopped = false
local allowResync = false
local resetReported = false
local initialResponse: Snapshot? = nil
local initialHandled = false
local initialFailure: string? = nil
local sawRaceUpdate = false
local sawDelete = false
local deletedUpdateId: number? = nil
local sawClosed = false
local sawReentryReset = false
local authorized = false
local deletedEntityId: number? = nil
local initialEpoch = 0
local pendingCancellations = 0
local commandConnection: RBXScriptConnection? = nil
local cleaned = false

local function countEntities(entities: { [number]: number }): number
	local count = 0
	for _ in entities do count += 1 end
	return count
end

local function waitFor(predicate: () -> boolean, seconds: number): boolean
	local untilTime = os.clock() + seconds
	while not stopped and os.clock() < untilTime do
		if predicate() then return true end
		task.wait(0.05)
	end
	return predicate()
end

local requestSnapshot: () -> ()
requestSnapshot = function()
	local now = os.clock()
	if stopped or not state:CanBegin(now) then return end

	local cancelPending: (() -> ())? = nil
	local token = state:Begin(now, function()
		local cancel = cancelPending
		cancelPending = nil
		if cancel ~= nil then
			pendingCancellations += 1
			cancel()
		end
	end)
	if token == nil then return end

	local createdRequest, requestError = session.requests.Snapshot:Request(5)
	if createdRequest == nil then
		initialFailure = requestError and requestError.message or "Snapshot request failed"
		state:Fail(token)
		initialHandled = initialResponse == nil
		return
	end
	local pending = createdRequest
	cancelPending = function() pending:Cancel() end

	task.spawn(function()
		local result = pending:Await()
		cancelPending = nil
		if stopped then return end
		if not result.ok then
			initialFailure = result.error.code
			state:Fail(token)
			if initialResponse == nil then initialHandled = true end
			return
		end

		local response = result.value
		local firstResponse = initialResponse == nil
		if firstResponse then initialResponse = response end
		if firstResponse and response.status == "Ready" then
			waitFor(function() return sawRaceUpdate end, 5)
		end
		if stopped then return end
		state:Complete(token, response, os.clock())
		if firstResponse then initialHandled = true end
	end)
end

local function onUpdate(update: Update)
	local reportReset = update.kind == "Reset" and not resetReported
	if reportReset then
		resetReported = true
	elseif update.kind == "Reset" and initialEpoch > 0 and update.epoch > initialEpoch then
		sawReentryReset = true
	elseif update.kind == "Put" and update.health == 777 then
		sawRaceUpdate = true
	elseif update.kind == "Delete" then
		sawDelete = true
		deletedUpdateId = update.id
	elseif update.kind == "Closed" then
		sawClosed = true
	end

	local needsSnapshot = state:Receive(update, os.clock())
	if reportReset then report:FireServer("reset") end
	if allowResync and (needsSnapshot or state:CanBegin(os.clock())) then requestSnapshot() end
end

local listener, listenerError = session.events.Update:Connect(onUpdate)
assert(listener, listenerError and listenerError.message)

local function destroyClient()
	if cleaned then return end
	cleaned = true
	stopped = true
	state:Destroy()
	listener:Disconnect()
	if commandConnection ~= nil then commandConnection:Disconnect() end
	session:Destroy()
end
script.Destroying:Connect(destroyClient)

local function initialCheck()
	allowResync = true
	requestSnapshot()
	local completed = waitFor(function()
		if not initialHandled then return false end
		local response = initialResponse
		if response == nil then return true end
		if response.status == "Ready" then
			local view = state:GetSnapshot()
			return sawRaceUpdate and view.ready and view.revision == response.revision + 1
		end
		return response.status == "Denied"
	end, 10)
	assert(completed, initialFailure or "initial Snapshot did not settle")
	assert(initialFailure == nil, initialFailure)
	local response = assert(initialResponse, "missing initial Snapshot response")
	local view = state:GetSnapshot()
	if response.status == "Ready" then
		authorized = true
		assert(response.epoch > 0 and response.revision == 8 and #response.entities == 8)
		assert(view.ready and view.epoch == response.epoch and view.revision == response.revision + 1)
		for _, entity in response.entities do
			assert(view.entities[entity.id] ~= nil)
			local currentDeletedId = deletedEntityId
			if currentDeletedId == nil or entity.id < currentDeletedId then deletedEntityId = entity.id end
		end
		assert(deletedEntityId ~= nil and view.entities[deletedEntityId] == 777)
		assert(countEntities(view.entities) == 8)
		initialEpoch = response.epoch
	else
		assert(response.status == "Denied" and response.epoch == 0 and response.revision == 0 and #response.entities == 0)
		assert(not view.ready and view.epoch == 0 and view.revision == 0 and countEntities(view.entities) == 0)
	end
end

local function deleteCheck()
	if authorized then
		assert(waitFor(function()
			local view = state:GetSnapshot()
			return sawDelete and view.ready and countEntities(view.entities) == 7
				and deletedEntityId ~= nil and view.entities[deletedEntityId] == nil
		end, 5), "delete update was not applied")
		assert(deletedUpdateId == deletedEntityId, "server deleted a different entity")
	else
		local view = state:GetSnapshot()
		assert(not view.ready and view.epoch == 0 and view.revision == 0 and countEntities(view.entities) == 0)
	end
end

local function revokeCheck()
	if authorized then
		assert(waitFor(function()
			local view = state:GetSnapshot()
			return sawClosed and not view.ready and countEntities(view.entities) == 0
		end, 5), "revoked client retained its view")
	else
		local view = state:GetSnapshot()
		assert(not view.ready and countEntities(view.entities) == 0)
	end
end

local function reentryCheck()
	if authorized then
		assert(waitFor(function()
			local view = state:GetSnapshot()
			return sawReentryReset and view.ready and view.epoch > initialEpoch and countEntities(view.entities) == 7
				and deletedEntityId ~= nil and view.entities[deletedEntityId] == nil
		end, 10), "re-entry baseline did not restore the live collection")
	else
		local view = state:GetSnapshot()
		assert(not view.ready and view.epoch == 0 and view.revision == 0 and countEntities(view.entities) == 0)
	end
end

local function cleanupCheck()
	allowResync = false
	if authorized then
		assert(waitFor(function() return state:CanBegin(os.clock()) end, 5), "pending-cancel probe was not admitted")
		local cancelPending: (() -> ())? = nil
		local token = state:Begin(os.clock(), function()
			local cancel = cancelPending
			cancelPending = nil
			pendingCancellations += 1
			if cancel ~= nil then cancel() end
		end)
		assert(token ~= nil)
		local request, requestError = session.requests.Snapshot:Request(5)
		local pending = assert(request, requestError and requestError.message)
		cancelPending = function() pending:Cancel() end
		stopped = true
		state:Destroy()
		assert(pendingCancellations == 1, "Destroy did not cancel the exact pending request")
		local result = pending:Await()
		assert(not result.ok and result.error.code == "Cancelled", "pending request survived Destroy")
	else
		stopped = true
		state:Destroy()
	end
	local view = state:GetSnapshot()
	assert(not view.ready and countEntities(view.entities) == 0, "Destroy retained a client view")
	destroyClient()
end

local runPhase: { [string]: () -> () } = {
	initial = initialCheck,
	delete = deleteCheck,
	revoke = revokeCheck,
	reentry = reentryCheck,
	cleanup = cleanupCheck,
}

commandConnection = command.OnClientEvent:Connect(function(phase)
	if type(phase) ~= "string" then return end
	local run = runPhase[phase]
	if run == nil then return end
	task.spawn(function()
		local ok, failure = pcall(run)
		if not ok then
			warn("TEST entity-state client failed", phase, failure)
			destroyClient()
			report:FireServer("failure")
			return
		end
		report:FireServer(phase)
	end)
end)

local started, startError = session:Start()
if not started then
	destroyClient()
	error(startError and startError.message or "Relay client startup failed", 0)
end
report:FireServer("ready")

task.spawn(function()
	while not stopped do
		local now = os.clock()
		state:Tick(now)
		if allowResync and state:CanBegin(now) then requestSnapshot() end
		task.wait(0.05)
	end
end)
