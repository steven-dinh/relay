# Offline schema budget estimates

Run from the Relay repository root with Lune:

~~~sh
lune run scripts/analyze-schema-budget.luau scripts/analyze-schema-budget-example-spec.luau scripts/analyze-schema-budget-example-workload.luau
lune run scripts/analyze-schema-budget.luau scripts/analyze-schema-budget-example-spec.luau scripts/analyze-schema-budget-example-workload.luau --json
lune run scripts/analyze-schema-budget.luau scripts/analyze-schema-budget-example-spec.luau scripts/analyze-schema-budget-example-workload.luau --max-bytes-per-second 10000
~~~

The third command is a CI gate. The inclusive limit applies to the aggregate maximum modeled Relay buffer bytes per second. It exits nonzero for invalid input, an exceeded limit, or an active endpoint with Unknown size. JSON output has schemaVersion 1, success, the inspected definition, results, and a diagnostics array.

The schema module returns the same raw definition table passed to Relay.define. The workload module gives one assumption for every endpoint, including zero-frequency endpoints. The executable example above covers an input event, ordered nearby state, queued inventory updates, and an item-inspection RPC:

~~~lua
return {
	events = {
		Input = { sendsPerSecond = 12, recipients = 1, path = "QueuedSingleRecord" },
		NearbyState = { sendsPerSecond = 2, recipients = 20, path = "Immediate" },
		InventoryDelta = { sendsPerSecond = 0.5, recipients = 20, path = "QueuedSingleRecord" },
	},
	requests = {
		InspectItem = { callsPerSecond = 0.2, recipients = 1 },
	},
}
~~~

Event rates are total sends per second after application coalescing or drops, summed across senders. Client-to-server events require one recipient; server-to-client events allow any non-negative integer fanout. RPC recipients must be one, and calls per second count successfully completed calls in the success scenario. The analyzer does not predict admissions, drops, retries, recipient feasibility, queue policy, or batching.

For Immediate, the analyzer uses the inspected event byte bounds directly. Ordered-unreliable bounds already include the inspected ordered frame. QueuedSingleRecord requires inspected queued bounds and assumes one queued record per packet: the payload range comes from queuedBytes.bodyMinimum/bodyMaximum, and the packet range comes from singleRecordMinimum/singleRecordMaximum. The analyzer does not infer whether a schema uses Batch or State packing or predict actual packing.

For each RPC call, request and response body bounds are summed for payload. inspect.limits.rpcEnvelopeBytes is added once to each leg to form the complete Relay buffer range. Event and RPC rows are multiplied by the stated send/call rate and recipients. The aggregate is the sum of these modeled Relay buffer rates. Instance index bytes included in inspected queued bounds remain included; Instance-reference sidecar admission charges are excluded.

These are static schema bounds combined with user-supplied workload assumptions. They are not measured bandwidth or physical wire traffic. Roblox-encoded sizes, native tuple sizes, compression effects, and physical headers are Unknown. An active native-tuple event makes its byte-rate estimate and aggregate Unknown; a zero rate or zero server-to-client fanout contributes zero. A budget cannot pass when its aggregate maximum is Unknown. Trusted input modules execute as Luau code, must use repository-relative paths, must work under Lune, and must not print to stdout when JSON output is used.
