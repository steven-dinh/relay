import { createClient } from "./Network";

const [client, problem] = createClient({ startupTimeoutSeconds: 10, namespace: "typescript" });
assert(client, problem?.message);
client.events.Output.Once((message, accepted) => print(message, accepted));
client.requests.Confirm.Connect((choice) => choice.kind === "Text");
const [started, startProblem] = client.Start();
assert(started, startProblem?.message);
const [sent, sendProblem] = client.events.Input.Send(1, {
	items: [1, 2], scores: new Map([["score", 3]]), flags: new Map<"Active" | "Hidden", true>([["Active", true]]),
	choice: { kind: "Point", position: new Vector3(1, 2, 3) },
});
assert(sent, sendProblem?.message);
client.events.Timed.Send(7);
const [pending, requestProblem] = client.requests.Lookup.Request(5, 1);
assert(pending, requestProblem?.message);
const result = pending.Await();
if (result.ok) print(result.value.owned, result.value.material, result.value.note);
else warn(result.error.code, result.error.message);
