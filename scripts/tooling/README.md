# Relay Tools shared contracts

These internal development modules are outside the Relay runtime and Wally package.
The integration is in progress; the existing individual commands remain supported.

Project.validate accepts one schemaVersion 1 project, with id and a project-relative
schema .luau path. Optional policy, workload and baseline name .luau modules;
typescript names an owned .d.ts output; tests lists at most 32 .luau scenarios.
maxBytesPerSecond requires workload and a finite non-negative limit.

The optional required list contains schema, policy, compat, budget, tests or
typescript. Schema is always required. By default schema and configured
policy/compat/budget checks are required; testing and TypeScript are explicit.
A host resolves real paths within the selected project root. Lexical path validation
does not sandbox trusted Luau imports.

Result.new builds a versioned operation result with projectId, compilerId, toolingId,
sourceId, host (cli/studio), runId, status, diagnostics, artifacts and optional data.
Diagnostic rows include severity, code, path, message and an action. Artifacts carry
path, kind and optional digest; hosts enforce their actual ownership boundaries.
Result.aggregate records a flat children list and required operations. Required
missing, stale, unsupported or skipped work cannot yield a passed result. Identity
mismatch is stale; otherwise failed outranks cancelled, unsupported, inconclusive
and running. Readers reject inconsistent status and passed records with errors.
Result.isCurrent validates the complete identity, including runId, before accepting
a job result. Hosts advance runId when replacing a job, even with unchanged inputs.
Keep unknown/modeled units intact; this format does not establish authentication,
deployment compatibility, wire traffic or successful receipt.

Serialized readers must enforce the 4 MiB input limit before decoding. Result.validate
also bounds table depth to 32, entries to 65536 and diagnostic rows to 256, and
rejects cycles, unsupported values and inconsistent aggregates. Existing inspector
retention limits remain stricter and separate.

The host-neutral schema-check-core and schema-compatibility-core functions receive
the actual loaded Definition module explicitly. File loading, process execution,
CLI output and exit behavior stay in their host. Budget.analyze and the optional
TypeScript generator remain their existing owners.
