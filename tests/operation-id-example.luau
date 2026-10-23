local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Relay = require("../src")
local Kit = require("../scripts/consumer-testing/Kit")
local Rewards = require("../examples/operation-id-rpc/Rewards")

local relayMarker = {}
local definition = luau.load(fs.readFile("examples/operation-id-rpc/Definition.luau"), {
	debugName = "OperationIdDefinition",
	injectGlobals = true,
	environment = {
		game = { GetService = function(_, name)
			assert(name == "ReplicatedStorage")
			return { Relay = relayMarker }
		end },
		require = function(module)
			assert(module == relayMarker)
			return Relay
		end,
	},
})()

local function check(receipt, status, coins, potions)
	assert(receipt.status == status, `expected {status}, got {receipt.status}`)
	if coins ~= nil then assert(receipt.coins == coins and receipt.potions == potions) end
	return receipt
end

-- A completed receipt is immutable and returned unchanged for duplicate claims.
do
	local prepareCalls = 0
	local player = {}
	local rewards = Rewards.new(function() return 0 end, function() prepareCalls += 1 end)
	assert(rewards:AddPlayer(player))
	check(rewards:Lookup(player, 1, 1), "Unknown", 10, 0)
	local first = check(rewards:Claim(player, 1, 1), "Applied", 8, 1)
	assert(table.isfrozen(first) and not pcall(function() first.coins = 0 end))
	assert(rewards:Claim(player, 1, 1) == first, "completed duplicates return their original receipt")
	check(rewards:Claim(player, 1, 2), "Conflict", 8, 1)
	check(rewards:Lookup(player, 1, 2), "Conflict", 8, 1)
	check(rewards:Lookup(player, 1, 1), "Applied", 8, 1)
	assert(prepareCalls == 1, "same ID never prepares or applies the action twice")

	local other = {}
	assert(rewards:AddPlayer(other))
	check(rewards:Claim(other, 1, 1), "Applied", 8, 1)
	assert(prepareCalls == 2, "receipt ownership is per Player")
	for operationId = 2, 5 do
		check(rewards:Claim(player, operationId, 1), "Applied", 10 - operationId * 2, operationId)
	end
	check(rewards:Claim(player, 6, 1), "Denied", 0, 5)
	assert(rewards:Claim(player, 6, 1).status == "Denied" and prepareCalls == 6,
		"the five-potion cap is enforced and its denial is cached")
	rewards:Destroy()
end

-- Reservation precedes yielding preparation; duplicates see Pending and cannot run it again.
do
	local time = 0
	local prepareCalls = 0
	local player = {}
	local rewards = Rewards.new(function() return time end, function()
		prepareCalls += 1
		coroutine.yield()
	end)
	assert(rewards:AddPlayer(player))
	local result
	local attempt = coroutine.create(function() result = rewards:Claim(player, 7, 1) end)
	local resumed = coroutine.resume(attempt)
	assert(resumed and coroutine.status(attempt) == "suspended")
	check(rewards:Claim(player, 7, 1), "Pending", 10, 0)
	check(rewards:Lookup(player, 7, 1), "Pending", 10, 0)
	check(rewards:Claim(player, 7, 2), "Conflict", 10, 0)
	for operationId = 10, 16 do check(rewards:Claim(player, operationId, 2), "Denied") end
	check(rewards:Claim(player, 17, 2), "Capacity", 10, 0)
	check(rewards:Lookup(player, 10, 2), "Denied", 10, 0)
	assert(prepareCalls == 1)

	time = 62
	check(rewards:Lookup(player, 7, 1), "Pending", 10, 0)
	check(rewards:Lookup(player, 10, 2), "Unknown", 10, 0)
	check(rewards:Claim(player, 17, 2), "Denied", 10, 0,
		"completed rows expire while the in-flight reservation remains")
	assert(coroutine.resume(attempt) and coroutine.status(attempt) == "dead")
	check(result, "Applied", 8, 1)
	assert(rewards:Claim(player, 7, 1) == result and prepareCalls == 1)
	rewards:Destroy()
end

-- Expiry is inclusive, reads do not renew it, and expired IDs may be reused.
do
	local time = 0
	local prepareCalls = 0
	local player = {}
	local rewards = Rewards.new(function() return time end, function() prepareCalls += 1 end)
	assert(rewards:AddPlayer(player))
	for operationId = 1, 8 do check(rewards:Claim(player, operationId, 2), "Denied") end
	check(rewards:Claim(player, 9, 1), "Capacity", 10, 0)
	check(rewards:Lookup(player, 1, 2), "Denied", 10, 0)
	time = 29.9
	check(rewards:Lookup(player, 1, 2), "Denied", 10, 0)
	time = 30
	check(rewards:Lookup(player, 1, 2), "Unknown", 10, 0)
	check(rewards:Claim(player, 9, 1), "Applied", 8, 1)
	check(rewards:Claim(player, 1, 1), "Applied", 6, 2)
	time = 60
	check(rewards:Claim(player, 9, 1), "Applied", 4, 3)
	assert(prepareCalls == 3, "an Applied ID may be applied again after its receipt expires")
	rewards:Destroy()
end

-- Permission is rechecked after preparation yields; preparation errors cache denial.
do
	local prepareCalls = 0
	local player = {}
	local firstPreparation = true
	local rewards = Rewards.new(function() return 0 end, function()
		prepareCalls += 1
		if firstPreparation then
			firstPreparation = false
			coroutine.yield()
		end
	end)
	assert(rewards:AddPlayer(player))
	local result
	local attempt = coroutine.create(function() result = rewards:Claim(player, 1, 1) end)
	assert(coroutine.resume(attempt) and coroutine.status(attempt) == "suspended")
	assert(rewards:SetPermission(player, false))
	assert(coroutine.resume(attempt) and coroutine.status(attempt) == "dead")
	check(result, "Denied", 10, 0)
	assert(rewards:SetPermission(player, true))
	check(rewards:Claim(player, 1, 1), "Denied", 10, 0, "revocation denial remains the receipt")
	check(rewards:Claim(player, 2, 1), "Applied", 8, 1)
	assert(prepareCalls == 2)
	rewards:Destroy()

	local failedPlayer = {}
	local failures = 0
	local failed = Rewards.new(function() return 0 end, function()
		failures += 1
		error("preparation failed")
	end)
	assert(failed:AddPlayer(failedPlayer))
	local denial = check(failed:Claim(failedPlayer, 3, 1), "Denied", 10, 0)
	assert(failed:Claim(failedPlayer, 3, 1) == denial and failures == 1,
		"preparation errors have no effect and their denial is cached")
	failed:Destroy()
end

-- Player cleanup cannot let a late continuation mutate a replacement; Destroy is terminal.
do
	local player = {}
	local rewards = Rewards.new(function() return 0 end, function() coroutine.yield() end)
	assert(rewards:AddPlayer(player))
	local result
	local attempt = coroutine.create(function() result = rewards:Claim(player, 1, 1) end)
	assert(coroutine.resume(attempt) and coroutine.status(attempt) == "suspended")
	rewards:RemovePlayer(player)
	assert(rewards:AddPlayer(player), "a departed player's account slot is released")
	assert(coroutine.resume(attempt) and coroutine.status(attempt) == "dead")
	check(result, "Unknown", 0, 0)
	check(rewards:Lookup(player, 1, 1), "Unknown", 10, 0)

	local terminalResult
	local terminalAttempt = coroutine.create(function() terminalResult = rewards:Claim(player, 2, 1) end)
	assert(coroutine.resume(terminalAttempt) and coroutine.status(terminalAttempt) == "suspended")
	rewards:Destroy(); rewards:Destroy()
	assert(not rewards:AddPlayer(player))
	check(rewards:Lookup(player, 2, 1), "Unknown", 0, 0)
	assert(coroutine.resume(terminalAttempt) and coroutine.status(terminalAttempt) == "dead")
	check(terminalResult, "Unknown", 0, 0)
end

-- The shipped schema and public Relay RPC preserve the unknown-outcome/reconciliation flow.
do
	local time = 0
	local effects = 0
	local rewards = Rewards.new(function() return time end, function() effects += 1 end)
	local welcomeCount = 0
	local claimCount = 0
	Kit.withFixture(definition, function(test)
		assert(rewards:AddPlayer(test.player))
		assert(test.server.events.Ready:Connect(function(player)
			assert(player == test.player)
			assert(test.server.events.Welcome:Send(player))
		end))
		assert(test.client.events.Welcome:Connect(function() welcomeCount += 1 end))
		assert(test.server.requests.Claim:Connect(function(player, operationId, rewardId)
			assert(player == test.player)
			claimCount += 1
			return rewards:Claim(player, operationId, rewardId)
		end))
		assert(test.server.requests.Lookup:Connect(function(player, operationId, rewardId)
			assert(player == test.player)
			return rewards:Lookup(player, operationId, rewardId)
		end))
		assert(test:Start())
		assert(test.client.events.Ready:Send() and test:Pump() > 0 and welcomeCount == 1)

		local invalid, issue = test.client.requests.Claim:Request(5, 0, 1)
		assert(invalid == nil and issue.code == "InvalidPayload", "schema rejects invalid operation IDs locally")
		local original = assert(test.client.requests.Claim:Request(0.2, 77, 1))
		assert(test:Advance(0.3))
		local timeout = original:Await()
		assert(not timeout.ok and timeout.error.code == "RequestTimeout", "timeout is an unknown outcome")
		check(rewards:Lookup(test.player, 77, 1), "Unknown", 10, 0)
		assert(test:Pump() > 0 and effects == 1 and claimCount == 1,
			"the held request may still apply after the client timed out")

		local lookup = assert(test.client.requests.Lookup:Request(5, 77, 1))
		assert(test:Pump() > 0)
		local reconciled = lookup:Await()
		assert(reconciled.ok)
		check(reconciled.value, "Applied", 8, 1)
		local duplicate = assert(test.client.requests.Claim:Request(5, 77, 1))
		assert(test:Pump() > 0)
		local repeated = duplicate:Await()
		assert(repeated.ok and repeated.value.status == "Applied" and effects == 1 and claimCount == 2,
			"completed duplicate returns the original result without applying twice")
		local conflict = assert(test.client.requests.Claim:Request(5, 77, 2))
		assert(test:Pump() > 0)
		local conflictResult = conflict:Await()
		assert(conflictResult.ok and conflictResult.value.status == "Conflict")

		assert(rewards:SetPermission(test.player, false))
		local denied = assert(test.client.requests.Claim:Request(5, 78, 1))
		assert(test:Pump() > 0)
		local denial = denied:Await()
		assert(denial.ok)
		check(denial.value, "Denied", 8, 1)
		assert(rewards:SetPermission(test.player, true))
		local sameDenial = assert(test.client.requests.Claim:Request(5, 78, 1))
		assert(test:Pump() > 0)
		local cachedDenial = sameDenial:Await()
		assert(cachedDenial.ok and cachedDenial.value.status == "Denied" and effects == 1,
			"explicit denial is distinct from timeout and remains the receipt for that ID")
		assert(test.server:GetDiagnostics().counters.handlerErrors == 0)
	end)
	rewards:Destroy()
end

-- The global player cap releases a slot when an admitted player leaves.
do
	local rewards = Rewards.new(function() return 0 end, function() end)
	local players = {}
	for index = 1, 64 do
		players[index] = {}
		assert(rewards:AddPlayer(players[index]))
	end
	local extra = {}
	assert(not rewards:AddPlayer(extra))
	rewards:RemovePlayer(players[1])
	assert(rewards:AddPlayer(extra))
	rewards:Destroy()
end

-- A failed native-script startup releases app listeners and accounts without Script destruction.
do
	local runtime = require("./support/ServerRuntime").new()
	local player = runtime:addPlayer()
	local server, rewards, onDestroy
	local definitionMarker, rewardsMarker = {}, {}
	local storage = { Relay = relayMarker, Definition = definitionMarker }
	local loaded = luau.load(fs.readFile("examples/operation-id-rpc/Server.server.luau"), {
		debugName = "OperationIdServerStartup", injectGlobals = true,
		environment = {
			game = { GetService = function(_, name)
				return if name == "Players" then runtime.players else storage
			end },
			script = { Parent = { Rewards = rewardsMarker }, Destroying = {
				Connect = function(_, callback) onDestroy = callback end,
			} },
			require = function(module)
				if module == definitionMarker then return definition end
				if module == rewardsMarker then return { new = function()
					rewards = Rewards.new(function() return 0 end, function() end)
					return rewards
				end } end
				assert(module == relayMarker)
				return { createServer = function(token, options)
					server = assert(runtime.server.create(token, options))
					return { events = server.events, requests = server.requests,
						Start = function() return false, { message = "controlled startup refusal" } end,
						Destroy = function() server:Destroy() end,
					}
				end }
			end,
		},
	})
	local started, issue = pcall(loaded)
	assert(not started and tostring(issue):find("controlled startup refusal", 1, true))
	assert(runtime.connections == 0 and server:GetDiagnostics().state == "Destroyed")
	assert(not rewards:AddPlayer(player) and rewards:Lookup(player, 1, 1).status == "Unknown")
	onDestroy() -- Cleanup remains safe when the Script is later destroyed.
end

print("PASS operation-ID RPC reward receipts, bounds, reconciliation and cleanup")
