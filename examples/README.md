# Examples

The `reliable-events` example uses only Relay's public API. Put the Relay package
and `Definition.luau` in `ReplicatedStorage`, the server script in
`ServerScriptService`, and the client script in `StarterPlayerScripts`.

The example connects before startup and shows explicit cleanup. Choose rates and
game-side validation for your application. A successful send is a transport
handoff; arrange startup in your application when receiving early events matters.
