local function create(Relay, endpointCount)
	local events = {
		ClientProof = {
			id = 1,
			direction = "ClientToServer",
			fields = { { name = "result", type = "u8" } },
		},
	}
	for index = 2, endpointCount do
		local name = string.format("Endpoint%02d", index)
		events[name] = {
			id = index,
			direction = "ServerToClient",
			fields = { { name = "value", type = "u8" } },
		}
	end
	local definition, problem = Relay.define({
		name = "RelayToolsNativeQualification",
		version = 1,
		readiness = false,
		events = events,
	})
	assert(definition ~= nil, problem and problem.message or "definition failed")
	return definition
end

return table.freeze({ create = create })
