--!strict

local Relay = require(game:GetService("ReplicatedStorage").Relay)
local s = Relay.schema
local receipt = s.struct(
	{ status = s.enum({ Applied = 1, Denied = 2, Pending = 3, Conflict = 4, Capacity = 5, Unknown = 6 }) },
	{ coins = s.u8(0, 10) },
	{ potions = s.u8(0, 5) }
)
local input = s.fields({ operationId = s.u32(1, 4_294_967_295) }, { rewardId = s.u8(1, 2) })
local definition, problem = Relay.define({
	name = "OperationIdRewardShop", version = 1,
	events = {
		Ready = s.clientToServer(3, s.fields()),
		Welcome = s.serverToClient(4, s.fields()),
	},
	requests = {
		Claim = s.request(1, input, receipt, { concurrency = 2, refusals = true }),
		Lookup = s.request(2, input, receipt, { refusals = true }),
	},
})

return assert(definition, problem and problem.message)
