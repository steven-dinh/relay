--!strict
local Relay = require("../../src/init")
local s = Relay.schema
Relay.define({ name = "BadRequests", version = 1, events = {}, requests = false })
Relay.define({ name = "BadMethod", version = 1, events = {}, requests = { Inspect = 1 } })
Relay.define({ name = "BadId", version = 1, events = {}, requests = { Inspect = s.request("one", s.ordered(), s.boolean()) } })
Relay.define({ name = "BadFields", version = 1, events = {}, requests = { Inspect = s.request(1, {}, s.boolean()) } })
Relay.define({ name = "NamedResponse", version = 1, events = {}, requests = { Inspect = s.request(1, s.ordered(), s.field("value", s.u8())) } })
Relay.define({ name = "BadResponse", version = 1, events = {}, requests = { Inspect = s.request(1, s.ordered(), s.array(s.optional(s.u8()), 4)) } })
Relay.define({ name = "BadResponseBounds", version = 1, events = {}, requests = { Inspect = s.request(1, s.ordered(), { type = "f32" :: "f32" }) } })
