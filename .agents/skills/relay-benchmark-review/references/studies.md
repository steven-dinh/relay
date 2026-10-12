# Study review

Use `benchmarks/README.md` for collection and canonical comparison commands,
and `context.md` for current qualification limits. This skill reviews existing
evidence. Prepare a new campaign only when the user requests it.

## Evidence and provenance

Retain original ledgers, logs, failed attempts and raw results. Verify library
versions against `benchmarks/libraries.lock.json` and the measured artifacts,
including tag/source-commit splits and generated adapter identity. Verify the
exact Studio version/executable and benchmark harness/contract fingerprints.
Compare like workloads, delivery semantics, topology and metric boundaries.
Result V1 and persistent Result V2 are different cohorts; quick Output tables
accept dirty local source and cannot become canonical evidence.

The broadcast assessor reuses `BroadcastStudyReport.report`, which validates
the exact schedule, original source roots/result names, raw hashes/sizes,
canonical V2 correctness and compatibility, and baseline/control adapter pins.
It never trusts a saved report as a substitute for the raw files. A reporter
error blocks assessment of the supplied study; do not bypass it or edit raw
results to make a comparison pass.

```powershell
lune run .agents/skills/relay-benchmark-review/scripts/assess-study.luau --ledger '<study>/ledger.json' --maximum-control-drift <chosen-fraction> --current-root '<checkout>' --source-role candidate
lune run benchmarks/tests/benchmark-review.luau
```

The optional source check reuses the collector's clean Git identity check before
and after offline validation. A clean matching revision establishes only
`CleanRevisionMatch`. It does not revalidate ignored generated/vendor artifacts,
the built place or the current engine, nor measure current performance. A dirty,
changed, unavailable or mismatching checkout cannot anchor a current claim.
Without this option the source relationship is `NotCompared`; raw evidence
still describes its recorded snapshot. Never clean or reset a shared checkout
to manufacture eligibility.

## Controls and inference

Keep baseline, candidate and unchanged control in each paired cycle, with both
orders. Inspect median and p95 deltas against baseline **and control**; pooled
gains can conceal machine drift. Account for environment/load and preserve
failed/invalid launches. Do not select favorable retries after seeing results.

Ask for or reuse the user's declared tolerance. The CLI requires an explicit
nonnegative fractional tolerance; `0.05` means 5% and is only an example policy.
A retrospective tolerance can summarize a historical study but is not evidence
of predeclaration, statistical significance, or an independent uncertainty
interval. Record a predeclared policy artifact and when it preceded collection
if promotion depends on it; the ledger/reporter does not establish this.

`DiagnosticsOnly` means valid raw evidence and controls within the supplied
tolerance, with requested source checks satisfied. It grants no winner or
promotion. `Inconclusive` retains valid diagnostics when controls exceed the
tolerance, comparisons are unknown, or current-source identity fails.
Requesting a source role absent from a valid study also leaves the current-source
relationship unestablished and the assessment `Inconclusive`.
`Blocked` means arguments or raw study evidence could not be validated. The
assessor prints JSON only, exits 0 for `DiagnosticsOnly`, 1 for `Inconclusive`,
and 2 for `Blocked`. Its nested report retains units, scopes and raw pins.

One process with 30 windows is one independent launch. Two ordered launches
per role remain a smoke study, even with large within-process sample counts.
A rigorous claim needs an appropriate predeclared design, independent launches,
uncertainty analysis and protected-workload checks. Portable fixtures, Lune
timings and archive replay prove tooling behavior, not Roblox speed.

Report submit-call cost, sender frame interval, delivered throughput, drain,
completion/ACK age and RTT separately. RTT is not one-way latency or FPS.
Component savings are not whole-library gains; improvements against different
baselines cannot be added or compounded without a direct comparison.
