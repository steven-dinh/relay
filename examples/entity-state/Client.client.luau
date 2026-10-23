--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Relay = require(ReplicatedStorage:WaitForChild("Relay"))
local Definition = require(ReplicatedStorage:WaitForChild("Definition"))
local EntityClient = require(ReplicatedStorage:WaitForChild("EntityClient"))

local SNAPSHOT_TIMEOUT = 5
local clientResult, createError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
local client = assert(clientResult, createError and createError.message)
local entityState = EntityClient.new()

local screen = Instance.new("ScreenGui")
screen.Name = "EncounterHud"
screen.ResetOnSpawn = false
local label = Instance.new("TextLabel")
label.Name = "Targets"
label.AnchorPoint = Vector2.new(0, 0)
label.Position = UDim2.fromOffset(16, 16)
label.Size = UDim2.fromOffset(320, 240)
label.BackgroundTransparency = 0.2
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.TextSize = 18
label.Font = Enum.Font.Code
label.TextWrapped = true
label.Parent = screen
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local function render()
	local snapshot = entityState:GetSnapshot()
	if not snapshot.ready then
		label.Text = if entityState:NeedsSnapshot() then "Encounter targets\nLoading authorized state..."
			else "Encounter targets\nNo encounter access"
		return
	end

	local ids: { number } = {}
	for id in snapshot.entities do table.insert(ids, id) end
	table.sort(ids)
	local lines = { `Encounter targets  |  revision {snapshot.revision}` }
	if #ids == 0 then table.insert(lines, "No active targets") end
	for _, id in ids do
		table.insert(lines, `Target {id}  |  {snapshot.entities[id]} / 1000 HP`)
	end
	label.Text = table.concat(lines, "\n")
end

local function requestSnapshot(now: number)
	if not entityState:CanBegin(now) then return end
	local cancelPending: (() -> ())? = nil
	local token = entityState:Begin(now, function()
		local cancel = cancelPending
		cancelPending = nil
		if cancel ~= nil then cancel() end
	end)
	if token == nil then return end

	local pendingResult, requestError = client.requests.Snapshot:Request(SNAPSHOT_TIMEOUT)
	if pendingResult == nil then
		entityState:Fail(token)
		if requestError ~= nil and requestError.code ~= "RequestLimit" then
			warn("Encounter snapshot request failed", requestError.code)
		end
		return
	end
	local pending = pendingResult
	cancelPending = function() pending:Cancel() end
	task.spawn(function()
		local result = pending:Await()
		cancelPending = nil
		if result.ok then
			entityState:Complete(token, result.value, os.clock())
		else
			entityState:Fail(token)
		end
		render()
	end)
end

local updateResult, updateError = client.events.Update:Connect(function(update)
	local needsSnapshot = entityState:Receive(update, os.clock())
	render()
	if needsSnapshot then requestSnapshot(os.clock()) end
end)
local updateConnection = assert(updateResult, updateError and updateError.message)

local heartbeatConnection: RBXScriptConnection? = nil
local destroyingConnection: RBXScriptConnection? = nil
local stopped = false
local elapsed = 0

local function stop()
	if stopped then return end
	stopped = true
	if heartbeatConnection ~= nil then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
	if destroyingConnection ~= nil then destroyingConnection:Disconnect(); destroyingConnection = nil end
	updateConnection:Disconnect()
	entityState:Destroy()
	client:Destroy()
	screen:Destroy()
end

destroyingConnection = script.Destroying:Connect(stop)
local started, startError = client:Start()
if not started then stop(); error(startError and startError.message or "Relay client startup failed", 0) end
render()
requestSnapshot(os.clock())

heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
	if stopped then return end
	elapsed += deltaTime
	if elapsed < 0.25 then return end
	elapsed = 0
	local now = os.clock()
	entityState:Tick(now)
	if entityState:CanBegin(now) then requestSnapshot(now) end
	render()
end)
