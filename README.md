# Relay

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. It has no runtime
dependencies. The current source version is `0.2.0`; the API is evolving. The
Wally package is marked private. This repository's documentation follows
mutable `main` and may differ from a published release even while
`Relay.VERSION` remains `0.2.0`. Starting with v0.2.0, each published release
tag preserves its API reference.

## Documentation

- [Documentation](https://steven-dinh.github.io/relay/)
- [Development API and protocol reference](docs/reference.md)
- [Published v0.2.0 API and protocol reference](https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md)
- [Environment and support](docs/reference.md#environment-support-and-reporting)
- [Security policy](SECURITY.md)
- [Examples](examples/README.md)
- [Benchmarks](benchmarks/README.md)

## Install the published release

Download the [v0.2.0 model](https://github.com/steven-dinh/relay/releases/download/v0.2.0/Relay-v0.2.0.rbxmx)
and import it into `ReplicatedStorage`. Use its [published API reference](https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md)
and [reliable-events example](https://github.com/steven-dinh/relay/tree/v0.2.0/examples/reliable-events).
The matching [v0.2.0 source ZIP](https://github.com/steven-dinh/relay/releases/download/v0.2.0/Relay-v0.2.0-source.zip)
is available for source-based use.

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
For an advisory first check during development, use
`lune run scripts/verify-foundation.luau --first --dry-run`, then omit `--dry-run`
to execute the displayed plan. Selection reads staged, unstaged and untracked
changes against HEAD; explicit mappings and reasons are printed. Unknown files,
deletions, renames and an empty change set fall back to the full gate.
Always run the default full command before completion; advisory checks do not
replace correctness, package, build, CI or independent review requirements.

Each non-dry-run invocation reserves an ignored `.tmp/verification/` directory. It records
the revision, dirty source fingerprint, checks actually run and passed/failed,
blocked or skipped stages in `report.json`. Successful runs remove their own
generated artifacts; failed runs retain them. Interrupted runs may leave owned
directories for inspection. Clean up only the exact completed run directory.
Public-type checks preserve pinned, hash-verified definitions, positive/negative
fixtures and example analysis, with their own isolated sourcemaps. The legacy
definitions cache is read-only. Verification does not launch Studio or qualify
benchmark measurements; native checks require a coordinated quiet window.

## License

[MIT](LICENSE)
