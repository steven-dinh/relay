--!strict
local Relay = require("../../src/init")
local s = Relay.schema

return table.freeze({
    State = s.serverToClient(65_535, s.ordered(
        s.field("items" :: "items", s.array(s.u16(), 8)),
        (s.field("selected" :: "selected", s.optional(s.u8())))
    ), "Unreliable"),
})
