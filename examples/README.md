# Examples

The `reliable-events` example uses only Relay's public API. Put the Relay package
and `Definition.luau` plus `ordered.luau` in `ReplicatedStorage`, the server script in
`ServerScriptService`, and the client script in `StarterPlayerScripts`.

Use Luau's new type solver. The strict schema preserves each field's position
with `ordered(...)` and its exact kind/direction with singleton annotations.
Both sides require the same definition module, so their event names, methods,
and payload types are derived without separate client/server declarations.
The helper is an example of consumer-owned schema setup, not a Relay export.

The example connects before startup and shows explicit cleanup. Choose rates and
game-side validation for your application. A successful send is a transport
handoff; arrange startup in your application when receiving early events matters.
