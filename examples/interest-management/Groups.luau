--!strict

local MAX_GROUPS = 16
local MAX_MEMBERS = 64
local MAX_NAME_BYTES = 64

export type GroupManager = {
	Set: (self: GroupManager, name: string, audience: { Player }) -> (boolean, string?),
	Members: (self: GroupManager, name: string) -> ({ Player }?, string?),
	Delete: (self: GroupManager, name: string) -> (boolean, string?),
	Destroy: (self: GroupManager) -> (),
}

local function validName(name: string): boolean
	return type(name) == "string" and #name > 0 and #name <= MAX_NAME_BYTES
end

local function new(players: Players): GroupManager
	local groups: { [string]: { Player } } = {}
	local groupCount = 0
	local destroyed = false
	local removingConnection: RBXScriptConnection?
	local manager: GroupManager

	local function removePlayer(leaving: Player)
		if destroyed then return end
		for name, members in groups do
			local remaining: { Player } = {}
			for _, member in members do
				if member ~= leaving then table.insert(remaining, member) end
			end
			groups[name] = remaining
		end
	end

	manager = {
		Set = function(_: GroupManager, name: string, audience: { Player }): (boolean, string?)
			if destroyed then return false, "Destroyed" end
			if not validName(name) then return false, "InvalidGroup" end

			local previous = groups[name]
			if previous == nil and groupCount >= MAX_GROUPS then
				return false, "GroupLimit"
			end
			if type(audience) ~= "table" or getmetatable(audience) ~= nil then
				return false, "InvalidAudience"
			end

			local rawEntries: { [number]: unknown } = {}
			local entryCount = 0
			local maximumIndex = 0
			for key, value in next, audience do
				entryCount += 1
				if entryCount > MAX_MEMBERS then return false, "InvalidAudience" end
				if type(key) ~= "number" or key < 1 or key > MAX_MEMBERS or key % 1 ~= 0 then
					return false, "InvalidAudience"
				end
				rawEntries[key] = value
				maximumIndex = math.max(maximumIndex, key)
			end
			if entryCount ~= maximumIndex then return false, "InvalidAudience" end

			local currentPlayers: { [Player]: boolean } = {}
			for _, current in players:GetPlayers() do currentPlayers[current] = true end
			local entries: { Player } = {}
			local seenPlayers: { [Player]: boolean } = {}
			for index = 1, maximumIndex do
				local value = rawEntries[index]
				if typeof(value) ~= "Instance" or not value:IsA("Player") then
					return false, "InvalidAudience"
				end

				local member = value :: Player
				if member.Parent ~= players or currentPlayers[member] ~= true then
					return false, "NotCurrentPlayer"
				end
				if not seenPlayers[member] then
					seenPlayers[member] = true
					table.insert(entries, member)
				end
			end

			if previous == nil then groupCount += 1 end
			groups[name] = entries
			return true, nil
		end,
		Members = function(_: GroupManager, name: string): ({ Player }?, string?)
			if destroyed then return nil, "Destroyed" end
			if not validName(name) then return nil, "InvalidGroup" end
			local members = groups[name]
			if members == nil then return nil, "MissingGroup" end

			local currentPlayers: { [Player]: boolean } = {}
			for _, current in players:GetPlayers() do currentPlayers[current] = true end
			local snapshot: { Player } = {}
			for _, member in members do
				if member.Parent == players and currentPlayers[member] == true then
					table.insert(snapshot, member)
				end
			end
			return snapshot, nil
		end,
		Delete = function(_: GroupManager, name: string): (boolean, string?)
			if destroyed then return false, "Destroyed" end
			if not validName(name) then return false, "InvalidGroup" end
			if groups[name] == nil then return true, nil end
			groups[name] = nil
			groupCount -= 1
			return true, nil
		end,
		Destroy = function(_: GroupManager)
			if destroyed then return end
			destroyed = true
			if removingConnection ~= nil then
				removingConnection:Disconnect()
				removingConnection = nil
			end
			table.clear(groups)
			groupCount = 0
		end,
	}

	removingConnection = players.PlayerRemoving:Connect(removePlayer)
	return manager
end

return { new = new }
