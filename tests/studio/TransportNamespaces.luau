local function create(Relay)
    local schema = Relay.schema
    local definition, failure = Relay.define({
        name = "RelayTransportNamespacesProof",
        version = 1,
        readiness = true,
        events = {
            Input = { id = 1, direction = "ClientToServer", fields = { schema.field("value", schema.u8()) } },
            Output = { id = 2, direction = "ServerToClient", fields = { schema.field("value", schema.u8()) } },
        },
    })
    assert(definition ~= nil, failure and failure.message or "transport namespace definition failed")
    return definition
end

return table.freeze({ create = create })
