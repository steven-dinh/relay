--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local Definition = require(ReplicatedStorage.Definition)
local createDrain = require(script.Parent.Drain)

local sessionResult, createError = Relay.createServer(Definition, {
	inboundRate = {
		perPlayer = { capacity = 120, refillPerSecond = 60 },
		aggregate = { capacity = 960, refillPerSecond = 480 },
	},
})
local session = assert(sessionResult, createError and createError.message)
local drain = createDrain(session, task.spawn, os.clock, task.wait)

local connectionResult, connectError = session.events.Work:Connect(function(player, value)
	local accepted, refusal = drain:Run(function()
		-- Replace with bounded application work. It may yield; Run tracks it through return.
		task.wait(0.1)
		print(`finished work {value} for {player.UserId}`)
	end)
	if not accepted then warn(`refused work: {refusal}`) end
end)
local connection = assert(connectionResult, connectError and connectError.message)
local started, startError = session:Start()
assert(started, startError and startError.message)

game:BindToClose(function()
	connection:Disconnect()
	local drained = drain:Shutdown()
	if not drained then warn("session drain deadline elapsed; callbacks may still run") end
end)
