# Entity state native fixture

Build the isolated two-client place from the repository root:

```sh
rojo build tests/studio/entity-state/default.project.json --output .tmp/relay-entity-state-studio.rbxlx
```

Open the place in Studio and start a local server with two players. The server
authorizes the first current Player from its observed join order; both clients
request the same zero-argument snapshot, so the second Player must receive a
metadata-free denial. The fixture then checks an eight-target baseline, holds
baseline installation until the absolute update emitted after the server
captures that baseline arrives, applies deletion, revokes the authorized view,
and checks a fresh authorized baseline after re-entry without the deleted ID.
The fixture reports `TEST entity-state PASS` after both clients destroy their
Relay session and companion state.

The two fixture-only RemoteEvents carry a fixed command/report name. They carry
no membership, entity ID, or collection data and are not used by the example.
All application state travels through the companion's real Relay definition and
helper modules. This is a source-specific native correctness fixture; a Rojo
build or portable test does not qualify its Studio execution.
