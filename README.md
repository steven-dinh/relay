# Relay

Relay is a standalone Roblox event library with fixed schemas, reliable delivery
by default, and optional per-event unreliable delivery. It has no runtime
dependencies. This checkout documents Relay `0.3.0`. The Wally package is
private. Each GitHub release starting with `v0.2.0` preserves matching docs
and examples in its tag and source ZIP.

## Documentation

- [Quickstart](https://steven-dinh.github.io/relay/)
- [API and protocol guide](https://steven-dinh.github.io/relay/guide.html)
- [Development API and protocol reference](https://github.com/steven-dinh/relay/blob/main/docs/reference.md)
- [Benchmarks](https://steven-dinh.github.io/relay/benchmarks.html)
- [Upgrade compatibility](docs/reference.md#upgrade-compatibility)
- [Published v0.2.0 API and protocol reference](https://github.com/steven-dinh/relay/blob/v0.2.0/docs/reference.md)
- [Environment and support](docs/reference.md#environment-support-and-reporting)
- [Security policy](SECURITY.md)
- [Examples](examples/README.md)
- [Relay Tools development integration](scripts/tooling/README.md)

## Install Relay

Download [Relay v0.3.0](https://github.com/steven-dinh/relay/releases/download/v0.3.0/Relay-v0.3.0.rbxmx)
and import the model into `ReplicatedStorage`. Add the ModuleScript and scripts
from [`examples/quickstart/`](examples/quickstart/) to the locations shown on the
[quickstart page](https://steven-dinh.github.io/relay/), then press Play.
The server prints each received Ping in Studio's Output window. Change
`Ping:Send(1)` in the client script to `Ping:Send(2)` to verify that your edit
arrives at the server.

The [0.3.0 source ZIP](https://github.com/steven-dinh/relay/releases/download/v0.3.0/Relay-v0.3.0-source.zip)
includes the matching [API reference](https://github.com/steven-dinh/relay/blob/v0.3.0/docs/reference.md)
and [examples](https://github.com/steven-dinh/relay/tree/v0.3.0/examples).

Build the quickstart place from the repository root:

```sh
rojo build examples/quickstart/default.project.json --output relay-quickstart.rbxlx
```

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
        Input = s.clientToServer(1, s.fields(
            { sequence = s.u32() },
            { enabled = s.boolean() }
        )),
    },
})

assert(definition, definitionError and definitionError.message)
return definition
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
