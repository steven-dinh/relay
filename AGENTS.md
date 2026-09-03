# Relay Contributor Rules

## Scope

- Keep Relay standalone. Relay must not depend on a game repository or its Core package.
- Implement only approved slices. Do not add speculative APIs, abstractions, adapters, or configuration.
- The approved public surface is frozen to `VERSION`, `define`, `createServer`, and `createClient`.

## Package boundaries

- Publishable source lives under `src/`.
- Tests and verification tooling stay outside the Wally package.
- Generated files, dependencies, benchmark vendors, generated benchmark code, local results, and local Forge artifacts remain ignored.
- Do not edit downloaded or generated contents.

## Networking guardrail

- Any future remote, decoder, serializer, transport, batching, RPC, or middleware change requires a dedicated design and security review.
- Treat every future client payload and byte stream as attacker-controlled.

## Benchmarks

- Keep correctness checks separate from timing.
- Benchmark equivalent semantics before rankings.
- Keep setup outside timed regions and pin every compared dependency.
- Do not commit third-party source or local benchmark results.

## Verification

- Run `lune run scripts/verify-foundation.luau` after foundation changes.
- Update `context.md` whenever purpose, ownership, public API, modules, tests, or guardrails change.
- Keep changes surgical and remove only unused code introduced by the current change.
