# Relay Contributor Rules

## Scope

- Use [the contributor map](context.md#runtime-ownership) to find the module and focused test for the operation you are changing. Relay must stay independent of game repositories and their Core packages.
- Implement only approved slices. Do not add speculative APIs, abstractions, adapters, or configuration.
- Use code comments for non-obvious constraints, design rationale, or tool directives. Omit code narration and skill-generated tags such as `shortcut:`.
- The approved public surface is `VERSION`, `schema`, `define`, `inspect`, `createServer`, and `createClient`. The competitive roadmap authorizes useful reviewed additions; preserve strict typing and protocol/security guardrails.
- When asked to advance the roadmap, use `.tmp/roadmap-20261011/ROADMAP.md` and its `BLINKBLOX.md` acceptance criteria. Take the first unfinished, unblocked item and update its status and evidence. If the queue is unavailable, obtain its criteria before selecting a replacement. The [tracked summary](context.md#competitive-roadmap) records progress. Artifact preparation alone does not authorize publication.

## Package boundaries

- Publishable source lives under `src/`.
- Tests and verification tooling stay outside the Wally package.
- Generated files, dependencies, benchmark vendors, generated benchmark code, local results, and local Forge artifacts remain ignored.
- Do not edit downloaded or generated contents.
- GitHub releases attach only the Relay `.rbxmx` model and source ZIP. Keep example places, Wally ZIPs, installation files, manifests, and checksums out of release attachments.

## Networking guardrail

- Changes to remotes, decoders, serializers, transport, batching, RPC, or middleware require a dedicated design and security review.
- Treat every client payload and byte stream as attacker-controlled.
- Before adding or extending unreliable events or composite shapes, specify version compatibility, maximum total encoded size, array length, nesting depth, and admission charges in that review. Update the [protocol and abuse limits](docs/reference.md#protocol-and-abuse-limits) and keep the README link current.
- A decoder must reject malformed client data before any handler call, checking bounds before reads, allocation, or traversal. Focused checks must prove rejection and applicable admission charging.

## Benchmarks

- Keep correctness checks separate from timing.
- Benchmark equivalent semantics before rankings.
- Keep setup outside timed regions and pin every compared dependency.
- Do not commit third-party source or local benchmark results.
- For benchmark claims, follow the [measurement rules](benchmarks/README.md#measurement-rules). Use the local Relay benchmark-review skill when installed. Identify the operation and source measured. For timing comparisons, report control drift.

## Verification

- Run `lune run scripts/verify-foundation.luau` after foundation changes. On a clean checkout, follow the [CI setup](.github/workflows/ci.yml) to install pinned tools, acquire benchmark libraries and generate adapters first.
- Update `context.md` when purpose, ownership, public API, modules, tests, or guardrails change. Link to the owning spec or test for details.
- Keep changes surgical and remove only unused code introduced by the current change.
