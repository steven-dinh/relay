--!strict

local Types = require(script.Parent.Types)

type Snapshot = Types.Snapshot
type Update = Types.Update

type Viewer = { epoch: number, lastSnapshot: number?, snapshotPending: boolean }

export type ServerManager = {
	CreateEntity: (self: ServerManager, health: number) -> (number?, string?),
	SetHealth: (self: ServerManager, id: number, health: number) -> (boolean, string?),
	DeleteEntity: (self: ServerManager, id: number) -> (boolean, string?),
	SetViewer: (self: ServerManager, player: Player, allowed: boolean) -> (boolean, string?),
	RemovePlayer: (self: ServerManager, player: Player) -> (),
	Snapshot: (self: ServerManager, player: Player, now: number) -> Snapshot,
	Destroy: (self: ServerManager) -> (),
}

local MAX_ENTITIES = 32
local MAX_VIEWERS = 64
local MAX_ID = 65_535
local MAX_HEALTH = 1_000
local MAX_U32 = 4_294_967_295
local RESYNC_INTERVAL = 2

local EMPTY_ENTITIES: { Types.Entity } = {}
table.freeze(EMPTY_ENTITIES)
local DENIED: Snapshot = { status = "Denied", epoch = 0, revision = 0, entities = EMPTY_ENTITIES }
local BUSY: Snapshot = { status = "Busy", epoch = 0, revision = 0, entities = EMPTY_ENTITIES }
table.freeze(DENIED)
table.freeze(BUSY)

local function integerBetween(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
		and value % 1 == 0 and value >= minimum and value <= maximum
end

local function finiteNonnegative(value: unknown): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value >= 0
end

local function new(isCurrentPlayer: (Player) -> boolean, sendUpdate: (Player, Update) -> ()): ServerManager
	assert(type(isCurrentPlayer) == "function" and type(sendUpdate) == "function", "callbacks are required")

	local entities: { [number]: number } = {}
	local viewers: { [Player]: Viewer } = {}
	local entityCount = 0
	local viewerCount = 0
	local nextId = 1
	local epoch = 0
	local revision = 0
	local disabled = false
	local destroyed = false
	local manager: ServerManager

	local function current(player: Player): boolean
		local ok, result = pcall(isCurrentPlayer, player)
		return ok and result == true
	end

	local function emit(player: Player, update: Update)
		if current(player) then pcall(sendUpdate, player, update) end
	end

	local function closeAll()
		if disabled then return end
		disabled = true
		for player, viewer in viewers do
			emit(player, { epoch = viewer.epoch, revision = revision, kind = "Closed", id = 0, health = 0 })
		end
		table.clear(viewers)
		table.clear(entities)
		viewerCount = 0
		entityCount = 0
	end

	local function bumpRevision(): boolean
		if revision >= MAX_U32 then
			closeAll()
			return false
		end
		revision += 1
		return true
	end

	local function bumpEpoch(): boolean
		if epoch >= MAX_U32 then
			closeAll()
			return false
		end
		epoch += 1
		return true
	end

	local function publish(kind: Types.UpdateKind, id: number, health: number)
		for player, viewer in viewers do
			emit(player, { epoch = viewer.epoch, revision = revision, kind = kind, id = id, health = health })
		end
	end

	manager = {
		CreateEntity = function(_: ServerManager, health: number): (number?, string?)
			if destroyed then return nil, "Destroyed" end
			if disabled then return nil, "Closed" end
			if not integerBetween(health, 0, MAX_HEALTH) then return nil, "InvalidHealth" end
			if entityCount >= MAX_ENTITIES then return nil, "EntityLimit" end
			if nextId > MAX_ID then return nil, "IdExhausted" end
			if not bumpRevision() then return nil, "RevisionExhausted" end

			local id = nextId
			nextId += 1
			entities[id] = health
			entityCount += 1
			publish("Put", id, health)
			return id, nil
		end,
		SetHealth = function(_: ServerManager, id: number, health: number): (boolean, string?)
			if destroyed then return false, "Destroyed" end
			if disabled then return false, "Closed" end
			if not integerBetween(id, 1, MAX_ID) or not integerBetween(health, 0, MAX_HEALTH) then
				return false, "InvalidEntity"
			end
			if entities[id] == nil then return false, "MissingEntity" end
			if entities[id] == health then return true, nil end
			if not bumpRevision() then return false, "RevisionExhausted" end

			entities[id] = health
			publish("Put", id, health)
			return true, nil
		end,
		DeleteEntity = function(_: ServerManager, id: number): (boolean, string?)
			if destroyed then return false, "Destroyed" end
			if disabled then return false, "Closed" end
			if not integerBetween(id, 1, MAX_ID) then return false, "InvalidId" end
			if entities[id] == nil then return false, "MissingEntity" end
			if not bumpRevision() then return false, "RevisionExhausted" end

			entities[id] = nil
			entityCount -= 1
			publish("Delete", id, 0)
			return true, nil
		end,
		SetViewer = function(_: ServerManager, player: Player, allowed: boolean): (boolean, string?)
			if destroyed then return false, "Destroyed" end
			if disabled then return false, "Closed" end
			if type(allowed) ~= "boolean" then return false, "InvalidMembership" end
			if not current(player) then return false, "NotCurrentPlayer" end

			local previous = viewers[player]
			if allowed then
				if previous ~= nil then return true, nil end
				if viewerCount >= MAX_VIEWERS then return false, "ViewerLimit" end
				if not bumpEpoch() then return false, "EpochExhausted" end

				local viewer: Viewer = { epoch = epoch, lastSnapshot = nil, snapshotPending = false }
				viewers[player] = viewer
				viewerCount += 1
				emit(player, { epoch = viewer.epoch, revision = revision, kind = "Reset", id = 0, health = 0 })
				return true, nil
			end

			if previous == nil then return true, nil end
			if not bumpEpoch() then return false, "EpochExhausted" end
			viewers[player] = nil
			viewerCount -= 1
			emit(player, { epoch = epoch, revision = revision, kind = "Closed", id = 0, health = 0 })
			return true, nil
		end,
		RemovePlayer = function(_: ServerManager, player: Player)
			if destroyed or disabled or viewers[player] == nil then return end
			if not bumpEpoch() then return end
			viewers[player] = nil
			viewerCount -= 1
		end,
		Snapshot = function(_: ServerManager, player: Player, now: number): Snapshot
			if destroyed or disabled then return BUSY end
			local viewer = viewers[player]
			if viewer == nil or not current(player) then return DENIED end
			if not finiteNonnegative(now) or viewer.snapshotPending then return BUSY end
			local lastSnapshot = viewer.lastSnapshot
			if lastSnapshot ~= nil and (now < lastSnapshot or now - lastSnapshot < RESYNC_INTERVAL) then
				return BUSY
			end

			viewer.snapshotPending = true
			viewer.lastSnapshot = now
			local rows: { Types.Entity } = {}
			for id, health in entities do table.insert(rows, { id = id, health = health }) end
			table.sort(rows, function(left: Types.Entity, right: Types.Entity) return left.id < right.id end)
			viewer.snapshotPending = false
			return { status = "Ready", epoch = viewer.epoch, revision = revision, entities = rows }
		end,
		Destroy = function(_: ServerManager)
			if destroyed then return end
			destroyed = true
			table.clear(viewers)
			table.clear(entities)
			viewerCount = 0
			entityCount = 0
		end,
	}

	return manager
end

return { new = new }
