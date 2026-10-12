# Saved MicroProfiler HTML analysis

This CLI parses a saved Roblox MicroProfiler HTML export without opening it as a browser page or launching Studio. It uses the pinned viewer and Tools from an external reviewed anchor, then writes normalized frame, marker, network-event, relationship, and accounting data to a new JSON file.

## Run

Set `RELAY_PROFILE_RUNTIME` to the absolute root containing the pinned `node/bin/node.exe`, `python/python.exe`, and `node/node_modules`. Set `RELAY_PROFILE_ASSETS` to the reviewed `editor-high-32frames.html` anchor. The command rejects other Node/Python executable or anchor hashes and unsupported Playwright/Chromium versions. It does not install or update anything.

```powershell
$node = Join-Path $env:RELAY_PROFILE_RUNTIME 'node/bin/node.exe'
& $node benchmarks/profiling/html/extract-network.mjs INPUT.html NEW-OUTPUT.json [MARKER]
```

Omit `MARKER` to skip marker extraction. When filtering a viewer timer whose name starts with `::`, pass the base name without that prefix; this matches the retained reports' canonical marker argument. The output path must be new. Errors, unsupported dumps, malformed containers, and empty captures return nonzero without producing a measurement report. Keep the original input and outputs as separate files.

The supported runtime is Node 24.19.0 and Python 3.12.14 with pinned executable SHA-256 values in `runtime.mjs`; Playwright 1.62.1 and Chromium revision 1234 are loaded from that runtime. The external anchor is pinned by full-file hash as well as the viewer, Tools, and raw-format-5 identities. No dependencies or assets are downloaded.

The configured runtime directory, installed Playwright package tree, and installed Chromium binary are trusted host inputs. Node and Python executables plus the anchor HTML are checked by SHA-256. Playwright and Chromium version checks confirm their reported versions, but do not hash the full package tree or browser files. The boundary protects against untrusted dump data under this host-trust model.

The input HTML remains inert. Only the pinned anchor supplies executable viewer/decoder code. Parsing runs in a sandboxed Chromium dedicated worker with offline mode, a restrictive CSP, denied network and WebSocket requests, bounded output, and a 30-second worker deadline. The Windows wrapper assigns the process to a Job before execution, caps aggregate committed memory at 2 GiB and active processes at 32, and verifies cleanup. V8 flags are secondary bounds; the Job is the aggregate resource boundary.

## Checks

Invoke the Node and Python checks with the pinned executables. The pure normalizer check needs neither the external assets nor Chromium. Browser checks require the configured anchor and pinned runtime. Supply fresh output paths; these checks never write into retained inputs or source files.

```powershell
$node = Join-Path $env:RELAY_PROFILE_RUNTIME 'node/bin/node.exe'
$python = Join-Path $env:RELAY_PROFILE_RUNTIME 'python/python.exe'
& $node benchmarks/profiling/html/verify-normalizer.mjs
& $node benchmarks/profiling/html/verify-extractor.mjs
& $node benchmarks/profiling/html/verify-normalizer.mjs --viewer .tmp/profile-viewer-oracle.json
& $python benchmarks/profiling/html/verify-bounded-process.py
& $python benchmarks/profiling/html/verify-dump-output.py RETAINED_ANALYSIS_DIR FRESH_EXTRACTION.json NEW_REPORT.json
```

For explicit empty-capture and overwrite checks, pass paths to a retained empty export, an existing output, and a new path that should remain absent:

```powershell
& $node benchmarks/profiling/html/verify-extractor.mjs --cli-failures EMPTY_CAPTURE.html EXISTING_OUTPUT.json NEW_FAILURE_OUTPUT.json
```

The hold dump-output check accepts one fresh extraction, checks it against the retained parser output and official CSV, and reports the two known additions separately: explicit viewer zero buckets and `viewerNetworkTotalsAvailable`. It keeps marker, frame, marker-execution, network, relationship, and accounting comparisons exact. For a positive retained export, use strict semantic equality (excluding provenance) with the matching historical post-fix output. Set `RELAY_PROFILE_ASSETS` as described above. Pass the retained evidence root that contains the historical report; the historical report must be inside that root, while the fresh extraction and new report must be outside the entire root, this verifier's source directory, and the anchor directory:

```powershell
& $python benchmarks/profiling/html/verify-dump-output.py --positive RETAINED_EVIDENCE_ROOT RETAINED_POSITIVE_REPORT.json FRESH_POSITIVE_EXTRACTION.json NEW_REPORT.json
```

The positive check also runs small structural regressions that reject a missing viewer category/counter field and a fresh/report path in a sibling directory under retained evidence. Historical hold-pair and repeat results are read-only context.

## Limits

These reports describe what the saved HTML and pinned viewer expose. Empty network records mean evidence is absent, not that traffic was zero. Viewer accounting does not establish physical wire bytes. Rates, per-workload attribution, capture retention, and network-history preservation remain unqualified. This CLI removes the need to use computer control to inspect or parse an already-saved dump; computer control may still be needed to operate Studio and export one. It does not qualify a new capture or replace a native profiling check.

The retained real-network check contains five records and no packet relationships.
Synthetic viewer checks cover relationship bookkeeping; real binary packet-link
decoding remains unqualified.
