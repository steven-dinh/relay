# Relay Contributor Rules

## Scope

- Keep Relay standalone. Relay must not depend on a game repository or its Core package.
- Implement only approved slices. Do not add speculative APIs, abstractions, adapters, or configuration.
- The approved public surface is `VERSION`, `schema`, `define`, `inspect`, `createServer`, and `createClient`. The competitive roadmap authorizes useful reviewed additions; preserve strict typing and protocol/security guardrails.

## Branch naming

- Reuse a suitable existing branch and worktree instead of creating another unnecessarily.
- Use plain descriptive branch names without a `codex/` prefix, unless the user explicitly requests that prefix.

## Package boundaries

- Publishable source lives under `src/`.
- Tests and verification tooling stay outside the Wally package.
- Generated files, dependencies, benchmark vendors, generated benchmark code, local results, and local Forge artifacts remain ignored.
- Do not edit downloaded or generated contents.

## Networking guardrail

- Any future remote, decoder, serializer, transport, batching, RPC, or middleware change requires a dedicated design and security review.
- Treat every future client payload and byte stream as attacker-controlled.
- **Protocol and abuse limits:** before adding or extending unreliable events or composite shapes, specify version compatibility, maximum total encoded size, array length, nesting depth, and admission charges in the design and security review. Keep the current contract in README.md's Protocol and abuse limits section.
- A decoder must reject malformed client data before any handler call, checking bounds before reads, allocation, or traversal. Focused checks must prove rejection and applicable admission charging.

## Benchmarks

- Keep correctness checks separate from timing.
- Benchmark equivalent semantics before rankings.
- Keep setup outside timed regions and pin every compared dependency.
- Do not commit third-party source or local benchmark results.

## Verification

- Use a Sol (`gpt-6-sol`) subagent for code reviews.
- Run `lune run scripts/verify-foundation.luau` after foundation changes.
- Update `context.md` whenever purpose, ownership, public API, modules, tests, or guardrails change.
- Keep changes surgical and remove only unused code introduced by the current change.
