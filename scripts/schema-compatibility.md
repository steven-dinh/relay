# Offline schema compatibility

Compare two trusted, Lune-authored Relay definition modules from the repository
root:

```sh
lune run scripts/schema-compatibility.luau path/to/before.luau path/to/after.luau
lune run scripts/schema-compatibility.luau path/to/before.luau path/to/after.luau --json
```

Each module returns the raw definition table accepted by `Relay.define` and may
use `Relay.schema` helpers. Paths are repository-relative `.luau` paths; spaces
and Windows backslashes are accepted. Absolute paths and paths escaping the
repository are rejected. Modules execute as trusted local Luau code under Lune
and must not print to stdout, so JSON output stays parseable.

The checker compiles both definitions with the current repository's
`Definition.define`, reads
the compiled descriptor with `Definition.get`, and uses `Definition.inspect` for
reported size bounds. Status is based only on exact descriptor equality:
`equal` exits 0; any descriptor difference exits 1 and sets
`requiresMatchedDeployment` to `true`; invalid or unsupported input exits 2.
It does not prove compatibility across releases, topology, or a complete
deployment. Studio `game` services are not emulated; the check uses the current
source compiler and inspector. Additions and widening changes still require
the same matched deployment.

## Use a release-frozen baseline

Keep the released schema module and every authored module it imports, directly
or indirectly, together in a snapshot. For example, if `Spec.luau` imports
`./Bounds`, keep both `baselines/v1/Spec.luau` and `baselines/v1/Bounds.luau`
from v1. Compare `baselines/v1/Spec.luau` with the live `Spec.luau`. If both
schemas read the live `Bounds.luau`, a change there can produce equal
descriptors even though the released schema differs. For Relay Tools, set
`baseline` to the snapshot's entry module inside the project root.

Record the Relay tools/compiler revision used for the comparison. To verify
what the released compiler produced, use a descriptor captured from that
release or test the released build.

## Read the result

JSON output has `schemaVersion: 1`, `status`, `before`, `after`, `changes`, and
`diagnostics`. Valid sides include their normalized `source`, `inspection`, and
compiled `descriptor`. A valid pair also includes `descriptorEqual` and
`requiresMatchedDeployment`. Changes are sorted and carry a `path`, `kind`
(`added`, `removed`, or `changed`), and the applicable `before`/`after` values.
Diagnostics are sorted and identify the side or arguments, code, and message.
Both `changes` and `diagnostics` are always JSON arrays, including when empty.
Both CLI entry points encode ordered `fields` lists as arrays, including `[]`
for a fieldless endpoint or struct. Older standalone reports may contain `{}` for
an empty field list. Endpoint maps remain JSON objects.
Inspector fields such as `robloxEncodedBytes: "Unknown"` remain unknown.
Descriptors and enum values containing invalid UTF-8 appear as objects with
`"encoding": "hex"` and a lowercase `bytes` string containing two hexadecimal
digits per original byte. Valid UTF-8 strings keep their usual representation.

The readable output gives endpoint additions and removals as short kind/name/ID
summaries, then lists changed metadata and endpoint paths with before/after
values. This tool is an offline view of the current compiler contract; the
runtime remains authoritative.
