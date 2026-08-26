# Relay Benchmarks

This directory is reserved for neutral comparisons between Relay and other Roblox networking libraries. No competitors or benchmark results are included in the foundation release.

Future benchmarks must follow these rules:

- prove correctness before ranking performance;
- use deterministic fixtures;
- keep setup and dependency loading outside timed regions;
- provide equivalent-semantics and native-best lanes when features differ;
- measure real wall time;
- pin exact dependency revisions;
- keep downloaded source, generated code, and local results untracked.

Correctness tests remain separate from timing and never fail because of timing variance.
