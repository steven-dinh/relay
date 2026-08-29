# Relay

## Requirements

- [Rokit](https://github.com/rojo-rbx/rokit) `v1.2.0`

## Development setup

From the repository root:

```sh
rokit install
lune run scripts/verify-foundation.luau
```

The verifier runs the registered correctness tests and checks the public module
contract, tracked file set and LF policy, Git ignore rules, Wally package
contents and archive creation, the Rojo package build, and CI workflow pins.

## Public surface

`src/init.luau` returns a frozen table containing only:

```lua
{
    VERSION = "0.1.0",
}
```

No remotes, codecs, schemas, transports, batching, RPC, middleware, or Core adapters are implemented.

## Repository boundaries

- `src/` contains publishable package source.
- `tests/` and `scripts/` contain correctness tooling.
- `examples/` is reserved for future public API examples.
- `benchmarks/` is an isolated benchmark workspace.
- durable repository guidance and plans are tracked; downloaded benchmark
  libraries, generated output, local results, builds, dependencies, editor
  state, and local Forge specs/reports remain ignored.

## License

[MIT](LICENSE)
