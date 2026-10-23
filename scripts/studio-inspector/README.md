# Relay Studio Network Inspector

This optional Studio plugin displays bounded snapshots produced by `Relay.inspect` and `session:GetDiagnostics()`. The adapter writes one marked `StringValue` per attached session. It never stores message payloads, handler data, Players, or raw error messages.

## Build and install

From the Relay repository root, build the plugin script model:

```powershell
rojo build scripts/studio-inspector/plugin.project.json -o .tmp/RelayStudioInspector.rbxmx
```

In Studio, use **Model > Advanced > Insert From File** to insert the `.rbxmx` under `ServerStorage`. Select the imported `RelayStudioInspector` Script and choose **Plugins > Save as Local Plugin**. After saving, delete the imported original Script; Studio runs the plugin copy from `PluginDebugService`. See [Roblox's local plugin steps](https://create.roblox.com/docs/studio/plugins). The toolbar button is named **RelayStudioInspector**; it opens the **Relay Network Inspector** dock widget. The selector cycles through up to eight current snapshots. Its read-only text area supports selection and scrolling.

## Try the demo

Build and open the demo place, then press **Play**:

```powershell
rojo build scripts/studio-inspector/demo.project.json -o .tmp/RelayStudioInspectorDemo.rbxlx
```

The server creates a Relay definition and session with traffic and rejection diagnostics enabled, records the expected `ReadinessDisabled` result from `GetReadyPlayers()`, and broadcasts a small sequence value once per second for 30 seconds. The adapter leaves the final destroyed-session snapshot available until the demo script is removed.

## Attach to a project

Keep the inspector modules outside `src/` and the Wally package. For client use, expose the `Attachment` and `Snapshot` ModuleScripts to the LocalScript, then attach after creating the Relay client session:

```lua
local Attachment = require(ReplicatedStorage.RelayInspectorTools.Attachment)
local inspector, attachError = Attachment.Attach(Relay, definition, client, "Local client")
assert(inspector, attachError)
```

The adapter finds `Players.LocalPlayer.PlayerScripts` without yielding. For server use, require the same development modules and attach the server session:

```lua
local Attachment = require(ReplicatedStorage.RelayInspectorTools.Attachment)
local inspector, attachError = Attachment.Attach(Relay, definition, server, "Game server")
assert(inspector, attachError)
```

The adapter stores server diagnostics only in `ServerStorage.RelayStudioInspector_v1`; client diagnostics stay in the local client's `PlayerScripts.RelayStudioInspector_v1`. Putting the module code in `ReplicatedStorage` does not put server snapshots there. Attach while a session is active or starting; a destroyed or disconnected session returns `TerminalSession` and is not reattached. `Attach` returns `NotStudio` outside Studio. Call `inspector:Destroy()` when the owner is removed. The returned handle also supports `inspector:RecordFailure(error.code)` for observed API failures; it accepts only these code strings: `AlreadyStarted`, `DefinitionMismatch`, `Disconnected`, `Destroyed`, `InvalidAudience`, `InvalidDefinition`, `InvalidOptions`, `NotStarted`, `ReadinessDisabled`, `ReadinessExhausted`, `StartupTimeout`, `TransportFailure`, and `WrongRuntimeSide`.

Each attachment samples at most once per second, without catching up missed ticks. It keeps at most 16 historical samples and at most 24 KiB of encoded history, evicting the oldest samples to meet both limits. History and the current view share the existing 64-KiB StringValue limit; current detail is truncated when necessary. A root contains at most eight snapshots. The plugin reads only those marked StringValues in the current DataModel, scans at most 64 players, and polls only while its widget is visible.

The history selector cycles through scalar samples with absolute values and changes from the preceding sample. History covers session/rejection counters, active handler leases, channel traffic, rejection-report totals and allowlisted API-failure counts. It retains no payloads, Players, exception text, stacks or callbacks. Missing optional diagnostics remain unavailable rather than zero. Counter decreases mark a reset rather than a negative traffic count; saturated counters cannot establish an exact delta. Active handler leases are a gauge and may decrease normally.

Sample times are elapsed `os.clock()` seconds in the attachment's local DataModel, clamped against backwards movement. They are neither wall-clock nor synchronized server/client timestamps. Each attachment starts a new history; a replacement session has a new attachment and no delta against its predecessor. `RecordFailure` refreshes the current view but does not create an extra sample. The next scheduled sample that observes `Destroyed` or `Disconnected` becomes the final sample and releases the session and sampler while leaving bounded postmortem history visible. Explicit attachment `Destroy` removes the display immediately and does not take a final sample. Sampling errors stop the sampler and leave a code-only notice. Explicit attachment `Destroy` or external removal clears retained history and removes owned display data. Closing the widget stops plugin polling and clears its display cache; attached samplers remain bounded independently. There is no cross-DataModel bridge or production telemetry backend.

Diagnostic `*Bytes` fields use modeled content units, not wire bytes. `sentPackets` counts local successful handoffs; `sentRecords` counts represented logical records. Neither proves receipt. `outboundBytesCharged` reports admission reservations separately. Relay's handler `inFlight` value is global active Relay leases. When diagnostics reports are disabled, the panel still shows session and event counters, and reports that rejection details are unavailable.
