# Bounded session shutdown

`Drain.luau` is an application-owned quiesce/drain wrapper around a Relay server
session. `Run` starts work only while open, counts it until the callback returns,
and returns `false, "Closing"` after shutdown begins (`"TooManyActive"` at the
256-work cap). Callback errors release the count and are warned.

`BindToClose` disconnects the input listener, closes admission, waits at most
10 seconds using `os.clock()` seconds and `task.wait()`, then destroys the Relay
session. The Roblox DataModel reference says multiple `BindToClose` callbacks
run in parallel and the server waits up to 30 seconds for all callbacks:
[DataModel:BindToClose](https://create.roblox.com/docs/reference/engine/classes/DataModel).
Checked 23 October 2026. The 10-second recipe deadline leaves time for other
shutdown callbacks; this checkout has not run the example in Studio.

The recipe discards unsent Relay FIFO and State work when the session is
destroyed; those handles become unusable with the session. It does not flush,
retry, replay, save game data, or promise receipt.
An already handed-off send is not a delivery receipt. An in-flight request may
have an uncertain outcome. `Run` refuses new application work after close starts;
work already running can still attempt sends while it drains. If the deadline
expires, the session is destroyed while those callbacks may continue; they are
not cancelled, and later side effects remain application-owned. Player removal
or Relay diagnostics/teardown clearing its own in-flight count does not change
the recipe counter.

Build and open `default.project.json` in Studio to run the server-side example.
Run `lune run tests/session-drain.luau` for the bounded portable lifecycle checks.
