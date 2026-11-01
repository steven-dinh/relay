return function(context)
	context.withFixture(function(test)
		local received
		local connection, connectError = test.server.events.Input:Connect(function(player, value)
			assert(player == test.player)
			received = value
		end)
		assert(connection, connectError and connectError.message)
		local started, startError = test:Start()
		assert(started, startError and startError.message)
		local sent, sendError = test.client.events.Input:Send(7)
		assert(sent, sendError and sendError.message)
		test:Pump()
		assert(received == 7, "server observes Input after the portable Pump")
		connection:Disconnect()
	end)
end
