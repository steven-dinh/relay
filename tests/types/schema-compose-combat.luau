--!strict
local Relay = require("../../src/init")
local s = Relay.schema

return table.freeze({
    Attack = s.clientToServer(1, s.ordered(
        s.field("amount" :: "amount", s.u16()),
        (s.field("move" :: "move", s.struct(
            s.field("style" :: "style", s.enum("Slash" :: "Slash", "Guard" :: "Guard")),
            (s.field("sequence" :: "sequence", s.array(s.u8(), 4)))
        )))
    )),
})
