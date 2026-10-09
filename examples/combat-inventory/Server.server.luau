--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Definition = require(ReplicatedStorage.Definition)

local serverResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 16, refillPerSecond = 8 },
		aggregate = { capacity = 128, refillPerSecond = 64 },
	},
})
local server = assert(serverResult, createError and createError.message)

-- Keep inventory in server-owned state keyed by the actual Player supplied to Inspect.
-- Update it only after the game's own grant/removal checks succeed.
local inventoryByPlayer: { [Player]: { [number]: number } } = {}

local attackConnectionResult, attackError = server.events.Attack:Connect(function(player, sequence, targetId)
	print("Attack intent", player.UserId, sequence, targetId)
	-- Relay validates and rate-limits the message; authorize the action before applying damage.
end)
local attackConnection = assert(attackConnectionResult, attackError and attackError.message)

local inspectConnectionResult, inspectError = server.requests.Inspect:Connect(function(player, itemId)
	local inventory = inventoryByPlayer[player]
	local count = if inventory then inventory[itemId] or 0 else 0
	return { owned = count > 0, count = count }
end)
local inspectConnection = assert(inspectConnectionResult, inspectError and inspectError.message)

local function _publishInventoryUpdate(player: Player, itemId: number, count: number)
	local sent, sendError = server.events.InventoryUpdate:Send(player, itemId, count)
	assert(sent, sendError and sendError.message)
end

-- Call _publishInventoryUpdate after changing the authoritative inventory.
local started, startError = server:Start()
assert(started, startError and startError.message)

script.Destroying:Connect(function()
	attackConnection:Disconnect()
	inspectConnection:Disconnect()
	server:Destroy()
end)
