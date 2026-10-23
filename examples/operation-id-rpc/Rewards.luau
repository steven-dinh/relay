--!strict

local MAX_ACCOUNTS = 64
local MAX_RECEIPTS = 8
local RECEIPT_SECONDS = 30
local POTION_PRICE = 2
local MAX_POTIONS = 5

export type Status = "Applied" | "Denied" | "Pending" | "Conflict" | "Capacity" | "Unknown"
export type Receipt = { status: Status, coins: number, potions: number }

type PendingRow = { state: "Pending", rewardId: number }
type CompletedRow = {
	state: "Completed",
	rewardId: number,
	completedAt: number,
	receipt: Receipt,
}
type Row = PendingRow | CompletedRow
type Account = {
	coins: number,
	potions: number,
	allowed: boolean,
	rows: { [number]: Row },
	rowCount: number,
}

export type Rewards = {
	AddPlayer: (self: Rewards, player: Player) -> boolean,
	RemovePlayer: (self: Rewards, player: Player) -> (),
	SetPermission: (self: Rewards, player: Player, allowed: boolean) -> boolean,
	Claim: (self: Rewards, player: Player, operationId: number, rewardId: number) -> Receipt,
	Lookup: (self: Rewards, player: Player, operationId: number, rewardId: number) -> Receipt,
	Destroy: (self: Rewards) -> (),
}

local function new(now: () -> number, prepare: () -> ()): Rewards
	local accounts: { [Player]: Account } = {}
	local accountCount = 0
	local destroyed = false
	local rewards: Rewards

	local function makeReceipt(status: Status, account: Account?): Receipt
		local receipt: Receipt = {
			status = status,
			coins = if account == nil then 0 else account.coins,
			potions = if account == nil then 0 else account.potions,
		}
		return table.freeze(receipt) :: Receipt
	end

	local function isCurrent(player: Player, account: Account): boolean
		return not destroyed and accounts[player] == account
	end

	local function prune(account: Account)
		local time = now()
		for operationId, row in account.rows do
			if row.state == "Completed" and time >= row.completedAt + RECEIPT_SECONDS then
				account.rows[operationId] = nil
				account.rowCount -= 1
			end
		end
	end

	local function complete(account: Account, operationId: number, rewardId: number, status: Status): Receipt
		local result = makeReceipt(status, account)
		account.rows[operationId] = {
			state = "Completed",
			rewardId = rewardId,
			completedAt = now(),
			receipt = result,
		}
		return result
	end

	local function allowedToBuy(account: Account, rewardId: number): boolean
		return rewardId == 1 and account.allowed and account.coins >= POTION_PRICE and account.potions < MAX_POTIONS
	end

	rewards = {
		AddPlayer = function(_: Rewards, player: Player): boolean
			if destroyed then return false end
			if accounts[player] ~= nil then return true end
			if accountCount >= MAX_ACCOUNTS then return false end
			accounts[player] = { coins = 10, potions = 0, allowed = true, rows = {}, rowCount = 0 }
			accountCount += 1
			return true
		end,
		RemovePlayer = function(_: Rewards, player: Player)
			local account = accounts[player]
			if account == nil then return end
			accounts[player] = nil
			accountCount -= 1
			table.clear(account.rows)
			account.rowCount = 0
		end,
		SetPermission = function(_: Rewards, player: Player, allowed: boolean): boolean
			local account = accounts[player]
			if destroyed or account == nil then return false end
			account.allowed = allowed
			return true
		end,
		Claim = function(_: Rewards, player: Player, operationId: number, rewardId: number): Receipt
			local account = accounts[player]
			if destroyed or account == nil then return makeReceipt("Unknown", nil) end

			prune(account)
			local row = account.rows[operationId]
			if row ~= nil then
				if row.rewardId ~= rewardId then return makeReceipt("Conflict", account) end
				if row.state == "Pending" then return makeReceipt("Pending", account) end
				return row.receipt
			end
			if account.rowCount >= MAX_RECEIPTS then return makeReceipt("Capacity", account) end

			-- shortcut: stuck preparation retains a slot until player cleanup; use an application deadline for production work.
			account.rows[operationId] = { state = "Pending", rewardId = rewardId }
			account.rowCount += 1
			if not allowedToBuy(account, rewardId) then
				return complete(account, operationId, rewardId, "Denied")
			end

			local prepared = pcall(prepare)
			if not isCurrent(player, account) then return makeReceipt("Unknown", nil) end
			if not prepared or not allowedToBuy(account, rewardId) then
				return complete(account, operationId, rewardId, "Denied")
			end

			account.coins -= POTION_PRICE
			account.potions += 1
			return complete(account, operationId, rewardId, "Applied")
		end,
		Lookup = function(_: Rewards, player: Player, operationId: number, rewardId: number): Receipt
			local account = accounts[player]
			if destroyed or account == nil then return makeReceipt("Unknown", nil) end

			prune(account)
			local row = account.rows[operationId]
			if row == nil then return makeReceipt("Unknown", account) end
			if row.rewardId ~= rewardId then return makeReceipt("Conflict", account) end
			if row.state == "Pending" then return makeReceipt("Pending", account) end
			return row.receipt
		end,
		Destroy = function(_: Rewards)
			if destroyed then return end
			destroyed = true
			for _, account in accounts do
				table.clear(account.rows)
				account.rowCount = 0
			end
			table.clear(accounts)
			accountCount = 0
		end,
	}
	return rewards
end

return { new = new }
