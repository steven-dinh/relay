--!strict
local Relay = require("../../src/init")
local s = Relay.schema

-- Names and enum values still require singleton annotations under the pinned solver.
return s.struct(
    s.field("mode" :: "mode", s.enum("Idle" :: "Idle", "Run" :: "Run")),
    s.field("modes" :: "modes", s.set(s.enum("Idle" :: "Idle", "Run" :: "Run"), 4)),
    s.field("singleMode" :: "singleMode", s.set(s.enum("Only" :: "Only"), 1)),
    s.field("scores" :: "scores", s.array(s.u16(), 4)),
    s.field("tags" :: "tags", s.set(s.string(8), 4)),
    (s.field("target" :: "target", s.optional(s.u32())))
)
