# Untimed shared-clock diagnostic

This is a fixed Relay `state-broadcast-s2c`, four-client diagnostic, not a
benchmark mode or a matrix runner. The current diagnostic V2 tests **3 ms of
extra admission tolerance**. This is not a sleep or a clock-accuracy guarantee.
Historical diagnostic V1 captures below used the original zero-margin rule.

```powershell
lune run benchmarks/diagnostics/clock/run.luau --studio <absolute Studio executable>
lune run benchmarks/tests/clock-diagnostic.luau
```

Run from the repository root with clean source and no Studio process running.
The host launches one fresh session, with a 180-second deadline and bounded
exit confirmation. It writes an ignored `clock-diagnostic-<launchId>.json` in
`benchmarks/results/local/` only after confirming Studio has exited.

The host builds the ordinary frozen place, then overlays a diagnostic wrapper
in a separate in-memory copy. The original protocol remains an unchanged sibling.
A separately named candidate copy changes exactly two bracket comparisons to
allow 3 ms: readiness and formal replies. Each replacement must occur exactly
once. Finite, monotonic, local-clock, message-shape, and protocol checks remain
unchanged. No source file in the measured runner is edited.

The wrapper records raw server/client values, the zero-margin verdict, and the
candidate verdict. It captures the last 32 detailed readiness replies and all
four formal replies, even after a candidate rejection. It requires all four
challenges to have been sent before keeping the outer wait alive after a formal
failure; the candidate protocol's failure remains intact. Malformed replies and
terminations are never masked. All-four success requires four underlying
candidate acceptances, not merely four received replies.

The last formal callback stops the test without returning to the measured runner.
A separate begin-warmup guard enforces this boundary. Command/readiness clock-read
failures stop immediately; the host deadline bounds missing replies. Counters and
maximum violations cover all readiness replies, including those omitted from the
tail. Readiness phase duration uses one server-local `os.clock`, from the first
readiness command to the first formal command; it excludes Studio startup and is
not a guarantee that the clock converged.

The artifact is explicitly `RelayClockDiagnostic`, non-ranking, and neither
Result V1 nor Result V2. `version = 2` and `toleranceMilliseconds = 3` distinguish
this candidate from historical zero-margin diagnostics. Its baseline measurement
fingerprint is separate from instrumented-place, observer, and candidate-protocol
fingerprints. The ordinary
measurement fingerprint must still equal
`sha256:10729c469a27cd393dbaa2512139e6be42a8c4e50098f2ed9aab91d995395f00`.
No production, vendor, measured harness, contract, or saved result is changed.

The dedicated read-only design/security review checked the fixed selection,
two-comparison candidate, all-four failure collection, stop-before-warmup boundary,
authenticated and size-bounded collection, and exit-before-publication cleanup.
The focused test uses the real candidate protocol and an actual base-place build.
It covers tolerance edges, all-four and mixed first/last failures, duplicate and
malformed replies, suspension before timing, framing and false-success rejection,
non-Result identity, and baseline/original-source preservation.

This observer can perturb scheduling. One capture can explain its own rejection,
not prove the numerical cause of earlier failures or CPU/GPU causation. It does
not authorize loosening the clock check, repairing vendors, or resuming collection.

## Single live capture, 2026-09-07 UTC

At clean `a9ffd9a`, launch `0fce3636-7dc3-438e-896c-eb57ccd5fa70` completed in
44.94 seconds on Studio `0.737.0.7371584`. Its ignored artifact is
`../../results/local/clock-diagnostic-0fce3636-7dc3-438e-896c-eb57ccd5fa70.json`.
The status was `ClockAccepted`: all four formal replies passed. The wrapper
stopped before warmup and measured work, and the host confirmed Studio exit.

The capture contains six readiness rounds (24 replies). On participant 2's
sequences 4 and 6, the client timestamp exceeded the server's receipt-time
sample by 2.133 ms and 2.180 ms respectively. Readiness legitimately retries
these out-of-bracket samples; they were not formal proof failures. The final
two readiness rounds and all four formal replies were in bracket. Every
captured server read was finite and nondecreasing. The closest formal reply
was 0.631 ms below its server receipt-time sample.

This observes transient client/server clock disagreement, but does not reproduce
or establish the numerical cause of the two earlier formal failures. Roblox
documents the client value as a smoothed approximation, not an exact shared
clock; see its [GetServerTimeNow documentation](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Workspace.yaml#L1483).
No CPU/GPU cause is established, and the observer can affect scheduling.

The ordinary measurement fingerprint is unchanged. All 69 pre-existing local
Result V1/V2 files were hash-identical before and after the diagnostic; no new
measured result was produced. The frozen cohort still covers 33 of 56 selections.
No retry, clock-gate change, or further matrix launch followed this capture.

## Follow-up diagnosis and candidate

Two additional V1 captures at clean `63a39e3` took 96.94 seconds combined. The
second reproduced a formal `ClientAfterServerReceive` rejection of 0.279 ms after
two passing readiness rounds. The largest of 78 retained readiness/formal sample
violations across all three captures was 2.180 ms. An offline 0/1/2/3/5/10 ms
sweep made 3 ms the smallest tested margin covering those retained records.
The sample set is small and partly truncated; this is not an optimum or a
successful live test of the candidate. See the ignored
`../../results/local/clock-tolerance-analysis-2026-09-07.md` for the limits.

V2's all-four capture and complete readiness counters address those missing
observations for the candidate experiment. Focused local tests and the final
implementation review passed before live validation. Promotion to the measured
harness remains out of scope.

## Live 3 ms candidate validation, 2026-09-07 UTC

Three fresh sessions at clean `331da15` completed with four underlying candidate
acceptances each, before warmup, with Studio exit confirmed. All three used the
same candidate/observer source and the unchanged ordinary baseline fingerprint.

| Capture | Host elapsed | Readiness phase | Readiness rounds | Formal candidate replies | Formal zero-margin misses |
| --- | ---: | ---: | ---: | ---: | ---: |
| [9b2480e3](../../results/local/clock-diagnostic-9b2480e3-a10a-4cdf-8d7c-fb21fa707806.json) | 35.55 s | 457.86 ms | 2 | 4 / 4 accepted | 1: 0.914 ms |
| [8f166432](../../results/local/clock-diagnostic-8f166432-3abf-4077-b08b-56b7c3a7b582.json) | 37.71 s | 407.74 ms | 2 | 4 / 4 accepted | 1: 2.704 ms |
| [8ed88f19](../../results/local/clock-diagnostic-8ed88f19-10b9-4d4d-a805-bf90195a661e.json) | 35.64 s | 265.92 ms | 2 | 4 / 4 accepted | 0 |

The three host commands totaled 108.89 seconds. All 24 readiness replies were
retained; four missed the zero-margin bracket, none exceeded 3 ms. All 12 formal
replies were retained; two would fail the zero-margin predicate on those recorded
values, and none exceeded 3 ms. No server clock-read failure was observed. No
fixed settling sleep was added. This exercises the extra margin live, including
the remaining replies after an out-of-zero-margin final sample, rather than
inferring a whole session's outcome from a truncated capture.

These observations support 3 ms as a provisional startup-admission candidate;
they establish neither an optimum nor a 3 ms bound on actual clock error. The
largest formal violation, 2.704 ms, is only 0.296 ms below the candidate limit.
The observer and candidate copy can perturb scheduling. This is three short
startup captures for one topology, not a long-duration reliability test, an
unmodified measured run, or a paired startup-speed comparison. No fixed waiting
duration or wider 5/10 ms margin is demonstrated necessary by these captures.

All 74 pre-existing local JSON artifacts, including the 69 Result V1/V2 files,
were hash-identical after these three captures. No measured result was created;
the saved comparison still covers 33 of 56 selections. The measured clock rule,
contract, vendor files, and shared comparison fingerprint remain unchanged.
