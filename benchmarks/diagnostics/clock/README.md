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
non-Result identity, and baseline/source preservation. Live Studio capture is
still needed to verify the engine lifecycle and obtain observed clock values.

This observer can perturb scheduling. One capture can explain its own rejection,
not prove the numerical cause of earlier failures or CPU/GPU causation. It does
not authorize loosening the clock check, repairing vendors, or resuming collection.
