import { Client, Server } from "./Network";

export function nativeContracts(client: Client, server: Server, player: Player, values: {
	udim: UDim; udim2: UDim2; range: NumberRange; rect: Rect; brick: BrickColor;
	v2: Vector2int16; v3: Vector3int16; sequence: NumberSequence; colors: ColorSequence;
	key: NumberSequenceKeypoint; colorKey: ColorSequenceKeypoint; tween: TweenInfo; date: DateTime;
	ray: Ray; axes: Axes; faces: Faces; region: Region3; region16: Region3int16;
	properties: PhysicalProperties; font: Font; waypoint: PathWaypoint; part: Part;
}) {
	const [refreshed, refreshProblem] = client.RefreshReadiness(true);
	print(refreshed, refreshProblem?.code);
	client.RefreshReadiness();
	client.events.Native1.Send(values.udim, values.udim2, values.range, values.rect, values.brick, values.v2, values.v3, values.sequence);
	client.events.Native2.Send(values.colors, values.key, values.colorKey, values.tween, values.date, values.ray, values.axes, values.faces);
	client.events.Native3.Send(values.region, values.region16, values.properties, values.font, values.waypoint,
		Enum.Material.Wood, new Color3(), values.part);
	client.events.Formats.Send(buffer.create(1), 0.25, new Vector2(), new Vector3(), new CFrame(), new Color3(), undefined, true);
	server.events.Native3.Connect((_player, _region, _region16, _properties, _font, _waypoint, material, _color, part) => {
		const precise: Enum.Material.Plastic | Enum.Material.Wood = material;
		const classChecked: BasePart = part;
		print(precise, classChecked.Size);
	});
	server.events.Timed.Once((sender, time, value) => print(sender.UserId, time + value));
	server.events.Output.Broadcast("broadcast", true);
	const [ok, problem, count] = server.events.Output.SendTo([player], "audience", true);
	print(ok, problem, count);
	server.events.Output.SendExcept([], "excluded", false);
	server.events.Output.GetReadyPlayers();
	server.events.Empty.Broadcast();
	server.events.default.Broadcast("quote\"");
	server.events.default.Broadcast("line\n");
	server.events.default.Broadcast("nul\0");
	server.events.default.Broadcast("slash\\");
	const [pending] = server.requests.Confirm.Request(player, 5, { kind: "Text", text: "check" });
	if (pending) {
		const result = pending.Await();
		if (result.ok) { const value: boolean = result.value; print(value); }
		pending.Cancel();
	}
}
