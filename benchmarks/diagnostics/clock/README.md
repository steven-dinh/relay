# Untimed shared-clock diagnostic

This is a fixed Relay `state-broadcast-s2c`, four-client diagnostic, not a
benchmark mode or a matrix runner. It captures the clock values missing from
the two failed startup checks recorded in `../../session-reuse-review.md`.

```powershell
lune run benchmarks/diagnostics/clock/run.luau --studio <absolute Studio executable>
lune run benchmarks/tests/clock-diagnostic.luau
```

Run from the repository root with clean source and no Studio process running.
The host launches one fresh session, with a 180-second deadline and bounded
exit confirmation. It writes an ignored `clock-diagnostic-<launchId>.json` in
`benchmarks/results/local/` only after confirming Studio has exited.

The host builds the ordinary frozen place, then overlays a diagnostic wrapper
in a separate in-memory copy. The real control protocol remains an unchanged
sibling module. The wrapper observes its injected server clock and validated
replies: the last 32 readiness replies and at most four formal clock replies.
It stops on clock rejection or the fourth accepted formal reply, before warmup
or measured traffic. A separate begin-warmup guard enforces this boundary.

The artifact is explicitly `RelayClockDiagnostic`, non-ranking, and neither
Result V1 nor Result V2. Its baseline measurement fingerprint is recorded
separately from the instrumented place and observer fingerprints. The ordinary
measurement fingerprint must still equal
`sha256:10729c469a27cd393dbaa2512139e6be42a8c4e50098f2ed9aab91d995395f00`.
No production, vendor, measured harness, contract, or saved result is changed.

The dedicated read-only design/security review checked the fixed selection,
unchanged protocol delegation, stop-before-warmup boundary, authenticated and
size-bounded host collection, and exit-before-publication cleanup. The focused
test uses the real control protocol and an actual base-place build. It covers
successful and rejected clocks, suspension before timing, malformed framing,
non-Result identity, and baseline/source preservation.

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
