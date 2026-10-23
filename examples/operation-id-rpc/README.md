# Operation-ID RPC reward shop

This example buys one potion for two server-owned coins. It uses existing typed
Relay RPC and application-owned receipts; it adds no Relay runtime API. Build:

```sh
rojo build examples/operation-id-rpc/default.project.json --output .tmp/relay-operation-id-rpc.rbxlx
```

Open the place in Studio and run Server & Clients with one client. Both sides
connect before Start. Output demonstrates timeout, explicit receipt lookup,
concurrent and completed duplicates, conflicting input and permission denial.
Run `lune run tests/operation-id-example.luau` for portable checks using the
[consumer testing kit](../../scripts/consumer-testing/README.md).

## Application design and trust boundary

The server keys accounts by Relay's actual Player argument, never a claimed user
ID. Trusted join code admits at most 64 accounts, each starting with ten coins,
zero potions and permission to buy reward 1. Reward 2 is locked. Clients supply
only an operation ID (u32, 1..4294967295) and reward ID (u8, 1..2). They cannot
supply price, balance, quantity, permission, receipt contents or another owner.
Permissions, funds, inventory limit (five potions) and account identity are
checked immediately before the nonyielding debit/grant/receipt commit.

Each account retains at most eight rows, including in-flight reservations and
denials. Claim reserves its ID/input before a trusted preparation callback may
yield. A concurrent same-input duplicate returns Pending without doing work;
a completed duplicate returns the original immutable receipt. The same ID with
different input returns Conflict, including while pending. A preparation error
becomes a retained Denied receipt, with no mutation. Pending rows never expire
or get evicted; a stuck preparation can consume a slot until player cleanup.
New IDs return Capacity when all slots are owned, without evicting old rows.

Completed receipts expire 30 seconds after completion, inclusively. Expiry is
checked lazily on Claim/Lookup, scans at most eight rows and never renews on reads.
Rows may remain allocated while idle, still within the bound. Lookup checks both
ID and original input, returns Pending/Applied/Denied/Conflict or Unknown, and
never creates an account, reserves an ID or applies an action. Capacity,
Conflict and Unknown are not permission denials for an earlier attempt.
Player removal and Destroy release accounts/receipts; a yielding claim checks
the same account identity on return so cleanup cannot resurrect it or mutate a
replacement account.

The idempotency lifetime is the current Player's admitted account in this server,
while its pending reservation or unexpired receipt is retained. After expiry,
cleanup, server crash or teleport, the ID is no longer remembered. Reusing an ID
after that boundary can perform a new action. This bounded in-memory example
does not provide durable exactly-once execution. Persistent side effects require
an application-owned atomic transaction/ledger recording both the effect and its
operation receipt. Do not use a separate non-atomic receipt write as that ledger.

## Protocol, admission and recovery

The shared version-1 definition must match on both peers. It uses reliable RPC
with the existing envelope/codec, no new wire version, shapes or decoders.
Claim and Lookup each take two primitive fields (five payload bytes). Responses
are one fixed struct containing status, coins and potions (one byte enum and two u8 leaves;
depth one, four shape nodes, no arrays, strings, buffers or native references).
With the existing three-byte body header and 44-byte RPC envelope, requests are
52 bytes and successful responses 50 bytes. Claim declares concurrency two to
let a duplicate reach the application while the original yields; Lookup uses one.
Both opt into bounded Relay refusals. Empty Ready/Welcome reliable events provide
a client-listener startup handshake and carry no authority or retained state.
The existing 8192-byte reliable
frame cap and 4096-byte descriptor cap remain authoritative.
Server ingress retains Relay's normal shared admission order and charges: one
per-player/aggregate token per accepted RPC attempt, including application
duplicates, Lookup, Conflict, Capacity and Denied. The server config allows a
16-token per-player burst/refill eight per second and aggregate 128/refill 64.
Relay's existing handler/pending/replay bounds also remain in force. Application
receipt IDs are separate from Relay's transport correlation/replay identities.

The client uses a short Claim deadline, treats RequestTimeout as **unknown
outcome**, then makes one explicit, read-only Lookup using the same ID and input.
A received Denied receipt is an explicit denial; Pending, Unknown or a failed
lookup leave the original outcome unresolved. The demo makes no automatic retry
and never replaces an unknown action with a new ID. Production UI must retain
the original input and offer deliberate reconciliation within the receipt lifetime.
Receipt coins/potions describe the original completion, not a fresh inventory
snapshot. Authentication, durable state and a production UI remain application
responsibilities.

Platform references checked on 23 October 2026:
[task scheduling](https://create.roblox.com/docs/reference/engine/libraries/task),
[Player removal](https://create.roblox.com/docs/reference/engine/classes/Players#PlayerRemoving)
and [Luau os.clock/table/coroutine semantics](https://luau.org/library/).
Portable checks and a successful place build are separate from Studio execution.
