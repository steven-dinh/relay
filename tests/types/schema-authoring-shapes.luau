--!strict
local Relay = require("../../src/init")
local s = Relay.schema

local Mode = s.enum({ Idle = 1, Run = 2 })
local Record = s.struct({ id = s.u32() }, { mode = Mode })
local Result = s.taggedUnion({
	kind = {
		Success = s.struct({ value = s.u8() }),
		Failure = s.struct({ reason = s.string(24) }),
	},
})
local NamedKeys = s.struct({ name = s.u8() }, { type = s.string(8) })

return {
	Mode = Mode,
	Record = Record,
	Result = Result,
	NamedKeys = NamedKeys,
	LegacyRecord = s.struct(s.field("value" :: "value", s.u16())),
	MixedRecord = s.struct({ id = s.u32() }, s.field("count" :: "count", s.u16()), { mode = Mode }),
}
