require("../scripts/consumer-testing/run")

local Relay = require("../src")
local Kit = require("../scripts/consumer-testing/Kit")
local s = Relay.schema
local namespacedDefinition = assert(Relay.define({
	name = "ConsumerTestingNamespace",
	version = 1,
	events = {
		Input = s.clientToServer(1, s.fields(s.field("value", s.u8()))),
		Notice = s.serverToClient(2, s.fields(s.field("value", s.u8()))),
	},
}))

local receivedInput, receivedNotice
Kit.withFixture(namespacedDefinition, function(test)
	assert(test.server.events.Input:Connect(function(_, value) receivedInput = value end))
	assert(test.client.events.Notice:Connect(function(value) receivedNotice = value end))
	assert(test:Start(), "namespaced sessions start")
	assert(test.client.events.Input:Send(23) and test:Pump() > 0 and receivedInput == 23,
		"namespaced client events reach the server")
	assert(test.server.events.Notice:Broadcast(24) and test:Pump() > 0 and receivedNotice == 24,
		"namespaced server events reach the client")
end, {
	server = {
		namespace = "typescript",
		inboundRate = {
			perPlayer = { capacity = 4_096, refillPerSecond = 1 },
			aggregate = { capacity = 32_768, refillPerSecond = 1 },
		},
	},
	client = { namespace = "typescript", startupTimeoutSeconds = 3 },
})

local mismatchOk, mismatchFailure = pcall(Kit.new, namespacedDefinition, {
	server = { namespace = "server" },
	client = { namespace = "typescript", startupTimeoutSeconds = 3 },
})
assert(not mismatchOk and tostring(mismatchFailure):find("namespaces must match", 1, true),
	"mismatched fixture namespaces must be rejected")
