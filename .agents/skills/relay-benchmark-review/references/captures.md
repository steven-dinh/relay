# Capture and attribution

First identify which raw artifact supports the requested metric, its exact
run/source/engine, participants, measured windows and clock mapping. If these
cannot be established, say the claim is inconclusive and name the missing proof.
Result V2 and broadcast ledgers do not establish CPU or physical-wire attribution.
The supporting assessor always leaves these claims unqualified; extra flags in
an input ledger cannot authorize them.

## CPU and LibMP

Distinguish synchronous elapsed time, callback elapsed time, actual CPU work,
allocations and process-wide heap counters. Quick receive profiles include
capture/instrumentation and exclude engine decode, scheduling and transit.
Do not label them end-to-end receiver CPU.

For native LibMP, inspect retained qualification evidence for the exact Studio
build/SDK, reader slot/frame range, exact known-work enter/exit sentinel,
positive and negative controls, native UI/exact-frame corroboration, stopping
state and committed prefix. Marker presence alone proves only marker presence.
Related descriptor names must not widen the exact sentinel's accepted IDs.
`Step=false`, a capped scan, heartbeat timing or zero matches do not establish
clean EOF, a drain fence, full-window absence, or work's profiler-frame placement.
Do not promote the disabled benchmark collector based on those probes.

For attributable costs, map raw scopes to the same measured workload windows
and every receiver. Include deferred codec/engine work when the claimed scope
requires it; exclude setup/control work, avoid inclusive child/parent double
counting, and account for yields and observer overhead. A parser cannot certify
that human accounting review. Sender/receiver boundaries must match on both sides.

## Saved HTML and packets

Use the existing pinned offline extractor and checks from
`benchmarks/profiling/html/README.md` for saved HTML. Keep HTML inert, use a new
output and retain input hashes. Supported parsing is separate from native
capture qualification and real binary packet-relationship qualification.
Empty/missing network records mean unavailable evidence, never zero traffic.
Synthetic relationship tests do not qualify actual packet links.

For serializer studies, reuse `benchmarks/serializer-gate.md` and
`benchmarks/host/run-serializer-gate.luau` for artifact hashes, same-run receipts,
CPU supplements and pinned TShark re-decoding. Its `EligibleForReview` still
requires the retained human accounting/environment/boundary audits. Do not
introduce a parallel evidence format or trust entered byte totals.

Packet attribution needs complete send-through-drain intervals, loss/drop and
truncation evidence, actual connection/participant identity, matching clocks and
encapsulation, all recipients, and separation from control/other replication.
Count bidirectional ACKs/retransmissions once at a single capture point.
Use verified delivery denominators for those exact windows. Captured-frame bytes
remain distinct from physical WAN traffic and payload bytes. `buffer.len`,
engine-wide KB/s, HTML file size, idle subtraction and viewer totals cannot
replace attributable wire bytes. Inseparable traffic keeps the claim inconclusive.
