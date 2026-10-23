import { createServer } from "./Network";

const [server, problem] = createServer({ instanceRoot: game.GetService("Workspace"), inboundRate: {
	perPlayer: { capacity: 32, refillPerSecond: 16 },
	aggregate: { capacity: 128, refillPerSecond: 64 },
	endpoints: new Map([[1, { capacity: 16, refillPerSecond: 8 }]]),
} });
assert(server, problem?.message);
server.events.Input.Connect((player, sequence, payload) => {
	print(player.UserId, sequence, payload.items[0], payload.scores.get("score"), payload.flags.has("Active"));
	if (payload.choice.kind === "Point") print(payload.choice.position.X);
	server.events.Output.Send(player, "received", true);
});
server.requests.Lookup.Connect((_player, id) => ({ owned: id === 1, material: Enum.Material.Plastic }));
const [started, startProblem] = server.Start();
assert(started, startProblem?.message);
