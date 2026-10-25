# Offline schema checks

Run from the Relay repository root with Lune:

```sh
lune run scripts/check-schema.luau path/to/spec.luau
lune run scripts/check-schema.luau path/to/spec.luau --json
lune run scripts/check-schema.luau path/to/spec.luau --require-endpoint-rates path/to/inbound-rate.luau
```

Paths are relative to the repository root; absolute paths are unsupported. A spec
module returns the same raw definition table passed to `Relay.define` and may use
`Relay.schema` helpers.
For example, save this as `Spec.luau` at the repository root:

```lua
local s = require("./src/Schema")
return {
	name = "Example",
	version = 1,
	outboundBytes = { capacity = 128, refillPerSecond = 64 },
	events = {
		Input = s.clientToServer(1, s.fields({ value = s.u8() })),
		State = s.serverToClient(2, s.fields({ value = s.string(32) })),
	},
	requests = {
		Inspect = s.request(3, s.fields({ itemId = s.u16() }), s.struct({ owned = s.boolean() })),
	},
}
```

Save this as `InboundRate.luau` at the same location:

```lua
return {
	perPlayer = { capacity = 64, refillPerSecond = 32 },
	aggregate = { capacity = 256, refillPerSecond = 128 },
	endpoints = {
		[1] = { capacity = 32, refillPerSecond = 16 },
		[3] = { capacity = 8, refillPerSecond = 4 },
	},
}
```

The rate-policy module returns the normal server `inboundRate` table; the option
checks only that its per-endpoint
buckets cover every client-to-server event and request, and reject extra
non-client endpoint IDs. It does not check the rest of `createServer` options.

The checker calls Relay's definition compiler and inspector, so compiler errors
keep Relay's bounded schema path and reason. JSON output includes the inspected
size bounds; native Roblox byte sizes remain `Unknown` in Lune. Invalid schemas,
module load errors, arguments, or requested endpoint policies exit nonzero.
The compiler reports its first schema error; fix that error and rerun the check.

Spec and policy modules run as trusted local Luau code, must work under Lune,
and must not print to stdout so JSON output stays parseable. Studio `game`
services are not emulated; the checker loads the existing `Definition` compiler
and inspector without loading runtime sessions. Keep the authored schema in a
shared module for Studio and the Lune input. The in-game definition/runtime
compiler remains authoritative.
