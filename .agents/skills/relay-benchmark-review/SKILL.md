---
name: relay-benchmark-review
description: Review Relay benchmark or profiling evidence before performance claims, checking provenance, matched controls, raw integrity, capture validity, and CPU or packet attribution. Use for benchmark comparisons and promotion decisions; ordinary runtime edits do not require this workflow.
---

# Relay benchmark review

Read the checkout's `AGENTS.md` and the relevant benchmark ownership in
`context.md`. Record HEAD, origin and dirty state before interpreting evidence.
Use this skill from the repository root; keep outputs in a fresh ignored `.tmp/`
directory. A review request authorizes offline inspection, not a Studio campaign.

For paired State-broadcast ledgers, read [study review](references/studies.md)
and run the supporting assessor. It calls the existing offline reporter rather
than replacing its raw-result validation or drift calculations:

```powershell
lune run .agents/skills/relay-benchmark-review/scripts/assess-study.luau --ledger '<study>/ledger.json' --maximum-control-drift <chosen-fraction>
```

For current-source comparisons, add `--current-root <checkout>` and
`--source-role baseline` or `candidate`. For other canonical Result V1/V2
evidence, use `benchmarks/reporting/compare-results.luau` as described in
`benchmarks/README.md`; do not adapt a different cohort into a broadcast ledger.

If CPU, LibMP, network or packet claims are involved, read
[capture and attribution](references/captures.md). Parsed output or a found
marker alone cannot qualify a capture or attribute costs to Relay.

Report the evidence kind, exact revisions/versions, workload and metric boundary,
raw validation outcome, control drift against the user's chosen tolerance,
source relationship, and missing proof. Separate historical observations,
smoke diagnostics and rigorous campaigns. No default percentage establishes
significance. Invalid arguments or invalid, incompatible or missing raw study
inputs are blocked; drift, unestablished current-source identity, unqualified
attribution and insufficient independent runs make the requested
inference inconclusive. Preserve valid diagnostics without inventing a winner.
