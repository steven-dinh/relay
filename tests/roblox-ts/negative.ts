import { Client, ClientOptions, Server, ServerOptions, createClient, createServer } from "../../scripts/roblox-ts/consumer/src/Network";

export function invalidContracts(client: Client, server: Server, player: Player) {
	client.events.Missing.Send(); // expect-error
	client.events.Output.Send("wrong side", true); // expect-error
	server.events.Input.Send(1, {}); // expect-error
	client.events.Input.Connect(() => {}); // expect-error
	client.events.Input.Send("wrong", {}); // expect-error
	client.events.Input.Send(1, { items: ["bad"], scores: new Map<string, number>(), flags: new Map<"Active", true>(), choice: { kind: "Text", text: "ok" } }); // expect-error
	client.events.Input.Send(1, { items: [], scores: new Map<string, string>(), flags: new Map<"Active", true>(), choice: { kind: "Text", text: "ok" } }); // expect-error
	client.events.Input.Send(1, { items: [], scores: new Map<string, number>(), flags: new Map<"Active", boolean>(), choice: { kind: "Text", text: "ok" } }); // expect-error
	client.events.Input.Send(1, { items: [], scores: new Map<string, number>(), flags: new Map<"Active", true>(), choice: { kind: "Text", position: new Vector3() } }); // expect-error
	client.events.Input.Send(1, { items: [], scores: new Map<string, number>(), flags: new Map<"Active", true>(), choice: { kind: "Point", position: "bad" } }); // expect-error
	client.events.Timed.Send(1, 7); // expect-error
	client.events.Formats.Send(buffer.create(1), 0, new Vector2(), new Vector3(), new CFrame(), new Color3(), true); // expect-error
	server.events.Output.Send("not a Player", "message", true); // expect-error
	server.events.Output.SendTo(["bad"], "message", true); // expect-error
	server.events.default.Broadcast("not an enum value"); // expect-error
	server.events.Native3.Connect((_p, _r, _r16, _props, _font, _waypoint, material) => { const wrong: Enum.KeyCode = material; print(wrong); }); // expect-error
	server.events.Native3.Connect((_p, _r, _r16, _props, _font, _waypoint, material) => { const tooNarrow: Enum.Material.Plastic = material; print(tooNarrow); }); // expect-error
	server.events.Native3.Connect((_p, _r, _r16, _props, _font, _waypoint, _material, _color, part) => { const wrong: Model = part; print(wrong); }); // expect-error
	client.requests.Lookup.Connect(() => ({ owned: true, material: Enum.Material.Plastic })); // expect-error
	server.requests.Lookup.Request(5, 1); // expect-error
	client.requests.Confirm.Request(5, { kind: "Text", text: "ok" }); // expect-error
	server.requests.Confirm.Request(5, { kind: "Text", text: "ok" }); // expect-error
	client.requests.Lookup.Request(5, "bad"); // expect-error
	server.requests.Lookup.Connect(() => ({ owned: "bad", material: Enum.Material.Plastic })); // expect-error
	server.requests.Lookup.Connect(() => ({ owned: true, material: Enum.Material.Metal })); // expect-error
	client.requests.Confirm.Connect(() => "bad"); // expect-error
	createServer({}); // expect-error
	createServer({ inboundRate: { perPlayer: { capacity: 1, refillPerSecond: 1 }, aggregate: { capacity: 1, refillPerSecond: 1 } } }); // expect-error
	createClient({}); // expect-error
	const invalidClientNamespace: ClientOptions["namespace"] = 7; // expect-error
	const invalidServerNamespace: ServerOptions["namespace"] = 7; // expect-error
}
