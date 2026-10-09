# Relay

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. It has no runtime
dependencies. The current source version is `0.2.0`; the API is evolving. The
Wally package is marked private.

## Documentation

- [Documentation](https://steven-dinh.github.io/relay/)
- [API and protocol reference](docs/reference.md)
- [Examples](examples/README.md)
- [Benchmarks](benchmarks/README.md)

## Development setup

Install [Rokit](https://github.com/rojo-rbx/rokit) `v1.2.0`. From the repository
root, build Relay:

```sh
rokit install
rojo build default.project.json --output relay.rbxmx
```

Import `relay.rbxmx` into `ReplicatedStorage`. For strict consumer typing, enable
Workspace's `UseNewLuauTypeSolver` in Studio and use `--!strict` in your scripts.
Place the shared definition module in `ReplicatedStorage` so both server and
client can require it.

## Shared definition

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Relay = require(ReplicatedStorage.Relay)
local s = Relay.schema

local definition, definitionError = Relay.define({
    name = "Gameplay",
    version = 1,
    events = {
        Input = s.clientToServer(1, s.ordered(
            s.field("sequence", s.u32()),
            (s.field("enabled", s.boolean()))
        )),
    },
})

return assert(definition, definitionError and definitionError.message)
```

Use the [server](examples/reliable-events/Server.server.luau) and
[client](examples/reliable-events/Client.client.luau) scripts as a starting
point; both show listener and session cleanup. See [all examples](examples/README.md)
for more patterns.

## Protocol and abuse limits

Relay validates and bounds incoming payload work, but schemas do not authorize
gameplay. Your game owns permission checks. See the [full protocol and
abuse-limit contract](docs/reference.md#protocol-and-abuse-limits).

## Contributing

Run the foundation verifier with `lune run scripts/verify-foundation.luau`.

## License

[MIT](LICENSE)
