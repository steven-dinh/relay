--!strict
local Relay = require("../../src/init")
local Methods = require("./rpc-methods")
local definition = assert((Relay.define({ name = "BadRpcConsumer", version = 1, events = {}, requests = Methods })))
local server = assert((Relay.createServer(definition, { inboundRate = {
    perPlayer = { capacity = 16, refillPerSecond = 16 }, aggregate = { capacity = 32, refillPerSecond = 32 },
} })))
local client = assert((Relay.createClient(definition, { startupTimeoutSeconds = 3 })))
client.requests.Unknown:Request(1)
server.requests.Inspect:Request(1, 2)
client.requests.Inspect:Connect(function() end)
client.requests.Inspect:Request("slow", 2)
client.requests.Inspect:Request(1, "bad")
client.requests.Inspect:Request(1)
client.requests.Inspect:Request(1, 2, true)
client.requests.Enabled:Request(1, true)
server.requests.Enabled:Connect(function(_player) return 1 end)
server.requests.Selected:Connect(function(_player, _slot) return false end)
server.requests.Inspect:Connect(function(_player, _id) return { mode = "Other", items = {} } end)
server.requests.Inspect:Connect(function(_player, _id) return { mode = "Owned", items = { { id = "bad", count = 1 } } } end)
server.requests.Inspect:Connect(function(player: number, id: string) return { mode = "Owned", items = {} } end)
local pending = assert((client.requests.Inspect:Request(1, 1)))
pending:Cancel(true)
local result = pending:Await()
if result.ok then
    local wrong: string = result.value.items[1].count
    print(wrong)
else
    print(result.value)
end
