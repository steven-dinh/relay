# Relay Studio Network Inspector

This optional post-candidate Studio plugin displays bounded snapshots produced
by `Relay.inspect` and `session:GetDiagnostics()`. It is not included in the
published 0.2.0 install or frozen private 0.3.0 candidate. The adapter writes
one marked `StringValue` per attached session. It never stores message payloads,
handler data, Players, or raw error messages. Native Studio server/client
observation is qualified separately for each frozen source selection; portable
checks or plugin builds alone do not establish that evidence.

## Captured project reports and diagnosis

The plugin's **Import report** button reads a saved JSON result from Relay
Tools. **Next View** cycles through Sessions, Diagnosis, Overview, Problems,
Schema and Checks. Imported reports are retained for at most four project IDs
and 4 MiB total; each file is limited to 4 MiB before JSON decoding. The project
views keep captured statuses and show Studio source freshness as unverified.
They render logical manifest paths as text hints, not invented source-line
links, and never load the project's source or execute its schema.

Diagnosis can compare a v2 registered session with an imported common check
only when the registration declares complete project/compiler/tooling/source
IDs, the check is current, and its passed schema child has the same inspection
summary and endpoint roster. This association is advisory: Studio does not
independently verify those supplied IDs, field shapes, current source files or
deployment compatibility. When identity or schema summary differs, the UI
shows why and leaves the captured paths unlinked from live refusal/queue hints.
The tool does not convert handoffs into receipts or modeled content counters
into wire or CPU measurements.

Full automatic Studio semantic evaluation and automatic watch are deferred for
this tools selection. Native Luau editor feedback, explicit CLI check/import
and opt-in Play-session observation are supported paths; a captured report is
not editor or deployment proof.

## Build and install

From the Relay repository root, build the plugin script model:

```powershell
rojo build scripts/studio-inspector/plugin.project.json -o .tmp/RelayStudioInspector.rbxmx
```

In Studio, use **Model > Advanced > Insert From File** to insert the `.rbxmx` under `ServerStorage`. Select the imported `RelayStudioInspector` Script and choose **Plugins > Save as Local Plugin**. After saving, delete the imported original Script; Studio runs the plugin copy from `PluginDebugService`. See [Roblox's local plugin steps](https://create.roblox.com/docs/studio/plugins). The toolbar button is named **RelayStudioInspector**; it opens the **Relay Tools** dock widget. The selector cycles through up to eight current snapshots. Its read-only text area supports selection and scrolling.

The filter field accepts a case-insensitive endpoint name substring or an exact ID, optionally prefixed with `#`, up to 32 bytes. An empty filter shows all endpoints. Filtering applies to live event/request detail, per-endpoint counters and traffic rows; session-wide diagnostics, rejection reports and selected history remain visible. It searches only rows present in the bounded snapshot, so rows already truncated by the 64-KiB cap cannot be recovered. Closing the widget clears the filter.

## Try the demo

Build and open the demo place, then press **Play**:

```powershell
rojo build scripts/studio-inspector/demo.project.json -o .tmp/RelayStudioInspectorDemo.rbxlx
```

The server creates a Relay definition and session with traffic and rejection diagnostics enabled, records the expected `ReadinessDisabled` result from `GetReadyPlayers()`, and broadcasts a small sequence value once per second for 30 seconds. The adapter leaves the final destroyed-session snapshot available until the demo script is removed.

## Attach to a project

Keep inspector modules in a development-only folder outside `src/` and the
Wally package. The Relay package and the four adapter modules must be present in
the Rojo tree. The checked demo project maps the adapter modules as siblings so
`Attachment` can load `Snapshot` and `Structured` and `Registration` can load
`Attachment`:

```json
"ReplicatedStorage": {
  "Relay": { "$path": "../../src" },
  "RelayInspectorTools": {
    "$className": "Folder",
    "Attachment": { "$path": "Attachment.luau" },
    "Snapshot": { "$path": "Snapshot.luau" },
    "Structured": { "$path": "Structured.luau" },
    "Registration": { "$path": "Registration.luau" }
  }
}
```

The paths above are relative to `scripts/studio-inspector/demo.project.json`;
point your own development Rojo project at the corresponding modules. Do not
ship the inspector adapter as part of Relay's runtime/Wally package.

Prefer the registration factory when this code creates the actual Relay and
definition pair. It is gated to Studio and returns the `session`, `attachment`
and optional `error`; on attachment failure the factory destroys the session it
just made:

```lua
local Registration = require(ReplicatedStorage.RelayInspectorTools.Registration)
local server, attachment, createError = Registration.createServer(Relay, definition, options, {
    label = "Game server",
    projectId = "game-project",
    compilerId = "compiler-id-from-my-build",
    toolingId = "tooling-id-from-my-build",
    sourceId = "source-id-from-my-build",
})
assert(server and attachment, createError)
```

Supply identities from the application's build process. They are declared
metadata, not independently authenticated or recomputed by Studio. The client
factory has the same arguments and return shape: use
`Registration.createClient(Relay, definition, clientOptions, metadata)` on the
client side.

For rollback or an independently created pair, the older manual `Attach` path
remains available. It writes the v1 text snapshot and labels its association
unverified because the adapter cannot prove the supplied definition and
session are related. A constructed Registration record is v2 and keeps local
server/client session IDs and the declared metadata.

For a client that already has a session, the manual attachment example is:

```lua
local Attachment = require(ReplicatedStorage.RelayInspectorTools.Attachment)
local inspector, attachError = Attachment.Attach(Relay, definition, client, "Local client")
assert(inspector, attachError)
```

The adapter finds `Players.LocalPlayer.PlayerScripts` without yielding. The
legacy server `Attachment.Attach` form is:

```lua
local Attachment = require(ReplicatedStorage.RelayInspectorTools.Attachment)
local inspector, attachError = Attachment.Attach(Relay, definition, server, "Game server")
assert(inspector, attachError)
```

The adapter stores server diagnostics only in `ServerStorage.RelayStudioInspector_v1`; client diagnostics stay in the local client's `PlayerScripts.RelayStudioInspector_v1`. Putting the module code in `ReplicatedStorage` does not put server snapshots there. Attach while a session is active or starting; a destroyed or disconnected session returns `TerminalSession` and is not reattached. `Attach` returns `NotStudio` outside Studio. Call `inspector:Destroy()` when the owner is removed. The returned handle also supports `inspector:RecordFailure(error.code)` for observed API failures; it accepts only these code strings: `AlreadyStarted`, `DefinitionMismatch`, `Disconnected`, `Destroyed`, `InvalidAudience`, `InvalidDefinition`, `InvalidOptions`, `NotStarted`, `ReadinessDisabled`, `ReadinessExhausted`, `RemoteOwnershipConflict`, `StartupTimeout`, `TransportFailure`, and `WrongRuntimeSide`.

The v2 registration attachment samples at most once per second. Its explicit
`attachment:Refresh()` request is also rate-gated to one sample per second and
returns false when called sooner. It retains at most 16 samples / 24 KiB of
encoded history within the existing 64 KiB record. Destroying the Relay session
leaves a bounded terminal snapshot at its next sample; call
`attachment:Destroy()` to stop sampling and remove the snapshot immediately.
Closing the plugin widget stops plugin polling and clears its display cache; it
does not destroy the application session or the attached sampler.

Each attachment samples at most once per second, without catching up missed ticks. It keeps at most 16 historical samples and at most 24 KiB of encoded history, evicting the oldest samples to meet both limits. History and the current view share the existing 64-KiB StringValue limit; current detail is truncated when necessary. A root contains at most eight snapshots. The plugin reads only those marked StringValues in the current DataModel, scans at most 64 players, and polls only while its widget is visible.

The history selector cycles through scalar samples with absolute values and changes from the preceding sample. History covers session/rejection counters, active handler leases, channel traffic, rejection-report totals and allowlisted API-failure counts. It retains no payloads, Players, exception text, stacks or callbacks. Missing optional diagnostics remain unavailable rather than zero. Counter decreases mark a reset rather than a negative traffic count; saturated counters cannot establish an exact delta. Active handler leases are a gauge and may decrease normally.

Sample times are elapsed `os.clock()` seconds in the attachment's local DataModel, clamped against backwards movement. They are neither wall-clock nor synchronized server/client timestamps. Each attachment starts a new history; a replacement session has a new attachment and no delta against its predecessor. `RecordFailure` refreshes the current view but does not create an extra sample. The next scheduled sample that observes `Destroyed` or `Disconnected` becomes the final sample and releases the session and sampler while leaving bounded postmortem history visible. Explicit attachment `Destroy` removes the display immediately and does not take a final sample. Sampling errors stop the sampler and leave a code-only notice. Explicit attachment `Destroy` or external removal clears retained history and removes owned display data. Closing the widget stops plugin polling and clears its display cache; attached samplers remain bounded independently. There is no cross-DataModel bridge or production telemetry backend.

Diagnostic `*Bytes` fields use modeled content units, not wire bytes. `sentPackets` counts local successful handoffs; `sentRecords` counts represented logical records. Neither proves receipt. `outboundBytesCharged` reports admission reservations separately. Relay's handler `inFlight` value is global active Relay leases. When diagnostics reports are disabled, the panel still shows session and event counters, and reports that rejection details are unavailable.

C00 benchmark measurements remain a separate evidence workflow. Inspector
counters, sampled rates and modeled workload estimates are not performance
measurements or replacements for matched benchmark evidence.
