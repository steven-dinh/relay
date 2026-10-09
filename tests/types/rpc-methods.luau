--!strict
local s = require("../../src/init").schema
local Item = s.struct(
    s.field("id" :: "id", s.u32()),
    (s.field("count" :: "count", s.u16()))
)
return {
    Inspect = s.request(2, s.ordered(s.field("itemId", s.u32())), s.struct(
        s.field("mode" :: "mode", s.enum("Owned" :: "Owned", "Missing" :: "Missing")),
        (s.field("items" :: "items", s.array(Item, 4)))
    )),
    Enabled = s.request(3, s.ordered(), s.boolean()),
    Selected = s.request(4, s.ordered(s.field("slot", s.u8())), s.optional(s.u32())),
}
