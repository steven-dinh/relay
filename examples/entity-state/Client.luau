--!strict

local Types = require(script.Parent.Types)

type Snapshot = Types.Snapshot
type Update = Types.Update

export type ClientManager = {
	CanBegin: (self: ClientManager, now: number) -> boolean,
	Begin: (self: ClientManager, now: number, cancelPending: () -> ()) -> number?,
	Complete: (self: ClientManager, token: number, response: Snapshot, now: number) -> boolean,
	Fail: (self: ClientManager, token: number) -> (),
	Receive: (self: ClientManager, update: Update, now: number) -> boolean,
	Tick: (self: ClientManager, now: number) -> (),
	NeedsSnapshot: (self: ClientManager) -> boolean,
	GetSnapshot: (self: ClientManager) -> Types.ClientSnapshot,
	Destroy: (self: ClientManager) -> (),
}

type Phase = "Waiting" | "Recovering" | "Ready" | "Closed"
type Pending = { token: number, startedAt: number, epoch: number, cancel: () -> () }
type ParsedSnapshot = { status: Types.SnapshotStatus, epoch: number, revision: number, entities: { [number]: number } }

local MAX_ENTITIES = 32
local MAX_ID = 65_535
local MAX_HEALTH = 1_000
local MAX_U32 = 4_294_967_295
local MAX_BUFFERED_UPDATES = 64
local REQUEST_INTERVAL = 2
local SNAPSHOT_DEADLINE = 5
local FRESHNESS_SECONDS = 5

local function integerBetween(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
		and value % 1 == 0 and value >= minimum and value <= maximum
end

local function finiteNonnegative(value: number): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value >= 0
end

local function parseSnapshot(value: unknown): ParsedSnapshot?
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local raw = value :: { [string]: unknown }
	local status = raw.status
	local epoch = raw.epoch
	local revision = raw.revision
	local rawEntities = raw.entities
	if status ~= "Ready" and status ~= "Denied" and status ~= "Busy" then return nil end
	if not integerBetween(epoch, 0, MAX_U32) or not integerBetween(revision, 0, MAX_U32) then return nil end
	if type(rawEntities) ~= "table" or getmetatable(rawEntities) ~= nil then return nil end

	local rows: { [number]: unknown } = {}
	local count = 0
	local maximumIndex = 0
	for key, row in next, rawEntities do
		count += 1
		if count > MAX_ENTITIES or not integerBetween(key, 1, MAX_ENTITIES) then return nil end
		local index = key :: number
		rows[index] = row
		maximumIndex = math.max(maximumIndex, index)
	end
	if count ~= maximumIndex then return nil end
	local parsedEpoch = epoch :: number
	local parsedRevision = revision :: number

	local entities: { [number]: number } = {}
	if status ~= "Ready" then
		if epoch ~= 0 or revision ~= 0 or count ~= 0 then return nil end
		return { status = status, epoch = 0, revision = 0, entities = entities }
	end
	if epoch == 0 then return nil end

	for index = 1, count do
		local row = rows[index]
		if type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
		local rawRow = row :: { [string]: unknown }
		local id = rawRow.id
		local health = rawRow.health
		if not integerBetween(id, 1, MAX_ID) or not integerBetween(health, 0, MAX_HEALTH) then return nil end
		local entityId = id :: number
		if entities[entityId] ~= nil then return nil end
		entities[entityId] = health :: number
	end
	return { status = "Ready", epoch = parsedEpoch, revision = parsedRevision, entities = entities }
end

local function parseUpdate(value: unknown): Update?
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local raw = value :: { [string]: unknown }
	local epoch = raw.epoch
	local revision = raw.revision
	local kind = raw.kind
	local id = raw.id
	local health = raw.health
	if not integerBetween(epoch, 1, MAX_U32) or not integerBetween(revision, 0, MAX_U32) then return nil end
	if not integerBetween(id, 0, MAX_ID) or not integerBetween(health, 0, MAX_HEALTH) then return nil end
	if kind ~= "Put" and kind ~= "Delete" and kind ~= "Reset" and kind ~= "Closed" then return nil end
	if kind == "Put" and (id == 0 or revision == 0) then return nil end
	if kind == "Delete" and (id == 0 or health ~= 0 or revision == 0) then return nil end
	if (kind == "Reset" or kind == "Closed") and (id ~= 0 or health ~= 0) then return nil end
	return {
		epoch = epoch :: number,
		revision = revision :: number,
		kind = kind :: Types.UpdateKind,
		id = id :: number,
		health = health :: number,
	}
end

local function sameUpdate(left: Update, right: Update): boolean
	return left.epoch == right.epoch and left.revision == right.revision and left.kind == right.kind
		and left.id == right.id and left.health == right.health
end

local function applyUpdate(entities: { [number]: number }, update: Update): boolean
	if update.kind == "Put" then
		if entities[update.id] == nil then
			local count = 0
			for _ in entities do count += 1 end
			if count >= MAX_ENTITIES then return false end
		end
		entities[update.id] = update.health
	elseif update.kind == "Delete" then
		entities[update.id] = nil
	end
	return true
end

local function new(): ClientManager
	local entities: { [number]: number } = {}
	local buffered: { [number]: Update } = {}
	local bufferedCount = 0
	local pending: Pending? = nil
	local phase: Phase = "Waiting"
	local epoch = 0
	local revision = 0
	local revisionFloor = 0
	local lastRequestAt: number? = nil
	local baselineAt: number? = nil
	local nextToken = 0
	local destroyed = false
	local manager: ClientManager

	local function clearBuffer()
		table.clear(buffered)
		bufferedCount = 0
	end

	local function clearEntities()
		table.clear(entities)
		revision = 0
		baselineAt = nil
	end

	local function cancelCurrent()
		local active = pending
		pending = nil
		if active ~= nil then pcall(active.cancel) end
	end

	local function invalidate()
		cancelCurrent()
		revisionFloor = math.max(revisionFloor, revision)
		clearEntities()
		clearBuffer()
		phase = "Recovering"
	end

	local function storeBuffered(update: Update)
		if update.revision <= revisionFloor then return end
		local previous = buffered[update.revision]
		if previous ~= nil then
			if not sameUpdate(previous, update) then
				clearBuffer()
				cancelCurrent()
			end
			return
		end
		if bufferedCount >= MAX_BUFFERED_UPDATES then
			clearBuffer()
			cancelCurrent()
			return
		end
		buffered[update.revision] = update
		bufferedCount += 1
	end

	manager = {
		CanBegin = function(_: ClientManager, now: number): boolean
			if destroyed or pending ~= nil or not finiteNonnegative(now) then return false end
			local previous = lastRequestAt
			return previous == nil or (now >= previous and now - previous >= REQUEST_INTERVAL)
		end,
		Begin = function(_: ClientManager, now: number, cancelPending: () -> ()): number?
			if type(cancelPending) ~= "function" or not manager:CanBegin(now) then return nil end
			nextToken += 1
			lastRequestAt = now
			pending = { token = nextToken, startedAt = now, epoch = epoch, cancel = cancelPending }
			return nextToken
		end,
		Complete = function(_: ClientManager, token: number, response: Snapshot, now: number): boolean
			local active = pending
			if destroyed or active == nil or active.token ~= token then return false end
			if not finiteNonnegative(now) or now < active.startedAt or now - active.startedAt >= SNAPSHOT_DEADLINE then
				cancelCurrent()
				return false
			end
			pending = nil
			if epoch ~= active.epoch then return false end

			local parsed = parseSnapshot(response)
			if parsed == nil then
				invalidate()
				return false
			end
			if parsed.status == "Busy" then return true end
			if parsed.status == "Denied" then
				revisionFloor = math.max(revisionFloor, revision)
				clearEntities()
				clearBuffer()
				phase = "Closed"
				return true
			end
			if parsed.epoch < epoch or (phase == "Closed" and parsed.epoch <= epoch) then return false end
			if parsed.epoch == epoch and parsed.revision < revisionFloor then return false end

			local needsReplacement = parsed.epoch > epoch or phase ~= "Ready"
			if not needsReplacement and parsed.revision < revision then
				baselineAt = now
				return true
			end

			local candidate = parsed.entities
			local candidateRevision = parsed.revision
			if parsed.epoch == epoch and phase == "Recovering" and bufferedCount > 0 then
				local revisions: { number } = {}
				for updateRevision in buffered do table.insert(revisions, updateRevision) end
				table.sort(revisions)
				for _, updateRevision in revisions do
					if updateRevision > parsed.revision then
						if updateRevision ~= candidateRevision + 1 then
							invalidate()
							return false
						end
						local update = buffered[updateRevision]
						if update == nil or not applyUpdate(candidate, update) then
							invalidate()
							return false
						end
						candidateRevision = updateRevision
					end
				end
			end

			if parsed.epoch > epoch then
				epoch = parsed.epoch
				revisionFloor = 0
			end
			table.clear(entities)
			for id, health in candidate do entities[id] = health end
			revision = candidateRevision
			baselineAt = now
			clearBuffer()
			phase = "Ready"
			return true
		end,
		Fail = function(_: ClientManager, token: number)
			local active = pending
			if active ~= nil and active.token == token then pending = nil end
		end,
		Receive = function(_: ClientManager, rawUpdate: Update, now: number): boolean
			if destroyed or not finiteNonnegative(now) then return false end
			local update = parseUpdate(rawUpdate)
			if update == nil then
				invalidate()
				return true
			end
			if update.epoch < epoch then return false end

			if update.epoch > epoch then
				cancelCurrent()
				clearEntities()
				clearBuffer()
				epoch = update.epoch
				revisionFloor = 0
				if update.kind == "Closed" then
					phase = "Closed"
					return false
				end
				phase = "Recovering"
				if update.kind == "Reset" then
					revisionFloor = update.revision
				else
					storeBuffered(update)
				end
				return true
			end

			if phase == "Closed" then return false end
			if update.kind == "Reset" then return false end
			if update.kind == "Closed" then
				cancelCurrent()
				clearEntities()
				clearBuffer()
				phase = "Closed"
				return false
			end

			if phase == "Ready" then
				if update.revision <= revision then return false end
				if update.revision == revision + 1 then
					if not applyUpdate(entities, update) then
						invalidate()
						storeBuffered(update)
						return true
					end
					revision = update.revision
					return false
				end
				invalidate()
			end
			if phase == "Waiting" then phase = "Recovering" end
			storeBuffered(update)
			return true
		end,
		Tick = function(_: ClientManager, now: number)
			if destroyed or not finiteNonnegative(now) then return end
			local active = pending
			if active ~= nil and (now < active.startedAt or now - active.startedAt >= SNAPSHOT_DEADLINE) then
				cancelCurrent()
			end
			if phase == "Ready" and baselineAt ~= nil and now >= baselineAt
				and now - baselineAt >= FRESHNESS_SECONDS then
				invalidate()
			end
		end,
		NeedsSnapshot = function(_: ClientManager): boolean
			return not destroyed and (phase == "Waiting" or phase == "Recovering")
		end,
		GetSnapshot = function(_: ClientManager): Types.ClientSnapshot
			local copy: { [number]: number } = {}
			for id, health in entities do copy[id] = health end
			return { epoch = epoch, revision = revision, entities = copy, ready = phase == "Ready" }
		end,
		Destroy = function(_: ClientManager)
			if destroyed then return end
			destroyed = true
			cancelCurrent()
			clearEntities()
			clearBuffer()
			phase = "Closed"
		end,
	}

	return manager
end

return { new = new }
